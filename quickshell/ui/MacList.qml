import QtQuick
import QtQuick.Layouts

// Zero-gap grouped container for stacked macOS/Material You rows & 1px inset dividers.
ColumnLayout {
    readonly property bool edgeToEdge: true
    readonly property bool compactCard: true
    Layout.fillWidth: true
    Layout.leftMargin: 0
    Layout.rightMargin: 0
    Layout.topMargin: -8
    spacing: 0
}
