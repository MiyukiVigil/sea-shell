//@ pragma UseQApplication
// sea-shell — settings / control center (tabbed)
// RESIDENT: preloaded once by shell.qml (Loader) and shown/hidden via IPC so opening is
// instant instead of spawning a ~0.5s `qs -p` process each time. Toggle it with
//   qs -c sea-shell ipc call settings toggle       (SUPER+S)
// or, in-process, settingsLoader.item.openTab(n).  Esc / click-outside hides it.
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import "WifiEnterprise.js" as WifiEnterprise

Scope {
    id: root
    property string repo: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    // Read from the VERSION file install.sh deploys, not hardcoded here. The literal used to be
    // "mirrored in the repo VERSION file" by hand, and the two had silently drifted a whole major
    // release apart — the badge read v5.0.0 on a 6.0.0 install. A version badge that lies is worse
    // than no badge. The literal survives only as the fallback for a `qs -p` run out of the repo
    // with nothing deployed; the second path covers that case too (quickshell/ui/ → repo root).
    property string seaVersion: "7.0.0"
    Process {
        running: true
        command: ["sh","-c","cat \"$HOME/.config/quickshell/sea-shell/VERSION\" 2>/dev/null || cat \"" + root.repo + "/../../VERSION\" 2>/dev/null"]
        stdout: StdioCollector { id: verOut; onStreamFinished: {
            var v = (verOut.text || "").trim();
            if (v.length > 0) root.seaVersion = v;
        } }
    }
    property var userProfile: ({})
    FileView {
        path: Quickshell.env("HOME") + "/.config/sea-shell/profile.json"
        watchChanges: true
        onLoaded: { try { root.userProfile=JSON.parse(text()) } catch(e){} }
        onFileChanged: reload()
    }
    property var recentPages: []
    property var favPages: []
    readonly property string favPagesPath: Quickshell.env("HOME") + "/.config/sea-shell/settings-favs.json"
    Process {
        id: favLoadProc
        running: true
        command: ["sh", "-c", "cat \"" + root.favPagesPath + "\" 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: favLoadOut; onStreamFinished: {
            try {
                var a = JSON.parse(favLoadOut.text.trim());
                root.favPages = Array.isArray(a) ? a.filter(function(t) { return root.tabMeta[t] }) : [];
            } catch (e) { root.favPages = [] }
        } } }
    function saveFavPages() {
        var b64 = Qt.btoa(JSON.stringify(root.favPages));
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p \"$HOME/.config/sea-shell\" && echo '" + b64 + "' | base64 -d > \"" + root.favPagesPath + "\""]);
    }
    function isFav(tab) { return root.favPages.indexOf(Number(tab)) >= 0; }
    function toggleFav(tab) {
        var t = Number(tab);
        if (!root.tabMeta[t]) return;
        var f = root.favPages.slice();
        var i = f.indexOf(t);
        if (i >= 0) f.splice(i, 1); else f.push(t);
        root.favPages = f;
        saveFavPages();
    }
    // The two profile editors, on pages that may not be built yet, keep each other current.
    property var lockEditor: null
    property var userEditor: null
    property int tab: 8                             // land on the System / About dashboard

    // ---- resident lifecycle: the panel is hidden until shown, so it costs ~nothing closed ----
    property bool shown: false
    property bool authenticationPending: false
    function openPanel() { root.showTab(8) }
    function openTab(t) {
        var requested = Number(t);
        root.showTab(Number.isInteger(requested) && root.tabMeta[requested] ? requested : 8);
    }
    function closePanel() { root.shown = false }
    function togglePanel() { if (root.shown) root.closePanel(); else root.openPanel() }
    // ---------------- finding things ----------------
    //
    // TWENTY-TWO PAGES, SIXTY-ODD SECTIONS. The sidebar is grouped, which makes the pages
    // scannable, and that is where its help stops: knowing that "global menu" lives on the
    // Bar page — ninth section down, past the widget list — is knowledge you either have or
    // do not. Every settings app that is pleasant to use answers that with a search field,
    // and every critique of the ones that are not (Ventura's especially) comes back to
    // things being buried with no way to ask for them by name.
    //
    // Two surfaces are built on one registry: type to find any section anywhere, or use the
    // chips above a page to jump within it without scrolling.
    property var sectionIndex: []
    property bool sectionsReady: false
    // Bumped once the registrations have stopped arriving, so the two views built on the
    // registry recompute. NOT set from the panel's own Component.onCompleted: the settings
    // window is not shown at startup and its contents are built later than this file's root,
    // so that handler ran with an empty index and the chips never appeared. A short debounce
    // makes "ready" mean "nothing has registered for a moment", which is true whenever the
    // sections happen to be built.
    property int sectionTick: 0
    Timer {
        id: secSettle
        interval: 60
        onTriggered: { root.sectionsReady = true; root.sectionTick++ }
    }
    function regSection(sec) {
        // Walk up to whichever page column owns this section. The pages carry `tabIdx`
        // precisely so a section does not have to be told twice which page it is on.
        var t = -1, p = sec.parent;
        while (p) { if (p.tabIdx !== undefined) { t = p.tabIdx; break } p = p.parent }
        if (t < 0) return;
        sec.sameAsPage = sec.title.toLowerCase() === ("" + root.tabLabel(t)).toLowerCase();
        root.sectionIndex.push({ "tab": t, "title": sec.title, "icon": sec.icon, "item": sec });
        secSettle.restart();
    }

    // idx -> what the sidebar calls that page, so a search hit can say where it lives.
    // quiet hours: the bar reads this same file and does the silencing (shell.qml quietCfg)
    property var quietCfg: ({ enabled: false, from: "22:00", to: "07:00", share: true })
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/quiet.json"; watchChanges: true; printErrors: false
        onLoaded: { try { var j = JSON.parse(text());
            root.quietCfg = { enabled: !!j.enabled, from: j.from || "22:00", to: j.to || "07:00", share: j.share !== false } } catch (e) {} }
        onFileChanged: reload() }
    property bool dndOn: false
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/dnd"; watchChanges: true; printErrors: false
        onLoaded: root.dndOn = text().trim() === "1"
        onFileChanged: reload() }
    property var mutedList: []
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/notif-mutes.json"; watchChanges: true; printErrors: false
        onLoaded: { try { var a = JSON.parse(text()); root.mutedList = Array.isArray(a) ? a : [] } catch (e) {} }
        onFileChanged: reload() }
    property string focusActive: ""
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/focus-active"; watchChanges: true; printErrors: false
        onLoaded: root.focusActive = text().trim()
        onFileChanged: reload() }
    function setQuiet(k, v) {
        // half-typed times read as "2_:__" through the mask; leave the last good one alone
        if ((k === "from" || k === "to") && !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(v)) return;
        var c = Object.assign({}, root.quietCfg); c[k] = v; root.quietCfg = c;
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" > \"$HOME/.config/sea-shell/quiet.json\"", "sh", JSON.stringify(c)]);
    }
    readonly property var tabMeta: ({
        0:  { l: "Sound",                i: "volume_up",             c: "#FF2D55" },
        1:  { l: "Displays",             i: "monitor",               c: "#007AFF" },
        2:  { l: "Network",              i: "wifi",                  c: "#007AFF" },
        3:  { l: "Weather",              i: "cloud",                 c: "#32ADE6", parent: 22 },
        4:  { l: "Appearance",           i: "palette",               c: "#AF52DE" },
        5:  { l: "Quick Actions",        i: "bolt",                  c: "#FF9500", parent: 8 },
        6:  { l: "Battery & Power",      i: "battery_charging_full", c: "#34C759" },
        7:  { l: "Keyboard",             i: "keyboard",              c: "#636366" },
        8:  { l: "General",              i: "settings",              c: "#8E8E93" },
        9:  { l: "Bluetooth",            i: "bluetooth",             c: "#007AFF" },
        10: { l: "Lock Screen",          i: "lock",                  c: "#5E5CE6" },
        11: { l: "Calendar",             i: "calendar_month",        c: "#FF3B30", parent: 22 },
        12: { l: "Bar Widgets",          i: "widgets",               c: "#32ADE6", parent: 20 },
        13: { l: "Theme Profiles",       i: "auto_awesome",          c: "#AF52DE", parent: 4 },
        14: { l: "Phone Link",           i: "phonelink",             c: "#30B0C7" },
        15: { l: "Mouse & Trackpad",     i: "mouse",                 c: "#636366" },
        16: { l: "Desktop & Dock",       i: "dock_to_bottom",        c: "#0A84FF" },
        17: { l: "Window Rules",         i: "picture_in_picture",    c: "#5856D6", parent: 16 },
        18: { l: "Screen Time",          i: "hourglass_top",         c: "#5856D6" },
        19: { l: "Storage",              i: "hard_drive",            c: "#8E8E93", parent: 8 },
        20: { l: "Menu Bar",             i: "view_agenda",           c: "#32ADE6" },
        21: { l: "Wallpaper",            i: "wallpaper",             c: "#30B0C7" },
        22: { l: "Apps & Calendar",      i: "apps",                  c: "#007AFF" },
        23: { l: "Your Profile",         i: "account_circle",        c: "#007AFF" },
        24: { l: "Notifications",        i: "notifications",         c: "#FF3B30" },
        25: { l: "Gaming",               i: "sports_esports",        c: "#FF5E3A" },
        26: { l: "Accessibility",        i: "accessibility_new",     c: "#007AFF" },
        27: { l: "Privacy & Security",   i: "shield",                c: "#FF9500" },
        28: { l: "About",                i: "info",                  c: "#8E8E93", parent: 8 },
        29: { l: "Software Update",      i: "system_update_alt",     c: "#8E8E93", parent: 8 },
        30: { l: "Login Items & Startup",i: "rocket_launch",         c: "#8E8E93", parent: 8 },
        31: { l: "Date & Time",          i: "schedule",              c: "#8E8E93", parent: 8 },
        32: { l: "Language & Region",    i: "language",              c: "#8E8E93", parent: 8 },
        33: { l: "Backup & Restore",     i: "archive",               c: "#34C759", parent: 8 },
        34: { l: "Health Check",         i: "stethoscope",           c: "#30B0C7", parent: 8 },
        35: { l: "Window Effects",       i: "view_quilt",            c: "#0A84FF", parent: 16 }
    })
    function tabLabel(t)  { var m = root.tabMeta[t]; return m ? m.l : "" }
    function tabIcon(t)   { var m = root.tabMeta[t]; return m ? m.i : "tune" }
    function tabColor(t)  { var m = root.tabMeta[t]; return (m && m.c) ? m.c : Tok.accent }
    function tabParent(t) { var m = root.tabMeta[t]; return (m && m.parent !== undefined) ? m.parent : -1 }
    readonly property int activeSidebarTab: root.tabParent(root.tab) >= 0 ? root.tabParent(root.tab) : root.tab

    // ---- macOS System Settings surface tokens (derived from sea-shell's live palette) ----
    readonly property color windowCanvas: Tok.light ? Qt.hsla(Tok._h, 0.06 * Tok._sm, 0.955, 1) : Tok.bg
    readonly property color sidebarFill:  Tok.light ? Qt.hsla(Tok._h, 0.08 * Tok._sm, 0.922, 1) : Tok.sunken
    readonly property color cardFill:     Tok.light ? "#ffffff" : Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, 0.055)
    readonly property color cardBorder:   Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, Tok.light ? 0.085 : 0.095)
    readonly property color hairline:     Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, Tok.light ? 0.075 : 0.085)
    readonly property color groupFill:    root.cardFill
    readonly property color groupRule:    root.cardBorder
    readonly property color rowHover:     Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, Tok.light ? 0.045 : 0.065)
    function tileColor(turn) {
        var h = ((Tok._h + turn) % 1 + 1) % 1;
        return Qt.hsla(h, Tok._achromatic ? 0 : 0.46, Tok.light ? 0.55 : 0.5, 1);
    }

    // ---- back and forward, as in System Settings' toolbar ----
    property var navBack: []
    property var navFwd: []
    property int navLast: tab
    property bool navMoving: false
    readonly property bool canNavBack: root.navBack.length > 0 || root.tabParent(root.tab) >= 0
    function navGo(dir) {
        if (dir < 0 && !root.navBack.length) {
            var p = root.tabParent(root.tab);
            if (p >= 0) {
                root.navMoving = true;
                root.navFwd = root.navFwd.concat([root.tab]);
                root.tab = p;
                root.navMoving = false;
            }
            return;
        }
        var from = dir < 0 ? root.navBack : root.navFwd;
        if (!from.length) return;
        var to = from[from.length - 1];
        root.navMoving = true;
        if (dir < 0) { root.navBack = from.slice(0, -1); root.navFwd = root.navFwd.concat([root.tab]) }
        else { root.navFwd = from.slice(0, -1); root.navBack = root.navBack.concat([root.tab]) }
        root.tab = to;
        root.navMoving = false;
    }

    // ---- real system backends via sea-sys-settings.py ----
    readonly property string sysScript: Qt.resolvedUrl("sea-sys-settings.py").toString().replace("file://", "")
    property string sysMsg: ""
    property var dtInfo: ({ timezone: "", ntp: true, ntpSynced: false, localRtc: false })
    property var dtTimezones: []
    property var localeInfo: ({ lang: "en_US.UTF-8", lcTime: "", lcMeasurement: "", keymap: "", locales: [] })
    property var startupApps: []
    property var startupServices: []
    property var netExtra: ({ hostname: "", wired: [], activeConnection: "", dnsPreset: "auto", dnsServers: [] })
    property var privInfo: ({ ufwInstalled: false, ufwEnabled: false, clipCount: 0, clipWatching: false, micApps: [], camPresent: false, camInUse: false })
    property bool privBusy: false
    property var compCfg: ({
        gaps_in: 5, gaps_out: 12, border_size: 2, rounding: 10,
        blur_enabled: true, blur_size: 9, blur_passes: 4, shadow_enabled: true,
        inactive_opacity: 0.96, animations_enabled: true, follow_mouse: 1,
        kb_layout: "us", kb_options: "", repeat_rate: 25, repeat_delay: 600,
        numlock_by_default: true, cursor_size: 24, zoom_factor: 1.0
    })

    Process {
        id: dtGetProc
        command: ["python3", root.sysScript, "datetime-status"]
        stdout: StdioCollector { id: dtGetOut; onStreamFinished: {
            try { var j = JSON.parse(dtGetOut.text); if (j.ok) root.dtInfo = j } catch (e) {}
        } }
    }
    Process {
        id: dtTzProc
        stdout: StdioCollector { id: dtTzOut; onStreamFinished: {
            try { var j = JSON.parse(dtTzOut.text); if (j.ok) root.dtTimezones = j.timezones || [] } catch (e) {}
        } }
    }
    Process {
        id: localeGetProc
        command: ["python3", root.sysScript, "locale-status"]
        stdout: StdioCollector { id: locGetOut; onStreamFinished: {
            try { var j = JSON.parse(locGetOut.text); if (j.ok) root.localeInfo = j } catch (e) {}
        } }
    }
    Process {
        id: startupGetProc
        command: ["python3", root.sysScript, "startup-list"]
        stdout: StdioCollector { id: stGetOut; onStreamFinished: {
            try {
                var j = JSON.parse(stGetOut.text);
                if (j.ok) { root.startupApps = j.apps || []; root.startupServices = j.services || [] }
            } catch (e) {}
        } }
    }
    Process {
        id: netExtraProc
        command: ["python3", root.sysScript, "network-extra"]
        stdout: StdioCollector { id: netExOut; onStreamFinished: {
            try { var j = JSON.parse(netExOut.text); if (j.ok) root.netExtra = j } catch (e) {}
        } }
    }
    Process {
        id: privGetProc
        command: ["python3", root.sysScript, "privacy-status"]
        stdout: StdioCollector { id: privOut; onStreamFinished: {
            try { var j = JSON.parse(privOut.text); if (j.ok) root.privInfo = j } catch (e) {}
        } }
    }
    Process {
        id: compGetProc
        command: ["python3", root.sysScript, "compositor-get"]
        stdout: StdioCollector { id: compOut; onStreamFinished: {
            try { var j = JSON.parse(compOut.text); if (j.ok && j.config) root.compCfg = j.config } catch (e) {}
        } }
    }
    Process {
        id: sysActionProc
        property string afterRefresh: ""
        stdout: StdioCollector { id: sysActOut; onStreamFinished: {
            root.privBusy = false;
            try {
                var j = JSON.parse(sysActOut.text);
                if (!j.ok && j.error) root.sysMsg = j.error;
                else if (j.ok) root.sysMsg = "";
                if (j.ok && j.config) root.compCfg = j.config;
            } catch (e) {}
            if (sysActionProc.afterRefresh === "datetime") root.refreshDateTime();
            else if (sysActionProc.afterRefresh === "locale") root.refreshLocale();
            else if (sysActionProc.afterRefresh === "startup") root.refreshStartup();
            else if (sysActionProc.afterRefresh === "net") { root.refreshNetExtra(); root.rescanWifi(); }
            else if (sysActionProc.afterRefresh === "privacy") root.refreshPrivacy();
            else if (sysActionProc.afterRefresh === "host") { root.refreshSystemInfo(); root.refreshNetExtra(); }
        } }
    }
    function runSysAction(args, refreshKey) {
        sysActionProc.afterRefresh = refreshKey || "";
        sysActionProc.command = ["python3", root.sysScript].concat(args);
        sysActionProc.running = false;
        sysActionProc.running = true;
    }
    function refreshDateTime() { dtGetProc.running = false; dtGetProc.running = true }
    function searchTimezones(q) {
        dtTzProc.command = ["python3", root.sysScript, "datetime-timezones", q || ""];
        dtTzProc.running = false; dtTzProc.running = true;
    }
    function setDateTimeNtp(on) { root.sysMsg = "Updating NTP…"; root.runSysAction(["datetime-set-ntp", on ? "true" : "false"], "datetime") }
    function setTimeZone(tz) { root.sysMsg = "Setting timezone…"; root.runSysAction(["datetime-set-tz", tz], "datetime") }
    function refreshLocale() { localeGetProc.running = false; localeGetProc.running = true }
    function setSystemLocale(lang) { root.sysMsg = "Updating locale…"; root.runSysAction(["locale-set", lang], "locale") }
    function setHostname(name) { if (!name) return; root.sysMsg = "Updating hostname…"; root.runSysAction(["hostname-set", name], "host") }
    function refreshStartup() { startupGetProc.running = false; startupGetProc.running = true }
    function startupToggleApp(id, on) { root.runSysAction(["startup-toggle-app", id, on ? "true" : "false"], "startup") }
    function startupAddApp(id) { root.runSysAction(["startup-add-app", id], "startup") }
    function startupRemoveApp(id) { root.runSysAction(["startup-remove-app", id], "startup") }
    function startupServiceAction(unit, act) { root.runSysAction(["startup-service", unit, act], "startup") }
    function refreshNetExtra() { netExtraProc.running = false; netExtraProc.running = true }
    function setNetworkDns(con, preset) { root.sysMsg = "Applying DNS…"; root.runSysAction(["network-set-dns", con, preset], "net") }
    function refreshPrivacy() { privGetProc.running = false; privGetProc.running = true }
    function setFirewall(enable) { root.privBusy = true; root.sysMsg = "Requesting authorization…"; root.runSysAction(["privacy-firewall", enable ? "enable" : "disable"], "privacy") }
    function clearClipboardHistory() { root.runSysAction(["privacy-clear-clipboard"], "privacy") }
    function refreshCompositor() { compGetProc.running = false; compGetProc.running = true }
    function setCompositor(patch) {
        var merged = Object.assign({}, root.compCfg, patch);
        root.compCfg = merged;
        var b64 = Qt.btoa(JSON.stringify(patch));
        root.runSysAction(["compositor-set", b64], "");
    }
    function refreshSystemInfo() { sysProc.running = false; sysProc.running = true; diskProc.running = false; diskProc.running = true }
    function refreshBackups() { bkListProc.running = false; bkListProc.running = true }
    function runHealthCheck() { docProc.running = false; docProc.running = true }

    // ---- default applications -------------------------------------------------
    // WHICH PROGRAM OPENS WHAT is a system-wide setting, not a shell one: it lives
    // in mimeapps.list and every toolkit on the machine reads it. sea-defaults.py
    // owns the writing (through xdg-mime, which knows the file's precedence rules)
    // and this page only asks and shows. The terminal is the exception -- nothing
    // in the spec says which terminal is yours -- and is kept in the shell's own
    // defaults.json, which is why it is marked as not standard below.
    property var defRoles: []
    property var defCands: ({})
    property string defBusy: ""             // the role currently being written
    property string defError: ""
    property string defOpen: ""             // the role whose choices are expanded
    readonly property string defScript: Qt.resolvedUrl("sea-defaults.py").toString().replace("file://","")

    function defRefresh() { defProc.command = ["python3", root.defScript, "--all"]; defProc.running = false; defProc.running = true }
    function defSet(role, id) {
        root.defBusy = role; root.defError = "";
        defSetProc.command = ["python3", root.defScript, "--set", role, id];
        defSetProc.running = false; defSetProc.running = true;
    }
    Process {
        id: defProc
        stdout: StdioCollector { id: defOut; onStreamFinished: {
            try {
                var d = JSON.parse(defOut.text);
                root.defRoles = d.roles || [];
                root.defCands = d.candidates || ({});
            } catch (e) { root.defError = "Could not read the application list" }
        } }
    }
    Process {
        id: defSetProc
        stdout: StdioCollector { id: defSetOut; onStreamFinished: {
            root.defBusy = "";
            try {
                var d = JSON.parse(defSetOut.text);
                if (!d.ok) root.defError = d.error || "It refused the change";
            } catch (e) { root.defError = "It gave no answer" }
            root.defRefresh();          // read back what actually took, not what we asked for
        } }
    }
    property string navQuery: ""
    // Matches on the section name AND on the page it lives on, so "bar menu" finds the
    // global menu the same way "global" does, and a page name alone lists that page.
    readonly property var navHits: {
        var q = root.navQuery.toLowerCase().trim();
        if (q.length === 0) return [];
        var terms = q.split(/\s+/), out = [];
        for (var i = 0; i < searchIndex.sections.length; i++) {
            var e = searchIndex.sections[i];
            var par = root.tabParent(e.tab);
            var hay = (e.title + " " + root.tabLabel(e.tab) + (par >= 0 ? " " + root.tabLabel(par) : "")).toLowerCase();
            var ok = true;
            for (var t = 0; t < terms.length; t++)
                if (hay.indexOf(terms[t]) < 0) { ok = false; break }
            if (!ok) continue;
            out.push({ "e": e, "rank": e.title.toLowerCase().indexOf(terms[0]) === 0 ? 0
                              : (e.title.toLowerCase().indexOf(terms[0]) >= 0 ? 1
                              : (root.tabLabel(e.tab).toLowerCase().indexOf(terms[0]) >= 0 ? 2 : 3)) });
            if (out.length > 60) break;
        }
        out.sort(function (a, b) { return a.rank - b.rank });
        return out.map(function (o) { return o.e });
    }
    // The sections of the page being looked at, for the jump chips.
    readonly property var pageSections: {
        var currentAppearanceTab = root.apSubTab;
        var _ = root.sectionTick;               // recompute when the registry settles
        if (!root.sectionsReady) return [];
        var out = [];
        for (var i = 0; i < root.sectionIndex.length; i++)
            if (root.sectionIndex[i].tab === root.tab) {
                var ancestor = root.sectionIndex[i].item;
                var matches = true;
                while (ancestor) {
                    if (root.tab === 4 && typeof ancestor.appearanceSubTab !== "undefined") {
                        matches = ancestor.appearanceSubTab === currentAppearanceTab;
                        break;
                    }
                    ancestor = ancestor.parent;
                }
                if (matches) out.push(root.sectionIndex[i]);
            }
        // IN PAGE ORDER. Sections complete bottom-up, so the registry holds them backwards
        // and the chips read the page from the end. Once the page is laid out the sections'
        // own positions are the truth — and they are laid out, because chips are only drawn
        // for the page being looked at. mapToItem, not `y`: a section nested one column
        // deeper measures its y against that column, not the page.
        try {
            var ys = out.map(function (e) { return e.item.mapToItem(pane, 0, 0).y });
            var spread = false;
            for (var k = 1; k < ys.length; k++) if (ys[k] !== ys[0]) { spread = true; break }
            if (spread) {
                var pack = out.map(function (e, n) { return { e: e, y: ys[n] } });
                pack.sort(function (a, b) { return a.y - b.y });
                out = pack.map(function (o) { return o.e });
            } else {
                out.reverse();          // not laid out yet; the reversal is exactly right
            }
        } catch (err) { out.reverse() }
        return out;
    }

    // Switching page and scrolling to a section are two different frames: the page is not
    // laid out until after it is made visible, so its sections have no position yet. Hence
    // the deferral rather than one call.
    property var pendingJump: null
    function jumpTo(entry) {
        if (!entry) return;
        if (root.tab !== entry.tab) root.showTab(entry.tab);
        // A search hit only names its section. The page exists now, so the section does too.
        var target = entry.item;
        for (var i = 0; !target && i < root.sectionIndex.length; i++) {
            var known = root.sectionIndex[i];
            if (known.tab === entry.tab && known.title === entry.title) target = known.item;
        }
        if (entry.tab === 4) {
            var ancestor = target;
            while (ancestor) {
                if (typeof ancestor.appearanceSubTab !== "undefined") {
                    root.apSubTab = ancestor.appearanceSubTab;
                    break;
                }
                ancestor = ancestor.parent;
            }
        }
        root.pendingJump = target;
        jumpTimer.restart();
    }
    // A search is done once it has taken you somewhere: the field empties and lets go of the
    // keyboard, so the sidebar shows the pages again (and Escape closes the panel again).
    function jumpFromSearch(entry) {
        root.jumpTo(entry);
        navIn.text = "";
        navIn.focus = false;
    }
    function doJump() {
        var it = root.pendingJump;
        if (!it) return;
        try {
            var y = it.mapToItem(pane, 0, 0).y;
            var max = Math.max(0, contentFlick.contentHeight - contentFlick.height);
            contentFlick.contentY = Math.max(0, Math.min(y - 10, max));
        } catch (e) {}
    }
    Timer { id: jumpTimer; interval: 16; repeat: true; property int n: 0
        onRunningChanged: if (running) n = 0
        // Runs a few frames: the first pass lands before the new page has finished laying
        // out and would scroll to the wrong offset on a page that grows as it settles.
        onTriggered: { root.doJump(); n++; if (n > 5) { stop(); root.pendingJump = null } } }

    // A warm window whose output went away (lid shut, monitor unplugged) is closed by the
    // compositor and hidden by Quickshell for good; moving it to another screen alone leaves it
    // hidden. So open() takes the active output (where the cursor is) and, whenever the window is
    // not alive there, rebuilds it: hide, move, show again.
    property bool screensMoved: false
    Connections { target: Quickshell; function onScreensChanged() { root.screensMoved = true } }
    function placeOn(w) {
        var f = Hyprland.focusedMonitor, s = Quickshell.screens, t = null;
        for (var i = 0; f && i < s.length; i++) if (s[i].name === f.name) t = s[i];
        if (!t && s.length) t = s[0];
        if (t && (t !== w.screen || root.screensMoved || !w.backingWindowVisible || !w.visible)) {
            w.visible = false;
            w.screen = t;
            w.visible = Qt.binding(() => !root.authenticationPending);
        }
        root.screensMoved = false;
    }
    function showTab(t) {
        // on the active output each time; the warm surface otherwise stays on its first one
        root.placeOn(panel);

        // Not fresh until the read below lands. Everything this panel mirrors is stale between
        // here and there, and one of those mirrors drives the WHOLE SHELL's palette.
        root.apFresh = false;
        apReadProc.running = true;                  // pick up appearance changes made while closed
        root.tab = t;
        tabRefresh.restart();
        root.shown = true;
    }
    Timer { id: tabRefresh; interval: 80; onTriggered: root.refreshTab(root.tab) }
    function refreshTab(t) {
        root.sysMsg = "";
        if (t === 0) root.audioRefresh()
        if (t === 1) { root.reloadMonitors(); root.reloadDisplayProfiles(); panelGet.running = true }
        if (t === 2) { root.rescanWifi(); root.refreshNetExtra() }
        if (t === 14) root.reloadKde()
        if (t === 7) { kbProc.running = true; root.refreshCompositor() }
        if (t === 17) { wrRead.running = true; wrClsProc.running = true }
        if (t === 15) gsRead.running = true
        if (t === 18) { usageReadProc.running = true; ulimReadProc.running = true }
        if (t === 8) { sysProc.running = true; bkListProc.running = true; diskProc.running = true; root.refreshDateTime(); root.refreshLocale(); root.refreshStartup() }
        if (t === 19) { diskProc.running = true; diskScan.open() }
        if (t === 10) { idleChk.running = true; lockSettingsGet.running = true; if (root.lockEditor) root.lockEditor.reload() }
        if (t === 23 && root.userEditor) root.userEditor.reload()
        if (t === 6) { ppGet.running = true; lockSettingsGet.running = true; battProc.running = true }
        if (t === 11) { reloadEventsProc.running = true; calCfgLoad.running = true }
        if (t === 26 || t === 35) root.refreshCompositor()
        if (t === 27) root.refreshPrivacy()
        if (t === 28) { sysProc.running = true; root.refreshNetExtra() }
        if (t === 30) root.refreshStartup()
        if (t === 31) root.refreshDateTime()
        if (t === 32) root.refreshLocale()
        if (t === 33) root.refreshBackups()
    }
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }
    property string appearanceSaveState: "Changes save automatically"
    property bool appearanceSaveFailed: false
    property string pendingAppearancePayload: ""
    property var appearancePostSaveAction: null
    function afterAppearanceSave(action) {
        if (appearanceWriter.running || root.pendingAppearancePayload.length) root.appearancePostSaveAction = action;
        else action();
    }
    readonly property string appearanceSaveScript: Qt.resolvedUrl("sea-save-appearance.py").toString().replace("file://", "")
    function queueAppearanceSave(jsonText) {
        // Escape non-ASCII before btoa so fonts and paths survive UTF-8 decoding.
        var ascii = jsonText.replace(/[\u007f-\uffff]/g, function(c) {
            return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4);
        });
        root.pendingAppearancePayload = Qt.btoa(ascii);
        root.appearanceSaveFailed = false;
        root.appearanceSaveState = "Saving…";
        root.flushAppearanceSave();
    }
    function flushAppearanceSave() {
        if (appearanceWriter.running || !root.pendingAppearancePayload.length) return;
        appearanceWriter.command = ["python3", root.appearanceSaveScript, root.pendingAppearancePayload];
        root.pendingAppearancePayload = "";
        appearanceWriter.running = true;
    }
    Process {
        id: appearanceWriter
        onExited: (exitCode, exitStatus) => {
            root.appearanceSaveFailed = exitCode !== 0;
            root.appearanceSaveState = exitCode === 0 ? "Appearance saved" : "Could not save · try again";
            if (root.pendingAppearancePayload.length) Qt.callLater(root.flushAppearanceSave);
            else if (exitCode === 0 && root.appearancePostSaveAction) {
                var action = root.appearancePostSaveAction;
                root.appearancePostSaveAction = null;
                action();
            } else if (exitCode !== 0) root.appearancePostSaveAction = null;
        }
    }
    property bool apFolderColorFollow: false
    property string apIconTheme: "breeze"
    property var installedIconThemes: []
    property var iconPreviewCatalog: []
    readonly property string iconThemeScript: Qt.resolvedUrl("sea-icons.py").toString().replace("file://", "")
    Process {
        command: ["python3", root.iconThemeScript, "--catalog"]
        running: true
        stdout: StdioCollector { onStreamFinished: {
            try { root.iconPreviewCatalog = JSON.parse(text); root.installedIconThemes = root.iconPreviewCatalog.map(function(e) { return e.name; }); } catch (e) {}
        } }
    }
    property string iconApplyState: ""
    property bool iconApplyFailed: false
    property string pendingIconTheme: ""
    property string pendingIconMode: "light"
    function startIconApply() {
        if (iconApplier.running || !root.pendingIconTheme.length) return;
        iconApplier.command = ["python3", root.iconThemeScript, "--theme", root.pendingIconTheme, "--mode", root.pendingIconMode];
        root.pendingIconTheme = "";
        iconApplier.running = true;
    }
    Process {
        id: iconApplier
        onExited: (exitCode, exitStatus) => {
            root.iconApplyFailed = exitCode !== 0;
            root.iconApplyState = exitCode === 0 ? "Icon settings saved · reopen apps to refresh" : "Icon update failed · try again";
            if (root.pendingIconTheme.length) Qt.callLater(root.startIconApply);
        }
    }
    function applyIconTheme(name) {
        root.apIconTheme = name;
        root.saveAppearance();
        root.pendingIconTheme = name;
        root.pendingIconMode = root.apLight ? "light" : "dark";
        root.iconApplyState = "Updating icon settings…";
        root.iconApplyFailed = false;
        root.startIconApply();
    }


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
        // READ ONLY ONCE THE LOAD HAS LANDED. This used to call reload() and then text() in
        // one breath, but reload() finishes later, so text() could hand back the file as it
        // was BEFORE the change: what was shown lagged one change behind, and removing the
        // last widget could leave it on screen until something else changed.
        function apply() {
            try {
                var t = text();
                var j = (t && t.trim()) ? JSON.parse(t) : null;
                root.dtItems = (j && j.items) ? j.items : [];
                var a = (j && j.autoArrange !== undefined) ? j.autoArrange : "rescue";
                root.dtAuto = (a === true) ? "rescue" : (a === false) ? "off" : ("" + a);
            } catch (e) { root.dtItems = [] }
        }
        onFileChanged: reload()
        onLoaded: apply()
        Component.onCompleted: reload()
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
    onTabChanged: {
        if (tab !== 8 && root.tabMeta[tab])
            root.recentPages = [tab].concat(root.recentPages.filter(function(t) { return t !== root.tab })).slice(0, 5);
        if (!root.navMoving && root.navLast !== tab) { root.navBack = root.navBack.concat([root.navLast]).slice(-30); root.navFwd = [] }
        root.navLast = tab;
        if (root.pendingJump === null) contentFlick.contentY = 0;
        if (root.shown) pageArrival.restart();
        tabRefresh.restart();
        if (tab === 22 && root.defRoles.length === 0) root.defRefresh();
    }

    // SUPER+S is handled by shell.qml (target "settings") so this file can be unloaded
    // while it is closed. A second handler for the same target would replace that one.

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
            var matches = filter.match(/\*\.[a-zA-Z0-9]+/g);
            if (matches) ext = matches.map(function(m) { return m.slice(1).toLowerCase() }).join("|");
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
        command: ["python3", Qt.resolvedUrl("sea-keybinds.py").toString().replace("file://",""), "--list"]
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
                    // The ACTION comes through as well now, not just the keys. `exec` is
                    // singled out because its argument is a plain command string that can
                    // be edited safely; every other dispatcher is a structured lua call
                    // and is shown read-only rather than handed to a text box.
                    var isExec = b.sourceCommand !== null && b.sourceCommand !== undefined;
                    out.push({ keys: keys, desc: desc, key: b.key, mods: mods, canEdit: !!b.sourceId, sourceId: b.sourceId || "",
                               dispatcher: b.dispatcher || "", arg: isExec ? b.sourceCommand : (b.dispatcher || ""), isExec: isExec });
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
            if (b.sourceId === root.kbRec.sourceId) continue;
            if (b.mods.join(" ") === combo && b.key.toLowerCase() === base.toLowerCase()) {
                root.kbConflict = "already used by “" + b.desc + "”"; return }
        }
        // Only send a command when it is an exec bind AND the text actually changed —
        // sending the unchanged one would rewrite a hand-written lua expression (a
        // variable, a multi-line call) into a plain string for no reason.
        var cmd = (root.kbRec.isExec && root.kbRecAction.trim() !== ""
                   && root.kbRecAction !== root.kbRec.arg) ? root.kbRecAction.trim() : "";
        var args = ["--edit",root.kbRec.sourceId,combo,base];
        if (cmd !== "") args.push(cmd);
        root.kbMutate(args);
    }
    property bool kbDeleteArmed: false
    function kbMutate(args) {
        if (kbWriter.running) return;
        root.kbConflict = "Saving…";
        kbWriter.command = ["python3", Qt.resolvedUrl("sea-keybinds.py").toString().replace("file://","")].concat(args);
        kbWriter.running = true;
    }
    Process {
        id: kbWriter
        stderr: StdioCollector { id: kbWriteError }
        onExited: code => {
            if (code === 0) { root.kbCloseEditor(); kbRefetch.restart() }
            else root.kbConflict = kbWriteError.text.trim() || "Could not save shortcut";
        }
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
    property string kbRecAction: ""
    function kbOpenEdit(bind) {
        root.kbAdding = false; root.kbDeleteArmed = false;
        root.kbRec = bind; root.kbRecMods = bind.mods.slice(); root.kbRecKey = bind.key;
        root.kbRecAction = bind.arg || "";
        root.kbRecRecording = false; root.kbConflict = "";
    }
    function kbOpenAdd() {
        root.kbRec = null; root.kbConflict = "";
        root.kbAdding = true; root.kbAddRecording = false;
        root.kbAddDesc = ""; root.kbAddAction = "exec, "; root.kbAddKey = ""; root.kbAddMods = ["SUPER"];
    }
    function kbCloseEditor() {
        root.kbRec = null; root.kbAdding = false; root.kbRecAction = "";
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
    // "Alder Lake PCH-P High Definition Audio Controller HDMI / DisplayPort 3 Output (Stereo)" says
    // what the part is called and buries what it is. The port first, the chip only as a footnote.
    function deviceName(raw) {
        var s = ("" + raw).replace(/\s*\((Stereo|Mono)\)$/, "").replace(/\s+(Analog|Digital) Stereo(\s*\(HDMI\))?$/, function (m, a, h) { return h ? " HDMI" : "" });
        var m = s.match(/^(.*?)\s*High Definition Audio Controller\s*(.*)$/);
        if (!m) return { name: s, chip: "" };
        return { name: (m[2] || "Audio").replace(/\s+Output$/, ""), chip: m[1] };
    }
    // Flat rows for the device tables. Pipewire nodes are live objects with derived names and
    // per-node format lookups, so — as with Bluetooth — the object rides along in `_node` and
    // the table only ever renders plain values.
    readonly property var sinkRows: root.sinks.map(function (n) {
        var d = root.deviceName(root.nodeName(n));
        return { name: d.name, chip: d.chip, format: root.audioFmtBadge(n.name),
                 rate: root.audioMaxRate(n.name), _node: n };
    })
    readonly property var sourceRows: root.sources.map(function (n) {
        var d = root.deviceName(root.nodeName(n));
        return { name: d.name, chip: d.chip, _node: n };
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
    property string wxUnit: "m"   // m = °C metric · u = °F "Freedom units"
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
    property var offMonitors: []      // connected but switched off: [{name, desc, laptop}]
    property string selRes: ""        // "1920x1080"
    property string selHz: ""         // "165.00"
    property int selTransform: 0      // 0 landscape · 1 portrait · 2 landscape-flipped · 3 portrait-flipped
    readonly property var curMon: (root.monitors.length > root.monSel) ? root.monitors[root.monSel] : null
    Process {
        id: monProc; running: true
        // "all": a switched-off display (the laptop screen with an external one plugged in) is
        // still listed below the table, so it doesn't just vanish from Settings
        command: ["sh", "-c", "hyprctl -j monitors all"]
        stdout: StdioCollector { id: monOut; onStreamFinished: {
            try {
                var arr = JSON.parse(monOut.text); var out = [], off = [];
                for (var i=0;i<arr.length;i++) { var m=arr[i];
                    if (m.disabled) { off.push({ name: m.name, desc: (m.description || m.name), laptop: /^(eDP|LVDS|DSI)/.test(m.name) }); continue }
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
                root.offMonitors = off;
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
            + "&& notify-send 'sea-shell' 'Display: " + root.selRes + "@" + root.selHz + "Hz'"
            // hyprctl only changes the running session — write it to monitors.lua so it survives a reboot
            + "; sleep 1; python3 '" + root._displayScript + "' --persist");
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
        Quickshell.execDetached(["sh", "-c", "python3 '" + root._displayScript + "' --apply '" + ("" + name).replace(/'/g, "") + "' && notify-send 'sea-shell' 'Layout → " + ("" + name).replace(/'/g, "") + "'"
            + "; sleep 1; python3 '" + root._displayScript + "' --persist"]);
        monRefresh.start();
    }
    function deleteDisplayProfile(name) {
        Quickshell.execDetached(["python3", root._displayScript, "--delete", "" + name]);
        dispProfRefresh.restart();
    }

    // ---------- laptop screen (sea-panel.sh → Rust binary or sea-panel.py) ----------
    readonly property string _panelScript: Qt.resolvedUrl("sea-panel.sh").toString().replace("file://", "")
    property bool panelLaptop: false           // this machine has a built-in panel at all
    property bool panelExternalOnly: false
    property bool panelLidOff: true
    Process { id: panelGet; command: ["sh", root._panelScript, "--get"]
        stdout: StdioCollector { id: panelOut
            onStreamFinished: { try { var j = JSON.parse(panelOut.text.trim() || "{}");
                root.panelLaptop = !!j.laptop; root.panelExternalOnly = !!j.external_only; root.panelLidOff = !!j.lid_off } catch (e) {} } } }
    function setPanel(key, on) {
        Quickshell.execDetached(["sh", root._panelScript, "--set", key, on ? "1" : "0"]);
        monRefresh.start();
    }

    // ---------- appearance (shared with the bar via ~/.config/sea-shell/appearance.json) ----------
    property real apRadius: 14
    property real apOpacity: 0.80
    property string apGlass: "frosted"      // Tok glass: solid | frosted | clear
    property bool apReducedMotion: false
    property bool apDisplaySetups: true     // sea-setups.py: one arrangement per set of displays
    property bool apBarOpaque: true
    property int  apHeight: 42
    property real apScale: 0                 // UI scale: 0 = auto (per-monitor), >0 = manual multiplier
    // effective scale used for the live preview + the settings window itself (mirrors shell.qml)
    function autoScaleEstimate() {
        var h = 0, s = Quickshell.screens;
        for (var i = 0; i < s.length; i++) if (s[i] && s[i].height > h) h = s[i].height;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    // effective scale on one screen — same precedence as shell.qml uiFor(): per-monitor override,
    // then the global multiplier, then auto from that screen's own height
    function uiScaleFor(scr) {
        var mo = (scr && scr.name) ? root.monScaleAp(scr.name) : 0;
        if (mo > 0) return mo;
        if (root.apScale > 0) return root.apScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 0) return root.autoScaleEstimate();
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
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
    // optional pictures stuck on the power menu and the media dropdown; none unless chosen
    property string apStickerPower: ""
    property string apStickerMedia: ""
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
    property bool apHideGaming: false        // hide the bar during game mode / active game window
    property bool apSuspendShellGaming: false // stop seashell + wallpaper/clipboard daemons during game mode
    property bool apAutoPowerBattery: false   // auto power-saver + 60Hz on battery, restore on AC
    property bool apNight: false             // night light on/off (manual)
    property int  apNightTemp: 4000          // night-light colour temperature (K)
    property bool apNightAuto: false         // night light follows dark mode
    // drag-reorderable order of the bar widgets (mirrors shell.qml cfgWidgetOrder)
    // MUST match shell.qml's defaultWidgetOrder — it is the same bar. This copy had drifted:
    // wgUpdates and wgNet appeared twice (so the reorder list showed two identical rows, and
    // dragging either wrote a duplicate into the saved order) and one widget was missing.
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgAi","wgGithub","wgTotem","wgUpdates","wgNet","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgMic","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
    property var apWidgetOrder: root.defaultWidgetOrder
    // left cluster order (mirrors shell.qml cfgLeftOrder)
    readonly property var defaultLeftOrder: ["lgLogo","lgWork","lgScratch","lgTitle"]
    property var apLeftOrder: root.defaultLeftOrder
    readonly property var lgMeta: ({
        lgLogo:  { i: "water",  l: "Logo",         d: "The sea-shell mark — click opens the launcher" },
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
        wgAi:        { i: "auto_awesome",          l: "AI usage",          d: "Allowance left · Claude, GPT, Cursor/Grok, Gemini", prop: "wgAi" },
        wgGithub:    { i: "commit",                l: "GitHub",            d: "Commits today, streak, and watched-repo CI", prop: "wgGithub" },
        wgTotem:     { i: "password",              l: "Totem",             d: "2FA codes from your phone (Totem)",          prop: "wgTotem" },
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
    // ONE HANDLER, because an object may only assign a given signal once — a second
    // `Component.onCompleted` further down does not add to this one, it makes the whole
    // file fail to load with "Property value set multiple times", and the panel then never
    // exists at all. Its IPC target vanishing is the only symptom you get.
    Component.onCompleted: { root.wgSyncModel(); root.lgSyncModel(); root.rescanWallpapers();
                             gmSetupCheck.running = true }
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
    // "smart" is the default because it is the only one that LOOKS at the picture
    // before deciding: matugen measures the image's colourfulness (Hasler-Suesstrunk)
    // and picks monochrome, neutral, tonal-spot or vibrant to match. The rest apply
    // one algorithm to everything, which is why a black-and-white wallpaper under
    // tonal-spot comes back blue -- Material's scorer hands out a default hue when
    // it cannot find one in the image.
    property string apScheme: "scheme-smart"        // matugen colour-scheme algorithm
    readonly property var schemes: ["scheme-smart","scheme-tonal-spot","scheme-vibrant","scheme-content","scheme-neutral","scheme-expressive","scheme-fidelity","scheme-monochrome","scheme-rainbow","scheme-fruit-salad"]
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

    Attention { id: attention }
    SettingsIndex { id: searchIndex }
    // A page costs nothing until it is first opened, then stays: most sessions touch two or three
    // of the 26, and building them all up front was most of what Settings kept in memory. Search
    // can't see unbuilt pages, so it reads SettingsIndex instead. Building them on the first search
    // was tried and cost more memory than the old single file.
    component PageLoader: Loader {
        id: pageLoader
        property int page: -1
        readonly property bool wanted: root.tab === page
        Layout.fillWidth: true
        visible: wanted
        active: false
        onWantedChanged: if (wanted) active = true
        Component.onCompleted: if (wanted) active = true
    }

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

    // ---------- the global menu ----------
    // Its own config file rather than a corner of appearance.json, because the SIDECAR reads
    // it too: sea-appmenu.py re-reads ~/.config/sea-shell/appmenu.json on every pass, so
    // "read menus in the background" takes effect without restarting the bar.
    property bool gmEnabled: true
    property bool gmPrime: false
    property bool gmAccel: true
    property string gmDoctor: ""
    property bool gmDoctorBusy: false
    readonly property string gmScript: Qt.resolvedUrl("sea-appmenu.py").toString().replace("file://","")
    // WATCHED, NOT READ ONCE. This panel is resident — it is built when the bar starts and
    // lives for the whole session — so a single `cat` at startup meant its idea of the
    // settings was frozen at login. Right-click the bar to hide the strip and this still
    // believed it was on; the next click of the toggle then "turned it off" a second time,
    // wrote the value that was already on disk, and nothing happened. That is the bug that
    // looked like the switch being dead.
    FileView {
        id: gmCfg
        path: Quickshell.env("HOME") + "/.config/sea-shell/appmenu.json"
        watchChanges: true
        function apply(refresh) {
            try {
                if (refresh !== false) reload();
                var t = text();
                if (!t || !t.trim()) return;
                var j = JSON.parse(t);
                if (j.enabled !== undefined) root.gmEnabled = !!j.enabled;
                if (j.prime !== undefined) root.gmPrime = !!j.prime;
                if (j.accelerators !== undefined) root.gmAccel = !!j.accelerators;
            } catch (e) {}
        }
        onFileChanged: apply()
        onLoaded: apply(false)
        Component.onCompleted: apply()
    }
    function gmSave() {
        var j = { enabled: root.gmEnabled, prime: root.gmPrime, accelerators: root.gmAccel };
        var b64 = Qt.btoa(JSON.stringify(j));
        run("d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; echo '" + b64
            + "' | base64 -d > \"$d/.appmenu.tmp\" && mv -f \"$d/.appmenu.tmp\" \"$d/appmenu.json\"");
    }
    // "why has this window no menu?" answered for every open window at once. Worth a button
    // because the answer is usually actionable (an Electron app needs a launch flag) and is
    // otherwise invisible — the bar's only way of saying it is to show nothing at all.
    Process { id: gmDoc
        command: ["python3", root.gmScript, "--doctor"]
        onExited: root.gmDoctorBusy = false
        stdout: StdioCollector { id: gmDocOut; onStreamFinished: {
            root.gmDoctor = (gmDocOut.text || "").trim() || "no windows to look at";
        } } }
    function gmRunDoctor() { root.gmDoctor = ""; root.gmDoctorBusy = true; gmDoc.running = true }

    // ---- per-app setup ----
    // Each toolkit needs something different before it will publish a menu, and the
    // sidecar is the thing that knows what — so this asks rather than duplicating the
    // knowledge. --setup only ever REPORTS; nothing is written until --apply.
    property var gmApps: []
    property bool gmSetupBusy: false
    readonly property int gmNeeds: {
        var n = 0;
        for (var i = 0; i < root.gmApps.length; i++) if (!root.gmApps[i].ok) n++;
        return n;
    }
    Process { id: gmSetupCheck
        command: ["python3", root.gmScript, "--setup"]
        stdout: StdioCollector { id: gmSetupOut; onStreamFinished: {
            try { root.gmApps = (JSON.parse(gmSetupOut.text || "{}").apps) || []; }
            catch (e) { root.gmApps = [] }
        } } }
    Process { id: gmSetupApply
        command: ["python3", root.gmScript, "--setup", "--apply"]
        onExited: { root.gmSetupBusy = false; gmSetupCheck.running = true }
    }
    function gmSetupRefresh() { gmSetupCheck.running = true }
    function gmSetupAll() { root.gmSetupBusy = true; gmSetupApply.running = true }

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
    DiskScan { id: diskScan; active: root.shown && root.tab === 19; onCleaned: diskProc.running = true }
    // Every place this partition is mounted, root first. A btrfs partition is mounted once per
    // subvolume, and lsblk's single MOUNTPOINT is just whichever came up first (here /var/tmp),
    // which hid "/" from everything that looks for it.
    function diskMounts(n) {
        var all = (n.mountpoints || []).filter(function (m) { return !!m && m !== "[SWAP]" });
        if (all.length === 0 && n.mountpoint) all = [n.mountpoint];
        return all.sort(function (a, b) { return a.length - b.length || (a < b ? -1 : 1) });
    }
    Process {
        id: diskProc
        // FSUSED/FSAVAIL/FSUSE% are only populated for MOUNTED filesystems — an unmounted
        // partition genuinely has no knowable usage without mounting it, so the UI shows a
        // dash there rather than implying 0%.
        command: ["sh","-c","lsblk -J -o NAME,SIZE,FSTYPE,MOUNTPOINT,MOUNTPOINTS,RM,TYPE,LABEL,PATH,TRAN,MODEL,VENDOR,FSSIZE,FSUSED,FSAVAIL,FSUSE% 2>/dev/null"]
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
                                var mnts = root.diskMounts(n);
                                var mnt = mnts.length ? mnts[0] : "";
                                var pth = n.path || ("/dev/" + n.name);
                                var sys = mnts.some(function (m) { return m === "/" || m === "/boot" || m.indexOf("/boot/") === 0 });
                                if (mnt) mountedPaths.push(pth);
                                var pctRaw = n["fsuse%"] ? parseInt(("" + n["fsuse%"]).replace("%","")) : -1;
                                dParts.push({
                                    dev: pth.replace("/dev/", ""),
                                    label: n.label || "",
                                    size: n.size || "",
                                    fs: n.fstype,
                                    mount: mnt,
                                    mounts: mnts.join(", "),
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
            root.diskMsg = row && row._system ? "System partitions stay mounted" : "";
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
    // A paused player still holds its decoder and its frames. Freeing it is
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
    // The frame rate the bar re-encodes moving wallpapers to; 0 (unset) means 30.
    property int    apWpVidFps: 0
    readonly property var wpVidFpsOptions: [30, 60, 24]
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
    property bool apClock24: true
    property bool apClockSeconds: false
    property bool wgPower: true
    property bool wgQuick: true
    property bool wgAi: true
    property bool wgGithub: true
    property bool wgTotem: true
    property var apAiOn: ({ "claude": true, "codex": true, "cursor": true, "cursor-alt": true, "gemini": true })
    property string apAiDefault: ""
    property int apAiDigits: 2
    // What resting the pointer in each screen corner does. "" is nothing.
    property var apHotCorners: ({ "tl": "", "tr": "", "bl": "", "br": "" })
    function hotCornerSet(corner, action) {
        var o = {};
        for (var k in root.apHotCorners) o[k] = root.apHotCorners[k];
        o[corner] = action;
        root.apHotCorners = o;
        root.saveAppearance();
    }
    readonly property var aiPlanIds: ["claude", "codex", "cursor", "cursor-alt", "gemini"]
    function aiPlanKnown(id) { return id === "" || root.aiPlanIds.indexOf(id) >= 0; }
    // A second Cursor profile, signed in from its own user-data dir.
    property bool apHasCursorAlt: false
    Process {
        running: true
        command: ["sh", "-c", "test -d \"$HOME/.cursor-alt/data\" -o -s \"$HOME/.config/sea-shell/cursor-profiles\" && echo yes"]
        stdout: StdioCollector { onStreamFinished: root.apHasCursorAlt = text.trim() === "yes" }
    }
    function aiDigitsSet(n) {
        if (n !== 0 && n !== 1 && n !== 2) return;
        root.apAiDigits = n;
        root.saveAppearance();
    }
    function aiOnGet(id) {
        var o = root.apAiOn || ({});
        return o[id] !== false;
    }
    function aiOnToggle(id) {
        var ids = root.aiPlanIds;
        var o = {};
        for (var k = 0; k < ids.length; k++) o[ids[k]] = root.aiOnGet(ids[k]);
        var leaving = o[id] !== false;
        if (leaving) {
            var n = 0;
            for (var i = 0; i < ids.length; i++) if (ids[i] !== id && o[ids[i]]) n++;
            if (n === 0) return;
        }
        o[id] = !o[id];
        root.apAiOn = o;
        if (!o[id] && root.apAiDefault === id) root.apAiDefault = "";
        root.saveAppearance();
    }
    function aiDefaultSet(id) {
        root.apAiDefault = (root.apAiDefault === id) ? "" : id;
        root.saveAppearance();
    }
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
            root.apReducedMotion=!!j.reducedMotion;
            root.apDisplaySetups = j.displaySetups !== false;
            root.apGlass = (j.glass === "solid" || j.glass === "clear") ? j.glass : "frosted";
            if(j.barOpaque!==undefined) root.apBarOpaque=!!j.barOpaque;
            if(j.radius!==undefined) root.apRadius=j.radius; if(j.opacity!==undefined) root.apOpacity=j.opacity;
            if(j.height!==undefined) root.apHeight=j.height; if(j.scale!==undefined) root.apScale=j.scale; if(j.accent!==undefined) root.apAccent=j.accent;
            if(j.folderColorFollow!==undefined) root.apFolderColorFollow=j.folderColorFollow;
            if(j.iconTheme!==undefined) root.apIconTheme=j.iconTheme; if(j.font!==undefined) root.apFont=j.font; if(j.customFonts!==undefined) root.apCustomFonts=j.customFonts;
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
            if(j.clock24!==undefined) root.apClock24=!!j.clock24;
            if(j.clockSeconds!==undefined) root.apClockSeconds=!!j.clockSeconds;
            if(j.wgPower!==undefined) root.wgPower=!!j.wgPower;
            if(j.wgQuick!==undefined) root.wgQuick=!!j.wgQuick;
            if(j.wgAi!==undefined) root.wgAi=!!j.wgAi;
            if(j.wgGithub!==undefined) root.wgGithub=!!j.wgGithub;
            if(j.wgTotem!==undefined) root.wgTotem=!!j.wgTotem;
            if(j.aiOn && typeof j.aiOn==="object") root.apAiOn=j.aiOn;
            if(typeof j.aiDefault==="string" && root.aiPlanKnown(j.aiDefault)) root.apAiDefault=j.aiDefault;
            if(j.aiDigits===0||j.aiDigits===1||j.aiDigits===2) root.apAiDigits=j.aiDigits;
            if(j.wgNight!==undefined) root.wgNight=!!j.wgNight;
            if(j.wgMic!==undefined) root.wgMic=!!j.wgMic;
            if(j.hotCorners && typeof j.hotCorners==="object") root.apHotCorners=j.hotCorners;
            if(j.sysShow!==undefined && Array.isArray(j.sysShow) && j.sysShow.length) root.apSysShow=j.sysShow;
            if(j.barShape==="bar"||j.barShape==="pills") root.apBarShape=j.barShape;
            if(j.wsStyle==="grow"||j.wsStyle==="pill"||j.wsStyle==="circle") root.apWsStyle=j.wsStyle;
            if(j.wsLabel!==undefined && (""+j.wsLabel).length>0) root.apWsLabel=""+j.wsLabel;
            if(j.barLogo!==undefined && (""+j.barLogo).length>0) root.apBarLogo=""+j.barLogo;
            if(j.barLogoPath!==undefined) root.apBarLogoPath=""+j.barLogoPath;
            root.apStickerPower = j.stickerPower ? ""+j.stickerPower : "";
            root.apStickerMedia = j.stickerMedia ? ""+j.stickerMedia : "";
            if(j.welcomed!==undefined) root.apWelcomed=!!j.welcomed;
            if(j.autoHide!==undefined) root.apAutoHide=!!j.autoHide;
            if(j.hideFullscreen!==undefined) root.apHideFullscreen=!!j.hideFullscreen;
            if(j.hideGaming!==undefined) root.apHideGaming=!!j.hideGaming;
            if(j.suspendShellGaming!==undefined) root.apSuspendShellGaming=!!j.suspendShellGaming;
            if(j.autoPowerBattery!==undefined) root.apAutoPowerBattery=!!j.autoPowerBattery;
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
            reducedMotion: root.apReducedMotion,
            barOpaque: true,
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
            wgAi: root.wgAi,
            wgGithub: root.wgGithub,
            wgTotem: root.wgTotem,
            aiOn: root.apAiOn,
            aiDefault: root.apAiDefault,
            aiDigits: root.apAiDigits,
            wgNight: root.wgNight,
            wgMic: root.wgMic,
            sysShow: root.apSysShow,
            autoHide: root.apAutoHide,
            hideFullscreen: root.apHideFullscreen,
            hideGaming: root.apHideGaming,
            suspendShellGaming: root.apSuspendShellGaming,
            autoPowerBattery: root.apAutoPowerBattery,
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
        if (p.reducedMotion !== undefined) root.apReducedMotion = p.reducedMotion;
        if (p.barOpaque !== undefined) root.apBarOpaque = p.barOpaque;
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
        if (p.wgAi !== undefined) root.wgAi = p.wgAi;
        if (p.wgGithub !== undefined) root.wgGithub = p.wgGithub;
        if (p.wgTotem !== undefined) root.wgTotem = p.wgTotem;
        if (p.aiOn && typeof p.aiOn === "object") root.apAiOn = p.aiOn;
        if (typeof p.aiDefault === "string" && root.aiPlanKnown(p.aiDefault)) root.apAiDefault = p.aiDefault;
        if (p.aiDigits === 0 || p.aiDigits === 1 || p.aiDigits === 2) root.apAiDigits = p.aiDigits;
        if (p.wgNight !== undefined) root.wgNight = p.wgNight;
        if (p.wgMic !== undefined) root.wgMic = p.wgMic;
        if (p.autoHide !== undefined) root.apAutoHide = p.autoHide;
        if (p.hideFullscreen !== undefined) root.apHideFullscreen = p.hideFullscreen;
        if (p.hideGaming !== undefined) root.apHideGaming = p.hideGaming;
        if (p.suspendShellGaming !== undefined) root.apSuspendShellGaming = p.suspendShellGaming;
        if (p.autoPowerBattery !== undefined) root.apAutoPowerBattery = p.autoPowerBattery;
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
    readonly property var barToggleKeys: ["wgMpris","wgTray","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgVolume","wgBattery","wgClock","wgPower","wgQuick","wgNet","wgUpdates","wgMic","wgAi","wgGithub","wgTotem"]
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
            reducedMotion:   root.apReducedMotion,
            displaySetups:   root.apDisplaySetups,
            glass:           root.apGlass,
            barOpaque:       true,
            height:          Math.round(root.apHeight),
            scale:           Number(root.apScale.toFixed(2)),
            accent:          root.apAccent,
            iconTheme:       root.apIconTheme,
            folderColorFollow: root.apFolderColorFollow,
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
            clock24:         root.apClock24,
            clockSeconds:    root.apClockSeconds,
            wgPower:         root.wgPower,
            wgQuick:         root.wgQuick,
            wgAi:            root.wgAi,
            wgGithub:        root.wgGithub,
            wgTotem:         root.wgTotem,
            aiOn:            root.apAiOn,
            aiDefault:       root.apAiDefault,
            aiDigits:        root.apAiDigits,
            wgNight:         root.wgNight,
            wgMic:           root.wgMic,
            hotCorners:      root.apHotCorners,
            barShape:        root.apBarShape,
            wsStyle:         root.apWsStyle,
            wsLabel:         root.apWsLabel,
            barLogo:         root.apBarLogo,
            barLogoPath:     root.apBarLogoPath,
            stickerPower:    root.apStickerPower,
            stickerMedia:    root.apStickerMedia,
            welcomed:        root.apWelcomed,
            autoHide:        root.apAutoHide,
            hideFullscreen:  root.apHideFullscreen,
            hideGaming:      root.apHideGaming,
            suspendShellGaming: root.apSuspendShellGaming,
            autoPowerBattery: root.apAutoPowerBattery,
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
        root.queueAppearanceSave(j);
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
    function applyModeFromWallpaper() { root.afterAppearanceSave(function() { Quickshell.execDetached(["sh", root.modeScript]); }); }

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
        root.afterAppearanceSave(function() { Quickshell.execDetached(["sh", root.matugenScript]); });
    }
    // The wallpaper's OWN colours are a different case: choosing one of these is choosing what
    // matching would have given you, so matching stays on.
    function pickPaletteAccent(c) {
        root.apAccent = c;
        root.saveAppearance();
        root.afterAppearanceSave(function() { Quickshell.execDetached(["sh", root.matugenScript]); });
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
                    var e = { active: p[0] === "yes", signal: parseInt(p[1]) || 0, secure: (p[2] || "").length > 0,
                              enterprise: WifiEnterprise.isEnterprise(p[2]), ssid: sid };
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
    // Paused while a password row is open: the rows are rebuilt from each scan, and the field
    // you were typing into went with them, half a password and all.
    Timer { interval: 10000; running: root.shown && root.tab === 2 && root.wifiPwFor === ""; repeat: true; onTriggered: root.rescanWifi() }

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
        root.wifiMsg = "connecting to hidden “" + e + "”…"; root.hidOpen = false; root.wifiRetry = ""; root.wifiAsked = ssid;
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
    // The join in flight, ours or NetworkManager's own (auto-reconnect), so the row can say so.
    // Before this the only sign was a grey line of text above the list; the row you clicked
    // looked untouched until the scan after the handshake.
    property string wifiAsked: ""
    property string wifiDevConnecting: ""
    readonly property string wifiConnectingTo: root.wifiAsked !== "" ? root.wifiAsked : root.wifiDevConnecting
    property int wifiPhase: 0
    Timer { interval: 420; repeat: true; running: root.shown && root.wifiConnectingTo !== ""
        onTriggered: root.wifiPhase = (root.wifiPhase + 1) % 3 }
    Process { id: wifiDevState
        command: ["sh","-c","nmcli -t -f TYPE,STATE,CONNECTION dev status 2>/dev/null | awk -F: '$1==\"wifi\"{print $2 \"\\t\" $3; exit}'"]
        stdout: StdioCollector { id: wdsOut; onStreamFinished: {
            var p = wdsOut.text.replace(/\n$/, "").split("\t");
            root.wifiDevConnecting = (p[0] || "").indexOf("connecting") === 0 ? (p[1] || "network") : "";
        } } }
    Timer { interval: root.wifiConnectingTo !== "" ? 1000 : 4000; repeat: true; triggeredOnStart: true
        running: root.shown && root.tab === 2; onTriggered: wifiDevState.running = true }
    function wifiConnect(ssid, secure) {
        var e = ssid.replace(/'/g, "");
        if (secure && root.savedCons.indexOf(ssid) >= 0) {
            // known network → reconnect with the STORED password; prompt only on failure
            root.wifiMsg = "connecting…"; root.wifiRetry = ssid; root.wifiAsked = ssid;
            wifiJoin.command = ["sh","-c","nmcli con up id '" + e + "' 2>&1"];
            wifiJoin.running = true; return;
        }
        if (secure) { root.wifiPwFor = ssid; root.wifiMsg = ""; return }
        root.wifiMsg = "connecting…"; root.wifiRetry = ""; root.wifiAsked = ssid;
        wifiJoin.command = ["sh","-c","nmcli dev wifi connect '" + e + "' 2>&1"];
        wifiJoin.running = true;
    }
    // identity is only passed for 802.1X networks; they need a full EAP profile, not a PSK join
    function wifiJoinPw(ssid, pw, identity) {
        if (!pw.length) return;
        if (identity !== undefined && !identity.length) return;
        var e = ssid.replace(/'/g, ""), p = pw.replace(/'/g, "'\\''");
        root.wifiMsg = "connecting…"; root.wifiPwFor = ""; root.wifiRetry = ""; root.wifiAsked = ssid;
        wifiJoin.command = identity !== undefined
            ? WifiEnterprise.joinCmd(ssid, identity, pw)
            : ["sh","-c","nmcli dev wifi connect '" + e + "' password '" + p + "' 2>&1"];
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
            root.wifiAsked = ""; wifiDevState.running = true;
            if (!ok && root.wifiRetry !== "") {           // stored secret failed → ask inline
                root.wifiPwFor = root.wifiRetry; root.wifiRetry = "";
                root.wifiMsg = "saved password didn't work — enter it again";
                wifiRefresh.start(); return;
            }
            root.wifiRetry = "";
            root.wifiMsg = ok ? "connected ✓"
                         : t.indexOf("Secrets were required") >= 0 || t.indexOf("password") >= 0 ? "Wrong password. Try again."
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






    SurfaceMotion { id: settingsMotion; opened: root.shown && (root.apLoaded || Tok.loaded); reduced: Tok.reducedMotion; enterDuration: 160; exitDuration: 100 }
    NumberAnimation { id: pageArrival; target: pane; property: "arrival"; from: 0; to: 1
        duration: Tok.mBase; easing.type: Easing.OutCubic }
    onApSubTabChanged: if (root.shown) pageArrival.restart()

    // ============ window ============
    // KEPT WARM. Hiding the window threw away its surface and graphics, and making them again
    // took 160-220 ms before the first frame on every open (measured), which is the lag you
    // felt. So closed, the window stays mapped but shrinks to one transparent pixel in the
    // corner that takes no input or keys; opening only grows it back. (This also ends the
    // remap that SddmPreview.qml had to unload its theme around.)
    PanelWindow {
        id: panel
        readonly property bool live: root.shown || settingsMotion.presenting
        visible: !root.authenticationPending
        WlrLayershell.namespace: "sea-shell:settings"
        anchors { top: true; left: true; bottom: panel.live; right: panel.live }
        implicitWidth: 1; implicitHeight: 1
        // two regions, not null: a null mask cannot be assigned back, so the window stayed click-through once opened
        mask: panel.live ? allInput : noInput
        Region { id: noInput }
        Region { id: allInput; item: panel.contentItem }
        color: "transparent"
        // Keep the native surface on one layer. Changing layers on every toggle
        // requires a remap and discards the warm surface, delaying the first frame.
        // Closed panels already shrink to one transparent pixel with an empty mask.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        readonly property real ui: root.uiScaleFor(panel.screen)

        // The scrim lives inside the scaled contentItem, so it is sized in NATIVE units
        // (screen ÷ ui) to land exactly on the screen edges once scaled. With anchors.fill it
        // was shrunk with everything else: at a UI scale below 1× the dim only covered the
        // middle of the screen and left a bright frame round it (and clicks on that frame
        // fell through instead of closing).
        Rectangle { anchors.centerIn: parent; width: panel.contentItem.width / panel.ui; height: panel.contentItem.height / panel.ui
            opacity: settingsMotion.progress
            color: Qt.rgba(0, 0, 0, 0.5); MouseArea { anchors.fill: parent; onClicked: root.closePanel() } }
        Item { anchors.fill: parent; focus: root.shown; Keys.onEscapePressed: root.closePanel() }
        // scale the whole settings window with the UI scale — live-previews as the slider moves.
        // Content is authored native; clamps are in native space so it always fits the screen.
        Binding { target: panel.contentItem; property: "scale"; value: panel.ui }

        Rectangle {
            id: winCard
            anchors.centerIn: parent
            width: Math.min((panel.screen ? panel.screen.width : parent.width) / panel.ui - 60, 1140)
            height: Math.min((panel.screen ? panel.screen.height : parent.height) / panel.ui - 60, 840)
            radius: Math.max(12, Math.min(18, Tok.rCard))
            opacity: settingsMotion.progress
            scale: 0.975 + 0.025 * settingsMotion.progress
            transform: Translate { y: 16 * (1 - settingsMotion.progress) }
            layer.enabled: settingsMotion.progress > 0 && settingsMotion.progress < 1
            layer.smooth: true
            color: root.windowCanvas
            border.width: 1
            border.color: Tok.ruleHard
            clip: true

            MouseArea { anchors.fill: parent }
            MouseArea { anchors.fill: parent; z: 1000; visible: !root.shown; hoverEnabled: true; acceptedButtons: Qt.AllButtons }

            // Global shortcuts inside Settings (Ctrl+F search, Alt+Left/Right back/forward)
            Shortcut { enabled: root.shown; sequence: "Ctrl+F"; onActivated: navIn.forceActiveFocus() }
            Shortcut { enabled: root.shown && root.canNavBack; sequence: "Alt+Left"; onActivated: root.navGo(-1) }
            Shortcut { enabled: root.shown && root.navFwd.length > 0; sequence: "Alt+Right"; onActivated: root.navGo(1) }

            // ---------------- macOS Sequoia Sidebar ----------------
            Rectangle {
                id: sidebarPane
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                width: 248
                radius: parent.radius - 1
                color: root.sidebarFill
                // square off inner edge
                Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: parent.radius; color: parent.color }
                Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: root.hairline }
            }

            Item {
                id: sidebar
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 12; topMargin: 14; bottomMargin: 12 }
                width: 224

                ColumnLayout {
                    id: sbHead
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    spacing: 10

                    // Authentic macOS window close dot + subtle title
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 4
                        spacing: 7
                        Rectangle {
                            id: macCloseDot
                            implicitWidth: 12; implicitHeight: 12; radius: 6
                            color: "#FF5F56"
                            border.width: 0.5; border.color: Qt.rgba(0, 0, 0, 0.22)
                            Sym {
                                anchors.centerIn: parent; text: "close"; sz: 9
                                color: "#4D0000"; visible: macCloseMa.containsMouse
                            }
                            MouseArea {
                                id: macCloseMa; anchors.fill: parent; anchors.margins: -3
                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.closePanel()
                            }
                        }
                        Rectangle {
                            implicitWidth: 12; implicitHeight: 12; radius: 6
                            color: Tok.light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.12)
                        }
                        Rectangle {
                            implicitWidth: 12; implicitHeight: 12; radius: 6
                            color: Tok.light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.12)
                        }
                        Item { Layout.fillWidth: true }
                    }

                    // Recessed macOS Search Field
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30; radius: 8
                        color: Tok.light ? Qt.rgba(0, 0, 0, 0.055) : Qt.rgba(1, 1, 1, 0.07)
                        border.width: navIn.activeFocus ? 1.5 : 1
                        border.color: navIn.activeFocus ? Tok.accent : (Tok.light ? Qt.rgba(0, 0, 0, 0.07) : Qt.rgba(1, 1, 1, 0.08))
                        Behavior on border.color { ColorAnimation { duration: Tok.mMicro } }

                        Sym {
                            id: navMag
                            anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter }
                            text: "search"; sz: 15
                            color: navIn.activeFocus ? Tok.accent : Tok.ink3
                        }
                        TextInput {
                            id: navIn
                            anchors { left: navMag.right; leftMargin: 6; right: navClr.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                            color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                            onTextChanged: root.navQuery = text
                            Keys.onPressed: (e) => {
                                if (e.key === Qt.Key_Escape) {
                                    if (navIn.text.length) { navIn.text = ""; e.accepted = true }
                                } else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && root.navHits.length > 0) {
                                    root.jumpFromSearch(root.navHits[0]); e.accepted = true;
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !navIn.text.length
                                text: "Search"
                                color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                            }
                        }
                        Item {
                            id: navClr
                            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            width: 18; height: 18
                            visible: navIn.text.length > 0
                            Sym { anchors.centerIn: parent; text: "cancel"; sz: 14; color: navClrMa.containsMouse ? Tok.ink : Tok.ink3 }
                            MouseArea {
                                id: navClrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { navIn.text = ""; navIn.forceActiveFocus() }
                            }
                        }
                    }

                    // macOS Apple Account-style User Profile row
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: meCard.implicitHeight; radius: 8
                        color: root.tab === 23 ? Tok.accentWash : (meMa.containsMouse ? root.rowHover : "transparent")
                        border.width: root.tab === 23 ? 1 : 0; border.color: Tok.alpha(Tok.accent, 0.35)
                        Behavior on color { ColorAnimation { duration: Tok.mMicro } }
                        ProfileCard {
                            id: meCard; width: parent.width; compact: true; flat: true
                            profile: root.userProfile
                            subtitle: root.sysInfo.host ? ("Local Account · " + root.sysInfo.host) : "Your Profile"
                        }
                        MouseArea {
                            id: meMa; anchors.fill: parent; hoverEnabled: true; preventStealing: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.showTab(23)
                        }
                    }
                }

                Flickable {
                    id: sbFlick
                    anchors { left: parent.left; right: parent.right; top: sbHead.bottom; bottom: sbFoot.top }
                    anchors.topMargin: 8; anchors.bottomMargin: 8
                    clip: true
                    contentWidth: width
                    contentHeight: root.navQuery.length ? sbHits.implicitHeight : sbList.implicitHeight
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds

                    // Search results list
                    ColumnLayout {
                        id: sbHits
                        visible: root.navQuery.length > 0
                        width: sbFlick.width
                        spacing: 2
                        Text {
                            visible: root.navHits.length === 0
                            Layout.fillWidth: true; Layout.topMargin: 12; Layout.leftMargin: 6
                            text: "No results for \u201c" + root.navQuery + "\u201d"
                            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans; wrapMode: Text.WordWrap
                        }
                        Repeater {
                            model: root.navHits
                            delegate: Rectangle {
                                id: hitRow
                                required property var modelData
                                Layout.fillWidth: true; implicitHeight: 40; radius: 7
                                color: hitMa.containsMouse ? root.rowHover : "transparent"
                                Behavior on color { ColorAnimation { duration: Tok.mMicro } }
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                    spacing: 9
                                    MacIconBadge {
                                        icon: hitRow.modelData.icon && hitRow.modelData.icon.length
                                              ? hitRow.modelData.icon : root.tabIcon(hitRow.modelData.tab)
                                        badgeColor: root.tabColor(hitRow.modelData.tab)
                                        size: 21; iconSize: 13
                                    }
                                    Column {
                                        Layout.fillWidth: true; spacing: 0
                                        Text {
                                            width: parent.width; elide: Text.ElideRight
                                            text: hitRow.modelData.title
                                            color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
                                        }
                                        Text {
                                            width: parent.width; elide: Text.ElideRight
                                            readonly property int par: root.tabParent(hitRow.modelData.tab)
                                            text: par >= 0 ? (root.tabLabel(par) + " › " + root.tabLabel(hitRow.modelData.tab))
                                                           : root.tabLabel(hitRow.modelData.tab)
                                            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                                        }
                                    }
                                }
                                MouseArea {
                                    id: hitMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.jumpFromSearch(hitRow.modelData)
                                }
                            }
                        }
                    }

                    // Streamlined macOS Sequoia Sidebar Categories (20 top-level panes)
                    ColumnLayout {
                        id: sbList
                        visible: root.navQuery.length === 0
                        width: sbFlick.width
                        spacing: 2

                        // Connectivity
                        TabBtn { icon: "wifi";                  label: "Network";            idx: 2 }
                        TabBtn { icon: "bluetooth";             label: "Bluetooth";          idx: 9 }
                        TabBtn { icon: "phonelink";             label: "Phone Link";         idx: 14 }
                        GroupGap {}

                        // Sound & Attention
                        TabBtn { icon: "notifications";         label: "Notifications";      idx: 24 }
                        TabBtn { icon: "volume_up";             label: "Sound";              idx: 0 }
                        TabBtn { icon: "hourglass_top";         label: "Screen Time";        idx: 18 }
                        GroupGap {}

                        // Core System & Look (macOS Sequoia order)
                        TabBtn { icon: "settings";              label: "General";            idx: 8; badge: attention.urgentCount }
                        TabBtn { icon: "accessibility_new";     label: "Accessibility";      idx: 26 }
                        TabBtn { icon: "palette";               label: "Appearance";         idx: 4 }
                        TabBtn { icon: "view_agenda";           label: "Menu Bar";           idx: 20 }
                        TabBtn { icon: "dock_to_bottom";        label: "Desktop & Dock";     idx: 16 }
                        TabBtn { icon: "monitor";               label: "Displays";           idx: 1 }
                        TabBtn { icon: "wallpaper";             label: "Wallpaper";          idx: 21 }
                        GroupGap {}

                        // Security, Lock & Power
                        TabBtn { icon: "lock";                  label: "Lock Screen";        idx: 10 }
                        TabBtn { icon: "shield";                label: "Privacy & Security"; idx: 27 }
                        TabBtn { icon: "battery_charging_full"; label: "Battery & Power";    idx: 6 }
                        GroupGap {}

                        // Gaming, Hardware & Apps
                        TabBtn { icon: "sports_esports";        label: "Gaming";             idx: 25 }
                        TabBtn { icon: "keyboard";              label: "Keyboard";           idx: 7 }
                        TabBtn { icon: "mouse";                 label: "Mouse & Trackpad";   idx: 15 }
                        TabBtn { icon: "apps";                  label: "Apps & Calendar";    idx: 22 }
                    }
                }

                // Subtle macOS overlay scrollbar for sidebar
                Rectangle {
                    visible: sbFlick.contentHeight > sbFlick.height
                    width: 3; radius: 1.5
                    color: Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, sbFlick.moving ? 0.38 : 0.16)
                    anchors.right: sbFlick.right; anchors.rightMargin: -4
                    y: sbFlick.y + (sbFlick.contentHeight > 0 ? (sbFlick.contentY / sbFlick.contentHeight) * sbFlick.height : 0)
                    height: sbFlick.contentHeight > 0 ? Math.max(24, sbFlick.height * (sbFlick.height / sbFlick.contentHeight)) : 0
                }

                // Minimal version footer
                RowLayout {
                    id: sbFoot
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 6; rightMargin: 6 }
                    spacing: 7
                    SeaLogo { size: 17; card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent }
                    Text { text: "sea-shell"; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans; font.weight: 600 }
                    Text { text: "v" + root.seaVersion; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono }
                    Item { Layout.fillWidth: true }
                    Text { text: "Esc"; color: Tok.ink3; font.pixelSize: 10; font.family: Tok.mono }
                }
            }

            // ---------------- macOS Content Toolbar (Back / Forward / Breadcrumb Title) ----------------
            Item {
                id: toolbar
                anchors { left: sidebarPane.right; right: parent.right; top: parent.top }
                height: 48

                RowLayout {
                    anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                    spacing: 4

                    Repeater {
                        model: [{ g: "chevron_left", d: -1 }, { g: "chevron_right", d: 1 }]
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool can: modelData.d < 0 ? root.canNavBack : root.navFwd.length > 0
                            implicitWidth: 28; implicitHeight: 28; radius: 7
                            color: navMa.containsMouse && can ? root.rowHover : "transparent"
                            Sym {
                                anchors.centerIn: parent; text: modelData.g; sz: 22
                                color: can ? Tok.ink : Qt.rgba(Tok.ink3.r, Tok.ink3.g, Tok.ink3.b, 0.35)
                            }
                            MouseArea {
                                id: navMa; anchors.fill: parent; hoverEnabled: true; enabled: can
                                cursorShape: can ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.navGo(modelData.d)
                            }
                        }
                    }

                    // Breadcrumb parent link when inside a drill-down sub-pane
                    Rectangle {
                        readonly property int par: root.tabParent(root.tab)
                        visible: par >= 0
                        Layout.leftMargin: 6
                        implicitWidth: parTxt.implicitWidth + 12; implicitHeight: 26; radius: 6
                        color: parMa.containsMouse ? root.rowHover : "transparent"
                        Text {
                            id: parTxt; anchors.centerIn: parent
                            text: parent.par >= 0 ? root.tabLabel(parent.par) : ""
                            color: Tok.ink2; font.pixelSize: 14; font.family: Tok.sans; font.weight: 500
                        }
                        MouseArea {
                            id: parMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: if (parent.par >= 0) root.showTab(parent.par)
                        }
                    }
                    Sym {
                        visible: root.tabParent(root.tab) >= 0
                        text: "chevron_right"; sz: 16; color: Tok.ink3
                    }

                    Text {
                        Layout.leftMargin: root.tabParent(root.tab) >= 0 ? 2 : 8
                        text: root.tabLabel(root.tab)
                        color: Tok.ink; font.pixelSize: 15; font.family: Tok.sans; font.weight: 700
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: root.appearanceSaveState
                        color: root.appearanceSaveFailed ? Tok.crit : Tok.ink3
                        font.pixelSize: 11; font.family: Tok.sans
                        elide: Text.ElideRight; Layout.maximumWidth: 220
                    }

                    Rectangle {
                        implicitWidth: 26; implicitHeight: 26; radius: 13
                        color: closeMa.containsMouse ? root.rowHover : "transparent"
                        Sym { anchors.centerIn: parent; text: "close"; sz: 16; color: closeMa.containsMouse ? Tok.ink : Tok.ink3 }
                        MouseArea {
                            id: closeMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.closePanel()
                        }
                    }
                }

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1; color: root.hairline
                }
            }

            // Subtle overlay scrollbar for main content
            Rectangle {
                visible: contentFlick.contentHeight > contentFlick.height
                width: 4; radius: 2
                color: Qt.rgba(Tok.ink.r, Tok.ink.g, Tok.ink.b, contentFlick.moving ? 0.36 : 0.14)
                anchors { right: parent.right; rightMargin: 6 }
                y: contentFlick.y + (contentFlick.contentHeight > 0 ? (contentFlick.contentY / contentFlick.contentHeight) * contentFlick.height : 0)
                height: contentFlick.contentHeight > 0 ? Math.max(28, (contentFlick.height / contentFlick.contentHeight) * contentFlick.height) : 0
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
            }

            // ---------------- Full-Height Scrollable macOS Content Column ----------------
            Flickable {
                id: contentFlick
                anchors { left: sidebarPane.right; right: parent.right; top: toolbar.bottom; bottom: parent.bottom }
                contentWidth: width
                contentHeight: pane.implicitHeight + 68
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: pane
                    property real arrival: 1
                    readonly property real colW: Math.min(contentFlick.width - 56, 740)
                    width: colW
                    x: Math.max(24, (contentFlick.width - colW) / 2)
                    y: 20
                    opacity: 0.72 + 0.28 * arrival
                    transform: Translate { y: 6 * (1 - pane.arrival) }
                    spacing: 16

                    // Existing & redesigned pages (all original tab IDs preserved)
                    PageLoader { page: 0;  source: Qt.resolvedUrl("SettingsPageAudio.qml") }
                    PageLoader { page: 1;  source: Qt.resolvedUrl("SettingsPageDisplay.qml") }
                    PageLoader { page: 2;  source: Qt.resolvedUrl("SettingsPageNetwork.qml") }
                    PageLoader { page: 2;  source: Qt.resolvedUrl("SettingsPageVpn.qml") }
                    PageLoader { page: 3;  source: Qt.resolvedUrl("SettingsPageWeather.qml") }
                    PageLoader { page: 4;  source: Qt.resolvedUrl("SettingsPageAppearance.qml") }
                    PageLoader { page: 5;  source: Qt.resolvedUrl("SettingsPageActions.qml") }
                    PageLoader { page: 6;  source: Qt.resolvedUrl("SettingsPagePower.qml") }
                    PageLoader { page: 7;  source: Qt.resolvedUrl("SettingsPageKeybinds.qml") }
                    PageLoader { page: 8;  source: Qt.resolvedUrl("SettingsPageSystem.qml") }
                    PageLoader { page: 9;  source: Qt.resolvedUrl("SettingsPageBluetooth.qml") }
                    PageLoader { page: 10; source: Qt.resolvedUrl("SettingsPageIdleLock.qml") }
                    PageLoader { page: 11; source: Qt.resolvedUrl("SettingsPageCalendar.qml") }
                    PageLoader { page: 12; source: Qt.resolvedUrl("SettingsPageBarWidgets.qml") }
                    PageLoader { page: 13; source: Qt.resolvedUrl("SettingsPageThemeProfiles.qml") }
                    PageLoader { page: 14; source: Qt.resolvedUrl("SettingsPageKdeConnect.qml") }
                    PageLoader { page: 15; source: Qt.resolvedUrl("SettingsPageInput.qml") }
                    PageLoader { page: 16; source: Qt.resolvedUrl("SettingsPageDock.qml") }
                    PageLoader { page: 17; source: Qt.resolvedUrl("SettingsPageWindowRules.qml") }
                    PageLoader { page: 18; source: Qt.resolvedUrl("SettingsPageScreenTime.qml") }
                    PageLoader { page: 19; source: Qt.resolvedUrl("SettingsPageDisks.qml") }
                    PageLoader { page: 20; source: Qt.resolvedUrl("SettingsPageBar.qml") }
                    PageLoader { page: 21; source: Qt.resolvedUrl("SettingsPageDesktop.qml") }
                    PageLoader { page: 22; source: Qt.resolvedUrl("SettingsPageDefaultApps.qml") }
                    PageLoader { page: 23; source: Qt.resolvedUrl("SettingsPageProfile.qml") }
                    PageLoader { page: 24; source: Qt.resolvedUrl("SettingsPageNotifications.qml") }
                    PageLoader { page: 25; source: Qt.resolvedUrl("SettingsPageGaming.qml") }

                    // New macOS & Linux/Hyprland pages
                    PageLoader { page: 26; source: Qt.resolvedUrl("SettingsPageAccessibility.qml") }
                    PageLoader { page: 27; source: Qt.resolvedUrl("SettingsPagePrivacy.qml") }
                    PageLoader { page: 28; source: Qt.resolvedUrl("SettingsPageAbout.qml") }
                    PageLoader { page: 29; source: Qt.resolvedUrl("SettingsPageUpdates.qml") }
                    PageLoader { page: 30; source: Qt.resolvedUrl("SettingsPageStartup.qml") }
                    PageLoader { page: 31; source: Qt.resolvedUrl("SettingsPageDateTime.qml") }
                    PageLoader { page: 32; source: Qt.resolvedUrl("SettingsPageLanguage.qml") }
                    PageLoader { page: 33; source: Qt.resolvedUrl("SettingsPageBackup.qml") }
                    PageLoader { page: 34; source: Qt.resolvedUrl("SettingsPageHealth.qml") }
                    PageLoader { page: 35; source: Qt.resolvedUrl("SettingsPageWindowEffects.qml") }
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
                    color: theme.panel
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
                                text: root.kbAdding ? "New keybind" : (root.kbRec ? root.kbRec.desc : "")
                                color: theme.text; font.pixelSize: 15; font.family: Tok.sans; font.bold: true }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: kbXMa.containsMouse ? theme.a(theme.bad,0.25) : "transparent"
                                Sym { anchors.centerIn: parent; text: "close"; sz: 16; color: kbXMa.containsMouse ? theme.bad : theme.faint }
                                MouseArea { id: kbXMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                        }
                        // add-mode only: description + action inputs
                        ColumnLayout { visible: root.kbAdding; spacing: 4; Layout.fillWidth: true
                            Text { text: "Description"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbDescIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbDescIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.sans; clip: true; text: root.kbAddDesc; onTextChanged: root.kbAddDesc = text
                                    Text { visible: kbDescIn2.text===""; text: "E.g. Launch Firefox"; color: theme.faint; font.pixelSize: 12; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter } } }
                            Text { text: "Action / command"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.topMargin: 4 }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.4); border.width: 1; border.color: kbActIn2.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbActIn2; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter; color: theme.text; font.pixelSize: 12; font.family: Tok.sans; clip: true; text: root.kbAddAction; onTextChanged: root.kbAddAction = text } }
                        }
                        // edit-mode: what the bind actually runs
                        ColumnLayout { visible: !root.kbAdding && root.kbRec !== null; spacing: 4; Layout.fillWidth: true
                            Text { text: root.kbRec && root.kbRec.isExec ? "Command" : "Action (read-only)"
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                                color: theme.a(theme.line, root.kbRec && root.kbRec.isExec ? 0.4 : 0.22)
                                border.width: 1
                                border.color: kbActEdit.activeFocus ? theme.iris : theme.a(theme.iris,0.14)
                                TextInput { id: kbActEdit
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: root.kbRec && root.kbRec.isExec ? theme.text : theme.faint
                                    font.pixelSize: 12; font.family: Tok.sans; clip: true
                                    readOnly: !(root.kbRec && root.kbRec.isExec)
                                    text: root.kbRec ? (root.kbRec.isExec ? root.kbRecAction
                                                       : (root.kbRec.dispatcher + (root.kbRec.arg ? " " + root.kbRec.arg : "")))
                                                     : ""
                                    onTextChanged: if (root.kbRec && root.kbRec.isExec) root.kbRecAction = text } }
                            Text { visible: !!(root.kbRec && !root.kbRec.isExec)
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "This one runs a compositor action, not a command — only its shortcut can be changed here"
                                color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                        }
                        // shortcut picker (both modes)
                        Text { text: "Shortcut"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                        Flow { Layout.fillWidth: true; spacing: 6
                            Repeater { model: ["SUPER","CTRL","ALT","SHIFT"]
                                delegate: Rectangle { required property string modelData
                                    readonly property var mods: root.kbAdding ? root.kbAddMods : root.kbRecMods
                                    readonly property bool on: mods.indexOf(modelData) >= 0
                                    width: kmcT.width + 16; height: 26; radius: Tok.r
                                    color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5); border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                    Text { id: kmcT; anchors.centerIn: parent; text: modelData; color: on ? theme.frost : theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: on }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (root.kbAdding) { var m = root.kbAddMods.slice(); var i = m.indexOf(modelData); if(i>=0)m.splice(i,1); else m.push(modelData); root.kbAddMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m.indexOf(x)>=0); }
                                            else { var m2 = root.kbRecMods.slice(); var j = m2.indexOf(modelData); if(j>=0)m2.splice(j,1); else m2.push(modelData); root.kbRecMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x=>m2.indexOf(x)>=0); root.kbConflict=""; }
                                        } } }
                            }
                        }
                        // key capture
                        RowLayout { Layout.fillWidth: true; spacing: 10
                            Text { text: "Key"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 30 }
                            Rectangle { id: kbKeyBox; Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                                readonly property bool rec: root.kbAdding ? root.kbAddRecording : root.kbRecRecording
                                readonly property string keyv: root.kbAdding ? root.kbAddKey : root.kbRecKey
                                color: rec ? theme.a(theme.bad,0.18) : theme.a(theme.line,0.4); border.width: 1; border.color: rec ? theme.bad : theme.a(theme.iris,0.3)
                                Text { anchors.centerIn: parent
                                    text: kbKeyBox.rec ? "Press a key…" : (kbKeyBox.keyv ? root.kbPretty(kbKeyBox.keyv) : "Click, then press a key")
                                    color: kbKeyBox.rec ? theme.bad : (kbKeyBox.keyv ? theme.frost : theme.faint); font.pixelSize: 12; font.family: Tok.sans; font.bold: true }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (root.kbAdding) root.kbAddRecording = true; else root.kbRecRecording = true; kbCapture.forceActiveFocus() } }
                            }
                        }
                        // conflict / hint
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: root.kbConflict !== "" ? root.kbConflict : "Pick modifiers, click the key box and press a key"
                            color: root.kbConflict !== "" ? theme.bad : theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                        // actions
                        RowLayout { Layout.fillWidth: true; spacing: 10; Layout.topMargin: 2
                            Rectangle { visible: !root.kbAdding; implicitWidth: 110; implicitHeight: 32; radius: Tok.r
                                color: Tok.critWash
                                Text { anchors.centerIn: parent; text: root.kbDeleteArmed ? "Confirm delete" : "Delete"; color: Tok.crit; font.pixelSize: 12; font.family: Tok.sans }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (root.kbDeleteArmed && root.kbRec) root.kbMutate(["--delete",root.kbRec.sourceId]); else root.kbDeleteArmed = true } }
                            }
                            Item { Layout.fillWidth: true }
                            Rectangle { implicitWidth: 76; implicitHeight: 32; radius: Tok.r
                                color: kbCanMa.containsMouse ? theme.a(theme.bad,0.14) : "transparent"; border.width: 1; border.color: kbCanMa.containsMouse ? theme.bad : theme.a(theme.line,0.6)
                                Text { anchors.centerIn: parent; text: "Cancel"; color: kbCanMa.containsMouse ? theme.bad : theme.text; font.pixelSize: 12; font.family: Tok.sans }
                                MouseArea { id: kbCanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.kbCloseEditor() } }
                            Rectangle { id: kbOkBtn
                                readonly property bool valid: root.kbAdding ? (root.kbAddDesc.trim()!=="" && root.kbAddKey!=="" && root.kbAddAction.trim()!=="") : (root.kbRecKey!=="")
                                implicitWidth: 92; implicitHeight: 32; radius: Tok.r
                                color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22)) : theme.a(theme.line,0.3); border.width: 1; border.color: kbOkBtn.valid ? theme.iris : theme.a(theme.line,0.5)
                                Text { anchors.centerIn: parent; text: root.kbAdding ? "Add bind" : "Save"; color: kbOkBtn.valid ? (kbOkMa.containsMouse ? theme.bg : theme.text) : theme.faint; font.pixelSize: 12; font.family: Tok.sans; font.bold: true }
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
                color: theme.bg
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
                        Text { text: root.fileBrowserTitle; color: theme.text; font.pixelSize: 15; font.family: Tok.sans; font.bold: true; Layout.fillWidth: true }
                        // Confirm — folder mode only, where the answer is where you are
                        Rectangle {
                            visible: root.fileBrowserDirs
                            implicitWidth: fbUseRow.implicitWidth + 22; implicitHeight: 32; radius: Tok.r
                            color: fbUseMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22)
                            border.width: 1; border.color: theme.iris
                            Behavior on color { ColorAnimation { duration: Tok.mFast } }
                            RowLayout {
                                id: fbUseRow; anchors.centerIn: parent; spacing: 7
                                Sym { text: "check"; sz: 16; color: fbUseMa.containsMouse ? Tok.accentInk : Tok.ink }
                                Text { text: "Use this folder"; color: fbUseMa.containsMouse ? Tok.accentInk : Tok.ink
                                       font.pixelSize: 12; font.family: Tok.sans; font.bold: true }
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
                            color: theme.bg; border.width: 1; border.color: theme.a(theme.iris, 0.2)
                            Text { anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                verticalAlignment: Text.AlignVCenter
                                text: root.fileBrowserPath; color: theme.frost; font.pixelSize: 12; font.family: Tok.sans; elide: Text.ElideLeft } }
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
                                    Text { text: ".."; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; font.bold: true } }
                                MouseArea { id: fbItemUpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.goUpDir() } }

                            Repeater {
                                model: root.fileBrowserItems
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool isDir: modelData.type === "d"
                                    readonly property bool matchesFilter: root.fileBrowserDirs ? false
                                        : (!root.fileBrowserFilter || root.fileBrowserFilter.split("|").some(function(ext) { return modelData.name.toLowerCase().endsWith(ext.toLowerCase()) }))
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
                                            font.pixelSize: 12; font.family: Tok.sans; font.bold: isDir; elide: Text.ElideRight; Layout.fillWidth: true } }
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
