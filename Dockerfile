FROM alpine:3.24.2

# hadolint ignore=DL3018
RUN apk add --no-cache \
        aws-cli \
        bash \
        flock \
        gzip \
        sqlite \
        tar \
        tzdata

ENV BACKUP_SCRIPT=/scripts/vaultwarden-backup.sh \
    SQLITE_DB_PATH=db.sqlite3 \
    S3_STORAGE_CLASS=STANDARD \
    TARGET=/data \
    TZ=UTC \
    WORK_DIR=/tmp/s3-cron-backup

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 backup.sh /backup.sh
COPY --chmod=755 vaultwarden-backup.sh /scripts/vaultwarden-backup.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["cron"]
