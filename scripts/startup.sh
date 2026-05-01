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
apt-get purge -y needrestart || true

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

echo "=== Starting Early Health Check Server (port 8080) ==="
# We start it as early as possible to prevent MIG autohealer from killing the VM
# while it's still doing heavy apt-get/docker-pull operations.
cat <<'EOF' > /opt/health_server.py
import http.server
import socketserver
import subprocess
import time
import os

START_TIME = time.time()
BOOTSTRAP_WINDOW = 1200  # 20 minutes — covers docker install (~12 min) + margin
STALL_TIMEOUT = 300       # 5 minutes — if no progress after bootstrap window, report STALLED
MAX_BOOT_TIME = 1800      # 30 minutes — absolute cap; prevents eternal bootstrap
LAST_PROGRESS_FILE = '/tmp/health_progress'

def touch_progress():
    with open(LAST_PROGRESS_FILE, 'w') as f:
        f.write(str(time.time()))

def get_last_progress():
    try:
        with open(LAST_PROGRESS_FILE) as f:
            return float(f.read().strip())
    except Exception:
        return START_TIME

import socket
import urllib.request

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
            # check n8n via HTTP to ensure it's actually ready, postgres via TCP
            n8n_ok = check_http("http://127.0.0.1:5678/healthz")
            pg_ok = check_port(5432)

            ready = (n8n_ok and pg_ok)

            # Track progress — any partial readiness counts
            if n8n_ok or pg_ok:
                touch_progress()

        except Exception:
            ready = False

        # Hard cap — never stay in bootstrap forever
        if not ready and uptime > MAX_BOOT_TIME:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"HARD_FAIL")
            return

        # Phase 1: bootstrap — return 200 during initial window
        if not ready and uptime < BOOTSTRAP_WINDOW:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"BOOTSTRAP")
            return

        # Phase 2: stall detection — if past bootstrap window and no recent progress
        if not ready:
            since_progress = time.time() - get_last_progress()
            if since_progress > STALL_TIMEOUT:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b"STALLED")
                return
            # Still some recent progress, give more time
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"BOOTSTRAP")
            return

        # Phase 3: fully ready
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

with ThreadingTCPServer(("", 8080), Handler) as httpd:
    httpd.serve_forever()
EOF

cat <<'SVCEOF' > /etc/systemd/system/health-server.service
[Unit]
Description=Early Health Check Server

[Service]
ExecStart=/usr/bin/python3 /opt/health_server.py
Restart=always
StandardOutput=append:/var/log/health.log
StandardError=append:/var/log/health.log

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now health-server.service

echo "=== Install Docker & Tools ==="
echo 'DPkg::Options { "--force-confdef"; "--force-confold"; };' > /etc/apt/apt.conf.d/local
retry timeout 300 apt-get update -o Acquire::Retries=3 -o Acquire::http::Pipeline-Depth=0
retry timeout 300 apt-get install "$${APT_INSTALL_OPTS[@]}" --no-install-recommends \
  -o Acquire::Retries=3 \
  ca-certificates curl gnupg docker.io cron postgresql-client

# Only install gcloud if not already present
if ! command -v gcloud >/dev/null 2>&1; then
  echo "=== Install Google Cloud CLI ==="
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
  gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
  (
    set +e
    if retry timeout 300 apt-get install "$${APT_INSTALL_OPTS[@]}" --no-install-recommends google-cloud-cli; then
      echo "✅ gcloud installed successfully"
    else
      echo "⚠️ gcloud install failed (will retry check later)"
    fi
  )
fi





mkdir -p /usr/local/lib/docker/cli-plugins
(
  curl -SL https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose &&
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
) &

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


echo "=== Waiting for gcloud ==="
for i in {1..30}; do
  if command -v gcloud >/dev/null 2>&1; then
    echo "✅ gcloud ready"
    break
  fi
  sleep 2
done
if ! command -v gcloud >/dev/null 2>&1; then
  echo "❌ gcloud not installed after wait"
  exit 1
fi

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

# Guard against truncated secrets (network flap during fetch)
if [ -z "$DB_PASSWORD" ] || [ -z "$N8N_KEY" ] || [ -z "$CF_TOKEN" ]; then
  echo "❌ One or more secrets are empty (possible truncated fetch)"
  exit 1
fi
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



echo "=== Pre-flight Variables Check ==="

[ -z "${n8n_image}" ] && { echo "❌ n8n_image is empty"; exit 1; }
[ -z "${cloudflared_image}" ] && { echo "❌ cloudflared_image is empty"; exit 1; }

echo "=== Resolve AR Images ==="
# Try Artifact Registry mirror first; fall back to public if missing.
# (AR repo might not exist on the very first terraform apply, or mirror
# might have failed in CI).
N8N_TARGET="${n8n_ar_image}"
if ! gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://${ar_location}-docker.pkg.dev 2>/dev/null; then
  echo "⚠️ AR login failed, fallback to public images expected"
fi

# fallback if AR image not yet available (race condition with CI mirror)
if ! retry docker manifest inspect "$N8N_TARGET" >/dev/null 2>&1; then
  echo "⚠️ AR miss for n8n → fallback to public"
  N8N_TARGET="${n8n_image}"
fi

echo "Using AR image: $N8N_TARGET"

CF_TARGET="${cloudflared_ar_image}"
# fallback if AR image not yet available (race condition with CI mirror)
if ! retry docker manifest inspect "$CF_TARGET" >/dev/null 2>&1; then
  echo "⚠️ AR miss for cloudflared → fallback to public"
  CF_TARGET="${cloudflared_image}"
fi

echo "Using AR image: $CF_TARGET"

[ -z "${BACKUP_BUCKET_NAME}" ] && { echo "❌ BACKUP_BUCKET_NAME is empty"; exit 1; }

echo "✅ All required variables present"

# Write secrets to tmpfs (not written to disk) for Docker _FILE support
umask 077
mkdir -p /dev/shm/n8n-secrets
printf "%s" "$DB_PASSWORD" > /dev/shm/n8n-secrets/db_password
printf "%s" "$N8N_KEY" > /dev/shm/n8n-secrets/n8n_key
printf "%s" "$CF_TOKEN" > /dev/shm/n8n-secrets/cf_token
umask 022

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
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 3s
      retries: 5
    volumes:
      - /mnt/data/postgres:/var/lib/postgresql/data
      - /dev/shm/n8n-secrets/db_password:/run/secrets/db_password:ro
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
      DB_POSTGRESDB_PASSWORD_FILE: /run/secrets/db_password

      N8N_ENCRYPTION_KEY_FILE: /run/secrets/n8n_key

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
    volumes:
      - /dev/shm/n8n-secrets:/run/secrets:ro
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
    command: tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run --token-file /run/secrets/cf_token
    ports:
      - "127.0.0.1:2000:2000"
    volumes:
      - /dev/shm/n8n-secrets/cf_token:/run/secrets/cf_token:ro
    depends_on:
      n8n:
        condition: service_healthy
EOF

# .env only for image names and non-secret config
cat <<EOF > /opt/n8n/.env
N8N_IMAGE=$N8N_TARGET
CLOUDFLARED_IMAGE=$CF_TARGET
EOF
chmod 600 /opt/n8n/.env

echo "=== Waiting for docker-compose plugin ==="
# Wait for the background download started at the beginning of the script
COMPOSE_OK=false
for i in {1..30}; do
  if [ -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then
    COMPOSE_OK=true
    echo "✅ docker-compose ready"
    break
  fi
  echo "⏳ Waiting for docker-compose ($i/30)..."
  sleep 2
done

if [ "$COMPOSE_OK" != "true" ]; then
  echo "❌ docker-compose failed to install"
  exit 1
fi

docker compose config >/dev/null || { echo "❌ Invalid docker-compose.yml"; exit 1; }
echo "=== Cleaning package cache before image pull ==="
apt-get clean
rm -rf /var/lib/apt/lists/*


# Disk pressure check before image pull — prevents docker daemon crash on full disk
echo "=== Disk pressure check ==="

# Try to get Docker root safely
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
echo "Disk check path: $DOCKER_ROOT"
df -h "$DOCKER_ROOT"
# Fallback for COS if docker not ready
if [ -z "$DOCKER_ROOT" ]; then
  DOCKER_ROOT="/mnt/stateful_partition"
  echo "⚠️ Docker not ready, fallback to $DOCKER_ROOT"
fi

AVAIL_KB=$(df --output=avail "$DOCKER_ROOT" | tail -1 | xargs)

if [ "$AVAIL_KB" -lt 2097152 ]; then
  echo "❌ Low disk space on $DOCKER_ROOT ($${AVAIL_KB}KB free, need 2GB)"
  exit 1
fi

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
echo "=== Verify Secrets Before Start ==="
for f in db_password n8n_key cf_token; do
  if [ ! -s "/dev/shm/n8n-secrets/$f" ]; then
    echo "❌ Missing secret: $f (secret fetch may have partially failed)"
    exit 1
  fi
done

echo "=== Starting Postgres ONLY (Phase 1) ==="
# Поднимаем ТОЛЬКО базу, чтобы n8n не успел к ней подключиться
docker compose up -d postgres || {
  echo "❌ docker compose up postgres failed"
  docker compose logs postgres --tail=50
  exit 1
}

echo "=== Waiting for Postgres container to be 'Up' ==="
for i in {1..15}; do
  if docker compose ps postgres | grep -q "Up"; then
    echo "✅ Postgres container is up"
    break
  fi
  sleep 1
done

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
  # Use migrations table as the source of truth — it's populated by n8n on
  # every successful boot regardless of whether the user created workflows.
  MIGRATION_COUNT=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
  "SELECT COUNT(*) FROM migrations;" 2>/dev/null | xargs)

  if [ -n "$MIGRATION_COUNT" ] && [ "$MIGRATION_COUNT" -gt 0 ]; then
    # Verify table readability — catches corrupted schema/data
    if docker compose exec -T postgres psql -U n8n -d n8n -tAc \
      "SELECT 1 FROM workflow_entity LIMIT 1;" >/dev/null 2>&1; then
      WORKFLOW_COUNT=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
      "SELECT COUNT(*) FROM workflow_entity;" 2>/dev/null | xargs)
      echo "Existing DB: $MIGRATION_COUNT migrations, $WORKFLOW_COUNT workflows"
      echo "✅ DB already populated → SKIP restore"
      SKIP_RESTORE=true
    else
      echo "⚠️ Migrations exist but workflow_entity unreadable → force restore"
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
  # Minimum backup size (bytes) — reject truncated / empty dumps.
  # A healthy n8n DB with ≥1 workflow is typically >500 KB uncompressed.
  MIN_BACKUP_BYTES=500000
  # Search both .sql and .sql.gz (gzip backups)
  LATEST=$(gsutil ls -l gs://${BACKUP_BUCKET_NAME}/n8n/n8n-*.sql gs://${BACKUP_BUCKET_NAME}/n8n/n8n-*.sql.gz 2>/dev/null | \
  grep -v TOTAL | \
  awk -v min="$MIN_BACKUP_BYTES" '$1 > min {print $2, $3}' | \
  sort | \
  tail -n 1 | \
  cut -d' ' -f2) || true  

  if [ -z "$LATEST" ]; then
    # Fallback: try any backup regardless of size (small/compressed DB edge-case)
    echo "⚠️ No backup above $MIN_BACKUP_BYTES bytes, trying any backup..."
    LATEST=$(gsutil ls gs://${BACKUP_BUCKET_NAME}/n8n/n8n-*.sql gs://${BACKUP_BUCKET_NAME}/n8n/n8n-*.sql.gz 2>/dev/null | sort | tail -n 1) || true
  fi

  if [ -z "$LATEST" ]; then
    echo "❌ CRITICAL: No backup found in gs://${BACKUP_BUCKET_NAME}/n8n/"
    exit 1
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

    # Ensure DB exists (idempotent — no DROP needed,
    # dump was created with --clean --if-exists so it handles table cleanup)
    docker compose exec -T postgres psql -U n8n -d postgres -c "
    SELECT 'CREATE DATABASE n8n'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='n8n')\gexec
    "

    # Isolate DB during restore — block external connections
    docker compose exec -T postgres psql -U n8n -d postgres -c "
    REVOKE CONNECT ON DATABASE n8n FROM PUBLIC;
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'n8n' AND pid <> pg_backend_pid();
    "

    # Decompress if gzipped backup
    if echo "$FILENAME" | grep -q '\.gz$'; then
      echo "Verifying gzip integrity..."
      gunzip -t "/tmp/$FILENAME" || { echo "❌ gzip corrupt"; exit 1; }
      echo "Decompressing gzipped backup..."
      gunzip -f "/tmp/$FILENAME"
      FILENAME=$(echo "$FILENAME" | sed 's/\.gz$//')
    fi

    # Use docker cp instead of pipe — more reliable for large dumps
    POSTGRES_CID=$(docker compose ps -q postgres)
    docker cp "/tmp/$FILENAME" "$POSTGRES_CID:/tmp/restore.sql"

    RESTORE_SIZE=$(stat -c%s "/tmp/$FILENAME" 2>/dev/null || echo "unknown")
    echo "Restoring DB ($RESTORE_SIZE bytes)..."
    if ! docker compose exec -T postgres \
      psql -U n8n -d n8n \
      --single-transaction \
      --set ON_ERROR_STOP=on \
      -f /tmp/restore.sql; then
      echo "❌ Restore failed — cleaning DB for next boot retry"
      docker compose exec -T postgres psql -U n8n -d postgres -c "
      SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'n8n';
      DROP DATABASE IF EXISTS n8n;
      CREATE DATABASE n8n;
      ALTER DATABASE n8n CONNECTION LIMIT -1;
      GRANT CONNECT ON DATABASE n8n TO PUBLIC;
      "
      exit 1
    fi

    # Post-restore sanity check — verify DB is actually usable
    docker compose exec -T postgres psql -U n8n -d n8n -c "ANALYZE;" 2>/dev/null || true

    MIGRATION_CHECK=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
      "SELECT COUNT(*) FROM migrations;" 2>/dev/null | xargs)
    TABLE_CHECK=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs)

    if [ -z "$MIGRATION_CHECK" ] || [ "$MIGRATION_CHECK" -lt 1 ] || [ -z "$TABLE_CHECK" ] || [ "$TABLE_CHECK" -lt 5 ]; then
      echo "❌ Restore produced invalid DB (migrations=$MIGRATION_CHECK, tables=$TABLE_CHECK) — cleaning for retry"
      docker compose exec -T postgres psql -U n8n -d postgres -c "
      SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'n8n';
      DROP DATABASE IF EXISTS n8n;
      CREATE DATABASE n8n;
      ALTER DATABASE n8n CONNECTION LIMIT -1;
      GRANT CONNECT ON DATABASE n8n TO PUBLIC;
      "
      exit 1
    fi
    echo "Sanity check: $MIGRATION_CHECK migrations, $TABLE_CHECK tables OK"

    # Re-enable connections after successful restore
    docker compose exec -T postgres psql -U n8n -d postgres -c "GRANT CONNECT ON DATABASE n8n TO PUBLIC;"
    docker compose exec -T postgres rm -f /tmp/restore.sql
    echo "✅ Restore complete"
    rm -f "/tmp/$FILENAME" "/tmp/$FILENAME.sha256" "/tmp/$FILENAME.gz.sha256"
  fi
fi

echo "=== Starting Application Containers (Phase 2) ==="
# ТЕПЕРЬ безопасно поднимаем n8n и cloudflared
docker compose up -d n8n cloudflared || {
  echo "❌ docker compose up apps failed"
  docker compose logs --tail=100
  exit 1
}

echo "=== Application Readiness Status ==="

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
FILE="/tmp/n8n-$${TIMESTAMP}.sql.gz"
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

# Disk pressure check — abort if <500MB free in /tmp
AVAIL_KB=$(df --output=avail /tmp | tail -1 | xargs)
if [ "$AVAIL_KB" -lt 512000 ]; then
  echo "❌ SKIP backup: insufficient disk space ($${AVAIL_KB}KB free in /tmp)"
  exit 1
fi

BACKUP_START=$(date +%s)
# Force WAL flush to ensure backup contains latest committed data
docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -c "CHECKPOINT;" 2>/dev/null || true
timeout 300 docker exec "$POSTGRES_CONTAINER" pg_dump -U n8n --no-owner --no-acl --clean --if-exists --serializable-deferrable --lock-wait-timeout=10000 n8n | gzip > "$FILE"
BACKUP_DURATION=$(( $(date +%s) - BACKUP_START ))
echo "Backup duration: $${BACKUP_DURATION}s"
if [ ! -s "$FILE" ]; then
  echo "❌ EMPTY BACKUP"
  exit 1
fi

(cd /tmp && sha256sum "$(basename "$FILE")") > "$CHECKSUM_FILE"

SUCCESS=false
for i in {1..3}; do
  if timeout 300 gsutil cp "$FILE" gs://${BACKUP_BUCKET_NAME}/n8n/; then
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
  if timeout 60 gsutil cp "$CHECKSUM_FILE" gs://${BACKUP_BUCKET_NAME}/n8n/; then
    CHECKSUM_OK=true
    break
  fi
  sleep 5
done

if [ "$CHECKSUM_OK" != "true" ]; then
  echo "❌ CHECKSUM UPLOAD FAILED"
  exit 1
fi

# Verify upload integrity — read back checksum from GCS and compare
LOCAL_SUM=$(cat "$CHECKSUM_FILE" 2>/dev/null || true)
if ! timeout 60 gsutil stat gs://${BACKUP_BUCKET_NAME}/n8n/$(basename "$CHECKSUM_FILE") >/dev/null 2>&1; then
  echo "❌ Remote checksum missing after upload"
  exit 1
fi
REMOTE_SUM=$(timeout 60 gsutil cat gs://${BACKUP_BUCKET_NAME}/n8n/$(basename "$CHECKSUM_FILE") 2>/dev/null || true)
if [ -n "$REMOTE_SUM" ] && [ -n "$LOCAL_SUM" ] && [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
  echo "❌ Checksum mismatch after upload — backup may be corrupt"
  exit 1
fi

rm -f "$FILE" "$CHECKSUM_FILE"
echo "BACKUP_OK $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EOF

chmod +x /usr/local/bin/backup.sh

echo '*/10 * * * * root BACKUP_BUCKET_NAME=${BACKUP_BUCKET_NAME} flock -n /tmp/n8n-backup.lock /usr/local/bin/backup.sh >> /var/log/n8n-backup.log 2>&1 || echo "Backup skipped (lock busy)" >> /var/log/n8n-backup.log' > /etc/cron.d/n8n-backup
systemctl restart cron

echo "=== ALL DONE ==="
exit 0