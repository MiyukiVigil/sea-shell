#!/usr/bin/env python3
"""Backend helper for sea-shell macOS-style System Settings.

Provides safe, structured JSON queries and atomic mutations for:
- Date & Time (timedatectl)
- Language & Region (localectl)
- Device Hostname (hostnamectl)
- Login Items & User Startup Services (~/.config/autostart + systemctl --user)
- Wired Network & Quick DNS (nmcli)
- Privacy & Security (ufw, clipboard history, active mic/camera)
- Hyprland Compositor, Keyboard & Accessibility settings (compositor.json + compositor.lua + hyprctl eval)
"""

import base64
import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CFG_DIR = Path.home() / ".config/sea-shell"
HYPR_SEA_DIR = Path.home() / ".config/hypr/sea-shell"
AUTOSTART_DIR = Path.home() / ".config/autostart"
COMPOSITOR_JSON = CFG_DIR / "compositor.json"
COMPOSITOR_LUA = HYPR_SEA_DIR / "compositor.lua"

COMPOSITOR_DEFAULTS = {
    "gaps_in": 5,
    "gaps_out": 12,
    "border_size": 2,
    "rounding": 10,
    "blur_enabled": True,
    "blur_size": 9,
    "blur_passes": 4,
    "shadow_enabled": True,
    "inactive_opacity": 0.96,
    "animations_enabled": True,
    "follow_mouse": 1,
    "kb_layout": "us",
    "kb_options": "",
    "repeat_rate": 25,
    "repeat_delay": 600,
    "numlock_by_default": True,
    "cursor_size": 24,
    "zoom_factor": 1.0,
}

DNS_PRESETS = {
    "auto": [],
    "cloudflare": ["1.1.1.1", "1.0.0.1"],
    "quad9": ["9.9.9.9", "149.112.112.112"],
    "google": ["8.8.8.8", "8.8.4.4"],
}

WATCHED_USER_SERVICES = [
    ("pipewire.service", "PipeWire Audio"),
    ("wireplumber.service", "WirePlumber Session"),
    ("xdg-desktop-portal.service", "Desktop Portals"),
    ("hypridle.service", "Idle Daemon"),
    ("kdeconnectd.service", "KDE Connect"),
    ("ssh-agent.service", "SSH Agent"),
    ("syncthing.service", "Syncthing"),
]


def run(cmd, timeout=6):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as exc:
        return 1, "", str(exc)


def atomic_write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def out_json(obj):
    print(json.dumps(obj, ensure_ascii=False))


# ---------------- Date & Time ----------------

def datetime_status():
    code, stdout, _ = run(["timedatectl", "show"])
    props = {}
    if code == 0:
        for line in stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
    tz = props.get("Timezone", "")
    if not tz:
        try:
            tz = Path("/etc/timezone").read_text().strip()
        except Exception:
            tz = "UTC"
    ntp = props.get("NTP", "no").lower() in ("yes", "true", "1")
    ntp_synced = props.get("NTPSynchronized", "no").lower() in ("yes", "true", "1")
    local_rtc = props.get("LocalRTC", "no").lower() in ("yes", "true", "1")
    out_json({
        "ok": True,
        "timezone": tz,
        "ntp": ntp,
        "ntpSynced": ntp_synced,
        "localRtc": local_rtc,
    })


def datetime_timezones(query=""):
    code, stdout, _ = run(["timedatectl", "list-timezones"])
    zones = [z.strip() for z in stdout.splitlines() if z.strip()] if code == 0 else []
    q = (query or "").strip().lower()
    if q:
        zones = [z for z in zones if q in z.lower()]
    else:
        featured = [
            "UTC", "America/New_York", "America/Chicago", "America/Denver",
            "America/Los_Angeles", "Europe/London", "Europe/Paris", "Europe/Berlin",
            "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Kuala_Lumpur",
            "Asia/Kuching", "Asia/Shanghai", "Asia/Tokyo", "Asia/Seoul",
            "Australia/Sydney", "Pacific/Auckland",
        ]
        if zones:
            zset = set(zones)
            zones = [z for z in featured if z in zset] + [z for z in zones if z not in featured][:60]
    out_json({"ok": True, "timezones": zones[:80]})


def datetime_set_ntp(val: str):
    flag = "true" if str(val).lower() in ("1", "true", "yes", "on") else "false"
    code, _, err = run(["timedatectl", "set-ntp", flag], timeout=20)
    out_json({"ok": code == 0, "error": err.strip() if code != 0 else ""})


def datetime_set_tz(tz: str):
    tz = (tz or "").strip()
    if not tz or not re.match(r"^[A-Za-z0-9_+/.-]+$", tz):
        out_json({"ok": False, "error": "Invalid timezone"})
        return
    code, _, err = run(["timedatectl", "set-timezone", tz], timeout=20)
    out_json({"ok": code == 0, "timezone": tz, "error": err.strip() if code != 0 else ""})


# ---------------- Language & Region ----------------

def locale_status():
    code, stdout, _ = run(["localectl", "status"])
    lang = os.environ.get("LANG", "en_US.UTF-8")
    lc_time = os.environ.get("LC_TIME", "")
    lc_measure = os.environ.get("LC_MEASUREMENT", "")
    keymap = ""
    if code == 0:
        for line in stdout.splitlines():
            s = line.strip()
            if "LANG=" in s:
                m = re.search(r"LANG=([^\s]+)", s)
                if m:
                    lang = m.group(1)
            if "LC_TIME=" in s:
                m = re.search(r"LC_TIME=([^\s]+)", s)
                if m:
                    lc_time = m.group(1)
            if "LC_MEASUREMENT=" in s:
                m = re.search(r"LC_MEASUREMENT=([^\s]+)", s)
                if m:
                    lc_measure = m.group(1)
            if s.startswith("VC Keymap:"):
                keymap = s.split(":", 1)[1].strip()
    c2, lout, _ = run(["localectl", "list-locales"])
    locales = [x.strip() for x in lout.splitlines() if x.strip()] if c2 == 0 else [lang]
    if lang and lang not in locales:
        locales.insert(0, lang)
    out_json({
        "ok": True,
        "lang": lang,
        "lcTime": lc_time or lang,
        "lcMeasurement": lc_measure or lang,
        "keymap": keymap,
        "locales": locales[:60],
    })


def locale_set(lang: str):
    lang = (lang or "").strip()
    if not lang or not re.match(r"^[A-Za-z0-9_.@-]+$", lang):
        out_json({"ok": False, "error": "Invalid locale"})
        return
    code, _, err = run(["localectl", "set-locale", f"LANG={lang}"], timeout=20)
    out_json({"ok": code == 0, "lang": lang, "error": err.strip() if code != 0 else ""})


def hostname_set(name: str):
    name = (name or "").strip()
    if not name or not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$", name):
        out_json({"ok": False, "error": "Use letters, numbers, and hyphens only"})
        return
    code, _, err = run(["hostnamectl", "set-hostname", name], timeout=20)
    out_json({"ok": code == 0, "hostname": name, "error": err.strip() if code != 0 else ""})


# ---------------- Login Items & Startup Services ----------------

def parse_desktop_file(path: Path):
    cp = configparser.ConfigParser(interpolation=None)
    try:
        cp.read(path, encoding="utf-8")
        if "Desktop Entry" not in cp:
            return None
        de = cp["Desktop Entry"]
        name = de.get("Name", path.stem)
        comment = de.get("Comment", "")
        exe = de.get("Exec", "")
        icon = de.get("Icon", "")
        hidden = de.get("Hidden", "false").lower() == "true"
        nodisp = de.get("X-GNOME-Autostart-enabled", "true").lower() == "false"
        return {
            "id": path.name,
            "name": name,
            "comment": comment,
            "exec": exe,
            "icon": icon,
            "enabled": not (hidden or nodisp),
            "path": str(path),
        }
    except Exception:
        return None


def startup_list():
    entries = {}
    sys_dir = Path("/etc/xdg/autostart")
    if sys_dir.is_dir():
        for p in sorted(sys_dir.glob("*.desktop")):
            parsed = parse_desktop_file(p)
            if parsed:
                parsed["system"] = True
                entries[p.name] = parsed
    if AUTOSTART_DIR.is_dir():
        for p in sorted(AUTOSTART_DIR.glob("*.desktop")):
            parsed = parse_desktop_file(p)
            if parsed:
                parsed["system"] = p.name in entries
                entries[p.name] = parsed

    apps = sorted(entries.values(), key=lambda x: (not x["enabled"], x["name"].lower()))

    services = []
    code, uout, _ = run(["systemctl", "--user", "list-unit-files", "--type=service", "--no-legend", "--no-pager"])
    installed = {}
    if code == 0:
        for line in uout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                installed[parts[0]] = parts[1]

    for unit, label in WATCHED_USER_SERVICES:
        if unit not in installed:
            continue
        _, act_out, _ = run(["systemctl", "--user", "is-active", unit])
        state = act_out.strip() or "inactive"
        services.append({
            "unit": unit,
            "label": label,
            "active": state == "active",
            "state": state,
            "enabled": installed[unit] in ("enabled", "static", "enabled-runtime"),
            "preset": installed[unit],
        })

    out_json({"ok": True, "apps": apps, "services": services})


def startup_toggle_app(filename: str, enable_str: str):
    fname = os.path.basename(filename or "")
    if not fname.endswith(".desktop"):
        out_json({"ok": False, "error": "Invalid desktop entry"})
        return
    enable = str(enable_str).lower() in ("1", "true", "yes", "on")
    AUTOSTART_DIR.mkdir(parents=True, exist_ok=True)
    user_path = AUTOSTART_DIR / fname
    sys_path = Path("/etc/xdg/autostart") / fname
    if not user_path.exists():
        if sys_path.exists():
            shutil.copy2(sys_path, user_path)
        else:
            out_json({"ok": False, "error": "Entry not found"})
            return
    lines = user_path.read_text(encoding="utf-8", errors="replace").splitlines()
    out_lines = []
    seen_hidden = False
    seen_gnome = False
    for line in lines:
        if line.startswith("Hidden="):
            out_lines.append(f"Hidden={'false' if enable else 'true'}")
            seen_hidden = True
        elif line.startswith("X-GNOME-Autostart-enabled="):
            out_lines.append(f"X-GNOME-Autostart-enabled={'true' if enable else 'false'}")
            seen_gnome = True
        else:
            out_lines.append(line)
    if not seen_hidden:
        out_lines.append(f"Hidden={'false' if enable else 'true'}")
    if not seen_gnome:
        out_lines.append(f"X-GNOME-Autostart-enabled={'true' if enable else 'false'}")
    atomic_write(user_path, "\n".join(out_lines) + "\n")
    out_json({"ok": True})


def startup_add_app(desktop_id: str):
    did = os.path.basename(desktop_id or "")
    if not did:
        out_json({"ok": False, "error": "Missing desktop id"})
        return
    if not did.endswith(".desktop"):
        did += ".desktop"
    candidates = [
        Path.home() / ".local/share/applications" / did,
        Path("/usr/share/applications") / did,
        Path("/usr/local/share/applications") / did,
    ]
    src = next((c for c in candidates if c.exists()), None)
    if not src:
        out_json({"ok": False, "error": f"Application {did} not found"})
        return
    AUTOSTART_DIR.mkdir(parents=True, exist_ok=True)
    dst = AUTOSTART_DIR / did
    shutil.copy2(src, dst)
    startup_toggle_app(did, "true")


def startup_remove_app(filename: str):
    fname = os.path.basename(filename or "")
    user_path = AUTOSTART_DIR / fname
    sys_path = Path("/etc/xdg/autostart") / fname
    if sys_path.exists():
        # System entry: disable instead of deleting user override
        startup_toggle_app(fname, "false")
        return
    if user_path.exists():
        user_path.unlink()
    out_json({"ok": True})


def startup_service_action(unit: str, action: str):
    allowed_units = {u for u, _ in WATCHED_USER_SERVICES}
    if unit not in allowed_units or action not in ("start", "stop", "restart", "enable", "disable"):
        out_json({"ok": False, "error": "Unsupported service action"})
        return
    cmd = ["systemctl", "--user", action, unit]
    if action in ("enable", "disable"):
        cmd.insert(3, "--now")
    code, _, err = run(cmd, timeout=10)
    out_json({"ok": code == 0, "error": err.strip() if code != 0 else ""})


# ---------------- Network Extras (Ethernet, Hostname, DNS) ----------------

def network_extra():
    _, host_out, _ = run(["hostname"])
    hostname = host_out.strip() or os.uname().nodename

    wired = []
    active_con = ""
    active_dns = []
    code, dev_out, _ = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev", "status"])
    if code == 0:
        for line in dev_out.splitlines():
            parts = line.split(":")
            if len(parts) < 4:
                continue
            dev, dtype, state, con = parts[0], parts[1], parts[2], ":".join(parts[3:])
            if state == "connected" and not active_con and dtype in ("ethernet", "wifi"):
                active_con = con
            if dtype == "ethernet":
                info = {"device": dev, "state": state, "connection": con, "ip": "", "gw": "", "dns": [], "speed": ""}
                if state == "connected":
                    _, sout, _ = run(["nmcli", "-t", "-f", "IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,WIRED-PROPERTIES.CARRIER", "dev", "show", dev])
                    for sl in sout.splitlines():
                        if sl.startswith("IP4.ADDRESS"):
                            info["ip"] = sl.split(":", 1)[1].strip()
                        elif sl.startswith("IP4.GATEWAY"):
                            info["gw"] = sl.split(":", 1)[1].strip()
                        elif sl.startswith("IP4.DNS"):
                            info["dns"].append(sl.split(":", 1)[1].strip())
                    sp = Path(f"/sys/class/net/{dev}/speed")
                    if sp.exists():
                        try:
                            spd = int(sp.read_text().strip())
                            if spd > 0:
                                info["speed"] = f"{spd // 1000} Gbps" if spd >= 1000 else f"{spd} Mbps"
                        except Exception:
                            pass
                wired.append(info)

    dns_preset = "auto"
    if active_con:
        _, cout, _ = run(["nmcli", "-t", "-f", "ipv4.dns,ipv4.ignore-auto-dns", "con", "show", active_con])
        custom = ""
        ign = "no"
        for cl in cout.splitlines():
            if cl.startswith("ipv4.dns:"):
                custom = cl.split(":", 1)[1].strip()
            elif cl.startswith("ipv4.ignore-auto-dns:"):
                ign = cl.split(":", 1)[1].strip().lower()
        if custom:
            active_dns = [x.strip() for x in custom.replace(",", " ").split() if x.strip()]
        if ign == "yes" and active_dns:
            if "1.1.1.1" in active_dns:
                dns_preset = "cloudflare"
            elif "9.9.9.9" in active_dns:
                dns_preset = "quad9"
            elif "8.8.8.8" in active_dns:
                dns_preset = "google"
            else:
                dns_preset = "custom"

    out_json({
        "ok": True,
        "hostname": hostname,
        "wired": wired,
        "activeConnection": active_con,
        "dnsPreset": dns_preset,
        "dnsServers": active_dns,
    })


def network_set_dns(con_name: str, preset: str):
    if not con_name or preset not in DNS_PRESETS:
        out_json({"ok": False, "error": "Invalid connection or DNS preset"})
        return
    servers = DNS_PRESETS[preset]
    if preset == "auto":
        code, _, err = run(["nmcli", "con", "mod", con_name, "ipv4.dns", "", "ipv4.ignore-auto-dns", "no"])
    else:
        code, _, err = run(["nmcli", "con", "mod", con_name, "ipv4.dns", " ".join(servers), "ipv4.ignore-auto-dns", "yes"])
    if code == 0:
        run(["nmcli", "con", "up", con_name], timeout=12)
    out_json({"ok": code == 0, "preset": preset, "error": err.strip() if code != 0 else ""})


# ---------------- Privacy & Security ----------------

def privacy_status():
    ufw_installed = shutil.which("ufw") is not None
    ufw_enabled = False
    if ufw_installed:
        conf = Path("/etc/ufw/ufw.conf")
        if conf.exists():
            try:
                txt = conf.read_text(encoding="utf-8", errors="replace")
                ufw_enabled = re.search(r"^\s*ENABLED\s*=\s*yes\b", txt, re.M | re.I) is not None
            except Exception:
                pass
        if not ufw_enabled:
            _, s_out, _ = run(["systemctl", "is-active", "ufw.service"])
            # systemctl active only confirms service, conf confirms rules enabled; keep conf priority

    clip_count = 0
    if shutil.which("cliphist"):
        c, co, _ = run(["cliphist", "list"])
        if c == 0 and co.strip():
            clip_count = len(co.strip().splitlines())

    c_watch, _, _ = run(["pgrep", "-f", "wl-paste.*cliphist"])
    clip_watching = c_watch == 0

    # Active mic capture streams via pactl
    mic_apps = []
    if shutil.which("pactl"):
        c, po, _ = run(["pactl", "list", "source-outputs"])
        if c == 0:
            for block in po.split("Source Output #")[1:]:
                m = re.search(r'application\.name\s*=\s*"([^"]+)"', block)
                if m:
                    name = m.group(1)
                    if name not in mic_apps and "peak" not in name.lower():
                        mic_apps.append(name)

    # Active camera devices via /proc/*/fd (no root needed for user's own apps)
    cam_in_use = False
    video_devs = [str(p) for p in Path("/dev").glob("video*")]
    if video_devs:
        uid = os.getuid()
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if proc.stat().st_uid != uid:
                    continue
                fd_dir = proc / "fd"
                for fd in fd_dir.iterdir():
                    try:
                        target = os.readlink(fd)
                        if target.startswith("/dev/video"):
                            cam_in_use = True
                            break
                    except OSError:
                        continue
                if cam_in_use:
                    break
            except OSError:
                continue

    out_json({
        "ok": True,
        "ufwInstalled": ufw_installed,
        "ufwEnabled": ufw_enabled,
        "clipCount": clip_count,
        "clipWatching": clip_watching,
        "micApps": mic_apps,
        "camPresent": len(video_devs) > 0,
        "camInUse": cam_in_use,
    })


def privacy_firewall(action: str):
    if action not in ("enable", "disable"):
        out_json({"ok": False, "error": "Invalid action"})
        return
    if not shutil.which("ufw"):
        out_json({"ok": False, "error": "ufw is not installed"})
        return
    cmd = ["pkexec", "ufw", "--force", "enable"] if action == "enable" else ["pkexec", "ufw", "disable"]
    code, _, err = run(cmd, timeout=30)
    out_json({"ok": code == 0, "error": err.strip() if code != 0 else ""})


def privacy_clear_clipboard():
    if shutil.which("cliphist"):
        run(["cliphist", "wipe"])
    if shutil.which("wl-copy"):
        run(["wl-copy", "--clear"])
    out_json({"ok": True})


# ---------------- Hyprland Compositor, Keyboard & Accessibility ----------------

def read_hypr_option(opt: str, default):
    code, out, _ = run(["hyprctl", "-j", "getoption", opt], timeout=2)
    if code != 0:
        return default
    try:
        j = json.loads(out)
        if "int" in j:
            if isinstance(default, bool):
                return bool(j["int"])
            return int(j["int"])
        if "float" in j:
            return round(float(j["float"]), 2)
        if "str" in j:
            return str(j["str"])
        if "custom" in j:
            # e.g. gaps_in / gaps_out returns "5 5 5 5"
            first = str(j["custom"]).split()[0]
            return int(first)
    except Exception:
        pass
    return default


def load_compositor():
    data = dict(COMPOSITOR_DEFAULTS)
    if COMPOSITOR_JSON.exists():
        try:
            saved = json.loads(COMPOSITOR_JSON.read_text(encoding="utf-8"))
            if isinstance(saved, dict):
                data.update({k: v for k, v in saved.items() if k in COMPOSITOR_DEFAULTS})
        except Exception:
            pass
    else:
        # Seed from live Hyprland if available
        if shutil.which("hyprctl") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
            data["gaps_in"] = read_hypr_option("general:gaps_in", data["gaps_in"])
            data["gaps_out"] = read_hypr_option("general:gaps_out", data["gaps_out"])
            data["border_size"] = read_hypr_option("general:border_size", data["border_size"])
            data["rounding"] = read_hypr_option("decoration:rounding", data["rounding"])
            data["blur_enabled"] = read_hypr_option("decoration:blur:enabled", data["blur_enabled"])
            data["blur_size"] = read_hypr_option("decoration:blur:size", data["blur_size"])
            data["blur_passes"] = read_hypr_option("decoration:blur:passes", data["blur_passes"])
            data["shadow_enabled"] = read_hypr_option("decoration:shadow:enabled", data["shadow_enabled"])
            data["inactive_opacity"] = read_hypr_option("decoration:inactive_opacity", data["inactive_opacity"])
            data["animations_enabled"] = read_hypr_option("animations:enabled", data["animations_enabled"])
            data["follow_mouse"] = read_hypr_option("input:follow_mouse", data["follow_mouse"])
            data["kb_layout"] = read_hypr_option("input:kb_layout", data["kb_layout"])
            data["kb_options"] = read_hypr_option("input:kb_options", data["kb_options"])
            data["repeat_rate"] = read_hypr_option("input:repeat_rate", data["repeat_rate"])
            data["repeat_delay"] = read_hypr_option("input:repeat_delay", data["repeat_delay"])
            data["numlock_by_default"] = read_hypr_option("input:numlock_by_default", data["numlock_by_default"])
    return data


def lua_str(s: str) -> str:
    return json.dumps(str(s))


def render_compositor_lua(d: dict) -> str:
    return (
        "-- Generated by sea-shell Settings (sea-sys-settings.py). Safe to edit via Settings.\n"
        "hl.config({\n"
        "    general = {\n"
        f"        gaps_in = {int(d['gaps_in'])},\n"
        f"        gaps_out = {int(d['gaps_out'])},\n"
        f"        border_size = {int(d['border_size'])},\n"
        "    },\n"
        "    decoration = {\n"
        f"        rounding = {int(d['rounding'])},\n"
        f"        inactive_opacity = {float(d['inactive_opacity']):.2f},\n"
        "        blur = {\n"
        f"            enabled = {'true' if d['blur_enabled'] else 'false'},\n"
        f"            size = {int(d['blur_size'])},\n"
        f"            passes = {int(d['blur_passes'])},\n"
        "        },\n"
        "        shadow = {\n"
        f"            enabled = {'true' if d['shadow_enabled'] else 'false'},\n"
        "        },\n"
        "    },\n"
        "    animations = {\n"
        f"        enabled = {'true' if d['animations_enabled'] else 'false'},\n"
        "    },\n"
        "    input = {\n"
        f"        follow_mouse = {int(d['follow_mouse'])},\n"
        f"        kb_layout = {lua_str(d['kb_layout'])},\n"
        f"        kb_options = {lua_str(d['kb_options'])},\n"
        f"        repeat_rate = {int(d['repeat_rate'])},\n"
        f"        repeat_delay = {int(d['repeat_delay'])},\n"
        f"        numlock_by_default = {'true' if d['numlock_by_default'] else 'false'},\n"
        "    },\n"
        "    cursor = {\n"
        f"        zoom_factor = {float(d['zoom_factor']):.2f},\n"
        "    },\n"
        "})\n"
        f"hl.env('XCURSOR_SIZE', '{int(d['cursor_size'])}')\n"
        f"hl.env('HYPRCURSOR_SIZE', '{int(d['cursor_size'])}')\n"
    )


def compositor_get():
    out_json({"ok": True, "config": load_compositor()})


def compositor_set(b64_payload: str):
    try:
        patch = json.loads(base64.b64decode(b64_payload, validate=True).decode("utf-8"))
        if not isinstance(patch, dict):
            raise ValueError("Payload must be an object")
    except Exception as exc:
        out_json({"ok": False, "error": str(exc)})
        return

    data = load_compositor()
    for k, v in patch.items():
        if k not in COMPOSITOR_DEFAULTS:
            continue
        if k in ("gaps_in", "gaps_out", "border_size", "rounding", "blur_size", "blur_passes",
                 "follow_mouse", "repeat_rate", "repeat_delay", "cursor_size"):
            data[k] = int(v)
        elif k in ("inactive_opacity", "zoom_factor"):
            data[k] = round(float(v), 2)
        elif k in ("blur_enabled", "shadow_enabled", "animations_enabled", "numlock_by_default"):
            data[k] = bool(v)
        elif k in ("kb_layout", "kb_options"):
            s = str(v).strip()
            if re.match(r"^[a-zA-Z0-9_,:+ -]*$", s):
                data[k] = s

    # Clamp to safe ranges
    data["gaps_in"] = max(0, min(40, data["gaps_in"]))
    data["gaps_out"] = max(0, min(60, data["gaps_out"]))
    data["border_size"] = max(0, min(8, data["border_size"]))
    data["rounding"] = max(0, min(28, data["rounding"]))
    data["blur_size"] = max(1, min(20, data["blur_size"]))
    data["blur_passes"] = max(1, min(6, data["blur_passes"]))
    data["inactive_opacity"] = max(0.5, min(1.0, data["inactive_opacity"]))
    data["follow_mouse"] = max(0, min(3, data["follow_mouse"]))
    data["repeat_rate"] = max(10, min(80, data["repeat_rate"]))
    data["repeat_delay"] = max(150, min(1200, data["repeat_delay"]))
    data["cursor_size"] = max(16, min(64, data["cursor_size"]))
    data["zoom_factor"] = max(1.0, min(3.0, data["zoom_factor"]))

    atomic_write(COMPOSITOR_JSON, json.dumps(data, indent=2) + "\n")
    lua_src = render_compositor_lua(data)
    atomic_write(COMPOSITOR_LUA, lua_src)

    # Apply live via hyprctl eval (Lua config mode)
    if shutil.which("hyprctl") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        live_lua = (
            "hl.config({"
            f"general={{gaps_in={data['gaps_in']},gaps_out={data['gaps_out']},border_size={data['border_size']}}},"
            f"decoration={{rounding={data['rounding']},inactive_opacity={data['inactive_opacity']:.2f},"
            f"blur={{enabled={'true' if data['blur_enabled'] else 'false'},size={data['blur_size']},passes={data['blur_passes']}}},"
            f"shadow={{enabled={'true' if data['shadow_enabled'] else 'false'}}}}},"
            f"animations={{enabled={'true' if data['animations_enabled'] else 'false'}}},"
            f"input={{follow_mouse={data['follow_mouse']},kb_layout={lua_str(data['kb_layout'])},"
            f"kb_options={lua_str(data['kb_options'])},repeat_rate={data['repeat_rate']},"
            f"repeat_delay={data['repeat_delay']},numlock_by_default={'true' if data['numlock_by_default'] else 'false'}}},"
            f"cursor={{zoom_factor={data['zoom_factor']:.2f}}}"
            "})"
        )
        run(["hyprctl", "eval", live_lua], timeout=3)
        if "cursor_size" in patch:
            # Keep active cursor theme while updating size
            c_theme = os.environ.get("XCURSOR_THEME", "default")
            if shutil.which("gsettings"):
                _, gt, _ = run(["gsettings", "get", "org.gnome.desktop.interface", "cursor-theme"])
                gt = gt.strip().strip("'\"")
                if gt:
                    c_theme = gt
                run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-size", str(data["cursor_size"])])
            run(["hyprctl", "setcursor", c_theme, str(data["cursor_size"])], timeout=2)

    out_json({"ok": True, "config": data})


def main():
    if len(sys.argv) < 2:
        out_json({"ok": False, "error": "Missing command"})
        sys.exit(1)
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == "datetime-status":
        datetime_status()
    elif cmd == "datetime-timezones":
        datetime_timezones(args[0] if args else "")
    elif cmd == "datetime-set-ntp":
        datetime_set_ntp(args[0] if args else "true")
    elif cmd == "datetime-set-tz":
        datetime_set_tz(args[0] if args else "")
    elif cmd == "locale-status":
        locale_status()
    elif cmd == "locale-set":
        locale_set(args[0] if args else "")
    elif cmd == "hostname-set":
        hostname_set(args[0] if args else "")
    elif cmd == "startup-list":
        startup_list()
    elif cmd == "startup-toggle-app":
        startup_toggle_app(args[0] if len(args) > 0 else "", args[1] if len(args) > 1 else "true")
    elif cmd == "startup-add-app":
        startup_add_app(args[0] if args else "")
    elif cmd == "startup-remove-app":
        startup_remove_app(args[0] if args else "")
    elif cmd == "startup-service":
        startup_service_action(args[0] if len(args) > 0 else "", args[1] if len(args) > 1 else "")
    elif cmd == "network-extra":
        network_extra()
    elif cmd == "network-set-dns":
        network_set_dns(args[0] if len(args) > 0 else "", args[1] if len(args) > 1 else "auto")
    elif cmd == "privacy-status":
        privacy_status()
    elif cmd == "privacy-firewall":
        privacy_firewall(args[0] if args else "")
    elif cmd == "privacy-clear-clipboard":
        privacy_clear_clipboard()
    elif cmd == "compositor-get":
        compositor_get()
    elif cmd == "compositor-set":
        compositor_set(args[0] if args else "")
    else:
        out_json({"ok": False, "error": f"Unknown command: {cmd}"})
        sys.exit(1)


if __name__ == "__main__":
    main()
