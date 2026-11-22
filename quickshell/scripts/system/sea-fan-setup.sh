#!/bin/sh
# sea-shell — installs the fan daemon and its helper. Run once with sudo.
#
#   sudo sh sea-fan-setup.sh
#
# Undo with: sudo sea-fancurve firmware

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 1; }
grep -qx acer /sys/class/hwmon/hwmon*/name 2>/dev/null || { echo "no Acer fan controls on this machine" >&2; exit 1; }

here=$(dirname "$(readlink -f "$0")")
# Rust build is a few megabytes resident; the Python file is the fallback.
if [ -x "$here/sea-fand" ] && [ ! -d "$here/sea-fand" ]; then
    bin="$here/sea-fand"
elif [ -x "$here/../../../native/sea-fand/target/release/sea-fand" ]; then
    bin="$here/../../../native/sea-fand/target/release/sea-fand"
else
    bin="$here/sea-fand.py"
fi
install -o root -g root -m 755 "$bin" /usr/local/bin/sea-fand || exit 1
install -o root -g root -m 755 "$here/sea-fancurve.sh" /usr/local/bin/sea-fancurve || exit 1

cat > /etc/systemd/system/sea-fand.service <<'EOF'
[Unit]
Description=sea-shell fan curve

[Service]
Type=notify
ExecStart=/usr/local/bin/sea-fand
ExecStopPost=/usr/local/bin/sea-fand --release
Restart=on-failure
RestartSec=5
WatchdogSec=30
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if [ -n "$SUDO_USER" ]; then
    rule=$(mktemp)
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/sea-fancurve\n' "$SUDO_USER" > "$rule"
    visudo -cqf "$rule" && install -o root -g root -m 440 "$rule" /etc/sudoers.d/sea-fancurve
    rm -f "$rule"
fi

mode=$(cat /var/lib/sea-fan/mode 2>/dev/null)
/usr/local/bin/sea-fancurve "${mode:-auto}" || exit 1
# Already running from an earlier setup: "enable --now" leaves it alone, on the old code.
systemctl restart sea-fand || exit 1
systemctl is-active sea-fand
