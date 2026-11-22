// sea-shell — workspaces (Super+W): every workspace as a map of where things actually are.
// Each card is its monitor's shape with the windows at their true positions and sizes, so you
// recognise the one you want by its layout rather than by reading labels. Drag a window onto
// another card to move it there, or onto the last card to start a new workspace. Frosted over
// the wallpaper, in the dashboard's and settings' language.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects

Scope {
    id: panel
    property bool active: false
    property var uiFor: function (scr) { return 1 }
    property var labelFor: function (n) { return "" + n }
    property var scratchWs: null
    property int scratchCount: 0
    property bool scratchOpen: false
    signal dismiss()

    // The window is created on open and gone on close, so no capture outlives its source: a
    // ScreencopyView pinned to a dead window is a prime suspect for the fatal "Wayland connection
    // … Invalid argument". Held mapped through the fade, and pinned to the monitor it opened on.
    property var openOn: null
    property bool held: false
    onActiveChanged: {
        if (panel.active) {
            var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
            panel.openOn = scrs.length ? scrs[0] : null;
            if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) panel.openOn = scrs[i];
            panel.held = true;
            holdTimer.stop();
        } else holdTimer.restart();
    }
    Timer { id: holdTimer; interval: Tok.mFast; onTriggered: panel.held = false }
    // Going somewhere: gone first, then go. When a surface with the keyboard unmaps, Hyprland
    // hands focus back to the window it took it from, which would pull you straight back to the
    // workspace you just left. So no fade here, and the dispatch waits for the unmap.
    property string pendingGo: ""
    function closeThen(cmd) {
        panel.pendingGo = cmd;
        panel.dismiss();
        holdTimer.stop();
        panel.held = false;
        goTimer.restart();
    }
    Timer { id: goTimer; interval: 50; onTriggered: { Hyprland.dispatch(panel.pendingGo); panel.pendingGo = "" } }

    // The picture behind a card: the wallpaper itself, or a video's poster frame.
    WallStills { id: stills; active: panel.held }
    property string wallPath: ""
    FileView {
        path: panel.held ? Quickshell.env("HOME") + "/.config/sea-shell/wallpaper" : ""
        onLoaded: panel.wallPath = text().trim()
    }
    readonly property string wallStill: {
        for (var i = 0; i < stills.list.length; i++) if (stills.list[i].p === panel.wallPath) return stills.list[i].u;
        return "";
    }

    Variants {
        model: (panel.held && panel.openOn) ? [panel.openOn] : []
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property real ui: panel.uiFor(win.screen)
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sea-shell:expose"
            WlrLayershell.keyboardFocus: panel.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore

            // Real workspaces first, in order. Hyprland numbers special workspaces from -98 down;
            // the scratchpad overlays wherever you are, so it is not sorted in among them. It goes
            // on the END when it holds something, because its windows are the ones no other card
            // can show you. Choosing it pulls it down rather than travelling to it; see go().
            readonly property var wsList: {
                var out = [];
                var all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
                for (var i = 0; i < all.length; i++) if (all[i] && all[i].id > 0) out.push(all[i]);
                out.sort(function (a, b) { return a.id - b.id });
                if (panel.scratchCount > 0 && panel.scratchWs) out.push(panel.scratchWs);
                return out;
            }
            readonly property var liveWins: {
                var m = Hyprland.toplevels ? Hyprland.toplevels.values : [], out = [];
                for (var i = 0; i < m.length; i++) if (m[i] && m[i].wayland) out.push(m[i]);
                return out;
            }
            readonly property real screenAspect: (win.screen && win.screen.height > 0)
                                                 ? win.screen.width / win.screen.height : 16 / 9
            readonly property bool manyMonitors: Quickshell.screens.length > 1
            property int sel: 0
            property string filterText: ""
            function winMatches(cls, title) {
                var q = win.filterText.trim().toLowerCase();
                if (!q) return true;
                return ("" + (cls || "")).toLowerCase().indexOf(q) >= 0 || ("" + (title || "")).toLowerCase().indexOf(q) >= 0;
            }
            readonly property var firstMatch: {
                var q = win.filterText.trim().toLowerCase();
                if (!q) return null;
                var m = win.liveWins;
                for (var i = 0; i < m.length; i++) {
                    var t = m[i], ipc = t.lastIpcObject || {};
                    var cls = "" + (ipc.class || (t.wayland && t.wayland.appId) || "");
                    var title = "" + (ipc.title || (t.wayland && t.wayland.title) || cls);
                    if (win.winMatches(cls, title)) return t;
                }
                return null;
            }
            function focusMatch(t) {
                if (!t) return;
                if (t.lastIpcObject && t.lastIpcObject.address)
                    panel.closeThen("hl.dsp.focus({ window = 'address:" + t.lastIpcObject.address + "' })");
                else if (t.wayland) {
                    panel.dismiss();
                    t.wayland.activate();
                }
            }
            Component.onCompleted: {
                // open on the one you are standing in, so Enter is a no-op and the arrows start
                // from where you are rather than from workspace 1
                for (var i = 0; i < win.wsList.length; i++)
                    if (Hyprland.focusedWorkspace && win.wsList[i].id === Hyprland.focusedWorkspace.id) win.sel = i;
                body.ready = true;
            }
            // the lowest number nothing is using, which is where a new workspace goes
            readonly property int freeWs: {
                var used = {}, list = win.wsList;
                for (var i = 0; i < list.length; i++) used[list[i].id] = true;
                for (var n = 1; ; n++) if (!used[n]) return n;
            }
            function goNew() {
                panel.closeThen("hl.dsp.focus({ workspace = " + win.freeWs + " })");
            }
            function closeWin(addr) {
                if (addr) Hyprland.dispatch("hl.dsp.window.close({ window = 'address:" + addr + "' })");
            }
            // ---- dragging a window to another workspace ----
            property var dragWin: null         // { addr, cls, title, from } while one is carried
            property point dragAt: Qt.point(0, 0)
            // which workspace id is under this point of the page; 0 = none
            function wsAt(x, y) {
                for (var i = 0; i < cards.count; i++) {
                    var c = cards.itemAt(i), p = c ? c.mapFromItem(body, x, y) : null;
                    if (p && p.x >= 0 && p.y >= 0 && p.x < c.width && p.y < c.height) return c.modelData.id;
                }
                var q = newCard.mapFromItem(body, x, y);
                return (q.x >= 0 && q.y >= 0 && q.x < newCard.width && q.y < newCard.height) ? win.freeWs : 0;
            }
            function dropWin(x, y) {
                var w = win.dragWin; win.dragWin = null;
                if (!w) return;
                var id = win.wsAt(x, y);
                if (!id || id === w.from) return;
                var where = id < 0 ? "'special:scratch'" : id;
                Hyprland.dispatch("hl.dsp.window.move({ workspace = " + where + ", follow = false, window = 'address:" + w.addr + "' })");
                refreshSoon.restart();
            }
            Timer { id: refreshSoon; interval: 120; onTriggered: Hyprland.refreshToplevels() }

            function go(i) {
                if (i < 0 || i >= win.wsList.length) return;
                var w = win.wsList[i];
                // A special workspace cannot be focused — focus({ workspace = -98 }) does nothing
                // at all. It is toggled over whichever workspace you are already standing on.
                panel.closeThen(w.id < 0 ? "hl.dsp.workspace.toggle_special('scratch')"
                                         : "hl.dsp.focus({ workspace = " + w.id + " })");
            }

            // The wallpaper, blurred here and not by the compositor: what shows through a
            // full-screen layer depends on xray and on whichever windows are behind it. A tint
            // over the top keeps the text readable; solid glass is simply the tint.
            Item {
                id: body
                anchors.fill: parent
                property bool ready: false
                readonly property bool on: body.ready && panel.active
                opacity: body.on ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Rectangle { anchors.fill: parent; color: Tok.bg }
                Image {
                    anchors.fill: parent
                    visible: Tok.glassy && status === Image.Ready
                    asynchronous: true
                    source: panel.wallStill
                    sourceSize.width: 960
                    fillMode: Image.PreserveAspectCrop
                    layer.enabled: true
                    layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 }
                }
                Rectangle { anchors.fill: parent; color: Tok.alpha(Tok.glassTint, Tok.glassy ? Math.max(Tok.glassAlpha, 0.62) : 1) }
                MouseArea { anchors.fill: parent; onClicked: panel.dismiss() }

                FocusScope {
                    anchors.fill: parent; focus: true
                    scale: body.on ? 1 : 0.985
                    Behavior on scale { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
                    Keys.onPressed: (e) => {
                        var n = win.wsList.length, cols = grid.cols;
                        switch (e.key) {
                        case Qt.Key_Escape:
                            if (win.filterText !== "") { win.filterText = ""; e.accepted = true; return; }
                            panel.dismiss(); e.accepted = true; return;
                        case Qt.Key_Backspace:
                            if (win.filterText.length > 0) { win.filterText = win.filterText.slice(0, -1); e.accepted = true; return; }
                            break;
                        case Qt.Key_Left:   win.sel = Math.max(0, win.sel - 1); e.accepted = true; return;
                        case Qt.Key_Right:  win.sel = Math.min(n - 1, win.sel + 1); e.accepted = true; return;
                        case Qt.Key_Up:     win.sel = Math.max(0, win.sel - cols); e.accepted = true; return;
                        case Qt.Key_Down:   win.sel = Math.min(n - 1, win.sel + cols); e.accepted = true; return;
                        case Qt.Key_Return:
                        case Qt.Key_Enter:
                            if (win.filterText !== "" && win.firstMatch) { win.focusMatch(win.firstMatch); e.accepted = true; return; }
                            win.go(win.sel); e.accepted = true; return;
                        case Qt.Key_Space:
                            if (win.filterText === "") { win.go(win.sel); e.accepted = true; return; }
                            break;
                        }
                        if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_N) { win.goNew(); e.accepted = true; return }
                        // 1..9 jumps straight to that workspace when not filtering
                        if (win.filterText === "" && e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                            var want = e.key - Qt.Key_0;
                            for (var i = 0; i < n; i++)
                                if (win.wsList[i].id === want) { win.go(i); e.accepted = true; return }
                        }
                        // Type any letter/number to filter windows across all workspaces
                        if (!(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                            && e.text && e.text.length === 1 && /^[a-zA-Z0-9._\- ]$/.test(e.text)) {
                            win.filterText += e.text;
                            e.accepted = true;
                            return;
                        }
                    }

                    // ---- header ----
                    Item {
                        id: head
                        anchors { top: parent.top; left: parent.left; right: parent.right
                                  topMargin: Math.round(Tok.s8 * win.ui)
                                  leftMargin: Math.round(Tok.s12 * win.ui); rightMargin: Math.round(Tok.s12 * win.ui) }
                        height: Math.round(32 * win.ui)
                        Row {
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            spacing: Math.round(Tok.s3 * win.ui)
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Workspaces"
                                sz: Math.round(Tok.tTitle * win.ui); font.weight: Font.DemiBold
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: win.wsList.length + (win.wsList.length === 1 ? " workspace" : " workspaces")
                                      + "  ·  " + win.liveWins.length + (win.liveWins.length === 1 ? " window" : " windows")
                                sz: Math.round(Tok.tDense * win.ui); color: Tok.ink3
                            }
                            Rectangle {
                                visible: win.filterText !== ""
                                anchors.verticalCenter: parent.verticalCenter
                                height: Math.round(26 * win.ui)
                                width: filtRow.implicitWidth + Math.round(18 * win.ui)
                                radius: height / 2
                                color: Tok.alpha(Tok.accent, 0.18)
                                border.width: 1; border.color: Tok.accent
                                Row {
                                    id: filtRow; anchors.centerIn: parent; spacing: Math.round(6 * win.ui)
                                    IndText { text: "Filter:"; sz: Math.round(Tok.tData * win.ui); color: Tok.ink2 }
                                    IndText { text: win.filterText; sz: Math.round(Tok.tData * win.ui); color: Tok.ink; font.weight: Font.DemiBold }
                                    IndText { visible: !win.firstMatch; text: "(no match)"; sz: Math.round(Tok.tLabel * win.ui); color: Tok.warn }
                                }
                            }
                        }
                        // the keys, each on a cap, as the screenshot bar shows its own
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: Math.round(Tok.s4 * win.ui)
                            Repeater {
                                model: [{ k: "Type", l: "Filter" }, { k: "← →", l: "Choose" }, { k: "1–9", l: "Jump" },
                                        { k: "Ctrl+N", l: "New" }, { k: "Enter", l: "Go" }, { k: "Esc", l: "Close" }]
                                delegate: Row {
                                    required property var modelData
                                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                    spacing: Math.round(6 * win.ui)
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: capText.implicitWidth + Math.round(Tok.s2 * 1.5 * win.ui)
                                        height: Math.round(20 * win.ui); radius: Math.round(5 * win.ui)
                                        color: Tok.alpha(Tok.ink, 0.08)
                                        IndText { id: capText; anchors.centerIn: parent; text: modelData.k
                                                  sz: Math.round((Tok.tData - 1) * win.ui); color: Tok.ink2 }
                                    }
                                    IndText { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                                              sz: Math.round(Tok.tData * win.ui); color: Tok.ink3 }
                                }
                            }
                        }
                    }

                    // ---- the grid ----
                    // Sized to the space rather than to a constant: the cards are as large as the
                    // screen allows, which is the point of taking the whole screen.
                    Item {
                        id: grid
                        anchors {
                            top: head.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                            topMargin: Math.round(Tok.s6 * win.ui)
                            leftMargin: Math.round(Tok.s12 * win.ui)
                            rightMargin: Math.round(Tok.s12 * win.ui) + newCard.width + Math.round(Tok.s6 * win.ui)
                            bottomMargin: Math.round(Tok.s8 * win.ui)
                        }
                        readonly property int n: win.wsList.length
                        readonly property real gap: Math.round(Tok.s6 * win.ui)
                        readonly property real labelH: Math.round(34 * win.ui)   // under each card
                        function fitFor(c) {
                            var rows = Math.ceil(grid.n / c);
                            var w = (grid.width - grid.gap * (c - 1)) / c;
                            var h = (grid.height - grid.gap * (rows - 1)) / rows - grid.labelH;
                            return Math.min(w, h * win.screenAspect);
                        }
                        // Try every column count and keep whichever makes the biggest card that
                        // still fits both ways. Four workspaces on a wide screen want one row;
                        // twelve want three. One or two never fill the page: a map that big stops
                        // reading as a map.
                        readonly property int cols: {
                            if (grid.n <= 0) return 1;
                            var best = 1, bestW = 0;
                            for (var c = 1; c <= grid.n; c++) {
                                var fit = grid.fitFor(c);
                                if (fit > bestW) { bestW = fit; best = c }
                            }
                            return best;
                        }
                        readonly property real cardW: Math.max(120, Math.min(grid.fitFor(grid.cols), grid.width * 0.46))
                        readonly property real cardH: grid.cardW / win.screenAspect

                        Grid {
                            anchors.centerIn: parent
                            columns: grid.cols
                            spacing: grid.gap
                            Repeater {
                                id: cards
                                model: win.wsList
                                delegate: Item {
                                    id: wsCard
                                    required property var modelData
                                    required property int index
                                    // The stash is never the "focused" workspace — it is drawn over
                                    // one. What reads as current for it is being pulled down.
                                    readonly property bool focused: modelData.id < 0
                                                                    ? panel.scratchOpen
                                                                    : (Hyprland.focusedWorkspace
                                                                       && Hyprland.focusedWorkspace.id === modelData.id)
                                    readonly property bool dropHere: win.dragWin !== null && win.dragWin.from !== modelData.id
                                                                     && win.wsAt(win.dragAt.x, win.dragAt.y) === modelData.id
                                    readonly property bool picked: win.dragWin ? dropHere : win.sel === index
                                    readonly property var wins: win.liveWins.filter(function (t) {
                                        return t.workspace && t.workspace.id === wsCard.modelData.id })
                                    // `at` is in layout coordinates across all monitors and each
                                    // workspace lives on its own, so that is the one to map from.
                                    readonly property var mon: (modelData.monitor && modelData.monitor.width > 0) ? modelData.monitor : null
                                    readonly property real monScale: (mon && mon.scale > 0) ? mon.scale : 1
                                    readonly property real monX: mon ? mon.x : (win.screen ? win.screen.x : 0)
                                    readonly property real monY: mon ? mon.y : (win.screen ? win.screen.y : 0)
                                    readonly property real monW: mon ? mon.width / monScale : (win.screen ? win.screen.width : 1)
                                    readonly property real monH: mon ? mon.height / monScale : (win.screen ? win.screen.height : 1)
                                    width: grid.cardW; height: grid.cardH + grid.labelH

                                    // the ring around a chosen card, clear of its rounded edge
                                    Rectangle {
                                        anchors { left: thumb.left; right: thumb.right; top: thumb.top; bottom: thumb.bottom
                                                  margins: -Math.round(3 * win.ui) }
                                        radius: thumb.radius + Math.round(3 * win.ui)
                                        color: "transparent"
                                        border.width: Math.round(2 * win.ui)
                                        border.color: Tok.accent
                                        opacity: wsCard.picked ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                                    }
                                    Rectangle {
                                        id: thumb
                                        anchors { top: parent.top; left: parent.left; right: parent.right }
                                        height: grid.cardH
                                        radius: Math.round(Math.max(Tok.r, 10) * win.ui)
                                        color: Tok.alpha(Tok.ink, 0.07)
                                        scale: cardMa.containsMouse && !wsCard.picked ? 1.012 : 1
                                        Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                                        // Rounded as one: captures ignore their parents' clipping, and
                                        // this also keeps a stray thumbnail from leaking off the card.
                                        Item {
                                            id: map
                                            anchors.fill: parent
                                            layer.enabled: true
                                            layer.effect: MultiEffect { maskEnabled: true; maskSource: mapMask
                                                maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                                            readonly property real sx: map.width / Math.max(1, wsCard.monW)
                                            readonly property real sy: map.height / Math.max(1, wsCard.monH)

                                            Image {
                                                anchors.fill: parent
                                                visible: status === Image.Ready
                                                asynchronous: true; cache: true
                                                source: panel.wallStill
                                                sourceSize.width: 640
                                                fillMode: Image.PreserveAspectCrop
                                            }
                                            Repeater {
                                                model: wsCard.wins
                                                delegate: Rectangle {
                                                    id: winTile
                                                    required property var modelData
                                                    readonly property var ipc: (modelData && modelData.lastIpcObject) || null
                                                    readonly property string cls: {
                                                        try {
                                                            if (!modelData) return "";
                                                            var c = (winTile.ipc && winTile.ipc.class)
                                                                || (modelData.wayland && modelData.wayland.appId) || "";
                                                            return ("" + c).toLowerCase();
                                                        } catch (e) { return "" }
                                                    }
                                                    readonly property string title: (winTile.ipc && winTile.ipc.title) || winTile.cls || "Window"
                                                    readonly property var at: (winTile.ipc && winTile.ipc.at) || [0, 0]
                                                    readonly property var sz: (winTile.ipc && winTile.ipc.size) || [0, 0]
                                                    readonly property bool mapped: winTile.sz[0] > 0 && winTile.sz[1] > 0
                                                    x: winTile.mapped ? (winTile.at[0] - wsCard.monX) * map.sx : 0
                                                    y: winTile.mapped ? (winTile.at[1] - wsCard.monY) * map.sy : 0
                                                    width:  winTile.mapped ? Math.max(18, winTile.sz[0] * map.sx) : map.width
                                                    height: winTile.mapped ? Math.max(14, winTile.sz[1] * map.sy) : map.height
                                                    radius: Math.round(4 * win.ui)
                                                    clip: true
                                                    color: Tok.raised
                                                    border.width: winMa.containsMouse ? 2 : 0
                                                    border.color: Tok.accent
                                                    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }

                                                    ScreencopyView {
                                                        id: winScv
                                                        anchors.fill: parent
                                                        captureSource: (winTile.modelData && winTile.modelData.wayland)
                                                                       ? winTile.modelData.wayland : null
                                                        live: panel.active
                                                        visible: hasContent
                                                    }
                                                    // above the capture: drawn under it, the hover edge never shows
                                                    readonly property bool filterMatched: win.filterText !== "" && win.winMatches(winTile.cls, winTile.title)
                                                    readonly property bool filterDimmed: win.filterText !== "" && !filterMatched
                                                    Rectangle {
                                                        anchors.fill: parent; radius: parent.radius
                                                        color: filterDimmed ? Tok.alpha(Tok.bg, 0.72) : "transparent"
                                                        border.width: (winMa.containsMouse || filterMatched) ? 2 : 0
                                                        border.color: Tok.accent
                                                    }
                                                    // the app's icon on a plate in the corner: enough to
                                                    // tell windows apart, without strips across the picture
                                                    Rectangle {
                                                        visible: winTile.width > 44 * win.ui && winTile.height > 34 * win.ui
                                                        anchors { left: parent.left; bottom: parent.bottom; margins: Math.round(5 * win.ui) }
                                                        width: Math.round(24 * win.ui); height: width
                                                        radius: Math.round(6 * win.ui)
                                                        color: Tok.alpha(Tok.glassTint, 0.88)
                                                        IconImage {
                                                            anchors.centerIn: parent
                                                            implicitSize: Math.round(16 * win.ui)
                                                            asynchronous: true
                                                            source: Quickshell.iconPath(winTile.cls, "application-x-executable")
                                                        }
                                                    }
                                                    IconImage {
                                                        anchors.centerIn: parent
                                                        implicitSize: Math.min(40, Math.max(16, winTile.height * 0.4))
                                                        asynchronous: true
                                                        visible: !winScv.hasContent
                                                        source: Quickshell.iconPath(winTile.cls, "application-x-executable")
                                                    }
                                                    // the name, on hover only and only where it fits
                                                    Rectangle {
                                                        anchors { left: parent.left; right: parent.right; top: parent.top
                                                                  margins: Math.round(5 * win.ui); rightMargin: Math.round(32 * win.ui) }
                                                        height: Math.round(22 * win.ui); radius: Math.round(6 * win.ui)
                                                        visible: winMa.containsMouse && winTile.height > 50 * win.ui && winTile.width > 90 * win.ui
                                                        color: Tok.alpha(Tok.glassTint, 0.92)
                                                        IndText {
                                                            anchors { fill: parent; leftMargin: 7; rightMargin: 7 }
                                                            verticalAlignment: Text.AlignVCenter
                                                            elide: Text.ElideRight
                                                            text: winTile.title
                                                            sz: Math.round(Tok.tData * win.ui)
                                                        }
                                                    }
                                                    MouseArea {
                                                        id: winMa
                                                        anchors.fill: parent; hoverEnabled: true
                                                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                                        cursorShape: win.dragWin ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                                        preventStealing: true
                                                        property point from: Qt.point(0, 0)
                                                        property bool carrying: false
                                                        function pagePoint(m) { return winMa.mapToItem(body, m.x, m.y) }
                                                        onPressed: (m) => { winMa.from = Qt.point(m.x, m.y); winMa.carrying = false }
                                                        onPositionChanged: (m) => {
                                                            if (!winMa.pressed || !(m.buttons & Qt.LeftButton)) return;
                                                            if (!winMa.carrying && Math.abs(m.x - winMa.from.x) + Math.abs(m.y - winMa.from.y) > 8) {
                                                                winMa.carrying = true;
                                                                win.dragWin = { addr: winTile.ipc ? winTile.ipc.address : "", cls: winTile.cls,
                                                                                title: winTile.title, from: wsCard.modelData.id };
                                                            }
                                                            if (winMa.carrying) win.dragAt = winMa.pagePoint(m);
                                                        }
                                                        onReleased: (m) => {
                                                            if (!winMa.carrying) return;
                                                            var p = winMa.pagePoint(m);
                                                            winMa.carrying = false;
                                                            win.dropWin(p.x, p.y);
                                                        }
                                                        onCanceled: { winMa.carrying = false; win.dragWin = null }
                                                        onClicked: (m) => {
                                                            if (winMa.carrying) return;
                                                            var o = winTile.ipc;
                                                            if (m.button === Qt.MiddleButton) { win.closeWin(o && o.address); return }
                                                            if (o && o.address) panel.closeThen("hl.dsp.focus({ window = 'address:" + o.address + "' })");
                                                            else panel.dismiss();
                                                        }
                                                    }
                                                    // close, on hover where there is room for it
                                                    Rectangle {
                                                        anchors { right: parent.right; top: parent.top; margins: Math.round(5 * win.ui) }
                                                        width: Math.round(22 * win.ui); height: width; radius: width / 2
                                                        visible: (winMa.containsMouse || closeMa.containsMouse) && !win.dragWin
                                                                 && winTile.width > 60 * win.ui && winTile.height > 40 * win.ui
                                                        color: closeMa.containsMouse ? Tok.crit : Tok.alpha(Tok.glassTint, 0.92)
                                                        IndText { anchors.centerIn: parent; text: "×"; sz: Math.round(15 * win.ui)
                                                                  color: closeMa.containsMouse ? "white" : Tok.ink }
                                                        MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                                                                    cursorShape: Qt.PointingHandCursor
                                                                    onClicked: win.closeWin(winTile.ipc && winTile.ipc.address) }
                                                    }
                                                }
                                            }
                                            // An empty workspace is still a place you can go, and
                                            // saying so beats an unexplained blank card.
                                            Rectangle {
                                                anchors.centerIn: parent
                                                visible: wsCard.wins.length === 0
                                                width: emptyText.implicitWidth + Math.round(Tok.s4 * win.ui)
                                                height: Math.round(26 * win.ui); radius: height / 2
                                                color: Tok.alpha(Tok.glassTint, 0.82)
                                                IndText { id: emptyText; anchors.centerIn: parent; text: "No windows"
                                                          sz: Math.round(Tok.tData * win.ui); color: Tok.ink2 }
                                            }
                                        }
                                        Rectangle { id: mapMask; anchors.fill: parent; radius: thumb.radius
                                                    visible: false; layer.enabled: true; color: "white" }
                                        // a hairline, so a pale wallpaper still has an edge
                                        Rectangle { anchors.fill: parent; radius: thumb.radius; color: "transparent"
                                                    border.width: 1; border.color: Tok.alpha(Tok.ink, 0.12) }
                                    }

                                    // ---- the name, under the map ----
                                    Row {
                                        anchors { horizontalCenter: thumb.horizontalCenter; bottom: parent.bottom }
                                        height: Math.round(26 * win.ui)
                                        spacing: Math.round(7 * win.ui)
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: wsCard.focused
                                            width: Math.round(7 * win.ui); height: width; radius: width / 2
                                            color: Tok.accent
                                        }
                                        IndText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: wsCard.modelData.id < 0 ? "Stash" : "Workspace " + panel.labelFor(wsCard.modelData.id)
                                            sz: Math.round(Tok.tDense * win.ui); font.weight: Font.DemiBold
                                            color: wsCard.focused ? Tok.accent : Tok.ink
                                        }
                                        IndText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            // a custom name and, with several displays, which it is on
                                            readonly property string named: (wsCard.modelData.id > 0 && wsCard.modelData.name
                                                                             && ("" + wsCard.modelData.name) !== ("" + wsCard.modelData.id))
                                                                            ? ("" + wsCard.modelData.name) : ""
                                            readonly property string where: (win.manyMonitors && wsCard.mon && wsCard.modelData.id > 0) ? ("" + wsCard.mon.name) : ""
                                            text: [named, where].filter(function (x) { return x !== "" }).join("  ·  ")
                                            visible: text !== ""
                                            sz: Math.round(Tok.tData * win.ui); color: Tok.ink3
                                        }
                                    }

                                    MouseArea {
                                        id: cardMa
                                        anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        z: -1                     // window tiles keep their own clicks
                                        // moved, not merely under a pointer that was already resting
                                        // here when the page opened: that would take over the pick
                                        onPositionChanged: if (!win.dragWin) win.sel = wsCard.index
                                        onClicked: win.go(wsCard.index)
                                    }
                                }
                            }
                        }
                    }

                    // A place to go that does not exist yet, and somewhere to drop a window so that
                    // it does. A strip down the side rather than a card, so it never costs the
                    // real workspaces any size.
                    Rectangle {
                        id: newCard
                        anchors { top: grid.top; bottom: grid.bottom; right: parent.right
                                  rightMargin: Math.round(Tok.s12 * win.ui) }
                        width: Math.round(92 * win.ui)
                        readonly property bool dropHere: win.dragWin !== null && win.wsAt(win.dragAt.x, win.dragAt.y) === win.freeWs
                        radius: Math.round(Math.max(Tok.r, 10) * win.ui)
                        color: newCard.dropHere ? Tok.alpha(Tok.accent, 0.20)
                               : (newMa.containsMouse ? Tok.alpha(Tok.ink, 0.10) : Tok.alpha(Tok.ink, 0.05))
                        border.width: newCard.dropHere ? Math.round(2 * win.ui) : 1
                        border.color: newCard.dropHere ? Tok.accent : Tok.alpha(Tok.ink, 0.12)
                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                        Column {
                            anchors.centerIn: parent
                            spacing: Math.round(Tok.s1 * win.ui)
                            IndText { anchors.horizontalCenter: parent.horizontalCenter; text: "+"
                                      sz: Math.round(Tok.tKpi * win.ui); color: Tok.ink2 }
                            IndText { anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
                                      text: "New\nworkspace"; sz: Math.round(Tok.tData * win.ui); color: Tok.ink2 }
                        }
                        MouseArea { id: newMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: win.goNew() }
                    }

                    // the window being carried: an icon and its name under the pointer
                    Rectangle {
                        visible: win.dragWin !== null
                        x: win.dragAt.x + Math.round(12 * win.ui); y: win.dragAt.y + Math.round(12 * win.ui)
                        z: 10
                        width: Math.min(Math.round(280 * win.ui), ghostRow.implicitWidth + Math.round(Tok.s4 * win.ui))
                        height: Math.round(38 * win.ui); radius: Math.round(10 * win.ui)
                        color: Tok.raised; border.width: 1; border.color: Tok.alpha(Tok.ink, 0.14)
                        Row {
                            id: ghostRow
                            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: Math.round(Tok.s2 * win.ui) }
                            spacing: Math.round(Tok.s2 * win.ui)
                            IconImage { anchors.verticalCenter: parent.verticalCenter; implicitSize: Math.round(20 * win.ui)
                                        source: Quickshell.iconPath(win.dragWin ? win.dragWin.cls : "", "application-x-executable") }
                            IndText { anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, Math.round(220 * win.ui))
                                      elide: Text.ElideRight; text: win.dragWin ? win.dragWin.title : ""
                                      sz: Math.round(Tok.tData * win.ui) }
                        }
                    }
                }
            }
        }
    }
}
