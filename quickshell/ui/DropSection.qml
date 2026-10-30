import QtQuick

// A label over a group of rows in a bar dropdown ("Devices", "Output", "Power profile"), with
// an optional count or note on the right. A rule above it when it starts a new part of the card.
Column {
    id: s
    property string text: ""
    property string note: ""
    property bool rule: false
    width: parent ? parent.width : 280
    spacing: 0
    Item { width: 1; height: s.rule ? 6 : 2 }
    Rectangle { visible: s.rule; width: parent.width; height: 1; color: Tok.rule }
    Item { width: 1; height: s.rule ? 8 : 0 }
    Item {
        width: parent.width; height: 20
        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: s.text; color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 11; font.weight: Font.DemiBold; font.letterSpacing: 0.3 }
        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            visible: s.note !== ""; text: s.note; color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 11 }
    }
}
