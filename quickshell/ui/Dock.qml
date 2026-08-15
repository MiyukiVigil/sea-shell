// sea-shell — dock
//
// A dock is not a second bar. The bar reports state; the dock is about APPS — what is pinned,
// what is running, and getting to it in one click. It is a separate layer-shell surface per
// monitor, and it has to coexist with the bar's own auto-hide, per-monitor and scale logic
// rather than fight it.
//
// Four things this had to get right, none of them obvious:
//
//  1. Matching a Hyprland window class to a .desktop entry is NOT one lookup. VS Code ships
//     StartupWMClass=Code while its window class is `visual-studio-code-electron` — the two
//     disagree, so a single-key index silently loses the icon. `entryIndex` below is built from
//     startupClass, desktop id, app name and (lowest priority) exec basename.
//
//  2. `lastIpcObject` on a toplevel goes EMPTY on a long-lived shell until something calls
//     refreshToplevels() — the same trap that once broke ALT+Tab completely. Membership and
//     grouping therefore come from the WAYLAND handle; hyprctl data only ever ENRICHES
//     (geometry for overlap, focusHistoryID for MRU). Nothing is filtered out on its absence.
//
//  3. Magnification must not reflow the row. Growing the slots re-lays-out every neighbour and
//     the icons visibly jitter under the cursor — the classic broken-dock feel. Slots keep a
//     fixed width here; only the icon scales, and it grows OUTWARD past the card edge into
//     deliberate headroom the input region does not claim.
//
//  4. The window must not eat clicks it does not use. `mask` is an INPUT region, not a clip, so
//     the headroom still renders the zoomed icon while clicks there fall through to the app
//     underneath. Without it the dock would block a strip of screen it does not even paint.
//
// Pinned apps live in their own ~/.config/sea-shell/dock.json rather than appearance.json,
// because the dock writes them (right-click) while the settings panel rewrites appearance.json
// wholesale — sharing one file would make the two clobber each other.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland

Item {
    id: dock

    // ---- configuration (bound from shell.qml) ----
    property bool   dockEnabled: false
    property string edge: "bottom"          // bottom | top | left | right
    property int    iconSize: 40
    property string mode: "always"          // always | autohide | intelligent
    property bool   zoomEnabled: true
    property bool   showRunning: true       // append running apps that are not pinned
    property bool   showLabels: true        // name tooltip on hover
    property real   surfaceOpacity: 0.8
    property var    cfgMonitors: ({})       // shared per-monitor map with the bar
    property real   cfgScale: 0

    readonly property bool vertical: dock.edge === "left" || dock.edge === "right"

    // ---------- per-monitor helpers (mirrors the bar's, keyed on the same map) ----------
    function monDock(name) { var m = name ? dock.cfgMonitors[name] : null; return !(m && m.dock === false); }
    function monScale(name) { var m = name ? dock.cfgMonitors[name] : null; return (m && m.scale > 0) ? m.scale : 0; }
    function uiFor(scr) {
        var mo = (scr && scr.name) ? dock.monScale(scr.name) : 0;
        if (mo > 0) return mo;
        if (dock.cfgScale > 0) return dock.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 0) { var ss = Quickshell.screens; for (var i = 0; i < ss.length; i++) if (ss[i] && ss[i].height > h) h = ss[i].height; }
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }

    // ---------- pinned apps (own file — see header) ----------
    property var pinned: []
    Process {
        running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/dock.json\" 2>/dev/null"]
        stdout: StdioCollector { id: pinOut; onStreamFinished: {
            try {
                var t = pinOut.text.trim(); if (!t) return;
                var j = JSON.parse(t);
                if (Array.isArray(j.pinned)) dock.pinned = j.pinned;
            } catch (e) {}
        } } }
    function savePins() {
        var s = JSON.stringify({ pinned: dock.pinned });
        Quickshell.execDetached(["python3","-c",
            "import sys,os,pathlib; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell'))/'dock.json'; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[1])",
            s]);
    }
    function isPinned(key) { return dock.pinned.indexOf(key) >= 0 }
    function togglePin(key) {
        if (!key) return;
        var p = dock.pinned.slice(), i = p.indexOf(key);
        if (i >= 0) p.splice(i, 1); else p.push(key);
        dock.pinned = p; dock.savePins();
    }

    // ---------- desktop entry index ----------
    // Two passes on purpose: a generic exec basename (`electron`, `sh`) must never outrank a
    // real StartupWMClass, so exec keys are only claimed after every strong key is taken.
    readonly property var entryIndex: {
        var idx = {}, apps = [];
        try { apps = DesktopEntries.applications.values; } catch (e) { return idx; }
        function put(k, a) {
            var kk = ("" + (k || "")).trim().toLowerCase();
            if (kk !== "" && idx[kk] === undefined) idx[kk] = a;
        }
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i]; if (!a) continue;
            put(a.startupClass, a);
            put(("" + (a.id || "")).replace(/\.desktop$/i, ""), a);
            put(a.name, a);
        }
        for (var j = 0; j < apps.length; j++) {
            var b = apps[j]; if (!b) continue;
            var ex = ("" + (b.execString || "")).trim().split(/\s+/)[0];
            if (ex) put(ex.split("/").pop(), b);
        }
        return idx;
    }
    // Quickshell ships its own class→entry matcher and it is better than a hand-rolled one:
    // measured against this machine it resolves `visual-studio-code-electron`, `org.gnome.Nautilus`
    // and `obs`→OBS Studio, the last of which even byId() misses. So it goes first, and the local
    // index is the fallback for whatever it cannot place.
    //
    // `idx` is read FIRST and unconditionally, on every path: heuristicLookup is a method call and
    // a method call creates no binding dependency, so without touching the index here the icons
    // would resolve once at startup — against an empty list — and never refresh. DesktopEntries
    // populates lazily and streams in one entry at a time, so that would mean a dock of blank
    // letter tiles on every login.
    function entryFor(cls) {
        var idx = dock.entryIndex;
        var k = ("" + (cls || "")).trim().toLowerCase();
        if (k === "") return null;
        var e = null;
        try { e = DesktopEntries.heuristicLookup(cls); } catch (err) {}
        if (e) return e;
        e = idx[k]; if (e) return e;
        // reverse-DNS ids: org.gnome.Nautilus → nautilus
        var seg = k.split(".");
        if (seg.length > 1) { e = idx[seg[seg.length - 1]]; if (e) return e; }
        // trailing qualifiers some Electron builds add: foo-electron → foo
        var dashed = k.replace(/-(electron|bin|git|stable|desktop)$/, "");
        if (dashed !== k) { e = idx[dashed]; if (e) return e; }
        return null;
    }

    // ---------- running windows, grouped by class ----------
    // Refreshed off Hyprland's own event stream; see note 2 in the header.
    property int _tick: 0                       // bumped to force re-evaluation of the model
    Connections {
        target: Hyprland
        ignoreUnknownSignals: true
        function onRawEvent(ev) { dock._tick++; refreshDebounce.restart() }
    }
    Timer { id: refreshDebounce; interval: 120; repeat: false
        onTriggered: { try { Hyprland.refreshToplevels(); Hyprland.refreshMonitors(); } catch (e) {} } }
    // A slow heartbeat as well: rawEvent covers window open/close/workspace, but a window being
    // DRAGGED or resized emits nothing that changes its cached geometry, and overlap detection
    // would sit stale for the whole drag. Only runs in the mode that actually reads geometry.
    Timer { interval: 1200; repeat: true; running: dock.dockEnabled && dock.mode === "intelligent"
        onTriggered: { try { Hyprland.refreshToplevels(); dock._tick++; } catch (e) {} } }

    readonly property var groups: {
        var _ = dock._tick;                     // dependency: re-run when Hyprland reports change
        var wins = [], map = {}, order = [];
        try { wins = (Hyprland && Hyprland.toplevels) ? Hyprland.toplevels.values : []; } catch (e) { return { map: {}, order: [] }; }
        for (var i = 0; i < wins.length; i++) {
            var t = wins[i];
            if (!t || !t.wayland) continue;
            var cls = ("" + (t.wayland.appId || "")).trim();
            if (cls === "") continue;
            var k = cls.toLowerCase();
            if (!map[k]) { map[k] = { key: k, cls: cls, wins: [] }; order.push(k); }
            map[k].wins.push(t);
        }
        return { map: map, order: order };
    }

    // pinned first (configured order), then running-but-unpinned
    readonly property var items: {
        var g = dock.groups, out = [], seen = {};
        for (var i = 0; i < dock.pinned.length; i++) {
            var k = ("" + dock.pinned[i]).toLowerCase();
            if (seen[k]) continue; seen[k] = true;
            var grp = g.map[k];
            out.push({ key: k, cls: grp ? grp.cls : dock.pinned[i], entry: dock.entryFor(k),
                       wins: grp ? grp.wins : [], count: grp ? grp.wins.length : 0, pinned: true });
        }
        if (dock.showRunning) {
            for (var j = 0; j < g.order.length; j++) {
                var kk = g.order[j];
                if (seen[kk]) continue; seen[kk] = true;
                var gg = g.map[kk];
                out.push({ key: kk, cls: gg.cls, entry: dock.entryFor(kk),
                           wins: gg.wins, count: gg.wins.length, pinned: false });
            }
        }
        return out;
    }

    // ---------- activation ----------
    function labelFor(it) {
        if (it.entry && it.entry.name) return it.entry.name;
        return it.cls;
    }
    function focusWin(w) {
        if (!w) return;
        try {
            if (w.lastIpcObject && w.lastIpcObject.address)
                Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + w.lastIpcObject.address + "' })");
            else if (w.wayland) w.wayland.activate();
        } catch (e) {}
    }
    // Click semantics: not running → launch. Running → focus its MRU window; if that one is
    // ALREADY focused, step to the next instance so repeat clicks cycle a multi-window app.
    function activate(it) {
        if (!it) return;
        if (it.count === 0) { if (it.entry) it.entry.execute(); return; }
        var ws = it.wins.slice();
        ws.sort(function (a, b) {
            var ai = (a && a.lastIpcObject && a.lastIpcObject.focusHistoryID !== undefined) ? a.lastIpcObject.focusHistoryID : 9999;
            var bi = (b && b.lastIpcObject && b.lastIpcObject.focusHistoryID !== undefined) ? b.lastIpcObject.focusHistoryID : 9999;
            return ai - bi;
        });
        var target = ws[0];
        if (ws.length > 1 && target && target.activated) target = ws[1];
        dock.focusWin(target);
    }
    function launchNew(it) { if (it && it.entry) it.entry.execute(); }

    // ---------- geometry / overlap ----------
    readonly property int pad: 6
    readonly property int slot: dock.iconSize + 10
    readonly property int thickness: dock.iconSize + dock.pad * 2
    readonly property int headroom: Math.round(dock.iconSize * 0.62)   // zoom growth + label
    readonly property int gap: 8
    readonly property int tipRoom: 240          // surface room for the hover label; takes no input
    readonly property int cardLen: dock.items.length > 0
        ? (dock.items.length * dock.slot + dock.pad * 2) : 0

    function monGeom(name) {
        try {
            var ms = Hyprland.monitors.values;
            for (var i = 0; i < ms.length; i++) {
                var m = ms[i];
                if (m && m.name === name) {
                    var s = m.scale > 0 ? m.scale : 1;
                    return { x: m.x, y: m.y, w: m.width / s, h: m.height / s };
                }
            }
        } catch (e) {}
        return null;
    }

    // ============ one dock per monitor ============
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            property var modelData
            screen: modelData
            // Read modelData, never win.screen — reading screen inside `visible` creates the
            // visible↔screen-mapping binding loop the bar hit.
            visible: dock.dockEnabled && dock.items.length > 0
                     && dock.monDock(win.modelData ? win.modelData.name : "")
            readonly property real ui: dock.uiFor(win.screen)
            readonly property string monName: win.modelData ? win.modelData.name : ""

            color: "transparent"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "sea-shell:dock"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None    // the dock never types

            // ---- reveal / hide ----
            property bool hovered: false
            property bool revealed: false
            // "intelligent": out until a real window would sit under the dock. Hyprland reports
            // client geometry in logical coords including the bar's reserved strip, so this is a
            // plain rect intersection in absolute space — no scale gymnastics.
            readonly property bool covered: {
                var _ = dock._tick;
                if (dock.mode !== "intelligent") return false;
                var g = dock.monGeom(win.monName); if (!g) return false;
                var cw = dock.vertical ? (dock.thickness * win.ui) : (dock.cardLen * win.ui);
                var ch = dock.vertical ? (dock.cardLen * win.ui) : (dock.thickness * win.ui);
                var gp = dock.gap * win.ui;
                var rx = dock.edge === "left"  ? g.x + gp
                       : dock.edge === "right" ? g.x + g.w - gp - cw
                       : g.x + (g.w - cw) / 2;
                var ry = dock.edge === "top"    ? g.y + gp
                       : dock.edge === "bottom" ? g.y + g.h - gp - ch
                       : g.y + (g.h - ch) / 2;
                var wins = [];
                try { wins = Hyprland.toplevels.values; } catch (e) { return false; }
                for (var i = 0; i < wins.length; i++) {
                    var t = wins[i]; if (!t) continue;
                    // only windows on THIS monitor's visible workspace can cover the dock
                    if (t.monitor && t.monitor.name && t.monitor.name !== win.monName) continue;
                    try {
                        var mm = Hyprland.monitors.values, aws = -999;
                        for (var q = 0; q < mm.length; q++) if (mm[q].name === win.monName && mm[q].activeWorkspace) aws = mm[q].activeWorkspace.id;
                        if (t.workspace && t.workspace.id !== undefined && t.workspace.id !== aws) continue;
                    } catch (e) {}
                    var o = t.lastIpcObject;
                    if (!o || !o.at || !o.size || o.hidden) continue;
                    var wx = o.at[0], wy = o.at[1], ww = o.size[0], wh = o.size[1];
                    if (wx < rx + cw && wx + ww > rx && wy < ry + ch && wy + wh > ry) return true;
                }
                return false;
            }
            readonly property bool autoHiding: dock.mode === "autohide" || (dock.mode === "intelligent" && win.covered)
            readonly property bool out: !win.autoHiding || win.revealed || win.hovered

            Timer { id: hideTimer; interval: 500; onTriggered: if (!win.hovered) win.revealed = false }
            onAutoHidingChanged: if (win.autoHiding && !win.hovered) hideTimer.restart()

            // reserve the strip only when the dock is permanently out; otherwise windows get
            // the whole screen and the dock floats over them
            exclusionMode: win.autoHiding ? ExclusionMode.Ignore : ExclusionMode.Normal
            exclusiveZone: win.autoHiding ? 0 : Math.round((dock.thickness + dock.gap) * win.ui)

            // Input region: the card, plus a sliver on the docked edge to reveal it while hidden.
            // Never the headroom — see note 4 in the header. Declared as separate Regions and
            // selected with a ternary, which is the form already proven on the bar.
            mask: (win.autoHiding && !win.out) ? revealRegion : cardRegion
            Region { id: revealRegion; item: revealStrip }
            Region { id: cardRegion; item: inputRect }

            // The input region CANNOT point at `card`: the card lives inside the ui-scale wrapper,
            // so its x/y/width/height are in pre-scale coordinates and nested one level down, while
            // the region is interpreted in window space. Pointing at it yielded a rect that missed
            // the icons entirely — the dock rendered perfectly and silently ignored every click.
            // (The bar's Region works because its item is a direct child of the window at 1×.)
            // This mirrors the card's real on-screen rect instead, scale included.
            Item {
                id: inputRect
                readonly property real cw: (dock.vertical ? dock.thickness : dock.cardLen) * win.ui
                readonly property real ch: (dock.vertical ? dock.cardLen : dock.thickness) * win.ui
                readonly property real g:  dock.gap * win.ui
                width: inputRect.cw
                height: inputRect.ch
                x: dock.edge === "left"  ? inputRect.g
                 : dock.edge === "right" ? win.width - inputRect.g - inputRect.cw
                 : (win.width - inputRect.cw) / 2
                y: dock.edge === "top"    ? inputRect.g
                 : dock.edge === "bottom" ? win.height - inputRect.g - inputRect.ch
                 : (win.height - inputRect.ch) / 2
            }

            // one edge anchored → layer-shell centres the surface on the other axis.
            // The surface is deliberately LARGER than the card: it carries headroom for the
            // magnified icon and room for the hover label, neither of which takes input.
            anchors.top:    dock.edge === "top"
            anchors.bottom: dock.edge === "bottom"
            anchors.left:   dock.edge === "left"
            anchors.right:  dock.edge === "right"
            implicitWidth:  Math.round((dock.vertical ? (dock.gap + dock.thickness + dock.tipRoom)
                                                      : (dock.cardLen + dock.tipRoom)) * win.ui)
            implicitHeight: Math.round((dock.vertical ? (dock.cardLen + 80)
                                                      : (dock.gap + dock.thickness + dock.headroom + 8)) * win.ui)

            Item {
                id: revealStrip
                width:  dock.vertical ? 4 * win.ui : parent.width
                height: dock.vertical ? parent.height : 4 * win.ui
                anchors.top:    dock.edge === "top"    ? parent.top    : undefined
                anchors.bottom: dock.edge === "bottom" ? parent.bottom : undefined
                anchors.left:   dock.edge === "left"   ? parent.left   : undefined
                anchors.right:  dock.edge === "right"  ? parent.right  : undefined
                anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
                anchors.verticalCenter:   dock.vertical ? parent.verticalCenter : undefined
                HoverHandler { onHoveredChanged: if (hovered) { hideTimer.stop(); win.revealed = true } }
            }

            // native (1×) coordinate space inside, scaled up as a whole — same trick as the bar
            // `anchors.fill` and explicit width/height fight each other — anchors win and the
            // divide-by-ui is discarded, which double-scales everything on a >1× monitor. Size is
            // set explicitly and the Scale transform does the rest, so children lay out in one
            // native 1× space exactly like the bar's barBg does.
            Item {
                id: scaler
                transform: Scale { origin.x: 0; origin.y: 0; xScale: win.ui; yScale: win.ui }
                width: win.width / win.ui
                height: win.height / win.ui

                Rectangle {
                    id: card
                    width:  dock.vertical ? dock.thickness : dock.cardLen
                    height: dock.vertical ? dock.cardLen : dock.thickness
                    radius: Tok.rCard
                    color: Tok.alpha(Tok.surface, dock.surfaceOpacity)
                    border.width: 1
                    border.color: Tok.alpha(Tok.ruleHard, 0.55)

                    anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
                    anchors.verticalCenter:   dock.vertical ? parent.verticalCenter : undefined
                    anchors.top:    dock.edge === "top"    ? parent.top    : undefined
                    anchors.bottom: dock.edge === "bottom" ? parent.bottom : undefined
                    anchors.left:   dock.edge === "left"   ? parent.left   : undefined
                    anchors.right:  dock.edge === "right"  ? parent.right  : undefined
                    anchors.topMargin:    dock.edge === "top"    ? dock.gap : 0
                    anchors.bottomMargin: dock.edge === "bottom" ? dock.gap : 0
                    anchors.leftMargin:   dock.edge === "left"   ? dock.gap : 0
                    anchors.rightMargin:  dock.edge === "right"  ? dock.gap : 0

                    // slide off the docked edge when tucked away
                    transform: Translate {
                        x: win.out ? 0 : (dock.edge === "right" ? (dock.thickness + dock.gap + 4)
                                        : dock.edge === "left"  ? -(dock.thickness + dock.gap + 4) : 0)
                        y: win.out ? 0 : (dock.edge === "bottom" ? (dock.thickness + dock.gap + 4)
                                        : dock.edge === "top"    ? -(dock.thickness + dock.gap + 4) : 0)
                        Behavior on x { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                        Behavior on y { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                    }

                    HoverHandler {
                        onHoveredChanged: {
                            win.hovered = hovered;
                            if (hovered) { hideTimer.stop(); win.revealed = true }
                            else { dock.hoverKey = ""; if (win.autoHiding) hideTimer.restart() }
                        }
                    }

                    Grid {
                        id: strip
                        anchors.centerIn: parent
                        rows: dock.vertical ? Math.max(1, dock.items.length) : 1
                        columns: dock.vertical ? 1 : Math.max(1, dock.items.length)
                        spacing: 0

                        Repeater {
                            model: dock.items
                            delegate: Item {
                                id: cellRoot
                                required property var modelData
                                required property int index
                                width:  dock.vertical ? dock.thickness : dock.slot
                                height: dock.vertical ? dock.slot : dock.thickness

                                readonly property bool isHover: dock.hoverKey === cellRoot.modelData.key
                                // Distance falloff in SLOT units, not pixels: the row never
                                // reflows, so index distance is exact and cannot jitter.
                                // NOT readonly — `Behavior on` cannot attach to a readonly
                                // property, and the whole point here is to animate the change.
                                property real mag: {
                                    if (!dock.zoomEnabled || dock.hoverIndex < 0) return 1;
                                    var d = Math.abs(cellRoot.index - dock.hoverIndex);
                                    return d === 0 ? 1.45 : d === 1 ? 1.20 : d === 2 ? 1.07 : 1;
                                }
                                Behavior on mag { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                                Item {
                                    id: iconWrap
                                    width: dock.iconSize; height: dock.iconSize
                                    anchors.centerIn: parent
                                    scale: cellRoot.mag
                                    // grow away from the docked edge instead of into it
                                    transform: Translate {
                                        x: dock.edge === "left"  ?  dock.iconSize * (cellRoot.mag - 1) * 0.5
                                         : dock.edge === "right" ? -dock.iconSize * (cellRoot.mag - 1) * 0.5 : 0
                                        y: dock.edge === "top"    ?  dock.iconSize * (cellRoot.mag - 1) * 0.5
                                         : dock.edge === "bottom" ? -dock.iconSize * (cellRoot.mag - 1) * 0.5 : 0
                                        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                        Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                    }

                                    readonly property string ip: cellRoot.modelData.entry
                                        ? Quickshell.iconPath(cellRoot.modelData.entry.icon, true) : ""

                                    IconImage {
                                        anchors.fill: parent
                                        visible: iconWrap.ip !== ""
                                        source: iconWrap.ip
                                    }
                                    // letter tile when the .desktop entry has no usable icon —
                                    // an unresolved app still needs to be clickable, not invisible
                                    Rectangle {
                                        anchors.fill: parent
                                        visible: iconWrap.ip === ""
                                        radius: Tok.r
                                        color: Tok.alpha(Tok.accent, 0.20)
                                        border.width: 1; border.color: Tok.alpha(Tok.accent, 0.45)
                                        Text {
                                            anchors.centerIn: parent
                                            text: ("" + cellRoot.modelData.cls).substring(0, 1).toUpperCase()
                                            color: Tok.accent
                                            font.family: Tok.mono
                                            font.pixelSize: Math.round(dock.iconSize * 0.45)
                                            font.weight: 600
                                        }
                                    }
                                }

                                // ---- running indicator ----
                                // Up to three ticks, then a single wider bar: past three the
                                // count stops being readable and only the fact matters.
                                Row {
                                    spacing: 3
                                    visible: cellRoot.modelData.count > 0
                                    anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
                                    anchors.verticalCenter:   dock.vertical ? parent.verticalCenter : undefined
                                    anchors.top:    dock.edge === "top"    ? parent.top    : undefined
                                    anchors.bottom: dock.edge === "bottom" ? parent.bottom : undefined
                                    anchors.left:   dock.edge === "left"   ? parent.left   : undefined
                                    anchors.right:  dock.edge === "right"  ? parent.right  : undefined
                                    anchors.margins: 3
                                    // The model IS the tick count: one tick per window up to
                                    // three, then a single wide bar. (Rendering three and hiding
                                    // two of them, as this first did, only looks the same.)
                                    Repeater {
                                        model: cellRoot.modelData.count > 3 ? 1 : cellRoot.modelData.count
                                        delegate: Rectangle {
                                            width: cellRoot.modelData.count > 3 ? 16
                                                 : cellRoot.modelData.count === 1 ? 7 : 5
                                            height: 3; radius: 1.5
                                            color: Tok.accent
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                    onEntered: { dock.hoverKey = cellRoot.modelData.key; dock.hoverIndex = cellRoot.index }
                                    onExited: if (dock.hoverKey === cellRoot.modelData.key) { dock.hoverKey = ""; dock.hoverIndex = -1 }
                                    onClicked: (m) => {
                                        if (m.button === Qt.LeftButton) dock.activate(cellRoot.modelData);
                                        else if (m.button === Qt.MiddleButton) dock.launchNew(cellRoot.modelData);
                                        else if (m.button === Qt.RightButton) dock.togglePin(cellRoot.modelData.key);
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- hover label ----
                // Lives outside the card so it can sit in the headroom the input region ignores.
                Rectangle {
                    id: tip
                    visible: dock.showLabels && dock.hoverKey !== "" && win.hovered && win.out
                    readonly property var it: {
                        for (var i = 0; i < dock.items.length; i++) if (dock.items[i].key === dock.hoverKey) return dock.items[i];
                        return null;
                    }
                    width: tipText.implicitWidth + 14
                    height: tipText.implicitHeight + 8
                    radius: Tok.r
                    color: Tok.alpha(Tok.raised, Math.max(0.86, dock.surfaceOpacity))
                    border.width: 1; border.color: Tok.alpha(Tok.ruleHard, 0.6)

                    x: dock.vertical
                       ? (dock.edge === "left" ? card.x + card.width + 6 : card.x - width - 6)
                       : Math.max(0, Math.min(scaler.width - width,
                            card.x + strip.x + (dock.hoverIndex + 0.5) * dock.slot - width / 2))
                    y: dock.vertical
                       ? Math.max(0, Math.min(scaler.height - height,
                            card.y + strip.y + (dock.hoverIndex + 0.5) * dock.slot - height / 2))
                       : (dock.edge === "top" ? card.y + card.height + 6 : card.y - height - 6)

                    Text {
                        id: tipText
                        anchors.centerIn: parent
                        text: {
                            var it = tip.it; if (!it) return "";
                            var n = dock.labelFor(it);
                            return it.count > 1 ? (n + "  ·  " + it.count) : n;
                        }
                        color: Tok.ink
                        font.family: Tok.mono
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    // shared hover state — the tooltip and the magnification both read it
    property string hoverKey: ""
    property int hoverIndex: -1
}
