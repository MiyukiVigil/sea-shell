#!/bin/sh
# sea-shell — over-the-air updates.
#
#   sea-update.sh check     one line: state|localVer|remoteVer|behind|detail
#   sea-update.sh apply     fetch, fast-forward, reinstall  (refuses unless it is safe)
#
# states: uptodate · available · ahead · diverged · dirty · norepo · offline
#
# Two things make this awkward, and both are handled rather than assumed away:
#
#  1. THE DEPLOYED COPY DOES NOT KNOW WHERE THE REPO IS. install.sh copies files out of the repo
#     and explicitly tells you the repo can then be moved or deleted. So install.sh now records
#     its own location in REPO_PATH next to the deployed files, and this script reads that. If the
#     repo is gone, that is reported plainly instead of failing with a confusing git error.
#
#  2. A DIRTY OR AHEAD TREE MUST NEVER BE STEAMROLLED. This repo is somebody's working copy, not
#     a read-only channel — right now it holds dozens of uncommitted files. `apply` will not run
#     if the tree is dirty, ahead of the remote, or diverged; it only ever fast-forwards. Losing
#     someone's unpushed work to an auto-updater is unforgivable, so the bar can only ever offer
#     the update, never take it.
#
# Checking uses `git fetch` when the repo is present. It never prompts: BatchMode + no terminal
# prompt + a connect timeout, so a missing SSH key or a dead network fails fast as "offline"
# rather than hanging a background process forever.

QSD="$HOME/.config/quickshell/sea-shell"
REPO=$(cat "$QSD/REPO_PATH" 2>/dev/null)
LOCAL_VER=$(cat "$QSD/VERSION" 2>/dev/null || echo "?")

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

out() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5"; }

# ---- no repo: we can still say whether something newer exists ----
if [ -z "$REPO" ] || [ ! -d "$REPO/.git" ]; then
    out norepo "$LOCAL_VER" "?" 0 "source repo not found${REPO:+ at $REPO} — clone it and re-run install.sh to enable updates"
    exit 0
fi

cd "$REPO" 2>/dev/null || { out norepo "$LOCAL_VER" "?" 0 "cannot enter $REPO"; exit 0; }

REPO_VER=$(cat VERSION 2>/dev/null || echo "$LOCAL_VER")

case "${1:-check}" in
check)
    if ! timeout 30 git fetch --quiet origin 2>/dev/null; then
        out offline "$REPO_VER" "?" 0 "could not reach the remote (no network, or the ssh key is not loaded)"
        exit 0
    fi
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
        out norepo "$REPO_VER" "?" 0 "this branch tracks no remote"; exit 0; }

    behind=$(git rev-list --count HEAD.."$up" 2>/dev/null || echo 0)
    ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null || echo 0)
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # the VERSION file as it exists on the remote — what you would be upgrading TO
    remote_ver=$(git show "$up:VERSION" 2>/dev/null | tr -d '\n\r' || echo "?")

    if [ "$dirty" -gt 0 ] && [ "$behind" -gt 0 ]; then
        out dirty "$REPO_VER" "$remote_ver" "$behind" "$behind update(s) waiting, but $dirty file(s) are uncommitted — commit or stash first"
    elif [ "$dirty" -gt 0 ]; then
        out dirty "$REPO_VER" "$remote_ver" 0 "$dirty uncommitted file(s) — nothing to pull, but the tree is not clean"
    elif [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
        out diverged "$REPO_VER" "$remote_ver" "$behind" "local and remote have both moved on ($ahead ahead, $behind behind) — resolve by hand"
    elif [ "$behind" -gt 0 ]; then
        out available "$REPO_VER" "$remote_ver" "$behind" "$behind new commit(s) on $up"
    elif [ "$ahead" -gt 0 ]; then
        out ahead "$REPO_VER" "$remote_ver" 0 "$ahead local commit(s) not pushed"
    else
        out uptodate "$REPO_VER" "$remote_ver" 0 "up to date with $up"
    fi
    ;;

apply)
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$dirty" -gt 0 ] && {
        out dirty "$REPO_VER" "?" 0 "refused — $dirty uncommitted file(s); commit or stash them first"
        notify-send -u critical 'sea-shell' "Update refused: $dirty uncommitted files in the repo" 2>/dev/null
        exit 1; }

    timeout 60 git fetch --quiet origin 2>/dev/null || {
        out offline "$REPO_VER" "?" 0 "could not reach the remote"; exit 1; }

    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
        out norepo "$REPO_VER" "?" 0 "no upstream"; exit 1; }
    ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] && {
        out diverged "$REPO_VER" "?" 0 "refused — $ahead local commit(s) would need a merge; not automating that"
        exit 1; }

    # --ff-only: this either fast-forwards cleanly or does nothing. No merge commits, no
    # conflict resolution from a background script.
    if ! timeout 60 git merge --ff-only "$up" >/dev/null 2>&1; then
        out diverged "$REPO_VER" "?" 0 "refused — could not fast-forward"
        exit 1
    fi

    new_ver=$(cat VERSION 2>/dev/null || echo "?")
    notify-send 'sea-shell' "Updated to $new_ver — reinstalling…" 2>/dev/null
    if sh ./install.sh >/tmp/sea-update-install.log 2>&1; then
        out uptodate "$new_ver" "$new_ver" 0 "updated and reinstalled"
        notify-send 'sea-shell' "Now on $new_ver" 2>/dev/null
    else
        out available "$new_ver" "$new_ver" 0 "pulled $new_ver but install.sh failed — see /tmp/sea-update-install.log"
        notify-send -u critical 'sea-shell' 'Update pulled but install failed — see /tmp/sea-update-install.log' 2>/dev/null
    fi
    ;;
*)
    echo "usage: $0 check|apply" >&2; exit 2 ;;
esac
