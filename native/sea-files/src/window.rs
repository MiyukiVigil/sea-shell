//! One Files window. The layout takes Finder's sidebar and preview pane, and Windows 11's address
//! bar and command row. Nothing here reads the disk: folders, previews and file operations all run
//! on background threads and hand their answer back, so the window can always draw.
use crate::core::{self, Entry, Mode};
use crate::previewer::{Previewer, Shown, date_text};
use crate::root;
use crate::archive::{self, Item, Problem};
use crate::ops::{self, Choice, Job, Undo};
use crate::trash;
use crate::{bookmarks, duplicates, icons, prefs, preview, prefs_window, recent, resident, stars, tags, thumb_cache};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use gtk::{gdk, gio, glib, prelude::*};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Instant;

/// A shortcut controller on the window, in the bubble phase, not application accels: those run
/// before the focused widget, so Ctrl+C copied the file while you were typing in the search box and
/// Backspace went up a folder. This way a text box gets each key first and keeps what it uses.
const SHORTCUTS: &[(&str, &[&str])] = &[
    ("app.new-window", &["<Control>n"]),
    ("win.new-folder", &["<Control><Shift>n"]),
    ("win.rename", &["F2"]),
    ("win.trash", &["Delete"]),
    ("win.delete-permanently", &["<Shift>Delete"]),
    ("win.close", &["<Control>w"]),
    ("win.new-tab", &["<Control>t"]),
    ("win.next-tab", &["<Control>Tab"]),
    ("win.prev-tab", &["<Control><Shift>Tab"]),
    ("win.split", &["F3"]),
    ("win.cut", &["<Control>x"]),
    ("win.copy", &["<Control>c"]),
    ("win.paste", &["<Control>v"]),
    ("win.select-all", &["<Control>a"]),
    ("win.undo", &["<Control>z"]),
    ("win.redo", &["<Control><Shift>z", "<Control>y"]),
    ("win.view-grid", &["<Control>1"]),
    ("win.view-list", &["<Control>2"]),
    ("win.toggle-preview", &["<Alt>p"]),
    ("win.toggle-hidden", &["<Control>h"]),
    ("win.refresh", &["F5"]),
    ("win.back", &["<Alt>Left"]),
    ("win.forward", &["<Alt>Right"]),
    ("win.up", &["<Alt>Up", "BackSpace"]),
    ("win.go-home", &["<Alt>Home"]),
    ("win.edit-path", &["<Control>l"]),
    ("win.find", &["<Control>f"]),
    ("win.prefs", &["<Control>comma"]),
    ("win.properties", &["<Alt>Return"]),
    ("win.duplicate", &["<Control>d"]),
    ("win.copy-path", &["<Control><Shift>c"]),
    ("win.new-file", &["<Control><Alt>n"]),
];

fn trace() -> bool {
    std::env::var_os("SEA_FILES_TRACE").is_some()
}

pub(crate) fn entry_of(obj: &glib::Object) -> std::cell::Ref<'_, Entry> {
    obj.downcast_ref::<glib::BoxedAnyObject>().expect("rows hold entries").borrow::<Entry>()
}

pub(crate) fn kind_of(e: &Entry) -> (gio::Icon, String) {
    icons::for_entry(&e.name, e.is_dir)
}

thread_local! {
    /// Where each item in the Trash came from, for the column that shows it.
    pub(crate) static ORIGINS: RefCell<HashMap<PathBuf, String>> = RefCell::new(HashMap::new());
    pub(crate) static UNDO: RefCell<Vec<Undo>> = const { RefCell::new(Vec::new()) };
    pub(crate) static REDO: RefCell<Vec<Undo>> = const { RefCell::new(Vec::new()) };
    pub(crate) static WINS: RefCell<Vec<std::rc::Weak<Win>>> = const { RefCell::new(Vec::new()) };
    pub(crate) static OWN_DRAG: Cell<bool> = const { Cell::new(false) };
}

const THUMB_WORKERS: usize = 3;
const THUMB_CACHE: usize = 600;

struct ThumbJob {
    path: PathBuf,
    thumb: glib::WeakRef<gtk::Image>,
    stack: glib::WeakRef<gtk::Stack>,
    wanted: u64,
}

#[derive(Default)]
struct Thumbs {
    queue: RefCell<VecDeque<ThumbJob>>,
    running: Cell<usize>,
    cache: RefCell<HashMap<PathBuf, gdk::Texture>>,
    tick: Cell<u64>,
}

const WANT_KEY: &str = "sea-want";

impl Thumbs {
    fn request(self: &Rc<Self>, stack: &gtk::Stack, thumb: &gtk::Image, path: &Path, ready: bool) {
        if !ready {
            stack.set_visible_child_name("icon");
            thumb.set_paintable(None::<&gdk::Paintable>);
            return;
        }
        let wanted = self.tick.get() + 1;
        unsafe { thumb.set_data(WANT_KEY, wanted) };
        stack.set_visible_child_name("icon");
        thumb.set_paintable(None::<&gdk::Paintable>);
        if let Some(tex) = self.cache.borrow().get(path) {
            thumb.set_paintable(Some(tex));
            stack.set_visible_child_name("thumb");
            return;
        }
        if let Some(pixels) = thumb_cache::load(path) {
            let tex = pixels.texture();
            self.cache.borrow_mut().insert(path.to_path_buf(), tex.clone());
            thumb.set_paintable(Some(&tex));
            stack.set_visible_child_name("thumb");
            return;
        }
        self.queue.borrow_mut().push_back(ThumbJob {
            path: path.to_path_buf(),
            thumb: thumb.downgrade(),
            stack: stack.downgrade(),
            wanted,
        });
        self.pump();
    }

    fn still_wanted(thumb: &gtk::Image, wanted: u64) -> bool {
        unsafe { thumb.data::<u64>(WANT_KEY).map(|p| *p.as_ref()) == Some(wanted) }
    }

    fn pump(self: &Rc<Self>) {
        while self.running.get() < THUMB_WORKERS {
            let Some(job) = self.queue.borrow_mut().pop_back() else { return };
            let Some(thumb) = job.thumb.upgrade() else { continue };
            if !Self::still_wanted(&thumb, job.wanted) {
                continue;
            }
            self.running.set(self.running.get() + 1);
            let side = (thumb.pixel_size().max(16) * thumb.scale_factor().max(1)) as u32;
            let this = self.clone();
            glib::spawn_future_local(async move {
                let path = job.path.clone();
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
                let done = gio::spawn_blocking(move || preview::grid_thumb(&path, &name, side)).await;
                this.running.set(this.running.get() - 1);
                if let Ok(Some(pixels)) = done {
                    thumb_cache::save(&job.path, &pixels);
                    let tex = pixels.texture();
                    let mut cache = this.cache.borrow_mut();
                    if cache.len() >= THUMB_CACHE {
                        cache.clear();
                    }
                    cache.insert(job.path.clone(), tex.clone());
                    drop(cache);
                    if let Some(thumb) = job.thumb.upgrade() {
                        if Self::still_wanted(&thumb, job.wanted) {
                            thumb.set_paintable(Some(&tex));
                            if let Some(stack) = job.stack.upgrade() {
                                stack.set_visible_child_name("thumb");
                            }
                        }
                    }
                }
                this.pump();
            });
        }
    }
}

pub(crate) enum Place {
    Folder(PathBuf),
    Volume(gio::Volume),
}

pub(crate) struct Shell {
    window: gtk::ApplicationWindow,
    stack: gtk::Stack,
    strip: gtk::Box,
    pills: gtk::Box,
    tabs: RefCell<Vec<Rc<Tab>>>,
    current: Cell<usize>,
    search: gtk::SearchEntry,
    places: RefCell<Vec<(PathBuf, gtk::Widget)>>,
    favourites: gtk::ListBox,
    fav_paths: RefCell<Vec<PathBuf>>,
    tags: gtk::ListBox,
    tag_names: RefCell<Vec<String>>,
    locations: gtk::ListBox,
    targets: RefCell<Vec<Place>>,
    volumes: gio::VolumeMonitor,
    search_timer: RefCell<Option<glib::SourceId>>,
}

pub(crate) struct Tab {
    root: gtk::Box,
    panes: RefCell<Vec<Rc<Win>>>,
    active: Cell<usize>,
    pill: gtk::Box,
    label: gtk::Label,
}


// ---------- the window ----------
pub(crate) struct Win {
    window: gtk::ApplicationWindow,
    store: gio::ListStore,
    rows: RefCell<Vec<Entry>>,
    selection: gtk::MultiSelection,
    filter: gtk::CustomFilter,
    query: RefCell<String>,
    cwd: RefCell<PathBuf>,
    back: RefCell<Vec<PathBuf>>,
    forward: RefCell<Vec<PathBuf>>,
    hidden: Cell<bool>,
    scan_token: Cell<u64>,
    crumbs: gtk::Box,
    address: gtk::Stack,
    path_entry: gtk::Entry,
    shell: std::rc::Weak<Shell>,
    command: gtk::Box,
    main: gtk::Box,
    status: gtk::Label,
    free: gtk::Label,
    views: gtk::Stack,
    list: gtk::ColumnView,
    grid: gtk::GridView,
    preview_pane: gtk::Box,
    pane: Rc<Previewer>,
    quick: RefCell<Option<(gtk::Window, Rc<Previewer>)>>,
    columns: RefCell<HashMap<&'static str, gtk::ColumnViewColumn>>,
    root: RefCell<Option<Arc<root::Client>>>,
    in_trash: Cell<bool>,
    in_recent: Cell<bool>,
    in_starred: Cell<bool>,
    in_tag: Cell<bool>,
    dupe_alive: RefCell<Option<Arc<AtomicBool>>>,
    jobs: gtk::Box,
    inside: RefCell<Option<(PathBuf, String)>>,
    listings: RefCell<HashMap<PathBuf, Arc<Vec<Item>>>>,
    passwords: RefCell<HashMap<PathBuf, String>>,
    peek_token: Cell<u64>,
    write_btns: RefCell<Vec<gtk::Button>>,
    retry: RefCell<Option<Box<dyn FnOnce(&Rc<Win>)>>>,
    banner: gtk::Box,
    banner_text: gtk::Label,
    banner_btn: gtk::Button,
    back_btn: gtk::Button,
    forward_btn: gtk::Button,
    up_btn: gtk::Button,
    selection_btns: Vec<gtk::Button>,
    monitor: RefCell<Option<gio::FileMonitor>>,
    refresh_timer: RefCell<Option<glib::SourceId>>,
    thumbs: Rc<Thumbs>,
    thumbs_ready: Cell<bool>,
    preview_timer: RefCell<Option<glib::SourceId>>,
    opened_at: Instant,
    first_listing: Cell<bool>,
    inline_rename: RefCell<Option<PathBuf>>,
}

/// The shell's icons are Material Symbols, drawn as text. Using the same font is most of what makes
/// these buttons look like the rest of the desktop and not like a GTK app.
pub(crate) fn sym(glyph: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(glyph));
    label.add_css_class("sym");
    label
}

pub(crate) fn history_button(btn: gtk::Button, win: &Rc<Win>, from_back: bool) {
    let click = gtk::GestureClick::builder().button(3).build();
    let weak = Rc::downgrade(win);
    let anchor = btn.clone();
    click.connect_pressed(move |_, _, x, y| {
        let Some(this) = weak.upgrade() else { return };
        let stack: Vec<PathBuf> = if from_back {
            this.back.borrow().iter().rev().take(20).cloned().collect()
        } else {
            this.forward.borrow().iter().rev().take(20).cloned().collect()
        };
        if stack.is_empty() {
            return;
        }
        let menu = gio::Menu::new();
        for path in &stack {
            let label = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string_lossy().into_owned());
            let item = gio::MenuItem::new(Some(&label), None);
            let action = if from_back { "win.history-back-to" } else { "win.history-forward-to" };
            item.set_action_and_target_value(Some(action), Some(&path.to_string_lossy().to_variant()));
            menu.append_item(&item);
        }
        let pop = gtk::PopoverMenu::from_model_full(&menu, gtk::PopoverMenuFlags::NESTED);
        pop.set_parent(&anchor);
        pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        pop.popup();
    });
    btn.add_controller(click);
}

pub(crate) fn icon_button(glyph: &str, tip: &str, action: &str) -> gtk::Button {
    let b = gtk::Button::builder().tooltip_text(tip).action_name(action).build();
    b.set_child(Some(&sym(glyph)));
    b
}

pub(crate) fn chip(glyph: &str, words: &str, tip: &str, action: &str) -> gtk::Button {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    row.append(&sym(glyph));
    row.append(&gtk::Label::new(Some(words)));
    let b = gtk::Button::builder().tooltip_text(tip).action_name(action).child(&row).build();
    b.add_css_class("chip");
    b
}

impl Win {
    fn selected(&self) -> Vec<PathBuf> {
        let bits = self.selection.selection();
        let mut out = Vec::with_capacity(bits.size() as usize);
        if let Some((mut iter, first)) = gtk::BitsetIter::init_first(&bits) {
            let mut at = Some(first);
            while let Some(pos) = at {
                if let Some(obj) = self.selection.item(pos) {
                    out.push(entry_of(&obj).path.clone());
                }
                at = iter.next();
            }
        }
        out
    }

    fn selected_count(&self) -> u64 {
        self.selection.selection().size()
    }

    fn select_when_listed(self: &Rc<Self>, paths: Vec<PathBuf>, tries: u32, then: Option<Rc<dyn Fn(&Rc<Win>)>>) {
        let live: Vec<PathBuf> = paths.into_iter().filter(|p| p.exists()).collect();
        if live.is_empty() {
            return;
        }
        let rows = self.rows.borrow();
        let mut found = Vec::new();
        for path in &live {
            if let Some(pos) = rows.iter().position(|e| e.path == *path) {
                found.push(pos as u32);
            }
        }
        drop(rows);
        if !found.is_empty() {
            for (i, pos) in found.iter().enumerate() {
                self.selection.select_item(*pos, i == 0);
            }
            self.show_selection();
            if let Some(f) = then {
                f(self);
            }
            return;
        }
        if tries >= 40 {
            return;
        }
        let weak = Rc::downgrade(self);
        let again = then.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(100), move || {
            if let Some(w) = weak.upgrade() {
                w.select_when_listed(live, tries + 1, again);
            }
        });
    }

    fn navigate(self: &Rc<Self>, to: PathBuf, record: bool) {
        if record && *self.cwd.borrow() != to {
            self.back.borrow_mut().push(self.cwd.borrow().clone());
            self.forward.borrow_mut().clear();
        }
        *self.cwd.borrow_mut() = to.clone();
        self.cancel_inline_rename();
        self.query.borrow_mut().clear();
        self.filter.changed(gtk::FilterChange::LessStrict);
        if let Some(shell) = self.shell.upgrade() {
            if shell.active_win().is_some_and(|w| std::ptr::eq(w.as_ref(), self.as_ref())) {
                shell.search.set_text("");
            }
        }
        let inside = archive::locate(&to);
        *self.inside.borrow_mut() = inside.clone();
        let in_trash = trash::is_trash(&to);
        self.in_trash.set(in_trash);
        let in_recent = recent::is_view(&to);
        self.in_recent.set(in_recent);
        let in_starred = stars::is_view(&to);
        self.in_starred.set(in_starred);
        let in_tag = tags::is_view(&to);
        self.in_tag.set(in_tag);
        if let Some(where_col) = self.columns.borrow().get("where") {
            where_col.set_visible(in_trash);
        }
        if let Some(date_col) = self.columns.borrow().get("date") {
            date_col.set_title(Some(if in_trash { "Date Deleted" } else { "Date Modified" }));
        }
        if self.root.borrow().is_none() {
            self.retry.borrow_mut().take();
            self.banner.remove_css_class("admin");
            if in_trash {
                self.banner_text.set_text("Items here stay until you empty the Trash.");
                self.banner_btn.set_label("Empty Trash");
                self.banner.set_visible(true);
            } else { match &inside {
                Some((zip, _)) => {
                    let name = zip.file_name().unwrap_or_default().to_string_lossy();
                    self.banner_text.set_text(&if archive::is_editable(&name) { format!("Inside {name}. Changes here go straight into the archive.") } else { format!("Inside {name}. Extract it to change anything.") });
                    self.banner_btn.set_label("Extract All");
                    self.banner.set_visible(true);
                }
                None => self.banner.set_visible(false),
            } }
        }
        for b in self.write_btns.borrow().iter() {
            b.set_sensitive((inside.is_none() || self.editing().is_some()) && !in_trash && !in_recent && !in_starred && !in_tag);
        }
        let view = prefs::folder_view(&to.to_string_lossy()).unwrap_or_else(|| prefs::str_of("defaultView", "grid"));
        self.views.set_visible_child_name(if view == "list" { "list" } else { "grid" });
        self.rows.borrow_mut().clear();
        self.store.remove_all();
        self.rebuild_crumbs();
        self.back_btn.set_sensitive(!self.back.borrow().is_empty());
        self.forward_btn.set_sensitive(!self.forward.borrow().is_empty());
        self.up_btn.set_sensitive(to.parent().is_some() && !in_tag && !in_starred && !in_recent && !in_trash);
        if inside.is_some() || in_trash || in_recent || in_starred || in_tag {
            *self.monitor.borrow_mut() = None;
        } else {
            self.watch(&to);
        }
        self.reload();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
            if let Some(this) = weak.upgrade() {
                this.update_free();
            }
        });
        self.show_selection();
        self.focus_view();
        if let Some(shell) = self.shell.upgrade() {
            shell.sync();
        }
    }

    /// Half a window has no room for labelled buttons or the Kind column.
    fn set_compact(&self, on: bool) {
        let mut child = self.command.first_child();
        while let Some(button) = child {
            if let Some(row) = button.first_child() {
                if let Some(words) = row.last_child() {
                    words.set_visible(!on);
                }
            }
            child = button.next_sibling();
        }
        if let Some(col) = self.columns.borrow().get("kind") {
            col.set_visible(!on);
        }
    }

    fn title_text(&self) -> String {
        let at = self.cwd.borrow();
        if *at == trash::home_files() {
            return "Trash".to_string();
        }
        if recent::is_view(at.as_path()) {
            return "Recent".to_string();
        }
        if stars::is_view(at.as_path()) {
            return "Starred".to_string();
        }
        if tags::is_view(at.as_path()) {
            return tags::name_of_view(at.as_path()).unwrap_or_else(|| "Tags".to_string());
        }
        if *at == glib::home_dir() {
            return "Home".to_string();
        }
        at.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Computer".to_string())
    }

    /// Folders change under you: a download lands, another window pastes. A short delay gathers a
    /// burst into one read, and only the rows that differ are touched.
    fn watch(self: &Rc<Self>, dir: &Path) {
        let monitor = gio::File::for_path(dir).monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE).ok();
        if let Some(m) = &monitor {
            let weak = Rc::downgrade(self);
            m.connect_changed(move |_, _, _, _| {
                let Some(this) = weak.upgrade() else { return };
                if let Some(old) = this.refresh_timer.borrow_mut().take() {
                    old.remove();
                }
                let again = Rc::downgrade(&this);
                let id = glib::timeout_add_local_once(std::time::Duration::from_millis(150), move || {
                    if let Some(this) = again.upgrade() {
                        this.refresh_timer.borrow_mut().take();
                        this.reload();
                        this.update_free();
                    }
                });
                *this.refresh_timer.borrow_mut() = Some(id);
            });
        }
        *self.monitor.borrow_mut() = monitor;
    }

    fn reload(self: &Rc<Self>) {
        let token = self.scan_token.get() + 1;
        self.scan_token.set(token);
        let inside = self.inside.borrow().clone();
        if let Some((zip, folder)) = inside {
            self.reload_archive(zip, folder, token);
            return;
        }
        if *self.cwd.borrow() == trash::home_files() {
            self.reload_trash(token);
            return;
        }
        if recent::is_view(&*self.cwd.borrow()) {
            self.reload_recent(token);
            return;
        }
        if stars::is_view(&*self.cwd.borrow()) {
            self.reload_starred(token);
            return;
        }
        if tags::is_view(&*self.cwd.borrow()) {
            self.reload_tag(token);
            return;
        }
        let (dir, hidden, query, deep) = (
            self.cwd.borrow().clone(),
            self.hidden.get(),
            self.query.borrow().clone(),
            !self.in_trash.get()
                && !self.in_recent.get()
                && !self.in_starred.get()
                && !self.in_tag.get()
                && self.inside.borrow().is_none(),
        );
        let root = self.root.borrow().clone();
        let weak = Rc::downgrade(self);
        let started = Instant::now();
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || match root {
                Some(c) => c.list(&dir, hidden).map_err(|e| (e, false)),
                None if query.is_empty() || !deep => {
                    core::scan(&dir, hidden).map_err(|e| (e.to_string(), e.kind() == std::io::ErrorKind::PermissionDenied))
                }
                None => core::scan_deep(&dir, &query, hidden).map_err(|e| (e.to_string(), e.kind() == std::io::ErrorKind::PermissionDenied)),
            })
            .await;
            let Some(this) = weak.upgrade() else { return };
            // You've already gone somewhere else: this answer is about a folder nobody is looking at.
            if this.scan_token.get() != token {
                return;
            }
            match result {
                Ok(Ok(rows)) => this.apply(rows, started),
                Ok(Err((_, true))) => this.need_admin("You need administrator access to see this folder.", Box::new(|w| w.reload())),
                Ok(Err((e, _))) => this.status.set_text(&format!("Can't open this folder: {e}")),
                Err(_) => this.status.set_text("Can't open this folder."),
            }
        });
    }

    fn apply(self: &Rc<Self>, rows: Vec<Entry>, started: Instant) {
        let read = started.elapsed();
        {
            let old = self.rows.borrow();
            if let Some((at, remove, insert)) = core::minimal_change(&old, &rows) {
                let objs: Vec<glib::BoxedAnyObject> = insert.iter().cloned().map(glib::BoxedAnyObject::new).collect();
                self.store.splice(at as u32, remove as u32, &objs);
            }
        }
        *self.rows.borrow_mut() = rows;
        self.show_selection();
        if trace() {
            eprintln!("listing: {} rows, read {:?}, on screen {:?}", self.rows.borrow().len(), read, started.elapsed());
        }
        if !self.first_listing.replace(true) {
            if trace() {
                eprintln!("first listing {:?} after the window was made", self.opened_at.elapsed());
            }
            let weak = Rc::downgrade(self);
            glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
                if let Some(this) = weak.upgrade() {
                    this.thumbs_ready.set(true);
                }
            });
        }
    }

    fn rebuild_crumbs(self: &Rc<Self>) {
        while let Some(child) = self.crumbs.first_child() {
            self.crumbs.remove(&child);
        }
        let cwd = self.cwd.borrow().clone();
        if tags::is_view(&cwd) {
            let label = tags::name_of_view(&cwd).unwrap_or_else(|| "Tags".to_string());
            let b = gtk::Button::with_label(&label);
            let weak = Rc::downgrade(self);
            let path = cwd.clone();
            b.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.navigate(path.clone(), true);
                }
            });
            self.crumbs.append(&b);
            return;
        }
        let home = glib::home_dir();
        let mut stops: Vec<(String, PathBuf)> = Vec::new();
        let mut at = Some(cwd.as_path());
        let trash_home = trash::home_files();
        while let Some(p) = at {
            if p == trash_home {
                stops.push(("Trash".into(), p.to_path_buf()));
                break;
            }
            if p == home {
                stops.push(("Home".into(), p.to_path_buf()));
                break;
            }
            stops.push((p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Computer".into()), p.to_path_buf()));
            at = p.parent();
        }
        for (i, (label, path)) in stops.into_iter().rev().enumerate() {
            if i > 0 {
                let sep = sym("chevron_right");
                sep.add_css_class("crumb-sep");
                self.crumbs.append(&sep);
            }
            let b = gtk::Button::with_label(&label);
            let weak = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.navigate(path.clone(), true);
                }
            });
            self.crumbs.append(&b);
        }
    }

    fn update_free(self: &Rc<Self>) {
        let dir = self.inside.borrow().as_ref().map(|(zip, _)| zip.clone()).unwrap_or_else(|| self.cwd.borrow().clone());
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let free = gio::spawn_blocking(move || {
                gio::File::for_path(&dir)
                    .query_filesystem_info("filesystem::free", gio::Cancellable::NONE)
                    .ok()
                    .map(|i| i.attribute_uint64("filesystem::free"))
            })
            .await;
            if let (Some(this), Ok(Some(n))) = (weak.upgrade(), free) {
                this.free.set_text(&format!("{} available", core::human(n)));
            }
        });
    }

    fn focus_view(&self) {
        if self.views.visible_child_name().as_deref() == Some("grid") {
            self.grid.grab_focus();
        } else {
            self.list.grab_focus();
        }
    }

    // ---------- what's selected: status bar, buttons and the preview pane ----------
    fn show_selection(self: &Rc<Self>) {
        let count = self.selected_count();
        let shown = self.selection.n_items();
        let inside = self.in_archive();
        for (i, b) in self.selection_btns.iter().enumerate() {
            // Copy is the one thing that works inside an archive: it takes a copy out.
            let in_trash = self.in_trash.get();
            // Cut is first: inside an archive, moving out is Copy then Delete.
            let editable = inside && self.editing().is_some();
            b.set_sensitive(count > 0 && (i == 1 || (!inside && (!in_trash || i == 3)) || (editable && i != 0)));
        }
        let items = |n: u64| if n == 1 { "1 item".to_string() } else { format!("{n} items") };
        self.status.set_text(&if count == 0 { items(shown as u64) } else { format!("{} of {} selected", count, items(shown as u64)) });
        if let Some(id) = self.preview_timer.borrow_mut().take() {
            id.remove();
        }
        let weak = Rc::downgrade(self);
        let id = glib::timeout_add_local(std::time::Duration::from_millis(120), move || {
            if let Some(this) = weak.upgrade() {
                this.update_preview(this.selected_count());
                *this.preview_timer.borrow_mut() = None;
            }
            glib::ControlFlow::Break
        });
        *self.preview_timer.borrow_mut() = Some(id);
    }

    fn shown(&self, count: u64) -> Shown {
        match count {
            0 => Shown::Folder(self.cwd.borrow().clone()),
            1 => {
                let bits = self.selection.selection();
                match self.selection.item(bits.nth(0)) {
                    Some(obj) => Shown::One(entry_of(&obj).clone()),
                    None => Shown::Folder(self.cwd.borrow().clone()),
                }
            }
            n => Shown::Many(n, self.selected_entries().iter().filter(|e| !e.is_dir).map(|e| e.size).sum()),
        }
    }

    fn update_preview(self: &Rc<Self>, count: u64) {
        if self.preview_pane.is_visible() {
            self.pane.show(&self.shown(count));
        } else {
            self.pane.stop();
        }
        self.peek_inside(count);
        if let Some((window, previewer)) = self.quick.borrow().as_ref() {
            let shown = self.shown(count);
            window.set_title(Some(&shown_title(&shown)));
            previewer.show(&shown);
        }
    }

    // ---------- inside an archive ----------
    /// The archive being browsed, if what you're asking for can be done to it.
    fn editing(&self) -> Option<(PathBuf, String)> {
        self.inside.borrow().clone().filter(|(zip, _)| archive::is_editable(&zip.file_name().unwrap_or_default().to_string_lossy()))
    }

    /// Runs one change to an archive, asking for the password if it turns out to need one.
    fn edit_archive(self: &Rc<Self>, zip: PathBuf, op: Arc<dyn Fn(&Path, Option<&str>) -> Result<(), Problem> + Send + Sync>) {
        let password = self.passwords.borrow().get(&zip).cloned();
        let had_password = password.is_some();
        self.status.set_text("Updating the archive…");
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let (z, o) = (zip.clone(), op.clone());
            let done = gio::spawn_blocking(move || o(&z, password.as_deref())).await.unwrap_or(Err(Problem::Other("it stopped unexpectedly".into())));
            let Some(this) = weak.upgrade() else { return };
            match done {
                Ok(()) => {
                    this.listings.borrow_mut().remove(&zip);
                    this.status.set_text("Done.");
                    this.reload();
                }
                Err(Problem::NeedPassword) | Err(Problem::WrongPassword) => {
                    let again = zip.clone();
                    this.ask_password(&zip, had_password, Box::new(move |w, pw| {
                        w.passwords.borrow_mut().insert(again.clone(), pw);
                        w.edit_archive(again, op);
                    }), Box::new(|w| w.status.set_text("Left as it was.")));
                }
                Err(Problem::Other(e)) => this.status.set_text(&format!("Couldn't change the archive: {e}")),
            }
        });
    }

    fn add_to_archive(self: &Rc<Self>, paths: Vec<PathBuf>) {
        let Some((zip, folder)) = self.editing() else {
            self.writable();
            return;
        };
        self.edit_archive(zip, Arc::new(move |z, pw| archive::add(z, &paths, &folder, pw)));
    }

    /// Takes the selection out to a temporary folder now, so another app can receive it. It has to
    /// happen before the drag starts, so very large or locked items ask you to extract them instead.
    fn drag_out(&self) -> Option<Vec<PathBuf>> {
        let (zip, _) = self.inside.borrow().clone()?;
        let picked = self.selected_entries();
        let wanted = self.selected_inner();
        if picked.iter().map(|e| e.size).sum::<u64>() > DRAG_LIMIT || picked.iter().any(|e| e.is_dir && e.size > DRAG_LIMIT) {
            self.status.set_text("That's too large to drag out. Use Extract To instead.");
            return None;
        }
        let password = self.passwords.borrow().get(&zip).cloned();
        let dest = temp_dir("drag").join(format!("{}", self.scan_token.get()));
        let _ = std::fs::remove_dir_all(&dest);
        if archive::extract(&zip, Some(&wanted), &dest, password.as_deref()).is_err() {
            self.status.set_text("That's protected. Use Extract To, which asks for the password.");
            return None;
        }
        Some(wanted.iter().map(|w| dest.join(Path::new(w).file_name().unwrap_or_default())).collect())
    }

    fn in_archive(&self) -> bool {
        self.inside.borrow().is_some()
    }

    /// False, and says why, when what you're looking at can't be changed.
    fn writable(&self) -> bool {
        if self.in_archive() {
            self.status.set_text("This kind of archive can't be changed. Extract it first.");
            return false;
        }
        if self.in_trash.get() {
            self.status.set_text("This is in the Trash. Restore it first.");
            return false;
        }
        if self.in_recent.get() {
            self.status.set_text("Pick a file to open it.");
            return false;
        }
        if self.in_starred.get() {
            self.status.set_text("Pick a file to open it.");
            return false;
        }
        if self.in_tag.get() {
            self.status.set_text("Pick a file to open it.");
            return false;
        }
        true
    }

    // ---------- the Trash ----------
    fn reload_trash(self: &Rc<Self>, token: u64) {
        let started = Instant::now();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let items = gio::spawn_blocking(trash::list).await.unwrap_or_default();
            let Some(this) = weak.upgrade() else { return };
            if this.scan_token.get() != token {
                return;
            }
            ORIGINS.with(|o| {
                let mut o = o.borrow_mut();
                o.clear();
                for t in &items {
                    o.insert(t.file.clone(), t.orig.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
                }
            });
            let rows = items.into_iter().map(|t| Entry { name: t.name, path: t.file, is_dir: t.is_dir, size: t.size, mtime: t.deleted }).collect();
            this.apply(rows, started);
        });
    }

    fn reload_recent(self: &Rc<Self>, token: u64) {
        let started = Instant::now();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let rows = gio::spawn_blocking(|| recent::entries(200)).await.unwrap_or_default();
            let Some(this) = weak.upgrade() else { return };
            if this.scan_token.get() != token {
                return;
            }
            this.apply(rows, started);
        });
    }

    fn reload_starred(self: &Rc<Self>, token: u64) {
        let started = Instant::now();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let rows = gio::spawn_blocking(stars::entries).await.unwrap_or_default();
            let Some(this) = weak.upgrade() else { return };
            if this.scan_token.get() != token {
                return;
            }
            this.apply(rows, started);
        });
    }

    fn reload_tag(self: &Rc<Self>, token: u64) {
        let tag = tags::name_of_view(&*self.cwd.borrow()).unwrap_or_default();
        let started = Instant::now();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let rows = gio::spawn_blocking(move || tags::entries_for(&tag)).await.unwrap_or_default();
            let Some(this) = weak.upgrade() else { return };
            if this.scan_token.get() != token {
                return;
            }
            this.apply(rows, started);
        });
    }

    fn restore(self: &Rc<Self>) {
        let files = self.selected();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let (n, failed, back) = gio::spawn_blocking(move || {
                let n = files.len();
                let mut back = Vec::new();
                for f in &files {
                    if let Some(t) = trash::find(f) {
                        if let Ok(place) = trash::restore(&t) {
                            back.push(place);
                        }
                    }
                }
                (n, n - back.len(), back)
            })
            .await
            .unwrap_or((0, 0, Vec::new()));
            let (n, failed, back) = (n, failed, back);
            if let Some(this) = weak.upgrade() {
                if !back.is_empty() {
                    remember(Undo::Trash(back));
                }
                this.reload();
                this.status.set_text(&if failed > 0 { format!("{failed} of {n} items couldn't be restored.") } else if n == 1 { "Put back.".to_string() } else { format!("Put back {n} items.") });
            }
        });
    }

    fn empty_trash(self: &Rc<Self>) {
        let n = trash::list().len();
        if n == 0 {
            self.status.set_text("The Trash is already empty.");
            return;
        }
        let what = if n == 1 { "the 1 item".to_string() } else { format!("all {n} items") };
        self.confirm(&format!("Permanently delete {what} in the Trash?"), "This can't be undone.", "Empty Trash", Box::new(|w| {
            let weak = Rc::downgrade(w);
            glib::spawn_future_local(async move {
                let failed = gio::spawn_blocking(trash::empty).await.unwrap_or(0);
                if let Some(this) = weak.upgrade() {
                    this.reload();
                    this.status.set_text(&if failed > 0 { format!("{failed} items couldn't be deleted.") } else { "The Trash is empty.".to_string() });
                }
            });
        }));
    }

    /// Shift+Delete. Skips the Trash, says so first, and focuses Keep so a stray Enter is harmless.
    fn delete_permanently(self: &Rc<Self>) {
        if let Some((zip, _)) = self.editing() {
            let wanted = self.selected_inner();
            if wanted.is_empty() {
                return;
            }
            let n = wanted.len();
            self.confirm(&format!("Delete {} from the archive?", if n == 1 { "this item".to_string() } else { format!("these {n} items") }), "There's no Trash inside an archive. This can't be undone.", "Delete", Box::new(move |w| {
                w.edit_archive(zip, Arc::new(move |z, pw| archive::remove(z, &wanted, pw)));
            }));
            return;
        }
        if self.in_archive() {
            self.writable();
            return;
        }
        let paths = self.selected();
        if paths.is_empty() {
            return;
        }
        let n = paths.len();
        let what = match paths.as_slice() {
            [one] => format!("\u{201c}{}\u{201d}", self.selected_entries().first().map(|e| e.name.clone()).unwrap_or_else(|| one.to_string_lossy().into_owned())),
            _ => format!("these {n} items"),
        };
        let in_trash = self.in_trash.get();
        self.confirm(&format!("Permanently delete {what}?"), "It won't go to the Trash, and this can't be undone.", "Delete", Box::new(move |w| {
            if w.root.borrow().is_some() {
                return w.delete_as_admin(paths);
            }
            let weak = Rc::downgrade(w);
            glib::spawn_future_local(async move {
                let denied = gio::spawn_blocking(move || {
                    let mut denied = Vec::new();
                    let mut other = None;
                    for p in paths {
                        let done = if in_trash && let Some(t) = trash::find(&p) { trash::delete(&t) } else { trash::delete_permanently(&p) };
                        match done {
                            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => denied.push(p),
                            Err(e) => other = Some(e.to_string()),
                            Ok(()) => {}
                        }
                    }
                    (denied, other)
                })
                .await
                .unwrap_or_default();
                let Some(this) = weak.upgrade() else { return };
                this.reload();
                this.status.set_text(&denied.1.map(|e| format!("Couldn't delete: {e}")).unwrap_or("Deleted.".to_string()));
                if !denied.0.is_empty() {
                    let list = denied.0;
                    this.need_admin("You need administrator access to delete this.", Box::new(move |w| w.delete_as_admin(list)));
                }
            });
        }));
    }

    fn reload_archive(self: &Rc<Self>, zip: PathBuf, folder: String, token: u64) {
        let started = Instant::now();
        let cached = self.listings.borrow().get(&zip).cloned();
        if let Some(items) = cached {
            self.apply(archive::children(&items, &zip, &folder), started);
            return;
        }
        let password = self.passwords.borrow().get(&zip).cloned();
        self.status.set_text("Reading the archive…");
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let path = zip.clone();
            let had_password = password.is_some();
            let listed = gio::spawn_blocking(move || archive::list(&path, password.as_deref())).await.unwrap_or(Err(Problem::Other("it stopped unexpectedly".into())));
            let Some(this) = weak.upgrade() else { return };
            if this.scan_token.get() != token {
                return;
            }
            match listed {
                Ok(items) => {
                    let items = Arc::new(items);
                    this.listings.borrow_mut().insert(zip.clone(), items.clone());
                    this.apply(archive::children(&items, &zip, &folder), started);
                }
                Err(Problem::NeedPassword) | Err(Problem::WrongPassword) => {
                    let leave = zip.parent().map(Path::to_path_buf).unwrap_or_else(glib::home_dir);
                    let store = zip.clone();
                    this.ask_password(&zip, had_password, Box::new(move |w, pw| {
                        w.passwords.borrow_mut().insert(store, pw);
                        w.reload();
                    }), Box::new(move |w| w.navigate(leave, false)));
                }
                Err(Problem::Other(e)) => this.status.set_text(&format!("Can't read this archive: {e}")),
            }
        });
    }

    fn ask_password(self: &Rc<Self>, zip: &Path, wrong: bool, then: Box<dyn FnOnce(&Rc<Win>, String)>, cancel: Box<dyn FnOnce(&Rc<Win>)>) {
        let name = zip.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let dialog = gtk::Window::builder().transient_for(&self.window).modal(true).title("Password").default_width(400).resizable(false).build();
        dialog.add_css_class("sea");
        dialog.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
        body.add_css_class("dialog-body");
        let head = gtk::Label::builder().label(format!("{name} is protected")).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).build();
        head.add_css_class("dialog-title");
        let note = gtk::Label::builder().label(if wrong { "That password wasn't right. Try again." } else { "Enter its password to open it." }).xalign(0.0).wrap(true).build();
        note.add_css_class("dim");
        let entry = gtk::PasswordEntry::builder().show_peek_icon(true).hexpand(true).build();
        let row = gtk::Box::builder().spacing(8).halign(gtk::Align::End).margin_top(4).build();
        let no = gtk::Button::with_label("Cancel");
        no.add_css_class("plain");
        let yes = gtk::Button::with_label("Open");
        yes.add_css_class("accent");
        row.append(&no);
        row.append(&yes);
        body.append(&head);
        body.append(&note);
        body.append(&entry);
        body.append(&row);
        dialog.set_child(Some(&body));
        // Exactly one of these runs, however the dialog ends.
        let then = Rc::new(RefCell::new(Some(then)));
        let cancel = Rc::new(RefCell::new(Some(cancel)));
        let submit: Rc<dyn Fn()> = {
            let (weak, then, cancel, d, entry) = (Rc::downgrade(self), then.clone(), cancel.clone(), dialog.downgrade(), entry.clone());
            Rc::new(move || {
                let text = entry.text().to_string();
                if text.is_empty() {
                    return;
                }
                cancel.borrow_mut().take();
                if let (Some(this), Some(f)) = (weak.upgrade(), then.borrow_mut().take()) {
                    f(&this, text);
                }
                if let Some(d) = d.upgrade() {
                    d.close();
                }
            })
        };
        let go = submit.clone();
        entry.connect_activate(move |_| go());
        yes.connect_clicked(move |_| submit());
        let d = dialog.downgrade();
        no.connect_clicked(move |_| {
            if let Some(d) = d.upgrade() {
                d.close();
            }
        });
        let keys = gtk::EventControllerKey::new();
        let d = dialog.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(d) = d.upgrade() {
                    d.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        dialog.add_controller(keys);
        let weak = Rc::downgrade(self);
        dialog.connect_close_request(move |_| {
            if let (Some(this), Some(f)) = (weak.upgrade(), cancel.borrow_mut().take()) {
                f(&this);
            }
            glib::Propagation::Proceed
        });
        dialog.present();
        entry.grab_focus();
    }

    /// Extracts, asking for the password if it turns out to need one, and trying again if it's wrong.
    fn extract_run(self: &Rc<Self>, zip: PathBuf, wanted: Option<Vec<String>>, dest: PathBuf, done: Box<dyn FnOnce(&Rc<Win>, PathBuf)>) {
        let password = self.passwords.borrow().get(&zip).cloned();
        let had_password = password.is_some();
        self.status.set_text("Extracting…");
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let (z, w, d) = (zip.clone(), wanted.clone(), dest.clone());
            let result = gio::spawn_blocking(move || archive::extract(&z, w.as_deref(), &d, password.as_deref())).await.unwrap_or(Err(Problem::Other("it stopped unexpectedly".into())));
            let Some(this) = weak.upgrade() else { return };
            match result {
                Ok(()) => done(&this, dest),
                Err(Problem::NeedPassword) | Err(Problem::WrongPassword) => {
                    let again = zip.clone();
                    this.ask_password(&zip, had_password, Box::new(move |win, pw| {
                        win.passwords.borrow_mut().insert(again.clone(), pw);
                        win.extract_run(again, wanted, dest, done);
                    }), Box::new(|win| win.status.set_text("Left as it was.")));
                }
                Err(Problem::Other(e)) => this.status.set_text(&format!("Couldn't extract: {e}")),
            }
        });
    }

    /// The selected items, as paths within the archive being browsed.
    fn selected_inner(&self) -> Vec<String> {
        let Some((zip, _)) = self.inside.borrow().clone() else { return Vec::new() };
        self.selected().iter().filter_map(|p| p.strip_prefix(&zip).ok().map(|r| r.to_string_lossy().into_owned())).collect()
    }

    fn extract_all(self: &Rc<Self>) {
        let Some((zip, _)) = self.inside.borrow().clone() else { return };
        let parent = zip.parent().map(Path::to_path_buf).unwrap_or_else(glib::home_dir);
        let stem = preview::archive_stem(&zip.file_name().unwrap_or_default().to_string_lossy());
        let dest = core::free_name(&parent, stem.as_ref());
        self.extract_run(zip, None, dest, Box::new(|w, dest| {
            let at = archive::collapse_single_folder(&dest);
            w.status.set_text("Extracted.");
            // As Explorer does: show what you just took out.
            w.navigate(at, true);
        }));
    }

    fn extract_here(self: &Rc<Self>) {
        if self.in_archive() {
            return self.extract_all();
        }
        let dir = self.cwd.borrow().clone();
        for e in self.selected_entries().into_iter().filter(|e| preview::is_archive(&e.name)) {
            let dest = core::free_name(&dir, preview::archive_stem(&e.name).as_ref());
            self.extract_run(e.path, None, dest, Box::new(|w, dest| {
                archive::collapse_single_folder(&dest);
                w.status.set_text("Extracted.");
                w.reload();
            }));
        }
    }

    fn extract_to(self: &Rc<Self>) {
        let inside = self.inside.borrow().clone();
        let picks: Vec<PathBuf> = match &inside {
            Some((zip, _)) => vec![zip.clone()],
            None => self.selected_entries().into_iter().filter(|e| preview::is_archive(&e.name)).map(|e| e.path).collect(),
        };
        if picks.is_empty() {
            return;
        }
        let wanted = if inside.is_some() && self.selected_count() > 0 { Some(self.selected_inner()) } else { None };
        let dialog = gtk::FileDialog::builder().title("Extract to").modal(true).build();
        let parent = self.window.clone();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(folder) = dialog.select_folder_future(Some(&parent)).await else { return };
            let (Some(this), Some(folder)) = (weak.upgrade(), folder.path()) else { return };
            for zip in picks {
                let picked_some = wanted.is_some();
                let dest = if picked_some { folder.clone() } else {
                    core::free_name(&folder, preview::archive_stem(&zip.file_name().unwrap_or_default().to_string_lossy()).as_ref())
                };
                this.extract_run(zip, wanted.clone(), dest, Box::new(move |w, dest| {
                    if !picked_some {
                        archive::collapse_single_folder(&dest);
                    }
                    w.status.set_text("Extracted.");
                }));
            }
        });
    }

    fn copy_out(self: &Rc<Self>, zip: PathBuf) {
        let wanted = self.selected_inner();
        if wanted.is_empty() {
            return;
        }
        let token = self.peek_token.get();
        let dest = temp_dir("clip").join(format!("{}-{token}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dest);
        let leaves: Vec<PathBuf> = wanted.iter().map(|w| dest.join(Path::new(w).file_name().unwrap_or_default())).collect();
        self.extract_run(zip, Some(wanted), dest, Box::new(move |w, _| w.offer_clipboard(leaves, Mode::Copy)));
    }

    fn open_inside(self: &Rc<Self>, e: Entry) {
        let Some((zip, _)) = self.inside.borrow().clone() else { return };
        let Ok(inner) = e.path.strip_prefix(&zip).map(|p| p.to_string_lossy().into_owned()) else { return };
        // Not in memory-backed runtime storage, because this can be a very large file.
        let dest = glib::user_cache_dir().join("sea-files/open").join(format!("{}-{}", std::process::id(), self.scan_token.get()));
        let leaf = dest.join(&e.name);
        self.extract_run(zip, Some(vec![inner]), dest, Box::new(move |w, _| {
            w.status.set_text("");
            if let Err(err) = gio::AppInfo::launch_default_for_uri(&gio::File::for_path(&leaf).uri(), None::<&gio::AppLaunchContext>) {
                w.status.set_text(&format!("Couldn't open that: {err}"));
            }
        }));
    }

    /// A file inside an archive has no path yet, so it's taken out quietly to preview it. Never prompts:
    /// a password box shouldn't pop up because you moved the selection. Decrypted previews stay in
    /// memory-backed storage, and go when the app closes.
    fn peek_inside(self: &Rc<Self>, count: u64) {
        let token = self.peek_token.get() + 1;
        self.peek_token.set(token);
        let Some((zip, _)) = self.inside.borrow().clone() else { return };
        if count != 1 {
            return;
        }
        let Shown::One(e) = self.shown(1) else { return };
        if e.is_dir || e.size > PEEK_LIMIT {
            return;
        }
        let Ok(inner) = e.path.strip_prefix(&zip).map(|p| p.to_string_lossy().into_owned()) else { return };
        let password = self.passwords.borrow().get(&zip).cloned();
        if password.is_none() && self.listings.borrow().get(&zip).is_some_and(|items| archive::is_encrypted(items, &inner)) {
            return;
        }
        let base = temp_dir("peek");
        let dest = base.join(token.to_string());
        let leaf = dest.join(&e.name);
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let (z, d, b) = (zip.clone(), dest.clone(), base.clone());
            let ok = gio::spawn_blocking(move || {
                // Only the newest is ever kept.
                if let Ok(old) = std::fs::read_dir(&b) {
                    old.flatten().for_each(|o| { let _ = std::fs::remove_dir_all(o.path()); });
                }
                archive::extract(&z, Some(&[inner]), &d, password.as_deref()).is_ok()
            })
            .await
            .unwrap_or(false);
            let Some(this) = weak.upgrade() else { return };
            if !ok || this.peek_token.get() != token {
                return;
            }
            let real = Shown::One(Entry { path: leaf, ..e });
            if this.preview_pane.is_visible() {
                this.pane.show(&real);
            }
            if let Some((_, p)) = this.quick.borrow().as_ref() {
                p.show(&real);
            }
        });
    }

    // ---------- Quick Look: Space, as on a Mac ----------
    fn quick_look(self: &Rc<Self>) {
        // Taken first: closing runs the close handler, which looks at this same cell.
        let open = self.quick.borrow_mut().take();
        if let Some((window, _)) = open {
            window.close();
            return;
        }
        let count = self.selected_count();
        if count == 0 {
            return;
        }
        // Quick Look is the loud one. The pane goes quiet so one file can't play twice.
        self.pane.stop();
        // Sized to the screen, as on a Mac: a document needs the room to be read.
        let (mut width, mut height) = (980, 720);
        if let Some(monitor) = self.window.surface().and_then(|s| gdk::prelude::DisplayExt::monitor_at_surface(&s.display(), &s)) {
            let g = monitor.geometry();
            width = (g.width() * 72 / 100).clamp(640, 1500);
            height = (g.height() * 90 / 100).clamp(480, 1400);
        }
        let window = gtk::Window::builder().transient_for(&self.window).title("Quick Look").default_width(width).default_height(height).build();
        window.add_css_class("sea");
        window.add_css_class("quicklook");
        window.set_title(Some(&shown_title(&self.shown(count))));
        let previewer = Previewer::new(true);
        window.set_child(Some(&previewer.root));
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, state| {
            let Some(this) = weak.upgrade() else { return glib::Propagation::Proceed };
            match key {
                gdk::Key::space | gdk::Key::Escape => this.quick_look(),
                gdk::Key::Up | gdk::Key::Down => {
                    let down = key == gdk::Key::Down;
                    let read = this.quick.borrow().as_ref().is_some_and(|(_, p)| p.scroll_reader(down));
                    if !read {
                        this.step_selection(if down { 1 } else { -1 });
                    }
                }
                gdk::Key::Left => this.step_selection(-1),
                gdk::Key::Right => this.step_selection(1),
                gdk::Key::plus | gdk::Key::equal | gdk::Key::KP_Add | gdk::Key::minus | gdk::Key::KP_Subtract | gdk::Key::_0 if state.contains(gdk::ModifierType::CONTROL_MASK) => {
                    if let Some((_, p)) = this.quick.borrow().as_ref() {
                        p.zoom_by(match key {
                            gdk::Key::minus | gdk::Key::KP_Subtract => -1,
                            gdk::Key::_0 => 0,
                            _ => 1,
                        });
                    }
                }
                gdk::Key::Page_Up | gdk::Key::Page_Down => {
                    if let Some((_, p)) = this.quick.borrow().as_ref() {
                        p.turn_page(if key == gdk::Key::Page_Up { -1 } else { 1 });
                    }
                }
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        });
        window.add_controller(keys);
        let weak = Rc::downgrade(self);
        let held = previewer.clone();
        window.connect_close_request(move |_| {
            held.stop();
            if let Some(this) = weak.upgrade() {
                this.quick.borrow_mut().take();
                this.show_selection();
            }
            glib::Propagation::Proceed
        });
        previewer.show(&self.shown(count));
        window.present();
        *self.quick.borrow_mut() = Some((window, previewer));
    }

    fn step_selection(self: &Rc<Self>, step: i32) {
        let bits = self.selection.selection();
        let at = if bits.size() > 0 { bits.nth(0) as i32 + step } else { 0 };
        if at < 0 || at >= self.selection.n_items() as i32 {
            return;
        }
        self.selection.select_item(at as u32, true);
        if self.views.visible_child_name().as_deref() == Some("grid") {
            self.grid.scroll_to(at as u32, gtk::ListScrollFlags::NONE, None);
        } else {
            self.list.scroll_to(at as u32, None::<&gtk::ColumnViewColumn>, gtk::ListScrollFlags::NONE, None);
        }
    }

    // ---------- administrator ----------
    /// Explorer's "You'll need to provide administrator permission" with its Continue button.
    fn need_admin(self: &Rc<Self>, why: &str, retry: Box<dyn FnOnce(&Rc<Win>)>) {
        *self.retry.borrow_mut() = Some(retry);
        self.banner.remove_css_class("admin");
        self.banner_text.set_text(why);
        self.banner_btn.set_label("Continue");
        self.banner.set_visible(true);
    }

    fn banner_pressed(self: &Rc<Self>) {
        if self.in_trash.get() && self.root.borrow().is_none() {
            return self.empty_trash();
        }
        if self.in_archive() && self.root.borrow().is_none() {
            return self.extract_all();
        }
        if self.root.borrow().is_some() {
            *self.root.borrow_mut() = None;
            self.banner.set_visible(false);
            self.status.set_text("Back to your normal access.");
            self.reload();
        } else {
            self.enable_admin();
        }
    }

    fn enable_admin(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        if self.root.borrow().is_some() {
            return;
        }
        self.status.set_text("Waiting for your password…");
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let started = gio::spawn_blocking(root::Client::start).await;
            let Some(this) = weak.upgrade() else { return };
            match started {
                Ok(Ok(client)) => {
                    *this.root.borrow_mut() = Some(Arc::new(client));
                    this.banner.add_css_class("admin");
                    this.banner_text.set_text("Administrator mode. Changes in this window apply to the whole system, and deleting skips the Trash.");
                    this.banner_btn.set_label("Stop");
                    this.banner.set_visible(true);
                    this.status.set_text("");
                    match this.retry.borrow_mut().take() {
                        Some(retry) => retry(&this),
                        None => this.reload(),
                    }
                }
                Ok(Err(e)) => this.status.set_text(&e),
                Err(_) => this.status.set_text("The password prompt stopped unexpectedly."),
            }
        });
    }

    // ---------- yes or no ----------
    fn confirm(self: &Rc<Self>, title: &str, detail: &str, verb: &str, then: Box<dyn FnOnce(&Rc<Win>)>) {
        let dialog = gtk::Window::builder().transient_for(&self.window).modal(true).title(title).default_width(380).resizable(false).build();
        dialog.add_css_class("sea");
        dialog.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
        body.add_css_class("dialog-body");
        let head = gtk::Label::builder().label(title).xalign(0.0).wrap(true).build();
        head.add_css_class("dialog-title");
        body.append(&head);
        if !detail.is_empty() {
            let d = gtk::Label::builder().label(detail).xalign(0.0).wrap(true).build();
            d.add_css_class("dim");
            body.append(&d);
        }
        let row = gtk::Box::builder().spacing(8).halign(gtk::Align::End).margin_top(10).build();
        let keep = gtk::Button::with_label("Keep");
        keep.add_css_class("plain");
        let yes = gtk::Button::with_label(verb);
        yes.add_css_class("danger");
        row.append(&keep);
        row.append(&yes);
        body.append(&row);
        dialog.set_child(Some(&body));
        let close = dialog.downgrade();
        keep.connect_clicked(move |_| {
            if let Some(d) = close.upgrade() {
                d.close();
            }
        });
        let close = dialog.downgrade();
        let weak = Rc::downgrade(self);
        let then = RefCell::new(Some(then));
        yes.connect_clicked(move |_| {
            if let (Some(this), Some(f)) = (weak.upgrade(), then.borrow_mut().take()) {
                f(&this);
            }
            if let Some(d) = close.upgrade() {
                d.close();
            }
        });
        dialog.present();
        keep.grab_focus();
    }

    // ---------- the things right-click offers ----------
    fn selected_entries(&self) -> Vec<Entry> {
        let bits = self.selection.selection();
        let mut out = Vec::new();
        if let Some((mut iter, first)) = gtk::BitsetIter::init_first(&bits) {
            let mut at = Some(first);
            while let Some(pos) = at {
                if let Some(obj) = self.selection.item(pos) {
                    out.push(entry_of(&obj).clone());
                }
                at = iter.next();
            }
        }
        out
    }

    fn copy_paths(&self) {
        let text = self.selected().iter().map(|p| p.to_string_lossy().into_owned()).collect::<Vec<_>>().join("\n");
        let text = if text.is_empty() { self.cwd.borrow().to_string_lossy().into_owned() } else { text };
        self.window.clipboard().set_text(&text);
        self.status.set_text("Copied the path.");
    }

    fn duplicate(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        let paths = self.selected();
        let dest = self.cwd.borrow().clone();
        self.transfer(paths, dest, Mode::Copy);
    }

    fn toggle_bookmark(self: &Rc<Self>, add: bool) {
        let Some(e) = self.selected_entries().into_iter().find(|e| e.is_dir) else { return };
        if add {
            bookmarks::add(&e.path, &e.name);
            self.status.set_text(&format!("Added {} to Favourites", e.name));
        } else {
            bookmarks::remove(&e.path);
            self.status.set_text("Removed from Favourites");
        }
        if let Some(shell) = self.shell.upgrade() {
            shell.fill_favourites();
        }
    }

    fn toggle_star(self: &Rc<Self>) {
        let paths: Vec<PathBuf> = self.selected().into_iter().filter(|p| p.is_file()).collect();
        if paths.is_empty() {
            return;
        }
        let add = paths.iter().any(|p| !stars::is_starred(p));
        stars::toggle(&paths);
        self.status.set_text(if add { "Starred" } else { "Removed star" });
        if stars::is_view(&*self.cwd.borrow()) {
            self.reload();
        }
    }

    fn set_tag(self: &Rc<Self>, name: Option<&str>) {
        let paths: Vec<PathBuf> = self.selected().into_iter().filter(|p| p.exists()).collect();
        if paths.is_empty() {
            return;
        }
        let undo = tags::set_tag(&paths, name);
        remember(Undo::Tags(undo));
        if let Some(shell) = self.shell.upgrade() {
            shell.fill_tags();
        }
        let msg = match name {
            Some(n) => format!("Tagged as {n}"),
            None => "Tag removed".into(),
        };
        self.status.set_text(&msg);
        if tags::is_view(&*self.cwd.borrow()) {
            self.reload();
        }
    }

    fn find_duplicates(self: &Rc<Self>) {
        if self.in_trash.get() || self.in_recent.get() || self.in_starred.get() || self.in_tag.get() || self.in_archive() {
            self.status.set_text("Open a normal folder first.");
            return;
        }
        let dir = self.cwd.borrow().clone();
        if !dir.is_dir() {
            self.status.set_text("Duplicate scan needs a real folder.");
            return;
        }
        if let Some(old) = self.dupe_alive.borrow_mut().take() {
            old.store(false, Ordering::Relaxed);
        }
        let alive = Arc::new(AtomicBool::new(true));
        *self.dupe_alive.borrow_mut() = Some(alive.clone());

        let window = gtk::Window::builder()
            .transient_for(&self.window)
            .title("Find Duplicates")
            .default_width(720)
            .default_height(520)
            .modal(true)
            .build();
        window.add_css_class("sea");
        window.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
        body.add_css_class("dialog-body");
        let status = gtk::Label::builder().xalign(0.0).wrap(true).label("Scanning…").build();
        body.append(&status);
        let scroll = gtk::ScrolledWindow::builder().vexpand(true).min_content_height(280).build();
        let list = gtk::Box::new(gtk::Orientation::Vertical, 8);
        scroll.set_child(Some(&list));
        body.append(&scroll);
        let picks: Rc<RefCell<Vec<(PathBuf, gtk::CheckButton)>>> = Rc::new(RefCell::new(Vec::new()));
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let keep_new = gtk::Button::with_label("Keep Newest");
        let keep_old = gtk::Button::with_label("Keep Oldest");
        let trash_btn = gtk::Button::with_label("Move to Trash");
        trash_btn.add_css_class("destructive");
        let close = gtk::Button::with_label("Close");
        bar.append(&keep_new);
        bar.append(&keep_old);
        bar.append(&trash_btn);
        bar.append(&close);
        body.append(&bar);
        window.set_child(Some(&body));

        let weak_win = window.downgrade();
        let weak_self = Rc::downgrade(self);
        close.connect_clicked(move |_| {
            if let Some(w) = weak_win.upgrade() {
                w.close();
            }
        });
        window.connect_close_request(move |_| {
            if let Some(this) = weak_self.upgrade() {
                if let Some(a) = this.dupe_alive.borrow_mut().take() {
                    a.store(false, Ordering::Relaxed);
                }
            }
            glib::Propagation::Proceed
        });
        let keys = gtk::EventControllerKey::new();
        let weak_win = window.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(w) = weak_win.upgrade() {
                    w.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        window.add_controller(keys);
        window.present();

        let weak_self = Rc::downgrade(self);
        let weak_win = window.downgrade();
        glib::spawn_future_local(async move {
            let dir2 = dir.clone();
            let alive2 = alive.clone();
            let (groups, scanned) = gio::spawn_blocking(move || {
                let mut seen = 0usize;
                let groups = duplicates::find(&dir2, alive2, |n| seen = n);
                (groups, seen)
            })
            .await
            .unwrap_or((Vec::new(), 0));
            let Some(this) = weak_self.upgrade() else { return };
            if !this.dupe_alive.borrow().as_ref().is_some_and(|a| Arc::ptr_eq(a, &alive)) {
                return;
            }
            let Some(_dialog) = weak_win.upgrade() else { return };
            let picks = picks.clone();
            picks.borrow_mut().clear();
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            if groups.is_empty() {
                status.set_text(&format!("No duplicate files found ({scanned} files checked)."));
                keep_new.set_sensitive(false);
                keep_old.set_sensitive(false);
                trash_btn.set_sensitive(false);
                return;
            }
            let wasted: u64 = groups.iter().map(|g| g.wasted).sum();
            status.set_text(&format!(
                "{} groups · {} duplicate files · {} recoverable",
                groups.len(),
                groups.iter().map(|g| g.count).sum::<usize>().saturating_sub(groups.len()),
                duplicates::wasted_text(wasted)
            ));
            for group in &groups {
                let head = gtk::Label::builder()
                    .xalign(0.0)
                    .wrap(true)
                    .label(&format!(
                        "{} × {} — {} wasted",
                        group.count,
                        core::human(group.size),
                        duplicates::wasted_text(group.wasted)
                    ))
                    .build();
                head.add_css_class("side-title");
                list.append(&head);
                for file in &group.files {
                    let row = gtk::CheckButton::builder()
                        .label(&format!("{}\n{}", file.name, file.dir))
                        .active(false)
                        .build();
                    picks.borrow_mut().push((file.path.clone(), row.clone()));
                    list.append(&row);
                }
            }
            keep_new.connect_clicked({
                let groups = groups.clone();
                let picks = picks.clone();
                move |_| {
                    for (_, btn) in picks.borrow_mut().iter() {
                        btn.set_active(false);
                    }
                    for group in &groups {
                        let mut keep = 0usize;
                        for (i, f) in group.files.iter().enumerate() {
                            if f.mtime > group.files[keep].mtime {
                                keep = i;
                            }
                        }
                        for (i, f) in group.files.iter().enumerate() {
                            if i != keep {
                                if let Some((_, btn)) = picks.borrow().iter().find(|(p, _)| p == &f.path) {
                                    btn.set_active(true);
                                }
                            }
                        }
                    }
                }
            });
            keep_old.connect_clicked({
                let groups = groups.clone();
                let picks = picks.clone();
                move |_| {
                    for (_, btn) in picks.borrow_mut().iter() {
                        btn.set_active(false);
                    }
                    for group in &groups {
                        let mut keep = 0usize;
                        for (i, f) in group.files.iter().enumerate() {
                            if f.mtime < group.files[keep].mtime {
                                keep = i;
                            }
                        }
                        for (i, f) in group.files.iter().enumerate() {
                            if i != keep {
                                if let Some((_, btn)) = picks.borrow().iter().find(|(p, _)| p == &f.path) {
                                    btn.set_active(true);
                                }
                            }
                        }
                    }
                }
            });
            let weak_self2 = weak_self.clone();
            let weak_win2 = weak_win.clone();
            trash_btn.connect_clicked(move |_| {
                let paths: Vec<PathBuf> = picks
                    .borrow()
                    .iter()
                    .filter(|(_, b)| b.is_active())
                    .map(|(p, _)| p.clone())
                    .collect();
                if paths.is_empty() {
                    return;
                }
                if let Some(w) = weak_self2.upgrade() {
                    w.trash_now(paths);
                }
                if let Some(d) = weak_win2.upgrade() {
                    d.close();
                }
            });
        });
    }

    fn batch_rename(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        let picked: Vec<_> = self.selected_entries().into_iter().filter(|e| !e.is_dir).collect();
        if picked.len() < 2 {
            self.status.set_text("Select at least two files to batch rename.");
            return;
        }
        self.ask_name("Batch Rename", "Item", move |this, base| {
            if base.is_empty() || base.contains('/') {
                this.status.set_text("That name is not valid.");
                return;
            }
            let mut pairs = Vec::new();
            for (i, e) in picked.iter().enumerate() {
                let ext = Path::new(&e.name).extension().map(|x| format!(".{}", x.to_string_lossy())).unwrap_or_default();
                let n = i + 1;
                let dest = e.path.parent().unwrap_or_else(|| Path::new(".")).join(format!("{base} {n}{ext}"));
                if dest != e.path {
                    pairs.push((e.path.clone(), dest));
                }
            }
            match core::batch_rename(&pairs) {
                Ok(n) => {
                    this.status.set_text(&format!("Renamed {n} file(s)"));
                    this.reload();
                }
                Err(e) => this.status.set_text(&e),
            }
        });
    }

    fn share_kdeconnect(self: &Rc<Self>) {
        let paths = self.selected();
        if paths.is_empty() {
            return;
        }
        let mut cmd = std::process::Command::new("kdeconnect-cli");
        cmd.arg("--share").args(paths.iter().map(|p| p.as_os_str()));
        match cmd.spawn() {
            Ok(_) => self.status.set_text("Sent to KDE Connect…"),
            Err(e) => self.status.set_text(&format!("KDE Connect is not available: {e}")),
        }
    }

    fn terminal(&self) {
        if !self.writable() {
            return;
        }
        let picked = self.selected_entries();
        let dir = match picked.as_slice() {
            [e] if e.is_dir => e.path.clone(),
            _ => self.cwd.borrow().clone(),
        };
        if let Err(e) = std::process::Command::new("kitty").arg("--directory").arg(&dir).spawn() {
            self.status.set_text(&format!("Couldn't open a terminal: {e}"));
        }
    }

    fn compress(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        let paths = self.selected();
        if paths.is_empty() {
            return;
        }
        let name = default_archive_name(&paths);
        self.make_archive(paths, format!("{name}.zip"), None);
    }

    fn make_archive(self: &Rc<Self>, paths: Vec<PathBuf>, name: String, password: Option<String>) {
        let dir = self.cwd.borrow().clone();
        self.status.set_text("Compressing…");
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let done = gio::spawn_blocking(move || {
                let dest = core::free_name(&dir, name.as_ref());
                archive::create(&paths, &dest, password.as_deref())
            })
            .await
            .unwrap_or(Err(Problem::Other("it stopped unexpectedly".into())));
            if let Some(this) = weak.upgrade() {
                match done {
                    Ok(()) => this.status.set_text("Compressed."),
                    Err(Problem::Other(e)) => this.status.set_text(&format!("Couldn't compress: {e}")),
                    Err(_) => this.status.set_text("Couldn't compress."),
                }
                this.reload();
            }
        });
    }

    /// Name, format and an optional password.
    fn compress_dialog(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        let paths = self.selected();
        if paths.is_empty() {
            return;
        }
        let dialog = gtk::Window::builder().transient_for(&self.window).modal(true).title("Compress").default_width(440).resizable(false).build();
        dialog.add_css_class("sea");
        dialog.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
        body.add_css_class("dialog-body");
        let head = gtk::Label::builder().label(if paths.len() == 1 { "Compress this item".to_string() } else { format!("Compress {} items", paths.len()) }).xalign(0.0).build();
        head.add_css_class("dialog-title");
        body.append(&head);
        let name = gtk::Entry::builder().text(default_archive_name(&paths)).activates_default(true).build();
        body.append(&name);
        let formats = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        let chosen = Rc::new(RefCell::new(".zip".to_string()));
        let secret = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let mut first: Option<gtk::ToggleButton> = None;
        for (label, ext) in [("ZIP", ".zip"), ("7Z", ".7z"), ("TAR.GZ", ".tar.gz"), ("TAR.XZ", ".tar.xz"), ("TAR.ZST", ".tar.zst")] {
            let b = gtk::ToggleButton::builder().label(label).active(ext == ".zip").build();
            b.add_css_class("pill-choice");
            match &first {
                Some(f) => b.set_group(Some(f)),
                None => first = Some(b.clone()),
            }
            let (chosen, secret) = (chosen.clone(), secret.clone());
            b.connect_toggled(move |b| {
                if b.is_active() {
                    *chosen.borrow_mut() = ext.to_string();
                    // tar has no encryption of its own, so it isn't offered.
                    secret.set_visible(ext == ".zip" || ext == ".7z");
                }
            });
            formats.append(&b);
        }
        body.append(&formats);
        let pw = gtk::PasswordEntry::builder().show_peek_icon(true).placeholder_text("Password (optional)").build();
        let pw2 = gtk::PasswordEntry::builder().placeholder_text("Type it again").visible(false).build();
        let note = gtk::Label::builder().label("Encrypted with AES-256. If you lose the password, nobody can open it.").xalign(0.0).wrap(true).visible(false).build();
        note.add_css_class("dim");
        note.add_css_class("small");
        let (again, hint) = (pw2.clone(), note.clone());
        pw.connect_changed(move |p| {
            let on = !p.text().is_empty();
            again.set_visible(on);
            hint.set_visible(on);
        });
        secret.append(&pw);
        secret.append(&pw2);
        secret.append(&note);
        body.append(&secret);
        let row = gtk::Box::builder().spacing(8).halign(gtk::Align::End).margin_top(4).build();
        let no = gtk::Button::with_label("Cancel");
        no.add_css_class("plain");
        let yes = gtk::Button::with_label("Compress");
        yes.add_css_class("accent");
        row.append(&no);
        row.append(&yes);
        body.append(&row);
        dialog.set_child(Some(&body));
        let d = dialog.downgrade();
        no.connect_clicked(move |_| {
            if let Some(d) = d.upgrade() {
                d.close();
            }
        });
        let weak = Rc::downgrade(self);
        let d = dialog.downgrade();
        let warn = note.clone();
        yes.connect_clicked(move |_| {
            let ext = chosen.borrow().clone();
            let can_lock = ext == ".zip" || ext == ".7z";
            let first = pw.text().to_string();
            if can_lock && !first.is_empty() && first != pw2.text().as_str() {
                warn.set_text("Those two passwords don't match.");
                warn.set_visible(true);
                return;
            }
            let label = name.text().trim().to_string();
            if label.is_empty() || label.contains('/') {
                return;
            }
            let password = (can_lock && !first.is_empty()).then_some(first);
            if let Some(this) = weak.upgrade() {
                this.make_archive(paths.clone(), format!("{label}{ext}"), password);
            }
            if let Some(d) = d.upgrade() {
                d.close();
            }
        });
        let keys = gtk::EventControllerKey::new();
        let d = dialog.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(d) = d.upgrade() {
                    d.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        dialog.add_controller(keys);
        dialog.present();
    }

    fn new_file(self: &Rc<Self>) {
        if !self.writable() {
            return;
        }
        self.ask_name("New text file", "Untitled.txt", |this, name| {
            let path = this.cwd.borrow().join(name);
            let root = this.root.borrow().clone();
            let is_root = root.is_some();
            let made = match root {
                Some(c) => c.touch(&path),
                None => std::fs::OpenOptions::new().write(true).create_new(true).open(&path).map(|_| ()).map_err(|e| e.to_string()),
            };
            match made {
                Err(e) => this.status.set_text(&format!("Couldn't make that file: {e}")),
                Ok(()) if !is_root => remember(Undo::Trash(vec![path])),
                Ok(()) => {}
            }
            this.reload();
        });
    }

    fn open_with(self: &Rc<Self>, id: &str, make_default: bool) {
        let Some(app) = gio::AppInfo::all().into_iter().find(|a| a.id().as_deref() == Some(id)) else { return };
        let picked = self.selected_entries();
        if make_default {
            if let Some(e) = picked.first() {
                let (ty, _) = gio::content_type_guess(Some(e.name.as_str()), None::<&[u8]>);
                let _ = app.set_as_default_for_type(&ty);
            }
        }
        let files: Vec<gio::File> = picked.iter().map(|e| gio::File::for_path(&e.path)).collect();
        if let Err(e) = app.launch(&files, None::<&gio::AppLaunchContext>) {
            self.status.set_text(&format!("Couldn't open that: {e}"));
        }
    }

    fn set_sort(self: &Rc<Self>, field: &str, descending: bool) {
        let direction = if descending { gtk::SortType::Descending } else { gtk::SortType::Ascending };
        let columns = self.columns.borrow();
        // Plain name order is what the folder was read in, so no sorting has to run at all.
        match columns.get(field) {
            Some(col) if field != "name" || descending => self.list.sort_by_column(Some(col), direction),
            _ => self.list.sort_by_column(None::<&gtk::ColumnViewColumn>, direction),
        }
    }

    fn apply_prefs(self: &Rc<Self>) {
        let single = prefs::str_of("clickToOpen", "double") == "single";
        self.list.set_single_click_activate(single);
        self.grid.set_single_click_activate(single);
        let hidden = prefs::bool_of("showHidden", false);
        if self.hidden.replace(hidden) != hidden {
            self.reload();
        }
        self.set_sort(&prefs::str_of("sortField", "name"), prefs::bool_of("sortDescending", false));
        if let Some(factory) = self.grid.factory() {
            self.grid.set_factory(None::<&gtk::ListItemFactory>);
            self.grid.set_factory(Some(&factory));
        }
    }

    // ---------- properties ----------
    fn properties(self: &Rc<Self>) {
        if self.in_archive() {
            self.writable();
            return;
        }
        let picked = self.selected_entries();
        let target = match picked.as_slice() {
            [e] => e.path.clone(),
            [] => self.cwd.borrow().clone(),
            many => return self.properties_many(many.iter().map(|e| e.path.clone()).collect()),
        };
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Computer".into());
        let is_dir = target.is_dir();
        let (icon, kind) = kind_of(&Entry { name: name.clone(), path: target.clone(), is_dir, size: 0, mtime: 0 });
        let (window, grid, size_label) = self.info_window(&name, &icon);
        let mut rows = vec![("Kind".to_string(), kind), ("Location".to_string(), target.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or("/".into()))];
        let info = gio::File::for_path(&target).query_info("owner::user,owner::group,unix::mode,time::created,time::modified,time::access", gio::FileQueryInfoFlags::NONE, gio::Cancellable::NONE).ok();
        if let Some(i) = &info {
            let when = |key: &str| date_text(i.attribute_uint64(key) as i64);
            rows.push(("Modified".to_string(), when("time::modified")));
            if i.attribute_uint64("time::created") > 0 {
                rows.push(("Created".to_string(), when("time::created")));
            }
            rows.push(("Last opened".to_string(), when("time::access")));
            rows.push(("Owner".to_string(), format!("{} ({})", i.attribute_string("owner::user").unwrap_or_default(), i.attribute_string("owner::group").unwrap_or_default())));
            rows.push(("Permissions".to_string(), core::mode_text(i.attribute_uint32("unix::mode"))));
        }
        for (i, (k, v)) in rows.iter().enumerate() {
            info_row(&grid, i as i32 + 1, k, v);
        }
        let mode_bits = info.as_ref().map(|i| i.attribute_uint32("unix::mode"));
        if target.exists() && !self.in_trash.get() && !self.in_tag.get() {
            self.permission_editor(&window, &grid, &target, is_dir, rows.len() as i32 + 1, mode_bits);
        }
        window.present();
        // Otherwise the first value gets the keyboard and shows up selected.
        gtk::prelude::GtkWindowExt::set_focus(&window, None::<&gtk::Widget>);
        fill_size(size_label, vec![target]);
    }

    fn properties_many(self: &Rc<Self>, paths: Vec<PathBuf>) {
        let icon: gio::Icon = gio::ThemedIcon::new("edit-copy").upcast();
        let (window, _, size_label) = self.info_window(&format!("{} items", paths.len()), &icon);
        window.present();
        fill_size(size_label, paths);
    }

    fn info_window(&self, name: &str, icon: &gio::Icon) -> (gtk::Window, gtk::Grid, gtk::Label) {
        let window = gtk::Window::builder().transient_for(&self.window).title(format!("{name} Info")).default_width(430).build();
        window.add_css_class("sea");
        window.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
        body.add_css_class("dialog-body");
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        head.append(&gtk::Image::builder().gicon(icon).pixel_size(56).build());
        let title = gtk::Label::builder().label(name).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).hexpand(true).build();
        title.add_css_class("dialog-title");
        head.append(&title);
        body.append(&head);
        let grid = gtk::Grid::builder().column_spacing(16).row_spacing(6).build();
        grid.add_css_class("panel");
        grid.add_css_class("pref-row");
        let key = gtk::Label::builder().label("Size").xalign(0.0).build();
        key.add_css_class("dim");
        let size_label = gtk::Label::builder().label("Adding up…").xalign(0.0).wrap(true).hexpand(true).build();
        grid.attach(&key, 0, 0, 1, 1);
        grid.attach(&size_label, 1, 0, 1, 1);
        body.append(&grid);
        window.set_child(Some(&body));
        let keys = gtk::EventControllerKey::new();
        let close = window.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(w) = close.upgrade() {
                    w.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        window.add_controller(keys);
        (window, grid, size_label)
    }

    fn permission_editor(
        self: &Rc<Self>,
        window: &gtk::Window,
        grid: &gtk::Grid,
        target: &Path,
        is_dir: bool,
        row: i32,
        mode_bits: Option<u32>,
    ) {
        let key = gtk::Label::builder().label("Change mode").xalign(0.0).build();
        key.add_css_class("dim");
        let row_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let entry = gtk::Entry::builder()
            .placeholder_text("755")
            .width_chars(6)
            .text(mode_bits.map(|m| format!("{:o}", m & 0o777)).unwrap_or_else(|| "644".into()))
            .build();
        let recur = gtk::CheckButton::with_label("Apply to contents");
        recur.set_visible(is_dir);
        let apply = gtk::Button::with_label("Apply");
        row_box.append(&entry);
        row_box.append(&recur);
        row_box.append(&apply);
        grid.attach(&key, 0, row, 1, 1);
        grid.attach(&row_box, 1, row, 1, 1);
        let target = target.to_path_buf();
        let dialog = window.clone();
        apply.connect_clicked({
            let weak = Rc::downgrade(self);
            let target = target.clone();
            let dialog = dialog.clone();
            move |_| {
                let Some(this) = weak.upgrade() else { return };
                let mode = match core::parse_mode_input(&entry.text()) {
                    Ok(m) => m,
                    Err(e) => {
                        this.status.set_text(&e);
                        return;
                    }
                };
                let recursive = recur.is_visible() && recur.is_active();
                let weak2 = Rc::downgrade(&this);
                let path = target.clone();
                let dialog = dialog.clone();
                glib::spawn_future_local(async move {
                    let client = weak2.upgrade().and_then(|w| w.root.borrow().clone());
                    let done = gio::spawn_blocking(move || {
                        if let Some(client) = client {
                            client.chmod(&path, mode, recursive)
                        } else {
                            core::chmod_at(&path, mode, recursive)
                        }
                    })
                    .await;
                    let Some(this) = weak2.upgrade() else { return };
                    match done {
                        Ok(Ok(changed)) if !changed.is_empty() => {
                            remember(Undo::Chmod(changed));
                            this.status.set_text("Permissions updated.");
                            dialog.close();
                            this.reload();
                        }
                        Ok(Ok(_)) => this.status.set_text("Already had that mode."),
                        Ok(Err(e)) => this.status.set_text(&e),
                        _ => this.status.set_text("Couldn't change permissions."),
                    }
                });
            }
        });
    }

    fn go_history(self: &Rc<Self>, dest: PathBuf, from_back: bool) {
        if from_back {
            if !self.back.borrow().iter().any(|p| *p == dest) {
                return;
            }
            self.forward.borrow_mut().push(self.cwd.borrow().clone());
            while self.back.borrow().last().is_some_and(|p| *p != dest) {
                if let Some(p) = self.back.borrow_mut().pop() {
                    self.forward.borrow_mut().push(p);
                }
            }
            self.back.borrow_mut().pop();
        } else {
            if !self.forward.borrow().iter().any(|p| *p == dest) {
                return;
            }
            self.back.borrow_mut().push(self.cwd.borrow().clone());
            while self.forward.borrow().last().is_some_and(|p| *p != dest) {
                if let Some(p) = self.forward.borrow_mut().pop() {
                    self.back.borrow_mut().push(p);
                }
            }
            self.forward.borrow_mut().pop();
        }
        self.navigate(dest, false);
    }

    // ---------- right click ----------
    fn context_menu(self: &Rc<Self>, x: f64, y: f64, on_item: bool) {
        let menu = gio::Menu::new();
        let item = |label: &str, action: &str, accel: Option<&str>| {
            let it = gio::MenuItem::new(Some(label), Some(action));
            if let Some(a) = accel {
                it.set_attribute_value("accel", Some(&a.to_variant()));
            }
            it
        };
        let section = |items: Vec<gio::MenuItem>| {
            let s = gio::Menu::new();
            for i in &items {
                s.append_item(i);
            }
            s
        };
        let inside = self.in_archive();
        let in_trash = self.in_trash.get();
        if in_trash {
            if on_item {
                menu.append_section(None, &section(vec![item("Put Back", "win.restore", None), item("Quick Look", "win.quick-look", Some("space")), item("Copy", "win.copy", Some("<Control>c"))]));
                menu.append_section(None, &section(vec![item("Delete Permanently", "win.delete-permanently", Some("Delete")), item("Properties", "win.properties", Some("<Alt>Return"))]));
            } else {
                menu.append_section(None, &section(vec![item("Empty Trash", "win.empty-trash", None), item("Select All", "win.select-all", Some("<Control>a")), item("Refresh", "win.refresh", Some("F5"))]));
            }
        } else if on_item && inside {
            menu.append_section(None, &section(vec![item("Open", "win.open", Some("Return")), item("Quick Look", "win.quick-look", Some("space"))]));
            menu.append_section(None, &section(vec![item("Copy", "win.copy", Some("<Control>c")), item("Copy Path", "win.copy-path", Some("<Control><Shift>c"))]));
            if self.editing().is_some() {
                menu.append_section(None, &section(vec![item("Rename", "win.rename", Some("F2")), item("Delete from Archive", "win.trash", Some("Delete"))]));
            }
            menu.append_section(None, &section(vec![item("Extract To…", "win.extract-to", None), item("Extract All", "win.extract", None)]));
        } else if on_item {
            let picked = self.selected_entries();
            let first = picked.first().cloned();
            let mut top = vec![item("Open", "win.open", Some("Return"))];
            if picked.len() == 1 && first.as_ref().is_some_and(|e| e.is_dir) {
                top.push(item("Open in New Tab", "win.open-new-tab", None));
                top.push(item("Open in New Window", "win.open-new-window", None));
            }
            if picked.len() == 1 {
                if let Some(e) = first.as_ref().filter(|e| !e.is_dir) {
                    let (ty, _) = gio::content_type_guess(Some(e.name.as_str()), None::<&[u8]>);
                    let apps = gio::AppInfo::all_for_type(&ty);
                    if !apps.is_empty() {
                        let (with, always) = (gio::Menu::new(), gio::Menu::new());
                        for app in apps.iter().take(12) {
                            let Some(id) = app.id() else { continue };
                            let open = gio::MenuItem::new(Some(&app.display_name()), None);
                            open.set_action_and_target_value(Some("win.open-with"), Some(&id.to_variant()));
                            with.append_item(&open);
                            let set = gio::MenuItem::new(Some(&app.display_name()), None);
                            set.set_action_and_target_value(Some("win.open-always"), Some(&id.to_variant()));
                            always.append_item(&set);
                        }
                        with.append_section(None, &section(vec![gio::MenuItem::new_submenu(Some("Always Open With"), &always)]));
                        top.push(gio::MenuItem::new_submenu(Some("Open With"), &with));
                    }
                }
            }
            top.push(item("Quick Look", "win.quick-look", Some("space")));
            menu.append_section(None, &section(top));
            menu.append_section(None, &section(vec![
                item("Cut", "win.cut", Some("<Control>x")),
                item("Copy", "win.copy", Some("<Control>c")),
                item("Copy Path", "win.copy-path", Some("<Control><Shift>c")),
                item("Paste", "win.paste", Some("<Control>v")),
            ]));
            let mut change = vec![item("Rename", "win.rename", Some("F2")), item("Duplicate", "win.duplicate", Some("<Control>d"))];
            if picked.iter().any(|e| preview::is_archive(&e.name)) {
                change.push(item("Extract Here", "win.extract", None));
                change.push(item("Extract To…", "win.extract-to", None));
            }
            change.push(item("Compress to ZIP", "win.compress", None));
            change.push(item("Compress…", "win.compress-dialog", None));
            let root_mode = self.root.borrow().is_some();
            if !root_mode {
                change.push(item("Move to Trash", "win.trash", Some("Delete")));
            }
            change.push(item("Delete Permanently", "win.delete-permanently", Some("<Shift>Delete")));
            if picked.len() >= 2 && picked.iter().all(|e| !e.is_dir) && self.writable() {
                change.push(item("Batch Rename…", "win.batch-rename", None));
            }
            menu.append_section(None, &section(change));
            let mut last = Vec::new();
            if !picked.is_empty() && !self.in_trash.get() && !self.in_recent.get() && !self.in_starred.get() && !self.in_tag.get() {
                let tag_menu = gio::Menu::new();
                let none = gio::MenuItem::new(Some("No Tag"), None);
                none.set_action_and_target_value(Some("win.set-tag"), Some(&"".to_variant()));
                tag_menu.append_item(&none);
                for name in tags::NAMES {
                    let it = gio::MenuItem::new(Some(name), None);
                    it.set_action_and_target_value(Some("win.set-tag"), Some(&name.to_variant()));
                    tag_menu.append_item(&it);
                }
                last.push(gio::MenuItem::new_submenu(Some("Tags"), &tag_menu));
                let label = if picked.iter().all(|e| stars::is_starred(&e.path)) {
                    "Remove Star"
                } else {
                    "Add Star"
                };
                last.push(item(label, "win.toggle-star", None));
                last.push(item("Share via KDE Connect", "win.kdeconnect", None));
            }
            if let Some(e) = first.as_ref().filter(|e| e.is_dir && !self.in_trash.get() && !self.in_recent.get() && !self.in_starred.get() && !self.in_tag.get() && !self.in_archive()) {
                if bookmarks::contains(&e.path) {
                    last.push(item("Remove from Favourites", "win.remove-bookmark", None));
                } else {
                    last.push(item("Add to Favourites", "win.add-bookmark", None));
                }
            }
            last.push(item("Open in Terminal", "win.terminal", None));
            if !root_mode {
                last.push(item("Open as Administrator", "win.admin", None));
            }
            last.push(item("Properties", "win.properties", Some("<Alt>Return")));
            menu.append_section(None, &section(last));
        } else {
            if inside {
                menu.append_section(None, &section(vec![item("Extract All", "win.extract", None), item("Extract To…", "win.extract-to", None)]));
                let mut edit = vec![item("Select All", "win.select-all", Some("<Control>a"))];
                if self.editing().is_some() {
                    edit.insert(0, item("Paste", "win.paste", Some("<Control>v")));
                    edit.insert(0, item("New Folder", "win.new-folder", Some("<Control><Shift>n")));
                }
                menu.append_section(None, &section(edit));
            } else {
                menu.append_section(None, &section(vec![
                    item("New Folder", "win.new-folder", Some("<Control><Shift>n")),
                    item("New Text File", "win.new-file", Some("<Control><Alt>n")),
                ]));
                menu.append_section(None, &section(vec![item("Paste", "win.paste", Some("<Control>v")), item("Select All", "win.select-all", Some("<Control>a"))]));
            }
            let sort = gio::Menu::new();
            for (label, field) in [("Name", "name"), ("Date Modified", "date"), ("Size", "size"), ("Kind", "kind")] {
                let it = gio::MenuItem::new(Some(label), None);
                it.set_action_and_target_value(Some("win.sort-by"), Some(&field.to_variant()));
                sort.append_item(&it);
            }
            let order = gio::Menu::new();
            for (label, value) in [("Ascending", false), ("Descending", true)] {
                let it = gio::MenuItem::new(Some(label), None);
                it.set_action_and_target_value(Some("win.sort-order"), Some(&value.to_variant()));
                order.append_item(&it);
            }
            sort.append_section(None, &order);
            let group = gio::Menu::new();
            for (label, field) in [("None", "none"), ("Kind", "kind"), ("Date", "date"), ("Size", "size")] {
                let it = gio::MenuItem::new(Some(label), None);
                it.set_action_and_target_value(Some("win.group-by"), Some(&field.to_variant()));
                group.append_item(&it);
            }
            let cols = gio::Menu::new();
            cols.append(Some("Choose Columns…"), Some("win.columns"));
            for (label, action) in [
                ("Date Modified", "win.toggle-column-date"),
                ("Size", "win.toggle-column-size"),
                ("Kind", "win.toggle-column-kind"),
            ] {
                cols.append(Some(label), Some(action));
            }
            let view = section(vec![item("Icons", "win.view-grid", Some("<Control>1")), item("List", "win.view-list", Some("<Control>2"))]);
            view.append_section(None, &cols);
            menu.append_section(None, &section(vec![
                gio::MenuItem::new_submenu(Some("View"), &view),
                gio::MenuItem::new_submenu(Some("Sort By"), &sort),
                gio::MenuItem::new_submenu(Some("Group By"), &group),
                item("Hidden Files", "win.toggle-hidden", Some("<Control>h")),
                item("Refresh", "win.refresh", Some("F5")),
            ]));
            if !inside && !self.in_trash.get() && !self.in_recent.get() && !self.in_starred.get() && !self.in_tag.get() {
                menu.append_section(None, &section(vec![item("Find Duplicates…", "win.find-duplicates", None)]));
            }
            if !inside {
                let mut last = vec![item("Open in Terminal", "win.terminal", None)];
                if self.root.borrow().is_none() {
                    last.push(item("Open as Administrator", "win.admin", None));
                }
                last.push(item("Preferences", "win.prefs", Some("<Control>comma")));
                last.push(item("Properties", "win.properties", Some("<Alt>Return")));
                menu.append_section(None, &section(last));
            }
        }
        let pop = gtk::PopoverMenu::from_model_full(&menu, gtk::PopoverMenuFlags::NESTED);
        // GTK's measure comes up one row short and leaves the last item scrolled out of sight, and
        // turning its scrolling off makes the menu vanish. So it's told the height outright.
        let (mut rows, mut gaps) = (0, 0);
        for at in 0..menu.n_items() {
            if let Some(part) = menu.item_link(at, "section") {
                rows += part.n_items();
                gaps += 1;
            }
        }
        fn set_height(w: &gtk::Widget, height: i32) -> bool {
            if let Some(s) = w.downcast_ref::<gtk::ScrolledWindow>() {
                s.set_min_content_height(height);
                return true;
            }
            let mut c = w.first_child();
            while let Some(k) = c {
                if set_height(&k, height) {
                    return true;
                }
                c = k.next_sibling();
            }
            false
        }
        set_height(pop.upcast_ref(), rows * 32 + (gaps - 1).max(0) * 11 + 16);
        pop.set_parent(&self.views);
        pop.set_has_arrow(false);
        pop.set_halign(gtk::Align::Start);
        pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        pop.connect_closed(|p| {
            // Later, because the item you clicked still has to run.
            let p = p.clone();
            glib::timeout_add_local_once(std::time::Duration::from_millis(300), move || p.unparent());
        });
        pop.popup();
    }

    fn right_clicked(self: &Rc<Self>, x: f64, y: f64) {
        let item = item_under(self.views.upcast_ref(), x, y);
        match &item {
            // Right-clicking something unselected selects only it, as everywhere else.
            Some(cell) if !cell.is_selected() => {
                self.selection.select_item(cell.position(), true);
            }
            None => {
                self.selection.unselect_all();
            }
            _ => {}
        }
        self.focus_view();
        self.context_menu(x, y, item.is_some());
    }

    // ---------- clipboard ----------
    /// The text box with the keyboard, if any. Picking Copy from the global menu while typing
    /// means the text, the same as the keyboard shortcut does.
    fn text_focus(&self) -> Option<gtk::Text> {
        gtk::prelude::GtkWindowExt::focus(&self.window).and_downcast::<gtk::Text>()
    }

    fn to_clipboard(&self, mode: Mode) {
        if let Some(text) = self.text_focus() {
            let name = if mode == Mode::Move { "clipboard.cut" } else { "clipboard.copy" };
            let _ = WidgetExt::activate_action(&text, name, None);
            return;
        }
        let inside = self.inside.borrow().clone();
        if let Some((zip, _)) = inside {
            if mode == Mode::Move {
                self.writable();
                return;
            }
            // Dragging isn't possible from here yet, but this is: it takes a real copy out first.
            WINS.with(|w| {
                if let Some(this) = w.borrow().iter().filter_map(std::rc::Weak::upgrade).find(|t| std::ptr::eq(t.as_ref(), self)) {
                    this.copy_out(zip);
                }
            });
            return;
        }
        self.offer_clipboard(self.selected(), mode);
    }

    fn offer_clipboard(&self, paths: Vec<PathBuf>, mode: Mode) {
        if paths.is_empty() {
            return;
        }
        let uris: Vec<String> = paths.iter().map(|p| gio::File::for_path(p).uri().to_string()).collect();
        let word = if mode == Mode::Move { "cut" } else { "copy" };
        let bytes = |s: String| glib::Bytes::from_owned(s.into_bytes());
        let plain = paths.iter().map(|p| p.to_string_lossy()).collect::<Vec<_>>().join("\n");
        let provider = gdk::ContentProvider::new_union(&[
            gdk::ContentProvider::for_bytes("x-special/gnome-copied-files", &bytes(format!("{word}\n{}", uris.join("\n")))),
            gdk::ContentProvider::for_bytes("text/uri-list", &bytes(format!("{}\r\n", uris.join("\r\n")))),
            gdk::ContentProvider::for_bytes("application/x-kde-cutselection", &bytes(if mode == Mode::Move { "1".into() } else { "0".into() })),
            gdk::ContentProvider::for_bytes("text/plain;charset=utf-8", &bytes(plain)),
        ]);
        if self.window.clipboard().set_content(Some(&provider)).is_ok() {
            let n = paths.len();
            let verb = if mode == Mode::Move { "Cut" } else { "Copied" };
            self.status.set_text(&if n == 1 { format!("{verb} 1 item") } else { format!("{verb} {n} items") });
        }
    }

    /// Never blocks: the clipboard's owner may be slow or stuck, and that must not freeze this window.
    fn paste(self: &Rc<Self>) {
        if let Some(text) = self.text_focus() {
            let _ = WidgetExt::activate_action(&text, "clipboard.paste", None);
            return;
        }
        if self.editing().is_none() && !self.writable() {
            return;
        }
        let clipboard = self.window.clipboard();
        let weak = Rc::downgrade(self);
        // Decided now, not when the answer comes: a slow clipboard owner must not make files land
        // in whatever folder you've wandered into since.
        let dest = self.cwd.borrow().clone();
        glib::spawn_future_local(async move {
            let Ok((stream, mime)) = clipboard
                .read_future(&["x-special/gnome-copied-files", "text/uri-list"], glib::Priority::DEFAULT)
                .await
            else {
                if let Some(this) = weak.upgrade() {
                    this.status.set_text("There are no files on the clipboard.");
                }
                return;
            };
            let mut raw = Vec::new();
            while let Ok(chunk) = stream.read_bytes_future(65536, glib::Priority::DEFAULT).await {
                if chunk.is_empty() {
                    break;
                }
                raw.extend_from_slice(&chunk);
            }
            let Some(this) = weak.upgrade() else { return };
            let (mode, uris) = core::parse_clipboard(&mime, &String::from_utf8_lossy(&raw));
            let paths: Vec<PathBuf> = uris.iter().filter_map(|u| gio::File::for_uri(u).path()).collect();
            this.transfer(paths, dest, mode);
            if mode == Mode::Move {
                // A cut can only be pasted once.
                let _ = this.window.clipboard().set_content(None::<&gdk::ContentProvider>);
            }
        });
    }

    fn transfer(self: &Rc<Self>, paths: Vec<PathBuf>, dest: PathBuf, mode: Mode) {
        if paths.is_empty() {
            self.status.set_text("There are no files on the clipboard.");
            return;
        }
        if self.in_archive() {
            return self.add_to_archive(paths);
        }
        // Administrator work goes through the helper, which has its own rules: nothing is overwritten.
        let root = self.root.borrow().clone();
        if let Some(client) = root {
            let weak = Rc::downgrade(self);
            glib::spawn_future_local(async move {
                let errors = gio::spawn_blocking(move || paths.iter().filter_map(|p| client.transfer(p, &dest, mode).err().map(|e| format!("{}: {e}", p.display()))).collect::<Vec<_>>()).await.unwrap_or_default();
                if let Some(this) = weak.upgrade() {
                    this.reload();
                    this.status.set_text(&errors.first().map(|e| format!("Couldn't finish: {e}")).unwrap_or("Done.".to_string()));
                }
            });
            return;
        }
        let job = Arc::new(Job::default());
        let worker = job.clone();
        let (sources, target) = (paths.clone(), dest.clone());
        std::thread::spawn(move || {
            let out = ops::run(&sources, &target, mode, &worker);
            *worker.outcome.lock().unwrap() = Some(out);
            worker.finished.store(true, std::sync::atomic::Ordering::Release);
        });
        self.track_job(job, paths.len(), dest, mode);
    }

    /// The job's row, and the watching. Fast ones finish before it would appear, so nothing flashes.
    fn track_job(self: &Rc<Self>, job: Arc<Job>, count: usize, dest: PathBuf, mode: Mode) {
        use std::sync::atomic::Ordering::{Acquire, Relaxed};
        let row = gtk::Box::builder().spacing(10).build();
        row.add_css_class("job");
        let words = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).hexpand(true).build();
        let verb = if mode == Mode::Move { "Moving" } else { "Copying" };
        let place = dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("/".into());
        let what = if count == 1 { "1 item".to_string() } else { format!("{count} items") };
        let title = gtk::Label::builder().label(format!("{verb} {what} to {place}")).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::Middle).build();
        title.add_css_class("job-title");
        let bar = gtk::ProgressBar::new();
        let detail = gtk::Label::builder().label("Waiting for other copies to finish…").xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::Middle).build();
        detail.add_css_class("dim");
        detail.add_css_class("small");
        words.append(&title);
        words.append(&bar);
        words.append(&detail);
        let stop = gtk::Button::builder().tooltip_text("Stop").build();
        stop.set_child(Some(&sym("close")));
        stop.add_css_class("round");
        let stopper = job.clone();
        stop.connect_clicked(move |b| {
            stopper.stop();
            b.set_sensitive(false);
        });
        row.append(&words);
        row.append(&stop);
        row.set_visible(false);
        self.jobs.append(&row);
        let weak = Rc::downgrade(self);
        let started = Instant::now();
        let asking = Rc::new(Cell::new(false));
        glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else { return glib::ControlFlow::Break };
            if job.finished.load(Acquire) {
                this.jobs.remove(&row);
                this.jobs.set_visible(this.jobs.first_child().is_some());
                if let Some(out) = job.outcome.lock().unwrap().take() {
                    this.job_finished(out, dest.clone(), mode);
                }
                return glib::ControlFlow::Break;
            }
            if started.elapsed().as_millis() > 300 {
                row.set_visible(true);
                this.jobs.set_visible(true);
            }
            let pending = job.question.lock().unwrap().clone();
            if let Some(q) = pending {
                if !asking.replace(true) {
                    this.ask_conflict(q, job.clone(), asking.clone());
                }
            }
            if job.started.load(Relaxed) {
                let (done, total) = (job.done.load(Relaxed), job.total.load(Relaxed));
                if total > 0 {
                    bar.set_fraction((done as f64 / total as f64).min(1.0));
                    let secs = started.elapsed().as_secs_f64().max(0.1);
                    let speed = done as f64 / secs;
                    let left = if speed > 1.0 { (total.saturating_sub(done)) as f64 / speed } else { 0.0 };
                    let eta = if left > 90.0 { format!(", about {} min left", (left / 60.0).ceil() as u64) } else if left >= 2.0 { format!(", about {} s left", left.ceil() as u64) } else { String::new() };
                    detail.set_text(&format!("{} of {} at {}/s{eta}", core::human(done), core::human(total), core::human(speed as u64)));
                }
            }
            glib::ControlFlow::Continue
        });
    }

    fn job_finished(self: &Rc<Self>, out: ops::Outcome, dest: PathBuf, mode: Mode) {
        self.reload();
        // A file overwritten can't come back, so offering undo would only half work.
        if !out.replaced {
            if !out.moved.is_empty() {
                remember(Undo::Moved(out.moved.iter().map(|(a, b)| (b.clone(), a.clone())).collect()));
            }
            if !out.created.is_empty() {
                remember(Undo::Trash(out.created.clone()));
            }
        } else {
            UNDO.with(|u| u.borrow_mut().clear());
            REDO.with(|r| r.borrow_mut().clear());
        }
        let skipped = if out.skipped > 0 { format!(" Skipped {}.", out.skipped) } else { String::new() };
        self.status.set_text(&if out.cancelled {
            "Stopped. Anything half-copied was removed.".to_string()
        } else {
            match out.failures.first() {
                None => format!("Done.{skipped}"),
                Some(first) if out.failures.len() == 1 => format!("Couldn't finish: {first}"),
                Some(first) => format!("{} items couldn't be finished. First: {first}", out.failures.len()),
            }
        });
        if !out.denied.is_empty() {
            let denied = out.denied;
            self.need_admin("You need administrator access to do this here.", Box::new(move |w| w.transfer(denied, dest, mode)));
        }
    }

    fn ask_conflict(self: &Rc<Self>, q: ops::Question, job: Arc<Job>, asking: Rc<Cell<bool>>) {
        let dialog = gtk::Window::builder().transient_for(&self.window).modal(true).title("Already there").default_width(460).resizable(false).build();
        dialog.add_css_class("sea");
        dialog.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
        body.add_css_class("dialog-body");
        let head = gtk::Label::builder().label(format!("\u{201c}{}\u{201d} is already here", q.name)).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).build();
        head.add_css_class("dialog-title");
        body.append(&head);
        if q.both_folders {
            let n = gtk::Label::builder().label("Merging adds to the folder that's there. Files with the same name will ask again.").xalign(0.0).wrap(true).build();
            n.add_css_class("dim");
            body.append(&n);
        } else {
            let grid = gtk::Grid::builder().column_spacing(16).row_spacing(6).build();
            grid.add_css_class("panel");
            grid.add_css_class("pref-row");
            info_row(&grid, 0, "New", &format!("{}, {}", core::human(q.new_size), date_text(q.new_mtime)));
            info_row(&grid, 1, "Already here", &format!("{}, {}", core::human(q.old_size), date_text(q.old_mtime)));
            body.append(&grid);
        }
        let all = gtk::CheckButton::with_label("Do this for everything else");
        body.append(&all);
        let row = gtk::Box::builder().spacing(8).halign(gtk::Align::End).margin_top(4).build();
        let done = Rc::new(Cell::new(false));
        for (label, choice, class) in [("Skip", Choice::Skip, "plain"), ("Keep Both", Choice::KeepBoth, "plain"), (if q.both_folders { "Merge" } else { "Replace" }, Choice::Replace, "accent")] {
            let b = gtk::Button::with_label(label);
            b.add_css_class(class);
            let (job, asking, d, all, done) = (job.clone(), asking.clone(), dialog.downgrade(), all.clone(), done.clone());
            b.connect_clicked(move |_| {
                done.set(true);
                job.answer(choice, all.is_active());
                asking.set(false);
                if let Some(d) = d.upgrade() {
                    d.close();
                }
            });
            row.append(&b);
        }
        body.append(&row);
        dialog.set_child(Some(&body));
        // Closing it skips this one. Silence must never mean overwriting.
        dialog.connect_close_request(move |_| {
            if !done.get() {
                job.answer(Choice::Skip, false);
                asking.set(false);
            }
            glib::Propagation::Proceed
        });
        let keys = gtk::EventControllerKey::new();
        let d = dialog.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(d) = d.upgrade() {
                    d.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        dialog.add_controller(keys);
        dialog.present();
        gtk::prelude::GtkWindowExt::set_focus(&dialog, None::<&gtk::Widget>);
    }

    fn undo_step(self: &Rc<Self>, redo: bool) {
        let op = if redo { REDO.with(|r| r.borrow_mut().pop()) } else { UNDO.with(|u| u.borrow_mut().pop()) };
        let Some(op) = op else {
            self.status.set_text(if redo { "Nothing to redo." } else { "Nothing to undo." });
            return;
        };
        let what = op.describe();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || op.apply()).await.unwrap_or(Err("it stopped unexpectedly".into()));
            let Some(this) = weak.upgrade() else { return };
            match result {
                Ok(inverse) => {
                    if redo { UNDO.with(|u| u.borrow_mut().push(inverse)) } else { REDO.with(|r| r.borrow_mut().push(inverse)) }
                    this.status.set_text(&format!("{} {what}.", if redo { "Redid" } else { "Undid" }));
                }
                Err(e) => this.status.set_text(&format!("Couldn't: {e}")),
            }
            WINS.with(|w| w.borrow().iter().filter_map(std::rc::Weak::upgrade).for_each(|w| w.reload()));
        });
    }

    fn trash(self: &Rc<Self>) {
        if self.in_trash.get() {
            return self.delete_permanently();
        }
        if self.editing().is_some() {
            return self.delete_permanently();
        }
        if !self.writable() {
            return;
        }
        let paths = self.selected();
        if paths.is_empty() {
            return;
        }
        let n = paths.len();
        let items = if n == 1 { "this item".to_string() } else { format!("these {n} items") };
        if self.root.borrow().is_some() {
            // Root has no Trash of yours to use, so this one really is permanent, and says so.
            self.confirm(&format!("Permanently delete {items}?"), "Administrator mode skips the Trash. This can't be undone.", "Delete", Box::new(move |w| w.delete_as_admin(paths)));
        } else if prefs::bool_of("confirmTrash", false) {
            self.confirm(&format!("Move {items} to the Trash?"), "", "Move to Trash", Box::new(move |w| w.trash_now(paths)));
        } else {
            self.trash_now(paths);
        }
    }

    fn trash_now(self: &Rc<Self>, paths: Vec<PathBuf>) {
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let n = paths.len();
            let thrown = paths.clone();
            let (denied, refused) = gio::spawn_blocking(move || {
                let (mut denied, mut refused) = (Vec::new(), Vec::new());
                for p in paths {
                    if let Err(e) = gio::File::for_path(&p).trash(gio::Cancellable::NONE) {
                        if p.symlink_metadata().is_err() {
                            continue;
                        }
                        if e.matches(gio::IOErrorEnum::PermissionDenied) { denied.push(p) } else { refused.push(p) }
                    }
                }
                (denied, refused)
            })
            .await
            .unwrap_or_default();
            let Some(this) = weak.upgrade() else { return };
            this.reload();
            let gone: Vec<PathBuf> = thrown.iter().filter(|p| !denied.contains(p) && !refused.contains(p)).cloned().collect();
            if !gone.is_empty() {
                remember(Undo::Restore(gone));
            }
            if denied.is_empty() && refused.is_empty() {
                this.status.set_text(&format!("Moved {n} item{} to the Trash.", if n == 1 { "" } else { "s" }));
            }
            if !denied.is_empty() {
                this.need_admin("That can't go to the Trash without administrator access.", Box::new(move |w| w.trash_retry(denied)));
            }
            // Some drives have no Trash at all. Say so and offer the honest alternative.
            if !refused.is_empty() {
                let count = refused.len();
                this.confirm(&format!("{count} item{} can't go to the Trash", if count == 1 { "" } else { "s" }), "This drive doesn't have a Trash. Delete permanently instead? This can't be undone.", "Delete", Box::new(move |w| {
                    let weak = Rc::downgrade(w);
                    glib::spawn_future_local(async move {
                        let errors = gio::spawn_blocking(move || refused.iter().filter_map(|p| trash::delete_permanently(p).err().map(|e| e.to_string())).collect::<Vec<_>>()).await.unwrap_or_default();
                        if let Some(this) = weak.upgrade() {
                            this.reload();
                            this.status.set_text(&errors.first().map(|e| format!("Couldn't delete: {e}")).unwrap_or("Deleted.".to_string()));
                        }
                    });
                }));
            }
        });
    }

    fn trash_retry(self: &Rc<Self>, paths: Vec<PathBuf>) {
        let n = paths.len();
        self.confirm(&format!("Permanently delete {n} item{}?", if n == 1 { "" } else { "s" }), "Administrator mode skips the Trash. This can't be undone.", "Delete", Box::new(move |w| w.delete_as_admin(paths)));
    }

    fn delete_as_admin(self: &Rc<Self>, paths: Vec<PathBuf>) {
        let Some(client) = self.root.borrow().clone() else { return };
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let errors = gio::spawn_blocking(move || paths.iter().filter_map(|p| client.delete(p).err()).collect::<Vec<_>>()).await.unwrap_or_default();
            if let Some(this) = weak.upgrade() {
                this.reload();
                this.status.set_text(&errors.first().map(|e| format!("Couldn't delete: {e}")).unwrap_or("Deleted.".to_string()));
            }
        });
    }

    fn open_selected(self: &Rc<Self>) {
        let bits = self.selection.selection();
        if bits.size() == 0 {
            return;
        }
        self.activate(bits.nth(0));
    }

    fn activate(self: &Rc<Self>, pos: u32) {
        let Some(obj) = self.selection.item(pos) else { return };
        let e = entry_of(&obj).clone();
        if e.is_dir {
            self.navigate(e.path, true);
        } else if self.in_archive() {
            self.open_inside(e);
        } else if archive::is_browsable(&e.name) {
            // Double-click looks inside, as in Explorer. Open With still reaches other apps.
            self.navigate(e.path, true);
        } else if let Err(err) = gio::AppInfo::launch_default_for_uri(&gio::File::for_path(&e.path).uri(), None::<&gio::AppLaunchContext>) {
            self.status.set_text(&format!("Couldn't open {}: {err}", e.name));
        }
    }

    // ---------- name prompts: new folder and rename share one small popover-less dialog ----------
    fn ask_name(self: &Rc<Self>, title: &str, start: &str, done: impl Fn(&Rc<Self>, String) + 'static) {
        let dialog = gtk::Window::builder().transient_for(&self.window).modal(true).title(title).default_width(340).resizable(false).build();
        dialog.add_css_class("sea");
        dialog.add_css_class("dialog");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
        body.set_margin_top(14);
        body.set_margin_bottom(14);
        body.set_margin_start(14);
        body.set_margin_end(14);
        let label = gtk::Label::builder().label(title).xalign(0.0).build();
        let entry = gtk::Entry::builder().text(start).activates_default(true).build();
        let keys = gtk::EventControllerKey::new();
        let esc = dialog.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape {
                if let Some(d) = esc.upgrade() {
                    d.close();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        dialog.add_controller(keys);
        body.append(&label);
        body.append(&entry);
        dialog.set_child(Some(&body));
        let weak = Rc::downgrade(self);
        let close = dialog.downgrade();
        entry.connect_activate(move |e| {
            let name = e.text().trim().to_string();
            if name.is_empty() || name.contains('/') {
                return;
            }
            if let Some(this) = weak.upgrade() {
                done(&this, name);
            }
            if let Some(d) = close.upgrade() {
                d.close();
            }
        });
        dialog.present();
        // The name without its extension is what people mean to change.
        let stem = Path::new(start).file_stem().map(|s| s.to_string_lossy().chars().count()).unwrap_or(0);
        entry.select_region(0, stem as i32);
    }

    fn new_folder(self: &Rc<Self>) {
        if let Some((zip, folder)) = self.editing() {
            self.ask_name("New folder", "", move |this, name| {
                let inner = if folder.is_empty() { name } else { format!("{folder}/{name}") };
                this.edit_archive(zip.clone(), Arc::new(move |z, pw| archive::new_folder(z, &inner, pw)));
            });
            return;
        }
        if !self.writable() {
            return;
        }
        self.ask_name("New folder", "", |this, name| {
            let path = this.cwd.borrow().join(name);
            let root = this.root.borrow().clone();
            match root {
                Some(c) => {
                    if let Err(e) = c.mkdir(&path) {
                        this.status.set_text(&format!("Couldn't make that folder: {e}"));
                    }
                }
                None => match std::fs::create_dir(&path) {
                    Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                        this.need_admin("You need administrator access to make a folder here.", Box::new(move |w| {
                            if let Some(c) = w.root.borrow().clone() {
                                let _ = c.mkdir(&path);
                            }
                            w.reload();
                        }));
                    }
                    Err(e) => this.status.set_text(&format!("Couldn't make that folder: {e}")),
                    Ok(()) => remember(Undo::Trash(vec![path])),
                },
            }
            this.reload();
        });
    }

    fn group_key(e: &Entry, field: &str) -> String {
        match field {
            "kind" => kind_of(e).1,
            "date" => {
                let t = date_text(e.mtime);
                t.split_whitespace().next().unwrap_or("").to_string()
            }
            "size" => {
                if e.is_dir {
                    "Folders".into()
                } else if e.size < 1024 * 1024 {
                    "Under 1 MB".into()
                } else if e.size < 100 * 1024 * 1024 {
                    "1 MB – 100 MB".into()
                } else {
                    "Over 100 MB".into()
                }
            }
            _ => String::new(),
        }
    }

    fn compare_entries(a: &Entry, b: &Entry, _field: &str, order: impl Fn(&Entry, &Entry) -> std::cmp::Ordering) -> std::cmp::Ordering {
        let group = prefs::str_of("groupBy", "none");
        if group != "none" {
            let ga = Self::group_key(a, &group);
            let gb = Self::group_key(b, &group);
            if ga != gb {
                return ga.cmp(&gb);
            }
        }
        b.is_dir.cmp(&a.is_dir).then_with(|| order(a, b))
    }

    fn refresh_name_column(self: &Rc<Self>) {
        if let Some(factory) = self.list.row_factory() {
            self.list.set_row_factory(None::<&gtk::ListItemFactory>);
            self.list.set_row_factory(Some(&factory));
        }
    }

    fn cancel_inline_rename(self: &Rc<Self>) {
        if self.inline_rename.borrow_mut().take().is_some() {
            self.refresh_name_column();
        }
    }

    fn commit_rename_to(self: &Rc<Self>, old: PathBuf, name: String) {
        let to = old.with_file_name(&name);
        if to == old || name.is_empty() || name.contains('/') {
            self.status.set_text("That name is not valid.");
            return;
        }
        if to.symlink_metadata().is_ok() {
            self.status.set_text("Something already has that name.");
            return;
        }
        let root = self.root.borrow().clone();
        match root {
            Some(c) => {
                if let Err(e) = c.rename(&old, &to) {
                    self.status.set_text(&format!("Couldn't rename: {e}"));
                } else {
                    self.reload();
                }
            }
            None => match std::fs::rename(&old, &to) {
                Ok(()) => {
                    remember(Undo::Rename(to, old));
                    self.reload();
                }
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                    let old = old.clone();
                    self.need_admin("You need administrator access to rename this.", Box::new(move |w| {
                        if let Some(c) = w.root.borrow().clone() {
                            let _ = c.rename(&old, &to);
                        }
                        w.reload();
                    }));
                }
                Err(e) => self.status.set_text(&format!("Couldn't rename: {e}")),
            },
        }
    }

    fn begin_inline_rename(self: &Rc<Self>) {
        if !self.writable() || self.views.visible_child_name().as_deref() != Some("list") {
            return self.rename_dialog();
        }
        let paths = self.selected();
        let [path] = paths.as_slice() else {
            return self.rename_dialog();
        };
        *self.inline_rename.borrow_mut() = Some(path.clone());
        self.refresh_name_column();
    }

    fn rename_dialog(self: &Rc<Self>) {
        self.rename_impl(false);
    }

    fn rename(self: &Rc<Self>) {
        if self.views.visible_child_name().as_deref() == Some("list") {
            self.begin_inline_rename();
        } else {
            self.rename_impl(false);
        }
    }

    fn rename_impl(self: &Rc<Self>, _inline: bool) {
        if let Some((zip, _)) = self.editing() {
            let wanted = self.selected_inner();
            let [inner] = wanted.as_slice() else { return };
            let inner = inner.clone();
            let start = Path::new(&inner).file_name().unwrap_or_default().to_string_lossy().into_owned();
            self.ask_name("Rename", &start, move |this, name| {
                let inner = inner.clone();
                this.edit_archive(zip.clone(), Arc::new(move |z, pw| archive::rename(z, &inner, &name, pw)));
            });
            return;
        }
        if !self.writable() {
            return;
        }
        let paths = self.selected();
        let [path] = paths.as_slice() else { return };
        let old = path.clone();
        let start = old.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.ask_name("Rename", &start, move |this, name| {
            this.commit_rename_to(old.clone(), name);
        });
    }

    fn transfer_to_folder(self: &Rc<Self>, dest: PathBuf, paths: Vec<PathBuf>) {
        if !self.writable() || paths.is_empty() || !dest.is_dir() {
            return;
        }
        let dest = dest.clone();
        let ctrl = false;
        let mode = core::drop_mode(true, core::same_drive(&paths[0], &dest), ctrl);
        self.transfer(paths, dest, mode);
    }

    fn set_view(&self, name: &str) {
        self.views.set_visible_child_name(name);
        prefs::set_folder_view(&self.cwd.borrow().to_string_lossy(), name);
        self.focus_view();
    }

    fn select_all(&self) {
        if let Some(text) = self.text_focus() {
            let _ = WidgetExt::activate_action(&text, "selection.select-all", None);
            return;
        }
        self.selection.select_all();
    }

    fn edit_path(&self, on: bool) {
        if on {
            self.path_entry.set_text(&self.cwd.borrow().to_string_lossy());
            self.address.set_visible_child_name("entry");
            self.path_entry.grab_focus();
            self.path_entry.select_region(0, -1);
        } else {
            self.address.set_visible_child_name("crumbs");
            self.focus_view();
        }
    }

    fn show_columns_picker(self: &Rc<Self>, anchor: &impl IsA<gtk::Widget>) {
        let pop = gtk::Popover::new();
        pop.set_parent(anchor);
        let page = gtk::Box::new(gtk::Orientation::Vertical, 8);
        page.set_margin_top(12);
        page.set_margin_bottom(12);
        page.set_margin_start(14);
        page.set_margin_end(14);
        page.set_size_request(240, -1);
        let head = gtk::Label::builder().label("Columns").xalign(0.0).build();
        head.add_css_class("pref-head");
        page.append(&head);
        let mut rows: Vec<(&str, &str)> = vec![
            ("Date Modified", "date"),
            ("Size", "size"),
            ("Kind", "kind"),
        ];
        if self.in_trash.get() {
            rows.push(("Original Location", "where"));
        }
        for (label, key) in rows {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let words = gtk::Label::builder().label(label).xalign(0.0).hexpand(true).build();
            let check = gtk::CheckButton::new();
            if let Some(col) = self.columns.borrow().get(key) {
                check.set_active(col.is_visible());
            } else {
                check.set_sensitive(false);
            }
            row.append(&words);
            row.append(&check);
            page.append(&row);
            let weak = Rc::downgrade(self);
            check.connect_toggled(move |c| {
                let Some(w) = weak.upgrade() else { return };
                if let Some(col) = w.columns.borrow().get(key) {
                    col.set_visible(c.is_active());
                    prefs::set(&format!("columnVisible_{key}"), serde_json::json!(c.is_active()));
                }
            });
        }
        pop.set_child(Some(&page));
        pop.popup();
    }
}

// ---------- rows ----------
fn drag_for(win: &Rc<Win>, widget: &impl IsA<gtk::Widget>, item: &gtk::ListItem) {
    let drag = gtk::DragSource::new();
    drag.set_actions(gdk::DragAction::COPY | gdk::DragAction::MOVE);
    let weak = Rc::downgrade(win);
    let cell = item.downgrade();
    drag.connect_prepare(move |_, _, _| {
        let this = weak.upgrade()?;
        let cell = cell.upgrade()?;
        // Dragging something unselected drags that one thing, as everywhere else.
        if !cell.is_selected() {
            this.selection.select_item(cell.position(), true);
        }
        let paths = if this.in_archive() { this.drag_out()? } else { this.selected() };
        let files: Vec<gio::File> = paths.iter().map(gio::File::for_path).collect();
        if files.is_empty() {
            return None;
        }
        let uris = files.iter().map(|f| f.uri().to_string()).collect::<Vec<_>>().join("\r\n") + "\r\n";
        let list = gdk::FileList::from_array(&files);
        Some(gdk::ContentProvider::new_union(&[
            gdk::ContentProvider::for_value(&list.to_value()),
            gdk::ContentProvider::for_bytes("text/uri-list", &glib::Bytes::from_owned(uris.into_bytes())),
        ]))
    });
    drag.connect_drag_begin(|_, _| OWN_DRAG.with(|d| d.set(true)));
    drag.connect_drag_end(|_, _, _| OWN_DRAG.with(|d| d.set(false)));
    widget.add_controller(drag);
}

/// Something you did that can be taken back. Doing anything new ends what could be redone.
fn remember(op: Undo) {
    UNDO.with(|u| {
        let mut u = u.borrow_mut();
        u.push(op);
        if u.len() > 100 {
            u.remove(0);
        }
    });
    REDO.with(|r| r.borrow_mut().clear());
}

fn default_archive_name(paths: &[PathBuf]) -> String {
    match paths {
        [one] => one.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Archive".into()),
        _ => "Archive".to_string(),
    }
}

fn shown_title(shown: &Shown) -> String {
    match shown {
        Shown::One(e) => e.name.clone(),
        Shown::Many(n, _) => format!("{n} items"),
        Shown::Folder(p) => p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Computer".into()),
    }
}

const ITEM_KEY: &str = "sea-item";
const PEEK_LIMIT: u64 = 64 * 1024 * 1024;
const DRAG_LIMIT: u64 = 256 * 1024 * 1024;

fn temp_dir(kind: &str) -> PathBuf {
    let dir = glib::user_runtime_dir().join(format!("sea-files-{}", std::process::id())).join(kind);
    let _ = std::fs::create_dir_all(&dir);
    // Decrypted files can land here.
    use std::os::unix::fs::PermissionsExt;
    if let Some(parent) = dir.parent() {
        let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
    }
    dir
}

/// Takes away what previews and copies left behind, including from a run that crashed.
pub fn clear_temp() {
    let runtime = glib::user_runtime_dir();
    if let Ok(items) = std::fs::read_dir(&runtime) {
        for item in items.flatten() {
            if item.file_name().to_string_lossy().starts_with("sea-files-") {
                let _ = std::fs::remove_dir_all(item.path());
            }
        }
    }
    let _ = std::fs::remove_dir_all(glib::user_cache_dir().join("sea-files/open"));
}

fn item_in(w: &gtk::Widget) -> Option<gtk::ListItem> {
    if let Some(found) = unsafe { w.data::<glib::WeakRef<gtk::ListItem>>(ITEM_KEY) } {
        return unsafe { found.as_ref() }.upgrade();
    }
    let mut child = w.first_child();
    while let Some(c) = child {
        if let Some(found) = item_in(&c) {
            return Some(found);
        }
        child = c.next_sibling();
    }
    None
}

/// The row under a point, anywhere on it. A gesture per cell would miss the padding between columns,
/// and a right click there would wrongly get the empty-space menu.
fn item_under(view: &gtk::Widget, x: f64, y: f64) -> Option<gtk::ListItem> {
    let mut at = view.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(w) = at {
        if w == *view {
            return None;
        }
        if matches!(w.css_name().as_str(), "row" | "child") {
            return item_in(&w);
        }
        at = w.parent();
    }
    None
}

fn info_row(grid: &gtk::Grid, at: i32, key: &str, value: &str) {
    let k = gtk::Label::builder().label(key).xalign(0.0).yalign(0.0).build();
    k.add_css_class("dim");
    let v = gtk::Label::builder().label(value).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).selectable(true).hexpand(true).build();
    grid.attach(&k, 0, at, 1, 1);
    grid.attach(&v, 1, at, 1, 1);
}

fn fill_size(label: gtk::Label, paths: Vec<PathBuf>) {
    glib::spawn_future_local(async move {
        let (bytes, files) = gio::spawn_blocking(move || paths.iter().map(|p| core::tree_size(p)).fold((0, 0), |a, b| (a.0 + b.0, a.1 + b.1))).await.unwrap_or((0, 0));
        label.set_text(&format!("{} in {files} file{}", core::human(bytes), if files == 1 { "" } else { "s" }));
    });
}

fn name_cell(win: &Rc<Win>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    let weak = Rc::downgrade(win);
    factory.connect_setup(move |_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.append(&gtk::Image::builder().pixel_size(22).build());
        let name_stack = gtk::Stack::new();
        let label = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::Middle).hexpand(true).build();
        let entry = gtk::Entry::builder().hexpand(true).build();
        name_stack.add_named(&label, Some("label"));
        name_stack.add_named(&entry, Some("edit"));
        name_stack.set_visible_child_name("label");
        row.append(&name_stack);
        if let Some(win) = weak.upgrade() {
            drag_for(&win, &row, item);
            let weak_w = Rc::downgrade(&win);
            entry.connect_activate(move |e| {
                let Some(w) = weak_w.upgrade() else { return };
                let Some(path) = w.inline_rename.borrow().clone() else { return };
                let text = e.text().to_string();
                *w.inline_rename.borrow_mut() = None;
                w.commit_rename_to(path, text);
                w.refresh_name_column();
            });
            let weak_w = Rc::downgrade(&win);
            let entry_weak = entry.downgrade();
            let focus = gtk::EventControllerFocus::new();
            focus.connect_leave(move |_| {
                let Some(w) = weak_w.upgrade() else { return };
                let Some(e) = entry_weak.upgrade() else { return };
                let Some(path) = w.inline_rename.borrow().clone() else { return };
                let text = e.text().to_string();
                *w.inline_rename.borrow_mut() = None;
                w.commit_rename_to(path, text);
                w.refresh_name_column();
            });
            entry.add_controller(focus);
        }
        unsafe { row.set_data(ITEM_KEY, item.downgrade()) };
        item.set_child(Some(&row));
    });
    let weak = Rc::downgrade(win);
    factory.connect_bind(move |_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        let Some(data) = item.item() else { return };
        let e = entry_of(&data);
        let row = item.child().unwrap();
        let image = row.first_child().unwrap().downcast::<gtk::Image>().unwrap();
        let name_stack = row.last_child().unwrap().downcast::<gtk::Stack>().unwrap();
        let label = name_stack.child_by_name("label").unwrap().downcast::<gtk::Label>().unwrap();
        let entry = name_stack.child_by_name("edit").unwrap().downcast::<gtk::Entry>().unwrap();
        image.set_from_gicon(&kind_of(&e).0);
        label.set_text(&e.name);
        let editing = weak.upgrade().and_then(|w| w.inline_rename.borrow().clone()).is_some_and(|p| p == e.path);
        if editing {
            name_stack.set_visible_child_name("edit");
            entry.set_text(&e.name);
            entry.grab_focus();
            entry.select_region(0, -1);
        } else {
            name_stack.set_visible_child_name("label");
        }
    });
    factory
}

fn text_cell(text: impl Fn(&Entry) -> String + 'static) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, obj| {
        let label = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
        label.add_css_class("dim");
        obj.downcast_ref::<gtk::ListItem>().unwrap().set_child(Some(&label));
    });
    factory.connect_bind(move |_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        let Some(data) = item.item() else { return };
        item.child().unwrap().downcast::<gtk::Label>().unwrap().set_text(&text(&entry_of(&data)));
    });
    factory
}

fn grid_cell(win: &Rc<Win>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    let weak = Rc::downgrade(win);
    factory.connect_setup(move |_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        let cell = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let stack = gtk::Stack::builder().hhomogeneous(true).vhomogeneous(true).halign(gtk::Align::Center).build();
        let icon = gtk::Image::builder().pixel_size(84).build();
        let thumb = gtk::Image::builder().pixel_size(84).build();
        thumb.set_overflow(gtk::Overflow::Hidden);
        stack.add_named(&icon, Some("icon"));
        stack.add_named(&thumb, Some("thumb"));
        stack.set_visible_child_name("icon");
        cell.append(&stack);
        cell.append(&gtk::Label::builder().wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).lines(2).ellipsize(gtk::pango::EllipsizeMode::Middle).justify(gtk::Justification::Center).max_width_chars(14).build());
        if let Some(win) = weak.upgrade() {
            drag_for(&win, &cell, item);
        }
        unsafe { cell.set_data(ITEM_KEY, item.downgrade()) };
        item.set_child(Some(&cell));
    });
    let weak = Rc::downgrade(win);
    factory.connect_bind(move |_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        let Some(data) = item.item() else { return };
        let e = entry_of(&data);
        let cell = item.child().unwrap();
        let stack = cell.first_child().unwrap().downcast::<gtk::Stack>().unwrap();
        let icon = stack.child_by_name("icon").unwrap().downcast::<gtk::Image>().unwrap();
        let thumb = stack.child_by_name("thumb").unwrap().downcast::<gtk::Image>().unwrap();
        let size = (prefs::int_of("gridIconSize", 120) as f64 * 0.7) as i32;
        icon.set_pixel_size(size);
        thumb.set_pixel_size(size);
        cell.last_child().unwrap().downcast::<gtk::Label>().unwrap().set_text(&e.name);
        stack.set_visible_child_name("icon");
        thumb.set_paintable(None::<&gdk::Paintable>);
        icon.set_from_gicon(&kind_of(&e).0);
        unsafe { thumb.set_data(WANT_KEY, 0u64) };
        if !e.is_dir
            && (preview::is_picture(&e.name) || preview::is_video(&e.name) || e.name.to_ascii_lowercase().ends_with(".pdf"))
        {
            if let Some(w) = weak.upgrade() {
                w.thumbs.request(&stack, &thumb, &e.path, w.thumbs_ready.get());
            }
        }
    });
    factory.connect_unbind(|_, obj| {
        let item = obj.downcast_ref::<gtk::ListItem>().unwrap();
        if let Some(cell) = item.child() {
            if let Some(stack) = cell.first_child().and_then(|s| s.downcast::<gtk::Stack>().ok()) {
                stack.set_visible_child_name("icon");
                if let Some(thumb) = stack.child_by_name("thumb").and_then(|t| t.downcast::<gtk::Image>().ok()) {
                    unsafe { thumb.set_data(WANT_KEY, 0u64) };
                    thumb.set_paintable(None::<&gdk::Paintable>);
                }
            }
        }
    });
    factory
}

fn column(title: &str, factory: &gtk::SignalListItemFactory, width: i32, order: impl Fn(&Entry, &Entry) -> std::cmp::Ordering + 'static) -> gtk::ColumnViewColumn {
    let col = gtk::ColumnViewColumn::new(Some(title), Some(factory.clone()));
    col.set_resizable(true);
    col.set_fixed_width(width);
    col.set_sorter(Some(&gtk::CustomSorter::new(move |a, b| {
        let (a, b) = (entry_of(a), entry_of(b));
        Win::compare_entries(&a, &b, "", &order).into()
    })));
    col
}

fn attach_folder_drop(row: &impl IsA<gtk::Widget>, dest: PathBuf, shell: std::rc::Weak<Shell>) {
    let target = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY | gdk::DragAction::MOVE);
    target.connect_drop(move |_, value, _, _| {
        let Ok(list) = value.get::<gdk::FileList>() else { return false };
        if !OWN_DRAG.with(Cell::get) {
            return false;
        }
        let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
        if paths.is_empty() {
            return false;
        }
        if let Some(s) = shell.upgrade() {
            if let Some(w) = s.active_win() {
                w.transfer_to_folder(dest.clone(), paths);
                return true;
            }
        }
        false
    });
    row.add_controller(target);
}

fn attach_tag_drop(row: &impl IsA<gtk::Widget>, tag: String, shell: std::rc::Weak<Shell>) {
    let target = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY | gdk::DragAction::MOVE);
    target.connect_drop(move |_, value, _, _| {
        let Ok(list) = value.get::<gdk::FileList>() else { return false };
        if !OWN_DRAG.with(Cell::get) {
            return false;
        }
        let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
        if paths.is_empty() {
            return false;
        }
        tags::set_tag(&paths, Some(&tag));
        if let Some(s) = shell.upgrade() {
            s.fill_tags();
        }
        true
    });
    row.add_controller(target);
}
fn place_row(glyph: &str, tint: &str, label: &str, extra: Option<gtk::Button>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let tile = gtk::CenterBox::new();
    tile.add_css_class("tile");
    tile.add_css_class(tint);
    tile.set_center_widget(Some(&sym(glyph)));
    tile.set_valign(gtk::Align::Center);
    row.append(&tile);
    row.append(&gtk::Label::builder().label(label).xalign(0.0).hexpand(true).ellipsize(gtk::pango::EllipsizeMode::End).build());
    if let Some(b) = extra {
        row.append(&b);
    }
    row
}

fn sidebar(shell: &Rc<Shell>) -> gtk::Box {
    let side = gtk::Box::new(gtk::Orientation::Vertical, 0);
    side.add_css_class("sidebar");
    side.set_size_request(232, -1);
    // Search on top of the sidebar, as in Settings, so it's the same reach everywhere.
    side.append(&shell.search);
    let head = gtk::Label::builder().label("Favourites").xalign(0.0).build();
    head.add_css_class("side-title");
    side.append(&head);
    side.append(&shell.favourites);
    let weak = Rc::downgrade(shell);
    shell.favourites.connect_row_activated(move |_, row| {
        if let Some(shell) = weak.upgrade() {
            if let (Some(path), Some(win)) = (shell.fav_paths.borrow().get(row.index() as usize).cloned(), shell.active_win()) {
                win.navigate(path, true);
            }
        }
    });
    let head = gtk::Label::builder().label("Tags").xalign(0.0).build();
    head.add_css_class("side-title");
    side.append(&head);
    shell.tags.set_selection_mode(gtk::SelectionMode::None);
    let weak = Rc::downgrade(shell);
    shell.tags.connect_row_activated(move |_, row| {
        if let Some(shell) = weak.upgrade() {
            let i = row.index() as usize;
            if let Some(name) = shell.tag_names.borrow().get(i).cloned() {
                if let Some(win) = shell.active_win() {
                    win.navigate(tags::view(&name), true);
                }
            }
        }
    });
    side.append(&shell.tags);
    let head = gtk::Label::builder().label("Locations").xalign(0.0).build();
    head.add_css_class("side-title");
    side.append(&head);
    shell.locations.set_selection_mode(gtk::SelectionMode::None);
    let weak = Rc::downgrade(shell);
    shell.locations.connect_row_activated(move |_, row| {
        if let Some(shell) = weak.upgrade() {
            shell.place_activated(row.index() as usize);
        }
    });
    side.append(&shell.locations);
    side
}

impl Shell {
    fn active_tab(&self) -> Option<Rc<Tab>> {
        self.tabs.borrow().get(self.current.get()).cloned()
    }

    fn active_win(&self) -> Option<Rc<Win>> {
        let tab = self.active_tab()?;
        let panes = tab.panes.borrow();
        panes.get(tab.active.get()).or_else(|| panes.first()).cloned()
    }

    /// Everything that follows where you are: title, sidebar highlight, tab names and which pane looks
    /// current. Asked for after any change, so none of them can drift.
    fn sync(&self) {
        let active = self.active_win();
        if let Some(w) = &active {
            self.window.set_title(Some(&w.title_text()));
            let at = w.cwd.borrow().clone();
            for (path, row) in self.places.borrow().iter() {
                if *path == at { row.add_css_class("active") } else { row.remove_css_class("active") }
            }
        }
        let tabs = self.tabs.borrow();
        for (i, tab) in tabs.iter().enumerate() {
            if i == self.current.get() { tab.pill.add_css_class("current") } else { tab.pill.remove_css_class("current") }
            let panes = tab.panes.borrow();
            if let Some(p) = panes.get(tab.active.get()).or_else(|| panes.first()) {
                tab.label.set_text(&p.title_text());
            }
            for (k, p) in panes.iter().enumerate() {
                if panes.len() > 1 && k != tab.active.get() { p.main.add_css_class("pane-dim") } else { p.main.remove_css_class("pane-dim") }
            }
        }
        self.strip.set_visible(tabs.len() > 1);
    }

    fn move_tab(self: &Rc<Self>, from: usize, to: usize) {
        if from == to {
            return;
        }
        let mut tabs = self.tabs.borrow_mut();
        if from >= tabs.len() || to >= tabs.len() {
            return;
        }
        let tab = tabs.remove(from);
        tabs.insert(to, tab);
        drop(tabs);
        while let Some(child) = self.pills.first_child() {
            self.pills.remove(&child);
        }
        for tab in self.tabs.borrow().iter() {
            self.pills.append(&tab.pill);
        }
        let cur = self.current.get();
        let new_cur = if cur == from {
            to
        } else if from < cur && to >= cur {
            cur - 1
        } else if from > cur && to <= cur {
            cur + 1
        } else {
            cur
        };
        self.show_tab(new_cur);
    }

    fn wire_tab_drag(self: &Rc<Self>, tab: &Rc<Tab>) {
        const MIME: &str = "application/x-sea-shell-tab";
        let source = gtk::DragSource::new();
        source.set_actions(gdk::DragAction::MOVE);
        let weak = Rc::downgrade(self);
        let held = Rc::downgrade(tab);
        source.connect_prepare(move |_, _, _| {
            let s = weak.upgrade()?;
            let t = held.upgrade()?;
            let at = s.tabs.borrow().iter().position(|x| Rc::ptr_eq(x, &t))?;
            Some(gdk::ContentProvider::for_bytes(
                MIME,
                &glib::Bytes::from(at.to_string().as_bytes()),
            ))
        });
        tab.pill.add_controller(source);

        let formats = gdk::ContentFormats::new(&[MIME]);
        let target = gtk::DropTarget::builder()
            .formats(&formats)
            .actions(gdk::DragAction::MOVE)
            .build();
        let weak = Rc::downgrade(self);
        let held = Rc::downgrade(tab);
        target.connect_drop(move |_, value, _, _| {
            let Ok(bytes) = value.get::<glib::Bytes>() else { return false };
            let Ok(text) = std::str::from_utf8(bytes.as_ref()) else { return false };
            let Ok(from) = text.parse::<usize>() else { return false };
            let Some(s) = weak.upgrade() else { return false };
            let Some(t) = held.upgrade() else { return false };
            let Some(to) = s.tabs.borrow().iter().position(|x| Rc::ptr_eq(x, &t)) else { return false };
            if from != to {
                s.move_tab(from, to);
            }
            true
        });
        tab.pill.add_controller(target);
    }

    fn new_tab(self: &Rc<Self>, start: Option<PathBuf>) {
        let root = gtk::Box::builder().hexpand(true).vexpand(true).build();
        let label = gtk::Label::builder().ellipsize(gtk::pango::EllipsizeMode::End).max_width_chars(18).build();
        let pill = gtk::Box::builder().spacing(4).build();
        pill.add_css_class("tab");
        pill.append(&label);
        let close = gtk::Button::builder().child(&sym("close")).tooltip_text("Close tab").build();
        close.add_css_class("round");
        pill.append(&close);
        let tab = Rc::new(Tab { root: root.clone(), panes: RefCell::new(Vec::new()), active: Cell::new(0), pill: pill.clone(), label });
        let pane = build_pane(self, start);
        root.append(&pane.main);
        tab.panes.borrow_mut().push(pane);
        self.stack.add_child(&root);
        self.pills.append(&pill);
        let weak = Rc::downgrade(self);
        let held = Rc::downgrade(&tab);
        close.connect_clicked(move |_| {
            if let (Some(s), Some(t)) = (weak.upgrade(), held.upgrade()) {
                s.remove_tab(&t);
            }
        });
        let click = gtk::GestureClick::builder().button(0).build();
        let weak = Rc::downgrade(self);
        let held = Rc::downgrade(&tab);
        click.connect_released(move |g, _, _, _| {
            let (Some(s), Some(t)) = (weak.upgrade(), held.upgrade()) else { return };
            if g.current_button() == gdk::BUTTON_MIDDLE {
                s.remove_tab(&t);
            } else {
                let at = s.tabs.borrow().iter().position(|x| Rc::ptr_eq(x, &t));
                if let Some(at) = at {
                    s.show_tab(at);
                }
            }
        });
        pill.add_controller(click);
        self.wire_tab_drag(&tab);
        self.tabs.borrow_mut().push(tab);
        let last = self.tabs.borrow().len() - 1;
        self.show_tab(last);
    }

    fn show_tab(&self, at: usize) {
        self.current.set(at);
        if let Some(tab) = self.active_tab() {
            self.stack.set_visible_child(&tab.root);
        }
        if let Some(w) = self.active_win() {
            self.search.set_text(&w.query.borrow());
            w.focus_view();
        }
        self.sync();
    }

    fn step_tab(&self, step: i32) {
        let n = self.tabs.borrow().len() as i32;
        if n > 1 {
            self.show_tab((self.current.get() as i32 + step).rem_euclid(n) as usize);
        }
    }

    fn remove_tab(&self, tab: &Rc<Tab>) {
        let n = self.tabs.borrow().len();
        if n <= 1 {
            self.window.close();
            return;
        }
        for pane in tab.panes.borrow().iter() {
            pane.pane.stop();
            let open = pane.quick.borrow_mut().take();
            if let Some((q, _)) = open {
                q.close();
            }
        }
        let Some(at) = self.tabs.borrow().iter().position(|x| Rc::ptr_eq(x, tab)) else { return };
        self.stack.remove(&tab.root);
        self.pills.remove(&tab.pill);
        self.tabs.borrow_mut().remove(at);
        let now = self.current.get();
        let next = if now > at || now >= n - 1 { now.saturating_sub(1) } else { now };
        self.show_tab(next);
    }

    fn close_tab(&self) {
        if let Some(tab) = self.active_tab() {
            self.remove_tab(&tab);
        }
    }

    fn send_to_background(self: &Rc<Self>) {
        for tab in self.tabs.borrow().iter() {
            for pane in tab.panes.borrow().iter() {
                pane.cancel_inline_rename();
                if let Some((q, p)) = pane.quick.borrow_mut().take() {
                    p.stop();
                    q.close();
                }
                pane.pane.stop();
            }
        }
        self.search.set_text("");
        save_session(self);
        self.window.set_visible(false);
    }

    /// Fresh tab, nothing selected — same reset the QML primary window does on reopen().
    fn reopen(self: &Rc<Self>, start: Option<PathBuf>) {
        resident::stop_idle_quit();
        while self.tabs.borrow().len() > 1 {
            if let Some(t) = self.tabs.borrow().last().cloned() {
                self.remove_tab(&t);
            }
        }
        if self.active_tab().is_some_and(|t| t.panes.borrow().len() > 1) {
            self.toggle_split();
        }
        self.search.set_text("");
        if let Some(w) = self.active_win() {
            w.cancel_inline_rename();
            w.selection.unselect_all();
            *w.query.borrow_mut() = String::new();
            w.filter.changed(gtk::FilterChange::LessStrict);
            let target = start.filter(|p| p.is_dir() || p.exists()).unwrap_or_else(glib::home_dir);
            w.navigate(target, true);
        }
        self.window.present();
        focus_files_window();
    }

    /// Two folders side by side in this tab. Each has its own place, selection and history.
    fn toggle_split(self: &Rc<Self>) {
        let Some(tab) = self.active_tab() else { return };
        let count = tab.panes.borrow().len();
        while let Some(child) = tab.root.first_child() {
            tab.root.remove(&child);
        }
        if count > 1 {
            let keep = tab.active.get().min(count - 1);
            let chosen = tab.panes.borrow()[keep].clone();
            for p in tab.panes.borrow().iter() {
                if let Some(parent) = p.main.parent() {
                    if let Some(paned) = parent.downcast_ref::<gtk::Paned>() {
                        paned.set_start_child(None::<&gtk::Widget>);
                        paned.set_end_child(None::<&gtk::Widget>);
                    }
                }
                if !Rc::ptr_eq(p, &chosen) {
                    p.pane.stop();
                }
            }
            tab.root.append(&chosen.main);
            chosen.preview_pane.set_visible(prefs::bool_of("previewPane", true));
            chosen.set_compact(false);
            *tab.panes.borrow_mut() = vec![chosen];
            tab.active.set(0);
        } else {
            let first = tab.panes.borrow()[0].clone();
            let second = build_pane(self, Some(first.cwd.borrow().clone()));
            // A preview beside each of two lists leaves no room for the lists.
            first.preview_pane.set_visible(false);
            second.preview_pane.set_visible(false);
            first.set_compact(true);
            second.set_compact(true);
            let paned = gtk::Paned::builder().orientation(gtk::Orientation::Horizontal).start_child(&first.main).end_child(&second.main).wide_handle(true).hexpand(true).vexpand(true).build();
            paned.set_shrink_start_child(false);
            paned.set_shrink_end_child(false);
            tab.root.append(&paned);
            tab.panes.borrow_mut().push(second);
            tab.active.set(1);
        }
        if let Some(w) = self.active_win() {
            w.focus_view();
        }
        self.sync();
    }

    fn pane_focused(&self, win: &Win) {
        if let Some(tab) = self.active_tab() {
            let at = tab.panes.borrow().iter().position(|p| std::ptr::eq(p.as_ref(), win));
            if let Some(at) = at {
                if tab.active.replace(at) != at {
                    self.search.set_text(&win.query.borrow());
                    self.sync();
                }
            }
        }
    }

    /// Drives come and go, so this list is rebuilt whenever the system says something changed.
    fn fill_favourites(self: &Rc<Self>) {
        while let Some(row) = self.favourites.first_child() {
            self.places.borrow_mut().retain(|(_, w)| *w != row);
            self.favourites.remove(&row);
        }
        *self.fav_paths.borrow_mut() = Vec::new();
        for (i, bm) in bookmarks::load().into_iter().enumerate() {
            let tint = if i % 2 == 0 { "tile-0" } else { "tile-1" };
            self.favourites.append(&place_row(bookmarks::glyph(&bm.path), tint, &bm.name, None));
            if let Some(holder) = self.favourites.last_child() {
                self.places.borrow_mut().push((bm.path.clone(), holder.clone()));
                attach_folder_drop(&holder, bm.path.clone(), Rc::downgrade(self));
            }
            self.fav_paths.borrow_mut().push(bm.path);
        }
        self.sync();
    }

    fn fill_tags(self: &Rc<Self>) {
        while let Some(row) = self.tags.first_child() {
            self.places.borrow_mut().retain(|(_, w)| *w != row);
            self.tags.remove(&row);
        }
        *self.tag_names.borrow_mut() = Vec::new();
        let counts = tags::counts();
        for (i, name) in tags::NAMES.iter().enumerate() {
            if counts.get(*name).copied().unwrap_or(0) == 0 {
                continue;
            }
            let tint = match i % 3 {
                0 => "tile-0",
                1 => "tile-1",
                _ => "tile-2",
            };
            self.tags.append(&place_row("label", tint, name, None));
            if let Some(holder) = self.tags.last_child() {
                self.places.borrow_mut().push((tags::view(name), holder.clone()));
                attach_tag_drop(&holder, (*name).to_string(), Rc::downgrade(self));
                self.tag_names.borrow_mut().push((*name).to_string());
            }
        }
        self.sync();
    }

    fn fill_locations(self: &Rc<Self>) {
        while let Some(row) = self.locations.first_child() {
            self.places.borrow_mut().retain(|(_, w)| *w != row);
            self.locations.remove(&row);
        }
        let mut targets = Vec::new();
        let weak_shell = Rc::downgrade(self);
        let add = |row: gtk::Box, place: Place, targets: &mut Vec<Place>| {
            self.locations.append(&row);
            if let (Place::Folder(path), Some(holder)) = (&place, self.locations.last_child()) {
                self.places.borrow_mut().push((path.clone(), holder.clone()));
                if path.is_dir()
                    && !trash::is_trash(path)
                    && !stars::is_view(path)
                    && !recent::is_view(path)
                    && !tags::is_view(path)
                {
                    attach_folder_drop(&holder, path.clone(), weak_shell.clone());
                }
            }
            targets.push(place);
        };
        add(place_row("hard_drive", "tile-1", "Computer", None), Place::Folder(PathBuf::from("/")), &mut targets);
        for mount in self.volumes.mounts() {
            if mount.is_shadowed() {
                continue;
            }
            let Some(path) = mount.root().path() else { continue };
            let button = (mount.can_eject() || mount.can_unmount()).then(|| {
                let b = gtk::Button::builder().child(&sym("eject")).tooltip_text("Eject").build();
                b.add_css_class("round");
                b.add_css_class("drive-eject");
                let weak = Rc::downgrade(self);
                let m = mount.clone();
                b.connect_clicked(move |_| {
                    if let Some(shell) = weak.upgrade() {
                        shell.eject(&m);
                    }
                });
                b
            });
            add(place_row("usb", "tile-1", &mount.name(), button), Place::Folder(path), &mut targets);
        }
        // Plugged in but not mounted: there, and a click away.
        for volume in self.volumes.volumes() {
            if volume.get_mount().is_none() && volume.can_mount() {
                add(place_row("usb", "tile-2", &volume.name(), None), Place::Volume(volume), &mut targets);
            }
        }
        add(place_row("star", "tile-0", "Starred", None), Place::Folder(stars::root()), &mut targets);
        add(place_row("schedule", "tile-2", "Recent", None), Place::Folder(recent::root()), &mut targets);
        // Finder keeps it at the bottom of the sidebar, always in reach. The folder may not exist yet.
        let _ = std::fs::create_dir_all(trash::home_files());
        let _ = std::fs::create_dir_all(trash::home_files().with_file_name("info"));
        add(place_row("delete", "tile-1", "Trash", None), Place::Folder(trash::home_files()), &mut targets);
        // Drop something on the Trash row to throw it away.
        if let Some(holder) = self.locations.last_child() {
            let target = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY | gdk::DragAction::MOVE);
            let weak = Rc::downgrade(self);
            target.connect_drop(move |_, value, _, _| {
                let (Some(this), Ok(list)) = (weak.upgrade().and_then(|s| s.active_win()), value.get::<gdk::FileList>()) else { return false };
                let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
                if paths.is_empty() || !OWN_DRAG.with(Cell::get) {
                    return false;
                }
                this.trash_now(paths);
                true
            });
            holder.add_controller(target);
        }
        *self.targets.borrow_mut() = targets;
        self.sync();
    }

    fn place_activated(self: &Rc<Self>, at: usize) {
        let Some(win) = self.active_win() else { return };
        let targets = self.targets.borrow();
        match targets.get(at) {
            Some(Place::Folder(path)) => {
                let path = path.clone();
                drop(targets);
                win.navigate(path, true);
            }
            Some(Place::Volume(volume)) => {
                let volume = volume.clone();
                drop(targets);
                win.status.set_text("Mounting…");
                let ask = gtk::MountOperation::new(Some(&self.window));
                let (held, w) = (volume.clone(), win.clone());
                volume.mount(gio::MountMountFlags::NONE, Some(&ask), gio::Cancellable::NONE, move |result| match result {
                    Ok(()) => {
                        w.status.set_text("");
                        if let Some(path) = held.get_mount().and_then(|m| m.root().path()) {
                            w.navigate(path, true);
                        }
                    }
                    Err(e) => w.status.set_text(&format!("Couldn't mount it: {e}")),
                });
            }
            None => {}
        }
    }

    fn eject(self: &Rc<Self>, mount: &gio::Mount) {
        let Some(win) = self.active_win() else { return };
        // Leave it first, or the drive is busy because this window is looking at it.
        if let Some(path) = mount.root().path() {
            for tab in self.tabs.borrow().iter() {
                for pane in tab.panes.borrow().iter() {
                    let on_it = pane.cwd.borrow().starts_with(&path);
                    if on_it {
                        pane.navigate(glib::home_dir(), true);
                    }
                }
            }
        }
        win.status.set_text("Ejecting…");
        let w = win.clone();
        let done = move |result: Result<(), glib::Error>| match result {
            Ok(()) => w.status.set_text("Safe to unplug."),
            Err(e) => w.status.set_text(&format!("Couldn't eject it: {e}")),
        };
        let ask = gtk::MountOperation::new(Some(&self.window));
        if mount.can_eject() {
            mount.eject_with_operation(gio::MountUnmountFlags::NONE, Some(&ask), gio::Cancellable::NONE, done);
        } else {
            mount.unmount_with_operation(gio::MountUnmountFlags::NONE, Some(&ask), gio::Cancellable::NONE, done);
        }
    }
}
fn shell_of(window: &gtk::ApplicationWindow) -> Option<Rc<Shell>> {
    unsafe { window.data::<Rc<Shell>>("sea-shell").map(|p| std::rc::Rc::clone(p.as_ref())) }
}

fn focus_files_window() {
    let _ = std::process::Command::new("hyprctl")
        .args(["dispatch", "focuswindow", "class:org.seashell.Files"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

fn save_session(shell: &Shell) {
    let w = shell.window.width();
    let h = shell.window.height();
    if w > 0 && h > 0 {
        prefs::set("windowWidth", serde_json::json!(w));
        prefs::set("windowHeight", serde_json::json!(h));
    }
    let tabs: Vec<String> = shell
        .tabs
        .borrow()
        .iter()
        .filter_map(|t| {
            let panes = t.panes.borrow();
            let pane = panes.get(t.active.get()).or(panes.first())?;
            Some(pane.cwd.borrow().to_string_lossy().into_owned())
        })
        .collect();
    if !tabs.is_empty() {
        prefs::set("windowTabs", serde_json::json!(tabs));
    }
}

fn folder_target(raw: PathBuf) -> PathBuf {
    if raw.is_dir() {
        raw
    } else {
        raw.parent().map(Path::to_path_buf).unwrap_or(raw)
    }
}

fn primary_shell(app: &gtk::Application) -> Option<Rc<Shell>> {
    let shells: Vec<Rc<Shell>> = app
        .windows()
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::ApplicationWindow>())
        .filter_map(shell_of)
        .collect();
    shells.iter().find(|s| s.window.is_visible()).cloned().or_else(|| shells.into_iter().next())
}

fn with_shell(app: &gtk::Application) -> Option<Rc<Shell>> {
    primary_shell(app)
}

fn present_folder(app: &gtk::Application, folder: PathBuf) {
    if let Some(shell) = with_shell(app) {
        if let Some(w) = shell.active_win() {
            w.navigate(folder, true);
        }
        shell.window.present();
    } else {
        open(app, Some(folder));
    }
    focus_files_window();
}

/// D-Bus ShowFolders: open each folder; extra paths get new windows.
pub fn reveal_folders(app: &gtk::Application, paths: Vec<PathBuf>) {
    let mut first = true;
    for raw in paths {
        let folder = folder_target(raw);
        if !folder.is_dir() {
            continue;
        }
        if first {
            first = false;
            present_folder(app, folder);
        } else {
            open(app, Some(folder));
        }
    }
}

/// D-Bus ShowItems: open the parent folder and select the item.
pub fn reveal_items(app: &gtk::Application, paths: Vec<PathBuf>) {
    let mut by_parent: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
    for p in paths {
        if let Some(parent) = p.parent() {
            by_parent.entry(parent.to_path_buf()).or_default().push(p);
        }
    }
    let mut first = true;
    for (parent, items) in by_parent {
        if !parent.is_dir() {
            continue;
        }
        if first {
            first = false;
            if let Some(shell) = with_shell(app) {
                if let Some(w) = shell.active_win() {
                    w.navigate(parent, true);
                    w.select_when_listed(items, 0, None);
                }
                shell.window.present();
            } else {
                open(app, Some(parent.clone()));
                let app = app.clone();
                let items = items.clone();
                glib::idle_add_local_once(move || {
                    if let Some(w) = with_shell(&app).and_then(|s| s.active_win()) {
                        w.select_when_listed(items, 0, None);
                    }
                });
            }
            focus_files_window();
        } else {
            open(app, Some(parent));
        }
    }
}

/// D-Bus ShowItemProperties: parent folder, selection, then Get Info.
pub fn reveal_properties(app: &gtk::Application, paths: Vec<PathBuf>) {
    let good: Vec<PathBuf> = paths.into_iter().filter(|p| p.exists()).collect();
    if good.is_empty() {
        return;
    }
    let parent = folder_target(good[0].parent().map(Path::to_path_buf).unwrap_or_else(|| good[0].clone()));
    let then: Rc<dyn Fn(&Rc<Win>)> = Rc::new(|w| w.properties());
    if let Some(shell) = with_shell(app) {
        if let Some(w) = shell.active_win() {
            w.navigate(parent, true);
            w.select_when_listed(good, 0, Some(then.clone()));
        }
        shell.window.present();
    } else {
        open(app, Some(parent));
        let app = app.clone();
        glib::idle_add_local_once(move || {
            if let Some(w) = with_shell(&app).and_then(|s| s.active_win()) {
                w.select_when_listed(good, 0, Some(then));
            }
        });
    }
    focus_files_window();
}

pub fn raise_or_open(app: &gtk::Application, start: Option<PathBuf>) {
    resident::stop_idle_quit();
    if let Some(shell) = primary_shell(app) {
        if shell.window.is_visible() {
            shell.window.present();
            focus_files_window();
            if let Some(path) = start {
                let folder = folder_target(path);
                if let Some(w) = shell.active_win() {
                    w.navigate(folder, true);
                }
            }
        } else {
            shell.reopen(start.map(folder_target));
        }
        return;
    }
    open(app, start);
}

pub fn open(app: &gtk::Application, start: Option<PathBuf>) {
    let width = prefs::int_of("windowWidth", 1180) as i32;
    let height = prefs::int_of("windowHeight", 720) as i32;
    let window = gtk::ApplicationWindow::builder().application(app).title("Files").default_width(width).default_height(height).build();
    window.add_css_class("sea");
    let search = gtk::SearchEntry::builder().placeholder_text("Search this folder and subfolders").build();
    search.add_css_class("search");
    let stack = gtk::Stack::builder().hexpand(true).vexpand(true).build();
    let pills = gtk::Box::builder().spacing(6).build();
    let strip = gtk::Box::builder().spacing(6).visible(false).build();
    strip.add_css_class("tabstrip");
    let favourites = gtk::ListBox::new();
    favourites.set_selection_mode(gtk::SelectionMode::None);
    let shell = Rc::new(Shell {
        window: window.clone(),
        stack: stack.clone(),
        strip: strip.clone(),
        pills: pills.clone(),
        tabs: RefCell::new(Vec::new()),
        current: Cell::new(0),
        search: search.clone(),
        places: RefCell::new(Vec::new()),
        favourites,
        fav_paths: RefCell::new(Vec::new()),
        tags: gtk::ListBox::new(),
        tag_names: RefCell::new(Vec::new()),
        locations: gtk::ListBox::new(),
        targets: RefCell::new(Vec::new()),
        volumes: gio::VolumeMonitor::get(),
        search_timer: RefCell::new(None),
    });
    let more = gtk::Button::builder().child(&sym("add")).tooltip_text("New tab (Ctrl+T)").action_name("win.new-tab").build();
    more.add_css_class("round");
    strip.append(&pills);
    strip.append(&more);
    let weak = Rc::downgrade(&shell);
    search.connect_search_changed(move |s| {
        let Some(shell) = weak.upgrade() else { return };
        let Some(this) = shell.active_win() else { return };
        *this.query.borrow_mut() = s.text().to_lowercase();
        this.scan_token.set(this.scan_token.get() + 1);
        if let Some(id) = shell.search_timer.borrow_mut().take() {
            id.remove();
        }
        let q = this.query.borrow().clone();
        if q.is_empty() {
            this.filter.changed(gtk::FilterChange::LessStrict);
            this.reload();
            return;
        }
        this.filter.changed(gtk::FilterChange::Different);
        let weak_shell = Rc::downgrade(&shell);
        let id = glib::timeout_add_local(std::time::Duration::from_millis(120), move || {
            if let Some(shell) = weak_shell.upgrade() {
                if let Some(w) = shell.active_win() {
                    w.reload();
                }
                shell.search_timer.borrow_mut().take();
            }
            glib::ControlFlow::Break
        });
        *shell.search_timer.borrow_mut() = Some(id);
    });
    let weak = Rc::downgrade(&shell);
    search.connect_stop_search(move |s| {
        s.set_text("");
        if let Some(this) = weak.upgrade().and_then(|x| x.active_win()) {
            this.focus_view();
        }
    });
    let right = gtk::Box::builder().orientation(gtk::Orientation::Vertical).hexpand(true).build();
    right.append(&strip);
    right.append(&stack);
    let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    body.append(&sidebar(&shell));
    body.append(&right);
    window.set_child(Some(&body));
    window.present();
    for signal in ["mount-added", "mount-removed", "volume-added", "volume-removed"] {
        let weak = Rc::downgrade(&shell);
        shell.volumes.connect_local(signal, false, move |_| {
            if let Some(s) = weak.upgrade() {
                s.fill_locations();
            }
            None
        });
    }
    let shortcuts = gtk::ShortcutController::new();
    for (action, keys) in SHORTCUTS {
        for key in *keys {
            shortcuts.add_shortcut(gtk::Shortcut::new(gtk::ShortcutTrigger::parse_string(key), Some(gtk::NamedAction::new(action))));
        }
    }
    window.add_controller(shortcuts);
    install_actions(&window, &shell);
    let weak_fav = Rc::downgrade(&shell);
    glib::idle_add_local_once(move || {
        if let Some(s) = weak_fav.upgrade() {
            s.fill_favourites();
        }
    });
    let weak_loc = Rc::downgrade(&shell);
    glib::idle_add_local_once(move || {
        if let Some(s) = weak_loc.upgrade() {
            s.fill_locations();
            s.fill_tags();
        }
    });
    let restored = if start.is_none() { prefs::str_list_of("windowTabs") } else { Vec::new() };
    let first = start.or_else(|| restored.first().map(|p| PathBuf::from(p)));
    shell.new_tab(first.filter(|p| p.is_dir() || p.exists()));
    if restored.len() > 1 {
        let rest: Vec<PathBuf> = restored
            .iter()
            .skip(1)
            .map(|p| PathBuf::from(p))
            .filter(|p| p.is_dir() || p.exists())
            .collect();
        if !rest.is_empty() {
            let weak = Rc::downgrade(&shell);
            glib::idle_add_local_once(move || {
                if let Some(s) = weak.upgrade() {
                    for path in rest {
                        s.new_tab(Some(path));
                    }
                }
            });
        }
    }
    let weak_save = Rc::downgrade(&shell);
    let weak_app = app.downgrade();
    window.connect_close_request(move |_| {
        if let Some(shell) = weak_save.upgrade() {
            save_session(&shell);
        }
        if resident::quitting() {
            return glib::Propagation::Proceed;
        }
        let Some(app) = weak_app.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if !resident::keep_warm_enabled() {
            return glib::Propagation::Proceed;
        }
        let visible = app.windows().iter().filter(|w| w.is_visible()).count();
        if visible <= 1 {
            if let Some(shell) = weak_save.upgrade() {
                shell.send_to_background();
            }
            resident::schedule_idle_quit(&app);
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    // Everything else only holds a weak reference, so this is what keeps the window's state alive,
    // and letting go of it when the window goes is what frees it.
    unsafe { window.set_data("sea-shell", shell) };
    window.connect_destroy(|w| unsafe {
        let _ = w.steal_data::<Rc<Shell>>("sea-shell");
    });
    resident::stop_idle_quit();
}
fn install_actions(window: &gtk::ApplicationWindow, shell: &Rc<Shell>) {
    // ---- actions ----
    let act = |name: &str, f: Box<dyn Fn(&Rc<Win>)>| {
        let a = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(shell);
        a.connect_activate(move |_, _| {
            if let Some(this) = weak.upgrade().and_then(|s| s.active_win()) {
                f(&this);
            }
        });
        window.add_action(&a);
    };
    act("quick-look", Box::new(|w| w.quick_look()));
    act("properties", Box::new(|w| w.properties()));
    act("copy-path", Box::new(|w| w.copy_paths()));
    act("duplicate", Box::new(|w| w.duplicate()));
    act("compress", Box::new(|w| w.compress()));
    act("undo", Box::new(|w| w.undo_step(false)));
    act("redo", Box::new(|w| w.undo_step(true)));
    act("delete-permanently", Box::new(|w| w.delete_permanently()));
    act("restore", Box::new(|w| w.restore()));
    act("empty-trash", Box::new(|w| w.empty_trash()));
    act("go-trash", Box::new(|w| w.navigate(trash::home_files(), true)));
    act("extract", Box::new(|w| w.extract_here()));
    act("extract-to", Box::new(|w| w.extract_to()));
    act("compress-dialog", Box::new(|w| w.compress_dialog()));
    act("terminal", Box::new(|w| w.terminal()));
    act("new-file", Box::new(|w| w.new_file()));
    act("admin", Box::new(|w| w.enable_admin()));
    act("prefs", Box::new(|w| {
        let changed: Rc<dyn Fn()> = Rc::new(|| {
            crate::theme::reapply();
            WINS.with(|list| list.borrow().iter().filter_map(std::rc::Weak::upgrade).for_each(|w| w.apply_prefs()));
        });
        prefs_window::open(w.window.upcast_ref(), changed);
    }));
    act("add-bookmark", Box::new(|w| w.toggle_bookmark(true)));
    act("remove-bookmark", Box::new(|w| w.toggle_bookmark(false)));
    act("toggle-star", Box::new(|w| w.toggle_star()));
    act("batch-rename", Box::new(|w| w.batch_rename()));
    act("find-duplicates", Box::new(|w| w.find_duplicates()));
    act("kdeconnect", Box::new(|w| w.share_kdeconnect()));
    let set_tag = gio::SimpleAction::new("set-tag", Some(glib::VariantTy::STRING));
    let weak = Rc::downgrade(shell);
    set_tag.connect_activate(move |_, v| {
        if let Some(this) = weak.upgrade().and_then(|s| s.active_win()) {
            let name = v.and_then(|v| v.str()).filter(|s| !s.is_empty());
            this.set_tag(name);
        }
    });
    window.add_action(&set_tag);
    for (name, always) in [("open-with", false), ("open-always", true)] {
        let a = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let weak = Rc::downgrade(shell);
        a.connect_activate(move |_, v| {
            if let (Some(this), Some(id)) = (weak.upgrade().and_then(|s| s.active_win()), v.and_then(|v| v.str())) {
                this.open_with(id, always);
            }
        });
        window.add_action(&a);
    }
    let sort_by = gio::SimpleAction::new_stateful("sort-by", Some(glib::VariantTy::STRING), &prefs::str_of("sortField", "name").to_variant());
    let weak = Rc::downgrade(shell);
    sort_by.connect_activate(move |a, v| {
        let (Some(this), Some(field)) = (weak.upgrade().and_then(|s| s.active_win()), v.and_then(|v| v.str())) else { return };
        a.set_state(&field.to_variant());
        prefs::set("sortField", serde_json::json!(field));
        this.set_sort(field, prefs::bool_of("sortDescending", false));
    });
    window.add_action(&sort_by);
    let sort_order = gio::SimpleAction::new_stateful("sort-order", Some(glib::VariantTy::BOOLEAN), &prefs::bool_of("sortDescending", false).to_variant());
    let weak = Rc::downgrade(shell);
    sort_order.connect_activate(move |a, v| {
        let (Some(this), Some(down)) = (weak.upgrade().and_then(|s| s.active_win()), v.and_then(|v| v.get::<bool>())) else { return };
        a.set_state(&down.to_variant());
        prefs::set("sortDescending", serde_json::json!(down));
        this.set_sort(&prefs::str_of("sortField", "name"), down);
    });
    window.add_action(&sort_order);
    let group_by = gio::SimpleAction::new_stateful("group-by", Some(glib::VariantTy::STRING), &prefs::str_of("groupBy", "none").to_variant());
    let weak = Rc::downgrade(shell);
    group_by.connect_activate(move |a, v| {
        let (Some(this), Some(field)) = (weak.upgrade().and_then(|s| s.active_win()), v.and_then(|v| v.str())) else { return };
        a.set_state(&field.to_variant());
        prefs::set("groupBy", serde_json::json!(field));
        this.set_sort(&prefs::str_of("sortField", "name"), prefs::bool_of("sortDescending", false));
    });
    window.add_action(&group_by);
    act("cut", Box::new(|w| w.to_clipboard(Mode::Move)));
    act("copy", Box::new(|w| w.to_clipboard(Mode::Copy)));
    act("paste", Box::new(|w| w.paste()));
    act("trash", Box::new(|w| w.trash()));
    act("open", Box::new(|w| w.open_selected()));
    act("rename", Box::new(|w| w.rename()));
    act("new-folder", Box::new(|w| w.new_folder()));
    act("select-all", Box::new(|w| w.select_all()));
    act("close", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.close_tab();
        }
    }));
    act("new-tab", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.new_tab(Some(w.cwd.borrow().clone()));
        }
    }));
    act("next-tab", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.step_tab(1);
        }
    }));
    act("prev-tab", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.step_tab(-1);
        }
    }));
    act("split", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.toggle_split();
        }
    }));
    act("open-new-tab", Box::new(|w| {
        if let (Some(shell), Some(e)) = (w.shell.upgrade(), w.selected_entries().into_iter().next()) {
            shell.new_tab(Some(e.path));
        }
    }));
    act("open-new-window", Box::new(|w| {
        if let (Some(app), Some(e)) = (w.window.application(), w.selected_entries().into_iter().next()) {
            open(&app, Some(e.path));
        }
    }));
    act("view-list", Box::new(|w| w.set_view("list")));
    act("view-grid", Box::new(|w| w.set_view("grid")));
    act("refresh", Box::new(|w| {
        let zip = w.inside.borrow().as_ref().map(|(z, _)| z.clone());
        if let Some(zip) = zip {
            w.listings.borrow_mut().remove(&zip);
        }
        w.reload();
    }));
    act("edit-path", Box::new(|w| w.edit_path(true)));
    act("find", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            shell.search.grab_focus();
        }
    }));
    act("columns", Box::new(|w| {
        if let Some(shell) = w.shell.upgrade() {
            w.show_columns_picker(&shell.window);
        }
    }));
    act("toggle-hidden", Box::new(|w| {
        let hidden = !w.hidden.get();
        w.hidden.set(hidden);
        prefs::set("showHidden", serde_json::json!(hidden));
        w.reload();
    }));
    act("toggle-preview", Box::new(|w| {
        w.preview_pane.set_visible(!w.preview_pane.is_visible());
        w.show_selection();
    }));
    act("go-home", Box::new(|w| w.navigate(glib::home_dir(), true)));
    act("up", Box::new(|w| {
        // Read first: navigate changes this same cell, and an if-let would still be holding it.
        let parent = w.cwd.borrow().parent().map(Path::to_path_buf);
        if let Some(parent) = parent {
            w.navigate(parent, true);
        }
    }));
    act("back", Box::new(|w| {
        let Some(to) = w.back.borrow_mut().pop() else { return };
        w.forward.borrow_mut().push(w.cwd.borrow().clone());
        w.navigate(to, false);
    }));
    act("forward", Box::new(|w| {
        let Some(to) = w.forward.borrow_mut().pop() else { return };
        w.back.borrow_mut().push(w.cwd.borrow().clone());
        w.navigate(to, false);
    }));
    for (name, back) in [("history-back-to", true), ("history-forward-to", false)] {
        let a = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let weak = Rc::downgrade(shell);
        let back = back;
        a.connect_activate(move |_, v| {
            if let (Some(this), Some(s)) = (weak.upgrade().and_then(|x| x.active_win()), v.and_then(|v| v.str())) {
                this.go_history(PathBuf::from(s), back);
            }
        });
        window.add_action(&a);
    }
    for col in ["date", "size", "kind"] {
        let a = gio::SimpleAction::new(&format!("toggle-column-{col}"), None);
        let weak = Rc::downgrade(shell);
        let col = col;
        a.connect_activate(move |_, _| {
            if let Some(w) = weak.upgrade().and_then(|s| s.active_win()) {
                if let Some(c) = w.columns.borrow().get(col) {
                    c.set_visible(!c.is_visible());
                    prefs::set(&format!("columnVisible_{col}"), serde_json::json!(c.is_visible()));
                }
            }
        });
        window.add_action(&a);
    }
}

/// One folder view: its toolbar, list, preview and status. A tab holds one, or two when split.
fn build_pane(shell: &Rc<Shell>, start: Option<PathBuf>) -> Rc<Win> {
    let opened_at = Instant::now();
    let window = shell.window.clone();
    let command = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let main = gtk::Box::new(gtk::Orientation::Vertical, 0);

    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    let query = RefCell::new(String::new());
    let filter = gtk::CustomFilter::new(|_| true);
    let filtered = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    filtered.set_incremental(true);
    let list = gtk::ColumnView::builder().show_row_separators(false).show_column_separators(false).hexpand(true).vexpand(true).build();
    let sorted = gtk::SortListModel::new(Some(filtered), list.sorter());
    sorted.set_incremental(true);
    let selection = gtk::MultiSelection::new(Some(sorted));
    list.set_model(Some(&selection));
    let grid = gtk::GridView::builder().model(&selection).min_columns(2).max_columns(40).enable_rubberband(true).hexpand(true).vexpand(true).build();
    list.set_enable_rubberband(true);

    let views = gtk::Stack::new();
    views.set_transition_type(gtk::StackTransitionType::None);
    let crumbs = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let address = gtk::Stack::builder().hexpand(true).build();
    let path_entry = gtk::Entry::builder().hexpand(true).build();
    path_entry.add_css_class("path-entry");

    let back_btn = icon_button("chevron_left", "Back (Alt+Left)", "win.back");
    let forward_btn = icon_button("chevron_right", "Forward (Alt+Right)", "win.forward");
    let up_btn = icon_button("arrow_upward", "Up one level (Alt+Up)", "win.up");
    let cut = chip("content_cut", "Cut", "Cut (Ctrl+X)", "win.cut");
    let copy = chip("content_copy", "Copy", "Copy (Ctrl+C)", "win.copy");
    let rename = chip("edit", "Rename", "Rename (F2)", "win.rename");
    let del = chip("delete", "Trash", "Move to Trash (Delete)", "win.trash");

    let preview_pane = gtk::Box::new(gtk::Orientation::Vertical, 10);
    preview_pane.add_css_class("panel");
    preview_pane.add_css_class("preview");
    preview_pane.set_overflow(gtk::Overflow::Hidden);
    preview_pane.set_size_request(300, -1);
    let pane = Previewer::new(false);

    let jobs = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).visible(false).build();
    jobs.add_css_class("jobs");
    let banner = gtk::Box::builder().spacing(10).visible(false).build();
    banner.add_css_class("banner");
    let banner_text = gtk::Label::builder().xalign(0.0).hexpand(true).wrap(true).build();
    let banner_btn = gtk::Button::with_label("Continue");
    banner.append(&banner_text);
    banner.append(&banner_btn);
    let status = gtk::Label::builder().xalign(0.0).hexpand(true).ellipsize(gtk::pango::EllipsizeMode::End).build();
    let free = gtk::Label::new(None);

    let win = Rc::new(Win {
        window: window.clone(),
        store,
        rows: RefCell::new(Vec::new()),
        selection: selection.clone(),
        filter: filter.clone(),
        query,
        cwd: RefCell::new(glib::home_dir()),
        back: RefCell::new(Vec::new()),
        forward: RefCell::new(Vec::new()),
        hidden: Cell::new(false),
        scan_token: Cell::new(0),
        crumbs: crumbs.clone(),
        address: address.clone(),
        path_entry: path_entry.clone(),
        shell: Rc::downgrade(shell),
        command: command.clone(),
        main: main.clone(),
        status: status.clone(),
        free: free.clone(),
        views: views.clone(),
        list: list.clone(),
        grid: grid.clone(),
        preview_pane: preview_pane.clone(),
        pane: pane.clone(),
        quick: RefCell::new(None),
        columns: RefCell::new(HashMap::new()),
        root: RefCell::new(None),
        in_trash: Cell::new(false),
        in_recent: Cell::new(false),
        in_starred: Cell::new(false),
        in_tag: Cell::new(false),
        dupe_alive: RefCell::new(None),
        jobs: jobs.clone(),
        inside: RefCell::new(None),
        listings: RefCell::new(HashMap::new()),
        passwords: RefCell::new(HashMap::new()),
        peek_token: Cell::new(0),
        write_btns: RefCell::new(Vec::new()),
        retry: RefCell::new(None),
        banner: banner.clone(),
        banner_text: banner_text.clone(),
        banner_btn: banner_btn.clone(),
        back_btn: back_btn.clone(),
        forward_btn: forward_btn.clone(),
        up_btn: up_btn.clone(),
        selection_btns: vec![cut.clone(), copy.clone(), rename.clone(), del.clone()],
        monitor: RefCell::new(None),
        refresh_timer: RefCell::new(None),
        thumbs: Rc::new(Thumbs::default()),
        thumbs_ready: Cell::new(false),
        preview_timer: RefCell::new(None),
        opened_at,
        first_listing: Cell::new(false),
        inline_rename: RefCell::new(None),
    });

    history_button(back_btn.clone(), &win, true);
    history_button(forward_btn.clone(), &win, false);

    // ---- filter: runs on the row data already in memory, so typing never touches the disk ----
    {
        let weak = Rc::downgrade(&win);
        filter.set_filter_func(move |obj| {
            let Some(this) = weak.upgrade() else { return true };
            let q = this.query.borrow();
            q.is_empty() || entry_of(obj).name.to_lowercase().contains(q.as_str())
        });
    }

    // ---- columns ----
    let name_col = column("Name", &name_cell(&win), 240, |a, b| core::natural_cmp(&a.name, &b.name));
    name_col.set_expand(true);
    let date_col = column("Date Modified", &text_cell(|e| date_text(e.mtime)), 150, |a, b| a.mtime.cmp(&b.mtime));
    let size_col = column("Size", &text_cell(|e| if e.is_dir { "—".into() } else { core::human(e.size) }), 80, |a, b| a.size.cmp(&b.size));
    let kind_col = column("Kind", &text_cell(|e| kind_of(e).1), 150, |a, b| kind_of(a).1.cmp(&kind_of(b).1));
    let where_col = column("Original Location", &text_cell(|e| ORIGINS.with(|o| o.borrow().get(&e.path).cloned().unwrap_or_default())), 220, |a, b| a.name.cmp(&b.name));
    where_col.set_visible(false);
    for (key, col) in [("name", &name_col), ("where", &where_col), ("date", &date_col), ("size", &size_col), ("kind", &kind_col)] {
        list.append_column(col);
        if key != "name" && key != "where" {
            let visible = prefs::bool_of(&format!("columnVisible_{key}"), true);
            col.set_visible(visible);
        }
        win.columns.borrow_mut().insert(key, col.clone());
    }
    grid.set_factory(Some(&grid_cell(&win)));

    let scroller = |child: &gtk::Widget| gtk::ScrolledWindow::builder().child(child).hexpand(true).vexpand(true).build();
    let list_scroll = scroller(list.upcast_ref());
    // Padding belongs here. On the list itself GTK's row width sums stop adding up and it complains.
    list_scroll.set_margin_start(8);
    list_scroll.set_margin_end(8);
    list_scroll.set_margin_bottom(8);
    let grid_scroll = scroller(grid.upcast_ref());
    views.add_named(&list_scroll, Some("list"));
    views.add_named(&grid_scroll, Some("grid"));

    // ---- what happens on a row ----
    let weak = Rc::downgrade(&win);
    list.connect_activate(move |_, pos| {
        if let Some(this) = weak.upgrade() {
            this.activate(pos);
        }
    });
    let weak = Rc::downgrade(&win);
    grid.connect_activate(move |_, pos| {
        if let Some(this) = weak.upgrade() {
            this.activate(pos);
        }
    });
    let weak = Rc::downgrade(&win);
    selection.connect_selection_changed(move |_, _, _| {
        if let Some(this) = weak.upgrade() {
            this.show_selection();
        }
    });
    let weak = Rc::downgrade(&win);
    selection.connect_items_changed(move |_, _, _, _| {
        if let Some(this) = weak.upgrade() {
            this.show_selection();
        }
    });

    // ---- right click, Space and the menu key ----
    let secondary = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
    let weak = Rc::downgrade(&win);
    secondary.connect_pressed(move |g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        if let Some(this) = weak.upgrade() {
            this.right_clicked(x, y);
        }
    });
    views.add_controller(secondary);
    let middle = gtk::GestureClick::builder().button(gdk::BUTTON_MIDDLE).build();
    let weak = Rc::downgrade(&win);
    middle.connect_released(move |_, _, x, y| {
        let Some(this) = weak.upgrade() else { return };
        let Some(item) = item_under(this.views.upcast_ref(), x, y) else { return };
        let Some(data) = item.item() else { return };
        let e = entry_of(&data);
        if !e.is_dir {
            return;
        }
        if let Some(shell) = this.shell.upgrade() {
            shell.new_tab(Some(e.path.clone()));
        }
    });
    views.add_controller(middle);
    let dclick = gtk::GestureClick::new();
    let weak = Rc::downgrade(&win);
    dclick.connect_pressed(move |_, n_press, _, _| {
        if n_press != 2 {
            return;
        }
        let Some(this) = weak.upgrade() else { return };
        if this.selected_count() == 1 && this.writable() {
            this.begin_inline_rename();
        }
    });
    views.add_controller(dclick);
    // In the capture phase: the list itself uses Space to toggle selection.
    let view_keys = gtk::EventControllerKey::new();
    view_keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&win);
    view_keys.connect_key_pressed(move |_, key, _, state| {
        let Some(this) = weak.upgrade() else { return glib::Propagation::Proceed };
        let plain = !state.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SHIFT_MASK);
        if key == gdk::Key::space && plain {
            this.quick_look();
            return glib::Propagation::Stop;
        }
        if key == gdk::Key::Menu || (key == gdk::Key::F10 && state.contains(gdk::ModifierType::SHIFT_MASK)) {
            let on_item = this.selected_count() > 0;
            this.context_menu(60.0, 60.0, on_item);
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    views.add_controller(view_keys);
    let weak = Rc::downgrade(&win);
    banner_btn.connect_clicked(move |_| {
        if let Some(this) = weak.upgrade() {
            this.banner_pressed();
        }
    });

    // ---- files dropped in from anywhere ----
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY | gdk::DragAction::MOVE);
    let weak = Rc::downgrade(&win);
    drop.connect_drop(move |target, value, _, _| {
        let (Some(this), Ok(list)) = (weak.upgrade(), value.get::<gdk::FileList>()) else { return false };
        if this.in_archive() {
            let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
            if this.editing().is_none() || paths.is_empty() {
                this.writable();
                return false;
            }
            this.add_to_archive(paths);
            return true;
        }
        if !this.writable() {
            return false;
        }
        let dest = this.cwd.borrow().clone();
        let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).filter(|p| p.parent() != Some(dest.as_path())).collect();
        if paths.is_empty() {
            return false;
        }
        let ctrl = target.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
        let mode = core::drop_mode(OWN_DRAG.with(Cell::get), core::same_drive(&paths[0], &dest), ctrl);
        this.transfer(paths, dest, mode);
        true
    });
    views.add_controller(drop);

    // ---- toolbar: Finder's back and forward, Explorer's address bar ----
    let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    toolbar.add_css_class("toolbar");
    for b in [&back_btn, &forward_btn, &up_btn] {
        toolbar.append(b);
    }
    crumbs.add_css_class("address");
    let crumb_scroll = gtk::ScrolledWindow::builder().child(&crumbs).vscrollbar_policy(gtk::PolicyType::Never).hscrollbar_policy(gtk::PolicyType::External).hexpand(true).build();
    address.add_named(&crumb_scroll, Some("crumbs"));
    address.add_named(&path_entry, Some("entry"));
    toolbar.append(&address);
    // Clicking the empty end of the address bar types a path, as in Explorer.
    let click = gtk::GestureClick::new();
    let weak = Rc::downgrade(&win);
    click.connect_released(move |_, _, _, _| {
        if let Some(this) = weak.upgrade() {
            this.edit_path(true);
        }
    });
    crumbs.add_controller(click);
    let weak = Rc::downgrade(&win);
    path_entry.connect_activate(move |e| {
        let Some(this) = weak.upgrade() else { return };
        let raw = e.text().to_string();
        let target = if let Some(rest) = raw.strip_prefix('~') { PathBuf::from(format!("{}{rest}", glib::home_dir().display())) } else { PathBuf::from(raw) };
        this.edit_path(false);
        if target.is_dir() || archive::locate(&target).is_some() {
            this.navigate(target, true);
        } else {
            this.status.set_text("There's no folder there.");
        }
    });
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(&win);
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gdk::Key::Escape {
            if let Some(this) = weak.upgrade() {
                this.edit_path(false);
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    path_entry.add_controller(keys);
    let list_btn = icon_button("view_list", "List (Ctrl+2)", "win.view-list");
    let grid_btn = icon_button("grid_view", "Icons (Ctrl+1)", "win.view-grid");
    let columns_btn = icon_button("view_column", "Columns", "win.columns");
    let preview_btn = icon_button("right_panel_open", "Preview pane (Alt+P)", "win.toggle-preview");
    list_btn.add_css_class("on");
    preview_btn.add_css_class("on");
    for b in [&grid_btn, &list_btn, &columns_btn, &preview_btn] {
        toolbar.append(b);
    }

    // ---- command row: Windows 11's New, then the things you do to a selection ----
    command.add_css_class("commandbar");
    let new_folder = chip("create_new_folder", "New folder", "New folder (Ctrl+Shift+N)", "win.new-folder");
    let paste = chip("content_paste", "Paste", "Paste (Ctrl+V)", "win.paste");
    for b in [&new_folder, &cut, &copy, &paste, &rename, &del] {
        command.append(b);
    }
    win.write_btns.borrow_mut().extend([new_folder.clone(), paste.clone()]);

    // ---- preview pane ----
    // A picture's natural size is its full resolution, and a box would hand it that much of the
    // window. This holder has no opinion on width, so the pane stays the width it was given.
    let holder = gtk::ScrolledWindow::builder().child(&pane.root).hscrollbar_policy(gtk::PolicyType::External).vscrollbar_policy(gtk::PolicyType::External).vexpand(true).build();
    preview_pane.append(&holder);

    // ---- status bar: Finder's item count and free space ----
    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    bar.add_css_class("statusbar");
    bar.append(&status);
    bar.append(&free);

    // Two panels floating on the ground, clipped to their corners, with no lines between things.
    let files_panel = gtk::Box::new(gtk::Orientation::Vertical, 0);
    files_panel.add_css_class("panel");
    files_panel.add_css_class("files");
    files_panel.set_overflow(gtk::Overflow::Hidden);
    files_panel.set_hexpand(true);
    files_panel.set_size_request(320, -1);
    files_panel.append(&views);
    // A draggable divider, as Finder and Explorer both have. The pane holds its width when the
    // window resizes, and neither side can be crushed.
    let content = gtk::Paned::builder().orientation(gtk::Orientation::Horizontal).start_child(&files_panel).end_child(&preview_pane).wide_handle(true).build();
    content.set_resize_start_child(true);
    content.set_resize_end_child(false);
    content.set_shrink_start_child(false);
    content.set_shrink_end_child(false);
    main.append(&toolbar);
    main.append(&command);
    main.append(&banner);
    main.append(&content);
    main.append(&jobs);
    main.append(&bar);
    main.set_hexpand(true);
    // Whichever side you click into is the one the keys and the menu act on.
    let focus = gtk::EventControllerFocus::new();
    let weak = Rc::downgrade(&win);
    focus.connect_enter(move |_| {
        if let Some(this) = weak.upgrade() {
            if let Some(shell) = this.shell.upgrade() {
                shell.pane_focused(&this);
            }
        }
    });
    main.add_controller(focus);
    // Middle-click a folder for a new tab, as in a browser.
    let middle = gtk::GestureClick::builder().button(gdk::BUTTON_MIDDLE).build();
    let weak = Rc::downgrade(&win);
    middle.connect_pressed(move |_, _, x, y| {
        let Some(this) = weak.upgrade() else { return };
        let Some(cell) = item_under(this.views.upcast_ref(), x, y) else { return };
        let Some(obj) = this.selection.item(cell.position()) else { return };
        let e = entry_of(&obj).clone();
        if let (true, Some(shell)) = (e.is_dir, this.shell.upgrade()) {
            shell.new_tab(Some(e.path));
        }
    });
    views.add_controller(middle);

    let mark = |b: &gtk::Button, on: bool| if on { b.add_css_class("on") } else { b.remove_css_class("on") };
    views.connect_visible_child_name_notify(move |v| {
        let on_list = v.visible_child_name().as_deref() == Some("list");
        mark(&list_btn, on_list);
        mark(&grid_btn, !on_list);
    });
    preview_pane.connect_visible_notify(move |p| mark(&preview_btn, p.is_visible()));
    if std::env::var_os("SEA_FILES_BENCH").is_some() {
        bench(&window, &list_scroll);
    }
    win.hidden.set(prefs::bool_of("showHidden", false));
    win.preview_pane.set_visible(prefs::bool_of("previewPane", true));
    let single = prefs::str_of("clickToOpen", "double") == "single";
    win.list.set_single_click_activate(single);
    win.grid.set_single_click_activate(single);
    win.set_sort(&prefs::str_of("sortField", "name"), prefs::bool_of("sortDescending", false));
    WINS.with(|list| list.borrow_mut().push(Rc::downgrade(&win)));
    let reveal = start.as_ref().filter(|p| p.is_file()).cloned();
    let folder = start
        .as_ref()
        .and_then(|p| {
            if p.is_file() {
                p.parent().map(Path::to_path_buf)
            } else if p.is_dir() || archive::locate(p).is_some() {
                Some(p.clone())
            } else {
                None
            }
        })
        .unwrap_or_else(glib::home_dir);
    win.navigate(folder, false);
    if let Some(file) = reveal {
        win.select_when_listed(vec![file], 0, None);
    }
    if trace() {
        eprintln!("pane built in {:?}", opened_at.elapsed());
    }
    win
}

/// SEA_FILES_BENCH=1: scroll top to bottom at a steady pace and report how evenly frames arrived.
/// The one number that says whether it feels smooth, measured instead of guessed.
fn bench(window: &gtk::ApplicationWindow, scroller: &gtk::ScrolledWindow) {
    let adj = scroller.vadjustment();
    let (last, gaps, started): (Rc<Cell<i64>>, Rc<RefCell<Vec<i64>>>, Rc<Cell<i64>>) = Default::default();
    let app = window.application();
    scroller.add_tick_callback(move |_, clock| {
        let now = clock.frame_time();
        if adj.upper() <= adj.page_size() + 1.0 {
            return glib::ControlFlow::Continue;
        }
        if started.get() == 0 {
            started.set(now);
        }
        if last.get() != 0 {
            gaps.borrow_mut().push(now - last.get());
        }
        last.set(now);
        let done = (now - started.get()) as f64 / 8_000_000.0;
        adj.set_value((adj.upper() - adj.page_size()) * done.min(1.0));
        if done >= 1.0 {
            let mut g = gaps.borrow().clone();
            g.sort_unstable();
            let n = g.len().max(1);
            eprintln!("scroll: {} frames, median {:.1} ms, 99th {:.1} ms, worst {:.1} ms, over 33 ms: {}",
                g.len(), g[n / 2] as f64 / 1000.0, g[n * 99 / 100] as f64 / 1000.0, g[n - 1] as f64 / 1000.0,
                g.iter().filter(|x| **x > 33_000).count());
            if let Some(app) = &app {
                app.quit();
            }
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
}
