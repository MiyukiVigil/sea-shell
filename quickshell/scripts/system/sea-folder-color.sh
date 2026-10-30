#!/bin/sh
# Root helper: fixed system themes and a finite colour list only.
PATH=/usr/bin:/bin
export PATH
[ "$#" -eq 1 ] || exit 2
case "$1" in
    blue|cyan|green|grey|orange|pink|red|teal|violet|yellow) action=-C ;;
    default) action=-D ;;
    *) echo 'unsupported folder colour' >&2; exit 2 ;;
esac
[ -x /usr/bin/papirus-folders ] || { echo 'Install papirus-folders first' >&2; exit 1; }
result=0
for theme in Papirus Papirus-Dark Papirus-Light; do
    [ -d "/usr/share/icons/$theme" ] || continue
    if [ "$action" = -D ]; then
        /usr/bin/env -i PATH=/usr/bin:/bin HOME=/root /bin/bash /usr/bin/papirus-folders -D --theme "$theme" || result=1
    else
        /usr/bin/env -i PATH=/usr/bin:/bin HOME=/root /bin/bash /usr/bin/papirus-folders -C "$1" --theme "$theme" || result=1
    fi
done
exit "$result"
