// Settings → Gaming. Default launch profiles and bar behavior while playing.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 25
    visible: root.tab === 25
    Layout.fillWidth: true
    spacing: 14

    readonly property string gamingScript: Qt.resolvedUrl("sea-gaming.py").toString().replace("file://", "")
    property var gameDefaults: ({ gamemode: true, game_mode_on_play: true, mangohud: false, gamescope: "" })
    property string gamingFan: "custom"
    property string hudConfText: ""

    function reloadDefaults() { gameDefProc.running = true }
    function patchDefaults(patch) {
        var merged = Object.assign({}, gameDefaults, patch);
        gameDefaults = merged;
        Quickshell.execDetached(["python3", gamingScript, "defaults-patch", JSON.stringify(patch)]);
    }
    function gamescopeKey(scope) {
        scope = scope || "";
        if (scope.indexOf("-f") >= 0) return "1080p";
        if (scope.indexOf("-w") >= 0) return "1080p-windowed";
        return scope.length ? "custom" : "";
    }
    function setGamingFan(mode) {
        gamingFan = mode;
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p \"$HOME/.config/sea-shell\" && printf '%s\\n' '" + mode.replace(/'/g, "'\\''") + "' > \"$HOME/.config/sea-shell/gaming-fans\""]);
        Quickshell.execDetached(["sh", "-c", "~/.config/quickshell/sea-shell/sea-perf.sh " + mode]);
    }
    function parseMangohud(text) {
        var o = {
            horizontal: false, fpsOnly: false, showFps: false, frametime: false,
            cpu: false, cpuTemp: false, gpu: false, gpuTemp: false, gpuPower: false,
            vram: false, ram: false, position: "top-left", alpha: 0.5, radius: 0,
            fpsLimit: "", found: false
        };
        if (!text || !String(text).trim()) return o;
        o.found = true;
        var lines = String(text).split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].replace(/#.*/, "").trim();
            if (!line) continue;
            var eq = line.indexOf("=");
            var key = (eq >= 0 ? line.substring(0, eq) : line).trim();
            var val = eq >= 0 ? line.substring(eq + 1).trim() : "1";
            if (key === "horizontal") o.horizontal = val !== "0";
            else if (key === "fps_only") o.fpsOnly = val !== "0";
            else if (key === "fps") o.showFps = val !== "0";
            else if (key === "frametime") o.frametime = val !== "0";
            else if (key === "cpu_stats") o.cpu = val !== "0";
            else if (key === "cpu_temp") o.cpuTemp = val !== "0";
            else if (key === "gpu_stats") o.gpu = val !== "0";
            else if (key === "gpu_temp") o.gpuTemp = val !== "0";
            else if (key === "gpu_power") o.gpuPower = val !== "0";
            else if (key === "vram") o.vram = val !== "0";
            else if (key === "ram") o.ram = val !== "0";
            else if (key === "position" && val) o.position = val;
            else if (key === "background_alpha") {
                var a = parseFloat(val);
                if (!isNaN(a)) o.alpha = Math.max(0.4, Math.min(0.85, a));
            }
            else if (key === "round_corners") {
                var r = parseInt(val, 10);
                if (!isNaN(r)) o.radius = Math.max(0, Math.min(12, r));
            }
            else if (key === "fps_limit" && val) o.fpsLimit = val.split(",")[0].trim();
        }
        return o;
    }
    function buildHudPreview() {
        var look = "" + (gameDefaults.mh_look || "");
        var corner = "" + (gameDefaults.mh_corner || "");
        var fpsSel = "" + (gameDefaults.mh_fps || "");
        var src = parseMangohud(hudConfText);
        var horizontal = src.horizontal;
        var fpsOnly = src.fpsOnly;
        var alpha = src.found ? src.alpha : 0.5;
        var radius = src.radius;
        var position = src.position || "top-left";
        var limit = src.fpsLimit;
        var f = {
            showFps: src.showFps, frametime: src.frametime, cpu: src.cpu, cpuTemp: src.cpuTemp,
            gpu: src.gpu, gpuTemp: src.gpuTemp, gpuPower: src.gpuPower, vram: src.vram, ram: src.ram
        };
        var lookName = src.found ? "your config" : "a basic readout";
        if (look === "fps") {
            lookName = "FPS only";
            fpsOnly = true; horizontal = false; alpha = 0.5; radius = 8;
        } else if (look === "compact") {
            lookName = "compact";
            fpsOnly = false; horizontal = true; alpha = 0.5; radius = 0;
            f = { showFps: true, frametime: true, gpu: true, cpu: true,
                  cpuTemp: false, gpuTemp: false, gpuPower: false, vram: false, ram: false };
        } else if (look === "full") {
            lookName = "full stats";
            fpsOnly = false; horizontal = false; alpha = 0.58; radius = 10;
            f = { showFps: true, frametime: true, cpu: true, cpuTemp: true,
                  gpu: true, gpuTemp: true, gpuPower: true, vram: true, ram: true };
        }
        if (!fpsOnly && !f.showFps && !f.frametime && !f.cpu && !f.gpu && !f.vram && !f.ram)
            fpsOnly = true;
        if (corner === "top-left" || corner === "top-right" || corner === "bottom-left" || corner === "bottom-right")
            position = corner;
        if (position !== "top-left" && position !== "top-right" && position !== "bottom-left" && position !== "bottom-right")
            position = "top-left";
        if (fpsSel === "0") limit = "0";
        else if (fpsSel === "60" || fpsSel === "120" || fpsSel === "144") limit = fpsSel;
        var shown = 165;
        var n = parseInt(limit, 10);
        if (limit !== "0" && !isNaN(n) && n > 0) shown = n > 1 ? n - 1 : n;
        var ms = (1000 / shown).toFixed(1);
        var bits = [];
        var rows = [];
        if (f.showFps) { bits.push(shown + " FPS"); rows.push({ k: "FPS", v: "" + shown }); }
        if (f.frametime) { bits.push(ms + " ms"); rows.push({ k: "Frametime", v: ms + " ms" }); }
        if (f.cpu || f.cpuTemp) {
            var cpu = (f.cpu ? "34%" : "") + (f.cpu && f.cpuTemp ? "  " : "") + (f.cpuTemp ? "61°C" : "");
            bits.push("CPU " + cpu);
            rows.push({ k: "CPU", v: cpu });
        }
        if (f.gpu || f.gpuTemp || f.gpuPower) {
            var gpuBits = [];
            if (f.gpu) gpuBits.push("72%");
            if (f.gpuTemp) gpuBits.push("64°C");
            if (f.gpuPower) gpuBits.push("186 W");
            bits.push("GPU " + gpuBits.join(" "));
            rows.push({ k: "GPU", v: gpuBits.join("  ") });
        }
        if (f.vram) { bits.push("VRAM 6.4G"); rows.push({ k: "VRAM", v: "6.4 GB" }); }
        if (f.ram) { bits.push("RAM 18G"); rows.push({ k: "RAM", v: "18.2 GB" }); }
        var cap = (limit === "0" || limit === "") ? "no FPS limit" : ("capped at " + limit);
        return {
            horizontal: horizontal && !fpsOnly,
            fpsOnly: fpsOnly,
            alpha: alpha,
            radius: radius,
            position: position,
            fpsText: "" + shown,
            bits: bits,
            rows: rows,
            caption: "Preview · " + lookName + " · " + position.replace("-", " ") + " · " + cap
        };
    }
    readonly property var hudPreview: buildHudPreview()

    Component.onCompleted: { reloadDefaults(); fanProc.running = true }

    component ChipFlow: Item {
        property var options: []
        property string current: ""
        signal picked(string id)
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        implicitHeight: Math.max(34, flow.implicitHeight)
        Flow {
            id: flow
            width: parent.width
            spacing: 8
            Repeater {
                model: options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool cur: current === ("" + modelData.id)
                    implicitWidth: Math.max(56, chipTxt.implicitWidth + 22)
                    implicitHeight: 34
                    radius: Tok.r
                    color: cur ? theme.a(theme.iris, 0.2) : (chipMa.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                    border.width: 1
                    border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                    Text {
                        id: chipTxt
                        anchors.centerIn: parent
                        text: modelData.l
                        color: cur ? theme.frost : theme.text
                        font.pixelSize: 11
                        font.family: Tok.sans
                        font.bold: cur
                    }
                    MouseArea {
                        id: chipMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picked(modelData.id)
                    }
                }
            }
        }
    }

    Process {
        id: gameDefProc
        command: ["python3", gamingScript, "defaults"]
        stdout: StdioCollector { id: gameDefOut; onStreamFinished: {
            try { gameDefaults = JSON.parse(gameDefOut.text.trim()) || gameDefaults; } catch (e) {}
        } }
    }
    Process {
        id: fanProc
        command: ["sh", "-c", "cat \"$HOME/.config/sea-shell/gaming-fans\" 2>/dev/null || echo custom"]
        stdout: StdioCollector { id: fanOut; onStreamFinished: {
            var v = fanOut.text.trim();
            if (v === "auto" || v === "quiet" || v === "max") gamingFan = v;
        } }
    }
    FileView {
        path: Quickshell.env("HOME") + "/.config/MangoHud/MangoHud.conf"
        watchChanges: true
        printErrors: false
        onLoaded: hudConfText = text()
        onFileChanged: reload()
    }

    MacHeaderCard {
        icon: "sports_esports"
        badgeColor: "#FF5E3A"
        title: "Gaming"
        description: "Configure Game Mode, MangoHud overlay, Gamescope defaults, custom game artwork, bar visibility, and fan presets."
    }

    Section { title: "Launch defaults"; icon: "sports_esports" }
    Text {
        text: "Used for every Steam game unless that game has its own profile in the dashboard."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
    }
    ToggleCard {
        icon: "speed"
        title: "gamemoderun"
        desc: "Wrap launches with Feral GameMode when installed"
        on: gameDefaults.gamemode !== false
        onToggled: patchDefaults({ gamemode: gameDefaults.gamemode === false })
    }
    ToggleCard {
        icon: "videogame_asset"
        title: "Game mode on play"
        desc: "Turn on sea-shell game mode when you hit Play in the dashboard"
        on: gameDefaults.game_mode_on_play !== false
        onToggled: patchDefaults({ game_mode_on_play: gameDefaults.game_mode_on_play === false })
    }
    ToggleCard {
        icon: "monitoring"
        title: "MangoHud"
        desc: "Show the overlay and log FPS to ~/.config/sea-shell/mangohud-logs for session stats"
        on: !!gameDefaults.mangohud
        onToggled: patchDefaults({ mangohud: !gameDefaults.mangohud })
    }
    Rectangle {
        id: hudStage
        visible: !!gameDefaults.mangohud
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        implicitHeight: (hudPreview.horizontal || hudPreview.fpsOnly) ? 96 : 136
        radius: Tok.r + 2
        clip: true
        color: "#16141c"
        border.width: 1
        border.color: theme.a(theme.iris, 0.22)
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#241c30" }
                GradientStop { position: 1.0; color: "#3a2224" }
            }
        }
        Row {
            id: bitMeasure
            visible: false
            spacing: 8
            Repeater {
                model: hudPreview.bits
                delegate: Text {
                    required property var modelData
                    text: "" + modelData
                    font.pixelSize: 11
                    font.family: Tok.mono
                }
            }
        }
        Rectangle {
            id: hudCard
            readonly property int pad: 7
            readonly property int inset: 10
            x: hudPreview.position.indexOf("right") >= 0 ? parent.width - width - inset : inset
            y: hudPreview.position.indexOf("bottom") >= 0 ? parent.height - height - inset : inset
            radius: Math.min(12, hudPreview.radius)
            color: Qt.rgba(0, 0, 0, Math.max(0.72, hudPreview.alpha))
            border.width: 1
            border.color: "#33ffffff"
            clip: true
            width: {
                if (hudPreview.fpsOnly)
                    return Math.min(hudStage.width - inset * 2, bigFps.implicitWidth + 18);
                if (hudPreview.horizontal)
                    return Math.min(hudStage.width - inset * 2, Math.max(80, bitMeasure.implicitWidth + pad * 2));
                return Math.min(hudStage.width - inset * 2, hudCol.implicitWidth + pad * 2);
            }
            height: {
                var inner = hudPreview.fpsOnly ? (bigFps.implicitHeight + 8)
                          : hudPreview.horizontal ? hudFlow.implicitHeight
                          : hudCol.implicitHeight;
                return Math.min(hudStage.height - inset * 2, Math.max(22, inner + pad * 2));
            }
            Text {
                id: bigFps
                visible: hudPreview.fpsOnly
                anchors.centerIn: parent
                text: hudPreview.fpsText
                color: "#b6f0a8"
                font.pixelSize: 26
                font.family: Tok.mono
                font.bold: true
            }
            Flow {
                id: hudFlow
                visible: hudPreview.horizontal && !hudPreview.fpsOnly
                x: hudCard.pad
                y: hudCard.pad
                width: Math.max(40, hudCard.width - hudCard.pad * 2)
                spacing: 8
                Repeater {
                    model: hudPreview.bits
                    delegate: Text {
                        required property var modelData
                        text: "" + modelData
                        color: ("" + modelData).indexOf("FPS") >= 0 ? "#b6f0a8" : "#f2f0ea"
                        font.pixelSize: 11
                        font.family: Tok.mono
                    }
                }
            }
            Column {
                id: hudCol
                visible: !hudPreview.horizontal && !hudPreview.fpsOnly
                x: hudCard.pad
                y: hudCard.pad
                spacing: 1
                Repeater {
                    model: hudPreview.rows
                    delegate: Row {
                        required property var modelData
                        spacing: 10
                        Text {
                            text: modelData.k
                            color: "#c8c4bc"
                            font.pixelSize: 11
                            font.family: Tok.mono
                            width: 78
                            elide: Text.ElideRight
                        }
                        Text {
                            text: modelData.v
                            color: modelData.k === "FPS" ? "#b6f0a8" : "#f4f1ea"
                            font.pixelSize: 11
                            font.family: Tok.mono
                        }
                    }
                }
            }
        }
    }
    Text {
        visible: !!gameDefaults.mangohud
        text: hudPreview.caption
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        elide: Text.ElideRight
        maximumLineCount: 1
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
    }
    Text {
        visible: !!gameDefaults.mangohud
        text: "FPS limit. Left Shift+F1 turns a limit off while you play. “Your config” keeps ~/.config/MangoHud/MangoHud.conf."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
    }
    ChipFlow {
        visible: !!gameDefaults.mangohud
        current: "" + (gameDefaults.mh_fps || "")
        options: [
            { id: "", l: "Your config" },
            { id: "0", l: "No limit" },
            { id: "60", l: "60" },
            { id: "120", l: "120" },
            { id: "144", l: "144" }
        ]
        onPicked: function (id) { patchDefaults({ mh_fps: id }) }
    }
    Text {
        visible: !!gameDefaults.mangohud
        text: "Overlay"
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        Layout.leftMargin: 14
    }
    ChipFlow {
        visible: !!gameDefaults.mangohud
        current: "" + (gameDefaults.mh_look || "")
        options: [
            { id: "", l: "Your config" },
            { id: "fps", l: "FPS only" },
            { id: "compact", l: "Compact" },
            { id: "full", l: "Full" }
        ]
        onPicked: function (id) { patchDefaults({ mh_look: id }) }
    }
    ChipFlow {
        visible: !!gameDefaults.mangohud
        current: "" + (gameDefaults.mh_corner || "")
        options: [
            { id: "", l: "Your config" },
            { id: "top-left", l: "Top left" },
            { id: "top-right", l: "Top right" },
            { id: "bottom-left", l: "Bottom left" },
            { id: "bottom-right", l: "Bottom right" }
        ]
        onPicked: function (id) { patchDefaults({ mh_corner: id }) }
    }
    Text { text: "Default Gamescope"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        Layout.leftMargin: 14 }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        spacing: 8
        Repeater {
            model: [
                { id: "", l: "Off" },
                { id: "1080p", l: "1080p full" },
                { id: "1080p-windowed", l: "1080p window" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool cur: gamescopeKey(gameDefaults.gamescope) === modelData.id
                Layout.fillWidth: true
                implicitHeight: 34
                radius: Tok.r
                color: cur ? theme.a(theme.iris, 0.2) : (gmMa.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                border.width: 1
                border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                Text {
                    anchors.centerIn: parent
                    text: modelData.l
                    color: cur ? theme.frost : theme.text
                    font.pixelSize: 11
                    font.family: Tok.sans
                    font.bold: cur
                }
                MouseArea {
                    id: gmMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        var presets = { "": "", "1080p": "-W 1920 -H 1080 -f --",
                                        "1080p-windowed": "-W 1920 -H 1080 -w 1920 -h 1080 --" };
                        patchDefaults({ gamescope: presets[modelData.id] || "" });
                    }
                }
            }
        }
    }

    Section { title: "Game backgrounds"; icon: "image" }
    Text {
        text: "Heroic, Lutris and TwintailLauncher games without a background get one from the Steam store when the title matches exactly. A free SteamGridDB API key (steamgriddb.com → Preferences → API) finds art for nearly every game. Any game can also use your own picture: Background on the dashboard banner."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
    }
    FileView {
        id: sgdbFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/steamgriddb-key"
        printErrors: false
        onLoaded: if (!sgdbIn.activeFocus) sgdbIn.text = text().trim()
    }
    Rectangle {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        height: 30; radius: Tok.r
        color: theme.a(theme.line, 0.45)
        border.width: 1; border.color: theme.a(theme.line, 0.9)
        TextInput {
            id: sgdbIn
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: theme.text; font.pixelSize: 12; font.family: Tok.mono
            echoMode: activeFocus ? TextInput.Normal : TextInput.Password
            selectByMouse: true
            clip: true
            onEditingFinished: {
                var key = text.trim().replace(/[^A-Za-z0-9]/g, "");
                text = key;
                Quickshell.execDetached(["sh", "-c",
                    "mkdir -p \"$HOME/.config/sea-shell\" && umask 077 && printf '%s\\n' \"$1\" > \"$HOME/.config/sea-shell/steamgriddb-key\"",
                    "sh", key]);
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 10
            visible: sgdbIn.text.length === 0 && !sgdbIn.activeFocus
            text: "SteamGridDB API key (optional)"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        }
    }

    Section { title: "Shell in game mode"; icon: "bolt" }
    Text {
        text: "Smart Hibernate is always active in game mode: pauses background polling, GPU/Wi-Fi scans, dock, wallpaper rotation, and strips Hyprland gaps, borders, rounding, blur, shadows, and animations."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
    }
    ToggleCard {
        icon: "hide"
        title: "Hide bar while playing"
        desc: "Unmap the bar surface during game mode (and auto-hide while a game window is open)"
        on: root.apHideGaming
        onToggled: { root.apHideGaming = !root.apHideGaming; root.saveAppearance() }
    }
    ToggleCard {
        icon: "power_settings_new"
        title: "Suspend shell in game mode (Ultra)"
        desc: "Stop seashell, wallpaper daemon, and clipboard watchers while game mode is on for zero shell RAM/CPU overhead. Restores automatically on game exit or Super+Shift+G."
        on: root.apSuspendShellGaming
        onToggled: { root.apSuspendShellGaming = !root.apSuspendShellGaming; root.saveAppearance() }
    }

    Section { title: "Fans in game mode"; icon: "mode_fan" }
    Text {
        text: "Applied when game mode turns on, if sea-fand is installed."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
        Layout.leftMargin: 14
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        spacing: 8
        Repeater {
            model: [
                { k: "auto", l: "Auto" },
                { k: "quiet", l: "Quiet" },
                { k: "max", l: "Max" }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property bool cur: gamingFan === modelData.k
                Layout.fillWidth: true
                implicitHeight: 34
                radius: Tok.r
                color: cur ? theme.a(theme.iris, 0.2) : (fanMa.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                border.width: 1
                border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                Text {
                    anchors.centerIn: parent
                    text: modelData.l
                    color: cur ? theme.frost : theme.text
                    font.pixelSize: 11
                    font.family: Tok.sans
                    font.bold: cur
                }
                MouseArea {
                    id: fanMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: setGamingFan(modelData.k)
                }
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        implicitHeight: dashCol.implicitHeight + 24
        radius: Tok.r + 2
        color: root.groupFill
        border.width: 1
        border.color: root.groupRule
        ColumnLayout {
            id: dashCol
            anchors.fill: parent
            anchors.margins: 14
            spacing: 6
            Text {
                text: "Dashboard library"
                color: theme.text
                font.pixelSize: 13
                font.family: Tok.sans
                font.bold: true
            }
            Text {
                text: "Super+D → Gaming tab, or type g in the launcher to search installed games."
                color: theme.faint
                font.pixelSize: 11
                font.family: Tok.sans
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Rectangle {
                Layout.preferredWidth: openDash.implicitWidth + 20
                Layout.preferredHeight: 32
                radius: Tok.r
                color: openMa.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.35)
                Text {
                    id: openDash
                    anchors.centerIn: parent
                    text: "Open gaming dashboard"
                    color: theme.text
                    font.pixelSize: 12
                    font.family: Tok.sans
                }
                MouseArea {
                    id: openMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "dashboard", "gaming"])
                }
            }
        }
    }
}
