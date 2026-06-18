#!/usr/bin/env bash
#
# MTProto Proxy (telemt) — main configuration & deploy script
# Called by install.sh (bootstrap) or can be run standalone.
#
# Container is BUILT LOCALLY from telemt.dockerfile: the static binary is
# copied out of the official ghcr.io/telemt/telemt image — no third-party
# prebuilt image, no manual GitHub Releases parsing.
#
# Usage:
#   bash install-mtproto.sh               # interactive install
#   bash install-mtproto.sh --uninstall   # remove everything
#   bash install-mtproto.sh --rebuild     # rebuild image & recreate container
#   bash install-mtproto.sh --start|--stop|--restart   # lifecycle
#   bash install-mtproto.sh --status      # container + service status
#   bash install-mtproto.sh --logs        # follow container logs
#   bash install-mtproto.sh --list-versions     # show available GHCR versions
#   bash install-mtproto.sh --set-version [V]   # switch version (interactive if V omitted)
#   bash install-mtproto.sh --auto-update       # used by the update timer
#   bash install-mtproto.sh --update-status     # current version & update state
#   bash install-mtproto.sh --update-enable     # enable auto-update timer
#   bash install-mtproto.sh --update-disable    # disable auto-update timer
#
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/telemt"
CONFIG_DIR="telemt-config"       # subdirectory for telemt.toml + data (mounted volume)
SERVICE_NAME="telemt-compose"
COMPOSE_FILE="docker-compose.yml"
DOCKERFILE="telemt.dockerfile"
ENV_FILE=".env"
CONFIG_FILE="telemt.toml"
SERVICE_FILE="${SERVICE_NAME}.service"
UPDATER_TIMER="${SERVICE_NAME}-update"
INSTALL_MARKER=".telemt-installer"
# telemt runs as non-root (uid 65532) inside the built image.
NONROOT_UID="65532"
NONROOT_GID="65532"
if SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"; then
  :
else
  SCRIPT_DIR="$(pwd -P)"
fi

REPO_RAW="https://raw.githubusercontent.com/civisrom/mt-docker/main"
CONFIG_URL="${REPO_RAW}/config"

# Source image (official) and locally-built image tag.
GHCR_IMAGE="ghcr.io/telemt/telemt"
LOCAL_IMAGE="civisrom/mt-telemt"
DEFAULT_VERSION="3.4.18"
ENV_PATH="${INSTALL_DIR}/${ENV_FILE}"

# Dedicated buildx builder: keeps this project's build cache ISOLATED so that
# --uninstall can drop it with `docker buildx rm` without touching the default
# builder / other projects' caches (other containers on the host stay intact).
BUILDER_NAME="mt-docker"

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

download_config_template() {
  local name="$1" dest="$2"
  local local_template="${SCRIPT_DIR}/config/${name}"

  if [[ -f "$local_template" ]]; then
    cp "$local_template" "$dest"
  else
    download "${CONFIG_URL}/${name}" "$dest"
  fi

  if [[ ! -s "$dest" ]]; then
    err "Failed to prepare template: ${name}"
    exit 1
  fi
}

install_self_copy() {
  local dest="${INSTALL_DIR}/install-mtproto.sh"
  local src="${BASH_SOURCE[0]}"

  if [[ -f "$src" ]]; then
    cp "$src" "$dest"
    chmod 755 "$dest"
  else
    download "${REPO_RAW}/install-mtproto.sh" "$dest"
    chmod 755 "$dest"
  fi
}

check_deps() {
  local missing=()
  for cmd in docker openssl sed xxd curl; do
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
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" == *.* ]] || return 1
  [[ "$d" != *..* ]] || return 1

  local IFS='.'
  local -a labels
  read -ra labels <<< "$d"
  local label
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
  return 0
}

# Concrete semver tag only (no "latest" — build arg must be a real tag).
is_valid_version_tag() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Sanitize input: reject shell metacharacters for sed usage
sanitize_input() {
  local val="$1"
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
    if command -v curl &>/dev/null; then
      ip=$(curl -fsSL --connect-timeout 5 --max-time 10 "$svc" 2>/dev/null || true)
    elif command -v wget &>/dev/null; then
      ip=$(wget -qO- --timeout=10 "$svc" 2>/dev/null || true)
    else
      return 1
    fi
    ip="${ip%%[[:space:]]*}"
    if is_valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# ── .env helpers ───────────────────────────────────────────────────────
set_env_kv() {
  local key="$1" val="$2" file="$3"
  [[ -f "$file" ]] || : > "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

get_env_kv() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  grep -m1 -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

get_current_version() {
  get_env_kv "TELEMT_VERSION" "$ENV_PATH" || true
}

get_update_channel() {
  local ch
  ch=$(get_env_kv "UPDATE_CHANNEL" "$ENV_PATH" || true)
  echo "${ch:-latest}"
}

compose_file_is_telemt() {
  local compose_path="$1"
  [[ -f "$compose_path" ]] || return 1
  grep -Eq "org\.civisrom\.mt-docker|${LOCAL_IMAGE}:|${DOCKERFILE}" "$compose_path"
}

safe_realpath() {
  local path="$1"
  if command -v realpath &>/dev/null; then
    realpath -m "$path" 2>/dev/null
  else
    (cd "$(dirname "$path")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
  fi
}

is_safe_install_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 1

  local dir_real install_real
  dir_real=$(safe_realpath "$dir")
  install_real=$(safe_realpath "$INSTALL_DIR")

  [[ -n "$dir_real" && "$dir_real" != "/" ]] || return 1
  [[ "$dir_real" == "$install_real" ]] || return 1

  [[ -f "${dir}/${INSTALL_MARKER}" ]] && return 0
  compose_file_is_telemt "${dir}/${COMPOSE_FILE}" && return 0
  return 1
}

# ── fetch available versions from GHCR ───────────────────────────────────
# Lists semver tags of the official ghcr.io/telemt/telemt image using an
# anonymous pull token (public image). Sorted newest first.
fetch_available_versions() {
  local token tags_json
  token=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    "https://ghcr.io/token?scope=repository:telemt/telemt:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)
  [[ -z "$token" ]] && return 1

  tags_json=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/telemt/telemt/tags/list" 2>/dev/null || true)
  [[ -z "$tags_json" ]] && return 1

  echo "$tags_json" \
    | tr ',' '\n' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u -t. -k1,1rn -k2,2rn -k3,3rn \
    || true
}

# Newest concrete semver tag, or empty
latest_version() {
  fetch_available_versions 2>/dev/null | head -1
}

# Display version selection menu and set SELECTED_VERSION (+ SELECTED_CHANNEL)
select_version() {
  header "Version selection"

  info "Fetching available versions from GHCR (ghcr.io/telemt/telemt) …"
  local versions=""
  versions=$(fetch_available_versions) || true

  if [[ -z "$versions" ]]; then
    warn "Could not fetch version list. Using default ${DEFAULT_VERSION} (channel: latest)."
    SELECTED_VERSION="${DEFAULT_VERSION}"
    SELECTED_CHANNEL="latest"
    return
  fi

  local -a ver_array=()
  while IFS= read -r v; do ver_array+=("$v"); done <<< "$versions"
  local total=${#ver_array[@]}
  local newest="${ver_array[0]}"

  echo ""
  printf "  ${BOLD}%-4s  %-14s${NC}\n" "#" "Version"
  printf "  %-4s  %-14s\n" "---" "-----------"
  printf "  ${GREEN}${BOLD}%-4s  %-14s${NC}  (track newest, auto-update)\n" "0" "latest"

  local i
  for (( i=0; i<total && i<15; i++ )); do
    if (( i == 0 )); then
      printf "  ${CYAN}%-4s  %-14s${NC}  (newest release)\n" "$((i+1))" "${ver_array[$i]}"
    else
      printf "  %-4s  %-14s\n" "$((i+1))" "${ver_array[$i]}"
    fi
  done
  (( total > 15 )) && info "  … and $((total - 15)) more (showing top 15)"

  echo ""
  ask "Select version [0=latest]:"
  read -r ver_choice
  ver_choice=${ver_choice:-0}

  if [[ "$ver_choice" == "0" ]]; then
    SELECTED_VERSION="${newest}"   # concrete tag, but channel=latest tracks newest
    SELECTED_CHANNEL="latest"
  elif [[ "$ver_choice" =~ ^[0-9]+$ ]] && (( ver_choice >= 1 && ver_choice <= total && ver_choice <= 15 )); then
    SELECTED_VERSION="${ver_array[$((ver_choice - 1))]}"
    SELECTED_CHANNEL="pinned"
  else
    warn "Invalid choice. Using 'latest'."
    SELECTED_VERSION="${newest}"
    SELECTED_CHANNEL="latest"
  fi

  info "Selected version: ${SELECTED_VERSION} (channel: ${SELECTED_CHANNEL})"
}

# ── build / lifecycle helpers ────────────────────────────────────────────
compose() {
  docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" --env-file "${ENV_PATH}" "$@"
}

# Ensure the dedicated buildx builder exists (isolated build cache).
# Returns 0 if it can be used, 1 to fall back to the default builder.
ensure_builder() {
  command -v docker &>/dev/null || return 1
  docker buildx version &>/dev/null || return 1
  if docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    return 0
  fi
  if docker buildx create --name "${BUILDER_NAME}" --driver docker-container &>/dev/null; then
    return 0
  fi
  return 1
}

# Build via the dedicated builder when possible; fall back to the default
# builder if the dedicated one is unavailable, fails, or does not load the
# image into the local store (some Compose versions don't --load from a
# docker-container builder). $@ = extra build flags (e.g. --pull).
compose_build() {
  local ver img
  ver=$(get_current_version 2>/dev/null || true)
  img="${LOCAL_IMAGE}:${ver}"

  if ensure_builder; then
    if BUILDX_BUILDER="${BUILDER_NAME}" compose build "$@"; then
      # Confirm the image actually landed in the local image store; if not,
      # the default builder (which always loads) is used below.
      if [[ -z "$ver" ]] || docker image inspect "$img" &>/dev/null; then
        return 0
      fi
      warn "Image ${img} not in local store (builder didn't --load); retrying with default builder."
    else
      warn "Build with dedicated builder '${BUILDER_NAME}' failed; retrying with default builder."
    fi
  fi
  compose build "$@"
}

# Rebuild image and recreate the container. $1: extra build flag (e.g. --pull)
rebuild_stack() {
  local pull_flag="${1:-}"
  cd "${INSTALL_DIR}" || { err "Cannot cd to ${INSTALL_DIR}"; return 1; }
  info "Building image (${LOCAL_IMAGE}:$(get_current_version)) …"
  # shellcheck disable=SC2086
  compose_build ${pull_flag} || return 1
  info "Recreating container …"
  compose up -d --force-recreate --remove-orphans || return 1
  return 0
}

# Remove the dedicated builder and ITS build cache only (safe: does not touch
# the default builder or other projects' caches).
remove_builder() {
  command -v docker &>/dev/null || return 0
  docker buildx version &>/dev/null || return 0
  if docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    info "Removing dedicated buildx builder '${BUILDER_NAME}' (isolated build cache) …"
    docker buildx rm -f "${BUILDER_NAME}" 2>/dev/null || true
  fi
}

prune_old_local_images() {
  local keep="$1"
  local img
  # Guard: without a concrete version to keep, do nothing (avoid wiping the
  # image that is currently in use).
  [[ -z "$keep" ]] && return 0
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^${LOCAL_IMAGE}:" | grep -vF "${LOCAL_IMAGE}:${keep}" | while IFS= read -r img; do
      docker rmi "$img" 2>/dev/null || true
    done
}

# Switch version: writes .env, rebuilds, recreates; rolls back on failure.
switch_running_version() {
  local target_ver="$1" target_channel="$2"

  if ! is_valid_version_tag "$target_ver"; then
    err "Invalid version tag: ${target_ver}. Use X.Y.Z."
    return 1
  fi
  if [[ ! -f "$ENV_PATH" ]]; then
    err ".env not found: ${ENV_PATH}. Run install first."
    return 1
  fi

  local old_ver old_channel
  old_ver=$(get_current_version); old_ver=${old_ver:-unknown}
  old_channel=$(get_update_channel)

  local backup; backup=$(mktemp); cp "$ENV_PATH" "$backup"

  set_env_kv "TELEMT_VERSION" "$target_ver" "$ENV_PATH"
  set_env_kv "UPDATE_CHANNEL" "$target_channel" "$ENV_PATH"

  if ! rebuild_stack "--pull"; then
    mv "$backup" "$ENV_PATH"
    err "Rebuild failed; .env restored to ${old_ver} (${old_channel})."
    rebuild_stack || true
    return 1
  fi

  rm -f "$backup"
  prune_old_local_images "$target_ver"
  return 0
}

# ── detect existing installation ──────────────────────────────────────
detect_existing_install() {
  FOUND_DIRS=()
  FOUND_CONTAINERS=()
  FOUND_SYSTEMD=()
  FOUND_IMAGE=false

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

  _add_dir "${INSTALL_DIR}"

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

  local u
  for u in "${SERVICE_FILE}" "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service"; do
    [[ -f "/etc/systemd/system/$u" ]] && FOUND_SYSTEMD+=("$u")
  done

  local cid
  cid=$(docker ps -a --filter 'name=^telemt$' --format '{{.ID}}' 2>/dev/null || true)
  [[ -n "$cid" ]] && _add_container "$cid"

  local labeled_cids
  labeled_cids=$(docker ps -a --filter 'label=org.civisrom.mt-docker=telemt' --format '{{.ID}}' 2>/dev/null || true)
  if [[ -n "$labeled_cids" ]]; then
    while IFS= read -r cid; do _add_container "$cid"; done <<< "$labeled_cids"
  fi

  if docker images --format '{{.Repository}}' 2>/dev/null | grep -qx "${LOCAL_IMAGE}"; then
    FOUND_IMAGE=true
  fi

  if (( ${#FOUND_DIRS[@]} > 0 )) || \
     (( ${#FOUND_CONTAINERS[@]} > 0 )) || \
     (( ${#FOUND_SYSTEMD[@]} > 0 )) || \
     $FOUND_IMAGE; then
    return 0
  fi
  return 1
}

# ── cleanup existing installation (targeted — telemt only) ────────────
cleanup_existing_install() {
  echo ""
  info "── Removing existing telemt MTProto installation ──"

  # 1. Stop systemd units first (prevents restart races)
  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    info "Stopping systemd units …"
    local u
    for u in "${FOUND_SYSTEMD[@]}"; do
      info "  stopping: $u"
      systemctl stop "$u" 2>/dev/null || true
      systemctl disable "$u" 2>/dev/null || true
    done
  fi

  # 2. docker compose down (graceful)
  local dir
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    if ! is_safe_install_dir "$dir"; then
      warn "Skipping untrusted install directory during compose cleanup: ${dir}"
      continue
    fi
    if compose_file_is_telemt "${dir}/${COMPOSE_FILE}"; then
      info "Running compose down (${dir}/${COMPOSE_FILE}) …"
      local envf=""
      [[ -f "${dir}/${ENV_FILE}" ]] && envf="--env-file ${dir}/${ENV_FILE}"
      # shellcheck disable=SC2086
      docker compose -f "${dir}/${COMPOSE_FILE}" $envf down \
        --remove-orphans --volumes --rmi local 2>/dev/null || true
    fi
  done

  # 3. Force-remove any leftover containers (by ID)
  if (( ${#FOUND_CONTAINERS[@]} > 0 )); then
    info "Force-removing telemt containers …"
    local cid cname
    for cid in "${FOUND_CONTAINERS[@]}"; do
      cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || echo "$cid")
      info "  removing container: ${cname} (${cid:0:12})"
      docker rm -f "$cid" 2>/dev/null || true
    done
  fi

  # 4. Remove all locally-built telemt images (by repository — scoped to ours)
  if $FOUND_IMAGE; then
    info "Removing locally-built images: ${LOCAL_IMAGE} …"
    local img
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | grep -E "^${LOCAL_IMAGE}:" | while IFS= read -r img; do
        docker rmi -f "$img" 2>/dev/null || true
      done
  fi

  # 4b. Drop the dedicated buildx builder — removes THIS project's build cache
  #     only. The default builder and other projects' caches are untouched.
  #     This is the safe alternative to a global `docker builder prune`.
  #     (If the build had to fall back to the default builder, its cache is
  #     shared and intentionally NOT pruned — safety over completeness.)
  remove_builder

  # 6. Remove systemd unit files from disk
  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    info "Removing systemd unit files …"
    for u in "${FOUND_SYSTEMD[@]}"; do
      rm -f "/etc/systemd/system/$u"
      info "  deleted: /etc/systemd/system/$u"
    done
    systemctl daemon-reload 2>/dev/null || true
  fi

  # 7. Remove install directories
  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    if [[ -d "$dir" ]]; then
      if ! is_safe_install_dir "$dir"; then
        warn "Skipping untrusted install directory removal: ${dir}"
        continue
      fi
      info "Removing directory: ${dir} …"
      rm -rf -- "$dir"
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

# ── auto-update unit files ───────────────────────────────────────────────
write_auto_update_units() {
  if [[ ! -d "${INSTALL_DIR}" ]]; then
    err "Install directory not found: ${INSTALL_DIR}. Run install first."
    return 1
  fi
  if [[ ! -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    err "Compose file not found: ${INSTALL_DIR}/${COMPOSE_FILE}. Run install first."
    return 1
  fi
  download_config_template "${UPDATER_TIMER}.service" "/etc/systemd/system/${UPDATER_TIMER}.service"
  download_config_template "${UPDATER_TIMER}.timer" "/etc/systemd/system/${UPDATER_TIMER}.timer"
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${INSTALL_DIR}|" \
    "/etc/systemd/system/${UPDATER_TIMER}.service"
  sed -i "s|^ExecStart=.*|ExecStart=${INSTALL_DIR}/install-mtproto.sh --auto-update|" \
    "/etc/systemd/system/${UPDATER_TIMER}.service"
}

enable_auto_update_timer() {
  write_auto_update_units || return 1
  systemctl daemon-reload
  systemctl enable --now "${UPDATER_TIMER}.timer"
}

disable_auto_update_timer() {
  systemctl stop "${UPDATER_TIMER}.timer" 2>/dev/null || true
  systemctl disable "${UPDATER_TIMER}.timer" 2>/dev/null || true
  systemctl reset-failed "${UPDATER_TIMER}.timer" "${UPDATER_TIMER}.service" 2>/dev/null || true
}

# ── --auto-update (called by the update timer) ───────────────────────────
do_auto_update() {
  need_root
  check_deps
  if [[ ! -f "$ENV_PATH" ]]; then
    err ".env not found: ${ENV_PATH}. Nothing to update."
    exit 1
  fi

  local channel cur
  channel=$(get_update_channel)
  cur=$(get_current_version); cur=${cur:-unknown}

  if [[ "$channel" != "latest" ]]; then
    info "UPDATE_CHANNEL=${channel}; version pinned to ${cur}. Nothing to do."
    exit 0
  fi

  info "Auto-update: resolving newest version from GHCR …"
  local newest
  newest=$(latest_version)
  if [[ -z "$newest" ]]; then
    warn "Could not resolve newest version; leaving ${cur} running."
    exit 0
  fi

  if [[ "$newest" == "$cur" ]]; then
    info "Already on newest version (${cur}). Nothing to do."
    exit 0
  fi

  info "New version available: ${cur} → ${newest}. Rebuilding …"
  if switch_running_version "$newest" "latest"; then
    info "Updated to ${newest}."
  else
    err "Auto-update to ${newest} failed."
    exit 1
  fi
  exit 0
}

# ── update management: enable/disable/status ─────────────────────────
do_update_enable() {
  need_root
  local channel
  channel=$(get_update_channel)
  if [[ "$channel" != "latest" ]]; then
    local pinned; pinned=$(get_current_version)
    warn "Version is pinned to '${pinned}' (channel: ${channel})."
    warn "Auto-update only acts on channel 'latest'."
    ask "Switch to 'latest' (track newest) and rebuild? [Y/n]:"
    read -r switch_latest
    switch_latest=${switch_latest:-Y}
    if [[ "${switch_latest,,}" =~ ^y ]]; then
      local newest; newest=$(latest_version)
      newest=${newest:-$pinned}
      switch_running_version "$newest" "latest" || exit 1
      info "Switched to 'latest' (${newest})."
    fi
  fi
  enable_auto_update_timer || exit 1
  info "Auto-update ENABLED."
  info "Next run: $(systemctl list-timers "${UPDATER_TIMER}.timer" --no-pager 2>/dev/null | tail -2 | head -1 || echo 'check systemctl list-timers')"
  exit 0
}

do_update_disable() {
  need_root
  if [[ ! -f "/etc/systemd/system/${UPDATER_TIMER}.timer" && \
        ! -f "/etc/systemd/system/${UPDATER_TIMER}.service" ]]; then
    info "Auto-update is already DISABLED (timer not installed)."
    exit 0
  fi
  disable_auto_update_timer
  info "Auto-update DISABLED."
  exit 0
}

do_update_status() {
  echo ""
  header "Update status"
  local cur_img
  cur_img=$(docker inspect --format '{{.Config.Image}}' telemt 2>/dev/null || echo "unknown")
  info "Running image  : ${cur_img}"
  info "Source image   : ${GHCR_IMAGE}:$(get_current_version 2>/dev/null || echo '?')"
  info "Pinned version : $(get_current_version 2>/dev/null || echo 'not set')"
  info "Update channel : $(get_update_channel)"

  if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
    printf '%b[INFO]%b  Auto-update   : %bENABLED%b\n' "$GREEN" "$NC" "$GREEN" "$NC"
    local next
    next=$(systemctl list-timers "${UPDATER_TIMER}.timer" --no-pager 2>/dev/null | grep "${UPDATER_TIMER}" || echo "")
    [[ -n "$next" ]] && info "Timer info     : ${next}"
  elif [[ -f "/etc/systemd/system/${UPDATER_TIMER}.timer" ]]; then
    printf '%b[INFO]%b  Auto-update   : %bDISABLED%b\n' "$YELLOW" "$NC" "$YELLOW" "$NC"
  else
    info "Auto-update    : not installed"
  fi
  echo ""
  exit 0
}

# ── lifecycle subcommands (start/stop/restart/status/logs management) ─────
require_install() {
  if [[ ! -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    err "No installation found at ${INSTALL_DIR}. Run the installer first."
    exit 1
  fi
}

do_rebuild() {
  need_root; check_deps; require_install
  header "Rebuild & recreate"
  rebuild_stack "--pull" || { err "Rebuild failed."; exit 1; }
  prune_old_local_images "$(get_current_version)"
  info "Rebuilt and recreated (version $(get_current_version))."
  exit 0
}

do_start()   { need_root; require_install; compose_build || { err "Build failed."; exit 1; }; compose up -d; info "Started."; exit 0; }
do_stop()    { need_root; require_install; compose down; info "Stopped."; exit 0; }
do_ensure_builder() {
  need_root
  if ensure_builder; then
    info "Builder '${BUILDER_NAME}' ready."
  else
    warn "Dedicated builder unavailable; default builder will be used."
  fi
  exit 0
}
do_restart() { need_root; require_install; compose up -d --force-recreate; info "Restarted."; exit 0; }
do_logs()    { require_install; docker logs telemt --tail=100 -f || true; exit 0; }

do_status() {
  require_install
  header "telemt status"
  docker ps -a --filter 'name=^telemt$' \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
  echo ""
  info "Version       : $(get_current_version 2>/dev/null || echo '?')"
  info "Update channel: $(get_update_channel)"
  if systemctl is-enabled "${SERVICE_FILE}" &>/dev/null; then
    info "Service       : ${SERVICE_NAME} ($(systemctl is-active "${SERVICE_FILE}" 2>/dev/null || echo inactive))"
  fi
  echo ""
  exit 0
}

# Set specific version in running installation
do_set_version() {
  need_root
  require_install
  local target_ver="${2:-}"
  local target_channel="pinned"

  if [[ -z "$target_ver" ]]; then
    info "Fetching available versions from GHCR …"
    local versions=""
    versions=$(fetch_available_versions) || true
    if [[ -z "$versions" ]]; then
      err "Could not fetch version list."
      exit 1
    fi
    local -a ver_array=()
    while IFS= read -r v; do ver_array+=("$v"); done <<< "$versions"
    local newest="${ver_array[0]}"

    echo ""
    printf "  ${BOLD}%-4s  %-14s${NC}\n" "#" "Version"
    printf "  %-4s  %-14s\n" "---" "-----------"
    printf "  ${GREEN}${BOLD}%-4s  %-14s${NC}  (track newest)\n" "0" "latest"
    local i total=${#ver_array[@]}
    for (( i=0; i<total && i<15; i++ )); do
      printf "  %-4s  %-14s\n" "$((i+1))" "${ver_array[$i]}"
    done
    echo ""
    ask "Select version [0=latest]:"
    read -r ver_choice
    ver_choice=${ver_choice:-0}

    if [[ "$ver_choice" == "0" ]]; then
      target_ver="${newest}"; target_channel="latest"
    elif [[ "$ver_choice" =~ ^[0-9]+$ ]] && (( ver_choice >= 1 && ver_choice <= total && ver_choice <= 15 )); then
      target_ver="${ver_array[$((ver_choice - 1))]}"; target_channel="pinned"
    else
      err "Invalid choice."
      exit 1
    fi
  else
    if [[ "$target_ver" == "latest" ]]; then
      target_ver=$(latest_version)
      [[ -z "$target_ver" ]] && { err "Could not resolve 'latest'."; exit 1; }
      target_channel="latest"
    fi
  fi

  info "Switching to version: ${target_ver} (channel: ${target_channel})"
  switch_running_version "$target_ver" "$target_channel" || exit 1

  if [[ "$target_channel" == "pinned" ]]; then
    if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
      echo ""
      warn "Auto-update is ENABLED but the version is now pinned (${target_ver})."
      warn "The timer will not change a pinned version."
      ask "Disable auto-update? [Y/n]:"
      read -r disable_update
      disable_update=${disable_update:-Y}
      if [[ "${disable_update,,}" =~ ^y ]]; then
        disable_auto_update_timer
        info "Auto-update disabled."
      fi
    fi
  fi
  info "Done. Running version: ${target_ver}"
  exit 0
}

# ── CLI subcommands ───────────────────────────────────────────────────
case "${1:-}" in
  --uninstall)        do_uninstall ;;
  --rebuild)          do_rebuild ;;
  --start)            do_start ;;
  --stop)             do_stop ;;
  --restart)          do_restart ;;
  --ensure-builder)   do_ensure_builder ;;
  --status)           do_status ;;
  --logs)             do_logs ;;
  --auto-update)      do_auto_update ;;
  --update-enable)    do_update_enable ;;
  --update-disable)   do_update_disable ;;
  --update-status)    do_update_status ;;
  --set-version)      do_set_version "$@" ;;
  --list-versions)
    info "Fetching available versions from GHCR (ghcr.io/telemt/telemt) …"
    versions=$(fetch_available_versions) || true
    if [[ -z "$versions" ]]; then
      err "Could not fetch version list."
      exit 1
    fi
    echo ""
    printf '  %bAvailable versions:%b\n' "$BOLD" "$NC"
    echo "$versions" | head -20
    echo ""
    exit 0
    ;;
esac

# ══════════════════════════════════════════════════════════════════════════
# ██  INTERACTIVE CONFIGURATION                                          ██
# ══════════════════════════════════════════════════════════════════════════
need_root
check_deps

echo ""
info "=== MTProto Proxy (telemt) — Host Mode Installer (build-based) ==="
echo ""

# ── detect & offer to manage previous installation ────────────────────
if detect_existing_install; then
  header "Existing telemt installation detected"

  for dir in "${FOUND_DIRS[@]+"${FOUND_DIRS[@]}"}"; do
    info "  Install directory : ${dir}"
    if [[ -f "${dir}/${CONFIG_DIR}/${CONFIG_FILE}" ]]; then
      info "    config          : ${dir}/${CONFIG_DIR}/${CONFIG_FILE}"
    fi
    [[ -f "${dir}/${COMPOSE_FILE}" ]] && info "    compose         : ${dir}/${COMPOSE_FILE}"
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
      --filter "reference=${LOCAL_IMAGE}" 2>/dev/null | head -1 || echo "present")
    info "  Image             : ${itag}"
  fi

  if (( ${#FOUND_SYSTEMD[@]} > 0 )); then
    for su in "${FOUND_SYSTEMD[@]}"; do
      sstate=$(systemctl is-active "$su" 2>/dev/null || echo "inactive")
      info "  Systemd unit      : ${su} (${sstate})"
    done
  fi

  echo ""
  cur_ver=$(get_current_version 2>/dev/null || echo "unknown")
  cur_ver=${cur_ver:-unknown}
  info "  Current version   : ${LOCAL_IMAGE}:${cur_ver} (channel: $(get_update_channel))"

  update_state="not installed"
  if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
    update_state="${GREEN}ENABLED${NC}"
  elif [[ -f "/etc/systemd/system/${UPDATER_TIMER}.timer" ]]; then
    update_state="${YELLOW}DISABLED${NC}"
  fi
  printf '  %b[INFO]%b  Auto-update      : %b\n' "$GREEN" "$NC" "$update_state"

  echo ""
  printf '%bChoose an option:%b\n' "$BOLD" "$NC"
  echo "  1) Change version (show available & rebuild)"
  echo "  2) Toggle auto-update (enable / disable)"
  echo "  3) Rebuild current version (refresh base image)"
  echo "  4) Reinstall (remove and install fresh)"
  echo "  5) Uninstall completely (remove container, image, build cache, files)"
  echo "  6) Exit"
  echo ""
  ask "Your choice [1-6]:"
  read -r mgmt_choice

  case "${mgmt_choice}" in
    1)
      header "Change version"
      info "Current version: ${cur_ver}"
      info "Fetching available versions from GHCR …"
      mgmt_versions=$(fetch_available_versions) || true
      if [[ -z "$mgmt_versions" ]]; then
        err "Could not fetch version list."
        exit 1
      fi
      mgmt_ver_array=()
      while IFS= read -r v; do mgmt_ver_array+=("$v"); done <<< "$mgmt_versions"
      mgmt_total=${#mgmt_ver_array[@]}
      mgmt_newest="${mgmt_ver_array[0]}"
      echo ""
      printf "  ${BOLD}%-4s  %-14s${NC}\n" "#" "Version"
      printf "  %-4s  %-14s\n" "---" "-----------"
      printf "  ${GREEN}${BOLD}%-4s  %-14s${NC}  (track newest)\n" "0" "latest"
      for (( mgmt_i=0; mgmt_i<mgmt_total && mgmt_i<15; mgmt_i++ )); do
        marker=""
        [[ "${mgmt_ver_array[$mgmt_i]}" == "$cur_ver" ]] && marker="  <-- current"
        printf "  %-4s  %-14s%s\n" "$((mgmt_i+1))" "${mgmt_ver_array[$mgmt_i]}" "$marker"
      done
      (( mgmt_total > 15 )) && info "  … and $((mgmt_total - 15)) more (showing top 15)"
      echo ""
      ask "Select version [0=latest]:"
      read -r ver_choice
      ver_choice=${ver_choice:-0}

      if [[ "$ver_choice" == "0" ]]; then
        target_ver="${mgmt_newest}"; target_channel="latest"
      elif [[ "$ver_choice" =~ ^[0-9]+$ ]] && (( ver_choice >= 1 && ver_choice <= mgmt_total && ver_choice <= 15 )); then
        target_ver="${mgmt_ver_array[$((ver_choice - 1))]}"; target_channel="pinned"
      else
        err "Invalid choice."; exit 1
      fi

      info "Switching: ${cur_ver} → ${target_ver} (channel: ${target_channel})"
      switch_running_version "$target_ver" "$target_channel" || exit 1

      if [[ "$target_channel" == "pinned" ]] && systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
        echo ""
        warn "Auto-update is ENABLED but version is now pinned to ${target_ver}."
        ask "Disable auto-update? [Y/n]:"
        read -r disable_upd
        disable_upd=${disable_upd:-Y}
        if [[ "${disable_upd,,}" =~ ^y ]]; then
          disable_auto_update_timer
          info "Auto-update disabled."
        fi
      fi
      echo ""
      info "Done. Running version: ${target_ver}"
      exit 0
      ;;
    2)
      header "Auto-update management"
      if systemctl is-active "${UPDATER_TIMER}.timer" &>/dev/null; then
        printf '  Auto-update is currently: %b%bENABLED%b\n' "$GREEN" "$BOLD" "$NC"
        echo ""
        ask "Disable auto-update? [Y/n]:"
        read -r toggle_choice
        toggle_choice=${toggle_choice:-Y}
        if [[ "${toggle_choice,,}" =~ ^y ]]; then
          disable_auto_update_timer
          info "Auto-update DISABLED."
        else
          info "No changes."
        fi
      else
        printf '  Auto-update is currently: %b%bDISABLED%b\n' "$YELLOW" "$BOLD" "$NC"
        echo ""
        if [[ "$(get_update_channel)" != "latest" ]]; then
          warn "Version is pinned (${cur_ver}); auto-update only acts on channel 'latest'."
          ask "Switch to 'latest' (track newest) and enable auto-update? [Y/n]:"
          read -r switch_and_enable
          switch_and_enable=${switch_and_enable:-Y}
          if [[ "${switch_and_enable,,}" =~ ^y ]]; then
            newest=$(latest_version); newest=${newest:-$cur_ver}
            switch_running_version "$newest" "latest" || exit 1
            info "Switched to 'latest' (${newest})."
          fi
        fi
        ask "Enable auto-update? [Y/n]:"
        read -r toggle_choice
        toggle_choice=${toggle_choice:-Y}
        if [[ "${toggle_choice,,}" =~ ^y ]]; then
          enable_auto_update_timer || exit 1
          info "Auto-update ENABLED (daily at ~04:00)."
        else
          info "No changes."
        fi
      fi
      exit 0
      ;;
    3)
      header "Rebuild current version"
      rebuild_stack "--pull" || { err "Rebuild failed."; exit 1; }
      prune_old_local_images "$(get_current_version)"
      info "Rebuilt version ${cur_ver}."
      exit 0
      ;;
    4)
      # Reinstall: clean up, then fall through to the fresh-install flow below.
      cleanup_existing_install
      ;;
    5)
      # Full uninstall: clean up everything and stop.
      cleanup_existing_install
      info "Uninstall complete."
      exit 0
      ;;
    6)
      info "Exiting."
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
  uname="${uname#"${uname%%[![:space:]]*}"}"
  uname="${uname%"${uname##*[![:space:]]}"}"
  if [[ -z "$uname" ]]; then break; fi
  if [[ ! "$uname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    warn "Username may only contain letters, digits, '_' and '-'. Try again."
    continue
  fi
  if [[ -n "${SECRETS[$uname]+_}" ]]; then
    warn "User '${uname}' already added. Try a different name."
    continue
  fi

  echo ""
  printf "  %bSecret for '%s':%b\n" "$BOLD" "$uname" "$NC"
  echo "  1) Generate automatically (random 32-hex)"
  echo "  2) Enter custom secret (32 hex characters)"
  echo ""
  ask "Choice [1]:"
  read -r secret_choice
  secret_choice=${secret_choice:-1}

  if [[ "$secret_choice" == "2" ]]; then
    while true; do
      ask "Enter 32-char hex secret:"
      read -r secret
      secret="${secret#"${secret%%[![:space:]]*}"}"
      secret="${secret%"${secret##*[![:space:]]}"}"
      secret="${secret,,}"
      if [[ ! "$secret" =~ ^[0-9a-f]{32}$ ]]; then
        warn "Invalid secret: must be exactly 32 hexadecimal characters (0-9, a-f)."
        continue
      fi
      break
    done
  else
    secret=$(openssl rand -hex 16)
  fi

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

while true; do
  ask "Telemt listen port [443]:"
  read -r PORT
  PORT=${PORT:-443}
  if ! is_valid_port "$PORT"; then
    warn "Invalid port: ${PORT} (must be 1–65535). Try again."
    continue
  fi
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

echo ""
info "announce_ip — the public IP that telemt advertises in proxy links."
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
    warn "announce_ip is required."; continue
  fi
  if ! sanitize_input "$ANNOUNCE_IP"; then
    warn "Invalid characters in IP address."; continue
  fi
  if ! is_valid_ipv4 "$ANNOUNCE_IP"; then
    warn "Invalid IPv4 address: ${ANNOUNCE_IP}. Try again."; continue
  fi
  break
done

# ─────────────────────────────────────────────────────────────────────────
# §3  TLS MASKING (CENSORSHIP BYPASS)
# ─────────────────────────────────────────────────────────────────────────
header "TLS masking (censorship bypass)"

info "Telemt disguises MTProto traffic as TLS to a legitimate website."
info "Examples: www.google.com, www.microsoft.com, cloudflare.com"
echo ""

while true; do
  ask "TLS domain [www.google.com]:"
  read -r TLS_DOMAIN
  TLS_DOMAIN=${TLS_DOMAIN:-www.google.com}
  if ! sanitize_input "$TLS_DOMAIN"; then
    warn "Invalid characters in domain."; continue
  fi
  if ! is_valid_domain "$TLS_DOMAIN"; then
    warn "Invalid domain format: ${TLS_DOMAIN}. Try again."; continue
  fi
  break
done

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

if [[ "${SELECTED_CHANNEL}" != "latest" ]]; then
  warn "You pinned version ${SELECTED_VERSION}; auto-update acts only on channel 'latest'."
  ask "Enable automatic daily rebuild/update? [y/N]:"
  read -r AUTO_UPDATE
  AUTO_UPDATE=${AUTO_UPDATE:-N}
else
  ask "Enable automatic daily rebuild/update? [Y/n]:"
  read -r AUTO_UPDATE
  AUTO_UPDATE=${AUTO_UPDATE:-Y}
fi

# ══════════════════════════════════════════════════════════════════════════
# ██  DEPLOYMENT                                                          ██
# ══════════════════════════════════════════════════════════════════════════
header "Deploying"

info "Creating ${INSTALL_DIR} …"
mkdir -p "${INSTALL_DIR}"

info "Creating ${INSTALL_DIR}/${CONFIG_DIR} (config + data) …"
mkdir -p "${INSTALL_DIR}/${CONFIG_DIR}/data"

cat > "${INSTALL_DIR}/${INSTALL_MARKER}" <<MARKER
name=telemt
script=mt-docker
compose=${COMPOSE_FILE}
dockerfile=${DOCKERFILE}
config_dir=${CONFIG_DIR}
source_image=${GHCR_IMAGE}
local_image=${LOCAL_IMAGE}
MARKER

info "Installing management script copy …"
install_self_copy

info "Downloading template: ${DOCKERFILE} …"
download_config_template "${DOCKERFILE}" "${INSTALL_DIR}/${DOCKERFILE}"

info "Downloading template: ${CONFIG_FILE} …"
download_config_template "${CONFIG_FILE}" "${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"

info "Downloading template: ${COMPOSE_FILE} …"
download_config_template "${COMPOSE_FILE}" "${INSTALL_DIR}/${COMPOSE_FILE}"

# ── write .env (build arg + update channel) ──────────────────────────────
info "Writing ${ENV_FILE} (TELEMT_VERSION=${SELECTED_VERSION}, UPDATE_CHANNEL=${SELECTED_CHANNEL}) …"
set_env_kv "TELEMT_VERSION" "${SELECTED_VERSION}" "${ENV_PATH}"
set_env_kv "UPDATE_CHANNEL" "${SELECTED_CHANNEL}" "${ENV_PATH}"

# ── patch telemt.toml ──────────────────────────────────────────────────
info "Configuring ${CONFIG_FILE} …"

show_link_val=""
for u in "${USERS[@]}"; do
  show_link_val+="\"${u}\", "
done
show_link_val="[${show_link_val%, }]"

users_tmp=$(mktemp)
trap 'rm -f "$users_tmp"' EXIT
for u in "${USERS[@]}"; do
  echo "${u} = \"${SECRETS[$u]}\"" >> "$users_tmp"
done

CONFIG_PATH="${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"

sed -i "s|^show_link = .*|show_link = ${show_link_val}|"        "${CONFIG_PATH}"
sed -i "s|^port = .*|port = ${PORT}|"                           "${CONFIG_PATH}"
sed -i "s|^announce_ip = .*|announce_ip = \"${ANNOUNCE_IP}\"|"   "${CONFIG_PATH}"
sed -i "s|^tls_domain = .*|tls_domain = \"${TLS_DOMAIN}\"|"     "${CONFIG_PATH}"
sed -i "s|^mask_port = .*|mask_port = ${MASK_PORT}|"            "${CONFIG_PATH}"

sed -i "/^\[access\.users\]$/r ${users_tmp}" "${CONFIG_PATH}"
rm -f "$users_tmp"
trap - EXIT

# Config + data must be writable by the non-root container user (uid 65532).
# Done AFTER sed -i (which rewrites the file as root) so the final file is
# owned by the container user, enabling in-place and atomic config writes.
chown -R "${NONROOT_UID}:${NONROOT_GID}" "${INSTALL_DIR}/${CONFIG_DIR}"
chmod 755 "${INSTALL_DIR}/${CONFIG_DIR}" "${INSTALL_DIR}/${CONFIG_DIR}/data"
chmod 644 "${CONFIG_PATH}"

if (( PORT < 1024 )); then
  info "Port ${PORT} is privileged (<1024); the built binary carries cap_net_bind_service."
fi

# ── systemd service ────────────────────────────────────────────────────
if [[ "${CREATE_SERVICE,,}" =~ ^y ]]; then
  info "Downloading template: ${SERVICE_FILE} …"
  download_config_template "${SERVICE_FILE}" "/etc/systemd/system/${SERVICE_FILE}"
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${INSTALL_DIR}|" "/etc/systemd/system/${SERVICE_FILE}"
  # Point Exec* lines at the installed script copy (handles non-default INSTALL_DIR)
  sed -i "s|/opt/telemt/install-mtproto.sh|${INSTALL_DIR}/install-mtproto.sh|g" \
    "/etc/systemd/system/${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_FILE}"
  info "Service enabled: ${SERVICE_FILE}"
fi

# ── auto-update timer ──────────────────────────────────────────────────
if [[ "${AUTO_UPDATE,,}" =~ ^y ]]; then
  info "Creating auto-update timer …"
  enable_auto_update_timer || exit 1
  info "Auto-update timer enabled (daily at ~04:00)."
fi

# ── build image & start ────────────────────────────────────────────────
info "Building image ${LOCAL_IMAGE}:${SELECTED_VERSION} from ${GHCR_IMAGE}:${SELECTED_VERSION} …"
cd "${INSTALL_DIR}" || { err "Cannot cd to ${INSTALL_DIR}"; exit 1; }

if ! compose_build --pull; then
  err "Failed to build the image. Check Docker and network connectivity."
  exit 1
fi

info "Starting container …"
if ! compose up -d; then
  err "Failed to start container. Check config with: docker compose config"
  exit 1
fi

# ── wait for container to be running ──────────────────────────────────
info "Waiting for telemt to start …"
container_running=false
for _ in {1..15}; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
    container_running=true
    break
  fi
  sleep 2
done

if $container_running; then
  info "Container 'telemt' is running."
else
  err "Container 'telemt' did not start. Check: docker logs telemt"
  exit 1
fi

# ── verify port is listening ──────────────────────────────────────────
if command -v ss &>/dev/null; then
  port_listening=false
  for _ in {1..15}; do
    if ss -tlnp 2>/dev/null | grep -qE "[[:space:]][^[:space:]]*:${PORT}[[:space:]]"; then
      port_listening=true
      break
    fi
    sleep 2
  done
  if $port_listening; then
    info "Port ${PORT} is listening — OK"
  else
    err "Port ${PORT} is not listening. Check container logs: docker logs telemt"
    exit 1
  fi
else
  warn "'ss' not found; skipping listen-port verification."
fi

# ══════════════════════════════════════════════════════════════════════════
# ██  SUMMARY                                                             ██
# ══════════════════════════════════════════════════════════════════════════
echo ""
printf '%b════════════════════════════════════════════%b\n' "$BOLD" "$NC"
printf '%b%b  Installation complete!%b\n' "$GREEN" "$BOLD" "$NC"
printf '%b════════════════════════════════════════════%b\n' "$BOLD" "$NC"
echo ""
info "Install dir  : ${INSTALL_DIR}"
info "Config dir   : ${INSTALL_DIR}/${CONFIG_DIR}"
info "Config       : ${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"
info "Compose      : ${INSTALL_DIR}/${COMPOSE_FILE}"
info "Dockerfile   : ${INSTALL_DIR}/${DOCKERFILE}"
info "Source image : ${GHCR_IMAGE}:${SELECTED_VERSION}"
info "Built image  : ${LOCAL_IMAGE}:${SELECTED_VERSION}  (channel: ${SELECTED_CHANNEL})"
info "Network      : host mode (no Docker port mapping)"
info "Listen port  : ${PORT}"
info "Announce IP  : ${ANNOUNCE_IP}"
info "TLS domain   : ${TLS_DOMAIN}:${MASK_PORT}"
echo ""

# ── proxy links ────────────────────────────────────────────────────────
info "Users & proxy links:"
echo ""
domain_hex=$(printf '%s' "${TLS_DOMAIN}" | xxd -p | tr -d '\n')
for u in "${USERS[@]}"; do
  s="${SECRETS[$u]}"
  encoded_secret="ee${s}${domain_hex}"
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
  info "Reload      : systemctl reload ${SERVICE_NAME}   (rebuild + recreate)"
fi
info "Lifecycle   : bash ${INSTALL_DIR}/install-mtproto.sh --{start|stop|restart|status|logs}"
info "Rebuild     : bash ${INSTALL_DIR}/install-mtproto.sh --rebuild"
info "Logs        : docker logs telemt --tail=50 -f"
info "Config      : nano ${INSTALL_DIR}/${CONFIG_DIR}/${CONFIG_FILE}"
info "Uninstall   : bash ${INSTALL_DIR}/install-mtproto.sh --uninstall"
echo ""
header "Version management"
info "List versions   : bash ${INSTALL_DIR}/install-mtproto.sh --list-versions"
info "Switch version  : bash ${INSTALL_DIR}/install-mtproto.sh --set-version [VERSION|latest]"
info "Update status   : bash ${INSTALL_DIR}/install-mtproto.sh --update-status"
info "Enable updates  : bash ${INSTALL_DIR}/install-mtproto.sh --update-enable"
info "Disable updates : bash ${INSTALL_DIR}/install-mtproto.sh --update-disable"

echo ""
printf '%b%b⚠  FIREWALL REMINDER:%b\n' "$YELLOW" "$BOLD" "$NC"
printf '%b   Make sure your nftables config allows traffic on port %s.%b\n' "$YELLOW" "$PORT" "$NC"
printf '%b   Apply: nft -f /etc/nftables.conf%b\n' "$YELLOW" "$NC"
echo ""
