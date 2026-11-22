// Settings → General → Login Items & Startup. Built on demand via PageLoader in settings.qml.
import Quickshell
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: startupPage
    property int tabIdx: 30
    visible: root.tab === 30
    Layout.fillWidth: true
    spacing: 14

    property bool pickerOpen: false
    property string appQuery: ""

    readonly property var installableApps: {
        var q = startupPage.appQuery.toLowerCase().trim();
        var out = [];
        try {
            var all = DesktopEntries.applications.values;
            for (var i = 0; i < all.length; i++) {
                var e = all[i];
                if (!e || !e.name || !e.id) continue;
                if (q.length && ("" + e.name).toLowerCase().indexOf(q) < 0) continue;
                out.push(e);
            }
        } catch (err) {}
        out.sort(function(a, b) { return ("" + a.name).localeCompare("" + b.name) });
        return out.slice(0, 8);
    }

    MacHeaderCard {
        icon: "rocket_launch"
        badgeColor: "#8E8E93"
        title: "Login Items & Startup"
        description: "Control which apps open automatically when you log in and which background user services are active."
    }

    Section { title: "Open at Login"; icon: "login" }
    MacList {
        Item {
            visible: root.startupApps.length === 0
            Layout.fillWidth: true; implicitHeight: 44
            Text {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
                text: "No autostart entries found in ~/.config/autostart or /etc/xdg/autostart."
                color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans; wrapMode: Text.WordWrap
            }
        }

        Repeater {
            model: root.startupApps
            delegate: ColumnLayout {
                id: appEntry
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 0

                MacDivider { visible: appEntry.index > 0; insetLeft: 54 }

                Item {
                    Layout.fillWidth: true
                    implicitHeight: 54

                    RowLayout {
                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                        spacing: 12

                        // Real app icon when available, else clean rounded badge
                        Rectangle {
                            implicitWidth: 28; implicitHeight: 28; radius: 7
                            Layout.alignment: Qt.AlignVCenter
                            color: Tok.light ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(1, 1, 1, 0.08)
                            readonly property string iconPath: appEntry.modelData.icon ? Quickshell.iconPath(appEntry.modelData.icon, true) : ""
                            IconImage {
                                anchors.centerIn: parent
                                visible: parent.iconPath.length > 0
                                source: parent.iconPath
                                implicitSize: 20
                            }
                            Sym {
                                anchors.centerIn: parent
                                visible: parent.iconPath.length === 0
                                text: appEntry.modelData.system ? "manufacturing" : "apps"
                                sz: 17
                                color: appEntry.modelData.enabled ? Tok.accent : Tok.ink3
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 7
                                Text {
                                    text: appEntry.modelData.name
                                    color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500
                                    elide: Text.ElideRight; Layout.maximumWidth: 340
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                Rectangle {
                                    visible: appEntry.modelData.system
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: sysTag.implicitWidth + 10; implicitHeight: 17; radius: 4
                                    color: Tok.light ? Qt.rgba(0, 0, 0, 0.055) : Qt.rgba(1, 1, 1, 0.08)
                                    Text {
                                        id: sysTag; anchors.centerIn: parent
                                        text: "System"; color: Tok.ink3
                                        font.pixelSize: 10; font.family: Tok.sans; font.weight: 500
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                text: appEntry.modelData.comment || appEntry.modelData.exec || appEntry.modelData.id
                                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                        }

                        Rectangle {
                            visible: !appEntry.modelData.system
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: 28; implicitHeight: 28; radius: 6
                            color: rmMa.containsMouse ? Tok.critWash : "transparent"
                            Sym { anchors.centerIn: parent; text: "delete"; sz: 16; color: rmMa.containsMouse ? Tok.crit : Tok.ink3 }
                            MouseArea {
                                id: rmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.startupRemoveApp(appEntry.modelData.id)
                            }
                        }

                        Toggle {
                            Layout.alignment: Qt.AlignVCenter
                            on: !!appEntry.modelData.enabled
                            onToggled: root.startupToggleApp(appEntry.modelData.id, !appEntry.modelData.enabled)
                        }
                    }
                }
            }
        }

        MacDivider {}

        Item {
            Layout.fillWidth: true
            implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 8
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    label: startupPage.pickerOpen ? "Close app picker" : "Add login item…"
                    icon: startupPage.pickerOpen ? "close" : "add"
                    on: startupPage.pickerOpen
                    onPicked: {
                        startupPage.pickerOpen = !startupPage.pickerOpen;
                        if (startupPage.pickerOpen) addAppIn.forceActiveFocus();
                    }
                }
                Item { Layout.fillWidth: true }
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    label: "Refresh"; icon: "refresh"
                    onPicked: root.refreshStartup()
                }
            }
        }

        ColumnLayout {
            visible: startupPage.pickerOpen
            Layout.fillWidth: true
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 10
            spacing: 8
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 32; radius: 8
                color: Tok.bg; border.width: 1; border.color: addAppIn.activeFocus ? Tok.accent : root.cardBorder
                Sym { id: addSearchIco; anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter } text: "search"; sz: 15; color: Tok.ink3 }
                TextInput {
                    id: addAppIn
                    anchors { left: addSearchIco.right; leftMargin: 7; right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                    onTextChanged: startupPage.appQuery = text
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: addAppIn.text === ""
                        text: "Search installed apps to launch at login…"
                        color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                    }
                }
            }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: startupPage.installableApps
                    delegate: Chip {
                        required property var modelData
                        label: modelData.name; icon: "add"
                        onPicked: {
                            root.startupAddApp(modelData.id);
                            startupPage.pickerOpen = false;
                            addAppIn.text = "";
                        }
                    }
                }
            }
        }
    }

    Section { title: "Allow in the Background"; icon: "deployed_code" }
    MacList {
        Item {
            visible: root.startupServices.length === 0
            Layout.fillWidth: true; implicitHeight: 44
            Text {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
                text: "No watched user systemd services detected."
                color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
            }
        }
        Repeater {
            model: root.startupServices
            delegate: ColumnLayout {
                id: svcRow
                required property var modelData
                required property int index
                Layout.fillWidth: true; spacing: 0
                MacDivider { visible: svcRow.index > 0; insetLeft: 36 }
                Item {
                    Layout.fillWidth: true; implicitHeight: 50
                    RowLayout {
                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                        spacing: 12
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: 9; implicitHeight: 9; radius: 4.5
                            color: svcRow.modelData.active ? "#34C759" : Tok.ink3
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 2
                            Text {
                                text: svcRow.modelData.label
                                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500
                            }
                            Text {
                                text: svcRow.modelData.unit + "  ·  " + svcRow.modelData.state + " (" + svcRow.modelData.preset + ")"
                                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono
                            }
                        }
                        Chip {
                            Layout.alignment: Qt.AlignVCenter
                            visible: svcRow.modelData.active
                            label: "Restart"; icon: "refresh"
                            onPicked: root.startupServiceAction(svcRow.modelData.unit, "restart")
                        }
                        Toggle {
                            Layout.alignment: Qt.AlignVCenter
                            on: !!svcRow.modelData.active
                            onToggled: root.startupServiceAction(svcRow.modelData.unit, svcRow.modelData.active ? "stop" : "start")
                        }
                    }
                }
            }
        }
    }
}
