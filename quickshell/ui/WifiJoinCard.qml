import QtQuick
import QtQuick.Layouts

Rectangle {
    id: card
    property string ssid: ""
    property string draft: ""
    property string message: ""
    property bool failed: false
    property bool busy: false
    property color surface: "#eef0f8"
    property color ink: "#202330"
    property color muted: "#626779"
    property color accent: "#535a92"
    property color accentInk: "white"
    property color danger: "#ae3542"
    property string fontFamily: "sans-serif"
    property real rounding: 12
    signal edited(string value)
    signal submitted(string value)
    signal cancelled()
    implicitHeight: body.implicitHeight + 24
    radius: rounding; color: surface
    border.width: 1; border.color: Qt.alpha(accent, 0.3)
    function focusPassword() { password.forceActiveFocus() }
    onSsidChanged: { reveal.on = false; if (visible && ssid.length) Qt.callLater(focusPassword) }
    onVisibleChanged: if (visible && ssid.length) Qt.callLater(focusPassword)
    ColumnLayout {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 9
        Text { text: "Connect to " + card.ssid; color: card.ink; font.family: card.fontFamily
            font.pixelSize: 13; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 38; radius: 7
            color: Qt.alpha(card.accent, 0.06)
            border.width: password.activeFocus ? 2 : 1
            border.color: password.activeFocus ? card.accent : Qt.alpha(card.accent, 0.25)
            TextInput {
                id: password; objectName: "wifiPassword"
                anchors { left: parent.left; right: reveal.left; top: parent.top; bottom: parent.bottom; margins: 9 }
                text: card.draft; onTextEdited: card.edited(text)
                echoMode: reveal.on ? TextInput.Normal : TextInput.Password
                color: card.ink; selectionColor: card.accent; selectedTextColor: card.accentInk
                font.family: card.fontFamily; font.pixelSize: 13
                verticalAlignment: TextInput.AlignVCenter; clip: true
                enabled: !card.busy
                onAccepted: if (!card.busy && text.length) card.submitted(text)
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !password.text.length
                    text: "Password"; font: password.font; color: card.muted }
            }
            Text {
                id: reveal; property bool on: false
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                text: on ? "Hide" : "Show"; color: card.accent; font.pixelSize: 11; font.family: card.fontFamily
                MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: reveal.on = !reveal.on }
            }
        }
        Text { Layout.fillWidth: true; visible: card.message.length > 0
            text: card.message; wrapMode: Text.WordWrap; color: card.failed ? card.danger : card.muted
            font.family: card.fontFamily; font.pixelSize: 11 }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            Text { text: "Cancel"; color: card.muted; font.family: card.fontFamily; font.pixelSize: 12
                MouseArea { anchors.fill: parent; anchors.margins: -6; enabled: !card.busy
                    cursorShape: Qt.PointingHandCursor; onClicked: card.cancelled() } }
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: 102; implicitHeight: 32; radius: 8
                color: card.accent; opacity: card.busy || !password.text.length ? 0.55 : 1
                Text { anchors.centerIn: parent; text: card.busy ? "Connecting…" : "Connect"
                    color: card.accentInk; font.family: card.fontFamily; font.pixelSize: 12; font.bold: true }
                MouseArea { anchors.fill: parent; enabled: !card.busy && password.text.length > 0
                    cursorShape: Qt.PointingHandCursor; onClicked: card.submitted(password.text) }
            }
        }
    }
}
