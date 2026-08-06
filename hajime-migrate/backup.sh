#!/usr/bin/env bash
# =============================================================================
# Hajime OS — CarbonFlow backup
#
# Runs from the workstation, not the server, so the archive lands off-machine
# by construction. The server's own disk is about to be wiped; a backup stored
# on it protects nothing.
#
# Backs up what cannot be recreated. Docker layers, pulled images and Ollama
# models are deliberately skipped: they are re-fetchable, and a raw copy of a
# live Docker directory is not a consistent snapshot anyway. Image references
# are recorded instead so the stack can be rebuilt.
#
# Usage:
#   ./backup.sh /path/to/destination
#   HOST=192.168.100.59 KEY=~/.ssh/carbonflow_key ./backup.sh /d/backups
#
# Exit codes: 0 verified, 1 usage error, 2 backup failed, 3 verification failed.
# =============================================================================

set -uo pipefail

HOST="${HOST:-192.168.100.59}"
USER="${SSH_USER:-root}"
KEY="${KEY:-$HOME/.ssh/carbonflow_key}"
# Where the archive is assembled on the server before it is pulled across.
#
# /tmp is the obvious choice and the wrong one on this host: it is a 1 GB tmpfs,
# which means staging half a gigabyte there spends the machine's memory, and
# this machine was already 4 GB into swap when it was first surveyed. The check
# below measures the filesystem rather than trusting the default.
#
#   STAGE_ROOT=/vault/stage ./backup.sh /d/backups
STAGE_ROOT="${STAGE_ROOT:-/tmp}"
STAGE="$STAGE_ROOT/hajime_backup_$$"

DEST="${1:-}"
if [ -z "$DEST" ]; then
    echo "usage: $0 <destination-directory>" >&2
    echo "the destination must NOT be on the server being backed up" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/carbonflow-$STAMP"
LOG="$OUT/backup.log"

ssh_do() {
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$USER@$HOST" "$@"
}

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
}

fail() {
    log "FAILED: $*"
    log "The backup is INCOMPLETE. Do not proceed with any migration step."
    exit 2
}

# --- preflight -------------------------------------------------------------
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }
: > "$LOG"

log "destination: $OUT"
log "server:      $USER@$HOST"

ssh_do 'echo ok' >/dev/null 2>&1 || fail "cannot reach $HOST over SSH"
log "ssh reachable"

# Refuse to stage into a directory the wipe would destroy.
case "$DEST" in
    /vault/*|/opt/*)
        fail "destination '$DEST' looks like a path on the server being wiped"
        ;;
esac

AVAIL_KB=$(df -Pk "$DEST" | awk 'NR==2 {print $4}')
if [ "${AVAIL_KB:-0}" -lt 5242880 ]; then
    fail "destination has less than 5 GB free (${AVAIL_KB} KB)"
fi
log "free space at destination: $((AVAIL_KB / 1024)) MB"

ssh_do "mkdir -p $STAGE/db $STAGE/configs $STAGE/volumes $STAGE/appdata" \
    || fail "cannot create staging directory on server"

# The staging filesystem has to hold the whole archive before any of it moves.
# Running out halfway leaves a partial tar for the checksum step to fail on,
# after an hour of work, on a machine that may have filled its root disk on the
# way there.
STAGE_KB=$(ssh_do "df -Pk '$STAGE' | awk 'NR==2 {print \$4}'")
if [ "${STAGE_KB:-0}" -lt 2097152 ]; then
    fail "the staging filesystem at ${STAGE_ROOT} has $((STAGE_KB / 1024)) MB free.
       That is not enough to assemble the archive, and on this host /tmp is a
       1 GB tmpfs, so filling it spends memory rather than disk.
       Point it at real storage:  STAGE_ROOT=/vault/hajime_stage $0 $DEST"
fi
log "staging at $STAGE ($((STAGE_KB / 1024)) MB free)"

# --- 1. databases ----------------------------------------------------------
# Logical dumps, taken through each engine's own tool. Copying data files from
# a running database gives a torn snapshot.
log "--- databases ---"

# Credentials are read from each container's own environment at run time, so no
# secret is written into this script or into the shell history.
dump_mariadb() {
    container="$1"; target="$2"
    log "mariadb: $container"
    ssh_do "docker exec $container sh -c 'mariadb-dump -u root \
        -p\"\$MARIADB_ROOT_PASSWORD\" --all-databases --single-transaction \
        --quick --routines --events' > $STAGE/db/$target" \
        || fail "mariadb dump failed for $container"
    size=$(ssh_do "wc -c < $STAGE/db/$target")
    [ "$size" -gt 1024 ] || fail "$target is only ${size} bytes, refusing to trust it"
    log "  ${size} bytes"
}

# A container that is gone is not a failure; a container that is there and will
# not dump is. The stack has shrunk since this script was written -- the whole
# Postiz group was retired -- and without that distinction one absent container
# aborted the entire backup before it reached the volumes, the secrets or /opt.
# The data those containers held is still inside the volume archive either way.
# Running, not merely present. `docker inspect` succeeds for a stopped
# container, so the first version of this check waved postiz-postgres through
# and the dump died against a container that exists and is switched off. A
# stopped container's data is in its volume, which the volume archive takes.
present() {
    state=$(ssh_do "docker inspect --format '{{.State.Running}}' '$1' 2>/dev/null")
    [ "$state" = "true" ]
}

for pair in "carbonflow-litecart-db mariadb_litecart.sql" \
            "carbonflow-npm-db mariadb_npm.sql"; do
    # shellcheck disable=SC2086
    set -- $pair
    if present "$1"; then
        dump_mariadb "$1" "$2"
    else
        log "mariadb: $1 is not on this host, skipped"
    fi
done

if present postiz-postgres; then
    log "postgres: postiz-postgres"
    ssh_do "docker exec postiz-postgres sh -c 'pg_dumpall -U \"\$POSTGRES_USER\"' \
            > $STAGE/db/postgresql_all.sql" \
        || fail "pg_dumpall failed"
    PG_SIZE=$(ssh_do "wc -c < $STAGE/db/postgresql_all.sql")
    [ "$PG_SIZE" -gt 1024 ] || fail "postgres dump is only ${PG_SIZE} bytes"
    log "  ${PG_SIZE} bytes"
else
    log "postgres: postiz-postgres is not running on this host, skipped"
    log "  its volume is still captured with the rest of /vault/docker/volumes"
fi

if present postiz-redis; then
    log "redis: postiz-redis"
    ssh_do "docker exec postiz-redis redis-cli --no-auth-warning BGSAVE >/dev/null 2>&1; \
            sleep 3; docker cp postiz-redis:/data/dump.rdb $STAGE/db/redis_postiz.rdb" \
        || log "  WARNING: redis snapshot unavailable (cache only, not fatal)"
else
    log "redis: postiz-redis is not running on this host, skipped"
fi

# n8n keeps workflows in SQLite. Its own exporter yields JSON, which survives an
# engine change and doubles as the import format for hajime-workflow.
if present carbonflow-n8n; then
    log "n8n: workflow and credential export"
    ssh_do "docker exec carbonflow-n8n n8n export:workflow --all \
            --output=/tmp/n8n_workflows.json >/dev/null 2>&1 && \
            docker cp carbonflow-n8n:/tmp/n8n_workflows.json $STAGE/db/" \
        || fail "n8n workflow export failed"
    ssh_do "docker exec carbonflow-n8n n8n export:credentials --all --decrypted \
            --output=/tmp/n8n_credentials.json >/dev/null 2>&1 && \
            docker cp carbonflow-n8n:/tmp/n8n_credentials.json $STAGE/db/ && \
            docker exec carbonflow-n8n rm -f /tmp/n8n_credentials.json" \
        || log "  WARNING: credential export failed, re-enter credentials by hand"
    # The raw SQLite file as a second line of defence.
    ssh_do "docker cp carbonflow-n8n:/home/node/.n8n/database.sqlite \
            $STAGE/db/n8n_database.sqlite" \
        || log "  WARNING: raw n8n sqlite copy failed"
    log "  n8n exported"
else
    log "n8n: carbonflow-n8n is not on this host, skipped"
fi

if present carbonflow-uptime-kuma; then
    log "uptime-kuma: sqlite"
    ssh_do "docker cp carbonflow-uptime-kuma:/app/data/kuma.db \
            $STAGE/db/uptime_kuma.db 2>/dev/null" \
        || log "  WARNING: uptime-kuma database not captured"
else
    log "uptime-kuma: not on this host, skipped"
fi

# --- 2. configuration and secrets -----------------------------------------
# The part the previous backup left empty. None of this is recreatable.
log "--- configuration and secrets ---"

ssh_do "tar czf $STAGE/configs/opt.tar.gz \
        --exclude='*/docker-images' --exclude='*/ollama-models' \
        --exclude='*/final-sweep-*' --exclude='*/apks' \
        -C / opt 2>/dev/null" \
    || fail "could not archive /opt"
log "  /opt archived (compose files, .env, service definitions)"

ssh_do "tar czf $STAGE/configs/vault_secrets.tar.gz -C /vault \
        secrets credentials cloudflare 2>/dev/null" \
    || fail "could not archive vault secrets"
log "  /vault secrets, credentials and cloudflare captured"

# Container topology: ports, mounts, networks and environment. Enough to
# reconstruct the stack even without the compose files.
ssh_do "docker ps -a --format '{{.Names}}' | while read -r c; do \
          docker inspect \"\$c\"; done > $STAGE/configs/docker_inspect.json" \
    || log "  WARNING: docker inspect capture incomplete"
ssh_do "docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' > $STAGE/configs/docker_images.txt"
ssh_do "docker volume ls -q > $STAGE/configs/docker_volumes.txt"
ssh_do "crontab -l > $STAGE/configs/root_crontab.txt 2>/dev/null; \
        cp -r /etc/periodic $STAGE/configs/ 2>/dev/null; true"
ssh_do "rc-status -a > $STAGE/configs/services.txt 2>/dev/null; true"
log "  container topology, images, volumes and schedules recorded"

# --- 3. docker volumes -----------------------------------------------------
log "--- docker named volumes ---"
ssh_do "tar czf $STAGE/volumes/docker_volumes.tar.gz -C /vault/docker volumes 2>/dev/null" \
    || fail "could not archive docker volumes"
log "  volumes archived"

# --- 4. application data ---------------------------------------------------
# Small, irreplaceable directories. /vault/docker and /vault/ollama are skipped
# on purpose, and /vault/hajime_backups is skipped to avoid nesting backups.
log "--- application data ---"
ssh_do "tar czf $STAGE/appdata/vault_data.tar.gz -C /vault \
        --exclude=docker --exclude=ollama --exclude=hajime_backups \
        --exclude=lost+found --exclude=backups . 2>/dev/null" \
    || fail "could not archive vault application data"
log "  /vault application data archived"

# --- 5. manifest and checksums --------------------------------------------
log "--- manifest ---"
ssh_do "cd $STAGE && find . -type f -exec sha256sum {} \; > /tmp/hajime_sha_$$.txt \
        && mv /tmp/hajime_sha_$$.txt $STAGE/SHA256SUMS" \
    || fail "could not compute checksums on server"

ssh_do "cat > $STAGE/MANIFEST.txt <<EOF
Hajime OS backup manifest
taken        : $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC
source host  : \$(hostname)
kernel       : \$(uname -r)
containers   : \$(docker ps -q | wc -l) running, \$(docker ps -aq | wc -l) total

Deliberately excluded (recreatable, not lost):
  /vault/docker          docker layers and images, re-pullable
  /vault/ollama          model weights, re-downloadable
  /opt/*/docker-images   exported image tarballs
  /opt/*/ollama-models   model weights
  /vault/hajime_backups  previous backup, not nested

Restore order: databases, then configs, then volumes, then application data.
EOF"

# --- 6. transfer off-machine ----------------------------------------------
log "--- transferring to $OUT ---"
scp -i "$KEY" -o BatchMode=yes -r "$USER@$HOST:$STAGE/." "$OUT/" >>"$LOG" 2>&1 \
    || fail "transfer to destination failed"
log "transfer complete"

ssh_do "rm -rf $STAGE"
log "server staging directory removed"

# --- 7. verification -------------------------------------------------------
# A backup nobody has verified is a rumour. Checksums are recomputed locally
# against the manifest written on the server.
log "--- verification ---"
cd "$OUT" || fail "cannot enter $OUT"

VERIFY_FAILED=0
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >"$OUT/verify.log" 2>&1 || VERIFY_FAILED=1
    # grep -c always prints a count and exits 1 when it is zero. Adding a
    # `|| echo 0` here would emit a second line and break the integer test,
    # which would silently swallow a real checksum mismatch.
    BAD=$(grep -c 'FAILED' "$OUT/verify.log" 2>/dev/null)
    BAD=${BAD:-0}
else
    log "WARNING: sha256sum unavailable locally, checksums not verified"
    BAD=0
fi

# What must be here is what was attempted, not what the stack looked like when
# this script was written. A dump skipped because its container is switched off
# is not a missing file; demanding it anyway fails a backup that is complete and
# tells the operator not to trust 251 MB of good data.
REQUIRED="configs/opt.tar.gz configs/vault_secrets.tar.gz \
          volumes/docker_volumes.tar.gz appdata/vault_data.tar.gz"
for item in "carbonflow-litecart-db db/mariadb_litecart.sql" \
            "carbonflow-npm-db db/mariadb_npm.sql" \
            "postiz-postgres db/postgresql_all.sql" \
            "carbonflow-n8n db/n8n_workflows.json"; do
    # shellcheck disable=SC2086
    set -- $item
    if present "$1"; then
        REQUIRED="$REQUIRED $2"
    else
        log "not required: $2 (its container is not running)"
    fi
done

# shellcheck disable=SC2086
for required in $REQUIRED; do
    if [ ! -s "$OUT/$required" ]; then
        log "MISSING or EMPTY: $required"
        VERIFY_FAILED=1
    fi
done

# --force-local matters on Windows: without it GNU tar reads a leading "C:" as
# a remote host specification and fails on a perfectly good archive.
for archive in configs/opt.tar.gz configs/vault_secrets.tar.gz \
               volumes/docker_volumes.tar.gz appdata/vault_data.tar.gz; do
    if [ -s "$OUT/$archive" ]; then
        tar --force-local -tzf "$OUT/$archive" >/dev/null 2>&1 \
            || { log "CORRUPT ARCHIVE: $archive"; VERIFY_FAILED=1; }
    else
        log "MISSING or EMPTY ARCHIVE: $archive"
        VERIFY_FAILED=1
    fi
done

TOTAL=$(du -sh "$OUT" 2>/dev/null | cut -f1)
log "backup size: $TOTAL"

if [ "$VERIFY_FAILED" -ne 0 ] || [ "${BAD:-0}" -ne 0 ]; then
    log "VERIFICATION FAILED. This backup is NOT usable. Do not wipe anything."
    exit 3
fi

log "verification passed: checksums match, archives readable, required files present"
log ""
log "Next step is a restore rehearsal on a throwaway VM."
log "An unrehearsed backup is still an assumption."
exit 0
