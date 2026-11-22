//! Starred files (fm_starred.json) — individual files pinned by the user.
use crate::core::Entry;
use gtk::glib;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "__sea_files_starred__";

pub fn root() -> PathBuf {
    PathBuf::from(ROOT)
}

pub fn is_view(path: &Path) -> bool {
    path.as_os_str().as_bytes() == ROOT.as_bytes()
}

fn path_file() -> PathBuf {
    glib::user_config_dir().join("sea-shell/fm_starred.json")
}

pub fn load() -> Vec<PathBuf> {
    let raw = fs::read_to_string(path_file()).ok();
    let Some(list) = raw.and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()) else {
        return Vec::new();
    };
    list.into_iter().map(PathBuf::from).filter(|p| p.exists()).collect()
}

pub fn save(list: &[PathBuf]) {
    let p = path_file();
    if let Some(dir) = p.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let items: Vec<String> = list.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    let tmp = p.with_extension("tmp");
    if serde_json::to_string_pretty(&items).ok().and_then(|t| fs::write(&tmp, t).ok()).is_some() {
        let _ = fs::rename(tmp, p);
    }
}

pub fn is_starred(path: &Path) -> bool {
    let key = path.to_string_lossy();
    load().iter().any(|p| p.to_string_lossy() == key)
}

pub fn toggle(paths: &[PathBuf]) {
    if paths.is_empty() {
        return;
    }
    let mut list = load();
    let add = paths.iter().any(|p| !list.iter().any(|x| x == p));
    for p in paths {
        if add {
            if !list.iter().any(|x| x == p) {
                list.push(p.clone());
            }
        } else {
            list.retain(|x| x != p);
        }
    }
    save(&list);
}

pub fn entries() -> Vec<Entry> {
    load()
        .into_iter()
        .filter_map(|path| {
            if !path.is_file() {
                return None;
            }
            let name = path.file_name()?.to_string_lossy().into_owned();
            let meta = fs::metadata(&path).ok()?;
            use std::os::unix::fs::MetadataExt;
            Some(Entry {
                name,
                path,
                is_dir: false,
                size: meta.len(),
                mtime: meta.mtime(),
            })
        })
        .collect()
}
