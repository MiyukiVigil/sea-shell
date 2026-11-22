import QtQuick
import QtQuick.Layouts

// Authentic macOS setting row with pill switch: optional icon, title, subtitle, toggle.
Rectangle {
    id: tc
    property string icon: ""
    property string title: ""
    property string desc: ""
    property bool on: false
    readonly property bool edgeToEdge: true
    signal toggled()
    Layout.fillWidth: true
    implicitHeight: Math.max(desc !== "" ? 54 : 44, tcRow.implicitHeight + 18)
    radius: 8
    color: tcMa.containsMouse ? root.rowHover : "transparent"
    Behavior on color { ColorAnimation { duration: Tok.mMicro } }

    RowLayout {
        id: tcRow
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 16 }
        spacing: 12
        Sym {
            visible: tc.icon !== ""
            text: tc.icon; sz: 19
            filled: tc.on
            color: tc.on ? Tok.accent : Tok.ink2
            Layout.alignment: Qt.AlignVCenter
        }
        ColumnLayout {
            spacing: 2; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
            Text {
                visible: tc.title !== ""
                text: tc.title; color: Tok.ink
                font.pixelSize: 13; font.family: Tok.sans
                Layout.fillWidth: true; elide: Text.ElideRight
            }
            Text {
                visible: tc.desc !== ""
                text: tc.desc; color: Tok.ink3
                font.pixelSize: 11; font.family: Tok.sans
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                lineHeight: 1.25
            }
        }
        Toggle {
            on: tc.on
            onToggled: tc.toggled()
            Layout.alignment: Qt.AlignVCenter
        }
    }
    MouseArea {
        id: tcMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tc.toggled()
    }
}
