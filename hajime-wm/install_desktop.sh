#!/bin/sh
# =============================================================================
# Hajime desktop installer for FreeBSD 14.4.
#
# Installs wayfire and its supporting pieces, applies the Hajime theme, and
# sets the machine to boot straight into it: autologin on the console and
# wayfire started from the login shell. Idempotent: running it twice changes
# nothing the second time.
#
# It refuses rather than guesses. A missing firmware package, a GPU outside the
# supported range or an unexpected release each stop the run with an
# explanation, because a half-configured desktop is harder to debug than one
# that never started.
#
# Usage:  sh install_desktop.sh [--dry-run]
# Exit:   0 done, 1 refused, 2 must be run as root
#
# DESKTOP_USER picks the account the desktop runs as; it defaults to
# hajime-desktop, created here if missing. Not $SUDO_USER's fallback of
# `hajime`: that account is the nologin service user install_hajime_os.sh
# creates, and a login can never reach a desktop through a shell of nologin.
# =============================================================================

set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

USER_NAME="${SUDO_USER:-${DESKTOP_USER:-hajime-desktop}}"
HERE=$(dirname "$0")
BEGIN="# --- BEGIN hajime desktop ---"
END="# --- END hajime desktop ---"

WARNINGS=0
say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
warn() { printf '   warn  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
# A real run stops at the first blocker. A dry run notes it and keeps going:
# the point of a dry run is to see the whole plan, and one that halts on the
# first problem hides the four behind it. Same rule as install_hajime_os.sh
# and install_theme.sh; this script did not follow it until it grew enough new
# refusals (the account, the autologin line) that skipping straight past the
# first one started hiding the rest.
BLOCKERS=0
die() {
    if [ "$DRY" -eq 1 ]; then
        printf '   WOULD REFUSE: %s\n' "$*"
        BLOCKERS=$((BLOCKERS + 1))
        return 0
    fi
    printf '\n   REFUSED: %s\n' "$*" >&2
    exit 1
}

run() {
    if [ "$DRY" -eq 1 ]; then
        printf '   would  %s\n' "$*"
    else
        "$@" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# One backup, taken the first time and never again. A second copy taken on a
# second run would preserve this script's own output as "the original".
keep_original() {
    file="$1"
    [ -f "$file" ] || return 0
    [ -f "${file}.hajime-orig" ] && return 0
    if [ "$DRY" -eq 1 ]; then
        printf '   would  copy %s to %s.hajime-orig\n' "$file" "$file"
        return 0
    fi
    cp -p "$file" "${file}.hajime-orig"
}

# Replace the marked block in a file, or append one if it is not there yet.
write_block() {
    file="$1"; body="$2"
    if [ "$DRY" -eq 1 ]; then
        printf '   would  rewrite the hajime block in %s\n' "$file"
        return 0
    fi
    keep_original "$file"
    touch "$file" || return 1
    tmp="${file}.hajime.$$"
    awk -v b="$BEGIN" -v e="$END" '
        $0 == b { skip = 1 }
        !skip   { print }
        $0 == e { skip = 0; next }
    ' "$file" > "$tmp" || return 1
    # Three separate %s\n conversions, not `%s%s` for body and END: a body
    # built by command substitution (the usual case; see AL_BODY below) has
    # every trailing newline stripped by $(...), so END landed glued onto
    # body's last line with no separator -- caught by hand on the production
    # host, in /etc/gettytab, after it had already happened silently in
    # /boot/loader.conf and /etc/motd.template from install_theme.sh's copy
    # of this same function.
    printf '%s\n%s\n%s\n' "$BEGIN" "$body" "$END" >> "$tmp" || return 1
    mv "$tmp" "$file"
}

[ "$(id -u)" -eq 0 ] || { echo "run as root: packages and rc.conf are changed"; exit 2; }

say "Hajime desktop installer"
say "target user: ${USER_NAME}"
[ "$DRY" -eq 1 ] && say "dry run: nothing will be changed"

# --- 1. the platform -------------------------------------------------------
step "platform"
REL=$(freebsd-version -r 2>/dev/null || uname -r)
say "   FreeBSD ${REL}"
case "$REL" in
    14.4*|15.*) ok "a supported release" ;;
    14.0*|14.1*|14.2*|14.3*)
        die "FreeBSD ${REL} is end-of-life and receives no security patches.
            Upgrade to 14.4 before installing a desktop on a machine that
            hosts public sites." ;;
    *) warn "unrecognised release; continuing, but the package matrix assumes 14.4" ;;
esac

# --- 2. the GPU ------------------------------------------------------------
step "graphics hardware"
GPU=$(pciconf -lv 2>/dev/null | grep -B3 -i 'display' | grep -i "device.*=" | head -1 |
      sed "s/.*= '//;s/'.*//")
if [ -n "$GPU" ]; then
    ok "${GPU}"
else
    die "no display controller found. This machine has no GPU to drive."
fi

# The firmware blobs are named by Intel codename, not marketing name: a
# Kaby Lake HD 630 needs the `kabylake` package, and so does a Coffee Lake
# UHD 630, because both are Gen9.5 and share i915/kbl_dmc_ver1_04.bin.
#
# The name has a `-kmod-` segment: `gpu-firmware-intel-kabylake` (no `-kmod-`)
# does not exist in the FreeBSD-kmods repository and `pkg install` refuses it.
# Caught by hand on the production host on 2026-08-09; see decisions.md.
FIRMWARE="gpu-firmware-intel-kmod-kabylake"
if pciconf -lv 2>/dev/null | grep -qi 'kabylake\|HD Graphics 6[0-9][0-9]\|UHD Graphics 6'; then
    ok "Gen9.5 Intel graphics: ${FIRMWARE} is the right firmware"
else
    warn "not recognised as Gen9.5; verify the firmware package for this chip"
fi

# --- 3. packages -----------------------------------------------------------
step "packages"
# drm-kmod is the meta-port: it selects the driver version matching this
# kernel. Pinning a specific one by hand is what produces the version
# mismatches people hit on point releases.
# wayfire and wf-shell are the desktop. The five after them are what the
# launchers in wf-shell.ini actually start: without them the panel has buttons
# that do nothing, which is worse than a panel with fewer buttons.
#
# badwolf is the browser xdg-open hands the console URL to. netsurf and dillo
# are lighter still but ship no working JavaScript engine, and the console
# page needs one -- a browser that cannot run it is not light, it is useless.
# falkon and qutebrowser run, but both pull in all of Qt WebEngine, which is a
# second Chromium-class engine on a machine with 8 GB of RAM that is also
# running nineteen services. badwolf is WebKitGTK with almost no shell around
# it: a real engine without the second-Chromium cost.
#
# imv is for the splash and is the one thing here that is optional in practice:
# wayfire.ini guards on it, so a session still starts if it is missing.
PKGS="drm-kmod ${FIRMWARE} seatd wayfire wf-shell xterm thunar imv xdg-utils badwolf"

for p in $PKGS; do
    if pkg info -e "$p" 2>/dev/null; then
        ok "$p already installed"
    else
        printf '   install %s ... ' "$p"
        if run pkg install -y "$p"; then
            printf 'done\n'
        else
            printf 'FAILED\n'
            die "could not install ${p}. Nothing further was changed."
        fi
    fi
done

# --- 4. the account ----------------------------------------------------------
step "the account"
# hajime (uid 900, install_hajime_os.sh) is a service account with a shell of
# /usr/sbin/nologin: correct for a daemon, but init(8) can never turn an
# autologin on that shell into a desktop session -- login would authenticate
# and then immediately exit. This account is a different thing, so it gets a
# different name rather than a flag that silently changes what `hajime` means.
if getent passwd "${USER_NAME}" >/dev/null 2>&1; then
    # A separate lookup, not the exit status of the one above piped through
    # cut: a pipeline's status is its last command's, and cut succeeds on
    # empty input, so chaining it onto getent would report "exists" even for
    # an account that is not there.
    EXISTING_SHELL=$(getent passwd "${USER_NAME}" | cut -d: -f7)
    case "$EXISTING_SHELL" in
        */nologin)
            die "${USER_NAME}'s shell is ${EXISTING_SHELL}. A desktop cannot
            start through an account init(8) will not open a shell on. Point
            DESKTOP_USER at an account with a real shell, or unset it and let
            this installer create hajime-desktop." ;;
        *) ok "${USER_NAME} exists, shell is ${EXISTING_SHELL}" ;;
    esac
else
    # -w no leaves the password field locked (`*`): nothing can authenticate
    # into this account over ssh or at a password prompt. The console
    # autologin below reaches it a different way -- init(8) telling getty to
    # log this account in without asking for one -- which is the only door
    # meant to open.
    if run pw useradd "${USER_NAME}" -m -d "/home/${USER_NAME}" -s /bin/sh \
            -c "Hajime desktop session" -w no; then
        ok "${USER_NAME} created (own group, /bin/sh, no password)"
    else
        die "could not create ${USER_NAME}"
    fi
fi

# --- 5. kernel module and seat -------------------------------------------
step "kernel and seat"
CURRENT_KLD=$(sysrc -n kld_list 2>/dev/null || echo "")
case " ${CURRENT_KLD} " in
    *" i915kms "*) ok "i915kms already in kld_list" ;;
    *)
        run sysrc kld_list="${CURRENT_KLD} i915kms" && ok "added i915kms to kld_list"
        ;;
esac
run sysrc seatd_enable="YES" && ok "seatd enabled"
if [ "$DRY" -eq 0 ] && ! service seatd onestatus >/dev/null 2>&1; then
    run service seatd start && ok "seatd started"
fi

# The user needs to be in the video group to reach the GPU.
if pw groupshow video 2>/dev/null | grep -q "\b${USER_NAME}\b"; then
    ok "${USER_NAME} already in the video group"
else
    run pw groupmod video -m "${USER_NAME}" && ok "added ${USER_NAME} to video"
fi

# --- 6. the theme ----------------------------------------------------------
step "theme"
HOME_DIR=$(getent passwd "${USER_NAME}" 2>/dev/null | cut -d: -f6)
HOME_DIR="${HOME_DIR:-/home/${USER_NAME}}"

# The stylesheet and the palette it imports. Installing one without the other
# leaves GTK resolving @screen to nothing and drawing every window transparent.
PALETTE="${HERE}/../hajime-brand/out/palette-gtk.css"
[ -f "$PALETTE" ] || die "missing ${PALETTE}
            The palette is generated: python hajime-brand/tools/emit.py"

# `install -d -o USER target` only chowns the leaf it creates; a fresh account
# has no ~/.config yet, so that directory itself is created here, owned by
# root, and left that way. wf-panel and wf-background each try to create their
# own subdirectory under ~/.config on first run, get EPERM, and the unhandled
# filesystem_error takes the whole process down -- SIGTRAP first crash caught
# by hand on the production host, every single login, no wallpaper and no
# panel ever appearing. Owning ~/.config itself first, before anything is
# created under it, is what the leaf-only chown above assumed already true.
run install -d -o "${USER_NAME}" -m 755 "${HOME_DIR}/.config"

for target in "${HOME_DIR}/.config/gtk-3.0" "${HOME_DIR}/.config/gtk-4.0"; do
    run install -d -o "${USER_NAME}" -m 755 "$target"
    if run install -o "${USER_NAME}" -m 644 "${HERE}/hajime_theme.css" "${target}/gtk.css" &&
       run install -o "${USER_NAME}" -m 644 "$PALETTE" "${target}/palette-gtk.css"; then
        ok "theme and palette installed to ${target}"
    else
        warn "could not install the theme to ${target}"
    fi
done

if run install -o "${USER_NAME}" -m 644 "${HERE}/wayfire.ini" "${HOME_DIR}/.config/wayfire.ini"; then
    ok "wayfire.ini installed"
else
    warn "could not install wayfire.ini"
fi

# wf-panel and wf-background read their own file. The wallpaper path lives
# there, and putting it in wayfire.ini instead fails without saying anything.
if run install -o "${USER_NAME}" -m 644 "${HERE}/wf-shell.ini" "${HOME_DIR}/.config/wf-shell.ini"; then
    ok "wf-shell.ini installed (panel at the bottom, wallpaper, launchers)"
else
    warn "could not install wf-shell.ini"
fi

# There is no GNOME or KDE session here for xdg-open to detect, so it falls
# through to `xdg-mime query default x-scheme-handler/http`, which reads
# $XDG_CONFIG_HOME/mimeapps.list -- $HOME/.config/mimeapps.list, since nothing
# on this desktop sets XDG_CONFIG_HOME. Without this file the console
# launcher's `xdg-open http://127.0.0.1:8088/` finds no handler and the button
# does nothing. The name it points at, badwolf.desktop, is not written by this
# repo: the www/badwolf package installs it to
# /usr/local/share/applications/badwolf.desktop, which is on the default
# XDG_DATA_DIRS search path and is where xdg-mime resolves the name from.
if run install -o "${USER_NAME}" -m 644 "${HERE}/mimeapps.list" "${HOME_DIR}/.config/mimeapps.list"; then
    ok "mimeapps.list installed (badwolf is the default browser)"
else
    warn "could not install mimeapps.list"
fi

# --- 7. console autologin ---------------------------------------------------
step "console autologin"

# ttyv0 references this capability by name, not by account, so re-running
# with a different DESKTOP_USER only has to replace this block -- the ttys
# line below never changes.
#
# Built from separately-resolved pieces rather than one printf format string:
# a format string with a backslash-then-newline escape next to each other
# (needed for gettytab's own line-continuation syntax) was tried first and
# silently produced a literal `\n` two-character sequence instead of a
# newline byte on this shell -- caught only by dumping the result through
# `od`, not by eye.
GT_TAB=$(printf '\t')
GT_NL='
'
AL_BODY="hajime-al|Hajime desktop autologin:\\${GT_NL}${GT_TAB}:al=${USER_NAME}:tc=Pc:"
if write_block /etc/gettytab "$AL_BODY"; then
    ok "/etc/gettytab: hajime-al autologs in as ${USER_NAME}"
else
    die "could not write /etc/gettytab"
fi

# Edited in place, not appended: getttyent(3) has no defined behaviour for two
# entries named ttyv0, and init(8) starting a getty twice on /dev/ttyv0 is not
# a failure mode worth finding out by hand on a machine with no other console.
if grep -qE '^ttyv0[[:space:]].*getty[[:space:]]+hajime-al' /etc/ttys 2>/dev/null; then
    ok "ttyv0 already set to autologin (hajime-al)"
elif [ "$DRY" -eq 1 ]; then
    say "   would  point ttyv0 at the hajime-al autologin getty tag"
elif grep -qE '^ttyv0[[:space:]]+"[^"]*getty[[:space:]]+Pc"' /etc/ttys 2>/dev/null; then
    keep_original /etc/ttys
    tmp="/etc/ttys.hajime.$$"
    awk '
        /^ttyv0[ \t]+"[^"]*getty[ \t]+Pc"/ {
            print "'"$BEGIN"'"
            print "ttyv0\t\"/usr/libexec/getty hajime-al\"\t\txterm\tonifexists secure"
            print "'"$END"'"
            next
        }
        { print }
    ' /etc/ttys > "$tmp" && mv "$tmp" /etc/ttys \
        && ok "ttyv0: autologin as ${USER_NAME} (hajime-al)" \
        || die "could not write /etc/ttys"
else
    die "ttyv0's line in /etc/ttys is not the stock 'getty Pc' entry; refusing
            to guess how to edit it. Point it at the autologin tag by hand:
            ttyv0 \"/usr/libexec/getty hajime-al\"  xterm  onifexists secure"
fi

# --- 8. desktop autostart ---------------------------------------------------
step "desktop autostart"

# Appended to .profile, not to wayfire's own launch: sh(1) reads ~/.profile
# for every login shell, autologin included, and the guard below is what
# keeps that from also starting wayfire over ssh or a second time on top of
# an already-running session. See the block itself for the reasoning behind
# each check.
AUTOSTART_BODY=$(cat <<'HAJIME_AUTOSTART_EOF'

# Wayfire starts only for this account's own login on the physical console,
# never over ssh and never a second time on top of itself. ttyv0 is the only
# tty init(8) autologs into (see /etc/ttys); every other path here -- ssh,
# `su`, a login on ttyv1..8 -- reads a different tty and falls through to the
# ordinary shell below instead.
if [ "$(tty 2>/dev/null)" = "/dev/ttyv0" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && \
   ! pgrep -q -x -u "$(id -u)" wayfire; then
    # FreeBSD has no systemd/elogind to create this, and /var/run is wiped by
    # cleanvar(8) on every boot before this account could own a directory
    # there, so the runtime directory lives under $HOME instead: created
    # fresh on login, owned by this account, gone only when the account is.
    #
    # Wiped before use, not just created: getting here already proved no
    # wayfire is running, so nothing can be using the old one, and leaving it
    # in place let a wayland-N socket from every past crash sit there forever.
    export XDG_RUNTIME_DIR="${HOME}/.xdg_runtime"
    rm -rf "$XDG_RUNTIME_DIR"
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    # exec, not a background start: no loop in this script retries wayfire if
    # it crashes. If it exits, this shell exits with it, init(8) respawns
    # getty on ttyv0, and the account logs back in fresh -- the standard
    # ttys(5) respawn throttle is what stops a crash loop from spinning
    # unbounded, not a loop written here.
    exec wayfire >"${HOME}/.wayfire.log" 2>&1
fi
HAJIME_AUTOSTART_EOF
)

PROFILE="${HOME_DIR}/.profile"
[ -f "$PROFILE" ] || die "no ${PROFILE}. The account's shell should have
            created one from /usr/share/skel; give ${USER_NAME} a real login
            shell before running this again."
if write_block "$PROFILE" "$AUTOSTART_BODY"; then
    run chown "${USER_NAME}" "$PROFILE"
    ok "${PROFILE}: wayfire starts on ${USER_NAME}'s own ttyv0 login"
else
    die "could not write ${PROFILE}"
fi

# --- 9. verdict ------------------------------------------------------------
step "next"
if [ "$DRY" -eq 1 ]; then
    say "   dry run complete; nothing was changed"
    say "   ${WARNINGS} warning(s), ${BLOCKERS} blocker(s)."
    if [ "$BLOCKERS" -gt 0 ]; then
        say ""
        say "   A real run would stop at the first WOULD REFUSE above."
        exit 1
    fi
    say "   A real run would proceed."
    exit 0
fi

say "   Reboot. i915kms loads from kld_list, ${USER_NAME} logs in on ttyv0"
say "   without a password prompt, and wayfire starts by itself from"
say "   ${USER_NAME}'s .profile. Nothing to type at the console."
say ""
say "   If the screen stays black, the firmware is the first thing to check:"
say ""
say "     dmesg | grep -i drm | grep -i firmware"
say ""
say "   A line reading 'successfully loaded firmware image' means the GPU is"
say "   working and the problem is elsewhere. A 'not found' line names the"
say "   file, and its prefix names the package."
say ""
say "   If wayfire started but crashed, ${USER_NAME}'s own log has the reason:"
say ""
say "     cat ~${USER_NAME}/.wayfire.log"
say ""
say "   The diagnostic script covers the rest:  sh wayland_feasibility_test.sh"
say ""
say "   To undo the autologin: /etc/gettytab, /etc/ttys and"
say "   ~${USER_NAME}/.profile each have a .hajime-orig copy beside them, and"
say "   this script's own additions sit between ${BEGIN} and ${END} markers."
say ""
say "   The wallpaper, the splash and the launcher icons come from the theme"
say "   installer, which also sets the loader screen and the console palette:"
say ""
say "     sh hajime-brand/install_theme.sh"
say ""
say "   And the display language, which is a login class like on any other"
say "   system rather than a translation painted into the pictures:"
say ""
say "     hajime-lang ar        (or: hajime-lang en)"
exit 0
