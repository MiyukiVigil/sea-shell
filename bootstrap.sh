#!/usr/bin/env bash
# sea-shell one-line installer — clones the repo, then hands off to install.sh.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh)
#
# Pass installer flags straight through, e.g. add a wallpaper or go non-interactive:
#   bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh) --wallpaper
#   bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh) -y
#
# Use process substitution `bash <(…)`, NOT `curl … | bash`: the pipe steals stdin, so
# sudo/pacman/makepkg can't prompt. Arch-based distros only (needs pacman + the AUR).
set -euo pipefail

REPO="https://github.com/MiyukiVigil/sea-shell.git"
DIR="${SEASHELL_DIR:-$HOME/.local/share/sea-shell}"

c()   { printf '\033[%sm' "$1"; }
say() { printf '%s»%s %s\n'  "$(c '38;2;99;199;221')"  "$(c 0)" "$*"; }
die() { printf '%s✗%s %s\n'  "$(c '38;2;244;110;110')" "$(c 0)" "$*" >&2; exit 1; }

command -v pacman >/dev/null 2>&1 || die "sea-shell is Arch-only (it installs from pacman + the AUR). Aborting."
command -v git    >/dev/null 2>&1 || { say "installing git…"; sudo pacman -S --needed --noconfirm git; }

if [ -d "$DIR/.git" ]; then
  say "updating existing checkout at ${DIR/#$HOME/\~}…"
  git -C "$DIR" pull --ff-only || die "git pull failed — sort it out in $DIR and re-run"
else
  say "cloning sea-shell → ${DIR/#$HOME/\~}…"
  git clone --depth 1 "$REPO" "$DIR"
fi

say "handing off to the installer…"
exec bash "$DIR/install.sh" "$@"
