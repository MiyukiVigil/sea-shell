#!/bin/sh
# sea-shell — put a new wallpaper INTO the folder, from the clipboard.
#
# Usage: sea-wallpaper-import.sh          import whatever is on the clipboard
#        sea-wallpaper-import.sh PATH     import a file from anywhere on disk
#
# Prints the imported path on stdout and nothing else, so the picker can focus what it
# just got. Prints nothing and exits 1 when there was nothing importable.
#
# WHY THIS EXISTS.  Everything in this shell could choose a wallpaper and none of it could
# ADD one: the folder was filled by a file manager, or it was not filled. Copying an image
# out of a browser and pressing one key in the picker is the whole gesture, and the
# clipboard already holds every form it arrives in — raw image data, a file path, a URI, or
# a URL to fetch.

here="$(dirname "$0")"

dir="$(python3 - <<'PYEOF' 2>/dev/null
import json, os
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
except Exception:
    j = {}
d = str(j.get("wpDir") or "").strip()
d = os.path.expanduser(d) if d else os.path.expanduser("~/Pictures/wallpapers")
print(d)
PYEOF
)"
[ -n "$dir" ] || dir="$HOME/Pictures/wallpapers"
mkdir -p "$dir" 2>/dev/null || exit 1

# Never overwrite. Two screenshots pasted a second apart must not become one file, and a
# name that already exists is somebody's wallpaper.
unique() {
    base="$1" ext="$2" n=1
    cand="$dir/$base$ext"
    while [ -e "$cand" ]; do
        cand="$dir/$base-$n$ext"
        n=$((n + 1))
    done
    printf '%s' "$cand"
}

# Anything that is not a still or a clip is not a wallpaper, whatever it is called.
ext_ok() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *.jpg|*.jpeg|*.png|*.webp|*.bmp|*.jxl|*.mp4|*.webm|*.gif|*.mkv|*.mov) return 0 ;;
        *) return 1 ;;
    esac
}

copy_in() {
    src="$1"
    [ -f "$src" ] || return 1
    ext_ok "$src" || return 1
    name="$(basename "$src")"
    stem="${name%.*}"; ext=".${name##*.}"
    [ "$stem" = "$name" ] && ext=""
    out="$(unique "$stem" "$ext")"
    cp -- "$src" "$out" 2>/dev/null || return 1
    printf '%s\n' "$out"
    return 0
}

# ---- an explicit path wins ----------------------------------------------------------
if [ -n "$1" ]; then
    copy_in "$1" && exit 0
    exit 1
fi

command -v wl-paste >/dev/null 2>&1 || exit 1

types="$(wl-paste --list-types 2>/dev/null)"
[ -n "$types" ] || exit 1

# ---- raw image data ------------------------------------------------------------------
# The common case: an image copied out of a browser or a screenshot tool, which arrives as
# bytes with no name at all. It gets a dated one.
for t in image/png image/jpeg image/webp image/gif; do
    printf '%s\n' "$types" | grep -qx "$t" || continue
    case "$t" in
        image/png)  ext=".png" ;;
        image/jpeg) ext=".jpg" ;;
        image/webp) ext=".webp" ;;
        *)          ext=".gif" ;;
    esac
    out="$(unique "pasted-$(date +%Y%m%d-%H%M%S)" "$ext")"
    if wl-paste --type "$t" > "$out" 2>/dev/null && [ -s "$out" ]; then
        printf '%s\n' "$out"
        exit 0
    fi
    rm -f "$out"
done

# ---- a path, a file:// URI, or a URL -------------------------------------------------
text="$(wl-paste --no-newline 2>/dev/null | head -n 1)"
[ -n "$text" ] || exit 1

case "$text" in
    file://*)
        # percent-decoding, because a copied file URI escapes every space in the name
        path="$(python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1][7:]))" "$text" 2>/dev/null)"
        copy_in "$path" && exit 0
        ;;
    http://*|https://*)
        ext_ok "$text" || exit 1
        command -v curl >/dev/null 2>&1 || exit 1
        name="$(basename "$text")"
        name="${name%%\?*}"                       # drop a query string before naming
        stem="${name%.*}"; ext=".${name##*.}"
        out="$(unique "$stem" "$ext")"
        # A wallpaper is not a 4 GB download, and a URL that turns out to be a login page
        # should not land in the folder as a valid-looking file.
        if curl -fsSL --max-time 60 --max-filesize 209715200 -o "$out" "$text" 2>/dev/null \
           && [ -s "$out" ]; then
            printf '%s\n' "$out"
            exit 0
        fi
        rm -f "$out"
        ;;
    /*)
        copy_in "$text" && exit 0
        ;;
    ~/*)
        copy_in "$HOME/${text#\~/}" && exit 0
        ;;
esac
exit 1
