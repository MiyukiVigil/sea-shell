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

    // Auto-detect HDMI monitor plugin to switch audio to HDMI (TV)
    readonly property int screenCount: Quickshell.screens.length
    onScreenCountChanged: {
        if (screenCount > 1) {
            Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-hdmi-audio.sh").toString().replace("file://", "")]);
        }
    }
    Component.onCompleted: {
        if (Quickshell.screens.length > 1) {
            Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-hdmi-audio.sh").toString().replace("file://", "")]);
        }
    }

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
    Timer { interval: 8000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: kdeWatch.running = root.cfgKdeconnect }

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

    // Moondrop DAC parametric-EQ panel — resident overlay, toggled via its "dac" IPC
    // (SUPER+SHIFT+E). No-ops gracefully when no Moondrop device is connected.
    DacPanel { id: dacPanel }

    // Screen recorder chooser — resident overlay, toggled via its "recorder" IPC
    // (SUPER+R). It owns the whole SUPER+R semantic: stops a running recording,
    // otherwise opens. `recording` is fed from the status poll above so it knows which.
    // The exclusive hold is passed through so it can warn that system audio recorded
    // from a monitor will be silent while a DAC is playing bit-perfect past pipewire.
    RecorderPanel {
        id: recPanel
        recording: root.recordingActive
        exclusiveHold: root.dacExclusive
        exclusiveName: root.dacModel
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
        function pin(): void { root.grabHold = true }
        function unpin(): void { root.grabHold = false }
        function toggleExpose(): void { root.toggleExpose() }
        function toggleIdle(): void { root.toggleIdle() }
    }

    // ---------- alt-tab window switcher (resident, driven by ALT+Tab binds) ----------
    property bool switcherOpen: false
    property int switcherSel: 0
    // Show the switcher ONLY on the focused monitor, not mirrored onto every screen —
    // a full card on each output reads like a second switcher "behind" the real one.
    readonly property var switcherScreen: {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        if (fm && fm.name) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) return scrs[i];
        return scrs.length ? scrs[0] : null;
    }
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
            Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + w.lastIpcObject.address + "' })");
    }
    IpcHandler {
        target: "switcher"
        function next(): void { root.switcherStep(1) }
        function prev(): void { root.switcherStep(-1) }
        function commit(): void { root.switcherCommit() }
        function cancel(): void { root.switcherOpen = false }
    }
    // Visual HUD for the ALT+Tab switcher — icon + title tiles, the current pick highlighted;
    // hover to preview a pick, click to focus it. Purely visual (the ALT binds drive stepping,
    // release commits), so it takes no keyboard focus and rides the Overlay layer above windows.
    Variants {
        model: (root.switcherOpen && root.switcherScreen) ? [root.switcherScreen] : []
        PanelWindow {
            id: swWin
            required property var modelData
            screen: modelData
            readonly property real ui: root.uiFor(swWin.screen)
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:switcher"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; left: true; right: true; bottom: true }

            // dim + click-outside to dismiss without switching
            Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.30
                MouseArea { anchors.fill: parent; onClicked: root.switcherOpen = false } }

            Rectangle {
                id: swCardRoot
                anchors.centerIn: parent
                scale: swWin.ui                 // match the shell's per-monitor UI scale
                radius: Math.max(14, root.cfgRadius)
                color: theme.a(theme.panel, 0.98)
                border.width: 1; border.color: theme.a(theme.iris, 0.28)
                clip: true
                // Composite the WHOLE card (all live captures) into one offscreen buffer.
                // ScreencopyView's texture node escapes per-item clipping and was leaking a
                // stray thumbnail to a screen corner; an FBO the size of the card physically
                // confines every capture to the card rectangle.
                layer.enabled: true
                // Deterministic column count — depends only on the screen width and the
                // window count, never on the grid's own size, so there is no binding loop.
                // As many 132px tiles as fit in 86% of the screen, capped at the window count.
                readonly property int cols: Math.max(1, Math.min(root.switcherWins.length,
                                                                 Math.floor(((swWin.width / swWin.ui) * 0.86) / 218)))
                width: swGrid.implicitWidth + 28
                height: swInner.implicitHeight + 24
                Column {
                    id: swInner
                    anchors.centerIn: parent
                    spacing: 10
                    Grid {
                    id: swGrid
                    anchors.horizontalCenter: parent.horizontalCenter
                    columns: swCardRoot.cols
                    columnSpacing: 10; rowSpacing: 10
                    Repeater {
                        model: root.switcherWins
                        delegate: Rectangle {
                            id: swTile
                            required property int index
                            required property var modelData
                            readonly property bool sel: index === root.switcherSel
                            readonly property string cls: ("" + (modelData.lastIpcObject.class || "")).toLowerCase()
                            width: 208; height: 150; radius: 12
                            clip: true
                            color: sel ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.35)
                            border.width: sel ? 2 : 1
                            border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                            // live thumbnail of the window (falls back to the app icon until a
                            // frame arrives, or if the window has no capturable wayland handle)
                            Rectangle {
                                anchors { top: parent.top; left: parent.left; right: parent.right; margins: 6 }
                                height: 96; radius: 8; clip: true; color: theme.a(theme.bg, 0.55)
                                ScreencopyView {
                                    id: thumbScv
                                    anchors.fill: parent
                                    captureSource: swTile.modelData.wayland
                                    live: root.switcherOpen
                                    visible: hasContent
                                }
                                Image {
                                    anchors.centerIn: parent; visible: !thumbScv.hasContent
                                    width: 40; height: 40; asynchronous: true
                                    sourceSize.width: 80; sourceSize.height: 80; fillMode: Image.PreserveAspectFit
                                    source: Quickshell.iconPath(swTile.cls, "application-x-executable")
                                }
                            }
                            // app icon + title along the bottom
                            Row {
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
                                height: 32; spacing: 7
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18; asynchronous: true
                                    sourceSize.width: 36; sourceSize.height: 36; fillMode: Image.PreserveAspectFit
                                    source: Quickshell.iconPath(swTile.cls, "application-x-executable")
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 25; elide: Text.ElideRight
                                    text: "" + (swTile.modelData.lastIpcObject.title || swTile.modelData.lastIpcObject.class || "window")
                                    color: swTile.sel ? theme.text : theme.sub; font.pixelSize: 11; font.family: root.cfgFont; font.bold: swTile.sel
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: root.switcherSel = swTile.index
                                onClicked: { root.switcherSel = swTile.index; root.switcherCommit() }
                            }
                        }
                    }
                }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.switcherWins.length + " window" + (root.switcherWins.length === 1 ? "" : "s") + "  ·  Tab cycles  ·  release Alt to focus  ·  Esc cancels"
                        color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont
                    }
                }
            }
        }
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
    property string cfgFont: "monospace"
    property bool   cfgLight: false          // dark (default) ↔ light palette
    property string cfgBarFill: "matugen"    // top-bar fill: matugen (accent-tinted) · black · white
    property string cfgEdge: "top"           // which screen edge the bar docks to: top or bottom
    property bool cfgMpris: true
    property bool cfgDac: true
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
    property bool cfgQuick: true          // Control Center pill (quick toggles + power profile)
    property bool cfgNightWidget: false   // Night-light toggle pill on the bar
    property bool cfgAutoHide: false      // auto-hide the bar; reveal by pushing the cursor to the edge
    property bool cfgHideFullscreen: false // hide the bar while a window is fullscreen (reveal on hover)
    // order of the right-hand bar widgets (drag-reorder in Settings → Bar widgets).
    // Values are the widget ids; the bar positions each right-group pill by its index here,
    // so reordering this list reorders the pills. Unknown/absent ids fall to the far end.
    // wgMpris is the centre pill and ignores its position; wgRec is the transient recorder.
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgDac","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
    property var cfgWidgetOrder: root.defaultWidgetOrder
    // left cluster order (logo · workspaces · window-title) — drag-reorder in Settings → Bar widgets
    readonly property var defaultLeftOrder: ["lgLogo","lgWork","lgTitle"]
    property var cfgLeftOrder: root.defaultLeftOrder
    // append any ids missing from a saved order (e.g. new ones added in an update)
    // Merge widgets added by an update into a saved order. They land where the
    // default order says they belong -- immediately after the nearest earlier
    // default-neighbour the saved order already has -- rather than being pushed
    // onto the end. Appending was wrong on a right-anchored bar: the end is past
    // the power button, which is deliberately last, so every new widget arrived
    // in the one position nothing should occupy.
    function reconcileOrder(order, def) {
        var res = order.slice();
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
            if (j.edge === "top" || j.edge === "bottom" || j.edge === "left" || j.edge === "right") root.cfgEdge = j.edge;
            if (j.height  !== undefined) root.cfgHeight  = j.height;
            if (j.scale   !== undefined) root.cfgScale   = j.scale;
            if (j.accent  !== undefined && (""+j.accent).length>0) root.cfgAccent = j.accent;
            if (j.font    !== undefined && (""+j.font).length>0)   root.cfgFont   = j.font;
            if (j.mode    !== undefined) root.cfgLight = (""+j.mode === "light");
            if (j.wgMpris !== undefined) root.cfgMpris = !!j.wgMpris;
            if (j.wgDac !== undefined) root.cfgDac = !!j.wgDac;
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
            if (j.wgPower !== undefined) root.cfgPower = !!j.wgPower;
            if (j.wgQuick !== undefined) root.cfgQuick = !!j.wgQuick;
            if (j.wgNight !== undefined) root.cfgNightWidget = !!j.wgNight;
            if (j.autoHide !== undefined) root.cfgAutoHide = !!j.autoHide;
            if (j.hideFullscreen !== undefined) root.cfgHideFullscreen = !!j.hideFullscreen;
            if (j.night !== undefined) root.cfgNight = !!j.night;
            if (j.nightTemp !== undefined) root.cfgNightTemp = j.nightTemp;
            if (j.nightAuto !== undefined) root.cfgNightAuto = !!j.nightAuto;
            if (j.widgetOrder !== undefined && Array.isArray(j.widgetOrder) && j.widgetOrder.length > 0) root.cfgWidgetOrder = root.reconcileOrder(j.widgetOrder, root.defaultWidgetOrder);
            if (j.leftOrder !== undefined && Array.isArray(j.leftOrder) && j.leftOrder.length > 0) root.cfgLeftOrder = root.reconcileOrder(j.leftOrder, root.defaultLeftOrder);
            if (j.monitors !== undefined && j.monitors && typeof j.monitors === "object") root.cfgMonitors = j.monitors;
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
    // playing apps (output streams) — tracked so their per-app volume is live
    property var streams: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isStream && n.audio })
    function streamName(n) { return n ? (n.name || n.description || n.nickname || "app") : "" }
    PwObjectTracker { objects: root.streams }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "device") : "" }

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

    // ---------- moondrop dac ----------
    // Identifying the DAC rides entirely on PipeWire, and deliberately never opens
    // the device. ALSA publishes a USB card's vendor/product as "USB<vid>:<pid>" in
    // alsa.components ("USB35d8:011d" for a DAWN PRO2) -- exactly the key the
    // script's registry is indexed by -- so a passive indicator needs no hidraw at
    // all. That matters: DacPanel serialises every call through one queue because
    // two processes on the same hidraw pick up each other's replies. A pill that
    // polled --json would be the second process.
    //
    // The registry itself comes from the script (--registry is the one flag that
    // touches no hardware), so this file never hardcodes a product ID.
    readonly property string _dacScript: Qt.resolvedUrl("moondrop_control.py").toString().replace("file://","")
    property var dacRegistry: null
    Process {
        id: dacRegProc
        command: ["python3", root._dacScript, "--registry"]
        running: true
        stdout: StdioCollector { id: dacRegOut; onStreamFinished: {
            try { root.dacRegistry = JSON.parse(dacRegOut.text.trim() || "null"); }
            catch (e) { root.dacRegistry = null; }   // no registry → no pill, rather than a guess
        } }
    }

    // "USB35d8:011d" → "011d". Empty for anything that isn't this vendor.
    function dacPidOf(node) {
        if (!node || !node.properties || !root.dacRegistry) return "";
        var comp = node.properties["alsa.components"] || "";
        var m = new RegExp("USB" + root.dacRegistry.vendor_id + ":([0-9a-fA-F]{4})", "i").exec(comp);
        return m ? m[1].toLowerCase() : "";
    }
    readonly property var dacNode: {
        if (!root.dacRegistry) return null;
        var ns = root.sinks;
        for (var i = 0; i < ns.length; i++) if (root.dacPidOf(ns[i]) !== "") return ns[i];
        return null;
    }
    readonly property string dacPidPw: root.dacPidOf(root.dacNode)
    // ---- exclusive / bit-perfect playback ----
    // PipeWire is NOT the source of truth for playback. A bit-perfect player (SONE,
    // TIDAL) opens the card directly via exclusive ALSA: the graph never sees the
    // stream, defaultAudioSink cheerfully reports "Speaker" while the music is
    // physically going through the DAC, and PipeWire may not even keep a node for
    // a card it cannot open. So identification here goes around PipeWire entirely —
    // the kernel says who holds the card, and /proc/asound/cardN/usbid says what
    // that card IS ("35d8:011d"), which is the same USB pair the script's registry
    // is keyed by. One scan answers both "is anything bypassing the graph" and
    // "is that thing a Moondrop".
    property string exclCard: ""     // ALSA card index held outside pipewire
    property string exclUsbId: ""    // its "vid:pid", empty for non-USB cards
    property string exclHolder: ""   // owning process name, e.g. "alsa-writer"
    Process {
        id: dacExclProc
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
        stdout: StdioCollector { id: dacExclOut; onStreamFinished: {
            var p = dacExclOut.text.trim().split("|");
            root.exclCard = p[0] || ""; root.exclUsbId = (p[1] || "").toLowerCase(); root.exclHolder = p[2] || "";
        } } }
    // Cannot be gated on dacPresent: presence now partly DEPENDS on this scan, and
    // a timer waiting on its own result never fires. It is a few /proc reads.
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: dacExclProc.running = true }

    // The exclusively-held card, named through the script's registry — "" when
    // nothing bypasses pipewire, or when what does isn't a DAC we know.
    readonly property string dacPidExcl: {
        if (!root.dacRegistry || root.exclUsbId === "") return "";
        var p = root.exclUsbId.split(":");
        if (p.length !== 2 || p[0] !== root.dacRegistry.vendor_id) return "";
        return root.dacRegistry.supported[p[1]] ? p[1] : "";
    }
    // Prefer PipeWire's answer (reactive, no polling); fall back to the ALSA scan,
    // which is the only one that still works once the card has been taken.
    readonly property string dacPid: root.dacPidPw !== "" ? root.dacPidPw : root.dacPidExcl
    readonly property bool dacPresent: root.dacPid !== ""
    readonly property bool dacExclusive: root.dacPidExcl !== ""
    // Two ways it counts as the output: PipeWire routes to it, or something
    // bypassed PipeWire and took the card for itself.
    readonly property bool dacActive: root.dacExclusive
                                      || (root.dacNode !== null && Pipewire.defaultAudioSink !== null
                                          && Pipewire.defaultAudioSink.id === root.dacNode.id)
    // Whichever path found it, the NAME comes from the script's registry — nothing
    // here hardcodes a product ID.
    readonly property string dacModel: (root.dacRegistry && root.dacPid && root.dacRegistry.supported[root.dacPid]) || ""
    // Recognised-but-not-driveable (the Old Fashioned) stays out of the pill: it is
    // a Moondrop, but the panel cannot tune it, so claiming otherwise would lie.
    readonly property bool dacSupported: root.dacModel !== ""

    // Short name for a sink: the nickname ("Speaker") beats the description
    // ("Alder Lake PCH-P High Definition Audio Controller Speaker") on a bar.
    function sinkShort(n) { return n ? (n.nickname || n.description || n.name || "output") : "—" }
    readonly property string outputLabel:
        root.dacActive ? (root.dacModel + (root.dacExclusive ? " · exclusive" : ""))
                       : root.sinkShort(Pipewire.defaultAudioSink)

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

    // ---------- control center (quick toggles used by the "cc" dropdown) ----------
    function ccActive(k) {
        if (k === "dark") return !root.cfgLight;                       // "dark mode" tile lit while dark
        if (k === "caf")  return !root.idleOn;                         // lit while caffeine keeps the screen awake (hypridle killed)
        if (k === "dnd")  return root.dnd;
        if (k === "wifi") return root.wifiOn;
        if (k === "bt")   return !!(root.btAdapter && root.btAdapter.enabled);
        if (k === "night") return root.nightActive;
        return false;
    }
    function ccToggle(k) {
        if (k === "dark") { Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-toggle-theme.sh").toString().replace("file://","")]); return; }
        if (k === "caf")  { root.toggleIdle(); return; }
        if (k === "dnd")  { root.setDnd(!root.dnd); return; }
        if (k === "wifi") { root.wifiToggle(); return; }
        if (k === "bt")   { if (root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled; return; }
        if (k === "night"){ Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-toggle-night.sh").toString().replace("file://","")]); return; }
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
    // This poll is also sea-record.sh's cleanup tick: its status branch sweeps the
    // pipewire mix a crashed "both" recording would otherwise strand (which holds the
    // microphone open). So it stays running even when nothing is being recorded.
    property bool recordingActive: false
    property string recordingTime: "00:00"
    property string recordingAudio: ""     // none | mic | system | both
    property string recordingWhat: ""      // region, or the output name
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
    Timer { id: idleTimer; interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: idleChk.running = true }
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
    property int noteSeq: 0
    property var mutedApps: []        // per-app DND: app names whose popups are suppressed (history still records)
    // generic safe config writer — content is passed as argv (no shell quoting), so any
    // apostrophes / newlines / unicode in a notification body round-trip intact.
    function writeCfg(name, content) {
        Quickshell.execDetached(["python3","-c",
            "import sys,os,pathlib; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell'))/sys.argv[1]; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[2])",
            name, content]);
    }
    function saveNotes() { root.writeCfg("notif-history.json", JSON.stringify(root.notes)); }
    function saveMutes() { root.writeCfg("notif-mutes.json", JSON.stringify(root.mutedApps)); }
    function isMuted(app) { return root.mutedApps.indexOf(app) >= 0; }
    function toggleMute(app) {
        if (!app) return;
        var a = root.mutedApps.slice(); var i = a.indexOf(app);
        if (i >= 0) a.splice(i, 1); else a.push(app);
        root.mutedApps = a; root.saveMutes();
    }
    // restore persisted history + mutes at startup
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/notif-history.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: histOut; onStreamFinished: {
            try { var a = JSON.parse(histOut.text.trim()||"[]");
                if (Array.isArray(a)) { root.notes = a.slice(0,40);
                    var mx = 0; for (var i=0;i<a.length;i++) if ((a[i].key||0) > mx) mx = a[i].key; root.noteSeq = mx; } } catch(e) {} } } }
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/notif-mutes.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: muteOut; onStreamFinished: {
            try { var a = JSON.parse(muteOut.text.trim()||"[]"); if (Array.isArray(a)) root.mutedApps = a; } catch(e) {} } } }
    // Do Not Disturb: suppress on-screen popups (history still records everything). Persists
    // across restarts; critical-urgency notifications still pop through so alerts aren't lost.
    property bool dnd: false
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/dnd 2>/dev/null || echo 0"]
        stdout: StdioCollector { id: dndOut; onStreamFinished: root.dnd = (dndOut.text.trim() === "1") } }
    function setDnd(v) { root.dnd = v; Quickshell.execDetached(["sh","-c","echo " + (v?"1":"0") + " > \"$HOME/.config/sea-shell/dnd\""]); }

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
            } catch (e) {}
        } } }
    function tmrSaveCfg() {
        var o = { pomoFocus: root.pomoFocusMin, pomoBreak: root.pomoBreakMin, pomoLong: root.pomoLongMin,
                  pomoEvery: root.pomoEvery, pomoDnd: root.pomoDnd, zones: root.wcZones };
        var s = JSON.stringify(o).replace(/'/g, "'\\''");
        Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && printf '%s' '" + s + "' > ~/.config/sea-shell/timers.json"]);
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
        actionsSupported: false
        bodyImagesSupported: false
        bodyMarkupSupported: true
        imageSupported: true
        onNotification: (n) => {
            var k = ++root.noteSeq;
            var app = (n.appName||"notification");
            var entry = { key: k, summary: (n.summary||""), body: (n.body||""),
                          appName: app, urgency: n.urgency,
                          time: Qt.formatDateTime(new Date(), "HH:mm") };
            root.notes = [entry].concat(root.notes).slice(0, 40);
            root.saveNotes();
            // DND or a per-app mute swallows the popup but keeps the history entry;
            // critical (urgency 2) breaks through either way so alerts aren't lost.
            if ((!root.dnd && !root.isMuted(app)) || n.urgency === 2)
                popupModel.insert(0, { key: k, summary: entry.summary, body: entry.body, appName: entry.appName, urg: n.urgency });
            // not tracked → server releases it after this handler; we've copied the fields
        }
    }
    function popDismiss(k) { for (var i=0;i<popupModel.count;i++) if (popupModel.get(i).key===k) { popupModel.remove(i); return } }
    function noteClear() { root.notes = []; popupModel.clear(); root.saveNotes() }

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
        Quickshell.execDetached(["hyprctl", "keyword", "cursor:zoom_factor", "" + z]);
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
        implicitHeight: 32; radius: 9
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
        readonly property bool vert: false
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
        readonly property real hostNW: dw.host ? (dw.host.width  || dw.host.implicitWidth)  : 0
        readonly property real hostNH: dw.host ? (dw.host.height || dw.host.implicitHeight) : 0
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
        Component.onCompleted: dw.held = dw.shown
        NumberAnimation { id: openAnim; target: cardBg; property: "openAnimFactor"; to: 1.0; duration: 165; easing.type: Easing.OutCubic }

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

        Rectangle {
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
            // per-monitor: user can turn the bar off entirely on a given output.
            // Read modelData (the Variants source), NOT bar.screen — reading screen here
            // creates a visible↔screen-mapping binding loop.
            visible: root.monBar(bar.modelData ? bar.modelData.name : "")
            // per-monitor UI scale — a 4K TV scales up while a 1080p laptop stays 1×
            readonly property real ui: root.uiFor(bar.screen)
            // which tray icon owns the shared tray menu dropdown
            property Item trayHost: null
            property var trayMenuSel: null
            // ---- auto-hide state ----
            property bool revealed: false
            property bool barHover: false
            readonly property bool fsActive: {
                var t = Hyprland.activeToplevel;
                return !!(t && t.lastIpcObject && t.lastIpcObject.fullscreen);
            }
            // the bar auto-hides when the user turned it on, or when configured to hide on fullscreen
            readonly property bool autoHiding: root.cfgAutoHide || (root.cfgHideFullscreen && bar.fsActive)
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
            Rectangle {
                id: barBg
                width: barInset.width / bar.ui
                height: barInset.height / bar.ui
                transformOrigin: Item.TopLeft
                scale: bar.ui
                radius: root.cfgRadius
                color: theme.a(root.barFillColor, root.cfgOpacity)
                // at 0% opacity the fill vanishes and so does the outline — only the chips remain
                border.width: root.cfgOpacity < 0.06 ? 0 : 1
                border.color: theme.a(theme.iris, 0.30 * Math.min(1, root.cfgOpacity / 0.5))

                Item {
                    id: horizontalBarLayout
                    anchors.fill: parent
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
                    function oidx(w) { var i = leftGroup.order ? leftGroup.order.indexOf(w) : -1; return i < 0 ? 999 : i; }
                    function xFor(w) {
                        var kids = leftGroup.children, myi = leftGroup.oidx(w), sum = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.lid === undefined || !c.visible || c.width <= 0) continue;
                            if (leftGroup.oidx(c.lid) < myi) sum += c.width + leftGroup.gap;
                        }
                        return sum;
                    }
                    function spanW() {
                        var kids = leftGroup.children, tot = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.lid === undefined || !c.visible || c.width <= 0) continue;
                            tot += c.width + leftGroup.gap;
                        }
                        return Math.max(0, tot - leftGroup.gap);
                    }
                    SeaLogo { property string lid: "lgLogo"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        size: 24
                        card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: launcher.toggle() } }
                    Grid { property string lid: "lgWork"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        columns: 99
                        rowSpacing: 6; columnSpacing: 6
                        verticalItemAlignment: Grid.AlignVCenter
                        Repeater {
                            model: Hyprland.workspaces
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                // active workspace grows along the bar's long axis
                                width:  foc ? 36 : 24
                                height: 24
                                radius: 12   // circle → pill when active
                                color: foc ? theme.iris : theme.a(theme.line,0.55)
                                border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris,0.18)
                                Behavior on width  { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Text { anchors.centerIn: parent; text: modelData.id; color: foc ? theme.bg : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: foc }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = "+modelData.id+" })") }
                            }
                        }
                    }
                    Text {
                        // the window title. Capped short so a long app class (e.g. electron apps)
                        // can't grow into the centre and push the media pill out — it's only a hint.
                        property string lid: "lgTitle"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
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
                    id: mprisDrop; host: root.barVertical ? mprisPillVert : mprisPill; shown: root.openPop ==="mpris" && root.openBar === bar
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
                                // gold badge: only appears for direct-ALSA (bit-perfect) playback, e.g. SONE.
                                // When the card being driven that way is a Moondrop, the badge names it:
                                // the model comes from the script's own registry, read straight off ALSA,
                                // so it holds even though pipewire is bypassed. Click opens that DAC's EQ.
                                //
                                // The MouseArea WRAPS the Row rather than filling it — anchors.fill on a
                                // child of a Row makes Qt refuse to lay the Row out at all ("Row will not
                                // function"), which silently deletes the badge.
                                MouseArea {
                                    visible: root.hqInfo !== ""
                                    implicitWidth: hqRow.implicitWidth; implicitHeight: hqRow.implicitHeight
                                    hoverEnabled: true
                                    cursorShape: root.dacExclusive ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (root.dacExclusive) dacPanel.toggle()
                                    Row { id: hqRow; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "verified"; sz: 13; color: theme.warn }
                                        Text { anchors.verticalCenter: parent.verticalCenter
                                            text: root.hqInfo + (root.dacExclusive ? " · " + root.dacModel : "")
                                            color: theme.warn; font.pixelSize: 10; font.family: root.cfgFont; font.bold: true } } }
                                // What it is coming OUT of. MPRIS cannot tell you this — a player knows
                                // nothing about routing — and pipewire alone can't either, since a
                                // bit-perfect player bypasses the graph entirely. A Moondrop is named
                                // from the script's registry; anything else falls back to pipewire's
                                // own name for the sink.
                                MouseArea {
                                    visible: root.player !== null
                                    implicitWidth: outRow.implicitWidth; implicitHeight: outRow.implicitHeight
                                    hoverEnabled: true
                                    cursorShape: root.dacActive ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (root.dacActive) dacPanel.toggle()
                                    Row { id: outRow; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter
                                            text: root.dacActive ? "graphic_eq" : "volume_up"; sz: 13
                                            color: root.dacActive ? theme.iris : theme.faint }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "out via " + root.outputLabel
                                            color: root.dacActive ? theme.iris : theme.sub
                                            font.pixelSize: 10; font.family: root.cfgFont; font.bold: root.dacActive } } } } }

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
                        x: (mprisDrop.card.x + mprisDrop.card.width + 10 + width > mprisDrop.swN - 8)
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
                        // ask MusicBrainz only when someone actually looks at this panel,
                        // and only once per track — same deal as the lyrics sidecar
                        onVisibleChanged: if (visible) root.fetchMeta()
                        // grow to fit the details (art + rows) so nothing clips; never shorter than the card
                        width: 288; height: Math.max(mprisDrop.card.height, detailsCol.implicitHeight + 28)
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
                                        Text { id: keyTxt
                                            anchors.left: parent.left; anchors.top: parent.top
                                            width: Math.min(implicitWidth, parent.width * 0.34); elide: Text.ElideRight
                                            text: modelData.k; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                        Text { id: valTxt
                                            anchors.left: keyTxt.right; anchors.leftMargin: 10
                                            anchors.right: parent.right; anchors.top: parent.top
                                            horizontalAlignment: Text.AlignRight
                                            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
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
                    function oidx(w) { var i = rightGroup.order ? rightGroup.order.indexOf(w) : -1; return i < 0 ? 999 : i; }
                    // x of a child = summed widths of visible siblings ordered before it (left→right)
                    function xFor(w) {
                        var kids = rightGroup.children, myi = rightGroup.oidx(w), sum = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.wid === undefined || !c.visible || c.width <= 0) continue;
                            if (rightGroup.oidx(c.wid) < myi) sum += c.width + rightGroup.gap;
                        }
                        return sum;
                    }
                    // total laid-out width → drives the right anchor and the centre pill's free-space calc
                    function spanW() {
                        var kids = rightGroup.children, tot = 0;
                        for (var k = 0; k < kids.length; k++) { var c = kids[k];
                            if (!c || c.wid === undefined || !c.visible || c.width <= 0) continue;
                            tot += c.width + rightGroup.gap;
                        }
                        return Math.max(0, tot - rightGroup.gap);
                    }

                    // ---- WEATHER dropdown (its pill is declared after the tray, below) ----
                    

                    // ---- SYSTEM TRAY (after weather) — collapsible, right-click = app menu ----
                    Grid { columns: 99; rowSpacing: 2; columnSpacing: 2
                        property string wid: "wgTray"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        horizontalItemAlignment: Grid.AlignHCenter; verticalItemAlignment: Grid.AlignVCenter
                        visible: root.cfgTray && SystemTray.items.values.length > 0
                        // collapse / expand toggle
                        Rectangle { width: 16; height: 16; radius: 4
                            visible: SystemTray.items.values.length > 0
                            color: tcm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                            Sym { anchors.centerIn: parent; text: root.trayCollapsed ? "chevron_left" : "chevron_right"; sz: 12; color: theme.sub }
                            MouseArea { id: tcm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed } }
                        Grid { columns: 99; rowSpacing: 2; columnSpacing: 2; visible: !root.trayCollapsed
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
                    

                    // ---- CONTROL CENTER (quick toggles + power profile) ----
                    Pill { owner: bar; id: ccPill; key: "cc"
                        property string wid: "wgQuick"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgQuick
                        icon: "tune"; accent: theme.frost }

                    // ---- WEATHER pill (placed after the tray) ----
                    Pill { owner: bar; id: wxPill; key: "wx"
                        property string wid: "wgWeather"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgWeather && root.wxTemp!==""; icon: root.wxIcon(root.wxCond); value: root.wxTemp; accent: theme.frost }

                    // ---- CLIPBOARD (opens the launcher in clipboard mode) ----
                    Pill { owner: bar; icon: "content_paste"; accent: theme.frost
                        property string wid: "wgClipboard"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgClipboard
                        onClicked: { root.openPop = ""; launcher.open(";") } }

                    // ---- NOTIFICATION CENTER (bell + badge) ----
                    Pill { owner: bar; id: bellPill; key: "notif"
                        property string wid: "wgNotif"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNotif
                        icon: root.dnd ? "notifications_off" : (root.notes.length>0 ? "notifications" : "notifications_none")
                        accent: root.dnd ? theme.warn : (root.notes.length>0 ? theme.iris : theme.frost)
                        value: root.dnd ? "" : (root.notes.length>0 ? String(root.notes.length) : "") }
                    

                    // ---- WIFI ----
                    Pill { owner: bar; id: wifiPill; key: "wifi"
                        property string wid: "wgWifi"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgWifi
                        icon: root.wifiOn ? "wifi" : "wifi_off"; accent: root.wifiOn ? theme.frost : theme.bad
                        }   // icon-only: SSID lives in the dropdown
                    

                    // ---- BLUETOOTH ----
                    Pill { owner: bar; id: btPill
                        property string wid: "wgBluetooth"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgBluetooth && root.btAdapter !== null
                        key: root.btAdapter ? "bt" : ""
                        icon: (!root.btAdapter || !root.btAdapter.enabled) ? "bluetooth_disabled" : (root.btActive ? "bluetooth_connected" : (root.btAdapter.discovering ? "bluetooth_searching" : "bluetooth"))
                        accent: root.btActive ? theme.iris : ((root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint)
                        // show the connected device name, plus its battery % when the device reports one
                        value: root.btActive ? (root.btName(root.btActive) + (root.btActive.batteryAvailable ? "  " + Math.round((root.btActive.battery||0)*100) + "%" : "")) : "" }

                    // ---- KDE CONNECT ----
                    // icon-only when there's nothing to say; the phone's battery is the one
                    // number worth bar space (the name would eat 150px and is in the dropdown).
                    // Colour follows the battery the same way the laptop pill does.
                    Pill { owner: bar; id: kdePill; key: "kde"
                        property string wid: "wgKdeconnect"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgKdeconnect
                        icon: root.kdeActive ? root.kdeIcon(root.kdeDev) : "phonelink_off"
                        accent: !root.kdeActive ? theme.faint
                              : (root.kdeDev.isCharging ? theme.good
                              : (root.kdeBattery >= 0 && root.kdeBattery <= 20 ? theme.bad : theme.iris))
                        value: root.kdeBattery >= 0 ? root.kdeBattery + "%" : "" }


                    // ---- CAFFEINE ---- (mug icon; lit yellow when keeping the screen awake)
                    Pill { owner: bar
                        property string wid: "wgCaffeine"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgCaffeine
                        icon: "coffee"
                        // yellow while caffeine is active (screen kept awake → hypridle killed → idleOn false)
                        accent: root.idleOn ? theme.sub : theme.warn
                        value: ""
                        onClicked: root.toggleIdle() }

                    // ---- NIGHT LIGHT ---- (warm-screen toggle; lit warm when active)
                    Pill { owner: bar
                        property string wid: "wgNight"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNightWidget
                        icon: "nightlight"
                        accent: root.nightActive ? theme.warn : theme.sub
                        value: ""
                        onClicked: root.ccToggle("night") }

                    // ---- SYSTEM MONITOR (cpu · ram · gpu) ----
                    Pill { owner: bar; id: sysPill; key: "sys"
                        property string wid: "wgSystem"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgSystem
                        icon: "speed"; value: Math.round(root.cpuUsage)+"%"
                        accent: root.loadColor(root.cpuTemp, 78, 90) }
                    

                    // ---- VOLUME ----
                    Pill { owner: bar; id: volPill; key: "vol"
                        property string wid: "wgVolume"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
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
                        property string wid: "wgBattery"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        readonly property var dev: UPower.displayDevice
                        readonly property bool charging: !UPower.onBattery
                        readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                        visible: root.cfgBattery && dev && dev.isLaptopBattery
                        key: visible ? "bat" : ""
                        icon: charging?"battery_charging_full":pct>=90?"battery_full":pct>=60?"battery_5_bar":pct>=35?"battery_3_bar":pct>=15?"battery_1_bar":"battery_alert"
                        value: pct+"%"; accent: charging?theme.good:pct<=20?theme.bad:theme.frost }
                    

                    // ---- MOONDROP DAC PILL ----
                    // Transient, like the recorder: it exists only while a DAC the
                    // panel can actually drive is plugged in.
                    //
                    // "Active" is carried by the NAME, not by colour. Colour alone
                    // can't do it: in light mode theme.iris is Qt.darker(accent,2.4)
                    // and lands within a few percent of theme.faint, and matugen can
                    // repoint the accent at any wallpaper colour — so an accent-vs-
                    // faint swap is unreadable in exactly the theme it has to work in.
                    // Icon alone = plugged in. Icon + model = audio is going through it.
                    // Left-click opens the EQ panel, right-click routes audio here.
                    Pill { owner: bar; id: dacPill; icon: "graphic_eq"
                        property string wid: "wgDac"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgDac && root.dacSupported
                        accent: root.dacActive ? theme.iris : theme.faint
                        value: root.dacActive ? root.dacModel : ""
                        maxTextW: 130
                        onClicked: dacPanel.toggle()
                        onRightClicked: if (root.dacNode) Pipewire.preferredDefaultAudioSink = root.dacNode
                    }

                    // ---- SCREEN RECORDER PILL ----
                    // Transient: it exists only while something is being recorded.
                    // Left-click stops and keeps. Right-click arms a discard, and a second
                    // right-click throws the take away — while armed the pill says so.
                    Pill { owner: bar; id: recPill
                        property string wid: "wgRec"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
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
                        property string wid: "wgClock"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgClock
                        // when a timer/pomodoro is live the pill becomes a countdown; otherwise it's the clock
                        icon: root.tmrRunning ? (root.pomoActive ? (root.pomoPhase==="focus" ? "local_fire_department" : "coffee") : "timer") : "schedule"
                        value: root.tmrRunning ? root.tmrText : Qt.formatDateTime(clock.date,"ddd d MMM · HH:mm")
                        vertValue: root.tmrRunning ? root.tmrText : Qt.formatDateTime(clock.date,"HH:mm")
                        accent: root.tmrRunning ? (root.tmrPaused ? theme.warn : (root.pomoActive && root.pomoPhase!=="focus" ? theme.good : theme.iris)) : theme.iris }
                     

                    // ---- POWER (very end) ----
                    Pill { owner: bar; id: pwrPill; key: "pwr"; icon: "power_settings_new"; accent: theme.bad
                        property string wid: "wgPower"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgPower }
                    
                }

                // dropdown windows for the END cluster — kept OUT of the rightGroup positioner:
                // a layer-surface window reads to a Grid as a full-height item, which in a vertical
                // (columns:1) bar would insert screen-tall gaps. They anchor to their host by id, so
                // their parent doesn't matter — parking them here keeps the Grid pill-only.
                Item { id: rightGroupDrops
                    // ---- CONTROL CENTER dropdown: quick toggles + power profile ----
                    Drop { screen: bar.screen
                        id: ccDrop; host: root.barVertical ? ccPillVert : ccPill; shown: root.openPop === "cc" && root.openBar === bar
                        cardW: 316; cardH: ccCol.implicitHeight + 30
                        Column { id: ccCol; anchors.fill: ccDrop.card; anchors.margins: 15; spacing: 12
                            Text { text: "quick settings"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                            // toggle tiles
                            Grid { width: parent.width; columns: 2; columnSpacing: 8; rowSpacing: 8
                                Repeater {
                                    model: [
                                        { k: "dark", onI: "dark_mode",        offI: "light_mode",        l: "Dark mode" },
                                        { k: "caf",  onI: "coffee",           offI: "coffee",            l: "Caffeine" },
                                        { k: "dnd",  onI: "do_not_disturb_on", offI: "do_not_disturb_off", l: "Do not disturb" },
                                        { k: "wifi", onI: "wifi",             offI: "wifi_off",          l: "Wi-Fi" },
                                        { k: "bt",   onI: "bluetooth",        offI: "bluetooth_disabled", l: "Bluetooth" },
                                        { k: "night", onI: "nightlight",      offI: "nightlight",        l: "Night light" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool on: root.ccActive(modelData.k)
                                        width: (parent.width - 8) / 2; height: 50; radius: 10
                                        color: on ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.4)
                                        border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.14)
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Row { anchors.left: parent.left; anchors.leftMargin: 11; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: on ? modelData.onI : modelData.offI; sz: 18; color: on ? theme.iris : theme.sub }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 26; text: modelData.l; color: on ? theme.text : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; elide: Text.ElideRight } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.ccToggle(modelData.k) }
                                    }
                                }
                            }
                            // power profile
                            Text { text: "power profile"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                            Row { width: parent.width; spacing: 6
                                Repeater {
                                    model: [ { k: "power-saver", i: "eco", l: "Saver" }, { k: "balanced", i: "balance", l: "Balanced" }, { k: "performance", i: "bolt", l: "Perf" } ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool sel: root.powerProfile === modelData.k
                                        width: (parent.width - 12) / 3; height: 44; radius: 9
                                        color: sel ? theme.iris : theme.a(theme.line, 0.4); border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Column { anchors.centerIn: parent; spacing: 2
                                            Sym { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.i; sz: 16; color: sel ? theme.bg : theme.sub }
                                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 10; font.family: root.cfgFont; font.bold: sel } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setProfile(modelData.k) }
                                    }
                                }
                            }
                            // shortcut to full settings
                            Rectangle { width: parent.width; height: 38; radius: 9
                                color: ccSetMa.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Row { anchors.centerIn: parent; spacing: 8
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "settings"; sz: 16; color: theme.frost }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "all settings"; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont } }
                                MouseArea { id: ccSetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.openPop = ""; root.openSettings(0) } }
                            }
                        }
                    }
                    Drop { screen: bar.screen
                        id: wxDrop; host: root.barVertical ? wxPillVert : wxPill; shown: root.openPop ==="wx" && root.openBar === bar
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
                        id: notifDrop; host: root.barVertical ? bellPillVert : bellPill; shown: root.openPop ==="notif" && root.openBar === bar
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
                            // ---- muted apps (per-app DND) — chips you can tap to un-mute ----
                            Column { width: parent.width; spacing: 5; visible: root.mutedApps.length > 0
                                Text { text: "muted apps"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; font.letterSpacing: 0.5 }
                                Flow { width: parent.width; spacing: 5
                                    Repeater { model: root.mutedApps
                                        delegate: Rectangle { required property var modelData
                                            height: 20; radius: 6; width: mchip.implicitWidth + 16
                                            color: mchMa.containsMouse ? theme.a(theme.warn,0.22) : theme.a(theme.warn,0.13)
                                            border.width: 1; border.color: theme.a(theme.warn,0.35)
                                            Row { id: mchip; anchors.centerIn: parent; spacing: 4
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "notifications_off"; sz: 11; color: theme.warn }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData; color: theme.sub; font.pixelSize: 10; font.family: root.cfgFont }
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "close"; sz: 11; color: theme.faint } }
                                            MouseArea { id: mchMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleMute(modelData) } } } }
                                Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) } }
                            Text { visible: root.notes.length===0; text: "no notifications"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont; topPadding: 4 }
                            Flickable { width: parent.width; height: Math.min(390, listCol.implicitHeight); contentHeight: listCol.implicitHeight; clip: true; boundsBehavior: Flickable.StopAtBounds; visible: root.notes.length>0
                                Column { id: listCol; width: parent.width; spacing: 6
                                    Repeater { model: root.notes
                                        delegate: Rectangle { required property var modelData; width: listCol.width; radius: 10
                                            implicitHeight: ec.implicitHeight + 16; color: theme.a(theme.line,0.38)
                                            border.width: 1; border.color: modelData.urgency===2 ? theme.a(theme.bad,0.45) : theme.a(theme.iris,0.12)
                                            Column { id: ec; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10; spacing: 3
                                                Item { width: parent.width; height: 16
                                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width - 46 - 26; font.bold: true }
                                                    // mute-this-app toggle
                                                    Rectangle { id: noteMute; anchors.right: noteTime.left; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                                                        width: 18; height: 16; radius: 5
                                                        readonly property bool m: root.isMuted(modelData.appName)
                                                        color: nmMa.containsMouse ? theme.a(theme.warn,0.2) : "transparent"
                                                        Sym { anchors.centerIn: parent; text: noteMute.m ? "notifications_off" : "notifications_active"; sz: 12; color: noteMute.m ? theme.warn : theme.faint }
                                                        MouseArea { id: nmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleMute(modelData.appName) } }
                                                    Text { id: noteTime; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.time; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; width: 46; horizontalAlignment: Text.AlignRight } }
                                                Text { width: parent.width; visible: modelData.summary!==""; text: modelData.summary; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; wrapMode: Text.WordWrap }
                                                Text { width: parent.width; visible: modelData.body!==""; text: modelData.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText } } } } } } } }
                    Drop { screen: bar.screen
                        id: wifiDrop; host: root.barVertical ? wifiPillVert : wifiPill; shown: root.openPop ==="wifi" && root.openBar === bar
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
                        id: btDrop; host: root.barVertical ? btPillVert : btPill; shown: root.openPop ==="bt" && root.openBar === bar
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
                    // KDE Connect: the phone's state, then the things you actually open the
                    // widget for — ring, send a file, push the clipboard, browse its storage.
                    // The settings tab is one gear away rather than the only destination.
                    Drop { screen: bar.screen
                        id: kdeDrop; host: root.barVertical ? kdePillVert : kdePill; shown: root.openPop ==="kde" && root.openBar === bar
                        cardW: 300; cardH: kdeCol.implicitHeight + 28
                        Column { id: kdeCol; anchors.fill: kdeDrop.card; anchors.margins: 14; spacing: 8
                            readonly property var dev: root.kdeDev
                            // Header
                            Item { width: parent.width; height: 26
                                Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    text: "kde connect"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 2
                                    Rectangle { width: 26; height: 26; radius: 8
                                        color: kdeRfMa.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                        Sym { anchors.centerIn: parent; text: "refresh"; sz: 15; color: theme.sub }
                                        MouseArea { id: kdeRfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { kdeWatch.running = false; kdeWatch.running = true } } }
                                    Rectangle { width: 26; height: 26; radius: 8
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
                                        height: 22; radius: 6; width: chipTxt.width + 26
                                        color: sel ? theme.a(theme.iris,0.24) : (chipMa.containsMouse ? theme.a(theme.line,0.6) : theme.a(theme.line,0.32))
                                        border.width: 1; border.color: sel ? theme.a(theme.iris,0.5) : "transparent"
                                        Row { anchors.centerIn: parent; spacing: 5
                                            Rectangle { width: 6; height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter
                                                color: !modelData.isReachable ? theme.a(theme.faint,0.55) : (modelData.isPaired ? theme.good : theme.warn) }
                                            // capped so one long hostname can't push the switcher to three rows
                                            Text { id: chipTxt; anchors.verticalCenter: parent.verticalCenter; text: modelData.name
                                                width: Math.min(implicitWidth, 104); elide: Text.ElideRight
                                                color: sel ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                        MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.kdeSel = modelData.id } } } }
                            // The device itself
                            Rectangle { width: parent.width; radius: 10; visible: kdeCol.dev !== null
                                implicitHeight: devCol.implicitHeight + 20
                                color: theme.a(theme.line, 0.32); border.width: 1
                                border.color: root.kdeActive ? theme.a(theme.iris,0.35) : theme.a(theme.iris,0.12)
                                Column { id: devCol; anchors.left: parent.left; anchors.right: parent.right
                                    anchors.top: parent.top; anchors.margins: 10; spacing: 9
                                    Row { width: parent.width; spacing: 9
                                        Rectangle { width: 34; height: 34; radius: 10; anchors.verticalCenter: parent.verticalCenter
                                            color: root.kdeActive ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.5)
                                            Sym { anchors.centerIn: parent; sz: 19; text: root.kdeIcon(kdeCol.dev)
                                                color: root.kdeActive ? theme.iris : theme.faint } }
                                        Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 43; spacing: 2
                                            Text { width: parent.width; elide: Text.ElideRight; text: kdeCol.dev ? kdeCol.dev.name : ""
                                                color: theme.text; font.pixelSize: 13; font.family: root.cfgFont; font.bold: true }
                                            Row { spacing: 6
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.kdeStatus(kdeCol.dev)
                                                    color: root.kdeActive ? theme.frost : theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                                // cellular strength, 0–4 bars
                                                Row { anchors.verticalCenter: parent.verticalCenter; spacing: 2; height: 11
                                                    visible: kdeCol.dev && kdeCol.dev.signal >= 0
                                                    Repeater { model: 4
                                                        delegate: Rectangle { required property int index
                                                            width: 3; height: 4 + index*2; radius: 1; anchors.bottom: parent.bottom
                                                            color: (kdeCol.dev && index < kdeCol.dev.signal) ? theme.frost : theme.a(theme.faint,0.35) } } } } } }
                                    StatBar { width: parent.width; label: "battery"
                                        visible: kdeCol.dev && kdeCol.dev.charge >= 0
                                        value: kdeCol.dev ? kdeCol.dev.charge : 0
                                        barColor: !kdeCol.dev ? theme.iris : (kdeCol.dev.isCharging ? theme.good : (kdeCol.dev.charge <= 20 ? theme.bad : theme.iris))
                                        rightText: kdeCol.dev ? (kdeCol.dev.charge + "%" + (kdeCol.dev.isCharging ? "  ·  charging" : "")) : "" } } }
                            // Shortcuts — greyed out when the phone hasn't loaded that plugin
                            Grid { id: kdeActs; width: parent.width; columns: 2; columnSpacing: 8; rowSpacing: 8
                                visible: root.kdeActive
                                readonly property real cw: (width - columnSpacing) / 2
                                KdeAct { width: kdeActs.cw; icon: "ring_volume"; label: "ring"; tint: theme.warn
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canRing
                                    onAct: root.kdeRun(["--ring", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "wifi_tethering"; label: "ping"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canPing
                                    onAct: root.kdeRun(["--ping", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "upload_file"; label: "send file"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canShare
                                    onAct: { root.openPop = ""; root.kdeRun(["--send-file", kdeCol.dev.id]) } }
                                KdeAct { width: kdeActs.cw; icon: "content_paste_go"; label: "clipboard"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canShare
                                    onAct: root.kdeRun(["--send-clipboard", kdeCol.dev.id]) }
                                KdeAct { width: kdeActs.cw; icon: "folder_open"; label: "browse files"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canBrowse
                                    onAct: { root.openPop = ""; root.kdeRun(["--browse", kdeCol.dev.id]) } }
                                KdeAct { width: kdeActs.cw; icon: "sms"; label: "messages"
                                    enabled: kdeCol.dev !== null && kdeCol.dev.canSms
                                    onAct: { root.openPop = ""; root.kdeRun(["--sms", kdeCol.dev.id]) } } }
                            // Pairing — the only thing that matters until the handshake is done
                            Column { width: parent.width; spacing: 6
                                visible: kdeCol.dev !== null && !kdeCol.dev.isPaired
                                Text { width: parent.width; wrapMode: Text.WordWrap
                                    visible: kdeCol.dev && (kdeCol.dev.isPairRequestedByPeer || kdeCol.dev.isPairRequested)
                                    text: "check that your device shows the key " + (kdeCol.dev ? kdeCol.dev.verificationKey : "")
                                    color: theme.sub; font.pixelSize: 10; font.family: root.cfgFont }
                                Row { width: parent.width; spacing: 8
                                    visible: kdeCol.dev && kdeCol.dev.isPairRequestedByPeer
                                    KdeAct { width: (kdeCol.width - 8)/2; icon: "check_circle"; label: "accept"; tint: theme.good
                                        onAct: root.kdeRun(["--accept", kdeCol.dev.id]) }
                                    KdeAct { width: (kdeCol.width - 8)/2; icon: "cancel"; label: "reject"; tint: theme.bad
                                        onAct: root.kdeRun(["--reject", kdeCol.dev.id]) } }
                                KdeAct { width: parent.width; icon: "link"; label: "pair with this device"; tint: theme.iris
                                    visible: kdeCol.dev && kdeCol.dev.isReachable && !kdeCol.dev.isPairRequested && !kdeCol.dev.isPairRequestedByPeer
                                    onAct: root.kdeRun(["--pair", kdeCol.dev.id]) }
                                Text { visible: kdeCol.dev && !kdeCol.dev.isReachable
                                    text: "not on this network — open the app on the device"
                                    color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont } }
                            // Unpair sits at the bottom, small and out of the way of the shortcuts
                            Item { width: parent.width; height: 16; visible: kdeCol.dev !== null && kdeCol.dev.isPaired
                                Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    text: "unpair"; color: unpMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.8)
                                    font.pixelSize: 10; font.family: root.cfgFont
                                    MouseArea { id: unpMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.kdeRun(["--unpair", kdeCol.dev.id]) } } }
                            // Nothing at all — usually the daemon just hasn't seen the phone yet
                            Column { width: parent.width; spacing: 3; visible: root.kdeDevices.length === 0
                                Text { text: "no devices"; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont }
                                Text { width: parent.width; wrapMode: Text.WordWrap
                                    text: "open KDE Connect on your phone, make sure it's on the same network, then hit refresh"
                                    color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont } } } }
                    Drop { screen: bar.screen
                        id: sysDrop; host: root.barVertical ? sysPillVert : sysPill; shown: root.openPop ==="sys" && root.openBar === bar
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
                        id: volDrop; host: root.barVertical ? volPillVert : volPill; shown: root.openPop ==="vol" && root.openBar === bar
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
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width-42-sinkBadge.width; elide: Text.ElideRight; text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: cur }
                                        Text { id: sinkBadge; anchors.verticalCenter: parent.verticalCenter; text: root.audioFmtBadge(modelData.name); visible: text!==""; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont } }
                                    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Pipewire.preferredDefaultAudioSink = modelData } } }
                            // ---- bluetooth codec — only when the current output is a BT device offering a choice ----
                            Item { height: 6; width: 1; visible: root.audioBtSink !== null }
                            Text { visible: root.audioBtSink !== null; text: "bluetooth codec"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; font.letterSpacing: 0.5 }
                            Flow { visible: root.audioBtSink !== null; width: parent.width; spacing: 6
                                Repeater { model: root.audioBtSink ? root.audioBtSink.bt_codecs : []
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool on: modelData.active
                                        implicitHeight: 24; implicitWidth: ccT.implicitWidth + 18; radius: 7
                                        color: on ? theme.a(theme.iris, 0.25) : (ccMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                                        border.width: 1; border.color: on ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                                        Text { id: ccT; anchors.centerIn: parent; text: modelData.codec; color: on ? theme.iris : theme.sub; font.pixelSize: 10; font.family: root.cfgFont; font.bold: on }
                                        MouseArea { id: ccMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioSetCodec(root.audioBtSink.name, modelData.profile) } }
                                }
                            }
                            // ---- per-app mixer (sea-audio.py, 4.0): volume slider + click the chip to change output ----
                            Item { height: 6; width: 1; visible: root.streams.length > 0 }
                            Text { visible: root.streams.length > 0; text: "apps"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; font.letterSpacing: 0.5 }
                            Repeater { model: root.streams
                                delegate: Column {
                                    required property var modelData
                                    width: parent.width; spacing: 3
                                    // name + output chip
                                    Row { width: parent.width; height: 20; spacing: 8
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "graphic_eq"; sz: 14; color: theme.faint }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 22 - appChip.width - 16; elide: Text.ElideRight
                                            text: root.streamName(modelData); color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                                        Rectangle { id: appChip; anchors.verticalCenter: parent.verticalCenter
                                            implicitWidth: acRow.implicitWidth + 14; height: 20; radius: 6
                                            color: acMa.containsMouse ? theme.a(theme.iris, 0.28) : theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.28)
                                            Row { id: acRow; anchors.centerIn: parent; spacing: 3
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "arrow_forward"; sz: 11; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.audioSinkLabelOf(modelData.id); color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont } }
                                            MouseArea { id: acMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioCycleRouteById(modelData.id) } } }
                                    // volume slider + readout
                                    Row { width: parent.width; height: 20; spacing: 8
                                        Item { width: 22; height: 1 }
                                        Slider { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 22 - 44 - 16
                                            value: modelData.audio ? modelData.audio.volume : 0
                                            onMoved: (v) => { if (modelData.audio) { modelData.audio.muted = false; modelData.audio.volume = v } } }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: 44; horizontalAlignment: Text.AlignRight
                                            text: modelData.audio ? Math.round(modelData.audio.volume * 100) + "%" : "—"; color: theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                }
                            }
                        } }
                    Drop { screen: bar.screen
                        id: batDrop; host: root.barVertical ? batPillVert : batPill; shown: root.openPop ==="bat" && root.openBar === bar
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
                                                    color: evRow.soon ? theme.frost : theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } } } } }

                            // ================= TIMER · POMODORO =================
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column { width: parent.width; spacing: 6
                                Item { width: parent.width; height: 12
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: root.pomoActive ? "POMODORO" : "TIMER"; color: theme.frost; font.pixelSize: 9; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 1 }
                                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: root.pomoActive
                                        text: "session " + (root.pomoDone + (root.pomoPhase==="focus"?1:0)); color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } }

                                // ---- active countdown ----
                                Column { width: parent.width; spacing: 6; visible: root.tmrRunning
                                    Row { width: parent.width; spacing: 10
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.tmrText; color: root.tmrPaused?theme.warn:theme.frost; font.pixelSize: 30; font.family: root.cfgFont; font.bold: true }
                                        Column { anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                            Text { text: root.pomoActive ? (root.pomoPhase==="focus"?"focus":(root.pomoPhase==="long"?"long break":"break")) : "timer"
                                                color: (root.pomoActive && root.pomoPhase!=="focus") ? theme.good : theme.iris; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true }
                                            Text { visible: root.tmrPaused; text: "paused"; color: theme.warn; font.pixelSize: 9; font.family: root.cfgFont } } }
                                    Rectangle { width: parent.width; height: 5; radius: 2.5; color: theme.a(theme.line,0.7)
                                        Rectangle { height: parent.height; radius: 2.5
                                            width: parent.width * (root.tmrTotal>0 ? Math.max(0,Math.min(1, 1 - root.tmrRemain/root.tmrTotal)) : 0)
                                            color: (root.pomoActive && root.pomoPhase!=="focus") ? theme.good : theme.iris; Behavior on width { NumberAnimation { duration: 300 } } } }
                                    Row { width: parent.width; spacing: 6
                                        Rectangle { width: (parent.width - (root.pomoActive?12:6))/(root.pomoActive?3:2); height: 30; radius: 8
                                            color: tpMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"play_arrow":"pause"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"resume":"pause"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: tpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrToggle() } }
                                        Rectangle { visible: root.pomoActive; width: (parent.width - 12)/3; height: 30; radius: 8
                                            color: tsMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "skip_next"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "skip"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: tsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoSkip() } }
                                        Rectangle { width: root.pomoActive ? (parent.width-12)/3 : (parent.width-6)/2; height: 30; radius: 8
                                            color: txMa.containsMouse ? theme.a(theme.bad,0.22) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.bad,0.25)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "stop"; sz: 14; color: theme.bad }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "stop"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: txMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrStop() } } } }

                                // ---- idle: quick timers + pomodoro ----
                                Column { width: parent.width; spacing: 6; visible: !root.tmrRunning
                                    Flow { width: parent.width; spacing: 5
                                        Repeater { model: [1,5,10,15,25]
                                            delegate: Rectangle { required property var modelData; height: 28; radius: 7; width: (parent.width - 4*5)/5
                                                color: qcMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.16)
                                                Text { anchors.centerIn: parent; text: modelData+"m"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                                MouseArea { id: qcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.timerStartMin(modelData) } } } }
                                    Rectangle { width: parent.width; height: 34; radius: 8
                                        color: psMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22); border.width:1; border.color: theme.iris
                                        Row { anchors.centerIn: parent; spacing: 7
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "local_fire_department"; sz: 16; color: psMa.containsMouse?theme.bg:theme.frost }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Start Pomodoro · " + root.pomoFocusMin + "/" + root.pomoBreakMin; color: psMa.containsMouse?theme.bg:theme.frost; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true } }
                                        MouseArea { id: psMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoStart() } }
                                    // compact config: focus / break steppers + DND toggle
                                    Row { width: parent.width; spacing: 8
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "focus"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                            Rectangle { width: 20; height: 20; radius: 6; color: fmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: fmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.max(5, root.pomoFocusMin-5); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoFocusMin; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                            Rectangle { width: 20; height: 20; radius: 6; color: fpMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "add"; sz: 12; color: theme.frost }
                                                MouseArea { id: fpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.min(120, root.pomoFocusMin+5); root.tmrSaveCfg() } } } }
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "break"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                            Rectangle { width: 20; height: 20; radius: 6; color: bmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: bmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoBreakMin = Math.max(1, root.pomoBreakMin-1); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoBreakMin; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                            Rectangle { width: 20; height: 20; radius: 6; color: bpMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "add"; sz: 12; color: theme.frost }
                                                MouseArea { id: bpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoBreakMin = Math.min(60, root.pomoBreakMin+1); root.tmrSaveCfg() } } } }
                                        Item { width: 2; height: 1 }
                                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 26; height: 22; radius: 7
                                            color: root.pomoDnd ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: root.pomoDnd?theme.a(theme.iris,0.5):theme.a(theme.line,0.9)
                                            Sym { anchors.centerIn: parent; text: root.pomoDnd?"notifications_off":"notifications"; sz: 13; color: root.pomoDnd?theme.iris:theme.faint }
                                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoDnd = !root.pomoDnd; root.tmrSaveCfg() } } } } } }

                            // ================= WORLD CLOCK =================
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column { width: parent.width; spacing: 5
                                Item { width: parent.width; height: 12
                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        text: "WORLD CLOCK"; color: theme.frost; font.pixelSize: 9; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 1 } }
                                Repeater { model: root.wcTimes
                                    delegate: Rectangle { required property var modelData; width: parent.width; height: 28; radius: 7
                                        color: wcm.containsMouse ? theme.a(theme.line,0.4) : "transparent"
                                        Row { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "public"; sz: 13; color: theme.faint }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 120; elide: Text.ElideRight; text: modelData.label; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.day; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.time; color: theme.frost; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true } }
                                        MouseArea { id: wcm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                        Rectangle { anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter; visible: wcm.containsMouse
                                            width: 20; height: 20; radius: 6; color: theme.a(theme.bad,0.22)
                                            Sym { anchors.centerIn: parent; text: "close"; sz: 12; color: theme.bad }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wcRemove(modelData.zone) } } } }
                                Text { visible: root.wcTimes.length===0; text: "add a city below"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                Flow { width: parent.width; spacing: 5; topPadding: 2
                                    Repeater { model: root.wcPresets
                                        delegate: Rectangle { required property var modelData
                                            visible: root.wcZones.indexOf(modelData.z) < 0
                                            height: 22; radius: 6; width: visible ? (wcAddRow.implicitWidth + 14) : 0
                                            color: wcaMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.35); border.width: 1; border.color: theme.a(theme.iris,0.18)
                                            Row { id: wcAddRow; anchors.centerIn: parent; spacing: 3
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "add"; sz: 11; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: theme.text; font.pixelSize: 9; font.family: root.cfgFont } }
                                            MouseArea { id: wcaMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.wcAdd(modelData.z) } } } } } } }
                    Drop { screen: bar.screen
                        id: pwrDrop; host: root.barVertical ? pwrPillVert : pwrPill; shown: root.openPop ==="pwr" && root.openBar === bar
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
                                               {i:"logout",l:"log out",c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }",col:theme.frost},
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
                } // closes rightGroupDrops
                } // closes horizontalBarLayout

                // ---------- START: verticalBarLayout ----------
                ColumnLayout {
                    id: verticalBarLayout
                    anchors.fill: parent
                    anchors.topMargin: root.cfgRadius + 6
                    anchors.bottomMargin: root.cfgRadius + 6
                    // reveal via opacity (not visible:false) — see horizontalBarLayout note
                    opacity: root.barVertical ? 1 : 0
                    enabled: root.barVertical
                    z: root.barVertical ? 1 : 0
                    spacing: 12
                    
                    // --- TOP: Logo & Workspaces ---
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8
                        
                        SeaLogo {
                            id: logoVert
                            size: 24
                            card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: launcher.toggle() }
                        }
                        
                        // Workspace list (vertical switcher)
                        Column {
                            spacing: 6
                            anchors.horizontalCenter: parent.horizontalCenter
                            Repeater {
                                model: Hyprland.workspaces
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                    width: 24
                                    height: foc ? 36 : 24
                                    radius: 12
                                    color: foc ? theme.iris : theme.a(theme.line, 0.55)
                                    border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris, 0.18)
                                    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                    Text { anchors.centerIn: parent; text: modelData.id; color: foc ? theme.bg : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: foc }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = "+modelData.id+" })") }
                                }
                            }
                        }
                    }
                    
                    // --- MIDDLE: Media & Resource Indicators ---
                    ColumnLayout {
                        Layout.fillHeight: true; Layout.alignment: Qt.AlignHCenter
                        spacing: 10
                        Item { Layout.fillHeight: true } // spacer
                        
                        // Media pill (Vertical variant)
                        Rectangle {
                            id: mprisPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgMpris && root.player !== null
                            Sym { anchors.centerIn: parent; text: "music_note"; sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "mpris") ? "" : "mpris" }
                                onDoubleClicked: if(root.player) root.player.togglePlaying()
                            }
                        }
                        
                        // System monitor pill (Vertical variant)
                        Rectangle {
                            id: sysPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgSystem
                            Sym { anchors.centerIn: parent; text: "speed"; sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "sys") ? "" : "sys" }
                            }
                        }
                        
                        Item { Layout.fillHeight: true } // spacer
                    }
                    
                    // --- BOTTOM: SysTray, Quick Actions, Clock & Power ---
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8
                        
                        // System tray (vertical stack)
                        ColumnLayout {
                            spacing: 4
                            Layout.alignment: Qt.AlignHCenter
                            Rectangle {
                                width: 22; height: 22; radius: 11
                                color: theme.a(theme.line, 0.4)
                                Sym { anchors.centerIn: parent; text: root.trayCollapsed ? "expand_less" : "expand_more"; sz: 12; color: theme.sub }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed }
                            }
                            ColumnLayout {
                                spacing: 4
                                visible: !root.trayCollapsed
                                Repeater {
                                    model: SystemTray.items
                                    delegate: Item {
                                        id: trayItemVert
                                        required property SystemTrayItem modelData
                                        width: 18; height: 18
                                        Image {
                                            width: 36; height: 36; anchors.centerIn: parent; scale: 0.5
                                            asynchronous: true; source: trayItemVert.modelData.icon
                                            sourceSize.width: 96; sourceSize.height: 96; smooth: true; mipmap: true
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton|Qt.RightButton
                                            onClicked: (e)=>{
                                                if (e.button===Qt.LeftButton) { trayItemVert.modelData.activate(); return }
                                                if (root.openPop==="tray" && bar.trayHost===trayItemVert) { root.openPop=""; return }
                                                bar.trayHost = trayItemVert; bar.trayMenuSel = trayItemVert.modelData; root.openBar = bar; root.openPop = "tray"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Quick Settings shortcut (Vertical variant)
                        Rectangle {
                            id: ccPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgQuick
                            Sym { anchors.centerIn: parent; text: "tune"; sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "cc") ? "" : "cc" }
                            }
                        }
                        
                        // Network status pill (Vertical variant)
                        Rectangle {
                            id: wifiPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgWifi
                            Sym { anchors.centerIn: parent; text: root.wifiOn ? "wifi" : "wifi_off"; sz: 16; color: root.wifiOn ? theme.frost : theme.bad }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "wifi") ? "" : "wifi" }
                            }
                        }
                        
                        // Bluetooth status pill (Vertical variant)
                        Rectangle {
                            id: btPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgBluetooth && root.btAdapter !== null
                            Sym { anchors.centerIn: parent; text: "bluetooth"; sz: 16; color: root.btActive ? theme.iris : theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "bt") ? "" : "bt" }
                            }
                        }
                        
                        // KDE Connect pill (Vertical variant)
                        Rectangle {
                            id: kdePillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgKdeconnect
                            Sym { anchors.centerIn: parent; text: root.kdeActive ? root.kdeIcon(root.kdeDev) : "phonelink_off"; sz: 16
                                color: root.kdeActive ? theme.iris : theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "kde") ? "" : "kde" }
                            }
                        }

                        // Volume control (Vertical variant)
                        Rectangle {
                            id: volPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgVolume
                            readonly property var au: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
                            readonly property int vol: au ? Math.round(au.volume*100) : 0
                            Sym { anchors.centerIn: parent; text: !volPillVert.au||volPillVert.au.muted ? "volume_off" : volPillVert.vol<34?"volume_mute":volPillVert.vol<67?"volume_down":"volume_up"; sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "vol") ? "" : "vol" }
                            }
                        }
                        
                        // Battery status pill (Vertical variant)
                        Rectangle {
                            id: batPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            readonly property var dev: UPower.displayDevice
                            readonly property bool charging: !UPower.onBattery
                            readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                            visible: root.cfgBattery && dev && dev.isLaptopBattery
                            Sym { anchors.centerIn: parent; text: batPillVert.charging?"battery_charging_full":batPillVert.pct>=90?"battery_full":"battery_5_bar"; sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "bat") ? "" : "bat" }
                            }
                        }

                        // Notification pill (Vertical variant)
                        Rectangle {
                            id: bellPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgNotif
                            Sym { anchors.centerIn: parent; text: root.dnd ? "notifications_off" : (root.notes.length>0 ? "notifications" : "notifications_none"); sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "notif") ? "" : "notif" }
                            }
                        }
                        
                        // Vertical Stacked Clock
                        ColumnLayout {
                            id: clockPillVert
                            spacing: 1
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgClock
                            Text {
                                text: Qt.formatDateTime(clock.date, "HH")
                                color: theme.text; font.pixelSize: 13; font.bold: true; font.family: root.cfgFont
                                Layout.alignment: Qt.AlignHCenter
                            }
                            Text {
                                text: Qt.formatDateTime(clock.date, "mm")
                                color: theme.iris; font.pixelSize: 13; font.bold: true; font.family: root.cfgFont
                                Layout.alignment: Qt.AlignHCenter
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.openBar = bar; root.openPop = (root.openPop === "cal") ? "" : "cal" }
                            }
                        }
                        
                        // Power Control (Vertical variant)
                        Rectangle {
                            id: pwrPillVert
                            width: 32; height: 32; radius: 16
                            color: theme.a(theme.bad, 0.22); border.width: 1; border.color: theme.bad
                            visible: root.cfgPower
                            Sym { anchors.centerIn: parent; text: "power_settings_new"; sz: 16; color: theme.bad }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.openBar = bar; root.openPop = (root.openPop === "pwr") ? "" : "pwr" }
                            }
                        }
                        
                        Item { height: 4; width: 1 }
                    }
                }
            }
            }

            // register this bar's windows with the ONE shared focus grab at root —
            // a grab per bar fights the other monitors' grabs and insta-closes dropdowns
            Item { Component.onCompleted: { root.grabWins = root.grabWins.concat([bar, ccDrop, wxDrop, wifiDrop, btDrop, kdeDrop, volDrop, batDrop, calDrop, pwrDrop, notifDrop, mprisDrop, trayDrop, sysDrop]) } }
        }
    }

 // ===== on-screen notification popups (top-right, under the bar) =====
    PanelWindow {
        id: notifWin
        readonly property real ui: root.uiFor(notifWin.screen)
        readonly property real baseW: 370
        anchors { top: true; bottom: true; left: true; right: true }
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
            anchors.topMargin: 50 * notifWin.ui
            anchors.rightMargin: 12 * notifWin.ui
            width: notifWin.baseW
            spacing: 8
            transformOrigin: Item.TopRight
            scale: notifWin.ui
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
        id: osdWin
        readonly property real ui: root.uiFor(osdWin.screen)
        anchors { bottom: true; left: true; right: true }
        margins { bottom: 80 * osdWin.ui }
        implicitHeight: 60 * osdWin.ui
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:osd"
        exclusionMode: ExclusionMode.Ignore
        visible: root.osdKind !== ""
        mask: Region { item: osdCard }
        Rectangle {
            id: osdCard
            anchors.centerIn: parent
            scale: osdWin.ui                 // authored native; scaled around its centre
            width: 250; height: 54; radius: root.cfgRadius
            color: theme.a(theme.bg, root.dropOpacity); border.width: 1; border.color: theme.a(theme.iris,0.34)
            Row { anchors.fill: parent; anchors.margins: 16; spacing: 13
                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.osdIcon; sz: 24; color: theme.frost }
                Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width-52; spacing: 6
                    Row { width: parent.width
                        Text { text: root.osdKind==="vol" ? "volume" : (root.osdKind==="zoom" ? "magnifier" : "brightness"); color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                        Item { width: parent.width - 80; height: 1 }
                        Text { text: root.osdKind==="zoom" ? (root.zoomFactor.toFixed(2).replace(/\.?0+$/,"")+"×") : (Math.round(root.osdVal*100)+"%"); color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont } }
                    Rectangle { width: parent.width; height: 6; radius: 3; color: theme.a(theme.line,0.85)
                        Rectangle { width: parent.width*Math.max(0,Math.min(1,root.osdVal)); height: parent.height; radius: 3; color: theme.iris
                            Behavior on width { NumberAnimation { duration: 90 } } } }
                }
            }
        }
    }

    // (the alt-tab switcher HUD lives up top, next to its state + the `switcher` IPC —
    //  a single thumbnail-based overlay; there is deliberately no second one here.)

    // ===== Exposé Mission Control HUD overlay =====
    property bool exposeActive: false
    function toggleExpose() { root.exposeActive = !root.exposeActive }
    
    PanelWindow {
        id: exposeWin
        readonly property real ui: root.uiFor(exposeWin.screen)
        visible: root.exposeActive
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:expose"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        
        // dim background scrim
        Rectangle {
            anchors.fill: parent; color: theme.bg          // fully opaque — a focus mode, no desktop bleed-through
            MouseArea { anchors.fill: parent; onClicked: root.exposeActive = false }
            
            FocusScope {
                anchors.fill: parent; focus: exposeWin.visible
                Keys.onEscapePressed: root.exposeActive = false
                
                ColumnLayout {
                    anchors.centerIn: parent
                    scale: exposeWin.ui              // authored native; scaled around its centre
                    // clamp in native space so the scaled HUD still fits the screen
                    width: Math.min(parent.width / exposeWin.ui - 100, 1000)
                    height: Math.min(parent.height / exposeWin.ui - 100, 700); spacing: 20
                    
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
                                clip: true
                                // compose captures into one FBO so a ScreencopyView texture node can't
                                // leak a stray thumbnail outside the card (the same fix as the switcher)
                                layer.enabled: true

                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 12; spacing: 10
                                    
                                    // Workspace header
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text { text: "Workspace " + modelData.id; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont }
                                        Item { Layout.fillWidth: true }
                                        Text { text: modelData.name; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                    }
                                    
                                    // Live thumbnails of the windows in this workspace — click to jump
                                    Flow {
                                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                                        Repeater {
                                            model: {
                                                var m = Hyprland.toplevels ? Hyprland.toplevels.values : [];
                                                var out = [];
                                                for (var i = 0; i < m.length; i++) {
                                                    var t = m[i];
                                                    // use the LIVE .workspace ref, not lastIpcObject.workspace —
                                                    // the latter is a stale snapshot, so windows land in the wrong card.
                                                    if (t && t.workspace && t.workspace.id === wsBox.modelData.id) out.push(t);
                                                }
                                                return out;
                                            }
                                            delegate: Rectangle {
                                                id: winTile
                                                required property var modelData
                                                readonly property string cls: ("" + (modelData.lastIpcObject.class || "")).toLowerCase()
                                                width: 122; height: 60; radius: 7; clip: true
                                                color: theme.a(theme.bg, 0.55)
                                                border.width: 1; border.color: theme.a(theme.iris, 0.14)
                                                ScreencopyView {
                                                    id: winScv
                                                    anchors.fill: parent
                                                    captureSource: winTile.modelData.wayland
                                                    live: root.exposeActive
                                                    visible: hasContent
                                                }
                                                IconImage {
                                                    anchors.centerIn: parent; implicitSize: 24; asynchronous: true
                                                    visible: !winScv.hasContent
                                                    source: Quickshell.iconPath(winTile.cls, "application-x-executable")
                                                }
                                                // title strip
                                                Rectangle {
                                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                                    height: 15; color: theme.a(theme.panel, 0.9)
                                                    Text {
                                                        anchors.fill: parent; anchors.leftMargin: 5; anchors.rightMargin: 5
                                                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                                        text: winTile.modelData.lastIpcObject.class || "window"
                                                        color: theme.sub; font.pixelSize: 8; font.family: root.cfgFont
                                                    }
                                                }
                                                // click anywhere → focus that window
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + winTile.modelData.lastIpcObject.address + "' })"); root.exposeActive = false }
                                                }
                                                // close button — declared last so it wins the click in its corner
                                                Rectangle {
                                                    anchors { top: parent.top; right: parent.right; margins: 3 }
                                                    width: 16; height: 16; radius: 8
                                                    color: winClMa.containsMouse ? theme.bad : theme.a(theme.bg, 0.7)
                                                    Sym { anchors.centerIn: parent; text: "close"; sz: 11; color: winClMa.containsMouse ? theme.bg : theme.faint }
                                                    MouseArea {
                                                        id: winClMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: Hyprland.dispatch("hl.dsp.window.close({ window = 'address:" + winTile.modelData.lastIpcObject.address + "' })")
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
}
