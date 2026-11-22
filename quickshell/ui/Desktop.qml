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
    property bool suspended: false
    visible: !suspended
    signal doneRequested()
    // Readings for the widgets, supplied by the bar (see shell.qml).
    property var readings: ({})
    property var player: null
    property var viz: []

    // A short history of load, so the system widget can draw a trace rather than a number.
    // Sampled here rather than in each widget: one buffer, one cadence, and every system
    // widget on every monitor shows the same line.
    property var cpuHistory: []
    property var memHistory: []
    property var gpuHistory: []
    property bool seen: true
    Timer {
        interval: 2000
        running: !root.suspended && root.seen
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var r = root.readings || {};
            function push(buf, v) {
                var h = buf.slice(-39);
                h.push(Math.max(0, Math.min(100, v || 0)));
                return h;
            }
            root.cpuHistory = push(root.cpuHistory, r.cpu);
            root.memHistory = push(root.memHistory, r.memPct);
            root.gpuHistory = push(root.gpuHistory, r.gpu);
        }
    }
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

    // ---------- live snapping ----------
    // While a widget is dragged its edges and centre are pulled onto other widgets' edges and
    // centres, the middle of the screen, and a margin in from each side, within SNAP pixels.
    // The drop still goes through settle(), so the wallpaper map has the last word unless
    // Shift says "exactly here" (which also turns the snapping off).
    property real guideX: -1
    property real guideY: -1
    readonly property real snapDist: 8
    readonly property real snapMargin: 24
    function snapDrag(id, x, y, w, h) {
        var fh = root.sh - root.insetTop - root.insetBottom, top = root.insetTop;
        var cx = [root.sw / 2, root.snapMargin, root.sw - root.snapMargin];
        var cy = [top + fh / 2, top + root.snapMargin, top + fh - root.snapMargin];
        for (var i = 0; i < root.items.length; i++) {
            var o = root.items[i];
            if (!o || "" + o.id === "" + id) continue;
            var ox = o.x * root.sw, oy = o.y * fh + top, ow = o.w * root.sw, oh = o.h * fh;
            cx.push(ox, ox + ow / 2, ox + ow);
            cy.push(oy, oy + oh / 2, oy + oh);
        }
        function best(pos, size, cands) {
            var edges = [pos, pos + size / 2, pos + size], out = { p: pos, g: -1, d: root.snapDist + 1 };
            for (var e = 0; e < 3; e++)
                for (var c = 0; c < cands.length; c++) {
                    var d = cands[c] - edges[e];
                    if (Math.abs(d) < out.d) out = { p: pos + d, g: cands[c], d: Math.abs(d) };
                }
            return out;
        }
        var bx = best(x, w, cx), by = best(y, h, cy);
        root.guideX = bx.g; root.guideY = by.g;
        return Qt.point(bx.p, by.p);
    }

    // ---------- the arrangement ----------
    property var items: []
    // The Repeater runs on the ids, not on `items`: a JS array model rebuilds every delegate
    // each time it is replaced, so a widget the wallpaper nudged was destroyed and re-made at
    // its new spot, a teleport. The ids only change when a widget is added or removed, so a
    // move reaches a widget that is still alive and it can glide there.
    property var ids: []
    readonly property var byId: {
        var m = {};
        for (var i = 0; i < root.items.length; i++) m[root.keyOf(root.items[i], i)] = root.items[i];
        return m;
    }
    function keyOf(it, i) { return (it && it.id) ? "" + it.id : "#" + i }
    onItemsChanged: {
        var k = root.items.map((it, i) => root.keyOf(it, i));
        if (k.join("\n") !== root.ids.join("\n")) root.ids = k;
        root.rebuildMask();
    }
    readonly property string confPath:
        Quickshell.env("HOME") + "/.config/sea-shell/desktop.json"

    FileView {
        id: conf
        path: root.confPath
        watchChanges: true
        // READ ONLY ONCE THE LOAD HAS LANDED. This used to call reload() and then text() in
        // one breath, but reload() finishes later, so text() could hand back the file as it
        // was BEFORE the change: what was shown lagged one change behind, and removing the
        // last widget could leave it on screen until something else changed.
        function apply() {
            try {
                var t = text();
                if (!t || !t.trim()) { root.items = []; return }
                var j = JSON.parse(t);
                root.items = (j && j.items) ? j.items : [];
            } catch (e) {
                root.items = [];
            }
        }
        onFileChanged: reload()
        onLoaded: apply()
        Component.onCompleted: reload()
    }

    // ONE WRITER, AND IT IS NOT THIS FILE.
    //
    // This used to write the arrangement itself, and twice it destroyed one: it serialised
    // `root.items`, which is a COPY of the file made when the FileView last parsed it, so
    // any moment that copy was stale or partial the next drag wrote the stale version over
    // the real one — five widgets became one, with no error anywhere. A surface that also
    // owns the record will eventually overwrite the record with what it happens to be
    // showing. So every change is a request to sea-desktop.py, which reads the file, edits
    // it and writes it back; this file only ever reads.
    Process { id: helperProc }
    readonly property string helper:
        Quickshell.env("HOME") + "/.config/quickshell/sea-shell/sea-desktop.py"
    function ask(args) {
        helperProc.command = ["python3", root.helper].concat(args);
        helperProc.running = true;
    }
    function removeItem(id) { if (id) root.ask(["--remove", "" + id]) }
    function moveItem(id, x, y, pin) {
        if (!id) return;
        root.ask(["--move", "" + id, "--x", "" + x, "--y", "" + y, pin ? "--pin" : "--unpin"]);
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
        // READ ONLY ONCE THE LOAD HAS LANDED. This used to call reload() and then text() in
        // one breath, but reload() finishes later, so text() could hand back the file as it
        // was BEFORE the change: what was shown lagged one change behind, and removing the
        // last widget could leave it on screen until something else changed.
        function apply() {
            try {
                var t = text();
                root.quiet = (t && t.trim()) ? JSON.parse(t) : ({});
            } catch (e) {
                root.quiet = ({});
            }
        }
        onFileChanged: reload()
        onLoaded: apply()
        Component.onCompleted: reload()
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

    // How LIGHT the picture is under a rectangle, 0 (black) to 1 (white); 0.5 when unknown.
    readonly property var qluma: (root.quiet && root.quiet.luma) ? root.quiet.luma : []
    function lumaAt(fx, fy, fw, fh) {
        if (root.qluma.length !== root.qw * root.qh) return 0.5;
        var x0 = Math.max(0, Math.floor(fx * root.qw)), y0 = Math.max(0, Math.floor(fy * root.qh));
        var x1 = Math.min(root.qw, Math.ceil((fx + fw) * root.qw)), y1 = Math.min(root.qh, Math.ceil((fy + fh) * root.qh));
        var sum = 0, n = 0;
        for (var y = y0; y < y1; y++) for (var x = x0; x < x1; x++) { sum += root.qluma[y * root.qw + x]; n++ }
        return n ? sum / n / 255 : 0.5;
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

    mask: Region {
        // Arranging takes the whole screen, so a widget can be dragged anywhere including
        // off one edge and back. Otherwise: the widgets, and nothing else.
        item: root.editing ? root.contentItem : null
        regions: root.editing ? [] : root.maskRegions
    }

    // ---------- what is drawn ----------
    // Native-sized (screen ÷ ui) and scaled up from the corner, so it lands exactly on the
    // screen. No anchors.fill: that overrode width/height with the physical size, and at a
    // UI scale below 1× the arranging layer then covered only the top-left of the screen.
    Item {
        scale: root.ui
        transformOrigin: Item.TopLeft
        width: root.sw
        height: root.sh

        // While arranging, the whole surface takes input (see the mask above), which is the
        // one moment a click on empty desktop can be heard at all. Right-click ends the
        // mode — the same gesture that dismisses every other transient state in this shell.
        MouseArea {
            anchors.fill: parent
            enabled: root.editing
            acceptedButtons: Qt.RightButton
            // ASK, do not assign: `editing` is bound from the shell, and setting it here cut
            // that binding, so after one right-click the gallery could no longer turn arranging
            // on and every widget stayed stuck where it was.
            onClicked: root.doneRequested()
        }

        // keep-clear shading, only while arranging. The point is that you can SEE what the
        // shell thinks is in the picture, and disagree with it.
        //
        // One 96x54 image, drawn once and stretched smoothly over the screen, so the busy parts
        // read as a soft shadow over the subject. It was 5184 red squares: a hard-edged grid
        // that looked like an error, and that much scene for something only seen while dragging.
        Canvas {
            id: veil
            x: 0; y: root.insetTop
            width: root.qw; height: root.qh
            transformOrigin: Item.TopLeft
            transform: Scale { xScale: root.sw / root.qw; yScale: (root.sh - root.insetTop - root.insetBottom) / root.qh }
            smooth: true
            visible: root.editing && root.haveQuiet
            opacity: root.editing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mBase } }
            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                for (var i = 0; i < root.qmap.length; i++) {
                    var v = root.qmap[i] / 255;
                    // fades in from a little below the limit, so the edge of a subject is a
                    // gradient and not a line
                    var a = Math.max(0, Math.min(0.42, (v - root.busyLimit + 0.08) * 1.1));
                    if (a <= 0) continue;
                    ctx.fillStyle = Qt.rgba(0.05, 0.06, 0.1, a);
                    ctx.fillRect(i % root.qw, Math.floor(i / root.qw), 1, 1);
                }
            }
            Connections { target: root; function onQmapChanged() { veil.requestPaint() } function onEditingChanged() { if (root.editing) veil.requestPaint() } }
        }

        Repeater {
            model: root.ids
            delegate: DesktopItem {
                required property var modelData
                readonly property var entry: root.byId[modelData] || ({ x: 0, y: 0, w: 0.1, h: 0.08 })
                pal: root.pal
                uiFont: root.uiFont
                spec: entry
                editing: root.editing
                readings: root.readings
                player: root.player
                viz: root.viz
                // What the wallpaper is doing under this item, so it can decide whether it
                // needs a ground at all. Same map, same threshold as the placement nudge.
                busy: root.busyAt(entry.x, entry.y, entry.w, entry.h)
                under: root.lumaAt(entry.x, entry.y, entry.w, entry.h)
                history: root.cpuHistory
                memHistory: root.memHistory
                gpuHistory: root.gpuHistory
                fieldW: root.sw
                fieldH: root.sh - root.insetTop - root.insetBottom
                fieldY: root.insetTop
                busyFn: root.busyAt
                busyLimit: root.busyLimit
                snapFn: root.snapDrag
                onDragEnded: { root.guideX = -1; root.guideY = -1 }
                onRemoved: root.removeItem(entry.id)
                onMoved: (fx, fy, exact) => {
                    // SHIFT is one statement, not two: "put it exactly here" and "stop
                    // moving it when the wallpaper changes" are the same intent — you have
                    // overruled the map, and it would be rude to overrule you back tomorrow.
                    var p = exact ? Qt.point(fx, fy)
                                  : root.settle(fx, fy, entry.w, entry.h);
                    root.moveItem(entry.id, p.x, p.y, exact);
                }
            }
        }

        // Alignment guides while a widget is dragged: the line it has locked onto, across
        // the whole field, as a drawing app shows it.
        Rectangle {
            visible: root.editing && root.guideX >= 0
            x: root.guideX - 0.5; y: root.insetTop; z: 50
            width: 1; height: root.sh - root.insetTop - root.insetBottom
            color: Tok.accent
        }
        Rectangle {
            visible: root.editing && root.guideY >= 0
            x: 0; y: root.guideY - 0.5; z: 50
            width: root.sw; height: 1
            color: Tok.accent
        }
    }
}
