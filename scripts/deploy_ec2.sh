#!/usr/bin/env bash
# deploy_ec2.sh — runs ON the EC2 instance
# Called by GitHub Actions via SSH
# Usage: bash deploy_ec2.sh <new_image> <version_tag> <container_name> <port>

set -euo pipefail

NEW_IMAGE="${1}"
VERSION_TAG="${2}"
CONTAINER_NAME="${3}"
APP_PORT="${4}"
APP_URL="http://localhost:${APP_PORT}"
LOG_FILE="$HOME/cicd-demo/deploy.log"
MAX_RETRIES=10
RETRY_INTERVAL=10

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔  $*${RESET}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠  $*${RESET}" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✖  $*${RESET}" | tee -a "$LOG_FILE"; }

echo "" >> "$LOG_FILE"
echo "════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "  Deploy started: $(date)" | tee -a "$LOG_FILE"
echo "  Image: $NEW_IMAGE" | tee -a "$LOG_FILE"
echo "════════════════════════════════════════" | tee -a "$LOG_FILE"

# ── Step 1: Capture current stable container ─────────────────────────────────
log "Capturing current stable state..."
STABLE_IMAGE=""
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  STABLE_IMAGE=$(docker inspect "$CONTAINER_NAME" \
    --format '{{.Config.Image}}' 2>/dev/null || echo "")
  log "Stable image: ${STABLE_IMAGE:-none}"
else
  log "No running container found — fresh deploy."
fi

# ── Step 2: Pull new image from Docker Hub ───────────────────────────────────
log "Pulling new image: $NEW_IMAGE"
docker pull "$NEW_IMAGE" 2>&1 | tee -a "$LOG_FILE"
success "Image pulled."

# ── Step 3: Stop old container and start new one ─────────────────────────────
log "Starting new container..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm   "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${APP_PORT}:3000" \
  -e "APP_VERSION=${VERSION_TAG}" \
  "$NEW_IMAGE" 2>&1 | tee -a "$LOG_FILE"

log "Container started. Waiting 10s for app to initialize..."
sleep 10

# ── Step 4: Health check ─────────────────────────────────────────────────────
log "Running health check (${MAX_RETRIES} attempts × ${RETRY_INTERVAL}s)..."
HEALTHY=false

for i in $(seq 1 "$MAX_RETRIES"); do
  log "Attempt ${i}/${MAX_RETRIES}..."

  HTTP_CODE=$(curl -s -o /tmp/health_resp.json \
    -w "%{http_code}" \
    --connect-timeout 5 \
    --max-time 10 \
    "${APP_URL}/health" 2>/dev/null || echo "000")

  BODY=$(cat /tmp/health_resp.json 2>/dev/null || echo "{}")
  STATUS=$(echo "$BODY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  log "  HTTP: ${HTTP_CODE} | status: \"${STATUS}\""

  if [ "$HTTP_CODE" = "200" ] && [ "$STATUS" = "healthy" ]; then
    HEALTHY=true
    break
  fi

  [ "$i" -lt "$MAX_RETRIES" ] && sleep "$RETRY_INTERVAL"
done

# ── Step 5: Result ───────────────────────────────────────────────────────────
if [ "$HEALTHY" = "true" ]; then
  success "════════════════════════════════════════"
  success "  DEPLOY SUCCEEDED"
  success "  Version : $VERSION_TAG"
  success "  Image   : $NEW_IMAGE"
  success "  URL     : http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'EC2_IP'):${APP_PORT}"
  success "════════════════════════════════════════"
  exit 0
fi

# ── Rollback ─────────────────────────────────────────────────────────────────
error "Health check FAILED after ${MAX_RETRIES} attempts."
error "Triggering AUTO ROLLBACK..."

docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm   "$CONTAINER_NAME" 2>/dev/null || true

if [ -n "$STABLE_IMAGE" ]; then
  warn "Rolling back to: $STABLE_IMAGE"

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${APP_PORT}:3000" \
    "$STABLE_IMAGE" 2>&1 | tee -a "$LOG_FILE"

  sleep 5

  RB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 "${APP_URL}/health" 2>/dev/null || echo "000")

  if [ "$RB_CODE" = "200" ]; then
    warn "Rollback complete. Previous version is running again."
    warn "Failed image: $NEW_IMAGE"
  else
    error "Rollback health check also failed — manual intervention needed!"
  fi
else
  warn "No stable image to roll back to. Container stopped."
fi

error "Deploy FAILED. See $LOG_FILE for full details."
exit 1
