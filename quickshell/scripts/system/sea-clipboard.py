#!/usr/bin/env python3
"""sea-clipboard — visual clipboard history (with image thumbnails) + persistent pins.

Subcommands:
  list [--limit N]        JSON {ok, items: [...], pins: [...]}
  copy <id>               copy cliphist entry <id> to Wayland clipboard via wl-copy
  delete <id>             delete cliphist entry <id>
  clear                   clear cliphist history (keeps pinned snippets intact)
  pin-entry <id>          decode cliphist text entry <id> and save it to pins
  pin-add <text>          add a custom text snippet to pins
  pin-remove <pin_id>     remove a pinned snippet
  pin-copy <pin_id>       copy a pinned snippet to clipboard
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

PINS_FILE = Path.home() / ".config" / "sea-shell" / "clipboard-pins.json"
THUMB_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "sea-clip-thumbs"
IMG_RE = re.compile(r"^\[\[\s*binary data\s+([^\]]+?)\s+(png|jpg|jpeg|webp|bmp|gif)\s+(\d+x\d+)\s*\]\]$", re.I)


def load_pins() -> list[dict]:
    try:
        data = json.loads(PINS_FILE.read_text())
        if isinstance(data, list):
            return [p for p in data if isinstance(p, dict) and p.get("text")]
    except Exception:
        pass
    return []


def save_pins(pins: list[dict]) -> None:
    PINS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = PINS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(pins, indent=2, ensure_ascii=False))
    os.replace(tmp, PINS_FILE)


def ensure_thumb(entry_id: str, ext: str) -> str:
    THUMB_DIR.mkdir(parents=True, exist_ok=True)
    ext = ext.lower()
    if ext == "jpeg":
        ext = "jpg"
    out = THUMB_DIR / f"{entry_id}.{ext}"
    if out.is_file() and out.stat().st_size > 0:
        return str(out)
    try:
        dec = subprocess.run(["cliphist", "decode", entry_id], capture_output=True, timeout=3)
        if dec.returncode == 0 and dec.stdout:
            out.write_bytes(dec.stdout)
            return str(out)
    except Exception:
        pass
    return ""


def prune_thumbs(live_ids: set[str]) -> None:
    if not THUMB_DIR.is_dir():
        return
    for p in THUMB_DIR.iterdir():
        if p.stem not in live_ids:
            try:
                p.unlink()
            except Exception:
                pass


def cmd_list(limit: int = 80):
    items = []
    live_ids = set()
    if shutil.which("cliphist"):
        try:
            res = subprocess.run(["cliphist", "list"], capture_output=True, text=True, timeout=4)
            lines = [ln for ln in res.stdout.splitlines() if ln.strip()][:limit]
            for ln in lines:
                parts = ln.split("\t", 1)
                if len(parts) != 2:
                    continue
                eid, preview = parts[0].strip(), parts[1].strip()
                live_ids.add(eid)
                m = IMG_RE.match(preview)
                if m:
                    size_s, ext, dims = m.group(1), m.group(2).lower(), m.group(3)
                    thumb = ensure_thumb(eid, ext)
                    items.append({
                        "id": eid,
                        "kind": "image",
                        "preview": f"Image · {dims} · {size_s}",
                        "dims": dims,
                        "size": size_s,
                        "ext": ext.upper(),
                        "thumb": thumb,
                    })
                else:
                    is_url = bool(re.match(r"^https?://\S+$", preview))
                    is_color = bool(re.match(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", preview))
                    items.append({
                        "id": eid,
                        "kind": "color" if is_color else ("url" if is_url else "text"),
                        "preview": preview,
                        "thumb": "",
                    })
            prune_thumbs(live_ids)
        except Exception as exc:
            print(json.dumps({"ok": False, "err": str(exc), "items": [], "pins": load_pins()}))
            return 1
    print(json.dumps({"ok": True, "items": items, "pins": load_pins()}, ensure_ascii=False))
    return 0


def cmd_copy(eid: str):
    dec = subprocess.run(["cliphist", "decode", eid], capture_output=True, timeout=4)
    if dec.returncode != 0:
        return 1
    p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p.communicate(dec.stdout, timeout=4)
    return 0


def cmd_delete(eid: str):
    subprocess.run(["cliphist", "delete"], input=f"{eid}\t\n".encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
    # cliphist delete matches full line; also try deleting exact line from cliphist list
    try:
        res = subprocess.run(["cliphist", "list"], capture_output=True, text=True, timeout=4)
        for ln in res.stdout.splitlines():
            if ln.startswith(eid + "\t"):
                subprocess.run(["cliphist", "delete"], input=(ln + "\n").encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
                break
    except Exception:
        pass
    for p in THUMB_DIR.glob(f"{eid}.*"):
        try:
            p.unlink()
        except Exception:
            pass
    return 0


def cmd_clear():
    subprocess.run(["cliphist", "wipe"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
    if THUMB_DIR.is_dir():
        for p in THUMB_DIR.iterdir():
            try:
                p.unlink()
            except Exception:
                pass
    return 0


def add_pin_text(text: str):
    text = text.strip()
    if not text:
        return 1
    pins = load_pins()
    pid = hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()[:12]
    pins = [p for p in pins if p.get("id") != pid]
    pins.insert(0, {"id": pid, "text": text, "added": int(time.time())})
    save_pins(pins[:60])
    return 0


def cmd_pin_entry(eid: str):
    dec = subprocess.run(["cliphist", "decode", eid], capture_output=True, timeout=4)
    if dec.returncode != 0 or not dec.stdout:
        return 1
    try:
        txt = dec.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return 1
    return add_pin_text(txt)


def cmd_pin_remove(pid: str):
    pins = [p for p in load_pins() if p.get("id") != pid]
    save_pins(pins)
    return 0


def cmd_pin_copy(pid: str):
    for p in load_pins():
        if p.get("id") == pid:
            proc = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proc.communicate(p["text"].encode("utf-8"), timeout=4)
            return 0
    return 1


def main():
    args = sys.argv[1:]
    if not args or args[0] == "list":
        limit = 80
        if "--limit" in args:
            try:
                limit = int(args[args.index("--limit") + 1])
            except Exception:
                pass
        return cmd_list(limit)
    cmd = args[0]
    if cmd == "copy" and len(args) >= 2:
        return cmd_copy(args[1])
    if cmd == "delete" and len(args) >= 2:
        return cmd_delete(args[1])
    if cmd == "clear":
        return cmd_clear()
    if cmd == "pin-entry" and len(args) >= 2:
        return cmd_pin_entry(args[1])
    if cmd == "pin-add" and len(args) >= 2:
        return add_pin_text(args[1])
    if cmd == "pin-remove" and len(args) >= 2:
        return cmd_pin_remove(args[1])
    if cmd == "pin-copy" and len(args) >= 2:
        return cmd_pin_copy(args[1])
    return 2


if __name__ == "__main__":
    sys.exit(main())
