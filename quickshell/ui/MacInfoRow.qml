import QtQuick
import QtQuick.Layouts

// Authentic macOS key-value detail row inside a grouped card.
Item {
    id: row
    property string label: ""
    property string value: ""
    property string subtitle: ""
    property string icon: ""
    property bool mono: false
    property color valueColor: Tok.ink2
    readonly property bool edgeToEdge: true
    Layout.fillWidth: true
    implicitHeight: subtitle !== "" ? Math.max(52, contentRow.implicitHeight + 18) : 42

    RowLayout {
        id: contentRow
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 16 }
        spacing: 12
        Sym {
            visible: row.icon !== ""
            text: row.icon; sz: 18; color: Tok.ink2
            Layout.alignment: Qt.AlignVCenter
        }
        ColumnLayout {
            spacing: 2; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
            Text {
                text: row.label
                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            Text {
                visible: row.subtitle !== ""
                text: row.subtitle
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                elide: Text.ElideRight; Layout.fillWidth: true
            }
        }
        Text {
            text: row.value
            color: row.valueColor
            font.pixelSize: row.mono ? 12 : 13
            font.family: row.mono ? Tok.mono : Tok.sans
            elide: Text.ElideRight
            Layout.maximumWidth: 320
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignRight
        }
    }
}
