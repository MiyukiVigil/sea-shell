#!/usr/bin/env python3
"""sea-gamepad: reads controllers for the shell and prints what happens as JSON lines.

A controller is not input to Wayland, so nothing else tells the shell about one. Devices are read
without a grab until big picture is the thing on screen: then they are grabbed, so Steam's own
Big Picture does not move at the same time. A game still gets the pad, because the shell closes
the devices while one is running. Nothing here acts on a press: the shell decides what each one means.

Output, one JSON object per line:
  {"t": "pads", "pads": [{"name", "bus", "battery": {"pct", "status"} or null}]}
  {"t": "press", "b": "a"}       a b x y l r menu view home up down left right
  {"t": "release", "b": "a"}

A held direction repeats as further presses, so the shell only has to move once per press.

Reads words on stdin. "pause" closes every device, for while a game is running: a pad's sticks
send hundreds of events a second and nothing here needs them then. "resume" opens them again.
"grab" keeps the events here alone. "ungrab" shares them again. "relay" keeps the home
button here and passes every other event on, so Steam Big Picture can be played and home still
comes back to this shell.

  --allow-virtual   also read virtual devices, for tests. Steam makes a virtual pad for each game,
                    which would otherwise count as a second controller.
"""
import json
import os
import select
import sys
import time

try:
    import evdev
    from evdev import ecodes as ec
except ImportError:
    print(json.dumps({"t": "error", "why": "python-evdev is not installed"}), flush=True)
    sys.exit(0)

BUTTONS = {
    ec.BTN_SOUTH: "a", ec.BTN_EAST: "b",
    # Evdev names 307 and 308 the other way round from where the letters sit on a pad, which is
    # why these are plain numbers: 307 is the left face button on Xbox pads, triangle on PlayStation.
    307: "x", 308: "y",
    ec.BTN_TL: "l", ec.BTN_TR: "r",
    ec.BTN_START: "menu", ec.BTN_SELECT: "view", ec.BTN_MODE: "home",
    ec.BTN_DPAD_UP: "up", ec.BTN_DPAD_DOWN: "down", ec.BTN_DPAD_LEFT: "left", ec.BTN_DPAD_RIGHT: "right",
}
STICK_ON = 0.65
STICK_OFF = 0.45
REPEAT_FIRST = 0.38
REPEAT_NEXT = 0.11
SCAN_EVERY = 2.0
BATTERY_EVERY = 30.0


def emit(obj):
    print(json.dumps(obj), flush=True)


class Pad:
    """Turns one device's raw events into presses. Knows nothing about reading the device."""

    def __init__(self, stick_range=None):
        self.stick_range = stick_range or {}
        self.hat = {"x": 0, "y": 0}
        self.stick = {"x": 0.0, "y": 0.0}
        self.stick_dir = None
        self.hat_dir = None

    def _norm(self, code, value):
        low, high = self.stick_range.get(code, (-32768, 32767))
        if high <= low:
            return 0.0
        return (value - low) / (high - low) * 2 - 1

    def _stick_direction(self):
        x, y = self.stick["x"], self.stick["y"]
        size = max(abs(x), abs(y))
        # Harder to leave than to enter, so a stick held near the line does not chatter.
        if size < (STICK_OFF if self.stick_dir else STICK_ON):
            return None
        if abs(x) >= abs(y):
            return "right" if x > 0 else "left"
        return "down" if y > 0 else "up"

    def _hat_direction(self):
        if self.hat["y"]:
            return "down" if self.hat["y"] > 0 else "up"
        if self.hat["x"]:
            return "right" if self.hat["x"] > 0 else "left"
        return None

    def feed(self, etype, code, value):
        """Returns (buttons, direction changes), each a list of (name, pressed)."""
        out = []
        if etype == ec.EV_KEY and code in BUTTONS and value in (0, 1):
            out.append((BUTTONS[code], value == 1))
        elif etype == ec.EV_ABS:
            if code in (ec.ABS_HAT0X, ec.ABS_HAT0Y):
                self.hat["x" if code == ec.ABS_HAT0X else "y"] = value
                now = self._hat_direction()
                if now != self.hat_dir:
                    if self.hat_dir:
                        out.append((self.hat_dir, False))
                    if now:
                        out.append((now, True))
                    self.hat_dir = now
            elif code in (ec.ABS_X, ec.ABS_Y):
                self.stick["x" if code == ec.ABS_X else "y"] = self._norm(code, value)
                now = self._stick_direction()
                if now != self.stick_dir:
                    if self.stick_dir:
                        out.append((self.stick_dir, False))
                    if now:
                        out.append((now, True))
                    self.stick_dir = now
        return out


def is_pad(dev, allow_virtual):
    caps = dev.capabilities()
    keys = caps.get(ec.EV_KEY, [])
    axes = [a[0] if isinstance(a, tuple) else a for a in caps.get(ec.EV_ABS, [])]
    if ec.BTN_SOUTH not in keys or not (ec.ABS_X in axes or ec.ABS_HAT0X in axes):
        return False
    if allow_virtual:
        return True
    return "/devices/virtual/" not in sysfs_path(dev)


def sysfs_path(dev):
    return os.path.realpath("/sys/class/input/" + os.path.basename(dev.path))


def battery_dir(dev):
    """The controller's own battery, found by walking up from its device.

    Going by device rather than listing every power_supply keeps out mice and headsets, and the
    laptop's own battery.
    """
    here = sysfs_path(dev)
    for _ in range(6):
        ps = os.path.join(here, "power_supply")
        if os.path.isdir(ps):
            for name in sorted(os.listdir(ps)):
                return os.path.join(ps, name)
        here = os.path.dirname(here)
    return None


LEVELS = {"Full": 100, "High": 75, "Normal": 50, "Low": 20, "Critical": 5}


def read_battery(path):
    if not path:
        return None

    def read(name):
        try:
            with open(os.path.join(path, name)) as f:
                return f.read().strip()
        except OSError:
            return ""

    pct = read("capacity")
    # Some drivers only give a word.
    value = int(pct) if pct.isdigit() else LEVELS.get(read("capacity_level"))
    if value is None:
        return None
    return {"pct": value, "status": read("status") or "Unknown"}


class Reader:
    def __init__(self, allow_virtual):
        self.allow_virtual = allow_virtual
        self.devices = {}       # fd -> (InputDevice, Pad, battery dir)
        self.seen = set()       # paths already looked at, so a mouse is only opened once
        self.paused = False
        self.exclusive = False  # grabbed while our big picture is the screen in front
        self.relay = False      # grabbed, but every event except home is passed through
        self.virtual = {}       # physical fd -> uinput device Steam can read
        self.held = None        # (direction, next repeat time)
        self.last_pads = None

    def scan(self):
        try:
            paths = {"/dev/input/" + n for n in os.listdir("/dev/input") if n.startswith("event")}
        except OSError:
            return
        self.seen &= paths
        for path in sorted(paths - self.seen):
            self.seen.add(path)
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            try:
                pad = is_pad(dev, self.allow_virtual)
            except OSError:
                pad = False
            if not pad:
                dev.close()
                continue
            ranges = {}
            for code, info in dev.capabilities().get(ec.EV_ABS, []):
                ranges[code] = (info.min, info.max)
            self.devices[dev.fd] = (dev, Pad(ranges), battery_dir(dev))
            if self.exclusive:
                self._grab(dev, True)
            if self.relay:
                self._open_virtual(dev)
        if self.exclusive:
            # Steam may have grabbed the pad first. Keep trying until this process holds it,
            # or the home button never reaches the shell.
            for dev, _pad, _bat in self.devices.values():
                self._grab(dev, True)
        self.report()

    def report(self):
        pads = []
        for dev, _pad, bat in self.devices.values():
            bus = {3: "usb", 5: "bluetooth"}.get(dev.info.bustype, "other")
            pads.append({"name": dev.name, "bus": bus, "battery": read_battery(bat)})
        if pads != self.last_pads:
            self.last_pads = pads
            emit({"t": "pads", "pads": pads})

    def drop(self, fd):
        dev, _pad, _bat = self.devices.pop(fd)
        self.seen.discard(dev.path)
        try:
            dev.close()
        except OSError:
            pass
        # A direction held on the pad that just went away would otherwise repeat for ever.
        self.release_held()
        self.report()

    def release_held(self):
        if self.held:
            emit({"t": "release", "b": self.held[0]})
            self.held = None

    def _grab(self, dev, on):
        try:
            dev.grab() if on else dev.ungrab()
        except OSError:
            pass

    def set_exclusive(self, on):
        if on == self.exclusive:
            return
        self.exclusive = on
        for dev, _pad, _bat in self.devices.values():
            self._grab(dev, on)

    def _open_virtual(self, dev):
        if dev.fd in self.virtual:
            return
        try:
            self.virtual[dev.fd] = evdev.UInput.from_device(dev, name=dev.name)
        except OSError:
            pass

    def _close_virtual(self):
        for ui in self.virtual.values():
            try:
                ui.close()
            except OSError:
                pass
        self.virtual.clear()

    def apply_word(self, word):
        if word == "pause":
            self.relay = False
            self._close_virtual()
            self.exclusive = False
            self.set_paused(True)
            return
        if word not in ("resume", "grab", "ungrab", "relay"):
            return
        self.set_paused(False)
        if word != "relay":
            self.relay = False
            self._close_virtual()
        self.set_exclusive(word in ("grab", "relay"))
        if word == "relay":
            self.relay = True
            for dev, _pad, _bat in self.devices.values():
                self._grab(dev, True)
                self._open_virtual(dev)

    def set_paused(self, paused):
        if paused == self.paused:
            return
        self.paused = paused
        if paused:
            self.release_held()
            for dev, _pad, _bat in self.devices.values():
                dev.close()
            self.devices.clear()
            self.seen.clear()
        else:
            self.scan()

    def handle(self, name, pressed):
        emit({"t": "press" if pressed else "release", "b": name})
        if name in ("up", "down", "left", "right"):
            if pressed:
                self.held = (name, time.monotonic() + REPEAT_FIRST)
            elif self.held and self.held[0] == name:
                self.held = None

    def read_fd(self, fd):
        dev, pad, _bat = self.devices[fd]
        try:
            for event in dev.read():
                if self.relay:
                    # Home stays with the shell. Everything else is handed to Steam.
                    if event.type == ec.EV_KEY and event.code == ec.BTN_MODE and event.value in (0, 1):
                        self.handle("home", event.value == 1)
                        continue
                    ui = self.virtual.get(fd)
                    if ui:
                        ui.write_event(event)
                    continue
                for name, pressed in pad.feed(event.type, event.code, event.value):
                    self.handle(name, pressed)
        except BlockingIOError:
            pass
        except OSError:
            ui = self.virtual.pop(fd, None)
            if ui:
                try:
                    ui.close()
                except OSError:
                    pass
            self.drop(fd)

    def run(self):
        self.scan()
        next_scan = time.monotonic() + SCAN_EVERY
        next_battery = time.monotonic() + BATTERY_EVERY
        stdin_open = True
        while True:
            now = time.monotonic()
            wait = next_scan - now
            if self.held:
                wait = min(wait, self.held[1] - now)
            watch = list(self.devices) + ([sys.stdin.fileno()] if stdin_open else [])
            ready, _, _ = select.select(watch, [], [], max(0, wait))
            for fd in ready:
                if fd == sys.stdin.fileno():
                    line = sys.stdin.readline()
                    if not line:
                        # The shell went away; a helper nobody reads has no reason to live.
                        return
                    word = line.strip()
                    self.apply_word(word)
                elif fd in self.devices:
                    self.read_fd(fd)
            now = time.monotonic()
            if self.held and now >= self.held[1]:
                emit({"t": "press", "b": self.held[0]})
                self.held = (self.held[0], now + REPEAT_NEXT)
            if now >= next_scan:
                next_scan = now + SCAN_EVERY
                if not self.paused:
                    self.scan()
            if now >= next_battery:
                next_battery = now + BATTERY_EVERY
                self.report()


def main():
    try:
        Reader("--allow-virtual" in sys.argv).run()
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
