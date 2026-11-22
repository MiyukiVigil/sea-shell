#!/usr/bin/env python3
"""Claim the once-per-release update page (7.0 onwards) for an existing installation.

One marker per minor release, whats-new-<major>.<minor>, so 7.1 shows its own page to a
machine that already saw 7.0's, and a 7.1.x patch does not show it again."""
import json
import os
import sys
from pathlib import Path


def claim(config, version, first_run=False):
    try:
        parts = version.split('.')
        major, minor = int(parts[0]), int(parts[1]) if len(parts) > 1 else 0
        if major < 7:
            return False
        if not first_run and not json.loads((config / 'appearance.json').read_text()).get('welcomed'):
            return False
        config.mkdir(parents=True, exist_ok=True)
        marker = config / f'whats-new-{major}.{minor}'
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
