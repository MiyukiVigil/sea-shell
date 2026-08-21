// sea-shell — one thing on the desktop.
//
// A widget or a shortcut; the difference is what it draws and what a click does, not how it
// is placed. Position arrives as fractions of the usable field and is handed back the same
// way, so this never learns what a monitor is.
//
// IT IS ONLY DRAGGABLE WHILE ARRANGING. A desktop where a stray click can move your clock
// is a desktop you cannot trust, and the whole point of putting things somewhere is that
// they stay there.
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import QtQuick

Item {
    id: item

    property var pal
    property string uiFont: "sans"
    property var spec: ({})
    property bool editing: false
    property real fieldW: 1920
    property real fieldH: 1000
    property real fieldY: 0

    // fx, fy are fractions; `exact` means the user asked for no nudging (shift held).
    signal moved(real fx, real fy, bool exact)
    signal removed()

    readonly property string kind: (item.spec && item.spec.kind) ? item.spec.kind : "clock"

    x: (item.spec ? item.spec.x : 0) * item.fieldW
    y: (item.spec ? item.spec.y : 0) * item.fieldH + item.fieldY
    width: Math.max(40, (item.spec ? item.spec.w : 0.1) * item.fieldW)
    height: Math.max(30, (item.spec ? item.spec.h : 0.08) * item.fieldH)

    // ---------- ground ----------
    Rectangle {
        anchors.fill: parent
        radius: Tok.r + 4
        // Off by default: a desktop widget sits on a picture the user chose, and a panel
        // behind it is one more thing covering that picture. It appears while arranging so
        // there is something to aim at, and stays if the item asks for it.
        visible: item.editing || (item.spec && item.spec.ground === true)
        color: item.pal ? item.pal.a(item.pal.bg, item.editing ? 0.55 : 0.35) : "#40000000"
        border.width: item.editing ? 1 : 0
        border.color: item.pal ? item.pal.a(item.pal.iris, dragArea.drag.active ? 0.9 : 0.45)
                               : "#7788ccff"
    }

    // ---------- clock ----------
    Column {
        anchors.centerIn: parent
        visible: item.kind === "clock"
        spacing: 2
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: clk.hhmm
            color: item.pal ? item.pal.text : "#eee"
            font.pixelSize: Math.max(18, item.height * 0.42)
            font.family: item.uiFont
            // A widget on a wallpaper has no ground to sit on, so it needs to survive
            // landing on a pale one. A soft dark halo costs nothing and is the difference
            // between readable everywhere and readable on dark pictures.
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.45)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: clk.date
            color: item.pal ? item.pal.sub : "#bbb"
            font.pixelSize: Math.max(9, item.height * 0.14)
            font.family: item.uiFont
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.4)
        }
    }
    QtObject {
        id: clk
        property string hhmm: ""
        property string date: ""
    }
    Timer {
        running: item.kind === "clock"
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var d = new Date();
            clk.hhmm = Qt.formatDateTime(d, "HH:mm");
            clk.date = Qt.formatDateTime(d, "ddd d MMM");
        }
    }

    // ---------- shortcut ----------
    Column {
        anchors.centerIn: parent
        visible: item.kind === "launch"
        spacing: 4
        IconImage {
            anchors.horizontalCenter: parent.horizontalCenter
            implicitSize: Math.max(24, Math.min(item.width, item.height) * 0.55)
            source: (item.spec && item.spec.icon)
                    ? Quickshell.iconPath(item.spec.icon, true) : ""
            visible: source !== ""
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: item.width - 8
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: (item.spec && item.spec.label) ? item.spec.label : ""
            color: item.pal ? item.pal.text : "#eee"
            font.pixelSize: 11
            font.family: item.uiFont
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.5)
        }
    }

    Process { id: launcher }
    function launch() {
        if (!item.spec) return;
        // A .desktop id is the better handle: the entry knows its own Exec field codes,
        // its working directory and whether it wants a terminal, none of which survive
        // being flattened into a string. A raw command still works for anything without
        // an entry — a script, a one-liner — which is most of what a shortcut is for.
        if (item.spec.entry) {
            try {
                var e = DesktopEntries.byId("" + item.spec.entry);
                if (e) { e.execute(); return }
            } catch (err) {}
        }
        if (!item.spec.exec) return;
        launcher.command = ["sh", "-c", "" + item.spec.exec];
        launcher.running = true;
    }

    // ---------- interaction ----------
    MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: item.editing ? (drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                  : (item.kind === "launch" ? Qt.PointingHandCursor
                                                            : Qt.ArrowCursor)
        drag.target: item.editing ? item : null
        drag.threshold: 4
        // Right-click removes, but only while arranging: on a desktop you are using, the
        // gesture that deletes your shortcut must not be one click away from launching it.
        acceptedButtons: item.editing ? (Qt.LeftButton | Qt.RightButton) : Qt.LeftButton
        // Holding shift means "exactly here" — the nudge is help, not a rule.
        property bool exact: false
        onPressed: mouse => { dragArea.exact = (mouse.modifiers & Qt.ShiftModifier) !== 0 }
        onReleased: {
            if (!item.editing) return;
            var fx = Math.max(0, Math.min(1, item.x / item.fieldW));
            var fy = Math.max(0, Math.min(1, (item.y - item.fieldY) / item.fieldH));
            item.moved(fx, fy, dragArea.exact);
        }
        onClicked: mouse => {
            if (item.editing) {
                if (mouse.button === Qt.RightButton) item.removed();
                return;
            }
            if (item.kind === "launch") item.launch();
        }
    }
}
