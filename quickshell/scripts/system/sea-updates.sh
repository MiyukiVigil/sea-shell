#!/bin/sh
# sea-shell — pending package updates, repo + AUR.
#
#   sea-updates.sh          print the update list (see format below)
#   sea-updates.sh count    print just "<repo> <aur>"
#
# Output, one record per line, pipe-delimited so the bar can parse it without a JSON pass:
#
#   <repoCount>|<aurCount>          <- always line 1, even when both are 0
#   R|name|oldver|newver            <- one per repo update
#   A|name|oldver|newver            <- one per AUR update
#
# `checkupdates` (pacman-contrib) is used rather than `pacman -Qu` because -Qu compares against
# whatever the local sync db happens to hold, which is stale until something runs `pacman -Sy` —
# so a machine that has not synced in a week honestly reports "0 updates". checkupdates syncs a
# PRIVATE temp db instead, which is why it is safe to run on a timer: it never touches the real
# db and therefore can never leave the system in a partial-upgrade state the way a bare `-Sy`
# would.
#
# Exit codes matter here: checkupdates exits 2 when there is nothing to do, NOT 0, so `|| exit`
# on it would silently blank the list every time the system is up to date.

have() { command -v "$1" >/dev/null 2>&1; }

repo=""
if have checkupdates; then
    # 2 = no updates (not an error). Anything else = a real failure; treat as empty.
    repo=$(checkupdates 2>/dev/null)
fi

aur=""
if have paru; then
    aur=$(paru -Qua 2>/dev/null)
elif have yay; then
    aur=$(yay -Qua 2>/dev/null)
fi

# `grep -c .` rather than `wc -l`: an empty string still counts as one line under wc.
rc=$(printf '%s' "$repo" | grep -c . 2>/dev/null || echo 0)
ac=$(printf '%s' "$aur"  | grep -c . 2>/dev/null || echo 0)

[ "${1:-}" = "count" ] && { printf '%s %s\n' "$rc" "$ac"; exit 0; }

printf '%s|%s\n' "$rc" "$ac"

# Lines look like: "name 1.2.3-1 -> 1.2.4-1". Split on the arrow so versions containing spaces
# (there are none in practice, but epochs and -git suffixes get close) cannot shift the columns.
emit() {
    src="$1"
    printf '%s\n' "$2" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=${line%% *}
        rest=${line#* }
        old=${rest%% -> *}
        new=${rest##* -> }
        printf '%s|%s|%s|%s\n' "$src" "$name" "$old" "$new"
    done
}

[ -n "$repo" ] && emit R "$repo"
[ -n "$aur" ]  && emit A "$aur"
exit 0
