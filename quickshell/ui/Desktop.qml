// sea-shell — the desktop
//
// The space between the bar and the dock, which the shell has never done anything with.
// One surface per monitor on the BOTTOM layer: above the wallpaper, below every window, so
// nothing here can ever cover something you are working in.
//
// INPUT IS THE HARD PART, and getting it wrong is worse than having no desktop at all. A
// full-screen layer surface that accepts input swallows every pointer event that would have
// reached the desktop — scroll-to-switch-workspace, drag-to-select, any mouse bind you have
// — and it does so silently, because there is nothing visible there to blame. So the input
// region is exactly the widgets and nothing else: one Region per item, rebuilt as items
// move. Only while ARRANGING does the whole surface take input, and that is a mode you
// entered on purpose and can see.
//
// POSITIONS ARE FRACTIONS, not pixels. A desktop laid out on a 1440p monitor and reopened
// on a 1080p one should hold its arrangement, and a widget parked against the right edge
// should stay against the right edge.
//
// PLACEMENT IS ADVICE. sea-wallpaper-quiet.py works out which parts of the wallpaper have
// something in them; while you drag, that map is drawn as keep-clear shading and a dropped
// widget is nudged out of a busy cell IF a calmer one is within two cells. It is a nudge
// and not a rule: the map is right about eleven wallpapers in twelve, and the twelfth is
// yours to overrule. Hold SHIFT while dropping to place exactly where the pointer is.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

PanelWindow {
    id: root

    property var pal
    property string uiFont: "sans"
    property real ui: 1.0
    property bool editing: false
    // Kept clear at the top and bottom so nothing is ever parked under the bar or the dock.
    property int insetTop: 0
    property int insetBottom: 0

    color: "transparent"
    WlrLayershell.namespace: "sea-shell:desktop"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; left: true; right: true; bottom: true }

    readonly property real sw: root.width / root.ui
    readonly property real sh: root.height / root.ui

    // ---------- the arrangement ----------
    property var items: []
    readonly property string confPath:
        Quickshell.env("HOME") + "/.config/sea-shell/desktop.json"

    FileView {
        id: conf
        path: root.confPath
        watchChanges: true
        function apply() {
            try {
                reload();
                var t = text();
                if (!t || !t.trim()) { root.items = []; return }
                var j = JSON.parse(t);
                root.items = (j && j.items) ? j.items : [];
            } catch (e) {
                root.items = [];
            }
        }
        onFileChanged: apply()
        onLoaded: apply()
        Component.onCompleted: apply()
    }

    Process { id: writer }
    function save() {
        // Written through a shell rather than FileView because the config is the record and
        // a half-written record is worse than a stale one: printf to a temp file and rename,
        // so a reader either sees the old arrangement or the new one.
        var body = JSON.stringify({ "v": 1, "items": root.items });
        writer.command = ["sh", "-c",
            "mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"",
            "sh", root.confPath, body];
        writer.running = true;
    }

    function setItem(i, changes) {
        var next = [];
        for (var k = 0; k < root.items.length; k++)
            next.push(k === i ? Object.assign({}, root.items[k], changes) : root.items[k]);
        root.items = next;
        root.save();
    }

    // ---------- the quiet map ----------
    property var quiet: ({})
    readonly property var qmap: (root.quiet && root.quiet.map) ? root.quiet.map : []
    readonly property int qw: (root.quiet && root.quiet.gw) ? root.quiet.gw : 96
    readonly property int qh: (root.quiet && root.quiet.gh) ? root.quiet.gh : 54
    readonly property bool haveQuiet: root.qmap.length === root.qw * root.qh

    FileView {
        id: quietFile
        path: Quickshell.env("HOME") + "/.cache/sea-shell/wallquiet.json"
        watchChanges: true
        function apply() {
            try {
                reload();
                var t = text();
                root.quiet = (t && t.trim()) ? JSON.parse(t) : ({});
            } catch (e) {
                root.quiet = ({});
            }
        }
        onFileChanged: apply()
        onLoaded: apply()
        Component.onCompleted: apply()
    }

    // How much is going on under a rectangle given in FRACTIONS of the screen. 0 is empty.
    function busyAt(fx, fy, fw, fh) {
        if (!root.haveQuiet) return 0;
        var x0 = Math.max(0, Math.floor(fx * root.qw));
        var y0 = Math.max(0, Math.floor(fy * root.qh));
        var x1 = Math.min(root.qw, Math.ceil((fx + fw) * root.qw));
        var y1 = Math.min(root.qh, Math.ceil((fy + fh) * root.qh));
        if (x1 <= x0 || y1 <= y0) return 0;
        var sum = 0, n = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++) { sum += root.qmap[y * root.qw + x]; n++ }
        return n ? (sum / n) / 255 : 0;
    }

    // Anything above this is "there is something here". Chosen against the measured library:
    // wallpapers with a subject sit well above it, open sky and water well below.
    readonly property real busyLimit: 0.30

    // The nudge. Search outward a couple of cells for somewhere calmer; if nowhere within
    // reach is better, leave the drop exactly where it was put.
    function settle(fx, fy, fw, fh) {
        if (!root.haveQuiet) return Qt.point(fx, fy);
        var here = root.busyAt(fx, fy, fw, fh);
        if (here <= root.busyLimit) return Qt.point(fx, fy);
        var stepX = 1 / root.qw, stepY = 1 / root.qh;
        var best = here, bx = fx, by = fy;
        for (var dy = -2; dy <= 2; dy++) {
            for (var dx = -2; dx <= 2; dx++) {
                var nx = Math.max(0, Math.min(1 - fw, fx + dx * stepX));
                var ny = Math.max(0, Math.min(1 - fh, fy + dy * stepY));
                var s = root.busyAt(nx, ny, fw, fh);
                if (s < best - 0.02) { best = s; bx = nx; by = ny }
            }
        }
        return Qt.point(bx, by);
    }

    // ---------- input region ----------
    // One Region per item so the rest of the desktop keeps working. See the header.
    Instantiator {
        id: maskPool
        model: root.editing ? 0 : root.items.length
        delegate: Region {
            required property int index
            x: Math.round((root.items[index] ? root.items[index].x : 0) * root.sw * root.ui)
            y: Math.round(((root.items[index] ? root.items[index].y : 0) * root.sh + root.insetTop) * root.ui)
            width: Math.round((root.items[index] ? root.items[index].w : 0) * root.sw * root.ui)
            height: Math.round((root.items[index] ? root.items[index].h : 0) * root.sh * root.ui)
        }
        onObjectAdded: root.rebuildMask()
        onObjectRemoved: root.rebuildMask()
    }
    property var maskRegions: []
    function rebuildMask() {
        var a = [];
        for (var i = 0; i < maskPool.count; i++) a.push(maskPool.objectAt(i));
        root.maskRegions = a;
    }
    onItemsChanged: root.rebuildMask()

    mask: Region {
        // Arranging takes the whole screen, so a widget can be dragged anywhere including
        // off one edge and back. Otherwise: the widgets, and nothing else.
        item: root.editing ? root.contentItem : null
        regions: root.editing ? [] : root.maskRegions
    }

    // ---------- what is drawn ----------
    Item {
        anchors.fill: parent
        scale: root.ui
        transformOrigin: Item.TopLeft
        width: root.sw
        height: root.sh

        // keep-clear shading, only while arranging. The point is that you can SEE what the
        // shell thinks is in the picture, and disagree with it.
        Item {
            anchors.fill: parent
            visible: root.editing && root.haveQuiet
            opacity: 0.55
            Repeater {
                model: root.editing && root.haveQuiet ? root.qw * root.qh : 0
                delegate: Rectangle {
                    required property int index
                    readonly property real v: root.qmap[index] / 255
                    visible: v > root.busyLimit
                    x: (index % root.qw) * (root.sw / root.qw)
                    y: Math.floor(index / root.qw) * ((root.sh - root.insetTop - root.insetBottom) / root.qh) + root.insetTop
                    width: root.sw / root.qw + 1
                    height: (root.sh - root.insetTop - root.insetBottom) / root.qh + 1
                    color: root.pal ? root.pal.a(root.pal.bad, Math.min(0.5, (v - root.busyLimit) * 1.1))
                                    : Qt.rgba(1, 0.2, 0.2, Math.min(0.5, (v - root.busyLimit) * 1.1))
                }
            }
        }

        Repeater {
            model: root.items
            delegate: DesktopItem {
                required property var modelData
                required property int index
                pal: root.pal
                uiFont: root.uiFont
                spec: modelData
                editing: root.editing
                fieldW: root.sw
                fieldH: root.sh - root.insetTop - root.insetBottom
                fieldY: root.insetTop
                onMoved: (fx, fy, exact) => {
                    var p = exact ? Qt.point(fx, fy)
                                  : root.settle(fx, fy, modelData.w, modelData.h);
                    root.setItem(index, { "x": p.x, "y": p.y });
                }
            }
        }
    }
}
