// Settings → Accessibility. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 26
    visible: root.tab === 26
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "accessibility_new"
        badgeColor: "#007AFF"
        title: "Accessibility"
        description: "Make the desktop easier to see, read, and navigate by reducing motion or transparency, enlarging the pointer, or zooming the screen."
    }

    Section { title: "Vision & Display"; icon: "visibility" }
    MacList {
        ToggleCard {
            icon: "layers_clear"
            title: "Reduce transparency"
            desc: "Use solid surfaces on the menu bar, dropdowns, notifications, and dock instead of frosted blur."
            on: root.apGlass === "solid"
            onToggled: {
                root.apGlass = (root.apGlass === "solid") ? "frosted" : "solid";
                root.saveAppearance();
            }
        }
        MacDivider {}
        ToggleCard {
            icon: "aspect_ratio"
            title: "Auto interface scale"
            desc: "Automatically size the shell for each display resolution (scales up on 4K screens)."
            on: root.apScale === 0
            onToggled: {
                root.apScale = (root.apScale === 0) ? Math.max(1.0, root.autoScaleEstimate()) : 0;
                root.saveAppearance();
            }
        }
        SliderRow {
            visible: root.apScale > 0
            icon: "zoom_out_map"; label: "Interface scale"
            value: (root.apScale - 0.75) / 1.75
            readout: root.apScale.toFixed(2) + "×"
            onMoved: (v) => {
                root.apScale = Math.round((0.75 + v * 1.75) * 20) / 20;
                root.saveAppearance();
            }
        }
        MacDivider {}
        SliderRow {
            icon: "arrow_selector_tool"; label: "Pointer size"
            value: Math.max(0, Math.min(1, ((root.compCfg.cursor_size || 24) - 16) / 48))
            readout: (root.compCfg.cursor_size || 24) + " px"
            onMoved: (v) => root.setCompositor({ cursor_size: Math.round(16 + v * 48) })
        }
    }

    Section { title: "Zoom"; icon: "zoom_in" }
    MacList {
        SliderRow {
            icon: "search"; label: "Screen zoom"
            value: Math.max(0, Math.min(1, ((root.compCfg.zoom_factor || 1.0) - 1.0) / 2.0))
            readout: (root.compCfg.zoom_factor || 1.0).toFixed(2) + "×"
            onMoved: (v) => root.setCompositor({ zoom_factor: Math.round((1.0 + v * 2.0) * 20) / 20 })
        }
        Item {
            visible: (root.compCfg.zoom_factor || 1.0) > 1.01
            Layout.fillWidth: true; implicitHeight: 40
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                Text { text: "Zoom follows the cursor across the active display."; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                Chip { label: "Reset to 1.0×"; icon: "restart_alt"; Layout.alignment: Qt.AlignVCenter; onPicked: root.setCompositor({ zoom_factor: 1.0 }) }
            }
        }
    }

    Section { title: "Motion"; icon: "motion_photos_off" }
    MacList {
        ToggleCard {
            icon: "animation"
            title: "Reduce shell motion"
            desc: "Minimize movement and show panels, menus, and transitions immediately."
            on: root.apReducedMotion
            onToggled: { root.apReducedMotion = !root.apReducedMotion; root.saveAppearance() }
        }
        MacDivider {}
        ToggleCard {
            icon: "crop_free"
            title: "Window & workspace animations"
            desc: "Turn off Hyprland compositor animations for instant window opening and workspace switching."
            on: root.compCfg.animations_enabled !== false
            onToggled: root.setCompositor({ animations_enabled: root.compCfg.animations_enabled === false })
        }
    }
}
