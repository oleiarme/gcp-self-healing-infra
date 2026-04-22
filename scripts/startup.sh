#!/bin/bash
set -e
exec > >(tee /var/log/startup.log|logger -t startup) 2>&1

echo "=== Swap ==="
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
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
CPUQuota=85%
TimeoutStartSec=180
EOF

cat <<EOF > /etc/systemd/system/containerd.service.d/throttle.conf
[Service]
CPUAccounting=true
CPUQuota=85%
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

export CF_TOKEN
export N8N_KEY
export DB_PASSWORD

echo "=== Setup n8n + Cloudflare Tunnel ==="
mkdir -p /opt/n8n
cd /opt/n8n

cat <<EOF > docker-compose.yml
version: '3.8'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:2.16.1
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${db_host}
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: postgres
      DB_POSTGRESDB_USER: ${db_user}
      DB_POSTGRESDB_PASSWORD: \$DB_PASSWORD
      N8N_ENCRYPTION_KEY: \$N8N_KEY
      EXECUTIONS_PROCESS: main
      EXECUTIONS_MODE: regular
      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
      N8N_LOG_LEVEL: error
      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE_HISTORY: 24
    healthcheck:
      # 10s matches GCP health check check_interval_sec in terraform/main.tf.
      # GCP probes every 10s; if Docker also checks every 10s there is no
      # stale-health window where GCP reads healthy while n8n is already dead.
      # start_period 420s covers cold DB migrations on e2-micro.
      test: ["CMD", "curl", "-sf", "http://localhost:5678/healthz"]
      interval: 10s
      timeout: 15s
      retries: 10
      start_period: 420s

  cloudflared:
    image: cloudflare/cloudflared:2026.3.0
    restart: unless-stopped
    command: tunnel --metrics 0.0.0.0:2000 run
    environment:
      TUNNEL_TOKEN: \$CF_TOKEN
EOF

docker compose config || { echo "❌ Invalid docker-compose.yml"; exit 1; }

echo "=== Pulling containers ==="
# На e2-micro pull может занять вечность, увеличиваем таймаут
retry timeout 1800 docker compose pull

echo "=== Starting Containers ==="
docker compose up -d

echo "=== Verifying n8n startup ==="
HEALTHY=false
# 60 попыток по 10 секунд = 10 минут ожидания
for i in {1..60}; do
  if curl -sf http://localhost:5678/healthz >/dev/null; then
    echo "✅ n8n is up and healthy"
    HEALTHY=true
    break 
  fi
  echo "⏳ Waiting for n8n to initialize ($i/60)..."
  sleep 10
done

if [ "$HEALTHY" = true ]; then
  echo "=== Startup complete ==="
  docker compose ps
  exit 0
else
  echo "❌ CRITICAL: n8n failed to start within 10 minutes"
  docker compose logs --tail=100
  exit 1
fi