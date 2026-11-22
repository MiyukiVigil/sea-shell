//! The Trash, read straight from the freedesktop layout every Linux desktop shares, so items thrown
//! away in any other app show up here, and items restored here go back where they came from.
use std::ffi::OsString;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct Trashed {
    pub name: String,
    pub file: PathBuf,
    pub info: PathBuf,
    pub orig: PathBuf,
    pub deleted: i64,
    pub is_dir: bool,
    pub size: u64,
}

fn data_home() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share"))
}

/// Your main Trash's files folder. This path is also what stands for "the Trash" in a window.
pub fn home_files() -> PathBuf {
    data_home().join("Trash/files")
}

/// (trash folder, the top a relative Path= is measured from). Other drives keep their own, per the spec.
fn roots() -> Vec<(PathBuf, Option<PathBuf>)> {
    let mut out = vec![(data_home().join("Trash"), None)];
    let uid = unsafe { getuid() };
    if let Ok(mounts) = fs::read_to_string("/proc/self/mounts") {
        for line in mounts.lines() {
            let Some(point) = line.split(' ').nth(1) else { continue };
            let point = PathBuf::from(point.replace("\\040", " "));
            for dir in [point.join(format!(".Trash-{uid}")), point.join(".Trash").join(uid.to_string())] {
                if dir.join("info").is_dir() && !out.iter().any(|(d, _)| *d == dir) {
                    out.push((dir, Some(point.clone())));
                }
            }
        }
    }
    out
}

unsafe extern "C" {
    fn getuid() -> u32;
}

pub fn is_trash(path: &Path) -> bool {
    path.starts_with(home_files()) || roots().iter().any(|(d, _)| path.starts_with(d.join("files")))
}

fn unescape(s: &str) -> OsString {
    let b = s.as_bytes();
    let (mut out, mut i) = (Vec::with_capacity(b.len()), 0);
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..(i + 3).min(s.len())], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    OsString::from_vec(out)
}

fn parse_date(s: &str) -> i64 {
    let n: Vec<i32> = s.split(|c: char| !c.is_ascii_digit()).filter(|p| !p.is_empty()).filter_map(|p| p.parse().ok()).collect();
    if n.len() < 6 {
        return 0;
    }
    gtk::glib::DateTime::from_local(n[0], n[1], n[2], n[3], n[4], n[5] as f64).map(|t| t.to_unix()).unwrap_or(0)
}

fn read_info(info: &Path, top: Option<&Path>) -> Option<(PathBuf, i64)> {
    let text = fs::read_to_string(info).ok()?;
    let (mut orig, mut deleted) = (None, 0);
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("Path=") {
            let p = PathBuf::from(unescape(v.trim()));
            orig = Some(match top {
                Some(t) if p.is_relative() => t.join(p),
                _ => p,
            });
        } else if let Some(v) = line.strip_prefix("DeletionDate=") {
            deleted = parse_date(v.trim());
        }
    }
    Some((orig?, deleted))
}

pub fn list() -> Vec<Trashed> {
    let mut out = Vec::new();
    for (root, top) in roots() {
        let Ok(items) = fs::read_dir(root.join("info")) else { continue };
        for item in items.flatten() {
            let info = item.path();
            if info.extension().and_then(|e| e.to_str()) != Some("trashinfo") {
                continue;
            }
            let Some((orig, deleted)) = read_info(&info, top.as_deref()) else { continue };
            let file = root.join("files").join(info.file_stem().unwrap_or_default());
            let Ok(meta) = fs::symlink_metadata(&file) else { continue };
            let name = orig.file_name().unwrap_or_default().to_string_lossy().into_owned();
            out.push(Trashed { name, file, info, orig, deleted, is_dir: meta.is_dir(), size: meta.len() });
        }
    }
    out.sort_by(|a, b| b.deleted.cmp(&a.deleted).then_with(|| crate::core::natural_cmp(&a.name, &b.name)));
    out
}

pub fn find(file: &Path) -> Option<Trashed> {
    list().into_iter().find(|t| t.file == file)
}

/// Back where it came from, recreating the folder if it's gone. Never over something that's there now.
pub fn restore(item: &Trashed) -> io::Result<PathBuf> {
    let parent = item.orig.parent().ok_or_else(|| io::Error::other("it has no original folder"))?;
    fs::create_dir_all(parent)?;
    let dest = crate::core::free_name(parent, item.orig.file_name().unwrap_or_default());
    if fs::rename(&item.file, &dest).is_err() {
        crate::core::copy_tree(&item.file, &dest)?;
        remove(&item.file)?;
    }
    let _ = fs::remove_file(&item.info);
    Ok(dest)
}

fn remove(path: &Path) -> io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        // A folder someone made read-only can't be emptied until it's writable again.
        let _ = make_writable(path);
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn make_writable(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let _ = fs::set_permissions(&d, fs::Permissions::from_mode(0o700));
        if let Ok(items) = fs::read_dir(&d) {
            for i in items.flatten() {
                if i.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    stack.push(i.path());
                }
            }
        }
    }
    Ok(())
}

pub fn delete(item: &Trashed) -> io::Result<()> {
    remove(&item.file)?;
    let _ = fs::remove_file(&item.info);
    Ok(())
}

pub fn empty() -> usize {
    list().iter().filter(|t| delete(t).is_err()).count()
}

/// The most recent trashing of this path, for undo.
pub fn newest_of(orig: &Path) -> Option<Trashed> {
    list().into_iter().find(|t| t.orig == orig)
}

/// Deleted outright, skipping the Trash. Refuses your home folder and everything above it, whatever
/// was selected, because that's the one mistake nobody recovers from.
pub fn delete_permanently(path: &Path) -> io::Result<()> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    if home.starts_with(path) || path.parent().is_none() {
        return Err(io::Error::other("that folder can't be deleted"));
    }
    remove(path)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// These change XDG_DATA_HOME, which is process-wide.
    pub(crate) static ENV: Mutex<()> = Mutex::new(());

    fn fresh(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sea-trash-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("data/Trash/files")).unwrap();
        fs::create_dir_all(d.join("data/Trash/info")).unwrap();
        unsafe { std::env::set_var("XDG_DATA_HOME", d.join("data")) };
        d
    }

    fn throw_away(d: &Path, stored: &str, orig: &Path) {
        fs::write(d.join("data/Trash/files").join(stored), "x").unwrap();
        let esc = orig.to_string_lossy().replace(' ', "%20");
        fs::write(d.join("data/Trash/info").join(format!("{stored}.trashinfo")), format!("[Trash Info]\nPath={esc}\nDeletionDate=2026-11-03T21:06:00\n")).unwrap();
    }

    #[test]
    fn items_show_their_real_name_and_home() {
        let _g = ENV.lock().unwrap();
        let d = fresh("list");
        throw_away(&d, "note.2.txt", &d.join("my docs/note.txt"));
        let items = list();
        assert_eq!(items.len(), 1);
        assert_eq!((items[0].name.as_str(), items[0].orig.clone()), ("note.txt", d.join("my docs/note.txt")));
        assert!(items[0].deleted > 0);
    }

    #[test]
    fn restore_recreates_the_folder_and_never_overwrites() {
        let _g = ENV.lock().unwrap();
        let d = fresh("restore");
        let orig = d.join("gone/deep/note.txt");
        throw_away(&d, "note.txt", &orig);
        assert_eq!(restore(&list()[0]).unwrap(), orig);
        assert!(orig.exists());
        assert!(list().is_empty(), "its info file goes too");
        throw_away(&d, "note.txt", &orig);
        assert_eq!(restore(&list()[0]).unwrap(), d.join("gone/deep/note copy.txt"));
        assert!(orig.exists());
    }

    #[test]
    fn deleting_and_emptying_really_remove_it() {
        let _g = ENV.lock().unwrap();
        let d = fresh("del");
        throw_away(&d, "a", &d.join("a"));
        throw_away(&d, "b", &d.join("b"));
        delete(&find(&d.join("data/Trash/files/a")).unwrap()).unwrap();
        assert_eq!(list().len(), 1);
        assert_eq!(empty(), 0);
        assert_eq!(fs::read_dir(d.join("data/Trash/files")).unwrap().count(), 0);
        assert_eq!(fs::read_dir(d.join("data/Trash/info")).unwrap().count(), 0);
    }

    #[test]
    fn permanent_delete_refuses_home_and_above() {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap());
        assert!(delete_permanently(&home).is_err());
        assert!(delete_permanently(Path::new("/")).is_err());
        assert!(home.exists());
        if let Some(parent) = home.parent() {
            assert!(delete_permanently(parent).is_err());
        }
    }

    #[test]
    fn a_read_only_folder_can_still_be_deleted() {
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("sea-ro-{}", std::process::id()));
        fs::create_dir_all(d.join("ro/in")).unwrap();
        fs::write(d.join("ro/in/f"), "x").unwrap();
        fs::set_permissions(d.join("ro/in"), fs::Permissions::from_mode(0o500)).unwrap();
        delete_permanently(&d.join("ro")).unwrap();
        assert!(!d.join("ro").exists());
    }
}
