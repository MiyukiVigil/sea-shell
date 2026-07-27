#!/usr/bin/env python3
"""sea-shell — display (monitor arrangement) profiles.

A "profile" is a saved snapshot of every monitor's mode + position + scale +
transform + enabled-state, so a laptop that docks/undocks can restore a layout
with one click instead of re-dragging monitors in hyprctl every time.

Monitors are identified by their *description* (make/model/serial) first and
their connector name (eDP-1, HDMI-A-1) second — so a profile still applies when
an external display comes back on a different port.

Subcommands (all print JSON to stdout unless noted):
  --current            snapshot the live arrangement (not saved)
  --list               saved profiles + a one-line summary of each
  --save NAME          store the current arrangement under NAME
  --apply NAME         restore NAME via `hyprctl keyword monitor …`
  --delete NAME        remove a saved profile
  --match              name of the saved profile whose monitor set matches the
                       currently-connected monitors (for auto-apply), or ""

Store: ~/.config/sea-shell/display-profiles.json
"""
import sys, os, json, subprocess, datetime

STORE = os.path.expanduser("~/.config/sea-shell/display-profiles.json")


def _hypr(*args):
    """Run hyprctl and return stdout (empty string on failure)."""
    try:
        return subprocess.run(["hyprctl", *args], capture_output=True,
                              text=True, timeout=6).stdout
    except Exception:
        return ""


def _live_monitors():
    """Current monitors as a normalized list of dicts."""
    try:
        raw = json.loads(_hypr("monitors", "all", "-j") or "[]")
    except Exception:
        raw = []
    out = []
    for m in raw:
        out.append({
            "name": m.get("name", ""),
            "description": (m.get("description") or "").strip(),
            "make": m.get("make", ""), "model": m.get("model", ""),
            "serial": m.get("serial", ""),
            "w": int(m.get("width", 0)), "h": int(m.get("height", 0)),
            "rate": round(float(m.get("refreshRate", 0.0)), 3),
            "x": int(m.get("x", 0)), "y": int(m.get("y", 0)),
            "scale": round(float(m.get("scale", 1.0)), 6),
            "transform": int(m.get("transform", 0)),
            "disabled": bool(m.get("disabled", False)),
            "focused": bool(m.get("focused", False)),
        })
    return out


def _load():
    try:
        with open(STORE) as f:
            d = json.load(f)
            if isinstance(d, dict) and isinstance(d.get("profiles"), dict):
                return d
    except Exception:
        pass
    return {"profiles": {}}


def _write(d):
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, STORE)


def _summary(mons):
    """Human one-liner: '2 screens · eDP-1 + HDMI-A-1'."""
    on = [m for m in mons if not m["disabled"]]
    names = " + ".join(m["name"] for m in on) or "none"
    n = len(on)
    return f"{n} screen{'s' if n != 1 else ''} · {names}"


def _key(m):
    """Stable-ish identity for matching a saved monitor to a live one."""
    return (m.get("description") or "").strip() or m.get("name", "")


def cmd_current():
    print(json.dumps({"monitors": _live_monitors()}))


def cmd_list():
    d = _load()
    live = {_key(m) for m in _live_monitors()}
    out = []
    for name, prof in d["profiles"].items():
        mons = prof.get("monitors", [])
        keys = {_key(m) for m in mons if not m.get("disabled")}
        out.append({
            "name": name,
            "summary": _summary(mons),
            "created": prof.get("created", ""),
            # a profile "matches" when every enabled monitor it wants is present
            "matches": bool(keys) and keys.issubset(live),
        })
    out.sort(key=lambda p: p["name"].lower())
    print(json.dumps({"profiles": out}))


def cmd_save(name):
    if not name.strip():
        print(json.dumps({"ok": False, "error": "empty name"})); return
    d = _load()
    d["profiles"][name] = {
        "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "monitors": _live_monitors(),
    }
    _write(d)
    print(json.dumps({"ok": True, "name": name}))


def cmd_delete(name):
    d = _load()
    if name in d["profiles"]:
        del d["profiles"][name]
        _write(d)
        print(json.dumps({"ok": True}))
    else:
        print(json.dumps({"ok": False, "error": "no such profile"}))


def cmd_apply(name):
    d = _load()
    prof = d["profiles"].get(name)
    if not prof:
        print(json.dumps({"ok": False, "error": "no such profile"})); return
    live = _live_monitors()
    # map saved identity -> the connector name it's actually on right now
    by_key = {_key(m): m for m in live}
    by_name = {m["name"]: m for m in live}
    cmds = []
    for m in prof.get("monitors", []):
        live_m = by_key.get(_key(m)) or by_name.get(m["name"])
        connector = live_m["name"] if live_m else m["name"]
        if m.get("disabled"):
            cmds.append(f"{connector},disable")
            continue
        rate = m["rate"] if m["rate"] else 60
        spec = (f"{connector},{m['w']}x{m['h']}@{rate},"
                f"{m['x']}x{m['y']},{m['scale']}")
        if m.get("transform"):
            spec += f",transform,{m['transform']}"
        cmds.append(spec)
    applied = []
    for spec in cmds:
        _hypr("keyword", "monitor", spec)
        applied.append(spec)
    print(json.dumps({"ok": True, "applied": applied}))


def cmd_match():
    d = _load()
    live = {_key(m) for m in _live_monitors()}
    best = ""
    for name, prof in d["profiles"].items():
        keys = {_key(m) for m in prof.get("monitors", []) if not m.get("disabled")}
        if keys and keys == live:          # exact set match wins
            best = name; break
    print(json.dumps({"profile": best}))


def main(argv):
    if not argv:
        cmd_current(); return
    op = argv[0]
    if op == "--current": cmd_current()
    elif op == "--list": cmd_list()
    elif op == "--match": cmd_match()
    elif op == "--save" and len(argv) > 1: cmd_save(argv[1])
    elif op == "--apply" and len(argv) > 1: cmd_apply(argv[1])
    elif op == "--delete" and len(argv) > 1: cmd_delete(argv[1])
    else:
        print(json.dumps({"ok": False, "error": "usage"})); sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
