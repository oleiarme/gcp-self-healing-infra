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

# Установка docker compose v2 plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "=== Taming Docker for e2-micro ==="
mkdir -p /etc/docker
# ЕДИНСТВЕННАЯ запись daemon.json — не перезаписывать ниже!
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
CPUQuota=70%
EOF

cat <<EOF > /etc/systemd/system/containerd.service.d/throttle.conf
[Service]
CPUQuota=70%
EOF

sysctl -w vm.swappiness=10
systemctl daemon-reload
retry systemctl restart docker
systemctl enable docker

echo "=== Get Secrets from Secret Manager ==="

# Убран 2>/dev/null, чтобы реальная причина (IAM, API downtime) попала в системный лог
DB_PASSWORD=$(gcloud secrets versions access latest --secret="${DB_SECRET_NAME}") || { 
  echo "❌ CRITICAL: Failed to fetch DB_PASSWORD"; 
  exit 1; 
}

N8N_KEY=$(gcloud secrets versions access latest --secret="${N8N_KEY_SECRET_NAME}") || { 
  echo "❌ CRITICAL: Failed to fetch N8N_KEY"; 
  exit 1; 
}

CF_TOKEN=$(gcloud secrets versions access latest --secret="${CF_TUNNEL_SECRET_NAME}") || { 
  echo "❌ CRITICAL: Failed to fetch CF_TOKEN"; 
  exit 1; 
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
      DB_POSTGRESDB_PASSWORD: $DB_PASSWORD
      
      N8N_ENCRYPTION_KEY: $N8N_KEY
      EXECUTIONS_PROCESS:main
      EXECUTIONS_MODE: regular
      N8N_CONCURRENCY_PRODUCTION_LIMIT: 1
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s # КРИТИЧНО: Даем время на накатывание миграций БД при первом старте

  cloudflared:
    image: cloudflare/cloudflared:2026.3.0
    restart: unless-stopped
    # Включаем сервер метрик на порту 2000 для healthcheck
    command: tunnel --metrics 0.0.0.0:2000 run
    environment:
      TUNNEL_TOKEN: $CF_TOKEN
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:2000/ready"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF

docker compose config || { echo "❌ Invalid docker-compose.yml"; exit 1; }

echo "=== Gentle Pulling (Saving CPU Credits) ==="

# Если после всех retry pull падает -> жестко убиваем скрипт. MIG пересоздаст машину.
retry timeout 180 docker compose pull n8n || { echo "❌ Critical: n8n pull failed"; exit 1; }

# Короткий отдых для CPU
sleep 10 

retry timeout 120 docker compose pull cloudflared || { echo "❌ Critical: cloudflared pull failed"; exit 1; }

echo "=== Starting Containers ==="
docker compose up -d

echo "=== Verifying n8n startup ==="

# Флаг -f заставит curl вернуть ошибку, если n8n отдаст HTTP 500/503
for i in {1..30}; do
  if curl -sf http://localhost:5678/healthz >/dev/null; then
    echo "✅ n8n is up and healthy"
    # Сигнализируем успешный старт
    exit 0
  fi
  echo "⏳ Waiting for n8n to initialize ($i/30)..."
  sleep 5
done

echo "=== Docker Containers Status ==="
docker compose ps

# Если нужно, можно вывести логи неудачных контейнеров
FAILED_CONTAINERS=$(docker compose ps -q --filter "health=unhealthy")
if [ ! -z "$FAILED_CONTAINERS" ]; then
  echo "❌ Unhealthy containers detected!"
  docker compose logs
  exit 1
fi

# Если цикл закончился, а n8n так и не ожил
echo "❌ CRITICAL: n8n failed to start within timeout"
echo "=== Dumping Docker Logs ==="
docker compose logs --tail=100
exit 1



echo "=== Startup complete ==="
