//! sea-fand — Acer fan curve. Protocol and numbers match `sea-fand.py`.
//!
//!     sea-fand            follow the preset in /var/lib/sea-fan/mode
//!     sea-fand --release  hand the fans back to the firmware and exit

use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

const MODE_FILE: &str = "/var/lib/sea-fan/mode";
const TICK: f64 = 2.0;
const DEFAULT_MODE: &str = "auto";
const RISE_TAU: f64 = 20.0;
const FALL_TAU: f64 = 30.0;
const RAMP_UP: f64 = 80.0;
const RAMP_DOWN: f64 = 15.0;
const DEADBAND: f64 = 120.0;
const HOLD_S: f64 = 45.0;
const HOLD_SHARE: f64 = 0.5;
const EC_JUMP: f64 = 250.0;
const EC_LAG: f64 = 10.0;
const MIN_PCT: f64 = 10.0;
const MAX_PCT: f64 = 100.0;
const BOOST_FILE: &str = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
const BOOST_QUIET: i32 = 60;

const QUIET: &[(f64, f64)] = &[(60.0, 2200.0), (80.0, 3000.0), (92.0, 4200.0), (96.0, 4500.0), (99.0, 7000.0)];
const AUTO: &[(f64, f64)] = &[
    (50.0, 2400.0),
    (65.0, 3000.0),
    (75.0, 3600.0),
    (85.0, 4200.0),
    (92.0, 5200.0),
    (96.0, 6500.0),
    (99.0, 8000.0),
];
const MAX: &[(f64, f64)] = &[(50.0, 5500.0), (75.0, 6500.0), (88.0, 8000.0)];
const SEED: &[(f64, f64)] = &[
    (0.0, 5.0),
    (2500.0, 8.0),
    (3850.0, 20.0),
    (4900.0, 32.0),
    (5400.0, 42.0),
    (5750.0, 45.0),
    (6100.0, 55.0),
    (8000.0, 100.0),
];

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_stop(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}

fn curve(mode: &str) -> &'static [(f64, f64)] {
    match mode {
        "quiet" => QUIET,
        "max" => MAX,
        _ => AUTO,
    }
}

fn lerp(points: &[(f64, f64)], x: f64) -> f64 {
    if x <= points[0].0 {
        return points[0].1;
    }
    for w in points.windows(2) {
        let (x0, y0) = w[0];
        let (x1, y1) = w[1];
        if x <= x1 {
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        }
    }
    points[points.len() - 1].1
}

fn read_int(path: &Path) -> io::Result<i64> {
    let s = fs::read_to_string(path)?;
    s.trim().parse().map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn write_val(path: &Path, value: impl std::fmt::Display) -> io::Result<()> {
    let mut f = fs::File::create(path)?;
    write!(f, "{value}")
}

fn find_hwmon(name: &str) -> Option<PathBuf> {
    let dir = fs::read_dir("/sys/class/hwmon").ok()?;
    for ent in dir.flatten() {
        let path = ent.path();
        if fs::read_to_string(path.join("name")).ok().map(|s| s.trim() == name).unwrap_or(false) {
            return Some(path);
        }
    }
    None
}

fn fan_ids(hwmon: &Path) -> Vec<String> {
    let mut ids = Vec::new();
    let Ok(dir) = fs::read_dir(hwmon) else { return ids };
    for ent in dir.flatten() {
        let name = ent.file_name();
        let name = name.to_string_lossy();
        let Some(rest) = name.strip_prefix("fan") else { continue };
        let Some(id) = rest.strip_suffix("_input") else { continue };
        if hwmon.join(format!("pwm{id}")).exists() {
            ids.push(id.to_string());
        }
    }
    ids.sort();
    ids
}

fn set_boost(pct: i32, path: &Path) {
    if path.exists() {
        let _ = write_val(path, pct);
    }
}

fn release(hwmon: &Path, boost_file: &Path) {
    for n in fan_ids(hwmon) {
        let _ = write_val(&hwmon.join(format!("pwm{n}_enable")), 2);
    }
    set_boost(100, boost_file);
}

struct Controller {
    hwmon: PathBuf,
    cpu_temp: PathBuf,
    mode_file: PathBuf,
    boost_file: PathBuf,
    boost: Option<i32>,
    fans: Vec<String>,
    temp: f64,
    target: f64,
    pct: HashMap<String, f64>,
    floor: HashMap<String, f64>,
    last_rpm: HashMap<String, f64>,
    raised_at: HashMap<String, f64>,
    clock: f64,
    hold_until: f64,
}

impl Controller {
    fn new(hwmon: PathBuf, cpu_temp: PathBuf, mode_file: PathBuf, boost_file: PathBuf) -> io::Result<Self> {
        let fans = fan_ids(&hwmon);
        if fans.is_empty() {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no controllable fans"));
        }
        let mut ctl = Self {
            hwmon,
            cpu_temp,
            mode_file,
            boost_file,
            boost: None,
            fans,
            temp: 0.0,
            target: 0.0,
            pct: HashMap::new(),
            floor: HashMap::new(),
            last_rpm: HashMap::new(),
            raised_at: HashMap::new(),
            clock: 0.0,
            hold_until: 0.0,
        };
        ctl.temp = ctl.raw_temp();
        let rpms: Vec<f64> = ctl
            .fans
            .iter()
            .map(|n| read_int(&ctl.hwmon.join(format!("fan{n}_input"))).unwrap_or(0) as f64)
            .collect();
        ctl.target = rpms.iter().copied().fold(0.0, f64::max);
        for (n, r) in ctl.fans.iter().zip(rpms.iter()) {
            ctl.pct.insert(n.clone(), lerp(SEED, *r));
            ctl.floor.insert(n.clone(), MIN_PCT);
            ctl.last_rpm.insert(n.clone(), *r);
            ctl.raised_at.insert(n.clone(), -EC_LAG);
        }
        let fans = ctl.fans.clone();
        for n in &fans {
            ctl.apply(n)?;
            write_val(&ctl.hwmon.join(format!("pwm{n}_enable")), 1)?;
            ctl.apply(n)?;
        }
        Ok(ctl)
    }

    fn raw_temp(&self) -> f64 {
        let mut temps = vec![read_int(&self.cpu_temp).unwrap_or(0)];
        let gpu = self.hwmon.join("temp2_input");
        if gpu.exists() {
            if let Ok(v) = read_int(&gpu) {
                temps.push(v);
            }
        }
        *temps.iter().max().unwrap_or(&0) as f64 / 1000.0
    }

    fn mode(&self) -> String {
        match fs::read_to_string(&self.mode_file) {
            Ok(s) => {
                let m = s.trim();
                if m == "quiet" || m == "auto" || m == "max" { m.to_string() } else { DEFAULT_MODE.into() }
            }
            Err(_) => DEFAULT_MODE.into(),
        }
    }

    fn apply(&self, n: &str) -> io::Result<()> {
        let pct = self.pct[n];
        let pwm = ((pct * 2.55 + 0.999) as i64).clamp(0, 255);
        write_val(&self.hwmon.join(format!("pwm{n}")), pwm)
    }

    fn step(&mut self, dt: f64) -> io::Result<()> {
        self.clock += dt;
        let raw = self.raw_temp();
        let tau = if raw > self.temp { RISE_TAU } else { FALL_TAU };
        self.temp += (raw - self.temp) * (dt / tau).min(1.0);

        let mode = self.mode();
        let boost = if mode == "quiet" { BOOST_QUIET } else { 100 };
        if self.boost != Some(boost) {
            set_boost(boost, &self.boost_file);
            self.boost = Some(boost);
        }

        let mut rpms = HashMap::new();
        for n in &self.fans {
            if read_int(&self.hwmon.join(format!("pwm{n}_enable"))).unwrap_or(0) != 1 {
                self.apply(n)?;
                write_val(&self.hwmon.join(format!("pwm{n}_enable")), 1)?;
            }
            rpms.insert(n.clone(), read_int(&self.hwmon.join(format!("fan{n}_input"))).unwrap_or(0) as f64);
        }

        let mut jumped = Vec::new();
        for n in &self.fans {
            let rpm = rpms[n];
            if rpm - self.last_rpm[n] >= EC_JUMP
                && self.clock - self.raised_at[n] > EC_LAG
                && rpm > self.target + DEADBAND
            {
                jumped.push(rpm);
            }
        }
        self.last_rpm = rpms.clone();
        let want = lerp(curve(&mode), self.temp);
        if !jumped.is_empty() {
            let peak = jumped.into_iter().fold(0.0, f64::max);
            let held = want + HOLD_SHARE * (peak - want);
            if held > self.target {
                self.target = held;
                self.hold_until = self.clock + HOLD_S;
                for n in self.fans.clone() {
                    let seed = lerp(SEED, self.target);
                    if seed > self.pct[&n] {
                        self.pct.insert(n.clone(), seed.min(MAX_PCT));
                        self.raised_at.insert(n.clone(), self.clock);
                        self.apply(&n)?;
                    }
                }
            }
        }

        if want > self.target {
            self.target = want.min(self.target + RAMP_UP * dt);
        } else if self.clock >= self.hold_until {
            let rate = if self.target - want < 1500.0 { RAMP_DOWN } else { RAMP_DOWN * 4.0 };
            self.target = want.max(self.target - rate * dt);
        }

        for n in self.fans.clone() {
            let rpm = rpms[&n];
            if rpm == 0.0 && self.target > 0.0 {
                let floor = self.floor[&n].max(self.pct[&n] + 5.0).min(MAX_PCT);
                self.floor.insert(n.clone(), floor);
            }
            let err = self.target - rpm;
            if err.abs() <= DEADBAND {
                continue;
            }
            if err < 0.0 && self.clock < self.hold_until {
                continue;
            }
            let move_by = if err > 0.0 { (1 + (err.abs() as i64) / 300).min(3) } else { 1 };
            let mut pct = self.pct[&n] + if err > 0.0 { move_by as f64 } else { -(move_by as f64) };
            pct = pct.clamp(self.floor[&n], MAX_PCT);
            if pct != self.pct[&n] {
                if pct > self.pct[&n] {
                    self.raised_at.insert(n.clone(), self.clock);
                }
                self.pct.insert(n.clone(), pct);
                self.apply(&n)?;
            }
        }
        Ok(())
    }
}

fn notify(msg: &str) {
    let Ok(addr) = env::var("NOTIFY_SOCKET") else { return };
    let mut sun_path = [0u8; 108];
    let path_len = if let Some(rest) = addr.strip_prefix('@') {
        let b = rest.as_bytes();
        let n = b.len().min(107);
        sun_path[1..1 + n].copy_from_slice(&b[..n]);
        1 + n
    } else {
        let b = std::ffi::OsStr::new(&addr).as_bytes();
        let n = b.len().min(107);
        sun_path[..n].copy_from_slice(&b[..n]);
        n + 1
    };
    unsafe {
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0);
        if fd < 0 {
            return;
        }
        let mut sa: libc::sockaddr_un = std::mem::zeroed();
        sa.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let dst = sa.sun_path.as_mut_ptr() as *mut u8;
        std::ptr::copy_nonoverlapping(sun_path.as_ptr(), dst, path_len);
        let len = (std::mem::size_of::<libc::sa_family_t>() + path_len) as libc::socklen_t;
        libc::sendto(
            fd,
            msg.as_ptr() as *const libc::c_void,
            msg.len(),
            0,
            &sa as *const _ as *const libc::sockaddr,
            len,
        );
        libc::close(fd);
    }
}

fn arm_signals() {
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = on_stop as *const () as usize;
        libc::sigaction(libc::SIGTERM, &sa, std::ptr::null_mut());
        libc::sigaction(libc::SIGINT, &sa, std::ptr::null_mut());
    }
}

fn main() {
    let hwmon = match find_hwmon("acer") {
        Some(p) => p,
        None => {
            eprintln!("sea-fand: no acer hwmon device");
            std::process::exit(1);
        }
    };
    if env::args().any(|a| a == "--release") {
        release(&hwmon, Path::new(BOOST_FILE));
        return;
    }
    let cpu_temp = find_hwmon("coretemp")
        .map(|p| p.join("temp1_input"))
        .unwrap_or_else(|| hwmon.join("temp1_input"));

    arm_signals();
    let ctl = Controller::new(hwmon.clone(), cpu_temp, PathBuf::from(MODE_FILE), PathBuf::from(BOOST_FILE));
    let mut ctl = match ctl {
        Ok(c) => c,
        Err(e) => {
            eprintln!("sea-fand: {e}");
            std::process::exit(1);
        }
    };
    notify("READY=1");
    let mut last = Instant::now();
    let result = loop {
        if STOP.load(Ordering::Relaxed) {
            break Ok(());
        }
        thread::sleep(Duration::from_secs_f64(TICK));
        if STOP.load(Ordering::Relaxed) {
            break Ok(());
        }
        let now = Instant::now();
        let dt = now.duration_since(last).as_secs_f64().min(TICK * 3.0);
        last = now;
        if let Err(e) = ctl.step(dt) {
            break Err(e);
        }
        notify("WATCHDOG=1");
    };
    release(&hwmon, Path::new(BOOST_FILE));
    if let Err(e) = result {
        eprintln!("sea-fand: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curves_climb_and_quiet_stays_slower() {
        assert!(lerp(QUIET, 70.0) < lerp(AUTO, 70.0));
        assert!(lerp(AUTO, 70.0) < lerp(MAX, 70.0));
        assert_eq!(lerp(QUIET, 0.0), 2200.0);
        assert_eq!(lerp(AUTO, 200.0), 8000.0);
    }

    #[test]
    fn step_ramps_toward_the_curve() {
        let dir = std::env::temp_dir().join(format!("sea-fand-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("fan1_input"), "2400\n").unwrap();
        fs::write(dir.join("pwm1"), "0\n").unwrap();
        fs::write(dir.join("pwm1_enable"), "2\n").unwrap();
        fs::write(dir.join("temp1_input"), "90000\n").unwrap();
        let mode = dir.join("mode");
        fs::write(&mode, "auto\n").unwrap();
        let boost = dir.join("boost");
        fs::write(&boost, "100\n").unwrap();
        let mut ctl = Controller::new(dir.clone(), dir.join("temp1_input"), mode, boost).unwrap();
        let start = ctl.target;
        ctl.step(TICK).unwrap();
        assert!(ctl.target > start);
        assert!(ctl.target - start <= RAMP_UP * TICK + 1.0);
        let _ = fs::remove_dir_all(&dir);
    }
}
