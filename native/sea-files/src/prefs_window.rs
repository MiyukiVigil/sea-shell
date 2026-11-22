//! Preferences (Ctrl+,). Finder's Settings and Explorer's Folder Options, in sea's panels. Every
//! change applies straight away and saves itself, like the rest of the shell.
use crate::prefs;
use gtk::{glib, prelude::*};
use serde_json::json;
use std::rc::Rc;

fn section(page: &gtk::Box, title: &str) -> gtk::Box {
    let head = gtk::Label::builder().label(title).xalign(0.0).build();
    head.add_css_class("pref-head");
    page.append(&head);
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 0);
    panel.add_css_class("panel");
    panel.add_css_class("pref-panel");
    page.append(&panel);
    panel
}

fn row(panel: &gtk::Box, title: &str, note: &str, control: &impl IsA<gtk::Widget>) {
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    line.add_css_class("pref-row");
    let words = gtk::Box::new(gtk::Orientation::Vertical, 1);
    words.set_hexpand(true);
    words.append(&gtk::Label::builder().label(title).xalign(0.0).build());
    if !note.is_empty() {
        let n = gtk::Label::builder().label(note).xalign(0.0).wrap(true).build();
        n.add_css_class("dim");
        n.add_css_class("small");
        words.append(&n);
    }
    line.append(&words);
    control.set_valign(gtk::Align::Center);
    line.append(control);
    panel.append(&line);
}

fn toggle(key: &'static str, default: bool, changed: &Rc<dyn Fn()>) -> gtk::Switch {
    let sw = gtk::Switch::builder().active(prefs::bool_of(key, default)).build();
    let changed = changed.clone();
    sw.connect_active_notify(move |s| {
        prefs::set(key, json!(s.is_active()));
        changed();
    });
    sw
}

/// A row of pills, one lit. The shell's own control for "pick one of these".
fn choice(key: &'static str, default: &str, options: &[(&'static str, &str)], changed: &Rc<dyn Fn()>, after: Option<Rc<dyn Fn()>>) -> gtk::Box {
    let holder = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let current = prefs::str_of(key, default);
    let mut group: Option<gtk::ToggleButton> = None;
    for (value, label) in options {
        let b = gtk::ToggleButton::builder().label(*label).active(current == *value).build();
        b.add_css_class("pill-choice");
        if let Some(first) = &group {
            b.set_group(Some(first));
        } else {
            group = Some(b.clone());
        }
        let (changed, value, after) = (changed.clone(), value.to_string(), after.clone());
        b.connect_toggled(move |b| {
            if b.is_active() {
                prefs::set(key, json!(value));
                if let Some(a) = &after {
                    a();
                }
                changed();
            }
        });
        holder.append(&b);
    }
    holder
}

fn icon_themes() -> Vec<String> {
    let mut found = Vec::new();
    for base in [glib::user_data_dir().join("icons"), glib::home_dir().join(".icons"), "/usr/share/icons".into()] {
        let Ok(dirs) = std::fs::read_dir(base) else { continue };
        for d in dirs.flatten() {
            let name = d.file_name().to_string_lossy().into_owned();
            let themed = std::fs::read_to_string(d.path().join("index.theme")).map(|t| t.contains("Directories=")).unwrap_or(false);
            if themed && !name.eq_ignore_ascii_case("hicolor") && !found.contains(&name) {
                found.push(name);
            }
        }
    }
    found.sort_by_key(|n| n.to_lowercase());
    found
}

pub fn open(parent: &gtk::Window, changed: Rc<dyn Fn()>) {
    let window = gtk::Window::builder().transient_for(parent).title("Preferences").default_width(600).default_height(680).build();
    window.add_css_class("sea");
    let page = gtk::Box::new(gtk::Orientation::Vertical, 8);
    page.add_css_class("pref-page");

    let general = section(&page, "General");
    row(&general, "New windows open in", "", &choice("defaultView", "grid", &[("grid", "Icons"), ("list", "List")], &changed, None));
    row(&general, "Remember each folder's view", "A folder you switched to List stays that way.", &toggle("rememberPerFolder", true, &changed));
    row(&general, "Open items with", "", &choice("clickToOpen", "double", &[("double", "Double click"), ("single", "Single click")], &changed, None));
    row(
        &general,
        "Keep running in the background",
        "Closing hides the window so the next Super+E is instant. Quits after 20 minutes unused, or use File → Quit.",
        &toggle("keepRunning", true, &changed),
    );
    row(&general, "Show the preview pane", "Alt+P switches it for the window you're in.", &toggle("previewPane", true, &changed));

    let files = section(&page, "Files");
    row(&files, "Show hidden files", "Names starting with a dot. Ctrl+H switches them.", &toggle("showHidden", false, &changed));
    row(&files, "Ask before moving to the Trash", "", &toggle("confirmTrash", false, &changed));
    row(&files, "Sort by", "", &choice("sortField", "name", &[("name", "Name"), ("date", "Date"), ("size", "Size"), ("kind", "Kind")], &changed, None));
    let size = gtk::Scale::with_range(gtk::Orientation::Horizontal, 48.0, 192.0, 8.0);
    size.set_value(prefs::int_of("gridIconSize", 120) as f64 * 0.7);
    size.set_size_request(200, -1);
    size.set_draw_value(false);
    let on_size = changed.clone();
    size.connect_value_changed(move |s| {
        prefs::set("gridIconSize", json!((s.value() / 0.7) as i64));
        on_size();
    });
    row(&files, "Icon size", "", &size);

    let look = section(&page, "Appearance");
    let own_rows = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let refresh_own: Rc<dyn Fn()> = {
        let own_rows = own_rows.clone();
        Rc::new(move || own_rows.set_visible(prefs::str_of("themeSource", "shell") == "own"))
    };
    row(&look, "Colours and corners", "Follow the desktop, or give Files its own.", &choice("themeSource", "shell", &[("shell", "Desktop"), ("own", "Its own")], &changed, Some(refresh_own.clone())));
    row(&own_rows, "Mode", "", &choice("ownMode", "light", &[("light", "Light"), ("dark", "Dark")], &changed, None));
    let swatches = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    for accent in ["#535a92", "#63c7dd", "#4dd0c4", "#6ea8fe", "#c9a7f5", "#a6e3a1", "#f4c542", "#f48fb1", "#ff9e64"] {
        let dot = gtk::Button::new();
        dot.add_css_class("swatch");
        let provider = gtk::CssProvider::new();
        provider.load_from_string(&format!("button {{ background: {accent}; }}"));
        #[allow(deprecated)]
        dot.style_context().add_provider(&provider, gtk::STYLE_PROVIDER_PRIORITY_USER + 1);
        let on = changed.clone();
        dot.connect_clicked(move |_| {
            prefs::set("ownAccent", json!(accent));
            on();
        });
        swatches.append(&dot);
    }
    row(&own_rows, "Accent", "", &swatches);
    let round = gtk::Scale::with_range(gtk::Orientation::Horizontal, 2.0, 30.0, 1.0);
    round.set_value(prefs::int_of("ownRadius", 24) as f64);
    round.set_size_request(200, -1);
    round.set_draw_value(false);
    let on_round = changed.clone();
    round.connect_value_changed(move |s| {
        prefs::set("ownRadius", json!(s.value() as i64));
        on_round();
    });
    row(&own_rows, "Roundness", "", &round);
    look.append(&own_rows);
    refresh_own();
    let themes = icon_themes();
    let names: Vec<&str> = themes.iter().map(String::as_str).collect();
    let picker = gtk::DropDown::from_strings(&names);
    let current = prefs::str_of("iconTheme", "");
    if let Some(at) = themes.iter().position(|t| *t == current) {
        picker.set_selected(at as u32);
    }
    let on_icons = changed.clone();
    picker.connect_selected_notify(move |p| {
        if let Some(name) = themes.get(p.selected() as usize) {
            prefs::set("iconTheme", json!(name));
            on_icons();
        }
    });
    row(&look, "Icons", "", &picker);

    let scroll = gtk::ScrolledWindow::builder().child(&page).hscrollbar_policy(gtk::PolicyType::Never).build();
    window.set_child(Some(&scroll));
    let keys = gtk::EventControllerKey::new();
    let close = window.downgrade();
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gtk::gdk::Key::Escape {
            if let Some(w) = close.upgrade() {
                w.close();
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    window.add_controller(keys);
    window.present();
}
