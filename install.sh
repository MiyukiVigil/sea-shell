#!/usr/bin/env bash
# sea-shell installer — installs the sea-cyan rice into ~/.config so it works
# on every login with no dependence on where this repo lives.
# Idempotent + reversible.  Usage:
#   ./install.sh              # full install: packages (pacman + AUR) THEN configs
#   ./install.sh --deps       # only install the packages, touch no configs
#   ./install.sh --no-deps    # skip packages, only lay down configs (works on any distro)
#   ./install.sh --dev        # developer mode: symlink configs to this repo instead
#   ./install.sh --wallpaper  # also generate + set a sea-gradient wallpaper
#   ./install.sh -y|--yes     # non-interactive (pacman/makepkg --noconfirm)
#   ./install.sh --uninstall  # remove everything this script added
# Package install is Arch-only (Arch/CachyOS/EndeavourOS/Manjaro/Artix — needs pacman + the
# AUR). On any other distro, install the deps yourself and run with --no-deps.
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
MARK_A_LUA="-- >>> sea-shell >>>"          # Lua-comment markers for the hyprland.lua block
MARK_B_LUA="-- <<< sea-shell <<<"

# install destinations (everything sea-shell owns lives in a sea-shell/ subdir)
QS_DEST="$CFG/quickshell/sea-shell"
HYPR_DEST="$CFG/hypr/sea-shell"
KITTY_THEME="$CFG/kitty/sea-cyan.conf"
DATA_DIR="$CFG/sea-shell"                 # runtime data (appearance.json, wallpaper)
SEA_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo 1.3.0)"   # release, from ./VERSION

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
  local file="$1" content="$2" ma="${3:-$MARK_A}" mb="${4:-$MARK_B}"
  mkdir -p "$(dirname "$file")"; touch "$file"
  if grep -qF -- "$ma" "$file"; then          # `--`: markers start with `--` (Lua comment), don't let grep parse them as options
    sed -i "/$ma/,/$mb/d" "$file"
    info "refreshing sea-shell block in ${file/#$HOME/\~}"
  else
    cp -a "$file" "$file.bak-$STAMP" 2>/dev/null && info "backed up ${file/#$HOME/\~} → .bak-$STAMP"
  fi
  { printf '\n%s\n%s\n%s\n' "$ma" "$content" "$mb"; } >> "$file"
  ok "wired ${file/#$HOME/\~}"
}
remove_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  # remove both the legacy hyprlang (#) block and the Lua (--) block, wherever they live
  grep -qF -- "$MARK_A"     "$file" && { sed -i "/$MARK_A/,/$MARK_B/d" "$file";         ok "unwired ${file/#$HOME/\~}"; }
  grep -qF -- "$MARK_A_LUA" "$file" && { sed -i "/$MARK_A_LUA/,/$MARK_B_LUA/d" "$file"; ok "unwired ${file/#$HOME/\~} (lua)"; }
  return 0
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
# lay the quickshell/ tree down FLAT into $QS_DEST. The repo is organised into subfolders
# (ui/ · scripts/{wallpaper,theme,lock,…} · assets/) for sanity, but the runtime resolves
# every .qml component and helper script as a flat sibling in one directory, so we flatten
# on deploy — recursively, at any depth, so new subfolders added later just work. Basenames
# must stay unique across the tree (a collision is warned + skipped, not silently merged).
# $1 = copy (self-contained) | link (--dev, live-edit the repo).
deploy_qs() {
  local mode="$1" src="$SCRIPT_DIR/quickshell" dest="$QS_DEST" f name seen=" "
  [ -L "$dest" ] && rm -f "$dest"        # replace an old --dev symlink
  if [ -d "$dest" ] && [ ! -f "$dest/.sea-shell" ]; then
    mv "$dest" "$dest.bak-$STAMP"; info "backed up ${dest/#$HOME/\~} → .bak-$STAMP"
  fi
  rm -rf "$dest"; mkdir -p "$dest"
  while IFS= read -r f; do
    name="$(basename "$f")"
    case "$seen" in *" $name "*) warn "duplicate basename '$name' (${f#$src/}) — skipped"; continue ;; esac
    seen="$seen$name "
    if [ "$mode" = "link" ]; then ln -sfn "$f" "$dest/$name"
    else install -m 644 "$f" "$dest/$name"; fi
  done < <(find "$src" -type f ! -name '.sea-shell' | sort)
  touch "$dest/.sea-shell"
  chmod +x "$dest"/*.sh "$dest"/*.py 2>/dev/null
  ok "installed ${dest/#$HOME/\~}/ (${mode}, flattened)"
}

check_deps() {
  local missing=() optional=()
  for d in hyprctl qs kitty; do
    command -v "$d" >/dev/null 2>&1 || missing+=("$d")
  done
  # used by the bar / launcher / keybinds — everything still works without them,
  # just with that feature missing
  for d in grim slurp wl-copy cliphist fd playerctl brightnessctl hyprlock hypridle hyprsunset wf-recorder jq kdeconnect-cli zenity; do
    command -v "$d" >/dev/null 2>&1 || optional+=("$d")
  done
  # static wallpapers want swww (or its awww fork); animated ones want mpvpaper
  command -v swww >/dev/null 2>&1 || command -v awww >/dev/null 2>&1 || optional+=("swww")
  command -v mpvpaper >/dev/null 2>&1 || optional+=("mpvpaper")
  [ -x /usr/lib/hyprpolkitagent/hyprpolkitagent ] || command -v hyprpolkitagent >/dev/null 2>&1 || optional+=("hyprpolkitagent")
  [ ${#missing[@]} -gt 0 ] && warn "REQUIRED but not on PATH: ${missing[*]}"
  [ ${#optional[@]} -gt 0 ] && warn "optional, some features off without them: ${optional[*]}"
  [ ${#optional[@]} -gt 0 ] && info "grab them all:  sudo pacman -S ${optional[*]}"
  # NB: no `grep -q` here — with pipefail, its early exit SIGPIPEs fc-list into a false warning
  fc-list 2>/dev/null | grep -i "material symbols" >/dev/null || warn "font 'Material Symbols Outlined' not found — bar icons will be boxes (yay -S ttf-material-symbols-variable)"
  fc-list 2>/dev/null | grep -i "symbols nerd font" >/dev/null || warn "font 'Symbols Nerd Font' not found — distro/brand logos on the System page will be boxes (sudo pacman -S ttf-nerd-fonts-symbols)"
  return 0
}

# ---------- package installation (Arch only) ----------
# Official-repo packages — installed with pacman (fast, no build).
REPO_PKGS=(
  hyprland hypridle hyprlock hyprpolkitagent hyprsunset  # compositor + idle/lock/polkit/night-light
  kitty fish starship fastfetch                       # terminal · shell · prompt · fetch
  pipewire wireplumber pipewire-pulse                 # audio (the bar's volume/OSD)
  networkmanager bluez bluez-utils upower             # net · bluetooth · battery
  power-profiles-daemon polkit                        # power menu · auth
  xdg-desktop-portal-gtk adw-gtk-theme                # GTK/Qt/browser light-dark follows the shell
  brightnessctl playerctl cliphist wl-clipboard       # brightness · media · clipboard
  grim slurp cava                                     # screenshots · audio visualiser
  wf-recorder                                         # screen recording (SUPER+R)
  libnotify python fd ffmpeg imagemagick curl jq kdeconnect # notifications + helpers used by scripts
  zenity                                              # file picker behind KDE Connect "send file"
  ttf-nerd-fonts-symbols                              # brand/distro logo glyphs on the System page
  python-hidapi                                       # Moondrop DAC EQ panel (USB-HID control)
)
# AUR packages — need an AUR helper (paru/yay); bootstrapped below if absent.
AUR_PKGS=(
  quickshell                          # the bar/launcher/overlays engine — the heart of it
  matugen                             # wallpaper→accent theming ("match colours")
  ttf-material-symbols-variable       # the bar's icon font (stable pkg; the -git one won't build)
  swww                                # static / image wallpapers
  mpvpaper                            # animated (video) wallpapers
)

require_arch() {
  command -v pacman >/dev/null 2>&1 && return 0
  warn "sea-shell's automatic setup installs from the Arch repos + AUR, so it only runs on"
  warn "Arch-based distros (Arch · CachyOS · EndeavourOS · Manjaro · Artix …)."
  warn "On another distro: install the equivalents of these yourself, then run --no-deps:"
  warn "  ${REPO_PKGS[*]} ${AUR_PKGS[*]}"
  exit 1
}

aur_helper() { for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }; done; return 1; }

bootstrap_paru() {
  info "no AUR helper found — bootstrapping paru (for quickshell, matugen, the icon font)…"
  sudo pacman -S --needed $NOCONFIRM base-devel git || return 1
  local tmp; tmp="$(mktemp -d)"
  git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin" || { rm -rf "$tmp"; return 1; }
  ( cd "$tmp/paru-bin" && makepkg -si $NOCONFIRM ); local rc=$?
  rm -rf "$tmp"; [ $rc -eq 0 ] && command -v paru >/dev/null 2>&1
}

enable_services() {
  info "enabling services (NetworkManager · Bluetooth · power profiles · PipeWire)…"
  sudo systemctl enable --now NetworkManager.service     2>/dev/null || true
  sudo systemctl enable --now bluetooth.service          2>/dev/null || true
  sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null || true
  systemctl --user enable --now pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
  # start light/dark from a known state so GTK/Qt/browsers have a color-scheme to follow
  command -v gsettings >/dev/null 2>&1 && gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
  ok "services enabled"
}

install_deps() {
  require_arch
  title "installing packages"
  info "official repos (pacman)…"
  sudo pacman -S --needed $NOCONFIRM "${REPO_PKGS[@]}" || warn "some repo packages didn't install — check the names/network above"
  local helper; helper="$(aur_helper)" || { bootstrap_paru && helper=paru || helper=""; }
  if [ -n "$helper" ]; then
    info "AUR ($helper)…"
    "$helper" -S --needed $NOCONFIRM "${AUR_PKGS[@]}" || warn "some AUR packages failed to build — see output above"
  else
    warn "no AUR helper and paru bootstrap failed — install these from the AUR yourself:"
    warn "  ${AUR_PKGS[*]}"
  fi
  enable_services
  install_moondrop_udev
  ok "packages done"
}

# Grant the logged-in user raw-HID access to Moondrop DACs so the EQ panel works
# without root. Harmless if you don't own one. Idempotent.
install_moondrop_udev() {
  local src="$SCRIPT_DIR/moondrophub_reverse/99-moondrop.rules"
  [ -f "$src" ] || return 0
  info "installing Moondrop DAC udev rule (raw-HID access without root)…"
  if sudo install -m 644 "$src" /etc/udev/rules.d/99-moondrop.rules 2>/dev/null; then
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo udevadm trigger 2>/dev/null || true
    ok "Moondrop udev rule installed (replug the DAC if it's connected)"
  else
    warn "couldn't install the Moondrop udev rule — the EQ panel will need root until you add it"
  fi
}

hypr_block() {
  # $1 = absolute dir the sea-shell .lua files live in. Emits the Lua block dofile'd from
  # hyprland.lua (Hyprland 0.55+). idle daemon + polkit agent are runtime-guarded, so
  # installing the package later makes them work on the next login without re-running this.
  local block="dofile(\"$1/sea.lua\")
dofile(\"$1/keybinds.lua\")
hl.on(\"hyprland.start\", function()
    hl.exec_cmd(\"qs -c sea-shell\")
    hl.exec_cmd(\"command -v hypridle >/dev/null && exec hypridle\")
    hl.exec_cmd(\"[ -x /usr/lib/hyprpolkitagent/hyprpolkitagent ] && exec /usr/lib/hyprpolkitagent/hyprpolkitagent\")
    hl.exec_cmd(\"sleep 0.5; exec ~/.config/quickshell/sea-shell/sea-wallpaper-restore.sh\")
end)"
  printf '%s' "$block"
}

# Wire the sea-shell Lua block into ~/.config/hypr/hyprland.lua. sea-shell 5.0+ is Lua-only
# (hyprlang is dropped in Hyprland 0.57). $1 = absolute dir the .lua files live in.
wire_hypr_lua() {
  local lua="$CFG/hypr/hyprland.lua" conf="$CFG/hypr/hyprland.conf"
  remove_block "$conf"                         # migration: strip any old hyprlang sea-shell block
  if [ -f "$lua" ]; then
    add_block "$lua" "$(hypr_block "$1")" "$MARK_A_LUA" "$MARK_B_LUA"
  elif [ -f "$conf" ]; then
    warn "you're on a hyprlang hyprland.conf — sea-shell $SEA_VERSION is Lua-only (required at Hyprland 0.57)."
    warn "convert it to ~/.config/hypr/hyprland.lua, then re-run install. see $SCRIPT_DIR/hypr/README-lua.md"
  else
    # truly fresh (no hyprland.lua and no hyprland.conf) — drop in the shipped starter config
    if [ -f "$SCRIPT_DIR/hypr/hyprland.lua" ]; then
      cp "$SCRIPT_DIR/hypr/hyprland.lua" "$lua"; ok "installed starter ~/.config/hypr/hyprland.lua"
    else
      printf '%s\n' '-- Hyprland config (Lua). sea-shell owns the block below; add monitors/input above.' \
        'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })' \
        'hl.config({ input = { kb_layout = "us" } })' > "$lua"
    fi
    add_block "$lua" "$(hypr_block "$1")" "$MARK_A_LUA" "$MARK_B_LUA"
    warn "installed a starter ~/.config/hypr/hyprland.lua — tweak monitors/keyboard to taste"
  fi
}

do_install() {
  [ "${NO_DEPS:-0}" = "1" ] || install_deps      # packages first (Arch-gated); --no-deps skips
  title "installing sea-shell v$SEA_VERSION from ${SCRIPT_DIR/#$HOME/\~}"
  check_deps
  mkdir -p "$DATA_DIR"
  # seed the (empty) matugen border override so sea.lua's dofile of it never dangles
  mkdir -p "$HYPR_DEST"; [ -e "$HYPR_DEST/matugen.lua" ] || : > "$HYPR_DEST/matugen.lua"
  # sea-shell 5.0+ is Lua-only — purge legacy hyprlang compositor configs left by an older install
  for stale in "$HYPR_DEST/sea.conf" "$HYPR_DEST/keybinds.conf" "$HYPR_DEST/matugen.conf"; do
    [ -e "$stale" ] && { rm -f "$stale"; info "removed legacy ${stale/#$HOME/\~}"; }
  done
  [ -e "$HYPR_DEST/hyprlock-colors.conf" ] || printf '# sea-shell default lockscreen colors\n$accent = rgba(63c7ddcc)\n$accentAlpha = 63c7dd\n$frost = rgba(a2e2e8ff)\n$frostAlpha = a2e2e8\n' > "$HYPR_DEST/hyprlock-colors.conf"
  # remember where the repo lives so GUI edits (keybind rebinds) can sync back to it
  printf '%s' "$SCRIPT_DIR" > "$DATA_DIR/.repo"

  if [ "${DEV:-0}" = "1" ]; then
    # ---- developer mode: live-edit the repo, configs follow instantly ----
    deploy_qs link
    wire_hypr_lua "$SCRIPT_DIR/hypr"
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
    deploy_qs copy
    # 1) Hyprland look + keybinds (Lua), dofile'd from hyprland.lua. See hypr/README-lua.md.
    mkdir -p "$HYPR_DEST"
    copy_file "$SCRIPT_DIR/hypr/sea.lua" "$HYPR_DEST/sea.lua"
    copy_file "$SCRIPT_DIR/hypr/keybinds.lua" "$HYPR_DEST/keybinds.lua"
    wire_hypr_lua "$HYPR_DEST"
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
  printf '%s' "$out" > "$DATA_DIR/wallpaper"
  if "$SCRIPT_DIR/quickshell/scripts/wallpaper/sea-wallpaper-restore.sh" 2>/dev/null; then
    ok "wallpaper set (and restored on every login)"
  else warn "install 'swww' (or awww) for the wallpaper to apply + restore on login"; fi
}

do_uninstall() {
  title "uninstalling sea-shell"
  pkill -xf "qs -c sea-shell" 2>/dev/null
  remove_block "$CFG/hypr/hyprland.lua"     # Lua entry (5.0+)
  remove_block "$CFG/hypr/hyprland.conf"    # legacy hyprlang entry (pre-5.0)
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

# ---- args (flags combine, e.g. `--no-deps --wallpaper`) ----
ACTION=install
for arg in "$@"; do
  case "$arg" in
    --uninstall|-u) ACTION=uninstall ;;
    --deps)         ACTION=deps ;;
    --no-deps)      NO_DEPS=1 ;;
    --dev)          DEV=1 ;;
    --wallpaper)    WALLPAPER=1 ;;
    -y|--yes)       ASSUME_YES=1 ;;
    -h|--help)      ACTION=help ;;
    *) warn "unknown option: $arg"; ACTION=help ;;
  esac
done
# non-interactive when asked (-y) or when there's no terminal to prompt on (piped install)
if [ "${ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then NOCONFIRM="--noconfirm"; else NOCONFIRM=""; fi

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  deps)      install_deps ;;
  help)      sed -n '2,14p' "$0" ;;
esac
