// Settings → General → Backup & Restore. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 33
    visible: root.tab === 33
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "archive"
        badgeColor: "#34C759"
        title: "Backup & Restore"
        description: "Create snapshots of your settings, dock pins, window rules, gestures, keybinds, and bar layouts in ~/Documents."
        note: "Restoring always saves your current configuration first so you can undo."
    }

    Section { title: "Backups"; icon: "archive" }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
        text: root.bkMsg !== "" ? root.bkMsg
            : "Wallpaper image files are not copied into backups, only their folder paths and selections."
        color: root.bkMsg !== "" ? Tok.accent : Tok.ink3
        font.pixelSize: 12; font.family: Tok.sans
    }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        IndBtn { text: "Back up now"; rank: "primary"; onActivated: root.bkCreate() }
        Item { Layout.fillWidth: true }
        Chip { label: "Refresh"; icon: "refresh"; onPicked: root.refreshBackups() }
    }
    IndTable {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 30
        rows: root.bkList
        maxRows: 10
        selectable: true
        emptyText: "No backups yet"
        columns: [
            { label: "Archive", key: "file", flex: true, mono: true },
            { label: "Size",    key: "size", w: 74,  num: true },
            { label: "Created", key: "when", w: 126, mono: true }
        ]
        onActivated: (i, row) => root.bkRestore(row)
    }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
        text: "Click any backup archive above to restore it. Restart the bar afterwards so every surface reloads."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }
}
