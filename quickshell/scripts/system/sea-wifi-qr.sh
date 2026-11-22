#!/bin/sh
# sea-shell — generate a scannable Wi-Fi join QR code for the active connection.
# Outputs JSON: {"ok":true,"ssid":"...","qr":"/run/user/.../sea-wifi-qr.png"}
set -u

OUT="${XDG_RUNTIME_DIR:-/tmp}/sea-wifi-qr.png"

if ! command -v nmcli >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
    printf '{"ok":false,"err":"nmcli or qrencode missing"}\n'
    exit 1
fi

# Find active Wi-Fi connection name and SSID
conn=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
if [ -z "$conn" ]; then
    printf '{"ok":false,"err":"Not connected to Wi-Fi"}\n'
    exit 1
fi

ssid=$(nmcli -g 802-11-wireless.ssid connection show "$conn" 2>/dev/null | head -1)
[ -z "$ssid" ] && ssid="$conn"
psk=$(nmcli -s -g 802-11-wireless-security.psk connection show "$conn" 2>/dev/null | head -1)
km=$(nmcli -g 802-11-wireless-security.key-mgmt connection show "$conn" 2>/dev/null | head -1)

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/;/\\;/g; s/,/\\,/g; s/:/\\:/g'; }
es=$(esc "$ssid")
ep=$(esc "$psk")

case "$km" in
    *wpa*|*sae*) sec="WPA" ;;
    *wep*)       sec="WEP" ;;
    *)           sec="nopass" ;;
esac

if [ "$sec" = "nopass" ] || [ -z "$psk" ]; then
    payload="WIFI:T:nopass;S:${es};;"
else
    payload="WIFI:T:${sec};S:${es};P:${ep};;"
fi

if qrencode -s 7 -m 2 -o "$OUT" "$payload" >/dev/null 2>&1; then
    python3 - "$ssid" "$OUT" "$sec" <<'PY'
import json, sys
print(json.dumps({"ok": True, "ssid": sys.argv[1], "qr": sys.argv[2], "security": sys.argv[3]}))
PY
    exit 0
fi

printf '{"ok":false,"err":"Failed to generate QR code"}\n'
exit 1
