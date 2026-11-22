import QtQuick
import QtQuick.Layouts

// macOS sidebar group spacing with subtle inset hairline separator.
Item {
    Layout.fillWidth: true
    implicitHeight: 13
    Rectangle {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 8 }
        height: 1
        color: root.hairline
    }
}
