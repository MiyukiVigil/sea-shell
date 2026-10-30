#!/usr/bin/env python3
"""Map the current accent to a stock Papirus folder colour."""
import json
import os
from pathlib import Path
import subprocess
import sys

COLORS = {"blue": "5294e2", "cyan": "00bcd4", "green": "87b158",
          "grey": "8e8e8e", "orange": "ee923a", "pink": "f28fad",
          "red": "ef5350", "teal": "16a085", "violet": "9c7ac6", "yellow": "f9bd30"}


def nearest(accent):
    def rgb(value):
        value = value.lstrip('#')
        if len(value) != 6:
            raise ValueError('expected six-digit colour')
        return tuple(int(value[i:i+2], 16) for i in (0, 2, 4))
    target = rgb(accent)
    return min(COLORS, key=lambda key: sum((a-b)**2 for a, b in zip(target, rgb(COLORS[key]))))


def main():
    reset = sys.argv[1:] == ['--reset']
    if sys.argv[1:] and not reset:
        return 2
    cfg = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'sea-shell/appearance.json'
    try:
        data = json.loads(cfg.read_text())
        if not reset and not data.get('folderColorFollow', False):
            return 0
        color = 'default' if reset else nearest(data.get('accent', '#63c7dd'))
    except (OSError, ValueError, TypeError):
        return 1
    helper = '/usr/local/bin/sea-folder-color'
    if not Path(helper).is_file():
        print('Folder colour helper is not installed', file=sys.stderr)
        return 1
    return subprocess.run(['/usr/bin/sudo', '-n', helper, color], check=False).returncode


if __name__ == '__main__':
    sys.exit(main())
