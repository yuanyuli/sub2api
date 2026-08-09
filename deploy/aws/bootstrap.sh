#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 curl openssl
systemctl enable --now docker

install -d -m 700 /opt/sub2api

if [ ! -f /opt/sub2api/.env ]; then
  umask 077
  POSTGRES_PASSWORD="$(openssl rand -hex 32)"
  REDIS_PASSWORD="$(openssl rand -hex 32)"
  JWT_SECRET="$(openssl rand -hex 32)"
  TOTP_ENCRYPTION_KEY="$(openssl rand -hex 32)"
  ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  cat > /opt/sub2api/.env <<EOF
POSTGRES_USER=sub2api
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=sub2api
REDIS_PASSWORD=${REDIS_PASSWORD}
JWT_SECRET=${JWT_SECRET}
TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}
ADMIN_EMAIL=zt_halcyon@yeah.net
ADMIN_PASSWORD=${ADMIN_PASSWORD}
TZ=Asia/Shanghai
EOF
  printf '%s\n' "${ADMIN_PASSWORD}" > /root/sub2api-initial-admin-password
  chmod 600 /opt/sub2api/.env /root/sub2api-initial-admin-password
fi

cat > /opt/sub2api/compose.yaml <<'EOF'
services:
  postgres:
    image: postgres:18-alpine
    restart: unless-stopped
    mem_limit: 512m
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      PGDATA: /var/lib/postgresql/data
      TZ: ${TZ}
    command: postgres -c max_connections=30 -c shared_buffers=128MB -c effective_cache_size=512MB
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [internal]
  redis:
    image: redis:8-alpine
    restart: unless-stopped
    mem_limit: 256m
    command: ["sh", "-c", "redis-server --appendonly yes --appendfsync everysec --requirepass \"$$REDIS_PASSWORD\""]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      TZ: ${TZ}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [internal]
  sub2api:
    image: weishaw/sub2api:0.1.173
    restart: unless-stopped
    mem_limit: 768m
    security_opt:
      - no-new-privileges:true
    ports:
      - 127.0.0.1:8080:8080
    environment:
      AUTO_SETUP: "true"
      SERVER_HOST: "0.0.0.0"
      SERVER_PORT: "8080"
      DATABASE_HOST: postgres
      DATABASE_PORT: "5432"
      DATABASE_USER: ${POSTGRES_USER}
      DATABASE_PASSWORD: ${POSTGRES_PASSWORD}
      DATABASE_DBNAME: ${POSTGRES_DB}
      DATABASE_SSLMODE: disable
      DATABASE_MAX_OPEN_CONNS: "20"
      DATABASE_MAX_IDLE_CONNS: "5"
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDIS_POOL_SIZE: "64"
      REDIS_MIN_IDLE_CONNS: "2"
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      TOTP_ENCRYPTION_KEY: ${TOTP_ENCRYPTION_KEY}
      TZ: ${TZ}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 6
      start_period: 45s
    networks: [internal]
volumes:
  postgres_data:
  redis_data:
networks:
  internal:
    driver: bridge
EOF

chmod 600 /opt/sub2api/compose.yaml
docker compose --env-file /opt/sub2api/.env -f /opt/sub2api/compose.yaml config --quiet
docker compose --env-file /opt/sub2api/.env -f /opt/sub2api/compose.yaml pull
docker compose --env-file /opt/sub2api/.env -f /opt/sub2api/compose.yaml up -d

for attempt in $(seq 1 24); do
  if curl --fail --silent --show-error http://127.0.0.1:8080/health >/dev/null; then
    exit 0
  fi
  sleep 5
done

docker compose --env-file /opt/sub2api/.env -f /opt/sub2api/compose.yaml ps
exit 1
