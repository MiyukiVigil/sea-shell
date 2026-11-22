//! Preferences, in the same fm_prefs.json the old Files used, so nothing has to be set up again.
//! Keys this version doesn't know about are left alone.
use gtk::glib;
use serde_json::{Map, Value};
use std::cell::RefCell;
use std::path::PathBuf;

fn path() -> PathBuf {
    glib::user_config_dir().join("sea-shell/fm_prefs.json")
}
fn views_path() -> PathBuf {
    glib::user_config_dir().join("sea-shell/fm_folder_views.json")
}

fn read(p: PathBuf) -> Map<String, Value> {
    std::fs::read_to_string(p).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn write(p: PathBuf, value: &Map<String, Value>) {
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = p.with_extension("tmp");
    if let Ok(text) = serde_json::to_string_pretty(value) {
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

thread_local! {
    static PREFS: RefCell<Map<String, Value>> = RefCell::new(read(path()));
    static VIEWS: RefCell<Map<String, Value>> = RefCell::new(read(views_path()));
}

pub fn bool_of(key: &str, default: bool) -> bool {
    PREFS.with(|p| p.borrow().get(key).and_then(Value::as_bool).unwrap_or(default))
}
pub fn str_of(key: &str, default: &str) -> String {
    PREFS.with(|p| p.borrow().get(key).and_then(Value::as_str).unwrap_or(default).to_string())
}
pub fn int_of(key: &str, default: i64) -> i64 {
    PREFS.with(|p| p.borrow().get(key).and_then(Value::as_i64).unwrap_or(default))
}
pub fn str_list_of(key: &str) -> Vec<String> {
    PREFS.with(|p| {
        p.borrow()
            .get(key)
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    })
}
pub fn set(key: &str, value: Value) {
    PREFS.with(|p| {
        let mut p = p.borrow_mut();
        p.insert(key.to_string(), value);
        write(path(), &p);
    });
}

pub fn folder_view(dir: &str) -> Option<String> {
    if !bool_of("rememberPerFolder", true) {
        return None;
    }
    VIEWS.with(|v| v.borrow().get(dir).and_then(Value::as_str).map(str::to_string))
}
pub fn set_folder_view(dir: &str, view: &str) {
    if !bool_of("rememberPerFolder", true) {
        return;
    }
    VIEWS.with(|v| {
        let mut v = v.borrow_mut();
        v.insert(dir.to_string(), Value::String(view.to_string()));
        write(views_path(), &v);
    });
}
