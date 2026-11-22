#!/usr/bin/env python3
"""sea-dgpu — zero-wake hybrid dGPU status + battery charge-limit inspector.

Reads ONLY Linux sysfs and /proc/<pid>/fd — never invokes nvidia-smi or NVML,
so checking status on battery never wakes a suspended RTX/Radeon dGPU.

Usage:
  sea-dgpu.py              print JSON status
  sea-dgpu.py --limit PCT  write battery charge_control_end_threshold (if writable)
"""
from __future__ import annotations

import glob
import json
import os
import sys
from pathlib import Path

VENDORS = {"0x10de": "NVIDIA", "0x1002": "AMD", "0x8086": "Intel"}


def find_dgpu():
    cards = []
    for path in sorted(glob.glob("/sys/class/drm/card[0-9]*")):
        name = os.path.basename(path)
        if "-" in name:
            continue
        dev = Path(path) / "device"
        vendor_f = dev / "vendor"
        if not vendor_f.is_file():
            continue
        vendor = vendor_f.read_text().strip().lower()
        boot_vga = 0
        try:
            boot_vga = int((dev / "boot_vga").read_text().strip())
        except Exception:
            pass
        rt = "unknown"
        try:
            rt = (dev / "power" / "runtime_status").read_text().strip()
        except Exception:
            pass
        cards.append({
            "card": name,
            "vendor": VENDORS.get(vendor, vendor),
            "vendor_id": vendor,
            "boot_vga": boot_vga == 1,
            "runtime_status": rt,
            "pci": os.path.basename(os.path.realpath(dev)),
        })
    if len(cards) < 2:
        # Single-GPU machine: only report NVIDIA if present as non-hybrid
        for c in cards:
            if c["vendor_id"] == "0x10de":
                c["hybrid"] = False
                return c
        return None
    # Prefer non-boot NVIDIA/AMD discrete GPU
    for c in cards:
        if c["vendor_id"] == "0x10de":
            c["hybrid"] = True
            return c
    for c in cards:
        if not c["boot_vga"]:
            c["hybrid"] = True
            return c
    return None


def find_nvidia_holders():
    """Scan /proc/<pid>/fd for processes holding /dev/nvidia* open (zero GPU wake)."""
    holders = []
    seen = set()
    my_uid = os.getuid()
    for pid_s in os.listdir("/proc"):
        if not pid_s.isdigit():
            continue
        pid = int(pid_s)
        pdir = f"/proc/{pid}"
        try:
            if os.stat(pdir).st_uid != my_uid:
                continue
            fds = os.listdir(f"{pdir}/fd")
        except Exception:
            continue
        hit = False
        for fd in fds:
            try:
                target = os.readlink(f"{pdir}/fd/{fd}")
            except Exception:
                continue
            if target.startswith("/dev/nvidia") and target != "/dev/nvidiactl":
                hit = True
                break
        if not hit:
            continue
        try:
            comm = Path(f"{pdir}/comm").read_text().strip()
        except Exception:
            comm = f"pid-{pid}"
        key = (comm, pid)
        if key in seen:
            continue
        seen.add(key)
        holders.append({"pid": pid, "name": comm})
    # Deduplicate by name while keeping count and first pid
    by_name = {}
    for h in holders:
        n = h["name"]
        if n not in by_name:
            by_name[n] = {"name": n, "pid": h["pid"], "count": 1}
        else:
            by_name[n]["count"] += 1
    return sorted(by_name.values(), key=lambda x: x["name"].lower())[:8]


def battery_charge_limit():
    for bat in sorted(glob.glob("/sys/class/power_supply/BAT*")):
        f = Path(bat) / "charge_control_end_threshold"
        if f.is_file():
            try:
                val = int(f.read_text().strip())
            except Exception:
                val = -1
            return {
                "supported": True,
                "path": str(f),
                "writable": os.access(f, os.W_OK),
                "limit": val,
            }
    return {"supported": False, "path": "", "writable": False, "limit": -1}


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--limit":
        info = battery_charge_limit()
        if not info["supported"]:
            print(json.dumps({"ok": False, "err": "not supported"}))
            return 1
        try:
            pct = max(40, min(100, int(sys.argv[2])))
            Path(info["path"]).write_text(f"{pct}\n")
            print(json.dumps({"ok": True, "limit": pct}))
            return 0
        except Exception as exc:
            print(json.dumps({"ok": False, "err": str(exc)}))
            return 1

    gpu = find_dgpu()
    holders = find_nvidia_holders() if (gpu and gpu["vendor_id"] == "0x10de" and gpu["runtime_status"] == "active") else []
    out = {
        "ok": True,
        "has_dgpu": gpu is not None,
        "gpu": gpu or {},
        "holders": holders,
        "charge_limit": battery_charge_limit(),
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
