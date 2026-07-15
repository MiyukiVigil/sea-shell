#!/usr/bin/env bash
# sea-shell — one-shot system overview for the settings About/System page.
# Prints `key=value` lines (one per line). Multiple `gpu=` lines are collected
# into a list by the QML parser. Everything degrades gracefully when a tool is
# missing, so this stays useful on non-Arch/non-Hyprland setups too.

. /etc/os-release 2>/dev/null

printf 'os=%s\n'     "${PRETTY_NAME:-Linux}"
printf 'id=%s\n'     "${ID:-linux}"          # distro id (cachyos, arch, …) → picks the logo glyph
printf 'idlike=%s\n' "${ID_LIKE:-}"          # fallback family (e.g. "arch") when id has no glyph
printf 'host=%s@%s\n' "$USER" "$(hostnamectl hostname 2>/dev/null || hostname 2>/dev/null)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'arch=%s\n'   "$(uname -m)"

# uptime → "2d 3h 14m" (drops the day field under 24h)
awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
      if (d>0) printf "up=%dd %dh %dm\n", d, h, m; else printf "up=%dh %dm\n", h, m}' /proc/uptime

# CPU model + logical core count
awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print "cpu="$2; exit}' /proc/cpuinfo
printf 'cores=%s\n' "$(nproc 2>/dev/null)"

# up to two GPUs — prefer the bracketed marketing name, drop "(rev ..)"
lspci 2>/dev/null | awk -F': ' '/VGA compatible controller|3D controller/{
    s=$2;
    if (match(s, /\[[^]]+\]/)) s=substr(s, RSTART+1, RLENGTH-2);
    gsub(/ \(rev [^)]*\)/, "", s);
    print "gpu="s }' | head -2

# memory + root disk (value + percent, for the meters)
awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0) printf "ram=%.1f / %.1f GiB\nrampct=%d\n", (t-a)/1048576, t/1048576, ((t-a)*100)/t}' /proc/meminfo
df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); printf "disk=%s of %s\ndiskpct=%d\n", $3, $2, $5}'

# desktop / compositor / session
printf 'de=%s\n'      "${XDG_CURRENT_DESKTOP:-Hyprland}"
printf 'session=%s\n' "${XDG_SESSION_TYPE:-wayland}"
printf 'wm=%s\n'  "$(hyprctl version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v)"
printf 'res=%s\n' "$(hyprctl monitors 2>/dev/null | grep -m1 -oE '[0-9]{3,}x[0-9]{3,}')"
printf 'shell=quickshell %s\n' "$(qs --version 2>/dev/null | awk '{print $2}')"

# package count (Arch)
command -v pacman >/dev/null 2>&1 && printf 'pkgs=%s\n' "$(pacman -Q 2>/dev/null | wc -l)"

# load average (1 / 5 / 15 min)
awk '{printf "load=%s  %s  %s\n", $1, $2, $3}' /proc/loadavg
