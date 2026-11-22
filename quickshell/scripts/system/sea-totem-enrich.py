#!/usr/bin/env python3
"""Enrich `totem list --json` with brand badge data for the sea-shell bar widget.

Reads stdin (JSON array of accounts), writes the same array with a `logo` object:
  { "file": "/path/to.svg"|null, "hex": "5865F2", "letter": "D", "light": false }

Looks up Simple Icons from Totem's brand-icons.json (CC0/MIT subset). Titles that the
phone tagged with the wrong slug (e.g. LinkedIn → gmail) are resolved by account name.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

BRAND_COLORS = {
    "microsoft": "0078D4",
    "outlook": "0078D4",
    "xbox": "107C10",
    "azure": "0078D4",
    "linkedin": "0A66C2",
    "amazon": "FF9900",
    "aws": "232F3E",
    "amazonwebservices": "232F3E",
    "openai": "10A37F",
    "chatgpt": "10A37F",
    "adobe": "FF0000",
    "slack": "4A154B",
    "yahoo": "6001D2",
    "heroku": "430098",
    "nintendo": "E60012",
    "minecraft": "62B47A",
    "kraken": "5741D9",
    "tuta": "850122",
    "tutanota": "850122",
    "fastmail": "0067B9",
    "hytale": "1A73E8",
    "threadwell": "5B8DEF",
}
PALETTE = ["B5652B", "2B7BB5", "2E9E6B", "8E44AD", "C0392B", "D35400", "16A085", "7F8C8D", "2C3E50", "B03A75"]

# Title → preferred Simple Icons slug (when the phone's icon is wrong or missing).
TITLE_SLUG = {
    "discord": "discord",
    "github": "github",
    "google": "google",
    "cloudflare": "cloudflare",
    "twitter": "x",
    "x": "x",
    "linkedin": None,  # not in the CC0 pack — letter badge
    "hytale": None,
    "threadwell": None,
}


def normalize(s: str) -> str:
    s = s.lower().replace("&", "and").replace("+", "plus")
    return re.sub(r"[^\w]", "", s, flags=re.UNICODE)


def java_hash(s: str) -> int:
    # Same 32-bit string hash the desktop popup uses for letter colours.
    h = 0
    for ch in s:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
        if h >= 0x80000000:
            h -= 0x100000000
    return h


def letter_color(name: str) -> str:
    n = normalize(name)
    for brand, hex_ in BRAND_COLORS.items():
        if n == brand or n.startswith(brand):
            return hex_
    return PALETTE[((java_hash(n) % len(PALETTE)) + len(PALETTE)) % len(PALETTE)]


def is_light(hex_: str) -> bool:
    def chan(i: int) -> float:
        c = int(hex_[i : i + 2], 16) / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = chan(0), chan(2), chan(4)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6


def first_letter(title: str) -> str:
    for ch in title:
        if ch.isalnum():
            return ch.upper()
    return "?"


def find_brand_icons() -> Path | None:
    home = Path.home()
    candidates = [
        home / "Documents/Personal/MultiPlatformAuthenticator/desktop/ui/brand-icons.json",
        home / ".local/share/totem/brand-icons.json",
        Path(os.environ.get("TOTEM_BRAND_ICONS", "")) if os.environ.get("TOTEM_BRAND_ICONS") else None,
    ]
    for p in candidates:
        if p and p.is_file():
            return p
    return None


def load_brands(path: Path) -> tuple[dict[str, dict], dict[str, str]]:
    data = json.loads(path.read_text())
    by_slug = {i["s"]: i for i in data["icons"]}
    by_title: dict[str, str] = {}
    for i in data["icons"]:
        by_title[normalize(i["t"])] = i["s"]
        for a in i.get("a") or []:
            by_title[normalize(a)] = i["s"]
    return by_slug, by_title


def resolve(account: dict, by_slug: dict[str, dict], by_title: dict[str, str]) -> tuple[dict | None, str, str]:
    title = account.get("title") or account.get("issuer") or "Account"
    n = normalize(title)
    slug = None

    # Prefer a known title mapping (fixes LinkedIn/Hytale tagged as gmail).
    for key, mapped in TITLE_SLUG.items():
        if n == key or n.startswith(key):
            slug = mapped
            break

    if slug is None and n not in TITLE_SLUG:
        # Direct title / alias hit in Simple Icons
        slug = by_title.get(n)
        if not slug:
            for t, s in by_title.items():
                if n.startswith(t) or t.startswith(n):
                    if len(t) >= 4:
                        slug = s
                        break

    if slug is None:
        phone_icon = (account.get("icon") or "").strip()
        if phone_icon in by_slug:
            # Don't trust gmail when the title clearly isn't Google.
            if phone_icon == "gmail" and "google" not in n and "gmail" not in n:
                pass
            else:
                slug = phone_icon

    brand = by_slug.get(slug) if slug else None
    hex_ = brand["h"] if brand else letter_color(title)
    letter = first_letter(title)
    return brand, hex_, letter


def write_svg(cache: Path, slug: str, hex_: str, path_d: str) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    # White glyph on brand-coloured square (desktop style).
    fill = "#000000" if is_light(hex_) else "#ffffff"
    # Path is 24×24; scale to ~16px inside a 24px badge (same ratio as the desktop popup).
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        f'<rect width="24" height="24" rx="6" fill="#{hex_}"/>'
        f'<g transform="translate(4 4) scale(0.6666667)">'
        f'<path fill="{fill}" d="{path_d}"/></g></svg>\n'
    )
    out = cache / f"{slug}.svg"
    if not out.exists() or out.read_text() != svg:
        out.write_text(svg)
    return out


def main() -> None:
    raw = sys.stdin.read()
    try:
        accounts = json.loads(raw)
    except json.JSONDecodeError:
        sys.stdout.write(raw)
        return

    if not isinstance(accounts, list):
        sys.stdout.write(raw)
        return

    brands_path = find_brand_icons()
    by_slug, by_title = load_brands(brands_path) if brands_path else ({}, {})
    cache = Path.home() / ".cache" / "sea-shell" / "totem-brands"

    out = []
    for a in accounts:
        brand, hex_, letter = resolve(a, by_slug, by_title)
        file_path = None
        if brand:
            file_path = str(write_svg(cache, brand["s"], hex_, brand["p"]))
        a = dict(a)
        a["logo"] = {
            "file": file_path,
            "hex": hex_,
            "letter": letter,
            "light": is_light(hex_),
        }
        out.append(a)

    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
