#!/usr/bin/env bash
#
# Container entrypoint.
#
# 1. If a complete set of BACKUP_* variables is present, generate the rclone
#    config, an env file for the cron jobs, and the /etc/cron.d schedule.
# 2. Otherwise run vaultwarden without any scheduled backups.
# 3. Hand off (exec) to supervisord which manages vaultwarden + cron.
#
set -euo pipefail

log() { echo "[vaultwarden-entrypoint] $*"; }

# ---- Defaults ---------------------------------------------------------------
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 * * * *}"            # hourly
BACKUP_RETENTION_SCHEDULE="${BACKUP_RETENTION_SCHEDULE:-30 3 * * *}"  # daily 03:30
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-24}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"
BACKUP_S3_PROVIDER="${BACKUP_S3_PROVIDER:-Other}"
BACKUP_S3_PATH_PREFIX="${BACKUP_S3_PATH_PREFIX:-}"

CRON_FILE=/etc/cron.d/vaultwarden-backup
ENV_FILE=/etc/vaultwarden-backup.env
RCLONE_CONF=/root/.config/rclone/rclone.conf

# Required variables for backups to be enabled.
backups_enabled() {
  [[ -n "${BACKUP_AGE_KEY:-}"              \
     && -n "${BACKUP_S3_ENDPOINT:-}"       \
     && -n "${BACKUP_S3_BUCKET:-}"         \
     && -n "${BACKUP_S3_ACCESS_KEY_ID:-}"  \
     && -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]]
}

any_backup_var_set() { compgen -v | grep -q '^BACKUP_'; }

# Always start from a clean slate (image rebuild / restart with new env).
rm -f "$CRON_FILE" "$ENV_FILE"

if backups_enabled; then
  log "Backup configuration detected — enabling scheduled backups."

  # Normalize prefix so it always ends with a single slash when non-empty.
  if [[ -n "$BACKUP_S3_PATH_PREFIX" && "${BACKUP_S3_PATH_PREFIX: -1}" != "/" ]]; then
    BACKUP_S3_PATH_PREFIX="${BACKUP_S3_PATH_PREFIX}/"
  fi

  # ---- rclone remote "s3backup" --------------------------------------------
  umask 077
  mkdir -p "$(dirname "$RCLONE_CONF")"
  cat > "$RCLONE_CONF" <<EOF
[s3backup]
type = s3
provider = ${BACKUP_S3_PROVIDER}
env_auth = false
access_key_id = ${BACKUP_S3_ACCESS_KEY_ID}
secret_access_key = ${BACKUP_S3_SECRET_ACCESS_KEY}
region = ${BACKUP_S3_REGION}
endpoint = ${BACKUP_S3_ENDPOINT}
EOF

  # ---- env file sourced by the cron jobs -----------------------------------
  # cron runs with a minimal environment, so persist what the jobs need.
  {
    for v in BACKUP_AGE_KEY BACKUP_S3_BUCKET BACKUP_S3_PATH_PREFIX BACKUP_RETENTION_COUNT; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  # ---- cron schedule -------------------------------------------------------
  # Output of each job is appended to PID 1's stdout (supervisord) so the logs
  # end up on the container stdout -> visible via `kubectl logs`.
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${BACKUP_SCHEDULE} root /usr/local/bin/vw-backup.sh >> /proc/1/fd/1 2>&1
${BACKUP_RETENTION_SCHEDULE} root /usr/local/bin/vw-cleanup.sh >> /proc/1/fd/1 2>&1
EOF
  chmod 644 "$CRON_FILE"

  log "Backup schedule    : '${BACKUP_SCHEDULE}'"
  log "Cleanup schedule   : '${BACKUP_RETENTION_SCHEDULE}'"
  log "Retention (count)  : ${BACKUP_RETENTION_COUNT}"
  log "S3 endpoint/bucket : ${BACKUP_S3_ENDPOINT} / ${BACKUP_S3_BUCKET}/${BACKUP_S3_PATH_PREFIX}"
else
  if any_backup_var_set; then
    log "WARNING: some BACKUP_* variables are set but the required set is incomplete — backups are DISABLED."
    log "Required: BACKUP_AGE_KEY, BACKUP_S3_ENDPOINT, BACKUP_S3_BUCKET, BACKUP_S3_ACCESS_KEY_ID, BACKUP_S3_SECRET_ACCESS_KEY."
  else
    log "No backup configuration — running vaultwarden without scheduled backups."
  fi
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/vaultwarden.conf
