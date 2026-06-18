# telemt — MTProto-прокси (Rust, fake-TLS) из проекта telemt/telemt.
#
# Бинарь берём из ОФИЦИАЛЬНОГО образа GHCR (ghcr.io/telemt/telemt:<version>),
# где он лежит в /app/telemt и статически слинкован с musl. Это убирает
# зависимость от стороннего образа и от ручного разбора GitHub Releases: смена
# TELEMT_VERSION просто меняет тег base-образа, и пересборка тянет нужную
# версию.
#
# Контейнер собирается локально (docker compose build), а не тянется готовым.
# Запуск: telemt run --data-path /etc/telemt/data /etc/telemt/telemt.toml
ARG TELEMT_VERSION=3.4.18

# ── stage 1: достаём статический бинарь из официального образа ───────────
FROM ghcr.io/telemt/telemt:${TELEMT_VERSION} AS dl

# ── stage 2: минимальный runtime ────────────────────────────────────────
FROM alpine:3.21

# ca-certificates — для fake-TLS/upstream TLS; libcap — для setcap;
# tini — корректный reaper PID 1.
RUN apk add --no-cache ca-certificates libcap tini \
    && addgroup -g 65532 -S telemt \
    && adduser -u 65532 -S -G telemt -H -s /sbin/nologin telemt \
    && mkdir -p /etc/telemt/data \
    && chown -R 65532:65532 /etc/telemt

COPY --from=dl /app/telemt /usr/local/bin/telemt

# Бинарь запускается non-root пользователем. Чтобы он мог биндить
# привилегированные порты (<1024, напр. 443) без root, вешаем file-capability
# NET_BIND_SERVICE прямо на бинарь — для non-root это надёжнее, чем cap_add в
# compose (Docker не выставляет ambient-капабилити). ВНИМАНИЕ: file-capability
# работает только если в compose НЕ включён no-new-privileges (этот флаг
# отключает применение file-caps при execve) и NET_BIND_SERVICE остаётся в
# bounding set (cap_add).
RUN chmod 0755 /usr/local/bin/telemt \
    && setcap 'cap_net_bind_service=+ep' /usr/local/bin/telemt

USER 65532:65532
WORKDIR /etc/telemt

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/telemt"]
CMD ["run", "--data-path", "/etc/telemt/data", "/etc/telemt/telemt.toml"]
