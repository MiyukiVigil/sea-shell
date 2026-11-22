//! The preview, used twice: the pane beside the files, and Quick Look (Space) at full size.
//! Only the newest request is ever finished, so holding an arrow key through a folder of photos
//! works on the one you stop on, not the fifty you passed.
use crate::core::{self, Entry};
use crate::player::Player;
use crate::preview::{self, Made, Pixels};
use gtk::{gio, glib, prelude::*};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;

pub enum Shown {
    Folder(PathBuf),
    One(Entry),
    Many(u64, u64),
}

pub struct Previewer {
    pub root: gtk::Box,
    big: bool,
    picture: gtk::Picture,
    frame: gtk::AspectFrame,
    play_over: gtk::Button,
    stage: gtk::Overlay,
    player: Rc<Player>,
    icon: gtk::Image,
    text: gtk::Label,
    text_scroll: gtk::ScrolledWindow,
    pages: gtk::Box,
    page_label: gtk::Label,
    title: gtk::Label,
    facts: gtk::Grid,
    token: Cell<u64>,
    current: RefCell<Option<Entry>>,
    page: Cell<u32>,
    page_count: Cell<u32>,
    last_size: Cell<(i32, i32)>,
    resize_wait: RefCell<Option<glib::SourceId>>,
    // Quick Look's reader: every page in one scrolling column, drawn only when near the view.
    reader: gtk::ScrolledWindow,
    sheet: gtk::Box,
    sheets: RefCell<Vec<gtk::Picture>>,
    aspect: Cell<f64>,
    zoom: Cell<f64>,
    drawn: RefCell<HashMap<usize, i32>>,
    drawing: Cell<u32>,
}

const PAGE_GAP: i32 = 12;

fn sym(glyph: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(glyph));
    l.add_css_class("sym");
    l
}

pub fn date_text(ts: i64) -> String {
    glib::DateTime::from_unix_local(ts).and_then(|d| d.format("%-d %b %Y, %H:%M")).map(|s| s.to_string()).unwrap_or_default()
}

pub fn kind_of_name(name: &str, is_dir: bool) -> (gio::Icon, String) {
    if is_dir {
        return (gio::ThemedIcon::new("folder").upcast(), "Folder".to_string());
    }
    let (ty, _) = gio::content_type_guess(Some(name), None::<&[u8]>);
    (gio::content_type_get_icon(&ty), gio::content_type_get_description(&ty).to_string())
}

impl Previewer {
    pub fn new(big: bool) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 10);
        root.set_margin_top(12);
        root.set_margin_bottom(12);
        root.set_margin_start(12);
        root.set_margin_end(12);
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Contain).build();
        picture.add_css_class("preview-picture");
        picture.set_overflow(gtk::Overflow::Hidden);
        // The frame takes the picture's shape, so the rounded clip lands on its corners, not on the
        // empty bands a tall pane leaves around a wide photo.
        let frame = gtk::AspectFrame::builder().child(&picture).vexpand(true).valign(gtk::Align::Center).visible(false).build();
        let stage = gtk::Overlay::builder().child(&frame).build();
        let play_over = gtk::Button::builder().child(&sym("play_arrow")).halign(gtk::Align::Center).valign(gtk::Align::Center).visible(false).build();
        play_over.add_css_class("play-big");
        stage.add_overlay(&play_over);
        let player = Player::new();
        player.picture.set_visible(false);
        player.controls.set_visible(false);
        let icon = gtk::Image::builder().pixel_size(if big { 192 } else { 128 }).vexpand(true).build();
        let text = gtk::Label::builder().xalign(0.0).yalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).selectable(big).build();
        text.add_css_class("preview-text");
        let text_scroll = gtk::ScrolledWindow::builder().child(&text).vexpand(true).visible(false).hscrollbar_policy(gtk::PolicyType::Never).build();
        let page_label = gtk::Label::new(None);
        let pages = gtk::Box::builder().spacing(6).halign(gtk::Align::Center).visible(false).build();
        let title = gtk::Label::builder().xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).build();
        title.add_css_class("preview-title");
        let facts = gtk::Grid::builder().column_spacing(12).row_spacing(3).build();
        let sheet = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(PAGE_GAP).halign(gtk::Align::Center).build();
        let reader = gtk::ScrolledWindow::builder().child(&sheet).vexpand(true).hexpand(true).visible(false).build();
        root.append(&reader);
        root.append(&stage);
        root.append(&player.picture);
        root.append(&icon);
        root.append(&text_scroll);
        root.append(&pages);
        root.append(&player.controls);
        root.append(&title);
        root.append(&facts);
        let this = Rc::new(Previewer { root, big, picture, frame, play_over, stage, player, icon, text, text_scroll, pages, page_label, title, facts, token: Cell::new(0), current: Default::default(), page: Cell::new(1), page_count: Cell::new(1), last_size: Cell::new((0, 0)), resize_wait: Default::default(), reader, sheet, sheets: Default::default(), aspect: Cell::new(1.414), zoom: Cell::new(1.0), drawn: Default::default(), drawing: Cell::new(0) });
        let weak = Rc::downgrade(&this);
        this.reader.vadjustment().connect_value_changed(move |_| {
            if let Some(t) = weak.upgrade() {
                t.note_page();
                t.draw_near();
            }
        });
        // Ctrl+scroll zooms, as in every reader.
        let wheel = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        wheel.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        wheel.connect_scroll(move |c, _, dy| {
            if c.current_event_state().contains(gtk::gdk::ModifierType::CONTROL_MASK) {
                if let Some(t) = weak.upgrade() {
                    t.zoom_by(if dy < 0.0 { 1 } else { -1 });
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        this.reader.add_controller(wheel);
        // A new window size means new pixels, once the dragging has stopped.
        let weak = Rc::downgrade(&this);
        this.root.add_tick_callback(move |root, _| {
            let Some(t) = weak.upgrade() else { return glib::ControlFlow::Break };
            let size = (root.width(), root.height());
            if size != t.last_size.replace(size) && size.0 > 0 {
                if let Some(old) = t.resize_wait.borrow_mut().take() {
                    old.remove();
                }
                let again = Rc::downgrade(&t);
                let id = glib::timeout_add_local_once(std::time::Duration::from_millis(180), move || {
                    if let Some(t) = again.upgrade() {
                        t.resize_wait.borrow_mut().take();
                        t.resized();
                    }
                });
                *t.resize_wait.borrow_mut() = Some(id);
            }
            glib::ControlFlow::Continue
        });
        for (glyph, step) in [("chevron_left", -1), ("chevron_right", 1)] {
            let b = gtk::Button::builder().child(&sym(glyph)).build();
            b.add_css_class("round");
            let weak = Rc::downgrade(&this);
            b.connect_clicked(move |_| {
                if let Some(t) = weak.upgrade() {
                    t.turn_page(step);
                }
            });
            if step < 0 {
                this.pages.append(&b);
                this.pages.append(&this.page_label);
            } else {
                this.pages.append(&b);
            }
        }
        let weak = Rc::downgrade(&this);
        this.play_over.connect_clicked(move |_| {
            if let Some(t) = weak.upgrade() {
                t.start_playing();
            }
        });
        this
    }

    fn set_facts(&self, rows: &[(String, String)]) {
        while let Some(child) = self.facts.first_child() {
            self.facts.remove(&child);
        }
        for (i, (k, v)) in rows.iter().enumerate() {
            let key = gtk::Label::builder().label(k).xalign(0.0).yalign(0.0).build();
            key.add_css_class("dim");
            let value = gtk::Label::builder().label(v).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).hexpand(true).build();
            self.facts.attach(&key, 0, i as i32, 1, 1);
            self.facts.attach(&value, 1, i as i32, 1, 1);
        }
    }

    fn add_facts(&self, rows: &[(String, String)]) {
        let start = { let mut n = 0; let mut c = self.facts.first_child(); while let Some(w) = c { n += 1; c = w.next_sibling(); } n / 2 };
        for (i, (k, v)) in rows.iter().enumerate() {
            let key = gtk::Label::builder().label(k).xalign(0.0).yalign(0.0).build();
            key.add_css_class("dim");
            let value = gtk::Label::builder().label(v).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).hexpand(true).build();
            self.facts.attach(&key, 0, start + i as i32, 1, 1);
            self.facts.attach(&value, 1, start + i as i32, 1, 1);
        }
    }

    fn clear(&self) {
        self.frame.set_visible(false);
        self.stage.set_visible(true);
        self.play_over.set_visible(false);
        self.text_scroll.set_visible(false);
        self.pages.set_visible(false);
        self.reader.set_visible(false);
        self.facts.set_visible(true);
        self.close_reader();
        self.player.stop();
        self.player.picture.set_visible(false);
        self.player.controls.set_visible(false);
        self.icon.set_visible(true);
    }

    fn show_pixels(&self, pixels: Pixels) {
        self.frame.set_ratio(pixels.width as f32 / pixels.height.max(1) as f32);
        self.picture.set_paintable(Some(&pixels.texture()));
        self.frame.set_visible(true);
        self.icon.set_visible(false);
    }

    pub fn stop(&self) {
        self.token.set(self.token.get() + 1);
        self.player.stop();
    }

    /// The most a picture can be drawn at right now, in real pixels. Never more than a small step
    /// above what's on screen, because shrinking a much larger image is what makes it look broken.
    fn longest(&self) -> u32 {
        let scale = self.root.scale_factor().max(1);
        let (w, h) = (self.root.width(), self.root.height());
        let room = if w > 0 { w.max(h - 150) } else if self.big { 1200 } else { 300 };
        (room.max(64) * scale) as u32
    }

    fn resized(self: &Rc<Self>) {
        if self.reader.is_visible() {
            self.layout_sheets();
            return;
        }
        // A picture or poster made for a different size gets made again.
        if self.frame.is_visible() && !self.player.picture.is_visible() {
            let page = self.page.get();
            self.refresh_picture(page);
        }
    }

    fn refresh_picture(self: &Rc<Self>, page: u32) {
        let Some(entry) = self.current.borrow().clone() else { return };
        let token = self.token.get();
        let (path, name, longest) = (entry.path.clone(), entry.name.clone(), self.longest());
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let lower = name.to_ascii_lowercase();
            let made = gio::spawn_blocking(move || {
                if lower.ends_with(".pdf") { preview::pdf_page(&path, page, longest) } else if preview::is_picture(&lower) { preview::decode_fit(&path, longest) } else { None }
            })
            .await;
            if let (Some(this), Ok(Some(pixels))) = (weak.upgrade(), made) {
                if this.token.get() == token {
                    this.show_pixels(pixels);
                }
            }
        });
    }

    // ---------- Quick Look's PDF reader ----------
    fn page_width(&self) -> i32 {
        let room = (self.reader.width() - 24).max(300);
        // Filling a very wide window would make a page taller than anyone can read at a glance.
        let fit = room.min(1100);
        (fit as f64 * self.zoom.get()) as i32
    }

    fn open_reader(self: &Rc<Self>, pages: u32, aspect: f64) {
        self.aspect.set(aspect);
        self.zoom.set(1.0);
        self.page_count.set(pages);
        self.stage.set_visible(false);
        self.icon.set_visible(false);
        self.facts.set_visible(false);
        self.reader.set_visible(true);
        self.pages.set_visible(pages > 1);
        self.page_label.set_text(&format!("Page 1 of {pages}"));
        let mut sheets = self.sheets.borrow_mut();
        for i in 0..pages {
            let pic = gtk::Picture::builder().content_fit(gtk::ContentFit::Fill).can_shrink(false).build();
            pic.add_css_class("pdf-page");
            pic.set_overflow(gtk::Overflow::Hidden);
            let _ = i;
            self.sheet.append(&pic);
            sheets.push(pic);
        }
        drop(sheets);
        let weak = Rc::downgrade(self);
        // The reader has no width until it has been laid out.
        glib::idle_add_local_once(move || {
            if let Some(t) = weak.upgrade() {
                t.layout_sheets();
            }
        });
    }

    fn close_reader(&self) {
        for pic in self.sheets.borrow_mut().drain(..) {
            self.sheet.remove(&pic);
        }
        self.drawn.borrow_mut().clear();
        self.reader.vadjustment().set_value(0.0);
    }

    fn layout_sheets(self: &Rc<Self>) {
        let width = self.page_width();
        let height = (width as f64 * self.aspect.get()) as i32;
        for pic in self.sheets.borrow().iter() {
            pic.set_size_request(width, height);
        }
        self.draw_near();
    }

    /// Only pages near the view are ever drawn, and ones far behind are let go, so a 900-page manual
    /// costs about what a short one does.
    fn draw_near(self: &Rc<Self>) {
        let sheets = self.sheets.borrow();
        if sheets.is_empty() {
            return;
        }
        let scale = self.root.scale_factor().max(1);
        let width = self.page_width();
        let want = width * scale;
        let adj = self.reader.vadjustment();
        let (top, view) = (adj.value(), adj.page_size().max(1.0));
        let step = (width as f64 * self.aspect.get()) + PAGE_GAP as f64;
        let first = ((top - view) / step).floor().max(0.0) as usize;
        let last = (((top + view * 2.0) / step).ceil() as usize).min(sheets.len() - 1);
        let far = 8;
        for (i, pic) in sheets.iter().enumerate() {
            if (i + far < first || i > last + far) && self.drawn.borrow_mut().remove(&i).is_some() {
                pic.set_paintable(None::<&gtk::gdk::Paintable>);
            }
        }
        let Some(entry) = self.current.borrow().clone() else { return };
        for i in first..=last {
            if self.drawing.get() >= 3 {
                break;
            }
            if self.drawn.borrow().get(&i) == Some(&want) {
                continue;
            }
            self.drawn.borrow_mut().insert(i, want);
            self.drawing.set(self.drawing.get() + 1);
            let token = self.token.get();
            let path = entry.path.clone();
            let weak = Rc::downgrade(self);
            glib::spawn_future_local(async move {
                let pixels = gio::spawn_blocking(move || preview::pdf_page_at_width(&path, i as u32 + 1, want as u32)).await;
                let Some(this) = weak.upgrade() else { return };
                this.drawing.set(this.drawing.get() - 1);
                if this.token.get() == token {
                    if let Ok(Some(p)) = pixels {
                        if let Some(pic) = this.sheets.borrow().get(i) {
                            // This page may not share the first page's shape.
                            pic.set_size_request((p.width as i32) / scale, (p.height as i32) / scale);
                            pic.set_paintable(Some(&p.texture()));
                        }
                    }
                    this.draw_near();
                }
            });
        }
    }

    fn note_page(&self) {
        let count = self.page_count.get();
        if count == 0 {
            return;
        }
        let adj = self.reader.vadjustment();
        let step = (self.page_width() as f64 * self.aspect.get()) + PAGE_GAP as f64;
        let at = ((adj.value() + adj.page_size() / 2.0) / step) as u32 + 1;
        let at = at.clamp(1, count);
        if self.page.replace(at) != at {
            self.page_label.set_text(&format!("Page {at} of {count}"));
        }
    }

    /// Arrow keys read the document while one is open. False means the caller can use the key.
    pub fn scroll_reader(&self, down: bool) -> bool {
        if !self.reader.is_visible() {
            return false;
        }
        let adj = self.reader.vadjustment();
        adj.set_value(adj.value() + if down { 90.0 } else { -90.0 });
        true
    }

    pub fn zoom_by(self: &Rc<Self>, step: i32) {
        if !self.reader.is_visible() {
            return;
        }
        let z = if step == 0 { 1.0 } else { (self.zoom.get() * if step > 0 { 1.2 } else { 1.0 / 1.2 }).clamp(0.5, 4.0) };
        self.zoom.set(z);
        self.layout_sheets();
    }

    pub fn show(self: &Rc<Self>, what: &Shown) {
        let token = self.token.get() + 1;
        self.token.set(token);
        self.clear();
        *self.current.borrow_mut() = None;
        let entry = match what {
            Shown::Many(count, bytes) => {
                self.icon.set_icon_name(Some("edit-copy"));
                self.title.set_text(&format!("{count} items"));
                self.set_facts(&if *bytes > 0 { vec![("Size".to_string(), core::human(*bytes))] } else { Vec::new() });
                return;
            }
            Shown::Folder(path) => Entry {
                name: if *path == crate::trash::home_files() { "Trash".to_string() } else { path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or("Computer".into()) },
                path: path.clone(),
                is_dir: true,
                size: 0,
                mtime: std::fs::metadata(path).ok().map(|m| { use std::os::unix::fs::MetadataExt; m.mtime() }).unwrap_or(0),
            },
            Shown::One(e) => e.clone(),
        };
        let (icon, kind) = kind_of_name(&entry.name, entry.is_dir);
        self.icon.set_from_gicon(&icon);
        self.title.set_text(&entry.name);
        let mut rows = vec![("Kind".to_string(), kind)];
        if !entry.is_dir {
            rows.push(("Size".to_string(), core::human(entry.size)));
        }
        rows.push(("Modified".to_string(), date_text(entry.mtime)));
        self.set_facts(&rows);
        *self.current.borrow_mut() = Some(entry.clone());
        self.page.set(1);
        let (path, name, is_dir, longest) = (entry.path.clone(), entry.name.clone(), entry.is_dir, self.longest());
        let weak = Rc::downgrade(self);
        let started = std::time::Instant::now();
        glib::spawn_future_local(async move {
            let made = gio::spawn_blocking({
                let name = name.clone();
                move || preview::make(&path, &name, is_dir, longest)
            })
            .await
            .unwrap_or(Made::Nothing);
            let Some(this) = weak.upgrade() else { return };
            if this.token.get() != token {
                return;
            }
            this.present(made);
            if std::env::var_os("SEA_FILES_TRACE").is_some() {
                eprintln!("preview: {name} in {:?}", started.elapsed());
            }
        });
    }

    fn present(self: &Rc<Self>, made: Made) {
        let fact = |k: &str, v: String| (k.to_string(), v);
        match made {
            Made::Picture { pixels, width, height } => {
                self.show_pixels(pixels);
                self.add_facts(&[fact("Dimensions", format!("{width} × {height}"))]);
            }
            Made::Texture(tex) => {
                self.frame.set_ratio(tex.width() as f32 / tex.height().max(1) as f32);
                self.add_facts(&[fact("Dimensions", format!("{} × {}", tex.width(), tex.height()))]);
                self.picture.set_paintable(Some(&tex));
                self.frame.set_visible(true);
                self.icon.set_visible(false);
            }
            Made::Text(text) => {
                self.text.set_text(&text);
                self.text_scroll.set_visible(true);
                self.icon.set_visible(false);
            }
            Made::Pdf { pixels, pages, aspect } if self.big => {
                drop(pixels);
                self.open_reader(pages, aspect);
            }
            Made::Pdf { pixels, pages, .. } => {
                self.show_pixels(pixels);
                self.page_count.set(pages);
                self.page_label.set_text(&format!("Page 1 of {pages}"));
                self.pages.set_visible(pages > 1);
                self.add_facts(&[fact("Pages", pages.to_string())]);
            }
            Made::Video { poster, facts } => {
                if let Some(p) = poster {
                    self.show_pixels(p);
                }
                self.add_facts(&facts);
                self.play_over.set_visible(true);
                if self.big {
                    self.start_playing();
                }
            }
            Made::Audio { cover, facts } => {
                if let Some(p) = cover {
                    self.show_pixels(p);
                }
                self.add_facts(&facts);
                self.play_over.set_visible(true);
                if self.big {
                    self.start_playing();
                }
            }
            Made::Listing { text, count } => {
                self.text.set_text(&text);
                self.text_scroll.set_visible(true);
                self.icon.set_visible(false);
                self.add_facts(&[fact("Contains", format!("{count} items"))]);
            }
            Made::Folder { count, text } => {
                self.add_facts(&[fact("Contains", if count == 1 { "1 item".into() } else { format!("{count} items") })]);
                if self.big && count > 0 {
                    self.text.set_text(&text);
                    self.text_scroll.set_visible(true);
                    self.icon.set_visible(false);
                }
            }
            Made::Nothing => {}
        }
    }

    fn start_playing(&self) {
        let Some(entry) = self.current.borrow().clone() else { return };
        if !self.player.load(&entry.path) {
            self.title.set_text("This can't play here: mpv isn't available.");
            return;
        }
        self.play_over.set_visible(false);
        self.player.controls.set_visible(true);
        if preview::is_video(&entry.name) {
            self.stage.set_visible(false);
            self.icon.set_visible(false);
            self.player.picture.set_visible(true);
        }
    }

    pub fn turn_page(self: &Rc<Self>, step: i32) {
        let Some(entry) = self.current.borrow().clone() else { return };
        let next = self.page.get() as i32 + step;
        if next < 1 || next > self.page_count.get() as i32 || !self.pages.is_visible() {
            return;
        }
        if self.reader.is_visible() {
            let page_height = self.page_width() as f64 * self.aspect.get() + PAGE_GAP as f64;
            self.reader.vadjustment().set_value((next - 1) as f64 * page_height);
            return;
        }
        self.page.set(next as u32);
        self.page_label.set_text(&format!("Page {next} of {}", self.page_count.get()));
        let token = self.token.get();
        let (path, longest) = (entry.path.clone(), self.longest());
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let page = gio::spawn_blocking(move || preview::pdf_page(&path, next as u32, longest)).await;
            if let (Some(this), Ok(Some(pixels))) = (weak.upgrade(), page) {
                if this.token.get() == token && this.page.get() == next as u32 {
                    this.show_pixels(pixels);
                }
            }
        });
    }
}
