#!/bin/sh
# sea-shell — keep the bar alive.
#
# Quickshell exits (rc 255) on "The Wayland connection experienced a fatal error:
# Invalid argument". Observed repeatedly around fullscreen clients tearing down their
# surfaces — a game or emulator being closed takes the bar with it. Nothing in the QML
# can catch that: by the time the connection dies the process is already gone, so the
# only real fix is to bring it back. Hyprland used to `exec` the bar exactly once, which
# meant one such error left you barless until you hit SUPER+SHIFT+B.
#
# Usage:  sea-bar-supervisor.sh             start supervising (from hyprland.lua)
#         sea-bar-supervisor.sh --restart   stop the old supervisor+bar, start fresh
#
# The bar is killed via the child PID we own, never `pkill` — a pattern like
# 'qs -c sea-shell' also matches the very sh -c that runs it, which has bitten this
# repo before (it self-kills), and `pkill -x qs` would take out the `qs -p` panels too.

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/sea-shell-supervisor.pid"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/sea-shell-supervisor-${HYPRLAND_INSTANCE_SIGNATURE:-none}.lock"
LOG="${XDG_RUNTIME_DIR:-/tmp}/sea-shell-supervisor.log"

# ---- restart: hand over to a fresh supervisor -------------------------------
if [ "$1" = "--restart" ]; then
    if [ -f "$PIDFILE" ]; then
        old=$(cat "$PIDFILE" 2>/dev/null)
        # TERM makes the old supervisor kill its bar and stand down (trap below)
        [ -n "$old" ] && kill "$old" 2>/dev/null
        i=0
        while [ -n "$old" ] && kill -0 "$old" 2>/dev/null && [ "$i" -lt 20 ]; do
            i=$((i + 1)); sleep 0.1
        done
    fi
    exec "$0"
fi

# ---- single instance, keyed to THIS Hyprland session ------------------------
# Session-keyed so a supervisor stranded by a previous session can never block this
# one (the wallpaper autopause hit exactly that bug with a session-agnostic lock).
exec 9>"$LOCK"
flock -n 9 || exit 0

echo $$ > "$PIDFILE"

child=""
cleanup() {
    [ -n "$child" ] && kill "$child" 2>/dev/null
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup TERM INT HUP

# ---- do not hand the desktop a developer's environment ---------------------
# Everything the launcher starts is a CHILD OF THE BAR and inherits this process's
# environment. Restart the bar from inside an editor's integrated terminal — which is
# exactly what you do while working on it — and the whole desktop inherits that editor's
# variables. ELECTRON_RUN_AS_NODE=1 is the one that bites: every Electron app launched
# from the launcher then starts as plain node and dies, while the same app started from a
# terminal works, because the terminal was started by Hyprland and is clean. Cider and
# Obsidian were unlaunchable this way and it looked like the launcher was broken.
#
# These are all injected by editors/toolchains and none of them mean anything to a bar.
unset ELECTRON_RUN_AS_NODE ELECTRON_NO_ATTACH_CONSOLE ELECTRON_IS_DEV \
      ELECTRON_FORCE_IS_PACKAGED ELECTRON_DISABLE_SECURITY_WARNINGS \
      NODE_OPTIONS CHROME_DESKTOP
for v in $(env | sed -n 's/^\(VSCODE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# LD_LIBRARY_PATH pointed at an editor's bundled electron would break any app that loads
# a different one; the bar itself has never needed it.
case "$LD_LIBRARY_PATH" in *code*|*electron*) unset LD_LIBRARY_PATH ;; esac

fails=0
while :; do
    start=$(date +%s)
    # 9<&- : do NOT leak the lock fd into the bar. Everything the bar spawns
    # (sea-kdeconnect.py, the cliphist wl-paste watchers) inherits it otherwise and
    # keeps the lock held long after the bar is gone, so every later supervisor sees
    # a taken lock and exits silently — leaving no bar at all.
    qs -c sea-shell 9<&- &
    child=$!
    wait "$child"
    rc=$?
    child=""
    run=$(( $(date +%s) - start ))

    # 143 = SIGTERM: something killed the bar deliberately. Respawn it anyway —
    # that is what an old-style `pkill -xf 'qs -c sea-shell'` expects to be able
    # to do. Deliberately stopping the SUPERVISOR is what --restart / TERM is for.
    echo "$(date '+%F %T') bar exited rc=$rc after ${run}s" >> "$LOG"

    if [ "$run" -lt 5 ]; then
        fails=$((fails + 1))
        if [ "$fails" -ge 5 ]; then
            notify-send -u critical 'sea-shell' \
                'Bar keeps failing at startup — supervisor stopped. See sea-shell-supervisor.log' 2>/dev/null
            rm -f "$PIDFILE"
            exit 1
        fi
        sleep 2
    else
        fails=0
        sleep 1
    fi
done
