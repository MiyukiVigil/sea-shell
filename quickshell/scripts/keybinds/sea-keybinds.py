#!/usr/bin/env python3
"""Source-backed keybind editing. Runtime Lua dispatcher args are opaque handles."""
import hashlib,json,os,re,shutil,subprocess,sys,tempfile
from pathlib import Path

def split_args(text):
    out=[];start=0;depth=0;quote='';escape=False
    for i,c in enumerate(text):
        if quote:
            if escape:escape=False
            elif c=='\\':escape=True
            elif c==quote:quote=''
        elif c in '\"\'':quote=c
        elif c in '([{':depth+=1
        elif c in ')]}':
            if depth==0:out.append(text[start:i].strip());return out
            depth-=1
        elif c==',' and depth==0:out.append(text[start:i].strip());start=i+1
    return []
def literal(value):
    try:return json.loads(value)
    except (ValueError,TypeError):return None

def records(path):
    text=path.read_text();constants=dict(re.findall(r'local\s+(\w+)\s*=\s*"([^"\n]*)"',text));out=[]
    for index,line in enumerate(text.splitlines(keepends=True)):
        match=re.search(r'hl\.bind\(',line)
        if not match:continue
        args=split_args(line[match.end():])
        if len(args)<3:continue
        desc=re.search(r'description\s*=\s*("(?:\\.|[^"\\])*")',args[2])
        if not desc:continue
        pieces=[literal(p.strip()) if p.strip().startswith('"') else constants.get(p.strip()) for p in args[0].split('..')]
        if any(p is None for p in pieces):continue
        keys=''.join(pieces).split('+');keys=[k.strip() for k in keys]
        cmd=re.fullmatch(r'hl\.dsp\.exec_cmd\(("(?:\\.|[^"\\])*")\)',args[1])
        out.append(dict(id=hashlib.sha256((str(path.resolve())+'\0'+line).encode()).hexdigest(),index=index,
                        desc=literal(desc[1]),key=keys[-1],mods=keys[:-1],args=args,line=line,
                        command=literal(cmd[1]) if cmd else None))
    return out

def mutate(path,identity,mods=None,key=None,command=None,delete=False):
    candidates=[r for r in records(path) if r['id']==identity]
    if len(candidates)!=1:raise ValueError('Shortcut changed or is ambiguous. Refresh and try again.')
    rec=candidates[0];lines=path.read_text().splitlines(keepends=True)
    if delete:del lines[rec['index']]
    else:
        if not key or '\n' in key:raise ValueError('A valid shortcut key is required')
        args=rec['args'];args[0]=json.dumps(' + '.join(mods+[key]),ensure_ascii=False)
        if command is not None:
            if rec['command'] is None:raise ValueError('This action is not a plain command')
            args[1]='hl.dsp.exec_cmd('+json.dumps(command,ensure_ascii=False)+')'
        start=rec['line'].index('hl.bind(')+len('hl.bind(')
        # Keep trailing comments and options unchanged.
        # The call's balanced closing parenthesis is identified by the original args.
        tail=rec['line'][start:];depth=0;quote='';escape=False;end=None
        for i,c in enumerate(tail):
            if quote:
                if escape:escape=False
                elif c=='\\':escape=True
                elif c==quote:quote=''
            elif c in '\"\'':quote=c
            elif c in '([{':depth+=1
            elif c in ')]}':
                if depth==0:end=i;break
                depth-=1
        if end is None:raise ValueError('Unsupported binding format')
        lines[rec['index']]=rec['line'][:start]+', '.join(args)+rec['line'][start+end:]
    shutil.copy2(path,path.with_suffix(path.suffix+'.before-settings'))
    fd,name=tempfile.mkstemp(prefix='.keybinds-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:f.write(''.join(lines));f.flush();os.fsync(f.fileno())
        os.chmod(name,path.stat().st_mode & 0o777);os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

def config_path():
    p=Path.home()/'.config/hypr/sea-shell/keybinds.lua'
    if not p.exists():
        repo=(Path.home()/'.config/sea-shell/.repo').read_text().strip();p=Path(repo)/'hypr/keybinds.lua'
    return p

def main(argv):
    path=config_path()
    if argv[0]=='--list':
        source=records(path);live=json.loads(subprocess.check_output(['hyprctl','binds','-j']))
        for b in live:
            mods=[name for mask,name in [(64,'SUPER'),(4,'CTRL'),(8,'ALT'),(1,'SHIFT')] if b.get('modmask',0)&mask]
            matches=[r for r in source if r['desc']==b.get('description') and r['key'].lower()==b.get('key','').lower() and set(r['mods'])==set(mods)]
            b['sourceId']=matches[0]['id'] if len(matches)==1 else ''
            b['sourceCommand']=matches[0]['command'] if len(matches)==1 else None
        print(json.dumps(live));return
    identity=argv[1]
    if argv[0]=='--delete':mutate(path,identity,delete=True)
    elif argv[0]=='--edit':mutate(path,identity,argv[2].split(),argv[3],argv[4] if len(argv)>4 else None)
    else:raise ValueError('Unknown operation')
    repo_file=Path.home()/'.config/sea-shell/.repo'
    if repo_file.exists():
        dest=Path(repo_file.read_text().strip())/'hypr/keybinds.lua'
        if dest.exists() and dest.resolve()!=path.resolve():shutil.copy2(path,dest)
    subprocess.run(['hyprctl','reload'],check=True,stdout=subprocess.DEVNULL)
    errors=subprocess.check_output(['hyprctl','configerrors'],text=True).strip()
    if errors:raise ValueError('Configuration reload reported errors: '+errors)
    print('Saved')
if __name__=='__main__':
    try:main(sys.argv[1:])
    except Exception as e:print(str(e),file=sys.stderr);sys.exit(1)
