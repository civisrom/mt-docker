# mt-docker

Interactive installation script for [telemt-docker](https://github.com/An0nX/telemt-docker) MTProto proxy.

## Requirements

- Linux (Debian/Ubuntu recommended)
- Docker with Compose plugin (`docker compose`)
- OpenSSL

## Quick start

```bash
sudo bash install-mtproto.sh
```

The script will interactively ask for:

| Parameter | Description |
|-----------|-------------|
| Users | Usernames for `show_link` / `[access.users]`; a secret key is generated for each via `openssl rand -hex 16` |
| Server port | Port the proxy listens on (default `443`) |
| Announce IP | External IP of the server |
| TLS domain | Domain for TLS masking (default `online.<IP>.sslip.io`) |
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
sudo bash install-mtproto.sh --uninstall
```
