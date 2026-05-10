#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:?Usage: create_env.sh <name> [ttl_minutes]}"
TTL_MINUTES="${2:-30}"
TTL_SECONDS=$((TTL_MINUTES * 60))

ENV_ID="env-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
NETWORK_NAME="${ENV_ID}-net"
CONTAINER_NAME="${ENV_ID}-app"
APP_IMAGE="${APP_IMAGE:-sandbox-app:latest}"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
HOST_IP="${HOST_IP:-$(hostname -I | awk '{print $1}')}"
LOG_DIR="$PROJECT_DIR/logs/$ENV_ID"
STATE_FILE="$PROJECT_DIR/envs/$ENV_ID.json"
NGINX_CONF="$PROJECT_DIR/nginx/conf.d/${ENV_ID}.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ -f "$STATE_FILE" ]]; then
    echo -e "${RED}Error: Environment $ENV_ID already exists${NC}"
    exit 1
fi

if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
    echo -e "${RED}Error: Nginx container ($NGINX_CONTAINER) is not running. Run 'make up' first.${NC}"
    exit 1
fi

echo -e "${CYAN}Creating environment: $ENV_ID ($ENV_NAME)${NC}"

docker network create "$NETWORK_NAME" > /dev/null
echo -e "  ${GREEN}✓${NC} Network $NETWORK_NAME created"

docker network connect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Nginx connected to $NETWORK_NAME"

CONTAINER_ID=$(docker run -d \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.name=$ENV_NAME" \
    -e "ENV_ID=$ENV_ID" \
    --restart unless-stopped \
    "$APP_IMAGE")

echo -e "  ${GREEN}✓${NC} Container $CONTAINER_NAME started ($CONTAINER_ID)"

sleep 1

mkdir -p "$LOG_DIR"
docker logs -f "$CONTAINER_ID" >> "$LOG_DIR/app.log" 2>&1 &
LOG_PID=$!
echo -e "  ${GREEN}✓${NC} Log shipping started (PID: $LOG_PID)"

cat > "$NGINX_CONF" <<EOF
location /${ENV_ID}/ {
    set \$upstream ${CONTAINER_NAME};
    rewrite ^/${ENV_ID}/(.*)\$ /\$1 break;
    proxy_pass http://\$upstream:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Env-ID ${ENV_ID};
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
}
EOF

docker exec "$NGINX_CONTAINER" nginx -s reload > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Nginx route registered and reloaded"

CREATED_AT=$(date +%s)
TMP_STATE=$(mktemp)
cat > "$TMP_STATE" <<EOF
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": $CREATED_AT,
  "ttl": $TTL_SECONDS,
  "status": "running",
  "container_id": "$CONTAINER_ID",
  "container_name": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "log_pid": $LOG_PID,
  "url": "http://${HOST_IP}/${ENV_ID}/"
}
EOF
mv "$TMP_STATE" "$STATE_FILE"
echo -e "  ${GREEN}✓${NC} State file written"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Environment created successfully!${NC}"
echo -e "  URL: ${CYAN}http://${HOST_IP}/${ENV_ID}/${NC}"
echo -e "  TTL: ${YELLOW}${TTL_MINUTES} minutes${NC}"
echo -e "  ID:  ${ENV_ID}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
