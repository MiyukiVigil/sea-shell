import QtQuick

// The top of a bar dropdown, as the Wi-Fi one has it: a title, one status line that says what
// is happening right now (coloured only when it means something), and on the right either an
// on/off switch, a value, or a small action. Bluetooth, sound, battery and calendar share it,
// so they read as one family instead of four people's ideas of a header.
Column {
    id: h
    property string title: ""
    property string status: ""
    property string tone: "neutral"           // neutral | ok | warn | crit | accent
    property string value: ""                 // a reading on the right, e.g. "45%"
    property string actionIcon: ""            // a small button on the right, e.g. "refresh"
    property bool actionBusy: false           // the action is running: the icon turns
    property bool hasSwitch: false
    property bool switchOn: false
    signal action()
    signal switched(bool on)

    width: parent ? parent.width : 280
    spacing: 3

    Item {
        width: parent.width; height: 28
        Text {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: h.title; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 16; font.bold: true
        }
        Row {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
                visible: h.value !== ""; anchors.verticalCenter: parent.verticalCenter
                text: h.value; color: Tok.ink2; font.family: Tok.mono; font.pixelSize: 12; font.features: { "tnum": 1 }
            }
            Rectangle {
                visible: h.actionIcon !== ""; anchors.verticalCenter: parent.verticalCenter
                width: 26; height: 26; radius: Tok.r
                color: am.containsMouse ? Tok.accentWash : "transparent"
                Text {
                    id: ai; anchors.centerIn: parent; text: h.actionIcon
                    font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: am.containsMouse ? Tok.ink : Tok.ink2
                    RotationAnimation on rotation { running: h.actionBusy; from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                        onRunningChanged: if (!running) ai.rotation = 0 }
                }
                MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: h.action() }
            }
            IndToggle {
                visible: h.hasSwitch; anchors.verticalCenter: parent.verticalCenter
                on: h.switchOn
                onToggled: v => h.switched(v)
            }
        }
    }
    Text {
        visible: h.status !== ""
        width: parent.width; elide: Text.ElideRight
        text: h.status
        color: h.tone === "ok" ? Tok.ok : h.tone === "warn" ? Tok.warn : h.tone === "crit" ? Tok.crit : h.tone === "accent" ? Tok.accent : Tok.ink2
        font.family: Tok.sans; font.pixelSize: 12
    }
    Item { width: 1; height: 6 }
    Rectangle { width: parent.width; height: 1; color: Tok.rule }
    Item { width: 1; height: 2 }
}
