#!/bin/sh
# Prefer the Rust sea-appmenu binary when install.sh built it; else Python.
# SEA_APPMENU_PY=1 forces the Python path (fallback / compare).
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -z "${SEA_APPMENU_PY:-}" ] && [ -x "$DIR/sea-appmenu" ]; then
  exec "$DIR/sea-appmenu" "$@"
fi
exec python3 "$DIR/sea-appmenu.py" "$@"
