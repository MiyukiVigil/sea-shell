// Settings → Disks. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 19
    visible: root.tab === 19; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "hard_drive"
        badgeColor: "#8E8E93"
        title: "Storage"
        description: "Inspect internal and removable drives, monitor SMART health, see what is using space, and safely clear caches."
    }

    // ---- overview ----
    // Numbers first, detail below: how many drives, how much of the root
    // filesystem is gone, and whether anything is plugged in.
    Section { title: "Overview"; icon: "monitoring" }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        Layout.topMargin: 4; spacing: Tok.s8
        IndKpi {
            label: "Drives"; value: "" + root.diskDrives.length
            sub: root.diskRemovableCount > 0 ? (root.diskRemovableCount + " removable") : "All internal"
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Tok.rule }
        IndKpi {
            label: "Root used"; value: root.diskRootPct >= 0 ? ("" + root.diskRootPct) : "—"
            unit: root.diskRootPct >= 0 ? "%" : ""
            sub: root.diskRootFree !== "" ? (root.diskRootFree + " free") : ""
            tone: root.diskRootPct >= 90 ? "crit" : root.diskRootPct >= 80 ? "warn" : "ok"
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Tok.rule }
        IndKpi {
            label: "Can be cleared"
            value: diskScan.clearableCount > 0 ? diskScan.human(diskScan.clearableBytes).split(" ")[0] : (diskScan.scanned ? "0" : "…")
            unit: diskScan.clearableCount > 0 ? diskScan.human(diskScan.clearableBytes).split(" ")[1] : ""
            sub: diskScan.clearableCount > 0 ? "at most" : ""
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Tok.rule }
        IndKpi {
            label: "Mounted"; value: "" + root.diskMountedCount
            sub: "of " + root.diskRows.length + " partitions"
        }
        Item { Layout.fillWidth: true }
    }

    // ---- one panel per physical drive ----
    Section { title: "Drives"; icon: "hard_drive" }
    Repeater {
        model: root.diskDrives
        delegate: ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10
            spacing: 6

            // drive header: what it is, how it connects, and eject if removable
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Sym { text: modelData.removable ? "usb" : "hard_drive"; sz: 16
                    color: modelData.removable ? theme.frost : theme.sub }
                Text { text: modelData.name; color: theme.text
                    font.pixelSize: 13; font.family: Tok.sans; font.bold: true
                    elide: Text.ElideRight; Layout.maximumWidth: 300 }
                Rectangle {
                    implicitHeight: 15; implicitWidth: busT.width + 12; radius: Tok.r
                    color: theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                    Text { id: busT; anchors.centerIn: parent; text: modelData.bus
                        color: theme.frost; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                }
                Text { text: modelData.size + "  ·  /dev/" + modelData.dev
                    color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                Item { Layout.fillWidth: true }
                IndBtn {
                    visible: modelData.removable
                    text: "Eject"; rank: "secondary"
                    onActivated: root.diskEject({ path: modelData.path, name: modelData.name,
                                                  mounted: modelData.mounted })
                }
            }
            // The drive's own report on itself. Absent for drives that keep it to
            // themselves, which most USB sticks do.
            Flow {
                id: healthFlow
                readonly property var rows: diskScan.healthRows(modelData.dev)
                visible: rows.length > 0
                Layout.fillWidth: true; Layout.topMargin: 2; Layout.bottomMargin: 4
                spacing: 22
                Repeater {
                    model: healthFlow.rows
                    delegate: IndKpi {
                        required property var modelData
                        label: modelData.label; value: modelData.value; tone: modelData.tone
                        size: Tok.tBody
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }

            // partitions of this drive
            Repeater {
                model: modelData.parts
                delegate: Rectangle {
                    id: partRow
                    required property var modelData
                    readonly property bool sys: modelData.system
                    Layout.fillWidth: true
                    implicitHeight: 46
                    radius: Tok.rSmall
                    color: pma.containsMouse && !partRow.sys ? Tok.surface : "transparent"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 4; anchors.rightMargin: 4
                        anchors.topMargin: 5; anchors.bottomMargin: 5
                        spacing: 3
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text { text: modelData.dev; color: theme.text
                                font.pixelSize: 11; font.family: Tok.sans
                                Layout.minimumWidth: 92 }
                            Text { visible: modelData.label !== ""; text: modelData.label
                                color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                Layout.minimumWidth: 76; elide: Text.ElideRight }
                            Text { text: diskScan.fsNote(modelData.dev) || modelData.fs; color: theme.faint
                                font.pixelSize: 11; font.family: Tok.sans
                                Layout.minimumWidth: 48 }
                            Text { text: modelData.size; color: theme.sub
                                font.pixelSize: 11; font.family: Tok.sans
                                Layout.minimumWidth: 62; horizontalAlignment: Text.AlignRight }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideMiddle
                                text: modelData.mounted ? modelData.mounts : "Not mounted"
                                color: modelData.mounted ? theme.frost : theme.faint
                                font.pixelSize: 11; font.family: Tok.sans
                            }
                            Rectangle {
                                implicitHeight: 15; implicitWidth: stT.width + 12; radius: Tok.r
                                readonly property color tone: partRow.sys ? theme.line
                                               : modelData.mounted ? theme.good : theme.iris
                                color: theme.a(tone, 0.18)
                                border.width: 1
                                border.color: theme.a(tone, 0.45)
                                Text { id: stT; anchors.centerIn: parent
                                    text: partRow.sys ? "System"
                                          : modelData.mounted ? "mounted" : "idle"
                                    color: partRow.sys ? theme.faint
                                           : modelData.mounted ? theme.good : theme.frost
                                    font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                            }
                        }
                        // usage bar — only where a usage figure genuinely exists
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            visible: modelData.pct >= 0
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 5
                                radius: 2.5; color: theme.a(theme.line, 0.8)
                                Rectangle {
                                    height: parent.height; radius: 2.5
                                    width: parent.width * Math.max(0, Math.min(1, modelData.pct / 100))
                                    color: modelData.pct >= 90 ? theme.bad
                                         : modelData.pct >= 78 ? theme.warn : theme.iris
                                    Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                }
                            }
                            Text {
                                text: modelData.used + " used  ·  " + modelData.avail + " free  ·  " + modelData.pct + "%"
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
                                Layout.minimumWidth: 200; horizontalAlignment: Text.AlignRight
                            }
                        }
                    }
                    MouseArea {
                        id: pma
                        anchors.fill: parent; hoverEnabled: true
                        cursorShape: partRow.sys ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: root.diskToggle({ _system: modelData.system,
                                                     _mounted: modelData.mounted,
                                                     _path: modelData.path,
                                                     dev: modelData.dev })
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 8
        wrapMode: Text.WordWrap
        text: root.diskMsg !== "" ? root.diskMsg
              : "Click a partition to mount or unmount it. Removable media mounts silently; internal "
                + "partitions ask for an admin password once per session. / and /boot are shown but never unmounted. "
                + "Usage is only known for mounted filesystems."
        color: root.diskMsg !== "" ? theme.frost : theme.faint
        font.pixelSize: 11; font.family: Tok.sans
    }

    Section { title: "Free up space"; icon: "mop" }
    DiskCleanPanel { scan: diskScan }

    Section { title: "What's using space"; icon: "folder_open" }
    DiskUsagePanel { scan: diskScan }

}
