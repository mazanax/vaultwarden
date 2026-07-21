# Custom Vaultwarden with encrypted S3 backups

A drop-in image based on `vaultwarden/server:latest` that adds an **optional**,
self-contained backup subsystem:

- When the `BACKUP_*` variables are set, a cron job periodically archives
  `/data`, encrypts it with [age](https://age-encryption.org), and uploads it to
  any S3-compatible object storage via [rclone](https://rclone.org).
- A separate cron job enforces retention — it keeps only the newest *N* backups
  and deletes the rest.
- Every backup/cleanup step is printed to the container **stdout**, so it shows
  up in `docker logs` / `kubectl logs`.
- When the variables are **not** set, the image behaves exactly like stock
  vaultwarden — nothing extra runs.

`vaultwarden` and `cron` run side by side under `supervisord`, so a single
container both serves the app and produces backups.

## Repository layout

```
.
├── Dockerfile                    # base image + supervisor, cron, age, rclone, sqlite3
├── supervisor/supervisord.conf   # runs vaultwarden (/start.sh) and cron together
├── scripts/
│   ├── entrypoint.sh             # builds rclone + cron config from env, then execs supervisord
│   ├── vw-backup.sh              # snapshot /data -> tar.gz -> age -> S3
│   └── vw-cleanup.sh             # retention enforcement
├── docker-compose.yml
├── k8s/deployment.yaml
└── .env.example
```

## Quick start

```bash
cp .env.example .env      # fill in your values (see below)
docker compose up -d --build
docker logs -f vaultwarden
```

---

# Backups

## How it works

```
          BACKUP_SCHEDULE (hourly)                 BACKUP_RETENTION_SCHEDULE (daily)
                  │                                             │
                  ▼                                             ▼
   /data ──► sqlite3 .backup (consistent DB)          list backups in S3
         ──► tar -czf  (compress)                     sort by timestamp
         ──► age -r    (encrypt, public key)          delete all but newest N
         ──► rclone    (upload to S3)
                  │                                             │
                  ▼                                             ▼
   s3://BUCKET/PREFIX/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz.age   (old objects removed)
```

- The SQLite database is copied with `sqlite3 .backup` for a transactionally
  consistent snapshot. The volatile `tmp/` directory is skipped; everything else
  in `/data` (attachments, sends, `rsa_key*`, `config.json`, `icon_cache`, …) is
  included.
- Archives are named with a fixed-width UTC timestamp
  (`vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz.age`), so a lexical sort equals a
  chronological sort — that is how retention decides what is "old".
- All output goes to the container stdout via `/proc/1/fd/1`, so backup logs are
  visible with `kubectl logs` without any log driver configuration.

## Enabling backups

Backups turn on **only when all required variables are present**. If some — but
not all — required variables are set, backups stay **disabled** and a warning is
logged at startup so misconfiguration is obvious.

### Step 1 — generate an age key pair

The container only ever holds the **public** recipient key: it can encrypt but
never decrypt. Keep the private key somewhere safe and offline (a secrets
manager, a password vault, printed paper — anywhere but the container).

```bash
age-keygen -o key.txt
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
#             ^ this string goes into BACKUP_AGE_KEY
# key.txt contains the private key (AGE-SECRET-KEY-...) — store it OUTSIDE the container
```

You may pass several public keys (space-separated) in `BACKUP_AGE_KEY` to
encrypt each backup to multiple recipients.

### Step 2 — set the environment variables

Minimum required set:

```bash
BACKUP_AGE_KEY=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
BACKUP_S3_ENDPOINT=https://s3.us-east-1.amazonaws.com
BACKUP_S3_BUCKET=my-vaultwarden-backups
BACKUP_S3_ACCESS_KEY_ID=AKIA...
BACKUP_S3_SECRET_ACCESS_KEY=...
```

### Step 3 — (re)start the container

On startup `entrypoint.sh` writes the rclone remote, an env file for the cron
jobs, and `/etc/cron.d/vaultwarden-backup`, then hands off to supervisord. You
should see:

```
[vaultwarden-entrypoint] Backup configuration detected — enabling scheduled backups.
[vaultwarden-entrypoint] Backup schedule    : '0 * * * *'
[vaultwarden-entrypoint] Cleanup schedule   : '30 3 * * *'
[vaultwarden-entrypoint] Retention (count)  : 24
```

## Configuration reference

| Variable | Required | Default | Description |
|---|:---:|---|---|
| `BACKUP_AGE_KEY` | ✅ | – | age **public** recipient key(s) (`age1...`); space-separated for multiple |
| `BACKUP_S3_ENDPOINT` | ✅ | – | S3 endpoint URL (e.g. `https://s3.us-east-1.amazonaws.com`, `https://<acct>.r2.cloudflarestorage.com`, `http://minio:9000`) |
| `BACKUP_S3_BUCKET` | ✅ | – | Target bucket name |
| `BACKUP_S3_ACCESS_KEY_ID` | ✅ | – | S3 access key ID |
| `BACKUP_S3_SECRET_ACCESS_KEY` | ✅ | – | S3 secret access key |
| `BACKUP_SCHEDULE` | – | `0 * * * *` | Cron expression for the backup job (default: hourly) |
| `BACKUP_RETENTION_SCHEDULE` | – | `30 3 * * *` | Cron expression for the cleanup job (default: daily 03:30) |
| `BACKUP_RETENTION_COUNT` | – | `24` | How many of the most recent backups to keep |
| `BACKUP_S3_PATH_PREFIX` | – | *(none)* | Key prefix inside the bucket, e.g. `vaultwarden/`; trailing slash optional |
| `BACKUP_S3_REGION` | – | `us-east-1` | S3 region |
| `BACKUP_S3_PROVIDER` | – | `Other` | rclone S3 provider: `AWS`, `Minio`, `Wasabi`, `Cloudflare`, `Ceph`, `DigitalOcean`, … |

### Cron expression tips

`BACKUP_SCHEDULE` / `BACKUP_RETENTION_SCHEDULE` are standard 5-field cron
expressions:

| Expression | Meaning |
|---|---|
| `0 * * * *` | every hour (default backup) |
| `*/15 * * * *` | every 15 minutes |
| `0 */6 * * *` | every 6 hours |
| `0 2 * * *` | every day at 02:00 |
| `30 3 * * *` | every day at 03:30 (default cleanup) |

### Provider examples

**AWS S3**

```bash
BACKUP_S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com
BACKUP_S3_REGION=eu-central-1
BACKUP_S3_PROVIDER=AWS
```

**MinIO**

```bash
BACKUP_S3_ENDPOINT=http://minio:9000
BACKUP_S3_PROVIDER=Minio
```

**Cloudflare R2**

```bash
BACKUP_S3_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
BACKUP_S3_REGION=auto
BACKUP_S3_PROVIDER=Cloudflare
```

## Testing / manual runs

Run either job on demand (logs go to your terminal):

```bash
docker exec vaultwarden /usr/local/bin/vw-backup.sh
docker exec vaultwarden /usr/local/bin/vw-cleanup.sh
```

Inspect the generated config inside the container:

```bash
docker exec vaultwarden cat /etc/cron.d/vaultwarden-backup
docker exec vaultwarden cat /root/.config/rclone/rclone.conf
docker exec vaultwarden rclone --config /root/.config/rclone/rclone.conf \
  lsf s3backup:$BACKUP_S3_BUCKET/
```

## Restoring a backup

```bash
# 1. Download the desired archive
rclone copy s3backup:BUCKET/PREFIX/vaultwarden-20260721T120000Z.tar.gz.age .

# 2. Decrypt with your PRIVATE key and extract
age -d -i key.txt vaultwarden-20260721T120000Z.tar.gz.age | tar -xzf - -C /restore/target

# 3. Stop vaultwarden, replace /data with the restored contents, start again
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `... backups are DISABLED` at startup | one of the required `BACKUP_*` vars is missing |
| No backup after an hour | check the schedule; run `vw-backup.sh` manually to see errors |
| `upload failed` | wrong endpoint/credentials/bucket, or provider needs path-style — try `BACKUP_S3_PROVIDER=Other` |
| `age encryption failed` | `BACKUP_AGE_KEY` is not a valid public `age1...` recipient |

---

## Build & run without Compose

```bash
docker build -t custom-vaultwarden:latest .
docker run -d --name vaultwarden -p 8080:80 \
  -v vw-data:/data \
  -e BACKUP_AGE_KEY=age1... \
  -e BACKUP_S3_ENDPOINT=https://s3.us-east-1.amazonaws.com \
  -e BACKUP_S3_BUCKET=my-vaultwarden-backups \
  -e BACKUP_S3_ACCESS_KEY_ID=AKIA... \
  -e BACKUP_S3_SECRET_ACCESS_KEY=... \
  custom-vaultwarden:latest
```

## Kubernetes

See [`k8s/deployment.yaml`](k8s/deployment.yaml). Secrets/config are injected via
`Secret` + `ConfigMap`, and backup logs appear in `kubectl logs deploy/vaultwarden`.
Because a single writer owns the `/data` PVC, keep one replica (the manifest uses
`strategy: Recreate`).
