#!/usr/bin/env python3
"""sea-translate — Screen OCR + instant text translation for sea-shell.

Subcommands:
  text <text> [target_lang]     translate text to target_lang (default: en)
  clip [target_lang]            translate current Wayland clipboard text
  ocr [target_lang]             slurp + grim + tesseract + translate
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

TMP_PNG = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "sea-trans-ocr.png"


def translate_text(text: str, target: str = "en") -> tuple[str, str]:
    text = text.strip()
    if not text:
        return "", ""
    q = urllib.parse.urlencode({
        "client": "gtx",
        "sl": "auto",
        "tl": target,
        "dt": "t",
        "q": text[:3000],
    })
    url = f"https://translate.googleapis.com/translate_a/single?{q}"
    req = urllib.request.Request(url, headers={"User-Agent": "sea-shell/8.0"})
    with urllib.request.urlopen(req, timeout=6) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    parts = [seg[0] for seg in (data[0] or []) if seg and seg[0]]
    detected = data[2] if len(data) > 2 and isinstance(data[2], str) else "auto"
    return "".join(parts), detected


def pick_tess_langs() -> str:
    try:
        out = subprocess.check_output(["tesseract", "--list-langs"], text=True, stderr=subprocess.DEVNULL, timeout=3)
        avail = {ln.strip() for ln in out.splitlines() if ln.strip() and not ln.startswith("List of")}
    except Exception:
        return "eng"
    want = [l for l in ("eng", "jpn", "chi_sim", "kor") if l in avail]
    return "+".join(want) if want else "eng"


def run_ocr() -> str:
    if not (shutil.which("slurp") and shutil.which("grim") and shutil.which("tesseract")):
        raise RuntimeError("Need slurp, grim, and tesseract installed")
    geo = subprocess.run(["slurp"], capture_output=True, text=True)
    if geo.returncode != 0 or not geo.stdout.strip():
        return ""
    g = subprocess.run(["grim", "-g", geo.stdout.strip(), str(TMP_PNG)])
    if g.returncode != 0 or not TMP_PNG.is_file():
        raise RuntimeError("Failed to capture screen region")
    langs = pick_tess_langs()
    res = subprocess.run(["tesseract", str(TMP_PNG), "stdout", "-l", langs], capture_output=True, text=True, timeout=15)
    try:
        TMP_PNG.unlink()
    except Exception:
        pass
    return res.stdout.strip()


def main():
    args = sys.argv[1:]
    if not args:
        print(json.dumps({"ok": False, "err": "usage: sea-translate.py ocr|clip|text ..."}))
        return 2
    cmd = args[0]
    try:
        if cmd == "ocr":
            tl = args[1] if len(args) >= 2 else "en"
            src = run_ocr()
            if not src:
                print(json.dumps({"ok": True, "cancelled": True, "source": "", "translated": "", "lang": ""}))
                return 0
            tr, lang = translate_text(src, tl)
            print(json.dumps({"ok": True, "source": src, "translated": tr, "lang": lang, "target": tl}, ensure_ascii=False))
            return 0
        if cmd == "clip":
            tl = args[1] if len(args) >= 2 else "en"
            src = subprocess.run(["wl-paste", "--no-newline"], capture_output=True, text=True, timeout=3).stdout.strip()
            if not src:
                print(json.dumps({"ok": False, "err": "Clipboard has no text"}))
                return 1
            tr, lang = translate_text(src, tl)
            print(json.dumps({"ok": True, "source": src, "translated": tr, "lang": lang, "target": tl}, ensure_ascii=False))
            return 0
        if cmd == "text" and len(args) >= 2:
            src = args[1]
            tl = args[2] if len(args) >= 3 else "en"
            tr, lang = translate_text(src, tl)
            print(json.dumps({"ok": True, "source": src, "translated": tr, "lang": lang, "target": tl}, ensure_ascii=False))
            return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "err": str(exc)}))
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
