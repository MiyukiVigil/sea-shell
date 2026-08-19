#!/usr/bin/env bash
# sea-shell installer — installs the sea-cyan rice into ~/.config so it works
# on every login with no dependence on where this repo lives.
# Idempotent + reversible.  Usage:
#   ./install.sh              # full install: packages (pacman + AUR) THEN configs
#   ./install.sh --deps       # only install the packages, touch no configs
#   ./install.sh --no-deps    # skip packages, only lay down configs (works on any distro)
#   ./install.sh --dev        # developer mode: symlink configs to this repo instead
#   ./install.sh --hubmoon    # also install Hub Moon (EQ + DAC control) without asking
#   ./install.sh --no-hubmoon # never ask about Hub Moon
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
# Install a file that something ELSE rewrites after we lay it down — the theme pipeline, or
# the control center. Copying over one of these on every re-install is how a reinstall quietly
# reverts work the user already did. copy_file cannot be used: it suppresses its own backup for
# any file containing "sea-shell", which these all do, so the old content went nowhere at all.
#
# The shipped copy still lands on a machine that has none. It just never overwrites a live one.
keep_file() {
  local src="$1" dest="$2" why="$3"
  mkdir -p "$(dirname "$dest")"
  [ -L "$dest" ] && rm -f "$dest"          # an old --dev symlink is ours to replace
  if [ ! -e "$dest" ]; then
    install -m 644 "$src" "$dest"; ok "installed ${dest/#$HOME/\~}"
  elif cmp -s "$src" "$dest"; then
    ok "up to date ${dest/#$HOME/\~}"
  else
    info "kept your ${dest/#$HOME/\~} — $why"
  fi
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
  # Stamp the release alongside the code. Without this a backup archive made months later has
  # no idea which version produced it, which is exactly when you need to know.
  printf '%s\n' "$SEA_VERSION" > "$dest/VERSION"
  # Record where this repo lives so the OTA updater can find it later. install.sh explicitly
  # allows the repo to be moved or deleted afterwards, so the deployed copy has no other way
  # of knowing where its source is.
  printf '%s\n' "$SCRIPT_DIR" > "$dest/REPO_PATH"
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
  python-pykakasi pypinyin                            # lyrics pronunciation — kana/kanji→romaji, hanzi→pinyin (both offline)
  translate-shell                                     # lyrics translation (Google's unofficial endpoint; optional, degrades quietly)
)
# AUR packages — need an AUR helper (paru/yay); bootstrapped below if absent.
AUR_PKGS=(
  quickshell                          # the bar/launcher/overlays engine — the heart of it
  matugen                             # wallpaper→accent theming ("match colours")
  ttf-material-symbols-variable       # the bar's icon font (stable pkg; the -git one won't build)
  swww                                # static / image wallpapers
  mpvpaper                            # animated (video) wallpapers
  python-syncedlyrics                 # second-chance lyrics lookup (NetEase · Musixmatch) when lrclib misses
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
  ok "packages done"
}

# Grant the logged-in user raw-HID access to Moondrop DACs so the EQ panel works
# without root. Harmless if you don't own one. Idempotent.

hypr_block() {
  # $1 = absolute dir the sea-shell .lua files live in. Emits the Lua block dofile'd from
  # hyprland.lua (Hyprland 0.55+). idle daemon + polkit agent are runtime-guarded, so
  # installing the package later makes them work on the next login without re-running this.
  local block="dofile(\"$1/sea.lua\")
dofile(\"$1/keybinds.lua\")
hl.on(\"hyprland.start\", function()
    hl.exec_cmd(\"sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh\")
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
    # Link the TEMPLATE, never ~/.config/starship.toml itself: the theme pipeline generates the
    # live prompt from the template and would replace the symlink with a real file on the first
    # accent change — silently seeding the template from the repo copy in the process.
    ln -sfn "$SCRIPT_DIR/starship/sea.toml" "$DATA_DIR/starship-default.toml"
    ok "linked ~/.config/sea-shell/starship-default.toml → repo"
    [ -e "$CFG/starship.toml" ] || { install -m 644 "$SCRIPT_DIR/starship/sea.toml" "$CFG/starship.toml"; ok "seeded ~/.config/starship.toml"; }
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
    # 3) starship prompt (fish already runs `starship init fish`).
    #    ~/.config/starship.toml is GENERATED, not installed: matugen-accent.sh substitutes the
    #    wallpaper palette into starship-default.toml to produce it. Writing the shipped file
    #    over the top is exactly what made every re-install revert the prompt to the default
    #    cyan while the rest of the desktop stayed on the wallpaper's accent. So the shipped
    #    copy updates the TEMPLATE, and the live prompt is only seeded when there isn't one.
    install -m 644 "$SCRIPT_DIR/starship/sea.toml" "$DATA_DIR/starship-default.toml"
    ok "installed ~/.config/sea-shell/starship-default.toml"
    if [ ! -e "$CFG/starship.toml" ] || [ -L "$CFG/starship.toml" ]; then
      rm -f "$CFG/starship.toml"
      install -m 644 "$SCRIPT_DIR/starship/sea.toml" "$CFG/starship.toml"
      ok "installed ~/.config/starship.toml"
    else
      info "kept your themed ~/.config/starship.toml — regenerated from the template on the next accent change"
    fi
    # 4) lock screen + idle daemon (canonical paths — hyprlock/hypridle only read these).
    #    Both are edited in place by the control center's lock settings, so they are kept.
    keep_file "$SCRIPT_DIR/hypr/hyprlock.conf" "$CFG/hypr/hyprlock.conf" "edited by Control center → Idle & power"
    keep_file "$SCRIPT_DIR/hypr/hypridle.conf" "$CFG/hypr/hypridle.conf" "edited by Control center → Idle & power"
  fi

  # 3) wallpaper: install the repo one if present; --wallpaper regenerates it
  [ -f "$SCRIPT_DIR/sea-wall.png" ] && copy_file "$SCRIPT_DIR/sea-wall.png" "$DATA_DIR/sea-wall.png"
  if [ "${WALLPAPER:-0}" = "1" ]; then set_wallpaper; fi

  # 4) apply live: reload hyprland + (re)start the bar from the installed config
  if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    hyprctl reload >/dev/null 2>&1
    # The restart has to go through Hyprland: anything this script backgrounds itself dies when
    # install.sh exits. Under a Lua config (Hyprland 0.55+) the old `hyprctl dispatch exec ...`
    # form is a Lua SYNTAX ERROR — "[string \"return hl.dispatch(exec sh ...)\"]:1: ')' expected".
    # That error went to /dev/null and success was printed unconditionally, so for months this
    # said "bar restarted" while leaving the old process running the previous code. Hence both
    # the correct dispatch form AND an actual check that a new pid appeared.
    _sup="sh \$HOME/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"
    _oldbar=$(pgrep -xf "qs -c sea-shell" 2>/dev/null | head -1)
    if ! hyprctl dispatch "hl.dsp.exec_cmd('$_sup')" 2>&1 | grep -q '^ok'; then
      # pre-0.55 .conf parser, where the Lua form is the one that does not exist
      hyprctl dispatch exec "$_sup" >/dev/null 2>&1
    fi
    _i=0; _newbar=""
    while [ "$_i" -lt 30 ]; do
      _newbar=$(pgrep -xf "qs -c sea-shell" 2>/dev/null | head -1)
      [ -n "$_newbar" ] && [ "$_newbar" != "$_oldbar" ] && break
      _i=$((_i + 1)); sleep 0.2
    done
    # A new pid is NOT proof of a working bar. A QML error makes qs exit ~instantly and the
    # supervisor respawns it, so "a different pid appeared" is exactly what a crash loop looks
    # like from out here. Confirm the same pid is still alive a moment later.
    if [ -n "$_newbar" ] && [ "$_newbar" != "$_oldbar" ]; then
      sleep 2
      if kill -0 "$_newbar" 2>/dev/null; then
        ok "hyprland reloaded, bar restarted (pid $_newbar)"
      else
        warn "the bar started and immediately exited — that is a QML error, not a restart problem."
        warn "see the error with:  qs -c sea-shell"
      fi
    else
      warn "hyprland reloaded, but the bar did not come back — start it with:"
      warn "  sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"
    fi
  else
    info "not inside a Hyprland session — everything starts on next login"
  fi

  maybe_install_hubmoon

  title "done — log out/in (or reboot) and sea-shell comes up by itself"
  [ "${DEV:-0}" = "1" ] && warn "dev mode: configs point at this repo — don't move/delete it" \
                        || info "repo can be moved/deleted; re-run ./install.sh after pulling updates"
}

# ---- Hub Moon (optional) --------------------------------------------------------------
# sea-shell used to carry a parametric EQ and a Moondrop DAC controller. It does not any
# more: that is a whole application's worth of problem and Hub Moon is that application.
# This offers to install it and is happy to be told no — nothing in the shell depends on it.
#
# LATEST, resolved at install time rather than pinned: /releases/latest is GitHub's own
# answer and it excludes pre-releases, so a beta channel does not become everybody's install.
HUBMOON_REPO="MiyukiVigil/Moon_Hub"

hubmoon_asset() {
  # $1 = a grep pattern for the asset name. Prints the first matching browser_download_url.
  curl -fsSL --max-time 25 "https://api.github.com/repos/$HUBMOON_REPO/releases/latest" 2>/dev/null \
    | python3 -c '
import json, re, sys
try:
    rel = json.load(sys.stdin)
except Exception:
    sys.exit(1)
pat = re.compile(sys.argv[1])
for a in rel.get("assets") or []:
    if pat.search(a.get("name") or ""):
        print(a.get("browser_download_url") or "")
        break
' "$1" 2>/dev/null
}

install_hubmoon() {
  command -v curl >/dev/null 2>&1 || { warn "hub moon needs curl to download — skipping"; return 0; }

  info "asking github for the latest Hub Moon release…"
  local url="" tmp=""
  if command -v pacman >/dev/null 2>&1; then
    url="$(hubmoon_asset '\.pkg\.tar\.zst$')"
  fi
  # Not Arch, or the release has no Arch package: the AppImage runs anywhere.
  [ -n "$url" ] || url="$(hubmoon_asset '\.AppImage$')"
  [ -n "$url" ] || { warn "no installable Hub Moon asset in the latest release — get it from https://hubmoon.miyukivigil.tech"; return 0; }

  tmp="$(mktemp -d)" || return 0
  local file="$tmp/$(basename "${url%%\?*}")"
  info "downloading $(basename "$file")…"
  if ! curl -fL --progress-bar --max-time 300 -o "$file" "$url"; then
    warn "download failed — get it from https://hubmoon.miyukivigil.tech"
    rm -rf "$tmp"; return 0
  fi

  case "$file" in
    *.pkg.tar.zst)
      # -U on a file, not -S: this is not in any repo, and pacman is the only thing that
      # should be putting files under /usr on an Arch system.
      if sudo pacman -U $NOCONFIRM "$file"; then ok "Hub Moon installed"
      else warn "pacman refused it — install manually: sudo pacman -U $file"; rm -rf "$tmp"; return 0; fi
      ;;
    *.AppImage)
      mkdir -p "$HOME/.local/bin"
      install -m 755 "$file" "$HOME/.local/bin/hub-moon" \
        && ok "Hub Moon installed to ~/.local/bin/hub-moon" \
        || warn "could not install the AppImage"
      case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add ~/.local/bin to your PATH to run it" ;; esac
      ;;
  esac
  rm -rf "$tmp"
}

# Asked, never assumed. A desktop shell installer that pulls in an unrelated application
# because it happens to share an author is the kind of thing people uninstall both over.
maybe_install_hubmoon() {
  [ "${HUBMOON:-0}" = "1" ] && { install_hubmoon; return 0; }
  [ "${NO_HUBMOON:-0}" = "1" ] && return 0
  # No terminal to ask on (piped install) means no: silence is not consent.
  [ -t 0 ] || return 0
  printf '\n%s🌙 Hub Moon — parametric EQ and Moondrop DAC control, by the same author.%s\n' \
    "$(c '1;38;2;162;226;232')" "$(c 0)"
  printf '   sea-shell dropped its own EQ in 6.2; this is the replacement, and it is optional.\n'
  printf '   install it? [y/N] '
  read -r _hm
  case "$_hm" in [Yy]*) install_hubmoon ;; *) info "skipped — install it later from https://hubmoon.miyukivigil.tech" ;; esac
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
  # stop the supervisor first, or it just respawns the bar we are removing
  [ -f "${XDG_RUNTIME_DIR:-/tmp}/sea-shell-supervisor.pid" ] && \
    kill "$(cat "${XDG_RUNTIME_DIR:-/tmp}/sea-shell-supervisor.pid")" 2>/dev/null
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
    --hubmoon)      HUBMOON=1 ;;
    --no-hubmoon)   NO_HUBMOON=1 ;;
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
