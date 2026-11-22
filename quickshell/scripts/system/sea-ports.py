#!/usr/bin/env python3
"""sea-ports — live listening localhost ports & containers for DevHub.

Subcommands:
  list                  JSON {ok, ports: [...], containers: [...]}
  kill <pid>            send SIGTERM to local dev server PID (own user only)
  container-stop <id>   stop a running docker/podman container
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys

PROC_RE = re.compile(r'users:\(\("([^"]+)",pid=(\d+)')
ADDR_RE = re.compile(r'^(.*):(\d+)$')


def list_ports():
    out = []
    seen = set()
    try:
        res = subprocess.run(["ss", "-tlnpH"], capture_output=True, text=True, timeout=3)
    except Exception:
        return out
    for line in res.stdout.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        local = cols[3]
        m = ADDR_RE.match(local)
        if not m:
            continue
        host, port_s = m.group(1).strip("[]"), m.group(2)
        port = int(port_s)
        # Focus on developer/user-facing ports (skip ephemeral RPC > 49000 unless named)
        pm = PROC_RE.search(line)
        proc = pm.group(1) if pm else ""
        pid = int(pm.group(2)) if pm else 0
        if not proc and port < 1024:
            continue
        if port >= 49152 and proc not in ("node", "python3", "python", "vite", "bun", "deno", "ruby", "go", "cargo", "java", "uvicorn", "flask", "next-server"):
            continue
        key = (port, pid)
        if key in seen:
            continue
        seen.add(key)
        # Filter to user-owned processes if pid known, or common dev ports
        own = False
        if pid > 0:
            try:
                own = os.stat(f"/proc/{pid}").st_uid == os.getuid()
            except Exception:
                own = False
        if not own and port not in (80, 443, 3000, 3001, 4000, 4200, 5000, 5173, 5174, 5432, 6379, 8000, 8080, 8081, 8888, 9000, 9090):
            continue
        is_web = port in (80, 443, 3000, 3001, 4000, 4173, 4200, 4321, 5000, 5173, 5174, 5500, 8000, 8080, 8081, 8443, 8888, 9000) or proc in ("node", "vite", "bun", "deno", "python3", "uvicorn", "gunicorn", "caddy", "nginx", "hugo", "ruby")
        out.append({
            "port": port,
            "host": "localhost" if host in ("127.0.0.1", "::1", "*", "0.0.0.0", "::") else host,
            "proc": proc or "service",
            "pid": pid,
            "own": own,
            "url": f"http://localhost:{port}" if is_web else "",
        })
    out.sort(key=lambda x: x["port"])
    return out[:14]


def list_containers():
    engine = shutil.which("docker") or shutil.which("podman")
    if not engine:
        return []
    try:
        res = subprocess.run(
            [engine, "ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"],
            capture_output=True, text=True, timeout=2.5,
        )
        if res.returncode != 0:
            return []
        rows = []
        for ln in res.stdout.splitlines():
            p = ln.split("\t")
            if len(p) >= 4:
                rows.append({"id": p[0], "name": p[1], "image": p[2], "status": p[3], "engine": os.path.basename(engine)})
        return rows[:8]
    except Exception:
        return []


def main():
    args = sys.argv[1:]
    if not args or args[0] == "list":
        print(json.dumps({"ok": True, "ports": list_ports(), "containers": list_containers()}))
        return 0
    if args[0] == "kill" and len(args) >= 2:
        try:
            pid = int(args[1])
            if os.stat(f"/proc/{pid}").st_uid != os.getuid():
                return 1
            os.kill(pid, signal.SIGTERM)
            return 0
        except Exception:
            return 1
    if args[0] == "container-stop" and len(args) >= 2:
        engine = shutil.which("docker") or shutil.which("podman")
        if not engine:
            return 1
        return subprocess.run([engine, "stop", args[1]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    return 2


if __name__ == "__main__":
    sys.exit(main())
