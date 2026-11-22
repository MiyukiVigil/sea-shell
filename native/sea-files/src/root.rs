//! Administrator access, the way Explorer and Finder offer it: you ask, or an action is refused and
//! you press Continue, and it asks for your password. A window never runs as root. Under Wayland that
//! is neither safe nor reliable. A tiny helper does, reached through pkexec, one per window, and it
//! only does the few things below. It exits when its window goes, since its input closes.
use crate::core::{self, Entry, Mode};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

/// Removing any of these would end the system. The helper refuses, whatever it's asked.
const NEVER_DELETE: &[&str] = &["/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var"];

fn path_of(req: &Value, key: &str) -> Result<PathBuf, String> {
    match req[key].as_str() {
        Some(p) if p.starts_with('/') => Ok(PathBuf::from(p)),
        _ => Err("that isn't a full path".to_string()),
    }
}

fn delete(path: &Path) -> Result<(), String> {
    let clean = path.components().collect::<PathBuf>();
    if NEVER_DELETE.iter().any(|p| Path::new(p) == clean) || path.to_string_lossy().contains("/../") {
        return Err("that folder can't be deleted from here".to_string());
    }
    let meta = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if meta.is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) }.map_err(|e| e.to_string())
}

fn answer(req: &Value) -> Result<Value, String> {
    let io = |e: std::io::Error| e.to_string();
    match req["op"].as_str().unwrap_or("") {
        "list" => {
            let rows = core::scan(&path_of(req, "path")?, req["hidden"].as_bool().unwrap_or(false)).map_err(io)?;
            let rows: Vec<Value> = rows.into_iter().map(|e| json!([e.name, e.path.to_string_lossy(), e.is_dir, e.size, e.mtime])).collect();
            Ok(json!({ "rows": rows }))
        }
        "copy" | "move" => {
            let mode = if req["op"] == "move" { Mode::Move } else { Mode::Copy };
            core::transfer(&path_of(req, "src")?, &path_of(req, "dest")?, mode).map_err(io)?;
            Ok(json!({}))
        }
        "mkdir" => std::fs::create_dir(path_of(req, "path")?).map(|_| json!({})).map_err(io),
        "touch" => std::fs::OpenOptions::new().write(true).create_new(true).open(path_of(req, "path")?).map(|_| json!({})).map_err(io),
        "rename" => {
            let to = path_of(req, "to")?;
            if std::fs::symlink_metadata(&to).is_ok() {
                return Err("something already has that name".to_string());
            }
            std::fs::rename(path_of(req, "from")?, to).map(|_| json!({})).map_err(io)
        }
        "delete" => delete(&path_of(req, "path")?).map(|_| json!({})),
        "chmod" => {
            let mode = req["mode"].as_u64().ok_or("mode missing")? as u32 & 0o777;
            let recursive = req["recursive"].as_bool().unwrap_or(false);
            let changed = core::chmod_at(&path_of(req, "path")?, mode, recursive)?;
            let rows: Vec<Value> = changed.into_iter().map(|(p, old)| json!({ "path": p.to_string_lossy(), "old": old })).collect();
            Ok(json!({ "changed": rows }))
        }
        _ => Err("that isn't something this helper does".to_string()),
    }
}

/// The helper's whole life: one request a line, one answer a line, until the window goes away.
pub fn serve(input: impl BufRead, mut output: impl Write) {
    let _ = writeln!(output, "{}", json!({ "ready": true }));
    let _ = output.flush();
    for line in input.lines() {
        let Ok(line) = line else { break };
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(req) => match answer(&req) {
                Ok(mut ok) => {
                    ok["ok"] = json!(true);
                    ok
                }
                Err(e) => json!({ "ok": false, "error": e }),
            },
            Err(_) => json!({ "ok": false, "error": "unreadable request" }),
        };
        if writeln!(output, "{reply}").is_err() || output.flush().is_err() {
            break;
        }
    }
}

/// The window's end of it. `call` blocks, so it is only ever used from background threads.
pub struct Client {
    pipes: Mutex<(ChildStdin, BufReader<ChildStdout>)>,
}

impl Client {
    /// Asks for the password. Err means it was dismissed, refused or unavailable.
    pub fn start() -> Result<Client, String> {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe = exe.to_string_lossy().into_owned();
        // A test can run the helper directly, with no password dialog involved.
        let mut command = if std::env::var_os("SEA_FILES_NO_PKEXEC").is_some() {
            let mut c = Command::new(&exe);
            c.arg("--root-helper");
            c
        } else {
            let mut c = Command::new("pkexec");
            c.args([exe.as_str(), "--root-helper"]);
            c
        };
        let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| e.to_string())?;
        let stdin = child.stdin.take().ok_or("no pipe")?;
        let mut stdout = BufReader::new(child.stdout.take().ok_or("no pipe")?);
        let mut first = String::new();
        if stdout.read_line(&mut first).unwrap_or(0) == 0 || !first.contains("ready") {
            let _ = child.wait();
            return Err("The password wasn't accepted, so nothing changed.".to_string());
        }
        // Dropping the client closes the helper's input, which ends it. This collects it afterwards.
        std::thread::spawn(move || {
            let mut child: Child = child;
            let _ = child.wait();
        });
        Ok(Client { pipes: Mutex::new((stdin, stdout)) })
    }

    fn call(&self, req: Value) -> Result<Value, String> {
        let mut pipes = self.pipes.lock().map_err(|_| "the helper stopped")?;
        writeln!(pipes.0, "{req}").map_err(|_| "the helper stopped")?;
        pipes.0.flush().map_err(|_| "the helper stopped")?;
        let mut line = String::new();
        if pipes.1.read_line(&mut line).unwrap_or(0) == 0 {
            return Err("the helper stopped".to_string());
        }
        let reply: Value = serde_json::from_str(&line).map_err(|_| "the helper said something odd")?;
        if reply["ok"].as_bool() == Some(true) { Ok(reply) } else { Err(reply["error"].as_str().unwrap_or("it failed").to_string()) }
    }

    pub fn list(&self, dir: &Path, hidden: bool) -> Result<Vec<Entry>, String> {
        let reply = self.call(json!({ "op": "list", "path": dir.to_string_lossy(), "hidden": hidden }))?;
        Ok(reply["rows"].as_array().map(|rows| rows.iter().map(|r| Entry {
            name: r[0].as_str().unwrap_or("").to_string(),
            path: PathBuf::from(r[1].as_str().unwrap_or("")),
            is_dir: r[2].as_bool().unwrap_or(false),
            size: r[3].as_u64().unwrap_or(0),
            mtime: r[4].as_i64().unwrap_or(0),
        }).collect()).unwrap_or_default())
    }
    pub fn transfer(&self, src: &Path, dest: &Path, mode: Mode) -> Result<(), String> {
        let op = if mode == Mode::Move { "move" } else { "copy" };
        self.call(json!({ "op": op, "src": src.to_string_lossy(), "dest": dest.to_string_lossy() })).map(|_| ())
    }
    pub fn mkdir(&self, path: &Path) -> Result<(), String> {
        self.call(json!({ "op": "mkdir", "path": path.to_string_lossy() })).map(|_| ())
    }
    pub fn touch(&self, path: &Path) -> Result<(), String> {
        self.call(json!({ "op": "touch", "path": path.to_string_lossy() })).map(|_| ())
    }
    pub fn rename(&self, from: &Path, to: &Path) -> Result<(), String> {
        self.call(json!({ "op": "rename", "from": from.to_string_lossy(), "to": to.to_string_lossy() })).map(|_| ())
    }
    pub fn delete(&self, path: &Path) -> Result<(), String> {
        self.call(json!({ "op": "delete", "path": path.to_string_lossy() })).map(|_| ())
    }

    pub fn chmod(&self, path: &Path, mode: u32, recursive: bool) -> Result<Vec<(PathBuf, u32)>, String> {
        let reply = self.call(json!({ "op": "chmod", "path": path.to_string_lossy(), "mode": mode, "recursive": recursive }))?;
        Ok(reply["changed"].as_array().map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    Some((PathBuf::from(r["path"].as_str()?), r["old"].as_u64()? as u32))
                })
                .collect()
        }).unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn run(requests: &[Value]) -> Vec<Value> {
        let input = requests.iter().map(|r| r.to_string()).collect::<Vec<_>>().join("\n");
        let mut out = Vec::new();
        serve(Cursor::new(input), &mut out);
        String::from_utf8(out).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sea-root-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn the_system_folders_can_never_be_deleted() {
        for p in ["/", "/usr", "/etc/", "/home", "/boot"] {
            let r = run(&[json!({ "op": "delete", "path": p })]);
            assert_eq!(r[1]["ok"], json!(false), "{p}");
            assert!(Path::new(p).exists());
        }
        assert_eq!(run(&[json!({ "op": "delete", "path": "/tmp/../usr" })])[1]["ok"], json!(false));
    }

    #[test]
    fn it_does_only_what_it_lists() {
        let r = run(&[json!({ "op": "exec", "path": "/bin/sh" }), json!({ "op": "delete", "path": "relative/path" })]);
        assert_eq!((r[1]["ok"].clone(), r[2]["ok"].clone()), (json!(false), json!(false)));
    }

    #[test]
    fn folder_operations_work_end_to_end() {
        let d = tmp("ops");
        let s = |p: &str| d.join(p).to_string_lossy().into_owned();
        let r = run(&[
            json!({ "op": "mkdir", "path": s("a") }),
            json!({ "op": "touch", "path": s("a/f") }),
            json!({ "op": "rename", "from": s("a/f"), "to": s("a/g") }),
            json!({ "op": "copy", "src": s("a/g"), "dest": s("") }),
            json!({ "op": "list", "path": s("a"), "hidden": false }),
            json!({ "op": "delete", "path": s("a") }),
        ]);
        assert!(r[1..].iter().all(|x| x["ok"] == json!(true)), "{r:?}");
        assert_eq!(r[5]["rows"][0][0], json!("g"));
        assert!(d.join("g").exists() && !d.join("a").exists());
    }
}
