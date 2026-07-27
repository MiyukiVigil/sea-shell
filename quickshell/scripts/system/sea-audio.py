#!/usr/bin/env python3
"""sea-audio — PipeWire routing + device-info for the sea-shell "Sound" surface (4.0).

This is the data/plumbing layer for the audio pieces the shell does NOT already have.
It deliberately owns nothing the DAC panel / sea-eq.py already cover (EQ, filter-chains):
its job is the three real gaps —

  1. per-app OUTPUT routing   — send one app to a specific sink, not just the default
  2. device format readout    — the sink's live sample-rate / bit-depth (or, idle, the
                                graph rate + what the sink *can* do), plus a Bluetooth codec
  3. a clean sink + stream map the QML can render without re-parsing pw-dump itself

Everything is read from `pw-dump` (one JSON snapshot of the whole graph) so there's a
single source of truth and no racing of several CLIs. Actions use `pw-metadata`
(routing / default) which WirePlumber honours.

Subcommands:
  --status              emit the whole audio map as JSON (default)
  --route S SINK        send stream node S to SINK (id, object.serial, or node.name);
                        SINK "" / "auto" / "-1" clears the override (back to default)
  --default SINK        set the default output sink
  (BT codec *switching* is intentionally not here yet — we read the current codec, but
   changing it is a device-Route param write that needs a connected device to get right.)

Output shape (--status):
  {"ok": true,
   "graph": {"rate": 48000, "allowed": [44100,48000], "quantum": 1024},
   "default_sink": "alsa_output...",           # node.name of the default sink
   "sinks":   [{"id","serial","name","label","default","channels","bt_codec",
                "active","rate","format","bits","rates","formats"}, ...],
   "streams": [{"id","app","title","sink_id","sink_label","volume","muted"}, ...]}
  {"ok": false, "err": "..."}
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

# PCM format name -> bit depth, for the "S24LE → 24-bit" readout.
_BITS = {
    "U8": 8, "S8": 8,
    "S16LE": 16, "S16BE": 16, "S16": 16,
    "S24LE": 24, "S24BE": 24, "S24": 24, "S24_32LE": 24, "S24_32BE": 24, "S24_32": 24,
    "S32LE": 32, "S32BE": 32, "S32": 32,
    "F32LE": 32, "F32BE": 32, "F32": 32, "F64LE": 64, "F64BE": 64,
}


def _bits(fmt: str | None):
    if not fmt:
        return None
    return _BITS.get(fmt) or _BITS.get(fmt.rstrip("LEB"))  # tolerate endianness spelling


def _dump():
    r = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=8)
    return json.loads(r.stdout)


def _props(o):
    return (o.get("info") or {}).get("props") or {}


def _params(o):
    return (o.get("info") or {}).get("params") or {}


def _fmt_from_param(param):
    """Pull (rate, format, channels) out of a Format/EnumFormat param entry list.
    Only present (non-empty) while a sink is actively streaming."""
    rate = fmt = chan = None
    for f in param or []:
        if not isinstance(f, dict):
            continue
        rate = f.get("rate", rate)
        chan = f.get("channels", chan)
        fmt = f.get("format", fmt)
    # `rate` can arrive as {"num":48000,"denom":1} or a flat int depending on version
    if isinstance(rate, dict):
        rate = rate.get("num")
    return rate, fmt, chan


def _enumformat(o):
    """What the sink *can* do: (max_rate, sorted rates, sorted format names)."""
    rates, formats = set(), set()
    for e in _params(o).get("EnumFormat") or []:
        if not isinstance(e, dict):
            continue
        r = e.get("rate")
        if isinstance(r, dict):
            # a range/choice: {"default":..,"min":..,"max":..} or {"none":[...]}
            for v in list(r.values()):
                if isinstance(v, list):
                    rates.update(x for x in v if isinstance(x, int))
                elif isinstance(v, int):
                    rates.add(v)
        elif isinstance(r, int):
            rates.add(r)
        elif isinstance(r, list):
            rates.update(x for x in r if isinstance(x, int))
        f = e.get("format")
        if isinstance(f, str):
            formats.add(f)
        elif isinstance(f, list):
            formats.update(x for x in f if isinstance(x, str))
        elif isinstance(f, dict):
            for v in f.values():
                if isinstance(v, list):
                    formats.update(x for x in v if isinstance(x, str))
    return (max(rates) if rates else None,
            sorted(rates),
            sorted(formats, key=lambda s: _bits(s) or 0))


def _metadata(dump, name):
    # NB: Metadata objects carry their props at the TOP level (o["props"]), unlike
    # Nodes which nest them under o["info"]["props"]. Check the top level here.
    for o in dump:
        if o.get("type") != "PipeWire:Interface:Metadata":
            continue
        if (o.get("props") or {}).get("metadata.name") == name:
            return o.get("metadata") or []
    return []


def _default_sink(dump):
    for m in _metadata(dump, "default"):
        if m.get("key") == "default.audio.sink":
            v = m.get("value")
            return v.get("name") if isinstance(v, dict) else v
    return None


def _graph(dump):
    g = {"rate": None, "allowed": [], "quantum": None}
    for m in _metadata(dump, "settings"):
        k, v = m.get("key"), m.get("value")
        if k == "clock.rate":
            g["rate"] = int(v) if str(v).isdigit() else v
        elif k == "clock.force-rate" and v and str(v) != "0":
            g["rate"] = int(v) if str(v).isdigit() else v
        elif k == "clock.allowed-rates" and isinstance(v, list):
            g["allowed"] = [x for x in v if isinstance(x, int)]
        elif k in ("clock.quantum", "clock.force-quantum") and v and str(v) != "0":
            g["quantum"] = int(v) if str(v).isdigit() else v
    return g


def _links(dump):
    """stream-node-id -> sink-node-id, from Link objects (the real routing)."""
    out = {}
    for o in dump:
        if o.get("type") != "PipeWire:Interface:Link":
            continue
        info = o.get("info") or {}
        s = info.get("output-node-id")
        d = info.get("input-node-id")
        if s is not None and d is not None:
            out.setdefault(s, d)
    return out


# WirePlumber exposes each Bluetooth A2DP codec as its own card *profile* — the codec
# name is spelled out in the profile description ("...codec AAC"). So enumerating /
# switching codecs is enumerating / switching those a2dp-sink* profiles.
_CODEC_RE = re.compile(r"codec ([\w+\-]+)", re.I)


def _bt_profiles(dump, device_id):
    """(codecs, card_name, active_profile) for a bluez device, over its A2DP profiles.
    codecs = [{"profile","codec","active"}], flattened for the QML to render as chips."""
    if device_id is None:
        return [], None, None
    dev = None
    for o in dump:
        if o.get("type") == "PipeWire:Interface:Device" and o.get("id") == int(device_id):
            dev = o
            break
    if not dev:
        return [], None, None
    params = (dev.get("info") or {}).get("params") or {}
    card = ((dev.get("info") or {}).get("props") or {}).get("device.name")
    cur = params.get("Profile") or []
    cur_name = cur[0].get("name") if cur else None
    out = []
    for e in params.get("EnumProfile") or []:
        nm = e.get("name", "")
        if not nm.startswith("a2dp") or e.get("available") == "no":
            continue
        m = _CODEC_RE.search(e.get("description", ""))
        out.append({"profile": nm,
                    "codec": (m.group(1) if m else nm),
                    "active": nm == cur_name})
    return out, card, cur_name


def status():
    dump = _dump()
    default_name = _default_sink(dump)
    graph = _graph(dump)
    links = _links(dump)

    nodes = [o for o in dump if o.get("type") == "PipeWire:Interface:Node"]
    sinks, sink_by_id = [], {}
    for o in nodes:
        p = _props(o)
        if p.get("media.class") != "Audio/Sink":
            continue
        rate, fmt, chan = _fmt_from_param(_params(o).get("Format"))
        active = rate is not None
        max_rate, rates, formats = _enumformat(o)
        label = p.get("node.nick") or p.get("node.description") or p.get("node.name", "?")
        entry = {
            "id": o["id"],
            "serial": p.get("object.serial"),
            "name": p.get("node.name"),
            "label": label,
            "default": p.get("node.name") == default_name,
            "channels": chan or (int(p["audio.channels"]) if "audio.channels" in p else None),
            "bt_codec": p.get("api.bluez5.codec"),
            "active": active,
            # live rate while playing, else what it'll run at (the graph clock)
            "rate": rate or graph.get("rate"),
            "format": fmt,
            "bits": _bits(fmt),
            "rates": rates,
            "formats": formats,
        }
        if entry["bt_codec"]:      # a bluetooth sink → enumerate its switchable codecs
            profs, card, _ = _bt_profiles(dump, p.get("device.id"))
            entry["bt_codecs"] = profs
            entry["card"] = card
        sinks.append(entry)
        sink_by_id[o["id"]] = label
    sinks.sort(key=lambda s: (not s["default"], s["label"].lower()))

    streams = []
    for o in nodes:
        p = _props(o)
        if not str(p.get("media.class", "")).startswith("Stream/Output/Audio"):
            continue
        if p.get("stream.monitor") == "true":
            continue
        sink_id = links.get(o["id"])
        streams.append({
            "id": o["id"],
            "app": p.get("application.name") or p.get("node.name") or "?",
            "title": p.get("media.name") or "",
            "sink_id": sink_id,
            "sink_label": sink_by_id.get(sink_id),
            "volume": None,   # volume lives in the Props param; the shell already has it via Pipewire service
            "muted": None,
        })

    return {"ok": True, "graph": graph, "default_sink": default_name,
            "sinks": sinks, "streams": streams}


def _resolve_sink(dump, ref):
    """A user-supplied SINK (id / serial / node.name / label) -> node.name."""
    ref = str(ref).strip()
    for o in dump:
        if o.get("type") != "PipeWire:Interface:Node":
            continue
        p = _props(o)
        if p.get("media.class") != "Audio/Sink":
            continue
        if (str(o["id"]) == ref or str(p.get("object.serial")) == ref
                or p.get("node.name") == ref or p.get("node.nick") == ref):
            return p.get("node.name")
    return None


def route(stream, sink):
    """Pin stream node -> sink via the target.object metadata WirePlumber honours."""
    clear = str(sink).strip().lower() in ("", "auto", "-1", "default")
    if clear:
        # Release the pin by DELETING the key (omit the value) — WirePlumber then
        # follows the default sink again. Passing "-1" as a value doesn't work:
        # pw-metadata's option parser eats the leading '-'. Deleting is the clean way.
        subprocess.run(["pw-metadata", str(stream), "target.object"],
                       check=True, capture_output=True, text=True)
        # older wireplumber keyed the pin as target.node; clear that too, best-effort
        subprocess.run(["pw-metadata", str(stream), "target.node"],
                       capture_output=True, text=True)
        return {"ok": True, "stream": stream, "target": None}
    dump = _dump()
    name = _resolve_sink(dump, sink)
    if not name:
        return {"ok": False, "err": f"no sink matching {sink!r}"}
    subprocess.run(["pw-metadata", str(stream), "target.object", name, "Spa:String"],
                   check=True, capture_output=True, text=True)
    return {"ok": True, "stream": stream, "target": name}


def set_default(sink):
    dump = _dump()
    name = _resolve_sink(dump, sink)
    if not name:
        return {"ok": False, "err": f"no sink matching {sink!r}"}
    subprocess.run(["pw-metadata", "0", "default.audio.sink",
                    json.dumps({"name": name}), "Spa:String:JSON"],
                   check=True, capture_output=True, text=True)
    return {"ok": True, "default_sink": name}


def bt_codec(sink_ref, codec):
    """Switch a Bluetooth sink's A2DP codec by switching its card profile.
    `codec` may be a profile name (a2dp-sink-sbc) or a codec name (SBC / AAC …)."""
    dump = _dump()
    sink = None
    for o in dump:
        if o.get("type") != "PipeWire:Interface:Node":
            continue
        p = _props(o)
        if p.get("media.class") != "Audio/Sink":
            continue
        if (str(o["id"]) == str(sink_ref) or str(p.get("object.serial")) == str(sink_ref)
                or p.get("node.name") == sink_ref or p.get("node.nick") == sink_ref):
            sink = o
            break
    if not sink:
        return {"ok": False, "err": f"no sink matching {sink_ref!r}"}
    profs, card, _ = _bt_profiles(dump, _props(sink).get("device.id"))
    if not card:
        return {"ok": False, "err": "that sink is not a bluetooth device"}
    norm = lambda s: re.sub(r"[^a-z0-9]", "", str(s).lower())   # "SBC-XQ" == "sbc_xq"
    ref = norm(codec)
    target = next((pr["profile"] for pr in profs
                   if norm(pr["profile"]) == ref or norm(pr["codec"]) == ref), None)
    if not target:
        return {"ok": False, "err": f"no codec {codec!r} here (have: {[pr['codec'] for pr in profs]})"}
    subprocess.run(["pactl", "set-card-profile", card, target], check=True,
                   capture_output=True, text=True)
    return {"ok": True, "card": card, "profile": target}


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--status", action="store_true")
    g.add_argument("--route", nargs=2, metavar=("STREAM", "SINK"))
    g.add_argument("--default", metavar="SINK")
    g.add_argument("--bt-codec", nargs=2, metavar=("SINK", "CODEC"), dest="bt_codec")
    args = ap.parse_args()

    try:
        if args.route:
            out = route(args.route[0], args.route[1])
        elif args.default:
            out = set_default(args.default)
        elif args.bt_codec:
            out = bt_codec(args.bt_codec[0], args.bt_codec[1])
        else:
            out = status()
    except Exception as e:  # noqa: BLE001 — always answer with JSON so the QML can show it
        out = {"ok": False, "err": str(e)}
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
