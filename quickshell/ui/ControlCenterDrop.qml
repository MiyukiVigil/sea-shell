// sea-shell — Control Center dropdown body (extracted from shell.qml).
// Quick toggles (2x4 grid including Game Mode + Ultra/Hibernate), live Volume & Brightness
// sliders, Power Profile & Fan presets, and Dashboard/Settings shortcuts.
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Column {
    id: cc
    property var shellRoot: null
    property var audioSink: null
    spacing: 10

    DropHeader {
        title: "Quick settings"
        status: shellRoot && shellRoot.gameOn
            ? (shellRoot.cfgSuspendShellGaming ? "Game mode · Zero-shell" : "Game mode · Hibernated")
            : (shellRoot ? (shellRoot.powerProfile === "power-saver" ? "Power saver" : shellRoot.powerProfile === "performance" ? "Performance" : "Balanced") : "")
        tone: shellRoot && shellRoot.gameOn ? "accent" : "neutral"
    }

    // ---- 2x4 quick-toggle tile grid ----
    Grid {
        width: parent.width
        columns: 2
        columnSpacing: 8
        rowSpacing: 8
        Repeater {
            model: [
                { k: "dark",  onI: "dark_mode",         offI: "light_mode",         l: "Dark mode" },
                { k: "caf",   onI: "coffee",            offI: "coffee",             l: "Caffeine" },
                { k: "dnd",   onI: "do_not_disturb_on", offI: "do_not_disturb_off", l: "Do not disturb" },
                { k: "wifi",  onI: "wifi",              offI: "wifi_off",           l: "Wi-Fi" },
                { k: "bt",    onI: "bluetooth",         offI: "bluetooth_disabled", l: "Bluetooth" },
                { k: "night", onI: "nightlight",        offI: "nightlight",         l: "Night light" },
                { k: "game",  onI: "sports_esports",    offI: "sports_esports",     l: "Game mode" },
                { k: "ultra", onI: "bolt",              offI: "bolt",               l: shellRoot && shellRoot.cfgSuspendShellGaming ? "Zero-shell" : "Hibernate" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: modelData.k === "ultra"
                    ? !!(shellRoot && shellRoot.cfgSuspendShellGaming)
                    : !!(shellRoot && shellRoot.ccActive(modelData.k))
                width: (parent.width - 8) / 2
                height: 46
                radius: Tok.r
                color: on
                    ? Tok.alpha(Tok.accent, tileMa.containsMouse ? 0.24 : 0.16)
                    : (tileMa.containsMouse ? Tok.raised : Tok.alpha(Tok.ruleHard, 0.28))
                border.width: 1
                border.color: on ? Tok.alpha(Tok.accent, 0.65) : Tok.alpha(Tok.rule, 0.65)
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                Row {
                    anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 8
                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        text: on ? modelData.onI : modelData.offI
                        sz: 17
                        color: on ? Tok.accent : Tok.ink2
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 25
                        text: modelData.l
                        color: on ? Tok.ink : Tok.ink2
                        font.pixelSize: 12
                        font.family: Tok.sans
                        font.weight: on ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    id: tileMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!shellRoot) return;
                        if (modelData.k === "ultra") shellRoot.toggleSuspendShellGaming();
                        else shellRoot.ccToggle(modelData.k);
                    }
                }
            }
        }
    }

    // ---- quick sliders: Volume + Brightness ----
    Column {
        width: parent.width
        spacing: 6
        // Volume
        Row {
            visible: cc.audioSink !== null
            width: parent.width
            height: 28
            spacing: 8
            Rectangle {
                width: 26; height: 26; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                color: ccVolMa.containsMouse ? Tok.alpha(Tok.accent, 0.14) : "transparent"
                Sym {
                    anchors.centerIn: parent; sz: 16
                    text: (cc.audioSink && cc.audioSink.muted) ? "volume_off" : ((cc.audioSink && cc.audioSink.volume < 0.5) ? "volume_down" : "volume_up")
                    color: (cc.audioSink && cc.audioSink.muted) ? Tok.crit : Tok.ink2
                }
                MouseArea {
                    id: ccVolMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (cc.audioSink) cc.audioSink.muted = !cc.audioSink.muted
                }
            }
            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 26 - 36 - 16
                value: cc.audioSink ? cc.audioSink.volume : 0
                onMoved: (v) => { if (cc.audioSink) { cc.audioSink.muted = false; cc.audioSink.volume = v } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 36; horizontalAlignment: Text.AlignRight
                text: cc.audioSink ? Math.round(cc.audioSink.volume * 100) + "%" : "—"
                color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono
            }
        }
        // Brightness (laptops / DDC backlight)
        Row {
            visible: !!(shellRoot && shellRoot.brMax > 0)
            width: parent.width
            height: 28
            spacing: 8
            Item {
                width: 26; height: 26; anchors.verticalCenter: parent.verticalCenter
                Sym { anchors.centerIn: parent; text: "brightness_6"; sz: 16; color: Tok.ink2 }
            }
            Slider {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 26 - 36 - 16
                value: shellRoot ? Math.max(0.05, shellRoot.brVal) : 0.5
                onMoved: (v) => {
                    var pct = Math.max(5, Math.min(100, Math.round(v * 100)));
                    if (shellRoot) shellRoot.brVal = pct / 100;
                    Quickshell.execDetached(["brightnessctl", "set", pct + "%"]);
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 36; horizontalAlignment: Text.AlignRight
                text: shellRoot ? Math.round(shellRoot.brVal * 100) + "%" : "—"
                color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono
            }
        }
    }

    // ---- Power profile ----
    DropSection { text: "Power profile"; rule: true }
    Row {
        width: parent.width
        spacing: 6
        Repeater {
            model: [
                { k: "power-saver", i: "eco",     l: "Saver" },
                { k: "balanced",    i: "balance", l: "Balanced" },
                { k: "performance", i: "bolt",    l: "Perf" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool sel: !!(shellRoot && shellRoot.powerProfile === modelData.k)
                width: (parent.width - 12) / 3
                height: 40
                radius: Tok.r
                color: sel ? Tok.accent : (ppMa.containsMouse ? Tok.raised : Tok.alpha(Tok.ruleHard, 0.28))
                border.width: sel ? 0 : 1
                border.color: Tok.alpha(Tok.rule, 0.65)
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                Column {
                    anchors.centerIn: parent; spacing: 1
                    Sym { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.i; sz: 15; color: sel ? Tok.accentInk : Tok.ink2 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.l; color: sel ? Tok.accentInk : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans; font.weight: sel ? Font.DemiBold : Font.Normal }
                }
                MouseArea { id: ppMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (shellRoot) shellRoot.setProfile(modelData.k) }
            }
        }
    }

    // ---- Fan preset (when sea-fand / fan curve is available) ----
    DropSection { visible: !!(shellRoot && shellRoot.hasFanCurve); text: "Fans"; note: "used in game mode"; rule: true }
    Row {
        visible: !!(shellRoot && shellRoot.hasFanCurve)
        width: parent.width
        spacing: 6
        Repeater {
            model: [
                { k: "auto",  i: "auto_mode", l: "Auto" },
                { k: "quiet", i: "mode_fan",  l: "Quiet" },
                { k: "max",   i: "speed",     l: "Max" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool sel: !!(shellRoot && shellRoot.fanMode === modelData.k)
                width: (parent.width - 12) / 3
                height: 40
                radius: Tok.r
                color: sel ? Tok.accent : (fnMa.containsMouse ? Tok.raised : Tok.alpha(Tok.ruleHard, 0.28))
                border.width: sel ? 0 : 1
                border.color: Tok.alpha(Tok.rule, 0.65)
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                Column {
                    anchors.centerIn: parent; spacing: 1
                    Sym { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.i; sz: 15; color: sel ? Tok.accentInk : Tok.ink2 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.l; color: sel ? Tok.accentInk : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans; font.weight: sel ? Font.DemiBold : Font.Normal }
                }
                MouseArea { id: fnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (shellRoot) shellRoot.setFanMode(modelData.k) }
            }
        }
    }

    // ---- Footer actions: Dashboard + All settings ----
    Row {
        width: parent.width
        spacing: 8
        Rectangle {
            width: (parent.width - 8) / 2; height: 34; radius: Tok.r
            color: ccDashMa.containsMouse ? Tok.alpha(Tok.accent, 0.16) : Tok.alpha(Tok.ruleHard, 0.28)
            border.width: 1; border.color: Tok.alpha(Tok.rule, 0.65)
            Row { anchors.centerIn: parent; spacing: 6
                Sym { anchors.verticalCenter: parent.verticalCenter; text: "space_dashboard"; sz: 15; color: Tok.ink2 }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Dashboard"; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans } }
            MouseArea { id: ccDashMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: if (shellRoot) { shellRoot.openPop = ""; shellRoot.toggleDash() } }
        }
        Rectangle {
            width: (parent.width - 8) / 2; height: 34; radius: Tok.r
            color: ccSetMa.containsMouse ? Tok.alpha(Tok.accent, 0.16) : Tok.alpha(Tok.ruleHard, 0.28)
            border.width: 1; border.color: Tok.alpha(Tok.rule, 0.65)
            Row { anchors.centerIn: parent; spacing: 6
                Sym { anchors.verticalCenter: parent.verticalCenter; text: "settings"; sz: 15; color: Tok.ink2 }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Settings"; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans } }
            MouseArea { id: ccSetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: if (shellRoot) { shellRoot.openPop = ""; shellRoot.openSettings(0) } }
        }
    }
}
