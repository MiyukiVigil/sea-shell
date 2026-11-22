// Settings → Apps & Calendar (Default Apps + drill-downs to Calendar & Weather).
import Quickshell
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 22
    visible: root.tab === 22
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "apps"
        badgeColor: "#007AFF"
        title: "Apps & Calendar"
        description: "Choose default applications for links, files, and folders, and configure Calendar and Weather."
    }

    Section { title: "Services"; icon: "calendar_month" }
    MacList {
        MacNavRow {
            icon: "calendar_month"; badgeColor: "#FF3B30"
            title: "Calendar & Reminders"
            subtitle: "Import .ics schedules, manage calendar subscriptions, and event reminders"
            value: root.calEvents.length > 0 ? (root.calEvents.length + " events") : ""
            destination: 11
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "cloud"; badgeColor: "#32ADE6"
            title: "Weather"
            subtitle: "Forecast city and temperature units"
            value: root.wxLoc + " · " + (root.wxUnit === "u" ? "°F" : "°C")
            destination: 3
        }
    }

    Section { title: "What opens what"; icon: "apps" }
    MacList {
        Text {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 8; Layout.bottomMargin: 8; wrapMode: Text.Wrap
            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
            text: "System-wide MIME defaults via xdg-mime. The terminal choice is used by sea-shell's own actions."
        }
        Text {
            visible: root.defError.length > 0
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 6; wrapMode: Text.Wrap
            color: Tok.crit; font.pixelSize: 12; font.family: Tok.sans
            text: "⚠  " + root.defError
        }
        Text {
            visible: root.defRoles.length === 0
            Layout.leftMargin: 14; Layout.bottomMargin: 10
            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
            text: "Reading installed applications…"
        }

        Repeater {
            model: root.defRoles
            delegate: ColumnLayout {
                id: roleBlock
                required property var modelData
                required property int index
                readonly property bool expanded: root.defOpen === modelData.role
                readonly property var choices: root.defCands[modelData.role] || []
                Layout.fillWidth: true
                spacing: 0

                MacDivider { visible: roleBlock.index > 0 }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: roleBlock.modelData.note.length > 0 ? 52 : 44
                    radius: 8
                    color: roleBlock.expanded ? Tok.accentWash : (roleMa.containsMouse ? root.rowHover : "transparent")

                    RowLayout {
                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                        spacing: 12
                        Sym { text: roleBlock.modelData.icon; sz: 18; color: Tok.accent; Layout.alignment: Qt.AlignVCenter }
                        ColumnLayout {
                            spacing: 1; Layout.fillWidth: true; Layout.preferredWidth: 0; Layout.alignment: Qt.AlignVCenter
                            Text {
                                Layout.fillWidth: true; Layout.preferredWidth: 0; elide: Text.ElideRight
                                text: roleBlock.modelData.label
                                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500
                            }
                            Text {
                                visible: roleBlock.modelData.note.length > 0
                                text: roleBlock.modelData.note
                                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                                elide: Text.ElideRight; Layout.fillWidth: true; Layout.preferredWidth: 0
                            }
                        }
                        RowLayout {
                            Layout.preferredWidth: 200; Layout.maximumWidth: 200; spacing: 8; Layout.alignment: Qt.AlignVCenter
                            Item {
                                Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                IconImage {
                                    anchors.fill: parent
                                    visible: roleBlock.modelData.current && roleBlock.modelData.current.icon.length > 0
                                    source: visible ? Quickshell.iconPath(roleBlock.modelData.current.icon, true) : ""
                                    implicitSize: 18
                                }
                            }
                            Text {
                                Layout.fillWidth: true; Layout.preferredWidth: 0; elide: Text.ElideRight
                                text: root.defBusy === roleBlock.modelData.role ? "Saving…"
                                    : (roleBlock.modelData.current ? roleBlock.modelData.current.name : "Not set")
                                color: roleBlock.modelData.current ? Tok.ink2 : Tok.ink3
                                font.pixelSize: 12; font.family: Tok.sans
                                horizontalAlignment: Text.AlignRight
                            }
                            Sym { text: roleBlock.expanded ? "expand_less" : "unfold_more"; sz: 16; color: Tok.ink3 }
                        }
                    }
                    MouseArea {
                        id: roleMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.defOpen = roleBlock.expanded ? "" : roleBlock.modelData.role
                    }
                }

                ColumnLayout {
                    visible: roleBlock.expanded
                    Layout.fillWidth: true; Layout.leftMargin: 32; Layout.rightMargin: 14; Layout.topMargin: 4; Layout.bottomMargin: 8; spacing: 2
                    Repeater {
                        model: roleBlock.choices
                        delegate: Rectangle {
                            id: candRow
                            required property var modelData
                            readonly property bool chosen: roleBlock.modelData.current && roleBlock.modelData.current.id === modelData.id
                            Layout.fillWidth: true; implicitHeight: 34; radius: 7
                            color: chosen ? Tok.accentWash : (candMa.containsMouse ? root.rowHover : "transparent")
                            RowLayout {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 9
                                IconImage {
                                    visible: candRow.modelData.icon.length > 0
                                    source: visible ? Quickshell.iconPath(candRow.modelData.icon, true) : ""
                                    implicitSize: 16
                                }
                                Text {
                                    text: candRow.modelData.name
                                    color: chosen ? Tok.accent : Tok.ink
                                    font.pixelSize: 12; font.family: Tok.sans; font.weight: chosen ? 600 : 400
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                                Sym { visible: chosen; text: "check"; sz: 15; color: Tok.accent }
                            }
                            MouseArea {
                                id: candMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.defSet(roleBlock.modelData.role, candRow.modelData.id); root.defOpen = "" }
                            }
                        }
                    }
                }
            }
        }
    }
}
