#!/usr/bin/env python3
"""Bounded CPU boost/cooling diagnostic. Needs root; restores the original boost switch.

Does not change fan settings, GPU limits, game settings, or persistent configuration.
Writes samples to stdout. Run while a game and its frame logger are already running.
"""
import csv
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

BOOST = Path('/sys/devices/system/cpu/intel_pstate/no_turbo')
WATCHDOG = '''import pathlib,select,sys
p=pathlib.Path('/sys/devices/system/cpu/intel_pstate/no_turbo')
select.select([sys.stdin], [], [], 180)
p.write_text(sys.argv[1])
'''


def cpu_temp():
    temperatures = []
    for hw in Path('/sys/class/hwmon').glob('hwmon*'):
        try:
            if (hw / 'name').read_text().strip() == 'coretemp':
                temperatures.extend(int(p.read_text()) / 1000 for p in hw.glob('temp*_input'))
        except OSError:
            continue
    return max(temperatures, default='')


def sample(writer, phase, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = subprocess.run(
            ['/usr/bin/nvidia-smi', '--query-gpu=temperature.gpu,utilization.gpu,clocks.gr,power.draw,clocks_event_reasons.sw_thermal_slowdown',
             '--format=csv,noheader,nounits'], capture_output=True, text=True, check=True, timeout=5)
        values = next(csv.reader(result.stdout.splitlines(), skipinitialspace=True))
        writer.writerow([time.time(), phase, BOOST.read_text().strip(), cpu_temp()] + values)
        sys.stdout.flush()
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def main():
    if len(sys.argv) != 1:
        raise SystemExit('Usage: sudo python3 sea-cpu-boost-test.py')
    if os.geteuid() != 0:
        raise SystemExit('Administrator access is needed to temporarily control CPU boost. No settings changed.')
    original = BOOST.read_text().strip()
    if original != '0':
        raise SystemExit('CPU boost is already disabled; no settings changed.')
    # A separate process restores boost on parent exit, including SIGKILL, or after 180s.
    watchdog = subprocess.Popen([sys.executable, '-I', '-c', WATCHDOG, original], stdin=subprocess.PIPE)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    writer = csv.writer(sys.stdout)
    writer.writerow(['epoch', 'phase', 'no_turbo', 'cpu_temp_c', 'gpu_temp_c',
                     'gpu_busy_pct', 'gpu_clock_mhz', 'gpu_power_w', 'thermal_slowdown'])
    try:
        sample(writer, 'baseline', 20)
        BOOST.write_text('1')
        sample(writer, 'boost-off', 90)
        BOOST.write_text(original)
        sample(writer, 'restored', 30)
    finally:
        try:
            BOOST.write_text(original)
        finally:
            watchdog.stdin.close()
            watchdog.wait(timeout=5)
        print('Original CPU boost setting restored.', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
