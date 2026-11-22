#!/usr/bin/env python3
"""Game library (Steam, TwintailLauncher, Lutris, Heroic, Prism Launcher) + gaming session history for sea-shell."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CFG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'sea-shell'
DATA_FILE = CFG / 'gaming.json'
PROFILES_FILE = CFG / 'gaming-profiles.json'
MAX_SESSIONS = 120
DEFAULT_PROFILE = {
    'gamemode': True,
    'game_mode_on_play': True,
    'mangohud': False,
    # Empty leaves ~/.config/MangoHud/MangoHud.conf in charge. Set values override it per launch.
    'mh_fps': '',       # '' | '0' | '60' | '120' | '144'
    'mh_look': '',      # '' | 'fps' | 'compact' | 'full'
    'mh_corner': '',    # '' | top-left | top-right | bottom-left | bottom-right
    'gamescope': '',
    'env': {},
}
TWINTAIL_PREFIX = 'twintail:'
LUTRIS_PREFIX = 'lutris:'
LUTRIS_FLATPAK = 'net.lutris.Lutris'
HEROIC_PREFIX = 'heroic:'
HEROIC_FLATPAK = 'com.heroicgameslauncher.hgl'
PRISM_PREFIX = 'prism:'
PRISM_FLATPAK = 'org.prismlauncher.PrismLauncher'
MAX_ART_BYTES = 40 * 1024 * 1024
MH_LOOKS = {
    'fps': 'fps_only,font_size=28,background_alpha=0.45,round_corners=8',
    'compact': 'horizontal,hud_compact,hud_no_margin,fps,frametime,gpu_stats,cpu_stats,font_size=18,background_alpha=0.35,round_corners=0',
    'full': 'fps,frametime,cpu_stats,cpu_temp,gpu_stats,gpu_temp,gpu_power,vram,ram,font_size=20,background_alpha=0.5,round_corners=10',
}
MH_CORNERS = ('top-left', 'top-right', 'bottom-left', 'bottom-right')


def _mangohud_config(prof: dict) -> str:
    """read_cfg first so MangoHud.conf applies, then the profile overrides, then the log folder."""
    log_dir = CFG / 'mangohud-logs'
    parts = ['read_cfg']
    look = str(prof.get('mh_look') or '')
    if look in MH_LOOKS:
        parts.append(MH_LOOKS[look])
    corner = str(prof.get('mh_corner') or '')
    if corner in MH_CORNERS:
        parts.append(f'position={corner}')
    fps = str(prof.get('mh_fps') or '')
    if fps == '0':
        parts.append('fps_limit=0')
    elif fps.isdigit():
        parts.append(f'fps_limit={fps},0')
        parts.append('toggle_fps_limit=Shift_L+F1')
    parts.append(f'output_folder={log_dir}')
    return ','.join(parts)


GAMESCOPE_PRESETS = {
    '': '',
    '1080p': '-W 1920 -H 1080 -f --',
    '1080p-windowed': '-W 1920 -H 1080 -w 1920 -h 1080 --',
}
# Gamescope leaves itself running if it hangs after its game exits, and fullscreen that is a black
# window over the desktop. Runs inside Gamescope: gives it a moment to exit on its own, then ends it.
GAMESCOPE_CHILD = '''
gs=$1; shift
"$@"
st=$?
setsid sh -c 'sleep 5
    grep -qa gamescope "/proc/$0/cmdline" 2>/dev/null || exit 0
    kill "$0"; sleep 2
    grep -qa gamescope "/proc/$0/cmdline" 2>/dev/null && kill -KILL "$0"' "$gs" >/dev/null 2>&1 &
exit $st
'''


def _acf_field(text: str, key: str) -> str:
    m = re.search(rf'"{re.escape(key)}"\s+"([^"]*)"', text)
    return m.group(1) if m else ''


def _steam_root() -> Path:
    home = Path.home()
    for p in (home / '.local/share/Steam', home / '.steam/root', home / '.steam/steam'):
        if (p / 'steamapps').is_dir():
            return p
    return home / '.local/share/Steam'


def _local_asset(appid: str, names: tuple[str, ...]) -> str:
    """Steam's on-disk library cache (works offline; CDN often 404s for new titles)."""
    base = _steam_root() / 'appcache/librarycache' / appid
    if not base.is_dir():
        return ''
    for name in names:
        for path in base.rglob(name):
            if path.is_file():
                return path.as_uri()
    return ''


def _local_art(appid: str) -> str:
    return _local_asset(appid, ('library_capsule.jpg', 'library_header.jpg', 'library_hero.jpg', 'logo.png'))


def _steam_records() -> dict[str, dict[str, int]]:
    """Steam's own play records (minutes, epoch seconds) from each account's localconfig.vdf."""
    records: dict[str, dict[str, int]] = {}
    for path in (_steam_root() / 'userdata').glob('*/config/localconfig.vdf'):
        try:
            text = path.read_text(errors='replace')
        except OSError:
            continue
        stack: list[str] = []
        pending = ''
        for raw in text.splitlines():
            line = raw.strip()
            if line == '{':
                stack.append(pending)
            elif line == '}':
                if stack:
                    stack.pop()
            else:
                m = re.fullmatch(r'"([^"]*)"(?:\s+"([^"]*)")?', line)
                if not m:
                    continue
                key, value = m.groups()
                if value is None:
                    pending = key
                elif (key in ('LastPlayed', 'Playtime', 'Playtime2wks') and value.isdigit()
                      and len(stack) >= 2 and stack[-2].lower() == 'apps' and stack[-1].isdigit()):
                    record = records.setdefault(stack[-1], {})
                    record[key] = max(record.get(key, 0), int(value))
    return records


def _steamapps_dirs() -> list[Path]:
    dirs: list[Path] = []
    seen: set[Path] = set()
    home = Path.home()
    candidates = [
        home / '.local/share/Steam/steamapps',
        home / '.steam/root/steamapps',
        home / '.steam/steam/steamapps',
    ]
    lib_vdf = home / '.local/share/Steam/config/libraryfolders.vdf'
    if not lib_vdf.is_file():
        lib_vdf = home / '.steam/root/config/libraryfolders.vdf'
    if lib_vdf.is_file():
        try:
            for m in re.finditer(r'"path"\s+"([^"]+)"', lib_vdf.read_text(errors='replace')):
                p = Path(m.group(1).replace('\\\\', '/')) / 'steamapps'
                candidates.append(p)
        except OSError:
            pass
    for p in candidates:
        try:
            rp = p.resolve()
        except OSError:
            continue
        if rp.is_dir() and rp not in seen:
            seen.add(rp)
            dirs.append(rp)
    return dirs


def _installed_flag(state: str) -> bool:
    try:
        return (int(state) & 4) == 4
    except ValueError:
        return state.strip() == '4'


# Steam also lists Proton, runtimes, and redistributables as "installed apps".
_SKIP_NAME = re.compile(
    r'(proton\s|steam linux runtime|steamworks|redistribut|dedicated server|\btool\b|\bsdk\b|'
    r'steam client|soundtrack|demo unlock)',
    re.I,
)


def _is_playable_game(name: str, manifest: str) -> bool:
    if _SKIP_NAME.search(name):
        return False
    # Non-game depot bundles often omit a launch config.
    if 'LaunchExecutable' not in manifest and 'launch' not in manifest.lower():
        if 'commonredist' in manifest.lower() or 'steamlibrary' in name.lower():
            return False
    return True


def _last_sessions() -> dict[str, dict]:
    out: dict[str, dict] = {}
    for s in _load_data()['sessions']:
        aid = str(s.get('appid') or '')
        if aid and aid not in out:
            out[aid] = s
    return out


def _load_profiles() -> dict:
    if not PROFILES_FILE.is_file():
        return {'defaults': dict(DEFAULT_PROFILE), 'games': {}}
    try:
        raw = json.loads(PROFILES_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {'defaults': dict(DEFAULT_PROFILE), 'games': {}}
    defaults = dict(DEFAULT_PROFILE)
    defaults.update(raw.get('defaults') or {})
    games = raw.get('games') if isinstance(raw.get('games'), dict) else {}
    return {'defaults': defaults, 'games': games}


def _save_profiles(data: dict) -> None:
    CFG.mkdir(parents=True, exist_ok=True)
    PROFILES_FILE.write_text(json.dumps(data, indent=2) + '\n')


def profile_for(appid: str) -> dict:
    store = _load_profiles()
    merged = dict(store['defaults'])
    override = store['games'].get(str(appid), {})
    for key in DEFAULT_PROFILE:
        if key in override:
            merged[key] = override[key]
    if isinstance(override.get('env'), dict):
        merged['env'] = {**dict(merged.get('env') or {}), **override['env']}
    if override.get('steam_launch_options'):
        merged['steam_launch_options'] = override['steam_launch_options']
    return merged


def profile_patch(appid: str, patch: dict) -> dict:
    store = _load_profiles()
    cur = store['games'].setdefault(str(appid), {})
    for key, val in patch.items():
        if key == 'env' and isinstance(val, dict):
            base = cur.get('env') if isinstance(cur.get('env'), dict) else {}
            merged = {**base, **val}
            # null removes a variable; merging alone could never take one back out.
            cur['env'] = {k: v for k, v in merged.items() if v is not None}
        else:
            cur[key] = val
    _save_profiles(store)
    return profile_for(appid)


def profile_reset(appid: str) -> dict:
    """Drops a game's own settings, so it follows the defaults in Settings again."""
    store = _load_profiles()
    store['games'].pop(str(appid), None)
    _save_profiles(store)
    return profile_for(appid)


def defaults() -> dict:
    return dict(_load_profiles()['defaults'])


def defaults_patch(patch: dict) -> dict:
    store = _load_profiles()
    for key, val in patch.items():
        if key not in DEFAULT_PROFILE:
            continue
        if key == 'env' and isinstance(val, dict):
            base = store['defaults'].get('env') if isinstance(store['defaults'].get('env'), dict) else {}
            store['defaults']['env'] = {**base, **val}
        else:
            store['defaults'][key] = val
    _save_profiles(store)
    return defaults()


def search_library(query: str, limit: int = 24) -> list[dict]:
    q = (query or '').strip().lower()
    hits: list[tuple[int, dict]] = []
    for game in library():
        name = game['name'].lower()
        if not q:
            score = game.get('last_played') or 0
        elif q in name:
            score = 1000 - name.index(q) + len(q)
        else:
            words = q.split()
            if not all(w in name for w in words):
                continue
            score = sum(100 - name.index(w) for w in words if w in name)
        hits.append((score, {
            'appid': game['appid'],
            'name': game['name'],
            'art': game.get('art') or '',
            'seconds': game.get('seconds') or 0,
            'last_played': game.get('last_played') or 0,
        }))
    hits.sort(key=lambda pair: (-pair[0], -pair[1]['last_played'], pair[1]['name'].lower()))
    return [g for _, g in hits[: max(1, limit)]]


def _fps_stats_since(since_ts: float) -> dict:
    """Parse MangoHud CSV logs written under mangohud-logs/ during a session."""
    log_dir = CFG / 'mangohud-logs'
    if not log_dir.is_dir():
        return {}
    best_path: Path | None = None
    best_mtime = since_ts
    for path in log_dir.glob('*.log'):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if mtime >= since_ts and mtime >= best_mtime:
            best_mtime = mtime
            best_path = path
    if not best_path:
        return {}
    fps_vals: list[float] = []
    try:
        for line in best_path.read_text(errors='replace').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or 'frametime' in line.lower():
                continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) < 3:
                continue
            try:
                fps_vals.append(float(parts[2]))
            except ValueError:
                continue
    except OSError:
        return {}
    if not fps_vals:
        return {}
    fps_vals.sort()
    n = len(fps_vals)
    one_pct = fps_vals[max(0, int(n * 0.01) - 1)]
    return {
        'fps_avg': round(sum(fps_vals) / n),
        'fps_1pct_low': round(one_pct),
    }


def _steam_library_free_gib() -> tuple[float, str]:
    """Free space on the partition holding the main Steam library."""
    root = _steam_root()
    try:
        usage = shutil.disk_usage(root)
        return round(usage.free / (1024 ** 3), 1), str(root)
    except OSError:
        return 0.0, str(root)


def _shader_cache_gib() -> float:
    total = 0
    for base in (_steam_root() / 'steamapps/shadercache', Path.home() / '.local/share/Steam/steamapps/shadercache'):
        if not base.is_dir():
            continue
        for path in base.rglob('*'):
            try:
                if path.is_file():
                    total += path.stat().st_size
            except OSError:
                pass
    return round(total / (1024 ** 3), 1)


def preflight() -> dict:
    checks: list[dict] = []
    gm = subprocess.run(['gamemoded', '-s'], capture_output=True, text=True, timeout=3)
    gm_ok = gm.returncode == 0
    gm_active = 'is active' in (gm.stdout or '')
    checks.append({
        'id': 'gamemoded',
        'label': 'GameMode',
        'ok': gm_ok,
        'warn': not gm_ok,
        'detail': 'daemon running' if gm_ok else 'not installed',
    })
    pp = subprocess.run(['powerprofilesctl', 'get'], capture_output=True, text=True, timeout=3)
    profile = (pp.stdout or 'balanced').strip() or 'balanced'
    checks.append({
        'id': 'power',
        'label': 'Power',
        'ok': profile == 'performance',
        'warn': profile != 'performance',
        'detail': profile,
    })
    fan = (CFG / 'gaming-fans').read_text().strip() if (CFG / 'gaming-fans').is_file() else 'custom'
    checks.append({'id': 'fans', 'label': 'Fans', 'ok': True, 'warn': False, 'detail': fan})
    free_gib, _path = _steam_library_free_gib()
    checks.append({
        'id': 'disk',
        'label': 'Library disk',
        'ok': free_gib >= 20,
        'warn': free_gib < 20,
        'detail': f'{free_gib} GiB free',
    })
    shaders = _shader_cache_gib()
    checks.append({
        'id': 'shaders',
        'label': 'Shader cache',
        'ok': shaders < 30,
        'warn': shaders >= 30,
        'detail': f'{shaders} GiB',
    })
    ready = all(c['ok'] or c.get('warn') for c in checks if c['id'] != 'shaders')
    return {'ok': ready, 'checks': checks}


def _fmt_duration(seconds: int) -> str:
    seconds = max(0, int(seconds))
    m, s = divmod(seconds, 60)
    if m >= 60:
        h, m = divmod(m, 60)
        return f'{h}h {m}m'
    if m:
        return f'{m}m {s}s'
    return f'{s}s'


def _notify_session(session: dict) -> None:
    stats = session.get('stats') or {}
    bits = [_fmt_duration(session.get('seconds', 0))]
    if stats.get('fps_avg') is not None:
        bits.append(f"{stats['fps_avg']} FPS avg")
    if stats.get('gpu_avg') is not None:
        bits.append(f"GPU {stats['gpu_avg']}% avg")
    if stats.get('gpu_temp_max') is not None:
        bits.append(f"peak {stats['gpu_temp_max']}°C")
    title = session.get('title') or 'Game session'
    subprocess.run(
        ['notify-send', 'sea-shell', f'{title} — ' + ', '.join(bits)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


RECENT_WINDOW = 14 * 86400
TOTALS_KEEP = 45 * 86400


def _session_seconds_since(since: float) -> dict[str, int]:
    out: dict[str, int] = {}
    for s in _load_data()['sessions']:
        try:
            ended = datetime.fromisoformat(str(s.get('ended', '')).replace('Z', '+00:00')).timestamp()
        except ValueError:
            continue
        aid = str(s.get('appid') or '')
        if aid and ended >= since:
            out[aid] = out.get(aid, 0) + int(s.get('seconds') or 0)
    return out


def _totals_growth(games: list[dict], now: float) -> dict[str, int]:
    """Two-week playtime for launchers that only keep a lifetime total (Lutris, Twintail): the
    library notes each total when it changes, and the growth since two weeks ago is the answer.
    Counting starts the first time a game is seen, so play from before then is not in it."""
    path = CFG / 'playtime-totals.json'
    try:
        hist = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        hist = {}
    changed = False
    out: dict[str, int] = {}
    for g in games:
        if g['source'] == 'steam':
            continue
        points = [p for p in hist.get(g['appid'], []) if now - p[0] < TOTALS_KEEP]
        total = int(g.get('seconds') or 0)
        if not points or points[-1][1] != total:
            points.append([int(now), total])
            changed = True
        hist[g['appid']] = points
        cutoff = now - RECENT_WINDOW
        before = [p for p in points if p[0] <= cutoff]
        base = before[-1][1] if before else points[0][1]
        out[g['appid']] = max(0, total - base)
    if changed:
        try:
            CFG.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(hist) + '\n')
        except OSError:
            pass
    return out


def _favourites() -> list[str]:
    data = _read_json(CFG / 'favourites.json')
    return [str(a) for a in data] if isinstance(data, list) else []


def set_favourite(appid: str, on: bool) -> list[str]:
    favs = [a for a in _favourites() if a != appid]
    if on:
        favs.insert(0, appid)
    CFG.mkdir(parents=True, exist_ok=True)
    (CFG / 'favourites.json').write_text(json.dumps(favs) + '\n')
    return favs


def _apply_recent(games: list[dict], last_sess: dict[str, dict]) -> None:
    now = time.time()
    sessions = _session_seconds_since(now - RECENT_WINDOW)
    growth = _totals_growth(games, now)
    favs = set(_favourites())
    for g in games:
        aid = g['appid']
        g['favourite'] = aid in favs
        g['recent_seconds'] = max(int(g.get('recent_seconds') or 0), sessions.get(aid, 0), growth.get(aid, 0))
        if g.get('last_session') is None:
            g['last_session'] = last_sess.get(aid)


def _proc_paths(pid: int) -> list[str]:
    """Where a process lives on disk: its folder, Wine prefix and command line, with Wine's
    Z: drive turned back into a Unix path."""
    base = Path('/proc') / str(pid)
    out = []
    try:
        out.append(os.readlink(base / 'cwd'))
    except OSError:
        pass
    try:
        for var in (base / 'environ').read_bytes().split(b'\0'):
            if var.startswith((b'WINEPREFIX=', b'STEAM_COMPAT_DATA_PATH=')):
                out.append(var.split(b'=', 1)[1].decode(errors='replace'))
    except OSError:
        pass
    try:
        for arg in (base / 'cmdline').read_bytes().split(b'\0'):
            arg = arg.decode(errors='replace')
            if re.match(r'^[zZ]:\\', arg):
                arg = arg[2:].replace('\\', '/')
            if arg.startswith('/'):
                out.append(arg)
    except OSError:
        pass
    return out


def _parent_pid(pid: int) -> int:
    try:
        stat = (Path('/proc') / str(pid) / 'stat').read_text()
        return int(stat.rsplit(')', 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def which_game(pid: int) -> dict:
    """The Lutris, Twintail, Heroic or Prism game a window's process belongs to, matched by install
    folder. Walks up a few parents, since Wine windows often belong to a helper the game started."""
    dirs = []
    for g in [*_twintail_games(), *_lutris_games(), *_heroic_games(), *_prism_games()]:
        d = g.get('directory')
        if d and len(d) > 1:
            dirs.append((d.rstrip('/') + '/', g))
    dirs.sort(key=lambda x: -len(x[0]))
    for _ in range(6):
        if pid <= 1:
            break
        for path in _proc_paths(pid):
            path = path.rstrip('/') + '/'
            for d, g in dirs:
                if path.startswith(d):
                    return {'appid': g['appid'], 'title': g['name']}
        pid = _parent_pid(pid)
    return {}


def library() -> list[dict]:
    games: dict[str, dict] = {}
    records = _steam_records()
    tracked = _load_data()['playtime']
    last_sess = _last_sessions()
    for root in _steamapps_dirs():
        for manifest in root.glob('appmanifest_*.acf'):
            try:
                text = manifest.read_text(errors='replace')
            except OSError:
                continue
            appid = _acf_field(text, 'appid') or manifest.stem.replace('appmanifest_', '')
            if not appid.isdigit():
                continue
            name = _acf_field(text, 'name') or f'Steam {appid}'
            if not _installed_flag(_acf_field(text, 'StateFlags')):
                continue
            if not _is_playable_game(name, text):
                continue
            art = _local_art(appid)
            record = records.get(appid, {})
            manifest_played = _acf_field(text, 'LastPlayed')
            manifest_size = _acf_field(text, 'SizeOnDisk')
            sess = last_sess.get(appid)
            games[appid] = {
                'appid': appid,
                'source': 'steam',
                'name': name,
                'art': art,
                'hero': _local_asset(appid, ('library_hero.jpg',))
                or f'https://steamcdn-a.akamaihd.net/steam/apps/{appid}/library_hero.jpg',
                'logo': _local_asset(appid, ('logo.png',)),
                'seconds': max(record.get('Playtime', 0) * 60, int(tracked.get(appid, 0))),
                'recent_seconds': record.get('Playtime2wks', 0) * 60,
                'last_played': max(record.get('LastPlayed', 0),
                                   int(manifest_played) if manifest_played.isdigit() else 0),
                'size': int(manifest_size) if manifest_size.isdigit() else 0,
                'profile': profile_for(appid),
                'last_session': sess,
                'icon': f'https://steamcdn-a.akamaihd.net/steam/apps/{appid}/library_600x900.jpg',
                'header': f'https://steamcdn-a.akamaihd.net/steam/apps/{appid}/header.jpg',
                'capsule': f'https://steamcdn-a.akamaihd.net/steam/apps/{appid}/capsule_616x353.jpg',
            }
    out = [*games.values(), *_twintail_games(), *_lutris_games(), *_heroic_games(), *_prism_games()]
    _apply_art(out)
    _apply_recent(out, last_sess)
    out.sort(key=lambda g: (-g['last_played'], g['name'].lower()))
    return out


def _art_file(url: str) -> Path:
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'sea-shell/game-art'
    return cache / f'{hashlib.sha256(url.encode()).hexdigest()[:20]}.jpg'


def _start_art_fetch(url: str) -> None:
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), 'cache-art', url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _cached_art(url: str) -> str:
    """A local JPEG of a launcher's art, or '' until it has been fetched in the background. Their
    art is often WebP, which Qt only reads with an extra plugin, and they go offline."""
    if not url.startswith(('https://', 'http://')):
        return ''
    out = _art_file(url)
    if out.is_file():
        return out.as_uri()
    # the library is polled; one fetch per image, and a failed one is retried a minute later
    claim = out.with_suffix('.claim')
    try:
        if time.time() - claim.stat().st_mtime < 60:
            return ''
    except OSError:
        pass
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        claim.touch()
        _start_art_fetch(url)
    except OSError:
        pass
    return ''


def cache_art(url: str) -> None:
    if not url.startswith(('https://', 'http://')):
        raise SystemExit('cache-art: not a web address')
    out = _art_file(url)
    out.parent.mkdir(parents=True, exist_ok=True)
    raw = out.with_suffix('.download')
    tmp = out.with_suffix('.tmp.jpg')
    request = urllib.request.Request(url, headers={'User-Agent': 'sea-shell'})
    try:
        with urllib.request.urlopen(request, timeout=30) as reply:
            raw.write_bytes(reply.read(MAX_ART_BYTES))
        for tool in (['magick', str(raw), '-resize', '1920x1920>', '-quality', '88', str(tmp)],
                     ['ffmpeg', '-y', '-loglevel', 'error', '-i', str(raw), '-q:v', '3', str(tmp)]):
            if shutil.which(tool[0]) and subprocess.run(tool, capture_output=True).returncode == 0:
                tmp.replace(out)
                return
    finally:
        raw.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)


def _custom_art_file(appid: str) -> Path:
    return CFG / 'game-art' / f'{re.sub(r"[^A-Za-z0-9_-]", "-", appid)}.jpg'


def _custom_art(appid: str) -> str:
    """A background the user picked for this game. The mtime query makes Qt drop its cached copy
    when the picture is replaced under the same name."""
    path = _custom_art_file(appid)
    try:
        return f'{path.as_uri()}?v={int(path.stat().st_mtime)}'
    except OSError:
        return ''


def _to_jpeg(src: Path, out: Path) -> bool:
    """Animated pictures (GIF, WebP) keep only their first frame; otherwise ImageMagick writes
    one numbered file per frame and none under the name asked for."""
    tmp = out.with_suffix('.tmp.jpg')
    try:
        for tool in (['magick', f'{src}[0]', '-resize', '1920x1920>', '-quality', '88', str(tmp)],
                     ['ffmpeg', '-y', '-loglevel', 'error', '-i', str(src), '-frames:v', '1', '-q:v', '3', str(tmp)]):
            if shutil.which(tool[0]) and subprocess.run(tool, capture_output=True).returncode == 0 and tmp.is_file():
                tmp.replace(out)
                return True
    except OSError:
        return False
    finally:
        tmp.unlink(missing_ok=True)
    return False


def set_art(appid: str, source: str) -> None:
    """Use a local picture or a web image as this game's background; '' goes back to the default."""
    out = _custom_art_file(appid)
    if not source:
        out.unlink(missing_ok=True)
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    if source.startswith(('https://', 'http://')):
        cache_art(source)
        fetched = _art_file(source)
        if not fetched.is_file():
            raise SystemExit('set-art: could not fetch that image')
        shutil.copyfile(fetched, out)
        return
    src = Path(source.removeprefix('file://')).expanduser()
    if not src.is_file():
        raise SystemExit('set-art: no such file')
    if not _to_jpeg(src, out):
        raise SystemExit('set-art: could not read that image (needs ImageMagick or ffmpeg)')


def pick_art(appid: str) -> None:
    if not shutil.which('zenity'):
        _notify('Install zenity to pick a background.')
        raise SystemExit(1)
    res = subprocess.run(
        ['zenity', '--file-selection', '--title=Choose a background',
         '--file-filter=Images | *.jpg *.jpeg *.png *.webp *.avif *.bmp'],
        capture_output=True, text=True,
    )
    path = res.stdout.strip()
    if res.returncode == 0 and path:
        set_art(appid, path)


def _steamgriddb_key() -> str:
    key = os.environ.get('STEAMGRIDDB_API_KEY', '').strip()
    if key:
        return key
    try:
        return (CFG / 'steamgriddb-key').read_text().strip()
    except OSError:
        return ''


def _get_json(url: str, headers: dict | None = None):
    request = urllib.request.Request(url, headers={'User-Agent': 'sea-shell', **(headers or {})})
    with urllib.request.urlopen(request, timeout=15) as reply:
        return json.loads(reply.read(2 * 1024 * 1024))


def _url_ok(url: str) -> bool:
    try:
        request = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'sea-shell'})
        with urllib.request.urlopen(request, timeout=10) as reply:
            return reply.status == 200
    except (OSError, ValueError):
        return False


def _norm_title(name: str) -> str:
    return re.sub(r'[^a-z0-9]+', '', name.lower().replace('™', '').replace('®', ''))


def _steamgriddb_hero(name: str, key: str) -> str:
    auth = {'Authorization': f'Bearer {key}'}
    api = 'https://www.steamgriddb.com/api/v2'
    found = _get_json(f'{api}/search/autocomplete/{urllib.parse.quote(name, safe="")}', auth).get('data') or []
    if not found:
        return ''
    wanted = _norm_title(name)
    game = next((g for g in found if _norm_title(g.get('name', '')) == wanted), found[0])
    heroes = _get_json(f'{api}/heroes/game/{game["id"]}?types=static', auth).get('data') or []
    return next((h['url'] for h in heroes if str(h.get('url', '')).startswith('https://')), '')


def _steam_store_hero(name: str) -> str:
    """Only an exact title match counts: a near one is usually a DLC or a crossover."""
    found = _get_json('https://store.steampowered.com/api/storesearch/?cc=us&l=en&term='
                      + urllib.parse.quote(name)).get('items') or []
    wanted = _norm_title(name)
    for item in found:
        if item.get('type') == 'app' and _norm_title(item.get('name', '')) == wanted:
            base = f'https://steamcdn-a.akamaihd.net/steam/apps/{item["id"]}'
            for f in ('library_hero.jpg', 'page_bg_generated_v6b.jpg'):
                if _url_ok(f'{base}/{f}'):
                    return f'{base}/{f}'
    return ''


ART_LOOKUP_RETRY = 3 * 86400


def _art_lookups() -> dict:
    try:
        return json.loads((CFG / 'art-lookup.json').read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def find_art(appid: str, name: str) -> None:
    url = ''
    key = _steamgriddb_key()
    finders = [lambda: _steamgriddb_hero(name, key)] if key else []
    finders.append(lambda: _steam_store_hero(name))
    for finder in finders:
        try:
            url = finder()
        except (OSError, ValueError, KeyError):
            url = ''
        if url:
            break
    lookups = _art_lookups()
    lookups[appid] = {'url': url, 'at': int(time.time()), 'name': name, 'keyed': bool(key)}
    CFG.mkdir(parents=True, exist_ok=True)
    (CFG / 'art-lookup.json').write_text(json.dumps(lookups, indent=1) + '\n')
    if url:
        cache_art(url)


def _found_art(appid: str, name: str, lookups: dict) -> str:
    """Background art found online for a game its launcher has none for, or '' while the
    search runs in the background. A miss is retried after a few days, or as soon as a
    SteamGridDB key is added."""
    hit = lookups.get(appid)
    if hit and hit.get('name') == name:
        if hit.get('url'):
            return _cached_art(hit['url'])
        stale = time.time() - hit.get('at', 0) > ART_LOOKUP_RETRY
        if not stale and (hit.get('keyed') or not _steamgriddb_key()):
            return ''
    claim = CFG / 'game-art' / f'{re.sub(r"[^A-Za-z0-9_-]", "-", appid)}.lookup'
    try:
        if time.time() - claim.stat().st_mtime < 300:
            return ''
    except OSError:
        pass
    try:
        claim.parent.mkdir(parents=True, exist_ok=True)
        claim.touch()
        _start_art_lookup(appid, name)
    except OSError:
        pass
    return ''


def _start_art_lookup(appid: str, name: str) -> None:
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), 'find-art', appid, name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _apply_art(games: list[dict]) -> None:
    lookups = _art_lookups()
    for g in games:
        custom = _custom_art(g['appid'])
        g['custom_hero'] = bool(custom)
        if custom:
            g['hero'] = custom
        elif not g.get('hero') and g['source'] != 'steam':
            g['hero'] = _found_art(g['appid'], g['name'], lookups)


def _twintail_db() -> Path:
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    return data / 'twintaillauncher/storage.db'


def _cached_dir_size(key: str, directory: Path) -> int:
    """Game folders are huge and the library is polled, so each version is measured once."""
    cache_file = CFG / 'game-sizes.json'
    try:
        cache = json.loads(cache_file.read_text())
    except (OSError, json.JSONDecodeError):
        cache = {}
    if key in cache:
        return int(cache[key])
    total = 0
    for root, _, files in os.walk(directory):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    cache[key] = total
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(cache) + '\n')
    except OSError:
        pass
    return total


def _twintail_games() -> list[dict]:
    """Games installed through TwintailLauncher. Its database is only ever read: launch settings
    stay in Twintail, which applies them when it starts the game."""
    path = _twintail_db()
    if not path.is_file():
        return []
    try:
        db = sqlite3.connect(f'{path.as_uri()}?mode=ro', uri=True)
        try:
            rows = db.execute(
                'SELECT i.id, i.version, COALESCE(m.display_name, i.name), i.directory, i.game_icon,'
                ' i.game_background, i.last_played_time, i.total_playtime'
                ' FROM install i LEFT JOIN manifest m ON m.id = i.manifest_id',
            ).fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return []
    out = []
    for install, version, name, directory, icon, background, played, playtime in rows:
        folder = Path(directory or '')
        if not folder.is_dir():
            continue
        art = _cached_art(background or '')
        out.append({
            'appid': f'{TWINTAIL_PREFIX}{install}',
            'source': 'twintail',
            'name': re.sub(r'\s*\(Global\)$', '', name or 'Game'),
            'art': art,
            'hero': art,
            'icon': icon or '',
            'seconds': int(playtime or 0),
            'recent_seconds': 0,
            'last_played': int(played or 0),
            'size': _cached_dir_size(f'{install}:{version}', folder),
            'directory': str(folder),
            'profile': {},
            'last_session': None,
        })
    return out


def _launch_twintail(appid: str) -> None:
    launcher = shutil.which('twintaillauncher')
    if not launcher:
        _notify_launch_error('TwintailLauncher was not found.')
        raise SystemExit(1)
    install = appid[len(TWINTAIL_PREFIX):]
    # The same command as the desktop shortcuts Twintail makes for its games.
    cmd = [launcher, f'--install={install}']
    _write_launch_log(appid, cmd)
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _lutris_data_dirs() -> list[Path]:
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    return [data / 'lutris', Path.home() / f'.var/app/{LUTRIS_FLATPAK}/data/lutris']


def _lutris_cmd() -> list[str]:
    native = shutil.which('lutris')
    if native:
        return [native]
    flatpak = shutil.which('flatpak')
    if flatpak and _lutris_data_dirs()[1].is_dir():
        return [flatpak, 'run', LUTRIS_FLATPAK]
    return []


def _lutris_art(data_dir: Path, slug: str) -> tuple[str, str]:
    """(cover, icon) as file URIs. Lutris keeps covers next to its database and icons in the
    user icon theme; anything missing stays '' so the tile falls back to its placeholder."""
    def first(paths) -> str:
        for p in paths:
            if p.is_file():
                return p.as_uri()
        return ''
    cover = first(data_dir / sub / f'{slug}.{ext}'
                  for sub in ('coverart', 'banners') for ext in ('jpg', 'png'))
    icon = first([data_dir.parent / 'icons/hicolor/128x128/apps' / f'lutris_{slug}.png',
                  data_dir / 'icons' / f'{slug}.png'])
    return cover, icon


def _lutris_games() -> list[dict]:
    """Games installed through Lutris. pga.db is only ever read: runners, Wine prefixes and
    launch options stay in Lutris, which applies them when it starts the game."""
    out = []
    seen: set[str] = set()
    for data_dir in _lutris_data_dirs():
        path = data_dir / 'pga.db'
        if not path.is_file():
            continue
        try:
            db = sqlite3.connect(f'{path.as_uri()}?mode=ro', uri=True)
            try:
                rows = db.execute(
                    'SELECT id, slug, name, directory, playtime, lastplayed, installed_at'
                    ' FROM games WHERE installed = 1',
                ).fetchall()
            finally:
                db.close()
        except sqlite3.Error:
            continue
        for gid, slug, name, directory, playtime, played, installed_at in rows:
            appid = f'{LUTRIS_PREFIX}{gid}'
            if appid in seen:
                continue
            seen.add(appid)
            folder = Path(directory or '')
            cover, icon = _lutris_art(data_dir, slug or '')
            title = (name or slug or 'Game').strip()
            out.append({
                'appid': appid,
                'source': 'lutris',
                'name': title.title() if title.islower() else title,
                'art': cover,
                'hero': cover,
                'icon': icon,
                'seconds': int(float(playtime or 0) * 3600),
                'recent_seconds': 0,
                'last_played': int(played or 0),
                'size': _cached_dir_size(f'lutris:{gid}:{installed_at}', folder) if directory and folder.is_dir() else 0,
                'directory': str(folder) if directory else '',
                'profile': {},
                'last_session': None,
            })
    return out


def _heroic_dirs() -> list[Path]:
    conf = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
    return [conf / 'heroic', Path.home() / f'.var/app/{HEROIC_FLATPAK}/config/heroic']


def _read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _heroic_installed(base: Path) -> list[tuple[str, str, str]]:
    """(runner, app name, install folder) for every store Heroic installs from."""
    out = []
    legendary = _read_json(base / 'legendaryConfig/legendary/installed.json')
    if isinstance(legendary, dict):
        for name, info in legendary.items():
            if isinstance(info, dict) and not info.get('is_dlc'):
                out.append(('legendary', info.get('app_name') or name, info.get('install_path') or ''))
    gog = _read_json(base / 'gog_store/installed.json')
    for info in (gog or {}).get('installed', []) if isinstance(gog, dict) else []:
        if isinstance(info, dict) and info.get('appName'):
            out.append(('gog', info['appName'], info.get('install_path') or ''))
    nile = _read_json(base / 'nile_config/nile/installed.json')
    for info in nile if isinstance(nile, list) else []:
        if isinstance(info, dict) and info.get('id'):
            out.append(('nile', info['id'], info.get('path') or ''))
    side = _read_json(base / 'sideload_apps/library.json')
    for info in (side or {}).get('games', []) if isinstance(side, dict) else []:
        if isinstance(info, dict) and info.get('app_name') and info.get('is_installed', True):
            folder = info.get('folder_name') or str(Path((info.get('install') or {}).get('executable') or '').parent)
            out.append(('sideload', info['app_name'], folder if folder != '.' else ''))
    return out


def _heroic_info(base: Path) -> dict[tuple[str, str], dict]:
    """Titles and art from Heroic's store caches, keyed by (runner, app name)."""
    out: dict[tuple[str, str], dict] = {}
    for runner, file, key in (('legendary', 'store_cache/legendary_library.json', 'library'),
                              ('gog', 'store_cache/gog_library.json', 'games'),
                              ('nile', 'store_cache/nile_library.json', 'library'),
                              ('sideload', 'sideload_apps/library.json', 'games')):
        data = _read_json(base / file)
        for g in (data or {}).get(key, []) if isinstance(data, dict) else []:
            if isinstance(g, dict) and g.get('app_name'):
                out[(runner, g['app_name'])] = g
    return out


def _heroic_games() -> list[dict]:
    """Epic, GOG and Amazon games installed through Heroic, and the apps added to it by hand.
    Only read: Wine versions and launch options stay in Heroic, which applies them on launch."""
    out = []
    seen: set[str] = set()
    for base in _heroic_dirs():
        if not base.is_dir():
            continue
        info = _heroic_info(base)
        played = _read_json(base / 'store/timestamp.json') or {}
        for runner, name, folder in _heroic_installed(base):
            appid = f'{HEROIC_PREFIX}{runner}:{name}'
            if appid in seen:
                continue
            seen.add(appid)
            meta = info.get((runner, name), {})
            stamp = played.get(name) if isinstance(played, dict) else None
            stamp = stamp if isinstance(stamp, dict) else {}
            try:
                last = int(datetime.fromisoformat(str(stamp.get('lastPlayed', '')).replace('Z', '+00:00')).timestamp())
            except ValueError:
                last = 0
            cover = meta.get('art_square') or meta.get('art_cover') or ''
            wide = meta.get('art_background') or meta.get('art_cover') or ''
            path = Path(folder) if folder else None
            out.append({
                'appid': appid,
                'source': 'heroic',
                'store': runner,
                'name': meta.get('title') or name,
                'art': _cached_art(cover) if cover.startswith('http') else (cover if cover.startswith('file:') else ''),
                'hero': _cached_art(wide) if wide.startswith('http') else '',
                'icon': '',
                'seconds': int(float(stamp.get('totalPlayed') or 0) * 60),
                'recent_seconds': 0,
                'last_played': last,
                'size': _cached_dir_size(f'heroic:{runner}:{name}', path) if path and path.is_dir() else 0,
                'directory': str(path) if path else '',
                'profile': {},
                'last_session': None,
            })
    return out


def _heroic_cmd() -> list[str]:
    native = shutil.which('heroic')
    if native:
        return [native]
    flatpak = shutil.which('flatpak')
    if flatpak and _heroic_dirs()[1].is_dir():
        return [flatpak, 'run', HEROIC_FLATPAK]
    return []


def _launch_heroic(appid: str) -> None:
    heroic = _heroic_cmd()
    if not heroic:
        _notify_launch_error('Heroic was not found.')
        raise SystemExit(1)
    runner, _, name = appid[len(HEROIC_PREFIX):].partition(':')
    if not runner or not name:
        raise SystemExit('Heroic id must be heroic:<runner>:<app name>')
    # The link Heroic writes into the desktop shortcuts it makes; --no-gui keeps its window shut.
    url = f'heroic://launch?appName={urllib.parse.quote(name)}&runner={urllib.parse.quote(runner)}'
    cmd = [*heroic, '--no-gui', url]
    _write_launch_log(appid, cmd)
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _launch_lutris(appid: str) -> None:
    lutris = _lutris_cmd()
    if not lutris:
        _notify_launch_error('Lutris was not found.')
        raise SystemExit(1)
    gid = appid[len(LUTRIS_PREFIX):]
    if not gid.isdigit():
        raise SystemExit('Lutris game id must be numeric')
    # The same URI Lutris puts in the desktop shortcuts it makes for its games.
    cmd = [*lutris, f'lutris:rungameid/{gid}']
    _write_launch_log(appid, cmd)
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _prism_data_dirs() -> list[Path]:
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    return [data / 'PrismLauncher', Path.home() / f'.var/app/{PRISM_FLATPAK}/data/PrismLauncher']


def _ini_general(path: Path) -> dict[str, str]:
    """The [General] keys of a Prism .cfg. Keys it has never changed are absent: Prism's default."""
    out: dict[str, str] = {}
    try:
        lines = path.read_text(errors='replace').splitlines()
    except OSError:
        return out
    section = 'General'
    for line in lines:
        line = line.strip()
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1]
        elif section == 'General' and '=' in line:
            key, _, val = line.partition('=')
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] == '"':
                val = val[1:-1]
            out[key.strip()] = val
    return out


def _local_jpeg(src: Path) -> str:
    """A file URI Qt can show for a local picture. Prism's own icons are often WebP, which Qt only
    reads with an extra plugin, so those are converted once per version of the file."""
    if src.suffix.lower() in ('.png', '.jpg', '.jpeg'):
        return src.as_uri()
    try:
        stamp = int(src.stat().st_mtime)
    except OSError:
        return ''
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'sea-shell/game-art'
    out = cache / f'{hashlib.sha256(f"{src}:{stamp}".encode()).hexdigest()[:20]}.jpg'
    if out.is_file():
        return out.as_uri()
    out.parent.mkdir(parents=True, exist_ok=True)
    return out.as_uri() if _to_jpeg(src, out) else ''


def _prism_icon(icons: Path, key: str) -> str:
    if not key or not icons.is_dir():
        return ''
    for ext in ('png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'):
        path = icons / f'{key}.{ext}'
        if path.is_file():
            return _local_jpeg(path)
    return ''


def _prism_instances() -> list[tuple[Path, Path, dict]]:
    """(data folder, instance folder, instance.cfg) for each Prism Launcher instance."""
    out = []
    for data_dir in _prism_data_dirs():
        if not data_dir.is_dir():
            continue
        root = data_dir / (_ini_general(data_dir / 'prismlauncher.cfg').get('InstanceDir') or 'instances')
        if not root.is_dir():
            continue
        for inst in sorted(root.iterdir()):
            info = _ini_general(inst / 'instance.cfg')
            if info:
                out.append((data_dir, inst, info))
    return out


def _prism_games() -> list[dict]:
    """Minecraft instances in Prism Launcher. instance.cfg is only ever read: Java, memory and
    mods stay in Prism, which applies them when it starts the instance."""
    out = []
    seen: set[str] = set()
    for data_dir, inst, info in _prism_instances():
        appid = f'{PRISM_PREFIX}{inst.name}'
        if appid in seen:
            continue
        seen.add(appid)
        icons = data_dir / (_ini_general(data_dir / 'prismlauncher.cfg').get('IconsDir') or 'icons')
        icon = _prism_icon(icons, info.get('iconKey', ''))
        game_dir = next((d for d in (inst / 'minecraft', inst / '.minecraft') if d.is_dir()), inst)
        launched = info.get('lastLaunchTime', '')
        played = info.get('totalTimePlayed', '')
        pack = inst / 'mmc-pack.json'
        version = info.get('ManagedPackVersionID') or (str(int(pack.stat().st_mtime)) if pack.is_file() else '')
        out.append({
            'appid': appid,
            'source': 'prism',
            'name': info.get('name') or inst.name,
            'art': icon,
            'hero': '',
            'icon': icon,
            'seconds': int(played) if played.isdigit() else 0,
            'recent_seconds': 0,
            'last_played': int(launched) // 1000 if launched.isdigit() else 0,
            'size': _cached_dir_size(f'prism:{inst.name}:{version}', inst),
            'directory': str(game_dir),
            'profile': {},
            'last_session': None,
        })
    return out


def _prism_cmd() -> list[str]:
    native = shutil.which('prismlauncher')
    if native:
        return [native]
    flatpak = shutil.which('flatpak')
    if flatpak and _prism_data_dirs()[1].is_dir():
        return [flatpak, 'run', PRISM_FLATPAK]
    return []


def _prism_running() -> bool:
    return subprocess.run(['pgrep', '-x', 'prismlauncher'], capture_output=True).returncode == 0


def _prism_feral_on(data_dir: Path, info: dict) -> bool:
    """Whether Prism starts this instance through Feral gamemode, which fires the game mode hooks
    in ~/.config/gamemode.ini. An instance that overrides performance settings has the last word."""
    if info.get('OverridePerformance') == 'true' and 'EnableFeralGamemode' in info:
        return info['EnableFeralGamemode'] == 'true'
    return _ini_general(data_dir / 'prismlauncher.cfg').get('EnableFeralGamemode') == 'true'


def _set_ini_general(path: Path, key: str, value: str) -> None:
    try:
        lines = path.read_text(errors='replace').splitlines()
    except OSError:
        lines = []
    if not any(line.strip() == '[General]' for line in lines):
        lines = ['[General]', *lines]
    start = next(i for i, line in enumerate(lines) if line.strip() == '[General]')
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith('[')), len(lines))
    for i in range(start + 1, end):
        if lines[i].partition('=')[0].strip() == key:
            lines[i] = f'{key}={value}'
            break
    else:
        lines.insert(end, f'{key}={value}')
    tmp = path.with_suffix('.cfg.sea-tmp')
    tmp.write_text('\n'.join(lines) + '\n')
    tmp.replace(path)


def prism_gamemode() -> str:
    """Turn on Prism's "Enable Feral GameMode" for every Prism install. Prism keeps its settings in
    memory and writes them all back, so an edit made while it runs would be lost."""
    targets = [d for d in _prism_data_dirs() if (d / 'prismlauncher.cfg').is_file()]
    if not targets:
        return 'missing'
    if all(_ini_general(d / 'prismlauncher.cfg').get('EnableFeralGamemode') == 'true' for d in targets):
        return 'on'
    if _prism_running():
        return 'running'
    for d in targets:
        _set_ini_general(d / 'prismlauncher.cfg', 'EnableFeralGamemode', 'true')
    return 'on'


def _java_in(game_dir: str) -> bool:
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if os.readlink(proc / 'cwd') == game_dir and b'java' in (proc / 'cmdline').read_bytes().split(b'\0')[0]:
                return True
        except OSError:
            continue
    return False


def prism_watch(game_dir: str) -> None:
    """Game mode for a Prism launch that does not go through Feral gamemode: on once Minecraft's
    Java process is up in the instance folder, auto-off once it is gone. Gives up if it never starts."""
    gm_script = Path.home() / '.config/quickshell/sea-shell/sea-gamemode.sh'
    for _ in range(300):
        if _java_in(game_dir):
            break
        time.sleep(1)
    else:
        return
    subprocess.run(['sh', str(gm_script), 'auto-on'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while _java_in(game_dir):
        time.sleep(3)
    subprocess.run(['sh', str(gm_script), 'auto-off'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _launch_prism(appid: str) -> None:
    prism = _prism_cmd()
    if not prism:
        _notify_launch_error('Prism Launcher was not found.')
        raise SystemExit(1)
    name = appid[len(PRISM_PREFIX):]
    found = next(((d, inst, info) for d, inst, info in _prism_instances() if inst.name == name), None)
    if not found:
        _notify_launch_error(f'Prism Launcher has no instance called {name}.')
        raise SystemExit(1)
    data_dir, inst, info = found
    want = defaults().get('game_mode_on_play') is not False
    _mark_game_mode_skip(not want)
    if want and not _prism_feral_on(data_dir, info):
        prism_gamemode()
        if not _prism_feral_on(data_dir, info):
            game_dir = next((d for d in (inst / 'minecraft', inst / '.minecraft') if d.is_dir()), inst)
            subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), 'prism-watch', str(game_dir)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
    _notify(f'Starting {info.get("name") or name}' + (' (game mode)' if want else ''))
    # The same command as the desktop shortcuts Prism makes for its instances.
    cmd = [*prism, '--launch', name]
    _write_launch_log(appid, cmd)
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _load_data() -> dict:
    if not DATA_FILE.is_file():
        return {'playtime': {}, 'sessions': []}
    try:
        data = json.loads(DATA_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {'playtime': {}, 'sessions': []}
    if not isinstance(data.get('playtime'), dict):
        data['playtime'] = {}
    if not isinstance(data.get('sessions'), list):
        data['sessions'] = []
    return data


def _save_data(data: dict) -> None:
    CFG.mkdir(parents=True, exist_ok=True)
    DATA_FILE.write_text(json.dumps(data, indent=2) + '\n')


def append_session(payload: dict, notify: bool = False) -> dict:
    data = _load_data()
    appid = str(payload.get('appid') or '').strip()
    seconds = int(payload.get('seconds') or 0)
    if seconds < 30:
        return data
    stats = payload.get('stats') if isinstance(payload.get('stats'), dict) else {}
    started_raw = payload.get('started')
    if started_raw:
        try:
            since = datetime.fromisoformat(str(started_raw)).timestamp()
            stats = {**stats, **_fps_stats_since(since)}
        except (TypeError, ValueError):
            pass
    session = {
        'started': started_raw or datetime.now(timezone.utc).astimezone().isoformat(),
        'ended': payload.get('ended') or datetime.now(timezone.utc).astimezone().isoformat(),
        'appid': appid,
        'title': str(payload.get('title') or 'Game session'),
        'seconds': seconds,
        'game_mode': bool(payload.get('game_mode')),
        'stats': stats,
    }
    data['sessions'].insert(0, session)
    data['sessions'] = data['sessions'][:MAX_SESSIONS]
    if appid:
        data['playtime'][appid] = int(data['playtime'].get(appid, 0)) + seconds
    _save_data(data)
    if notify:
        _notify_session(session)
    return session


def add_playtime(appid: str, seconds: int) -> None:
    if not appid or seconds <= 0:
        return
    data = _load_data()
    data['playtime'][appid] = int(data['playtime'].get(appid, 0)) + int(seconds)
    _save_data(data)


def _notify(message: str, title: str = 'Gaming') -> None:
    subprocess.run(
        ['notify-send', '-a', 'sea-shell', title, message],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _notify_launch_error(message: str) -> None:
    _notify(message)


def _steam_bin() -> str:
    path = shutil.which('steam')
    if path:
        return path
    flatpak = shutil.which('flatpak')
    if flatpak and subprocess.run(
        [flatpak, 'info', 'com.valvesoftware.Steam'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return f'{flatpak} run com.valvesoftware.Steam'
    return ''


def _steam_running() -> bool:
    return subprocess.run(['pgrep', '-x', 'steam'], capture_output=True).returncode == 0


def _steam_ui_up() -> bool:
    return subprocess.run(['pgrep', '-f', 'steamwebhelper'], capture_output=True).returncode == 0


def _start_steam_silent(steam: str) -> None:
    subprocess.Popen(
        [*steam.split(), '-silent'],
        env=os.environ.copy(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def steam_warm() -> None:
    """Start Steam in the tray, with no window, if it is not running. Big picture calls this on open."""
    steam = _steam_bin()
    if steam and not _steam_running():
        _start_steam_silent(steam)


def _ensure_steam_client(steam: str) -> None:
    """Steam must be up before steam:// URLs work reliably.

    A URL sent while Steam is still starting is handled by opening its library window, so this
    waits for the client's UI process and a moment after, not only for the steam process.
    """
    if _steam_running() and _steam_ui_up():
        return
    if not _steam_running():
        _start_steam_silent(steam)
    for _ in range(180):
        if _steam_running() and _steam_ui_up():
            time.sleep(3)
            return
        time.sleep(0.25)
    _notify_launch_error('Steam is still starting — try Play again in a few seconds.')


def _write_launch_log(appid: str, cmd: list[str]) -> None:
    CFG.mkdir(parents=True, exist_ok=True)
    (CFG / 'last-launch.json').write_text(
        json.dumps({'appid': appid, 'cmd': cmd, 'at': datetime.now(timezone.utc).astimezone().isoformat()})
        + '\n',
    )


def steam_wrap_script() -> Path:
    return Path.home() / '.config/quickshell/sea-shell/sea-steam-wrap.sh'


_VDF_LAUNCH = r'"LaunchOptions"\s+"((?:[^"\\]|\\.)*)"'


def _vdf_set_launch_options(text: str, appid: str, value: str) -> str:
    """Set LaunchOptions for an appid block; used so Gamescope wraps the game, not Steam."""
    value = value.replace('\\', '\\\\').replace('"', '\\"')
    key = f'"{appid}"'
    idx = 0
    while True:
        i = text.find(key, idx)
        if i < 0:
            return text
        rest = text[i + len(key):].lstrip()
        if not rest.startswith('{'):
            idx = i + 1
            continue
        brace = text.find('{', i)
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    block = text[brace + 1:j]
                    line = f'"LaunchOptions"\t\t"{value}"'
                    if re.search(_VDF_LAUNCH, block):
                        block = re.sub(_VDF_LAUNCH, lambda _: line, block, count=1)
                    else:
                        block = '\n' + line + block
                    return text[:brace + 1] + block + text[j:]
            j += 1
        return text


def _acf_name(appid: str) -> str:
    for root in _steamapps_dirs():
        manifest = root / f'appmanifest_{appid}.acf'
        if not manifest.is_file():
            continue
        try:
            name = _acf_field(manifest.read_text(errors='replace'), 'name')
        except OSError:
            continue
        if name:
            return name
    return f'Steam {appid}'


def _vdf_get_launch_options(text: str, appid: str) -> str:
    key = f'"{appid}"'
    idx = 0
    while True:
        i = text.find(key, idx)
        if i < 0:
            return ''
        rest = text[i + len(key):].lstrip()
        if not rest.startswith('{'):
            idx = i + 1
            continue
        brace = text.find('{', i)
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    block = text[brace + 1:j]
                    m = re.search(_VDF_LAUNCH, block)
                    return m.group(1) if m else ''
            j += 1
        return ''


def _play_session_file() -> Path:
    return Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / 'sea-gaming-play'


def _steam_wrap_value() -> str:
    return f'{steam_wrap_script()} %command%'


def _wrap_pending(appid: str) -> list[tuple[Path, str]]:
    """Each localconfig.vdf still lacking the wrapper for this game, with its new text."""
    pending = []
    for path in (_steam_root() / 'userdata').glob('*/config/localconfig.vdf'):
        try:
            text = path.read_text(errors='replace')
        except OSError:
            continue
        current = _vdf_get_launch_options(text, appid)
        if 'sea-steam-wrap.sh' in current:
            continue
        if current and 'gamemoderun' not in current and 'mangohud' not in current:
            profile_patch(appid, {'steam_launch_options': current.replace('\\"', '"')})
        new = _vdf_set_launch_options(text, appid, _steam_wrap_value())
        if new != text:
            pending.append((path, new))
    return pending


def _game_running() -> bool:
    return subprocess.run(['pgrep', '-f', 'reaper SteamLaunch'], capture_output=True).returncode == 0


def _stop_steam(steam: str) -> bool:
    subprocess.run([*steam.split(), '-shutdown'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        if not _steam_running():
            return True
        time.sleep(0.25)
    return False


def _ensure_wrap_launch_options(appid: str, steam: str) -> bool:
    """Put the wrapper in this game's Launch Options, once. It reads the profile on every launch,
    so the toggles apply from then on without touching Steam again.

    Steam only reads localconfig.vdf at startup and rewrites it when it exits, so an edit made
    while it runs is ignored and then lost. The first Play of a game has to restart Steam.
    """
    if not _wrap_pending(appid):
        return True
    if _steam_running():
        if _game_running():
            _notify_launch_error('Close the game that is running first: Steam has to restart once to apply launch settings.')
            return False
        _notify('Restarting Steam once to apply launch settings for this game')
        if not _stop_steam(steam):
            _notify_launch_error('Steam did not close, so launch settings were not applied. Close it and press Play again.')
            return False
    for path, new in _wrap_pending(appid):
        tmp = path.with_suffix('.vdf.sea-tmp')
        try:
            tmp.write_text(new)
            tmp.replace(path)
        except OSError:
            _notify_launch_error(f'Could not write {path.name}, so launch settings were not applied.')
            return False
    return True


def wrap_exec(appid: str, argv: list[str]) -> None:
    # Only our own separator. Steam's command has -- of its own that its launch chain needs:
    # steam-launch-wrapper -- reaper SteamLaunch AppId=N -- proton waitforexitandrun game.exe
    if argv[:1] == ['--']:
        argv = argv[1:]
    if not argv:
        raise SystemExit('wrap-exec: missing game command')
    if not appid.isdigit() or appid == '0':
        try:
            pending = json.loads((CFG / 'pending-wrap.json').read_text())
            appid = str(pending.get('appid') or appid)
        except (OSError, json.JSONDecodeError):
            pass
    prof = profile_for(appid) if str(appid).isdigit() else dict(DEFAULT_PROFILE)
    env = os.environ.copy()
    native = str((prof.get('steam_launch_options') or ''))
    extra: list[str] = []
    if native and 'sea-steam-wrap.sh' not in native:
        pre, _, post = native.partition('%command%')
        for tok in pre.split():
            if '=' in tok and tok[0].isalpha():
                key, _, val = tok.partition('=')
                env[key] = val.strip('"')
        extra = post.split()
    if prof.get('mangohud'):
        env['MANGOHUD'] = '1'
        env['ENABLE_VKBASALT'] = env.get('ENABLE_VKBASALT', '0')
        log_dir = CFG / 'mangohud-logs'
        log_dir.mkdir(parents=True, exist_ok=True)
        # read_cfg keeps MangoHud.conf; mh_fps / mh_look / mh_corner override it for this launch.
        env['MANGOHUD_CONFIG'] = _mangohud_config(prof)
    for key, val in (prof.get('env') or {}).items():
        env[str(key)] = str(val)
    _mark_game_mode_skip(prof.get('game_mode_on_play') is False)
    cmd = list(argv) + extra
    use_gm = prof.get('gamemode') is not False
    if use_gm and shutil.which('gamemoderun'):
        cmd = ['gamemoderun', *cmd]
    if prof.get('mangohud') and shutil.which('mangohud'):
        cmd = ['mangohud', *cmd]
    cmd = _gamescope_cmd(str(prof.get('gamescope') or ''), cmd, env)
    os.execvpe(cmd[0], cmd, env)


def _gamescope_cmd(scope: str, inner: list[str], env: dict | None = None) -> list[str]:
    scope = (scope or '').strip()
    if not scope or not shutil.which('gamescope'):
        return inner
    parts = scope.split()
    if '--' in parts:
        pre = parts[:parts.index('--')]
    else:
        pre = parts
    # -w takes a value. The old "1080p window" preset left it bare, so it swallowed the --.
    if pre[-1:] == ['-w']:
        pre = [*pre, '1920', '-h', '1080']
    if env is None:
        return ['gamescope', *pre, '--', *inner]
    # Steam's overlay is preloaded for the game; loaded into Gamescope itself it can break it.
    preload = env.pop('LD_PRELOAD', None)
    if preload:
        inner = ['env', f'LD_PRELOAD={preload}', *inner]
    return ['gamescope', *pre, '--', 'sh', '-c', GAMESCOPE_CHILD, 'sea-gamescope-child', str(os.getpid()), *inner]


def _mark_game_mode_skip(skip: bool) -> None:
    """gamemoderun fires Feral's start hook, which would turn game mode on regardless of the
    profile. sea-gamemode.sh auto-on honours this file, and auto-off clears it."""
    marker = Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / 'sea-gamemode-skip'
    try:
        if skip:
            marker.touch()
        else:
            marker.unlink(missing_ok=True)
    except OSError:
        pass


def launch(appid: str, gamemode: bool | None = None) -> None:
    if appid.startswith(TWINTAIL_PREFIX):
        _launch_twintail(appid)
        return
    if appid.startswith(LUTRIS_PREFIX):
        _launch_lutris(appid)
        return
    if appid.startswith(HEROIC_PREFIX):
        _launch_heroic(appid)
        return
    if appid.startswith(PRISM_PREFIX):
        _launch_prism(appid)
        return
    if not appid.isdigit():
        raise SystemExit('appid must be numeric')
    steam = _steam_bin()
    if not steam:
        _notify_launch_error('Steam was not found. Install Steam or fix your PATH.')
        raise SystemExit(1)
    prof = profile_for(appid)
    if gamemode is not None:
        prof = dict(prof)
        prof['gamemode'] = gamemode
    scope = str(prof.get('gamescope') or '').strip()
    if scope and not shutil.which('gamescope'):
        _notify_launch_error('Gamescope is on for this game but is not installed. Turn on “No Gamescope”, then Play.')
        raise SystemExit(1)
    title = _acf_name(appid)
    bits = []
    if prof.get('game_mode_on_play'):
        bits.append('game mode')
    if prof.get('mangohud'):
        bits.append('MangoHud')
    if prof.get('gamemode') is not False:
        bits.append('gamemoderun')
    if scope:
        bits.append('Gamescope')
    extra = f' ({", ".join(bits)})' if bits else ''
    if not _ensure_wrap_launch_options(appid, steam):
        raise SystemExit(1)
    _notify(f'Starting {title}{extra}')
    CFG.mkdir(parents=True, exist_ok=True)
    (CFG / 'pending-wrap.json').write_text(json.dumps({'appid': appid}) + '\n')
    try:
        _play_session_file().write_text(appid + '\n')
    except OSError:
        pass
    gm_script = Path.home() / '.config/quickshell/sea-shell/sea-gamemode.sh'
    if prof.get('game_mode_on_play') and gm_script.is_file():
        # auto-on so quitting the game restores wallpaper/blur/idle (manual `on` does not).
        subprocess.Popen(
            ['sh', str(gm_script), 'auto-on'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    _ensure_steam_client(steam)
    cmd = [*steam.split(), f'steam://rungameid/{appid}']
    _write_launch_log(appid, cmd)
    try:
        subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        _notify_launch_error(f'Launch failed: {exc}')
        raise SystemExit(1) from exc


def summary(days: int = 7) -> dict:
    data = _load_data()
    names = {g['appid']: g['name'] for g in library()}
    cutoff = datetime.now(timezone.utc).astimezone().timestamp() - days * 86400
    week_seconds = 0
    week_sessions = 0
    for s in data['sessions']:
        try:
            ended = datetime.fromisoformat(s.get('ended', '')).timestamp()
        except (TypeError, ValueError):
            continue
        if ended >= cutoff:
            week_seconds += int(s.get('seconds') or 0)
            week_sessions += 1
    top = sorted(data['playtime'].items(), key=lambda kv: kv[1], reverse=True)[:8]
    top_playtime = [{'appid': a, 'name': names.get(a, f'Steam {a}'), 'seconds': sec} for a, sec in top]
    return {
        'week_seconds': week_seconds,
        'week_sessions': week_sessions,
        'total_sessions': len(data['sessions']),
        'top_playtime': top_playtime,
        'sessions': data['sessions'][:40],
        'library_count': len(library()),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)

    sub.add_parser('library', help='JSON list of installed Steam games')

    sub.add_parser('preflight', help='Health checks before playing')

    sub.add_parser('steam-warm', help='Start Steam in the tray, with no window, if it is not running')

    p_play = sub.add_parser('play', help='Launch a Steam game using its profile')
    p_play.add_argument('appid')
    p_play.add_argument('--gamemode', action='store_true', help='Force gamemoderun (legacy)')
    p_play.add_argument('--no-gamemode', action='store_true', help='Skip gamemoderun for this launch')

    p_prof = sub.add_parser('profile', help='Merged launch profile JSON for an appid')
    p_prof.add_argument('appid')

    p_patch = sub.add_parser('profile-patch', help='Merge keys into a game profile')
    p_patch.add_argument('appid')
    p_patch.add_argument('json')

    p_reset = sub.add_parser('profile-reset', help='Remove a game profile, back to the defaults')
    p_reset.add_argument('appid')

    sub.add_parser('defaults', help='Global launch profile defaults JSON')
    p_def = sub.add_parser('defaults-patch', help='Merge keys into global defaults')
    p_def.add_argument('json')

    p_search = sub.add_parser('search', help='Fuzzy library search JSON')
    p_search.add_argument('query', nargs='?', default='')
    p_search.add_argument('--limit', type=int, default=24)

    sub.add_parser('gamescope-presets', help='Named gamescope argument presets')

    p_add = sub.add_parser('append-session', help='Append a finished session (JSON on stdin)')
    p_add.add_argument('--notify', action='store_true')
    p_pt = sub.add_parser('playtime', help='Add seconds to an appid total')
    p_pt.add_argument('appid')
    p_pt.add_argument('seconds', type=int)

    p_sum = sub.add_parser('summary', help='Playtime + recent sessions JSON')
    p_sum.add_argument('--days', type=int, default=7)

    p_wrap = sub.add_parser('wrap-exec', help='Steam LaunchOptions wrapper: profile then exec the game')
    p_wrap.add_argument('appid')
    p_wrap.add_argument('argv', nargs=argparse.REMAINDER)

    p_art = sub.add_parser('cache-art', help='Fetch a launcher image into the local art cache')
    p_art.add_argument('url')
    p_set = sub.add_parser('set-art', help="Use a picture (path or URL) as a game's background; '' resets")
    p_set.add_argument('appid')
    p_set.add_argument('source')
    p_pick = sub.add_parser('pick-art', help="Choose a game's background with a file picker")
    p_pick.add_argument('appid')
    p_find = sub.add_parser('find-art', help='Look up background art online (SteamGridDB, Steam store)')
    p_find.add_argument('appid')
    p_find.add_argument('name')
    p_fav = sub.add_parser('favourite', help='Mark a game as a favourite (on) or not (off)')
    p_fav.add_argument('appid')
    p_fav.add_argument('state', choices=('on', 'off'))
    p_which = sub.add_parser('which-game', help='JSON {appid, title} of the Lutris/Twintail game a process belongs to')
    p_which.add_argument('pid', type=int)
    sub.add_parser('prism-gamemode', help="Turn on Prism Launcher's Feral GameMode setting (Prism must be closed)")
    p_pwatch = sub.add_parser('prism-watch', help='Game mode on while Minecraft runs in this instance folder')
    p_pwatch.add_argument('game_dir')

    args = ap.parse_args()
    if args.cmd == 'library':
        print(json.dumps(library()))
    elif args.cmd == 'preflight':
        print(json.dumps(preflight()))
    elif args.cmd == 'steam-warm':
        steam_warm()
    elif args.cmd == 'play':
        gm = None
        if args.no_gamemode:
            gm = False
        elif args.gamemode:
            gm = True
        launch(args.appid, gm)
    elif args.cmd == 'profile':
        print(json.dumps(profile_for(args.appid)))
    elif args.cmd == 'profile-patch':
        print(json.dumps(profile_patch(args.appid, json.loads(args.json))))
    elif args.cmd == 'profile-reset':
        print(json.dumps(profile_reset(args.appid)))
    elif args.cmd == 'defaults':
        print(json.dumps(defaults()))
    elif args.cmd == 'defaults-patch':
        print(json.dumps(defaults_patch(json.loads(args.json))))
    elif args.cmd == 'search':
        print(json.dumps(search_library(args.query, limit=max(1, args.limit))))
    elif args.cmd == 'gamescope-presets':
        print(json.dumps(GAMESCOPE_PRESETS))
    elif args.cmd == 'append-session':
        raw = os.sys.stdin.read()
        append_session(json.loads(raw) if raw.strip() else {}, notify=args.notify)
    elif args.cmd == 'playtime':
        add_playtime(args.appid, args.seconds)
    elif args.cmd == 'summary':
        print(json.dumps(summary(days=max(1, args.days))))
    elif args.cmd == 'cache-art':
        cache_art(args.url)
    elif args.cmd == 'set-art':
        set_art(args.appid, args.source)
    elif args.cmd == 'pick-art':
        pick_art(args.appid)
    elif args.cmd == 'find-art':
        find_art(args.appid, args.name)
    elif args.cmd == 'favourite':
        print(json.dumps(set_favourite(args.appid, args.state == 'on')))
    elif args.cmd == 'which-game':
        print(json.dumps(which_game(args.pid)))
    elif args.cmd == 'prism-gamemode':
        print(prism_gamemode())
    elif args.cmd == 'prism-watch':
        prism_watch(args.game_dir)
    elif args.cmd == 'wrap-exec':
        wrap_exec(args.appid, args.argv)


if __name__ == '__main__':
    main()
