// "What's using space": walk down through the home folder the way you'd go looking, plus the
// biggest files that are plausibly yours to remove. Files only ever go to the Trash from here.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: panel
    required property var scan
    Layout.fillWidth: true
    spacing: 4

    readonly property string current: scan.folder.path || scan.home
    // A dotted name says little to anyone who hasn't looked inside.
    readonly property var hints: ({
        ".local": "apps, games and their data", ".cache": "caches, see above", ".config": "app settings",
        ".steam": "Steam", ".var": "Flatpak apps", ".cargo": "Rust", ".rustup": "Rust toolchains",
        ".npm": "Node packages", ".mozilla": "Firefox profile"
    })
    readonly property var crumbs: {
        var rel = current === scan.home ? "" : current.substring(scan.home.length + 1);
        var out = [{ name: "Home", path: scan.home }], at = scan.home;
        var parts = rel ? rel.split("/") : [];
        for (var i = 0; i < parts.length; i++) {
            at += "/" + parts[i];
            out.push({ name: parts[i], path: at });
        }
        return out;
    }

    RowLayout {
        Layout.fillWidth: true; spacing: 4
        Repeater {
            model: panel.crumbs
            delegate: RowLayout {
                id: crumb
                required property var modelData
                required property int index
                readonly property bool last: index === panel.crumbs.length - 1
                spacing: 4
                Text { visible: crumb.index > 0; text: "chevron_right"; color: Tok.ink3
                    font.family: "Material Symbols Outlined"; font.pixelSize: 14 }
                Text {
                    text: crumb.modelData.name
                    color: crumb.last ? Tok.ink : Tok.accent
                    font.pixelSize: 12; font.family: Tok.sans; font.weight: crumb.last ? 600 : 500
                    MouseArea { anchors.fill: parent; enabled: !crumb.last
                        cursorShape: crumb.last ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: panel.scan.openFolder(crumb.modelData.path) }
                }
            }
        }
        Text { visible: !!panel.scan.folder.totalSize
            text: "·  " + panel.scan.folder.totalSize; color: Tok.ink3
            font.pixelSize: 12; font.family: Tok.sans; Layout.leftMargin: 4 }
        Item { Layout.fillWidth: true }
        IndBtn { text: "Open in Files"; rank: "ghost"; onActivated: panel.scan.showInFiles(panel.current + "/") }
    }

    Text {
        visible: panel.scan.folder.rows.length === 0
        text: panel.scan.folderBusy ? "Measuring…" : "Nothing large in here."
        color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
    }

    Repeater {
        model: panel.scan.folder.rows
        delegate: Rectangle {
            id: usage
            required property var modelData
            readonly property bool canOpen: modelData.isDir
            Layout.fillWidth: true
            implicitHeight: 36
            radius: Tok.rSmall
            color: usageMouse.containsMouse && canOpen ? Tok.surface : "transparent"
            opacity: panel.scan.folderBusy ? 0.6 : 1
            MouseArea {
                id: usageMouse
                anchors.fill: parent; hoverEnabled: true; enabled: usage.canOpen
                cursorShape: usage.canOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: panel.scan.openFolder(usage.modelData.path)
            }
            ColumnLayout {
                anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4
                anchors.topMargin: 5; anchors.bottomMargin: 5
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Text { text: usage.modelData.name; color: usage.canOpen ? Tok.ink : Tok.ink3
                        font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
                        elide: Text.ElideMiddle; Layout.maximumWidth: 360 }
                    Text { visible: panel.current === panel.scan.home && !!panel.hints[usage.modelData.name]
                        text: panel.hints[usage.modelData.name] || ""
                        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                        elide: Text.ElideRight; Layout.maximumWidth: 240 }
                    Item { Layout.fillWidth: true }
                    Text { text: usage.modelData.size; color: Tok.ink2
                        font.pixelSize: 12; font.family: Tok.mono }
                    Text { text: "chevron_right"; color: usage.canOpen ? Tok.ink3 : "transparent"
                        font.family: "Material Symbols Outlined"; font.pixelSize: 15 }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 4; radius: 2; color: Tok.alpha(Tok.ink, 0.10)
                    Rectangle {
                        height: parent.height; radius: 2
                        width: parent.width * Math.min(1, usage.modelData.pct / 100)
                        color: usage.canOpen ? Tok.accent : Tok.ink3
                        Behavior on width { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
                    }
                }
            }
        }
    }
    Text {
        Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap
        visible: panel.scan.folder.rows.length > 0
        text: "Only your home folder is measured here. These are sizes before compression, so on btrfs they can add up to more than the drive says is used."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }

    // ---- biggest files ----
    Text { visible: panel.scan.files.length > 0; Layout.topMargin: 12
        text: "Biggest files"; color: Tok.ink
        font.pixelSize: 12; font.family: Tok.sans; font.weight: 600 }
    Text { visible: panel.scan.files.length > 0; Layout.fillWidth: true; wrapMode: Text.WordWrap; Layout.bottomMargin: 2
        text: "Moving a file to the Trash doesn't free its space until the Trash is emptied. App data, game files and project dependencies are left off this list."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
    Repeater {
        model: panel.scan.files
        delegate: RowLayout {
            id: file
            required property var modelData
            Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; Layout.topMargin: 3; spacing: 8
            ColumnLayout {
                Layout.fillWidth: true; spacing: 1
                Text { text: file.modelData.name; color: Tok.ink
                    Layout.fillWidth: true; elide: Text.ElideMiddle
                    font.pixelSize: 12; font.family: Tok.sans; font.weight: 500 }
                Text { text: file.modelData.where + "  ·  changed " + file.modelData.age; color: Tok.ink3
                    Layout.fillWidth: true; elide: Text.ElideMiddle
                    font.pixelSize: 11; font.family: Tok.sans }
            }
            Text { text: file.modelData.size; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.mono }
            IndBtn { text: "Show"; rank: "ghost"; onActivated: panel.scan.showInFiles(file.modelData.path) }
            IndBtn { text: "Move to Trash"; rank: "secondary"; onActivated: panel.scan.trash(file.modelData) }
        }
    }
    Text {
        visible: panel.scan.fileNote !== ""
        Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap
        text: panel.scan.fileNote
        color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
    }
}
