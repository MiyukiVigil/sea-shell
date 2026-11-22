//! Keep the first Files process warm: hide instead of quit, reopen on the next launch, idle exit.
use crate::handover;
use gtk::{glib, prelude::*};
use std::cell::Cell;
use std::time::Duration;

const IDLE_QUIT_MS: u64 = 20 * 60 * 1000;

thread_local! {
    static IDLE_QUIT: std::cell::RefCell<Option<glib::SourceId>> = const { std::cell::RefCell::new(None) };
    static QUITTING: Cell<bool> = const { Cell::new(false) };
}

pub fn keep_warm_enabled() -> bool {
    std::env::var_os(handover::ENV_SKIP).is_none() && crate::prefs::bool_of("keepRunning", true)
}

pub fn stop_idle_quit() {
    IDLE_QUIT.with(|c| {
        if let Some(id) = c.borrow_mut().take() {
            id.remove();
        }
    });
}

fn any_window_visible(app: &gtk::Application) -> bool {
    app.windows().iter().any(|w| w.is_visible())
}

pub fn schedule_idle_quit(app: &gtk::Application) {
    if !keep_warm_enabled() {
        return;
    }
    stop_idle_quit();
    let weak = app.downgrade();
    let id = glib::timeout_add_local(Duration::from_millis(IDLE_QUIT_MS), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !any_window_visible(&app) {
            app.quit();
        }
        glib::ControlFlow::Break
    });
    IDLE_QUIT.with(|c| *c.borrow_mut() = Some(id));
}

pub fn quit_for_good(app: &gtk::Application) {
    QUITTING.with(|q| q.set(true));
    stop_idle_quit();
    for w in app.windows() {
        w.destroy();
    }
    app.quit();
}

pub fn quitting() -> bool {
    QUITTING.with(Cell::get)
}
