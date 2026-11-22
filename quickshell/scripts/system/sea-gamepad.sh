#!/bin/sh
# Prefer the Rust sea-gamepad binary when install.sh built it; else Python.
# SEA_GAMEPAD_PY=1 forces the Python path (fallback / compare).
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -z "${SEA_GAMEPAD_PY:-}" ] && [ -x "$DIR/sea-gamepad" ]; then
  exec "$DIR/sea-gamepad" "$@"
fi
exec python3 "$DIR/sea-gamepad.py" "$@"
