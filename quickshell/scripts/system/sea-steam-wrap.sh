#!/bin/sh
# Steam LaunchOptions helper:  sea-steam-wrap.sh %command%
# Applies sea-shell's per-game profile (Gamescope, MangoHud, gamemoderun) around the
# GAME, never around the Steam client.
set -e
HERE="$HOME/.config/quickshell/sea-shell"
APP="${SteamAppId:-${SteamGameId:-0}}"
exec python3 "$HERE/sea-gaming.py" wrap-exec "$APP" -- "$@"
