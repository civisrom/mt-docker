# mt-docker

Интерактивный скрипт установки MTProto-прокси [telemt-docker](https://github.com/An0nX/telemt-docker).

## Быстрый старт (одна команда)

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh)
```

или через curl:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh)
```

Загрузочный скрипт (`install.sh`) автоматически:
1. Определяет дистрибутив (Debian/Ubuntu, CentOS/RHEL, Fedora)
2. Устанавливает системные зависимости (openssl, curl, wget, ca-certificates, jq, xxd)
3. Предлагает установить Docker CE + Compose plugin через официальный скрипт и запускает демон
4. Скачивает и запускает основной скрипт `install-mtproto.sh`

### Требования

- Linux (Debian/Ubuntu, CentOS/RHEL, Fedora)
- Root-доступ

> Все остальные зависимости (Docker, OpenSSL и т.д.) устанавливаются автоматически.

## Параметры установки

Скрипт интерактивно запрашивает:

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| Пользователи | Имена для `show_link` / `[access.users]`; секрет генерируется через `openssl rand -hex 16` | — |
| Порт сервера | Порт telemt в host mode (реальный порт на хосте) | `443` |
| Announce IP | Публичный IP сервера (автоопределение через ifconfig.me) | auto-detect |
| TLS-домен | Домен для TLS-маскировки (fake-TLS) | `www.google.com` |
| Systemd-служба | Создать systemd-юнит для автозапуска | `Y` |
| Авто-обновление | Ежедневный таймер обновления образа (04:00) | `Y` |

## Режим работы

Контейнер работает в **host network mode** — без Docker port mapping.
Порт задаётся в `telemt.toml` секции `[server] port` и является реальным портом на хосте.

После установки скрипт генерирует `tg://proxy` ссылки для каждого пользователя с fake-TLS кодированием.

## Создаваемые файлы

| Файл | Расположение |
|------|--------------|
| `telemt.toml` | `/opt/telemt/telemt.toml` |
| `docker-compose.yml` | `/opt/telemt/docker-compose.yml` |
| Systemd-служба | `/etc/systemd/system/telemt-compose.service` |
| Таймер обновления | `/etc/systemd/system/telemt-compose-update.timer` |

## Управление

```bash
# Служба
sudo systemctl start|stop|restart|status telemt-compose

# Перезапуск с новым конфигом
sudo systemctl reload telemt-compose

# Логи
sudo docker logs telemt --tail=50 -f

# Ручное обновление образа
cd /opt/telemt && sudo docker compose pull && sudo docker compose up -d --force-recreate

# Проверить таймер авто-обновления
sudo systemctl list-timers telemt-compose-update.timer
```

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --uninstall
```

или локально:

```bash
sudo bash install-mtproto.sh --uninstall
```
