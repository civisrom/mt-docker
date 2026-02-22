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
2. Устанавливает системные зависимости (openssl, curl, wget, ca-certificates, jq)
3. Предлагает установить Docker CE + Compose plugin через официальный скрипт и запускает демон
4. Скачивает и запускает основной скрипт `install-mtproto.sh`

### Требования

- Linux (Debian/Ubuntu, CentOS/RHEL, Fedora)
- Root-доступ

> Все остальные зависимости (Docker, OpenSSL и т.д.) устанавливаются автоматически.

Скрипт интерактивно запрашивает:

| Параметр | Описание |
|----------|----------|
| Пользователи | Имена для `show_link` / `[access.users]`; для каждого генерируется секретный ключ через `openssl rand -hex 16` |
| Порт сервера | Порт, на котором слушает прокси (по умолчанию `443`) |
| Announce IP | Внешний IP-адрес сервера |
| TLS-домен | Домен для TLS-маскировки (обязательный, например `example.com`) |
| Порт хоста | Маппинг порта Docker на стороне хоста |
| Systemd-служба | Создать systemd-юнит для автозапуска |
| Авто-обновление | Включить ежедневный таймер обновления образа |

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

# Логи
sudo docker compose -f /opt/telemt/docker-compose.yml logs -f

# Ручное обновление образа
sudo docker compose -f /opt/telemt/docker-compose.yml pull && \
sudo docker compose -f /opt/telemt/docker-compose.yml up -d

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
