// Settings → Power. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 6
    visible: root.tab === 6; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "battery_charging_full"
        badgeColor: "#34C759"
        title: "Battery & Power"
        description: "Monitor battery charge and wear health, switch power profiles, set laptop lid behavior, and manage session power."
    }

    Section { title: "Battery"; icon: "battery_full" }
    RowLayout {
        Layout.fillWidth: true; spacing: 10
        visible: UPower.displayDevice && UPower.displayDevice.isLaptopBattery
        Sym { text: UPower.onBattery ? "battery_5_bar" : "battery_charging_full"; sz: 18
            color: UPower.onBattery && UPower.displayDevice.percentage < 0.2 ? theme.bad : theme.good }
        Rectangle { Layout.fillWidth: true; implicitHeight: 8; radius: Tok.r; color: theme.a(theme.line, 0.8)
            Rectangle { height: parent.height; radius: Tok.r
                width: parent.width * (UPower.displayDevice ? UPower.displayDevice.percentage : 0)
                color: UPower.onBattery && UPower.displayDevice.percentage < 0.2 ? theme.bad : theme.good } }
        Text { text: UPower.displayDevice ? Math.round(UPower.displayDevice.percentage * 100) + "%" + (UPower.onBattery ? "" : " ⚡") : ""
            color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }
    }

    // ---- health / wear ----
    // Charge % says how full the pack is; THIS says how much pack is
    // left to fill. UPower doesn't expose it, so it comes from sysfs.
    Section { visible: !!root.battHealth.present; title: "Health"; icon: "health_and_safety" }
    RowLayout {
        visible: !!root.battHealth.present
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 24
        IndKpi {
            label: "Capacity"
            value: "" + (root.battHealth.pct || 0)
            unit: "%"
            size: Tok.tKpi
            sub: "Of design"
            // a pack under ~80% of design is meaningfully worn; under 60% is near replacement
            tone: (root.battHealth.pct || 0) < 60 ? "crit"
                : (root.battHealth.pct || 0) < 80 ? "warn" : "ok"
        }
        IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
        IndKpi {
            label: "Cycles"
            value: (root.battHealth.cycles || 0) > 0 ? "" + root.battHealth.cycles : "—"
            size: Tok.tKpi
            sub: (root.battHealth.cycles || 0) > 0 ? "Charge cycles" : "Not reported"
        }
        IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
        IndKpi {
            label: "Pack"
            value: root.battHealth.model || "—"
            size: Tok.tPanel
            sub: [root.battHealth.vendor,
                  root.battHealth.design > 0
                    ? Math.round(root.battHealth.design / 1000) + " mAh design" : ""]
                 .filter(function (x) { return x }).join("  ·  ")
        }
        Item { Layout.fillWidth: true }
    }

    Text { text: "Power profile"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
    MacSegmented {
        value: root.powerProfile
        model: [
            { k: "power-saver", i: "eco",     l: "Power Saver" },
            { k: "balanced",    i: "balance", l: "Balanced" },
            { k: "performance", i: "speed",   l: "Performance" }
        ]
        onPicked: (k) => root.setProfile(k)
    }
    ToggleCard {
        icon: "auto_awesome"
        title: "Auto battery saver"
        desc: "Switch to Power Saver and 60 Hz when unplugged, and restore Balanced + full refresh rate on AC (paused during Game Mode)"
        on: root.apAutoPowerBattery
        onToggled: { root.apAutoPowerBattery = !root.apAutoPowerBattery; root.saveAppearance() }
    }
    Section { title: "Laptop lid action"; icon: "laptop" }
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Repeater {
            model: [
                {l:"Suspend",  v:"suspend",   i:"bedtime"},
                {l:"Lock",     v:"lock",      i:"lock"},
                {l:"Screen Off",v:"dpms",     i:"settings_brightness"},
                {l:"Hibernate",v:"hibernate", i:"save_as"},
                {l:"Shut down",v:"shutdown",  i:"power_settings_new"},
                {l:"Ignore",   v:"ignore",    i:"block"}
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool cur: root.lockLidAction === modelData.v
                Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                color: cur ? theme.a(theme.iris, 0.2) : (ppmLid.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                RowLayout { anchors.centerIn: parent; spacing: 6
                    Sym { text: modelData.i; sz: 15; color: cur ? theme.iris : theme.frost }
                    Text { text: modelData.l; color: cur ? theme.frost : theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: cur } }
                MouseArea { id: ppmLid; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.lockLidAction = modelData.v;
                        root.saveLockSettings();
                        root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"; hyprctl reload");
                    }
                }
            }
        }
    }
    Section { title: "Session"; icon: "power_settings_new" }
    GridLayout {
        columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
        Row2 { icon: "lock"; label: "Lock"; cmd: "~/.config/quickshell/sea-shell/sea-lock.sh"; quitAfter: true }
        Row2 { icon: "bedtime"; label: "Suspend"; cmd: "systemctl suspend"; quitAfter: true }
        Row2 { icon: "logout"; label: "Logout"; cmd: "systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }"; quitAfter: true }
        Row2 { icon: "restart_alt"; label: "Reboot"; cmd: "systemctl reboot"; tint: theme.bad; quitAfter: true }
        Row2 { icon: "power_settings_new"; label: "Shutdown"; cmd: "systemctl poweroff"; tint: theme.bad; quitAfter: true }
    }
}
