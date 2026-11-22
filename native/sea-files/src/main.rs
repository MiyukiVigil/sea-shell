//! sea-files: the sea-shell file manager. One process, any number of windows.
mod handover;
mod resident;
mod duplicates;
mod archive;
mod bookmarks;
mod core;
mod fm1;
mod icons;
mod menu;
mod recent;
mod stars;
mod tags;
mod thumb_cache;
mod ops;
mod player;
mod prefs;
mod prefs_window;
mod preview;
mod previewer;
mod root;
mod theme;
mod trash;
mod window;

use gtk::{gio, glib, prelude::*};

fn main() -> glib::ExitCode {
    // The administrator helper. Decided before anything graphical starts, because this is the part
    // running as root and it has no business loading a toolkit.
    if std::env::args().nth(1).as_deref() == Some("--root-helper") {
        root::serve(std::io::stdin().lock(), std::io::stdout().lock());
        return glib::ExitCode::SUCCESS;
    }
    let args: Vec<String> = std::env::args().collect();
    handover::try_delegate(&args);
    let app = gtk::Application::builder()
        .application_id("org.seashell.Files")
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    app.connect_startup(|app| {
        glib::idle_add_local_once(|| window::clear_temp());
        theme::install();
        menu::publish(app);
        fm1::publish(app);
        handover::listen(app.clone());
        let new_window = gio::SimpleAction::new("new-window", None);
        let weak = app.downgrade();
        new_window.connect_activate(move |_, _| {
            if let Some(app) = weak.upgrade() {
                window::open(&app, None);
            }
        });
        app.add_action(&new_window);
        let quit = gio::SimpleAction::new("quit", None);
        let weak = app.downgrade();
        quit.connect_activate(move |_, _| {
            if let Some(app) = weak.upgrade() {
                resident::quit_for_good(&app);
            }
        });
        app.add_action(&quit);
    });
    app.connect_shutdown(|_| window::clear_temp());
    app.connect_activate(|app| window::raise_or_open(app, None));
    app.connect_open(|app, files, _| {
        for file in files {
            window::raise_or_open(app, file.path());
        }
    });
    app.run()
}
