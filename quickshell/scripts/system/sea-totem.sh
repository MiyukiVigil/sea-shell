#!/usr/bin/env bash
# sea-shell Totem bar helper: find the `totem` CLI and run status / list / code as JSON.
# Usage:
#   sea-totem.sh status
#   sea-totem.sh list
#   sea-totem.sh code <query-or-id>
#   sea-totem.sh open          # open the Totem desktop popup (second instance)
set -euo pipefail

find_totem() {
  if [[ -n "${TOTEM_BIN:-}" && -x "$TOTEM_BIN" ]]; then
    printf '%s\n' "$TOTEM_BIN"
    return 0
  fi
  if command -v totem >/dev/null 2>&1; then
    command -v totem
    return 0
  fi
  local candidates=(
    "$HOME/Documents/Personal/MultiPlatformAuthenticator/target/release/totem"
    "$HOME/Documents/Personal/MultiPlatformAuthenticator/target/debug/totem"
    "$HOME/.local/bin/totem"
    /usr/local/bin/totem
    /usr/bin/totem
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

find_desktop() {
  if [[ -n "${TOTEM_DESKTOP:-}" && -x "$TOTEM_DESKTOP" ]]; then
    printf '%s\n' "$TOTEM_DESKTOP"
    return 0
  fi
  if command -v totem-desktop >/dev/null 2>&1; then
    command -v totem-desktop
    return 0
  fi
  local candidates=(
    "$HOME/Documents/Personal/MultiPlatformAuthenticator/target/release/totem-desktop"
    "$HOME/Documents/Personal/MultiPlatformAuthenticator/desktop/src-tauri/target/release/totem-desktop"
    "$HOME/.local/bin/totem-desktop"
    /usr/bin/totem-desktop
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  open)
    if desk=$(find_desktop); then
      exec "$desk" "$@"
    fi
    printf '{"ok":false,"error":"Totem desktop app not found"}\n'
    exit 1
    ;;
  status|list|code)
    if ! bin=$(find_totem); then
      printf '{"ok":false,"error":"totem CLI not found — build with: cargo build -p totem-cli --release","missing":true}\n'
      exit 0
    fi
    if [[ "$cmd" == "status" ]]; then
      exec "$bin" status --json
    elif [[ "$cmd" == "list" ]]; then
      enrich=""
      for cand in \
        "$HOME/.config/quickshell/sea-shell/sea-totem-enrich.py" \
        "$HOME/Documents/sea-shell/quickshell/scripts/system/sea-totem-enrich.py"
      do
        if [[ -f "$cand" ]]; then enrich="$cand"; break; fi
      done
      if [[ -n "$enrich" ]]; then
        "$bin" list --json | python3 "$enrich"
      else
        exec "$bin" list --json
      fi
    else
      q="${1:-}"
      if [[ -z "$q" ]]; then
        printf '{"ok":false,"error":"missing account query"}\n'
        exit 1
      fi
      exec "$bin" code "$q" --no-copy --json
    fi
    ;;
  *)
    printf '{"ok":false,"error":"unknown command"}\n'
    exit 1
    ;;
esac
