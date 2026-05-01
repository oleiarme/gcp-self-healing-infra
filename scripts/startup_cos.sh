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
  local RAW
  RAW=$(curl -sf -H "Authorization: Bearer $TOKEN" \
       "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/$SECRET_NAME/versions/latest:access")
  echo "$RAW" | sed -n 's/.*"data": "\([^"]*\)".*/\1/p' | base64 -d
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

echo "=== Recreate Docker network after restart ==="
docker network create n8n-net || true

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
cat <<'EOF' > /tmp/health_server.py
import http.server
import socketserver
import time
import socket
import urllib.request

START_TIME = time.time()
BOOTSTRAP_WINDOW = 1200
STALL_TIMEOUT = 300
MAX_BOOT_TIME = 1800
LAST_PROGRESS_FILE = '/tmp/health_progress'

def touch_progress():
    with open(LAST_PROGRESS_FILE, 'w') as f:
        f.write(str(time.time()))

def get_last_progress():
    try:
        with open(LAST_PROGRESS_FILE) as f:
            return float(f.read().strip())
    except:
        return START_TIME

def check_port(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=1)
        s.close()
        return True
    except:
        return False

def check_http(url):
    try:
        urllib.request.urlopen(url, timeout=2)
        return True
    except:
        return False

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        uptime = time.time() - START_TIME

        try:
            n8n_ok = check_http("http://127.0.0.1:5678/healthz")
            pg_ok = check_port(5432)
            ready = (n8n_ok and pg_ok)

            if n8n_ok or pg_ok:
                touch_progress()
        except:
            ready = False

        if not ready and uptime > MAX_BOOT_TIME:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"HARD_FAIL")
            return

        if not ready and uptime < BOOTSTRAP_WINDOW:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"BOOTSTRAP")
            return

        if not ready:
            if time.time() - get_last_progress() > STALL_TIMEOUT:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b"STALLED")
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"BOOTSTRAP")
            return

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

with ThreadingTCPServer(("", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF


docker rm -f health-server 2>/dev/null || true

docker run -d --name health-server --restart always --network host \
  -v /tmp/health_server.py:/health_server.py:ro \
  mirror.gcr.io/python:3-alpine python3 /health_server.py

sleep 2
docker ps | grep health-server || {
  echo "❌ health-server failed to start"
  docker logs health-server || true
  exit 1
}

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

mkdir -p /mnt/disks/data
fsck -a "$DATA_DISK" || true
mount -o discard,defaults "$DATA_DISK" /mnt/disks/data

mkdir -p /mnt/disks/data/postgres
chown -R 70:70 /mnt/disks/data/postgres
mkdir -p /home/docker/n8n

# ==========================================
# 7. Docker Network + Image Pull
# ==========================================
docker network create n8n-net || true

# === Disk check (COS-aware) ===

# Try to get Docker root
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")

# Fallback если docker ещё не стартовал
if [ -z "$DOCKER_ROOT" ]; then
  DOCKER_ROOT="/mnt/stateful_partition"
  echo "⚠️ Docker not ready, fallback to $DOCKER_ROOT"
fi

echo "Disk check path: $DOCKER_ROOT"
df -h "$DOCKER_ROOT"

AVAIL_KB=$(df --output=avail "$DOCKER_ROOT" | tail -1 | xargs)

if [ "$AVAIL_KB" -lt 2097152 ]; then
  echo "⚠️ Low disk space on $DOCKER_ROOT ($((AVAIL_KB/1024))MB free). Cleaning..."
  docker system prune -af --volumes || true

  AVAIL_KB=$(df --output=avail "$DOCKER_ROOT" | tail -1 | xargs)
fi

if [ "$AVAIL_KB" -lt 1048576 ]; then
  echo "❌ CRITICAL: Still low disk space ($((AVAIL_KB/1024))MB)"
  exit 1
fi

echo "=== Pre-clean Docker ==="
docker system prune -af --volumes || true

echo "=== Pull Docker images ==="
pull_with_fallback() {
  local name="$1"
  local primary="$2"
  local fallback="$3"
  local selected="$primary"

  echo "→ Pulling $name from Artifact Registry: $primary" >&2
  if ! docker pull "$primary" >&2; then
    echo "⚠️ $name Artifact Registry pull failed, falling back to public image" >&2
    selected="$fallback"
    docker pull "$selected" >&2
  fi

  printf "%s" "$selected"
}

N8N_TARGET=$(pull_with_fallback "n8n" "${n8n_ar_image}" "${n8n_image}")
CF_TARGET=$(pull_with_fallback "cloudflared" "${cloudflared_ar_image}" "${cloudflared_image}")
POSTGRES_IMAGE="postgres:15-alpine"
docker pull "$POSTGRES_IMAGE"

cat <<EOF > /home/docker/runtime.env
N8N_TARGET=$N8N_TARGET
CF_TARGET=$CF_TARGET
POSTGRES_IMAGE=$POSTGRES_IMAGE
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PORT=${db_port}
N8N_PUBLIC_HOST=${n8n_public_host}
EOF
chmod 600 /home/docker/runtime.env

# ==========================================
# 8. Start Postgres
# ==========================================
# Write secrets to tmpfs (not written to disk) for Docker _FILE support
umask 077
mkdir -p /dev/shm/n8n-secrets
printf "%s" "$DB_PASSWORD" > /dev/shm/n8n-secrets/db_password
printf "%s" "$N8N_KEY" > /dev/shm/n8n-secrets/n8n_key
printf "%s" "$CF_TOKEN" > /dev/shm/n8n-secrets/cf_token
umask 022

echo "=== Verify Secrets Before Start ==="
for f in db_password n8n_key cf_token; do
  if [ ! -s "/dev/shm/n8n-secrets/$f" ]; then
    echo "❌ Missing secret: $f (secret fetch may have partially failed)"
    exit 1
  fi
done

docker rm -f postgres 2>/dev/null || true 
echo "=== Ensure Docker network ==="
docker network inspect n8n-net >/dev/null 2>&1 || docker network create n8n-net

echo "=== Starting Postgres ==="
docker run -d \
  --name postgres \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -v /mnt/disks/data/postgres:/var/lib/postgresql/data \
  -v /dev/shm/n8n-secrets/db_password:/run/secrets/db_password:ro \
  -e POSTGRES_DB="${db_name}" \
  -e POSTGRES_USER="${db_user}" \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
  --health-cmd="pg_isready -U ${db_user}" \
  --health-interval=5s \
  --health-timeout=3s \
  --health-retries=5 \
  "$POSTGRES_IMAGE"

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
# FAST SKIP: if n8n already initialized the DB, skip restore
SKIP_RESTORE=false
MIGRATIONS_READY=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM migrations;" 2>/dev/null | xargs || echo "")
if [ -n "$MIGRATIONS_READY" ] && [ "$MIGRATIONS_READY" -gt 0 ]; then
  echo "✅ DB already initialized ($MIGRATIONS_READY migrations) → skipping restore"
  SKIP_RESTORE=true
fi

echo "→ Checking if restore is needed"
DB_EXISTS=$(docker exec postgres psql -U "${db_user}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" | xargs)
if [ "$DB_EXISTS" = "1" ]; then
  # Use migrations table as the source of truth — it's populated by n8n on
  # every successful boot regardless of whether the user created workflows.
  MIGRATION_COUNT=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM migrations;" 2>/dev/null | xargs)
  if [ -n "$MIGRATION_COUNT" ] && [ "$MIGRATION_COUNT" -gt 0 ]; then
    # Verify table readability — catches corrupted schema/data
    if docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc \
      "SELECT 1 FROM workflow_entity LIMIT 1;" >/dev/null 2>&1; then
      WORKFLOW_COUNT=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM workflow_entity;" 2>/dev/null | xargs)
      echo "✅ DB populated ($MIGRATION_COUNT migrations, $WORKFLOW_COUNT workflows) → SKIP restore"
      SKIP_RESTORE=true
    else
      echo "⚠️ Migrations exist but workflow_entity unreadable → force restore"
    fi
  fi
fi

if [ "$SKIP_RESTORE" != "true" ]; then
  echo "→ Requesting backup list from GCS..."
  # Refresh token before GCS operations (may have expired during long startup)
  TOKEN=$(get_token)
  BACKUP_INFO=$(timeout 20 curl -sf -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-") || true
  
  echo "→ Backup list received (size: ${#BACKUP_INFO})"
  # Search for both .sql and .sql.gz backups
  LATEST_OBJ=$(echo "$BACKUP_INFO" | grep -o '"name": "[^"]*' | cut -d'"' -f4 | grep -E '\.(sql|sql\.gz)$' | sort | tail -n 1)

  echo "→ Found latest backup: $LATEST_OBJ"
  if [ -n "$LATEST_OBJ" ]; then
    echo "→ Restoring from $LATEST_OBJ"
    OBJ_ENC=$(echo "$LATEST_OBJ" | sed 's/\//%2F/g')
    # Download backup — detect extension for gzip support
    DOWNLOAD_FILE="/home/docker/backup.sql"
    if echo "$LATEST_OBJ" | grep -q '\.gz$'; then
      DOWNLOAD_FILE="/home/docker/backup.sql.gz"
    fi
    timeout 120 curl -sf -H "Authorization: Bearer $TOKEN" \
         "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/$${OBJ_ENC}?alt=media" > "$DOWNLOAD_FILE"

    if [ -s /home/docker/backup.sql ] || [ -s /home/docker/backup.sql.gz ]; then
      # Decompress if gzipped backup
      if [ -s /home/docker/backup.sql.gz ]; then
        echo "Verifying gzip integrity..."
        docker run -i --rm -v /home/docker:/data busybox sh -c 'gunzip -t /data/backup.sql.gz' || { echo "❌ gzip corrupt"; exit 1; }
        echo "Decompressing gzipped backup..."
        docker run -i --rm -v /home/docker:/data busybox gunzip -f /data/backup.sql.gz
      fi

      # Verify checksum if available
      CHECKSUM_OBJ="$LATEST_OBJ.sha256"
      CHECKSUM_ENC=$(echo "$CHECKSUM_OBJ" | sed 's/\//%2F/g')
      if curl -sf -H "Authorization: Bearer $TOKEN" \
           "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/$${CHECKSUM_ENC}?alt=media" > /home/docker/backup.sha256 2>/dev/null; then
        echo "Verifying checksum..."
        (cd /home/docker && sha256sum -c backup.sha256) || { echo "❌ Checksum failed"; exit 1; }
        echo "Checksum OK"
        rm -f /home/docker/backup.sha256
      else
        echo "⚠️ No checksum available, skipping verification"
      fi

      # Ensure DB exists (idempotent — no DROP needed,
      # dump was created with --clean --if-exists so it handles table cleanup)
      docker exec postgres psql -U "${db_user}" -d postgres -c "
      SELECT 'CREATE DATABASE ${db_name}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${db_name}')\gexec
      "

      # Isolate DB during restore — block external connections
      docker exec postgres psql -U "${db_user}" -d postgres -c "
      REVOKE CONNECT ON DATABASE ${db_name} FROM PUBLIC;
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '${db_name}' AND pid <> pg_backend_pid();
      "

      # Use docker cp instead of pipe — more reliable for large dumps
      docker cp /home/docker/backup.sql postgres:/tmp/restore.sql

      RESTORE_SIZE=$(stat -c%s /home/docker/backup.sql 2>/dev/null || echo "unknown")
      echo "Restoring DB ($RESTORE_SIZE bytes)..."
      if ! docker exec postgres psql -U "${db_user}" -d "${db_name}" --single-transaction --set ON_ERROR_STOP=on -f /tmp/restore.sql; then
        echo "❌ Restore failed — cleaning DB for next boot retry"
        docker exec postgres psql -U "${db_user}" -d postgres -c "
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db_name}';
        DROP DATABASE IF EXISTS ${db_name};
        CREATE DATABASE ${db_name};
        ALTER DATABASE ${db_name} CONNECTION LIMIT -1;
        GRANT CONNECT ON DATABASE ${db_name} TO PUBLIC;
        "
        rm -f /home/docker/backup.sql
        exit 1
      fi

      # Post-restore sanity check
      docker exec postgres psql -U "${db_user}" -d "${db_name}" -c "ANALYZE;" 2>/dev/null || true

      MIGRATION_CHECK=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc "SELECT COUNT(*) FROM migrations;" 2>/dev/null | xargs)
      TABLE_CHECK=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tAc \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs)

      if [ -z "$MIGRATION_CHECK" ] || [ "$MIGRATION_CHECK" -lt 1 ] || [ -z "$TABLE_CHECK" ] || [ "$TABLE_CHECK" -lt 5 ]; then
        echo "❌ Restore produced invalid DB (migrations=$MIGRATION_CHECK, tables=$TABLE_CHECK) — cleaning for retry"
        docker exec postgres psql -U "${db_user}" -d postgres -c "
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db_name}';
        DROP DATABASE IF EXISTS ${db_name};
        CREATE DATABASE ${db_name};
        ALTER DATABASE ${db_name} CONNECTION LIMIT -1;
        GRANT CONNECT ON DATABASE ${db_name} TO PUBLIC;
        "
        rm -f /home/docker/backup.sql
        exit 1
      fi
      echo "Sanity check: $MIGRATION_CHECK migrations, $TABLE_CHECK tables OK"

      # Re-enable connections after successful restore
      docker exec postgres psql -U "${db_user}" -d postgres -c "GRANT CONNECT ON DATABASE ${db_name} TO PUBLIC;"
      docker exec postgres rm -f /tmp/restore.sql
      echo "✅ Restore complete"
      rm -f /home/docker/backup.sql
    else
      echo "❌ CRITICAL: Failed to download backup"
      exit 1
    fi
  else
    echo "⚠️ No backups found in ${BACKUP_BUCKET_NAME}; continuing with empty database"
  fi
fi


docker rm -f n8n 2>/dev/null || true
docker network inspect n8n-net >/dev/null 2>&1 || docker network create n8n-net
# ==========================================
# 10. Start n8n
# ==========================================
echo "=== Starting n8n ==="
docker run -d \
  --name n8n \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -v /dev/shm/n8n-secrets:/run/secrets:ro \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT="${db_port}" \
  -e DB_POSTGRESDB_DATABASE="${db_name}" \
  -e DB_POSTGRESDB_USER="${db_user}" \
  -e DB_POSTGRESDB_PASSWORD_FILE=/run/secrets/db_password \
  -e N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_key \
  -e N8N_EXECUTIONS_MODE=regular \
  -e N8N_CONCURRENCY_PRODUCTION_LIMIT=1 \
  -e N8N_LOG_LEVEL=warn \
  -e EXECUTIONS_DATA_SAVE_ON_SUCCESS=none \
  -e EXECUTIONS_DATA_SAVE_ON_ERROR=all \
  -e EXECUTIONS_DATA_PRUNE=true \
  -e EXECUTIONS_DATA_MAX_AGE_HISTORY=24 \
  -e N8N_RUNNERS_ENABLED=true \
  -e N8N_RUNNERS_MODE=internal \
  -e N8N_HOST="${n8n_public_host}" \
  -e N8N_PROTOCOL=https \
  -e WEBHOOK_URL="https://${n8n_public_host}/" \
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
    break
  fi
  echo "⏳ Waiting for n8n ($i/60)..."
  sleep 5
done

if [ "$N8N_READY" != "true" ]; then
  echo "❌ n8n failed to become ready"
  docker logs n8n --tail=50 || true
fi


docker rm -f cloudflared 2>/dev/null || true
docker network inspect n8n-net >/dev/null 2>&1 || docker network create n8n-net

echo "=== Starting cloudflared ==="
docker run -d \
  --name cloudflared \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:2000:2000 \
  -v /dev/shm/n8n-secrets/cf_token:/run/secrets/cf_token:ro \
  "$CF_TARGET" \
  tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run --token-file /run/secrets/cf_token

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
FILE="/tmp/n8n-\$${TIMESTAMP}.sql.gz"

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

# Disk pressure check — abort if <500MB free in /tmp
AVAIL_KB=\$(df --output=avail /tmp | tail -1 | xargs)
if [ "\$AVAIL_KB" -lt 512000 ]; then
  echo "❌ SKIP backup: insufficient disk space (\$${AVAIL_KB}KB free in /tmp)"
  exit 1
fi

BACKUP_START=\$(date +%s)
# Force WAL flush to ensure backup contains latest committed data
docker exec postgres psql -U ${db_user} -d ${db_name} -c "CHECKPOINT;" 2>/dev/null || true
timeout 300 docker exec postgres pg_dump -U ${db_user} --no-owner --no-acl --clean --if-exists --serializable-deferrable --lock-wait-timeout=10000 ${db_name} | gzip > "\$FILE"
BACKUP_DURATION=\$(( \$(date +%s) - BACKUP_START ))
echo "Backup duration: \$${BACKUP_DURATION}s"
if [ ! -s "\$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

(cd /tmp && sha256sum "\$(basename "\$FILE")") > "\$FILE.sha256"

# Upload backup
curl --max-time 300 -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @"\$FILE" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\$${TIMESTAMP}.sql.gz"

# Upload checksum
curl --max-time 60 -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: text/plain" \
     --data-binary @"\$FILE.sha256" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\$${TIMESTAMP}.sql.gz.sha256"

# Verify upload integrity — read back checksum from GCS and compare with local
LOCAL_SUM=\$(cat "\$FILE.sha256" 2>/dev/null || true)
REMOTE_SUM=\$(curl --max-time 60 -sf -H "Authorization: Bearer \$TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/n8n%2Fn8n-\$${TIMESTAMP}.sql.gz.sha256?alt=media" 2>/dev/null || true)
if [ -n "\$REMOTE_SUM" ] && [ -n "\$LOCAL_SUM" ] && [ "\$REMOTE_SUM" != "\$LOCAL_SUM" ]; then
  echo "❌ Checksum mismatch after upload — backup may be corrupt"
  exit 1
fi

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
