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
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgScale: 0     // 0 = auto (per-monitor), >0 = manual UI-scale multiplier
    function uiFor(scr) {          // matches shell.qml: ≤1440p → 1×, grows past it, capped 2.5×
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    // follow the bar's appearance config (accent + light/dark + UI scale)
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.scale!==undefined) root.cfgScale=j.scale; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

    // ---------- industrial token shim ----------
    // Colours come from the shared Tok singleton (see shell.qml). This surface used to carry its
    // own copy of the ramp AND its own appearance.json parse, so it drifted from the bar every
    // time the palette changed. The `theme.*` vocabulary is kept because the call sites below
    // speak it; only the source of the values moved.
    QtObject {
        id: theme
        readonly property bool  light: Tok.light
        readonly property color bg:    Tok.bg
        readonly property color panel: Tok.surface
        readonly property color line:  Tok.ruleHard
        readonly property color text:  Tok.ink
        readonly property color sub:   Tok.ink2
        readonly property color faint: Tok.ink3
        readonly property color iris:  Tok.accent
        readonly property color frost: Tok.ink2
        readonly property color good:  Tok.ok
        readonly property color warn:  Tok.warn
        readonly property color bad:   Tok.crit
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    property var actions: [
        {i:"lock",       l:"Lock",      k:Qt.Key_L, c:"~/.config/quickshell/sea-shell/sea-lock.sh",  col:theme.frost},
        {i:"bedtime",    l:"Suspend",   k:Qt.Key_S, c:"systemctl suspend",      col:theme.frost},
        {i:"logout",     l:"Log out",   k:Qt.Key_O, c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }",  col:theme.frost},
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
        id: win
        readonly property real ui: root.uiFor(win.screen)
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:power"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        // scale the whole overlay up on big displays; centred content stays centred (default
        // transformOrigin is the centre, i.e. the screen centre for this full-screen surface)
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

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
                color: theme.text; font.pixelSize: 17; font.bold: true; font.family: Tok.mono }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.up
                color: theme.faint; font.pixelSize: 12; font.family: Tok.mono }
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
                    width: 130; height: 150; radius: Tok.rCard
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
                            color: arm ? theme.bad : theme.text; font.pixelSize: 14; font.family: Tok.mono }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: String.fromCharCode(modelData.k).toLowerCase()
                            color: cur ? theme.frost : theme.faint; font.pixelSize: 10; font.family: Tok.mono }
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
            font.pixelSize: 12; font.family: Tok.mono
        }
    }
}
