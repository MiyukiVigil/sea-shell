#!/bin/sh
# sea-shell — Wayland screen recorder (wf-recorder · slurp · PipeWire)
#
# Usage:
#   sea-record.sh start [opts]  start recording
#   sea-record.sh stop          stop, keep the file
#   sea-record.sh cancel        stop, delete the file
#   sea-record.sh toggle        stop if recording, else start
#   sea-record.sh status        "elapsed|path|audio|capture", or "inactive"
#   sea-record.sh probe         JSON: audio devices + outputs (RecorderPanel reads this)
#
# Options override ~/.config/sea-shell/recorder.json, which in turn overrides the
# defaults below. RecorderPanel.qml writes that file AND passes the same values as
# flags, so a bare `sea-record.sh start` from a terminal reproduces whatever the
# panel last did.
#
#   --capture region|screen|output:<name>
#   --audio   none|mic|system|both
#   --mic     <pulse source>    ""  = default source
#   --sys     <pulse monitor>   ""  = default sink's monitor (follows the DAC)
#   --fps     <n>
#   --format  mp4|mkv|webm
#   --encoder sw|hw             hw = VAAPI
#   --dir     <path>            where recordings land (default ~/Videos/Recordings)
#   --geometry "x,y WxH"        pre-selected region — skips slurp
#   --output  <name>            same as --capture output:<name>
#
# The `countdown` key in recorder.json is deliberately ignored here: the 3-2-1 is
# drawn by the panel, which owns the screen. This script's job is to record now.
#
# wf-recorder 0.6 takes exactly ONE --audio device, so `both` cannot be expressed in
# flags. We build the mix ourselves: a null sink with the mic and the system monitor
# looped into it, and record ITS monitor. See mix_down() for the teardown contract.

state="/tmp/sea-record.pid"     # 1 pid · 2 path · 3 start · 4 modules · 5 audio · 6 capture · 7 prev-sink
log="/tmp/sea-record.log"
cfgfile="$HOME/.config/sea-shell/recorder.json"
mixsink="sea_record_mix"

# ---- defaults (lowest priority) ----
capture="region"; audio="system"; mic=""; sys=""
fps="60"; format="mp4"; encoder="sw"; outdir="$HOME/Videos/Recordings"
geometry=""

note()  { notify-send -i video-x-generic "sea-shell" "$1"; }
fail()  { notify-send -u critical -i video-x-generic "sea-shell" "$1"; exit 1; }
line()  { awk -v n="$1" 'NR==n' "$state" 2>/dev/null; }

# Is $1 OUR recorder — not merely "some process holds this pid"?
#
# `kill -0` alone is not good enough, and the difference is not theoretical: kill the
# recorder and the kernel is free to hand that pid straight to the next process that
# asks. Then `kill -0` says yes about a stranger, and two things follow. status keeps
# reporting a recording that ended (the pill sticks forever, and the leaked mix sink
# is never swept because the stale-state branch never runs), and — worse — stop_recording
# SIGTERMs that innocent pid and SIGKILLs it five seconds later.
#
# So ask what the process actually IS. /proc/<pid>/comm is the cheapest honest answer.
is_wf() {
    [ -n "$1" ] || return 1
    [ "$(cat "/proc/$1/comm" 2>/dev/null)" = "wf-recorder" ]
}
alive() { [ -f "$state" ] && is_wf "$(line 1)"; }

# ---- config ----
# Missing file, missing key, or no jq at all → the defaults above. A recorder that
# refuses to start because its settings file is absent would be a worse recorder.
cfg() {
    [ -f "$cfgfile" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r --arg k "$1" '.[$k] // empty' "$cfgfile" 2>/dev/null
}
read_cfg() {
    v=$(cfg capture); [ -n "$v" ] && capture="$v"
    v=$(cfg audio);   [ -n "$v" ] && audio="$v"
    v=$(cfg mic);     [ -n "$v" ] && mic="$v"
    v=$(cfg sys);     [ -n "$v" ] && sys="$v"
    v=$(cfg fps);     [ -n "$v" ] && fps="$v"
    v=$(cfg format);  [ -n "$v" ] && format="$v"
    v=$(cfg encoder); [ -n "$v" ] && encoder="$v"
    v=$(cfg dir);     [ -n "$v" ] && outdir=$(printf '%s' "$v" | sed "s|^~|$HOME|")
}

# ---- audio devices ----
def_source()  { pactl get-default-source 2>/dev/null; }
def_monitor() { s=$(pactl get-default-sink 2>/dev/null); [ -n "$s" ] && printf '%s.monitor' "$s"; }

# Tear down every module we own. Matched by NAME, not by the stored ids: a recording
# killed with SIGKILL never gets to write its ids, so the next start/status has to be
# able to find the wreckage from nothing but the sink name. A leaked loopback holds
# the microphone open indefinitely — mic LED on, capture live — so this re-reads the
# module list and retries rather than assuming one unload pass took.
mix_down() {
    command -v pactl >/dev/null 2>&1 || return 0
    i=0
    while [ "$i" -lt 5 ]; do
        ids=$(pactl list short modules 2>/dev/null | grep -F "$mixsink" | cut -f1)
        [ -z "$ids" ] && return 0
        for id in $ids; do pactl unload-module "$id" 2>/dev/null; done
        i=$((i + 1))
    done
    return 1
}
# $1 = system monitor, $2 = mic. Echoes the module ids; empty stdout means failure.
mix_up() {
    _m=$(pactl load-module module-null-sink sink_name="$mixsink" \
            sink_properties="device.description=sea-shell\ recording\ mix" 2>/dev/null)
    [ -n "$_m" ] || return 1
    _a=$(pactl load-module module-loopback source="$1" sink="$mixsink" \
            latency_msec=20 source_dont_move=true sink_dont_move=true 2>/dev/null)
    _b=$(pactl load-module module-loopback source="$2" sink="$mixsink" \
            latency_msec=20 source_dont_move=true sink_dont_move=true 2>/dev/null)
    [ -n "$_a" ] && [ -n "$_b" ] || { mix_down; return 1; }
    printf '%s %s %s' "$_m" "$_a" "$_b"
}

focused_output() {
    hyprctl monitors -j 2>/dev/null | jq -r 'first(.[] | select(.focused) | .name) // empty' 2>/dev/null
}

start_recording() {
    alive && { note "Already recording."; exit 0; }
    command -v wf-recorder >/dev/null 2>&1 || fail "wf-recorder not found. Install it: sudo pacman -S wf-recorder"
    rm -f "$state"
    mkdir -p "$outdir" || fail "Can't write to $outdir"

    # ---- where ----
    set --; capdesc=""
    case "$capture" in
        region)
            if [ -z "$geometry" ]; then
                command -v slurp >/dev/null 2>&1 || fail "slurp not found — needed to select a region."
                geometry=$(slurp -d 2>/dev/null)
                [ -z "$geometry" ] && exit 0          # cancelled the drag — not an error
            fi
            set -- "$@" -g "$geometry"; capdesc="region" ;;
        output:*)
            o=${capture#output:}
            set -- "$@" -o "$o"; capdesc="$o" ;;
        screen)
            o=$(focused_output)
            if [ -n "$o" ]; then set -- "$@" -o "$o"; capdesc="$o"; else capdesc="screen"; fi ;;
        *) fail "Unknown capture mode: $capture" ;;
    esac

    # ---- how ----
    case "$format" in
        mp4|mkv) vsw="libx264";    vhw="h264_vaapi"; acodec="aac" ;;
        webm)    vsw="libvpx-vp9"; vhw="vp9_vaapi";  acodec="libopus" ;;
        *) fail "Unknown format: $format" ;;
    esac
    if [ "$encoder" = "hw" ] && [ -e /dev/dri/renderD128 ]; then
        set -- "$@" -c "$vhw" -d /dev/dri/renderD128
    else
        case "$vsw" in
            libx264)    set -- "$@" -c libx264 -p preset=veryfast -p crf=21 ;;
            libvpx-vp9) set -- "$@" -c libvpx-vp9 -p deadline=realtime -p cpu-used=8 ;;
        esac
    fi
    set -- "$@" -r "$fps"

    # ---- audio ----
    modules=""; prev_sink=""
    if [ "$audio" != "none" ]; then
        command -v pactl >/dev/null 2>&1 || fail "pactl not found — can't record audio."
        m=${mic:-$(def_source)}
        s=${sys:-$(def_monitor)}
        case "$audio" in
            mic)
                [ -n "$m" ] || fail "No microphone to record from."
                set -- "$@" --audio="$m" ;;
            system)
                [ -n "$s" ] || fail "No audio output to record from."
                set -- "$@" --audio="$s" ;;
            both)
                [ -n "$m" ] && [ -n "$s" ] || fail "Need both a microphone and an output to mix."
                mix_down                              # sweep anything a killed run left behind
                # Loading a null sink can make wireplumber re-pick the default sink and
                # silently move playback into the recording mix. Put it back afterwards.
                prev_sink=$(pactl get-default-sink 2>/dev/null)
                modules=$(mix_up "$s" "$m") || fail "Couldn't build the audio mix."
                [ -n "$prev_sink" ] && pactl set-default-sink "$prev_sink" 2>/dev/null
                set -- "$@" --audio="$mixsink.monitor" ;;
            *) fail "Unknown audio mode: $audio" ;;
        esac
        set -- "$@" -C "$acodec"
    fi

    path="$outdir/Record-$(date +%Y%m%d-%H%M%S).$format"
    : > "$log"
    wf-recorder -y "$@" -f "$path" >>"$log" 2>&1 &
    pid=$!

    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$pid" "$path" "$(date +%s)" "$modules" "$audio" "$capdesc" "$prev_sink" > "$state"

    # wf-recorder exits within a few hundred ms on a bad codec, a busy device or a
    # missing render node. Without this the pill simply never appears and the failure
    # is invisible — so wait for it to prove it survived, and say why if it didn't.
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        why=$(grep -iE 'error|failed|cannot|no such|unable|invalid' "$log" 2>/dev/null | head -1)
        [ -z "$why" ] && why=$(tail -1 "$log" 2>/dev/null)
        rm -f "$state"; mix_down
        [ -n "$prev_sink" ] && pactl set-default-sink "$prev_sink" 2>/dev/null
        fail "Recording failed to start.
${why:-see $log}"
    fi

    case "$audio" in
        none)   asuffix="" ;;
        mic)    asuffix=" · mic" ;;
        system) asuffix=" · system audio" ;;
        both)   asuffix=" · mic + system" ;;
    esac
    note "Recording $capdesc$asuffix"
}

# $1 = keep | discard
stop_recording() {
    [ -f "$state" ] || exit 0
    pid=$(line 1); path=$(line 2); mods=$(line 4); prev_sink=$(line 7)

    # Only ever signal a pid we've confirmed is still wf-recorder itself (see is_wf).
    # If it already died, fall through: the modules and the state file still need clearing.
    if is_wf "$pid"; then
        kill "$pid" 2>/dev/null              # SIGTERM: wf-recorder finalises the muxer
        i=0
        while is_wf "$pid" && [ "$i" -lt 50 ]; do
            sleep 0.1; i=$((i + 1))
        done
        is_wf "$pid" && kill -9 "$pid" 2>/dev/null   # 5s on — the file is what it is
    fi

    # By id first (precise), then by name in case the ids went stale.
    if [ -n "$mods" ]; then
        for id in $mods; do pactl unload-module "$id" 2>/dev/null; done
    fi
    mix_down
    [ -n "$prev_sink" ] && pactl set-default-sink "$prev_sink" 2>/dev/null

    rm -f "$state"

    if [ "$1" = "discard" ]; then
        rm -f "$path"
        note "Recording discarded."
        return
    fi
    if [ -s "$path" ]; then
        size=$(du -h "$path" 2>/dev/null | cut -f1)
        note "Saved $(basename "$path") · $size"
        command -v wl-copy >/dev/null 2>&1 && wl-copy "$path" 2>/dev/null
    else
        rm -f "$path"
        note "Recording produced no file — see $log"
    fi
}

probe() {
    if ! command -v pactl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then echo '{}'; return; fi
    # .description is the CARD name with the port glued on, so two mics on one card
    # read identically for the first 40 characters ("Alder Lake PCH-P High Defin…").
    # The active port's own description is the part that actually tells them apart
    # ("Stereo Microphone" vs "Digital Microphone"), so lead with that and keep the
    # card as a secondary line.
    mics=$(pactl -f json list sources 2>/dev/null \
        | jq -c '[.[] | select(.properties["media.class"] == "Audio/Source") | . as $s
                 | {name: $s.name,
                    desc: (([$s.ports[]? | select(.name == $s.active_port) | .description] | first) // $s.description),
                    via:  ($s.properties["device.description"] // "")}]' 2>/dev/null)
    sinks=$(pactl -f json list sinks 2>/dev/null \
        | jq -c '[.[] | . as $s
                 | {name: ($s.name + ".monitor"),
                    desc: (([$s.ports[]? | select(.name == $s.active_port) | .description] | first) // $s.description),
                    via:  ($s.properties["device.description"] // "")}]' 2>/dev/null)
    outs=$(hyprctl monitors -j 2>/dev/null \
        | jq -c '[.[] | {name: .name, desc: "\(.width)x\(.height)@\(.refreshRate | floor)", focused: .focused}]' 2>/dev/null)
    jq -n --argjson mics "${mics:-[]}" --argjson sinks "${sinks:-[]}" --argjson outs "${outs:-[]}" \
          --arg dmic "$(def_source)" --arg dsys "$(def_monitor)" \
          --argjson hw "$([ -e /dev/dri/renderD128 ] && echo true || echo false)" \
          --argjson wf "$(command -v wf-recorder >/dev/null 2>&1 && echo true || echo false)" \
        '{mics:$mics, sinks:$sinks, outputs:$outs, default_mic:$dmic, default_sys:$dsys, hw:$hw, wf:$wf}'
}

read_cfg
cmd="${1:-toggle}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --capture)  capture="$2";        shift 2 ;;
        --audio)    audio="$2";          shift 2 ;;
        --mic)      mic="$2";            shift 2 ;;
        --sys)      sys="$2";            shift 2 ;;
        --fps)      fps="$2";            shift 2 ;;
        --format)   format="$2";         shift 2 ;;
        --encoder)  encoder="$2";        shift 2 ;;
        --dir)      outdir="$2";         shift 2 ;;
        --geometry) geometry="$2"; capture="region"; shift 2 ;;
        --output)   capture="output:$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "$cmd" in
    start)  start_recording ;;
    stop)   stop_recording keep ;;
    cancel) stop_recording discard ;;
    toggle) if alive; then stop_recording keep; else start_recording; fi ;;
    status)
        if alive; then
            printf '%s|%s|%s|%s\n' "$(( $(date +%s) - $(line 3) ))" "$(line 2)" "$(line 5)" "$(line 6)"
        else
            echo "inactive"
            # Stale state = wf-recorder died without us. Sweep its mix, or a crashed
            # "both" recording strands a loopback holding the microphone open.
            if [ -f "$state" ]; then
                mix_down
                # A recorder killed before it wrote a single frame leaves a 0-byte file
                # behind; nothing else would ever clear it. Only ever remove it when it
                # is genuinely empty — a crashed recording that DID capture something is
                # the user's, and mkv will still play it.
                p=$(line 2)
                if [ -n "$p" ] && [ -e "$p" ] && [ ! -s "$p" ]; then rm -f "$p"; fi
                rm -f "$state"
            fi
        fi ;;
    probe)  probe ;;
    *) echo "usage: sea-record.sh start|stop|cancel|toggle|status|probe [opts]" >&2; exit 2 ;;
esac
