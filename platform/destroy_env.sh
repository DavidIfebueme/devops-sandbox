#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/.env" 2>/dev/null || true

ENV_ID="${1:?Usage: destroy_env.sh <env_id>}"
STATE_FILE="$PROJECT_DIR/envs/${ENV_ID}.json"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
LOG_DIR="$PROJECT_DIR/logs/$ENV_ID"
ARCHIVE_DIR="$PROJECT_DIR/logs/archived/$ENV_ID"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ ! -f "$STATE_FILE" ]]; then
    echo -e "${RED}Error: Environment $ENV_ID not found${NC}"
    exit 1
fi

CONTAINER_NAME=$(jq -r '.container_name' "$STATE_FILE")
NETWORK_NAME=$(jq -r '.network' "$STATE_FILE")
LOG_PID=$(jq -r '.log_pid' "$STATE_FILE")

echo -e "${YELLOW}Destroying environment: $ENV_ID${NC}"

if [[ -n "$LOG_PID" && "$LOG_PID" != "null" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Log shipping stopped (PID: $LOG_PID)"
fi

CONTAINERS=$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" 2>/dev/null || true)
if [[ -n "$CONTAINERS" ]]; then
    docker stop $CONTAINERS 2>/dev/null || true
    docker rm -f $CONTAINERS 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Containers removed"
fi

docker network disconnect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true

docker network rm "$NETWORK_NAME" 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Network $NETWORK_NAME removed"

NGINX_CONF="$PROJECT_DIR/nginx/conf.d/${ENV_ID}.conf"
if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
    docker exec "$NGINX_CONTAINER" nginx -s reload > /dev/null 2>&1 || true
    echo -e "  ${GREEN}✓${NC} Nginx config removed and reloaded"
fi

if [[ -d "$LOG_DIR" ]]; then
    mkdir -p "$ARCHIVE_DIR"
    mv "$LOG_DIR"/* "$ARCHIVE_DIR/" 2>/dev/null || true
    rmdir "$LOG_DIR" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Logs archived to logs/archived/$ENV_ID/"
fi

rm -f "$STATE_FILE"
echo -e "  ${GREEN}✓${NC} State file deleted"

echo ""
echo -e "${RED}Environment $ENV_ID destroyed${NC}"
