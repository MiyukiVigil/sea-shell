import QtQuick
import QtQuick.Layouts

// Authentic macOS push button (primary accent fill).
Rectangle {
    id: ab
    scale: abMa.pressed ? 0.98 : 1
    Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
    property string label: ""
    property string icon: ""
    property bool enabled: true
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: 34
    radius: 7
    opacity: ab.enabled ? 1 : 0.45
    color: abMa.containsMouse && ab.enabled ? Qt.lighter(Tok.accent, Tok.light ? 1.08 : 1.06) : Tok.accent
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.12)
    Behavior on color { ColorAnimation { duration: Tok.mMicro } }

    RowLayout {
        anchors.centerIn: parent
        spacing: 7
        Sym {
            visible: ab.icon !== ""
            text: ab.icon; sz: 15
            color: Tok.accentInk
        }
        Text {
            text: ab.label
            color: Tok.accentInk
            font.pixelSize: 12; font.family: Tok.sans; font.weight: 600
        }
    }
    MouseArea {
        id: abMa
        anchors.fill: parent
        hoverEnabled: true
        enabled: ab.enabled
        cursorShape: ab.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: ab.clicked()
    }
}
