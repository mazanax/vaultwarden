FROM vaultwarden/server:latest

# Extra tooling for the scheduled backup subsystem:
#   supervisor - run vaultwarden + cron side by side in one container
#   cron       - scheduling
#   age        - encryption of the backup archive
#   rclone     - upload to any S3-compatible object storage
#   sqlite3    - consistent snapshot of the vaultwarden database
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        supervisor \
        cron \
        age \
        rclone \
        sqlite3 \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY supervisor/supervisord.conf /etc/supervisor/conf.d/vaultwarden.conf
COPY scripts/entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY scripts/vw-backup.sh    /usr/local/bin/vw-backup.sh
COPY scripts/vw-cleanup.sh   /usr/local/bin/vw-cleanup.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/vw-backup.sh \
             /usr/local/bin/vw-cleanup.sh

# Our entrypoint prepares the cron/backup configuration from the environment,
# then hands off to supervisord which runs vaultwarden's own /start.sh.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
