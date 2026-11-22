//! sea-gamepad — controller reader for sea-shell. Protocol matches `sea-gamepad.py`.

use evdev::uinput::VirtualDevice;
use evdev::{
    AbsoluteAxisCode, AbsInfo, AttributeSet, BusType, Device, EventType, InputEvent, KeyCode,
    UinputAbsSetup,
};
use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::fd::{AsRawFd, BorrowedFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const STICK_ON: f64 = 0.65;
const STICK_OFF: f64 = 0.45;
const REPEAT_FIRST: f64 = 0.38;
const REPEAT_NEXT: f64 = 0.11;
const SCAN_EVERY: f64 = 2.0;
const BATTERY_EVERY: f64 = 30.0;

fn emit(v: serde_json::Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

fn button_name(code: u16) -> Option<&'static str> {
    Some(match code {
        c if c == KeyCode::BTN_SOUTH.0 => "a",
        c if c == KeyCode::BTN_EAST.0 => "b",
        307 => "x",
        308 => "y",
        c if c == KeyCode::BTN_TL.0 => "l",
        c if c == KeyCode::BTN_TR.0 => "r",
        c if c == KeyCode::BTN_START.0 => "menu",
        c if c == KeyCode::BTN_SELECT.0 => "view",
        c if c == KeyCode::BTN_MODE.0 => "home",
        c if c == KeyCode::BTN_DPAD_UP.0 => "up",
        c if c == KeyCode::BTN_DPAD_DOWN.0 => "down",
        c if c == KeyCode::BTN_DPAD_LEFT.0 => "left",
        c if c == KeyCode::BTN_DPAD_RIGHT.0 => "right",
        _ => return None,
    })
}

struct Pad {
    stick_range: HashMap<u16, (i32, i32)>,
    hat: (i32, i32),
    stick: (f64, f64),
    stick_dir: Option<&'static str>,
    hat_dir: Option<&'static str>,
}

impl Pad {
    fn new(stick_range: HashMap<u16, (i32, i32)>) -> Self {
        Self {
            stick_range,
            hat: (0, 0),
            stick: (0.0, 0.0),
            stick_dir: None,
            hat_dir: None,
        }
    }

    fn norm(&self, code: u16, value: i32) -> f64 {
        let (low, high) = self.stick_range.get(&code).copied().unwrap_or((-32768, 32767));
        if high <= low {
            return 0.0;
        }
        (f64::from(value - low) / f64::from(high - low)) * 2.0 - 1.0
    }

    fn stick_direction(&self) -> Option<&'static str> {
        let (x, y) = self.stick;
        let size = x.abs().max(y.abs());
        let thr = if self.stick_dir.is_some() { STICK_OFF } else { STICK_ON };
        if size < thr {
            return None;
        }
        if x.abs() >= y.abs() {
            Some(if x > 0.0 { "right" } else { "left" })
        } else {
            Some(if y > 0.0 { "down" } else { "up" })
        }
    }

    fn hat_direction(&self) -> Option<&'static str> {
        let (x, y) = self.hat;
        if y != 0 {
            Some(if y > 0 { "down" } else { "up" })
        } else if x != 0 {
            Some(if x > 0 { "right" } else { "left" })
        } else {
            None
        }
    }

    fn update_dir(
        out: &mut Vec<(&'static str, bool)>,
        slot: &mut Option<&'static str>,
        now: Option<&'static str>,
    ) {
        if now != *slot {
            if let Some(old) = *slot {
                out.push((old, false));
            }
            if let Some(n) = now {
                out.push((n, true));
            }
            *slot = now;
        }
    }

    fn feed(&mut self, etype: EventType, code: u16, value: i32) -> Vec<(&'static str, bool)> {
        let mut out = Vec::new();
        if etype == EventType::KEY {
            if let Some(name) = button_name(code) {
                if value == 0 || value == 1 {
                    out.push((name, value == 1));
                }
            }
        } else if etype == EventType::ABSOLUTE {
            if code == AbsoluteAxisCode::ABS_HAT0X.0 {
                self.hat.0 = value;
                let now = self.hat_direction();
                Self::update_dir(&mut out, &mut self.hat_dir, now);
            } else if code == AbsoluteAxisCode::ABS_HAT0Y.0 {
                self.hat.1 = value;
                let now = self.hat_direction();
                Self::update_dir(&mut out, &mut self.hat_dir, now);
            } else if code == AbsoluteAxisCode::ABS_X.0 || code == AbsoluteAxisCode::ABS_Y.0 {
                if code == AbsoluteAxisCode::ABS_X.0 {
                    self.stick.0 = self.norm(code, value);
                } else {
                    self.stick.1 = self.norm(code, value);
                }
                let now = self.stick_direction();
                Self::update_dir(&mut out, &mut self.stick_dir, now);
            }
        }
        out
    }
}

fn event_sysfs(path: &Path) -> PathBuf {
    let base = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    fs::canonicalize(format!("/sys/class/input/{base}")).unwrap_or_default()
}

fn is_virtual_event(path: &Path) -> bool {
    event_sysfs(path)
        .to_string_lossy()
        .contains("/devices/virtual/")
}

fn is_pad_dev(dev: &Device, path: &Path, allow_virtual: bool) -> bool {
    let Some(keys) = dev.supported_keys() else {
        return false;
    };
    if !keys.contains(KeyCode::BTN_SOUTH) {
        return false;
    }
    let Some(axes) = dev.supported_absolute_axes() else {
        return false;
    };
    if !axes.contains(AbsoluteAxisCode::ABS_X) && !axes.contains(AbsoluteAxisCode::ABS_HAT0X) {
        return false;
    }
    allow_virtual || !is_virtual_event(path)
}

fn battery_dir(path: &Path) -> Option<PathBuf> {
    let mut here = event_sysfs(path);
    for _ in 0..6 {
        let ps = here.join("power_supply");
        if ps.is_dir() {
            if let Ok(rd) = fs::read_dir(&ps) {
                let mut names: Vec<_> = rd.filter_map(|e| e.ok()).map(|e| e.path()).collect();
                names.sort();
                return names.into_iter().next();
            }
        }
        here = here.parent()?.to_path_buf();
    }
    None
}

fn read_battery(path: Option<&Path>) -> Option<serde_json::Value> {
    let path = path?;
    let read = |name: &str| -> String {
        fs::read_to_string(path.join(name))
            .map(|s| s.trim().to_owned())
            .unwrap_or_default()
    };
    let pct = read("capacity");
    let value = if !pct.is_empty() && pct.chars().all(|c| c.is_ascii_digit()) {
        pct.parse::<i64>().ok()
    } else {
        match read("capacity_level").as_str() {
            "Full" => Some(100),
            "High" => Some(75),
            "Normal" => Some(50),
            "Low" => Some(20),
            "Critical" => Some(5),
            _ => None,
        }
    }?;
    let status = read("status");
    Some(json!({
        "pct": value,
        "status": if status.is_empty() { "Unknown".into() } else { status },
    }))
}

fn make_virtual(dev: &Device) -> io::Result<VirtualDevice> {
    let name = dev.name().unwrap_or("sea-gamepad-relay");
    let mut builder = VirtualDevice::builder()?
        .name(name)
        .input_id(dev.input_id());
    if let Some(keys) = dev.supported_keys() {
        builder = builder.with_keys(keys)?;
    }
    if let Ok(abs) = dev.get_absinfo() {
        for (code, info) in abs {
            let setup = UinputAbsSetup::new(code, info);
            builder = builder.with_absolute_axis(&setup)?;
        }
    }
    builder.build()
}

struct Slot {
    pad: Pad,
    battery: Option<PathBuf>,
    path: PathBuf,
}

struct Reader {
    allow_virtual: bool,
    devices: HashMap<RawFd, (Device, Slot)>,
    seen: HashSet<PathBuf>,
    paused: bool,
    exclusive: bool,
    relay: bool,
    virtuals: HashMap<RawFd, VirtualDevice>,
    held: Option<(&'static str, Instant)>,
    last_pads: Option<String>,
}

impl Reader {
    fn new(allow_virtual: bool) -> Self {
        Self {
            allow_virtual,
            devices: HashMap::new(),
            seen: HashSet::new(),
            paused: false,
            exclusive: false,
            relay: false,
            virtuals: HashMap::new(),
            held: None,
            last_pads: None,
        }
    }

    fn scan(&mut self) {
        let Ok(rd) = fs::read_dir("/dev/input") else {
            return;
        };
        let paths: HashSet<PathBuf> = rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("event"))
            })
            .collect();
        self.seen.retain(|p| paths.contains(p));
        let mut newcomers: Vec<_> = paths.difference(&self.seen).cloned().collect();
        newcomers.sort();
        for path in newcomers {
            self.seen.insert(path.clone());
            let Ok(mut dev) = Device::open(&path) else {
                continue;
            };
            if !is_pad_dev(&dev, &path, self.allow_virtual) {
                continue;
            }
            let mut ranges = HashMap::new();
            if let Ok(abs) = dev.get_absinfo() {
                for (code, info) in abs {
                    ranges.insert(code.0, (info.minimum(), info.maximum()));
                }
            }
            let bat = battery_dir(&path);
            let _ = dev.set_nonblocking(true);
            if self.exclusive || self.relay {
                let _ = dev.grab();
            }
            let fd = dev.as_raw_fd();
            if self.relay {
                if let Ok(ui) = make_virtual(&dev) {
                    self.virtuals.insert(fd, ui);
                }
            }
            self.devices.insert(
                fd,
                (
                    dev,
                    Slot {
                        pad: Pad::new(ranges),
                        battery: bat,
                        path,
                    },
                ),
            );
        }
        if self.exclusive || self.relay {
            for (dev, _) in self.devices.values_mut() {
                let _ = dev.grab();
            }
        }
        self.report();
    }

    fn report(&mut self) {
        let mut pads = Vec::new();
        for (dev, slot) in self.devices.values() {
            let bus = match dev.input_id().bus_type() {
                BusType::BUS_USB => "usb",
                BusType::BUS_BLUETOOTH => "bluetooth",
                _ => "other",
            };
            pads.push(json!({
                "name": dev.name().unwrap_or(""),
                "bus": bus,
                "battery": read_battery(slot.battery.as_deref()),
            }));
        }
        let s = serde_json::to_string(&pads).unwrap_or_default();
        if self.last_pads.as_deref() != Some(s.as_str()) {
            self.last_pads = Some(s);
            emit(json!({"t": "pads", "pads": pads}));
        }
    }

    fn drop_fd(&mut self, fd: RawFd) {
        if let Some((_dev, slot)) = self.devices.remove(&fd) {
            self.seen.remove(&slot.path);
        }
        self.virtuals.remove(&fd);
        self.release_held();
        self.report();
    }

    fn release_held(&mut self) {
        if let Some((name, _)) = self.held.take() {
            emit(json!({"t": "release", "b": name}));
        }
    }

    fn set_exclusive(&mut self, on: bool) {
        if on == self.exclusive {
            return;
        }
        self.exclusive = on;
        for (dev, _) in self.devices.values_mut() {
            if on {
                let _ = dev.grab();
            } else {
                let _ = dev.ungrab();
            }
        }
    }

    fn open_virtual(&mut self, fd: RawFd) {
        if self.virtuals.contains_key(&fd) {
            return;
        }
        if let Some((dev, _)) = self.devices.get(&fd) {
            if let Ok(ui) = make_virtual(dev) {
                self.virtuals.insert(fd, ui);
            }
        }
    }

    fn close_virtual(&mut self) {
        self.virtuals.clear();
    }

    fn set_paused(&mut self, paused: bool) {
        if paused == self.paused {
            return;
        }
        self.paused = paused;
        if paused {
            self.release_held();
            self.devices.clear();
            self.seen.clear();
            self.close_virtual();
        } else {
            self.scan();
        }
    }

    fn apply_word(&mut self, word: &str) {
        match word {
            "pause" => {
                self.relay = false;
                self.close_virtual();
                self.exclusive = false;
                self.set_paused(true);
            }
            "resume" | "grab" | "ungrab" | "relay" => {
                self.set_paused(false);
                if word != "relay" {
                    self.relay = false;
                    self.close_virtual();
                }
                self.set_exclusive(matches!(word, "grab" | "relay"));
                if word == "relay" {
                    self.relay = true;
                    let fds: Vec<_> = self.devices.keys().copied().collect();
                    for fd in fds {
                        if let Some((dev, _)) = self.devices.get_mut(&fd) {
                            let _ = dev.grab();
                        }
                        self.open_virtual(fd);
                    }
                }
            }
            _ => {}
        }
    }

    fn handle(&mut self, name: &'static str, pressed: bool) {
        emit(json!({"t": if pressed { "press" } else { "release" }, "b": name}));
        if matches!(name, "up" | "down" | "left" | "right") {
            if pressed {
                self.held = Some((
                    name,
                    Instant::now() + Duration::from_secs_f64(REPEAT_FIRST),
                ));
            } else if self.held.map(|(n, _)| n) == Some(name) {
                self.held = None;
            }
        }
    }

    fn read_fd(&mut self, fd: RawFd) {
        let relay = self.relay;
        let fetched = {
            let Some((dev, _)) = self.devices.get_mut(&fd) else {
                return;
            };
            match dev.fetch_events() {
                Ok(iter) => Ok(iter.collect::<Vec<_>>()),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(_) => Err(()),
            }
        };
        let Ok(events) = fetched else {
            self.drop_fd(fd);
            return;
        };
        for ev in events {
            if relay {
                if ev.event_type() == EventType::KEY
                    && ev.code() == KeyCode::BTN_MODE.0
                    && (ev.value() == 0 || ev.value() == 1)
                {
                    self.handle("home", ev.value() == 1);
                    continue;
                }
                if let Some(ui) = self.virtuals.get_mut(&fd) {
                    let _ = ui.emit(&[ev]);
                }
                continue;
            }
            let Some((_, slot)) = self.devices.get_mut(&fd) else {
                return;
            };
            let changes = slot.pad.feed(ev.event_type(), ev.code(), ev.value());
            for (name, pressed) in changes {
                self.handle(name, pressed);
            }
        }
    }

    fn run(&mut self) {
        self.scan();
        let mut next_scan = Instant::now() + Duration::from_secs_f64(SCAN_EVERY);
        let mut next_battery = Instant::now() + Duration::from_secs_f64(BATTERY_EVERY);
        let stdin = io::stdin();
        let mut stdin_lock = stdin.lock();
        let mut line = String::new();
        let stdin_fd = io::stdin().as_raw_fd();

        loop {
            let now = Instant::now();
            let mut wait_ms = ((next_scan.saturating_duration_since(now)).as_secs_f64() * 1000.0)
                .clamp(0.0, 2000.0) as u16;
            if let Some((_, when)) = self.held {
                let w = (when.saturating_duration_since(now).as_secs_f64() * 1000.0)
                    .clamp(0.0, 2000.0) as u16;
                wait_ms = wait_ms.min(w);
            }

            let device_fds: Vec<RawFd> = self.devices.keys().copied().collect();
            let mut poll_fds: Vec<PollFd> = Vec::with_capacity(device_fds.len() + 1);
            for &fd in &device_fds {
                let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
                poll_fds.push(PollFd::new(borrowed, PollFlags::POLLIN));
            }
            let stdin_borrowed = unsafe { BorrowedFd::borrow_raw(stdin_fd) };
            poll_fds.push(PollFd::new(stdin_borrowed, PollFlags::POLLIN));

            let _ = poll(&mut poll_fds, PollTimeout::from(wait_ms));

            if let Some(revents) = poll_fds.last().and_then(|p| p.revents()) {
                if revents.contains(PollFlags::POLLIN) {
                    line.clear();
                    match stdin_lock.read_line(&mut line) {
                        Ok(0) => return,
                        Ok(_) => self.apply_word(line.trim()),
                        Err(_) => return,
                    }
                }
            }

            for (i, &fd) in device_fds.iter().enumerate() {
                if let Some(revents) = poll_fds.get(i).and_then(|p| p.revents()) {
                    if revents.intersects(PollFlags::POLLIN | PollFlags::POLLERR | PollFlags::POLLHUP)
                    {
                        self.read_fd(fd);
                    }
                }
            }

            let now = Instant::now();
            if let Some((name, when)) = self.held {
                if now >= when {
                    emit(json!({"t": "press", "b": name}));
                    self.held = Some((name, now + Duration::from_secs_f64(REPEAT_NEXT)));
                }
            }
            if now >= next_scan {
                next_scan = now + Duration::from_secs_f64(SCAN_EVERY);
                if !self.paused {
                    self.scan();
                }
            }
            if now >= next_battery {
                next_battery = now + Duration::from_secs_f64(BATTERY_EVERY);
                self.report();
            }
        }
    }
}

fn main() {
    let _ = AttributeSet::<KeyCode>::new(); // keep AttributeSet in scope for type inference helpers
    let _ = AbsInfo::new(0, -32768, 32767, 0, 0, 0);
    let _ = InputEvent::new(EventType::SYNCHRONIZATION.0, 0, 0);

    let allow_virtual = env::args().any(|a| a == "--allow-virtual");
    Reader::new(allow_virtual).run();
}
