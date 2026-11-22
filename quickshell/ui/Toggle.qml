import QtQuick
import QtQuick.Layouts

// Authentic macOS pill switch — bind `on`, handle `toggled`.
Rectangle {
    id: tg
    property bool on: false
    property bool enabled: true
    signal toggled()
    implicitWidth: 38; implicitHeight: 22; radius: 11
    opacity: enabled ? 1.0 : 0.45
    color: on ? Tok.accent : (Tok.light ? Qt.rgba(0, 0, 0, 0.16) : Qt.rgba(1, 1, 1, 0.16))
    border.width: 1
    border.color: on ? Qt.rgba(0, 0, 0, 0.08) : (Tok.light ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(1, 1, 1, 0.10))
    Behavior on color { ColorAnimation { duration: Tok.mFast } }

    Rectangle {
        id: knob
        readonly property real kw: tgMa.pressed ? 21 : 18
        width: kw; height: 18; radius: 9
        y: 2
        x: tg.on ? tg.width - width - 2 : 2
        color: "#ffffff"
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, Tok.light ? 0.12 : 0.28)
        Behavior on x { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
    }
    MouseArea {
        id: tgMa
        anchors.fill: parent
        enabled: tg.enabled
        cursorShape: tg.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: tg.toggled()
    }
}
