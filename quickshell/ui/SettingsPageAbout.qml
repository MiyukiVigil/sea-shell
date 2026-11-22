// Settings → General → About. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: aboutPage
    property int tabIdx: 28
    visible: root.tab === 28
    Layout.fillWidth: true
    spacing: 14

    property bool editingHost: false

    // Centered macOS About This Mac masthead
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: mastCol.implicitHeight + 36
        radius: 11
        color: root.cardFill
        border.width: 1
        border.color: root.cardBorder

        ColumnLayout {
            id: mastCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 20 }
            spacing: 6

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: 56; implicitHeight: 56; radius: 14
                color: Tok.accentWash
                border.width: 1; border.color: root.cardBorder
                SeaLogo { anchors.centerIn: parent; size: 34; card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.sysInfo.host || root.netExtra.hostname || "Linux PC"
                color: Tok.ink; font.pixelSize: 19; font.family: Tok.sans; font.weight: 700
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: (root.sysInfo.os || "Linux") + "  ·  sea-shell v" + root.seaVersion
                color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.sysInfo.up ? ("Up " + root.sysInfo.up) : ""
                visible: !!(root.sysInfo.up)
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
            }
        }
    }

    Section { title: "Device"; icon: "computer" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 10
                Text { text: "Name"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: !aboutPage.editingHost; Layout.alignment: Qt.AlignVCenter }
                Text {
                    visible: !aboutPage.editingHost
                    text: root.sysInfo.host || root.netExtra.hostname || "—"
                    color: Tok.ink2; font.pixelSize: 13; font.family: Tok.sans
                    Layout.alignment: Qt.AlignVCenter
                }
                Rectangle {
                    visible: aboutPage.editingHost
                    Layout.fillWidth: true; implicitHeight: 30; radius: 7; Layout.alignment: Qt.AlignVCenter
                    color: Tok.bg; border.width: 1; border.color: hostIn.activeFocus ? Tok.accent : root.cardBorder
                    TextInput {
                        id: hostIn
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; clip: true; selectByMouse: true
                        text: root.sysInfo.host || root.netExtra.hostname || ""
                        onAccepted: {
                            root.setHostname(text.trim());
                            aboutPage.editingHost = false;
                        }
                    }
                }
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    label: aboutPage.editingHost ? "Save" : "Rename"
                    on: aboutPage.editingHost
                    onPicked: {
                        if (aboutPage.editingHost) {
                            root.setHostname(hostIn.text.trim());
                            aboutPage.editingHost = false;
                        } else {
                            hostIn.text = root.sysInfo.host || root.netExtra.hostname || "";
                            aboutPage.editingHost = true;
                            hostIn.forceActiveFocus();
                        }
                    }
                }
            }
        }
        Text {
            visible: root.sysMsg !== ""
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 8; wrapMode: Text.WordWrap
            text: root.sysMsg; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
        }
    }

    Section { title: "Hardware"; icon: "memory" }
    MacList {
        MacInfoRow {
            icon: "developer_board"; label: "Processor"
            value: (root.sysInfo.cpu || "…") + (root.sysInfo.cores ? (" (" + root.sysInfo.cores + " threads)") : "")
        }
        Repeater {
            model: root.sysInfo.gpus || []
            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true; spacing: 0
                MacDivider {}
                MacInfoRow { icon: "view_in_ar"; label: "Graphics"; value: modelData }
            }
        }
        MacDivider {}
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 12; Layout.bottomMargin: 12; spacing: 10
            Meter { label: "Memory"; pct: parseInt(root.sysInfo.rampct) || 0; value: root.sysInfo.ram || "…"; fill: Tok.accent }
            Meter { label: "Startup Disk"; pct: parseInt(root.sysInfo.diskpct) || 0; value: root.sysInfo.disk || "…"; fill: "#34C759" }
        }
    }

    Section { title: "Software"; icon: "info" }
    MacList {
        MacInfoRow { label: "Operating System"; value: root.sysInfo.os || "…" }
        MacDivider {}
        MacInfoRow { label: "Kernel"; value: root.sysInfo.kernel || "…"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Compositor"; value: root.sysInfo.wm ? ("Hyprland " + root.sysInfo.wm) : "Hyprland" }
        MacDivider {}
        MacInfoRow { label: "Session"; value: root.sysInfo.session ? Tok.cap(root.sysInfo.session) : "Wayland" }
        MacDivider {}
        MacInfoRow { label: "Display"; value: root.sysInfo.res || "…"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Shell"; value: root.sysInfo.shell || "…"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Packages"; value: root.sysInfo.pkgs ? (root.sysInfo.pkgs + " (pacman)") : "…" }
        MacDivider {}
        MacInfoRow { label: "Architecture"; value: root.sysInfo.arch || "…"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Load Average"; value: root.sysInfo.load || "…"; mono: true }
    }

    RowLayout {
        Layout.fillWidth: true; Layout.topMargin: 4
        Item { Layout.fillWidth: true }
        Chip { label: "Refresh info"; icon: "refresh"; onPicked: { root.refreshSystemInfo() } }
    }
}
