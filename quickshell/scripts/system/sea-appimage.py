#!/usr/bin/env python3
"""Install an AppImage in one step: ~/Applications, a launcher entry and its icon.

Double-clicking an AppImage in Files lands here. Installing reads the name and icon out of the
image without starting the app; the app only runs when you press Open or launch it.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

STAMP = '# Managed by sea-shell: sea-appimage.py\n'
MIME = 'application/vnd.appimage'
HANDLER = 'sea-appimage.desktop'
PATH_KEY = 'X-SeaShell-AppImage'
# Only these keys carry over from the image's own .desktop file. Exec, Icon and Actions are ours.
COPIED_KEYS = re.compile(r'(Name|GenericName|Comment|Keywords)(\[[\w@.-]+\])?$'
                         r'|Categories$|MimeType$|StartupWMClass$|StartupNotify$|Terminal$|X-AppImage-Version$')
ICON_SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
ICON_LIMIT = 10 * 1024 * 1024


class AppImageError(Exception):
    pass


def data_home():
    return Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')


def config_home():
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')


def applications():
    return data_home() / 'applications'


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`') + '"'


def check_appimage(path):
    try:
        with open(path, 'rb') as file:
            header = file.read(11)
    except OSError as error:
        raise AppImageError(f"Couldn't read {path}: {error.strerror}") from error
    if header[:4] != b'\x7fELF' or header[8:10] != b'AI':
        raise AppImageError(f'{Path(path).name} is not an AppImage.')
    if header[10] != 2:
        raise AppImageError(f'{Path(path).name} is an old type {header[10]} AppImage, which sea-shell can\'t install.')


def runtime_size(path):
    """The runtime is a plain ELF file; the image's filesystem starts right after its section table."""
    with open(path, 'rb') as file:
        header = file.read(64)
    section_table = struct.unpack('<Q', header[40:48])[0]
    entry_size, entries = struct.unpack('<HH', header[58:62])
    return section_table + entry_size * entries


def needs_extract_and_run(path):
    """Older runtimes mount through FUSE 2, which most current distros no longer ship."""
    with open(path, 'rb') as file:
        runtime = file.read(runtime_size(path))
    if b'libfuse.so.2' not in runtime:
        return False
    try:
        libraries = subprocess.run(['ldconfig', '-p'], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return 'libfuse.so.2' not in libraries


def extract(path, into):
    """Pull the top-level metadata files out. 7z reads the image without running anything."""
    path = Path(path).resolve()
    if shutil.which('7z'):
        done = subprocess.run(['7z', 'x', '-y', '-bd', '-r-', f'-o{into}', str(path),
                               '*.desktop', '*.png', '*.svg', '.DirIcon'],
                              capture_output=True, timeout=120)
        if done.returncode == 0:
            return Path(into)
    # No 7z, or a format it can't read: the image's runtime can do it, without starting the app.
    os.chmod(path, os.stat(path).st_mode | 0o111)
    for pattern in ('*.desktop', '.DirIcon', '*.png', '*.svg'):
        subprocess.run([str(path), '--appimage-extract', pattern], cwd=into,
                       capture_output=True, timeout=120)
    return Path(into) / 'squashfs-root'


def parse_desktop(text):
    fields, inside = {}, False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('['):
            inside = line == '[Desktop Entry]'
        elif inside and '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            fields.setdefault(key.strip(), value.strip())
    return fields


def contained(path, root):
    """Links inside an image may point anywhere; only follow those that stay inside it."""
    try:
        return path.is_file() and path.resolve().is_relative_to(root.resolve())
    except OSError:
        return False


def icon_kind(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'png'
    if b'<svg' in data[:2048]:
        return 'svg'
    return None


def read_bundle(path):
    """(fields of the image's .desktop file, icon bytes or None). Unreadable images give ({}, None)."""
    with tempfile.TemporaryDirectory(prefix='sea-appimage-') as temp:
        try:
            root = extract(path, temp)
        except (OSError, subprocess.SubprocessError):
            return {}, None
        if not root.is_dir():
            return {}, None
        fields = {}
        for candidate in sorted(root.glob('*.desktop')):
            if contained(candidate, root):
                fields = parse_desktop(candidate.read_text(errors='replace'))
                break
        wanted = re.sub(r'[^\w.+-]', '', fields.get('Icon', ''))
        names = [f'{wanted}.png', f'{wanted}.svg'] if wanted else []
        for name in names + ['.DirIcon']:
            icon = root / name
            if contained(icon, root) and icon.stat().st_size <= ICON_LIMIT:
                data = icon.read_bytes()
                if icon_kind(data):
                    return fields, data
        return fields, None


def name_from_file(path):
    stem = Path(path).name
    stem = re.sub(r'\.appimage$', '', stem, flags=re.I)
    stem = re.sub(r'[-_. ]+(x86[-_]64|amd64|aarch64|arm64|i[36]86|v?\d+(\.\d+)+.*)', '', stem, flags=re.I)
    return stem or 'AppImage'


def slug_of(name):
    return re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-') or hashlib.sha1(name.encode()).hexdigest()[:10]


def installed():
    """Every app installed here, as {slug: (name, AppImage path, entry path)}."""
    found = {}
    for entry in sorted(applications().glob('sea-appimage-*.desktop')):
        text = entry.read_text(errors='replace')
        if not text.startswith(STAMP):
            continue
        fields = parse_desktop(text)
        if PATH_KEY in fields:
            found[entry.stem[len('sea-appimage-'):]] = (fields.get('Name', entry.stem), Path(fields[PATH_KEY]), entry)
    return found


def exec_args(fields):
    """Keep the flags an app asks for (--no-sandbox, %U) but not the command in front of them."""
    try:
        words = shlex.split(fields.get('Exec', ''))[1:]
    except ValueError:
        return []
    kept = []
    for word in words:
        if re.fullmatch(r'%[a-zA-Z]', word):
            kept.append(word)
        elif word.startswith('-'):
            kept.append(quoted(word))
    return kept


def install_icon(slug, data):
    hicolor = data_home() / 'icons/hicolor'
    remove_icons(slug)
    if not data:
        return None
    kind = icon_kind(data)
    if kind == 'svg':
        folder = hicolor / 'scalable/apps'
    else:
        width = struct.unpack('>I', data[16:20])[0]
        size = width if width in ICON_SIZES else 256
        folder = hicolor / f'{size}x{size}/apps'
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f'sea-appimage-{slug}.{kind}').write_bytes(data)
    os.utime(hicolor)  # tells GTK any icon cache here is stale
    return f'sea-appimage-{slug}'


def remove_icons(slug):
    for icon in (data_home() / 'icons/hicolor').glob(f'*/apps/sea-appimage-{slug}.*'):
        icon.unlink(missing_ok=True)


def move_into_place(source, target):
    if source.resolve() == target.resolve():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(source, target)
    except OSError:
        # Another drive. Copy beside the target first so a running or older copy is swapped at once.
        partial = target.with_name(target.name + '.partial')
        try:
            shutil.copyfile(source, partial)
            os.replace(partial, target)
        finally:
            partial.unlink(missing_ok=True)
        source.unlink(missing_ok=True)


def write_entry(slug, name, fields, target, icon, script, fallback):
    entry = applications() / f'sea-appimage-{slug}.desktop'
    entry.parent.mkdir(parents=True, exist_ok=True)
    lines = [STAMP.rstrip(), '[Desktop Entry]', 'Type=Application', f'Name={name}']
    for key, value in fields.items():
        if COPIED_KEYS.match(key) and key != 'Name':
            lines.append(f'{key}={value}')
    if 'Categories' not in fields:
        lines.append('Categories=Utility;')
    command = [quoted(target)] + exec_args(fields)
    if fallback:
        command = ['env', 'APPIMAGE_EXTRACT_AND_RUN=1'] + command
    lines += [f'Exec={" ".join(command)}', f'TryExec={target}', f'{PATH_KEY}={target}']
    if icon:
        lines.append(f'Icon={icon}')
    lines += ['Actions=Uninstall;', '', '[Desktop Action Uninstall]', 'Name=Uninstall',
              f'Exec={quoted(script)} remove {slug}', '']
    partial = entry.with_suffix('.desktop.tmp')
    partial.write_text('\n'.join(lines))
    partial.replace(entry)
    return entry


def refresh_launcher():
    try:
        subprocess.run(['update-desktop-database', '-q', str(applications())], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


def install(path, script=None):
    """Move the image into ~/Applications and add it to the launcher. Returns a summary dict."""
    source = Path(path).expanduser()
    check_appimage(source)
    fields, icon_data = read_bundle(source)
    name = re.sub(r'[\x00-\x1f]', '', fields.get('Name', '')).strip() or name_from_file(source)
    slug = slug_of(name)
    previous = installed().get(slug)
    if previous:
        target = previous[1]
    else:
        stem = re.sub(r'[^\w.+-]+', '-', name).strip('.-') or slug
        target = Path.home() / 'Applications' / f'{stem}.AppImage'
        number = 2
        while target.exists() and target.resolve() != source.resolve():
            target = target.with_name(f'{stem}-{number}.AppImage')
            number += 1
    fallback = needs_extract_and_run(source)
    move_into_place(source, target)
    os.chmod(target, 0o755)
    icon = install_icon(slug, icon_data)
    write_entry(slug, name, fields, target, icon, script or Path(__file__).resolve(), fallback)
    refresh_launcher()
    return {'name': name, 'slug': slug, 'path': target, 'icon': icon, 'updated': bool(previous),
            'version': fields.get('X-AppImage-Version', '')}


def find(query):
    apps = installed()
    if query in apps:
        return query, apps[query]
    wanted = query.lower()
    for slug, app in apps.items():
        if app[0].lower() == wanted:
            return slug, app
    raise AppImageError(f'{query} is not installed.')


def trash(path):
    """Trash rather than delete, so a mistaken Uninstall can be taken back."""
    if subprocess.run(['gio', 'trash', str(path)], capture_output=True, timeout=30).returncode != 0:
        raise AppImageError(f"Couldn't move {path} to the trash.")


def remove(query):
    slug, (name, target, entry) = find(query)
    if target.exists():
        trash(target)
    entry.unlink(missing_ok=True)
    remove_icons(slug)
    refresh_launcher()
    return name


def launch(slug):
    subprocess.Popen(['gio', 'launch', str(applications() / f'sea-appimage-{slug}.desktop')],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def explicit_default():
    """The handler the user has chosen in mimeapps.list, if any."""
    try:
        text = (config_home() / 'mimeapps.list').read_text(errors='replace')
    except OSError:
        return None
    inside = False
    for line in text.splitlines():
        if line.startswith('['):
            inside = line.strip() == '[Default Applications]'
        elif inside and line.startswith(MIME + '='):
            return line.split('=', 1)[1].split(';')[0].strip() or None
    return None


def register(script=None):
    """Add the double-click handler. A default the user picked themselves is left alone."""
    script = script or Path(__file__).resolve()
    path = applications() / HANDLER
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(STAMP + '[Desktop Entry]\nType=Application\nName=Install AppImage\n'
                    'Comment=Add this AppImage to your apps\nIcon=system-software-install\n'
                    f'Exec={quoted(script)} open %f\nTerminal=false\nNoDisplay=true\nMimeType={MIME};\n')
    refresh_launcher()
    if explicit_default() in (None, HANDLER):
        subprocess.run(['xdg-mime', 'default', HANDLER, MIME], capture_output=True, timeout=20)
    return path


def unregister():
    """Take the handler away again. Installed apps are the user's and stay."""
    listing = config_home() / 'mimeapps.list'
    if explicit_default() == HANDLER:
        kept = [line for line in listing.read_text().splitlines(True) if line.strip() != f'{MIME}={HANDLER};'
                and line.strip() != f'{MIME}={HANDLER}']
        listing.write_text(''.join(kept))
    (applications() / HANDLER).unlink(missing_ok=True)
    refresh_launcher()


def notify(title, body, icon='system-software-install', action=None, urgency=None):
    command = ['notify-send', '-a', 'sea-shell', '-i', icon]
    if urgency:
        command += ['-u', urgency]
    if action:
        command += ['-t', '20000', '-A', f'go={action}']
    try:
        # With an action this waits until the notification goes away, then says which was pressed.
        done = subprocess.run(command + ['--', title, body], capture_output=True, text=True)
    except OSError:
        return False
    return done.stdout.strip() == 'go'


def open_file(path):
    """What a double-click does: launch it if it's already installed, otherwise install it."""
    source = Path(path).expanduser()
    try:
        for slug, (_, target, _) in installed().items():
            if target.exists() and source.exists() and source.samefile(target):
                launch(slug)
                return 0
        result = install(source)
    except (AppImageError, OSError) as error:
        notify("Couldn't install AppImage", str(error), icon='dialog-error', urgency='critical')
        return 1
    verb = 'updated' if result['updated'] else 'installed'
    title = f"{result['name']} {verb}"
    if notify(title, 'It\'s in your apps now. The file moved to ~/Applications.',
              icon=result['icon'] or 'system-software-install', action='Open'):
        launch(result['slug'])
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('install', help='install one or more AppImages').add_argument('files', nargs='+')
    commands.add_parser('open', help='launch if installed, otherwise install').add_argument('file')
    commands.add_parser('remove', help='uninstall an app, by name').add_argument('name')
    commands.add_parser('list', help='show installed apps')
    commands.add_parser('register', help='handle AppImage double-clicks')
    commands.add_parser('unregister', help='stop handling AppImage double-clicks')
    args = parser.parse_args()
    try:
        if args.command == 'install':
            for file in args.files:
                result = install(file)
                print(f"{'Updated' if result['updated'] else 'Installed'} {result['name']}: {result['path']}")
        elif args.command == 'open':
            return open_file(args.file)
        elif args.command == 'remove':
            name = remove(args.name)
            notify(f'{name} uninstalled', 'The file is in the trash if you want it back.')
            print(f'Removed {name}')
        elif args.command == 'list':
            for slug, (name, target, _) in installed().items():
                print(f'{slug}\t{name}\t{target}')
        elif args.command == 'register':
            print(register())
        elif args.command == 'unregister':
            unregister()
    except (AppImageError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
