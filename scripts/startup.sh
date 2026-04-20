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
CPUQuota=25%
EOF

cat <<EOF > /etc/systemd/system/containerd.service.d/throttle.conf
[Service]
CPUQuota=25%
EOF

sysctl -w vm.swappiness=10
systemctl daemon-reload
retry systemctl restart docker
systemctl enable docker

echo "=== Get DB Password from Secret Manager ==="
DB_PASSWORD=$(gcloud secrets versions access latest --secret="${DB_SECRET_NAME}" 2>/dev/null)
if [ -z "$DB_PASSWORD" ]; then
  echo "❌ ERROR: Failed to get DB_PASSWORD from Secret Manager!"
  exit 1
fi
n8n_encryption_key=$(gcloud secrets versions access latest --secret="${N8N_KEY_SECRET_NAME}" 2>/dev/null)
cf_tunnel_token=$(gcloud secrets versions access latest --secret="${CF_TUNNEL_SECRET_NAME}" 2>/dev/null)

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
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${db_host}
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=postgres
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=${DB_PASSWORD}
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
docker compose pull n8n
sleep 120
docker compose pull cloudflared
sleep 60

echo "=== Starting Containers ==="
docker compose up -d

echo "=== Startup complete ==="
