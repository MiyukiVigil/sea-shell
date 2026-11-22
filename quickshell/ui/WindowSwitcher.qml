// sea-shell — the Alt+Tab window switcher. Hold Alt and press Tab to move through your windows,
// most recently used first; let go of Alt and the one you stopped on is focused. A quick tap
// swaps to the previous window without showing anything, as on Windows. Alt+` does the same
// among the windows of the app you are in. The cross on a tile, or a middle click, closes it.
//
// Driven by Hyprland global shortcuts rather than `qs ipc` commands: those are separate
// processes, so a fast Alt+Tab could deliver "focus it" before "open". Shortcuts arrive in order.
//
// The binds are in hypr/keybinds.lua and their shape matters: Hyprland cancels a release bind
// when another key (Tab) went down since its own, unless the bind is transparent. Purely visual,
// so the window takes no keyboard focus and the app underneath keeps it until the switch.
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

Scope {
    id: sw
    property var uiFor: function (scr) { return 1 }
    property bool open: false       // Alt is held and a pick is under way
    property bool shown: false      // on screen; only once the hold outlasts a quick tap
    property var mru: []            // the toplevels, most recently focused first
    property var picked: null       // tracks the WINDOW: a refresh can reorder the list under it
    property bool sameApp: false    // Alt+`: only the windows of the app in focus

    // Only on the focused monitor: a card on each output reads as a second switcher behind it.
    readonly property var targetScreen: {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        if (fm && fm.name) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) return scrs[i];
        return scrs.length ? scrs[0] : null;
    }

    // Kept here, not read from hyprctl's focusHistoryID: that is only as fresh as the last
    // refresh, which lands after the pick is made, so a tap could go to the wrong window.
    // focusHistoryID still orders whatever has not been focused since the shell started.
    Connections {
        target: Hyprland
        function onActiveToplevelChanged() {
            var t = Hyprland.activeToplevel; if (!t) return;
            var alive = Hyprland.toplevels ? Hyprland.toplevels.values : [];
            sw.mru = [t].concat(sw.mru.filter(function (o) { return o !== t && alive.indexOf(o) >= 0 }));
        }
    }
    Timer { running: true; interval: 1000; onTriggered: Hyprland.refreshToplevels() }

    // Membership comes from the WAYLAND handle, never lastIpcObject: `Hyprland.toplevels` keeps
    // ghost entries with no handle, and lastIpcObject goes empty on a long-lived shell.
    readonly property var wins: {
        var m = Hyprland.toplevels ? Hyprland.toplevels.values : [], out = [], order = sw.mru;
        for (var i = 0; i < m.length; i++) {
            var t = m[i];
            if (t && t.wayland && t.wayland.appId && ("" + t.wayland.appId).trim() !== "") out.push(t);
        }
        var active = Hyprland.activeToplevel;
        if (sw.sameApp && active && active.wayland) {
            var app = active.wayland.appId;
            out = out.filter(function (t) { return t.wayland.appId === app });
        }
        function rank(t) {
            var at = order.indexOf(t);
            if (at >= 0) return at;
            var o = t.lastIpcObject;
            return 1000 + (o && o.focusHistoryID !== undefined ? o.focusHistoryID : 9000);
        }
        out.sort(function (a, b) { return rank(a) - rank(b) });
        return out;
    }
    readonly property int sel: Math.max(0, sw.wins.indexOf(sw.picked))

    function stepApp(dir) {
        if (!sw.open) sw.sameApp = true;
        sw.step(dir);
        if (!sw.open) sw.sameApp = false;     // no window to go to
    }
    function closeWin(w) {
        if (w && w.lastIpcObject && w.lastIpcObject.address)
            Hyprland.dispatch("hl.dsp.window.close({ window = 'address:" + w.lastIpcObject.address + "' })");
        if (w === sw.picked) sw.picked = sw.wins[(sw.sel + 1) % Math.max(1, sw.wins.length)] || null;
    }
    function step(dir) {
        Hyprland.refreshToplevels();          // titles; async, the list already stands on its own
        var n = sw.wins.length; if (n === 0) return;
        if (!sw.open) {
            sw.picked = sw.wins[n > 1 ? (dir > 0 ? 1 : n - 1) : 0];
            sw.open = true;
            revealTimer.restart();
        } else {
            sw.picked = sw.wins[((sw.sel + dir) % n + n) % n];
            revealTimer.stop();
            sw.shown = true;                  // a second Tab means they are choosing: show it now
        }
    }
    function cancel() { revealTimer.stop(); sw.open = false; sw.shown = false; sw.sameApp = false }
    function commit() {
        if (!sw.open) return;
        var w = sw.picked; sw.cancel();
        if (!w) return;
        if (w.lastIpcObject && w.lastIpcObject.address)
            Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + w.lastIpcObject.address + "' })");
        else if (w.wayland)
            w.wayland.activate();             // no hyprctl data yet: the wayland handle still focuses
    }
    Timer { id: revealTimer; interval: 120; onTriggered: sw.shown = sw.open }

    GlobalShortcut { appid: "sea-shell"; name: "switcher-next"; description: "Window switcher"
        onPressed: sw.step(1) }
    GlobalShortcut { appid: "sea-shell"; name: "switcher-prev"; description: "Window switcher (back)"
        onPressed: sw.step(-1) }
    GlobalShortcut { appid: "sea-shell"; name: "switcher-app"; description: "Window switcher (this app)"
        onPressed: sw.stepApp(1) }
    GlobalShortcut { appid: "sea-shell"; name: "switcher-cancel"; description: "Close the window switcher"
        onPressed: sw.cancel() }
    // A release bind reaches a global shortcut as a release, so listen for both.
    GlobalShortcut { appid: "sea-shell"; name: "switcher-commit"; description: "Focus the chosen window"
        onPressed: sw.commit(); onReleased: sw.commit() }

    Variants {
        model: (sw.shown && sw.targetScreen) ? [sw.targetScreen] : []
        PanelWindow {
            id: swWin
            required property var modelData
            screen: modelData
            readonly property real ui: sw.uiFor(swWin.screen)
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:switcher"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; left: true; right: true; bottom: true }

            // click outside to dismiss without switching
            Rectangle { anchors.fill: parent; color: Tok.alpha("#000000", 0.18)
                MouseArea { anchors.fill: parent; onClicked: sw.cancel() } }

            Glass {
                id: card
                anchors.centerIn: parent
                radius: Tok.rCard
                readonly property int tileW: 216
                readonly property int tileH: 158
                // As many tiles as fit in 86% of the screen, capped at the window count. Depends
                // on neither the card's nor the grid's size, so there is no binding loop.
                readonly property int cols: Math.max(1, Math.min(sw.wins.length,
                                                                 Math.floor(((swWin.width / swWin.ui) * 0.86) / (card.tileW + Tok.s1))))
                readonly property int rows: Math.ceil(sw.wins.length / card.cols)
                readonly property real fit: Math.min(1, (swWin.height / swWin.ui * 0.84) / Math.max(1, card.rows * (card.tileH + Tok.s1) + 80))
                width: grid.implicitWidth + Tok.s3 * 2
                height: inner.implicitHeight + Tok.s3 * 2
                scale: swWin.ui * card.fit * (card.ready ? 1 : 0.97)
                opacity: card.ready ? 1 : 0
                property bool ready: false
                Component.onCompleted: card.ready = true
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                Column {
                    id: inner
                    anchors.centerIn: parent
                    spacing: Tok.s2
                    Grid {
                        id: grid
                        anchors.horizontalCenter: parent.horizontalCenter
                        columns: card.cols
                        spacing: Tok.s1
                        Repeater {
                            model: sw.wins
                            delegate: Rectangle {
                                id: tile
                                required property int index
                                required property var modelData
                                readonly property bool sel: index === sw.sel
                                readonly property string cls: ("" + ((modelData.lastIpcObject && modelData.lastIpcObject.class)
                                                                     || (modelData.wayland && modelData.wayland.appId) || "")).toLowerCase()
                                readonly property string title: "" + ((modelData.lastIpcObject && (modelData.lastIpcObject.title || modelData.lastIpcObject.class))
                                                                      || (modelData.wayland && (modelData.wayland.title || modelData.wayland.appId)) || "Window")
                                width: card.tileW; height: card.tileH
                                radius: Tok.r + 4
                                color: tile.sel ? Tok.alpha(Tok.accent, 0.20)
                                                : (tileMa.containsMouse ? Tok.alpha(Tok.ink, 0.06) : "transparent")
                                border.width: tile.sel ? 2 : 0
                                border.color: Tok.accent
                                Behavior on color { ColorAnimation { duration: Tok.mMicro } }

                                Row {
                                    id: tileHead
                                    anchors { top: parent.top; left: parent.left; right: parent.right
                                              topMargin: Tok.s2; leftMargin: Tok.s2 + 2; rightMargin: Tok.s2 + 2 }
                                    spacing: Tok.s2 - 1
                                    Image {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18; asynchronous: true
                                        sourceSize.width: 36; sourceSize.height: 36; fillMode: Image.PreserveAspectFit
                                        source: Quickshell.iconPath(tile.cls, "application-x-executable")
                                    }
                                    IndText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 25; elide: Text.ElideRight
                                        text: tile.title; sz: Tok.tData
                                        font.weight: tile.sel ? Font.DemiBold : Font.Normal
                                        color: tile.sel ? Tok.ink : Tok.ink2
                                    }
                                }
                                Rectangle {
                                    anchors { top: tileHead.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                                              topMargin: Tok.s2 - 1; leftMargin: Tok.s2; rightMargin: Tok.s2; bottomMargin: Tok.s2 }
                                    radius: Tok.r; clip: true
                                    color: Tok.alpha(Tok.ink, 0.06)
                                    ScreencopyView {
                                        id: thumb
                                        anchors.fill: parent
                                        captureSource: (tile.modelData && tile.modelData.wayland) ? tile.modelData.wayland : null
                                        live: sw.shown
                                        visible: hasContent
                                    }
                                    Image {
                                        anchors.centerIn: parent; visible: !thumb.hasContent
                                        width: 44; height: 44; asynchronous: true
                                        sourceSize.width: 88; sourceSize.height: 88; fillMode: Image.PreserveAspectFit
                                        source: Quickshell.iconPath(tile.cls, "application-x-executable")
                                    }
                                }
                                MouseArea {
                                    id: tileMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    // Only a pointer that actually moved picks: the card appearing
                                    // under a resting pointer must not override what Tab chose.
                                    property point from: Qt.point(-1, -1)
                                    onEntered: tileMa.from = Qt.point(tileMa.mouseX, tileMa.mouseY)
                                    onPositionChanged: (m) => {
                                        if (Math.abs(m.x - tileMa.from.x) + Math.abs(m.y - tileMa.from.y) > 3) sw.picked = tile.modelData;
                                    }
                                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                    onClicked: (m) => {
                                        if (m.button === Qt.MiddleButton) { sw.closeWin(tile.modelData); return }
                                        sw.picked = tile.modelData; sw.commit();
                                    }
                                }
                                Rectangle {
                                    anchors { top: parent.top; right: parent.right; margins: Tok.s1 + 2 }
                                    width: 22; height: 22; radius: 11
                                    visible: tileMa.containsMouse || crossMa.containsMouse
                                    color: crossMa.containsMouse ? Tok.crit : Tok.alpha(Tok.ink, 0.10)
                                    IndText { anchors.centerIn: parent; text: "×"; sz: 15
                                              color: crossMa.containsMouse ? "white" : Tok.ink }
                                    MouseArea { id: crossMa; anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor; onClicked: sw.closeWin(tile.modelData) }
                                }
                            }
                        }
                    }
                    IndText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        topPadding: 2
                        text: "Release Alt to switch  ·  Esc cancels  ·  Middle-click closes"
                        sz: Tok.tData - 1; color: Tok.ink3
                    }
                }
            }
        }
    }
}
