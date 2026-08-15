// Text input. Placeholder describes the FORMAT, not an instruction. Numeric/secret content is
// mono. Focus is a real accent ring, never a removed outline.
import QtQuick

Rectangle {
    id: f
    property alias text: input.text
    property string placeholder: ""
    property bool secret: false
    property bool mono: false
    property alias input: input
    signal accepted(string value)

    implicitHeight: 32
    radius: Tok.r
    color: Tok.raised
    border.width: 1
    border.color: input.activeFocus ? Tok.accent : Tok.ruleHard

    // the accent ring: a 2px halo drawn outside the border, matching the focus-visible rule
    Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: Tok.r + 1
        color: "transparent"
        border.width: 2
        border.color: Tok.accentWash
        visible: input.activeFocus
        z: -1
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        selectByMouse: true
        color: Tok.ink
        selectionColor: Tok.accent
        selectedTextColor: Tok.accentInk
        font.family: (f.mono || f.secret) ? Tok.mono : Tok.sans
        font.pixelSize: Tok.tDense
        font.features: (f.mono || f.secret) ? ({ "tnum": 1 }) : ({})
        echoMode: f.secret ? TextInput.Password : TextInput.Normal
        onAccepted: f.accepted(text)

        IndText {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === ""
            text: f.placeholder
            sz: Tok.tDense
            mono: f.mono || f.secret
            color: Tok.ink3
        }
    }
}
