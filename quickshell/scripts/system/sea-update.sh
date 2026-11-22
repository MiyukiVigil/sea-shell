#!/bin/sh
# sea-shell — over-the-air updates.
#
#   sea-update.sh check       one line: state|installedVer|remoteVer|behind|detail
#   sea-update.sh changes     what the waiting update changes, from the changelog (markdown)
#   sea-update.sh drift       deployed config files that differ from the repo, one per line
#   sea-update.sh start       begin an update in the background, detached from the bar
#   sea-update.sh undo        put the snapshot from before the last update back, in the background
#   sea-update.sh status      the state file: phase|from|to|detail
#   sea-update.sh undoable    the version `undo` would go back to, if any
#
# states: uptodate · available · pending · ahead · diverged · dirty · norepo · offline
#
# Four things make this awkward, and all are handled rather than assumed away:
#
#  1. THE DEPLOYED COPY DOES NOT KNOW WHERE THE REPO IS. install.sh copies files out of the repo
#     and explicitly tells you the repo can then be moved or deleted. So install.sh records its
#     own location in REPO_PATH next to the deployed files, and this script reads that. If the
#     repo is gone, that is reported plainly instead of failing with a confusing git error.
#
#  2. A DIRTY OR AHEAD TREE MUST NEVER BE STEAMROLLED. This repo is somebody's working copy, not
#     a read-only channel. The update will not run if the tree is dirty, ahead of the remote, or
#     diverged; it only ever fast-forwards. Losing someone's unpushed work to an auto-updater is
#     unforgivable, so the bar can only ever offer the update, never take it.
#
#  3. THE UPDATER RUNS INSIDE WHAT IT REPLACES. Settings lives in the bar's process and install.sh
#     restarts the bar, which took the update down with it the moment it got that far. `start`
#     detaches first, keeps its progress in a file, and the new bar reads the result from there.
#
#  4. A BAD UPDATE MUST NOT LEAVE YOU WITHOUT A DESKTOP. The shell is snapshotted before anything
#     changes and the bar is watched afterwards. If it won't stay up the snapshot goes back by
#     itself. The repo stays where it is (git history is its owner's business), so the update
#     shows as "pending" and can be tried again.
#
# Checking uses `git fetch` when the repo is present. It never prompts: BatchMode + no terminal
# prompt + a connect timeout, so a missing SSH key or a dead network fails fast as "offline"
# rather than hanging a background process forever.

QSD="$HOME/.config/quickshell/sea-shell"
HYD="$HOME/.config/hypr/sea-shell"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sea-shell"
SNAP_DIR="$STATE_DIR/update-snapshots"
STATUS="$STATE_DIR/update-status"
LOG="$STATE_DIR/update.log"
KEEP_SNAPSHOTS=3
REPO=$(cat "$QSD/REPO_PATH" 2>/dev/null)
LOCAL_VER=$(cat "$QSD/VERSION" 2>/dev/null || echo "?")
SELF=$(readlink -f "$0")

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

out() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5"; }
say() { mkdir -p "$STATE_DIR"; printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"; }

# ---- commands that don't need the repo ----
case "${1:-check}" in
status) cat "$STATUS" 2>/dev/null; exit 0 ;;
undoable)
    last=$(ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r | head -1)
    [ -n "$last" ] && cat "$last/VERSION" 2>/dev/null
    exit 0 ;;
start|undo)
    mkdir -p "$STATE_DIR"
    case "$1" in start) job=_apply ;; undo) job=_undo ;; esac
    say working "$LOCAL_VER" "" "Starting…"
    # setsid: a new session, so restarting the bar doesn't take this down with it.
    setsid sh "$SELF" "$job" >>"$LOG" 2>&1 </dev/null &
    exit 0 ;;
esac

snapshot() {
    # $1 = version it holds. The shell plus the Hyprland files install.sh overwrites; settings
    # live elsewhere and an update doesn't touch them.
    snap="$SNAP_DIR/$(date +%Y%m%d-%H%M%S)-$1"
    mkdir -p "$snap/hypr" || return 1
    cp -a "$QSD" "$snap/qs" || { rm -rf "$snap"; return 1; }
    for f in sea.lua keybinds.lua; do
        [ -f "$HYD/$f" ] && cp -a "$HYD/$f" "$snap/hypr/$f"
    done
    printf '%s\n' "$1" > "$snap/VERSION"
    # shellcheck disable=SC2012
    ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP_SNAPSHOTS + 1)) | while IFS= read -r old; do
        rm -rf "$old"
    done
    printf '%s\n' "$snap"
}
latest_snapshot() { ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r | head -1 | sed 's:/$::'; }

restart_bar() {
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
    sup="sh $QSD/sea-bar-supervisor.sh --restart"
    hyprctl dispatch "hl.dsp.exec_cmd('$sup')" 2>&1 | grep -q '^ok' || hyprctl dispatch exec "$sup" >/dev/null 2>&1
}
bar_pid() { pgrep -f '(^|/)(seashell|qs|quickshell)( -[^ ]+)* -c sea-shell$' | head -1; }
# A QML error makes qs exit at once and the supervisor respawn it, so a pid existing proves
# nothing. The same pid surviving a while does. Outside a session there is no bar to judge.
bar_stays_up() {
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
    sleep "${SEA_UPDATE_SETTLE:-3}"
    first=$(bar_pid)
    [ -n "$first" ] || return 1
    sleep "${SEA_UPDATE_WATCH:-8}"
    [ "$(bar_pid)" = "$first" ]
}
restore() {
    # $1 = snapshot. Swapped in whole, for the same reason install.sh does it that way.
    tmp="$QSD.undo.$$"
    rm -rf "$tmp"; cp -a "$1/qs" "$tmp" || return 1
    rm -rf "$QSD.old.$$"
    [ -d "$QSD" ] && mv "$QSD" "$QSD.old.$$"
    mv "$tmp" "$QSD" || return 1
    rm -rf "$QSD.old.$$"
    for f in sea.lua keybinds.lua; do
        [ -f "$1/hypr/$f" ] && cp -a "$1/hypr/$f" "$HYD/$f"
    done
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && hyprctl reload >/dev/null 2>&1
    restart_bar
}

case "${1:-check}" in
_undo)
    snap=$(latest_snapshot)
    [ -n "$snap" ] || { say failed "$LOCAL_VER" "" "There's no earlier version saved."; exit 1; }
    was=$(cat "$snap/VERSION" 2>/dev/null || echo "?")
    say working "$LOCAL_VER" "$was" "Going back to $was…"
    if restore "$snap"; then
        rm -rf "$snap"
        say undone "$LOCAL_VER" "$was" "Back on $was."
        notify-send 'sea-shell' "Back on $was" 2>/dev/null
    else
        say failed "$LOCAL_VER" "$was" "Couldn't put $was back. See $LOG"
        notify-send -u critical 'sea-shell' "Couldn't go back to $was" 2>/dev/null
        exit 1
    fi
    exit 0 ;;
esac

# ---- no repo: we can still say whether something newer exists ----
if [ -z "$REPO" ] || [ ! -d "$REPO/.git" ]; then
    out norepo "$LOCAL_VER" "?" 0 "The sea-shell repo isn't at ${REPO:-its old location} any more. Clone it and run install.sh to turn updates on."
    exit 0
fi

cd "$REPO" 2>/dev/null || { out norepo "$LOCAL_VER" "?" 0 "Can't open $REPO."; exit 0; }

REPO_VER=$(cat VERSION 2>/dev/null || echo "$LOCAL_VER")

# Deployed, committed, and not the same thing: pulled by hand and never installed, or put back
# after a bad update. Dev-mode links follow the repo by themselves, so they never count.
needs_install() {
    [ -L "$QSD/settings.qml" ] && return 1
    [ -f "$QSD/INSTALLED_COMMIT" ] && [ "$(cat "$QSD/INSTALLED_COMMIT")" != "$(git rev-parse HEAD 2>/dev/null)" ] && return 0
    [ "$REPO_VER" != "$LOCAL_VER" ]
}

case "${1:-check}" in
check)
    if ! timeout 30 git fetch --quiet origin 2>/dev/null; then
        out offline "$LOCAL_VER" "?" 0 "Couldn't reach the remote. There's no network, or the SSH key isn't loaded."
        exit 0
    fi
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
        out norepo "$LOCAL_VER" "?" 0 "This branch doesn't track a remote."; exit 0; }

    behind=$(git rev-list --count HEAD.."$up" 2>/dev/null || echo 0)
    ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null || echo 0)
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # the VERSION file as it exists on the remote — what you would be upgrading TO
    remote_ver=$(git show "$up:VERSION" 2>/dev/null | tr -d '\n\r' || echo "?")

    if [ "$dirty" -gt 0 ] && [ "$behind" -gt 0 ]; then
        out dirty "$LOCAL_VER" "$remote_ver" "$behind" "An update is waiting, but $dirty files in the repo aren't committed. Commit or stash them first."
    elif [ "$dirty" -gt 0 ]; then
        out dirty "$LOCAL_VER" "$remote_ver" 0 "$dirty files in the repo aren't committed, so updates stay off until they are."
    elif [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
        out diverged "$LOCAL_VER" "$remote_ver" "$behind" "This repo and the remote have both moved on ($ahead ahead, $behind behind). That needs sorting out by hand."
    elif [ "$behind" -gt 0 ]; then
        out available "$LOCAL_VER" "$remote_ver" "$behind" "$behind new commits on $up."
    elif needs_install; then
        out pending "$LOCAL_VER" "$REPO_VER" 0 "The repo has $REPO_VER, but it isn't installed yet."
    elif [ "$ahead" -gt 0 ]; then
        out ahead "$LOCAL_VER" "$remote_ver" 0 "$ahead local commits haven't been pushed."
    else
        out uptodate "$LOCAL_VER" "$remote_ver" 0 "You have the latest version."
    fi
    ;;

changes)
    # The changelog is written for people, commit subjects for the author. Falls back to those
    # only if the version isn't in the changelog.
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    behind=0; [ -n "$up" ] && behind=$(git rev-list --count HEAD.."$up" 2>/dev/null || echo 0)
    if [ "$behind" -gt 0 ]; then log=$(git show "$up:CHANGELOG.md" 2>/dev/null); else log=$(cat CHANGELOG.md 2>/dev/null); fi
    text=$(printf '%s\n' "$log" | awk -v have="$LOCAL_VER" '
        /^## \[/ { v = $2; gsub(/[\[\]]/, "", v); if (v == have) exit; on = 1 }
        on { print }')
    if [ -n "$text" ]; then
        printf '%s\n' "$text"
    elif [ "$behind" -gt 0 ]; then
        git log --format='- %s' HEAD.."$up" 2>/dev/null
    fi
    ;;

drift)
    # What an update would replace that isn't what the repo shipped. install.sh keeps a dated
    # copy of these two, but it should be no surprise.
    for f in sea.lua keybinds.lua; do
        [ -f "hypr/$f" ] && [ -f "$HYD/$f" ] && ! cmp -s "hypr/$f" "$HYD/$f" && echo "$f"
    done
    ;;

_apply)
    fail() { say failed "$LOCAL_VER" "$2" "$1"; notify-send -u critical 'sea-shell' "Update stopped: $1" 2>/dev/null; exit 1; }
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$dirty" -gt 0 ] && fail "$dirty files in the repo aren't committed." ""

    say working "$LOCAL_VER" "" "Checking for changes…"
    timeout 60 git fetch --quiet origin 2>/dev/null || fail "Couldn't reach the remote." ""

    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || fail "This branch doesn't track a remote." ""
    ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] && fail "$ahead local commits would need a merge." ""

    say working "$LOCAL_VER" "" "Saving the current version…"
    snap=$(snapshot "$LOCAL_VER") || fail "Couldn't save the current version, so nothing was changed." ""

    # --ff-only: this either fast-forwards cleanly or does nothing. No merge commits, no
    # conflict resolution from a background script.
    timeout 60 git merge --ff-only "$up" >/dev/null 2>&1 || fail "The repo couldn't fast-forward." ""

    new_ver=$(cat VERSION 2>/dev/null || echo "?")
    say working "$LOCAL_VER" "$new_ver" "Installing $new_ver…"
    # --no-deps: nobody is at a terminal to answer pacman. A package the new version wants shows
    # up in Needs attention instead.
    if ! bash ./install.sh --no-deps --no-hubmoon -y >>"$LOG" 2>&1; then
        restore "$snap"
        fail "$new_ver didn't install, so $LOCAL_VER was put back. See $LOG" "$new_ver"
    fi
    say working "$LOCAL_VER" "$new_ver" "Making sure the bar stays up…"
    if ! bar_stays_up; then
        restore "$snap"
        fail "The bar wouldn't stay up on $new_ver, so $LOCAL_VER was put back. See $LOG" "$new_ver"
    fi
    say updated "$LOCAL_VER" "$new_ver" "Updated to $new_ver."
    notify-send 'sea-shell' "Now on $new_ver" 2>/dev/null
    ;;
*)
    echo "usage: $0 check|changes|drift|start|undo|status|undoable" >&2; exit 2 ;;
esac
