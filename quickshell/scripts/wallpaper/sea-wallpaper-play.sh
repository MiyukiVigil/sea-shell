#!/bin/sh
# sea-shell — play a wallpaper clip outside the bar.
#
#   sea-wallpaper-play.sh play /path/to/clip.mp4
#   sea-wallpaper-play.sh stop
#
# mpvpaper owns the decode. The bar only decides when it should be running, so a
# video wallpaper does not land in `qs`'s RSS. The file it is given is already the
# screen-sized copy (sea-wallpaper-optimize.py); this does not scale a 4K master.
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/sea-wallpaper-play.pid"

stop_player() {
    if [ -f "$PIDFILE" ]; then
        old=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$old" ] && kill "$old" 2>/dev/null
        rm -f "$PIDFILE"
    fi
}

case "$1" in
    stop)
        stop_player
        exit 0
        ;;
    play)
        [ -f "$2" ] || exit 1
        stop_player
        # -s: mpvpaper drops the decoder when its layer is covered.
        # The bar also stops this process when a window covers the wallpaper.
        mpvpaper -s -o "no-audio loop hwdec=auto-safe panscan=1.0 vd-lavc-threads=1 demuxer-max-bytes=2MiB demuxer-max-back-bytes=512KiB cache=no" '*' "$2" &
        player=$!
        echo "$player" > "$PIDFILE"
        trap 'kill "$player" 2>/dev/null; rm -f "$PIDFILE"; exit 0' TERM INT HUP
        wait "$player"
        ;;
    *)
        exit 2
        ;;
esac
