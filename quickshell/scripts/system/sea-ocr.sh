#!/bin/sh
# sea-shell — OCR a screen region straight to the clipboard.
#
# Usage:  sea-ocr.sh [lang]        lang defaults to "eng"; pass any tesseract code, or a
#                                  combination like "eng+chi_sim" to read mixed text.
#
# Select a region, get its text on the clipboard. Reuses the same grim/slurp pair the
# screenshot tool already relies on, so there is no new capture path to keep working.

LANG_ARG="${1:-eng}"
TMP="${XDG_RUNTIME_DIR:-/tmp}/sea-ocr-$$.png"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

for bin in grim slurp tesseract wl-copy; do
    command -v "$bin" >/dev/null 2>&1 || {
        notify-send 'sea-shell' "OCR needs $bin — pacman -S grim slurp tesseract wl-clipboard" 2>/dev/null
        exit 1; }
done

# tesseract fails with a bare "data file not found" if the language pack is missing; check first
if ! tesseract --list-langs 2>/dev/null | tail -n +2 | grep -qx "$(printf '%s' "$LANG_ARG" | cut -d+ -f1)"; then
    notify-send 'sea-shell' "OCR language '$LANG_ARG' not installed — pacman -S tesseract-data-$(printf '%s' "$LANG_ARG" | cut -d+ -f1)" 2>/dev/null
    exit 1
fi

# an empty selection means the user pressed Esc — leave without any noise
region="$(slurp -d 2>/dev/null)" || exit 0
[ -n "$region" ] || exit 0

grim -g "$region" "$TMP" 2>/dev/null || {
    notify-send 'sea-shell' 'OCR: could not capture that region' 2>/dev/null; exit 1; }

# -c preserve_interword_spaces keeps column-ish text readable instead of collapsing runs
text="$(tesseract "$TMP" - -l "$LANG_ARG" -c preserve_interword_spaces=1 2>/dev/null \
        | sed -e 's/[[:space:]]*$//' -e '/^$/d')"

if [ -z "$text" ]; then
    notify-send 'sea-shell' 'OCR: no text found in that region' 2>/dev/null
    exit 0
fi

printf '%s' "$text" | wl-copy

# preview the first couple of lines so it is obvious WHAT got copied
preview="$(printf '%s' "$text" | head -c 140)"
[ "$(printf '%s' "$text" | wc -c)" -gt 140 ] && preview="$preview…"
notify-send -i edit-copy 'sea-shell — copied' "$preview" 2>/dev/null
