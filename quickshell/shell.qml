//@ pragma UseQApplication
// sea-shell — Quickshell bar with clickable dropdowns, themed after miyukivigil.tech
// Verified on Quickshell 0.3.0.  Icons: Material Symbols Outlined.
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris
import Quickshell.Services.Notifications
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root

    // resident launcher — no process-spawn delay; open via `qs -c sea-shell ipc call launcher …`
    Launcher { id: launcher }
    IpcHandler {
        target: "launcher"
        function toggle(): void { launcher.toggle() }
        function clipboard(): void { launcher.open(";") }
    }

    // resident settings (control center) — preloaded in the background so opening is instant
    // instead of spawning a ~0.5s `qs -p settings.qml`. Toggle via its own "settings" IPC
    // (SUPER+S) or, in-process, settingsLoader.item.openTab(n). asynchronous → never blocks
    // the bar at login; the item lands ~½s after startup, long before the user opens it.
    Loader { id: settingsLoader; asynchronous: true; active: true; source: Qt.resolvedUrl("settings.qml") }
    function openSettings(tab) { if (settingsLoader.item) settingsLoader.item.openTab(tab) }
    property string openPop: ""      // only one dropdown open at a time
    property var openBar: null       // …and only on the monitor whose pill was clicked
    // one shared click-outside grab covering every monitor's bar + dropdowns.
    // Screenshot tools "pin" the shell first — slurp/grim steal focus, and without
    // the hold the dropdown being screenshotted would close before the capture.
    property var grabWins: []
    property bool grabHold: false
    IpcHandler {
        target: "shell"
        function pin(): void { root.grabHold = true }
        function unpin(): void { root.grabHold = false }
        function toggleExpose(): void { root.toggleExpose() }
        function toggleIdle(): void { root.toggleIdle() }
    }

    // ---------- alt-tab window switcher (resident, driven by ALT+Tab binds) ----------
    property bool switcherOpen: false
    property int switcherSel: 0
    // every open window, most-recently-used first (focusHistoryID 0 = current)
    readonly property var switcherWins: {
        var m = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var out = [];
        for (var i=0;i<m.length;i++) { var t=m[i];
            if (t && t.lastIpcObject && (""+(t.lastIpcObject.class||"")) !== "") out.push(t); }
        out.sort(function(a,b){ return (a.lastIpcObject.focusHistoryID||0) - (b.lastIpcObject.focusHistoryID||0); });
        return out;
    }
    function switcherStep(dir) {
        var n = root.switcherWins.length; if (n === 0) return;
        if (!root.switcherOpen) { root.switcherOpen = true; root.switcherSel = (n > 1 ? (dir > 0 ? 1 : n - 1) : 0); }
        else root.switcherSel = ((root.switcherSel + dir) % n + n) % n;
    }
    function switcherCommit() {
        if (!root.switcherOpen) return; root.switcherOpen = false;
        var w = root.switcherWins[root.switcherSel];
        if (w && w.lastIpcObject && w.lastIpcObject.address)
            Hyprland.dispatch("focuswindow address:" + w.lastIpcObject.address);
    }
    IpcHandler {
        target: "switcher"
        function next(): void { root.switcherStep(1) }
        function prev(): void { root.switcherStep(-1) }
        function commit(): void { root.switcherCommit() }
        function cancel(): void { root.switcherOpen = false }
    }
    HyprlandFocusGrab {
        windows: root.grabWins
        active: root.openPop !== "" && !root.grabHold
        onCleared: root.openPop = ""
    }

    // ---------- appearance (live-reloaded from ~/.config/sea-shell/appearance.json) ----------
    property real cfgRadius: 14
    property real cfgOpacity: 0.80
    property int  cfgHeight: 42
    property string cfgAccent: "#63c7dd"
    property string cfgFont: "monospace"
    property bool   cfgLight: false          // dark (default) ↔ light palette
    property string cfgBarFill: "matugen"    // top-bar fill: matugen (accent-tinted) · black · white
    property string cfgEdge: "top"           // which screen edge the bar docks to: top or bottom
    property bool cfgMpris: true
    property bool cfgTray: true
    property bool cfgWeather: true
    property bool cfgClipboard: true
    property bool cfgNotif: true
    property bool cfgWifi: true
    property bool cfgBluetooth: true
    property bool cfgCaffeine: true
    property bool cfgSystem: true
    property bool cfgVolume: true
    property bool cfgBattery: true
    property bool cfgClock: true
    property bool cfgPower: true
    // horizontal bar only — left/right (a vertical bar) was removed; this shell was never
    // designed for it and the narrow strip never laid out cleanly. Kept as a constant so the
    // (now dormant) orientation-aware branches below all resolve to the horizontal layout.
    readonly property bool barVertical: false
    // bar background colour. "matugen" is a VISIBLY accent-tinted dark/light — theme.bg itself
    // is deliberately near-black (lightness 0.07) so it reads as black at 100% opacity, hiding
    // the hue; the bar lifts the lightness + saturation so the wallpaper colour actually shows.
    // "black"/"white" are clean neutrals. Only affects the top bar; dropdowns stay theme.bg.
    readonly property color barFillColor: cfgBarFill === "black" ? "#0a0d12"
                                        : cfgBarFill === "white" ? "#f5f8fb"
                                        : theme.light ? Qt.hsla(theme._ah, 0.18, 0.90, 1)
                                                      : Qt.hsla(theme._ah, 0.46, 0.135, 1)

    // Propagate the shell's light/dark choice to the SYSTEM: gsettings color-scheme
    // (so GTK apps + browsers' prefers-color-scheme follow, via xdg-desktop-portal) and
    // kitty. Every mode change — the SUPER+⇧+D key, the settings toggle, and the auto
    // schedule — lands in appearance.json, which the FileView below watches, so this one
    // hook covers them all (and syncs the system to the saved mode on startup).
    readonly property string _applyModeSh: Qt.resolvedUrl("sea-apply-mode.sh").toString().replace("file://","")
    property int _appliedMode: -1            // -1 unknown · 0 dark · 1 light (guards non-mode edits)
    function applyMode() {
        root._appliedMode = root.cfgLight ? 1 : 0;
        modeProc.command = ["sh", root._applyModeSh, root.cfgLight ? "light" : "dark"];
        modeProc.running = false; modeProc.running = true;
    }
    Process { id: modeProc }

    // Dropdowns stay glassy (semi-transparent + blur). The bright-background washout
    // is solved by the `xray` layer rule (sea.conf) — the blur samples the wallpaper,
    // not whatever bright window is behind — so a low opacity reads fine over the dark
    // wallpaper. Light mode needs more body (a translucent light card over the dark
    // wallpaper would go muddy), so it sits higher.
    readonly property real dropOpacity: root.cfgLight ? Math.max(0.55, root.cfgOpacity)
                                                      : Math.max(0.35, root.cfgOpacity)
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; touch \"$d/kitty-matugen.conf\"; [ -f \"$d/appearance.json\" ] || printf '{\"radius\":14,\"opacity\":0.80,\"height\":42,\"accent\":\"#63c7dd\",\"font\":\"monospace\"}' > \"$d/appearance.json\"; echo \"$d/appearance.json\""]
        stdout: StdioCollector { id: apprPathOut; onStreamFinished: apprFile.path = apprPathOut.text.trim() } }
    FileView {
        id: apprFile; path: ""; watchChanges: true
        function apply() { try {
            reload();                                  // pull the latest bytes (needed for live changes)
            var t = text(); if(!t || !t.trim()) return; var j = JSON.parse(t);
            if (j.radius  !== undefined) root.cfgRadius  = j.radius;
            if (j.opacity !== undefined) root.cfgOpacity = j.opacity;
            if (j.barFill !== undefined && (""+j.barFill).length>0) root.cfgBarFill = j.barFill;
            // top / bottom only — this shell is a horizontal bar; left/right were dropped.
            if (j.edge === "top" || j.edge === "bottom") root.cfgEdge = j.edge;
            if (j.height  !== undefined) root.cfgHeight  = j.height;
            if (j.accent  !== undefined && (""+j.accent).length>0) root.cfgAccent = j.accent;
            if (j.font    !== undefined && (""+j.font).length>0)   root.cfgFont   = j.font;
            if (j.mode    !== undefined) root.cfgLight = (""+j.mode === "light");
            if (j.wgMpris !== undefined) root.cfgMpris = !!j.wgMpris;
            if (j.wgTray !== undefined) root.cfgTray = !!j.wgTray;
            if (j.wgWeather !== undefined) root.cfgWeather = !!j.wgWeather;
            if (j.wgClipboard !== undefined) root.cfgClipboard = !!j.wgClipboard;
            if (j.wgNotif !== undefined) root.cfgNotif = !!j.wgNotif;
            if (j.wgWifi !== undefined) root.cfgWifi = !!j.wgWifi;
            if (j.wgBluetooth !== undefined) root.cfgBluetooth = !!j.wgBluetooth;
            if (j.wgCaffeine !== undefined) root.cfgCaffeine = !!j.wgCaffeine;
            if (j.wgSystem !== undefined) root.cfgSystem = !!j.wgSystem;
            if (j.wgVolume !== undefined) root.cfgVolume = !!j.wgVolume;
            if (j.wgBattery !== undefined) root.cfgBattery = !!j.wgBattery;
            if (j.wgClock !== undefined) root.cfgClock = !!j.wgClock;
            if (j.wgPower !== undefined) root.cfgPower = !!j.wgPower;
            if ((root.cfgLight ? 1 : 0) !== root._appliedMode) root.applyMode();  // sync system + kitty on flip/startup
        } catch(e) {} }
        onLoaded: apply()
        onFileChanged: apply()
    }
    // auto dark-mode schedule — sea-theme-schedule.sh flips `mode` in appearance.json
    // when the clock crosses the configured window; the FileView above then applies it.
    Process { id: themeSched; command: ["sh", Qt.resolvedUrl("sea-theme-schedule.sh").toString().replace("file://","")] }
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: themeSched.running = true }
    // ---------- calendar events database ----------
    property var calEvents: []
    function calDate(s) { var p = (""+s).split("-"); return new Date(parseInt(p[0]), (parseInt(p[1])||1)-1, parseInt(p[2])||1); }
    function calTodayKey() { var t = clock.date; return t.getFullYear() + "-" + String(t.getMonth()+1).padStart(2,"0") + "-" + String(t.getDate()).padStart(2,"0"); }
    // events from today onward, sorted chronologically (the clock dropdown's "upcoming" list —
    // the raw calEvents order is neither filtered nor sorted, so it used to surface past dates)
    readonly property var calUpcoming: {
        var key = root.calTodayKey();
        return root.calEvents.filter(function(e){ return (""+e.date) >= key; })
                             .sort(function(a,b){ return (""+a.date) < (""+b.date) ? -1 : (""+a.date) > (""+b.date) ? 1 : 0; });
    }
    function calRel(s) {
        var d = root.calDate(s); d.setHours(0,0,0,0);
        var now = new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate());
        var days = Math.round((d.getTime() - now.getTime()) / 86400000);
        if (days <= 0)  return "today";
        if (days === 1) return "tomorrow";
        if (days < 7)   return "in " + days + "d";
        if (days < 31)  return "in " + Math.round(days/7) + "w";
        return "in " + Math.round(days/30) + "mo";
    }
    Process {
        id: reloadEventsProc; running: true
        command: ["sh", "-c", "cat ~/.config/sea-shell/calendar_events.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: eventsOut; onStreamFinished: {
            try {
                root.calEvents = JSON.parse(eventsOut.text.trim() || "[]");
            } catch(e) {
                root.calEvents = [];
            }
        } }
    }
    // ---- subscribed .ics re-sync: "Import Link" remembers the URL; refresh it on a timer ----
    readonly property string _icsScript: Qt.resolvedUrl("sea-import-ics.py").toString().replace("file://","")
    Process { id: calResyncProc; command: ["python3", root._icsScript, "--resync"]
        stdout: StdioCollector { onStreamFinished: reloadEventsProc.running = true } }
    Timer { interval: 25000;          running: true; repeat: false; onTriggered: calResyncProc.running = true }   // freshen ~25s after login
    Timer { interval: 6*3600*1000;    running: true; repeat: true;  onTriggered: calResyncProc.running = true }   // and every 6h

    // ---- reminder settings (calendar.json, written by settings/import script) ----
    property bool calRemind: true
    property int  calLead: 30
    Process { id: calCfgProc; running: true; command: ["sh","-c","cat ~/.config/sea-shell/calendar.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: calCfgOut; onStreamFinished: { try { var j=JSON.parse(calCfgOut.text.trim()||"{}");
            if(j.remind!==undefined) root.calRemind=!!j.remind; if(j.lead!==undefined) root.calLead=j.lead; } catch(e){} } } }
    Timer { interval: 5*60000; running: true; repeat: true; onTriggered: calCfgProc.running = true }   // pick up settings changes

    // ---- reminders: fire a notification a lead-time before each event (timed events) or at
    //      08:00 on the day (all-day). Fired keys persist so a bar restart won't re-notify. ----
    property var calReminded: ({})
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/calendar-reminded.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: remOut; onStreamFinished: { try { root.calReminded = JSON.parse(remOut.text.trim()||"{}") } catch(e) { root.calReminded = {} } } } }
    function fireReminder(e, key, whenStr) {
        var m = root.calReminded; m[key] = 1;
        Quickshell.execDetached(["sh","-c","echo '" + Qt.btoa(JSON.stringify(m)) + "' | base64 -d > \"$HOME/.config/sea-shell/calendar-reminded.json\""]);
        Quickshell.execDetached(["notify-send","-a","sea-shell","-i","x-office-calendar","Reminder · " + e.title, whenStr + "  ·  " + e.date]);
    }
    function checkReminders() {
        if (!root.calRemind) return;
        var now = clock.date;
        for (var i=0;i<root.calEvents.length;i++) {
            var e = root.calEvents[i]; var key = e.date + "|" + e.title + "|" + (e.time||"");
            if (root.calReminded[key]) continue;
            var d = root.calDate(e.date);
            if (e.time && (""+e.time).indexOf(":")>0) {
                var hm = (""+e.time).split(":");
                var evt = new Date(d.getFullYear(), d.getMonth(), d.getDate(), parseInt(hm[0]), parseInt(hm[1]));
                var due = new Date(evt.getTime() - root.calLead*60000);
                if (now >= due && now <= evt) fireReminder(e, key, "at " + e.time);
            } else {
                var at8 = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 8, 0);
                var endDay = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59);
                if (now >= at8 && now <= endDay) fireReminder(e, key, "today");
            }
        }
    }
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.checkReminders() }

    QtObject {
        id: theme
        readonly property bool light: root.cfgLight
        // Surfaces follow the accent HUE at low saturation, so the whole shell tracks matugen
        // instead of a fixed navy — a subtle tint only (text keeps its high-contrast values).
        // The default/off accent is sea cyan, whose hue lands right back on the old deep-ocean
        // navy, so nothing jarring changes when matugen is off.
        readonly property color _acc: root.cfgAccent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    light ? Qt.hsla(_ah, 0.20, 0.945, 1) : Qt.hsla(_ah, 0.36, 0.070, 1)
        readonly property color panel: light ? Qt.hsla(_ah, 0.18, 0.895, 1) : Qt.hsla(_ah, 0.30, 0.110, 1)
        readonly property color line:  light ? Qt.hsla(_ah, 0.16, 0.780, 1) : Qt.hsla(_ah, 0.24, 0.205, 1)
        // The dropdowns are very translucent now, so the text does the readability work:
        // near-white in dark mode, near-black in light mode, with punchy secondaries.
        readonly property color text:  light ? "#08111c" : "#f2f6fc"
        readonly property color sub:   light ? "#213747" : "#cbd6e6"
        readonly property color faint: light ? "#3a4e5e" : "#9dabc1"
        // the raw accent is too pale for text/borders on a light card, so darken it hard
        // there — a pale accent (e.g. #96cdf8) only reads as text once it's well darkened.
        readonly property color iris:  light ? Qt.darker(root.cfgAccent, 2.4)  : root.cfgAccent
        readonly property color frost: light ? Qt.darker(root.cfgAccent, 1.7)  : Qt.lighter(root.cfgAccent, 1.22)
        readonly property color good:  light ? "#2f9e63" : "#a6e3a1"
        readonly property color warn:  light ? "#b9820f" : "#f4c542"
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // ---------- audio ----------
    property var sinks: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isSink && !n.isStream && n.audio })
    PwObjectTracker { objects: { var a = []; if (Pipewire.defaultAudioSink) a.push(Pipewire.defaultAudioSink); for (var i=0;i<root.sinks.length;i++) a.push(root.sinks[i]); return a } }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "device") : "" }

    // ---------- wifi ----------
    property var wifiList: []
    property string ssid: ""
    property bool wifiOn: false
    // Connection state comes from the DEVICE state (authoritative + instant), NOT from
    // the scan list's ACTIVE column. That column depends on scan freshness and can drop
    // the active AP for several polls right after a reconnect — which left the bar icon
    // stuck on "disconnected". `dev status` always reflects reality, so poll it on its own.
    Process {
        id: wifiStatus; running: true
        command: ["sh","-c","nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null | awk -F: '$2==\"wifi\"{print $3 \"\\t\" $4; exit}'"]
        stdout: StdioCollector { id: wifiStatOut; onStreamFinished: {
            var t = wifiStatOut.text.replace(/\n$/,"");
            if (!t) { root.wifiOn = false; root.ssid = ""; return }
            var p = t.split("\t"); var st = p[0]||""; var conn = p[1]||"";
            root.wifiOn = (st === "connected");
            root.ssid = root.wifiOn ? conn : "";
        } }
    }
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: wifiStatus.running = true }
    // the network list for the dropdown (styling only — active row cross-checks the
    // connected SSID from dev status so a stale ACTIVE column can't mis-highlight)
    Process {
        id: wifiScan; running: true
        command: ["sh", "-c", "nmcli -t -f ACTIVE,SIGNAL,SECURITY,SSID dev wifi 2>/dev/null | awk -F: 'length($4)>0' | sort -t: -k2 -rn | head -8"]
        stdout: StdioCollector { id: wifiOut; onStreamFinished: {
            var out = []; var lines = wifiOut.text.trim().split("\n");
            for (var i=0;i<lines.length;i++){ if(!lines[i])continue; var p=lines[i].split(":");
                var sid=p.slice(3).join(":");
                var e={active:(p[0]==="yes")||(root.ssid!=="" && sid===root.ssid),signal:parseInt(p[1])||0,secure:(p[2]||"").length>0,ssid:sid};
                out.push(e); }
            root.wifiList = out;
        } }
    }
    Timer { interval: 8000; running: true; repeat: true; triggeredOnStart: true; onTriggered: wifiScan.running = true }
    property string wifiPwFor: ""     // ssid awaiting an inline password
    property string wifiRetry: ""     // ssid whose saved profile we're trying first
    // known networks reconnect with their STORED password (`nmcli con up`); the
    // inline field only appears for new networks or when the saved secret fails.
    Process { id: wifiUp
        stdout: StdioCollector { id: wupOut; onStreamFinished: {
            var ok = wupOut.text.indexOf("successfully") >= 0;
            if (!ok && root.wifiRetry !== "") root.wifiPwFor = root.wifiRetry;   // no/bad profile → ask
            else root.wifiPwFor = "";
            root.wifiRetry = ""; wifiRefresh.start();
        } } }
    function wifiConnect(s, secure) {
        var e = s.replace(/'/g,"");
        if (secure) {
            root.wifiRetry = s;
            wifiUp.command = ["sh","-c","nmcli con up id '"+e+"' 2>&1"];
            wifiUp.running = true; return;
        }
        Quickshell.execDetached(["sh","-c","nmcli dev wifi connect '"+e+"' || notify-send 'sea-shell' 'Could not join "+e+"'"]);
        root.wifiPwFor = ""; wifiRefresh.start();
    }
    // join with the typed password; blank password falls back to any saved credentials
    function wifiJoin(s, pw) {
        var e = s.replace(/'/g,""); var p = (pw||"");
        var cmd = p.length>0
            ? "nmcli dev wifi connect '"+e+"' password '"+p.replace(/'/g,"'\\''")+"'"
            : "nmcli dev wifi connect '"+e+"'";
        Quickshell.execDetached(["sh","-c",cmd+" && notify-send 'sea-shell' 'Connected to "+e+"' || notify-send 'sea-shell' 'Wrong password or could not join "+e+"'"]);
        root.wifiPwFor = ""; wifiRefresh.start();
    }
    function wifiToggle() { Quickshell.execDetached(["sh","-c","nmcli radio wifi | grep -q enabled && nmcli radio wifi off || nmcli radio wifi on"]); wifiRefresh.start() }
    Timer { id: wifiRefresh; interval: 2500; onTriggered: { wifiScan.running = true; wifiStatus.running = true } }

    // ---------- cloudflare warp ----------
    property string warpStatus: "Disconnected"   // raw status line from warp-cli
    property bool warpConnected: warpStatus.indexOf("Connected") >= 0 && warpStatus.indexOf("Disconnected") < 0
    property string warpMode: "warp"              // current mode (warp | doh | warp+doh | tunnel_only)
    Process {
        id: warpPoll; running: true
        command: ["sh","-c","warp-cli status 2>/dev/null | grep '^Status' | sed 's/Status update: //'"]
        stdout: StdioCollector { id: warpOut; onStreamFinished: {
            var s = warpOut.text.trim(); if (s) root.warpStatus = s; } }
    }
    Process {
        id: warpModePoll; running: true
        command: ["sh","-c","warp-cli mode 2>/dev/null | head -1 | awk '{print $NF}'"]
        stdout: StdioCollector { id: warpModeOut; onStreamFinished: {
            var m = warpModeOut.text.trim(); if (m) root.warpMode = m; } }
    }
    Timer { interval: 4000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { warpPoll.running = true; warpModePoll.running = true } }
    function warpToggle() {
        if (root.warpConnected) {
            Quickshell.execDetached(["sh","-c","warp-cli disconnect && notify-send 'sea-shell' 'WARP disconnected'"]);
            root.warpStatus = "Disconnected";
        } else {
            Quickshell.execDetached(["sh","-c","warp-cli connect && notify-send 'sea-shell' 'WARP connected' || notify-send 'sea-shell' 'WARP failed to connect'"]);
            root.warpStatus = "Connecting...";
        }
        warpTimer.start();
    }
    function warpSetMode(m) {
        Quickshell.execDetached(["sh","-c","warp-cli mode "+m]);
        root.warpMode = m; warpTimer.start();
    }
    Timer { id: warpTimer; interval: 1800; repeat: false; onTriggered: { warpPoll.running = true; warpModePoll.running = true } }

    // ---------- vpn (networkmanager) ----------
    property var vpnList: []   // [{name, type, state, active}]
    property string vpnActionName: ""
    property string vpnFailedName: ""
    Timer { id: vpnFailTimer; interval: 6000; repeat: false; onTriggered: root.vpnFailedName = "" }

    Process {
        id: vpnActionProc
        onExited: (code) => {
            var ok = code === 0;
            if (!ok) {
                root.vpnFailedName = root.vpnActionName;
                vpnFailTimer.start();
                Quickshell.execDetached(["sh","-c","notify-send -u critical 'sea-shell' 'VPN connection failed'"]);
            } else {
                root.vpnFailedName = "";
            }
            root.vpnActionName = "";
            vpnScan.running = true;
        }
    }

    Process {
        id: vpnScan; running: true
        command: ["sh","-c","nmcli -t -f NAME,TYPE,STATE,ACTIVE con show 2>/dev/null | grep -E ':(vpn|wireguard):'"]
        stdout: StdioCollector { id: vpnOut; onStreamFinished: {
            var out = []; var lines = vpnOut.text.trim().split("\n");
            for (var i=0; i<lines.length; i++) {
                if (!lines[i]) continue;
                var p = lines[i].split(":");
                if (p.length < 4) continue;
                out.push({ name: p[0], type: p[1], state: p[2], active: p[3]==="yes" });
            }
            root.vpnList = out;
        } }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: vpnScan.running = true }
    function vpnToggle(name) {
        if (root.vpnActionName !== "") return;
        root.vpnActionName = name;
        root.vpnFailedName = "";
        var e = name.replace(/'/g,"");
        var cur = root.vpnList.find(function(v){ return v.name===name && v.state==="activated"; });
        if (cur) {
            vpnActionProc.command = ["nmcli", "con", "down", "id", e];
        } else {
            vpnActionProc.command = ["nmcli", "con", "up", "id", e];
        }
        vpnActionProc.running = true;
        vpnScan.running = true;
    }


    // ---------- bluetooth ----------
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btDevices: (btAdapter && btAdapter.devices) ? btAdapter.devices.values : []
    readonly property var btActive: { var d = root.btDevices; for (var i=0;i<d.length;i++) if (d[i] && d[i].connected) return d[i]; return null }
    function btName(d) { return d ? (d.deviceName || d.name || d.address || "device") : "" }
    function btIcon(d) {
        var ic = d ? (""+(d.icon||"")).toLowerCase() : "";
        if (ic.indexOf("headset")>=0 || ic.indexOf("headphone")>=0 || ic.indexOf("audio")>=0) return "headphones";
        if (ic.indexOf("mouse")>=0) return "mouse";
        if (ic.indexOf("keyboard")>=0) return "keyboard";
        if (ic.indexOf("phone")>=0) return "smartphone";
        if (ic.indexOf("watch")>=0) return "watch";
        if (ic.indexOf("speaker")>=0) return "speaker";
        return "bluetooth";
    }

    // ---------- weather (location + unit read from files each fetch) ----------
    property string wxTemp: ""      // e.g. 25°C
    property string wxCond: ""      // e.g. Patchy rain nearby
    property string wxFeels: ""
    property string wxHumid: ""
    property string wxWind: ""
    Process {
        id: wxProc; running: true
        // %t temp · %C condition · %f feels · %h humidity · %w wind ; unit file: m (metric) / u (uscs)
        command: ["sh","-c","loc=$(cat ~/.config/sea-shell/location 2>/dev/null || echo Kuching); u=$(cat ~/.config/sea-shell/wxunit 2>/dev/null || echo m); curl -s --max-time 8 \"wttr.in/$loc?format=%t|%C|%f|%h|%w&$u\" 2>/dev/null | sed 's/+//g'"]
        stdout: StdioCollector { id: wxOut; onStreamFinished: {
            var p = wxOut.text.trim().split("|");
            if (p.length >= 5) { root.wxTemp=p[0].trim(); root.wxCond=p[1].trim(); root.wxFeels=p[2].trim(); root.wxHumid=p[3].trim(); root.wxWind=p[4].trim(); }
        } }
    }
    Timer { interval: 900000; running: true; repeat: true; triggeredOnStart: true; onTriggered: wxProc.running = true }
    // ---- forecast (3-day, from wttr.in j1) ----
    property var wxForecast: []     // [{day, icon, hi, lo, cond}]
    Process {
        id: wxfProc; running: true
        command: ["sh","-c","loc=$(cat ~/.config/sea-shell/location 2>/dev/null || echo Kuching); curl -s --max-time 10 \"wttr.in/$loc?format=j1\" 2>/dev/null"]
        stdout: StdioCollector { id: wxfOut; onStreamFinished: {
            try {
                var u = "m"; // read unit lazily via wxUnitProbe below; default metric
                var j = JSON.parse(wxfOut.text); var out = [];
                var days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
                for (var i=0;i<Math.min(3,(j.weather||[]).length);i++) {
                    var w = j.weather[i];
                    var d = new Date(w.date+"T12:00:00");
                    var mid = (w.hourly && w.hourly.length>4) ? w.hourly[4] : (w.hourly?w.hourly[0]:null);
                    var cond = mid && mid.weatherDesc && mid.weatherDesc[0] ? mid.weatherDesc[0].value : "";
                    out.push({ day: (i===0?"today":days[d.getDay()]),
                               hi: root.wxUnitU ? w.maxtempF+"°" : w.maxtempC+"°",
                               lo: root.wxUnitU ? w.mintempF+"°" : w.mintempC+"°",
                               cond: cond });
                }
                root.wxForecast = out;
            } catch(e) {}
        } }
    }
    property bool wxUnitU: false
    Process { id: wxUnitProbe; running: true; command: ["sh","-c","cat ~/.config/sea-shell/wxunit 2>/dev/null"]
        stdout: StdioCollector { id: wxuOut; onStreamFinished: root.wxUnitU = (wxuOut.text.trim()==="u") } }
    Timer { interval: 1800000; running: true; repeat: true; triggeredOnStart: true; onTriggered: { wxUnitProbe.running=true; wxfProc.running = true } }
    // pick a Material Symbol from the condition text
    function wxIcon(c) {
        c = (c||"").toLowerCase();
        if (c.indexOf("thunder")>=0) return "thunderstorm";
        if (c.indexOf("snow")>=0||c.indexOf("sleet")>=0||c.indexOf("ice")>=0) return "weather_snowy";
        if (c.indexOf("rain")>=0||c.indexOf("drizzle")>=0||c.indexOf("shower")>=0) return "rainy";
        if (c.indexOf("fog")>=0||c.indexOf("mist")>=0||c.indexOf("haze")>=0) return "foggy";
        if (c.indexOf("overcast")>=0) return "cloud";
        if (c.indexOf("cloud")>=0||c.indexOf("partly")>=0) return "partly_cloudy_day";
        if (c.indexOf("clear")>=0||c.indexOf("sunny")>=0) return "sunny";
        return "cloud";
    }

    // ---------- power profiles ----------
    property string powerProfile: "balanced"
    Process { id: ppGet; running: true; command: ["sh","-c","powerprofilesctl get 2>/dev/null"]
        stdout: StdioCollector { id: ppOut; onStreamFinished: root.powerProfile = (ppOut.text.trim() || "balanced") } }
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: ppGet.running = true }
    function setProfile(p) { Quickshell.execDetached(["powerprofilesctl","set",p]); root.powerProfile = p; ppRefresh.start() }
    Timer { id: ppRefresh; interval: 800; onTriggered: ppGet.running = true }

    // ---------- system monitor (cpu · ram · gpu) ----------
    property real cpuUsage: 0     // %
    property real cpuTemp: 0      // °C
    property real memUsed: 0      // GiB
    property real memTotal: 0     // GiB
    property real memPct: 0       // %
    property string gpuName: ""   // "" when no discrete GPU
    property bool  hasGpu: false
    property real gpuUsage: 0     // %
    property real gpuTemp: 0      // °C
    property real gpuPower: 0     // W
    property real gpuMemUsed: 0   // GiB
    property real gpuMemTotal: 0  // GiB
    // sea-sysmon.sh samples /proc + nvidia-smi and prints one pipe-delimited line
    Process {
        id: sysProc; running: true
        command: ["bash", Qt.resolvedUrl("sea-sysmon.sh").toString().replace("file://","")]
        stdout: StdioCollector { id: sysOut; onStreamFinished: {
            var p = sysOut.text.trim().split("|");
            if (p.length < 11) return;
            root.cpuUsage    = parseFloat(p[0]) || 0;
            root.cpuTemp     = parseFloat(p[1]) || 0;
            root.memUsed     = parseFloat(p[2]) || 0;
            root.memTotal    = parseFloat(p[3]) || 0;
            root.memPct      = parseFloat(p[4]) || 0;
            root.gpuName     = p[5] || "";
            root.hasGpu      = root.gpuName !== "";
            root.gpuUsage    = parseFloat(p[6]) || 0;
            root.gpuTemp     = parseFloat(p[7]) || 0;
            root.gpuPower    = parseFloat(p[8]) || 0;
            root.gpuMemUsed  = parseFloat(p[9]) || 0;
            root.gpuMemTotal = parseFloat(p[10]) || 0;
        } }
    }
    // only poll while a bar is visible; 3s is a good live/quiet balance
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: sysProc.running = true }
    // color a value by thermal/load severity (green → warn → bad)
    function loadColor(v, warnAt, badAt) { return v >= badAt ? theme.bad : v >= warnAt ? theme.warn : theme.good }

    // ---------- low-battery alerts (through our own notification daemon via the bus) ----------
    property int battWarned: 0   // 0 none · 1 low fired · 2 critical fired — resets when charging
    function checkBatt() {
        var d = UPower.displayDevice;
        if (!d || !d.isLaptopBattery) return;
        if (!UPower.onBattery) { root.battWarned = 0; return }
        var p = Math.round((d.percentage||0)*100);
        if (p <= 5 && root.battWarned < 2) { root.battWarned = 2;
            Quickshell.execDetached(["notify-send","-u","critical","Battery critical","" + p + "% left — plug in NOW"]) }
        else if (p <= 15 && root.battWarned < 1) { root.battWarned = 1;
            Quickshell.execDetached(["notify-send","Battery low","" + p + "% remaining"]) }
    }
    Connections { target: UPower.displayDevice; ignoreUnknownSignals: true
        function onPercentageChanged() { root.checkBatt() } }
    Connections { target: UPower; ignoreUnknownSignals: true
        function onOnBatteryChanged() { root.checkBatt() } }

    // ---------- mpris ----------
    readonly property var players: { var ps = Mpris.players ? Mpris.players.values : []; var out=[]; for (var i=0;i<ps.length;i++) if (ps[i] && ps[i].canControl) out.push(ps[i]); return out }
    property int playerSel: 0
    readonly property var player: root.players.length ? root.players[Math.min(root.playerSel, root.players.length-1)] : null
    property real mprisPos: 0
    
    // ---------- cava audio visualizer ----------
    // (the bar-pill mini-visualizer was removed — it rendered as flat 1px "underscores" for
    // bit-perfect players like SONE that bypass PipeWire, so cava only ever saw silence.
    // The full visualizer inside the dropdown still runs; see cavaProc below.)
    property var visualizerValues: [0, 0, 0, 0, 0, 0, 0, 0]
    Process {
        id: barCavaProc
        running: false
        command: ["sh", "-c", "~/.config/quickshell/sea-shell/sea-cava.sh"]
        stdout: SplitParser {
            onRead: (line) => {
                var parts = line.trim().split(/\s+/);
                if (parts.length >= 8) {
                    var vals = [];
                    for (var i = 0; i < 8; i++) {
                        var v = parseInt(parts[i]);
                        vals.push(isNaN(v) ? 0 : Math.min(100, v) / 100.0);
                    }
                    root.visualizerValues = vals;
                }
            }
        }
    }
    // Poll fast (150ms) for tight lyric sync. Snap to the player's own clock whenever it
    // reports a fresh value (normal advance or a seek); between fresh reports — some players
    // only update position lazily — interpolate so the highlighted line glides instead of
    // jumping every 400ms.
    Timer { interval: 150; running: root.openPop==="mpris" && root.player!==null; repeat: true; triggeredOnStart: true
        property real lastReported: -1
        onTriggered: {
            if (!root.player) { root.mprisPos = 0; return }
            var p = root.player.positionSupported ? root.player.position : 0;
            if (p !== lastReported) { root.mprisPos = p; lastReported = p; }
            else if (root.player.isPlaying) { root.mprisPos += interval/1000; }
        } }
    function fmtTime(s) { s = Math.max(0, Math.floor(s||0)); var m = Math.floor(s/60); var ss = s%60; return m + ":" + (ss<10?"0":"") + ss }

    // ---------- screen recording status poll ----------
    property bool recordingActive: false
    property string recordingTime: "00:00"
    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: recStatusProc.running = true
    }
    Process {
        id: recStatusProc
        command: ["sh", "-c", "~/.config/quickshell/sea-shell/sea-record.sh status"]
        stdout: StdioCollector {
            id: recOut
            onStreamFinished: {
                var txt = recOut.text.trim();
                if (txt === "inactive" || !txt) {
                    root.recordingActive = false;
                } else {
                    root.recordingActive = true;
                    var parts = txt.split("|");
                    var sec = parseInt(parts[0]) || 0;
                    var m = Math.floor(sec / 60);
                    var s = sec % 60;
                    root.recordingTime = (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
                }
            }
        }
    }

    // ---------- bit-perfect quality readout ----------
    // Players like SONE (TIDAL) in bit-perfect mode bypass pipewire and open the DAC
    // directly via ALSA — the kernel's hw_params then holds the TRUE stream format.
    // We report the first RUNNING playback substream not owned by pipewire.
    property string hqInfo: ""
    Process { id: hqProc
        command: ["sh","-c","for d in /proc/asound/card*/pcm*p/sub*; do [ -f \"$d/status\" ] || continue; grep -q RUNNING \"$d/status\" 2>/dev/null || continue; pid=$(awk '/owner_pid/{print $3}' \"$d/status\"); comm=$(cat /proc/$pid/comm 2>/dev/null); case \"$comm\" in pipewire*|wireplumber*) continue;; esac; awk -v c=\"$comm\" '/^format:/{f=$2}/^rate:/{r=$2}END{if(f&&r)printf \"%s|%s|%s\", f, r, c}' \"$d/hw_params\"; break; done"]
        stdout: StdioCollector { id: hqOut; onStreamFinished: {
            var t = hqOut.text.trim();
            if (!t) { root.hqInfo = ""; return }
            var p = t.split("|"); var fmt = p[0] || ""; var rate = parseInt(p[1]) || 0;
            var bits = fmt.indexOf("S16")===0 ? "16" : fmt.indexOf("S24")===0 ? "24" : fmt.indexOf("S32")===0 ? "32" : fmt.indexOf("F32")===0 ? "32" : "";
            root.hqInfo = (bits && rate) ? bits + "-bit · " + (Math.round(rate/100)/10) + " kHz · bit-perfect" : "";
        } } }
    Timer { interval: 2000; running: root.openPop === "mpris"; repeat: true; triggeredOnStart: true; onTriggered: hqProc.running = true }

    // ambient visualizer for bit-perfect playback — pipewire can't see the stream
    // (that's the point of exclusive mode), so cava would sit at zero. Layered sines
    // + smoothing give a living wave while the track plays; purely decorative.
    property var fakeBars: []
    Timer {
        interval: 66; repeat: true
        running: root.openPop === "mpris" && root.hqInfo !== "" && root.player !== null && root.player.isPlaying
        onTriggered: {
            var t = Date.now() / 1000, prev = root.fakeBars, out = [];
            for (var i = 0; i < 22; i++) {
                var target = 34 + 26 * Math.sin(t * 2.3 + i * 0.52)
                                + 20 * Math.sin(t * 3.9 + i * 1.31 + 1.7)
                                + 16 * Math.random();
                var p = prev.length === 22 ? prev[i] : 0;
                out.push(Math.max(4, Math.min(100, 0.55 * p + 0.45 * target)));
            }
            root.fakeBars = out;
        }
    }
    // what the dropdown actually draws: real cava, or the ambient wave in bit-perfect mode
    readonly property var vizBars: root.hqInfo !== "" ? root.fakeBars : root.cavaValues

    // ---------- lyrics (lrclib.net — free, keyless; synced LRC when available) ----------
    property bool lyricsOpen: false
    property bool infoOpen: false        // track-details sidecar (opens on the opposite side of lyrics)
    property var lyrics: []              // [{t: seconds, l: line}] when synced
    property string plainLyrics: ""
    property string lyricsState: "idle"  // idle | loading | ok | plain | none
    property string lyricsKey: ""
    readonly property string trackKey: root.player ? (root.player.trackArtist||"")+"|"+(root.player.trackTitle||"") : ""
    onTrackKeyChanged: { root.lyricsState = "idle"; root.lyrics = []; root.plainLyrics = "";
        if (root.lyricsOpen && root.openPop==="mpris") root.fetchLyrics() }
    // current line follows playback (small lead so the line flips as it's sung)
    readonly property int lyrIdx: { var i = -1; for (var k=0;k<root.lyrics.length;k++) if (root.lyrics[k].t <= root.mprisPos + 0.2) i = k; else break; return i }
    function fetchLyrics(force) {
        if (!root.player) return;
        if (!force && root.lyricsKey === root.trackKey && root.lyricsState !== "idle") return;
        root.lyricsKey = root.trackKey; root.lyricsState = "loading"; root.lyrics = []; root.plainLyrics = "";
        lyrProc.running = false;
        // env-array → artist/title never touch shell quoting
        lyrProc.command = ["env",
            "A=" + (root.player.trackArtist||""), "T=" + (root.player.trackTitle||""),
            "AL=" + (root.player.trackAlbum||""), "D=" + Math.round(root.player.length||0),
            // Escalating fallback, each step run ONLY if the previous found no lyrics:
            //   1. exact get (artist+title+album+duration)
            //   2. search by artist+title
            //   3. search by title only — catches romanized-vs-original artist mismatches
            //      (e.g. MPRIS says "Shihoko Hirata" but lrclib indexes "平田志穂子")
            // The common case still resolves on step 1 (one request); only misses pay for more.
            // Prefix the reply with the track key this request was issued for (up to the \x1f).
            // parseLyrics drops any reply whose key no longer matches the current track — so a
            // slow fetch for the PREVIOUS source can't clobber the one we switched to.
            "sh","-c","printf '%s\\x1f' \"$A|$T\"; G=$(curl -sG --max-time 8 --compressed https://lrclib.net/api/get --data-urlencode \"artist_name=$A\" --data-urlencode \"track_name=$T\" --data-urlencode \"album_name=$AL\" --data-urlencode \"duration=$D\"); case $G in *'\"syncedLyrics\":\"'*|*'\"plainLyrics\":\"'*) printf '%s' \"$G\"; exit 0;; esac; S=$(curl -sG --max-time 8 --compressed https://lrclib.net/api/search --data-urlencode \"track_name=$T\" --data-urlencode \"artist_name=$A\"); case $S in *'\"syncedLyrics\":\"'*|*'\"plainLyrics\":\"'*) printf '%s' \"$S\"; exit 0;; esac; curl -sG --max-time 8 --compressed https://lrclib.net/api/search --data-urlencode \"track_name=$T\""]
        lyrProc.running = true;
    }
    Process { id: lyrProc
        stdout: StdioCollector { id: lyrOut; onStreamFinished: root.parseLyrics(lyrOut.text) } }
    function parseLyrics(raw) {
        // strip + verify the "artist|title\x1f" header the fetch stamped on its reply; a reply
        // for a track we've since switched away from is stale — drop it so it can't overwrite.
        var us = raw.indexOf("\x1f");
        if (us >= 0) { if (raw.slice(0, us) !== root.trackKey) return; raw = raw.slice(us + 1); }
        var parts = raw.split("\x1e"), rec = null;
        for (var p=0;p<parts.length && !rec;p++) {
            try { var j = JSON.parse(parts[p]); } catch(e) { continue }
            if (Array.isArray(j)) {                       // search results: first entry that HAS lyrics
                var f = null;
                for (var q=0;q<j.length;q++) if (j[q] && (j[q].syncedLyrics || j[q].plainLyrics)) { f = j[q]; break }
                j = f;
            }
            if (j && (j.syncedLyrics || j.plainLyrics)) rec = j;
        }
        if (!rec) { root.lyricsState = "none"; return }
        if (rec.syncedLyrics) {
            var out = [], re = /\[(\d+):(\d+(?:\.\d+)?)\](.*)/;
            rec.syncedLyrics.split("\n").forEach(line => {
                var m = re.exec(line); if (!m) return;
                var txt = m[3].trim(); if (txt === "") txt = "♪";
                out.push({ t: parseInt(m[1],10)*60 + parseFloat(m[2]), l: txt });
            });
            if (out.length) { out.sort((a,b)=>a.t-b.t); root.lyrics = out; root.lyricsState = "ok"; return }
        }
        if (rec.plainLyrics) { root.plainLyrics = rec.plainLyrics; root.lyricsState = "plain"; return }
        root.lyricsState = "none";
    }

    // ---------- cava audio visualizer (only runs while the music dropdown is open) ----------
    property var cavaValues: []
    Process {
        id: cavaProc
        running: root.openPop === "mpris" && root.hqInfo === ""   // no point capturing silence in bit-perfect mode
        // bash process substitution + exec → quickshell owns cava directly and can
        // actually kill it (piping into `cava -p /dev/stdin` leaked a cava per open)
        command: ["bash","-c","exec cava -p <(printf '[general]\\nframerate=60\\nbars=22\\nsleep_timer=1\\n[input]\\nmethod=pipewire\\nsource=auto\\n[output]\\nchannels=mono\\nmethod=raw\\nraw_target=/dev/stdout\\ndata_format=ascii\\nascii_max_range=100\\n[smoothing]\\nnoise_reduction=0.45')"]
        stdout: SplitParser { onRead: data => { root.cavaValues = data.split(";").filter(s => s !== "").map(v => parseInt(v,10)||0) } }
    }

    SystemClock { id: clock; precision: SystemClock.Seconds }

    property bool trayCollapsed: false
 
    // ---------- caffeine mode (idle & lock status) ----------
    property bool idleOn: false
    Process { id: idleChk; running: false; command: ["sh","-c","pgrep -x hypridle >/dev/null && echo on || echo off"]
        stdout: StdioCollector { id: idleOut; onStreamFinished: root.idleOn = idleOut.text.trim() === "on" } }
    Timer { id: idleTimer; interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: idleChk.running = true }
    function toggleIdle() {
        if (root.idleOn) {
            Quickshell.execDetached(["sh", "-c", "pkill -x hypridle; notify-send -i coffee 'sea-shell' 'Caffeine mode active — screen will stay on'"]);
            root.idleOn = false;
        } else {
            Quickshell.execDetached(["sh", "-c", "hyprctl dispatch exec hypridle; notify-send 'sea-shell' 'Caffeine mode inactive — normal sleep active'"]);
            root.idleOn = true;
        }
    }

    // keep clipboard history populated so CTRL+V / the bar icon work.
    // clip-watch.sh kills any stale watchers then starts exactly one pair (idempotent on restart).
    Process { running: true; command: ["sh", Qt.resolvedUrl("clip-watch.sh").toString().replace("file://","")] }

    // ---------- notifications (our own daemon: popups + bar center) ----------
    property var notes: []           // history for the center
    property int noteSeq: 0
    // Do Not Disturb: suppress on-screen popups (history still records everything). Persists
    // across restarts; critical-urgency notifications still pop through so alerts aren't lost.
    property bool dnd: false
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/dnd 2>/dev/null || echo 0"]
        stdout: StdioCollector { id: dndOut; onStreamFinished: root.dnd = (dndOut.text.trim() === "1") } }
    function setDnd(v) { root.dnd = v; Quickshell.execDetached(["sh","-c","echo " + (v?"1":"0") + " > \"$HOME/.config/sea-shell/dnd\""]); }
    ListModel { id: popupModel }      // transient on-screen popups
    NotificationServer {
        id: notifServer
        keepOnReload: false
        actionsSupported: false
        bodyImagesSupported: false
        bodyMarkupSupported: true
        imageSupported: true
        onNotification: (n) => {
            var k = ++root.noteSeq;
            var entry = { key: k, summary: (n.summary||""), body: (n.body||""),
                          appName: (n.appName||"notification"), urgency: n.urgency,
                          time: Qt.formatDateTime(new Date(), "HH:mm") };
            root.notes = [entry].concat(root.notes).slice(0, 40);
            // DND swallows the popup but keeps the history entry; critical (urgency 2) breaks through
            if (!root.dnd || n.urgency === 2)
                popupModel.insert(0, { key: k, summary: entry.summary, body: entry.body, appName: entry.appName, urg: n.urgency });
            // not tracked → server releases it after this handler; we've copied the fields
        }
    }
    function popDismiss(k) { for (var i=0;i<popupModel.count;i++) if (popupModel.get(i).key===k) { popupModel.remove(i); return } }
    function noteClear() { root.notes = []; popupModel.clear() }

    // ---------- OSD (volume + brightness) ----------
    property string osdKind: ""      // "vol" | "bright" | ""
    property real osdVal: 0
    property string osdIcon: ""
    property bool osdReady: false
    Timer { id: osdHide; interval: 1500; onTriggered: root.osdKind = "" }
    Timer { interval: 1400; running: true; onTriggered: root.osdReady = true }  // suppress OSD flash on startup
    function showOsd(kind, val, icon) { if(!root.osdReady) return; root.osdKind = kind; root.osdVal = val; root.osdIcon = icon; osdHide.restart() }

    readonly property var osdSink: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
    Connections {
        target: root.osdSink
        function onVolumeChanged() { root.showOsd("vol", root.osdSink.volume, root.osdSink.muted?"volume_off":(root.osdSink.volume<0.5?"volume_down":"volume_up")) }
        function onMutedChanged()  { root.showOsd("vol", root.osdSink.volume, root.osdSink.muted?"volume_off":"volume_up") }
    }

    // brightness: watch the backlight sysfs directly (no polling)
    property int brMax: 0
    property real brVal: 0
    Process { running: true; command: ["sh","-c","cat /sys/class/backlight/*/max_brightness 2>/dev/null | head -1"]
        stdout: StdioCollector { id: brMaxOut; onStreamFinished: { var v=parseInt(brMaxOut.text.trim()); if(!isNaN(v)) root.brMax=v } } }
    Process { running: true; command: ["sh","-c","ls /sys/class/backlight/*/brightness 2>/dev/null | head -1"]
        stdout: StdioCollector { id: brPathOut; onStreamFinished: { var p=brPathOut.text.trim(); if(p) brFile.path=p } } }
    FileView {
        id: brFile; path: ""; watchChanges: true
        function upd() { reload(); if(root.brMax>0){ var nv=parseInt(text().trim())/root.brMax; if(nv!==root.brVal){ root.brVal=nv; root.showOsd("bright", nv, "brightness_6") } } }
        onLoaded: upd()
        onFileChanged: upd()
    }

    // ============ components ============
    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"; font.pixelSize: sz
        color: theme.frost; verticalAlignment: Text.AlignVCenter
    }

    component Slider: Item {
        id: sl
        property real value: 0
        property color fill: theme.iris
        signal moved(real v)
        implicitHeight: 20; implicitWidth: 150
        function clamp(v){ return Math.max(0,Math.min(1,v)) }
        Rectangle { id: trk; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 6; radius: 3; color: theme.a(theme.line,0.85)
            Rectangle { width: trk.width*sl.clamp(sl.value); height: parent.height; radius: 3; color: sl.fill } }
        Rectangle { width: 14; height: 14; radius: 7; border.width: 2; border.color: sl.fill; color: theme.frost
            anchors.verticalCenter: parent.verticalCenter; x: (sl.width-width)*sl.clamp(sl.value) }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onPressed: (e)=>{ var v=sl.clamp(e.x/sl.width); sl.value=v; sl.moved(v) }
            onPositionChanged: (e)=>{ if(pressed){ var v=sl.clamp(e.x/sl.width); sl.value=v; sl.moved(v) } } }
    }

    // labelled progress bar used in the system-monitor dropdown
    component StatBar: Column {
        property string label: ""
        property real value: 0            // 0..100
        property string rightText: ""
        property color barColor: theme.iris
        spacing: 4
        Item { width: parent.width; height: 15
            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                text: label; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                text: rightText; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true } }
        Rectangle { width: parent.width; height: 6; radius: 3; color: theme.a(theme.line,0.85)
            Rectangle { height: parent.height; radius: 3; color: barColor
                width: parent.width * Math.max(0, Math.min(1, value/100))
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } } } }
    }

    component Marquee: Item {
        id: mq
        property alias text: staticTxt.text
        property alias color: staticTxt.color
        property alias font: staticTxt.font
        property int maxW: 160

        readonly property bool scrolling: staticTxt.implicitWidth > mq.maxW
        // gap between end of text and the ghost copy that follows
        readonly property int gap: 48
        // total stride = text width + gap; scrolling loops over this distance
        readonly property int stride: staticTxt.implicitWidth + gap

        implicitHeight: staticTxt.implicitHeight
        implicitWidth: scrolling ? mq.maxW : staticTxt.implicitWidth
        width: implicitWidth
        height: implicitHeight
        clip: true

        // Both copies live in ONE strip that scrolls as a single unit. (Previously the
        // ghost bound its x to the animated primary's x — bindings on an animated
        // property lag frame-to-frame, so the ghost fell behind and the loop looked
        // like "scroll off, jump, repeat" instead of a seamless marquee.)
        Item {
            id: strip
            height: mq.height
            Text { id: staticTxt; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: mq.stride                       // ghost sits exactly one stride ahead
                visible: mq.scrolling
                text: staticTxt.text; color: staticTxt.color; font: staticTxt.font
            }
            NumberAnimation on x {
                running: mq.scrolling && root.player && root.player.isPlaying
                loops: Animation.Infinite
                from: 0
                to: -mq.stride
                duration: Math.max(2000, mq.stride * 28)
                easing.type: Easing.Linear
                onRunningChanged: if (!running) strip.x = 0    // reset when paused / not scrolling
            }
        }
    }

    // a clickable bar pill that toggles a dropdown identified by `key`
    component Pill: Rectangle {
        id: pill
        property string icon: ""
        property string value: ""
        property string vertValue: ""    // compact value used on a vertical bar (falls back to value)
        property color accent: theme.frost
        property string key: ""
        property bool scrollText: false
        property int maxTextW: 160
        signal clicked()
        signal rightClicked()
        signal scrolled(real dy)
        property var owner: null
        readonly property bool open: root.openPop === key && key !== ""
        readonly property bool vert: root.barVertical
        // On a vertical bar the pill becomes a capsule with the icon stacked over the value.
        // The value only shows when short enough to fit the narrow bar (a long string like the
        // full date would overflow) — so pills like battery/volume keep their readout while the
        // clock (given a compact HH:mm vertValue) stays legible and others fall back to icon-only.
        readonly property string vtext: pill.vertValue !== "" ? pill.vertValue : pill.value
        readonly property bool showVal: pill.vert ? (pill.vtext.length > 0 && pill.vtext.length <= 6)
                                                  : (pill.value !== "")
        implicitHeight: pill.vert ? (pr.implicitHeight + 12) : 26
        // vertical pills share ONE width (derived from bar thickness) so they stack into a
        // clean column with flush edges instead of a ragged centre-aligned zigzag
        implicitWidth:  pill.vert ? Math.max(30, root.cfgHeight - 12) : (pr.implicitWidth + 14)
        // uniform rounded-rectangle corners on a vertical bar (not a per-pill capsule, which
        // would make short pills horizontal ovals and tall ones vertical ovals)
        radius: pill.vert ? Math.min(13, height/2) : height/2
        color: (open || pm.containsMouse) ? theme.a(theme.iris,0.18) : theme.a(theme.line,0.42)
        border.width: 1; border.color: (open || pm.containsMouse) ? theme.a(theme.iris,0.55) : theme.a(theme.iris,0.16)
        Behavior on color { ColorAnimation { duration: 120 } }


        // Grid (not Row) so the icon + value sit side-by-side (horizontal bar) or stacked
        // (vertical bar). Cross-axis centring is the Grid's job, so children carry no anchors.
        Grid { id: pr; anchors.centerIn: parent
            columns: pill.vert ? 1 : 99
            rowSpacing: 1; columnSpacing: 6
            horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
            // Material Symbols glyphs sit ~0.16em left of their advance box, so a centred
            // icon-only pill looks left-shifted. A Translate nudges the paint right to centre
            // the ink WITHOUT changing layout width (so icon+value spacing is untouched).
            Sym { text: pill.icon; color: pill.accent; visible: text!==""; sz: pill.vert ? 15 : 16
                transform: Translate { x: Math.round((pill.vert ? 15 : 16) * 0.16) } }
            // Use Marquee only when scrollText is enabled (e.g. mprisPill), plain Text otherwise.
            // Marquee with maxW:9999 creates an implicit-width loop that causes flickering.
            Loader {
                visible: pill.showVal
                active: pill.showVal
                sourceComponent: pill.vert ? vertComp : (pill.scrollText ? marqueeComp : plainComp)
            }
            Component {
                id: plainComp
                Text { text: pill.value; color: theme.text; font.pixelSize: 13; font.family: root.cfgFont }
            }
            Component {
                id: vertComp
                Text { text: pill.vtext; color: theme.text; font.pixelSize: 10; font.family: root.cfgFont }
            }
            Component {
                id: marqueeComp
                Marquee { text: pill.value; color: theme.text; font.pixelSize: 13; font.family: root.cfgFont; maxW: pill.maxTextW }
            }
        }
        MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (e)=>{ if(e.button===Qt.RightButton){ pill.rightClicked(); return } if(pill.key!==""){ root.openBar = pill.owner; root.openPop = pill.open ? "" : pill.key } else pill.clicked() }
            onWheel: (w)=> pill.scrolled(w.angleDelta.y) }
    }

    // a dropdown card anchored under its host widget, with an 8px gap below the bar.
    // The popup window is 8px taller than the card; the card sits at the bottom of it,
    // so `card`'s top edge is 8px below the pill. Put content with `anchors.fill: card`.
    // A blurable LAYER SURFACE dropdown (Hyprland can only frost layer surfaces, not xdg-popups),
    // positioned under `host` via mapToGlobal. Set cardW / cardH; put content with anchors.fill: <id>.card
    component Drop: PanelWindow {
        id: dw
        property Item host
        property alias card: cardBg
        property int cardW: 240
        property int cardH: 120
        property Item sidecar: null      // optional extra panel (e.g. lyrics) that must also receive clicks
        property Item sidecar2: null     // second optional panel (e.g. track details on the other side)
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:drop"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand   // lets the wifi password field type
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; left: true; right: true; bottom: true }
        // empty input mask while closed (incl. the brief post-close hold) so clicks pass
        // straight through — there's nothing to intercept once the card is gone.
        mask: Region { item: dw.shown ? cardBg : null; regions: [ sideRegion, sideRegion2 ] }
        Region { id: sideRegion; item: dw.shown ? dw.sidecar : null }
        Region { id: sideRegion2; item: dw.shown ? dw.sidecar2 : null }
        readonly property point hp: {
            if (!dw.visible || !dw.host) return Qt.point(-9999, -9999);
            // Reference position & parent hierarchy to force binding updates when layout shifts
            var _trigger = dw.host.x + dw.host.y + dw.host.width + dw.host.height;
            var p = dw.host.parent;
            while (p) {
                _trigger += p.x + p.y;
                p = p.parent;
            }
            return dw.host.mapToGlobal(Qt.point(0, 0));
        }
        readonly property int sw: dw.screen ? dw.screen.width : 1920
        readonly property int sh: dw.screen ? dw.screen.height : 1080
        // mapToGlobal speaks virtual-desktop coordinates; this surface is monitor-local,
        // so subtract the screen's global offset or cards drift on non-origin monitors
        readonly property int scrX: dw.screen ? dw.screen.x : 0
        readonly property int scrY: dw.screen ? dw.screen.y : 0
        readonly property int hostW: dw.host ? (dw.host.width  || dw.host.implicitWidth)  : 0
        readonly property int hostH: dw.host ? (dw.host.height || dw.host.implicitHeight) : 0
        // host position in this (monitor-local) Drop window's coordinates. mapToGlobal on a
        // layer surface does NOT include the surface's inset on its docked axis — a right/bottom
        // bar reads as if flush to the monitor's left/top — so add that inset back per edge.
        readonly property real barOffX: root.cfgEdge === "right"  ? Math.max(0, dw.sw - root.cfgHeight) : 0
        readonly property real barOffY: root.cfgEdge === "bottom" ? Math.max(0, dw.sh - root.cfgHeight) : 0
        readonly property real hostGX: dw.hp.x - dw.scrX + dw.barOffX
        readonly property real hostGY: dw.hp.y - dw.scrY + dw.barOffY

        // `shown` is the logical open state (each usage sets it). CLOSE IS INSTANT: the
        // card — shade AND text — is zeroed on the same frame, so nothing lingers or
        // fades. The now-empty window is then held mapped for a few frames and unmapped
        // only once it has no visible content, so the layer surface can never flash its
        // last buffer on unmap. OPEN fades + slides the card in. (Pairs with the
        // `layerrule = animation none` on sea-shell:drop in sea.conf.)
        property bool shown: false
        property bool held: false
        visible: dw.shown || dw.held
        onShownChanged: {
            if (dw.shown) { holdTimer.stop(); dw.held = true; openAnim.restart(); }
            else { openAnim.stop(); cardBg.openAnimFactor = 0.0; holdTimer.restart(); }
        }
        Timer { id: holdTimer; interval: 90; onTriggered: dw.held = false }
        Component.onCompleted: dw.held = dw.shown
        NumberAnimation { id: openAnim; target: cardBg; property: "openAnimFactor"; to: 1.0; duration: 165; easing.type: Easing.OutCubic }

        // Fade the WHOLE window content (card gradient AND the text columns, which are
        // siblings of cardBg) as one. Fading only cardBg.opacity left the text at full
        // opacity — so on open it flashed in before the card, and on close it lingered a
        // frame after the card zeroed. contentItem is the parent of every default child,
        // so one binding fades everything together; close zeroes it on the same frame.
        Binding { target: dw.contentItem; property: "opacity"; value: cardBg.openAnimFactor }

        Rectangle {
            id: cardBg
            property real openAnimFactor: 0.0
            width: dw.cardW; height: dw.cardH
            // the card opens off the side the bar is docked to: below a top bar, above a
            // bottom bar, to the right of a left bar, to the left of a right bar. It slides
            // in FROM the bar (12px) and is clamped to stay on-screen on the free axis.
            readonly property real slide: (1.0 - openAnimFactor) * 12
            x: {
                if (root.cfgEdge === "left")  return dw.hostGX + dw.hostW + 8 - slide;
                if (root.cfgEdge === "right") return dw.hostGX - dw.cardW - 8 + slide;
                return Math.max(8, Math.min(dw.sw - dw.cardW - 8, dw.hostGX + dw.hostW/2 - dw.cardW/2));
            }
            y: {
                if (root.cfgEdge === "bottom") return dw.hostGY - dw.cardH - 8 + slide;
                if (root.barVertical)          return Math.max(8, Math.min(dw.sh - dw.cardH - 8, dw.hostGY + dw.hostH/2 - dw.cardH/2));
                return dw.hostGY + dw.hostH + 8 - slide;   // top bar
            }
            radius: root.cfgRadius
            gradient: Gradient {
                GradientStop { position: 0.0; color: theme.a(theme.bg, Math.min(1, root.dropOpacity * 1.10)) }
                GradientStop { position: 1.0; color: theme.a(theme.bg, root.dropOpacity * 0.92) }
            }
            border.width: 1; border.color: theme.a(theme.frost, 0.26)
            // matte-glass rim — a whisper of light at the top edge fading out, matching the
            // launcher card. Children draw above the fill but below the content columns.
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0;  color: Qt.rgba(1, 1, 1, theme.light ? 0.10 : 0.05) }
                    GradientStop { position: 0.32; color: "transparent" }
                }
            }
            Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: parent.radius; rightMargin: parent.radius }
                height: 1; color: Qt.rgba(1, 1, 1, theme.light ? 0.45 : 0.12) }
        }
    }

    // ============ one bar per monitor ============
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: bar
            property var modelData
            screen: modelData
            // which tray icon owns the shared tray menu dropdown
            property Item trayHost: null
            property var trayMenuSel: null
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "sea-shell:bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand   // lets dropdown text fields (wifi pw) type
            exclusionMode: ExclusionMode.Auto
            // 4-way docking: top/bottom stretch horizontally (anchor left+right + a fixed
            // height); left/right stretch vertically (anchor top+bottom + a fixed width).
            anchors.top:    root.cfgEdge === "top"    || root.barVertical
            anchors.bottom: root.cfgEdge === "bottom" || root.barVertical
            anchors.left:   root.cfgEdge === "left"   || !root.barVertical
            anchors.right:  root.cfgEdge === "right"  || !root.barVertical
            implicitHeight: root.barVertical ? 0 : root.cfgHeight
            implicitWidth:  root.barVertical ? root.cfgHeight : 0

            Rectangle {
                id: barBg
                anchors.fill: parent
                // 6px gap on the docked edge, 8px on the two free edges (0 on the inner edge)
                anchors.topMargin:    root.cfgEdge === "bottom" ? 0 : (root.barVertical ? 8 : 6)
                anchors.bottomMargin: root.cfgEdge === "top"    ? 0 : (root.barVertical ? 8 : 6)
                anchors.leftMargin:   root.cfgEdge === "right"  ? 0 : (root.barVertical ? 6 : 8)
                anchors.rightMargin:  root.cfgEdge === "left"   ? 0 : (root.barVertical ? 6 : 8)
                radius: root.cfgRadius
                color: theme.a(root.barFillColor, root.cfgOpacity)
                // at 0% opacity the fill vanishes and so does the outline — only the chips remain
                border.width: root.cfgOpacity < 0.06 ? 0 : 1
                border.color: theme.a(theme.iris, 0.30 * Math.min(1, root.cfgOpacity / 0.5))

                // ---------- START: logo · workspaces · app name ----------
                // Grid (not Row) so the same markup lays out horizontally (top/bottom bar,
                // columns:99 → one row) or vertically (left/right bar, columns:1 → one column).
                // Cross-axis centring is done by the Grid's item-alignment, so children carry
                // NO verticalCenter/horizontalCenter anchors of their own.
                Grid {
                    id: leftGroup
                    columns: root.barVertical ? 1 : 99
                    rowSpacing: 7; columnSpacing: 7
                    horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                    anchors.left:   root.barVertical ? undefined : parent.left
                    anchors.leftMargin: 10
                    anchors.top:    root.barVertical ? parent.top : undefined
                    anchors.topMargin: 12
                    anchors.verticalCenter:   root.barVertical ? undefined : parent.verticalCenter
                    anchors.horizontalCenter: root.barVertical ? parent.horizontalCenter : undefined
                    SeaLogo { size: 24
                        card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: launcher.toggle() } }
                    Grid {
                        columns: root.barVertical ? 1 : 99
                        rowSpacing: 6; columnSpacing: 6
                        horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                        Repeater {
                            model: Hyprland.workspaces
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                // active workspace grows along the bar's long axis
                                width:  (foc && !root.barVertical) ? 36 : 24
                                height: (foc && root.barVertical)  ? 36 : 24
                                radius: 12   // circle → pill when active
                                color: foc ? theme.iris : theme.a(theme.line,0.55)
                                border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris,0.18)
                                Behavior on width  { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Text { anchors.centerIn: parent; text: modelData.id; color: foc ? theme.bg : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: foc }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("workspace "+modelData.id) }
                            }
                        }
                    }
                    Text {
                        // the horizontal window title has no room in a narrow vertical bar.
                        // Capped short so a long app class (e.g. electron apps) can't grow into
                        // the centre and push the media pill out of existence — it's only a hint.
                        visible: !root.barVertical
                        width: Math.min(implicitWidth, 130); elide: Text.ElideRight
                        color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont
                        text: (Hyprland.activeToplevel && Hyprland.activeToplevel.lastIpcObject) ? (Hyprland.activeToplevel.lastIpcObject.class || "") : ""
                    }
                }

                // ---------- CENTER: media (click → full player dropdown) ----------
                Pill { owner: bar
                    id: mprisPill
                    anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter }
                    // clamp the title width to the free gap between the left and right
                    // clusters so a long track never overflows into (or past) them.
                    // The pill is centred, so its half-width is limited by the tighter side.
                    readonly property real freeText: {
                        var half = barBg.width / 2;
                        var leftEnd = leftGroup.x + leftGroup.width;    // right edge of left cluster
                        var rightStart = rightGroup.x;                  // left edge of right cluster
                        var room = Math.min(half - leftEnd, rightStart - half) - 8;    // per-side gap
                        return room * 2 - 42;                           // both halves, minus icon+padding
                    }
                    visible: root.cfgMpris && root.player !== null && freeText >= 26
                    key: "mpris"
                    scrollText: true
                    maxTextW: Math.max(0, Math.min(180, freeText))
                    // a music note reads clearly as "now playing"; the animated CAVA bars
                    // behind already signal play/paused, and right-click still toggles playback.
                    icon: "music_note"
                    accent: theme.iris
                    value: {
                        if (!root.player) return "";
                        var t = (root.player.trackTitle || ""); var ar = (root.player.trackArtist || "");
                        return ar ? (ar + " — " + t) : t;
                    }
                    onRightClicked: { if(root.player) root.player.togglePlaying() }
                    onScrolled: (dy)=>{ if(!root.player) return; if(dy>0) root.player.next(); else root.player.previous() }
                }
                Drop { screen: bar.screen
                    id: mprisDrop; host: mprisPill; shown: root.openPop ==="mpris" && root.openBar === bar
                    cardW: 380; cardH: mprCol.implicitHeight + 32
                    sidecar: root.lyricsOpen ? lyrPanel : null           // clicks land on the panel only while it's open
                    sidecar2: root.infoOpen ? infoPanel : null
                    onVisibleChanged: if (visible && root.lyricsOpen) root.fetchLyrics()   // track may have changed while closed
                    Column { id: mprCol; anchors.fill: mprisDrop.card; anchors.margins: 15; spacing: 11

                        // player switcher chips (only when several apps are playing)
                        Row { width: parent.width; spacing: 6; visible: root.players.length > 1
                            Repeater { model: root.players.length
                                delegate: Rectangle { required property int index
                                    property bool cur: index === Math.min(root.playerSel, root.players.length-1)
                                    width: pcTxt.width + 18; height: 20; radius: 10
                                    color: cur ? theme.a(theme.iris,0.28) : (pcMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.5))
                                    border.width: 1; border.color: cur ? theme.iris : theme.a(theme.line,0.9)
                                    Text { id: pcTxt; anchors.centerIn: parent; text: (root.players[index].identity||"player").toLowerCase()
                                        color: cur ? theme.text : theme.sub; font.pixelSize: 9; font.family: root.cfgFont }
                                    MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.playerSel = index } } } }

                        // art + track info
                        Row { width: parent.width; spacing: 13
                            Rectangle { width: 84; height: 84; radius: 12; color: theme.a(theme.line,0.6); clip: true
                                border.width: 1; border.color: theme.a(theme.iris,0.35)
                                Image { anchors.fill: parent; asynchronous: true; fillMode: Image.PreserveAspectCrop
                                    source: (root.player && root.player.trackArtUrl) ? root.player.trackArtUrl : ""; visible: status===Image.Ready }
                                Sym { anchors.centerIn: parent; text: "music_note"; sz: 34; color: theme.faint; visible: !(root.player && root.player.trackArtUrl && root.player.trackArtUrl!=="") } }
                            Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 97; spacing: 3
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: root.player ? (root.player.trackTitle||"—") : "—"; color: theme.text; font.pixelSize: 15; font.family: root.cfgFont; font.bold: true
                                }
                                Text {
                                    width: parent.width; elide: Text.ElideRight; visible: text!==""
                                    text: root.player ? (root.player.trackArtist||"") : ""; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont
                                }
                                Text {
                                    width: parent.width; elide: Text.ElideRight; visible: text!==""
                                    text: root.player ? (root.player.trackAlbum||"") : ""; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont
                                }
                                // gold badge: only appears for direct-ALSA (bit-perfect) playback, e.g. SONE
                                Row { spacing: 5; visible: root.hqInfo !== ""
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "verified"; sz: 13; color: theme.warn }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.hqInfo
                                        color: theme.warn; font.pixelSize: 10; font.family: root.cfgFont; font.bold: true } } } }

                        // cava visualizer
                        Item { width: parent.width; height: 38
                            Row { anchors.fill: parent; spacing: 3
                                Repeater { model: root.vizBars.length
                                    delegate: Rectangle { required property int index
                                        width: (mprCol.width - (root.vizBars.length-1)*3) / Math.max(1, root.vizBars.length)
                                        height: Math.max(2, (root.vizBars[index]||0)/100*38); anchors.bottom: parent.bottom
                                        radius: 2; color: theme.a(theme.iris, 0.55 + 0.4*((root.vizBars[index]||0)/100)) } } }
                            Text { anchors.centerIn: parent; visible: root.vizBars.length===0; text: "…"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont } }

                        // seekable progress
                        Column { width: parent.width; spacing: 4; visible: root.player && root.player.length>0
                            Item { width: parent.width; height: 14
                                Rectangle { id: seekTrack; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: seekMa.containsMouse||seekMa.pressed ? 7 : 5; radius: 4; color: theme.a(theme.line,0.85)
                                    Behavior on height { NumberAnimation { duration: 90 } }
                                    Rectangle { height: parent.height; radius: 4; color: theme.iris
                                        width: parent.width * (root.player && root.player.length>0 ? Math.max(0,Math.min(1, root.mprisPos/root.player.length)) : 0) } }
                                MouseArea { id: seekMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: (root.player && root.player.canSeek) ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    function seekTo(x) { if (!root.player || !root.player.canSeek || !(root.player.length>0)) return;
                                        var f = Math.max(0, Math.min(1, x/width)); root.player.position = f*root.player.length; root.mprisPos = f*root.player.length }
                                    onPressed: (e)=> seekTo(e.x)
                                    onPositionChanged: (e)=> { if (pressed) seekTo(e.x) } } }
                            Row { width: parent.width
                                Text { text: root.fmtTime(root.mprisPos); color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                Item { width: parent.width - 90; height: 1 }
                                Text { text: root.fmtTime(root.player ? root.player.length : 0); color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; horizontalAlignment: Text.AlignRight; width: 44 } } }

                        // controls: shuffle · prev · play · next · loop
                        Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 10
                            Rectangle { width: 34; height: 34; radius: 17; visible: root.player ? root.player.shuffleSupported : false
                                color: sh.containsMouse ? theme.a(theme.iris,0.2) : "transparent"
                                Sym { anchors.centerIn: parent; text: "shuffle"; sz: 18; color: (root.player&&root.player.shuffle) ? theme.iris : theme.faint }
                                MouseArea { id: sh; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.shuffle = !root.player.shuffle } }
                            Rectangle { width: 38; height: 38; radius: 19; color: pv.containsMouse?theme.a(theme.iris,0.2):"transparent"
                                Sym { anchors.centerIn: parent; text: "skip_previous"; sz: 22; color: (root.player&&root.player.canGoPrevious)?theme.frost:theme.faint }
                                MouseArea { id: pv; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.previous() } }
                            Rectangle { width: 46; height: 46; radius: 23; color: pp.containsMouse?theme.iris:theme.a(theme.iris,0.22); border.width: 1; border.color: theme.iris
                                Sym { anchors.centerIn: parent; text: (root.player&&root.player.isPlaying)?"pause":"play_arrow"; sz: 26; color: pp.containsMouse?theme.bg:theme.frost }
                                MouseArea { id: pp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.togglePlaying() } }
                            Rectangle { width: 38; height: 38; radius: 19; color: nx.containsMouse?theme.a(theme.iris,0.2):"transparent"
                                Sym { anchors.centerIn: parent; text: "skip_next"; sz: 22; color: (root.player&&root.player.canGoNext)?theme.frost:theme.faint }
                                MouseArea { id: nx; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.next() } }
                            Rectangle { width: 34; height: 34; radius: 17; visible: root.player ? root.player.loopSupported : false
                                color: lp.containsMouse ? theme.a(theme.iris,0.2) : "transparent"
                                Sym { anchors.centerIn: parent; sz: 18
                                    text: (root.player&&root.player.loopState===MprisLoopState.Track) ? "repeat_one" : "repeat"
                                    color: (root.player&&root.player.loopState!==MprisLoopState.None) ? theme.iris : theme.faint }
                                MouseArea { id: lp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if(!root.player) return; root.player.loopState = root.player.loopState===MprisLoopState.None ? MprisLoopState.Playlist : root.player.loopState===MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None } } } }

                        // player volume
                        Row { width: parent.width; spacing: 8; visible: root.player ? root.player.volumeSupported : false
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_down"; sz: 16; color: theme.faint }
                            Item { width: parent.width - 48; height: 14; anchors.verticalCenter: parent.verticalCenter
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: 2; color: theme.a(theme.line,0.85)
                                    Rectangle { height: parent.height; radius: 2; color: theme.a(theme.iris,0.8)
                                        width: parent.width * (root.player ? Math.max(0,Math.min(1,root.player.volume)) : 0) } }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    function setV(x) { if (root.player) root.player.volume = Math.max(0, Math.min(1, x/width)) }
                                    onPressed: (e)=> setV(e.x); onPositionChanged: (e)=> { if (pressed) setV(e.x) } } }
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_up"; sz: 16; color: theme.faint } }

                        // details (left) + lyrics (right) toggles — each panel opens BESIDE the card as a sidecar
                        Row { width: parent.width; spacing: 8; height: 26
                            Rectangle { width: (parent.width-8)/2; height: 26; radius: 8
                                color: dtMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.4)
                                border.width: 1; border.color: root.infoOpen ? theme.a(theme.iris,0.5) : theme.a(theme.line,0.9)
                                Row { anchors.centerIn: parent; spacing: 6
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "info"; sz: 14; color: root.infoOpen ? theme.iris : theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.infoOpen ? "hide details" : "details"
                                        color: root.infoOpen ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                MouseArea { id: dtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.infoOpen = !root.infoOpen } }
                            Rectangle { width: (parent.width-8)/2; height: 26; radius: 8
                                color: lyMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.4)
                                border.width: 1; border.color: root.lyricsOpen ? theme.a(theme.iris,0.5) : theme.a(theme.line,0.9)
                                Row { anchors.centerIn: parent; spacing: 6
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; sz: 14; color: root.lyricsOpen ? theme.iris : theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.lyricsOpen ? "hide lyrics" : "lyrics"
                                        color: root.lyricsOpen ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                MouseArea { id: lyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.lyricsOpen = !root.lyricsOpen; if (root.lyricsOpen) root.fetchLyrics(root.lyricsState!=='ok' && root.lyricsState!=='plain') } } } }
                    }

                    // ---- lyrics sidecar: full-height panel next to the player card ----
                    Rectangle {
                        id: lyrPanel
                        visible: root.lyricsOpen && root.openPop === "mpris"
                        width: 300; height: mprisDrop.card.height
                        // right of the card; flips to the left near the screen edge
                        x: (mprisDrop.card.x + mprisDrop.card.width + 10 + width > mprisDrop.sw - 8)
                           ? mprisDrop.card.x - width - 10 : mprisDrop.card.x + mprisDrop.card.width + 10
                        y: mprisDrop.card.y
                        radius: root.cfgRadius; color: theme.a(theme.bg, root.dropOpacity)
                        border.width: 1; border.color: theme.a(theme.iris,0.34)
                        Column { anchors.fill: parent; anchors.margins: 13; spacing: 8
                            Row { width: parent.width; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; sz: 15; color: theme.iris }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont }
                                Item { width: parent.width - 150; height: 1 }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.lyricsState==="ok" ? "synced" : ""; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            Item { width: parent.width; height: parent.height - 34
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="loading"; text: "fetching lyrics…"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="none"; text: "no lyrics found"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                // synced: follows playback, current line highlighted, click to seek
                                ListView { id: lyrView; anchors.fill: parent; visible: root.lyricsState==="ok"; clip: true
                                    model: root.lyrics; spacing: 3
                                    delegate: Item { required property var modelData; required property int index
                                        width: lyrView.width; height: lyT.height + 8
                                        Text { id: lyT; width: parent.width; anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.l; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                                            color: index===root.lyrIdx ? theme.frost : (index<root.lyrIdx ? theme.faint : theme.sub)
                                            font.pixelSize: index===root.lyrIdx ? 14 : 12; font.bold: index===root.lyrIdx; font.family: root.cfgFont
                                            Behavior on color { ColorAnimation { duration: 150 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: (root.player&&root.player.canSeek)?Qt.PointingHandCursor:Qt.ArrowCursor
                                            onClicked: { if (root.player && root.player.canSeek) { root.player.position = modelData.t; root.mprisPos = modelData.t } } } }
                                    Connections { target: root; function onLyrIdxChanged() { if (root.lyrIdx >= 0) lyrView.positionViewAtIndex(root.lyrIdx, ListView.Center) } } }
                                // plain (unsynced) fallback: just scroll
                                Flickable { anchors.fill: parent; visible: root.lyricsState==="plain"; clip: true
                                    contentHeight: plainT.height; boundsBehavior: Flickable.StopAtBounds
                                    Text { id: plainT; width: parent.width; text: root.plainLyrics; wrapMode: Text.Wrap
                                        horizontalAlignment: Text.AlignHCenter; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont } } } } }

                    // ---- track-details sidecar: opens on the OPPOSITE side of the lyrics panel ----
                    Rectangle {
                        id: infoPanel
                        visible: root.infoOpen && root.openPop === "mpris"
                        // grow to fit the details (art + rows) so nothing clips; never shorter than the card
                        width: 260; height: Math.max(mprisDrop.card.height, detailsCol.implicitHeight + 28)
                        clip: true
                        // prefer the LEFT of the card (mirrors lyrics on the right); flip right near the screen edge
                        x: (mprisDrop.card.x - 10 - width < 8)
                           ? mprisDrop.card.x + mprisDrop.card.width + 10 : mprisDrop.card.x - width - 10
                        y: mprisDrop.card.y
                        radius: root.cfgRadius; color: theme.a(theme.bg, root.dropOpacity)
                        border.width: 1; border.color: theme.a(theme.iris,0.34)
                        Column { id: detailsCol; anchors.fill: parent; anchors.margins: 14; spacing: 10
                            Row { width: parent.width; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "info"; sz: 15; color: theme.iris }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "track details"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            // large album art
                            Rectangle { anchors.horizontalCenter: parent.horizontalCenter
                                width: Math.min(parent.width, 150); height: width; radius: 12; clip: true
                                color: theme.a(theme.line,0.6); border.width: 1; border.color: theme.a(theme.iris,0.3)
                                Image { anchors.fill: parent; asynchronous: true; fillMode: Image.PreserveAspectCrop
                                    source: (root.player && root.player.trackArtUrl) ? root.player.trackArtUrl : ""; visible: status===Image.Ready }
                                Sym { anchors.centerIn: parent; text: "music_note"; sz: 40; color: theme.faint; visible: !(root.player && root.player.trackArtUrl && root.player.trackArtUrl!=="") } }
                            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                text: root.player ? (root.player.trackTitle||"—") : "—"; color: theme.text; font.pixelSize: 14; font.bold: true; font.family: root.cfgFont }
                            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; visible: text!==""
                                text: root.player ? (root.player.trackArtist||"") : ""; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.12) }
                            // detail rows (static ones via a model; live time rows bound directly so they don't rebuild the list)
                            Column { id: infoRows; width: parent.width; spacing: 8
                                Repeater {
                                    model: {
                                        var p = root.player; if (!p) return [];
                                        return [
                                            {k:"Album",   v: p.trackAlbum || "—"},
                                            {k:"Source",  v: p.identity || "—"},
                                            {k:"Quality", v: root.hqInfo !== "" ? root.hqInfo : "standard"},
                                            {k:"Length",  v: root.fmtTime(p.length||0)}
                                        ];
                                    }
                                    delegate: Item { required property var modelData; width: infoRows.width; height: 16
                                        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: modelData.k; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: parent.width*0.62; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
                                            text: modelData.v; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                }
                                Item { width: infoRows.width; height: 16
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Elapsed"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight
                                        text: root.fmtTime(root.mprisPos); color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                Item { width: infoRows.width; height: 16
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Remaining"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight
                                        text: "-" + root.fmtTime(Math.max(0,(root.player?root.player.length:0)-root.mprisPos)); color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } } }
                        }
                    } }

                // ---------- END: weather · tray · wifi · vol · battery · clock ----------
                // Grid, same trick as leftGroup — horizontal (top/bottom) or vertical (left/right).
                // Anchored to the far edge: right for a horizontal bar, bottom for a vertical one.
                Grid {
                    id: rightGroup
                    columns: root.barVertical ? 1 : 99
                    rowSpacing: 7; columnSpacing: 7
                    horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                    // horizontal axis via anchors; vertical position via manual y. Anchoring a
                    // content-sized Grid's `bottom` collapses it (height reads 0 at anchor time),
                    // so we compute y from implicitHeight: bottom-pinned when vertical, centred when not.
                    anchors.right:  root.barVertical ? undefined : parent.right
                    anchors.rightMargin: 10
                    anchors.horizontalCenter: root.barVertical ? parent.horizontalCenter : undefined
                    y: root.barVertical ? (parent.height - implicitHeight - 12)
                                        : (parent.height - implicitHeight) / 2

                    // ---- WEATHER dropdown (its pill is declared after the tray, below) ----
                    

                    // ---- SYSTEM TRAY (after weather) — collapsible, right-click = app menu ----
                    Grid { columns: root.barVertical ? 1 : 99; rowSpacing: 2; columnSpacing: 2
                        horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                        visible: root.cfgTray && SystemTray.items.values.length > 0
                        // collapse / expand toggle
                        Rectangle { width: 16; height: 16; radius: 4
                            visible: SystemTray.items.values.length > 0
                            color: tcm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                            Sym { anchors.centerIn: parent; text: root.barVertical ? (root.trayCollapsed ? "expand_less" : "expand_more") : (root.trayCollapsed ? "chevron_left" : "chevron_right"); sz: 12; color: theme.sub }
                            MouseArea { id: tcm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed } }
                        Grid { columns: root.barVertical ? 1 : 99; rowSpacing: 2; columnSpacing: 2; visible: !root.trayCollapsed
                            horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                            Repeater { model: SystemTray.items
                                delegate: Item { id: trayItem; required property SystemTrayItem modelData; width: 18; height: 18
                                    Image { width: 36; height: 36; anchors.centerIn: parent; scale: 0.5; asynchronous: true; source: trayItem.modelData.icon; sourceSize.width: 96; sourceSize.height: 96; smooth: true; mipmap: true; fillMode: Image.PreserveAspectFit }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton|Qt.RightButton
                                        onClicked: (e)=>{
                                            if (e.button===Qt.LeftButton) { trayItem.modelData.activate(); return }
                                            // one shared menu window → opening a 2nd icon replaces it, same icon toggles
                                            if (root.openPop==="tray" && bar.trayHost===trayItem) { root.openPop=""; return }
                                            bar.trayHost = trayItem; bar.trayMenuSel = trayItem.modelData; root.openBar = bar; root.openPop = "tray" } }
                                } } } }

                    // ---- shared tray menu: ONE blurable layer-surface Drop (sea-shell:drop),
                    // part of the openPop single-dropdown system so the focus grab dismisses it ----
                    

                    // ---- WEATHER pill (placed after the tray) ----
                    Pill { owner: bar; id: wxPill; key: "wx"
                        visible: root.cfgWeather && root.wxTemp!==""; icon: root.wxIcon(root.wxCond); value: root.wxTemp; accent: theme.frost }

                    // ---- CLIPBOARD (opens the launcher in clipboard mode) ----
                    Pill { owner: bar; icon: "content_paste"; accent: theme.frost
                        visible: root.cfgClipboard
                        onClicked: { root.openPop = ""; launcher.open(";") } }

                    // ---- NOTIFICATION CENTER (bell + badge) ----
                    Pill { owner: bar; id: bellPill; key: "notif"
                        visible: root.cfgNotif
                        icon: root.dnd ? "notifications_off" : (root.notes.length>0 ? "notifications" : "notifications_none")
                        accent: root.dnd ? theme.warn : (root.notes.length>0 ? theme.iris : theme.frost)
                        value: root.dnd ? "" : (root.notes.length>0 ? String(root.notes.length) : "") }
                    

                    // ---- WIFI ----
                    Pill { owner: bar; id: wifiPill; key: "wifi"
                        visible: root.cfgWifi
                        icon: root.wifiOn ? "wifi" : "wifi_off"; accent: root.wifiOn ? theme.frost : theme.bad
                        }   // icon-only: SSID lives in the dropdown
                    

                    // ---- BLUETOOTH ----
                    Pill { owner: bar; id: btPill
                        visible: root.cfgBluetooth && root.btAdapter !== null
                        key: root.btAdapter ? "bt" : ""
                        icon: (!root.btAdapter || !root.btAdapter.enabled) ? "bluetooth_disabled" : (root.btActive ? "bluetooth_connected" : (root.btAdapter.discovering ? "bluetooth_searching" : "bluetooth"))
                        accent: root.btActive ? theme.iris : ((root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint)
                        value: root.btActive ? root.btName(root.btActive) : "" }
                    

                    // ---- CAFFEINE ----
                    Pill { owner: bar
                        visible: root.cfgCaffeine
                        icon: root.idleOn ? "bedtime" : "coffee"
                        accent: root.idleOn ? theme.frost : theme.warn
                        value: ""
                        onClicked: root.toggleIdle() }

                    // ---- SYSTEM MONITOR (cpu · ram · gpu) ----
                    Pill { owner: bar; id: sysPill; key: "sys"
                        visible: root.cfgSystem
                        icon: "speed"; value: Math.round(root.cpuUsage)+"%"
                        accent: root.loadColor(root.cpuTemp, 78, 90) }
                    

                    // ---- VOLUME ----
                    Pill { owner: bar; id: volPill; key: "vol"
                        visible: root.cfgVolume
                        readonly property var au: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
                        readonly property int vol: au ? Math.round(au.volume*100) : 0
                        icon: !au||au.muted ? "volume_off" : vol<34?"volume_mute":vol<67?"volume_down":"volume_up"
                        accent: (au&&au.muted)?theme.faint:theme.frost
                        value: au ? (au.muted?"muted":vol+"%") : "—"
                        onRightClicked: { if(au) au.muted = !au.muted }
                        onScrolled: (dy)=>{ if(!au) return; au.muted=false; au.volume=Math.max(0,Math.min(1,au.volume+(dy>0?0.05:-0.05))) } }
                    

                    // ---- BATTERY ----
                    Pill { owner: bar; id: batPill
                        readonly property var dev: UPower.displayDevice
                        readonly property bool charging: !UPower.onBattery
                        readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                        visible: root.cfgBattery && dev && dev.isLaptopBattery
                        key: visible ? "bat" : ""
                        icon: charging?"battery_charging_full":pct>=90?"battery_full":pct>=60?"battery_5_bar":pct>=35?"battery_3_bar":pct>=15?"battery_1_bar":"battery_alert"
                        value: pct+"%"; accent: charging?theme.good:pct<=20?theme.bad:theme.frost }
                    

                    // ---- SCREEN RECORDER PILL ----
                    Pill { owner: bar; id: recPill; icon: "videocam"
                        visible: root.recordingActive
                        accent: theme.bad
                        value: root.recordingTime
                        onClicked: Quickshell.execDetached(["sh", "-c", "~/.config/quickshell/sea-shell/sea-record.sh toggle"])
                    }

                    // ---- CLOCK ----
                    Pill { owner: bar; id: clockPill; key: "cal"; icon: "schedule"
                        visible: root.cfgClock
                        value: Qt.formatDateTime(clock.date,"ddd d MMM · HH:mm")
                        vertValue: Qt.formatDateTime(clock.date,"HH:mm"); accent: theme.iris }
                     

                    // ---- POWER (very end) ----
                    Pill { owner: bar; id: pwrPill; key: "pwr"; icon: "power_settings_new"; accent: theme.bad
                        visible: root.cfgPower }
                    
                }

                // dropdown windows for the END cluster — kept OUT of the rightGroup positioner:
                // a layer-surface window reads to a Grid as a full-height item, which in a vertical
                // (columns:1) bar would insert screen-tall gaps. They anchor to their host by id, so
                // their parent doesn't matter — parking them here keeps the Grid pill-only.
                Item { id: rightGroupDrops
                    Drop { screen: bar.screen
                        id: wxDrop; host: wxPill; shown: root.openPop ==="wx" && root.openBar === bar
                        cardW: 250; cardH: wxCol.implicitHeight + 32
                        Column { id: wxCol; anchors.fill: wxDrop.card; anchors.margins: 14; spacing: 8
                            Row { width: parent.width; spacing: 10
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.wxIcon(root.wxCond); sz: 30; color: theme.frost }
                                Column { anchors.verticalCenter: parent.verticalCenter; spacing: 1; width: parent.width - 40
                                    Text { text: root.wxTemp; color: theme.text; font.pixelSize: 20; font.family: root.cfgFont; font.bold: true }
                                    Text { width: parent.width; text: root.wxCond; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont
                                        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line,0.7) }
                            Repeater { model: [{i:"thermostat",l:"feels like",v:root.wxFeels},{i:"humidity_percentage",l:"humidity",v:root.wxHumid},{i:"air",l:"wind",v:root.wxWind}]
                                delegate: Item { required property var modelData; width: parent.width; height: 20
                                    Sym { id: wxdIc; anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 15; color: theme.iris }
                                    Text { anchors { left: wxdIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                                        text: modelData.l; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont }
                                    Text { anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                        width: Math.min(implicitWidth, parent.width - 110); elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                                        text: modelData.v; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont } } }
                            // ---- 3-day forecast ----
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line,0.7); visible: root.wxForecast.length>0 }
                            Text { visible: root.wxForecast.length>0; text: "forecast"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                            Repeater { model: root.wxForecast
                                delegate: Row { required property var modelData; width: parent.width; height: 26; spacing: 8
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.day; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; width: 46 }
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: root.wxIcon(modelData.cond); sz: 17; color: theme.frost }
                                    Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 168; elide: Text.ElideRight; text: modelData.cond; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.hi; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.lo; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line,0.7) }
                            Item { width: parent.width; height: 26
                                Row { anchors.fill: parent; spacing: 8
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "settings"; sz: 15; color: theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "set location / units"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont } }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.openPop=""; root.openSettings(3) } } } } }
                    Drop { screen: bar.screen
                        id: trayDrop; host: bar.trayHost
                        shown: root.openPop ==="tray" && root.openBar === bar && bar.trayHost !== null
                        cardW: 230; cardH: Math.max(30, tmCol.implicitHeight + 12)
                        QsMenuOpener { id: trayMenu; menu: bar.trayMenuSel ? bar.trayMenuSel.menu : null }
                        Column { id: tmCol; anchors.fill: trayDrop.card; anchors.margins: 6; spacing: 1
                            Text { visible: trayMenu.children.values.length===0; text: "no menu"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont; leftPadding: 6; topPadding: 4 }
                            Repeater { model: trayMenu.children
                                delegate: Rectangle { required property var modelData
                                    width: parent.width; height: modelData.isSeparator ? 7 : 28; radius: 6
                                    color: (!modelData.isSeparator && em.containsMouse) ? theme.a(theme.iris,0.16) : "transparent"
                                    Rectangle { visible: modelData.isSeparator; anchors.verticalCenter: parent.verticalCenter; x: 5; width: parent.width-10; height: 1; color: theme.a(theme.line,0.8) }
                                    Row { visible: !modelData.isSeparator; anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; spacing: 8
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.text||""; color: modelData.enabled?theme.text:theme.faint; font.pixelSize: 12; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-22 }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: modelData.hasChildren; text: "chevron_right"; sz: 14; color: theme.sub } }
                                    MouseArea { id: em; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !modelData.isSeparator
                                        onClicked: { if(!modelData.hasChildren){ modelData.triggered(); root.openPop="" } } } } } } }
                    Drop { screen: bar.screen
                        id: notifDrop; host: bellPill; shown: root.openPop ==="notif" && root.openBar === bar
                        cardW: 350; cardH: Math.min(460, notifCol.implicitHeight + 28)
                        Column { id: notifCol; anchors.fill: notifDrop.card; anchors.margins: 14; spacing: 4
                            // Header
                            Item { width: parent.width; height: 28
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "notifications"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 6
                                    // Do Not Disturb toggle
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter
                                        width: dndRow.width + 16; height: 22; radius: 6
                                        color: root.dnd ? theme.a(theme.warn, 0.2) : (dndMa.containsMouse ? theme.a(theme.line, 0.75) : theme.a(theme.line, 0.5))
                                        border.width: 1; border.color: root.dnd ? theme.a(theme.warn, 0.5) : "transparent"
                                        Row { id: dndRow; anchors.centerIn: parent; spacing: 4
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: root.dnd ? "do_not_disturb_on" : "do_not_disturb_off"; sz: 13; color: root.dnd ? theme.warn : theme.sub }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "DND"; color: root.dnd ? theme.warn : theme.sub; font.pixelSize: 10; font.family: root.cfgFont; font.bold: root.dnd } }
                                        MouseArea { id: dndMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setDnd(!root.dnd) } }
                                    // clear all
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter
                                        visible: root.notes.length > 0
                                        width: clrTxt.implicitWidth + 16; height: 22; radius: 6
                                        color: clrMa.containsMouse ? theme.a(theme.bad, 0.18) : theme.a(theme.line, 0.5)
                                        Text { id: clrTxt; anchors.centerIn: parent; text: "clear all"; color: clrMa.containsMouse ? theme.bad : theme.sub; font.pixelSize: 10; font.family: root.cfgFont }
                                        MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.noteClear() } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Text { visible: root.notes.length===0; text: "no notifications"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont; topPadding: 4 }
                            Flickable { width: parent.width; height: Math.min(390, listCol.implicitHeight); contentHeight: listCol.implicitHeight; clip: true; boundsBehavior: Flickable.StopAtBounds; visible: root.notes.length>0
                                Column { id: listCol; width: parent.width; spacing: 6
                                    Repeater { model: root.notes
                                        delegate: Rectangle { required property var modelData; width: listCol.width; radius: 10
                                            implicitHeight: ec.implicitHeight + 16; color: theme.a(theme.line,0.38)
                                            border.width: 1; border.color: modelData.urgency===2 ? theme.a(theme.bad,0.45) : theme.a(theme.iris,0.12)
                                            Column { id: ec; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10; spacing: 3
                                                Row { width: parent.width
                                                    Text { text: modelData.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-50; font.bold: true }
                                                    Text { text: modelData.time; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; width: 46; horizontalAlignment: Text.AlignRight } }
                                                Text { width: parent.width; visible: modelData.summary!==""; text: modelData.summary; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; wrapMode: Text.WordWrap }
                                                Text { width: parent.width; visible: modelData.body!==""; text: modelData.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText } } } } } } } }
                    Drop { screen: bar.screen
                        id: wifiDrop; host: wifiPill; shown: root.openPop ==="wifi" && root.openBar === bar
                        cardW: 290; cardH: wifiCol.implicitHeight + 28
                        onVisibleChanged: if(!visible) root.wifiPwFor = ""
                        Column { id: wifiCol; anchors.fill: wifiDrop.card; anchors.margins: 14; spacing: 4
                            // Header
                            Item { width: parent.width; height: 28
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "wi-fi"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                    width: 26; height: 26; radius: 8
                                    color: rfm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                    Sym { anchors.centerIn: parent; text: "refresh"; sz: 15; color: theme.sub }
                                    MouseArea { id: rfm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { wifiScan.running = true; wifiStatus.running = true } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Repeater { model: root.wifiList
                                delegate: Column { id: netRow; required property var modelData; width: parent.width; spacing: 3
                                    readonly property bool asking: root.wifiPwFor === netRow.modelData.ssid
                                    Rectangle { width: parent.width; height: 34; radius: 8
                                        color: netRow.modelData.active ? theme.a(theme.iris,0.18) : (netRow.asking ? theme.a(theme.iris,0.10) : (wm.containsMouse ? theme.a(theme.line,0.45) : "transparent"))
                                        border.width: netRow.modelData.active ? 1 : 0; border.color: theme.a(theme.iris,0.3)
                                        Row { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: netRow.modelData.signal>66?"signal_wifi_4_bar":netRow.modelData.signal>33?"network_wifi_3_bar":"network_wifi_1_bar"; sz: 16; color: netRow.modelData.active?theme.iris:theme.frost }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width-64; elide: Text.ElideRight; text: netRow.modelData.ssid; color: netRow.modelData.active ? theme.text : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: netRow.modelData.active }
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: netRow.modelData.active?"check_circle":"lock"; sz: 13; color: netRow.modelData.active?theme.good:theme.a(theme.faint,0.6); visible: netRow.modelData.secure||netRow.modelData.active } }
                                        MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { if(netRow.modelData.active) return; if(netRow.asking) root.wifiPwFor=""; else root.wifiConnect(netRow.modelData.ssid, netRow.modelData.secure) } } }
                                    // inline password field
                                    Row { width: parent.width; height: 34; visible: netRow.asking; spacing: 6
                                        Rectangle { width: parent.width-42; height: 32; radius: 8; color: theme.a(theme.line,0.5); border.width: 1; border.color: pwIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                            TextInput { id: pwIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; verticalAlignment: TextInput.AlignVCenter
                                                echoMode: TextInput.Password; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; clip: true; focus: netRow.asking
                                                onAccepted: root.wifiJoin(netRow.modelData.ssid, text)
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: pwIn.text===""; text: "password ↵"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont } } }
                                        Rectangle { width: 36; height: 32; radius: 8; color: jm.containsMouse?theme.iris:theme.a(theme.iris,0.2); border.width: 1; border.color: theme.iris
                                            Sym { anchors.centerIn: parent; text: "arrow_forward"; sz: 14; color: jm.containsMouse?theme.bg:theme.frost }
                                            MouseArea { id: jm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wifiJoin(netRow.modelData.ssid, pwIn.text) } } } } }
                            Text { visible: root.wifiList.length===0; text: "scanning…"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont; topPadding: 4 }

                            // ---- VPN Section ----
                            Item { height: 2; width: 1 }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 4; width: 1 }

                            // Cloudflare WARP row
                            Item { width: parent.width; height: 26
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; spacing: 7
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "security"; sz: 14
                                        color: root.warpConnected ? theme.good : theme.faint }
                                    Text { anchors.verticalCenter: parent.verticalCenter
                                        text: "Cloudflare WARP"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                                    Text { anchors.verticalCenter: parent.verticalCenter
                                        visible: root.warpConnected
                                        text: "· " + root.warpMode; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont } }
                                // WARP toggle switch
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                    width: 36; height: 20; radius: 10
                                    color: root.warpConnected ? theme.good : theme.a(theme.line, 0.85)
                                    border.width: 1; border.color: root.warpConnected ? theme.a(theme.good,0.5) : theme.a(theme.iris,0.3)
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Rectangle { width: 15; height: 15; radius: 8; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
                                        x: root.warpConnected ? 19 : 2; Behavior on x { NumberAnimation { duration: 130 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.warpToggle() } } }

                            // WARP mode chips (only when WARP is connected)
                            Row { visible: root.warpConnected; spacing: 5; topPadding: 2
                                Repeater { model: ["warp","doh","warp+doh","tunnel_only"]
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool cur: root.warpMode === modelData
                                        height: 20; radius: 5; width: modeTxt.implicitWidth + 14
                                        color: cur ? theme.a(theme.good,0.2) : (modeMa.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.3))
                                        border.width: cur ? 1 : 0; border.color: theme.a(theme.good,0.4)
                                        Text { id: modeTxt; anchors.centerIn: parent
                                            text: modelData; color: cur ? theme.good : theme.faint
                                            font.pixelSize: 9; font.family: root.cfgFont; font.bold: cur }
                                        MouseArea { id: modeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.warpSetMode(modelData) } } } }

                            // NM VPN connections (if any saved)
                            Repeater { model: root.vpnList
                                delegate: Item { required property var modelData
                                    readonly property bool connecting: modelData.state === "activating" || root.vpnActionName === modelData.name
                                    readonly property bool failed: root.vpnFailedName === modelData.name
                                    width: parent.width; height: 34
                                    Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 0
                                        Row { spacing: 7
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "vpn_key"; sz: 14
                                                color: modelData.active ? theme.iris : (connecting ? theme.frost : (failed ? theme.bad : theme.faint)) }
                                            Text { anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.name; color: modelData.active ? theme.text : (connecting ? theme.frost : (failed ? theme.bad : theme.sub))
                                                font.pixelSize: 11; font.family: root.cfgFont; font.bold: modelData.active || connecting; elide: Text.ElideRight } }
                                        Text {
                                            visible: connecting || failed || modelData.active
                                            text: connecting ? "connecting…" : (failed ? "connection failed" : "connected")
                                            color: connecting ? theme.frost : (failed ? theme.bad : theme.good)
                                            font.pixelSize: 9; font.family: root.cfgFont; leftPadding: 21 } }
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                        width: 36; height: 20; radius: 10
                                        color: modelData.active ? theme.iris : (connecting ? theme.a(theme.frost, 0.4) : theme.a(theme.line, 0.85))
                                        border.width: 1; border.color: modelData.active ? theme.a(theme.iris,0.5) : (connecting ? theme.a(theme.frost,0.3) : theme.a(theme.iris,0.3))
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Rectangle { width: 15; height: 15; radius: 8; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
                                            x: modelData.active ? 19 : 2; Behavior on x { NumberAnimation { duration: 130 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: connecting ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: if (!connecting) root.vpnToggle(modelData.name) } } } } } }
                    Drop { screen: bar.screen
                        id: btDrop; host: btPill; shown: root.openPop ==="bt" && root.openBar === bar
                        cardW: 290; cardH: btCol.implicitHeight + 28
                        Column { id: btCol; anchors.fill: btDrop.card; anchors.margins: 14; spacing: 4
                            // Header
                            Item { width: parent.width; height: 28
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "bluetooth"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 6
                                    Rectangle { width: 26; height: 26; radius: 8
                                        color: btScanMa.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                        Sym { anchors.centerIn: parent; text: (root.btAdapter&&root.btAdapter.discovering)?"sync":"search"; sz: 15; color: theme.sub }
                                        MouseArea { id: btScanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering } }
                                    // power toggle
                                    Rectangle { width: 36; height: 20; radius: 10; anchors.verticalCenter: undefined
                                        color: (root.btAdapter&&root.btAdapter.enabled)?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: theme.a(theme.iris,0.3)
                                        Rectangle { width: 15; height: 15; radius: 8; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
                                            x: (root.btAdapter&&root.btAdapter.enabled)?19:2; Behavior on x { NumberAnimation { duration: 130 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Repeater { model: root.btDevices
                                delegate: Rectangle { required property var modelData; width: parent.width; height: 36; radius: 8
                                    color: modelData.connected ? theme.a(theme.iris,0.18) : (dm.containsMouse ? theme.a(theme.line,0.45) : "transparent")
                                    border.width: modelData.connected ? 1 : 0; border.color: theme.a(theme.iris,0.3)
                                    Row { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: root.btIcon(modelData); sz: 17; color: modelData.connected?theme.iris:theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - (modelData.batteryAvailable?100:60); elide: Text.ElideRight; text: root.btName(modelData); color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: modelData.connected }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: modelData.batteryAvailable; text: Math.round((modelData.battery||0)*100)+"%"; color: theme.sub; font.pixelSize: 10; font.family: root.cfgFont }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: modelData.connected; text: "check_circle"; sz: 14; color: theme.good }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: modelData.pairing; text: "sync"; sz: 14; color: theme.warn } }
                                    MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { if(modelData.connected) modelData.disconnect(); else modelData.connect() } } } }
                            Text { visible: root.btDevices.length===0; text: (root.btAdapter&&root.btAdapter.enabled)?"tap search to scan…":"bluetooth is off"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont; topPadding: 4 } } }
                    Drop { screen: bar.screen
                        id: sysDrop; host: sysPill; shown: root.openPop ==="sys" && root.openBar === bar
                        cardW: 250; cardH: sysCol.implicitHeight + 28
                        Column { id: sysCol; anchors.fill: sysDrop.card; anchors.margins: 14; spacing: 10
                            // Header
                            Item { width: parent.width; height: 20
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "system"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 4
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "developer_board"; sz: 13; color: theme.faint }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "live"; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            // CPU
                            StatBar { width: parent.width; label: "CPU"
                                value: root.cpuUsage; barColor: root.loadColor(root.cpuUsage, 70, 90)
                                rightText: Math.round(root.cpuUsage)+"%  ·  "+Math.round(root.cpuTemp)+"°C" }
                            // RAM
                            StatBar { width: parent.width; label: "RAM"; barColor: theme.iris
                                value: root.memPct
                                rightText: root.memUsed.toFixed(1)+" / "+root.memTotal.toFixed(1)+" GB" }
                            // GPU (only when a discrete GPU is present)
                            Column { width: parent.width; spacing: 10; visible: root.hasGpu
                                Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                                Item { width: parent.width; height: 14
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: "GPU"; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.6 }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 40; elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                                        text: root.gpuName; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont } }
                                StatBar { width: parent.width; label: "usage"
                                    value: root.gpuUsage; barColor: root.loadColor(root.gpuUsage, 70, 90)
                                    rightText: Math.round(root.gpuUsage)+"%  ·  "+Math.round(root.gpuTemp)+"°C" }
                                StatBar { width: parent.width; label: "VRAM"; barColor: theme.frost
                                    value: root.gpuMemTotal>0 ? root.gpuMemUsed/root.gpuMemTotal*100 : 0
                                    rightText: root.gpuMemUsed.toFixed(1)+" / "+root.gpuMemTotal.toFixed(1)+" GB" }
                                Item { width: parent.width; height: 15
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: "power draw"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        text: root.gpuPower.toFixed(1)+" W"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true } } } } }
                    Drop { screen: bar.screen
                        id: volDrop; host: volPill; shown: root.openPop ==="vol" && root.openBar === bar
                        cardW: 290; cardH: volCol.implicitHeight + 28
                        Column { id: volCol; anchors.fill: volDrop.card; anchors.margins: 14; spacing: 4
                            // Header
                            Item { width: parent.width; height: 28
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "volume"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                    text: volPill.vol+"%"; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 4; width: 1 }
                            // Volume slider row
                            Row { width: parent.width; spacing: 10; height: 32
                                Rectangle { width: 28; height: 28; radius: 8; anchors.verticalCenter: parent.verticalCenter
                                    color: volMuteMa.containsMouse ? theme.a(theme.iris,0.15) : "transparent"
                                    Sym { anchors.centerIn: parent; text: (volPill.au&&volPill.au.muted)?"volume_off":"volume_up"; sz: 17; color: (volPill.au&&volPill.au.muted)?theme.bad:theme.frost }
                                    MouseArea { id: volMuteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(volPill.au) volPill.au.muted=!volPill.au.muted } }
                                Slider { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 38
                                    value: volPill.au ? volPill.au.volume : 0
                                    onMoved: (v)=>{ if(volPill.au){ volPill.au.muted=false; volPill.au.volume=v } } } }
                            Item { height: 2; width: 1 }
                            Text { text: "output device"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; font.letterSpacing: 0.5 }
                            Item { height: 1; width: 1 }
                            Repeater { model: root.sinks
                                delegate: Rectangle { required property var modelData; readonly property bool cur: Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.id===modelData.id
                                    width: parent.width; height: 32; radius: 8
                                    color: cur ? theme.a(theme.iris,0.18) : (sm.containsMouse?theme.a(theme.line,0.45):"transparent")
                                    border.width: cur ? 1 : 0; border.color: theme.a(theme.iris,0.3)
                                    Row { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: cur?"radio_button_checked":"radio_button_unchecked"; sz: 15; color: cur?theme.iris:theme.faint }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width-42; elide: Text.ElideRight; text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: cur } }
                                    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Pipewire.preferredDefaultAudioSink = modelData } } } } }
                    Drop { screen: bar.screen
                        id: batDrop; host: batPill; shown: root.openPop ==="bat" && root.openBar === bar
                        cardW: 230; cardH: batCol.implicitHeight + 28
                        Column { id: batCol; anchors.fill: batDrop.card; anchors.margins: 14; spacing: 4
                            // Header
                            Item { width: parent.width; height: 28
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "power profile"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                    text: batPill.pct+"%"; color: batPill.charging?theme.good:batPill.pct<=20?theme.bad:theme.sub; font.pixelSize: 12; font.family: root.cfgFont } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Repeater { model: [{k:"performance",i:"speed",l:"Performance"},{k:"balanced",i:"balance",l:"Balanced"},{k:"power-saver",i:"eco",l:"Power Saver"}]
                                delegate: Rectangle { required property var modelData; readonly property bool cur: root.powerProfile===modelData.k
                                    width: parent.width; height: 34; radius: 8
                                    color: cur ? theme.a(theme.iris,0.18) : (bm.containsMouse?theme.a(theme.line,0.45):"transparent")
                                    border.width: cur ? 1 : 0; border.color: theme.a(theme.iris,0.3)
                                    Row { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 17; color: cur?theme.iris:theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: cur?theme.text:theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: cur } }
                                    MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setProfile(modelData.k) } } } } }
                    Drop { screen: bar.screen
                        id: calDrop; host: clockPill; shown: root.openPop ==="cal" && root.openBar === bar
                        cardW: 280; cardH: calCol.implicitHeight + 32
                        onVisibleChanged: { if (visible) reloadEventsProc.running = true }
                        Column { id: calCol; anchors.fill: calDrop.card; anchors.margins: 14; spacing: 10
                            property var dt: clock.date
                            property int yr: dt.getFullYear()
                            property int mo: dt.getMonth()
                            property int today: dt.getDate()
                            property int lead: new Date(yr, mo, 1).getDay()
                            property var days: { var arr=[]; var n=new Date(yr, mo+1, 0).getDate(); for(var i=1;i<=n;i++) arr.push(i); return arr }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(clock.date,"MMMM yyyy"); color: theme.frost; font.pixelSize: 14; font.family: root.cfgFont; font.bold: true }
                            // at-a-glance counts for today / the next 7 days
                            Text { anchors.horizontalCenter: parent.horizontalCenter
                                readonly property int todayN: root.calEvents.filter(function(e){ return (""+e.date) === root.calTodayKey(); }).length
                                readonly property int weekN: {
                                    var end = new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate()+6);
                                    var ek = end.getFullYear()+"-"+String(end.getMonth()+1).padStart(2,"0")+"-"+String(end.getDate()).padStart(2,"0");
                                    return root.calUpcoming.filter(function(e){ return (""+e.date) <= ek; }).length;
                                }
                                visible: weekN > 0
                                text: [ todayN>0 ? todayN + " today" : "", weekN>0 ? weekN + " this week" : "" ].filter(Boolean).join("  ·  ")
                                color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont }
                            Grid { anchors.horizontalCenter: parent.horizontalCenter; columns: 7; spacing: 4
                                Repeater { model: ["S","M","T","W","T","F","S"]
                                    delegate: Text { required property var modelData; width: 34; horizontalAlignment: Text.AlignHCenter; text: modelData; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont } }
                                Repeater { model: calCol.lead
                                    delegate: Item { width: 34; height: 26 } }
                                Repeater { model: calCol.days
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool isToday: modelData===calCol.today
                                        readonly property bool hasEvent: {
                                            var dateStr = calCol.yr + "-" + String(calCol.mo + 1).padStart(2, "0") + "-" + String(modelData).padStart(2, "0");
                                            return root.calEvents.some(function(e) { return e.date === dateStr; });
                                        }
                                        width: 34; height: 26; radius: 7
                                        color: isToday ? theme.iris : (hasEvent ? theme.a(theme.iris, 0.13) : "transparent")
                                        border.width: (hasEvent && !isToday) ? 1 : 0; border.color: theme.a(theme.frost, 0.4)
                                        Text { anchors.centerIn: parent; text: parent.modelData; color: parent.isToday ? theme.bg : theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: parent.isToday }
                                        Rectangle {
                                            visible: parent.hasEvent && !parent.isToday
                                            width: 3; height: 3; radius: 1.5; color: theme.frost
                                            anchors.bottom: parent.bottom; anchors.bottomMargin: 3; anchors.horizontalCenter: parent.horizontalCenter } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column {
                                width: parent.width; spacing: 5
                                Item { width: parent.width; height: 12
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: "UPCOMING"; color: theme.frost; font.pixelSize: 9; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 1 }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        visible: root.calUpcoming.length > 4; text: "+" + (root.calUpcoming.length - 4) + " more"
                                        color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } }
                                Text { visible: root.calUpcoming.length === 0; text: "nothing coming up"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                Repeater {
                                    model: root.calUpcoming.slice(0, 4)
                                    delegate: Rectangle {
                                        id: evRow
                                        required property var modelData
                                        readonly property string rel: root.calRel(modelData.date)
                                        readonly property bool soon: evRow.rel === "today" || evRow.rel === "tomorrow"
                                        width: parent.width; height: 34; radius: 7
                                        color: evRow.soon ? theme.a(theme.iris, 0.12) : "transparent"
                                        Row {
                                            anchors.fill: parent; anchors.leftMargin: 7; anchors.rightMargin: 8; spacing: 9
                                            Column { anchors.verticalCenter: parent.verticalCenter; width: 26
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: (""+evRow.modelData.date).slice(8)
                                                    color: evRow.soon ? theme.frost : theme.iris; font.pixelSize: 15; font.family: root.cfgFont; font.bold: true }
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.calDate(evRow.modelData.date), "MMM").toUpperCase()
                                                    color: theme.faint; font.pixelSize: 8; font.family: root.cfgFont } }
                                            Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 44; spacing: 1
                                                Text { width: parent.width; text: evRow.modelData.title; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; elide: Text.ElideRight }
                                                Text { text: evRow.rel + "  ·  " + Qt.formatDate(root.calDate(evRow.modelData.date), "ddd") + (evRow.modelData.time ? "  ·  " + evRow.modelData.time : "")
                                                    color: evRow.soon ? theme.frost : theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } } } } } } }
                    Drop { screen: bar.screen
                        id: pwrDrop; host: pwrPill; shown: root.openPop ==="pwr" && root.openBar === bar
                        cardW: 210; cardH: pwrCol.implicitHeight + 28
                        property string confirmL: ""          // reboot/shutdown ask for a second click
                        property string who: ""
                        property string up: ""
                        onVisibleChanged: { pwrDrop.confirmL = ""; if (visible) upProc.running = true }
                        Process { id: upProc; command: ["sh","-c","printf '%s@%s|' \"$USER\" \"$(hostnamectl hostname 2>/dev/null || hostname)\"; awk '{s=int($1); printf \"up %dh %02dm\", s/3600, (s%3600)/60}' /proc/uptime"]
                            stdout: StdioCollector { id: upOut; onStreamFinished: { var p = upOut.text.split("|"); pwrDrop.who = p[0]||""; pwrDrop.up = p[1]||"" } } }
                        Column { id: pwrCol; anchors.fill: pwrDrop.card; anchors.margins: 10; spacing: 3
                            Row { width: parent.width; spacing: 7; bottomPadding: 2
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "person"; sz: 15; color: theme.iris }
                                Column { anchors.verticalCenter: parent.verticalCenter; spacing: 0
                                    Text { text: pwrDrop.who; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true }
                                    Text { text: pwrDrop.up; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            Item { width: 1; height: 2 }
                            Repeater { model: [{i:"lock",l:"lock",c:"~/.config/quickshell/sea-shell/sea-lock.sh",col:theme.frost},
                                               {i:"bedtime",l:"suspend",c:"systemctl suspend",col:theme.frost},
                                               {i:"logout",l:"log out",c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch exit; sleep 3; loginctl terminate-session self; }",col:theme.frost},
                                               {i:"restart_alt",l:"reboot",c:"systemctl reboot",col:theme.warn,danger:true},
                                               {i:"power_settings_new",l:"shut down",c:"systemctl poweroff",col:theme.bad,danger:true}]
                                delegate: Rectangle { required property var modelData
                                    readonly property bool arming: pwrDrop.confirmL === modelData.l
                                    width: parent.width; height: 34; radius: 8
                                    color: arming ? theme.a(theme.bad,0.18) : (pw.containsMouse ? theme.a(theme.iris,0.16) : "transparent")
                                    border.width: arming ? 1 : 0; border.color: theme.a(theme.bad,0.6)
                                    Row { anchors.fill: parent; anchors.leftMargin: 10; spacing: 10
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 17; color: modelData.col }
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: arming ? "click again to " + modelData.l : modelData.l
                                            color: arming ? theme.bad : theme.text; font.pixelSize: 13; font.family: root.cfgFont } }
                                    MouseArea { id: pw; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.danger && !arming) { pwrDrop.confirmL = modelData.l; return }
                                            root.openPop=""; Quickshell.execDetached(["sh","-c",modelData.c]) } } } } } }
                }
            }

            // register this bar's windows with the ONE shared focus grab at root —
            // a grab per bar fights the other monitors' grabs and insta-closes dropdowns
            Item { Component.onCompleted: { root.grabWins = root.grabWins.concat([bar, wxDrop, wifiDrop, btDrop, volDrop, batDrop, calDrop, pwrDrop, notifDrop, mprisDrop, trayDrop, sysDrop]) } }
        }
    }

 // ===== on-screen notification popups (top-right, under the bar) =====
    PanelWindow {
        id: notifWin
        anchors { top: true; right: true }
        margins { top: 50; right: 12 }
        implicitWidth: 370
        implicitHeight: Math.max(1, popCol.implicitHeight)
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "sea-shell:notif"
        exclusionMode: ExclusionMode.Ignore
        visible: popupModel.count > 0
        mask: Region { item: popCol }
        Column {
            id: popCol; anchors.top: parent.top; anchors.right: parent.right; width: parent.width; spacing: 8
            Repeater {
                model: popupModel
                delegate: Rectangle {
                    id: pcard
                    required property var model
                    width: popCol.width; radius: root.cfgRadius
                    implicitHeight: pcc.implicitHeight + 22
                    color: theme.a(theme.bg, root.dropOpacity)
                    border.width: 1; border.color: pcard.model.urg===2 ? theme.a(theme.bad,0.6) : theme.a(theme.iris,0.34)
                    Column { id: pcc; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12; anchors.rightMargin: 36; spacing: 3
                        Row { width: parent.width
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: pcard.model.urg===2 ? "priority_high" : "notifications"; sz: 13; color: pcard.model.urg===2 ? theme.bad : theme.frost }
                            Text { leftPadding: 6; anchors.verticalCenter: parent.verticalCenter; text: pcard.model.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-24 } }
                        Text { width: parent.width; visible: pcard.model.summary!==""; text: pcard.model.summary; color: theme.text; font.pixelSize: 13; font.family: root.cfgFont; font.bold: true; wrapMode: Text.WordWrap }
                        Text { width: parent.width; visible: pcard.model.body!==""; text: pcard.model.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight; textFormat: Text.PlainText }
                    }
                    Rectangle { anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6; width: 22; height: 22; radius: 11
                        color: xm.containsMouse ? theme.a(theme.iris,0.2) : "transparent"
                        Sym { anchors.centerIn: parent; text: "close"; sz: 14; color: theme.sub }
                        MouseArea { id: xm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.popDismiss(pcard.model.key) } }
                    Timer { running: true; interval: pcard.model.urg===2 ? 12000 : 5000; onTriggered: root.popDismiss(pcard.model.key) }
                }
            }
        }
    }

    // ===== OSD (volume / brightness), bottom-centre =====
    PanelWindow {
        anchors { bottom: true; left: true; right: true }
        margins { bottom: 80 }
        implicitHeight: 60
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:osd"
        exclusionMode: ExclusionMode.Ignore
        visible: root.osdKind !== ""
        mask: Region { item: osdCard }
        Rectangle {
            id: osdCard
            anchors.centerIn: parent
            width: 250; height: 54; radius: root.cfgRadius
            color: theme.a(theme.bg, root.dropOpacity); border.width: 1; border.color: theme.a(theme.iris,0.34)
            Row { anchors.fill: parent; anchors.margins: 16; spacing: 13
                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.osdIcon; sz: 24; color: theme.frost }
                Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width-52; spacing: 6
                    Row { width: parent.width
                        Text { text: root.osdKind==="vol" ? "volume" : "brightness"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                        Item { width: parent.width - 80; height: 1 }
                        Text { text: Math.round(root.osdVal*100)+"%"; color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont } }
                    Rectangle { width: parent.width; height: 6; radius: 3; color: theme.a(theme.line,0.85)
                        Rectangle { width: parent.width*Math.max(0,Math.min(1,root.osdVal)); height: parent.height; radius: 3; color: theme.iris
                            Behavior on width { NumberAnimation { duration: 90 } } } }
                }
            }
        }
    }

    // ===== alt-tab window switcher =====
    PanelWindow {
        id: switcherWin
        visible: root.switcherOpen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:switcher"
        exclusionMode: ExclusionMode.Ignore
        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.35)
            MouseArea { anchors.fill: parent; onClicked: root.switcherOpen = false } }   // click-away cancels
        readonly property int cardW: 148
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, swFlick.contentWidth + 28)
            height: swCol.implicitHeight + 22
            radius: root.cfgRadius + 4
            color: theme.a(theme.bg, 0.97)
            border.width: 1; border.color: theme.a(theme.iris, 0.32)
            Column {
                id: swCol; anchors.centerIn: parent; width: parent.width - 24; spacing: 9
                Flickable {
                    id: swFlick; width: parent.width; height: 150; contentWidth: swRow.implicitWidth; clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Row {
                        id: swRow; height: parent.height; spacing: 10
                        Repeater {
                            model: root.switcherWins
                            delegate: Rectangle {
                                id: swCard
                                required property var modelData
                                required property int index
                                readonly property bool sel: index === root.switcherSel
                                readonly property var ipc: modelData.lastIpcObject
                                width: switcherWin.cardW; height: 146; radius: 12
                                color: sel ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.4)
                                border.width: sel ? 2 : 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                Column {
                                    anchors.centerIn: parent; width: parent.width - 18; spacing: 7
                                    IconImage { anchors.horizontalCenter: parent.horizontalCenter; implicitSize: 52; asynchronous: true
                                        source: Quickshell.iconPath((""+(swCard.ipc.class||"")).toLowerCase(), "application-x-executable") }
                                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                        text: swCard.ipc.class||"window"; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: swCard.sel }
                                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap
                                        text: swCard.ipc.title||""; color: theme.sub; font.pixelSize: 9; font.family: root.cfgFont }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.switcherSel = swCard.index; root.switcherCommit() } }
                            }
                        }
                    }
                    // keep the selected card visible when cycling past the edge
                    Connections { target: root; function onSwitcherSelChanged() {
                        var x = root.switcherSel * (switcherWin.cardW + 10);
                        if (x < swFlick.contentX) swFlick.contentX = x;
                        else if (x + switcherWin.cardW > swFlick.contentX + swFlick.width) swFlick.contentX = x + switcherWin.cardW - swFlick.width;
                    } }
                }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                    text: root.switcherWins.length + " windows · Tab cycles · release Alt to focus · Esc cancels"
                    color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
            }
        }
    }

    // ===== Exposé Mission Control HUD overlay =====
    property bool exposeActive: false
    function toggleExpose() { root.exposeActive = !root.exposeActive }
    
    PanelWindow {
        id: exposeWin
        visible: root.exposeActive
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:expose"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        
        // dim background scrim
        Rectangle {
            anchors.fill: parent; color: theme.a(theme.bg, theme.light ? 0.96 : 0.94)
            MouseArea { anchors.fill: parent; onClicked: root.exposeActive = false }
            
            FocusScope {
                anchors.fill: parent; focus: exposeWin.visible
                Keys.onEscapePressed: root.exposeActive = false
                
                ColumnLayout {
                    anchors.centerIn: parent; width: Math.min(parent.width - 100, 1000)
                    height: Math.min(parent.height - 100, 700); spacing: 20
                    
                    // Header
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "MISSION CONTROL / EXPOSÉ"; color: theme.text; font.pixelSize: 22; font.bold: true; font.family: root.cfgFont }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            implicitWidth: 32; implicitHeight: 32; radius: 16
                            color: expClMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                            border.width: 1; border.color: theme.a(theme.iris, 0.16)
                            Sym { anchors.centerIn: parent; text: "close"; sz: 16; color: theme.frost }
                            MouseArea { id: expClMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.exposeActive = false }
                        }
                    }
                    
                    // Grid of workspaces
                    Flow {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 20
                        Repeater {
                            model: Hyprland.workspaces ? Hyprland.workspaces.values : []
                            delegate: Rectangle {
                                id: wsBox
                                required property var modelData
                                width: 280; height: 180; radius: root.cfgRadius
                                color: theme.a(theme.line, 0.55); border.width: 1
                                border.color: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id ? theme.iris : theme.a(theme.iris, 0.12)
                                
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 12; spacing: 10
                                    
                                    // Workspace header
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text { text: "Workspace " + modelData.id; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont }
                                        Item { Layout.fillWidth: true }
                                        Text { text: modelData.name; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                    }
                                    
                                    // List of windows in this workspace
                                    ListView {
                                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                                        model: {
                                            var m = Hyprland.toplevels ? Hyprland.toplevels.values : [];
                                            var out = [];
                                            for (var i = 0; i < m.length; i++) {
                                                var t = m[i];
                                                if (t && t.lastIpcObject && t.lastIpcObject.workspace && t.lastIpcObject.workspace.id === modelData.id) {
                                                    out.push(t);
                                                }
                                            }
                                            return out;
                                        }
                                        delegate: Rectangle {
                                            id: winCard
                                            required property var modelData
                                            width: parent.width; height: 32; radius: 6
                                            color: theme.a(theme.line, 0.5)
                                            RowLayout {
                                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                                IconImage {
                                                    implicitSize: 18; asynchronous: true
                                                    source: Quickshell.iconPath(("" + (modelData.lastIpcObject.class || "")).toLowerCase(), "application-x-executable")
                                                }
                                                Text {
                                                    text: modelData.lastIpcObject.class || "window"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont
                                                    elide: Text.ElideRight; Layout.fillWidth: true
                                                }
                                                // Close window button
                                                Sym {
                                                    text: "close"; sz: 13; color: winClMa.containsMouse ? theme.bad : theme.faint
                                                    MouseArea {
                                                        id: winClMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: Hyprland.dispatch("closewindow address:" + modelData.lastIpcObject.address)
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                anchors.fill: parent; anchors.rightMargin: 24; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    Hyprland.dispatch("focuswindow address:" + modelData.lastIpcObject.address);
                                                    root.exposeActive = false;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
