// sea-shell — Screen Ruler & Pixel Measurer (Super+Alt+R).
// Drag anywhere to measure W x H px, aspect ratio, diagonal px, and coordinates.
// Press C to copy "WxH", Esc or right-click to close.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

Scope {
    id: root
    property bool shown: false
    property var uiFor: function (scr) { return 1 }
    signal closed()

    property var openOn: null
    property real x1: 0
    property real y1: 0
    property real x2: 0
    property real y2: 0
    property bool hasBox: false
    property bool dragging: false
    property real curX: 0
    property real curY: 0

    readonly property int boxX: Math.round(Math.min(x1, x2))
    readonly property int boxY: Math.round(Math.min(y1, y2))
    readonly property int boxW: Math.round(Math.abs(x2 - x1))
    readonly property int boxH: Math.round(Math.abs(y2 - y1))
    readonly property int diag: Math.round(Math.sqrt(boxW * boxW + boxH * boxH))
    readonly property string aspect: {
        if (boxW <= 0 || boxH <= 0) return "";
        function gcd(a, b) { return b === 0 ? a : gcd(b, a % b); }
        var g = gcd(boxW, boxH);
        var rw = Math.round(boxW / g), rh = Math.round(boxH / g);
        if (rw <= 32 && rh <= 32) return rw + ":" + rh;
        return (boxW / boxH).toFixed(2) + ":1";
    }

    function open() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        root.hasBox = false;
        root.dragging = false;
        root.shown = true;
    }
    function close() { if (!root.shown) return; root.shown = false; root.closed(); }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    Variants {
        model: (root.shown && root.openOn) ? [root.openOn] : []
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:ruler"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            FocusScope {
                anchors.fill: parent; focus: true
                Keys.onEscapePressed: root.close()
                Keys.onPressed: (e) => {
                    if (e.key === Qt.Key_C && root.hasBox && root.boxW > 0) {
                        var s = root.boxW + "x" + root.boxH;
                        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy && notify-send 'sea-shell Ruler' 'Copied " + s + "'", "sh", s]);
                        root.close();
                        e.accepted = true;
                    }
                }
            }

            // Subtle crosshairs following pointer
            Rectangle { x: Math.round(root.curX); y: 0; width: 1; height: parent.height; color: Tok.alpha(Tok.accent, 0.35) }
            Rectangle { x: 0; y: Math.round(root.curY); width: parent.width; height: 1; color: Tok.alpha(Tok.accent, 0.35) }

            // Measured selection box
            Rectangle {
                visible: root.hasBox && (root.boxW > 1 || root.boxH > 1)
                x: root.boxX; y: root.boxY; width: root.boxW; height: root.boxH
                color: Tok.alpha(Tok.accent, 0.14)
                border.width: 2; border.color: Tok.accent
            }

            // Live dimension readout pill
            Rectangle {
                visible: root.hasBox && (root.boxW > 1 || root.boxH > 1)
                x: Math.max(12, Math.min(parent.width - width - 12, root.boxX + (root.boxW - width) / 2))
                y: root.boxY > 44 ? root.boxY - height - 10 : root.boxY + root.boxH + 10
                width: readTxt.implicitWidth + 22; height: 30; radius: Tok.r
                color: Tok.bg; border.width: 1; border.color: Tok.accent
                Text {
                    id: readTxt; anchors.centerIn: parent
                    text: root.boxW + " × " + root.boxH + " px" + (root.aspect ? "  ·  " + root.aspect : "") + "  ·  diag " + root.diag + " px"
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; font.weight: Font.DemiBold
                }
            }

            // Bottom hint bar
            Rectangle {
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 24 }
                width: hintTxt.implicitWidth + 24; height: 30; radius: Tok.r
                color: Tok.bg; border.width: 1; border.color: Tok.ruleHard
                Text {
                    id: hintTxt; anchors.centerIn: parent
                    text: "Drag to measure (" + Math.round(root.curX) + ", " + Math.round(root.curY) + ") · C copy WxH · Right-click or Esc close"
                    color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.CrossCursor
                onPressed: (m) => {
                    if (m.button === Qt.RightButton) { root.close(); return; }
                    root.x1 = m.x; root.y1 = m.y; root.x2 = m.x; root.y2 = m.y;
                    root.dragging = true; root.hasBox = true;
                }
                onPositionChanged: (m) => {
                    root.curX = m.x; root.curY = m.y;
                    if (root.dragging) { root.x2 = m.x; root.y2 = m.y; }
                }
                onReleased: root.dragging = false
            }
        }
    }
}
