// Settings → KdeConnect. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 14
    visible: root.tab === 14; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "phonelink"
        badgeColor: "#30B0C7"
        title: "Phone Link (KDE Connect)"
        description: "Pair Android or iOS devices to share clipboard, files, notifications, media controls, and battery status."
    }

    Section { title: "KDE Connect"; icon: "phonelink" }
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Text { text: "KDE Connect"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans }
        Item { Layout.fillWidth: true }
        Sym { text: "sync"; sz: 16; color: theme.sub
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.reloadKde() } }
    }
    ColumnLayout {
        visible: root.kdeDevices.length === 0; Layout.fillWidth: true; spacing: 2
        Text { text: "No devices found"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }
        Text { text: "Open KDE Connect on the other device, on the same network, then refresh."
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
    }
    ColumnLayout {
        Layout.fillWidth: true; spacing: 8
        Repeater {
            model: root.kdeDevices
            delegate: Rectangle {
                id: kdeCard
                required property var modelData
                readonly property bool online: modelData.isPaired && modelData.isReachable
                Layout.fillWidth: true; radius: Tok.r
                implicitHeight: kdeCardCol.implicitHeight + 22
                color: online ? theme.a(theme.iris, 0.14) : theme.a(theme.line, 0.3)
                border.width: 1; border.color: online ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.12)
                ColumnLayout {
                    id: kdeCardCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 11; spacing: 9
                    // name + state
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Rectangle {
                            implicitWidth: 36; implicitHeight: 36; radius: Tok.r
                            color: kdeCard.online ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.5)
                            Sym { anchors.centerIn: parent; sz: 19
                                text: kdeCard.modelData.type === "phone" ? "smartphone"
                                    : (kdeCard.modelData.type === "tablet" ? "tablet_android"
                                    : (kdeCard.modelData.type === "tv" ? "tv" : "computer"))
                                color: kdeCard.online ? theme.iris : theme.faint }
                        }
                        ColumnLayout {
                            spacing: 2; Layout.fillWidth: true
                            Text { text: kdeCard.modelData.name; color: theme.text; font.pixelSize: 13; font.family: Tok.sans; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                            RowLayout {
                                spacing: 6
                                Text {
                                    text: !kdeCard.modelData.isPaired
                                            ? (kdeCard.modelData.isPairRequestedByPeer ? "wants to pair"
                                               : (kdeCard.modelData.isPairRequested ? "Waiting for a reply…" : "not paired"))
                                            : (kdeCard.modelData.isReachable
                                               ? ("online" + (kdeCard.modelData.network ? " · " + kdeCard.modelData.network : ""))
                                               : "away")
                                    color: kdeCard.online ? theme.frost : theme.faint; font.pixelSize: 11; font.family: Tok.sans
                                }
                                Text { visible: kdeCard.modelData.address !== ""
                                    text: "· " + kdeCard.modelData.address; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                                // cellular strength, 0–4 bars
                                Row {
                                    visible: kdeCard.modelData.signal >= 0
                                    spacing: 2; height: 11
                                    Repeater { model: 4
                                        delegate: Rectangle { required property int index
                                            width: 3; height: 4 + index * 2; radius: 1; anchors.bottom: parent.bottom
                                            color: index < kdeCard.modelData.signal ? theme.frost : theme.a(theme.faint, 0.35) } }
                                }
                            }
                        }
                        Sym { visible: kdeCard.modelData.isCharging; text: "bolt"; sz: 15; color: theme.good }
                    }
                    // battery — NOT the Meter component: that one goes red
                    // above 88%, which is right for RAM and backwards for a battery
                    RowLayout {
                        visible: kdeCard.modelData.charge >= 0
                        Layout.fillWidth: true; spacing: 11
                        Text { text: "Battery"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.preferredWidth: 58 }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 9; radius: Tok.r; color: theme.a(theme.line, 0.8)
                            Rectangle {
                                height: parent.height; radius: Tok.r
                                width: parent.width * Math.max(0, Math.min(1, kdeCard.modelData.charge / 100))
                                color: kdeCard.modelData.isCharging ? theme.good
                                     : (kdeCard.modelData.charge <= 20 ? theme.bad : theme.iris)
                                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                            }
                        }
                        Text {
                            text: kdeCard.modelData.charge + "%" + (kdeCard.modelData.isCharging ? " charging" : "")
                            color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                            Layout.preferredWidth: 96; horizontalAlignment: Text.AlignRight
                        }
                    }
                    // what you can actually do with it
                    Flow {
                        visible: kdeCard.online
                        Layout.fillWidth: true; spacing: 6
                        Chip { label: "Ring"; icon: "ring_volume"; enabled: kdeCard.modelData.canRing; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--ring", kdeCard.modelData.id]) }
                        Chip { label: "Ping"; icon: "wifi_tethering"; enabled: kdeCard.modelData.canPing; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--ping", kdeCard.modelData.id]) }
                        Chip { label: "send file"; icon: "upload_file"; enabled: kdeCard.modelData.canShare; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--send-file", kdeCard.modelData.id]) }
                        Chip { label: "Clipboard"; icon: "content_paste_go"; enabled: kdeCard.modelData.canShare; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--send-clipboard", kdeCard.modelData.id]) }
                        Chip { label: "Browse files"; icon: "folder_open"; enabled: kdeCard.modelData.canBrowse; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--browse", kdeCard.modelData.id]) }
                        Chip { label: "Messages"; icon: "sms"; enabled: kdeCard.modelData.canSms; opacity: enabled ? 1 : 0.4
                            onPicked: root.kdeAction(["--sms", kdeCard.modelData.id]) }
                    }
                    // pairing
                    Text {
                        visible: kdeCard.modelData.isPairRequestedByPeer || kdeCard.modelData.isPairRequested
                        text: "Verification key " + kdeCard.modelData.verificationKey + " — it must match the one on the device"
                        color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Chip { visible: kdeCard.modelData.isPairRequestedByPeer; label: "Accept"; icon: "check_circle"
                            onPicked: root.kdeAction(["--accept", kdeCard.modelData.id]) }
                        Chip { visible: kdeCard.modelData.isPairRequestedByPeer; label: "Reject"; icon: "cancel"
                            onPicked: root.kdeAction(["--reject", kdeCard.modelData.id]) }
                        Chip {
                            visible: !kdeCard.modelData.isPaired && kdeCard.modelData.isReachable
                                     && !kdeCard.modelData.isPairRequested && !kdeCard.modelData.isPairRequestedByPeer
                            label: "Pair"; icon: "link"
                            onPicked: root.kdeAction(["--pair", kdeCard.modelData.id]) }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: kdeCard.modelData.isPaired
                            text: "Unpair"; color: unpairMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.85)
                            font.pixelSize: 11; font.family: Tok.sans
                            MouseArea { id: unpairMa; anchors.fill: parent; anchors.margins: -7; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; onClicked: root.kdeAction(["--unpair", kdeCard.modelData.id]) }
                        }
                    }
                }
            }
        }
    }
    Text {
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: "The bar widget has the same shortcuts — click the phone pill for battery, ring, send file, clipboard and file browsing"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }
}
