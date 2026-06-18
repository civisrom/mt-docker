# mt-docker

Интерактивный установщик MTProto-прокси на базе [telemt/telemt](https://github.com/telemt/telemt).

Контейнер **собирается локально** из официального образа `ghcr.io/telemt/telemt`:
статический бинарь `telemt` копируется в минимальный alpine-образ — без
зависимости от сторонних готовых образов и без ручного разбора GitHub Releases.
Обновление = смена версии + пересборка.

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
- Docker с поддержкой `docker compose build` (ставится автоматически)

## Как собирается контейнер

`telemt.dockerfile` — двухстадийная сборка:

```dockerfile
ARG TELEMT_VERSION=3.4.18
FROM ghcr.io/telemt/telemt:${TELEMT_VERSION} AS dl   # официальный образ
FROM alpine:3.21                                     # минимальный runtime
COPY --from=dl /app/telemt /usr/local/bin/telemt
# non-root uid 65532 + file-capability cap_net_bind_service на бинаре
```

Запуск внутри контейнера:

```
telemt run --data-path /etc/telemt/data /etc/telemt/telemt.toml
```

Версия задаётся в `/opt/telemt/.env` (`TELEMT_VERSION`) и используется
одновременно как build-arg и как тег локального образа `civisrom/mt-telemt`.

## Параметры установки

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| Пользователи | Имена для `show_link` / `[access.users]`; секрет `openssl rand -hex 16` | — |
| Порт сервера | Порт telemt в host mode (реальный порт на хосте) | `443` |
| Announce IP | Публичный IP сервера (автоопределение) | auto-detect |
| TLS-домен | Домен для TLS-маскировки (fake-TLS) | `www.google.com` |
| Версия | Конкретная версия из GHCR или `latest` (отслеживать новейшую) | `latest` |
| Systemd-служба | systemd-юнит для автозапуска (сборка при старте) | `Y` |
| Авто-обновление | Ежедневная пересборка при появлении новой версии (04:00) | `Y` (latest) / `N` (pinned) |

## Режим работы

Контейнер работает в **host network mode** — без Docker port mapping.
Порт задаётся в `telemt.toml` секции `[server] port` и является реальным
портом на хосте.

### Привилегированные порты (<1024)

Бинарь запускается non-root пользователем (uid 65532). В `telemt.dockerfile`
на бинарь вешается file-capability `cap_net_bind_service=+ep`, а в compose —
`cap_add: NET_BIND_SERVICE` (держит её в bounding set). Это позволяет надёжно
биндить порт `443` без root.

> `no-new-privileges` намеренно **не включён** в compose: этот флаг отключает
> применение file-capabilities при `execve`, из-за чего non-root перестаёт
> биндить `443`. Если используете порт `>1024`, можете включить
> `no-new-privileges:true` и убрать `cap_add` для максимального hardening.

### Монтирование конфигурации

`telemt-config/` монтируется как директория в `/etc/telemt` (writable):
там лежат `telemt.toml` и `data/` (replay-кэш, fake-сертификаты). Остальная
ФС контейнера — `read_only`. Атомарная запись конфига (`.tmp` + rename)
поддерживается.

## Создаваемые файлы

| Файл | Расположение |
|------|--------------|
| `telemt.toml` | `/opt/telemt/telemt-config/telemt.toml` |
| `data/` | `/opt/telemt/telemt-config/data/` |
| `docker-compose.yml` | `/opt/telemt/docker-compose.yml` |
| `telemt.dockerfile` | `/opt/telemt/telemt.dockerfile` |
| `.env` | `/opt/telemt/.env` (`TELEMT_VERSION`, `UPDATE_CHANNEL`) |
| Systemd-служба | `/etc/systemd/system/telemt-compose.service` |
| Служба обновления | `/etc/systemd/system/telemt-compose-update.service` |
| Таймер обновления | `/etc/systemd/system/telemt-compose-update.timer` |

## Управление

Скрипт `install-mtproto.sh` — единая точка управления:

```bash
sudo bash /opt/telemt/install-mtproto.sh --start     # docker compose up -d --build
sudo bash /opt/telemt/install-mtproto.sh --stop      # docker compose down
sudo bash /opt/telemt/install-mtproto.sh --restart   # пересоздать контейнер
sudo bash /opt/telemt/install-mtproto.sh --rebuild   # пересобрать образ + пересоздать
sudo bash /opt/telemt/install-mtproto.sh --status    # статус контейнера/службы
sudo bash /opt/telemt/install-mtproto.sh --logs      # docker logs -f
```

Через systemd:

```bash
sudo systemctl start|stop|restart|status telemt-compose
sudo systemctl reload telemt-compose   # пересборка + пересоздание
sudo docker logs telemt --tail=50 -f
```

## Управление версиями и обновлениями

| Команда | Описание |
|---------|----------|
| `--list-versions` | Показать доступные версии из GHCR (`ghcr.io/telemt/telemt`) |
| `--set-version [V]` | Переключиться на версию `V` или `latest` (интерактивно или напрямую) |
| `--update-status` | Текущая версия, канал и статус авто-обновлений |
| `--update-enable` | Создать/включить таймер авто-обновления |
| `--update-disable` | Остановить и отключить таймер |
| `--auto-update` | Вызывается таймером: резолвит новейшую версию и пересобирает |

```bash
# показать доступные версии из GHCR
sudo bash /opt/telemt/install-mtproto.sh --list-versions

# переключиться на конкретную версию (канал станет pinned)
sudo bash /opt/telemt/install-mtproto.sh --set-version 3.4.18

# вернуться на отслеживание новейшей (канал latest)
sudo bash /opt/telemt/install-mtproto.sh --set-version latest
```

### Логика обновлений

- `.env` хранит `TELEMT_VERSION` (всегда конкретный тег) и `UPDATE_CHANNEL`.
- `UPDATE_CHANNEL=latest` — авто-обновление резолвит новейший semver-тег из
  GHCR; если он новее текущего — правит `.env` и **пересобирает** образ
  (`docker compose build --pull` + `up -d --force-recreate`), старые образы
  подчищаются.
- `UPDATE_CHANNEL=pinned` — авто-обновление ничего не меняет (no-op); при
  пиннинге установщик предлагает отключить таймер.
- Таймер срабатывает ежедневно в ~04:00 (рандомизация ±30 мин).

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/civisrom/mt-docker/main/install.sh) --uninstall
```

или локально:

```bash
sudo bash /opt/telemt/install-mtproto.sh --uninstall
```

Удаление **безопасное и точечное** — затрагивает только ресурсы telemt:

- контейнер по точному имени `telemt` и по метке `org.civisrom.mt-docker=telemt`
  (контейнеры других проектов на хосте, напр. rustdesk, не трогаются);
- локально собранные образы строго `civisrom/mt-telemt:*`;
- **build-кэш** — через удаление выделенного buildx-builder'а `mt-docker`
  (`docker buildx rm`). Весь кэш сборки изолирован в этом builder'е, поэтому
  чистится одной командой, не затрагивая дефолтный builder и кэш других
  проектов. Глобальный `docker builder prune` **не** запускается;
- systemd-юниты и каталог `/opt/telemt`.

Базовый образ `ghcr.io/telemt/telemt` намеренно **не удаляется**: он может
использоваться другими сборками на хосте.

### Почему выделенный builder

Сборка идёт через `docker buildx` builder `mt-docker` (драйвер
`docker-container`). Это даёт изолированный build-кэш, который можно полностью
снести при удалении, ничего не задев. Если buildx недоступен или builder не
создаётся (ограниченный хост) — сборка автоматически откатывается на дефолтный
builder, а удаление в этом случае не трогает общий кэш (безопасность важнее
полноты очистки).
