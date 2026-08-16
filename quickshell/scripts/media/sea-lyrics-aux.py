#!/usr/bin/env python3
"""Romanise — and optionally translate — a block of lyric lines.

    stdin   {"lines": ["…", …], "translate": false, "to": "en"}
    stdout  {"romaji": ["…", …], "trans": ["…", …]}

Both outputs are LINE-ALIGNED with the input or they are not returned at all. The panel
indexes them with the same `lyrIdx` it already computes from the playback position, so a
result that is off by one line is worse than no result: it would confidently show the
pronunciation of the wrong lyric.

Romanisation is offline (pykakasi · pypinyin · a pure-algorithm Hangul pass), so it costs
one subprocess per track and can never fail mid-song. Translation shells out to
translate-shell, which drives Google's unofficial endpoint — no stability contract, so it
is opt-in, and every failure path here returns empty rather than raising.
"""
import json
import re
import subprocess
import sys

KANA = re.compile(r"[぀-ヿ]")
HAN = re.compile(r"[一-鿿]")
HANGUL = re.compile(r"[가-힯]")


def jp(lines):
    try:
        import pykakasi
    except ImportError:
        return None
    k = pykakasi.kakasi()
    return [" ".join(w["hepburn"] for w in k.convert(l)).strip() for l in lines]


def zh(lines):
    try:
        from pypinyin import Style, pinyin
    except ImportError:
        return None
    return [" ".join(x[0] for x in pinyin(l, style=Style.TONE)) for l in lines]


# Revised Romanisation of Korean. Hangul syllables are algorithmic — onset, nucleus and coda
# fall straight out of the codepoint — so this needs no package at all.
_ONSET = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "",
          "j", "jj", "ch", "k", "t", "p", "h"]
_NUCLEUS = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae",
            "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
_CODA = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "p", "l", "l",
         "l", "l", "m", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]


def ko(lines):
    out = []
    for line in lines:
        buf = []
        for ch in line:
            c = ord(ch)
            if 0xAC00 <= c <= 0xD7A3:
                i = c - 0xAC00
                buf.append(_ONSET[i // 588] + _NUCLEUS[(i % 588) // 28] + _CODA[i % 28])
            else:
                buf.append(ch)
        out.append("".join(buf))
    return out


def romanise(lines):
    """Pick one script for the whole track rather than per line.

    A Japanese song with an English chorus is still a Japanese song, and switching
    romanisers line by line would put pinyin under its kanji-free lines.
    """
    body = "\n".join(lines)
    if KANA.search(body):
        return jp(lines)
    if HANGUL.search(body):
        return ko(lines)
    if HAN.search(body):
        return zh(lines)
    return None                      # already Latin — there is nothing to pronounce


def translate(lines, to):
    # A blank lyric line is a beat of silence, not something to translate; `trans` collapses
    # them and the reply stops lining up. Send placeholders and put the blanks back after.
    marked = [l if l.strip() else "·" for l in lines]
    try:
        done = subprocess.run(["trans", "-b", "-no-warn", "-t", to, "-i", "-"],
                              input="\n".join(marked), capture_output=True,
                              text=True, timeout=25)
    except Exception:
        return None
    if done.returncode != 0:
        return None
    got = done.stdout.rstrip("\n").split("\n")
    if len(got) != len(lines):
        return None                  # re-wrapped: the mapping is gone, so drop all of it
    return ["" if not lines[i].strip() else got[i] for i in range(len(got))]


def find(artist, title):
    """Second-chance lyrics lookup, for tracks lrclib has never heard of.

    lrclib is keyless and fast so it stays the first stop, but its catalogue thins out badly
    outside Western releases — "Ape" by RED in BLUE is absent entirely, and the title-only
    fallback then finds a different band's song of the same name. syncedlyrics queries
    NetEase and Musixmatch, which is exactly where the Japanese and Korean catalogue lives.

    It returns a bare LRC string with no duration, so the caller cannot length-check this the
    way it checks lrclib. The search is artist AND title though, not title alone, which is
    what made the lrclib fallback dangerous in the first place.
    """
    try:
        import syncedlyrics
    except ImportError:
        return ""
    q = ("%s %s" % (title, artist)).strip()
    if not q:
        return ""
    # NetEase only, and deliberately not the all-providers sweep.
    #
    # Musixmatch answers 401 to every request syncedlyrics makes and is retried five times;
    # Megalobiz refuses the connection outright. Between them the sweep burns roughly thirty
    # seconds re-confirming that two endpoints are still broken, and the user sits watching an
    # empty panel for all of it before being told there are no lyrics. NetEase is the only
    # provider in the set that both works and covers the catalogue lrclib misses, so a fast
    # "no lyrics found" is worth more than a slow one that ends the same way.
    #
    # `sys.stderr` is redirected because syncedlyrics narrates every retry, and this runs from
    # a Process whose output is parsed as JSON.
    import contextlib
    import io as _io
    try:
        with contextlib.redirect_stderr(_io.StringIO()):
            got = syncedlyrics.search(q, providers=["NetEase"])
    except Exception:
        return ""
    return got if (got and "[" in got) else ""


def main():
    try:
        req = json.load(sys.stdin)
    except Exception:
        req = {}
    if req.get("find"):
        json.dump({"lrc": find(req.get("artist") or "", req.get("title") or "")}, sys.stdout)
        return
    lines = req.get("lines") or []
    out = {"romaji": [], "trans": []}
    if lines:
        out["romaji"] = romanise(lines) or []
        if req.get("translate"):
            out["trans"] = translate(lines, req.get("to") or "en") or []
    json.dump(out, sys.stdout)


main()
