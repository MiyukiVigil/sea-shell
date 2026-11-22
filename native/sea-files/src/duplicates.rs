//! Find identical files under a folder (size → partial hash → full hash).
use crate::core;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

const HEAD: u64 = 64 * 1024;

#[derive(Clone, Debug)]
pub struct DupeFile {
    pub path: PathBuf,
    pub name: String,
    pub dir: String,
    pub mtime: i64,
}

#[derive(Clone, Debug)]
pub struct DupeGroup {
    pub size: u64,
    pub count: usize,
    pub wasted: u64,
    pub files: Vec<DupeFile>,
}

fn digest(path: &Path, limit: Option<u64>) -> Result<String, std::io::Error> {
    let mut file = File::open(path)?;
    let mut ctx = md5::Context::new();
    if let Some(n) = limit {
        let mut buf = vec![0u8; n.min(1 << 20) as usize];
        let got = file.read(&mut buf)?;
        ctx.consume(&buf[..got]);
    } else {
        let mut buf = [0u8; 1 << 20];
        loop {
            let got = file.read(&mut buf)?;
            if got == 0 {
                break;
            }
            ctx.consume(&buf[..got]);
        }
    }
    Ok(format!("{:x}", ctx.compute()))
}

fn walk(root: &Path, alive: &AtomicBool, progress: &mut dyn FnMut(usize)) -> HashMap<u64, Vec<PathBuf>> {
    let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
    let mut scanned = 0usize;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if !alive.load(Ordering::Relaxed) {
            break;
        }
        let Ok(read) = fs::read_dir(&dir) else { continue };
        for ent in read.flatten() {
            if !alive.load(Ordering::Relaxed) {
                return by_size;
            }
            let path = ent.path();
            let Ok(meta) = ent.metadata() else { continue };
            if meta.is_dir() {
                if path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) {
                    continue;
                }
                stack.push(path);
                continue;
            }
            if !meta.is_file() || meta.len() == 0 {
                continue;
            }
            by_size.entry(meta.len()).or_default().push(path);
            scanned += 1;
            if scanned % 500 == 0 {
                progress(scanned);
            }
        }
    }
    progress(scanned);
    by_size
}

pub fn find(root: &Path, alive: Arc<AtomicBool>, mut progress: impl FnMut(usize)) -> Vec<DupeGroup> {
    if !root.is_dir() {
        return Vec::new();
    }
    let by_size = walk(root, &alive, &mut progress);
    if !alive.load(Ordering::Relaxed) {
        return Vec::new();
    }
    let mut groups = Vec::new();
    for (size, paths) in by_size {
        if paths.len() < 2 || !alive.load(Ordering::Relaxed) {
            continue;
        }
        let mut heads: HashMap<String, Vec<PathBuf>> = HashMap::new();
        for fp in paths {
            if let Ok(h) = digest(&fp, Some(HEAD.min(size))) {
                heads.entry(h).or_default().push(fp);
            }
        }
        for (head, same_head) in heads {
            if same_head.len() < 2 || !alive.load(Ordering::Relaxed) {
                continue;
            }
            let full_map: HashMap<String, Vec<PathBuf>> = if size <= HEAD {
                HashMap::from([(head, same_head)])
            } else {
                let mut full: HashMap<String, Vec<PathBuf>> = HashMap::new();
                for fp in same_head {
                    if let Ok(h) = digest(&fp, None) {
                        full.entry(h).or_default().push(fp);
                    }
                }
                full
            };
            for same in full_map.into_values() {
                if same.len() < 2 {
                    continue;
                }
                let mut files = Vec::new();
                for fp in same {
                    let Ok(meta) = fs::metadata(&fp) else { continue };
                    use std::os::unix::fs::MetadataExt;
                    files.push(DupeFile {
                        name: fp.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string(),
                        dir: fp.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
                        path: fp,
                        mtime: meta.mtime(),
                    });
                }
                if files.len() < 2 {
                    continue;
                }
                files.sort_by(|a, b| a.path.cmp(&b.path));
                let count = files.len();
                groups.push(DupeGroup {
                    size,
                    count,
                    wasted: size * (count as u64 - 1),
                    files,
                });
            }
        }
    }
    if !alive.load(Ordering::Relaxed) {
        return Vec::new();
    }
    groups.sort_by(|a, b| b.wasted.cmp(&a.wasted));
    groups
}

pub fn wasted_text(n: u64) -> String {
    core::human(n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn finds_two_identical_files() {
        let dir = std::env::temp_dir().join(format!("sea-files-dupe-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let a = dir.join("a.bin");
        let b = dir.join("b.bin");
        fs::write(&a, b"same bytes").unwrap();
        fs::write(&b, b"same bytes").unwrap();
        fs::write(dir.join("c.bin"), b"other").unwrap();
        let alive = Arc::new(AtomicBool::new(true));
        let groups = find(&dir, alive, |_| {});
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].files.len(), 2);
    }
}
