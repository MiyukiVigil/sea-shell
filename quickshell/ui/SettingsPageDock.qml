// Settings → Desktop & Dock (macOS Desktop & Dock hub + drill-downs to Window Effects, Rules & Desktop).
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 16
    visible: root.tab === 16
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "dock_to_bottom"
        badgeColor: "#0A84FF"
        title: "Desktop & Dock"
        description: "Customize dock size, position, magnification, app attention, and Hyprland window behavior."
    }

    Section { title: "Dock"; icon: "dock_to_bottom" }
    MacList {
        ToggleCard {
            icon: "apps"; title: "Enable Dock"
            desc: "Show a floating dock for pinned and running apps. Right-click an icon to pin or unpin."
            on: root.apDock; onToggled: { root.apDock = !root.apDock; root.saveAppearance() }
        }
        MacDivider {}
        SliderRow {
            icon: "photo_size_select_large"; label: "Size"
            value: Math.max(0, Math.min(1, (root.apDockIcon - 24) / 40))
            readout: Math.round(root.apDockIcon) + " px"
            onMoved: (v) => { root.apDockIcon = Math.round(24 + v * 40); root.saveAppearance() }
        }
        MacDivider {}
        ToggleCard {
            icon: "zoom_in"; title: "Magnification"
            desc: "Enlarge icons smoothly as the pointer moves across the dock."
            on: root.apDockZoom; onToggled: { root.apDockZoom = !root.apDockZoom; root.saveAppearance() }
        }
    }

    Section { title: "Placement"; icon: "open_with" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Position on screen"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 260; Layout.alignment: Qt.AlignVCenter
                    value: root.apDockEdge
                    model: [
                        { k: "bottom", l: "Bottom" },
                        { k: "left", l: "Left" },
                        { k: "right", l: "Right" },
                        { k: "top", l: "Top" }
                    ]
                    onPicked: (k) => { root.apDockEdge = k; root.saveAppearance() }
                }
            }
        }
        Text {
            visible: root.apDockEdge === root.apEdge
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 8; wrapMode: Text.WordWrap
            text: "The dock and menu bar are both on the " + root.apEdge + " edge and will overlap."
            color: Tok.warn; font.pixelSize: 11; font.family: Tok.sans
        }
    }

    Section { title: "Behaviour"; icon: "visibility" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Visibility"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 270; Layout.alignment: Qt.AlignVCenter
                    value: root.apDockMode
                    model: [
                        { k: "always", l: "Always" },
                        { k: "autohide", l: "Auto-hide" },
                        { k: "intelligent", l: "Smart" }
                    ]
                    onPicked: (k) => { root.apDockMode = k; root.saveAppearance() }
                }
            }
        }
        Text {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 8; wrapMode: Text.WordWrap
            text: root.apDockMode === "always"
                ? "Always visible and reserves its strip so maximized windows stop above it."
                : root.apDockMode === "autohide"
                ? "Automatically hides until you move the pointer to the screen edge."
                : "Stays visible while free and slides away whenever a window moves underneath."
            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
        }
        MacDivider {}
        ToggleCard {
            icon: "playlist_add"; title: "Show open applications in Dock"
            desc: "Display unpinned running applications while their windows are open."
            on: root.apDockRunning; onToggled: { root.apDockRunning = !root.apDockRunning; root.saveAppearance() }
        }
        MacDivider {}
        ToggleCard {
            icon: "label"; title: "Show app names on hover"
            desc: "Show the application name and window count above hovered dock icons."
            on: root.apDockLabels; onToggled: { root.apDockLabels = !root.apDockLabels; root.saveAppearance() }
        }
    }

    Section { title: "Attention"; icon: "notifications_active" }
    MacList {
        ToggleCard {
            icon: "notifications_active"; title: "Animate requesting applications"
            desc: "Pulse the dock icon when an application requests attention."
            on: root.apAttnFlash; onToggled: { root.apAttnFlash = !root.apAttnFlash; root.saveAppearance() }
        }
        MacDivider {}
        ToggleCard {
            icon: "arrow_forward"; title: "Switch workspace on activation"
            desc: "Jump directly to the requesting window even if it lives on another workspace."
            on: root.apAttnFocus; onToggled: { root.apAttnFocus = !root.apAttnFocus; root.saveAppearance() }
        }
    }

    Section { title: "Windows & Desktop"; icon: "view_quilt" }
    MacList {
        MacNavRow {
            icon: "view_quilt"; badgeColor: "#0A84FF"
            title: "Window Effects & Tiling"
            subtitle: "Gaps, borders, corner rounding, blur, shadows, opacity, and focus behavior"
            destination: 35
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "picture_in_picture"; badgeColor: "#5856D6"
            title: "Window Rules"
            subtitle: "Automatic floating, workspace assignment, size, and opacity per app"
            value: root.wrRules.length > 0 ? (root.wrRules.length + " rules") : ""
            destination: 17
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "widgets"; badgeColor: "#30B0C7"
            title: "Desktop Widgets & Hot Corners"
            subtitle: "Configure desktop widgets, wallpaper, and screen corner actions"
            destination: 21
        }
    }
}
