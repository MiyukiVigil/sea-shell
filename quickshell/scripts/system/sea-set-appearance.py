#!/usr/bin/env python3
"""sea-shell — merge a few keys into appearance.json without touching the rest.

    sea-set-appearance.py mode=dark matugen=true wsStyle=circle barLogo=auto

WHY THIS EXISTS.  settings.qml writes appearance.json by rebuilding the WHOLE file from its
own properties — which is correct there, because it holds every one of them. Any other
surface that wants to change two keys cannot do that: it would have to know all ~90 keys, and
whichever ones it did not know it would silently reset. The welcome screen is exactly that
case, and it sets things the user has often already configured.

So: read, merge, write atomically. Unknown keys are preserved untouched, and a malformed or
missing file is replaced rather than being a hard failure — a first run has nothing to lose.

Values are coerced by shape: true/false to bool, a bare number to int or float, anything else
to string. `key=` sets an empty string, which is how a path is cleared.
"""
from __future__ import annotations

import json
import os
import sys

CFG_DIR = os.path.join(os.path.expanduser("~"), ".config", "sea-shell")
CFG = os.path.join(CFG_DIR, "appearance.json")


def coerce(v):
    low = v.strip().lower()
    if low == "true":
        return True
    if low == "false":
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v


def main():
    pairs = [a for a in sys.argv[1:] if "=" in a]
    if not pairs:
        return 0

    try:
        with open(CFG, encoding="utf-8") as fh:
            j = json.load(fh)
        if not isinstance(j, dict):
            j = {}
    except Exception:
        j = {}

    for p in pairs:
        k, _, v = p.partition("=")
        k = k.strip()
        if k:
            j[k] = coerce(v)

    os.makedirs(CFG_DIR, exist_ok=True)
    tmp = CFG + ".tmp"
    # Written to a temp file and renamed, because the bar WATCHES this file: a reader that
    # catches a half-written JSON gets a parse error and keeps its previous values, which is
    # a setting that silently did not apply.
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(j, fh)
    os.replace(tmp, CFG)
    return 0


if __name__ == "__main__":
    sys.exit(main())
