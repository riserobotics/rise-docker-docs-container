# Ubuntu base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ------------------------------------------------------------
# System packages + Hugo (apt instead of snap – snapd is unsuitable in containers)
# ------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget git unzip \
      tini dumb-init gnupg tar xz-utils \
      adduser sudo procps \
      python3 python3-pip python3-venv \
      cron && \
    apt-get install -y --no-install-recommends hugo && \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Create non-root user 'coder' for code-server
# ------------------------------------------------------------
RUN adduser --disabled-password --gecos "" coder && \
    usermod -aG sudo coder && \
    mkdir -p /home/coder && chown -R coder:coder /home/coder

# ------------------------------------------------------------
# code-server (VS Code in the browser)
# ------------------------------------------------------------
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Workspace
RUN mkdir -p /home/coder/documentation-dev && chown -R coder:coder /home/coder/documentation-dev

# VS Code defaults: dark theme, no welcome screen
RUN mkdir -p /home/coder/.local/share/code-server/User && \
    cat <<'EOF' > /home/coder/.local/share/code-server/User/settings.json
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.preferredDarkColorTheme": "Default Dark Modern",
  "window.autoDetectColorScheme": false,
  "workbench.startupEditor": "none",
  "telemetry.telemetryLevel": "off",
  "update.showReleaseNotes": false,
  "workbench.tips.enabled": false
}
EOF
RUN chown -R coder:coder /home/coder/.local

# ------------------------------------------------------------
# Flask clone-repo app (serves on 8081 → setup.localhost)
# ------------------------------------------------------------
WORKDIR /opt/clone-repo

# Use venv to avoid PEP 668 issues
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Dependencies
COPY src/clone-repo/requirements.txt /opt/clone-repo/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /opt/clone-repo/requirements.txt

# App sources
COPY src/clone-repo/ /opt/clone-repo/
RUN chown -R coder:coder /opt/clone-repo

# ------------------------------------------------------------
# Cron watcher script (runs every second via a loop; started by cron at boot)
# ------------------------------------------------------------
# Copy the script placed in your repo at src/scripts/test-hugo.sh
COPY src/scripts/test-hugo.sh /usr/local/bin/test-hugo.sh
RUN chmod +x /usr/local/bin/test-hugo.sh

# Install a root crontab that launches the watcher on container start
# We use @reboot to start a long-running loop that checks every second.
RUN printf '@reboot /usr/local/bin/test-hugo.sh >> /var/log/test-hugo.log 2>&1\n' > /etc/cron.d/hugo-watcher && \
    chmod 0644 /etc/cron.d/hugo-watcher && \
    crontab /etc/cron.d/hugo-watcher

# ------------------------------------------------------------
# Traefik (reverse proxy for dev/setup/preview hosts)
# ------------------------------------------------------------
ARG TRAEFIK_VERSION=v3.1.5
RUN mkdir -p /usr/local/bin /etc/traefik /etc/traefik/dynamic
RUN curl -fsSL "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" \
  | tar -xz -C /usr/local/bin traefik && \
  chmod +x /usr/local/bin/traefik

# Static Traefik configuration
RUN cat <<'EOF' > /etc/traefik/traefik.yml
entryPoints:
  web:
    address: ":80"
providers:
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
log:
  level: "INFO"
api:
  dashboard: false
EOF

# Dynamic routes:
# - dev.localhost     → code-server (http://127.0.0.1:8080)
# - setup.localhost   → Flask app  (http://127.0.0.1:8081)
# - preview.localhost → Hugo       (http://127.0.0.1:1313)
RUN cat <<'EOF' > /etc/traefik/dynamic/dev.yml
http:
  routers:
    code:
      rule: "Host(`dev.localhost`)"
      entryPoints: ["web"]
      service: "code"
    setup:
      rule: "Host(`setup.localhost`)"
      entryPoints: ["web"]
      service: "setup"
    preview:
      rule: "Host(`preview.localhost`)"
      entryPoints: ["web"]
      service: "preview"
  services:
    code:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
    setup:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8081"
    preview:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:1313"
EOF

# ------------------------------------------------------------
# Startup script: Traefik (80), code-server (8080), Flask app (8081), cron
# ------------------------------------------------------------
RUN cat <<'EOS' > /usr/local/bin/start.sh
#!/usr/bin/env bash
set -euo pipefail

# Ensure workspace exists
mkdir -p /home/coder/documentation-dev
chown -R coder:coder /home/coder

# 1) Start Traefik (port 80)
traefik --configFile=/etc/traefik/traefik.yml &
TRAEFIK_PID=$!

# 2) Start code-server (8080)
sudo -u coder -H /usr/bin/code-server \
  --bind-addr 0.0.0.0:8080 \
  --auth none \
  --disable-telemetry \
  /home/coder/documentation-dev &
CODE_PID=$!

# 3) Start Flask app (8081) via venv
sudo -u coder -H bash -lc '/opt/venv/bin/python -m flask --app /opt/clone-repo/app:app run --host=0.0.0.0 --port=8081' &
FLASK_PID=$!

# 4) Start cron (which launches the per-second watcher at boot)
cron
# keep cron running in background; the test-hugo.sh will stop cron once hugo starts

trap "kill -TERM $TRAEFIK_PID $CODE_PID $FLASK_PID 2>/dev/null || true; service cron stop || true" TERM INT
wait -n $TRAEFIK_PID $CODE_PID $FLASK_PID
EOS
RUN chmod +x /usr/local/bin/start.sh

# ------------------------------------------------------------
# Networking + Entrypoint
# ------------------------------------------------------------
EXPOSE 80
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/start.sh"]
