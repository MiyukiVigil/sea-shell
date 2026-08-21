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
    // Read from the VERSION file install.sh deploys, not hardcoded here. The literal used to be
    // "mirrored in the repo VERSION file" by hand, and the two had silently drifted a whole major
    // release apart — the badge read v5.0.0 on a 6.0.0 install. A version badge that lies is worse
    // than no badge. The literal survives only as the fallback for a `qs -p` run out of the repo
    // with nothing deployed; the second path covers that case too (quickshell/ui/ → repo root).
    property string seaVersion: "6.3.1"
    Process {
        running: true
        command: ["sh","-c","cat \"$HOME/.config/quickshell/sea-shell/VERSION\" 2>/dev/null || cat \"" + root.repo + "/../../VERSION\" 2>/dev/null"]
        stdout: StdioCollector { id: verOut; onStreamFinished: {
            var v = (verOut.text || "").trim();
            if (v.length > 0) root.seaVersion = v;
        } }
    }
    property int tab: 8                             // land on the System / About dashboard

    // ---- resident lifecycle: the panel is hidden until shown, so it costs ~nothing closed ----
    property bool shown: false
    function openPanel() { root.showTab(8) }
    function openTab(t) { root.showTab(t) }
    function closePanel() { root.shown = false }
    function togglePanel() { if (root.shown) root.closePanel(); else root.openPanel() }
    function showTab(t) {
        // Not fresh until the read below lands. Everything this panel mirrors is stale between
        // here and there, and one of those mirrors drives the WHOLE SHELL's palette.
        root.apFresh = false;
        apReadProc.running = true;                  // pick up appearance changes made while closed
        if (root.tab === t) root.refreshTab(t); else root.tab = t;   // else onTabChanged refreshes
        root.shown = true;
    }
    function refreshTab(t) {
        if (t === 0) root.audioRefresh()              // audio: sink formats + streams
        if (t === 1) { root.reloadMonitors(); root.reloadDisplayProfiles() }   // display: monitors + saved layout profiles
        if (t === 2) root.rescanWifi()                // network: re-probe the air, don't show the last poll
        if (t === 14) root.reloadKde()                // kdeconnect: refresh devices
        if (t === 7) kbProc.running = true            // keybinds: refresh binds
        if (t === 17) { wrRead.running = true; wrClsProc.running = true }   // window rules + live class list
        if (t === 15) gsRead.running = true           // input: reload gestures from disk
        if (t === 18) { usageReadProc.running = true; ulimReadProc.running = true }   // screen time
        if (t === 8) { sysProc.running = true; bkListProc.running = true; otaProc.running = true }   // system: stats + backups + update check
        if (t === 19) diskProc.running = true         // disks
        if (t === 10) { idleChk.running = true; lockSettingsGet.running = true }   // idle & lock
        if (t === 6) { ppGet.running = true; lockSettingsGet.running = true; battProc.running = true }   // power: profile, lid settings, battery wear
        if (t === 11) { reloadEventsProc.running = true; calCfgLoad.running = true }  // calendar
    }
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }

    // ---------- the desktop ----------
    // The arrangement is owned by sea-desktop.py, not by this panel: there is one desktop
    // but a surface per monitor, and a settings page that wrote the file directly would be
    // a third writer racing the other two. This page asks; the script decides.
    readonly property string dtScript: Qt.resolvedUrl("sea-desktop.py").toString().replace("file://","")
    property var dtItems: []
    property bool dtEditing: false
    property string dtAuto: "rescue"
    property string dtQuery: ""
    function dtRun(args) { Quickshell.execDetached(["python3", root.dtScript].concat(args)) }
    function dtIpc(fn) { Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "desktop", fn]) }
    FileView {
        id: dtFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/desktop.json"
        watchChanges: true
        function apply() {
            try {
                reload();
                var t = text();
                var j = (t && t.trim()) ? JSON.parse(t) : null;
                root.dtItems = (j && j.items) ? j.items : [];
                var a = (j && j.autoArrange !== undefined) ? j.autoArrange : "rescue";
                root.dtAuto = (a === true) ? "rescue" : (a === false) ? "off" : ("" + a);
            } catch (e) { root.dtItems = [] }
        }
        onFileChanged: apply()
        onLoaded: apply()
        Component.onCompleted: apply()
    }
    // Installed applications, filtered by what has been typed. Capped: this is a picker,
    // and a list you have to scroll is a list you should have searched.
    readonly property var dtApps: {
        var q = root.dtQuery.toLowerCase().trim();
        var out = [];
        try {
            var all = DesktopEntries.applications.values;
            for (var i = 0; i < all.length; i++) {
                var e = all[i];
                if (!e || !e.name) continue;
                if (q.length && ("" + e.name).toLowerCase().indexOf(q) < 0) continue;
                out.push(e);
            }
        } catch (err) {}
        // Sorted, then cut. DesktopEntries hands them back in scan order, which is neither
        // alphabetical nor stable — a picker whose first seven entries change between
        // openings is one you cannot learn, only search.
        out.sort(function (a, b) { return ("" + a.name).localeCompare("" + b.name) });
        return out.slice(0, 7);
    }
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
    // The browser used to start at a literal "/home/miyukivigil", which is one specific
    // machine's home directory shipped inside the config.
    readonly property string homeDir: Quickshell.env("HOME") || "/"
    property bool fileBrowserOpen: false
    property string fileBrowserPath: ""  // current directory (absolute path)
    property string fileBrowserFilter: "" // e.g. ".conf", ".ovpn", ".ics"
    property var fileBrowserCallback: null // function(path) called on file selection
    property var fileBrowserItems: []     // [{type, name}]
    property string fileBrowserTitle: ""
    // Folder mode: files are hidden entirely and the header grows a "use this folder"
    // action, because in a directory picker the thing you want is the place you are
    // standing — there is nothing in the list to click.
    property bool fileBrowserDirs: false

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

    function pickFolder(title, start, callback) {
        root.fileBrowserTitle = title;
        root.fileBrowserFilter = "";
        root.fileBrowserDirs = true;
        root.fileBrowserCallback = callback;
        root.fileBrowserPath = (start && start.length && start.charAt(0) === "/")
                             ? start : root.homeDir;
        root.fileBrowserOpen = true;
        refreshFileBrowser();
    }

    function pickFile(title, filter, callback) {
        root.fileBrowserTitle = title;
        root.fileBrowserDirs = false;
        var ext = "";
        if (filter) {
            var m = filter.match(/\*\.([a-zA-Z0-9]+)/);
            if (m) ext = "." + m[1];
            else if (filter.indexOf(".") >= 0) ext = filter.slice(filter.indexOf("."));
        }
        root.fileBrowserFilter = ext;
        root.fileBrowserCallback = callback;
        if (!root.fileBrowserPath) {
            root.fileBrowserPath = root.homeDir;
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
    // Flat rows for IndTable. The live Bluetooth objects expose methods (connect/disconnect) and
    // computed names, which a data-driven table can't read directly — `_dev` carries the object
    // through so the activation handler can still act on it.
    readonly property var btRows: root.btDevices.map(function (d) {
        return {
            name:    root.btName(d),
            battery: d.batteryAvailable ? Math.round((d.battery || 0) * 100) + "%" : "",
            state:   d.connected ? "connected" : "paired",
            _tone:   d.connected ? "ok" : "neutral",
            _dev:    d
        };
    })

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

    // ---------- battery health ----------
    // UPower is already imported for charge %, but wear is not exposed through it — the design
    // vs current full-charge capacity lives in sysfs. Reported as a percentage of design
    // capacity, which is the number that actually tells you whether the pack is worn out.
    property var battHealth: ({})
    Process {
        id: battProc
        command: ["sh","-c",
            "B=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1); [ -z \"$B\" ] && exit 0;" +
            "read_it() { cat \"$B/$1\" 2>/dev/null; };" +
            // charge_* (µAh) on most laptops, energy_* (µWh) on others — take whichever exists
            "full=$(read_it charge_full); [ -z \"$full\" ] && full=$(read_it energy_full);" +
            "des=$(read_it charge_full_design); [ -z \"$des\" ] && des=$(read_it energy_full_design);" +
            "printf '%s|%s|%s|%s|%s|%s' \"$full\" \"$des\" \"$(read_it cycle_count)\" \"$(read_it manufacturer)\" \"$(read_it model_name)\" \"$(read_it status)\""]
        stdout: StdioCollector { id: battOut; onStreamFinished: {
            var t = battOut.text.trim();
            if (!t) { root.battHealth = ({}); return }
            var p = t.split("|");
            var full = parseFloat(p[0]) || 0, des = parseFloat(p[1]) || 0;
            root.battHealth = {
                present: des > 0,
                pct:     des > 0 ? Math.round(full / des * 100) : 0,
                full:    full, design: des,
                cycles:  parseInt(p[2]) || 0,
                vendor:  (p[3] || "").trim(),
                model:   (p[4] || "").trim(),
                status:  (p[5] || "").trim()
            };
        } } }

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
        var list = q === "" ? root.kbBinds
                            : root.kbBinds.filter(b => b.desc.toLowerCase().indexOf(q) >= 0 || b.keys.toLowerCase().indexOf(q) >= 0);
        // tag the bind currently being re-recorded so its chip reads as live during capture
        var rec = root.kbRec;
        return list.map(function (b) {
            var isRec = rec !== null && rec.desc === b.desc && rec.key === b.key;
            return isRec ? Object.assign({}, b, { _tone: "accent" }) : b;
        });
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

    // ---------- industrial token shim ----------
    // Same remapping as shell.qml's — see the note there. Kept as a shim because ~340 call sites
    // in this file speak these names; the ramp itself lives once, in Tok.qml.
    QtObject {
        id: theme
        readonly property bool  light: root.apLight
        readonly property color _acc: root.apAccent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    Tok.bg
        readonly property color panel: Tok.surface
        readonly property color line:  Tok.ruleHard
        readonly property color text:  Tok.ink
        readonly property color sub:   Tok.ink2
        readonly property color faint: Tok.ink3
        readonly property color iris:  Tok.accent
        readonly property color frost: Tok.ink2
        readonly property color good:  Tok.ok
        readonly property color warn:  Tok.warn
        readonly property color bad:   Tok.crit
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }
    // While the panel is open THIS surface owns the accent, so dragging the colour picker
    // live-previews across the whole shell; on close, the config file takes back over.
    //
    // RestoreNone MATTERS.  A Binding with `when` defaults to putting back whatever the target
    // held at the moment it activated — so opening settings took a snapshot of the theme,
    // changing the theme wrote the new one to disk, and CLOSING settings restored the snapshot
    // and flipped the entire shell back to the mode you had just left. The config said dark and
    // the bar drew light, until the next unrelated write to appearance.json happened to correct
    // it. Nothing to restore is the right answer: the file is the source of truth, saveAppearance
    // has already written it, and Tok re-reads it on change.
    // GATED ON apFresh, not just on being open. This panel's copy of the config is filled by an
    // async `cat` that only runs when the panel opens, so between opening and that read landing
    // the mirror still holds whatever was true when the bar started. Binding on `shown` alone
    // pushed THAT onto Tok the instant the panel appeared: switch to dark globally, open
    // settings, and the whole shell flashed back to light for as long as the read took, then
    // snapped to dark when it arrived. Until the copy is known current, the file stays in charge.
    Binding { target: Tok; property: "accentRaw"; value: root.apAccent; when: root.shown && root.apFresh
              restoreMode: Binding.RestoreNone }
    Binding { target: Tok; property: "light";     value: root.apLight;  when: root.shown && root.apFresh
              restoreMode: Binding.RestoreNone }
    // Handing control back. RestoreNone stops the Binding putting a stale snapshot back, but on
    // its own it leaves Tok holding the preview value with nothing left to correct it — so the
    // panel says explicitly when it has let go, and Tok re-reads the file.
    onShownChanged: if (!root.shown) Tok.resync()

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
    // Flat rows for the device tables. Pipewire nodes are live objects with derived names and
    // per-node format lookups, so — as with Bluetooth — the object rides along in `_node` and
    // the table only ever renders plain values.
    readonly property var sinkRows: root.sinks.map(function (n) {
        return { name: root.nodeName(n), format: root.audioFmtBadge(n.name),
                 rate: root.audioMaxRate(n.name), _node: n };
    })
    readonly property var sourceRows: root.sources.map(function (n) {
        return { name: root.nodeName(n), _node: n };
    })
    readonly property int sinkSel: {
        if (!root.curSink) return -1;
        for (var i = 0; i < root.sinks.length; i++) if (root.sinks[i].id === root.curSink.id) return i;
        return -1;
    }
    readonly property int sourceSel: {
        if (!root.curSource) return -1;
        for (var i = 0; i < root.sources.length; i++) if (root.sources[i].id === root.curSource.id) return i;
        return -1;
    }

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
    // Flat rows for the overview table. The chips only ever showed one monitor's mode at a time
    // (in a sentence under the picker), so a two-display setup could not be compared at a glance.
    readonly property var monRows: root.monitors.map(function (m) {
        return {
            name:  m.name,
            desc:  m.desc,
            mode:  m.curRes + " @ " + m.hz + "Hz",
            scale: (Math.round((m.scale || 1) * 100) / 100) + "×",
            rot:   m.transform ? (m.transform * 90) + "°" : ""
        };
    })

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
        // `hyprctl keyword` only works against the LEGACY .conf parser — under a Lua config it
        // refuses with "keyword can't work with non-legacy parsers. Use eval." and the display
        // silently keeps its old mode. Try keyword (for .conf users), fall back to the Lua eval.
        var lua = 'hl.monitor({ output = "' + root.curMon.name + '", mode = "' + root.selRes + "@" + root.selHz
                + '", position = "auto", scale = ' + root.curMon.scale + ", transform = " + root.selTransform + " })";
        run("{ hyprctl keyword monitor '" + spec + "' | grep -q '^ok' || hyprctl eval '" + lua + "'; } "
            + "&& notify-send 'sea-shell' 'Display: " + root.selRes + "@" + root.selHz + "Hz'");
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
    // ---------- the bar's own shape, workspaces and mark ----------
    // All three used to be facts rather than settings. They live in a Bar tab of their own
    // now: bar-specific controls were sharing "Appearance → bar theme" with the shell-wide
    // dark/light switch and the GTK/Qt app preference, which are not about the bar at all.
    property string apBarShape: "bar"       // bar | pills
    property string apWsStyle:  "grow"      // grow | pill | circle
    property string apWsLabel:  "arabic"    // what the workspace is CALLED on the bar
    // The chip shows the SCHEME, not its name: you pick a numbering by seeing it, the same
    // way you pick a logo by seeing it. "mandarin" tells you less than 一 二 三 does.
    // Mirrors shell.qml: a scheme whose symbols nothing on this machine can draw is not
    // offered at all, rather than offered as a row of tofu boxes.
    readonly property string symbolFamily: {
        var fams = Qt.fontFamilies();
        var prefs = ["DejaVu Sans", "Noto Sans Symbols2", "Adwaita Mono", "DejaVu Sans Mono"];
        for (var i = 0; i < prefs.length; i++)
            if (fams.indexOf(prefs[i]) >= 0) return prefs[i];
        for (var j = 0; j < fams.length; j++)
            if (fams[j].indexOf("Nerd Font") >= 0) return fams[j];
        return "";
    }
    readonly property var wsLabelChoices: [
        { k: "arabic",   l: "1 2 3" },
        { k: "roman",    l: "I II III" },
        { k: "mandarin", l: "\u4e00 \u4e8c \u4e09" },
        { k: "letters",  l: "A B C" },
        { k: "circled",  l: "\u2460 \u2461 \u2462" },
        { k: "dice",     l: "\u2680 \u2681 \u2682" },
        { k: "dots",     l: "\u25cf \u25cf \u25cf" }
    ]
    property string apBarLogo:  "auto"      // auto | sea | cachy | <distro> | custom
    property string apBarLogoPath: ""
    readonly property var barLogoChoices: [
        { k: "auto",        l: "auto" },
        { k: "sea",         l: "sea-shell" },
        { k: "cachy",       l: "cachyos" },
        { k: "arch",        l: "arch" },
        { k: "debian",      l: "debian" },
        { k: "ubuntu",      l: "ubuntu" },
        { k: "fedora",      l: "fedora" },
        { k: "nixos",       l: "nixos" },
        { k: "opensuse",    l: "opensuse" },
        { k: "gentoo",      l: "gentoo" },
        { k: "mint",        l: "mint" },
        { k: "manjaro",     l: "manjaro" },
        { k: "endeavouros", l: "endeavour" },
        { k: "artix",       l: "artix" },
        { k: "void",        l: "void" },
        { k: "alpine",      l: "alpine" },
        { k: "pop",         l: "pop!_os" },
        { k: "tux",         l: "generic" },
        { k: "custom",      l: "custom…" }
    ]

    // Written by welcome.qml, never by this panel — but this panel REBUILDS the whole file
    // from its own properties on every save, so any key it does not carry is deleted. That is
    // what kept resurrecting the first-run tour: change any setting, `welcomed` disappears,
    // and the tour reopens over whatever you were doing. Carried through untouched.
    property bool apWelcomed: false

    property bool apAutoHide: false          // auto-hide the bar (reveal on hover)
    property bool apHideFullscreen: false     // hide the bar while a window is fullscreen
    property bool apNight: false             // night light on/off (manual)
    property int  apNightTemp: 4000          // night-light colour temperature (K)
    property bool apNightAuto: false         // night light follows dark mode
    // drag-reorderable order of the bar widgets (mirrors shell.qml cfgWidgetOrder)
    // MUST match shell.qml's defaultWidgetOrder — it is the same bar. This copy had drifted:
    // wgUpdates and wgNet appeared twice (so the reorder list showed two identical rows, and
    // dragging either wrote a duplicate into the saved order) and one widget was missing.
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgUpdates","wgNet","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgMic","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
    property var apWidgetOrder: root.defaultWidgetOrder
    // left cluster order (mirrors shell.qml cfgLeftOrder)
    readonly property var defaultLeftOrder: ["lgLogo","lgWork","lgScratch","lgTitle"]
    property var apLeftOrder: root.defaultLeftOrder
    readonly property var lgMeta: ({
        lgLogo:  { i: "sailing",  l: "Logo",         d: "The sea-shell mark — click opens the launcher" },
        lgWork:  { i: "apps",     l: "Workspaces",   d: "Hyprland workspace indicators" },
        lgScratch: { i: "inventory_2", l: "Scratchpad", d: "How many windows are stashed — hidden while it holds none" },
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
        wgNet:       { i: "swap_vert",             l: "Network Speed",     d: "Live download / upload throughput",                      prop: "wgNet" },
        wgUpdates:   { i: "system_update_alt",     l: "Updates",           d: "Pending pacman + AUR updates, with a one-click upgrade",  prop: "wgUpdates" },
        wgSystem:    { i: "speed",                 l: "System Monitor",    d: "Live CPU usage and system load",                        prop: "wgSystem" },
        wgMic:       { i: "mic",                   l: "Microphone",        d: "Input level, and click to mute — red while muted",      prop: "wgMic" },
        wgVolume:    { i: "volume_up",             l: "Volume",            d: "Sound level and output selector",                       prop: "wgVolume" },
        wgBattery:   { i: "battery_charging_full", l: "Battery",           d: "Remaining charge (laptops)",                            prop: "wgBattery" },
        wgRec:       { i: "videocam",              l: "Screen Recorder",   d: "Shows only while recording — no toggle",                 prop: "" },
        wgClock:     { i: "schedule",              l: "Clock & Calendar",  d: "Date/time with upcoming events",                        prop: "wgClock" },
        wgPower:     { i: "power_settings_new",    l: "Power",             d: "Lock, log out, reboot, or shut down",                   prop: "wgPower" }
    })
    // ---------- per-widget pill appearance ----------
    // Which row (if any) has its style panel open. One at a time: the list is a reorderable
    // stack, and several rows expanded at once turns a drag into a guess about where you are.
    property string wgOpenId: ""
    readonly property var wgAccentChoices: [
        { k: "",      l: "default" },
        { k: "iris",  l: "accent"  },
        { k: "good",  l: "good"    },
        { k: "warn",  l: "warn"    },
        { k: "bad",   l: "alert"   },
        { k: "text",  l: "ink"     }
    ]
    readonly property var wgContentChoices: [
        { k: "both",  l: "icon + value" },
        { k: "icon",  l: "icon"         },
        { k: "value", l: "value"        }
    ]
    readonly property var wgGroundChoices: [
        { k: "filled",  l: "filled"  },
        { k: "outline", l: "outline" },
        { k: "bare",    l: "bare"    }
    ]
    // Named roles resolve through the theme, so a pill coloured "accent" re-tints with the
    // wallpaper like everything else. A raw #hex is honoured and does not.
    function wgTone(n) {
        switch (n) {
        case "iris": return theme.iris;  case "good": return theme.good;
        case "warn": return theme.warn;  case "bad":  return theme.bad;
        case "text": return theme.text;  case "frost": return theme.frost;
        default: return (n && n.charAt(0) === "#") ? n : theme.faint;
        }
    }
    readonly property var wgStyleDefaults: ({ a: "", c: "both", g: "filled" })
    function wgStyleGet(wid, k) {
        var e = root.apWgStyle ? root.apWgStyle[wid] : null;
        return (e && e[k] !== undefined && e[k] !== "") ? "" + e[k] : root.wgStyleDefaults[k];
    }
    // Stored SPARSELY: a value put back to its default deletes the key, and a widget left with
    // no keys deletes the whole entry. Without that the file accumulates one object per widget
    // full of values that only say "unchanged", and a default we improve later can never reach
    // anyone who once opened this panel.
    function wgStyleSet(wid, k, v) {
        var m = {};
        for (var w in root.apWgStyle) { m[w] = {}; for (var kk in root.apWgStyle[w]) m[w][kk] = root.apWgStyle[w][kk]; }
        var e = m[wid] || {};
        if (v === root.wgStyleDefaults[k] || v === "") delete e[k]; else e[k] = v;
        var n = 0; for (var q in e) n++;
        if (n === 0) delete m[wid]; else m[wid] = e;
        root.apWgStyle = m;
        root.saveAppearance();
    }
    function wgStyleTouched(wid) { var e = root.apWgStyle ? root.apWgStyle[wid] : null; if (!e) return false; for (var k in e) return true; return false; }

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
    // Scanned once at startup rather than only when the wallpaper tab becomes visible: it
    // costs ~26ms against a warm cache, and it means the count is right the first time the
    // tab is opened instead of depending on a visibility transition that may already have
    // happened. Folded in here because a QML object may only assign Component.onCompleted
    // ONCE — a second one at root scope is "Property value set multiple times", which takes
    // the whole panel out of the shell.
    Component.onCompleted: { root.wgSyncModel(); root.lgSyncModel(); root.rescanWallpapers() }
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
    // ---------- user window rules ----------
    // Data lives in window-rules.json; sea-window-rules.sh turns it into Lua and applies it.
    // Rules take effect when a window MAPS, so edits affect the next window of that class —
    // the panel says this rather than leaving you wondering why nothing moved.
    property var wrRules: []
    property int wrSel: -1
    Process { id: wrRead; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/window-rules.json\" 2>/dev/null"]
        stdout: StdioCollector { id: wrJsonOut; onStreamFinished: {
            try { var t = wrJsonOut.text.trim(); if (!t) return; var j = JSON.parse(t);
                  if (Array.isArray(j)) root.wrRules = j; } catch (e) {}
        } } }
    function wrSave() {
        var b64 = Qt.btoa(JSON.stringify(root.wrRules));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"$HOME/.config/sea-shell/window-rules.json\""
            + " && sh \"$HOME/.config/quickshell/sea-shell/sea-window-rules.sh\" >/dev/null 2>&1");
    }
    function wrAdd() {
        var l = root.wrRules.slice();
        l.push({ "class": "", title: "", float: false, tile: false, center: false, pin: false,
                 noblur: false, noshadow: false, opacity: 1, workspace: "", size: "" });
        root.wrRules = l; root.wrSel = l.length - 1;
    }
    function wrDel(i) {
        var l = root.wrRules.slice(); l.splice(i, 1); root.wrRules = l;
        if (root.wrSel >= l.length) root.wrSel = l.length - 1;
        root.wrSave();
    }
    function wrSet(i, k, v) {
        var l = root.wrRules.slice(); if (!l[i]) return;
        var o = {}; for (var q in l[i]) o[q] = l[i][q];
        o[k] = v; l[i] = o; root.wrRules = l; root.wrSave();
    }
    // one-line human summary of what a rule actually does, for the table
    function wrSummary(r) {
        if (!r) return "—";
        var a = [];
        if (r.float) a.push("float");
        if (r.tile) a.push("tile");
        if (r.center) a.push("center");
        if (r.pin) a.push("pin");
        if (r.fullscreen) a.push("fullscreen");
        if (r.noblur) a.push("no blur");
        if (r.noshadow) a.push("no shadow");
        if (r.opacity !== undefined && r.opacity > 0 && r.opacity < 1) a.push("opacity " + Number(r.opacity).toFixed(2));
        if (r.workspace) a.push("ws " + r.workspace);
        if (r.size) a.push(r.size);
        return a.length ? a.join(" · ") : "no actions";
    }
    readonly property var wrRows: {
        var out = [];
        for (var i = 0; i < root.wrRules.length; i++) {
            var r = root.wrRules[i];
            out.push({ cls: r["class"] || "—", ttl: r.title || "—", act: root.wrSummary(r),
                       _tone: (!r["class"] && !r.title) ? "crit" : "neutral" });
        }
        return out;
    }

    // ---------- screen time (usage + limits) ----------
    // The bar measures; this panel only reads that file and writes the limits file back. Two
    // files, one writer each — the same split that keeps the dock pins safe from saveAppearance.
    property var  usageAll: ({})
    property var  usageLimits: ({})
    property bool usageSummary: false
    property string usageSummaryTime: "21:00"
    readonly property string usageDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    Process { id: usageReadProc; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage.json\" 2>/dev/null"]
        stdout: StdioCollector { id: usageReadOut; onStreamFinished: {
            try { var t = usageReadOut.text.trim(); if (t) root.usageAll = JSON.parse(t) || ({}); } catch (e) {}
        } } }
    Process { id: ulimReadProc; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage-limits.json\" 2>/dev/null"]
        stdout: StdioCollector { id: ulimReadOut; onStreamFinished: {
            try {
                var t = ulimReadOut.text.trim(); if (!t) return;
                var j = JSON.parse(t);
                if (j.limits) root.usageLimits = j.limits;
                if (j.summary !== undefined) root.usageSummary = !!j.summary;
                if (j.summaryTime) root.usageSummaryTime = j.summaryTime;
            } catch (e) {}
        } } }
    function ulimSave() {
        var o = { limits: root.usageLimits, summary: root.usageSummary, summaryTime: root.usageSummaryTime };
        var b64 = Qt.btoa(JSON.stringify(o));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"$HOME/.config/sea-shell/usage-limits.json\"");
    }
    function ulimSet(app, mins) {
        var l = {}; for (var k in root.usageLimits) l[k] = root.usageLimits[k];
        if (mins > 0) l[app] = mins; else delete l[app];
        root.usageLimits = l; root.ulimSave();
    }
    function usageFmt(s) {
        s = Math.round(s);
        if (s < 60) return s + "s";
        var m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        return Math.floor(m / 60) + "h " + (m % 60) + "m";
    }
    // Every app seen in the last fortnight, not just today — otherwise you could only ever set a
    // limit on something you had already used today, which is backwards.
    readonly property var usageApps: {
        var seen = {}, out = [];
        for (var d in root.usageAll) for (var a in root.usageAll[d]) seen[a] = true;
        var today = root.usageAll[root.usageDate] || ({});
        for (var k in seen) out.push({ app: k, _s: today[k] || 0 });
        out.sort(function (x, y) { return y._s - x._s || (x.app < y.app ? -1 : 1) });
        return out;
    }
    readonly property var usageLimitRows: {
        var out = [], apps = root.usageApps;
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i], lim = root.usageLimits[a.app] || 0;
            var mins = a._s / 60;
            var over = lim > 0 && mins >= lim;
            out.push({ app: a.app,
                       today: a._s > 0 ? root.usageFmt(a._s) : "—",
                       limit: lim > 0 ? (lim + " min") : "—",
                       state: lim > 0 ? (over ? "over" : "ok") : "",
                       _tone: over ? "crit" : (lim > 0 ? "ok" : "neutral") });
        }
        return out;
    }
    property int usageSel: -1

    // ---------- OTA updates ----------
    // sea-update.sh does the git work and refuses anything unsafe; this only shows the result
    // and offers the button when the state is actually installable.
    property string otaState: ""            // uptodate·available·ahead·diverged·dirty·norepo·offline
    property string otaLocal: ""
    property string otaRemote: ""
    property int    otaBehind: 0
    property string otaDetail: ""
    property bool   otaBusy: false
    Process {
        id: otaProc
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-update.sh check"]
        onRunningChanged: root.otaBusy = otaProc.running || otaApply.running
        stdout: StdioCollector { id: otaOut; onStreamFinished: {
            var p = otaOut.text.trim().split("|");
            if (p.length < 5) { root.otaState = "offline"; root.otaDetail = "check failed"; return }
            root.otaState = p[0]; root.otaLocal = p[1]; root.otaRemote = p[2];
            root.otaBehind = parseInt(p[3]) || 0; root.otaDetail = p[4];
        } } }
    Process {
        id: otaApply
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-update.sh apply"]
        onRunningChanged: {
            root.otaBusy = otaProc.running || otaApply.running;
            if (!otaApply.running) otaProc.running = true;   // re-check once it finishes
        }
        stdout: StdioCollector { id: otaApplyOut; onStreamFinished: {
            var p = otaApplyOut.text.trim().split("|");
            if (p.length >= 5) { root.otaState = p[0]; root.otaDetail = p[4]; }
        } } }
    // Only a clean fast-forward is offered. Every other state is a situation a human should look
    // at, not something a button should paper over.
    readonly property bool otaCanApply: root.otaState === "available" && !root.otaBusy
    readonly property color otaColor: root.otaState === "available" ? theme.frost
                                    : root.otaState === "uptodate"  ? theme.good
                                    : root.otaState === "offline" || root.otaState === "norepo" ? theme.faint
                                    : theme.warn

    // ---------- health check ----------
    property var  docRows: []
    property bool docRunning: false
    property int  docWarn: 0
    property int  docCrit: 0
    Process {
        id: docProc
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-doctor.sh"]
        onRunningChanged: root.docRunning = docProc.running
        stdout: StdioCollector { id: docOut; onStreamFinished: {
            var out = [], w = 0, c = 0;
            var lines = docOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var p = lines[i].split("|");
                if (p.length < 4) continue;
                if (p[0] === "warn") w++; else if (p[0] === "crit") c++;
                out.push({ st: p[0] === "ok" ? "ok" : p[0] === "warn" ? "warn" : "fail",
                           cat: p[1], item: p[2], detail: p[3],
                           _tone: p[0] === "ok" ? "ok" : p[0] === "warn" ? "warn" : "crit" });
            }
            root.docRows = out; root.docWarn = w; root.docCrit = c;
        } } }
    // Problems first. A clean run is 40+ green rows and the two that matter must not be buried
    // in the middle of them.
    readonly property var docSorted: {
        var bad = [], good = [];
        for (var i = 0; i < root.docRows.length; i++)
            (root.docRows[i].st === "ok" ? good : bad).push(root.docRows[i]);
        return bad.concat(good);
    }

    // ---------- backup / restore ----------
    property var    bkList: []
    property string bkMsg: ""
    Process {
        id: bkListProc
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-backup.sh list"]
        stdout: StdioCollector { id: bkOut; onStreamFinished: {
            var out = [], lines = bkOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var p = lines[i].split("|");
                if (p.length < 3) continue;
                var name = p[0].split("/").pop();
                out.push({ file: name, size: p[1], when: p[2], _path: p[0],
                           _tone: name.indexOf("pre-restore") === 0 ? "warn" : "neutral" });
            }
            // newest first
            out.sort(function (a, b) { return a.when < b.when ? 1 : -1 });
            root.bkList = out;
        } } }
    Process {
        id: bkMakeProc
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-backup.sh create"]
        stdout: StdioCollector { id: bkMakeOut; onStreamFinished: {
            root.bkMsg = "backup written to " + bkMakeOut.text.split("\n")[0];
            bkListProc.running = true;
        } } }
    function bkCreate() { root.bkMsg = "writing backup…"; bkMakeProc.running = true }
    function bkRestore(row) {
        if (!row) return;
        root.bkMsg = "restoring " + row.file + "…";
        // The script archives the current config before it replaces anything, so this is
        // recoverable even if it is the wrong archive.
        run("~/.config/quickshell/sea-shell/sea-backup.sh restore '" + ("" + row._path).replace(/'/g, "") + "'"
            + " >/dev/null 2>&1");
        bkRefresh.restart();
    }
    Timer { id: bkRefresh; interval: 1500; repeat: false; onTriggered: bkListProc.running = true }

    // ---------- touchpad gestures ----------
    // Valid values probed against this machine's Hyprland 0.56, one at a time with a reload
    // between each — see sea-gestures.sh. Offering an option the compositor rejects is worse
    // than not offering it, so these two lists are exactly what it accepts.
    readonly property var gsDirs: ["horizontal","vertical","left","right","up","down","pinch","swipe"]
    readonly property var gsActions: ["workspace","move","resize","special","fullscreen","close","float"]
    property var gsList: []
    property int gsSel: -1
    Process { id: gsRead; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/gestures.json\" 2>/dev/null"]
        stdout: StdioCollector { id: gsOut; onStreamFinished: {
            try { var t = gsOut.text.trim(); if (!t) return; var j = JSON.parse(t);
                  if (Array.isArray(j)) root.gsList = j; } catch (e) {}
        } } }
    function gsSave() {
        var b64 = Qt.btoa(JSON.stringify(root.gsList));
        run("mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"$HOME/.config/sea-shell/gestures.json\""
            + " && sh \"$HOME/.config/quickshell/sea-shell/sea-gestures.sh\" >/dev/null 2>&1");
    }
    function gsAdd() {
        var l = root.gsList.slice();
        l.push({ fingers: 3, direction: "horizontal", action: "workspace" });
        root.gsList = l; root.gsSel = l.length - 1; root.gsSave();
    }
    function gsDel(i) {
        var l = root.gsList.slice(); l.splice(i, 1); root.gsList = l;
        if (root.gsSel >= l.length) root.gsSel = l.length - 1;
        root.gsSave();
    }
    function gsSet(i, k, v) {
        var l = root.gsList.slice(); if (!l[i]) return;
        var o = {}; for (var q in l[i]) o[q] = l[i][q];
        o[k] = v; l[i] = o; root.gsList = l; root.gsSave();
    }
    // Hyprland keys a gesture on fingers+direction and refuses a second one for the same pair,
    // so flag the clash in the table instead of letting it silently never fire.
    readonly property var gsRows: {
        var out = [], seen = {};
        for (var i = 0; i < root.gsList.length; i++) {
            var g = root.gsList[i];
            var key = g.fingers + "/" + g.direction;
            var dup = !!seen[key]; seen[key] = true;
            // The generator drops anything the compositor would reject; say so here rather than
            // listing a row that looks configured and quietly never fires.
            var bad = "";
            if (dup) bad = "duplicate — ignored";
            else if (root.gsDirs.indexOf(g.direction) < 0) bad = "invalid direction — ignored";
            else if (root.gsActions.indexOf(g.action) < 0) bad = "invalid action — ignored";
            else if (!(g.fingers >= 2 && g.fingers <= 5)) bad = "fingers must be 2–5 — ignored";
            out.push({ fing: g.fingers + " finger", dir: g.direction, act: g.action,
                       note: bad, _tone: bad !== "" ? "crit" : "neutral" });
        }
        return out;
    }

    // Currently-open window classes, so you can copy one instead of hunting for it in a terminal.
    property string wrOpenClasses: "…"
    Process { id: wrClsProc
        command: ["sh","-c","hyprctl -j clients 2>/dev/null | python3 -c \"import json,sys;print(', '.join(sorted({w['class'] for w in json.load(sys.stdin) if w.get('class')})))\" 2>/dev/null"]
        stdout: StdioCollector { id: wrClsOut; onStreamFinished: {
            var t = wrClsOut.text.trim(); root.wrOpenClasses = t !== "" ? t : "(none)";
        } } }

    // ---- dock ----
    property bool   apDock: false
    property string apDockEdge: "bottom"
    property real   apDockIcon: 40
    property string apDockMode: "always"            // always · autohide · intelligent
    property bool   apDockZoom: true
    property bool   apDockRunning: true
    property bool   apDockLabels: true
    readonly property var edges: ["top","bottom","left","right"]
    // ---------- disks & removable media ----------
    // udisksctl mounts through polkit, so no root and no sudo prompt in the shell. Mount points
    // land under /run/media/$USER/. System partitions (/ and /boot) are listed but never offered
    // an unmount action — unmounting the root filesystem from a settings panel is not a feature.
    property var diskRows: []
    // Removable drives get their own list because ejecting is a *drive* operation, not a
    // partition one — you pull the stick, not the filesystem.
    property var ejectDisks: []
    // grouped by physical drive, so the panel can show which partitions belong to which disk
    property var diskDrives: []
    readonly property int diskRemovableCount: {
        var n = 0; for (var i = 0; i < root.diskDrives.length; i++) if (root.diskDrives[i].removable) n++;
        return n;
    }
    readonly property int diskMountedCount: {
        var n = 0; for (var i = 0; i < root.diskRows.length; i++) if (root.diskRows[i]._mounted) n++;
        return n;
    }
    // The root filesystem is the one whose fullness actually stops you working, so it gets the KPI.
    readonly property int diskRootPct: {
        for (var i = 0; i < root.diskDrives.length; i++)
            for (var k = 0; k < root.diskDrives[i].parts.length; k++)
                if (root.diskDrives[i].parts[k].mount === "/") return root.diskDrives[i].parts[k].pct;
        return -1;
    }
    readonly property string diskRootFree: {
        for (var i = 0; i < root.diskDrives.length; i++)
            for (var k = 0; k < root.diskDrives[i].parts.length; k++)
                if (root.diskDrives[i].parts[k].mount === "/") return root.diskDrives[i].parts[k].avail;
        return "";
    }
    property string diskMsg: ""
    Process {
        id: diskProc
        // FSUSED/FSAVAIL/FSUSE% are only populated for MOUNTED filesystems — an unmounted
        // partition genuinely has no knowable usage without mounting it, so the UI shows a
        // dash there rather than implying 0%.
        command: ["sh","-c","lsblk -J -o NAME,SIZE,FSTYPE,MOUNTPOINT,RM,TYPE,LABEL,PATH,TRAN,MODEL,VENDOR,FSSIZE,FSUSED,FSAVAIL,FSUSE% 2>/dev/null"]
        stdout: StdioCollector { id: diskOut; onStreamFinished: {
            var out = [], ej = [];
            try {
                var j = JSON.parse(diskOut.text);
                var tops = j.blockdevices || [], drives = [];
                for (var i = 0; i < tops.length; i++) {
                    var dsk = tops[i];
                    if (dsk.type !== "disk") continue;
                    // zram and other diskless block devices carry no partitions worth showing
                    if (!dsk.children || dsk.children.length === 0) continue;
                    var dParts = [];
                    // `tran` and `model` are reported on the disk and are null on every partition
                    // under it, so the bus has to be carried down rather than read off the row.
                    var bus = dsk.tran || "—";
                    var mountedPaths = [];
                    var walk = function (ns) {
                        for (var k = 0; k < ns.length; k++) {
                            var n = ns[k];
                            if (n.type === "part" && n.fstype && n.fstype !== "swap") {
                                var mnt = n.mountpoint || "";
                                var pth = n.path || ("/dev/" + n.name);
                                var sys = (mnt === "/" || mnt === "/boot" || mnt.indexOf("/boot/") === 0);
                                if (mnt) mountedPaths.push(pth);
                                var pctRaw = n["fsuse%"] ? parseInt(("" + n["fsuse%"]).replace("%","")) : -1;
                                dParts.push({
                                    dev: pth.replace("/dev/", ""),
                                    label: n.label || "",
                                    size: n.size || "",
                                    fs: n.fstype,
                                    mount: mnt,
                                    used: n.fsused || "",
                                    avail: n.fsavail || "",
                                    pct: isNaN(pctRaw) ? -1 : pctRaw,
                                    system: sys,
                                    mounted: !!mnt,
                                    path: pth
                                });
                                out.push({
                                    dev:   pth.replace("/dev/", ""),
                                    label: n.label || "—",
                                    size:  n.size || "",
                                    fs:    n.fstype,
                                    bus:   bus,
                                    mount: mnt || "—",
                                    state: mnt ? "mounted" : "idle",
                                    _tone: mnt ? "ok" : "neutral",
                                    _path: pth,
                                    _mounted: !!mnt,
                                    _system: sys,
                                    _removable: n.rm === true || n.rm === "1"
                                });
                            }
                            if (n.children) walk(n.children);
                        }
                    };
                    if (dsk.children) walk(dsk.children);
                    var dname = ((dsk.vendor || "").trim() + " " + (dsk.model || "").trim()).trim();
                    var dRemovable = (dsk.rm === true || dsk.rm === "1" || dsk.tran === "usb");
                    drives.push({
                        name: dname || dsk.name,
                        dev: dsk.name,
                        path: dsk.path || ("/dev/" + dsk.name),
                        size: dsk.size || "",
                        bus: dsk.tran || "—",
                        removable: dRemovable,
                        mounted: mountedPaths.slice(),
                        parts: dParts
                    });
                    if (dRemovable) {
                        var nm = dname;
                        ej.push({
                            path: dsk.path || ("/dev/" + dsk.name),
                            name: nm || dsk.name,
                            size: dsk.size || "",
                            mounted: mountedPaths
                        });
                    }
                }
            } catch (e) {}
            root.diskRows = out;
            root.ejectDisks = ej;
            root.diskDrives = drives;
        } } }
    Timer { id: diskRefresh; interval: 1200; repeat: false; onTriggered: diskProc.running = true }
    // Hotplug. There is no udev watch here, so without a poll a USB plugged in while this tab is
    // open simply never appears — the same "it shows the same thing until you reload it" staleness
    // the network dropdown had. lsblk is cheap and the timer only runs while you are looking at it.
    Timer {
        id: diskPoll
        interval: 4000; repeat: true
        running: root.shown && root.tab === 19
        onTriggered: diskProc.running = true
    }
    function diskToggle(row) {
        if (!row || row._system) {
            root.diskMsg = row && row._system ? "system partitions stay mounted" : "";
            return;
        }
        var d = row._path.replace(/'/g, "");
        root.diskMsg = (row._mounted ? "unmounting " : "mounting ") + row.dev + "…";
        // -b takes the block device; udisks answers on stdout either way, so surface its message
        run("udisksctl " + (row._mounted ? "unmount" : "mount") + " -b '" + d + "' 2>&1 | head -1 "
            + "| xargs -0 -I{} notify-send 'sea-shell' '{}'");
        diskRefresh.restart();
    }
    // Unmount everything on the drive, then cut its power, so the stick is safe to pull rather
    // than merely unmounted. Chained with && so a filesystem that refuses to unmount (open files)
    // aborts before power-off and its own error is what gets reported — no silent half-eject.
    // `power-off-drive` is allow_active=yes in polkit, so this never prompts for removable media.
    function diskEject(d) {
        if (!d) return;
        var cmds = [];
        for (var i = 0; i < d.mounted.length; i++)
            cmds.push("udisksctl unmount -b '" + ("" + d.mounted[i]).replace(/'/g, "") + "'");
        cmds.push("udisksctl power-off -b '" + ("" + d.path).replace(/'/g, "") + "'");
        // power-off prints NOTHING on success, so without this echo `tail -1` would report the
        // preceding unmount ("Unmounted /dev/sda1.") — or nothing at all for an already-unmounted
        // drive. The echo makes the last line the eject verdict in both cases; on failure the &&
        // chain never reaches it and the real error is what surfaces instead.
        cmds.push("echo 'ejected " + d.name.replace(/'/g, "") + " — safe to unplug'");
        root.diskMsg = "ejecting " + d.name + "…";
        run("( " + cmds.join(" && ") + " ) 2>&1 | tail -1 "
            + "| xargs -0 -I{} notify-send 'sea-shell' '{}'");
        diskRefresh.restart();
    }

    // ---------- input devices + VRR ----------
    // Hyprland owns these, but `hyprctl keyword` is inert under a Lua config (it answers
    // "keyword can't work with non-legacy parsers. Use eval."), so everything here goes through
    // `hyprctl eval` + hl.config — note hl.config is a FUNCTION taking a table, not an indexable
    // object, so `hl.config.misc.vrr = 1` fails with "attempt to index a function value".
    // Values persist to appearance.json and are re-applied at shell start, because an eval only
    // lives as long as the current Hyprland session.
    property real   apMouseSens: 0          // -1 .. 1
    property string apAccelProfile: ""      // "" = libinput default | adaptive | flat
    property bool   apMouseNatural: false
    property bool   apTpNatural: false
    property real   apTpScroll: 1.0
    property bool   apTpTap: true
    property bool   apTpDwt: true           // disable touchpad while typing
    property int    apVrr: 0                // 0 off · 1 on · 2 fullscreen · 3 fullscreen+video
    readonly property var vrrModes: [
        { v: 0, l: "off" }, { v: 1, l: "always" }, { v: 2, l: "fullscreen" }, { v: 3, l: "fs + video" }
    ]

    function applyInput() {
        var lua = 'hl.config({ input = { sensitivity = ' + root.apMouseSens.toFixed(2)
                + ', natural_scroll = ' + (root.apMouseNatural ? 'true' : 'false')
                + (root.apAccelProfile !== "" ? ', accel_profile = "' + root.apAccelProfile + '"' : '')
                + ', touchpad = { natural_scroll = ' + (root.apTpNatural ? 'true' : 'false')
                + ', scroll_factor = ' + root.apTpScroll.toFixed(2)
                + ', tap_to_click = ' + (root.apTpTap ? 'true' : 'false')
                + ', disable_while_typing = ' + (root.apTpDwt ? 'true' : 'false')
                + ' } } })';
        run("hyprctl eval '" + lua + "' >/dev/null 2>&1");
    }
    function applyVrr() {
        run("hyprctl eval 'hl.config({ misc = { vrr = " + Math.round(root.apVrr) + " } })' >/dev/null 2>&1");
    }
    // re-apply once at startup: an eval does not survive a Hyprland restart
    Timer { interval: 1500; running: true; repeat: false
        onTriggered: { if (root.apLoaded) { root.applyInput(); root.applyVrr() } } }

    // ---------- wallpaper: switch transition + auto-rotate ----------
    // The transition was hardcoded to `grow` in two separate files; it is a setting now, shared
    // by the picker, the SUPER+N keybinds, login restore and the rotate daemon.
    property string apWpTransition: "grow"
    property int    apWpTransitionFps: 60
    property real   apWpTransitionDur: 1
    readonly property var wpTransitions: ["none","simple","fade","wipe","wave","grow","center","any","outer","left","right","top","bottom","random"]
    // Auto-rotate ships OFF: with "match colours" on, every rotation re-themes the whole shell,
    // and an accent that changes under you unprompted is a surprise rather than a feature.
    property bool   apWpRotate: false
    property real   apWpRotateMins: 30
    property string apWpRotateMode: "next"
    readonly property var wpRotateModes: ["next","prev","random"]
    // WHERE the wallpapers are. This was hardcoded to ~/Pictures/wallpapers in the cycle
    // script, in the indexer and — by omission — in the picker, so it could not be changed
    // at all; and the flat listing meant a folder with any organisation in it indexed as
    // empty. Subfolders are "collections" in the picker.
    property string apWpDir: "~/Pictures/wallpapers"
    property bool   apWpRecursive: true
    // Rotating into a video respawns a decoder every interval; some folders are mostly
    // clips and some people would rather the timer left those alone.
    property bool   apWpRotateStills: false
    // A paused mpvpaper still holds its decoder, its surface and its VRAM. Freeing it is
    // the default because the thing covering the wallpaper is usually the thing that
    // wanted that memory.
    property bool   apWpCoverStill: true
    property bool   apWpBatteryStill: false
    // The pinned pair. Shares auto dark mode's OWN darkStart/darkEnd rather than carrying
    // a second pair of times: "the desktop goes dark at 19:00" should mean one thing.
    property bool   apWpDayNight: false
    property string apWpDay: ""
    property string apWpNight: ""
    // The lock screen used to be overwritten on every single apply — sea-lockwall.sh ran
    // unconditionally — so "a different picture on the lock screen" was not expressible.
    property bool   apWpLockOwn: false
    property string apWpLock: ""
    // 0 = leave mpvpaper alone. Capping a 60fps clip to 30 halves the full-screen blits
    // the compositor does for it, which on a machine whose iGPU composites while the dGPU
    // renders is the cost that actually shows up.
    property int    apWpVidFps: 0
    readonly property var wpVidFpsOptions: [0, 60, 30, 24]
    // WHAT DECIDES LIGHT/DARK.  "manual" = whatever you last set, "clock" = the
    // darkStart..darkEnd window, "wallpaper" = the picture's own luminance. One source, chosen —
    // rather than two booleans that can both be on and disagree every minute.
    property string apModeSource: "manual"   // manual | clock | wallpaper
    property bool apAutoDark: false         // auto-switch dark/light by time of day (mirrors modeSource==="clock")
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
    property bool wgNet: true
    property bool wgUpdates: true
    property bool wgSystem: true
    property bool wgVolume: true
    property bool wgBattery: true
    property bool wgClock: true
    property bool wgPower: true
    property bool wgQuick: true
    property bool wgNight: false
    property bool wgMic: false
    // Which readings the System Monitor pill shows. sea-sysmon.sh has always sampled all of them;
    // this only decides which ones reach the bar.
    // Per-widget pill appearance: { wgWifi: { a: "iris", c: "icon", g: "outline" }, … }.
    // SPARSE ON PURPOSE — a widget left at its defaults has no entry at all, so the file does not
    // grow twenty objects of nulls and a widget added later inherits the new default rather than
    // a stale copy of the old one written before it existed.
    property bool apAttnFlash: true    // pulse the dock icon of an app asking for attention
    property bool apAttnFocus: true    // and switch to it
    property var apWgStyle: ({})
    property var apSysShow: ["cpu"]
    function sysShowToggle(k) {
        var a = root.apSysShow.slice(); var i = a.indexOf(k);
        if (i >= 0) { if (a.length <= 1) return; a.splice(i, 1); }   // never let it empty out
        else a.push(k);
        root.apSysShow = a; root.saveAppearance();
    }
    // ---------- matugen per-target overrides ----------
    property bool ovrHyprland: true
    property bool ovrHyprGlow: true
    property string ovrHyprGlowColor: ""
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
            if(j.hyprGlow) { if(j.hyprGlow.enabled!==undefined) root.ovrHyprGlow=!!j.hyprGlow.enabled; if(j.hyprGlow.customColor) root.ovrHyprGlowColor=j.hyprGlow.customColor; }
            if(j.kitty) { if(j.kitty.enabled!==undefined) root.ovrKitty=!!j.kitty.enabled; if(j.kitty.customAccent) root.ovrKittyAccent=j.kitty.customAccent; if(j.kitty.customBg) root.ovrKittyBg=j.kitty.customBg; }
            if(j.fastfetch) { if(j.fastfetch.enabled!==undefined) root.ovrFastfetch=!!j.fastfetch.enabled; if(j.fastfetch.customAccent) root.ovrFastfetchAccent=j.fastfetch.customAccent; }
            if(j.starship) { if(j.starship.enabled!==undefined) root.ovrStarship=!!j.starship.enabled; if(j.starship.customAccent) root.ovrStarshipAccent=j.starship.customAccent; }
        } catch(e){} } } }
    function saveOverrides() {
        var j = '{"hyprland":{"enabled":'+(root.ovrHyprland?'true':'false')+',"customActive":"'+root.ovrHyprActive+'","customInactive":"'+root.ovrHyprInactive+'"},"hyprGlow":{"enabled":'+(root.ovrHyprGlow?'true':'false')+',"customColor":"'+root.ovrHyprGlowColor+'"},"kitty":{"enabled":'+(root.ovrKitty?'true':'false')+',"customAccent":"'+root.ovrKittyAccent+'","customBg":"'+root.ovrKittyBg+'"},"fastfetch":{"enabled":'+(root.ovrFastfetch?'true':'false')+',"customAccent":"'+root.ovrFastfetchAccent+'"},"starship":{"enabled":'+(root.ovrStarship?'true':'false')+',"customAccent":"'+root.ovrStarshipAccent+'"}}';
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
            if(j.dock!==undefined) root.apDock=!!j.dock;
            if(j.dockEdge!==undefined && (""+j.dockEdge).length>0) root.apDockEdge=j.dockEdge;
            if(j.dockIcon!==undefined) root.apDockIcon=j.dockIcon;
            if(j.dockMode!==undefined && (""+j.dockMode).length>0) root.apDockMode=j.dockMode;
            if(j.dockZoom!==undefined) root.apDockZoom=!!j.dockZoom;
            if(j.dockRunning!==undefined) root.apDockRunning=!!j.dockRunning;
            if(j.dockLabels!==undefined) root.apDockLabels=!!j.dockLabels;
            if(j.mouseSens!==undefined) root.apMouseSens=j.mouseSens;
            if(j.accelProfile!==undefined) root.apAccelProfile=j.accelProfile;
            if(j.mouseNatural!==undefined) root.apMouseNatural=!!j.mouseNatural;
            if(j.tpNatural!==undefined) root.apTpNatural=!!j.tpNatural;
            if(j.tpScroll!==undefined) root.apTpScroll=j.tpScroll;
            if(j.tpTap!==undefined) root.apTpTap=!!j.tpTap;
            if(j.tpDwt!==undefined) root.apTpDwt=!!j.tpDwt;
            if(j.vrr!==undefined) root.apVrr=j.vrr;
            if(j.wpTransition!==undefined && (""+j.wpTransition).length>0) root.apWpTransition=j.wpTransition;
            if(j.wpTransitionFps!==undefined) root.apWpTransitionFps=j.wpTransitionFps;
            if(j.wpTransitionDur!==undefined) root.apWpTransitionDur=j.wpTransitionDur;
            if(j.wpRotate!==undefined) root.apWpRotate=!!j.wpRotate;
            if(j.wpRotateMins!==undefined) root.apWpRotateMins=j.wpRotateMins;
            if(j.wpRotateMode!==undefined && (""+j.wpRotateMode).length>0) root.apWpRotateMode=j.wpRotateMode;
            if(j.wpDir!==undefined && (""+j.wpDir).length>0) root.apWpDir=""+j.wpDir;
            if(j.wpRecursive!==undefined) root.apWpRecursive=!!j.wpRecursive;
            if(j.wpRotateStills!==undefined) root.apWpRotateStills=!!j.wpRotateStills;
            if(j.wpCoverStill!==undefined) root.apWpCoverStill=!!j.wpCoverStill;
            if(j.wpBatteryStill!==undefined) root.apWpBatteryStill=!!j.wpBatteryStill;
            if(j.wpDayNight!==undefined) root.apWpDayNight=!!j.wpDayNight;
            if(j.wpDay!==undefined) root.apWpDay=""+j.wpDay;
            if(j.wpNight!==undefined) root.apWpNight=""+j.wpNight;
            if(j.wpLockOwn!==undefined) root.apWpLockOwn=!!j.wpLockOwn;
            if(j.wpLock!==undefined) root.apWpLock=""+j.wpLock;
            if(j.wpVidFps!==undefined) root.apWpVidFps=parseInt(j.wpVidFps)||0;
            if(j.edge==="top"||j.edge==="bottom"||j.edge==="left"||j.edge==="right") root.apEdge=j.edge;
            // modeSource is the newer key; a config written before it existed only has autoDark,
            // so derive from that rather than silently dropping someone's schedule back to manual.
            if(j.modeSource==="manual"||j.modeSource==="clock"||j.modeSource==="wallpaper") root.apModeSource=j.modeSource;
            else if(j.autoDark!==undefined) root.apModeSource = j.autoDark ? "clock" : "manual";
            if(j.wgStyle && typeof j.wgStyle === "object") root.apWgStyle = j.wgStyle;
            if(j.attnFlash!==undefined) root.apAttnFlash=!!j.attnFlash;
            if(j.attnFocus!==undefined) root.apAttnFocus=!!j.attnFocus;
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
            if(j.wgNet!==undefined) root.wgNet=!!j.wgNet;
            if(j.wgUpdates!==undefined) root.wgUpdates=!!j.wgUpdates;
            if(j.wgSystem!==undefined) root.wgSystem=!!j.wgSystem;
            if(j.wgVolume!==undefined) root.wgVolume=!!j.wgVolume;
            if(j.wgBattery!==undefined) root.wgBattery=!!j.wgBattery;
            if(j.wgClock!==undefined) root.wgClock=!!j.wgClock;
            if(j.wgPower!==undefined) root.wgPower=!!j.wgPower;
            if(j.wgQuick!==undefined) root.wgQuick=!!j.wgQuick;
            if(j.wgNight!==undefined) root.wgNight=!!j.wgNight;
            if(j.wgMic!==undefined) root.wgMic=!!j.wgMic;
            if(j.sysShow!==undefined && Array.isArray(j.sysShow) && j.sysShow.length) root.apSysShow=j.sysShow;
            if(j.barShape==="bar"||j.barShape==="pills") root.apBarShape=j.barShape;
            if(j.wsStyle==="grow"||j.wsStyle==="pill"||j.wsStyle==="circle") root.apWsStyle=j.wsStyle;
            if(j.wsLabel!==undefined && (""+j.wsLabel).length>0) root.apWsLabel=""+j.wsLabel;
            if(j.barLogo!==undefined && (""+j.barLogo).length>0) root.apBarLogo=""+j.barLogo;
            if(j.barLogoPath!==undefined) root.apBarLogoPath=""+j.barLogoPath;
            if(j.welcomed!==undefined) root.apWelcomed=!!j.welcomed;
            if(j.autoHide!==undefined) root.apAutoHide=!!j.autoHide;
            if(j.hideFullscreen!==undefined) root.apHideFullscreen=!!j.hideFullscreen;
            if(j.night!==undefined) root.apNight=!!j.night;
            if(j.nightTemp!==undefined) root.apNightTemp=j.nightTemp;
            if(j.nightAuto!==undefined) root.apNightAuto=!!j.nightAuto;
            if(j.widgetOrder!==undefined && Array.isArray(j.widgetOrder) && j.widgetOrder.length>0) root.apWidgetOrder=root.wgReconcile(j.widgetOrder);
            if(j.leftOrder!==undefined && Array.isArray(j.leftOrder) && j.leftOrder.length>0) root.apLeftOrder=root.wgReconcile(j.leftOrder, root.defaultLeftOrder);
            if(j.monitors!==undefined && j.monitors && typeof j.monitors==="object") root.apMonitors=j.monitors;
            root.apLoaded = true;          // parsed cleanly — ap* now mirror the file, saving is safe
            root.apFresh  = true;          // …and the live-preview bindings may take over now
        } catch(e) {
            // An EMPTY read means there is genuinely no config yet: the declared defaults are
            // correct and writing them is right. A NON-EMPTY read that will not parse means we
            // caught the file mid-write (two installs in quick succession, or matugen rewriting
            // it) — marking loaded there would let the next save persist defaults OVER a real
            // config, silently resetting every appearance setting. Retry instead.
            if ((apOut.text || "").trim() === "") { root.apLoaded = true; root.apFresh = true; }
            else apReRead.restart();
        } } } }
    Timer { id: apReRead; interval: 400; repeat: false; onTriggered: apReadProc.running = true }
    // Gates the window until the saved palette is read, so it fades in with the user's matugen
    // colours instead of flashing the default sea-cyan for a frame first — AND gates
    // saveAppearance(), which writes every ap* property at once and would otherwise persist the
    // declared defaults over a real config if anything triggered a save during startup. That is
    // what kept switching the dock back off.
    property bool apLoaded: false
    property bool apFresh: false            // this panel's mirror is known to match the file

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
            wgNet: root.wgNet,
            wgUpdates: root.wgUpdates,
            wgSystem: root.wgSystem,
            wgVolume: root.wgVolume,
            wgBattery: root.wgBattery,
            wgClock: root.wgClock,
            wgPower: root.wgPower,
            wgQuick: root.wgQuick,
            wgNight: root.wgNight,
            wgMic: root.wgMic,
            sysShow: root.apSysShow,
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
        if (p.wgNet !== undefined) root.wgNet = p.wgNet;
        if (p.wgUpdates !== undefined) root.wgUpdates = p.wgUpdates;
        if (p.wgSystem !== undefined) root.wgSystem = p.wgSystem;
        if (p.wgVolume !== undefined) root.wgVolume = p.wgVolume;
        if (p.wgBattery !== undefined) root.wgBattery = p.wgBattery;
        if (p.wgClock !== undefined) root.wgClock = p.wgClock;
        if (p.wgPower !== undefined) root.wgPower = p.wgPower;
        if (p.wgQuick !== undefined) root.wgQuick = p.wgQuick;
        if (p.wgNight !== undefined) root.wgNight = p.wgNight;
        if (p.wgMic !== undefined) root.wgMic = p.wgMic;
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
    // Every widget that HAS a toggle must be listed here, or a saved bar layout neither stores nor
    // restores it — wgNet and wgUpdates were toggleable in the panel but absent from this list, so
    // switching between saved layouts left those two wherever they happened to be. wgRec is the
    // only correct omission: the recorder pill shows itself while recording and has no toggle.
    readonly property var barToggleKeys: ["wgMpris","wgTray","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgVolume","wgBattery","wgClock","wgPower","wgQuick","wgNet","wgUpdates","wgMic"]
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
    // Built as an OBJECT and stringified, not concatenated. The previous version was one
    // ~90-key string glued together by hand, and it broke twice in a single release: a quote
    // landing one character off truncated the file mid-key. It was also written with
    // `printf '%s' '<json>' > file` — single-quoted, so one apostrophe in a font name or a
    // wallpaper path escaped the quoting entirely, and truncating, so the bar's own watcher
    // could read a half-written config. Base64 through argv and a rename has neither failure:
    // nothing is re-parsed by a shell, and no reader ever sees a partial file.
    function saveAppearance() {
        if (!root.apLoaded) return;      // see apLoaded — never write defaults over a real config
        var j = JSON.stringify({
            radius:          Math.round(root.apRadius),
            opacity:         Number(root.apOpacity.toFixed(2)),
            height:          Math.round(root.apHeight),
            scale:           Number(root.apScale.toFixed(2)),
            accent:          root.apAccent,
            font:            root.apFont,
            customFonts:     root.apCustomFonts,
            mode:            (root.apLight?'light':'dark'),
            matugen:         root.apMatugen,
            scheme:          root.apScheme,
            barFill:         root.apBarFill,
            edge:            root.apEdge,
            dock:            root.apDock,
            dockEdge:        root.apDockEdge,
            dockIcon:        Math.round(root.apDockIcon),
            dockMode:        root.apDockMode,
            dockZoom:        root.apDockZoom,
            dockRunning:     root.apDockRunning,
            dockLabels:      root.apDockLabels,
            modeSource:      root.apModeSource,
            autoDark:        root.apModeSource === "clock",
            wgStyle:         root.apWgStyle,
            attnFlash:       root.apAttnFlash,
            attnFocus:       root.apAttnFocus,
            darkStart:       root.apDarkStart,
            darkEnd:         root.apDarkEnd,
            appMode:         root.apAppMode,
            wgMpris:         root.wgMpris,
            wgTray:          root.wgTray,
            wgWeather:       root.wgWeather,
            wgClipboard:     root.wgClipboard,
            wgNotif:         root.wgNotif,
            wgWifi:          root.wgWifi,
            wgBluetooth:     root.wgBluetooth,
            wgKdeconnect:    root.wgKdeconnect,
            wgCaffeine:      root.wgCaffeine,
            wgNet:           root.wgNet,
            wgUpdates:       root.wgUpdates,
            wgSystem:        root.wgSystem,
            wgVolume:        root.wgVolume,
            wgBattery:       root.wgBattery,
            wgClock:         root.wgClock,
            wgPower:         root.wgPower,
            wgQuick:         root.wgQuick,
            wgNight:         root.wgNight,
            wgMic:           root.wgMic,
            barShape:        root.apBarShape,
            wsStyle:         root.apWsStyle,
            wsLabel:         root.apWsLabel,
            barLogo:         root.apBarLogo,
            barLogoPath:     root.apBarLogoPath,
            welcomed:        root.apWelcomed,
            autoHide:        root.apAutoHide,
            hideFullscreen:  root.apHideFullscreen,
            night:           root.apNight,
            nightTemp:       Math.round(root.apNightTemp),
            nightAuto:       root.apNightAuto,
            mouseSens:       Number(root.apMouseSens.toFixed(2)),
            accelProfile:    root.apAccelProfile,
            mouseNatural:    root.apMouseNatural,
            tpNatural:       root.apTpNatural,
            tpScroll:        Number(root.apTpScroll.toFixed(2)),
            tpTap:           root.apTpTap,
            tpDwt:           root.apTpDwt,
            vrr:             Math.round(root.apVrr),
            wpTransition:    root.apWpTransition,
            wpTransitionFps: Math.round(root.apWpTransitionFps),
            wpTransitionDur: Number(root.apWpTransitionDur.toFixed(2)),
            wpRotate:        root.apWpRotate,
            wpRotateMins:    Math.round(root.apWpRotateMins),
            wpRotateMode:    root.apWpRotateMode,
            wpDir:           root.apWpDir,
            wpRecursive:     root.apWpRecursive,
            wpRotateStills:  root.apWpRotateStills,
            wpCoverStill:    root.apWpCoverStill,
            wpBatteryStill:  root.apWpBatteryStill,
            wpDayNight:      root.apWpDayNight,
            wpDay:           root.apWpDay,
            wpNight:         root.apWpNight,
            wpLockOwn:       root.apWpLockOwn,
            wpLock:          root.apWpLock,
            wpVidFps:        Math.round(root.apWpVidFps),
            sysShow:         root.apSysShow,
            widgetOrder:     root.apWidgetOrder,
            leftOrder:       root.apLeftOrder,
            monitors:        root.apMonitors
        });
        var d = "\"$HOME/.config/sea-shell\"";
        run("mkdir -p " + d + " && printf %s " + JSON.stringify(Qt.btoa(j))
            + " | base64 -d > " + d + "/appearance.json.tmp && "
            + "mv -f " + d + "/appearance.json.tmp " + d + "/appearance.json");
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
    property string modeScript:    Qt.resolvedUrl("sea-theme-from-wallpaper.sh").toString().replace("file://","")
    // Picking "the wallpaper" has to decide something NOW. Otherwise the setting appears to do
    // nothing at all until the next time you happen to change wallpaper, which is exactly how it
    // was reported. The sleep is because saveAppearance() writes the config from its own detached
    // process, and this script reads modeSource back out of that file — start it in the same
    // instant and it reads the value you just replaced and no-ops.
    function applyModeFromWallpaper() { run("sleep 0.4; sh '" + root.modeScript + "'") }

    // CHOOSING A COLOUR BY HAND IS AN OVERRIDE, and an override the next wallpaper silently
    // undoes is not one — the same rule the light/dark source follows. With match-colours left
    // on, picking a swatch wrote your colour and then had matugen re-derive one from the
    // wallpaper over the top of it a moment later, so the pick visibly did not take.
    //
    // The sleep is a second, separate hazard: saveAppearance() writes the config from its own
    // detached process, and the script reads that file. Started in the same instant, it can read
    // the accent you just replaced and write the old one straight back.
    function pickAccent(c) {
        root.apAccent = c;
        root.apMatugen = false;                 // yours now, until you turn matching back on
        root.saveAppearance();
        run("sleep 0.4; sh '" + root.matugenScript + "'");
    }
    // The wallpaper's OWN colours are a different case: choosing one of these is choosing what
    // matching would have given you, so matching stays on.
    function pickPaletteAccent(c) {
        root.apAccent = c;
        root.saveAppearance();
        run("sleep 0.4; sh '" + root.matugenScript + "'");
    }
    property string wpCycleScript:  Qt.resolvedUrl("sea-wallpaper-cycle.sh").toString().replace("file://","")
    property string wpRotateScript: Qt.resolvedUrl("sea-wallpaper-rotate.sh").toString().replace("file://","")
    property string wpApplyScript:  Qt.resolvedUrl("sea-wallpaper-apply.sh").toString().replace("file://","")
    property string lockwallScript: Qt.resolvedUrl("sea-lockwall.sh").toString().replace("file://","")
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
            root.pickAccent(col);
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
    // `nmcli dev wifi` prints NM's CACHE, not a scan — NM re-probes the air only every few
    // minutes on its own, so a "refresh" that just re-reads the cache redraws identical rows.
    // `list --rescan yes` re-probes AND waits for the result, which is what a refresh has to do.
    // (The old rescan-then-read pair raced: `run()` is detached, so the read fired long before
    // the rescan had finished and picked up the pre-scan cache anyway.)
    function wifiScanCmd(force) {
        return ["sh", "-c", "nmcli -t -f ACTIVE,SIGNAL,SECURITY,SSID dev wifi list --rescan "
            + (force ? "yes" : "no") + " 2>/dev/null | awk -F: 'length($4)>0'"];
    }
    Process {
        id: wifiScan; running: true
        command: root.wifiScanCmd(false)
        stdout: StdioCollector {
            id: wifiOut
            onStreamFinished: {
                // one row comes back per BSSID — a mesh/repeater network repeats its SSID, so
                // collapse each name down to its strongest sighting before listing.
                var best = {}, order = [];
                var lines = wifiOut.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split(":");
                    var sid = p.slice(3).join(":").replace(/\\:/g, ":");   // terse mode escapes ':' in SSIDs
                    if (!sid) continue;
                    var e = { active: p[0] === "yes", signal: parseInt(p[1]) || 0, secure: (p[2] || "").length > 0, ssid: sid };
                    if (!(sid in best)) { best[sid] = e; order.push(sid) }
                    else if (e.signal > best[sid].signal) { e.active = e.active || best[sid].active; best[sid] = e }
                    else if (e.active) best[sid].active = true;
                }
                var out = order.map(function (s) { return best[s] });
                out.sort(function (a, b) { return b.signal - a.signal });
                root.wifiList = out;
            }
        }
    }
    // a scan already in flight is left to finish — running=true on a live Process is a no-op,
    // so re-entering here (double-click on refresh) would otherwise silently drop the request.
    function rescanWifi() {
        savedScan.running = true; infoScan.running = true;
        if (wifiScan.running) return;
        wifiScan.command = root.wifiScanCmd(true);
        wifiScan.running = true;
    }
    // Network tab open → keep re-probing so the list stays live instead of freezing on whatever
    // the tab-open scan happened to catch. refreshTab() already fires the scan on open.
    Timer { interval: 10000; running: root.shown && root.tab === 2; repeat: true; onTriggered: root.rescanWifi() }

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

    // Region heading: mono, uppercase, tracked, over a hard rule that runs the full width. The
    // heading is no longer accent-coloured — with one heading per group the accent was doing
    // decoration, not signalling, and it competed with genuinely active controls below it.
    component Section: ColumnLayout {
        property string title: ""
        property string icon: ""
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.topMargin: 4
        spacing: 4
        RowLayout {
            spacing: 8
            Sym { text: icon; sz: 15; color: Tok.ink3 }
            Text { text: title; color: Tok.ink2; font.pixelSize: Tok.tLabel; font.family: Tok.mono
                font.weight: 600; font.letterSpacing: 1.15; font.capitalization: Font.AllUppercase }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }
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
            width: parent.width; height: 6; radius: Tok.r
            color: theme.a(theme.line, 0.8)
            Rectangle { width: track.width * sl.clamp(sl.value); height: parent.height; radius: Tok.r; color: sl.fill }
        }
        Rectangle {
            width: 15; height: 15; radius: Tok.r
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
        implicitWidth: 44; implicitHeight: 24; radius: Tok.r
        color: on ? Tok.accent : Tok.sunken
        border.width: 1; border.color: on ? Tok.accent : Tok.ruleHard
        Behavior on color { ColorAnimation { duration: 120 } }
        // knob must contrast with whatever it sits ON: accent-ink over the lit track, tertiary
        // ink over the dark one. (It was a single fixed colour, which the palette change broke.)
        Rectangle { width: 18; height: 18; radius: Tok.r; y: 3; x: tg.on ? tg.width - width - 3 : 3
            color: tg.on ? Tok.accentInk : Tok.ink3
            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } } }
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
        radius: Tok.r
        color: tcMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.4)
        border.width: 1; border.color: tc.on ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
        Behavior on color { ColorAnimation { duration: 110 } }
        RowLayout {
            id: tcRow
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
            Sym { visible: tc.icon !== ""; text: tc.icon; sz: 19; color: tc.on ? theme.frost : theme.sub; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout { spacing: 2; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                Text { visible: tc.title !== ""; text: tc.title; color: theme.text; font.pixelSize: 13; font.family: Tok.mono; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { visible: tc.desc !== ""; text: tc.desc; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; wrapMode: Text.WordWrap } }
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
        Text { text: sr.label; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
        Slider { fill: sr.tint; value: sr.value; onMoved: (v) => sr.moved(v) }
        Text { text: sr.readout; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight }
    }

    // selectable pill for choice groups (resolution, scheme, profile, …)
    component Chip: Rectangle {
        id: ch
        property string label: ""
        property string icon: ""
        // Some chips ARE their symbol — the workspace numbering picker shows ⚀⚁⚂ rather than
        // the word "dice" — and the UI font does not necessarily have them.
        property string labelFont: Tok.mono
        property bool on: false
        signal picked()
        implicitWidth: chRow.implicitWidth + 24; implicitHeight: 32; radius: Tok.r
        color: on ? theme.iris : (chMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.16)
        Behavior on color { ColorAnimation { duration: 100 } }
        Row { id: chRow; anchors.centerIn: parent; spacing: 6
            Sym { visible: ch.icon !== ""; anchors.verticalCenter: parent.verticalCenter; text: ch.icon; sz: 15; color: ch.on ? Tok.accentInk : Tok.ink2 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: ch.label; color: ch.on ? Tok.accentInk : Tok.ink; font.pixelSize: 12; font.family: ch.labelFont; font.bold: ch.on } }
        MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.picked() }
    }

    // accent action button (Apply, Save, …)
    component AccentBtn: Rectangle {
        id: ab
        property string label: ""
        property string icon: ""
        property bool enabled: true
        signal clicked()
        Layout.fillWidth: true; implicitHeight: 40; radius: Tok.r
        opacity: ab.enabled ? 1 : 0.45
        color: abMa.containsMouse && ab.enabled ? theme.iris : theme.a(theme.iris, 0.22)
        border.width: 1; border.color: theme.iris
        Behavior on color { ColorAnimation { duration: 110 } }
        RowLayout { anchors.centerIn: parent; spacing: 8
            Sym { visible: ab.icon !== ""; text: ab.icon; sz: 17; color: abMa.containsMouse && ab.enabled ? Tok.accentInk : Tok.ink2 }
            Text { text: ab.label; color: abMa.containsMouse && ab.enabled ? Tok.accentInk : Tok.ink; font.pixelSize: 13; font.family: Tok.mono; font.bold: true } }
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
            Layout.fillWidth: true; implicitHeight: 42; radius: Tok.r
            color: rma.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.38)
            border.width: 1; border.color: rma.containsMouse ? theme.iris : theme.a(theme.iris, 0.16)
            Behavior on color { ColorAnimation { duration: 110 } }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 13; anchors.rightMargin: 13; spacing: 10
                Sym { text: parent.parent.parent.icon; sz: 19; color: parent.parent.parent.tint }
                Text { text: parent.parent.parent.label; color: theme.text; font.pixelSize: 13; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            MouseArea {
                id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.run(parent.parent.cmd); if (parent.parent.quitAfter) root.closePanel() }
            }
        }
    }

    // ---------- the wallpaper shelf ----------
    // The picker's index, read here too, so the day/night pair can be chosen by LOOKING at
    // wallpapers rather than by typing two absolute paths into two text fields. Same script,
    // same cache, same poster frames — settings is not allowed a second opinion about what
    // is in the wallpaper folder.
    property var wpIndex: []
    property bool wpIndexBusy: false
    Process {
        id: wpIndexProc
        command: ["python3", Qt.resolvedUrl("sea-wallpaper-index.py").toString().replace("file://","")]
        stdout: StdioCollector { id: wpIxOut; onStreamFinished: {
            var out = [], lines = wpIxOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].split("\t");
                // EIGHT. The indexer grew an mtime column for the picker's "newest" sort and
                // this length check was not moved with it, so every row failed and the folder
                // reported zero wallpapers while being full of them.
                // `< 8`, not `!== 8`. The indexer has grown a column twice now (collection, then
                // mtime, then the full-resolution still) and each time an exact-length check
                // somewhere silently dropped every row — a folder of wallpapers reporting
                // itself empty. Extra columns are none of this parser's business.
                if (f.length < 8 || !f[0]) continue;
                out.push({ path: f[0], name: f[0].slice(f[0].lastIndexOf("/") + 1),
                           poster: f[4], coll: f[6] || "", vid: f[4].length > 0 });
            }
            root.wpIndex = out;
            root.wpIndexBusy = false;
            root.wpScanned = true;
            wpScanGuard.stop();
        } }
    }
    // Scanned at least once, as opposed to scanned and genuinely empty. Without it "0
    // wallpapers" is what a folder full of wallpapers looks like when the scan never ran, and
    // the two are indistinguishable from the outside — which is exactly the state this got
    // stuck in.
    property bool wpScanned: false
    function rescanWallpapers() {
        if (root.wpIndexBusy) return;
        root.wpIndexBusy = true;
        wpIndexProc.running = true;
        wpScanGuard.restart();
    }
    // If the process never reports back — it failed to start, python is missing, stdout never
    // closed — `wpIndexBusy` would stay true forever and every later rescan, including the
    // button, would return at the guard above. One wedged scan meant no scan ever again.
    Timer {
        id: wpScanGuard; interval: 12000; repeat: false
        onTriggered: if (root.wpIndexBusy) { root.wpIndexBusy = false; root.wpScanned = true }
    }

    // The config stores whatever the user typed; the browser deals in absolute paths.
    // Kept as "~/…" wherever it can be, because that is the form that survives being read
    // on a machine whose home is somewhere else.
    function expandHome(p) {
        if (!p || !p.length) return root.homeDir;
        if (p.charAt(0) === "~") return root.homeDir + p.slice(1);
        return p;
    }
    function shortenHome(p) {
        if (!p) return "";
        return (p.indexOf(root.homeDir + "/") === 0) ? "~" + p.slice(root.homeDir.length) : p;
    }
    function wpStill(w) { return !w ? "" : (w.vid ? w.poster : w.path) }
    function wpNamed(path) {
        for (var i = 0; i < root.wpIndex.length; i++)
            if (root.wpIndex[i].path === path) return root.wpIndex[i];
        return null;
    }
    readonly property int wpCollCount: {
        var seen = {}, n = 0;
        for (var i = 0; i < root.wpIndex.length; i++) {
            var c = root.wpIndex[i].coll;
            if (c && !seen[c]) { seen[c] = true; n++ }
        }
        return n;
    }

    // ---- a wallpaper as a CARTRIDGE ----
    // The picker commits by dropping a cartridge into a deck. Choosing which wallpaper is
    // loaded automatically at dusk is the same act, decided in advance — so it is the same
    // object: a labelled plate with a picture on it and a key notch down one side, sitting
    // in a slot that is either occupied or plainly empty.
    //
    // The notch is not decoration. It is the one marking on here that says which way up
    // this goes, which is the only thing a physical cartridge's shape ever told you.
    component CartTile: Rectangle {
        id: ct
        property string slot: ""            // DAY / NIGHT — the tracked legend
        property string path: ""
        property bool armed: false          // waiting for a pick off the shelf
        signal picked()
        signal cleared()

        readonly property var entry: root.wpNamed(ct.path)
        readonly property bool filled: ct.path.length > 0

        implicitWidth: 208; implicitHeight: 132
        radius: Tok.rSmall
        clip: true
        color: Tok.sunken
        border.width: ct.armed ? 2 : 1
        border.color: ct.armed ? Tok.accent : (ctMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
        Behavior on border.color { ColorAnimation { duration: Tok.mFast } }

        Image {
            anchors { fill: parent; margins: ct.border.width; bottomMargin: 26 + ct.border.width }
            visible: ct.filled
            source: ct.entry ? Tok.fileUrl(root.wpStill(ct.entry)) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: true
            sourceSize.height: 240
        }

        // empty slot — an opening with nothing in it, said the way the deck says it
        Column {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -13
            spacing: 4
            visible: !ct.filled
            Sym { anchors.horizontalCenter: parent.horizontalCenter
                  text: "add_photo_alternate"; sz: 22; color: Tok.ink3 }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   text: ct.armed ? "pick one below" : "empty"
                   color: ct.armed ? Tok.accent : Tok.ink3
                   font.pixelSize: Tok.tLabel; font.family: Tok.mono
                   font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase }
        }

        // the label plate
        Rectangle {
            id: ctPlate
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 26
            color: Tok.raised
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1; color: Tok.ruleHard }
            Row {
                anchors { left: parent.left; leftMargin: 8; right: ctClear.left; rightMargin: 6
                          verticalCenter: parent.verticalCenter }
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ct.slot; color: Tok.accent
                    font.pixelSize: Tok.tLabel; font.family: Tok.mono; font.weight: 700
                    font.letterSpacing: 1.3; font.capitalization: Font.AllUppercase
                }
                Rectangle { anchors.verticalCenter: parent.verticalCenter
                            width: 1; height: 12; color: Tok.ruleHard }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - 96)
                    text: ct.filled ? (ct.entry ? ct.entry.name : ct.path.slice(ct.path.lastIndexOf("/") + 1))
                                    : "—"
                    color: Tok.ink2; font.pixelSize: Tok.tData; font.family: Tok.mono
                    elide: Text.ElideMiddle
                }
            }
            Sym {
                id: ctClear
                anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
                visible: ct.filled
                text: "backspace"; sz: 14
                color: ctClearMa.containsMouse ? Tok.crit : Tok.ink3
                MouseArea { id: ctClearMa; anchors.fill: parent; anchors.margins: -5
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: ct.cleared() }
            }
        }

        // The key notch, in the ground's own colour so it reads as absent material rather
        // than as a painted mark. TOP corner, which is where a cartridge is actually keyed —
        // and, on the profile cartridge that shares this detail, the only edge where a
        // notch does not take a bite out of the accent band that identifies it.
        Rectangle {
            anchors { right: parent.right; top: parent.top }
            width: 18; height: 10
            color: Tok.bg
            Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 1; color: Tok.ruleHard }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: Tok.ruleHard }
        }

        // registration corners while armed — the same four brackets the picker puts on the
        // panel it has hold of, meaning the same thing: this one is the target.
        Repeater {
            model: ct.armed ? 4 : 0
            Item {
                required property int index
                readonly property bool onRight: (index % 2) === 1
                readonly property bool onBottom: index >= 2
                // 4px, matching the picker's brackets. At 3 they were technically drawn and
                // practically invisible — the same measuring mistake the picker's own
                // corners needed correcting for.
                readonly property real arm: 16
                width: arm; height: arm
                x: onRight ? ct.width - arm : 0
                y: onBottom ? ct.height - 26 - arm : 0
                Rectangle { width: parent.arm; height: 4; color: Tok.accent
                            y: parent.onBottom ? parent.arm - 4 : 0 }
                Rectangle { width: 4; height: parent.arm; color: Tok.accent
                            x: parent.onRight ? parent.arm - 4 : 0 }
            }
        }

        MouseArea { id: ctMa; anchors.fill: parent; anchors.bottomMargin: 26
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: ct.picked() }
    }

    // ---- the shelf a cartridge is picked off ----
    // Only while a slot is armed. A row of every wallpaper you own, permanently on display
    // under slots that are already full, would be the largest thing on this page and would
    // answer nothing. Two groups need one (the day/night pair, and the lock screen), which
    // is why it is a component rather than a block of markup written twice.
    component WallShelf: Rectangle {
        id: sh
        property bool open: false
        property string chosen: ""
        signal picked(string path)

        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        // Via a plain property: QML has no Behavior on an ATTACHED property, so animating
        // Layout.preferredHeight directly is not a slower open, it is an error.
        property real shelfH: sh.open ? 104 : 0
        Behavior on shelfH { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
        Layout.preferredHeight: shelfH
        visible: shelfH > 1
        clip: true
        radius: Tok.r
        color: Tok.sunken
        border.width: 1; border.color: Tok.ruleHard

        Text {
            anchors.centerIn: parent
            visible: !root.wpIndex.length
            text: root.wpIndexBusy ? "scanning…" : "no wallpapers in that folder"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.mono
        }

        ListView {
            id: shelfList
            anchors.fill: parent; anchors.margins: 10
            orientation: ListView.Horizontal
            spacing: 8
            clip: true
            model: root.wpIndex
            delegate: Rectangle {
                id: shelfItem
                required property var modelData
                readonly property bool isChosen: sh.chosen === modelData.path
                width: 132; height: shelfList.height
                radius: Tok.rSmall
                clip: true
                color: Tok.bg
                border.width: shelfItem.isChosen ? 2 : 1
                border.color: shelfItem.isChosen ? Tok.accent
                            : (shelfMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
                Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                Image {
                    anchors.fill: parent; anchors.margins: shelfItem.border.width
                    source: root.wpStill(shelfItem.modelData).length
                            ? Tok.fileUrl(root.wpStill(shelfItem.modelData)) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; cache: true
                    sourceSize.height: 160
                }
                // motion marker, exactly as the picker draws it — a moving wallpaper is a
                // different kind of thing and that has to be visible wherever one is offered
                Rectangle {
                    visible: shelfItem.modelData.vid
                    anchors { top: parent.top; left: parent.left; margins: 4 }
                    width: 16; height: 16; radius: Tok.rSmall
                    color: Tok.alpha(Tok.bg, 0.72)
                    Sym { anchors.centerIn: parent; text: "play_arrow"; sz: 12; color: Tok.ink }
                }
                MouseArea {
                    id: shelfMa
                    anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sh.picked(shelfItem.modelData.path)
                }
            }
        }
    }

    // ---- a theme profile as a CARTRIDGE ----
    // Same object as the wallpaper pair above, for the same reason: a saved preset is a
    // thing you LOAD into the machine, and loading one changes the whole desktop. The row
    // of "Load" buttons this replaces described a preset in words — font, radius, and a hex
    // string — which is the one way of showing a palette that cannot show you the palette.
    //
    // A profile has no picture, so its face IS its palette: the four background steps and
    // the accent, laid out in the order the design language stacks them.
    //
    // The ramp is re-derived here rather than read from Tok, because Tok can only ever
    // describe the palette that is currently ACTIVE — and every cartridge on this shelf is
    // by definition one that is not.
    function profHue(p) {
        var c = Qt.color(p && p.accent ? p.accent : "#63c7dd");
        return c.hslHue >= 0 ? c.hslHue : 0.55;
    }
    function profLight(p) { return p && ("" + p.mode) === "light" }
    function profStep(p, i) {
        var h = root.profHue(p), lt = root.profLight(p);
        if (i === 0) return lt ? Qt.hsla(h, 0.07, 0.940, 1) : Qt.hsla(h, 0.14, 0.072, 1);  // bg
        if (i === 1) return lt ? Qt.hsla(h, 0.09, 0.972, 1) : Qt.hsla(h, 0.13, 0.104, 1);  // surface
        if (i === 2) return lt ? Qt.hsla(h, 0.10, 1.000, 1) : Qt.hsla(h, 0.12, 0.136, 1);  // raised
        return lt ? Qt.hsla(h, 0.08, 0.898, 1) : Qt.hsla(h, 0.16, 0.046, 1);               // sunken
    }
    function profAccent(p) {
        var c = Qt.color(p && p.accent ? p.accent : "#63c7dd");
        var h = root.profHue(p), sat = c.hslSaturation;
        return root.profLight(p)
            ? Qt.hsla(h, Math.max(0.35, Math.min(0.95, sat)), 0.34, 1)
            : Qt.hsla(h, Math.max(0.42, Math.min(0.95, sat)), 0.62, 1);
    }
    // Which cartridge is in the machine. Compared on what a profile actually sets rather
    // than on its name, so a preset you have since edited stops claiming to be loaded.
    function profLoaded(p) {
        if (!p) return false;
        return ("" + p.accent).toLowerCase() === ("" + root.apAccent).toLowerCase()
            && ("" + p.font) === ("" + root.apFont)
            && Math.round(p.radius) === Math.round(root.apRadius)
            && root.profLight(p) === root.apLight;
    }

    component ProfileCart: Rectangle {
        id: pc
        property var profile: null
        property bool loaded: false
        signal load()
        signal eject()

        implicitWidth: 176; implicitHeight: 116
        radius: Tok.rSmall
        clip: true
        color: Tok.sunken
        border.width: pc.loaded ? 2 : 1
        border.color: pc.loaded ? Tok.accent : (pcMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
        Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
        // The dip on press: 3px of the machine taking the object. Anticipation is the whole
        // reason the picker's insert reads as force rather than as a position change, and it
        // costs one Behavior here.
        transform: Translate { y: pcMa.pressed ? 3 : 0
                               Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } } }

        // The face. Three neutral steps and the accent, with hairlines between them —
        // without those a low-saturation preset (the shipped "BW" is four shades of
        // near-white) draws four bands you cannot tell apart, and the cartridge looks blank
        // rather than pale. The rules are the profile's OWN rule colour, so the separation
        // is drawn in the palette being previewed rather than in the one you are sitting in.
        Item {
            id: pcFace
            anchors { fill: parent; margins: pc.border.width; bottomMargin: 26 + pc.border.width }

            Column {
                anchors.fill: parent
                Repeater {
                    model: 3
                    Rectangle {
                        required property int index
                        width: pcFace.width
                        height: (pcFace.height - 14) / 3
                        color: root.profStep(pc.profile, index)
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 1
                            color: root.profLight(pc.profile)
                                   ? Qt.hsla(root.profHue(pc.profile), 0.10, 0.845, 1)
                                   : Qt.hsla(root.profHue(pc.profile), 0.12, 0.190, 1)
                        }
                    }
                }
                // The accent gets a band rather than a dot: it is the single fact that
                // distinguishes one preset from another, and a 30px circle floating in the
                // corner was decoration standing in for it.
                Rectangle {
                    width: pcFace.width; height: 14
                    color: root.profAccent(pc.profile)
                }
            }

            // light or dark, said once, in the palette's own ink
            Sym {
                anchors { left: parent.left; top: parent.top; margins: 7 }
                text: root.profLight(pc.profile) ? "light_mode" : "dark_mode"
                sz: 15
                color: root.profLight(pc.profile) ? Qt.hsla(root.profHue(pc.profile), 0.16, 0.09, 1)
                                                  : Qt.hsla(root.profHue(pc.profile), 0.08, 0.912, 1)
            }

            // The spec, printed on the label the way a spec is printed on hardware — in the
            // preset's own secondary ink, over its own raised step. This is what the row
            // this replaces spent a whole line of prose on.
            Text {
                anchors { left: parent.left; right: parent.right; leftMargin: 7; rightMargin: 7
                          bottom: parent.bottom; bottomMargin: 19 }
                text: (pc.profile ? pc.profile.font : "") + "  ·  r" + (pc.profile ? Math.round(pc.profile.radius) : 0)
                color: root.profLight(pc.profile) ? Qt.hsla(root.profHue(pc.profile), 0.12, 0.310, 1)
                                                  : Qt.hsla(root.profHue(pc.profile), 0.08, 0.680, 1)
                font.pixelSize: Tok.tLabel; font.family: Tok.mono
                font.letterSpacing: 0.6
                elide: Text.ElideRight
            }
        }

        Rectangle {
            id: pcPlate
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 26
            color: Tok.raised
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1; color: Tok.ruleHard }
            Row {
                anchors { left: parent.left; leftMargin: 8; right: pcEject.left; rightMargin: 6
                          verticalCenter: parent.verticalCenter }
                spacing: 7
                // The status lamp, exactly as the deck runs it: lit for the one that is in.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7; height: 7; radius: 3.5
                    color: pc.loaded ? Tok.accent : Tok.alpha(Tok.ink3, 0.40)
                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - 26)
                    text: pc.profile ? pc.profile.name : ""
                    color: Tok.ink; font.pixelSize: Tok.tData; font.family: Tok.mono
                    font.weight: pc.loaded ? 700 : 400
                    elide: Text.ElideRight
                }
            }
            Sym {
                id: pcEject
                anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
                text: "eject"; sz: 15
                color: pcEjectMa.containsMouse ? Tok.crit : Tok.ink3
                MouseArea { id: pcEjectMa; anchors.fill: parent; anchors.margins: -5
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: pc.eject() }
            }
        }

        // the key notch — the one marking that says which way up this goes
        Rectangle {
            anchors { right: parent.right; top: parent.top }
            width: 18; height: 10
            color: Tok.bg
            Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 1; color: Tok.ruleHard }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: Tok.ruleHard }
        }

        MouseArea { id: pcMa; anchors.fill: parent; anchors.bottomMargin: 26
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: pc.load() }
    }

    // a single tab button in the sidebar
    component TabBtn: Rectangle {
        property string icon: ""
        property string label: ""
        property int idx: 0
        readonly property bool sel: root.tab === idx
        Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
        color: sel ? Tok.accentWash : (tbm.containsMouse ? Tok.surface : "transparent")
        // selection is an inset accent bar plus a wash — not an outline. An outlined tab reads
        // as a button you can press again; a bar reads as "you are here".
        Rectangle {
            visible: sel
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 2; color: Tok.accent
        }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 10
            Sym { text: icon; sz: 17; color: sel ? Tok.accent : Tok.ink3 }
            Text { text: label; color: sel ? Tok.ink : Tok.ink2; font.pixelSize: Tok.tDense
                font.family: Tok.sans; font.weight: sel ? 600 : 400; Layout.fillWidth: true }
        }
        MouseArea { id: tbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = idx }
    }

    // small uppercase section heading that groups the sidebar tabs
    component GroupLabel: Text {
        Layout.fillWidth: true; Layout.topMargin: 12; Layout.leftMargin: 5; Layout.bottomMargin: 2
        color: Tok.ink3; font.pixelSize: 10; font.family: Tok.mono
        font.weight: 600; font.letterSpacing: 1.3; font.capitalization: Font.AllUppercase
    }

    // one key/value tile for the About/System dashboard
    component InfoTile: Rectangle {
        property string icon: ""
        property string iconFont: "Material Symbols Outlined"   // set "Symbols Nerd Font" for brand/distro glyphs
        property string label: ""
        property string value: "…"
        Layout.fillWidth: true; implicitHeight: 46; radius: Tok.r
        color: theme.a(theme.line, 0.24); border.width: 1; border.color: theme.a(theme.iris, 0.10)
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 11
            Sym { text: icon; sz: 19; color: theme.iris; font.family: iconFont }
            ColumnLayout {
                spacing: 1; Layout.fillWidth: true
                Text { text: label; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                Text { text: value; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
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
        Text { text: label; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.preferredWidth: 58 }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 9; radius: Tok.r; color: theme.a(theme.line, 0.8)
            Rectangle { height: parent.height; radius: Tok.r
                width: parent.width * Math.max(0, Math.min(1, parent.parent.pct / 100))
                color: parent.parent.pct > 88 ? theme.bad : parent.parent.fill
                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
        }
        Text { text: value; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.preferredWidth: 96; horizontalAlignment: Text.AlignRight }
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
            radius: Tok.rCard
            // fade in once the saved palette is read — no default sea-cyan flash first
            opacity: root.apLoaded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            // ---------------- sidebar (anchored, fixed width) ----------------
            // The tab list SCROLLS. It used to be one fixed-height ColumnLayout anchored top and
            // bottom, which silently overflowed the card the moment the tabs stopped fitting —
            // adding a single tab pushed "Actions" out past the panel's rounded edge. Trimming
            // row heights would only postpone that, so the list is a Flickable: it scrolls when
            // it must, sits still when it need not, and survives the next tab being added.
            Item {
                id: sidebar
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 18 }
                width: 202

                ColumnLayout {
                    id: sbHead
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    spacing: 3
                    // ---- brand header: logo + name + version ----
                    RowLayout {
                    spacing: 11; Layout.fillWidth: true; Layout.bottomMargin: 4
                    SeaLogo { size: 34; card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        RowLayout {
                            spacing: 6
                            Text { text: "sea-shell"; color: theme.text; font.pixelSize: 17; font.family: Tok.mono; font.bold: true }
                            Rectangle {
                                implicitHeight: 15; implicitWidth: verTxt.width + 10; radius: Tok.r
                                color: theme.a(theme.iris, 0.18); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                Text { id: verTxt; anchors.centerIn: parent; text: "v" + root.seaVersion
                                    color: theme.frost; font.pixelSize: 9; font.family: Tok.mono; font.bold: true }
                            }
                        }
                        Text { text: "control center"; color: theme.frost; font.pixelSize: 10; font.family: Tok.mono }
                    }
                }
                    Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; Layout.bottomMargin: 2; height: 1; color: theme.a(theme.iris, 0.14) }
                }

                Flickable {
                    id: sbFlick
                    anchors { left: parent.left; right: parent.right; top: sbHead.bottom; bottom: sbFoot.top }
                    anchors.topMargin: 3; anchors.bottomMargin: 6
                    clip: true
                    contentWidth: width
                    contentHeight: sbList.implicitHeight
                    // only grabs the wheel when there is somewhere to go
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    ColumnLayout {
                        id: sbList
                        width: sbFlick.width
                        spacing: 3

                        GroupLabel { text: "OVERVIEW" }
                            TabBtn { icon: "monitor_heart";        label: "System";      idx: 8 }
                            GroupLabel { text: "LOOK & FEEL" }
                            TabBtn { icon: "palette";              label: "Appearance";  idx: 4 }
                            TabBtn { icon: "view_agenda";          label: "Bar";         idx: 20 }
                            TabBtn { icon: "widgets";              label: "Bar Widgets"; idx: 12 }
                            TabBtn { icon: "dock_to_bottom";       label: "Dock";        idx: 16 }
                            TabBtn { icon: "wallpaper";            label: "Desktop";     idx: 21 }
                            TabBtn { icon: "picture_in_picture";   label: "Window rules"; idx: 17 }
                            TabBtn { icon: "auto_awesome";         label: "Theme Profiles"; idx: 13 }
                            GroupLabel { text: "DEVICES" }
                            TabBtn { icon: "volume_up";            label: "Audio";       idx: 0 }
                            TabBtn { icon: "brightness_6";         label: "Display";     idx: 1 }
                            TabBtn { icon: "wifi";                 label: "Network";     idx: 2 }
                            TabBtn { icon: "bluetooth";            label: "Bluetooth";   idx: 9 }
                            TabBtn { icon: "phonelink";            label: "KDE Connect"; idx: 14 }
                TabBtn { icon: "hard_drive";           label: "Disks";       idx: 19 }
                            GroupLabel { text: "DAILY" }
                            TabBtn { icon: "cloud";                label: "Weather";     idx: 3 }
                            TabBtn { icon: "calendar_month";       label: "Calendar";    idx: 11 }
                            TabBtn { icon: "keyboard";             label: "Keybinds";    idx: 7 }
                            TabBtn { icon: "mouse";                label: "Input";       idx: 15 }
                TabBtn { icon: "hourglass_top";        label: "Screen time"; idx: 18 }
                            GroupLabel { text: "SESSION" }
                            TabBtn { icon: "bedtime";              label: "Idle & lock"; idx: 10 }
                            TabBtn { icon: "bolt";                 label: "Actions";     idx: 5 }
                            TabBtn { icon: "power_settings_new";   label: "Power";       idx: 6 }
                    }
                }

                // hand-drawn scroll indicator — this shell does not import QtQuick.Controls
                // (its ScrollBar needs a QQuickStyle set before any QML loads), so a Rectangle
                // does the job with no new dependency.
                Rectangle {
                    visible: sbFlick.contentHeight > sbFlick.height
                    width: 3; radius: 1.5
                    color: theme.a(theme.iris, 0.45)
                    anchors.right: sbFlick.right
                    y: sbFlick.y + (sbFlick.contentHeight > 0
                        ? (sbFlick.contentY / sbFlick.contentHeight) * sbFlick.height : 0)
                    height: sbFlick.contentHeight > 0
                        ? Math.max(24, sbFlick.height * (sbFlick.height / sbFlick.contentHeight)) : 0
                }

                // pinned to the bottom of the sidebar, outside the scrolling area
                Text {
                    id: sbFoot
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    text: "esc to close"; color: theme.faint; font.pixelSize: 10
                    font.family: Tok.mono; horizontalAlignment: Text.AlignHCenter
                }
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
                                Text { text: "volume"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                Slider { value: (root.curSink && root.curSink.audio) ? root.curSink.audio.volume : 0
                                    onMoved: (v) => { if (root.curSink && root.curSink.audio) { root.curSink.audio.muted = false; root.curSink.audio.volume = v } } }
                                Text { text: (root.curSink && root.curSink.audio) ? Math.round(root.curSink.audio.volume * 100) + "%" : "—"
                                    color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } }
                            RowLayout { visible: root.curSource && root.curSource.audio; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                Sym { text: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? "mic_off" : "mic"; sz: 18
                                    color: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? theme.faint : theme.sub; Layout.alignment: Qt.AlignVCenter
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (root.curSource && root.curSource.audio) root.curSource.audio.muted = !root.curSource.audio.muted } } }
                                Text { text: "microphone"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                Slider { fill: theme.good; value: (root.curSource && root.curSource.audio) ? root.curSource.audio.volume : 0
                                    onMoved: (v) => { if (root.curSource && root.curSource.audio) { root.curSource.audio.muted = false; root.curSource.audio.volume = v } } }
                                Text { text: (root.curSource && root.curSource.audio) ? Math.round(root.curSource.audio.volume * 100) + "%" : "—"
                                    color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } }
                            Text { text: "output device"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 32
                                rows: root.sinkRows
                                selectable: true
                                selectedIndex: root.sinkSel
                                emptyText: "no output devices"
                                columns: [
                                    { label: "Device", key: "name",   flex: true },
                                    { label: "Format", key: "format", w: 96,  chip: true, num: true },
                                    { label: "Max",    key: "rate",   w: 84,  num: true }
                                ]
                                onActivated: (i, row) => { if (row._node) Pipewire.preferredDefaultAudioSink = row._node }
                            }
                            // ---- bluetooth codec (per connected BT output offering a choice) ----
                            Text { visible: root.audioBtSinks.length > 0; text: "bluetooth codec"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            ColumnLayout { visible: root.audioBtSinks.length > 0; Layout.fillWidth: true; spacing: 8
                                Repeater { model: root.audioBtSinks
                                    delegate: ColumnLayout { id: btRow; required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 5
                                        Text { text: btRow.modelData.label; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Flow { Layout.fillWidth: true; Layout.leftMargin: 4; spacing: 6
                                            Repeater { model: btRow.modelData.bt_codecs
                                                delegate: Rectangle { required property var modelData
                                                    readonly property bool on: modelData.active
                                                    implicitHeight: 26; implicitWidth: bcT.implicitWidth + 20; radius: Tok.r
                                                    color: on ? theme.a(theme.iris, 0.25) : (bcMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                                                    border.width: 1; border.color: on ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                                                    Text { id: bcT; anchors.centerIn: parent; text: modelData.codec; color: on ? theme.iris : theme.sub; font.pixelSize: 10; font.family: Tok.mono; font.bold: on }
                                                    MouseArea { id: bcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioSetCodec(btRow.modelData.name, modelData.profile) } } } } } } }
                            Text { text: "input device"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 32
                                rows: root.sourceRows
                                selectable: true
                                selectedIndex: root.sourceSel
                                emptyText: "no input devices"
                                columns: [ { label: "Device", key: "name", flex: true } ]
                                onActivated: (i, row) => { if (row._node) Pipewire.preferredDefaultAudioSource = row._node }
                            }
                            Section { title: "per-app volume"; icon: "graphic_eq" }
                            Text { visible: root.streams.length === 0; text: "nothing is playing"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.leftMargin: 14 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 8
                                Repeater { model: root.streams
                                    delegate: RowLayout { required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                        Sym { text: "music_note"; sz: 16; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                        Text { text: root.streamName(modelData); color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideRight; Layout.preferredWidth: 120 }
                                        Slider { fill: theme.iris; value: modelData.audio ? modelData.audio.volume : 0; onMoved: (v) => { if (modelData.audio) modelData.audio.volume = v } }
                                        Text { text: modelData.audio ? Math.round(modelData.audio.volume * 100) + "%" : "—"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 48; horizontalAlignment: Text.AlignRight } } } }

                            Section { title: "per-app output"; icon: "alt_route" }
                            Text { visible: root.audioStreams.length === 0; text: "nothing is playing"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.leftMargin: 14 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 12
                                Repeater { model: root.audioStreams
                                    delegate: ColumnLayout { id: appRow; required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 5
                                        RowLayout { Layout.fillWidth: true; spacing: 8
                                            Sym { text: "graphic_eq"; sz: 15; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                            Text { text: appRow.modelData.app + (appRow.modelData.title ? " — " + appRow.modelData.title : ""); color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true } }
                                        Flow { Layout.fillWidth: true; Layout.leftMargin: 23; spacing: 6
                                            Repeater { model: root.sinks
                                                delegate: Rectangle { required property var modelData
                                                    readonly property bool here: appRow.modelData.sink_id === modelData.id
                                                    implicitHeight: 24; implicitWidth: chipT.implicitWidth + 18; radius: Tok.r
                                                    color: here ? theme.a(theme.iris, 0.25) : (chipMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                                                    border.width: 1; border.color: here ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                                                    Text { id: chipT; anchors.centerIn: parent; text: modelData.nickname || root.nodeName(modelData); color: here ? theme.iris : theme.sub; font.pixelSize: 10; font.family: Tok.mono; font.bold: here }
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
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.leftMargin: 14 }

                            // ---- monitor mode ----
                            Section { title: "monitor"; icon: "monitor" }
                            // Every output at once, and the row IS the selector — picking one
                            // scopes the resolution / refresh / scale controls below to it.
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 32
                                rows: root.monRows
                                selectable: true
                                selectedIndex: root.monSel
                                emptyText: "reading monitors…"
                                columns: [
                                    { label: "Output",  key: "name",  w: 110, mono: true },
                                    { label: "Display", key: "desc",  flex: true },
                                    { label: "Mode",    key: "mode",  w: 150, num: true },
                                    { label: "Scale",   key: "scale", w: 60,  num: true },
                                    { label: "Rotate",  key: "rot",   w: 62,  num: true }
                                ]
                                onActivated: (i) => { root.monSel = i; root.selRes = ""; root.reloadMonitors() }
                            }

                            // ---- adaptive sync ----
                            // misc:vrr is GLOBAL in hyprland, not per-monitor, so it sits under
                            // the monitor table rather than inside the per-output controls.
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                Layout.topMargin: 4; spacing: 8
                                Text { text: "adaptive sync"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 100 }
                                Repeater {
                                    model: root.vrrModes
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l; on: root.apVrr === modelData.v
                                        onPicked: { root.apVrr = modelData.v; root.saveAppearance(); root.applyVrr() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; wrapMode: Text.WordWrap
                                text: root.curMon && root.curMon.vrrCapable === false
                                      ? "this panel reports no VRR support — the setting will have no effect"
                                      : "variable refresh (FreeSync / G-Sync). “fullscreen” limits it to fullscreen windows, which avoids flicker on panels that misbehave at low refresh"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            Text { text: "resolution"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: root.uniqueRes(root.curMon)
                                    delegate: Chip { required property var modelData; label: modelData; on: root.selRes === modelData
                                        onPicked: { root.selRes = modelData; var hs = root.hzFor(root.curMon, modelData); if (hs.length) root.selHz = hs[0] } } } }

                            Text { text: "refresh rate"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
                            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater { model: root.hzFor(root.curMon, root.selRes)
                                    delegate: Chip { required property var modelData; label: Math.round(parseFloat(modelData)) + " Hz"; on: root.selHz === modelData
                                        onPicked: root.selHz = modelData } } }

                            Text { text: "orientation"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 2 }
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
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

                            Repeater { model: root.displayProfiles
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    implicitHeight: 48; radius: Tok.r
                                    color: dpMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: modelData.matches ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 10; spacing: 12
                                        Sym { text: modelData.matches ? "check_circle" : "dashboard"; sz: 19
                                            color: modelData.matches ? theme.good : theme.sub; Layout.alignment: Qt.AlignVCenter }
                                        ColumnLayout { spacing: 1; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                                            Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { text: modelData.summary + (modelData.created ? "  ·  " + modelData.created : ""); color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true } }
                                        // apply
                                        Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 66; implicitHeight: 30; radius: Tok.r
                                            color: dpApplyMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "play_arrow"; sz: 14; color: dpApplyMa.containsMouse ? theme.bg : theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "apply"; color: dpApplyMa.containsMouse ? theme.bg : theme.frost; font.pixelSize: 11; font.family: Tok.mono } }
                                            MouseArea { id: dpApplyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyDisplayProfile(modelData.name) } }
                                        // delete
                                        Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 30; implicitHeight: 30; radius: Tok.r
                                            color: dpDelMa.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"; border.width: 1; border.color: theme.a(theme.bad, dpDelMa.containsMouse ? 0.5 : 0.2)
                                            Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: dpDelMa.containsMouse ? theme.bad : theme.faint }
                                            MouseArea { id: dpDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteDisplayProfile(modelData.name) } }
                                    }
                                    MouseArea { id: dpMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                } }
                            Text { visible: root.displayProfiles.length === 0; text: "no saved layouts yet"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.leftMargin: 14 }

                            // save-current row
                            RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 2; spacing: 8
                                Rectangle { Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
                                    color: theme.a(theme.line, 0.5); border.width: 1; border.color: profIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                    TextInput { id: profIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 12; font.family: Tok.mono; clip: true; selectByMouse: true
                                        text: root.profName; onTextChanged: root.profName = text
                                        onAccepted: { root.saveDisplayProfile(text); text = "" }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: profIn.text === ""; text: "name this layout…"; color: theme.faint; font.pixelSize: 12; font.family: Tok.mono } } }
                                Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 78; implicitHeight: 38; radius: Tok.r
                                    opacity: root.profName.trim() !== "" ? 1 : 0.45
                                    color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                                    Row { anchors.centerIn: parent; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "bookmark_add"; sz: 15; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "save"; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost; font.pixelSize: 11; font.family: Tok.mono } }
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
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

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
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }
                        }

                        // ================= NETWORK =================
                        ColumnLayout {
                            visible: root.tab === 2; Layout.fillWidth: true; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "wifi"; sz: 18; color: theme.iris }
                                Text { text: "wi-fi networks"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                // radio on/off toggle
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                    color: root.wifiRadio ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: root.wifiRadio ? theme.iris : theme.a(theme.line, 0.9)
                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3
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
                                Layout.fillWidth: true; implicitHeight: netCol.implicitHeight + 16; radius: Tok.r
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
                                            Text { text: modelData.k; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.preferredWidth: 56 }
                                            Text { text: modelData.v; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
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
                                        Layout.fillWidth: true; implicitHeight: asking ? 80 : 40; radius: Tok.r
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
                                                    Text { text: modelData.ssid; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    Text { text: modelData.signal + "%"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
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
                                                    Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r
                                                    color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                    TextInput { id: pwIn
                                                        anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                        verticalAlignment: TextInput.AlignVCenter
                                                        color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                                        echoMode: TextInput.Password; clip: true
                                                        Text { text: "password…"; visible: pwIn.text===""; color: theme.faint
                                                            font.pixelSize: 11; font.family: Tok.mono; anchors.verticalCenter: parent.verticalCenter }
                                                        Keys.onReturnPressed: { root.wifiJoinPw(wrow.modelData.ssid, pwIn.text); pwIn.text = "" }
                                                        Keys.onEscapePressed: (e)=> { root.wifiPwFor = ""; pwIn.text = ""; e.accepted = true }
                                                    }
                                                }
                                                Rectangle { implicitWidth: 64; implicitHeight: 28; radius: Tok.r
                                                    color: jbm.containsMouse ? theme.iris : theme.a(theme.iris, 0.25)
                                                    border.width: 1; border.color: theme.iris
                                                    Text { anchors.centerIn: parent; text: "join"; font.pixelSize: 11; font.family: Tok.mono; font.bold: true
                                                        color: jbm.containsMouse ? theme.bg : theme.frost }
                                                    MouseArea { id: jbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { root.wifiJoinPw(wrow.modelData.ssid, pwIn.text); pwIn.text = "" } } }
                                            }
                                        }
                                    }
                                }
                                Text { visible: root.wifiList.length === 0; text: root.wifiRadio ? "scanning…" : "wi-fi is off"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                                // join a hidden network
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: root.hidOpen ? 78 : 34; radius: Tok.r; clip: true
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
                                                Text { text: "join a hidden network…"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.fillWidth: true }
                                                Sym { text: root.hidOpen ? "expand_less" : "expand_more"; sz: 16; color: theme.faint } }
                                        }
                                        RowLayout {
                                            visible: root.hidOpen; Layout.fillWidth: true; spacing: 8
                                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r
                                                color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                TextInput { id: hidSsid; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                    verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; clip: true
                                                    Text { text: "ssid"; visible: hidSsid.text===""; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; anchors.verticalCenter: parent.verticalCenter } } }
                                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r
                                                color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                                TextInput { id: hidPw; anchors { fill: parent; leftMargin: 9; rightMargin: 9 }
                                                    verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; echoMode: TextInput.Password; clip: true
                                                    Text { text: "password (blank if open)"; visible: hidPw.text===""; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; anchors.verticalCenter: parent.verticalCenter }
                                                    Keys.onReturnPressed: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text=""; hidPw.text="" } } }
                                            Rectangle { implicitWidth: 56; implicitHeight: 28; radius: Tok.r
                                                color: hjm.containsMouse ? theme.iris : theme.a(theme.iris, 0.25); border.width: 1; border.color: theme.iris
                                                Text { anchors.centerIn: parent; text: "join"; font.pixelSize: 11; font.family: Tok.mono; font.bold: true
                                                    color: hjm.containsMouse ? theme.bg : theme.frost }
                                                MouseArea { id: hjm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.wifiJoinHidden(hidSsid.text, hidPw.text); hidSsid.text=""; hidPw.text="" } } }
                                        }
                                    }
                                }
                                Text { visible: root.wifiMsg !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; text: root.wifiMsg
                                    color: root.wifiMsg.indexOf("✓") >= 0 ? theme.good : root.wifiMsg.indexOf("wrong") >= 0 ? theme.bad : theme.sub
                                    font.pixelSize: 11; font.family: Tok.mono }
                                Text { Layout.fillWidth: true; wrapMode: Text.Wrap; text: "click to connect / disconnect · the trash icon forgets a saved network · secured ones ask inline"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.topMargin: 4 }
                            }
                        }

                        // ================= VPN =================
                        ColumnLayout {
                            visible: root.tab === 2; Layout.fillWidth: true; spacing: 10

                            // WARP header row
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "security"; sz: 18; color: root.warpConnected ? theme.good : theme.iris }
                                Text { text: "Cloudflare WARP"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                    color: root.warpConnected ? theme.a(theme.good, 0.4) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: root.warpConnected ? theme.good : theme.a(theme.line, 0.9)
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3
                                        x: root.warpConnected ? parent.width - 19 : 3
                                        color: root.warpConnected ? theme.frost : theme.faint
                                        Behavior on x { NumberAnimation { duration: 130 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.warpToggle() } }
                            }

                            // WARP status + mode chips
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text { text: root.warpStatus; color: root.warpConnected ? theme.good : theme.faint
                                    font.pixelSize: 11; font.family: Tok.mono }
                                Item { Layout.fillWidth: true }
                                Repeater { model: ["warp","doh","warp+doh","tunnel_only"]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.warpMode === modelData
                                        implicitHeight: 20; radius: Tok.r; implicitWidth: wmt.implicitWidth + 14
                                        color: cur ? theme.a(theme.good, 0.25) : (wma2.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.3))
                                        border.width: cur ? 1 : 0; border.color: theme.a(theme.good, 0.45)
                                        Text { id: wmt; anchors.centerIn: parent; text: modelData
                                            color: cur ? theme.good : theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: cur }
                                        MouseArea { id: wma2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.warpSetMode(modelData) } } }
                            }

                            // VPN connections divider
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8; Layout.topMargin: 4
                                Sym { text: "vpn_key"; sz: 18; color: theme.iris }
                                Text { text: "VPN connections"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                            }

                            // saved VPN list
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Text { visible: root.vpnList.length === 0; text: "no VPN profiles saved — import one below"
                                    color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                                Repeater {
                                    model: root.vpnList
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool connecting: modelData.state === "activating" || root.vpnActionName === modelData.name
                                        readonly property bool failed: root.vpnFailedName === modelData.name
                                        Layout.fillWidth: true; implicitHeight: 50; radius: Tok.r
                                        color: modelData.active ? theme.a(theme.iris, 0.18) : (connecting ? theme.a(theme.frost, 0.08) : theme.a(theme.line, 0.35))
                                        border.width: 1; border.color: failed ? theme.bad : (modelData.active ? theme.a(theme.iris, 0.5) : (connecting ? theme.a(theme.frost, 0.3) : theme.a(theme.iris, 0.12)))
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 10
                                            Sym { text: modelData.type==="wireguard" ? "cable" : "vpn_key"; sz: 17
                                                color: modelData.active ? theme.iris : (connecting ? theme.frost : (failed ? theme.bad : theme.faint)) }
                                            ColumnLayout { spacing: 2; Layout.fillWidth: true
                                                Text { text: modelData.name; color: modelData.active ? theme.text : (connecting ? theme.frost : (failed ? theme.bad : theme.sub))
                                                    font.pixelSize: 13; font.family: Tok.mono; font.bold: modelData.active || connecting; elide: Text.ElideRight }
                                                Text {
                                                    text: connecting ? "connecting…" : (failed ? "connection failed — please try again" : (modelData.active ? "connected" : modelData.type))
                                                    color: connecting ? theme.frost : (failed ? theme.bad : (modelData.active ? theme.good : theme.faint))
                                                    font.pixelSize: 10; font.family: Tok.mono } }
                                            Rectangle {
                                                implicitWidth: 104; implicitHeight: 30; radius: Tok.r
                                                color: connecting ? theme.a(theme.line, 0.5) : (vtm.containsMouse ? (modelData.active ? theme.a(theme.bad,0.3) : theme.iris) : (modelData.active ? theme.a(theme.bad,0.15) : theme.a(theme.iris,0.2)))
                                                border.width: 1; border.color: connecting ? theme.a(theme.line, 0.7) : (modelData.active ? theme.bad : theme.iris)
                                                Behavior on color { ColorAnimation { duration: 110 } }
                                                Text { anchors.centerIn: parent
                                                    text: connecting ? "connecting…" : (modelData.active ? "disconnect" : "connect")
                                                    color: connecting ? theme.faint : (vtm.containsMouse ? (modelData.active ? theme.bad : theme.bg) : (modelData.active ? theme.bad : theme.frost))
                                                    font.pixelSize: 11; font.family: Tok.mono; font.bold: true }
                                                MouseArea { id: vtm; anchors.fill: parent; hoverEnabled: true; cursorShape: connecting ? Qt.ArrowCursor : Qt.PointingHandCursor
                                                    onClicked: if (!connecting) root.vpnToggle(modelData.name) } }
                                            Rectangle {
                                                implicitWidth: 32; implicitHeight: 30; radius: Tok.r
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
                                radius: Tok.r; clip: true
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
                                            Text { text: "import VPN profile"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.fillWidth: true }
                                            Sym { text: root.vpnAddOpen ? "expand_less" : "expand_more"; sz: 17; color: theme.faint } } }

                                    // type chips
                                    RowLayout {
                                        visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                                        Repeater { model: [{l:"WireGuard (.conf)",v:0},{l:"OpenVPN (.ovpn)",v:1}]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool sel: root.vpnAddMode === modelData.v
                                                Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                                                color: sel ? theme.a(theme.iris,0.25) : (atm2.containsMouse ? theme.a(theme.line,0.5) : theme.a(theme.line,0.35))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.15)
                                                Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.text : theme.sub
                                                    font.pixelSize: 11; font.family: Tok.mono; font.bold: sel }
                                                MouseArea { id: atm2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.vpnAddMode = modelData.v } } }
                                    }

                                    // file path + import button
                                    RowLayout {
                                        visible: root.vpnAddOpen; Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                            color: theme.a(theme.bg, 0.8); border.width: 1
                                            border.color: vpnPathIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.25)
                                            TextInput {
                                                id: vpnPathIn
                                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 12; font.family: Tok.mono; clip: true
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: vpnPathIn.text === ""
                                                    text: root.vpnAddMode === 0 ? "~/path/to/tunnel.conf" : "~/path/to/config.ovpn"
                                                    color: theme.faint; font.pixelSize: 12; font.family: Tok.mono }
                                                Keys.onReturnPressed: {
                                                    if (root.vpnAddMode === 0) root.vpnAddWireguard(vpnPathIn.text);
                                                    else root.vpnAddOpenVPN(vpnPathIn.text);
                                                    vpnPathIn.text = ""; root.vpnAddOpen = false; } } }
                                        Rectangle {
                                            implicitWidth: 36; implicitHeight: 34; radius: Tok.r
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
                                            implicitWidth: 80; implicitHeight: 34; radius: Tok.r
                                            color: viam.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                            border.width: 1; border.color: theme.iris
                                            RowLayout { anchors.centerIn: parent; spacing: 5
                                                Sym { text: "upload_file"; sz: 14; color: viam.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "import"; color: viam.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true } }
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
                                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                                }
                            }

                            // status message
                            Text { visible: root.vpnMsg !== ""; text: root.vpnMsg
                                color: root.vpnMsg.indexOf("fail") >= 0 || root.vpnMsg.indexOf("fail") >= 0 ? theme.bad : theme.sub
                                font.pixelSize: 11; font.family: Tok.mono; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        }

                        // ================= WEATHER =================
                        ColumnLayout {
                            visible: root.tab === 3; Layout.fillWidth: true; spacing: 14
                            Section { title: "location"; icon: "location_on" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
                                    color: theme.a(theme.line, 0.4); border.width: 1
                                    border.color: locIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    TextInput {
                                        id: locIn
                                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 13; font.family: Tok.mono
                                        clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                        Component.onCompleted: text = root.wxLoc
                                        onAccepted: root.saveLoc(text)
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: locIn.text === ""; text: "city, e.g. Kuching"; color: theme.faint; font.pixelSize: 13; font.family: Tok.mono }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 96; implicitHeight: 38; radius: Tok.r
                                    color: svm.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                    border.width: 1; border.color: theme.iris
                                    RowLayout {
                                        anchors.centerIn: parent; spacing: 6
                                        Sym { text: "save"; sz: 16; color: svm.containsMouse ? theme.bg : theme.frost }
                                        Text { text: "Save"; color: svm.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: Tok.mono }
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
                                        Layout.fillWidth: true; implicitHeight: 40; radius: Tok.r
                                        color: sel ? theme.iris : (um.containsMouse ? theme.a(theme.iris,0.16) : theme.a(theme.line,0.4))
                                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris,0.16)
                                        Text { anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.text; font.pixelSize: 13; font.family: Tok.mono; font.bold: sel }
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
                                        { i: "contrast", l: "theme" },
                                        { i: "palette", l: "colors" },
                                        { i: "tune", l: "targets" },
                                        { i: "font_download", l: "fonts" },
                                        { i: "wallpaper", l: "wallpaper" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData; required property int index
                                        readonly property bool sel: root.apSubTab === index
                                        Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
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
                                // WHAT DECIDES IT.  This was a boolean — "auto dark by time", on or off —
                                // which had no room for a third answer, and two booleans that can both be on
                                // is how a schedule and a wallpaper end up overwriting each other once a
                                // minute. One source, chosen.
                                Text { text: "what decides light or dark"; color: theme.faint; font.pixelSize: 10
                                       font.family: Tok.mono; Layout.leftMargin: 14; Layout.topMargin: 6 }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                    Repeater {
                                        model: [{k:"manual",   l:"you",       i:"touch_app"},
                                                {k:"clock",    l:"the clock", i:"schedule"},
                                                {k:"wallpaper",l:"the wallpaper", i:"wallpaper"}]
                                        delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i
                                            on: root.apModeSource === modelData.k
                                            onPicked: {
                                                root.apModeSource = modelData.k;
                                                root.apAutoDark = (modelData.k === "clock");
                                                root.saveAppearance();
                                                if (modelData.k === "wallpaper") root.applyModeFromWallpaper();
                                            } } } }
                                Text {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    wrapMode: Text.WordWrap; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    text: root.apModeSource === "clock"
                                          ? "dark inside the window below · overrides the manual pick and the SUPER+⇧+D key"
                                          : root.apModeSource === "wallpaper"
                                          ? "each wallpaper's own brightness picks the mode. a picture that is neither clearly dark nor clearly light leaves it alone, so most switches change nothing — pressing SUPER+⇧+D hands control back to you"
                                          : "whatever you last set, by the chip above or SUPER+⇧+D. nothing changes it behind your back"
                                }
                                RowLayout { visible: root.apModeSource === "clock"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                    Sym { text: "schedule"; sz: 18; color: theme.sub }
                                    Text { text: "dark from"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: dstart.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dstart; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: Tok.mono; inputMask: "99:99;_"; text: root.apDarkStart
                                            onEditingFinished: { root.apDarkStart = text; root.saveAppearance() } } }
                                    Text { text: "to"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                                    Rectangle { implicitWidth: 68; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: dend.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                        TextInput { id: dend; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: Tok.mono; inputMask: "99:99;_"; text: root.apDarkEnd
                                            onEditingFinished: { root.apDarkEnd = text; root.saveAppearance() } } }
                                    Item { Layout.fillWidth: true } }

                                Section { title: "app preference"; icon: "apps" }
                                Text { text: "controls GTK / Qt app themes independently from the shell"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14 }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                    Repeater { model: [{k:"auto",l:"auto",i:"sync"},{k:"dark",l:"dark",i:"dark_mode"},{k:"light",l:"light",i:"light_mode"}]
                                        delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.apAppMode===modelData.k
                                            onPicked: { root.apAppMode=modelData.k; root.saveAppearance(); root.applyAppMode() } } } }
                                Text { visible: root.apAppMode!=="auto"; text: "apps will stay " + root.apAppMode + " regardless of shell theme"; color: theme.iris; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14 }

                            }

                            // SUB-TAB 1: Colors
                            ColumnLayout {
                                visible: root.apSubTab === 1; Layout.fillWidth: true; spacing: 12
                                Section { title: "accent colour"; icon: "palette" }
                                Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                    Repeater { model: root.accents
                                        delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                                            width: 40; height: 40; radius: Tok.r; color: modelData
                                            border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                            Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 20; color: "#0d1420" }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickAccent(modelData) } } } }
                                ToggleCard { icon: "colorize"; title: "auto colours from wallpaper"
                                    desc: "recolours the shell + kitty on every wallpaper · off = sea cyan"
                                    on: root.apMatugen; onToggled: root.toggleMatugen() }
                                ColumnLayout { Layout.fillWidth: true; spacing: 8; visible: root.apMatugen
                                    RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                        Sym { text: "tune"; sz: 15; color: theme.faint }
                                        Text { text: "colour scheme"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                                        Item { Layout.fillWidth: true }
                                        Text { text: root.apScheme.replace("scheme-",""); color: theme.frost; font.pixelSize: 11; font.family: Tok.mono } }
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
                                            width: 36; height: 36; radius: Tok.r; color: modelData
                                            border.width: sel?3:1; border.color: sel?theme.text:theme.a(theme.text,0.2)
                                            Sym { anchors.centerIn: parent; visible: parent.sel; text: "check"; sz: 18; color: "#0d1420" }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickPaletteAccent(modelData) } } } }
                            }

                            // SUB-TAB 2: Custom Targets Overrides
                            ColumnLayout {
                                visible: root.apSubTab === 2; Layout.fillWidth: true; spacing: 14
                                // ---------- per-target colour overrides ----------
                                ColumnLayout { Layout.fillWidth: true; spacing: 8
                                    Section { title: "colour targets"; icon: "tune" }
                                    Text { text: "customize which apps auto-match wallpaper/global accent · disabled auto-match targets can use custom colors"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont }
                                    // Hyprland borders
                                    Rectangle { Layout.fillWidth: true; implicitHeight: hyprCol.implicitHeight + 20; radius: Tok.r
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrHyprland?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: hyprCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "border_style"; sz: 18; color: root.ovrHyprland?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "hyprland borders"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "window active/inactive border colours"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                    color: root.ovrHyprland?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrHyprland?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrHyprland?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprland=!root.ovrHyprland; root.toggleOverride("hyprland") } } } }
                                            // custom border colours (only visible when auto-match is OFF)
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrHyprland
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "active"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprActive || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: haIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: haIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrHyprActive
                                                            onEditingFinished: { root.ovrHyprActive=text.trim(); root.toggleOverride("hyprland") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !haIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: haEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: haEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprActive"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprActive = modelData; root.toggleOverride("hyprland") } } } } }
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "inactive"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprInactive || theme.a(root.apAccent,0.4); border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: hiIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: hiIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrHyprInactive
                                                            onEditingFinished: { root.ovrHyprInactive=text.trim(); root.toggleOverride("hyprland") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !hiIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: hiEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: hiEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprInactive"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprInactive = modelData; root.toggleOverride("hyprland") } } } } } } } }
                                    // Hyprland window glow (decoration:shadow) — a separate target
                                    // from the borders on purpose: a matched border with a fixed
                                    // glow is a real preference, and they used to be welded together
                                    // only because the glow simply never followed the wallpaper.
                                    Rectangle { Layout.fillWidth: true; implicitHeight: glowCol.implicitHeight + 20; radius: Tok.r
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrHyprGlow?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: glowCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "blur_on"; sz: 18; color: root.ovrHyprGlow?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "hyprland window glow"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "the coloured shadow around the focused window"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                    color: root.ovrHyprGlow?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrHyprGlow?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrHyprGlow?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprGlow=!root.ovrHyprGlow; root.toggleOverride("hyprGlow") } } } }
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrHyprGlow
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "glow"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprGlowColor || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: hgIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: hgIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrHyprGlowColor
                                                            onEditingFinished: { root.ovrHyprGlowColor=text.trim(); root.toggleOverride("hyprGlow") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !hgIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprGlowColor = modelData; root.toggleOverride("hyprGlow") } } } } } } } }
                                    // Kitty terminal
                                    Rectangle { Layout.fillWidth: true; implicitHeight: kittyCol.implicitHeight + 20; radius: Tok.r
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrKitty?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: kittyCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "terminal"; sz: 18; color: root.ovrKitty?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "kitty terminal"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "terminal colour palette and background"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                    color: root.ovrKitty?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrKitty?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrKitty?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKitty=!root.ovrKitty; root.toggleOverride("kitty") } } } }
                                            // custom kitty colors
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrKitty
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrKittyAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: kaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: kaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrKittyAccent
                                                            onEditingFinished: { root.ovrKittyAccent=text.trim(); root.toggleOverride("kitty") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !kaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: kaEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: kaEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyAccent"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyAccent = modelData; root.toggleOverride("kitty") } } } } }
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "bg"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrKittyBg || "#171729"; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: kbIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: kbIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrKittyBg
                                                            onEditingFinished: { root.ovrKittyBg=text.trim(); root.toggleOverride("kitty") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !kbIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: kbEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: kbEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyBg"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: ["#0f141d","#171729","#1a1b26","#1e1e2e","#282828","#000000"].concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyBg = modelData; root.toggleOverride("kitty") } } } } } } } }
                                    // Fastfetch
                                    Rectangle { Layout.fillWidth: true; implicitHeight: ffCol.implicitHeight + 20; radius: Tok.r
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrFastfetch?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: ffCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "info"; sz: 18; color: root.ovrFastfetch?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "fastfetch"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "system info key + logo accent colour"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                    color: root.ovrFastfetch?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrFastfetch?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrFastfetch?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetch=!root.ovrFastfetch; root.toggleOverride("fastfetch") } } } }
                                            // custom fastfetch accent
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrFastfetch
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrFastfetchAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: ffaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: ffaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrFastfetchAccent
                                                            onEditingFinished: { root.ovrFastfetchAccent=text.trim(); root.toggleOverride("fastfetch") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !ffaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: ffEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: ffEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "fastfetch"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetchAccent = modelData; root.toggleOverride("fastfetch") } } } } } } } }
                                    // Starship prompt
                                    Rectangle { Layout.fillWidth: true; implicitHeight: ssCol.implicitHeight + 20; radius: Tok.r
                                        color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrStarship?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                                        ColumnLayout { id: ssCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                                            RowLayout { Layout.fillWidth: true; spacing: 10
                                                Sym { text: "star"; sz: 18; color: root.ovrStarship?theme.frost:theme.faint }
                                                ColumnLayout { spacing: 1; Layout.fillWidth: true
                                                    Text { text: "starship prompt"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                                                    Text { text: "terminal prompt accent colours"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont } }
                                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                    color: root.ovrStarship?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrStarship?theme.iris:theme.a(theme.iris,0.3)
                                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrStarship?27:3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrStarship=!root.ovrStarship; root.toggleOverride("starship") } } } }
                                            // custom starship accent
                                            ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrStarship
                                                RowLayout { Layout.fillWidth: true; spacing: 8
                                                    Text { text: "accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                                                    Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrStarshipAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                                                    Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: ssaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                                        TextInput { id: ssaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono; clip: true; selectByMouse: true; text: root.ovrStarshipAccent
                                                            onEditingFinished: { root.ovrStarshipAccent=text.trim(); root.toggleOverride("starship") }
                                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !ssaIn.text; text: "auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                                    Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                                        color: ssEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                                        Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                                        MouseArea { id: ssEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "starship"; colorPickerProc.running = true } } } }
                                                Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                                                    Repeater { model: root.accents.concat(root.matugenPalette)
                                                        delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
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
                                            implicitWidth: ft.implicitWidth+22; implicitHeight: 32; radius: Tok.r
                                            color: sel?theme.iris:(fmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                                            Text { id: ft; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: modelData; font.bold: sel }
                                            MouseArea { id: fmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apFont=modelData; root.saveAppearance() } } } } }
                                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; implicitHeight: 38; radius: Tok.r
                                    color: theme.a(theme.line,0.4); border.width: 1; border.color: fontIn.activeFocus?theme.iris:theme.a(theme.iris,0.16)
                                    TextInput { id: fontIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 13; font.family: root.apFont; clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris,0.4)
                                        Component.onCompleted: text = root.apFont
                                        onAccepted: root.addCustomFont(text)
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: fontIn.text===""; text: "type a font name, ↵ to save it as a chip"; color: theme.faint; font.pixelSize: 13; font.family: root.apFont } } }
                                Text { text: "changes apply to the bar live"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.leftMargin: 14 }
                            }

                            // SUB-TAB 4: Wallpaper — folder · transition · rotation · pair · motion
                            ColumnLayout {
                                id: wpTab
                                visible: root.apSubTab === 4; Layout.fillWidth: true; spacing: 12
                                // "" | day | night — which cartridge slot the shelf is filling.
                                property string armed: ""
                                // Both: onVisibleChanged covers arriving at the tab, and
                                // Component.onCompleted covers the panel opening with this
                                // tab already selected — where visibility never changes and
                                // the shelf would sit empty saying "0 wallpapers".
                                onVisibleChanged: if (visible && !root.wpIndex.length) root.rescanWallpapers()
                                Component.onCompleted: if (visible && !root.wpIndex.length) root.rescanWallpapers()
                                // …and whenever the PANEL opens. The two above only fire when
                                // this tab's visibility changes, so a panel left sitting on
                                // this tab with an empty index — which is what an earlier
                                // failed scan leaves behind — had no way to try again short of
                                // the re-scan button.
                                Connections {
                                    target: root
                                    function onShownChanged() {
                                        if (root.shown && wpTab.visible && !root.wpIndex.length)
                                            root.rescanWallpapers();
                                    }
                                }

                                Section { title: "wallpaper folder"; icon: "folder_open" }
                                Text {
                                    text: "the picker, the SUPER+N keybinds and auto-rotate all read this one folder"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    Layout.leftMargin: 14
                                }
                                Rectangle {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    implicitHeight: 38; radius: Tok.r
                                    color: theme.a(theme.line, 0.4)
                                    border.width: 1
                                    border.color: wpDirIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10
                                        spacing: 8
                                        Sym { text: "folder"; sz: 17; color: theme.sub }
                                        TextInput {
                                            id: wpDirIn
                                            Layout.fillWidth: true
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 13; font.family: Tok.mono
                                            clip: true; selectByMouse: true
                                            selectionColor: theme.a(theme.iris, 0.4)
                                            Component.onCompleted: text = root.apWpDir
                                            // Committed on ↵, not on every keystroke: saving per character
                                            // would re-scan the folder once per letter of the path you are
                                            // still halfway through typing.
                                            onAccepted: {
                                                root.apWpDir = text.trim().length ? text.trim() : "~/Pictures/wallpapers";
                                                wpDirIn.text = root.apWpDir;
                                                root.saveAppearance();
                                                root.rescanWallpapers();
                                            }
                                        }
                                        Text {
                                            visible: wpDirIn.text.trim() !== root.apWpDir
                                            text: "↵ to save"; color: theme.iris
                                            font.pixelSize: 10; font.family: Tok.mono
                                        }
                                        Rectangle {
                                            implicitWidth: 28; implicitHeight: 26; radius: Tok.rSmall
                                            color: wpBrowseMa.containsMouse ? theme.a(theme.iris, 0.22) : "transparent"
                                            border.width: 1; border.color: theme.a(theme.iris, 0.25)
                                            Sym { anchors.centerIn: parent; text: "folder_open"; sz: 15
                                                  color: wpBrowseMa.containsMouse ? theme.iris : theme.sub }
                                            MouseArea {
                                                id: wpBrowseMa
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.pickFolder("wallpaper folder",
                                                                           root.expandHome(root.apWpDir),
                                                                           function (dir) {
                                                    root.apWpDir = root.shortenHome(dir);
                                                    wpDirIn.text = root.apWpDir;
                                                    root.saveAppearance();
                                                    root.rescanWallpapers();
                                                })
                                            }
                                        }
                                    }
                                }
                                ToggleCard {
                                    icon: "account_tree"
                                    title: "include subfolders"
                                    desc: "each subfolder becomes a collection you can filter the picker by"
                                    on: root.apWpRecursive
                                    onToggled: { root.apWpRecursive = !root.apWpRecursive
                                                 root.saveAppearance(); root.rescanWallpapers() }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 10
                                    Text {
                                        Layout.fillWidth: true
                                        color: theme.sub; font.pixelSize: 11; font.family: Tok.mono
                                        text: root.wpIndexBusy ? "scanning…"
                                              : !root.wpScanned ? "not scanned yet — press re-scan"
                                              : root.wpIndex.length + " wallpaper" + (root.wpIndex.length === 1 ? "" : "s")
                                                + (root.wpCollCount ? "  ·  " + root.wpCollCount + " collection"
                                                                       + (root.wpCollCount === 1 ? "" : "s") : "")
                                    }
                                    Chip {
                                        label: root.wpIndexBusy ? "scanning" : "re-scan"
                                        icon: "refresh"
                                        onPicked: root.rescanWallpapers()
                                    }
                                }

                                Section { title: "switch transition"; icon: "animation" }
                                Text {
                                    text: "used by the picker, SUPER+N / SUPER+SHIFT+N, and auto-rotate"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    Layout.leftMargin: 14
                                }
                                Flow {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
                                    Repeater {
                                        model: root.wpTransitions
                                        delegate: Chip {
                                            required property var modelData
                                            label: modelData
                                            on: root.apWpTransition === modelData
                                            onPicked: { root.apWpTransition = modelData; root.saveAppearance() }
                                        }
                                    }
                                }
                                SliderRow {
                                    icon: "speed"; label: "duration"
                                    value: Math.min(1, root.apWpTransitionDur / 5)
                                    readout: root.apWpTransitionDur.toFixed(1) + "s"
                                    onMoved: (v) => { root.apWpTransitionDur = Math.max(0.1, v * 5); root.saveAppearance() }
                                }
                                SliderRow {
                                    icon: "60fps"; label: "fps"
                                    value: Math.min(1, (root.apWpTransitionFps - 15) / 105)
                                    readout: Math.round(root.apWpTransitionFps) + ""
                                    onMoved: (v) => { root.apWpTransitionFps = Math.round(15 + v * 105); root.saveAppearance() }
                                }
                                Row2 {
                                    icon: "skip_next"; label: "preview it — switch to the next wallpaper"
                                    cmd: "sh '" + root.wpCycleScript + "' next"
                                }

                                Section { title: "auto-rotate"; icon: "schedule" }
                                ToggleCard {
                                    icon: "autorenew"
                                    title: "rotate wallpaper automatically"
                                    desc: root.apWpDayNight
                                          ? "held — the day/night pair below outranks the timer"
                                          : (root.apMatugen
                                             ? "on — heads up: “match colours” is enabled, so every rotation re-themes the shell"
                                             : "cycles the wallpaper folder on a timer")
                                    on: root.apWpRotate && !root.apWpDayNight
                                    onToggled: {
                                        root.apWpRotate = !root.apWpRotate;
                                        root.saveAppearance();
                                        // the daemon re-reads config each tick, but restart so a
                                        // changed interval takes effect now instead of after the
                                        // current sleep — and so enabling it works even if the
                                        // daemon was never started this session.
                                        run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
                                    }
                                }
                                SliderRow {
                                    icon: "timer"; label: "every"
                                    value: Math.min(1, (root.apWpRotateMins - 1) / 239)
                                    readout: root.apWpRotateMins >= 60
                                             ? (root.apWpRotateMins / 60).toFixed(1) + "h"
                                             : Math.round(root.apWpRotateMins) + "m"
                                    onMoved: (v) => { root.apWpRotateMins = Math.max(1, Math.round(1 + v * 239)); root.saveAppearance() }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    Text { text: "order"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                    Repeater {
                                        model: root.wpRotateModes
                                        delegate: Chip {
                                            required property var modelData
                                            label: modelData
                                            on: root.apWpRotateMode === modelData
                                            onPicked: {
                                                root.apWpRotateMode = modelData; root.saveAppearance();
                                                run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
                                            }
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                                ToggleCard {
                                    icon: "image"
                                    title: "stills only"
                                    desc: "skip moving wallpapers — rotating into one restarts a video decoder every interval"
                                    on: root.apWpRotateStills
                                    onToggled: { root.apWpRotateStills = !root.apWpRotateStills; root.saveAppearance() }
                                }

                                // ---------------- the pair ----------------
                                Section { title: "day & night"; icon: "routine" }
                                ToggleCard {
                                    icon: "bedtime"
                                    title: "pin a day and a night wallpaper"
                                    desc: "swaps at " + root.apDarkStart + " and " + root.apDarkEnd
                                          + " — the same times as auto dark mode, in Theme"
                                    on: root.apWpDayNight
                                    onToggled: {
                                        root.apWpDayNight = !root.apWpDayNight;
                                        root.saveAppearance();
                                        run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 12
                                    opacity: root.apWpDayNight ? 1 : 0.4
                                    Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                                    CartTile {
                                        slot: "day"; path: root.apWpDay
                                        armed: wpTab.armed === "day"
                                        onPicked: wpTab.armed = (wpTab.armed === "day") ? "" : "day"
                                        onCleared: { root.apWpDay = ""; root.saveAppearance() }
                                    }
                                    CartTile {
                                        slot: "night"; path: root.apWpNight
                                        armed: wpTab.armed === "night"
                                        onPicked: wpTab.armed = (wpTab.armed === "night") ? "" : "night"
                                        onCleared: { root.apWpNight = ""; root.saveAppearance() }
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                WallShelf {
                                    open: wpTab.armed === "day" || wpTab.armed === "night"
                                    chosen: wpTab.armed === "day" ? root.apWpDay
                                          : wpTab.armed === "night" ? root.apWpNight : ""
                                    onPicked: (path) => {
                                        if (wpTab.armed === "day")        root.apWpDay = path;
                                        else if (wpTab.armed === "night") root.apWpNight = path;
                                        root.saveAppearance();
                                        wpTab.armed = "";
                                        run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
                                    }
                                }

                                // ---------------- the lock screen ----------------
                                Section { title: "lock screen"; icon: "lock" }
                                ToggleCard {
                                    icon: "photo_library"
                                    title: "lock screen keeps its own picture"
                                    desc: "off — hyprlock follows the desktop, re-synced on every switch"
                                    on: root.apWpLockOwn
                                    onToggled: {
                                        root.apWpLockOwn = !root.apWpLockOwn;
                                        root.saveAppearance();
                                        // Re-run the sync so the change is on the lock screen now
                                        // rather than at the next wallpaper switch — which, if you
                                        // never switch, is never.
                                        run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 12
                                    opacity: root.apWpLockOwn ? 1 : 0.4
                                    Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                                    CartTile {
                                        slot: "lock"; path: root.apWpLock
                                        armed: wpTab.armed === "lock"
                                        onPicked: wpTab.armed = (wpTab.armed === "lock") ? "" : "lock"
                                        onCleared: {
                                            root.apWpLock = ""; root.saveAppearance();
                                            run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                                WallShelf {
                                    open: wpTab.armed === "lock"
                                    chosen: root.apWpLock
                                    onPicked: (path) => {
                                        root.apWpLock = path;
                                        root.saveAppearance();
                                        wpTab.armed = "";
                                        run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
                                    }
                                }

                                // ---------------- moving wallpapers ----------------
                                Section { title: "moving wallpapers"; icon: "movie" }
                                Text {
                                    text: "mp4 · webm · gif play through mpvpaper, which holds a decoder for as long as it runs"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    Layout.leftMargin: 14; Layout.rightMargin: 14
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                }
                                ToggleCard {
                                    icon: "memory"
                                    title: "free it while it's covered"
                                    desc: "a fullscreen window swaps the video for its own still frame — pausing keeps the VRAM, this hands it back"
                                    on: root.apWpCoverStill
                                    onToggled: { root.apWpCoverStill = !root.apWpCoverStill; root.saveAppearance() }
                                }
                                ToggleCard {
                                    icon: "battery_saver"
                                    title: "still frame on battery"
                                    desc: "hold the poster frame until it's plugged back in"
                                    on: root.apWpBatteryStill
                                    onToggled: { root.apWpBatteryStill = !root.apWpBatteryStill; root.saveAppearance() }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    Text { text: "frame cap"; color: theme.sub; font.pixelSize: 12
                                           font.family: Tok.mono; Layout.minimumWidth: 76 }
                                    Repeater {
                                        model: root.wpVidFpsOptions
                                        delegate: Chip {
                                            required property var modelData
                                            label: modelData === 0 ? "as filmed" : modelData + " fps"
                                            on: root.apWpVidFps === modelData
                                            onPicked: {
                                                root.apWpVidFps = modelData; root.saveAppearance();
                                                // mpvpaper reads its options once, at start
                                                run("sh '" + root.wpApplyScript + "' >/dev/null 2>&1 &");
                                            }
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                                Text {
                                    text: "capping halves the full-screen blits the compositor does for a clip · it does not reduce decoding"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    Layout.leftMargin: 14; Layout.rightMargin: 14
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // ================= DESKTOP =================
                        // The space between the bar and the dock. Everything here is a
                        // request to sea-desktop.py; see the note by dtScript above.
                        ColumnLayout {
                            visible: root.tab === 21; Layout.fillWidth: true; spacing: 12

                            Section { title: "arranging"; icon: "drag_pan" }
                            Text {
                                text: "while arranging, drag anything on the desktop. shaded areas are where the shell thinks your wallpaper has something in it — a widget dropped there moves aside unless you hold shift, which also pins it. follow-wallpaper: RESCUE moves only what a new wallpaper actually covers, and only as far as it must — often nothing, which is correct. ARRANGE re-places everything in the calmest space of every new picture. pinned widgets never move."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                wrapMode: Text.WordWrap
                                Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                Chip {
                                    label: root.dtEditing ? "arranging" : "arrange"
                                    icon: "drag_pan"
                                    on: root.dtEditing
                                    onPicked: {
                                        root.dtEditing = !root.dtEditing;
                                        root.dtIpc(root.dtEditing ? "start" : "done");
                                    }
                                }
                                Chip {
                                    label: "follow wallpaper: " + root.dtAuto
                                    icon: "auto_awesome_motion"
                                    on: root.dtAuto !== "off"
                                    onPicked: {
                                        var o = ["rescue", "arrange", "off"];
                                        var i = o.indexOf(root.dtAuto);
                                        root.dtRun(["--auto", o[(i + 1) % o.length]]);
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }

                            Section { title: "on the desktop"; icon: "widgets" }
                            Text {
                                visible: root.dtItems.length === 0
                                text: "nothing yet"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                Layout.leftMargin: 14
                            }
                            Repeater {
                                model: root.dtItems
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 10
                                    Text {
                                        text: ({ "clock": "schedule", "weather": "cloud",
                                                 "media": "music_note", "system": "monitor_heart",
                                                 "launch": "apps" })[modelData.kind] || "widgets"
                                        font.family: "Material Symbols Rounded"; font.pixelSize: 16
                                        color: theme.sub
                                    }
                                    Text {
                                        text: modelData.kind === "launch"
                                              ? (modelData.label || "shortcut") : modelData.kind
                                        color: theme.text; font.pixelSize: 12; font.family: root.apFont
                                    }
                                    Text {
                                        text: modelData.id || ""
                                        color: theme.faint; font.pixelSize: 9; font.family: Tok.mono
                                    }
                                    Item { Layout.fillWidth: true }
                                    // Cycling chips rather than a row of radio groups per
                                    // widget: five widgets times four axes is twenty
                                    // controls, and a settings page you have to scroll past
                                    // is how a customisable thing stops being customised.
                                    Chip {
                                        visible: modelData.kind !== "launch"
                                        label: modelData.ground || "rule"
                                        icon: "layers"
                                        onPicked: {
                                            var o = ["rule", "panel", "bare"];
                                            var i = o.indexOf(modelData.ground || "rule");
                                            root.dtRun(["--set", "" + modelData.id,
                                                        "--ground", o[(i + 1) % o.length]]);
                                        }
                                    }
                                    Chip {
                                        visible: modelData.kind !== "launch"
                                        label: modelData.tone || "accent"
                                        icon: "palette"
                                        onPicked: {
                                            var o = ["accent", "frost", "green", "amber", "red", "plain"];
                                            var i = o.indexOf(modelData.tone || "accent");
                                            root.dtRun(["--set", "" + modelData.id,
                                                        "--tone", o[(i + 1) % o.length]]);
                                        }
                                    }
                                    Chip {
                                        visible: modelData.kind !== "launch"
                                        label: modelData.align || "left"
                                        icon: "format_align_left"
                                        onPicked: {
                                            var o = ["left", "centre", "right"];
                                            var i = o.indexOf(modelData.align || "left");
                                            root.dtRun(["--set", "" + modelData.id,
                                                        "--align", o[(i + 1) % o.length]]);
                                        }
                                    }
                                    Chip {
                                        label: modelData.size || "medium"
                                        icon: "photo_size_select_small"
                                        onPicked: {
                                            var o = ["small", "medium", "large"];
                                            var i = o.indexOf(modelData.size || "medium");
                                            root.dtRun(["--set", "" + modelData.id,
                                                        "--size", o[(i + 1) % o.length]]);
                                        }
                                    }
                                    Chip {
                                        label: modelData.pinned ? "pinned" : "free"
                                        icon: modelData.pinned ? "push_pin" : "open_in_full"
                                        on: !!modelData.pinned
                                        onPicked: root.dtRun([modelData.pinned ? "--unpin" : "--pin",
                                                              "" + modelData.id])
                                    }
                                    Chip {
                                        label: "remove"; icon: "close"
                                        onPicked: root.dtRun(["--remove", "" + modelData.id])
                                    }
                                }
                            }

                            Section { title: "add"; icon: "add_circle" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                Repeater {
                                    model: [{ k: "clock",   l: "clock",   i: "schedule" },
                                            { k: "weather", l: "weather", i: "cloud" },
                                            { k: "media",   l: "playing", i: "music_note" },
                                            { k: "system",  l: "system",  i: "monitor_heart" }]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l; icon: modelData.i
                                        onPicked: root.dtRun(["--add-" + modelData.k])
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                height: 30; radius: Tok.r
                                color: theme.a(theme.line, 0.45)
                                border.width: 1; border.color: theme.a(theme.line, 0.9)
                                TextInput {
                                    id: dtIn
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 12; font.family: root.apFont
                                    selectByMouse: true
                                    onTextChanged: root.dtQuery = text
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 10
                                    visible: dtIn.text.length === 0
                                    text: "search installed applications"
                                    color: theme.faint; font.pixelSize: 11; font.family: Tok.mono
                                }
                            }
                            Repeater {
                                model: root.dtApps
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 10
                                    IconImage {
                                        implicitSize: 18
                                        source: Quickshell.iconPath(modelData.icon, true)
                                    }
                                    Text {
                                        text: modelData.name || ""
                                        color: theme.text; font.pixelSize: 12; font.family: root.apFont
                                    }
                                    Item { Layout.fillWidth: true }
                                    Chip {
                                        label: "add"; icon: "add"
                                        onPicked: root.dtRun(["--add-entry", "" + modelData.id,
                                                              "--label", "" + modelData.name,
                                                              "--icon", "" + (modelData.icon || modelData.id)])
                                    }
                                }
                            }
                        }

                        // ================= BAR =================
                        // Its own tab, because it was sharing "Appearance → bar theme" with the
                        // shell-wide dark/light switch and the GTK/Qt app preference — neither of
                        // which is about the bar. What is here IS the bar: its shape, how it draws
                        // workspaces, and the mark at its left end.
                        ColumnLayout {
                            visible: root.tab === 20; Layout.fillWidth: true; spacing: 12

                            Section { title: "shape"; icon: "view_agenda" }
                            Text {
                                text: "one strip, or the three clusters as separate floating pills"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                Layout.leftMargin: 14
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                Repeater {
                                    model: [{ k: "bar", l: "one bar", i: "rectangle" },
                                            { k: "pills", l: "pills", i: "view_week" }]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l; icon: modelData.i
                                        on: root.apBarShape === modelData.k
                                        onPicked: { root.apBarShape = modelData.k; root.saveAppearance() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }

                            Section { title: "workspaces"; icon: "grid_view" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                Repeater {
                                    model: [{ k: "grow",   l: "grow",    i: "unfold_more" },
                                            { k: "pill",   l: "pills",   i: "more_horiz" },
                                            { k: "circle", l: "circles", i: "circle" }]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l; icon: modelData.i
                                        on: root.apWsStyle === modelData.k
                                        onPicked: { root.apWsStyle = modelData.k; root.saveAppearance() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                text: root.apWsStyle === "grow"
                                      ? "a chip each · the one you are on stretches along the bar"
                                      : root.apWsStyle === "circle"
                                      ? "true circles that stretch into a pill on the one you are on \u00b7 round at any roundness setting, unlike grow"
                                      : "every workspace the same chip · the one you are on is filled, and nothing moves"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                Layout.leftMargin: 14; Layout.rightMargin: 14
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }

                            Section { title: "numbering"; icon: "format_list_numbered" }
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater {
                                    model: root.wsLabelChoices
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l
                                        labelFont: modelData.k === "dice" ? root.symbolFamily : Tok.mono
                                        visible: modelData.k !== "dice" || root.symbolFamily !== ""
                                        on: root.apWsLabel === modelData.k
                                        onPicked: { root.apWsLabel = modelData.k; root.saveAppearance() }
                                    }
                                }
                            }
                            Text {
                                text: "each scheme falls back to the plain number once it runs out of symbols — "
                                      + "\u2685 is the last die and \u2473 the last circled numeral"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                Layout.leftMargin: 14; Layout.rightMargin: 14
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }

                            Section { title: "the mark"; icon: "stars" }
                            Text {
                                text: "auto reads /etc/os-release · cachyos and sea-shell are drawn and recolour with the "
                                      + "theme, the rest are Nerd Font glyphs"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                Layout.leftMargin: 14; Layout.rightMargin: 14
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
                                Repeater {
                                    model: root.barLogoChoices
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool sel: root.apBarLogo === modelData.k
                                        implicitWidth: lgRow.implicitWidth + 20; implicitHeight: 36; radius: Tok.r
                                        color: sel ? theme.iris : (lgMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.16)
                                        Behavior on color { ColorAnimation { duration: 100 } }
                                        Row {
                                            id: lgRow; anchors.centerIn: parent; spacing: 7
                                            // The choice IS the picture. A list of distro names with
                                            // no logos beside them is the same mistake the theme
                                            // presets used to make with `accent: #dbc0c8`.
                                            BarLogo {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: modelData.k !== "auto" && modelData.k !== "custom"
                                                kind: modelData.k; size: 18
                                                card: sel ? Tok.accentInk : theme.panel
                                                accent: sel ? Tok.accentInk : theme.iris
                                                highlight: sel ? Tok.accentInk : theme.frost
                                                rim: sel ? Tok.accentInk : theme.iris
                                            }
                                            Sym {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: modelData.k === "auto" || modelData.k === "custom"
                                                text: modelData.k === "auto" ? "auto_awesome" : "image"
                                                sz: 16; color: sel ? Tok.accentInk : theme.frost
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.l
                                                color: sel ? Tok.accentInk : Tok.ink
                                                font.pixelSize: 11; font.family: Tok.mono; font.bold: sel
                                            }
                                        }
                                        MouseArea {
                                            id: lgMa; anchors.fill: parent; hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.apBarLogo = modelData.k;
                                                root.saveAppearance();
                                                if (modelData.k === "custom" && !root.apBarLogoPath.length)
                                                    root.pickFile("bar logo image", "*.png", function (f) {
                                                        root.apBarLogoPath = f; root.saveAppearance();
                                                    });
                                            }
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                visible: root.apBarLogo === "custom"
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                    color: theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    Text {
                                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                        verticalAlignment: Text.AlignVCenter
                                        text: root.apBarLogoPath.length ? root.apBarLogoPath : "no image chosen"
                                        color: root.apBarLogoPath.length ? theme.text : theme.faint
                                        font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideLeft
                                    }
                                }
                                Chip {
                                    label: "choose…"; icon: "folder_open"
                                    onPicked: root.pickFile("bar logo image", "*.png", function (f) {
                                        root.apBarLogoPath = f; root.saveAppearance();
                                    })
                                }
                            }

                                Section { title: "bar shape"; icon: "tune" }
                                SliderRow { icon: "rounded_corner"; label: "roundness"; value: root.apRadius/26; readout: Math.round(root.apRadius)+"px"
                                    onMoved: (v)=>{ root.apRadius = v*26; root.saveAppearance() } }
                                RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                    Sym { text: "dock_to_right"; sz: 18; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                    Text { text: "position"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: root.edges
                                            delegate: Chip { required property var modelData; label: modelData; on: root.apEdge===modelData
                                                onPicked: { root.apEdge=modelData; root.saveAppearance() } } } } }
                                SliderRow { icon: "opacity"; label: "opacity"; tint: theme.frost; value: root.apOpacity; readout: Math.round(root.apOpacity*100)+"%"
                                    onMoved: (v)=>{ root.apOpacity = v; root.saveAppearance() } }
                                Text { visible: root.apOpacity < 0.06; text: "↑ 0% hides the bar background — only the buttons show"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14 }
                                RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
                                    Sym { text: "format_color_fill"; sz: 18; color: theme.sub; Layout.alignment: Qt.AlignVCenter }
                                    Text { text: "bar fill"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: [{k:"matugen",l:"matugen"},{k:"black",l:"black"},{k:"white",l:"white"}]
                                            delegate: Chip { required property var modelData; label: modelData.l; on: root.apBarFill===modelData.k
                                                onPicked: { root.apBarFill=modelData.k; root.saveAppearance() } } } } }
                                Text { visible: root.apBarFill!=="matugen" && root.apOpacity<0.99; text: "↑ set opacity to 100% for a solid " + root.apBarFill + " bar"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14 }
                                SliderRow { icon: "height"; label: "bar height"; tint: theme.good; value: (root.apHeight-34)/20; readout: Math.round(root.apHeight)+"px"
                                    onMoved: (v)=>{ root.apHeight = 34 + v*20; root.saveAppearance() } }
                                ToggleCard { icon: "swipe_up"; title: "auto-hide bar"; desc: "tucks the bar away · push the cursor to the edge to reveal it"
                                    on: root.apAutoHide; onToggled: { root.apAutoHide=!root.apAutoHide; root.saveAppearance() } }
                                ToggleCard { visible: !root.apAutoHide; icon: "fullscreen"; title: "hide when fullscreen"; desc: "only auto-hides while a window is fullscreen (e.g. video, games)"
                                    on: root.apHideFullscreen; onToggled: { root.apHideFullscreen=!root.apHideFullscreen; root.saveAppearance() } }
                        }

                        // ================= BAR WIDGETS =================
                        ColumnLayout {
                            visible: root.tab === 12; Layout.fillWidth: true; spacing: 14
                            Section { title: "bar widgets"; icon: "widgets" }
                            Text {
                                text: "toggle widgets on/off, drag the ⠿ handle to reorder where they sit on the bar, and open ⚙ on any row to set how that pill looks. Media Player always stays centred."
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
                                    readonly property bool styleOpen: root.wgOpenId === wrap.wid
                                    width: wgList.width; height: 52 + (wrap.styleOpen ? 116 : 0)
                                    Behavior on height { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
                                    z: held ? 2 : 1

                                    Rectangle {
                                        id: card
                                        width: wrap.width; height: wrap.height; radius: Tok.r
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
                                            id: hdr
                                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                            height: 52
                                            anchors.leftMargin: 8; anchors.rightMargin: 14; spacing: 10
                                            // drag handle — grabbing this reorders the row
                                            MouseArea {
                                                id: handle
                                                Layout.preferredWidth: 24; Layout.fillHeight: true
                                                cursorShape: Qt.SizeVerCursor
                                                drag.target: card; drag.axis: Drag.YAxis
                                                onPressed: { root.wgOpenId = ""; root.wgDragging = true; wrap.held = true }
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
                                            // Opens the appearance controls for THIS widget. A dot marks one that
                                            // has been styled, so a bar that no longer looks like the defaults can
                                            // be traced to the rows responsible without opening all twenty.
                                            MouseArea {
                                                Layout.preferredWidth: 26; Layout.fillHeight: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.wgOpenId = wrap.styleOpen ? "" : wrap.wid
                                                Sym { anchors.centerIn: parent; text: "tune"; sz: 17
                                                      color: wrap.styleOpen ? theme.iris : theme.faint }
                                                Rectangle {
                                                    visible: root.wgStyleTouched(wrap.wid) && !wrap.styleOpen
                                                    width: 5; height: 5; radius: 2.5; color: theme.iris
                                                    anchors.right: parent.right; anchors.top: parent.top; anchors.topMargin: 13
                                                }
                                            }
                                            // toggle (hidden for no-toggle widgets like the recorder)
                                            Rectangle {
                                                visible: wrap.hasToggle
                                                Layout.alignment: Qt.AlignVCenter
                                                implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                                color: wrap.enabledVal ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: wrap.enabledVal ? theme.iris : theme.a(theme.iris, 0.3)
                                                Rectangle {
                                                    width: 16; height: 16; radius: Tok.r; y: 3; x: wrap.enabledVal ? 27 : 3
                                                    color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (wrap.hasToggle) { root[wrap.meta.prop] = !wrap.enabledVal; root.saveAppearance() } }
                                                }
                                            }
                                        }

                                        // ---- per-widget appearance ----
                                        // Colour, what the pill draws, and what it draws it on. Chosen per
                                        // widget because the reasons differ per widget: the clock wants to be
                                        // read, the recorder wants to be noticed, and a pill you only keep for
                                        // its dropdown wants to take as little of the bar as it can.
                                        ColumnLayout {
                                            id: styleBox
                                            visible: wrap.styleOpen
                                            anchors.top: hdr.bottom
                                            anchors.left: parent.left; anchors.right: parent.right
                                            anchors.leftMargin: 44; anchors.rightMargin: 14; anchors.topMargin: 1
                                            spacing: 6

                                            Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.14) }

                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 8
                                                Text { text: "COLOUR"; color: theme.faint; font.pixelSize: 10
                                                       font.family: Tok.mono; font.letterSpacing: 0.7
                                                       Layout.preferredWidth: 52 }
                                                Repeater {
                                                    model: root.wgAccentChoices
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        readonly property bool sel: root.wgStyleGet(wrap.wid, "a") === modelData.k
                                                        implicitWidth: 22; implicitHeight: 22; radius: 11
                                                        color: modelData.k === "" ? "transparent" : root.wgTone(modelData.k)
                                                        border.width: sel ? 2 : 1
                                                        border.color: sel ? theme.text : theme.a(theme.iris, 0.35)
                                                        // "default" has no colour of its own to show — it means the
                                                        // widget keeps whatever it already decides for itself.
                                                        Sym { visible: modelData.k === ""; anchors.centerIn: parent
                                                              text: "block"; sz: 12; color: theme.faint }
                                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: root.wgStyleSet(wrap.wid, "a", modelData.k) }
                                                    }
                                                }
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 8
                                                Text { text: "SHOWS"; color: theme.faint; font.pixelSize: 10
                                                       font.family: Tok.mono; font.letterSpacing: 0.7
                                                       Layout.preferredWidth: 52 }
                                                Repeater {
                                                    model: root.wgContentChoices
                                                    delegate: Chip {
                                                        required property var modelData
                                                        label: modelData.l
                                                        on: root.wgStyleGet(wrap.wid, "c") === modelData.k
                                                        onPicked: root.wgStyleSet(wrap.wid, "c", modelData.k)
                                                    }
                                                }
                                                Item { Layout.fillWidth: true }
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 8
                                                Text { text: "GROUND"; color: theme.faint; font.pixelSize: 10
                                                       font.family: Tok.mono; font.letterSpacing: 0.7
                                                       Layout.preferredWidth: 52 }
                                                Repeater {
                                                    model: root.wgGroundChoices
                                                    delegate: Chip {
                                                        required property var modelData
                                                        label: modelData.l
                                                        on: root.wgStyleGet(wrap.wid, "g") === modelData.k
                                                        onPicked: root.wgStyleSet(wrap.wid, "g", modelData.k)
                                                    }
                                                }
                                                Item { Layout.fillWidth: true }
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
                            // ---- per-widget options ----
                            // The first of these. sea-sysmon.sh samples cpu, ram, gpu, vram, temps and
                            // power every 3 seconds and the pill rendered exactly one of them, so a 6GB
                            // card had its VRAM measured on every tick and shown nowhere.
                            Section { title: "system monitor"; icon: "speed"; Layout.topMargin: 8 }
                            Text {
                                text: "which readings reach the bar pill. all of them are already being sampled, so adding one costs nothing. GPU readings hide themselves on a machine with no discrete card."
                                color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            Flow {
                                Layout.fillWidth: true; Layout.bottomMargin: 4; spacing: 6
                                Repeater {
                                    model: [{k:"cpu",l:"CPU %"},{k:"cput",l:"CPU temp"},
                                            {k:"ram",l:"RAM %"},{k:"ramg",l:"RAM GiB"},
                                            {k:"gpu",l:"GPU %"},{k:"gput",l:"GPU temp"},
                                            {k:"vram",l:"VRAM %"},{k:"vramg",l:"VRAM GiB"}]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool on: root.apSysShow.indexOf(modelData.k) >= 0
                                        height: 27; radius: Tok.r; width: smTxt.implicitWidth + 20
                                        color: on ? theme.a(theme.iris, 0.25)
                                             : (smMa.containsMouse ? theme.a(theme.line, 0.7) : theme.a(theme.line, 0.4))
                                        border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.2)
                                        Text { id: smTxt; anchors.centerIn: parent; text: modelData.l
                                            color: on ? theme.text : theme.sub
                                            font.pixelSize: 11; font.family: root.apFont; font.bold: on }
                                        MouseArea { id: smMa; anchors.fill: parent; hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.sysShowToggle(modelData.k) }
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
                                        width: lwrap.width; height: lwrap.height; radius: Tok.r
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
                                    Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
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
                                    implicitWidth: 84; implicitHeight: 36; radius: Tok.r
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
                                    Layout.fillWidth: true; implicitHeight: 44; radius: Tok.r
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                                        Sym { text: "bookmark"; sz: 17; color: theme.frost }
                                        Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                                        Rectangle { implicitWidth: 70; implicitHeight: 28; radius: Tok.r
                                            color: blLoadMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.18); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                            Text { anchors.centerIn: parent; text: "load"; color: blLoadMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont }
                                            MouseArea { id: blLoadMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.loadBarLayout(modelData) } }
                                        Rectangle { implicitWidth: 30; implicitHeight: 28; radius: Tok.r
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
                                    Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: profNameIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    TextInput {
                                        id: profNameIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: theme.text; font.pixelSize: 12; font.family: root.apFont
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: !profNameIn.text; text: "Enter preset name..."; color: theme.faint; font.pixelSize: 12 }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: 120; implicitHeight: 36; radius: Tok.r
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
                            
                            // ---- the rack ----
                            // Cartridges, not a list of rows with a Load button. A preset
                            // has a palette and no words for it, and the row this replaces
                            // spent its width on "font: Adwaita Sans · radius: 14px ·
                            // accent: #dbc0c8" — a description of a colour scheme in the
                            // one format that cannot show you a colour scheme.
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                visible: root.profilesList.length > 0
                                Section { title: "saved presets"; icon: "inventory_2" }
                                Text {
                                    text: "click a cartridge to load it · the lit lamp is the one you are on"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    Layout.leftMargin: 14; Layout.bottomMargin: 4
                                }
                                Flow {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    spacing: 10
                                    Repeater {
                                        model: root.profilesList
                                        delegate: ProfileCart {
                                            required property var modelData
                                            required property int index
                                            profile: modelData
                                            loaded: root.profLoaded(modelData)
                                            onLoad: root.loadProfile(modelData)   // it persists itself
                                            onEject: root.deleteProfile(index)
                                        }
                                    }
                                }
                            }

                            // Placeholder
                            Text {
                                text: "no presets saved yet — set the shell up how you like it, name it above, and save."
                                visible: root.profilesList.length === 0
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.mono
                                Layout.topMargin: 20; horizontalAlignment: Text.AlignHCenter
                                Layout.fillWidth: true
                            }
                        }

                        // ================= ACTIONS =================
                        ColumnLayout {
                            visible: root.tab === 5; Layout.fillWidth: true; spacing: 14
                            Section { title: "quick actions"; icon: "bolt" }
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
                                    Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                                    color: theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: kbField.text!=="" ? theme.a(theme.iris,0.5) : theme.a(theme.iris,0.2)
                                    Sym { id: kbLens; text: "search"; sz: 15; color: theme.faint
                                        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter } }
                                    TextInput {
                                        id: kbField
                                        anchors { left: kbLens.right; leftMargin: 8; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                        color: theme.text; font.pixelSize: 13; font.family: Tok.mono; clip: true
                                        onTextChanged: root.kbQuery = text
                                        Text { text: "type to filter · click a bind to edit it"; visible: kbField.text===""
                                            color: theme.faint; font.pixelSize: 12; font.family: Tok.mono; anchors.verticalCenter: parent.verticalCenter }
                                        Keys.onPressed: (e)=> {
                                            if (e.key === Qt.Key_Escape) { root.closePanel(); e.accepted = true; }
                                        }
                                    }
                                }
                                // Add Button → opens the editor popup in "add" mode
                                Rectangle {
                                    implicitWidth: 32; implicitHeight: 32; radius: Tok.r
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

                            // bind rows — a table, because that is what a keymap is. The chip
                            // column carries the combo; `_tone: accent` marks the bind currently
                            // being re-recorded so it stands out mid-capture.
                            IndTable {
                                Layout.fillWidth: true
                                rowHeight: 30
                                selectable: false
                                rows: root.kbShown
                                emptyText: root.kbQuery !== "" ? "no bind matches that" : "—"
                                columns: [
                                    { label: "Action",  key: "desc", flex: true },
                                    { label: "Binding", key: "keys", w: 200, chip: true, num: true, toneKey: "_tone" }
                                ]
                                onActivated: (i, row) => { if (row.canEdit) root.kbOpenEdit(row) }
                            }
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.kbShown.length + "/" + root.kbBinds.length + " binds · rebinds rewrite keybinds.lua + reload hyprland"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                        }

                        // ================= SYSTEM =================
                        // ================= SYSTEM / ABOUT =================
                        ColumnLayout {
                            visible: root.tab === 8; Layout.fillWidth: true; spacing: 12

                            // ---- hero: brand · version · host ----
                            // Was a horizontal accent gradient behind a brand hero. Flat surface
                            // and a hairline now — an internal tool opens on its data, not on a
                            // decorated masthead.
                            Rectangle {
                                Layout.fillWidth: true; radius: Tok.r; implicitHeight: 90
                                color: Tok.surface
                                border.width: 1; border.color: Tok.rule
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 18
                                    SeaLogo { size: 62; card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                                    ColumnLayout {
                                        spacing: 4; Layout.fillWidth: true
                                        RowLayout { spacing: 9
                                            Text { text: "sea-shell"; color: theme.text; font.pixelSize: 25; font.family: Tok.mono; font.bold: true }
                                            Rectangle { Layout.alignment: Qt.AlignVCenter
                                                implicitHeight: 21; implicitWidth: hvT.width + 15; radius: Tok.r; color: theme.iris
                                                Text { id: hvT; anchors.centerIn: parent; text: "v" + root.seaVersion; color: theme.bg; font.pixelSize: 11; font.family: Tok.mono; font.bold: true } }
                                        }
                                        RowLayout { spacing: 7
                                            Sym { text: "person"; sz: 14; color: theme.frost }
                                            Text { text: root.sysInfo.host || "…"; color: theme.frost; font.pixelSize: 13; font.family: Tok.mono }
                                            // distro logo: CachyOS is drawn (no Nerd glyph exists); everything else uses the Font Logos glyph
                                            CachyLogo { visible: root.sysInfo.id === "cachyos"; size: 15; color: theme.faint; Layout.leftMargin: 6 }
                                            Text { visible: root.sysInfo.id !== "cachyos"; text: root.distroGlyph(root.sysInfo.id, root.sysInfo.idlike)
                                                font.family: "Symbols Nerd Font"; font.pixelSize: 14; color: theme.faint; Layout.leftMargin: 6 }
                                            Text { text: root.sysInfo.os || "…"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; elide: Text.ElideRight; Layout.fillWidth: true }
                                        }
                                    }
                                    ColumnLayout { spacing: 2; Layout.alignment: Qt.AlignVCenter
                                        Text { text: "UPTIME"; color: theme.faint; font.pixelSize: 8; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1.5; Layout.alignment: Qt.AlignRight }
                                        Text { text: root.sysInfo.up || "…"; color: theme.frost; font.pixelSize: 15; font.family: Tok.mono; font.bold: true; Layout.alignment: Qt.AlignRight }
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

                            // ---- updates (OTA) ----
                            Section { title: "sea-shell updates"; icon: "cloud_download" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    RowLayout {
                                        spacing: 8
                                        Text { text: "installed " + (root.otaLocal || "…"); color: theme.text
                                            font.pixelSize: 12; font.family: Tok.mono }
                                        Rectangle {
                                            visible: root.otaState !== ""
                                            implicitHeight: 16; implicitWidth: otaTxt.width + 12; radius: Tok.r
                                            color: theme.a(root.otaColor, 0.18)
                                            border.width: 1; border.color: theme.a(root.otaColor, 0.5)
                                            Text { id: otaTxt; anchors.centerIn: parent
                                                text: root.otaState === "available" ? (root.otaBehind + " update" + (root.otaBehind === 1 ? "" : "s"))
                                                      : root.otaState
                                                color: root.otaColor; font.pixelSize: 9; font.family: Tok.mono; font.bold: true }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        text: root.otaBusy ? "working…"
                                              : (root.otaDetail || "check github for a newer sea-shell")
                                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    }
                                }
                                IndBtn { text: "Check"; rank: "secondary"; enabled: !root.otaBusy
                                    onActivated: otaProc.running = true }
                                IndBtn { text: "Update"; rank: "primary"; enabled: root.otaCanApply
                                    onActivated: otaApply.running = true }
                            }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                // Being explicit about the refusal rules up front is the point: an
                                // updater that might eat unpushed work is one nobody should press.
                                text: "pulls from your git remote and re-runs install.sh. it only ever fast-forwards — "
                                    + "if the repo has uncommitted changes, local commits, or has diverged, the update "
                                    + "is refused rather than merged, so nothing unpushed can be lost."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            // ---- health check ----
                            Section { title: "health check"; icon: "stethoscope" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    text: root.docRows.length === 0
                                          ? "checks dependencies, config validity, deployment and the bar's crash history."
                                          : (root.docCrit > 0 ? (root.docCrit + " problem" + (root.docCrit === 1 ? "" : "s")
                                                                + (root.docWarn > 0 ? " · " + root.docWarn + " warning" + (root.docWarn === 1 ? "" : "s") : ""))
                                             : root.docWarn > 0 ? (root.docWarn + " warning" + (root.docWarn === 1 ? "" : "s") + " · nothing broken")
                                             : "all " + root.docRows.length + " checks passed")
                                    color: root.docCrit > 0 ? theme.bad : root.docWarn > 0 ? theme.warn : theme.sub
                                    font.pixelSize: 11; font.family: Tok.mono
                                }
                                IndBtn { text: root.docRunning ? "Checking…" : "Run check"; rank: "primary"
                                    enabled: !root.docRunning; onActivated: docProc.running = true }
                            }
                            IndTable {
                                visible: root.docRows.length > 0
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 26
                                rows: root.docSorted
                                maxRows: 14
                                columns: [
                                    { label: "",       key: "st",     w: 54, chip: true },
                                    { label: "Area",   key: "cat",    w: 88, mono: true },
                                    { label: "Item",   key: "item",   w: 150, mono: true },
                                    { label: "Detail", key: "detail", flex: true }
                                ]
                            }

                            // ---- backup & restore ----
                            Section { title: "backup"; icon: "archive" }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: root.bkMsg !== "" ? root.bkMsg
                                      : "archives every setting, pin, rule, gesture, keybind and layout to ~/Documents. "
                                        + "restoring saves your current config first, so it is itself undoable. "
                                        + "wallpaper files are not included — only the path to them."
                                color: root.bkMsg !== "" ? theme.frost : theme.faint
                                font.pixelSize: 10; font.family: Tok.mono
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                IndBtn { text: "Back up now"; rank: "primary"; onActivated: root.bkCreate() }
                                IndBtn { text: "Refresh list"; rank: "secondary"; onActivated: bkListProc.running = true }
                                Item { Layout.fillWidth: true }
                            }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 28
                                rows: root.bkList
                                maxRows: 6
                                selectable: true
                                emptyText: "no backups yet"
                                columns: [
                                    { label: "Archive", key: "file", flex: true, mono: true },
                                    { label: "Size",    key: "size", w: 70,  num: true },
                                    { label: "Made",    key: "when", w: 120, mono: true }
                                ]
                                onActivated: (i, row) => root.bkRestore(row)
                            }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "click an archive to restore it. restart the bar afterwards to pick everything up."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            // ---- refresh ----
                            RowLayout { Layout.topMargin: 6; Layout.fillWidth: true
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    implicitHeight: 30; implicitWidth: rfRow.width + 22; radius: Tok.r
                                    color: rfMa.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.2)
                                    RowLayout { id: rfRow; anchors.centerIn: parent; spacing: 7
                                        Sym { text: "refresh"; sz: 15; color: theme.frost }
                                        Text { text: "refresh"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono } }
                                    MouseArea { id: rfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { sysProc.running = true; diskProc.running = true } }
                                }
                            }
                        }

                        // ================= DISKS =================
                        ColumnLayout {
                            visible: root.tab === 19; Layout.fillWidth: true; spacing: 14

                            // ---- overview ----
                            // Numbers first, detail below: how many drives, how much of the root
                            // filesystem is gone, and whether anything is plugged in.
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                Layout.topMargin: 4; spacing: Tok.s8
                                IndKpi {
                                    label: "DRIVES"; value: "" + root.diskDrives.length
                                    sub: root.diskRemovableCount > 0 ? (root.diskRemovableCount + " removable") : "all internal"
                                }
                                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Tok.rule }
                                IndKpi {
                                    label: "ROOT USED"; value: root.diskRootPct >= 0 ? ("" + root.diskRootPct) : "—"
                                    unit: root.diskRootPct >= 0 ? "%" : ""
                                    sub: root.diskRootFree !== "" ? (root.diskRootFree + " free") : ""
                                    tone: root.diskRootPct >= 90 ? "crit" : root.diskRootPct >= 80 ? "warn" : "ok"
                                }
                                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Tok.rule }
                                IndKpi {
                                    label: "MOUNTED"; value: "" + root.diskMountedCount
                                    sub: "of " + root.diskRows.length + " partitions"
                                }
                                Item { Layout.fillWidth: true }
                            }

                            // ---- one panel per physical drive ----
                            Repeater {
                                model: root.diskDrives
                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10
                                    spacing: 6

                                    // drive header: what it is, how it connects, and eject if removable
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Sym { text: modelData.removable ? "usb" : "hard_drive"; sz: 16
                                            color: modelData.removable ? theme.frost : theme.sub }
                                        Text { text: modelData.name; color: theme.text
                                            font.pixelSize: 13; font.family: Tok.mono; font.bold: true
                                            elide: Text.ElideRight; Layout.maximumWidth: 300 }
                                        Rectangle {
                                            implicitHeight: 15; implicitWidth: busT.width + 12; radius: Tok.r
                                            color: theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                            Text { id: busT; anchors.centerIn: parent; text: modelData.bus
                                                color: theme.frost; font.pixelSize: 9; font.family: Tok.mono; font.bold: true }
                                        }
                                        Text { text: modelData.size + "  ·  /dev/" + modelData.dev
                                            color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                                        Item { Layout.fillWidth: true }
                                        IndBtn {
                                            visible: modelData.removable
                                            text: "Eject"; rank: "secondary"
                                            onActivated: root.diskEject({ path: modelData.path, name: modelData.name,
                                                                          mounted: modelData.mounted })
                                        }
                                    }
                                    Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }

                                    // partitions of this drive
                                    Repeater {
                                        model: modelData.parts
                                        delegate: Rectangle {
                                            id: partRow
                                            required property var modelData
                                            readonly property bool sys: modelData.system
                                            Layout.fillWidth: true
                                            implicitHeight: 46
                                            radius: Tok.rSmall
                                            color: pma.containsMouse && !partRow.sys ? Tok.surface : "transparent"

                                            ColumnLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 4; anchors.rightMargin: 4
                                                anchors.topMargin: 5; anchors.bottomMargin: 5
                                                spacing: 3
                                                RowLayout {
                                                    Layout.fillWidth: true; spacing: 8
                                                    Text { text: modelData.dev; color: theme.text
                                                        font.pixelSize: 11; font.family: Tok.mono
                                                        Layout.minimumWidth: 92 }
                                                    Text { text: modelData.label !== "" ? modelData.label : "—"
                                                        color: theme.sub; font.pixelSize: 11; font.family: Tok.mono
                                                        Layout.minimumWidth: 76; elide: Text.ElideRight }
                                                    Text { text: modelData.fs; color: theme.faint
                                                        font.pixelSize: 10; font.family: Tok.mono
                                                        Layout.minimumWidth: 48 }
                                                    Text { text: modelData.size; color: theme.sub
                                                        font.pixelSize: 11; font.family: Tok.mono
                                                        Layout.minimumWidth: 62; horizontalAlignment: Text.AlignRight }
                                                    Text {
                                                        Layout.fillWidth: true; elide: Text.ElideMiddle
                                                        text: modelData.mounted ? modelData.mount : "not mounted"
                                                        color: modelData.mounted ? theme.frost : theme.faint
                                                        font.pixelSize: 10; font.family: Tok.mono
                                                    }
                                                    Rectangle {
                                                        implicitHeight: 15; implicitWidth: stT.width + 12; radius: Tok.r
                                                        readonly property color tone: partRow.sys ? theme.line
                                                                       : modelData.mounted ? theme.good : theme.iris
                                                        color: theme.a(tone, 0.18)
                                                        border.width: 1
                                                        border.color: theme.a(tone, 0.45)
                                                        Text { id: stT; anchors.centerIn: parent
                                                            text: partRow.sys ? "system"
                                                                  : modelData.mounted ? "mounted" : "idle"
                                                            color: partRow.sys ? theme.faint
                                                                   : modelData.mounted ? theme.good : theme.frost
                                                            font.pixelSize: 9; font.family: Tok.mono; font.bold: true }
                                                    }
                                                }
                                                // usage bar — only where a usage figure genuinely exists
                                                RowLayout {
                                                    Layout.fillWidth: true; spacing: 8
                                                    visible: modelData.pct >= 0
                                                    Rectangle {
                                                        Layout.fillWidth: true; implicitHeight: 5
                                                        radius: 2.5; color: theme.a(theme.line, 0.8)
                                                        Rectangle {
                                                            height: parent.height; radius: 2.5
                                                            width: parent.width * Math.max(0, Math.min(1, modelData.pct / 100))
                                                            color: modelData.pct >= 90 ? theme.bad
                                                                 : modelData.pct >= 78 ? theme.warn : theme.iris
                                                            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                                        }
                                                    }
                                                    Text {
                                                        text: modelData.used + " used  ·  " + modelData.avail + " free  ·  " + modelData.pct + "%"
                                                        color: theme.faint; font.pixelSize: 9; font.family: Tok.mono
                                                        Layout.minimumWidth: 200; horizontalAlignment: Text.AlignRight
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: pma
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: partRow.sys ? Qt.ArrowCursor : Qt.PointingHandCursor
                                                onClicked: root.diskToggle({ _system: modelData.system,
                                                                             _mounted: modelData.mounted,
                                                                             _path: modelData.path,
                                                                             dev: modelData.dev })
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 8
                                wrapMode: Text.WordWrap
                                text: root.diskMsg !== "" ? root.diskMsg
                                      : "click a partition to mount or unmount it. removable media mounts silently; internal "
                                        + "partitions ask for an admin password once per session. / and /boot are shown but never unmounted. "
                                        + "usage is only known for mounted filesystems."
                                color: root.diskMsg !== "" ? theme.frost : theme.faint
                                font.pixelSize: 10; font.family: Tok.mono
                            }

                        }

                        // ================= SCREEN TIME =================
                        ColumnLayout {
                            visible: root.tab === 18; Layout.fillWidth: true; spacing: 14

                            Section { title: "today"; icon: "hourglass_top" }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 30
                                rows: root.usageLimitRows
                                selectable: true
                                selectedIndex: root.usageSel
                                maxRows: 12
                                emptyText: "nothing recorded yet — the bar starts counting from its next restart"
                                columns: [
                                    { label: "App",   key: "app",   flex: true, mono: true },
                                    { label: "Today", key: "today", w: 84, num: true },
                                    { label: "Limit", key: "limit", w: 84, num: true },
                                    { label: "",      key: "state", w: 62, chip: true }
                                ]
                                onActivated: (i, row) => root.usageSel = i
                            }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "time each app held focus, paused while the session is idle. pick a row to set its daily limit."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            Section { title: "daily limit"; icon: "timer"
                                visible: root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length }
                            RowLayout {
                                visible: root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                readonly property string app: (root.usageSel >= 0 && root.usageSel < root.usageLimitRows.length)
                                                              ? root.usageLimitRows[root.usageSel].app : ""
                                Text { text: parent.app; color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                    Layout.minimumWidth: 170; elide: Text.ElideRight }
                                Repeater {
                                    model: [0, 30, 60, 120, 180, 240]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData === 0 ? "off" : (modelData + "m")
                                        on: (root.usageLimits[parent.parent.app] || 0) === modelData
                                        onPicked: root.ulimSet(parent.parent.app, modelData)
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                visible: root.usageSel >= 0
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "you get one notification the first time an app passes its limit each day. it does not block anything."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            Section { title: "daily summary"; icon: "summarize" }
                            ToggleCard {
                                icon: "notifications_active"; title: "Send a daily summary"
                                desc: "one notification with your total and top three apps"
                                on: root.usageSummary
                                onToggled: { root.usageSummary = !root.usageSummary; root.ulimSave() }
                            }
                            RowLayout {
                                visible: root.usageSummary
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                Text { text: "at"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 30 }
                                Repeater {
                                    model: ["17:00","19:00","21:00","23:00"]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData; on: root.usageSummaryTime === modelData
                                        onPicked: { root.usageSummaryTime = modelData; root.ulimSave() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                        }

                        // ================= WINDOW RULES =================
                        ColumnLayout {
                            visible: root.tab === 17; Layout.fillWidth: true; spacing: 14

                            Section { title: "window rules"; icon: "picture_in_picture" }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "match a window by class (and optionally title), then change how it opens. "
                                    + "hyprland applies rules when a window MAPS, so an edit affects the next window "
                                    + "of that class — windows already open keep what they were given."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 30
                                rows: root.wrRows
                                selectable: true
                                selectedIndex: root.wrSel
                                emptyText: "no rules yet — add one below"
                                columns: [
                                    { label: "Class",  key: "cls", w: 190, mono: true },
                                    { label: "Title",  key: "ttl", w: 130, mono: true },
                                    { label: "Does",   key: "act", flex: true }
                                ]
                                onActivated: (i, row) => root.wrSel = i
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                IndBtn { text: "Add rule"; rank: "primary"; onActivated: root.wrAdd() }
                                IndBtn { text: "Delete"; rank: "danger"; enabled: root.wrSel >= 0
                                    onActivated: root.wrDel(root.wrSel) }
                                Item { Layout.fillWidth: true }
                                IndBtn { text: "Re-apply all"; rank: "secondary"; onActivated: root.wrSave() }
                            }

                            // ---- editor for the selected rule ----
                            ColumnLayout {
                                id: wrEdit
                                visible: root.wrSel >= 0 && root.wrSel < root.wrRules.length
                                Layout.fillWidth: true; spacing: 10
                                readonly property var r: (root.wrSel >= 0 && root.wrSel < root.wrRules.length)
                                                          ? root.wrRules[root.wrSel] : ({})

                                Section { title: "match"; icon: "search" }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    Text { text: "class"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 54 }
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                                        color: theme.a(theme.line, 0.5); border.width: 1
                                        border.color: wrC.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                        TextInput { id: wrC; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono
                                            text: wrEdit.r["class"] || ""
                                            onEditingFinished: root.wrSet(root.wrSel, "class", text.trim())
                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrC.text
                                                text: "^(firefox)$"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    Text { text: "title"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 54 }
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                                        color: theme.a(theme.line, 0.5); border.width: 1
                                        border.color: wrT.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                        TextInput { id: wrT; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono
                                            text: wrEdit.r.title || ""
                                            onEditingFinished: root.wrSet(root.wrSel, "title", text.trim())
                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrT.text
                                                text: "optional — e.g. ^(Picture-in-Picture)$"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                }
                                Text {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
                                    visible: !wrEdit.r["class"] && !wrEdit.r.title
                                    text: "a rule with no class and no title would match every window — it is skipped until you fill one in."
                                    color: theme.bad; font.pixelSize: 10; font.family: Tok.mono
                                }
                                Text {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
                                    text: "tip: run  hyprctl clients -j | grep class  to find a window's class. open windows right now: "
                                          + root.wrOpenClasses
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                }

                                Section { title: "do this"; icon: "bolt" }
                                Grid {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                    columns: 3; columnSpacing: 8; rowSpacing: 8
                                    Repeater {
                                        model: [ { k: "float", l: "float" }, { k: "tile", l: "force tile" },
                                                 { k: "center", l: "center" }, { k: "pin", l: "pin" },
                                                 { k: "noblur", l: "no blur" }, { k: "noshadow", l: "no shadow" } ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property var rr: (root.wrSel >= 0 && root.wrSel < root.wrRules.length) ? root.wrRules[root.wrSel] : ({})
                                            readonly property bool on: !!rr[modelData.k]
                                            width: 150; height: 34; radius: Tok.r
                                            color: on ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.4)
                                            border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.14)
                                            Row { anchors.centerIn: parent; spacing: 7
                                                Sym { anchors.verticalCenter: parent.verticalCenter
                                                    text: on ? "check_box" : "check_box_outline_blank"; sz: 15
                                                    color: on ? theme.iris : theme.sub }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                                                    color: on ? theme.text : theme.sub; font.pixelSize: 11; font.family: Tok.mono } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.wrSet(root.wrSel, modelData.k, !parent.on) }
                                        }
                                    }
                                }
                                SliderRow {
                                    icon: "opacity"; label: "opacity"
                                    value: {
                                        var o = wrEdit.r.opacity;
                                        return (o === undefined || o === null) ? 1 : Math.max(0.2, Math.min(1, o));
                                    }
                                    readout: {
                                        var o = wrEdit.r.opacity;
                                        return (o === undefined || o >= 1) ? "off" : Number(o).toFixed(2);
                                    }
                                    onMoved: (v) => root.wrSet(root.wrSel, "opacity", Math.max(0.2, Math.min(1, v)))
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                    Text { text: "workspace"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 74 }
                                    Rectangle { implicitWidth: 90; implicitHeight: 30; radius: Tok.r
                                        color: theme.a(theme.line, 0.5); border.width: 1
                                        border.color: wrW.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                        TextInput { id: wrW; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono
                                            text: wrEdit.r.workspace || ""
                                            onEditingFinished: root.wrSet(root.wrSel, "workspace", text.trim())
                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrW.text
                                                text: "3"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                    Text { text: "size"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.leftMargin: 10 }
                                    Rectangle { implicitWidth: 120; implicitHeight: 30; radius: Tok.r
                                        color: theme.a(theme.line, 0.5); border.width: 1
                                        border.color: wrS.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                        TextInput { id: wrS; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono
                                            text: wrEdit.r.size || ""
                                            onEditingFinished: root.wrSet(root.wrSel, "size", text.trim())
                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrS.text
                                                text: "800x600"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono } } }
                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }

                        // ================= DOCK =================
                        ColumnLayout {
                            visible: root.tab === 16; Layout.fillWidth: true; spacing: 14

                            Section { title: "dock"; icon: "dock_to_bottom" }
                            ToggleCard {
                                icon: "apps"; title: "Enable dock"
                                desc: "a second surface for pinned and running apps. right-click an icon on the dock to pin or unpin it, middle-click to open another window."
                                on: root.apDock; onToggled: { root.apDock = !root.apDock; root.saveAppearance() }
                            }

                            Section { title: "placement"; icon: "open_with" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                Text { text: "edge"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                Repeater {
                                    model: ["bottom","top","left","right"]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData; on: root.apDockEdge === modelData
                                        onPicked: { root.apDockEdge = modelData; root.saveAppearance() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            // The bar and the dock are independent surfaces on the same layer, so
                            // nothing stops them being docked to the same edge — say so rather than
                            // silently stacking them.
                            Text {
                                visible: root.apDockEdge === root.apEdge
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "the dock and the bar are both on the " + root.apEdge + " edge — they will overlap. move one of them."
                                color: theme.warn; font.pixelSize: 10; font.family: Tok.mono
                            }
                            SliderRow {
                                icon: "photo_size_select_large"; label: "icon size"
                                value: Math.max(0, Math.min(1, (root.apDockIcon - 24) / 40))
                                readout: Math.round(root.apDockIcon) + " px"
                                onMoved: (v) => { root.apDockIcon = Math.round(24 + v * 40); root.saveAppearance() }
                            }

                            Section { title: "behaviour"; icon: "visibility" }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                Text { text: "when"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                Chip { label: "always";      on: root.apDockMode === "always"
                                       onPicked: { root.apDockMode = "always"; root.saveAppearance() } }
                                Chip { label: "auto-hide";   on: root.apDockMode === "autohide"
                                       onPicked: { root.apDockMode = "autohide"; root.saveAppearance() } }
                                Chip { label: "when free";   on: root.apDockMode === "intelligent"
                                       onPicked: { root.apDockMode = "intelligent"; root.saveAppearance() } }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: root.apDockMode === "always"
                                        ? "always visible, and reserves its strip so maximised windows stop above it."
                                      : root.apDockMode === "autohide"
                                        ? "hidden until you push the cursor into the screen edge."
                                        : "visible while nothing covers it, and slides away when a window moves underneath. windows keep the full screen."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            ToggleCard {
                                icon: "zoom_in"; title: "Magnify on hover"
                                desc: "the icon under the cursor and its neighbours grow. slots keep their width, so the row never shifts under you."
                                on: root.apDockZoom; onToggled: { root.apDockZoom = !root.apDockZoom; root.saveAppearance() }
                            }
                            ToggleCard {
                                icon: "playlist_add"; title: "Show running apps"
                                desc: "apps that are open but not pinned appear after the pinned ones, and leave when they close."
                                on: root.apDockRunning; onToggled: { root.apDockRunning = !root.apDockRunning; root.saveAppearance() }
                            }
                            ToggleCard {
                                icon: "label"; title: "Show names on hover"
                                desc: "app name above the icon, with the window count when more than one is open."
                                on: root.apDockLabels; onToggled: { root.apDockLabels = !root.apDockLabels; root.saveAppearance() }
                            }

                            // ---- attention ----
                            Section { title: "attention"; icon: "notifications_active" }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 4
                                wrapMode: Text.WordWrap
                                text: "clicking a link somewhere else asks the browser to come forward — Wayland calls it activation, and Hyprland leaves it to the shell to decide what that means. with both of these off the window is raised where it is and you go looking for it."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }
                            ToggleCard {
                                icon: "notifications_active"; title: "Flash the dock icon"
                                desc: "three beats on the app that is asking, so you can see which one it was."
                                on: root.apAttnFlash; onToggled: { root.apAttnFlash = !root.apAttnFlash; root.saveAppearance() }
                            }
                            ToggleCard {
                                icon: "arrow_forward"; title: "Switch to it"
                                desc: "go to the window, changing workspace if it is on another one. works whether or not the dock is on."
                                on: root.apAttnFocus; onToggled: { root.apAttnFocus = !root.apAttnFocus; root.saveAppearance() }
                            }

                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 4
                                wrapMode: Text.WordWrap
                                text: "pinned apps are stored in ~/.config/sea-shell/dock.json. per-monitor: the dock follows the same monitor list as the bar in Display."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }
                        }

                        // ================= CALENDAR =================
                        ColumnLayout {
                            visible: root.tab === 11; Layout.fillWidth: true; spacing: 14

                            // header + live count
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "calendar_month"; sz: 18; color: theme.iris }
                                Text { text: "calendar"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Rectangle { visible: root.calEvents.length > 0; implicitHeight: 20; implicitWidth: cntTxt.width + 16; radius: Tok.r
                                    color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                    Text { id: cntTxt; anchors.centerIn: parent; text: root.calEvents.length + (root.calEvents.length===1 ? " event" : " events")
                                        color: theme.frost; font.pixelSize: 10; font.family: Tok.mono; font.bold: true } }
                            }

                            // ---- import card ----
                            Rectangle {
                                Layout.fillWidth: true; radius: Tok.r; implicitHeight: impCol.implicitHeight + 24
                                color: theme.a(theme.line, 0.28); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                                ColumnLayout {
                                    id: impCol
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                    Text { text: "IMPORT EVENTS"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                                    // url + import link
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                                            color: theme.a(theme.bg, 0.4); border.width: 1
                                            border.color: calUrlIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                                Sym { text: "link"; sz: 15; color: theme.faint }
                                                TextInput {
                                                    id: calUrlIn
                                                    Layout.fillWidth: true
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                                    clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: calUrlIn.text === ""
                                                        text: "paste an .ics link…"; color: theme.faint; font.pixelSize: 12; font.family: Tok.mono }
                                                    Keys.onReturnPressed: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
                                        }
                                        Rectangle {
                                            implicitWidth: 108; implicitHeight: 36; radius: Tok.r
                                            color: calUrlMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                                            border.width: 1; border.color: theme.iris
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "download"; sz: 15; color: calUrlMa.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "Import"; color: calUrlMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true } }
                                            MouseArea { id: calUrlMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
                                    }
                                    // file picker + clear
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 8
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                                            color: calImpMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.14)
                                            border.width: 1; border.color: theme.a(theme.iris, 0.6)
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "upload_file"; sz: 15; color: calImpMa.containsMouse ? theme.bg : theme.frost }
                                                Text { text: "Import .ics file"; color: calImpMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true } }
                                            MouseArea { id: calImpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.pickFile("Select Calendar iCalendar (.ics) File", "iCalendar (*.ics) | *.ics", function(path) { root.importICS(path); }) } }
                                        Rectangle {
                                            implicitWidth: 128; implicitHeight: 36; radius: Tok.r
                                            visible: root.calEvents.length > 0
                                            color: calClrMa.containsMouse ? theme.a(theme.bad, 0.22) : "transparent"
                                            border.width: 1; border.color: calClrMa.containsMouse ? theme.bad : theme.a(theme.bad, 0.4)
                                            RowLayout { anchors.centerIn: parent; spacing: 6
                                                Sym { text: "delete_sweep"; sz: 15; color: theme.bad }
                                                Text { text: "Clear all"; color: theme.bad; font.pixelSize: 11; font.family: Tok.mono; font.bold: true } }
                                            MouseArea { id: calClrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.clearEvents() } }
                                    }
                                    Text { visible: root.calMsg !== ""; text: root.calMsg; color: theme.frost; font.pixelSize: 11; font.family: Tok.mono; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                }
                            }

                            // ---- subscriptions (imported links are remembered & auto-refreshed) ----
                            RowLayout { Layout.fillWidth: true; spacing: 8; visible: root.calSubs.length > 0
                                Text { text: "SUBSCRIPTIONS"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                                Sym { text: "sync"; sz: 14; color: resyncMa.containsMouse ? theme.iris : theme.faint
                                    MouseArea { id: resyncMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.calMsg = "re-syncing subscriptions…"; root.calMutate(["--resync"]) } } }
                                Text { text: "re-sync"; color: resyncMa.containsMouse ? theme.iris : theme.faint; font.pixelSize: 9; font.family: Tok.mono }
                            }
                            Repeater {
                                model: root.calSubs
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                                    color: theme.a(theme.line, 0.3); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                    RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                                        Sym { text: "link"; sz: 14; color: theme.frost }
                                        Text { text: modelData; color: theme.sub; font.pixelSize: 10; font.family: Tok.mono; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                        Sym { text: "close"; sz: 15; color: unsubMa.containsMouse ? theme.bad : theme.faint
                                            MouseArea { id: unsubMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--unsub", modelData]) } } }
                                }
                            }

                            // ---- reminders ----
                            RowLayout { Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
                                Text { text: "REMINDERS"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                            }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 46; radius: Tok.r
                                color: theme.a(theme.line, 0.28); border.width: 1; border.color: root.calRemind ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.12)
                                RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                    Sym { text: "notifications_active"; sz: 18; color: root.calRemind ? theme.frost : theme.faint }
                                    ColumnLayout { spacing: 0; Layout.fillWidth: true
                                        Text { text: "notify before events"; color: theme.text; font.pixelSize: 13; font.family: Tok.mono }
                                        Text { text: "timed: " + root.calLead + " min ahead · all-day: at 8:00 am"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono } }
                                    Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                        color: root.calRemind ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: root.calRemind ? theme.iris : theme.a(theme.iris, 0.3)
                                        Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.calRemind ? 27 : 3; color: theme.frost; Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","remind", root.calRemind ? "false" : "true"]) } } }
                            }
                            RowLayout { Layout.fillWidth: true; spacing: 6; visible: root.calRemind
                                Text { text: "lead"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.rightMargin: 4 }
                                Repeater { model: [10, 15, 30, 60]
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool sel: root.calLead === modelData
                                        implicitWidth: 48; implicitHeight: 26; radius: Tok.r
                                        color: sel ? theme.iris : (ldMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4)); border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                        Text { anchors.centerIn: parent; text: modelData + "m"; color: sel ? theme.bg : theme.sub; font.pixelSize: 10; font.family: Tok.mono; font.bold: sel }
                                        MouseArea { id: ldMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","lead", "" + modelData]) } } }
                                Item { Layout.fillWidth: true }
                            }

                            // ---- events list header + refresh ----
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
                                Text { text: "EVENTS"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
                                Sym { text: "refresh"; sz: 15; color: calRefMa.containsMouse ? theme.iris : theme.faint
                                    MouseArea { id: calRefMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: reloadEventsProc.running = true } }
                            }

                            Text { visible: root.calEvents.length === 0; text: "no events yet — import an .ics file or link above";
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.fillWidth: true; wrapMode: Text.Wrap }

                            Repeater {
                                model: root.calSorted
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property var rel: root.evRel(modelData.date)
                                    Layout.fillWidth: true; implicitHeight: bodyRow.implicitHeight + 16; radius: Tok.r
                                    opacity: rel.past ? 0.45 : 1
                                    color: theme.a(theme.line, 0.32); border.width: 1
                                    border.color: rel.soon ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.1)
                                    RowLayout {
                                        id: bodyRow
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: 8; anchors.rightMargin: 12; spacing: 12
                                        // date chip
                                        Rectangle {
                                            implicitWidth: 44; implicitHeight: 42; radius: Tok.r
                                            color: rel.soon ? theme.iris : theme.a(theme.iris, 0.14)
                                            ColumnLayout { anchors.centerIn: parent; spacing: 0
                                                Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(root.evDate(modelData.date), "ddd").toUpperCase()
                                                    color: rel.soon ? theme.bg : theme.frost; font.pixelSize: 9; font.family: Tok.mono; font.bold: true }
                                                Text { Layout.alignment: Qt.AlignHCenter; text: (""+modelData.date).slice(8)
                                                    color: rel.soon ? theme.bg : theme.text; font.pixelSize: 17; font.family: Tok.mono; font.bold: true } }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 2
                                            Text { text: modelData.title; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; font.bold: true
                                                Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                            RowLayout { spacing: 6
                                                Text { text: rel.t; color: rel.past ? theme.faint : theme.frost; font.pixelSize: 10; font.family: Tok.mono; font.bold: true }
                                                Text { visible: !!modelData.time; text: "· " + (modelData.time||""); color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                                                Text { text: "· " + Qt.formatDate(root.evDate(modelData.date), "d MMM yyyy"); color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
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
                                Text { text: "bluetooth"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Sym { text: (root.btAdapter && root.btAdapter.discovering) ? "sync" : "search"; sz: 16; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering } }
                                Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                    color: (root.btAdapter && root.btAdapter.enabled) ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.7)
                                    border.width: 1; border.color: (root.btAdapter && root.btAdapter.enabled) ? theme.iris : theme.a(theme.line, 0.9)
                                    Rectangle { width: 16; height: 16; radius: Tok.r; y: 3
                                        x: (root.btAdapter && root.btAdapter.enabled) ? parent.width - 19 : 3
                                        color: (root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint
                                        Behavior on x { NumberAnimation { duration: 120 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled } }
                            }
                            Text { visible: root.btAdapter === null; text: "no bluetooth adapter found"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                            IndTable {
                                Layout.fillWidth: true
                                rowHeight: 34
                                rows: root.btRows
                                emptyText: ""       // the tab prints its own richer empty message below
                                columns: [
                                    { label: "Device",  key: "name",    flex: true },
                                    { label: "Battery", key: "battery", w: 70,  num: true },
                                    { label: "State",   key: "state",   w: 110, chip: true, num: true }
                                ]
                                onActivated: (i, row) => {
                                    if (!row._dev) return;
                                    row._dev.connected ? row._dev.disconnect() : row._dev.connect();
                                }
                            }
                            Text { visible: root.btAdapter !== null && root.btDevices.length === 0
                                text: (root.btAdapter && root.btAdapter.enabled) ? "no paired devices — hit search to discover" : "bluetooth is off"
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                        }

                        // ================= KDE CONNECT =================
                        ColumnLayout {
                            visible: root.tab === 14; Layout.fillWidth: true; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Sym { text: "phonelink"; sz: 18; color: theme.iris }
                                Text { text: "kde connect"; color: theme.iris; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.18) }
                                Sym { text: "sync"; sz: 16; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.reloadKde() } }
                            }
                            ColumnLayout {
                                visible: root.kdeDevices.length === 0; Layout.fillWidth: true; spacing: 2
                                Text { text: "no devices found"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                                Text { text: "open KDE Connect on the other device, on the same network, then refresh"
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: root.kdeDevices
                                    delegate: Rectangle {
                                        id: kdeCard
                                        required property var modelData
                                        readonly property bool online: modelData.isPaired && modelData.isReachable
                                        Layout.fillWidth: true; radius: Tok.r
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
                                                    implicitWidth: 36; implicitHeight: 36; radius: Tok.r
                                                    color: kdeCard.online ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.5)
                                                    Sym { anchors.centerIn: parent; sz: 19
                                                        text: kdeCard.modelData.type === "phone" ? "smartphone"
                                                            : (kdeCard.modelData.type === "tablet" ? "tablet_android"
                                                            : (kdeCard.modelData.type === "tv" ? "tv" : "computer"))
                                                        color: kdeCard.online ? theme.iris : theme.faint }
                                                }
                                                ColumnLayout {
                                                    spacing: 2; Layout.fillWidth: true
                                                    Text { text: kdeCard.modelData.name; color: theme.text; font.pixelSize: 13; font.family: Tok.mono; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    RowLayout {
                                                        spacing: 6
                                                        Text {
                                                            text: !kdeCard.modelData.isPaired
                                                                    ? (kdeCard.modelData.isPairRequestedByPeer ? "wants to pair"
                                                                       : (kdeCard.modelData.isPairRequested ? "waiting for a reply…" : "not paired"))
                                                                    : (kdeCard.modelData.isReachable
                                                                       ? ("online" + (kdeCard.modelData.network ? " · " + kdeCard.modelData.network : ""))
                                                                       : "away")
                                                            color: kdeCard.online ? theme.frost : theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                                        }
                                                        Text { visible: kdeCard.modelData.address !== ""
                                                            text: "· " + kdeCard.modelData.address; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
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
                                                Text { text: "battery"; color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.preferredWidth: 58 }
                                                Rectangle {
                                                    Layout.fillWidth: true; implicitHeight: 9; radius: Tok.r; color: theme.a(theme.line, 0.8)
                                                    Rectangle {
                                                        height: parent.height; radius: Tok.r
                                                        width: parent.width * Math.max(0, Math.min(1, kdeCard.modelData.charge / 100))
                                                        color: kdeCard.modelData.isCharging ? theme.good
                                                             : (kdeCard.modelData.charge <= 20 ? theme.bad : theme.iris)
                                                        Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                                                    }
                                                }
                                                Text {
                                                    text: kdeCard.modelData.charge + "%" + (kdeCard.modelData.isCharging ? " charging" : "")
                                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.mono
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
                                                color: theme.sub; font.pixelSize: 10; font.family: Tok.mono; Layout.fillWidth: true; wrapMode: Text.WordWrap
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
                                                    font.pixelSize: 11; font.family: Tok.mono
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
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
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
                                        Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
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
                                    Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                                        color: root.idleOn ? theme.a(theme.iris, 0.35) : theme.a(theme.warn, 0.3)
                                        border.width: 1; border.color: root.idleOn ? theme.iris : theme.warn
                                        Rectangle { width: 16; height: 16; radius: Tok.r; y: 3
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
                                                implicitWidth: chipDim.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipDimMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipDim; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipDimMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDim = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customDimIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customDimIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: root.lockDim.toString(); selectByMouse: true
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
                                                implicitWidth: chipLck.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipLckMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipLck; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipLckMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockLock = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customLckIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customLckIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: Math.round(root.lockLock / 60).toString(); selectByMouse: true
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
                                                implicitWidth: chipDpms.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipDpmsMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipDpms; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipDpmsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDpms = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customDpmsIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customDpmsIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: Math.round(root.lockDpms / 60).toString(); selectByMouse: true
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
                                                implicitWidth: chipSsp.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipSspMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipSsp; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipSspMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockSuspend = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customSspIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customSspIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: Math.round(root.lockSuspend / 60).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockSuspend = Math.max(1, v * 60) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customSspIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 10 } } } }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                                        color: root.lockSuspendEnabled ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockSuspendEnabled ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
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
                                                implicitWidth: chipLidRow.implicitWidth + 18; implicitHeight: 26; radius: Tok.r
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
                                                implicitWidth: chipGrc.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipGrcMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipGrc; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipGrcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockGrace = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customGrcIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customGrcIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: root.lockGrace.toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockGrace = Math.max(0, v) }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customGrcIn.activeFocus; text: "s"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Hide cursor Toggle
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "navigation"; sz: 20 }
                                    Text { text: "hide cursor on lock"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                                        color: root.lockHideCursor ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockHideCursor ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
                                            x: root.lockHideCursor ? parent.width - 17 : 3
                                            color: root.lockHideCursor ? theme.frost : theme.faint
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockHideCursor = !root.lockHideCursor } }
                                }

                                // Ignore empty input Toggle
                                RowLayout { Layout.fillWidth: true; spacing: 10
                                    Sym { text: "space_bar"; sz: 20 }
                                    Text { text: "ignore empty input"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
                                    Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                                        color: root.lockIgnoreEmpty ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                                        border.width: 1; border.color: root.lockIgnoreEmpty ? theme.iris : theme.faint
                                        Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
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
                                                implicitWidth: chipPas.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipPasMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipPas; anchors.centerIn: parent; text: modelData.l.toString(); color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipPasMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurPasses = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customPasIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customPasIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: root.lockBlurPasses.toString(); selectByMouse: true
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
                                                implicitWidth: chipSz.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipSzMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipSz; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipSzMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurSize = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customSzIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customSzIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: root.lockBlurSize.toString(); selectByMouse: true
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
                                                implicitWidth: chipVib.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                                                color: sel ? theme.iris : (chipVibMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                                                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                                Text { id: chipVib; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                                                MouseArea { id: chipVibMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockVibrancy = modelData.v } } }
                                        Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                                            border.width: 1; border.color: customVibIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                                            TextInput { id: customVibIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                                color: theme.text; font.pixelSize: 11; font.family: Tok.mono; text: Math.round(root.lockVibrancy * 100).toString(); selectByMouse: true
                                                onEditingFinished: { var v = parseFloat(text); if(!isNaN(v)) root.lockVibrancy = Math.max(0, Math.min(100, v)) / 100 }
                                                Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customVibIn.activeFocus; text: "%"; color: theme.faint; font.pixelSize: 10 } } } }
                                }

                                // Wallpaper path text input
                                Text { text: "wallpaper image path"; color: theme.faint; font.pixelSize: 10; font.family: root.apFont; Layout.topMargin: 4 }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 10
                                    Rectangle {
                                        Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                                        color: theme.a(theme.line, 0.4); border.width: 1
                                        border.color: bgIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                        TextInput {
                                            id: bgIn
                                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                            clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                                            text: root.lockBg
                                            onTextChanged: root.lockBg = text
                                        }
                                    }
                                    Rectangle {
                                        implicitWidth: 36; implicitHeight: 36; radius: Tok.r
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
                                    Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
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
                                    implicitWidth: 120; implicitHeight: 38; radius: Tok.r
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

                        // ================= INPUT =================
                        ColumnLayout {
                            visible: root.tab === 15; Layout.fillWidth: true; spacing: 12

                            Section { title: "mouse"; icon: "mouse" }
                            SliderRow {
                                icon: "speed"; label: "sensitivity"
                                value: (root.apMouseSens + 1) / 2      // -1..1 mapped onto the 0..1 track
                                readout: (root.apMouseSens >= 0 ? "+" : "") + root.apMouseSens.toFixed(2)
                                onMoved: (v) => { root.apMouseSens = Math.round((v * 2 - 1) * 100) / 100
                                                  root.saveAppearance(); root.applyInput() }
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                Text { text: "accel"; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; Layout.minimumWidth: 76 }
                                Repeater {
                                    model: [ { v: "",         l: "default" },
                                             { v: "adaptive", l: "adaptive" },
                                             { v: "flat",     l: "flat" } ]
                                    delegate: Chip {
                                        required property var modelData
                                        label: modelData.l; on: root.apAccelProfile === modelData.v
                                        onPicked: { root.apAccelProfile = modelData.v; root.saveAppearance(); root.applyInput() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            ToggleCard {
                                icon: "swap_vert"; title: "natural scrolling"
                                desc: "invert mouse wheel direction"
                                on: root.apMouseNatural
                                onToggled: { root.apMouseNatural = !root.apMouseNatural; root.saveAppearance(); root.applyInput() }
                            }

                            Section { title: "touchpad"; icon: "touch_app" }
                            ToggleCard {
                                icon: "swap_vert"; title: "natural scrolling"
                                desc: "content follows your fingers"
                                on: root.apTpNatural
                                onToggled: { root.apTpNatural = !root.apTpNatural; root.saveAppearance(); root.applyInput() }
                            }
                            SliderRow {
                                icon: "unfold_more"; label: "scroll speed"
                                value: Math.min(1, root.apTpScroll / 3)
                                readout: root.apTpScroll.toFixed(2) + "×"
                                onMoved: (v) => { root.apTpScroll = Math.max(0.1, Math.round(v * 3 * 100) / 100)
                                                  root.saveAppearance(); root.applyInput() }
                            }
                            ToggleCard {
                                icon: "ads_click"; title: "tap to click"
                                on: root.apTpTap
                                onToggled: { root.apTpTap = !root.apTpTap; root.saveAppearance(); root.applyInput() }
                            }
                            ToggleCard {
                                icon: "edit_off"; title: "disable while typing"
                                desc: "ignore the touchpad mid-keystroke so a stray palm can't move the caret"
                                on: root.apTpDwt
                                onToggled: { root.apTpDwt = !root.apTpDwt; root.saveAppearance(); root.applyInput() }
                            }

                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.topMargin: 4
                                wrapMode: Text.WordWrap
                                text: "applied live via hyprctl eval, and re-applied at login — an eval only lasts as long as the current hyprland session"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }

                            // ---- touchpad gestures ----
                            Section { title: "gestures"; icon: "gesture" }
                            Text {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                wrapMode: Text.WordWrap
                                text: "swipe on the touchpad to do something. hyprland allows one gesture per "
                                    + "finger-count + direction pair, so a second one on the same pair never fires."
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            }
                            IndTable {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
                                rowHeight: 30
                                rows: root.gsRows
                                selectable: true
                                selectedIndex: root.gsSel
                                emptyText: "no gestures — hyprland ships none by default"
                                columns: [
                                    { label: "Fingers",   key: "fing", w: 90,  mono: true },
                                    { label: "Direction", key: "dir",  w: 110, mono: true },
                                    { label: "Does",      key: "act",  w: 120, mono: true },
                                    { label: "",          key: "note", flex: true }
                                ]
                                onActivated: (i, row) => root.gsSel = i
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                                IndBtn { text: "Add gesture"; rank: "primary"; onActivated: root.gsAdd() }
                                IndBtn { text: "Delete"; rank: "danger"; enabled: root.gsSel >= 0
                                    onActivated: root.gsDel(root.gsSel) }
                                Item { Layout.fillWidth: true }
                            }
                            ColumnLayout {
                                id: gsEdit
                                visible: root.gsSel >= 0 && root.gsSel < root.gsList.length
                                Layout.fillWidth: true; spacing: 8
                                readonly property var g: (root.gsSel >= 0 && root.gsSel < root.gsList.length)
                                                          ? root.gsList[root.gsSel] : ({})
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
                                    Text { text: "fingers"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 68 }
                                    Repeater { model: [2,3,4,5]
                                        delegate: Chip { required property var modelData
                                            label: "" + modelData; on: gsEdit.g.fingers === modelData
                                            onPicked: root.gsSet(root.gsSel, "fingers", modelData) } }
                                    Item { Layout.fillWidth: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
                                    Text { text: "direction"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 68 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: root.gsDirs
                                            delegate: Chip { required property var modelData
                                                label: modelData; on: gsEdit.g.direction === modelData
                                                onPicked: root.gsSet(root.gsSel, "direction", modelData) } } }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
                                    Text { text: "action"; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; Layout.minimumWidth: 68 }
                                    Flow { Layout.fillWidth: true; spacing: 6
                                        Repeater { model: root.gsActions
                                            delegate: Chip { required property var modelData
                                                label: modelData; on: gsEdit.g.action === modelData
                                                onPicked: root.gsSet(root.gsSel, "action", modelData) } } }
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
                                Rectangle { Layout.fillWidth: true; implicitHeight: 8; radius: Tok.r; color: theme.a(theme.line, 0.8)
                                    Rectangle { height: parent.height; radius: Tok.r
                                        width: parent.width * (UPower.displayDevice ? UPower.displayDevice.percentage : 0)
                                        color: UPower.onBattery && UPower.displayDevice.percentage < 0.2 ? theme.bad : theme.good } }
                                Text { text: UPower.displayDevice ? Math.round(UPower.displayDevice.percentage * 100) + "%" + (UPower.onBattery ? "" : " ⚡") : ""
                                    color: theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                            }

                            // ---- health / wear ----
                            // Charge % says how full the pack is; THIS says how much pack is
                            // left to fill. UPower doesn't expose it, so it comes from sysfs.
                            Section { visible: !!root.battHealth.present; title: "health"; icon: "health_and_safety" }
                            RowLayout {
                                visible: !!root.battHealth.present
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 24
                                IndKpi {
                                    label: "capacity"
                                    value: "" + (root.battHealth.pct || 0)
                                    unit: "%"
                                    size: Tok.tKpi
                                    sub: "of design"
                                    // a pack under ~80% of design is meaningfully worn; under 60% is near replacement
                                    tone: (root.battHealth.pct || 0) < 60 ? "crit"
                                        : (root.battHealth.pct || 0) < 80 ? "warn" : "ok"
                                }
                                IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
                                IndKpi {
                                    label: "cycles"
                                    value: (root.battHealth.cycles || 0) > 0 ? "" + root.battHealth.cycles : "—"
                                    size: Tok.tKpi
                                    sub: (root.battHealth.cycles || 0) > 0 ? "charge cycles" : "not reported"
                                }
                                IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
                                IndKpi {
                                    label: "pack"
                                    value: root.battHealth.model || "—"
                                    size: Tok.tPanel
                                    sub: [root.battHealth.vendor,
                                          root.battHealth.design > 0
                                            ? Math.round(root.battHealth.design / 1000) + " mAh design" : ""]
                                         .filter(function (x) { return x }).join("  ·  ")
                                }
                                Item { Layout.fillWidth: true }
                            }

                            Text { text: "power profile"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Repeater {
                                    model: [ {k:"power-saver", i:"eco", l:"saver"}, {k:"balanced", i:"balance", l:"balanced"}, {k:"performance", i:"speed", l:"performance"} ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool cur: root.powerProfile === modelData.k
                                        Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                        color: cur ? theme.a(theme.iris, 0.2) : (ppm.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.centerIn: parent; spacing: 7
                                            Sym { text: modelData.i; sz: 16; color: cur ? theme.iris : theme.frost }
                                            Text { text: modelData.l; color: cur ? theme.frost : theme.text; font.pixelSize: 12; font.family: Tok.mono; font.bold: cur } }
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
                                        Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                        color: cur ? theme.a(theme.iris, 0.2) : (ppmLid.containsMouse ? theme.a(theme.line, 0.5) : theme.a(theme.line, 0.3))
                                        border.width: 1; border.color: cur ? theme.iris : theme.a(theme.iris, 0.12)
                                        RowLayout { anchors.centerIn: parent; spacing: 6
                                            Sym { text: modelData.i; sz: 15; color: cur ? theme.iris : theme.frost }
                                            Text { text: modelData.l; color: cur ? theme.frost : theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: cur } }
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
                Rectangle { anchors.fill: parent; radius: Tok.r; color: Qt.rgba(0,0,0,0.55)
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
                    radius: Tok.r
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
                                color: theme.text; font.pixelSize: 15; font.family: Tok.mono; font.bold: true }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: kbXMa.containsMouse ? theme.a(theme.bad,0.25) : "transparent"
                                Sym { anchors.centerIn: parent; text: "close"; sz: 16; color: kbXMa.containsMouse ? theme.bad : theme.faint }
                                MouseArea { id: kbXMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                        }
                        // add-mode only: description + action inputs
                        ColumnLayout { visible: root.kbAdding; spacing: 4; Layout.fillWidth: true
                            Text { text: "description"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbDescIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbDescIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; clip: true; text: root.kbAddDesc; onTextChanged: root.kbAddDesc = text
                                    Text { visible: kbDescIn2.text===""; text: "e.g. Launch Firefox"; color: theme.faint; font.pixelSize: 12; font.family: Tok.mono; anchors.verticalCenter: parent.verticalCenter } } }
                            Text { text: "action / command"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.topMargin: 4 }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbActIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbActIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; clip: true; text: root.kbAddAction; onTextChanged: root.kbAddAction = text } }
                        }
                        // shortcut picker (both modes)
                        Text { text: "shortcut"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                        Flow { Layout.fillWidth: true; spacing: 6
                            Repeater { model: ["SUPER","CTRL","ALT","SHIFT"]
                                delegate: Rectangle { required property string modelData
                                    readonly property var mods: root.kbAdding ? root.kbAddMods : root.kbRecMods
                                    readonly property bool on: mods.indexOf(modelData) >= 0
                                    width: kmcT.width + 16; height: 26; radius: Tok.r
                                    color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5); border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                    Text { id: kmcT; anchors.centerIn: parent; text: modelData; color: on ? theme.frost : theme.faint; font.pixelSize: 11; font.family: Tok.mono; font.bold: on }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.kbAdding) { var m = root.kbAddMods.slice(); var i = m.indexOf(modelData); if(i>=0)m.splice(i,1); else m.push(modelData); root.kbAddMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m.indexOf(x)>=0); }
                                            else { var m2 = root.kbRecMods.slice(); var j = m2.indexOf(modelData); if(j>=0)m2.splice(j,1); else m2.push(modelData); root.kbRecMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m2.indexOf(x)>=0); root.kbConflict=""; }
                                        } } }
                            }
                        }
                        // key capture
                        RowLayout { Layout.fillWidth: true; spacing: 10
                            Text { text: "key"; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; Layout.minimumWidth: 30 }
                            Rectangle { id: kbKeyBox; Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                readonly property bool rec: root.kbAdding ? root.kbAddRecording : root.kbRecRecording
                                readonly property string keyv: root.kbAdding ? root.kbAddKey : root.kbRecKey
                                color: rec ? theme.a(theme.bad,0.18) : theme.a(theme.line,0.4); border.width: 1; border.color: rec ? theme.bad : theme.a(theme.iris,0.3)
                                Text { anchors.centerIn: parent
                                    text: kbKeyBox.rec ? "press a key…" : (kbKeyBox.keyv ? root.kbPretty(kbKeyBox.keyv) : "click, then press a key")
                                    color: kbKeyBox.rec ? theme.bad : (kbKeyBox.keyv ? theme.frost : theme.faint); font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (root.kbAdding) root.kbAddRecording = true; else root.kbRecRecording = true; kbCapture.forceActiveFocus() } }
                            }
                        }
                        // conflict / hint
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: root.kbConflict !== "" ? root.kbConflict : "pick modifiers, click the key box and press a key"
                            color: root.kbConflict !== "" ? theme.bad : theme.faint; font.pixelSize: 10; font.family: Tok.mono }
                        // actions
                        RowLayout { Layout.fillWidth: true; spacing: 10; Layout.topMargin: 2
                            Item { Layout.fillWidth: true }
                            Rectangle { implicitWidth: 76; implicitHeight: 32; radius: Tok.r
                                color: kbCanMa.containsMouse ? theme.a(theme.bad,0.14) : "transparent"; border.width: 1; border.color: kbCanMa.containsMouse ? theme.bad : theme.a(theme.line,0.6)
                                Text { anchors.centerIn: parent; text: "cancel"; color: kbCanMa.containsMouse ? theme.bad : theme.text; font.pixelSize: 12; font.family: Tok.mono }
                                MouseArea { id: kbCanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                            Rectangle { id: kbOkBtn
                                readonly property bool valid: root.kbAdding ? (root.kbAddDesc.trim()!=="" && root.kbAddKey!=="" && root.kbAddAction.trim()!=="") : (root.kbRecKey!=="")
                                implicitWidth: 92; implicitHeight: 32; radius: Tok.r
                                color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22)) : theme.a(theme.line,0.3); border.width: 1; border.color: kbOkBtn.valid ? theme.iris : theme.a(theme.line,0.5)
                                Text { anchors.centerIn: parent; text: root.kbAdding ? "add bind" : "save"; color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.bg : theme.text) : theme.faint; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
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
                radius: Tok.r
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
                        Text { text: root.fileBrowserTitle; color: theme.text; font.pixelSize: 15; font.family: Tok.mono; font.bold: true; Layout.fillWidth: true }
                        // Confirm — folder mode only, where the answer is where you are
                        Rectangle {
                            visible: root.fileBrowserDirs
                            implicitWidth: fbUseRow.implicitWidth + 22; implicitHeight: 32; radius: Tok.r
                            color: fbUseMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22)
                            border.width: 1; border.color: theme.iris
                            Behavior on color { ColorAnimation { duration: 110 } }
                            RowLayout {
                                id: fbUseRow; anchors.centerIn: parent; spacing: 7
                                Sym { text: "check"; sz: 16; color: fbUseMa.containsMouse ? Tok.accentInk : Tok.ink }
                                Text { text: "use this folder"; color: fbUseMa.containsMouse ? Tok.accentInk : Tok.ink
                                       font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                            }
                            MouseArea {
                                id: fbUseMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.fileBrowserOpen = false;
                                    if (root.fileBrowserCallback) root.fileBrowserCallback(root.fileBrowserPath);
                                }
                            }
                        }
                        // Cancel button
                        Rectangle {
                            implicitWidth: 32; implicitHeight: 32; radius: Tok.r
                            color: fbCloseMa.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"
                            Sym { anchors.centerIn: parent; text: "close"; sz: 18; color: fbCloseMa.containsMouse ? theme.bad : theme.faint }
                            MouseArea { id: fbCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.fileBrowserOpen = false } }
                    }

                    // Path navigation bar
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Rectangle {
                            implicitWidth: 36; implicitHeight: 34; radius: Tok.r
                            color: fbUpMa.containsMouse ? theme.iris : theme.a(theme.line, 0.4)
                            border.width: 1; border.color: theme.a(theme.iris, 0.25)
                            Sym { anchors.centerIn: parent; text: "arrow_upward"; sz: 16; color: fbUpMa.containsMouse ? theme.bg : theme.frost }
                            MouseArea { id: fbUpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUpDir() } }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                            color: theme.a(theme.bg, 0.8); border.width: 1; border.color: theme.a(theme.iris, 0.2)
                            Text { anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                verticalAlignment: Text.AlignVCenter
                                text: root.fileBrowserPath; color: theme.frost; font.pixelSize: 12; font.family: Tok.mono; elide: Text.ElideLeft } }
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
                                Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
                                color: fbItemUpMa.containsMouse ? theme.a(theme.line, 0.6) : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                    Sym { text: "drive_folder_upload"; sz: 16; color: theme.iris }
                                    Text { text: ".."; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; font.bold: true } }
                                MouseArea { id: fbItemUpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUpDir() } }

                            Repeater {
                                model: root.fileBrowserItems
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool isDir: modelData.type === "d"
                                    readonly property bool matchesFilter: root.fileBrowserDirs ? false
                                        : (!root.fileBrowserFilter || modelData.name.endsWith(root.fileBrowserFilter))
                                    visible: isDir || matchesFilter
                                    Layout.fillWidth: true
                                    implicitHeight: (isDir || matchesFilter) ? 38 : 0
                                    radius: Tok.r
                                    color: fbItemMa.containsMouse ? theme.a(theme.iris, 0.16) : "transparent"
                                    border.width: fbItemMa.containsMouse ? 1 : 0; border.color: theme.a(theme.iris, 0.25)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                        Sym {
                                            text: isDir ? "folder" : "description"
                                            sz: 16; color: isDir ? theme.frost : theme.faint }
                                        Text {
                                            text: modelData.name; color: theme.text
                                            font.pixelSize: 12; font.family: Tok.mono; font.bold: isDir; elide: Text.ElideRight; Layout.fillWidth: true } }
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
