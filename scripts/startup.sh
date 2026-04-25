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
  swapon /swapfile
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
retry apt-get install -y ca-certificates curl gnupg docker.io

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

sysctl -w vm.swappiness=60
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
cat <<EOF > /opt/n8n/.env
DB_PASSWORD=$${DB_PASSWORD}
N8N_KEY=$${N8N_KEY}
CF_TOKEN=$${CF_TOKEN}
EOF
chmod 600 /opt/n8n/.env

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
  n8n:
    image: ${n8n_image}
    restart: unless-stopped
    ports:
        - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${db_host}
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${db_name}
      DB_POSTGRESDB_USER: ${db_user}
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
      
    healthcheck:
      # 10s matches GCP health check check_interval_sec in terraform/main.tf.
      # GCP probes every 10s; if Docker also checks every 10s there is no
      # stale-health window where GCP reads healthy while n8n is already dead.
      # start_period 420s covers cold DB migrations on e2-micro.
      test: ["CMD", "curl", "-f", "http://127.0.0.1:5678"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 420s

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
      test: ["CMD", "cloudflared", "--version"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 30s
EOF

docker compose config || { echo "❌ Invalid docker-compose.yml"; exit 1; }

echo "=== Cleaning package cache before image pull ==="
apt-get clean
rm -rf /var/lib/apt/lists/*



echo "=== Pulling n8n image ==="
retry timeout 1800 docker pull "${n8n_image}"


echo "=== Pulling cloudflared image ==="
retry timeout 600 docker pull "${cloudflared_image}"

echo "=== Starting Containers ==="
docker compose up -d

echo "=== Verifying n8n startup ==="
# n8n must be /healthz-green AND cloudflared's tunnel must be registered
# with the edge. Historically this loop only checked n8n, so a silently-
# failed cloudflared would let startup.sh exit 0 even though the external
# SLI probe (which goes through the tunnel) was guaranteed to fail. Both
# checks must succeed simultaneously in the same iteration, otherwise
# the loop keeps waiting.
HEALTHY=false
# Track which probe was the last to fail so the CRITICAL message —
# which feeds the n8n_startup_critical log-based metric and the on-call
# pager — names the actually-failing component instead of blaming n8n
# every time. The log-based metric filter in monitoring.tf matches on
# the substring "CRITICAL: " so the counter keeps working regardless
# of which of the two suffixes we print.
last_fail="both n8n and cloudflared"
# 60 попыток по 10 секунд = 10 минут ожидания
for i in {1..60}; do
  n8n_ok=false
  cf_ok=false
  if curl -sf http://127.0.0.1:5678/healthz >/dev/null; then
    n8n_ok=true
  fi
  if curl -fsS http://127.0.0.1:2000/ready >/dev/null; then
  cf_ok=true
  fi
  if [ "$n8n_ok" = true ] && [ "$cf_ok" = true ]; then
    echo "✅ n8n + cloudflared are up and healthy"
    HEALTHY=true
    break
  fi
  if [ "$n8n_ok" = false ] && [ "$cf_ok" = false ]; then
    last_fail="both n8n and cloudflared"
  elif [ "$n8n_ok" = false ]; then
    last_fail="n8n"
  else
    last_fail="cloudflared"
  fi
  echo "⏳ Waiting for n8n + cloudflared to initialize ($i/60, last fail: $last_fail)..."
  sleep 10
done

if [ "$HEALTHY" = true ]; then
  echo "=== Startup complete ==="
  docker compose ps
  exit 0
else
  # IMPORTANT: keep the exact substring "CRITICAL: startup failed" —
  # the log-based metric n8n_startup_critical in terraform/monitoring.tf
  # filters on it. The per-component detail ("n8n" / "cloudflared" /
  # "both") follows after an em-dash so on-call can triage without
  # opening logs, while the metric stays stable regardless of which
  # component failed.
  echo "❌ CRITICAL: startup failed — $last_fail did not become healthy within 10 minutes"
  docker compose logs --tail=100
  exit 1
fi