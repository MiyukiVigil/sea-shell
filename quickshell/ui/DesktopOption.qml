// One row of a desktop widget's options (DesktopItem's gear panel): a label and a pill per choice.
// Its own file rather than an inline component: Quickshell's live reload does not pick up a
// NEW inline component, and the whole desktop failed to load until a restart.
import QtQuick

Row {
    id: optRow
    property Item item                  // the DesktopItem whose option this is
    property string label: ""
    property var choices: []          // [{ v, l }]
    property string current: ""
    property string key: ""
    spacing: 4
    Text { width: 54; text: optRow.label; color: Tok.ink2; font.family: Tok.sans; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
    Repeater {
        model: optRow.choices
        delegate: Rectangle {
            required property var modelData
            readonly property bool on: optRow.current === modelData.v
            implicitWidth: optT.implicitWidth + 16; implicitHeight: 26; radius: 13
            color: on ? Tok.accent : (optMa.containsMouse ? Tok.accentWash : Tok.sunken)
            Text { id: optT; anchors.centerIn: parent; text: modelData.l; color: parent.on ? Tok.accentInk : Tok.ink; font.family: Tok.sans; font.pixelSize: 11 }
            MouseArea { id: optMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: optRow.item.setOpt(optRow.key, modelData.v) }
        }
    }
}
