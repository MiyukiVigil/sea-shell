//! Recent files from ~/.local/share/recently-used.xbel (freedesktop recent list).
use crate::core::Entry;
use gio::prelude::FileExt;
use gtk::{gio, glib};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "__sea_files_recent__";

pub fn root() -> PathBuf {
    PathBuf::from(ROOT)
}

pub fn is_view(path: &Path) -> bool {
    path.as_os_str().as_bytes() == ROOT.as_bytes()
}

fn xbel_path() -> PathBuf {
    glib::user_data_dir().join("recently-used.xbel")
}

fn path_from_href(href: &str) -> Option<PathBuf> {
    if href.starts_with('/') {
        return Some(PathBuf::from(href));
    }
    gio::File::for_uri(href).path()
}

/// Newest local files that still exist, up to `limit`.
pub fn entries(limit: usize) -> Vec<Entry> {
    let text = fs::read_to_string(xbel_path()).ok();
    let Some(text) = text else { return Vec::new() };
    let mut hits: Vec<(String, PathBuf)> = Vec::new();
    let mut in_bookmark = false;
    let mut href = String::new();
    let mut when = String::new();
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("<bookmark ") {
            in_bookmark = true;
            href.clear();
            when.clear();
            if let Some(h) = t.split("href=\"").nth(1).and_then(|s| s.split('"').next()) {
                href = h.to_string();
            }
            for key in ["visited=\"", "modified=\""] {
                if let Some(v) = t.split(key).nth(1).and_then(|s| s.split('"').next()) {
                    when = v.to_string();
                }
            }
        } else if in_bookmark && t.starts_with("</bookmark>") {
            in_bookmark = false;
            if href.starts_with("file://") || href.starts_with('/') {
                if let Some(path) = path_from_href(&href) {
                    if path.exists() && path.is_file() {
                        hits.push((when.clone(), path));
                    }
                }
            }
        }
    }
    hits.sort_by(|a, b| b.0.cmp(&a.0));
    let mut seen = std::collections::HashSet::new();
    let mut rows = Vec::new();
    for (_, path) in hits {
        if !seen.insert(path.clone()) {
            continue;
        }
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
        let meta = fs::metadata(&path).ok();
        let (size, mtime) = match meta {
            Some(m) => {
                use std::os::unix::fs::MetadataExt;
                (m.len(), m.mtime())
            }
            None => (0, 0),
        };
        rows.push(Entry {
            name,
            path,
            is_dir: false,
            size,
            mtime,
        });
        if rows.len() >= limit {
            break;
        }
    }
    rows
}
