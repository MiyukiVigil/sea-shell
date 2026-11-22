// Settings → Desktop. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 21
    visible: root.tab === 21; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "wallpaper"
        badgeColor: "#30B0C7"
        title: "Wallpaper & Desktop"
        description: "Pick wallpapers, configure desktop widgets, and assign actions to Hot Corners."
    }

    Section { title: "Wallpaper"; icon: "wallpaper" }
    MacList {
        MacNavRow {
            icon: "photo_library"; badgeColor: "#30B0C7"
            title: "Open Visual Wallpaper Picker"
            subtitle: "Browse your wallpaper library, collections, and video wallpapers"
            onActivated: { root.run("qs -p " + root.repo + "/wallpaper.qml & disown"); root.closePanel() }
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "tune"; badgeColor: "#AF52DE"
            title: "Wallpaper Folder, Transitions & Auto-Rotate"
            subtitle: "Set wallpaper directory, switch effects, day/night pairs, and moving wallpaper options"
            onActivated: { root.apSubTab = 1; root.showTab(4) }
        }
    }

    Section { title: "Arranging"; icon: "drag_pan" }
    Text {
        text: "Drag widgets to arrange them; hold Shift to pin them over busy wallpaper areas."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
    }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Chip {
            label: root.dtEditing ? "Arranging" : "Arrange"
            icon: "drag_pan"
            on: root.dtEditing
            onPicked: {
                root.dtEditing = !root.dtEditing;
                root.dtIpc(root.dtEditing ? "start" : "done");
            }
        }
        Chip {
            label: "Follow wallpaper: " + root.dtAuto
            icon: "auto_awesome_motion"
            on: root.dtAuto !== "off"
            onPicked: {
                var o = ["rescue", "arrange", "off"];
                var i = o.indexOf(root.dtAuto);
                root.dtRun(["--auto", o[(i + 1) % o.length]]);
            }
        }
        Item { Layout.fillWidth: true }
    }

    Section { title: "Hot corners"; icon: "picture_in_picture_alt" }
    Text {
        text: "Rest the pointer in a corner of the screen to open something. Corners are off in games and fullscreen apps, and where two monitors meet."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
    }
    Repeater {
        model: [{ k: "tl", l: "Top left" }, { k: "tr", l: "Top right" },
                { k: "bl", l: "Bottom left" }, { k: "br", l: "Bottom right" }]
        delegate: RowLayout {
            id: cornerRow
            required property var modelData
            readonly property string current: (root.apHotCorners || {})[modelData.k] || ""
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
            Text {
                Layout.preferredWidth: 84
                text: cornerRow.modelData.l
                color: theme.text; font.pixelSize: 12; font.family: Tok.sans
            }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: [{ k: "", l: "Off", i: "block" }, { k: "overview", l: "Overview", i: "grid_view" },
                            { k: "launcher", l: "Launcher", i: "apps" }, { k: "dashboard", l: "Dashboard", i: "space_dashboard" },
                            { k: "notif", l: "Notifications", i: "notifications" }, { k: "widgets", l: "Widgets", i: "widgets" }]
                    delegate: Chip {
                        required property var modelData
                        label: modelData.l; icon: modelData.i
                        on: cornerRow.current === modelData.k
                        onPicked: root.hotCornerSet(cornerRow.modelData.k, modelData.k)
                    }
                }
            }
        }
    }

    Section { title: "On the desktop"; icon: "widgets" }
    Text {
        visible: root.dtItems.length === 0
        text: "Nothing yet"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        Layout.leftMargin: 14
    }
    Repeater {
        model: root.dtItems
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 10
            Text {
                text: ({ "clock": "schedule", "weather": "cloud",
                         "media": "music_note", "system": "monitor_heart",
                         "launch": "apps" })[modelData.kind] || "widgets"
                renderType: Text.NativeRendering; font.family: "Material Symbols Rounded"; font.pixelSize: 16
                color: theme.sub
            }
            Text {
                text: modelData.kind === "launch"
                      ? (modelData.label || "shortcut") : modelData.kind
                color: theme.text; font.pixelSize: 12; font.family: root.apFont
            }
            Text {
                text: modelData.id || ""
                color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            }
            Item { Layout.fillWidth: true }
            // Cycling chips rather than a row of radio groups per
            // widget: five widgets times four axes is twenty
            // controls, and a settings page you have to scroll past
            // is how a customisable thing stops being customised.
            // card / glass / clear: the Material/macOS tile, solid, half
            // see-through, or none; classic: the original read-out
            Chip {
                visible: modelData.kind !== "launch"
                label: modelData.look || "card"
                icon: (modelData.look || "card") === "card" ? "crop_square" : "texture"
                onPicked: {
                    var o = ["card", "glass", "clear", "classic"];
                    var i = o.indexOf(modelData.look || "card");
                    root.dtRun(["--set", "" + modelData.id, "--look", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                visible: modelData.kind === "clock"
                label: modelData.face || "dial"
                icon: "schedule"
                onPicked: {
                    var o = ["dial", "cookie", "digital", "stacked"];
                    var i = o.indexOf(modelData.face || "dial");
                    root.dtRun(["--set", "" + modelData.id,
                                "--face", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                visible: modelData.kind !== "launch"
                label: modelData.ground || "rule"
                icon: "layers"
                onPicked: {
                    var o = ["rule", "panel", "bare"];
                    var i = o.indexOf(modelData.ground || "rule");
                    root.dtRun(["--set", "" + modelData.id,
                                "--ground", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                visible: modelData.kind !== "launch"
                label: modelData.tone || "accent"
                icon: "palette"
                onPicked: {
                    var o = ["accent", "frost", "green", "amber", "red", "plain"];
                    var i = o.indexOf(modelData.tone || "accent");
                    root.dtRun(["--set", "" + modelData.id,
                                "--tone", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                visible: modelData.kind !== "launch"
                label: modelData.align || "left"
                icon: "format_align_left"
                onPicked: {
                    var o = ["left", "centre", "right"];
                    var i = o.indexOf(modelData.align || "left");
                    root.dtRun(["--set", "" + modelData.id,
                                "--align", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                label: modelData.size || "medium"
                icon: "photo_size_select_small"
                onPicked: {
                    var o = ["small", "medium", "large"];
                    var i = o.indexOf(modelData.size || "medium");
                    root.dtRun(["--set", "" + modelData.id,
                                "--size", o[(i + 1) % o.length]]);
                }
            }
            Chip {
                label: modelData.pinned ? "Pinned" : "Free"
                icon: modelData.pinned ? "push_pin" : "open_in_full"
                on: !!modelData.pinned
                onPicked: root.dtRun([modelData.pinned ? "--unpin" : "--pin",
                                      "" + modelData.id])
            }
            Chip {
                label: "Remove"; icon: "close"
                onPicked: root.dtRun(["--remove", "" + modelData.id])
            }
        }
    }

    Section { title: "Add"; icon: "add_circle" }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Repeater {
            model: [{ k: "clock",   l: "clock",   i: "schedule" },
                    { k: "weather", l: "weather", i: "cloud" },
                    { k: "media",   l: "playing", i: "music_note" },
                    { k: "system",  l: "system",  i: "monitor_heart" }]
            delegate: Chip {
                required property var modelData
                label: modelData.l; icon: modelData.i
                onPicked: root.dtRun(["--add-" + modelData.k])
            }
        }
        Item { Layout.fillWidth: true }
    }
    Rectangle {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        height: 30; radius: Tok.r
        color: theme.a(theme.line, 0.45)
        border.width: 1; border.color: theme.a(theme.line, 0.9)
        TextInput {
            id: dtIn
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: theme.text; font.pixelSize: 12; font.family: root.apFont
            selectByMouse: true
            onTextChanged: root.dtQuery = text
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 10
            visible: dtIn.text.length === 0
            text: "Search installed applications"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        }
    }
    Repeater {
        model: root.dtApps
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 10
            IconImage {
                implicitSize: 18
                source: Quickshell.iconPath(modelData.icon, true)
            }
            Text {
                text: modelData.name || ""
                color: theme.text; font.pixelSize: 12; font.family: root.apFont
            }
            Item { Layout.fillWidth: true }
            Chip {
                label: "Add"; icon: "add"
                onPicked: root.dtRun(["--add-entry", "" + modelData.id,
                                      "--label", "" + modelData.name,
                                      "--icon", "" + (modelData.icon || modelData.id)])
            }
        }
    }
}
