#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/.env" 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: simulate_outage.sh --env <env_id> --mode <crash|pause|network|recover|stress>"
    exit 1
}

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)  ENV_ID="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *)      usage ;;
    esac
done

[[ -z "$ENV_ID" || -z "$MODE" ]] && usage

STATE_FILE="$PROJECT_DIR/envs/${ENV_ID}.json"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"

if [[ ! -f "$STATE_FILE" ]]; then
    echo -e "${RED}Error: Environment $ENV_ID not found${NC}"
    exit 1
fi

CONTAINER_NAME=$(jq -r '.container_name' "$STATE_FILE")
NETWORK_NAME=$(jq -r '.network' "$STATE_FILE")

# GUARD: never simulate against Nginx or daemon containers
PROTECTED_NAMES=("$NGINX_CONTAINER" "sandbox-daemon" "sandbox-api" "sandbox-prometheus" "sandbox-grafana")
for protected in "${PROTECTED_NAMES[@]}"; do
    if [[ "$CONTAINER_NAME" == "$protected" ]]; then
        echo -e "${RED}BLOCKED: Cannot simulate outage against protected container: $CONTAINER_NAME${NC}"
        exit 1
    fi
done

echo -e "${YELLOW}Simulating outage: $MODE on $ENV_ID${NC}"

case "$MODE" in
    crash)
        docker kill "$CONTAINER_NAME"
        echo -e "  ${RED}✗${NC} Container killed (health monitor should detect within 90s)"
        ;;

    pause)
        docker pause "$CONTAINER_NAME"
        echo -e "  ${YELLOW}⏸${NC} Container paused (recover with: simulate_outage.sh --env $ENV_ID --mode recover)"
        ;;

    network)
        docker network disconnect "$NETWORK_NAME" "$CONTAINER_NAME"
        echo -e "  ${RED}✗${NC} Network disconnected (recover with: simulate_outage.sh --env $ENV_ID --mode recover)"
        ;;

    recover)
        # Try all recovery methods — whatever is applicable
        if docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null | grep -q "paused"; then
            docker unpause "$CONTAINER_NAME"
            echo -e "  ${GREEN}✓${NC} Container unpaused"
        fi

        if docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null | grep -q "exited\|dead"; then
            docker start "$CONTAINER_NAME"
            echo -e "  ${GREEN}✓${NC} Container restarted"
        fi

        # Reconnect network if disconnected
        if ! docker network inspect "$NETWORK_NAME" --format='{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
            docker network connect "$NETWORK_NAME" "$CONTAINER_NAME"
            echo -e "  ${GREEN}✓${NC} Network reconnected"
        fi

        # Update status back to running
        CURRENT_STATUS=$(jq -r '.status' "$STATE_FILE")
        if [[ "$CURRENT_STATUS" == "degraded" ]]; then
            TMP_STATE=$(mktemp)
            jq '.status = "running"' "$STATE_FILE" > "$TMP_STATE"
            mv "$TMP_STATE" "$STATE_FILE"
            echo -e "  ${GREEN}✓${NC} Status updated to running"
        fi
        ;;

    stress)
        if ! command -v stress-ng &> /dev/null; then
            echo -e "${RED}Error: stress-ng not installed. Run: apt install stress-ng${NC}"
            exit 1
        fi
        docker exec -d "$CONTAINER_NAME" sh -c "stress-ng --cpu 4 --timeout 60s" 2>/dev/null || \
            echo -e "  ${YELLOW}⚠${NC} Could not run stress-ng in container (may not be available). Running on host instead."
        echo -e "  ${YELLOW}⚡${NC} CPU stress applied for 60s"
        ;;

    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        usage
        ;;
esac
