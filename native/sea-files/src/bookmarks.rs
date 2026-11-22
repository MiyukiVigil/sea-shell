//! Sidebar favourites in fm_bookmarks.json — same file the old Files used.
use gtk::glib;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Bookmark {
    pub name: String,
    pub path: PathBuf,
}

fn path() -> PathBuf {
    glib::user_config_dir().join("sea-shell/fm_bookmarks.json")
}

fn defaults() -> Vec<Bookmark> {
    let home = glib::home_dir();
    [
        ("Home", home.clone()),
        ("Desktop", home.join("Desktop")),
        ("Documents", home.join("Documents")),
        ("Downloads", home.join("Downloads")),
        ("Music", home.join("Music")),
        ("Pictures", home.join("Pictures")),
        ("Videos", home.join("Videos")),
    ]
    .into_iter()
    .map(|(name, path)| Bookmark { name: name.to_string(), path })
    .collect()
}

pub fn load() -> Vec<Bookmark> {
    let raw = std::fs::read_to_string(path()).ok();
    let parsed: Option<Vec<Map<String, Value>>> = raw.and_then(|t| serde_json::from_str(&t).ok());
    let Some(items) = parsed else {
        let d = defaults();
        save(&d);
        return d;
    };
    let mut out = Vec::new();
    for item in items {
        let Some(path_str) = item.get("path").and_then(Value::as_str) else { continue };
        let path = PathBuf::from(path_str);
        if !path.exists() {
            continue;
        }
        let name = item
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_else(|| path.file_name().and_then(|n| n.to_str()).unwrap_or("Folder"))
            .to_string();
        out.push(Bookmark { name, path });
    }
    if out.is_empty() {
        return defaults();
    }
    out
}

pub fn save(list: &[Bookmark]) {
    let p = path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let items: Vec<Value> = list
        .iter()
        .map(|b| {
            serde_json::json!({
                "name": b.name,
                "path": b.path.to_string_lossy(),
            })
        })
        .collect();
    let tmp = p.with_extension("tmp");
    if serde_json::to_string_pretty(&items).ok().and_then(|t| std::fs::write(&tmp, t).ok()).is_some() {
        let _ = std::fs::rename(tmp, p);
    }
}

pub fn contains(path: &Path) -> bool {
    let key = path.to_string_lossy();
    load().iter().any(|b| b.path.to_string_lossy() == key)
}

pub fn add(path: &Path, name: &str) {
    if !path.exists() {
        return;
    }
    let mut list = load();
    let key = path.to_string_lossy();
    if list.iter().any(|b| b.path.to_string_lossy() == key) {
        return;
    }
    list.push(Bookmark {
        name: if name.is_empty() {
            path.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("Folder")
                .to_string()
        } else {
            name.to_string()
        },
        path: path.to_path_buf(),
    });
    save(&list);
}

pub fn remove(path: &Path) {
    let key = path.to_string_lossy();
    let list: Vec<_> = load().into_iter().filter(|b| b.path.to_string_lossy() != key).collect();
    save(&list);
}

/// Material symbol name for a well-known folder, else generic folder.
pub fn glyph(path: &Path) -> &'static str {
    let home = glib::home_dir();
    if path == home {
        return "home";
    }
    for (dir, glyph) in [
        (glib::UserDirectory::Documents, "description"),
        (glib::UserDirectory::Downloads, "download"),
        (glib::UserDirectory::Pictures, "image"),
        (glib::UserDirectory::Music, "music_note"),
        (glib::UserDirectory::Videos, "movie"),
        (glib::UserDirectory::Desktop, "desktop_windows"),
    ] {
        if glib::user_special_dir(dir).is_some_and(|d| d == path) {
            return glyph;
        }
    }
    if path == home.join("Desktop") {
        return "desktop_windows";
    }
    "folder"
}
