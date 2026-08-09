#!/bin/sh
# =============================================================================
# Hajime OS data restore.
#
# Reads a backup produced by backup.sh and loads it into the native FreeBSD
# services. The layout it expects is the one backup.sh writes; nothing is
# guessed.
#
# The script it replaces ended every restore command with `|| true` and then
# printed "0 Data Loss". That is the worst failure mode available to a restore
# tool: it cannot tell you the databases are empty, so you find out later, with
# the source machine already wiped. This one verifies checksums before touching
# anything, stops on the first failure it cannot explain, and reports what did
# not land.
#
# Usage:  sh restore_data.sh <backup-dir> [--dry-run] [--force]
#
#   --force    overwrite databases that already have data in them
#
# Exit:   0 everything restored, 1 something did not, 2 not root
# =============================================================================

set -u

DRY=0
FORCE=0
SRC=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "unknown option: $arg" >&2; exit 1 ;;
        *)         SRC="$arg" ;;
    esac
done

HAJIME_USER=hajime
HAJIME_DATA=/vault/hajime
STAGING=/vault/restore-staging
LOG=/var/log/hajime-restore.log

FAILED=""
SKIPPED=""

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
warn() { printf '   warn  %s\n' "$*"; }
bad()  { printf '   FAIL  %s\n' "$*"; FAILED="${FAILED}\n     - $*"; }
skip() { printf '   skip  %s\n' "$*"; SKIPPED="${SKIPPED}\n     - $*"; }
die()  { printf '\n   REFUSED: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY" -eq 1 ]; then
        printf '   would  %s\n' "$*"
        return 0
    fi
    "$@" >>"$LOG" 2>&1
}

[ "$(id -u)" -eq 0 ] || { echo "run as root: this writes to the databases" >&2; exit 2; }
[ -n "$SRC" ] || die "give the backup directory: sh restore_data.sh /vault/hajime_backups/2026-08-03"
[ -d "$SRC" ] || die "$SRC is not a directory"

SRC=$(cd "$SRC" && pwd)
say "Hajime OS restore"
say "from: ${SRC}"
[ "$DRY" -eq 1 ] && say "dry run: nothing will be written"
[ "$DRY" -eq 0 ] && : >"$LOG"

if [ -f "$SRC/MANIFEST.txt" ]; then
    say ""
    sed 's/^/   | /' "$SRC/MANIFEST.txt" | head -8
fi

# --- 1. is this backup intact ----------------------------------------------
# Before anything is written. A restore from a truncated dump is worse than no
# restore, because it looks like it worked.
step "verifying the backup"

[ -f "$SRC/SHA256SUMS" ] || die "no SHA256SUMS in ${SRC}. This is not a backup \
this script can trust; restore it by hand if you accept that."

if command -v sha256sum >/dev/null 2>&1; then
    SUMCMD="sha256sum -c --quiet"
elif command -v shasum >/dev/null 2>&1; then
    SUMCMD="shasum -a 256 -c --quiet"
else
    die "neither sha256sum nor shasum is installed; cannot verify the backup"
fi

if ( cd "$SRC" && $SUMCMD SHA256SUMS >"$LOG.verify" 2>&1 ); then
    FILES=$(wc -l < "$SRC/SHA256SUMS" | tr -d ' ')
    ok "${FILES} files, all checksums match"
else
    say ""
    say "   These files do not match their checksums:"
    grep -v ': OK$' "$LOG.verify" 2>/dev/null | sed 's/^/     /' | head -20
    die "the backup is damaged. Take it again rather than restore half of it."
fi

# --- 2. a way back ---------------------------------------------------------
step "rollback point"

if [ "$DRY" -eq 1 ]; then
    say "   would  snapshot the pool before writing"
elif command -v zfs >/dev/null 2>&1 && zpool list -H -o name 2>/dev/null | grep -q .; then
    POOL=$(zpool list -H -o name | head -1)
    SNAP="${POOL}@hajime-prerestore-$(date +%Y%m%d-%H%M%S)"
    if zfs snapshot -r "$SNAP" >>"$LOG" 2>&1; then
        ok "$SNAP"
        say "         to undo this restore:  zfs rollback -r ${SNAP}"
    else
        warn "could not snapshot; the restore is not undoable"
    fi
else
    warn "no ZFS pool; the restore is not undoable"
fi

# --- 3. postgres -----------------------------------------------------------
# pg_dumpall output is a script of CREATE ROLE and CREATE DATABASE statements,
# so it runs against an empty cluster as the superuser.
step "postgresql"

PG_DUMP="$SRC/db/postgresql_all.sql"
if [ ! -f "$PG_DUMP" ]; then
    skip "postgresql: no dump in the backup"
# Checked in a dry run too. It was not, and the rehearsal on a machine where
# postgresql had never been installed printed a plan that claimed the restore
# would succeed. A dry run that hides the blocker is worse than no dry run: it
# counts the blocker and keeps going, which is the whole point of the flag.
elif ! service postgresql onestatus >/dev/null 2>&1; then
    bad "postgresql: the server is not running (service postgresql start)"
else
    EXISTING=0
    if [ "$DRY" -eq 0 ]; then
        EXISTING=$(su -m postgres -c "psql -tAc \
            \"SELECT count(*) FROM pg_database WHERE datname NOT IN \
            ('postgres','template0','template1')\"" 2>/dev/null || echo 0)
    fi
    if [ "${EXISTING:-0}" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
        bad "postgresql: ${EXISTING} database(s) already exist. Pass --force to \
overwrite them, or drop them first."
    else
        SIZE=$(wc -c < "$PG_DUMP" | tr -d ' ')
        say "   loading ${SIZE} bytes"
        # ON_ERROR_STOP: without it psql reports success after skipping every
        # failed statement, which is how a restore silently produces an empty
        # database.
        if run su -m postgres -c \
             "psql -v ON_ERROR_STOP=1 --quiet -f '$PG_DUMP' postgres"; then
            if [ "$DRY" -eq 0 ]; then
                N=$(su -m postgres -c "psql -tAc \
                    \"SELECT count(*) FROM pg_database WHERE datname NOT IN \
                    ('postgres','template0','template1')\"" 2>/dev/null || echo 0)
                ok "postgresql: ${N} database(s) restored"
            else
                ok "postgresql"
            fi
        else
            bad "postgresql: the load failed; see ${LOG}"
        fi
    fi
fi

# --- 4. mariadb ------------------------------------------------------------
step "mariadb"

restore_mariadb() {
    label="$1"; dump="$2"
    if [ ! -f "$dump" ]; then
        skip "mariadb ${label}: no dump in the backup"
        return
    fi
    # Same as postgresql above: the dry run skipped this and reported both
    # databases as restored against a machine with no mariadb installed.
    if ! service mysql-server onestatus >/dev/null 2>&1; then
        bad "mariadb ${label}: the server is not running (service mysql-server start)"
        return
    fi
    SIZE=$(wc -c < "$dump" | tr -d ' ')
    say "   ${label}: loading ${SIZE} bytes"
    # The dump came from --all-databases, so it carries its own CREATE DATABASE
    # and USE statements. No socket password: a fresh FreeBSD mariadb lets root
    # in over the unix socket, and the old root password belonged to a container
    # that no longer exists.
    if run sh -c "mariadb -u root --batch < '$dump'"; then
        ok "mariadb ${label} restored"
    else
        bad "mariadb ${label}: the load failed; see ${LOG}"
    fi
}

restore_mariadb litecart "$SRC/db/mariadb_litecart.sql"
restore_mariadb npm      "$SRC/db/mariadb_npm.sql"

# --- 5. redis --------------------------------------------------------------
# Redis here held Postiz's queue and cache. Losing it costs pending jobs, not
# data, so a missing snapshot is a note rather than a failure.
step "redis"

RDB="$SRC/db/redis_postiz.rdb"
if [ ! -f "$RDB" ]; then
    skip "redis: no snapshot in the backup (it held cache only)"
else
    RDB_DIR=$(sysrc -n redis_dir 2>/dev/null || echo /var/db/redis)
    if [ "$DRY" -eq 0 ] && service redis onestatus >/dev/null 2>&1; then
        # Loading a dump.rdb under a running server does nothing: it reads the
        # file at startup and would overwrite it on the way out.
        run service redis stop
    fi
    if run install -o redis -g redis -m 660 "$RDB" "$RDB_DIR/dump.rdb"; then
        ok "redis snapshot placed in ${RDB_DIR}"
        run service redis start
    else
        bad "redis: could not place the snapshot in ${RDB_DIR}"
    fi
fi

# --- 6. workflows ----------------------------------------------------------
# The point of the whole rewrite: hajime-workflow reads n8n's own export format,
# so the workflows move across without being re-drawn.
step "workflows"

WF="$SRC/db/n8n_workflows.json"
if [ ! -f "$WF" ]; then
    bad "no n8n_workflows.json in the backup; the automations would be lost"
elif ! pw usershow "$HAJIME_USER" >/dev/null 2>&1; then
    # install(1) says "unknown group hajime" and nothing else, which reads like
    # a bug in this script rather than a step that was never run. The account is
    # created by install_hajime_os.sh; the rehearsal skipped that and spent a
    # while working out why the workflows would not install.
    bad "no ${HAJIME_USER} account on this machine; run install_hajime_os.sh first"
else
    run install -d -o "$HAJIME_USER" -g "$HAJIME_USER" -m 750 "$HAJIME_DATA"
    if run install -o "$HAJIME_USER" -g "$HAJIME_USER" -m 640 "$WF" \
            "$HAJIME_DATA/workflows.json"; then
        if [ "$DRY" -eq 0 ] && command -v hajime-workflow >/dev/null 2>&1; then
            # Parse them with the engine that will run them. A workflow that
            # loads today and fails to parse at the next boot is a workflow that
            # was never really restored.
            if HAJIME_WORKFLOWS="$HAJIME_DATA/workflows.json" \
               hajime-workflow --validate >"$LOG.workflows" 2>&1; then
                sed 's/^/   /' "$LOG.workflows"
                ok "workflows.json installed and parsed by the engine"
            else
                sed 's/^/   /' "$LOG.workflows"
                # Either the file will not parse, or a schedule will never
                # fire. Both mean automations that look restored and are not.
                bad "hajime-workflow rejected the restored workflows (above)"
            fi
        else
            ok "workflows.json installed"
        fi
    else
        bad "could not install workflows.json"
    fi
fi

# n8n's credentials export is decrypted plaintext. It goes in root-only and is
# meant to be read once, moved into the secret store, and deleted.
CRED="$SRC/db/n8n_credentials.json"
if [ -f "$CRED" ]; then
    if run install -o root -g wheel -m 600 "$CRED" "/root/n8n_credentials.json"; then
        ok "credentials placed at /root/n8n_credentials.json (mode 600)"
        warn "that file is decrypted plaintext. Move what you need into \
/usr/local/etc/hajime and delete it."
    else
        bad "could not place the credentials export"
    fi
else
    skip "no credential export; re-enter API keys by hand"
fi

# --- 7. secrets ------------------------------------------------------------
step "secrets"

VS="$SRC/configs/vault_secrets.tar.gz"
if [ ! -f "$VS" ]; then
    bad "no vault_secrets.tar.gz; the OAuth tokens and Cloudflare credentials \
are not in this backup"
else
    run install -d -o root -g wheel -m 700 /vault/secrets
    # 077 so nothing inside the archive lands group- or world-readable, whatever
    # mode it was stored with.
    if run sh -c "umask 077; tar xzf '$VS' -C /vault"; then
        ok "secrets, credentials and cloudflare config extracted to /vault"
        run chmod -R go-rwx /vault/secrets /vault/credentials /vault/cloudflare
        ok "tightened to owner-only"
    else
        bad "could not extract ${VS}"
    fi
fi

# --- 8. application data ---------------------------------------------------
step "application data"

AD="$SRC/appdata/vault_data.tar.gz"
if [ ! -f "$AD" ]; then
    skip "no vault_data.tar.gz in the backup"
elif run sh -c "tar xzf '$AD' -C /vault"; then
    ok "site files and media restored under /vault"
else
    bad "could not extract ${AD}"
fi

# --- 9. what does not restore automatically --------------------------------
# The docker volumes and the compose files describe a stack that no longer
# exists. Extracting them somewhere and calling it a restore would be a lie, so
# they are staged for reading and left alone.
step "staged for you, not restored"

run install -d -o root -g wheel -m 700 "$STAGING"

for a in "$SRC/volumes/docker_volumes.tar.gz" "$SRC/configs/opt.tar.gz"; do
    [ -f "$a" ] || continue
    name=$(basename "$a" .tar.gz)
    if run sh -c "tar xzf '$a' -C '$STAGING'"; then
        ok "${name} extracted to ${STAGING}/"
    else
        bad "could not extract ${name}"
    fi
done

for f in docker_inspect.json docker_images.txt docker_volumes.txt \
         root_crontab.txt services.txt; do
    [ -f "$SRC/configs/$f" ] || continue
    run install -o root -g wheel -m 600 "$SRC/configs/$f" "$STAGING/$f"
done
ok "container topology and schedules copied to ${STAGING}/"

for db in n8n_database.sqlite uptime_kuma.db; do
    [ -f "$SRC/db/$db" ] || continue
    run install -o root -g wheel -m 600 "$SRC/db/$db" "$STAGING/$db"
    ok "${db} kept in ${STAGING}/ as a second copy"
done

say ""
say "   Those describe the Docker stack this system replaces. Nothing reads"
say "   them automatically; they are there so you can look up a setting the"
say "   old machine had and this one does not."

# --- 10. verdict -----------------------------------------------------------
step "result"

if [ "$DRY" -eq 1 ]; then
    say "   dry run complete; nothing was written"
    exit 0
fi

if [ -n "$SKIPPED" ]; then
    say ""
    say "   Not present in the backup:"
    printf '%b\n' "$SKIPPED"
fi

if [ -n "$FAILED" ]; then
    say ""
    say "   These did not restore:"
    printf '%b\n' "$FAILED"
    say ""
    say "   The rest did. Fix these before you decommission the source machine,"
    say "   and keep the backup until you have."
    say "   Full log: ${LOG}"
    exit 1
fi

say "   Everything in the backup was restored and verified."
say ""
say "   Check it yourself before trusting it:"
say ""
say "     hajimectl check"
say "     psql -U postgres -l"
say "     mariadb -u root -e 'show databases'"
say ""
say "   Keep ${SRC} until the new machine has served real traffic for a week."
exit 0
