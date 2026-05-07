#!/bin/bash

trap 'echo "Graceful shutdown...";

docker stop --time=30 n8n 2>/dev/null || true;
docker stop --time=20 cloudflared 2>/dev/null || true;
docker stop --time=30 postgres 2>/dev/null || true;

exit 0' SIGTERM SIGINT

set -e
set -o pipefail
set -u

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

restore_db() {
  echo "→ Fetching latest backup..."

  TOKEN=$(get_token)

  BACKUP_INFO=$(curl -fs \
    -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/${BACKUP_BUCKET_NAME}/o?prefix=n8n/n8n-" \
    || true)

  LATEST_OBJ=$(echo "$BACKUP_INFO" \
    | grep -o '"name": "[^"]*' \
    | cut -d'"' -f4 \
    | grep -E '\.sql(\.gz)?$' \
    | sort \
    | tail -n 1)

  if [ -z "$LATEST_OBJ" ]; then
    echo "❌ No backup found → cannot restore"
    exit 0
  fi

  echo "→ Latest backup: $LATEST_OBJ"

  RESTORE_FILE="/mnt/disks/data/tmp/restore.sql"
  mkdir -p /mnt/disks/data/tmp

  ENCODED_OBJ=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${LATEST_OBJ}', safe=''))")
  rm -f "$RESTORE_FILE"

  curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/download/storage/v1/b/${BACKUP_BUCKET_NAME}/o/${ENCODED_OBJ}?alt=media" \
    -o "$RESTORE_FILE"

  if [ ! -s "$RESTORE_FILE" ]; then
    echo "❌ Backup empty"
    exit 1
  fi

  echo "→ Resetting DB schema before restore"

  docker exec postgres psql -U "${db_user}" -d "${db_name}" \
    -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

  echo "→ Restoring..."

  if file "$RESTORE_FILE" | grep -q gzip; then
    gunzip -c "$RESTORE_FILE" | timeout 600 docker exec -i postgres psql \
      -U "${db_user}" -d "${db_name}"
  else
    timeout 600 docker exec -i postgres psql \
      -U "${db_user}" -d "${db_name}" < "$RESTORE_FILE"
  fi

  echo "✅ Restore complete"
}

check_db_health() {
  echo "=== DB HEALTH CHECK (optimized) ==="

  RESULT=$(docker exec postgres psql -U "${db_user}" -d "${db_name}" -tA -F',' -c "
SELECT
  EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='migrations'),
  COALESCE((SELECT COUNT(*) FROM migrations), 0),
  EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='workflow_entity'),
  COALESCE((SELECT COUNT(*) FROM workflow_entity), 0),
  EXISTS (SELECT 1 FROM pg_indexes WHERE tablename='workflow_entity' AND indexname LIKE '%pkey%');
" 2>/dev/null || echo "")

  if [ -z "$RESULT" ]; then
    echo "❌ DB connection failed"
    return 1
  fi

  IFS=',' read -r MIG_EXISTS MIG_COUNT WF_EXISTS WF_COUNT PK_EXISTS <<< "$RESULT"

  echo "DEBUG: migrations=$MIG_EXISTS count=$MIG_COUNT workflow=$WF_EXISTS count=$WF_COUNT pk=$PK_EXISTS"

  if [ "$MIG_EXISTS" != "t" ] || [ "$MIG_COUNT" -lt 1 ]; then
    echo "❌ migrations invalid"
    return 1
  fi

  if [ "$WF_EXISTS" != "t" ] || [ "$WF_COUNT" -lt 1 ]; then
    echo "❌ workflow invalid"
    return 1
  fi

  if [ "$PK_EXISTS" != "t" ]; then
    echo "❌ PK missing"
    return 1
  fi

  echo "✅ DB HEALTHY"
  return 0
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
  DATA=$(echo "$RAW" | python3 -c "import sys, json; print(json.load(sys.stdin)['payload']['data'])")

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
  echo "=== Initial Docker bootstrap ==="

  # restart ONLY if docker unhealthy
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon unhealthy → restarting"
    systemctl restart docker
  else
    echo "Docker daemon already healthy"
  fi

  echo "=== Waiting for Docker daemon ==="

  for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
      echo "✅ Docker daemon ready"
      break
    fi

    echo "⏳ Waiting Docker daemon ($i/30)..."
    sleep 2
  done

  echo "=== Waiting for Docker networking ==="

  for i in {1..30}; do
    if docker run --rm --network host mirror.gcr.io/library/busybox true >/dev/null 2>&1; then
      echo "✅ Docker networking ready"
      break
    fi

    echo "⏳ Waiting Docker networking ($i/30)..."
    sleep 2
  done

  ip link set dev eth0 mtu 1460 || true

  touch "$DOCKER_READY_FILE"
  sync

else
  echo "=== Docker already initialized, skipping bootstrap ==="
fi

docker info | grep "Docker Root Dir"



echo "=== Waiting for network ==="
echo "=== Ensuring network OR cached images ==="

if ! docker image inspect mirror.gcr.io/library/busybox >/dev/null 2>&1; then
  echo "No cached image → waiting for network"
  for i in {1..30}; do
  if curl -sf https://registry.npmjs.org >/dev/null && \
     curl -sf https://api.github.com >/dev/null; then
    echo "✅ Network fully ready"
    break
  fi
  echo "⏳ Waiting for full internet connectivity..."
  sleep 2
done
else
  echo "Cached image exists → skip network wait"
fi

docker rm -f health-server 2>/dev/null || true
iptables -I INPUT 1 -p tcp -s 35.191.0.0/16 --dport 8080 -j ACCEPT
iptables -I INPUT 2 -p tcp -s 130.211.0.0/22 --dport 8080 -j ACCEPT

docker run -d \
  --name health-server \
  --network host \
  --restart always \
  python:3-alpine \
  sh -c "python -m http.server 8080"

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

mkdir -p /mnt/disks/data/n8n

# force correct ownership for n8n runtime
chown -R 1000:1000 /mnt/disks/data/n8n

# remove dangerous world-writable perms if they exist
chmod 700 /mnt/disks/data/n8n || true

# verify ownership
N8N_UID=$(stat -c '%u' /mnt/disks/data/n8n)
N8N_GID=$(stat -c '%g' /mnt/disks/data/n8n)

if [ "$N8N_UID" != "1000" ] || [ "$N8N_GID" != "1000" ]; then
  echo "❌ Invalid n8n directory ownership: ${N8N_UID}:${N8N_GID}"
  exit 1
fi

echo "✅ n8n directory ownership verified"

mkdir -p /home/docker/n8n

# ==========================================
# 7. Docker Network + Image Pull
# ==========================================
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net || true

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
if [ -z "$DOCKER_ROOT" ]; then
  DOCKER_ROOT="/mnt/stateful_partition"
  echo "⚠️ Docker not ready, fallback to $DOCKER_ROOT"
fi

echo "Disk check path: $DOCKER_ROOT"
df -h "$DOCKER_ROOT"

AVAIL_KB=$(df --output=avail "$DOCKER_ROOT" | tail -1 | xargs)

if [ "$AVAIL_KB" -lt 2097152 ]; then
  echo "⚠️ Low disk space on $DOCKER_ROOT ($((AVAIL_KB/1024))MB free). Cleaning..."
  docker system prune -af || true
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

  if docker image inspect "$primary" >/dev/null 2>&1; then
    echo "✅ Using cached $name image: $primary" >&2
    printf "%s" "$primary"
    return 0
  fi

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
docker image inspect "$POSTGRES_IMAGE" >/dev/null 2>&1 || docker pull "$POSTGRES_IMAGE"

cat <<EOF > /home/docker/runtime.env
BACKUP_BUCKET=${BACKUP_BUCKET_NAME}
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
umask 077
mkdir -p /dev/shm/n8n-secrets
printf "%s" "$DB_PASSWORD" > /dev/shm/n8n-secrets/db_password
printf "%s" "$N8N_KEY"     > /dev/shm/n8n-secrets/n8n_key


chown -R 1000:1000 /dev/shm/n8n-secrets
chmod 600 /dev/shm/n8n-secrets/*


echo "=== Verify Secrets Before Start ==="
for f in db_password n8n_key; do
  if [ ! -s "/dev/shm/n8n-secrets/$f" ]; then
    echo "❌ Missing secret: $f"
    exit 1
  fi
done

docker rm -f postgres 2>/dev/null || true

echo "=== Ensure Docker network ==="
docker network inspect n8n-net >/dev/null 2>&1 || \
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net

echo "=== Starting Postgres ==="
docker run -d \
  --name postgres \
  --oom-score-adj -900 \
  --stop-timeout 30 \
  --memory="512m" \
  --memory-swap="512m" \
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
for i in {1..30}; do
  if docker exec postgres pg_isready -U "${db_user}" >/dev/null 2>&1; then
    echo "✅ Postgres ready"
    READY=true
    break
  fi
  sleep 2
done


if [ "$READY" != "true" ]; then
  echo "❌ Postgres failed to start"
  docker logs postgres --tail=50 || true
  exit 1
fi

echo "=== DB HEALTH CHECK BEFORE RESTORE ==="

if check_db_health; then
  echo "→ DB healthy → SKIP restore"
else
  echo "→ DB unhealthy → restoring..."
  restore_db
fi



# ==========================================
# 9. Backup Restore (DR only)
# ==========================================



docker rm -f n8n 2>/dev/null || true
docker network inspect n8n-net >/dev/null 2>&1 || \
docker network create --opt com.docker.network.driver.mtu=1460 n8n-net




echo "→ Waiting for Postgres before starting n8n..."

for i in {1..60}; do
  if docker exec postgres pg_isready -U "$db_user" >/dev/null 2>&1; then
    echo "→ Postgres is ready"
    break
  fi
  echo "→ waiting... ($i)"
  sleep 2
done
# ==========================================
# 10. Start n8n (no queue mode, no Redis, no worker)
# ==========================================
echo "=== Starting n8n ==="
#N8N_RUNNER_TOKEN="my-secret-token-12345"
docker run -d \
  --name n8n \
  --oom-score-adj 200 \
  --stop-timeout 30 \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  --memory="900m" \
  --memory-swap="1500m" \
  -v /dev/shm/n8n-secrets:/run/secrets:ro \
  -v /mnt/disks/data/n8n:/home/node/.n8n \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE="${db_name}" \
  -e DB_POSTGRESDB_USER="${db_user}" \
  -e DB_POSTGRESDB_PASSWORD_FILE=/run/secrets/db_password \
  -e N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_key \
  -e N8N_RUNNERS_ENABLED=false \
  -e N8N_RUNNERS_PYTHON_ENABLED=false \
  -e N8N_RUNNERS_JS_ENABLED=false \
  -e N8N_LOG_LEVEL=info \
  -e N8N_GRACEFUL_SHUTDOWN_TIMEOUT=25 \
  -e N8N_PROJECTS_ENABLED=false \
  -e N8N_COLLABORATION_ENABLED=false \
  -e N8N_TEMPLATES_ENABLED=false \
  -e N8N_COMMUNITY_PACKAGES_ENABLED=false \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \
  -e NODE_OPTIONS="--max-old-space-size=512" \
  "$N8N_TARGET"


echo "=== Verifying n8n runtime permissions ==="

docker exec n8n sh -c '
  touch /home/node/.n8n/.permission-test &&
  rm -f /home/node/.n8n/.permission-test
' || {
  echo "❌ n8n cannot write to runtime directory"
  exit 1
}

echo "✅ n8n runtime writable"

echo "=== Waiting for n8n ==="

N8N_READY=false
for startup_retry in {1..60}; do
  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "✅ n8n is ready"
    echo "=== Warming up n8n runners ==="

    for warmup_retry in {1..12}; do
      if curl -sf http://127.0.0.1:5678/rest/settings >/dev/null 2>&1; then
        echo "✅ API ready"
        break
      fi

      echo "⏳ Waiting API warmup ($warmup_retry/12)..."
      sleep 5
    done

sleep 15
    N8N_READY=true
    break
  fi
  echo "⏳ Waiting for n8n ($startup_retry/60)..."
  sleep 5
done

if [ "$N8N_READY" != "true" ]; then
  echo "❌ n8n failed to become ready"
  docker logs n8n --tail=50 || true
  exit 1
fi

# ==========================================
# 11. Start cloudflared
# ==========================================
docker rm -f cloudflared 2>/dev/null || true

mkdir -p /mnt/disks/data/n8n-secrets

echo "=== n8n warmup ==="
sleep 5

echo "=== Starting cloudflared ==="
if [ -z "$CF_TOKEN" ]; then
  echo "❌ CF_TOKEN empty"
  exit 1
fi
docker run -d \
  --name cloudflared \
  --stop-timeout 30 \
  --memory="128m" \
  --memory-swap="128m" \
  --network n8n-net \
  --restart unless-stopped \
  -p 127.0.0.1:2000:2000 \
  "$CF_TARGET" \
  tunnel \
  --grace-period 30s \
  --retries 5 \
  --protocol http2 \
  --metrics 0.0.0.0:2000 \
  run --token "$CF_TOKEN"



# ==========================================
# 12. Final health verification
# ==========================================
echo "=== Final Health Verification ==="
HEALTHY=false
for i in {1..60}; do
  n8n_ok=false
  cf_ok=false

  if curl -sf http://127.0.0.1:5678/healthz | grep -q '"status":"ok"'; then
    n8n_ok=true
  fi
  if docker logs cloudflared 2>&1 | grep -q "Registered tunnel connection"; then
    cf_ok=true
  fi

  if [ "$n8n_ok" = true ] && [ "$cf_ok" = true ]; then
    echo "✅ n8n + cloudflared are healthy"
    HEALTHY=true
    break
  fi
  echo "⏳ Verifying ($i/60)..."
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
cat <<'BACKUPEOF' > /home/docker/backup.sh
#!/bin/bash
set -e
set -u

: "${DB_USER:?missing}"
: "${DB_NAME:?missing}"
: "${BACKUP_BUCKET:?missing}"
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p /mnt/disks/data/tmp
FILE="/mnt/disks/data/tmp/n8n-${TIMESTAMP}.sql.gz"

COUNT=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM workflow_entity;" | xargs)
if [ "$COUNT" -lt 1 ]; then
  echo "⚠️ SKIP backup: no workflows"
  exit 0
fi

SIZE=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT pg_database_size('$DB_NAME');" | xargs)
if [ "$SIZE" -lt 1000000 ]; then
  echo "⚠️ SKIP backup: DB too small ($SIZE bytes)"
  exit 0
fi

AVAIL_KB=$(df --output=avail /tmp | tail -1 | xargs)
if [ "$AVAIL_KB" -lt 512000 ]; then
  echo "❌ SKIP backup: insufficient disk space (${AVAIL_KB}KB free in /tmp)"
  exit 1
fi

BACKUP_START=$(date +%s)
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c "CHECKPOINT;" 2>/dev/null || true
timeout 300 docker exec postgres pg_dump -U "$DB_USER" --no-owner --no-acl --clean --if-exists --serializable-deferrable --lock-wait-timeout=10000 "$DB_NAME" | gzip > "$FILE"
BACKUP_DURATION=$(( $(date +%s) - BACKUP_START ))
echo "Backup duration: ${BACKUP_DURATION}s"

if [ ! -s "$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

cd /mnt/disks/data/tmp
sha256sum "$(basename "$FILE")" > "$FILE.sha256"

curl --max-time 300 -sf -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @"$FILE" \
     "https://storage.googleapis.com/upload/storage/v1/b/"$BACKUP_BUCKET"/o?uploadType=media&name=n8n/n8n-${TIMESTAMP}.sql.gz"

curl --max-time 60 -sf -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: text/plain" \
     --data-binary @"$FILE.sha256" \
     "https://storage.googleapis.com/upload/storage/v1/b/"$BACKUP_BUCKET"/o?uploadType=media&name=n8n/n8n-${TIMESTAMP}.sql.gz.sha256"

LOCAL_SUM=$(cat "$FILE.sha256" 2>/dev/null || true)
REMOTE_SUM=$(curl --max-time 60 -sf -H "Authorization: Bearer $TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/"$BACKUP_BUCKET"/o/n8n%2Fn8n-${TIMESTAMP}.sql.gz.sha256?alt=media" 2>/dev/null || true)
if [ -n "$REMOTE_SUM" ] && [ -n "$LOCAL_SUM" ] && [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
  echo "❌ Checksum mismatch after upload"
  exit 1
fi

rm -f "$FILE" "$FILE.sha256"

CUTOFF_DATE=$(date -d '7 days ago' +%Y%m%d)
OLD_BACKUPS=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/"$BACKUP_BUCKET"/o?prefix=n8n/n8n-" \
  | grep -o '"name": "[^"]*' | cut -d'"' -f4 \
  | grep -E '\.(sql\.gz|sha256)$' || true)

while IFS= read -r obj; do
  FILE_DATE=$(echo "$obj" | grep -o '[0-9]\{8\}' | head -1)
  if [ -n "$FILE_DATE" ] && [ "$FILE_DATE" -lt "$CUTOFF_DATE" ]; then
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$obj', safe=''))")
    curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
      "https://storage.googleapis.com/storage/v1/b/"$BACKUP_BUCKET"/o/${ENCODED}" || true
    echo "Deleted old backup: $obj"
  fi
done <<< "$OLD_BACKUPS"

echo "BACKUP_OK $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
BACKUPEOF

# Inject runtime values into backup.sh

chmod +x /home/docker/backup.sh

cat <<'SVCEOF' > /etc/systemd/system/n8n-backup.service || true
[Unit]
Description=n8n Postgres Backup

[Service]
Type=oneshot
EnvironmentFile=/home/docker/runtime.env
ExecStart=/home/docker/backup.sh
SVCEOF

cat <<'TMREOF' > /etc/systemd/system/n8n-backup.timer || true
[Unit]
Description=Run n8n Backup every 10 min
[Timer]
OnBootSec=15min
OnUnitActiveSec=60min
[Install]
WantedBy=timers.target
TMREOF

systemctl daemon-reload || true
systemctl enable --now n8n-backup.timer || echo "⚠️ systemd timer skipped"

if [ "$HEALTHY" != "true" ]; then
  echo "⚠️ WARNING: not all services healthy at startup end, but continuing"
  echo "=== n8n logs ==="
  docker logs n8n --tail=20 || true
  echo "=== cloudflared logs ==="
  docker logs cloudflared --tail=20 || true
fi

echo "✅ Startup complete"
