// sea-shell — the widget gallery.
//
// WHERE WIDGETS COME FROM, NOT A SECOND PLACE TO READ THEM. This drawer used to be a column of
// live widgets, a smaller copy of what the desktop could already show. Now it is what macOS's
// Edit Widgets is: every kind of widget in every size and face, and you drag the one you want
// onto the desktop, where it lands where you let go, at the size you picked. While it is open
// the desktop is arranging too, so the widgets already there can be moved or removed in the
// same breath.
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

PanelWindow {
    id: drawer
    property bool opened: false
    property bool edgeEnabled: true
    property real ui: 1
    property var readings: ({})
    property var player: null
    property var viz: []
    // where the desktop's field starts and ends, so a drop lands where the desktop will draw it
    property int insetTop: 0
    property int insetBottom: 0
    signal requested(bool open)
    signal settingsRequested()
    property real pull: 0
    property bool dragging: false
    readonly property real reveal: Math.max(motion.progress, pull)
    SurfaceMotion { id: motion; opened: drawer.opened; reduced: Tok.reducedMotion }
    Behavior on pull { enabled: !drawer.dragging; NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "sea-shell:widgets"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    visible: edgeEnabled || opened || motion.presenting
    // Only the sheet takes input, so the desktop beside it can still be arranged; while a
    // widget is being carried, the whole screen does, so the drop is seen wherever it lands.
    mask: Region { item: drawer.opened ? (drawer.carrying ? drawer.contentItem : drawer.tucked ? tuckPill : sheet) : edgeTab }

    component Widget: MaterialWidget {
        readings: drawer.readings; player: drawer.player; viz: drawer.viz
        active: drawer.opened; reducedMotion: Tok.reducedMotion; uiFont: Tok.sans
        surface: Tok.surface; container: Tok.accentWash; accent: Tok.accent
        ink: Tok.ink; secondary: Tok.ink2; accentInk: Tok.accentInk
    }

    // ---------- carrying a widget out ----------
    // footprints as sea-desktop.py has them, so the ghost is the size the widget will be
    readonly property var footprints: ({ small: { w: 0.0885, h: 0.17 }, medium: { w: 0.1875, h: 0.17 }, large: { w: 0.1875, h: 0.376 } })
    readonly property real fieldH: drawer.height - (drawer.insetTop + drawer.insetBottom) * drawer.ui
    property var carried: null            // { kind, size, face }
    readonly property bool carrying: carried !== null
    readonly property bool overCancel: carrying && carryAt.x >= cancelPill.x && carryAt.x <= cancelPill.x + cancelPill.width
                                       && carryAt.y >= cancelPill.y && carryAt.y <= cancelPill.y + cancelPill.height
    property point carryAt: Qt.point(0, 0)
    function drop() {
        var c = drawer.carried;
        drawer.carried = null;
        if (!c) return;
        // let go on the cancel pill: changed your mind
        if (drawer.overCancel) return;
        var fx = drawer.carryAt.x / drawer.width;
        var fy = (drawer.carryAt.y - drawer.insetTop * drawer.ui) / drawer.fieldH;
        var cmd = ["python3", Qt.resolvedUrl("sea-desktop.py").toString().replace("file://", ""), "--add-" + c.kind,
                   "--x", "" + fx.toFixed(4), "--y", "" + fy.toFixed(4), "--size", c.size];
        if (c.face) cmd.push("--face", c.face);
        Quickshell.execDetached(cmd);
    }

    Item { anchors.fill: parent; focus: drawer.opened; Keys.onEscapePressed: drawer.requested(false) }
    // a light veil, so the desktop is still there to drop onto
    Rectangle {
        anchors.fill: parent; color: Qt.rgba(0, 0, 0, drawer.carrying ? 0.08 : 0.16); opacity: drawer.reveal
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
    }
    Text {
        visible: drawer.opened
        opacity: drawer.reveal
        anchors.horizontalCenter: parent.horizontalCenter
        y: drawer.carrying ? drawer.height - 110 * drawer.ui : drawer.tucked ? drawer.height - 86 * drawer.ui : sheet.y - 34 * drawer.ui
        text: drawer.carrying ? "Let go to put it here" : "Drag a widget onto the desktop · drag, resize or ⚙ the ones already there · Esc when done"
        color: "white"; font.family: Tok.sans; font.pixelSize: 13 * drawer.ui
        style: Text.Outline; styleColor: Qt.rgba(0, 0, 0, 0.45)
    }

    // THE TRAY. Along the bottom, as macOS's widget gallery is: it covers a short band of the
    // screen rather than a whole side, so every widget already on the desktop stays in reach.
    property string tab: "clock"
    // Tucked: the tray sinks to a small pill, so the bottom of the desktop can be reached too.
    property bool tucked: false
    onOpenedChanged: if (opened) tucked = false
    readonly property var groups: ({
        clock: [ { size: "small", face: "dial", l: "Dial" }, { size: "small", face: "cookie", l: "Cookie" },
                 { size: "small", face: "digital", l: "Digital" }, { size: "small", face: "stacked", l: "Stacked" },
                 { size: "medium", face: "dial", l: "Time and dial" }, { size: "medium", face: "stacked", l: "Stacked" },
                 { size: "large", face: "dial", l: "With calendar" } ],
        weather: [ { size: "small", l: "Now" }, { size: "medium", l: "Three days" }, { size: "large", l: "With details" } ],
        system: [ { size: "small", l: "Processor" }, { size: "medium", l: "Gauges" }, { size: "large", l: "With details" } ],
        media: [ { size: "small", l: "Cover" }, { size: "medium", l: "Player" }, { size: "large", l: "Big cover" } ],
        calendar: [ { size: "small", l: "Today" }, { size: "medium", l: "Up next" }, { size: "large", l: "Month" } ],
        battery: [ { size: "small", l: "This computer" }, { size: "medium", l: "Devices" }, { size: "large", l: "With time left" } ] })
    Rectangle {
        id: sheet
        // the shelf's height: a large widget fills it, small and medium ones stand at 62% of it,
        // the way macOS's gallery sets mixed sizes side by side
        readonly property real shelf: 150 * drawer.ui
        width: Math.min(1180 * drawer.ui, drawer.width - 48 * drawer.ui)
        height: tray.implicitHeight + 32 * drawer.ui
        x: (drawer.width - width) / 2
        // rises from the bottom edge, and sinks back while a widget is being carried
        property real shown: drawer.reveal * (drawer.carrying || drawer.tucked ? 0 : 1)
        Behavior on shown { enabled: drawer.opened; NumberAnimation { duration: Tok.mBase; easing.type: Easing.OutCubic } }
        y: drawer.height + 12 - (height + 30 * drawer.ui) * shown
        radius: 24 * drawer.ui; color: Tok.bg; border.width: 1; border.color: Tok.rule
        enabled: drawer.opened
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            id: tray
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 * drawer.ui }
            spacing: 12 * drawer.ui
            RowLayout {
                Layout.fillWidth: true; spacing: 6 * drawer.ui
                Text { text: "Widgets"; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 17 * drawer.ui; font.bold: true; Layout.rightMargin: 10 * drawer.ui }
                Repeater {
                    model: [{ k: "clock", l: "Clock", i: "schedule" }, { k: "weather", l: "Weather", i: "partly_cloudy_day" },
                            { k: "system", l: "System", i: "monitor_heart" }, { k: "media", l: "Music", i: "graphic_eq" },
                            { k: "calendar", l: "Calendar", i: "calendar_month" }, { k: "battery", l: "Batteries", i: "battery_full" }]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: drawer.tab === modelData.k
                        implicitWidth: tabRow.implicitWidth + 24 * drawer.ui; implicitHeight: 32 * drawer.ui; radius: height / 2
                        color: on ? Tok.accent : (tabMa.containsMouse ? Tok.accentWash : Tok.sunken)
                        Row { id: tabRow; anchors.centerIn: parent; spacing: 5 * drawer.ui
                            Text { text: modelData.i; font.family: "Material Symbols Rounded"; font.pixelSize: 16 * drawer.ui; color: parent.parent.on ? Tok.accentInk : Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: modelData.l; font.family: Tok.sans; font.pixelSize: 12 * drawer.ui; color: parent.parent.on ? Tok.accentInk : Tok.ink; anchors.verticalCenter: parent.verticalCenter } }
                        MouseArea { id: tabMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: drawer.tab = modelData.k }
                    }
                }
                Item { Layout.fillWidth: true }
                Rectangle { implicitWidth: moreT.implicitWidth + 24 * drawer.ui; implicitHeight: 32 * drawer.ui; radius: height / 2; color: moreMa.containsMouse ? Tok.accentWash : Tok.sunken
                    Text { id: moreT; anchors.centerIn: parent; text: "Desktop settings"; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 12 * drawer.ui }
                    MouseArea { id: moreMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { drawer.requested(false); drawer.settingsRequested() } } }
                Rectangle { implicitWidth: 32 * drawer.ui; implicitHeight: 32 * drawer.ui; radius: width / 2; color: tuckMa.containsMouse ? Tok.accentWash : Tok.sunken
                    Text { anchors.centerIn: parent; text: "keyboard_arrow_down"; color: Tok.ink; font.family: "Material Symbols Rounded"; font.pixelSize: 21 * drawer.ui }
                    MouseArea { id: tuckMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: drawer.tucked = true } }
                Rectangle { implicitWidth: 32 * drawer.ui; implicitHeight: 32 * drawer.ui; radius: width / 2; color: Tok.accent
                    Text { anchors.centerIn: parent; text: "check"; color: Tok.accentInk; font.family: "Material Symbols Rounded"; font.pixelSize: 19 * drawer.ui }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: drawer.requested(false) } }
            }
            Flickable {
                Layout.fillWidth: true
                implicitHeight: sheet.shelf + 22 * drawer.ui
                contentWidth: previews.implicitWidth; contentHeight: height
                clip: true; boundsBehavior: Flickable.StopAtBounds; interactive: !drawer.carrying
                flickableDirection: Flickable.HorizontalFlick
                Row {
                    id: previews
                    spacing: 14 * drawer.ui
                    Repeater {
                        model: drawer.groups[drawer.tab]
                        delegate: Column {
                            id: tile
                            required property var modelData
                            readonly property real dw: tile.modelData.size === "small" ? 170 : 360
                            readonly property real dh: tile.modelData.size === "large" ? 376 : 170
                            readonly property real k: tile.modelData.size === "large" ? sheet.shelf / 376 : sheet.shelf * 0.62 / 170
                            spacing: 4 * drawer.ui
                            Item {
                                width: tile.dw * tile.k; height: tile.dh * tile.k
                                Widget {
                                    width: tile.dw; height: tile.dh; scale: tile.k; transformOrigin: Item.TopLeft
                                    kind: drawer.tab; size: tile.modelData.size.charAt(0)
                                    face: tile.modelData.face || "dial"
                                    active: drawer.opened && !drawer.carrying
                                }
                                Rectangle { anchors.fill: parent; radius: 10 * drawer.ui; color: "transparent"
                                    border.width: grab.containsMouse ? 2 : 0; border.color: Tok.accent }
                                MouseArea {
                                    id: grab
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: drawer.carrying ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    property point start
                                    onPressed: e => start = Qt.point(e.x, e.y)
                                    onPositionChanged: e => {
                                        if (!pressed) return;
                                        var p = mapToItem(drawer.contentItem, e.x, e.y);
                                        if (!drawer.carrying && Math.abs(e.x - start.x) + Math.abs(e.y - start.y) > 6)
                                            drawer.carried = { kind: drawer.tab, size: tile.modelData.size, face: tile.modelData.face || "" };
                                        drawer.carryAt = p;
                                    }
                                    onReleased: drawer.drop()
                                    onCanceled: drawer.carried = null
                                }
                            }
                            Text { text: tile.modelData.l; color: Tok.ink2; font.family: Tok.sans; font.pixelSize: 11 * drawer.ui }
                        }
                    }
                }
            }
        }
    }

    Widget {
        id: ghost
        visible: drawer.carrying
        readonly property var fp: drawer.carried ? drawer.footprints[drawer.carried.size] : drawer.footprints.small
        width: fp.w * drawer.width; height: fp.h * drawer.fieldH
        x: drawer.carryAt.x - width / 2; y: drawer.carryAt.y - height / 2
        kind: drawer.carried ? drawer.carried.kind : "clock"
        size: drawer.carried ? drawer.carried.size.charAt(0) : "s"
        face: drawer.carried && drawer.carried.face ? drawer.carried.face : "dial"
        opacity: drawer.overCancel ? 0.4 : 0.92
        active: drawer.carrying
    }

    // the tray, tucked away: one pill to bring it back
    Rectangle {
        id: tuckPill
        visible: drawer.opened && drawer.tucked && !drawer.carrying
        width: tuckRow.implicitWidth + 30 * drawer.ui; height: 38 * drawer.ui; radius: height / 2
        x: (drawer.width - width) / 2; y: drawer.height - height - 14 * drawer.ui
        color: tuckPillMa.containsMouse ? Tok.accent : Tok.bg; border.width: 1; border.color: Tok.rule
        Row { id: tuckRow; anchors.centerIn: parent; spacing: 6 * drawer.ui
            Text { text: "keyboard_arrow_up"; font.family: "Material Symbols Rounded"; font.pixelSize: 20 * drawer.ui; color: tuckPillMa.containsMouse ? Tok.accentInk : Tok.ink; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Widgets"; font.family: Tok.sans; font.pixelSize: 13 * drawer.ui; font.bold: true; color: tuckPillMa.containsMouse ? Tok.accentInk : Tok.ink; anchors.verticalCenter: parent.verticalCenter } }
        MouseArea { id: tuckPillMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: drawer.tucked = false }
    }

    // where the sheet was, while it is out of the way: let go here to put nothing down
    Rectangle {
        id: cancelPill
        visible: drawer.carrying
        width: 170 * drawer.ui; height: 44 * drawer.ui; radius: height / 2
        x: (drawer.width - width) / 2
        y: drawer.height - height - 40 * drawer.ui
        color: drawer.overCancel ? Tok.critWash : Tok.bg; border.width: 1; border.color: drawer.overCancel ? Tok.crit : Tok.rule
        Row { anchors.centerIn: parent; spacing: 6 * drawer.ui
            Text { text: "close"; color: drawer.overCancel ? Tok.crit : Tok.ink2; font.family: "Material Symbols Rounded"; font.pixelSize: 18 * drawer.ui; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Drop here to cancel"; color: drawer.overCancel ? Tok.crit : Tok.ink2; font.family: Tok.sans; font.pixelSize: 12 * drawer.ui; anchors.verticalCenter: parent.verticalCenter } }
    }

    // The handle sits where the drawer comes from: the BOTTOM edge, left of the dock. It used to
    // be a sliver on the left edge pulled sideways, from when the gallery slid in from the left;
    // once it rose from the bottom, the gesture and the motion pointed different ways.
    Rectangle {
        id: edgeTab
        readonly property bool hot: edgeMouse.containsMouse || edgeMouse.pressed
        x: 28 * drawer.ui
        y: drawer.height - height
        width: (hot ? tabLabel.implicitWidth + 40 : 44) * drawer.ui
        height: (hot ? 30 : 5) * drawer.ui
        radius: hot ? 12 * drawer.ui : height / 2
        // the resting sliver is a hint of a handle, not a button: barely there until pointed at
        color: hot ? Tok.surface : Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, 0.28)
        border.width: hot ? 1 : 0; border.color: Tok.ruleHard
        visible: drawer.edgeEnabled && !drawer.opened
        Behavior on width { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
        Row {
            anchors.centerIn: parent; spacing: 6 * drawer.ui
            opacity: edgeTab.hot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            Text { text: "widgets"; font.family: "Material Symbols Rounded"; font.pixelSize: 15 * drawer.ui; color: Tok.accent; anchors.verticalCenter: parent.verticalCenter }
            Text { id: tabLabel; text: "Widgets"; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 12 * drawer.ui; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea {
            id: edgeMouse; hoverEnabled: true
            // a few pixels of reach above the sliver, so it can be found without aiming
            anchors.fill: parent; anchors.topMargin: edgeTab.hot ? 0 : -6 * drawer.ui
            cursorShape: Qt.PointingHandCursor
            property real startY: 0
            onPressed: event => { startY = event.y; drawer.dragging = true }
            onPositionChanged: event => { if (pressed) drawer.pull = Math.min(1, Math.max(0, (startY - event.y) / (sheet.height + 24))) }
            onReleased: event => {
                var distance = startY - event.y;
                drawer.dragging = false;
                if (distance > 64 * drawer.ui || Math.abs(distance) < 6 * drawer.ui) drawer.requested(true);
                drawer.pull = 0;
            }
            onCanceled: { drawer.dragging = false; drawer.pull = 0 }
        }
    }
}
