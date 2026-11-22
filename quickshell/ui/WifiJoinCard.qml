import QtQuick
import QtQuick.Layouts

// The password ask under a Wi-Fi network in the bar's dropdown. Self-contained (colours come
// in as properties) so the dropdown, and the test, can host it without the shell's theme.
// Drawn in settings' language: a quiet filled field, then two pill buttons, the default filled.
Rectangle {
    id: card
    property string ssid: ""
    property string draft: ""
    // 802.1X networks (eduroam, campus Wi-Fi) sign in with an account, so they also ask for a username.
    property bool enterprise: false
    property string identityDraft: ""
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
    signal identityEdited(string value)
    signal submitted(string value)
    signal cancelled()
    readonly property bool ready: !busy && password.text.length > 0 && (!enterprise || identity.text.length > 0)
    implicitHeight: body.implicitHeight + 28
    radius: rounding + 4; color: surface
    border.width: 1; border.color: Qt.alpha(ink, 0.075)
    function focusPassword() {
        if (enterprise && !identity.text.length) identity.forceActiveFocus()
        else password.forceActiveFocus()
    }
    function submit() { if (ready) submitted(password.text) }
    onSsidChanged: { reveal.on = false; if (visible && ssid.length) Qt.callLater(focusPassword) }
    onVisibleChanged: if (visible && ssid.length) Qt.callLater(focusPassword)
    onEnterpriseChanged: if (visible && ssid.length) Qt.callLater(focusPassword)
    ColumnLayout {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
        spacing: 10
        RowLayout {
            Layout.fillWidth: true; spacing: 10
            Rectangle {
                implicitWidth: 30; implicitHeight: 30; radius: 15
                color: card.failed ? Qt.alpha(card.danger, 0.14) : Qt.alpha(card.accent, 0.14)
                Text { anchors.centerIn: parent; text: card.failed ? "wifi_lock" : "lock"
                    font.family: "Material Symbols Outlined"; font.pixelSize: 16
                    color: card.failed ? card.danger : card.accent }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 1
                Text { text: card.ssid; color: card.ink; font.family: card.fontFamily
                    font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { text: card.enterprise ? "Sign in with your account" : "Enter the network password"
                    color: card.muted; font.family: card.fontFamily
                    font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 36; radius: 10; visible: card.enterprise
            color: Qt.alpha(card.ink, 0.05)
            border.width: identity.activeFocus ? 2 : 1
            border.color: card.failed && !identity.text.length ? card.danger
                : identity.activeFocus ? card.accent : Qt.alpha(card.ink, 0.075)
            Behavior on border.color { ColorAnimation { duration: 120 } }
            TextInput {
                id: identity; objectName: "wifiIdentity"
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                text: card.identityDraft; onTextEdited: card.identityEdited(text)
                color: card.ink; selectionColor: card.accent; selectedTextColor: card.accentInk
                font.family: card.fontFamily; font.pixelSize: 13
                verticalAlignment: TextInput.AlignVCenter; clip: true
                enabled: !card.busy
                KeyNavigation.tab: password
                onAccepted: if (card.ready) card.submit(); else password.forceActiveFocus()
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !identity.text.length
                    text: "Username (e.g. you@university.edu)"; font: identity.font; color: card.muted
                    width: parent.width; elide: Text.ElideRight }
            }
        }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 36; radius: 10
            color: Qt.alpha(card.ink, 0.05)
            border.width: password.activeFocus ? 2 : 1
            border.color: card.failed && !password.text.length ? card.danger
                : password.activeFocus ? card.accent : Qt.alpha(card.ink, 0.075)
            Behavior on border.color { ColorAnimation { duration: 120 } }
            TextInput {
                id: password; objectName: "wifiPassword"
                anchors { left: parent.left; right: reveal.left; top: parent.top; bottom: parent.bottom; leftMargin: 12; rightMargin: 8 }
                text: card.draft; onTextEdited: card.edited(text)
                echoMode: reveal.on ? TextInput.Normal : TextInput.Password
                passwordCharacter: "•"
                color: card.ink; selectionColor: card.accent; selectedTextColor: card.accentInk
                font.family: card.fontFamily; font.pixelSize: 13
                verticalAlignment: TextInput.AlignVCenter; clip: true
                enabled: !card.busy
                onAccepted: if (card.ready) card.submit(); else if (card.enterprise) identity.forceActiveFocus()
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !password.text.length
                    text: "Password"; font: password.font; color: card.muted }
            }
            Text {
                id: reveal; property bool on: false
                anchors { right: parent.right; rightMargin: 11; verticalCenter: parent.verticalCenter }
                text: on ? "visibility_off" : "visibility"
                font.family: "Material Symbols Outlined"; font.pixelSize: 17
                color: revealMa.containsMouse ? card.ink : card.muted
                MouseArea { id: revealMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: reveal.on = !reveal.on }
            }
        }
        Text { Layout.fillWidth: true; visible: card.message.length > 0
            text: card.message; wrapMode: Text.WordWrap; color: card.failed ? card.danger : card.muted
            font.family: card.fontFamily; font.pixelSize: 11 }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: cancelT.implicitWidth + 28; implicitHeight: 30; radius: 15
                color: cancelMa.containsMouse ? Qt.alpha(card.ink, 0.09) : Qt.alpha(card.ink, 0.05)
                opacity: card.busy ? 0.5 : 1
                Text { id: cancelT; anchors.centerIn: parent; text: "Cancel"; color: card.ink
                    font.family: card.fontFamily; font.pixelSize: 12; font.weight: Font.Medium }
                MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; enabled: !card.busy
                    cursorShape: Qt.PointingHandCursor; onClicked: card.cancelled() }
            }
            Rectangle {
                implicitWidth: Math.max(92, joinT.implicitWidth + 28); implicitHeight: 30; radius: 15
                readonly property bool ready: card.ready
                color: ready ? (joinMa.containsMouse ? Qt.lighter(card.accent, 1.08) : card.accent) : Qt.alpha(card.ink, 0.05)
                Behavior on color { ColorAnimation { duration: 120 } }
                Text { id: joinT; anchors.centerIn: parent; text: card.busy ? "Connecting…" : "Join"
                    color: parent.ready ? card.accentInk : card.muted
                    font.family: card.fontFamily; font.pixelSize: 12; font.weight: Font.DemiBold }
                MouseArea { id: joinMa; anchors.fill: parent; hoverEnabled: true; enabled: parent.ready
                    cursorShape: Qt.PointingHandCursor; onClicked: card.submit() }
            }
        }
    }
}
