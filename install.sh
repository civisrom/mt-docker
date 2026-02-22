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
#   3. Offers to install Docker CE via official get.docker.com script
#   4. Downloads and launches the main install-mtproto.sh
#
set -euo pipefail

# ── colours / helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
ask()   { printf "${CYAN}[?]${NC}    %s " "$*"; }

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
        jq \
        sed
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
        jq \
        sed
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
        jq \
        sed
      ;;
    *)
      warn "Unknown distro '${DISTRO_ID}'. Trying apt-get …"
      apt-get update -qq && apt-get install -y -qq \
        openssl curl wget ca-certificates gnupg lsb-release jq sed || {
        err "Could not install packages. Install manually: openssl curl wget ca-certificates jq sed"
        exit 1
      }
      ;;
  esac
  info "System packages — OK"
}

install_packages

# ── Docker installation menu ──────────────────────────────────────────
install_docker_menu() {
  local docker_installed=false
  local compose_installed=false

  command -v docker &>/dev/null && docker_installed=true
  docker compose version &>/dev/null 2>&1 && compose_installed=true

  echo ""
  printf "${BOLD}── Docker installation ──${NC}\n"
  echo ""

  if $docker_installed; then
    info "Docker detected: $(docker --version)"
  else
    warn "Docker is NOT installed."
  fi

  if $compose_installed; then
    info "Docker Compose detected: $(docker compose version --short)"
  else
    warn "Docker Compose plugin is NOT installed."
  fi

  echo ""
  printf "${BOLD}Choose an option:${NC}\n"
  echo "  1) Install Docker CE + all components (official get.docker.com script)"
  echo "  2) Skip Docker installation (already installed / will install manually)"
  echo ""
  ask "Your choice [1/2]:"
  read -r docker_choice

  case "${docker_choice}" in
    1)
      info "Installing Docker CE via official script (https://get.docker.com) …"
      curl -fsSL https://get.docker.com | sh

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

      # verify compose plugin came with the install
      if ! docker compose version &>/dev/null 2>&1; then
        warn "Compose plugin not found after Docker install, installing separately …"
        case "${DISTRO_ID}" in
          debian|ubuntu|linuxmint|pop)
            apt-get install -y -qq docker-compose-plugin ;;
          centos|rhel|rocky|almalinux|ol)
            yum install -y -q docker-compose-plugin ;;
          fedora)
            dnf install -y -q docker-compose-plugin ;;
          *)
            err "Cannot install Compose plugin automatically for '${DISTRO_ID}'."
            err "Install docker-compose-plugin manually and re-run."
            exit 1 ;;
        esac
      fi

      info "Docker CE: $(docker --version)"
      info "Compose:   $(docker compose version --short)"
      ;;
    2)
      info "Skipping Docker installation."
      # verify what we need is actually present
      if ! command -v docker &>/dev/null; then
        err "Docker is not installed. Cannot continue."
        exit 1
      fi
      if ! docker compose version &>/dev/null 2>&1; then
        err "Docker Compose plugin is not installed. Cannot continue."
        exit 1
      fi
      # ensure daemon is running
      if ! docker info &>/dev/null 2>&1; then
        warn "Docker daemon is not running, starting …"
        systemctl enable --now docker
        local retries=0
        while ! docker info &>/dev/null; do
          retries=$((retries + 1))
          if (( retries > 15 )); then
            err "Docker daemon did not start in time."
            exit 1
          fi
          sleep 2
        done
      fi
      info "Docker — OK"
      ;;
    *)
      err "Invalid choice. Exiting."
      exit 1
      ;;
  esac
}

install_docker_menu

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
