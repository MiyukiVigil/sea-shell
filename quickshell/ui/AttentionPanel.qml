// The short list at the top of System. Says so plainly when there's nothing to do.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: panel
    required property var list
    signal openTab(int tab)
    Layout.fillWidth: true
    spacing: 4
    onVisibleChanged: if (visible) list.refresh()
    Component.onCompleted: if (visible) list.refresh()

    Text {
        visible: panel.list.rows.length === 0
        text: panel.list.loaded ? "Nothing needs you right now." : "Checking…"
        color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
    }
    Repeater {
        model: panel.list.rows
        delegate: RowLayout {
            id: item
            required property var modelData
            readonly property color tone: modelData.level === "bad" ? Tok.crit : modelData.level === "warn" ? Tok.warn : Tok.ink3
            Layout.fillWidth: true; Layout.topMargin: 4; spacing: 10
            Text { text: item.modelData.level === "info" ? "info" : item.modelData.level === "bad" ? "error" : "warning"
                color: item.tone; renderType: Text.NativeRendering; font.family: "Material Symbols Rounded"; font.pixelSize: 18
                Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 1
                Text { text: item.modelData.title; color: Tok.ink; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    font.pixelSize: 12; font.family: Tok.sans; font.weight: 500 }
                Text { text: item.modelData.detail; color: Tok.ink3; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    font.pixelSize: 11; font.family: Tok.sans }
            }
            IndBtn { visible: item.modelData.level === "info"; text: "Not now"; rank: "ghost"
                onActivated: panel.list.dismiss(item.modelData.id) }
            IndBtn {
                visible: item.modelData.tab !== undefined || item.modelData.run !== undefined
                rank: "secondary"
                text: item.modelData.run === "backup" ? "Back up now" : item.modelData.run === "fans" ? "Set up" : "Open"
                onActivated: item.modelData.run !== undefined ? panel.list.perform(item.modelData)
                                                              : panel.openTab(item.modelData.tab)
            }
        }
    }
}
