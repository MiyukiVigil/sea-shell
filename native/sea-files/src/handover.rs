//! Second launch before GTK starts: hand the folder to the resident instance over a Unix socket.
use gtk::{glib, prelude::*};
use std::collections::VecDeque;
use std::io::{BufRead, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const ENV_SKIP: &str = "SEA_FILES_NO_RESIDENT";

pub fn socket_path() -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("sea-files.sock")
}

fn first_open_path(args: impl Iterator<Item = String>) -> Option<PathBuf> {
    let raw = args.filter(|a| !a.starts_with('-')).next()?;
    let path = if raw.starts_with("file://") {
        glib::filename_from_uri(&raw).ok()?.0
    } else {
        PathBuf::from(raw)
    };
    if path.exists() {
        Some(path.canonicalize().unwrap_or(path))
    } else {
        None
    }
}

/// If another instance is listening, send the path and exit the process.
pub fn try_delegate(args: &[String]) -> bool {
    if std::env::var_os(ENV_SKIP).is_some() || args.iter().any(|a| a == "--new-instance") {
        return false;
    }
    let path = first_open_path(args.iter().cloned());
    let sock = socket_path();
    let Ok(mut stream) = UnixStream::connect(&sock) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(1500)));
    let msg = serde_json::json!({ "open": path.as_ref().map(|p| p.to_string_lossy().to_string()) });
    if stream.write_all(format!("{msg}\n").as_bytes()).is_err() {
        return false;
    }
    let mut reader = std::io::BufReader::new(&mut stream);
    let mut ack = String::new();
    if reader.read_line(&mut ack).ok().filter(|_| ack.starts_with("ok")).is_some() {
        std::process::exit(0);
    }
    false
}

pub fn listen(app: gtk::Application) {
    let path = socket_path();
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => Arc::new(Mutex::new(l)),
        Err(_) => return,
    };
    let queue: Arc<Mutex<VecDeque<Option<PathBuf>>>> = Arc::new(Mutex::new(VecDeque::new()));
    let queue_poll = queue.clone();
    let app_weak = app.downgrade();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        let mut pending = queue_poll.lock().expect("handover queue");
        while let Some(open) = pending.pop_front() {
            if let Some(app) = app_weak.upgrade() {
                crate::window::raise_or_open(&app, open);
            }
        }
        glib::ControlFlow::Continue
    });
    thread::spawn(move || {
        loop {
            let stream = {
                let guard = listener.lock().expect("socket listener");
                guard.accept().map(|(s, _)| s)
            };
            let Ok(mut stream) = stream else { continue };
            let mut line = String::new();
            let _ = std::io::BufReader::new(&mut stream).read_line(&mut line);
            let open: Option<PathBuf> = serde_json::from_str::<serde_json::Value>(line.trim())
                .ok()
                .and_then(|v| v.get("open").and_then(|x| x.as_str()).map(PathBuf::from))
                .filter(|p| p.as_os_str().is_empty() || p.exists());
            queue.lock().expect("handover queue").push_back(open);
            let _ = stream.write_all(b"ok\n");
        }
    });
}
