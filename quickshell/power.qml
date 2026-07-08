//@ pragma UseQApplication
// sea-shell — power / session menu (SUPER+ESC). Esc or click-outside closes.
// ←→/Tab or hover to select · ⏎ activate · L/S/O/R/P hotkeys · 1–5 quick
// Reboot & shut down ask twice (second ⏎ / second click / same hotkey again).
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

ShellRoot {
    id: root
    property int sel: 0
    property int arming: -1        // action index waiting for its second confirm
    property string who: ""
    property string up: ""

    QtObject {
        id: theme
        readonly property color bg:    "#0d1420"
        readonly property color line:  "#24304a"
        readonly property color text:  "#e2e9f4"
        readonly property color sub:   "#a6b6cf"
        readonly property color faint: "#6f8099"
        readonly property color iris:  "#63c7dd"
        readonly property color frost: "#a2e2e8"
        readonly property color warn:  "#f4c542"
        readonly property color bad:   "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    property var actions: [
        {i:"lock",       l:"Lock",      k:Qt.Key_L, c:"loginctl lock-session",  col:theme.frost},
        {i:"bedtime",    l:"Suspend",   k:Qt.Key_S, c:"systemctl suspend",      col:theme.frost},
        {i:"logout",     l:"Log out",   k:Qt.Key_O, c:"uwsm check is-active >/dev/null 2>&1 && uwsm stop || hyprctl dispatch exit",  col:theme.frost},
        {i:"restart_alt",l:"Reboot",    k:Qt.Key_R, c:"systemctl reboot",       col:theme.warn, danger:true},
        {i:"power_settings_new", l:"Shut down", k:Qt.Key_P, c:"systemctl poweroff", col:theme.bad, danger:true}
    ]
    function run(c) { Quickshell.execDetached(["sh","-c",c]); Qt.quit() }
    function activate(i) {
        root.sel = i;
        var a = root.actions[i];
        if (a.danger && root.arming !== i) { root.arming = i; return }
        run(a.c);
    }

    Process { running: true; command: ["sh","-c","printf '%s@%s|' \"$USER\" \"$(hostnamectl hostname 2>/dev/null || hostname)\"; awk '{s=int($1); printf \"up %dh %02dm\", s/3600, (s%3600)/60}' /proc/uptime"]
        stdout: StdioCollector { id: uOut; onStreamFinished: { var p = uOut.text.split("|"); root.who = p[0]||""; root.up = p[1]||"" } } }

    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:power"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.6); MouseArea { anchors.fill: parent; onClicked: Qt.quit() } }
        Item {
            anchors.fill: parent; focus: true
            Keys.onPressed: (e)=> {
                if (e.key === Qt.Key_Escape) { if (root.arming >= 0) root.arming = -1; else Qt.quit(); return }
                if (e.key === Qt.Key_Left  || e.key === Qt.Key_Backtab) { root.sel = (root.sel+root.actions.length-1)%root.actions.length; root.arming = -1; return }
                if (e.key === Qt.Key_Right || e.key === Qt.Key_Tab)     { root.sel = (root.sel+1)%root.actions.length; root.arming = -1; return }
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { root.activate(root.sel); return }
                if (e.key >= Qt.Key_1 && e.key <= Qt.Key_5) { root.activate(e.key - Qt.Key_1); return }
                for (var i=0;i<root.actions.length;i++) if (e.key === root.actions[i].k) { root.activate(i); return }
            }
        }

        // user @ host · uptime
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: cardsRow.top; anchors.bottomMargin: 34
            spacing: 4
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.who
                color: theme.text; font.pixelSize: 17; font.bold: true; font.family: "monospace" }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.up
                color: theme.faint; font.pixelSize: 12; font.family: "monospace" }
        }

        Row {
            id: cardsRow
            anchors.centerIn: parent; spacing: 22
            Repeater {
                model: root.actions
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === root.sel
                    readonly property bool arm: index === root.arming
                    width: 130; height: 150; radius: 18
                    scale: cur ? 1.05 : 1.0
                    color: arm ? theme.a(theme.bad,0.16) : cur ? theme.a(theme.iris,0.16) : theme.a(theme.bg,0.96)
                    border.width: cur || arm ? 2 : 1
                    border.color: arm ? theme.bad : cur ? modelData.col : theme.a(theme.iris,0.24)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Column {
                        anchors.centerIn: parent; spacing: 12
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.i
                            font.family: "Material Symbols Outlined"; font.pixelSize: 46; color: arm ? theme.bad : modelData.col }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: arm ? "sure?" : modelData.l
                            color: arm ? theme.bad : theme.text; font.pixelSize: 14; font.family: "monospace" }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: String.fromCharCode(modelData.k).toLowerCase()
                            color: cur ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace" }
                    }
                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onEntered: { root.sel = index; if (root.arming !== index) root.arming = -1 }
                        onClicked: root.activate(index) }
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: cardsRow.bottom; anchors.topMargin: 30
            text: root.arming >= 0 ? "press again to " + root.actions[root.arming].l.toLowerCase() + " · esc to cancel"
                                   : "←→ select · ⏎ go · l s o r p · esc to cancel"
            color: root.arming >= 0 ? theme.bad : theme.faint
            font.pixelSize: 12; font.family: "monospace"
        }
    }
}
