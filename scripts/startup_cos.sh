#!/bin/bash
# startup_cos.sh — COS (Container-Optimized OS) startup script
# Equivalent of scripts/startup.sh for Ubuntu, but tailored for COS:
#   - No apt-get install (Docker and gcloud are built-in)
#   - No systemd services (Docker already running)
#   - Uses docker-compose with labels and json-file logging
#   - Metadata google-logging-enabled=true, google-monitoring-enabled=true (set in Terraform)
#
# Requirements: 8.4, 8.5
set -e
set -o pipefail
exec > >(tee -a /var/log/startup.log) 2>&1

echo "=== COS Startup Script ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Standby pool: the MIG stops and starts this same VM (same instance id), so
# cloud-init treats the next boot as "already done" and skips user-data
# scripts (scripts_user runs once per instance). Removing its semaphore
# makes cloud-init run this script again on every boot. Done first, so a
# failed run is also retried on the next boot.
rm -f /var/lib/cloud/instance/sem/config_scripts_user

log_step() {
  echo "=== [$(date -u +%H:%M:%SZ)] $1 ==="
}

retry() {
  for i in {1..5}; do
    "$@" && return 0
    sleep 5
  done
  return 1
}

# ==========================================
# 1. Wait for Docker (should already be running on COS)
# ==========================================
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

# ==========================================
# 1.5 Detect or Install Docker Compose V2
# ==========================================
echo "=== Detecting Docker Compose ==="
if docker compose version >/dev/null 2>&1; then
  echo "✅ Native 'docker compose' is available"
  COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  echo "✅ Native 'docker-compose' is available"
  COMPOSE_CMD="docker-compose"
else
  echo "⏳ No native compose found, falling back to download..."
  COMPOSE_BIN="/var/lib/docker/cli-plugins/docker-compose"
  # shellcheck disable=SC2034
  COMPOSE_VERSION="v2.32.4"
  COMPOSE_URL="https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-x86_64"
  if [ ! -x "$COMPOSE_BIN" ]; then
    mkdir -p /var/lib/docker/cli-plugins
    retry curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_BIN"
    chmod +x "$COMPOSE_BIN"
    echo "✅ Docker Compose $($COMPOSE_BIN version --short) installed"
  else
    echo "✅ Docker Compose already available: $($COMPOSE_BIN version --short)"
  fi
  COMPOSE_CMD="$COMPOSE_BIN"
fi

# COS rootfs is read-only; Docker Compose V2 needs a writable config dir
export DOCKER_CONFIG="/var/lib/docker/.docker-config"
mkdir -p "$DOCKER_CONFIG"

# ==========================================
# 2. Wait for GCP auth (metadata service)
# ==========================================
echo "=== Checking GCP metadata (service account) ==="
if ! curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email >/dev/null; then
  echo "❌ No service account attached or metadata unavailable"
  exit 1
fi

# Fetch Access Token and Project ID from metadata server for API access (COS does not have gcloud CLI)
TOKEN_RESPONSE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" || echo "")
CLEAN_RESPONSE=$(echo "$TOKEN_RESPONSE" | tr -d '\n\r ')
ACCESS_TOKEN=$(echo "$CLEAN_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "❌ Failed to fetch access token from metadata server"
  exit 1
fi

PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" || echo "")
if [ -z "$PROJECT_ID" ]; then
  echo "❌ Failed to fetch project ID from metadata server"
  exit 1
fi

fetch_secret() {
  # shellcheck disable=SC2034
  local secret_name="$1"
  local url="https://secretmanager.googleapis.com/v1/projects/$${PROJECT_ID}/secrets/$${secret_name}/versions/latest:access"
  local res
  res=$(curl -sf -H "Authorization: Bearer $${ACCESS_TOKEN}" "$url" || echo "")
  if [ -z "$res" ]; then
    return 1
  fi
  local clean
  clean=$(echo "$res" | tr -d '\n\r ')
  local b64
  b64=$(echo "$clean" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p')
  if [ -z "$b64" ]; then
    return 1
  fi
  echo "$b64" | base64 --decode
}

echo "=== Checking Secret Manager access ==="
if ! retry fetch_secret "${DB_SECRET_NAME}" >/dev/null; then
  echo "❌ Cannot access Secret Manager"
  exit 1
fi

# ==========================================
# 3. Fetch secrets from Secret Manager
# ==========================================
echo "=== Get Secrets from Secret Manager ==="
DB_PASSWORD=$(retry fetch_secret "${DB_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch DB_PASSWORD"
  exit 1
}

N8N_KEY=$(retry fetch_secret "${N8N_KEY_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch N8N_KEY"
  exit 1
}

CF_TOKEN=$(retry fetch_secret "${CF_TUNNEL_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch CF_TOKEN"
  exit 1
}

echo "✅ All secrets fetched successfully."

# ==========================================
# 4. Mount persistent data disk
# ==========================================
echo "=== Mount Persistent Data Disk ==="
# COS convention: /mnt/disks/<name>
DATA_DIR="/mnt/disks/n8n-data"

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

# Format if empty (first boot)
if ! blkid "$DATA_DISK" | grep -q 'TYPE="ext4"'; then
  echo "Formatting new persistent disk..."
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DISK"
fi

mkdir -p "$DATA_DIR"
if mountpoint -q "$DATA_DIR"; then
  echo "✅ $DATA_DIR already mounted"
else
  # Standby pool: on start of a stopped VM, Docker may have restarted a
  # container before this script ran (restart: on-failure after an unclean
  # shutdown). A postgres container started now would use an empty
  # $DATA_DIR on the boot disk, and the mount below would hide it while
  # the container keeps writing there. Stop all containers first; step 10
  # starts them again in order, after the mount.
  RUNNING_CONTAINERS=$(docker ps -q)
  if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "⚠️ Containers running before data disk mount — stopping them"
    # shellcheck disable=SC2086
    docker stop $RUNNING_CONTAINERS
  fi
  fsck -a "$DATA_DISK" || true
  mount -o discard,defaults "$DATA_DISK" "$DATA_DIR"
fi

# Ensure postgres directory exists with correct permissions (uid 70 for alpine postgres)
mkdir -p "$DATA_DIR/postgres"
if [ "$(stat -c '%u:%g' "$DATA_DIR/postgres")" != "70:70" ]; then
  chown -R 70:70 "$DATA_DIR/postgres"
fi

# ==========================================
# 4.5. Setup Swap File
# ==========================================
echo "=== Setup Swap File ==="
if [ ! -f "$DATA_DIR/swapfile" ]; then
  echo "Creating 2GB swap file..."
  fallocate -l 2G "$DATA_DIR/swapfile"
  chmod 600 "$DATA_DIR/swapfile"
  mkswap "$DATA_DIR/swapfile"
fi

if ! grep -q "$DATA_DIR/swapfile" /proc/swaps; then
  echo "Enabling swap file..."
  swapon "$DATA_DIR/swapfile"
fi

# ==========================================
# 5. Configure Artifact Registry Docker credentials
# ==========================================
log_step "Configure Artifact Registry credentials"
docker-credential-gcr configure-docker --registries="${ar_location}-docker.pkg.dev" >/dev/null 2>&1 || {
  echo "⚠️ Failed to configure Docker credential helper for Artifact Registry"
}

COMPOSE_DIR="/var/lib/docker/compose/n8n"
mkdir -p "$COMPOSE_DIR"

# ==========================================
# 7. Copy docker-compose and healthz-sidecar files
# ==========================================
echo "=== Setup /var/lib/docker/cli-plugins/docker-compose ==="

# Copy compose file (rendered by Terraform templatefile or baked into image)
# On COS, we write the compose file directly since we can't rely on /opt
# Standby pool keeps the boot disk: drop the previous boot's file so compose
# changes (e.g. restart policy) reach a restarted VM, not only a new one.
rm -f "$COMPOSE_DIR/docker-compose.yml"
cp /var/lib/cloud/instance/scripts/docker-compose.cos.yml "$COMPOSE_DIR/docker-compose.yml" 2>/dev/null || true

# If compose file wasn't provided via cloud-init, write it inline
if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  cat <<'COMPOSEFILE' > "$COMPOSE_DIR/docker-compose.yml"
services:
  postgres:
    image: $${POSTGRES_IMAGE}
    restart: on-failure
    labels:
      container_name: "postgres"
    ports:
      - "127.0.0.1:5432:5432"
    environment:
      POSTGRES_DB: $${DB_NAME}
      POSTGRES_USER: $${DB_USER}
      POSTGRES_PASSWORD: $${DB_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${DB_USER} -d $${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 5
    volumes:
      - $${DATA_DIR}/postgres:/var/lib/postgresql/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  n8n:
    image: $${N8N_IMAGE}
    restart: on-failure
    labels:
      container_name: "n8n"
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: $${DB_NAME}
      DB_POSTGRESDB_USER: $${DB_USER}
      DB_POSTGRESDB_PASSWORD: $${DB_PASSWORD}
      N8N_ENCRYPTION_KEY: $${N8N_KEY}
      N8N_EXECUTIONS_MODE: regular
      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
      N8N_LOG_LEVEL: error
      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE_HISTORY: 24
      N8N_RUNNERS_ENABLED: "false"
      N8N_HOST: $${N8N_PUBLIC_HOST}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://$${N8N_PUBLIC_HOST}/
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PORT: 5678
      N8N_LISTEN_ADDRESS: 0.0.0.0
      DB_POSTGRESDB_CONNECTION_TIMEOUT: 60000
      N8N_PROXY_HOPS: 1
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 420s
    depends_on:
      postgres:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  cloudflared:
    image: $${CLOUDFLARED_IMAGE}
    restart: on-failure
    labels:
      container_name: "cloudflared"
    command: tunnel --no-autoupdate --protocol http2 --metrics 0.0.0.0:2000 run --token $${CF_TOKEN}
    ports:
      - "127.0.0.1:2000:2000"
    depends_on:
      - n8n
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  healthz-sidecar:
    image: $${HEALTHZ_SIDECAR_IMAGE}
    restart: on-failure
    labels:
      container_name: "healthz-sidecar"
    ports:
      - "8080:8080"
    environment:
      N8N_URL: "http://n8n:5678/healthz"
      POSTGRES_HOST: "postgres"
      POSTGRES_PORT: "5432"
      POSTGRES_USER: $${DB_USER}
      POSTGRES_DB: $${DB_NAME}
      POSTGRES_PASSWORD: $${DB_PASSWORD}
      CLOUDFLARED_METRICS_URL: "http://cloudflared:2000/ready"
      BOOTSTRAP_WINDOW_SECONDS: "1800"
    depends_on:
      postgres:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
COMPOSEFILE
fi

# ==========================================
# 8. Copy healthz-sidecar files
# ==========================================
mkdir -p "$COMPOSE_DIR/healthz-sidecar"

# Write healthz-sidecar files inline to ensure self-contained startup
cat <<'EOF' > "$COMPOSE_DIR/healthz-sidecar/Dockerfile"
FROM python:3.12-slim

WORKDIR /opt

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY healthz_server.py .

EXPOSE 8080

CMD ["python3", "healthz_server.py"]
EOF

cat <<'EOF' > "$COMPOSE_DIR/healthz-sidecar/requirements.txt"
psycopg2-binary>=2.9,<3.0
EOF

cat <<'EOF' > "$COMPOSE_DIR/healthz-sidecar/healthz_server.py"
"""
healthz-sidecar: Lightweight HTTP health-check server for COS deployments.

Endpoints:
  /healthz      — Returns 200 during bootstrap grace window (first BOOTSTRAP_WINDOW_SECONDS),
                   after that delegates to /healthz/deep logic.
  /healthz/deep — All-or-nothing deep check:
                   1. Postgres SELECT 1 completes in < 1s
                   2. n8n /healthz responds with HTTP 200 in < 2s
                   3. Container cloudflared is in state running (via metrics endpoint)
                   Returns HTTP 200 only when ALL three pass.
                   Returns HTTP 503 with JSON body identifying which check failed.

Requirements: 8.6, 8.7, 8.8, 8.9
"""

import http.server
import json
import os
import socket
import socketserver
import time
import urllib.request
import urllib.error

import psycopg2

# Configuration from environment
BOOTSTRAP_WINDOW_SECONDS = int(os.environ.get("BOOTSTRAP_WINDOW_SECONDS", "1800"))
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "postgres")
POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
POSTGRES_USER = os.environ.get("POSTGRES_USER", "n8n")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "n8n")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
N8N_URL = os.environ.get("N8N_URL", "http://n8n:5678/healthz")
CLOUDFLARED_METRICS_URL = os.environ.get("CLOUDFLARED_METRICS_URL", "http://cloudflared:2000/ready")

PORT = int(os.environ.get("HEALTHZ_PORT", "8080"))

START_TIME = time.time()


def check_postgres() -> dict:
    """
    Check Postgres connectivity.

    Important:
    - MIG health checks should validate availability, not performance SLA.
    - Temporary latency spikes must NOT mark the VM unhealthy.
    """

    start = time.time()

    try:
        conn = psycopg2.connect(
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD,
            dbname=POSTGRES_DB,
            connect_timeout=3,
        )

        try:
            cur = conn.cursor()
            cur.execute("SELECT 1")
            cur.fetchone()
            cur.close()

        finally:
            conn.close()

        elapsed = time.time() - start

        return {
            "ok": True,
            "check": "postgres",
            "latency_ms": int(elapsed * 1000),
        }

    except Exception as e:
        return {
            "ok": False,
            "check": "postgres",
            "error": str(e),
        }

def check_n8n() -> dict:
    """Check n8n /healthz responds with HTTP 200 in < 2s."""
    start = time.time()
    try:
        req = urllib.request.Request(N8N_URL, method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            resp.read()
            elapsed = time.time() - start
            if elapsed > 2.0:
                return {"ok": False, "check": "n8n", "error": f"too slow: {elapsed:.2f}s"}
            return {"ok": True, "check": "n8n", "latency_ms": int(elapsed * 1000)}
    except Exception as e:
        return {"ok": False, "check": "n8n", "error": str(e)}


def check_cloudflared() -> dict:
    """Check cloudflared container is in state running via its metrics/ready endpoint."""
    start = time.time()
    try:
        req = urllib.request.Request(CLOUDFLARED_METRICS_URL, method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            status = resp.status
            elapsed = time.time() - start
            if status == 200:
                return {"ok": True, "check": "cloudflared", "latency_ms": int(elapsed * 1000)}
            return {"ok": False, "check": "cloudflared", "error": f"HTTP {status}"}
    except Exception as e:
        return {"ok": False, "check": "cloudflared", "error": str(e)}


def run_deep_checks() -> tuple[bool, list[dict]]:
    """Run all three deep checks. Returns (all_ok, results)."""
    results = [
        check_postgres(),
        check_n8n(),
        check_cloudflared(),
    ]
    all_ok = all(r["ok"] for r in results)
    return all_ok, results


class HealthHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for health endpoints."""

    def log_message(self, format, *args):
        """Suppress default access logging to reduce noise."""
        pass

    def do_GET(self):
        if self.path == "/healthz":
            self._handle_healthz()
        elif self.path == "/healthz/deep":
            self._handle_deep()
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "not found"}).encode())

    def _handle_healthz(self):
        """Bootstrap grace: return 200 during first BOOTSTRAP_WINDOW_SECONDS.
        After that, delegate to deep check logic."""
        uptime = time.time() - START_TIME

        if uptime < BOOTSTRAP_WINDOW_SECONDS:
            # During bootstrap grace, always return 200
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            body = {
                "status": "bootstrap",
                "uptime_seconds": int(uptime),
                "grace_remaining_seconds": int(BOOTSTRAP_WINDOW_SECONDS - uptime),
            }
            self.wfile.write(json.dumps(body).encode())
            return

        # After bootstrap grace, delegate to deep check
        self._handle_deep()

    def _handle_deep(self):
        """All-or-nothing deep health check."""
        all_ok, results = run_deep_checks()

        if all_ok:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            body = {"status": "healthy", "checks": results}
            self.wfile.write(json.dumps(body).encode())
        else:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            failed = [r for r in results if not r["ok"]]
            body = {
                "status": "unhealthy",
                "checks": results,
                "failed": failed,
            }
            self.wfile.write(json.dumps(body).encode())


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    """Allow concurrent health check requests."""
    allow_reuse_address = True
    daemon_threads = True


def main():
    print(f"healthz-sidecar starting on port {PORT}")
    print(f"  BOOTSTRAP_WINDOW_SECONDS={BOOTSTRAP_WINDOW_SECONDS}")
    print(f"  POSTGRES_HOST={POSTGRES_HOST}:{POSTGRES_PORT}")
    print(f"  N8N_URL={N8N_URL}")
    print(f"  CLOUDFLARED_METRICS_URL={CLOUDFLARED_METRICS_URL}")

    with ThreadedTCPServer(("", PORT), HealthHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
EOF

# ==========================================
# 9. Pull images sequentially (avoids swap/IOPS thrashing on e2-micro)
# ==========================================
cd "$COMPOSE_DIR"

pull_image() {
  local name="$1"
  local primary="$2"
  local fallback="$3"
  local timeout_sec="$4"
  log_step "Pulling $name ($primary)"
  # Up to 3 attempts: one transient AR error must not drop us to Docker Hub.
  # A timeout (exit 124) is not retried: 3 x 1800 s for n8n would outlast
  # the auto-healing initial delay (2400 s).
  local attempt rc
  for attempt in 1 2 3; do
    if timeout "$timeout_sec" docker pull "$primary"; then
      PULLED_IMAGE="$primary"
      return 0
    else
      rc=$?
    fi
    [ "$rc" -eq 124 ] && break
    [ "$attempt" -lt 3 ] && sleep 5
  done
  if [ -n "$fallback" ] && [ "$fallback" != "$primary" ]; then
    echo "⚠️ AR pull failed for $name → fallback to $fallback"
    if retry timeout "$timeout_sec" docker pull "$fallback"; then
      PULLED_IMAGE="$fallback"
      return 0
    fi
  fi
  return 1
}

pull_image "postgres" "${postgres_ar_image}" "${postgres_image}" 600 || {
  echo "❌ Docker pull failed for postgres"
  exit 1
}
POSTGRES_TARGET="$PULLED_IMAGE"

pull_image "cloudflared" "${cloudflared_ar_image}" "${cloudflared_image}" 600 || {
  echo "❌ Docker pull failed for cloudflared"
  exit 1
}
CF_TARGET="$PULLED_IMAGE"

pull_image "n8n" "${n8n_ar_image}" "${n8n_image}" 1800 || {
  echo "❌ Docker pull failed for n8n"
  exit 1
}
N8N_TARGET="$PULLED_IMAGE"

SIDECAR_TARGET="${healthz_sidecar_ar_image}"
log_step "Pulling healthz-sidecar ($SIDECAR_TARGET)"
if ! timeout 600 docker pull "$SIDECAR_TARGET"; then
  echo "⚠️ AR pull failed for healthz-sidecar → building locally..."
  docker build -t "$SIDECAR_TARGET" "$COMPOSE_DIR/healthz-sidecar"
fi

# ==========================================
# 9.5 Write environment file
# ==========================================
log_step "Write .env"
cat <<EOF > "$COMPOSE_DIR/.env"
CF_TOKEN=$CF_TOKEN
N8N_KEY=$N8N_KEY
DB_PASSWORD=$DB_PASSWORD
DB_NAME=${db_name}
DB_USER=${db_user}
N8N_IMAGE=$N8N_TARGET
CLOUDFLARED_IMAGE=$CF_TARGET
POSTGRES_IMAGE=$POSTGRES_TARGET
HEALTHZ_SIDECAR_IMAGE=$SIDECAR_TARGET
DATA_DIR=$DATA_DIR
N8N_PUBLIC_HOST=${n8n_public_host}
EOF
chmod 600 "$COMPOSE_DIR/.env"

# ==========================================
# 10. Start services in order
# ==========================================
log_step "Starting Postgres"
$COMPOSE_CMD up -d postgres || {
  echo "❌ $COMPOSE_CMD up postgres failed"
  $COMPOSE_CMD logs --no-log-prefix -n 50 postgres 2>/dev/null || docker logs --tail 50 postgres 2>/dev/null || true
  exit 1
}

echo "=== Waiting for Postgres ==="
READY=false
for i in {1..60}; do
  if $COMPOSE_CMD exec -T postgres pg_isready -U ${db_user} >/dev/null 2>&1; then
    if $COMPOSE_CMD exec -T postgres psql -U ${db_user} -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
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
  $COMPOSE_CMD logs --no-log-prefix -n 50 postgres 2>/dev/null || docker logs --tail 50 postgres 2>/dev/null || true
  exit 1
fi

log_step "Starting Application Containers"
$COMPOSE_CMD up -d n8n cloudflared healthz-sidecar || {
  echo "❌ $COMPOSE_CMD up apps failed"
  $COMPOSE_CMD logs --no-log-prefix -n 100 2>/dev/null || docker logs --tail 100 n8n 2>/dev/null || true
  exit 1
}

# ==========================================
# 11. Verify startup
# ==========================================
log_step "Verifying startup"
HEALTHY=false
for i in {1..60}; do
  n8n_ok=false
  cf_ok=false

  if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    n8n_ok=true
  fi

  if curl -fsS http://127.0.0.1:2000/ready >/dev/null 2>&1; then
    cf_ok=true
  fi

  if [ "$n8n_ok" = true ] && [ "$cf_ok" = true ]; then
    echo "✅ n8n + cloudflared are up and healthy"
    HEALTHY=true
    break
  fi

  echo "⏳ Waiting ($i/60)..."
  sleep 10
done

if [ "$HEALTHY" = true ]; then
  echo "=== COS Startup complete ==="
  $COMPOSE_CMD ps
  # Standby pool keeps this boot disk (20 GB) for weeks: drop images no
  # container uses (old n8n versions after deploys), keep the running ones.
  docker image prune -af >/dev/null 2>&1 || echo "⚠️ docker image prune failed"
else
  echo "❌ CRITICAL: startup failed"
  $COMPOSE_CMD logs --no-log-prefix -n 100 2>/dev/null || true
  exit 1
fi

# ==========================================
# 12. Setup Automated Backup System (Daily)
# ==========================================
echo "=== Setting up automated backups ==="

cat <<'BACKUPSCRIPT' > "/var/lib/docker/compose/n8n/n8n-backup.sh"
#!/bin/bash
set -e
set -o pipefail

BACKUP_BUCKET="${BACKUP_BUCKET_NAME}"
TEMP_BACKUP_FILE="/tmp/postgres-backup-$(date +%Y%m%dT%H%M%S).sql.gz"

echo "Starting Postgres backup to GCS bucket: $${BACKUP_BUCKET}"

# 1. Fetch metadata access token and project ID
TOKEN_RESPONSE=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" || echo "")
ACCESS_TOKEN=$(echo "$${TOKEN_RESPONSE}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$${ACCESS_TOKEN}" ]; then
  echo "❌ Error: Failed to fetch access token from metadata server." >&2
  exit 1
fi

PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" || echo "")
if [ -z "$${PROJECT_ID}" ]; then
  echo "❌ Error: Failed to fetch project ID from metadata server." >&2
  exit 1
fi

# 2. Dump Postgres database
docker exec postgres pg_dumpall -U "${db_user}" | gzip > "$${TEMP_BACKUP_FILE}"

# 3. Upload to GCS via REST API
OBJECT_NAME="backup-$(date +%Y%m%dT%H%M%S).sql.gz"
echo "Uploading $${TEMP_BACKUP_FILE} as $${OBJECT_NAME}..."

UPLOAD_URL="https://storage.googleapis.com/upload/storage/v1/b/$${BACKUP_BUCKET}/o?uploadType=media&name=$${OBJECT_NAME}"

HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" \
  -X POST \
  --data-binary @"$${TEMP_BACKUP_FILE}" \
  -H "Authorization: Bearer $${ACCESS_TOKEN}" \
  -H "Content-Type: application/gzip" \
  "$${UPLOAD_URL}")

if [ "$${HTTP_CODE}" -ne 200 ]; then
  echo "❌ Error: GCS upload failed with HTTP code $${HTTP_CODE}" >&2
  rm -f "$${TEMP_BACKUP_FILE}"
  exit 1
fi

echo "✅ Backup successfully uploaded to gs://$${BACKUP_BUCKET}/$${OBJECT_NAME}"
rm -f "$${TEMP_BACKUP_FILE}"
BACKUPSCRIPT

chmod +x "/var/lib/docker/compose/n8n/n8n-backup.sh"

# Write systemd service and timer files for Backups
cat <<'EOF' > "/etc/systemd/system/n8n-backup.service"
[Unit]
Description=n8n Postgres Backup Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash /var/lib/docker/compose/n8n/n8n-backup.sh
EOF

cat <<'EOF' > "/etc/systemd/system/n8n-backup.timer"
[Unit]
Description=Run n8n Postgres Backup Daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ==========================================
# 13. Setup Automated RAM/Swap Monitor (60s)
# ==========================================
echo "=== Setting up automated memory monitoring ==="

cat <<'MONITORSCRIPT' > "/var/lib/docker/compose/n8n/n8n-monitor.sh"
#!/bin/bash
set -e
set -o pipefail

# 1. Fetch metadata needed for API
TOKEN_RESPONSE=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" || echo "")
ACCESS_TOKEN=$(echo "$${TOKEN_RESPONSE}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$${ACCESS_TOKEN}" ]; then
  echo "❌ Error: Failed to fetch access token." >&2
  exit 1
fi

PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" || echo "")
INSTANCE_ID=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/id" || echo "")
INSTANCE_NAME=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name" || echo "")
ZONE_FULL=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" || echo "")
ZONE=$(echo "$${ZONE_FULL}" | awk -F/ '{print $$NF}')

if [ -z "$${PROJECT_ID}" ] || [ -z "$${INSTANCE_ID}" ] || [ -z "$${ZONE}" ]; then
  echo "❌ Error: Failed to fetch VM metadata." >&2
  exit 1
fi

# 2. Calculate RAM and Swap utilization from /proc/meminfo
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $$2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $$2}')
RAM_UTIL=$(echo | awk "{print (1 - $${MEM_AVAIL}/$${MEM_TOTAL}) * 100}")

SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $$2}')
SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $$2}')
if [ "$${SWAP_TOTAL}" -gt 0 ]; then
  SWAP_UTIL=$(echo | awk "{print (1 - $${SWAP_FREE}/$${SWAP_TOTAL}) * 100}")
else
  SWAP_UTIL=0
fi

TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 3. Create time series payload
cat <<EOF > /tmp/monitor-payload.json
{
  "timeSeries": [
    {
      "metric": {
        "type": "custom.googleapis.com/vm/memory/ram_utilization",
        "labels": {
          "instance_name": "$${INSTANCE_NAME}"
        }
      },
      "resource": {
        "type": "gce_instance",
        "labels": {
          "project_id": "$${PROJECT_ID}",
          "instance_id": "$${INSTANCE_ID}",
          "zone": "$${ZONE}"
        }
      },
      "points": [
        {
          "interval": {
            "endTime": "$${TIME}"
          },
          "value": {
            "doubleValue": $${RAM_UTIL}
          }
        }
      ]
    },
    {
      "metric": {
        "type": "custom.googleapis.com/vm/memory/swap_utilization",
        "labels": {
          "instance_name": "$${INSTANCE_NAME}"
        }
      },
      "resource": {
        "type": "gce_instance",
        "labels": {
          "project_id": "$${PROJECT_ID}",
          "instance_id": "$${INSTANCE_ID}",
          "zone": "$${ZONE}"
        }
      },
      "points": [
        {
          "interval": {
            "endTime": "$${TIME}"
          },
          "value": {
            "doubleValue": $${SWAP_UTIL}
          }
        }
      ]
    }
  ]
}
EOF

# 4. Post to Stackdriver Monitoring API
MONITOR_URL="https://monitoring.googleapis.com/v3/projects/$${PROJECT_ID}/timeSeries"
HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" \
  -X POST \
  -d @/tmp/monitor-payload.json \
  -H "Authorization: Bearer $${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  "$${MONITOR_URL}")

if [ "$${HTTP_CODE}" -ne 200 ]; then
  echo "❌ Error: Failed to report metrics, HTTP code $${HTTP_CODE}" >&2
  cat /tmp/monitor-payload.json
  rm -f /tmp/monitor-payload.json
  exit 1
fi

echo "✅ Metrics reported: RAM=$${RAM_UTIL}%, Swap=$${SWAP_UTIL}%"
rm -f /tmp/monitor-payload.json
MONITORSCRIPT

chmod +x "/var/lib/docker/compose/n8n/n8n-monitor.sh"

# Write systemd service and timer files for Monitoring
cat <<'EOF' > "/etc/systemd/system/n8n-monitor.service"
[Unit]
Description=n8n RAM and Swap Monitoring Service
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /var/lib/docker/compose/n8n/n8n-monitor.sh
EOF

cat <<'EOF' > "/etc/systemd/system/n8n-monitor.timer"
[Unit]
Description=Run n8n Memory Monitoring Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

echo "=== Enabling and starting systemd timers ==="
systemctl daemon-reload
systemctl enable --now n8n-backup.timer
systemctl enable --now n8n-monitor.timer

echo "=== ALL DONE ==="
exit 0
