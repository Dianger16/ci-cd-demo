#!/usr/bin/env bash
# deploy_ec2.sh — runs ON the EC2 instance
# Usage:
# bash deploy_ec2.sh <new_image> <version_tag> <container_name> <port>

set -euo pipefail

# ── Validate Arguments ───────────────────────────────────────────────────────
if [ "$#" -ne 4 ]; then
  echo "Usage: bash deploy_ec2.sh <new_image> <version_tag> <container_name> <port>"
  exit 1
fi

NEW_IMAGE="${1}"
VERSION_TAG="${2}"
CONTAINER_NAME="${3}"
APP_PORT="${4}"

# Prevent empty image
if [ -z "$NEW_IMAGE" ]; then
  echo "ERROR: Docker image name is empty."
  exit 1
fi

APP_URL="http://localhost:${APP_PORT}"
LOG_FILE="$HOME/cicd-demo/deploy.log"
MAX_RETRIES=10
RETRY_INTERVAL=10

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log() {
  echo -e "${BLUE}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"
}

success() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${RESET}" | tee -a "$LOG_FILE"
}

warn() {
  echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${RESET}" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[$(date '+%H:%M:%S')] ✖ $*${RESET}" | tee -a "$LOG_FILE"
}

echo "" >> "$LOG_FILE"
echo "════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "Deploy started: $(date)" | tee -a "$LOG_FILE"
echo "Image: $NEW_IMAGE" | tee -a "$LOG_FILE"
echo "════════════════════════════════════════" | tee -a "$LOG_FILE"

# ── Step 1: Capture current stable container ────────────────────────────────
log "Capturing current stable state..."

STABLE_IMAGE=""

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  STABLE_IMAGE=$(docker inspect "$CONTAINER_NAME" \
    --format '{{.Config.Image}}' 2>/dev/null || echo "")

  log "Stable image: ${STABLE_IMAGE:-none}"
else
  log "No running container found — fresh deploy."
fi

# ── Step 2: Pull image ──────────────────────────────────────────────────────
log "Pulling image: $NEW_IMAGE"

docker pull "$NEW_IMAGE" 2>&1 | tee -a "$LOG_FILE"

success "Image pulled successfully."

# ── Step 3: Replace container ───────────────────────────────────────────────
log "Stopping old container..."

docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

log "Starting new container..."

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${APP_PORT}:3000" \
  -e "APP_VERSION=${VERSION_TAG}" \
  "$NEW_IMAGE" 2>&1 | tee -a "$LOG_FILE"

sleep 10

# ── Step 4: Health check ────────────────────────────────────────────────────
log "Running health checks..."

HEALTHY=false

for i in $(seq 1 "$MAX_RETRIES"); do
  HTTP_CODE=$(curl -s -o /tmp/health_resp.json \
    -w "%{http_code}" \
    "${APP_URL}/health" || echo "000")

  BODY=$(cat /tmp/health_resp.json 2>/dev/null || echo "{}")

  STATUS=$(echo "$BODY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('status',''))" \
    2>/dev/null || echo "")

  log "Attempt ${i}: HTTP=${HTTP_CODE}, status=${STATUS}"

  if [ "$HTTP_CODE" = "200" ] && [ "$STATUS" = "healthy" ]; then
    HEALTHY=true
    break
  fi

  sleep "$RETRY_INTERVAL"
done

# ── Step 5: Success ─────────────────────────────────────────────────────────
if [ "$HEALTHY" = "true" ]; then
  success "DEPLOY SUCCEEDED"
  success "Version: $VERSION_TAG"
  success "Image: $NEW_IMAGE"
  exit 0
fi

# ── Rollback ────────────────────────────────────────────────────────────────
error "Health check failed."
error "Starting rollback..."

docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if [ -n "$STABLE_IMAGE" ]; then
  warn "Rolling back to: $STABLE_IMAGE"

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${APP_PORT}:3000" \
    "$STABLE_IMAGE"

  warn "Rollback completed."
else
  warn "No stable image available for rollback."
fi

exit 1
