//! Zips and their relatives: looking inside, taking things out, making new ones, with passwords.
//! Zips go through a library, so a password never appears on a command line where `ps` can see it.
//! 7z and rar have no such library, so 7z is the tool. tar and friends go through bsdtar.
use crate::core::{self, Entry};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, PartialEq)]
pub enum Problem {
    NeedPassword,
    WrongPassword,
    Other(String),
}

impl From<io::Error> for Problem {
    fn from(e: io::Error) -> Self {
        Problem::Other(e.to_string())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub inner: String,
    pub is_dir: bool,
    pub size: u64,
    pub mtime: i64,
    pub encrypted: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Family {
    Zip,
    Seven,
    Tar,
}

fn family(name: &str) -> Family {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".zip") || lower.ends_with(".jar") {
        Family::Zip
    } else if lower.ends_with(".7z") || lower.ends_with(".rar") {
        Family::Seven
    } else {
        Family::Tar
    }
}

/// Double-clicking opens these like folders, as Explorer does for a zip.
pub fn is_browsable(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".zip", ".jar", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".tzst"].iter().any(|e| lower.ends_with(e))
}

/// The archive a path is inside, and the path within it. "/a/b.zip/c/d" gives ("/a/b.zip", "c/d").
pub fn locate(path: &Path) -> Option<(PathBuf, String)> {
    if path.is_dir() {
        return None;
    }
    for candidate in path.ancestors() {
        if candidate.is_file() {
            let name = candidate.file_name()?.to_string_lossy();
            if !is_browsable(&name) {
                return None;
            }
            let inner = path.strip_prefix(candidate).ok()?.to_string_lossy().into_owned();
            return Some((candidate.to_path_buf(), inner));
        }
    }
    None
}

/// Zip and 7z listings give the time on the clock where the file was made, with no zone. Read as
/// local time, not UTC, or every date is off by your distance from Greenwich.
fn stamp(y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64) -> i64 {
    gtk::glib::DateTime::from_local(y as i32, m as i32, d as i32, hh as i32, mm as i32, ss as f64).map(|t| t.to_unix()).unwrap_or(0)
}

fn wrong_password(e: &zip::result::ZipError) -> bool {
    matches!(e, zip::result::ZipError::InvalidPassword)
}

fn zip_open(path: &Path) -> Result<zip::ZipArchive<io::BufReader<fs::File>>, Problem> {
    let file = fs::File::open(path)?;
    zip::ZipArchive::new(io::BufReader::new(file)).map_err(|e| Problem::Other(e.to_string()))
}

fn zip_list(path: &Path) -> Result<Vec<Item>, Problem> {
    let mut archive = zip_open(path)?;
    let mut out = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        let Ok(f) = archive.by_index_raw(i) else { continue };
        // A name that would climb out of the archive isn't shown, and can't be extracted either.
        let Some(safe) = f.enclosed_name() else { continue };
        let mtime = f.last_modified().map(|d| stamp(d.year() as i64, d.month() as i64, d.day() as i64, d.hour() as i64, d.minute() as i64, d.second() as i64)).unwrap_or(0);
        out.push(Item { inner: safe.to_string_lossy().trim_end_matches('/').to_string(), is_dir: f.is_dir(), size: f.size(), mtime, encrypted: f.encrypted() });
    }
    Ok(out)
}

fn seven_tool() -> &'static str {
    if std::path::Path::new("/usr/bin/7z").exists() { "7z" } else { "7za" }
}

/// `-p` goes on the command line for 7z, which has no other non-interactive way. Empty keeps it from
/// waiting on a prompt nobody can see.
fn seven(args: &[&std::ffi::OsStr], password: Option<&str>) -> Result<String, Problem> {
    // Changing an archive with a bare -p would ask for a password nobody can type.
    let creating = args.first().is_some_and(|a| *a == "a" || *a == "d" || *a == "rn");
    let pass = (!creating || password.is_some()).then(|| format!("-p{}", password.unwrap_or("")));
    let out = Command::new(seven_tool()).args(args).args(pass.as_ref()).stdin(Stdio::null()).output().map_err(|e| Problem::Other(format!("7z isn't available: {e}")))?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let err = String::from_utf8_lossy(&out.stderr);
    let all = format!("{text}{err}");
    if !out.status.success() {
        if all.contains("Enter password") || all.contains("Wrong password") || all.contains("Can not open encrypted archive") || all.contains("Data Error in encrypted") || all.contains("CRC Failed in encrypted") {
            return Err(if password.is_some() { Problem::WrongPassword } else { Problem::NeedPassword });
        }
        return Err(Problem::Other(err.lines().chain(text.lines()).find(|l| l.contains("ERROR") || l.contains("Error")).unwrap_or("7z couldn't read it").to_string()));
    }
    Ok(text)
}

fn seven_list(path: &Path, password: Option<&str>) -> Result<Vec<Item>, Problem> {
    let text = seven(&["l".as_ref(), "-slt".as_ref(), "-ba".as_ref(), path.as_os_str()], password)?;
    let mut out = Vec::new();
    for block in text.split("\n\n") {
        let (mut name, mut is_dir, mut size, mut mtime, mut encrypted) = (None, false, 0, 0, false);
        for line in block.lines() {
            let Some((k, v)) = line.split_once(" = ") else { continue };
            match k {
                "Path" => name = Some(v.to_string()),
                "Size" => size = v.parse().unwrap_or(0),
                "Attributes" => is_dir = v.starts_with('D') || v.contains("drwx"),
                "Folder" => is_dir = is_dir || v == "+",
                "Encrypted" => encrypted = v == "+",
                "Modified" => {
                    let n: Vec<i64> = v.split(|c: char| !c.is_ascii_digit()).filter(|s| !s.is_empty()).filter_map(|s| s.parse().ok()).collect();
                    if n.len() >= 6 {
                        mtime = stamp(n[0], n[1], n[2], n[3], n[4], n[5]);
                    }
                }
                _ => {}
            }
        }
        if let Some(n) = name.filter(|n| !n.is_empty() && !n.split('/').any(|p| p == "..")) {
            out.push(Item { inner: n.trim_end_matches('/').to_string(), is_dir, size, mtime, encrypted });
        }
    }
    Ok(out)
}

fn tar_list(path: &Path) -> Result<Vec<Item>, Problem> {
    let out = Command::new("bsdtar").arg("-tvf").arg(path).stdin(Stdio::null()).output()?;
    if !out.status.success() {
        return Err(Problem::Other(String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("that archive can't be read").to_string()));
    }
    let mut items = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        // perms links owner group size month day time name, and the name may contain spaces
        let mut rest = line;
        let mut fields = Vec::new();
        for _ in 0..8 {
            let t = rest.trim_start();
            let end = t.find(' ').unwrap_or(t.len());
            fields.push(&t[..end]);
            rest = &t[end..];
        }
        let name = rest.trim_start().split(" -> ").next().unwrap_or("").trim_end_matches('/').trim_start_matches("./");
        if name.is_empty() || name.split('/').any(|p| p == "..") {
            continue;
        }
        items.push(Item { inner: name.to_string(), is_dir: fields[0].starts_with('d'), size: fields[4].parse().unwrap_or(0), mtime: 0, encrypted: false });
    }
    Ok(items)
}

pub fn list(path: &Path, password: Option<&str>) -> Result<Vec<Item>, Problem> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    match family(&name) {
        Family::Zip => zip_list(path),
        Family::Seven => seven_list(path, password),
        Family::Tar => tar_list(path),
    }
}

/// What's directly inside one folder of an archive. Archives often leave folders implied by the names
/// of the files in them, so those are worked out, not looked up. Paths are the real path of the archive
/// with the inner path added, which is what makes breadcrumbs and Back simply work.
pub fn children(items: &[Item], archive: &Path, folder: &str) -> Vec<Entry> {
    let prefix = if folder.is_empty() { String::new() } else { format!("{folder}/") };
    let mut found: BTreeMap<String, Entry> = BTreeMap::new();
    for item in items {
        let Some(rest) = item.inner.strip_prefix(&prefix) else { continue };
        if rest.is_empty() {
            continue;
        }
        let (name, deeper) = match rest.split_once('/') {
            Some((head, _)) => (head, true),
            None => (rest, false),
        };
        let is_dir = deeper || item.is_dir;
        let at = found.entry(name.to_string()).or_insert_with(|| Entry { name: name.to_string(), path: archive.join(&prefix).join(name), is_dir, size: 0, mtime: 0 });
        if !deeper {
            at.size = item.size;
            at.mtime = item.mtime;
            at.is_dir = is_dir;
        }
    }
    let mut rows: Vec<Entry> = found.into_values().collect();
    rows.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| core::natural_cmp(&a.name, &b.name)));
    rows
}

pub fn is_encrypted(items: &[Item], inner: &str) -> bool {
    items.iter().any(|i| i.inner == inner && i.encrypted)
}

fn zip_extract(path: &Path, wanted: Option<&[String]>, dest: &Path, password: Option<&str>) -> Result<(), Problem> {
    let mut archive = zip_open(path)?;
    for i in 0..archive.len() {
        let raw = archive.by_index_raw(i).map_err(|e| Problem::Other(e.to_string()))?;
        let Some(safe) = raw.enclosed_name() else { continue };
        let encrypted = raw.encrypted();
        drop(raw);
        // Selected items land by their last name: copying a/b/c.txt out gives c.txt.
        let rel: PathBuf = match wanted {
            None => safe,
            Some(list) => {
                let Some(root) = list.iter().find(|w| safe == Path::new(w) || safe.starts_with(w)) else { continue };
                let parent = Path::new(root).parent().unwrap_or(Path::new(""));
                safe.strip_prefix(parent).unwrap_or(&safe).to_path_buf()
            }
        };
        let target = dest.join(&rel);
        let mut file = match (encrypted, password) {
            (true, None) => return Err(Problem::NeedPassword),
            (true, Some(p)) => archive.by_index_decrypt(i, p.as_bytes()).map_err(|e| if wrong_password(&e) { Problem::WrongPassword } else { Problem::Other(e.to_string()) })?,
            (false, _) => archive.by_index(i).map_err(|e| Problem::Other(e.to_string()))?,
        };
        if file.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        if file.is_symlink() {
            // Only links that stay inside what's being extracted. The rest are how an archive
            // reaches out and writes over something it shouldn't.
            let mut link = String::new();
            io::Read::read_to_string(&mut file, &mut link)?;
            let inside = !link.starts_with('/') && !Path::new(&link).components().any(|c| matches!(c, std::path::Component::ParentDir));
            if inside {
                let _ = std::os::unix::fs::symlink(&link, &target);
            }
            continue;
        }
        let mut out = fs::OpenOptions::new().write(true).create_new(true).open(&target)?;
        if let Err(e) = io::copy(&mut file, &mut out) {
            // ZipCrypto can only half-check a password up front. A bad one shows up here.
            drop(out);
            let _ = fs::remove_file(&target);
            return Err(if encrypted { Problem::WrongPassword } else { Problem::Other(e.to_string()) });
        }
        if let Some(mode) = file.unix_mode() {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o777));
        }
    }
    Ok(())
}

fn outside_tool(path: &Path, wanted: Option<&[String]>, into: &Path, password: Option<&str>, seven_zip: bool) -> Result<(), Problem> {
    if seven_zip {
        let out_flag = format!("-o{}", into.display());
        let mut args: Vec<&std::ffi::OsStr> = vec!["x".as_ref(), "-y".as_ref(), out_flag.as_ref(), path.as_os_str()];
        if let Some(list) = wanted {
            args.extend(list.iter().map(|w| std::ffi::OsStr::new(w.as_str())));
        }
        seven(&args, password).map(|_| ())
    } else {
        let mut c = Command::new("bsdtar");
        c.arg("-xf").arg(path).arg("-C").arg(into);
        if let Some(list) = wanted {
            c.args(list);
        }
        let out = c.stdin(Stdio::null()).output()?;
        if out.status.success() { Ok(()) } else { Err(Problem::Other(String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("it couldn't be extracted").to_string())) }
    }
}

/// Takes everything, or just `wanted`, into `dest`, which is created. If it fails, `dest` is removed
/// again if this call made it, so a wrong password leaves nothing behind.
pub fn extract(path: &Path, wanted: Option<&[String]>, dest: &Path, password: Option<&str>) -> Result<(), Problem> {
    let fresh = !dest.exists();
    fs::create_dir_all(dest)?;
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let done = match family(&name) {
        Family::Zip => zip_extract(path, wanted, dest, password),
        other => match wanted {
            None => outside_tool(path, None, dest, password, other == Family::Seven),
            Some(list) => {
                // These tools keep the full inner path, so items are lifted out of a scratch folder.
                let work = dest.join(format!(".sea-extract-{}", std::process::id()));
                fs::create_dir_all(&work)?;
                let result = outside_tool(path, Some(list), &work, password, other == Family::Seven).and_then(|_| {
                    for w in list {
                        let from = work.join(w);
                        let leaf = from.file_name().unwrap_or_default().to_os_string();
                        fs::rename(&from, core::free_name(dest, &leaf))?;
                    }
                    Ok(())
                });
                let _ = fs::remove_dir_all(&work);
                result
            }
        },
    };
    if done.is_err() && fresh {
        let _ = fs::remove_dir_all(dest);
    }
    done
}

/// An archive that holds one folder and nothing else shouldn't become folder/folder.
/// Returns where the contents ended up.
pub fn collapse_single_folder(dest: &Path) -> PathBuf {
    let keep = dest.to_path_buf();
    let Ok(items) = fs::read_dir(dest) else { return keep };
    let items: Vec<_> = items.flatten().collect();
    let [only] = items.as_slice() else { return keep };
    if !only.path().is_dir() || only.path().is_symlink() {
        return keep;
    }
    let Some(parent) = dest.parent() else { return keep };
    let scratch = dest.with_extension("sea-collapse");
    let inner_name = only.file_name();
    if fs::rename(only.path(), &scratch).is_err() {
        return keep;
    }
    let _ = fs::remove_dir(dest);
    let target = core::free_name(parent, &inner_name);
    if fs::rename(&scratch, &target).is_err() {
        return scratch;
    }
    target
}

fn add_to_zip(w: &mut zip::ZipWriter<io::BufWriter<fs::File>>, disk: &Path, name: &str, password: Option<&str>, seen: &mut HashSet<PathBuf>) -> Result<(), Problem> {
    use std::os::unix::fs::PermissionsExt;
    use zip::write::SimpleFileOptions;
    let meta = fs::symlink_metadata(disk)?;
    let z = |e: zip::result::ZipError| Problem::Other(e.to_string());
    let base = SimpleFileOptions::default().unix_permissions(meta.permissions().mode() & 0o7777);
    if meta.file_type().is_symlink() {
        // Stored as a link, not followed: a link to ~ mustn't drag your whole home folder in.
        w.add_symlink(name, fs::read_link(disk)?.to_string_lossy(), base).map_err(z)?;
    } else if meta.is_dir() {
        if !seen.insert(fs::canonicalize(disk)?) {
            return Ok(());
        }
        w.add_directory(format!("{name}/"), base).map_err(z)?;
        let mut kids: Vec<_> = fs::read_dir(disk)?.flatten().collect();
        kids.sort_by_key(|k| k.file_name());
        for kid in kids {
            add_to_zip(w, &kid.path(), &format!("{name}/{}", kid.file_name().to_string_lossy()), password, seen)?;
        }
    } else {
        let options = base.compression_method(zip::CompressionMethod::Deflated).large_file(meta.len() >= u32::MAX as u64);
        let mut data = fs::File::open(disk)?;
        match password {
            Some(p) => w.start_file(name, options.with_aes_encryption(zip::AesMode::Aes256, p)).map_err(z)?,
            None => w.start_file(name, options).map_err(z)?,
        }
        io::copy(&mut data, w)?;
    }
    Ok(())
}

/// A new archive. The format comes from `dest`'s name. A failed one is removed, never left looking done.
pub fn create(sources: &[PathBuf], dest: &Path, password: Option<&str>) -> Result<(), Problem> {
    let name = dest.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let names: Vec<std::ffi::OsString> = sources.iter().filter_map(|s| s.file_name().map(|n| n.to_os_string())).collect();
    let parent = sources.first().and_then(|s| s.parent()).unwrap_or(Path::new("/")).to_path_buf();
    let done = match family(&name) {
        Family::Zip => (|| {
            let file = fs::OpenOptions::new().write(true).create_new(true).open(dest)?;
            let mut w = zip::ZipWriter::new(io::BufWriter::new(file));
            let mut seen = HashSet::new();
            for s in sources {
                let label = s.file_name().unwrap_or_default().to_string_lossy().into_owned();
                add_to_zip(&mut w, s, &label, password, &mut seen)?;
            }
            w.finish().map_err(|e| Problem::Other(e.to_string()))?;
            Ok(())
        })(),
        Family::Seven => {
            let mut args: Vec<&std::ffi::OsStr> = vec!["a".as_ref(), dest.as_os_str()];
            let hide = "-mhe=on";
            if password.is_some() {
                args.push(hide.as_ref());
            }
            let names_abs: Vec<PathBuf> = names.iter().map(|n| parent.join(n)).collect();
            args.extend(names_abs.iter().map(|n| n.as_os_str()));
            seven(&args, password).map(|_| ())
        }
        Family::Tar => {
            let out = Command::new("bsdtar").arg("-acf").arg(dest).arg("-C").arg(&parent).arg("--").args(&names).stdin(Stdio::null()).output()?;
            if out.status.success() { Ok(()) } else { Err(Problem::Other(String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("it couldn't be made").to_string())) }
        }
    };
    if done.is_err() {
        let _ = fs::remove_file(dest);
    }
    done
}

// ---------- changing an archive ----------
//
// A zip can't be edited in place safely, so it's rewritten beside itself and swapped in only once
// complete. Entries that aren't changing are copied as stored, without decrypting or recompressing,
// which is why deleting from a password zip needs no password and is quick even when it's huge.

/// Zip and 7z can be changed. A compressed tar would have to be rebuilt whole, so it stays read-only.
pub fn is_editable(name: &str) -> bool {
    family(name) != Family::Tar
}

fn inner_matches(name: &str, target: &str) -> bool {
    let name = name.trim_end_matches('/');
    name == target || name.starts_with(&format!("{target}/"))
}

/// Rewrites a zip. `change` returns None to drop an entry, or the name to keep it under.
fn zip_rewrite(path: &Path, change: impl Fn(&str) -> Option<String>, add: impl FnOnce(&mut zip::ZipWriter<io::BufWriter<fs::File>>) -> Result<(), Problem>) -> Result<(), Problem> {
    let mut archive = zip_open(path)?;
    let temp = path.with_extension(format!("sea-edit-{}", std::process::id()));
    let result = (|| {
        let file = fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
        let mut w = zip::ZipWriter::new(io::BufWriter::new(file));
        for i in 0..archive.len() {
            let raw = archive.by_index_raw(i).map_err(|e| Problem::Other(e.to_string()))?;
            let name = raw.name().map_err(|e| Problem::Other(e.to_string()))?.to_string();
            let Some(keep) = change(&name) else { continue };
            if keep == name {
                w.raw_copy_file(raw).map_err(|e| Problem::Other(e.to_string()))?;
            } else {
                w.raw_copy_file_rename(raw, keep).map_err(|e| Problem::Other(e.to_string()))?;
            }
        }
        add(&mut w)?;
        w.finish().map_err(|e| Problem::Other(e.to_string()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
        return result;
    }
    if let Ok(meta) = fs::metadata(path) {
        let _ = fs::set_permissions(&temp, meta.permissions());
    }
    fs::rename(&temp, path).map_err(|e| {
        let _ = fs::remove_file(&temp);
        Problem::from(e)
    })
}

fn free_inner(items: &[Item], folder: &str, name: &str) -> String {
    let path_of = |n: &str| if folder.is_empty() { n.to_string() } else { format!("{folder}/{n}") };
    let taken = |n: &str| {
        let p = path_of(n);
        items.iter().any(|i| inner_matches(&i.inner, &p))
    };
    if !taken(name) {
        return path_of(name);
    }
    let raw = Path::new(name);
    let stem = raw.file_stem().unwrap_or_default().to_string_lossy().into_owned();
    let ext = raw.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let mut n = 1;
    loop {
        let label = if n == 1 { format!("{stem} copy{ext}") } else { format!("{stem} copy {n}{ext}") };
        if !taken(&label) {
            return path_of(&label);
        }
        n += 1;
    }
}

/// 7z adds by path relative to where it runs, so what's added is staged in a scratch folder first.
fn seven_add(path: &Path, stage: &Path, password: Option<&str>) -> Result<(), Problem> {
    let abs = fs::canonicalize(path)?;
    let pass = password.map(|p| format!("-p{p}"));
    let out = Command::new(seven_tool()).current_dir(stage).arg("a").arg(&abs).arg(".").args(pass.as_ref()).stdin(Stdio::null()).output().map_err(|e| Problem::Other(e.to_string()))?;
    if out.status.success() {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    if text.contains("Wrong password") || text.contains("Can not open encrypted") {
        return Err(if password.is_some() { Problem::WrongPassword } else { Problem::NeedPassword });
    }
    Err(Problem::Other("7z couldn't add that".to_string()))
}

/// Puts files into a folder of the archive. A name that's taken gets "copy", never replaced.
/// A protected zip keeps new files protected, so it needs its password for this.
pub fn add(path: &Path, sources: &[PathBuf], folder: &str, password: Option<&str>) -> Result<(), Problem> {
    let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    match family(&name) {
        Family::Tar => Err(Problem::Other("this kind of archive can't be changed".to_string())),
        Family::Zip => {
            let items = zip_list(path)?;
            let locked = items.iter().any(|i| i.encrypted);
            if locked && password.is_none() {
                return Err(Problem::NeedPassword);
            }
            if locked {
                check_zip_password(path, &items, password)?;
            }
            let lock = if locked { password } else { None };
            zip_rewrite(path, |n| Some(n.to_string()), |w| {
                let mut seen = HashSet::new();
                for s in sources {
                    let label = s.file_name().unwrap_or_default().to_string_lossy().into_owned();
                    add_to_zip(w, s, &free_inner(&items, folder, &label), lock, &mut seen)?;
                }
                Ok(())
            })
        }
        Family::Seven => {
            let items = seven_list(path, password)?;
            let stage = path.with_extension(format!("sea-stage-{}", std::process::id()));
            let result = (|| {
                for s in sources {
                    let label = s.file_name().unwrap_or_default().to_string_lossy().into_owned();
                    let target = stage.join(free_inner(&items, folder, &label));
                    if let Some(parent) = target.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    core::copy_tree(s, &target)?;
                }
                seven_add(path, &stage, password)
            })();
            let _ = fs::remove_dir_all(&stage);
            result
        }
    }
}

/// Adding to a protected zip with the wrong password would make a zip with two passwords.
fn check_zip_password(path: &Path, items: &[Item], password: Option<&str>) -> Result<(), Problem> {
    let Some(first) = items.iter().find(|i| i.encrypted && !i.is_dir) else { return Ok(()) };
    let probe = std::env::temp_dir().join(format!("sea-probe-{}-{}", std::process::id(), first.size));
    let result = zip_extract(path, Some(&[first.inner.clone()]), &probe, password);
    let _ = fs::remove_dir_all(&probe);
    result
}

pub fn remove(path: &Path, inners: &[String], password: Option<&str>) -> Result<(), Problem> {
    let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    match family(&name) {
        Family::Tar => Err(Problem::Other("this kind of archive can't be changed".to_string())),
        Family::Zip => zip_rewrite(path, |n| (!inners.iter().any(|w| inner_matches(n, w))).then(|| n.to_string()), |_| Ok(())),
        Family::Seven => {
            let mut args: Vec<&std::ffi::OsStr> = vec!["d".as_ref(), path.as_os_str()];
            args.extend(inners.iter().map(|w| std::ffi::OsStr::new(w.as_str())));
            seven(&args, password).map(|_| ())
        }
    }
}

pub fn rename(path: &Path, inner: &str, new_name: &str, password: Option<&str>) -> Result<(), Problem> {
    let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let parent = Path::new(inner).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let to = if parent.is_empty() { new_name.to_string() } else { format!("{parent}/{new_name}") };
    match family(&name) {
        Family::Tar => Err(Problem::Other("this kind of archive can't be changed".to_string())),
        Family::Zip => {
            let items = zip_list(path)?;
            if items.iter().any(|i| inner_matches(&i.inner, &to)) {
                return Err(Problem::Other("something already has that name".to_string()));
            }
            zip_rewrite(path, |n| {
                let trimmed = n.trim_end_matches('/');
                if trimmed == inner {
                    Some(if n.ends_with('/') { format!("{to}/") } else { to.clone() })
                } else if let Some(rest) = n.strip_prefix(&format!("{inner}/")) {
                    Some(format!("{to}/{rest}"))
                } else {
                    Some(n.to_string())
                }
            }, |_| Ok(()))
        }
        Family::Seven => {
            let (i, t) = (std::ffi::OsStr::new(inner), std::ffi::OsStr::new(&to));
            seven(&["rn".as_ref(), path.as_os_str(), i, t], password).map(|_| ())
        }
    }
}

pub fn new_folder(path: &Path, inner: &str, password: Option<&str>) -> Result<(), Problem> {
    let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    match family(&name) {
        Family::Tar => Err(Problem::Other("this kind of archive can't be changed".to_string())),
        Family::Zip => zip_rewrite(path, |n| Some(n.to_string()), |w| {
            w.add_directory(format!("{inner}/"), zip::write::SimpleFileOptions::default()).map_err(|e| Problem::Other(e.to_string()))
        }),
        Family::Seven => {
            let stage = path.with_extension(format!("sea-stage-{}", std::process::id()));
            fs::create_dir_all(stage.join(inner))?;
            let result = seven_add(path, &stage, password);
            let _ = fs::remove_dir_all(&stage);
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sea-arch-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn sample(d: &Path) -> PathBuf {
        let s = d.join("src");
        fs::create_dir_all(s.join("deep/er")).unwrap();
        fs::write(s.join("top.txt"), "top").unwrap();
        fs::write(s.join("deep/er/note.txt"), "secret words").unwrap();
        s
    }

    #[test]
    fn a_password_zip_needs_its_password() {
        let d = tmp("pw");
        let dest = d.join("a.zip");
        create(&[sample(&d)], &dest, Some("hunter2")).unwrap();
        let raw = fs::read(&dest).unwrap();
        assert!(!raw.windows(12).any(|w| w == b"secret words"), "the contents must really be encrypted");
        let items = list(&dest, None).unwrap();
        assert!(is_encrypted(&items, "src/top.txt"));
        assert_eq!(extract(&dest, None, &d.join("no"), None), Err(Problem::NeedPassword));
        assert!(!d.join("no").exists(), "a refused extract leaves nothing behind");
        assert_eq!(extract(&dest, None, &d.join("bad"), Some("wrong")), Err(Problem::WrongPassword));
        assert!(!d.join("bad").exists());
        extract(&dest, None, &d.join("ok"), Some("hunter2")).unwrap();
        assert_eq!(fs::read_to_string(d.join("ok/src/deep/er/note.txt")).unwrap(), "secret words");
    }

    #[test]
    fn other_tools_can_open_what_this_makes() {
        let d = tmp("compat");
        let dest = d.join("a.zip");
        create(&[sample(&d)], &dest, Some("hunter2")).unwrap();
        if std::path::Path::new("/usr/bin/7z").exists() {
            let ok = Command::new("7z").args(["t", "-phunter2"]).arg(&dest).output().unwrap();
            assert!(ok.status.success(), "{}", String::from_utf8_lossy(&ok.stdout));
            let bad = Command::new("7z").args(["t", "-pnope"]).arg(&dest).stdin(Stdio::null()).output().unwrap();
            assert!(!bad.status.success());
        }
    }

    #[test]
    fn looking_inside_finds_implied_folders() {
        let items: Vec<Item> = ["a/b/c.txt", "a/d.txt", "e.txt"].iter().map(|n| Item { inner: n.to_string(), is_dir: false, size: 1, mtime: 0, encrypted: false }).collect();
        let at = Path::new("/x/y.zip");
        let top = children(&items, at, "");
        assert_eq!(top.iter().map(|e| (e.name.as_str(), e.is_dir)).collect::<Vec<_>>(), [("a", true), ("e.txt", false)]);
        assert_eq!(top[0].path, Path::new("/x/y.zip/a"));
        let a = children(&items, at, "a");
        assert_eq!(a.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["b", "d.txt"]);
        assert_eq!(a[1].path, Path::new("/x/y.zip/a/d.txt"));
    }

    #[test]
    fn taking_one_thing_out_keeps_only_its_own_name() {
        let d = tmp("one");
        let dest = d.join("a.zip");
        create(&[sample(&d)], &dest, None).unwrap();
        let out = d.join("out");
        extract(&dest, Some(&["src/deep/er/note.txt".to_string()]), &out, None).unwrap();
        assert_eq!(fs::read_to_string(out.join("note.txt")).unwrap(), "secret words");
        assert!(!out.join("src").exists() && !out.join("top.txt").exists());
        let out2 = d.join("out2");
        extract(&dest, Some(&["src/deep".to_string()]), &out2, None).unwrap();
        assert!(out2.join("deep/er/note.txt").exists());
    }

    #[test]
    fn a_zip_cannot_write_outside_where_it_was_told() {
        let d = tmp("slip");
        let dest = d.join("evil.zip");
        let mut w = zip::ZipWriter::new(fs::File::create(&dest).unwrap());
        let opts = zip::write::SimpleFileOptions::default();
        w.start_file("../../escaped.txt", opts).unwrap();
        io::Write::write_all(&mut w, b"x").unwrap();
        w.add_symlink("ln", "/etc/passwd", opts).unwrap();
        w.start_file("fine.txt", opts).unwrap();
        io::Write::write_all(&mut w, b"y").unwrap();
        w.finish().unwrap();
        let out = d.join("deep/in/out");
        extract(&dest, None, &out, None).unwrap();
        assert!(out.join("fine.txt").exists());
        assert!(!d.join("deep/escaped.txt").exists() && !d.join("escaped.txt").exists());
        assert!(fs::symlink_metadata(out.join("ln")).is_err(), "a link pointing out is dropped");
    }

    #[test]
    fn extracting_never_overwrites_inside_an_existing_folder() {
        let d = tmp("keep");
        let dest = d.join("a.zip");
        create(&[sample(&d)], &dest, None).unwrap();
        let out = d.join("out/src");
        fs::create_dir_all(&out).unwrap();
        fs::write(out.join("top.txt"), "mine").unwrap();
        assert!(extract(&dest, None, &d.join("out"), None).is_err());
        assert_eq!(fs::read_to_string(out.join("top.txt")).unwrap(), "mine");
    }

    #[test]
    fn tar_and_7z_round_trip() {
        let d = tmp("rt");
        let src = sample(&d);
        for (name, pw) in [("a.tar.gz", None), ("a.tar.zst", None), ("a.7z", None), ("b.7z", Some("hunter2"))] {
            if name.ends_with("7z") && !Path::new("/usr/bin/7z").exists() {
                continue;
            }
            let dest = d.join(name);
            create(std::slice::from_ref(&src), &dest, pw).unwrap();
            if pw.is_some() {
                assert_eq!(list(&dest, None), Err(Problem::NeedPassword), "{name}: names are hidden too");
                assert_eq!(list(&dest, Some("nope")), Err(Problem::WrongPassword), "{name}");
            }
            let items = list(&dest, pw).unwrap();
            assert!(items.iter().any(|i| i.inner == "src/deep/er/note.txt"), "{name}: {items:?}");
            let out = d.join(format!("out-{name}"));
            extract(&dest, None, &out, pw).unwrap();
            assert_eq!(fs::read_to_string(out.join("src/deep/er/note.txt")).unwrap(), "secret words", "{name}");
            let one = d.join(format!("one-{name}"));
            extract(&dest, Some(&["src/top.txt".to_string()]), &one, pw).unwrap();
            assert_eq!(fs::read_to_string(one.join("top.txt")).unwrap(), "top", "{name}");
        }
    }

    #[test]
    fn a_folder_holding_one_folder_is_flattened() {
        let d = tmp("flat");
        fs::create_dir_all(d.join("pack/pack/x")).unwrap();
        collapse_single_folder(&d.join("pack"));
        assert!(d.join("pack/x").exists());
        fs::create_dir_all(d.join("two/a")).unwrap();
        fs::create_dir_all(d.join("two/b")).unwrap();
        collapse_single_folder(&d.join("two"));
        assert!(d.join("two/a").exists());
    }

    fn names(path: &Path, pw: Option<&str>) -> Vec<String> {
        let mut v: Vec<String> = list(path, pw).unwrap().into_iter().filter(|i| !i.is_dir).map(|i| i.inner).collect();
        v.sort();
        v
    }

    #[test]
    fn editing_a_zip_adds_removes_and_renames() {
        let d = tmp("edit");
        let z = d.join("a.zip");
        create(&[sample(&d)], &z, None).unwrap();
        fs::write(d.join("new.txt"), "fresh").unwrap();
        add(&z, &[d.join("new.txt")], "src/deep", None).unwrap();
        assert!(names(&z, None).contains(&"src/deep/new.txt".to_string()));
        add(&z, &[d.join("new.txt")], "src/deep", None).unwrap();
        assert!(names(&z, None).contains(&"src/deep/new copy.txt".to_string()), "a taken name is never replaced");
        rename(&z, "src/deep", "renamed", None).unwrap();
        assert!(names(&z, None).contains(&"src/renamed/er/note.txt".to_string()));
        assert!(rename(&z, "src/renamed", "top.txt", None).is_err());
        remove(&z, &["src/renamed".to_string()], None).unwrap();
        assert_eq!(names(&z, None), ["src/top.txt"]);
        new_folder(&z, "src/made", None).unwrap();
        assert!(list(&z, None).unwrap().iter().any(|i| i.inner == "src/made" && i.is_dir));
        let out = d.join("out");
        extract(&z, None, &out, None).unwrap();
        assert_eq!(fs::read_to_string(out.join("src/top.txt")).unwrap(), "top");
        assert_eq!(fs::read_dir(&d).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().contains("sea-edit")).count(), 0);
    }

    #[test]
    fn a_protected_zip_stays_protected_when_edited() {
        let d = tmp("edit-pw");
        let z = d.join("a.zip");
        create(&[sample(&d)], &z, Some("hunter2")).unwrap();
        fs::write(d.join("new.txt"), "fresh secret").unwrap();
        assert_eq!(add(&z, &[d.join("new.txt")], "", None), Err(Problem::NeedPassword));
        assert_eq!(add(&z, &[d.join("new.txt")], "", Some("wrong")), Err(Problem::WrongPassword));
        assert_eq!(names(&z, None).len(), 2, "a refused edit changes nothing");
        add(&z, &[d.join("new.txt")], "", Some("hunter2")).unwrap();
        assert!(is_encrypted(&list(&z, None).unwrap(), "new.txt"));
        assert!(!fs::read(&z).unwrap().windows(12).any(|w| w == b"fresh secret"));
        remove(&z, &["src/top.txt".to_string()], None).unwrap();
        let out = d.join("out");
        extract(&z, None, &out, Some("hunter2")).unwrap();
        assert_eq!(fs::read_to_string(out.join("new.txt")).unwrap(), "fresh secret");
        assert_eq!(fs::read_to_string(out.join("src/deep/er/note.txt")).unwrap(), "secret words", "the rest still opens");
    }

    #[test]
    fn editing_a_7z_works_and_tar_refuses() {
        if !Path::new("/usr/bin/7z").exists() {
            return;
        }
        let d = tmp("edit-7z");
        let z = d.join("a.7z");
        create(&[sample(&d)], &z, None).unwrap();
        fs::write(d.join("new.txt"), "fresh").unwrap();
        add(&z, &[d.join("new.txt")], "src", None).unwrap();
        assert!(names(&z, None).contains(&"src/new.txt".to_string()));
        rename(&z, "src/new.txt", "other.txt", None).unwrap();
        assert!(names(&z, None).contains(&"src/other.txt".to_string()));
        remove(&z, &["src/other.txt".to_string()], None).unwrap();
        assert!(!names(&z, None).contains(&"src/other.txt".to_string()));
        let t = d.join("a.tar.gz");
        create(&[d.join("src")], &t, None).unwrap();
        assert!(!is_editable("a.tar.gz") && is_editable("a.zip") && is_editable("a.7z"));
        assert!(add(&t, &[d.join("new.txt")], "", None).is_err());
    }

    #[test]
    fn archive_times_are_local_clock_times() {
        let t = stamp(2026, 11, 3, 21, 6, 0);
        let back = gtk::glib::DateTime::from_unix_local(t).unwrap();
        assert_eq!((back.day_of_month(), back.hour(), back.minute()), (3, 21, 6));
    }

    #[test]
    fn locate_finds_the_archive_in_a_path() {
        let d = tmp("loc");
        let z = d.join("a.zip");
        fs::write(&z, "x").unwrap();
        assert_eq!(locate(&z.join("b/c.txt")), Some((z.clone(), "b/c.txt".to_string())));
        assert_eq!(locate(&z), Some((z.clone(), String::new())));
        assert_eq!(locate(&d), None);
        fs::write(d.join("note.txt"), "x").unwrap();
        assert_eq!(locate(&d.join("note.txt/y")), None);
    }
}
