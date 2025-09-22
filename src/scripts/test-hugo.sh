#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/home/coder/documentation-dev"
MARKER_FILE="hugo.yaml"
HUGO_PORT="1313"
LOG_FILE="/var/log/hugo-server.log"
LOCK_FILE="/tmp/hugo_server_started"
BASE_URL="http://preview.localhost/"

# Wait until a TCP port is actually listening
wait_for_port() {
  local port="$1" tries=30
  for _ in $(seq 1 $tries); do
    if ss -lnt | awk '{print $4}' | grep -q ":${port}\$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# If we already started Hugo before, exit quickly
if [[ -f "$LOCK_FILE" ]]; then
  exit 0
fi

echo "[watcher] Starting; waiting for ${TARGET_DIR}/${MARKER_FILE} ..." >&2

# Poll every second for the marker file
while true; do
  if [[ -f "${TARGET_DIR}/${MARKER_FILE}" ]]; then
    echo "[watcher] Found ${MARKER_FILE}; launching Hugo ..." >&2

    # Start Hugo as 'coder', bind to 0.0.0.0 so Traefik can reach it
    # NOTE: --baseURL is optional but recommended for correct links.
    nohup runuser -u coder -- bash -lc \
      "cd '${TARGET_DIR}' && hugo server -D --bind 0.0.0.0 --port ${HUGO_PORT} --baseURL '${BASE_URL}'" \
      >> "${LOG_FILE}" 2>&1 &

    # Confirm the port is up before stopping cron
    if wait_for_port "${HUGO_PORT}"; then
      echo "[watcher] Hugo is listening on :${HUGO_PORT}. Stopping cron." >&2
      touch "${LOCK_FILE}"
      service cron stop || true
      exit 0
    else
      echo '[watcher] Hugo failed to start within timeout. Will retry.' >&2
      # If Hugo failed immediately, loop will continue and retry
    fi
  fi
  sleep 1
done
