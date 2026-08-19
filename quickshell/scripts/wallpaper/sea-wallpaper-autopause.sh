#!/bin/sh
# sea-shell — stop a video wallpaper costing anything while nobody can see it.
#
# mpvpaper's own --auto-pause doesn't detect Hyprland's fullscreen occlusion reliably, so
# we drive it ourselves: listen to Hyprland's event socket and, on anything that changes
# what is in front of the wallpaper, decide between three states.
#
#   play    — visible. mpv unpaused.
#   pause   — covered, and the user wants the decoder kept warm.
#   freeze  — covered (or on battery), and mpvpaper is REPLACED by its poster frame.
#
# WHY FREEZE EXISTS.  Pausing was all this did, and a paused mpvpaper is not a free
# mpvpaper: it holds its decoder, its wl_surface and its VRAM for as long as it lives. On
# a 6 GB card the thing covering the wallpaper is usually a game, and that is exactly the
# memory it wanted. Freezing hands the background back to swww — which is already showing
# the same frame underneath, so the swap is invisible — and kills mpvpaper outright.
#
# Single-instance (flock). Started alongside mpvpaper by sea-wallpaper-apply.sh; re-running
# while one is live is a no-op.

here="$(dirname "$0")"
SOCK="$XDG_RUNTIME_DIR/sea-mpvpaper.sock"                       # mpv IPC socket
EV="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"  # hypr events

command -v ncat >/dev/null 2>&1 || exit 0
[ -S "$EV" ] || exit 0

# Only one listener per session. The lock is keyed to the Hyprland instance so a
# listener stranded by a previous session can never block this one — and fd 9 is
# closed for the ncat below, because an ncat that outlives its parent script (its
# event socket died with the old compositor) would otherwise hold the lock
# forever and silently prevent every future listener from starting.
exec 9>"$XDG_RUNTIME_DIR/sea-autopause-$HYPRLAND_INSTANCE_SIGNATURE.lock"
flock -n 9 || exit 0

setp() { printf '{"command":["set_property","pause",%s]}\n' "$1" | ncat -U "$SOCK" >/dev/null 2>&1; }

# What the wallpaper SHOULD be doing, in one call: play | pause | freeze.
#
# Occlusion, the two settings and the mains state are all decided here together rather
# than in shell, because this runs on every window event and each separate check would be
# another fork. Reading the settings each time is also what makes the toggles in Settings
# take effect on the next window you open instead of at the next login.
#
# COVERED MEANS FULLSCREEN, and nothing looser. Counting a window that merely fills the
# monitor caught every maximised editor, which is not what anyone means by "nobody can see
# the wallpaper". It does still look at EVERY monitor rather than only the focused one — a
# wallpaper plainly visible on the other screen was being paused.
want() {
    python3 - <<'PY' 2>/dev/null
import glob, json, os, subprocess, sys

def hj(what):
    try:
        out = subprocess.run(["hyprctl", what, "-j"], capture_output=True,
                             text=True, timeout=4).stdout
        return json.loads(out or "[]")
    except Exception:
        print("play"); sys.exit(0)       # can't tell -> assume visible, keep playing

try:
    cfg = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
except Exception:
    cfg = {}
# Freeing the VRAM is the whole point, so it is the default; keeping the decoder warm is
# the opt-out for anyone who would rather have the video back instantly.
cover_still = cfg.get("wpCoverStill", True)
battery_still = cfg.get("wpBatteryStill", False)

def on_battery():
    mains = []
    for d in glob.glob("/sys/class/power_supply/*"):
        try:
            if open(os.path.join(d, "type")).read().strip() != "Mains":
                continue
            mains.append(open(os.path.join(d, "online")).read().strip() == "1")
        except OSError:
            pass
    # No mains supply at all is a desktop, not a flat battery.
    return bool(mains) and not any(mains)

if battery_still and on_battery():
    print("freeze"); sys.exit(0)

mons, clients = hj("monitors"), hj("clients")

# TRUE FULLSCREEN ONLY.
#
# This used to also count "a window sized to at least 95% of the monitor" and "tiled windows
# adding up to 85% of it". Both are true of an ordinary maximised editor and of most
# single-window workspaces, so the wallpaper was paused — and, once freezing existed, killed —
# during normal work rather than during the fullscreen game this was built for. Hyprland
# already knows what fullscreen means; ask it and nothing else.
covered = True
for m in mons:
    if m.get("disabled"):
        continue
    ws = (m.get("activeWorkspace") or {}).get("id")
    hidden = False
    for c in clients:
        if (c.get("workspace") or {}).get("id") != ws:
            continue
        if c.get("hidden") or not c.get("mapped"):
            continue
        if c.get("fullscreen"):
            hidden = True
            break
    if not hidden:
        covered = False                  # wallpaper still visible somewhere
        break

# FREEZING IS DESTRUCTIVE AND PAUSING IS NOT, so they do not answer to the same question.
#
# "Covered" is true for an ordinary maximised terminal, and for any workspace whose tiled
# windows fill it — which is most workspaces, most of the time. Killing mpvpaper for that
# means the wallpaper visibly stops every time you switch workspace and has to be restarted
# from scratch coming back, which is exactly what it did.
#
# So only a genuinely FULLSCREEN window — the case this was built for, a game — is worth
# handing the VRAM back for. Everything else pauses, as it always did.
if not covered:
    print("play")
elif cover_still:
    print("freeze")
else:
    print("pause")
PY
}

# Freezing and resuming are process-level operations, so unlike a pause they must not be
# repeated on every window event — `state` is what makes them edge-triggered. It starts
# empty rather than at "play" so the first sync always acts.
state=""
pending=""
sync() {
    w="$(want)"
    [ -z "$w" ] && w="play"

    # Freezing waits for a SECOND opinion. Going fullscreen is often momentary — a video
    # expanded for a few seconds, a game alt-tabbed straight back out — and killing the
    # wallpaper process for that costs a visible restart on the way back. The first sighting
    # pauses instead, which is free and instant to undo; the confirmation arrives on the next
    # window event, or at worst on the 30s tick, by which time the decoder has been idle
    # anyway and only the VRAM is still being held.
    if [ "$w" = "freeze" ] && [ "$pending" != "freeze" ]; then
        pending="freeze"
        if [ "$state" != "pause" ]; then setp true; state="pause"; fi
        return
    fi
    [ "$w" = "freeze" ] || pending=""

    [ "$w" = "$state" ] && return
    case "$w" in
        play)
            if [ "$state" = "freeze" ]; then
                # setsid: mpvpaper must outlive this listener's process group, or the next
                # thing to kill the listener takes the wallpaper down with it.
                #
                # 9<&- IS LOAD-BEARING. This ends in `exec mpvpaper`, so without it mpvpaper
                # INHERITS the lock fd and holds it for as long as the wallpaper plays —
                # which is forever. The next listener to start then loses flock and exits
                # silently, and the wallpaper is left with nobody watching it: stuck paused,
                # with nothing able to unpause it. The header warns about a stranded ncat
                # doing this; a stranded mpvpaper is worse, because it never dies.
                setsid sh "$here/sea-wallpaper-apply.sh" --resume >/dev/null 2>&1 9<&- &
            else
                setp false
            fi
            ;;
        pause)  setp true ;;
        freeze) sh "$here/sea-wallpaper-apply.sh" --freeze >/dev/null 2>&1 9<&- ;;
    esac
    state="$w"
}

# give mpvpaper a moment to create its socket, then match the current state
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 25 ]; do i=$((i+1)); sleep 0.2; done
sync

# TWO event sources, ONE loop, through a fifo.
#
# Window events alone are not enough any more: unplugging the mains changes what the
# wallpaper should be doing and emits no Hyprland event at all, so on a quiet desktop the
# battery setting would not take effect until the next time a window opened. A slow tick
# covers that — 30s is well inside "I unplugged it and walked off" and is one hyprctl
# pair per tick when nothing is happening.
#
# Reading from the fifo rather than from a pipeline also keeps the loop in THIS shell, so
# `state` survives between events. Piped into `while`, it lived in a subshell and every
# freeze decision was made against a state the previous one could not update.
FIFO="$XDG_RUNTIME_DIR/sea-autopause-$HYPRLAND_INSTANCE_SIGNATURE.fifo"
rm -f "$FIFO"
mkfifo "$FIFO" 2>/dev/null || exit 0

ncat -U "$EV" 2>/dev/null 9<&- > "$FIFO" &
EV_PID=$!
( while sleep 30; do printf 'tick>>\n'; done ) > "$FIFO" 2>/dev/null 9<&- &
TICK_PID=$!
trap 'kill "$EV_PID" "$TICK_PID" 2>/dev/null; rm -f "$FIFO"' EXIT INT TERM

# Re-evaluate on anything that changes what's on screen in front of the wallpaper.
# open/close/move/float matter as much as `fullscreen` now that a borderless window
# filling the monitor counts as covering it — a game launched into an existing
# workspace emits openwindow and nothing else.
while IFS= read -r line; do
    case "$line" in
        # The tick is also the liveness check. With two writers the fifo never reaches
        # EOF, so the old "exit when the event socket closes" no longer happens by
        # itself — and a listener left spinning against a dead compositor would poll
        # hyprctl forever.
        tick\>\>*) [ -S "$EV" ] || break; sync ;;
        fullscreen\>\>*|workspace\>\>*|workspacev2\>\>*|focusedmon\>\>*|focusedmonv2\>\>*|\
        openwindow\>\>*|closewindow\>\>*|movewindow\>\>*|movewindowv2\>\>*|\
        changefloatingmode\>\>*|monitoradded\>\>*|monitorremoved\>\>*) sync ;;
    esac
done < "$FIFO"
