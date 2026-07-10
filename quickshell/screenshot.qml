//@ pragma UseQApplication
// sea-shell — screenshot picker (Print). Pick a monitor, region, window, or everything.
// The widget quits BEFORE grim fires (0.3s grace) so it never appears in the shot.
// Keys: 1..9 monitor · R region · W window · A all · S toggle save · Esc cancel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

ShellRoot {
    id: root
    property bool save: false
    property string winGeo: ""
    property string winTitle: ""
    property string accent: "#63c7dd"
    property bool cfgLight: false

    // pin the bar's focus grab so an open dropdown (music player etc.) survives
    // both this widget taking focus AND the later slurp/grim capture
    Component.onCompleted: Quickshell.execDetached(["qs","-c","sea-shell","ipc","call","shell","pin"])
    function cancel() { Quickshell.execDetached(["qs","-c","sea-shell","ipc","call","shell","unpin"]); Qt.quit() }

    // follow the shell's accent + light/dark (same appearance.json every other surface reads)
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

    QtObject {
        id: theme
        readonly property bool light: root.cfgLight
        readonly property color _acc: root.accent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    light ? Qt.hsla(_ah, 0.20, 0.945, 1) : Qt.hsla(_ah, 0.36, 0.070, 1)
        readonly property color line:  light ? Qt.hsla(_ah, 0.16, 0.780, 1) : Qt.hsla(_ah, 0.24, 0.205, 1)
        readonly property color text:  light ? "#0c1520" : "#e2e9f4"
        readonly property color sub:   light ? "#2c4256" : "#a6b6cf"
        readonly property color faint: light ? "#48606f" : "#6f8099"
        readonly property color iris:  light ? Qt.darker(root.accent, 2.4) : root.accent
        readonly property color frost: light ? Qt.darker(root.accent, 1.7) : Qt.lighter(root.accent, 1.22)
        readonly property color warn:  light ? "#b9820f" : "#f4c542"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // grab the focused window's geometry NOW (the picker is a layer surface, so
    // hyprctl still reports the real window as active)
    Process { running: true; command: ["sh","-c","hyprctl activewindow -j 2>/dev/null"]
        stdout: StdioCollector { id: awOut; onStreamFinished: {
            try { var j = JSON.parse(awOut.text);
                if (j && j.at && j.size) {
                    root.winGeo = j.at[0] + "," + j.at[1] + " " + j.size[0] + "x" + j.size[1];
                    root.winTitle = (j.title || "window").slice(0, 22);
                }
            } catch(e) {} } } }

    function shoot(kind, arg) {
        var g = kind === "out"    ? "grim -o '" + arg + "'"
              : kind === "win"    ? "grim -g '" + root.winGeo + "'"
              : kind === "all"    ? "grim"
              :                     "grim -g \"$(slurp)\"";
        var cmd = root.save
            ? "f=~/Pictures/$(date +%Y%m%d-%H%M%S).png; " + g + " \"$f\" && wl-copy < \"$f\" && notify-send 'sea-shell' \"Saved $f + copied\""
            : g + " - | wl-copy && notify-send 'sea-shell' 'Screenshot copied to clipboard'";
        // leave time for the compositor to unmap this widget before the capture,
        // and release the dropdown pin once the shot is done (success or not)
        Quickshell.execDetached(["sh","-c","sleep 0.3; " + cmd + "; qs -c sea-shell ipc call shell unpin"]);
        Qt.quit();
    }

    // one target button
    component Shot: Rectangle {
        property string icon: ""
        property string label: ""
        property string hotkey: ""
        signal fire()
        width: 118; height: 96; radius: 14
        color: sm.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.bg, 0.96)
        border.width: 1; border.color: sm.containsMouse ? theme.iris : theme.a(theme.iris, 0.24)
        Behavior on color { ColorAnimation { duration: 100 } }
        Column {
            anchors.centerIn: parent; spacing: 6
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.icon
                font.family: "Material Symbols Outlined"; font.pixelSize: 30; color: theme.frost }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.label
                color: theme.text; font.pixelSize: 11; font.family: "monospace"; width: 106
                horizontalAlignment: Text.AlignHCenter; elide: Text.ElideMiddle }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.hotkey
                color: theme.faint; font.pixelSize: 9; font.family: "monospace" }
        }
        MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: parent.fire() }
    }

    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:shot"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.45); MouseArea { anchors.fill: parent; onClicked: root.cancel() } }
        Item {
            anchors.fill: parent; focus: true
            Keys.onPressed: (e)=> {
                if (e.key === Qt.Key_Escape) { root.cancel(); return }
                if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                    var i = e.key - Qt.Key_1, scr = Quickshell.screens;
                    if (i < scr.length) root.shoot("out", scr[i].name); return }
                if (e.key === Qt.Key_R) { root.shoot("region"); return }
                if (e.key === Qt.Key_A) { root.shoot("all"); return }
                if (e.key === Qt.Key_W && root.winGeo !== "") { root.shoot("win"); return }
                if (e.key === Qt.Key_S) { root.save = !root.save; return }
            }
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: buttons.width + 44
            height: buttons.height + 96
            radius: 18
            color: theme.a(theme.bg, 0.97)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            Text { anchors { top: parent.top; topMargin: 16; horizontalCenter: parent.horizontalCenter }
                text: "screenshot"; color: theme.iris; font.pixelSize: 13; font.family: "monospace"; font.bold: true }

            Row {
                id: buttons
                anchors.centerIn: parent; anchors.verticalCenterOffset: 4; spacing: 12
                Repeater {
                    model: Quickshell.screens
                    delegate: Shot {
                        required property var modelData
                        required property int index
                        icon: "desktop_windows"
                        label: modelData.name
                        hotkey: (index + 1) + ""
                        onFire: root.shoot("out", modelData.name)
                    }
                }
                Shot { icon: "crop"; label: "region"; hotkey: "r"; onFire: root.shoot("region") }
                Shot { visible: root.winGeo !== ""; icon: "select_window"; label: root.winTitle; hotkey: "w"; onFire: root.shoot("win") }
                Shot { icon: "grid_view"; label: "everything"; hotkey: "a"; onFire: root.shoot("all") }
            }

            // save-to-file toggle + hint
            Row {
                anchors { bottom: parent.bottom; bottomMargin: 12; horizontalCenter: parent.horizontalCenter }
                spacing: 8
                Rectangle {
                    width: svTxt.width + 34; height: 22; radius: 11
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.save ? theme.a(theme.iris, 0.3) : theme.a(theme.line, 0.5)
                    border.width: 1; border.color: root.save ? theme.iris : theme.a(theme.line, 0.9)
                    Text { id: svTxt; anchors { left: parent.left; leftMargin: 24; verticalCenter: parent.verticalCenter }
                        text: "save to ~/Pictures"; color: root.save ? theme.frost : theme.faint
                        font.pixelSize: 10; font.family: "monospace" }
                    Rectangle { width: 10; height: 10; radius: 5; anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        color: root.save ? theme.frost : theme.faint }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.save = !root.save }
                }
                Text { anchors.verticalCenter: parent.verticalCenter
                    text: root.save ? "· file + clipboard" : "· clipboard only"
                    color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
            }
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; top: card.bottom; topMargin: 18 }
            text: "1–9 screens · r region · w window · a all · s save · esc cancel"
            color: theme.faint; font.pixelSize: 11; font.family: "monospace"
        }
    }
}
