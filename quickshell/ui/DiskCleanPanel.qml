// "Free up space": what could go, what it costs, and a two-step button, because nothing here
// comes back. Rows are grouped by the cost of clearing them, and only the free group starts ticked.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: panel
    required property var scan
    property bool confirming: false
    Layout.fillWidth: true
    spacing: 8

    readonly property var tiers: [
        { id: "safe", title: "Safe to clear", note: "You won't notice these are gone." },
        { id: "space", title: "Clear if you need the room", note: "Nothing breaks, but each has a cost. Read what it says first." }
    ]

    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: panel.scan.cleaning ? "Clearing…"
                : panel.scan.items.length === 0
                    ? (panel.scan.scanning ? "Looking through your drive…" : "Nothing here is worth clearing right now.")
                : "Up to " + panel.scan.human(panel.scan.clearableBytes) + " could be cleared."
                  + (panel.scan.scanning ? " Still looking…" : "")
            color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
        }
        IndBtn {
            text: panel.scan.scanning ? "Scanning…" : "Scan again"; rank: "ghost"
            enabled: !panel.scan.scanning && !panel.scan.cleaning
            onActivated: panel.scan.rescan()
        }
    }

    Repeater {
        model: panel.tiers
        delegate: ColumnLayout {
            id: tier
            required property var modelData
            readonly property var rows: panel.scan.tierItems(modelData.id)
            visible: rows.length > 0
            Layout.fillWidth: true; Layout.topMargin: 6
            spacing: 2

            Text { text: tier.modelData.title; color: Tok.ink
                font.pixelSize: 12; font.family: Tok.sans; font.weight: 600 }
            Text { text: tier.modelData.note; color: Tok.ink3
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                font.pixelSize: 11; font.family: Tok.sans; Layout.bottomMargin: 4 }

            Repeater {
                model: tier.rows
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool busy: !!modelData.busy
                    readonly property bool ticked: !!panel.scan.selected[modelData.id] && !busy
                    readonly property var result: panel.scan.rowState[modelData.id]
                    readonly property bool hasProblem: !!result && (result.state === "failed" || result.state === "skipped" || result.state === "partial")
                    Layout.fillWidth: true
                    implicitHeight: body.implicitHeight + 12
                    radius: Tok.rSmall
                    color: rowMouse.containsMouse && !busy ? Tok.surface : "transparent"

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent; hoverEnabled: true
                        enabled: !row.busy && !panel.scan.cleaning
                        cursorShape: row.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: { panel.confirming = false; panel.scan.toggle(row.modelData.id) }
                    }
                    RowLayout {
                        id: body
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 4; anchors.rightMargin: 4
                        spacing: 10
                        Rectangle {
                            implicitWidth: 18; implicitHeight: 18; radius: Tok.rSmall
                            Layout.alignment: Qt.AlignTop; Layout.topMargin: 1
                            opacity: row.busy ? 0.4 : 1
                            color: row.ticked ? Tok.accent : "transparent"
                            border.width: row.ticked ? 0 : 1; border.color: Tok.ruleHard
                            Text { anchors.centerIn: parent; visible: row.ticked; text: "check"
                                color: Tok.accentInk; font.family: "Material Symbols Outlined"; font.pixelSize: 15 }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text { text: row.modelData.title; color: row.busy ? Tok.ink3 : Tok.ink
                                    font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
                                    elide: Text.ElideMiddle; Layout.maximumWidth: body.width - 150 }
                                Text { visible: !!row.modelData.admin; text: "lock"; color: Tok.ink3
                                    font.family: "Material Symbols Outlined"; font.pixelSize: 13 }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: row.result && row.result.state === "working" ? "Clearing…"
                                    : row.hasProblem && row.result.note ? row.result.note
                                    : row.busy ? row.modelData.busy + " " + row.modelData.desc
                                    : row.modelData.desc
                                color: row.hasProblem ? Tok.warn : Tok.ink3
                                font.pixelSize: 11; font.family: Tok.sans
                            }
                        }
                        Text { text: row.modelData.size; color: row.busy ? Tok.ink3 : Tok.ink2
                            Layout.alignment: Qt.AlignTop
                            font.pixelSize: 12; font.family: Tok.mono }
                    }
                }
            }
        }
    }

    // Two steps, and the second states the consequence in the place you are about to click.
    RowLayout {
        visible: panel.scan.items.length > 0 && !panel.confirming
        Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: panel.scan.chosen.length === 0 ? "Tick what you want gone."
                : panel.scan.chosen.length + (panel.scan.chosen.length === 1 ? " item" : " items") + " ticked"
            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
        }
        IndBtn {
            rank: "primary"
            text: panel.scan.cleaning ? "Clearing…"
                : panel.scan.chosen.length === 0 ? "Clear" : "Clear up to " + panel.scan.human(panel.scan.chosenBytes)
            enabled: panel.scan.chosen.length > 0 && !panel.scan.cleaning
            onActivated: panel.confirming = true
        }
    }
    Rectangle {
        visible: panel.confirming
        Layout.fillWidth: true; Layout.topMargin: 6
        implicitHeight: confirmRow.implicitHeight + 16
        radius: Tok.rSmall
        color: Tok.critWash
        RowLayout {
            id: confirmRow
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 10; anchors.rightMargin: 8
            spacing: 8
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: "Permanently delete " + panel.scan.chosen.length + (panel.scan.chosen.length === 1 ? " item" : " items")
                      + "? This can't be undone."
                      + (panel.scan.chosenHasTrash ? " That includes everything in your Trash." : "")
                      + (panel.scan.chosenNeedsAdmin ? " Items with a lock will ask for your password." : "")
                color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
            }
            IndBtn { text: "Keep them"; rank: "secondary"; onActivated: panel.confirming = false }
            IndBtn { text: "Delete"; rank: "danger"
                onActivated: { panel.confirming = false; panel.scan.clean() } }
        }
    }
    Text {
        visible: panel.scan.summary !== ""
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: panel.scan.summary
        color: Tok.ok; font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
    }
    Text {
        visible: panel.scan.items.length > 0
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: "Sizes are the most you'd get back. Btrfs compresses files, so the real figure is often lower, and it's what's shown once clearing is done."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }
}
