// Settings → General → Date & Time. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: dtPage
    property int tabIdx: 31
    visible: root.tab === 31
    Layout.fillWidth: true
    spacing: 14

    property bool tzPickerOpen: false
    property string nowText: ""
    property string dateText: ""

    function updateClock() {
        var d = new Date();
        dtPage.nowText = Qt.formatDateTime(d, root.apClock24 ? (root.apClockSeconds ? "HH:mm:ss" : "HH:mm") : (root.apClockSeconds ? "h:mm:ss ap" : "h:mm ap"));
        dtPage.dateText = Qt.formatDateTime(d, "dddd, d MMMM yyyy");
    }
    Component.onCompleted: updateClock()
    Timer {
        interval: 1000; repeat: true; running: root.shown && root.tab === 31
        onTriggered: dtPage.updateClock()
    }

    // Live clock summary card
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: clockRow.implicitHeight + 28
        radius: 11; color: root.cardFill; border.width: 1; border.color: root.cardBorder
        RowLayout {
            id: clockRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 16 }
            spacing: 14
            MacIconBadge { icon: "schedule"; badgeColor: "#8E8E93"; size: 46 }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 2
                Text { text: dtPage.nowText; color: Tok.ink; font.pixelSize: 22; font.family: Tok.mono; font.weight: 700 }
                Text { text: dtPage.dateText; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            }
            ColumnLayout {
                spacing: 2; Layout.alignment: Qt.AlignVCenter
                Text {
                    text: root.dtInfo.timezone || "UTC"
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; font.weight: 600
                    horizontalAlignment: Text.AlignRight; Layout.alignment: Qt.AlignRight
                }
                Text {
                    text: root.dtInfo.ntp ? (root.dtInfo.ntpSynced ? "Synced via NTP" : "NTP enabled") : "Manual time"
                    color: root.dtInfo.ntpSynced ? "#34C759" : Tok.ink3
                    font.pixelSize: 11; font.family: Tok.sans
                    horizontalAlignment: Text.AlignRight; Layout.alignment: Qt.AlignRight
                }
            }
        }
    }

    Section { title: "Time & Synchronization"; icon: "schedule" }
    MacList {
        ToggleCard {
            icon: "sync"
            title: "Set time and date automatically"
            desc: "Synchronize the system clock using Network Time Protocol (NTP) via systemd-timesyncd."
            on: !!root.dtInfo.ntp
            onToggled: root.setDateTimeNtp(!root.dtInfo.ntp)
        }
        MacDivider {}
        Item {
            Layout.fillWidth: true; implicitHeight: 52
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Sym { text: "public"; sz: 18; color: Tok.ink2; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 2
                    Text { text: "Time zone"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans }
                    Text { text: root.dtInfo.timezone || "UTC"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono }
                }
                Chip {
                    Layout.alignment: Qt.AlignVCenter
                    label: dtPage.tzPickerOpen ? "Done" : "Change…"
                    icon: dtPage.tzPickerOpen ? "check" : "edit"
                    on: dtPage.tzPickerOpen
                    onPicked: {
                        dtPage.tzPickerOpen = !dtPage.tzPickerOpen;
                        if (dtPage.tzPickerOpen) {
                            root.searchTimezones("");
                            tzSearchIn.forceActiveFocus();
                        }
                    }
                }
            }
        }
        ColumnLayout {
            visible: dtPage.tzPickerOpen
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 10; spacing: 8
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 32; radius: 8
                color: Tok.bg; border.width: 1; border.color: tzSearchIn.activeFocus ? Tok.accent : root.cardBorder
                Sym { id: tzMag; anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter } text: "search"; sz: 15; color: Tok.ink3 }
                TextInput {
                    id: tzSearchIn
                    anchors { left: tzMag.right; leftMargin: 7; right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                    onTextChanged: root.searchTimezones(text)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: tzSearchIn.text === ""
                        text: "Search city or region (e.g. Tokyo, London, New_York)…"
                        color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                    }
                }
            }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: root.dtTimezones.slice(0, 24)
                    delegate: Chip {
                        required property string modelData
                        label: modelData
                        on: root.dtInfo.timezone === modelData
                        onPicked: {
                            root.setTimeZone(modelData);
                            dtPage.tzPickerOpen = false;
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

    Section { title: "Clock Format"; icon: "access_time" }
    MacList {
        ToggleCard {
            icon: "schedule"
            title: "24-hour time"
            desc: "Display times as 15:30 instead of 3:30 pm in the menu bar."
            on: root.apClock24
            onToggled: { root.apClock24 = !root.apClock24; root.saveAppearance(); dtPage.updateClock() }
        }
        MacDivider {}
        ToggleCard {
            icon: "timer"
            title: "Display time with seconds"
            desc: "Show seconds live in the menu bar clock."
            on: root.apClockSeconds
            onToggled: { root.apClockSeconds = !root.apClockSeconds; root.saveAppearance(); dtPage.updateClock() }
        }
    }
}
