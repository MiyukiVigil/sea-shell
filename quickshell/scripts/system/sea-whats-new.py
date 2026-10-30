#!/usr/bin/env python3
"""Claim the once-only 7.0 update page for an existing installation."""
import json
import os
import sys
from pathlib import Path


def claim(config, version, first_run=False):
    try:
        major = int(version.split('.')[0])
        if major != 7:
            return False
        if not first_run and not json.loads((config / 'appearance.json').read_text()).get('welcomed'):
            return False
        config.mkdir(parents=True, exist_ok=True)
        marker = config / 'whats-new-7.0'
        with marker.open('x') as out:
            out.write(version + '\n')
        return not first_run
    except (OSError, ValueError, TypeError):
        return False


if __name__ == '__main__':
    config = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'sea-shell'
    try:
        version = Path(__file__).with_name('VERSION').read_text().strip()
    except OSError:
        version = '0'
    print('show' if claim(config, version, '--fresh' in sys.argv[1:]) else 'skip')
