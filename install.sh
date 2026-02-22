#!/usr/bin/env bash
#
# MTProto Proxy — bootstrap installer
#
# Run:
#   bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh)
#
# What it does:
#   1. Detects distro (Debian/Ubuntu or RHEL/CentOS/Fedora)
#   2. Installs system dependencies (openssl, curl, ca-certificates …)
#   3. Installs Docker CE + Compose plugin and enables the daemon
#   4. Downloads and launches the main install-mtproto.sh
#
set -euo pipefail

# ── colours / helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }

REPO_RAW="https://raw.githubusercontent.com/civisrom/mt-docker/main"

# ── root check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (or with sudo)."
  exit 1
fi

# ── detect distro ──────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_LIKE="${ID_LIKE,,:-}"
  else
    err "Cannot detect distribution (/etc/os-release not found)."
    exit 1
  fi
}

detect_distro
info "Detected distro: ${DISTRO_ID}"

# ── install system packages ────────────────────────────────────────────
install_packages() {
  case "${DISTRO_ID}" in
    debian|ubuntu|linuxmint|pop)
      info "Updating apt cache …"
      apt-get update -qq
      info "Installing dependencies …"
      apt-get install -y -qq \
        openssl \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        jq
      ;;
    centos|rhel|rocky|almalinux|ol)
      info "Installing dependencies (yum) …"
      yum install -y -q \
        openssl \
        curl \
        wget \
        ca-certificates \
        gnupg2 \
        yum-utils \
        jq
      ;;
    fedora)
      info "Installing dependencies (dnf) …"
      dnf install -y -q \
        openssl \
        curl \
        wget \
        ca-certificates \
        gnupg2 \
        dnf-plugins-core \
        jq
      ;;
    *)
      warn "Unknown distro '${DISTRO_ID}'. Trying apt-get …"
      apt-get update -qq && apt-get install -y -qq \
        openssl curl wget ca-certificates gnupg lsb-release jq || {
        err "Could not install packages. Install manually: openssl curl wget ca-certificates jq"
        exit 1
      }
      ;;
  esac
  info "System packages — OK"
}

install_packages

# ── install Docker CE ──────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
  else
    info "Installing Docker CE via official script …"
    curl -fsSL https://get.docker.com | sh
    info "Docker installed: $(docker --version)"
  fi

  # ensure daemon is running and enabled on boot
  info "Enabling and starting Docker daemon …"
  systemctl enable --now docker
  # wait until docker responds
  local retries=0
  while ! docker info &>/dev/null; do
    retries=$((retries + 1))
    if (( retries > 15 )); then
      err "Docker daemon did not start in time."
      exit 1
    fi
    sleep 2
  done
  info "Docker daemon — running"
}

install_docker

# ── verify Docker Compose plugin ──────────────────────────────────────
verify_compose() {
  if docker compose version &>/dev/null; then
    info "Docker Compose plugin: $(docker compose version --short)"
  else
    warn "Docker Compose plugin not found, installing …"
    case "${DISTRO_ID}" in
      debian|ubuntu|linuxmint|pop)
        apt-get install -y -qq docker-compose-plugin
        ;;
      centos|rhel|rocky|almalinux|ol)
        yum install -y -q docker-compose-plugin
        ;;
      fedora)
        dnf install -y -q docker-compose-plugin
        ;;
      *)
        # fallback: install from GitHub
        local compose_ver
        compose_ver=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        curl -fsSL "https://github.com/docker/compose/releases/download/${compose_ver}/docker-compose-$(uname -s)-$(uname -m)" \
          -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        ;;
    esac
    if docker compose version &>/dev/null; then
      info "Docker Compose plugin installed: $(docker compose version --short)"
    else
      err "Failed to install Docker Compose plugin."
      exit 1
    fi
  fi
}

verify_compose

# ── download & run main script ─────────────────────────────────────────
MAIN_SCRIPT_URL="${REPO_RAW}/install-mtproto.sh"
TMP_SCRIPT=$(mktemp /tmp/install-mtproto.XXXXXX.sh)

info "Downloading install-mtproto.sh …"
if command -v wget &>/dev/null; then
  wget -qO "${TMP_SCRIPT}" "${MAIN_SCRIPT_URL}"
elif command -v curl &>/dev/null; then
  curl -fsSL -o "${TMP_SCRIPT}" "${MAIN_SCRIPT_URL}"
fi

if [[ ! -s "${TMP_SCRIPT}" ]]; then
  err "Failed to download install-mtproto.sh"
  rm -f "${TMP_SCRIPT}"
  exit 1
fi

chmod +x "${TMP_SCRIPT}"

info "Launching MTProto configuration …"
echo ""
bash "${TMP_SCRIPT}" "$@"

rm -f "${TMP_SCRIPT}"
