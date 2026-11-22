#!/usr/bin/env python3
"""Plan allowance left for the bar and the desktop widget.

Claude, GPT and Gemini each have their own window. Cursor and Grok share one
included pool, so they are a single meter. The figure is how much of that
allowance is still left, and the caption is when that window resets.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path

# Chromium / Electron safeStorage (OSCrypt) on Linux.
_OSCRYPT_SALT = b'saltysalt'
_OSCRYPT_IV = b' ' * 16
_OSCRYPT_V2_SCHEMA = 'chrome_libsecret_os_crypt_password_v2'
_CURSOR_SAFE_PREFIX = 'cursor-safe-storage:v1:'

INDEX_VERSION = 1
CLAUDE_KEYS = (
    'input_tokens', 'output_tokens',
    'cache_read_input_tokens', 'cache_creation_input_tokens',
)


def _home() -> Path:
    return Path(os.environ.get('HOME', str(Path.home())))


def _cache_index() -> Path:
    base = Path(os.environ.get('XDG_CACHE_HOME', _home() / '.cache'))
    return base / 'sea-shell' / 'ai-usage-index.json'


def local_day(value, now: datetime | None = None) -> str | None:
    """A timestamp from a log, as the machine's own calendar day."""
    if value is None or value == '':
        return None
    dt = None
    if isinstance(value, (int, float)):
        sec = float(value) / 1000.0 if float(value) > 1e12 else float(value)
        try:
            dt = datetime.fromtimestamp(sec).astimezone()
        except (OverflowError, OSError, ValueError):
            return None
    elif isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            return local_day(int(text), now)
        if text.endswith('Z'):
            text = text[:-1] + '+00:00'
        try:
            dt = datetime.fromisoformat(text)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.astimezone()
        else:
            dt = dt.astimezone()
    if dt is None:
        return None
    return dt.date().isoformat()


def format_count(n: int, unit: str) -> str:
    n = int(n or 0)
    if unit == 'tokens':
        if n >= 1_000_000_000:
            return f'{n / 1_000_000_000:.1f}B'
        if n >= 1_000_000:
            return f'{n / 1_000_000:.1f}M'
        if n >= 10_000:
            return f'{n / 1_000:.0f}k'
        if n >= 1_000:
            return f'{n / 1_000:.1f}k'
    return str(n)


def _blank(model: str = '') -> dict:
    return {'tokens': 0, 'events': 0, 'model': model, 'models': {}}


def _add(days: dict, day: str, amount: int, model: str = '') -> None:
    if not day or amount <= 0:
        return
    row = days.setdefault(day, _blank())
    row['tokens'] += int(amount)
    row['events'] += 1
    if model:
        counts = row.setdefault('models', {})
        counts[model] = counts.get(model, 0) + int(amount)


def _load_index(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {'v': INDEX_VERSION, 'files': {}}
    if not isinstance(data, dict) or data.get('v') != INDEX_VERSION:
        return {'v': INDEX_VERSION, 'files': {}}
    files = data.get('files')
    if not isinstance(files, dict):
        files = {}
    return {'v': INDEX_VERSION, 'files': files}


def _save_index(path: Path, index: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(index, separators=(',', ':')))
    tmp.replace(path)


def _scan_jsonl(root: Path, index: dict, kind: str) -> None:
    """Re-read a session log only when its size or mtime changed."""
    files = index.setdefault('files', {})
    if not root.is_dir():
        return
    seen = set()
    for path in root.rglob('*.jsonl'):
        if not path.is_file():
            continue
        key = str(path)
        seen.add(key)
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_size > 64 * 1024 * 1024:
            continue
        prev = files.get(key) or {}
        if prev.get('mtime_ns') == st.st_mtime_ns and prev.get('size') == st.st_size and prev.get('kind') == kind:
            continue
        days: dict = {}
        folder_day = _folder_day(path)
        try:
            with path.open(encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if kind == 'claude':
                        if '"usage"' not in line:
                            continue
                        _consume_claude(line, days)
                    else:
                        if 'token_usage_record' not in line and '"usage"' not in line:
                            continue
                        _consume_codex(line, days, folder_day)
        except OSError:
            continue
        files[key] = {
            'kind': kind,
            'mtime_ns': st.st_mtime_ns,
            'size': st.st_size,
            'days': days,
        }
    # A log that was deleted should not keep counting.
    for key, row in list(files.items()):
        if row.get('kind') == kind and key not in seen and key.startswith(str(root)):
            del files[key]


def _folder_day(path: Path) -> str:
    parts = path.parts
    for i in range(len(parts) - 3):
        year, month, day = parts[i + 1], parts[i + 2], parts[i + 3]
        if (len(year) == 4 and year.isdigit() and len(month) == 2 and month.isdigit()
                and len(day) == 2 and day.isdigit() and parts[i] == 'sessions'):
            return f'{year}-{month}-{day}'
    return ''


def _consume_claude(line: str, days: dict) -> None:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return
    if obj.get('type') != 'assistant':
        return
    message = obj.get('message') if isinstance(obj.get('message'), dict) else {}
    usage = message.get('usage') if isinstance(message.get('usage'), dict) else None
    if not usage:
        return
    amount = 0
    for key in CLAUDE_KEYS:
        value = usage.get(key)
        if isinstance(value, (int, float)):
            amount += int(value)
    model = message.get('model') if isinstance(message.get('model'), str) else ''
    _add(days, local_day(obj.get('timestamp')), amount, model)


def _consume_codex(line: str, days: dict, folder_day: str) -> None:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return
    if obj.get('type') != 'token_usage_record':
        return
    payload = obj.get('payload') if isinstance(obj.get('payload'), dict) else {}
    usage = payload.get('usage') if isinstance(payload.get('usage'), dict) else {}
    total = usage.get('total_tokens')
    if not isinstance(total, (int, float)):
        inn = usage.get('input_tokens') if isinstance(usage.get('input_tokens'), (int, float)) else 0
        out = usage.get('output_tokens') if isinstance(usage.get('output_tokens'), (int, float)) else 0
        total = inn + out
    model = ''
    for key in ('model',):
        if isinstance(payload.get(key), str):
            model = payload[key]
    day = local_day(obj.get('timestamp')) or folder_day
    _add(days, day, int(total), model)


def _sum_index(index: dict, kind: str, days: set[str]) -> dict:
    total = _blank()
    for row in index.get('files', {}).values():
        if row.get('kind') != kind:
            continue
        for day, info in (row.get('days') or {}).items():
            if day not in days or not isinstance(info, dict):
                continue
            total['tokens'] += int(info.get('tokens') or 0)
            total['events'] += int(info.get('events') or 0)
            for model, amount in (info.get('models') or {}).items():
                total['models'][model] = total['models'].get(model, 0) + int(amount)
    if total['models']:
        total['model'] = max(total['models'], key=total['models'].get)
    return total


def _cursor(db: Path, start_ms: int) -> dict:
    """Requests, not tokens. Grok is split out by its model name."""
    out = {
        'cursor': _blank(),
        'grok': _blank(),
    }
    if not db.is_file():
        return out
    try:
        con = sqlite3.connect(f'file:{db}?immutable=1', uri=True)
    except sqlite3.Error:
        return out
    try:
        cur = con.cursor()
        rows = cur.execute(
            'SELECT model, createdAt, requestId FROM ai_code_hashes WHERE createdAt >= ?',
            (start_ms,),
        )
        seen = {'cursor': {}, 'grok': {}}
        for model, created, request in rows:
            name = model if isinstance(model, str) else ''
            bucket = 'grok' if 'grok' in name.lower() else 'cursor'
            day = local_day(created)
            if not day:
                continue
            key = request or f'{created}:{name}'
            bag = seen[bucket].setdefault(day, set())
            if key in bag:
                continue
            bag.add(key)
            row = out[bucket]
            row.setdefault('per_day', {})
            row['per_day'][day] = row['per_day'].get(day, 0) + 1
            counts = row['models']
            counts[name or 'Cursor'] = counts.get(name or 'Cursor', 0) + 1
    except sqlite3.Error:
        return out
    finally:
        con.close()
    for row in out.values():
        per = row.get('per_day') or {}
        row['events'] = sum(per.values())
        row['tokens'] = row['events']
        if row['models']:
            row['model'] = max(row['models'], key=row['models'].get)
    return out


def _window(row: dict, today: str, week: set[str], per_day_key: str = 'per_day') -> tuple[int, int]:
    per = row.get(per_day_key)
    if isinstance(per, dict) and per:
        return int(per.get(today) or 0), sum(int(per.get(day) or 0) for day in week)
    return 0, 0


def _as_dt(value) -> datetime | None:
    if value is None or value == '':
        return None
    if isinstance(value, dict):
        value = value.get('seconds', value.get('second'))
        if value is None:
            return None
    if isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            value = int(text)
        else:
            if text.endswith('Z'):
                text = text[:-1] + '+00:00'
            try:
                dt = datetime.fromisoformat(text)
            except ValueError:
                return None
            return dt.astimezone() if dt.tzinfo else dt.replace(tzinfo=datetime.now().astimezone().tzinfo)
    if isinstance(value, (int, float)):
        sec = float(value)
        if sec > 1e11:
            sec /= 1000.0
        try:
            return datetime.fromtimestamp(sec).astimezone()
        except (OverflowError, OSError, ValueError):
            return None
    return None


def reset_phrase(value, now: datetime | None = None, short: bool = False) -> str:
    dt = _as_dt(value)
    if dt is None:
        return ''
    now = now.astimezone() if now else datetime.now().astimezone()
    clock = dt.strftime('%-I:%M %p').lower()
    if dt.date() == now.date():
        return f'Resets at {clock}'
    if short:
        return f'Resets {dt.strftime("%b")} {dt.day}'
    return f'Resets {dt.strftime("%a, %b")} {dt.day} at {clock}'


def _remaining_from_used(used, fraction: bool = True) -> float:
    """``fraction`` reads 0..1 as a share. Cursor already sends percents, where 0.28 is 0.28%."""
    used = float(used)
    if fraction and 0 <= used <= 1:
        used *= 100.0
    return max(0.0, min(100.0, 100.0 - used))


def _pick(data: dict | None, *names):
    if not isinstance(data, dict):
        return None
    for name in names:
        if name in data and data[name] is not None:
            return data[name]
    return None


def _window_seconds(label: str, explicit: float | None = None) -> float | None:
    if isinstance(explicit, (int, float)) and explicit > 0:
        return float(explicit)
    low = (label or '').lower()
    if ('5hr' in low or '5-hour' in low or 'five hour' in low
            or low.startswith('session')):
        return 5 * 3600
    if 'week' in low or '7 day' in low:
        return 7 * 86400
    if 'month' in low:
        return 30 * 86400
    return None


def _pct(value: float) -> float:
    return round(max(0.0, min(100.0, float(value))), 2)


def format_pct(value: float) -> str:
    """Two decimals, with trailing zeros dropped so an even 38 stays 38%."""
    return f'{_pct(value):.2f}'.rstrip('0').rstrip('.') + '%'


def pace_state(used: float, reset_at, span: float | None, now: datetime | None = None) -> dict | None:
    """Rate so far, and whether that rate fills the window before it resets."""
    now = now.astimezone() if now else datetime.now().astimezone()
    used = max(0.0, min(100.0, float(used)))
    if used <= 0 or used >= 100 or not span or span <= 0:
        return None
    reset = _as_dt(reset_at)
    if reset is None:
        return None
    remaining_s = (reset - now).total_seconds()
    elapsed = span - remaining_s
    if remaining_s <= 0 or elapsed < 30 * 60 or elapsed > span * 1.05:
        return None
    per_day = span >= 36 * 3600
    unit_s = 86400 if per_day else 3600
    rate = used / (elapsed / unit_s)
    if rate <= 0.05:
        return None
    left_s = (100.0 - used) / rate * unit_s
    if rate >= 9.5:
        rate_txt = str(int(round(rate)))
    else:
        rate_txt = f'{rate:.1f}'.rstrip('0').rstrip('.')
    unit = 'a day' if per_day else 'an hour'
    if left_s < 36 * 3600:
        hours = max(1, int(round(left_s / 3600)))
        when = '1 hr' if hours == 1 else f'{hours} hr'
    else:
        days = max(1, int(round(left_s / 86400)))
        when = '1 day' if days == 1 else f'{days} days'
    return {
        'phrase': f'About {rate_txt}% {unit} · full in {when}',
        'fills': left_s <= remaining_s,
        'when': when,
        'left_s': left_s,
    }


def pace_phrase(used: float, reset_at, span: float | None, now: datetime | None = None) -> str:
    state = pace_state(used, reset_at, span, now)
    return state['phrase'] if state else ''


def _meter(label: str, remaining: float, reset_at, now: datetime | None = None,
           span: float | None = None) -> dict:
    left = max(0.0, min(100.0, float(remaining)))
    window = span if span is not None else _window_seconds(label)
    state = pace_state(100.0 - left, reset_at, window, now) or {}
    reset = _as_dt(reset_at)
    return {
        'label': label,
        'used': _pct(100.0 - left),
        'left': _pct(left),
        'reset': reset_phrase(reset_at, now),
        'resetAt': reset.isoformat() if reset else '',
        'span': int(window or 0),
        'pace': state.get('phrase') or '',
        'fills': bool(state.get('fills')),
        'paceWhen': state.get('when') or '',
        'fillsIn': state.get('left_s') or 0,
    }


def quota_row(ident: str, name: str, remaining: float, reset_at, window: str,
              detail: str = '', now: datetime | None = None, windows: list | None = None) -> dict:
    left = _pct(remaining)
    row = {
        'id': ident,
        'name': name,
        'short': name,
        'unit': 'left',
        'model': window or '',
        'today': left,
        'week': 100,
        'todayLabel': format_pct(left),
        'weekLabel': reset_phrase(reset_at, now, short=True),
        'detail': detail,
        'with': '',
        'windows': windows or [],
        'pace': '',
    }
    if windows:
        lead = min(windows, key=lambda item: item.get('left', 100))
        row['pace'] = lead.get('pace') or ''
    row['warn'] = _warn(ident, name, windows)
    row['days'] = []
    return row


_DOW = ('Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su')


WARN_AT = (95, 80)


def _warn(ident: str, name: str, windows: list | None) -> dict | None:
    """The most urgent thing to say about a plan, once per window.

    Past 95% used comes first, then a window on pace to run out before it resets,
    then past 80%. Each has its own key, so each is said once per reset.
    """
    fullest = max(windows or [], key=lambda w: float(w.get('used') or 0), default=None)
    used = float(fullest.get('used') or 0) if fullest else 0.0
    if fullest and used >= WARN_AT[0]:
        return _threshold_warn(ident, name, fullest, WARN_AT[0])
    pace = _pace_warn(ident, name, windows)
    if pace:
        return pace
    if fullest and used >= WARN_AT[1]:
        return _threshold_warn(ident, name, fullest, WARN_AT[1])
    return None


def _threshold_warn(ident: str, name: str, window: dict, level: int) -> dict:
    reset = window.get('reset') or ''
    body = f"{window.get('label')} is {format_pct(window.get('used') or 0)} used."
    if reset:
        body += f' {reset}.'
    return {
        'key': f"{ident}|{window.get('label')}|{window.get('resetAt')}|{level}",
        'title': name,
        'body': body,
    }


def _pace_warn(ident: str, name: str, windows: list | None) -> dict | None:
    """The soonest window that runs out before its own reset."""
    soon = None
    for window in windows or []:
        if not window.get('fills'):
            continue
        if soon is None or window.get('fillsIn', 1e18) < soon.get('fillsIn', 1e18):
            soon = window
    if soon is None:
        return None
    return {
        'key': f"{ident}|{soon.get('label')}|{soon.get('resetAt')}",
        'title': name,
        'body': f"{soon.get('label')} is on track to fill in {soon.get('paceWhen')}, before it resets.",
    }


def week_bars(used: float, reset_at, span: float | None, weights: dict | None,
              now: datetime) -> list:
    """Split a week's used percent across the days it has been open.

    The heights follow local activity on those days, and they add up to the
    plan's used percent. Days before any activity stay empty.
    """
    now = now.astimezone()
    reset = _as_dt(reset_at)
    if reset is None or not span or span < 36 * 3600:
        return []
    start = reset - timedelta(seconds=float(span))
    last = min(now.date(), reset.date())
    if last < start.date():
        return []
    days = []
    cursor = start.date()
    while cursor <= last and len(days) < 8:
        days.append(cursor)
        cursor += timedelta(days=1)
    weights = weights or {}
    total = sum(float(weights.get(day.isoformat(), 0) or 0) for day in days)
    used = max(0.0, min(100.0, float(used)))
    bars = []
    running = 0.0
    for i, day in enumerate(days):
        if total <= 0:
            amount = 0.0
        elif i == len(days) - 1:
            amount = round(max(0.0, used - running), 2)
        else:
            amount = round(used * float(weights.get(day.isoformat(), 0) or 0) / total, 2)
            running += amount
        bars.append({
            'label': _DOW[day.weekday()],
            'day': day.isoformat(),
            'used': amount,
            'today': day == now.date(),
        })
    return bars


def _index_per_day(index: dict, kind: str) -> dict:
    totals: dict[str, int] = {}
    for row in index.get('files', {}).values():
        if row.get('kind') != kind:
            continue
        for day, info in (row.get('days') or {}).items():
            if isinstance(info, dict):
                totals[day] = totals.get(day, 0) + int(info.get('tokens') or 0)
    return totals


def _attach_week(tool: dict, weights: dict, now: datetime) -> None:
    week = None
    for window in tool.get('windows') or []:
        span = float(window.get('span') or 0)
        if span >= 36 * 3600 and (week is None or span > float(week.get('span') or 0)):
            week = window
    if week is None:
        tool['days'] = []
        return
    tool['days'] = week_bars(week.get('used') or 0, week.get('resetAt'), week.get('span'), weights, now)


_CLAUDE_WINDOWS = (
    ('five_hour', 'Session (5hr)'),
    ('seven_day', 'Weekly (7 day)'),
)


def parse_claude_usage(data: dict, now: datetime | None = None) -> dict | None:
    if not isinstance(data, dict):
        return None
    unified = data.get('unifiedWindows') or data.get('unified_windows') or {}
    found = []
    for key, label in _CLAUDE_WINDOWS:
        raw = data.get(key)
        if not isinstance(raw, dict):
            raw = unified.get(key) if isinstance(unified, dict) else None
        if not isinstance(raw, dict) or raw.get('utilization') is None:
            continue
        remaining = _remaining_from_used(raw['utilization'])
        reset = raw.get('resets_at', raw.get('resetsAt'))
        found.append((label, remaining, reset))
    if not found:
        return None
    found.sort(key=lambda item: item[1])
    label, remaining, reset = found[0]
    others = []
    for lab, rem, when in found[1:2]:
        bit = f'{lab} {int(round(rem))}% left'
        phrase = reset_phrase(when, now)
        if phrase:
            bit += ' · ' + phrase
        others.append(bit)
    windows = [_meter(lab, rem, when, now) for lab, rem, when in found]
    # The bars follow the plan page: session, then the week. The pill keeps the tighter one.
    windows.sort(key=lambda item: 0 if item['label'].startswith('Session') else 1)
    return quota_row('claude', 'Claude', remaining, reset, label, ' · '.join(others), now, windows)


def parse_cursor_usage(period: dict, plan: dict | None = None, now: datetime | None = None) -> dict | None:
    usage = _pick(period, 'planUsage', 'plan_usage') or {}
    used = _pick(usage, 'totalPercentUsed', 'total_percent_used', 'autoPercentUsed', 'auto_percent_used')
    if used is None:
        limit = _pick(usage, 'limit')
        spend = _pick(usage, 'includedSpend', 'included_spend', 'totalSpend', 'total_spend')
        if limit and spend is not None and float(limit) > 0:
            used = float(spend) / float(limit) * 100.0
    if used is None:
        return None
    info = _pick(plan, 'planInfo', 'plan_info') or {}
    reset = _pick(info, 'includedUsageResetsAt', 'included_usage_resets_at')
    if reset is None:
        reset = _pick(period, 'billingCycleEnd', 'billing_cycle_end')
    window = 'included'
    period_kind = _pick(info, 'includedUsagePeriod', 'included_usage_period')
    if period_kind in (1, 'INCLUDED_USAGE_PERIOD_MONTHLY', 'MONTHLY', 'monthly'):
        window = 'monthly'
    elif period_kind in (2, 'INCLUDED_USAGE_PERIOD_WEEKLY', 'WEEKLY', 'weekly'):
        window = 'weekly'
    left = _remaining_from_used(used, fraction=False)
    title = 'Weekly' if window == 'weekly' else ('Monthly' if window == 'monthly' else 'Included')
    return quota_row('cursor', 'Cursor', left, reset, window, '', now, [_meter(title, left, reset, now)])


def parse_grok_usage(sand: dict, cursor_left: float | None = None, now: datetime | None = None) -> dict | None:
    """Grok's allowance is its own plan. Skip a copy of Cursor's included meter."""
    if not isinstance(sand, dict):
        return None
    used = _pick(sand, 'usagePercent', 'usage_percent')
    label = _pick(sand, 'grokPlanLabel', 'grok_plan_label') or ''
    plan_name = _pick(sand, 'includedUsageSuperGrokPlan', 'included_usage_super_grok_plan') or ''
    if used is None and not plan_name and not label:
        return None
    if used is None:
        return None
    left = _remaining_from_used(used, fraction=False)
    named = bool(label or plan_name)
    if cursor_left is not None and not named and abs(left - float(cursor_left)) < 0.6:
        return None
    window = label if isinstance(label, str) and 0 < len(label) < 28 else 'Grok plan'
    reset = _pick(sand, 'nextResetTimestampUtc', 'next_reset_timestamp_utc')
    return quota_row('grok', 'Grok', left, reset, window, '', now, [_meter(window, left, reset, now)])


def _window_label(node: dict, hint: str) -> str:
    secs = node.get('limit_window_seconds')
    if isinstance(secs, (int, float)):
        if secs <= 6 * 3600:
            return 'Session (5hr)'
        if secs >= 6 * 86400:
            return 'Weekly'
    if hint == 'primary_window':
        return 'Session (5hr)'
    if 'secondary' in hint or 'week' in hint:
        return 'Weekly'
    return 'plan'


def parse_codex_usage(data: dict, now: datetime | None = None) -> dict | None:
    found = []

    def walk(node, hint: str = '') -> None:
        if isinstance(node, dict):
            if 'remaining_percent' in node or 'used_percent' in node:
                found.append((hint, node))
            for key, value in node.items():
                walk(value, key if isinstance(key, str) else hint)
        elif isinstance(node, list):
            for value in node:
                walk(value, hint)

    if not isinstance(data, dict):
        return None
    walk(data)
    parsed = []
    for hint, node in found:
        if node.get('remaining_percent') is not None:
            rem = float(node['remaining_percent'])
            if 0 <= rem <= 1:
                rem *= 100.0
        elif node.get('used_percent') is not None:
            rem = _remaining_from_used(node['used_percent'])
        else:
            continue
        reset = node.get('reset_at', node.get('resets_at'))
        if reset is None and node.get('reset_after_seconds') is not None:
            reset = datetime.now().astimezone().timestamp() + float(node['reset_after_seconds'])
        span = node.get('limit_window_seconds')
        parsed.append((
            _window_label(node, hint), max(0.0, min(100.0, rem)), reset,
            0 if hint == 'primary_window' else 1,
            float(span) if isinstance(span, (int, float)) and span > 0 else None,
        ))
    if not parsed:
        return None
    parsed.sort(key=lambda item: (item[3], item[1]))
    # The tighter window is the one that runs out first, but a primary session
    # window is the one the plan page leads with when both are present.
    label, remaining, reset, _rank, _span = min(parsed, key=lambda item: item[1])
    detail = ''
    others = [item for item in parsed if item[0] != label or item[2] != reset]
    if others:
        lab, rem, when, _rank, _span = others[0]
        detail = f'{lab} {int(round(rem))}% left'
        phrase = reset_phrase(when, now)
        if phrase:
            detail += ' · ' + phrase
    windows = [_meter(lab, rem, when, now, span) for lab, rem, when, _rank, span in parsed]
    windows.sort(key=lambda item: 0 if item['label'].startswith('Session') else 1)
    return quota_row('codex', 'GPT', remaining, reset, label, detail, now, windows)


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _claude_token() -> str:
    data = _read_json(_home() / '.claude' / '.credentials.json')
    token = (data.get('claudeAiOauth') or {}).get('accessToken') or ''
    return token if isinstance(token, str) else ''


def _codex_auth() -> tuple[str, str]:
    data = _read_json(_home() / '.codex' / 'auth.json')
    tokens = data.get('tokens') or {}
    access = tokens.get('access_token') or ''
    account = tokens.get('account_id') or ''
    if not isinstance(access, str):
        access = ''
    if not isinstance(account, str):
        account = ''
    return access, account


def cursor_profiles() -> list[tuple[str, Path]]:
    """Cursor user-data dirs, each signed in to its own account.

    The main one, then ``~/.cursor-alt/data``, then any extra dirs listed one per
    line in ``~/.config/sea-shell/cursor-profiles``.
    """
    home = _home()
    dirs = [home / '.config' / 'Cursor', home / '.cursor-alt' / 'data']
    try:
        extra = (home / '.config' / 'sea-shell' / 'cursor-profiles').read_text().splitlines()
    except OSError:
        extra = []
    for line in extra:
        line = line.strip()
        if line and not line.startswith('#'):
            dirs.append(Path(os.path.expanduser(line)))
    out = []
    seen = set()
    for path in dirs:
        key = str(path.resolve()) if path.exists() else str(path)
        if key in seen:
            continue
        seen.add(key)
        ident = 'cursor' if not out else ('cursor-alt' if len(out) == 1 else f'cursor-alt{len(out)}')
        out.append((ident, path))
    return out


def _cursor_state(data_dir: Path, key: str) -> str:
    db = data_dir / 'User' / 'globalStorage' / 'state.vscdb'
    if not db.is_file():
        return ''
    uri = 'file:' + str(db) + '?immutable=1'
    try:
        con = sqlite3.connect(uri, uri=True)
    except sqlite3.Error:
        return ''
    try:
        row = con.execute('SELECT value FROM ItemTable WHERE key = ?', (key,)).fetchone()
    except sqlite3.Error:
        return ''
    finally:
        con.close()
    if not row or row[0] is None:
        return ''
    val = row[0]
    if isinstance(val, bytes):
        val = val.decode('utf-8', 'replace')
    return val if isinstance(val, str) else ''


def _secret_tool_lookup(*attrs: str) -> str:
    """Read one libsecret value. Never log the secret."""
    if len(attrs) % 2 != 0 or not attrs:
        return ''
    try:
        proc = subprocess.run(
            ['secret-tool', 'lookup', *attrs],
            capture_output=True, text=True, timeout=4, check=False)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return ''
    if proc.returncode != 0:
        return ''
    return (proc.stdout or '').rstrip('\n')


def _cursor_oscrypt_password() -> str:
    """Electron Safe Storage master password for Cursor on Linux."""
    for application in ('Cursor', 'cursor'):
        pw = _secret_tool_lookup(
            'xdg:schema', _OSCRYPT_V2_SCHEMA, 'application', application)
        if pw:
            return pw
    for account in ('Cursor', 'cursor'):
        pw = _secret_tool_lookup(
            'service', 'Cursor Safe Storage', 'account', account)
        if pw:
            return pw
    return ''


def _oscrypt_aes128_cbc(blob: bytes, password: str, iterations: int) -> str:
    """Decrypt Chromium OSCrypt v10/v11 (AES-128-CBC, fixed IV)."""
    if len(blob) < 4 or not password:
        return ''
    body = blob[3:]
    key = hashlib.pbkdf2_hmac(
        'sha1', password.encode('utf-8'), _OSCRYPT_SALT, iterations, dklen=16)
    try:
        proc = subprocess.run(
            ['openssl', 'enc', '-aes-128-cbc', '-d',
             '-K', key.hex(), '-iv', _OSCRYPT_IV.hex()],
            input=body, capture_output=True, timeout=4, check=False)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return ''
    if proc.returncode != 0 or not proc.stdout:
        return ''
    try:
        return proc.stdout.decode('utf-8')
    except UnicodeDecodeError:
        return ''


def _cursor_decrypt_sealed(val: str) -> str:
    """Unwrap ``cursor-safe-storage:v1:`` (Electron safeStorage) to plaintext."""
    if not val.startswith(_CURSOR_SAFE_PREFIX):
        return ''
    try:
        blob = base64.b64decode(val[len(_CURSOR_SAFE_PREFIX):], validate=False)
    except (ValueError, TypeError):
        return ''
    if len(blob) < 4:
        return ''
    version = blob[:3]
    if version == b'v11':
        pw = _cursor_oscrypt_password()
        return _oscrypt_aes128_cbc(blob, pw, 1) if pw else ''
    if version == b'v10':
        # basic_text backend — obfuscated with the hardcoded peanuts password.
        return _oscrypt_aes128_cbc(blob, 'peanuts', 1)
    return ''


def _cursor_token(data_dir: Path | None = None) -> str:
    if data_dir is None:
        data_dir = _home() / '.config' / 'Cursor'
    val = _cursor_state(data_dir, 'cursorAuth/accessToken')
    if not val:
        return ''
    val = val.strip()
    if val.startswith('{'):
        try:
            parsed = json.loads(val)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            inner = parsed.get('accessToken') or parsed.get('token') or ''
            val = inner if isinstance(inner, str) else ''
            # Some builds store a JSON Buffer of the safeStorage ciphertext.
            if not val and isinstance(parsed.get('data'), list):
                try:
                    raw = bytes(int(b) & 0xFF for b in parsed['data'])
                    if raw[:3] in (b'v10', b'v11'):
                        pw = (_cursor_oscrypt_password() if raw[:3] == b'v11'
                              else 'peanuts')
                        val = _oscrypt_aes128_cbc(raw, pw, 1)
                except (TypeError, ValueError):
                    val = ''
    val = val.strip().strip('"')
    if val.startswith(_CURSOR_SAFE_PREFIX):
        val = _cursor_decrypt_sealed(val).strip()
    return val if val.count('.') >= 2 else ''


def _http_json(url: str, headers: dict, body: bytes | None = None, timeout: float = 8) -> dict:
    req = urllib.request.Request(
        url, data=body, headers=headers, method='POST' if body is not None else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw = res.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        return {}
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


# Bare "antigravity" UA drops Gemini buckets; the CLI identity keeps them.
_ANTIGRAVITY_UA = 'antigravity/cli/1.5.0'


def _oauth_client(service: str) -> tuple[str, str]:
    """Load optional OAuth client_id/client_secret from env or ~/.config/sea-shell/ai-oauth.json."""
    prefix = service.upper()
    cid = (os.environ.get(f'{prefix}_OAUTH_CLIENT_ID') or '').strip()
    sec = (os.environ.get(f'{prefix}_OAUTH_CLIENT_SECRET') or '').strip()
    if cid and sec:
        return cid, sec
    cfg = _read_json(_home() / '.config' / 'sea-shell' / 'ai-oauth.json')
    entry = cfg.get(service) if isinstance(cfg, dict) else None
    if isinstance(entry, dict):
        cid = cid or str(entry.get('client_id') or '').strip()
        sec = sec or str(entry.get('client_secret') or '').strip()
    return cid, sec


def _gemini_creds_path() -> Path:
    return _home() / '.gemini' / 'oauth_creds.json'


def _gemini_token_file() -> Path:
    return _home() / '.config' / 'sea-shell' / 'gemini-token'


def _gemini_load_creds() -> dict:
    data = _read_json(_gemini_creds_path())
    return data if isinstance(data, dict) else {}


def _gemini_save_creds(data: dict) -> None:
    path = _gemini_creds_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix('.json.tmp')
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(path)
    except OSError:
        pass


def _oauth_refresh(refresh: str, client_id: str, client_secret: str) -> dict:
    """Exchange a refresh token. Returns the token response dict or {}."""
    if not isinstance(refresh, str) or not refresh or not client_id or not client_secret:
        return {}
    body = urllib.parse.urlencode({
        'client_id': client_id,
        'client_secret': client_secret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
    }).encode('utf-8')
    req = urllib.request.Request(
        'https://oauth2.googleapis.com/token',
        data=body,
        headers={'Content-Type': 'application/x-www-form-urlencoded'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            raw = res.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        return {}
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) and data.get('access_token') else {}


def _gemini_refresh(creds: dict) -> str:
    """Refresh an expired Gemini CLI access token. Returns the bearer token or ''."""
    refresh = creds.get('refresh_token') or ''
    if not isinstance(refresh, str) or not refresh:
        access = creds.get('access_token') or ''
        return access if isinstance(access, str) else ''
    cid, sec = _oauth_client('gemini')
    data = _oauth_refresh(refresh, cid, sec)
    if not data:
        access = creds.get('access_token') or ''
        return access if isinstance(access, str) else ''
    creds = dict(creds)
    creds['access_token'] = data['access_token']
    if data.get('refresh_token'):
        creds['refresh_token'] = data['refresh_token']
    if data.get('expires_in'):
        creds['expiry_date'] = int(time.time() * 1000) + int(data['expires_in']) * 1000
    _gemini_save_creds(creds)
    return str(creds['access_token'])


def _gemini_cli_token() -> str:
    """Bearer from sea-shell override or Gemini CLI oauth_creds (refreshing if needed)."""
    path = _gemini_token_file()
    if path.is_file():
        try:
            line = path.read_text(encoding='utf-8').strip().splitlines()[0].strip()
            if line:
                return line
        except OSError:
            pass
    env = (os.environ.get('GEMINI_TOKEN') or os.environ.get('GOOGLE_OAUTH_ACCESS_TOKEN') or '').strip()
    if env:
        return env
    creds = _gemini_load_creds()
    access = creds.get('access_token') or ''
    if not isinstance(access, str) or not access:
        return ''
    expiry = creds.get('expiry_date')
    try:
        expiry_ms = float(expiry) if expiry is not None else 0.0
    except (TypeError, ValueError):
        expiry_ms = 0.0
    if expiry_ms and expiry_ms < (time.time() * 1000) + 60_000:
        return _gemini_refresh(creds)
    return access


def _antigravity_keyring_token() -> dict:
    """Antigravity / agy Google OAuth from the OS keyring (service gemini, username antigravity)."""
    raw = _secret_tool_lookup('service', 'gemini', 'username', 'antigravity')
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    nested = data.get('token')
    return nested if isinstance(nested, dict) else data


def _expiry_epoch(value) -> float:
    """Unix seconds for an expiry field (ISO, ms, or seconds). 0 if unknown."""
    if value is None or value == '':
        return 0.0
    if isinstance(value, (int, float)):
        n = float(value)
        return n / 1000.0 if n > 1e12 else n
    if isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            return _expiry_epoch(int(text))
        # Trim sub-microsecond noise some Google blobs emit.
        if re.match(r'^\d{4}-\d{2}-\d{2}T', text):
            if text.endswith('Z'):
                text = text[:-1] + '+00:00'
            if '.' in text:
                head, rest = text.split('.', 1)
                frac = ''
                tz = ''
                for i, ch in enumerate(rest):
                    if ch.isdigit():
                        frac += ch
                    else:
                        tz = rest[i:]
                        break
                text = head + '.' + (frac + '000000')[:6] + tz
            try:
                return datetime.fromisoformat(text).timestamp()
            except ValueError:
                return 0.0
    return 0.0


def _antigravity_access_token() -> str:
    """Fresh Antigravity bearer from the keyring, refreshing a minute early."""
    tok = _antigravity_keyring_token()
    if not tok:
        return ''
    access = tok.get('access_token') or tok.get('accessToken') or ''
    refresh = tok.get('refresh_token') or tok.get('refreshToken') or ''
    expiry = _expiry_epoch(tok.get('expiry') or tok.get('expiry_date') or tok.get('expires_at'))
    need_refresh = bool(refresh) and (not access or not expiry or expiry < time.time() + 60)
    if need_refresh:
        cid, sec = _oauth_client('antigravity')
        data = _oauth_refresh(str(refresh), cid, sec)
        if data.get('access_token'):
            return str(data['access_token'])
    return access if isinstance(access, str) else ''


def _gemini_bucket_tier(model_id: str) -> str:
    name = (model_id or '').lower()
    if 'flash-lite' in name or 'flashlite' in name or 'lite' in name:
        return 'Flash Lite'
    if 'flash' in name:
        return 'Flash'
    if 'pro' in name or 'ultra' in name:
        return 'Pro'
    return 'Gemini'


def _remaining_fraction(raw: dict) -> float | None:
    frac = _pick(raw, 'remainingFraction', 'remaining_fraction')
    if frac is None:
        used = _pick(raw, 'usedFraction', 'used_fraction', 'usageFraction')
        if used is not None:
            try:
                frac = 1.0 - float(used)
            except (TypeError, ValueError):
                frac = None
    if frac is None:
        rem = _pick(raw, 'remainingPercent', 'remaining_percent', 'percentLeft')
        if rem is not None:
            try:
                left = float(rem)
                if 0 <= left <= 1:
                    left *= 100.0
                frac = left / 100.0
            except (TypeError, ValueError):
                frac = None
    if frac is None:
        return None
    try:
        f = float(frac)
    except (TypeError, ValueError):
        return None
    return max(0.0, min(100.0, f * 100.0 if 0.0 <= f <= 1.0 else f))


# Antigravity Models & Usage order: Gemini → Claude/GPT → Argon; weekly then five hour.
_ANTIGRAVITY_WINDOW_ORDER = (
    'Gemini weekly', 'Gemini five hour',
    'Claude/GPT weekly', 'Claude/GPT five hour',
    'Argon weekly',
)


def _antigravity_quota_row(windows: list[dict], now: datetime | None,
                           plan: str = '') -> dict | None:
    """Shared Antigravity meter: id stays gemini for settings/session compat."""
    if not windows:
        return None
    by_label: dict[str, dict] = {}
    for w in windows:
        lab = w['label']
        if lab not in by_label or w['left'] < by_label[lab]['left']:
            by_label[lab] = w
    ordered = [by_label[k] for k in _ANTIGRAVITY_WINDOW_ORDER if k in by_label]
    ordered.extend(w for k, w in by_label.items() if k not in _ANTIGRAVITY_WINDOW_ORDER)
    lead = min(ordered, key=lambda item: item.get('left', 100))
    detail_bits = []
    for w in ordered:
        if w is lead:
            continue
        bit = f"{w['label']} {format_pct(w['left'])} left"
        if w.get('reset'):
            bit += ' · ' + w['reset']
        detail_bits.append(bit)
        break
    name = f'Antigravity · {plan}' if plan else 'Antigravity'
    return quota_row(
        'gemini', name, lead['left'], lead.get('resetAt') or '',
        lead['label'], ' · '.join(detail_bits), now, ordered,
    )


def _antigravity_summary_label(bucket_id: str, group_name: str) -> str | None:
    """Label a summary bucket to match Antigravity Models & Usage."""
    bid = (bucket_id or '').lower()
    group = (group_name or '').lower()
    argon = 'argon' in bid or 'argon' in group
    third = (
        bid.startswith('3p')
        or 'claude' in group
        or ('gpt' in group and 'gemini' not in group)
    )
    weekly = 'weekly' in bid or 'week' in bid
    five = '5h' in bid or '5hr' in bid or 'session' in bid or 'five' in bid
    if argon:
        return 'Argon weekly' if weekly or not five else 'Argon five hour'
    if third:
        if weekly:
            return 'Claude/GPT weekly'
        if five:
            return 'Claude/GPT five hour'
        return 'Claude/GPT five hour'
    if weekly:
        return 'Gemini weekly'
    if five:
        return 'Gemini five hour'
    return None


def parse_gemini_usage(data: dict, now: datetime | None = None) -> dict | None:
    """Map retrieveUserQuota model buckets into Gemini five-hour-style meters."""
    if not isinstance(data, dict):
        return None
    buckets = (
        data.get('buckets')
        or data.get('quotaBuckets')
        or data.get('quotas')
        or data.get('models')
        or []
    )
    if isinstance(buckets, dict):
        buckets = list(buckets.values())
    if not isinstance(buckets, list):
        for key in ('userQuota', 'quota', 'data'):
            nested = data.get(key)
            if isinstance(nested, dict):
                return parse_gemini_usage(nested, now)
        return None
    # Tightest Gemini-family model stands in for the five-hour Gemini window.
    best_left = None
    best_reset = None
    for raw in buckets:
        if not isinstance(raw, dict):
            continue
        model = str(_pick(raw, 'modelId', 'model_id', 'model', 'id') or '').lower()
        if 'claude' in model or model.startswith('3p') or 'argon' in model:
            continue
        left = _remaining_fraction(raw)
        if left is None:
            continue
        reset = _pick(raw, 'resetTime', 'reset_time', 'resetsAt', 'resets_at')
        if best_left is None or left < best_left:
            best_left = left
            best_reset = reset
    if best_left is None:
        return None
    return _antigravity_quota_row(
        [_meter('Gemini five hour', best_left, best_reset, now)], now)


def parse_antigravity_quota_summary(data: dict, now: datetime | None = None) -> dict | None:
    """Map retrieveUserQuotaSummary like Antigravity Models & Usage."""
    if not isinstance(data, dict):
        return None
    groups = data.get('groups') or data.get('quotaGroups') or []
    if not isinstance(groups, list):
        return None
    windows = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        gname = str(group.get('displayName') or group.get('name') or '')
        for raw in group.get('buckets') or []:
            if not isinstance(raw, dict):
                continue
            bid = str(raw.get('bucketId') or raw.get('id') or '')
            label = _antigravity_summary_label(bid, gname)
            if not label:
                continue
            left = _remaining_fraction(raw)
            if left is None:
                continue
            reset = _pick(raw, 'resetTime', 'reset_time', 'resetsAt', 'resets_at')
            windows.append(_meter(label, left, reset, now))
    return _antigravity_quota_row(windows, now)


def parse_antigravity_user_status(data: dict, now: datetime | None = None) -> dict | None:
    """LS fallback: fold models into Gemini / Claude/GPT five-hour meters."""
    if not isinstance(data, dict):
        return None
    user = data.get('userStatus') if isinstance(data.get('userStatus'), dict) else data
    cascade = user.get('cascadeModelConfigData') if isinstance(user, dict) else None
    configs = []
    if isinstance(cascade, dict):
        configs = cascade.get('clientModelConfigs') or []
    if not isinstance(configs, list) or not configs:
        configs = user.get('clientModelConfigs') if isinstance(user, dict) else None
    if not isinstance(configs, list):
        return None
    best: dict[str, tuple[float, object]] = {}
    for raw in configs:
        if not isinstance(raw, dict):
            continue
        label = str(raw.get('label') or '')
        low = label.lower()
        if 'autocomplete' in low or 'embedding' in low:
            continue
        quota = raw.get('quotaInfo') if isinstance(raw.get('quotaInfo'), dict) else raw
        left = _remaining_fraction(quota) if isinstance(quota, dict) else None
        if left is None:
            continue
        if 'argon' in low:
            tier = 'Argon weekly'
        elif any(x in low for x in ('claude', 'gpt', 'sonnet', 'opus', 'oss')):
            tier = 'Claude/GPT five hour'
        else:
            tier = 'Gemini five hour'
        reset = _pick(quota, 'resetTime', 'reset_time', 'resetsAt', 'resets_at') if isinstance(quota, dict) else None
        prev = best.get(tier)
        if prev is None or left < prev[0]:
            best[tier] = (left, reset)
    if not best:
        return None
    windows = [_meter(tier, left, reset, now) for tier, (left, reset) in best.items()]
    plan = ''
    if isinstance(user, dict):
        plan_info = ((user.get('planStatus') or {}).get('planInfo') or {})
        if isinstance(plan_info, dict):
            plan = str(plan_info.get('planName') or '')
    return _antigravity_quota_row(windows, now, plan)


def _cmdline_arg(cmdline: str, flag: str) -> str:
    match = re.search(
        re.escape(flag) + r'''[=\s]+(?:["']([^"']+)["']|([^\s"']+))''',
        cmdline,
    )
    if not match:
        return ''
    return match.group(1) or match.group(2) or ''


def _antigravity_ls_endpoints() -> list[tuple[int, str]]:
    """[(port, csrf)] for a running Antigravity / agy language_server."""
    try:
        proc = subprocess.run(
            ['ps', '-e', '-o', 'pid=,args='],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    found: list[tuple[str, str]] = []
    for line in (proc.stdout or '').splitlines():
        text = line.strip()
        if 'language_server' not in text and 'antigravity' not in text.lower():
            continue
        if '--csrf_token' not in text:
            continue
        match = re.match(r'^(\d+)\s+(.+)$', text)
        if not match:
            continue
        csrf = _cmdline_arg(match.group(2), '--csrf_token')
        if csrf:
            found.append((match.group(1), csrf))
    endpoints: list[tuple[int, str]] = []
    for pid, csrf in found:
        ports: set[int] = set()
        try:
            ss = subprocess.run(
                ['ss', '-lptn'], capture_output=True, text=True, timeout=3,
            )
            for line in (ss.stdout or '').splitlines():
                if f'pid={pid},' not in line and f'pid={pid})' not in line:
                    continue
                for hit in re.finditer(r'127\.0\.0\.1:(\d+)', line):
                    ports.add(int(hit.group(1)))
        except (OSError, subprocess.TimeoutExpired):
            pass
        if not ports:
            try:
                lsof = subprocess.run(
                    ['lsof', '-a', '-P', '-n', f'-p{pid}', '-iTCP', '-sTCP:LISTEN'],
                    capture_output=True, text=True, timeout=3,
                )
                for hit in re.finditer(r'127\.0\.0\.1:(\d+)', lsof.stdout or ''):
                    ports.add(int(hit.group(1)))
            except (OSError, subprocess.TimeoutExpired):
                pass
        for port in sorted(ports):
            endpoints.append((port, csrf))
    return endpoints


def _http_json_local(url: str, headers: dict, body: bytes, timeout: float = 5) -> dict:
    """POST to a local Antigravity language server (self-signed HTTPS ok)."""
    req = urllib.request.Request(url, data=body, headers=headers, method='POST')
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as res:
            raw = res.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        return {}
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _antigravity_ls_plan(now: datetime | None) -> dict | None:
    body = json.dumps({
        'metadata': {
            'ideName': 'antigravity',
            'extensionName': 'antigravity',
            'ideVersion': 'unknown',
            'locale': 'en',
        },
    }).encode('utf-8')
    for port, csrf in _antigravity_ls_endpoints():
        headers = {
            'Content-Type': 'application/json',
            'Connect-Protocol-Version': '1',
            'X-Codeium-Csrf-Token': csrf,
        }
        for scheme in ('https', 'http'):
            data = _http_json_local(
                f'{scheme}://127.0.0.1:{port}/'
                'exa.language_server_pb.LanguageServerService/GetUserStatus',
                headers, body,
            )
            row = parse_antigravity_user_status(data, now)
            if row:
                return row
    return None


def _gemini_cloud_plan(token: str, now: datetime | None, *, antigravity: bool) -> dict | None:
    """Quota via Cloud Code. Antigravity needs its CLI User-Agent for Gemini buckets."""
    headers = {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json',
        'User-Agent': _ANTIGRAVITY_UA if antigravity else 'gemini-cli',
    }
    if antigravity:
        for host in (
            'https://daily-cloudcode-pa.googleapis.com',
            'https://cloudcode-pa.googleapis.com',
        ):
            data = _http_json(host + '/v1internal:retrieveUserQuotaSummary', headers, b'{}')
            row = parse_antigravity_quota_summary(data, now)
            if row:
                return row
        data = _http_json(
            'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota',
            headers, b'{}',
        )
        return parse_gemini_usage(data, now)

    project = ' '
    loaded = _http_json(
        'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
        headers,
        json.dumps({
            'metadata': {'ideType': 'GEMINI_CLI', 'pluginType': 'GEMINI'},
        }).encode('utf-8'),
    )
    if isinstance(loaded, dict):
        project = (
            loaded.get('cloudaicompanionProject')
            or loaded.get('cloudAiCompanionProject')
            or (loaded.get('currentProject') or {}).get('id')
            or project
        )
        if isinstance(project, dict):
            project = project.get('id') or project.get('name') or ' '
        if not isinstance(project, str) or not project.strip():
            project = ' '
    data = _http_json(
        'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota',
        headers,
        json.dumps({'project': project}).encode('utf-8'),
    )
    if not data:
        data = _http_json(
            'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota',
            headers, b'{}',
        )
    return parse_gemini_usage(data, now)


def _gemini_plan(now: datetime | None = None) -> list[dict] | None:
    """Antigravity allowance: quota summary (five hour + weekly) first, then LS / CLI."""
    now = now.astimezone() if now else datetime.now().astimezone()
    # Summary matches Antigravity Models & Usage (Gemini / Claude·GPT / Argon).
    agy = _antigravity_access_token()
    if agy:
        row = _gemini_cloud_plan(agy, now, antigravity=True)
        if row:
            return [row]
    row = _antigravity_ls_plan(now)
    if row:
        return [row]
    cli = _gemini_cli_token()
    if cli:
        row = _gemini_cloud_plan(cli, now, antigravity=False)
        if row:
            return [row]
    return None


def _gemini_auth_available() -> bool:
    if _gemini_token_file().is_file() or _gemini_creds_path().is_file():
        return True
    if (os.environ.get('GEMINI_TOKEN') or os.environ.get('GOOGLE_OAUTH_ACCESS_TOKEN') or '').strip():
        return True
    if _secret_tool_lookup('service', 'gemini', 'username', 'antigravity'):
        return True
    if _antigravity_ls_endpoints():
        return True
    return False


def session_id(comm: str, cmdline: bytes = b'') -> str | None:
    """Which plan a process belongs to.

    The Cursor window is an editor named ``cursor`` and stays up with nobody
    using it. The agent, including one started with no window, is ``cursor-agent``
    or the sandbox helper beside it.
    """
    if comm == 'claude':
        return 'claude'
    if comm == 'codex':
        return 'codex'
    if comm in ('gemini', 'agy'):
        return 'gemini'
    if comm in ('cursor-agent', 'cursorsandbox'):
        return 'cursor'
    if b'cursor-agent' in cmdline or b'cursorsandbox' in cmdline:
        return 'cursor'
    if b'gemini' in cmdline or b'antigravity' in cmdline.lower():
        return 'gemini'
    return None


def live_tools() -> set[str]:
    """Plans with a session open right now, including a headless Cursor agent."""
    found = set()
    proc = Path('/proc')
    try:
        entries = list(proc.iterdir())
    except OSError:
        return found
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            comm = (entry / 'comm').read_text().strip()
        except OSError:
            continue
        ident = session_id(comm)
        if ident is None and comm in ('node', 'cursor-agent'):
            try:
                raw = (entry / 'cmdline').read_bytes()
            except OSError:
                raw = b''
            ident = session_id(comm, raw)
        if ident:
            found.add(ident)
    return found


def mark_running(tools: list[dict], live: set[str] | None = None) -> list[dict]:
    live = live_tools() if live is None else live
    for tool in tools:
        tool['live'] = tool.get('id') in live
        tool['running'] = tool['live']
    return tools


def merge_shared_pool(tools: list[dict]) -> list[dict]:
    """Cursor and Grok draw from one included allowance, so they are one meter."""
    cursor = next((t for t in tools if t.get('id') == 'cursor'), None)
    grok = next((t for t in tools if t.get('id') == 'grok'), None)
    if cursor is None or grok is None:
        return tools
    merged = dict(cursor)
    merged['with'] = 'grok'
    merged['name'] = 'Cursor · Grok'
    merged['short'] = 'Cursor · Grok'
    return [merged if t.get('id') == 'cursor' else t for t in tools if t.get('id') != 'grok']


PLAN_CACHE_MAX_AGE = 3600


def _plan_cache() -> Path:
    base = Path(os.environ.get('XDG_CACHE_HOME', _home() / '.cache'))
    return base / 'sea-shell' / 'ai-plans.json'


def keep_last_good(fresh: dict, cache: dict, now: datetime) -> tuple[dict, dict]:
    """A source whose fetch failed shows its last good rows for up to an hour.

    ``fresh`` maps a source to its rows, or to None when the fetch failed.
    Returns the rows to show per source, and the cache to save.
    """
    shown = {}
    saved = {}
    stamp = now.timestamp()
    for source, rows in fresh.items():
        if rows is not None:
            shown[source] = rows
            saved[source] = {'at': stamp, 'rows': rows}
            continue
        old = cache.get(source) if isinstance(cache.get(source), dict) else None
        if old and isinstance(old.get('rows'), list) and stamp - float(old.get('at') or 0) <= PLAN_CACHE_MAX_AGE:
            shown[source] = [dict(row, stale=True) for row in old['rows']]
            saved[source] = old
        else:
            shown[source] = []
    return shown, saved


def _claude_plan(token: str, now: datetime | None) -> list[dict] | None:
    data = _http_json(
        'https://api.anthropic.com/api/oauth/usage',
        {
            'Authorization': 'Bearer ' + token,
            'anthropic-version': '2023-06-01',
            'anthropic-beta': 'oauth-2025-04-20',
            'Accept': 'application/json',
            'User-Agent': 'claude-code',
        },
    )
    if not data:
        return None
    row = parse_claude_usage(data, now)
    return [row] if row else []


def _codex_plan(access: str, account: str, now: datetime | None) -> list[dict] | None:
    headers = {
        'Authorization': 'Bearer ' + access,
        'Accept': 'application/json',
        'User-Agent': 'codex-cli',
    }
    if account:
        headers['Chatgpt-Account-Id'] = account
    data = _http_json('https://chatgpt.com/backend-api/wham/usage', headers)
    if not data:
        return None
    row = parse_codex_usage(data, now)
    return [row] if row else []


def fetch_plan_tools(now: datetime | None = None) -> list[dict]:
    """Live plan meters. Tokens stay on the machine; only percents come back."""
    now = now.astimezone() if now else datetime.now().astimezone()
    jobs = []
    claude = _claude_token()
    if claude:
        jobs.append(('claude', lambda: _claude_plan(claude, now)))
    access, account = _codex_auth()
    if access:
        jobs.append(('codex', lambda: _codex_plan(access, account, now)))
    # Cursor before Antigravity so a slow/failing Gemini probe cannot starve listing order.
    accounts = set()
    for ident, data_dir in cursor_profiles():
        token = _cursor_token(data_dir)
        if not token:
            continue
        email = _cursor_state(data_dir, 'cursorAuth/cachedEmail').strip().strip('"') or token
        if email in accounts:
            continue
        accounts.add(email)
        jobs.append((ident, lambda token=token, ident=ident: _cursor_account(token, ident, now)))
    if _gemini_auth_available():
        jobs.append(('gemini', lambda: _gemini_plan(now)))
    fresh = {}
    if jobs:
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            futures = [(source, pool.submit(job)) for source, job in jobs]
            for source, future in futures:
                try:
                    fresh[source] = future.result()
                except Exception:
                    # One provider dying (keyring, network) must not blank the others.
                    fresh[source] = None
    cache_path = _plan_cache()
    shown, saved = keep_last_good(fresh, _read_json(cache_path), now)
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache_path.with_suffix('.json.tmp')
        tmp.write_text(json.dumps(saved, separators=(',', ':')))
        tmp.replace(cache_path)
    except OSError:
        pass
    tools = []
    for source, _job in jobs:
        tools.extend(shown.get(source) or [])
    return mark_running(tools)


def _cursor_account(token: str, ident: str, now: datetime | None = None) -> list[dict] | None:
    """One signed-in Cursor account: its included pool, with Grok on it."""
    headers = {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json',
        'Connect-Protocol-Version': '1',
    }
    base = 'https://api2.cursor.sh/aiserver.v1.DashboardService/'
    names = ('GetCurrentPeriodUsage', 'GetPlanInfo', 'GetSandUsageStatus')
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        period, plan, sand = pool.map(lambda name: _http_json(base + name, headers, b'{}'), names)
    if not period or not sand:
        return None
    rows = []
    row = parse_cursor_usage(period, plan, now)
    if row:
        rows.append(row)
    grok = parse_grok_usage(sand, row['today'] if row else None, now)
    if grok:
        rows.append(grok)
    return as_cursor_account(merge_shared_pool(rows), ident)


def as_cursor_account(rows: list[dict], ident: str) -> list[dict]:
    """Give a second account's meters their own id and name."""
    if ident == 'cursor':
        return rows
    number = ident[len('cursor-alt'):]
    suffix = ' alt ' + number if number else ' alt'
    out = []
    for row in rows:
        row = dict(row)
        row['account'] = ident
        row['id'] = ident
        name = row.get('name') or 'Cursor'
        row['name'] = name.replace('Cursor', 'Cursor' + suffix, 1) if 'Cursor' in name else name + suffix
        row['short'] = row['name']
        if row.get('warn'):
            row['warn'] = dict(row['warn'], title=row['name'], key=ident + '|' + row['warn'].get('key', ''))
        out.append(row)
    return out


def _tool(ident: str, name: str, unit: str, today: int, week: int, model: str) -> dict:
    return {
        'id': ident,
        'name': name,
        'short': name,
        'unit': unit,
        'model': model or '',
        'today': int(today),
        'week': int(week),
        'todayLabel': format_count(today, unit),
        'weekLabel': format_count(week, unit),
        'detail': '',
        'with': '',
    }


def collect(claude_root: Path | None = None, codex_root: Path | None = None,
            cursor_db: Path | None = None, index_path: Path | None = None,
            now: datetime | None = None, fetch_plans: bool = False) -> dict:
    now = now.astimezone() if now else datetime.now().astimezone()
    today = now.date().isoformat()
    week_days = {(now.date() - timedelta(days=n)).isoformat() for n in range(7)}
    home = _home()
    claude_root = claude_root if claude_root is not None else home / '.claude' / 'projects'
    codex_root = codex_root if codex_root is not None else home / '.codex' / 'sessions'
    cursor_db = cursor_db if cursor_db is not None else home / '.cursor' / 'ai-tracking' / 'ai-code-tracking.db'
    index_path = index_path if index_path is not None else _cache_index()

    if fetch_plans:
        tools = fetch_plan_tools(now)
        index = _load_index(index_path)
        _scan_jsonl(claude_root, index, 'claude')
        _scan_jsonl(codex_root, index, 'codex')
        _save_index(index_path, index)
        tracked = _cursor(cursor_db, int((now - timedelta(days=40)).timestamp() * 1000))
        weights = {
            'claude': _index_per_day(index, 'claude'),
            'codex': _index_per_day(index, 'codex'),
            'cursor': {},
        }
        for bucket in ('cursor', 'grok'):
            for day, count in (tracked[bucket].get('per_day') or {}).items():
                weights['cursor'][day] = weights['cursor'].get(day, 0) + int(count)
        for tool in tools:
            kind = 'cursor' if tool['id'].startswith('cursor') else tool['id']
            _attach_week(tool, weights.get(kind) or {}, now)
        active = [t for t in tools if t['unit'] == 'left']
        lead = min(active, key=lambda t: t['today']) if active else None
        return {
            'updated': now.isoformat(timespec='seconds'),
            'today': today,
            'usedToday': len(active),
            'lead': {k: lead[k] for k in ('name', 'todayLabel', 'unit', 'model')} if lead else None,
            'tools': tools,
        }

    index = _load_index(index_path)
    _scan_jsonl(claude_root, index, 'claude')
    _scan_jsonl(codex_root, index, 'codex')
    _save_index(index_path, index)

    # The index stores every day a log has. Today and the week are slices of that.
    def slice_kind(kind: str) -> tuple[dict, dict]:
        today_row = _sum_index(index, kind, {today})
        week_row = _sum_index(index, kind, week_days)
        return today_row, week_row

    claude_today, claude_week = slice_kind('claude')
    codex_today, codex_week = slice_kind('codex')

    start = datetime.combine(now.date() - timedelta(days=6), datetime.min.time()).astimezone()
    cursor = _cursor(cursor_db, int(start.timestamp() * 1000))

    tools = []
    if claude_root.is_dir():
        tools.append(_tool('claude', 'Claude', 'tokens', claude_today['tokens'], claude_week['tokens'], claude_week['model']))
    if codex_root.is_dir():
        tools.append(_tool('codex', 'Codex', 'tokens', codex_today['tokens'], codex_week['tokens'], codex_week['model']))
    if cursor_db.is_file():
        cur = cursor['cursor']
        grok = cursor['grok']
        tools.append(_tool('cursor', 'Cursor', 'requests',
                           _window(cur, today, week_days)[0], _window(cur, today, week_days)[1], cur.get('model') or ''))
        if grok.get('models') or _window(grok, today, week_days)[1]:
            tools.append(_tool('grok', 'Grok', 'requests',
                               _window(grok, today, week_days)[0], _window(grok, today, week_days)[1], grok.get('model') or ''))

    active = [t for t in tools if t['today'] > 0]
    lead = None
    token_users = [t for t in active if t['unit'] == 'tokens']
    if token_users:
        lead = max(token_users, key=lambda t: t['today'])
    elif active:
        lead = max(active, key=lambda t: t['today'])
    return {
        'updated': now.isoformat(timespec='seconds'),
        'today': today,
        'usedToday': len(active),
        'lead': {k: lead[k] for k in ('name', 'todayLabel', 'unit', 'model')} if lead else None,
        'tools': tools,
    }


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == '--live':
        print(json.dumps({'running': sorted(live_tools())}))
        return
    print(json.dumps(collect(fetch_plans=True)))


if __name__ == '__main__':
    main()
