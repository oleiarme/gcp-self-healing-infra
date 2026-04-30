#!/bin/bash
set -e
set -o pipefail
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

[ -z "${BACKUP_BUCKET_NAME}" ] && { echo "❌ BACKUP_BUCKET_NAME not set"; exit 1; }

# [FIX 1] Вернуть из PR #10: non-interactive apt.
# Без этого dpkg может EOF'ить на stdin при конфликте conffile и валить
# весь bootstrap. Имена стабильные, чтобы terraform templatefile()
# с двойным $ не поломал рендер.
export DEBIAN_FRONTEND=noninteractive

echo "=== Disable needrestart ==="
export NEEDRESTART_MODE=a
apt-get remove -y needrestart || true

# shellcheck disable=SC2034
APT_INSTALL_OPTS=(-y \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef)

echo "=== Swap ==="
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  if ! swapon --show | grep -q /swapfile; then
  swapon /swapfile
  fi
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

retry() {
  for i in {1..5}; do
    "$@" && return 0
    sleep 5
  done
  return 1
}

echo "=== Install Docker ==="
retry apt-get update
retry apt-get install "$${APT_INSTALL_OPTS[@]}" ca-certificates curl gnupg apt-transport-https
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
retry apt-get update
retry apt-get install "$${APT_INSTALL_OPTS[@]}" --no-install-recommends \
  docker.io cron postgresql-client google-cloud-cli





mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "=== Taming Docker for e2-micro ==="
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
mkdir -p /etc/systemd/system/containerd.service.d

cat <<EOF > /etc/systemd/system/docker.service.d/throttle.conf
[Service]
CPUAccounting=true
TimeoutStartSec=180
EOF

cat <<EOF > /etc/systemd/system/containerd.service.d/throttle.conf
[Service]
CPUAccounting=true
TimeoutStartSec=180
EOF

sysctl -w vm.swappiness=10
systemctl daemon-reload
systemctl restart containerd
sleep 5
retry systemctl restart docker
systemctl enable docker
systemctl enable containerd

echo "=== Waiting for Docker daemon ==="

for i in {1..30}; do
  if docker info >/dev/null 2>&1; then
    echo "✅ Docker is ready"
    break
  fi
  echo "⏳ Waiting for Docker ($i/30)..."
  sleep 2
done
docker info >/dev/null 2>&1 || {
  echo "❌ Docker not ready after 60s"
  exit 1
}

echo "=== Checking GCP metadata (service account) ==="

if ! curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email >/dev/null; then
  echo "❌ No service account attached or metadata unavailable"
  exit 1
fi

echo "=== Waiting for GCP auth ==="

for i in {1..10}; do
  if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "✅ GCP auth ready"
    break
  fi
  echo "⏳ Waiting for GCP auth ($i/10)..."
  sleep 2
done
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
  echo "❌ GCP auth not available"
  exit 1
fi

echo "=== Checking gcloud CLI ==="

if ! command -v gcloud >/dev/null 2>&1; then
  echo "❌ gcloud not installed"
  exit 1
fi

echo "=== Checking Secret Manager access ==="

if ! retry gcloud secrets versions access latest --secret="${DB_SECRET_NAME}" >/dev/null 2>&1; then
  echo "❌ Cannot access Secret Manager"
  exit 1
fi

echo "=== Get Secrets from Secret Manager ==="
DB_PASSWORD=$(retry gcloud secrets versions access latest --secret="${DB_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch DB_PASSWORD"
  exit 1
}

N8N_KEY=$(retry gcloud secrets versions access latest --secret="${N8N_KEY_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch N8N_KEY"
  exit 1
}

CF_TOKEN=$(retry gcloud secrets versions access latest --secret="${CF_TUNNEL_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch CF_TOKEN"
  exit 1
}

echo "✅ All secrets fetched successfully."

echo "=== Mount Persistent Data Disk ==="
# Wait for stateful disk attachment
for i in {1..30}; do
  if [ -b "/dev/disk/by-id/google-n8n-data" ]; then
    echo "✅ Disk attached"
    break
  fi
  echo "⏳ Waiting for disk attachment ($i/30)..."
  sleep 2
done

DATA_DISK="/dev/disk/by-id/google-n8n-data"
if [ ! -b "$DATA_DISK" ]; then
  echo "❌ CRITICAL: Persistent disk not attached"
  exit 1
fi

# Format if empty (first boot of the project)
if ! blkid "$DATA_DISK" | grep -q 'TYPE="ext4"'; then
  echo "Formatting new persistent disk..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK"
fi

mkdir -p /mnt/data
# Check and repair filesystem before mount (protection against corruption)
fsck -a "$DATA_DISK" || true
mount -o discard,defaults "$DATA_DISK" /mnt/data
# Append fstab entry only if not already present (idempotent on reboot)
if ! grep -q 'google-n8n-data' /etc/fstab; then
  echo "/dev/disk/by-id/google-n8n-data /mnt/data ext4 discard,defaults 0 2" >> /etc/fstab
fi

# Ensure postgres directory exists and has correct permissions (postgres user is usually uid 70 in alpine)
mkdir -p /mnt/data/postgres
chown -R 70:70 /mnt/data/postgres

mkdir -p /opt/n8n

echo "=== Install Ops Agent (logging-only, minimal receiver set) ==="
# We deliberately ship a logging-only Ops Agent config. Host-metrics and
# process-metrics receivers from the default config pushed e2-micro over its
# IO budget (see commit 'del ops agent not enouth io' on main). The single
# tail receiver below is what powers the n8n/startup_critical log-based
# metric defined in terraform/monitoring.tf.
mkdir -p /etc/google-cloud-ops-agent
cat <<'EOF' > /etc/google-cloud-ops-agent/config.yaml
logging:
  receivers:
    startup_log:
      type: files
      include_paths:
        - /var/log/startup.log
  service:
    pipelines:
      default_pipeline:
        receivers:
          - startup_log
metrics:
  service:
    pipelines: {}
EOF

# Ops Agent install is non-fatal: the agent is an observability aid, not
# an application dependency, and must never boot-loop the VM on transient
# apt or network errors. `set -e` is suppressed for this block only; any
# failure is logged as a WARNING and the rest of the script continues so
# the n8n container still starts and the GCP health check stays green.
{
  retry curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh &&
    # Сначала добавляем репозиторий БЕЗ установки (убираем --also-install)
    retry bash add-google-cloud-ops-agent-repo.sh &&
    # Устанавливаем принудительно, игнорируя вопросы о конфигах
    retry apt-get install -y -o Dpkg::Options::="--force-confold" google-cloud-ops-agent &&
    systemctl enable --now google-cloud-ops-agent
} || echo "⚠️ WARNING: Ops Agent install failed..."


echo "=== Pre-flight Variables Check ==="

[ -z "${n8n_image}" ] && { echo "❌ n8n_image is empty"; exit 1; }
[ -z "${cloudflared_image}" ] && { echo "❌ cloudflared_image is empty"; exit 1; }

echo "=== Resolve AR Images ==="
# Try Artifact Registry mirror first; fall back to public if missing.
# (AR repo might not exist on the very first terraform apply, or mirror
# might have failed in CI).
N8N_TARGET="${n8n_ar_image}"
gcloud auth configure-docker "${ar_location}-docker.pkg.dev" --quiet

echo "Using AR image: $N8N_TARGET"

CF_TARGET="${cloudflared_ar_image}"
echo "Using AR image: $CF_TARGET"
[ -z "${BACKUP_BUCKET_NAME}" ] && { echo "❌ BACKUP_BUCKET_NAME is empty"; exit 1; }

echo "✅ All required variables present"

# Write .env AFTER AR image resolution so $N8N_TARGET and $CF_TARGET are set
echo "=== Setup Environment ==="
cat <<EOF > /opt/n8n/.env
CF_TOKEN=$CF_TOKEN
N8N_KEY=$N8N_KEY
DB_PASSWORD=$DB_PASSWORD
N8N_IMAGE=$N8N_TARGET
CLOUDFLARED_IMAGE=$CF_TARGET
EOF
chmod 600 /opt/n8n/.env

echo "=== Setup n8n + Cloudflare Tunnel ==="
cd /opt/n8n

cat <<'EOF' > docker-compose.yml
services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    ports:
      - "127.0.0.1:5432:5432"
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: $${DB_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 3s
      retries: 5
    volumes:
      - /mnt/data/postgres:/var/lib/postgresql/data
  n8n:
    image: $${N8N_IMAGE}
    restart: unless-stopped
    ports:
        - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: $${DB_PASSWORD}

      N8N_ENCRYPTION_KEY: $${N8N_KEY}

      N8N_EXECUTIONS_MODE: regular
      
      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
      N8N_LOG_LEVEL: error

      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE_HISTORY: 24

      N8N_RUNNERS_ENABLED: "true"
      N8N_RUNNERS_MODE: internal
      
      N8N_HOST: n8n-gcp.pp.ua
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://n8n-gcp.pp.ua/
      # Disable the telemetry that throws 'track' errors
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PORT: 5678
      N8N_LISTEN_ADDRESS: 0.0.0.0
      DB_POSTGRESDB_CONNECTION_TIMEOUT: 60000
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
      
    healthcheck:
      # 10s matches GCP health check check_interval_sec in terraform/main.tf.
      # GCP probes every 10s; if Docker also checks every 10s there is no
      # stale-health window where GCP reads healthy while n8n is already dead.
      # start_period 420s covers cold DB migrations on e2-micro.
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz || exit 1"]

      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 420s
    depends_on:
      postgres:
        condition: service_healthy
        
  cloudflared:
    image: $${CLOUDFLARED_IMAGE}
    restart: unless-stopped
    command: tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run --token $${CF_TOKEN}
    ports:
      - "127.0.0.1:2000:2000"
    env_file:
      - .env
    depends_on:
      n8n:
        condition: service_healthy
EOF

docker compose config >/dev/null || { echo "❌ Invalid docker-compose.yml"; exit 1; }

echo "=== Cleaning package cache before image pull ==="
apt-get clean
rm -rf /var/lib/apt/lists/*



echo "=== Pulling n8n image ==="
if ! retry timeout 1800 docker pull "$N8N_TARGET"; then
  echo "❌ Docker pull failed after retries: $N8N_TARGET"
  docker info || true
  free -m
  exit 1
fi


echo "=== Pulling cloudflared image ==="
if ! retry timeout 600 docker pull "$CF_TARGET"; then
  echo "❌ Docker pull failed after retries: $CF_TARGET"
  docker info || true
  free -m
  exit 1
fi


echo "=== Starting Containers ==="
echo "=== Starting Postgres ONLY (Phase 1) ==="
# Поднимаем ТОЛЬКО базу, чтобы n8n не успел к ней подключиться
docker compose up -d postgres || {
  echo "❌ docker compose up postgres failed"
  docker compose logs postgres --tail=50
  exit 1
}

echo "=== Waiting for Postgres (strict) ==="
READY=false
for i in {1..60}; do
  if docker compose ps postgres >/dev/null 2>&1 && \
     docker compose exec -T postgres pg_isready -U n8n >/dev/null 2>&1; then
    
    if docker compose exec -T postgres psql -U n8n -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
      echo "✅ Postgres fully ready"
      READY=true
      break
    fi
  fi
  echo "⏳ Waiting for Postgres ($i/60)..."
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "❌ Postgres not ready"
  docker compose logs postgres --tail=50
  exit 1
fi



echo "=== Backup Restore (DR only) ==="
# With a persistent data disk, Postgres data survives VM recreation.
# Restore only runs on first boot (empty PD) or after catastrophic
# disk failure — it is a DR mechanism, not a deploy mechanism.
SKIP_RESTORE=false

echo "=== Checking if DB already has data ==="
DB_EXISTS=$(docker compose exec -T postgres psql -U n8n -d postgres -tAc \
"SELECT 1 FROM pg_database WHERE datname='n8n';" | xargs)

if [ "$DB_EXISTS" = "1" ]; then
  TABLE_EXISTS=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
  "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name='workflow_entity');" 2>/dev/null | xargs)

  if [ "$TABLE_EXISTS" = "t" ]; then
    WORKFLOW_COUNT=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
    "SELECT COUNT(*) FROM workflow_entity;" | xargs)
    echo "Existing workflows: $WORKFLOW_COUNT"

    if [ "$WORKFLOW_COUNT" -gt 0 ]; then
      echo "✅ DB already populated → SKIP restore"
      SKIP_RESTORE=true
    fi
  fi
fi

# Выполняем поиск бэкапа только если решили ресторить
if [ "$SKIP_RESTORE" != "true" ]; then
  echo "=== Selecting valid backup ==="
  echo "=== Checking backup bucket access ==="

  if ! gsutil ls "gs://${BACKUP_BUCKET_NAME}/n8n/" >/dev/null 2>&1; then
  echo "❌ Bucket not accessible"
  exit 1
  fi
  LATEST=$(gsutil ls -l gs://${BACKUP_BUCKET_NAME}/n8n/n8n-*.sql 2>/dev/null | \
  grep -v TOTAL | \
  awk '$1 > 500000 {print $2, $3}' | \
  sort | \
  tail -n 1 | \
  cut -d' ' -f2) || true  

  if [ -z "$LATEST" ]; then
    echo "⚠️ No valid backup found → starting with empty DB"
    SKIP_RESTORE=true
  else
    echo "Selected backup: $LATEST"
    CHECKSUM="$LATEST.sha256"
    FILENAME=$(basename "$LATEST")

    if ! gsutil stat "$CHECKSUM" >/dev/null 2>&1; then
      echo "❌ Checksum missing"
      exit 1
    fi

    echo "Downloading backup..."
    retry gsutil cp "$LATEST" "/tmp/$FILENAME"
    if [ ! -s "/tmp/$FILENAME" ]; then
      echo "❌ Backup file is empty"
      exit 1
    fi
    retry gsutil cp "$CHECKSUM" "/tmp/$FILENAME.sha256"

    echo "Verifying checksum..."
    if ! (cd /tmp && sha256sum -c "$FILENAME.sha256"); then
      echo "❌ Checksum failed"
      exit 1
    fi
    echo "Checksum OK"

    echo "Dropping DB..."
    docker compose exec -T postgres psql -U n8n -d postgres -c "DROP DATABASE IF EXISTS n8n;"
    docker compose exec -T postgres psql -U n8n -d postgres -c "CREATE DATABASE n8n;"

    echo "Restoring DB..."
    if ! cat "/tmp/$FILENAME" | docker compose exec -T postgres \
      psql -U n8n -d n8n \
      --single-transaction \
      --set ON_ERROR_STOP=on; then      
      echo "❌ Restore failed"
      exit 1
    fi
    echo "✅ Restore complete"
    rm -f "/tmp/$FILENAME" "/tmp/$FILENAME.sha256"
  fi
fi

echo "=== Starting Application Containers (Phase 2) ==="
# ТЕПЕРЬ безопасно поднимаем n8n и cloudflared
docker compose up -d n8n cloudflared || {
  echo "❌ docker compose up apps failed"
  docker compose logs --tail=100
  exit 1
}

echo "=== Starting Health Check Server (port 8080) ==="

cat <<'EOF' > /opt/health_server.py
import http.server
import socketserver
import subprocess
import time

START_TIME = time.time()
BOOTSTRAP_WINDOW = 1800  # 30 minutes — matches MIG initial_delay_sec

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        uptime = time.time() - START_TIME

        try:
            # check n8n
            n8n = subprocess.run(
                ["curl", "-sf", "http://127.0.0.1:5678/healthz"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )

            # check postgres
            pg = subprocess.run(
                ["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "n8n"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )

            ready = (n8n.returncode == 0 and pg.returncode == 0)

        except Exception:
            ready = False

        # 🔹 Phase 1: bootstrap
        if not ready and uptime < BOOTSTRAP_WINDOW:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"BOOTSTRAP")
            return

        # 🔹 Phase 2: real state
        if ready:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"FAIL")



with socketserver.TCPServer(("", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF

nohup python3 /opt/health_server.py >/var/log/health.log 2>&1 &

echo "=== Waiting for n8n readiness ==="

for i in {1..60}; do
  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "✅ n8n is ready"
    break
  fi

  echo "⏳ Waiting for n8n ($i/60)..."
  sleep 5
done

echo "=== Verifying n8n startup ==="


HEALTHY=false
last_fail="both n8n and cloudflared"

for i in {1..60}; do
  n8n_ok=false
  cf_ok=false

  # Проверяем, что контейнеры вообще запущены
  n8n_running=false
  cf_running=false

  # n8n container state 
  n8n_container=$(docker compose ps -q n8n 2>/dev/null)
  if [ -n "$n8n_container" ] && \
   docker inspect -f '{{.State.Running}}' "$n8n_container" | grep -q true; then
  n8n_running=true
  fi

  # cloudflared container state
  cf_container=$(docker compose ps -q cloudflared 2>/dev/null)
  if [ -n "$cf_container" ] && \
    docker inspect -f '{{.State.Running}}' "$cf_container" | grep -q true; then
    cf_running=true
  fi

  # Проверка n8n
  if [ "$n8n_running" = true ] && \
     curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    n8n_ok=true
  fi

  # Проверка cloudflared
  if [ "$cf_running" = true ] && \
     curl -fsS http://127.0.0.1:2000/ready >/dev/null 2>&1; then
    cf_ok=true
  fi

  # Успех
  if [ "$n8n_ok" = true ] && [ "$cf_ok" = true ]; then
    echo "✅ n8n + cloudflared are up and healthy"
    HEALTHY=true
    break
  fi

  # Диагностика
  if [ "$n8n_running" = false ] || [ "$cf_running" = false ]; then
    last_fail="containers not running"
  elif [ "$n8n_ok" = false ] && [ "$cf_ok" = false ]; then
    last_fail="both n8n and cloudflared"
  elif [ "$n8n_ok" = false ]; then
    last_fail="n8n"
  else
    last_fail="cloudflared"
  fi

  echo "⏳ Waiting ($i/60): $last_fail..."
  sleep 10
done

if [ "$HEALTHY" = true ]; then
  echo "=== Startup complete ==="
  docker compose ps
  
else
  echo "❌ CRITICAL: startup failed — $last_fail did not become healthy within 10 minutes"

  echo "=== n8n logs ==="
  docker compose logs --tail=50 n8n

  echo "=== cloudflared logs ==="
  docker compose logs --tail=50 cloudflared

  exit 1
fi

echo "=== Setup Backup Cron ==="

cat <<'EOF' > /usr/local/bin/backup.sh
#!/bin/bash
set -e
cd /opt/n8n || exit 1

retry() {
  for i in {1..5}; do
    "$@" && return 0
    sleep 5
  done
  return 1
}

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILE="/tmp/n8n-$${TIMESTAMP}.sql"
CHECKSUM_FILE="$${FILE}.sha256"

POSTGRES_CONTAINER=$(docker ps -qf name=postgres)
if [ -z "$POSTGRES_CONTAINER" ]; then
  echo "❌ Postgres container not found"
  exit 1
fi

echo "=== Checking DB before backup ==="

COUNT=$(docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -t -c "SELECT count(*) FROM workflow_entity;" | xargs)
echo "Workflow count: $COUNT"

SIZE=$(docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -t -c "SELECT pg_database_size('n8n');" | xargs)

echo "DB size: $SIZE"

if [ "$COUNT" -lt 1 ] || [ "$SIZE" -lt 1000000 ]; then
  echo "⚠️ SKIP backup: invalid DB (count=$COUNT size=$SIZE)"
  exit 0
fi

timeout 300 docker exec "$POSTGRES_CONTAINER" pg_dump -U n8n --no-owner --no-acl --clean --if-exists n8n > "$FILE"
if [ ! -s "$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

(cd /tmp && sha256sum "$(basename "$FILE")") > "$CHECKSUM_FILE"

SUCCESS=false
for i in {1..3}; do
  if gsutil cp "$FILE" gs://${BACKUP_BUCKET_NAME}/n8n/; then
    SUCCESS=true
    break
  fi
  sleep 5
done

if [ "$SUCCESS" != "true" ]; then
  echo "❌ BACKUP FAILED"
  exit 1
fi

CHECKSUM_OK=false
for i in {1..3}; do
  if gsutil cp "$CHECKSUM_FILE" gs://${BACKUP_BUCKET_NAME}/n8n/; then
    CHECKSUM_OK=true
    break
  fi
  sleep 5
done

if [ "$CHECKSUM_OK" != "true" ]; then
  echo "❌ CHECKSUM UPLOAD FAILED"
  exit 1
fi

rm -f "$FILE" "$CHECKSUM_FILE"

echo "BACKUP_OK $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EOF

chmod +x /usr/local/bin/backup.sh

echo "*/10 * * * * root BACKUP_BUCKET_NAME=${BACKUP_BUCKET_NAME} flock -n /tmp/n8n-backup.lock /usr/local/bin/backup.sh > /var/log/n8n-backup.log 2>&1" > /etc/cron.d/n8n-backup
systemctl restart cron

echo "=== ALL DONE ==="
exit 0