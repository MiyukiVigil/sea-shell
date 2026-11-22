// sea-shell — the wallpaper strip. A row of your wallpapers along the foot of the screen with
// the current one ringed, shown for a moment whenever Super+N / Super+Shift+N moves through
// them (so you can see where you are in the collection and what is next), or on its own with
// `qs -c sea-shell ipc call wallpaper strip`. A click on a picture switches to it.
//
// It never takes the keyboard: it is a glance, like a volume overlay, not a dialog, so it can
// come up while you are typing without stealing a single key. It takes the pointer only while
// it is up, and stays while the pointer is over it.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

Scope {
    id: root
    property bool shown: false
    signal picked(string path)

    // a moment after a cycle; longer when asked for directly
    function flash() { root.place(); root.shown = true; hideTimer.interval = 2600; hideTimer.restart() }
    function open()  { root.place(); root.shown = true; hideTimer.interval = 6000; hideTimer.restart() }
    function close() { root.shown = false }
    Timer { id: hideTimer; onTriggered: if (!hover.hovered) root.shown = false }

    // same rebuild-if-lost rule as the other warm windows (see PowerMenu.placeOn)
    property bool screensMoved: false
    Connections { target: Quickshell; function onScreensChanged() { root.screensMoved = true } }
    function place() {
        var f = Hyprland.focusedMonitor, s = Quickshell.screens, t = null;
        for (var i = 0; f && i < s.length; i++) if (s[i].name === f.name) t = s[i];
        if (!t && s.length) t = s[0];
        if (t && t === win.screen && (root.screensMoved || !win.backingWindowVisible)) win.screen = null;
        if (t) win.screen = t;
        root.screensMoved = false;
    }

    WallStills { id: stills; active: root.shown || win.visible }
    property string current: ""
    FileView {
        path: Quickshell.env("HOME") + "/.config/sea-shell/wallpaper"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.current = text().trim()
    }
    readonly property int curIx: {
        for (var i = 0; i < stills.list.length; i++) if (stills.list[i].p === root.current) return i;
        return -1;
    }
    onCurIxChanged: if (curIx >= 0) strip.positionViewAtIndex(curIx, ListView.Center)
    onShownChanged: if (shown && curIx >= 0) strip.positionViewAtIndex(curIx, ListView.Center)

    PanelWindow {
        id: win
        readonly property real ui: Tok.uiFor(win.screen)
        anchors { bottom: true; left: true; right: true }
        implicitHeight: 200
        // Unmapped while it is closed. A 1920-wide surface still holds a buffer when the
        // pictures on it are invisible.
        visible: root.shown || sheet.opacity > 0
        color: "transparent"
        mask: root.shown ? hitRegion : noInput
        Region { id: noInput }
        Region { id: hitRegion; item: sheet }
        WlrLayershell.namespace: "sea-shell:wallstrip"
        // Keep closed panels warm without blocking fullscreen presentation.
        WlrLayershell.layer: (root.shown || sheet.opacity > 0) ? WlrLayer.Overlay : WlrLayer.Bottom
        // Quickshell applies the new layer when the native surface is mapped again.
        // Keep the QML content resident and preserve the window's visibility policy.
        Connections {
            target: win.WlrLayershell
            function onLayerChanged() {
                if (!win.visible) return;
                win.visible = false;
                win.visible = Qt.binding(function() { return root.shown || sheet.opacity > 0; });
            }
        }
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            id: sheet
            readonly property real k: win.ui
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: (root.shown ? 28 : 12) * k
            Behavior on anchors.bottomMargin { NumberAnimation { duration: Tok.reducedMotion ? 0 : 200; easing.type: Easing.OutCubic } }
            width: Math.min(parent.width - 48 * k, Math.max(600 * k, stills.list.length * 154 * k + 14 * k))
            height: 146 * k
            radius: Tok.rCard * k
            color: Tok.bg
            border.width: 1; border.color: Tok.alpha(Tok.ink, 0.075)
            opacity: root.shown ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Tok.reducedMotion ? 0 : (root.shown ? 150 : 260) } }
            HoverHandler { id: hover; onHoveredChanged: if (!hovered && root.shown) hideTimer.restart() }

            ListView {
                id: strip
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 * sheet.k }
                width: Math.min(parent.width - 24 * sheet.k, stills.list.length * 154 * sheet.k - 10 * sheet.k)
                height: 96 * sheet.k
                orientation: ListView.Horizontal
                spacing: 10 * sheet.k
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: stills.list
                delegate: Item {
                    id: tile
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === root.curIx
                    width: 144 * sheet.k; height: strip.height
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width - (tile.cur ? 0 : 8 * sheet.k); height: 81 * sheet.k - (tile.cur ? 0 : 5 * sheet.k)
                        Behavior on width { NumberAnimation { duration: Tok.mFast } }
                        radius: 10 * sheet.k
                        color: Tok.alpha(Tok.ink, 0.06)
                        border.width: tile.cur ? 3 * sheet.k : (tMa.containsMouse ? 2 * sheet.k : 0)
                        border.color: tile.cur ? Tok.accent : Tok.alpha(Tok.ink, 0.25)
                        clip: true
                        Image {
                            anchors.fill: parent; anchors.margins: parent.border.width
                            source: tile.modelData.u
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true; cache: false
                            sourceSize.width: 300
                        }
                    }
                    MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: if (!tile.cur) root.picked(tile.modelData.p) }
                }
                // the wheel moves along the row, as a trackpad's sideways swipe would
                WheelHandler { onWheel: (e) => strip.flick(e.angleDelta.y * 8 * sheet.k, 0) }
            }
            Row {
                id: capRow
                anchors { left: parent.left; leftMargin: 20 * sheet.k; bottom: parent.bottom; bottomMargin: 12 * sheet.k }
                spacing: 8 * sheet.k
                IndText { text: root.curIx >= 0 ? stills.list[root.curIx].cap : "Wallpapers"; sz: Math.round(13 * sheet.k)
                    font.weight: Font.DemiBold; elide: Text.ElideRight; width: Math.min(implicitWidth, sheet.width * 0.6) }
                IndText { text: root.curIx >= 0 ? (root.curIx + 1) + " of " + stills.list.length : stills.list.length + " wallpapers"
                    sz: Math.round(12 * sheet.k); color: Tok.ink3 }
            }
            IndText {
                visible: capRow.width + implicitWidth + 60 * sheet.k < sheet.width
                anchors { right: parent.right; rightMargin: 20 * sheet.k; bottom: parent.bottom; bottomMargin: 12 * sheet.k }
                text: "Super N next · Super Shift N back"; sz: Math.round(11 * sheet.k); color: Tok.ink3
            }
        }
    }
}
