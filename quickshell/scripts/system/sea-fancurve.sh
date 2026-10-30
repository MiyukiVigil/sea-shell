#!/bin/sh
# sea-shell — fan preset (ROOT helper).
#
#   sea-fancurve auto | quiet | max
#
#   auto    stop fancontrol and hand the fans back to the firmware's own curve
#   quiet   lm_sensors fancontrol curve with a low ceiling
#   max     stop fancontrol and pin the fans at full speed (a fixed speed cannot hunt)
#
# It runs as root, so it takes no numbers, only the named presets: a sudoers rule for it
# then cannot be used to write arbitrary values to the fans or the config.
#
# Install (once, as root; the panel's "gaming fans" row appears when this file exists):
#   sudo install -m 755 -o root -g root sea-fancurve.sh /usr/local/bin/sea-fancurve
#   echo "$USER ALL=(root) NOPASSWD: /usr/local/bin/sea-fancurve" | sudo tee /etc/sudoers.d/sea-fancurve
#   sudo chmod 440 /etc/sudoers.d/sea-fancurve
#
# quiet expects a working /etc/fancontrol (from pwmconfig) whose fans belong to one hwmon
# device. hwmon numbers can change between boots, so the device's current number is
# looked up by its DEVNAME and written back into the config every time.

CONF=/etc/fancontrol

name=$(sed -n 's/^DEVNAME=hwmon[0-9]*=\([^ ]*\).*/\1/p' "$CONF" 2>/dev/null)
hw=$(grep -lx "${name:-acer}" /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | cut -d/ -f5)
[ -n "$hw" ] || { echo "hwmon device '${name:-acer}' not found" >&2; exit 1; }
dev=/sys/class/hwmon/$hw

# fancontrol restores the pwm mode it found at start when it stops, so set ours after
pin() {
    systemctl disable --now fancontrol 2>/dev/null
    for p in "$dev"/pwm[0-9]; do
        echo "$1" > "${p}_enable"
        [ -n "$2" ] && echo "$2" > "$p"
    done
}

case "$1" in
    auto)  pin 2 ;;
    max)   pin 1 255 ;;
    quiet)
        [ -f "$CONF" ] || { echo "no $CONF - run pwmconfig first" >&2; exit 1; }
        # Acer fans are steep: 140 is already ~6100 rpm of ~8000. Starting the curve at 65°C
        # keeps it flat across normal temperatures instead of hunting around its start.
        sed -i -E \
            -e "s/hwmon[0-9]+/$hw/g" \
            -e "s/^(MINTEMP=).*/\1$hw\/pwm1=65 $hw\/pwm2=65/" \
            -e "s/^(MAXPWM=).*/\1$hw\/pwm1=120 $hw\/pwm2=120/" \
            -e "s/^(MAXTEMP=).*/\1$hw\/pwm1=92 $hw\/pwm2=92/" \
            "$CONF"
        systemctl enable fancontrol 2>/dev/null
        systemctl restart fancontrol ;;
    *)     echo "usage: sea-fancurve auto|quiet|max" >&2; exit 2 ;;
esac
