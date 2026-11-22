import QtQuick
import QtQuick.Layouts

// Authentic macOS slider row: icon (optional) · label · slim slider · tabular readout.
Item {
    id: sr
    property string icon: ""
    property string label: ""
    property real value: 0
    property string readout: ""
    property color tint: Tok.accent
    readonly property bool edgeToEdge: true
    signal moved(real v)

    Layout.fillWidth: true
    implicitHeight: 44

    RowLayout {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 16 }
        spacing: 12

        Sym {
            visible: sr.icon !== ""
            text: sr.icon; sz: 18; color: Tok.ink2
            Layout.alignment: Qt.AlignVCenter
        }
        Text {
            text: sr.label; color: Tok.ink
            font.pixelSize: 13; font.family: Tok.sans
            Layout.minimumWidth: 112
            Layout.alignment: Qt.AlignVCenter
        }
        Slider {
            fill: sr.tint
            value: sr.value
            onMoved: (v) => sr.moved(v)
            Layout.alignment: Qt.AlignVCenter
        }
        Text {
            text: sr.readout; color: Tok.ink2
            font.pixelSize: 12; font.family: Tok.mono
            Layout.minimumWidth: 54
            horizontalAlignment: Text.AlignRight
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
