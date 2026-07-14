#!/bin/sh
# sea-shell — sync the current wallpaper to the hyprlock background.
# For video/gif: extracts the first frame via ffmpeg into sea-lockwall.png.
# For static images: copies directly to sea-lockwall.png.
# Then patches the path = line in hyprlock.conf.
#
# Usage: sea-lockwall.sh [wallpaper-path]
#   If no argument, reads ~/.config/sea-shell/wallpaper

set -e

DEST="$HOME/.config/sea-shell/sea-lockwall.png"
LOCK_CONF="$HOME/.config/hypr/hyprlock.conf"

wp="${1:-}"
if [ -z "$wp" ]; then
    wp="$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null || true)"
fi
[ -z "$wp" ] && wp="$HOME/.config/sea-shell/sea-wall.png"
[ -f "$wp" ] || { echo "sea-lockwall: wallpaper not found: $wp" >&2; exit 1; }

ext="$(printf '%s' "$wp" | tr '[:upper:]' '[:lower:]' | sed 's/.*\.//')"

case "$ext" in
    mp4|webm|mkv|avi|mov|gif)
        # Extract first frame — scale to 1920×1080 max, preserve aspect
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -y -loglevel error \
                -i "$wp" \
                -vframes 1 \
                -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease" \
                "$DEST"
        else
            echo "sea-lockwall: ffmpeg not found, cannot extract frame" >&2
            exit 1
        fi
        ;;
    *)
        cp "$wp" "$DEST"
        ;;
esac

# Patch path = in hyprlock.conf if it exists
if [ -f "$LOCK_CONF" ]; then
    # Use sed to replace the path = line inside the background block
    # Works even if the file uses spaces around =
    sed -i "s|^\( *path *= *\).*|\1$DEST|" "$LOCK_CONF"
fi

echo "sea-lockwall: lock background set to $DEST"
