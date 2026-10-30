import QtQuick
import QtQuick.Layouts

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
    signal finished()
    width: 620
    implicitHeight: contents.implicitHeight + 48
    height: implicitHeight
    radius: rounding; color: surface
    border.width: 1; border.color: rule
    ColumnLayout {
        id: contents
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
        spacing: 16
        RowLayout {
            Layout.fillWidth: true; spacing: 12
            Text { text: "waves"; font.family: "Material Symbols Outlined"; font.pixelSize: 24; color: card.accent }
            Text { text: "sea-shell"; font.family: card.mono; font.pixelSize: 13; font.weight: Font.DemiBold; color: card.ink }
            Text { text: "v7.0.0"; font.family: card.mono; font.pixelSize: 11; color: card.secondary }
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: 26; implicitHeight: 26; radius: card.controlRadius
                color: closeMouse.containsMouse ? card.wash : "transparent"
                Text { anchors.centerIn: parent; text: "close"; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: card.secondary }
                MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.finished() }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: card.rule }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 4
            Text { text: "what’s new"; font.family: card.mono; font.pixelSize: 20; font.weight: Font.DemiBold; color: card.ink }
            Text { text: "lock · power · notifications · desktop"; font.family: card.mono; font.pixelSize: 11; color: card.secondary }
        }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 0
            Repeater {
                model: [
                    {icon:"lock", title:"lock screen", line:"Your clock, wallpaper and notifications, with a built-in unlock screen."},
                    {icon:"power_settings_new", title:"power menu", line:"Hold to confirm session actions, or schedule a shutdown for later."},
                    {icon:"shield", title:"password prompts", line:"Permission requests now appear inside the shell."},
                    {icon:"notifications", title:"grouped notifications", line:"Messages group by app, with dismiss and undo."},
                    {icon:"tune", title:"dropdowns", line:"Sound, Bluetooth, battery and calendar use the same controls."},
                    {icon:"widgets", title:"desktop widgets", line:"Calendar and batteries, with text that adapts to the wallpaper."}
                ]
                delegate: ColumnLayout {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true; spacing: 0
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 12; Layout.bottomMargin: 12; spacing: 12
                        Text { Layout.alignment: Qt.AlignTop; text: modelData.icon; font.family: "Material Symbols Outlined"; font.pixelSize: 18; color: card.accent }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            Text { text: modelData.title; font.family: card.mono; font.pixelSize: 13; font.weight: Font.Medium; color: card.ink }
                            Text { text: modelData.line; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.family: card.sans; font.pixelSize: 12; color: card.secondary }
                        }
                    }
                    Rectangle { visible: index < 5; Layout.fillWidth: true; height: 1; color: card.rule }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: card.rule }
        RowLayout {
            Layout.fillWidth: true
            Text { text: "settings kept"; Layout.fillWidth: true; font.family: card.mono; font.pixelSize: 11; color: card.secondary }
            Rectangle {
                implicitWidth: 86; implicitHeight: 32; radius: card.controlRadius
                color: buttonMouse.containsMouse ? card.wash : "transparent"
                border.width: 1; border.color: card.rule
                Text { anchors.centerIn: parent; text: "done"; font.family: card.mono; font.pixelSize: 12; color: card.ink }
                MouseArea { id: buttonMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.finished() }
            }
        }
    }
}
