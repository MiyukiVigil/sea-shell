#!/usr/bin/env python3
"""Synchronize installed icon-theme variants across GTK and Qt configuration."""
import argparse,configparser,json,os,subprocess
from pathlib import Path

def choose(theme, mode, roots):
    installed={p.name for root in roots if root.is_dir() for p in root.iterdir() if (p/'index.theme').is_file()}
    base=theme or 'breeze'
    candidates=([base+'-Dark',base+'-dark',base] if mode=='dark' else [base+'-Light',base+'-light',base])
    return next((name for name in candidates if name in installed),next((name for name in ('breeze','Adwaita','hicolor') if name in installed),'hicolor'))
def write_ini(path,section,key,value):
    parser=configparser.ConfigParser(interpolation=None);parser.optionxform=str
    if path.exists():parser.read(path)
    if not parser.has_section(section):parser.add_section(section)
    parser.set(section,key,value);path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.sea-tmp')
    with temporary.open('w') as out:parser.write(out,space_around_delimiters=False)
    temporary.replace(path)
def apply(mode,theme=None):
    config=Path(os.environ.get('XDG_CONFIG_HOME') or Path.home()/'.config')
    appearance=config/'sea-shell/appearance.json'
    try:data=json.loads(appearance.read_text())
    except (OSError,ValueError):data={}
    data_home=Path(os.environ.get('XDG_DATA_HOME') or Path.home()/'.local/share')
    roots=[data_home/'icons',Path.home()/'.icons']+[Path(p)/'icons' for p in os.environ.get('XDG_DATA_DIRS','/usr/local/share:/usr/share').split(':')]
    selected=choose(theme or data.get('iconTheme','breeze'),mode,roots)
    for version in ('gtk-3.0','gtk-4.0'):write_ini(config/version/'settings.ini','Settings','gtk-icon-theme-name',selected)
    for version in ('qt5ct','qt6ct'):write_ini(config/version/(version+'.conf'),'Appearance','icon_theme',selected)
    try:subprocess.run(['gsettings','set','org.gnome.desktop.interface','icon-theme',selected],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
    except (OSError,subprocess.TimeoutExpired):pass
    return selected
def preview_icons(theme, mode, roots):
    selected=choose(theme,mode,roots)
    output={}
    for key,name in {'folder':'folder','text':'text-x-generic','image':'image-x-generic'}.items():
        for family in dict.fromkeys((selected,theme,'Adwaita','hicolor')):
            for root in roots:
                base=root/family
                parser=configparser.ConfigParser(interpolation=None)
                try:parser.read(base/'index.theme')
                except configparser.Error:continue
                dirs=parser.get('Icon Theme','Directories',fallback='').split(',')
                dirs+=parser.get('Icon Theme','ScaledDirectories',fallback='').split(',')
                dirs=sorted(set(d for d in dirs if d),key=lambda d:(not ('32' in d or 'scalable' in d),d))
                found=next((base/d/(stem+ext) for stem in (name,name+'-symbolic') for d in dirs for ext in ('.svg','.png') if (base/d/(stem+ext)).is_file()),None)
                if found:output[key]=found.resolve().as_uri();break
            if key in output:break
    return output

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['light','dark'],default='dark')
    parser.add_argument('--theme');parser.add_argument('--list',action='store_true');parser.add_argument('--catalog',action='store_true')
    args=parser.parse_args()
    if args.list or args.catalog:
        roots=[Path.home()/'.local/share/icons',Path.home()/'.icons']+[Path(p)/'icons' for p in os.environ.get('XDG_DATA_DIRS','/usr/local/share:/usr/share').split(':')]
        names=sorted({p.name for root in roots if root.is_dir() for p in root.iterdir() if (p/'index.theme').is_file() and not (p/'cursors').is_dir() and p.name not in ('hicolor','locolor','default') and not p.name.lower().endswith(('-dark','-light'))})
        print(json.dumps([{'name':name,'light':preview_icons(name,'light',roots),'dark':preview_icons(name,'dark',roots)} for name in names] if args.catalog else names))
    else:print(apply(args.mode,args.theme))
