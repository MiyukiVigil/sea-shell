// Settings → ScreenTime. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 18
    visible: root.tab === 18; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "hourglass_top"
        badgeColor: "#5856D6"
        title: "Screen Time"
        description: "Review active focus time per application, set daily usage reminders, and schedule a daily summary."
    }

    Section { title: "Today"; icon: "hourglass_top" }
    IndTable {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 30
        rows: root.usageLimitRows
        selectable: true
        selectedIndex: root.usageSel
        maxRows: 12
        emptyText: "Nothing recorded yet. The bar starts counting from its next restart."
        columns: [
            { label: "App",   key: "app",   flex: true },
            { label: "Today", key: "today", w: 84, num: true },
            { label: "Limit", key: "limit", w: 84, num: true },
            { label: "",      key: "state", w: 62, chip: true }
        ]
        onActivated: (i, row) => root.usageSel = i
    }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        wrapMode: Text.WordWrap
        text: "Time each app held focus, paused while the session is idle. Pick a row to set its daily limit."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    Section { title: "Daily limit"; icon: "timer"
        visible: root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length }
    RowLayout {
        visible: root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        readonly property string app: (root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length)
                                      ? root.usageLimitRows[root.usageSel].app : ""
        Text { text: parent.app; color: theme.text; font.pixelSize: 12; font.family: Tok.sans
            Layout.minimumWidth: 170; elide: Text.ElideRight }
        Repeater {
            model: [0, 30, 60, 120, 180, 240]
            delegate: Chip {
                required property var modelData
                label: modelData === 0 ? "Off" : (modelData + "m")
                on: (root.usageLimits[parent.parent.app] || 0) === modelData
                onPicked: root.ulimSet(parent.parent.app, modelData)
            }
        }
        Item { Layout.fillWidth: true }
    }
    Text {
        visible: root.usageSel >= 0
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        wrapMode: Text.WordWrap
        text: "You get one notification the first time an app passes its limit each day. It does not block anything."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    Section { title: "Daily summary"; icon: "summarize" }
    ToggleCard {
        icon: "notifications_active"; title: "Send a daily summary"
        desc: "One notification with your total and top three apps"
        on: root.usageSummary
        onToggled: { root.usageSummary = !root.usageSummary; root.ulimSave() }
    }
    RowLayout {
        visible: root.usageSummary
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        Text { text: "at"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 30 }
        Repeater {
            model: ["17:00","19:00","21:00","23:00"]
            delegate: Chip {
                required property var modelData
                label: modelData; on: root.usageSummaryTime === modelData
                onPicked: { root.usageSummaryTime = modelData; root.ulimSave() }
            }
        }
        Item { Layout.fillWidth: true }
    }
}
