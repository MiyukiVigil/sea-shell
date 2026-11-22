// Settings → Vpn. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 2
    visible: root.tab === 2; Layout.fillWidth: true; spacing: 10

    // WARP header row
    Section { title: "Cloudflare WARP"; icon: "security" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 50
            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                spacing: 12
                Sym { text: "security"; sz: 19; filled: root.warpConnected; color: root.warpConnected ? "#34C759" : Tok.ink2; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 1
                    Text { text: "Cloudflare WARP"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500 }
                    Text { text: root.warpStatus; color: root.warpConnected ? "#34C759" : Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                }
                Toggle { Layout.alignment: Qt.AlignVCenter; on: root.warpConnected; onToggled: root.warpToggle() }
            }
        }
        MacDivider {}
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                spacing: 10
                Text { text: "Mode"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                RowLayout {
                    spacing: 6; Layout.alignment: Qt.AlignVCenter
                    Repeater {
                        model: ["warp", "doh", "warp+doh", "tunnel_only"]
                        delegate: Chip {
                            required property string modelData
                            label: modelData; on: root.warpMode === modelData
                            onPicked: root.warpSetMode(modelData)
                        }
                    }
                }
            }
        }
    }

    // VPN connections divider
    Section { title: "VPN connections"; icon: "vpn_key" }

    // saved VPN list
    ColumnLayout {
        Layout.fillWidth: true; spacing: 6
        Text { visible: root.vpnList.length === 0; text: "No VPN profiles saved. Import one below."
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
        Repeater {
            model: root.vpnList
            delegate: Rectangle {
                required property var modelData
                readonly property bool connecting: modelData.state === "activating" || root.vpnActionName === modelData.name
                readonly property bool failed: root.vpnFailedName === modelData.name
                Layout.fillWidth: true; implicitHeight: 50; radius: Tok.r
                color: modelData.active ? theme.a(theme.iris, 0.18) : (connecting ? theme.a(theme.frost, 0.08) : theme.a(theme.line, 0.35))
                border.width: 1; border.color: failed ? theme.bad : (modelData.active ? theme.a(theme.iris, 0.5) : (connecting ? theme.a(theme.frost, 0.3) : theme.a(theme.iris, 0.12)))
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                    Sym { text: modelData.type==="wireguard" ? "cable" : "vpn_key"; sz: 17
                        color: modelData.active ? theme.iris : (connecting ? theme.frost : (failed ? theme.bad : theme.faint)) }
                    ColumnLayout { spacing: 2; Layout.fillWidth: true
                        Text { text: modelData.name; color: modelData.active ? theme.text : (connecting ? theme.frost : (failed ? theme.bad : theme.sub))
                            font.pixelSize: 13; font.family: Tok.sans; font.bold: modelData.active || connecting; elide: Text.ElideRight }
                        Text {
                            text: connecting ? "connecting…" : (failed ? "Connection failed — please try again" : (modelData.active ? "Connected" : modelData.type))
                            color: connecting ? theme.frost : (failed ? theme.bad : (modelData.active ? theme.good : theme.faint))
                            font.pixelSize: 11; font.family: Tok.sans } }
                    Rectangle {
                        implicitWidth: 104; implicitHeight: 30; radius: Tok.r
                        color: connecting ? theme.a(theme.line, 0.5) : (vtm.containsMouse ? (modelData.active ? theme.a(theme.bad,0.3) : theme.iris) : (modelData.active ? theme.a(theme.bad,0.15) : theme.a(theme.iris,0.2)))
                        border.width: 1; border.color: connecting ? theme.a(theme.line, 0.7) : (modelData.active ? theme.bad : theme.iris)
                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                        Text { anchors.centerIn: parent
                            text: connecting ? "connecting…" : (modelData.active ? "Disconnect" : "Connect")
                            color: connecting ? theme.faint : (vtm.containsMouse ? (modelData.active ? theme.bad : theme.bg) : (modelData.active ? theme.bad : theme.frost))
                            font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                        MouseArea { id: vtm; anchors.fill: parent; hoverEnabled: true; cursorShape: connecting ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: if (!connecting) root.vpnToggle(modelData.name) } }
                    Rectangle {
                        implicitWidth: 32; implicitHeight: 30; radius: Tok.r
                        color: vdm.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"
                        Sym { anchors.centerIn: parent; text: "delete"; sz: 16
                            color: vdm.containsMouse ? theme.bad : theme.faint }
                        MouseArea { id: vdm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.vpnDelete(modelData.name) } }
                }
            }
        }
    }

    // add VPN expandable panel
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: root.vpnAddOpen ? vpnAddInner.implicitHeight + 20 : 42
        radius: Tok.r; clip: true
        Behavior on implicitHeight { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        color: root.vpnAddOpen ? root.rowHover : "transparent"
        border.width: root.vpnAddOpen ? 1 : 0; border.color: theme.a(theme.iris, 0.45)

        ColumnLayout {
            id: vpnAddInner
            anchors { fill: parent; leftMargin: 14; rightMargin: 14; topMargin: 8; bottomMargin: 8 }
            spacing: 10

            // toggle header
            MouseArea { Layout.fillWidth: true; implicitHeight: 26; cursorShape: Qt.PointingHandCursor
                onClicked: root.vpnAddOpen = !root.vpnAddOpen
                RowLayout { anchors.fill: parent; spacing: 8
                    Sym { text: "add_circle"; sz: 17; color: theme.frost }
                    Text { text: "Import VPN profile"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.fillWidth: true }
                    Sym { text: root.vpnAddOpen ? "expand_less" : "expand_more"; sz: 17; color: theme.faint } } }

            // type chips
            RowLayout {
                visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                Repeater { model: [{l:"WireGuard (.conf)",v:0},{l:"OpenVPN (.ovpn)",v:1}]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool sel: root.vpnAddMode === modelData.v
                        Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                        color: sel ? theme.a(theme.iris,0.25) : (atm2.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.35))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.15)
                        Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.text : theme.sub
                            font.pixelSize: 11; font.family: Tok.sans; font.bold: sel }
                        MouseArea { id: atm2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.vpnAddMode = modelData.v } } }
            }

            // file path + import button
            RowLayout {
                visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                    color: theme.bg; border.width: 1
                    border.color: vpnPathIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.25)
                    TextInput {
                        id: vpnPathIn
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 12; font.family: Tok.sans; clip: true
                        Text { anchors.verticalCenter: parent.verticalCenter; visible: vpnPathIn.text === ""
                            text: root.vpnAddMode === 0 ? "~/path/to/tunnel.conf" : "~/path/to/config.ovpn"
                            color: theme.faint; font.pixelSize: 12; font.family: Tok.sans }
                        Keys.onReturnPressed: {
                            if (root.vpnAddMode === 0) root.vpnAddWireguard(vpnPathIn.text);
                            else root.vpnAddOpenVPN(vpnPathIn.text);
                            vpnPathIn.text = ""; root.vpnAddOpen = false; } } }
                Rectangle {
                    implicitWidth: 36; implicitHeight: 34; radius: Tok.r
                    color: vpnBrowseMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                    border.width: 1; border.color: theme.a(theme.iris, 0.25)
                    Sym { anchors.centerIn: parent; text: "folder_open"; sz: 16; color: theme.frost }
                    MouseArea {
                        id: vpnBrowseMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var filter = root.vpnAddMode === 0 ? "WireGuard (*.conf) | *.conf" : "OpenVPN (*.ovpn) | *.ovpn";
                            root.pickFile(root.vpnAddMode === 0 ? "Select WireGuard Configuration" : "Select OpenVPN Configuration", filter, function(path) {
                                vpnPathIn.text = path;
                            }); } } }
                Rectangle {
                    implicitWidth: 80; implicitHeight: 34; radius: Tok.r
                    color: viam.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                    border.width: 1; border.color: theme.iris
                    RowLayout { anchors.centerIn: parent; spacing: 5
                        Sym { text: "upload_file"; sz: 14; color: viam.containsMouse ? theme.bg : theme.frost }
                        Text { text: "Import"; color: viam.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } }
                    MouseArea { id: viam; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.vpnAddMode === 0) root.vpnAddWireguard(vpnPathIn.text);
                            else root.vpnAddOpenVPN(vpnPathIn.text);
                            vpnPathIn.text = ""; root.vpnAddOpen = false; } } }
            }

            // hint
            Text { visible: root.vpnAddOpen; Layout.fillWidth: true; wrapMode: Text.Wrap
                text: root.vpnAddMode === 0
                    ? "paste the path to a WireGuard .conf file — the profile name is taken from the filename. get a .conf from your VPN provider or export from your router."
                    : "paste the path to an OpenVPN .ovpn file — username/password will be prompted on first connect if required."
                color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
        }
    }

    // status message
    Text { visible: root.vpnMsg !== ""; text: root.vpnMsg
        color: root.vpnMsg.indexOf("fail") >= 0 || root.vpnMsg.indexOf("fail") >= 0 ? theme.bad : theme.sub
        font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; wrapMode: Text.Wrap }
}
