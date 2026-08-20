#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

TARGET="${TARGET:-/data}"
SQLITE_DB_PATH="${SQLITE_DB_PATH:-db.sqlite3}"
TEMP_DIR=""

die() {
    printf '[vaultwarden-backup] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?

    trap - EXIT
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        case "$TEMP_DIR" in
            "${WORK_DIR:-/tmp/s3-cron-backup}"/vaultwarden.*)
                rm -rf -- "$TEMP_DIR"
                ;;
        esac
    fi
    exit "$status"
}

trap cleanup EXIT

[[ -n "${BACKUP_OUTPUT:-}" ]] || die "BACKUP_OUTPUT is required"
[[ -d "$TARGET" ]] || die "TARGET is not a directory: $TARGET"
[[ "$SQLITE_DB_PATH" != /* ]] || die "SQLITE_DB_PATH must be relative to TARGET"
[[ "$SQLITE_DB_PATH" != *'..'* ]] || die "SQLITE_DB_PATH must not contain '..'"

DATABASE="${TARGET%/}/$SQLITE_DB_PATH"
[[ -f "$DATABASE" ]] || die "database not found: $DATABASE"

TEMP_DIR="$(mktemp -d "${WORK_DIR:-/tmp/s3-cron-backup}/vaultwarden.XXXXXX")"
SNAPSHOT_ROOT="$TEMP_DIR/snapshot"
SNAPSHOT="$SNAPSHOT_ROOT/$SQLITE_DB_PATH"
TAR_FILE="$TEMP_DIR/backup.tar"
mkdir -p "$(dirname "$SNAPSHOT")"

SQLITE_SNAPSHOT_ARG="${SNAPSHOT//\\/\\\\}"
SQLITE_SNAPSHOT_ARG="${SQLITE_SNAPSHOT_ARG//\"/\\\"}"

printf '[vaultwarden-backup] creating SQLite snapshot\n' >&2
sqlite3 \
    "$DATABASE" \
    '.timeout 30000' \
    ".backup \"$SQLITE_SNAPSHOT_ARG\""

[[ "$(sqlite3 -batch -noheader "$SNAPSHOT" 'PRAGMA quick_check;')" == ok ]] ||
    die "SQLite snapshot check failed"

EXCLUDES=(
    "--exclude=$SQLITE_DB_PATH"
    "--exclude=./$SQLITE_DB_PATH"
    "--exclude=${SQLITE_DB_PATH}-wal"
    "--exclude=./${SQLITE_DB_PATH}-wal"
    "--exclude=${SQLITE_DB_PATH}-shm"
    "--exclude=./${SQLITE_DB_PATH}-shm"
)

if [[ -n "${TAR_EXCLUDES:-}" ]]; then
    read -r -a EXTRA_EXCLUDES <<<"$TAR_EXCLUDES"
    for pattern in "${EXTRA_EXCLUDES[@]}"; do
        EXCLUDES+=("--exclude=$pattern")
    done
fi

printf '[vaultwarden-backup] creating archive\n' >&2
tar \
    --create \
    --file "$TAR_FILE" \
    "${EXCLUDES[@]}" \
    --directory "$TARGET" \
    .
tar \
    --append \
    --file "$TAR_FILE" \
    --directory "$SNAPSHOT_ROOT" \
    "./$SQLITE_DB_PATH"
gzip --stdout "$TAR_FILE" >"$BACKUP_OUTPUT"
gzip --test "$BACKUP_OUTPUT"

printf '[vaultwarden-backup] archive ready: %s\n' "$BACKUP_OUTPUT" >&2
