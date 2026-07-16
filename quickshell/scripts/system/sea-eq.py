#!/usr/bin/env python3
"""
sea-shell — software equaliser (PipeWire filter-chain)

Parametric EQ for ANY output: laptop speakers, another brand's DAC, bluetooth.
No Moondrop hardware, and no Moondrop code — this script is deliberately
standalone. moondrop_control.py talks to a DAC's own DSP chip over USB HID and
knows nothing about PipeWire; this one is the reverse. The DAC panel drives both
and is the only place they meet.

    sea-eq.py --status                 installed? running? which bands?
    sea-eq.py --apply --from-json FILE render those bands and load them
    sea-eq.py --apply --from-rew FILE  ...from an AutoEQ/REW ParametricEQ.txt
    sea-eq.py --remove                 stop it and delete the config
    sea-eq.py --render OUT.conf --from-json FILE    just write the file

--from-json takes either shape:
    {"pregain": -5.0, "filters": [...]}   moondrop_control.py --export-json
    {"bands": [...]}                      moondrop_control.py --preset
Bands are {index, type, frequency, gain, q} with type one of:
    disabled peaking low_shelf high_shelf low_pass high_pass
When the source carries no pre-gain (a community preset never does), it is
computed from the curve's own peak — software biquads have no fixed-point limit,
but the sink still clips at full scale.

WHY filter-chain.service AND NOT pipewire.conf.d
------------------------------------------------
Both load the graph. But pipewire.conf.d only takes effect when the MAIN daemon
restarts, which drops every stream on the machine. filter-chain.service is a
separate pipewire instance that BindsTo the main one, so the sink appears and
disappears with nothing else interrupted — which is what lets a GUI offer this
without asking you to sacrifice whatever is playing.

WHY APPLY, AND NOT LIVE
-----------------------
PipeWire 1.6 still lists the per-band control params (eq_band_0:Gain and friends)
on the node, but writing them through pw-cli is accepted and silently ignored —
the graph moved under audioconvert.filter-graph. So changing a band means
re-rendering and reloading: ~1s, on this sink alone. Verified on 1.6.7; if a later
version honours the control params this can become live without any UI change.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import time

SERVICE = "filter-chain.service"
CONF_DIR = os.path.expanduser("~/.config/pipewire/filter-chain.conf.d")
CONF = os.path.join(CONF_DIR, "99-sea-eq.conf")
STATE = os.path.expanduser("~/.config/sea-shell/software-eq.json")
SINK = "effect_input.eq"

# our band types -> pipewire's builtin biquad labels
PIPEWIRE_LABELS = {
    "peaking": "bq_peaking",
    "low_shelf": "bq_lowshelf",
    "high_shelf": "bq_highshelf",
    "low_pass": "bq_lowpass",
    "high_pass": "bq_highpass",
}

REW_TYPES = {"PK": "peaking", "LS": "low_shelf", "HS": "high_shelf",
             "LP": "low_pass", "HP": "high_pass"}

# Response maths is evaluated at 48 kHz: pipewire recomputes the biquad per graph
# rate, so unlike the DAC path (pinned to its DSP's 96 kHz) there is no single true
# rate here. 48k is what the sink almost always runs at, and the peak of a curve
# barely moves with rate anyway — this only ever picks a pre-gain.
FS = 48000


# ---------------------------------------------------------------------------
# response maths — standard RBJ, used only to work out headroom
#
# Deliberately the textbook b/a convention, NOT the swapped num/den layout
# moondrop_control.py carries: that swap is a quirk of Moondrop's firmware
# packing, and pipewire computes its own coefficients from Freq/Q/Gain.
# ---------------------------------------------------------------------------
def _coeffs(f0, gain, q, kind):
    w0 = 2.0 * math.pi * f0 / FS
    cw, sw = math.cos(w0), math.sin(w0)
    if kind == "peaking":
        A = math.sqrt(10 ** (gain / 20.0))
        al = sw / (2.0 * q)
        a0 = 1.0 + al / A
        return ([(1.0 + al * A) / a0, -2.0 * cw / a0, (1.0 - al * A) / a0],
                [1.0, -2.0 * cw / a0, (1.0 - al / A) / a0])
    if kind in ("low_shelf", "high_shelf"):
        A = 10 ** (gain / 40.0)
        # RBJ reads Q as shelf slope S here; the radicand goes negative once the
        # slope is too steep for the gain. Floor it rather than hand back a NaN
        # that would silently erase the band from the peak search.
        al = sw / 2.0 * math.sqrt(max(0.0, (A + 1.0 / A) * (1.0 / q - 1.0) + 2.0))
        tsa = 2.0 * math.sqrt(A) * al
        if kind == "low_shelf":
            a0 = (A + 1.0) + (A - 1.0) * cw + tsa
            return ([A * ((A + 1.0) - (A - 1.0) * cw + tsa) / a0,
                     2.0 * A * ((A - 1.0) - (A + 1.0) * cw) / a0,
                     A * ((A + 1.0) - (A - 1.0) * cw - tsa) / a0],
                    [1.0,
                     -2.0 * ((A - 1.0) + (A + 1.0) * cw) / a0,
                     ((A + 1.0) + (A - 1.0) * cw - tsa) / a0])
        a0 = (A + 1.0) - (A - 1.0) * cw + tsa
        return ([A * ((A + 1.0) + (A - 1.0) * cw + tsa) / a0,
                 -2.0 * A * ((A - 1.0) + (A + 1.0) * cw) / a0,
                 A * ((A + 1.0) + (A - 1.0) * cw - tsa) / a0],
                [1.0,
                 2.0 * ((A - 1.0) - (A + 1.0) * cw) / a0,
                 ((A + 1.0) - (A - 1.0) * cw - tsa) / a0])
    if kind in ("low_pass", "high_pass"):
        al = sw / (2.0 * q)
        a0 = 1.0 + al
        if kind == "low_pass":
            return ([(1.0 - cw) / 2.0 / a0, (1.0 - cw) / a0, (1.0 - cw) / 2.0 / a0],
                    [1.0, -2.0 * cw / a0, (1.0 - al) / a0])
        return ([(1.0 + cw) / 2.0 / a0, -(1.0 + cw) / a0, (1.0 + cw) / 2.0 / a0],
                [1.0, -2.0 * cw / a0, (1.0 - al) / a0])
    return None


def band_db(band, f):
    """This band's gain in dB at frequency f."""
    if band.get("type") == "disabled":
        return 0.0
    c = _coeffs(float(band["frequency"]), float(band["gain"]), float(band["q"]), band["type"])
    if not c:
        return 0.0
    b, a = c
    w = 2.0 * math.pi * f / FS
    c1, c2, s1, s2 = math.cos(w), math.cos(2 * w), math.sin(w), math.sin(2 * w)
    nr = b[0] + b[1] * c1 + b[2] * c2
    ni = -(b[1] * s1 + b[2] * s2)
    dr = a[0] + a[1] * c1 + a[2] * c2
    di = -(a[1] * s1 + a[2] * s2)
    dm = dr * dr + di * di
    if dm <= 0:
        return 0.0
    mag = math.sqrt((nr * nr + ni * ni) / dm)
    return 20.0 * math.log10(mag) if mag > 1e-12 else -120.0


def curve_peak(filters, points=240):
    """Highest point of the SUMMED response, dB. Overlapping bands add, so the
    biggest single band is not the answer."""
    peak = 0.0
    lo, hi = math.log10(20.0), math.log10(20000.0)
    for n in range(points + 1):
        f = 10 ** (lo + (hi - lo) * n / points)
        s = sum(band_db(b, f) for b in filters)
        if s > peak:
            peak = s
    return peak


# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
def parse_rew(path):
    """Parse a REW / AutoEQ 'ParametricEQ.txt'. Returns (filters, preamp_db)."""
    import re
    filters, preamp = [], 0.0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            pm = re.match(r"(?:Preamp|Pre-gain|Pre-amp):\s*([\d.-]+)\s*dB", line, re.IGNORECASE)
            if pm:
                preamp = float(pm.group(1))
                continue
            fm = re.match(r"Filter\s+(\d+):\s*(ON|OFF)\s+([a-zA-Z0-9_]+)\s+Fc\s+([\d.]+)\s*Hz\s+"
                          r"Gain\s+([\d.-]+)\s*dB\s+Q\s+([\d.]+)", line, re.IGNORECASE)
            if fm:
                t = REW_TYPES.get(fm.group(3).upper(), "peaking")
                if fm.group(2).upper() == "OFF":
                    t = "disabled"
                filters.append({"index": int(fm.group(1)) - 1, "type": t,
                                "frequency": float(fm.group(4)), "gain": float(fm.group(5)),
                                "q": float(fm.group(6))})
    return filters, preamp


def load_json(path):
    """Returns (filters, preamp_or_None). None means 'nobody told us' — compute it."""
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    # "filters" is --export-json's shape; "bands" is --preset's. Accept either:
    # piping one into the other is the obvious thing to try.
    filters = d.get("filters", d.get("bands", []))
    return filters, d.get("pregain")


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
def build_config(filters, preamp=0.0, node_name="eq", description="Universal EQ"):
    """Render a libpipewire-module-filter-chain config: a virtual sink applying
    these bands to whatever it is routed to.

    The graph is mono (one In, one Out); filter-chain instantiates it per channel,
    so it EQs both sides of a stereo stream identically. Nodes are linked
    explicitly in series — filter-chain does not chain them implicitly.
    """
    nodes, links, prev = [], [], None

    if abs(preamp) > 1e-9:
        # No biquad does plain gain, so scale the samples: dB -> linear multiplier.
        mult = 10 ** (preamp / 20.0)
        nodes.append(f'                {{ type = builtin name = preamp label = linear '
                     f'control = {{ "Mult" = {mult:.6f} "Add" = 0.0 }} }}')
        prev = "preamp"

    for f in sorted(filters, key=lambda x: x["index"]):
        if f["type"] == "disabled":
            continue
        label = PIPEWIRE_LABELS.get(f["type"])
        if label is None:
            continue
        name = f"eq_band_{f['index']}"
        nodes.append(f'                {{ type = builtin name = {name} label = {label} '
                     f'control = {{ "Freq" = {float(f["frequency"]):g} "Q" = {float(f["q"]):g} '
                     f'"Gain" = {float(f["gain"]):g} }} }}')
        if prev is not None:
            links.append(f'                {{ output = "{prev}:Out" input = "{name}:In" }}')
        prev = name

    if not nodes:
        # An empty graph is invalid; a unity-gain node keeps the sink usable.
        nodes.append('                { type = builtin name = passthrough label = linear '
                     'control = { "Mult" = 1.0 "Add" = 0.0 } }')

    nodes_s = "\n".join(nodes)
    links_s = "\n".join(links)
    links_block = f"            links = [\n{links_s}\n            ]\n" if links else ""

    return (
        "# sea-shell software EQ -- generated by sea-eq.py, do not edit by hand\n"
        f"# Select the \"{description}\" output; it feeds your real device.\n"
        "# Managed from the DAC panel (SUPER+SHIFT+E), or with: sea-eq.py --remove\n"
        "context.modules = [\n"
        "{   name = libpipewire-module-filter-chain\n"
        "    args = {\n"
        f"        node.description = \"{description}\"\n"
        f"        media.name       = \"{description}\"\n"
        "        filter.graph = {\n"
        "            nodes = [\n"
        f"{nodes_s}\n"
        "            ]\n"
        f"{links_block}"
        "        }\n"
        "        # Channel config belongs at args level, not inside capture/playback props:\n"
        "        # that is what makes filter-chain replicate the mono graph onto both\n"
        "        # channels. (Matches /usr/share/pipewire/filter-chain/sink-eq6.conf.)\n"
        "        audio.channels = 2\n"
        "        audio.position = [ FL FR ]\n"
        "        capture.props = {\n"
        f"            node.name   = \"effect_input.{node_name}\"\n"
        "            media.class = Audio/Sink\n"
        "        }\n"
        "        playback.props = {\n"
        f"            node.name    = \"effect_output.{node_name}\"\n"
        "            node.passive = true\n"
        "        }\n"
        "    }\n"
        "}\n"
        "]\n"
    )


# ---------------------------------------------------------------------------
# lifecycle
# ---------------------------------------------------------------------------
def _sh(*argv):
    """Run a command, return (rc, stdout). Never raises for a missing binary."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=25)
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def status():
    _, active = _sh("systemctl", "--user", "is-active", SERVICE)
    _, sinks = _sh("pactl", "list", "short", "sinks")
    try:
        with open(STATE, encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, json.JSONDecodeError):
        st = {}
    return {
        "installed": os.path.exists(CONF),
        "running": active == "active",
        "sink_present": SINK in sinks,
        "sink": SINK,
        "service": SERVICE,
        "conf": CONF,
        "pregain": st.get("pregain", 0.0),
        "filters": st.get("filters", []),
        "name": st.get("name", ""),
    }


def apply_bands(filters, preamp, name=""):
    """Render and (re)load. Returns (ok, message)."""
    os.makedirs(CONF_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(build_config(filters, preamp))
    os.replace(tmp, CONF)       # atomic: a failed render can't leave a half-file
    with open(STATE, "w", encoding="utf-8") as fh:
        json.dump({"pregain": preamp, "filters": filters, "name": name}, fh, indent=2)

    rc, _ = _sh("systemctl", "--user", "restart", SERVICE)
    if rc != 0:
        return False, f"could not start {SERVICE} (systemctl exit {rc})"
    # Starting is not the same as working: a bad graph makes the daemon exit, and
    # the only honest confirmation is the sink actually showing up.
    for _ in range(20):
        time.sleep(0.15)
        _, sinks = _sh("pactl", "list", "short", "sinks")
        if SINK in sinks:
            return True, "applied"
    return False, f"{SERVICE} started but no {SINK} sink appeared"


def remove():
    _sh("systemctl", "--user", "stop", SERVICE)
    for p in (CONF, STATE):
        try:
            os.remove(p)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="sea-shell software EQ (PipeWire filter-chain)")
    ap.add_argument("--status", action="store_true", help="Report state as JSON")
    ap.add_argument("--apply", action="store_true", help="Render bands and (re)load the EQ")
    ap.add_argument("--remove", action="store_true", help="Stop the EQ and delete its config")
    ap.add_argument("--render", metavar="OUT.conf", help="Only write the config file, load nothing")
    ap.add_argument("--from-json", metavar="FILE.json", help="Bands from an exported/preset JSON")
    ap.add_argument("--from-rew", metavar="FILE.txt", help="Bands from an AutoEQ/REW ParametricEQ.txt")
    ap.add_argument("--name", default="", help="Label for these bands (shown by --status)")
    args = ap.parse_args()

    def die(msg):
        print(json.dumps({"ok": False, "error": msg}))
        sys.exit(1)

    if args.status:
        print(json.dumps(status(), indent=2))
        return

    if args.remove:
        remove()
        print(json.dumps({"ok": True, "removed": True}))
        return

    if not (args.apply or args.render):
        ap.print_help()
        return

    if args.from_rew:
        try:
            filters, preamp = parse_rew(args.from_rew)
        except OSError as e:
            die(f"could not read {args.from_rew}: {e}")
    elif args.from_json:
        try:
            filters, preamp = load_json(args.from_json)
        except (OSError, json.JSONDecodeError) as e:
            die(f"could not read {args.from_json}: {e}")
    else:
        die("nothing to render: pass --from-json or --from-rew")

    if not filters:
        die("no EQ bands to render")
    if preamp is None:
        # The source didn't ship one (a community preset never does). Buy back the
        # headroom the curve needs rather than rendering something that clips.
        peak = curve_peak(filters)
        preamp = -round(peak, 1) if peak > 0 else 0.0

    active = [f for f in filters if f.get("type") != "disabled"]

    if args.render:
        with open(args.render, "w", encoding="utf-8") as fh:
            fh.write(build_config(filters, preamp))
        print(json.dumps({"ok": True, "bands": len(active), "pregain": preamp,
                          "wrote": args.render}, indent=2))
        return

    ok, msg = apply_bands(filters, preamp, name=args.name)
    print(json.dumps({"ok": ok, "error": None if ok else msg, "bands": len(active),
                      "pregain": preamp, "sink": SINK, "conf": CONF}, indent=2))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
