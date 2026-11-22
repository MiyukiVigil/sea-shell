// Settings → Desktop & Dock → Window Effects & Tiling. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 35
    visible: root.tab === 35
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "view_quilt"
        badgeColor: "#0A84FF"
        title: "Window Effects & Tiling"
        description: "Tune Hyprland gaps, borders, rounded corners, blur, drop shadows, and window focus behavior live."
        note: "Applied immediately to Hyprland and saved to ~/.config/hypr/sea-shell/compositor.lua."
    }

    Section { title: "Gaps & Geometry"; icon: "grid_view" }
    MacList {
        SliderRow {
            icon: "space_dashboard"; label: "Inner gaps"
            value: Math.max(0, Math.min(1, (root.compCfg.gaps_in !== undefined ? root.compCfg.gaps_in : 5) / 32))
            readout: (root.compCfg.gaps_in !== undefined ? root.compCfg.gaps_in : 5) + " px"
            onMoved: (v) => root.setCompositor({ gaps_in: Math.round(v * 32) })
        }
        MacDivider {}
        SliderRow {
            icon: "fit_screen"; label: "Outer gaps"
            value: Math.max(0, Math.min(1, (root.compCfg.gaps_out !== undefined ? root.compCfg.gaps_out : 12) / 48))
            readout: (root.compCfg.gaps_out !== undefined ? root.compCfg.gaps_out : 12) + " px"
            onMoved: (v) => root.setCompositor({ gaps_out: Math.round(v * 48) })
        }
        MacDivider {}
        SliderRow {
            icon: "border_style"; label: "Border width"
            value: Math.max(0, Math.min(1, (root.compCfg.border_size !== undefined ? root.compCfg.border_size : 2) / 6))
            readout: (root.compCfg.border_size !== undefined ? root.compCfg.border_size : 2) + " px"
            onMoved: (v) => root.setCompositor({ border_size: Math.round(v * 6) })
        }
        MacDivider {}
        SliderRow {
            icon: "rounded_corner"; label: "Corner radius"
            value: Math.max(0, Math.min(1, (root.compCfg.rounding !== undefined ? root.compCfg.rounding : 10) / 24))
            readout: (root.compCfg.rounding !== undefined ? root.compCfg.rounding : 10) + " px"
            onMoved: (v) => root.setCompositor({ rounding: Math.round(v * 24) })
        }
    }

    Section { title: "Blur, Shadows & Opacity"; icon: "blur_on" }
    MacList {
        ToggleCard {
            icon: "blur_on"
            title: "Window & layer blur"
            desc: "Enable frosted glass blur behind translucent surfaces and windows."
            on: root.compCfg.blur_enabled !== false
            onToggled: root.setCompositor({ blur_enabled: root.compCfg.blur_enabled === false })
        }
        SliderRow {
            visible: root.compCfg.blur_enabled !== false
            icon: "blur_circular"; label: "Blur radius"
            value: Math.max(0, Math.min(1, ((root.compCfg.blur_size || 9) - 1) / 17))
            readout: (root.compCfg.blur_size || 9) + " px"
            onMoved: (v) => root.setCompositor({ blur_size: Math.round(1 + v * 17) })
        }
        SliderRow {
            visible: root.compCfg.blur_enabled !== false
            icon: "layers"; label: "Blur passes"
            value: Math.max(0, Math.min(1, ((root.compCfg.blur_passes || 4) - 1) / 5))
            readout: (root.compCfg.blur_passes || 4) + "×"
            onMoved: (v) => root.setCompositor({ blur_passes: Math.round(1 + v * 5) })
        }
        MacDivider {}
        ToggleCard {
            icon: "shadow"
            title: "Window drop shadows"
            desc: "Soft depth shadow around floating and tiled windows."
            on: root.compCfg.shadow_enabled !== false
            onToggled: root.setCompositor({ shadow_enabled: root.compCfg.shadow_enabled === false })
        }
        MacDivider {}
        SliderRow {
            icon: "opacity"; label: "Inactive opacity"
            value: Math.max(0, Math.min(1, ((root.compCfg.inactive_opacity || 0.96) - 0.6) / 0.4))
            readout: Math.round((root.compCfg.inactive_opacity || 0.96) * 100) + "%"
            onMoved: (v) => root.setCompositor({ inactive_opacity: Math.round((0.6 + v * 0.4) * 100) / 100 })
        }
        MacDivider {}
        ToggleCard {
            icon: "animation"
            title: "Compositor animations"
            desc: "Smooth open, close, and workspace-switch animations."
            on: root.compCfg.animations_enabled !== false
            onToggled: root.setCompositor({ animations_enabled: root.compCfg.animations_enabled === false })
        }
    }

    Section { title: "Window Focus"; icon: "ads_click" }
    MacList {
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10; Layout.bottomMargin: 10; spacing: 8
            MacSegmented {
                value: root.compCfg.follow_mouse !== undefined ? root.compCfg.follow_mouse : 1
                model: [
                    { k: 0, l: "Click to focus" },
                    { k: 1, l: "Follow cursor" },
                    { k: 2, l: "Loose follow" }
                ]
                onPicked: (k) => root.setCompositor({ follow_mouse: k })
            }
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: (root.compCfg.follow_mouse === 0)
                    ? "Click a window to focus it, like macOS."
                    : (root.compCfg.follow_mouse === 2)
                    ? "Cursor movement focuses windows without switching keyboard focus until clicked."
                    : "Moving the pointer over a window immediately gives it focus."
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
            }
        }
    }
}
