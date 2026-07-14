#!/bin/sh
# sea-shell — cava audio visualizer backend wrapper
# outputs 8 space-separated bar values in real-time

conf="/tmp/sea-cava-$USER.conf"

# build configuration
cat <<EOF > "$conf"
[general]
framerate = 30
bars = 8

[output]
method = raw
data_format = ascii
EOF

# run cava with temporary config
exec cava -p "$conf"
