// Settings → Actions. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 5
    visible: root.tab === 5; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "bolt"
        badgeColor: "#FF9500"
        title: "Quick Actions"
        description: "One-click maintenance actions, shell restarts, wallpaper picker, config folders, and theme export."
    }

    Section { title: "Quick actions"; icon: "bolt" }
    GridLayout {
        columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
        Row2 { icon: "refresh"; label: "Reload Hyprland"; cmd: "hyprctl reload"; quitAfter: true }
        Row2 { icon: "restart_alt"; label: "Restart bar"; cmd: "sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"; quitAfter: true }
        Row2 { icon: "terminal"; label: "Terminal"; cmd: "kitty & disown"; quitAfter: true }
        Row2 { icon: "wallpaper"; label: "Wallpapers"; cmd: "qs -p " + root.repo + "/wallpaper.qml & disown"; quitAfter: true }
        // The first-run tour, on demand. It shows itself once on a
        // fresh install and is otherwise unreachable — which for a
        // screen that explains where things are is the wrong way round.
        Row2 { icon: "auto_awesome"; label: "Show the welcome tour again"
               cmd: "qs -c sea-shell ipc call welcome open"; quitAfter: true }
        Row2 { icon: "content_paste"; label: "Clipboard history"; cmd: "qs -c sea-shell ipc call launcher clipboard"; quitAfter: true }
        Row2 { icon: "photo_camera"; label: "Screenshot region"; cmd: "sleep 0.2; grim -g \"$(slurp)\" - | wl-copy"; quitAfter: true }
        Row2 { icon: "keyboard"; label: "Keybinds editor"; cmd: "qs -p " + root.repo + "/keybinds.qml & disown"; quitAfter: true }
        Row2 { icon: "edit_note"; label: "Edit keybinds"; cmd: "xdg-open \"$(dirname \"$(readlink -f ~/.config/quickshell/sea-shell)\")/hypr/keybinds.conf\" & disown"; quitAfter: true }
        Row2 { icon: "settings"; label: "Edit configs"; cmd: "kitty --directory " + root.repo + "/.. & disown"; quitAfter: true }
        Row2 { icon: "palette"; label: "Export theme pack"
               cmd: "a=$(sh \"$HOME/.config/quickshell/sea-shell/sea-theme-export.sh\" 2>/dev/null); notify-send \"Theme exported\" \"${a:-Saved to Downloads}\"" }
    }
}
