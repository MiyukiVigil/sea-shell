// Settings → Privacy & Security. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 27
    visible: root.tab === 27
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "shield"
        badgeColor: "#FF9500"
        title: "Privacy & Security"
        description: "Manage your network firewall, monitor active microphone and camera access, and protect clipboard and screen sharing privacy."
    }

    Section { title: "Network Firewall"; icon: "security" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 56
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 10; implicitHeight: 10; radius: 5
                    color: !root.privInfo.ufwInstalled ? Tok.ink3 : (root.privInfo.ufwEnabled ? "#34C759" : "#FF9500")
                }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 2
                    Text {
                        text: !root.privInfo.ufwInstalled ? "Firewall (ufw not installed)"
                            : (root.privInfo.ufwEnabled ? "Firewall is active" : "Firewall is inactive")
                        color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500
                    }
                    Text {
                        text: !root.privInfo.ufwInstalled
                            ? "Install ufw to manage incoming connection rules from Settings."
                            : "Blocks unsolicited incoming network connections via Uncomplicated Firewall (ufw)."
                        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                }
                Toggle {
                    Layout.alignment: Qt.AlignVCenter
                    enabled: !!root.privInfo.ufwInstalled && !root.privBusy
                    on: !!root.privInfo.ufwEnabled
                    onToggled: root.setFirewall(!root.privInfo.ufwEnabled)
                }
            }
        }
    }

    Section { title: "Microphone & Camera Activity"; icon: "sensors" }
    MacList {
        MacInfoRow {
            icon: "mic"
            label: "Microphone"
            subtitle: (root.privInfo.micApps && root.privInfo.micApps.length > 0)
                ? ("In use by: " + root.privInfo.micApps.join(", "))
                : "No applications are currently recording audio"
            value: (root.privInfo.micApps && root.privInfo.micApps.length > 0) ? "Active" : "Idle"
            valueColor: (root.privInfo.micApps && root.privInfo.micApps.length > 0) ? "#FF9500" : Tok.ink3
        }
        MacDivider { visible: !!(root.curSource && root.curSource.audio) }
        ToggleCard {
            visible: !!(root.curSource && root.curSource.audio)
            icon: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? "mic_off" : "mic"
            title: "Mute default microphone"
            desc: "Hardware-level input mute in PipeWire until you unmute it."
            on: !!(root.curSource && root.curSource.audio && root.curSource.audio.muted)
            onToggled: {
                if (root.curSource && root.curSource.audio)
                    root.curSource.audio.muted = !root.curSource.audio.muted;
            }
        }
        MacDivider {}
        MacInfoRow {
            icon: "videocam"
            label: "Camera"
            subtitle: !root.privInfo.camPresent ? "No camera device detected (/dev/video*)"
                : (root.privInfo.camInUse ? "An application currently has a camera device open" : "Camera detected and idle")
            value: !root.privInfo.camPresent ? "None" : (root.privInfo.camInUse ? "In use" : "Idle")
            valueColor: root.privInfo.camInUse ? "#34C759" : Tok.ink3
        }
    }

    Section { title: "Clipboard History"; icon: "content_paste" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 52
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Sym { text: "content_paste"; sz: 18; color: Tok.ink2; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 2
                    Text { text: "Saved clipboard items"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans }
                    Text { text: (root.privInfo.clipCount || 0) + " items stored in cliphist"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                }
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    label: "Clear history"; icon: "delete_sweep"
                    onPicked: root.clearClipboardHistory()
                }
            }
        }
    }

    Section { title: "Screen Sharing & Lock"; icon: "lock" }
    MacList {
        ToggleCard {
            icon: "screen_share"
            title: "Silence notifications while sharing or recording"
            desc: "Automatically hide popups whenever a screen share or recording is active."
            on: root.quietCfg.share
            onToggled: root.setQuiet("share", !root.quietCfg.share)
        }
        MacDivider {}
        MacNavRow {
            icon: "lock"; badgeColor: "#5E5CE6"
            title: "Lock Screen & Idle Timeouts"
            subtitle: "Configure automatic locking, grace period, and login screen security"
            destination: 10
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Text {
            visible: root.sysMsg !== ""
            text: root.sysMsg; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
            Layout.fillWidth: true; wrapMode: Text.WordWrap
        }
        Item { Layout.fillWidth: root.sysMsg === "" }
        Chip { label: "Refresh status"; icon: "refresh"; onPicked: root.refreshPrivacy() }
    }
}
