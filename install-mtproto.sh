#!/usr/bin/env bash
#
# MTProto Proxy (telemt-docker) — main configuration & deploy script
# Called by install.sh (bootstrap) or can be run standalone.
#
# Usage:
#   bash install-mtproto.sh              # interactive install
#   bash install-mtproto.sh --uninstall  # remove everything
#   bash install-mtproto.sh --list-versions    # show available versions
#   bash install-mtproto.sh --set-version [V]  # switch to version V (interactive if V omitted)
#   bash install-mtproto.sh --update-status    # show current version & update state
#   bash install-mtproto.sh --update-enable    # enable auto-update timer
#   bash install-mtproto.sh --update-disable   # disable auto-update timer
#
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/telemt"
CONFIG_DIR="telemt-config"       # subdirectory for telemt.toml (mounted as volume)
SERVICE_NAME="telemt-compose"
COMPOSE_FILE="docker-compose.yml"
CONFIG_FILE="telemt.toml"
SERVICE_FILE="${SERVICE_NAME}.service"
UPDATER_TIMER="${SERVICE_NAME}-update"

REPO_RAW="https://raw.githubusercontent.com/civisrom/mt-docker/main"
CONFIG_URL="${REPO_RAW}/config"

DOCKER_IMAGE="whn0thacked/telemt-docker"
DOCKER_HUB_API="https://hub.docker.com/v2/repositories/${DOCKER_IMAGE}/tags"
VERSION_FILE="${INSTALL_DIR}/.telemt-version"

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
  # Only check compose plugin if docker itself is present
  if command -v docker &>/dev/null && ! docker compose version &>/dev/null; then
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
# Searches for install dirs, systemd units, containers (by name AND by
# image), and docker images.  Sets:
#   FOUND_DIRS        — array of install directories
#   FOUND_CONTAINERS  — array of container IDs (by name + by image)
#   FOUND_SYSTEMD     — array of systemd unit file paths
#   FOUND_IMAGE       — bool (telemt image present)
detect_existing_install() {
  FOUND_DIRS=()
  FOUND_CONTAINERS=()
  FOUND_SYSTEMD=()
  FOUND_IMAGE=false

  # helper: deduplicate values in an array variable
  _add_dir() {
    local d="$1"
    [[ -z "$d" || ! -d "$d" ]] && return
    local e; for e in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
      [[ "$e" == "$d" ]] && return
    done
    FOUND_DIRS+=("$d")
  }

  _add_container() {
    local c="$1"
    [[ -z "$c" ]] && return
    local e; for e in "${FOUND_CONTAINERS[@]+"${FOUND_CONTAINERS[@]}"}"; do
      [[ "$e" == "$c" ]] && return
    done
    FOUND_CONTAINERS+=("$c")
  }

  # ── 1. Install directories ───────────────────────────────────────────
  # 1a. Default path
  _add_dir "${INSTALL_DIR}"

  # 1b. WorkingDirectory from systemd service files
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

  # ── 2. Systemd units (service + timer + updater) ─────────────────────
  local u
  for u in "${SERVICE_FILE}" "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service"; do
    [[ -f "/etc/systemd/system/$u" ]] && FOUND_SYSTEMD+=("$u")
  done

  # ── 3. Containers — by name 'telemt' ─────────────────────────────────
  local cid
  cid=$(docker ps -a --filter 'name=^telemt$' --format '{{.ID}}' 2>/dev/null || true)
  [[ -n "$cid" ]] && _add_container "$cid"

  # ── 4. Containers — by image 'whn0thacked/telemt-docker' ─────────────
  #       Catches containers even if container_name was changed.
  local img_cids
  img_cids=$(docker ps -a --filter 'ancestor=whn0thacked/telemt-docker' --format '{{.ID}}' 2>/dev/null || true)
  if [[ -n "$img_cids" ]]; then
    while IFS= read -r cid; do
      _add_container "$cid"
    done <<< "$img_cids"
  fi

  # ── 5. Docker image ──────────────────────────────────────────────────
  if docker images --format '{{.Repository}}' 2>/dev/null | grep -qx 'whn0thacked/telemt-docker'; then
    FOUND_IMAGE=true
  fi

  # Return 0 if anything was found
  if (( ${#FOUND_DIRS[@]} > 0 )) || \
     (( ${#FOUND_CONTAINERS[@]} > 0 )) || \
     (( ${#FOUND_SYSTEMD[@]} > 0 )) || \
     $FOUND_IMAGE; then
    return 0
  fi
  return 1
}

# ── cleanup existing installation (targeted — telemt only) ────────────
# Order of operations is critical:
#   1. Stop systemd units FIRST  (prevents them from restarting containers)
#   2. docker compose down        (graceful container + network + volume stop)
#   3. Force-remove leftover containers (by ID — catches renamed ones too)
#   4. Remove telemt docker images (only whn0thacked/telemt-docker)
#   5. Prune dangling image layers
#   6. Remove systemd unit files
#   7. Remove install directories
cleanup_existing_install() {
  echo ""
  info "── Removing existing telemt MTProto installation ──"

  # ── 1. Stop systemd units first (prevents restart races) ─────────────
  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    info "Stopping systemd units …"
    local u
    for u in "${FOUND_SYSTEMD[@]}"; do
      info "  stopping: $u"
      systemctl stop "$u" 2>/dev/null || true
      systemctl disable "$u" 2>/dev/null || true
    done
  fi

  # ── 2. docker compose down (graceful: stops containers, removes ──────
  #        project networks and anonymous volumes)
  local dir
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    if [[ -f "${dir}/${COMPOSE_FILE}" ]]; then
      info "Running compose down (${dir}/${COMPOSE_FILE}) …"
      docker compose -f "${dir}/${COMPOSE_FILE}" down \
        --remove-orphans --volumes 2>/dev/null || true
    fi
  done

  # ── 3. Force-remove any leftover containers (by ID) ─────────────────
  #        Uses container IDs collected in detect_existing_install —
  #        includes containers found by name AND by image.
  if (( ${#FOUND_CONTAINERS[@]} > 0 )); then
    info "Force-removing telemt containers …"
    local cid cname
    for cid in "${FOUND_CONTAINERS[@]}"; do
      cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || echo "$cid")
      info "  removing container: ${cname} (${cid:0:12})"
      docker rm -f "$cid" 2>/dev/null || true
    done
  fi

  # ── 4. Remove telemt docker images (all tags) ───────────────────────
  if $FOUND_IMAGE; then
    local telemt_image_ids
    telemt_image_ids=$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
      --filter 'reference=whn0thacked/telemt-docker' 2>/dev/null || true)
    if [[ -n "$telemt_image_ids" ]]; then
      info "Removing telemt Docker images …"
      local img_line img_id img_tag
      while IFS= read -r img_line; do
        img_id="${img_line%% *}"
        img_tag="${img_line#* }"
        info "  removing image: ${img_tag} (${img_id:0:12})"
        docker rmi -f "$img_id" 2>/dev/null || true
      done <<< "$telemt_image_ids"
    fi
  fi

  # ── 5. Prune only dangling layers created in the last hour ──────────
  #        Avoids accidentally removing dangling images from other projects.
  docker image prune -f --filter "until=1h" 2>/dev/null || true

  # ── 6. Remove systemd unit files from disk ──────────────────────────
  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    info "Removing systemd unit files …"
    for u in "${FOUND_SYSTEMD[@]}"; do
      rm -f "/etc/systemd/system/$u"
      info "  deleted: /etc/systemd/system/$u"
    done
    systemctl daemon-reload 2>/dev/null || true
  fi

  # ── 7. Remove install directories ───────────────────────────────────
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

# ── fetch available versions from Docker Hub ─────────────────────────
# Returns list of semver tags (e.g., 3.3.27, 3.3.28, ...) sorted newest first
fetch_available_versions() {
  local api_url="${DOCKER_HUB_API}/?page_size=50&ordering=last_updated"
  local raw_json=""

  if command -v curl &>/dev/null; then
    raw_json=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api_url" 2>/dev/null || true)
  elif command -v wget &>/dev/null; then
    raw_json=$(wget -qO- --timeout=20 "$api_url" 2>/dev/null || true)
  fi

  if [[ -z "$raw_json" ]]; then
    return 1
  fi

  # Extract semver tags (X.Y.Z), exclude pre-releases, cache, commit hashes
  if command -v jq &>/dev/null; then
    echo "$raw_json" | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -t. -k1,1rn -k2,2rn -k3,3rn
  else
    # Fallback: parse JSON without jq using grep/sed
    echo "$raw_json" \
      | grep -oP '"name"\s*:\s*"\K[^"]+' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -t. -k1,1rn -k2,2rn -k3,3rn
  fi
}

# Display version selection menu and set SELECTED_VERSION
select_version() {
  header "Version selection"

  info "Fetching available versions from Docker Hub …"
  local versions
  versions=$(fetch_available_versions)

  if [[ -z "$versions" ]]; then
    warn "Could not fetch version list. Using 'latest'."
    SELECTED_VERSION="latest"
    return
  fi

  # Convert to array
  local -a ver_array=()
  while IFS= read -r v; do
    ver_array+=("$v")
  done <<< "$versions"

  local total=${#ver_array[@]}
  if (( total == 0 )); then
    warn "No versions found. Using 'latest'."
    SELECTED_VERSION="latest"
    return
  fi

  echo ""
  printf "  ${BOLD}%-4s  %-14s${NC}\n" "#" "Version"
  printf "  %-4s  %-14s\n" "---" "-----------"
  printf "  ${GREEN}${BOLD}%-4s  %-14s${NC}  (always newest)\n" "0" "latest"

  local i
  for (( i=0; i<total && i<15; i++ )); do
    if (( i == 0 )); then
      printf "  ${CYAN}%-4s  %-14s${NC}  (newest release)\n" "$((i+1))" "${ver_array[$i]}"
    else
      printf "  %-4s  %-14s\n" "$((i+1))" "${ver_array[$i]}"
    fi
  done

  if (( total > 15 )); then
    info "  … and $((total - 15)) more (showing top 15)"
  fi

  echo ""
  ask "Select version [0=latest]:"
  read -r ver_choice
  ver_choice=${ver_choice:-0}

  if [[ "$ver_choice" == "0" ]]; then
    SELECTED_VERSION="latest"
  elif [[ "$ver_choice" =~ ^[0-9]+$ ]] && (( ver_choice >= 1 && ver_choice <= total && ver_choice <= 15 )); then
    SELECTED_VERSION="${ver_array[$((ver_choice - 1))]}"
  else
    warn "Invalid choice. Using 'latest'."
    SELECTED_VERSION="latest"
  fi

  info "Selected version: ${SELECTED_VERSION}"
}

# ── update management: enable/disable/status ─────────────────────────
do_update_enable() {
  need_root
  if [[ ! -f "/etc/systemd/system/${UPDATER_TIMER}.timer" ]]; then
    err "Auto-update timer not found. Run install first."
    exit 1
  fi
  systemctl enable --now "${UPDATER_TIMER}.timer" 2>/dev/null
  info "Auto-update ENABLED."
  info "Next run: $(systemctl list-timers "${UPDATER_TIMER}.timer" --no-pager 2>/dev/null | tail -2 | head -1 || echo 'check systemctl list-timers')"
  exit 0
}

do_update_disable() {
  need_root
  if [[ ! -f "/etc/systemd/system/${UPDATER_TIMER}.timer" ]]; then
    err "Auto-update timer not found."
    exit 1
  fi
  systemctl stop "${UPDATER_TIMER}.timer" 2>/dev/null || true
  systemctl disable "${UPDATER_TIMER}.timer" 2>/dev/null || true
  info "Auto-update DISABLED."
  exit 0
}

do_update_status() {
  echo ""
  header "Update status"

  # Current image version
  local cur_img
  cur_img=$(docker inspect --format '{{.Config.Image}}' telemt 2>/dev/null || echo "unknown")
  info "Current image  : ${cur_img}"

  # Pinned version from file
  if [[ -f "${VERSION_FILE}" ]]; then
    info "Pinned version : $(cat "${VERSION_FILE}")"
  else
    info "Pinned version : not set (using compose default)"
  fi

  # Timer status
  if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
    printf "${GREEN}[INFO]${NC}  Auto-update   : ${GREEN}ENABLED${NC}\n"
    local next
    next=$(systemctl list-timers "${UPDATER_TIMER}.timer" --no-pager 2>/dev/null | grep "${UPDATER_TIMER}" || echo "")
    if [[ -n "$next" ]]; then
      info "Timer info     : ${next}"
    fi
  elif [[ -f "/etc/systemd/system/${UPDATER_TIMER}.timer" ]]; then
    printf "${YELLOW}[INFO]${NC}  Auto-update   : ${YELLOW}DISABLED${NC}\n"
  else
    info "Auto-update    : not installed"
  fi

  echo ""
  exit 0
}

# Set specific version in running installation
do_set_version() {
  need_root
  local target_ver="${2:-}"

  if [[ -z "$target_ver" ]]; then
    # Interactive mode: show available versions
    info "Fetching available versions …"
    local versions
    versions=$(fetch_available_versions)

    if [[ -z "$versions" ]]; then
      err "Could not fetch version list."
      exit 1
    fi

    local -a ver_array=()
    while IFS= read -r v; do
      ver_array+=("$v")
    done <<< "$versions"

    echo ""
    printf "  ${BOLD}%-4s  %-14s${NC}\n" "#" "Version"
    printf "  %-4s  %-14s\n" "---" "-----------"
    printf "  ${GREEN}${BOLD}%-4s  %-14s${NC}  (always newest)\n" "0" "latest"

    local i total=${#ver_array[@]}
    for (( i=0; i<total && i<15; i++ )); do
      printf "  %-4s  %-14s\n" "$((i+1))" "${ver_array[$i]}"
    done
    echo ""

    ask "Select version [0=latest]:"
    read -r ver_choice
    ver_choice=${ver_choice:-0}

    if [[ "$ver_choice" == "0" ]]; then
      target_ver="latest"
    elif [[ "$ver_choice" =~ ^[0-9]+$ ]] && (( ver_choice >= 1 && ver_choice <= total && ver_choice <= 15 )); then
      target_ver="${ver_array[$((ver_choice - 1))]}"
    else
      err "Invalid choice."
      exit 1
    fi
  fi

  info "Switching to version: ${target_ver}"

  # Update docker-compose.yml image tag
  if [[ ! -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    err "Compose file not found: ${INSTALL_DIR}/${COMPOSE_FILE}"
    exit 1
  fi

  sed -i "s|image: ${DOCKER_IMAGE}:.*|image: ${DOCKER_IMAGE}:${target_ver}|" \
    "${INSTALL_DIR}/${COMPOSE_FILE}"

  # Save pinned version
  echo "${target_ver}" > "${VERSION_FILE}"

  # Pull and restart
  cd "${INSTALL_DIR}" || exit 1
  info "Pulling image …"
  if ! docker compose pull; then
    err "Failed to pull ${DOCKER_IMAGE}:${target_ver}"
    exit 1
  fi

  info "Restarting container …"
  docker compose up -d --force-recreate

  # If pinned to specific version, warn about auto-update conflict
  if [[ "$target_ver" != "latest" ]]; then
    if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
      echo ""
      warn "Auto-update is currently ENABLED."
      warn "It may override your pinned version on next update cycle."
      ask "Disable auto-update? [Y/n]:"
      read -r disable_update
      disable_update=${disable_update:-Y}
      if [[ "${disable_update,,}" =~ ^y ]]; then
        systemctl stop "${UPDATER_TIMER}.timer" 2>/dev/null || true
        systemctl disable "${UPDATER_TIMER}.timer" 2>/dev/null || true
        info "Auto-update disabled."
      fi
    fi
  fi

  info "Done. Running version: ${target_ver}"
  exit 0
}

# ── CLI subcommands ───────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then do_uninstall; fi
if [[ "${1:-}" == "--update-enable" ]]; then do_update_enable; fi
if [[ "${1:-}" == "--update-disable" ]]; then do_update_disable; fi
if [[ "${1:-}" == "--update-status" ]]; then do_update_status; fi
if [[ "${1:-}" == "--set-version" ]]; then do_set_version "$@"; fi
if [[ "${1:-}" == "--list-versions" ]]; then
  info "Fetching available versions from Docker Hub …"
  versions=$(fetch_available_versions)
  if [[ -z "$versions" ]]; then
    err "Could not fetch version list."
    exit 1
  fi
  echo ""
  printf "  ${BOLD}Available versions:${NC}\n"
  echo "$versions" | head -20
  echo ""
  exit 0
fi

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
    if [[ -f "${dir}/${CONFIG_DIR}/${CONFIG_FILE}" ]]; then
      info "    config          : ${dir}/${CONFIG_DIR}/${CONFIG_FILE}"
    elif [[ -f "${dir}/${CONFIG_FILE}" ]]; then
      info "    config (legacy) : ${dir}/${CONFIG_FILE}"
    fi
    if [[ -f "${dir}/${COMPOSE_FILE}" ]]; then
      info "    compose         : ${dir}/${COMPOSE_FILE}"
    fi
  done

  if (( ${#FOUND_CONTAINERS[@]} > 0 )); then
    for cid in "${FOUND_CONTAINERS[@]}"; do
      cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || echo "$cid")
      cstate=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
      info "  Container         : ${cname} (${cstate})"
    done
  fi

  if $FOUND_IMAGE; then
    itag=$(docker images --format '{{.Repository}}:{{.Tag}}  ({{.Size}})' \
      --filter 'reference=whn0thacked/telemt-docker' 2>/dev/null | head -1 || echo "present")
    info "  Image             : ${itag}"
  fi

  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    for su in "${FOUND_SYSTEMD[@]}"; do
      sstate=$(systemctl is-active "$su" 2>/dev/null || echo "inactive")
      info "  Systemd unit      : ${su} (${sstate})"
    done
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
  # reject duplicate usernames
  if [[ -n "${SECRETS[$uname]+_}" ]]; then
    warn "User '${uname}' already added. Try a different name."
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
    if ss -tlnp 2>/dev/null | grep -qE "[[:space:]][^[:space:]]*:${PORT}[[:space:]]"; then
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
# §4  VERSION SELECTION
# ─────────────────────────────────────────────────────────────────────────
select_version

# ─────────────────────────────────────────────────────────────────────────
# §5  SYSTEMD & AUTO-UPDATE
# ─────────────────────────────────────────────────────────────────────────
header "Systemd & auto-update"

ask "Create systemd service for auto-start? [Y/n]:"
read -r CREATE_SERVICE
CREATE_SERVICE=${CREATE_SERVICE:-Y}

# If pinned to a specific version, default auto-update to No
if [[ "${SELECTED_VERSION}" != "latest" ]]; then
  warn "You selected a pinned version (${SELECTED_VERSION})."
  warn "Auto-update would override this — defaulting to disabled."
  ask "Enable automatic daily image update? [y/N]:"
  read -r AUTO_UPDATE
  AUTO_UPDATE=${AUTO_UPDATE:-N}
else
  ask "Enable automatic daily image update? [Y/n]:"
  read -r AUTO_UPDATE
  AUTO_UPDATE=${AUTO_UPDATE:-Y}
fi

# ══════════════════════════════════════════════════════════════════════════
# ██  DEPLOYMENT                                                          ██
# ══════════════════════════════════════════════════════════════════════════

header "Deploying"

# ── prepare install directory ───────────────────────────────────────────
info "Creating ${INSTALL_DIR} …"
mkdir -p "${INSTALL_DIR}"

# Create config subdirectory (mounted as volume for atomic config writes)
info "Creating ${INSTALL_DIR}/${CONFIG_DIR} …"
mkdir -p "${INSTALL_DIR}/${CONFIG_DIR}"

# ── download templates from repo config/ ───────────────────────────────
info "Downloading template: ${CONFIG_FILE} …"
download "${CONFIG_URL}/${CONFIG_FILE}" "${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"

info "Downloading template: ${COMPOSE_FILE} …"
download "${CONFIG_URL}/${COMPOSE_FILE}" "${INSTALL_DIR}/${COMPOSE_FILE}"

# Set permissions so the container's non-root user can modify the config
chmod 777 "${INSTALL_DIR}/${CONFIG_DIR}"
chmod 666 "${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"

# ── pin selected version in docker-compose.yml ───────────────────────
info "Pinning image version: ${DOCKER_IMAGE}:${SELECTED_VERSION}"
sed -i "s|image: ${DOCKER_IMAGE}:.*|image: ${DOCKER_IMAGE}:${SELECTED_VERSION}|" \
  "${INSTALL_DIR}/${COMPOSE_FILE}"

# Save version info for management commands
echo "${SELECTED_VERSION}" > "${VERSION_FILE}"

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

# full path to the config file inside the subdirectory
CONFIG_PATH="${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"

# apply values with sed
sed -i "s|^show_link = .*|show_link = ${show_link_val}|"              "${CONFIG_PATH}"
sed -i "s|^port = .*|port = ${PORT}|"                                 "${CONFIG_PATH}"
sed -i "s|^announce_ip = .*|announce_ip = \"${ANNOUNCE_IP}\"|"         "${CONFIG_PATH}"
sed -i "s|^tls_domain = .*|tls_domain = \"${TLS_DOMAIN}\"|"           "${CONFIG_PATH}"
sed -i "s|^mask_port = .*|mask_port = ${MASK_PORT}|"                   "${CONFIG_PATH}"

# insert user lines after [access.users] using 'r' (read file) command
sed -i "/^\[access\.users\]$/r ${users_tmp}" "${CONFIG_PATH}"
rm -f "$users_tmp"
trap - EXIT

# ── privileged port handling ───────────────────────────────────────────
# The upstream image runs as non-root by default. Ports below 1024
# require root inside the container, so we must enable user: "root"
# and disable no-new-privileges in docker-compose.yml.
if (( PORT < 1024 )); then
  info "Port ${PORT} is privileged (<1024) — enabling root user in compose."
  # Uncomment user: "root"
  sed -i 's|^    # user: "root"|    user: "root"|' "${INSTALL_DIR}/${COMPOSE_FILE}"
  # Comment out security_opt and no-new-privileges
  sed -i 's|^    security_opt:$|    # security_opt:|'                          "${INSTALL_DIR}/${COMPOSE_FILE}"
  sed -i 's|^      - no-new-privileges:true$|    #   - no-new-privileges:true|' "${INSTALL_DIR}/${COMPOSE_FILE}"
fi

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
  if ss -tlnp 2>/dev/null | grep -qE "[[:space:]][^[:space:]]*:${PORT}[[:space:]]"; then
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
info "Config dir   : ${INSTALL_DIR}/${CONFIG_DIR}"
info "Config       : ${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"
info "Compose      : ${INSTALL_DIR}/${COMPOSE_FILE}"
info "Image version: ${DOCKER_IMAGE}:${SELECTED_VERSION}"
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
info "Config      : nano ${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"
info "Restart     : docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} up -d --force-recreate"
info "Uninstall   : bash install-mtproto.sh --uninstall"
echo ""
header "Version management"
info "List versions   : bash install-mtproto.sh --list-versions"
info "Switch version  : bash install-mtproto.sh --set-version [VERSION]"
info "Update status   : bash install-mtproto.sh --update-status"
info "Enable updates  : bash install-mtproto.sh --update-enable"
info "Disable updates : bash install-mtproto.sh --update-disable"

# ── nftables reminder ──────────────────────────────────────────────────
echo ""
printf "${YELLOW}${BOLD}⚠  FIREWALL REMINDER:${NC}\n"
printf "${YELLOW}   Make sure your nftables config allows traffic on port ${PORT}.${NC}\n"
printf "${YELLOW}   Check: define TELEMT_PORT = ${PORT}${NC}\n"
printf "${YELLOW}   Apply: nft -f /etc/nftables.conf${NC}\n"
echo ""
