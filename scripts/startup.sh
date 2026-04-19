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

systemctl enable docker
systemctl start docker

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

docker-compose up -d

echo "=== Startup complete ==="
