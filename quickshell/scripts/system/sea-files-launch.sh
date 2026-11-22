#!/usr/bin/env sh
# Launch native sea-files; fail clearly if install.sh has not built it yet.
SF="${SEA_FILES:-$HOME/.config/quickshell/sea-shell/sea-files}"
if [ -x "$SF" ]; then
  exec "$SF" "$@"
fi
echo "sea-files not found at $SF — run ./install.sh from the sea-shell repo." >&2
exit 1
