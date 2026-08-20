#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf '[entrypoint] ERROR: %s\n' "$*" >&2
    exit 1
}

require_env() {
    local name="$1"

    [[ -n "${!name:-}" ]] || die "${name} is required"
}

start_cron() {
    local cron_dir cron_file field
    local -a fields=()

    require_env CRON_SCHEDULE
    require_env BACKUP_NAME
    require_env S3_BUCKET_URL
    require_env AWS_ACCESS_KEY_ID
    require_env AWS_SECRET_ACCESS_KEY

    [[ "$CRON_SCHEDULE" != *$'\n'* && "$CRON_SCHEDULE" != *$'\r'* ]] ||
        die "CRON_SCHEDULE must be a five-field cron expression"
    read -r -a fields <<<"$CRON_SCHEDULE"
    ((${#fields[@]} == 5)) || die "CRON_SCHEDULE must contain exactly five fields"
    for field in "${fields[@]}"; do
        [[ "$field" =~ ^[0-9A-Za-z*/,-]+$ ]] || die "invalid cron field: $field"
    done

    cron_dir="${WORK_DIR:-/tmp/s3-cron-backup}/crontabs"
    mkdir -p "$cron_dir"
    cron_file="$cron_dir/root"

    {
        printf 'SHELL=/bin/bash\n'
        printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
        printf '%s /backup.sh >>/proc/1/fd/1 2>>/proc/1/fd/2\n' "${fields[*]}"
    } >"$cron_file"
    chmod 0600 "$cron_file"

    printf '[entrypoint] cron schedule: %s (%s)\n' "${fields[*]}" "${TZ:-UTC}" >&2
    exec crond -f -d 8 -c "$cron_dir"
}

if (($# == 0)); then
    set -- cron
fi

case "$1" in
    backup)
        shift
        exec /backup.sh "$@"
        ;;
    cron)
        shift
        (($# == 0)) || die "cron mode does not accept arguments"
        start_cron
        ;;
    *)
        exec "$@"
        ;;
esac
