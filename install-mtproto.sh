#!/usr/bin/env bash
#
# MTProto Proxy (telemt-docker) — main configuration & deploy script
# Called by install.sh (bootstrap) or can be run standalone.
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
SERVICE_FILE="${SERVICE_NAME}.service"
UPDATER_TIMER="${SERVICE_NAME}-update"

REPO_RAW="https://raw.githubusercontent.com/civisrom/mt-docker/main"
CONFIG_URL="${REPO_RAW}/config"

# ── colours / helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

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

# download helper: $1=url  $2=destination
download() {
  local url="$1" dest="$2"
  if command -v wget &>/dev/null; then
    wget -qO "$dest" "$url"
  elif command -v curl &>/dev/null; then
    curl -fsSL -o "$dest" "$url"
  else
    err "Neither wget nor curl found."
    exit 1
  fi
  if [[ ! -s "$dest" ]]; then
    err "Failed to download: $url"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in docker openssl sed; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! docker compose version &>/dev/null; then
    missing+=("docker-compose-plugin")
  fi
  if (( ${#missing[@]} )); then
    err "Missing dependencies: ${missing[*]}"
    err "Run install.sh first, or install them manually."
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
  for u in "${SERVICE_FILE}" "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service"; do
    systemctl disable --now "$u" 2>/dev/null || true
    rm -f "/etc/systemd/system/$u"
  done
  systemctl daemon-reload 2>/dev/null || true

  info "Removing ${INSTALL_DIR} …"
  rm -rf "${INSTALL_DIR}"
  info "Uninstall complete."
  exit 0
}

if [[ "${1:-}" == "--uninstall" ]]; then do_uninstall; fi

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
  uname="${uname#"${uname%%[![:space:]]*}"}" # trim leading
  uname="${uname%"${uname##*[![:space:]]}"}" # trim trailing
  if [[ -z "$uname" ]]; then break; fi
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
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  err "Invalid port number: ${PORT} (must be 1–65535)."
  exit 1
fi

ask "Announce IP (external IP of this server):"
read -r ANNOUNCE_IP
if [[ -z "$ANNOUNCE_IP" ]]; then
  err "announce_ip is required."
  exit 1
fi
if [[ "$ANNOUNCE_IP" == *"|"* || "$ANNOUNCE_IP" == *"&"* ]]; then
  err "Invalid characters in announce_ip."
  exit 1
fi

ask "TLS domain (e.g. example.com):"
read -r TLS_DOMAIN
if [[ -z "$TLS_DOMAIN" ]]; then
  err "tls_domain is required."
  exit 1
fi
if [[ "$TLS_DOMAIN" == *"|"* || "$TLS_DOMAIN" == *"&"* ]]; then
  err "Invalid characters in tls_domain."
  exit 1
fi

# --- docker port mapping ---
ask "Host port to expose [${PORT}]:"
read -r HOST_PORT
HOST_PORT=${HOST_PORT:-$PORT}
if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
  err "Invalid host port: ${HOST_PORT} (must be 1–65535)."
  exit 1
fi

# --- systemd service ---
ask "Create systemd service for auto-start? [Y/n]:"
read -r CREATE_SERVICE
CREATE_SERVICE=${CREATE_SERVICE:-Y}

# --- auto-update ---
ask "Enable automatic daily image update? [Y/n]:"
read -r AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-Y}

# ── prepare install directory ───────────────────────────────────────────
info "Creating ${INSTALL_DIR} …"
mkdir -p "${INSTALL_DIR}"

# ── download templates from repo config/ ───────────────────────────────
info "Downloading template: ${CONFIG_FILE} …"
download "${CONFIG_URL}/${CONFIG_FILE}" "${INSTALL_DIR}/${CONFIG_FILE}"

info "Downloading template: ${COMPOSE_FILE} …"
download "${CONFIG_URL}/${COMPOSE_FILE}" "${INSTALL_DIR}/${COMPOSE_FILE}"

# ── patch telemt.toml ──────────────────────────────────────────────────
info "Configuring ${CONFIG_FILE} …"

# build show_link value: ["user1", "user2", ...]
show_link_val=""
for u in "${USERS[@]}"; do
  show_link_val+="\"${u}\", "
done
show_link_val="[${show_link_val%, }]"

# build [access.users] block into a temp file (avoids sed quoting issues)
users_tmp=$(mktemp)
for u in "${USERS[@]}"; do
  echo "${u} = \"${SECRETS[$u]}\"" >> "$users_tmp"
done

# apply values with sed
sed -i "s|^show_link = .*|show_link = ${show_link_val}|" "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^port = .*|port = ${PORT}|"                    "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^announce_ip = .*|announce_ip = \"${ANNOUNCE_IP}\"|" "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^tls_domain = .*|tls_domain = \"${TLS_DOMAIN}\"|"   "${INSTALL_DIR}/${CONFIG_FILE}"

# insert user lines after [access.users] using 'r' (read file) command
sed -i "/^\[access\.users\]$/r ${users_tmp}" "${INSTALL_DIR}/${CONFIG_FILE}"
rm -f "$users_tmp"

# ── patch docker-compose.yml ──────────────────────────────────────────
info "Configuring ${COMPOSE_FILE} …"

# replace port mapping line: "443:443/tcp" → "<HOST_PORT>:<PORT>/tcp"
sed -i "s|\"443:443/tcp\"|\"${HOST_PORT}:${PORT}/tcp\"|" "${INSTALL_DIR}/${COMPOSE_FILE}"

# ── systemd service ────────────────────────────────────────────────────
if [[ "${CREATE_SERVICE,,}" =~ ^y ]]; then
  info "Downloading template: ${SERVICE_FILE} …"
  download "${CONFIG_URL}/${SERVICE_FILE}" "/etc/systemd/system/${SERVICE_FILE}"

  # patch WorkingDirectory in case INSTALL_DIR differs from default
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${INSTALL_DIR}|" "/etc/systemd/system/${SERVICE_FILE}"

  systemctl daemon-reload
  systemctl enable "${SERVICE_FILE}"
  info "Service enabled: ${SERVICE_FILE}"
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
if ! docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" pull; then
  err "Failed to pull Docker image. Check your internet connection."
  exit 1
fi

info "Starting container …"
if ! docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" up -d; then
  err "Failed to start container. Check config with: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} config"
  exit 1
fi

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
