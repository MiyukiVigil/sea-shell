#!/usr/bin/env python3
"""Shared presentation profile; never changes account credentials or PAM."""
import getpass
import html
import json
from pathlib import Path
import re
import sys

BASE = Path.home()/'.config/sea-shell'
DEFAULTS = dict(name=getpass.getuser(), avatar=str(Path.home()/'Pictures/icons/pfp.png'), font='Adwaita Sans', color='#7165aa', glow=False, nameSize=22, clockSize=82, clock24=True, showDate=True, showMedia=True, showAvatar=True)

def validate(v):
    out=DEFAULTS | v
    for key in ('name','font','avatar'):
        if not isinstance(out[key],str) or any(c in out[key] for c in '\n\r\x00{}'):
            raise ValueError('Invalid '+key)
    if out['name'].startswith('cmd[') or '$' in out['name']: raise ValueError('Use a plain display name')
    if not re.fullmatch(r'#[0-9a-fA-F]{6}',out['color']): raise ValueError('Use a color like #aabbcc')
    for key,lo,hi in [('nameSize',12,40),('clockSize',40,120)]:
        out[key]=int(out[key])
        if not lo<=out[key]<=hi: raise ValueError('Invalid '+key)
    for key in ('glow','clock24','showDate','showMedia','showAvatar'):
        if not isinstance(out[key],bool): raise ValueError('Invalid '+key)
    if out['avatar'] and not Path(out['avatar']).expanduser().is_file(): raise ValueError('Profile picture not found')
    return out

def patch_lock(text,v):
    def replace(match):
        block=match.group(0)
        def put(key,value):
            nonlocal block
            if re.search(r'^\s*'+key+r'\s*=',block,re.M):
                block=re.sub(r'^(\s*'+key+r'\s*=).*$',lambda m:m[1]+' '+str(value),block,flags=re.M)
            else: block=block[:-1]+'    '+key+' = '+str(value)+'\n}'
        if block.startswith('label'):
            if 'echo "$USER"' in block or '# sea-profile-name' in block:
                put('text',html.escape(v['name'])+' # sea-profile-name')
                put('font_family',v['font']);put('font_size',v['nameSize']);put('color','rgb('+v['color'][1:]+')')
                put('shadow_passes',3 if v['glow'] else 0);put('shadow_color','rgba('+v['color'][1:]+'99)');put('shadow_size',10)
                put('position','0, -30')
            elif "date +'%H:%M'" in block or "date +'%I:%M %p'" in block:
                put('text',"cmd[update:1000] date +'"+('%H:%M' if v['clock24'] else '%I:%M %p')+"'")
                put('font_size',v['clockSize']);put('font_family',v['font']);put('position','0, 220')
            elif "date +'%A" in block or '# sea-profile-date' in block:
                put('text',("cmd[update:60000] date +'%A, %-d %B %Y'" if v['showDate'] else '')+' # sea-profile-date')
                put('position','0, 140')
            elif 'sea-nowplaying.sh' in block or '# sea-profile-media' in block:
                put('text',('cmd[update:1000] ~/.config/quickshell/sea-shell/sea-nowplaying.sh' if v['showMedia'] else '')+' # sea-profile-media')
                put('position','0, -225')
            elif '───' in block: put('text','')
            elif 'CAPS LOCK ON' in block: put('position','0, -165')
        elif block.startswith('input-field'):
            put('position','0, -100');put('rounding',18);put('size','300, 52')
        return block
    # Keep a template so toggles can restore hidden fields on subsequent saves.
    text=re.sub(r'\n# sea-profile-avatar-begin.*?# sea-profile-avatar-end\n','\n',text,flags=re.S)
    text=re.sub(r'(?:label|input-field)\s*\{[^{}]*\}',replace,text)
    if v['showAvatar'] and v['avatar']:
        text+='\n# sea-profile-avatar-begin\nimage {\n    monitor =\n    path = '+str(Path(v['avatar']).expanduser())+'\n    size = 82\n    rounding = -1\n    border_size = 3\n    border_color = rgb('+v['color'][1:]+')\n    position = 0, 50\n    halign = center\n    valign = center\n}\n# sea-profile-avatar-end\n'
    return text

if __name__=='__main__':
    try:
        state=BASE/'profile.json'
        if sys.argv[1]=='get': print(json.dumps(DEFAULTS | (json.loads(state.read_text()) if state.exists() else {})))
        elif sys.argv[1]=='set':
            v=validate(json.loads(sys.argv[2]));BASE.mkdir(parents=True,exist_ok=True)
            lock=Path.home()/'.config/hypr/hyprlock.conf'
            if lock.exists():
                template=BASE/'hyprlock-profile-template.conf'
                if not template.exists(): template.write_text(lock.read_text())
                tmp=lock.with_suffix('.conf.profile-new');tmp.write_text(patch_lock(lock.read_text(),v));tmp.replace(lock)
            tmp=state.with_suffix('.json.new');tmp.write_text(json.dumps(v,indent=2));tmp.replace(state)
            print('Profile and lock screen saved. Login theme avatar is updated separately with Apply theme.')
    except Exception as e:
        print(str(e),file=sys.stderr);sys.exit(1)
