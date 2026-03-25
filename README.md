# mt-docker

Интерактивный скрипт установки MTProto-прокси [telemt-docker](https://gitlab.com/An0nX/telemt-docker).

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
| Версия образа | Конкретная версия Docker-образа или `latest` | `latest` |
| Systemd-служба | Создать systemd-юнит для автозапуска | `Y` |
| Авто-обновление | Ежедневный таймер обновления образа (04:00) | `Y` (при `latest`), `N` (при пиннинге) |

## Режим работы

Контейнер работает в **host network mode** — без Docker port mapping.
Порт задаётся в `telemt.toml` секции `[server] port` и является реальным портом на хосте.

### Привилегированные порты (<1024)

Upstream-образ запускается от **non-root** пользователя по умолчанию. Если выбран порт ниже 1024 (например, 443), скрипт автоматически включает `user: "root"` в `docker-compose.yml` и отключает `no-new-privileges`, так как привязка к таким портам требует прав root.

### Монтирование конфигурации

Конфигурация монтируется как **директория** (`telemt-config/`), а не как отдельный файл. Это необходимо для поддержки атомарной записи конфигурации (API создаёт `.tmp` файл и переименовывает его).

После установки скрипт генерирует `tg://proxy` ссылки для каждого пользователя с fake-TLS кодированием.

## Создаваемые файлы

| Файл | Расположение |
|------|--------------|
| `telemt.toml` | `/opt/telemt/telemt-config/telemt.toml` |
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

## Управление версиями

```bash
# Показать доступные версии
sudo bash install-mtproto.sh --list-versions

# Переключиться на конкретную версию (интерактивно)
sudo bash install-mtproto.sh --set-version

# Переключиться на конкретную версию (напрямую)
sudo bash install-mtproto.sh --set-version 3.3.27

# Показать текущую версию и статус обновлений
sudo bash install-mtproto.sh --update-status
```

При выборе конкретной версии (не `latest`) скрипт автоматически предложит отключить авто-обновление, чтобы таймер не перезаписал выбранную версию.

## Управление авто-обновлениями

```bash
# Отключить авто-обновление
sudo bash install-mtproto.sh --update-disable

# Включить авто-обновление
sudo bash install-mtproto.sh --update-enable

# Проверить статус
sudo bash install-mtproto.sh --update-status
```

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --uninstall
```

или локально:

```bash
sudo bash install-mtproto.sh --uninstall
```
