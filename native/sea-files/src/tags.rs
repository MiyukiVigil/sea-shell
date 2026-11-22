//! Colour tags stored in fm_tags.json — same palette as the old Files.
use crate::core::Entry;
use gtk::glib;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

pub const NAMES: &[&str] = &["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Grey"];

const PREFIX: &str = "__sea_files_tag__:";

pub fn view(name: &str) -> PathBuf {
    PathBuf::from(format!("{PREFIX}{name}"))
}

pub fn is_view(path: &Path) -> bool {
    path.to_string_lossy().starts_with(PREFIX)
}

pub fn name_of_view(path: &Path) -> Option<String> {
    path.to_string_lossy().strip_prefix(PREFIX).map(str::to_string)
}

fn path_file() -> PathBuf {
    glib::user_config_dir().join("sea-shell/fm_tags.json")
}

fn load_map() -> Map<String, Value> {
    fs::read_to_string(path_file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_map(map: &Map<String, Value>) {
    let p = path_file();
    if let Some(dir) = p.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let tmp = p.with_extension("tmp");
    if serde_json::to_string_pretty(map).ok().and_then(|t| fs::write(&tmp, t).ok()).is_some() {
        let _ = fs::rename(tmp, p);
    }
}

pub fn tag_of(path: &Path) -> Option<String> {
    let key = path.to_string_lossy();
    load_map()
        .get(key.as_ref())
        .and_then(Value::as_str)
        .filter(|n| NAMES.contains(n))
        .map(str::to_string)
}

pub fn set_tag(paths: &[PathBuf], name: Option<&str>) -> Vec<(PathBuf, Option<String>)> {
    let mut map = load_map();
    let mut touched = Vec::new();
    for p in paths {
        let key = p.to_string_lossy().to_string();
        let old = map.get(&key).and_then(Value::as_str).filter(|n| NAMES.contains(n)).map(str::to_string);
        touched.push((p.clone(), old.clone()));
        match name {
            Some(n) if NAMES.contains(&n) => {
                map.insert(key, Value::String(n.to_string()));
            }
            _ => {
                map.remove(&key);
            }
        }
    }
    // Drop tags on missing paths.
    map.retain(|k, v| {
        v.as_str().is_some_and(|n| NAMES.contains(&n)) && Path::new(k).exists()
    });
    save_map(&map);
    touched
}

pub fn entries_for(tag: &str) -> Vec<Entry> {
    if !NAMES.contains(&tag) {
        return Vec::new();
    }
    let map = load_map();
    let mut rows = Vec::new();
    for (path, name) in map.iter() {
        if name.as_str() != Some(tag) {
            continue;
        }
        let path = PathBuf::from(path);
        if !path.exists() {
            continue;
        }
        let meta = fs::metadata(&path).ok();
        let is_dir = meta.as_ref().is_some_and(|m| m.is_dir());
        let (size, mtime) = match meta {
            Some(m) => {
                use std::os::unix::fs::MetadataExt;
                (m.len(), m.mtime())
            }
            None => (0, 0),
        };
        rows.push(Entry {
            name: path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string(),
            path,
            is_dir,
            size,
            mtime,
        });
    }
    rows.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    rows
}

pub fn counts() -> HashMap<String, usize> {
    let mut out: HashMap<String, usize> = NAMES.iter().map(|n| ((*n).to_string(), 0)).collect();
    for name in load_map().values().filter_map(Value::as_str) {
        if let Some(c) = out.get_mut(name) {
            *c += 1;
        }
    }
    out
}
