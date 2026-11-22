// Settings → Bluetooth (macOS-style Bluetooth header + paired devices).
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 9
    visible: root.tab === 9
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "bluetooth"
        badgeColor: "#007AFF"
        title: "Bluetooth"
        description: "Connect headphones, speakers, keyboards, controllers, and other wireless devices."
    }

    Section { title: "Bluetooth"; icon: "bluetooth" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 54
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Sym { text: "bluetooth"; sz: 18; color: (root.btAdapter && root.btAdapter.enabled) ? "#007AFF" : Tok.ink3; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 2
                    Text { text: "Bluetooth"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500 }
                    Text {
                        text: root.btAdapter === null ? "No Bluetooth adapter found"
                            : (root.btAdapter.discovering ? "Scanning for nearby devices…"
                               : (root.btAdapter.enabled ? "Discoverable and ready to connect" : "Off"))
                        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                    }
                }
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    visible: !!(root.btAdapter && root.btAdapter.enabled)
                    label: (root.btAdapter && root.btAdapter.discovering) ? "Stop scan" : "Scan"
                    icon: (root.btAdapter && root.btAdapter.discovering) ? "sync" : "search"
                    on: !!(root.btAdapter && root.btAdapter.discovering)
                    onPicked: if (root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering
                }
                Toggle {
                    Layout.alignment: Qt.AlignVCenter
                    enabled: root.btAdapter !== null
                    on: !!(root.btAdapter && root.btAdapter.enabled)
                    onToggled: if (root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled
                }
            }
        }

        MacDivider { visible: root.btDevices.length > 0 }

        IndTable {
            visible: root.btDevices.length > 0
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 8; Layout.bottomMargin: 8
            rowHeight: 36
            rows: root.btRows
            emptyText: ""
            columns: [
                { label: "Device",  key: "name",    flex: true },
                { label: "Battery", key: "battery", w: 74,  num: true },
                { label: "State",   key: "state",   w: 110, chip: true, num: true }
            ]
            onActivated: (i, row) => {
                if (!row._dev) return;
                row._dev.connected ? row._dev.disconnect() : row._dev.connect();
            }
        }
        Text {
            visible: root.btAdapter !== null && root.btDevices.length === 0
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; Layout.bottomMargin: 10
            text: (root.btAdapter && root.btAdapter.enabled) ? "No paired devices yet — click Scan to discover nearby devices." : "Turn on Bluetooth to connect wireless devices."
            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
        }
    }
}
