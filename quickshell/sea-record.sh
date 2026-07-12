#!/bin/sh
# sea-shell — wayland screen recording wrapper using wf-recorder & slurp
# Usage:
#   sea-record.sh toggle    # toggles recording on/off
#   sea-record.sh status    # prints elapsed seconds and output path if active

pidfile="/tmp/sea-record.pid"
outdir="$HOME/Videos/Recordings"

stop_recording() {
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" | awk 'NR==1')
        path=$(cat "$pidfile" | awk 'NR==2')
        kill "$pid" 2>/dev/null
        rm -f "$pidfile"
        notify-send -i video-x-generic "sea-shell" "Recording saved to: $(basename "$path")"
        wl-copy "$path" 2>/dev/null
    fi
}

start_recording() {
    mkdir -p "$outdir"
    geom=$(slurp -d 2>/dev/null)
    if [ -z "$geom" ]; then
        # user cancelled slurp
        exit 0
    fi
    
    path="$outdir/Record-$(date +%Y%m%d-%H%M%S).mp4"
    
    if command -v wf-recorder >/dev/null 2>&1; then
        wf-recorder -g "$geom" -f "$path" >/dev/null 2>&1 &
        pid=$!
        echo "$pid" > "$pidfile"
        echo "$path" >> "$pidfile"
        echo "$(date +%s)" >> "$pidfile"
        notify-send -i video-x-generic "sea-shell" "Screen recording started..."
    else
        notify-send -u critical "sea-shell" "wf-recorder not found. Please install it."
    fi
}

case "$1" in
    toggle)
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" | head -1 2>/dev/null)" 2>/dev/null; then
            stop_recording
        else
            start_recording
        fi
        ;;
    status)
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" | head -1 2>/dev/null)" 2>/dev/null; then
            start_time=$(cat "$pidfile" | awk 'NR==3')
            now=$(date +%s)
            elapsed=$((now - start_time))
            path=$(cat "$pidfile" | awk 'NR==2')
            echo "$elapsed|$path"
        else
            echo "inactive"
            # clean up stale pidfile if any
            rm -f "$pidfile"
        fi
        ;;
esac
