#!/usr/bin/env python3
"""sea-sessions — save & relaunch Hyprland workspace app bundles.

Subcommands:
  list                 JSON {ok, sessions: [...]}
  capture <name>       snapshot currently open mapped windows (workspace + exec) as a session
  launch <id>          launch all apps in session <id> on their saved workspaces
  delete <id>          delete session <id>
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SESSIONS_FILE = Path.home() / ".config" / "sea-shell" / "sessions.json"
DESKTOP_DIRS = [
    Path.home() / ".local" / "share" / "applications",
    Path("/usr/local/share/applications"),
    Path("/usr/share/applications"),
]


def load_sessions() -> list[dict]:
    try:
        data = json.loads(SESSIONS_FILE.read_text())
        if isinstance(data, list):
            return data
    except Exception:
        pass
    return []


def save_sessions(sessions: list[dict]) -> None:
    SESSIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SESSIONS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(sessions, indent=2))
    os.replace(tmp, SESSIONS_FILE)


def desktop_exec_map() -> dict[str, tuple[str, str]]:
    """Map lowercased desktop id / StartupWMClass / name -> (nice_name, clean_exec)."""
    idx = {}
    for d in DESKTOP_DIRS:
        if not d.is_dir():
            continue
        for f in d.glob("*.desktop"):
            try:
                txt = f.read_text(errors="ignore")
            except Exception:
                continue
            name = exec_cmd = wm = ""
            in_main = False
            for ln in txt.splitlines():
                if ln.startswith("["):
                    in_main = ln.strip() == "[Desktop Entry]"
                    continue
                if not in_main:
                    continue
                if ln.startswith("Name=") and not name:
                    name = ln[5:].strip()
                elif ln.startswith("Exec=") and not exec_cmd:
                    exec_cmd = re.sub(r"\s+%[fFuUdDnNickvm]", "", ln[5:].strip()).strip()
                elif ln.startswith("StartupWMClass="):
                    wm = ln[15:].strip()
            if not exec_cmd:
                continue
            label = name or f.stem
            for key in (wm, f.stem, name):
                k = key.strip().lower()
                if k and k not in idx:
                    idx[k] = (label, exec_cmd)
    return idx


def cmd_capture(name: str):
    name = name.strip() or f"Session {time.strftime('%H:%M')}"
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True, timeout=3))
    except Exception as exc:
        print(json.dumps({"ok": False, "err": str(exc)}))
        return 1

    dmap = desktop_exec_map()
    apps = []
    seen = set()
    for c in clients:
        if not c.get("mapped"):
            continue
        ws = int((c.get("workspace") or {}).get("id") or 1)
        if ws <= 0:
            continue
        cls = (c.get("class") or c.get("initialClass") or "").strip()
        if not cls:
            continue
        key = cls.lower()
        label, cmd = dmap.get(key, (cls, ""))
        if not cmd:
            pid = int(c.get("pid") or 0)
            if pid > 0:
                try:
                    raw = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\x00")
                    exe = raw[0].decode("utf-8", errors="ignore")
                    if exe:
                        cmd = exe
                except Exception:
                    pass
        if not cmd:
            continue
        dedup = (ws, key)
        if dedup in seen:
            continue
        seen.add(dedup)
        apps.append({"ws": ws, "cls": cls, "label": label, "exec": cmd})

    if not apps:
        print(json.dumps({"ok": False, "err": "No open windows to save"}))
        return 1

    apps.sort(key=lambda a: (a["ws"], a["label"].lower()))
    sid = hashlib.sha1(f"{name}-{time.time()}".encode()).hexdigest()[:10]
    sessions = [s for s in load_sessions() if s.get("name", "").lower() != name.lower()]
    sessions.insert(0, {"id": sid, "name": name, "saved": int(time.time()), "apps": apps})
    save_sessions(sessions[:20])
    print(json.dumps({"ok": True, "id": sid, "count": len(apps)}))
    return 0


def cmd_launch(sid: str):
    target = None
    for s in load_sessions():
        if s.get("id") == sid:
            target = s
            break
    if not target:
        return 1
    for a in target.get("apps") or []:
        ws = int(a.get("ws") or 1)
        cmd = str(a.get("exec") or "").strip()
        if not cmd:
            continue
        safe = cmd.replace("\\", "\\\\").replace("'", "\\'")
        subprocess.run(
            ["hyprctl", "dispatch", f"hl.dsp.exec_cmd('[workspace {ws} silent] {safe}')"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    subprocess.run(
        ["notify-send", "-a", "sea-shell", f"Launched {target.get('name', 'session')}", f"{len(target.get('apps') or [])} apps across workspaces"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] == "list":
        print(json.dumps({"ok": True, "sessions": load_sessions()}))
        return 0
    if args[0] == "capture":
        return cmd_capture(" ".join(args[1:]))
    if args[0] == "launch" and len(args) >= 2:
        return cmd_launch(args[1])
    if args[0] == "delete" and len(args) >= 2:
        save_sessions([s for s in load_sessions() if s.get("id") != args[1]])
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
