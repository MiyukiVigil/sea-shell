#!/bin/sh
# Prefer the Rust sea-panel binary when install.sh built it; else Python.
# SEA_PANEL_PY=1 forces the Python path (fallback / compare).
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -z "${SEA_PANEL_PY:-}" ] && [ -x "$DIR/sea-panel" ]; then
  exec "$DIR/sea-panel" "$@"
fi
exec python3 "$DIR/sea-panel.py" "$@"
