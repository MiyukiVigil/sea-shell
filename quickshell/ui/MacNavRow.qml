import QtQuick
import QtQuick.Layouts

// Authentic macOS System Settings drill-down navigation row:
// [Squircle Icon Badge]  Title (+ optional subtitle)   [optional value / badge]  ›
Rectangle {
    id: nav
    property string icon: "tune"
    property color badgeColor: Tok.accent
    property string title: ""
    property string subtitle: ""
    property string value: ""
    property int badge: 0
    property int destination: -1
    readonly property bool edgeToEdge: true
    signal activated()

    Layout.fillWidth: true
    implicitHeight: subtitle !== "" ? 54 : 44
    radius: 8
    activeFocusOnTab: true
    color: navMa.pressed ? Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, 0.08)
         : (navMa.containsMouse || nav.activeFocus ? root.rowHover : "transparent")
    border.width: nav.activeFocus ? 1 : 0
    border.color: Tok.accent
    Behavior on color { ColorAnimation { duration: Tok.mMicro } }

    function trigger() {
        if (nav.destination >= 0) root.showTab(nav.destination);
        nav.activated();
    }

    Keys.onReturnPressed: trigger()
    Keys.onEnterPressed: trigger()
    Keys.onSpacePressed: trigger()
    Accessible.role: Accessible.Button
    Accessible.name: nav.title
    Accessible.onPressAction: trigger()

    RowLayout {
        anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
        spacing: 12

        MacIconBadge {
            icon: nav.icon
            badgeColor: nav.badgeColor
            size: 30
            iconSize: 17
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2
            Text {
                text: nav.title
                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: 500
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            Text {
                visible: nav.subtitle !== ""
                text: nav.subtitle
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                elide: Text.ElideRight; Layout.fillWidth: true
            }
        }

        Text {
            visible: nav.value !== ""
            text: nav.value
            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
            elide: Text.ElideRight
            Layout.maximumWidth: 190
            Layout.alignment: Qt.AlignVCenter
        }

        Rectangle {
            visible: nav.badge > 0
            implicitWidth: Math.max(18, bTxt.implicitWidth + 10)
            implicitHeight: 18; radius: 9
            color: "#FF3B30"
            Layout.alignment: Qt.AlignVCenter
            Text {
                id: bTxt; anchors.centerIn: parent
                text: nav.badge; color: "#ffffff"
                font.pixelSize: 11; font.family: Tok.sans; font.weight: 600
            }
        }

        Sym {
            text: "chevron_right"; sz: 18
            color: Tok.ink3
            Layout.alignment: Qt.AlignVCenter
        }
    }

    MouseArea {
        id: navMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: nav.trigger()
    }
}
