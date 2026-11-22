//! sea-panel — turn the laptop's own screen off when an external display takes over.
//! Behaviour matches `quickshell/scripts/system/sea-panel.py`.

use fs2::FileExt;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

const DEFAULTS: &[(&str, bool)] = &[("external_only", false), ("lid_off", true)];
const INTERNAL: &[&str] = &["eDP", "LVDS", "DSI"];

fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn cfg_path() -> PathBuf {
    home().join(".config/sea-shell/laptop-panel.json")
}

fn persist_path() -> PathBuf {
    home().join(".config/sea-shell/display-persist.json")
}

fn runtime_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn state_path() -> PathBuf {
    runtime_dir().join("sea-panel-off.json")
}

fn lock_path() -> PathBuf {
    runtime_dir().join("sea-panel.lock")
}

fn hypr(args: &[&str]) -> String {
    Command::new("hyprctl")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default()
}

fn load_json(path: &Path, default: Value) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(default)
}

fn atomic_write(path: &Path, text: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = PathBuf::from(format!("{}.tmp", path.display()));
    {
        let mut f = File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
    }
    fs::rename(tmp, path)?;
    Ok(())
}

fn load_cfg() -> serde_json::Map<String, Value> {
    let mut cfg = serde_json::Map::new();
    for (k, v) in DEFAULTS {
        cfg.insert((*k).into(), Value::Bool(*v));
    }
    if let Value::Object(obj) = load_json(&cfg_path(), Value::Object(serde_json::Map::new())) {
        for (k, _) in DEFAULTS {
            if let Some(Value::Bool(b)) = obj.get(*k) {
                cfg.insert((*k).into(), Value::Bool(*b));
            } else if let Some(v) = obj.get(*k) {
                // accept 0/1 as well
                cfg.insert(
                    (*k).into(),
                    Value::Bool(match v {
                        Value::Number(n) => n.as_i64().unwrap_or(0) != 0,
                        Value::String(s) => matches!(s.as_str(), "1" | "true" | "on"),
                        _ => false,
                    }),
                );
            }
        }
    }
    cfg
}

fn save_cfg(cfg: &serde_json::Map<String, Value>) {
    let _ = atomic_write(
        &cfg_path(),
        &serde_json::to_string_pretty(&Value::Object(cfg.clone())).unwrap_or_else(|_| "{}".into()),
    );
}

fn lid_closed() -> bool {
    let Ok(entries) = fs::read_dir("/proc/acpi/button/lid") else {
        return false;
    };
    for ent in entries.flatten() {
        let state = ent.path().join("state");
        if let Ok(s) = fs::read_to_string(&state) {
            if s.contains("closed") {
                return true;
            }
        }
    }
    false
}

fn lid_present() -> bool {
    fs::read_dir("/proc/acpi/button/lid")
        .map(|it| it.filter_map(Result::ok).next().is_some())
        .unwrap_or(false)
}

fn monitors() -> Vec<Value> {
    let raw = hypr(&["monitors", "all", "-j"]);
    serde_json::from_str::<Value>(raw.trim())
        .ok()
        .and_then(|v| match v {
            Value::Array(a) => Some(a),
            _ => None,
        })
        .unwrap_or_default()
}

fn is_internal(m: &Value) -> bool {
    m.get("name")
        .and_then(|n| n.as_str())
        .map(|n| INTERNAL.iter().any(|p| n.starts_with(p)))
        .unwrap_or(false)
}

fn disabled(m: &Value) -> bool {
    m.get("disabled").and_then(|d| d.as_bool()).unwrap_or(false)
}

fn enable(m: &Value) {
    let name = match m.get("name").and_then(|n| n.as_str()) {
        Some(n) => n,
        None => return,
    };
    let desc = m
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("")
        .trim();
    let persist = load_json(&persist_path(), json!({}));
    let saved = persist.get(desc).cloned().unwrap_or(Value::Null);

    let (mode, pos, scale) = if let Some(obj) = saved.as_object() {
        if obj.get("w").and_then(|w| w.as_u64()).unwrap_or(0) > 0 {
            let w = obj.get("w").and_then(|v| v.as_u64()).unwrap_or(0);
            let h = obj.get("h").and_then(|v| v.as_u64()).unwrap_or(0);
            let rate = obj
                .get("rate")
                .map(|v| match v {
                    Value::Number(n) => n.to_string(),
                    Value::String(s) => s.clone(),
                    _ => "60".into(),
                })
                .unwrap_or_else(|| "60".into());
            let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0);
            let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0);
            let scale = obj
                .get("scale")
                .map(|v| match v {
                    Value::Number(n) => n.to_string(),
                    Value::String(s) => s.clone(),
                    _ => "1".into(),
                })
                .unwrap_or_else(|| "1".into());
            (
                format!("{w}x{h}@{rate}"),
                format!("{x}x{y}"),
                scale,
            )
        } else {
            ("preferred".into(), "auto".into(), "1".into())
        }
    } else {
        ("preferred".into(), "auto".into(), "1".into())
    };

    let expr = format!(
        "hl.monitor({{ output = \"{name}\", mode = \"{mode}\", position = \"{pos}\", scale = {scale}, disabled = false }})"
    );
    hypr(&["eval", &expr]);
}

fn sync() {
    let cfg = load_cfg();
    let mons = monitors();
    if mons.is_empty() {
        return;
    }
    let external_on = mons
        .iter()
        .any(|m| !is_internal(m) && !disabled(m));
    let want_off = external_on
        && (cfg.get("external_only").and_then(|v| v.as_bool()).unwrap_or(false)
            || (cfg.get("lid_off").and_then(|v| v.as_bool()).unwrap_or(true) && lid_closed()));

    let mut ours: BTreeSet<String> = match load_json(&state_path(), json!([])) {
        Value::Array(a) => a
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        _ => BTreeSet::new(),
    };
    let nothing_on = !mons.iter().any(|m| !disabled(m));

    for m in &mons {
        if !is_internal(m) {
            continue;
        }
        let Some(name) = m.get("name").and_then(|n| n.as_str()).map(str::to_owned) else {
            continue;
        };
        if want_off && !disabled(m) {
            let expr = format!("hl.monitor({{ output = \"{name}\", disabled = true }})");
            hypr(&["eval", &expr]);
            ours.insert(name);
        } else if !want_off && disabled(m) && (ours.contains(&name) || nothing_on) {
            enable(m);
            ours.remove(&name);
        } else if !disabled(m) {
            ours.remove(&name);
        }
    }

    let list: Vec<String> = ours.into_iter().collect();
    let _ = atomic_write(
        &state_path(),
        &serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()),
    );
}

fn event_socket() -> Option<UnixStream> {
    let runtime = runtime_dir();
    let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
    let mut path = runtime.join("hypr").join(&sig).join(".socket2.sock");
    if sig.is_empty() || !path.exists() {
        let mut socks: Vec<PathBuf> = fs::read_dir(runtime.join("hypr"))
            .ok()?
            .filter_map(|e| e.ok())
            .map(|e| e.path().join(".socket2.sock"))
            .filter(|p| p.exists())
            .collect();
        socks.sort_by_key(|p| {
            fs::metadata(p)
                .and_then(|m| m.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH)
        });
        path = socks.pop()?;
    }
    UnixStream::connect(path).ok()
}

fn mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn watch() {
    let lock_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(lock_path());
    let Ok(lock_file) = lock_file else {
        return;
    };
    if lock_file.try_lock_exclusive().is_err() {
        return; // another watcher already runs
    }

    let Some(mut sock) = event_socket() else {
        return;
    };
    let _ = sock.set_nonblocking(true);
    sync();

    let mut lid = lid_closed();
    let mut cfg_m = mtime(&cfg_path());
    let mut buf = Vec::new();
    let mut due: Option<Instant> = None;
    let mut chunk = [0u8; 4096];

    loop {
        // 1s poll cadence matches Python select timeout
        thread::sleep(Duration::from_millis(200));
        match sock.read(&mut chunk) {
            Ok(0) => {
                let _ = sock.shutdown(Shutdown::Both);
                return; // compositor gone; the bar restarts us
            }
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                    let line = buf.drain(..=pos).collect::<Vec<_>>();
                    // events are "name>>payload"
                    let ev_name = {
                        let s = String::from_utf8_lossy(&line);
                        s.split(">>")
                            .next()
                            .unwrap_or("")
                            .trim()
                            .to_owned()
                    };
                    if matches!(
                        ev_name.as_str(),
                        "monitoradded"
                            | "monitoraddedv2"
                            | "monitorremoved"
                            | "monitorremovedv2"
                            | "configreloaded"
                    ) {
                        due = Some(Instant::now() + Duration::from_millis(600));
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => return,
        }

        let now_lid = lid_closed();
        let now_cfg = mtime(&cfg_path());
        if now_lid != lid || now_cfg != cfg_m {
            lid = now_lid;
            cfg_m = now_cfg;
            due = due.or_else(|| Some(Instant::now()));
        }
        if let Some(t) = due {
            if Instant::now() >= t {
                due = None;
                sync();
            }
        }
    }
}

fn cmd_get() {
    let cfg = load_cfg();
    let laptop = lid_present() || monitors().iter().any(is_internal);
    let mut out = Value::Object(cfg);
    if let Value::Object(ref mut m) = out {
        m.insert("laptop".into(), Value::Bool(laptop));
    }
    println!("{}", serde_json::to_string(&out).unwrap_or_else(|_| "{}".into()));
}

fn cmd_set(key: &str, val: &str) {
    if !DEFAULTS.iter().any(|(k, _)| *k == key) {
        eprintln!("{{\"ok\":false,\"error\":\"usage\"}}");
        std::process::exit(2);
    }
    let mut cfg = load_cfg();
    cfg.insert(
        key.into(),
        Value::Bool(matches!(val, "1" | "true" | "on")),
    );
    save_cfg(&cfg);
    sync();
    println!("{}", serde_json::to_string(&Value::Object(cfg)).unwrap_or_else(|_| "{}".into()));
}

fn main() {
    let mut args = env::args().skip(1);
    let op = args.next().unwrap_or_else(|| "--get".into());
    match op.as_str() {
        "--get" => cmd_get(),
        "--set" => {
            let key = args.next().unwrap_or_default();
            let val = args.next().unwrap_or_default();
            if key.is_empty() || val.is_empty() {
                println!("{{\"ok\":false,\"error\":\"usage\"}}");
                std::process::exit(2);
            }
            cmd_set(&key, &val);
        }
        "--sync" => sync(),
        "--watch" => watch(),
        _ => {
            println!("{{\"ok\":false,\"error\":\"usage\"}}");
            std::process::exit(2);
        }
    }
}
