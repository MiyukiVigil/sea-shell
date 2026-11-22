import QtQuick
import QtQuick.Layouts

// The once-per-release page an existing install sees after updating (welcome.qml shows it when
// sea-whats-new.py says "show"). Colours come in as properties so it stays plain QtQuick.
// Drawn in settings' language: one sheet, a coloured tile per item, quiet fills, a pill button.
Rectangle {
    id: card
    property color surface: "#f7f7fa"
    property color raised: "#ffffff"
    property color ink: "#20212a"
    property color secondary: "#626575"
    property color accent: "#435d9e"
    property color wash: "#e9edf7"
    property color rule: "#dedfe7"
    property string sans: "Inter"
    property string mono: "JetBrains Mono"
    property real controlRadius: 7
    property real rounding: 20
    property string version: "7.1"
    signal finished()
    width: 620
    implicitHeight: contents.implicitHeight + 56
    height: implicitHeight
    radius: rounding + 6; color: surface
    border.width: 1; border.color: Qt.rgba(ink.r, ink.g, ink.b, 0.075)
    // a tile colour per row, turned round the colour wheel from the accent as Settings does
    function tile(i) {
        var h = card.accent.hslHue < 0 ? 0.6 : card.accent.hslHue;
        return Qt.hsla((h + i * 0.085) % 1, Math.max(0.42, card.accent.hslSaturation), 0.52, 1);
    }
    ColumnLayout {
        id: contents
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 28 }
        spacing: 18
        RowLayout {
            Layout.fillWidth: true; spacing: 12
            ColumnLayout {
                Layout.fillWidth: true; spacing: 3
                Text { text: "What’s new in sea-shell " + card.version; font.family: card.sans; font.pixelSize: 22; font.weight: Font.Bold; color: card.ink }
                Text { text: "Your settings were kept. Here is what changed."; font.family: card.sans; font.pixelSize: 13; color: card.secondary }
            }
            Rectangle {
                Layout.alignment: Qt.AlignTop
                implicitWidth: 30; implicitHeight: 30; radius: 15
                color: closeMouse.containsMouse ? Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.09) : Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.05)
                Text { anchors.centerIn: parent; text: "close"; font.family: "Material Symbols Outlined"; font.pixelSize: 17; color: card.secondary }
                MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.finished() }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: list.implicitHeight + 12
            radius: 14
            color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.04)
            ColumnLayout {
                id: list
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                spacing: 0
                Repeater {
                    model: [
                        {icon:"space_dashboard", title:"A new dashboard", line:"Redesigned, and it opens the moment you press Super D."},
                        {icon:"screenshot_region", title:"Screenshots and recording", line:"A capture bar, a tidier editor and a recorder that opens at once."},
                        {icon:"widgets", title:"Four new widgets", line:"Network, notifications, photos and a quote a day, with guides that line them up as you drag."},
                        {icon:"lock_clock", title:"The lock screen at a glance", line:"The weather and your next events sit under the clock."},
                        {icon:"devices", title:"A layout for each set of displays", line:"Dock or undock and your widgets, dock and bar come back as they were there."},
                        {icon:"palette", title:"One look throughout", line:"Shortcuts, the dock, Files, password prompts and the welcome tour now match Settings."}
                    ]
                    delegate: ColumnLayout {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true; spacing: 0
                        RowLayout {
                            Layout.fillWidth: true; Layout.margins: 10; spacing: 14
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: 32; implicitHeight: 32; radius: 9
                                color: card.tile(index)
                                Text { anchors.centerIn: parent; text: modelData.icon; font.family: "Material Symbols Outlined"; font.pixelSize: 19; color: "white" }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 2
                                Text { text: modelData.title; font.family: card.sans; font.pixelSize: 14; font.weight: Font.DemiBold; color: card.ink }
                                Text { text: modelData.line; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.family: card.sans; font.pixelSize: 12; color: card.secondary }
                            }
                        }
                        Rectangle { visible: index < 5; Layout.fillWidth: true; Layout.leftMargin: 56; height: 1
                            color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.075) }
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: 112; implicitHeight: 36; radius: 18
                color: buttonMouse.containsMouse ? Qt.lighter(card.accent, 1.08) : card.accent
                Text { anchors.centerIn: parent; text: "Continue"; font.family: card.sans; font.pixelSize: 13; font.weight: Font.DemiBold
                    color: (0.2126 * card.accent.r + 0.7152 * card.accent.g + 0.0722 * card.accent.b) > 0.55 ? "#15161c" : "white" }
                MouseArea { id: buttonMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.finished() }
            }
        }
    }
}
