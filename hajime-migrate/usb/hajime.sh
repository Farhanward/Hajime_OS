#!/bin/sh
# =============================================================================
# Type this and walk away.
#
#   mount -t msdosfs /dev/da0s1 /mnt && sh /mnt/hajime.sh
#
# It installs FreeBSD 14.4 on ZFS, names the machine, gives it the old
# server's address, enables sshd and installs the key -- so that when it
# reboots you can leave the room and finish the rest over the network.
#
# It refuses rather than guesses. Every check below exists because getting it
# wrong means a machine with no console that nobody can reach.
# =============================================================================

set -u

say()  { printf '   %s\n' "$*"; }
die()  { printf '\n   REFUSED: %s\n' "$*" >&2; exit 1; }

HERE=$(dirname "$0")
CFG="${HERE}/installerconfig"

printf '\nHajime: unattended install\n\n'

[ -f "$CFG" ] || die "installerconfig is not next to this script"

# --- is this the machine we wrote this for -----------------------------------
# The script names ada0 and 192.168.100.59. On the wrong machine that is a
# wiped disk and an address collision, so neither is assumed.
[ -e /dev/ada0 ] || die "there is no /dev/ada0 here.
       Disks present: $(sysctl -n kern.disks)
       This script was written for one server with one SATA disk."

SIZE_GB=$(( $(diskinfo ada0 | awk '{print $3}') / 1000000000 ))
say "target: ada0, about ${SIZE_GB} GB"
if [ "$SIZE_GB" -lt 100 ] || [ "$SIZE_GB" -gt 1000 ]; then
    die "ada0 is ${SIZE_GB} GB. The server's disk is about 512 GB.
       Refusing in case this is a different machine."
fi

# re0 is the Realtek the address is configured on. If the kernel called it
# something else, the machine comes up with no network and no console.
if ! ifconfig re0 >/dev/null 2>&1; then
    die "there is no re0 interface.
       Interfaces present: $(ifconfig -l)
       Edit ifconfig_re0 in installerconfig to the right name first."
fi
say "network: re0 present, will come up as 192.168.100.59"

# --- the point of no return --------------------------------------------------
cat <<'WARN'

   Everything on ada0 is about to be erased and replaced with FreeBSD on ZFS.

   Ten seconds. Ctrl-C now if this is not what you meant.

WARN
i=10
while [ "$i" -gt 0 ]; do printf '\r   %2d ' "$i"; sleep 1; i=$((i - 1)); done
printf '\r      \n'

# --- go ----------------------------------------------------------------------
say "installing. This takes a few minutes and prints a lot."
echo
if bsdinstall script "$CFG"; then
    cat <<'DONE'

   Installed.

   Remove the USB stick and reboot:

       reboot

   It comes back as carbonflow-tech on 192.168.100.59 with sshd running and
   the key already in place, so from your workstation:

       ssh -i ~/.ssh/carbonflow_key root@192.168.100.59

   Nothing else needs doing at this keyboard.

DONE
else
    cat <<'FAILED'

   The install did not finish. Nothing here is a guess about why -- read the
   output above, it says.

   The disk may be half-written. Two ways on:

     - run this script again, it starts from a clean pool
     - or type  bsdinstall  and do it by hand, choosing Auto (ZFS) on ada0

FAILED
    exit 1
fi
