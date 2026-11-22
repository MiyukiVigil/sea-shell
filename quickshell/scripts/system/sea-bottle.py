#!/usr/bin/env python3
"""Message in a bottle — cast a note into the sea; it washes up later.

Useful as a delayed reminder. Janky as a nautical delivery mechanism.

    cast <text> [--in SECONDS]   throw a bottle (default delay: 20 min … 6 h, random)
    list                         floating + washed bottles (JSON)
    due                          bottles whose wash time has arrived (marks them washed)
    peek                         due bottles without marking
    dismiss <id>                 forget one
    clear-washed                 drop already-washed bottles

State: ~/.config/sea-shell/bottles.json
"""
from __future__ import annotations

import json
import os
import random
import sys
import time
import uuid
from pathlib import Path

CFG = Path(os.environ.get("HOME", str(Path.home()))) / ".config" / "sea-shell"
FILE = CFG / "bottles.json"


def _load() -> list[dict]:
    try:
        raw = json.loads(FILE.read_text(encoding="utf-8"))
        return raw if isinstance(raw, list) else []
    except (OSError, json.JSONDecodeError, TypeError):
        return []


def _save(items: list[dict]) -> None:
    CFG.mkdir(parents=True, exist_ok=True)
    tmp = FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(items, indent=2), encoding="utf-8")
    tmp.replace(FILE)


def _now() -> float:
    return time.time()


def cast(text: str, delay: float | None = None) -> dict:
    text = (text or "").strip()
    if not text:
        raise SystemExit("sea-bottle: nothing to cast")
    if delay is None:
        # 20 minutes … 6 hours — long enough to forget, short enough to be useful today
        delay = float(random.randint(20 * 60, 6 * 3600))
    delay = max(30.0, float(delay))
    now = _now()
    bottle = {
        "id": uuid.uuid4().hex[:10],
        "text": text[:500],
        "castAt": now,
        "washAt": now + delay,
        "washed": False,
        "washedAt": 0,
    }
    items = _load()
    items.insert(0, bottle)
    _save(items[:40])
    return bottle


def due(mark: bool = True) -> list[dict]:
    now = _now()
    items = _load()
    out: list[dict] = []
    changed = False
    for b in items:
        if b.get("washed"):
            continue
        if float(b.get("washAt") or 0) <= now:
            out.append(b)
            if mark:
                b["washed"] = True
                b["washedAt"] = now
                changed = True
    if changed:
        _save(items)
    return out


def floating() -> list[dict]:
    return [b for b in _load() if not b.get("washed")]


def washed_recent(limit: int = 8) -> list[dict]:
    washed = [b for b in _load() if b.get("washed")]
    washed.sort(key=lambda b: float(b.get("washedAt") or 0), reverse=True)
    return washed[:limit]


def dismiss(bid: str) -> bool:
    items = _load()
    nxt = [b for b in items if b.get("id") != bid]
    if len(nxt) == len(items):
        return False
    _save(nxt)
    return True


def clear_washed() -> int:
    items = _load()
    keep = [b for b in items if not b.get("washed")]
    n = len(items) - len(keep)
    _save(keep)
    return n


def _fmt_eta(secs: float) -> str:
    secs = max(0, int(secs))
    if secs < 90:
        return "about a minute"
    if secs < 3600:
        return f"~{max(1, secs // 60)} min"
    h = secs // 3600
    m = (secs % 3600) // 60
    if m == 0:
        return f"~{h} h"
    return f"~{h} h {m} m"


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "cast":
        delay = None
        words: list[str] = []
        i = 1
        while i < len(argv):
            if argv[i] == "--in" and i + 1 < len(argv):
                delay = float(argv[i + 1])
                i += 2
                continue
            words.append(argv[i])
            i += 1
        b = cast(" ".join(words), delay)
        eta = _fmt_eta(float(b["washAt"]) - _now())
        print(json.dumps({"ok": True, "bottle": b, "eta": eta}))
        return 0
    if cmd == "list":
        print(json.dumps({
            "floating": floating(),
            "washed": washed_recent(),
            "now": _now(),
        }))
        return 0
    if cmd == "due":
        print(json.dumps(due(mark=True)))
        return 0
    if cmd == "peek":
        print(json.dumps(due(mark=False)))
        return 0
    if cmd == "dismiss":
        if len(argv) < 2:
            print("sea-bottle: dismiss needs an id", file=sys.stderr)
            return 2
        ok = dismiss(argv[1])
        print(json.dumps({"ok": ok}))
        return 0 if ok else 1
    if cmd == "clear-washed":
        print(json.dumps({"removed": clear_washed()}))
        return 0
    print("sea-bottle: unknown command", file=sys.stderr)
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
