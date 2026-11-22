#!/usr/bin/env python3
"""sea-services — systemd service health & quick journald log peek for DevHub.

Subcommands:
  list                     JSON {ok, failed: [...], core: [...]}
  restart <unit> <scope>   restart a user systemd service (system services require sudo)
  logs <unit> <scope>      last 25 journalctl lines for <unit>
"""
from __future__ import annotations

import json
import subprocess
import sys

CORE_UNITS = [
    ("pipewire.service", "user", "PipeWire"),
    ("wireplumber.service", "user", "WirePlumber"),
    ("gamemoded.service", "user", "GameMode"),
    ("docker.service", "system", "Docker"),
    ("sea-fand.service", "system", "sea-fand"),
    ("bluetooth.service", "system", "Bluetooth"),
]


def unit_state(unit: str, scope: str) -> str:
    cmd = ["systemctl", "--user", "is-active", unit] if scope == "user" else ["systemctl", "is-active", unit]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        return (r.stdout.strip() or r.stderr.strip() or "unknown").splitlines()[0]
    except Exception:
        return "unknown"


def unit_exists(unit: str, scope: str) -> bool:
    cmd = ["systemctl", "--user", "show", "-p", "LoadState", "--value", unit] if scope == "user" else ["systemctl", "show", "-p", "LoadState", "--value", unit]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        return r.stdout.strip() == "loaded"
    except Exception:
        return False


def failed_user_units() -> list[dict]:
    try:
        r = subprocess.run(
            ["systemctl", "--user", "--failed", "--no-legend", "--plain"],
            capture_output=True, text=True, timeout=2,
        )
        out = []
        for ln in r.stdout.splitlines():
            cols = ln.split()
            if cols:
                out.append({"unit": cols[0], "label": cols[0].replace(".service", ""), "scope": "user", "state": "failed"})
        return out[:6]
    except Exception:
        return []


def cmd_list():
    core = []
    for unit, scope, label in CORE_UNITS:
        if not unit_exists(unit, scope):
            continue
        st = unit_state(unit, scope)
        core.append({"unit": unit, "label": label, "scope": scope, "state": st})
    print(json.dumps({"ok": True, "failed": failed_user_units(), "core": core}))
    return 0


def cmd_restart(unit: str, scope: str):
    if scope != "user":
        return 1
    return subprocess.run(["systemctl", "--user", "restart", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def cmd_logs(unit: str, scope: str):
    cmd = ["journalctl", "--user", "-u", unit, "-n", "25", "--no-pager", "-o", "short"] if scope == "user" else ["journalctl", "-u", unit, "-n", "25", "--no-pager", "-o", "short"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
        print(json.dumps({"ok": True, "unit": unit, "lines": r.stdout.strip() or "(no recent log entries)"}))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "err": str(exc)}))
        return 1


def main():
    args = sys.argv[1:]
    if not args or args[0] == "list":
        return cmd_list()
    if args[0] == "restart" and len(args) >= 3:
        return cmd_restart(args[1], args[2])
    if args[0] == "logs" and len(args) >= 3:
        return cmd_logs(args[1], args[2])
    return 2


if __name__ == "__main__":
    sys.exit(main())
