#!/usr/bin/env python3
"""Prepare SilentSDDM previews; only explicit apply changes the system greeter."""
import configparser
import json
import os
import pwd
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

BASE = Path.home() / '.local/share/sea-shell/silent-sddm'
STATE = Path.home() / '.config/sea-shell/sddm.json'
DEFAULTS = dict(preset='default', background='', position='center', clock=True, animations=True, blur=0, avatar='')

def config():
    return configparser.ConfigParser(interpolation=None, strict=False)

def prepare(values, base=BASE):
    v = DEFAULTS | values
    preset = str(v['preset'])
    if not re.fullmatch(r'[a-z0-9-]+', preset):
        raise ValueError('Invalid preset')
    c = config()
    if not c.read(base / 'configs' / (preset + '.conf')):
        raise ValueError('Preset is not installed')
    if v['position'] not in ('left', 'center', 'right'):
        raise ValueError('Invalid login position')
    def put(section, key, value):
        if not c.has_section(section): c.add_section(section)
        c.set(section, key, str(value))
    put('General', 'enable-animations', str(bool(v['animations'])).lower())
    put('LockScreen.Clock', 'display', str(bool(v['clock'])).lower())
    put('LoginScreen.LoginArea', 'position', '"' + v['position'] + '"')
    blur = int(v['blur'])
    if not 0 <= blur <= 100: raise ValueError('Blur must be between 0 and 100')
    for section in ('LoginScreen', 'LockScreen'):
        put(section, 'blur', blur)
    if v['background']:
        source = Path(v['background']).expanduser().resolve(strict=True)
        if not source.is_file() or source.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.webp', '.gif', '.mp4', '.webm'):
            raise ValueError('Choose an image or video file')
        target = base / 'backgrounds' / ('sea-custom' + source.suffix.lower())
        # The settings page stages on every change for its live preview, so a background
        # that is already in place (same size, same time) is not copied, or its poster cut, again.
        fresh = not (target.exists() and target.stat().st_size == source.stat().st_size
                     and int(target.stat().st_mtime) == int(source.stat().st_mtime))
        if fresh:
            shutil.copy2(source, target)
        # A preset's poster must never flash before the custom video loads.
        poster = target.name
        if source.suffix.lower() in ('.mp4', '.webm') and (fresh or not (base / 'backgrounds' / 'sea-custom-poster.png').exists()):
            poster = 'sea-custom-poster.png'
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(source),
                '-frames:v', '1', '-vf', 'scale=1920:-2', str(base / 'backgrounds' / poster)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if source.suffix.lower() in ('.mp4', '.webm'):
            poster = 'sea-custom-poster.png'
        put('General', 'animated-background-placeholder', '"' + poster + '"')
        for section in ('LoginScreen', 'LockScreen'):
            put(section, 'background', '"' + target.name + '"')
            put(section, 'use-background-color', 'false')
    if v['avatar']:
        avatar = Path(v['avatar']).expanduser().resolve(strict=True)
        if avatar.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.webp'):
            raise ValueError('Choose an image for your avatar')
        shutil.copyfile(avatar, base / 'sea-avatar.icon')
    elif (base / 'sea-avatar.icon').exists():
        (base / 'sea-avatar.icon').unlink()
    with (base / 'configs/sea-shell.conf').open('w') as f: c.write(f)
    metadata = base / 'metadata.desktop'
    metadata.write_text(re.sub(r'^ConfigFile=.*$', 'ConfigFile=configs/sea-shell.conf', metadata.read_text(), flags=re.M))
    return v

PREVIEW = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'sea-shell/sddm-preview'

def build_preview(base=BASE):
    """A copy of the theme that settings can draw in place of sddm-greeter.

    Only one file differs: components/Config.qml asks a small singleton for each option
    instead of the greeter's `config` object, and that singleton reads configs/sea-shell.conf
    itself (and watches it), so a change made in settings reaches the preview with no reload.
    The large folders are links, not copies.
    """
    stamp = PREVIEW / '.source-mtime'
    source_mtime = str(int((base / 'components/Config.qml').stat().st_mtime))
    if stamp.exists() and stamp.read_text() == source_mtime:
        return PREVIEW
    if PREVIEW.exists(): shutil.rmtree(PREVIEW)
    PREVIEW.mkdir(parents=True)
    for item in base.iterdir():
        if item.name in ('.git', 'docs', 'nix'): continue
        if item.name in ('backgrounds', 'fonts', 'icons', 'configs', 'sea-avatar.icon'):
            (PREVIEW / item.name).symlink_to(item)
        elif item.is_dir():
            shutil.copytree(item, PREVIEW / item.name)
        else:
            shutil.copy2(item, PREVIEW / item.name)
    comp = PREVIEW / 'components'
    cfg = comp / 'Config.qml'
    cfg.write_text(re.sub(r'(?<![\w."\'])config\b(?!\s*:)', 'SeaPreviewConfig.config', cfg.read_text()))
    with (comp / 'qmldir').open('a') as f: f.write('singleton SeaPreviewConfig SeaPreviewConfig.qml\n')
    (comp / 'SeaPreviewConfig.qml').write_text(PREVIEW_CONFIG_QML.replace('@CONF@', str(base / 'configs/sea-shell.conf')))
    stamp.write_text(source_mtime)
    return PREVIEW

PREVIEW_CONFIG_QML = """pragma Singleton
import QtQuick
import Quickshell.Io

// Stands in for the `config` object sddm-greeter gives a theme: the same lookups, read from
// the theme's config file, with [General] keys bare and every other key as "Section/key".
QtObject {
    id: sea
    property FileView file: FileView { path: "@CONF@"; blockLoading: true; watchChanges: true; onFileChanged: reload() }
    property var config: sea.parse(sea.file.text())
    function parse(text) {
        var o = {}, section = "General";
        var lines = (text || "").split(/\\r?\\n/);
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim();
            if (!l.length || l[0] === ";" || l[0] === "#") continue;
            if (l[0] === "[") { section = l.slice(1, l.indexOf("]")); continue }
            var eq = l.indexOf("=");
            if (eq < 0) continue;
            var k = l.slice(0, eq).trim(), v = l.slice(eq + 1).trim();
            if (v.length > 1 && v[0] === '"' && v[v.length - 1] === '"') v = v.slice(1, -1);
            o[section === "General" ? k : section + "/" + k] = v;
        }
        o.stringValue = function (k) { var v = o[k]; return v === undefined ? "" : String(v) };
        o.intValue = function (k) { var n = parseInt(o[k]); return isNaN(n) ? 0 : n };
        o.realValue = function (k) { var n = parseFloat(o[k]); return isNaN(n) ? 0 : n };
        o.boolValue = function (k) { return String(o[k]) === "true" };
        return o;
    }
}
"""

def install(stage):
    if os.geteuid() != 0: raise ValueError('Administrator authentication is required')
    stage = Path(stage).resolve(strict=True)
    if not (stage / 'Main.qml').is_file() or not (stage / 'configs/sea-shell.conf').is_file():
        raise ValueError('Prepare the theme first')
    dest = Path('/usr/share/sddm/themes/sea-silent')
    # Copy into a fresh directory before changing the selected theme.
    temporary = dest.with_name('sea-silent.new')
    if temporary.exists(): shutil.rmtree(temporary)
    shutil.copytree(stage, temporary, ignore=shutil.ignore_patterns('.git', 'docs', '*.sh'), symlinks=False)
    for p in temporary.rglob('*'):
        p.chmod(0o755 if p.is_dir() else 0o644)
    if dest.exists():
        backup = dest.with_name('sea-silent.previous')
        if backup.exists(): shutil.rmtree(backup)
        dest.rename(backup)
    temporary.rename(dest)
    if (dest / 'sea-avatar.icon').exists():
        uid = int(os.environ.get('PKEXEC_UID', os.getuid()))
        username = pwd.getpwuid(uid).pw_name
        faces = Path('/usr/share/sddm/faces')
        faces.mkdir(parents=True, exist_ok=True)
        face = faces / (username + '.face.icon')
        if face.exists() and not face.with_suffix('.icon.before-sea-shell').exists():
            shutil.copy2(face, face.with_suffix('.icon.before-sea-shell'))
        shutil.copyfile(dest / 'sea-avatar.icon', face)
        face.chmod(0o644)
    # /etc/sddm.conf overrides snippets: preserve all unrelated settings there.
    path = Path('/etc/sddm.conf')
    c = config()
    c.optionxform = str
    c.read(path)
    if path.exists() and not path.with_suffix('.conf.before-sea-shell').exists():
        shutil.copy2(path, path.with_suffix('.conf.before-sea-shell'))
    for s in ('General', 'Theme'):
        if not c.has_section(s): c.add_section(s)
    c.set('Theme', 'Current', 'sea-silent')
    c.set('General', 'InputMethod', 'qtvirtualkeyboard')
    old = c.get('General', 'GreeterEnvironment', fallback='')
    env = [x for x in old.split(',') if x and not x.startswith(('QML2_IMPORT_PATH=', 'QT_IM_MODULE='))]
    env += ['QML2_IMPORT_PATH=' + str(dest / 'components'), 'QT_IM_MODULE=qtvirtualkeyboard']
    c.set('General', 'GreeterEnvironment', ','.join(env))
    temp = path.with_suffix('.conf.sea-new')
    with temp.open('w') as f: c.write(f)
    temp.chmod(0o644)
    temp.replace(path)

if __name__ == '__main__':
    try:
        action = sys.argv[1]
        if action == 'setup':
            if not (BASE / 'Main.qml').exists():
                BASE.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(dir=BASE.parent) as temp:
                    checkout = Path(temp) / 'theme'
                    subprocess.run(['git', 'clone', '--no-checkout', '--filter=blob:none',
                        'https://github.com/uiriansan/SilentSDDM', str(checkout)], check=True,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    subprocess.run(['git', '-C', str(checkout), 'checkout',
                        'd477613b07ca13729af20cb4699b308ac7348d2f'], check=True,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    shutil.copytree(checkout, BASE, ignore=shutil.ignore_patterns('.git', 'docs'))
            print('SilentSDDM is ready to customize.')
        elif action == 'get':
            v = DEFAULTS | (json.loads(STATE.read_text()) if STATE.exists() else {})
            if not v['avatar'] and (Path.home() / 'Pictures/icons/pfp.png').is_file():
                v['avatar'] = str(Path.home() / 'Pictures/icons/pfp.png')
            v['presets'] = sorted(p.stem for p in (BASE / 'configs').glob('*.conf') if p.stem != 'sea-shell')
            v['installed'] = (BASE / 'Main.qml').exists()
            print(json.dumps(v))
        elif action in ('preview', 'apply'):
            v = prepare(json.loads(sys.argv[2]))
            STATE.parent.mkdir(parents=True, exist_ok=True)
            STATE.write_text(json.dumps(v, indent=2))
            if action == 'preview':
                env = os.environ | {'QT_IM_MODULE': 'qtvirtualkeyboard', 'QML2_IMPORT_PATH': str(BASE / 'components')}
                subprocess.Popen(['sddm-greeter-qt6', '--test-mode', '--theme', str(BASE)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                print('Preview opened. Login is disabled in preview mode.')
            else:
                result = subprocess.run(['pkexec', '--disable-internal-agent', '/usr/bin/python3',
                    str(Path(__file__).resolve()), 'install', str(BASE)], capture_output=True, text=True)
                if result.returncode == 126:
                    raise ValueError('Authentication cancelled. Your login theme was not changed.')
                if result.returncode != 0:
                    raise ValueError('Could not apply the theme. Check that the desktop authentication agent is running and try again. ' + result.stderr.strip())
                print('Applied. Your next login will use SilentSDDM.')
        elif action == 'stage':
            # For the preview inside settings: the same preparation as a preview, no greeter.
            v = prepare(json.loads(sys.argv[2]))
            STATE.parent.mkdir(parents=True, exist_ok=True)
            STATE.write_text(json.dumps(v, indent=2))
            print(str(build_preview()))
        elif action == 'install': install(sys.argv[2])
        else: raise ValueError('Unknown action')
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
