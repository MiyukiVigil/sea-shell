#!/bin/sh
# sea-shell — automatically enable HDMI audio on NVIDIA cards when connected,
# and set it as the default output device.

# 1. Find the NVIDIA audio card name dynamically using pactl and jq
NVIDIA_CARD=$(pactl -f json list cards 2>/dev/null | jq -r '.[] | select(.properties["device.vendor.name"] | contains("NVIDIA")) | .name' | head -n1)

if [ -n "$NVIDIA_CARD" ]; then
    # Enable the digital stereo profile on the NVIDIA card
    pactl set-card-profile "$NVIDIA_CARD" output:hdmi-stereo 2>/dev/null
fi

# 2. Wait a brief moment for PipeWire to register the new sink
sleep 0.8

# 3. Find the sink ID of the NVIDIA HDMI audio output and set it as default
NVIDIA_SINK=$(wpctl status 2>/dev/null | grep -i 'GA106\|NVIDIA' | grep -i 'HDMI' | head -n1 | grep -oE '[0-9]+' | head -n1)
if [ -n "$NVIDIA_SINK" ]; then
    wpctl set-default "$NVIDIA_SINK" 2>/dev/null
    notify-send -a "sea-shell" "Audio Output" "Switched to HDMI (TV) audio output."
fi
