#!/bin/bash
set -e
set -o pipefail
set -u
trap 'rm -rf /dev/shm/n8n-secrets/ 2>/dev/null || true' EXIT
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

echo "Starting n8n on COS..."

# ==========================================
# CONFIG FROM GCP METADATA
# ==========================================
get_custom_meta() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

get_required_meta() {
  local key="$1"
  local val
  val=$(get_custom_meta "$key")

  if [ -z "$val" ]; then
    echo "❌ Missing metadata: $key"
    exit 1
  fi

  echo "$val"
}

echo "=== Loading Configuration ==="

db_user=$(get_required_meta "config_db_user")
db_name=$(get_required_meta "config_db_name")
DB_SECRET_NAME=$(get_required_meta "config_db_secret")
N8N_KEY_SECRET_NAME=$(get_required_meta "config_n8n_key_secret")
CF_TUNNEL_SECRET_NAME=$(get_required_meta "config_cf_token_secret")

n8n_image=$(get_required_meta "config_n8n_image")
cloudflared_image=$(get_required_meta "config_cloudflared_image")

n8n_ar_image=$(get_required_meta "config_n8n_ar_image")
cloudflared_ar_image=$(get_required_meta "config_cf_ar_image")

db_port=$(get_required_meta "config_db_port")
n8n_public_host=$(get_required_meta "config_n8n_host")
BACKUP_BUCKET_NAME=$(get_required_meta "config_backup_bucket")

echo "CONFIG LOADED: db=$db_name user=$db_user host=$n8n_public_host"

# ==========================================
# 0. Utility functions
# ==========================================

touch_progress_safe() {
  echo "$(date +%s)" > /tmp/health_progress 2>/dev/null || true
}
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
  local PROJECT_ID=$(get_metadata "project/project-id")

  if [ -z "$PROJECT_ID" ]; then
    echo "❌ project_id is empty"
    return 1
  fi

  local TOKEN=$(get_token)
  local RAW
  RAW=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
     "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_NAME}/versions/latest:access")
  DATA=$(printf '%s' "$RAW" | sed -n 's/.*"data": "\([^"]*\)".*/\1/p')

  if [ -z "$DATA" ]; then
    echo "❌ Secret $SECRET_NAME is empty or invalid"
    return 1
  fi

  echo "$DATA" | base64 -d
} 




mkdir -p /mnt/stateful_partition/docker

cat <<EOF > /etc/docker/daemon.json
{
  "data-root": "/mnt/stateful_partition/docker",
  "mtu": 1460,
  "max-concurrent-downloads": 3,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF


DOCKER_READY_FILE="/var/run/docker-initialized"

if [ ! -f "$DOCKER_READY_FILE" ]; then
  echo "=== Initial Docker restart ==="
  systemctl restart docker

  for i in {1..30}; do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done

  sleep 5
  touch "$DOCKER_READY_FILE"
  ip link set dev eth0 mtu 1460 || true
else
  echo "=== Docker already initialized, skipping restart ==="
fi

docker info | grep "Docker Root Dir"



# ==========================================
# 3. Health server (AFTER Docker restart)
# ==========================================
echo "=== Starting Early Health Check Server (port 8080) ==="
cat <<EOF > /tmp/health_server.py
import http.server
import socketserver
import time
import socket
import urllib.request

START_TIME = time.time()
BOOTSTRAP_WINDOW = 1800
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

        
        if uptime < BOOTSTRAP_WINDOW:
            touch_progress()

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
  docker.io/library/python:3-alpine python3 /health_server.py

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
echo "=== Setup Swap on persistent disk ==="
SWAP_FILE="/mnt/disks/data/swapfile"
if [ ! -f "$SWAP_FILE" ]; then
  fallocate -l 2G "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
fi
if ! swapon --show | grep -q "$SWAP_FILE"; then
  swapon "$SWAP_FILE"
fi
sysctl -w vm.swappiness=10
mkdir -p /home/docker/n8n

# ==========================================
# 7. Docker Network + Image Pull
# ==========================================
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net || true

# === Disk check (COS-aware) -- ===

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


echo "=== Docker auth for Artifact Registry (COS-safe) ==="
TOKEN=$(get_token)

if [ -n "${n8n_ar_image:-}" ]; then
  AR_DOMAIN=$(echo "${n8n_ar_image}" | cut -d'/' -f1)

  mkdir -p /mnt/stateful_partition/docker-config
  export DOCKER_CONFIG=/mnt/stateful_partition/docker-config

  AUTH=$(printf "oauth2accesstoken:%s" "$TOKEN" | base64 -w 0)

  cat > "$DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {
    "${AR_DOMAIN}": {
      "auth": "${AUTH}"
    }
  }
}
EOF

  echo "✅ Docker auth configured for ${AR_DOMAIN}"
else
  echo "⚠️ n8n_ar_image not set → skipping AR auth"
fi


echo "=== Pull Docker images ==="
pull_with_fallback() {
  local name="$1"
  local primary="$2"
  local fallback="$3"
  local selected="$primary"

  echo "→ Pulling $name from Artifact Registry: $primary" >&2
  
  for i in 1 2 3; do
    if timeout 1800 docker pull "$primary" >&2; then
      echo "✅ Pulled $name from AR (attempt $i)" >&2
      printf "%s" "$primary"
      return 0
    fi

    echo "⚠️ Pull failed (attempt $i), cleaning broken layers..." >&2
    docker image rm -f "$primary" >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
    sleep 3
  done

  echo "⚠️ $name AR pull failed, falling back to public image" >&2
  selected="$fallback"

  if ! timeout 1800 docker pull "$selected" >&2; then
    echo "❌ CRITICAL: fallback pull also failed" >&2
    exit 1
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
docker network inspect n8n-net >/dev/null 2>&1 || \
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net || true

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
for i in {1..180}; do
  if docker exec postgres pg_isready -U "${db_user}" >/dev/null 2>&1; then
    if docker exec postgres psql -U "${db_user}" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
      echo "✅ Postgres fully ready"
      READY=true
      break
    fi
  fi
  echo "⏳ Waiting for Postgres ($i/180)..."
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
SKIP_RESTORE=false

echo "→ Checking DB state..."
touch_progress_safe

# --- 1. Check DB exists ---
DB_EXISTS=$(timeout 5s docker exec postgres psql \
  -U "${db_user}" \
  -d postgres \
  -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" \
  2>/dev/null | xargs || echo "")

echo "DEBUG: DB_EXISTS=$DB_EXISTS"

if [ "$DB_EXISTS" = "1" ]; then
  echo "→ DB exists. Checking schema integrity..."

  # --- 2. Check migrations table exists (SAFE) ---
  MIGRATIONS_TABLE_EXISTS=$(timeout 5s docker exec postgres psql \
    -U "${db_user}" \
    -d "${db_name}" \
    -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='migrations';" \
    2>/dev/null | xargs || echo "")

  echo "DEBUG: MIGRATIONS_TABLE_EXISTS=$MIGRATIONS_TABLE_EXISTS"

  if [ "$MIGRATIONS_TABLE_EXISTS" = "1" ]; then

    # --- 3. Count migrations ---
    MIGRATION_COUNT=$(timeout 5s docker exec postgres psql \
      -U "${db_user}" \
      -d "${db_name}" \
      -tAc "SELECT COUNT(*) FROM migrations;" \
      2>/dev/null | xargs || echo "0")

    echo "DEBUG: MIGRATION_COUNT=$MIGRATION_COUNT"

    if [ "$MIGRATION_COUNT" -gt 0 ] 2>/dev/null; then

      # --- 4. Check workflow_entity table exists ---
      WORKFLOW_TABLE_EXISTS=$(timeout 15s docker exec postgres psql \
        -U "${db_user}" \
        -d "${db_name}" \
        -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='workflow_entity';" \
        2>/dev/null | xargs || echo "")

      echo "DEBUG: WORKFLOW_TABLE_EXISTS=$WORKFLOW_TABLE_EXISTS"

      if [ "$WORKFLOW_TABLE_EXISTS" = "1" ]; then

        # --- 5. Count workflows ---
        WORKFLOW_COUNT=$(timeout 5s docker exec postgres psql \
          -U "${db_user}" \
          -d "${db_name}" \
          -tAc "SELECT COUNT(*) FROM workflow_entity;" \
          2>/dev/null | xargs || echo "0")

        echo "DEBUG: WORKFLOW_COUNT=$WORKFLOW_COUNT"

        if [ "$WORKFLOW_COUNT" -gt 0 ] 2>/dev/null; then
          echo "✅ DB healthy ($MIGRATION_COUNT migrations, $WORKFLOW_COUNT workflows) → SKIP restore"
          SKIP_RESTORE=true
        else
          echo "⚠️ workflow_entity empty → restore required"
        fi

      else
        echo "⚠️ workflow_entity table missing → restore required"
      fi

    else
      echo "⚠️ migrations table empty → restore required"
    fi

  else
    echo "⚠️ migrations table missing → restore required"
  fi

else
  echo "⚠️ DB does not exist → restore required"
fi

touch_progress_safe

# ==========================================
# RESTORE ENTRY POINT (single gate)
# ==========================================
Да, меняем весь блок целиком. Вот финальная версия — просто замени всё от if [ "$SKIP_RESTORE" != "true" ]; then до закрывающего fi:

bash
if [ "$SKIP_RESTORE" != "true" ]; then
  echo "→ DB not healthy or missing → restore required"
  echo "=== ENTER RESTORE BLOCK ==="
  touch_progress_safe

  echo "→ Requesting backup list from GCS..."
  TOKEN=$(get_token)

  BACKUP_INFO=$(timeout 20 curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-") || true

  if [ -z "$BACKUP_INFO" ]; then
    echo "⚠️ EMPTY BACKUP RESPONSE — skipping restore"
    touch_progress_safe
  else
    echo "DEBUG: BACKUP_INFO length=${#BACKUP_INFO}"
    echo "$BACKUP_INFO" | head -c 300 || true
    touch_progress_safe

    LATEST_OBJ=$(echo "$BACKUP_INFO" \
      | grep -o '"name": "[^"]*' \
      | cut -d'"' -f4 \
      | grep -E '\.(sql|sql\.gz)$' \
      | sort \
      | tail -n 1)

    echo "→ Found latest backup: $LATEST_OBJ"

    if [ -z "$LATEST_OBJ" ]; then
      echo "⚠️ No backup files found in GCS → skipping restore"
    else
      RESTORE_FILE="/mnt/disks/data/tmp/restore.sql"
      mkdir -p /mnt/disks/data/tmp

      # --- 1. Скачиваем файл ---
      echo "→ Downloading backup: $LATEST_OBJ"
      ENCODED_OBJ=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${LATEST_OBJ}', safe=''))")
      TOKEN=$(get_token)
      curl -sf --max-time 600 \
        -H "Authorization: Bearer $TOKEN" \
        "https://storage.googleapis.com/download/storage/v1/b/${BACKUP_BUCKET_NAME}/o/${ENCODED_OBJ}?alt=media" \
        -o "$RESTORE_FILE"

      if [ ! -s "$RESTORE_FILE" ]; then
        echo "❌ Downloaded backup is empty"
        exit 1
      fi
      echo "✅ Backup downloaded ($(du -sh "$RESTORE_FILE" | cut -f1))"

      # --- 2. Проверяем checksum (после скачивания) ---
      CHECKSUM_OBJ="${LATEST_OBJ}.sha256"
      ENCODED_CS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${CHECKSUM_OBJ}', safe=''))")
      TOKEN=$(get_token)
      REMOTE_SUM=$(curl -sf --max-time 30 \
        -H "Authorization: Bearer $TOKEN" \
        "https://storage.googleapis.com/download/storage/v1/b/${BACKUP_BUCKET_NAME}/o/${ENCODED_CS}?alt=media" \
        2>/dev/null || true)

      if [ -n "$REMOTE_SUM" ]; then
        LOCAL_SUM=$(sha256sum "$RESTORE_FILE" | awk '{print $1}')
        if [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
          echo "❌ Checksum mismatch — backup corrupt"
          rm -f "$RESTORE_FILE"
          exit 1
        fi
        echo "✅ Checksum verified"
      else
        echo "⚠️ No checksum file found — skipping verification"
      fi

      # --- 3. Определяем формат и восстанавливаем ---
      echo "→ Detecting backup format..."
      if file "$RESTORE_FILE" | grep -q 'gzip'; then
        echo "→ Format: gzip compressed SQL"
        if ! gunzip -c "$RESTORE_FILE" | docker exec -i postgres psql \
            -U "${db_user}" -d "${db_name}" --set ON_ERROR_STOP=on; then
          echo "❌ Restore failed"
          rm -f "$RESTORE_FILE"
          exit 1
        fi
      else
        echo "→ Format: plain SQL"
        if ! docker exec -i postgres psql \
            -U "${db_user}" -d "${db_name}" --set ON_ERROR_STOP=on < "$RESTORE_FILE"; then
          echo "❌ Restore failed"
          rm -f "$RESTORE_FILE"
          exit 1
        fi
      fi

      rm -f "$RESTORE_FILE"
      echo "✅ Restore completed"
      touch_progress_safe
    fi
  fi
fi

docker rm -f n8n 2>/dev/null || true
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net || true
# ==========================================
# 10. Start n8n
# ==========================================
echo "=== Starting n8n ==="
docker run -d \
  --name n8n \
  --network n8n-net \
  --restart unless-stopped \
  --memory 400m \
  --memory-swap 600m \
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
  -e NODE_OPTIONS="--max-old-space-size=256" \
  -e N8N_LISTEN_ADDRESS=0.0.0.0 \
  -e DB_POSTGRESDB_CONNECTION_TIMEOUT=60000 \
  "$N8N_TARGET"

# ==========================================
# 11. Wait for n8n, then start cloudflared
# ==========================================
echo "=== Waiting for n8n ==="
N8N_READY=false
for i in {1..180}; do
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
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net || true

echo "=== Starting cloudflared ==="
docker run -d \
  --name cloudflared \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:2000:2000 \
  -e TUNNEL_TOKEN="$(cat /dev/shm/n8n-secrets/cf_token)" \
  "$CF_TARGET" \
  tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run
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
mkdir -p /mnt/disks/data/tmp
FILE="/mnt/disks/data/tmp/n8n-\${TIMESTAMP}.sql.gz"

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
  echo "❌ SKIP backup: insufficient disk space (\${AVAIL_KB}KB free in /tmp)"
  exit 1
fi

BACKUP_START=\$(date +%s)
# Force WAL flush to ensure backup contains latest committed data
docker exec postgres psql -U ${db_user} -d ${db_name} -c "CHECKPOINT;" 2>/dev/null || true
timeout 300 docker exec postgres pg_dump -U ${db_user} --no-owner --no-acl --clean --if-exists --serializable-deferrable --lock-wait-timeout=10000 ${db_name} | gzip > "\$FILE"
BACKUP_DURATION=\$(( \$(date +%s) - BACKUP_START ))
echo "Backup duration: \${BACKUP_DURATION}s"
if [ ! -s "\$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

cd /mnt/disks/data/tmp
sha256sum "\$(basename \"\$FILE\")" > "\$FILE.sha256"

# Upload backup
curl --max-time 300 -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @"\$FILE" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\${TIMESTAMP}.sql.gz"

# Upload checksum
curl --max-time 60 -sf -X POST -H "Authorization: Bearer \$TOKEN" \
     -H "Content-Type: text/plain" \
     --data-binary @"\$FILE.sha256" \
     "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET_NAME}/o?uploadType=media&name=n8n/n8n-\${TIMESTAMP}.sql.gz.sha256"

# Verify upload integrity — read back checksum from GCS and compare with local
LOCAL_SUM=\$(cat "\$FILE.sha256" 2>/dev/null || true)
REMOTE_SUM=\$(curl --max-time 60 -sf -H "Authorization: Bearer \$TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/n8n%2Fn8n-\${TIMESTAMP}.sql.gz.sha256?alt=media" 2>/dev/null || true)
if [ -n "\$REMOTE_SUM" ] && [ -n "\$LOCAL_SUM" ] && [ "\$REMOTE_SUM" != "\$LOCAL_SUM" ]; then
  echo "❌ Checksum mismatch after upload — backup may be corrupt"
  exit 1
fi

rm -f "\$FILE" "\$FILE.sha256"
CUTOFF_DATE=\$(date -d '7 days ago' +%Y%m%d)
OLD_BACKUPS=\$(curl -sf -H "Authorization: Bearer \$TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-" \
  | grep -o '"name": "[^"]*' | cut -d'"' -f4 \
  | grep -E '\.(sql\.gz|sha256)$' || true)
  

# Фильтруем по дате имени файла
while IFS= read -r obj; do
  FILE_DATE=\$(echo "\$obj" | grep -o '[0-9]\{8\}' | head -1)
  if [ -n "\$FILE_DATE" ] && [ "\$FILE_DATE" -lt "\$CUTOFF_DATE" ]; then
    ENCODED=\$(python3 -c "import urllib.parse; print(urllib.parse.quote('\$obj', safe=''))")
    curl -sf -X DELETE -H "Authorization: Bearer \$TOKEN" \
      "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o/\${ENCODED}" || true
    echo "Deleted old backup: \$obj"
  fi
done <<< "\$OLD_BACKUPS"
echo "BACKUP_OK \$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
EOF
chmod +x /home/docker/backup.sh

cat <<'SVCEOF' > /etc/systemd/system/n8n-backup.service || true
[Unit]
Description=n8n Postgres Backup
[Service]
Type=oneshot
ExecStart=/home/docker/backup.sh
SVCEOF

cat <<'TMREOF' > /etc/systemd/system/n8n-backup.timer || true
[Unit]
Description=Run n8n Backup every 10 min
[Timer]
OnBootSec=15min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
TMREOF

systemctl daemon-reload || true
systemctl enable --now n8n-backup.timer || echo "⚠️ systemd timer skipped"

echo "=== ALL DONE ==="
if [ "$HEALTHY" != "true" ]; then
  echo "❌ Instance not healthy → forcing recreate"
  exit 1
fi



exit 0
