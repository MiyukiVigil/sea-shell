// The wallpaper collection as still pictures, for the photo widget: each wallpaper's own file
// when it is a picture, its cached poster frame when it is a video. Read from the index the
// wallpaper picker keeps (sea-wallpaper-index.py), so nothing is decoded here, and only while
// something wants it (`active`).
import Quickshell
import Quickshell.Io
import QtQuick

Scope {
    id: ws
    property bool active: false
    property var list: []          // [{ u: still's file url, cap: a readable name, p: the wallpaper's own path }]
    function nameOf(p) {
        var b = ("" + p).replace(/^.*\//, "").replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ").trim();
        return b.length ? b.charAt(0).toUpperCase() + b.slice(1) : "";
    }
    function parse(t) {
        var out = [], rows = ("" + t).split("\n");
        for (var i = 0; i < rows.length; i++) {
            var c = rows[i].split("\t");
            if (c.length < 6 || !c[0]) continue;
            var still = /\.(jpe?g|png|webp)$/i.test(c[0]);
            var u = still ? c[0] : c[5];
            if (!u) continue;
            out.push({ u: "file://" + u, cap: ws.nameOf(c[0]), p: c[0] });
        }
        ws.list = out;
    }
    FileView {
        path: ws.active ? (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/sea-shell/wallindex.tsv" : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: ws.parse(text())
    }
}
