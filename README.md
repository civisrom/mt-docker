# mt-docker

Interactive installation script for [telemt-docker](https://github.com/An0nX/telemt-docker) MTProto proxy.

## Quick start (one-liner)

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh)
```

or with curl:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh)
```

The bootstrap script (`install.sh`) automatically:
1. Detects distro (Debian/Ubuntu, CentOS/RHEL, Fedora)
2. Installs system dependencies (openssl, curl, wget, ca-certificates, jq)
3. Installs Docker CE + Compose plugin and enables/starts the daemon
4. Downloads and runs the main `install-mtproto.sh`

### Requirements

- Linux (Debian/Ubuntu, CentOS/RHEL, Fedora)
- Root access

> All other dependencies (Docker, OpenSSL, etc.) are installed automatically by the script.

The script will interactively ask for:

| Parameter | Description |
|-----------|-------------|
| Users | Usernames for `show_link` / `[access.users]`; a secret key is generated for each via `openssl rand -hex 16` |
| Server port | Port the proxy listens on (default `443`) |
| Announce IP | External IP of the server |
| TLS domain | Domain for TLS masking (required, e.g. `example.com`) |
| Host port | Docker port mapping on the host side |
| Systemd service | Whether to create a systemd unit for auto-start |
| Auto-update | Whether to enable a daily timer that pulls the latest image |

## Generated files

| File | Location |
|------|----------|
| `telemt.toml` | `/opt/telemt/telemt.toml` |
| `docker-compose.yml` | `/opt/telemt/docker-compose.yml` |
| Systemd service | `/etc/systemd/system/telemt-compose.service` |
| Update timer | `/etc/systemd/system/telemt-compose-update.timer` |

## Management

```bash
# Service
sudo systemctl start|stop|restart|status telemt-compose

# Logs
sudo docker compose -f /opt/telemt/docker-compose.yml logs -f

# Manual image update
sudo docker compose -f /opt/telemt/docker-compose.yml pull && \
sudo docker compose -f /opt/telemt/docker-compose.yml up -d

# Check auto-update timer
sudo systemctl list-timers telemt-compose-update.timer
```

## Uninstall

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --uninstall
```

or locally:

```bash
sudo bash install-mtproto.sh --uninstall
```
