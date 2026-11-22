import QtQuick
import QtQuick.Layouts

// Authentic macOS slim slider (0..1)
Item {
    id: sl
    property real value: 0
    property color fill: Tok.accent
    signal moved(real v)
    implicitHeight: 22
    Layout.fillWidth: true
    function clamp(v) { return Math.max(0, Math.min(1, v)) }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width; height: 4; radius: 2
        color: Tok.light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.14)
        Rectangle {
            width: Math.max(4, track.width * sl.clamp(sl.value))
            height: parent.height; radius: 2
            color: sl.fill
        }
    }

    Rectangle {
        id: thumb
        width: 16; height: 16; radius: 8
        scale: slMa.pressed ? 1.08 : 1.0
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        color: "#ffffff"
        border.width: 1
        border.color: slMa.pressed ? sl.fill : Qt.rgba(0, 0, 0, Tok.light ? 0.18 : 0.35)
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(sl.width - width, (sl.width - width) * sl.clamp(sl.value)))
    }

    MouseArea {
        id: slMa
        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
        onPressed: (e) => { var v = sl.clamp(e.x / Math.max(1, sl.width)); sl.value = v; sl.moved(v) }
        onPositionChanged: (e) => { if (pressed) { var v = sl.clamp(e.x / Math.max(1, sl.width)); sl.value = v; sl.moved(v) } }
    }
}
