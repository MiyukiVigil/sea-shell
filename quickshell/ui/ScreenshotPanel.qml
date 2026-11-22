// sea-shell — screenshot picker (Print). Pick a monitor, region, window, everything,
// quick copy to clipboard, or OCR text.
// Keys: 1..9 monitor · R region · C quick copy · W window · O OCR · A all · Esc cancel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

Scope {
    id: root
    property bool shown: false
    signal closed()
    property string winGeo: ""
    property string winTitle: ""
    property var recentShots: []

    readonly property color cardFill:  Tok.surface
    readonly property color cardEdge:  Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color cardSheen: Tok.light ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(1, 1, 1, 0.045)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)

    property bool screensMoved: false
    Connections { target: Quickshell; function onScreensChanged() { root.screensMoved = true } }
    function placeOn(w) {
        var f = Hyprland.focusedMonitor, s = Quickshell.screens, t = null;
        for (var i = 0; f && i < s.length; i++) if (s[i].name === f.name) t = s[i];
        if (!t && s.length) t = s[0];
        if (t && (t !== w.screen || root.screensMoved || !w.backingWindowVisible || !w.visible)) {
            w.visible = false;
            w.screen = t;
            w.visible = true;
        }
        root.screensMoved = false;
    }

    function open() {
        if (root.shown) return;
        root.placeOn(win);
        root.winGeo = ""; root.winTitle = "";
        awProc.running = true;
        recentProc.running = true;
        Quickshell.execDetached(["quickshell","-c","sea-shell","ipc","call","shell","pin"]);
        root.shown = true;
    }
    function hide() { root.shown = false; closedTimer.restart() }
    function close() {
        if (!root.shown) return;
        Quickshell.execDetached(["quickshell","-c","sea-shell","ipc","call","shell","unpin"]);
        root.hide();
    }
    function toggle() { if (root.shown) root.close(); else root.open() }
    Timer { id: closedTimer; interval: 60; onTriggered: root.closed() }

    Process { id: awProc; command: ["sh","-c","hyprctl activewindow -j 2>/dev/null"]
        stdout: StdioCollector { id: awOut; onStreamFinished: {
            try { var j = JSON.parse(awOut.text);
                if (j && j.at && j.size) {
                    root.winGeo = j.at[0] + "," + j.at[1] + " " + j.size[0] + "x" + j.size[1];
                    root.winTitle = j.title || j.class || "";
                }
            } catch(e) {} } } }

    Process {
        id: recentProc
        command: ["sh", "-c", "ls -1t \"$HOME/Pictures/Screenshots\"/*.png \"$HOME/Pictures/Screenshots\"/*.jpg \"$HOME/Pictures/Screenshots\"/*.webp 2>/dev/null | head -3"]
        stdout: StdioCollector { id: recOut; onStreamFinished: {
            var out = [], lines = recOut.text.trim().split("\n");
            for (var i = 0; i < lines.length; i++) {
                var p = lines[i].trim();
                if (p) out.push({ path: p, name: p.slice(p.lastIndexOf("/") + 1) });
            }
            root.recentShots = out;
        } }
    }

    function shoot(kind, arg) {
        if (kind === "ocr") {
            Quickshell.execDetached(["sh", "-c", "sleep 0.25; ~/.config/quickshell/sea-shell/sea-ocr.sh eng; quickshell -c sea-shell ipc call shell unpin"]);
            root.hide();
            return;
        }
        if (kind === "copy") {
            Quickshell.execDetached(["sh", "-c",
                "sleep 0.25; g=\"$(slurp)\" && grim -g \"$g\" - | wl-copy --type image/png && notify-send 'sea-shell' 'Region copied to clipboard'; quickshell -c sea-shell ipc call shell unpin"]);
            root.hide();
            return;
        }
        var g = kind === "out"    ? "grim -o '" + arg + "'"
              : kind === "win"    ? "grim -g '" + root.winGeo + "'"
              : kind === "all"    ? "grim"
              :                     "grim -g \"$(slurp)\"";
        var cmd = g + " /tmp/sea-capture.png && quickshell -p ~/.config/quickshell/sea-shell/screenshot-editor.qml"
                + " || quickshell -c sea-shell ipc call shell unpin";
        Quickshell.execDetached(["sh","-c","sleep 0.3; " + cmd]);
        root.hide();
    }

    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    component Shot: Rectangle {
        id: sh
        property string icon: ""
        property string label: ""
        property string sub: ""
        property string hotkey: ""
        signal fire()
        width: 102; height: 86
        radius: Math.min(16, Tok.r + 4)
        color: shMa.containsMouse ? Tok.raised : root.cardFill
        border.width: 1
        border.color: shMa.containsMouse ? Tok.alpha(Tok.accent, 0.35) : root.cardEdge
        scale: shMa.pressed ? 0.96 : 1
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Column {
            anchors.centerIn: parent
            spacing: 3
            Sym { anchors.horizontalCenter: parent.horizontalCenter; text: sh.icon; sz: 26
                color: shMa.containsMouse ? Tok.accent : Tok.ink }
            IndText { anchors.horizontalCenter: parent.horizontalCenter; text: sh.label
                sz: Tok.tDense; font.weight: Font.DemiBold; topPadding: 2 }
            IndText { anchors.horizontalCenter: parent.horizontalCenter; text: sh.sub; visible: sh.sub !== ""
                width: sh.width - 12; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                sz: Tok.tLabel; color: Tok.ink3 }
        }
        Rectangle {
            anchors { top: parent.top; right: parent.right; margins: 6 }
            width: 18; height: 18; radius: 5
            color: Tok.sunken
            border.width: 1; border.color: root.cardEdge
            IndText { anchors.centerIn: parent; text: sh.hotkey; mono: true; sz: 10; color: Tok.ink3 }
        }
        MouseArea { id: shMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: sh.fire() }
    }

    PanelWindow {
        id: win
        readonly property real ui: Tok.uiFor(win.screen)
        readonly property bool live: root.shown
        anchors { top: true; left: true; bottom: true; right: true }
        visible: win.live
        implicitWidth: 1; implicitHeight: 1
        mask: win.live ? allInput : noInput
        Region { id: noInput }
        Region { id: allInput; item: win.contentItem }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:shot"
        WlrLayershell.layer: (win.live) ? WlrLayer.Overlay : WlrLayer.Bottom
        Connections {
            target: win.WlrLayershell
            function onLayerChanged() {
                if (!win.visible) return;
                win.visible = false;
                win.visible = Qt.binding(function() { return win.live; });
            }
        }
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

        Item {
            id: stage
            anchors.centerIn: parent
            width: win.width / win.ui; height: win.height / win.ui
            visible: root.shown
            property real shown: 0
            onVisibleChanged: if (visible) { shown = 0; rise.restart() }
            NumberAnimation { id: rise; target: stage; property: "shown"; from: 0; to: 1
                duration: Tok.reducedMotion ? 0 : 160; easing.type: Easing.OutCubic }

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.22)
                opacity: stage.shown
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }
            Item {
                anchors.fill: parent; focus: root.shown
                Keys.onPressed: (e)=> {
                    if (e.key === Qt.Key_Escape) { root.close(); return }
                    if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                        var i = e.key - Qt.Key_1, scr = Quickshell.screens;
                        if (i < scr.length) root.shoot("out", scr[i].name); return }
                    if (e.key === Qt.Key_R) { root.shoot("region"); return }
                    if (e.key === Qt.Key_C) { root.shoot("copy"); return }
                    if (e.key === Qt.Key_O) { root.shoot("ocr"); return }
                    if (e.key === Qt.Key_A) { root.shoot("all"); return }
                    if (e.key === Qt.Key_W && root.winGeo !== "") { root.shoot("win"); return }
                }
            }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 64 - (1 - stage.shown) * 12 }
                spacing: Tok.s2
                opacity: stage.shown

                // Compact recent captures strip (click to copy to clipboard)
                Rectangle {
                    visible: root.recentShots.length > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: recRow.implicitWidth + 20
                    height: 52
                    radius: Math.min(18, Tok.r + 6)
                    color: Tok.bg
                    border.width: 1; border.color: root.cardEdge
                    MouseArea { anchors.fill: parent }
                    Row {
                        id: recRow
                        anchors.centerIn: parent
                        spacing: Tok.s2
                        IndText { anchors.verticalCenter: parent.verticalCenter; text: "Recent"; sz: Tok.tLabel; color: Tok.ink3; font.weight: Font.Medium }
                        Repeater {
                            model: root.recentShots
                            delegate: Rectangle {
                                required property var modelData
                                width: 58; height: 34; radius: Tok.rSmall + 2
                                color: Tok.sunken; clip: true
                                border.width: 1
                                border.color: rMa.containsMouse ? Tok.accent : root.cardEdge
                                Image {
                                    anchors.fill: parent; anchors.margins: 1
                                    source: Tok.fileUrl(modelData.path)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true; cache: false
                                    sourceSize.width: 120
                                }
                                MouseArea {
                                    id: rMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Quickshell.execDetached(["sh", "-c", "wl-copy --type image/png < \"$1\" && notify-send 'sea-shell' 'Screenshot copied'", "sh", modelData.path]);
                                        root.close();
                                    }
                                }
                            }
                        }
                        Rectangle {
                            width: 30; height: 30; radius: 15
                            anchors.verticalCenter: parent.verticalCenter
                            color: fldMa.containsMouse ? Tok.raised : root.cardFill
                            border.width: 1; border.color: root.cardEdge
                            Sym { anchors.centerIn: parent; text: "folder_open"; sz: 16; color: fldMa.containsMouse ? Tok.accent : Tok.ink2 }
                            MouseArea {
                                id: fldMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { Quickshell.execDetached(["sh", "-c", "xdg-open \"$HOME/Pictures/Screenshots\""]); root.close() }
                            }
                        }
                    }
                }

                // Main capture dock
                Rectangle {
                    id: bar
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: row.width + 20
                    height: row.height + 20
                    radius: Tok.rCard + 2
                    color: Tok.bg
                    border.width: 1; border.color: Tok.alpha(Tok.ink, Tok.light ? 0.11 : 0.13)
                    MouseArea { anchors.fill: parent }
                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: 18; rightMargin: 18 }
                        height: 1; color: root.cardSheen
                    }

                    Row {
                        id: row
                        anchors.centerIn: parent
                        spacing: 6
                        Repeater {
                            model: Quickshell.screens
                            delegate: Shot {
                                required property var modelData
                                required property int index
                                icon: "desktop_windows"
                                label: Quickshell.screens.length > 1 ? "Screen " + (index + 1) : "Screen"
                                sub: modelData.name
                                hotkey: (index + 1) + ""
                                onFire: root.shoot("out", modelData.name)
                            }
                        }
                        Shot { visible: root.winGeo !== ""; icon: "select_window"; label: "Window"; sub: root.winTitle
                            hotkey: "W"; onFire: root.shoot("win") }
                        Shot { icon: "crop"; label: "Region"; sub: "Edit & save"; hotkey: "R"; onFire: root.shoot("region") }
                        Shot { icon: "content_copy"; label: "Quick copy"; sub: "To clipboard"; hotkey: "C"; onFire: root.shoot("copy") }
                        Shot { icon: "document_scanner"; label: "OCR text"; sub: "Copy text"; hotkey: "O"; onFire: root.shoot("ocr") }
                        Shot { visible: Quickshell.screens.length > 1; icon: "select_all"; label: "Everything"
                            sub: "All screens"; hotkey: "A"; onFire: root.shoot("all") }
                        Item { width: 9; height: 86
                            Rectangle { anchors.centerIn: parent; width: 1; height: 50; color: Tok.rule } }
                        Item {
                            width: 44; height: 86
                            Rectangle {
                                anchors.centerIn: parent
                                width: 36; height: 36; radius: 18
                                color: clMa.containsMouse ? Tok.raised : root.cardFill
                                border.width: 1; border.color: root.cardEdge
                                Sym { anchors.centerIn: parent; text: "close"; sz: 19; color: clMa.containsMouse ? Tok.ink : Tok.ink2 }
                                MouseArea { id: clMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                            }
                        }
                    }
                }
            }
        }
    }
}
