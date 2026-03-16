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
header(){ printf "\n${BOLD}── %s ──${NC}\n\n" "$*"; }

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
  for cmd in docker openssl sed xxd; do
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

# ── input validation helpers ──────────────────────────────────────────
is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets
  read -ra octets <<< "$ip"
  (( ${#octets[@]} == 4 )) || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

is_valid_domain() {
  local d="$1"
  # Basic domain validation: alphanumeric, hyphens, dots, 2+ parts
  [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$d" == *.* ]]
}

# Sanitize input: strip dangerous characters for sed usage
sanitize_input() {
  local val="$1"
  # Reject if contains shell metacharacters
  if [[ "$val" == *"|"* || "$val" == *"&"* || "$val" == *";"* || \
        "$val" == *"\`"* || "$val" == *"\$"* || "$val" == *">"* || \
        "$val" == *"<"* || "$val" == *"'"* || "$val" == *"\\"* ]]; then
    return 1
  fi
  return 0
}

# Auto-detect public IP via external services
detect_public_ip() {
  local ip=""
  local services=(
    "https://ifconfig.me"
    "https://api.ipify.org"
    "https://ipecho.net/plain"
    "https://icanhazip.com"
  )
  local svc
  for svc in "${services[@]}"; do
    ip=$(curl -fsSL --connect-timeout 5 --max-time 10 "$svc" 2>/dev/null || true)
    ip="${ip%%[[:space:]]*}"  # trim whitespace/newlines
    if is_valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# ── detect existing installation ──────────────────────────────────────
# Searches for install dirs in: default path, systemd service files,
# running/stopped containers, and docker images.
# Sets: FOUND_DIRS (array), FOUND_CONTAINER (bool), FOUND_IMAGE (bool)
detect_existing_install() {
  FOUND_DIRS=()
  FOUND_CONTAINER=false
  FOUND_IMAGE=false

  # helper: add dir to FOUND_DIRS if not already present
  _add_dir() {
    local d="$1"
    if [[ -z "$d" || ! -d "$d" ]]; then return; fi
    local existing
    for existing in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
      if [[ "$existing" == "$d" ]]; then return; fi
    done
    FOUND_DIRS+=("$d")
  }

  # 1. Default install directory
  _add_dir "${INSTALL_DIR}"

  # 2. WorkingDirectory from systemd service files
  local svc_path
  for svc_path in \
    "/etc/systemd/system/${SERVICE_FILE}" \
    "/etc/systemd/system/${UPDATER_TIMER}.service"
  do
    if [[ -f "$svc_path" ]]; then
      local wd
      wd=$(grep '^WorkingDirectory=' "$svc_path" 2>/dev/null | cut -d= -f2- || true)
      _add_dir "$wd"
    fi
  done

  # 3. Check for telemt container (running or stopped)
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
    FOUND_CONTAINER=true
  fi

  # 4. Check for telemt docker image
  if docker images --format '{{.Repository}}' 2>/dev/null | grep -qx 'whn0thacked/telemt-docker'; then
    FOUND_IMAGE=true
  fi

  # Return 0 if anything was found
  if (( ${#FOUND_DIRS[@]} > 0 )) || $FOUND_CONTAINER || $FOUND_IMAGE; then
    return 0
  fi
  return 1
}

# ── cleanup existing installation (targeted — telemt only) ────────────
cleanup_existing_install() {
  echo ""
  info "── Removing existing telemt MTProto installation ──"

  # 1. Stop containers via compose (for each found install dir)
  local dir
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    if [[ -f "${dir}/${COMPOSE_FILE}" ]]; then
      info "Stopping containers (${dir}/${COMPOSE_FILE}) …"
      docker compose -f "${dir}/${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
    fi
  done

  # 2. Force-remove container 'telemt' if still present
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
    info "Force-removing container 'telemt' …"
    docker rm -f telemt 2>/dev/null || true
  fi

  # 3. Remove only telemt docker images (all tags)
  local telemt_image_ids
  telemt_image_ids=$(docker images --format '{{.ID}}' --filter 'reference=whn0thacked/telemt-docker' 2>/dev/null || true)
  if [[ -n "$telemt_image_ids" ]]; then
    info "Removing telemt Docker images …"
    local img_id
    while IFS= read -r img_id; do
      docker rmi -f "$img_id" 2>/dev/null || true
    done <<< "$telemt_image_ids"
  fi

  # 4. Disable and remove systemd units
  info "Removing systemd units …"
  local u
  for u in "${SERVICE_FILE}" "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service"; do
    if [[ -f "/etc/systemd/system/$u" ]]; then
      systemctl disable --now "$u" 2>/dev/null || true
      rm -f "/etc/systemd/system/$u"
      info "  removed: $u"
    fi
  done
  systemctl daemon-reload 2>/dev/null || true

  # 5. Remove install directories and their config files
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    if [[ -d "$dir" ]]; then
      info "Removing directory: ${dir} …"
      rm -rf "$dir"
    fi
  done

  info "── Cleanup complete ──"
  echo ""
}

# ── uninstall (--uninstall flag) ──────────────────────────────────────
do_uninstall() {
  need_root

  if detect_existing_install; then
    cleanup_existing_install
  else
    warn "No existing telemt installation found."
  fi

  info "Uninstall complete."
  exit 0
}

if [[ "${1:-}" == "--uninstall" ]]; then do_uninstall; fi

# ══════════════════════════════════════════════════════════════════════════
# ██  INTERACTIVE CONFIGURATION                                          ██
# ══════════════════════════════════════════════════════════════════════════
need_root
check_deps

echo ""
info "=== MTProto Proxy (telemt) — Host Mode Installer ==="
echo ""

# ── detect & offer to remove previous installation ───────────────────
if detect_existing_install; then
  header "Existing telemt installation detected"

  # show what was found
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    info "  Install directory : ${dir}"
    if [[ -f "${dir}/${CONFIG_FILE}" ]]; then
      info "    config          : ${dir}/${CONFIG_FILE}"
    fi
    if [[ -f "${dir}/${COMPOSE_FILE}" ]]; then
      info "    compose         : ${dir}/${COMPOSE_FILE}"
    fi
  done
  if $FOUND_CONTAINER; then
    cstate=$(docker inspect -f '{{.State.Status}}' telemt 2>/dev/null || echo "unknown")
    info "  Container 'telemt': ${cstate}"
  fi
  if $FOUND_IMAGE; then
    itag=$(docker images --format '{{.Repository}}:{{.Tag}}  ({{.Size}})' --filter 'reference=whn0thacked/telemt-docker' 2>/dev/null | head -1 || echo "present")
    info "  Image             : ${itag}"
  fi

  echo ""
  printf "${BOLD}Choose an option:${NC}\n"
  echo "  1) Remove existing installation completely and install fresh"
  echo "  2) Cancel installation"
  echo ""
  ask "Your choice [1/2]:"
  read -r reinstall_choice

  case "${reinstall_choice}" in
    1)
      cleanup_existing_install
      ;;
    2)
      info "Installation cancelled."
      exit 0
      ;;
    *)
      err "Invalid choice. Exiting."
      exit 1
      ;;
  esac
fi

# ─────────────────────────────────────────────────────────────────────────
# §1  USERS
# ─────────────────────────────────────────────────────────────────────────
header "User configuration"

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

# ─────────────────────────────────────────────────────────────────────────
# §2  NETWORK CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────
header "Network configuration (host mode)"

info "Container runs in host network mode — the port you set here"
info "is the actual port on the host. Make sure it's not in use."
echo ""

# --- server port ---
while true; do
  ask "Telemt listen port [443]:"
  read -r PORT
  PORT=${PORT:-443}
  if ! is_valid_port "$PORT"; then
    warn "Invalid port: ${PORT} (must be 1–65535). Try again."
    continue
  fi
  # Check if port is already in use (best-effort)
  if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      warn "Port ${PORT} appears to be already in use on this host."
      ask "Use it anyway? [y/N]:"
      read -r confirm_busy
      if [[ ! "${confirm_busy,,}" =~ ^y ]]; then
        continue
      fi
    fi
  fi
  break
done

# --- announce IP ---
echo ""
info "announce_ip — the public IP that telemt advertises in proxy links."
info "Clients (Telegram relay servers) connect to this IP."
echo ""

DETECTED_IP=""
info "Detecting public IP …"
if DETECTED_IP=$(detect_public_ip); then
  info "Detected: ${DETECTED_IP}"
else
  warn "Could not auto-detect public IP."
fi

while true; do
  if [[ -n "$DETECTED_IP" ]]; then
    ask "Announce IP [${DETECTED_IP}]:"
    read -r ANNOUNCE_IP
    ANNOUNCE_IP=${ANNOUNCE_IP:-$DETECTED_IP}
  else
    ask "Announce IP (external IP of this server):"
    read -r ANNOUNCE_IP
  fi

  if [[ -z "$ANNOUNCE_IP" ]]; then
    warn "announce_ip is required."
    continue
  fi
  if ! sanitize_input "$ANNOUNCE_IP"; then
    warn "Invalid characters in IP address."
    continue
  fi
  if ! is_valid_ipv4 "$ANNOUNCE_IP"; then
    warn "Invalid IPv4 address: ${ANNOUNCE_IP}. Try again."
    continue
  fi
  break
done

# ─────────────────────────────────────────────────────────────────────────
# §3  TLS MASKING (CENSORSHIP BYPASS)
# ─────────────────────────────────────────────────────────────────────────
header "TLS masking (censorship bypass)"

info "Telemt disguises MTProto traffic as TLS to a legitimate website."
info "Choose a popular HTTPS site that is NOT blocked in your region."
info "Examples: www.google.com, www.microsoft.com, cloudflare.com"
echo ""

# --- TLS domain ---
while true; do
  ask "TLS domain [www.google.com]:"
  read -r TLS_DOMAIN
  TLS_DOMAIN=${TLS_DOMAIN:-www.google.com}

  if ! sanitize_input "$TLS_DOMAIN"; then
    warn "Invalid characters in domain."
    continue
  fi
  if ! is_valid_domain "$TLS_DOMAIN"; then
    warn "Invalid domain format: ${TLS_DOMAIN}. Try again."
    continue
  fi
  break
done

# mask_port — HTTPS port on the masking domain, always 443
MASK_PORT=443

# ─────────────────────────────────────────────────────────────────────────
# §4  SYSTEMD & AUTO-UPDATE
# ─────────────────────────────────────────────────────────────────────────
header "Systemd & auto-update"

ask "Create systemd service for auto-start? [Y/n]:"
read -r CREATE_SERVICE
CREATE_SERVICE=${CREATE_SERVICE:-Y}

ask "Enable automatic daily image update? [Y/n]:"
read -r AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-Y}

# ══════════════════════════════════════════════════════════════════════════
# ██  DEPLOYMENT                                                          ██
# ══════════════════════════════════════════════════════════════════════════

header "Deploying"

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
trap 'rm -f "$users_tmp"' EXIT
for u in "${USERS[@]}"; do
  echo "${u} = \"${SECRETS[$u]}\"" >> "$users_tmp"
done

# apply values with sed
sed -i "s|^show_link = .*|show_link = ${show_link_val}|"              "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^port = .*|port = ${PORT}|"                                 "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^announce_ip = .*|announce_ip = \"${ANNOUNCE_IP}\"|"         "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^tls_domain = .*|tls_domain = \"${TLS_DOMAIN}\"|"           "${INSTALL_DIR}/${CONFIG_FILE}"
sed -i "s|^mask_port = .*|mask_port = ${MASK_PORT}|"                   "${INSTALL_DIR}/${CONFIG_FILE}"

# insert user lines after [access.users] using 'r' (read file) command
sed -i "/^\[access\.users\]$/r ${users_tmp}" "${INSTALL_DIR}/${CONFIG_FILE}"
rm -f "$users_tmp"
trap - EXIT

# ── Note: docker-compose.yml uses network_mode: host ─────────────────
# Port exposure is controlled by telemt.toml [server] port setting,
# not by Docker port mapping. No compose patching needed.

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
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
# Pull with timeout, recreate only if image changed, prune old images
ExecStart=/bin/sh -c '\
  docker compose pull -q && \
  docker compose up -d --remove-orphans && \
  docker image prune -f'
# Retry on transient network failures
Restart=on-failure
RestartSec=60
# Timeout for pull (large images, slow connections)
TimeoutStartSec=300
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

cd "${INSTALL_DIR}" || { err "Cannot cd to ${INSTALL_DIR}"; exit 1; }

if ! docker compose pull; then
  err "Failed to pull Docker image. Check your internet connection."
  exit 1
fi

info "Starting container …"
if ! docker compose up -d; then
  err "Failed to start container. Check config with: docker compose config"
  exit 1
fi

# ── wait for container to be healthy ──────────────────────────────────
info "Waiting for telemt to start …"
sleep 2
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
  info "Container 'telemt' is running."
else
  warn "Container may not have started properly. Check: docker logs telemt"
fi

# ── verify port is listening ──────────────────────────────────────────
if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    info "Port ${PORT} is listening — OK"
  else
    warn "Port ${PORT} does not appear to be listening yet."
    warn "Check container logs: docker logs telemt"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
# ██  SUMMARY                                                             ██
# ══════════════════════════════════════════════════════════════════════════
echo ""
printf "${BOLD}════════════════════════════════════════════${NC}\n"
printf "${GREEN}${BOLD}  Installation complete!${NC}\n"
printf "${BOLD}════════════════════════════════════════════${NC}\n"
echo ""
info "Install dir  : ${INSTALL_DIR}"
info "Config       : ${INSTALL_DIR}/${CONFIG_FILE}"
info "Compose      : ${INSTALL_DIR}/${COMPOSE_FILE}"
info "Network      : host mode (no Docker port mapping)"
info "Listen port  : ${PORT}"
info "Announce IP  : ${ANNOUNCE_IP}"
info "TLS domain   : ${TLS_DOMAIN}:${MASK_PORT}"
echo ""

# ── proxy links ────────────────────────────────────────────────────────
info "Users & proxy links:"
echo ""

# Hex-encode TLS domain for fake-TLS secret (ee prefix)
domain_hex=$(printf '%s' "${TLS_DOMAIN}" | xxd -p | tr -d '\n')

for u in "${USERS[@]}"; do
  s="${SECRETS[$u]}"
  # fake-TLS secret format: ee + 32 hex secret + hex-encoded SNI domain
  encoded_secret="ee${s}${domain_hex}"

  # Build tg:// proxy link
  tg_link="tg://proxy?server=${ANNOUNCE_IP}&port=${PORT}&secret=${encoded_secret}"

  printf "  ${BOLD}%s${NC}\n" "$u"
  printf "    Secret : %s\n" "$s"
  printf "    Link   : ${CYAN}%s${NC}\n" "$tg_link"
  echo ""
done

# ── management commands ────────────────────────────────────────────────
header "Management commands"

if [[ "${CREATE_SERVICE,,}" =~ ^y ]]; then
  info "Service     : systemctl {start|stop|restart|status} ${SERVICE_NAME}"
  info "Reload      : systemctl reload ${SERVICE_NAME}"
fi
if [[ "${AUTO_UPDATE,,}" =~ ^y ]]; then
  info "Auto-update : systemctl list-timers ${UPDATER_TIMER}.timer"
fi
info "Logs        : docker logs telemt --tail=50 -f"
info "Config      : nano ${INSTALL_DIR}/${CONFIG_FILE}"
info "Restart     : docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} up -d --force-recreate"
info "Uninstall   : bash install-mtproto.sh --uninstall"

# ── nftables reminder ──────────────────────────────────────────────────
echo ""
printf "${YELLOW}${BOLD}⚠  FIREWALL REMINDER:${NC}\n"
printf "${YELLOW}   Make sure your nftables config allows traffic on port ${PORT}.${NC}\n"
printf "${YELLOW}   Check: define TELEMT_PORT = ${PORT}${NC}\n"
printf "${YELLOW}   Apply: nft -f /etc/nftables.conf${NC}\n"
echo ""
