//! Copying and moving, one job at a time, on its own thread. Every file is written beside its final
//! name and only renamed into place once complete, so cancelling or crashing can't leave half a file
//! that looks whole, and a replaced file stays intact until its replacement is ready.
use crate::core::{self, Mode};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Choice {
    Replace,
    KeepBoth,
    Skip,
}

#[derive(Clone, Debug)]
pub struct Question {
    pub name: String,
    pub both_folders: bool,
    pub new_size: u64,
    pub new_mtime: i64,
    pub old_size: u64,
    pub old_mtime: i64,
}

#[derive(Default, Debug)]
pub struct Outcome {
    /// What now exists because of this job, at the top level.
    pub created: Vec<PathBuf>,
    /// (where it was, where it is).
    pub moved: Vec<(PathBuf, PathBuf)>,
    pub denied: Vec<PathBuf>,
    pub failures: Vec<String>,
    pub skipped: usize,
    pub cancelled: bool,
    /// Something was overwritten, so this job can't be fully undone.
    pub replaced: bool,
}

/// What the window and the worker share.
#[derive(Default)]
pub struct Job {
    pub done: AtomicU64,
    pub total: AtomicU64,
    pub cancel: AtomicBool,
    pub started: AtomicBool,
    pub finished: AtomicBool,
    pub current: Mutex<String>,
    pub question: Mutex<Option<Question>>,
    answer: Mutex<Option<(Choice, bool)>>,
    wake: Condvar,
    pub outcome: Mutex<Option<Outcome>>,
}

impl Job {
    pub fn answer(&self, choice: Choice, for_all: bool) {
        *self.question.lock().unwrap() = None;
        *self.answer.lock().unwrap() = Some((choice, for_all));
        self.wake.notify_all();
    }

    pub fn stop(&self) {
        self.cancel.store(true, Ordering::Relaxed);
        self.wake.notify_all();
    }

    fn stopped(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    fn ask(&self, q: Question) -> Option<(Choice, bool)> {
        *self.question.lock().unwrap() = Some(q);
        let mut slot = self.answer.lock().unwrap();
        loop {
            if let Some(a) = slot.take() {
                return Some(a);
            }
            if self.stopped() {
                return None;
            }
            slot = self.wake.wait_timeout(slot, std::time::Duration::from_millis(200)).unwrap().0;
        }
    }
}

/// One at a time, across every window. Two big copies at once only make a disk slower.
static QUEUE: Mutex<()> = Mutex::new(());

struct Worker<'a> {
    job: &'a Job,
    sticky: Option<Choice>,
    out: Outcome,
}

fn stamp_of(m: &fs::Metadata) -> i64 {
    use std::os::unix::fs::MetadataExt;
    m.mtime()
}

impl Worker<'_> {
    fn decide(&mut self, from: &Path, to: &Path) -> Option<Choice> {
        if let Some(c) = self.sticky {
            return Some(c);
        }
        let (a, b) = (fs::symlink_metadata(from).ok()?, fs::symlink_metadata(to).ok()?);
        let q = Question {
            name: to.file_name().unwrap_or_default().to_string_lossy().into_owned(),
            both_folders: a.is_dir() && b.is_dir(),
            new_size: a.len(),
            new_mtime: stamp_of(&a),
            old_size: b.len(),
            old_mtime: stamp_of(&b),
        };
        let (choice, all) = self.job.ask(q)?;
        if all {
            self.sticky = Some(choice);
        }
        Some(choice)
    }

    fn copy_file(&mut self, from: &Path, to: &Path, meta: &fs::Metadata) -> io::Result<()> {
        let parent = to.parent().ok_or_else(|| io::Error::other("no folder to write into"))?;
        let part = parent.join(format!(".{}.sea-part-{}", to.file_name().unwrap_or_default().to_string_lossy(), std::process::id()));
        let result = (|| {
            let mut input = fs::File::open(from)?;
            let mut output = fs::File::create(&part)?;
            let mut buf = vec![0u8; 1024 * 1024];
            loop {
                if self.job.stopped() {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
                }
                let n = input.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                output.write_all(&buf[..n])?;
                self.job.done.fetch_add(n as u64, Ordering::Relaxed);
            }
            output.set_permissions(meta.permissions())?;
            if let Ok(when) = meta.modified() {
                let _ = output.set_modified(when);
            }
            Ok(())
        })();
        if let Err(e) = result {
            let _ = fs::remove_file(&part);
            return Err(e);
        }
        fs::rename(&part, to).inspect_err(|_| {
            let _ = fs::remove_file(&part);
        })
    }

    /// False if anything under here stayed behind, so a move knows not to remove the original.
    fn place(&mut self, from: &Path, target: &Path, mode: Mode, top: bool) -> bool {
        if self.job.stopped() {
            return false;
        }
        let Ok(meta) = fs::symlink_metadata(from) else {
            self.out.failures.push(format!("{}: it's gone", from.display()));
            return false;
        };
        *self.job.current.lock().unwrap() = from.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let mut target = target.to_path_buf();
        let mut merged = false;
        if fs::symlink_metadata(&target).is_ok() {
            // Copying something onto itself is Duplicate, and needs no question.
            let same = fs::canonicalize(from).ok() == fs::canonicalize(&target).ok();
            let choice = if same { Choice::KeepBoth } else {
                match self.decide(from, &target) {
                    Some(c) => c,
                    None => return false,
                }
            };
            match choice {
                Choice::Skip => {
                    self.out.skipped += 1;
                    self.job.done.fetch_add(core::tree_size(from).0, Ordering::Relaxed);
                    return false;
                }
                Choice::KeepBoth => {
                    let parent = target.parent().map(Path::to_path_buf).unwrap_or_default();
                    target = core::free_name(&parent, target.file_name().unwrap_or_default());
                }
                Choice::Replace => {
                    let old_dir = fs::symlink_metadata(&target).map(|m| m.is_dir()).unwrap_or(false);
                    if meta.is_dir() && old_dir {
                        merged = true;
                    } else {
                        // A file over a file is replaced by rename at the end, keeping the old one
                        // safe until then. Only a file over a folder, or the reverse, clears first.
                        if meta.is_dir() != old_dir {
                            let gone = if old_dir { fs::remove_dir_all(&target) } else { fs::remove_file(&target) };
                            if let Err(e) = gone {
                                self.note(from, e);
                                return false;
                            }
                        }
                        self.out.replaced = true;
                    }
                }
            }
        }
        if mode == Mode::Move && !merged && fs::symlink_metadata(&target).is_err() && fs::rename(from, &target).is_ok() {
            self.job.done.fetch_add(core::tree_size(&target).0, Ordering::Relaxed);
            if top {
                self.out.moved.push((from.to_path_buf(), target));
            }
            return true;
        }
        let ok = if meta.file_type().is_symlink() {
            let made = fs::read_link(from).and_then(|l| {
                let _ = fs::remove_file(&target);
                std::os::unix::fs::symlink(l, &target)
            });
            self.result(from, made)
        } else if meta.is_dir() {
            if !merged {
                if let Err(e) = fs::create_dir(&target) {
                    self.note(from, e);
                    return false;
                }
            }
            let mut all = true;
            match fs::read_dir(from) {
                Ok(items) => {
                    for item in items.flatten() {
                        if !self.place(&item.path(), &target.join(item.file_name()), mode, false) {
                            all = false;
                        }
                    }
                }
                Err(e) => {
                    self.note(from, e);
                    all = false;
                }
            }
            let _ = fs::set_permissions(&target, meta.permissions());
            all
        } else if meta.is_file() {
            let made = self.copy_file(from, &target, &meta);
            self.result(from, made)
        } else {
            self.out.failures.push(format!("{}: that kind of file can't be copied", from.display()));
            false
        };
        if ok && mode == Mode::Move {
            let gone = if meta.is_dir() { fs::remove_dir(from) } else { fs::remove_file(from) };
            if let Err(e) = gone {
                self.note(from, e);
                return false;
            }
        }
        if top && ok {
            if mode == Mode::Move { self.out.moved.push((from.to_path_buf(), target)) } else { self.out.created.push(target) }
        } else if top && !ok && !self.job.stopped() && mode == Mode::Copy && !merged && target.exists() {
            self.out.created.push(target);
        }
        ok
    }

    fn result(&mut self, from: &Path, made: io::Result<()>) -> bool {
        match made {
            Ok(()) => true,
            Err(e) => {
                self.note(from, e);
                false
            }
        }
    }

    fn note(&mut self, from: &Path, e: io::Error) {
        match e.kind() {
            io::ErrorKind::Interrupted => {}
            io::ErrorKind::PermissionDenied => self.out.denied.push(from.to_path_buf()),
            _ => self.out.failures.push(format!("{}: {e}", from.display())),
        }
    }
}

pub fn run(sources: &[PathBuf], dest: &Path, mode: Mode, job: &Job) -> Outcome {
    let _turn = QUEUE.lock().unwrap_or_else(|p| p.into_inner());
    job.started.store(true, Ordering::Relaxed);
    let mut w = Worker { job, sticky: None, out: Outcome::default() };
    // A move within one drive is a rename, and takes no time to speak of.
    let total: u64 = sources.iter().filter(|s| !(mode == Mode::Move && core::same_drive(s, dest))).map(|s| core::tree_size(s).0).sum();
    job.total.store(total, Ordering::Relaxed);
    for src in sources {
        if job.stopped() {
            break;
        }
        let Some(name) = src.file_name() else { continue };
        if dest.starts_with(src) {
            w.out.failures.push(format!("{}: a folder can't go inside itself", src.display()));
            continue;
        }
        if mode == Mode::Move && src.parent() == Some(dest) {
            continue;
        }
        w.place(src, &dest.join(name), mode, true);
    }
    w.out.cancelled = job.stopped();
    w.out
}

/// Undo and redo. Each operation returns the one that reverses it. Nothing here deletes for good:
/// undoing something you made sends it to the Trash, so undo can't lose anything either.
#[derive(Clone, Debug, PartialEq)]
pub enum Undo {
    Rename(PathBuf, PathBuf),
    Moved(Vec<(PathBuf, PathBuf)>),
    Restore(Vec<PathBuf>),
    Trash(Vec<PathBuf>),
    Tags(Vec<(PathBuf, Option<String>)>),
    Chmod(Vec<(PathBuf, u32)>),
}

impl Undo {
    pub fn describe(&self) -> &'static str {
        match self {
            Undo::Rename(..) => "rename",
            Undo::Moved(..) => "move",
            Undo::Restore(..) => "trash",
            Undo::Trash(..) => "new items",
            Undo::Tags(..) => "tag",
            Undo::Chmod(..) => "permissions",
        }
    }

    pub fn apply(&self) -> Result<Undo, String> {
        match self {
            Undo::Chmod(restore) => {
                use std::os::unix::fs::PermissionsExt;
                let mut back = Vec::new();
                for (path, old) in restore {
                    let was = fs::symlink_metadata(path).ok().map(|m| m.permissions().mode() & 0o7777);
                    core::chmod_at(path, old & 0o777, false)?;
                    if let Some(w) = was {
                        back.push((path.clone(), w));
                    }
                }
                Ok(Undo::Chmod(back))
            }
            Undo::Tags(restore) => {
                let mut back = Vec::new();
                for (path, want) in restore {
                    let was = crate::tags::tag_of(path);
                    crate::tags::set_tag(std::slice::from_ref(path), want.as_deref());
                    back.push((path.clone(), was));
                }
                Ok(Undo::Tags(back))
            }
            Undo::Rename(a, b) => {
                if fs::symlink_metadata(b).is_ok() {
                    return Err(format!("{} is in the way", b.display()));
                }
                fs::rename(a, b).map_err(|e| e.to_string())?;
                Ok(Undo::Rename(b.clone(), a.clone()))
            }
            Undo::Moved(pairs) => {
                let mut back = Vec::new();
                for (from, to) in pairs {
                    if fs::symlink_metadata(to).is_ok() {
                        return Err(format!("{} is in the way", to.display()));
                    }
                    if let Some(parent) = to.parent() {
                        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                    }
                    if fs::rename(from, to).is_err() {
                        core::copy_tree(from, to).map_err(|e| e.to_string())?;
                        crate::trash::delete_permanently(from).map_err(|e| e.to_string())?;
                    }
                    back.push((to.clone(), from.clone()));
                }
                Ok(Undo::Moved(back))
            }
            Undo::Restore(origs) => {
                let mut places = Vec::new();
                for orig in origs {
                    let item = crate::trash::newest_of(orig).ok_or_else(|| format!("{} isn't in the Trash any more", orig.display()))?;
                    places.push(crate::trash::restore(&item).map_err(|e| e.to_string())?);
                }
                Ok(Undo::Trash(places))
            }
            Undo::Trash(paths) => {
                for p in paths {
                    gtk::prelude::FileExt::trash(&gtk::gio::File::for_path(p), gtk::gio::Cancellable::NONE).map_err(|e| e.to_string())?;
                }
                Ok(Undo::Restore(paths.clone()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;
    use std::sync::atomic::Ordering::Relaxed;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sea-ops-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("a")).unwrap();
        fs::create_dir_all(d.join("b")).unwrap();
        d
    }

    /// Runs a job with a helper answering every question the same way, counting them.
    fn run_with(sources: Vec<PathBuf>, dest: PathBuf, mode: Mode, answer: Option<(Choice, bool)>) -> (Outcome, usize) {
        let job = Arc::new(Job::default());
        let (j, stop) = (job.clone(), Arc::new(AtomicBool::new(false)));
        let s2 = stop.clone();
        let asker = std::thread::spawn(move || {
            let mut asked = 0;
            while !s2.load(Relaxed) {
                let pending = j.question.lock().unwrap().is_some();
                if pending {
                    asked += 1;
                    match answer {
                        Some((c, all)) => j.answer(c, all),
                        None => j.stop(),
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            asked
        });
        let out = run(&sources, &dest, mode, &job);
        stop.store(true, Relaxed);
        (out, asker.join().unwrap())
    }

    #[test]
    fn copies_a_tree_with_links_and_times() {
        let d = tmp("tree");
        fs::create_dir_all(d.join("a/x/y")).unwrap();
        fs::write(d.join("a/x/y/f"), "data").unwrap();
        std::os::unix::fs::symlink("f", d.join("a/x/y/ln")).unwrap();
        let (out, asked) = run_with(vec![d.join("a/x")], d.join("b"), Mode::Copy, None);
        assert_eq!(asked, 0);
        assert_eq!(out.created, [d.join("b/x")]);
        assert_eq!(fs::read_to_string(d.join("b/x/y/f")).unwrap(), "data");
        assert!(fs::symlink_metadata(d.join("b/x/y/ln")).unwrap().file_type().is_symlink());
        assert!(d.join("a/x/y/f").exists());
        let before = fs::metadata(d.join("a/x/y/f")).unwrap().modified().unwrap();
        assert_eq!(fs::metadata(d.join("b/x/y/f")).unwrap().modified().unwrap(), before);
    }

    #[test]
    fn asks_about_conflicts_and_each_answer_does_what_it_says() {
        let d = tmp("conflict");
        fs::write(d.join("a/f"), "new").unwrap();
        fs::write(d.join("b/f"), "old").unwrap();
        let (out, asked) = run_with(vec![d.join("a/f")], d.join("b"), Mode::Copy, Some((Choice::Skip, false)));
        assert_eq!((asked, out.skipped), (1, 1));
        assert_eq!(fs::read_to_string(d.join("b/f")).unwrap(), "old");
        let (out, _) = run_with(vec![d.join("a/f")], d.join("b"), Mode::Copy, Some((Choice::KeepBoth, false)));
        assert_eq!(out.created, [d.join("b/f copy")]);
        assert_eq!(fs::read_to_string(d.join("b/f")).unwrap(), "old");
        let (out, _) = run_with(vec![d.join("a/f")], d.join("b"), Mode::Copy, Some((Choice::Replace, false)));
        assert!(out.replaced);
        assert_eq!(fs::read_to_string(d.join("b/f")).unwrap(), "new");
    }

    #[test]
    fn do_this_for_all_only_asks_once_and_folders_merge() {
        let d = tmp("all");
        fs::create_dir_all(d.join("a/box")).unwrap();
        fs::create_dir_all(d.join("b/box")).unwrap();
        for n in ["1", "2", "3"] {
            fs::write(d.join("a/box").join(n), "new").unwrap();
            fs::write(d.join("b/box").join(n), "old").unwrap();
        }
        fs::write(d.join("b/box/only-here"), "keep").unwrap();
        let (_, asked) = run_with(vec![d.join("a/box")], d.join("b"), Mode::Copy, Some((Choice::Replace, true)));
        assert_eq!(asked, 1);
        assert_eq!(fs::read_to_string(d.join("b/box/2")).unwrap(), "new");
        assert_eq!(fs::read_to_string(d.join("b/box/only-here")).unwrap(), "keep", "merging keeps what was only there");
    }

    #[test]
    fn a_move_keeps_what_was_skipped() {
        let d = tmp("mv");
        fs::create_dir_all(d.join("a/box")).unwrap();
        fs::create_dir_all(d.join("b/box")).unwrap();
        fs::write(d.join("a/box/clash"), "mine").unwrap();
        fs::write(d.join("a/box/free"), "x").unwrap();
        fs::write(d.join("b/box/clash"), "theirs").unwrap();
        let job = Arc::new(Job::default());
        let j = job.clone();
        let (d1, d2) = (d.join("a/box"), d.join("b"));
        let t = std::thread::spawn(move || run(&[d1], &d2, Mode::Move, &j));
        // Merge the folder, then skip the clashing file.
        let mut answers = vec![Choice::Skip, Choice::Replace];
        while !t.is_finished() {
            if job.question.lock().unwrap().is_some() {
                if let Some(c) = answers.pop() {
                    job.answer(c, false);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let out = t.join().unwrap();
        assert_eq!(out.skipped, 1);
        assert_eq!(fs::read_to_string(d.join("a/box/clash")).unwrap(), "mine", "a skipped file must stay");
        assert_eq!(fs::read_to_string(d.join("b/box/clash")).unwrap(), "theirs");
        assert!(d.join("b/box/free").exists() && !d.join("a/box/free").exists());
    }

    #[test]
    fn cancelling_leaves_no_partial_file_and_stops_asking() {
        let d = tmp("cancel");
        fs::write(d.join("a/big"), vec![7u8; 40 * 1024 * 1024]).unwrap();
        let job = Arc::new(Job::default());
        job.stop();
        let out = run(&[d.join("a/big")], &d.join("b"), Mode::Copy, &job);
        assert!(out.cancelled);
        assert_eq!(fs::read_dir(d.join("b")).unwrap().count(), 0);
        fs::write(d.join("b/big"), "old").unwrap();
        let (out, _) = run_with(vec![d.join("a/big")], d.join("b"), Mode::Copy, None);
        assert!(out.cancelled);
        assert_eq!(fs::read_to_string(d.join("b/big")).unwrap(), "old");
    }

    #[test]
    fn copying_onto_itself_duplicates_without_asking() {
        let d = tmp("dup");
        fs::write(d.join("a/f.txt"), "x").unwrap();
        let (out, asked) = run_with(vec![d.join("a/f.txt")], d.join("a"), Mode::Copy, None);
        assert_eq!(asked, 0);
        assert_eq!(out.created, [d.join("a/f copy.txt")]);
    }

    #[test]
    fn progress_adds_up_and_a_folder_cannot_enter_itself() {
        let d = tmp("prog");
        fs::write(d.join("a/one"), vec![1u8; 1000]).unwrap();
        let job = Job::default();
        run(&[d.join("a/one")], &d.join("b"), Mode::Copy, &job);
        assert_eq!((job.done.load(Relaxed), job.total.load(Relaxed)), (1000, 1000));
        fs::create_dir_all(d.join("a/in")).unwrap();
        let out = run(&[d.join("a")], &d.join("a/in"), Mode::Copy, &Job::default());
        assert_eq!(out.failures.len(), 1);
    }

    #[test]
    fn undo_and_redo_reverse_each_other() {
        let d = tmp("undo");
        fs::write(d.join("a/f"), "x").unwrap();
        let back = Undo::Rename(d.join("a/f"), d.join("a/g")).apply().unwrap();
        assert!(d.join("a/g").exists());
        let again = back.apply().unwrap();
        assert!(d.join("a/f").exists());
        assert_eq!(again, Undo::Rename(d.join("a/f"), d.join("a/g")));
        let back = Undo::Moved(vec![(d.join("a/f"), d.join("b/f"))]).apply().unwrap();
        assert!(d.join("b/f").exists());
        back.apply().unwrap();
        assert!(d.join("a/f").exists());
        fs::write(d.join("a/g"), "in the way").unwrap();
        assert!(Undo::Rename(d.join("a/f"), d.join("a/g")).apply().is_err());
        assert_eq!(fs::read_to_string(d.join("a/g")).unwrap(), "in the way");
    }
}
