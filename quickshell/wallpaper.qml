//@ pragma UseQApplication
// sea-shell — wallpaper picker (SUPER+W)
// Reads ~/Pictures/wallpapers and sets the pick with swww (install: pacman -S swww).
// Esc / click-outside closes.
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    property var papers: []

    QtObject {
        id: theme
        readonly property color bg:    "#0d1420"
        readonly property color line:  "#24304a"
        readonly property color text:  "#e2e9f4"
        readonly property color faint: "#6f8099"
        readonly property color iris:  "#63c7dd"
        readonly property color frost: "#a2e2e8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    Process {
        id: lsProc; running: true
        command: ["sh", "-c", "find ~/Pictures/wallpapers -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.mp4' -o -iname '*.webm' \\) 2>/dev/null | sort"]
        stdout: StdioCollector { id: lsOut; onStreamFinished: {
            var l = lsOut.text.trim(); root.papers = l ? l.split("\n") : [];
        } }
    }
    function base(p) { return p.slice(p.lastIndexOf("/") + 1) }
    function isVideo(p) { var e = p.toLowerCase(); return e.endsWith(".mp4") || e.endsWith(".webm") || e.endsWith(".gif") }
    property bool matchColors: true
    property string matugenScript: Qt.resolvedUrl("matugen-accent.sh").toString().replace("file://", "")
    property string lockwallScript: Qt.resolvedUrl("sea-lockwall.sh").toString().replace("file://","")
    function setWall(p) {
        var vid = isVideo(p);
        // persist the pick so it can be restored on login
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.config/sea-shell && printf '%s' '" + p + "' > ~/.config/sea-shell/wallpaper"]);
        // sync lock screen background (first frame for video, direct copy for static)
        Quickshell.execDetached(["sh", root.lockwallScript, p]);
        // recolour the bar to match the wallpaper (matugen)
        if (root.matchColors) Quickshell.execDetached(["sh", root.matugenScript, p]);
        if (vid) {
            // animated: mpvpaper (install: pacman -S mpvpaper)
            Quickshell.execDetached(["sh", "-c",
                "if command -v mpvpaper >/dev/null; then pkill -x mpvpaper; sleep 0.2; " +
                "mpvpaper -o 'no-audio --loop-file=inf --panscan=1.0' '*' '" + p + "' & disown; " +
                "else notify-send 'sea-shell' 'Animated wallpapers need mpvpaper: pacman -S mpvpaper'; fi"]);
        } else {
            // static: swww (or its awww fork) → hyprpaper → mpvpaper (mpv can show a still) fallback
            Quickshell.execDetached(["sh", "-c",
                "pkill -x mpvpaper 2>/dev/null; " +
                "SW=$(command -v swww || command -v awww); SWD=$(command -v swww-daemon || command -v awww-daemon); " +
                "if [ -n \"$SW\" ]; then \"$SW\" query >/dev/null 2>&1 || { \"$SWD\" & sleep 0.4; }; \"$SW\" img '" + p + "' --transition-type grow --transition-fps 60; " +
                "elif command -v hyprpaper >/dev/null; then killall hyprpaper 2>/dev/null; hyprpaper & sleep 0.3; hyprctl hyprpaper preload '" + p + "'; hyprctl hyprpaper wallpaper ',\"" + p + "\"'; " +
                "elif command -v mpvpaper >/dev/null; then mpvpaper -o 'no-audio --image-display-duration=inf --panscan=1.0' '*' '" + p + "' & disown; " +
                "else notify-send 'sea-shell' 'Install a wallpaper daemon: pacman -S swww  (or hyprpaper / mpvpaper)'; fi"]);
        }
        Qt.quit()
    }

    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55); MouseArea { anchors.fill: parent; onClicked: Qt.quit() } }
        Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: Qt.quit() }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 900)
            height: Math.min(parent.height - 80, 620)
            radius: 18
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 22; spacing: 14

                RowLayout {
                    spacing: 12; Layout.fillWidth: true
                    IconImage { implicitSize: 28; source: Qt.resolvedUrl("logo.svg") }
                    Text { text: "wallpapers"; color: theme.text; font.pixelSize: 18; font.family: "monospace"; font.bold: true }
                    Text { text: "~/Pictures/wallpapers"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                    Item { Layout.fillWidth: true }
                    // match-colours toggle (matugen)
                    Rectangle {
                        implicitHeight: 30; implicitWidth: mcRow.implicitWidth + 22; radius: 8
                        color: root.matchColors ? theme.a(theme.iris,0.22) : theme.a(theme.line,0.5)
                        border.width: 1; border.color: root.matchColors ? theme.iris : theme.a(theme.iris,0.16)
                        RowLayout { id: mcRow; anchors.centerIn: parent; spacing: 7
                            Text { text: "auto_awesome"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: root.matchColors?theme.frost:theme.faint }
                            Text { text: "match colours"; color: root.matchColors?theme.text:theme.faint; font.pixelSize: 12; font.family: "monospace" } }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.matchColors = !root.matchColors }
                    }
                    Text { text: root.papers.length + " found"; color: theme.frost; font.pixelSize: 11; font.family: "monospace" }
                }

                GridView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: (width - 1) / Math.max(1, Math.floor(width / 220)); cellHeight: cellWidth * 0.6
                    model: root.papers
                    delegate: Item {
                        required property var modelData
                        readonly property bool vid: root.isVideo(modelData)
                        width: GridView.view.cellWidth; height: GridView.view.cellHeight
                        Rectangle {
                            anchors.fill: parent; anchors.margins: 6; radius: 10; clip: true
                            color: theme.line
                            border.width: wm.containsMouse ? 2 : 1
                            border.color: wm.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                            Image {
                                anchors.fill: parent; anchors.margins: 1
                                visible: !parent.parent.vid
                                source: parent.parent.vid ? "" : "file://" + modelData
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                sourceSize.width: 400
                            }
                            // animated wallpaper → film-icon placeholder (can't decode as image)
                            Text {
                                anchors.centerIn: parent; visible: parent.parent.vid
                                text: "movie"; font.family: "Material Symbols Outlined"; font.pixelSize: 40; color: theme.iris
                            }
                            Rectangle {
                                anchors.bottom: parent.bottom; width: parent.width; height: 24
                                color: Qt.rgba(0, 0, 0, 0.55)
                                Text { anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideMiddle
                                    text: root.base(modelData); color: theme.text; font.pixelSize: 11; font.family: "monospace"; horizontalAlignment: Text.AlignHCenter }
                            }
                            MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setWall(modelData) }
                        }
                    }
                }

                Text {
                    visible: root.papers.length === 0
                    Layout.alignment: Qt.AlignHCenter
                    text: "no images in ~/Pictures/wallpapers — drop some jpg/png/webp there"
                    color: theme.faint; font.pixelSize: 12; font.family: "monospace"
                }
            }
        }
    }
}
