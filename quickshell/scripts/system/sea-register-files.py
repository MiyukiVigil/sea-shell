#!/usr/bin/env python3
"""Register sea-fm with the desktop; default selection is explicitly opt-in."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

STAMP = '# Managed by sea-shell: sea-register-files.py\n'
def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`') + '"'
def register(script=None, data_home=None):
    script = Path(script or Path(__file__).with_name('sea-fm.py')).resolve()
    if not script.is_file():
        raise FileNotFoundError(script)
    data = Path(data_home or os.environ.get('XDG_DATA_HOME') or Path.home()/'.local/share')
    applications = data/'applications';applications.mkdir(parents=True,exist_ok=True)
    path = applications/'sea-fm.desktop'
    if path.exists() and not path.read_text().startswith(STAMP):
        backup=path.with_suffix('.desktop.before-sea-shell')
        if not backup.exists():backup.write_bytes(path.read_bytes())
    command = quoted(sys.executable)+' '+quoted(script)
    text = STAMP+'[Desktop Entry]\nType=Application\nName=Files\nGenericName=File Manager\nComment=Browse and manage files with sea-shell\n'
    text += 'Exec='+command+' %F\nIcon=system-file-manager\nTerminal=false\nCategories=System;FileManager;\nMimeType=inode/directory;\nStartupNotify=true\nStartupWMClass=sea-fm\nActions=NewWindow;Home;\n\n'
    text += '[Desktop Action NewWindow]\nName=New Window\nExec='+command+'\n\n'
    text += '[Desktop Action Home]\nName=Home\nExec='+command+' '+quoted(Path.home())+'\n'
    temporary=path.with_suffix('.desktop.tmp');temporary.write_text(text);temporary.replace(path)
    return path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--default',action='store_true')
    args=parser.parse_args()
    path=register()
    if args.default:
        defaults=Path(__file__).with_name('sea-defaults.py')
        subprocess.run([sys.executable,str(defaults),'--set','filemanager',path.name],check=True)
    print(path)
if __name__=='__main__':main()
