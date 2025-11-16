#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
HOMELAB_ROOT="/opt/homelab"
STACK_NAME="laptop-homelab"
TZ_DEFAULT="America/New_York"
INSTALL_TAILSCALE="true"
# =====================================

need_cmd() { command -v "$1" &>/dev/null; }
say() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die() { echo -e "\033[1;31m[✗] $*\033[0m"; exit 1; }

# 0) Sanity checks
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash setup-laptop-homelab.sh"
grep -qi "Ubuntu" /etc/os-release || warn "This looks non-Ubuntu. Proceeding anyway."
. /etc/os-release
if ! [[ "${VERSION_ID:-}" =~ ^24\.04 ]]; then
  warn "Not Ubuntu 24.04 (Noble). Detected: ${VERSION_ID:-unknown}. Continuing…"
fi

# 1) Base packages, updates
say "Updating apt and installing base packages…"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates gnupg lsb-release jq unzip ufw htop git

# 2) Install Docker Engine + Compose
if ! need_cmd docker; then
  say "Installing Docker (Engine + CLI + Compose plugin)…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# Add current sudo user to docker group (takes effect next login)
if ! id -nG "${SUDO_USER:-$USER}" | grep -qw docker; then
  say "Adding ${SUDO_USER:-$USER} to docker group…"
  usermod -aG docker "${SUDO_USER:-$USER}"
fi

# 3) Tailscale
if [ "$INSTALL_TAILSCALE" = "true" ]; then
  if ! need_cmd tailscale; then
    say "Installing Tailscale…"
    curl -fsSL https://tailscale.com/install.sh | sh
    say "Tailscale installed. After the script completes, run:  sudo tailscale up"
  else
    say "Tailscale already installed."
  fi
fi

# 4) Firewall (UFW)
say "Configuring UFW…"
ufw allow OpenSSH || true
ufw allow 8080    # Dashy
ufw allow 8096    # Jellyfin
ufw allow 3001    # Uptime Kuma
ufw allow 19999   # Netdata
ufw allow 3000    # Grafana
ufw allow 9090    # Prometheus
ufw allow 9100    # Node Exporter
ufw allow 8081    # Nextcloud
ufw allow 9443    # Portainer

ufw --force enable

# 5) Create homelab structure
say "Creating homelab directories at ${HOMELAB_ROOT}…"
mkdir -p "$HOMELAB_ROOT"/{dashy,jellyfin/config,jellyfin/cache,jellyfin/media,nextcloud/{app,data,db},uptime-kuma,data/netdata,monitoring/{prometheus,grafana,exporters},wireguard,portainer,wazuh}
chown -R "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$HOMELAB_ROOT"

# 6) Generate .env with secrets if missing
ENV_FILE="$HOMELAB_ROOT/.env"
if [ ! -f "$ENV_FILE" ]; then
  say "Generating ${ENV_FILE}…"
  cat > "$ENV_FILE" <<EOF
TZ=${TZ_DEFAULT}

# Nextcloud + MariaDB
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -hex 12)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=$(openssl rand -hex 16)

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 12)
EOF
fi

# 7) Prometheus starter config
if [ ! -f "$HOMELAB_ROOT/monitoring/prometheus/prometheus.yml" ]; then
  say "Writing Prometheus config…"
  cat > "$HOMELAB_ROOT/monitoring/prometheus/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
EOF
fi

# 8) Dashy starter config
if [ ! -f "$HOMELAB_ROOT/dashy/conf.yml" ]; then
  say "Writing Dashy starter config…"
  cat > "$HOMELAB_ROOT/dashy/conf.yml" <<'EOF'
appConfig:
  title: "Laptop Homelab"
  theme: nord-frost
  layout: auto
sections:
  - name: Core
    items:
      - title: Portainer
        url: http://localhost:9443
      - title: Jellyfin
        url: http://localhost:8096
      - title: Nextcloud
        url: http://localhost:8081
      - title: Uptime Kuma
        url: http://localhost:3001
      - title: Netdata
        url: http://localhost:19999
      - title: Grafana
        url: http://localhost:3000
      - title: Prometheus
        url: http://localhost:9090
EOF
fi

# 9) Docker Compose stack
COMPOSE_FILE="$HOMELAB_ROOT/docker-compose.yml"
say "Writing docker-compose.yml…"
cat > "$COMPOSE_FILE" <<'EOF'
services:
  # ---- Dashboard ----
  dashy:
    image: lissy93/dashy:latest
    container_name: dashy
    ports:
      - "8080:8080"
    volumes:
      - ./dashy/conf.yml:/app/public/conf.yml
    environment:
      - NODE_ENV=production
    restart: unless-stopped
    networks: [homelab]

  # ---- Media Server ----
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - ./jellyfin/media:/media
    ports:
      - "8096:8096"
    restart: unless-stopped
    networks: [homelab]
    devices:
      - /dev/dri:/dev/dri

  # ---- Nextcloud + MariaDB ----
  mariadb:
    image: mariadb:11
    container_name: nextcloud-db
    command: --transaction-isolation=READ-COMMITTED --innodb-read-only-compressed=OFF --innodb_buffer_pool_size=512M
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    volumes:
      - ./nextcloud/db:/var/lib/mysql
    restart: unless-stopped
    networks: [homelab]

  nextcloud:
    image: nextcloud:28-apache
    container_name: nextcloud
    depends_on:
      - mariadb
    environment:
      - TZ=${TZ}
      - MYSQL_HOST=mariadb
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
    volumes:
      - ./nextcloud/app:/var/www/html
      - ./nextcloud/data:/var/www/html/data
    ports:
      - "8081:80"
    restart: unless-stopped
    networks: [homelab]

  # ---- Uptime Kuma ----
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    volumes:
      - ./uptime-kuma:/app/data
    ports:
      - "3001:3001"
    restart: unless-stopped
    networks: [homelab]

  # ---- Netdata ----
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    pid: host
    network_mode: host
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
      - SYS_RESOURCE
    security_opt:
      - apparmor:unconfined
    environment:
      - TZ=${TZ}
    volumes:
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - ./data/netdata:/var/lib/netdata
    restart: unless-stopped

  # ---- Metrics Stack ----
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    command: --config.file=/etc/prometheus/prometheus.yml
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./monitoring/prometheus:/prometheus
    ports:
      - "9090:9090"
    restart: unless-stopped
    networks: [homelab]

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    pid: host
    network_mode: host
    restart: unless-stopped

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    ports:
      - "8082:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    restart: unless-stopped
    networks: [homelab]

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      - TZ=${TZ}
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    volumes:
      - ./monitoring/grafana:/var/lib/grafana
    ports:
      - "3000:3000"
    restart: unless-stopped
    networks: [homelab]

  # ---- Portainer ----
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer:/data
    ports:
      - "9443:9443"
    restart: unless-stopped
    networks: [homelab]

networks:
  homelab:
    name: homelab
    driver: bridge
EOF

# 10) Systemd unit to ensure stack is up on boot
SERVICE_FILE="/etc/systemd/system/${STACK_NAME}.service"
say "Creating systemd unit ${STACK_NAME}.service…"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${STACK_NAME} stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${HOMELAB_ROOT}
Environment=COMPOSE_PROJECT_NAME=${STACK_NAME}
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${STACK_NAME}.service"

# 11) Bring the stack up now
say "Bringing the stack up with docker compose…"
( cd "$HOMELAB_ROOT" && docker compose pull && docker compose up -d )

say "=============================================================="
say "Laptop homelab is deploying. Quick links (on this machine):"
echo " Dashy       : http://localhost:8080"
echo " Jellyfin    : http://localhost:8096"
echo " Nextcloud   : http://localhost:8081"
echo " Uptime Kuma : http://localhost:3001"
echo " Netdata     : http://localhost:19999"
echo " Grafana     : http://localhost:3000  (admin / password from $ENV_FILE)"
echo " Prometheus  : http://localhost:9090"
echo " Portainer   : https://localhost:9443"

say "Secrets and settings are in: $ENV_FILE (edit and restart the service if needed)"
say "Manage stack:  sudo systemctl {start|stop|restart|status} ${STACK_NAME}"
if [ "$INSTALL_TAILSCALE" = "true" ]; then
  say "Run 'sudo tailscale up' to authenticate your device to your tailnet."
fi
say "Done!"
