#!/usr/bin/python3 -I
"""sea-shell fan daemon (ROOT, runs as sea-fand.service).

    sea-fand            run, following the preset in /var/lib/sea-fan/mode
    sea-fand --release  give the fans back to the firmware and exit

Replaces both the firmware's curve and lm_sensors fancontrol on the Acer Nitro. Measured on
an AN515-58 under the same all-core build:

    firmware   89-92 C at 3300-4500 rpm, so it stays quiet long after the CPU is hot
    fancontrol 5450-5770 rpm with a pwm ceiling of 120, bouncing 4900-5800 within seconds

Why it is built the way it is:

  rpm, not pwm    these fans are steep and uneven (pwm 81 is already 4900 rpm, 140 is 6100),
                  so curves name a speed and each fan's pwm is nudged until it gets there.
  smoothed temp   the package jumps 15 C in a second when a core boosts. Reacting to that is
                  what makes a fan blast and fall back, so rises are averaged over ~20 s and
                  falls over ~30 s.
  limited ramps   the target moves at most 80 rpm/s up and 15 rpm/s down. A change of speed
                  is slow enough not to be noticed as an event.
  holds the EC    the EC's own curve still jumps the fans on raw spikes and drops them seconds
                  later, a loud-soft pulse. A jump the pwm did not cause pulls the target
                  halfway up to it, held for HOLD_S and then wound down like any other fall.
  fails to safe   any error, a stop or a hang hands control back to the firmware: the except
                  below, ExecStopPost, and the systemd watchdog in case the loop itself sticks.
"""
import glob
import os
import signal
import socket
import sys
import time

MODE_FILE = "/var/lib/sea-fan/mode"
TICK = 2.0

# (degrees C, rpm), linear between points, flat beyond the ends. Every preset ends by climbing
# hard near TjMax (100 C here): Quiet is a preference, not a reason to sit at the limit.
CURVES = {
    "quiet": [(60, 2200), (80, 3000), (92, 4200), (96, 4500), (99, 7000)],
    "auto":  [(50, 2400), (65, 3000), (75, 3600), (85, 4200), (92, 5200), (96, 6500), (99, 8000)],
    "max":   [(50, 5500), (75, 6500), (88, 8000)],
}
DEFAULT_MODE = "auto"

RISE_TAU, FALL_TAU = 20.0, 30.0     # seconds, temperature smoothing
RAMP_UP, RAMP_DOWN = 80.0, 15.0     # rpm per second, target speed
DEADBAND = 120                      # rpm; the tach reads in steps, so closer than this is "there"
HOLD_S = 45.0                       # seconds an EC jump is kept before winding down
HOLD_SHARE = 0.5                    # how far toward the EC's jump the held speed goes; all the
                                    # way was steady but sat at the loudest speed of each spike
EC_JUMP = 250                       # rpm in one tick with no pwm rise behind it: the EC did that.
                                    # Must sit above Acer tach steps (~183 rpm on fan2); 150 kept
                                    # re-arming the hold at full speed so the fans never wound down
EC_LAG = 10.0                       # seconds a pwm rise can take to show on the tach
# The EC keeps its own curve as a floor: at a fixed 5% these fans still ran 3500-4700 rpm, stepping
# with temperature. No pwm can go under that, and winding down further only means a longer climb
# before the fans respond again when something gets hot.
MIN_PCT, MAX_PCT = 10, 100
# Heat is the only thing left that gets a fan below the EC's curve, so Quiet also caps the CPU.
# Other presets leave it alone: the performance they ask for is theirs to have.
BOOST_FILE = "/sys/devices/system/cpu/intel_pstate/max_perf_pct"
BOOST_CAP = {"quiet": 60}

# Rough rpm to pwm % from the measurements above: only used to start close to the right speed,
# the loop corrects it from there.
SEED = [(0, 5), (2500, 8), (3850, 20), (4900, 32), (5400, 42), (5750, 45), (6100, 55), (8000, 100)]


def lerp(points, x):
    if x <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return points[-1][1]


def read_int(path):
    with open(path) as fh:
        return int(fh.read().strip())


def write(path, value):
    with open(path, "w") as fh:
        fh.write(str(value))


def find_hwmon(name):
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            with open(path + "/name") as fh:
                if fh.read().strip() == name:
                    return path
        except OSError:
            pass
    return None


def fan_ids(hwmon):
    return sorted(p[len(hwmon) + 4:-6] for p in glob.glob(hwmon + "/fan[0-9]_input")
                  if os.path.exists(hwmon + "/pwm" + p[len(hwmon) + 4:-6]))


def set_boost(pct, path=BOOST_FILE):
    if os.path.exists(path):
        write(path, pct)


def release(hwmon, boost_file=BOOST_FILE):
    # The fans first: nothing that goes wrong with the cap may leave them unmanaged.
    for n in fan_ids(hwmon):
        write(f"{hwmon}/pwm{n}_enable", 2)
    try:
        set_boost(100, boost_file)
    except OSError:
        pass


class Controller:
    def __init__(self, hwmon, cpu_temp, mode_file=MODE_FILE, boost_file=BOOST_FILE):
        self.hwmon, self.cpu_temp, self.mode_file, self.boost_file = hwmon, cpu_temp, mode_file, boost_file
        self.boost = None
        self.fans = fan_ids(hwmon)
        if not self.fans:
            raise RuntimeError("no controllable fans in " + hwmon)
        self.temp = self.raw_temp()
        rpms = [read_int(f"{hwmon}/fan{n}_input") for n in self.fans]
        # Start from what the fans are doing now so taking over is silent. The pwm goes in
        # before manual mode: in firmware mode pwm reads 255, and switching first would be a
        # moment of full speed.
        self.target = max(rpms)
        self.pct = {n: lerp(SEED, r) for n, r in zip(self.fans, rpms)}
        self.floor = {n: MIN_PCT for n in self.fans}
        self.last_rpm = dict(zip(self.fans, rpms))
        self.raised_at = {n: -EC_LAG for n in self.fans}
        self.clock = 0.0
        self.hold_until = 0.0
        for n in self.fans:
            self.apply(n)
            write(f"{hwmon}/pwm{n}_enable", 1)
            self.apply(n)

    def raw_temp(self):
        # temp2 is the GPU as the EC sees it, which unlike nvidia-smi does not wake the dGPU
        temps = [read_int(self.cpu_temp)]
        gpu = f"{self.hwmon}/temp2_input"
        if os.path.exists(gpu):
            temps.append(read_int(gpu))
        return max(temps) / 1000

    def mode(self):
        try:
            with open(self.mode_file) as fh:
                m = fh.read().strip()
        except OSError:
            return DEFAULT_MODE
        return m if m in CURVES else DEFAULT_MODE

    def apply(self, n):
        # the driver works in whole percents and truncates, so round up to land on the one asked for
        write(f"{self.hwmon}/pwm{n}", min(255, int(self.pct[n] * 2.55 + 0.999)))

    def step(self, dt):
        self.clock += dt
        raw = self.raw_temp()
        tau = RISE_TAU if raw > self.temp else FALL_TAU
        self.temp += (raw - self.temp) * min(1.0, dt / tau)

        mode = self.mode()
        boost = BOOST_CAP.get(mode, 100)
        if boost != self.boost:
            set_boost(boost, self.boost_file)
            self.boost = boost

        rpms = {}
        for n in self.fans:
            # Firmware can take the fans back across suspend; manual mode has to be re-claimed.
            if read_int(f"{self.hwmon}/pwm{n}_enable") != 1:
                self.apply(n)
                write(f"{self.hwmon}/pwm{n}_enable", 1)
            rpms[n] = read_int(f"{self.hwmon}/fan{n}_input")

        # Only count a rise that lands clearly above the target. Tach steps around the speed we
        # already asked for are not an EC pulse; treating them as one pinned the hold at max.
        jumped = [rpms[n] for n in self.fans
                  if rpms[n] - self.last_rpm[n] >= EC_JUMP
                  and self.clock - self.raised_at[n] > EC_LAG
                  and rpms[n] > self.target + DEADBAND]
        self.last_rpm = rpms
        want = lerp(CURVES[mode], self.temp)
        if jumped:
            held = want + HOLD_SHARE * (max(jumped) - want)
            # A weaker blip must not re-arm the timer: that pinned target at full speed whenever
            # the tach stepped while we were already louder than the halfway hold.
            if held > self.target:
                self.target = held
                self.hold_until = self.clock + HOLD_S
                # Seed the pwm near that speed now, so the fans are ours before the EC lets go.
                for n in self.fans:
                    seed = lerp(SEED, self.target)
                    if seed > self.pct[n]:
                        self.pct[n] = min(MAX_PCT, seed)
                        self.raised_at[n] = self.clock
                        self.apply(n)

        if want > self.target:
            self.target = min(want, self.target + RAMP_UP * dt)
        elif self.clock >= self.hold_until:
            # Far above the curve (stuck hold, Max → Auto): catch down faster than a normal fall
            rate = RAMP_DOWN if self.target - want < 1500 else RAMP_DOWN * 4
            self.target = max(want, self.target - rate * dt)

        for n in self.fans:
            rpm = rpms[n]
            # A tach of 0 means this pwm is too low to keep the fan turning. Remember that for
            # this run, or the loop would stall it and kick it back up over and over.
            if rpm == 0 and self.target > 0:
                self.floor[n] = min(MAX_PCT, max(self.floor[n], self.pct[n] + 5))
            err = self.target - rpm
            if abs(err) <= DEADBAND:
                continue
            # Above a held target is the EC's spike; easing off under it only digs a dip for
            # when the EC lets go.
            if err < 0 and self.clock < self.hold_until:
                continue
            # The EC takes seconds to follow a change. Stepping down at full rate overshoots, so
            # going down is slow; going up stays quick, heat being the case that cannot wait.
            move = min(3, 1 + int(abs(err) // 300)) if err > 0 else 1
            pct = self.pct[n] + (move if err > 0 else -move)
            pct = max(self.floor[n], min(MAX_PCT, pct))
            if pct != self.pct[n]:
                if pct > self.pct[n]:
                    self.raised_at[n] = self.clock
                self.pct[n] = pct
                self.apply(n)


def notify(msg):
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.sendto(msg.encode(), addr)


def main():
    hwmon = find_hwmon("acer")
    if not hwmon:
        print("sea-fand: no acer hwmon device", file=sys.stderr)
        return 1
    if "--release" in sys.argv[1:]:
        release(hwmon)
        return 0

    core = find_hwmon("coretemp")
    cpu_temp = core + "/temp1_input" if core else hwmon + "/temp1_input"

    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        ctl = Controller(hwmon, cpu_temp)
        notify("READY=1")
        last = time.monotonic()
        while True:
            time.sleep(TICK)
            now = time.monotonic()
            # a long gap is a suspend, not a long tick
            ctl.step(min(now - last, TICK * 3))
            last = now
            notify("WATCHDOG=1")
    finally:
        release(hwmon)


if __name__ == "__main__":
    sys.exit(main())
