#!/bin/sh
# ==============================================================================
# Hajime OS - Yōkoso Boot Splash Player
# Plays C:\Users\Farhan\Downloads\Hajime_OS.mp4 on startup with "Yōkoso" greeting
# ==============================================================================

INTRO_PATH="/usr/local/share/hajime/Hajime_OS.mp4"
FALLBACK_PATH="/mnt/Downloads/Hajime_OS.mp4"

echo "⛩️  [Hajime OS] Initializing Yōkoso (ようこそ) Boot Splash..."

if [ -f "$INTRO_PATH" ]; then
    ffplay -nodisp -autoexit -loglevel quiet "$INTRO_PATH" &
    mpv --fs --no-osc --no-input-default-bindings "$INTRO_PATH" 2>/dev/null || true
elif [ -f "$FALLBACK_PATH" ]; then
    mpv --fs "$FALLBACK_PATH" 2>/dev/null || true
else
    echo "ようこそ (Yōkoso) to Hajime OS!"
fi
