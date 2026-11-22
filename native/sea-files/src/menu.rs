//! The menu bar, published for the shell's global menu as com.canonical.dbusmenu. The bar finds it
//! by asking which well-known name this process owns, and GApplication already owns one, so the
//! same connection serves both. Clicks arrive here and become ordinary window actions.
use gtk::{gio, glib, glib::prelude::*, prelude::*};
use std::collections::HashMap;

const XML: &str = r#"<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
<arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"#;
const PATH: &str = "/com/canonical/menu/0";

/// (label, action, shortcut as the keys held and the key pressed). An empty label is a separator.
type Item = (&'static str, &'static str, &'static [&'static str]);
const SEP: Item = ("", "", &[]);
const MENUS: &[(&str, &[Item])] = &[
    ("File", &[
        ("New Window", "app.new-window", &["Control", "n"]),
        ("New Folder", "win.new-folder", &["Control", "Shift", "n"]),
        SEP,
        ("New Tab", "win.new-tab", &["Control", "t"]),
        ("Open", "win.open", &["Return"]),
        ("Quick Look", "win.quick-look", &["space"]),
        ("Get Info", "win.properties", &["Alt", "Return"]),
        SEP,
        ("Rename", "win.rename", &["F2"]),
        ("Duplicate", "win.duplicate", &["Control", "d"]),
        ("Compress to ZIP", "win.compress", &[]),
        ("Compress Options", "win.compress-dialog", &[]),
        ("Extract Here", "win.extract", &[]),
        ("Extract To", "win.extract-to", &[]),
        ("Move to Trash", "win.trash", &["Delete"]),
        ("Delete Permanently", "win.delete-permanently", &["Shift", "Delete"]),
        SEP,
        ("Open as Administrator", "win.admin", &[]),
        ("Open in Terminal", "win.terminal", &[]),
        ("Preferences", "win.prefs", &["Control", "comma"]),
        SEP,
        ("Close Window", "win.close", &["Control", "w"]),
        ("Quit", "app.quit", &["Control", "q"]),
    ]),
    ("Edit", &[
        ("Cut", "win.cut", &["Control", "x"]),
        ("Copy", "win.copy", &["Control", "c"]),
        ("Copy Path", "win.copy-path", &["Control", "Shift", "c"]),
        ("Paste", "win.paste", &["Control", "v"]),
        SEP,
        ("Select All", "win.select-all", &["Control", "a"]),
        SEP,
        ("Undo", "win.undo", &["Control", "z"]),
        ("Redo", "win.redo", &["Control", "Shift", "z"]),
    ]),
    ("View", &[
        ("Icons", "win.view-grid", &["Control", "1"]),
        ("List", "win.view-list", &["Control", "2"]),
        SEP,
        ("Preview Pane", "win.toggle-preview", &["Alt", "p"]),
        ("Split View", "win.split", &["F3"]),
        ("Hidden Files", "win.toggle-hidden", &["Control", "h"]),
        SEP,
        ("Refresh", "win.refresh", &["F5"]),
        ("Columns…", "win.columns", &[]),
    ]),
    ("Go", &[
        ("Back", "win.back", &["Alt", "Left"]),
        ("Forward", "win.forward", &["Alt", "Right"]),
        ("Up One Level", "win.up", &["Alt", "Up"]),
        SEP,
        ("Home", "win.go-home", &["Alt", "Home"]),
        ("Type a Location", "win.edit-path", &["Control", "l"]),
        ("Find", "win.find", &["Control", "f"]),
    ]),
    ("Tools", &[("Find Duplicates", "win.find-duplicates", &[])]),
];

fn svs(pairs: Vec<(&str, glib::Variant)>) -> HashMap<String, glib::Variant> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

fn item_id(menu: usize, item: usize) -> i32 {
    ((menu as i32 + 1) * 100) + item as i32 + 1
}

fn action_of(id: i32) -> Option<&'static str> {
    let (m, i) = (id / 100 - 1, id % 100 - 1);
    let item = MENUS.get(usize::try_from(m).ok()?)?.1.get(usize::try_from(i).ok()?)?;
    Some(item.1).filter(|a| !a.is_empty())
}

fn item_node(m: usize, i: usize) -> glib::Variant {
    let (text, _, keys) = MENUS[m].1[i];
    let mut props = Vec::new();
    if text.is_empty() {
        props.push(("type", "separator".to_variant()));
    } else {
        props.push(("label", text.to_variant()));
        props.push(("enabled", true.to_variant()));
        if !keys.is_empty() {
            let chord: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
            props.push(("shortcut", vec![chord].to_variant()));
        }
    }
    (item_id(m, i), svs(props), Vec::<glib::Variant>::new()).to_variant()
}

fn menu_node(m: usize) -> glib::Variant {
    let kids: Vec<glib::Variant> = (0..MENUS[m].1.len()).map(|i| item_node(m, i)).collect();
    let props = svs(vec![("label", MENUS[m].0.to_variant()), ("children-display", "submenu".to_variant())]);
    ((m as i32 + 1) * 100, props, kids).to_variant()
}

/// The subtree under `parent`. Hosts ask for one menu at a time when walking a path, so answering
/// every question with the whole tree meant no item could ever be found, and clicks went nowhere.
fn layout(parent: i32) -> glib::Variant {
    let (m, i) = (parent / 100 - 1, parent % 100 - 1);
    if parent > 0 && (m as usize) < MENUS.len() {
        return if i < 0 { menu_node(m as usize) } else { item_node(m as usize, i as usize) };
    }
    let top: Vec<glib::Variant> = (0..MENUS.len()).map(menu_node).collect();
    (0i32, svs(vec![("children-display", "submenu".to_variant())]), top).to_variant()
}

/// A tuple's to_variant() boxes a Variant member as `v`. The protocol wants the struct itself.
fn layout_reply(parent: i32) -> glib::Variant {
    glib::Variant::tuple_from_iter([1u32.to_variant(), layout(parent)])
}

pub fn publish(app: &gtk::Application) {
    let Some(conn) = app.dbus_connection() else { return };
    let Ok(node) = gio::DBusNodeInfo::for_xml(XML) else { return };
    let Some(iface) = node.lookup_interface("com.canonical.dbusmenu") else { return };
    let weak = app.downgrade();
    let registered = conn
        .register_object(PATH, &iface)
        .method_call(move |_conn, _sender, _path, _iface, method, params, inv| match method {
            "GetLayout" => {
                let (parent, _, _): (i32, i32, Vec<String>) = params.get().unwrap_or((0, -1, Vec::new()));
                inv.return_value(Some(&layout_reply(parent)));
            }
            "Event" => {
                let (id, event, _, _): (i32, String, glib::Variant, u32) = params.get().unwrap_or((0, String::new(), ().to_variant(), 0));
                if event == "clicked" {
                    if let (Some(app), Some(action)) = (weak.upgrade(), action_of(id)) {
                        run(&app, action);
                    }
                }
                inv.return_value(None);
            }
            "AboutToShow" => inv.return_value(Some(&(false,).to_variant())),
            "GetGroupProperties" => inv.return_value(Some(&(Vec::<(i32, HashMap<String, glib::Variant>)>::new(),).to_variant())),
            "EventGroup" => inv.return_value(Some(&(Vec::<i32>::new(),).to_variant())),
            "AboutToShowGroup" => inv.return_value(Some(&(Vec::<i32>::new(), Vec::<i32>::new()).to_variant())),
            _ => inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "unknown method"),
        })
        .property(|_conn, _sender, _path, _iface, name| match name {
            "Version" => 3u32.to_variant(),
            "TextDirection" => "ltr".to_variant(),
            "Status" => "normal".to_variant(),
            _ => Vec::<String>::new().to_variant(),
        })
        .build();
    if let Err(e) = registered {
        eprintln!("sea-files: the global menu isn't available: {e}");
    }
    // Lets the registrar answer without a scan. There's no X11 id under Wayland, so the pid stands
    // in, as it does for the old Files. If nothing is listening the name scan still finds us.
    conn.call(
        Some("com.canonical.AppMenu.Registrar"),
        "/com/canonical/AppMenu/Registrar",
        "com.canonical.AppMenu.Registrar",
        "RegisterWindow",
        Some(&(std::process::id(), glib::variant::ObjectPath::try_from(PATH.to_string()).unwrap()).to_variant()),
        None,
        gio::DBusCallFlags::NO_AUTO_START,
        2000,
        gio::Cancellable::NONE,
        |_| {},
    );
}

fn run(app: &gtk::Application, action: &str) {
    match action.split_once('.') {
        Some(("app", name)) => gio::prelude::ActionGroupExt::activate_action(app, name, None),
        Some(("win", name)) => {
            if let Some(window) = app.active_window().or_else(|| app.windows().first().cloned()) {
                if let Some(w) = window.downcast_ref::<gtk::ApplicationWindow>() {
                    gio::prelude::ActionGroupExt::activate_action(w, name, None);
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_id_finds_its_action() {
        assert_eq!(action_of(item_id(1, 1)), Some("win.copy"));
        assert_eq!(action_of(item_id(0, 0)), Some("app.new-window"));
        assert_eq!(action_of(item_id(0, 2)), None, "a separator does nothing");
        assert_eq!(action_of(100), None);
        assert_eq!(action_of(99_900), None);
    }

    #[test]
    fn the_layout_is_what_the_protocol_declares() {
        assert_eq!(layout(0).type_().as_str(), "(ia{sv}av)");
        assert_eq!(layout_reply(0).type_().as_str(), "(u(ia{sv}av))");
    }

    #[test]
    fn a_host_can_walk_down_to_one_menu() {
        let edit = layout(200);
        assert_eq!(edit.child_value(0).get::<i32>(), Some(200));
        assert_eq!(edit.child_value(2).n_children(), MENUS[1].1.len());
        assert_eq!(layout(item_id(1, 1)).child_value(0).get::<i32>(), Some(item_id(1, 1)));
        assert_eq!(layout(0).child_value(2).n_children(), MENUS.len());
    }
}
