#!/usr/bin/env python3
"""sea-dropzone — temporary file shelf, image converter, and instant LAN QR share.

Subcommands:
  list                     JSON {ok, items: [...], share: {...}|null}
  add <path>...            add file path(s) to the shelf
  add-clip                 save current clipboard image (if any) or file URI to shelf
  remove <path>            remove file from shelf
  clear                    clear shelf list (does not delete original files)
  convert <path> <fmt>     convert image to webp|jpg|png via magick and add result to shelf
  share <path>             serve <path> on local LAN HTTP (auto-expires in 5m) + render QR PNG
  stop-share               stop active LAN share server
"""
from __future__ import annotations

import functools
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

SHELF_FILE = Path.home() / ".config" / "sea-shell" / "dropzone.json"
RUN_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
SHARE_STATE = RUN_DIR / "sea-dropzone-share.json"
QR_PNG = RUN_DIR / "sea-dropzone-qr.png"
IMG_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif"}


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return ""


def load_shelf() -> list[str]:
    try:
        data = json.loads(SHELF_FILE.read_text())
        if isinstance(data, list):
            return [str(x) for x in data if isinstance(x, str) and os.path.isfile(x)]
    except Exception:
        pass
    return []


def save_shelf(paths: list[str]) -> None:
    SHELF_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SHELF_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(paths[:30], indent=2))
    os.replace(tmp, SHELF_FILE)


def active_share():
    if not SHARE_STATE.is_file():
        return None
    try:
        d = json.loads(SHARE_STATE.read_text())
        pid = int(d.get("pid") or 0)
        if pid > 0 and os.path.exists(f"/proc/{pid}"):
            return d
    except Exception:
        pass
    try:
        SHARE_STATE.unlink()
    except Exception:
        pass
    return None


def stop_share():
    cur = active_share()
    if cur and cur.get("pid"):
        try:
            os.kill(int(cur["pid"]), signal.SIGTERM)
        except Exception:
            pass
    for f in (SHARE_STATE, QR_PNG):
        try:
            f.unlink()
        except Exception:
            pass


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def cmd_list():
    items = []
    for p in load_shelf():
        st = os.stat(p)
        ext = Path(p).suffix.lower()
        items.append({
            "path": p,
            "name": os.path.basename(p),
            "size": human_size(st.st_size),
            "is_image": ext in IMG_EXTS,
            "ext": ext.lstrip(".").upper() or "FILE",
        })
    print(json.dumps({"ok": True, "items": items, "share": active_share()}))
    return 0


def cmd_add(paths: list[str]):
    cur = load_shelf()
    for raw in paths:
        p = os.path.abspath(os.path.expanduser(raw))
        if os.path.isfile(p):
            cur = [x for x in cur if x != p]
            cur.insert(0, p)
    save_shelf(cur)
    return 0


def cmd_add_clip():
    # Try file URI list first, then PNG image from clipboard
    try:
        types = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return 1
    if "text/uri-list" in types:
        raw = subprocess.run(["wl-paste", "--type", "text/uri-list"], capture_output=True, text=True, timeout=2).stdout
        added = []
        for ln in raw.splitlines():
            ln = ln.strip()
            if ln.startswith("file://"):
                added.append(urllib.parse.unquote(ln[7:]))
        if added:
            return cmd_add(added)
    if "image/png" in types:
        data = subprocess.run(["wl-paste", "--type", "image/png"], capture_output=True, timeout=3).stdout
        if data:
            dest = RUN_DIR / f"sea-drop-{int(time.time())}.png"
            dest.write_bytes(data)
            return cmd_add([str(dest)])
    return 1


def cmd_convert(path: str, fmt: str):
    fmt = fmt.lower()
    if fmt not in ("webp", "jpg", "png") or not os.path.isfile(path) or not shutil.which("magick"):
        return 1
    src = Path(path)
    out = src.with_suffix(f".{fmt}")
    if out == src:
        out = src.with_name(f"{src.stem}-opt.{fmt}")
    extra = ["-quality", "86"] if fmt in ("webp", "jpg") else []
    r = subprocess.run(["magick", str(src), *extra, str(out)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode == 0 and out.is_file():
        cmd_add([str(out)])
        return 0
    return 1


def _serve_single(path: str, port: int):
    target = Path(path)
    directory = str(target.parent)
    fname = target.name

    class OneFileHandler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            req = urllib.parse.unquote(self.path.lstrip("/"))
            if req in ("", fname):
                self.path = "/" + urllib.parse.quote(fname)
                return super().do_GET()
            self.send_error(404)

        def log_message(self, format, *args):
            pass

    handler = functools.partial(OneFileHandler, directory=directory)
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)

    # Auto-expire after 5 minutes so no stray LAN server stays up indefinitely
    def expire():
        time.sleep(300)
        httpd.shutdown()

    threading.Thread(target=expire, daemon=True).start()
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()


def cmd_share(path: str):
    if not os.path.isfile(path):
        print(json.dumps({"ok": False, "err": "file missing"}))
        return 1
    stop_share()
    # Pick a free TCP port
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("0.0.0.0", 0))
    port = sock.getsockname()[1]
    sock.close()

    ip = lan_ip()
    fname = os.path.basename(path)
    url = f"http://{ip}:{port}/{urllib.parse.quote(fname)}"

    # Spawn detached background server process
    proc = subprocess.Popen(
        [sys.executable, __file__, "--_serve", path, str(port)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    qr_path = ""
    if shutil.which("qrencode"):
        r = subprocess.run(
            ["qrencode", "-s", "8", "-m", "2", "-o", str(QR_PNG), url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if r.returncode == 0 and QR_PNG.is_file():
            qr_path = str(QR_PNG)

    info = {
        "ok": True,
        "pid": proc.pid,
        "path": path,
        "filename": fname,
        "url": url,
        "qr": qr_path,
        "expires_in": 300,
    }
    SHARE_STATE.write_text(json.dumps(info))
    print(json.dumps(info))
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] == "list":
        return cmd_list()
    cmd = args[0]
    if cmd == "--_serve" and len(args) >= 3:
        _serve_single(args[1], int(args[2]))
        return 0
    if cmd == "add" and len(args) >= 2:
        return cmd_add(args[1:])
    if cmd == "add-clip":
        return cmd_add_clip()
    if cmd == "remove" and len(args) >= 2:
        save_shelf([x for x in load_shelf() if x != args[1]])
        return 0
    if cmd == "clear":
        save_shelf([])
        stop_share()
        return 0
    if cmd == "convert" and len(args) >= 3:
        return cmd_convert(args[1], args[2])
    if cmd == "share" and len(args) >= 2:
        return cmd_share(args[1])
    if cmd == "stop-share":
        stop_share()
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
