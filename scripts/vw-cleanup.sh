#!/usr/bin/env bash
#
# Retention: keep the newest BACKUP_RETENTION_COUNT backups in S3, delete older.
# Backup file names embed a fixed-width UTC timestamp, so a lexical sort equals
# a chronological sort.
#
set -euo pipefail

# shellcheck disable=SC1091
source /etc/vaultwarden-backup.env

log() { echo "[vaultwarden-cleanup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

RCLONE_CONF=/root/.config/rclone/rclone.conf
RET="${BACKUP_RETENTION_COUNT:-24}"
BASE="s3backup:${BACKUP_S3_BUCKET}/${BACKUP_S3_PATH_PREFIX}"

log "Enforcing retention: keep ${RET} most recent backup(s)"

mapfile -t FILES < <(
  rclone --config "$RCLONE_CONF" lsf --files-only "$BASE" 2>/dev/null \
    | grep -E '^vaultwarden-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.age$' \
    | sort
)

TOTAL=${#FILES[@]}
log "Found ${TOTAL} backup(s) in ${BASE}"

if (( TOTAL <= RET )); then
  log "Nothing to delete"
  exit 0
fi

DELCOUNT=$(( TOTAL - RET ))
log "Deleting ${DELCOUNT} old backup(s)"

for f in "${FILES[@]:0:DELCOUNT}"; do
  if rclone --config "$RCLONE_CONF" deletefile "${BASE}${f}"; then
    log "Deleted ${f}"
  else
    log "WARNING: failed to delete ${f}"
  fi
done

log "Cleanup completed"
