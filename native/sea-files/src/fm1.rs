//! org.freedesktop.FileManager1 — "Open containing folder" from browsers, Steam, VS Code, etc.
use gtk::{gio, glib, glib::prelude::*, prelude::*};
use std::path::PathBuf;

const BUS: &str = "org.freedesktop.FileManager1";
const PATH: &str = "/org/freedesktop/FileManager1";

const XML: &str = r#"<node><interface name="org.freedesktop.FileManager1">
<method name="ShowFolders"><arg type="as" direction="in" name="URIs"/><arg type="s" direction="in" name="StartupId"/></method>
<method name="ShowItems"><arg type="as" direction="in" name="URIs"/><arg type="s" direction="in" name="StartupId"/></method>
<method name="ShowItemProperties"><arg type="as" direction="in" name="URIs"/><arg type="s" direction="in" name="StartupId"/></method>
</interface></node>"#;

pub(crate) fn path_from_uri(uri: &str) -> Option<PathBuf> {
    if uri.is_empty() {
        return None;
    }
    if uri.starts_with('/') {
        return Some(PathBuf::from(uri));
    }
    gio::File::for_uri(uri).path()
}

fn paths_from_params(params: &glib::Variant) -> Vec<PathBuf> {
    let (uris, _): (Vec<String>, String) = params.get().unwrap_or((Vec::new(), String::new()));
    uris.into_iter().filter_map(|u| path_from_uri(&u)).collect()
}

pub fn publish(app: &gtk::Application) {
    let Some(conn) = app.dbus_connection() else {
        return;
    };
    let Ok(node) = gio::DBusNodeInfo::for_xml(XML) else {
        return;
    };
    let Some(iface) = node.lookup_interface("org.freedesktop.FileManager1") else {
        return;
    };
    let weak = app.downgrade();
    let registered = conn
        .register_object(PATH, &iface)
        .method_call(move |_conn, _sender, _path, _iface, method, params, inv| match method {
            "ShowFolders" => {
                let paths = paths_from_params(&params);
                if let Some(app) = weak.upgrade() {
                    let app = app.clone();
                    glib::idle_add_local_once(move || crate::window::reveal_folders(&app, paths));
                }
                inv.return_value(None);
            }
            "ShowItems" => {
                let paths = paths_from_params(&params);
                if let Some(app) = weak.upgrade() {
                    let app = app.clone();
                    glib::idle_add_local_once(move || crate::window::reveal_items(&app, paths));
                }
                inv.return_value(None);
            }
            "ShowItemProperties" => {
                let paths = paths_from_params(&params);
                if let Some(app) = weak.upgrade() {
                    let app = app.clone();
                    glib::idle_add_local_once(move || crate::window::reveal_properties(&app, paths));
                }
                inv.return_value(None);
            }
            _ => inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "no such method"),
        })
        .build();
    if let Err(e) = registered {
        eprintln!("sea-files: FileManager1 export failed: {e}");
        return;
    }
    std::mem::forget(registered);
    let _guard = gio::bus_own_name_on_connection(
        &conn,
        BUS,
        gio::BusNameOwnerFlags::DO_NOT_QUEUE,
        |_conn, _name| {}
        ,
        |_conn, _name| {},
    );
    std::mem::forget(_guard);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_paths_pass_through() {
        assert_eq!(path_from_uri("/tmp/foo").as_deref(), Some(std::path::Path::new("/tmp/foo")));
        assert_eq!(path_from_uri(""), None);
    }
}
