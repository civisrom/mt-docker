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

## Управление версиями и обновлениями

### CLI-команды

| Команда | Описание |
|---------|----------|
| `--list-versions` | Показать доступные версии из Docker Hub |
| `--set-version [V]` | Переключиться на версию (интерактивно или напрямую) |
| `--update-status` | Текущая версия + статус авто-обновлений |
| `--update-enable` | Включить авто-обновление |
| `--update-disable` | Отключить авто-обновление |

Все команды можно запускать как напрямую, так и через bootstrap-скрипт (без повторной установки зависимостей):

```bash
# Напрямую (если скрипт уже скачан)
sudo bash install-mtproto.sh --list-versions

# Через bootstrap (скачает скрипт автоматически)
bash <(curl -fsSL https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --list-versions
```

### Выбор версии

```bash
# Показать доступные версии
sudo bash install-mtproto.sh --list-versions

# Переключиться интерактивно (покажет список и спросит выбор)
sudo bash install-mtproto.sh --set-version

# Переключиться на конкретную версию напрямую
sudo bash install-mtproto.sh --set-version 3.3.27

# Вернуться на latest
sudo bash install-mtproto.sh --set-version latest
```

### Управление авто-обновлениями

```bash
# Проверить статус (текущая версия, пиннинг, состояние таймера)
sudo bash install-mtproto.sh --update-status

# Отключить авто-обновление
sudo bash install-mtproto.sh --update-disable

# Включить авто-обновление
sudo bash install-mtproto.sh --update-enable
```

### Умная логика

- **При установке**: если выбрана конкретная версия (не `latest`), авто-обновление по умолчанию **отключается**
- **При `--set-version`**: если версия запинена и авто-обновление включено — скрипт объяснит, что таймер будет бесполезно тянуть тот же тег, и предложит отключить его
- **При `--update-enable`**: если версия запинена — скрипт предложит переключиться на `latest`, чтобы обновления действительно работали
- **Авто-обновление** запускается ежедневно в ~04:00 (с рандомизацией ±30 мин) и тянет тег, указанный в `docker-compose.yml`

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --uninstall
```

или локально:

```bash
sudo bash install-mtproto.sh --uninstall
```
