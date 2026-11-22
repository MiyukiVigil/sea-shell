// Settings → Network (Wi-Fi, Wired Ethernet, DNS & Hostname). VPN section loads right below.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 2
    visible: root.tab === 2
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "wifi"
        badgeColor: "#007AFF"
        title: "Network"
        description: "Manage Wi-Fi networks, wired Ethernet interfaces, DNS servers, and VPN connections."
    }

    // ---- Wired / Ethernet ----
    Section { visible: (root.netExtra.wired || []).length > 0; title: "Ethernet"; icon: "settings_ethernet" }
    MacList {
        visible: (root.netExtra.wired || []).length > 0
        Repeater {
            model: root.netExtra.wired || []
            delegate: ColumnLayout {
                id: ethItem
                required property var modelData
                required property int index
                Layout.fillWidth: true; spacing: 0
                MacDivider { visible: ethItem.index > 0 }
                MacInfoRow {
                    icon: "settings_ethernet"
                    label: ethItem.modelData.connection || ethItem.modelData.device
                    subtitle: ethItem.modelData.state === "connected"
                        ? ([ethItem.modelData.ip, ethItem.modelData.speed].filter(function(x) { return x }).join("  ·  "))
                        : ("Device: " + ethItem.modelData.device)
                    value: Tok.cap(ethItem.modelData.state || "unavailable")
                    valueColor: ethItem.modelData.state === "connected" ? "#34C759" : Tok.ink3
                }
            }
        }
    }

    // ---- Wi-Fi ----
    Section { title: "Wi-Fi networks"; icon: "wifi" }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Sym { text: "wifi"; sz: 18; color: root.wifiRadio ? Tok.accent : Tok.ink3 }
        Text { text: "Wi-Fi"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500; Layout.fillWidth: true }
        Chip { label: "Rescan"; icon: "refresh"; onPicked: root.rescanWifi() }
        Toggle { on: root.wifiRadio; onToggled: root.setWifiRadio(!root.wifiRadio) }
    }

    // Active connection details
    ColumnLayout {
        visible: !!root.netInfo.ip
        Layout.fillWidth: true; spacing: 0
        MacDivider {}
        MacInfoRow { label: "IP Address"; value: root.netInfo.ip || ""; mono: true }
        MacInfoRow { visible: !!(root.netInfo.gw); label: "Router"; value: root.netInfo.gw || ""; mono: true }
        MacInfoRow { visible: (root.netInfo.dns || []).length > 0; label: "DNS"; value: (root.netInfo.dns || []).join(", "); mono: true }
        MacInfoRow { visible: !!(root.netInfo.iface); label: "Interface"; value: root.netInfo.iface || ""; mono: true }
    }

    MacDivider {}

    ColumnLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 4
        Repeater {
            model: root.wifiList
            delegate: Rectangle {
                id: wrow
                required property var modelData
                readonly property bool asking: root.wifiPwFor === modelData.ssid
                readonly property bool joining: root.wifiConnectingTo === modelData.ssid
                readonly property bool eap: !!modelData.enterprise
                onAskingChanged: if (asking) (eap ? idIn : pwIn).forceActiveFocus()
                function join() {
                    if (eap) root.wifiJoinPw(modelData.ssid, pwIn.text, idIn.text)
                    else root.wifiJoinPw(modelData.ssid, pwIn.text)
                    pwIn.text = ""
                }
                Layout.fillWidth: true; implicitHeight: asking ? (eap ? 114 : 80) : 38; radius: 8
                Behavior on implicitHeight { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                color: modelData.active || joining ? Tok.accentWash : (wma.containsMouse || asking ? root.rowHover : "transparent")
                border.width: asking || joining || modelData.active ? 1 : 0; border.color: Tok.alpha(Tok.accent, 0.45)
                clip: true
                ColumnLayout {
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 4; bottomMargin: 6 }
                    spacing: 2
                    Item {
                        Layout.fillWidth: true; implicitHeight: 30
                        MouseArea {
                            id: wma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (wrow.joining) return;
                                if (modelData.active) { root.wifiDisconnect(modelData.ssid); return }
                                if (wrow.asking) { root.wifiPwFor = ""; return }
                                root.wifiConnect(modelData.ssid, modelData.secure)
                            }
                        }
                        RowLayout {
                            anchors.fill: parent; spacing: 9
                            readonly property bool saved: root.savedCons.indexOf(modelData.ssid) >= 0
                            Sym {
                                text: wrow.joining ? ["wifi_1_bar", "wifi_2_bar", "wifi"][root.wifiPhase]
                                    : modelData.signal > 66 ? "signal_wifi_4_bar" : modelData.signal > 33 ? "network_wifi_3_bar" : "network_wifi_1_bar"
                                sz: 17; color: modelData.active || wrow.joining ? Tok.accent : Tok.ink2
                            }
                            Text {
                                text: modelData.ssid; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans
                                font.weight: modelData.active ? 600 : 400
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                            Text {
                                text: wrow.joining ? "Connecting…" : modelData.signal + "%"
                                color: wrow.joining ? Tok.accent : Tok.ink3; font.pixelSize: 11; font.family: Tok.mono
                            }
                            Sym {
                                visible: wma.containsMouse && parent.saved; text: "delete"; sz: 15; color: fgm.containsMouse ? Tok.crit : Tok.ink3
                                MouseArea {
                                    id: fgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.wifiForget(modelData.ssid)
                                }
                            }
                            Sym { visible: modelData.active && wma.containsMouse; text: "link_off"; sz: 15; color: Tok.crit }
                            Sym { text: "lock"; sz: 13; color: Tok.ink3; visible: modelData.secure && !wma.containsMouse }
                            Sym { text: "check"; sz: 15; color: "#34C759"; visible: modelData.active && !wma.containsMouse }
                        }
                    }
                    // 802.1X enterprise username
                    Rectangle {
                        visible: wrow.asking && wrow.eap
                        Layout.fillWidth: true; Layout.rightMargin: 72; implicitHeight: 28; radius: 7
                        color: Tok.bg; border.width: 1; border.color: Tok.alpha(Tok.accent, 0.45)
                        TextInput {
                            id: idIn
                            anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                            verticalAlignment: TextInput.AlignVCenter
                            color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                            KeyNavigation.tab: pwIn
                            Text { text: "Username (e.g. you@university.edu)"; visible: idIn.text === ""; color: Tok.ink3
                                font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                            Keys.onReturnPressed: pwIn.forceActiveFocus()
                            Keys.onEscapePressed: (e) => { root.wifiPwFor = ""; pwIn.text = ""; e.accepted = true }
                        }
                    }
                    // Inline password row
                    RowLayout {
                        visible: wrow.asking; Layout.fillWidth: true; spacing: 8
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 28; radius: 7
                            color: Tok.bg; border.width: 1; border.color: Tok.alpha(Tok.accent, 0.45)
                            TextInput {
                                id: pwIn
                                anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                verticalAlignment: TextInput.AlignVCenter
                                color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
                                echoMode: TextInput.Password; clip: true
                                Text { text: "Password…"; visible: pwIn.text === ""; color: Tok.ink3
                                    font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                                Keys.onReturnPressed: wrow.join()
                                Keys.onEscapePressed: (e) => { root.wifiPwFor = ""; pwIn.text = ""; e.accepted = true }
                            }
                        }
                        AccentBtn {
                            Layout.fillWidth: false; implicitWidth: 66; implicitHeight: 28
                            label: "Join"
                            onClicked: wrow.join()
                        }
                    }
                }
            }
        }
        Text {
            visible: root.wifiList.length === 0
            text: root.wifiRadio ? "Scanning for nearby networks…" : "Wi-Fi is turned off."
            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
        }
        // Join hidden network
        Rectangle {
            Layout.fillWidth: true; implicitHeight: root.hidOpen ? 76 : 34; radius: 8; clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
            color: root.hidOpen ? root.rowHover : "transparent"
            border.width: root.hidOpen ? 1 : 0; border.color: root.cardBorder
            ColumnLayout {
                anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 4; bottomMargin: 6 }
                spacing: 4
                Item {
                    Layout.fillWidth: true; implicitHeight: 26
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.hidOpen = !root.hidOpen; if (root.hidOpen) hidSsid.forceActiveFocus() }
                    }
                    RowLayout {
                        anchors.fill: parent; spacing: 8
                        Sym { text: "visibility_off"; sz: 16; color: Tok.ink2 }
                        Text { text: "Other Network…"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans; Layout.fillWidth: true }
                        Sym { text: root.hidOpen ? "expand_less" : "expand_more"; sz: 16; color: Tok.ink3 }
                    }
                }
                RowLayout {
                    visible: root.hidOpen; Layout.fillWidth: true; spacing: 8
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 28; radius: 7
                        color: Tok.bg; border.width: 1; border.color: root.cardBorder
                        TextInput {
                            id: hidSsid; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                            verticalAlignment: TextInput.AlignVCenter; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                            Text { text: "Network name (SSID)"; visible: hidSsid.text === ""; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 28; radius: 7
                        color: Tok.bg; border.width: 1; border.color: root.cardBorder
                        TextInput {
                            id: hidPw; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                            verticalAlignment: TextInput.AlignVCenter; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; echoMode: TextInput.Password; clip: true
                            Text { text: "Password (optional)"; visible: hidPw.text === ""; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                            Keys.onReturnPressed: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text = ""; hidPw.text = "" }
                        }
                    }
                    AccentBtn {
                        Layout.fillWidth: false; implicitWidth: 60; implicitHeight: 28; label: "Join"
                        onClicked: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text = ""; hidPw.text = "" }
                    }
                }
            }
        }
        Text {
            visible: root.wifiMsg !== ""
            Layout.fillWidth: true; wrapMode: Text.Wrap; text: root.wifiMsg
            color: root.wifiMsg.indexOf("✓") >= 0 ? "#34C759" : root.wifiMsg.indexOf("Wrong") >= 0 ? Tok.crit : Tok.ink2
            font.pixelSize: 11; font.family: Tok.sans
        }
    }

    // ---- DNS & Device Name ----
    Section { title: "DNS & Identity"; icon: "dns" }
    MacList {
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10; Layout.bottomMargin: 10; spacing: 8
            RowLayout {
                Layout.fillWidth: true
                Text { text: "DNS Preset"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true }
                Text {
                    text: root.netExtra.activeConnection ? root.netExtra.activeConnection : "No active connection"
                    color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                }
            }
            MacSegmented {
                value: root.netExtra.dnsPreset || "auto"
                model: [
                    { k: "auto", l: "Automatic" },
                    { k: "cloudflare", l: "Cloudflare" },
                    { k: "quad9", l: "Quad9" },
                    { k: "google", l: "Google" }
                ]
                onPicked: (k) => { if (root.netExtra.activeConnection) root.setNetworkDns(root.netExtra.activeConnection, k) }
            }
        }
        MacDivider {}
        MacNavRow {
            icon: "computer"; badgeColor: "#8E8E93"
            title: "Local Hostname"
            value: root.netExtra.hostname || root.sysInfo.host || ""
            destination: 28
        }
    }
}
