import QtQuick
import QtQuick.Layouts

// one key/value tile for the About/System dashboard
Rectangle {
    property string icon: ""
    property url logo: ""
    property string iconFont: "Material Symbols Outlined"   // set "Symbols Nerd Font" for brand/distro glyphs
    property string label: ""
    property string value: "…"
    Layout.fillWidth: true; implicitHeight: 46; radius: Tok.r
    color: Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, 0.035)
    RowLayout {
        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 11
        ThemedLogo { visible: logo.toString().length > 0; artwork: logo; Layout.preferredWidth: 30; Layout.preferredHeight: 24 }

        Sym { visible: !logo.toString().length; text: icon; sz: 19; color: theme.iris; font.family: iconFont }
        ColumnLayout {
            spacing: 1; Layout.fillWidth: true
            Text { text: label; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
            Text { text: value; color: theme.text; font.pixelSize: 12; font.family: Tok.sans; elide: Text.ElideRight; Layout.fillWidth: true }
        }
    }
}
