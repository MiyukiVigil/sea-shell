#!/usr/bin/env python3
"""Read-only GPU/cooling/shell sampler. Does not measure FPS; use MangoHud alongside it."""
import argparse
import csv
import datetime
import os
from pathlib import Path
import subprocess
import time


def sample_shell():
    rss = ticks = 0
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            if (p / 'comm').read_text().strip() != 'qs':
                continue
            stat = (p / 'stat').read_text().rsplit(')', 1)[1].split()
            ticks += int(stat[11]) + int(stat[12])
            for line in (p / 'status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    rss += int(line.split()[1])
        except (OSError, ValueError, IndexError):
            continue
    return rss, ticks


def cpu_temperature():
    values = []
    for h in Path('/sys/class/hwmon').glob('hwmon*'):
        try:
            if (h / 'name').read_text().strip() != 'coretemp':
                continue
            values += [int(p.read_text()) / 1000 for p in h.glob('temp*_input')]
        except (OSError, ValueError):
            pass
    return max(values) if values else ''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--seconds', type=int, default=600)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.seconds < 1:
        ap.error('--seconds must be positive')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    last_time = time.monotonic()
    _, last_ticks = sample_shell()
    deadline = last_time + args.seconds
    fields = 'temperature.gpu,utilization.gpu,clocks.gr,power.draw,memory.used,clocks_event_reasons.sw_thermal_slowdown'
    with args.output.open('w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['time', 'gpu_temp_c', 'gpu_busy_pct', 'gpu_clock_mhz', 'gpu_power_w',
                         'vram_mib', 'thermal_slowdown', 'shell_rss_mib', 'shell_cpu_pct', 'fan_rpm', 'cpu_temp_c'])
        while time.monotonic() < deadline:
            gpu = subprocess.run(['nvidia-smi', '--query-gpu=' + fields,
                                  '--format=csv,noheader,nounits'], capture_output=True,
                                 text=True, timeout=5)
            if gpu.returncode:
                raise RuntimeError(gpu.stderr.strip())
            rss, ticks = sample_shell()
            now = time.monotonic()
            cpu = max(0, ticks - last_ticks) / os.sysconf('SC_CLK_TCK') / (now - last_time) * 100
            fans = []
            for p in Path('/sys/class/hwmon').glob('hwmon*/fan*_input'):
                try:
                    fans.append(p.read_text().strip())
                except OSError:
                    pass
            for row in csv.reader(gpu.stdout.splitlines(), skipinitialspace=True):
                writer.writerow([datetime.datetime.now().astimezone().isoformat()] + row +
                                [round(rss / 1024, 1), round(cpu, 1), '|'.join(fans), cpu_temperature()])
            f.flush()
            last_time, last_ticks = now, ticks
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    print(args.output)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
