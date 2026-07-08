//@ pragma UseQApplication
// sea-shell — settings / control center (tabbed)
// Run:  qs -p ~/.config/quickshell/sea-shell/settings.qml   (SUPER+S)
// Esc or click-outside closes.  Verified on Quickshell 0.3.0.
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    property string repo: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    property int tab: 0
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }
    onTabChanged: if (tab === 7) kbProc.running = true   // refresh binds when the tab opens

    // ---------- keybinds tab: live binds + rebind (same engine as keybinds.qml) ----------
    property var kbBinds: []
    property string kbQuery: ""
    property var kbRec: null          // bind being rebound
    property var kbRecMods: []
    property string kbConflict: ""
    readonly property var kbShown: {
        var q = root.kbQuery.toLowerCase().trim();
        if (q === "") return root.kbBinds;
        return root.kbBinds.filter(b => b.desc.toLowerCase().indexOf(q) >= 0 || b.keys.toLowerCase().indexOf(q) >= 0);
    }
    function kbModStr(m) { var s = []; if (m & 64) s.push("SUPER"); if (m & 4) s.push("CTRL"); if (m & 8) s.push("ALT"); if (m & 1) s.push("SHIFT"); return s }
    function kbPretty(k) {
        if (k === "Return") return "⏎"; if (k === "Escape") return "Esc"; if (k === "grave") return "`";
        if (/^mouse/.test(k)) return k.replace("mouse:","M"); if (/^XF86/.test(k)) return k.replace("XF86","");
        return k.length === 1 ? k.toUpperCase() : k;
    }
    Process {
        id: kbProc; running: true
        command: ["sh","-c","hyprctl binds -j"]
        stdout: StdioCollector { id: kbOut; onStreamFinished: {
            try {
                var arr = JSON.parse(kbOut.text); var out = []; var seen = {};
                for (var i=0;i<arr.length;i++) {
                    var b = arr[i]; if (b.mouse) continue;
                    var mods = root.kbModStr(b.modmask);
                    var keys = mods.concat([root.kbPretty(b.key)]).join(" + ");
                    var hasDesc = !!(b.description && b.description.length);
                    var desc = hasDesc ? b.description : (b.dispatcher + (b.arg ? " " + b.arg : ""));
                    var sig = keys + "|" + desc; if (seen[sig]) continue; seen[sig] = 1;
                    out.push({ keys: keys, desc: desc, key: b.key, mods: mods, canEdit: hasDesc });
                }
                root.kbBinds = out;
            } catch(e) {}
        } }
    }
    Timer { id: kbRefetch; interval: 600; onTriggered: kbProc.running = true }
    function kbKeyName(e) {
        var k = e.key;
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(97 + (k - Qt.Key_A));
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(48 + (k - Qt.Key_0));
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1);
        var map = {};
        map[Qt.Key_Left]="left"; map[Qt.Key_Right]="right"; map[Qt.Key_Up]="up"; map[Qt.Key_Down]="down";
        map[Qt.Key_Return]="Return"; map[Qt.Key_Enter]="Return"; map[Qt.Key_Space]="Space";
        map[Qt.Key_Print]="Print"; map[Qt.Key_QuoteLeft]="grave"; map[Qt.Key_Tab]="Tab";
        map[Qt.Key_Backspace]="BackSpace"; map[Qt.Key_Delete]="Delete"; map[Qt.Key_Insert]="Insert";
        map[Qt.Key_Home]="Home"; map[Qt.Key_End]="End"; map[Qt.Key_PageUp]="Page_Up"; map[Qt.Key_PageDown]="Page_Down";
        map[Qt.Key_Comma]="comma"; map[Qt.Key_Period]="period"; map[Qt.Key_Minus]="minus"; map[Qt.Key_Equal]="equal";
        map[Qt.Key_Semicolon]="semicolon"; map[Qt.Key_Apostrophe]="apostrophe"; map[Qt.Key_Slash]="slash"; map[Qt.Key_Backslash]="backslash";
        map[Qt.Key_BracketLeft]="bracketleft"; map[Qt.Key_BracketRight]="bracketright";
        return map[k] || null;
    }
    function kbApply(base) {
        var combo = root.kbRecMods.join(" ");
        for (var i=0;i<root.kbBinds.length;i++) {
            var b = root.kbBinds[i];
            if (b.desc === root.kbRec.desc && b.key === root.kbRec.key) continue;
            if (b.mods.join(" ") === combo && b.key.toLowerCase() === base.toLowerCase()) {
                root.kbConflict = "already used by “" + b.desc + "”"; return }
        }
        Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-rebind.sh").toString().replace("file://",""),
                                 root.kbRec.desc, root.kbRec.key, combo, base]);
        root.kbRec = null; root.kbConflict = "";
        kbRefetch.start();
    }

    QtObject {
        id: theme
        readonly property color bg:    "#0d1420"
        readonly property color panel: "#131b29"
        readonly property color line:  "#24304a"
        readonly property color text:  "#e2e9f4"
        readonly property color sub:   "#a6b6cf"
        readonly property color faint: "#6f8099"
        readonly property color iris:  "#63c7dd"
        readonly property color frost: "#a2e2e8"
        readonly property color good:  "#a6e3a1"
        readonly property color bad:   "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // ---------- audio state ----------
    property var sinks: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isSink && !n.isStream && n.audio })
    property var curSink: Pipewire.defaultAudioSink
    property var curSource: Pipewire.defaultAudioSource
    PwObjectTracker {
        objects: {
            var arr = [];
            if (root.curSink) arr.push(root.curSink);
            if (root.curSource) arr.push(root.curSource);
            for (var i = 0; i < root.sinks.length; i++) arr.push(root.sinks[i]);
            return arr;
        }
    }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "device") : "" }

    // ---------- weather location + unit ----------
    property string wxLoc: "Kuching"
    property string wxUnit: "m"   // m = °C metric · u = °F "freedom units"
    Process { running: true; command: ["sh", "-c", "cat ~/.config/sea-shell/location 2>/dev/null || echo Kuching"]
        stdout: StdioCollector { id: locOut; onStreamFinished: { var v = locOut.text.trim(); if (v) root.wxLoc = v } } }
    Process { running: true; command: ["sh", "-c", "cat ~/.config/sea-shell/wxunit 2>/dev/null || echo m"]
        stdout: StdioCollector { id: unitOut; onStreamFinished: { var v = unitOut.text.trim(); if (v === "u" || v === "m") root.wxUnit = v } } }
    function saveLoc(loc) {
        var l = (loc || "").trim(); if (!l) return;
        run("mkdir -p ~/.config/sea-shell && printf '%s' '" + l.replace(/'/g, "") + "' > ~/.config/sea-shell/location && notify-send 'sea-shell' 'Weather location → " + l.replace(/'/g, "") + " (restart bar to refresh)'");
        root.wxLoc = l;
    }
    function saveUnit(u) {
        root.wxUnit = u;
        run("mkdir -p ~/.config/sea-shell && printf '%s' '" + u + "' > ~/.config/sea-shell/wxunit && notify-send 'sea-shell' 'Weather units → " + (u === "u" ? "°F" : "°C") + " (restart bar to refresh)'");
    }

    // ---------- brightness ----------
    property int brightness: -1
    Process {
        id: brGet; running: true
        command: ["sh", "-c", "brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%'"]
        stdout: StdioCollector { id: brOut; onStreamFinished: { var v = parseInt(brOut.text); if (!isNaN(v)) root.brightness = v } }
    }
    function setBrightness(pct) { root.brightness = pct; run("brightnessctl s " + Math.round(pct) + "% >/dev/null 2>&1") }

    // ---------- displays (hyprctl monitors) ----------
    property var monitors: []
    property int monSel: 0            // which monitor is being edited
    property string selRes: ""        // "1920x1080"
    property string selHz: ""         // "165.00"
    property int selTransform: 0      // 0 landscape · 1 portrait · 2 landscape-flipped · 3 portrait-flipped
    readonly property var curMon: (root.monitors.length > root.monSel) ? root.monitors[root.monSel] : null
    Process {
        id: monProc; running: true
        command: ["sh", "-c", "hyprctl -j monitors"]
        stdout: StdioCollector { id: monOut; onStreamFinished: {
            try {
                var arr = JSON.parse(monOut.text); var out = [];
                for (var i=0;i<arr.length;i++) { var m=arr[i];
                    var modes=[]; var seenR={};
                    for (var j=0;j<(m.availableModes||[]).length;j++){ var raw=m.availableModes[j];
                        var mm=raw.match(/^(\d+)x(\d+)@([\d.]+)Hz$/); if(!mm) continue;
                        modes.push({res:mm[1]+"x"+mm[2], hz:mm[3], raw:raw}); }
                    out.push({ name:m.name, desc:(m.description||m.name), w:m.width, h:m.height,
                               hz:(""+m.refreshRate).split(".")[0], transform:m.transform||0, scale:m.scale||1,
                               modes:modes, curRes:m.width+"x"+m.height });
                }
                root.monitors = out;
                if (out.length && root.selRes==="") { var c=out[root.monSel];
                    root.selRes=c.curRes; root.selHz=(c.modes[0]?c.modes[0].hz:""); root.selTransform=c.transform;
                    // prefer a mode whose hz matches current
                    for (var k=0;k<c.modes.length;k++) if(c.modes[k].res===c.curRes){ root.selHz=c.modes[k].hz; break; }
                }
            } catch(e) {}
        } }
    }
    function reloadMonitors() { monProc.running = true }
    // native modes first, then common 16:9 resolutions Hyprland can scale to
    function uniqueRes(m) {
        var seen={}, r=[];
        if(m) for(var i=0;i<m.modes.length;i++){ var s=m.modes[i].res; if(!seen[s]){seen[s]=1;r.push(s)} }
        var common=["3840x2160","2560x1440","1920x1080","1600x900","1366x768","1280x720","1024x576"];
        for(var j=0;j<common.length;j++) if(!seen[common[j]]){seen[common[j]]=1;r.push(common[j])}
        return r;
    }
    function hzFor(m, res) {
        var seen={}, r=[];
        if(m) for(var i=0;i<m.modes.length;i++) if(m.modes[i].res===res && !seen[m.modes[i].hz]){seen[m.modes[i].hz]=1;r.push(m.modes[i].hz)}
        var common=["165.00","144.00","120.00","75.00","60.00"];
        for(var j=0;j<common.length;j++) if(!seen[common[j]]){seen[common[j]]=1;r.push(common[j])}
        return r;
    }
    function applyDisplay() {
        if (!root.curMon) return;
        var spec = root.curMon.name + "," + root.selRes + "@" + root.selHz + ",auto," + root.curMon.scale + ",transform," + root.selTransform;
        run("hyprctl keyword monitor '" + spec + "' && notify-send 'sea-shell' 'Display: " + root.selRes + "@" + root.selHz + "Hz'");
        monRefresh.start();
    }
    Timer { id: monRefresh; interval: 900; onTriggered: monProc.running = true }

    // ---------- appearance (shared with the bar via ~/.config/sea-shell/appearance.json) ----------
    property real apRadius: 14
    property real apOpacity: 0.80
    property int  apHeight: 42
    property string apAccent: "#63c7dd"
    property string apFont: "monospace"
    property var apCustomFonts: []      // fonts the user typed, persisted as chips
    property var accents: ["#63c7dd","#4dd0c4","#6aa6ff","#cba6f7","#a6e3a1","#f4c542","#f38ba8","#ff9e64"]
    property var baseFonts: ["monospace","MesloLGM Nerd Font","JetBrainsMono Nerd Font","FiraCode Nerd Font","sans-serif","Iosevka"]
    readonly property var fontPresets: root.baseFonts.concat(root.apCustomFonts)
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text);
            if(j.radius!==undefined) root.apRadius=j.radius; if(j.opacity!==undefined) root.apOpacity=j.opacity;
            if(j.height!==undefined) root.apHeight=j.height; if(j.accent!==undefined) root.apAccent=j.accent;
            if(j.font!==undefined) root.apFont=j.font; if(j.customFonts!==undefined) root.apCustomFonts=j.customFonts; } catch(e){} } } }
    function saveAppearance() {
        var cf = '['; for(var i=0;i<root.apCustomFonts.length;i++){ cf += (i?',':'') + '\"'+root.apCustomFonts[i]+'\"'; } cf += ']';
        var j = '{\"radius\":'+Math.round(root.apRadius)+',\"opacity\":'+root.apOpacity.toFixed(2)+',\"height\":'+Math.round(root.apHeight)+',\"accent\":\"'+root.apAccent+'\",\"font\":\"'+root.apFont+'\",\"customFonts\":'+cf+'}';
        run("mkdir -p \"$HOME/.config/sea-shell\" && printf '%s' '"+j+"' > \"$HOME/.config/sea-shell/appearance.json\"");
    }
    function addCustomFont(f) {
        f = (f||"").trim(); if(f==="") return;
        if (root.baseFonts.indexOf(f)<0 && root.apCustomFonts.indexOf(f)<0) { var a=root.apCustomFonts.slice(); a.push(f); root.apCustomFonts=a; }
        root.apFont = f; root.saveAppearance();
    }
    // matugen: derive a palette from the current wallpaper (pick any swatch)
    property bool matugenBusy: false
    property var matugenPalette: []      // several extracted colours to choose from
    Process {
        id: matugenProc
        // for video/gif wallpapers, grab the first frame with ffmpeg, then colour-match that
        command: ["sh","-c","wp=$(cat \"$HOME/.config/sea-shell/wallpaper\" 2>/dev/null); [ -z \"$wp\" ] && exit 1; " +
            "case \"$wp\" in *.mp4|*.webm|*.mkv|*.mov|*.gif) f=/tmp/sea-matugen-frame.png; ffmpeg -y -i \"$wp\" -vframes 1 \"$f\" >/dev/null 2>&1 && wp=\"$f\";; esac; " +
            "matugen --json hex --prefer saturation image \"$wp\" 2>/dev/null"]
        stdout: StdioCollector { id: matOut; onStreamFinished: {
            root.matugenBusy = false;
            try {
                var j = JSON.parse(matOut.text); var c = j.colors || {}; var b = j.base16 || {};
                function pc(role){ return c[role] ? ((c[role].dark||c[role].default||c[role].light)||{}).color : null; }
                function pb(k){ return b[k] ? ((b[k].dark||b[k].default||b[k].light)||{}).color : null; }
                var pal = [];
                var roles = [pc("primary"), pc("secondary"), pc("tertiary"),
                             pb("base08"), pb("base0A"), pb("base0B"), pb("base0C"), pb("base0D"), pb("base0E")];
                var seen = {};
                for (var i=0;i<roles.length;i++){ var col=roles[i]; if(col && !seen[col.toLowerCase()]){ seen[col.toLowerCase()]=1; pal.push(col) } }
                root.matugenPalette = pal;
                if (pal.length) { root.apAccent = pal[0]; root.saveAppearance(); run("notify-send 'sea-shell' 'Wallpaper palette ready — "+pal.length+" colours, applied "+pal[0]+"'"); }
                else run("notify-send 'sea-shell' 'matugen: could not read colours'");
            } catch(e) { run("notify-send 'sea-shell' 'matugen: no wallpaper set yet (pick one first)'"); }
        } }
    }
    function matchWallpaper() { if(root.matugenBusy) return; root.matugenBusy = true; matugenProc.running = true }

    // ---------- wifi ----------
    property var wifiList: []
    Process {
        id: wifiScan; running: true
        command: ["sh", "-c", "nmcli -t -f ACTIVE,SIGNAL,SECURITY,SSID dev wifi 2>/dev/null | awk -F: 'length($4)>0' | sort -t: -k2 -rn | head -8"]
        stdout: StdioCollector {
            id: wifiOut
            onStreamFinished: {
                var out = [];
                var lines = wifiOut.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split(":");
                    out.push({ active: p[0] === "yes", signal: parseInt(p[1]) || 0, secure: (p[2] || "").length > 0, ssid: p.slice(3).join(":") });
                }
                root.wifiList = out;
            }
        }
    }
    function rescanWifi() { wifiScan.running = true }
    function wifiConnect(ssid, secure) {
        var e = ssid.replace(/'/g, "");
        if (secure)
            Quickshell.execDetached(["kitty","--class","sea-wifi","--title","join "+e,"-e","sh","-c",
                "nmcli dev wifi connect '"+e+"' --ask && { notify-send 'sea-shell' 'Connected to "+e+"'; sleep 0.6; } || { echo; read -p 'could not connect — press enter to close…' _; }"]);
        else
            run("nmcli dev wifi connect '" + e + "' || notify-send 'sea-shell' 'Could not join " + e + "'");
        wifiRefresh.start();
    }
    Timer { id: wifiRefresh; interval: 2500; onTriggered: root.rescanWifi() }

    // ============ reusable components ============
    component Sym: Text {
        property int sz: 18
        font.family: "Material Symbols Outlined"; font.pixelSize: sz
        color: theme.frost; verticalAlignment: Text.AlignVCenter
    }

    component Section: ColumnLayout {
        property string title: ""
        property string icon: ""
        Layout.fillWidth: true
        spacing: 10
        RowLayout {
            spacing: 8
            Sym { text: icon; sz: 18; color: theme.iris }
            Text { text: title; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
            Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
        }
    }

    // custom slider (0..1)
    component Slider: Item {
        id: sl
        property real value: 0
        property color fill: theme.iris
        signal moved(real v)
        implicitHeight: 22
        Layout.fillWidth: true
        function clamp(v) { return Math.max(0, Math.min(1, v)) }
        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: 6; radius: 3
            color: theme.a(theme.line, 0.8)
            Rectangle { width: track.width * sl.clamp(sl.value); height: parent.height; radius: 3; color: sl.fill }
        }
        Rectangle {
            width: 15; height: 15; radius: 8
            border.width: 2; border.color: sl.fill; color: theme.frost
            anchors.verticalCenter: parent.verticalCenter
            x: (sl.width - width) * sl.clamp(sl.value)
        }
        MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onPressed: (e) => { var v = sl.clamp(e.x / sl.width); sl.value = v; sl.moved(v) }
            onPositionChanged: (e) => { if (pressed) { var v = sl.clamp(e.x / sl.width); sl.value = v; sl.moved(v) } }
        }
    }

    component Row2: RowLayout {
        property string icon: ""
        property string label: ""
        property string cmd: ""
        property bool quitAfter: false
        property color tint: theme.frost
        Layout.fillWidth: true
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 42; radius: 9
            color: rma.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.38)
            border.width: 1; border.color: rma.containsMouse ? theme.iris : theme.a(theme.iris, 0.16)
            Behavior on color { ColorAnimation { duration: 110 } }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 13; anchors.rightMargin: 13; spacing: 10
                Sym { text: parent.parent.parent.icon; sz: 19; color: parent.parent.parent.tint }
                Text { text: parent.parent.parent.label; color: theme.text; font.pixelSize: 13; font.family: "monospace"; Layout.fillWidth: true }
            }
            MouseArea {
                id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.run(parent.parent.cmd); if (parent.parent.quitAfter) Qt.quit() }
            }
        }
    }

    // a single tab button in the sidebar
    component TabBtn: Rectangle {
        property string icon: ""
        property string label: ""
        property int idx: 0
        readonly property bool sel: root.tab === idx
        Layout.fillWidth: true; implicitHeight: 40; radius: 10
        color: sel ? theme.a(theme.iris, 0.2) : (tbm.containsMouse ? theme.a(theme.line, 0.5) : "transparent")
        border.width: 1; border.color: sel ? theme.a(theme.iris, 0.5) : "transparent"
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 10
            Sym { text: icon; sz: 18; color: sel ? theme.iris : theme.sub }
            Text { text: label; color: sel ? theme.text : theme.sub; font.pixelSize: 13; font.family: "monospace"; font.bold: sel; Layout.fillWidth: true }
        }
        MouseArea { id: tbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = idx }
    }

    // ============ window ============
    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.5); MouseArea { anchors.fill: parent; onClicked: Qt.quit() } }
        Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: Qt.quit() }

        Rectangle {
            anchors.centerIn: parent
            width: 720
            height: Math.min(parent.height - 80, 560)
            radius: 18
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            // ---------------- sidebar (anchored, fixed width) ----------------
            ColumnLayout {
                id: sidebar
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 20 }
                width: 180; spacing: 8
                RowLayout {
                    spacing: 11; Layout.fillWidth: true; Layout.bottomMargin: 6
                    IconImage { implicitSize: 30; source: Qt.resolvedUrl("logo.svg") }
                    ColumnLayout {
                        spacing: 0
                        Text { text: "sea-shell"; color: theme.text; font.pixelSize: 17; font.family: "monospace"; font.bold: true }
                        Text { text: "control center"; color: theme.frost; font.pixelSize: 10; font.family: "monospace" }
                    }
                }
                TabBtn { icon: "volume_up";           label: "Audio";    idx: 0 }
                TabBtn { icon: "brightness_6";         label: "Display";  idx: 1 }
                TabBtn { icon: "wifi";                 label: "Network";  idx: 2 }
                TabBtn { icon: "cloud";                label: "Weather";  idx: 3 }
                TabBtn { icon: "palette";              label: "Appearance"; idx: 4 }
                TabBtn { icon: "bolt";                 label: "Actions";  idx: 5 }
                TabBtn { icon: "keyboard";             label: "Keybinds"; idx: 7 }
                TabBtn { icon: "power_settings_new";   label: "Power";    idx: 6 }
                Item { Layout.fillHeight: true }
                Text { text: "esc to close"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
            }

            Rectangle {
                anchors { left: sidebar.right; leftMargin: 11; top: parent.top; topMargin: 20; bottom: parent.bottom; bottomMargin: 20 }
                width: 1; color: theme.a(theme.iris, 0.16)
            }

            // ---------------- content pane (anchored between sidebar and edge) ----------------
            Flickable {
                id: contentFlick
                anchors { left: sidebar.right; leftMargin: 24; right: parent.right; rightMargin: 20; top: parent.top; topMargin: 20; bottom: parent.bottom; bottomMargin: 20 }
                contentWidth: width
                contentHeight: pane.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: pane
                    width: contentFlick.width
                    spacing: 16

                        // ================= AUDIO =================
                        ColumnLayout {
                            visible: root.tab === 0; Layout.fillWidth: true; spacing: 14
                            Section { title: "output"; icon: "volume_up" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Sym {
                                    text: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? "volume_off" : "volume_up"
                                    sz: 20; color: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? theme.faint : theme.frost
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { if (root.curSink && root.curSink.audio) root.curSink.audio.muted = !root.curSink.audio.muted } }
                                }
                                Slider {
                                    value: (root.curSink && root.curSink.audio) ? root.curSink.audio.volume : 0
                                    onMoved: (v) => { if (root.curSink && root.curSink.audio) { root.curSink.audio.muted = false; root.curSink.audio.volume = v } }
                                }
                                Text { text: (root.curSink && root.curSink.audio) ? Math.round(root.curSink.audio.volume * 100) + "%" : "—"
                                       color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 38; horizontalAlignment: Text.AlignRight }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                visible: root.curSource && root.curSource.audio
                                Sym {
                                    text: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? "mic_off" : "mic"
                                    sz: 20; color: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? theme.faint : theme.frost
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { if (root.curSource && root.curSource.audio) root.curSource.audio.muted = !root.curSource.audio.muted } }
                                }
                                Slider {
                                    fill: theme.good
                                    value: (root.curSource && root.curSource.audio) ? root.curSource.audio.volume : 0
                                    onMoved: (v) => { if (root.curSource && root.curSource.audio) { root.curSource.audio.muted = false; root.curSource.audio.volume = v } }
                                }
                                Text { text: (root.curSource && root.curSource.audio) ? Math.round(root.curSource.audio.volume * 100) + "%" : "—"
                                       color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 38; horizontalAlignment: Text.AlignRight }
                            }
                            Text { text: "output device"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.sinks
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.curSink && root.curSink.id === modelData.id
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (dma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 8
                                            Sym { text: cur ? "radio_button_checked" : "radio_button_unchecked"; sz: 16; color: cur ? theme.iris : theme.faint }
                                            Text { text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                        MouseArea { id: dma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: Pipewire.preferredDefaultAudioSink = modelData }
                                    }
                                }
                            }
                        }

                        // ================= DISPLAY =================
                        ColumnLayout {
                            visible: root.tab === 1; Layout.fillWidth: true; spacing: 14
                            Section { title: "brightness"; icon: "brightness_6" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Sym { text: "brightness_low"; sz: 20 }
                                Slider {
                                    fill: theme.frost
                                    value: root.brightness >= 0 ? root.brightness / 100 : 0
                                    onMoved: (v) => root.setBrightness(v * 100)
                                }
                                Text { text: root.brightness >= 0 ? root.brightness + "%" : "n/a"
                                       color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 38; horizontalAlignment: Text.AlignRight }
                            }
                            Text { visible: root.brightness < 0; text: "brightnessctl found no backlight (desktop monitor?)"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }

                            // ---- monitor configuration ----
                            Section { title: "monitor"; icon: "monitor" }
                            // monitor selector (when more than one)
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8; visible: root.monitors.length > 1
                                Repeater { model: root.monitors
                                    delegate: Rectangle { required property var modelData; required property int index
                                        readonly property bool sel: root.monSel === index
                                        Layout.fillWidth: true; implicitHeight: 30; radius: 8
                                        color: sel ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.4); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.14)
                                        Text { anchors.centerIn: parent; text: modelData.name; color: sel?theme.frost:theme.text; font.pixelSize: 12; font.family: "monospace" }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.monSel=index; root.selRes=""; root.reloadMonitors() } } } }
                            }
                            Text { text: root.curMon ? (root.curMon.desc + "  ·  now " + root.curMon.curRes + "@" + root.curMon.hz + "Hz") : "reading monitors…"
                                   color: theme.faint; font.pixelSize: 11; font.family: "monospace" }

                            // resolution
                            Text { text: "resolution"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            Flow { Layout.fillWidth: true; spacing: 7
                                Repeater { model: root.uniqueRes(root.curMon)
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.selRes===modelData
                                        implicitWidth: rt.implicitWidth+20; implicitHeight: 32; radius: 8
                                        color: sel?theme.iris:(rmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                        Text { id: rt; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: sel }
                                        MouseArea { id: rmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.selRes=modelData; var hs=root.hzFor(root.curMon,modelData); if(hs.length) root.selHz=hs[0] } } } }
                            }
                            // refresh rate
                            Text { text: "refresh rate"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            Flow { Layout.fillWidth: true; spacing: 7
                                Repeater { model: root.hzFor(root.curMon, root.selRes)
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.selHz===modelData
                                        implicitWidth: ht.implicitWidth+20; implicitHeight: 32; radius: 8
                                        color: sel?theme.iris:(hmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                        Text { id: ht; anchors.centerIn: parent; text: Math.round(parseFloat(modelData))+" Hz"; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: sel }
                                        MouseArea { id: hmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selHz=modelData } } }
                            }
                            // orientation
                            Text { text: "orientation"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            RowLayout { Layout.fillWidth: true; spacing: 7
                                Repeater { model: [{t:0,i:"stay_current_landscape",l:"landscape"},{t:1,i:"stay_current_portrait",l:"portrait"},{t:2,i:"screen_rotation",l:"land ↕"},{t:3,i:"screen_rotation",l:"port ↕"}]
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.selTransform===modelData.t
                                        Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                        color: sel?theme.iris:(omm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                        RowLayout { anchors.centerIn: parent; spacing: 6
                                            Sym { text: modelData.i; sz: 16; color: sel?theme.bg:theme.frost }
                                            Text { text: modelData.l; color: sel?theme.bg:theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: sel } }
                                        MouseArea { id: omm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selTransform=modelData.t } } }
                            }
                            // apply
                            Rectangle { Layout.fillWidth: true; implicitHeight: 40; radius: 9; visible: root.curMon!==null
                                color: apm.containsMouse ? theme.iris : theme.a(theme.iris,0.22); border.width: 1; border.color: theme.iris
                                RowLayout { anchors.centerIn: parent; spacing: 8
                                    Sym { text: "check"; sz: 17; color: apm.containsMouse?theme.bg:theme.frost }
                                    Text { text: "Apply " + root.selRes + "@" + Math.round(parseFloat(root.selHz||"0")) + "Hz"; color: apm.containsMouse?theme.bg:theme.text; font.pixelSize: 13; font.family: "monospace" } }
                                MouseArea { id: apm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyDisplay() } }
                        }

                        // ================= NETWORK =================
                        ColumnLayout {
                            visible: root.tab === 2; Layout.fillWidth: true; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "wifi"; sz: 18; color: theme.iris }
                                Text { text: "wi-fi networks"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Sym { text: "refresh"; sz: 17; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.rescanWifi() } }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.wifiList
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; implicitHeight: 40; radius: 8
                                        color: modelData.active ? theme.a(theme.iris, 0.2) : (wma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: modelData.active ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 9
                                            Sym {
                                                text: modelData.signal > 66 ? "signal_wifi_4_bar" : modelData.signal > 33 ? "network_wifi_3_bar" : "network_wifi_1_bar"
                                                sz: 17; color: modelData.active ? theme.iris : theme.frost
                                            }
                                            Text { text: modelData.ssid; color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Sym { text: "lock"; sz: 13; color: theme.faint; visible: modelData.secure }
                                            Sym { text: "check"; sz: 15; color: theme.good; visible: modelData.active }
                                        }
                                        MouseArea { id: wma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: if (!modelData.active) root.wifiConnect(modelData.ssid, modelData.secure) }
                                    }
                                }
                                Text { visible: root.wifiList.length === 0; text: "scanning…"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                                Text { text: "secured networks open a prompt for the password"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.topMargin: 4 }
                            }
                        }

                        // ================= WEATHER =================
                        ColumnLayout {
                            visible: root.tab === 3; Layout.fillWidth: true; spacing: 14
                            Section { title: "location"; icon: "location_on" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 38; radius: 9
                                    color: theme.a(theme.line, 0.4); border.width: 1
                                    border.color: locIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    TextInput {
                                        id: locIn
                                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 13; font.family: "monospace"
                                        clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                        Component.onCompleted: text = root.wxLoc
                                        onAccepted: root.saveLoc(text)
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: locIn.text === ""; text: "city, e.g. Kuching"; color: theme.faint; font.pixelSize: 13; font.family: "monospace" }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 96; implicitHeight: 38; radius: 9
                                    color: svm.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                    border.width: 1; border.color: theme.iris
                                    RowLayout {
                                        anchors.centerIn: parent; spacing: 6
                                        Sym { text: "save"; sz: 16; color: svm.containsMouse ? theme.bg : theme.frost }
                                        Text { text: "Save"; color: svm.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: "monospace" }
                                    }
                                    MouseArea { id: svm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveLoc(locIn.text) }
                                }
                            }
                            Section { title: "units"; icon: "thermostat" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Repeater {
                                    model: [{u:"m",l:"°C  metric"},{u:"u",l:"°F  freedom"}]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool sel: root.wxUnit === modelData.u
                                        Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                        color: sel ? theme.iris : (um.containsMouse ? theme.a(theme.iris,0.16) : theme.a(theme.line,0.4))
                                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.16)
                                        Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.text; font.pixelSize: 13; font.family: "monospace"; font.bold: sel }
                                        MouseArea { id: um; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveUnit(modelData.u) }
                                    }
                                }
                            }
                        }

                        // ================= APPEARANCE =================
                        ColumnLayout {
                            visible: root.tab === 4; Layout.fillWidth: true; spacing: 14
                            Section { title: "bar shape"; icon: "tune" }
                            // roundness
                            RowLayout { Layout.fillWidth: true; spacing: 10
                                Sym { text: "rounded_corner"; sz: 20 }
                                Text { text: "roundness"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                Slider { value: root.apRadius/26; onMoved: (v)=>{ root.apRadius = v*26; root.saveAppearance() } }
                                Text { text: Math.round(root.apRadius)+"px"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }
                            // transparency
                            RowLayout { Layout.fillWidth: true; spacing: 10
                                Sym { text: "opacity"; sz: 20 }
                                Text { text: "opacity"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                Slider { fill: theme.frost; value: (root.apOpacity-0.25)/0.75; onMoved: (v)=>{ root.apOpacity = 0.25 + v*0.75; root.saveAppearance() } }
                                Text { text: Math.round(root.apOpacity*100)+"%"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }
                            // height
                            RowLayout { Layout.fillWidth: true; spacing: 10
                                Sym { text: "height"; sz: 20 }
                                Text { text: "bar height"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                Slider { fill: theme.good; value: (root.apHeight-34)/20; onMoved: (v)=>{ root.apHeight = 34 + v*20; root.saveAppearance() } }
                                Text { text: Math.round(root.apHeight)+"px"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }

                            Section { title: "accent colour"; icon: "palette" }
                            Flow { Layout.fillWidth: true; spacing: 10
                                Repeater { model: root.accents
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                        width: 40; height: 40; radius: 20; color: modelData
                                        border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                        Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 20; color: "#0d1420" }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAccent=modelData; root.saveAppearance() } } } } }
                            // matugen — derive accent from wallpaper
                            Rectangle { Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                color: mgm.containsMouse ? theme.iris : theme.a(theme.iris,0.18); border.width: 1; border.color: theme.iris
                                RowLayout { anchors.centerIn: parent; spacing: 8
                                    Sym { text: root.matugenBusy?"sync":"auto_awesome"; sz: 17; color: mgm.containsMouse?theme.bg:theme.frost }
                                    Text { text: root.matugenBusy ? "matching…" : "match wallpaper (matugen)"; color: mgm.containsMouse?theme.bg:theme.text; font.pixelSize: 13; font.family: root.apFont } }
                                MouseArea { id: mgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.matchWallpaper() } }
                            // extracted palette — pick any colour
                            Flow { Layout.fillWidth: true; spacing: 9; visible: root.matugenPalette.length>0
                                Repeater { model: root.matugenPalette
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                        width: 36; height: 36; radius: 18; color: modelData
                                        border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                        Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 18; color: "#0d1420" }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAccent=modelData; root.saveAppearance() } } } } }

                            Section { title: "font"; icon: "font_download" }
                            Flow { Layout.fillWidth: true; spacing: 7
                                Repeater { model: root.fontPresets
                                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.apFont===modelData
                                        implicitWidth: ft.implicitWidth+20; implicitHeight: 32; radius: 8
                                        color: sel?theme.iris:(fmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                        Text { id: ft; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: modelData; font.bold: sel }
                                        MouseArea { id: fmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apFont=modelData; root.saveAppearance() } } } }
                            }
                            // custom font entry
                            Rectangle { Layout.fillWidth: true; implicitHeight: 38; radius: 9
                                color: theme.a(theme.line,0.4); border.width: 1; border.color: fontIn.activeFocus?theme.iris:theme.a(theme.iris,0.16)
                                TextInput { id: fontIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 13; font.family: root.apFont; clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris,0.4)
                                    Component.onCompleted: text = root.apFont
                                    onAccepted: root.addCustomFont(text)
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: fontIn.text===""; text: "type a font name, ↵ to save it as a chip"; color: theme.faint; font.pixelSize: 13; font.family: root.apFont } } }
                            Text { text: "changes apply to the bar live"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont }
                        }

                        // ================= ACTIONS =================
                        ColumnLayout {
                            visible: root.tab === 5; Layout.fillWidth: true; spacing: 14
                            Section { title: "quick actions"; icon: "bolt" }
                            GridLayout {
                                columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
                                Row2 { icon: "refresh"; label: "Reload Hyprland"; cmd: "hyprctl reload"; quitAfter: true }
                                Row2 { icon: "restart_alt"; label: "Restart bar"; cmd: "pkill -f 'sea-shell'; sleep 0.3; qs -c sea-shell & disown"; quitAfter: true }
                                Row2 { icon: "terminal"; label: "Terminal"; cmd: "kitty & disown"; quitAfter: true }
                                Row2 { icon: "wallpaper"; label: "Wallpapers"; cmd: "qs -p " + root.repo + "/wallpaper.qml & disown"; quitAfter: true }
                                Row2 { icon: "content_paste"; label: "Clipboard history"; cmd: "qs -c sea-shell ipc call launcher clipboard"; quitAfter: true }
                                Row2 { icon: "photo_camera"; label: "Screenshot → clipboard"; cmd: "sleep 0.2; grim -g \"$(slurp)\" - | wl-copy"; quitAfter: true }
                                Row2 { icon: "keyboard"; label: "Keybinds — search · rebind"; cmd: "qs -p " + root.repo + "/keybinds.qml & disown"; quitAfter: true }
                                Row2 { icon: "edit_note"; label: "Edit keybinds"; cmd: "xdg-open \"$(dirname \"$(readlink -f ~/.config/quickshell/sea-shell)\")/hypr/keybinds.conf\" & disown"; quitAfter: true }
                                Row2 { icon: "settings"; label: "Edit configs"; cmd: "kitty --directory " + root.repo + "/.. & disown"; quitAfter: true }
                            }
                        }

                        // ================= KEYBINDS =================
                        ColumnLayout {
                            visible: root.tab === 7; Layout.fillWidth: true; spacing: 10
                            Section { title: "keybinds"; icon: "keyboard" }
                            // search
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 32; radius: 8
                                color: theme.a(theme.line, 0.4)
                                border.width: 1; border.color: kbField.text!=="" ? theme.a(theme.iris,0.5) : theme.a(theme.iris,0.2)
                                Sym { id: kbLens; text: "search"; sz: 15; color: theme.faint
                                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter } }
                                TextInput {
                                    id: kbField
                                    anchors { left: kbLens.right; leftMargin: 8; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                    color: theme.text; font.pixelSize: 13; font.family: "monospace"; clip: true
                                    onTextChanged: root.kbQuery = text
                                    Text { text: "type to filter · click a bind to rebind it"; visible: kbField.text===""
                                        color: theme.faint; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                    Keys.onPressed: (e)=> {
                                        if (e.key === Qt.Key_Escape) { if (root.kbRec) { root.kbRec = null; root.kbConflict = "" } else Qt.quit(); e.accepted = true; return }
                                        if (root.kbRec) {
                                            if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                            var n = root.kbKeyName(e);
                                            if (n) root.kbApply(n); else root.kbConflict = "unsupported key";
                                            e.accepted = true;
                                        }
                                    }
                                }
                            }
                            // recording bar: modifier chips + status
                            RowLayout {
                                visible: root.kbRec !== null; Layout.fillWidth: true; spacing: 8
                                Text { text: "rebind “" + (root.kbRec ? root.kbRec.desc : "") + "”:"
                                    color: theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                Repeater {
                                    model: ["SUPER","CTRL","ALT","SHIFT"]
                                    delegate: Rectangle {
                                        required property string modelData
                                        readonly property bool on: root.kbRecMods.indexOf(modelData) >= 0
                                        implicitWidth: kmc.width + 14; implicitHeight: 22; radius: 11
                                        color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5)
                                        border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                        Text { id: kmc; anchors.centerIn: parent; text: modelData
                                            color: on ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace"; font.bold: on }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: { var m = root.kbRecMods.slice(); var i = m.indexOf(modelData);
                                                if (i >= 0) m.splice(i,1); else m.push(modelData);
                                                root.kbRecMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x => m.indexOf(x) >= 0);
                                                root.kbConflict = ""; kbField.forceActiveFocus() } }
                                    }
                                }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight
                                    text: root.kbConflict !== "" ? root.kbConflict : "press the new key · esc cancels"
                                    color: root.kbConflict !== "" ? theme.bad : theme.sub; font.pixelSize: 11; font.family: "monospace" }
                            }
                            // bind rows
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.kbShown
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool isRec: root.kbRec !== null && root.kbRec.desc === modelData.desc && root.kbRec.key === modelData.key
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: isRec ? theme.a(theme.iris, 0.2) : kbh.containsMouse ? theme.a(theme.iris, 0.12) : theme.a(theme.line, 0.32)
                                        border.width: 1; border.color: isRec ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 10
                                            Text { text: modelData.desc; color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Sym { visible: kbh.containsMouse && modelData.canEdit && !isRec; text: "edit"; sz: 14; color: theme.faint }
                                            Rectangle { implicitHeight: 22; implicitWidth: kbk.implicitWidth + 16; radius: 6
                                                color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                Text { id: kbk; anchors.centerIn: parent; text: modelData.keys; color: theme.frost; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                        }
                                        MouseArea { id: kbh; anchors.fill: parent; hoverEnabled: true
                                            cursorShape: modelData.canEdit ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onClicked: { if (!modelData.canEdit) return;
                                                root.kbRec = modelData; root.kbRecMods = modelData.mods.slice(); root.kbConflict = "";
                                                kbField.forceActiveFocus() } }
                                    }
                                }
                            }
                            Text { text: root.kbShown.length + "/" + root.kbBinds.length + " binds · rebinds rewrite keybinds.conf + reload hyprland"
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                        }

                        // ================= POWER =================
                        ColumnLayout {
                            visible: root.tab === 6; Layout.fillWidth: true; spacing: 14
                            Section { title: "session"; icon: "power_settings_new" }
                            GridLayout {
                                columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
                                Row2 { icon: "lock"; label: "Lock"; cmd: "loginctl lock-session"; quitAfter: true }
                                Row2 { icon: "bedtime"; label: "Suspend"; cmd: "systemctl suspend"; quitAfter: true }
                                Row2 { icon: "logout"; label: "Logout"; cmd: "hyprctl dispatch exit"; quitAfter: true }
                                Row2 { icon: "restart_alt"; label: "Reboot"; cmd: "systemctl reboot"; tint: theme.bad; quitAfter: true }
                                Row2 { icon: "power_settings_new"; label: "Shutdown"; cmd: "systemctl poweroff"; tint: theme.bad; quitAfter: true }
                            }
                        }
                    }
                }
        }
    }
}
