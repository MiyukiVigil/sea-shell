#!/usr/bin/env bash
# Pack the current sea-shell look (wallpaper pointer, appearance, matugen colours,
# desktop layout) into a tarball you can share or re-import.
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/sea-shell"
OUT_DIR="${1:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M)"
NAME="sea-theme-${STAMP}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$NAME" "$OUT_DIR"

copy_if() {
  local src="$1" dest="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

copy_if "$CFG/appearance.json" "$STAGE/$NAME/appearance.json"
copy_if "$CFG/desktop.json" "$STAGE/$NAME/desktop.json"
copy_if "$CFG/wallpaper" "$STAGE/$NAME/wallpaper"
copy_if "$CFG/wallpaper-path" "$STAGE/$NAME/wallpaper-path"
copy_if "$CFG/matugen" "$STAGE/$NAME/matugen"
copy_if "$CFG/theme-profiles" "$STAGE/$NAME/theme-profiles"
# Optional extras people often want with a look
copy_if "$CFG/calendar.json" "$STAGE/$NAME/calendar.json"
copy_if "$CFG/focus-profiles.json" "$STAGE/$NAME/focus-profiles.json"

# Resolve wallpaper file into the pack when we only have a path pointer
if [[ -f "$CFG/wallpaper-path" ]]; then
  wp="$(tr -d '\n' < "$CFG/wallpaper-path")"
  if [[ -n "$wp" && -f "$wp" ]]; then
    mkdir -p "$STAGE/$NAME/assets"
    ext="${wp##*.}"
    [[ "$ext" == "$wp" || "$ext" == *"/"* ]] && ext="bin"
    cp -a "$wp" "$STAGE/$NAME/assets/wallpaper.$ext"
  fi
elif [[ -f "$CFG/wallpaper" ]]; then
  mkdir -p "$STAGE/$NAME/assets"
  cp -a "$CFG/wallpaper" "$STAGE/$NAME/assets/wallpaper.bin"
fi

cat > "$STAGE/$NAME/README.txt" <<EOF
sea-shell theme pack
Exported: $(date -Iseconds)

To import on another machine:
  1. Extract this archive
  2. Copy appearance.json, desktop.json into ~/.config/sea-shell/
  3. Place the wallpaper from assets/ wherever you like and set it with
     sea-wallpaper-apply.sh, or copy wallpaper-path / wallpaper back
  4. Restart the bar: sea-bar-supervisor.sh --restart

EOF

ARCHIVE="$OUT_DIR/${NAME}.tar.gz"
tar -C "$STAGE" -czf "$ARCHIVE" "$NAME"
printf '%s\n' "$ARCHIVE"
