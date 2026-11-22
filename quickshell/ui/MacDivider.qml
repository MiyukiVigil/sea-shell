import QtQuick
import QtQuick.Layouts

// Crisp 1px inset hairline separator inside a MacList or Section card.
Rectangle {
    property int insetLeft: 16
    property int insetRight: 16
    readonly property bool edgeToEdge: true
    Layout.fillWidth: true
    Layout.leftMargin: insetLeft
    Layout.rightMargin: insetRight
    implicitHeight: 1
    color: root.hairline
}
