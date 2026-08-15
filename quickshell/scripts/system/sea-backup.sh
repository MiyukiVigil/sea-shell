#!/bin/sh
# sea-shell — back up and restore everything the shell owns.
#
#   sea-backup.sh create [dir]     write sea-shell-backup-<host>-<date>.tar.gz (default: ~/Documents)
#   sea-backup.sh restore <file>   restore from an archive (existing config is saved first)
#   sea-backup.sh list [dir]       list archives found
#
# What goes in, and what deliberately does not:
#
#   IN   ~/.config/sea-shell/          every setting, pins, rules, gestures, usage history,
#                                      notification history/mutes, timers, bar layouts
#        ~/.config/hypr/sea-shell/     sea.lua, keybinds.lua and the generated matugen/rules/
#                                      gestures lua (keybinds.lua in particular may hold edits)
#        ~/.config/hypr/hyprland.lua   your main config, which carries the sea-shell block
#        ~/.config/hypr/hyprlock.conf  lock screen
#        ~/.config/hypr/hypridle.conf  idle rules
#
#   OUT  ~/.config/quickshell/sea-shell/   deployed FROM the repo by install.sh. Backing it up
#                                          would restore a stale copy of code over a newer one,
#                                          which is worse than not backing it up at all.
#        wallpaper image files             potentially gigabytes of video; the PATH is saved in
#                                          the config, the file stays where it is.
#
# Restore never overwrites blind: it tars the current config to a .pre-restore archive first, so
# a restore that turns out to be the wrong one is itself undoable.

set -u

STAMP_HOST=$(hostname 2>/dev/null || echo host)
DEFAULT_DIR="$HOME/Documents"

paths() {
    # printed one per line, relative to $HOME so the archive is portable between users
    for p in \
        ".config/sea-shell" \
        ".config/hypr/sea-shell" \
        ".config/hypr/hyprland.lua" \
        ".config/hypr/hyprlock.conf" \
        ".config/hypr/hypridle.conf"
    do
        [ -e "$HOME/$p" ] && printf '%s\n' "$p"
    done
}

cmd_create() {
    dir="${1:-$DEFAULT_DIR}"
    mkdir -p "$dir" || { echo "cannot write to $dir" >&2; exit 1; }
    date_s=$(date +%Y%m%d-%H%M%S)
    out="$dir/sea-shell-backup-$STAMP_HOST-$date_s.tar.gz"

    list=$(paths)
    [ -z "$list" ] && { echo "nothing to back up — no sea-shell config found" >&2; exit 1; }

    # A manifest inside the archive so a restore can tell you what it is before you commit.
    tmp=$(mktemp -d) || exit 1
    {
        echo "sea-shell backup"
        echo "created: $(date '+%F %T')"
        echo "host:    $STAMP_HOST"
        echo "version: $(cat "$HOME/.config/quickshell/sea-shell/VERSION" 2>/dev/null || echo unknown)"
        echo "paths:"
        printf '  %s\n' $list
    } > "$tmp/MANIFEST"

    # -C "$HOME" so members are stored relative; MANIFEST is added from its own dir.
    tar -czf "$out" -C "$tmp" MANIFEST -C "$HOME" $list 2>/dev/null || {
        rm -rf "$tmp"; echo "archive failed" >&2; exit 1; }
    rm -rf "$tmp"

    sz=$(du -h "$out" 2>/dev/null | cut -f1)
    echo "$out"
    echo "size: ${sz:-?}"
    notify-send 'sea-shell' "Backup written to $out" 2>/dev/null
}

cmd_restore() {
    src="${1:-}"
    [ -f "$src" ] || { echo "usage: $0 restore <file.tar.gz>" >&2; exit 2; }
    tar -tzf "$src" >/dev/null 2>&1 || { echo "not a readable tar.gz: $src" >&2; exit 1; }

    # Safety net FIRST: the current config becomes its own archive before anything is replaced.
    pre="$HOME/Documents/sea-shell-pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$HOME/Documents"
    list=$(paths)
    [ -n "$list" ] && tar -czf "$pre" -C "$HOME" $list 2>/dev/null

    # Extract everything except the manifest, which is metadata rather than config.
    tar -xzf "$src" -C "$HOME" --exclude MANIFEST 2>/dev/null || {
        echo "restore failed" >&2; exit 1; }

    # Regenerate the derived Lua from the restored JSON, then reload, so the session matches the
    # files immediately instead of at the next login.
    for g in sea-window-rules.sh sea-gestures.sh; do
        [ -x "$HOME/.config/quickshell/sea-shell/$g" ] && sh "$HOME/.config/quickshell/sea-shell/$g" >/dev/null 2>&1
    done
    hyprctl reload >/dev/null 2>&1

    echo "restored from $src"
    [ -n "$list" ] && echo "previous config saved to $pre"
    notify-send 'sea-shell' 'Config restored — restart the bar to pick everything up' 2>/dev/null
}

cmd_list() {
    dir="${1:-$DEFAULT_DIR}"
    found=0
    for f in "$dir"/sea-shell-backup-*.tar.gz "$dir"/sea-shell-pre-restore-*.tar.gz; do
        [ -f "$f" ] || continue
        found=1
        printf '%s|%s|%s\n' "$f" "$(du -h "$f" 2>/dev/null | cut -f1)" \
            "$(date -r "$f" '+%F %H:%M' 2>/dev/null)"
    done
    [ "$found" = 0 ] && exit 0
    exit 0
}

case "${1:-}" in
    create)  shift; cmd_create "${1:-}" ;;
    restore) shift; cmd_restore "${1:-}" ;;
    list)    shift; cmd_list "${1:-}" ;;
    *) echo "usage: $0 create [dir] | restore <file> | list [dir]" >&2; exit 2 ;;
esac
