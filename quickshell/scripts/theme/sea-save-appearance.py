#!/usr/bin/env python3
"""Merge and atomically persist Appearance changes, preserving other settings."""
import base64,fcntl,json,os,sys,tempfile
from pathlib import Path

def save(changes, config_dir=None):
    if not isinstance(changes,dict):raise ValueError('Appearance changes must be an object')
    folder=Path(config_dir or Path.home()/'.config/sea-shell');folder.mkdir(parents=True,exist_ok=True)
    target=folder/'appearance.json'
    with (folder/'appearance.settings.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        current=json.loads(target.read_text()) if target.exists() else {}
        if not isinstance(current,dict):raise ValueError('Existing Appearance configuration is invalid')
        current.update(changes)
        fd,name=tempfile.mkstemp(prefix='.appearance-',suffix='.tmp',dir=folder)
        try:
            with os.fdopen(fd,'w') as out:
                json.dump(current,out,ensure_ascii=False,indent=2);out.write('\n')
                out.flush();os.fsync(out.fileno())
            os.replace(name,target)
        finally:
            if os.path.exists(name):os.unlink(name)
    return target
if __name__=='__main__':
    try:
        save(json.loads(base64.b64decode(sys.argv[1],validate=True)))
        print(json.dumps({'ok':True}))
    except Exception as exc:
        print(str(exc),file=sys.stderr);sys.exit(1)
