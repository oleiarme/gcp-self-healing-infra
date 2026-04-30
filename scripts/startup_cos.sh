#!/bin/bash
set -e
set -o pipefail
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

echo "Starting n8n on COS..."

# ==========================================
# 0. Utility functions
# ==========================================
retry() {
  for i in {1..5}; do
    "$@" && return 0
    echo "⏳ Retry $i/5: $*"
    sleep 5
  done
  return 1
}

get_metadata() {
  curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"
}

get_token() {
  get_metadata "instance/service-accounts/default/token" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4
}

get_secret() {
  local SECRET_NAME=$1
  local TOKEN=$(get_token)
  curl -sf -H "Authorization: Bearer $TOKEN" \
       "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/$SECRET_NAME/versions/latest:access" \
       | grep -o '"data": "[^"]*' | cut -d'"' -f4 | docker run -i --rm busybox base64 -d
}

# ==========================================
# 1. Setup Swap (e2-micro needs it)
# ==========================================
echo "=== Setup Swap ==="
if [ ! -f /var/lib/swapfile ]; then
  fallocate -l 4G /var/lib/swapfile
  chmod 600 /var/lib/swapfile
  mkswap /var/lib/swapfile
fi
if ! swapon --show | grep -q swapfile; then
  swapon /var/lib/swapfile
fi
sysctl -w vm.swappiness=10

# ==========================================
# 2. Docker registry mirror (BEFORE health server!)
# ==========================================
echo "=== Setup Docker Registry Mirror ==="
mkdir -p /etc/docker
cat <<DOCKEREOF > /etc/docker/daemon.json
{
  "registry-mirrors": ["https://mirror.gcr.io"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKEREOF
systemctl daemon-reload
systemctl restart docker

# Wait for Docker to be ready after restart
for i in {1..30}; do
  if docker info >/dev/null 2>&1; then
    echo "✅ Docker is ready"
    break
  fi
  sleep 2
done

# ==========================================
# 3. Health server (AFTER Docker restart)
# ==========================================
echo "=== Starting Early Health Check Server (port 8080) ==="
# busybox nc does NOT support -e flag, use pipe instead
docker run -d --name health-server --restart always --network host busybox sh -c '
while true; do
  echo -e "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nBOOTSTRAP" | nc -l -p 8080 || true
done
'

# ==========================================
# 4. Wait for GCP metadata
# ==========================================
echo "=== Fetching Metadata Token ==="
for i in {1..10}; do
  if get_metadata "instance/id" >/dev/null; then
    break
  fi
  sleep 2
done

TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then
  echo "❌ Failed to get access token"
  exit 1
fi

# ==========================================
# 5. Get Secrets from Secret Manager
# ==========================================
echo "=== Get Secrets from Secret Manager ==="
DB_PASSWORD=$(retry get_secret "${DB_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch DB_PASSWORD"
  exit 1
}
N8N_KEY=$(retry get_secret "${N8N_KEY_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch N8N_KEY"
  exit 1
}
CF_TOKEN=$(retry get_secret "${CF_TUNNEL_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch CF_TOKEN"
  exit 1
}

if [ -z "$DB_PASSWORD" ] || [ -z "$N8N_KEY" ] || [ -z "$CF_TOKEN" ]; then
  echo "❌ One or more secrets are empty"
  exit 1
fi
echo "✅ All secrets fetched successfully"

# ==========================================
# 6. Mount Persistent Data Disk
# ==========================================
echo "=== Mount Persistent Data Disk ==="
DATA_DISK="/dev/disk/by-id/google-n8n-data"
for i in {1..30}; do
  if [ -b "$DATA_DISK" ]; then
    echo "✅ Disk attached"
    break
  fi
  echo "⏳ Waiting for disk ($i/30)..."
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
chown -R 70:70 /mnt/data/postgres
mkdir -p /home/docker/n8n

# ==========================================
# 7. Docker Network + Image Pull
# ==========================================
docker network create n8n-net || true

echo "=== Pulling Images ==="
N8N_TARGET="${n8n_ar_image}"
CF_TARGET="${cloudflared_ar_image}"

# Authenticate Docker to Artifact Registry
echo "$TOKEN" | docker login -u oauth2accesstoken --password-stdin https://${ar_location}-docker.pkg.dev 2>/dev/null || true

retry docker pull "$N8N_TARGET" || {
  echo "⚠️ AR miss for n8n → fallback to public"
  N8N_TARGET="${n8n_image}"
  retry docker pull "$N8N_TARGET" || { echo "❌ Failed to pull n8n"; exit 1; }
}

retry docker pull "$CF_TARGET" || {
  echo "⚠️ AR miss for cloudflared → fallback to public"
  CF_TARGET="${cloudflared_image}"
  retry docker pull "$CF_TARGET" || { echo "❌ Failed to pull cloudflared"; exit 1; }
}

retry docker pull postgres:15-alpine || { echo "❌ Failed to pull postgres"; exit 1; }

# ==========================================
# 8. Start Postgres
# ==========================================
echo "=== Starting Postgres ==="
docker run -d \
  --name postgres \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -v /mnt/data/postgres:/var/lib/postgresql/data \
  -e POSTGRES_DB="${db_name}" \
  -e POSTGRES_USER="${db_user}" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:15-alpine

echo "=== Waiting for Postgres ==="
READY=false
for i in {1..60}; do
  if docker exec postgres pg_isready -U "${db_user}" >/dev/null 2>&1; then
    if docker exec postgres psql -U "${db_user}" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
      echo "✅ Postgres fully ready"
      READY=true
      break
    fi
  fi
  echo "⏳ Waiting for Postgres ($i/60)..."
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "❌ Postgres failed to start"
  docker logs postgres --tail=50 || true
  exit 1
fi

# ==========================================
# 9. Backup Restore (DR only)
# ==========================================
echo "=== Backup Restore (DR only) ==="
SKIP_RESTORE=false
DB_EXISTS=$(docker exec postgres psql -U "${db_user}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" | xargs)
if [ "$DB_EXISTS" = "1" ]; then
  TABLE_EXISTS=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name='workflow_entity');" 2>/dev/null | xargs)
  if [ "$TABLE_EXISTS" = "t" ]; then
    COUNT=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM workflow_entity;" | xargs)
    if [ "$COUNT" -gt 0 ]; then
      echo "✅ DB populated ($COUNT workflows) → SKIP restore"
      SKIP_RESTORE=true
    fi
  fi
fi

if [ "$SKIP_RESTORE" != "true" ]; then
  echo "Fetching latest backup info via REST API..."
  # Refresh token before GCS operations (may have expired during long startup)
  TOKEN=$(get_token)
  BACKUP_INFO=$(curl -sf -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-") || true

  LATEST_OBJ=$(echo "$BACKUP_INFO" | grep -o '"name": "[^"]*' | cut -d'"' -f4 | grep '\.sql$' | sort | tail -n 1)

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
      echo "⚠️ Failed to download backup, starting fresh"
    fi
  else
    echo "⚠️ No backups found, starting fresh"
  fi
fi

# ==========================================
# 10. Start n8n
# ==========================================
echo "=== Starting n8n ==="
docker run -d \
  --name n8n \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
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
  -e N8N_PORT=5678 \
  -e N8N_LISTEN_ADDRESS=0.0.0.0 \
  -e DB_POSTGRESDB_CONNECTION_TIMEOUT=60000 \
  "$N8N_TARGET"

# ==========================================
# 11. Wait for n8n, then start cloudflared
# ==========================================
echo "=== Waiting for n8n ==="
N8N_READY=false
for i in {1..60}; do
  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "✅ n8n is ready"
    N8N_READY=true
    # Switch health server from BOOTSTRAP to OK
    docker exec health-server sh -c 'kill $$(pgrep nc) 2>/dev/null; true'
    break
  fi
  echo "⏳ Waiting for n8n ($i/60)..."
  sleep 5
done

if [ "$N8N_READY" != "true" ]; then
  echo "❌ n8n failed to become ready"
  docker logs n8n --tail=50 || true
fi

echo "=== Starting cloudflared ==="
docker run -d \
  --name cloudflared \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:2000:2000 \
  "$CF_TARGET" \
  tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run --token "$CF_TOKEN"

# ==========================================
# 12. Final health verification
# ==========================================
echo "=== Final Health Verification ==="
HEALTHY=false
for i in {1..30}; do
  n8n_ok=false
  cf_ok=false

  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    n8n_ok=true
  fi
  if curl -fsS http://127.0.0.1:2000/ready >/dev/null 2>&1; then
    cf_ok=true
  fi

  if [ "$n8n_ok" = true ] && [ "$cf_ok" = true ]; then
    echo "✅ n8n + cloudflared are healthy"
    HEALTHY=true
    break
  fi
  echo "⏳ Verifying ($i/30)..."
  sleep 5
done

if [ "$HEALTHY" != "true" ]; then
  echo "❌ CRITICAL: not all services healthy"
  echo "=== n8n logs ==="
  docker logs n8n --tail=30 || true
  echo "=== cloudflared logs ==="
  docker logs cloudflared --tail=30 || true
fi

# ==========================================
# 13. Backup via systemd timer
# ==========================================
echo "=== Setup Backup Timer ==="
cat <<EOF > /home/docker/backup.sh
#!/bin/bash
set -e
TOKEN=\$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
FILE="/tmp/n8n-\$${TIMESTAMP}.sql"

COUNT=\$(docker exec postgres psql -U ${db_user} -d ${db_name} -t -c "SELECT count(*) FROM workflow_entity;" | xargs)
if [ "\$COUNT" -lt 1 ]; then
  echo "⚠️ SKIP backup: no workflows"
  exit 0
fi

SIZE=\$(docker exec postgres psql -U ${db_user} -d ${db_name} -t -c "SELECT pg_database_size('${db_name}');" | xargs)
if [ "\$SIZE" -lt 1000000 ]; then
  echo "⚠️ SKIP backup: DB too small (\$SIZE bytes)"
  exit 0
fi

timeout 300 docker exec postgres pg_dump -U ${db_user} --no-owner --no-acl --clean --if-exists ${db_name} > "\$FILE"
if [ ! -s "\$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

(cd /tmp && sha256sum "\$(basename "\$FILE")") > "\$FILE.sha256"

# Upload backup
curl -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @"\$FILE" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\$${TIMESTAMP}.sql"

# Upload checksum
curl -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: text/plain" \
     --data-binary @"\$FILE.sha256" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\$${TIMESTAMP}.sql.sha256"

rm -f "\$FILE" "\$FILE.sha256"
echo "BACKUP_OK \$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EOF
chmod +x /home/docker/backup.sh

cat <<'SVCEOF' > /etc/systemd/system/n8n-backup.service
[Unit]
Description=n8n Postgres Backup
[Service]
Type=oneshot
ExecStart=/home/docker/backup.sh
SVCEOF

cat <<'TMREOF' > /etc/systemd/system/n8n-backup.timer
[Unit]
Description=Run n8n Backup every 10 min
[Timer]
OnBootSec=15min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
TMREOF

systemctl daemon-reload
systemctl enable --now n8n-backup.timer

echo "=== ALL DONE ==="
exit 0
