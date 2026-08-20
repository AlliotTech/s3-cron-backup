#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

WORK_DIR="${WORK_DIR:-/tmp/s3-cron-backup}"
S3_STORAGE_CLASS="${S3_STORAGE_CLASS:-STANDARD}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/scripts/vaultwarden-backup.sh}"
BACKUP_OUTPUT=""

die() {
    printf '[backup] ERROR: %s\n' "$*" >&2
    exit 1
}

require_env() {
    local name="$1"

    [[ -n "${!name:-}" ]] || die "${name} is required"
}

cleanup() {
    local status=$?

    trap - EXIT
    if [[ -n "$BACKUP_OUTPUT" && -f "$BACKUP_OUTPUT" ]]; then
        rm -f -- "$BACKUP_OUTPUT"
    fi
    exit "$status"
}

trap cleanup EXIT

require_env BACKUP_NAME
require_env S3_BUCKET_URL
require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY

[[ "$BACKUP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "BACKUP_NAME contains invalid characters"
[[ -x "$BACKUP_SCRIPT" ]] || die "BACKUP_SCRIPT is not executable: $BACKUP_SCRIPT"

mkdir -p "$WORK_DIR"

exec {LOCK_FD}>"$WORK_DIR/backup.lock"
flock --nonblock "$LOCK_FD" || die "another backup is already running"

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
BACKUP_OUTPUT="${WORK_DIR%/}/${BACKUP_NAME}-${TIMESTAMP}.tar.gz"
export BACKUP_OUTPUT WORK_DIR

printf '[backup] running: %s\n' "$BACKUP_SCRIPT" >&2
"$BACKUP_SCRIPT"
[[ -s "$BACKUP_OUTPUT" ]] || die "backup script did not create: $BACKUP_OUTPUT"

export AWS_CLI_AUTO_PROMPT=off
export AWS_PAGER=""
if [[ "${S3_ENDPOINT:-}" == *r2.cloudflarestorage.com* ]]; then
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
    export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
    export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
fi

AWS_ARGS=()
if [[ -n "${S3_ENDPOINT:-}" ]]; then
    AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT")
fi

DESTINATION="${S3_BUCKET_URL%/}/$(basename "$BACKUP_OUTPUT")"
printf '[backup] uploading: %s\n' "$DESTINATION" >&2
aws "${AWS_ARGS[@]}" s3 cp \
    "$BACKUP_OUTPUT" \
    "$DESTINATION" \
    --only-show-errors \
    --storage-class "$S3_STORAGE_CLASS"

printf '[backup] completed\n' >&2
