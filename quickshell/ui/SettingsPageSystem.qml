// Settings → General (macOS System Settings hub with drill-down sub-panes).
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 8
    visible: root.tab === 8
    Layout.fillWidth: true
    spacing: 14
    Component.onCompleted: attention.refresh()
    onVisibleChanged: if (visible) attention.refresh()

    MacHeaderCard {
        icon: "settings"
        badgeColor: "#8E8E93"
        title: "General"
        description: "Manage your overall setup and preferences for this machine, including system info, updates, storage, startup items, date and time, and backups."
    }

    // Only shown when there are actionable attention items
    Section { title: "Needs attention"; icon: "notifications_active"; visible: attention.rows.length > 0 }
    AttentionPanel {
        visible: attention.rows.length > 0
        list: attention
        onOpenTab: tab => root.openTab(tab)
    }

    // Primary macOS General drill-down list
    Section { title: "General"; icon: "settings" }
    MacList {
        MacNavRow {
            icon: "info"; badgeColor: "#8E8E93"
            title: "About"
            value: root.sysInfo.host || root.sysInfo.os || ""
            destination: 28
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "system_update_alt"; badgeColor: "#8E8E93"
            title: "Software Update"
            value: "v" + root.seaVersion
            destination: 29
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "hard_drive"; badgeColor: "#8E8E93"
            title: "Storage"
            value: root.diskRootPct >= 0 ? (root.diskRootPct + "% used") : ""
            destination: 19
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "rocket_launch"; badgeColor: "#8E8E93"
            title: "Login Items & Startup"
            value: root.startupApps.length > 0 ? (root.startupApps.filter(function(a) { return a.enabled }).length + " enabled") : ""
            destination: 30
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "schedule"; badgeColor: "#8E8E93"
            title: "Date & Time"
            value: root.dtInfo.timezone || ""
            destination: 31
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "language"; badgeColor: "#8E8E93"
            title: "Language & Region"
            value: root.localeInfo.lang || ""
            destination: 32
        }
    }

    // Maintenance & Recovery group
    Section { title: "Maintenance & Recovery"; icon: "build" }
    MacList {
        MacNavRow {
            icon: "archive"; badgeColor: "#34C759"
            title: "Backup & Restore"
            subtitle: "Snapshots of your sea-shell settings, keybinds, and layouts"
            value: root.bkList.length > 0 ? (root.bkList.length + " saved") : ""
            destination: 33
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "stethoscope"; badgeColor: "#30B0C7"
            title: "Health Check"
            subtitle: "Verify dependencies, Hyprland config, and bar stability"
            destination: 34
        }
        MacDivider { insetLeft: 58 }
        MacNavRow {
            icon: "bolt"; badgeColor: "#FF9500"
            title: "Quick Actions"
            subtitle: "Reload Hyprland, restart bar, welcome tour, export theme"
            destination: 5
        }
    }
}
