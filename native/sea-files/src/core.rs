//! Everything that doesn't touch the toolkit: reading folders, ordering names, and copying files.
//! Kept apart so it can be tested without a display, and so none of it can end up on the UI thread
//! by accident: a slow disk must never be able to stop the window drawing.
use std::cmp::Ordering;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub size: u64,
    pub mtime: i64,
}

/// Folders first, then names the way people read them: "file2" before "file10", case ignored.
pub fn scan(dir: &Path, hidden: bool) -> io::Result<Vec<Entry>> {
    let mut rows = Vec::new();
    for item in fs::read_dir(dir)? {
        let Ok(item) = item else { continue };
        let name = item.file_name().to_string_lossy().into_owned();
        if !hidden && name.starts_with('.') {
            continue;
        }
        let path = item.path();
        // A symlink to a folder opens like a folder, so it sorts and shows like one.
        let meta = fs::metadata(&path).or_else(|_| item.metadata());
        let (is_dir, size, mtime) = match meta {
            Ok(m) => {
                use std::os::unix::fs::MetadataExt;
                (m.is_dir(), m.len(), m.mtime())
            }
            Err(_) => (false, 0, 0),
        };
        rows.push(Entry { name, path, is_dir, size, mtime });
    }
    rows.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| natural_cmp(&a.name, &b.name)));
    Ok(rows)
}

/// Walk up to three levels down when `query` is set, stopping at 150 hits — same rules as the old
/// Files and sea-fm-core.
pub fn scan_deep(dir: &Path, query: &str, hidden: bool) -> io::Result<Vec<Entry>> {
    let q = query.to_lowercase();
    let mut rows = Vec::new();
    walk_deep(dir, &q, hidden, 0, &mut rows)?;
    rows.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| natural_cmp(&a.name, &b.name)));
    Ok(rows)
}

fn walk_deep(dir: &Path, query: &str, hidden: bool, depth: usize, rows: &mut Vec<Entry>) -> io::Result<()> {
    for item in fs::read_dir(dir)? {
        if !query.is_empty() && rows.len() >= 150 {
            return Ok(());
        }
        let Ok(item) = item else { continue };
        let name = item.file_name().to_string_lossy().into_owned();
        if !hidden && name.starts_with('.') {
            continue;
        }
        let path = item.path();
        let meta = fs::metadata(&path).or_else(|_| item.metadata());
        let (is_dir, size, mtime) = match meta {
            Ok(m) => {
                use std::os::unix::fs::MetadataExt;
                (m.is_dir(), m.len(), m.mtime())
            }
            Err(_) => (false, 0, 0),
        };
        if query.is_empty() || name.to_lowercase().contains(query) {
            rows.push(Entry { name, path: path.clone(), is_dir, size, mtime });
        }
        if !query.is_empty() && depth < 3 && is_dir {
            let _ = walk_deep(&path, query, hidden, depth + 1, rows);
        }
    }
    Ok(())
}

pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let (m, n) = (digits(&mut x), digits(&mut y));
                let (m, n) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                let by_value = m.len().cmp(&n.len()).then_with(|| m.cmp(n));
                if by_value != Ordering::Equal {
                    return by_value;
                }
            }
            (Some(p), Some(q)) => {
                let by_letter = p.to_lowercase().cmp(q.to_lowercase());
                if by_letter != Ordering::Equal {
                    return by_letter;
                }
                x.next();
                y.next();
            }
        }
    }
}

fn digits(it: &mut std::iter::Peekable<std::str::Chars>) -> String {
    let mut out = String::new();
    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
        out.push(c);
        it.next();
    }
    out
}

pub fn human(n: u64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let (mut v, mut u) = (n as f64, 0);
    while v >= 1000.0 && u < UNITS.len() - 1 {
        v /= 1000.0;
        u += 1;
    }
    match u {
        0 => format!("{n} bytes"),
        _ if v >= 100.0 => format!("{v:.0} {}", UNITS[u]),
        _ => format!("{v:.1} {}", UNITS[u]),
    }
}

/// The two rows changed between an old and a new listing, as (position, how many to remove, what
/// to insert). Only that stretch is touched, so a file appearing doesn't lose your place or selection.
pub fn minimal_change<'a>(old: &[Entry], new: &'a [Entry]) -> Option<(usize, usize, &'a [Entry])> {
    let start = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    if start == old.len() && start == new.len() {
        return None;
    }
    let tail = old[start..].iter().rev().zip(new[start..].iter().rev()).take_while(|(a, b)| a == b).count();
    Some((start, old.len() - start - tail, &new[start..new.len() - tail]))
}

/// Where a pasted file lands. Never over something that exists: "a.txt" then "a copy.txt", the way
/// Finder and Windows both do it.
pub fn free_name(dir: &Path, name: &std::ffi::OsStr) -> PathBuf {
    let first = dir.join(name);
    if fs::symlink_metadata(&first).is_err() {
        return first;
    }
    let raw = Path::new(name);
    let stem = raw.file_stem().unwrap_or(name).to_string_lossy().into_owned();
    let ext = raw.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let mut n = 1;
    loop {
        let label = if n == 1 { format!("{stem} copy{ext}") } else { format!("{stem} copy {n}{ext}") };
        let candidate = dir.join(label);
        if fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
        n += 1;
    }
}

/// Rename many files at once via temporary names so swaps and series shifts stay safe.
pub fn batch_rename(pairs: &[(PathBuf, PathBuf)]) -> Result<usize, String> {
    if pairs.is_empty() {
        return Err("Nothing to rename".into());
    }
    let targets: Vec<_> = pairs.iter().map(|(_, d)| d.clone()).collect();
    if targets.len() != targets.iter().collect::<std::collections::HashSet<_>>().len() {
        return Err("Two files would end up with the same name".into());
    }
    let sources: std::collections::HashSet<_> = pairs.iter().map(|(s, _)| s.clone()).collect();
    for dest in &targets {
        if dest.exists() && !sources.contains(dest) {
            return Err(format!("'{}' already exists", dest.file_name().unwrap_or_default().to_string_lossy()));
        }
    }
    let stamp = format!(".sea-files-rn-{}-", std::process::id());
    let mut staged = Vec::new();
    for (i, (src, dest)) in pairs.iter().enumerate() {
        if !src.exists() {
            return Err(format!("'{}' is gone", src.display()));
        }
        let tmp = src.parent().unwrap_or_else(|| Path::new(".")).join(format!("{stamp}{i}"));
        fs::rename(src, &tmp).map_err(|e| e.to_string())?;
        staged.push((tmp, dest.clone(), src.clone()));
    }
    for (tmp, dest, src) in &staged {
        if fs::rename(tmp, dest).is_err() {
            for (t, _, s) in &staged {
                let _ = fs::rename(t, s);
            }
            return Err(format!("Could not rename to '{}'", dest.display()));
        }
    }
    Ok(staged.len())
}

pub fn copy_tree(from: &Path, to: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(from)?;
    if meta.file_type().is_symlink() {
        std::os::unix::fs::symlink(fs::read_link(from)?, to)
    } else if meta.is_dir() {
        fs::create_dir(to)?;
        for item in fs::read_dir(from)? {
            let item = item?;
            copy_tree(&item.path(), &to.join(item.file_name()))?;
        }
        fs::set_permissions(to, meta.permissions())
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    Copy,
    Move,
}

/// One item into a folder. Returns where it ended up. A partly finished copy is removed rather than
/// left looking complete, and a move only removes the original once the copy has fully landed.
pub fn transfer(src: &Path, dest_dir: &Path, mode: Mode) -> io::Result<PathBuf> {
    let name = src.file_name().ok_or_else(|| io::Error::other("that item has no name"))?;
    if dest_dir.starts_with(src) {
        return Err(io::Error::other("a folder can't go inside itself"));
    }
    if mode == Mode::Move && src.parent() == Some(dest_dir) {
        return Ok(src.to_path_buf());
    }
    let dest = free_name(dest_dir, name);
    if mode == Mode::Move && fs::rename(src, &dest).is_ok() {
        return Ok(dest);
    }
    if let Err(e) = copy_tree(src, &dest) {
        let _ = fs::remove_dir_all(&dest).or_else(|_| fs::remove_file(&dest));
        return Err(e);
    }
    if mode == Mode::Move {
        if fs::symlink_metadata(src)?.is_dir() {
            fs::remove_dir_all(src)?;
        } else {
            fs::remove_file(src)?;
        }
    }
    Ok(dest)
}

/// Bytes on disk and files in a tree. Hard links count once, symlinks aren't followed.
pub fn tree_size(path: &Path) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    let (mut bytes, mut files, mut stack, mut seen) = (0, 0, vec![path.to_path_buf()], std::collections::HashSet::new());
    while let Some(p) = stack.pop() {
        let Ok(m) = fs::symlink_metadata(&p) else { continue };
        if m.is_dir() {
            if let Ok(items) = fs::read_dir(&p) {
                stack.extend(items.flatten().map(|i| i.path()));
            }
        } else if m.nlink() <= 1 || seen.insert((m.dev(), m.ino())) {
            bytes += m.len();
            files += 1;
        }
    }
    (bytes, files)
}

/// "rwxr-xr-x", with the number, the way both a terminal and a person would want it.
pub fn mode_text(mode: u32) -> String {
    let bit = |shift: u32| {
        let m = (mode >> shift) & 7;
        format!("{}{}{}", if m & 4 != 0 { 'r' } else { '-' }, if m & 2 != 0 { 'w' } else { '-' }, if m & 1 != 0 { 'x' } else { '-' })
    };
    format!("{}{}{} ({:o})", bit(6), bit(3), bit(0), mode & 0o777)
}

/// Parses `755`, `0755`, or `rwxr-xr-x (755)` into a Unix mode (permission bits only).
pub fn parse_mode_input(text: &str) -> Result<u32, String> {
    let t = text.trim();
    let digits = t
        .rsplit('(')
        .next()
        .and_then(|s| s.strip_suffix(')'))
        .map(str::trim)
        .unwrap_or(t);
    let digits = digits.trim_start_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    if digits.len() > 4 || !digits.chars().all(|c| matches!(c, '0'..='7')) {
        return Err("Use an octal mode like 755.".into());
    }
    u32::from_str_radix(digits, 8)
        .map(|m| m & 0o777)
        .map_err(|_| "That mode is not valid.".into())
}

pub fn chmod_at(path: &Path, mode: u32, recursive: bool) -> Result<Vec<(PathBuf, u32)>, String> {
    use std::os::unix::fs::PermissionsExt;
    let mut changed = Vec::new();
    let mut stack = vec![path.to_path_buf()];
    while let Some(at) = stack.pop() {
        let meta = fs::symlink_metadata(&at).map_err(|e| e.to_string())?;
        if meta.file_type().is_symlink() {
            continue;
        }
        let old = meta.permissions().mode() & 0o7777;
        let mut want = mode & 0o777;
        if meta.is_dir() {
            want |= (want & 0o444) >> 2;
        }
        if old != want {
            fs::set_permissions(&at, fs::Permissions::from_mode(want)).map_err(|e| e.to_string())?;
            changed.push((at.clone(), old));
        }
        if recursive && meta.is_dir() {
            if let Ok(read) = fs::read_dir(&at) {
                for ent in read.flatten() {
                    stack.push(ent.path());
                }
            }
        }
        if !recursive {
            break;
        }
    }
    Ok(changed)
}

/// What a drop does, the way Finder and Explorer decide it: within one drive a drag moves, onto
/// another drive it copies, and Ctrl always copies. Something dragged in from another app copies, so
/// a file never disappears from under the program that offered it.
pub fn drop_mode(ours: bool, same_drive: bool, ctrl: bool) -> Mode {
    if ours && same_drive && !ctrl { Mode::Move } else { Mode::Copy }
}

pub fn same_drive(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::symlink_metadata(a), fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev(),
        _ => false,
    }
}

/// What another app put on the clipboard. "x-special/gnome-copied-files" starts with the word copy
/// or cut; "text/uri-list" is one URI a line and may hold comments.
pub fn parse_clipboard(mime: &str, text: &str) -> (Mode, Vec<String>) {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#'));
    let mut mode = Mode::Copy;
    let mut uris = Vec::new();
    if mime == "x-special/gnome-copied-files" {
        if lines.next() == Some("cut") {
            mode = Mode::Move;
        }
    }
    uris.extend(lines.map(str::to_string));
    (mode, uris)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sea-files-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn numbers_sort_by_value() {
        let mut v = vec!["file10", "File2", "file1", "a"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["a", "file1", "File2", "file10"]);
        assert_eq!(natural_cmp("a01", "a1"), "a01".cmp("a1"));
    }

    #[test]
    fn deep_search_finds_nested_names() {
        let d = tmp("deep");
        fs::create_dir_all(d.join("a/b")).unwrap();
        fs::write(d.join("a/b/target.txt"), "x").unwrap();
        fs::write(d.join("other.txt"), "x").unwrap();
        let names: Vec<_> = scan_deep(&d, "target", false).unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["target.txt"]);
        assert!(scan_deep(&d, "target", false).unwrap().len() <= 150);
    }

    #[test]
    fn folders_come_first_and_hidden_stays_hidden() {
        let d = tmp("scan");
        fs::write(d.join("a.txt"), "x").unwrap();
        fs::write(d.join(".secret"), "x").unwrap();
        fs::create_dir(d.join("zeta")).unwrap();
        let names: Vec<_> = scan(&d, false).unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["zeta", "a.txt"]);
        assert_eq!(scan(&d, true).unwrap().len(), 3);
    }

    #[test]
    fn a_name_that_is_not_utf8_keeps_its_real_path() {
        use std::os::unix::ffi::OsStrExt;
        let d = tmp("bytes");
        let weird = std::ffi::OsStr::from_bytes(b"caf\xe9.txt");
        fs::write(d.join(weird), "x").unwrap();
        let rows = scan(&d, false).unwrap();
        assert!(rows[0].path.exists(), "the lossy display name must not replace the path");
    }

    #[test]
    fn a_change_only_touches_what_changed() {
        let e = |n: &str| Entry { name: n.into(), path: n.into(), is_dir: false, size: 0, mtime: 0 };
        let old = [e("a"), e("b"), e("c")];
        assert_eq!(minimal_change(&old, &old), None);
        let new = [e("a"), e("b2"), e("b"), e("c")];
        let (at, remove, insert) = minimal_change(&old, &new).unwrap();
        assert_eq!((at, remove, insert.len(), insert[0].name.as_str()), (1, 0, 1, "b2"));
        let (at, remove, insert) = minimal_change(&new, &old).unwrap();
        assert_eq!((at, remove, insert.len()), (1, 1, 0));
    }

    #[test]
    fn nothing_is_ever_overwritten() {
        let d = tmp("names");
        fs::write(d.join("a.txt"), "x").unwrap();
        assert_eq!(free_name(&d, "b.txt".as_ref()), d.join("b.txt"));
        assert_eq!(free_name(&d, "a.txt".as_ref()), d.join("a copy.txt"));
        fs::write(d.join("a copy.txt"), "x").unwrap();
        assert_eq!(free_name(&d, "a.txt".as_ref()), d.join("a copy 2.txt"));
    }

    #[test]
    fn copy_keeps_the_original_and_move_does_not() {
        let d = tmp("ops");
        fs::create_dir_all(d.join("src/inner")).unwrap();
        fs::write(d.join("src/inner/f"), "data").unwrap();
        std::os::unix::fs::symlink("f", d.join("src/inner/link")).unwrap();
        fs::create_dir(d.join("out")).unwrap();
        let copied = transfer(&d.join("src"), &d.join("out"), Mode::Copy).unwrap();
        assert_eq!(fs::read_to_string(copied.join("inner/f")).unwrap(), "data");
        assert!(fs::symlink_metadata(copied.join("inner/link")).unwrap().file_type().is_symlink());
        assert!(d.join("src/inner/f").exists());
        let again = transfer(&d.join("src"), &d.join("out"), Mode::Move).unwrap();
        assert_eq!(again, d.join("out/src copy"));
        assert!(!d.join("src").exists());
    }

    #[test]
    fn a_folder_cannot_go_inside_itself() {
        let d = tmp("self");
        fs::create_dir_all(d.join("a/b")).unwrap();
        assert!(transfer(&d.join("a"), &d.join("a/b"), Mode::Copy).is_err());
        assert!(transfer(&d.join("a"), &d.join("a"), Mode::Move).is_err());
        assert!(d.join("a/b").exists());
    }

    #[test]
    fn moving_into_the_same_folder_changes_nothing() {
        let d = tmp("same");
        fs::write(d.join("f"), "x").unwrap();
        assert_eq!(transfer(&d.join("f"), &d, Mode::Move).unwrap(), d.join("f"));
        assert_eq!(fs::read_dir(&d).unwrap().count(), 1);
    }

    #[test]
    fn modes_and_sizes() {
        assert_eq!(mode_text(0o40755), "rwxr-xr-x (755)");
        let d = tmp("size");
        fs::write(d.join("a"), "12345").unwrap();
        fs::hard_link(d.join("a"), d.join("b")).unwrap();
        assert_eq!(tree_size(&d), (5, 1));
    }

    #[test]
    fn drops_follow_finder_and_explorer() {
        assert_eq!(drop_mode(true, true, false), Mode::Move);
        assert_eq!(drop_mode(true, true, true), Mode::Copy);
        assert_eq!(drop_mode(true, false, false), Mode::Copy);
        assert_eq!(drop_mode(false, true, false), Mode::Copy);
    }

    #[test]
    fn clipboard_formats() {
        let (m, u) = parse_clipboard("x-special/gnome-copied-files", "cut\nfile:///a\nfile:///b\n");
        assert_eq!((m, u.len()), (Mode::Move, 2));
        let (m, u) = parse_clipboard("x-special/gnome-copied-files", "copy\nfile:///a");
        assert_eq!((m, u), (Mode::Copy, vec!["file:///a".to_string()]));
        let (m, u) = parse_clipboard("text/uri-list", "# comment\r\nfile:///a\r\n");
        assert_eq!((m, u), (Mode::Copy, vec!["file:///a".to_string()]));
    }

    #[test]
    fn sizes_read_like_finder() {
        assert_eq!(human(12), "12 bytes");
        assert_eq!(human(1_500), "1.5 KB");
        assert_eq!(human(250_000_000), "250 MB");
    }
}
