//! sea-appmenu — focused window's menu bar for the bar to draw.
//!
//! Phase 2a: Rust owns the always-on daemon (Hyprland socket, flock, DBusMenu).
//! AT-SPI / lazy submenu / doctor / setup / AppMenu registrar stay on short-lived
//! or side-car Python so idle RSS drops from ~38 MB to a few MB.

use fs2::FileExt;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value as Zv};

const MAX_TOP: usize = 24;
const MAX_DEPTH: usize = 6;
const RETRY_LIMIT: u32 = 7;

type RegMap = Arc<Mutex<HashMap<u32, (String, String)>>>;

fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn cache_dir() -> PathBuf {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".cache"))
        .join("sea-shell")
}

fn out_path() -> PathBuf {
    cache_dir().join("appmenu.json")
}

fn uid() -> u32 {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|u| u.parse().ok())
        })
        .unwrap_or(1000)
}

fn lock_path() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", uid())))
        .join("sea-shell")
        .join("appmenu.lock")
}

fn exe_dir() -> PathBuf {
    env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn python_script() -> PathBuf {
    let beside = exe_dir().join("sea-appmenu.py");
    if beside.is_file() {
        return beside;
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../quickshell/scripts/menu/sea-appmenu.py")
}

fn py_json(args: &[&str]) -> Option<Value> {
    let script = python_script();
    if !script.is_file() {
        return None;
    }
    let out = Command::new("python3")
        .arg(&script)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    serde_json::from_slice(&out.stdout).ok()
}

fn forward_py(args: &[String]) -> i32 {
    let script = python_script();
    match Command::new("python3").arg(&script).args(args).status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!("sea-appmenu: python fallback failed: {e}");
            1
        }
    }
}

fn hypr(args: &[&str]) -> Value {
    Command::new("hyprctl")
        .args(args)
        .arg("-j")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice(&o.stdout).ok())
        .unwrap_or(Value::Null)
}

fn focused(addr: Option<&str>) -> Option<Map<String, Value>> {
    if let Some(a) = addr {
        if let Value::Array(clients) = hypr(&["clients"]) {
            for c in clients {
                let Some(obj) = c.as_object() else { continue };
                let ca = obj.get("address").and_then(|v| v.as_str()).unwrap_or("");
                if !ca.eq_ignore_ascii_case(a) {
                    continue;
                }
                let pid = obj.get("pid").and_then(|v| v.as_i64()).filter(|p| *p > 0)?;
                let mut m = Map::new();
                m.insert("pid".into(), json!(pid));
                m.insert(
                    "class".into(),
                    json!(obj.get("class").and_then(|v| v.as_str()).unwrap_or("")),
                );
                let ws = obj.get("workspace").and_then(|v| v.as_object());
                m.insert(
                    "ws".into(),
                    ws.and_then(|w| w.get("id").cloned()).unwrap_or(Value::Null),
                );
                m.insert(
                    "monitor".into(),
                    obj.get("monitor").cloned().unwrap_or(Value::Null),
                );
                return Some(m);
            }
        }
    }
    let obj = hypr(&["activewindow"]).as_object()?.clone();
    let pid = obj.get("pid").and_then(|v| v.as_i64()).filter(|p| *p > 0)?;
    let mut m = Map::new();
    m.insert("pid".into(), json!(pid));
    m.insert(
        "class".into(),
        json!(obj.get("class").and_then(|v| v.as_str()).unwrap_or("")),
    );
    let ws = obj.get("workspace").and_then(|v| v.as_object());
    m.insert(
        "ws".into(),
        ws.and_then(|w| w.get("id").cloned()).unwrap_or(Value::Null),
    );
    m.insert(
        "monitor".into(),
        obj.get("monitor").cloned().unwrap_or(Value::Null),
    );
    Some(m)
}

fn atomic_write_json(path: &Path, val: &Value) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut f = File::create(&tmp)?;
        serde_json::to_writer(&mut f, val)?;
        f.write_all(b"\n")?;
    }
    fs::rename(tmp, path)?;
    Ok(())
}

fn write_snap(val: &Value) {
    let _ = atomic_write_json(&out_path(), val);
}

fn demnemonic(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '_' {
            if chars.peek() == Some(&'_') {
                out.push('_');
                chars.next();
            }
            continue;
        }
        out.push(c);
    }
    out
}

fn prop_str<'a>(props: &'a HashMap<String, OwnedValue>, key: &str) -> Option<&'a str> {
    props.get(key).and_then(|v| match &**v {
        Zv::Str(s) => Some(s.as_str()),
        _ => None,
    })
}

fn prop_bool(props: &HashMap<String, OwnedValue>, key: &str, default: bool) -> bool {
    props
        .get(key)
        .and_then(|v| match &**v {
            Zv::Bool(b) => Some(*b),
            _ => None,
        })
        .unwrap_or(default)
}

fn prop_i32(props: &HashMap<String, OwnedValue>, key: &str) -> Option<i32> {
    props.get(key).and_then(|v| match &**v {
        Zv::I32(i) => Some(*i),
        Zv::U32(u) => Some(*u as i32),
        _ => None,
    })
}

fn dbm_accel(v: Option<&Zv<'_>>) -> Option<String> {
    let Zv::Array(arr) = v? else {
        return None;
    };
    let mut parts = Vec::new();
    for item in arr.iter() {
        match item {
            Zv::Str(s) if !s.is_empty() => parts.push(s.as_str().to_string()),
            Zv::Array(inner) => {
                for x in inner.iter() {
                    if let Zv::Str(s) = x {
                        if !s.is_empty() {
                            parts.push(s.as_str().to_string());
                        }
                    }
                }
            }
            _ => {}
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("+"))
    }
}

fn dict_props(v: &Zv<'_>) -> Option<HashMap<String, OwnedValue>> {
    let Zv::Dict(dict) = v else {
        return None;
    };
    let mut out = HashMap::new();
    for (k, val) in dict.iter() {
        let key = match k {
            Zv::Str(s) => s.as_str().to_string(),
            _ => continue,
        };
        if let Ok(ov) = OwnedValue::try_from(val.try_clone().ok()?) {
            out.insert(key, ov);
        }
    }
    Some(out)
}

fn dbm_item(node: &Zv<'_>, depth: usize) -> Option<Value> {
    let Zv::Structure(st) = node else {
        return None;
    };
    let fields = st.fields();
    if fields.len() < 3 {
        return None;
    }
    let ident = match &fields[0] {
        Zv::I32(i) => *i,
        Zv::U32(u) => *u as i32,
        _ => return None,
    };
    let props = dict_props(&fields[1])?;
    if !prop_bool(&props, "visible", true) {
        return None;
    }
    if prop_str(&props, "type") == Some("separator") {
        return Some(json!({"sep": true}));
    }
    let label = demnemonic(prop_str(&props, "label").unwrap_or(""));
    if label.is_empty() {
        return None;
    }
    let mut entry = json!({
        "label": label,
        "enabled": prop_bool(&props, "enabled", true),
        "id": ident,
    });
    if let Some(acc) = dbm_accel(props.get("shortcut").map(|v| &**v)) {
        entry["key"] = json!(acc);
    }
    if let Some(tog) = prop_str(&props, "toggle-type") {
        if !tog.is_empty() {
            entry["checked"] = json!(prop_i32(&props, "toggle-state").unwrap_or(0) == 1);
            if tog.eq_ignore_ascii_case("radio") {
                entry["radio"] = json!(true);
            }
        }
    }
    if let Some(ico) = prop_str(&props, "icon-name") {
        if !ico.is_empty() {
            entry["icon"] = json!(ico);
        }
    }
    let Zv::Array(kids) = &fields[2] else {
        return Some(entry);
    };
    if !kids.is_empty() && depth < MAX_DEPTH {
        let sub: Vec<_> = kids.iter().filter_map(|k| dbm_item(k, depth + 1)).collect();
        if !sub.is_empty() {
            entry["items"] = json!(sub);
        }
    } else if prop_str(&props, "children-display") == Some("submenu") {
        entry["stub"] = json!(true);
    }
    Some(entry)
}

fn session_bus() -> Option<Connection> {
    Connection::session().ok()
}

fn owner_pid(conn: &Connection, name: &str) -> Option<u32> {
    conn.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "GetConnectionUnixProcessID",
        &name,
    )
    .ok()
    .and_then(|m| m.body().deserialize().ok())
}

fn list_names(conn: &Connection) -> Vec<String> {
    conn.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "ListNames",
        &(),
    )
    .ok()
    .and_then(|m| m.body().deserialize().ok())
    .unwrap_or_default()
}

fn dbm_paths(conn: &Connection, name: &str) -> Vec<String> {
    if let Ok(msg) = conn.call_method(
        Some(name),
        "/com/canonical/menu",
        Some("org.freedesktop.DBus.Introspectable"),
        "Introspect",
        &(),
    ) {
        if let Ok(xml) = msg.body().deserialize::<String>() {
            let mut out = Vec::new();
            for chunk in xml.split("<node name=\"").skip(1) {
                if let Some(kid) = chunk.split('"').next() {
                    if !kid.is_empty() {
                        out.push(format!("/com/canonical/menu/{kid}"));
                    }
                }
            }
            if !out.is_empty() {
                return out;
            }
        }
    }
    if conn
        .call_method(
            Some(name),
            "/com/canonical/menu/0",
            Some("org.freedesktop.DBus.Introspectable"),
            "Introspect",
            &(),
        )
        .ok()
        .and_then(|m| m.body().deserialize::<String>().ok())
        .is_some_and(|xml| xml.contains("dbusmenu"))
    {
        return vec!["/com/canonical/menu/0".into()];
    }
    vec![]
}

fn dbm_get_layout(
    conn: &Connection,
    name: &str,
    path: &str,
    ident: i32,
    depth: i32,
) -> Option<OwnedValue> {
    let msg = conn
        .call_method(
            Some(name),
            path,
            Some("com.canonical.dbusmenu"),
            "GetLayout",
            &(ident, depth, Vec::<String>::new()),
        )
        .ok()?;
    let (_rev, layout): (i32, OwnedValue) = msg.body().deserialize().ok()?;
    Some(layout)
}

fn dbm_about_to_show(conn: &Connection, name: &str, path: &str, ident: i32) {
    let _ = conn.call_method(
        Some(name),
        path,
        Some("com.canonical.dbusmenu"),
        "AboutToShow",
        &ident,
    );
}

fn dbm_menus(conn: &Connection, name: &str, path: &str) -> Vec<Value> {
    let Some(mut root) = dbm_get_layout(conn, name, path, 0, -1) else {
        return vec![];
    };
    if let Zv::Structure(st) = &*root {
        let fields = st.fields();
        if fields.len() >= 3 {
            if let Zv::Array(kids) = &fields[2] {
                let mut asked = false;
                for kid in kids.iter() {
                    let Zv::Structure(ks) = kid else { continue };
                    let kf = ks.fields();
                    if kf.len() < 3 {
                        continue;
                    }
                    let ident = match &kf[0] {
                        Zv::I32(i) => *i,
                        Zv::U32(u) => *u as i32,
                        _ => continue,
                    };
                    let empty = matches!(&kf[2], Zv::Array(a) if a.is_empty());
                    let is_sub = dict_props(&kf[1])
                        .as_ref()
                        .and_then(|p| prop_str(p, "children-display"))
                        == Some("submenu");
                    if empty && is_sub {
                        dbm_about_to_show(conn, name, path, ident);
                        asked = true;
                    }
                }
                if asked {
                    thread::sleep(Duration::from_millis(50));
                    if let Some(r) = dbm_get_layout(conn, name, path, 0, -1) {
                        root = r;
                    }
                }
            }
        }
    }
    let Zv::Structure(st) = &*root else {
        return vec![];
    };
    let fields = st.fields();
    if fields.len() < 3 {
        return vec![];
    }
    let Zv::Array(kids) = &fields[2] else {
        return vec![];
    };
    let mut out = Vec::new();
    for kid in kids.iter() {
        if let Some(it) = dbm_item(kid, 1) {
            if it.get("sep").and_then(|v| v.as_bool()) != Some(true) {
                out.push(it);
            }
        }
        if out.len() >= MAX_TOP {
            break;
        }
    }
    out
}

fn reg_state_path() -> PathBuf {
    cache_dir().join("appmenu-registered.json")
}

fn reg_load(conn: &Connection, map: &mut HashMap<u32, (String, String)>) {
    let Ok(text) = fs::read_to_string(reg_state_path()) else {
        return;
    };
    let Ok(j) = serde_json::from_str::<Value>(&text) else {
        return;
    };
    let Some(reg) = j.get("reg").and_then(|v| v.as_object()) else {
        return;
    };
    for (k, v) in reg {
        let Ok(wid) = k.parse::<u32>() else { continue };
        let Some(arr) = v.as_array() else { continue };
        if arr.len() < 2 {
            continue;
        }
        let sender = arr[0].as_str().unwrap_or("").to_string();
        let path = arr[1].as_str().unwrap_or("").to_string();
        if owner_pid(conn, &sender).is_some() {
            map.insert(wid, (sender, path));
        }
    }
}

fn reg_save(map: &HashMap<u32, (String, String)>) {
    let reg: Map<String, Value> = map
        .iter()
        .map(|(k, (s, p))| (k.to_string(), json!([s, p])))
        .collect();
    let _ = atomic_write_json(&reg_state_path(), &json!({"v": 1, "reg": reg}));
}

/// Own com.canonical.AppMenu.Registrar in-process (no Python sidecar).
fn registrar_start_rust(reg: RegMap) -> bool {
    use zbus::interface;

    struct Registrar {
        map: RegMap,
    }

    #[interface(name = "com.canonical.AppMenu.Registrar")]
    impl Registrar {
        async fn register_window(
            &mut self,
            window_id: u32,
            menu_object_path: OwnedObjectPath,
            #[zbus(header)] hdr: zbus::message::Header<'_>,
        ) -> zbus::fdo::Result<()> {
            let sender = hdr.sender().map(|s| s.to_string()).unwrap_or_default();
            let mut g = self.map.lock().unwrap();
            g.insert(window_id, (sender, menu_object_path.to_string()));
            reg_save(&g);
            Ok(())
        }

        async fn unregister_window(&mut self, window_id: u32) -> zbus::fdo::Result<()> {
            let mut g = self.map.lock().unwrap();
            g.remove(&window_id);
            reg_save(&g);
            Ok(())
        }

        async fn get_menu_for_window(
            &self,
            window_id: u32,
        ) -> zbus::fdo::Result<(String, OwnedObjectPath)> {
            let g = self.map.lock().unwrap();
            if let Some((s, p)) = g.get(&window_id) {
                let path = OwnedObjectPath::try_from(p.as_str())
                    .unwrap_or_else(|_| OwnedObjectPath::try_from("/").unwrap());
                Ok((s.clone(), path))
            } else {
                Ok((
                    String::new(),
                    OwnedObjectPath::try_from("/").unwrap(),
                ))
            }
        }

        async fn get_menus(&self) -> zbus::fdo::Result<Vec<(u32, String, OwnedObjectPath)>> {
            let g = self.map.lock().unwrap();
            let mut out = Vec::new();
            for (w, (s, p)) in g.iter() {
                if let Ok(path) = OwnedObjectPath::try_from(p.as_str()) {
                    out.push((*w, s.clone(), path));
                }
            }
            Ok(out)
        }
    }

    let Ok(conn) = Connection::session() else {
        return false;
    };
    {
        let mut g = reg.lock().unwrap();
        reg_load(&conn, &mut g);
    }
    if conn
        .object_server()
        .at(
            "/com/canonical/AppMenu/Registrar",
            Registrar { map: reg },
        )
        .is_err()
    {
        eprintln!("sea-appmenu: registrar object register failed");
        return false;
    }
    match conn.request_name("com.canonical.AppMenu.Registrar") {
        Ok(_) => {
            // Hold `conn` (and its executor) for the process lifetime.
            loop {
                thread::sleep(Duration::from_secs(3600));
            }
        }
        Err(e) => {
            eprintln!("sea-appmenu: registrar name not acquired: {e}");
            false
        }
    }
}

fn refresh_reg_from_bus(conn: &Connection, reg: &RegMap) {
    // Prefer live registrar GetMenus when someone owns the name (our sidecar).
    if let Ok(msg) = conn.call_method(
        Some("com.canonical.AppMenu.Registrar"),
        "/com/canonical/AppMenu/Registrar",
        Some("com.canonical.AppMenu.Registrar"),
        "GetMenus",
        &(),
    ) {
        if let Ok(rows) = msg
            .body()
            .deserialize::<Vec<(u32, String, OwnedObjectPath)>>()
        {
            let mut g = reg.lock().unwrap();
            g.clear();
            for (wid, svc, path) in rows {
                g.insert(wid, (svc, path.to_string()));
            }
            return;
        }
    }
    let mut g = reg.lock().unwrap();
    if g.is_empty() {
        reg_load(conn, &mut g);
    }
}

fn registrar_menu(conn: &Connection, reg: &RegMap, pid: u32, xid: Option<u32>) -> Option<(String, String)> {
    refresh_reg_from_bus(conn, reg);
    let g = reg.lock().unwrap();
    if let Some(xid) = xid {
        if let Some((s, p)) = g.get(&xid) {
            if owner_pid(conn, s) == Some(pid) {
                return Some((s.clone(), p.clone()));
            }
        }
    }
    for (_wid, (s, p)) in g.iter() {
        if owner_pid(conn, s) == Some(pid) {
            return Some((s.clone(), p.clone()));
        }
    }
    // Foreign GetMenuForWindow
    if let Some(xid) = xid {
        if let Ok(msg) = conn.call_method(
            Some("com.canonical.AppMenu.Registrar"),
            "/com/canonical/AppMenu/Registrar",
            Some("com.canonical.AppMenu.Registrar"),
            "GetMenuForWindow",
            &xid,
        ) {
            if let Ok((svc, path)) = msg.body().deserialize::<(String, OwnedObjectPath)>() {
                if !svc.is_empty() && owner_pid(conn, &svc) == Some(pid) {
                    return Some((svc, path.to_string()));
                }
            }
        }
    }
    None
}

fn is_xwayland(pid: u32) -> bool {
    if let Value::Array(clients) = hypr(&["clients"]) {
        for c in clients {
            if c.get("pid").and_then(|v| v.as_u64()) == Some(pid as u64) {
                return c.get("xwayland").and_then(|v| v.as_bool()) == Some(true);
            }
        }
    }
    false
}

fn x11_active_window() -> Option<u32> {
    let out = Command::new("xprop")
        .args(["-root", "_NET_ACTIVE_WINDOW"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    for tok in s.split_whitespace() {
        if let Some(rest) = tok.strip_prefix("0x") {
            if let Ok(v) = u32::from_str_radix(rest, 16) {
                return Some(v);
            }
        }
    }
    None
}

fn dbm_for_pid(conn: &Connection, reg: &RegMap, pid: u32) -> Option<(String, String)> {
    let xid = if is_xwayland(pid) {
        x11_active_window()
    } else {
        None
    };
    if let Some(hit) = registrar_menu(conn, reg, pid, xid) {
        return Some(hit);
    }
    let names = list_names(conn);
    for n in names.into_iter().filter(|n| !n.starts_with(':')) {
        if owner_pid(conn, &n) != Some(pid) {
            continue;
        }
        for path in dbm_paths(conn, &n) {
            if let Some(lay) = dbm_get_layout(conn, &n, &path, 0, 1) {
                if let Zv::Structure(st) = &*lay {
                    let fields = st.fields();
                    if fields.len() >= 3 {
                        if let Zv::Array(kids) = &fields[2] {
                            if !kids.is_empty() {
                                return Some((n, path));
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

fn enable_a11y(conn: &Connection) {
    let _ = conn.call_method(
        Some("org.a11y.Bus"),
        "/org/a11y/bus",
        Some("org.freedesktop.DBus.Properties"),
        "Set",
        &(
            "org.a11y.Status",
            "IsEnabled",
            zbus::zvariant::Value::new(true),
        ),
    );
}

fn has_menus(snap: &Value) -> bool {
    snap.get("menus")
        .and_then(|m| m.as_array())
        .is_some_and(|a| !a.is_empty())
}

fn snapshot_rust(conn: &Connection, reg: &RegMap, addr: Option<&str>) -> Value {
    let mut base = json!({"v": 2, "menus": [], "mode": "none"});
    let Some(win) = focused(addr) else {
        return base;
    };
    let pid = win.get("pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    base["pid"] = json!(pid);
    base["class"] = win.get("class").cloned().unwrap_or(json!(""));
    base["ws"] = win.get("ws").cloned().unwrap_or(Value::Null);
    base["monitor"] = win.get("monitor").cloned().unwrap_or(Value::Null);

    if let Some((name, path)) = dbm_for_pid(conn, reg, pid) {
        let menus = dbm_menus(conn, &name, &path);
        if !menus.is_empty() {
            base["menus"] = json!(menus);
            base["mode"] = json!("ready");
            base["source"] = json!("dbusmenu");
            base["app"] = json!(name);
            return base;
        }
    }
    // AT-SPI path — short-lived Python (exits; does not stay resident).
    if let Some(v) = py_json(&["--once"]) {
        return v;
    }
    base["why"] = json!("no dbusmenu export; python fallback failed");
    base
}

fn hypr_socket2() -> Option<PathBuf> {
    let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let rt = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", uid()));
    Some(PathBuf::from(rt).join("hypr").join(sig).join(".socket2.sock"))
}

fn getppid() -> u32 {
    fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| {
            let rest = s.split(')').nth(1)?;
            rest.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(1)
}

fn daemon() -> i32 {
    let lock_dir = lock_path()
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let _ = fs::create_dir_all(&lock_dir);
    let lock_file = match OpenOptions::new()
        .create(true)
        .write(true)
        .open(lock_path())
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!("sea-appmenu: lock open failed: {e}");
            return 1;
        }
    };
    if lock_file.try_lock_exclusive().is_err() {
        eprintln!("sea-appmenu: another daemon holds the lock; exiting");
        return 0;
    }
    let _lock = lock_file;

    let Some(sock_path) = hypr_socket2() else {
        eprintln!("sea-appmenu: no HYPRLAND_INSTANCE_SIGNATURE");
        return 1;
    };
    let Ok(conn) = Connection::session() else {
        eprintln!("sea-appmenu: no session bus");
        return 1;
    };
    enable_a11y(&conn);

    let reg: RegMap = Arc::new(Mutex::new(HashMap::new()));
    let reg_for_srv = reg.clone();
    let reg_owned = Arc::new(Mutex::new(false));
    let flag = reg_owned.clone();
    thread::spawn(move || {
        // Signal "attempted"; name acquisition is best-effort — client path still works.
        *flag.lock().unwrap() = true;
        let _ = registrar_start_rust(reg_for_srv);
        *flag.lock().unwrap() = false;
    });
    thread::sleep(Duration::from_millis(150));
    refresh_reg_from_bus(&conn, &reg);

    let Ok(mut stream) = UnixStream::connect(&sock_path) else {
        eprintln!("sea-appmenu: cannot connect to {}", sock_path.display());
        return 1;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(4)));

    let snap = snapshot_rust(&conn, &reg, None);
    write_snap(&snap);

    let parent = getppid();
    let mut retries = 0u32;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut published: Option<u64> = snap.get("pid").and_then(|v| v.as_u64());
    let mut snapcache: HashMap<u64, Value> = HashMap::new();
    let mut addrmap: HashMap<String, (u64, String)> = HashMap::new();

    const WANTED: &[&str] = &[
        "activewindow>>",
        "activewindowv2>>",
        "workspace>>",
        "openwindow>>",
        "focusedmon>>",
        "closewindow>>",
        "activespecial>>",
        "movewindow>>",
    ];

    loop {
        match stream.read(&mut tmp) {
            Ok(0) => return 0,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                if getppid() != parent && parent != 1 {
                    return 0;
                }
                if retries < RETRY_LIMIT {
                    let snap = snapshot_rust(&conn, &reg, None);
                    retries += 1;
                    if has_menus(&snap) {
                        retries = RETRY_LIMIT;
                    }
                    write_snap(&snap);
                }
                continue;
            }
            Err(_) => return 1,
        }

        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            let txt = String::from_utf8_lossy(&line[..line.len().saturating_sub(1)]);
            if !WANTED.iter().any(|p| txt.starts_with(p)) {
                continue;
            }
            let mut addr: Option<String> = None;
            if let Some(rest) = txt.strip_prefix("activewindowv2>>") {
                let a = rest.trim();
                if !a.is_empty() && a != "," {
                    addr = Some(if a.starts_with("0x") {
                        a.to_string()
                    } else {
                        format!("0x{a}")
                    });
                }
            }

            let mut epid = None;
            let mut ecls = String::new();
            if let Some(ref a) = addr {
                if let Some((p, c)) = addrmap.get(&a.to_lowercase()) {
                    epid = Some(*p);
                    ecls = c.clone();
                }
            }
            if epid.is_none() {
                if let Some(e) = focused(addr.as_deref()) {
                    epid = e.get("pid").and_then(|v| v.as_u64());
                    ecls = e
                        .get("class")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                }
            }
            if let Some(pid) = epid {
                if let Some(hit) = snapcache.get(&pid) {
                    if hit.get("class").and_then(|v| v.as_str()) == Some(ecls.as_str()) {
                        write_snap(hit);
                    }
                }
            }

            let snap = snapshot_rust(&conn, &reg, addr.as_deref());
            published = snap.get("pid").and_then(|v| v.as_u64());
            if let (Some(a), Some(pid)) = (addr.as_ref(), published) {
                addrmap.insert(
                    a.to_lowercase(),
                    (
                        pid,
                        snap.get("class")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string(),
                    ),
                );
                if addrmap.len() > 128 {
                    addrmap.clear();
                }
            }
            if let Some(pid) = published {
                snapcache.insert(pid, snap.clone());
                if snapcache.len() > 64 {
                    if let Value::Array(clients) = hypr(&["clients"]) {
                        let live: HashSet<u64> = clients
                            .iter()
                            .filter_map(|c| c.get("pid").and_then(|v| v.as_u64()))
                            .collect();
                        snapcache.retain(|k, _| live.contains(k));
                    }
                }
            }
            retries = if has_menus(&snap) { RETRY_LIMIT } else { 0 };
            write_snap(&snap);

            // Settle: give the compositor a beat, then confirm unless more events arrived.
            thread::sleep(Duration::from_millis(250));
            let _ = stream.set_nonblocking(true);
            let mut peek = [0u8; 1];
            let has = matches!(stream.read(&mut peek), Ok(n) if n > 0);
            if has {
                buf.push(peek[0]);
            }
            let _ = stream.set_nonblocking(false);
            let _ = stream.set_read_timeout(Some(Duration::from_secs(4)));
            if !has {
                let again = snapshot_rust(&conn, &reg, None);
                let same_pid = again.get("pid") == snap.get("pid");
                let same_len = again.get("menus").and_then(|m| m.as_array()).map(|a| a.len())
                    == snap.get("menus").and_then(|m| m.as_array()).map(|a| a.len());
                if !same_pid || !same_len {
                    published = again.get("pid").and_then(|v| v.as_u64());
                    write_snap(&again);
                }
            }
        }
    }
}

fn main() {
    let argv: Vec<String> = env::args().skip(1).collect();
    if argv.iter().any(|a| a == "--daemon") {
        std::process::exit(daemon());
    }
    if argv.iter().any(|a| {
        matches!(
            a.as_str(),
            "--invoke"
                | "--submenu"
                | "--prime-all"
                | "--forget"
                | "--setup"
                | "--doctor"
                | "--registrar"
        )
    }) {
        std::process::exit(forward_py(&argv));
    }

    if let Some(conn) = session_bus() {
        enable_a11y(&conn);
        let reg = Arc::new(Mutex::new(HashMap::new()));
        let snap = snapshot_rust(&conn, &reg, None);
        if has_menus(&snap) || snap.get("source").and_then(|v| v.as_str()) == Some("dbusmenu") {
            if argv.iter().any(|a| a == "--write") {
                write_snap(&snap);
            }
            if argv.iter().any(|a| a == "--pretty") {
                println!("{}", serde_json::to_string_pretty(&snap).unwrap_or_default());
            } else {
                println!("{}", serde_json::to_string(&snap).unwrap_or_default());
            }
            return;
        }
    }
    std::process::exit(forward_py(&argv));
}
