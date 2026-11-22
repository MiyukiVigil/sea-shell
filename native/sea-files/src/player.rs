//! Video and audio, through libmpv's software renderer. GTK's own media backend isn't a package most
//! machines have, and mpv already plays everything and is here for the wallpapers. Frames arrive as
//! plain pixels, which keeps this free of any OpenGL sharing between mpv and GTK.
//! Nothing here runs until something is actually played, so browsing past videos costs nothing.
use gtk::{gdk, glib, prelude::*};
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};

#[repr(C)]
struct Param {
    kind: c_int,
    data: *mut c_void,
}
const API_TYPE: c_int = 1;
const SW_SIZE: c_int = 17;
const SW_FORMAT: c_int = 18;
const SW_STRIDE: c_int = 19;
const SW_POINTER: c_int = 20;
const UPDATE_FRAME: u64 = 1;

#[link(name = "mpv")]
unsafe extern "C" {
    fn setlocale(category: c_int, locale: *const c_char) -> *mut c_char;
    fn mpv_create() -> *mut c_void;
    fn mpv_initialize(ctx: *mut c_void) -> c_int;
    fn mpv_set_option_string(ctx: *mut c_void, name: *const c_char, value: *const c_char) -> c_int;
    fn mpv_set_property_string(ctx: *mut c_void, name: *const c_char, value: *const c_char) -> c_int;
    fn mpv_get_property_string(ctx: *mut c_void, name: *const c_char) -> *mut c_char;
    fn mpv_free(data: *mut c_void);
    fn mpv_command(ctx: *mut c_void, args: *const *const c_char) -> c_int;
    fn mpv_terminate_destroy(ctx: *mut c_void);
    fn mpv_render_context_create(res: *mut *mut c_void, ctx: *mut c_void, params: *mut Param) -> c_int;
    fn mpv_render_context_set_update_callback(res: *mut c_void, cb: extern "C" fn(*mut c_void), data: *mut c_void);
    fn mpv_render_context_update(res: *mut c_void) -> u64;
    fn mpv_render_context_render(res: *mut c_void, params: *mut Param) -> c_int;
    fn mpv_render_context_free(res: *mut c_void);
}

fn cs(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

extern "C" fn frame_ready(flag: *mut c_void) {
    // mpv's thread. Only ever raises a flag; the window's frame clock does the rest.
    unsafe { (*(flag as *const AtomicBool)).store(true, Ordering::Release) };
}

struct Engine {
    ctx: *mut c_void,
    render: *mut c_void,
    dirty: Box<AtomicBool>,
}

impl Engine {
    fn new() -> Option<Self> {
        unsafe {
            // mpv refuses to start under a locale that writes decimals with a comma, and GTK has
            // just set the user's. LC_NUMERIC is 1 on Linux.
            setlocale(1, c"C".as_ptr());
            let ctx = mpv_create();
            if ctx.is_null() {
                return None;
            }
            for (k, v) in [("vo", "libmpv"), ("config", "no"), ("terminal", "no"), ("idle", "yes"), ("keep-open", "yes"), ("osc", "no"),
                           ("input-default-bindings", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("audio-client-name", "sea-files"), ("hwdec", "no")] {
                mpv_set_option_string(ctx, cs(k).as_ptr(), cs(v).as_ptr());
            }
            if mpv_initialize(ctx) < 0 {
                mpv_terminate_destroy(ctx);
                return None;
            }
            let api = cs("sw");
            let mut params = [Param { kind: API_TYPE, data: api.as_ptr() as *mut c_void }, Param { kind: 0, data: std::ptr::null_mut() }];
            let mut render = std::ptr::null_mut();
            if mpv_render_context_create(&mut render, ctx, params.as_mut_ptr()) < 0 {
                mpv_terminate_destroy(ctx);
                return None;
            }
            let dirty = Box::new(AtomicBool::new(false));
            mpv_render_context_set_update_callback(render, frame_ready, &*dirty as *const AtomicBool as *mut c_void);
            Some(Engine { ctx, render, dirty })
        }
    }

    fn command(&self, args: &[&str]) {
        let owned: Vec<CString> = args.iter().map(|a| cs(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        unsafe { mpv_command(self.ctx, ptrs.as_ptr()) };
    }

    fn set(&self, name: &str, value: &str) {
        unsafe { mpv_set_property_string(self.ctx, cs(name).as_ptr(), cs(value).as_ptr()) };
    }

    fn get(&self, name: &str) -> Option<String> {
        unsafe {
            let p = mpv_get_property_string(self.ctx, cs(name).as_ptr());
            if p.is_null() {
                return None;
            }
            let out = CStr::from_ptr(p).to_string_lossy().into_owned();
            mpv_free(p as *mut c_void);
            Some(out)
        }
    }

    /// A new frame at this size if one is due. rgb0 is mpv's cheapest software format.
    fn frame(&self, width: i32, height: i32) -> Option<gdk::Texture> {
        if !self.dirty.swap(false, Ordering::AcqRel) {
            return None;
        }
        unsafe {
            if mpv_render_context_update(self.render) & UPDATE_FRAME == 0 {
                return None;
            }
            let mut size = [width.max(2) as c_int, height.max(2) as c_int];
            let stride = size[0] as usize * 4;
            let mut buf = vec![0u8; stride * size[1] as usize];
            let format = cs("rgb0");
            let mut st = stride;
            let mut params = [
                Param { kind: SW_SIZE, data: size.as_mut_ptr() as *mut c_void },
                Param { kind: SW_FORMAT, data: format.as_ptr() as *mut c_void },
                Param { kind: SW_STRIDE, data: &mut st as *mut usize as *mut c_void },
                Param { kind: SW_POINTER, data: buf.as_mut_ptr() as *mut c_void },
                Param { kind: 0, data: std::ptr::null_mut() },
            ];
            if mpv_render_context_render(self.render, params.as_mut_ptr()) < 0 {
                return None;
            }
            Some(gdk::MemoryTexture::new(size[0], size[1], gdk::MemoryFormat::R8g8b8x8, &glib::Bytes::from_owned(buf), stride).upcast())
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe {
            mpv_render_context_free(self.render);
            mpv_terminate_destroy(self.ctx);
        }
    }
}

fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}

/// The picture and its controls. One per preview, with mpv started on first use.
pub struct Player {
    pub picture: gtk::Picture,
    pub controls: gtk::Box,
    engine: std::cell::RefCell<Option<Rc<Engine>>>,
    play: gtk::Label,
    time: gtk::Label,
    seek: gtk::Scale,
    mute: gtk::Label,
    syncing: std::cell::Cell<bool>,
}

fn round_button(glyph: &str) -> (gtk::Button, gtk::Label) {
    let label = gtk::Label::new(Some(glyph));
    label.add_css_class("sym");
    let b = gtk::Button::builder().child(&label).build();
    b.add_css_class("round");
    (b, label)
}

impl Player {
    pub fn new() -> Rc<Self> {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Contain).hexpand(true).vexpand(true).build();
        picture.add_css_class("preview-picture");
        picture.set_overflow(gtk::Overflow::Hidden);
        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        controls.add_css_class("player");
        let (play_btn, play) = round_button("pause");
        let (mute_btn, mute) = round_button("volume_up");
        let seek = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 0.001);
        seek.set_hexpand(true);
        seek.set_draw_value(false);
        let time = gtk::Label::new(Some("0:00"));
        time.add_css_class("dim");
        controls.append(&play_btn);
        controls.append(&seek);
        controls.append(&time);
        controls.append(&mute_btn);
        let this = Rc::new(Player { picture, controls, engine: Default::default(), play, time, seek, mute, syncing: Default::default() });
        let weak = Rc::downgrade(&this);
        play_btn.connect_clicked(move |_| {
            if let Some(e) = weak.upgrade().and_then(|t| t.engine.borrow().clone()) {
                e.command(&["cycle", "pause"]);
            }
        });
        let weak = Rc::downgrade(&this);
        mute_btn.connect_clicked(move |_| {
            if let Some(e) = weak.upgrade().and_then(|t| t.engine.borrow().clone()) {
                e.command(&["cycle", "mute"]);
            }
        });
        let weak = Rc::downgrade(&this);
        this.seek.connect_value_changed(move |s| {
            let Some(t) = weak.upgrade() else { return };
            if t.syncing.get() {
                return;
            }
            if let Some(e) = t.engine.borrow().clone() {
                e.set("percent-pos", &format!("{}", s.value() * 100.0));
            }
        });
        let weak = Rc::downgrade(&this);
        this.picture.add_tick_callback(move |pic, _| {
            let Some(t) = weak.upgrade() else { return glib::ControlFlow::Break };
            if let Some(e) = t.engine.borrow().as_ref() {
                let scale = pic.scale_factor();
                if let Some(tex) = e.frame(pic.width() * scale, pic.height() * scale) {
                    pic.set_paintable(Some(&tex));
                }
            }
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
            let Some(t) = weak.upgrade() else { return glib::ControlFlow::Break };
            t.refresh();
            glib::ControlFlow::Continue
        });
        this
    }

    fn refresh(&self) {
        let Some(e) = self.engine.borrow().clone() else { return };
        let number = |name: &str| e.get(name).and_then(|v| v.parse::<f64>().ok());
        let (at, total) = (number("time-pos").unwrap_or(0.0), number("duration").unwrap_or(0.0));
        self.time.set_text(&format!("{} / {}", clock(at), clock(total)));
        self.syncing.set(true);
        self.seek.set_value(if total > 0.0 { at / total } else { 0.0 });
        self.syncing.set(false);
        self.play.set_text(if e.get("pause").as_deref() == Some("yes") { "play_arrow" } else { "pause" });
        self.mute.set_text(if e.get("mute").as_deref() == Some("yes") { "volume_off" } else { "volume_up" });
    }

    /// False if mpv can't start, so the caller can say so instead of showing a dead button.
    pub fn load(&self, path: &Path) -> bool {
        if self.engine.borrow().is_none() {
            *self.engine.borrow_mut() = Engine::new().map(Rc::new);
        }
        let Some(e) = self.engine.borrow().clone() else { return false };
        e.set("pause", "no");
        e.command(&["loadfile", &path.to_string_lossy()]);
        true
    }

    /// Silence right away when the selection moves on. The engine stays for the next file.
    pub fn stop(&self) {
        if let Some(e) = self.engine.borrow().as_ref() {
            e.command(&["stop"]);
        }
        self.picture.set_paintable(None::<&gdk::Paintable>);
    }
}
