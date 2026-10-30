use serde_json::{Value, json};
use std::{
    env, fs,
    io::{self, Read, Write},
    path::Path,
    time::UNIX_EPOCH,
};

fn scan(
    path: &Path,
    query: &str,
    hidden: bool,
    depth: usize,
    rows: &mut Vec<Value>,
) -> io::Result<()> {
    for item in fs::read_dir(path)? {
        let Ok(item) = item else { continue };
        let name = item.file_name().into_string().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "non-UTF8 filename requires compatibility scanner",
            )
        })?;
        let item_path = item.path();
        let path_text = item_path.to_str().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "non-UTF8 path requires compatibility scanner",
            )
        })?;
        if !hidden && name.starts_with('.') {
            continue;
        }
        if !query.is_empty() && rows.len() >= 150 {
            break;
        }
        let Ok(kind) = item.file_type() else { continue };
        let directory = if kind.is_symlink() {
            item.path().is_dir()
        } else {
            kind.is_dir()
        };
        if query.is_empty() || name.to_lowercase().contains(query) {
            // Match lstat semantics: links remain links and are never traversed.
            if let Ok(meta) = fs::symlink_metadata(item.path()) {
                let modified = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs_f64())
                    .unwrap_or(0.0);
                rows.push(json!([
                    name,
                    path_text,
                    directory,
                    if directory { 0 } else { meta.len() },
                    modified
                ]));
            }
        }
        if !query.is_empty() && depth < 3 && kind.is_dir() {
            match scan(&item.path(), query, hidden, depth + 1, rows) {
                Err(error) if error.kind() == io::ErrorKind::InvalidData => return Err(error),
                _ => {}
            }
        }
    }
    Ok(())
}
// Copies into a caller-owned temporary file. The caller commits it atomically
// after metadata succeeds, and removes it if this process is cancelled.
fn copy_data(source: &Path, temporary: &Path) -> io::Result<()> {
    let mut input = fs::File::open(source)?;
    if !input.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "source is not a regular file",
        ));
    }
    let mut output = fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(temporary)?;
    let mut block = vec![0u8; 1024 * 1024];
    let mut total = 0u64;
    let stdout = io::stdout();
    let mut progress = stdout.lock();
    loop {
        let count = input.read(&mut block)?;
        if count == 0 {
            break;
        }
        output.write_all(&block[..count])?;
        total += count as u64;
        writeln!(progress, "{}", json!({"bytes": total}))?;
        progress.flush()?;
    }
    output.flush()?;
    Ok(())
}
fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() == 4 && args[1] == "copy-data" {
        if let Err(error) = copy_data(Path::new(&args[2]), Path::new(&args[3])) {
            eprintln!("{error}");
            std::process::exit(1);
        }
        return;
    }
    if args.len() != 5 || args[1] != "scan" {
        eprintln!("usage: sea-fm-core scan PATH QUERY HIDDEN");
        std::process::exit(2)
    }
    let mut rows = Vec::new();
    let result = scan(
        Path::new(&args[2]),
        &args[3].to_lowercase(),
        args[4] == "1",
        0,
        &mut rows,
    );
    let fallback = result
        .as_ref()
        .is_err_and(|e| e.kind() == io::ErrorKind::InvalidData);
    let error = result.err().map(|e| e.to_string()).unwrap_or_default();
    let output = json!({"rows":rows,"error":error,"fallback":fallback});
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    if serde_json::to_writer(&mut out, &output).is_err() || out.write_all(b"\n").is_err() {
        std::process::exit(1)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_folder_is_error() {
        let mut rows = vec![];
        assert!(scan(Path::new("/nonexistent/sea-fm"), "", false, 0, &mut rows).is_err());
    }
    #[test]
    fn plain_scan_reads_source() {
        let mut rows = vec![];
        scan(
            Path::new(env!("CARGO_MANIFEST_DIR")),
            "",
            false,
            0,
            &mut rows,
        )
        .unwrap();
        assert!(rows.iter().any(|r| r[0] == "Cargo.toml"));
    }
}
