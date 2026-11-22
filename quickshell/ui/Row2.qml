import QtQuick
import QtQuick.Layouts

// Clean macOS action row inside a settings card.
RowLayout {
    id: r2
    property string icon: ""
    property string label: ""
    property string cmd: ""
    property bool quitAfter: false
    property color tint: Tok.accent
    Layout.fillWidth: true

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 38
        radius: 8
        color: rma.containsMouse ? root.rowHover : "transparent"
        Behavior on color { ColorAnimation { duration: Tok.mMicro } }

        RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 10
            Sym { text: r2.icon; sz: 17; color: r2.tint }
            Text {
                text: r2.label
                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            Sym { text: "chevron_right"; sz: 16; color: Tok.ink3 }
        }
        MouseArea {
            id: rma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.run(r2.cmd);
                if (r2.quitAfter) root.closePanel();
            }
        }
    }
}
