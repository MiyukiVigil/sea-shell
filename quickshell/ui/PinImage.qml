//@ pragma UseQApplication
// sea-shell — Pin-to-screen floating reference image (launched from screenshot-editor.qml).
// Drag to move (Hyprland window / layer offset), scroll to zoom, Shift+scroll for opacity,
// C to copy, Esc or right-click to close.
import Quickshell
import Quickshell.Wayland
import QtQuick

ShellRoot {
    id: root
    readonly property string imgPath: Quickshell.env("SEA_PIN_IMAGE") || "/tmp/sea-shot-pin.png"
    property real zoom: 1.0
    property real cardOpacity: 1.0
    property int imgW: 400
    property int imgH: 260
    property int offX: 80
    property int offY: 80

    PanelWindow {
        id: win
        anchors { top: true; left: true }
        margins { left: root.offX; top: root.offY }
        implicitWidth: Math.max(120, Math.round(root.imgW * root.zoom) + 8)
        implicitHeight: Math.max(80, Math.round(root.imgH * root.zoom) + 8)
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:pin"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            id: frame
            anchors.fill: parent
            radius: Tok.r
            color: Tok.bg
            opacity: root.cardOpacity
            border.width: 2
            border.color: ma.containsMouse ? Tok.accent : Tok.ruleHard
            clip: true

            FocusScope {
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: Qt.quit()
                Keys.onPressed: (e) => {
                    if (e.key === Qt.Key_C) {
                        Quickshell.execDetached(["sh", "-c", "wl-copy --type image/png < \"$1\"", "sh", root.imgPath]);
                        e.accepted = true;
                    } else if (e.key === Qt.Key_Plus || e.key === Qt.Key_Equal) {
                        root.zoom = Math.min(3.0, root.zoom + 0.15); e.accepted = true;
                    } else if (e.key === Qt.Key_Minus) {
                        root.zoom = Math.max(0.25, root.zoom - 0.15); e.accepted = true;
                    } else if (e.key === Qt.Key_0) {
                        root.zoom = 1.0; root.cardOpacity = 1.0; e.accepted = true;
                    }
                }
            }

            Image {
                id: pic
                anchors.fill: parent
                anchors.margins: 4
                source: Tok.fileUrl(root.imgPath)
                fillMode: Image.PreserveAspectFit
                smooth: true; mipmap: true; cache: false
                onStatusChanged: if (status === Image.Ready) {
                    root.imgW = Math.min(960, implicitWidth);
                    root.imgH = Math.round(root.imgW * (implicitHeight / Math.max(1, implicitWidth)));
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point startPt: Qt.point(0, 0)
                onPressed: (m) => {
                    if (m.button === Qt.RightButton) { Qt.quit(); return; }
                    startPt = Qt.point(m.x, m.y);
                }
                onPositionChanged: (m) => {
                    if (!(m.buttons & Qt.LeftButton)) return;
                    root.offX = Math.max(0, root.offX + Math.round(m.x - startPt.x));
                    root.offY = Math.max(0, root.offY + Math.round(m.y - startPt.y));
                }
                onWheel: (w) => {
                    var step = w.angleDelta.y > 0 ? 0.1 : -0.1;
                    if (w.modifiers & Qt.ShiftModifier) {
                        root.cardOpacity = Math.max(0.25, Math.min(1.0, root.cardOpacity + step));
                    } else {
                        root.zoom = Math.max(0.25, Math.min(3.0, root.zoom + step));
                    }
                }
            }

            // Hover toolbar: Copy + Close
            Row {
                visible: ma.containsMouse || closeMa.containsMouse || copyMa.containsMouse
                anchors { top: parent.top; right: parent.right; margins: 8 }
                spacing: 4
                Rectangle {
                    width: 24; height: 24; radius: Tok.rSmall
                    color: copyMa.containsMouse ? Tok.accent : Tok.alpha(Tok.bg, 0.82)
                    border.width: 1; border.color: Tok.rule
                    Sym { anchors.centerIn: parent; text: "content_copy"; sz: 13; color: copyMa.containsMouse ? Tok.accentInk : Tok.ink }
                    MouseArea {
                        id: copyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["sh", "-c", "wl-copy --type image/png < \"$1\" && notify-send 'sea-shell' 'Pinned image copied'", "sh", root.imgPath])
                    }
                }
                Rectangle {
                    width: 24; height: 24; radius: Tok.rSmall
                    color: closeMa.containsMouse ? Tok.crit : Tok.alpha(Tok.bg, 0.82)
                    border.width: 1; border.color: Tok.rule
                    Sym { anchors.centerIn: parent; text: "close"; sz: 14; color: closeMa.containsMouse ? "#ffffff" : Tok.ink }
                    MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Qt.quit() }
                }
            }
        }
    }
}
