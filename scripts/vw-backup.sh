#!/usr/bin/env bash
#
# Create an encrypted backup of /data and upload it to S3-compatible storage.
#
#   /data  --(consistent snapshot)-->  tar.gz  --(age)-->  *.tar.gz.age  --> S3
#
# All progress is written to stdout so it is visible in `kubectl logs`.
#
set -euo pipefail

# shellcheck disable=SC1091
source /etc/vaultwarden-backup.env

log()  { echo "[vaultwarden-backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
fail() { log "ERROR: $*"; exit 1; }

RCLONE_CONF=/root/.config/rclone/rclone.conf
DATA_DIR=/data

TS="$(date -u '+%Y%m%dT%H%M%SZ')"
ARCHIVE="vaultwarden-${TS}.tar.gz.age"
REMOTE="s3backup:${BACKUP_S3_BUCKET}/${BACKUP_S3_PATH_PREFIX}${ARCHIVE}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Starting backup of ${DATA_DIR}"
[[ -d "$DATA_DIR" ]] || fail "${DATA_DIR} does not exist"

# --- 1. Build a consistent snapshot -----------------------------------------
SNAP="$WORK/snapshot"
mkdir -p "$SNAP"
cp -a "${DATA_DIR}/." "$SNAP/" 2>/dev/null || true

# Replace the live SQLite DB with a transactionally consistent copy.
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${DATA_DIR}/db.sqlite3" ]]; then
  rm -f "$SNAP/db.sqlite3" "$SNAP/db.sqlite3-wal" "$SNAP/db.sqlite3-shm"
  sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '$SNAP/db.sqlite3'" \
    && log "Captured consistent SQLite snapshot" \
    || fail "sqlite3 .backup failed"
fi

# Volatile / regenerable data — no need to keep.
rm -rf "$SNAP/tmp"

# --- 2. Compress ------------------------------------------------------------
log "Creating compressed archive"
tar -czf "$WORK/data.tar.gz" -C "$SNAP" . || fail "tar failed"

# --- 3. Encrypt with age (public recipient key(s)) --------------------------
# BACKUP_AGE_KEY may contain multiple whitespace-separated recipient keys.
AGE_ARGS=()
AGE_RECIPIENTS=0
for k in $BACKUP_AGE_KEY; do
  AGE_ARGS+=( -r "$k" )
  AGE_RECIPIENTS=$(( AGE_RECIPIENTS + 1 ))
done
log "Encrypting archive with age (${AGE_RECIPIENTS} recipient(s))"
age "${AGE_ARGS[@]}" -o "$WORK/$ARCHIVE" "$WORK/data.tar.gz" || fail "age encryption failed"

SIZE="$(du -h "$WORK/$ARCHIVE" | cut -f1)"
log "Encrypted archive ready: ${ARCHIVE} (${SIZE})"

# --- 4. Upload --------------------------------------------------------------
log "Uploading to ${REMOTE}"
rclone --config "$RCLONE_CONF" copyto "$WORK/$ARCHIVE" "$REMOTE" || fail "upload failed"

log "Backup completed successfully: ${ARCHIVE}"
