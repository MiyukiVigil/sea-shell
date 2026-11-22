import QtQuick
import QtQuick.Layouts

// Refined macOS selectable option pill.
Rectangle {
    id: ch
    scale: chMa.pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
    property string label: ""
    property string icon: ""
    property string labelFont: Tok.sans
    property bool on: false
    signal picked()

    implicitWidth: chRow.implicitWidth + 22
    implicitHeight: 28
    radius: 7
    color: on ? Tok.accent
         : (chMa.containsMouse
            ? (Tok.light ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(1, 1, 1, 0.12))
            : (Tok.light ? Qt.rgba(0, 0, 0, 0.045) : Qt.rgba(1, 1, 1, 0.06)))
    border.width: 1
    border.color: on ? Qt.rgba(0, 0, 0, 0.08) : root.cardBorder
    Behavior on color { ColorAnimation { duration: Tok.mMicro } }

    Row {
        id: chRow
        anchors.centerIn: parent
        spacing: 5
        Sym {
            visible: ch.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: ch.icon; sz: 14
            color: ch.on ? Tok.accentInk : Tok.ink2
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Tok.cap(ch.label)
            color: ch.on ? Tok.accentInk : Tok.ink
            font.pixelSize: 12; font.family: ch.labelFont
            font.weight: ch.on ? 600 : 400
        }
    }
    MouseArea {
        id: chMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ch.picked()
    }
}
