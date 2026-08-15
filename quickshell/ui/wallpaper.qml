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
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgScale: 0     // 0 = auto (per-monitor), >0 = manual UI-scale multiplier
    function uiFor(scr) {          // matches shell.qml: ≤1440p → 1×, grows past it, capped 2.5×
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    // follow the bar's appearance config (accent + light/dark + matugen flag + UI scale)
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text);
            if(j.accent) root.accent=j.accent;
            if(j.scale!==undefined) root.cfgScale=j.scale;
            if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light");
            if(j.matugen!==undefined) root.matchColors=!!j.matugen; } catch(e){} } } }

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
    property string autopauseScript: Qt.resolvedUrl("sea-wallpaper-autopause.sh").toString().replace("file://","")
    property string applyScript: Qt.resolvedUrl("sea-wallpaper-apply.sh").toString().replace("file://","")
    function setWall(p) {
        // persist the pick so it can be restored on login
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.config/sea-shell && printf '%s' '" + p + "' > ~/.config/sea-shell/wallpaper"]);
        // sync lock screen background (first frame for video, direct copy for static)
        Quickshell.execDetached(["sh", root.lockwallScript, p]);
        // recolour the bar to match the wallpaper (matugen)
        if (root.matchColors) Quickshell.execDetached(["sh", root.matugenScript, p]);
        // The whole swww/mpvpaper/hyprpaper ladder used to be inlined here as a shell string,
        // duplicating sea-wallpaper-restore.sh — with the transition hardcoded to `grow` in
        // both, so the picker and the SUPER+N keybind could not share a setting. One script now.
        Quickshell.execDetached(["sh", root.applyScript, p]);
        Qt.quit()
    }

    PanelWindow {
        id: win
        readonly property real ui: root.uiFor(win.screen)
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        // scale the centred picker up on big displays (content stays centred)
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55); MouseArea { anchors.fill: parent; onClicked: Qt.quit() } }
        Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: Qt.quit() }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width / win.ui - 80, 900)
            height: Math.min(parent.height / win.ui - 80, 620)
            radius: Tok.rCard
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 22; spacing: 14

                RowLayout {
                    spacing: 12; Layout.fillWidth: true
                    SeaLogo { size: 28; card: theme.line; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                    Text { text: "wallpapers"; color: theme.text; font.pixelSize: 18; font.family: Tok.mono; font.bold: true }
                    Text { text: "~/Pictures/wallpapers"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                    Item { Layout.fillWidth: true }
                    // match-colours toggle (matugen)
                    Rectangle {
                        implicitHeight: 30; implicitWidth: mcRow.implicitWidth + 22; radius: Tok.r
                        color: root.matchColors ? theme.a(theme.iris,0.22) : theme.a(theme.line,0.5)
                        border.width: 1; border.color: root.matchColors ? theme.iris : theme.a(theme.iris,0.16)
                        RowLayout { id: mcRow; anchors.centerIn: parent; spacing: 7
                            Text { text: "auto_awesome"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: root.matchColors?theme.frost:theme.faint }
                            Text { text: "match colours"; color: root.matchColors?theme.text:theme.faint; font.pixelSize: 12; font.family: Tok.mono } }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.matchColors = !root.matchColors }
                    }
                    Text { text: root.papers.length + " found"; color: theme.frost; font.pixelSize: 11; font.family: Tok.mono }
                }

                GridView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: (width - 1) / Math.max(1, Math.floor(width / 220)); cellHeight: cellWidth * 0.6
                    model: root.papers
                    delegate: Item {
                        id: cell
                        required property var modelData
                        readonly property bool vid: root.isVideo(modelData)
                        property string thumbPath: ""     // set once the poster frame is extracted
                        property bool thumbReady: false
                        width: GridView.view.cellWidth; height: GridView.view.cellHeight

                        // Image can't decode video — extract a cached poster frame with ffmpeg
                        // (seek 1s to skip black intros; fall back to frame 0 for very short clips),
                        // then reveal it. Cached under ~/.cache, so re-opening the picker is instant.
                        Process {
                            running: cell.vid
                            command: ["sh","-c",
                                "d=\"$HOME/.cache/sea-shell/wallthumbs\"; mkdir -p \"$d\"; " +
                                "t=\"$d/" + root.base(modelData) + ".jpg\"; " +
                                "if [ ! -s \"$t\" ]; then " +
                                "ffmpeg -y -loglevel error -ss 1 -i '" + modelData + "' -frames:v 1 -vf scale=400:-2 \"$t\" </dev/null 2>/dev/null || " +
                                "ffmpeg -y -loglevel error -i '" + modelData + "' -frames:v 1 -vf scale=400:-2 \"$t\" </dev/null 2>/dev/null; fi; " +
                                "[ -s \"$t\" ] && printf '%s' \"$t\""]
                            stdout: StdioCollector { id: tOut; onStreamFinished: { var p = tOut.text.trim(); if (p) { cell.thumbPath = p; cell.thumbReady = true } } }
                        }

                        Rectangle {
                            anchors.fill: parent; anchors.margins: 6; radius: Tok.r; clip: true
                            color: theme.line
                            border.width: wm.containsMouse ? 2 : 1
                            border.color: wm.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                            Image {
                                anchors.fill: parent; anchors.margins: 1
                                visible: cell.vid ? cell.thumbReady : true
                                source: cell.vid ? (cell.thumbReady ? "file://" + cell.thumbPath : "") : "file://" + modelData
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                sourceSize.width: 400
                            }
                            // still extracting (or ffmpeg unavailable) → film-icon placeholder
                            Text {
                                anchors.centerIn: parent; visible: cell.vid && !cell.thumbReady
                                text: "movie"; font.family: "Material Symbols Outlined"; font.pixelSize: 40; color: theme.iris
                            }
                            // little play badge marks a card as an animated wallpaper
                            Rectangle {
                                visible: cell.vid && cell.thumbReady
                                anchors { top: parent.top; left: parent.left; margins: 6 }
                                width: 22; height: 22; radius: Tok.r; color: Qt.rgba(0, 0, 0, 0.5)
                                Text { anchors.centerIn: parent; text: "play_arrow"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: theme.frost }
                            }
                            Rectangle {
                                anchors.bottom: parent.bottom; width: parent.width; height: 24
                                color: Qt.rgba(0, 0, 0, 0.55)
                                Text { anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideMiddle
                                    text: root.base(modelData); color: theme.text; font.pixelSize: 11; font.family: Tok.mono; horizontalAlignment: Text.AlignHCenter }
                            }
                            MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setWall(modelData) }
                        }
                    }
                }

                Text {
                    visible: root.papers.length === 0
                    Layout.alignment: Qt.AlignHCenter
                    text: "no images in ~/Pictures/wallpapers — drop some jpg/png/webp there"
                    color: theme.faint; font.pixelSize: 12; font.family: Tok.mono
                }
            }
        }
    }
}
