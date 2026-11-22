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
import Quickshell.Services.Polkit
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import "WifiEnterprise.js" as WifiEnterprise
import "WallpaperState.js" as WallpaperState

ShellRoot {
    id: root

    // Quickshell's own "Config reloaded" card: the shell reloads itself on every update and
    // file sync, so the card only gets in the way (and can stick on screen). Failures still show.
    Connections { target: Quickshell; function onReloadCompleted() { Quickshell.inhibitReloadPopup() } }

    property var userProfile: ({})
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/profile.json"; watchChanges: true
        onLoaded: { try { root.userProfile = JSON.parse(text()) } catch(e){} }
        onFileChanged: reload()
    }
    // WirePlumber owns output selection and remembers the user's chosen DAC/sink.
    // Starting the shell or connecting a display must not override that choice.

    // ---- KDE Connect Integration ----
    // `--watch` is a resident process that re-prints the device array whenever the
    // daemon signals a change (battery, reachability, pairing) — so the pill and its
    // dropdown are live instead of a spawn-a-python-every-10s poll. The script also
    // reports which plugins are actually loaded per device, which is what gates the
    // action tiles in the dropdown.
    property bool cfgKdeconnect: true
    property var kdeDevices: []
    property string kdeSel: ""                 // device pinned in the dropdown ("" = auto)
    // the device the bar speaks for: the pinned one, else the first — the script sorts
    // online+paired first, so that is the phone you actually care about
    readonly property var kdeDev: {
        if (root.kdeDevices.length === 0) return null;
        for (var i = 0; i < root.kdeDevices.length; i++)
            if (root.kdeDevices[i].id === root.kdeSel) return root.kdeDevices[i];
        return root.kdeDevices[0];
    }
    readonly property bool kdeActive: root.kdeDev !== null && root.kdeDev.isPaired && root.kdeDev.isReachable
    readonly property int kdeBattery: root.kdeActive ? root.kdeDev.charge : -1
    readonly property string kdeScript: Qt.resolvedUrl("sea-kdeconnect.py").toString().replace("file://", "")

    Process {
        id: kdeWatch
        command: ["python3", root.kdeScript, "--watch"]
        stdout: SplitParser { onRead: data => { try { root.kdeDevices = JSON.parse(data) } catch(e) {} } }
    }
    // starts the watcher, stops it when the widget is switched off, and revives it if it
    // ever dies (kdeconnectd restart / D-Bus hiccup). Re-asserting the same value is a no-op.
    Timer { interval: 8000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true
        onTriggered: kdeWatch.running = root.cfgKdeconnect && !root.gameOn }

    // ---- laptop screen (Settings → Display) ----
    // turns the laptop panel off while an external display is connected / the lid is closed;
    // resident so it follows hotplug and the lid. Revived if it dies (compositor restart).
    // sea-panel.sh prefers the Rust binary when install.sh built it; SEA_PANEL_PY=1 forces Python.
    Process { id: panelWatch; command: ["sh", Qt.resolvedUrl("sea-panel.sh").toString().replace("file://", ""), "--watch"] }
    Timer { interval: 8000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true
        onTriggered: panelWatch.running = true }

    function kdeRun(args) { Quickshell.execDetached(["python3", root.kdeScript].concat(args)) }
    function kdeIcon(d) {
        if (!d) return "phonelink_off";
        return d.type === "phone" ? "smartphone" : d.type === "tablet" ? "tablet_android"
             : d.type === "tv" ? "tv" : "computer";
    }
    function kdeStatus(d) {
        if (!d) return "";
        if (!d.isPaired) return d.isPairRequestedByPeer ? "wants to pair"
                              : d.isPairRequested ? "waiting for a reply…"
                              : (d.isReachable ? "not paired" : "not paired · away");
        if (!d.isReachable) return "away";
        return d.network !== "" ? "online · " + d.network : "online";
    }

    // app dock — its own layer-shell surface per monitor, off unless enabled in settings.
    // It shares cfgMonitors with the bar so a monitor turned off there can turn the dock off
    // independently (`{"<name>": {"bar": false, "dock": false}}`).
    Dock {
        id: appDock
        dockEnabled: root.cfgDock && !root.gameOn
        edge: root.cfgDockEdge
        iconSize: root.cfgDockIcon
        mode: root.cfgDockMode
        zoomEnabled: root.cfgDockZoom
        showRunning: root.cfgDockRunning
        showLabels: root.cfgDockLabels
        surfaceOpacity: root.dropOpacity
        attnKey: root.attnKey
        attnNonce: root.attnNonce
        cfgMonitors: root.cfgMonitors
        cfgScale: root.cfgScale
    }

    // Launcher / power / recorder load on first use (Phase 3). Facades keep the old call
    // sites (`launcher.toggle()`, …) working while the Loader is still cold.
    property string _launcherPending: ""
    property string _launcherPrefix: ""
    Loader {
        id: launcherLoader
        asynchronous: true; active: false
        source: Qt.resolvedUrl("Launcher.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            if (root._launcherPending === "toggle") item.toggle();
            else if (root._launcherPending === "open") item.open(root._launcherPrefix);
            root._launcherPending = "";
        }
    }
    QtObject {
        id: launcher
        readonly property bool shown: !!(launcherLoader.item && launcherLoader.item.shown)
        function toggle() {
            if (launcherLoader.item) launcherLoader.item.toggle();
            else { root._launcherPending = "toggle"; launcherLoader.active = true }
        }
        function open(prefix) {
            if (launcherLoader.item) launcherLoader.item.open(prefix);
            else { root._launcherPending = "open"; root._launcherPrefix = prefix || ""; launcherLoader.active = true }
        }
        function close() { if (launcherLoader.item) launcherLoader.item.close() }
    }

    // Visual clipboard manager (Super+V) + Emoji picker (Super+.) — lazy loaded on first open.
    property string _clipPending: ""
    property string _clipTab: "history"
    Loader {
        id: clipLoader
        asynchronous: true; active: false
        source: Qt.resolvedUrl("ClipboardPanel.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._clipPending === "toggle") item.toggle(root._clipTab);
            else if (root._clipPending === "open") item.open(root._clipTab);
            root._clipPending = "";
        }
    }
    Connections {
        target: clipLoader.item
        enabled: clipLoader.item !== null
        function onClosed() { coolTimer.restart() }
    }
    function toggleClipboard(tab) {
        if (clipLoader.item) clipLoader.item.toggle(tab || "history");
        else { root._clipPending = "toggle"; root._clipTab = tab || "history"; clipLoader.active = true }
    }
    function openClipboard(tab) {
        if (clipLoader.item) clipLoader.item.open(tab || "history");
        else { root._clipPending = "open"; root._clipTab = tab || "history"; clipLoader.active = true }
    }
    IpcHandler {
        target: "clipboard"
        function toggle(): void { root.toggleClipboard("history") }
        function open(): void { root.openClipboard("history") }
        function pins(): void { root.toggleClipboard("pins") }
        function emoji(): void { root.toggleClipboard("emoji") }
        function close(): void { if (clipLoader.item) clipLoader.item.close() }
    }

    // Instant Scratchpad / Markdown Notes (Super+Alt+N) — lazy loaded
    property string _notesPending: ""
    Loader {
        id: notesLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("ScratchNotes.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._notesPending === "toggle") item.toggle();
            else if (root._notesPending === "open") item.open();
            root._notesPending = "";
        }
    }
    Connections { target: notesLoader.item; enabled: notesLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "notes"
        function toggle(): void { if (notesLoader.item) notesLoader.item.toggle(); else { root._notesPending = "toggle"; notesLoader.active = true } }
        function open(): void   { if (notesLoader.item) notesLoader.item.open();   else { root._notesPending = "open";   notesLoader.active = true } }
        function close(): void  { if (notesLoader.item) notesLoader.item.close() }
    }

    // File Drop Shelf & Instant QR Share (Super+Alt+S) — lazy loaded
    property string _dropPending: ""
    Loader {
        id: dropLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("DropShelf.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._dropPending === "toggle") item.toggle();
            else if (root._dropPending === "open") item.open();
            root._dropPending = "";
        }
    }
    Connections { target: dropLoader.item; enabled: dropLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "dropzone"
        function toggle(): void { if (dropLoader.item) dropLoader.item.toggle(); else { root._dropPending = "toggle"; dropLoader.active = true } }
        function open(): void   { if (dropLoader.item) dropLoader.item.open();   else { root._dropPending = "open";   dropLoader.active = true } }
        function close(): void  { if (dropLoader.item) dropLoader.item.close() }
    }

    // Color Studio & Eyedropper History (Super+Alt+C) — lazy loaded
    property string _colorPending: ""
    Loader {
        id: colorLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("ColorStudio.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._colorPending === "toggle") item.toggle();
            else if (root._colorPending === "open") item.open();
            root._colorPending = "";
        }
    }
    Connections { target: colorLoader.item; enabled: colorLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "colors"
        function toggle(): void { if (colorLoader.item) colorLoader.item.toggle(); else { root._colorPending = "toggle"; colorLoader.active = true } }
        function open(): void   { if (colorLoader.item) colorLoader.item.open();   else { root._colorPending = "open";   colorLoader.active = true } }
        function close(): void  { if (colorLoader.item) colorLoader.item.close() }
    }

    // Workspace App Sessions (Super+Alt+L) — lazy loaded
    property string _sessionsPending: ""
    Loader {
        id: sessionsLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("SessionsPanel.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._sessionsPending === "toggle") item.toggle();
            else if (root._sessionsPending === "open") item.open();
            root._sessionsPending = "";
        }
    }
    Connections { target: sessionsLoader.item; enabled: sessionsLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "sessions"
        function toggle(): void { if (sessionsLoader.item) sessionsLoader.item.toggle(); else { root._sessionsPending = "toggle"; sessionsLoader.active = true } }
        function open(): void   { if (sessionsLoader.item) sessionsLoader.item.open();   else { root._sessionsPending = "open";   sessionsLoader.active = true } }
        function close(): void  { if (sessionsLoader.item) sessionsLoader.item.close() }
    }

    // Screen Ruler & Pixel Measurer (Super+Alt+R) — lazy loaded
    property string _rulerPending: ""
    Loader {
        id: rulerLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("ScreenRuler.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._rulerPending === "toggle") item.toggle();
            else if (root._rulerPending === "open") item.open();
            root._rulerPending = "";
        }
    }
    Connections { target: rulerLoader.item; enabled: rulerLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "ruler"
        function toggle(): void { if (rulerLoader.item) rulerLoader.item.toggle(); else { root._rulerPending = "toggle"; rulerLoader.active = true } }
        function open(): void   { if (rulerLoader.item) rulerLoader.item.open();   else { root._rulerPending = "open";   rulerLoader.active = true } }
        function close(): void  { if (rulerLoader.item) rulerLoader.item.close() }
    }

    // Screen OCR -> Instant Translate (Super+Shift+T) — lazy loaded
    property string _transPending: ""
    Loader {
        id: transLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("TranslatePopup.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.uiFor = root.uiFor;
            if (root._transPending === "ocr") item.openOcr();
            else if (root._transPending === "toggle") item.toggle();
            else if (root._transPending === "open") item.open();
            root._transPending = "";
        }
    }
    Connections { target: transLoader.item; enabled: transLoader.item !== null; function onClosed() { coolTimer.restart() } }
    IpcHandler {
        target: "translate"
        function ocr(): void    { if (transLoader.item) transLoader.item.openOcr(); else { root._transPending = "ocr";    transLoader.active = true } }
        function toggle(): void { if (transLoader.item) transLoader.item.toggle();  else { root._transPending = "toggle"; transLoader.active = true } }
        function open(): void   { if (transLoader.item) transLoader.item.open();    else { root._transPending = "open";   transLoader.active = true } }
        function close(): void  { if (transLoader.item) transLoader.item.close() }
    }

    // Power menu — same lazy rule. SUPER+ESC pays a short first-open compile once.
    property string _powerPending: ""
    Loader {
        id: powerLoader
        asynchronous: true; active: false
        source: Qt.resolvedUrl("PowerMenu.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.sticker = root.stickerUrl(root.cfgStickerPower);
            if (root._powerPending === "toggle") item.toggle();
            else if (root._powerPending === "open") item.open();
            root._powerPending = "";
        }
    }
    QtObject {
        id: powerMenu
        readonly property bool shown: !!(powerLoader.item && powerLoader.item.shown)
        function toggle() {
            if (powerLoader.item) powerLoader.item.toggle();
            else { root._powerPending = "toggle"; powerLoader.active = true }
        }
        function open() {
            if (powerLoader.item) powerLoader.item.open();
            else { root._powerPending = "open"; powerLoader.active = true }
        }
        function close() { if (powerLoader.item) powerLoader.item.close() }
    }
    // Keep the sticker current if the profile changes after first load.
    onCfgStickerPowerChanged: if (powerLoader.item) powerLoader.item.sticker = root.stickerUrl(root.cfgStickerPower)

    // ---------- polkit: the shell answers "allow this change?" itself ----------
    // Only one agent can serve a session. hyprpolkitagent is no longer started at login; if
    // registering here fails anyway (something else already holds the session), it is started
    // as before so a prompt is never left with nobody to answer it.
    PolkitAgent { id: polkitAgent }
    property bool _polkitLive: !!polkitAgent.flow && !polkitAgent.flow.isCompleted
    property bool _polkitHeld: false
    on_PolkitLiveChanged: {
        if (root._polkitLive) { polkitHoldTimer.stop(); root._polkitHeld = true }
        else polkitHoldTimer.restart();
    }
    Timer { id: polkitHoldTimer; interval: 220; onTriggered: { root._polkitHeld = false; coolTimer.restart() } }
    Loader {
        id: polkitLoader
        active: root._polkitLive || root._polkitHeld
        source: Qt.resolvedUrl("PolkitDialog.qml")
    }
    Binding { when: polkitLoader.item !== null; target: polkitLoader.item; property: "flow"; value: polkitAgent.flow }
    Binding { when: polkitLoader.item !== null; target: polkitLoader.item; property: "profile"; value: root.userProfile }
    Timer { interval: 4000; running: true
        onTriggered: if (!polkitAgent.isRegistered)
            Quickshell.execDetached(["sh", "-c", "pgrep -x hyprpolkitagent >/dev/null || { [ -x /usr/lib/hyprpolkitagent/hyprpolkitagent ] && exec /usr/lib/hyprpolkitagent/hyprpolkitagent; }"]) }
    IpcHandler { target: "polkit"
        function registered(): bool { return polkitAgent.isRegistered }
        function cancel(): void { if (polkitAgent.flow) polkitAgent.flow.cancelAuthenticationRequest() } }
    // Which screen the window with the keyboard is on; the bars use it to decide which one shows
    // that window's title and menu. Falls back to the focused monitor when it cannot be told.
    readonly property string activeWinMonitor: {
        try {
            var t = Hyprland.activeToplevel;
            if (t && t.workspace && t.workspace.monitor && t.workspace.monitor.name) return "" + t.workspace.monitor.name;
            var o = t ? t.lastIpcObject : null;
            if (o && o.monitor !== undefined) {
                var ms = Hyprland.monitors.values;
                for (var i = 0; i < ms.length; i++) if (ms[i].id === o.monitor) return "" + ms[i].name;
            }
        } catch (e) {}
        return Hyprland.focusedMonitor ? "" + Hyprland.focusedMonitor.name : "";
    }
    IpcHandler { target: "power"
        function toggle(): void { powerMenu.toggle() }
        function open(): void { powerMenu.open() }
        function close(): void { powerMenu.close() } }
    // ---------- the desktop ----------
    // Bottom layer, one per monitor, above the wallpaper and below every window. Empty
    // until something is put on it, which is why it can simply be on: an empty desktop
    // draws nothing and — because its input region is its widgets — takes no clicks either.
    property bool desktopEditing: false
    readonly property string desktopScript: Qt.resolvedUrl("sea-desktop.py").toString().replace("file://","")
    Process { id: desktopProc }
    // The arrangement file must exist before anything can watch it changing.
    Process {
        id: desktopEnsure
        command: ["python3", root.desktopScript, "--ensure"]
        running: true
    }
    function desktopRun(args) {
        desktopProc.command = ["python3", root.desktopScript].concat(args);
        desktopProc.running = true;
    }
    // The widgets live on a full-screen layer. While a window already covers that
    // screen they are not visible, and the layer plus five widget trees is a large
    // part of the idle footprint. The arrangement file is what brings them back.
    property int desktopCoverGen: 0
    Timer { interval: 800; running: !root.desktopEditing && !root.gameOn; repeat: true; triggeredOnStart: true
        onTriggered: root.desktopCoverGen++ }
    readonly property bool desktopCovered: {
        var _ = root.desktopCoverGen;
        var screens = Quickshell.screens;
        if (!screens.length) return false;
        var tops = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var mons = Hyprland.monitors ? Hyprland.monitors.values : [];
        for (var s = 0; s < screens.length; s++) {
            var scr = screens[s], hit = false, aws = -999;
            for (var q = 0; q < mons.length; q++)
                if (mons[q].name === scr.name && mons[q].activeWorkspace) aws = mons[q].activeWorkspace.id;
            for (var i = 0; i < tops.length; i++) {
                var t = tops[i];
                if (!t || !t.monitor || t.monitor.name !== scr.name) continue;
                if (t.workspace && t.workspace.id !== undefined && t.workspace.id !== aws) continue;
                var o = null;
                try { o = t.lastIpcObject; } catch (e) { o = null; }
                if (!o || o.hidden || o.floating) continue;
                if (o.fullscreen > 0) { hit = true; break; }
                var ww = (o.size && o.size[0]) || 0, wh = (o.size && o.size[1]) || 0;
                if (ww * wh > scr.width * scr.height * 0.82) { hit = true; break; }
            }
            if (!hit) return false;
        }
        return true;
    }
    Variants {
        model: (!root.gameOn && !(root.desktopCovered && !root.desktopEditing)) ? Quickshell.screens : []
        Desktop {
            required property var modelData
            screen: modelData
            pal: theme
            uiFont: Tok.sans
            ui: root.uiFor(modelData)
            editing: root.desktopEditing
            suspended: root.gameOn
            seen: root.desktopSeen || root.desktopEditing
            // right-click on the desktop while arranging: finish, and close the gallery with it
            onDoneRequested: { root.desktopEditing = false; root.widgetsScreen = "" }
            // One bound object rather than a property per reading: the desktop is a viewer,
            // and every widget that lands here later should be a change to Desktop.qml, not
            // another wire through the bar.
            readings: ({
                "wxTemp": root.wxTemp, "wxCond": root.wxCond, "wxFeels": root.wxFeels, "wxHumid": root.wxHumid,
                "wxWind": root.wxWind, "wxForecast": root.wxForecast, "wxLoc": root.wxLoc,
                "cpu": root.cpuUsage, "cpuTemp": root.cpuTemp,
                "memPct": root.memPct, "memUsed": root.memUsed, "memTotal": root.memTotal,
                "gpuName": root.gpuName, "gpu": root.gpuUsage, "gpuTemp": root.gpuTemp,
                "netRx": root.netRx, "netTx": root.netTx,
                "calEvents": root.calUpcoming.slice(0, 8),
                "batteries": root.widgetBatteries, "batEta": root.widgetBatEta,
                "ssid": root.ssid, "wifiOn": root.wifiOn, "wifiSig": root.wifiSig, "netIf": root.netIf,
                "notes": root.widgetNotes, "noteCount": root.notes.length, "dnd": root.dnd,
                "aiUsage": root.aiShownUsage, "aiLive": root.aiLive, "aiDigits": root.cfgAiDigits,
                "github": root.github, "timer": root.timerReading, "clips": root.widgetClips,
                "privacy": root.privacyLabel !== "", "batPct": root.widgetBatteries.length ? root.widgetBatteries[0].p : 100,
                "bottles": root.bottleFloating.length
            })
            player: root.player
            // The same bars the media pill draws — real cava, or the ambient wave in
            // bit-perfect mode. One source, so the desktop and the bar never disagree
            // about what the music is doing.
            viz: root.vizBars
            // Nothing is ever parked under the bar, or under where the dock appears.
            insetTop: root.cfgEdge === "top" ? root.cfgHeight + 6 : 6
            insetBottom: root.cfgEdge === "bottom" ? root.cfgHeight + 6 : (root.cfgDock ? 78 : 6)
        }
    }
    property string widgetsScreen: ""
    // the gallery is where widgets are arranged, so the desktop arranges while it is open
    onWidgetsScreenChanged: {
        root.desktopEditing = root.widgetsScreen !== "";
        if (root.widgetsScreen !== "") root.closePanels();
    }
    function toggleWidgets() {
        var focused = Hyprland.focusedMonitor;
        var name = focused ? focused.name : (Quickshell.screens.length ? Quickshell.screens[0].name : "");
        root.widgetsScreen = root.widgetsScreen === name ? "" : name;
    }
    IpcHandler { target: "widgets"; function toggle(): void { root.toggleWidgets() } function close(): void { root.widgetsScreen = "" } }
    Variants {
        // Built after Settings (see lateReady): it is only ever used while arranging, and it
        // was 0.7s of the time between login and a visible bar.
        model: root.lateReady ? Quickshell.screens : []
        WidgetsDrawer {
            required property var modelData
            screen: modelData; ui: root.uiFor(modelData)
            opened: root.widgetsScreen === modelData.name
            edgeEnabled: {
                if (root.gameOn) return false;
                var win = Hyprland.activeToplevel;
                var obj = win ? win.lastIpcObject : null;
                return !(obj && obj.fullscreen > 0);
            }
            readings: ({ wxTemp: root.wxTemp, wxCond: root.wxCond, wxFeels: root.wxFeels, wxHumid: root.wxHumid, wxWind: root.wxWind,
                         wxForecast: root.wxForecast, wxLoc: root.wxLoc, cpu: root.cpuUsage, cpuTemp: root.cpuTemp,
                         memPct: root.memPct, memUsed: root.memUsed, memTotal: root.memTotal,
                         gpuName: root.gpuName, gpu: root.gpuUsage, gpuTemp: root.gpuTemp, netRx: root.netRx,
                         calEvents: root.calUpcoming.slice(0, 8), batteries: root.widgetBatteries, batEta: root.widgetBatEta,
                         netTx: root.netTx, ssid: root.ssid, wifiOn: root.wifiOn, wifiSig: root.wifiSig, netIf: root.netIf,
                         notes: root.widgetNotes, noteCount: root.notes.length, dnd: root.dnd, aiUsage: root.aiShownUsage, aiLive: root.aiLive, aiDigits: root.cfgAiDigits,
                         github: root.github, timer: root.timerReading, clips: root.widgetClips,
                         privacy: root.privacyLabel !== "", batPct: root.widgetBatteries.length ? root.widgetBatteries[0].p : 100,
                         bottles: root.bottleFloating.length })
            player: root.player; viz: root.vizBars
            insetTop: root.cfgEdge === "top" ? root.cfgHeight + 6 : 6
            insetBottom: root.cfgEdge === "bottom" ? root.cfgHeight + 6 : (root.cfgDock ? 78 : 6)
            onRequested: open => { root.widgetsScreen = open ? modelData.name : ""; if (open) root.openPop = "" }
            onSettingsRequested: root.openSettings(21)
        }
    }
    IpcHandler {
        target: "desktop"
        function arrange(): void { root.desktopEditing = !root.desktopEditing }
        // Explicit on/off as well as the toggle: a checkbox in Settings that only knows how
        // to flip goes out of step the first time the mode is changed from anywhere else.
        function start(): void { root.desktopEditing = true }
        function done(): void { root.desktopEditing = false }
        function addClock(): void { root.desktopRun(["--add-clock"]) }
        function addApp(exec: string, label: string): void {
            root.desktopRun(["--add-app", exec, "--label", label]);
        }
        function remove(id: string): void { root.desktopRun(["--remove", id]) }
        function clear(): void { root.desktopRun(["--clear"]) }
        function tidy(): void { root.desktopRun(["--tidy"]) }
    }
    IpcHandler {
        target: "launcher"
        function toggle(): void { launcher.toggle() }
        function clipboard(): void { launcher.open(";") }
        function open(prefix: string): void { launcher.open(prefix || "") }
        function bottle(): void { launcher.open("!") }
    }

    // ---------- the sea menu (the logo) ----------
    //
    // The mark used to be a second way to open the launcher, which SUPER+Space and
    // CTRL+Space already do. In a bar that now draws the focused window's menus, the
    // leftmost item is where the SYSTEM's menu belongs — the same place, and the same job,
    // as the apple on a mac: who am I, my settings, and the ways this session ends. The
    // launcher stays on the list because taking a click away from someone is rude.
    readonly property string seaScripts: Quickshell.env("HOME") + "/.config/quickshell/sea-shell/"
    // EVERY ROW SAYS HOW ELSE TO GET THERE. A system menu that only works with the pointer
    // teaches nothing; one that prints the keybind beside each entry is how people stop
    // needing it. The shortcuts are the real ones from keybinds.lua, not a wish list.
    //
    // NO TRAILING DOTS AT ALL. The convention is real — an ellipsis means "this one asks you
    // something first" — but here it distinguished almost nothing (nearly every row opens
    // something) while the bar font rendered it as three dots hovering at mid-height, well
    // clear of the word they belong to. It was noise that read as a rendering fault, so the
    // shortcut column carries the information instead.
    readonly property var seaMenuItems: [
        { id: "about",    label: "About sea-shell",  icon: "" },
        { id: "settings", label: "Settings",      icon: "tune",             key: "Super+S" },
        { sep: true },
        { id: "dash",     label: "Dashboard",        icon: "space_dashboard",  key: "Super+D" },
        { id: "wall",     label: "Wallpaper",     icon: "wallpaper",        key: "Super+Shift+W" },
        { id: "keys",     label: "Keybinds",      icon: "keyboard",         key: "Super+K" },
        { sep: true },
        { id: "launcher", label: "Applications",  icon: "apps",             key: "Super+Space" },
        { sep: true },
        { id: "lock",     label: "Lock Screen",      icon: "lock",             key: "Super+Alt+L" },
        { id: "sleep",    label: "Sleep",            icon: "bedtime" },
        { id: "power",    label: "Power",         icon: "power_settings_new", key: "Super+Esc" }
    ]
    function seaMenuRun(id) {
        root.openPop = "";
        // openTab, not open(): settings.qml's root exposes openPanel/openTab/closePanel and has
        // never had an open() — calling it threw a TypeError and the item simply did nothing.
        // The two land on different tabs on purpose. System (8) IS the about page — it carries
        // the version badge — so pointing "Settings…" there as well would give the menu two
        // items that do exactly the same thing; it opens Appearance instead, and the nav down
        // the side of the panel is right there for everything else.
        if (id === "about")    { root.openSettings(8); return }
        if (id === "settings") { root.openSettings(4); return }
        if (id === "launcher") { launcher.toggle(); return }
        var sh = function (c) { Quickshell.execDetached(["sh", "-c", c]) };
        if (id === "dash")  root.toggleDashboard();
        if (id === "wall")  sh(root.seaScripts + "sea-toggle.sh wallpaper");
        if (id === "keys")  sh(root.seaScripts + "sea-toggle.sh keybinds");
        if (id === "lock")  sh(root.seaScripts + "sea-lock.sh");
        if (id === "sleep") sh("systemctl suspend");
        // Restart / shut down / log out live behind the power menu, which asks first.
        // A shut-down that fires straight off a menu click is how you lose work.
        if (id === "power") sh(root.seaScripts + "sea-toggle.sh power");
    }

    // ---------- the global menu, from the keyboard ----------
    // A menu bar that can only be reached with the pointer is half a menu bar, and the strip
    // lives on whichever monitor has focus — which is not something an IpcHandler out here
    // can address directly, because each bar builds its own GlobalMenu inside a per-screen
    // delegate. So the request is a counter that every strip watches; the one that is on the
    // focused screen acts on it and the rest ignore it. A counter rather than a bool because
    // two presses in a row have to be two events.
    property int gmenuOpenPing: 0
    property int gmenuSearchPing: 0
    IpcHandler {
        target: "menu"
        // open the focused window's menu bar at its first menu (SUPER+M)
        function open(): void { root.gmenuOpenPing++ }
        // go straight to the command search over it (SUPER+SHIFT+M)
        function search(): void { root.gmenuSearchPing++ }
        // the system menu under the mark, the way ctrl-F2 reaches the apple menu
        function sea(): void {
            root.openPop = (root.openPop === "sea") ? "" : "sea";
        }
    }

    // resident settings (control center) — preloaded so opening is instant instead of spawning
    // a ~0.5s `qs -p settings.qml`. Toggle via its own "settings" IPC (SUPER+S) or, in-process,
    // root.openSettings(n).
    //
    // NOT LOADED UNTIL THE BAR IS UP. `asynchronous` did not keep it off the startup path: the
    // shell is not "loaded" — and nothing is on screen — until every Loader started during
    // construction has finished, and compiling settings.qml is ~3s that no cache can save
    // (Quickshell serves the config from qs:@/ URLs, which Qt's disk cache does not cover).
    // That was half of a six-second login. So the bar comes first and the rest follows in a
    // chain: settings, then the welcome tour and the widget drawer.
    //
    // Settings / dashboard / screenshot stay unloaded until asked for. Preloading them on
    // idle used to cost well over 100 MB while closed (Phase 3 efficiency plan). First open
    // pays a short async compile; after that the Loader keeps them warm.
    property bool lateReady: false
    property int pendingSettingsTab: -1
    // WidgetsDrawer waits on lateReady; welcome needs to be up early to decide first-run /
    // what's-new. Neither needs the 4k-line settings tree.
    Timer {
        interval: 2000; running: true
        onTriggered: {
            root.lateReady = true;
            welcomeLoader.active = true;
        }
    }
    Loader {
        id: settingsLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("settings.qml")
        onStatusChanged: {
            if (status !== Loader.Ready && status !== Loader.Error) return;
            if (status === Loader.Ready && root.pendingSettingsTab >= 0) item.openTab(root.pendingSettingsTab);
            root.pendingSettingsTab = -1;
        }
    }

    // The first-run tour. Loaded shortly after the bar so a new install still sees the tour,
    // then dropped again if it has nothing to show. IPC stays here so the target exists
    // while the QML is cold.
    property string _welcomePending: ""
    Loader {
        id: welcomeLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("welcome.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            if (root._welcomePending === "open") item.open();
            else if (root._welcomePending === "toggle") { if (item.shown) item.close(); else item.open() }
            else if (root._welcomePending === "close") item.close();
            root._welcomePending = "";
            welcomeCool.restart();
        }
    }
    IpcHandler {
        target: "welcome"
        function open(): void {
            if (welcomeLoader.item) welcomeLoader.item.open();
            else { root._welcomePending = "open"; welcomeLoader.active = true }
        }
        function close(): void {
            if (welcomeLoader.item) welcomeLoader.item.close();
            else root._welcomePending = "";
        }
        function toggle(): void {
            if (welcomeLoader.item) { if (welcomeLoader.item.shown) welcomeLoader.item.close(); else welcomeLoader.item.open() }
            else { root._welcomePending = "toggle"; welcomeLoader.active = true }
        }
    }
    Timer { id: welcomeCool; interval: 12000; onTriggered: root.coolPanels() }
    // The dashboard (SUPER+D). Loads on first open; stays warm after that.
    // One desktop arrangement per set of displays (sea-setups.py): when a monitor comes or goes,
    // the widgets, dock and bar placement you had last time on this set come back. Settled for
    // three seconds first, because docking brings displays up one at a time.
    Timer { id: setupSwitch; interval: 3000; running: true
        onTriggered: Quickshell.execDetached(["python3", root.seaScripts + "sea-setups.py", "--switch"]) }
    Connections { target: Quickshell; function onScreensChanged() { setupSwitch.restart() } }
    property bool pendingDash: false
    property string pendingDashTab: ""
    Loader {
        id: dashLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("DashboardPanel.qml")
        onStatusChanged: if (status === Loader.Ready && root.pendingDash) {
            root.pendingDash = false;
            var tab = root.pendingDashTab; root.pendingDashTab = "";
            item.open(tab || "");
        }
    }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "liveGameId"
        value: root.gameLive && root.gameLive.appid ? "" + root.gameLive.appid : "" }
    function toggleDashboard() {
        if (dashLoader.item) dashLoader.item.toggle();
        else { root.pendingDashTab = ""; root.pendingDash = true; dashLoader.active = true }
    }
    function openDashboardGaming() {
        root.openPop = "";
        if (dashLoader.item) dashLoader.item.open("gaming");
        else { root.pendingDashTab = "gaming"; root.pendingDash = true; dashLoader.active = true }
    }
    function openDashboardDev() {
        root.openPop = "";
        if (dashLoader.item) dashLoader.item.open("dev");
        else { root.pendingDashTab = "dev"; root.pendingDash = true; dashLoader.active = true }
    }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "github"
        value: root.github }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "aiTools"
        value: root.aiTools }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "aiShown"
        value: root.aiShown }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "aiBarValue"
        value: root.aiBarValue }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "player"
        value: root.player }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "powerProfile"
        value: root.powerProfile }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "netRx"
        value: root.netRx }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "netTx"
        value: root.netTx }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "batPct"
        value: (UPower.displayDevice && UPower.displayDevice.isLaptopBattery) ? Math.round((UPower.displayDevice.percentage || 0) * 100) : -1 }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "batCharging"
        value: !UPower.onBattery }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "batRate"
        value: (UPower.displayDevice && UPower.displayDevice.isLaptopBattery) ? (UPower.displayDevice.changeRate || 0) : 0 }
    Binding { when: dashLoader.item !== null; target: dashLoader.item; property: "batEta"
        value: root.widgetBatEta }
    Connections {
        target: dashLoader.item
        enabled: dashLoader.item !== null
        function onFocusAi(id) { root.setAiFocus(id) }
        function onSetPowerProfile(p) { root.setProfile(p) }
    }
    IpcHandler { target: "dashboard"
        function toggle(): void { root.toggleDashboard() }
        function close(): void { if (dashLoader.item) dashLoader.item.close() }
        function gaming(): void { root.openDashboardGaming() }
        function dev(): void { root.openDashboardDev() } }
    // ---------- big picture ----------
    // The console mode, opened from the Gaming tab or the controller's home button. sea-gamepad.py
    // runs all the time because that button has to work from the desktop; it lets go of the
    // devices while a game is up. While this mode is the screen in front, it holds the pads
    // so Steam's own Big Picture does not move as well. The mode itself is only built the first time it is opened.
    property bool pendingBigPicture: false
    property var bigPictureCfg: ({ screen: "auto", other: "black", home: true, sfx: "on" })
    property var gamepads: []
    // pause: a game has the pad. relay: Steam Big Picture has it, except home. grab: this screen.
    readonly property string gamepadMode: {
        var bp = bigPictureLoader.item;
        if (root.gameLive !== null || (bp && bp.shown && bp.gameShowing)) return "pause";
        if (bp && bp.shown && bp.steamHandoff) return "relay";
        if (bp && bp.shown) return "grab";
        return "ungrab";
    }
    onGamepadModeChanged: if (gamepadProc.running) gamepadProc.write(root.gamepadMode + "\n")
    FileView {
        id: bigPictureFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/bigpicture.json"
        printErrors: false
        onLoaded: {
            try { root.bigPictureCfg = Object.assign({}, root.bigPictureCfg, JSON.parse(text())); } catch (e) {}
        }
    }
    function setBigPictureCfg(patch) {
        root.bigPictureCfg = Object.assign({}, root.bigPictureCfg, patch);
        bigPictureFile.setText(JSON.stringify(root.bigPictureCfg));
    }
    Loader {
        id: bigPictureLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("BigPicture.qml")
        onStatusChanged: if (status === Loader.Ready && root.pendingBigPicture) {
            root.pendingBigPicture = false;
            item.open();
        }
    }
    Binding { when: bigPictureLoader.item !== null; target: bigPictureLoader.item; property: "cfg"; value: root.bigPictureCfg }
    Binding { when: bigPictureLoader.item !== null; target: bigPictureLoader.item; property: "pads"; value: root.gamepads }
    Connections {
        target: bigPictureLoader.item
        function onSetCfg(patch) { root.setBigPictureCfg(patch) }
    }
    function openBigPicture() {
        if (bigPictureLoader.item) bigPictureLoader.item.open();
        else { root.pendingBigPicture = true; bigPictureLoader.active = true }
    }
    IpcHandler { target: "bigpicture"
        function open(): void { root.openBigPicture() }
        function close(): void { if (bigPictureLoader.item) bigPictureLoader.item.close() }
        function toggle(): void { if (bigPictureLoader.item && bigPictureLoader.item.shown) bigPictureLoader.item.close(); else root.openBigPicture() }
        // A pad button by name (a, b, x, y, up, down, left, right, l, r, menu, view, home), for
        // scripts and testing: the same path sea-gamepad.py's presses take.
        function press(button: string): void {
            if (!bigPictureLoader.item) return;
            bigPictureLoader.item.press(button);
            bigPictureLoader.item.release(button);
        } }
    function gamepadLine(line) {
        var m;
        try { m = JSON.parse(line); } catch (e) { return; }
        if (m.t === "pads") { root.gamepads = m.pads; return; }
        if (m.t === "error") { gamepadRestart.stop(); root.gamepadGiveUp = true; return; }
        var bp = bigPictureLoader.item;
        if (bp && bp.shown) {
            if (m.t === "press") bp.press(m.b);
            else if (m.t === "release") bp.release(m.b);
        // Not over a game that is running, which is where Steam's own overlay expects that button.
        } else if (m.t === "press" && m.b === "home" && root.bigPictureCfg.home !== false && root.gameLive === null) {
            root.openDashClosed();
            root.openBigPicture();
        }
    }
    function openDashClosed() { if (dashLoader.item) dashLoader.item.close(); }
    property bool gamepadGiveUp: false
    Process {
        id: gamepadProc
        // sea-gamepad.sh prefers the Rust binary when present; SEA_GAMEPAD_PY=1 forces Python.
        command: ["sh", Qt.resolvedUrl("sea-gamepad.sh").toString().replace("file://", "")]
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.gamepadLine(data) }
        onExited: if (!root.gamepadGiveUp) gamepadRestart.restart()
        onStarted: gamepadProc.write(root.gamepadMode + "\n")
    }
    Timer { id: gamepadRestart; interval: 5000; onTriggered: gamepadProc.running = true }
    // After the bar has had its turn at startup.
    Timer { interval: 3000; running: true; onTriggered: gamepadProc.running = true }

    // The screenshot picker (Print), resident for the same reason and on the same chain.
    property bool pendingShot: false
    Loader {
        id: shotLoader; asynchronous: true; active: false; source: Qt.resolvedUrl("ScreenshotPanel.qml")
        onStatusChanged: if (status === Loader.Ready && root.pendingShot) { root.pendingShot = false; item.open() }
    }
    IpcHandler { target: "screenshot"
        function toggle(): void {
            if (shotLoader.item) shotLoader.item.toggle();
            else { root.pendingShot = true; shotLoader.active = true }
        }
        function close(): void { if (shotLoader.item) shotLoader.item.close() } }

    // Asked for before it has finished loading: remembered, and opened when it lands.
    function openSettings(tab) {
        if (settingsLoader.item) settingsLoader.item.openTab(tab);
        else { root.pendingSettingsTab = tab; settingsLoader.active = true }
    }
    // The panel used to own this target, which meant it could not be unloaded: SUPER+S
    // would have had nothing to call. The shell keeps the target and builds the panel
    // on the first call.
    IpcHandler {
        target: "settings"
        function toggle(): void {
            if (settingsLoader.item) settingsLoader.item.togglePanel();
            else root.openSettings(8);
        }
        function open(): void { root.openSettings(8) }
        function openTab(requestedTab: int): void { root.openSettings(requestedTab) }
        function close(): void { if (settingsLoader.item) settingsLoader.item.closePanel() }
    }

    // Screen recorder chooser — lazy like launcher/power. SUPER+R IPC lives here so
    // it works while the panel is cold; stop/cancel never need the QML loaded.
    readonly property string recScript: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "") + "/sea-record.sh"
    property string _recPending: ""
    Loader {
        id: recLoader
        asynchronous: true; active: false
        source: Qt.resolvedUrl("RecorderPanel.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            item.recording = root.recordingActive;
            item.exclusiveHold = root.exclusiveHold;
            item.exclusiveName = root.exclHolder;
            if (root._recPending === "toggle") item.toggle();
            else if (root._recPending === "open") item.open();
            root._recPending = "";
        }
    }
    Binding { when: recLoader.item !== null; target: recLoader.item; property: "recording"; value: root.recordingActive }
    Binding { when: recLoader.item !== null; target: recLoader.item; property: "exclusiveHold"; value: root.exclusiveHold }
    Binding { when: recLoader.item !== null; target: recLoader.item; property: "exclusiveName"; value: root.exclHolder }
    QtObject {
        id: recPanel
        readonly property bool shown: !!(recLoader.item && recLoader.item.shown)
        function toggle() {
            if (root.recordingActive) { stop(); return }
            if (recLoader.item) recLoader.item.toggle();
            else { root._recPending = "toggle"; recLoader.active = true }
        }
        function open() {
            if (root.recordingActive) return;
            if (recLoader.item) recLoader.item.open();
            else { root._recPending = "open"; recLoader.active = true }
        }
        function close() { if (recLoader.item) recLoader.item.close() }
        function stop() { Quickshell.execDetached([root.recScript, "stop"]) }
        function cancel() { Quickshell.execDetached([root.recScript, "cancel"]) }
    }
    IpcHandler {
        target: "recorder"
        function toggle(): void { recPanel.toggle() }
        function open(): void { recPanel.open() }
        function close(): void { recPanel.close() }
        function stop(): void { recPanel.stop() }
        function cancel(): void { recPanel.cancel() }
    }
    // ---------- one panel at a time ----------
    // Each panel is its own overlay and knows nothing of the others, so SUPER+D over Settings
    // over the launcher stacked all three. Whichever opens last closes the rest, and the bar's
    // dropdowns and the widgets drawer with them.
    // The screenshot picker never closes anything: what it is for is capturing what is open.
    // Big picture is only ever the one closing: leaving it hands the pads back and restores the
    // screens, which is not something a stray keybind should do.
    function panelList() {
        return [
            { name: "dashboard", item: dashLoader.item, close: function (p) { p.close() } },
            { name: "settings", item: settingsLoader.item, close: function (p) { p.closePanel() } },
            { name: "launcher", item: launcher, close: function (p) { p.close() } },
            { name: "power", item: powerMenu, close: function (p) { p.close() } },
            { name: "recorder", item: recPanel, close: function (p) { p.close() } },
            { name: "welcome", item: welcomeLoader.item, close: function (p) { p.close() } },
            { name: "screenshot", item: shotLoader.item, close: function (p) { p.close() } }
        ];
    }
    function panelOpened(name) {
        if (name === "screenshot") return;
        var list = root.panelList();
        for (var i = 0; i < list.length; i++) {
            var p = list[i];
            if (p.name !== name && p.item && p.item.shown) p.close(p.item);
        }
        root.openPop = "";
        root.widgetsScreen = "";
    }
    function closePanels() {
        var list = root.panelList();
        for (var i = 0; i < list.length; i++) {
            var p = list[i];
            if (p.name !== "screenshot" && p.item && p.item.shown) p.close(p.item);
        }
    }
    // Hold the outside-click grab until a lazy Drop registers (otherwise openPop is
    // cleared in the same frame the Loader starts). Backup timer covers a failed load.
    Timer { id: dropArmTimer; interval: 400; onTriggered: root.grabHold = false }
    onOpenPopChanged: {
        if (root.openPop !== "") {
            root.closePanels();
            root.grabHold = true;
            dropArmTimer.restart();
        } else {
            dropArmTimer.stop();
            root.grabHold = false;
            // Dropdown LazyLoaders unload via activeAsync once their 90ms close hold ends;
            // schedule a sweep so V4 GC releases the torn-down subtree promptly.
            gcTimer.restart();
        }
    }
    // Closed panels used to stay compiled for the rest of the session (settings alone is
    // well over 100 MB once built). Drop them a moment after they hide so a reopen
    // animation can finish, and so a second open in that window does not compile twice.
    Timer { id: coolTimer; interval: 2500; onTriggered: root.coolPanels() }
    Timer { id: gcTimer; interval: 450; onTriggered: gc() }
    function coolPanels() {
        var dropped = false;
        function drop(loader, live) {
            if (!loader || !loader.item || loader.status !== Loader.Ready || live) return;
            loader.active = false;
            dropped = true;
        }
        drop(settingsLoader, settingsLoader.item && settingsLoader.item.shown);
        drop(dashLoader, dashLoader.item && dashLoader.item.shown);
        drop(bigPictureLoader, bigPictureLoader.item && bigPictureLoader.item.shown);
        drop(launcherLoader, launcherLoader.item && launcherLoader.item.shown);
        drop(clipLoader, clipLoader.item && clipLoader.item.shown);
        drop(notesLoader, notesLoader.item && notesLoader.item.shown);
        drop(dropLoader, dropLoader.item && dropLoader.item.shown);
        drop(colorLoader, colorLoader.item && colorLoader.item.shown);
        drop(sessionsLoader, sessionsLoader.item && sessionsLoader.item.shown);
        drop(rulerLoader, rulerLoader.item && rulerLoader.item.shown);
        drop(transLoader, transLoader.item && transLoader.item.shown);
        drop(powerLoader, powerLoader.item && powerLoader.item.shown);
        drop(shotLoader, shotLoader.item && shotLoader.item.shown);
        drop(recLoader, (recLoader.item && recLoader.item.shown) || root.recordingActive);
        drop(welcomeLoader, welcomeLoader.item && welcomeLoader.item.shown);
        drop(wallStripLoader, wallStripLoader.item && wallStripLoader.item.shown);
        if (dropped) gcTimer.restart();
    }
    Connections { target: dashLoader.item; ignoreUnknownSignals: true
        function onShownChanged() { if (dashLoader.item.shown) root.panelOpened("dashboard"); else coolTimer.restart() } }
    Connections { target: settingsLoader.item; ignoreUnknownSignals: true
        function onShownChanged() { if (settingsLoader.item.shown) root.panelOpened("settings"); else coolTimer.restart() } }
    Connections { target: launcher
        function onShownChanged() { if (launcher.shown) root.panelOpened("launcher"); else coolTimer.restart() } }
    Connections { target: powerMenu
        function onShownChanged() { if (powerMenu.shown) root.panelOpened("power"); else coolTimer.restart() } }
    Connections { target: recPanel
        function onShownChanged() { if (recPanel.shown) root.panelOpened("recorder"); else coolTimer.restart() } }
    Connections { target: welcomeLoader.item; ignoreUnknownSignals: true
        function onShownChanged() { if (welcomeLoader.item.shown) root.panelOpened("welcome"); else coolTimer.restart() } }
    Connections { target: bigPictureLoader.item; ignoreUnknownSignals: true
        function onShownChanged() { if (bigPictureLoader.item.shown) root.panelOpened("bigpicture"); else coolTimer.restart() } }
    Connections { target: shotLoader.item; ignoreUnknownSignals: true
        function onShownChanged() { if (!shotLoader.item.shown) coolTimer.restart() } }

    // Opens a bar dropdown on the named screen's bar, or the focused one's.
    function openWidgetOn(name, screenName) {
        if (name === "") { root.openPop = ""; return; }
        if (["wifi","bt","vol","bat","cal","pwr","notif","cc","wx","sys","upd","kde","mpris","ai"].indexOf(name) < 0) return;
        var bars = root.grabWins.filter(function(w) { return w && w.widgetBar === true && w.visible; });
        var want = screenName || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "");
        var chosen = bars.find(function(w) { return want && w.screen && w.screen.name === want; }) || bars[0];
        if (chosen) { root.openBar = chosen; root.openPop = name; }
    }
    property string openPop: ""      // only one dropdown open at a time
    property var openBar: null       // …and only on the monitor whose pill was clicked
    // one shared click-outside grab covering every monitor's bar + dropdowns.
    // Screenshot tools "pin" the shell first — slurp/grim steal focus, and without
    // the hold the dropdown being screenshotted would close before the capture.
    property var grabWins: []
    property bool grabHold: false
    IpcHandler {
        target: "shell"
        // Public keyboard/automation entry point uses the same per-monitor menu state as pills.
        function openWidget(name: string): void { root.openWidgetOn(name, "") }
        // Settings owns its own "settings" target, which does not exist until it has loaded, up to
        // 30s after login. These go through the bar, which can load it and open it once it lands.
        function toggleSettings(): void {
            if (settingsLoader.item) settingsLoader.item.togglePanel();
            else root.openSettings(8);
        }
        function openSettingsTab(tab: int): void { root.openSettings(tab) }
        // The Notifications page shows these and asks here, so each keeps one owner.
        function setDnd(on: bool): void { root.setDnd(on) }
        function toggleMute(app: string): void { root.toggleMute(app) }
        function applyFocus(id: string): void { root.applyFocus(id || "clear") }
        function mediaTab(index: int): void { if (index >= 0 && index <= 2) root.mediaTab = index }
        function pin(): void { root.grabHold = true }
        function unpin(): void { root.grabHold = false }
        function toggleExpose(): void { root.toggleExpose() }
        function toggleIdle(): void { root.toggleIdle() }
        // Rebuilds everything in place (see below for why never a restart). This used to be a
        // second handler for "shell", and Quickshell keeps only one per target: that one won,
        // so pin, toggleExpose (SUPER+W), toggleIdle and openWidget all silently did nothing.
        function reload(): void { Quickshell.reload(true) }
    }

    // ---------- alt-tab window switcher (WindowSwitcher.qml) ----------
    WindowSwitcher { id: windowSwitcher; uiFor: root.uiFor }
    IpcHandler {
        target: "switcher"
        function next(): void { windowSwitcher.step(1) }
        function prev(): void { windowSwitcher.step(-1) }
        function commit(): void { windowSwitcher.commit() }
        function cancel(): void { windowSwitcher.cancel() }
    }

    // ---------- wallpaper switch transition ----------
    // swww/awww animate a static→static change themselves, but a change to or from a VIDEO
    // has no backend transition: the player has to open the new clip and decode a first frame.
    // Most of this user's library is video, so the backend transition almost never ran.
    //
    // The shell covers the seam with a full-screen layer, lets the swap happen behind it,
    // and uncovers once the new wallpaper is up — for a clip, on VideoWallpaper's ready().
    //
    // It used to do that by dipping to black, which states nothing except that something
    // stalled: the same darkness for next as for previous, and no way to tell a transition
    // from a hung process. It is now a PANEL THAT TRAVELS, entering from the side you are
    // coming from and leaving towards the side you are going to, so the direction of the
    // switch is in the motion. The picker's commit shares the vocabulary — see the slot in
    // wallpaper.qml; both are the shell's ground moving over a seam, not a light going out.
    property real wallPanelX: 1                // screen widths: +1/-1 = off-stage, 0 = covering
    property int  wallPanelDir: 1              // +1 next (enters from the right), -1 previous
    property bool wallPanelAnim: false         // off while the panel is parked off-stage
    // What it switched TO. The panel has to sit covered until the new wallpaper has put
    // a first frame up, and a blank hold is the whole reason this read as a stall: the eye is
    // given six hundred milliseconds and nothing to do with them. Naming the wallpaper turns
    // the wait into the answer to "which one did I just land on".
    property string wallPanelName: ""
    // True for exactly as long as the panel sits covered waiting on the daemon. Drives the
    // one honest thing that can be shown during a wait whose length is not ours to choose:
    // how much of it is left.
    property bool wallHold: false
    // Separate from `wallHold`, and later than it: the cartridge sits in view for a beat after
    // the panel lands before it goes in. Dropping it the instant the panel arrived meant the
    // one thing worth watching was over in 260ms of a 1.1s sequence, and the rest of the hold
    // went back to being a progress bar on an empty plate.
    property bool wallDrop: false
    Timer {
        id: wallDropTimer; interval: 170; repeat: false
        onTriggered: root.wallDrop = true
    }
    // Gated on the thumbnail, not on a timer: the cartridge holds until there is a picture in
    // it, then goes in. A blank frame dropping into a slot is worse than no cartridge at all.
    onWallPanelThumbChanged: if (root.wallPanelThumb.length) wallDropTimer.restart()
    property string wallPanelThumb: ""
    Process {
        id: wallNameRead
        command: ["sh", "-c",
                  "sleep 0.08; printf '%s\\n' \"$HOME\"; cat \"$HOME/.config/sea-shell/wallpaper\" 2>/dev/null"]
        stdout: StdioCollector { id: wnOut; onStreamFinished: {
            var lines = wnOut.text.split("\n");
            var home = (lines[0] || "").trim();
            var t = (lines[1] || "").trim();
            root.wallPanelName = t ? t.slice(t.lastIndexOf("/") + 1) : "";
            // The picker already cached a poster frame for every clip; the cycle can show the
            // same one instead of a caption. A still is its own poster.
            if (!t) { root.wallPanelThumb = ""; return }
            var low = t.toLowerCase();
            var moving = [".mp4", ".webm", ".gif", ".mkv", ".mov"].some(function (e) {
                return low.lastIndexOf(e) === low.length - e.length;
            });
            root.wallPanelThumb = moving
                ? home + "/.cache/sea-shell/wallthumbs/" + root.wallPanelName + ".w1280.jpg"
                : t;
        } }
    }
    property bool wallFading: false
    // Kept short on purpose. The covered hold below is fixed by how long the new wallpaper
    // takes to show a first frame, so the slides are the only part worth trimming — at 0.45× the whole
    // switch sat near 1.6s of nothing, which reads as a stall rather than a transition.
    readonly property int wallSlideMs: Math.max(160, Math.round(root.cfgWpTransitionDur * 1000 * 0.26))
    property real cfgWpTransitionDur: 1        // mirrors appearance.json wpTransitionDur

    IpcHandler {
        target: "wallpaper"
        function cycle(dir: string): void { root.wallCycle(dir) }
        function next(): void { root.wallCycle("next") }
        function prev(): void { root.wallCycle("prev") }
        function random(): void { root.wallCycle("random") }

        // `qs -c sea-shell ipc call wallpaper set /path/to/image`
        //
        // Setting a wallpaper was something only the picker and the cycle keybinds could
        // do, because each of them carried its own copy of what that means — write the
        // path, apply it, sync the lock screen, re-derive the palette. Anything else
        // wanting to change the wallpaper could write the config file and get none of the
        // rest. sea-wallpaper-set.sh is now that sequence, and this is the door to it.
        function set(path: string): void { root.wallSet(path) }
        // the strip of wallpapers along the foot of the screen, for a few seconds
        function strip(): void { wallStrip.open() }
        // video wallpaper control: pause/play is a manual hold on top of the automatic rules
        function pause(): void { root.wpForce = "pause" }
        function play(): void { root.wpForce = "" }
        function status(): string { return root.wpMode + " " + (root.wpVideo || root.wpPath) }
        // put the video surface back above an awww-daemon that mapped after it
        function remap(): void { root.wpRemap() }
    }
    // Shown for a moment on every cycle, so Super+N says where you are in the collection.
    // Built on first use and cooled after it hides.
    property string _wallStripPending: ""
    Loader {
        id: wallStripLoader
        asynchronous: true; active: false
        source: Qt.resolvedUrl("WallpaperStrip.qml")
        onStatusChanged: {
            if (status !== Loader.Ready) return;
            if (root._wallStripPending === "flash") item.flash();
            else if (root._wallStripPending === "open") item.open();
            root._wallStripPending = "";
        }
    }
    Connections {
        target: wallStripLoader.item
        ignoreUnknownSignals: true
        function onPicked(p) { root.wallSet(p) }
        function onShownChanged() { if (!wallStripLoader.item.shown) coolTimer.restart() }
    }
    QtObject {
        id: wallStrip
        function flash() {
            if (wallStripLoader.item) wallStripLoader.item.flash();
            else { root._wallStripPending = "flash"; wallStripLoader.active = true }
        }
        function open() {
            if (wallStripLoader.item) wallStripLoader.item.open();
            else { root._wallStripPending = "open"; wallStripLoader.active = true }
        }
        function close() { if (wallStripLoader.item) wallStripLoader.item.close() }
    }

    // ---------- video wallpaper (VideoWallpaper.qml, one per screen) ----------
    // The bar decodes the clip itself; awww keeps the still/poster underneath. Everything
    // that decides play / pause / freeze is already in this process — game mode, Hyprland's
    // fullscreen state, UPower — so it is one binding instead of a listener script talking
    // to a decoder over a socket.
    property string wpPath: ""
    property string wpPoster: ""
    property string wpVideo: ""                // what the player opens: the optimized copy once built
    property string wpForce: ""                // IPC override: "" | "pause"
    property bool cfgWpCoverStill: true
    property bool cfgWpBatteryStill: false
    property int cfgWpVidFps: 0
    readonly property bool wpMotion: WallpaperState.isMotion(root.wpPath)
    readonly property bool wpCovered: {
        var ms = Hyprland.monitors.values, n = 0;
        for (var i = 0; i < ms.length; i++) {
            var w = ms[i].activeWorkspace;
            if (!w) continue;
            n++;
            if (!w.hasFullscreen) return false;
        }
        return n > 0;
    }
    readonly property string wpMode: {
        var m = WallpaperState.decide({
            motion: root.wpMotion, gameOn: root.gameOn, coveredAll: root.wpCovered,
            onBattery: UPower.onBattery, coverStill: root.cfgWpCoverStill,
            batteryStill: root.cfgWpBatteryStill,
            occluded: root.desktopCovered && !root.desktopEditing });
        return (m === "play" && root.wpForce === "pause") ? "pause" : m;
    }
    // Encode for the biggest panel attached, in device pixels.
    readonly property string wpTargetSize: {
        var w = 0, h = 0, ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++) {
            var r = ss[i].devicePixelRatio || 1;
            var sw = Math.round(ss[i].width * r), sh = Math.round(ss[i].height * r);
            if (sw * sh > w * h) { w = sw; h = sh }
        }
        return w > 0 ? w + "x" + h : "1920x1080";
    }
    readonly property int wpTargetFps: root.cfgWpVidFps > 0 ? root.cfgWpVidFps : 24
    FileView {
        path: Quickshell.env("HOME") + "/.config/sea-shell/wallpaper"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.wpSetPath(text().trim())
        onLoadFailed: root.wpSetPath("")
    }
    function wpSetPath(p) {
        if (p === root.wpPath) return;
        root.wpPath = p;
        root.wpPoster = "";
        if (!root.wpMotion) { root.wpVideo = ""; return }
        root.wpAwaitReady = root.wallHold;
        if (root.wallHold) { wallLiftTimer.interval = 1600; wallLiftTimer.restart() }
        wpPosterProc.running = false;
        wpPosterProc.command = ["python3", root.seaScripts + "sea-wallpaper-index.py", "--fullposter", p];
        wpPosterProc.running = true;
        root.wpResolve();
    }
    function wpResolve() {
        if (!root.wpMotion) return;
        wpBuildProc.running = false;
        wpResolveProc.running = false;
        wpResolveProc.command = ["python3", root.seaScripts + "sea-wallpaper-optimize.py", root.wpPath,
                                 "--size", root.wpTargetSize, "--fps", "" + root.wpTargetFps];
        wpResolveProc.running = true;
    }
    onWpTargetSizeChanged: root.wpResolve()
    onWpTargetFpsChanged: root.wpResolve()
    Process {
        id: wpPosterProc
        stdout: StdioCollector { id: wpPosterOut; onStreamFinished: root.wpPoster = wpPosterOut.text.trim() }
    }
    // A clip that is bigger than the panel is not played as-is. The original stays on disk;
    // awww holds its poster until the screen-sized copy exists. Decoding a 1440p or 4K
    // file inside the bar is what pushed this process into the 600–700 MB range.
    Process {
        id: wpResolveProc
        stdout: StdioCollector { id: wpResolveOut; onStreamFinished: {
            var l = wpResolveOut.text.trim().split("\n");
            if (!l[0]) return;
            if (l[1] === "pending") {
                root.wpVideo = "";
                wpBuildProc.command = wpResolveProc.command.concat(["--build"]);
                wpBuildProc.running = true;
            } else root.wpVideo = l[0];
        } }
    }
    Process {
        id: wpBuildProc
        property string forPath: ""
        onStarted: forPath = root.wpPath
        stdout: StdioCollector { id: wpBuildOut; onStreamFinished: {
            var p = wpBuildOut.text.trim().split("\n")[0];
            if (p && wpBuildProc.forPath === root.wpPath) root.wpVideo = p;
        } }
    }
    property bool wpAwaitReady: false
    function wpReady() {
        if (!root.wpAwaitReady) return;
        root.wpAwaitReady = false;
        if (root.wallHold) { wallLiftTimer.interval = 60; wallLiftTimer.restart() }
    }
    // The clip is played by mpvpaper, not by Qt. A decoder inside this process kept its
    // frames, FFmpeg and the VAAPI/CUDA probe in the same RSS the dashboard lists as `qs`.
    // mpvpaper is its own process, and only while the wallpaper is actually on screen.
    property string wpPlaying: ""
    property bool wpRestart: false
    function wpStart() {
        if (root.wpPlaying === "") return;
        wpPlay.command = ["sh", root.seaScripts + "sea-wallpaper-play.sh", "play", root.wpPlaying];
        wpPlay.running = true;
        root.wpReady();
    }
    function wpSync() {
        var want = (root.wpMode === "play" && root.wpVideo !== "") ? root.wpVideo : "";
        var same = want === root.wpPlaying && (want === "" ? !wpPlay.running : wpPlay.running);
        if (same) return;
        root.wpPlaying = want;
        if (wpPlay.running) { root.wpRestart = want !== ""; wpPlay.running = false; }
        else { root.wpRestart = false; if (want !== "") root.wpStart(); }
    }
    function wpRemap() {
        if (!wpPlay.running) return;
        root.wpRestart = true;
        wpPlay.running = false;
    }
    onWpModeChanged: root.wpSync()
    onWpVideoChanged: root.wpSync()
    Process {
        id: wpPlay
        onExited: if (root.wpRestart && root.wpPlaying !== "") { root.wpRestart = false; root.wpStart() }
    }

    // Same curtain as a cycle: whatever asked for this is not the picker, so the panel is
    // the only thing that tells the user a switch is happening at all.
    property string wallSetPath: ""
    function wallSet(path) {
        if (root.wallFading || !path || !path.length) return;
        root.wallSetPath = path;
        root.wallCycle("set");
    }

    property string wallCycleDir: "next"
    function wallCycle(dir) {
        if (root.wallFading) return;           // ignore a second press mid-transition
        wallStrip.flash();
        root.wallCycleDir = (dir === "prev" || dir === "random" || dir === "set") ? dir : "next";
        root.wallPanelDir = (dir === "prev") ? -1 : 1;
        // Park the panel off-stage with the Behavior DISABLED, and only then create the
        // window. Animating it in from the same tick the delegate is built would find the
        // Rectangle already at its destination — the panel would blink into place covering
        // the screen instead of sliding on. Hence the tick of delay in wallInTimer.
        root.wallPanelAnim = false;
        root.wallPanelX = root.wallPanelDir;
        root.wallPanelName = "";
        root.wallPanelThumb = "";
        root.wallDrop = false;
        root.wallFading = true;
        wallInTimer.restart();
    }
    Timer {
        id: wallInTimer; interval: 16; repeat: false
        onTriggered: {
            root.wallPanelAnim = true;
            root.wallPanelX = 0;               // slides on; swapTimer fires when it has arrived
            wallSwapTimer.interval = root.wallSlideMs;
            wallSwapTimer.restart();
        }
    }
    // at full black: perform the actual switch
    Timer {
        id: wallSwapTimer; repeat: false
        onTriggered: {
            if (root.wallCycleDir === "set") {
                Quickshell.execDetached(["sh",
                    Qt.resolvedUrl("sea-wallpaper-set.sh").toString().replace("file://",""),
                    root.wallSetPath]);
            } else {
                Quickshell.execDetached(["sh",
                    Qt.resolvedUrl("sea-wallpaper-cycle.sh").toString().replace("file://",""),
                    root.wallCycleDir]);
            }
            wallNameRead.running = true;       // fills the hold with what it landed on
            root.wallHold = true;
            // A still is awww's to animate underneath, so this hold only covers the swap. A clip
            // extends it from wpSetPath() and lifts on VideoWallpaper's first frame instead,
            // with a ceiling in case that frame never comes (game mode, a broken file).
            wallLiftTimer.interval = 620;
            wallLiftTimer.restart();
        }
    }
    Timer {
        id: wallLiftTimer; repeat: false
        onTriggered: {
            // Off towards where you were headed, not back the way it came.
            root.wallHold = false;
            root.wallPanelX = -root.wallPanelDir;
            wallDoneTimer.interval = root.wallSlideMs;
            wallDoneTimer.restart();
        }
    }
    Timer {
        id: wallDoneTimer; repeat: false
        onTriggered: {
            root.wallFading = false;           // tears the window down
            root.wallPanelAnim = false;        // reset off-stage for the next press
            root.wallPanelX = 1;
        }
    }

    // ---------- hot corners ----------
    property var cfgHotCorners: ({ "tl": "", "tr": "", "bl": "", "br": "" })
    readonly property bool hotCornersOn: {
        var c = root.cfgHotCorners || {};
        return !!(c.tl || c.tr || c.bl || c.br);
    }
    readonly property bool hotCornersHeld: {
        if (root.gameOn) return true;
        var win = Hyprland.activeToplevel;
        var obj = win ? win.lastIpcObject : null;
        return !!(obj && obj.fullscreen > 0);
    }
    function hotCornerRun(action, screenName) {
        if (action === "overview") root.toggleExpose();
        else if (action === "launcher") launcher.toggle();
        else if (action === "dashboard") root.toggleDashboard();
        else if (action === "notif") root.openWidgetOn(root.openPop === "notif" ? "" : "notif", screenName);
        else if (action === "widgets") root.toggleWidgets();
    }
    // A corner another monitor touches is where the pointer crosses over, not a corner.
    function cornerOpen(scr, corner) {
        if (!scr) return false;
        var x = corner[1] === "r" ? scr.x + scr.width : scr.x;
        var y = corner[0] === "b" ? scr.y + scr.height : scr.y;
        var all = Quickshell.screens;
        for (var i = 0; i < all.length; i++) {
            var o = all[i];
            if (!o || o.name === scr.name) continue;
            if (x >= o.x && x <= o.x + o.width && y >= o.y && y <= o.y + o.height) return false;
        }
        return true;
    }
    component HotCorner: PanelWindow {
        id: hc
        property string corner: "tl"
        property var scr: null
        screen: scr
        readonly property string action: (root.cfgHotCorners || {})[corner] || ""
        visible: action !== "" && !root.hotCornersHeld && root.cornerOpen(scr, corner)
        anchors { top: corner[0] === "t"; bottom: corner[0] === "b"; left: corner[1] === "l"; right: corner[1] === "r" }
        implicitWidth: 2; implicitHeight: 2
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:corner"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        // A short rest, so sweeping past the corner on the way somewhere else does nothing.
        Timer { id: dwell; interval: 140; onTriggered: root.hotCornerRun(hc.action, hc.scr ? hc.scr.name : "") }
        MouseArea { anchors.fill: parent; hoverEnabled: true
            onEntered: dwell.restart()
            onExited: dwell.stop() }
    }
    Variants {
        model: root.hotCornersOn ? Quickshell.screens : []
        Scope {
            required property var modelData
            HotCorner { scr: modelData; corner: "tl" }
            HotCorner { scr: modelData; corner: "tr" }
            HotCorner { scr: modelData; corner: "bl" }
            HotCorner { scr: modelData; corner: "br" }
        }
    }

    // One curtain per monitor. Bottom layer: above the background (where VideoWallpaper and
    // awww draw) but below every real window, so it only ever darkens visible wallpaper — never
    // the user's apps. It takes no input: no keyboard focus and an empty mask.
    Variants {
        model: root.wallFading ? Quickshell.screens : []
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:wallfade"
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            mask: Region {}                    // fully click-through
            Rectangle {
                width: parent.width; height: parent.height
                x: root.wallPanelX * parent.width
                color: Tok.bg

                // A full-face vent grille. This was a flat field with a caption on it, which
                // is why it still read as bland however well it was timed — the panel itself
                // said nothing. At this spacing it costs one Repeater and turns the covering
                // panel into the blank side of a rack unit sliding across the screen, which is
                // the same equipment the picker's deck is made of.
                Row {
                    anchors.centerIn: parent
                    spacing: Math.round(22 * root.uiFor(modelData))
                    Repeater {
                        model: Math.ceil(parent.parent.width / (22 * root.uiFor(modelData))) + 2
                        Rectangle {
                            width: Math.max(1, Math.round(root.uiFor(modelData)))
                            height: parent.parent.parent.height
                            color: Tok.alpha(Tok.ink3, 0.16)
                        }
                    }
                }

                // The x binding stays intact: a Behavior intercepts a binding-driven change
                // rather than overwriting it, which a NumberAnimation on the same property
                // would have done permanently on the first run.
                //
                // Asymmetric easing, because arriving and leaving are not the same event. It
                // decelerates ON (it has come to cover something and stops) and accelerates
                // OFF (it is done and gets out of the way). One curve for both read as a
                // single mechanical sweep in each direction, which is what made it dull.
                Behavior on x {
                    enabled: root.wallPanelAnim
                    NumberAnimation {
                        duration: root.wallSlideMs
                        easing.type: root.wallPanelX === 0 ? Easing.OutCubic : Easing.InCubic
                    }
                }
                // The leading edge, so the panel has a direction and not just a presence: a
                // machined lip — the accent rule with a hairline set just behind it — on
                // whichever side it is travelling towards.
                Rectangle {
                    id: lip
                    width: Math.max(3, Math.round(3 * root.uiFor(modelData)))
                    height: parent.height
                    x: root.wallPanelDir > 0 ? 0 : parent.width - width
                    color: Tok.accent
                }
                Rectangle {
                    width: 1; height: parent.height
                    x: root.wallPanelDir > 0 ? lip.width + 2 : parent.width - lip.width - 3
                    color: Tok.ruleHard
                }

                // What it landed on, held in the middle of the panel while the swap happens
                // behind it. Direction first, in the tracked label style, then the file.
                Rectangle {
                    anchors.centerIn: parent
                    width: plateCol.implicitWidth + Tok.s12 * 2 * root.uiFor(modelData)
                    height: plateCol.implicitHeight + Tok.s8 * root.uiFor(modelData)
                    color: Tok.surface
                    radius: Tok.rSmall
                    opacity: root.wallPanelX === 0 ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    IndRule { anchors { left: parent.left; right: parent.right; top: parent.top } hard: true }
                    IndRule { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } hard: true }

                    // the deck's vent motif, both ends, so the plate reads as equipment
                    Repeater {
                        model: 2
                        Row {
                            required property int index
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: index === 0 ? parent.left : undefined
                            anchors.right: index === 1 ? parent.right : undefined
                            anchors.leftMargin: Tok.s4 * root.uiFor(modelData)
                            anchors.rightMargin: Tok.s4 * root.uiFor(modelData)
                            spacing: Math.max(2, Math.round(3 * root.uiFor(modelData)))
                            Repeater {
                                model: 5
                                Rectangle {
                                    width: Math.max(1, Math.round(root.uiFor(modelData)))
                                    height: Math.round(14 * root.uiFor(modelData))
                                    color: Tok.alpha(Tok.ink3, 0.30)
                                }
                            }
                        }
                    }

                Column {
                    id: plateCol
                    anchors.centerIn: parent
                    spacing: Tok.s3 * root.uiFor(modelData)

                    // A working deck, not a caption. The hold is the machine loading the next
                    // cartridge, so it shows exactly that: the wallpaper you are about to get,
                    // dropping into a slot. Same event as the picker's commit, same language,
                    // and it turns the wait into the thing you are waiting for.
                    Item {
                        id: loadBay
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.round(232 * root.uiFor(modelData))
                        height: Math.round(118 * root.uiFor(modelData))
                        clip: true

                        Rectangle {
                            id: miniCart
                            width: Math.round(208 * root.uiFor(modelData))
                            height: Math.round(117 * root.uiFor(modelData))
                            x: (loadBay.width - width) / 2
                            // parked clear of the slot until the swap has actually happened,
                            // then driven all the way through the clip boundary
                            y: root.wallDrop ? loadBay.height : Math.round(6 * root.uiFor(modelData))
                            Behavior on y {
                                NumberAnimation { duration: 360; easing.type: Easing.InQuad }
                            }
                            color: Tok.sunken
                            radius: Tok.rSmall
                            border.width: Math.max(1, Math.round(2 * root.uiFor(modelData)))
                            border.color: Tok.accent
                            clip: true
                            Image {
                                anchors.fill: parent
                                anchors.margins: parent.border.width
                                source: Tok.fileUrl(root.wallPanelThumb)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                sourceSize.width: 420
                            }
                        }
                    }

                    // the slot it goes into
                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: loadBay.width
                        height: Math.round(12 * root.uiFor(modelData))
                        Rectangle {
                            anchors.fill: parent
                            color: Qt.darker(Tok.sunken, Tok.light ? 2.1 : 1.6)
                            radius: Tok.rSmall
                        }
                    }

                    IndText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        sz: Math.round(Tok.tDense * root.uiFor(modelData))
                        font.weight: 600
                        color: Tok.accent
                        text: root.wallPanelDir > 0 ? "Next  →" : "←  Previous"
                    }
                    IndText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        sz: Math.round(Tok.tDense * root.uiFor(modelData))
                        color: Tok.ink
                        text: root.wallPanelName
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, parent.parent.width * 0.6)
                        horizontalAlignment: Text.AlignHCenter
                    }
                    // The wait, drawn. A clip's first frame is not ours to hurry, so the
                    // only decent thing to do with the hold is say how much of it is left —
                    // which is feedback, the one job that earns an animation. It fills for
                    // exactly the length of the hold, on a hairline track, in the accent.
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 200 * root.uiFor(modelData)
                        height: Math.max(1, Math.round(root.uiFor(modelData)))
                        color: Tok.rule
                        Rectangle {
                            width: root.wallHold ? parent.width : 0
                            height: parent.height
                            color: Tok.accent
                            Behavior on width {
                                NumberAnimation { duration: 620; easing.type: Easing.Linear }
                            }
                        }
                    }
                }
                }
            }
        }
    }
    HyprlandFocusGrab {
        windows: {
            try {
                var out = [];
                var list = root.grabWins || [];
                for (var i = 0; i < list.length; i++) {
                    var w = list[i];
                    if (w && w.visible !== undefined) out.push(w);
                }
                return out;
            } catch(e) { return []; }
        }
        active: root.openPop !== "" && !root.grabHold
        onCleared: root.openPop = ""
    }

    // ---------- appearance (live-reloaded from ~/.config/sea-shell/appearance.json) ----------
    property real cfgRadius: 14
    property real cfgOpacity: 0.80
    property bool cfgBarOpaque: true
    property string cfgGlass: "frosted"     // the bar, menus and notifications: solid | frosted | clear (Tok glass)
    readonly property real barSurfaceOpacity: 1.0
    property int  cfgHeight: 42
    // global UI scale — makes the whole shell legible on big/far displays (4K TVs, projectors).
    // 0 = auto (derived per-monitor from its height, so a laptop stays 1× while a 4K TV scales up);
    // any positive value is a manual multiplier applied to every surface. Set in appearance.json
    // ("scale") and via Settings → Appearance. Applied as a Scale transform, so it needs no
    // per-widget edits and never shrinks below the native 1080p-tuned design.
    property real cfgScale: 0
    // effective scale for a given screen. Auto keeps ≤1440p untouched (the native design already
    // fits there) and grows past it, capped at 2.5× so an 8K panel doesn't become comical.
    // per-monitor overrides — { "eDP-1": { bar: true, scale: 0 }, ... }; scale 0 = inherit
    property var cfgMonitors: ({})
    function monBar(name)   { var m = name ? root.cfgMonitors[name] : null; return !(m && m.bar === false); }
    function monScale(name) { var m = name ? root.cfgMonitors[name] : null; return (m && m.scale > 0) ? m.scale : 0; }
    function uiFor(scr) {
        var mo = (scr && scr.name) ? root.monScale(scr.name) : 0;   // per-monitor scale wins
        if (mo > 0) return mo;
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 0) { var ss = Quickshell.screens; for (var i=0;i<ss.length;i++) if (ss[i] && ss[i].height > h) h = ss[i].height; }
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    property string cfgAccent: "#63c7dd"
    property string cfgFont: Tok.resolveFont("Inter")
    property bool   cfgLight: false          // dark (default) ↔ light palette
    property string cfgBarFill: "matugen"    // top-bar fill: matugen (accent-tinted) · black · white
    property string cfgEdge: "top"           // which screen edge the bar docks to: top or bottom
    // ---- dock ----
    // Off by default: the dock is a second always-on surface and nobody should get one they did
    // not ask for. It defaults to the edge OPPOSITE the bar so enabling it never lands the two
    // on top of each other.
    property bool   cfgDock: false
    property string cfgDockEdge: "bottom"
    property int    cfgDockIcon: 40
    property string cfgDockMode: "always"    // always (reserves space) · autohide · intelligent
    property bool   cfgDockZoom: true
    property bool   cfgDockRunning: true     // show running apps that are not pinned
    property bool   cfgDockLabels: true
    property bool cfgMpris: true
    property bool cfgMic: false     // off by default: most people do not need a permanent mic pill
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
    property bool cfgClock24: true
    property bool cfgClockSeconds: false
    property bool cfgPower: true
    property bool cfgQuick: true          // Control Center pill (quick toggles + power profile)
    property bool cfgUpdates: true        // pending pacman/AUR update count
    property bool cfgNet: true            // live network throughput
    property bool cfgNightWidget: false   // Night-light toggle pill on the bar
    property bool cfgAi: true             // Claude, Codex, Cursor, Grok, and Antigravity usage
    property bool cfgGithub: true         // contribution streak / today on the bar
    property bool cfgTotem: true          // Totem 2FA codes from the phone
    property var totemStatus: ({ ok: false, paired: false, missing: false, error: "", phone: null })
    property var totemAccounts: []
    property string totemQuery: ""
    property string totemNotice: ""
    property string totemCode: ""
    property int totemCodeLeft: 0
    property bool totemBusy: false
    property var aiUsage: ({ tools: [] })
    property string aiFocus: ""
    property var github: ({ ok: false, today: 0, streak: 0, year: 0, weeks: [], repos: [], login: "", error: "" })
    property string focusId: ""
    property var focusProfiles: ({})
    property var widgetClips: []
    // Which plans are drawn, and which one leads. Empty default means the tightest allowance.
    property var cfgAiOn: ({ "claude": true, "codex": true, "cursor": true, "cursor-alt": true, "gemini": true })
    property string cfgAiDefault: ""
    property int cfgAiDigits: 2
    function aiPct(n) {
        var d = root.cfgAiDigits;
        if (d !== 0 && d !== 1 && d !== 2) d = 2;
        var v = Number(n);
        if (!isFinite(v)) v = 0;
        return v.toFixed(d) + "%";
    }
    function aiKnown(id) {
        return id === "claude" || id === "codex" || id === "grok" || id === "gemini"
            || /^cursor(-alt\d*)?$/.test(id);
    }
    function aiPlanOn(id) {
        if (id === "grok") id = "cursor";
        else if (id.indexOf("cursor-alt") === 0) id = "cursor-alt";
        var on = root.cfgAiOn || ({});
        return on[id] !== false;
    }
    function aiFind(tools, id) {
        for (var i = 0; i < tools.length; i++)
            if (tools[i].id === id || (id === "grok" && tools[i].with === "grok")
                || (id === "cursor" && tools[i].id === "cursor")) return tools[i];
        return null;
    }
    readonly property var aiTools: {
        var all = (root.aiUsage && root.aiUsage.tools) ? root.aiUsage.tools : [];
        var out = [];
        for (var i = 0; i < all.length; i++)
            if (root.aiPlanOn(all[i].id)) out.push(all[i]);
        var pref = root.cfgAiDefault;
        if (pref) {
            var hit = -1;
            for (var j = 0; j < out.length; j++)
                if (out[j].id === pref) hit = j;
            if (hit > 0) {
                var top = out[hit];
                out.splice(hit, 1);
                out.unshift(top);
            }
        }
        return out;
    }
    readonly property var aiShownUsage: ({
        tools: root.aiTools,
        lead: root.aiUsage ? root.aiUsage.lead : null
    })
    readonly property var aiShown: {
        var tools = root.aiTools;
        var focused = root.aiFocus ? root.aiFind(tools, root.aiFocus) : null;
        if (focused) return focused;
        // Stale ai-focus (e.g. a plan that vanished) falls through to On top / lead.
        var preferred = root.cfgAiDefault ? root.aiFind(tools, root.cfgAiDefault) : null;
        if (preferred) return preferred;
        if (root.aiUsage && root.aiUsage.lead)
            for (var j = 0; j < tools.length; j++)
                if (tools[j].name === root.aiUsage.lead.name
                    || tools[j].id === root.aiUsage.lead.id) return tools[j];
        return tools.length ? tools[0] : null;
    }
    readonly property string aiBarValue: (root.aiShown && root.aiShown.unit === "left")
        ? root.aiPct(root.aiShown.today) : (root.aiShown ? (root.aiShown.todayLabel || "") : "")
    readonly property int aiHot: {
        var s = root.aiShown;
        if (!s || !s.windows) return 0;
        var m = 0;
        for (var i = 0; i < s.windows.length; i++)
            m = Math.max(m, Number(s.windows[i].used) || 0);
        return m;
    }
    readonly property color aiAccent: root.aiBarValue === "" ? theme.frost
        : (root.aiHot >= 95 ? theme.bad : (root.aiHot >= 80 ? theme.warn : theme.iris))
    // Kept off the usage objects. A field named running on those objects does not
    // come back through the binding, so the dot was never drawn.
    property var aiLive: ({})
    function aiIsLive(id) {
        if (id === "grok") id = "cursor";
        var m = root.aiLive || ({});
        return !!m[id];
    }
    function aiSetLive(ids) {
        var on = {};
        if (ids) for (var n = 0; n < ids.length; n++) on["" + ids[n]] = true;
        root.aiLive = on;
    }
    property var aiWarned: ({})
    Process {
        running: true
        command: ["sh", "-c", "cat \"$HOME/.config/sea-shell/ai-warned.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.aiWarned = JSON.parse(text.trim() || "{}"); } catch (e) { root.aiWarned = {}; }
            }
        }
    }
    function aiCheckWarn(tools) {
        if (!tools) return;
        var changed = false;
        for (var i = 0; i < tools.length; i++) {
            var plan = tools[i];
            if (!root.aiPlanOn(plan.id)) continue;
            var w = plan.warn;
            if (!w || !w.key || root.aiWarned[w.key]) continue;
            root.aiWarned[w.key] = 1;
            changed = true;
            Quickshell.execDetached(["notify-send", "-u", "normal", "-a", "sea-shell",
                w.title || "Plan usage", w.body || ""]);
        }
        if (!changed) return;
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p \"$HOME/.config/sea-shell\" && echo '" + Qt.btoa(JSON.stringify(root.aiWarned))
            + "' | base64 -d > \"$HOME/.config/sea-shell/ai-warned.json\""]);
    }
    function setAiFocus(id) {
        if (!root.aiKnown(id)) return;
        root.aiFocus = id;
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p \"$HOME/.config/sea-shell\" && printf %s " + id + " > \"$HOME/.config/sea-shell/ai-focus\""]);
    }
    FileView {
        path: Quickshell.env("HOME") + "/.config/sea-shell/ai-focus"
        watchChanges: true
        printErrors: false
        onLoaded: {
            var t = text().trim();
            if (root.aiKnown(t)) root.aiFocus = t;
        }
        onFileChanged: reload()
    }
    readonly property string aiScript: Quickshell.env("HOME") + "/.config/quickshell/sea-shell/sea-ai-usage.py"
    Process {
        id: aiProc
        command: ["python3", root.aiScript]
        stdout: StdioCollector {
            id: aiOut
            onStreamFinished: {
                var t = aiOut.text.trim();
                if (!t) return;
                try {
                    var parsed = JSON.parse(t);
                    root.aiUsage = parsed;
                    var ids = [];
                    var tools = parsed.tools || [];
                    for (var i = 0; i < tools.length; i++)
                        if (tools[i].live) ids.push(tools[i].id);
                    if (ids.length) root.aiSetLive(ids);
                    root.aiCheckWarn(tools);
                } catch (e) {}
            }
        }
    }
    Timer {
        id: aiTimer
        interval: 180000; repeat: true; running: !root.gameHibernate; triggeredOnStart: true
        onTriggered: { if (!aiProc.running) aiProc.running = true }
    }
    property real aiFetchedAt: 0
    Connections {
        target: aiProc
        function onRunningChanged() { if (aiProc.running) root.aiFetchedAt = Date.now() }
    }
    Connections {
        target: root
        function onOpenPopChanged() {
            if (root.openPop === "ai" && !aiProc.running && Date.now() - root.aiFetchedAt > 30000) {
                aiProc.running = true;
                aiTimer.restart();
            }
            if (root.openPop === "gh" && !ghProc.running && Date.now() - root.ghFetchedAt > 30000) {
                root.refreshGithub(false);
                ghTimer.restart();
            }
        }
    }

    // ---------- GitHub contributions + watched repos ----------
    readonly property string githubScript: Quickshell.env("HOME") + "/.config/quickshell/sea-shell/sea-github.py"
    property bool ghUseCache: true
    Process {
        id: ghProc
        command: root.ghUseCache
            ? ["python3", root.githubScript, "--cache-ok"]
            : ["python3", root.githubScript]
        stdout: StdioCollector {
            id: ghOut
            onStreamFinished: {
                var t = ghOut.text.trim();
                root.ghUseCache = true;
                if (!t) return;
                try { root.github = JSON.parse(t); } catch (e) {}
            }
        }
    }
    function refreshGithub(force) {
        if (ghProc.running) return;
        root.ghUseCache = !force;
        ghProc.running = true;
    }
    Timer {
        id: ghTimer
        interval: 300000; repeat: true; running: root.cfgGithub && !root.gameHibernate; triggeredOnStart: true
        onTriggered: root.refreshGithub(false)
    }
    property real ghFetchedAt: 0
    Connections {
        target: ghProc
        function onRunningChanged() { if (ghProc.running) root.ghFetchedAt = Date.now() }
    }
    readonly property string githubBarValue: {
        if (!root.github || !root.github.ok) return "";
        var n = Number(root.github.today) || 0;
        if (n > 0) return String(n);
        var s = Number(root.github.streak) || 0;
        return s > 0 ? (s + "d") : "";
    }
    readonly property bool githubCiBad: {
        var repos = (root.github && root.github.repos) ? root.github.repos : [];
        for (var i = 0; i < repos.length; i++) if (repos[i].ci === "fail") return true;
        return false;
    }
    // Streak flame: fire icon while a streak lives; sputters (warn + ember pulse) until you commit today.
    readonly property bool githubLit: !!(root.github && root.github.ok && (Number(root.github.streak) || 0) > 0)
    readonly property bool githubSputter: root.githubLit && (Number(root.github.today) || 0) === 0
    readonly property string githubPillIcon: root.githubLit ? "local_fire_department" : "commit"
    readonly property color githubPillAccent: root.githubCiBad ? theme.bad
        : !root.githubLit ? theme.frost
        : root.githubSputter ? theme.warn
        : theme.iris
    property real githubEmber: 1.0
    Timer {
        interval: 110; repeat: true
        running: root.githubSputter && root.cfgGithub && !root.gameHibernate
        onTriggered: root.githubEmber = 0.72 + Math.random() * 0.38
        onRunningChanged: if (!running) root.githubEmber = 1.0
    }


    // ---------- Totem (2FA from phone) ----------
    function totemSh() {
        // install.sh flattens scripts into ~/.config/quickshell/sea-shell/
        return Quickshell.env("HOME") + "/.config/quickshell/sea-shell/sea-totem.sh";
    }
    Process {
        id: totemStatusProc
        command: ["bash", root.totemSh(), "status"]
        stdout: StdioCollector {
            id: totemStatusOut
            onStreamFinished: {
                var t = totemStatusOut.text.trim();
                if (!t) return;
                try {
                    var j = JSON.parse(t);
                    root.totemStatus = j;
                    if (j.missing) root.totemNotice = "totem CLI not found";
                    else if (!j.paired) root.totemNotice = "Not paired — open Totem to pair";
                    else root.totemNotice = j.phone && j.phone.name ? ("Phone: " + j.phone.name) : "Paired";
                } catch (e) { root.totemNotice = "Couldn't read Totem status"; }
            }
        }
    }
    Process {
        id: totemListProc
        command: ["bash", root.totemSh(), "list"]
        stdout: StdioCollector {
            id: totemListOut
            onStreamFinished: {
                root.totemBusy = false;
                var t = totemListOut.text.trim();
                if (!t) return;
                try {
                    var j = JSON.parse(t);
                    if (Array.isArray(j)) root.totemAccounts = j;
                    else if (j && j.error) root.totemNotice = j.error;
                } catch (e) { root.totemNotice = "Couldn't list accounts"; }
            }
        }
    }
    Process {
        id: totemCodeProc
        property string query: ""
        command: ["bash", root.totemSh(), "code", query]
        stdout: StdioCollector {
            id: totemCodeOut
            onStreamFinished: {
                root.totemBusy = false;
                var t = totemCodeOut.text.trim();
                if (!t) return;
                try {
                    var j = JSON.parse(t);
                    if (j.ok && j.code) {
                        root.totemCode = j.code;
                        root.totemCodeLeft = Number(j.seconds_left) || 0;
                        root.totemNotice = "Copied " + (j.account && j.account.title ? j.account.title : "code");
                        Quickshell.execDetached([
                            "bash", "-c",
                            'printf %s "$1" | wl-copy 2>/dev/null || printf %s "$1" | xclip -selection clipboard; ( sleep 20; c=$(wl-paste 2>/dev/null || xclip -selection clipboard -o 2>/dev/null); [ "$c" = "$1" ] && { wl-copy --clear 2>/dev/null || true; } ) &',
                            "_", j.code
                        ]);
                    } else {
                        root.totemNotice = (j && j.error) ? j.error : "Couldn't get code";
                    }
                } catch (e) { root.totemNotice = "Couldn't get code"; }
            }
        }
    }
    function refreshTotemStatus() {
        if (totemStatusProc.running) return;
        totemStatusProc.running = true;
    }
    function refreshTotemAccounts() {
        if (totemListProc.running) return;
        root.totemBusy = true;
        root.totemNotice = "Asking phone…";
        totemListProc.running = true;
    }
    function fetchTotemCode(q) {
        if (!q || totemCodeProc.running) return;
        root.totemBusy = true;
        root.totemNotice = "Getting code…";
        root.totemCode = "";
        totemCodeProc.query = q;
        totemCodeProc.running = false;
        totemCodeProc.running = true;
    }
    function openTotemApp() {
        Quickshell.execDetached(["bash", root.totemSh(), "open"]);
    }
    readonly property var totemFiltered: {
        var q = (root.totemQuery || "").trim().toLowerCase();
        var out = [];
        var acc = root.totemAccounts || [];
        for (var i = 0; i < acc.length; i++) {
            var a = acc[i];
            var hay = ((a.title || "") + " " + (a.subtitle || "") + " " + (a.issuer || "") + " " + (a.label || "")).toLowerCase();
            if (!q || hay.indexOf(q) >= 0) out.push(a);
        }
        out.sort(function (a, b) { return (a.policy === "never") - (b.policy === "never"); });
        return out;
    }
    readonly property string totemPillIcon: root.totemStatus && root.totemStatus.paired ? "password" : (root.totemStatus && root.totemStatus.missing ? "key_off" : "phonelink_lock")
    readonly property color totemPillAccent: root.totemStatus && root.totemStatus.paired ? theme.iris : theme.warn
    Timer {
        interval: 120000; repeat: true; running: root.cfgTotem && !root.gameHibernate; triggeredOnStart: true
        onTriggered: root.refreshTotemStatus()
    }

    // ---------- Focus profiles ----------
    readonly property string focusScript: Quickshell.env("HOME") + "/.config/quickshell/sea-shell/sea-focus.py"
    Process {
        id: focusGetProc
        command: ["python3", root.focusScript, "get"]
        stdout: StdioCollector {
            id: focusOut
            onStreamFinished: {
                try {
                    var j = JSON.parse(focusOut.text.trim() || "{}");
                    root.focusId = j.id || "";
                    root.focusProfiles = j.profiles || ({});
                } catch (e) {}
            }
        }
    }
    Timer { interval: 60000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: focusGetProc.running = true }
    // Night/game owned by the current focus profile so Clear can put them back.
    property bool focusSavedNight: false
    property bool focusOwnedGame: false
    property string focusPendingId: ""
    function setNightOn(on) {
        var want = !!on;
        if (want === root.cfgNight && !root.cfgNightAuto) return;
        Quickshell.execDetached(["python3", "-c",
            "import json,os,sys\n"
            + "p=os.path.expanduser('~/.config/sea-shell/appearance.json')\n"
            + "os.makedirs(os.path.dirname(p),exist_ok=True)\n"
            + "d={}\n"
            + "try:\n d=json.load(open(p))\nexcept Exception:\n pass\n"
            + "d['night']=sys.argv[1]=='1'\n"
            + "d['nightAuto']=False\n"
            + "t=p+'.tmp'\n"
            + "json.dump(d,open(t,'w'))\n"
            + "os.replace(t,p)\n",
            want ? "1" : "0"]);
    }
    Process {
        id: focusApplyProc
        stdout: StdioCollector {
            id: focusApplyOut
            onStreamFinished: {
                var raw = focusApplyOut.text.trim();
                if (!raw) return;
                try {
                    var j = JSON.parse(raw);
                    root._focusApplyActions(j);
                } catch (e) {}
            }
        }
    }
    function _focusApplyActions(j) {
        if (j.error) { focusGetProc.running = true; return; }
        var act = j.actions || j.profile || ({});
        var clearing = !!act.clear || !(j.id);
        muteFile.reload();
        if (Array.isArray(act.muteApps)) root.mutedApps = act.muteApps.slice();
        if (clearing) {
            root.setDnd(false);
            if (root.cafWanted) root.toggleIdle();
            root.setNightOn(root.focusSavedNight);
            if (root.focusOwnedGame && root.gameOn)
                Quickshell.execDetached(["sh", "-c", "$HOME/.config/quickshell/sea-shell/sea-gamemode.sh off"]);
            root.focusOwnedGame = false;
            root.focusId = "";
            focusGetProc.running = true;
            return;
        }
        root.focusSavedNight = root.cfgNight;
        if (act.dnd !== undefined) root.setDnd(!!act.dnd);
        if (act.caffeine) {
            if (!root.cafWanted) root.toggleIdle();
        } else if (root.cafWanted) {
            root.toggleIdle();
        }
        if (act.night !== undefined) root.setNightOn(!!act.night);
        if (act.gameMode) {
            if (!root.gameOn) {
                Quickshell.execDetached(["sh", "-c", "$HOME/.config/quickshell/sea-shell/sea-gamemode.sh on"]);
                root.focusOwnedGame = true;
            }
        } else if (root.focusOwnedGame && root.gameOn) {
            Quickshell.execDetached(["sh", "-c", "$HOME/.config/quickshell/sea-shell/sea-gamemode.sh off"]);
            root.focusOwnedGame = false;
        }
        if (act.openDash === "dev") root.openDashboardDev();
        else if (act.openDash === "gaming") root.openDashboardGaming();
        else if (act.openDash === "overview") {
            if (!dashLoader.item || !dashLoader.item.shown) root.toggleDashboard();
        }
        root.focusId = j.id || root.focusPendingId;
        focusGetProc.running = true;
    }
    function applyFocus(id) {
        id = id || "clear";
        if (focusApplyProc.running) return;
        root.focusPendingId = id;
        // sea-focus.py owns notif-mutes.json (+ snapshot/restore); shell effects
        // come from its stdout so we never depend on focusProfiles being loaded.
        focusApplyProc.command = ["python3", root.focusScript, "apply", id];
        focusApplyProc.running = true;
    }

    // ---------- Clipboard lines for the desktop widget ----------
    Process {
        id: clipWidgetProc
        command: ["sh", "-c", "cliphist list 2>/dev/null | head -12"]
        stdout: StdioCollector {
            id: clipWidgetOut
            onStreamFinished: {
                var lines = clipWidgetOut.text.split("\n").filter(function(l) { return l.length > 0; });
                var out = [];
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i];
                    var tab = line.indexOf("\t");
                    var body = tab >= 0 ? line.slice(tab + 1) : line;
                    var img = body.indexOf("[[ binary data") === 0;
                    var ocr = /^OCR\b/i.test(body) || body.indexOf("[ocr]") === 0;
                    out.push({ text: img ? body.replace("[[ binary data", "image ·").replace("]]", "").trim() : body, img: img, ocr: ocr });
                }
                root.widgetClips = out;
            }
        }
    }
    Timer { interval: 8000; running: !root.gameOn; repeat: true; triggeredOnStart: true; onTriggered: { if (!clipWidgetProc.running) clipWidgetProc.running = true } }

    readonly property var timerReading: ({
        running: root.tmrRunning,
        paused: root.tmrPaused,
        remain: root.tmrRemain,
        total: root.tmrTotal,
        text: root.tmrText,
        pomo: root.pomoActive,
        phase: root.pomoPhase,
        done: root.pomoDone
    })
    // Same rule as session_id() in sea-ai-usage.py: the Cursor editor stays up with nobody
    // using it, so only the agent and its sandbox count.
    function aiSessionOf(comm, args) {
        if (comm === "claude") return "claude";
        if (comm === "codex") return "codex";
        if (comm === "gemini" || comm === "agy") return "gemini";
        if (comm === "cursor-agent" || comm === "cursorsandbox") return "cursor";
        if ((comm === "node" || comm === "cursor-agent")
            && (args.indexOf("cursor-agent") >= 0 || args.indexOf("cursorsandbox") >= 0)) return "cursor";
        if (args.indexOf("gemini") >= 0 || args.toLowerCase().indexOf("antigravity") >= 0) return "gemini";
        return "";
    }
    Process {
        id: aiLiveProc
        command: ["ps", "-eo", "comm=,args="]
        stdout: StdioCollector {
            id: aiLiveOut
            onStreamFinished: {
                var lines = aiLiveOut.text.split("\n");
                var ids = [];
                for (var i = 0; i < lines.length; i++) {
                    var m = /^\s*(\S+)\s*(.*)$/.exec(lines[i]);
                    if (!m) continue;
                    var id = root.aiSessionOf(m[1], m[2]);
                    if (id && ids.indexOf(id) < 0) ids.push(id);
                }
                root.aiSetLive(ids);
            }
        }
    }
    Timer {
        interval: 5000; repeat: true; running: !root.gameHibernate; triggeredOnStart: true
        onTriggered: { if (!aiLiveProc.running) aiLiveProc.running = true }
    }
    // ---------- bar shape, workspaces, and the mark ----------
    // All three used to be facts about the bar rather than settings: one continuous strip,
    // workspaces as circles that grow, and the sea-shell logo, always. The first thing on
    // somebody's bar should be able to say what the MACHINE is.
    property string cfgBarShape: "bar"      // bar | pills
    property string cfgWsStyle:  "grow"     // grow | pill | circle
    property string cfgWsLabel:  "arabic"   // what the workspace is CALLED on the bar
    property string cfgBarLogo:  "auto"     // auto | sea | cachy | <distro glyph> | custom
    property string cfgBarLogoPath: ""
    // pictures chosen in Settings → Appearance → stickers; empty means none
    property string cfgStickerPower: ""
    property string cfgStickerMedia: ""
    function stickerUrl(path) { return path.length ? (path.indexOf("://") > 0 ? path : "file://" + path) : "" }

    // /etc/os-release, read synchronously — the mark is on the first frame or it is a flash.
    // Same reasoning as the palette; see the FileView above.
    FileView {
        id: osRelease
        path: "/etc/os-release"
        blockLoading: true
        Component.onCompleted: root.parseOsRelease(osRelease.text())
        onLoaded: root.parseOsRelease(osRelease.text())
    }
    property string distroId: ""
    property string distroLike: ""
    function parseOsRelease(t) {
        if (!t) return;
        var lines = t.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var m = /^(ID|ID_LIKE)=(.*)$/.exec(lines[i].trim());
            if (!m) continue;
            var v = m[2].replace(/^"|"$/g, "").trim().toLowerCase();
            if (m[1] === "ID") root.distroId = v; else root.distroLike = v;
        }
    }
    // What "auto" resolves to. CachyOS gets the drawn mark because Nerd Fonts ships no
    // glyph for it; anything ID_LIKE=arch that we do not know by name falls back to the
    // Arch glyph rather than to the shell's own logo, because that is still true.
    readonly property string logoKind: {
        if (root.cfgBarLogo !== "auto") return root.cfgBarLogo;
        var id = root.distroId;
        if (id === "cachyos") return "cachy";
        var known = ["arch","alpine","artix","debian","endeavouros","fedora","gentoo",
                     "manjaro","mint","nixos","opensuse","pop","ubuntu","void"];
        if (known.indexOf(id) >= 0) return id;
        if (id === "linuxmint") return "mint";
        if (id.indexOf("opensuse") === 0) return "opensuse";
        if (id === "pop_os" || id === "popos") return "pop";
        if (root.distroLike.indexOf("arch") >= 0) return "arch";
        if (root.distroLike.indexOf("debian") >= 0) return "debian";
        if (root.distroLike.indexOf("fedora") >= 0) return "fedora";
        return id.length ? "tux" : "sea";
    }
    readonly property bool barPills: root.cfgBarShape === "pills"

    // ---------- what a workspace is CALLED ----------
    // The bar has always said "1 2 3" because that is what Hyprland calls them, which is a
    // reason to default to it and no reason at all to be stuck with it. Every scheme below
    // falls back to the plain number once it runs out of symbols — ⚅ is the last die, ⑳ the
    // last circled numeral, and a workspace 21 that rendered as a blank box would be worse
    // than one that admits it is 21.
    function wsRoman(n) {
        if (n < 1 || n > 3999) return "" + n;
        var v = [1000,900,500,400,100,90,50,40,10,9,5,4,1];
        var g = ["M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"];
        var out = "";
        for (var i = 0; i < v.length; i++) while (n >= v[i]) { out += g[i]; n -= v[i] }
        return out;
    }
    function wsMandarin(n) {
        var d = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"];
        if (n < 1 || n > 99) return "" + n;
        if (n < 10) return d[n];
        if (n === 10) return "十";
        var tens = Math.floor(n / 10), ones = n % 10;
        return (tens > 1 ? d[tens] : "") + "十" + (ones ? d[ones] : "");
    }
    // Not every scheme's symbols exist in the UI font. CookieRun — the font this shell is
    // actually being used with — has the circled numerals and NOT the dice, so ⚀⚁⚂ rendered
    // as three tofu boxes on the bar. Probed rather than hardcoded, the same way the bar's
    // Nerd Font is, and the scheme falls back to plain numbers if nothing on the machine
    // can draw it.
    readonly property string symbolFamily: {
        var fams = Qt.fontFamilies();
        var prefs = ["DejaVu Sans", "Noto Sans Symbols2", "Adwaita Mono", "DejaVu Sans Mono"];
        for (var i = 0; i < prefs.length; i++)
            if (fams.indexOf(prefs[i]) >= 0) return prefs[i];
        for (var j = 0; j < fams.length; j++)
            if (fams[j].indexOf("Nerd Font") >= 0) return fams[j];
        return "";
    }
    // Which schemes need it, and whether we can honour them at all.
    readonly property bool wsNeedsSymbol: root.cfgWsLabel === "dice"
    readonly property string wsFontFamily: root.wsNeedsSymbol && root.symbolFamily !== ""
                                           ? root.symbolFamily : root.cfgFont

    // The strip's workspaces. A copy rather than Hyprland.workspaces itself: that model is in
    // order, but a Repeater in a Grid put a workspace re-created mid-session at the wrong end, so
    // Steam restarting on 1 read 2 1 3 along the bar.
    readonly property var stripWorkspaces: {
        var all = (Hyprland && Hyprland.workspaces) ? Hyprland.workspaces.values : [];
        var out = [];
        for (var i = 0; i < all.length; i++) if (all[i] && all[i].id > 0) out.push(all[i]);
        return out.sort(function (a, b) { return a.id - b.id });
    }

    // ---------- the scratchpad ----------
    // Hyprland builds a special workspace when the first window is thrown into it and tears
    // it down the moment the last one leaves. So there is no such thing as an empty stash to
    // have to test for: its EXISTENCE is the whole signal.
    readonly property var scratchWs: {
        var all = (Hyprland && Hyprland.workspaces) ? Hyprland.workspaces.values : [];
        var any = null;
        for (var i = 0; i < all.length; i++) {
            if (!all[i] || all[i].id >= 0) continue;
            if (("" + all[i].name) === "special:scratch") return all[i];   // the one the keybind uses
            if (!any) any = all[i];
        }
        return any;
    }
    // Counted off the wayland toplevels, the same rule the switcher settled on: hyprctl's
    // per-workspace window count goes stale on a long-lived shell, and a stash that says 3
    // when it holds 1 is worse than no mark at all.
    readonly property int scratchCount: {
        if (!root.scratchWs) return 0;
        var m = (Hyprland && Hyprland.toplevels) ? Hyprland.toplevels.values : [];
        var n = 0;
        for (var i = 0; i < m.length; i++)
            if (m[i] && m[i].workspace && m[i].workspace.id === root.scratchWs.id) n++;
        return n;
    }
    // Whether the stash is currently ON SCREEN. Holding windows and showing them are two
    // different states — that separation is the entire point of a scratchpad — so this is
    // not derivable from scratchWs.
    property bool scratchOpen: false
    // The event stream says when it opens and closes but says nothing about the state the bar
    // STARTED in: restart the shell with the stash pulled down and the mark would draw dim.
    // Asked once, from whichever monitor is holding it.
    function scratchSync() {
        try {
            var ms = (Hyprland && Hyprland.monitors) ? Hyprland.monitors.values : [];
            for (var i = 0; i < ms.length; i++) {
                var o = ms[i] && ms[i].lastIpcObject;
                if (o && o.specialWorkspace && ("" + (o.specialWorkspace.name || "")).length > 0) {
                    root.scratchOpen = true; return;
                }
            }
        } catch (e) {}
        root.scratchOpen = false;
    }
    Timer { interval: 900; running: true; repeat: false
        onTriggered: { try { if (Hyprland.refreshMonitors) Hyprland.refreshMonitors(); } catch (e) {} root.scratchSync(); } }
    // Emptying the stash puts it away whether or not anything said so.
    onScratchCountChanged: if (root.scratchCount === 0) root.scratchOpen = false

    function wsLabelFor(n) {
        // The stash has no number to write in any of these systems, and "-98" is not a label.
        if (n < 0) return "\u2022";
        switch (root.cfgWsLabel) {
        case "roman":    return root.wsRoman(n);
        case "mandarin": return root.wsMandarin(n);
        case "letters":  return (n >= 1 && n <= 26) ? String.fromCharCode(64 + n) : "" + n;
        case "circled":  return (n >= 1 && n <= 20) ? String.fromCharCode(0x2460 + n - 1) : "" + n;
        case "dice":     return (n >= 1 && n <= 6 && root.symbolFamily !== "")
                                ? String.fromCharCode(0x2680 + n - 1) : "" + n;
        // Every workspace the same mark: which one you are on is said by the fill alone,
        // and where you are in the row by position. The most minimal the bar goes.
        case "dots":     return "\u25cf";
        default:         return "" + n;
        }
    }

    property bool cfgAutoHide: false      // auto-hide the bar; reveal by pushing the cursor to the edge
    property bool cfgHideFullscreen: false // hide the bar while a window is fullscreen (reveal on hover)
    property bool cfgHideGaming: false     // hide the bar while game mode or a Steam window is active
    property bool cfgSuspendShellGaming: false  // Level 2 Ultra mode: stop seashell + daemons in game mode
    property bool cfgAutoPowerBattery: false    // auto power-saver + 60Hz on battery, restore on AC
    function patchAppearanceBool(key, val) {
        Quickshell.execDetached(["python3", "-c",
            "import json,os,pathlib,sys; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell/appearance.json')); " +
            "p.parent.mkdir(parents=True,exist_ok=True); " +
            "d=json.loads(p.read_text()) if p.is_file() else {}; " +
            "d[sys.argv[1]]=(sys.argv[2]=='1'); " +
            "t=p.with_suffix('.json.tmp'); t.write_text(json.dumps(d,indent=2)); os.replace(t,p)",
            key, val ? "1" : "0"]);
    }
    function toggleSuspendShellGaming() {
        root.cfgSuspendShellGaming = !root.cfgSuspendShellGaming;
        root.patchAppearanceBool("suspendShellGaming", root.cfgSuspendShellGaming);
    }
    function toggleAutoPowerBattery() {
        root.cfgAutoPowerBattery = !root.cfgAutoPowerBattery;
        root.patchAppearanceBool("autoPowerBattery", root.cfgAutoPowerBattery);
        if (root.cfgAutoPowerBattery && UPower.displayDevice && UPower.displayDevice.isLaptopBattery) {
            Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-power-auto.sh").toString().replace("file://", ""),
                UPower.onBattery ? "battery" : "ac"]);
        }
    }
    Connections {
        target: UPower
        function onOnBatteryChanged() {
            if (!root.cfgAutoPowerBattery || root.gameOn) return;
            Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-power-auto.sh").toString().replace("file://", ""),
                UPower.onBattery ? "battery" : "ac"]);
        }
    }
    // order of the right-hand bar widgets (drag-reorder in Settings → Bar widgets).
    // Values are the widget ids; the bar positions each right-group pill by its index here,
    // so reordering this list reorders the pills. Unknown/absent ids fall to the far end.
    // wgMpris is the centre pill and ignores its position; wgRec is the transient recorder.
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgAi","wgGithub","wgTotem","wgUpdates","wgNet","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgMic","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
    property var cfgWidgetOrder: root.defaultWidgetOrder
    // left cluster order (logo · workspaces · window-title) — drag-reorder in Settings → Bar widgets
    readonly property var defaultLeftOrder: ["lgLogo","lgWork","lgScratch","lgTitle"]
    property var cfgLeftOrder: root.defaultLeftOrder
    // append any ids missing from a saved order (e.g. new ones added in an update)
    // Merge widgets added by an update into a saved order. They land where the
    // default order says they belong -- immediately after the nearest earlier
    // default-neighbour the saved order already has -- rather than being pushed
    // onto the end. Appending was wrong on a right-anchored bar: the end is past
    // the power button, which is deliberately last, so every new widget arrived
    // in the one position nothing should occupy.
    function reconcileOrder(order, def) {
        // Drop repeats before anything else. A saved order can legitimately contain the same id
        // twice: settings.qml's copy of the default list carried wgUpdates and wgNet in it twice,
        // so its reorder list showed two identical rows and dragging either wrote the duplicate
        // straight back out to disk. The registries match again, but a config written by any
        // build up to 6.0 still holds the damage, and a repeated id renders a repeated pill.
        var res = [];
        for (var d = 0; d < order.length; d++)
            if (res.indexOf(order[d]) < 0) res.push(order[d]);
        for (var i = 0; i < def.length; i++) {
            if (res.indexOf(def[i]) >= 0) continue;
            var at = res.length;                       // nothing to anchor to → end
            for (var j = i - 1; j >= 0; j--) {
                var k = res.indexOf(def[j]);
                if (k >= 0) { at = k + 1; break; }
            }
            res.splice(at, 0, def[i]);
        }
        return res;
    }
    // horizontal bar only — left/right (a vertical bar) was removed; this shell was never
    // designed for it and the narrow strip never laid out cleanly. Kept as a constant so the
    // (now dormant) orientation-aware branches below all resolve to the horizontal layout.
    readonly property bool barVertical: root.cfgEdge === "left" || root.cfgEdge === "right"
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

    // Popup readability is independent of bar transparency and the window behind it.
    readonly property real dropOpacity: Tok.glassAlpha
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; touch \"$d/kitty-matugen.conf\"; [ -f \"$d/appearance.json\" ] || printf '{\"radius\":14,\"opacity\":0.80,\"height\":42,\"accent\":\"#63c7dd\",\"font\":\"Inter\"}' > \"$d/appearance.json\"; echo \"$d/appearance.json\""]
        // Seeding only. It used to also be what TOLD the FileView below where the file is,
        // which meant the bar's own colours waited on a shell fork before they could even
        // start loading — the second half of the blue flash. The path is known without
        // asking anything; only the mkdir/touch/seed needs a shell.
        stdout: StdioCollector { id: apprPathOut; onStreamFinished: apprFile.reload() } }
    FileView {
        id: apprFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/appearance.json"
        // Read before the first frame, for the same reason Tok.qml blocks: everything the
        // bar draws is a function of this file, and drawing once without it is a flash of
        // the defaults.
        blockLoading: true
        watchChanges: true
        function apply() { try {
            var t = text(); if(!t || !t.trim()) return; var j = JSON.parse(t);
            if (j.radius  !== undefined) root.cfgRadius  = j.radius;
            if (j.opacity !== undefined) root.cfgOpacity = j.opacity;
            if (j.barOpaque !== undefined) root.cfgBarOpaque = !!j.barOpaque;
            root.cfgGlass = (j.glass === "solid" || j.glass === "clear") ? j.glass : "frosted";
            if (j.wpTransitionDur !== undefined) root.cfgWpTransitionDur = j.wpTransitionDur;
            root.cfgWpCoverStill = j.wpCoverStill !== false;
            root.cfgWpBatteryStill = !!j.wpBatteryStill;
            root.cfgWpVidFps = parseInt(j.wpVidFps) || 0;
            if (j.barFill !== undefined && (""+j.barFill).length>0) root.cfgBarFill = j.barFill;
            // top / bottom only — this shell is a horizontal bar; left/right were dropped.
            if (j.edge === "top" || j.edge === "bottom" || j.edge === "left" || j.edge === "right") root.cfgEdge = j.edge;
            if (j.height  !== undefined) root.cfgHeight  = j.height;
            if (j.dock !== undefined) root.cfgDock = !!j.dock;
            if (j.dockEdge === "top" || j.dockEdge === "bottom" || j.dockEdge === "left" || j.dockEdge === "right") root.cfgDockEdge = j.dockEdge;
            if (j.dockIcon !== undefined) root.cfgDockIcon = j.dockIcon;
            if (j.dockMode === "always" || j.dockMode === "autohide" || j.dockMode === "intelligent") root.cfgDockMode = j.dockMode;
            if (j.dockZoom !== undefined) root.cfgDockZoom = !!j.dockZoom;
            if (j.dockRunning !== undefined) root.cfgDockRunning = !!j.dockRunning;
            if (j.dockLabels !== undefined) root.cfgDockLabels = !!j.dockLabels;
            if (j.scale   !== undefined) root.cfgScale   = j.scale;
            if (j.accent  !== undefined && (""+j.accent).length>0) root.cfgAccent = j.accent;
            if (j.font    !== undefined && (""+j.font).length>0)   root.cfgFont   = Tok.resolveFont(j.font);
            if (j.mode    !== undefined) root.cfgLight = (""+j.mode === "light");
            if (j.wgMpris !== undefined) root.cfgMpris = !!j.wgMpris;
            if (j.wgMic !== undefined) root.cfgMic = !!j.wgMic;
            if (j.wgTray !== undefined) root.cfgTray = !!j.wgTray;
            if (j.wgWeather !== undefined) root.cfgWeather = !!j.wgWeather;
            if (j.wgClipboard !== undefined) root.cfgClipboard = !!j.wgClipboard;
            if (j.wgNotif !== undefined) root.cfgNotif = !!j.wgNotif;
            if (j.wgWifi !== undefined) root.cfgWifi = !!j.wgWifi;
            if (j.wgBluetooth !== undefined) root.cfgBluetooth = !!j.wgBluetooth;
            if (j.wgKdeconnect !== undefined) root.cfgKdeconnect = !!j.wgKdeconnect;
            if (j.wgCaffeine !== undefined) root.cfgCaffeine = !!j.wgCaffeine;
            if (j.wgSystem !== undefined) root.cfgSystem = !!j.wgSystem;
            if (j.wgVolume !== undefined) root.cfgVolume = !!j.wgVolume;
            if (j.wgBattery !== undefined) root.cfgBattery = !!j.wgBattery;
            if (j.wgClock !== undefined) root.cfgClock = !!j.wgClock;
            if (j.clock24 !== undefined) root.cfgClock24 = !!j.clock24;
            if (j.clockSeconds !== undefined) root.cfgClockSeconds = !!j.clockSeconds;
            if (j.wgPower !== undefined) root.cfgPower = !!j.wgPower;
            if (j.wgQuick !== undefined) root.cfgQuick = !!j.wgQuick;
            if (j.wgUpdates !== undefined) root.cfgUpdates = !!j.wgUpdates;
            if (j.wgNet !== undefined) root.cfgNet = !!j.wgNet;
            if (j.wgAi !== undefined) root.cfgAi = !!j.wgAi;
            if (j.wgGithub !== undefined) root.cfgGithub = !!j.wgGithub;
            if (j.wgTotem !== undefined) root.cfgTotem = !!j.wgTotem;
            if (j.aiOn && typeof j.aiOn === "object") {
                var prevDefault = root.cfgAiDefault;
                root.cfgAiOn = j.aiOn;
                if (typeof j.aiDefault === "string" && j.aiDefault !== "" && root.aiKnown(j.aiDefault)) {
                    if (j.aiDefault !== prevDefault) root.aiFocus = j.aiDefault;
                    root.cfgAiDefault = j.aiDefault;
                } else if (j.aiDefault === "") root.cfgAiDefault = "";
            } else if (j.aiDefault === "" || (typeof j.aiDefault === "string" && root.aiKnown(j.aiDefault))) {
                if (j.aiDefault && j.aiDefault !== root.cfgAiDefault) root.aiFocus = j.aiDefault;
                root.cfgAiDefault = j.aiDefault || "";
            }
            if (j.aiDigits === 0 || j.aiDigits === 1 || j.aiDigits === 2) root.cfgAiDigits = j.aiDigits;
            if (j.hotCorners && typeof j.hotCorners === "object") root.cfgHotCorners = j.hotCorners;
            if (j.wgNight !== undefined) root.cfgNightWidget = !!j.wgNight;
            if (j.barShape === "bar" || j.barShape === "pills") root.cfgBarShape = j.barShape;
            if (j.wsStyle === "grow" || j.wsStyle === "pill" || j.wsStyle === "circle") root.cfgWsStyle = j.wsStyle;
            if (j.wsLabel !== undefined && (""+j.wsLabel).length > 0) root.cfgWsLabel = ""+j.wsLabel;
            if (j.barLogo !== undefined && (""+j.barLogo).length > 0) root.cfgBarLogo = ""+j.barLogo;
            if (j.barLogoPath !== undefined) root.cfgBarLogoPath = ""+j.barLogoPath;
            root.cfgStickerPower = j.stickerPower ? ""+j.stickerPower : "";
            root.cfgStickerMedia = j.stickerMedia ? ""+j.stickerMedia : "";
            if (j.autoHide !== undefined) root.cfgAutoHide = !!j.autoHide;
            if (j.hideFullscreen !== undefined) root.cfgHideFullscreen = !!j.hideFullscreen;
            if (j.hideGaming !== undefined) root.cfgHideGaming = !!j.hideGaming;
            if (j.suspendShellGaming !== undefined) root.cfgSuspendShellGaming = !!j.suspendShellGaming;
            if (j.autoPowerBattery !== undefined) root.cfgAutoPowerBattery = !!j.autoPowerBattery;
            if (j.night !== undefined) root.cfgNight = !!j.night;
            if (j.nightTemp !== undefined) root.cfgNightTemp = j.nightTemp;
            if (j.nightAuto !== undefined) root.cfgNightAuto = !!j.nightAuto;
            if (j.sysShow !== undefined && Array.isArray(j.sysShow) && j.sysShow.length > 0) root.cfgSysShow = j.sysShow;
            if (j.wgStyle !== undefined && j.wgStyle !== null && typeof j.wgStyle === "object") root.cfgWgStyle = j.wgStyle;
            if (j.attnFlash !== undefined) root.cfgAttnFlash = !!j.attnFlash;
            if (j.attnFocus !== undefined) root.cfgAttnFocus = !!j.attnFocus;
            if (j.widgetOrder !== undefined && Array.isArray(j.widgetOrder) && j.widgetOrder.length > 0) root.cfgWidgetOrder = root.reconcileOrder(j.widgetOrder, root.defaultWidgetOrder);
            if (j.leftOrder !== undefined && Array.isArray(j.leftOrder) && j.leftOrder.length > 0) root.cfgLeftOrder = root.reconcileOrder(j.leftOrder, root.defaultLeftOrder);
            if (j.monitors !== undefined && j.monitors && typeof j.monitors === "object") root.cfgMonitors = j.monitors;
            if ((root.cfgLight ? 1 : 0) !== root._appliedMode) root.applyMode();  // sync system + kitty on flip/startup
        } catch(e) {} }
        // Same trap as Tok.qml: with blockLoading the bytes are present when construction
        // finishes and NO load signal is emitted, so onLoaded alone never fires and the
        // bar draws its first frame against the defaults regardless.
        Component.onCompleted: apply()
        onLoaded: apply()
        // Reload only on disk changes; onLoaded parses without starting another load.
        onFileChanged: reload()
    }
    // auto dark-mode schedule — sea-theme-schedule.sh flips `mode` in appearance.json
    // when the clock crosses the configured window; the FileView above then applies it.
    Process { id: themeSched; command: ["sh", Qt.resolvedUrl("sea-theme-schedule.sh").toString().replace("file://","")] }

    // ---------- the global menu's supply ----------
    // sea-appmenu.py follows Hyprland's focus events and rewrites a JSON snapshot of the
    // focused window's menu bar; GlobalMenu.qml watches that file. Kept as a daemon rather
    // than run per focus change because starting python and connecting to the accessibility
    // bus costs more than the walk it then performs.
    // Does the desktop currently carry a media widget? cava is expensive enough that it is
    // not left running for a visualiser nobody has put on screen, and cheap enough that it
    // is worth running when they have.
    property bool desktopHasMedia: false
    FileView {
        id: desktopPeek
        path: Quickshell.env("HOME") + "/.config/sea-shell/desktop.json"
        watchChanges: true
        function apply() {
            try {
                var t = text();
                var j = (t && t.trim()) ? JSON.parse(t) : null;
                var its = (j && j.items) ? j.items : [];
                var hit = false;
                for (var i = 0; i < its.length; i++) if (its[i].kind === "media") hit = true;
                root.desktopHasMedia = hit;
            } catch (e) { root.desktopHasMedia = false }
        }
        // Reload only on disk changes; onLoaded parses without starting another load.
        onFileChanged: reload()
        onLoaded: apply()
        Component.onCompleted: apply()
    }

    // Wrapper prefers Rust sea-appmenu when install.sh built it (SEA_APPMENU_PY=1 → Python).
    readonly property string appmenuScript: Qt.resolvedUrl("sea-appmenu.sh").toString().replace("file://","")
    // The global menu's own settings, shared with the sidecar — it re-reads this file on
    // every pass, so the background-reading switch takes effect without a restart. Kept out
    // of appearance.json for exactly that reason: python should not have to parse the bar's
    // theme to find out whether it may open a menu.
    property bool gmenuEnabled: true
    property bool gmenuAccel: true
    property bool gmenuPrime: false
    // Flip the strip on or off and remember it. Writes the same file Settings owns, whole,
    // so a right-click never silently drops the other two switches.
    property double gmenuLastToggle: 0
    function gmenuToggle() {
        // SPAMMING THIS USED TO WEDGE IT. Two toggles in the same instant meant two shell
        // writes in flight over one file, and `> file` truncates before it writes — so the
        // watcher below could read the empty middle of one of them, fail to parse, and fall
        // back to defaults that no longer matched what was on disk. After that every further
        // toggle flipped from the wrong value. The write is now atomic (temp file, then
        // rename, which is what the sidecar has always done) and a second toggle inside
        // 250ms is ignored, because nobody means two.
        var now = Date.now();
        if (now - root.gmenuLastToggle < 250) return;
        root.gmenuLastToggle = now;
        root.gmenuEnabled = !root.gmenuEnabled;
        var j = JSON.stringify({ enabled: root.gmenuEnabled,
                                 accelerators: root.gmenuAccel,
                                 prime: root.gmenuPrime });
        Quickshell.execDetached(["sh", "-c",
            "d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; "
            + "printf %s " + JSON.stringify(Qt.btoa(j))
            + " | base64 -d > \"$d/.appmenu.tmp\" && mv -f \"$d/.appmenu.tmp\" \"$d/appmenu.json\""]);
    }
    FileView {
        id: appmenuCfg
        path: Quickshell.env("HOME") + "/.config/sea-shell/appmenu.json"
        watchChanges: true
        function apply() {
            try {
                var t = text();
                var j = (t && t.trim()) ? JSON.parse(t) : {};
                root.gmenuEnabled = (j.enabled === undefined) ? true : !!j.enabled;
                root.gmenuAccel   = (j.accelerators === undefined) ? true : !!j.accelerators;
                root.gmenuPrime   = (j.prime === undefined) ? false : !!j.prime;
            } catch (e) {
                // KEEP WHAT WE HAVE. An unreadable file here is almost always a write caught
                // half-done, not a request to go back to defaults — and resetting on it is
                // what made a burst of toggles end up disagreeing with the file on disk.
            }
        }
        // Reload only on disk changes; onLoaded parses without starting another load.
        onFileChanged: reload()
        onLoaded: apply()
        Component.onCompleted: apply()
    }
    Process {
        id: appmenuDaemon
        command: [root.appmenuScript, "--daemon"]
        // Switched off means OFF, not merely hidden: the sidecar walks an accessibility tree
        // on every focus change, and there is no reason to pay for that when nothing draws
        // the result.
        // NOT `running: root.gmenuEnabled`. The revive timer below assigns `running` by
        // hand, and in QML an imperative assignment DESTROYS the binding on that property —
        // so after the first revive the daemon stopped following the setting entirely and
        // could never be switched off again. Driving both from one handler keeps the single
        // source of truth without a binding for anything to clobber.
        running: true
        // It exits on its own if there is no accessibility bus to talk to, and a dead
        // daemon simply means the snapshot stops changing — the bar falls back to the
        // title, which is what it drew before any of this existed.
        onExited: if (root.gmenuEnabled) appmenuRevive.restart()
    }
    onGmenuEnabledChanged: {
        appmenuDaemon.running = root.gmenuEnabled;
        if (!root.gmenuEnabled) appmenuRevive.stop();
    }
    Timer { id: appmenuRevive; interval: 5000
        onTriggered: if (root.gmenuEnabled) appmenuDaemon.running = true }
    Timer { interval: 60000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: themeSched.running = true }
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
    Timer { interval: 6*3600*1000;    running: !root.gameHibernate; repeat: true;  onTriggered: calResyncProc.running = true }   // and every 6h

    // ---- reminder settings (calendar.json, written by settings/import script) ----
    property bool calRemind: true
    property int  calLead: 30
    Process { id: calCfgProc; running: true; command: ["sh","-c","cat ~/.config/sea-shell/calendar.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: calCfgOut; onStreamFinished: { try { var j=JSON.parse(calCfgOut.text.trim()||"{}");
            if(j.remind!==undefined) root.calRemind=!!j.remind; if(j.lead!==undefined) root.calLead=j.lead; } catch(e){} } } }
    Timer { interval: 5*60000; running: !root.gameHibernate; repeat: true; onTriggered: calCfgProc.running = true }   // pick up settings changes

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
    Timer { interval: 60000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: root.checkReminders() }

    // ---------- industrial token shim ----------
    // The ramp formulas now live once, in Tok.qml. This object survives only because ~190 call
    // sites in this file already speak its vocabulary; each name is remapped onto its industrial
    // role rather than re-deriving colours here (the old copy had already drifted from the one
    // in settings.qml and Dashboard.qml).
    //
    //   panel → surface        one step up from the ground, not a translucent card
    //   line  → ruleHard       used BOTH as a hairline and, via a(), as a fill — ruleHard keeps
    //                          the old fill relationship intact while moving to the new palette
    //   frost → ink2           icons go neutral, so the accent can go back to meaning "active"
    //                          instead of tinting every glyph on the bar
    QtObject {
        id: theme
        readonly property bool  light: root.cfgLight
        readonly property color _acc: root.cfgAccent
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
    // The bar owns the LIVE accent — matugen, theme profiles and the night toggle all land in
    // root.cfgAccent first — so push it into the shared tokens instead of letting Tok's own
    // file read race them. settings.qml takes over while its panel is open, for live preview.
    Binding { target: Tok; property: "accentRaw"; value: root.cfgAccent }
    Binding { target: Tok; property: "light";     value: root.cfgLight }
    Binding { target: Tok; property: "glassMode"; value: root.cfgGlass }

    // ---------- audio ----------
    property var sinks: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isSink && !n.isStream && n.audio })
    PwObjectTracker { objects: { var a = []; if (Pipewire.defaultAudioSink) a.push(Pipewire.defaultAudioSink); for (var i=0;i<root.sinks.length;i++) a.push(root.sinks[i]); return a } }
    // playing apps (output streams) — tracked so their per-app volume is live
    property var streams: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isStream && n.audio })
    function streamName(n) { return n ? (n.name || n.description || n.nickname || "app") : "" }
    PwObjectTracker { objects: root.streams }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "device") : "" }
    // For the output list: what the output IS ("Speaker", "HDMI 1"), with the card it lives on
    // as a second line. The full descriptions all start with the same controller name, which
    // made four rows read "Alder Lake PCH-P High Definition Aud…".
    function sinkLabel(n) {
        if (!n) return "";
        var nick = "" + (n.nickname || "");
        if (nick === "Speaker") return "Speakers";
        return nick || root.nodeName(n);
    }
    function sinkCard(n) {
        var d = n ? "" + (n.description || "") : "";
        var m = d.match(/^(.*?)\s+(High Definition Audio|HD Audio|Audio)\b/i);
        return m ? m[1] : (n && n.nickname ? d : "");
    }

    // ---------- sound: per-sink format + per-app routing (sea-audio.py, 4.0) ----------
    // Enriches the volume dropdown with what PipeWire's own model doesn't surface: each
    // output's live sample-rate / bit-depth (or a Bluetooth codec), and the ability to
    // send one app to a specific sink. A cheap pw-dump snapshot, taken only while the
    // dropdown is open; routing writes go straight back to pipewire and we re-read.
    readonly property string _audioScript: Qt.resolvedUrl("sea-audio.py").toString().replace("file://", "")
    property var audioSinks: ({})       // node.name -> {rate,format,bits,active,bt_codec,rates}
    property var audioStreams: []       // [{id,app,title,sink_id,sink_label}]
    Process {
        id: audioInfoProc
        command: ["python3", root._audioScript, "--status"]
        stdout: StdioCollector { id: audioInfoOut; onStreamFinished: {
            try {
                var j = JSON.parse(audioInfoOut.text.trim() || "{}");
                if (!j.ok) return;
                var m = {};
                for (var i = 0; i < (j.sinks || []).length; i++) m[j.sinks[i].name] = j.sinks[i];
                root.audioSinks = m;
                root.audioStreams = j.streams || [];
            } catch (e) {}
        } } }
    function audioRefresh() { audioInfoProc.running = true }
    Timer { id: audioRefreshTimer; interval: 350; onTriggered: root.audioRefresh() }
    // refresh while any volume dropdown is open (rate/streams change as apps come & go)
    Timer { running: root.openPop === "vol"; interval: 2000; repeat: true; triggeredOnStart: true; onTriggered: root.audioRefresh() }
    // "48k · 24-bit", or a codec name for bluetooth; idle sinks show the rate they'll run at
    function audioFmtBadge(nodeName) {
        var s = root.audioSinks[nodeName]; if (!s) return "";
        if (s.bt_codec) return ("" + s.bt_codec).toUpperCase();
        var khz = s.rate ? (s.rate % 1000 === 0 ? (s.rate / 1000) : (s.rate / 1000).toFixed(1)) + "k" : "";
        if (!s.active) return khz;                       // idle: only the rate is known
        return khz + (khz && s.bits ? " · " : "") + (s.bits ? s.bits + "-bit" : "");
    }
    function audioRoute(streamId, sinkRef) {
        Quickshell.execDetached(["python3", root._audioScript, "--route", "" + streamId, "" + sinkRef]);
        audioRefreshTimer.restart();
    }
    // click an app's chip to send it to the next output in the list (by node.name, which
    // the backend resolves robustly regardless of pipewire's id churn)
    function audioCycleRoute(stream) {
        var list = root.sinks; if (!list || !list.length) return;
        var idx = -1;
        for (var i = 0; i < list.length; i++) if (list[i].id === stream.sink_id) { idx = i; break; }
        var next = list[(idx + 1) % list.length];
        if (next) root.audioRoute(stream.id, next.name);
    }
    // the current output, if it's a bluetooth device offering a codec choice (else null)
    readonly property var audioBtSink: {
        var n = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.name : "";
        var s = root.audioSinks[n];
        return (s && s.bt_codecs && s.bt_codecs.length > 1) ? s : null;
    }
    // switch a bluetooth sink's A2DP codec (by stable node.name — the id churns on switch)
    function audioSetCodec(sinkName, profile) {
        Quickshell.execDetached(["python3", root._audioScript, "--bt-codec", "" + sinkName, "" + profile]);
        audioRefreshTimer.restart();
    }
    // bridge the Pipewire stream (which owns the volume) to sea-audio's routing view (keyed by id)
    function audioSinkLabelOf(pwId) {
        for (var i = 0; i < root.audioStreams.length; i++) if (root.audioStreams[i].id === pwId) return root.audioStreams[i].sink_label || "default";
        return "default";
    }
    function audioCycleRouteById(pwId) {
        var e = null;
        for (var i = 0; i < root.audioStreams.length; i++) if (root.audioStreams[i].id === pwId) { e = root.audioStreams[i]; break; }
        root.audioCycleRoute(e || { id: pwId, sink_id: -1 });
    }

    // ---------- exclusive (bit-perfect) playback ----------
    // PipeWire is NOT the source of truth for playback. A bit-perfect player (SONE,
    // TIDAL) opens the card directly via exclusive ALSA: the graph never sees the
    // stream, defaultAudioSink cheerfully reports "Speaker" while the music is
    // physically going out another device, and PipeWire may not even keep a node for
    // a card it cannot open. So this goes around PipeWire entirely — the kernel says
    // who holds the card.
    //
    // What survives here is deliberately GENERIC. This used to be half of a Moondrop
    // DAC integration, keyed to a vendor registry, and the DAC panel is gone — but
    // "something has taken the card and pipewire cannot see the audio" is not a
    // Moondrop fact. The recorder needs it, because system audio captured from a
    // monitor while a card is held exclusively records silence.
    property string exclCard: ""     // ALSA card index held outside pipewire
    property string exclUsbId: ""    // its "vid:pid", empty for non-USB cards
    property string exclHolder: ""   // owning process name, e.g. "alsa-writer"
    readonly property bool exclusiveHold: root.exclCard !== ""
    Process {
        id: exclProc
        command: ["sh","-c",
            "for d in /proc/asound/card*/pcm*p/sub*; do " +
              "[ -f \"$d/status\" ] || continue; " +
              "s=$(head -1 \"$d/status\"); case \"$s\" in *closed*) continue;; esac; " +
              "pid=$(awk '/owner_pid/{print $3}' \"$d/status\"); " +
              "comm=$(cat /proc/$pid/comm 2>/dev/null); " +
              "case \"$comm\" in pipewire*|wireplumber*) continue;; esac; " +
              "c=${d#/proc/asound/card}; c=${c%%/*}; " +
              "printf '%s|%s|%s' \"$c\" \"$(cat /proc/asound/card$c/usbid 2>/dev/null)\" \"$comm\"; " +
              "exit 0; " +
            "done"]
        stdout: StdioCollector { id: exclOut; onStreamFinished: {
            var p = exclOut.text.trim().split("|");
            root.exclCard = p[0] || ""; root.exclUsbId = (p[1] || "").toLowerCase(); root.exclHolder = p[2] || "";
        } } }
    Timer { interval: 8000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true
            onTriggered: exclProc.running = true }

    // Short name for a sink: the nickname ("Speaker") beats the description
    // ("Alder Lake PCH-P High Definition Audio Controller Speaker") on a bar.
    function sinkShort(n) { return n ? (n.nickname || n.description || n.name || "output") : "—" }
    readonly property string outputLabel: root.sinkShort(Pipewire.defaultAudioSink)

    // ---------- microphone ----------
    // The only genuinely absent widget: Volume covers the sink and nothing in the shell has ever
    // touched the source, so an open mic was invisible. wpctl is the authority rather than the
    // Pipewire binding because @DEFAULT_AUDIO_SOURCE@ follows the default-source change the same
    // way the volume keys do — tracking a node id instead would go stale the moment it moves.
    // Pipewire.defaultAudioSource follows that same default, and changes arrive as they happen.
    readonly property var micSource: Pipewire.defaultAudioSource
    PwObjectTracker { objects: root.micSource ? [root.micSource] : [] }
    readonly property bool micMuted: !!(root.micSource && root.micSource.audio && root.micSource.audio.muted)
    readonly property real micVol: (root.micSource && root.micSource.audio) ? root.micSource.audio.volume : 0
    readonly property string micName: root.micSource ? (root.micSource.nickname || root.micSource.description || "") : ""
    function micToggle() {
        Quickshell.execDetached(["sh","-c","wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"]);
    }

    // ---------- battery health ----------
    // Read when the battery dropdown opens; wear moves over months, not minutes.
    property int batHealth: -1
    property int batCycles: -1
    Process { id: batHealthProc
        command: ["sh","-c","for b in /sys/class/power_supply/BAT*; do [ -d \"$b\" ] || continue; "
            + "for k in charge_full charge_full_design energy_full energy_full_design cycle_count; do "
            + "[ -r \"$b/$k\" ] && echo \"$k=$(cat \"$b/$k\")\"; done; break; done"]
        stdout: StdioCollector { id: batHealthOut; onStreamFinished: {
            var v = {};
            batHealthOut.text.trim().split("\n").forEach(function(l) {
                var kv = l.split("=");
                if (kv.length === 2) v[kv[0]] = parseFloat(kv[1]);
            });
            var full = v.charge_full || v.energy_full, design = v.charge_full_design || v.energy_full_design;
            root.batHealth = (full > 0 && design > 0) ? Math.min(100, Math.round(full / design * 100)) : -1;
            root.batCycles = v.cycle_count > 0 ? Math.round(v.cycle_count) : -1;
        } } }

    // ---------- wifi ----------
    property var wifiList: []
    property int wifiSeen: 0          // distinct SSIDs the scan found, before the list is capped
    readonly property bool wifiScanning: wifiScan.running
    property string ssid: ""
    property bool wifiOn: false
    // the joined network's strength (0–100) from the last scan, for the network widget
    readonly property int wifiSig: {
        for (var i = 0; i < root.wifiList.length; i++) if (root.wifiList[i].active) return root.wifiList[i].signal || 0;
        return 0;
    }
    // A join in flight: the network we asked for, or the one NetworkManager is bringing up on
    // its own (auto-reconnect after resume). Without it the icon stayed on "off" and the row
    // on its old look for the whole handshake, so a click seemed to do nothing for 5–10 s.
    property string wifiAsked: ""
    property string wifiDevConnecting: ""
    readonly property string wifiConnectingTo: root.wifiAsked !== "" ? root.wifiAsked : root.wifiDevConnecting
    readonly property bool wifiBusy: root.wifiConnectingTo !== ""
    // steps the bars 1 → 2 → 3 while busy, so the pill reads as working rather than off
    property int wifiPhase: 0
    Timer { interval: 420; repeat: true; running: root.wifiBusy && !root.gameHibernate
        onRunningChanged: root.wifiPhase = 0
        onTriggered: root.wifiPhase = (root.wifiPhase + 1) % 3 }
    readonly property string wifiIcon: root.wifiBusy ? ["wifi_1_bar", "wifi_2_bar", "wifi"][root.wifiPhase]
                                                     : (root.wifiOn ? "wifi" : "wifi_off")
    readonly property color wifiAccent: root.wifiBusy ? theme.sub : (root.wifiOn ? theme.frost : theme.bad)
    // Connection state comes from the DEVICE state (authoritative + instant), NOT from
    // the scan list's ACTIVE column. That column depends on scan freshness and can drop
    // the active AP for several polls right after a reconnect — which left the bar icon
    // stuck on "disconnected". `dev status` always reflects reality, so poll it on its own.
    Process {
        id: wifiStatus; running: true
        command: ["sh","-c","nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null | awk -F: '$2==\"wifi\"{print $3 \"\\t\" $4; exit}'"]
        stdout: StdioCollector { id: wifiStatOut; onStreamFinished: {
            var t = wifiStatOut.text.replace(/\n$/,"");
            if (!t) { root.wifiOn = false; root.ssid = ""; root.wifiDevConnecting = ""; return }
            var p = t.split("\t"); var st = p[0]||""; var conn = p[1]||"";
            root.wifiOn = (st === "connected");
            root.ssid = root.wifiOn ? conn : "";
            root.wifiDevConnecting = st.indexOf("connecting") === 0 ? (conn || "network") : "";
        } }
    }
    Timer { interval: root.wifiBusy ? 1000 : 10000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: wifiStatus.running = true }
    // the network list for the dropdown (styling only — active row cross-checks the
    // connected SSID from dev status so a stale ACTIVE column can't mis-highlight)
    //
    // `nmcli dev wifi` PRINTS NM'S CACHE — it is not a scan. NetworkManager only re-probes the
    // air on its own schedule (minutes apart), so polling that cache faster just re-renders the
    // same rows; that's why the dropdown looked frozen until something else forced a scan.
    // `list --rescan yes` re-probes and waits for the result, but it costs a real radio sweep —
    // so it's spent only while the user is looking (see the while-open timer below) and the idle
    // background poll stays on the cheap cached read.
    function wifiScanCmd(force) {
        return ["sh","-c","nmcli -t -f ACTIVE,SIGNAL,SECURITY,SSID dev wifi list --rescan "
            + (force ? "yes" : "no") + " 2>/dev/null | awk -F: 'length($4)>0'"];
    }
    // force=true re-probes the air. A scan already in flight is left to finish: setting
    // running=true on a live Process is a no-op, so re-entering here would silently drop it.
    function wifiRescan(force) {
        wifiStatus.running = true;
        wifiSavedScan.running = true;
        if (wifiScan.running) return;
        wifiScan.command = root.wifiScanCmd(force);
        wifiScan.running = true;
    }
    Process {
        id: wifiScan; running: true
        command: root.wifiScanCmd(false)
        stdout: StdioCollector { id: wifiOut; onStreamFinished: {
            // nmcli returns one row per BSSID, so a mesh/repeater SSID repeats and eats list
            // slots — collapse each name to its strongest sighting, then take the top 8 DISTINCT.
            var best = {}; var order = []; var lines = wifiOut.text.trim().split("\n");
            for (var i=0;i<lines.length;i++){ if(!lines[i])continue; var p=lines[i].split(":");
                var sid=p.slice(3).join(":").replace(/\\:/g,":");   // terse mode escapes ':' in SSIDs
                if(!sid) continue;
                var e={active:(p[0]==="yes")||(root.ssid!=="" && sid===root.ssid),signal:parseInt(p[1])||0,secure:(p[2]||"").length>0,sec:(p[2]||""),ssid:sid};
                if (!(sid in best)) { best[sid]=e; order.push(sid) }
                else if (e.signal > best[sid].signal) { e.active = e.active || best[sid].active; best[sid]=e }
                else if (e.active) best[sid].active = true; }
            var out = order.map(function(s){ return best[s] });
            out.sort(function(a,b){ return Number(b.active) - Number(a.active) || b.signal - a.signal });
            root.wifiSeen = out.length;
            root.wifiList = out.slice(0,8);
        } }
    }
    // nmcli's SECURITY column is a space-separated list — "WPA1 WPA2", "WPA2 802.1X" — and the row
    // has room for one short word, so report the strongest scheme present: that is what the link
    // will negotiate. An open network is NAMED rather than shown nothing, because a row with no
    // marking on it reads as one that failed to render, not one with no encryption.
    function wifiSecLabel(s) {
        var t = ("" + (s || "")).toUpperCase();
        if (!t.length)              return "OPEN";
        if (t.indexOf("WPA3") >= 0) return "WPA3";
        if (t.indexOf("WPA2") >= 0) return "WPA2";
        if (t.indexOf("WPA")  >= 0) return "WPA";
        if (t.indexOf("WEP")  >= 0) return "WEP";
        return t.split(" ")[0];
    }
    Timer { interval: 30000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: root.wifiRescan(false) }
    // dropdown open → the list has to be live: re-probe on open (triggeredOnStart) and keep
    // re-probing, so signal bars move and vanished APs drop off without a manual poke.
    Timer { interval: 8000; running: root.openPop === "wifi"; repeat: true; triggeredOnStart: true
        onTriggered: root.wifiRescan(true) }
    property string wifiPwFor: ""     // edited independently from the volatile scan list
    property string wifiDraft: ""
    property string wifiIdentity: ""
    // latched when the card opens, so the network dropping out of a rescan can't flip the form
    property bool wifiPwEnterprise: false
    property string wifiJoinMessage: ""
    property bool wifiJoinFailed: false
    readonly property bool wifiJoining: wifiJoinProc.running || wifiUp.running
    onWifiPwForChanged: {
        root.wifiDraft = ""; root.wifiJoinMessage = ""; root.wifiJoinFailed = false;
        root.wifiPwEnterprise = root.wifiIsEnterprise(root.wifiPwFor);
    }
    function wifiIsEnterprise(s) {
        for (var i = 0; i < root.wifiList.length; i++)
            if (root.wifiList[i].ssid === s) return WifiEnterprise.isEnterprise(root.wifiList[i].sec);
        return false;
    }
    function wifiCancelDraft() { if (!root.wifiJoining) root.wifiPwFor = "" }
    Process {
        id: wifiJoinProc
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.wifiPwFor = "";
                root.wifiJoinMessage = "Connected";
                root.wifiJoinFailed = false;
            } else {
                root.wifiJoinFailed = true;
                root.wifiJoinMessage = root.wifiPwEnterprise
                    ? "Could not sign in. Check your username and password."
                    : "Could not connect. Check the password and try again.";
            }
            wifiJoinProc.command = [];
            root.wifiAsked = "";
            root.wifiRescan(false);
        }
    }
    property string wifiRetry: ""     // ssid whose saved profile we're trying first
    // Saved (known) networks — the settings panel has always tracked these; the bar did not, and
    // that was the whole bug below. Also drives the "saved" tag and the forget action.
    property var wifiSaved: []
    Process { id: wifiSavedScan; running: true
        command: ["sh","-c","nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2==\"802-11-wireless\"{print $1}'"]
        stdout: StdioCollector { id: wsOut; onStreamFinished: {
            var t = wsOut.text.trim();
            root.wifiSaved = t ? t.split("\n") : [];
        } } }
    function wifiForget(s) {
        var e = s.replace(/'/g,"");
        Quickshell.execDetached(["sh","-c","nmcli con delete id '"+e+"' 2>/dev/null; notify-send 'sea-shell' 'Forgot "+e+"'"]);
        wifiRefresh.start();
    }
    // known networks reconnect with their STORED password (`nmcli con up`); the
    // inline field only appears for new networks or when the saved secret fails.
    Process { id: wifiUp
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && root.wifiRetry !== "") {
                root.wifiPwFor = root.wifiRetry;
                root.wifiJoinMessage = "Saved credentials did not connect. Enter the password to retry.";
            } else {
                if (exitCode !== 0)
                    Quickshell.execDetached(["notify-send", "sea-shell", "Could not join " + root.wifiAsked]);
                root.wifiPwFor = "";
            }
            root.wifiAsked = "";
            wifiStatus.running = true;
            root.wifiRetry = "";
            wifiRefresh.start();
        }
    }
    function wifiConnect(s, secure) {
        if (root.wifiJoining) return;
        var e = s.replace(/'/g,"");
        if (secure) {
            // Only try the stored profile if one actually EXISTS. This used to fire `con up` at
            // every secured network including ones never seen before, which always failed — so
            // joining a new network cost a guaranteed round-trip through nmcli before the
            // password field appeared. settings.qml had the savedCons check; the bar didn't.
            if (root.wifiSaved.indexOf(s) >= 0) {
                root.wifiRetry = s; root.wifiAsked = s;
                wifiUp.command = ["nmcli", "--wait", "25", "con", "up", "id", s];
                wifiUp.running = true; return;
            }
            root.wifiPwFor = s; return;       // never seen → ask straight away
        }
        root.wifiPwFor = ""; root.wifiRetry = ""; root.wifiAsked = s;
        wifiUp.command = ["nmcli", "--wait", "25", "dev", "wifi", "connect", s];
        wifiUp.running = true;
    }
    // Argument arrays preserve SSIDs/passwords exactly; completion comes from nmcli's exit code.
    function wifiJoin(s, pw) {
        if (root.wifiJoining || !s.length || !pw.length) return;
        if (root.wifiPwEnterprise && !root.wifiIdentity.length) return;
        root.wifiJoinFailed = false;
        root.wifiJoinMessage = "Connecting…";
        root.wifiAsked = s;
        if (root.wifiPwEnterprise) {
            wifiJoinProc.command = WifiEnterprise.joinCmd(s, root.wifiIdentity, pw);
        } else {
            wifiJoinProc.command = ["nmcli", "--wait", "25", "dev", "wifi", "connect", s, "password", pw];
        }
        wifiJoinProc.running = true;
    }
    function wifiToggle() { Quickshell.execDetached(["sh","-c","nmcli radio wifi | grep -q enabled && nmcli radio wifi off || nmcli radio wifi on"]); wifiRefresh.start() }
    Timer { id: wifiRefresh; interval: 2500; onTriggered: root.wifiRescan(true) }

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
    Timer { interval: 15000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true
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
    Timer { interval: 15000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: vpnScan.running = true }
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
    // The Batteries widget's rows: this computer and every connected Bluetooth device that
    // reports a level. Built here because MaterialWidget is plain QtQuick (it loads in tests).
    readonly property var widgetBatteries: {
        var out = [], d0 = UPower.displayDevice;
        if (d0 && d0.isLaptopBattery)
            out.push({ n: "This computer", i: "laptop_chromebook", p: (d0.percentage || 0) * 100, c: !UPower.onBattery });
        var ds = root.btDevices;
        for (var i = 0; i < ds.length; i++) {
            var d = ds[i];
            if (!d || !d.connected || !d.batteryAvailable) continue;
            var ic = "" + (d.icon || "");
            out.push({ n: root.btName(d), p: (d.battery || 0) * 100, c: false,
                       i: /headset|audio|headphone/.test(ic) ? "headphones" : /mouse/.test(ic) ? "mouse" : /keyboard/.test(ic) ? "keyboard"
                        : /phone/.test(ic) ? "smartphone" : /game/.test(ic) ? "sports_esports" : "bluetooth" });
        }
        return out;
    }
    readonly property string widgetBatEta: {
        var d = UPower.displayDevice; if (!d || !d.isLaptopBattery) return "";
        var sec = UPower.onBattery ? d.timeToEmpty : d.timeToFull;
        if (!(sec > 0)) return UPower.onBattery ? "" : ((d.percentage || 0) >= 0.995 ? "Fully charged" : "Charging");
        var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
        return (h ? h + " h " : "") + m + " min" + (UPower.onBattery ? " left" : " to full");
    }
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
    // The lock screen runs as its own process and fetches nothing, so the bar hands it the
    // weather and the next two events through a small file in the runtime dir (lock.qml reads it).
    function writeGlance() {
        var g = { wxTemp: root.wxTemp, wxCond: root.wxCond, at: Date.now(),
                  events: root.calUpcoming.slice(0, 2).map(e => ({ title: e.title || "", date: e.date || "", time: e.time || "" })),
                  bottles: root.bottleShore.slice(0, 2).map(b => ({ id: b.id || "", text: b.text || "" })) };
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"", "sh",
            JSON.stringify(g), (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sea-glance.json"]);
    }
    Timer { id: glanceWrite; interval: 1500; onTriggered: root.writeGlance() }
    onWxTempChanged: glanceWrite.restart()
    onWxCondChanged: glanceWrite.restart()
    onCalUpcomingChanged: glanceWrite.restart()
    onBottleShoreChanged: glanceWrite.restart()

    // ---------- Message in a bottle ----------
    readonly property string bottleScript: Qt.resolvedUrl("sea-bottle.py").toString().replace("file://", "")
    property var bottleShore: []   // recently washed-up notes for the lock screen
    property var bottleFloating: []
    function castBottle(text) {
        var t = ("" + (text || "")).trim();
        if (!t) return;
        Quickshell.execDetached(["python3", root.bottleScript, "cast", t]);
        bottleListProc.running = true;
        Quickshell.execDetached(["notify-send", "-a", "sea-shell", "-i", "mail-message-new",
            "Bottle cast", "It will wash up later — keep an eye on the tide."]);
    }
    Process {
        id: bottleDueProc
        command: ["python3", root.bottleScript, "due"]
        stdout: StdioCollector {
            id: bottleDueOut
            onStreamFinished: {
                try {
                    var due = JSON.parse(bottleDueOut.text.trim() || "[]") || [];
                    for (var i = 0; i < due.length; i++) {
                        var b = due[i];
                        Quickshell.execDetached(["notify-send", "-u", "normal", "-a", "sea-shell", "-i", "mail-unread",
                            "A bottle washed up", "" + (b.text || "")]);
                        var shore = root.bottleShore.slice();
                        shore.unshift(b);
                        root.bottleShore = shore.slice(0, 6);
                    }
                    if (due.length) bottleListProc.running = true;
                } catch (e) {}
            }
        }
    }
    Process {
        id: bottleListProc
        command: ["python3", root.bottleScript, "list"]
        stdout: StdioCollector {
            id: bottleListOut
            onStreamFinished: {
                try {
                    var j = JSON.parse(bottleListOut.text.trim() || "{}") || {};
                    root.bottleFloating = j.floating || [];
                    // keep shore notes that are still in the washed list
                    var washed = j.washed || [];
                    if (washed.length && root.bottleShore.length === 0)
                        root.bottleShore = washed.slice(0, 4);
                } catch (e) {}
            }
        }
    }
    Timer {
        interval: 45000; repeat: true; running: !root.gameHibernate; triggeredOnStart: true
        onTriggered: { bottleDueProc.running = true; bottleListProc.running = true }
    }
    IpcHandler {
        target: "bottle"
        function cast(text: string): void { root.castBottle(text) }
        function check(): void { bottleDueProc.running = true }
    }
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
    Timer { interval: 900000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: wxProc.running = true }
    // ---- forecast (3-day, from wttr.in j1) ----
    property var wxForecast: []     // [{day, icon, hi, lo, cond}]
    // the place the weather is for, as the widgets title it
    // no file is normal (Kuching is the default), so its absence is not worth a warning
    FileView { id: wxLocFile; path: Quickshell.env("HOME") + "/.config/sea-shell/location"; watchChanges: true; printErrors: false; onFileChanged: reload() }
    // RELOAD WITHOUT QUITTING. `qs kill` and starting again made Quickshell crash on its way
    // out (a Wayland teardown segfault) and put up its crash reporter every time. Reloading
    // the configuration in place rebuilds everything without ever exiting.
    // (the reload IPC is on the "shell" handler above)
    readonly property string wxLoc: (wxLocFile.text() || "Kuching").trim()
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
                    out.push({ day: (i===0?"Today":days[d.getDay()]),
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
    Timer { interval: 1800000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: { wxUnitProbe.running=true; wxfProc.running = true } }
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
    Timer { interval: 15000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: { ppGet.running = true; fanGet.running = true } }
    function setProfile(p) { Quickshell.execDetached(["powerprofilesctl","set",p]); root.powerProfile = p; ppRefresh.start() }
    Timer { id: ppRefresh; interval: 800; onTriggered: ppGet.running = true }

    // ---------- gaming fan preset (sea-perf.sh → root helper sea-fancurve) ----------
    // The row only exists once /usr/local/bin/sea-fancurve is installed: fan control needs root
    // and sea-fand, which only knows Acer's fan interface.
    property bool   hasFanCurve: false
    property string fanMode: "custom"     // auto | quiet | max | custom, read back by sea-perf.sh status
    Process { id: fanGet; running: true
        command: ["sh","-c","[ -x /usr/local/bin/sea-fancurve ] && echo 1 || echo 0; ~/.config/quickshell/sea-shell/sea-perf.sh status"]
        stdout: StdioCollector { id: fanOut; onStreamFinished: {
            var l = fanOut.text.trim().split("\n");
            root.hasFanCurve = l[0] === "1"; root.fanMode = l[1] || "custom";
        } } }
    function setFanMode(m) {
        root.fanMode = m;
        Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-perf.sh " + m]);
        fanRefresh.start();
    }
    // fancontrol takes about a second to restart; read back after it, not before
    Timer { id: fanRefresh; interval: 2500; onTriggered: { fanGet.running = true; ppGet.running = true } }

    // ---------- control center (quick toggles used by the "cc" dropdown) ----------
    function ccActive(k) {
        if (k === "dark") return !root.cfgLight;                       // "dark mode" tile lit while dark
        if (k === "caf")  return !root.idleOn;                         // lit while caffeine keeps the screen awake (hypridle killed)
        if (k === "dnd")  return root.silenced;
        if (k === "wifi") return root.wifiOn;
        if (k === "bt")   return !!(root.btAdapter && root.btAdapter.enabled);
        if (k === "night") return root.nightActive;
        if (k === "game") return root.gameOn;
        return false;
    }
    function ccToggle(k) {
        if (k === "dark") { Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-toggle-theme.sh").toString().replace("file://","")]); return; }
        if (k === "caf")  { root.toggleIdle(); return; }
        if (k === "dnd")  { root.toggleSilence(); return; }
        if (k === "wifi") { root.wifiToggle(); return; }
        if (k === "bt")   { if (root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled; return; }
        if (k === "night"){ Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-toggle-night.sh").toString().replace("file://","")]); return; }
        if (k === "game") { root.toggleGame(); return; }
    }

    // ---------- night light (hyprsunset — warms the screen in the evening) ----------
    property bool   cfgNight: false       // manual on/off (flipped by sea-toggle-night.sh → appearance.json)
    property int    cfgNightTemp: 4000    // colour temperature in Kelvin
    property bool   cfgNightAuto: false   // follow dark mode: warm whenever the shell is in dark mode
    property bool   hasNight: false       // hyprsunset present on PATH
    Process { id: nightAvailProc; running: true; command: ["sh","-c","command -v hyprsunset >/dev/null 2>&1 && echo 1 || echo 0"]
        stdout: StdioCollector { id: nightAvail; onStreamFinished: root.hasNight = nightAvail.text.trim() === "1" } }
    // active when: following dark mode → tied to the palette; otherwise the manual switch
    readonly property bool nightActive: root.cfgNightAuto ? root.cfgLight : root.cfgNight
    // re-probe for hyprsunset when night is switched on — covers installing it while the shell runs,
    // so night light works without a restart (the startup probe can predate the install).
    onNightActiveChanged: if (root.nightActive && !root.hasNight) nightAvailProc.running = true
    // hyprsunset holds the warm gamma while running; stopping it resets the screen instantly.
    // `running` is a pure binding — NEVER assign it imperatively (that clobbers the binding and
    // strands the daemon on when night is later switched off).
    Process { id: nightProc; running: root.hasNight && root.nightActive
        command: ["hyprsunset","-t", String(root.cfgNightTemp)] }
    // change temperature live on the running daemon via hyprsunset's hyprctl IPC — no restart, so
    // the binding above stays intact. Debounced so dragging the slider sends one settled update.
    Process { id: nightTempProc; command: ["hyprctl","hyprsunset","temperature", String(root.cfgNightTemp)] }
    Timer { id: nightTempDebounce; interval: 150
        onTriggered: if (root.hasNight && root.nightActive) nightTempProc.running = true }
    onCfgNightTempChanged: if (root.hasNight && root.nightActive) nightTempDebounce.restart()

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
    // A monitor whose workspace has no windows shows the desktop, and its widgets with it.
    readonly property bool desktopSeen: {
        var mons = Hyprland.monitors ? Hyprland.monitors.values : [];
        var tops = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < mons.length; i++) {
            var ws = mons[i] && mons[i].activeWorkspace;
            if (!ws) continue;
            var empty = true;
            for (var j = 0; j < tops.length && empty; j++)
                if (tops[j] && tops[j].workspace && tops[j].workspace.id === ws.id) empty = false;
            if (empty) return true;
        }
        return false;
    }
    // Sampling runs nvidia-smi, so it only runs while something on screen shows a reading.
    readonly property bool sysWanted: !root.gameHibernate && (root.cfgSystem || root.openPop === "sys" || root.widgetsScreen !== ""
        || root.dashShown || root.desktopSeen)
    Timer { interval: 3000; running: root.sysWanted; repeat: true; triggeredOnStart: true
        onTriggered: if (!sysProc.running) sysProc.running = true }
    // WHICH of those the bar pill actually shows.
    //
    // sea-sysmon.sh has been sampling all eleven values every 3s since the pill was written, and
    // the pill rendered exactly one of them — so a machine with a 6GB dGPU had its VRAM measured
    // on every tick and displayed nowhere. The metric list is a setting because there is no right
    // answer: a laptop wants battery-cheap CPU, a gaming box wants VRAM, and both are one line.
    // Per-widget pill appearance, written by Settings → Bar Widgets. Sparse: a widget with no
    // entry here draws exactly as it always did, so this is inert until somebody touches it.
    //   { wgWifi: { a: "iris", c: "icon", g: "outline" }, … }
    //   a = accent role (frost | iris | good | warn | bad | text) or a #hex
    //   c = content    (both | icon | value)
    //   g = ground     (filled | outline | bare)
    property var cfgWgStyle: ({})
    property var cfgSysShow: ["cpu"]
    readonly property var sysMetrics: ({
        cpu:  { l: "CPU",  v: function(){ return Math.round(root.cpuUsage) + "%" },
                c: function(){ return root.loadColor(root.cpuTemp, 78, 90) } },
        cput: { l: "CPU °", v: function(){ return Math.round(root.cpuTemp) + "°" },
                c: function(){ return root.loadColor(root.cpuTemp, 78, 90) } },
        ram:  { l: "RAM",  v: function(){ return Math.round(root.memPct) + "%" },
                c: function(){ return root.loadColor(root.memPct, 80, 92) } },
        ramg: { l: "RAM GiB", v: function(){ return root.memUsed.toFixed(1) + "G" },
                c: function(){ return root.loadColor(root.memPct, 80, 92) } },
        gpu:  { l: "GPU",  v: function(){ return Math.round(root.gpuUsage) + "%" },
                c: function(){ return root.loadColor(root.gpuTemp, 75, 87) } },
        gput: { l: "GPU °", v: function(){ return Math.round(root.gpuTemp) + "°" },
                c: function(){ return root.loadColor(root.gpuTemp, 75, 87) } },
        vram: { l: "VRAM", v: function(){ return root.gpuMemTotal > 0
                    ? Math.round(root.gpuMemUsed/root.gpuMemTotal*100) + "%" : "—" },
                c: function(){ return root.loadColor(root.gpuMemTotal > 0
                    ? root.gpuMemUsed/root.gpuMemTotal*100 : 0, 80, 93) } },
        vramg:{ l: "VRAM GiB", v: function(){ return root.gpuMemUsed.toFixed(1) + "G" },
                c: function(){ return root.loadColor(root.gpuMemTotal > 0
                    ? root.gpuMemUsed/root.gpuMemTotal*100 : 0, 80, 93) } }
    })
    // GPU metrics are dropped rather than shown as "—" on a machine with no discrete card.
    readonly property var sysShown: {
        var out = [];
        for (var i = 0; i < root.cfgSysShow.length; i++) {
            var k = root.cfgSysShow[i];
            if (!root.sysMetrics[k]) continue;
            if (!root.hasGpu && (k === "gpu" || k === "gput" || k === "vram" || k === "vramg")) continue;
            out.push(k);
        }
        return out.length ? out : ["cpu"];
    }
    readonly property string sysPillText: {
        var out = [];
        for (var i = 0; i < root.sysShown.length; i++) out.push(root.sysMetrics[root.sysShown[i]].v());
        return out.join("  ");
    }
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
    // This poll is also sea-record.sh's cleanup tick: its status branch sweeps the
    // pipewire mix a crashed "both" recording would otherwise strand (which holds the
    // microphone open). So it stays running even when nothing is being recorded.
    property bool recordingActive: false
    property string recordingTime: "00:00"
    property string recordingAudio: ""     // none | mic | system | both
    property string recordingWhat: ""      // region, or the output name
    // sea-record.sh writes this while recording. Reading it in-process each second costs
    // nothing; the status script only runs while it is there, or once to sweep it away.
    FileView {
        id: recState
        path: "/tmp/sea-record.pid"
        printErrors: false
        onLoaded: if (!recStatusProc.running) recStatusProc.running = true
        onLoadFailed: if (root.recordingActive && !recStatusProc.running) recStatusProc.running = true
    }
    Timer {
        interval: 1000; running: !root.gameHibernate || root.recordingActive; repeat: true; triggeredOnStart: true
        onTriggered: recState.reload()
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
                    root.recordingAudio = parts[3] !== undefined ? parts[2] : "";
                    root.recordingWhat  = parts[3] !== undefined ? parts[3] : "";
                }
            }
        }
    }
    // Right-clicking the pill throws the recording away, so it arms first and commits on
    // the second click — the pill visibly says "discard?" in between. An accidental
    // right-click on a bar you click at all day should not be able to delete a take.
    property bool recDiscardArmed: false
    Timer { id: recDisarm; interval: 2500; onTriggered: root.recDiscardArmed = false }
    onRecordingActiveChanged: if (!root.recordingActive) { root.recDiscardArmed = false; recDisarm.stop() }
    // the pill's dot breathes while recording
    property real recPulse: 1.0
    SequentialAnimation on recPulse {
        running: root.recordingActive && !root.recDiscardArmed
        loops: Animation.Infinite
        NumberAnimation { to: 0.3; duration: 750; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1.0; duration: 750; easing.type: Easing.InOutQuad }
    }

    // ---------- bit-perfect quality readout ----------
    // Players like SONE (TIDAL) in bit-perfect mode bypass pipewire and open the card
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
        running: !root.gameOn && (root.openPop === "mpris" || root.widgetsScreen !== "" || root.desktopHasMedia) && !Tok.reducedMotion && root.hqInfo !== "" && root.player !== null && root.player.isPlaying
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
    property int mediaTab: 0
    onMediaTabChanged: { root.infoOpen = mediaTab === 1; root.lyricsOpen = mediaTab === 2; if (root.lyricsOpen) root.fetchLyrics() }
    property bool lyricsOpen: false
    property bool infoOpen: false        // track-details sidecar (opens on the opposite side of lyrics)
    property var lyrics: []              // [{t: seconds, l: line}] when synced
    property string plainLyrics: ""
    property string lyricsState: "idle"  // idle | loading | ok | plain | none
    property string lyricsKey: ""
    // Pronunciation and translation ride ALONGSIDE root.lyrics, indexed by the same lyrIdx —
    // sea-lyrics-aux.py only ever returns arrays the same length as what it was given, so an
    // index that is valid for one is valid for all three.
    property var lyrRomaji: []
    property var lyrTrans: []
    property bool cfgLyrRomaji: true
    property bool cfgLyrTrans: false
    property string lyrAuxKey: ""            // trackKey the current aux result belongs to
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/lyrics.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: lyrCfgOut; onStreamFinished: {
            try { var j = JSON.parse(lyrCfgOut.text.trim() || "{}");
                if (j.romaji !== undefined) root.cfgLyrRomaji = !!j.romaji;
                if (j.translate !== undefined) root.cfgLyrTrans = !!j.translate;
            } catch(e) {}
        } } }
    function lyrSaveCfg() {
        var o = JSON.stringify({ romaji: root.cfgLyrRomaji, translate: root.cfgLyrTrans });
        Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && printf '%s' '"+o+"' > ~/.config/sea-shell/lyrics.json"]);
    }
    readonly property string _lyrAuxPath: Qt.resolvedUrl("sea-lyrics-aux.py").toString().replace("file://","")
    Process { id: lyrAux
        stdout: StdioCollector { id: lyrAuxOut; onStreamFinished: {
            // Same staleness rule the lyrics fetch uses: a slow romanisation for the previous
            // track must not land under the one we already switched to.
            if (root.lyrAuxKey !== root.trackKey) return;
            try { var j = JSON.parse(lyrAuxOut.text || "{}");
                root.lyrRomaji = (j.romaji && j.romaji.length === root.lyrics.length) ? j.romaji : [];
                root.lyrTrans  = (j.trans  && j.trans.length  === root.lyrics.length) ? j.trans  : [];
            } catch(e) { root.lyrRomaji = []; root.lyrTrans = [] }
        } } }
    function lyrRunAux() {
        root.lyrRomaji = []; root.lyrTrans = [];
        if (!root.lyrics.length) return;
        if (!root.cfgLyrRomaji && !root.cfgLyrTrans) return;
        var lines = []; for (var i=0;i<root.lyrics.length;i++) lines.push(root.lyrics[i].l);
        root.lyrAuxKey = root.trackKey;
        lyrAux.running = false;
        lyrAux.command = ["sh","-c","printf '%s' \"$SEA_LYR\" | python3 " + root._lyrAuxPath];
        lyrAux.environment = ({ SEA_LYR: JSON.stringify({ lines: lines, translate: root.cfgLyrTrans, to: "en" }) });
        lyrAux.running = true;
    }
    function lyrToggleRomaji()  { root.cfgLyrRomaji = !root.cfgLyrRomaji; root.lyrSaveCfg(); root.lyrRunAux() }
    function lyrToggleTrans()   { root.cfgLyrTrans  = !root.cfgLyrTrans;  root.lyrSaveCfg(); root.lyrRunAux() }
    readonly property string trackKey: root.player ? (root.player.trackArtist||"")+"|"+(root.player.trackTitle||"") : ""
    onTrackKeyChanged: { root.lyricsState = "idle"; root.lyrics = []; root.plainLyrics = "";
        if (root.lyricsOpen && root.openPop==="mpris") root.fetchLyrics();
        root.metaState = "idle"; root.metaReleased = ""; root.metaLabel = "";
        if (root.infoOpen && root.openPop==="mpris") root.fetchMeta() }

    // ---------- track metadata (MusicBrainz) ----------
    // MPRIS carries what the player happens to tag; it has no idea WHEN a thing
    // came out. MusicBrainz does, needs no API key, and is already the same shape
    // of favour lrclib does for lyrics — so this only runs while the details
    // sidecar is open, once per track, exactly like fetchLyrics.
    property string metaKey: ""
    property string metaState: "idle"   // idle | loading | ok | none
    property string metaReleased: ""
    property string metaLabel: ""       // release the recording first appeared on
    function fetchMeta(force) {
        if (!root.player) return;
        if (!force && root.metaKey === root.trackKey && root.metaState !== "idle") return;
        root.metaKey = root.trackKey; root.metaState = "loading";
        root.metaReleased = ""; root.metaLabel = "";
        metaProc.running = false;
        // env-array → artist/title never touch shell quoting, same as fetchLyrics
        metaProc.command = ["env",
            "A=" + (root.player.trackArtist||""), "T=" + (root.player.trackTitle||""),
            "AL=" + (root.player.trackAlbum||""),
            // Escalating, each step only if the last found nothing:
            //   1. title + artist
            //   2. title alone — MPRIS romanises where MusicBrainz indexes the
            //      original script ("Tamari" vs "珠梨"), the same mismatch the
            //      lyrics fetch works around
            //   3. title with a leading "<album> - " stripped: some players put the
            //      album in front of the track name, which matches nothing
            // Reply is prefixed with the track key it was issued for, so a slow
            // answer for a previous track can't overwrite the current one.
            "sh","-c",
            "printf '%s\\x1f' \"$A|$T\"; " +
            "UA='sea-shell/3.2 (+https://seashell.miyukivigil.tech)'; " +
            "q() { curl -sG --max-time 8 --compressed -A \"$UA\" https://musicbrainz.org/ws/2/recording " +
              "--data-urlencode \"query=$1\" --data-urlencode fmt=json --data-urlencode limit=1; }; " +
            "R=$(q \"recording:\\\"$T\\\" AND artist:\\\"$A\\\"\"); " +
            "case $R in *'\"recordings\":[{'*) printf '%s' \"$R\"; exit 0;; esac; " +
            "R=$(q \"recording:\\\"$T\\\"\"); " +
            "case $R in *'\"recordings\":[{'*) printf '%s' \"$R\"; exit 0;; esac; " +
            "T2=${T#\"$AL\"}; T2=${T2# }; T2=${T2#-}; T2=${T2#–}; T2=${T2# }; " +
            "[ -n \"$T2\" ] && [ \"$T2\" != \"$T\" ] && q \"recording:\\\"$T2\\\"\""]
        metaProc.running = true;
    }
    Process { id: metaProc
        stdout: StdioCollector { id: metaOut; onStreamFinished: root.parseMeta(metaOut.text) } }

    function parseMeta(txt) {
        var i = txt.indexOf("\x1f");
        if (i < 0) { root.metaState = "none"; return }
        if (txt.slice(0, i) !== root.metaKey) return;   // reply for a track we've left
        var body = txt.slice(i + 1).trim();
        if (body === "") { root.metaState = "none"; return }
        try {
            var recs = (JSON.parse(body).recordings) || [];
            var r = recs[0];
            if (!r) { root.metaState = "none"; return }
            // Duration is the guard. Steps 2 and 3 search on title alone, which can
            // land on a completely different recording of the same name — and a
            // confidently wrong release date is worse than no date at all.
            var want = Math.round(root.player ? (root.player.length || 0) : 0);
            var got = r.length ? r.length / 1000 : 0;
            if (want > 0 && got > 0 && Math.abs(want - got) > 5) { root.metaState = "none"; return }
            root.metaReleased = r["first-release-date"] || "";
            var rel = (r.releases || [])[0];
            root.metaLabel = rel ? (rel.title || "") : "";
            root.metaState = root.metaReleased !== "" ? "ok" : "none";
        } catch (e) { root.metaState = "none" }
    }
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
    // [mm:ss.xx] is lrclib's spelling; NetEase writes [mm:ss:xx] with a colon before the
    // centiseconds, and the old pattern accepted only the dot — so every NetEase line failed to
    // match and a perfectly good result came back as an empty list.
    function parseLrc(text) {
        var out = [], re = /\[(\d+):(\d+)(?:[.:](\d+))?\](.*)/;
        ("" + text).split("\n").forEach(function (line) {
            var m = re.exec(line); if (!m) return;
            var cs = m[3] ? parseFloat("0." + m[3]) : 0;
            var txt = m[4].trim(); if (txt === "") txt = "♪";
            out.push({ t: parseInt(m[1],10)*60 + parseInt(m[2],10) + cs, l: txt });
        });
        out.sort(function(a,b){ return a.t-b.t });
        return out;
    }
    // Second chance when lrclib has never heard of the track — see find() in sea-lyrics-aux.py.
    property string lyrFindKey: ""
    Process { id: lyrFind
        stdout: StdioCollector { id: lyrFindOut; onStreamFinished: {
            if (root.lyrFindKey !== root.trackKey) return;
            var got = [];
            try { var j = JSON.parse(lyrFindOut.text || "{}"); if (j.lrc) got = root.parseLrc(j.lrc); } catch (e) {}
            if (got.length) { root.lyrics = got; root.lyricsState = "ok"; root.lyrRunAux(); }
            else root.lyricsState = "none";
        } } }
    function lyrFindElsewhere() {
        if (!root.player) { root.lyricsState = "none"; return }
        root.lyrFindKey = root.trackKey;
        lyrFind.running = false;
        lyrFind.command = ["sh","-c","printf '%s' \"$SEA_FIND\" | python3 " + root._lyrAuxPath];
        lyrFind.environment = ({ SEA_FIND: JSON.stringify({ find: true,
            artist: root.player.trackArtist || "", title: root.player.trackTitle || "" }) });
        lyrFind.running = true;
    }

    function parseLyrics(raw) {
        // strip + verify the "artist|title\x1f" header the fetch stamped on its reply; a reply
        // for a track we've since switched away from is stale — drop it so it can't overwrite.
        var us = raw.indexOf("\x1f");
        if (us >= 0) { if (raw.slice(0, us) !== root.trackKey) return; raw = raw.slice(us + 1); }
        var parts = raw.split("\x1e"), rec = null;
        for (var p=0;p<parts.length && !rec;p++) {
            try { var j = JSON.parse(parts[p]); } catch(e) { continue }
            if (Array.isArray(j)) {
                // A search reply is a list of DIFFERENT SONGS, and the third fetch step searches
                // on title alone — so "Embers" comes back with every song anyone ever called
                // Embers, and taking the first one with lyrics is exactly how another band's
                // words end up scrolling under yours.
                //
                // Duration is the cheap discriminator: same title and within a few seconds of the
                // same length is the same recording nearly every time. Artist is checked too but
                // cannot be required — the whole reason step 3 exists is that MPRIS and lrclib
                // disagree about how to spell the artist.
                var want = root.player ? Math.round(root.player.length || 0) : 0;
                var pick = null, loose = null;
                for (var q=0;q<j.length;q++) {
                    var c = j[q]; if (!c || !(c.syncedLyrics || c.plainLyrics)) continue;
                    if (!loose) loose = c;
                    var d = Math.round(c.duration || 0);
                    if (!(want > 0 && d > 0)) continue;   // no length to compare on → cannot verify → refuse
                    var off = Math.abs(d - want);
                    var ar = ("" + (c.artistName || "")).toLowerCase();
                    var me = ("" + (root.player ? (root.player.trackArtist||"") : "")).toLowerCase();
                    var sameArtist = !!(me && ar && (ar.indexOf(me) >= 0 || me.indexOf(ar) >= 0));
                    // TWO tolerances, because the two things this fallback catches look nothing alike.
                    // A romanised-artist miss (MPRIS "Shihoko Hirata" vs lrclib "平田志穂子") is the SAME
                    // recording, so its length matches almost exactly. A different band's song that
                    // merely shares a title is only ever coincidentally close — Jinjer's "Ape" is 196s
                    // against RED in BLUE's 202s, which sailed through a flat ±7s window and put the
                    // wrong band's words on screen. So: loose only when the artist agrees.
                    if (off > (sameArtist ? 7 : 2)) continue;
                    if (sameArtist) { pick = c; break }
                    if (!pick) pick = c;                  // near-exact length; keep looking for an artist too
                }
                // Nothing within range of the right length means the match is wrong, and "no
                // lyrics found" beats confidently scrolling someone else's song.
                j = pick || (want > 0 ? null : loose);
            }
            if (j && (j.syncedLyrics || j.plainLyrics)) rec = j;
        }
        if (!rec) { root.lyrFindElsewhere(); return }
        if (rec.syncedLyrics) {
            var out = root.parseLrc(rec.syncedLyrics);
            if (out.length) { root.lyrics = out; root.lyricsState = "ok"; root.lyrRunAux(); return }
        }
        if (rec.plainLyrics) { root.plainLyrics = rec.plainLyrics; root.lyricsState = "plain"; return }
        root.lyricsState = "none";
    }

    // ---------- cava audio visualizer (only runs while the music dropdown is open) ----------
    property var cavaValues: []
    Process {
        id: cavaProc
        // Also while a media widget is on the desktop and something is actually playing —
        // that widget draws these same bars, and until 6.4 cava only ever ran for the
        // dropdown, so the desktop visualiser was reading silence and drawing a flat line.
        running: !root.gameOn && (root.openPop === "mpris" || root.widgetsScreen !== "" || root.desktopHasMedia)
                 && root.player !== null && root.player.isPlaying && !Tok.reducedMotion
                 && root.hqInfo === ""   // no point capturing silence in bit-perfect mode
        // bash process substitution + exec → quickshell owns cava directly and can
        // actually kill it (piping into `cava -p /dev/stdin` leaked a cava per open)
        command: ["bash","-c","exec cava -p <(printf '[general]\\nframerate=60\\nbars=22\\nsleep_timer=1\\n[input]\\nmethod=pipewire\\nsource=auto\\n[output]\\nchannels=mono\\nmethod=raw\\nraw_target=/dev/stdout\\ndata_format=ascii\\nascii_max_range=100\\n[smoothing]\\nnoise_reduction=0.45')"]
        stdout: SplitParser { onRead: data => { root.cavaValues = data.split(";").filter(s => s !== "").map(v => parseInt(v,10)||0) } }
    }

    SystemClock { id: clock; precision: SystemClock.Seconds }

    property bool trayCollapsed: false
 
    // ---------- caffeine mode (idle & lock status) ----------
    property bool idleOn: false
    // caffeine is now sticky: the DESIRED state persists to ~/.config/sea-shell/caffeine and is
    // re-applied at startup AND enforced on every poll — so a login or a `hyprctl reload` (which
    // re-runs the hypridle exec-once) can't quietly bring idle-sleep back while caffeine is on.
    property bool cafWanted: false
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/caffeine 2>/dev/null || echo 0"]
        stdout: StdioCollector { id: cafOut; onStreamFinished: {
            root.cafWanted = (cafOut.text.trim() === "1");
            if (root.cafWanted) { Quickshell.execDetached(["sh","-c","pkill -x hypridle"]); root.idleOn = false; }
        } } }
    Process { id: idleChk; running: false; command: ["sh","-c","pgrep -x hypridle >/dev/null && echo on || echo off"]
        stdout: StdioCollector { id: idleOut; onStreamFinished: {
            var running = idleOut.text.trim() === "on";
            if (root.cafWanted && running) {           // caffeine wants awake but hypridle crept back → kill it
                Quickshell.execDetached(["sh","-c","pkill -x hypridle"]); root.idleOn = false;
            } else root.idleOn = running;
        } } }
    Timer { id: idleTimer; interval: 5000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: idleChk.running = true }
    function saveCaffeine() { Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && echo " + (root.cafWanted?"1":"0") + " > ~/.config/sea-shell/caffeine"]); }
    function toggleIdle() {
        if (!root.cafWanted) {
            root.cafWanted = true; root.saveCaffeine();
            Quickshell.execDetached(["sh", "-c", "pkill -x hypridle; notify-send -i coffee 'sea-shell' 'Caffeine mode active — screen will stay on (remembered)'"]);
            root.idleOn = false;
        } else {
            root.cafWanted = false; root.saveCaffeine();
            Quickshell.execDetached(["sh", "-c", "hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"; notify-send 'sea-shell' 'Caffeine mode inactive — normal sleep active'"]);
            root.idleOn = true;
        }
    }

    // keep clipboard history populated so CTRL+V / the bar icon work.
    // clip-watch.sh kills any stale watchers then starts exactly one pair (idempotent on restart).
    Process { running: true; command: ["sh", Qt.resolvedUrl("clip-watch.sh").toString().replace("file://","")] }

    // ---------- notifications (our own daemon: popups + bar center) ----------
    property var notes: []           // history for the center (persisted across restarts)
    // the newest few, trimmed to what the notifications widget draws
    readonly property var widgetNotes: root.notes.slice(0, 6).map(n => ({ summary: n.summary, body: n.body,
        appName: n.appName, appIcon: n.appIcon, time: n.time, ts: n.ts }))
    property int noteSeq: 0
    property var mutedApps: []        // per-app DND: app names whose popups are suppressed (history still records)
    property var priorityApps: []     // per-app bypass: app names allowed through DND / Quiet Hours
    // generic safe config writer — content is passed as argv (no shell quoting), so any
    // apostrophes / newlines / unicode in a notification body round-trip intact.
    function writeCfg(name, content) {
        Quickshell.execDetached(["python3","-c",
            "import sys,os,pathlib; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell'))/sys.argv[1]; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[2])",
            name, content]);
    }
    // History starts empty and is read from disk a moment later. Anything that saves in that
    // window (a popup expiring during a reload) would write the empty list over the file, so
    // saving waits until the read has finished.
    property bool notesLoaded: false
    function saveNotes() { if (root.notesLoaded) root.writeCfg("notif-history.json", JSON.stringify(root.notes)); }
    function saveMutes() { root.writeCfg("notif-mutes.json", JSON.stringify(root.mutedApps)); }
    function savePriorities() { root.writeCfg("notif-priority.json", JSON.stringify(root.priorityApps)); }
    function isMuted(app) { return root.mutedApps.indexOf(app) >= 0; }
    function isPriority(app) { return root.priorityApps.indexOf(app) >= 0; }
    function toggleMute(app) {
        if (!app) return;
        var a = root.mutedApps.slice(); var i = a.indexOf(app);
        if (i >= 0) a.splice(i, 1); else a.push(app);
        root.mutedApps = a; root.saveMutes();
    }
    function togglePriority(app) {
        if (!app) return;
        var a = root.priorityApps.slice(); var i = a.indexOf(app);
        if (i >= 0) a.splice(i, 1); else {
            a.push(app);
            // Promoting an app to priority automatically unmutes it
            if (root.isMuted(app)) root.toggleMute(app);
        }
        root.priorityApps = a; root.savePriorities();
    }
    // restore persisted history + mutes at startup
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/notif-history.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: histOut; onStreamFinished: {
            try { var a = JSON.parse(histOut.text.trim()||"[]");
                if (Array.isArray(a)) {
                    // keep anything that arrived before the read finished, newest first
                    root.notes = root.notes.concat(a).slice(0,40);
                    var mx = 0; for (var i=0;i<root.notes.length;i++) if ((root.notes[i].key||0) > mx) mx = root.notes[i].key; root.noteSeq = Math.max(root.noteSeq, mx); } } catch(e) {}
            root.notesLoaded = true; root.saveNotes() } } }
    FileView {
        id: muteFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/notif-mutes.json"
        watchChanges: true; printErrors: false
        onLoaded: {
            try {
                var a = JSON.parse(text().trim() || "[]");
                if (Array.isArray(a)) root.mutedApps = a;
            } catch (e) {}
        }
        onFileChanged: reload()
    }
    FileView {
        id: priorityFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/notif-priority.json"
        watchChanges: true; printErrors: false
        onLoaded: {
            try {
                var a = JSON.parse(text().trim() || "[]");
                if (Array.isArray(a)) root.priorityApps = a;
            } catch (e) {}
        }
        onFileChanged: reload()
    }
    // Do Not Disturb: suppress on-screen popups (history still records everything). Persists
    // across restarts; critical-urgency notifications still pop through so alerts aren't lost.
    property bool dnd: false
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/dnd 2>/dev/null || echo 0"]
        stdout: StdioCollector { id: dndOut; onStreamFinished: root.dnd = (dndOut.text.trim() === "1") } }
    function setDnd(v) { root.dnd = v; Quickshell.execDetached(["sh","-c","echo " + (v?"1":"0") + " > \"$HOME/.config/sea-shell/dnd\""]); }

    // ---------- quiet hours ----------
    // Do Not Disturb on a schedule, and while the screen is being shared. Kept apart from root.dnd
    // rather than flipping it: that one is your own choice and game mode and the pomodoro already
    // save and restore it, so a schedule writing to it would fight them all.
    property var quietCfg: ({ enabled: false, from: "22:00", to: "07:00", share: true })
    Process { running: true
        command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; [ -f \"$d/notif-mutes.json\" ] || printf '[]' > \"$d/notif-mutes.json\"; [ -f \"$d/dnd\" ] || echo 0 > \"$d/dnd\"; f=\"$d/quiet.json\"; [ -f \"$f\" ] || printf '{}' > \"$f\"; echo \"$f\""]
        stdout: StdioCollector { id: quietPathOut; onStreamFinished: quietFile.path = quietPathOut.text.trim() } }
    FileView { id: quietFile; path: ""; watchChanges: true; printErrors: false
        onLoaded: {
            try {
                var j = JSON.parse(text());
                root.quietCfg = { enabled: !!j.enabled, from: j.from || "22:00", to: j.to || "07:00", share: j.share !== false };
            } catch (e) {}
            root.quietTick();
        }
        onFileChanged: reload() }
    property bool quietScheduled: false
    function quietTick() {
        var c = root.quietCfg;
        function mins(t) { var p = ("" + t).split(":"); return (+p[0]) * 60 + (+p[1]); }
        var d = new Date(), n = d.getHours() * 60 + d.getMinutes(), a = mins(c.from), b = mins(c.to);
        // the usual window runs past midnight, so from > to means "after from OR before to"
        root.quietScheduled = !!c.enabled && a !== b && (a < b ? (n >= a && n < b) : (n >= a || n < b));
    }
    Timer { interval: 20000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: root.quietTick() }
    readonly property bool quietWanted: root.quietScheduled || (root.quietCfg.share && root.screenShared)
    // Turning it off from the bar lasts until this stretch of quiet ends, not for good.
    property bool quietPaused: false
    onQuietWantedChanged: if (!quietWanted) root.quietPaused = false
    readonly property bool quietNow: root.quietWanted && !root.quietPaused
    readonly property bool silenced: root.dnd || root.quietNow
    function toggleSilence() {
        if (root.quietNow) { root.quietPaused = true; if (root.dnd) root.setDnd(false); }
        else root.setDnd(!root.dnd);
    }

    // ---------- what is using the mic, the camera and the screen ----------
    // Input streams only, minus anything capturing a speaker rather than the mic: the bar's own
    // visualiser (cava) is one of those, and would otherwise light this up all day.
    readonly property var inStreams: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.type === PwNodeType.AudioInStream })
    PwObjectTracker { objects: root.inStreams }
    readonly property var micApps: {
        var out = [];
        for (var i = 0; i < root.inStreams.length; i++) {
            var n = root.inStreams[i], p = n.properties || {};
            if (("" + p["stream.capture.sink"]) === "true") continue;
            var name = "" + (p["application.name"] || p["application.process.binary"] || n.description || n.name || "An app");
            if (out.indexOf(name) < 0) out.push(name);
        }
        return out;
    }
    // A webcam opened directly never appears in PipeWire, so ask who has the device open.
    property var cameraApps: []
    Process { id: camProc
        command: ["sh","-c","set -- /dev/video*; [ -e \"$1\" ] || exit 0; for p in $(fuser \"$@\" 2>/dev/null); do read -r c < \"/proc/$p/comm\" && echo \"$c\"; done"]
        stdout: StdioCollector { id: camOut; onStreamFinished: {
            var l = camOut.text.trim();
            var next = [];
            if (l) l.split("\n").forEach(function(c) {
                var name = /^(pipewire|wireplumber)/.test(c) ? "An app" : c;
                if (next.indexOf(name) < 0) next.push(name);
            });
            next.sort();
            if (JSON.stringify(next) !== JSON.stringify(root.cameraApps)) root.cameraApps = next;
        } } }
    Timer { interval: 3000; running: !root.gameHibernate; repeat: true; triggeredOnStart: true; onTriggered: camProc.running = true }
    // Hyprland reports every capture, including one-frame screenshots and this shell's own live
    // previews, so a window share only counts when no preview is open, and anything shorter
    // than a few seconds does not count at all.
    property int capMonitors: 0
    property int capWindows: 0
    readonly property bool ownPreviews: root.exposeActive || windowSwitcher.open || launcher.shown
    readonly property bool captureSeen: root.capMonitors > 0 || (root.capWindows > 0 && !root.ownPreviews)
    property bool screenShared: false
    onCaptureSeenChanged: { if (captureSeen) capSettle.restart(); else { capSettle.stop(); root.screenShared = false; } }
    Timer { id: capSettle; interval: 4000; onTriggered: root.screenShared = true }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "screencast") return;
            var d = ("" + event.data).split(","), step = d[0] === "1" ? 1 : -1;
            if (d[1] === "window") root.capWindows = Math.max(0, root.capWindows + step);
            else root.capMonitors = Math.max(0, root.capMonitors + step);
        }
    }
    readonly property string privacyLabel: {
        var parts = root.micApps.concat(root.cameraApps.filter(function(c) { return root.micApps.indexOf(c) < 0 }));
        if (parts.length) return parts.length > 2 ? parts.slice(0, 2).join(", ") + " +" + (parts.length - 2) : parts.join(", ");
        return (root.screenShared && !root.recordingActive) ? "Sharing screen" : "";
    }

    // ---------- network throughput ----------
    // /proc/net/dev holds cumulative counters, so a RATE needs two samples and the real elapsed
    // time between them — not the timer interval, which drifts whenever the shell is busy and
    // would quietly inflate every reading.
    property real netRx: 0                       // bytes/sec, all real interfaces
    property real netTx: 0
    property var  netIf: []                      // [{name, rx, tx}] per interface, bytes/sec
    property var  _netPrev: ({})
    property real _netPrevT: 0
    Process {
        id: netProc
        command: ["sh","-c","cat /proc/net/dev"]
        stdout: StdioCollector { id: netOut; onStreamFinished: {
            var now = Date.now(), dt = (now - root._netPrevT) / 1000;
            var lines = netOut.text.split("\n"), cur = {}, rows = [], trx = 0, ttx = 0;
            for (var i = 2; i < lines.length; i++) {
                var ln = lines[i].trim(); if (ln === "") continue;
                var ci = ln.indexOf(":"); if (ci < 0) continue;
                var name = ln.substring(0, ci).trim();
                // loopback is not network traffic, and a down interface is noise
                if (name === "lo" || name.indexOf("virbr") === 0) continue;
                var f = ln.substring(ci + 1).trim().split(/\s+/);
                if (f.length < 10) continue;
                var rx = parseFloat(f[0]), tx = parseFloat(f[8]);
                cur[name] = { rx: rx, tx: tx };
                var p = root._netPrev[name];
                if (p && dt > 0.2 && dt < 30) {
                    // counters reset on interface restart; a negative delta is not -5 GB/s
                    var drx = Math.max(0, rx - p.rx) / dt, dtx = Math.max(0, tx - p.tx) / dt;
                    if (rx > 0 || tx > 0) rows.push({ name: name, rx: drx, tx: dtx });
                    trx += drx; ttx += dtx;
                }
            }
            root._netPrev = cur; root._netPrevT = now;
            if (rows.length > 0 || dt > 0.2) { root.netRx = trx; root.netTx = ttx; root.netIf = rows; }
        } } }
    Timer { interval: 2000; repeat: true; running: root.cfgNet && !root.gameHibernate; triggeredOnStart: true
        onTriggered: netProc.running = true }
    function netFmt(b) {
        if (b < 1024) return Math.round(b) + " B";
        if (b < 1024 * 1024) return (b / 1024).toFixed(b < 10240 ? 1 : 0) + " K";
        return (b / 1048576).toFixed(1) + " M";
    }

    // ---------- app usage ----------
    // Measures how long each app actually HELD FOCUS, not how long it was open, and stops
    // counting once the session goes idle — otherwise walking away with Firefox focused would
    // quietly bill it for lunch. IdleMonitor is a real wayland idle-notify subscription, so this
    // costs nothing while you work.
    property var    usageAll: ({})            // {"YYYY-MM-DD": {class: seconds}}
    property string usageDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    property string usageCur: ""
    property real   usageSince: 0
    IdleMonitor { id: usageIdle; timeout: 120 }

    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage.json\" 2>/dev/null"]
        stdout: StdioCollector { id: usageOut; onStreamFinished: {
            try { var t = usageOut.text.trim(); if (t) root.usageAll = JSON.parse(t) || ({}); } catch (e) {}
        } } }
    function usageSave() {
        // Keep a fortnight. Unbounded history would grow forever for a panel that only ever
        // shows today and the last 7 days.
        var keys = Object.keys(root.usageAll).sort(), out = {};
        var keep = keys.slice(Math.max(0, keys.length - 14));
        for (var i = 0; i < keep.length; i++) out[keep[i]] = root.usageAll[keep[i]];
        root.usageAll = out;
        root.writeCfg("usage.json", JSON.stringify(out));
    }
    // Bank whatever the current app has earned since the last checkpoint.
    function usageFlush() {
        if (root.usageCur === "" || root.usageSince <= 0) return;
        var now = Date.now();
        var dt = (now - root.usageSince) / 1000;
        root.usageSince = now;
        // A suspend/resume or a clock change can hand us an absurd delta; drop it rather than
        // recording an eight-hour "session" that never happened.
        if (dt <= 0 || dt > 3600) return;
        var today = Qt.formatDate(new Date(), "yyyy-MM-dd");
        if (today !== root.usageDate) { root.usageDate = today; }
        var all = {}; for (var d in root.usageAll) all[d] = root.usageAll[d];
        var day = {}; if (all[today]) for (var k in all[today]) day[k] = all[today][k];
        day[root.usageCur] = (day[root.usageCur] || 0) + dt;
        all[today] = day;
        root.usageAll = all;
    }
    function usageSwitch(cls) { root.usageFlush(); root.usageCur = cls; root.usageSince = Date.now(); }
    // ---------- an application asking for your attention ----------
    // Clicking a link in one app and having the browser come up BEHIND it is the case this
    // exists for. Wayland's xdg-activation is how the launching app hands over the right to
    // take focus; Hyprland turns that into an `urgent` event and, with misc:focus_on_activate
    // off (its default, and what this machine had), does nothing else with it. So the window
    // is raised on some other workspace and you go looking for it.
    //
    // Hyprland emits urgent TWICE for a single link open, so the nonce is what the dock
    // animates on and the key is deliberately allowed to be re-set to the same value.
    property bool cfgAttnFlash: true      // pulse the app's dock icon
    property bool cfgAttnFocus: true      // and go to it
    property string attnKey: ""           // lowercase window class currently asking
    property int attnNonce: 0
    property real _attnLast: 0
    Timer { id: attnClear; interval: 2600; onTriggered: root.attnKey = "" }

    function attnRaise(addr) {
        if (!addr) return;
        var want = ("" + addr).replace(/^0x/, "").toLowerCase();
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < list.length; i++) {
            var t = list[i], o = t ? t.lastIpcObject : null;
            if (!o || !o.address) continue;
            if (("" + o.address).replace(/^0x/, "").toLowerCase() !== want) continue;

            var cls = ("" + (o.class || (t.wayland ? t.wayland.appId : "") || "")).trim().toLowerCase();
            if (root.cfgAttnFlash && cls !== "") { root.attnKey = cls; root.attnNonce++; attnClear.restart(); }
            // Same path the dock uses to focus a window, for the same reason: the address is
            // exact, and activate() is the fallback for a window hyprctl has not listed yet.
            if (root.cfgAttnFocus) {
                if (o.address) Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + o.address + "' })");
                else if (t.wayland) t.wayland.activate();
            }
            return;
        }
        // Not in the model yet — a window that opened this instant. Ask once, then give up
        // rather than spinning: a miss here costs a flash, not correctness.
        Hyprland.refreshToplevels();
    }

    Connections { target: Hyprland; ignoreUnknownSignals: true
        function onRawEvent(event) {
            if (!event) return;
            if (event.name === "activespecial") {
                // "name,monitor" — an empty name is the stash being put away. Taken from the
                // event rather than read back off the monitor, because this has to be right the
                // instant the key is pressed and lastIpcObject is not.
                root.scratchOpen = ("" + (event.data || "")).split(",")[0].length > 0;
                return;
            }
            if (event.name !== "urgent") return;
            if (!root.cfgAttnFlash && !root.cfgAttnFocus) return;
            var now = Date.now();
            if (now - root._attnLast < 400) return;      // the duplicate event for one open
            root._attnLast = now;
            root.attnRaise(event.data);
        }
    }

    Connections { target: Hyprland; ignoreUnknownSignals: true
        function onActiveToplevelChanged() {
            var t = Hyprland.activeToplevel;
            root.usageSwitch((t && t.wayland && t.wayland.appId) ? ("" + t.wayland.appId) : "");
        } }
    Connections { target: usageIdle; ignoreUnknownSignals: true
        function onIsIdleChanged() {
            // Bank what is owed, then park the clock (0 makes usageFlush a no-op) until input
            // comes back.
            if (usageIdle.isIdle) { root.usageFlush(); root.usageSince = 0; }
            else root.usageSince = Date.now();
        } }
    // ---- daily limits + summary ----
    property var    usageLimits: ({})          // appClass -> minutes/day
    property bool   usageSummary: false
    property string usageSummaryTime: "21:00"
    // Not persisted: "already warned about X today" is worthless after a restart, and re-warning
    // once after a reboot is far better than staying silent because a stale flag said we had.
    property var    _usageNotified: ({})
    property string _usageSummaryDone: ""
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage-limits.json\" 2>/dev/null"]
        stdout: StdioCollector { id: ulimOut; onStreamFinished: {
            try {
                var t = ulimOut.text.trim(); if (!t) return;
                var j = JSON.parse(t);
                if (j.limits && typeof j.limits === "object") root.usageLimits = j.limits;
                if (j.summary !== undefined) root.usageSummary = !!j.summary;
                if (j.summaryTime) root.usageSummaryTime = j.summaryTime;
            } catch (e) {}
        } } }
    function usageCheck() {
        var day = root.usageAll[root.usageDate] || ({});
        for (var app in root.usageLimits) {
            var lim = root.usageLimits[app];
            if (!(lim > 0)) continue;
            var used = (day[app] || 0) / 60;
            var key = root.usageDate + "/" + app;
            if (used >= lim && !root._usageNotified[key]) {
                root._usageNotified[key] = true;
                Quickshell.execDetached(["notify-send","-u","normal","-a","sea-shell","sea-shell",
                    app + " is over its " + lim + " min limit — " + Math.round(used) + " min today"]);
            }
        }
        if (!root.usageSummary) return;
        // Fires on the first minute-tick at or after the chosen time, once per day. String
        // compare is safe because both sides are zero-padded HH:mm.
        var nowS = Qt.formatDateTime(new Date(), "HH:mm");
        if (nowS >= root.usageSummaryTime && root._usageSummaryDone !== root.usageDate) {
            root._usageSummaryDone = root.usageDate;
            var rows = root.usageRows;
            if (rows.length === 0) return;
            var body = "";
            for (var i = 0; i < Math.min(3, rows.length); i++)
                body += (i ? "\n" : "") + rows[i].app + " — " + root.usageFmt(rows[i].secs);
            Quickshell.execDetached(["notify-send","-a","sea-shell","sea-shell",
                "Today: " + root.usageFmt(root.usageTotal) + " active\n" + body]);
        }
    }
    Timer { interval: 60000; repeat: true; running: !root.gameHibernate
        onTriggered: { root.usageFlush(); root.usageSave(); root.usageCheck(); } }

    function usageFmt(s) {
        s = Math.round(s);
        if (s < 60) return s + "s";
        var m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        return Math.floor(m / 60) + "h " + (m % 60) + "m";
    }
    readonly property var usageRows: {
        var day = root.usageAll[root.usageDate] || ({}), arr = [];
        for (var k in day) arr.push({ app: k, secs: day[k] });
        arr.sort(function (a, b) { return b.secs - a.secs });
        return arr;
    }
    readonly property real usageTotal: {
        var t = 0; for (var i = 0; i < root.usageRows.length; i++) t += root.usageRows[i].secs;
        return t;
    }

    // ---------- pending package updates ----------
    // The count comes from sea-updates.sh (checkupdates + paru -Qua). See that script for why
    // `pacman -Qu` is not used: it reports against a possibly week-old sync db.
    property int  updRepo: 0
    property int  updAur: 0
    readonly property int updTotal: root.updRepo + root.updAur
    property var  updList: []                    // [{src:"R"|"A", name, old, nw}]
    property bool updChecking: false
    Process {
        id: updProc
        command: ["sh","-c","~/.config/quickshell/sea-shell/sea-updates.sh"]
        onRunningChanged: root.updChecking = updProc.running
        stdout: StdioCollector { id: updOut; onStreamFinished: {
            var lines = updOut.text.split("\n"), out = [];
            if (lines.length > 0) {
                var h = lines[0].split("|");
                root.updRepo = parseInt(h[0]) || 0;
                root.updAur  = parseInt(h[1]) || 0;
            }
            for (var i = 1; i < lines.length; i++) {
                var p = lines[i].split("|");
                // `new` is reserved in JS, hence nw
                if (p.length >= 4) out.push({ src: p[0], name: p[1], old: p[2], nw: p[3] });
            }
            root.updList = out;
        } } }
    // 30 minutes. checkupdates syncs a private db over the NETWORK — this is a real request to a
    // mirror, not a local read — so a tight interval is rude for no gain. triggeredOnStart gives
    // a count at login rather than a blank pill for the first half hour.
    Timer { interval: 30 * 60 * 1000; repeat: true; running: root.cfgUpdates && !root.gameHibernate; triggeredOnStart: true
        onTriggered: updProc.running = true }
    function updRefresh() { updProc.running = true }
    // Upgrades run in a terminal on purpose: pacman asks questions (replace this? keep that?) and
    // a silent background upgrade that hits a prompt would hang forever with nothing to answer it.
    function updRun() {
        root.openPop = "";
        Quickshell.execDetached(["sh","-c","kitty --hold sh -c 'paru -Syu; echo; echo done'"]);
    }

    // ---------- game mode ----------
    // sea-gamemode.sh owns the SYSTEM side (effects, power profile, idle) and writes its
    // state file; the bar owns DND and the indicator. One owner per setting — the script never
    // touches root.dnd and the bar never touches blur, so neither can fight the other.
    // Watching the file rather than only reacting to our own IPC means running the script from
    // a terminal, a keybind or the panel all behave identically.
    property bool gameOn: false
    property bool gameOnAuto: false   // started by Play / Feral; restore desktop when the game closes
    property bool gameWasDnd: false
    readonly property bool dashShown: !!(dashLoader.item && dashLoader.item.shown)
    readonly property bool settingsShown: !!(settingsLoader.item && settingsLoader.item.shown)
    // Level 1 Smart Hibernate: freeze all non-essential polling, animations, and background
    // subprocesses while Game Mode is active and no interactive shell overlay is open.
    readonly property bool gameHibernate: root.gameOn && root.openPop === "" && !root.dashShown && !root.settingsShown && root.widgetsScreen === ""
    Process { running: true
        // create it if absent: a FileView cannot watch a path that has never existed
        command: ["sh","-c","f=\"${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode.json\"; [ -f \"$f\" ] || printf '{\"on\":false}' > \"$f\"; echo \"$f\""]
        stdout: StdioCollector { id: gmPathOut; onStreamFinished: gmFile.path = gmPathOut.text.trim() } }
    FileView {
        id: gmFile; path: ""; watchChanges: true
        function apply() { try {
            var t = text(); if (!t || !t.trim()) return;
            var j = JSON.parse(t);
            root.gameOnAuto = !!j.auto;
            root.applyGame(!!j.on);
        } catch (e) {} }
        // Same trap as Tok.qml: with blockLoading the bytes are present when construction
        // finishes and NO load signal is emitted, so onLoaded alone never fires and the
        // bar draws its first frame against the defaults regardless.
        Component.onCompleted: apply()
        onLoaded: apply()
        // Reload only on disk changes; onLoaded parses without starting another load.
        onFileChanged: reload()
    }
    // Mirrors how the pomodoro handles DND: remember whether DND was ALREADY on, so leaving game
    // mode does not un-silence notifications the user had deliberately silenced.
    readonly property string gamingScript: Qt.resolvedUrl("sea-gaming.py").toString().replace("file://", "")
    property var  gameLive: null
    property string gameTrackApp: ""
    property string gameTrackTitle: ""
    property real gameTrackStart: 0
    property var  gameTrackSamples: []
    property int  gameBarTick: 0
    property string gamePlayApp: ""
    property real gamePlaySince: 0
    Timer { id: gameBarClock; interval: 1000; running: root.gameLive !== null && !root.gameHibernate; repeat: true
        onTriggered: root.gameBarTick++ }
    readonly property string gameBarValue: {
        root.gameBarTick;
        if (root.gameLive && root.gameTrackStart > 0) {
            var sec = Math.max(0, Math.floor((Date.now() - root.gameTrackStart) / 1000));
            var m = Math.floor(sec / 60), ss = sec % 60;
            var t = (m < 10 ? "0" : "") + m + ":" + (ss < 10 ? "0" : "") + ss;
            if (root.hasGpu && root.gpuUsage > 0) return t + " · " + Math.round(root.gpuUsage) + "%";
            return t;
        }
        if (root.gameOn)
            return root.hasGpu && root.gpuUsage > 0 ? Math.round(root.gpuUsage) + "% GPU" : "ON";
        if (root.gameLive && root.gameLive.title) {
            var n = "" + root.gameLive.title;
            return n.length > 18 ? n.slice(0, 16) + "…" : n;
        }
        return "";
    }
    function gameFromTop(t) {
        if (!t) return null;
        var ipc = t.lastIpcObject || {};
        var id = "" + ((t.wayland && t.wayland.appId) || ipc.class || "");
        var title = "" + ((t.wayland && t.wayland.title) || ipc.title || "");
        var m = id.match(/steam_app_(\d+)/);
        if (m) return { appid: m[1], title: title.length ? title : ("Steam " + m[1]) };
        if (/gamescope/i.test(id)) return { appid: "", title: title.length ? title : "Game" };
        // Lutris and Twintail games run under Wine/Proton: the class is the .exe (or Proton's
        // steam_app_default), and Minecraft's is its version; none says which game, so the
        // process is asked once.
        if (/\.exe$|^steam_app_default$|^steam_proton$|^minecraft/i.test(id)) {
            var pid = (t.wayland && t.wayland.pid) || ipc.pid || 0;
            if (!pid) return null;
            var known = root.wineGames[pid];
            if (known === undefined) { root.lookupWineGame(pid); return null; }
            return known ? { appid: known.appid, title: known.title } : null;
        }
        return null;
    }
    // pid → {appid, title}, or false for a Wine window that is no library game (a launcher, an installer).
    property var wineGames: ({})
    property var wineQueue: []
    function lookupWineGame(pid) {
        if (root.wineQueue.indexOf(pid) >= 0) return;
        root.wineQueue = root.wineQueue.concat([pid]);
        if (!wineProc.running) root.nextWineLookup();
    }
    function nextWineLookup() {
        if (!root.wineQueue.length) return;
        wineProc.pid = root.wineQueue[0];
        wineProc.command = ["python3", root.gamingScript, "which-game", String(wineProc.pid)];
        wineProc.running = true;
    }
    Process {
        id: wineProc
        property int pid: 0
        stdout: StdioCollector { id: wineOut; onStreamFinished: {
            var hit = false;
            try { var o = JSON.parse(wineOut.text.trim()); if (o && o.appid) hit = o; } catch (e) {}
            var next = Object.assign({}, root.wineGames);
            next[wineProc.pid] = hit;
            root.wineGames = next;
            root.wineQueue = root.wineQueue.filter(function (p) { return p !== wineProc.pid; });
        } }
        onExited: Qt.callLater(root.nextWineLookup)
    }
    function gamePlayFlush() {
        if (!root.gamePlayApp || root.gamePlaySince <= 0) return;
        var sec = Math.round((Date.now() - root.gamePlaySince) / 1000);
        root.gamePlaySince = 0;
        if (sec < 20) return;
        Quickshell.execDetached(["python3", root.gamingScript, "playtime", root.gamePlayApp, String(sec)]);
        root.gamePlayApp = "";
    }
    function refreshGameLive() {
        try { Hyprland.refreshToplevels(); } catch (e) {}
        var list = (Hyprland && Hyprland.toplevels) ? Hyprland.toplevels.values : [];
        var pick = null;
        for (var i = 0; i < list.length; i++) {
            var g = root.gameFromTop(list[i]);
            if (g) pick = g;
        }
        var had = root.gameLive;
        if (had && !pick) root.gameTrackFinish(true);
        if (pick && pick.appid) {
            if (root.gameTrackApp && root.gameTrackApp !== pick.appid) root.gameTrackFinish(true);
            if (root.gameTrackApp !== pick.appid) root.gameTrackBegin(pick);
            if (pick.appid !== root.gamePlayApp) { root.gamePlayFlush(); root.gamePlayApp = pick.appid; root.gamePlaySince = Date.now(); }
        } else root.gamePlayFlush();
        root.gameLive = pick;
        if (pick) {
            root.gameSawWindow = true;
            gameRestore.stop();
        } else if (had && !pick && root.gameOn && (root.gameOnAuto || root.gamePlayOwned)) {
            // Falling edge only — restarting this on every 2s poll while idle
            // reset the countdown forever, so game mode never dropped.
            gameRestore.restart();
        }
    }
    property bool gamePlayOwned: false
    property bool gameSawWindow: false
    FileView {
        id: playSessFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sea-gaming-play"
        watchChanges: true
        printErrors: false
        function apply() {
            var id = (text() || "").trim();
            root.gamePlayOwned = id.length > 0;
            if (root.gamePlayOwned) { root.gameSawWindow = false; gameFailsafe.restart(); }
        }
        onLoaded: apply(); onFileChanged: reload()
    }
    // Play uses auto-on. Wait after the game WINDOW is gone, not after every empty poll.
    Timer { id: gameRestore; interval: 8000; repeat: false
        onTriggered: root.dropPlayGameMode() }
    Timer { id: gameFailsafe; interval: 90000; repeat: false
        onTriggered: { if (!root.gameSawWindow) root.dropPlayGameMode() } }
    function dropPlayGameMode() {
        if (root.gameLive) return;
        if (!(root.gameOnAuto || root.gamePlayOwned)) return;
        Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-gamemode.sh off; rm -f \"${XDG_RUNTIME_DIR:-/tmp}/sea-gaming-play\""]);
        root.gamePlayOwned = false;
        root.gameSawWindow = false;
    }
    function gameTrackBegin(g) {
        root.gameTrackApp = g.appid || "";
        root.gameTrackTitle = g.title || "Game";
        root.gameTrackStart = Date.now();
        root.gameTrackSamples = [];
    }
    function gameSessionStats() {
        if (!root.gameTrackSamples.length) return {};
        var gpu = 0, mx = 0, tmx = 0, vram = 0, cpu = 0;
        for (var i = 0; i < root.gameTrackSamples.length; i++) {
            var s = root.gameTrackSamples[i];
            gpu += s.gpu || 0;
            cpu += s.cpu || 0;
            mx = Math.max(mx, s.gpu || 0);
            tmx = Math.max(tmx, s.temp || 0);
            vram = Math.max(vram, s.vram || 0);
        }
        return {
            gpu_avg: Math.round(gpu / root.gameTrackSamples.length),
            gpu_max: Math.round(mx),
            gpu_temp_max: Math.round(tmx),
            vram_peak: Math.round(vram * 10) / 10,
            cpu_avg: Math.round(cpu / root.gameTrackSamples.length),
        };
    }
    function gameTrackFinish(notify) {
        var sec = root.gameTrackStart > 0 ? Math.round((Date.now() - root.gameTrackStart) / 1000) : 0;
        if (sec < 30) {
            root.gameTrackStart = 0; root.gameTrackApp = ""; root.gameTrackTitle = ""; root.gameTrackSamples = [];
            return;
        }
        var payload = {
            started: new Date(root.gameTrackStart).toISOString(),
            ended: new Date().toISOString(),
            appid: root.gameTrackApp,
            title: root.gameTrackTitle,
            seconds: sec,
            game_mode: root.gameOn,
            stats: root.gameSessionStats()
        };
        var b64 = Qt.btoa(JSON.stringify(payload));
        var flag = notify ? " --notify" : "";
        Quickshell.execDetached(["sh", "-c",
            "echo '" + b64 + "' | base64 -d | python3 '" + root.gamingScript + "' append-session" + flag]);
        root.gameTrackStart = 0; root.gameTrackApp = ""; root.gameTrackTitle = ""; root.gameTrackSamples = [];
    }
    Timer { id: gameLivePoll; interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refreshGameLive() }
    Timer { id: gameSamplePoll; interval: 5000; running: root.gameLive !== null && !root.gameHibernate; repeat: true; triggeredOnStart: true
        onTriggered: {
            root.gameTrackSamples = root.gameTrackSamples.concat([{
                gpu: root.gpuUsage, temp: root.gpuTemp, vram: root.gpuMemUsed, cpu: root.cpuUsage
            }]).slice(-360);
        } }
    function applyGame(v) {
        if (v === root.gameOn) return;
        if (v) {
            root.gameWasDnd = root.dnd;
            root.setDnd(true);
            if (root.openPop !== "") root.openPop = "";
            kdeWatch.running = false;
        } else {
            if (!root.gameWasDnd) root.setDnd(false);
            if (!root.gameLive) root.gameTrackFinish(true);
            kdeWatch.running = root.cfgKdeconnect;
        }
        root.gameOn = v;
        if (v) {
            // Reclaim idle panel memory (Dashboard, Settings, Launcher, etc.) right away.
            root.coolPanels();
            gcTimer.restart();
        }
        fanRefresh.start();
    }
    function toggleGame() { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-gamemode.sh toggle"]) }
    IpcHandler {
        target: "game"
        function toggle(): void { root.toggleGame() }
        function on(): void { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-gamemode.sh on"]) }
        function off(): void { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-gamemode.sh off"]) }
    }

    // ---------- timers · pomodoro · world clock (all live in the clock dropdown) ----------
    // A single 1s driver runs both a plain countdown and the pomodoro state machine; when a
    // pomodoro cycle is engaged, phase transitions flip DND (focus = quiet) and post a heads-up.
    property bool   tmrRunning: false        // a countdown exists (running or paused)
    property bool   tmrPaused:  false
    property int    tmrRemain:  0            // seconds left
    property int    tmrTotal:   0            // seconds the current phase started at (for the ring)
    property bool   pomoActive: false        // pomodoro cycle engaged (vs a one-off timer)
    property string pomoPhase:  "focus"      // focus | break | long
    property int    pomoDone:   0            // focus sessions completed this cycle
    // config (persisted to ~/.config/sea-shell/timers.json)
    property int    pomoFocusMin: 25
    property int    pomoBreakMin: 5
    property int    pomoLongMin:  15
    property int    pomoEvery:    4          // long break after every N focus sessions
    property bool   pomoDnd:      true       // auto-silence notifications during focus
    property bool   tmrWasDnd:    false      // DND state before the cycle, restored on stop
    readonly property string tmrText: {
        var s = Math.max(0, root.tmrRemain); var m = Math.floor(s/60); var ss = s%60;
        return (m<10?"0":"")+m+":"+(ss<10?"0":"")+ss;
    }
    Timer { id: tmrTick; interval: 1000; repeat: true; running: root.tmrRunning && !root.tmrPaused
        onTriggered: { if (root.tmrRemain > 0) root.tmrRemain -= 1; if (root.tmrRemain <= 0) root.tmrFinish(); } }
    function tmrStart(secs, phase) {
        root.tmrTotal = secs; root.tmrRemain = secs; root.pomoPhase = phase || "focus";
        root.tmrRunning = true; root.tmrPaused = false;
    }
    function tmrToggle() { if (root.tmrRunning) root.tmrPaused = !root.tmrPaused; }
    function tmrStop() {
        var wasPomo = root.pomoActive;
        root.tmrRunning = false; root.tmrPaused = false; root.tmrRemain = 0; root.tmrTotal = 0;
        root.pomoActive = false;
        if (wasPomo && root.pomoDnd && root.dnd && !root.tmrWasDnd) root.setDnd(false);
    }
    function tmrFinish() {
        root.tmrRunning = false; root.tmrPaused = false; root.tmrRemain = 0;
        if (root.pomoActive) { root._pomoAdvance(); return; }
        Quickshell.execDetached(["sh","-c","notify-send -u critical -a sea-shell -i alarm 'Timer finished' 'time is up' ; canberra-gtk-play -i complete 2>/dev/null || paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true"]);
    }
    // start a one-off countdown (minutes). Cancels any pomodoro cycle first.
    function timerStartMin(mins) {
        if (root.pomoActive) root.tmrStop();
        root.pomoActive = false; root.tmrStart(Math.max(1, Math.round(mins*60)), "timer");
    }
    function pomoStart() {
        root.pomoActive = true; root.pomoDone = 0; root.tmrWasDnd = root.dnd;
        if (root.pomoDnd) root.setDnd(true);
        root.tmrStart(root.pomoFocusMin*60, "focus");
    }
    function _pomoAdvance() {
        if (root.pomoPhase === "focus") {
            root.pomoDone += 1;
            var longNow = (root.pomoDone % root.pomoEvery === 0);
            var mins = longNow ? root.pomoLongMin : root.pomoBreakMin;
            if (root.pomoDnd && root.dnd && !root.tmrWasDnd) root.setDnd(false);   // breaks: notifications back
            Quickshell.execDetached(["sh","-c","notify-send -a sea-shell -i coffee 'Focus done' 'take a "+mins+" min break' ; canberra-gtk-play -i complete 2>/dev/null || true"]);
            root.tmrStart(mins*60, longNow ? "long" : "break");
        } else {
            if (root.pomoDnd && !root.tmrWasDnd) root.setDnd(true);
            Quickshell.execDetached(["sh","-c","notify-send -a sea-shell -i schedule 'Break over' 'back to focus' ; canberra-gtk-play -i complete 2>/dev/null || true"]);
            root.tmrStart(root.pomoFocusMin*60, "focus");
        }
    }
    function pomoSkip() { if (root.tmrRunning) root.tmrFinish(); }   // jump to the next phase
    // persistence: read config + world-clock zones at startup, write on change
    property var wcZones: []                 // ["Asia/Tokyo", …]
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/timers.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: tmrCfgOut; onStreamFinished: {
            try { var j = JSON.parse(tmrCfgOut.text.trim() || "{}");
                if (j.pomoFocus) root.pomoFocusMin = j.pomoFocus;
                if (j.pomoBreak) root.pomoBreakMin = j.pomoBreak;
                if (j.pomoLong)  root.pomoLongMin  = j.pomoLong;
                if (j.pomoEvery) root.pomoEvery    = j.pomoEvery;
                if (j.pomoDnd !== undefined) root.pomoDnd = !!j.pomoDnd;
                if (Array.isArray(j.zones)) root.wcZones = j.zones;
                if (Array.isArray(j.calFold)) root.calFold = j.calFold;
            } catch (e) {}
        } } }
    function tmrSaveCfg() {
        var o = { pomoFocus: root.pomoFocusMin, pomoBreak: root.pomoBreakMin, pomoLong: root.pomoLongMin,
                  pomoEvery: root.pomoEvery, pomoDnd: root.pomoDnd, zones: root.wcZones,
                  calFold: root.calFold };
        var s = JSON.stringify(o).replace(/'/g, "'\\''");
        Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && printf '%s' '" + s + "' > ~/.config/sea-shell/timers.json"]);
    }
    // Which sections of the clock dropdown are folded away.
    //
    // The panel stacks a month grid, the event list, the timer block and the world clock into one
    // uncapped column — about 720px with a full month and a few events, which runs off the bottom
    // of anything shorter than 1080p. Folding is per section and remembered, so the panel reopens
    // the shape you left it in rather than resetting to its tallest form every time.
    property var calFold: []
    function calFolded(k) { return root.calFold.indexOf(k) >= 0 }
    function calToggleFold(k) {
        var a = root.calFold.slice(); var i = a.indexOf(k);
        if (i >= 0) a.splice(i, 1); else a.push(k);
        root.calFold = a; root.tmrSaveCfg();
    }

    // world clock: one process prints "zone|HH:mm|ddd" per configured zone; refreshed each minute while open
    property var wcTimes: []                 // [{zone,label,time,day}]
    Process { id: wcProc
        stdout: StdioCollector { id: wcOut; onStreamFinished: {
            var out = [], lines = wcOut.text.trim().split("\n");
            for (var i=0;i<lines.length;i++) { var p = lines[i].split("|"); if (p.length>=3) {
                var seg = p[0].split("/"); var city = seg[seg.length-1].replace(/_/g," ");
                out.push({ zone: p[0], label: city, time: p[1], day: p[2] }); } }
            root.wcTimes = out;
        } } }
    function wcRefresh() {
        if (!root.wcZones.length) { root.wcTimes = []; return; }
        var parts = [];
        for (var i=0;i<root.wcZones.length;i++) { var z = ("" + root.wcZones[i]).replace(/'/g,"");
            parts.push("printf '%s|%s|%s\\n' '"+z+"' \"$(TZ='"+z+"' date +%H:%M)\" \"$(TZ='"+z+"' date +%a)\""); }
        wcProc.command = ["sh","-c", parts.join(";")];
        wcProc.running = true;
    }
    function wcAdd(zone)    { var z=(""+zone).trim(); if(!z) return; if(root.wcZones.indexOf(z)>=0) return; var a=root.wcZones.slice(); a.push(z); root.wcZones=a; root.tmrSaveCfg(); root.wcRefresh(); }
    function wcRemove(zone) { var a=root.wcZones.filter(function(z){return z!==zone;}); root.wcZones=a; root.tmrSaveCfg(); root.wcRefresh(); }
    readonly property var wcPresets: [
        {l:"New York", z:"America/New_York"}, {l:"Los Angeles", z:"America/Los_Angeles"},
        {l:"London", z:"Europe/London"}, {l:"Paris", z:"Europe/Paris"},
        {l:"Dubai", z:"Asia/Dubai"}, {l:"India", z:"Asia/Kolkata"},
        {l:"Singapore", z:"Asia/Singapore"}, {l:"Tokyo", z:"Asia/Tokyo"},
        {l:"Sydney", z:"Australia/Sydney"}, {l:"UTC", z:"UTC"} ]
    Timer { interval: 60000; running: root.openPop==="cal"; repeat: true; triggeredOnStart: true; onTriggered: root.wcRefresh() }

    ListModel { id: popupModel }      // transient on-screen popups
    NotificationServer {
        id: notifServer
        keepOnReload: false
        // Apps only attach action buttons if the server advertises support, so this being false
        // is why notifications here have always been text-only.
        actionsSupported: true
        bodyImagesSupported: false
        bodyMarkupSupported: true
        imageSupported: true
        onNotification: (n) => {
            var k = ++root.noteSeq;
            var app = (n.appName||"notification");
            var summary = (n.summary||""), body = (n.body||"");
            // The shell's scripts say `notify-send 'sea-shell' 'Colours matched'`: that names the
            // tool as the app and puts the shell's name where the title goes. Read it as meant.
            if (app === "notify-send") {
                app = "Notification";
                if (summary.toLowerCase() === "sea-shell") {
                    app = "sea-shell";
                    summary = body;
                    body = "";
                }
            }
            var entry = { key: k, summary: summary, body: body,
                          appName: app, appIcon: (n.appIcon||""), urgency: n.urgency,
                          time: Qt.formatDateTime(new Date(), "HH:mm"),
                          ts: Date.now() };   // the lock screen shows what arrived while locked
            // Actions live on the Notification object, and an UNTRACKED notification is released
            // by the server the moment this handler returns — so the buttons would be dead by the
            // time you could click one. Track ONLY notifications that actually have actions, and
            // release them again on dismiss, so nothing is held longer than it is useful.
            var acts = [];
            try {
                if (n.actions) for (var ai = 0; ai < n.actions.length; ai++)
                    acts.push({ i: ai, t: ("" + (n.actions[ai].text || "")) });
            } catch (e) {}
            if (acts.length > 0) {
                try { n.tracked = true; root.noteObjs[k] = n; root.noteObjsRev++; } catch (e) { acts = []; }
            }
            entry.actions = acts;
            root.notes = [entry].concat(root.notes).slice(0, 40);
            root.saveNotes();
            // DND or a per-app mute swallows the popup but keeps the history entry;
            // critical (urgency 2) breaks through either way so alerts aren't lost.
            // One popup per app: a newer message from the same app replaces the one on screen
            // and carries the count, so a burst of chat messages is one card, not a column.
            var piled = 1;
            for (var pi = popupModel.count - 1; pi >= 0; pi--) {
                var pm = popupModel.get(pi);
                if (pm.appName === app && pm.urg !== 2 && n.urgency !== 2) {
                    piled += (pm.n || 1);
                    if (pm.acts === "[]") root.noteRelease(pm.key);
                    popupModel.remove(pi);
                }
            }
            // A sender's photo or a song's cover lives only while the notification is tracked, so
            // hold it for as long as the card is up. Not for the history: forty of them would
            // sit in memory for a thumbnail nobody asked to keep.
            var shown = ((!root.silenced || root.isPriority(app)) && !root.isMuted(app)) || n.urgency === 2;
            var img = "" + (n.image || "");
            if (img && shown && !root.noteObjs[k]) {
                try { n.tracked = true; root.noteObjs[k] = n; root.noteObjsRev++; } catch (e) { img = ""; }
            }
            if (shown)
                popupModel.insert(0, { key: k, summary: entry.summary, body: entry.body,
                                       appName: entry.appName, appIcon: entry.appIcon || "", urg: n.urgency, n: piled,
                                       image: img.indexOf("/") === 0 ? "file://" + img : img,
                                       // ListModel roles stay primitive; the array rides as JSON
                                       acts: JSON.stringify(acts) });
            // not tracked → server releases it after this handler; we've copied the fields
        }
    }
    // Live notification objects for entries that carry actions, keyed by our own sequence number.
    // Deliberately NOT inside `notes` — that array is JSON.stringify'd to disk on every change,
    // and a QObject in there would corrupt the history file.
    property var noteObjs: ({})
    // Mutating a JS object does not re-evaluate anything that read it, so a button bound to
    // "is this notification still live" would never notice the server letting it go. The counter
    // is the dependency the bindings actually watch.
    property int noteObjsRev: 0
    function noteLive(k) { return root.noteObjsRev >= 0 && root.noteObjs[k] !== undefined }
    function noteRelease(k) {
        var n = root.noteObjs[k]; if (!n) return;
        try { n.tracked = false; } catch (e) {}
        delete root.noteObjs[k];
        root.noteObjsRev++;
    }
    function noteInvoke(k, idx) {
        var n = root.noteObjs[k];
        try { if (n && n.actions && n.actions[idx]) n.actions[idx].invoke(); } catch (e) {}
        root.popDismiss(k);
    }
    function popDismiss(k) { root.noteRelease(k); for (var i=0;i<popupModel.count;i++) if (popupModel.get(i).key===k) { popupModel.remove(i); return } }
    // Dismissing keeps what it took for a few seconds so it can be put back: a stray key or
    // click in the centre should never cost the history.
    property var noteUndo: null        // { label, items } of the last dismissal, while it can be undone
    Timer { id: noteUndoT; interval: 8000; onTriggered: root.noteUndo = null }
    function noteTake(keep, label) {
        var gone = root.notes.filter(function(n) { return !keep(n) });
        if (!gone.length) return;
        gone.forEach(function(n) { root.noteRelease(n.key); root.popDismiss(n.key) });
        root.notes = root.notes.filter(keep); root.saveNotes();
        root.noteUndo = { label: label, items: gone }; noteUndoT.restart();
    }
    function noteRemove(k) { root.noteTake(function(n) { return n.key !== k }, "Dismissed 1 notification") }
    function noteRemoveApp(app) { root.noteTake(function(n) { return n.appName !== app }, "Dismissed " + app) }
    function noteUndoNow() {
        if (!root.noteUndo) return;
        root.notes = root.notes.concat(root.noteUndo.items).sort(function(a, b) { return (b.key || 0) - (a.key || 0) }).slice(0, 40);
        root.saveNotes(); root.noteUndo = null; noteUndoT.stop();
    }
    // The centre shows one card per app, newest app first; within one, newest first.
    readonly property var noteGroups: {
        var by = {}, order = [];
        for (var i = 0; i < root.notes.length; i++) {
            var n = root.notes[i], k = n.appName || "notification";
            if (!by[k]) { by[k] = { app: k, icon: n.appIcon || "", items: [] }; order.push(k) }
            by[k].items.push(n);
        }
        return order.map(function(k) { return by[k] });
    }
    IpcHandler { target: "notifs"
        function dismissApp(app: string): void { root.noteRemoveApp(app) }
        function count(): int { return root.notes.length } }
    property var notifOpen: ({})       // app → expanded, for this opening of the centre
    property int notifCursor: -1       // keyboard position in noteGroups, -1 = none
    function noteClear() {
        var all = root.notes.slice();
        for (var k in root.noteObjs) root.noteRelease(k);
        root.notes = []; popupModel.clear(); root.saveNotes();
        if (all.length) { root.noteUndo = { label: "Cleared " + all.length + " notifications", items: all }; noteUndoT.restart() }
    }

    // ---------- OSD (volume + brightness) ----------
    property string osdKind: ""      // "vol" | "bright" | ""
    property real osdVal: 0
    property string osdIcon: ""
    property bool osdReady: false
    Timer { id: osdHide; interval: 1500; onTriggered: root.osdKind = "" }
    Timer { interval: 1400; running: true; onTriggered: root.osdReady = true }  // suppress OSD flash on startup
    function showOsd(kind, val, icon) { if(!root.osdReady) return; root.osdKind = kind; root.osdVal = val; root.osdIcon = icon; osdHide.restart() }

    // ---------- screen magnifier (Hyprland cursor:zoom_factor) ----------
    // Bound to SUPER +/-/0 in keybinds.conf → `qs -c sea-shell ipc call zoom …`. The OSD
    // reuses the volume/brightness card so the zoom level flashes on-screen as you step it.
    property real zoomFactor: 1.0
    readonly property real zoomMax: 5.0
    function zoomSet(f) {
        var z = Math.max(1.0, Math.min(root.zoomMax, Math.round(f * 100) / 100));
        root.zoomFactor = z;
        // keyword is legacy-parser only (Lua configs refuse it, 0.57 doesn't know it at all),
        // so fall back to eval — same pattern as matugen-accent.sh and the display tab.
        Quickshell.execDetached(["sh", "-c", "hyprctl keyword cursor:zoom_factor " + z + " 2>/dev/null | grep -q '^ok' || "
            + "hyprctl eval 'hl.config({ cursor = { zoom_factor = " + z + " } })' >/dev/null 2>&1"]);
        root.osdReady = true;   // zoom is always user-initiated — never a startup flash
        root.showOsd("zoom", (z - 1) / (root.zoomMax - 1), z > 1.01 ? "zoom_in" : "zoom_out");
    }
    function zoomIn()    { root.zoomSet(root.zoomFactor + (root.zoomFactor < 2 ? 0.25 : 0.5)); }
    function zoomOut()   { root.zoomSet(root.zoomFactor - (root.zoomFactor <= 2 ? 0.25 : 0.5)); }
    function zoomReset() { root.zoomSet(1.0); }
    IpcHandler {
        target: "zoom"
        function inc(): void   { root.zoomIn() }
        function dec(): void   { root.zoomOut() }
        function reset(): void { root.zoomReset() }
        function toggle(): void { root.zoomSet(root.zoomFactor > 1.01 ? 1.0 : 2.0) }
    }

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

    // A foldable section header for the clock dropdown. Carries the section's headline fact on
    // the right — a count, a running countdown — so a folded section still says whether there is
    // anything under it worth opening. No children: the body it controls is wrapped by the caller,
    // because a `default property alias` on a Column would swallow this component's own rows.
    component CalHead: Item {
        id: ch
        property string skey: ""
        property string title: ""
        property string summary: ""
        readonly property bool folded: root.calFolded(ch.skey)
        width: parent ? parent.width : 0
        height: 14
        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: ch.title; color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont
            font.bold: true }
        Text { anchors.right: chev.left; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter
            text: ch.summary; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
        Sym { id: chev; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: ch.folded ? "expand_more" : "expand_less"; sz: 13
            color: chm.containsMouse ? theme.iris : theme.faint }
        MouseArea { id: chm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: root.calToggleFold(ch.skey) }
    }

    component Slider: Item {
        id: sl
        property real value: 0
        property color fill: theme.iris
        signal moved(real v)
        implicitHeight: 20; implicitWidth: 150
        function clamp(v){ return Math.max(0,Math.min(1,v)) }
        Rectangle { id: trk; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 6; radius: Tok.r; color: theme.a(theme.line,0.85)
            Rectangle { width: trk.width*sl.clamp(sl.value); height: parent.height; radius: Tok.r; color: sl.fill } }
        Rectangle { width: 14; height: 14; radius: Tok.r; border.width: 2; border.color: sl.fill; color: theme.frost
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
        Rectangle { width: parent.width; height: 6; radius: Tok.r; color: theme.a(theme.line,0.85)
            Rectangle { height: parent.height; radius: Tok.r; color: barColor
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

        // A CLIP ALONE CUTS MID-GLYPH. The strip was chopped dead straight at both ends, so
        // a title scrolling past showed half a character hanging at each edge — which reads
        // as a rendering fault rather than as text continuing. It fades out instead.
        //
        // Only while it is actually scrolling: a title that fits needs no mask, and a render
        // layer per pill for nothing is a layer per pill for nothing.
        layer.enabled: mq.scrolling
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mqMask
        }
        Item {
            id: mqMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: "transparent" }
                    GradientStop { position: 0.08; color: "white" }
                    GradientStop { position: 0.92; color: "white" }
                    GradientStop { position: 1.00; color: "transparent" }
                }
            }
        }

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
                running: mq.visible && mq.scrolling && !Tok.reducedMotion && root.player && root.player.isPlaying
                loops: Animation.Infinite
                from: 0
                to: -mq.stride
                duration: Math.max(2000, mq.stride * 28)
                easing.type: Easing.Linear
                onRunningChanged: if (!running) strip.x = 0    // reset when paused / not scrolling
            }
        }
    }

    // one shortcut tile in the KDE Connect dropdown. `enabled` is Item's own — a device
    // that hasn't loaded the plugin greys the tile out AND kills its MouseArea for free.
    component KdeAct: Rectangle {
        id: ka
        property string icon: ""
        property string label: ""
        // iris, not frost: frost is near-white in the light palette and the glyph
        // vanishes into the tile
        property color tint: theme.iris
        signal act()
        implicitHeight: 32; radius: Tok.r
        color: !ka.enabled ? theme.a(theme.line, 0.22)
             : (kaMa.containsMouse ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.5))
        border.width: 1
        border.color: (ka.enabled && kaMa.containsMouse) ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
        Behavior on color { ColorAnimation { duration: 110 } }
        Row { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 7
            Sym { anchors.verticalCenter: parent.verticalCenter; text: ka.icon; sz: 15
                color: ka.enabled ? ka.tint : theme.a(theme.faint, 0.55) }
            Text { anchors.verticalCenter: parent.verticalCenter; text: ka.label
                color: ka.enabled ? theme.text : theme.a(theme.faint, 0.7)
                font.pixelSize: 11; font.family: root.cfgFont } }
        MouseArea { id: kaMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: ka.act() }
    }

    // a clickable bar pill that toggles a dropdown identified by `key`
    component Pill: Rectangle {
        id: pill
        // The widget id — keys BOTH the bar ordering (rightGroup.xFor) and the per-widget
        // appearance below. It used to be re-declared on all eighteen call sites; a pill's
        // identity is part of what a pill is, so it lives here.
        property string wid: ""
        // Pushed off the bar by the group because there was no room for it. NOT unloaded and not
        // `visible: false`: its bindings stay live so it returns the instant space does, and the
        // call sites keep `visible` for what the user asked for, which is a different question
        // from whether it fits.
        property bool overflowed: false
        property string icon: ""
        property string mark: ""          // an AiMark id, drawn instead of the material glyph
        property string markAlso: ""      // second brand when two products share the meter
        property string value: ""
        property string vertValue: ""    // compact value used on a vertical bar (falls back to value)
        property color accent: theme.frost
        // 1 = steady; pulse below 1 for a sputtering flame (GitHub streak with no commits today)
        property real ember: 1.0
        property string key: ""
        property bool scrollText: false
        property int maxTextW: 160
        signal clicked()
        signal rightClicked()
        signal scrolled(real dy)
        property var owner: null
        readonly property bool open: root.openPop === key && key !== ""
        readonly property bool hot: pill.open || pm.containsMouse

        // ---- per-widget appearance (Settings → Bar Widgets) ----
        // Absent entry = absent styling: every default here is what the pill drew before any
        // of this existed, so a config that has never been touched renders identically.
        readonly property var wgs: (pill.wid !== "" && root.cfgWgStyle) ? (root.cfgWgStyle[pill.wid] || null) : null
        readonly property string sGround:  (pill.wgs && pill.wgs.g) ? "" + pill.wgs.g : "filled"
        readonly property string sContent: (pill.wgs && pill.wgs.c) ? "" + pill.wgs.c : "both"

        // A CHOSEN COLOUR REPLACES THE RESTING COLOUR ONLY.  Nearly every pill on this bar
        // already says something with its tint when it matters — wi-fi off is red, pending
        // updates are amber, a muted microphone is red, a battery under 20% is red. A
        // preference that painted over those would be switching the signal off rather than
        // restyling it. So the choice applies while the pill sits at theme.frost, its idle
        // tint, and stands aside the instant the widget has something to report.
        readonly property color inkAccent: {
            var a = (pill.wgs && pill.wgs.a) ? "" + pill.wgs.a : "";
            if (a === "" || !Qt.colorEqual(pill.accent, theme.frost)) return pill.accent;
            switch (a) {
            case "iris":  return theme.iris;
            case "good":  return theme.good;
            case "warn":  return theme.warn;
            case "bad":   return theme.bad;
            case "text":  return theme.text;
            case "frost": return theme.frost;
            // A raw #hex is allowed but does NOT follow the wallpaper, which the settings
            // panel says out loud next to the field.
            default: return a.charAt(0) === "#" ? a : pill.accent;
            }
        }
        // SETTABLE. This was `readonly ... : false`, which meant the vertical branches below
        // — the stacked layout, the shared column width, the compact value — could never be
        // reached by anything. A side bar therefore had to hand-write its own pills, and did,
        // fourteen times over. See the note on verticalBarLayout for what that cost.
        property bool vert: false
        // On a vertical bar the pill becomes a capsule with the icon stacked over the value.
        // The value only shows when short enough to fit the narrow bar (a long string like the
        // full date would overflow) — so pills like battery/volume keep their readout while the
        // clock (given a compact HH:mm vertValue) stays legible and others fall back to icon-only.
        readonly property string vtext: pill.vertValue !== "" ? pill.vertValue : pill.value
        readonly property bool showVal: (pill.vert ? (pill.vtext.length > 0 && pill.vtext.length <= 6)
                                                   : (pill.value !== "")) && pill.sContent !== "icon"
        // "value" hides the icon — but a pill whose value is empty right now (the clipboard, the
        // control centre, a battery still reading) would then draw nothing at all: an invisible
        // pill that still takes width and still answers clicks. The icon stays in that case.
        readonly property bool showIcon: (pill.icon !== "" || pill.mark !== "") && (pill.sContent !== "value" || pill.value === "")
        implicitHeight: pill.vert ? (pr.implicitHeight + 12) : 26
        // vertical pills share ONE width (derived from bar thickness) so they stack into a
        // clean column with flush edges instead of a ragged centre-aligned zigzag
        implicitWidth:  pill.vert ? Math.max(30, root.cfgHeight - 12) : (pr.implicitWidth + 14)
        // uniform rounded-rectangle corners on a vertical bar (not a per-pill capsule, which
        // would make short pills horizontal ovals and tall ones vertical ovals)
        radius: pill.vert ? Math.min(13, height/2) : height/2
        opacity: pill.overflowed ? 0 : 1
        enabled: !pill.overflowed
        // ---- micro-motion ----
        // A pill that changes width (the clock crossing 9:59→10:00, the update count, the
        // menu strip changing window) used to jump, and because the left/right groups lay
        // themselves out by summing their children's widths, every widget after it jumped
        // with it. Animating the width makes the whole cluster slide over to make room,
        // which is the single change that stops the bar reading as a redrawn image.
        Behavior on width { NumberAnimation { duration: Tok.mFast
                                              easing.type: Easing.Bezier
                                              easing.bezierCurve: Tok.mMove } }
        Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
        // Presses answer. 6% for 90ms — under the threshold where you would call it an
        // animation, over the one where the button feels dead.
        scale: pm.pressed ? 0.94 : 1.0
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        // Hover and open still read on all three grounds — a bare pill that gave no feedback
        // would look like a label rather than a control.
        // Filled is a quiet tint of the ink on the glass, no outline, as the website's bar and
        // macOS's menu bar extras; open takes the accent. "outline" keeps its rim.
        color: pill.open                 ? theme.a(theme.iris, 0.20)
             : pill.sGround === "filled" ? (pm.containsMouse ? Tok.alpha(Tok.ink, 0.11) : Tok.alpha(Tok.ink, 0.055))
             : pm.containsMouse          ? Tok.alpha(Tok.ink, pill.sGround === "bare" ? 0.08 : 0.10)
             : "transparent"
        border.width: pill.sGround === "outline" ? 1 : 0
        border.color: pill.hot ? theme.a(theme.iris,0.55) : Tok.alpha(Tok.ink, 0.14)
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on border.color { ColorAnimation { duration: Tok.mFast } }


        // Grid (not Row) so the icon + value sit side-by-side (horizontal bar) or stacked
        // (vertical bar). Cross-axis centring is the Grid's job, so children carry no anchors.
        Grid { id: pr; anchors.centerIn: parent
            columns: pill.vert ? 1 : 99
            rowSpacing: 1; columnSpacing: 6
            horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
            // Material Symbols glyphs sit ~0.16em left of their advance box, so a centred
            // icon-only pill looks left-shifted. A Translate nudges the paint right to centre
            // the ink WITHOUT changing layout width (so icon+value spacing is untouched).
            AiMark {
                visible: pill.showIcon && pill.mark !== ""
                width: pill.vert ? 15 : (pill.markAlso !== "" ? 26 : 16); height: pill.vert ? 15 : 16
                tool: pill.mark; also: pill.markAlso; ink: pill.inkAccent
            }
            Rectangle {
                visible: pill.key === "ai" && root.aiIsLive(pill.mark)
                width: visible ? 7 : 0; height: visible ? 7 : 0; radius: 3.5
                color: "#1b7a4b"
                border.width: visible ? 1 : 0; border.color: Tok.bg
            }
            Sym { text: pill.icon; color: pill.inkAccent; visible: pill.showIcon && pill.mark === ""; sz: pill.vert ? 15 : 16
                scale: pill.ember
                opacity: 0.55 + 0.45 * pill.ember
                Behavior on scale { NumberAnimation { duration: 70 } }
                Behavior on opacity { NumberAnimation { duration: 70 } }
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
                Text { text: pill.vtext; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
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
        property int cardW: 280
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
        // UI scale for this monitor. The whole window contentItem is scaled by `ui` (below), so
        // ALL card/content/sidecar geometry is authored at native 1× and simply renders `ui`×
        // larger — only the screen-anchored card position is converted from physical → native.
        readonly property real ui: root.uiFor(dw.screen)
        // native (pre-scale) screen dimensions: physical ÷ ui
        readonly property real swN: dw.sw / dw.ui
        readonly property real shN: dw.sh / dw.ui
        // mapToGlobal speaks virtual-desktop coordinates; this surface is monitor-local,
        // so subtract the screen's global offset or cards drift on non-origin monitors
        readonly property int scrX: dw.screen ? dw.screen.x : 0
        readonly property int scrY: dw.screen ? dw.screen.y : 0
        // host size in NATIVE units. The host pill lives in the (scaled) bar, so its own
        // width/height are already native — no division needed.
        //
        // Read `width` ONLY. This used to be `width || implicitWidth`, and depending on both in
        // one binding is what produced "Binding loop detected for hostNW/hostNH" twelve times
        // over on every launch: an Item's width is itself bound to implicitWidth, so the
        // expression sat on both ends of that link and re-entered whenever the pill resized.
        // The fallback was never load-bearing — no Pill usage sets width, so it is always
        // exactly implicitWidth; the `||` only ever covered the pre-layout frame.
        readonly property real hostNW: dw.host ? dw.host.width  : 0
        readonly property real hostNH: dw.host ? dw.host.height : 0
        // host top-left in this window's NATIVE coordinates. mapToGlobal returns physical px, so
        // divide by ui. On a layer surface mapToGlobal omits the surface's inset on its docked
        // axis — a right/bottom bar reads as flush to the monitor's left/top — so add it back
        // (native units: the physical bar thickness cfgHeight·ui, ÷ ui = cfgHeight).
        readonly property real hostGX: (dw.hp.x - dw.scrX) / dw.ui + (root.cfgEdge === "right"  ? Math.max(0, dw.swN - root.cfgHeight) : 0)
        readonly property real hostGY: (dw.hp.y - dw.scrY) / dw.ui + (root.cfgEdge === "bottom" ? Math.max(0, dw.shN - root.cfgHeight) : 0)

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
        // Every dropdown has to be in the shared focus grab's list, or it is treated as outside
        // the grab and dismissed the frame it opens. They are built lazily (LazyLoader, after
        // startup), so each one adds itself when it exists and takes itself out when it goes.
        Component.onCompleted: {
            dw.held = dw.shown;
            root.grabWins = root.grabWins.concat([dw]);
            // Lazy Drops arm after openPop; release the hold once this surface is in the grab.
            if (dw.shown) {
                if (cardBg.openAnimFactor === 0.0 && !openAnim.running) openAnim.restart();
                root.grabHold = false;
            }
        }
        Component.onDestruction: root.grabWins = root.grabWins.filter(function(w) { return w && w !== dw })
        // Emphasized-decelerate: it leaves the bar quickly and settles, which is what makes a
        // card read as having been THROWN from the pill rather than faded up in place. Same
        // curve everything else in the shell now enters on.
        NumberAnimation { id: openAnim; target: cardBg; property: "openAnimFactor"; to: 1.0
                          duration: Tok.mBase
                          easing.type: Easing.Bezier; easing.bezierCurve: Tok.mEnter }

        // Fade the WHOLE window content (card gradient AND the text columns, which are
        // siblings of cardBg) as one. Fading only cardBg.opacity left the text at full
        // opacity — so on open it flashed in before the card, and on close it lingered a
        // frame after the card zeroed. contentItem is the parent of every default child,
        // so one binding fades everything together; close zeroes it on the same frame.
        Binding { target: dw.contentItem; property: "opacity"; value: cardBg.openAnimFactor }
        // scale the ENTIRE window content up on big displays. Origin at the window's top-left
        // (= monitor origin, since this surface fills the screen) so native coords map to
        // physical px by ×ui — every card/content/sidecar position stays 1× and just renders bigger.
        Binding { target: dw.contentItem; property: "transformOrigin"; value: Item.TopLeft }
        Binding { target: dw.contentItem; property: "scale"; value: dw.ui }

        Glass {
            id: cardBg
            property real openAnimFactor: 0.0
            width: dw.cardW; height: dw.cardH
            // the card opens off the side the bar is docked to: below a top bar, above a
            // bottom bar, to the right of a left bar, to the left of a right bar. It slides
            // in FROM the bar (12px) and is clamped to stay on-screen on the free axis.
            // All native units (the window content is scaled by dw.ui as a whole).
            readonly property real slide: (1.0 - openAnimFactor) * 12
            x: {
                if (root.cfgEdge === "left")  return dw.hostGX + dw.hostNW + 8 - slide;
                if (root.cfgEdge === "right") return dw.hostGX - dw.cardW - 8 + slide;
                return Math.max(8, Math.min(dw.swN - dw.cardW - 8, dw.hostGX + dw.hostNW/2 - dw.cardW/2));
            }
            y: {
                if (root.cfgEdge === "bottom") return dw.hostGY - dw.cardH - 8 + slide;
                if (root.barVertical)          return Math.max(8, Math.min(dw.shN - dw.cardH - 8, dw.hostGY + dw.hostNH/2 - dw.cardH/2));
                return dw.hostGY + dw.hostNH + 8 - slide;   // top bar
            }
            radius: 18
            // A hair of growth on the way in, anchored to the edge the card came from, so the
            // slide has some weight behind it. 1.5% — enough to feel, small enough that the
            // text never visibly resamples.
            scale: 0.985 + 0.015 * cardBg.openAnimFactor
            transformOrigin: root.cfgEdge === "bottom" ? Item.Bottom
                           : root.cfgEdge === "left"   ? Item.Left
                           : root.cfgEdge === "right"  ? Item.Right : Item.Top
            // Glass (Tok's material): the tint never drops below what keeps text readable,
            // and the blur behind is the wallpaper, so the app under a menu cannot dim it.
        }
    }

    // ============ one bar per monitor ============
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: bar
            readonly property bool widgetBar: true
            property var modelData
            screen: modelData
            // per-monitor: user can turn the bar off entirely on a given output.
            // Read modelData (the Variants source), NOT bar.screen — reading screen here
            // creates a visible↔screen-mapping binding loop.
            // Also unmap the layer surface entirely while Game Mode + "Hide bar while playing"
            // are active so Hyprland has zero bar surface to composite during gameplay.
            visible: root.monBar(bar.modelData ? bar.modelData.name : "") && !(root.gameOn && root.cfgHideGaming && root.openPop === "")
            // per-monitor UI scale — a 4K TV scales up while a 1080p laptop stays 1×
            readonly property real ui: root.uiFor(bar.screen)
            // which tray icon owns the shared tray menu dropdown
            property Item trayHost: null
            property var trayMenuSel: null
            // ---- auto-hide state ----
            property bool revealed: false
            property bool barHover: false
            readonly property bool fsActive: {
                try {
                    var t = Hyprland.activeToplevel;
                    return !!(t && t.lastIpcObject && t.lastIpcObject.fullscreen);
                } catch(e) { return false; }
            }
            readonly property bool gamingHide: root.cfgHideGaming && (root.gameOn || root.gameLive !== null)
            // the bar auto-hides when the user turned it on, or when configured to hide on fullscreen / gaming
            readonly property bool autoHiding: root.cfgAutoHide || (root.cfgHideFullscreen && bar.fsActive) || bar.gamingHide
            // the bar is "out" (fully shown) when not auto-hiding, or hovered, or a dropdown is open
            readonly property bool barOut: !bar.autoHiding || bar.revealed || root.openPop !== ""
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "sea-shell:bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand   // lets dropdown text fields (wifi pw) type
            // give up the reserved strip while auto-hiding so windows use the full screen
            exclusionMode: bar.autoHiding ? ExclusionMode.Ignore : ExclusionMode.Auto
            // while hidden, only a thin edge strip stays interactive so clicks pass through to apps
            mask: (bar.autoHiding && !bar.barOut) ? revealRegion : null
            Region { id: revealRegion; item: revealStrip }
            Timer { id: barHideTimer; interval: 550; onTriggered: if (root.openPop === "" && !bar.barHover) bar.revealed = false }
            // re-arm the hide once a dropdown closes or fullscreen kicks in, if the cursor's away
            Connections { target: root; function onGameOnChanged() { if (bar.autoHiding && !bar.barHover && root.openPop === "") barHideTimer.restart() } }
            Connections { target: root; function onGameLiveChanged() { if (bar.autoHiding && !bar.barHover && root.openPop === "") barHideTimer.restart() } }
            Connections { target: root; function onOpenPopChanged() { if (root.openPop === "" && bar.autoHiding && !bar.barHover) barHideTimer.restart() } }
            onAutoHidingChanged: if (bar.autoHiding && !bar.barHover && root.openPop === "") barHideTimer.restart()
            // a sliver pinned to the docked edge — hovering it slides the bar back out
            Item {
                id: revealStrip
                height: root.cfgEdge === "bottom" || !root.barVertical ? 4 : parent.height
                width:  root.barVertical ? 4 : parent.width
                anchors.top:    root.cfgEdge !== "bottom" ? parent.top : undefined
                anchors.bottom: root.cfgEdge === "bottom" ? parent.bottom : undefined
                anchors.left:   root.cfgEdge !== "right" ? parent.left : undefined
                anchors.right:  root.cfgEdge === "right" ? parent.right : undefined
                HoverHandler { onHoveredChanged: if (hovered) { barHideTimer.stop(); bar.revealed = true } }
            }
            // 4-way docking: top/bottom stretch horizontally (anchor left+right + a fixed
            // height); left/right stretch vertically (anchor top+bottom + a fixed width).
            anchors.top:    root.cfgEdge === "top"    || root.barVertical
            anchors.bottom: root.cfgEdge === "bottom" || root.barVertical
            anchors.left:   root.cfgEdge === "left"   || !root.barVertical
            anchors.right:  root.cfgEdge === "right"  || !root.barVertical
            implicitHeight: root.barVertical ? 0 : root.cfgHeight * bar.ui
            implicitWidth:  root.barVertical ? root.cfgHeight * bar.ui : 0

            // barInset owns the edge gap; barBg lays out at native (1×) size inside it and is
            // Scale-transformed up by `bar.ui`. Everything below barBg therefore lives in one
            // native coordinate space — the pill-collision math and dropdown anchoring all work
            // unchanged, and the whole bar simply renders `ui`× larger on a big display.
            Item {
                id: barInset
                anchors.fill: parent
                // gap on the docked edge / free edges, scaled with the UI so it stays proportional
                anchors.topMargin:    (root.cfgEdge === "bottom" ? 0 : (root.barVertical ? 8 : 6)) * bar.ui
                anchors.bottomMargin: (root.cfgEdge === "top"    ? 0 : (root.barVertical ? 8 : 6)) * bar.ui
                anchors.leftMargin:   (root.cfgEdge === "right"  ? 0 : (root.barVertical ? 6 : 8)) * bar.ui
                anchors.rightMargin:  (root.cfgEdge === "left"   ? 0 : (root.barVertical ? 6 : 8)) * bar.ui
                // auto-hide: slide the bar off its docked edge when tucked away
                transform: Translate {
                    x: bar.barOut ? 0 : (root.cfgEdge === "right" ? (bar.width + 12) : (root.cfgEdge === "left" ? -(bar.width + 12) : 0))
                    y: bar.barOut ? 0 : (root.cfgEdge === "bottom" ? (bar.height + 12) : (root.cfgEdge === "top" ? -(bar.height + 12) : 0))
                    Behavior on x { NumberAnimation { duration: 210; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: 210; easing.type: Easing.OutCubic } }
                }
                HoverHandler { onHoveredChanged: { bar.barHover = hovered; if (hovered) { barHideTimer.stop(); bar.revealed = true } else if (bar.autoHiding) barHideTimer.restart() } }
            Glass {
                id: barBg
                width: barInset.width / bar.ui
                height: barInset.height / bar.ui
                transformOrigin: Item.TopLeft
                scale: bar.ui
                radius: Tok.rCard
                // The opacity slider stays live — a see-through bar is a deliberate feature here
                // (at 0% the fill and outline both vanish and only the chips remain), so it is
                // left alone. The rim is the part that changes: a hairline rule rather than an
                // accent tint, so the accent goes back to marking active state only.
                // In PILL mode the strip itself carries nothing: the three clusters grow
                // their own grounds below, and one continuous background behind them would
                // just be the bar again with extra outlines drawn on it.
                on: !root.barPills
                tint: root.barFillColor

                Item {
                    id: horizontalBarLayout
                    anchors.fill: parent

                    // ---- PILL MODE: a ground per cluster ----
                    // Two, not three: the centre cluster is the media pill, which already has
                    // its own rounded ground — putting an island behind it would be a pill
                    // drawn around a pill. So the left and right clusters get one each and the
                    // middle one is simply itself.
                    //
                    // z:-1 rather than declaration order, because these have to sit behind
                    // siblings that are declared further down and positioned by xFor().
                    Glass {
                        z: -1
                        visible: root.barPills && leftGroup.width > 0
                        anchors.fill: leftGroup
                        anchors.margins: -6
                        anchors.leftMargin: -9
                        anchors.rightMargin: -9
                        radius: Tok.rCard
                        tint: root.barFillColor
                    }
                    Glass {
                        z: -1
                        visible: root.barPills && rightGroup.width > 0
                        anchors.fill: rightGroup
                        anchors.margins: -6
                        anchors.leftMargin: -9
                        anchors.rightMargin: -9
                        radius: Tok.rCard
                        tint: root.barFillColor
                    }
                    // Never use visible:false — a hidden subtree collapses its Text pills'
                    // implicitWidth to 0 and doesn't recover on re-show, which is what wiped
                    // the right group when switching orientation. Stay laid-out; reveal via
                    // opacity so both orientations are independent, always-measured entities.
                    opacity: root.barVertical ? 0 : 1
                    enabled: !root.barVertical
                    z: root.barVertical ? 0 : 1

                    // ---------- START: logo · workspaces · app name ----------
                // Order-driven cluster (was a Grid): each child carries an `lid` and is placed by
                // its index in root.cfgLeftOrder, so the Settings drag-reorder rearranges the left
                // side. Same xFor/spanW technique as the right group; horizontal bar only.
                Item {
                    id: leftGroup
                    readonly property int gap: 7
                    property var order: root.cfgLeftOrder
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: 26
                    implicitWidth: leftGroup.spanW()
                    width: implicitWidth
                    // The workspaces + title and the global menu trade places on focus changes.
                    // menuShown lags gmenu.available so the swap can fade: on the way in, the
                    // workspaces fade out first and the menu fades in where they were. On the
                    // way out the old menu is already gone (the snapshot is the new window's),
                    // so the workspaces just fade straight back in.
                    //
                    // Switching fast means most of these fades get interrupted. So only a real
                    // change of content restarts from invisible; otherwise it carries on from
                    // wherever it had got to, and going back and forth never blinks.
                    property bool menuShown: false
                    property real swapFade: 1
                    property real swapSlide: 0
                    function settleSwap(shown) {
                        swapAnim.stop();
                        swapOut.stop();
                        if (shown !== leftGroup.menuShown) {
                            leftGroup.menuShown = shown;
                            leftGroup.swapFade = 0;
                            leftGroup.swapSlide = -6;
                        }
                        swapIn.start();
                    }
                    Connections {
                        target: gmenu
                        function onAvailableChanged() {
                            if (!gmenu.available) leftGroup.settleSwap(false);
                            else if (leftGroup.menuShown) leftGroup.settleSwap(true);
                            else { swapIn.stop(); swapOut.stop(); swapAnim.start(); }
                        }
                        // Focus has moved and the daemon has not caught up: the strip on screen
                        // is about the last window, so it goes, and what replaces it waits.
                        function onSwitchingChanged() {
                            if (gmenu.switching) {
                                if (!leftGroup.menuShown) return;
                                swapAnim.stop();
                                swapIn.stop();
                                swapOut.start();
                            } else if (leftGroup.menuShown) {
                                leftGroup.settleSwap(gmenu.available);
                            }
                        }
                    }
                    NumberAnimation { id: swapOut; target: leftGroup; property: "swapFade"; to: 0
                        duration: Math.min(Tok.mMicro, 50); easing.type: Easing.OutCubic }
                    SequentialAnimation {
                        id: swapAnim
                        NumberAnimation { target: leftGroup; property: "swapFade"; to: 0
                            duration: Math.min(Tok.mMicro, 50); easing.type: Easing.OutCubic }
                        ScriptAction { script: leftGroup.settleSwap(gmenu.available) }
                    }
                    ParallelAnimation {
                        id: swapIn
                        NumberAnimation { target: leftGroup; property: "swapFade"; to: 1
                            duration: Tok.mBase; easing.type: Easing.OutCubic }
                        NumberAnimation { target: leftGroup; property: "swapSlide"; to: 0
                            duration: Tok.mBase; easing.type: Easing.OutCubic }
                    }
                    function oidx(w) { var i = leftGroup.order ? leftGroup.order.indexOf(w) : -1; return i < 0 ? 999 : i; }
                    // BOTH `visible` AND `width` ARE READ FOR EVERY CHILD, EVERY TIME, and the
                    // short-circuit only happens after. A QML binding re-runs when a property
                    // it actually READ during its last evaluation changes, and the old
                    // `!c.visible || c.width <= 0` never reached the width of a hidden child —
                    // so once a child had been skipped while hidden, its later width was
                    // invisible to this sum and every widget after it stayed at a stale x.
                    // It survived because the left cluster rarely changes shape mid-session;
                    // the global menu changes it on every focus change, which is enough to
                    // hit it.
                    function xFor(w) {
                        var kids = leftGroup.children, myi = leftGroup.oidx(w), sum = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.lid === undefined) continue;
                            var vis = c.visible, cw = c.width;
                            if (!vis || cw <= 0) continue;
                            if (leftGroup.oidx(c.lid) < myi) sum += cw + leftGroup.gap;
                        }
                        return sum;
                    }
                    function spanW() {
                        var kids = leftGroup.children, tot = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.lid === undefined) continue;
                            var vis = c.visible, cw = c.width;
                            if (!vis || cw <= 0) continue;
                            tot += cw + leftGroup.gap;
                        }
                        return Math.max(0, tot - leftGroup.gap);
                    }
                    BarLogo { id: seaMark
                        property string lid: "lgLogo"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        size: 24
                        kind: root.logoKind
                        imagePath: root.cfgBarLogoPath
                        card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            // Right-click still goes straight to the launcher, so the old
                            // one-click habit has somewhere to land.
                            onClicked: (e)=> {
                                if (e.button === Qt.RightButton) { launcher.toggle(); return }
                                root.openPop = (root.openPop === "sea") ? "" : "sea";
                            } } }
                    LazyLoader {
                        activeAsync: (root.openPop === "sea" && bar.modelData && Hyprland.focusedMonitor
                                  && bar.modelData.name === Hyprland.focusedMonitor.name)
                                 || !!(item && item.visible)
                        Drop { screen: bar.screen
                        id: seaDrop; host: root.barVertical ? logoVert : seaMark
                        // NOT `root.openBar === bar`. That is the right test for a pill,
                        // because a pill click can say which bar it belongs to — but the
                        // sea menu also opens from an IPC call and a keybind, where there
                        // is no pill and nothing to compare against. Each bar deciding for
                        // itself whether it owns the focused monitor needs no such handoff.
                        shown: root.openPop === "sea" && bar.modelData
                               && Hyprland.focusedMonitor
                               && bar.modelData.name === Hyprland.focusedMonitor.name
                        cardW: 300
                        cardH: seaCol.implicitHeight + 12
                        // Drawn to the same rules as the window menus next to it: rows inset
                        // from the card so the highlight is a pill rather than a band, a
                        // FILLED accent for the row under the pointer with Tok.accentInk on
                        // top, separators inset to the text, and the shortcut flush right in
                        // mono so the column lines up. The system menu sitting beside the
                        // application menus and looking like a different program was the
                        // thing to fix.
                        Column { id: seaCol; anchors.fill: seaDrop.card; anchors.margins: 6; spacing: 0
                            Repeater {
                                model: root.seaMenuItems
                                delegate: Item {
                                    id: smRow
                                    required property var modelData
                                    readonly property bool isSep: !!modelData.sep
                                    readonly property bool lit: !smRow.isSep && smMa.containsMouse
                                    width: seaCol.width
                                    height: isSep ? 9 : 26
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter
                                        visible: smRow.isSep
                                        x: 10; width: Math.max(0, parent.width - 20); height: 1
                                        color: theme.a(theme.line, 0.55) }
                                    Rectangle { anchors.fill: parent; anchors.topMargin: 1; anchors.bottomMargin: 1
                                        visible: smRow.lit
                                        radius: Math.min(7, Tok.r); color: theme.iris }
                                    SeaLogo { visible: smRow.modelData.id === "about"
                                        anchors.left: parent.left; anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        size: 15; accent: theme.iris }
                                    Sym { visible: !smRow.isSep && smRow.modelData.id !== "about"
                                        anchors.left: parent.left; anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.icon || ""; sz: 15
                                        color: smRow.lit ? Tok.accentInk : theme.sub
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } } }
                                    Text { visible: !smRow.isSep
                                        anchors.left: parent.left; anchors.leftMargin: 34
                                        anchors.right: smKey.left; anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        text: modelData.label || ""
                                        color: smRow.lit ? Tok.accentInk : theme.text
                                        font.pixelSize: 12; font.family: Tok.sans
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } } }
                                    Text { id: smKey
                                        visible: !smRow.isSep && !!modelData.key
                                        anchors.right: parent.right; anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.key || ""
                                        color: smRow.lit ? Tok.alpha(Tok.accentInk, 0.75) : theme.faint
                                        font.pixelSize: 11; font.family: Tok.mono
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } } }
                                    MouseArea { id: smMa; anchors.fill: parent; hoverEnabled: true
                                        enabled: !smRow.isSep
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.seaMenuRun(modelData.id) }
                                }
                            }
                        }
                    }
                    }
                    Grid { property string lid: "lgWork"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        // A menu bar is long, and the left cluster is the only place it can go
                        // without running into the media pill. So the workspaces stand down for
                        // it: they are a glance, and the menu is something you are using right
                        // now. They come straight back the moment the focused window has no menu
                        // — which is most windows — and the left group measures only visible
                        // children, so the menu simply starts where they were.
                        visible: !leftGroup.menuShown
                        opacity: leftGroup.swapFade
                        transform: Translate { x: leftGroup.swapSlide }
                        columns: 99
                        rowSpacing: 6; columnSpacing: 6
                        verticalItemAlignment: Grid.AlignVCenter
                        Repeater {
                            model: root.stripWorkspaces
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                // Special workspaces are not places in the strip. Hyprland numbers
                                // them from -98 down, so SUPER+` put a chip reading "-98" in the
                                // bar — a label that doesn't fit its own 24px circle, and one whose
                                // click dispatched focus({ workspace = -98 }), which is not how a
                                // special workspace is reached anyway. The scratchpad is an OVERLAY
                                // on the workspace you are already on; it has no place in a list of
                                // places to go, and its windows being on screen is what tells you
                                // it is open. (A Positioner skips invisible children outright, so
                                // this leaves no gap where the chip used to be.)
                                visible: modelData.id > 0
                                // Two ways to say which one you are on.
                                //   grow — a circle per workspace, the active one stretching
                                //          into a pill along the bar's long axis. Movement
                                //          carries the state, so it survives any palette.
                                //   pill — every workspace the same pill, the active one
                                //          filled. Nothing moves; the row keeps a fixed width,
                                //          which is what people want it back for.
                                //   grow   — a rounded chip per workspace, the active one
                                //            stretching along the bar's long axis. Movement
                                //            carries the state, so it survives any palette.
                                //   pill   — every workspace the same chip, the active one
                                //            filled. Nothing moves; the row keeps a fixed
                                //            width, which is what people want it back for.
                                //   circle — the same, actually round. Wide labels (VIII, 十二)
                                //            push it out rather than being clipped, so it is a
                                //            circle when it can be and a lozenge when it cannot.
                                readonly property real labelW: wsLabelTxt.implicitWidth + 14
                                //   grow   — a chip each, the active one stretching along the
                                //            bar. Its corner radius follows the roundness
                                //            slider, so at a low roundness these are rounded
                                //            SQUARES, not circles.
                                //   pill   — every workspace the same chip, the active one
                                //            filled. Nothing moves; the row keeps a fixed width.
                                //   circle — the old shape, properly: true circles that STRETCH
                                //            into a true pill on the one you are on. The radius
                                //            is half the height rather than the roundness
                                //            slider, so it is round at any setting.
                                width:  root.cfgWsStyle === "circle" ? (foc ? Math.max(38, labelW) : Math.max(24, labelW))
                                      : root.cfgWsStyle === "pill"   ? Math.max(30, labelW)
                                      : (foc ? Math.max(36, labelW) : Math.max(24, labelW))
                                height: 24
                                radius: root.cfgWsStyle === "circle" ? height / 2 : Tok.r
                                color: foc ? theme.iris : theme.a(theme.line,0.55)
                                border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris,0.18)
                                Behavior on width  { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Text { id: wsLabelTxt; anchors.centerIn: parent
                                    text: root.wsLabelFor(modelData.id)
                                    color: foc ? theme.bg : theme.sub
                                    font.pixelSize: 12; font.family: root.wsFontFamily; font.bold: foc }
                                // Left switches workspace; right swaps the workspaces for the
                                // focused window's menu bar and back. The gesture is on the
                                // two things it swaps — this and the menu strip — rather than
                                // on the whole bar: bar-wide, it fired in the gaps BESIDE the
                                // volume and clock pills but not on them, because those keep
                                // their own right-click, and a gesture that works in the gaps
                                // and not on the buttons just reads as broken.
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (e)=> {
                                        if (e.button === Qt.RightButton) {
                                            if (!gmenu.hasNativeMenu) {
                                                gmenu.showManualMenu = !gmenu.showManualMenu;
                                                return;
                                            }
                                            root.gmenuToggle();
                                            return;
                                        }
                                        Hyprland.dispatch("hl.dsp.focus({ workspace = "+modelData.id+" })");
                                    } }
                            }
                        }
                    }
                    // THE STASH. Not the special workspace put back into the strip — read the
                    // note above, it is still not a place you travel to. This is a different
                    // fact: how many windows you are currently holding out of sight. Nothing
                    // in the bar used to say so, which made SUPER+SHIFT+` a way to lose a
                    // window until you remembered the other half of the binding.
                    //
                    // It exists only while it has something to report. Stash the last window
                    // and it removes itself — xFor skips invisible children, so the cluster
                    // closes up behind it and no dead chrome is left holding a zero.
                    Rectangle {
                        id: scratchMark
                        property string lid: "lgScratch"
                        x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.scratchCount > 0
                        width: scratchRow.implicitWidth + 14
                        height: 24
                        radius: root.cfgWsStyle === "circle" ? height / 2 : Tok.r
                        // Filled when the stash is DOWN, exactly as the workspace you are on is
                        // filled: one grammar for "this is the thing you are looking at".
                        color: root.scratchOpen ? theme.iris : theme.a(theme.line, 0.55)
                        border.width: 1
                        border.color: root.scratchOpen ? theme.frost : theme.a(theme.iris, 0.18)
                        Behavior on color { ColorAnimation { duration: 160 } }
                        Row {
                            id: scratchRow
                            anchors.centerIn: parent
                            spacing: 3
                            Text { anchors.verticalCenter: parent.verticalCenter
                                text: "inventory_2"
                                font.family: "Material Symbols Outlined"; font.pixelSize: 13
                                color: root.scratchOpen ? theme.bg : theme.sub }
                            Text { anchors.verticalCenter: parent.verticalCenter
                                text: "" + root.scratchCount
                                color: root.scratchOpen ? theme.bg : theme.sub
                                font.pixelSize: 12; font.family: root.wsFontFamily
                                font.bold: root.scratchOpen }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            // Pulled over the workspace you are standing on, never focused —
                            // focus({ workspace = -98 }) is a no-op, which is what made the
                            // old chip useless as well as unreadable.
                            onClicked: Hyprland.dispatch("hl.dsp.workspace.toggle_special('scratch')") }
                    }
                    // The focused window's menu bar, when it has one. It shares lgTitle's slot
                    // with the title below and the two are mutually exclusive, so the bar's
                    // layout needs no new widget id and no settings migration: whichever of
                    // the pair is visible is the one the left group measures.
                    GlobalMenu {
                        id: gmenu
                        property string lid: "lgTitle"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        // overrides GlobalMenu's own `visible: available`, so the strip waits
                        // for the workspaces to fade out before it takes their place
                        visible: available && leftGroup.menuShown
                        opacity: leftGroup.swapFade
                        transform: Translate { x: leftGroup.swapSlide }
                        pal: theme
                        uiFont: root.cfgFont
                        script: root.appmenuScript
                        screenName: bar.modelData ? bar.modelData.name : ""
                        // the ACTIVE WINDOW's monitor, not the focused one: with follow_mouse,
                        // moving the pointer onto an empty screen focuses that screen while the
                        // window keeps the keyboard, and its menu then jumped to the empty screen's
                        // bar while the screen it is on fell back to the workspaces
                        focusedMonitor: root.activeWinMonitor
                        ui: root.uiFor(bar.screen)
                        barEdgeY: root.cfgHeight
                        barEdge: root.cfgEdge
                        // How far the strip may run before it folds the rest behind a
                        // chevron. The left cluster shares the bar with a centred media
                        // pill, and an app with a dozen top-level menus (LibreOffice has
                        // twelve) would otherwise push that pill out of the centre.
                        maxWidth: Math.max(140, barBg.width * 0.38)
                        openPing: root.gmenuOpenPing
                        searchPing: root.gmenuSearchPing
                        // one opacity slider moves the bar and everything that drops out of it
                        dropOpacity: root.dropOpacity
                        // Never on a side bar. A vertical bar is 42px WIDE — there is no room for
                        // "File Edit View" in it, and the left cluster it lives in is only
                        // held at opacity 0 there rather than removed, so without this the
                        // strip was still reading menus and still opening its drop off an
                        // invisible pill.
                        featureOn: root.gmenuEnabled && !root.barVertical
                        showKeys: root.gmenuAccel
                        // any change here means the focused window changed — see the note
                        // on focusHint in GlobalMenu.qml
                        focusHint: {
                            try {
                                var t = Hyprland.activeToplevel;
                                if (!t) return "";
                                var o = t.lastIpcObject;
                                if (o) return "" + (o.pid || "") + ":" + (o.class || "") + ":" + (o.title || "");
                                return "" + (t.address || "");
                            } catch (e) { return "" }
                        }
                        onToggleRequested: root.gmenuToggle()
                    }
                    Text {
                        // the window title. Capped short so a long app class (e.g. electron apps)
                        // can't grow into the centre and push the media pill out — it's only a hint.
                        property string lid: "lgTitle"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        visible: !leftGroup.menuShown
                        opacity: leftGroup.swapFade
                        transform: Translate { x: leftGroup.swapSlide }
                        width: Math.min(implicitWidth, 130); elide: Text.ElideRight
                        color: theme.sub; font.pixelSize: 12; font.family: Tok.sans
                        text: {
                            // Same staleness as the strip had: activeToplevel keeps naming the
                            // window you left once focus drops to nothing, so an empty desktop
                            // sat here labelled "code". The daemon's snapshot is the one thing
                            // that can say nothing is focused.
                            if (gmenu.snapSaysNoWindow) return "";
                            // Not until the daemon has said this window has no menu of its own, or
                            // an app about to show its menu flashes its raw class name here first.
                            if (gmenu.available || gmenu.snapStale) return "";
                            // only on the bar of the screen the window is on (see focusedMonitor above)
                            if (bar.modelData && root.activeWinMonitor && bar.modelData.name !== root.activeWinMonitor) return "";
                            try {
                                var t = Hyprland.activeToplevel;
                                if (!t) return "";
                                if (t.lastIpcObject && t.lastIpcObject.class) return "" + t.lastIpcObject.class;
                                if (t.wayland && t.wayland.appId) return "" + t.wayland.appId;
                                return "";
                            } catch(e) { return ""; }
                        }
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
                LazyLoader { activeAsync: (root.openPop ==="mpris" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                    id: mprisDrop; host: root.barVertical ? mprisPillVert : mprisPill; shown: root.openPop ==="mpris" && root.openBar === bar
                    cardW: Math.min(748, mprisDrop.swN - 24); cardH: Math.min(300, mprisDrop.shN - root.cfgHeight - 24)

                    onVisibleChanged: if (visible && root.lyricsOpen) root.fetchLyrics()   // track may have changed while closed
                    MediaPlayerFrame {
                        uiFont: Tok.sans
                        id: mediaFrame; anchors.fill: mprisDrop.card
                        player: root.player; mascotSource: root.stickerUrl(root.cfgStickerMedia); selectedTab: root.mediaTab; viz: root.vizBars; active: mprisDrop.shown; reducedMotion: Tok.reducedMotion
                        ink: Tok.ink; secondary: Tok.ink2; accent: Tok.accent; wash: Tok.accentWash; rule: Tok.rule
                        onSelected: tab => root.mediaTab = tab
                    }
                    Column { id: mprCol
                        parent: mediaFrame.controlsHost
                        width: parent.width; spacing: 7

                        // player switcher chips (only when several apps are playing)
                        Row { width: parent.width; spacing: 6; visible: root.players.length > 1
                            Repeater { model: root.players.length
                                delegate: Rectangle { required property int index
                                    property bool cur: index === Math.min(root.playerSel, root.players.length-1)
                                    width: pcTxt.width + 18; height: 20; radius: Tok.r
                                    color: cur ? theme.a(theme.iris,0.28) : (pcMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.5))
                                    border.width: cur ? 1 : 0; border.color: theme.iris
                                    Text { id: pcTxt; anchors.centerIn: parent; text: root.players[index].identity||"Player"
                                        color: cur ? theme.text : theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.playerSel = index } } } }

                        // Shuffle and repeat sit either side of the transport, as on every player, and
                        // the seek bar under it. All of it centres in what the rows below leave free.
                        Item { width: parent.width
                            height: mediaFrame.controlsHost.height - y - 7 - outputRow.height - (volumeRow.visible ? volumeRow.height + 7 : 0)
                            Column { anchors.centerIn: parent; width: parent.width; spacing: 10
                                Item { width: parent.width; height: 72
                                    MaterialWidget { id: mprControls; anchors.fill: parent
                                        kind: "media"; mediaPart: "controls"; player: root.player; viz: root.vizBars; active: mprisDrop.shown
                                        surface: Tok.surface; container: Tok.accentWash; accent: Tok.accent
                                        ink: Tok.ink; secondary: Tok.ink2; accentInk: Tok.accentInk; reducedMotion: Tok.reducedMotion
                                    }
                                    Rectangle { width: 36; height: 36; radius: 18
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.horizontalCenter: parent.horizontalCenter; anchors.horizontalCenterOffset: -118
                                        readonly property bool on: !!root.player && root.player.shuffle
                                        color: on ? Tok.alpha(Tok.accent, 0.18) : "transparent"
                                        opacity: root.player && root.player.shuffleSupported ? 1 : 0.35
                                        Sym { anchors.centerIn: parent; text: "shuffle"; sz: 20; color: parent.on ? Tok.accent : Tok.ink2 }
                                        MouseArea { anchors.fill: parent; enabled: !!root.player && root.player.shuffleSupported; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.player.shuffle = !root.player.shuffle }
                                    }
                                    Rectangle { width: 36; height: 36; radius: 18
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.horizontalCenter: parent.horizontalCenter; anchors.horizontalCenterOffset: 118
                                        readonly property bool on: !!root.player && root.player.loopState !== MprisLoopState.None
                                        color: on ? Tok.alpha(Tok.accent, 0.18) : "transparent"
                                        opacity: root.player && root.player.loopSupported ? 1 : 0.35
                                        Sym { anchors.centerIn: parent; sz: 20; color: parent.on ? Tok.accent : Tok.ink2
                                            text: root.player && root.player.loopState === MprisLoopState.Track ? "repeat_one" : "repeat" }
                                        MouseArea { anchors.fill: parent; enabled: !!root.player && root.player.loopSupported; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.player.loopState = root.player.loopState===MprisLoopState.None ? MprisLoopState.Playlist : root.player.loopState===MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None }
                                    }
                                }
                                Item { width: parent.width; height: 28
                                    visible: !!root.player && root.player.length > 0
                                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; y: 3; height: 4; radius: 2; color: theme.a(theme.line,0.85)
                                        Rectangle { height: parent.height; radius: 2; color: theme.a(theme.iris,0.8)
                                            width: parent.width * (root.player && root.player.length > 0 ? Math.max(0, Math.min(1, mprControls.playPosition / root.player.length)) : 0) } }
                                    MouseArea { anchors.left: parent.left; anchors.right: parent.right; height: 12
                                        enabled: !!root.player && root.player.canSeek; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: (e) => mprControls.seek(e.x / width) }
                                    Text { anchors.left: parent.left; anchors.bottom: parent.bottom; text: mprControls.timeText(root.player ? Math.min(mprControls.playPosition, root.player.length) : 0)
                                        color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    Text { anchors.right: parent.right; anchors.bottom: parent.bottom; text: mprControls.timeText(root.player ? root.player.length : 0)
                                        color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                }
                            }
                        }

                        // ---- signal chain ----
                        // The one thing no other shell can tell you: where the audio is actually
                        // going, and whether it is arriving untouched. It was two 10px lines wedged
                        // under the album name. It is the most specific fact this panel holds, so it
                        // gets a strip of its own and reads like the instrument readout it is.
                        Rectangle { id: outputRow
                            width: parent.width; height: 26; radius: Tok.r
                            visible: root.player !== null
                            color: "transparent"
                            border.width: 0
                            border.color: theme.a(theme.line,0.9)
                            Row { anchors.left: parent.left
                                anchors.right: hqChip.left; anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter
                                    text: "volume_up"; sz: 13; color: theme.sub }
                                Text { anchors.verticalCenter: parent.verticalCenter
                                    text: "Output"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Text { anchors.verticalCenter: parent.verticalCenter
                                    text: root.outputLabel; elide: Text.ElideRight
                                    color: theme.sub
                                    font.pixelSize: 11; font.family: Tok.sans } }
                            IndChip { id: hqChip
                                anchors.right: parent.right; anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.hqInfo !== ""
                                text: root.hqInfo + (root.exclusiveHold ? " \u00b7 exclusive" : "")
                                tone: "warn" } }

                        // ---- player volume ----
                        Row { id: volumeRow; width: parent.width; spacing: 8; visible: root.player ? root.player.volumeSupported : false
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_down"; sz: 15; color: theme.sub }
                            Item { width: parent.width - 48; height: 12; anchors.verticalCenter: parent.verticalCenter
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: Tok.r; color: theme.a(theme.line,0.85)
                                    Rectangle { height: parent.height; radius: Tok.r; color: theme.a(theme.iris,0.8)
                                        width: parent.width * (root.player ? Math.max(0,Math.min(1,root.player.volume)) : 0) } }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    function setV(x) { if (root.player) root.player.volume = Math.max(0, Math.min(1, x/width)) }
                                    onPressed: (e)=> setV(e.x); onPositionChanged: (e)=> { if (pressed) setV(e.x) } } }
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_up"; sz: 15; color: theme.sub } }

                    }

                    // ---- lyrics sidecar: full-height panel next to the player card ----
                    Rectangle {
                        id: lyrPanel
                        parent: mediaFrame.lyricsHost
                        anchors.fill: parent
                        color: "transparent"; border.width: 0
                        Column { anchors.fill: parent; anchors.margins: 0; spacing: 8
                            Item {
                                width: parent.width; height: 24
                                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0,parent.width-lyricHeaderActions.width-12); elide: Text.ElideRight
                                    text: "Lyrics"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: Tok.sans }
                                Row { id: lyricHeaderActions; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                    Repeater { model: [{k:"r",l:"あ→a"},{k:"t",l:"EN"}]
                                        delegate: Rectangle { required property var modelData
                                            readonly property bool on: modelData.k==="r" ? root.cfgLyrRomaji : root.cfgLyrTrans
                                            height: 20; radius: 6; width: languageLabel.implicitWidth+12
                                            color: on ? Tok.alpha(Tok.accent, 0.18) : Tok.alpha(Tok.ink, 0.06)
                                            Text { id: languageLabel; anchors.centerIn: parent; text: modelData.l; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: modelData.k==="r" ? root.lyrToggleRomaji() : root.lyrToggleTrans() }
                                        }
                                    }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: root.lyricsState==="ok"
                                        text: "Synced"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                }
                            }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            // height was hardcoded to `- 34` against a header that has since grown a
                            // row of 18px chips, so the list ran past the bottom of the panel
                            Item { width: parent.width; height: parent.height - 44
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="loading"; text: "Fetching lyrics…"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="none"; text: "No lyrics found"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                // synced: follows playback, current line highlighted, click to seek
                                ListView { id: lyrView; anchors.fill: parent; visible: root.lyricsState==="ok"; clip: true
                                    model: root.lyrics; spacing: 3
                                    // the active line sits mid-panel, so lines were being sliced in half
                                    // at both edges; the list now runs out past them and fades instead
                                    topMargin: 2; bottomMargin: 10
                                    maximumFlickVelocity: 1400
                                    delegate: Item { required property var modelData; required property int index
                                        // Stacked rather than a mode switch: singing along needs the
                                        // original and the reading at the same time, not one or the other.
                                        readonly property string sub2: {
                                            var r = (root.cfgLyrRomaji && root.lyrRomaji.length > index) ? root.lyrRomaji[index] : "";
                                            var t = (root.cfgLyrTrans  && root.lyrTrans.length  > index) ? root.lyrTrans[index]  : "";
                                            // Romaji is dropped when it only echoes a Latin line back — but
                                            // compared on letters alone, because pykakasi re-spaces around
                                            // punctuation ("Yeah, yeah" → "Yeah , yeah") and an exact compare
                                            // therefore never matched, printing every English chorus twice.
                                            if (r) {
                                                var norm = function(x) { return ("" + x).toLowerCase().replace(/[^a-z0-9]/g, "") };
                                                if (norm(r) === norm(modelData.l)) r = "";
                                            }
                                            return (r && t) ? r + "\n" + t : (r || t);
                                        }
                                        width: lyrView.width; height: lyCol.height + 8
                                        Column { id: lyCol; width: parent.width; anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                        Text { id: lyT; width: parent.width
                                            text: modelData.l; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                                            color: index===root.lyrIdx ? theme.frost : (index<root.lyrIdx ? theme.faint : theme.sub)
                                            font.pixelSize: index===root.lyrIdx ? 17 : 13; font.bold: index===root.lyrIdx; font.family: Tok.sans
                                            Behavior on color { ColorAnimation { duration: 150 } } }
                                        Text { width: parent.width; visible: parent.parent.sub2 !== ""
                                            text: parent.parent.sub2; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                                            color: index===root.lyrIdx ? theme.iris : theme.faint
                                            font.pixelSize: index===root.lyrIdx ? 11 : 10; font.family: Tok.sans
                                            font.italic: true } }
                                        MouseArea { anchors.fill: parent; cursorShape: (root.player&&root.player.canSeek)?Qt.PointingHandCursor:Qt.ArrowCursor
                                            onClicked: { if (root.player && root.player.canSeek) { root.player.position = modelData.t; root.mprisPos = modelData.t } } } }
                                    Connections { target: root; function onLyrIdxChanged() { if (root.lyrIdx >= 0) lyrView.positionViewAtIndex(root.lyrIdx, ListView.Center) } } }
                                // plain (unsynced) fallback: just scroll
                                Flickable { anchors.fill: parent; visible: root.lyricsState==="plain"; clip: true
                                    contentHeight: plainT.height; boundsBehavior: Flickable.StopAtBounds
                                    Text { id: plainT; width: parent.width; text: root.plainLyrics; wrapMode: Text.Wrap
                                        horizontalAlignment: Text.AlignHCenter; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans } } } } }

                    // ---- track-details sidecar: opens on the OPPOSITE side of the lyrics panel ----
                    Rectangle {
                        id: infoPanel
                        parent: mediaFrame.detailsHost
                        anchors.fill: parent
                        color: "transparent"; border.width: 0
                        onVisibleChanged: if (visible) root.fetchMeta()
                        clip: true
                        Flickable { id: infoScroll; anchors.fill: parent; anchors.margins: 0
                            contentWidth: width; contentHeight: detailsCol.implicitHeight; clip: true; boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.VerticalFlick
                            interactive: contentHeight > height + 1
                            onContentHeightChanged: if (contentHeight <= height + 1) contentY = 0
                            onHeightChanged: if (contentHeight <= height + 1) contentY = 0
                        Column { id: detailsCol; width: infoScroll.width; spacing: 6
                            Row { width: parent.width; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "info"; sz: 15; color: theme.iris }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Track details"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: Tok.sans } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            // detail rows (static ones via a model; live time rows bound directly so they don't rebuild the list)
                            Column { id: infoRows; width: parent.width; spacing: 6
                                Repeater {
                                    model: {
                                        var p = root.player; if (!p) return [];
                                        var rows = [
                                            {k:"Album",   v: p.trackAlbum || "—"},
                                            {k:"Source",  v: p.identity || "—"},
                                            // where it physically comes out: a Moondrop is named by the
                                            // script's registry, anything else falls back to pipewire
                                            {k:"Output",  v: root.outputLabel},
                                            {k:"Quality", v: root.hqInfo !== "" ? root.hqInfo : "standard"},
                                            {k:"Length",  v: root.fmtTime(p.length||0)}
                                        ];
                                        // only once MusicBrainz has actually answered for THIS track
                                        if (root.metaState === "ok" && root.metaReleased !== "")
                                            rows.splice(2, 0, {k:"Released", v: root.metaReleased});
                                        else if (root.metaState === "loading")
                                            rows.splice(2, 0, {k:"Released", v: "…"});
                                        return rows;
                                    }
                                    // Label and value used to be anchored to opposite edges with the
                                    // value pinned at 62% — so they overlapped when the label was long
                                    // and truncated when the value was ("24-bit · 44.1 kHz · bit-pe…").
                                    // Now the label takes what it needs, the value gets the rest and
                                    // wraps to a second line instead of being cut.
                                    delegate: Item { required property var modelData
                                        width: infoRows.width
                                        implicitHeight: Math.max(16, valTxt.implicitHeight + 2)
                                        // Key as a tracked uppercase label, value in mono: this is a
                                        // readout of facts about a file — codec, bitrate, release year,
                                        // sink — and the shell's own token file says machine-readable
                                        // values are mono and prose is sans. It was all one face before,
                                        // so nothing in the panel told you which was which.
                                        IndLabel { id: keyTxt
                                            anchors.left: parent.left; anchors.top: parent.top; anchors.topMargin: 1
                                            width: Math.min(implicitWidth, parent.width * 0.38); elide: Text.ElideRight
                                            sz: 9; text: modelData.k }
                                        IndText { id: valTxt
                                            anchors.left: keyTxt.right; anchors.leftMargin: 10
                                            anchors.right: parent.right; anchors.top: parent.top
                                            horizontalAlignment: Text.AlignRight
                                            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                                            mono: true; sz: 11; text: modelData.v; color: theme.text } }
                                }
                                Item { width: infoRows.width; height: 16
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Elapsed"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight
                                        text: root.fmtTime(root.mprisPos); color: theme.text; font.pixelSize: 11; font.family: Tok.sans } }
                                Item { width: infoRows.width; height: 16
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Remaining"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight
                                        text: "-" + root.fmtTime(Math.max(0,(root.player?root.player.length:0)-root.mprisPos)); color: theme.text; font.pixelSize: 11; font.family: Tok.sans } } }
                        }
                        }
                    } }
                }

                // ---------- END: weather · tray · wifi · vol · battery · clock ----------
                // Grid, same trick as leftGroup — horizontal (top/bottom) or vertical (left/right).
                // Anchored to the far edge: right for a horizontal bar, bottom for a vertical one.
                // Order-driven layout (was a Grid): each child pill carries a `wid` and is placed
                // by its index in root.cfgWidgetOrder, so the Settings drag-reorder rearranges the
                // bar. All positions are declarative — `xFor`/`spanW` read sibling width+visibility,
                // so QML re-lays-out automatically when a pill resizes, hides, or the order changes.
                Item {
                    id: rightGroup
                    readonly property int gap: 7
                    property var order: root.cfgWidgetOrder
                    anchors.right:  parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: 26
                    implicitWidth: rightGroup.spanW()
                    width: implicitWidth
                    // position of a widget id in the saved order (unknown → far end)
                    function oidx(w) {
                        if (w === "wgOverflow") return -1;          // always the centre-most item
                        if (w === "wgPrivacy") return -2;           // not a choice you make, so not in the saved order
                        if (w === "wgGame") return -3;              // gaming session indicator (transient)
                        var i = rightGroup.order ? rightGroup.order.indexOf(w) : -1; return i < 0 ? 999 : i;
                    }
                    // x of a child = summed widths of visible siblings ordered before it (left→right)
                    function xFor(w) {
                        var kids = rightGroup.children, myi = rightGroup.oidx(w), sum = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.wid === undefined || !c.visible || c.overflowed || c.width <= 0) continue;
                            if (rightGroup.oidx(c.wid) < myi) sum += c.width + rightGroup.gap;
                        }
                        return sum;
                    }

                    // ---------- OVERFLOW ----------
                    // This cluster was right-anchored with implicitWidth = spanW() and no ceiling,
                    // so it simply grew leftward: enough pills carrying values — weather, network
                    // throughput, an update count, a multi-reading system monitor, the full date —
                    // and it reached the centre pill, then kept going into the left cluster. The
                    // media pill already yields (it measures the gap and hides under 26px of text),
                    // but nothing stopped the cluster after that.
                    //
                    // The reserve for the centre is a CONSTANT rather than the media pill's measured
                    // width, and that is deliberate: the pill sizes itself FROM the gap between the
                    // clusters, so reading its width here would be a binding loop.
                    readonly property real centreReserve: (root.cfgMpris && root.player !== null) ? 120 : 0
                    readonly property real budget: {
                        var barW = barBg.width;
                        if (barW <= 0) return 9999;
                        var rightEdge = barW - rightGroup.anchors.rightMargin;
                        var lim = rightEdge - (leftGroup.x + leftGroup.width) - 12;      // never reach the left cluster
                        if (rightGroup.centreReserve > 0)                                 // nor the centre pill's zone
                            lim = Math.min(lim, rightEdge - (barW / 2 + rightGroup.centreReserve / 2 + 10));
                        return Math.max(80, lim);
                    }
                    // Width the cluster would want with nothing pushed out. Safe to feed the
                    // decision below because a pill's own width does not change when it is pushed
                    // out — only its opacity does — so this measurement cannot chase its own tail.
                    function natW() {
                        var kids = rightGroup.children, tot = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            // The indicator is excluded, or it flaps: it appearing makes the cluster
                            // wider, which is the very condition that made it appear.
                            if (!c || c.wid === undefined || c.wid === "wgOverflow") continue;
                            if (!c.visible || c.width <= 0) continue;
                            tot += c.width + rightGroup.gap;
                        }
                        return Math.max(0, tot - rightGroup.gap);
                    }
                    property int pushedCount: 0
                    // Pushes from the CENTRE-MOST end outward. The far-right end is where the
                    // anchors live — clock, power, battery — and the pills nearest the centre are
                    // the ones actually colliding, so they are the ones that give way.
                    function reflow() {
                        var kids = rightGroup.children, list = [];
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (c && c.wid !== undefined && c.wid !== "wgOverflow" && c.visible && c.width > 0) list.push(c);
                        }
                        list.sort(function (a, b) { return rightGroup.oidx(a.wid) - rightGroup.oidx(b.wid) });
                        var over = rightGroup.natW() - rightGroup.budget, n = 0;
                        if (over > 0) over += 40;      // the ⋯ chip has to fit somewhere too
                        for (var i = 0; i < list.length; i++) {
                            var push = over > 0;
                            if (push) { over -= (list[i].width + rightGroup.gap); n++; }
                            if (list[i].overflowed !== push) list[i].overflowed = push;
                        }
                        rightGroup.pushedCount = n;
                    }
                    // Re-evaluates whenever any child's width or visibility changes, or the bar
                    // resizes — every one of those is a property read inside natW()/budget.
                    readonly property real reflowTrigger: rightGroup.natW() + rightGroup.budget
                    onReflowTriggerChanged: Qt.callLater(rightGroup.reflow)
                    Component.onCompleted: Qt.callLater(rightGroup.reflow)
                    // total laid-out width → drives the right anchor and the centre pill's free-space calc
                    function spanW() {
                        var kids = rightGroup.children, tot = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            // Pushed-out pills must not be counted here either: this drives the
                            // group's own width, and the group is anchored to the right — so
                            // counting them made the cluster wider than its contents and left the
                            // surviving pills floating in from the edge.
                            if (!c || c.wid === undefined || !c.visible || c.overflowed || c.width <= 0) continue;
                            tot += c.width + rightGroup.gap;
                        }
                        return Math.max(0, tot - rightGroup.gap);
                    }

                    // ---- WEATHER dropdown (its pill is declared after the tray, below) ----
                    

                    // ---- SYSTEM TRAY (after weather) — collapsible, right-click = app menu ----
                    Grid { columns: 99; rowSpacing: 2; columnSpacing: 2
                        // The tray is the one cluster member that is not a Pill, and it is also the
                        // one whose width the shell does not control — it is however many icons other
                        // applications decided to put there. It carries the same overflow contract.
                        property bool overflowed: false
                        opacity: overflowed ? 0 : 1
                        enabled: !overflowed
                        property string wid: "wgTray"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                        visible: root.cfgTray && SystemTray.items.values.length > 0
                        // collapse / expand toggle
                        Rectangle { width: 16; height: 16; radius: Tok.r
                            visible: SystemTray.items.values.length > 0
                            color: tcm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                            Sym { anchors.centerIn: parent; text: root.trayCollapsed ? "chevron_left" : "chevron_right"; sz: 12; color: theme.sub }
                            MouseArea { id: tcm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed } }
                        Grid { columns: 99; rowSpacing: 2; columnSpacing: 2; visible: !root.trayCollapsed
                            horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                            Repeater { model: SystemTray.items
                                delegate: Item { id: trayItem; required property SystemTrayItem modelData; width: 18; height: 18
                                    Image { width: 36; height: 36; anchors.centerIn: parent; scale: 0.5; asynchronous: true
                                        source: { try { return (trayItem.modelData && trayItem.modelData.icon) ? trayItem.modelData.icon : "" } catch(e) { return "" } }
                                        sourceSize.width: 96; sourceSize.height: 96; smooth: true; mipmap: true; fillMode: Image.PreserveAspectFit }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton|Qt.RightButton
                                        onClicked: (e)=>{
                                            try {
                                                if (!trayItem.modelData) return;
                                                if (e.button===Qt.LeftButton) { trayItem.modelData.activate(); return }
                                                if (root.openPop==="tray" && bar.trayHost===trayItem) { root.openPop=""; return }
                                                bar.trayHost = trayItem; bar.trayMenuSel = trayItem.modelData; root.openBar = bar; root.openPop = "tray"
                                            } catch(err) { root.openPop=""; }
                                        } }
                                } } } }

                    // ---- shared tray menu: ONE blurable layer-surface Drop (sea-shell:drop),
                    // part of the openPop single-dropdown system so the focus grab dismisses it ----
                    

                    // ---- OVERFLOW ----
                    // Sits at the centre-most end, which is where the pills that could not fit
                    // used to run into the media pill. Nothing disappears silently: the count is
                    // how many the bar had to push out, and it goes straight to the tab where you
                    // can switch some off or reorder them.
                    Pill { owner: bar
                        wid: "wgOverflow"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: rightGroup.pushedCount > 0
                        icon: "more_horiz"; value: "" + rightGroup.pushedCount
                        accent: theme.warn
                        onClicked: root.openSettings(12) }

                    // ---- CONTROL CENTER (quick toggles + power profile) ----
                    Pill { owner: bar; id: ccPill; key: "cc"
                        wid: "wgQuick"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgQuick
                        icon: "tune"; accent: theme.frost }

                    // ---- WEATHER pill (placed after the tray) ----
                    Pill { owner: bar; id: wxPill; key: "wx"
                        wid: "wgWeather"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgWeather && root.wxTemp!==""; icon: root.wxIcon(root.wxCond); value: root.wxTemp; accent: theme.frost }

                    // ---- CLIPBOARD (opens the launcher in clipboard mode) ----
                    Pill { owner: bar; icon: "content_paste"; accent: theme.frost
                        wid: "wgClipboard"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgClipboard
                        onClicked: { root.openPop = ""; launcher.open(";") } }

                    // ---- PENDING UPDATES ----
                    Pill { owner: bar; id: updPill; key: "upd"
                        wid: "wgUpdates"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgUpdates
                        icon: root.updTotal > 0 ? "system_update_alt" : "task_alt"
                        accent: root.updTotal > 0 ? theme.warn : theme.frost
                        value: root.updTotal > 0 ? String(root.updTotal) : "" }

                    // ---- AI USAGE (allowance left, and when that window resets) ----
                    Pill { owner: bar; id: aiPill; key: "ai"
                        wid: "wgAi"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgAi
                        mark: root.aiShown ? root.aiShown.id : "claude"
                        markAlso: (root.aiShown && root.aiShown.with) ? root.aiShown.with : ""
                        accent: root.aiAccent
                        value: root.aiBarValue
                        maxTextW: 72 }

                    // ---- GITHUB (today's commits / streak) ----
                    Pill { owner: bar; id: ghPill; key: "gh"
                        wid: "wgGithub"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgGithub
                        icon: root.githubPillIcon
                        accent: root.githubPillAccent
                        ember: root.githubSputter ? root.githubEmber : 1.0
                        value: root.githubBarValue
                        maxTextW: 48 }

                    // ---- TOTEM (2FA) ----
                    Pill { owner: bar; id: totemPill; key: "totem"
                        wid: "wgTotem"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgTotem
                        icon: root.totemPillIcon
                        accent: root.totemPillAccent
                        value: root.totemCode !== "" ? root.totemCode : ""
                        maxTextW: 72 }

                    // ---- NETWORK THROUGHPUT ----
                    // No dropdown: the pill IS the readout, and the per-interface detail lives in
                    // the Dashboard where there is room for it. Clicking opens Network settings.
                    Pill { owner: bar; id: netPill; key: ""
                        wid: "wgNet"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNet
                        icon: "swap_vert"
                        accent: (root.netRx + root.netTx) > 262144 ? theme.iris : theme.frost
                        value: root.netFmt(root.netRx) + "  " + root.netFmt(root.netTx)
                        vertValue: root.netFmt(root.netRx + root.netTx)
                        maxTextW: 140
                        onClicked: root.openSettings(2) }

                    // ---- NOTIFICATION CENTER (bell + badge) ----
                    Pill { owner: bar; id: bellPill; key: "notif"
                        wid: "wgNotif"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNotif
                        icon: root.silenced ? "notifications_off" : (root.notes.length>0 ? "notifications" : "notifications_none")
                        accent: root.silenced ? theme.warn : (root.notes.length>0 ? theme.iris : theme.frost)
                        value: root.silenced ? "" : (root.notes.length>0 ? String(root.notes.length) : "") }

                    // ---- IN USE: mic, camera, screen. Only there while something is ----
                    Pill { owner: bar; id: privacyPill
                        wid: "wgPrivacy"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.privacyLabel !== ""
                        icon: root.cameraApps.length ? "videocam" : (root.micApps.length ? "mic" : "screen_share")
                        accent: theme.warn; value: root.privacyLabel; maxTextW: 130
                        onClicked: root.openSettings(0) }
                    

                    // ---- WIFI ----
                    Pill { owner: bar; id: wifiPill; key: "wifi"
                        wid: "wgWifi"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgWifi
                        icon: root.wifiIcon; accent: root.wifiAccent
                        }   // icon-only: SSID lives in the dropdown
                    

                    // ---- BLUETOOTH ----
                    Pill { owner: bar; id: btPill
                        wid: "wgBluetooth"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgBluetooth && root.btAdapter !== null
                        key: root.btAdapter ? "bt" : ""
                        icon: (!root.btAdapter || !root.btAdapter.enabled) ? "bluetooth_disabled" : (root.btActive ? "bluetooth_connected" : (root.btAdapter.discovering ? "bluetooth_searching" : "bluetooth"))
                        accent: root.btActive ? theme.iris : ((root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint)
                        // show the connected device name, plus its battery % when the device reports one
                        value: root.btActive ? (root.btName(root.btActive) + (root.btActive.batteryAvailable ? "  " + Math.round((root.btActive.battery||0)*100) + "%" : "")) : "" }

                    // ---- MICROPHONE ----
                    // Muted is the state worth shouting about, so it takes the crit colour: an open
                    // mic you think is muted is the failure that matters, and the reverse is worse.
                    Pill { owner: bar; id: micPill; key: "mic"
                        wid: "wgMic"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgMic
                        icon: root.micMuted ? "mic_off" : "mic"
                        accent: root.micMuted ? theme.bad : theme.good
                        value: root.micMuted ? "" : Math.round(root.micVol*100) + "%"
                        onClicked: root.micToggle() }

                    // ---- KDE CONNECT ----
                    // icon-only when there's nothing to say; the phone's battery is the one
                    // number worth bar space (the name would eat 150px and is in the dropdown).
                    // Colour follows the battery the same way the laptop pill does.
                    Pill { owner: bar; id: kdePill; key: "kde"
                        wid: "wgKdeconnect"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgKdeconnect
                        icon: root.kdeActive ? root.kdeIcon(root.kdeDev) : "phonelink_off"
                        accent: !root.kdeActive ? theme.faint
                              : (root.kdeDev.isCharging ? theme.good
                              : (root.kdeBattery >= 0 && root.kdeBattery <= 20 ? theme.bad : theme.iris))
                        value: root.kdeBattery >= 0 ? root.kdeBattery + "%" : "" }


                    // ---- GAMING ---- (game mode and/or an active Steam/gamescope window)
                    Pill { owner: bar; id: gamePill
                        wid: "wgGame"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.gameOn || root.gameLive !== null
                        icon: "sports_esports"
                        accent: root.gameOn ? theme.iris : theme.frost
                        value: root.gameBarValue
                        maxTextW: 160
                        onClicked: {
                            if (root.gameOn) root.toggleGame();
                            root.openDashboardGaming();
                        } }

                    // ---- CAFFEINE ---- (mug icon; lit yellow when keeping the screen awake)
                    Pill { owner: bar
                        wid: "wgCaffeine"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgCaffeine
                        icon: "coffee"
                        // yellow while caffeine is active (screen kept awake → hypridle killed → idleOn false)
                        accent: root.idleOn ? theme.sub : theme.warn
                        value: ""
                        onClicked: root.toggleIdle() }

                    // ---- NIGHT LIGHT ---- (warm-screen toggle; lit warm when active)
                    Pill { owner: bar
                        wid: "wgNight"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNightWidget
                        icon: "nightlight"
                        accent: root.nightActive ? theme.warn : theme.sub
                        value: ""
                        onClicked: root.ccToggle("night") }

                    // ---- SYSTEM MONITOR (cpu · ram · gpu) ----
                    Pill { owner: bar; id: sysPill; key: "sys"
                        wid: "wgSystem"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgSystem
                        icon: "speed"; value: root.sysPillText
                        accent: root.sysMetrics[root.sysShown[0]].c() }
                    

                    // ---- VOLUME ----
                    Pill { owner: bar; id: volPill; key: "vol"
                        wid: "wgVolume"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
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
                        wid: "wgBattery"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        readonly property var dev: UPower.displayDevice
                        readonly property bool charging: !UPower.onBattery
                        readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                        visible: root.cfgBattery && dev && dev.isLaptopBattery
                        key: visible ? "bat" : ""
                        icon: charging?"battery_charging_full":pct>=90?"battery_full":pct>=60?"battery_5_bar":pct>=35?"battery_3_bar":pct>=15?"battery_1_bar":"battery_alert"
                        value: pct+"%"; accent: charging?theme.good:pct<=20?theme.bad:theme.frost }
                    

                    // ---- SCREEN RECORDER PILL ----
                    // Transient: it exists only while something is being recorded.
                    // Left-click stops and keeps. Right-click arms a discard, and a second
                    // right-click throws the take away — while armed the pill says so.
                    Pill { owner: bar; id: recPill
                        wid: "wgRec"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.recordingActive
                        icon: root.recDiscardArmed ? "delete" : "fiber_manual_record"
                        accent: root.recDiscardArmed ? theme.warn : theme.a(theme.bad, root.recPulse)
                        value: root.recDiscardArmed ? "discard?" : root.recordingTime
                        maxTextW: 90
                        onClicked: {
                            // an armed pill left-clicked = "no, keep it" — then stop normally
                            root.recDiscardArmed = false; recDisarm.stop();
                            recPanel.stop();
                        }
                        onRightClicked: {
                            if (root.recDiscardArmed) { root.recDiscardArmed = false; recDisarm.stop(); recPanel.cancel() }
                            else { root.recDiscardArmed = true; recDisarm.restart() }
                        }
                    }

                    // ---- CLOCK ----
                    Pill { owner: bar; id: clockPill; key: "cal"
                        wid: "wgClock"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgClock
                        // when a timer/pomodoro is live the pill becomes a countdown; otherwise it's the clock
                        icon: root.tmrRunning ? (root.pomoActive ? (root.pomoPhase==="focus" ? "local_fire_department" : "coffee") : "timer") : "schedule"
                        value: root.tmrRunning ? root.tmrText : Qt.formatDateTime(clock.date, root.cfgClock24 ? (root.cfgClockSeconds ? "ddd d MMM · HH:mm:ss" : "ddd d MMM · HH:mm") : (root.cfgClockSeconds ? "ddd d MMM · h:mm:ss ap" : "ddd d MMM · h:mm ap"))
                        vertValue: root.tmrRunning ? root.tmrText : Qt.formatDateTime(clock.date, root.cfgClock24 ? (root.cfgClockSeconds ? "HH:mm:ss" : "HH:mm") : (root.cfgClockSeconds ? "h:mm:ss" : "h:mm"))
                        accent: root.tmrRunning ? (root.tmrPaused ? theme.warn : (root.pomoActive && root.pomoPhase!=="focus" ? theme.good : theme.iris)) : theme.iris }
                     

                    // ---- POWER (very end) ----
                    Pill { owner: bar; id: pwrPill; key: "pwr"; icon: "power_settings_new"; accent: theme.bad
                        wid: "wgPower"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgPower }
                    
                }

                // dropdown windows for the END cluster — kept OUT of the rightGroup positioner:
                // a layer-surface window reads to a Grid as a full-height item, which in a vertical
                // (columns:1) bar would insert screen-tall gaps. They anchor to their host by id, so
                // their parent doesn't matter — parking them here keeps the Grid pill-only.
                Item { id: rightGroupDrops
                    // ---- UPDATES dropdown: what is pending, and one button to install it ----
                    LazyLoader { activeAsync: (root.openPop === "gh" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: ghDrop; host: root.barVertical ? ghPillVert : ghPill; shown: root.openPop === "gh" && root.openBar === bar
                        cardW: 340; cardH: ghCol.implicitHeight + 28
                        Column { id: ghCol; anchors.fill: ghDrop.card; anchors.margins: 14; spacing: 12
                            Row {
                                width: parent.width
                                Text { text: root.githubPillIcon; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: root.githubPillAccent; anchors.verticalCenter: parent.verticalCenter
                                    scale: root.githubSputter ? root.githubEmber : 1.0 }
                                Item { width: 8; height: 1 }
                                Text {
                                    text: (root.github && root.github.ok) ? ("@" + root.github.login) : "GitHub"
                                    color: theme.text; font.pixelSize: 13; font.family: Tok.sans; font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Item { Layout.fillWidth: true; width: parent.width - x - refreshLbl.width - 4; height: 1 }
                                Text {
                                    id: refreshLbl
                                    text: "Refresh"
                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: root.refreshGithub(true) }
                                }
                            }
                            // Stats: three equal columns, figures centred
                            Row {
                                width: parent.width
                                Repeater {
                                    model: [
                                        { v: String((root.github && root.github.today) || 0), l: "today" },
                                        { v: String((root.github && root.github.streak) || 0), l: "streak" },
                                        { v: String((root.github && root.github.year) || 0), l: "year" }
                                    ]
                                    delegate: Item {
                                        required property var modelData
                                        width: parent.width / 3; height: statCol.implicitHeight
                                        Column {
                                            id: statCol
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            spacing: 2
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.v; color: theme.text; font.pixelSize: 22; font.family: Tok.sans; font.bold: true
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.l; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                            }
                                        }
                                    }
                                }
                            }
                            // Grid fills the card width
                            Item {
                                id: ghGridHost
                                width: parent.width
                                visible: root.github && root.github.ok && (root.github.weeks || []).length
                                height: {
                                    var weeks = (root.github && root.github.weeks) ? root.github.weeks : [];
                                    var n = weeks.length;
                                    if (n <= 0) return 0;
                                    var gap = 2;
                                    var cell = Math.max(5, Math.floor((width - gap * Math.max(0, n - 1)) / n));
                                    return cell * 7 + gap * 6;
                                }
                                Row {
                                    id: ghGridRow
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 2
                                    readonly property int cell: {
                                        var n = (root.github && root.github.weeks) ? root.github.weeks.length : 0;
                                        if (n <= 0) return 8;
                                        return Math.max(5, Math.floor((ghGridHost.width - 2 * Math.max(0, n - 1)) / n));
                                    }
                                    Repeater {
                                        model: (root.github && root.github.weeks) ? root.github.weeks : []
                                        delegate: Column {
                                            required property var modelData
                                            spacing: 2
                                            Repeater {
                                                model: modelData
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    width: ghGridRow.cell; height: ghGridRow.cell; radius: Math.max(1, ghGridRow.cell * 0.2)
                                                    color: {
                                                        var n = Number(modelData.level) || 0;
                                                        if (n <= 0) return theme.a(theme.line, 0.9);
                                                        if (n === 1) return theme.a(theme.iris, 0.28);
                                                        if (n === 2) return theme.a(theme.iris, 0.48);
                                                        if (n === 3) return theme.a(theme.iris, 0.72);
                                                        return theme.iris;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Column {
                                width: parent.width; spacing: 4
                                visible: root.github && (root.github.repos || []).length
                                Text { text: "Watched"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Repeater {
                                    model: (root.github && root.github.repos) ? root.github.repos.slice(0, 4) : []
                                    delegate: Row {
                                        required property var modelData
                                        width: parent.width; spacing: 8
                                        Rectangle {
                                            width: 7; height: 7; radius: 3.5; anchors.verticalCenter: parent.verticalCenter
                                            color: modelData.ci === "ok" ? theme.good : (modelData.ci === "fail" ? theme.bad : (modelData.ci === "running" ? theme.warn : theme.faint))
                                        }
                                        Text {
                                            width: parent.width - 20
                                            text: (modelData.repo || "") + " · " + (modelData.prs || 0) + " PR"
                                            color: theme.text; font.pixelSize: 12; font.family: Tok.sans; elide: Text.ElideMiddle
                                            anchors.verticalCenter: parent.verticalCenter
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: if (modelData.url) Quickshell.execDetached(["xdg-open", modelData.url]) }
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: !(root.github && root.github.ok)
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: (root.github && root.github.error) ? root.github.error : "Sign in with gh auth login"
                                color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; wrapMode: Text.WordWrap
                            }
                            // Focus profiles (scene presets)
                            Column {
                                width: parent.width; spacing: 6
                                Text {
                                    width: parent.width
                                    text: "Focus"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                }
                                Flow {
                                    width: parent.width; spacing: 6
                                    Repeater {
                                        model: {
                                            var p = root.focusProfiles || ({});
                                            var keys = Object.keys(p);
                                            if (keys.indexOf("clear") < 0) keys.push("clear");
                                            return keys;
                                        }
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property var prof: (root.focusProfiles && root.focusProfiles[modelData]) ? root.focusProfiles[modelData] : ({ label: modelData, icon: "circle" })
                                            readonly property bool on: root.focusId === modelData || (modelData === "clear" && !root.focusId)
                                            implicitWidth: focRow.implicitWidth + 14; height: 26; radius: 13
                                            color: on ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.35)
                                            border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.12)
                                            Row {
                                                id: focRow; anchors.centerIn: parent; spacing: 4
                                                Text { text: prof.icon || "circle"; font.family: "Material Symbols Outlined"; font.pixelSize: 13; color: on ? theme.iris : theme.sub; anchors.verticalCenter: parent.verticalCenter }
                                                Text { text: prof.label || modelData; color: on ? theme.text : theme.sub; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                                            }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.applyFocus(modelData) }
                                        }
                                    }
                                }
                            }
                        }
                    } }


                    LazyLoader { activeAsync: (root.openPop === "totem" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: totemDrop; host: root.barVertical ? totemPillVert : totemPill; shown: root.openPop === "totem" && root.openBar === bar
                        cardW: 320; cardH: totemCol.implicitHeight + 28
                        onShownChanged: if (shown) { root.refreshTotemStatus(); root.refreshTotemAccounts(); root.totemQuery = ""; root.totemCode = "" }
                        Column { id: totemCol; anchors.fill: totemDrop.card; anchors.margins: 14; spacing: 10
                            DropHeader {
                                title: "Totem"
                                status: root.totemNotice
                                tone: root.totemStatus && root.totemStatus.paired ? "ok" : "warn"
                                actionIcon: "refresh"
                                actionBusy: root.totemBusy
                                onAction: { root.refreshTotemStatus(); root.refreshTotemAccounts() }
                            }
                            Rectangle {
                                width: parent.width; height: 32; radius: 8
                                color: Tok.alpha(Tok.ink, 0.07); border.width: 1; border.color: Tok.alpha(Tok.iris, 0.2)
                                TextInput {
                                    id: totemSearch
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                    verticalAlignment: Text.AlignVCenter
                                    color: theme.text; font.pixelSize: 12; font.family: Tok.sans
                                    selectionColor: theme.iris; selectedTextColor: Tok.accentInk
                                    onTextChanged: root.totemQuery = text
                                    Keys.onReturnPressed: {
                                        var list = root.totemFiltered;
                                        if (list.length === 1 && list[0].policy !== "never") root.fetchTotemCode(list[0].id);
                                    }
                                    Text {
                                        anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                        visible: !totemSearch.text && !totemSearch.activeFocus
                                        text: "Search accounts…"
                                        color: theme.faint; font.pixelSize: 12; font.family: Tok.sans
                                    }
                                }
                            }
                            // Scroll when there are many accounts — card height follows this
                            // Flickable's viewport, not the full list, so rows never paint outside.
                            Flickable {
                                id: totemFlick
                                width: parent.width
                                visible: root.totemFiltered.length > 0
                                height: Math.min(300, totemListCol.implicitHeight)
                                contentHeight: totemListCol.implicitHeight
                                contentWidth: width
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                flickableDirection: Flickable.VerticalFlick
                                Column {
                                    id: totemListCol
                                    width: totemFlick.width; spacing: 4
                                    Repeater {
                                        model: root.totemFiltered.slice(0, 24)
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: totemListCol.width
                                            height: (modelData.subtitle || modelData.label) ? 44 : 36
                                            radius: 8
                                            color: rowMa.containsMouse ? Tok.alpha(Tok.ink, 0.07) : "transparent"
                                            opacity: modelData.policy === "never" ? 0.55 : 1
                                            Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                            MouseArea {
                                                id: rowMa; anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (modelData.policy === "never") { root.totemNotice = "Phone-only account"; return }
                                                    root.fetchTotemCode(modelData.id)
                                                }
                                            }
                                            TotemBrand {
                                                id: brand
                                                anchors.left: parent.left; anchors.leftMargin: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                logo: modelData.logo || null
                                                fallback: (modelData.title || "?").charAt(0)
                                            }
                                            Column {
                                                anchors.left: brand.right; anchors.leftMargin: 10
                                                anchors.right: chipBox.visible ? chipBox.left : parent.right
                                                anchors.rightMargin: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 1
                                                Text {
                                                    width: parent.width; elide: Text.ElideRight
                                                    text: modelData.title || modelData.issuer || "Account"
                                                    color: Tok.ink2; font.family: Tok.sans; font.pixelSize: 12
                                                }
                                                Text {
                                                    visible: !!(modelData.subtitle || modelData.label)
                                                    width: parent.width; elide: Text.ElideRight
                                                    text: modelData.subtitle || modelData.label || ""
                                                    color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 10
                                                }
                                            }
                                            IndChip {
                                                id: chipBox
                                                anchors.right: parent.right; anchors.rightMargin: 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: modelData.policy === "ask" || modelData.policy === "never"
                                                text: modelData.policy === "ask" ? "ASK" : "PHONE"
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: !root.totemBusy && root.totemFiltered.length === 0
                                width: parent.width; wrapMode: Text.WordWrap
                                text: root.totemStatus && root.totemStatus.missing
                                    ? "Build the CLI: cargo build -p totem-cli --release"
                                    : (root.totemStatus && root.totemStatus.paired ? "No matching accounts." : "Pair a phone in the Totem app.")
                                color: theme.sub; font.pixelSize: 12; font.family: Tok.sans
                            }
                            Rectangle {
                                visible: root.totemCode !== ""
                                width: parent.width; height: 44; radius: 10
                                color: Tok.alpha(theme.iris, 0.18); border.width: 1; border.color: theme.iris
                                Row {
                                    anchors.centerIn: parent; spacing: 10
                                    Text {
                                        text: root.totemCode.length === 6
                                            ? (root.totemCode.slice(0, 3) + " " + root.totemCode.slice(3))
                                            : root.totemCode
                                        color: theme.text; font.pixelSize: 22; font.family: Tok.sans; font.bold: true
                                        font.features: { "tnum": 1 }
                                    }
                                    Text {
                                        visible: root.totemCodeLeft > 0
                                        text: root.totemCodeLeft + "s"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }
                            Row {
                                spacing: 8
                                Rectangle {
                                    height: 28; radius: 8; width: openLbl.implicitWidth + 16
                                    color: Tok.alpha(Tok.ink, 0.08)
                                    Text { id: openLbl; anchors.centerIn: parent; text: "Open Totem"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openTotemApp() }
                                }
                            }
                        }
                    } }
                    LazyLoader { activeAsync: (root.openPop === "ai" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: aiDrop; host: root.barVertical ? aiPillVert : aiPill; shown: root.openPop === "ai" && root.openBar === bar
                        // Grow with the plan chips so a third account does not clip off the card edge.
                        cardW: Math.max(320, Math.ceil(aiTabs.implicitWidth) + 28)
                        cardH: aiCol.implicitHeight + 28
                        Column { id: aiCol; anchors.fill: aiDrop.card; anchors.margins: 14; spacing: 12
                            Row {
                                id: aiTabs
                                spacing: 6
                                Repeater {
                                    model: Math.min(4, root.aiTools.length)
                                    delegate: Rectangle {
                                        required property int index
                                        readonly property var plan: root.aiTools[index]
                                        readonly property bool on: root.aiShown && plan.id === root.aiShown.id
                                        implicitWidth: aiChip.implicitWidth + 16
                                        height: 28
                                        radius: 14
                                        color: on ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.35)
                                        border.width: 1
                                        border.color: on ? theme.iris : theme.a(theme.iris, 0.12)
                                        Row {
                                            id: aiChip
                                            anchors.centerIn: parent; spacing: 5
                                            AiMark {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: plan.with ? 22 : 14; height: 14
                                                tool: plan.id; also: plan.with || ""
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: plan.name || ""
                                                color: on ? theme.text : theme.sub
                                                font.pixelSize: 11; font.family: Tok.sans
                                                font.bold: on
                                            }
                                            Rectangle {
                                                visible: root.aiIsLive(plan.id)
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 7; height: 7; radius: 3.5
                                                color: "#1b7a4b"
                                                border.width: 1; border.color: Tok.bg
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.setAiFocus(plan.id)
                                        }
                                    }
                                }
                            }
                            Column {
                                width: parent.width; spacing: 10
                                visible: aiMeters.count > 0
                                Repeater {
                                    id: aiMeters
                                    model: (root.aiShown && root.aiShown.windows) ? root.aiShown.windows : []
                                    delegate: Column {
                                        required property var modelData
                                        width: aiCol.width - 28
                                        spacing: 3
                                        Item {
                                            width: parent.width; height: 16
                                            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.label || ""; color: theme.text; font.pixelSize: 12; font.family: Tok.sans }
                                            Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                                text: root.aiPct(modelData.used)
                                                color: (Number(modelData.used) || 0) >= 95 ? theme.bad
                                                    : ((Number(modelData.used) || 0) >= 80 ? theme.warn : theme.text)
                                                font.pixelSize: 12; font.family: Tok.sans; font.bold: true }
                                        }
                                        Rectangle {
                                            width: parent.width; height: 6; radius: 3
                                            color: theme.a(theme.line, 0.9)
                                            Rectangle {
                                                width: parent.width * Math.max(0, Math.min(1, (Number(modelData.used) || 0) / 100))
                                                height: parent.height; radius: 3
                                                color: (Number(modelData.used) || 0) >= 95 ? theme.bad
                                                    : ((Number(modelData.used) || 0) >= 80 ? theme.warn : theme.iris)
                                            }
                                        }
                                        Text {
                                            width: parent.width
                                            text: modelData.reset || ""
                                            color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: (modelData.pace || "").length > 0
                                            width: parent.width
                                            text: modelData.pace || ""
                                            color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                            }
                            Column {
                                width: parent.width; spacing: 6
                                visible: aiDays.count > 1
                                Text { text: "This week"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Row {
                                    width: parent.width
                                    Repeater {
                                        id: aiDays
                                        model: (root.aiShown && root.aiShown.days) ? root.aiShown.days : []
                                        delegate: Column {
                                            required property var modelData
                                            width: aiDays.count > 0 ? parent.width / aiDays.count : 0
                                            spacing: 3
                                            readonly property real share: {
                                                var peak = 0;
                                                var days = (root.aiShown && root.aiShown.days) ? root.aiShown.days : [];
                                                for (var i = 0; i < days.length; i++)
                                                    peak = Math.max(peak, Number(days[i].used) || 0);
                                                var used = Number(modelData.used) || 0;
                                                return peak > 0 ? used / peak : 0;
                                            }
                                            Text {
                                                width: parent.width
                                                horizontalAlignment: Text.AlignHCenter
                                                text: (Number(modelData.used) || 0) > 0 ? root.aiPct(modelData.used) : ""
                                                color: modelData.today ? theme.text : theme.sub
                                                font.pixelSize: 9; font.family: Tok.sans
                                                elide: Text.ElideRight
                                            }
                                            Item {
                                                width: parent.width; height: 36
                                                Rectangle {
                                                    anchors.bottom: parent.bottom
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    width: 10; radius: 2
                                                    height: Math.max(2, 36 * share)
                                                    color: modelData.today ? theme.iris : theme.a(theme.iris, 0.45)
                                                }
                                            }
                                            Text {
                                                width: parent.width
                                                horizontalAlignment: Text.AlignHCenter
                                                text: modelData.label || ""
                                                color: modelData.today ? theme.text : theme.sub
                                                font.pixelSize: 10; font.family: Tok.sans
                                                font.bold: !!modelData.today
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: aiMeters.count === 0
                                width: parent.width
                                text: {
                                    var all = (root.aiUsage && root.aiUsage.tools) ? root.aiUsage.tools : [];
                                    if (root.aiShown)
                                        return "Checking this plan.";
                                    if (all.length === 0)
                                        return "Sign in to Cursor, GPT, Claude or Antigravity.";
                                    if (root.aiTools.length === 0)
                                        return "No plans enabled — turn one on in Settings.";
                                    return "Checking plan usage.";
                                }
                                color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                            }
                        }
                    } }

                    LazyLoader { activeAsync: (root.openPop === "upd" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: updDrop; host: root.barVertical ? updPillVert : updPill; shown: root.openPop === "upd" && root.openBar === bar
                        cardW: 340; cardH: updCol.implicitHeight + 30
                        Column { id: updCol; anchors.fill: updDrop.card; anchors.margins: 15; spacing: 10
                            Row { width: parent.width
                                Text { text: "Updates"; color: theme.text; font.pixelSize: 15; font.family: Tok.sans; font.bold: true }
                                Item { width: parent.width - 120; height: 1 }
                                Text { text: root.updChecking ? "checking…" : (root.updRepo + " repo · " + root.updAur + " aur")
                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.mono } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.16) }

                            Text { visible: root.updTotal === 0 && !root.updChecking
                                text: "Everything is up to date"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }

                            // Capped, but the footer says by how much — a list that silently stops
                            // at 12 reads as "12 updates" when it might be 90.
                            Column { width: parent.width; spacing: 5
                                Repeater {
                                    model: Math.min(12, root.updList.length)
                                    delegate: Row {
                                        required property int index
                                        readonly property var u: root.updList[index]
                                        width: updCol.width; spacing: 7
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 15; height: 13; radius: Tok.rSmall
                                            color: u.src === "A" ? theme.a(theme.warn, 0.22) : theme.a(theme.iris, 0.18)
                                            border.width: 1; border.color: u.src === "A" ? theme.a(theme.warn, 0.5) : theme.a(theme.iris, 0.35)
                                            Text { anchors.centerIn: parent; text: u.src; font.pixelSize: 8; font.family: Tok.mono
                                                color: u.src === "A" ? theme.warn : theme.iris } }
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            width: 150; elide: Text.ElideRight
                                            text: u.name; color: theme.text; font.pixelSize: 11; font.family: Tok.mono }
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            width: 130; elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                                            text: u.nw; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono }
                                    }
                                }
                            }
                            Text { visible: root.updList.length > 12
                                text: "+" + (root.updList.length - 12) + " more not shown"
                                color: theme.sub; font.pixelSize: 11; font.family: Tok.mono }

                            Row { width: parent.width; spacing: 8
                                Rectangle { width: (parent.width - 8) * 0.62; height: 34; radius: Tok.r
                                    color: updGoMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22)
                                    border.width: 1; border.color: theme.iris
                                    opacity: root.updTotal > 0 ? 1 : 0.45
                                    Row { anchors.centerIn: parent; spacing: 7
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "download"; sz: 15
                                            color: updGoMa.containsMouse ? Tok.accentInk : theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Update now"
                                            color: updGoMa.containsMouse ? Tok.accentInk : theme.text; font.pixelSize: 12; font.family: Tok.sans } }
                                    MouseArea { id: updGoMa; anchors.fill: parent; hoverEnabled: true
                                        enabled: root.updTotal > 0
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.updRun() } }
                                Rectangle { width: (parent.width - 8) * 0.38; height: 34; radius: Tok.r
                                    color: updReMa.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4)
                                    border.width: 0; border.color: theme.a(theme.iris, 0.16)
                                    Row { anchors.centerIn: parent; spacing: 6
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "refresh"; sz: 15; color: theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Check"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
                                    MouseArea { id: updReMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.updRefresh() } }
                            }
                        }
                    }
                    }

                    // ---- CONTROL CENTER dropdown (modularized into ControlCenterDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop === "cc" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: ccDrop; host: root.barVertical ? ccPillVert : ccPill; shown: root.openPop === "cc" && root.openBar === bar
                        cardW: 326; cardH: ccCol.implicitHeight + 28
                        ControlCenterDrop {
                            id: ccCol
                            anchors { left: ccDrop.card.left; right: ccDrop.card.right; top: ccDrop.card.top; margins: 14 }
                            shellRoot: root
                            audioSink: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
                        }
                    }
                    }
                    // ---- WEATHER dropdown (modularized into WeatherDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="wx" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: wxDrop; host: root.barVertical ? wxPillVert : wxPill; shown: root.openPop ==="wx" && root.openBar === bar
                        cardW: 256; cardH: wxCol.implicitHeight + 28
                        WeatherDrop {
                            id: wxCol
                            anchors { left: wxDrop.card.left; right: wxDrop.card.right; top: wxDrop.card.top; margins: 14 }
                            shellRoot: root
                        }
                    }
                    }
                    LazyLoader { activeAsync: (root.openPop ==="tray" && root.openBar === bar && bar.trayHost !== null && bar.trayMenuSel !== null) || !!(item && item.visible); Drop { screen: bar.screen
                        id: trayDrop; host: bar.trayHost
                        shown: root.openPop ==="tray" && root.openBar === bar && bar.trayHost !== null && bar.trayMenuSel !== null
                        cardW: 230; cardH: Math.max(30, tmCol.implicitHeight + 12)
                        QsMenuOpener { id: trayMenu; menu: { try { return (bar.trayMenuSel && bar.trayMenuSel.menu) ? bar.trayMenuSel.menu : null } catch(e) { return null } } }
                        Column { id: tmCol; anchors.fill: trayDrop.card; anchors.margins: 6; spacing: 1
                            Text {
                                // A block-bodied binding cannot be followed by `;` on the same line —
                                // QML parses that as a stray statement ("Unexpected token ;") and the
                                // WHOLE config fails to load. Keep the block on its own lines.
                                visible: {
                                    try { return !trayMenu.children || !trayMenu.children.values || trayMenu.children.values.length === 0 }
                                    catch (e) { return true }
                                }
                                text: "No menu"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; leftPadding: 6; topPadding: 4
                            }
                            Repeater { model: { try { return trayMenu.children ? trayMenu.children : [] } catch(e) { return [] } }
                                delegate: Rectangle { required property var modelData
                                    width: parent.width; height: (modelData && modelData.isSeparator) ? 7 : 28; radius: Tok.r
                                    color: (modelData && !modelData.isSeparator && em.containsMouse) ? theme.a(theme.iris,0.16) : "transparent"
                                    Rectangle { visible: !!(modelData && modelData.isSeparator); anchors.verticalCenter: parent.verticalCenter; x: 5; width: parent.width-10; height: 1; color: theme.a(theme.line,0.8) }
                                    Row { visible: !!(modelData && !modelData.isSeparator); anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; spacing: 8
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: (modelData && modelData.text) ? modelData.text : ""; color: (modelData && modelData.enabled)?theme.text:theme.faint; font.pixelSize: 12; font.family: Tok.sans; elide: Text.ElideRight; width: parent.width-22 }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: !!(modelData && modelData.hasChildren); text: "chevron_right"; sz: 14; color: theme.sub } }
                                    MouseArea { id: em; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !!(modelData && !modelData.isSeparator)
                                        onClicked: { try { if(modelData && !modelData.hasChildren){ modelData.triggered(); root.openPop="" } } catch(e) { root.openPop=""; } } } } } } }
                    }
                    // ---- NOTIFICATION CENTRE dropdown (modularized into NotifDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="notif" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: notifDrop; host: root.barVertical ? bellPillVert : bellPill; shown: root.openPop ==="notif" && root.openBar === bar
                        cardW: 364; cardH: Math.min(500, notifCol.implicitHeight + 28)
                        WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
                        NotifDrop {
                            id: notifCol
                            anchors { left: notifDrop.card.left; right: notifDrop.card.right; top: notifDrop.card.top; margins: 14 }
                            shellRoot: root
                            shown: notifDrop.shown
                        }
                    }
                    }
                    // ---- WI-FI, QR SHARE & VPN dropdown (modularized into WifiDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="wifi" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: wifiDrop; host: root.barVertical ? wifiPillVert : wifiPill; shown: root.openPop ==="wifi" && root.openBar === bar
                        cardW: 320; cardH: wifiCol.implicitHeight + 24
                        WifiDrop {
                            id: wifiCol
                            anchors { left: wifiDrop.card.left; right: wifiDrop.card.right; top: wifiDrop.card.top; margins: 12 }
                            shellRoot: root
                            shown: wifiDrop.shown
                        }
                    }
                    }
                    // ---- BLUETOOTH dropdown (modularized into BluetoothDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="bt" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: btDrop; host: root.barVertical ? btPillVert : btPill; shown: root.openPop ==="bt" && root.openBar === bar
                        cardW: 320; cardH: btCol.implicitHeight + 24
                        BluetoothDrop {
                            id: btCol
                            anchors { left: btDrop.card.left; right: btDrop.card.right; top: btDrop.card.top; margins: 12 }
                            shellRoot: root
                        }
                    }
                    }
                    // KDE Connect: the phone's state, then the things you actually open the
                    // widget for — ring, send a file, push the clipboard, browse its storage.
                    // The settings tab is one gear away rather than the only destination.
                    LazyLoader { activeAsync: (root.openPop ==="kde" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: kdeDrop; host: root.barVertical ? kdePillVert : kdePill; shown: root.openPop ==="kde" && root.openBar === bar
                        cardW: 300; cardH: kdeCol.implicitHeight + 28
                        Column { id: kdeCol; anchors.fill: kdeDrop.card; anchors.margins: 14; spacing: 8
                            readonly property var dev: root.kdeDev
                            // Header
                            Item { width: parent.width; height: 26
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "KDE Connect"; color: theme.text; font.pixelSize: 15; font.family: Tok.sans; font.bold: true }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 2
                                    Rectangle { width: 26; height: 26; radius: Tok.r
                                        color: kdeRfMa.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                        Sym { anchors.centerIn: parent; text: "refresh"; sz: 15; color: theme.sub }
                                        MouseArea { id: kdeRfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { kdeWatch.running = false; kdeWatch.running = true } } }
                                    Rectangle { width: 26; height: 26; radius: Tok.r
                                        color: kdeSetMa.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                        Sym { anchors.centerIn: parent; text: "settings"; sz: 15; color: theme.sub }
                                        MouseArea { id: kdeSetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.openPop = ""; root.openSettings(14) } } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            // Device switcher — only worth the room once there IS a choice
                            Flow { width: parent.width; spacing: 5; visible: root.kdeDevices.length > 1
                                Repeater { model: root.kdeDevices
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool sel: kdeCol.dev && kdeCol.dev.id === modelData.id
                                        height: 22; radius: Tok.r; width: chipTxt.width + 26
                                        color: sel ? theme.a(theme.iris,0.24) : (chipMa.containsMouse ? theme.a(theme.line,0.6) : theme.a(theme.line,0.32))
                                        border.width: 1; border.color: sel ? theme.a(theme.iris,0.5) : "transparent"
                                        Row { anchors.centerIn: parent; spacing: 5
                                            Rectangle { width: 6; height: 6; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                                                color: !modelData.isReachable ? theme.a(theme.faint,0.55) : (modelData.isPaired ? theme.good : theme.warn) }
                                            // capped so one long hostname can't push the switcher to three rows
                                            Text { id: chipTxt; anchors.verticalCenter: parent.verticalCenter; text: modelData.name
                                                width: Math.min(implicitWidth, 104); elide: Text.ElideRight
                                                color: sel ? theme.text : theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
                                        MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.kdeSel = modelData.id } } } }
                            // The device itself
                            Rectangle { width: parent.width; radius: Tok.r; visible: kdeCol.dev !== null
                                implicitHeight: devCol.implicitHeight + 20
                                color: theme.a(theme.line, 0.32); border.width: 0
                                border.color: root.kdeActive ? theme.a(theme.iris,0.35) : theme.a(theme.iris,0.12)
                                Column { id: devCol; anchors.left: parent.left; anchors.right: parent.right
                                    anchors.top: parent.top; anchors.margins: 10; spacing: 9
                                    Row { width: parent.width; spacing: 9
                                        Rectangle { width: 34; height: 34; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                                            color: root.kdeActive ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.5)
                                            Sym { anchors.centerIn: parent; sz: 19; text: root.kdeIcon(kdeCol.dev)
                                                color: root.kdeActive ? theme.iris : theme.faint } }
                                        Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 43; spacing: 2
                                            Text { width: parent.width; elide: Text.ElideRight; text: kdeCol.dev ? kdeCol.dev.name : ""
                                                color: theme.text; font.pixelSize: 13; font.family: Tok.sans; font.bold: true }
                                            Row { spacing: 6
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.kdeStatus(kdeCol.dev)
                                                    color: root.kdeActive ? theme.frost : theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                                                // cellular strength, 0–4 bars
                                                Row { anchors.verticalCenter: parent.verticalCenter; spacing: 2; height: 11
                                                    visible: kdeCol.dev && kdeCol.dev.signal >= 0
                                                    Repeater { model: 4
                                                        delegate: Rectangle { required property int index
                                                            width: 3; height: 4 + index*2; radius: 1; anchors.bottom: parent.bottom
                                                            color: (kdeCol.dev && index < kdeCol.dev.signal) ? theme.frost : theme.a(theme.faint,0.35) } } } } } }
                                    StatBar { width: parent.width; label: "Battery"
                                        visible: kdeCol.dev && kdeCol.dev.charge >= 0
                                        value: kdeCol.dev ? kdeCol.dev.charge : 0
                                        barColor: !kdeCol.dev ? theme.iris : (kdeCol.dev.isCharging ? theme.good : (kdeCol.dev.charge <= 20 ? theme.bad : theme.iris))
                                        rightText: kdeCol.dev ? (kdeCol.dev.charge + "%" + (kdeCol.dev.isCharging ? "  ·  charging" : "")) : "" } } }
                            // Shortcuts — greyed out when the phone hasn't loaded that plugin
                            Grid { id: kdeActs; width: parent.width; columns: 2; columnSpacing: 8; rowSpacing: 8
                                visible: root.kdeActive
                                readonly property real cw: (width - columnSpacing) / 2
                                KdeAct { width: kdeActs.cw; icon: "ring_volume"; label: "Ring"; tint: theme.warn
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canRing
                                    onAct: root.kdeRun(["--ring", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "wifi_tethering"; label: "Ping"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canPing
                                    onAct: root.kdeRun(["--ping", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "upload_file"; label: "send file"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canShare
                                    onAct: { root.openPop = ""; root.kdeRun(["--send-file", kdeCol.dev.id]) } }
                                KdeAct { width: kdeActs.cw; icon: "content_paste_go"; label: "Clipboard"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canShare
                                    onAct: root.kdeRun(["--send-clipboard", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "folder_open"; label: "Browse files"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canBrowse
                                    onAct: { root.openPop = ""; root.kdeRun(["--browse", kdeCol.dev.id]) } }
                                KdeAct { width: kdeActs.cw; icon: "sms"; label: "Messages"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canSms
                                    onAct: { root.openPop = ""; root.kdeRun(["--sms", kdeCol.dev.id]) } } }
                            // Pairing — the only thing that matters until the handshake is done
                            Column { width: parent.width; spacing: 6
                                visible: kdeCol.dev !== null && !kdeCol.dev.isPaired
                                Text { width: parent.width; wrapMode: Text.WordWrap
                                    visible: kdeCol.dev && (kdeCol.dev.isPairRequestedByPeer || kdeCol.dev.isPairRequested)
                                    text: "check that your device shows the key " + (kdeCol.dev ? kdeCol.dev.verificationKey : "")
                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Row { width: parent.width; spacing: 8
                                    visible: kdeCol.dev && kdeCol.dev.isPairRequestedByPeer
                                    KdeAct { width: (kdeCol.width - 8)/2; icon: "check_circle"; label: "Accept"; tint: theme.good
                                        onAct: root.kdeRun(["--accept", kdeCol.dev.id]) }
                                    KdeAct { width: (kdeCol.width - 8)/2; icon: "cancel"; label: "Reject"; tint: theme.bad
                                        onAct: root.kdeRun(["--reject", kdeCol.dev.id]) } }
                                KdeAct { width: parent.width; icon: "link"; label: "Pair with this device"; tint: theme.iris
                                    visible: kdeCol.dev && kdeCol.dev.isReachable && !kdeCol.dev.isPairRequested && !kdeCol.dev.isPairRequestedByPeer
                                    onAct: root.kdeRun(["--pair", kdeCol.dev.id]) }
                                Text { visible: kdeCol.dev && !kdeCol.dev.isReachable
                                    text: "Not on this network — open the app on the device"
                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
                            // Unpair sits at the bottom, small and out of the way of the shortcuts
                            Item { width: parent.width; height: 16; visible: kdeCol.dev !== null && kdeCol.dev.isPaired
                                Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    text: "Unpair"; color: unpMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.8)
                                    font.pixelSize: 11; font.family: Tok.sans
                                    MouseArea { id: unpMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.kdeRun(["--unpair", kdeCol.dev.id]) } } }
                            // Nothing at all — usually the daemon just hasn't seen the phone yet
                            Column { width: parent.width; spacing: 3; visible: root.kdeDevices.length === 0
                                Text { text: "No devices"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }
                                Text { width: parent.width; wrapMode: Text.WordWrap
                                    text: "open KDE Connect on your phone, make sure it's on the same network, then hit refresh"
                                    color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } } } }
                    }
                    LazyLoader { activeAsync: (root.openPop ==="sys" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: sysDrop; host: root.barVertical ? sysPillVert : sysPill; shown: root.openPop ==="sys" && root.openBar === bar
                        cardW: 250; cardH: sysCol.implicitHeight + 28
                        Column { id: sysCol; anchors.fill: sysDrop.card; anchors.margins: 14; spacing: 10
                            // Header
                            Item { width: parent.width; height: 20
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "System"; color: theme.text; font.pixelSize: 15; font.family: Tok.sans; font.bold: true }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 4
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "developer_board"; sz: 13; color: theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Live"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } } }
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
                                        text: "GPU"; color: theme.frost; font.pixelSize: 11; font.family: Tok.sans; font.bold: true; font.letterSpacing: 0.6 }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 40; elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                                        text: root.gpuName; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
                                StatBar { width: parent.width; label: "Usage"
                                    value: root.gpuUsage; barColor: root.loadColor(root.gpuUsage, 70, 90)
                                    rightText: Math.round(root.gpuUsage)+"%  ·  "+Math.round(root.gpuTemp)+"°C" }
                                StatBar { width: parent.width; label: "VRAM"; barColor: theme.frost
                                    value: root.gpuMemTotal>0 ? root.gpuMemUsed/root.gpuMemTotal*100 : 0
                                    rightText: root.gpuMemUsed.toFixed(1)+" / "+root.gpuMemTotal.toFixed(1)+" GB" }
                                Item { width: parent.width; height: 15
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: "Power draw"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        text: root.gpuPower.toFixed(1)+" W"; color: theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } } } } }
                    }
                    // ---- SOUND & PER-APP MIXER dropdown (modularized into AudioDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="vol" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: volDrop; host: root.barVertical ? volPillVert : volPill; shown: root.openPop ==="vol" && root.openBar === bar
                        cardW: 332; cardH: volCol.implicitHeight + 24
                        AudioDrop {
                            id: volCol
                            anchors { left: volDrop.card.left; right: volDrop.card.right; top: volDrop.card.top; margins: 12 }
                            shellRoot: root
                            audioSink: volPill.au
                            volPct: volPill.vol
                        }
                    }
                    }
                    // ---- BATTERY & HYBRID dGPU dropdown (modularized into BatteryDrop.qml) ----
                    LazyLoader { activeAsync: (root.openPop ==="bat" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: batDrop; host: root.barVertical ? batPillVert : batPill; shown: root.openPop ==="bat" && root.openBar === bar
                        cardW: 296; cardH: batCol.implicitHeight + 24
                        BatteryDrop {
                            id: batCol
                            anchors { left: batDrop.card.left; right: batDrop.card.right; top: batDrop.card.top; margins: 12 }
                            shellRoot: root
                            charging: batPill.charging
                            pct: batPill.pct
                            active: batDrop.visible
                        }
                        onVisibleChanged: if (visible && !batHealthProc.running) batHealthProc.running = true
                    }
                    }
                    LazyLoader { activeAsync: (root.openPop ==="cal" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: calDrop; host: root.barVertical ? clockPillVert : clockPill; shown: root.openPop ==="cal" && root.openBar === bar
                        cardW: 280; cardH: calCol.implicitHeight + 32
                        onVisibleChanged: { if (visible) reloadEventsProc.running = true }
                        Column { id: calCol; anchors.fill: calDrop.card; anchors.margins: 14; spacing: 10
                            property var dt: clock.date
                            property int yr: dt.getFullYear()
                            property int mo: dt.getMonth()
                            property int today: dt.getDate()
                            property int lead: new Date(yr, mo, 1).getDay()
                            property var days: { var arr=[]; var n=new Date(yr, mo+1, 0).getDate(); for(var i=1;i<=n;i++) arr.push(i); return arr }
                            // today, and what is next, in the same header the other dropdowns use
                            DropHeader {
                                title: Qt.formatDate(clock.date, "dddd, d MMMM")
                                status: root.calUpcoming.length === 0 ? "Nothing coming up"
                                      : "Next: " + (root.calUpcoming[0].title || "event") + " · " + root.calRel(root.calUpcoming[0].date)
                                tone: root.calUpcoming.length && root.calRel(root.calUpcoming[0].date) === "today" ? "accent" : "neutral"
                                value: Qt.formatTime(clock.date, "HH:mm")
                            }
                            // The month keeps its own title row rather than a CalHead: it is the panel's
                            // identity, not a section label, so it stays centred and full size and only
                            // borrows the chevron.
                            Item { width: parent.width; height: 20
                                Text { anchors.centerIn: parent; text: Qt.formatDateTime(clock.date,"MMMM yyyy"); color: theme.frost; font.pixelSize: 14; font.family: Tok.sans; font.bold: true }
                                Sym { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    text: root.calFolded("cal") ? "expand_more" : "expand_less"; sz: 13
                                    color: mgm.containsMouse ? theme.iris : theme.faint }
                                MouseArea { id: mgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.calToggleFold("cal") } }
                            Column { width: parent.width; spacing: 10; visible: !root.calFolded("cal")
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
                                color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                            Grid { anchors.horizontalCenter: parent.horizontalCenter; columns: 7; spacing: 4
                                Repeater { model: ["S","M","T","W","T","F","S"]
                                    delegate: Text { required property var modelData; width: 34; horizontalAlignment: Text.AlignHCenter; text: modelData; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
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
                                        width: 34; height: 26; radius: Tok.r
                                        color: isToday ? theme.iris : (hasEvent ? theme.a(theme.iris, 0.13) : "transparent")
                                        border.width: (hasEvent && !isToday) ? 1 : 0; border.color: theme.a(theme.frost, 0.4)
                                        Text { anchors.centerIn: parent; text: parent.modelData; color: parent.isToday ? theme.bg : theme.text; font.pixelSize: 12; font.family: Tok.sans; font.bold: parent.isToday }
                                        Rectangle {
                                            visible: parent.hasEvent && !parent.isToday
                                            width: 3; height: 3; radius: 1.5; color: theme.frost
                                            anchors.bottom: parent.bottom; anchors.bottomMargin: 3; anchors.horizontalCenter: parent.horizontalCenter } } } }
                            }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column {
                                width: parent.width; spacing: 5
                                CalHead { skey: "up"; title: "Upcoming"
                                    summary: root.calUpcoming.length === 0 ? "None"
                                           : root.calUpcoming.length + (root.calUpcoming.length > 4 ? " · +" + (root.calUpcoming.length - 4) + " more" : "") }
                                Column { width: parent.width; spacing: 5; visible: !root.calFolded("up")
                                Repeater {
                                    model: root.calUpcoming.slice(0, 4)
                                    delegate: Rectangle {
                                        id: evRow
                                        required property var modelData
                                        readonly property string rel: root.calRel(modelData.date)
                                        readonly property bool soon: evRow.rel === "today" || evRow.rel === "tomorrow"
                                        width: parent.width; height: 34; radius: Tok.r
                                        color: evRow.soon ? theme.a(theme.iris, 0.12) : "transparent"
                                        Row {
                                            anchors.fill: parent; anchors.leftMargin: 7; anchors.rightMargin: 8; spacing: 9
                                            Column { anchors.verticalCenter: parent.verticalCenter; width: 26
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: (""+evRow.modelData.date).slice(8)
                                                    color: evRow.soon ? theme.frost : theme.iris; font.pixelSize: 15; font.family: Tok.sans; font.bold: true }
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.calDate(evRow.modelData.date), "MMM").toUpperCase()
                                                    color: theme.sub; font.pixelSize: 8; font.family: Tok.sans } }
                                            Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 44; spacing: 1
                                                Text { width: parent.width; text: evRow.modelData.title; color: theme.text; font.pixelSize: 11; font.family: Tok.sans; elide: Text.ElideRight }
                                                Text { text: evRow.rel + "  ·  " + Qt.formatDate(root.calDate(evRow.modelData.date), "ddd") + (evRow.modelData.time ? "  ·  " + evRow.modelData.time : "")
                                                    color: evRow.soon ? theme.frost : theme.faint; font.pixelSize: 11; font.family: Tok.sans } } } } } }

                            }
                            // ================= TIMER · POMODORO =================
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column { width: parent.width; spacing: 6
                                // A running countdown is the one thing that must survive folding: the
                                // section is exactly where you look to find out how long is left.
                                CalHead { skey: "tmr"; title: root.pomoActive ? "Pomodoro" : "Timer"
                                    summary: root.tmrRunning ? root.tmrText
                                           : (root.pomoActive ? "session " + (root.pomoDone + (root.pomoPhase==="focus"?1:0)) : "off") }
                                Column { width: parent.width; spacing: 6; visible: !root.calFolded("tmr")

                                // ---- active countdown ----
                                Column { width: parent.width; spacing: 6; visible: root.tmrRunning
                                    Row { width: parent.width; spacing: 10
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.tmrText; color: root.tmrPaused?theme.warn:theme.frost; font.pixelSize: 30; font.family: Tok.sans; font.bold: true }
                                        Column { anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                            Text { text: root.pomoActive ? (root.pomoPhase==="focus"?"Focus":(root.pomoPhase==="long"?"Long break":"Break")) : "Timer"
                                                color: (root.pomoActive && root.pomoPhase!=="focus") ? theme.good : theme.iris; font.pixelSize: 12; font.family: Tok.sans; font.bold: true }
                                            Text { visible: root.tmrPaused; text: "Paused"; color: theme.warn; font.pixelSize: 11; font.family: Tok.sans } } }
                                    Rectangle { width: parent.width; height: 5; radius: 2.5; color: theme.a(theme.line,0.7)
                                        Rectangle { height: parent.height; radius: 2.5
                                            width: parent.width * (root.tmrTotal>0 ? Math.max(0,Math.min(1, 1 - root.tmrRemain/root.tmrTotal)) : 0)
                                            color: (root.pomoActive && root.pomoPhase!=="focus") ? theme.good : theme.iris; Behavior on width { NumberAnimation { duration: 300 } } } }
                                    Row { width: parent.width; spacing: 6
                                        Rectangle { width: (parent.width - (root.pomoActive?12:6))/(root.pomoActive?3:2); height: 30; radius: Tok.r
                                            color: tpMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"play_arrow":"pause"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"Resume":"Pause"; color: theme.text; font.pixelSize: 11; font.family: Tok.sans } }
                                            MouseArea { id: tpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrToggle() } }
                                        Rectangle { visible: root.pomoActive; width: (parent.width - 12)/3; height: 30; radius: Tok.r
                                            color: tsMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "skip_next"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Skip"; color: theme.text; font.pixelSize: 11; font.family: Tok.sans } }
                                            MouseArea { id: tsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoSkip() } }
                                        Rectangle { width: root.pomoActive ? (parent.width-12)/3 : (parent.width-6)/2; height: 30; radius: Tok.r
                                            color: txMa.containsMouse ? theme.a(theme.bad,0.22) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.bad,0.25)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "stop"; sz: 14; color: theme.bad }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Stop"; color: theme.text; font.pixelSize: 11; font.family: Tok.sans } }
                                            MouseArea { id: txMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrStop() } } } }

                                // ---- idle: quick timers + pomodoro ----
                                Column { width: parent.width; spacing: 6; visible: !root.tmrRunning
                                    Flow { width: parent.width; spacing: 5
                                        Repeater { model: [1,5,10,15,25]
                                            delegate: Rectangle { required property var modelData; height: 28; radius: Tok.r; width: (parent.width - 4*5)/5
                                                color: qcMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.16)
                                                Text { anchors.centerIn: parent; text: modelData+"m"; color: theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                                                MouseArea { id: qcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.timerStartMin(modelData) } } } }
                                    Rectangle { width: parent.width; height: 34; radius: Tok.r
                                        color: psMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22); border.width:1; border.color: theme.iris
                                        Row { anchors.centerIn: parent; spacing: 7
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "local_fire_department"; sz: 16; color: psMa.containsMouse?theme.bg:theme.frost }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Start Pomodoro · " + root.pomoFocusMin + "/" + root.pomoBreakMin; color: psMa.containsMouse?theme.bg:theme.frost; font.pixelSize: 12; font.family: Tok.sans; font.bold: true } }
                                        MouseArea { id: psMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoStart() } }
                                    // compact config: focus / break steppers + DND toggle
                                    Row { width: parent.width; spacing: 8
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Focus"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: fmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: fmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.max(5, root.pomoFocusMin-5); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoFocusMin; color: theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: fpMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "add"; sz: 12; color: theme.frost }
                                                MouseArea { id: fpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.min(120, root.pomoFocusMin+5); root.tmrSaveCfg() } } } }
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Break"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: bmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: bmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoBreakMin = Math.max(1, root.pomoBreakMin-1); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoBreakMin; color: theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: bpMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "add"; sz: 12; color: theme.frost }
                                                MouseArea { id: bpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoBreakMin = Math.min(60, root.pomoBreakMin+1); root.tmrSaveCfg() } } } }
                                        Item { width: 2; height: 1 }
                                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 26; height: 22; radius: Tok.r
                                            color: root.pomoDnd ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: root.pomoDnd?theme.a(theme.iris,0.5):theme.a(theme.line,0.9)
                                            Sym { anchors.centerIn: parent; text: root.pomoDnd?"notifications_off":"notifications"; sz: 13; color: root.pomoDnd?theme.iris:theme.faint }
                                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoDnd = !root.pomoDnd; root.tmrSaveCfg() } } } } } }

                            }
                            // ================= WORLD CLOCK =================
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column { width: parent.width; spacing: 5
                                CalHead { skey: "wc"; title: "World clock"
                                    summary: root.wcZones.length === 0 ? "None" : root.wcZones.length + " cities" }
                                Column { width: parent.width; spacing: 5; visible: !root.calFolded("wc")
                                Repeater { model: root.wcTimes
                                    delegate: Rectangle { required property var modelData; width: parent.width; height: 28; radius: Tok.r
                                        color: wcm.containsMouse ? theme.a(theme.line,0.4) : "transparent"
                                        Row { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "public"; sz: 13; color: theme.sub }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 120; elide: Text.ElideRight; text: modelData.label; color: theme.text; font.pixelSize: 11; font.family: Tok.sans }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.day; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.time; color: theme.frost; font.pixelSize: 12; font.family: Tok.sans; font.bold: true } }
                                        MouseArea { id: wcm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                        Rectangle { anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter; visible: wcm.containsMouse
                                            width: 20; height: 20; radius: Tok.r; color: theme.a(theme.bad,0.22)
                                            Sym { anchors.centerIn: parent; text: "close"; sz: 12; color: theme.bad }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wcRemove(modelData.zone) } } } }
                                Text { visible: root.wcTimes.length===0; text: "Add a city below"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
                                Flow { width: parent.width; spacing: 5; topPadding: 2
                                    Repeater { model: root.wcPresets
                                        delegate: Rectangle { required property var modelData
                                            visible: root.wcZones.indexOf(modelData.z) < 0
                                            height: 22; radius: Tok.r; width: visible ? (wcAddRow.implicitWidth + 14) : 0
                                            color: wcaMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.35); border.width: 0; border.color: theme.a(theme.iris,0.18)
                                            Row { id: wcAddRow; anchors.centerIn: parent; spacing: 3
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "add"; sz: 11; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: theme.text; font.pixelSize: 11; font.family: Tok.sans } }
                                            MouseArea { id: wcaMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.wcAdd(modelData.z) } } } } } } } }
                    }
                    // Same rules as the full power menu (PowerMenu.qml): lock and suspend lose nothing
                    // and act at once; log out, restart and shut down are HELD, a fill sweeping the row
                    // while you keep the button down. "More" opens the full menu.
                    LazyLoader { activeAsync: (root.openPop ==="pwr" && root.openBar === bar) || !!(item && item.visible); Drop { screen: bar.screen
                        id: pwrDrop; host: root.barVertical ? pwrPillVert : pwrPill; shown: root.openPop ==="pwr" && root.openBar === bar
                        cardW: 280; cardH: pwrCol.implicitHeight + 24
                        property string up: ""
                        property string laterAt: ""
                        property string holdL: ""
                        property real holdP: 0
                        function go(c) { root.openPop = ""; Quickshell.execDetached(["sh","-c",c]) }
                        function release() { if (holdP >= 0.999) return; pwrHold.stop(); holdL = ""; holdP = 0 }
                        NumberAnimation { id: pwrHold; target: pwrDrop; property: "holdP"; from: 0; to: 1; duration: 750; easing.type: Easing.InOutQuad
                            property string cmd: ""
                            onFinished: if (pwrDrop.holdL !== "" && pwrDrop.holdP >= 0.999) { pwrDrop.holdL = ""; pwrDrop.holdP = 0; pwrDrop.go(cmd) } }
                        onVisibleChanged: { pwrDrop.release(); if (visible) { upProc.running = true; pwrLater.running = true } }
                        Process { id: upProc; command: ["awk", "{s=int($1); printf \"%dh %02dm\", s/3600, (s%3600)/60}", "/proc/uptime"]
                            stdout: StdioCollector { onStreamFinished: pwrDrop.up = text.trim() } }
                        Process { id: pwrLater; command: ["systemctl", "--user", "show", "sea-shutdown.timer", "-p", "ActiveState", "-p", "NextElapseUSecRealtime", "--value"]
                            stdout: StdioCollector { onStreamFinished: { var l = text.trim().split("\n"), m = (l[1] || "").match(/(\d\d:\d\d):\d\d/); pwrDrop.laterAt = l[0] === "active" && m ? m[1] : "" } } }
                        Column { id: pwrCol; anchors.fill: pwrDrop.card; anchors.margins: 12; spacing: 8
                            ProfileCard { width: parent.width; height: Math.max(60, implicitHeight - 14); compact: true; flat: true
                                profile: root.userProfile
                                subtitle: "Up " + pwrDrop.up + (UPower.displayDevice && UPower.displayDevice.isLaptopBattery
                                    ? "  ·  " + Math.round((UPower.displayDevice.percentage || 0) * 100) + "%" : "")
                            }
                            // the two that lose nothing, side by side
                            Row { width: parent.width; spacing: 8
                                Repeater { model: [{i:"lock",l:"Lock",c:root.seaScripts + "sea-lock.sh"}, {i:"bedtime",l:"Suspend",c:"systemctl suspend"}]
                                    delegate: Rectangle { required property var modelData
                                        width: (pwrCol.width - 8) / 2; height: 58; radius: Tok.rCard
                                        color: qma.pressed ? Tok.alpha(Tok.accent, 0.2) : qma.containsMouse ? Tok.alpha(Tok.ink, 0.1) : Tok.alpha(Tok.ink, 0.06)
                                        border.width: 0
                                        Column { anchors.centerIn: parent; spacing: 4
                                            Sym { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.i; sz: 20; color: qma.containsMouse ? Tok.accent : Tok.ink2 }
                                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.l; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans } }
                                        MouseArea { id: qma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: pwrDrop.go(modelData.c) } } } }
                            // the three that end your work: hold
                            Repeater { model: [{i:"logout",l:"Log out",c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }",col:Tok.warn},
                                               {i:"restart_alt",l:"Restart",c:"systemctl reboot",col:Tok.warn},
                                               {i:"power_settings_new",l:"Shut down",c:"systemctl poweroff",col:Tok.crit}]
                                delegate: Rectangle { required property var modelData
                                    readonly property bool held: pwrDrop.holdL === modelData.l
                                    width: parent.width; height: 38; radius: Tok.r; clip: true
                                    color: pw.containsMouse ? Tok.alpha(Tok.ink, 0.07) : "transparent"
                                    border.width: held ? 1 : 0; border.color: modelData.col
                                    Rectangle { width: parent.width * (held ? pwrDrop.holdP : 0); height: parent.height
                                        color: Qt.rgba(modelData.col.r, modelData.col.g, modelData.col.b, 0.22) }
                                    Row { anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 12
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 18; color: held || pw.containsMouse ? modelData.col : Tok.ink2 }
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: held ? "Keep holding to " + modelData.l.toLowerCase() : modelData.l
                                            color: held ? modelData.col : Tok.ink; font.pixelSize: 13; font.family: Tok.sans } }
                                    Text { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                        visible: pw.containsMouse && !held; text: "Hold"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                                    MouseArea { id: pw; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onPressed: { pwrDrop.holdL = modelData.l; pwrHold.cmd = modelData.c; pwrHold.restart() }
                                        onReleased: pwrDrop.release(); onCanceled: pwrDrop.release() } } }
                            Rectangle { width: parent.width; height: 1; color: Tok.alpha(Tok.ink, 0.08) }
                            Item { width: parent.width; height: 26
                                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    text: pwrDrop.laterAt ? "Shutting down at " + pwrDrop.laterAt : ""
                                    color: Tok.warn; font.pixelSize: 11; font.family: Tok.sans }
                                Rectangle { anchors.left: parent.left; anchors.leftMargin: 120; anchors.verticalCenter: parent.verticalCenter
                                    visible: pwrDrop.laterAt !== ""; width: cxT.implicitWidth + 16; height: 24; radius: 12
                                    color: cxMa.containsMouse ? Tok.alpha(Tok.ink, 0.08) : Tok.alpha(Tok.ink, 0.04); border.width: 0
                                    Text { id: cxT; anchors.centerIn: parent; text: "Cancel"; color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans }
                                    MouseArea { id: cxMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { Quickshell.execDetached(["sh","-c","systemctl --user stop sea-shutdown.timer && notify-send -i system-shutdown 'Shutdown cancelled'"]); pwrDrop.laterAt = "" } } }
                                Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    text: "More options  ›"; color: moreMa.containsMouse ? Tok.accent : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
                                    MouseArea { id: moreMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.openPop = ""; powerMenu.open() } } } } } }
                    }
                } // closes rightGroupDrops
                } // closes horizontalBarLayout

                // ---------- START: verticalBarLayout ----------
                //
                // ONE PILL DEFINITION, BOTH ORIENTATIONS.
                //
                // `Pill` was written to serve a vertical bar. It has the stacked icon-over-
                // value layout, the shared column width derived from the bar thickness, the
                // compact `vertValue` that falls back to `value` — and then `vert` was
                // declared `readonly property bool vert: false`, which locked every one of
                // those branches off permanently. Nothing could ever set it.
                //
                // So a second, hand-written set of pills grew here instead: fourteen
                // near-identical Rectangles, each repeating the hover colour, the border, the
                // click-to-open-a-dropdown wiring. That duplication is the whole reason this
                // bar has been broken — the weather pill was simply MISSING, so its dropdown
                // named a host that had never been written and every reload of a side bar
                // threw "ReferenceError: wxPillVert is not defined"; the updates pill had no
                // vertical form at all and opened its card off a hidden horizontal one; and
                // none of them ever got the press feedback, the width animation, or the
                // per-widget styling from Settings that the horizontal pills have.
                //
                // They are all `Pill { vert: true }` now. Everything the horizontal bar has
                // or gains, the side bar gets with it, and there is one place to fix.
                ColumnLayout {
                    id: verticalBarLayout
                    anchors.fill: parent
                    anchors.topMargin: root.cfgRadius + 6
                    anchors.bottomMargin: root.cfgRadius + 6
                    // reveal via opacity (not visible:false) — see horizontalBarLayout note
                    opacity: root.barVertical ? 1 : 0
                    enabled: root.barVertical
                    z: root.barVertical ? 1 : 0
                    spacing: 10

                    // A hairline between clusters. The old side bar was one undifferentiated
                    // column of identical squares from top to bottom, which is why nothing on
                    // it read as belonging to anything else.
                    component VRule: Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 2; Layout.bottomMargin: 2
                        implicitWidth: 16; implicitHeight: 1
                        color: theme.a(theme.line, 0.9)
                    }

                    // --- TOP: the mark, then where you are ---
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8

                        // BarLogo, not SeaLogo: the side bar drew the sea wave no matter what
                        // the user had chosen, because SeaLogo is one mark and BarLogo is the
                        // one that reads `logoKind` — so a CachyOS machine with the mark set to
                        // "auto" got the right logo on a top bar and the wrong one on a side bar.
                        // Same click behaviour as the horizontal mark: left opens the system
                        // menu, right still goes straight to the launcher.
                        BarLogo {
                            id: logoVert
                            size: 24
                            kind: root.logoKind
                            imagePath: root.cfgBarLogoPath
                            card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (e)=> {
                                    if (e.button === Qt.RightButton) { launcher.toggle(); return }
                                    root.openPop = (root.openPop === "sea") ? "" : "sea";
                                } }
                        }

                        VRule {}

                        // Workspaces. FOLLOWS THE NUMBERING AND THE STYLE THE USER PICKED, which
                        // the old vertical switcher did not: it hardcoded one look, so choosing
                        // "circles" or "pills" in Settings changed the top bar and left the side
                        // bar drawing something else entirely.
                        Column {
                            spacing: 6
                            Layout.alignment: Qt.AlignHCenter
                            Repeater {
                                model: root.stripWorkspaces
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                    // Special workspaces are not places here either. The
                                    // horizontal strip has excluded them since 6.0 and this
                                    // one never got the same line, so a vertical bar drew a
                                    // 24px circle reading "-98" the moment you used SUPER+`.
                                    visible: modelData.id > 0
                                    width: root.cfgWsStyle === "circle" ? 26 : 24
                                    height: root.cfgWsStyle === "grow" ? (foc ? 36 : 24)
                                          : (root.cfgWsStyle === "circle" ? 26 : 24)
                                    radius: root.cfgWsStyle === "circle" ? width / 2 : Tok.r
                                    color: foc ? theme.iris : theme.a(theme.line, 0.55)
                                    border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris, 0.18)
                                    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.wsLabelFor(modelData.id)
                                        color: foc ? Tok.accentInk : theme.sub
                                        font.pixelSize: 12; font.family: root.wsFontFamily; font.bold: foc
                                    }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = "+modelData.id+" })") }
                                }
                            }
                            // the stash — see the horizontal bar's note
                            Rectangle {
                                visible: root.scratchCount > 0
                                width: 24; height: 24; radius: Tok.r
                                color: root.scratchOpen ? theme.iris : theme.a(theme.line, 0.55)
                                border.width: 1
                                border.color: root.scratchOpen ? theme.frost : theme.a(theme.iris, 0.18)
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Text { anchors.centerIn: parent
                                    text: "" + root.scratchCount
                                    color: root.scratchOpen ? Tok.accentInk : theme.sub
                                    font.pixelSize: 11; font.family: root.wsFontFamily
                                    font.bold: root.scratchOpen }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: Hyprland.dispatch("hl.dsp.workspace.toggle_special('scratch')") }
                            }
                        }
                    }

                    // ONE flexible gap, not two. The old layout put a fillHeight spacer on
                    // either side of the media/system pair, which pinned them to the exact
                    // middle of the screen and left two large empty runs — a bar that looked
                    // half-empty however many widgets were switched on.
                    Item { Layout.fillHeight: true }

                    // --- what is playing, and how hard the machine is working ---
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8
                        visible: mprisPillVert.visible || sysPillVert.visible

                        Pill { owner: bar; vert: true; id: mprisPillVert; key: "mpris"
                            wid: "wgMpris"
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgMpris && root.player !== null
                            icon: "music_note"; accent: theme.frost
                            onRightClicked: if (root.player) root.player.togglePlaying()
                            onScrolled: (dy)=>{ if (!root.player) return; if (dy > 0) root.player.next(); else root.player.previous() } }

                        Pill { owner: bar; vert: true; id: sysPillVert; key: "sys"
                            wid: "wgSystem"
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgSystem
                            // Same source as the horizontal one, and the same accent that
                            // follows whichever metric is on show — a side bar reporting a
                            // different number from the top bar would be its own bug.
                            icon: "speed"
                            accent: root.sysMetrics[root.sysShown[0]].c()
                            vertValue: Math.round(root.cpuUsage) + "%" }

                        VRule { visible: true }
                    }

                    // --- BOTTOM: tray, status, the clock, the way out ---
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 7

                        // System tray (vertical stack)
                        ColumnLayout {
                            spacing: 5
                            Layout.alignment: Qt.AlignHCenter
                            visible: SystemTray.items && SystemTray.items.values.length > 0
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                width: 22; height: 18; radius: Tok.r
                                color: trayMa.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4)
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Sym { anchors.centerIn: parent; text: root.trayCollapsed ? "expand_less" : "expand_more"; sz: 12; color: theme.sub }
                                MouseArea { id: trayMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed }
                            }
                            ColumnLayout {
                                spacing: 5
                                visible: !root.trayCollapsed
                                Repeater {
                                    model: SystemTray.items
                                    delegate: Item {
                                        id: trayItemVert
                                        required property SystemTrayItem modelData
                                        Layout.alignment: Qt.AlignHCenter
                                        implicitWidth: 20; implicitHeight: 20
                                        scale: trayVMa.pressed ? 0.9 : 1.0
                                        Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
                                        Image {
                                            width: 40; height: 40; anchors.centerIn: parent; scale: 0.5
                                            asynchronous: true; source: { try { return (trayItemVert.modelData && trayItemVert.modelData.icon) ? trayItemVert.modelData.icon : "" } catch(e) { return "" } }
                                            sourceSize.width: 96; sourceSize.height: 96; smooth: true; mipmap: true
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        MouseArea {
                                            id: trayVMa
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton|Qt.RightButton
                                            onClicked: (e)=>{
                                                try {
                                                    if (!trayItemVert.modelData) return;
                                                    if (e.button===Qt.LeftButton) { trayItemVert.modelData.activate(); return }
                                                    if (root.openPop==="tray" && bar.trayHost===trayItemVert) { root.openPop=""; return }
                                                    bar.trayHost = trayItemVert; bar.trayMenuSel = trayItemVert.modelData; root.openBar = bar; root.openPop = "tray"
                                                } catch(err) { root.openPop=""; }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        VRule { visible: SystemTray.items && SystemTray.items.values.length > 0 }

                        Pill { owner: bar; vert: true; id: ccPillVert; key: "cc"
                            wid: "wgQuick"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgQuick; icon: "tune"; accent: theme.frost }

                        Pill { owner: bar; vert: true; id: wxPillVert; key: "wx"
                            wid: "wgWeather"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgWeather && root.wxTemp !== ""
                            icon: root.wxIcon(root.wxCond); accent: theme.frost
                            vertValue: root.wxTemp }

                        Pill { owner: bar; vert: true; id: updPillVert; key: "upd"
                            wid: "wgUpdates"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgUpdates
                            icon: root.updTotal > 0 ? "system_update_alt" : "task_alt"
                            accent: root.updTotal > 0 ? theme.warn : theme.frost
                            vertValue: root.updTotal > 0 ? String(root.updTotal) : "" }

                        Pill { owner: bar; vert: true; id: aiPillVert; key: "ai"
                            wid: "wgAi"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgAi
                            mark: root.aiShown ? root.aiShown.id : "claude"
                            markAlso: (root.aiShown && root.aiShown.with) ? root.aiShown.with : ""
                            accent: root.aiAccent
                            vertValue: root.aiBarValue }

                        Pill { owner: bar; vert: true; id: ghPillVert; key: "gh"
                            wid: "wgGithub"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgGithub
                            icon: root.githubPillIcon
                            accent: root.githubPillAccent
                            ember: root.githubSputter ? root.githubEmber : 1.0
                            vertValue: root.githubBarValue }

                        Pill { owner: bar; vert: true; id: totemPillVert; key: "totem"
                            wid: "wgTotem"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgTotem
                            icon: root.totemPillIcon
                            accent: root.totemPillAccent
                            vertValue: root.totemCode !== "" ? root.totemCode : "" }

                        Pill { owner: bar; vert: true; id: wifiPillVert; key: "wifi"
                            wid: "wgWifi"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgWifi
                            icon: root.wifiIcon
                            accent: root.wifiAccent }

                        Pill { owner: bar; vert: true; id: btPillVert; key: "bt"
                            wid: "wgBluetooth"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgBluetooth && root.btAdapter !== null
                            icon: "bluetooth"
                            accent: root.btActive ? theme.iris : theme.frost }

                        Pill { owner: bar; vert: true; id: kdePillVert; key: "kde"
                            wid: "wgKdeconnect"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgKdeconnect
                            icon: root.kdeActive ? root.kdeIcon(root.kdeDev) : "phonelink_off"
                            accent: root.kdeActive ? theme.iris : theme.frost }

                        Pill { owner: bar; vert: true; id: volPillVert; key: "vol"
                            wid: "wgVolume"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgVolume
                            readonly property var au: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
                            readonly property int vol: au ? Math.round(au.volume*100) : 0
                            icon: !volPillVert.au || volPillVert.au.muted ? "volume_off"
                                  : volPillVert.vol < 34 ? "volume_mute"
                                  : volPillVert.vol < 67 ? "volume_down" : "volume_up"
                            accent: (volPillVert.au && volPillVert.au.muted) ? theme.bad : theme.frost
                            vertValue: (volPillVert.au && !volPillVert.au.muted) ? (volPillVert.vol + "%") : ""
                            onScrolled: (dy)=>{ if (!volPillVert.au) return
                                volPillVert.au.volume = Math.max(0, Math.min(1, volPillVert.au.volume + (dy > 0 ? 0.05 : -0.05))) } }

                        Pill { owner: bar; vert: true; id: batPillVert; key: "bat"
                            wid: "wgBattery"; Layout.alignment: Qt.AlignHCenter
                            readonly property var dev: UPower.displayDevice
                            readonly property bool charging: !UPower.onBattery
                            readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                            visible: root.cfgBattery && dev && dev.isLaptopBattery
                            icon: batPillVert.charging ? "battery_charging_full"
                                  : batPillVert.pct >= 90 ? "battery_full" : "battery_5_bar"
                            accent: (!batPillVert.charging && batPillVert.pct <= 20) ? theme.bad : theme.frost
                            vertValue: batPillVert.pct + "%" }

                        Pill { owner: bar; vert: true; id: bellPillVert; key: "notif"
                            wid: "wgNotif"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgNotif
                            icon: root.dnd ? "notifications_off"
                                  : (root.notes.length > 0 ? "notifications" : "notifications_none")
                            accent: root.notes.length > 0 ? theme.iris : theme.frost
                            vertValue: root.notes.length > 0 ? String(root.notes.length) : "" }

                        VRule {}

                        // The clock stays hand-built: it is the one thing here that is two
                        // lines of type rather than an icon with a readout, and squeezing
                        // "20:14" through the pill's single compact value would lose the
                        // hour/minute stacking that makes it legible in a 42px column.
                        Item {
                            id: clockPillVert
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgClock
                            implicitWidth: Math.max(30, root.cfgHeight - 12)
                            implicitHeight: clockColVert.implicitHeight + 8
                            Rectangle {
                                anchors.fill: parent; radius: Tok.r
                                color: (root.openPop === "cal" || clockVMa.containsMouse)
                                       ? theme.a(theme.iris, 0.18) : "transparent"
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                            }
                            ColumnLayout {
                                id: clockColVert
                                anchors.centerIn: parent
                                spacing: 0
                                Text {
                                    text: Qt.formatDateTime(clock.date, "HH")
                                    color: theme.text; font.pixelSize: 13; font.bold: true; font.family: Tok.sans
                                    Layout.alignment: Qt.AlignHCenter
                                }
                                Text {
                                    text: Qt.formatDateTime(clock.date, "mm")
                                    color: theme.iris; font.pixelSize: 13; font.bold: true; font.family: Tok.sans
                                    Layout.alignment: Qt.AlignHCenter
                                }
                            }
                            MouseArea {
                                id: clockVMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "cal") ? "" : "cal" }
                            }
                        }

                        Pill { owner: bar; vert: true; id: pwrPillVert; key: "pwr"
                            wid: "wgPower"; Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgPower
                            icon: "power_settings_new"; accent: theme.bad }

                        Item { Layout.preferredHeight: 2; Layout.preferredWidth: 1 }
                    }
                }
            }
            }

            // register this bar's windows with the ONE shared focus grab at root —
            // a grab per bar fights the other monitors' grabs and insta-closes dropdowns
            Item {
                // EVERY dropdown must be in this list. One left out is not "unregistered", it is
                // treated as outside the grab — so it opens and is dismissed in the same frame,
                // which looks exactly like a dead pill. (updDrop was missing and did precisely that.)
                // The dropdowns register themselves (Drop, below) as they are built — they are
                // built lazily after the bar is up, so a list written here would name windows
                // that do not exist yet.
                readonly property var myWins: [bar]
                Component.onCompleted: {
                    try { root.grabWins = root.grabWins.concat(myWins); } catch(e) {}
                }
                Component.onDestruction: {
                    try {
                        var mw = myWins;
                        root.grabWins = root.grabWins.filter(function(w) { return w && mw.indexOf(w) < 0; });
                    } catch(e) {}
                }
            }
            
            // clear tray hosts/menus safely if a SystemTrayItem is removed
            Connections {
                target: SystemTray.items
                ignoreUnknownSignals: true
                function onValuesChanged() {
                    if (root.openPop === "tray") {
                        try {
                            var vals = SystemTray.items ? SystemTray.items.values : [];
                            var found = false;
                            for (var i = 0; i < vals.length; i++) {
                                if (vals[i] === bar.trayMenuSel) { found = true; break; }
                            }
                            if (!found) { root.openPop = ""; bar.trayHost = null; bar.trayMenuSel = null; }
                        } catch(e) { root.openPop = ""; bar.trayHost = null; bar.trayMenuSel = null; }
                    }
                }
            }
        }
    }

 // ===== on-screen notification popups (top-right, under the bar) =====
    PanelWindow {
        id: notifWin
        readonly property real ui: root.uiFor(notifWin.screen)
        readonly property real baseW: 370
        // Sized to the notification stack instead of a full 1920x1080 surface: saves ~20+ MB
        // of GPU/Wayland swapchain buffers while toasts are shown.
        anchors { top: true; right: true }
        margins { top: Math.round(42 * notifWin.ui); right: Math.round(4 * notifWin.ui) }
        implicitWidth: Math.ceil((notifWin.baseW + 24) * notifWin.ui)
        implicitHeight: Math.max(1, Math.ceil((popCol.implicitHeight + 24) * notifWin.ui))
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "sea-shell:notif"
        exclusionMode: ExclusionMode.Ignore
        visible: popupModel.count > 0
        mask: Region { item: popCol }
        // stack authored at native width; scaled up as a whole, pinned to the top-right corner
        Column {
            id: popCol
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 8 * notifWin.ui
            anchors.rightMargin: 8 * notifWin.ui
            width: notifWin.baseW
            spacing: 8
            transformOrigin: Item.TopRight
            scale: notifWin.ui
            // Notifications are the most dynamic thing the shell draws. `move` shuffles the cards
            // when one comes or goes. Arriving is each card's own animation below, not the
            // Column's `add`: a second arrival interrupted that one, and a burst left the earlier
            // cards stuck nearly transparent for the rest of their time on screen.
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: Tok.mBase
                                  easing.type: Easing.Bezier; easing.bezierCurve: Tok.mMove }
            }
            Repeater {
                model: popupModel
                // The app's icon large on the left and the details beside it: its name and "now",
                // the title, the body, and the app's own buttons as pills; a round close button
                // shows on hover. Glass like the bar and its menus.
                delegate: Glass {
                    id: pcard
                    required property var model
                    readonly property var actList: {
                        try { return JSON.parse(pcard.model.acts || "[]"); } catch (e) { return []; }
                    }
                    readonly property bool isShell: ("" + pcard.model.appName).toLowerCase() === "sea-shell"
                    readonly property bool hasPhoto: !!pcard.model.image && pPhoto.status === Image.Ready
                    readonly property string iconSrc: {
                        var i = "" + (pcard.model.appIcon || "");
                        if (i.indexOf("/") === 0) return "file://" + i;
                        if (i.indexOf("file:") === 0 || i.indexOf("image:") === 0) return i;
                        var p = i ? Quickshell.iconPath(i, true) : "";
                        if (!p) { try { var e = DesktopEntries.heuristicLookup("" + pcard.model.appName); if (e && e.icon) p = Quickshell.iconPath(e.icon, true) } catch (err) {} }
                        return p || Quickshell.iconPath(("" + pcard.model.appName).toLowerCase(), true);
                    }
                    width: popCol.width; radius: Tok.rCard + 4
                    implicitHeight: Math.max(pcc.implicitHeight + 28, pIcon.height + 28)
                    height: implicitHeight
                    border.color: pcard.model.urg === 2 ? Tok.alpha(Tok.crit, 0.7) : (Tok.glassy ? Tok.glassEdge : Tok.alpha(Tok.ink, 0.08))
                    NumberAnimation on opacity { from: 0; to: 1; duration: Tok.mFast }
                    transform: Translate { id: pEnter }
                    NumberAnimation { running: true; target: pEnter; property: "x"; from: popCol.width * 0.3; to: 0
                                      duration: Tok.mBase; easing.type: Easing.Bezier; easing.bezierCurve: Tok.mEnter }
                    HoverHandler { id: pHover }
                    // the app: the shell's own mark, the app's icon, or a tile with a bell
                    Item {
                        id: pIcon
                        x: 14; width: 52; height: 52
                        // beside the text it describes, until buttons make the card tall
                        y: pcard.actList.length > 0 ? 14 : (pcard.height - height) / 2
                        SeaLogo { anchors.centerIn: parent; visible: pcard.isShell && !pcard.hasPhoto; size: parent.width; accent: Tok.accent }
                        IconImage { id: pIconImg; anchors.fill: parent; source: pcard.isShell ? "" : pcard.iconSrc
                            visible: !pcard.isShell && !pcard.hasPhoto && status === Image.Ready; asynchronous: true }
                        // the notification's own picture, with the app it came from as a badge
                        ClippingRectangle { anchors.fill: parent; radius: 12; color: "transparent"; visible: pcard.hasPhoto
                            Image { id: pPhoto; anchors.fill: parent; source: pcard.model.image || ""; fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 104; sourceSize.height: 104; asynchronous: true } }
                        Rectangle { visible: pcard.hasPhoto && pBadge.status === Image.Ready
                            x: parent.width - 16; y: parent.height - 16; width: 22; height: 22; radius: 7; color: Tok.surface
                            IconImage { id: pBadge; anchors.centerIn: parent; implicitSize: 18; source: pcard.iconSrc; asynchronous: true } }
                        Rectangle {
                            anchors.fill: parent; radius: 14; visible: !pcard.isShell && !pcard.hasPhoto && !pIconImg.visible
                            color: pcard.model.urg === 2 ? Tok.crit : Tok.accent
                            Sym { anchors.centerIn: parent; text: pcard.model.urg === 2 ? "priority_high" : "notifications"; sz: 28
                                color: pcard.model.urg === 2 ? "white" : Tok.accentInk }
                        }
                    }
                    Column {
                        id: pcc
                        anchors.left: pIcon.right; anchors.leftMargin: 13
                        anchors.right: parent.right; anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Item {
                            width: parent.width; height: 16
                            Text { anchors.left: parent.left; anchors.right: pWhen.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                text: pcard.model.appName + (pcard.model.n > 1 ? " · " + pcard.model.n + " new" : "")
                                color: Tok.ink2; font.pixelSize: 11; font.weight: Font.DemiBold; font.family: Tok.sans; elide: Text.ElideRight }
                            Text { id: pWhen; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                text: "Now"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                        }
                        Text { width: parent.width; visible: pcard.model.summary !== ""; text: pcard.model.summary
                            color: Tok.ink; font.pixelSize: 13; font.weight: Font.DemiBold; font.family: Tok.sans; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                        Text { width: parent.width; visible: pcard.model.body !== ""; text: pcard.model.body
                            color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight; textFormat: Text.PlainText; lineHeight: 1.1 }
                        // action buttons the app supplied (Reply, Mark as read, …)
                        Row {
                            spacing: 6; topPadding: 8
                            visible: pcard.actList.length > 0
                            Repeater {
                                model: pcard.actList
                                delegate: Rectangle {
                                    required property var modelData
                                    height: 26; radius: 13
                                    width: alab.implicitWidth + 22
                                    color: am.containsMouse ? Tok.alpha(Tok.ink, 0.13) : Tok.alpha(Tok.ink, 0.07)
                                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                    scale: am.pressed ? 0.95 : 1.0
                                    Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
                                    Text { id: alab; anchors.centerIn: parent; text: modelData.t
                                        color: Tok.ink; font.pixelSize: 12; font.weight: Font.Medium; font.family: Tok.sans }
                                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.noteInvoke(pcard.model.key, modelData.i) }
                                }
                            }
                        }
                    }
                    // close, top-left over the icon's corner, on hover only
                    Rectangle {
                        x: -6; y: -6; width: 22; height: 22; radius: 11
                        opacity: pHover.hovered ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                        color: xm.containsMouse ? Tok.raised : Tok.surface
                        border.width: 1; border.color: Tok.alpha(Tok.ink, 0.14)
                        Sym { anchors.centerIn: parent; text: "close"; sz: 13; color: Tok.ink2 }
                        MouseArea { id: xm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.popDismiss(pcard.model.key) } }
                    Timer { running: true; interval: pcard.model.urg===2 ? 12000 : 5000; onTriggered: root.popDismiss(pcard.model.key) }
                }
            }
        }
    }

    // ===== OSD (volume / brightness), bottom-centre =====
    PanelWindow {
        id: osdWin
        readonly property real ui: root.uiFor(osdWin.screen)
        anchors { bottom: true; left: true; right: true }
        margins { bottom: 80 * osdWin.ui }
        implicitHeight: 60 * osdWin.ui
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:osd"
        exclusionMode: ExclusionMode.Ignore
        // Held mapped for the length of the fade-out, the same trick the dropdowns use, so
        // the layer surface is never torn down with a visible card still on it. Every volume
        // key press shows this — of everything in the shell it is the thing seen most often,
        // and it was appearing and vanishing between two frames.
        readonly property bool on: root.osdKind !== ""
        property bool held: false
        visible: osdWin.on || osdWin.held
        onOnChanged: { if (osdWin.on) { osdHold.stop(); osdWin.held = true } else osdHold.restart() }
        Timer { id: osdHold; interval: Tok.mFast + 30; onTriggered: osdWin.held = false }
        mask: Region { item: osdCard }
        Glass {
            id: osdCard
            anchors.centerIn: parent
            // authored native; scaled around its centre — and the last 6% of that scale is
            // the entry, so it grows into place rather than being switched on.
            scale: osdWin.ui * (osdWin.on ? 1.0 : 0.94)
            opacity: osdWin.on ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            Behavior on scale { NumberAnimation { duration: Tok.mBase
                                                  easing.type: Easing.Bezier
                                                  easing.bezierCurve: Tok.mEnter } }
            width: 250; height: 54; radius: Tok.rCard
            Row { anchors.fill: parent; anchors.margins: 16; spacing: 13
                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.osdIcon; sz: 24; color: theme.frost }
                Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width-52; spacing: 6
                    Row { width: parent.width
                        Text { text: root.osdKind==="vol" ? "Volume" : (root.osdKind==="zoom" ? "Magnifier" : "Brightness"); color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                        Item { width: parent.width - 80; height: 1 }
                        Text { text: root.osdKind==="zoom" ? (root.zoomFactor.toFixed(2).replace(/\.?0+$/,"")+"×") : (Math.round(root.osdVal*100)+"%"); color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont } }
                    Rectangle { width: parent.width; height: 6; radius: Tok.r; color: theme.a(theme.line,0.85)
                        Rectangle { width: parent.width*Math.max(0,Math.min(1,root.osdVal)); height: parent.height; radius: Tok.r; color: theme.iris
                            Behavior on width { NumberAnimation { duration: 90 } } } }
                }
            }
        }
    }

    // ===== Exposé — every workspace (WorkspacesPanel.qml) =====
    property bool exposeActive: false
    // refresh on the way in: the tiles read titles/classes and focus by address out of
    // lastIpcObject, which goes empty on a long-lived shell until something asks for it.
    function toggleExpose() { if (!root.exposeActive) Hyprland.refreshToplevels(); root.exposeActive = !root.exposeActive }
    WorkspacesPanel {
        active: root.exposeActive
        uiFor: root.uiFor
        labelFor: root.wsLabelFor
        scratchWs: root.scratchWs
        scratchCount: root.scratchCount
        scratchOpen: root.scratchOpen
        onDismiss: root.exposeActive = false
    }
}
