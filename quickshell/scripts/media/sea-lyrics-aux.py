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


def main():
    try:
        req = json.load(sys.stdin)
    except Exception:
        req = {}
    lines = req.get("lines") or []
    out = {"romaji": [], "trans": []}
    if lines:
        out["romaji"] = romanise(lines) or []
        if req.get("translate"):
            out["trans"] = translate(lines, req.get("to") or "en") or []
    json.dump(out, sys.stdout)


main()
