#!/usr/bin/env bash
# sea-shell installer — installs the sea-cyan rice into ~/.config so it works
# on every login with no dependence on where this repo lives.
# Idempotent + reversible.  Usage:
#   ./install.sh              # install (copies configs into ~/.config)
#   ./install.sh --dev        # developer mode: symlink configs to this repo instead
#   ./install.sh --wallpaper  # also generate + set a sea-gradient wallpaper
#   ./install.sh --uninstall  # remove everything this script added
# NOTE: intentionally NOT using `set -e` — this script leans on `[ test ] && action`
# idioms whose non-zero exit is expected control flow, which `set -e` would treat
# as a fatal error (e.g. check_deps returning 1 when nothing is missing).
set -uo pipefail

# ---- where this repo lives (resolves symlinks) ----
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARK_A="# >>> sea-shell >>>"
MARK_B="# <<< sea-shell <<<"

# install destinations (everything sea-shell owns lives in a sea-shell/ subdir)
QS_DEST="$CFG/quickshell/sea-shell"
HYPR_DEST="$CFG/hypr/sea-shell"
KITTY_THEME="$CFG/kitty/sea-cyan.conf"
DATA_DIR="$CFG/sea-shell"                 # runtime data (appearance.json, wallpaper)

# ---- pretty output ----
c() { printf '\033[%sm' "$1"; }
info()  { printf '%s»%s %s\n' "$(c '38;2;99;199;221')" "$(c 0)" "$*"; }
ok()    { printf '%s✓%s %s\n' "$(c '38;2;166;227;161')" "$(c 0)" "$*"; }
warn()  { printf '%s!%s %s\n' "$(c '38;2;244;197;66')" "$(c 0)" "$*"; }
title() { printf '\n%s🌊 %s%s\n' "$(c '1;38;2;162;226;232')" "$*" "$(c 0)"; }

# ---- helpers ----
# (re)write a marker-wrapped block in a file — replaces any previous sea-shell block,
# so re-running install always leaves the block current
add_block() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"; touch "$file"
  if grep -qF "$MARK_A" "$file"; then
    sed -i "/$MARK_A/,/$MARK_B/d" "$file"
    info "refreshing sea-shell block in ${file/#$HOME/\~}"
  else
    cp -a "$file" "$file.bak-$STAMP" 2>/dev/null && info "backed up ${file/#$HOME/\~} → .bak-$STAMP"
  fi
  { printf '\n%s\n%s\n%s\n' "$MARK_A" "$content" "$MARK_B"; } >> "$file"
  ok "wired ${file/#$HOME/\~}"
}
remove_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  if grep -qF "$MARK_A" "$file"; then
    sed -i "/$MARK_A/,/$MARK_B/d" "$file"
    ok "unwired ${file/#$HOME/\~}"
  fi
}
# copy a single file into place (backs up a pre-existing foreign file once)
copy_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  [ -L "$dest" ] && rm -f "$dest"        # replace an old --dev symlink
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest" && ! grep -qsF "sea-shell" "$dest"; then
    cp -a "$dest" "$dest.bak-$STAMP"; info "backed up ${dest/#$HOME/\~} → .bak-$STAMP"
  fi
  install -m 644 "$src" "$dest"
  ok "installed ${dest/#$HOME/\~}"
}
# copy a whole directory into place; a marker file tags it as ours so uninstall
# (and re-install) never deletes a directory the user made themselves
copy_dir() {
  local src="$1" dest="$2"
  [ -L "$dest" ] && rm -f "$dest"        # replace an old --dev symlink
  if [ -d "$dest" ] && [ ! -f "$dest/.sea-shell" ]; then
    mv "$dest" "$dest.bak-$STAMP"; info "backed up ${dest/#$HOME/\~} → .bak-$STAMP"
  fi
  rm -rf "$dest"; mkdir -p "$dest"
  cp -a "$src"/. "$dest"/
  touch "$dest/.sea-shell"
  chmod +x "$dest"/*.sh 2>/dev/null
  ok "installed ${dest/#$HOME/\~}/"
}
link_dir() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -d "$dest" ] && ! [ -L "$dest" ]; then mv "$dest" "$dest.bak-$STAMP"; info "backed up ${dest/#$HOME/\~} → .bak-$STAMP"; fi
  ln -sfn "$src" "$dest"
  ok "linked ${dest/#$HOME/\~} → ${src/#$HOME/\~}"
}

check_deps() {
  local missing=() optional=()
  for d in hyprctl qs kitty; do
    command -v "$d" >/dev/null 2>&1 || missing+=("$d")
  done
  # used by the bar / launcher / keybinds — everything still works without them,
  # just with that feature missing
  for d in grim slurp wl-copy cliphist fd playerctl brightnessctl swww hyprlock hypridle; do
    command -v "$d" >/dev/null 2>&1 || optional+=("$d")
  done
  [ -x /usr/lib/hyprpolkitagent ] || command -v hyprpolkitagent >/dev/null 2>&1 || optional+=("hyprpolkitagent")
  [ ${#missing[@]} -gt 0 ] && warn "REQUIRED but not on PATH: ${missing[*]}"
  [ ${#optional[@]} -gt 0 ] && warn "optional, some features off without them: ${optional[*]}"
  [ ${#optional[@]} -gt 0 ] && info "grab them all:  sudo pacman -S ${optional[*]}"
  # NB: no `grep -q` here — with pipefail, its early exit SIGPIPEs fc-list into a false warning
  fc-list 2>/dev/null | grep -i "material symbols" >/dev/null || warn "font 'Material Symbols Outlined' not found — bar icons will be boxes (pacman -S ttf-material-symbols-variable-git)"
  return 0
}

hypr_block() {
  # $1 = dir the hypr confs are sourced from
  # idle daemon + polkit agent are guarded at runtime, so installing the package
  # later makes them work on the next login without re-running this script
  local block="source = $1/sea.conf
source = $1/keybinds.conf
exec-once = qs -c sea-shell
exec-once = sh -c 'command -v hypridle >/dev/null && exec hypridle'
exec-once = sh -c '[ -x /usr/lib/hyprpolkitagent ] && exec /usr/lib/hyprpolkitagent'"
  # wallpaper restore at login (only when swww is available)
  if command -v swww >/dev/null 2>&1; then
    block="$block
exec-once = swww-daemon
exec-once = sh -c 'sleep 1; [ -f $DATA_DIR/sea-wall.png ] && swww img $DATA_DIR/sea-wall.png'"
  fi
  printf '%s' "$block"
}

do_install() {
  title "installing sea-shell from ${SCRIPT_DIR/#$HOME/\~}"
  check_deps
  mkdir -p "$DATA_DIR"
  # remember where the repo lives so GUI edits (keybind rebinds) can sync back to it
  printf '%s' "$SCRIPT_DIR" > "$DATA_DIR/.repo"

  if [ "${DEV:-0}" = "1" ]; then
    # ---- developer mode: live-edit the repo, configs follow instantly ----
    link_dir "$SCRIPT_DIR/quickshell" "$QS_DEST"
    add_block "$CFG/hypr/hyprland.conf" "$(hypr_block "$SCRIPT_DIR/hypr")"
    add_block "$CFG/kitty/kitty.conf" "include $SCRIPT_DIR/kitty/sea-cyan.conf"
    mkdir -p "$CFG"
    [ -e "$CFG/starship.toml" ] && ! [ -L "$CFG/starship.toml" ] && { cp -a "$CFG/starship.toml" "$CFG/starship.toml.bak-$STAMP"; info "backed up ~/.config/starship.toml → .bak-$STAMP"; }
    ln -sfn "$SCRIPT_DIR/starship/sea.toml" "$CFG/starship.toml"
    ok "linked ~/.config/starship.toml → repo"
    ln -sfn "$SCRIPT_DIR/hypr/hyprlock.conf" "$CFG/hypr/hyprlock.conf"; ok "linked ~/.config/hypr/hyprlock.conf → repo"
    ln -sfn "$SCRIPT_DIR/hypr/hypridle.conf" "$CFG/hypr/hypridle.conf"; ok "linked ~/.config/hypr/hypridle.conf → repo"
  else
    # ---- normal mode: self-contained copies in ~/.config ----
    # 0) Quickshell bar + overlays + helper scripts (run with `qs -c sea-shell`)
    copy_dir "$SCRIPT_DIR/quickshell" "$QS_DEST"
    # 1) Hyprland look + keybinds, sourced from ~/.config/hypr/sea-shell
    mkdir -p "$HYPR_DEST"
    copy_file "$SCRIPT_DIR/hypr/sea.conf" "$HYPR_DEST/sea.conf"
    copy_file "$SCRIPT_DIR/hypr/keybinds.conf" "$HYPR_DEST/keybinds.conf"
    add_block "$CFG/hypr/hyprland.conf" "$(hypr_block "$HYPR_DEST")"
    # 2) kitty theme
    copy_file "$SCRIPT_DIR/kitty/sea-cyan.conf" "$KITTY_THEME"
    add_block "$CFG/kitty/kitty.conf" "include $KITTY_THEME"
    # 3) starship prompt (fish already runs `starship init fish`)
    copy_file "$SCRIPT_DIR/starship/sea.toml" "$CFG/starship.toml"
    # 4) lock screen + idle daemon (canonical paths — hyprlock/hypridle only read these)
    copy_file "$SCRIPT_DIR/hypr/hyprlock.conf" "$CFG/hypr/hyprlock.conf"
    copy_file "$SCRIPT_DIR/hypr/hypridle.conf" "$CFG/hypr/hypridle.conf"
  fi

  # 3) wallpaper: install the repo one if present; --wallpaper regenerates it
  [ -f "$SCRIPT_DIR/sea-wall.png" ] && copy_file "$SCRIPT_DIR/sea-wall.png" "$DATA_DIR/sea-wall.png"
  if [ "${WALLPAPER:-0}" = "1" ]; then set_wallpaper; fi

  # 4) apply live: reload hyprland + (re)start the bar from the installed config
  if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    hyprctl reload >/dev/null 2>&1
    pkill -xf "qs -c sea-shell" 2>/dev/null
    hyprctl dispatch exec "qs -c sea-shell" >/dev/null 2>&1
    ok "hyprland reloaded, bar restarted"
  else
    info "not inside a Hyprland session — everything starts on next login"
  fi

  title "done — log out/in (or reboot) and sea-shell comes up by itself"
  [ "${DEV:-0}" = "1" ] && warn "dev mode: configs point at this repo — don't move/delete it" \
                        || info "repo can be moved/deleted; re-run ./install.sh after pulling updates"
}

set_wallpaper() {
  local out="$DATA_DIR/sea-wall.png"
  if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    warn "ImageMagick not found — skipping wallpaper (install 'imagemagick')"; return
  fi
  local IM; IM="$(command -v magick || command -v convert)"
  "$IM" -size 3840x2160 gradient:'#12507a-#0a1420' "$out" && ok "wallpaper → $out"
  if command -v swww >/dev/null 2>&1; then
    pgrep -x swww-daemon >/dev/null || swww-daemon 2>/dev/null &
    sleep 0.5; swww img "$out" 2>/dev/null && ok "set via swww (and restored on every login)"
  else warn "no swww — wallpaper generated but install 'swww' for it to apply + restore on login"; fi
}

do_uninstall() {
  title "uninstalling sea-shell"
  pkill -xf "qs -c sea-shell" 2>/dev/null
  remove_block "$CFG/hypr/hyprland.conf"
  remove_block "$CFG/kitty/kitty.conf"
  # installed copies (only removed when tagged as ours) and --dev symlinks
  if [ -L "$QS_DEST" ] || [ -f "$QS_DEST/.sea-shell" ]; then rm -rf "$QS_DEST"; ok "removed ${QS_DEST/#$HOME/\~}"; fi
  [ -d "$HYPR_DEST" ] && { rm -rf "$HYPR_DEST"; ok "removed ${HYPR_DEST/#$HOME/\~}"; }
  [ -f "$KITTY_THEME" ] && { rm -f "$KITTY_THEME"; ok "removed ${KITTY_THEME/#$HOME/\~}"; }
  # per-file installs: only remove if ours (or a --dev symlink), then restore the newest backup
  local f bak
  for f in "$CFG/starship.toml" "$CFG/hypr/hyprlock.conf" "$CFG/hypr/hypridle.conf"; do
    if [ -L "$f" ] || grep -qsF "sea-shell" "$f"; then
      rm -f "$f"; ok "removed ${f/#$HOME/\~}"
      bak="$(ls -1t "$f".bak-* 2>/dev/null | head -1 || true)"
      [ -n "$bak" ] && { mv "$bak" "$f"; info "restored backup → ${f/#$HOME/\~}"; }
    fi
  done
  info "runtime data kept at ${DATA_DIR/#$HOME/\~} (appearance, launcher history) — delete it manually if unwanted"
  title "done — run 'hyprctl reload' to apply"
}

# ---- args ----
case "${1:-}" in
  --uninstall|-u) do_uninstall ;;
  --wallpaper)    WALLPAPER=1 do_install ;;
  --dev)          DEV=1 do_install ;;
  -h|--help) sed -n '2,9p' "$0" ;;
  "") do_install ;;
  *) warn "unknown option: $1"; sed -n '2,9p' "$0"; exit 1 ;;
esac
