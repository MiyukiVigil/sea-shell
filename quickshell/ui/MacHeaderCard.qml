import QtQuick
import QtQuick.Layouts

// Authentic macOS / Material You top-of-page Header Card aligned to the 16px horizontal grid.
Rectangle {
    id: hdr
    property string icon: "settings"
    property color badgeColor: Tok.accent
    property string title: ""
    property string description: ""
    property string note: ""

    Layout.fillWidth: true
    implicitHeight: hdrRow.implicitHeight + 28
    radius: 11
    color: root.cardFill
    border.width: 1
    border.color: root.cardBorder

    RowLayout {
        id: hdrRow
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 16 }
        spacing: 14

        MacIconBadge {
            icon: hdr.icon
            badgeColor: hdr.badgeColor
            size: 46
            iconSize: 25
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 3
            Text {
                text: hdr.title
                color: Tok.ink; font.pixelSize: 17; font.family: Tok.sans; font.weight: 700
                Layout.fillWidth: true; elide: Text.ElideRight
            }
            Text {
                visible: hdr.description !== ""
                text: hdr.description
                color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                lineHeight: 1.3
            }
            Text {
                visible: hdr.note !== ""
                text: hdr.note
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                Layout.topMargin: 2
            }
        }
    }
}
