#!/usr/bin/env python3
"""Focus profiles for sea-shell — DND, mute apps, caffeine, night light, open panel.

Config: ~/.config/sea-shell/focus-profiles.json
Active: ~/.config/sea-shell/focus-active  (profile id or empty)

  list                 print profiles JSON
  get                  print { id, profile, profiles }
  apply <id>           write active + emit actions JSON for the shell
  clear                clear active profile
  seed                 write default profiles if missing
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

CFG = Path(os.environ.get("HOME", str(Path.home()))) / ".config" / "sea-shell"
PROFILES = CFG / "focus-profiles.json"
ACTIVE = CFG / "focus-active"
MUTES = CFG / "notif-mutes.json"
MUTES_PREV = CFG / "focus-mutes-prev.json"

DEFAULTS = {
    "coding": {
        "label": "Coding",
        "icon": "code",
        "dnd": True,
        "muteApps": ["discord", "Discord", "slack", "Slack", "steam", "Steam"],
        "caffeine": True,
        "night": False,
        "openDash": "dev",
    },
    "gaming": {
        "label": "Gaming",
        "icon": "sports_esports",
        "dnd": True,
        "muteApps": [],
        "caffeine": True,
        "night": False,
        "openDash": "gaming",
        "gameMode": True,
    },
    "meeting": {
        "label": "Meeting",
        "icon": "videocam",
        "dnd": True,
        "muteApps": ["discord", "Discord", "steam", "Steam"],
        "caffeine": True,
        "night": False,
        "openDash": "",
    },
    "clear": {
        "label": "Clear",
        "icon": "blur_off",
        "dnd": False,
        "muteApps": [],
        "caffeine": False,
        "night": False,
        "openDash": "",
        "clear": True,
    },
}


def _load() -> dict:
    if PROFILES.is_file():
        try:
            data = json.loads(PROFILES.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data:
                return data
        except (OSError, json.JSONDecodeError):
            pass
    return dict(DEFAULTS)


def _save(data: dict) -> None:
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        PROFILES.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def _active() -> str:
    if ACTIVE.is_file():
        try:
            return ACTIVE.read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    return ""


def seed() -> dict:
    if not PROFILES.is_file():
        _save(DEFAULTS)
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        if not ACTIVE.is_file():
            ACTIVE.write_text("", encoding="utf-8")
    except OSError:
        pass
    return _load()


def _read_mutes() -> list:
    if not MUTES.is_file():
        return []
    try:
        data = json.loads(MUTES.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (OSError, json.JSONDecodeError):
        return []


def _write_mutes(apps: list) -> list:
    clean = [a for a in apps if isinstance(a, str) and a]
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        MUTES.write_text(json.dumps(clean) + "\n", encoding="utf-8")
    except OSError:
        pass
    return clean


def _snapshot_mutes() -> None:
    """Remember mutes once when entering a profile, so Clear can restore them."""
    if MUTES_PREV.is_file():
        return
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        MUTES_PREV.write_text(json.dumps(_read_mutes()) + "\n", encoding="utf-8")
    except OSError:
        pass


def _restore_mutes() -> list:
    apps: list = []
    if MUTES_PREV.is_file():
        try:
            data = json.loads(MUTES_PREV.read_text(encoding="utf-8"))
            if isinstance(data, list):
                apps = data
        except (OSError, json.JSONDecodeError):
            apps = []
        try:
            MUTES_PREV.unlink()
        except OSError:
            pass
    return _write_mutes(apps)


def _apply_clear() -> dict:
    ACTIVE.write_text("", encoding="utf-8")
    mutes = _restore_mutes()
    actions = {
        "dnd": False,
        "muteApps": mutes,
        "caffeine": False,
        "night": False,
        "gameMode": False,
        "clear": True,
    }
    return {"id": "", "actions": actions}


def _apply_profile(pid: str, profiles: dict) -> dict:
    prof = profiles.get(pid)
    if not isinstance(prof, dict):
        return {"error": f"unknown profile {pid}"}
    if prof.get("clear"):
        return _apply_clear()
    _snapshot_mutes()
    ACTIVE.write_text(pid, encoding="utf-8")
    mutes = list(prof.get("muteApps") or [])
    if mutes:
        mutes = _write_mutes(mutes)
    else:
        mutes = _read_mutes()
    actions = dict(prof)
    actions["muteApps"] = mutes
    return {"id": pid, "profile": prof, "actions": actions}


def main() -> int:
    args = sys.argv[1:]
    cmd = args[0] if args else "get"
    if cmd == "seed":
        print(json.dumps(seed()))
        return 0
    profiles = seed()
    if cmd == "list":
        print(json.dumps(profiles))
        return 0
    if cmd == "clear":
        print(json.dumps(_apply_clear()))
        return 0
    if cmd == "apply" and len(args) > 1:
        pid = args[1]
        if pid == "clear" or pid == "":
            print(json.dumps(_apply_clear()))
            return 0
        out = _apply_profile(pid, profiles)
        print(json.dumps(out))
        return 1 if "error" in out else 0
    # get
    aid = _active()
    print(json.dumps({"id": aid, "profile": profiles.get(aid), "profiles": profiles}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
