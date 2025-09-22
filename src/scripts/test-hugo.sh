#!/usr/bin/env bash
set -euo pipefail

# Configuration
TARGET_DIR="/home/coder/documentation-dev"
MARKER_FILE="hugo.yaml"
HUGO_PORT="1313"
LOG_FILE="/var/log/hugo-server.log"
LOCK_FILE="/tmp/hugo_server_started"

# Helper: is process listening on port?
is_port_busy() {
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${HUGO_PORT}$"
}

# If already started once, quit quickly
if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

# Poll every second until the marker file appears
while true; do
  if [[ -f "${TARGET_DIR}/${MARKER_FILE}" ]]; then
    # Ensure hugo not already running
    if ! is_port_busy; then
      # Start Hugo as 'coder' user, bound to 0.0.0.0 so Traefik can route to it
      nohup runuser -u coder -- bash -lc "cd '${TARGET_DIR}' && hugo server -D --bind 0.0.0.0 --port ${HUGO_PORT}" \
        >> "${LOG_FILE}" 2>&1 &

      # Mark as started
      touch "${LOCK_FILE}"

      # Stop cron as requested (no further per-second checks needed)
      service cron stop || true
    fi
    exit 0
  fi

  sleep 1
done
