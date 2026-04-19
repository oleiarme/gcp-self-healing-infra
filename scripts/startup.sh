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
retry apt-get install -y ca-certificates curl gnupg docker.io docker-compose

echo "=== Taming Docker CPU for e2-micro ==="
# Создаем папку для настроек системного сервиса Docker
mkdir -p /etc/systemd/system/docker.service.d

# Запрещаем Docker'у использовать больше 15% процессора
cat <<EOF > /etc/systemd/system/docker.service.d/throttle.conf
[Service]
CPUQuota=15%
EOF

# Применяем жесткие ограничения
systemctl daemon-reload
systemctl restart docker

systemctl enable docker
systemctl start docker

echo "=== Taming Docker for e2-micro ==="
# Указываем Docker качать и распаковывать строго по 1 слою за раз
cat <<EOF > /etc/docker/daemon.json
{
  "max-concurrent-downloads": 1,
  "max-concurrent-uploads": 1
}
EOF
# Перезапускаем Docker, чтобы он съел новые настройки
systemctl restart docker

echo "=== Get DB Password from Secret Manager ==="
DB_PASSWORD=$(gcloud secrets versions access latest --secret="db-password")

echo "=== Setup n8n + Cloudflare Tunnel ==="
mkdir -p /opt/n8n
cd /opt/n8n

cat <<EOF > docker-compose.yml
version: '3.8'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:1.82.0
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${db_host}
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=postgres
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASSWORD}
      - N8N_ENCRYPTION_KEY=${n8n_encryption_key}
      - EXECUTIONS_PROCESS=main
      - EXECUTIONS_MODE=regular
      - N8N_CONCURRENCY_PRODUCTION_LIMIT=1

  cloudflared:
    image: cloudflare/cloudflared:2024.3.0
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${cf_tunnel_token}
EOF

echo "=== Gentle Pulling (Saving CPU Credits) ==="
# Скачиваем тяжелый n8n и даем серверу 30 секунд отдыха
docker-compose pull n8n
echo "Resting for 30 seconds..."
sleep 120

# Скачиваем легкий туннель и снова отдыхаем
docker-compose pull cloudflared
echo "Resting for 15 seconds..."
sleep 60

echo "=== Starting Containers ==="
# Теперь, когда всё скачано и распаковано, запуск займет 1 секунду
docker-compose up -d

echo "=== Startup complete ==="
