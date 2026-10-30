#!/bin/sh
# sea-shell — lock the screen safely.
#
#   sea-lock.sh         lock. With hypridle running this goes through `loginctl lock-session`, so
#                       logind knows the session is locked; hypridle's lock_cmd then calls --now.
#   sea-lock.sh --now   start the locker itself.
#
# The locker is lock.qml in its own Quickshell process, apart from the shell, so reloading or
# crashing the shell can never take the lock down with it. If lock.qml does not hold the lock
# within a few seconds, or exits without a real unlock (a crash, a QML error), hyprlock takes
# over. Hyprland keeps a session locked when its locker dies, and misc:allow_session_lock_restore
# (sea.lua) lets hyprlock pick it up. lock.qml marks the unlock only AFTER unlocking, so a crash
# in between costs a second password, never an open session.
# "engine": "hyprlock" in ~/.config/sea-shell/lock.json skips lock.qml entirely.

dir=$(dirname "$(readlink -f "$0")")
run="${XDG_RUNTIME_DIR:-/tmp}/sea-lock"

if [ "$1" != "--now" ]; then
    pidof hyprlock >/dev/null 2>&1 && exit 0
    if pgrep -x hypridle >/dev/null 2>&1; then
        exec loginctl lock-session
    fi
    exec "$0" --now
fi

# one locker at a time: the flock is held by this script and whatever it execs
exec 9>"$run.lock"
flock -n 9 || exit 0
pidof hyprlock >/dev/null 2>&1 && exit 0

if grep -qs '"engine" *: *"hyprlock"' "$HOME/.config/sea-shell/lock.json" || ! command -v quickshell >/dev/null 2>&1; then
    exec hyprlock
fi

rm -f "$run.up" "$run.ok"
quickshell -p "$dir/lock.qml" >"$run.log" 2>&1 &
qs=$!

# lock.qml touches $run.up once the compositor confirms every screen is covered
i=0
while [ ! -e "$run.up" ] && kill -0 "$qs" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1; i=$((i + 1))
done
if [ ! -e "$run.up" ]; then
    kill "$qs" 2>/dev/null
    exec hyprlock --grace 0 --immediate-render
fi

wait "$qs"
[ -e "$run.ok" ] || exec hyprlock --grace 0 --immediate-render --no-fade-in
rm -f "$run.up" "$run.ok"
