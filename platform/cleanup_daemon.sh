#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENVS_DIR="$PROJECT_DIR/envs"
LOG_FILE="$PROJECT_DIR/logs/cleanup.log"
DESTROY_SCRIPT="$SCRIPT_DIR/destroy_env.sh"

mkdir -p "$PROJECT_DIR/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Cleanup daemon started (PID: $$)"

while true; do
    for state_file in "$ENVS_DIR"/*.json; do
        [[ -f "$state_file" ]] || continue

        ENV_ID=$(jq -r '.id' "$state_file")
        CREATED_AT=$(jq -r '.created_at' "$state_file")
        TTL=$(jq -r '.ttl' "$state_file")
        STATUS=$(jq -r '.status' "$state_file")

        NOW=$(date +%s)
        EXPIRES_AT=$((CREATED_AT + TTL))

        if [[ $NOW -ge $EXPIRES_AT ]]; then
            log "TTL expired for $ENV_ID (created: $CREATED_AT, ttl: ${TTL}s, expired: $EXPIRES_AT)"
            bash "$DESTROY_SCRIPT" "$ENV_ID" >> "$LOG_FILE" 2>&1
            log "Environment $ENV_ID destroyed by cleanup daemon"
        fi
    done

    sleep 60
done
