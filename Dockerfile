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
      python3 python3-pip python3-venv && \
    apt-get install -y --no-install-recommends \
      hugo && \
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
# Clone-Repo web app (Flask) on 8081 → setup.localhost
# ------------------------------------------------------------
WORKDIR /opt/clone-repo

# Create and activate virtualenv for Python deps (avoids PEP 668 issues)
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Install deps into venv
COPY src/clone-repo/requirements.txt /opt/clone-repo/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /opt/clone-repo/requirements.txt

# App sources
COPY src/clone-repo/ /opt/clone-repo/
RUN chown -R coder:coder /opt/clone-repo

# ------------------------------------------------------------
# Traefik (as reverse proxy for dev.localhost + setup.localhost)
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
# - dev.localhost   → code-server (http://127.0.0.1:8080)
# - setup.localhost → Flask app  (http://127.0.0.1:8081)
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
  services:
    code:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
    setup:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8081"
EOF

# ------------------------------------------------------------
# Startup script: Traefik (80), code-server (8080), Flask app (8081 via venv)
# ------------------------------------------------------------
RUN cat <<'EOS' > /usr/local/bin/start.sh
#!/usr/bin/env bash
set -euo pipefail

# Ensure workspace exists
mkdir -p /home/coder/documentation-dev
chown -R coder:coder /home/coder

# 1) Traefik (root for port 80)
traefik --configFile=/etc/traefik/traefik.yml &
TRAEFIK_PID=$!

# 2) code-server on 8080
sudo -u coder -H /usr/bin/code-server \
  --bind-addr 0.0.0.0:8080 \
  --auth none \
  --disable-telemetry \
  /home/coder/documentation-dev &
CODE_PID=$!

# 3) Flask app on 8081 (use venv)
sudo -u coder -H bash -lc '/opt/venv/bin/python -m flask --app /opt/clone-repo/app:app run --host=0.0.0.0 --port=8081' &
FLASK_PID=$!

trap "kill -TERM $TRAEFIK_PID $CODE_PID $FLASK_PID 2>/dev/null || true" TERM INT
wait -n $TRAEFIK_PID $CODE_PID $FLASK_PID
EOS
RUN chmod +x /usr/local/bin/start.sh

# ------------------------------------------------------------
# Networking + Entrypoint
# ------------------------------------------------------------
EXPOSE 80
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/start.sh"]
