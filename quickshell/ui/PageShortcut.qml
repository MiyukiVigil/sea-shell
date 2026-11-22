import QtQuick
import QtQuick.Layouts

// A section is a macOS-style group: a bold title, and everything after it on the page, up
// to the next section, sits on one rounded panel. The panel is drawn from here, behind the
// section's siblings, so the twenty-odd pages did not have to be rewritten into containers:
// their rows already keep a 14px inset on both sides, which is exactly the panel's padding.
Rectangle {
    id: shortcut
    required property int destination
    Layout.fillWidth: true
    implicitHeight: 44
    radius: Tok.rSmall
    activeFocusOnTab: true
    color: shortcutMouse.containsMouse || activeFocus ? theme.a(theme.iris, 0.12) : theme.panel
    border.width: 1
    border.color: activeFocus ? theme.iris : theme.line
    function activate() { root.showTab(destination) }
    Keys.onReturnPressed: activate()
    Keys.onEnterPressed: activate()
    Keys.onSpacePressed: activate()
    Accessible.role: Accessible.Button
    Accessible.name: root.tabLabel(destination)
    Accessible.onPressAction: activate()
    RowLayout {
        anchors.fill: parent; anchors.margins: 10; spacing: 10
        Text { text: root.tabIcon(shortcut.destination); renderType: Text.NativeRendering; font.family: "Material Symbols Rounded"
            font.pixelSize: 20; color: theme.iris }
        Text { Layout.fillWidth: true; text: root.tabLabel(shortcut.destination)
            elide: Text.ElideRight; font.family: Tok.sans; font.pixelSize: 13; color: theme.text }
        Text { text: "›"; color: theme.sub; font.pixelSize: 18 }
    }
    MouseArea { id: shortcutMouse; anchors.fill: parent; hoverEnabled: true
        cursorShape: Qt.PointingHandCursor; onClicked: shortcut.activate() }
}
