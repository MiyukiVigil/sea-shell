//@ pragma UseQApplication
// sea-shell — settings / control center (tabbed)
// RESIDENT: preloaded once by shell.qml (Loader) and shown/hidden via IPC so opening is
// instant instead of spawning a ~0.5s `qs -p` process each time. Toggle it with
//   qs -c sea-shell ipc call settings toggle       (SUPER+S)
// or, in-process, settingsLoader.item.openTab(n).  Esc / click-outside hides it.
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts

Scope {
    id: root
    property string repo: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    readonly property string seaVersion: "2.0"     // sea-shell release — mirrored in the repo VERSION file
    property int tab: 8                             // land on the System / About dashboard

    // ---- resident lifecycle: the panel is hidden until shown, so it costs ~nothing closed ----
    property bool shown: false
    function openPanel() { root.showTab(8) }
    function openTab(t) { root.showTab(t) }
    function closePanel() { root.shown = false }
    function togglePanel() { if (root.shown) root.closePanel(); else root.openPanel() }
    function showTab(t) {
        apReadProc.running = true;                  // pick up appearance changes made while closed
        if (root.tab === t) root.refreshTab(t); else root.tab = t;   // else onTabChanged refreshes
        root.shown = true;
    }
    function refreshTab(t) {
        if (t === 7) kbProc.running = true            // keybinds: refresh binds
        if (t === 8) sysProc.running = true           // system: refresh live stats
        if (t === 10) { idleChk.running = true; lockSettingsGet.running = true }   // idle & lock
        if (t === 6) ppGet.running = true             // power: re-read profile
        if (t === 11) { reloadEventsProc.running = true; calCfgLoad.running = true }  // calendar
    }
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }
    onTabChanged: refreshTab(tab)

    // SUPER+S and other external triggers toggle the resident panel through this handler
    IpcHandler {
        target: "settings"
        function toggle(): void { root.togglePanel() }
        function open(): void { root.openPanel() }
        function openTab(tab: int): void { root.openTab(tab) }
        function close(): void { root.closePanel() }
    }

    // ---------- native QML file browser ----------
    property bool fileBrowserOpen: false
    property string fileBrowserPath: ""  // current directory (absolute path)
    property string fileBrowserFilter: "" // e.g. ".conf", ".ovpn", ".ics"
    property var fileBrowserCallback: null // function(path) called on file selection
    property var fileBrowserItems: []     // [{type, name}]
    property string fileBrowserTitle: ""

    Process {
        id: fileBrowserProc
        stdout: StdioCollector { id: fbOut; onStreamFinished: {
            var items = [];
            var text = fbOut.text.trim();
            if (text) {
                text.split("\n").forEach(line => {
                    var parts = line.split("|");
                    if (parts.length >= 2) {
                        items.push({ type: parts[0], name: parts[1] });
                    }
                });
            }
            root.fileBrowserItems = items;
        } }
    }

    function pickFile(title, filter, callback) {
        root.fileBrowserTitle = title;
        var ext = "";
        if (filter) {
            var m = filter.match(/\*\.([a-zA-Z0-9]+)/);
            if (m) ext = "." + m[1];
            else if (filter.indexOf(".") >= 0) ext = filter.slice(filter.indexOf("."));
        }
        root.fileBrowserFilter = ext;
        root.fileBrowserCallback = callback;
        if (!root.fileBrowserPath) {
            root.fileBrowserPath = "/home/miyukivigil"; // default start
        }
        root.fileBrowserOpen = true;
        refreshFileBrowser();
    }

    function refreshFileBrowser() {
        var cmd = "find \"" + root.fileBrowserPath + "\" -maxdepth 1 -not -name '.*' -printf '%Y|%f\\n' 2>/dev/null | sort -t'|' -k1,1r -k2,2";
        fileBrowserProc.command = ["sh", "-c", cmd];
        fileBrowserProc.running = true;
    }

    function enterDir(name) {
        var path = root.fileBrowserPath;
        if (path === "/") {
            root.fileBrowserPath = "/" + name;
        } else {
            root.fileBrowserPath = path + "/" + name;
        }
        refreshFileBrowser();
    }

    function goUpDir() {
        var path = root.fileBrowserPath;
        if (path === "/" || path === "") return;
        var i = path.lastIndexOf("/");
        if (i === 0) {
            root.fileBrowserPath = "/";
        } else {
            root.fileBrowserPath = path.slice(0, i);
        }
        refreshFileBrowser();
    }


    // ---------- system overview (System tab) ----------
    property var sysInfo: ({ gpus: [] })
    Process { id: sysProc; running: true
        command: ["bash", root.repo + "/sea-sysinfo.sh"]
        stdout: StdioCollector { id: sysOut; onStreamFinished: {
            var o = { gpus: [] };
            sysOut.text.split("\n").forEach(l => { var i = l.indexOf("="); if (i < 1) return;
                var k = l.slice(0, i), v = l.slice(i + 1);
                if (k === "gpu") o.gpus.push(v); else o[k] = v });
            root.sysInfo = o;
        } } }

    // ---------- calendar events (import & view) ----------
    property string calMsg: ""
    property var calEvents: []
    // subscriptions + reminder prefs live in calendar.json (also touched by the import script)
    property var calSubs: []
    property bool calRemind: true
    property int  calLead: 30
    Process { id: calCfgLoad; running: true; command: ["sh","-c","cat ~/.config/sea-shell/calendar.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: calCfgOut; onStreamFinished: { try { var j=JSON.parse(calCfgOut.text.trim()||"{}");
            root.calSubs = j.subs || []; if(j.remind!==undefined) root.calRemind=!!j.remind; if(j.lead!==undefined) root.calLead=j.lead; } catch(e){} } } }
    // one Process for every calendar mutation (delete / unsub / resync / set) → reload after
    Process { id: calMutProc
        stdout: StdioCollector { onStreamFinished: { reloadEventsProc.running = true; calCfgLoad.running = true; } } }
    function calMutate(a) { calMutProc.command = ["python3", root.repo + "/sea-import-ics.py"].concat(a); calMutProc.running = false; calMutProc.running = true; }
    function evKey(e) { return e.date + "|" + e.title + "|" + (e.time||""); }
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
    Process {
        id: calImportProc
        stdout: StdioCollector { id: calImportOut; onStreamFinished: {
            try {
                var res = JSON.parse(calImportOut.text.trim());
                if (res.status === "success") {
                    root.calMsg = "Successfully imported " + res.imported + " new events! (Total: " + res.total + ")";
                    reloadEventsProc.running = true;
                } else {
                    root.calMsg = "Failed: " + res.message;
                }
            } catch(e) {
                root.calMsg = "Import finished with error";
            }
        } }
    }
    function importICS(path) {
        root.calMsg = "importing calendar events…";
        calImportProc.command = ["python3", root.repo + "/sea-import-ics.py", path];
        calImportProc.running = true;
    }
    function clearEvents() {
        run("rm -f ~/.config/sea-shell/calendar_events.json");
        root.calEvents = [];
        root.calMsg = "All calendar events cleared.";
    }
    // events sorted chronologically, plus a small relative-time helper for the Calendar tab
    readonly property var calSorted: root.calEvents.slice().sort(function(a,b){ return (""+a.date) < (""+b.date) ? -1 : (""+a.date) > (""+b.date) ? 1 : 0 })
    function evDate(s) { var p = (""+s).split("-"); return new Date(parseInt(p[0]), (parseInt(p[1])||1)-1, parseInt(p[2])||1); }
    function evRel(s) {
        var d = root.evDate(s); d.setHours(0,0,0,0);
        var now = new Date(); now.setHours(0,0,0,0);
        var days = Math.round((d.getTime() - now.getTime()) / 86400000);
        if (days < 0)   return { t: days===-1 ? "yesterday" : (-days)+"d ago", past: true,  soon: false };
        if (days === 0) return { t: "today",             past: false, soon: true  };
        if (days === 1) return { t: "tomorrow",          past: false, soon: true  };
        if (days < 7)   return { t: "in "+days+"d",       past: false, soon: true  };
        if (days < 31)  return { t: "in "+Math.round(days/7)+"w",  past: false, soon: false };
        return { t: "in "+Math.round(days/30)+"mo",      past: false, soon: false };
    }

    // ---------- bluetooth (same engine as the bar dropdown) ----------
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btDevices: (btAdapter && btAdapter.devices) ? btAdapter.devices.values : []
    function btName(d) { return d ? (d.deviceName || d.name || d.address || "device") : "" }

    // ---------- idle & lock ----------
    property bool idleOn: false
    Process { id: idleChk; running: true; command: ["sh","-c","pgrep -x hypridle >/dev/null && echo on || echo off"]
        stdout: StdioCollector { id: idleOut; onStreamFinished: root.idleOn = idleOut.text.trim() === "on" } }
    function toggleIdle() {
        if (root.idleOn) run("pkill -x hypridle"); else run("hyprctl dispatch exec hypridle");
        root.idleOn = !root.idleOn;
    }

    // ---------- idle & lock config data ----------
    property int lockDim: 150
    property int lockLock: 300
    property int lockDpms: 600
    property int lockSuspend: 1800
    property bool lockSuspendEnabled: true
    property int lockGrace: 2
    property bool lockHideCursor: true
    property bool lockIgnoreEmpty: true
    property int lockBlurPasses: 3
    property int lockBlurSize: 6
    property real lockVibrancy: 0.15
    property string lockBg: "~/.config/sea-shell/sea-wall.png"

    Process {
        id: lockSettingsGet
        running: false
        command: ["python3", Qt.resolvedUrl("sea-lock-settings.py").toString().replace("file://",""), "get"]
        stdout: StdioCollector {
            id: lockGetOut
            onStreamFinished: {
                try {
                    var data = JSON.parse(lockGetOut.text);
                    if (data.idle_dim !== undefined) root.lockDim = data.idle_dim;
                    if (data.idle_lock !== undefined) root.lockLock = data.idle_lock;
                    if (data.idle_dpms !== undefined) root.lockDpms = data.idle_dpms;
                    if (data.idle_suspend !== undefined) root.lockSuspend = data.idle_suspend;
                    if (data.idle_suspend_enabled !== undefined) root.lockSuspendEnabled = data.idle_suspend_enabled;
                    if (data.lock_grace !== undefined) root.lockGrace = data.lock_grace;
                    if (data.lock_hide_cursor !== undefined) root.lockHideCursor = data.lock_hide_cursor;
                    if (data.lock_ignore_empty !== undefined) root.lockIgnoreEmpty = data.lock_ignore_empty;
                    if (data.lock_blur_passes !== undefined) root.lockBlurPasses = data.lock_blur_passes;
                    if (data.lock_blur_size !== undefined) root.lockBlurSize = data.lock_blur_size;
                    if (data.lock_vibrancy !== undefined) root.lockVibrancy = data.lock_vibrancy;
                    if (data.lock_bg !== undefined) root.lockBg = data.lock_bg;
                } catch(e) {
                    console.log("Error parsing lock settings: " + e);
                }
            }
        }
    }

    Process {
        id: lockSettingsSet
        running: false
    }

    function saveLockSettings() {
        var obj = {
            "idle_dim": root.lockDim,
            "idle_lock": root.lockLock,
            "idle_dpms": root.lockDpms,
            "idle_suspend": root.lockSuspend,
            "idle_suspend_enabled": root.lockSuspendEnabled,
            "lock_grace": root.lockGrace,
            "lock_hide_cursor": root.lockHideCursor,
            "lock_ignore_empty": root.lockIgnoreEmpty,
            "lock_blur_passes": root.lockBlurPasses,
            "lock_blur_size": root.lockBlurSize,
            "lock_vibrancy": root.lockVibrancy,
            "lock_bg": root.lockBg
        };
        var jsonStr = JSON.stringify(obj);
        var escapedJson = jsonStr.replace(/'/g, "'\\''");
        var scriptPath = Qt.resolvedUrl("sea-lock-settings.py").toString().replace("file://","");
        lockSettingsSet.command = ["sh", "-c", "printf '%s' '" + escapedJson + "' | python3 " + scriptPath + " set"];
        lockSettingsSet.running = true;
    }

    // ---------- power profile + battery ----------
    property string powerProfile: "balanced"
    Process { id: ppGet; running: true; command: ["sh","-c","powerprofilesctl get 2>/dev/null"]
        stdout: StdioCollector { id: ppOut; onStreamFinished: root.powerProfile = (ppOut.text.trim() || "balanced") } }
    function setProfile(p) { root.powerProfile = p; run("powerprofilesctl set " + p) }

    // ---------- per-app audio streams + input devices ----------
    property var sources: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && !n.isSink && !n.isStream && n.audio })
    property var streams: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isStream && n.audio })
    function streamName(n) { return n ? (n.name || n.description || n.nickname || "app") : "" }

    // ---------- keybinds tab: live binds + rebind (same engine as keybinds.qml) ----------
    property var kbBinds: []
    property string kbQuery: ""
    property var kbRec: null          // bind being rebound
    property var kbRecMods: []
    property string kbConflict: ""

    // Add new bind state variables
    property bool kbAdding: false
    property string kbAddDesc: ""
    property string kbAddAction: "exec, "
    property var kbAddMods: ["SUPER"]
    property string kbAddKey: ""
    property bool kbAddRecording: false
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
    function kbApplyAddBind() {
        var modsStr = root.kbAddMods.join(" ");
        var scriptPath = Qt.resolvedUrl("sea-add-bind.sh").toString().replace("file://","");
        Quickshell.execDetached(["sh", scriptPath, modsStr, root.kbAddKey, root.kbAddDesc, root.kbAddAction]);
        root.kbAdding = false;
        root.kbAddDesc = "";
        root.kbAddAction = "exec, ";
        root.kbAddKey = "";
        root.kbAddMods = ["SUPER"];
        kbRefetch.start();
    }

    QtObject {
        id: theme
        readonly property bool light: root.apLight
        readonly property color _acc: root.apAccent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    light ? Qt.hsla(_ah, 0.20, 0.945, 1) : Qt.hsla(_ah, 0.36, 0.070, 1)
        readonly property color panel: light ? Qt.hsla(_ah, 0.18, 0.895, 1) : Qt.hsla(_ah, 0.30, 0.110, 1)
        readonly property color line:  light ? Qt.hsla(_ah, 0.16, 0.780, 1) : Qt.hsla(_ah, 0.24, 0.205, 1)
        readonly property color text:  light ? "#0c1520" : "#e2e9f4"
        readonly property color sub:   light ? "#2c4256" : "#a6b6cf"
        readonly property color faint: light ? "#48606f" : "#6f8099"
        readonly property color iris:  light ? Qt.darker(root.apAccent, 2.4)  : root.apAccent
        readonly property color frost: light ? Qt.darker(root.apAccent, 1.7) : Qt.lighter(root.apAccent, 1.22)
        readonly property color good:  light ? "#2f9e63" : "#a6e3a1"
        readonly property color warn:  light ? "#b9820f" : "#f4c542"
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
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
            for (var j = 0; j < root.sources.length; j++) arr.push(root.sources[j]);
            for (var k = 0; k < root.streams.length; k++) arr.push(root.streams[k]);
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
    property bool apLight: false            // dark (default) ↔ light palette
    property bool apMatugen: false          // recolour accent + kitty from the wallpaper
    property string apScheme: "scheme-tonal-spot"   // matugen colour-scheme algorithm
    readonly property var schemes: ["scheme-tonal-spot","scheme-content","scheme-neutral","scheme-expressive","scheme-fidelity","scheme-monochrome","scheme-rainbow","scheme-fruit-salad"]
    property string apBarFill: "matugen"            // top-bar fill: matugen · black · white
    property string apEdge: "top"                   // bar dock edge: top or bottom
    readonly property var edges: ["top","bottom"]
    property bool apAutoDark: false         // auto-switch dark/light by time of day
    property string apDarkStart: "19:00"    // dark begins
    property string apDarkEnd: "07:00"      // dark ends (light begins)
    property var apCustomFonts: []      // fonts the user typed, persisted as chips
    property string apAppMode: "auto"       // system app dark/light: "auto" (follows shell), "dark", "light"
    property int apSubTab: 0
    property int idlSubTab: 0
    // ---------- bar widgets toggles ----------
    property bool wgMpris: true
    property bool wgTray: true
    property bool wgWeather: true
    property bool wgClipboard: true
    property bool wgNotif: true
    property bool wgWifi: true
    property bool wgBluetooth: true
    property bool wgCaffeine: true
    property bool wgSystem: true
    property bool wgVolume: true
    property bool wgBattery: true
    property bool wgClock: true
    property bool wgPower: true
    // ---------- matugen per-target overrides ----------
    property bool ovrHyprland: true
    property bool ovrKitty: true
    property bool ovrFastfetch: true
    property bool ovrStarship: true
    property string ovrHyprActive: ""       // custom active border colour (hex, empty = auto)
    property string ovrHyprInactive: ""     // custom inactive border colour (hex, empty = auto)
    property string ovrKittyAccent: ""      // custom kitty accent (hex, empty = auto)
    property string ovrKittyBg: ""          // custom kitty background (hex, empty = auto)
    property string ovrFastfetchAccent: ""  // custom fastfetch accent (hex, empty = auto)
    property string ovrStarshipAccent: ""   // custom starship accent (hex, empty = auto)
    Process { id: ovrReadProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/matugen-overrides.json\" 2>/dev/null"]
        stdout: StdioCollector { id: ovrOut; onStreamFinished: { try { var j=JSON.parse(ovrOut.text);
            if(j.hyprland) { if(j.hyprland.enabled!==undefined) root.ovrHyprland=!!j.hyprland.enabled; if(j.hyprland.customActive) root.ovrHyprActive=j.hyprland.customActive; if(j.hyprland.customInactive) root.ovrHyprInactive=j.hyprland.customInactive; }
            if(j.kitty) { if(j.kitty.enabled!==undefined) root.ovrKitty=!!j.kitty.enabled; if(j.kitty.customAccent) root.ovrKittyAccent=j.kitty.customAccent; if(j.kitty.customBg) root.ovrKittyBg=j.kitty.customBg; }
            if(j.fastfetch) { if(j.fastfetch.enabled!==undefined) root.ovrFastfetch=!!j.fastfetch.enabled; if(j.fastfetch.customAccent) root.ovrFastfetchAccent=j.fastfetch.customAccent; }
            if(j.starship) { if(j.starship.enabled!==undefined) root.ovrStarship=!!j.starship.enabled; if(j.starship.customAccent) root.ovrStarshipAccent=j.starship.customAccent; }
        } catch(e){} } } }
    function saveOverrides() {
        var j = '{"hyprland":{"enabled":'+(root.ovrHyprland?'true':'false')+',"customActive":"'+root.ovrHyprActive+'","customInactive":"'+root.ovrHyprInactive+'"},"kitty":{"enabled":'+(root.ovrKitty?'true':'false')+',"customAccent":"'+root.ovrKittyAccent+'","customBg":"'+root.ovrKittyBg+'"},"fastfetch":{"enabled":'+(root.ovrFastfetch?'true':'false')+',"customAccent":"'+root.ovrFastfetchAccent+'"},"starship":{"enabled":'+(root.ovrStarship?'true':'false')+',"customAccent":"'+root.ovrStarshipAccent+'"}}';
        run("mkdir -p \"$HOME/.config/sea-shell\" && printf '%s' '"+j+"' > \"$HOME/.config/sea-shell/matugen-overrides.json\"");
    }
    function toggleOverride(target) { saveOverrides(); run("sh '"+root.matugenScript+"'"); }
    property var accents: ["#63c7dd","#4dd0c4","#6aa6ff","#cba6f7","#a6e3a1","#f4c542","#f38ba8","#ff9e64"]
    property var baseFonts: ["monospace","MesloLGM Nerd Font","JetBrainsMono Nerd Font","FiraCode Nerd Font","sans-serif","Iosevka"]
    readonly property var fontPresets: root.baseFonts.concat(root.apCustomFonts)
    Process { id: apReadProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text);
            if(j.radius!==undefined) root.apRadius=j.radius; if(j.opacity!==undefined) root.apOpacity=j.opacity;
            if(j.height!==undefined) root.apHeight=j.height; if(j.accent!==undefined) root.apAccent=j.accent;
            if(j.font!==undefined) root.apFont=j.font; if(j.customFonts!==undefined) root.apCustomFonts=j.customFonts;
            if(j.mode!==undefined) root.apLight=(""+j.mode==="light"); if(j.matugen!==undefined) root.apMatugen=!!j.matugen;
            if(j.scheme!==undefined && (""+j.scheme).length>0) root.apScheme=j.scheme;
            if(j.barFill!==undefined && (""+j.barFill).length>0) root.apBarFill=j.barFill;
            if(j.edge==="top"||j.edge==="bottom") root.apEdge=j.edge;   // horizontal bar only
            if(j.autoDark!==undefined) root.apAutoDark=!!j.autoDark; if(j.darkStart!==undefined) root.apDarkStart=j.darkStart; if(j.darkEnd!==undefined) root.apDarkEnd=j.darkEnd;
            if(j.appMode!==undefined && (j.appMode==="auto"||j.appMode==="dark"||j.appMode==="light")) root.apAppMode=j.appMode;
            if(j.wgMpris!==undefined) root.wgMpris=!!j.wgMpris;
            if(j.wgTray!==undefined) root.wgTray=!!j.wgTray;
            if(j.wgWeather!==undefined) root.wgWeather=!!j.wgWeather;
            if(j.wgClipboard!==undefined) root.wgClipboard=!!j.wgClipboard;
            if(j.wgNotif!==undefined) root.wgNotif=!!j.wgNotif;
            if(j.wgWifi!==undefined) root.wgWifi=!!j.wgWifi;
            if(j.wgBluetooth!==undefined) root.wgBluetooth=!!j.wgBluetooth;
            if(j.wgCaffeine!==undefined) root.wgCaffeine=!!j.wgCaffeine;
            if(j.wgSystem!==undefined) root.wgSystem=!!j.wgSystem;
            if(j.wgVolume!==undefined) root.wgVolume=!!j.wgVolume;
            if(j.wgBattery!==undefined) root.wgBattery=!!j.wgBattery;
            if(j.wgClock!==undefined) root.wgClock=!!j.wgClock;
            if(j.wgPower!==undefined) root.wgPower=!!j.wgPower;
        } catch(e){} root.apLoaded = true; } } }
    // gates the window until the saved palette is read, so it fades in with the user's
    // matugen colours instead of flashing the default sea-cyan for a frame first
    property bool apLoaded: false

    // ---------- theme profiles ----------
    property var profilesList: []
    Process { id: profilesReadProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/profiles.json\" 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: profOut; onStreamFinished: { try { root.profilesList = JSON.parse(profOut.text) } catch(e){ root.profilesList = [] } } } }

    function saveProfile(name) {
        if (!name.trim()) return;
        var p = {
            name: name.trim(),
            accent: root.apAccent,
            radius: root.apRadius,
            opacity: root.apOpacity,
            height: root.apHeight,
            font: root.apFont,
            mode: root.apLight ? "light" : "dark",
            matugen: root.apMatugen,
            scheme: root.apScheme,
            edge: root.apEdge,
            barFill: root.apBarFill,
            autoDark: root.apAutoDark,
            darkStart: root.apDarkStart,
            darkEnd: root.apDarkEnd,
            appMode: root.apAppMode,
            wgMpris: root.wgMpris,
            wgTray: root.wgTray,
            wgWeather: root.wgWeather,
            wgClipboard: root.wgClipboard,
            wgNotif: root.wgNotif,
            wgWifi: root.wgWifi,
            wgBluetooth: root.wgBluetooth,
            wgCaffeine: root.wgCaffeine,
            wgSystem: root.wgSystem,
            wgVolume: root.wgVolume,
            wgBattery: root.wgBattery,
            wgClock: root.wgClock,
            wgPower: root.wgPower
        };
        var list = root.profilesList.slice();
        var idx = -1;
        for (var i = 0; i < list.length; i++) {
            if (list[i].name === name.trim()) { idx = i; break; }
        }
        if (idx >= 0) list[idx] = p; else list.push(p);
        root.profilesList = list;
        
        var base64 = Qt.btoa(JSON.stringify(list));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + base64 + "' | base64 -d > \"$HOME/.config/sea-shell/profiles.json\"");
    }

    function loadProfile(p) {
        if (p.accent !== undefined) root.apAccent = p.accent;
        if (p.radius !== undefined) root.apRadius = p.radius;
        if (p.opacity !== undefined) root.apOpacity = p.opacity;
        if (p.height !== undefined) root.apHeight = p.height;
        if (p.font !== undefined) root.apFont = p.font;
        if (p.matugen !== undefined) root.apMatugen = p.matugen;
        if (p.scheme !== undefined) root.apScheme = p.scheme;
        if (p.edge !== undefined) root.apEdge = p.edge;
        if (p.barFill !== undefined) root.apBarFill = p.barFill;
        if (p.autoDark !== undefined) root.apAutoDark = p.autoDark;
        if (p.darkStart !== undefined) root.apDarkStart = p.darkStart;
        if (p.darkEnd !== undefined) root.apDarkEnd = p.darkEnd;
        if (p.appMode !== undefined) root.apAppMode = p.appMode;
        if (p.mode !== undefined) root.apLight = ("" + p.mode === "light");
        
        if (p.wgMpris !== undefined) root.wgMpris = p.wgMpris;
        if (p.wgTray !== undefined) root.wgTray = p.wgTray;
        if (p.wgWeather !== undefined) root.wgWeather = p.wgWeather;
        if (p.wgClipboard !== undefined) root.wgClipboard = p.wgClipboard;
        if (p.wgNotif !== undefined) root.wgNotif = p.wgNotif;
        if (p.wgWifi !== undefined) root.wgWifi = p.wgWifi;
        if (p.wgBluetooth !== undefined) root.wgBluetooth = p.wgBluetooth;
        if (p.wgCaffeine !== undefined) root.wgCaffeine = p.wgCaffeine;
        if (p.wgSystem !== undefined) root.wgSystem = p.wgSystem;
        if (p.wgVolume !== undefined) root.wgVolume = p.wgVolume;
        if (p.wgBattery !== undefined) root.wgBattery = p.wgBattery;
        if (p.wgClock !== undefined) root.wgClock = p.wgClock;
        if (p.wgPower !== undefined) root.wgPower = p.wgPower;
        
        root.saveAppearance();
    }

    function deleteProfile(idx) {
        var list = root.profilesList.slice();
        list.splice(idx, 1);
        root.profilesList = list;
        var base64 = Qt.btoa(JSON.stringify(list));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + base64 + "' | base64 -d > \"$HOME/.config/sea-shell/profiles.json\"");
    }
    function saveAppearance() {
        var cf = '['; for(var i=0;i<root.apCustomFonts.length;i++){ cf += (i?',':'') + '\"'+root.apCustomFonts[i]+'\"'; } cf += ']';
        var j = '{\"radius\":'+Math.round(root.apRadius)+',\"opacity\":'+root.apOpacity.toFixed(2)+',\"height\":'+Math.round(root.apHeight)+',\"accent\":\"'+root.apAccent+'\",\"font\":\"'+root.apFont+'\",\"customFonts\":'+cf+',\"mode\":\"'+(root.apLight?'light':'dark')+'\",\"matugen\":'+(root.apMatugen?'true':'false')+',\"scheme\":\"'+root.apScheme+'\",\"barFill\":\"'+root.apBarFill+'\",\"edge\":\"'+root.apEdge+'\",\"autoDark\":'+(root.apAutoDark?'true':'false')+',\"darkStart\":\"'+root.apDarkStart+'\",\"darkEnd\":\"'+root.apDarkEnd+'\",\"appMode\":\"'+root.apAppMode+'\",\"wgMpris\":'+(root.wgMpris?'true':'false')+',\"wgTray\":'+(root.wgTray?'true':'false')+',\"wgWeather\":'+(root.wgWeather?'true':'false')+',\"wgClipboard\":'+(root.wgClipboard?'true':'false')+',\"wgNotif\":'+(root.wgNotif?'true':'false')+',\"wgWifi\":'+(root.wgWifi?'true':'false')+',\"wgBluetooth\":'+(root.wgBluetooth?'true':'false')+',\"wgCaffeine\":'+(root.wgCaffeine?'true':'false')+',\"wgSystem\":'+(root.wgSystem?'true':'false')+',\"wgVolume\":'+(root.wgVolume?'true':'false')+',\"wgBattery\":'+(root.wgBattery?'true':'false')+',\"wgClock\":'+(root.wgClock?'true':'false')+',\"wgPower\":'+(root.wgPower?'true':'false')+'}';
        run("mkdir -p \"$HOME/.config/sea-shell\" && printf '%s' '"+j+"' > \"$HOME/.config/sea-shell/appearance.json\"");
    }
    // apply the system app dark/light preference independently from the shell theme
    function applyAppMode() {
        var m = root.apAppMode;
        if (m === "auto") m = root.apLight ? "light" : "dark";
        if (m === "light") run("gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'");
        else run("gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'");
    }
    function addCustomFont(f) {
        f = (f||"").trim(); if(f==="") return;
        if (root.baseFonts.indexOf(f)<0 && root.apCustomFonts.indexOf(f)<0) { var a=root.apCustomFonts.slice(); a.push(f); root.apCustomFonts=a; }
        root.apFont = f; root.saveAppearance();
    }
    // matugen AUTO toggle — persist the flag, then apply now (accent + kitty from the
    // wallpaper) or reset everything back to the default sea cyan.
    property string matugenScript: Qt.resolvedUrl("matugen-accent.sh").toString().replace("file://","")
    property string pickScript: Qt.resolvedUrl("sea-pick-color.sh").toString().replace("file://","")
    property string pickingTarget: ""
    Process {
        id: colorPickerProc
        command: ["sh", root.pickScript]
        stdout: StdioCollector {
            id: pickerOut
            onStreamFinished: {
                var col = pickerOut.text.trim();
                if (col.indexOf("#") === 0 && col.length === 7) {
                    root.applyPickedColor(col);
                }
            }
        }
    }
    function applyPickedColor(col) {
        if (root.pickingTarget === "accent") {
            root.apAccent = col;
            root.saveAppearance();
            run("sh '"+root.matugenScript+"'");
        } else if (root.pickingTarget === "hyprActive") {
            root.ovrHyprActive = col;
            root.toggleOverride("hyprland");
        } else if (root.pickingTarget === "hyprInactive") {
            root.ovrHyprInactive = col;
            root.toggleOverride("hyprland");
        } else if (root.pickingTarget === "kittyAccent") {
            root.ovrKittyAccent = col;
            root.toggleOverride("kitty");
        } else if (root.pickingTarget === "kittyBg") {
            root.ovrKittyBg = col;
            root.toggleOverride("kitty");
        } else if (root.pickingTarget === "fastfetch") {
            root.ovrFastfetchAccent = col;
            root.toggleOverride("fastfetch");
        } else if (root.pickingTarget === "starship") {
            root.ovrStarshipAccent = col;
            root.toggleOverride("starship");
        }
    }
    function toggleMatugen() {
        root.apMatugen = !root.apMatugen; root.saveAppearance();
        if (root.apMatugen) run("sh '"+root.matugenScript+"'");
        else { root.apAccent = "#63c7dd"; root.saveAppearance(); run("sh '"+root.matugenScript+"' --reset"); }
    }
    // pick a matugen scheme algorithm — persist it, then re-derive the palette if matugen is on
    function setScheme(s) {
        root.apScheme = s; root.saveAppearance();
        if (root.apMatugen) run("sh '"+root.matugenScript+"'");
    }
    // matugen: derive a palette from the current wallpaper (pick any swatch)
    property bool matugenBusy: false
    property var matugenPalette: []      // several extracted colours to choose from
    Process {
        id: matugenProc
        // for video/gif wallpapers, grab the first frame with ffmpeg, then colour-match that
        command: ["sh","-c","wp=$(cat \"$HOME/.config/sea-shell/wallpaper\" 2>/dev/null); [ -z \"$wp\" ] && exit 1; " +
            "case \"$wp\" in *.mp4|*.webm|*.mkv|*.mov|*.gif) f=/tmp/sea-matugen-frame.png; ffmpeg -y -i \"$wp\" -vframes 1 \"$f\" >/dev/null 2>&1 && wp=\"$f\";; esac; " +
            "matugen --json hex --type "+root.apScheme+" --prefer saturation image \"$wp\" 2>/dev/null"]
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
    function rescanWifi() { run("nmcli dev wifi rescan 2>/dev/null"); wifiScan.running = true; savedScan.running = true; infoScan.running = true }

    // saved (known) wifi connections — for the forget button + "saved" tag
    property var savedCons: []
    Process { id: savedScan; running: true
        command: ["sh","-c","nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2==\"802-11-wireless\"{print $1}'"]
        stdout: StdioCollector { id: savedOut; onStreamFinished: root.savedCons = savedOut.text.trim() ? savedOut.text.trim().split("\n") : [] } }
    function wifiForget(ssid) {
        var e = ssid.replace(/'/g, "");
        root.wifiMsg = "forgot “" + e + "”";
        run("nmcli con delete id '" + e + "' 2>/dev/null"); wifiRefresh.start();
    }
    // active connection details (ip · gateway · dns)
    property var netInfo: ({ dns: [] })
    Process { id: infoScan; running: true
        command: ["sh","-c","dev=$(nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null | awk -F: '$2==\"wifi\" && $3==\"connected\"{print $1; exit}'); [ -z \"$dev\" ] && exit 0; printf 'iface=%s\\n' \"$dev\"; nmcli -t -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS dev show \"$dev\" 2>/dev/null"]
        stdout: StdioCollector { id: infoOut; onStreamFinished: {
            var o = { dns: [] };
            infoOut.text.split("\n").forEach(l => {
                if (l.indexOf("iface=") === 0) o.iface = l.slice(6);
                else if (l.indexOf("IP4.ADDRESS") === 0) o.ip = l.split(":")[1] || "";
                else if (l.indexOf("IP4.GATEWAY") === 0) o.gw = l.split(":")[1] || "";
                else if (l.indexOf("IP4.DNS") === 0) o.dns.push(l.split(":")[1] || "");
            });
            root.netInfo = o;
        } } }
    // hidden network join
    property bool hidOpen: false
    function wifiJoinHidden(ssid, pw) {
        if (!ssid.length) return;
        var e = ssid.replace(/'/g, ""), p = pw.replace(/'/g, "'\\''");
        root.wifiMsg = "connecting to hidden “" + e + "”…"; root.hidOpen = false; root.wifiRetry = "";
        wifiJoin.command = ["sh","-c","nmcli dev wifi connect '" + e + "'" + (pw.length ? " password '" + p + "'" : "") + " hidden yes 2>&1"];
        wifiJoin.running = true;
    }
    // connecting: open networks join directly; secured ones expand an INLINE password
    // row (a spawned terminal would sit behind this overlay's exclusive keyboard grab)
    property string wifiPwFor: ""     // ssid awaiting its password
    property string wifiMsg: ""
    property bool wifiRadio: true
    Process { running: true; command: ["sh","-c","nmcli radio wifi"]
        stdout: StdioCollector { id: wrOut; onStreamFinished: root.wifiRadio = wrOut.text.trim() === "enabled" } }
    function setWifiRadio(on) { root.wifiRadio = on; root.wifiMsg = on ? "" : "wi-fi off"; run("nmcli radio wifi " + (on ? "on" : "off")); wifiRefresh.start() }
    property string wifiRetry: ""     // ssid whose saved profile we're trying before prompting
    function wifiConnect(ssid, secure) {
        var e = ssid.replace(/'/g, "");
        if (secure && root.savedCons.indexOf(ssid) >= 0) {
            // known network → reconnect with the STORED password; prompt only on failure
            root.wifiMsg = "connecting…"; root.wifiRetry = ssid;
            wifiJoin.command = ["sh","-c","nmcli con up id '" + e + "' 2>&1"];
            wifiJoin.running = true; return;
        }
        if (secure) { root.wifiPwFor = ssid; root.wifiMsg = ""; return }
        root.wifiMsg = "connecting…"; root.wifiRetry = "";
        wifiJoin.command = ["sh","-c","nmcli dev wifi connect '" + e + "' 2>&1"];
        wifiJoin.running = true;
    }
    function wifiJoinPw(ssid, pw) {
        if (!pw.length) return;
        var e = ssid.replace(/'/g, ""), p = pw.replace(/'/g, "'\\''");
        root.wifiMsg = "connecting…"; root.wifiPwFor = ""; root.wifiRetry = "";
        wifiJoin.command = ["sh","-c","nmcli dev wifi connect '" + e + "' password '" + p + "' 2>&1"];
        wifiJoin.running = true;
    }
    function wifiDisconnect(ssid) {
        var e = ssid.replace(/'/g, "");
        root.wifiMsg = "disconnected from " + e;
        run("nmcli con down id '" + e + "' 2>/dev/null"); wifiRefresh.start();
    }
    Process { id: wifiJoin
        stdout: StdioCollector { id: wjOut; onStreamFinished: {
            var t = wjOut.text.trim();
            var ok = t.indexOf("successfully") >= 0;
            if (!ok && root.wifiRetry !== "") {           // stored secret failed → ask inline
                root.wifiPwFor = root.wifiRetry; root.wifiRetry = "";
                root.wifiMsg = "saved password didn't work — enter it again";
                wifiRefresh.start(); return;
            }
            root.wifiRetry = "";
            root.wifiMsg = ok ? "connected ✓"
                         : t.indexOf("Secrets were required") >= 0 || t.indexOf("password") >= 0 ? "wrong password — try again"
                         : t.split("\n")[0].slice(0, 64);
            wifiRefresh.start();
        } } }
    Timer { id: wifiRefresh; interval: 2500; onTriggered: root.rescanWifi() }

    // ---------- cloudflare warp ----------
    property string warpStatus: "Disconnected"
    property bool warpConnected: warpStatus.indexOf("Connected") >= 0 && warpStatus.indexOf("Disconnected") < 0
    property string warpMode: "warp"
    Process {
        id: warpPoll; running: true
        command: ["sh","-c","warp-cli status 2>/dev/null | grep '^Status' | sed 's/Status update: //'"]
        stdout: StdioCollector { id: warpOut; onStreamFinished: { var s = warpOut.text.trim(); if (s) root.warpStatus = s } }
    }
    Process {
        id: warpModePoll; running: true
        command: ["sh","-c","warp-cli mode 2>/dev/null | awk 'NR==1{print $NF}'"]
        stdout: StdioCollector { id: warpModeOut; onStreamFinished: { var m = warpModeOut.text.trim(); if (m) root.warpMode = m } }
    }
    Timer { id: warpPollTimer; interval: 4000; running: root.shown; repeat: true; triggeredOnStart: true
        onTriggered: { warpPoll.running = true; warpModePoll.running = true } }
    function warpToggle() {
        if (root.warpConnected) {
            run("warp-cli disconnect && notify-send 'sea-shell' 'WARP disconnected'");
            root.warpStatus = "Disconnected";
        } else {
            run("warp-cli connect && notify-send 'sea-shell' 'WARP connected' || notify-send 'sea-shell' 'WARP failed'");
            root.warpStatus = "Connecting...";
        }
        warpRefreshTimer.start();
    }
    function warpSetMode(m) { run("warp-cli mode " + m); root.warpMode = m; warpRefreshTimer.start() }
    Timer { id: warpRefreshTimer; interval: 1800; repeat: false; onTriggered: { warpPoll.running = true; warpModePoll.running = true } }

    // ---------- VPN (NetworkManager — wireguard + openvpn) ----------
    property var vpnList: []      // [{name, type, state, active}]
    property string vpnMsg: ""
    property bool vpnAddOpen: false
    property int vpnAddMode: 0    // 0=wireguard conf, 1=openvpn ovpn
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
    Timer { id: vpnPollTimer; interval: 5000; running: root.shown; repeat: true; triggeredOnStart: true; onTriggered: vpnScan.running = true }
    Timer { id: vpnRefreshTimer; interval: 2200; repeat: false; onTriggered: vpnScan.running = true }
    function vpnToggle(name) {
        if (root.vpnActionName !== "") return;
        root.vpnActionName = name;
        root.vpnFailedName = "";
        var e = name.replace(/'/g, "");
        var cur = root.vpnList.find(function(v){ return v.name===name && v.state==="activated"; });
        if (cur) {
            vpnActionProc.command = ["nmcli", "con", "down", "id", e];
            root.vpnMsg = "disconnecting " + e + "…";
        } else {
            vpnActionProc.command = ["nmcli", "con", "up", "id", e];
            root.vpnMsg = "connecting " + e + "…";
        }
        vpnActionProc.running = true;
        vpnScan.running = true;
    }
    function vpnDelete(name) {
        var e = name.replace(/'/g, "");
        run("nmcli con delete id '" + e + "' 2>/dev/null");
        root.vpnMsg = "deleted " + e;
        vpnRefreshTimer.start();
    }
    // Import WireGuard via nmcli — expects the raw .conf text
    function vpnAddWireguard(confPath) {
        if (!confPath.trim()) { root.vpnMsg = "enter the path to a .conf file"; return }
        var p = confPath.trim().replace(/^~/, Qt.resolvedUrl(".").toString().replace("file://","").replace(/\/quickshell.*$/,""));
        run("nmcli con import type wireguard file '" + p.replace(/'/g,"'\\''") + "' && notify-send 'sea-shell' 'WireGuard profile imported' || notify-send 'sea-shell' 'Import failed — check path'");
        root.vpnMsg = "importing WireGuard…"; vpnRefreshTimer.start();
    }
    // Import OpenVPN via nmcli
    function vpnAddOpenVPN(confPath) {
        if (!confPath.trim()) { root.vpnMsg = "enter the path to a .ovpn file"; return }
        var p = confPath.trim().replace(/^~/, Qt.resolvedUrl(".").toString().replace("file://","").replace(/\/quickshell.*$/,""));
        run("nmcli con import type openvpn file '" + p.replace(/'/g,"'\\''") + "' && notify-send 'sea-shell' 'OpenVPN profile imported' || notify-send 'sea-shell' 'Import failed — check path'");
        root.vpnMsg = "importing OpenVPN…"; vpnRefreshTimer.start();
    }

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
                Text { text: parent.parent.parent.label; color: theme.text; font.pixelSize: 13; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            MouseArea {
                id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.run(parent.parent.cmd); if (parent.parent.quitAfter) root.closePanel() }
            }
        }
    }

    // a single tab button in the sidebar
    component TabBtn: Rectangle {
        property string icon: ""
        property string label: ""
        property int idx: 0
        readonly property bool sel: root.tab === idx
        Layout.fillWidth: true; implicitHeight: 32; radius: 9
        color: sel ? theme.a(theme.iris, 0.2) : (tbm.containsMouse ? theme.a(theme.line, 0.5) : "transparent")
        border.width: 1; border.color: sel ? theme.a(theme.iris, 0.5) : "transparent"
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 10
            Sym { text: icon; sz: 18; color: sel ? theme.iris : theme.sub }
            Text { text: label; color: sel ? theme.text : theme.sub; font.pixelSize: 13; font.family: "monospace"; font.bold: sel; Layout.fillWidth: true }
        }
        MouseArea { id: tbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = idx }
    }

    // small uppercase section heading that groups the sidebar tabs
    component GroupLabel: Text {
        Layout.fillWidth: true; Layout.topMargin: 9; Layout.leftMargin: 5; Layout.bottomMargin: 1
        color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1.5
    }

    // one key/value tile for the About/System dashboard
    component InfoTile: Rectangle {
        property string icon: ""
        property string label: ""
        property string value: "…"
        Layout.fillWidth: true; implicitHeight: 46; radius: 11
        color: theme.a(theme.line, 0.24); border.width: 1; border.color: theme.a(theme.iris, 0.10)
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 11
            Sym { text: icon; sz: 19; color: theme.iris }
            ColumnLayout {
                spacing: 1; Layout.fillWidth: true
                Text { text: label; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                Text { text: value; color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
            }
        }
    }

    // a labelled progress meter (RAM / disk)
    component Meter: RowLayout {
        property string label: ""
        property string value: "…"
        property real pct: 0
        property color fill: theme.iris
        Layout.fillWidth: true; spacing: 11
        Text { text: label; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.preferredWidth: 58 }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 9; radius: 5; color: theme.a(theme.line, 0.8)
            Rectangle { height: parent.height; radius: 5
                width: parent.width * Math.max(0, Math.min(1, parent.parent.pct / 100))
                color: parent.parent.pct > 88 ? theme.bad : parent.parent.fill
                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
        }
        Text { text: value; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; Layout.preferredWidth: 96; horizontalAlignment: Text.AlignRight }
    }

    // ============ window ============
    PanelWindow {
        id: panel
        visible: root.shown                    // resident: mapped only while open
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.5); MouseArea { anchors.fill: parent; onClicked: root.closePanel() } }
        Item { anchors.fill: parent; focus: root.shown; Keys.onEscapePressed: root.closePanel() }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 60, 960)
            height: Math.min(parent.height - 60, 780)
            radius: 18
            // fade in once the saved palette is read — no default sea-cyan flash first
            opacity: root.apLoaded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            // ---------------- sidebar (anchored, fixed width) ----------------
            ColumnLayout {
                id: sidebar
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 18 }
                width: 202; spacing: 3
                // ---- brand header: logo + name + version ----
                RowLayout {
                    spacing: 11; Layout.fillWidth: true; Layout.bottomMargin: 4
                    SeaLogo { size: 34; card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        RowLayout {
                            spacing: 6
                            Text { text: "sea-shell"; color: theme.text; font.pixelSize: 17; font.family: "monospace"; font.bold: true }
                            Rectangle {
                                implicitHeight: 15; implicitWidth: verTxt.width + 10; radius: 7
                                color: theme.a(theme.iris, 0.18); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                Text { id: verTxt; anchors.centerIn: parent; text: "v" + root.seaVersion
                                    color: theme.frost; font.pixelSize: 9; font.family: "monospace"; font.bold: true }
                            }
                        }
                        Text { text: "control center"; color: theme.frost; font.pixelSize: 10; font.family: "monospace" }
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; Layout.bottomMargin: 2; height: 1; color: theme.a(theme.iris, 0.14) }

                GroupLabel { text: "OVERVIEW" }
                TabBtn { icon: "monitor_heart";        label: "System";      idx: 8 }
                GroupLabel { text: "LOOK & FEEL" }
                TabBtn { icon: "palette";              label: "Appearance";  idx: 4 }
                TabBtn { icon: "widgets";              label: "Bar Widgets"; idx: 12 }
                TabBtn { icon: "auto_awesome";         label: "Theme Profiles"; idx: 13 }
                GroupLabel { text: "DEVICES" }
                TabBtn { icon: "volume_up";            label: "Audio";       idx: 0 }
                TabBtn { icon: "brightness_6";         label: "Display";     idx: 1 }
                TabBtn { icon: "wifi";                 label: "Network";     idx: 2 }
                TabBtn { icon: "bluetooth";            label: "Bluetooth";   idx: 9 }
                GroupLabel { text: "DAILY" }
                TabBtn { icon: "cloud";                label: "Weather";     idx: 3 }
                TabBtn { icon: "calendar_month";       label: "Calendar";    idx: 11 }
                TabBtn { icon: "keyboard";             label: "Keybinds";    idx: 7 }
                GroupLabel { text: "SESSION" }
                TabBtn { icon: "bedtime";              label: "Idle & lock"; idx: 10 }
                TabBtn { icon: "bolt";                 label: "Actions";     idx: 5 }
                TabBtn { icon: "power_settings_new";   label: "Power";       idx: 6 }
                Item { Layout.fillHeight: true; Layout.minimumHeight: 6 }
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
                            Text { text: "input device"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.sources
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.curSource && root.curSource.id === modelData.id
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (sma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 8
                                            Sym { text: cur ? "radio_button_checked" : "radio_button_unchecked"; sz: 16; color: cur ? theme.iris : theme.faint }
                                            Text { text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: Pipewire.preferredDefaultAudioSource = modelData }
                                    }
                                }
                            }
                            Section { title: "per-app volume"; icon: "graphic_eq" }
                            Text { visible: root.streams.length === 0; text: "nothing is playing"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: root.streams
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true; spacing: 10
                                        Sym { text: "music_note"; sz: 16; color: theme.frost }
                                        Text { text: root.streamName(modelData); color: theme.sub; font.pixelSize: 11; font.family: "monospace"
                                            elide: Text.ElideRight; Layout.preferredWidth: 130 }
                                        Slider {
                                            fill: theme.iris
                                            value: modelData.audio ? modelData.audio.volume : 0
                                            onMoved: (v) => { if (modelData.audio) modelData.audio.volume = v }
                                        }
                                        Text { text: modelData.audio ? Math.round(modelData.audio.volume * 100) + "%" : "—"
                                               color: theme.sub; font.pixelSize: 11; font.family: "monospace"; Layout.minimumWidth: 36; horizontalAlignment: Text.AlignRight }
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
                                // radio on/off toggle
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                    color: root.wifiRadio ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: root.wifiRadio ? theme.iris : theme.a(theme.line, 0.9)
                                    Rectangle { width: 16; height: 16; radius: 8; y: 3
                                        x: root.wifiRadio ? parent.width - 19 : 3
                                        color: root.wifiRadio ? theme.frost : theme.faint
                                        Behavior on x { NumberAnimation { duration: 120 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setWifiRadio(!root.wifiRadio) } }
                                Sym { text: "refresh"; sz: 17; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.rescanWifi() } }
                            }
                            // active connection details
                            Rectangle {
                                visible: !!root.netInfo.ip
                                Layout.fillWidth: true; implicitHeight: netCol.implicitHeight + 16; radius: 8
                                color: theme.a(theme.iris, 0.08); border.width: 1; border.color: theme.a(theme.iris, 0.25)
                                ColumnLayout {
                                    id: netCol; anchors.fill: parent; anchors.margins: 10; spacing: 3
                                    Repeater {
                                        model: [
                                            { k: "ip",      v: root.netInfo.ip || "" },
                                            { k: "gateway", v: root.netInfo.gw || "" },
                                            { k: "dns",     v: (root.netInfo.dns || []).join("  ·  ") },
                                            { k: "iface",   v: root.netInfo.iface || "" }
                                        ]
                                        delegate: RowLayout {
                                            required property var modelData
                                            visible: modelData.v !== ""
                                            Layout.fillWidth: true; spacing: 8
                                            Text { text: modelData.k; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.preferredWidth: 56 }
                                            Text { text: modelData.v; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                    }
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.wifiList
                                    delegate: Rectangle {
                                        id: wrow
                                        required property var modelData
                                        readonly property bool asking: root.wifiPwFor === modelData.ssid
                                        onAskingChanged: if (asking) pwIn.forceActiveFocus()
                                        Layout.fillWidth: true; implicitHeight: asking ? 80 : 40; radius: 8
                                        Behavior on implicitHeight { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                                        color: modelData.active ? theme.a(theme.iris, 0.2) : (wma.containsMouse || asking ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: asking ? theme.iris : modelData.active ? theme.iris : theme.a(theme.iris, 0.12)
                                        clip: true
                                        ColumnLayout {
                                            anchors { fill: parent; leftMargin: 12; rightMargin: 12; topMargin: 4; bottomMargin: 6 }
                                            spacing: 2
                                            Item {
                                                Layout.fillWidth: true; implicitHeight: 30
                                                // base click zone UNDER the icon buttons
                                                MouseArea { id: wma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (modelData.active) { root.wifiDisconnect(modelData.ssid); return }
                                                        if (wrow.asking) { root.wifiPwFor = ""; return }
                                                        root.wifiConnect(modelData.ssid, modelData.secure)
                                                    } }
                                                RowLayout {
                                                    anchors.fill: parent; spacing: 9
                                                    readonly property bool saved: root.savedCons.indexOf(modelData.ssid) >= 0
                                                    Sym {
                                                        text: modelData.signal > 66 ? "signal_wifi_4_bar" : modelData.signal > 33 ? "network_wifi_3_bar" : "network_wifi_1_bar"
                                                        sz: 17; color: modelData.active ? theme.iris : theme.frost
                                                    }
                                                    Text { text: modelData.ssid; color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    Text { text: modelData.signal + "%"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                                    // forget (saved networks) — its own hitbox, sits above the row's click zone
                                                    Sym { visible: wma.containsMouse && parent.saved; text: "delete"; sz: 15; color: fgm.containsMouse ? theme.bad : theme.faint
                                                        MouseArea { id: fgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: root.wifiForget(modelData.ssid) } }
                                                    Sym { visible: modelData.active && wma.containsMouse; text: "link_off"; sz: 15; color: theme.bad }
                                                    Sym { text: "lock"; sz: 13; color: theme.faint; visible: modelData.secure && !wma.containsMouse }
                                                    Sym { text: "check"; sz: 15; color: theme.good; visible: modelData.active && !wma.containsMouse }
                                                }
                                            }
                                            // inline password row (secured networks)
                                            RowLayout {
                                                visible: wrow.asking; Layout.fillWidth: true; spacing: 8
                                                Rectangle {
                                                    Layout.fillWidth: true; implicitHeight: 28; radius: 7
                                                    color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                    TextInput { id: pwIn
                                                        anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                        verticalAlignment: TextInput.AlignVCenter
                                                        color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                                        echoMode: TextInput.Password; clip: true
                                                        Text { text: "password…"; visible: pwIn.text===""; color: theme.faint
                                                            font.pixelSize: 11; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                                        Keys.onReturnPressed: { root.wifiJoinPw(wrow.modelData.ssid, pwIn.text); pwIn.text = "" }
                                                        Keys.onEscapePressed: (e)=> { root.wifiPwFor = ""; pwIn.text = ""; e.accepted = true }
                                                    }
                                                }
                                                Rectangle { implicitWidth: 64; implicitHeight: 28; radius: 7
                                                    color: jbm.containsMouse ? theme.iris : theme.a(theme.iris, 0.25)
                                                    border.width: 1; border.color: theme.iris
                                                    Text { anchors.centerIn: parent; text: "join"; font.pixelSize: 11; font.family: "monospace"; font.bold: true
                                                        color: jbm.containsMouse ? theme.bg : theme.frost }
                                                    MouseArea { id: jbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { root.wifiJoinPw(wrow.modelData.ssid, pwIn.text); pwIn.text = "" } } }
                                            }
                                        }
                                    }
                                }
                                Text { visible: root.wifiList.length === 0; text: root.wifiRadio ? "scanning…" : "wi-fi is off"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                                // join a hidden network
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: root.hidOpen ? 78 : 34; radius: 8; clip: true
                                    Behavior on implicitHeight { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                                    color: theme.a(theme.line, 0.3); border.width: 1; border.color: root.hidOpen ? theme.iris : theme.a(theme.iris, 0.12)
                                    ColumnLayout {
                                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 4; anchors.bottomMargin: 6; spacing: 4
                                        Item {
                                            Layout.fillWidth: true; implicitHeight: 26
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.hidOpen = !root.hidOpen; if (root.hidOpen) hidSsid.forceActiveFocus() } }
                                            RowLayout { anchors.fill: parent; spacing: 9
                                                Sym { text: "visibility_off"; sz: 16; color: theme.frost }
                                                Text { text: "join a hidden network…"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.fillWidth: true }
                                                Sym { text: root.hidOpen ? "expand_less" : "expand_more"; sz: 16; color: theme.faint } }
                                        }
                                        RowLayout {
                                            visible: root.hidOpen; Layout.fillWidth: true; spacing: 8
                                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 7
                                                color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                TextInput { id: hidSsid; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                    verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: "monospace"; clip: true
                                                    Text { text: "ssid"; visible: hidSsid.text===""; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter } } }
                                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 7
                                                color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                TextInput { id: hidPw; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                    verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: "monospace"; echoMode: TextInput.Password; clip: true
                                                    Text { text: "password (blank if open)"; visible: hidPw.text===""; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                                    Keys.onReturnPressed: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text=""; hidPw.text="" } } }
                                            Rectangle { implicitWidth: 56; implicitHeight: 28; radius: 7
                                                color: hjm.containsMouse ? theme.iris : theme.a(theme.iris, 0.25); border.width: 1; border.color: theme.iris
                                                Text { anchors.centerIn: parent; text: "join"; font.pixelSize: 11; font.family: "monospace"; font.bold: true
                                                    color: hjm.containsMouse ? theme.bg : theme.frost }
                                                MouseArea { id: hjm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text=""; hidPw.text="" } } }
                                        }
                                    }
                                }
                                Text { visible: root.wifiMsg !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; text: root.wifiMsg
                                    color: root.wifiMsg.indexOf("✓") >= 0 ? theme.good : root.wifiMsg.indexOf("wrong") >= 0 ? theme.bad : theme.sub
                                    font.pixelSize: 11; font.family: "monospace" }
                                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; text: "click to connect / disconnect · the trash icon forgets a saved network · secured ones ask inline"
                                    color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.topMargin: 4 }
                            }
                        }

                        // ================= VPN =================
                        ColumnLayout {
                            visible: root.tab === 2; Layout.fillWidth: true; spacing: 10

                            // WARP header row
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "security"; sz: 18; color: root.warpConnected ? theme.good : theme.iris }
                                Text { text: "Cloudflare WARP"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                    color: root.warpConnected ? theme.a(theme.good, 0.4) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: root.warpConnected ? theme.good : theme.a(theme.line, 0.9)
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Rectangle { width: 16; height: 16; radius: 8; y: 3
                                        x: root.warpConnected ? parent.width - 19 : 3
                                        color: root.warpConnected ? theme.frost : theme.faint
                                        Behavior on x { NumberAnimation { duration: 130 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.warpToggle() } }
                            }

                            // WARP status + mode chips
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text { text: root.warpStatus; color: root.warpConnected ? theme.good : theme.faint
                                    font.pixelSize: 11; font.family: "monospace" }
                                Item { Layout.fillWidth: true }
                                Repeater { model: ["warp","doh","warp+doh","tunnel_only"]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.warpMode === modelData
                                        implicitHeight: 20; radius: 5; implicitWidth: wmt.implicitWidth + 14
                                        color: cur ? theme.a(theme.good, 0.25) : (wma2.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.3))
                                        border.width: cur ? 1 : 0; border.color: theme.a(theme.good, 0.45)
                                        Text { id: wmt; anchors.centerIn: parent; text: modelData
                                            color: cur ? theme.good : theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: cur }
                                        MouseArea { id: wma2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.warpSetMode(modelData) } } }
                            }

                            // VPN connections divider
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8; Layout.topMargin: 4
                                Sym { text: "vpn_key"; sz: 18; color: theme.iris }
                                Text { text: "VPN connections"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                            }

                            // saved VPN list
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text { visible: root.vpnList.length === 0; text: "no VPN profiles saved — import one below"
                                    color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                                Repeater {
                                    model: root.vpnList
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool connecting: modelData.state === "activating" || root.vpnActionName === modelData.name
                                        readonly property bool failed: root.vpnFailedName === modelData.name
                                        Layout.fillWidth: true; implicitHeight: 50; radius: 9
                                        color: modelData.active ? theme.a(theme.iris, 0.18) : (connecting ? theme.a(theme.frost, 0.08) : theme.a(theme.line, 0.35))
                                        border.width: 1; border.color: failed ? theme.bad : (modelData.active ? theme.a(theme.iris, 0.5) : (connecting ? theme.a(theme.frost, 0.3) : theme.a(theme.iris, 0.12)))
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                                            Sym { text: modelData.type==="wireguard" ? "cable" : "vpn_key"; sz: 17
                                                color: modelData.active ? theme.iris : (connecting ? theme.frost : (failed ? theme.bad : theme.faint)) }
                                            ColumnLayout { spacing: 2; Layout.fillWidth: true
                                                Text { text: modelData.name; color: modelData.active ? theme.text : (connecting ? theme.frost : (failed ? theme.bad : theme.sub))
                                                    font.pixelSize: 13; font.family: "monospace"; font.bold: modelData.active || connecting; elide: Text.ElideRight }
                                                Text {
                                                    text: connecting ? "connecting…" : (failed ? "connection failed — please try again" : (modelData.active ? "connected" : modelData.type))
                                                    color: connecting ? theme.frost : (failed ? theme.bad : (modelData.active ? theme.good : theme.faint))
                                                    font.pixelSize: 10; font.family: "monospace" } }
                                            Rectangle {
                                                implicitWidth: 104; implicitHeight: 30; radius: 7
                                                color: connecting ? theme.a(theme.line, 0.5) : (vtm.containsMouse ? (modelData.active ? theme.a(theme.bad,0.3) : theme.iris) : (modelData.active ? theme.a(theme.bad,0.15) : theme.a(theme.iris,0.2)))
                                                border.width: 1; border.color: connecting ? theme.a(theme.line, 0.7) : (modelData.active ? theme.bad : theme.iris)
                                                Behavior on color { ColorAnimation { duration: 110 } }
                                                Text { anchors.centerIn: parent
                                                    text: connecting ? "connecting…" : (modelData.active ? "disconnect" : "connect")
                                                    color: connecting ? theme.faint : (vtm.containsMouse ? (modelData.active ? theme.bad : theme.bg) : (modelData.active ? theme.bad : theme.frost))
                                                    font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                                MouseArea { id: vtm; anchors.fill: parent; hoverEnabled: true; cursorShape: connecting ? Qt.ArrowCursor : Qt.PointingHandCursor
                                                    onClicked: if (!connecting) root.vpnToggle(modelData.name) } }
                                            Rectangle {
                                                implicitWidth: 32; implicitHeight: 30; radius: 7
                                                color: vdm.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"
                                                Sym { anchors.centerIn: parent; text: "delete"; sz: 16
                                                    color: vdm.containsMouse ? theme.bad : theme.faint }
                                                MouseArea { id: vdm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.vpnDelete(modelData.name) } }
                                        }
                                    }
                                }
                            }

                            // add VPN expandable panel
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: root.vpnAddOpen ? vpnAddInner.implicitHeight + 20 : 42
                                radius: 9; clip: true
                                Behavior on implicitHeight { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                color: theme.a(theme.line, 0.3)
                                border.width: 1; border.color: root.vpnAddOpen ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.12)

                                ColumnLayout {
                                    id: vpnAddInner
                                    anchors { fill: parent; leftMargin: 14; rightMargin: 14; topMargin: 8; bottomMargin: 8 }
                                    spacing: 10

                                    // toggle header
                                    MouseArea { Layout.fillWidth: true; implicitHeight: 26; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.vpnAddOpen = !root.vpnAddOpen
                                        RowLayout { anchors.fill: parent; spacing: 8
                                            Sym { text: "add_circle"; sz: 17; color: theme.frost }
                                            Text { text: "import VPN profile"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.fillWidth: true }
                                            Sym { text: root.vpnAddOpen ? "expand_less" : "expand_more"; sz: 17; color: theme.faint } } }

                                    // type chips
                                    RowLayout {
                                        visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                                        Repeater { model: [{l:"WireGuard (.conf)",v:0},{l:"OpenVPN (.ovpn)",v:1}]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool sel: root.vpnAddMode === modelData.v
                                                Layout.fillWidth: true; implicitHeight: 32; radius: 7
                                                color: sel ? theme.a(theme.iris,0.25) : (atm2.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.35))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.15)
                                                Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.text : theme.sub
                                                    font.pixelSize: 11; font.family: "monospace"; font.bold: sel }
                                                MouseArea { id: atm2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.vpnAddMode = modelData.v } } }
                                    }

                                    // file path + import button
                                    RowLayout {
                                        visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                            color: theme.a(theme.bg, 0.8); border.width: 1
                                            border.color: vpnPathIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.25)
                                            TextInput {
                                                id: vpnPathIn
                                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 12; font.family: "monospace"; clip: true
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: vpnPathIn.text === ""
                                                    text: root.vpnAddMode === 0 ? "~/path/to/tunnel.conf" : "~/path/to/config.ovpn"
                                                    color: theme.faint; font.pixelSize: 12; font.family: "monospace" }
                                                Keys.onReturnPressed: {
                                                    if (root.vpnAddMode === 0) root.vpnAddWireguard(vpnPathIn.text);
                                                    else root.vpnAddOpenVPN(vpnPathIn.text);
                                                    vpnPathIn.text = ""; root.vpnAddOpen = false; } } }
                                        Rectangle {
                                            implicitWidth: 36; implicitHeight: 34; radius: 8
                                            color: vpnBrowseMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                                            border.width: 1; border.color: theme.a(theme.iris, 0.25)
                                            Sym { anchors.centerIn: parent; text: "folder_open"; sz: 16; color: theme.frost }
                                            MouseArea {
                                                id: vpnBrowseMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    var filter = root.vpnAddMode === 0 ? "WireGuard (*.conf) | *.conf" : "OpenVPN (*.ovpn) | *.ovpn";
                                                    root.pickFile(root.vpnAddMode === 0 ? "Select WireGuard Configuration" : "Select OpenVPN Configuration", filter, function(path) {
                                                        vpnPathIn.text = path;
                                                    }); } } }
                                        Rectangle {
                                            implicitWidth: 80; implicitHeight: 34; radius: 8
                                            color: viam.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                            border.width: 1; border.color: theme.iris
                                            RowLayout { anchors.centerIn: parent; spacing: 5
                                                Sym { text: "upload_file"; sz: 14; color: viam.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "import"; color: viam.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                            MouseArea { id: viam; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (root.vpnAddMode === 0) root.vpnAddWireguard(vpnPathIn.text);
                                                    else root.vpnAddOpenVPN(vpnPathIn.text);
                                                    vpnPathIn.text = ""; root.vpnAddOpen = false; } } }
                                    }

                                    // hint
                                    Text { visible: root.vpnAddOpen; Layout.fillWidth: true; wrapMode: Text.Wrap
                                        text: root.vpnAddMode === 0
                                            ? "paste the path to a WireGuard .conf file — the profile name is taken from the filename. get a .conf from your VPN provider or export from your router."
                                            : "paste the path to an OpenVPN .ovpn file — username/password will be prompted on first connect if required."
                                        color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                }
                            }

                            // status message
                            Text { visible: root.vpnMsg !== ""; text: root.vpnMsg
                                color: root.vpnMsg.indexOf("fail") >= 0 || root.vpnMsg.indexOf("fail") >= 0 ? theme.bad : theme.sub
                                font.pixelSize: 11; font.family: "monospace"; Layout.fillWidth: true; wrapMode: Text.Wrap }
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

                            // segmented horizontal navigation bar for Appearance sub-menus
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6; Layout.bottomMargin: 8
                                Repeater {
                                    model: [
                                        { i: "settings_system_daydream", l: "bar theme" },
                                        { i: "palette", l: "colors" },
                                        { i: "tune", l: "targets" },
                                        { i: "font_download", l: "fonts" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData; required property int index
                                        readonly property bool sel: root.apSubTab === index
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: sel ? theme.iris : (subMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                        RowLayout {
                                            anchors.centerIn: parent; spacing: 6
                                            Sym { text: modelData.i; sz: 14; color: sel ? theme.bg : theme.frost }
                                            Text { text: modelData.l; color: sel ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                        }
                                        MouseArea { id: subMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.apSubTab = index }
                                    }
                                }
                            }

                            // SUB-TAB 0: Bar Theme
                            ColumnLayout {
                                visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 14
                                Section { title: "theme"; icon: "contrast" }
                                RowLayout { Layout.fillWidth: true; spacing: 8
                                    Repeater { model: [{k:false,l:"Dark",i:"dark_mode"},{k:true,l:"Light",i:"light_mode"}]
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apLight===modelData.k
                                            Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                            color: sel?theme.iris:(thmMa.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 7
                                                Sym { text: modelData.i; sz: 17; color: sel?theme.bg:theme.frost }
                                                Text { text: modelData.l; color: sel?theme.bg:theme.text; font.pixelSize: 13; font.family: root.apFont; font.bold: sel } }
                                            MouseArea { id: thmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apLight=modelData.k; root.saveAppearance() } } } } }
                                // auto dark mode by time of day
                                Rectangle { Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                    color: theme.a(theme.line,0.4); border.width: 1; border.color: root.apAutoDark?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                        Sym { text: "bedtime"; sz: 18; color: root.apAutoDark?theme.frost:theme.faint }
                                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                                            Text { text: "auto dark by time"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                            Text { text: "dark inside the window · overrides the manual pick + the SUPER+⇧+D key"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                            color: root.apAutoDark?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.apAutoDark?theme.iris:theme.a(theme.iris,0.3)
                                            Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.apAutoDark?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAutoDark=!root.apAutoDark; root.saveAppearance() } } } } }
                                RowLayout { Layout.fillWidth: true; spacing: 10; visible: root.apAutoDark
                                    Sym { text: "schedule"; sz: 18 }
                                    Text { text: "dark from"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: 8; color: theme.a(theme.line,0.5); border.width: 1; border.color: dstart.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dstart; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: root.apFont; inputMask: "99:99;_"; text: root.apDarkStart
                                            onEditingFinished: { root.apDarkStart = text; root.saveAppearance() } } }
                                    Text { text: "to"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: 8; color: theme.a(theme.line,0.5); border.width: 1; border.color: dend.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dend; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: root.apFont; inputMask: "99:99;_"; text: root.apDarkEnd
                                            onEditingFinished: { root.apDarkEnd = text; root.saveAppearance() } } }
                                    Item { Layout.fillWidth: true } }
                                // system app dark/light preference — independent from shell theme
                                Section { title: "app preference"; icon: "apps" }
                                Text { text: "controls GTK / Qt app themes independently from the shell"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont }
                                RowLayout { Layout.fillWidth: true; spacing: 8
                                    Repeater { model: [{k:"auto",l:"Auto",i:"sync"},{k:"dark",l:"Dark",i:"dark_mode"},{k:"light",l:"Light",i:"light_mode"}]
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAppMode===modelData.k
                                            Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                            color: sel?theme.iris:(amMa.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 7
                                                Sym { text: modelData.i; sz: 17; color: sel?theme.bg:theme.frost }
                                                Text { text: modelData.l; color: sel?theme.bg:theme.text; font.pixelSize: 13; font.family: root.apFont; font.bold: sel } }
                                            MouseArea { id: amMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAppMode=modelData.k; root.saveAppearance(); root.applyAppMode() } } } } }
                                Text { visible: root.apAppMode!=="auto"; text: "apps will stay " + root.apAppMode + " regardless of shell theme"; color: theme.iris; font.pixelSize: 10; font.family: root.apFont }
                                Section { title: "bar shape"; icon: "tune" }
                                // roundness
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "rounded_corner"; sz: 20 }
                                    Text { text: "roundness"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                    Slider { value: root.apRadius/26; onMoved: (v)=>{ root.apRadius = v*26; root.saveAppearance() } }
                                    Text { text: Math.round(root.apRadius)+"px"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }
                                // bar position — which screen edge the bar docks to (left/right = vertical bar)
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "dock_to_right"; sz: 20 }
                                    Text { text: "position"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                    RowLayout { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: root.edges
                                            delegate: Rectangle { required property var modelData
                                                readonly property bool sel: root.apEdge===modelData
                                                Layout.fillWidth: true; implicitHeight: 30; radius: 8
                                                color: sel ? theme.iris : (edMa.containsMouse ? theme.a(theme.iris,0.16) : theme.a(theme.line,0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.14)
                                                Text { anchors.centerIn: parent; text: modelData; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: "monospace"; font.bold: sel }
                                                MouseArea { id: edMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apEdge=modelData; root.saveAppearance() } } } } } }
                                // transparency — 0% leaves only the pill buttons floating
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "opacity"; sz: 20 }
                                    Text { text: "opacity"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                    Slider { fill: theme.frost; value: root.apOpacity; onMoved: (v)=>{ root.apOpacity = v; root.saveAppearance() } }
                                    Text { text: Math.round(root.apOpacity*100)+"%"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }
                                Text { visible: root.apOpacity < 0.06
                                    text: "↑ 0% hides the bar background — only the buttons show"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true }
                                // bar fill — a clean solid black/white, or the matugen accent tint (most obvious at 100% opacity)
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "format_color_fill"; sz: 20 }
                                    Text { text: "bar fill"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                    RowLayout { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: [{k:"matugen",l:"matugen"},{k:"black",l:"black"},{k:"white",l:"white"}]
                                            delegate: Rectangle { required property var modelData
                                                readonly property bool sel: root.apBarFill===modelData.k
                                                Layout.fillWidth: true; implicitHeight: 30; radius: 8
                                                color: sel ? theme.iris : (bfMa.containsMouse ? theme.a(theme.iris,0.16) : theme.a(theme.line,0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.14)
                                                Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: "monospace"; font.bold: sel }
                                                MouseArea { id: bfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apBarFill=modelData.k; root.saveAppearance() } } } } } }
                                Text { visible: root.apBarFill!=="matugen" && root.apOpacity<0.99
                                    text: "↑ set opacity to 100% for a solid " + root.apBarFill + " bar"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true }
                                // height
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "height"; sz: 20 }
                                    Text { text: "bar height"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 82 }
                                    Slider { fill: theme.good; value: (root.apHeight-34)/20; onMoved: (v)=>{ root.apHeight = 34 + v*20; root.saveAppearance() } }
                                    Text { text: Math.round(root.apHeight)+"px"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight } }
                            }

                            // SUB-TAB 1: Colors
                            ColumnLayout {
                                visible: root.apSubTab === 1; Layout.fillWidth: true; spacing: 14
                                Section { title: "accent colour"; icon: "palette" }
                                Flow { Layout.fillWidth: true; spacing: 10
                                    Repeater { model: root.accents
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                            width: 40; height: 40; radius: 20; color: modelData
                                            border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                            Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 20; color: "#0d1420" }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAccent=modelData; root.saveAppearance(); run("sh '"+root.matugenScript+"'") } } } } }
                                // matugen AUTO — persisted; recolours the whole shell + kitty from the wallpaper (off = sea cyan)
                                Rectangle { Layout.fillWidth: true; implicitHeight: 48; radius: 9
                                    color: theme.a(theme.line,0.4); border.width: 1; border.color: root.apMatugen?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                        Sym { text: "colorize"; sz: 18; color: root.apMatugen?theme.frost:theme.faint }
                                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                                            Text { text: "auto colours from wallpaper"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                            Text { text: "recolours the shell + kitty on every wallpaper · off = sea cyan"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                            color: root.apMatugen?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.apMatugen?theme.iris:theme.a(theme.iris,0.3)
                                            Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.apMatugen?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleMatugen() } } } }
                                // matugen scheme — which Material You algorithm builds the palette (only shown when auto is on)
                                ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: root.apMatugen
                                    RowLayout { Layout.fillWidth: true; spacing: 6
                                        Sym { text: "tune"; sz: 15; color: theme.faint }
                                        Text { text: "colour scheme"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont }
                                        Item { Layout.fillWidth: true }
                                        Text { text: root.apScheme.replace("scheme-",""); color: theme.frost; font.pixelSize: 11; font.family: root.apFont } }
                                    Flow { Layout.fillWidth: true; spacing: 7
                                        Repeater { model: root.schemes
                                            delegate: Rectangle { required property var modelData
                                                readonly property bool sel: root.apScheme===modelData
                                                implicitWidth: scTxt.implicitWidth + 20; implicitHeight: 30; radius: 8
                                                color: sel ? theme.iris : (scMa.containsMouse ? theme.a(theme.iris,0.16) : theme.a(theme.line,0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.14)
                                                Text { id: scTxt; anchors.centerIn: parent; text: (""+modelData).replace("scheme-",""); color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setScheme(modelData) } } } } }
                                // matugen — one-off: derive a palette from the wallpaper or pick with eyedropper
                                RowLayout { Layout.fillWidth: true; spacing: 8
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 40; radius: 9
                                        color: mgm.containsMouse ? theme.iris : theme.a(theme.iris,0.18); border.width: 1; border.color: theme.iris
                                        RowLayout { anchors.centerIn: parent; spacing: 8
                                            Sym { text: root.matugenBusy?"sync":"auto_awesome"; sz: 17; color: mgm.containsMouse?theme.bg:theme.frost }
                                            Text { text: root.matugenBusy ? "matching…" : "pick a palette from wallpaper"; color: mgm.containsMouse?theme.bg:theme.text; font.pixelSize: 12; font.family: root.apFont } }
                                        MouseArea { id: mgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.matchWallpaper() } }
                                    Rectangle { implicitWidth: 100; implicitHeight: 40; radius: 9
                                        color: edm.containsMouse ? theme.iris : theme.a(theme.iris,0.18); border.width: 1; border.color: theme.iris
                                        RowLayout { anchors.centerIn: parent; spacing: 6
                                            Sym { text: "colorize"; sz: 17; color: edm.containsMouse?theme.bg:theme.frost }
                                            Text { text: "picker"; color: edm.containsMouse?theme.bg:theme.text; font.pixelSize: 12; font.family: root.apFont } }
                                        MouseArea { id: edm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "accent"; colorPickerProc.running = true } } } }
                                // extracted palette — pick any colour
                                Flow { Layout.fillWidth: true; spacing: 9; visible: root.matugenPalette.length>0
                                    Repeater { model: root.matugenPalette
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                            width: 36; height: 36; radius: 18; color: modelData
                                            border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                            Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 18; color: "#0d1420" }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAccent=modelData; root.saveAppearance(); run("sh '"+root.matugenScript+"'") } } } } }
                            }

                            // SUB-TAB 2: Custom Targets Overrides
                            ColumnLayout {
                                visible: root.apSubTab === 2; Layout.fillWidth: true; spacing: 14
                                // ---------- per-target colour overrides ----------
                                ColumnLayout { Layout.fillWidth: true; spacing: 8
                                    Section { title: "colour targets"; icon: "tune" }
                                    Text { text: "customize which apps auto-match wallpaper/global accent · disabled auto-match targets can use custom colors"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont }
                                    // Hyprland borders
                                    Rectangle { Layout.fillWidth: true; implicitHeight: hyprCol.implicitHeight + 20; radius: 9
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrHyprland?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: hyprCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "border_style"; sz: 18; color: root.ovrHyprland?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "hyprland borders"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "window active/inactive border colours"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                                    color: root.ovrHyprland?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrHyprland?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.ovrHyprland?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprland=!root.ovrHyprland; root.toggleOverride("hyprland") } } } }
                                            // custom border colours (only visible when auto-match is OFF)
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrHyprland
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "active"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrHyprActive || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: haIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: haIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrHyprActive
                                                            onEditingFinished: { root.ovrHyprActive=text.trim(); root.toggleOverride("hyprland") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !haIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: haEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: haEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprActive"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprActive = modelData; root.toggleOverride("hyprland") } } } } }
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "inactive"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrHyprInactive || theme.a(root.apAccent,0.4); border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: hiIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: hiIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrHyprInactive
                                                            onEditingFinished: { root.ovrHyprInactive=text.trim(); root.toggleOverride("hyprland") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !hiIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: hiEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: hiEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprInactive"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprInactive = modelData; root.toggleOverride("hyprland") } } } } } } } }
                                    // Kitty terminal
                                    Rectangle { Layout.fillWidth: true; implicitHeight: kittyCol.implicitHeight + 20; radius: 9
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrKitty?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: kittyCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "terminal"; sz: 18; color: root.ovrKitty?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "kitty terminal"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "terminal colour palette and background"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                                    color: root.ovrKitty?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrKitty?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.ovrKitty?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKitty=!root.ovrKitty; root.toggleOverride("kitty") } } } }
                                            // custom kitty colors
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrKitty
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrKittyAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: kaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: kaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrKittyAccent
                                                            onEditingFinished: { root.ovrKittyAccent=text.trim(); root.toggleOverride("kitty") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !kaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: kaEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: kaEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyAccent"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyAccent = modelData; root.toggleOverride("kitty") } } } } }
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "bg"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrKittyBg || "#171729"; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: kbIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: kbIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrKittyBg
                                                            onEditingFinished: { root.ovrKittyBg=text.trim(); root.toggleOverride("kitty") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !kbIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: kbEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: kbEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyBg"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: ["#0f141d","#171729","#1a1b26","#1e1e2e","#282828","#000000"].concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyBg = modelData; root.toggleOverride("kitty") } } } } } } } }
                                    // Fastfetch
                                    Rectangle { Layout.fillWidth: true; implicitHeight: ffCol.implicitHeight + 20; radius: 9
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrFastfetch?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: ffCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "info"; sz: 18; color: root.ovrFastfetch?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "fastfetch"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "system info key + logo accent colour"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                                    color: root.ovrFastfetch?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrFastfetch?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.ovrFastfetch?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetch=!root.ovrFastfetch; root.toggleOverride("fastfetch") } } } }
                                            // custom fastfetch accent
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrFastfetch
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrFastfetchAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: ffaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: ffaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrFastfetchAccent
                                                            onEditingFinished: { root.ovrFastfetchAccent=text.trim(); root.toggleOverride("fastfetch") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !ffaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: ffEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: ffEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "fastfetch"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetchAccent = modelData; root.toggleOverride("fastfetch") } } } } } } } }
                                    // Starship prompt
                                    Rectangle { Layout.fillWidth: true; implicitHeight: ssCol.implicitHeight + 20; radius: 9
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrStarship?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: ssCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "star"; sz: 18; color: root.ovrStarship?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "starship prompt"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "terminal prompt accent colours"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                                    color: root.ovrStarship?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrStarship?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.ovrStarship?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrStarship=!root.ovrStarship; root.toggleOverride("starship") } } } }
                                            // custom starship accent
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrStarship
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: 4; color: root.ovrStarshipAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: 6; color: theme.a(theme.line,0.5); border.width: 1; border.color: ssaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: ssaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; clip: true; selectByMouse: true; text: root.ovrStarshipAccent
                                                            onEditingFinished: { root.ovrStarshipAccent=text.trim(); root.toggleOverride("starship") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !ssaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 6
                                                        color: ssEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: ssEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "starship"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: 8; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrStarshipAccent = modelData; root.toggleOverride("starship") } } } } } } } }
                                }
                            }

                            // SUB-TAB 3: Fonts
                            ColumnLayout {
                                visible: root.apSubTab === 3; Layout.fillWidth: true; spacing: 14
                                Section { title: "font"; icon: "font_download" }
                                Flow { Layout.fillWidth: true; spacing: 7
                                    Repeater { model: root.fontPresets
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apFont===modelData
                                            implicitWidth: ft.implicitWidth+20; implicitHeight: 32; radius: 8
                                            color: sel?theme.iris:(fmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                            Text { id: ft; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: modelData; font.bold: sel }
                                            MouseArea { id: fmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apFont=modelData; root.saveAppearance() } } } } }
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
                        }

                        // ================= BAR WIDGETS =================
                        ColumnLayout {
                            visible: root.tab === 12; Layout.fillWidth: true; spacing: 14
                            Section { title: "bar widgets"; icon: "widgets" }
                            Text {
                                text: "toggle which widgets are displayed on the top-bar. Hidden widgets release layout space instantly."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: [
                                        { prop: "wgMpris",     i: "play_circle",            l: "Media Player",             d: "Shows current track info and playback controls in the bar center" },
                                        { prop: "wgTray",      i: "grid_view",              l: "System Tray",              d: "Collapsible area for background app status notifier icons" },
                                        { prop: "wgWeather",   i: "cloud",                  l: "Weather",                  d: "Displays current temperature and weather conditions" },
                                        { prop: "wgClipboard", i: "content_paste",          l: "Clipboard Manager",        d: "Quick access button to clipboard history search popup" },
                                        { prop: "wgNotif",     i: "notifications",          l: "Notification Bell",        d: "Displays a badge with unread notification count" },
                                        { prop: "wgWifi",      i: "wifi",                   l: "Wi-Fi Connection",        d: "Displays network status and wireless signal strength" },
                                        { prop: "wgBluetooth", i: "bluetooth",              l: "Bluetooth Status",         d: "Displays adapter status and toggles connected devices list" },
                                        { prop: "wgCaffeine",  i: "coffee",                 l: "Caffeine / Caffeine Lock", d: "Prevents screen dimming and automatic suspension" },
                                        { prop: "wgSystem",    i: "speed",                  l: "System Monitor",           d: "Displays live CPU usage and system load metric" },
                                        { prop: "wgVolume",    i: "volume_up",              l: "Volume Control",           d: "Displays sound volume level and output selector" },
                                        { prop: "wgBattery",   i: "battery_charging_full",  l: "Battery Status",           d: "Monitors remaining power levels for laptops" },
                                        { prop: "wgClock",     i: "schedule",               l: "Clock & Calendar",         d: "Shows current date and time with upcoming calendar events" },
                                        { prop: "wgPower",     i: "power_settings_new",     l: "Power Actions",            d: "Power icon for locking, logging out, restarting, or shutting down" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool enabledVal: root[modelData.prop]
                                        Layout.fillWidth: true; implicitHeight: 52; radius: 9
                                        color: theme.a(theme.line, 0.4); border.width: 1; border.color: enabledVal ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.16)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                                            Sym { text: modelData.i; sz: 19; color: enabledVal ? theme.frost : theme.faint }
                                            ColumnLayout {
                                                spacing: 1; Layout.fillWidth: true
                                                Text { text: modelData.l; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                Text { text: modelData.d; color: theme.faint; font.pixelSize: 10; font.family: root.apFont }
                                            }
                                            Rectangle {
                                                implicitWidth: 46; implicitHeight: 22; radius: 11
                                                color: enabledVal ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: enabledVal ? theme.iris : theme.a(theme.iris, 0.3)
                                                Rectangle {
                                                    width: 16; height: 16; radius: 8; y: 3; x: enabledVal ? 27 : 3
                                                    color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        root[modelData.prop] = !enabledVal;
                                                        root.saveAppearance();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ================= THEME PROFILES =================
                        ColumnLayout {
                            visible: root.tab === 13; Layout.fillWidth: true; spacing: 14
                            Section { title: "theme profiles & presets"; icon: "auto_awesome" }
                            Text {
                                text: "save your active layout configuration as a custom preset, or load an existing preset profile."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
                            }
                            
                            // Save section
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 36; radius: 7
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: profNameIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    TextInput {
                                        id: profNameIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 12; font.family: root.apFont
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: !profNameIn.text; text: "Enter preset name..."; color: theme.faint; font.pixelSize: 12 }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 120; implicitHeight: 36; radius: 7
                                    color: savePrMa.containsMouse ? theme.iris : theme.a(theme.line, 0.6)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    Text { anchors.centerIn: parent; text: "Save Preset"; color: savePrMa.containsMouse ? theme.bg : theme.frost; font.pixelSize: 11; font.bold: true; font.family: root.apFont }
                                    MouseArea {
                                        id: savePrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (profNameIn.text.trim() !== "") {
                                                root.saveProfile(profNameIn.text);
                                                profNameIn.text = "";
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Saved Profiles List
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                visible: root.profilesList.length > 0
                                Text { text: "SAVED PRESETS"; color: theme.faint; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1; Layout.topMargin: 10 }
                                
                                Repeater {
                                    model: root.profilesList
                                    delegate: Rectangle {
                                        required property var modelData
                                        required property int index
                                        Layout.fillWidth: true; implicitHeight: 52; radius: 9
                                        color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                                            Sym { text: "palette"; sz: 19; color: theme.frost }
                                            ColumnLayout {
                                                spacing: 1; Layout.fillWidth: true
                                                Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.bold: true; font.family: root.apFont }
                                                Text {
                                                    text: "font: " + modelData.font + " · radius: " + modelData.radius + "px · accent: " + modelData.accent
                                                    color: theme.faint; font.pixelSize: 10; font.family: root.apFont
                                                }
                                            }
                                            
                                            // Apply Preset
                                            Rectangle {
                                                implicitWidth: 80; implicitHeight: 28; radius: 6
                                                color: applyMa.containsMouse ? theme.iris : theme.a(theme.line, 0.6)
                                                Text { anchors.centerIn: parent; text: "Load"; color: applyMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont }
                                                MouseArea {
                                                    id: applyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.loadProfile(modelData)
                                                }
                                            }
                                            
                                            // Delete Preset
                                            Rectangle {
                                                implicitWidth: 32; implicitHeight: 28; radius: 6
                                                color: delPrMa.containsMouse ? theme.bad : theme.a(theme.line, 0.6)
                                                Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: delPrMa.containsMouse ? theme.bg : theme.faint }
                                                MouseArea {
                                                    id: delPrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteProfile(index)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Placeholder
                            Text {
                                text: "no presets saved yet."
                                visible: root.profilesList.length === 0
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.topMargin: 20; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                            }
                        }

                        // ================= ACTIONS =================
                        ColumnLayout {
                            visible: root.tab === 5; Layout.fillWidth: true; spacing: 14
                            Section { title: "quick actions"; icon: "bolt" }
                            GridLayout {
                                columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
                                Row2 { icon: "refresh"; label: "Reload Hyprland"; cmd: "hyprctl reload"; quitAfter: true }
                                Row2 { icon: "restart_alt"; label: "Restart bar"; cmd: "pkill -xf 'qs -c sea-shell'; sleep 0.3; hyprctl dispatch exec 'qs -c sea-shell'"; quitAfter: true }
                                Row2 { icon: "terminal"; label: "Terminal"; cmd: "kitty & disown"; quitAfter: true }
                                Row2 { icon: "wallpaper"; label: "Wallpapers"; cmd: "qs -p " + root.repo + "/wallpaper.qml & disown"; quitAfter: true }
                                Row2 { icon: "content_paste"; label: "Clipboard history"; cmd: "qs -c sea-shell ipc call launcher clipboard"; quitAfter: true }
                                Row2 { icon: "photo_camera"; label: "Screenshot region"; cmd: "sleep 0.2; grim -g \"$(slurp)\" - | wl-copy"; quitAfter: true }
                                Row2 { icon: "keyboard"; label: "Keybinds editor"; cmd: "qs -p " + root.repo + "/keybinds.qml & disown"; quitAfter: true }
                                Row2 { icon: "edit_note"; label: "Edit keybinds"; cmd: "xdg-open \"$(dirname \"$(readlink -f ~/.config/quickshell/sea-shell)\")/hypr/keybinds.conf\" & disown"; quitAfter: true }
                                Row2 { icon: "settings"; label: "Edit configs"; cmd: "kitty --directory " + root.repo + "/.. & disown"; quitAfter: true }
                            }
                        }

                        // ================= KEYBINDS =================
                        ColumnLayout {
                            visible: root.tab === 7; Layout.fillWidth: true; spacing: 10
                            Section { title: "keybinds"; icon: "keyboard" }
                            // search
                            RowLayout {
                                spacing: 10; Layout.fillWidth: true
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
                                            if (e.key === Qt.Key_Escape) {
                                                if (root.kbRec) { root.kbRec = null; root.kbConflict = "" }
                                                else if (root.kbAddRecording) { root.kbAddRecording = false }
                                                else if (root.kbAdding) { root.kbAdding = false }
                                                else root.closePanel();
                                                e.accepted = true;
                                                return;
                                            }
                                            if (root.kbRec) {
                                                if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                                var n = root.kbKeyName(e);
                                                if (n) root.kbApply(n); else root.kbConflict = "unsupported key";
                                                e.accepted = true;
                                                return;
                                            }
                                            if (root.kbAddRecording) {
                                                if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                                var k = root.kbKeyName(e);
                                                if (k) { root.kbAddKey = k; root.kbAddRecording = false }
                                                e.accepted = true;
                                            }
                                        }
                                    }
                                }
                                // Add Button
                                Rectangle {
                                    implicitWidth: 32; implicitHeight: 32; radius: 8
                                    color: kbAddBtnMa.containsMouse ? theme.iris : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.2)
                                    Sym { anchors.centerIn: parent; text: "add"; sz: 18; color: kbAddBtnMa.containsMouse ? theme.bg : theme.frost }
                                    MouseArea {
                                        id: kbAddBtnMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.kbAdding = !root.kbAdding; root.kbAddRecording = false; kbField.forceActiveFocus() }
                                    }
                                }
                            }

                            // ================= ADD BIND PANEL =================
                            Rectangle {
                                visible: root.kbAdding
                                Layout.fillWidth: true
                                implicitHeight: kbAddFormCol.implicitHeight + 20
                                radius: 10
                                color: theme.a(theme.line, 0.2)
                                border.width: 1; border.color: theme.a(theme.iris, 0.2)
                                ColumnLayout {
                                    id: kbAddFormCol
                                    anchors.fill: parent; anchors.margins: 14; spacing: 12
                                    
                                    // Description
                                    ColumnLayout {
                                        spacing: 4; Layout.fillWidth: true
                                        Text { text: "description"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 32; radius: 6
                                            color: theme.a(theme.line, 0.4); border.width: 1
                                            border.color: kbDescIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.1)
                                            TextInput {
                                                id: kbDescIn
                                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                                text: root.kbAddDesc
                                                onTextChanged: root.kbAddDesc = text
                                                Text { text: "e.g. Launch Firefox"; visible: kbDescIn.text===""; color: theme.faint; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                            }
                                        }
                                    }
                                    
                                    // Action / Command
                                    ColumnLayout {
                                        spacing: 4; Layout.fillWidth: true
                                        Text { text: "action / command"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 32; radius: 6
                                            color: theme.a(theme.line, 0.4); border.width: 1
                                            border.color: kbActionIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.1)
                                            TextInput {
                                                id: kbActionIn
                                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                                text: root.kbAddAction
                                                onTextChanged: root.kbAddAction = text
                                            }
                                        }
                                    }

                                    // Shortcut combination
                                    ColumnLayout {
                                        spacing: 4; Layout.fillWidth: true
                                        Text { text: "shortcut combination"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                        RowLayout {
                                            spacing: 10; Layout.fillWidth: true
                                            // Modifier chips
                                            Row {
                                                spacing: 6
                                                Repeater {
                                                    model: ["SUPER","CTRL","ALT","SHIFT"]
                                                    delegate: Rectangle {
                                                        required property string modelData
                                                        readonly property bool on: root.kbAddMods.indexOf(modelData) >= 0
                                                        width: kamc.width + 14; height: 22; radius: 11
                                                        color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5)
                                                        border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                                        Text { id: kamc; anchors.centerIn: parent; text: modelData
                                                            color: on ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace"; font.bold: on }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: { var m = root.kbAddMods.slice(); var i = m.indexOf(modelData);
                                                                if (i >= 0) m.splice(i,1); else m.push(modelData);
                                                                root.kbAddMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x => m.indexOf(x) >= 0);
                                                                kbField.forceActiveFocus() } }
                                                    }
                                                }
                                            }
                                            
                                            Text { text: "+"; color: theme.faint; font.pixelSize: 12; font.family: "monospace" }

                                            // Key capture button
                                            Rectangle {
                                                implicitWidth: 120; implicitHeight: 24; radius: 6
                                                color: root.kbAddRecording ? theme.a(theme.bad, 0.2) : theme.a(theme.line, 0.4)
                                                border.width: 1; border.color: root.kbAddRecording ? theme.bad : theme.a(theme.iris, 0.3)
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.kbAddRecording ? "press key…" : (root.kbAddKey ? root.kbAddKey : "set key combo")
                                                    color: root.kbAddRecording ? theme.bad : theme.frost
                                                    font.pixelSize: 11; font.family: "monospace"; font.bold: true
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.kbAddRecording = true; kbField.forceActiveFocus() }
                                                }
                                            }
                                            Item { Layout.fillWidth: true }
                                        }
                                    }
                                    
                                    // Control buttons (Save / Cancel)
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 10; Layout.topMargin: 4
                                        Item { Layout.fillWidth: true }
                                        
                                        // Cancel button
                                        Rectangle {
                                            implicitWidth: 70; implicitHeight: 28; radius: 6
                                            color: kbcancelBtnMa.containsMouse ? theme.a(theme.bad, 0.15) : "transparent"
                                            border.width: 1; border.color: kbcancelBtnMa.containsMouse ? theme.bad : theme.a(theme.line, 0.5)
                                            Text { anchors.centerIn: parent; text: "Cancel"; color: kbcancelBtnMa.containsMouse ? theme.bad : theme.text; font.pixelSize: 11; font.family: "monospace" }
                                            MouseArea {
                                                id: kbcancelBtnMa
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.kbAdding = false; root.kbAddRecording = false; kbField.forceActiveFocus() }
                                            }
                                        }
                                        
                                        // Save button
                                        Rectangle {
                                            readonly property bool valid: root.kbAddDesc.trim() !== "" && root.kbAddKey !== "" && root.kbAddAction.trim() !== ""
                                            implicitWidth: 90; implicitHeight: 28; radius: 6
                                            color: valid ? (kbsaveBtnMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)) : theme.a(theme.line, 0.2)
                                            border.width: 1; border.color: valid ? theme.iris : theme.a(theme.line, 0.5)
                                            Text { anchors.centerIn: parent; text: "Save Bind"; color: parent.valid ? (kbsaveBtnMa.containsMouse ? theme.bg : theme.text) : theme.faint; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                            MouseArea {
                                                id: kbsaveBtnMa
                                                anchors.fill: parent; enabled: parent.valid; cursorShape: parent.valid ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: root.kbApplyAddBind()
                                            }
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
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.kbShown.length + "/" + root.kbBinds.length + " binds · rebinds rewrite keybinds.conf + reload hyprland"
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                        }

                        // ================= SYSTEM =================
                        // ================= SYSTEM / ABOUT =================
                        ColumnLayout {
                            visible: root.tab === 8; Layout.fillWidth: true; spacing: 12

                            // ---- hero: brand · version · host ----
                            Rectangle {
                                Layout.fillWidth: true; radius: 16; implicitHeight: 90
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: theme.a(theme.iris, 0.17) }
                                    GradientStop { position: 1.0; color: theme.a(theme.line, 0.20) }
                                }
                                border.width: 1; border.color: theme.a(theme.iris, 0.22)
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 18
                                    SeaLogo { size: 62; card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                                    ColumnLayout {
                                        spacing: 4; Layout.fillWidth: true
                                        RowLayout { spacing: 9
                                            Text { text: "sea-shell"; color: theme.text; font.pixelSize: 25; font.family: "monospace"; font.bold: true }
                                            Rectangle { Layout.alignment: Qt.AlignVCenter
                                                implicitHeight: 21; implicitWidth: hvT.width + 15; radius: 10; color: theme.iris
                                                Text { id: hvT; anchors.centerIn: parent; text: "v" + root.seaVersion; color: theme.bg; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                        }
                                        RowLayout { spacing: 7
                                            Sym { text: "person"; sz: 14; color: theme.frost }
                                            Text { text: root.sysInfo.host || "…"; color: theme.frost; font.pixelSize: 13; font.family: "monospace" }
                                            Sym { text: "deployed_code"; sz: 14; color: theme.faint; Layout.leftMargin: 6 }
                                            Text { text: root.sysInfo.os || "…"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                    }
                                    ColumnLayout { spacing: 2; Layout.alignment: Qt.AlignVCenter
                                        Text { text: "UPTIME"; color: theme.faint; font.pixelSize: 8; font.family: "monospace"; font.bold: true; font.letterSpacing: 1.5; Layout.alignment: Qt.AlignRight }
                                        Text { text: root.sysInfo.up || "…"; color: theme.frost; font.pixelSize: 15; font.family: "monospace"; font.bold: true; Layout.alignment: Qt.AlignRight }
                                    }
                                }
                            }

                            // ---- system info grid ----
                            Section { title: "system"; icon: "monitor_heart" }
                            GridLayout {
                                Layout.fillWidth: true; columns: 2; columnSpacing: 10; rowSpacing: 8
                                InfoTile { icon: "terminal";        label: "KERNEL";     value: root.sysInfo.kernel || "…" }
                                InfoTile { icon: "dashboard";       label: "COMPOSITOR"; value: root.sysInfo.wm ? ("Hyprland " + root.sysInfo.wm) : "Hyprland" }
                                InfoTile { icon: "desktop_windows"; label: "SESSION";    value: root.sysInfo.session ? (root.sysInfo.session.charAt(0).toUpperCase() + root.sysInfo.session.slice(1)) : "Wayland" }
                                InfoTile { icon: "aspect_ratio";    label: "RESOLUTION"; value: root.sysInfo.res || "…" }
                                InfoTile { icon: "code";            label: "SHELL";      value: root.sysInfo.shell || "…" }
                                InfoTile { icon: "inventory_2";     label: "PACKAGES";   value: root.sysInfo.pkgs ? (root.sysInfo.pkgs + "  ·  pacman") : "…" }
                                InfoTile { icon: "architecture";    label: "ARCH";       value: root.sysInfo.arch || "…" }
                                InfoTile { icon: "monitoring";      label: "LOAD AVG";   value: root.sysInfo.load || "…" }
                            }

                            // ---- hardware ----
                            Section { title: "hardware"; icon: "memory" }
                            InfoTile { icon: "developer_board"; label: "CPU"
                                value: (root.sysInfo.cpu || "…") + (root.sysInfo.cores ? ("  ·  " + root.sysInfo.cores + " threads") : "") }
                            Repeater { model: root.sysInfo.gpus || []
                                delegate: InfoTile { required property var modelData; icon: "view_in_ar"; label: "GPU"; value: modelData } }
                            ColumnLayout { Layout.fillWidth: true; Layout.topMargin: 4; spacing: 10
                                Meter { label: "memory"; pct: parseInt(root.sysInfo.rampct) || 0; value: root.sysInfo.ram || "…"; fill: theme.iris }
                                Meter { label: "disk /"; pct: parseInt(root.sysInfo.diskpct) || 0; value: root.sysInfo.disk || "…"; fill: theme.frost }
                            }

                            // ---- refresh ----
                            RowLayout { Layout.topMargin: 6; Layout.fillWidth: true
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    implicitHeight: 30; implicitWidth: rfRow.width + 22; radius: 9
                                    color: rfMa.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.2)
                                    RowLayout { id: rfRow; anchors.centerIn: parent; spacing: 7
                                        Sym { text: "refresh"; sz: 15; color: theme.frost }
                                        Text { text: "refresh"; color: theme.sub; font.pixelSize: 11; font.family: "monospace" } }
                                    MouseArea { id: rfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sysProc.running = true }
                                }
                            }
                        }

                        // ================= CALENDAR =================
                        ColumnLayout {
                            visible: root.tab === 11; Layout.fillWidth: true; spacing: 14

                            // header + live count
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "calendar_month"; sz: 18; color: theme.iris }
                                Text { text: "calendar"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Rectangle { visible: root.calEvents.length > 0; implicitHeight: 20; implicitWidth: cntTxt.width + 16; radius: 10
                                    color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                    Text { id: cntTxt; anchors.centerIn: parent; text: root.calEvents.length + (root.calEvents.length===1 ? " event" : " events")
                                        color: theme.frost; font.pixelSize: 10; font.family: "monospace"; font.bold: true } }
                            }

                            // ---- import card ----
                            Rectangle {
                                Layout.fillWidth: true; radius: 12; implicitHeight: impCol.implicitHeight + 24
                                color: theme.a(theme.line, 0.28); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                                ColumnLayout {
                                    id: impCol
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                    Text { text: "IMPORT EVENTS"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                                    // url + import link
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 36; radius: 8
                                            color: theme.a(theme.bg, 0.4); border.width: 1
                                            border.color: calUrlIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                                Sym { text: "link"; sz: 15; color: theme.faint }
                                                TextInput {
                                                    id: calUrlIn
                                                    Layout.fillWidth: true
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                                    clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: calUrlIn.text === ""
                                                        text: "paste an .ics link…"; color: theme.faint; font.pixelSize: 12; font.family: "monospace" }
                                                    Keys.onReturnPressed: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
                                        }
                                        Rectangle {
                                            implicitWidth: 108; implicitHeight: 36; radius: 8
                                            color: calUrlMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                            border.width: 1; border.color: theme.iris
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "download"; sz: 15; color: calUrlMa.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "Import"; color: calUrlMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                            MouseArea { id: calUrlMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
                                    }
                                    // file picker + clear
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 36; radius: 8
                                            color: calImpMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.14)
                                            border.width: 1; border.color: theme.a(theme.iris, 0.6)
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "upload_file"; sz: 15; color: calImpMa.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "Import .ics file"; color: calImpMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                            MouseArea { id: calImpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.pickFile("Select Calendar iCalendar (.ics) File", "iCalendar (*.ics) | *.ics", function(path) { root.importICS(path); }) } }
                                        Rectangle {
                                            implicitWidth: 128; implicitHeight: 36; radius: 8
                                            visible: root.calEvents.length > 0
                                            color: calClrMa.containsMouse ? theme.a(theme.bad, 0.22) : "transparent"
                                            border.width: 1; border.color: calClrMa.containsMouse ? theme.bad : theme.a(theme.bad, 0.4)
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "delete_sweep"; sz: 15; color: theme.bad }
                                                Text { text: "Clear all"; color: theme.bad; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                            MouseArea { id: calClrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.clearEvents() } }
                                    }
                                    Text { visible: root.calMsg !== ""; text: root.calMsg; color: theme.frost; font.pixelSize: 11; font.family: "monospace"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                }
                            }

                            // ---- subscriptions (imported links are remembered & auto-refreshed) ----
                            RowLayout { Layout.fillWidth: true; spacing: 8; visible: root.calSubs.length > 0
                                Text { text: "SUBSCRIPTIONS"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                                Sym { text: "sync"; sz: 14; color: resyncMa.containsMouse ? theme.iris : theme.faint
                                    MouseArea { id: resyncMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.calMsg = "re-syncing subscriptions…"; root.calMutate(["--resync"]) } } }
                                Text { text: "re-sync"; color: resyncMa.containsMouse ? theme.iris : theme.faint; font.pixelSize: 9; font.family: "monospace" }
                            }
                            Repeater {
                                model: root.calSubs
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; implicitHeight: 32; radius: 8
                                    color: theme.a(theme.line, 0.3); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                                        Sym { text: "link"; sz: 14; color: theme.frost }
                                        Text { text: modelData; color: theme.sub; font.pixelSize: 10; font.family: "monospace"; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                        Sym { text: "close"; sz: 15; color: unsubMa.containsMouse ? theme.bad : theme.faint
                                            MouseArea { id: unsubMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--unsub", modelData]) } } }
                                }
                            }

                            // ---- reminders ----
                            RowLayout { Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
                                Text { text: "REMINDERS"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                            }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                color: theme.a(theme.line, 0.28); border.width: 1; border.color: root.calRemind ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.12)
                                RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                    Sym { text: "notifications_active"; sz: 18; color: root.calRemind ? theme.frost : theme.faint }
                                    ColumnLayout { spacing: 0; Layout.fillWidth: true
                                        Text { text: "notify before events"; color: theme.text; font.pixelSize: 13; font.family: "monospace" }
                                        Text { text: "timed: " + root.calLead + " min ahead · all-day: at 8:00 am"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" } }
                                    Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                        color: root.calRemind ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: root.calRemind ? theme.iris : theme.a(theme.iris, 0.3)
                                        Rectangle { width: 16; height: 16; radius: 8; y: 3; x: root.calRemind ? 27 : 3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","remind", root.calRemind ? "false" : "true"]) } } }
                            }
                            RowLayout { Layout.fillWidth: true; spacing: 6; visible: root.calRemind
                                Text { text: "lead"; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; Layout.rightMargin: 4 }
                                Repeater { model: [10, 15, 30, 60]
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool sel: root.calLead === modelData
                                        implicitWidth: 48; implicitHeight: 26; radius: 7
                                        color: sel ? theme.iris : (ldMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4)); border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                        Text { anchors.centerIn: parent; text: modelData + "m"; color: sel ? theme.bg : theme.sub; font.pixelSize: 10; font.family: "monospace"; font.bold: sel }
                                        MouseArea { id: ldMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","lead", "" + modelData]) } } }
                                Item { Layout.fillWidth: true }
                            }

                            // ---- events list header + refresh ----
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
                                Text { text: "EVENTS"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                                Sym { text: "refresh"; sz: 15; color: calRefMa.containsMouse ? theme.iris : theme.faint
                                    MouseArea { id: calRefMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: reloadEventsProc.running = true } }
                            }

                            Text { visible: root.calEvents.length === 0; text: "no events yet — import an .ics file or link above";
                                color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.fillWidth: true; wrapMode: Text.Wrap }

                            Repeater {
                                model: root.calSorted
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property var rel: root.evRel(modelData.date)
                                    Layout.fillWidth: true; implicitHeight: bodyRow.implicitHeight + 16; radius: 10
                                    opacity: rel.past ? 0.45 : 1
                                    color: theme.a(theme.line, 0.32); border.width: 1
                                    border.color: rel.soon ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.1)
                                    RowLayout {
                                        id: bodyRow
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: 8; anchors.rightMargin: 12; spacing: 12
                                        // date chip
                                        Rectangle {
                                            implicitWidth: 44; implicitHeight: 42; radius: 8
                                            color: rel.soon ? theme.iris : theme.a(theme.iris, 0.14)
                                            ColumnLayout { anchors.centerIn: parent; spacing: 0
                                                Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(root.evDate(modelData.date), "ddd").toUpperCase()
                                                    color: rel.soon ? theme.bg : theme.frost; font.pixelSize: 9; font.family: "monospace"; font.bold: true }
                                                Text { Layout.alignment: Qt.AlignHCenter; text: (""+modelData.date).slice(8)
                                                    color: rel.soon ? theme.bg : theme.text; font.pixelSize: 17; font.family: "monospace"; font.bold: true } }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 2
                                            Text { text: modelData.title; color: theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: true
                                                Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                            RowLayout { spacing: 6
                                                Text { text: rel.t; color: rel.past ? theme.faint : theme.frost; font.pixelSize: 10; font.family: "monospace"; font.bold: true }
                                                Text { visible: !!modelData.time; text: "· " + (modelData.time||""); color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                                Text { text: "· " + Qt.formatDate(root.evDate(modelData.date), "d MMM yyyy"); color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                            }
                                        }
                                        Sym { text: "close"; sz: 16; Layout.alignment: Qt.AlignVCenter
                                            color: delMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.55)
                                            MouseArea { id: delMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.calMutate(["--delete", root.evKey(modelData)]) } }
                                    }
                                }
                            }
                        }

                        // ================= BLUETOOTH =================
                        ColumnLayout {
                            visible: root.tab === 9; Layout.fillWidth: true; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "bluetooth"; sz: 18; color: theme.iris }
                                Text { text: "bluetooth"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Sym { text: (root.btAdapter && root.btAdapter.discovering) ? "sync" : "search"; sz: 16; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering } }
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                    color: (root.btAdapter && root.btAdapter.enabled) ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: (root.btAdapter && root.btAdapter.enabled) ? theme.iris : theme.a(theme.line, 0.9)
                                    Rectangle { width: 16; height: 16; radius: 8; y: 3
                                        x: (root.btAdapter && root.btAdapter.enabled) ? parent.width - 19 : 3
                                        color: (root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint
                                        Behavior on x { NumberAnimation { duration: 120 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled } }
                            }
                            Text { visible: root.btAdapter === null; text: "no bluetooth adapter found"; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.btDevices
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; implicitHeight: 38; radius: 8
                                        color: modelData.connected ? theme.a(theme.iris, 0.2) : (bma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: modelData.connected ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 9
                                            Sym { text: "bluetooth"; sz: 16; color: modelData.connected ? theme.iris : theme.frost }
                                            Text { text: root.btName(modelData); color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { visible: !!modelData.batteryAvailable; text: Math.round((modelData.battery || 0) * 100) + "%"; color: theme.sub; font.pixelSize: 10; font.family: "monospace" }
                                            Text { visible: bma.containsMouse; text: modelData.connected ? "disconnect" : "connect"
                                                color: modelData.connected ? theme.bad : theme.good; font.pixelSize: 10; font.family: "monospace" }
                                            Sym { visible: modelData.connected; text: "check"; sz: 14; color: theme.good }
                                        }
                                        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: modelData.connected ? modelData.disconnect() : modelData.connect() }
                                    }
                                }
                            }
                            Text { visible: root.btAdapter !== null && root.btDevices.length === 0
                                text: (root.btAdapter && root.btAdapter.enabled) ? "no paired devices — hit search to discover" : "bluetooth is off"
                                color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                        }

                        // ================= IDLE & LOCK =================
                        ColumnLayout {
                            visible: root.tab === 10; Layout.fillWidth: true; spacing: 14

                            // segmented horizontal navigation bar for Idle & Lock sub-menus
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6; Layout.bottomMargin: 8
                                Repeater {
                                    model: [
                                        { i: "timer", l: "timeouts" },
                                        { i: "security", l: "lockscreen style" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData; required property int index
                                        readonly property bool sel: root.idlSubTab === index
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: sel ? theme.iris : (subIdMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                        RowLayout {
                                            anchors.centerIn: parent; spacing: 6
                                            Sym { text: modelData.i; sz: 14; color: sel ? theme.bg : theme.frost }
                                            Text { text: modelData.l; color: sel ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                        }
                                        MouseArea { id: subIdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.idlSubTab = index }
                                    }
                                }
                            }

                            // SUB-TAB 0: Timeouts
                            ColumnLayout {
                                visible: root.idlSubTab === 0; Layout.fillWidth: true; spacing: 14
                                Section { title: "idle daemon"; icon: "bedtime" }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 10
                                    Sym { text: root.idleOn ? "bedtime" : "coffee"; sz: 18; color: root.idleOn ? theme.iris : theme.warn }
                                    ColumnLayout { spacing: 0; Layout.fillWidth: true
                                        Text { text: root.idleOn ? "idle daemon running" : "caffeine mode — idle daemon stopped"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                        Text {
                                            text: {
                                                if (!root.idleOn) return "screen stays on until you turn hypridle back on";
                                                var d = root.lockDim >= 60 ? (root.lockDim / 60).toFixed(0) + "m" : root.lockDim + "s";
                                                var l = (root.lockLock / 60).toFixed(0) + "m";
                                                var o = (root.lockDpms / 60).toFixed(0) + "m";
                                                var s = root.lockSuspendEnabled ? " · suspend " + (root.lockSuspend / 60).toFixed(0) + "m" : "";
                                                return "dim " + d + " · lock " + l + " · screen off " + o + s;
                                            }
                                            color: theme.faint; font.pixelSize: 10; font.family: root.apFont
                                        }
                                    }
                                    Rectangle { implicitWidth: 46; implicitHeight: 22; radius: 11
                                        color: root.idleOn ? theme.a(theme.iris, 0.35) : theme.a(theme.warn, 0.3)
                                        border.width: 1; border.color: root.idleOn ? theme.iris : theme.warn
                                        Rectangle { width: 16; height: 16; radius: 8; y: 3
                                            x: root.idleOn ? parent.width - 19 : 3
                                            color: root.idleOn ? theme.frost : theme.warn
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleIdle() } }
                                }

                                Section { title: "timeouts"; icon: "timer" }
                                
                                // Dim Backlight
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "brightness_medium"; sz: 20 }
                                    Text { text: "dim display"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"15s",v:15},{l:"30s",v:30},{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockDim === modelData.v
                                                implicitWidth: chipDim.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipDimMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipDim; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipDimMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDim = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customDimIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customDimIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: root.lockDim.toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockDim = Math.max(1, v) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customDimIn.activeFocus; text: "s"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Lock Screen
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "lock"; sz: 20 }
                                    Text { text: "lock screen"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300},{l:"10m",v:600},{l:"30m",v:1800}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockLock === modelData.v
                                                implicitWidth: chipLck.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipLckMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipLck; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipLckMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockLock = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customLckIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customLckIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: Math.round(root.lockLock / 60).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockLock = Math.max(1, v * 60) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customLckIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Screen Off (DPMS)
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "settings_brightness"; sz: 20 }
                                    Text { text: "screen off"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300},{l:"10m",v:600},{l:"30m",v:1800}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockDpms === modelData.v
                                                implicitWidth: chipDpms.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipDpmsMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipDpms; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipDpmsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDpms = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customDpmsIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customDpmsIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: Math.round(root.lockDpms / 60).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockDpms = Math.max(1, v * 60) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customDpmsIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Suspend
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "power"; sz: 20; color: root.lockSuspendEnabled ? theme.frost : theme.faint }
                                    Text { text: "suspend system"; color: root.lockSuspendEnabled ? theme.sub : theme.faint; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6; visible: root.lockSuspendEnabled
                                        Repeater {
                                            model: [{l:"10m",v:600},{l:"30m",v:1800},{l:"1h",v:3600},{l:"2h",v:7200}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockSuspend === modelData.v
                                                implicitWidth: chipSsp.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipSspMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipSsp; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipSspMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockSuspend = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customSspIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customSspIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: Math.round(root.lockSuspend / 60).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockSuspend = Math.max(1, v * 60) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customSspIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 10 } } } }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: 10
                                        color: root.lockSuspendEnabled ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockSuspendEnabled ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: 7; y: 3
                                            x: root.lockSuspendEnabled ? parent.width - 17 : 3
                                            color: root.lockSuspendEnabled ? theme.frost : theme.faint
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockSuspendEnabled = !root.lockSuspendEnabled } }
                                }
                            }

                            // SUB-TAB 1: Style & Wallpaper
                            ColumnLayout {
                                visible: root.idlSubTab === 1; Layout.fillWidth: true; spacing: 14
                                Section { title: "lock screen options"; icon: "security" }

                                // Grace period
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "av_timer"; sz: 20 }
                                    Text { text: "grace period"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"0s",v:0},{l:"2s",v:2},{l:"5s",v:5},{l:"10s",v:10}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockGrace === modelData.v
                                                implicitWidth: chipGrc.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipGrcMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipGrc; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipGrcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockGrace = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customGrcIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customGrcIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: root.lockGrace.toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockGrace = Math.max(0, v) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customGrcIn.activeFocus; text: "s"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Hide cursor Toggle
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "navigation"; sz: 20 }
                                    Text { text: "hide cursor on lock"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: 10
                                        color: root.lockHideCursor ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockHideCursor ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: 7; y: 3
                                            x: root.lockHideCursor ? parent.width - 17 : 3
                                            color: root.lockHideCursor ? theme.frost : theme.faint
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockHideCursor = !root.lockHideCursor } }
                                }

                                // Ignore empty input Toggle
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "space_bar"; sz: 20 }
                                    Text { text: "ignore empty input"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: 10
                                        color: root.lockIgnoreEmpty ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockIgnoreEmpty ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: 7; y: 3
                                            x: root.lockIgnoreEmpty ? parent.width - 17 : 3
                                            color: root.lockIgnoreEmpty ? theme.frost : theme.faint
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockIgnoreEmpty = !root.lockIgnoreEmpty } }
                                }

                                Section { title: "blur & background"; icon: "wallpaper" }

                                // Blur Passes
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "blur_on"; sz: 20 }
                                    Text { text: "blur passes"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"1",v:1},{l:"2",v:2},{l:"3",v:3},{l:"5",v:5},{l:"8",v:8}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockBlurPasses === modelData.v
                                                implicitWidth: chipPas.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipPasMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipPas; anchors.centerIn: parent; text: modelData.l.toString(); color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipPasMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurPasses = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customPasIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customPasIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: root.lockBlurPasses.toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockBlurPasses = Math.max(0, v) } } } }
                                }

                                // Blur Size
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "photo_size_select_large"; sz: 20 }
                                    Text { text: "blur size"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"2px",v:2},{l:"4px",v:4},{l:"8px",v:8},{l:"12px",v:12},{l:"16px",v:16}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockBlurSize === modelData.v
                                                implicitWidth: chipSz.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipSzMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipSz; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipSzMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurSize = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customSzIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customSzIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: root.lockBlurSize.toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockBlurSize = Math.max(0, v) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customSzIn.activeFocus; text: "px"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Vibrancy
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "vignette"; sz: 20 }
                                    Text { text: "vibrancy"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
                                        Repeater {
                                            model: [{l:"0%",v:0.0},{l:"25%",v:0.25},{l:"50%",v:0.5},{l:"75%",v:0.75},{l:"100%",v:1.0}]
                                            delegate: Rectangle { required property var modelData; readonly property bool sel: Math.abs(root.lockVibrancy - modelData.v) < 0.02
                                                implicitWidth: chipVib.implicitWidth+14; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipVibMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipVib; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipVibMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockVibrancy = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: 6; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customVibIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customVibIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: "monospace"; text: Math.round(root.lockVibrancy * 100).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseFloat(text); if(!isNaN(v)) root.lockVibrancy = Math.max(0, Math.min(100, v)) / 100 }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customVibIn.activeFocus; text: "%"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Wallpaper path text input
                                Text { text: "wallpaper image path"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont; Layout.topMargin: 4 }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 10
                                    Rectangle {
                                        Layout.fillWidth: true; implicitHeight: 36; radius: 8
                                        color: theme.a(theme.line, 0.4); border.width: 1
                                        border.color: bgIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                        TextInput {
                                            id: bgIn
                                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                            clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                            text: root.lockBg
                                            onTextChanged: root.lockBg = text
                                        }
                                    }
                                    Rectangle {
                                        implicitWidth: 36; implicitHeight: 36; radius: 8
                                        color: bgBrowseMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                                        border.width: 1; border.color: theme.a(theme.iris, 0.25)
                                        Sym { anchors.centerIn: parent; text: "folder_open"; sz: 16; color: theme.frost }
                                        MouseArea {
                                            id: bgBrowseMa
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.pickFile("Select Wallpaper Image", "Images (*.png *.jpg *.jpeg) | *.png;*.jpg;*.jpeg", function(path) {
                                                    bgIn.text = path;
                                                }); } } }
                                }
                            }

                            // Save & Actions Row (always visible at bottom of tab)
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10; Layout.topMargin: 8
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 38; radius: 9
                                    color: svLockM.containsMouse ? theme.iris : theme.a(theme.iris, 0.18)
                                    border.width: 1; border.color: theme.iris
                                    RowLayout {
                                        anchors.centerIn: parent; spacing: 6
                                        Sym { text: "save"; sz: 16; color: svLockM.containsMouse ? theme.bg : theme.frost }
                                        Text { text: "Apply & Restart Daemon"; color: svLockM.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: root.apFont; font.bold: true }
                                    }
                                    MouseArea {
                                        id: svLockM
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.saveLockSettings();
                                            // Restart daemon
                                            root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch exec hypridle");
                                            // Notify user
                                            root.run("notify-send 'sea-shell' 'Lock & Idle settings applied live!'");
                                        }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 120; implicitHeight: 38; radius: 9
                                    color: lkNowM.containsMouse ? theme.warn : theme.a(theme.line, 0.38)
                                    border.width: 1; border.color: lkNowM.containsMouse ? theme.warn : theme.a(theme.iris, 0.16)
                                    RowLayout {
                                        anchors.centerIn: parent; spacing: 6
                                        Sym { text: "lock"; sz: 16; color: lkNowM.containsMouse ? theme.bg : theme.warn }
                                        Text { text: "Lock Now"; color: lkNowM.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: root.apFont }
                                    }
                                    MouseArea {
                                        id: lkNowM
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.run("~/.config/quickshell/sea-shell/sea-lock.sh"); root.closePanel() }
                                    }
                                }
                            }
                        }

                        // ================= POWER =================
                        ColumnLayout {
                            visible: root.tab === 6; Layout.fillWidth: true; spacing: 14
                            Section { title: "battery"; icon: "battery_full" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                visible: UPower.displayDevice && UPower.displayDevice.isLaptopBattery
                                Sym { text: UPower.onBattery ? "battery_5_bar" : "battery_charging_full"; sz: 18
                                    color: UPower.onBattery && UPower.displayDevice.percentage < 0.2 ? theme.bad : theme.good }
                                Rectangle { Layout.fillWidth: true; implicitHeight: 8; radius: 4; color: theme.a(theme.line, 0.8)
                                    Rectangle { height: parent.height; radius: 4
                                        width: parent.width * (UPower.displayDevice ? UPower.displayDevice.percentage : 0)
                                        color: UPower.onBattery && UPower.displayDevice.percentage < 0.2 ? theme.bad : theme.good } }
                                Text { text: UPower.displayDevice ? Math.round(UPower.displayDevice.percentage * 100) + "%" + (UPower.onBattery ? "" : " ⚡") : ""
                                    color: theme.sub; font.pixelSize: 12; font.family: "monospace" }
                            }
                            Text { text: "power profile"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: [ {k:"power-saver", i:"eco", l:"saver"}, {k:"balanced", i:"balance", l:"balanced"}, {k:"performance", i:"speed", l:"performance"} ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.powerProfile === modelData.k
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (ppm.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.centerIn: parent; spacing: 7
                                            Sym { text: modelData.i; sz: 16; color: cur ? theme.iris : theme.frost }
                                            Text { text: modelData.l; color: cur ? theme.frost : theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: cur } }
                                        MouseArea { id: ppm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.setProfile(modelData.k) }
                                    }
                                }
                            }
                            Section { title: "session"; icon: "power_settings_new" }
                            GridLayout {
                                columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
                                Row2 { icon: "lock"; label: "Lock"; cmd: "~/.config/quickshell/sea-shell/sea-lock.sh"; quitAfter: true }
                                Row2 { icon: "bedtime"; label: "Suspend"; cmd: "systemctl suspend"; quitAfter: true }
                                Row2 { icon: "logout"; label: "Logout"; cmd: "systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch exit; sleep 3; loginctl terminate-session self; }"; quitAfter: true }
                                Row2 { icon: "restart_alt"; label: "Reboot"; cmd: "systemctl reboot"; tint: theme.bad; quitAfter: true }
                                Row2 { icon: "power_settings_new"; label: "Shutdown"; cmd: "systemctl poweroff"; tint: theme.bad; quitAfter: true }
                            }
                        }
                    }
                }

            // ================= NATIVE FILE BROWSER OVERLAY =================
            Rectangle {
                id: fbModal
                visible: root.fileBrowserOpen
                anchors.fill: parent
                radius: 18
                color: theme.a(theme.bg, 0.98)
                border.width: 1; border.color: theme.a(theme.iris, 0.4)
                MouseArea { anchors.fill: parent } // block clicks to content below

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 14

                    // Header row
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Sym { text: "folder_open"; sz: 22; color: theme.frost }
                        Text { text: root.fileBrowserTitle; color: theme.text; font.pixelSize: 15; font.family: "monospace"; font.bold: true; Layout.fillWidth: true }
                        // Cancel button
                        Rectangle {
                            implicitWidth: 32; implicitHeight: 32; radius: 16
                            color: fbCloseMa.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"
                            Sym { anchors.centerIn: parent; text: "close"; sz: 18; color: fbCloseMa.containsMouse ? theme.bad : theme.faint }
                            MouseArea { id: fbCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.fileBrowserOpen = false } }
                    }

                    // Path navigation bar
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Rectangle {
                            implicitWidth: 36; implicitHeight: 34; radius: 8
                            color: fbUpMa.containsMouse ? theme.iris : theme.a(theme.line, 0.4)
                            border.width: 1; border.color: theme.a(theme.iris, 0.25)
                            Sym { anchors.centerIn: parent; text: "arrow_upward"; sz: 16; color: fbUpMa.containsMouse ? theme.bg : theme.frost }
                            MouseArea { id: fbUpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUpDir() } }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8
                            color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.2)
                            Text { anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                verticalAlignment: Text.AlignVCenter
                                text: root.fileBrowserPath; color: theme.frost; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideLeft } }
                    }

                    // Content list (scrollable)
                    Flickable {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentWidth: width; contentHeight: fbCol.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: fbCol
                            anchors.left: parent.left; anchors.right: parent.right; spacing: 4
                            
                            // ".." Go Up item
                            Rectangle {
                                visible: root.fileBrowserPath !== "/"
                                Layout.fillWidth: true; implicitHeight: 38; radius: 8
                                color: fbItemUpMa.containsMouse ? theme.a(theme.line, 0.6) : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                    Sym { text: "drive_folder_upload"; sz: 16; color: theme.iris }
                                    Text { text: ".."; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; font.bold: true } }
                                MouseArea { id: fbItemUpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUpDir() } }

                            Repeater {
                                model: root.fileBrowserItems
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool isDir: modelData.type === "d"
                                    readonly property bool matchesFilter: !root.fileBrowserFilter || modelData.name.endsWith(root.fileBrowserFilter)
                                    visible: isDir || matchesFilter
                                    Layout.fillWidth: true
                                    implicitHeight: (isDir || matchesFilter) ? 38 : 0
                                    radius: 8
                                    color: fbItemMa.containsMouse ? theme.a(theme.iris, 0.16) : "transparent"
                                    border.width: fbItemMa.containsMouse ? 1 : 0; border.color: theme.a(theme.iris, 0.25)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                        Sym {
                                            text: isDir ? "folder" : "description"
                                            sz: 16; color: isDir ? theme.frost : theme.faint }
                                        Text {
                                            text: modelData.name; color: theme.text
                                            font.pixelSize: 12; font.family: "monospace"; font.bold: isDir; elide: Text.ElideRight; Layout.fillWidth: true } }
                                    MouseArea {
                                        id: fbItemMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (isDir) {
                                                root.enterDir(modelData.name);
                                            } else {
                                                root.fileBrowserOpen = false;
                                                if (root.fileBrowserCallback) {
                                                    var fullPath = root.fileBrowserPath === "/" ? "/" + modelData.name : root.fileBrowserPath + "/" + modelData.name;
                                                    root.fileBrowserCallback(fullPath);
                                                }
                                            }
                                        } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
