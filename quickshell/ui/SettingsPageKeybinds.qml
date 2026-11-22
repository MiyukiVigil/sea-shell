// Settings → Keyboard (macOS-style typing, layout, modifier keys + Keybinds editor).
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: kbPage
    property int tabIdx: 7
    visible: root.tab === 7
    Layout.fillWidth: true
    spacing: 14

    readonly property var kbLayouts: [
        { k: "us", l: "US English" },
        { k: "gb", l: "UK English" },
        { k: "de", l: "German" },
        { k: "fr", l: "French" },
        { k: "es", l: "Spanish" },
        { k: "jp", l: "Japanese" },
        { k: "kr", l: "Korean" },
        { k: "pl", l: "Polish" }
    ]

    readonly property var capsModes: [
        { k: "", l: "Caps Lock" },
        { k: "caps:escape", l: "Escape" },
        { k: "caps:ctrl_modifier", l: "Control" },
        { k: "ctrl:swapcaps", l: "Swap Ctrl" }
    ]

    MacHeaderCard {
        icon: "keyboard"
        badgeColor: "#636366"
        title: "Keyboard"
        description: "Adjust key repeat speed, keyboard layout, Caps Lock behavior, and custom Hyprland keyboard shortcuts."
    }

    Section { title: "Typing"; icon: "speed" }
    MacList {
        SliderRow {
            icon: "fast_forward"; label: "Key repeat rate"
            value: Math.max(0, Math.min(1, ((root.compCfg.repeat_rate || 25) - 10) / 70))
            readout: (root.compCfg.repeat_rate || 25) + " /s"
            onMoved: (v) => root.setCompositor({ repeat_rate: Math.round(10 + v * 70) })
        }
        MacDivider {}
        SliderRow {
            icon: "hourglass_empty"; label: "Delay until repeat"
            value: Math.max(0, Math.min(1, ((root.compCfg.repeat_delay || 600) - 150) / 850))
            readout: (root.compCfg.repeat_delay || 600) + " ms"
            onMoved: (v) => root.setCompositor({ repeat_delay: Math.round((150 + v * 850) / 25) * 25 })
        }
        MacDivider {}
        ToggleCard {
            icon: "pin"
            title: "Num Lock on startup"
            desc: "Enable the numeric keypad automatically when Hyprland starts."
            on: root.compCfg.numlock_by_default !== false
            onToggled: root.setCompositor({ numlock_by_default: root.compCfg.numlock_by_default === false })
        }
    }

    Section { title: "Input Source & Modifier Keys"; icon: "language" }
    MacList {
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10; Layout.bottomMargin: 10; spacing: 8
            Text { text: "Keyboard layout"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: kbPage.kbLayouts
                    delegate: Chip {
                        required property var modelData
                        label: modelData.l
                        on: (root.compCfg.kb_layout || "us") === modelData.k
                        onPicked: root.setCompositor({ kb_layout: modelData.k })
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
                Text { text: "Custom layout"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 28; radius: 7
                    color: Tok.bg; border.width: 1; border.color: customLayIn.activeFocus ? Tok.accent : root.cardBorder
                    TextInput {
                        id: customLayIn
                        anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; clip: true
                        text: root.compCfg.kb_layout || "us"
                        onEditingFinished: if (text.trim() !== "") root.setCompositor({ kb_layout: text.trim() })
                    }
                }
            }
        }
        MacDivider {}
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10; Layout.bottomMargin: 10; spacing: 8
            Text { text: "Caps Lock key"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            MacSegmented {
                value: root.compCfg.kb_options || ""
                model: kbPage.capsModes
                onPicked: (k) => root.setCompositor({ kb_options: k })
            }
        }
    }

    Section { title: "Keybinds"; icon: "keyboard" }
    ColumnLayout {
        readonly property bool edgeToEdge: true
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; Layout.bottomMargin: 6; spacing: 10
        RowLayout {
            spacing: 8; Layout.fillWidth: true
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 32; radius: 8
                color: Tok.bg
                border.width: 1; border.color: kbField.activeFocus ? Tok.accent : root.cardBorder
                Sym {
                    id: kbLens; text: "search"; sz: 15; color: Tok.ink3
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                }
                TextInput {
                    id: kbField
                    anchors { left: kbLens.right; leftMargin: 8; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                    onTextChanged: root.kbQuery = text
                    Text {
                        text: "Filter shortcuts · click any row to rebind"
                        visible: kbField.text === ""
                        color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Escape) { root.closePanel(); e.accepted = true; }
                    }
                }
            }
            Chip { label: "Add shortcut"; icon: "add"; onPicked: root.kbOpenAdd() }
        }

        IndTable {
            Layout.fillWidth: true
            rowHeight: 30
            selectable: true
            rows: root.kbShown
            emptyText: root.kbQuery !== "" ? "No shortcut matches that filter" : "—"
            columns: [
                { label: "Action",  key: "desc", flex: true },
                { label: "Shortcut", key: "keys", w: 200, chip: true, num: true, toneKey: "_tone" }
            ]
            onActivated: (i, row) => { if (row.canEdit) root.kbOpenEdit(row) }
        }
        Text {
            Layout.fillWidth: true; elide: Text.ElideRight
            text: root.kbShown.length + " of " + root.kbBinds.length + " shortcuts · edits update keybinds.lua and reload Hyprland"
            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
        }
    }
}
