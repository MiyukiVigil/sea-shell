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
    readonly property string seaVersion: "5.0.0"     // sea-shell release — mirrored in the repo VERSION file
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
        if (t === 0) root.audioRefresh()              // audio: sink formats + streams
        if (t === 1) { root.reloadMonitors(); root.reloadDisplayProfiles() }   // display: monitors + saved layout profiles
        if (t === 14) root.reloadKde()                // kdeconnect: refresh devices
        if (t === 7) kbProc.running = true            // keybinds: refresh binds
        if (t === 8) sysProc.running = true           // system: refresh live stats
        if (t === 10) { idleChk.running = true; lockSettingsGet.running = true }   // idle & lock
        if (t === 6) { ppGet.running = true; lockSettingsGet.running = true }   // power: re-read profile & lid settings
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

    // brand glyphs from "Symbols Nerd Font" (Font Logos range) — recolour like any icon
    readonly property string nfKernel:  "\uf31a"   // Tux
    readonly property string nfHypr:    "\uf359"   // Hyprland
    readonly property string nfWayland: "\uf367"   // Wayland
    readonly property string nfXorg:    "\uf369"   // Xorg (X11 sessions)
    // distro id → logo glyph. CachyOS has no glyph (drawn by CachyLogo instead); falls
    // back through ID_LIKE (e.g. "arch") and finally to Tux for anything unknown.
    function distroGlyph(id, idlike) {
        var m = { arch:"\uf303", endeavouros:"\uf322", manjaro:"\uf312", artix:"\uf31f",
                  garuda:"\uf337", archcraft:"\uf345", arcolinux:"\uf346", archlabs:"\uf31e",
                  debian:"\uf306", ubuntu:"\uf31b", pop:"\uf32a", linuxmint:"\uf30e",
                  elementary:"\uf309", zorin:"\uf32f", kali:"\uf327", parrot:"\uf329",
                  fedora:"\uf30a", rhel:"\uf316", centos:"\uf304", almalinux:"\uf31d",
                  rocky:"\uf32b", nixos:"\uf313", gentoo:"\uf30d", void:"\uf32e",
                  opensuse:"\uf314", "opensuse-tumbleweed":"\uf314", "opensuse-leap":"\uf314",
                  alpine:"\uf300", solus:"\uf32d", devuan:"\uf307", raspbian:"\uf315" };
        id = (id || "").toLowerCase();
        if (m[id]) return m[id];
        var like = (idlike || "").toLowerCase().split(/\s+/);
        for (var i = 0; i < like.length; i++) if (m[like[i]]) return m[like[i]];
        return nfKernel;   // Tux
    }

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
        if (root.idleOn) run("pkill -x hypridle"); else run("hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"");
        root.idleOn = !root.idleOn;
    }

    // ---------- idle & lock config data ----------
    property int lockDim: 150
    property int lockLock: 300
    property int lockDpms: 600
    property int lockSuspend: 1800
    property bool lockSuspendEnabled: true
    property string lockLidAction: "suspend"
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
                    if (data.lid_action !== undefined) root.lockLidAction = data.lid_action;
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
            "lid_action": root.lockLidAction,
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
    property var kbRec: null          // bind being rebound (edit-popup open when non-null)
    property var kbRecMods: []
    property string kbRecKey: ""      // staged new base key for the rebind
    property bool kbRecRecording: false
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
    // ---- keybind editor popup: open in edit or add mode, and close ----
    function kbOpenEdit(bind) {
        root.kbAdding = false;
        root.kbRec = bind; root.kbRecMods = bind.mods.slice(); root.kbRecKey = bind.key;
        root.kbRecRecording = false; root.kbConflict = "";
    }
    function kbOpenAdd() {
        root.kbRec = null; root.kbConflict = "";
        root.kbAdding = true; root.kbAddRecording = false;
        root.kbAddDesc = ""; root.kbAddAction = "exec, "; root.kbAddKey = ""; root.kbAddMods = ["SUPER"];
    }
    function kbCloseEditor() {
        root.kbRec = null; root.kbAdding = false;
        root.kbRecRecording = false; root.kbAddRecording = false; root.kbConflict = "";
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

    // ---------- sound: per-sink format + per-app routing (sea-audio.py, 4.0) ----------
    // The full-size twin of the volume dropdown's Sound bits: each output's live
    // sample-rate / bit-depth (or a Bluetooth codec) and its capability, plus per-app
    // output routing with an explicit sink picker. Read while the Audio tab is open.
    readonly property string _audioScript: Qt.resolvedUrl("sea-audio.py").toString().replace("file://", "")
    property var audioSinks: ({})       // node.name -> {rate,format,bits,active,bt_codec,rates}
    property var audioStreams: []       // [{id,app,title,sink_id,sink_label}]
    property var audioBtSinks: []       // bluetooth sinks offering a codec choice
    Process {
        id: audioInfoProc
        command: ["python3", root._audioScript, "--status"]
        stdout: StdioCollector { id: audioInfoOut; onStreamFinished: {
            try {
                var j = JSON.parse(audioInfoOut.text.trim() || "{}");
                if (!j.ok) return;
                var m = {}, bt = [];
                for (var i = 0; i < (j.sinks || []).length; i++) {
                    var sk = j.sinks[i]; m[sk.name] = sk;
                    if (sk.bt_codecs && sk.bt_codecs.length > 1) bt.push(sk);
                }
                root.audioSinks = m; root.audioBtSinks = bt;
                root.audioStreams = j.streams || [];
            } catch (e) {}
        } } }
    function audioRefresh() { audioInfoProc.running = true }
    Timer { id: audioRefreshTimer; interval: 350; onTriggered: root.audioRefresh() }
    Timer { running: root.shown && root.tab === 0; interval: 2000; repeat: true; triggeredOnStart: true; onTriggered: root.audioRefresh() }
    // "48k · 24-bit", or a codec name for bluetooth; idle sinks show the rate they'll run at
    function audioFmtBadge(nodeName) {
        var s = root.audioSinks[nodeName]; if (!s) return "";
        if (s.bt_codec) return ("" + s.bt_codec).toUpperCase();
        var khz = s.rate ? (s.rate % 1000 === 0 ? (s.rate / 1000) : (s.rate / 1000).toFixed(1)) + "k" : "";
        if (!s.active) return khz;
        return khz + (khz && s.bits ? " · " : "") + (s.bits ? s.bits + "-bit" : "");
    }
    function audioMaxRate(nodeName) {
        var s = root.audioSinks[nodeName]; if (!s || !s.rates || !s.rates.length) return "";
        var mx = s.rates[s.rates.length - 1];
        if (s.rate && mx <= s.rate) return "";   // nothing to add when capability == current rate
        return "up to " + (mx % 1000 === 0 ? (mx / 1000) : (mx / 1000).toFixed(1)) + "k";
    }
    function audioRoute(streamId, sinkRef) {
        Quickshell.execDetached(["python3", root._audioScript, "--route", "" + streamId, "" + sinkRef]);
        audioRefreshTimer.restart();
    }
    // switch a bluetooth sink's A2DP codec (by its stable node.name — the id churns on switch)
    function audioSetCodec(sinkName, profile) {
        Quickshell.execDetached(["python3", root._audioScript, "--bt-codec", "" + sinkName, "" + profile]);
        audioRefreshTimer.restart();
    }

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
                if (root.monSel >= out.length) root.monSel = 0;
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

    // ---------- KDE Connect ----------
    property var kdeDevices: []
    Process {
        id: kdeProc; running: false
        command: ["python3", root.repo + "/sea-kdeconnect.py", "--list"]
        stdout: StdioCollector { id: kdeOut; onStreamFinished: {
            try {
                root.kdeDevices = JSON.parse(kdeOut.text.trim() || "[]");
            } catch(e) { root.kdeDevices = [] }
        } }
    }
    function reloadKde() { kdeProc.running = false; kdeProc.running = true }
    function kdeAction(args) {
        Quickshell.execDetached(["python3", root.repo + "/sea-kdeconnect.py"].concat(args));
        kdeProcTimer.start();
    }
    Timer { id: kdeProcTimer; interval: 800; onTriggered: root.reloadKde() }
    Timer {
        id: kdeRefreshTimer
        interval: 4000
        running: root.shown && root.tab === 14
        repeat: true
        onTriggered: root.reloadKde()
    }
    // native modes first; only fall back to common defaults if no native modes were reported
    function uniqueRes(m) {
        var seen={}, r=[];
        if(m) for(var i=0;i<m.modes.length;i++){ var s=m.modes[i].res; if(!seen[s]){seen[s]=1;r.push(s)} }
        if(r.length > 0) return r;
        var common=["3840x2160","2560x1440","1920x1080","1600x900","1366x768","1280x720","1024x576"];
        for(var j=0;j<common.length;j++) if(!seen[common[j]]){seen[common[j]]=1;r.push(common[j])}
        return r;
    }
    function hzFor(m, res) {
        var seen={}, r=[];
        if(m) for(var i=0;i<m.modes.length;i++) if(m.modes[i].res===res && !seen[m.modes[i].hz]){seen[m.modes[i].hz]=1;r.push(m.modes[i].hz)}
        if(r.length > 0) return r;
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

    // ---------- display profiles (saved monitor arrangements) ----------
    readonly property string _displayScript: Qt.resolvedUrl("sea-display.py").toString().replace("file://", "")
    property var displayProfiles: []       // [{name, summary, created, matches}]
    property string profName: ""           // new-profile name field
    Process {
        id: dispProfProc
        command: ["python3", root._displayScript, "--list"]
        stdout: StdioCollector { id: dispProfOut; onStreamFinished: {
            try { var j = JSON.parse(dispProfOut.text.trim() || "{}"); root.displayProfiles = j.profiles || []; } catch (e) {}
        } } }
    function reloadDisplayProfiles() { dispProfProc.running = true }
    Timer { id: dispProfRefresh; interval: 700; onTriggered: root.reloadDisplayProfiles() }
    function saveDisplayProfile(name) {
        var n = (name || "").trim(); if (!n) return;
        Quickshell.execDetached(["python3", root._displayScript, "--save", n]);
        root.profName = ""; dispProfRefresh.restart();
    }
    function applyDisplayProfile(name) {
        Quickshell.execDetached(["sh", "-c", "python3 '" + root._displayScript + "' --apply '" + ("" + name).replace(/'/g, "") + "' && notify-send 'sea-shell' 'Layout → " + ("" + name).replace(/'/g, "") + "'"]);
        monRefresh.start();
    }
    function deleteDisplayProfile(name) {
        Quickshell.execDetached(["python3", root._displayScript, "--delete", "" + name]);
        dispProfRefresh.restart();
    }

    // ---------- appearance (shared with the bar via ~/.config/sea-shell/appearance.json) ----------
    property real apRadius: 14
    property real apOpacity: 0.80
    property int  apHeight: 42
    property real apScale: 0                 // UI scale: 0 = auto (per-monitor), >0 = manual multiplier
    // effective scale used for the live preview + the settings window itself (mirrors shell.qml)
    function autoScaleEstimate() {
        var h = 0, s = Quickshell.screens;
        for (var i = 0; i < s.length; i++) if (s[i] && s[i].height > h) h = s[i].height;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    function uiScale() { return root.apScale > 0 ? root.apScale : root.autoScaleEstimate(); }
    // per-monitor overrides — { name: { bar: bool, scale: number(0=inherit) } } (mirrors shell.qml cfgMonitors)
    property var apMonitors: ({})
    function monBarAp(name)   { var m = name ? root.apMonitors[name] : null; return !(m && m.bar === false); }
    function monScaleAp(name) { var m = name ? root.apMonitors[name] : null; return (m && m.scale > 0) ? m.scale : 0; }
    function setMon(name, key, val) {
        if (!name) return;
        var m = {};
        for (var kk in root.apMonitors) m[kk] = { bar: root.apMonitors[kk].bar, scale: root.apMonitors[kk].scale };
        if (!m[name]) m[name] = { bar: true, scale: 0 };
        m[name][key] = val;
        root.apMonitors = m; root.saveAppearance();
    }
    property bool apAutoHide: false          // auto-hide the bar (reveal on hover)
    property bool apHideFullscreen: false     // hide the bar while a window is fullscreen
    property bool apNight: false             // night light on/off (manual)
    property int  apNightTemp: 4000          // night-light colour temperature (K)
    property bool apNightAuto: false         // night light follows dark mode
    // drag-reorderable order of the bar widgets (mirrors shell.qml cfgWidgetOrder)
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
    property var apWidgetOrder: root.defaultWidgetOrder
    // left cluster order (mirrors shell.qml cfgLeftOrder)
    readonly property var defaultLeftOrder: ["lgLogo","lgWork","lgTitle"]
    property var apLeftOrder: root.defaultLeftOrder
    readonly property var lgMeta: ({
        lgLogo:  { i: "sailing",  l: "Logo",         d: "The sea-shell mark — click opens the launcher" },
        lgWork:  { i: "apps",     l: "Workspaces",   d: "Hyprland workspace indicators" },
        lgTitle: { i: "title",    l: "Window Title", d: "Class of the focused window" }
    })
    // append any ids missing from a saved order (e.g. new ones added in an update)
    function wgReconcile(order, def) {
        def = def || root.defaultWidgetOrder;
        var res = order.slice();
        for (var i = 0; i < def.length; i++)
            if (res.indexOf(def[i]) < 0) res.push(def[i]);
        return res;
    }
    // metadata for each widget id (icon · label · description · toggle-prop; "" prop = no toggle)
    readonly property var wgMeta: ({
        wgMpris:     { i: "play_circle",           l: "Media Player",      d: "Track info + controls — always sits in the bar centre", prop: "wgMpris" },
        wgTray:      { i: "grid_view",             l: "System Tray",       d: "Collapsible background app status-notifier icons",      prop: "wgTray" },
        wgQuick:     { i: "tune",                  l: "Control Center",    d: "Quick toggles (dark · caffeine · DND · Wi-Fi · BT) + power profile", prop: "wgQuick" },
        wgWeather:   { i: "cloud",                 l: "Weather",           d: "Current temperature and conditions",                    prop: "wgWeather" },
        wgClipboard: { i: "content_paste",         l: "Clipboard Manager", d: "Opens the clipboard-history search",                    prop: "wgClipboard" },
        wgNotif:     { i: "notifications",         l: "Notification Bell", d: "Unread-count badge + notification centre",              prop: "wgNotif" },
        wgWifi:      { i: "wifi",                   l: "Wi-Fi",             d: "Network status and signal strength",                    prop: "wgWifi" },
        wgBluetooth: { i: "bluetooth",             l: "Bluetooth",         d: "Adapter status + connected-devices list",               prop: "wgBluetooth" },
        wgKdeconnect:{ i: "phonelink",             l: "KDE Connect",       d: "Phone battery + ring, send file, clipboard, files",     prop: "wgKdeconnect" },
        wgCaffeine:  { i: "coffee",                l: "Caffeine",          d: "Prevents screen dimming and auto-suspend",              prop: "wgCaffeine" },
        wgNight:     { i: "nightlight",            l: "Night light",       d: "One-tap warm-screen toggle on the bar",                 prop: "wgNight" },
        wgSystem:    { i: "speed",                 l: "System Monitor",    d: "Live CPU usage and system load",                        prop: "wgSystem" },
        wgVolume:    { i: "volume_up",             l: "Volume",            d: "Sound level and output selector",                       prop: "wgVolume" },
        wgBattery:   { i: "battery_charging_full", l: "Battery",           d: "Remaining charge (laptops)",                            prop: "wgBattery" },
        wgRec:       { i: "videocam",              l: "Screen Recorder",   d: "Shows only while recording — no toggle",                 prop: "" },
        wgClock:     { i: "schedule",              l: "Clock & Calendar",  d: "Date/time with upcoming events",                        prop: "wgClock" },
        wgPower:     { i: "power_settings_new",    l: "Power",             d: "Lock, log out, reboot, or shut down",                   prop: "wgPower" }
    })
    // reorder helpers for the drag list (ListModel move → commit back to apWidgetOrder + save)
    function wgCommitOrder() {
        var a = []; for (var i = 0; i < wgOrderModel.count; i++) a.push(wgOrderModel.get(i).wid);
        root.apWidgetOrder = a; root.saveAppearance();
    }
    function wgSyncModel() {
        wgOrderModel.clear();
        for (var i = 0; i < root.apWidgetOrder.length; i++) {
            var w = root.apWidgetOrder[i]; if (root.wgMeta[w]) wgOrderModel.append({ wid: w });
        }
    }
    ListModel { id: wgOrderModel }
    Component.onCompleted: { root.wgSyncModel(); root.lgSyncModel() }
    onApWidgetOrderChanged: if (!root.wgDragging) root.wgSyncModel()
    property bool wgDragging: false
    // left-cluster reorder helpers (parallel to the widget ones)
    function lgCommitOrder() {
        var a = []; for (var i = 0; i < lgOrderModel.count; i++) a.push(lgOrderModel.get(i).wid);
        root.apLeftOrder = a; root.saveAppearance();
    }
    function lgSyncModel() {
        lgOrderModel.clear();
        for (var i = 0; i < root.apLeftOrder.length; i++) {
            var w = root.apLeftOrder[i]; if (root.lgMeta[w]) lgOrderModel.append({ wid: w });
        }
    }
    ListModel { id: lgOrderModel }
    onApLeftOrderChanged: if (!root.wgDragging) root.lgSyncModel()
    property string apAccent: "#63c7dd"
    property string apFont: "monospace"
    property bool apLight: false            // dark (default) ↔ light palette
    property bool apMatugen: false          // recolour accent + kitty from the wallpaper
    property string apScheme: "scheme-tonal-spot"   // matugen colour-scheme algorithm
    readonly property var schemes: ["scheme-tonal-spot","scheme-content","scheme-neutral","scheme-expressive","scheme-fidelity","scheme-monochrome","scheme-rainbow","scheme-fruit-salad"]
    property string apBarFill: "matugen"            // top-bar fill: matugen · black · white
    property string apEdge: "top"                   // bar dock edge: top, bottom, left, right
    readonly property var edges: ["top","bottom","left","right"]
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
    property bool wgKdeconnect: true
    property bool wgCaffeine: true
    property bool wgSystem: true
    property bool wgVolume: true
    property bool wgBattery: true
    property bool wgClock: true
    property bool wgPower: true
    property bool wgQuick: true
    property bool wgNight: false
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
            if(j.height!==undefined) root.apHeight=j.height; if(j.scale!==undefined) root.apScale=j.scale; if(j.accent!==undefined) root.apAccent=j.accent;
            if(j.font!==undefined) root.apFont=j.font; if(j.customFonts!==undefined) root.apCustomFonts=j.customFonts;
            if(j.mode!==undefined) root.apLight=(""+j.mode==="light"); if(j.matugen!==undefined) root.apMatugen=!!j.matugen;
            if(j.scheme!==undefined && (""+j.scheme).length>0) root.apScheme=j.scheme;
            if(j.barFill!==undefined && (""+j.barFill).length>0) root.apBarFill=j.barFill;
            if(j.edge==="top"||j.edge==="bottom"||j.edge==="left"||j.edge==="right") root.apEdge=j.edge;
            if(j.autoDark!==undefined) root.apAutoDark=!!j.autoDark; if(j.darkStart!==undefined) root.apDarkStart=j.darkStart; if(j.darkEnd!==undefined) root.apDarkEnd=j.darkEnd;
            if(j.appMode!==undefined && (j.appMode==="auto"||j.appMode==="dark"||j.appMode==="light")) root.apAppMode=j.appMode;
            if(j.wgMpris!==undefined) root.wgMpris=!!j.wgMpris;
            if(j.wgTray!==undefined) root.wgTray=!!j.wgTray;
            if(j.wgWeather!==undefined) root.wgWeather=!!j.wgWeather;
            if(j.wgClipboard!==undefined) root.wgClipboard=!!j.wgClipboard;
            if(j.wgNotif!==undefined) root.wgNotif=!!j.wgNotif;
            if(j.wgWifi!==undefined) root.wgWifi=!!j.wgWifi;
            if(j.wgBluetooth!==undefined) root.wgBluetooth=!!j.wgBluetooth;
            if(j.wgKdeconnect!==undefined) root.wgKdeconnect=!!j.wgKdeconnect;
            if(j.wgCaffeine!==undefined) root.wgCaffeine=!!j.wgCaffeine;
            if(j.wgSystem!==undefined) root.wgSystem=!!j.wgSystem;
            if(j.wgVolume!==undefined) root.wgVolume=!!j.wgVolume;
            if(j.wgBattery!==undefined) root.wgBattery=!!j.wgBattery;
            if(j.wgClock!==undefined) root.wgClock=!!j.wgClock;
            if(j.wgPower!==undefined) root.wgPower=!!j.wgPower;
            if(j.wgQuick!==undefined) root.wgQuick=!!j.wgQuick;
            if(j.wgNight!==undefined) root.wgNight=!!j.wgNight;
            if(j.autoHide!==undefined) root.apAutoHide=!!j.autoHide;
            if(j.hideFullscreen!==undefined) root.apHideFullscreen=!!j.hideFullscreen;
            if(j.night!==undefined) root.apNight=!!j.night;
            if(j.nightTemp!==undefined) root.apNightTemp=j.nightTemp;
            if(j.nightAuto!==undefined) root.apNightAuto=!!j.nightAuto;
            if(j.widgetOrder!==undefined && Array.isArray(j.widgetOrder) && j.widgetOrder.length>0) root.apWidgetOrder=root.wgReconcile(j.widgetOrder);
            if(j.leftOrder!==undefined && Array.isArray(j.leftOrder) && j.leftOrder.length>0) root.apLeftOrder=root.wgReconcile(j.leftOrder, root.defaultLeftOrder);
            if(j.monitors!==undefined && j.monitors && typeof j.monitors==="object") root.apMonitors=j.monitors;
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
            scale: root.apScale,
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
            wgKdeconnect: root.wgKdeconnect,
            wgCaffeine: root.wgCaffeine,
            wgSystem: root.wgSystem,
            wgVolume: root.wgVolume,
            wgBattery: root.wgBattery,
            wgClock: root.wgClock,
            wgPower: root.wgPower,
            wgQuick: root.wgQuick,
            wgNight: root.wgNight,
            autoHide: root.apAutoHide,
            hideFullscreen: root.apHideFullscreen,
            night: root.apNight,
            nightTemp: root.apNightTemp,
            nightAuto: root.apNightAuto,
            widgetOrder: root.apWidgetOrder,
            leftOrder: root.apLeftOrder,
            monitors: root.apMonitors
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
        if (p.scale !== undefined) root.apScale = p.scale;
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
        if (p.wgKdeconnect !== undefined) root.wgKdeconnect = p.wgKdeconnect;
        if (p.wgCaffeine !== undefined) root.wgCaffeine = p.wgCaffeine;
        if (p.wgSystem !== undefined) root.wgSystem = p.wgSystem;
        if (p.wgVolume !== undefined) root.wgVolume = p.wgVolume;
        if (p.wgBattery !== undefined) root.wgBattery = p.wgBattery;
        if (p.wgClock !== undefined) root.wgClock = p.wgClock;
        if (p.wgPower !== undefined) root.wgPower = p.wgPower;
        if (p.wgQuick !== undefined) root.wgQuick = p.wgQuick;
        if (p.wgNight !== undefined) root.wgNight = p.wgNight;
        if (p.autoHide !== undefined) root.apAutoHide = p.autoHide;
        if (p.hideFullscreen !== undefined) root.apHideFullscreen = p.hideFullscreen;
        if (p.night !== undefined) root.apNight = p.night;
        if (p.nightTemp !== undefined) root.apNightTemp = p.nightTemp;
        if (p.nightAuto !== undefined) root.apNightAuto = p.nightAuto;
        if (Array.isArray(p.widgetOrder) && p.widgetOrder.length > 0) root.apWidgetOrder = root.wgReconcile(p.widgetOrder);
        if (Array.isArray(p.leftOrder) && p.leftOrder.length > 0) root.apLeftOrder = root.wgReconcile(p.leftOrder, root.defaultLeftOrder);
        if (p.monitors && typeof p.monitors === "object") root.apMonitors = p.monitors;

        root.saveAppearance();
    }

    function deleteProfile(idx) {
        var list = root.profilesList.slice();
        list.splice(idx, 1);
        root.profilesList = list;
        var base64 = Qt.btoa(JSON.stringify(list));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + base64 + "' | base64 -d > \"$HOME/.config/sea-shell/profiles.json\"");
    }

    // ---------- bar layout presets (just the bar: widget order · left order · widget on/off) ----------
    readonly property var barToggleKeys: ["wgMpris","wgTray","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgVolume","wgBattery","wgClock","wgPower","wgQuick"]
    property var barLayouts: []
    Process { id: barLayoutsReadProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/bar-layouts.json\" 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: blOut; onStreamFinished: { try { root.barLayouts = JSON.parse(blOut.text) } catch(e){ root.barLayouts = [] } } } }
    function saveBarLayout(name) {
        if (!name.trim()) return;
        var p = { name: name.trim(), widgetOrder: root.apWidgetOrder, leftOrder: root.apLeftOrder, toggles: {} };
        for (var i = 0; i < root.barToggleKeys.length; i++) p.toggles[root.barToggleKeys[i]] = root[root.barToggleKeys[i]];
        var list = root.barLayouts.slice(); var idx = -1;
        for (var j = 0; j < list.length; j++) if (list[j].name === name.trim()) { idx = j; break; }
        if (idx >= 0) list[idx] = p; else list.push(p);
        root.barLayouts = list;
        var b64 = Qt.btoa(JSON.stringify(list));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"$HOME/.config/sea-shell/bar-layouts.json\"");
    }
    function loadBarLayout(p) {
        if (Array.isArray(p.widgetOrder) && p.widgetOrder.length > 0) root.apWidgetOrder = root.wgReconcile(p.widgetOrder);
        if (Array.isArray(p.leftOrder) && p.leftOrder.length > 0) root.apLeftOrder = root.wgReconcile(p.leftOrder, root.defaultLeftOrder);
        if (p.toggles) for (var i = 0; i < root.barToggleKeys.length; i++) { var k = root.barToggleKeys[i]; if (p.toggles[k] !== undefined) root[k] = p.toggles[k]; }
        root.saveAppearance();
    }
    function deleteBarLayout(idx) {
        var list = root.barLayouts.slice(); list.splice(idx, 1); root.barLayouts = list;
        var b64 = Qt.btoa(JSON.stringify(list));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"$HOME/.config/sea-shell/bar-layouts.json\"");
    }
    function saveAppearance() {
        var cf = '['; for(var i=0;i<root.apCustomFonts.length;i++){ cf += (i?',':'') + '\"'+root.apCustomFonts[i]+'\"'; } cf += ']';
        var j = '{\"radius\":'+Math.round(root.apRadius)+',\"opacity\":'+root.apOpacity.toFixed(2)+',\"height\":'+Math.round(root.apHeight)+',\"scale\":'+root.apScale.toFixed(2)+',\"accent\":\"'+root.apAccent+'\",\"font\":\"'+root.apFont+'\",\"customFonts\":'+cf+',\"mode\":\"'+(root.apLight?'light':'dark')+'\",\"matugen\":'+(root.apMatugen?'true':'false')+',\"scheme\":\"'+root.apScheme+'\",\"barFill\":\"'+root.apBarFill+'\",\"edge\":\"'+root.apEdge+'\",\"autoDark\":'+(root.apAutoDark?'true':'false')+',\"darkStart\":\"'+root.apDarkStart+'\",\"darkEnd\":\"'+root.apDarkEnd+'\",\"appMode\":\"'+root.apAppMode+'\",\"wgMpris\":'+(root.wgMpris?'true':'false')+',\"wgTray\":'+(root.wgTray?'true':'false')+',\"wgWeather\":'+(root.wgWeather?'true':'false')+',\"wgClipboard\":'+(root.wgClipboard?'true':'false')+',\"wgNotif\":'+(root.wgNotif?'true':'false')+',\"wgWifi\":'+(root.wgWifi?'true':'false')+',\"wgBluetooth\":'+(root.wgBluetooth?'true':'false')+',\"wgKdeconnect\":'+(root.wgKdeconnect?'true':'false')+',\"wgCaffeine\":'+(root.wgCaffeine?'true':'false')+',\"wgSystem\":'+(root.wgSystem?'true':'false')+',\"wgVolume\":'+(root.wgVolume?'true':'false')+',\"wgBattery\":'+(root.wgBattery?'true':'false')+',\"wgClock\":'+(root.wgClock?'true':'false')+',\"wgPower\":'+(root.wgPower?'true':'false')+',\"wgQuick\":'+(root.wgQuick?'true':'false')+',\"wgNight\":'+(root.wgNight?'true':'false')+',\"autoHide\":'+(root.apAutoHide?'true':'false')+',\"hideFullscreen\":'+(root.apHideFullscreen?'true':'false')+',\"night\":'+(root.apNight?'true':'false')+',\"nightTemp\":'+Math.round(root.apNightTemp)+',\"nightAuto\":'+(root.apNightAuto?'true':'false')+',\"widgetOrder\":'+JSON.stringify(root.apWidgetOrder)+',\"leftOrder\":'+JSON.stringify(root.apLeftOrder)+',\"monitors\":'+JSON.stringify(root.apMonitors)+'}';
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
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.topMargin: 4
        spacing: 10
        RowLayout {
            spacing: 8
            Sym { text: icon; sz: 17; color: theme.iris }
            Text { text: title; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true; font.letterSpacing: 0.4 }
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

    // ---- consistent form controls: spacing is baked in so every tab aligns by construction ----
    // on/off switch — bind `on`, handle `toggled`
    component Toggle: Rectangle {
        id: tg
        property bool on: false
        signal toggled()
        implicitWidth: 44; implicitHeight: 24; radius: 12
        color: on ? theme.iris : theme.a(theme.line, 0.85)
        border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.3)
        Behavior on color { ColorAnimation { duration: 120 } }
        Rectangle { width: 18; height: 18; radius: 9; y: 3; x: tg.on ? tg.width - width - 3 : 3
            color: theme.frost; Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } } }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tg.toggled() }
    }

    // full-width setting row with a built-in switch: icon · title · description · toggle.
    // The whole row is clickable. Border lights up while `on`.
    component ToggleCard: Rectangle {
        id: tc
        property string icon: ""
        property string title: ""
        property string desc: ""
        property bool on: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: Math.max(52, tcRow.implicitHeight + 18)
        radius: 10
        color: tcMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.4)
        border.width: 1; border.color: tc.on ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
        Behavior on color { ColorAnimation { duration: 110 } }
        RowLayout {
            id: tcRow
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
            Sym { visible: tc.icon !== ""; text: tc.icon; sz: 19; color: tc.on ? theme.frost : theme.sub; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout { spacing: 2; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                Text { visible: tc.title !== ""; text: tc.title; color: theme.text; font.pixelSize: 13; font.family: "monospace"; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { visible: tc.desc !== ""; text: tc.desc; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; wrapMode: Text.WordWrap } }
            Toggle { on: tc.on; onToggled: tc.toggled(); Layout.alignment: Qt.AlignVCenter }
        }
        MouseArea { id: tcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tc.toggled() }
    }

    // icon · fixed-width label · slider · fixed-width readout — columns line up across every slider
    component SliderRow: RowLayout {
        id: sr
        property string icon: ""
        property string label: ""
        property real value: 0
        property string readout: ""
        property color tint: theme.iris
        signal moved(real v)
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
        Sym { text: sr.icon; sz: 18; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
        Text { text: sr.label; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 76 }
        Slider { fill: sr.tint; value: sr.value; onMoved: (v) => sr.moved(v) }
        Text { text: sr.readout; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight }
    }

    // selectable pill for choice groups (resolution, scheme, profile, …)
    component Chip: Rectangle {
        id: ch
        property string label: ""
        property string icon: ""
        property bool on: false
        signal picked()
        implicitWidth: chRow.implicitWidth + 24; implicitHeight: 32; radius: 8
        color: on ? theme.iris : (chMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.16)
        Behavior on color { ColorAnimation { duration: 100 } }
        Row { id: chRow; anchors.centerIn: parent; spacing: 6
            Sym { visible: ch.icon !== ""; anchors.verticalCenter: parent.verticalCenter; text: ch.icon; sz: 15; color: ch.on ? theme.bg : theme.frost }
            Text { anchors.verticalCenter: parent.verticalCenter; text: ch.label; color: ch.on ? theme.bg : theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: ch.on } }
        MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.picked() }
    }

    // accent action button (Apply, Save, …)
    component AccentBtn: Rectangle {
        id: ab
        property string label: ""
        property string icon: ""
        property bool enabled: true
        signal clicked()
        Layout.fillWidth: true; implicitHeight: 40; radius: 9
        opacity: ab.enabled ? 1 : 0.45
        color: abMa.containsMouse && ab.enabled ? theme.iris : theme.a(theme.iris, 0.22)
        border.width: 1; border.color: theme.iris
        Behavior on color { ColorAnimation { duration: 110 } }
        RowLayout { anchors.centerIn: parent; spacing: 8
            Sym { visible: ab.icon !== ""; text: ab.icon; sz: 17; color: abMa.containsMouse && ab.enabled ? theme.bg : theme.frost }
            Text { text: ab.label; color: abMa.containsMouse && ab.enabled ? theme.bg : theme.text; font.pixelSize: 13; font.family: "monospace"; font.bold: true } }
        MouseArea { id: abMa; anchors.fill: parent; hoverEnabled: true; enabled: ab.enabled; cursorShape: Qt.PointingHandCursor; onClicked: ab.clicked() }
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
        property string iconFont: "Material Symbols Outlined"   // set "Symbols Nerd Font" for brand/distro glyphs
        property string label: ""
        property string value: "…"
        Layout.fillWidth: true; implicitHeight: 46; radius: 11
        color: theme.a(theme.line, 0.24); border.width: 1; border.color: theme.a(theme.iris, 0.10)
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 11
            Sym { text: icon; sz: 19; color: theme.iris; font.family: iconFont }
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
        // scale the whole settings window with the UI scale — live-previews as the slider moves.
        // Content is authored native; clamps are in native space so it always fits the screen.
        Binding { target: panel.contentItem; property: "scale"; value: root.uiScale() }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width / root.uiScale() - 60, 960)
            height: Math.min(parent.height / root.uiScale() - 60, 780)
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
                TabBtn { icon: "phonelink";            label: "KDE Connect"; idx: 14 }
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
                            visible: root.tab === 0; Layout.fillWidth: true; spacing: 12
                            Section { title: "output"; icon: "volume_up" }
                            RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                Sym { text: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? "volume_off" : "volume_up"; sz: 18
                                    color: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? theme.faint : theme.sub; Layout.alignment: Qt.AlignVCenter
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (root.curSink && root.curSink.audio) root.curSink.audio.muted = !root.curSink.audio.muted } } }
                                Text { text: "volume"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 76 }
                                Slider { value: (root.curSink && root.curSink.audio) ? root.curSink.audio.volume : 0
                                    onMoved: (v) => { if (root.curSink && root.curSink.audio) { root.curSink.audio.muted = false; root.curSink.audio.volume = v } } }
                                Text { text: (root.curSink && root.curSink.audio) ? Math.round(root.curSink.audio.volume * 100) + "%" : "—"
                                    color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } }
                            RowLayout { visible: root.curSource && root.curSource.audio; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                Sym { text: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? "mic_off" : "mic"; sz: 18
                                    color: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? theme.faint : theme.sub; Layout.alignment: Qt.AlignVCenter
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (root.curSource && root.curSource.audio) root.curSource.audio.muted = !root.curSource.audio.muted } } }
                                Text { text: "microphone"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 76 }
                                Slider { fill: theme.good; value: (root.curSource && root.curSource.audio) ? root.curSource.audio.volume : 0
                                    onMoved: (v) => { if (root.curSource && root.curSource.audio) { root.curSource.audio.muted = false; root.curSource.audio.volume = v } } }
                                Text { text: (root.curSource && root.curSource.audio) ? Math.round(root.curSource.audio.volume * 100) + "%" : "—"
                                    color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } }
                            Text { text: "output device"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 6
                                Repeater { model: root.sinks
                                    delegate: Rectangle { required property var modelData; readonly property bool cur: root.curSink && root.curSink.id === modelData.id
                                        Layout.fillWidth: true; implicitHeight: 38; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (dma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.32))
                                        border.width: 1; border.color: cur ? theme.a(theme.iris,0.5) : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                            Sym { text: cur ? "radio_button_checked" : "radio_button_unchecked"; sz: 16; color: cur ? theme.iris : theme.faint }
                                            Text { text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { text: root.audioFmtBadge(modelData.name); visible: text!==""; color: theme.frost; font.pixelSize: 11; font.family: "monospace"; Layout.alignment: Qt.AlignVCenter }
                                            Text { text: root.audioMaxRate(modelData.name); visible: text!==""; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.alignment: Qt.AlignVCenter } }
                                        MouseArea { id: dma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Pipewire.preferredDefaultAudioSink = modelData } } } }
                            // ---- bluetooth codec (per connected BT output offering a choice) ----
                            Text { visible: root.audioBtSinks.length > 0; text: "bluetooth codec"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            ColumnLayout { visible: root.audioBtSinks.length > 0; Layout.fillWidth: true; spacing: 8
                                Repeater { model: root.audioBtSinks
                                    delegate: ColumnLayout { id: btRow; required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 5
                                        Text { text: btRow.modelData.label; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Flow { Layout.fillWidth: true; Layout.leftMargin: 4; spacing: 6
                                            Repeater { model: btRow.modelData.bt_codecs
                                                delegate: Rectangle { required property var modelData
                                                    readonly property bool on: modelData.active
                                                    implicitHeight: 26; implicitWidth: bcT.implicitWidth + 20; radius: 7
                                                    color: on ? theme.a(theme.iris, 0.25) : (bcMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                                                    border.width: 1; border.color: on ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                                                    Text { id: bcT; anchors.centerIn: parent; text: modelData.codec; color: on ? theme.iris : theme.sub; font.pixelSize: 10; font.family: "monospace"; font.bold: on }
                                                    MouseArea { id: bcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioSetCodec(btRow.modelData.name, modelData.profile) } } } } } } }
                            Text { text: "input device"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 6
                                Repeater { model: root.sources
                                    delegate: Rectangle { required property var modelData; readonly property bool cur: root.curSource && root.curSource.id === modelData.id
                                        Layout.fillWidth: true; implicitHeight: 38; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (sma.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.32))
                                        border.width: 1; border.color: cur ? theme.a(theme.iris,0.5) : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                            Sym { text: cur ? "radio_button_checked" : "radio_button_unchecked"; sz: 16; color: cur ? theme.iris : theme.faint }
                                            Text { text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true } }
                                        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Pipewire.preferredDefaultAudioSource = modelData } } } }
                            Section { title: "per-app volume"; icon: "graphic_eq" }
                            Text { visible: root.streams.length === 0; text: "nothing is playing"; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.leftMargin: 14 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 8
                                Repeater { model: root.streams
                                    delegate: RowLayout { required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                        Sym { text: "music_note"; sz: 16; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                        Text { text: root.streamName(modelData); color: theme.sub; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight; Layout.preferredWidth: 120 }
                                        Slider { fill: theme.iris; value: modelData.audio ? modelData.audio.volume : 0; onMoved: (v) => { if (modelData.audio) modelData.audio.volume = v } }
                                        Text { text: modelData.audio ? Math.round(modelData.audio.volume * 100) + "%" : "—"; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } } } }

                            Section { title: "per-app output"; icon: "alt_route" }
                            Text { visible: root.audioStreams.length === 0; text: "nothing is playing"; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.leftMargin: 14 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 12
                                Repeater { model: root.audioStreams
                                    delegate: ColumnLayout { id: appRow; required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 5
                                        RowLayout { Layout.fillWidth: true; spacing: 8
                                            Sym { text: "graphic_eq"; sz: 15; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                            Text { text: appRow.modelData.app + (appRow.modelData.title ? " — " + appRow.modelData.title : ""); color: theme.sub; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true } }
                                        Flow { Layout.fillWidth: true; Layout.leftMargin: 23; spacing: 6
                                            Repeater { model: root.sinks
                                                delegate: Rectangle { required property var modelData
                                                    readonly property bool here: appRow.modelData.sink_id === modelData.id
                                                    implicitHeight: 24; implicitWidth: chipT.implicitWidth + 18; radius: 7
                                                    color: here ? theme.a(theme.iris, 0.25) : (chipMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                                                    border.width: 1; border.color: here ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                                                    Text { id: chipT; anchors.centerIn: parent; text: modelData.nickname || root.nodeName(modelData); color: here ? theme.iris : theme.sub; font.pixelSize: 10; font.family: "monospace"; font.bold: here }
                                                    MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioRoute(appRow.modelData.id, modelData.name) } } } } } } }
                        }

                        // ================= DISPLAY =================
                        ColumnLayout {
                            visible: root.tab === 1; Layout.fillWidth: true; spacing: 12

                            // ---- brightness ----
                            Section { title: "brightness"; icon: "brightness_6" }
                            SliderRow { icon: "brightness_low"; label: "level"; tint: theme.frost
                                value: root.brightness >= 0 ? root.brightness / 100 : 0
                                readout: root.brightness >= 0 ? root.brightness + "%" : "n/a"
                                onMoved: (v) => root.setBrightness(v * 100) }
                            Text { visible: root.brightness < 0; text: "brightnessctl found no backlight (desktop monitor?)"
                                color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.leftMargin: 14 }

                            // ---- monitor mode ----
                            Section { title: "monitor"; icon: "monitor" }
                            Flow { visible: root.monitors.length > 1; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: root.monitors
                                    delegate: Chip { required property var modelData; required property int index
                                        label: modelData.name; on: root.monSel === index
                                        onPicked: { root.monSel = index; root.selRes = ""; root.reloadMonitors() } } } }
                            Text { text: root.curMon ? (root.curMon.desc + "  ·  now " + root.curMon.curRes + "@" + root.curMon.hz + "Hz") : "reading monitors…"
                                color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.leftMargin: 14 }

                            Text { text: "resolution"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: root.uniqueRes(root.curMon)
                                    delegate: Chip { required property var modelData; label: modelData; on: root.selRes === modelData
                                        onPicked: { root.selRes = modelData; var hs = root.hzFor(root.curMon, modelData); if (hs.length) root.selHz = hs[0] } } } }

                            Text { text: "refresh rate"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: root.hzFor(root.curMon, root.selRes)
                                    delegate: Chip { required property var modelData; label: Math.round(parseFloat(modelData)) + " Hz"; on: root.selHz === modelData
                                        onPicked: root.selHz = modelData } } }

                            Text { text: "orientation"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: [{t:0,i:"stay_current_landscape",l:"landscape"},{t:1,i:"stay_current_portrait",l:"portrait"}]
                                    delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.selTransform === modelData.t
                                        onPicked: root.selTransform = modelData.t } } }

                            AccentBtn { visible: root.curMon !== null; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 4
                                icon: "check"; label: "Apply " + root.selRes + "@" + Math.round(parseFloat(root.selHz || "0")) + "Hz"
                                onClicked: root.applyDisplay() }

                            // ---- layout profiles (save/restore whole monitor arrangements) ----
                            Section { title: "layout profiles"; icon: "dashboard" }
                            Text { text: "save the current monitor arrangement — resolution, position, scale — and restore it in one tap when you dock or unplug."
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

                            Repeater { model: root.displayProfiles
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    implicitHeight: 48; radius: 10
                                    color: dpMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: modelData.matches ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 10; spacing: 12
                                        Sym { text: modelData.matches ? "check_circle" : "dashboard"; sz: 19
                                            color: modelData.matches ? theme.good : theme.sub; Layout.alignment: Qt.AlignVCenter }
                                        ColumnLayout { spacing: 1; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                                            Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { text: modelData.summary + (modelData.created ? "  ·  " + modelData.created : ""); color: theme.faint; font.pixelSize: 10; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true } }
                                        // apply
                                        Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 66; implicitHeight: 30; radius: 8
                                            color: dpApplyMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "play_arrow"; sz: 14; color: dpApplyMa.containsMouse ? theme.bg : theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "apply"; color: dpApplyMa.containsMouse ? theme.bg : theme.frost; font.pixelSize: 11; font.family: "monospace" } }
                                            MouseArea { id: dpApplyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyDisplayProfile(modelData.name) } }
                                        // delete
                                        Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 30; implicitHeight: 30; radius: 8
                                            color: dpDelMa.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"; border.width: 1; border.color: theme.a(theme.bad, dpDelMa.containsMouse ? 0.5 : 0.2)
                                            Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: dpDelMa.containsMouse ? theme.bad : theme.faint }
                                            MouseArea { id: dpDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteDisplayProfile(modelData.name) } }
                                    }
                                    MouseArea { id: dpMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                } }
                            Text { visible: root.displayProfiles.length === 0; text: "no saved layouts yet"; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.leftMargin: 14 }

                            // save-current row
                            RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 2; spacing: 8
                                Rectangle { Layout.fillWidth: true; implicitHeight: 38; radius: 9
                                    color: theme.a(theme.line, 0.5); border.width: 1; border.color: profIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                    TextInput { id: profIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 12; font.family: "monospace"; clip: true; selectByMouse: true
                                        text: root.profName; onTextChanged: root.profName = text
                                        onAccepted: { root.saveDisplayProfile(text); text = "" }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: profIn.text === ""; text: "name this layout…"; color: theme.faint; font.pixelSize: 12; font.family: "monospace" } } }
                                Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 78; implicitHeight: 38; radius: 9
                                    opacity: root.profName.trim() !== "" ? 1 : 0.45
                                    color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                                    Row { anchors.centerIn: parent; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "bookmark_add"; sz: 15; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "save"; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost; font.pixelSize: 11; font.family: "monospace" } }
                                    MouseArea { id: profSaveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.saveDisplayProfile(root.profName); profIn.text = "" } } } }

                            // ---- per-monitor rules ----
                            Section { visible: root.curMon !== null; title: "this monitor" + (root.monitors.length > 1 && root.curMon ? " · " + root.curMon.name : ""); icon: "tv_options_edit_channels" }
                            ToggleCard { visible: root.curMon !== null
                                icon: (root.curMon && root.monBarAp(root.curMon.name)) ? "web_asset" : "web_asset_off"
                                title: "show bar"; desc: "display the sea-shell bar on this output"
                                on: root.curMon ? root.monBarAp(root.curMon.name) : true
                                onToggled: if (root.curMon) root.setMon(root.curMon.name, "bar", !root.monBarAp(root.curMon.name)) }
                            ToggleCard { id: ovrScaleCard; visible: root.curMon !== null
                                icon: "zoom_out_map"; title: "override scale"
                                desc: ovrScaleCard.on ? ("this monitor: " + root.monScaleAp(root.curMon.name).toFixed(2) + "×") : "use the global / auto scale"
                                on: root.curMon ? (root.monScaleAp(root.curMon.name) > 0) : false
                                onToggled: if (root.curMon) root.setMon(root.curMon.name, "scale", root.monScaleAp(root.curMon.name) > 0 ? 0 : Math.max(1.0, root.autoScaleEstimate())) }
                            SliderRow { visible: root.curMon !== null && root.monScaleAp(root.curMon.name) > 0
                                icon: "aspect_ratio"; label: "scale"
                                value: root.curMon ? (root.monScaleAp(root.curMon.name) - 0.75) / 1.75 : 0
                                readout: (root.curMon ? root.monScaleAp(root.curMon.name).toFixed(2) : "1.00") + "×"
                                onMoved: (v) => { if (root.curMon) root.setMon(root.curMon.name, "scale", Math.round((0.75 + v * 1.75) * 20) / 20) } }

                            // ---- global display scale ----
                            Section { title: "display scale"; icon: "aspect_ratio" }
                            ToggleCard { icon: "aspect_ratio"; title: "auto scale (match display)"
                                desc: "sizes the whole shell per monitor — a 4K TV scales up, 1080p stays 1×"
                                on: root.apScale === 0
                                onToggled: { root.apScale = (root.apScale === 0) ? Math.max(1.0, root.autoScaleEstimate()) : 0; root.saveAppearance() } }
                            SliderRow { visible: root.apScale > 0; icon: "zoom_out_map"; label: "UI scale"
                                value: (root.apScale - 0.75) / 1.75; readout: root.apScale.toFixed(2) + "×"
                                onMoved: (v) => { root.apScale = Math.round((0.75 + v * 1.75) * 20) / 20; root.saveAppearance() } }
                            Text { visible: root.apScale > 0; text: "bump this up when projecting to a TV and everything looks too small"
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

                            // ---- night light ----
                            Section { title: "night light"; icon: "nightlight" }
                            ToggleCard { icon: "routine"; title: "follow dark mode"
                                desc: "warm the screen automatically whenever the shell is in dark mode"
                                on: root.apNightAuto
                                onToggled: { root.apNightAuto = !root.apNightAuto; root.saveAppearance() } }
                            ToggleCard { visible: !root.apNightAuto; icon: "nightlight"; title: "night light"
                                desc: "warm the screen now (also toggleable from the Control Center)"
                                on: root.apNight
                                onToggled: { root.apNight = !root.apNight; root.saveAppearance() } }
                            SliderRow { icon: "thermostat"; label: "warmth"; tint: theme.warn
                                value: (6000 - root.apNightTemp) / 3500; readout: root.apNightTemp + "K"
                                onMoved: (v) => { root.apNightTemp = Math.round((6000 - v * 3500) / 100) * 100; root.saveAppearance() } }
                            Text { text: "lower = warmer/oranger. Needs the hyprsunset package (bundled with the installer)."
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }
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
                                visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 12
                                Section { title: "theme"; icon: "contrast" }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                    Repeater { model: [{k:false,l:"dark",i:"dark_mode"},{k:true,l:"light",i:"light_mode"}]
                                        delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.apLight===modelData.k
                                            onPicked: { root.apLight=modelData.k; root.saveAppearance() } } } }
                                ToggleCard { icon: "bedtime"; title: "auto dark by time"
                                    desc: "dark inside the window · overrides the manual pick + the SUPER+⇧+D key"
                                    on: root.apAutoDark; onToggled: { root.apAutoDark=!root.apAutoDark; root.saveAppearance() } }
                                RowLayout { visible: root.apAutoDark; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                    Sym { text: "schedule"; sz: 18; color: theme.sub }
                                    Text { text: "dark from"; color: theme.sub; font.pixelSize: 12; font.family: "monospace" }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: 8; color: theme.a(theme.line,0.5); border.width: 1; border.color: dstart.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dstart; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: "monospace"; inputMask: "99:99;_"; text: root.apDarkStart
                                            onEditingFinished: { root.apDarkStart = text; root.saveAppearance() } } }
                                    Text { text: "to"; color: theme.sub; font.pixelSize: 12; font.family: "monospace" }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: 8; color: theme.a(theme.line,0.5); border.width: 1; border.color: dend.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dend; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: "monospace"; inputMask: "99:99;_"; text: root.apDarkEnd
                                            onEditingFinished: { root.apDarkEnd = text; root.saveAppearance() } } }
                                    Item { Layout.fillWidth: true } }

                                Section { title: "app preference"; icon: "apps" }
                                Text { text: "controls GTK / Qt app themes independently from the shell"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14 }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                    Repeater { model: [{k:"auto",l:"auto",i:"sync"},{k:"dark",l:"dark",i:"dark_mode"},{k:"light",l:"light",i:"light_mode"}]
                                        delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.apAppMode===modelData.k
                                            onPicked: { root.apAppMode=modelData.k; root.saveAppearance(); root.applyAppMode() } } } }
                                Text { visible: root.apAppMode!=="auto"; text: "apps will stay " + root.apAppMode + " regardless of shell theme"; color: theme.iris; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14 }

                                Section { title: "bar shape"; icon: "tune" }
                                SliderRow { icon: "rounded_corner"; label: "roundness"; value: root.apRadius/26; readout: Math.round(root.apRadius)+"px"
                                    onMoved: (v)=>{ root.apRadius = v*26; root.saveAppearance() } }
                                RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                    Sym { text: "dock_to_right"; sz: 18; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                    Text { text: "position"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 76 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: root.edges
                                            delegate: Chip { required property var modelData; label: modelData; on: root.apEdge===modelData
                                                onPicked: { root.apEdge=modelData; root.saveAppearance() } } } } }
                                SliderRow { icon: "opacity"; label: "opacity"; tint: theme.frost; value: root.apOpacity; readout: Math.round(root.apOpacity*100)+"%"
                                    onMoved: (v)=>{ root.apOpacity = v; root.saveAppearance() } }
                                Text { visible: root.apOpacity < 0.06; text: "↑ 0% hides the bar background — only the buttons show"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14 }
                                RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                    Sym { text: "format_color_fill"; sz: 18; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                    Text { text: "bar fill"; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; Layout.minimumWidth: 76 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: [{k:"matugen",l:"matugen"},{k:"black",l:"black"},{k:"white",l:"white"}]
                                            delegate: Chip { required property var modelData; label: modelData.l; on: root.apBarFill===modelData.k
                                                onPicked: { root.apBarFill=modelData.k; root.saveAppearance() } } } } }
                                Text { visible: root.apBarFill!=="matugen" && root.apOpacity<0.99; text: "↑ set opacity to 100% for a solid " + root.apBarFill + " bar"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14 }
                                SliderRow { icon: "height"; label: "bar height"; tint: theme.good; value: (root.apHeight-34)/20; readout: Math.round(root.apHeight)+"px"
                                    onMoved: (v)=>{ root.apHeight = 34 + v*20; root.saveAppearance() } }
                                ToggleCard { icon: "swipe_up"; title: "auto-hide bar"; desc: "tucks the bar away · push the cursor to the edge to reveal it"
                                    on: root.apAutoHide; onToggled: { root.apAutoHide=!root.apAutoHide; root.saveAppearance() } }
                                ToggleCard { visible: !root.apAutoHide; icon: "fullscreen"; title: "hide when fullscreen"; desc: "only auto-hides while a window is fullscreen (e.g. video, games)"
                                    on: root.apHideFullscreen; onToggled: { root.apHideFullscreen=!root.apHideFullscreen; root.saveAppearance() } }
                            }

                            // SUB-TAB 1: Colors
                            ColumnLayout {
                                visible: root.apSubTab === 1; Layout.fillWidth: true; spacing: 12
                                Section { title: "accent colour"; icon: "palette" }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                    Repeater { model: root.accents
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                            width: 40; height: 40; radius: 20; color: modelData
                                            border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                            Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 20; color: "#0d1420" }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.apAccent=modelData; root.saveAppearance(); run("sh '"+root.matugenScript+"'") } } } } }
                                ToggleCard { icon: "colorize"; title: "auto colours from wallpaper"
                                    desc: "recolours the shell + kitty on every wallpaper · off = sea cyan"
                                    on: root.apMatugen; onToggled: root.toggleMatugen() }
                                ColumnLayout { Layout.fillWidth: true; spacing: 8; visible: root.apMatugen
                                    RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                        Sym { text: "tune"; sz: 15; color: theme.faint }
                                        Text { text: "colour scheme"; color: theme.sub; font.pixelSize: 12; font.family: "monospace" }
                                        Item { Layout.fillWidth: true }
                                        Text { text: root.apScheme.replace("scheme-",""); color: theme.frost; font.pixelSize: 11; font.family: "monospace" } }
                                    Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                        Repeater { model: root.schemes
                                            delegate: Chip { required property var modelData; label: (""+modelData).replace("scheme-",""); on: root.apScheme===modelData
                                                onPicked: root.setScheme(modelData) } } } }
                                RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    AccentBtn { icon: root.matugenBusy?"sync":"auto_awesome"; label: root.matugenBusy ? "matching…" : "pick a palette from wallpaper"; onClicked: root.matchWallpaper() }
                                    AccentBtn { Layout.fillWidth: false; implicitWidth: 104; icon: "colorize"; label: "picker"; onClicked: { root.pickingTarget = "accent"; colorPickerProc.running = true } } }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 9; visible: root.matugenPalette.length>0
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
                                visible: root.apSubTab === 3; Layout.fillWidth: true; spacing: 12
                                Section { title: "font"; icon: "font_download" }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                    Repeater { model: root.fontPresets
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apFont===modelData
                                            implicitWidth: ft.implicitWidth+22; implicitHeight: 32; radius: 8
                                            color: sel?theme.iris:(fmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                            Text { id: ft; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: modelData; font.bold: sel }
                                            MouseArea { id: fmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apFont=modelData; root.saveAppearance() } } } } }
                                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; implicitHeight: 38; radius: 9
                                    color: theme.a(theme.line,0.4); border.width: 1; border.color: fontIn.activeFocus?theme.iris:theme.a(theme.iris,0.16)
                                    TextInput { id: fontIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 13; font.family: root.apFont; clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris,0.4)
                                        Component.onCompleted: text = root.apFont
                                        onAccepted: root.addCustomFont(text)
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: fontIn.text===""; text: "type a font name, ↵ to save it as a chip"; color: theme.faint; font.pixelSize: 13; font.family: root.apFont } } }
                                Text { text: "changes apply to the bar live"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.leftMargin: 14 }
                            }
                        }

                        // ================= BAR WIDGETS =================
                        ColumnLayout {
                            visible: root.tab === 12; Layout.fillWidth: true; spacing: 14
                            Section { title: "bar widgets"; icon: "widgets" }
                            Text {
                                text: "toggle widgets on/off, and drag the ⠿ handle to reorder where they sit on the bar. Media Player always stays centred."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            // drag-to-reorder list. ListView (non-interactive so the settings page still
                            // scrolls) over wgOrderModel; dragging the handle moves rows via ListModel.move
                            // and commits the new order to apWidgetOrder on release.
                            ListView {
                                id: wgList
                                Layout.fillWidth: true
                                Layout.preferredHeight: contentHeight
                                interactive: false
                                spacing: 8
                                cacheBuffer: 100000
                                model: wgOrderModel
                                displaced: Transition { NumberAnimation { properties: "y"; duration: 150; easing.type: Easing.OutCubic } }
                                delegate: Item {
                                    id: wrap
                                    required property int index
                                    required property string wid
                                    readonly property var meta: root.wgMeta[wrap.wid] || ({})
                                    readonly property bool hasToggle: (wrap.meta.prop || "") !== ""
                                    readonly property bool enabledVal: wrap.hasToggle ? root[wrap.meta.prop] : true
                                    property bool held: false
                                    width: wgList.width; height: 52
                                    z: held ? 2 : 1

                                    Rectangle {
                                        id: card
                                        width: wrap.width; height: wrap.height; radius: 9
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: theme.a(theme.line, wrap.held ? 0.75 : 0.4)
                                        border.width: 1; border.color: wrap.held ? theme.iris : (wrap.enabledVal ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.16))
                                        Drag.active: wrap.held
                                        Drag.source: wrap
                                        Drag.hotSpot.x: width / 2; Drag.hotSpot.y: height / 2
                                        states: State {
                                            when: wrap.held
                                            ParentChange { target: card; parent: wgList }
                                            AnchorChanges { target: card; anchors.horizontalCenter: undefined; anchors.verticalCenter: undefined }
                                        }
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 14; spacing: 10
                                            // drag handle — grabbing this reorders the row
                                            MouseArea {
                                                id: handle
                                                Layout.preferredWidth: 24; Layout.fillHeight: true
                                                cursorShape: Qt.SizeVerCursor
                                                drag.target: card; drag.axis: Drag.YAxis
                                                onPressed: { root.wgDragging = true; wrap.held = true }
                                                onReleased: { wrap.held = false; root.wgCommitOrder(); root.wgDragging = false }
                                                Sym { anchors.centerIn: parent; text: "drag_indicator"; sz: 18; color: wrap.held ? theme.iris : theme.faint }
                                            }
                                            Sym { text: wrap.meta.i || "widgets"; sz: 19; color: wrap.enabledVal ? theme.frost : theme.faint }
                                            ColumnLayout {
                                                spacing: 1; Layout.fillWidth: true
                                                Text { text: wrap.meta.l || wrap.wid; color: theme.text; font.pixelSize: 13; font.family: root.apFont
                                                    Layout.fillWidth: true; elide: Text.ElideRight }
                                                Text { text: wrap.meta.d || ""; color: theme.faint; font.pixelSize: 10; font.family: root.apFont
                                                    Layout.fillWidth: true; elide: Text.ElideRight }
                                            }
                                            // toggle (hidden for no-toggle widgets like the recorder)
                                            Rectangle {
                                                visible: wrap.hasToggle
                                                Layout.alignment: Qt.AlignVCenter
                                                implicitWidth: 46; implicitHeight: 22; radius: 11
                                                color: wrap.enabledVal ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: wrap.enabledVal ? theme.iris : theme.a(theme.iris, 0.3)
                                                Rectangle {
                                                    width: 16; height: 16; radius: 8; y: 3; x: wrap.enabledVal ? 27 : 3
                                                    color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (wrap.hasToggle) { root[wrap.meta.prop] = !wrap.enabledVal; root.saveAppearance() } }
                                                }
                                            }
                                        }
                                    }
                                    DropArea {
                                        anchors.fill: parent
                                        onEntered: (drag) => {
                                            var from = drag.source.index; var to = wrap.index;
                                            if (from !== to && from >= 0) wgOrderModel.move(from, to, 1);
                                        }
                                    }
                                }
                            }
                            // ---- left cluster order (logo · workspaces · window-title) ----
                            Section { title: "left side"; icon: "align_horizontal_left"; Layout.topMargin: 8 }
                            Text {
                                text: "drag to reorder the items on the left of the bar."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            ListView {
                                id: lgList
                                Layout.fillWidth: true
                                Layout.preferredHeight: contentHeight
                                interactive: false
                                spacing: 8
                                cacheBuffer: 100000
                                model: lgOrderModel
                                displaced: Transition { NumberAnimation { properties: "y"; duration: 150; easing.type: Easing.OutCubic } }
                                delegate: Item {
                                    id: lwrap
                                    required property int index
                                    required property string wid
                                    readonly property var meta: root.lgMeta[lwrap.wid] || ({})
                                    property bool held: false
                                    width: lgList.width; height: 46
                                    z: held ? 2 : 1
                                    Rectangle {
                                        id: lcard
                                        width: lwrap.width; height: lwrap.height; radius: 9
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: theme.a(theme.line, lwrap.held ? 0.75 : 0.4)
                                        border.width: 1; border.color: lwrap.held ? theme.iris : theme.a(theme.iris, 0.5)
                                        Drag.active: lwrap.held
                                        Drag.source: lwrap
                                        Drag.hotSpot.x: width / 2; Drag.hotSpot.y: height / 2
                                        states: State {
                                            when: lwrap.held
                                            ParentChange { target: lcard; parent: lgList }
                                            AnchorChanges { target: lcard; anchors.horizontalCenter: undefined; anchors.verticalCenter: undefined }
                                        }
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 14; spacing: 10
                                            MouseArea {
                                                id: lhandle
                                                Layout.preferredWidth: 24; Layout.fillHeight: true
                                                cursorShape: Qt.SizeVerCursor
                                                drag.target: lcard; drag.axis: Drag.YAxis
                                                onPressed: { root.wgDragging = true; lwrap.held = true }
                                                onReleased: { lwrap.held = false; root.lgCommitOrder(); root.wgDragging = false }
                                                Sym { anchors.centerIn: parent; text: "drag_indicator"; sz: 18; color: lwrap.held ? theme.iris : theme.faint }
                                            }
                                            Sym { text: lwrap.meta.i || "widgets"; sz: 19; color: theme.frost }
                                            ColumnLayout {
                                                spacing: 1; Layout.fillWidth: true
                                                Text { text: lwrap.meta.l || lwrap.wid; color: theme.text; font.pixelSize: 13; font.family: root.apFont
                                                    Layout.fillWidth: true; elide: Text.ElideRight }
                                                Text { text: lwrap.meta.d || ""; color: theme.faint; font.pixelSize: 10; font.family: root.apFont
                                                    Layout.fillWidth: true; elide: Text.ElideRight }
                                            }
                                        }
                                    }
                                    DropArea {
                                        anchors.fill: parent
                                        onEntered: (drag) => {
                                            var from = drag.source.index; var to = lwrap.index;
                                            if (from !== to && from >= 0) lgOrderModel.move(from, to, 1);
                                        }
                                    }
                                }
                            }
                            // ---- bar layout presets (save/restore the whole bar layout) ----
                            Section { title: "layout presets"; icon: "bookmarks"; Layout.topMargin: 8 }
                            Text {
                                text: "save the current widget order, left-side order and on/off toggles as a named preset, then restore it in one click."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 4
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 36; radius: 7
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: blNameIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    TextInput {
                                        id: blNameIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 12; font.family: root.apFont; clip: true
                                        onAccepted: { root.saveBarLayout(text); text = "" }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: !blNameIn.text; text: "layout name…"; color: theme.faint; font.pixelSize: 12; font.family: root.apFont }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 84; implicitHeight: 36; radius: 7
                                    color: blSaveMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                                    enabled: blNameIn.text.trim() !== ""; opacity: enabled ? 1 : 0.5
                                    Row { anchors.centerIn: parent; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "save"; sz: 15; color: blSaveMa.containsMouse ? theme.bg : theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "save"; color: blSaveMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 12; font.family: root.apFont } }
                                    MouseArea { id: blSaveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.saveBarLayout(blNameIn.text); blNameIn.text = "" } }
                                }
                            }
                            Text { visible: root.barLayouts.length === 0; text: "no saved layouts yet."; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.topMargin: 2 }
                            Repeater { model: root.barLayouts
                                delegate: Rectangle { required property var modelData; required property int index
                                    Layout.fillWidth: true; implicitHeight: 44; radius: 9
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                                        Sym { text: "bookmark"; sz: 17; color: theme.frost }
                                        Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                                        Rectangle { implicitWidth: 70; implicitHeight: 28; radius: 7
                                            color: blLoadMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.18); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                            Text { anchors.centerIn: parent; text: "load"; color: blLoadMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont }
                                            MouseArea { id: blLoadMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.loadBarLayout(modelData) } }
                                        Rectangle { implicitWidth: 30; implicitHeight: 28; radius: 7
                                            color: blDelMa.containsMouse ? theme.a(theme.bad, 0.25) : theme.a(theme.line, 0.5)
                                            Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: blDelMa.containsMouse ? theme.bad : theme.faint }
                                            MouseArea { id: blDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteBarLayout(index) } } }
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
                                Row2 { icon: "restart_alt"; label: "Restart bar"; cmd: "pkill -xf 'qs -c sea-shell'; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('qs -c sea-shell')\""; quitAfter: true }
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
                                        Text { text: "type to filter · click a bind to edit it"; visible: kbField.text===""
                                            color: theme.faint; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                        Keys.onPressed: (e)=> {
                                            if (e.key === Qt.Key_Escape) { root.closePanel(); e.accepted = true; }
                                        }
                                    }
                                }
                                // Add Button → opens the editor popup in "add" mode
                                Rectangle {
                                    implicitWidth: 32; implicitHeight: 32; radius: 8
                                    color: kbAddBtnMa.containsMouse ? theme.iris : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.2)
                                    Sym { anchors.centerIn: parent; text: "add"; sz: 18; color: kbAddBtnMa.containsMouse ? theme.bg : theme.frost }
                                    MouseArea {
                                        id: kbAddBtnMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.kbOpenAdd()
                                    }
                                }
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
                                            onClicked: { if (modelData.canEdit) root.kbOpenEdit(modelData) } }
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
                                            // distro logo: CachyOS is drawn (no Nerd glyph exists); everything else uses the Font Logos glyph
                                            CachyLogo { visible: root.sysInfo.id === "cachyos"; size: 15; color: theme.faint; Layout.leftMargin: 6 }
                                            Text { visible: root.sysInfo.id !== "cachyos"; text: root.distroGlyph(root.sysInfo.id, root.sysInfo.idlike)
                                                font.family: "Symbols Nerd Font"; font.pixelSize: 14; color: theme.faint; Layout.leftMargin: 6 }
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
                                InfoTile { icon: root.nfKernel; iconFont: "Symbols Nerd Font"; label: "KERNEL"; value: root.sysInfo.kernel || "…" }
                                InfoTile { icon: root.nfHypr;   iconFont: "Symbols Nerd Font"; label: "COMPOSITOR"; value: root.sysInfo.wm ? ("Hyprland " + root.sysInfo.wm) : "Hyprland" }
                                InfoTile { iconFont: "Symbols Nerd Font"; label: "SESSION"
                                    icon: (root.sysInfo.session === "x11" || root.sysInfo.session === "tty") ? root.nfXorg : root.nfWayland
                                    value: root.sysInfo.session ? (root.sysInfo.session.charAt(0).toUpperCase() + root.sysInfo.session.slice(1)) : "Wayland" }
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

                        // ================= KDE CONNECT =================
                        ColumnLayout {
                            visible: root.tab === 14; Layout.fillWidth: true; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "phonelink"; sz: 18; color: theme.iris }
                                Text { text: "kde connect"; color: theme.iris; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Sym { text: "sync"; sz: 16; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.reloadKde() } }
                            }
                            ColumnLayout {
                                visible: root.kdeDevices.length === 0; Layout.fillWidth: true; spacing: 2
                                Text { text: "no devices found"; color: theme.sub; font.pixelSize: 12; font.family: "monospace" }
                                Text { text: "open KDE Connect on the other device, on the same network, then refresh"
                                    color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: root.kdeDevices
                                    delegate: Rectangle {
                                        id: kdeCard
                                        required property var modelData
                                        readonly property bool online: modelData.isPaired && modelData.isReachable
                                        Layout.fillWidth: true; radius: 10
                                        implicitHeight: kdeCardCol.implicitHeight + 22
                                        color: online ? theme.a(theme.iris, 0.14) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: online ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.12)
                                        ColumnLayout {
                                            id: kdeCardCol
                                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                            anchors.margins: 11; spacing: 9
                                            // name + state
                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 10
                                                Rectangle {
                                                    implicitWidth: 36; implicitHeight: 36; radius: 11
                                                    color: kdeCard.online ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.5)
                                                    Sym { anchors.centerIn: parent; sz: 19
                                                        text: kdeCard.modelData.type === "phone" ? "smartphone"
                                                            : (kdeCard.modelData.type === "tablet" ? "tablet_android"
                                                            : (kdeCard.modelData.type === "tv" ? "tv" : "computer"))
                                                        color: kdeCard.online ? theme.iris : theme.faint }
                                                }
                                                ColumnLayout {
                                                    spacing: 2; Layout.fillWidth: true
                                                    Text { text: kdeCard.modelData.name; color: theme.text; font.pixelSize: 13; font.family: "monospace"; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    RowLayout {
                                                        spacing: 6
                                                        Text {
                                                            text: !kdeCard.modelData.isPaired
                                                                    ? (kdeCard.modelData.isPairRequestedByPeer ? "wants to pair"
                                                                       : (kdeCard.modelData.isPairRequested ? "waiting for a reply…" : "not paired"))
                                                                    : (kdeCard.modelData.isReachable
                                                                       ? ("online" + (kdeCard.modelData.network ? " · " + kdeCard.modelData.network : ""))
                                                                       : "away")
                                                            color: kdeCard.online ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace"
                                                        }
                                                        Text { visible: kdeCard.modelData.address !== ""
                                                            text: "· " + kdeCard.modelData.address; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                                                        // cellular strength, 0–4 bars
                                                        Row {
                                                            visible: kdeCard.modelData.signal >= 0
                                                            spacing: 2; height: 11
                                                            Repeater { model: 4
                                                                delegate: Rectangle { required property int index
                                                                    width: 3; height: 4 + index * 2; radius: 1; anchors.bottom: parent.bottom
                                                                    color: index < kdeCard.modelData.signal ? theme.frost : theme.a(theme.faint, 0.35) } }
                                                        }
                                                    }
                                                }
                                                Sym { visible: kdeCard.modelData.isCharging; text: "bolt"; sz: 15; color: theme.good }
                                            }
                                            // battery — NOT the Meter component: that one goes red
                                            // above 88%, which is right for RAM and backwards for a battery
                                            RowLayout {
                                                visible: kdeCard.modelData.charge >= 0
                                                Layout.fillWidth: true; spacing: 11
                                                Text { text: "battery"; color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.preferredWidth: 58 }
                                                Rectangle {
                                                    Layout.fillWidth: true; implicitHeight: 9; radius: 5; color: theme.a(theme.line, 0.8)
                                                    Rectangle {
                                                        height: parent.height; radius: 5
                                                        width: parent.width * Math.max(0, Math.min(1, kdeCard.modelData.charge / 100))
                                                        color: kdeCard.modelData.isCharging ? theme.good
                                                             : (kdeCard.modelData.charge <= 20 ? theme.bad : theme.iris)
                                                        Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                                                    }
                                                }
                                                Text {
                                                    text: kdeCard.modelData.charge + "%" + (kdeCard.modelData.isCharging ? " charging" : "")
                                                    color: theme.sub; font.pixelSize: 11; font.family: "monospace"
                                                    Layout.preferredWidth: 96; horizontalAlignment: Text.AlignRight
                                                }
                                            }
                                            // what you can actually do with it
                                            Flow {
                                                visible: kdeCard.online
                                                Layout.fillWidth: true; spacing: 6
                                                Chip { label: "ring"; icon: "ring_volume"; enabled: kdeCard.modelData.canRing; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--ring", kdeCard.modelData.id]) }
                                                Chip { label: "ping"; icon: "wifi_tethering"; enabled: kdeCard.modelData.canPing; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--ping", kdeCard.modelData.id]) }
                                                Chip { label: "send file"; icon: "upload_file"; enabled: kdeCard.modelData.canShare; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--send-file", kdeCard.modelData.id]) }
                                                Chip { label: "clipboard"; icon: "content_paste_go"; enabled: kdeCard.modelData.canShare; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--send-clipboard", kdeCard.modelData.id]) }
                                                Chip { label: "browse files"; icon: "folder_open"; enabled: kdeCard.modelData.canBrowse; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--browse", kdeCard.modelData.id]) }
                                                Chip { label: "messages"; icon: "sms"; enabled: kdeCard.modelData.canSms; opacity: enabled ? 1 : 0.4
                                                    onPicked: root.kdeAction(["--sms", kdeCard.modelData.id]) }
                                            }
                                            // pairing
                                            Text {
                                                visible: kdeCard.modelData.isPairRequestedByPeer || kdeCard.modelData.isPairRequested
                                                text: "verification key " + kdeCard.modelData.verificationKey + " — it must match the one on the device"
                                                color: theme.sub; font.pixelSize: 10; font.family: "monospace"; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                            }
                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 6
                                                Chip { visible: kdeCard.modelData.isPairRequestedByPeer; label: "accept"; icon: "check_circle"
                                                    onPicked: root.kdeAction(["--accept", kdeCard.modelData.id]) }
                                                Chip { visible: kdeCard.modelData.isPairRequestedByPeer; label: "reject"; icon: "cancel"
                                                    onPicked: root.kdeAction(["--reject", kdeCard.modelData.id]) }
                                                Chip {
                                                    visible: !kdeCard.modelData.isPaired && kdeCard.modelData.isReachable
                                                             && !kdeCard.modelData.isPairRequested && !kdeCard.modelData.isPairRequestedByPeer
                                                    label: "pair"; icon: "link"
                                                    onPicked: root.kdeAction(["--pair", kdeCard.modelData.id]) }
                                                Item { Layout.fillWidth: true }
                                                Text {
                                                    visible: kdeCard.modelData.isPaired
                                                    text: "unpair"; color: unpairMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.85)
                                                    font.pixelSize: 11; font.family: "monospace"
                                                    MouseArea { id: unpairMa; anchors.fill: parent; anchors.margins: -7; hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor; onClicked: root.kdeAction(["--unpair", kdeCard.modelData.id]) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "the bar widget has the same shortcuts — click the phone pill for battery, ring, send file, clipboard and file browsing"
                                color: theme.faint; font.pixelSize: 10; font.family: "monospace"
                            }
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

                                // Laptop Lid Close
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "laptop"; sz: 20; color: theme.frost }
                                    Text { text: "lid close action"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
                                    Item { Layout.fillWidth: true }
                                    RowLayout { spacing: 6
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
                                                readonly property bool sel: root.lockLidAction === modelData.v
                                                implicitWidth: chipLidRow.implicitWidth + 18; implicitHeight: 26; radius: 6
                                                color: sel ? theme.iris : (chipLidMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                RowLayout {
                                                    id: chipLidRow
                                                    anchors.centerIn: parent; spacing: 4
                                                    Sym { text: modelData.i; sz: 14; color: sel ? theme.bg : (chipLidMa.containsMouse ? theme.frost : theme.sub) }
                                                    Text { text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                }
                                                MouseArea {
                                                    id: chipLidMa
                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        root.lockLidAction = modelData.v;
                                                        root.saveLockSettings();
                                                        root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"; hyprctl reload");
                                                    }
                                                }
                                            }
                                        }
                                    }
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
                                            root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"");
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
                            Section { title: "laptop lid action"; icon: "laptop" }
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
                                        Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                        color: cur ? theme.a(theme.iris, 0.2) : (ppmLid.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.centerIn: parent; spacing: 6
                                            Sym { text: modelData.i; sz: 15; color: cur ? theme.iris : theme.frost }
                                            Text { text: modelData.l; color: cur ? theme.frost : theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: cur } }
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
                            Section { title: "session"; icon: "power_settings_new" }
                            GridLayout {
                                columns: 2; columnSpacing: 10; rowSpacing: 8; Layout.fillWidth: true
                                Row2 { icon: "lock"; label: "Lock"; cmd: "~/.config/quickshell/sea-shell/sea-lock.sh"; quitAfter: true }
                                Row2 { icon: "bedtime"; label: "Suspend"; cmd: "systemctl suspend"; quitAfter: true }
                                Row2 { icon: "logout"; label: "Logout"; cmd: "systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }"; quitAfter: true }
                                Row2 { icon: "restart_alt"; label: "Reboot"; cmd: "systemctl reboot"; tint: theme.bad; quitAfter: true }
                                Row2 { icon: "power_settings_new"; label: "Shutdown"; cmd: "systemctl poweroff"; tint: theme.bad; quitAfter: true }
                            }
                        }
                    }
                }

            // ================= KEYBIND EDITOR POPUP =================
            Item {
                id: kbModal
                anchors.fill: parent
                visible: root.kbRec !== null || root.kbAdding
                // dim backdrop — clicking it cancels
                Rectangle { anchors.fill: parent; radius: 18; color: Qt.rgba(0,0,0,0.55)
                    MouseArea { anchors.fill: parent; onClicked: root.kbCloseEditor() } }
                // focus sink: captures the key press while recording a shortcut
                Item {
                    id: kbCapture
                    anchors.fill: parent
                    focus: kbModal.visible
                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Escape) { root.kbCloseEditor(); e.accepted = true; return; }
                        if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted = true; return; }
                        if (root.kbRec && root.kbRecRecording) {
                            var n = root.kbKeyName(e);
                            if (n) { root.kbRecKey = n; root.kbRecRecording = false; root.kbConflict = ""; } else root.kbConflict = "unsupported key";
                            e.accepted = true;
                        } else if (root.kbAdding && root.kbAddRecording) {
                            var k = root.kbKeyName(e);
                            if (k) { root.kbAddKey = k; root.kbAddRecording = false; }
                            e.accepted = true;
                        }
                    }
                }
                // dialog card
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 80, 440)
                    implicitHeight: kbDlg.implicitHeight + 36
                    height: implicitHeight
                    radius: 14
                    color: theme.a(theme.panel, 0.99)
                    border.width: 1; border.color: theme.a(theme.iris, 0.4)
                    MouseArea { anchors.fill: parent }   // swallow clicks so they don't hit the dim
                    ColumnLayout {
                        id: kbDlg
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 18 }
                        spacing: 12
                        // header
                        RowLayout { Layout.fillWidth: true; spacing: 10
                            Sym { text: root.kbAdding ? "add_circle" : "keyboard"; sz: 20; color: theme.frost }
                            Text { Layout.fillWidth: true; elide: Text.ElideRight
                                text: root.kbAdding ? "new keybind" : (root.kbRec ? root.kbRec.desc : "")
                                color: theme.text; font.pixelSize: 15; font.family: "monospace"; font.bold: true }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: 14
                                color: kbXMa.containsMouse ? theme.a(theme.bad,0.25) : "transparent"
                                Sym { anchors.centerIn: parent; text: "close"; sz: 16; color: kbXMa.containsMouse ? theme.bad : theme.faint }
                                MouseArea { id: kbXMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                        }
                        // add-mode only: description + action inputs
                        ColumnLayout { visible: root.kbAdding; spacing: 4; Layout.fillWidth: true
                            Text { text: "description"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: 6; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbDescIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbDescIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: "monospace"; clip: true; text: root.kbAddDesc; onTextChanged: root.kbAddDesc = text
                                    Text { visible: kbDescIn2.text===""; text: "e.g. Launch Firefox"; color: theme.faint; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter } } }
                            Text { text: "action / command"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.topMargin: 4 }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: 6; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbActIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbActIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: "monospace"; clip: true; text: root.kbAddAction; onTextChanged: root.kbAddAction = text } }
                        }
                        // shortcut picker (both modes)
                        Text { text: "shortcut"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                        Flow { Layout.fillWidth: true; spacing: 6
                            Repeater { model: ["SUPER","CTRL","ALT","SHIFT"]
                                delegate: Rectangle { required property string modelData
                                    readonly property var mods: root.kbAdding ? root.kbAddMods : root.kbRecMods
                                    readonly property bool on: mods.indexOf(modelData) >= 0
                                    width: kmcT.width + 16; height: 26; radius: 8
                                    color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5); border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                    Text { id: kmcT; anchors.centerIn: parent; text: modelData; color: on ? theme.frost : theme.faint; font.pixelSize: 11; font.family: "monospace"; font.bold: on }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.kbAdding) { var m = root.kbAddMods.slice(); var i = m.indexOf(modelData); if(i>=0)m.splice(i,1); else m.push(modelData); root.kbAddMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m.indexOf(x)>=0); }
                                            else { var m2 = root.kbRecMods.slice(); var j = m2.indexOf(modelData); if(j>=0)m2.splice(j,1); else m2.push(modelData); root.kbRecMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m2.indexOf(x)>=0); root.kbConflict=""; }
                                        } } }
                            }
                        }
                        // key capture
                        RowLayout { Layout.fillWidth: true; spacing: 10
                            Text { text: "key"; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; Layout.minimumWidth: 30 }
                            Rectangle { id: kbKeyBox; Layout.fillWidth: true; implicitHeight: 34; radius: 8
                                readonly property bool rec: root.kbAdding ? root.kbAddRecording : root.kbRecRecording
                                readonly property string keyv: root.kbAdding ? root.kbAddKey : root.kbRecKey
                                color: rec ? theme.a(theme.bad,0.18) : theme.a(theme.line,0.4); border.width: 1; border.color: rec ? theme.bad : theme.a(theme.iris,0.3)
                                Text { anchors.centerIn: parent
                                    text: kbKeyBox.rec ? "press a key…" : (kbKeyBox.keyv ? root.kbPretty(kbKeyBox.keyv) : "click, then press a key")
                                    color: kbKeyBox.rec ? theme.bad : (kbKeyBox.keyv ? theme.frost : theme.faint); font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (root.kbAdding) root.kbAddRecording = true; else root.kbRecRecording = true; kbCapture.forceActiveFocus() } }
                            }
                        }
                        // conflict / hint
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: root.kbConflict !== "" ? root.kbConflict : "pick modifiers, click the key box and press a key"
                            color: root.kbConflict !== "" ? theme.bad : theme.faint; font.pixelSize: 10; font.family: "monospace" }
                        // actions
                        RowLayout { Layout.fillWidth: true; spacing: 10; Layout.topMargin: 2
                            Item { Layout.fillWidth: true }
                            Rectangle { implicitWidth: 76; implicitHeight: 32; radius: 7
                                color: kbCanMa.containsMouse ? theme.a(theme.bad,0.14) : "transparent"; border.width: 1; border.color: kbCanMa.containsMouse ? theme.bad : theme.a(theme.line,0.6)
                                Text { anchors.centerIn: parent; text: "cancel"; color: kbCanMa.containsMouse ? theme.bad : theme.text; font.pixelSize: 12; font.family: "monospace" }
                                MouseArea { id: kbCanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                            Rectangle { id: kbOkBtn
                                readonly property bool valid: root.kbAdding ? (root.kbAddDesc.trim()!=="" && root.kbAddKey!=="" && root.kbAddAction.trim()!=="") : (root.kbRecKey!=="")
                                implicitWidth: 92; implicitHeight: 32; radius: 7
                                color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22)) : theme.a(theme.line,0.3); border.width: 1; border.color: kbOkBtn.valid ? theme.iris : theme.a(theme.line,0.5)
                                Text { anchors.centerIn: parent; text: root.kbAdding ? "add bind" : "save"; color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.bg : theme.text) : theme.faint; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                MouseArea { id: kbOkMa; anchors.fill: parent; enabled: kbOkBtn.valid; hoverEnabled: true; cursorShape: kbOkBtn.valid ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { if (root.kbAdding) root.kbApplyAddBind(); else root.kbApply(root.kbRecKey); } }
                            }
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
