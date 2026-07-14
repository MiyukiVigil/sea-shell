#!/bin/sh
geom=$(slurp -p 2>/dev/null) || exit 1
grim -g "$geom" -t ppm - 2>/dev/null | python3 -c "import sys; data = sys.stdin.buffer.read(); print('#' + ''.join(f'{b:02x}' for b in data[-3:]))"
