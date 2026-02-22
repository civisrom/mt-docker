#!/usr/bin/env bash
#
# MTProto Proxy (telemt-docker) — installation script
# Can be sourced from another script or run standalone.
#
# Usage:
#   bash install-mtproto.sh              # interactive install
#   bash install-mtproto.sh --uninstall  # remove everything
#
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/telemt"
SERVICE_NAME="telemt-compose"
COMPOSE_FILE="docker-compose.yml"
CONFIG_FILE="telemt.toml"
IMAGE="whn0thacked/telemt-docker:latest"
UPDATER_TIMER="${SERVICE_NAME}-update"

# ── colours / helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
ask()   { printf "${CYAN}[?]${NC}    %s " "$*"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (or with sudo)."
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in docker openssl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! docker compose version &>/dev/null 2>&1; then
    missing+=("docker-compose-plugin")
  fi
  if (( ${#missing[@]} )); then
    err "Missing dependencies: ${missing[*]}"
    err "Install them first, then re-run the script."
    exit 1
  fi
}

# ── uninstall ───────────────────────────────────────────────────────────
do_uninstall() {
  need_root
  info "Stopping containers …"
  if [[ -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi

  info "Removing systemd units …"
  for u in "${SERVICE_NAME}.service" "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service"; do
    systemctl disable --now "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u"
  done
  systemctl daemon-reload 2>/dev/null || true

  info "Removing ${INSTALL_DIR} …"
  rm -rf "${INSTALL_DIR}"
  info "Uninstall complete."
  exit 0
}

[[ "${1:-}" == "--uninstall" ]] && do_uninstall

# ── interactive config ──────────────────────────────────────────────────
need_root
check_deps

info "=== MTProto Proxy (telemt) installer ==="
echo ""

# --- users ---
declare -a USERS=()
declare -A SECRETS=()

while true; do
  ask "Enter username (or empty to finish):"
  read -r uname
  uname=$(echo "$uname" | xargs)           # trim
  [[ -z "$uname" ]] && break
  # sanitise: only [a-zA-Z0-9_-]
  if [[ ! "$uname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    warn "Username may only contain letters, digits, '_' and '-'. Try again."
    continue
  fi
  secret=$(openssl rand -hex 16)
  USERS+=("$uname")
  SECRETS["$uname"]="$secret"
  info "Added user: ${uname}  secret: ${secret}"
done

if (( ${#USERS[@]} == 0 )); then
  err "At least one user is required."
  exit 1
fi

# --- server ---
ask "Server port [443]:"
read -r PORT
PORT=${PORT:-443}

ask "Announce IP (external IP of this server):"
read -r ANNOUNCE_IP
if [[ -z "$ANNOUNCE_IP" ]]; then
  err "announce_ip is required."
  exit 1
fi

ask "TLS domain [online.${ANNOUNCE_IP}.sslip.io]:"
read -r TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-"online.${ANNOUNCE_IP}.sslip.io"}

# --- docker port mapping ---
ask "Host port to expose [${PORT}]:"
read -r HOST_PORT
HOST_PORT=${HOST_PORT:-$PORT}

# --- systemd service ---
ask "Create systemd service for auto-start? [Y/n]:"
read -r CREATE_SERVICE
CREATE_SERVICE=${CREATE_SERVICE:-Y}

# --- auto-update ---
ask "Enable automatic daily image update? [Y/n]:"
read -r AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-Y}

# ── generate files ──────────────────────────────────────────────────────
info "Creating ${INSTALL_DIR} …"
mkdir -p "${INSTALL_DIR}"

# --- telemt.toml ---
info "Writing ${CONFIG_FILE} …"

show_link_list=""
users_block=""
for u in "${USERS[@]}"; do
  show_link_list+="\"${u}\", "
  users_block+="${u} = \"${SECRETS[$u]}\"\n"
done
# trim trailing ", "
show_link_list="${show_link_list%, }"

cat > "${INSTALL_DIR}/${CONFIG_FILE}" <<TOMLEOF
show_link = [${show_link_list}]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PORT}
listen_addr_ipv4 = "0.0.0.0"
#listen_addr_ipv6 = "::"
# metrics_port = 9090
# metrics_whitelist = ["127.0.0.1", "::1"]

[[server.listeners]]
ip = "0.0.0.0"
announce_ip = "${ANNOUNCE_IP}"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_port = 443
fake_cert_len = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
$(printf "%b" "$users_block")
[[upstreams]]
type = "direct"
enabled = true
weight = 10
TOMLEOF

# --- docker-compose.yml ---
info "Writing ${COMPOSE_FILE} …"
cat > "${INSTALL_DIR}/${COMPOSE_FILE}" <<YAMLEOF
services:
  telemt:
    image: ${IMAGE}
    container_name: telemt
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./${CONFIG_FILE}:/etc/telemt.toml:ro
    ports:
      - "${HOST_PORT}:${PORT}/tcp"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
YAMLEOF

# ── systemd service ────────────────────────────────────────────────────
if [[ "${CREATE_SERVICE,,}" =~ ^y ]]; then
  info "Creating systemd service ${SERVICE_NAME}.service …"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=Telemt MTProto Proxy (Docker Compose)
Documentation=https://github.com/An0nX/telemt-docker
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
# Wait for Docker to be fully ready
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break || sleep 3; done'
# Validate docker-compose.yml configuration
ExecStartPre=/usr/bin/docker compose config -q
# Pull latest images before starting
ExecStartPre=-/usr/bin/docker compose pull -q
# Start containers
ExecStart=/usr/bin/docker compose up -d --wait
# Reload containers configuration
ExecReload=/usr/bin/docker compose up -d --force-recreate
# Stop containers
ExecStop=/usr/bin/docker compose down
# Show last 50 lines of logs after stop (for debugging)
ExecStopPost=-/usr/bin/docker compose logs --tail=50
# Keep service active after start
RemainAfterExit=yes
# Restart on failure
Restart=on-failure
RestartSec=30
# Timeouts
TimeoutStartSec=300
TimeoutStopSec=120
# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
# Resource limits
LimitNOFILE=65536
LimitNPROC=512

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  info "Service enabled: ${SERVICE_NAME}.service"
fi

# ── auto-update timer ──────────────────────────────────────────────────
if [[ "${AUTO_UPDATE,,}" =~ ^y ]]; then
  info "Creating auto-update timer …"

  cat > "/etc/systemd/system/${UPDATER_TIMER}.service" <<UPDEOF
[Unit]
Description=Update Telemt MTProto Docker image
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/sh -c '\
  docker compose pull -q && \
  docker compose up -d --remove-orphans && \
  docker image prune -f'
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${UPDATER_TIMER}
UPDEOF

  cat > "/etc/systemd/system/${UPDATER_TIMER}.timer" <<TMREOF
[Unit]
Description=Daily update for Telemt MTProto Docker image

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

  systemctl daemon-reload
  systemctl enable --now "${UPDATER_TIMER}.timer"
  info "Auto-update timer enabled (daily at ~04:00)."
fi

# ── pull image & start ─────────────────────────────────────────────────
info "Pulling Docker image …"
docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" pull

info "Starting container …"
docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" up -d

# ── summary ─────────────────────────────────────────────────────────────
echo ""
info "========================================"
info " Installation complete!"
info "========================================"
info "Install dir : ${INSTALL_DIR}"
info "Config      : ${INSTALL_DIR}/${CONFIG_FILE}"
info "Compose     : ${INSTALL_DIR}/${COMPOSE_FILE}"
info "Port        : ${HOST_PORT} -> ${PORT}"
echo ""
info "Users & secrets:"
for u in "${USERS[@]}"; do
  info "  ${u} = ${SECRETS[$u]}"
done
echo ""
if [[ "${CREATE_SERVICE,,}" =~ ^y ]]; then
  info "Service     : systemctl {start|stop|status} ${SERVICE_NAME}"
fi
if [[ "${AUTO_UPDATE,,}" =~ ^y ]]; then
  info "Auto-update : systemctl list-timers ${UPDATER_TIMER}.timer"
fi
echo ""
info "To view logs: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} logs -f"
