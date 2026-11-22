import QtQuick
import QtQuick.Layouts

// Authentic macOS System Settings sidebar row with semantic squircle icon badge.
Rectangle {
    id: tb
    property string icon: ""
    property string label: ""
    property int idx: 0
    property real hue: 0
    property color badgeColor: root.tabColor(idx)
    property int badge: 0
    readonly property bool sel: root.activeSidebarTab === idx

    Layout.fillWidth: true
    implicitHeight: 34
    radius: 10
    color: sel ? Tok.accent : (tbm.containsMouse ? root.rowHover : "transparent")
    Behavior on color { ColorAnimation { duration: Tok.mMicro } }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 7
        anchors.rightMargin: 10
        spacing: 10

        MacIconBadge {
            icon: tb.icon
            badgeColor: tb.badgeColor
            size: 24
            iconSize: 15
            ringed: tb.sel
            Layout.alignment: Qt.AlignVCenter
        }

        Text {
            text: tb.label
            color: tb.sel ? Tok.accentInk : Tok.ink
            font.pixelSize: 13
            font.family: Tok.sans
            font.weight: tb.sel ? 600 : 400
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        Rectangle {
            visible: tb.badge > 0
            implicitWidth: Math.max(17, badgeText.implicitWidth + 9)
            implicitHeight: 17
            radius: 8.5
            color: tb.sel ? Tok.accentInk : "#FF3B30"
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: tb.badge
                color: tb.sel ? Tok.accent : "#ffffff"
                font.pixelSize: 10
                font.family: Tok.sans
                font.weight: 700
            }
        }
    }

    MouseArea {
        id: tbm
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.showTab(tb.idx)
    }
}
