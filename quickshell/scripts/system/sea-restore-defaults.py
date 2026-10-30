#!/usr/bin/env python3
"""Restore the file manager only while sea-fm is still the selected default."""
import os
from pathlib import Path
import subprocess


def main():
    config = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'sea-shell'
    data = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
    try:
        current = subprocess.run(['xdg-mime', 'query', 'default', 'inode/directory'],
                                 capture_output=True, text=True, timeout=20, check=True).stdout.strip()
        before = config / 'before-filemanager'
        if current == 'sea-fm.desktop':
            if before.is_file() and before.read_text().strip() not in ('', 'sea-fm.desktop'):
                previous = before.read_text().strip()
                subprocess.run(['xdg-mime', 'default', previous, 'inode/directory'], timeout=20, check=True)
                print('Restored file manager: ' + previous)
            else:
                print('Kept Files default: no previous file manager was recorded; choose one in your desktop settings.')
                return
        else:
            print('Kept your current file manager: ' + (current or 'unset'))
        desktop = data / 'applications/sea-fm.desktop'
        backup = desktop.with_suffix('.desktop.before-sea-shell')
        if desktop.is_file() and desktop.read_text().startswith('# Managed by sea-shell: sea-register-files.py'):
            desktop.unlink()
            if backup.is_file():
                backup.replace(desktop)
                print('Restored previous sea-fm.desktop')
            else:
                print('Removed sea-shell Files registration')
    except (OSError, subprocess.SubprocessError) as exc:
        print('Could not restore file manager: ' + str(exc))


if __name__ == '__main__':
    main()
