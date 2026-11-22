import QtQuick
import QtQuick.Layouts

// a labelled progress meter (RAM / disk)
RowLayout {
    property string label: ""
    property string value: "…"
    property real pct: 0
    property color fill: theme.iris
    Layout.fillWidth: true; spacing: 11
    Text { text: label; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.preferredWidth: 58 }
    Rectangle {
        Layout.fillWidth: true; implicitHeight: 9; radius: Tok.r; color: theme.a(theme.line, 0.8)
        Rectangle { height: parent.height; radius: Tok.r
            width: parent.width * Math.max(0, Math.min(1, parent.parent.pct / 100))
            color: parent.parent.pct > 88 ? theme.bad : parent.parent.fill
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
    }
    Text { text: value; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.preferredWidth: 96; horizontalAlignment: Text.AlignRight }
}
