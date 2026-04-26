#!/bin/bash
set -e
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

# [FIX 1] Вернуть из PR #10: non-interactive apt.
# Без этого dpkg может EOF'ить на stdin при конфликте conffile и валить
# весь bootstrap. Имена стабильные, чтобы terraform templatefile()
# с двойным $ не поломал рендер.
export DEBIAN_FRONTEND=noninteractive
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
retry apt-get install -y ca-certificates curl gnupg docker.io cron postgresql-client

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

echo "=== Get Secrets from Secret Manager ==="
DB_PASSWORD=$(gcloud secrets versions access latest --secret="${DB_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch DB_PASSWORD"
  exit 1
}

N8N_KEY=$(gcloud secrets versions access latest --secret="${N8N_KEY_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch N8N_KEY"
  exit 1
}

CF_TOKEN=$(gcloud secrets versions access latest --secret="${CF_TUNNEL_SECRET_NAME}") || {
  echo "❌ CRITICAL: Failed to fetch CF_TOKEN"
  exit 1
}

echo "✅ All secrets fetched successfully."

# Создаем файл .env для гарантированной передачи секретов в Docker
mkdir -p /opt/n8n


export CF_TOKEN
export N8N_KEY
export DB_PASSWORD

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

echo "=== Setup n8n + Cloudflare Tunnel ==="
cd /opt/n8n

echo "=== Restore latest backup (safe) ==="

LATEST=$(gsutil ls gs://n8n-backups-idealist426118/n8n/*.sql 2>/dev/null | sort | tail -n 1)
if [ -n "$LATEST" ]; then
  CHECKSUM="$LATEST.sha256"

  echo "Found backup: $LATEST"

  if ! gsutil stat "$CHECKSUM" >/dev/null 2>&1; then
    echo "⚠️ Checksum missing → skipping restore"
    rm -f /tmp/restore.sql
  else
    if ! gsutil cp "$LATEST" /tmp/restore.sql; then
      echo "❌ Failed to download backup"
      exit 1
    fi

    if ! gsutil cp "$CHECKSUM" /tmp/restore.sql.sha256; then
      echo "❌ Failed to download checksum"
      rm -f /tmp/restore.sql
      exit 1
    fi

    echo "Verifying checksum..."
    if ! (cd /tmp && sha256sum -c restore.sql.sha256); then
  echo "❌ Checksum failed, aborting restore"
  rm -f /tmp/restore.sql /tmp/restore.sql.sha256
  exit 1
    fi

    echo "Checksum OK"
  fi

else
  echo "No backup found"
fi

cat <<EOF > docker-compose.yml
services:
  postgres:
      image: postgres:15-alpine
      restart: unless-stopped
      environment:
        POSTGRES_DB: n8n
        POSTGRES_USER: n8n
        POSTGRES_PASSWORD: $DB_PASSWORD
      volumes:
        - postgres_data:/var/lib/postgresql/data
  n8n:
    image: ${n8n_image}
    restart: unless-stopped
    ports:
        - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: $DB_PASSWORD

      N8N_ENCRYPTION_KEY: $N8N_KEY

      N8N_EXECUTIONS_MODE: regular
      EXECUTIONS_PROCESS: main
      N8N_DISABLE_PRODUCTION_MAIN_PROCESS: "true"

      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
      N8N_LOG_LEVEL: error

      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE_HISTORY: 24

      N8N_RUNNERS_ENABLED: "false"
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
      test: ["CMD", "curl", "-f", "http://127.0.0.1:5678/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 420s
    depends_on:
      - postgres
        
  cloudflared:
    image: ${cloudflared_image}
    restart: unless-stopped
    command: tunnel --metrics 0.0.0.0:2000 run
    ports:
      - "127.0.0.1:2000:2000"
    environment:
      TUNNEL_TOKEN: \$CF_TOKEN
    healthcheck:
      # cloudflared exposes a /ready endpoint on its metrics port whenever
      # it has at least one registered connection to the Cloudflare edge.
      # Without this healthcheck, a silently-dead cloudflared would keep
      # n8n reachable only from inside the VM — the external uptime check
      # would catch it eventually, but Docker's own restart policy never
      # gets a chance to trigger on anything shorter than a full crash.
      # Probing /ready every 10s (matching n8n's healthcheck cadence) lets
      # docker compose mark cloudflared unhealthy within ~1m of edge-link
      # loss, which is what the start_period 30s allows for cold-start
      # tunnel registration.
      test: ["CMD", "curl", "-f", "http://127.0.0.1:2000/ready"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 30s
volumes:
    postgres_data:
EOF

docker compose config || { echo "❌ Invalid docker-compose.yml"; exit 1; }

echo "=== Cleaning package cache before image pull ==="
apt-get clean
rm -rf /var/lib/apt/lists/*



echo "=== Pulling n8n image ==="
retry timeout 1800 docker pull "${n8n_image}" || {
  echo "❌ Docker pull failed"
  free -m
  exit 1
}


echo "=== Pulling cloudflared image ==="
retry timeout 600 docker pull "${cloudflared_image}"


echo "=== Starting Containers ==="
docker compose up -d || {
  echo "❌ docker compose up failed"
  docker compose logs --tail=100
  exit 1
}

echo "=== Waiting for Postgres ==="

READY=false

for i in {1..30}; do
  if docker compose ps postgres >/dev/null 2>&1 && \
     docker compose exec -T postgres pg_isready -U n8n >/dev/null 2>&1; then
    echo "✅ Postgres is ready"
    READY=true
    break
  fi

  echo "⏳ Waiting for Postgres ($i/30)..."
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "❌ Postgres did not become ready in time"
  docker compose logs postgres --tail=50
  exit 1
fi


if [ -f /tmp/restore.sql ]; then
  echo "=== Restoring database (safe mode) ==="

  RESTORE_MARKER="/opt/n8n/.restore_done"

  if [ -f "$RESTORE_MARKER" ]; then
    echo "⚠️ Restore already done ранее → skip"
    rm -f /tmp/restore.sql /tmp/restore.sql.sha256

  else

    SCHEMA_VERSION=$(docker compose exec -T postgres psql -U n8n -d n8n -t -c \
      "SELECT MAX(id) FROM migrations;" 2>/dev/null | xargs || echo "0")

    echo "Schema version: $SCHEMA_VERSION"

    if [ "$SCHEMA_VERSION" != "0" ]; then
      echo "⚠️ Schema already initialized → skip restore"
      rm -f /tmp/restore.sql /tmp/restore.sql.sha256

    else
      echo "Running dry-run..."

      if ! timeout 600 bash -c '(
  echo "BEGIN;";
  cat /tmp/restore.sql;
  echo "ROLLBACK;";
) | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n'; then
        echo "❌ Dry-run failed, aborting restore"
        rm -f /tmp/restore.sql /tmp/restore.sql.sha256
        exit 1
      fi
      echo "Applying restore..."

      if ! timeout 600 bash -c 'cat /tmp/restore.sql | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n'; then
        echo "❌ Restore failed"
        exit 1
      fi

      echo "✅ Restore complete"

      touch "$RESTORE_MARKER"
      rm -f /tmp/restore.sql /tmp/restore.sql.sha256
    fi
  fi

else
  echo "No restore file"
fi

echo "=== Verifying n8n startup ==="

HEALTHY=false
last_fail="both n8n and cloudflared"

for i in {1..60}; do
  n8n_ok=false
  cf_ok=false

  # Проверяем, что контейнеры вообще запущены
  n8n_running=false
  cf_running=false

  if docker compose ps --services --filter "status=running" | grep -q '^n8n$'; then
  
  n8n_running=true
  fi

  if docker compose ps --services --filter "status=running" | grep -q '^cloudflared$'; then
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

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILE="/tmp/n8n-$${TIMESTAMP}.sql"
CHECKSUM_FILE="$${FILE}.sha256"

timeout 300 docker compose exec -T postgres pg_dump -U n8n --no-owner --no-acl n8n > "$FILE"
sha256sum "$FILE" > "$CHECKSUM_FILE"

SUCCESS=false
for i in {1..3}; do
  if gsutil cp -n "$FILE" gs://n8n-backups-idealist426118/n8n/; then
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
  if gsutil cp "$CHECKSUM_FILE" gs://n8n-backups-idealist426118/n8n/; then
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

echo "*/10 * * * * root flock -n /tmp/n8n-backup.lock /usr/local/bin/backup.sh > /var/log/n8n-backup.log 2>&1" > /etc/cron.d/n8n-backup
systemctl restart cron

echo "=== ALL DONE ==="
exit 0