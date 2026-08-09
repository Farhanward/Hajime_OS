#!/usr/bin/env bash
# =============================================================================
# Pull a complete, restorable copy of the old server.
#
# backup.sh takes the data: database dumps, secrets, the site trees. That is
# what the new system needs to be filled with. It is not what you need at two
# in the morning when the new system is wrong and the old one has to come back.
#
# This takes the machine: the partition table, the boot sector, the whole root
# filesystem and the whole of /vault, so the old server can be rebuilt on bare
# metal from nothing but this directory and an Alpine boot medium.
#
# Nothing is written to the server. Every command below reads.
#
# Usage:  bash pull_server_image.sh [--host H] [--dest DIR] [--key PATH]
#                                   [--dry-run]
#
# Exit:   0 complete and verified, 1 something did not come across
# =============================================================================

set -u
set -o pipefail

HOST=192.168.100.59
USER=root
KEY="${HOME}/.ssh/carbonflow_key"
DEST_ROOT="/c/hajime-backups"
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --dest) DEST_ROOT="$2"; shift 2 ;;
        --key)  KEY="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
warn() { printf '   warn  %s\n' "$*"; }
bad()  { printf '   FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
die()  { printf '\n   REFUSED: %s\n' "$*" >&2; exit 1; }

FAILED=0
SSH="ssh -i ${KEY} -o BatchMode=yes -o ConnectTimeout=15 ${USER}@${HOST}"

remote() { $SSH "$@"; }

say "Hajime: full image of ${HOST}"
[ "$DRY" -eq 1 ] && say "dry run: nothing will be transferred"

# --- 1. can we reach it, and is it the machine we think ---------------------
step "the server"

[ -f "$KEY" ] || die "no ssh key at ${KEY}"
remote true 2>/dev/null || die "cannot reach ${USER}@${HOST} with ${KEY}"

RELEASE=$(remote 'cat /etc/os-release 2>/dev/null | sed -n "s/^PRETTY_NAME=//p" | tr -d \"')
ok "${RELEASE:-unknown release}"

# Measured, not assumed. The archives are sized from this and the destination
# is checked against it before a single byte moves.
USED_KB=$(remote "df -k --output=used / /vault 2>/dev/null | tail -n +2 | awk '{s+=\$1} END {print s}'")
case "$USED_KB" in
    ''|*[!0-9]*) die "could not measure how much data is on the server" ;;
esac
USED_GB=$((USED_KB / 1024 / 1024))
ok "${USED_GB} GB in use across / and /vault"

# --- 2. is there room for it here -------------------------------------------
step "this machine"

mkdir -p "$DEST_ROOT" || die "cannot create ${DEST_ROOT}"
FREE_KB=$(df -k "$DEST_ROOT" | tail -1 | awk '{print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))

# Compression is not counted on. Model weights and container layers are close
# to incompressible, and a transfer that dies on a full disk at 90% has cost
# more than it saved.
if [ "$FREE_GB" -lt "$((USED_GB + 5))" ]; then
    die "${FREE_GB} GB free at ${DEST_ROOT}; the copy needs at least $((USED_GB + 5)) GB"
fi
ok "${FREE_GB} GB free at ${DEST_ROOT}"

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${DEST_ROOT}/carbonflow-image-${STAMP}"
if [ "$DRY" -eq 0 ]; then
    mkdir -p "$DEST" || die "cannot create ${DEST}"
fi
ok "$DEST"

# --- 3. the small things that make the big things restorable ----------------
# An archive of the filesystem is not a machine. Without the partition table
# the disk has no shape, and without the boot sector it does not start.
step "the shape of the disk"

meta() {
    label="$1"; file="$2"; shift 2
    if [ "$DRY" -eq 1 ]; then
        say "   would  ${file}  <- $*"
        return 0
    fi
    if remote "$@" > "${DEST}/${file}" 2>/dev/null && [ -s "${DEST}/${file}" ]; then
        ok "${file}  (${label})"
    else
        bad "${file}: ${label} could not be read"
    fi
}

meta "partition table"  partition-table.sfdisk 'sfdisk -d /dev/sda'
meta "block devices"    lsblk.txt              'lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT'
meta "mount table"      fstab.txt              'cat /etc/fstab'
meta "filesystem usage" df.txt                 'df -h'
meta "installed packages" apk-world.txt        'cat /etc/apk/world'
meta "package list"     apk-installed.txt      'apk info -v'
meta "kernel and release" release.txt          'uname -a; cat /etc/os-release'
meta "enabled services" rc-status.txt          'rc-status -a 2>&1'
meta "containers"       docker-ps.txt          'docker ps -a --format "{{.Names}}\t{{.Image}}\t{{.Status}}"'
meta "container detail" docker-inspect.json    'docker inspect $(docker ps -aq) 2>/dev/null'
meta "images"           docker-images.txt      'docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}"'
meta "volumes"          docker-volumes.txt     'docker volume ls'
meta "crontab"          root-crontab.txt       'crontab -l 2>&1'
meta "network"          network.txt            'ip addr; ip route'

# The first mebibyte carries the MBR, the partition table and the gap where the
# bootloader's second stage lives. Alpine on BIOS puts syslinux there, and a
# root filesystem restored without it produces a disk that will not boot.
if [ "$DRY" -eq 1 ]; then
    say "   would  mbr-1MiB.img  <- dd first mebibyte of /dev/sda"
elif remote 'dd if=/dev/sda bs=1M count=1 2>/dev/null' > "${DEST}/mbr-1MiB.img" \
     && [ -s "${DEST}/mbr-1MiB.img" ]; then
    ok "mbr-1MiB.img  (boot sector and the bootloader gap)"
else
    bad "mbr-1MiB.img: the boot sector could not be read"
fi

# --- 4. the filesystems ------------------------------------------------------
# Split rather than one stream. Forty gigabytes that fail at the last one are
# forty gigabytes to pull again; this way a failure costs one archive.
#
# gzip -1 rather than -9: the server is in production, gzip is single-threaded,
# and the difference on container layers and model weights is a few percent for
# several times the CPU.
step "the filesystems"

pull() {
    name="$1"; dir="$2"; shift 2
    out="${DEST}/${name}.tar.gz"
    excl=""
    for e in "$@"; do excl="${excl} --exclude=${e}"; done

    if [ "$DRY" -eq 1 ]; then
        # The command as it will actually run, not a description of it.
        say "   would  ${name}.tar.gz  <- nice -n 19 tar -C ${dir} -c${excl} . | gzip -1"
        return 0
    fi

    say "   ${name}: reading ${dir} ..."
    start=$(date +%s)
    # nice on the far end: this runs against a machine serving live sites.
    if ! remote "nice -n 19 tar -C ${dir} -c${excl} . 2>/dev/null | gzip -1" > "$out"; then
        bad "${name}: the transfer failed"
        return 1
    fi
    elapsed=$(( $(date +%s) - start ))
    size=$(du -m "$out" | awk '{print $1}')

    # gzip stores a CRC32 and the uncompressed length of the whole stream, so
    # this catches a truncated or corrupted transfer. It is the check that
    # matters: an archive that lists is an archive that restores.
    if gzip -t "$out" 2>/dev/null; then
        ok "${name}.tar.gz  ${size} MB in ${elapsed}s, gzip integrity ok"
    else
        bad "${name}.tar.gz is truncated or corrupt"
        return 1
    fi
}

pull rootfs / ./proc ./sys ./dev ./run ./tmp ./mnt ./media ./vault ./lost+found
pull vault-data /vault ./docker ./lost+found
pull vault-docker /vault/docker ./lost+found

# --- 5. what it is and how to put it back ------------------------------------
step "the manifest"

if [ "$DRY" -eq 0 ]; then
    {
        echo "Hajime full server image"
        echo "taken:    $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "from:     ${USER}@${HOST}"
        echo "release:  ${RELEASE}"
        echo "in use:   ${USED_GB} GB across / and /vault"
        echo
        echo "The server was running while this was taken. The archives are"
        echo "crash-consistent: the same state a power cut would leave. Alpine"
        echo "and the container filesystems recover from that. The databases"
        echo "inside the containers are covered separately and consistently by"
        echo "backup.sh, which dumps them through their own tools."
        echo
        echo "contents:"
        ls -lh "$DEST" | tail -n +2 | awk '{printf "  %-28s %s\n", $9, $5}'
    } > "${DEST}/MANIFEST.txt"
    ok "MANIFEST.txt"

    ( cd "$DEST" && sha256sum ./* > SHA256SUMS 2>/dev/null )
    ok "SHA256SUMS"
fi

# --- 6. verdict ---------------------------------------------------------------
step "result"

if [ "$DRY" -eq 1 ]; then
    say "   dry run finished; nothing was transferred"
    exit 0
fi

TOTAL=$(du -sh "$DEST" | awk '{print $1}')
if [ "$FAILED" -eq 0 ]; then
    say "   the image is complete: ${TOTAL} at ${DEST}"
    say "   restoring it: see hajime-migrate/RESTORE_OLD_SERVER.md"
    exit 0
fi

say "   ${FAILED} item(s) did not come across. This image is not complete."
say "   at: ${DEST}"
exit 1
