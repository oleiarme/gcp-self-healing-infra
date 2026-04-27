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

echo "=== Waiting for Docker daemon ==="

for i in {1..30}; do
  if docker info >/dev/null 2>&1; then
    echo "✅ Docker is ready"
    break
  fi
  echo "⏳ Waiting for Docker ($i/30)..."
  sleep 2
done

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
    container_name: n8n
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
      
      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
      N8N_LOG_LEVEL: error

      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE_HISTORY: 24

      N8N_RUNNERS_ENABLED: "true"
      N8N_RUNNERS_MODE: internal
      N8N_HOST: 0.0.0.0
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      N8N_LISTEN_ADDRESS: 0.0.0.0
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
      - postgres
        
  cloudflared:
    image: ${cloudflared_image}
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token $${CF_TOKEN}
    ports:
      - "127.0.0.1:2000:2000"
    depends_on:
      n8n:
        condition: service_healthy
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

echo "=== Waiting for Postgres (strict) ==="

READY=false

for i in {1..60}; do
  if docker compose ps postgres >/dev/null 2>&1 && \
     docker compose exec -T postgres pg_isready -U n8n >/dev/null 2>&1; then
    
    # дополнительная проверка: можно ли выполнить запрос
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



echo "=== Restore latest backup ==="
SKIP_RESTORE=false

echo "=== Checking if DB already has data ==="

DB_EXISTS=$(docker compose exec -T postgres psql -U n8n -d postgres -tAc \
"SELECT 1 FROM pg_database WHERE datname='n8n';" | xargs)

if [ "$DB_EXISTS" = "1" ]; then
  echo "DB exists, checking content..."

  TABLE_EXISTS=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
  "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name='workflow_entity');" 2>/dev/null | xargs)

  if [ "$TABLE_EXISTS" = "t" ]; then
    WORKFLOW_COUNT=$(docker compose exec -T postgres psql -U n8n -d n8n -tAc \
    "SELECT COUNT(*) FROM workflow_entity;" | xargs)

    echo "Existing workflows: $WORKFLOW_COUNT"

    if [ "$WORKFLOW_COUNT" -gt 0 ]; then
      echo "✅ DB already populated → SKIP restore"
      SKIP_RESTORE=true
    else
      echo "⚠️ Table exists but empty → will restore"
      SKIP_RESTORE=false
    fi
  else
    echo "⚠️ No workflow table → will restore"
    SKIP_RESTORE=false
  fi
else
  echo "⚠️ DB does not exist → will restore"
  SKIP_RESTORE=false
fi

echo "=== Selecting valid backup ==="

LATEST=$(gsutil ls gs://n8n-backups-idealist426118/n8n/n8n-*.sql 2>/dev/null | while read file; do
  size=$(gsutil du "$file" | awk '{print $1}')
  if [ "$size" -gt 500000 ]; then
    echo "$file"
  fi
done | sort | tail -n 1)

echo "Selected backup: $LATEST"

if [ -z "$LATEST" ]; then
  echo "⚠️ No valid backup found → starting with empty DB"
  exit 0
fi

CHECKSUM="$LATEST.sha256"
FILENAME=$(basename "$LATEST")

echo "Found backup: $LATEST"

if ! gsutil stat "$CHECKSUM" >/dev/null 2>&1; then
  echo "❌ Checksum missing"
  exit 1
fi

echo "Downloading backup..."
gsutil cp "$LATEST" "/tmp/$FILENAME"
gsutil cp "$CHECKSUM" "/tmp/$FILENAME.sha256"

echo "Verifying checksum..."
if ! (cd /tmp && sha256sum -c "$FILENAME.sha256"); then
  echo "❌ Checksum failed"
  exit 1
fi

echo "Checksum OK"

if [ -f /opt/n8n/.restore_done ]; then
  echo "✅ Restore already done ранее → SKIP"
  SKIP_RESTORE=true
fi

if [ "$SKIP_RESTORE" != "true" ]; then
  echo "Dropping DB..."
  docker compose exec -T postgres psql -U n8n -d postgres -c "DROP DATABASE IF EXISTS n8n;"
  docker compose exec -T postgres psql -U n8n -d postgres -c "CREATE DATABASE n8n;"

  echo "Restoring DB..."
  cat "/tmp/$FILENAME" | docker compose exec -T postgres psql -U n8n -d n8n

  echo "✅ Restore complete"
  touch /opt/n8n/.restore_done
else
  echo "=== Restore skipped ==="
fi

echo "Restoring DB..."
cat "/tmp/$FILENAME" | docker compose exec -T postgres psql -U n8n -d n8n

echo "✅ Restore complete"
touch /opt/n8n/.restore_done

rm -f "/tmp/$FILENAME" "/tmp/$FILENAME.sha256"

echo "=== Verifying restore ==="

COUNT=$(docker compose exec -T postgres psql -U n8n -d n8n -t -c "SELECT count(*) FROM workflow_entity;" | xargs)

echo "Workflow count: $COUNT"

if [ "$COUNT" -lt 1 ]; then
  echo "⚠️ Restore empty → skipping but continuing"
else
  echo "✅ Restore OK"
fi


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