#!/bin/bash
set -e
set -o pipefail
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

echo "Starting n8n on COS..."

# 1. Health server in busybox (runs in background)
echo "=== Starting Early Health Check Server (port 8080) ==="
docker run -d --name health-server --restart always -p 8080:8080 busybox sh -c '
cat <<EOF > /tmp/index.html
HTTP/1.1 200 OK
Content-Type: text/plain

BOOTSTRAP
EOF
while true; do
  nc -l -p 8080 -e cat /tmp/index.html || true
done
'

# 2. Setup Swap (e2-micro needs it)
echo "=== Setup Swap ==="
if [ ! -f /var/lib/swapfile ]; then
  fallocate -l 4G /var/lib/swapfile
  chmod 600 /var/lib/swapfile
  mkswap /var/lib/swapfile
fi
if ! swapon --show | grep -q swapfile; then
  swapon /var/lib/swapfile
fi

# 3. Docker registry mirror
echo "=== Setup Docker Registry Mirror ==="
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "registry-mirrors": ["https://mirror.gcr.io"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl daemon-reload
systemctl restart docker

# 4. GCP Auth via Metadata
echo "=== Fetching Metadata Token ==="
get_metadata() {
  curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"
}

# Wait for metadata server
for i in {1..10}; do
  if get_metadata "instance/id" >/dev/null; then
    break
  fi
  sleep 2
done

TOKEN=$(get_metadata "instance/service-accounts/default/token" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
if [ -z "$TOKEN" ]; then
  echo "❌ Failed to get access token"
  exit 1
fi

get_secret() {
  local SECRET_NAME=$1
  # Use busybox base64 to ensure it works consistently
  curl -sf -H "Authorization: Bearer $TOKEN" \
       "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/$SECRET_NAME/versions/latest:access" \
       | grep -o '"data": "[^"]*' | cut -d'"' -f4 | docker run -i --rm busybox base64 -d
}

echo "=== Get Secrets from Secret Manager ==="
DB_PASSWORD=$(get_secret "${DB_SECRET_NAME}")
N8N_KEY=$(get_secret "${N8N_KEY_SECRET_NAME}")
CF_TOKEN=$(get_secret "${CF_TUNNEL_SECRET_NAME}")

if [ -z "$DB_PASSWORD" ] || [ -z "$N8N_KEY" ] || [ -z "$CF_TOKEN" ]; then
  echo "❌ Failed to fetch secrets"
  exit 1
fi
echo "✅ Secrets fetched successfully"

# 5. Mount Persistent Disk
echo "=== Mount Persistent Data Disk ==="
DATA_DISK="/dev/disk/by-id/google-n8n-data"
for i in {1..30}; do
  if [ -b "$DATA_DISK" ]; then
    echo "✅ Disk attached"
    break
  fi
  sleep 2
done

if [ ! -b "$DATA_DISK" ]; then
  echo "❌ CRITICAL: Persistent disk not attached"
  exit 1
fi

if ! blkid "$DATA_DISK" | grep -q 'TYPE="ext4"'; then
  echo "Formatting new persistent disk..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK"
fi

mkdir -p /mnt/data
fsck -a "$DATA_DISK" || true
mount -o discard,defaults "$DATA_DISK" /mnt/data

mkdir -p /mnt/data/postgres
# UID 70 is postgres in alpine
chown -R 70:70 /mnt/data/postgres
mkdir -p /home/docker/n8n

# 6. Docker Network
docker network create n8n-net || true

# 7. Start Containers
echo "=== Pulling Images ==="
N8N_TARGET="${n8n_ar_image}"
CF_TARGET="${cloudflared_ar_image}"

# Authenticate Docker to AR using a temporary helper container
mkdir -p /home/docker/.docker
docker run --rm -v /home/docker/.docker:/root/.docker -e "GOOGLE_APPLICATION_CREDENTIALS=" busybox sh -c "
echo '{\"credHelpers\": {\"${ar_location}-docker.pkg.dev\": \"gcr\"}}' > /root/.docker/config.json
"
# Alternatively, we can just pass the token to docker login since we have it:
echo "$TOKEN" | docker login -u oauth2accesstoken --password-stdin https://${ar_location}-docker.pkg.dev

docker pull "$N8N_TARGET" || N8N_TARGET="${n8n_image}"
docker pull "$CF_TARGET" || CF_TARGET="${cloudflared_image}"
docker pull postgres:15-alpine

echo "=== Starting Postgres ==="
docker run -d \
  --name postgres \
  --network n8n-net \
  --restart unless-stopped \
  -v /mnt/data/postgres:/var/lib/postgresql/data \
  -e POSTGRES_DB="${db_name}" \
  -e POSTGRES_USER="${db_user}" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:15-alpine

echo "=== Waiting for Postgres ==="
READY=false
for i in {1..30}; do
  if docker exec postgres pg_isready -U "${db_user}" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "❌ Postgres failed to start"
  exit 1
fi

echo "=== Backup Restore (DR only) ==="
SKIP_RESTORE=false
DB_EXISTS=$(docker exec postgres psql -U "${db_user}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" | xargs)
if [ "$DB_EXISTS" = "1" ]; then
  TABLE_EXISTS=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name='workflow_entity');" 2>/dev/null | xargs)
  if [ "$TABLE_EXISTS" = "t" ]; then
    COUNT=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM workflow_entity;" | xargs)
    if [ "$COUNT" -gt 0 ]; then
      echo "✅ DB populated → SKIP restore"
      SKIP_RESTORE=true
    fi
  fi
fi

if [ "$SKIP_RESTORE" != "true" ]; then
  echo "Fetching latest backup info via REST API..."
  BACKUP_INFO=$(curl -sf -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-")
  
  LATEST_OBJ=$(echo "$BACKUP_INFO" | grep -o '"name": "[^"]*' | cut -d'"' -f4 | grep '.sql$' | sort | tail -n 1)
  
  if [ -n "$LATEST_OBJ" ]; then
    echo "Restoring from $LATEST_OBJ"
    OBJ_ENC=$(echo "$LATEST_OBJ" | sed 's/\//%2F/g')
    curl -sf -H "Authorization: Bearer $TOKEN" \
         "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/$${OBJ_ENC}?alt=media" > /home/docker/backup.sql
    
    if [ -s /home/docker/backup.sql ]; then
      docker exec postgres psql -U "${db_user}" -d postgres -c "DROP DATABASE IF EXISTS ${db_name};"
      docker exec postgres psql -U "${db_user}" -d postgres -c "CREATE DATABASE ${db_name};"
      cat /home/docker/backup.sql | docker exec -i postgres psql -U "${db_user}" -d "${db_name}" --single-transaction
      echo "✅ Restore complete"
      rm -f /home/docker/backup.sql
    else
      echo "❌ Failed to download backup"
    fi
  else
    echo "⚠️ No backups found, starting fresh"
  fi
fi

echo "=== Starting n8n ==="
docker run -d \
  --name n8n \
  --network n8n-net \
  --restart unless-stopped \
  -p 5678:5678 \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT="${db_port}" \
  -e DB_POSTGRESDB_DATABASE="${db_name}" \
  -e DB_POSTGRESDB_USER="${db_user}" \
  -e DB_POSTGRESDB_PASSWORD="$DB_PASSWORD" \
  -e N8N_ENCRYPTION_KEY="$N8N_KEY" \
  -e N8N_EXECUTIONS_MODE=regular \
  -e N8N_CONCURRENCY_PRODUCTION_LIMIT=1 \
  -e N8N_LOG_LEVEL=warn \
  -e EXECUTIONS_DATA_SAVE_ON_SUCCESS=none \
  -e EXECUTIONS_DATA_SAVE_ON_ERROR=all \
  -e EXECUTIONS_DATA_PRUNE=true \
  -e EXECUTIONS_DATA_MAX_AGE_HISTORY=24 \
  -e N8N_RUNNERS_ENABLED=true \
  -e N8N_RUNNERS_MODE=internal \
  -e N8N_HOST=n8n-gcp.pp.ua \
  -e N8N_PROTOCOL=https \
  -e WEBHOOK_URL=https://n8n-gcp.pp.ua/ \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_METRICS_ENABLED=false \
  "$N8N_TARGET"

echo "=== Starting cloudflared ==="
docker run -d \
  --name cloudflared \
  --network n8n-net \
  --restart unless-stopped \
  -e CF_TOKEN="$CF_TOKEN" \
  "$CF_TARGET" \
  tunnel --no-autoupdate --protocol http2 run --token "$CF_TOKEN"

echo "=== Waiting for n8n ==="
for i in {1..60}; do
  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "✅ n8n is ready"
    # Switch health server to OK state
    docker exec health-server sh -c 'echo -e "HTTP/1.1 200 OK\n\nOK" > /tmp/index.html'
    break
  fi
  sleep 5
done

echo "=== Setup Backup Timer ==="
cat <<'EOF' > /home/docker/backup.sh
#!/bin/bash
set -e
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILE="/tmp/n8n-$${TIMESTAMP}.sql"

COUNT=$(docker exec postgres psql -U ${db_user} -d ${db_name} -t -c "SELECT count(*) FROM workflow_entity;" | xargs)
if [ "$COUNT" -lt 1 ]; then
  exit 0
fi

docker exec postgres pg_dump -U ${db_user} --no-owner --clean ${db_name} > "$FILE"
if [ -s "$FILE" ]; then
  curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: text/plain" \
       --data-binary @"$FILE" \
       "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-$${TIMESTAMP}.sql"
  rm "$FILE"
fi
EOF
chmod +x /home/docker/backup.sh

cat <<'EOF' > /etc/systemd/system/n8n-backup.service
[Unit]
Description=n8n Backup
[Service]
Type=oneshot
ExecStart=/home/docker/backup.sh
EOF

cat <<'EOF' > /etc/systemd/system/n8n-backup.timer
[Unit]
Description=Run n8n Backup every 10 min
[Timer]
OnBootSec=15min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now n8n-backup.timer

echo "=== ALL DONE ==="
