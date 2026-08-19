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
import QtQuick.Effects
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

    // app dock — its own layer-shell surface per monitor, off unless enabled in settings.
    // It shares cfgMonitors with the bar so a monitor turned off there can turn the dock off
    // independently (`{"<name>": {"bar": false, "dock": false}}`).
    Dock {
        id: appDock
        dockEnabled: root.cfgDock
        edge: root.cfgDockEdge
        iconSize: root.cfgDockIcon
        mode: root.cfgDockMode
        zoomEnabled: root.cfgDockZoom
        showRunning: root.cfgDockRunning
        showLabels: root.cfgDockLabels
        surfaceOpacity: root.dropOpacity
        cfgMonitors: root.cfgMonitors
        cfgScale: root.cfgScale
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

    // The first-run tour. Resident like settings, and for the same reason: it owns an IPC
    // target ("welcome") that Settings → System calls to show it again, and it decides for
    // itself whether this is a first run. A Loader rather than a type, because a QML file
    // whose name starts lowercase cannot be used as one.
    Loader { id: welcomeLoader; asynchronous: true; active: true; source: Qt.resolvedUrl("welcome.qml") }
    function openSettings(tab) { if (settingsLoader.item) settingsLoader.item.openTab(tab) }

    // Screen recorder chooser — resident overlay, toggled via its "recorder" IPC
    // (SUPER+R). It owns the whole SUPER+R semantic: stops a running recording,
    // otherwise opens. `recording` is fed from the status poll above so it knows which.
    // The exclusive hold is passed through so it can warn that system audio recorded
    // from a monitor will be silent while something is playing bit-perfect past pipewire.
    RecorderPanel {
        id: recPanel
        recording: root.recordingActive
        exclusiveHold: root.exclusiveHold
        exclusiveName: root.exclHolder
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
    // Show the switcher ONLY on the focused monitor, not mirrored onto every screen —
    // a full card on each output reads like a second switcher "behind" the real one.
    readonly property var switcherScreen: {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        if (fm && fm.name) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) return scrs[i];
        return scrs.length ? scrs[0] : null;
    }
    // every open window, most-recently-used first (focusHistoryID 0 = current)
    // Membership is decided by the WAYLAND handle, never by lastIpcObject: `Hyprland.toplevels`
    // keeps ghost entries whose wayland handle is null, and — the reason ALT+Tab used to do
    // nothing at all — lastIpcObject goes empty on a long-lived shell until something calls
    // refreshToplevels(). Gating on it meant every window was filtered out and switcherStep()
    // bailed on n === 0. hyprctl data is now used only to ENRICH (MRU order), never to include.
    readonly property var switcherWins: {
        try {
            var m = (Hyprland && Hyprland.toplevels) ? Hyprland.toplevels.values : [];
            var out = [];
            for (var i=0; i<m.length; i++) {
                var t = m[i];
                if (t && t.wayland && t.wayland.appId && (""+t.wayland.appId).trim() !== "") out.push(t);
            }
            out.sort(function(a, b) {
                try {
                    var ai = (a && a.lastIpcObject && a.lastIpcObject.focusHistoryID !== undefined) ? a.lastIpcObject.focusHistoryID : 9999;
                    var bi = (b && b.lastIpcObject && b.lastIpcObject.focusHistoryID !== undefined) ? b.lastIpcObject.focusHistoryID : 9999;
                    return ai - bi;
                } catch(e) { return 0; }
            });
            return out;
        } catch(e) { return []; }
    }
    // The selection tracks the WINDOW, not its index — refreshToplevels() lands a moment after
    // the switcher opens and can reorder the list under the highlight.
    property var switcherSelWin: null
    readonly property int switcherSel: {
        var i = root.switcherWins.indexOf(root.switcherSelWin);
        return i < 0 ? 0 : i;
    }
    function switcherStep(dir) {
        Hyprland.refreshToplevels();          // titles + MRU order; async, list already stands on its own
        var wins = root.switcherWins, n = wins.length; if (n === 0) return;
        if (!root.switcherOpen) { root.switcherOpen = true; root.switcherSelWin = wins[n > 1 ? (dir > 0 ? 1 : n - 1) : 0]; }
        else root.switcherSelWin = wins[((root.switcherSel + dir) % n + n) % n];
    }
    function switcherCommit() {
        if (!root.switcherOpen) return; root.switcherOpen = false;
        var w = root.switcherSelWin; if (!w) return;
        if (w.lastIpcObject && w.lastIpcObject.address)
            Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + w.lastIpcObject.address + "' })");
        else if (w.wayland)
            w.wayland.activate();             // no hyprctl data yet — the wayland handle still focuses
    }
    IpcHandler {
        target: "switcher"
        function next(): void { root.switcherStep(1) }
        function prev(): void { root.switcherStep(-1) }
        function commit(): void { root.switcherCommit() }
        function cancel(): void { root.switcherOpen = false }
    }

    // ---------- wallpaper switch transition ----------
    // swww/awww animate a static→static change themselves, but ANIMATED wallpapers go to
    // mpvpaper, which has no transition at all: switching one means `pkill mpvpaper`, a gap,
    // then a fresh process — a hard cut with a black flash. Most of this user's library is
    // video, so the backend transition almost never ran.
    //
    // The compositor can't fix that, but the shell can: cover the seam with a full-screen
    // layer, let the swap happen behind it, and uncover once the new wallpaper is up. It
    // works for EVERY backend — mpvpaper, awww, hyprpaper — because it never touches them.
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
    // What it switched TO. The panel has to sit covered for as long as mpvpaper needs to put
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
    // Kept short on purpose. The covered hold below is fixed by how long mpvpaper takes to
    // show a first frame, so the slides are the only part worth trimming — at 0.45× the whole
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
            // mpvpaper needs its pkill + 0.2s settle + process start before the first frame is
            // up; lifting the curtain earlier just shows the flash we came here to hide. Static
            // wallpapers are ready far sooner, but awww is doing its own transition underneath
            // by then, so a slightly long hold costs nothing there.
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

    // One curtain per monitor. Bottom layer: above the background (where mpvpaper and awww
    // draw) but below every real window, so it only ever darkens visible wallpaper — never
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
                                source: root.wallPanelThumb ? "file://" + root.wallPanelThumb : ""
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
                        mono: true
                        sz: Math.round(Tok.tLabel * root.uiFor(modelData))
                        font.weight: 600
                        font.letterSpacing: 1.6
                        font.capitalization: Font.AllUppercase
                        color: Tok.accent
                        text: root.wallPanelDir > 0 ? "next  →" : "←  previous"
                    }
                    IndText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        mono: true
                        sz: Math.round(Tok.tDense * root.uiFor(modelData))
                        color: Tok.ink
                        text: root.wallPanelName
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, parent.parent.width * 0.6)
                        horizontalAlignment: Text.AlignHCenter
                    }
                    // The wait, drawn. mpvpaper's first frame is not ours to hurry, so the
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
                radius: Tok.rCard
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
                            // hyprctl class when we have it, wayland app id until then
                            readonly property string cls: ("" + ((modelData.lastIpcObject && modelData.lastIpcObject.class)
                                                                || (modelData.wayland && modelData.wayland.appId) || "")).toLowerCase()
                            width: 208; height: 150; radius: Tok.r
                            clip: true
                            color: sel ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.35)
                            border.width: sel ? 2 : 1
                            border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                            // live thumbnail of the window (falls back to the app icon until a
                            // frame arrives, or if the window has no capturable wayland handle)
                            Rectangle {
                                anchors { top: parent.top; left: parent.left; right: parent.right; margins: 6 }
                                height: 96; radius: Tok.r; clip: true; color: theme.a(theme.bg, 0.55)
                                ScreencopyView {
                                    id: thumbScv
                                    anchors.fill: parent
                                    captureSource: (swTile.modelData && swTile.modelData.wayland) ? swTile.modelData.wayland : null
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
                                    text: "" + ((swTile.modelData.lastIpcObject && (swTile.modelData.lastIpcObject.title || swTile.modelData.lastIpcObject.class))
                                                || (swTile.modelData.wayland && (swTile.modelData.wayland.title || swTile.modelData.wayland.appId)) || "window")
                                    color: swTile.sel ? theme.text : theme.sub; font.pixelSize: 11; font.family: root.cfgFont; font.bold: swTile.sel
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: root.switcherSelWin = swTile.modelData
                                onClicked: { root.switcherSelWin = swTile.modelData; root.switcherCommit() }
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
    property bool cfgPower: true
    property bool cfgQuick: true          // Control Center pill (quick toggles + power profile)
    property bool cfgUpdates: true        // pending pacman/AUR update count
    property bool cfgNet: true            // live network throughput
    property bool cfgNightWidget: false   // Night-light toggle pill on the bar
    // ---------- bar shape, workspaces, and the mark ----------
    // All three used to be facts about the bar rather than settings: one continuous strip,
    // workspaces as circles that grow, and the sea-shell logo, always. The first thing on
    // somebody's bar should be able to say what the MACHINE is.
    property string cfgBarShape: "bar"      // bar | pills
    property string cfgWsStyle:  "grow"     // grow | pill | circle
    property string cfgWsLabel:  "arabic"   // what the workspace is CALLED on the bar
    property string cfgBarLogo:  "auto"     // auto | sea | cachy | <distro glyph> | custom
    property string cfgBarLogoPath: ""

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

    function wsLabelFor(n) {
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
    // order of the right-hand bar widgets (drag-reorder in Settings → Bar widgets).
    // Values are the widget ids; the bar positions each right-group pill by its index here,
    // so reordering this list reorders the pills. Unknown/absent ids fall to the far end.
    // wgMpris is the centre pill and ignores its position; wgRec is the transient recorder.
    readonly property var defaultWidgetOrder: ["wgMpris","wgTray","wgQuick","wgUpdates","wgNet","wgWeather","wgClipboard","wgNotif","wgWifi","wgBluetooth","wgKdeconnect","wgCaffeine","wgNight","wgSystem","wgMic","wgVolume","wgBattery","wgRec","wgClock","wgPower"]
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

    // Dropdowns stay glassy (semi-transparent + blur). The bright-background washout
    // is solved by the `xray` layer rule (sea.conf) — the blur samples the wallpaper,
    // not whatever bright window is behind — so a low opacity reads fine over the dark
    // wallpaper. Light mode needs more body (a translucent light card over the dark
    // wallpaper would go muddy), so it sits higher.
    readonly property real dropOpacity: root.cfgLight ? Math.max(0.55, root.cfgOpacity)
                                                      : Math.max(0.35, root.cfgOpacity)
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; touch \"$d/kitty-matugen.conf\"; [ -f \"$d/appearance.json\" ] || printf '{\"radius\":14,\"opacity\":0.80,\"height\":42,\"accent\":\"#63c7dd\",\"font\":\"monospace\"}' > \"$d/appearance.json\"; echo \"$d/appearance.json\""]
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
            reload();                                  // pull the latest bytes (needed for live changes)
            var t = text(); if(!t || !t.trim()) return; var j = JSON.parse(t);
            if (j.radius  !== undefined) root.cfgRadius  = j.radius;
            if (j.opacity !== undefined) root.cfgOpacity = j.opacity;
            if (j.wpTransitionDur !== undefined) root.cfgWpTransitionDur = j.wpTransitionDur;
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
            if (j.font    !== undefined && (""+j.font).length>0)   root.cfgFont   = j.font;
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
            if (j.wgPower !== undefined) root.cfgPower = !!j.wgPower;
            if (j.wgQuick !== undefined) root.cfgQuick = !!j.wgQuick;
            if (j.wgUpdates !== undefined) root.cfgUpdates = !!j.wgUpdates;
            if (j.wgNet !== undefined) root.cfgNet = !!j.wgNet;
            if (j.wgNight !== undefined) root.cfgNightWidget = !!j.wgNight;
            if (j.barShape === "bar" || j.barShape === "pills") root.cfgBarShape = j.barShape;
            if (j.wsStyle === "grow" || j.wsStyle === "pill" || j.wsStyle === "circle") root.cfgWsStyle = j.wsStyle;
            if (j.wsLabel !== undefined && (""+j.wsLabel).length > 0) root.cfgWsLabel = ""+j.wsLabel;
            if (j.barLogo !== undefined && (""+j.barLogo).length > 0) root.cfgBarLogo = ""+j.barLogo;
            if (j.barLogoPath !== undefined) root.cfgBarLogoPath = ""+j.barLogoPath;
            if (j.autoHide !== undefined) root.cfgAutoHide = !!j.autoHide;
            if (j.hideFullscreen !== undefined) root.cfgHideFullscreen = !!j.hideFullscreen;
            if (j.night !== undefined) root.cfgNight = !!j.night;
            if (j.nightTemp !== undefined) root.cfgNightTemp = j.nightTemp;
            if (j.nightAuto !== undefined) root.cfgNightAuto = !!j.nightAuto;
            if (j.sysShow !== undefined && Array.isArray(j.sysShow) && j.sysShow.length > 0) root.cfgSysShow = j.sysShow;
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
    Timer { interval: 8000; running: true; repeat: true; triggeredOnStart: true
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
    property bool  micMuted: false
    property real  micVol:   0
    property string micName: ""
    Process { id: micProc; running: true
        command: ["sh","-c","wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null; "
                          + "wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -m1 node.nick"]
        stdout: StdioCollector { id: micOut; onStreamFinished: {
            var t = micOut.text;
            var m = t.match(/Volume:\s*([0-9.]+)/);
            root.micVol   = m ? parseFloat(m[1]) : 0;
            root.micMuted = t.indexOf("MUTED") >= 0;
            var n = t.match(/node\.nick\s*=\s*"([^"]*)"/);
            root.micName = n ? n[1] : "";
        } } }
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: micProc.running = true }
    function micToggle() {
        Quickshell.execDetached(["sh","-c","wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"]);
        micSettle.restart();
    }
    // act, then re-sample: wpctl can refuse, and a pill that reports what it was clicked to say
    // rather than what is true is the bug IndToggle had.
    Timer { id: micSettle; interval: 250; repeat: false; onTriggered: micProc.running = true }

    // ---------- wifi ----------
    property var wifiList: []
    property int wifiSeen: 0          // distinct SSIDs the scan found, before the list is capped
    readonly property bool wifiScanning: wifiScan.running
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
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true; onTriggered: wifiStatus.running = true }
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
            out.sort(function(a,b){ return b.signal - a.signal });
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
    Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.wifiRescan(false) }
    // dropdown open → the list has to be live: re-probe on open (triggeredOnStart) and keep
    // re-probing, so signal bars move and vanished APs drop off without a manual poke.
    Timer { interval: 8000; running: root.openPop === "wifi"; repeat: true; triggeredOnStart: true
        onTriggered: root.wifiRescan(true) }
    property string wifiPwFor: ""     // ssid awaiting an inline password
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
        stdout: StdioCollector { id: wupOut; onStreamFinished: {
            var ok = wupOut.text.indexOf("successfully") >= 0;
            if (!ok && root.wifiRetry !== "") root.wifiPwFor = root.wifiRetry;   // no/bad profile → ask
            else root.wifiPwFor = "";
            root.wifiRetry = ""; wifiRefresh.start();
        } } }
    function wifiConnect(s, secure) {
        var e = s.replace(/'/g,"");
        if (secure) {
            // Only try the stored profile if one actually EXISTS. This used to fire `con up` at
            // every secured network including ones never seen before, which always failed — so
            // joining a new network cost a guaranteed round-trip through nmcli before the
            // password field appeared. settings.qml had the savedCons check; the bar didn't.
            if (root.wifiSaved.indexOf(s) >= 0) {
                root.wifiRetry = s;
                wifiUp.command = ["sh","-c","nmcli con up id '"+e+"' 2>&1"];
                wifiUp.running = true; return;
            }
            root.wifiPwFor = s; return;       // never seen → ask straight away
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
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true
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
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: vpnScan.running = true }
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
        if (k === "game") return root.gameOn;
        return false;
    }
    function ccToggle(k) {
        if (k === "dark") { Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-toggle-theme.sh").toString().replace("file://","")]); return; }
        if (k === "caf")  { root.toggleIdle(); return; }
        if (k === "dnd")  { root.setDnd(!root.dnd); return; }
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
    // only poll while a bar is visible; 3s is a good live/quiet balance
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: sysProc.running = true }
    // WHICH of those the bar pill actually shows.
    //
    // sea-sysmon.sh has been sampling all eleven values every 3s since the pill was written, and
    // the pill rendered exactly one of them — so a machine with a 6GB dGPU had its VRAM measured
    // on every tick and displayed nowhere. The metric list is a setting because there is no right
    // answer: a laptop wants battery-cheap CPU, a gaming box wants VRAM, and both are one line.
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
    Timer { interval: 2000; repeat: true; running: root.cfgNet; triggeredOnStart: true
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
    Timer { interval: 60000; repeat: true; running: true
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
    Timer { interval: 30 * 60 * 1000; repeat: true; running: root.cfgUpdates; triggeredOnStart: true
        onTriggered: updProc.running = true }
    function updRefresh() { updProc.running = true }
    // Upgrades run in a terminal on purpose: pacman asks questions (replace this? keep that?) and
    // a silent background upgrade that hits a prompt would hang forever with nothing to answer it.
    function updRun() {
        root.openPop = "";
        Quickshell.execDetached(["sh","-c","kitty --hold sh -c 'paru -Syu; echo; echo done'"]);
    }

    // ---------- game mode ----------
    // sea-gamemode.sh owns the SYSTEM side (effects, power profile, mpvpaper) and writes its
    // state file; the bar owns DND and the indicator. One owner per setting — the script never
    // touches root.dnd and the bar never touches blur, so neither can fight the other.
    // Watching the file rather than only reacting to our own IPC means running the script from
    // a terminal, a keybind or the panel all behave identically.
    property bool gameOn: false
    property bool gameWasDnd: false
    Process { running: true
        // create it if absent: a FileView cannot watch a path that has never existed
        command: ["sh","-c","f=\"${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode.json\"; [ -f \"$f\" ] || printf '{\"on\":false}' > \"$f\"; echo \"$f\""]
        stdout: StdioCollector { id: gmPathOut; onStreamFinished: gmFile.path = gmPathOut.text.trim() } }
    FileView {
        id: gmFile; path: ""; watchChanges: true
        function apply() { try {
            reload();
            var t = text(); if (!t || !t.trim()) return;
            root.applyGame(!!JSON.parse(t).on);
        } catch (e) {} }
        // Same trap as Tok.qml: with blockLoading the bytes are present when construction
        // finishes and NO load signal is emitted, so onLoaded alone never fires and the
        // bar draws its first frame against the defaults regardless.
        Component.onCompleted: apply()
        onLoaded: apply()
        onFileChanged: apply()
    }
    // Mirrors how the pomodoro handles DND: remember whether DND was ALREADY on, so leaving game
    // mode does not un-silence notifications the user had deliberately silenced.
    function applyGame(v) {
        if (v === root.gameOn) return;
        if (v) { root.gameWasDnd = root.dnd; root.setDnd(true); }
        else if (!root.gameWasDnd) root.setDnd(false);
        root.gameOn = v;
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
            var entry = { key: k, summary: (n.summary||""), body: (n.body||""),
                          appName: app, urgency: n.urgency,
                          time: Qt.formatDateTime(new Date(), "HH:mm") };
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
            if ((!root.dnd && !root.isMuted(app)) || n.urgency === 2)
                popupModel.insert(0, { key: k, summary: entry.summary, body: entry.body,
                                       appName: entry.appName, urg: n.urgency,
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
    function noteClear() {
        for (var k in root.noteObjs) root.noteRelease(k);
        root.notes = []; popupModel.clear(); root.saveNotes();
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
            text: ch.title; color: theme.frost; font.pixelSize: 9; font.family: root.cfgFont
            font.bold: true; font.letterSpacing: 1 }
        Text { anchors.right: chev.left; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter
            text: ch.summary; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont }
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
            radius: Tok.rCard
            // Flat, and translucent in step with the bar: dropOpacity tracks cfgOpacity so the
            // cards and the bar read as one material. What was removed is the DECORATION that
            // used to ride on top — a two-stop gradient, a "matte-glass" rim and a white
            // highlight hairline, three stacked layers imitating frosted glass. The see-through
            // is the feature; the fake glass was not.
            color: Tok.alpha(Tok.surface, root.dropOpacity)
            border.width: 1; border.color: Tok.ruleHard
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
                try {
                    var t = Hyprland.activeToplevel;
                    return !!(t && t.lastIpcObject && t.lastIpcObject.fullscreen);
                } catch(e) { return false; }
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
                radius: Tok.rCard
                // The opacity slider stays live — a see-through bar is a deliberate feature here
                // (at 0% the fill and outline both vanish and only the chips remain), so it is
                // left alone. The rim is the part that changes: a hairline rule rather than an
                // accent tint, so the accent goes back to marking active state only.
                // In PILL mode the strip itself carries nothing: the three clusters grow
                // their own grounds below, and one continuous background behind them would
                // just be the bar again with extra outlines drawn on it.
                color: root.barPills ? "transparent" : theme.a(root.barFillColor, root.cfgOpacity)
                border.width: (root.barPills || root.cfgOpacity < 0.06) ? 0 : 1
                border.color: Tok.ruleHard

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
                    Rectangle {
                        z: -1
                        visible: root.barPills && leftGroup.width > 0
                        anchors.fill: leftGroup
                        anchors.margins: -6
                        anchors.leftMargin: -9
                        anchors.rightMargin: -9
                        radius: Tok.rCard
                        color: theme.a(root.barFillColor, root.cfgOpacity)
                        border.width: root.cfgOpacity < 0.06 ? 0 : 1
                        border.color: Tok.ruleHard
                    }
                    Rectangle {
                        z: -1
                        visible: root.barPills && rightGroup.width > 0
                        anchors.fill: rightGroup
                        anchors.margins: -6
                        anchors.leftMargin: -9
                        anchors.rightMargin: -9
                        radius: Tok.rCard
                        color: theme.a(root.barFillColor, root.cfgOpacity)
                        border.width: root.cfgOpacity < 0.06 ? 0 : 1
                        border.color: Tok.ruleHard
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
                    BarLogo { property string lid: "lgLogo"; x: leftGroup.xFor(lid); anchors.verticalCenter: parent.verticalCenter
                        size: 24
                        kind: root.logoKind
                        imagePath: root.cfgBarLogoPath
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
                        text: {
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
                                    width: pcTxt.width + 18; height: 20; radius: Tok.r
                                    color: cur ? theme.a(theme.iris,0.28) : (pcMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.5))
                                    border.width: 1; border.color: cur ? theme.iris : theme.a(theme.line,0.9)
                                    Text { id: pcTxt; anchors.centerIn: parent; text: (root.players[index].identity||"player").toLowerCase()
                                        color: cur ? theme.text : theme.sub; font.pixelSize: 9; font.family: root.cfgFont }
                                    MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.playerSel = index } } } }

                        // ---- ART, with the level meter riding its bottom edge ----
                        //
                        // The art was an 84px thumbnail beside three lines of text, and the cava
                        // meter was a 38px band under it doing nothing a shorter one could not. The
                        // art is the one thing in here worth looking at, so it takes the full width;
                        // the meter sits on it and costs no height at all.
                        // ClippingRectangle, not Rectangle: `clip: true` on a plain Rectangle clips
                        // children to its BOUNDING BOX and ignores the radius entirely, so the art
                        // kept four square corners inside a rounded frame no matter what radius was
                        // set. Quickshell's ClippingRectangle clips to the rounded shape itself.
                        ClippingRectangle {
                            id: artBox
                            // SQUARE, because cover art is — a 0.62 box cropped the top and bottom off
                            // every sleeve to make a shape nothing is delivered in. At full panel width
                            // it then dominated everything under it, so it sits at 62% and centred:
                            // still the anchor, no longer the entire panel.
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.round(parent.width * 0.62); height: width
                            radius: Tok.r
                            color: theme.a(theme.line, 0.6)
                            border.width: 1; border.color: theme.a(theme.iris, 0.25)
                            Image { id: artImg; anchors.fill: parent; asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                source: (root.player && root.player.trackArtUrl) ? root.player.trackArtUrl : ""
                                visible: status === Image.Ready }
                            Sym { anchors.centerIn: parent; text: "music_note"; sz: 46; color: theme.faint
                                visible: !artImg.visible }
                            // The meter sits ON the art, so it has to stay out of its way: a slim
                            // band of hairlines rather than the slab of blocks it was, and a scrim
                            // that only fades in under the band itself instead of a hard 32px shelf
                            // cutting across the bottom third of every sleeve.
                            Rectangle { anchors.left: parent.left; anchors.right: parent.right
                                anchors.bottom: parent.bottom; height: 22
                                visible: root.vizBars.length > 0 && artImg.visible
                                color: theme.a(theme.bg, 0.34) }
                            Row { id: vizRow
                                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                anchors.leftMargin: 8; anchors.rightMargin: 8; anchors.bottomMargin: 6
                                height: 12; spacing: 3
                                Repeater { model: root.vizBars.length
                                    delegate: Rectangle { required property int index
                                        width: Math.max(1, (vizRow.width - (root.vizBars.length-1)*3) / Math.max(1, root.vizBars.length))
                                        height: Math.max(1.5, (root.vizBars[index]||0)/100*12)
                                        anchors.bottom: parent.bottom; radius: 0
                                        color: theme.a(theme.iris, 0.55 + 0.45*((root.vizBars[index]||0)/100)) } } } }

                        // ---- title · artist — album folded onto the artist line, one row saved ----
                        Column { width: parent.width; spacing: 2
                            Text { width: parent.width; elide: Text.ElideRight
                                text: root.player ? (root.player.trackTitle||"\u2014") : "\u2014"
                                color: theme.text; font.pixelSize: 17; font.family: root.cfgFont; font.bold: true }
                            Text { width: parent.width; elide: Text.ElideRight; visible: text !== ""
                                text: {
                                    if (!root.player) return "";
                                    var a = root.player.trackArtist || "", al = root.player.trackAlbum || "";
                                    return (a && al) ? a + "  \u00b7  " + al : (a || al);
                                }
                                color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont } }

                        // ---- seek ----
                        Column { width: parent.width; spacing: 5; visible: root.player && root.player.length>0
                            Item { width: parent.width; height: 12
                                Rectangle { id: seekTrack; anchors.verticalCenter: parent.verticalCenter; width: parent.width
                                    height: seekMa.containsMouse||seekMa.pressed ? 6 : 4; radius: Tok.r; color: theme.a(theme.line,0.85)
                                    Behavior on height { NumberAnimation { duration: 90 } }
                                    Rectangle { height: parent.height; radius: Tok.r; color: theme.iris
                                        width: parent.width * (root.player && root.player.length>0 ? Math.max(0,Math.min(1, root.mprisPos/root.player.length)) : 0) } }
                                // the handle exists only while you are pointing at the bar
                                Rectangle { visible: seekMa.containsMouse || seekMa.pressed
                                    width: 10; height: 10; radius: Tok.rSmall; color: theme.iris
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: Math.max(0, Math.min(parent.width - width,
                                        seekTrack.width * (root.player && root.player.length>0 ? root.mprisPos/root.player.length : 0) - width/2)) }
                                MouseArea { id: seekMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: (root.player && root.player.canSeek) ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    function seekTo(x) { if (!root.player || !root.player.canSeek || !(root.player.length>0)) return;
                                        var f = Math.max(0, Math.min(1, x/width)); root.player.position = f*root.player.length; root.mprisPos = f*root.player.length }
                                    onPressed: (e)=> seekTo(e.x)
                                    onPositionChanged: (e)=> { if (pressed) seekTo(e.x) } } }
                            Item { width: parent.width; height: 12
                                IndText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    mono: true; sz: 10; color: theme.sub; text: root.fmtTime(root.mprisPos) }
                                // REMAINING, not total. Mid-track the number you want is how much is
                                // left, and the total is already implied by the bar. Mono and tabular
                                // so it stops twitching — the old row used the UI face, so the whole
                                // line re-measured itself on every tick.
                                IndText { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    mono: true; sz: 10; color: theme.faint
                                    text: "-" + root.fmtTime(Math.max(0, (root.player ? root.player.length : 0) - root.mprisPos)) } } }

                        // ---- transport: ONE primary, the rest recede ----
                        // Five same-weight buttons made you read the row to find play. It is now the
                        // only filled control in the panel, which is the whole point of an accent.
                        // The row is ALWAYS five slots wide — 32·36·48·36·32 — so play sits on the
                        // panel's axis by construction. Hiding unsupported controls was what broke
                        // that: a Row drops invisible children from layout and re-centres on what is
                        // left, so a player that reports loop but not shuffle pushed play off-axis,
                        // and one that reports neither made the row silently lose two buttons.
                        // Unsupported now reads as unavailable — dimmed and inert — which is a fact
                        // about the player, not a reason to rearrange the furniture.
                        // Every button anchors its OWN verticalCenter: a Row lays children out left
                        // to right and leaves y at 0, so the 48px play button hung 6px lower than the
                        // 36px ones beside it and only looked centred because it is the biggest thing
                        // in the row.
                        Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 8; height: 48
                            Rectangle { width: 32; height: 32; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                                readonly property bool can: root.player ? root.player.shuffleSupported : false
                                opacity: can ? 1.0 : 0.32
                                color: (can && sh.containsMouse) ? theme.a(theme.iris,0.16) : "transparent"
                                Sym { anchors.centerIn: parent; text: "shuffle"; sz: 17; color: (root.player&&root.player.shuffle) ? theme.iris : theme.faint }
                                MouseArea { id: sh; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: parent.can ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if(parent.can && root.player) root.player.shuffle = !root.player.shuffle } }
                            Rectangle { width: 36; height: 36; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter; color: pv.containsMouse?theme.a(theme.iris,0.16):"transparent"
                                Sym { anchors.centerIn: parent; text: "skip_previous"; sz: 22; color: (root.player&&root.player.canGoPrevious)?theme.text:theme.faint }
                                MouseArea { id: pv; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.previous() } }
                            Rectangle { width: 48; height: 48; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter; color: theme.iris
                                opacity: pp.containsMouse ? 0.85 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                                Sym { anchors.centerIn: parent; text: (root.player&&root.player.isPlaying)?"pause":"play_arrow"; sz: 27; color: Tok.accentInk }
                                MouseArea { id: pp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.togglePlaying() } }
                            Rectangle { width: 36; height: 36; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter; color: nx.containsMouse?theme.a(theme.iris,0.16):"transparent"
                                Sym { anchors.centerIn: parent; text: "skip_next"; sz: 22; color: (root.player&&root.player.canGoNext)?theme.text:theme.faint }
                                MouseArea { id: nx; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.player) root.player.next() } }
                            Rectangle { width: 32; height: 32; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                                readonly property bool can: root.player ? root.player.loopSupported : false
                                opacity: can ? 1.0 : 0.32
                                color: (can && lp.containsMouse) ? theme.a(theme.iris,0.16) : "transparent"
                                Sym { anchors.centerIn: parent; sz: 17
                                    text: (root.player&&root.player.loopState===MprisLoopState.Track) ? "repeat_one" : "repeat"
                                    color: (root.player&&root.player.loopState!==MprisLoopState.None) ? theme.iris : theme.faint }
                                MouseArea { id: lp; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: parent.can ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { if(!parent.can || !root.player) return; root.player.loopState = root.player.loopState===MprisLoopState.None ? MprisLoopState.Playlist : root.player.loopState===MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None } } } }

                        // ---- signal chain ----
                        // The one thing no other shell can tell you: where the audio is actually
                        // going, and whether it is arriving untouched. It was two 10px lines wedged
                        // under the album name. It is the most specific fact this panel holds, so it
                        // gets a strip of its own and reads like the instrument readout it is.
                        Rectangle {
                            width: parent.width; height: 26; radius: Tok.r
                            visible: root.player !== null
                            color: theme.a(theme.line, 0.35)
                            border.width: 1
                            border.color: theme.a(theme.line,0.9)
                            Row { anchors.left: parent.left; anchors.leftMargin: 8
                                anchors.right: hqChip.left; anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter
                                    text: "volume_up"; sz: 13; color: theme.faint }
                                IndText { anchors.verticalCenter: parent.verticalCenter; mono: true; sz: 9
                                    text: "OUT"; color: theme.faint; font.letterSpacing: 1 }
                                Text { anchors.verticalCenter: parent.verticalCenter
                                    text: root.outputLabel; elide: Text.ElideRight
                                    color: theme.sub
                                    font.pixelSize: 11; font.family: root.cfgFont } }
                            IndChip { id: hqChip
                                anchors.right: parent.right; anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.hqInfo !== ""
                                text: root.hqInfo + (root.exclusiveHold ? " \u00b7 exclusive" : "")
                                tone: "warn" } }

                        // ---- player volume ----
                        Row { width: parent.width; spacing: 8; visible: root.player ? root.player.volumeSupported : false
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_down"; sz: 15; color: theme.faint }
                            Item { width: parent.width - 48; height: 12; anchors.verticalCenter: parent.verticalCenter
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: Tok.r; color: theme.a(theme.line,0.85)
                                    Rectangle { height: parent.height; radius: Tok.r; color: theme.a(theme.iris,0.8)
                                        width: parent.width * (root.player ? Math.max(0,Math.min(1,root.player.volume)) : 0) } }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    function setV(x) { if (root.player) root.player.volume = Math.max(0, Math.min(1, x/width)) }
                                    onPressed: (e)=> setV(e.x); onPositionChanged: (e)=> { if (pressed) setV(e.x) } } }
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "volume_up"; sz: 15; color: theme.faint } }

                        // details (left) + lyrics (right) toggles — each panel opens BESIDE the card as a sidecar
                        Row { width: parent.width; spacing: 8; height: 26
                            Rectangle { width: (parent.width-8)/2; height: 26; radius: Tok.r
                                color: dtMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.4)
                                border.width: 1; border.color: root.infoOpen ? theme.a(theme.iris,0.5) : theme.a(theme.line,0.9)
                                Row { anchors.centerIn: parent; spacing: 6
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "info"; sz: 14; color: root.infoOpen ? theme.iris : theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.infoOpen ? "hide details" : "details"
                                        color: root.infoOpen ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                MouseArea { id: dtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.infoOpen = !root.infoOpen } }
                            Rectangle { width: (parent.width-8)/2; height: 26; radius: Tok.r
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
                        width: 340; height: mprisDrop.card.height
                        // right of the card; flips to the left near the screen edge
                        x: (mprisDrop.card.x + mprisDrop.card.width + 10 + width > mprisDrop.swN - 8)
                           ? mprisDrop.card.x - width - 10 : mprisDrop.card.x + mprisDrop.card.width + 10
                        y: mprisDrop.card.y
                        radius: Tok.rCard; color: Tok.alpha(Tok.surface, root.dropOpacity)
                        border.width: 1; border.color: Tok.ruleHard
                        Column { anchors.fill: parent; anchors.margins: 13; spacing: 8
                            Row { width: parent.width; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; sz: 15; color: theme.iris }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont }
                                Item { width: parent.width - 150; height: 1 }
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; spacing: 5
                                    Repeater { model: [{k:"r",l:"あ→a"},{k:"t",l:"EN"}]
                                        delegate: Rectangle { required property var modelData
                                            readonly property bool on: modelData.k==="r" ? root.cfgLyrRomaji : root.cfgLyrTrans
                                            height: 18; radius: Tok.rSmall; width: lxT.implicitWidth + 12
                                            color: on ? theme.a(theme.iris,0.28) : theme.a(theme.line,0.5)
                                            border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                            Text { id: lxT; anchors.centerIn: parent; text: modelData.l
                                                color: on ? theme.text : theme.faint; font.pixelSize: 9; font.family: root.cfgFont }
                                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: modelData.k==="r" ? root.lyrToggleRomaji() : root.lyrToggleTrans() } } }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.lyricsState==="ok" ? "synced" : ""; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            // height was hardcoded to `- 34` against a header that has since grown a
                            // row of 18px chips, so the list ran past the bottom of the panel
                            Item { width: parent.width; height: parent.height - 44
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="loading"; text: "fetching lyrics…"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
                                Text { anchors.centerIn: parent; visible: root.lyricsState==="none"; text: "no lyrics found"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont }
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
                                            font.pixelSize: index===root.lyrIdx ? 14 : 12; font.bold: index===root.lyrIdx; font.family: root.cfgFont
                                            Behavior on color { ColorAnimation { duration: 150 } } }
                                        Text { width: parent.width; visible: parent.parent.sub2 !== ""
                                            text: parent.parent.sub2; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                                            color: index===root.lyrIdx ? theme.iris : theme.faint
                                            font.pixelSize: index===root.lyrIdx ? 11 : 10; font.family: root.cfgFont
                                            font.italic: true } }
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
                        radius: Tok.rCard; color: Tok.alpha(Tok.surface, root.dropOpacity)
                        border.width: 1; border.color: Tok.ruleHard
                        Column { id: detailsCol; anchors.fill: parent; anchors.margins: 14; spacing: 10
                            Row { width: parent.width; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "info"; sz: 15; color: theme.iris }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "track details"; color: theme.text; font.pixelSize: 12; font.bold: true; font.family: root.cfgFont } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris,0.2) }
                            // large album art
                            // ClippingRectangle for the same reason the player's art is one: a plain
                            // Rectangle clips to its bounding box and leaves the image square-cornered
                            // inside a rounded frame.
                            ClippingRectangle { anchors.horizontalCenter: parent.horizontalCenter
                                width: Math.min(parent.width, 150); height: width; radius: Tok.r
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

                    // ---- PENDING UPDATES ----
                    Pill { owner: bar; id: updPill; key: "upd"
                        property string wid: "wgUpdates"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgUpdates
                        icon: root.updTotal > 0 ? "system_update_alt" : "task_alt"
                        accent: root.updTotal > 0 ? theme.warn : theme.frost
                        value: root.updTotal > 0 ? String(root.updTotal) : "" }

                    // ---- NETWORK THROUGHPUT ----
                    // No dropdown: the pill IS the readout, and the per-interface detail lives in
                    // the Dashboard where there is room for it. Clicking opens Network settings.
                    Pill { owner: bar; id: netPill; key: ""
                        property string wid: "wgNet"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
                        visible: root.cfgNet
                        icon: "swap_vert"
                        accent: (root.netRx + root.netTx) > 262144 ? theme.iris : theme.frost
                        value: root.netFmt(root.netRx) + "  " + root.netFmt(root.netTx)
                        vertValue: root.netFmt(root.netRx + root.netTx)
                        maxTextW: 140
                        onClicked: root.openSettings(2) }

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

                    // ---- MICROPHONE ----
                    // Muted is the state worth shouting about, so it takes the crit colour: an open
                    // mic you think is muted is the failure that matters, and the reverse is worse.
                    Pill { owner: bar; id: micPill; key: "mic"
                        property string wid: "wgMic"; x: rightGroup.xFor(wid); anchors.verticalCenter: parent.verticalCenter
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
                        icon: "speed"; value: root.sysPillText
                        accent: root.sysMetrics[root.sysShown[0]].c() }
                    

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
                    // ---- UPDATES dropdown: what is pending, and one button to install it ----
                    Drop { screen: bar.screen
                        id: updDrop; host: updPill; shown: root.openPop === "upd" && root.openBar === bar
                        cardW: 340; cardH: updCol.implicitHeight + 30
                        Column { id: updCol; anchors.fill: updDrop.card; anchors.margins: 15; spacing: 10
                            Row { width: parent.width
                                Text { text: "updates"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true; font.letterSpacing: 0.8 }
                                Item { width: parent.width - 120; height: 1 }
                                Text { text: root.updChecking ? "checking…" : (root.updRepo + " repo · " + root.updAur + " aur")
                                    color: theme.faint; font.pixelSize: 10; font.family: Tok.mono } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.16) }

                            Text { visible: root.updTotal === 0 && !root.updChecking
                                text: "everything is up to date"; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont }

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
                                            text: u.nw; color: theme.sub; font.pixelSize: 10; font.family: Tok.mono }
                                    }
                                }
                            }
                            Text { visible: root.updList.length > 12
                                text: "+" + (root.updList.length - 12) + " more not shown"
                                color: theme.faint; font.pixelSize: 10; font.family: Tok.mono }

                            Row { width: parent.width; spacing: 8
                                Rectangle { width: (parent.width - 8) * 0.62; height: 34; radius: Tok.r
                                    color: updGoMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22)
                                    border.width: 1; border.color: theme.iris
                                    opacity: root.updTotal > 0 ? 1 : 0.45
                                    Row { anchors.centerIn: parent; spacing: 7
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "download"; sz: 15
                                            color: updGoMa.containsMouse ? Tok.accentInk : theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "update now"
                                            color: updGoMa.containsMouse ? Tok.accentInk : theme.text; font.pixelSize: 12; font.family: root.cfgFont } }
                                    MouseArea { id: updGoMa; anchors.fill: parent; hoverEnabled: true
                                        enabled: root.updTotal > 0
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.updRun() } }
                                Rectangle { width: (parent.width - 8) * 0.38; height: 34; radius: Tok.r
                                    color: updReMa.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    Row { anchors.centerIn: parent; spacing: 6
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "refresh"; sz: 15; color: theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "check"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont } }
                                    MouseArea { id: updReMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor; onClicked: root.updRefresh() } }
                            }
                        }
                    }

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
                                        { k: "night", onI: "nightlight",      offI: "nightlight",        l: "Night light" },
                                        { k: "game", onI: "sports_esports",   offI: "sports_esports",    l: "Game mode" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool on: root.ccActive(modelData.k)
                                        width: (parent.width - 8) / 2; height: 50; radius: Tok.r
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
                                        width: (parent.width - 12) / 3; height: 44; radius: Tok.r
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
                            Rectangle { width: parent.width; height: 38; radius: Tok.r
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
                                text: "no menu"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont; leftPadding: 6; topPadding: 4
                            }
                            Repeater { model: { try { return trayMenu.children ? trayMenu.children : [] } catch(e) { return [] } }
                                delegate: Rectangle { required property var modelData
                                    width: parent.width; height: (modelData && modelData.isSeparator) ? 7 : 28; radius: Tok.r
                                    color: (modelData && !modelData.isSeparator && em.containsMouse) ? theme.a(theme.iris,0.16) : "transparent"
                                    Rectangle { visible: !!(modelData && modelData.isSeparator); anchors.verticalCenter: parent.verticalCenter; x: 5; width: parent.width-10; height: 1; color: theme.a(theme.line,0.8) }
                                    Row { visible: !!(modelData && !modelData.isSeparator); anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; spacing: 8
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: (modelData && modelData.text) ? modelData.text : ""; color: (modelData && modelData.enabled)?theme.text:theme.faint; font.pixelSize: 12; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-22 }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: !!(modelData && modelData.hasChildren); text: "chevron_right"; sz: 14; color: theme.sub } }
                                    MouseArea { id: em; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !!(modelData && !modelData.isSeparator)
                                        onClicked: { try { if(modelData && !modelData.hasChildren){ modelData.triggered(); root.openPop="" } } catch(e) { root.openPop=""; } } } } } } }
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
                                        width: dndRow.width + 16; height: 22; radius: Tok.r
                                        color: root.dnd ? theme.a(theme.warn, 0.2) : (dndMa.containsMouse ? theme.a(theme.line, 0.75) : theme.a(theme.line, 0.5))
                                        border.width: 1; border.color: root.dnd ? theme.a(theme.warn, 0.5) : "transparent"
                                        Row { id: dndRow; anchors.centerIn: parent; spacing: 4
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: root.dnd ? "do_not_disturb_on" : "do_not_disturb_off"; sz: 13; color: root.dnd ? theme.warn : theme.sub }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "DND"; color: root.dnd ? theme.warn : theme.sub; font.pixelSize: 10; font.family: root.cfgFont; font.bold: root.dnd } }
                                        MouseArea { id: dndMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setDnd(!root.dnd) } }
                                    // clear all
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter
                                        visible: root.notes.length > 0
                                        width: clrTxt.implicitWidth + 16; height: 22; radius: Tok.r
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
                                            height: 20; radius: Tok.r; width: mchip.implicitWidth + 16
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
                                        delegate: Rectangle { id: nrow; required property var modelData; width: listCol.width; radius: Tok.r
                                            implicitHeight: ec.implicitHeight + 16; color: theme.a(theme.line,0.38)
                                            border.width: 1; border.color: modelData.urgency===2 ? theme.a(theme.bad,0.45) : theme.a(theme.iris,0.12)
                                            Column { id: ec; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10; spacing: 3
                                                Item { width: parent.width; height: 16
                                                    Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width - 46 - 26; font.bold: true }
                                                    // mute-this-app toggle
                                                    Rectangle { id: noteMute; anchors.right: noteTime.left; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                                                        width: 18; height: 16; radius: Tok.r
                                                        readonly property bool m: root.isMuted(modelData.appName)
                                                        color: nmMa.containsMouse ? theme.a(theme.warn,0.2) : "transparent"
                                                        Sym { anchors.centerIn: parent; text: noteMute.m ? "notifications_off" : "notifications_active"; sz: 12; color: noteMute.m ? theme.warn : theme.faint }
                                                        MouseArea { id: nmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleMute(modelData.appName) } }
                                                    Text { id: noteTime; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.time; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; width: 46; horizontalAlignment: Text.AlignRight } }
                                                Text { width: parent.width; visible: modelData.summary!==""; text: modelData.summary; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; wrapMode: Text.WordWrap }
                                                Text { width: parent.width; visible: modelData.body!==""; text: modelData.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText }
                                                // The actions were recorded on every notification and drawn on
                                                // none of them here, so anything that timed out or arrived
                                                // during DND landed in history with its buttons in the data
                                                // and nowhere on screen — a Reply you could see the trace of
                                                // and not press.
                                                //
                                                // They only fire while the sending app still holds the
                                                // notification open; once the server releases it the button is
                                                // inert, so it goes visibly dead rather than staying pressable
                                                // and quietly doing nothing.
                                                Flow { width: parent.width; spacing: 5; topPadding: 3
                                                    visible: nrow.modelData.actions !== undefined && nrow.modelData.actions.length > 0
                                                    Repeater { model: nrow.modelData.actions || []
                                                        delegate: Rectangle { id: nact
                                                            required property var modelData
                                                            readonly property bool live: root.noteLive(nrow.modelData.key)
                                                            height: 22; radius: Tok.r; width: nactT.implicitWidth + 18
                                                            opacity: nact.live ? 1.0 : 0.4
                                                            color: (nact.live && naMa.containsMouse) ? theme.a(theme.iris,0.24) : theme.a(theme.line,0.55)
                                                            border.width: 1
                                                            border.color: nact.live ? theme.a(theme.iris,0.35) : theme.a(theme.line,0.9)
                                                            Text { id: nactT; anchors.centerIn: parent
                                                                text: nact.modelData.t; color: nact.live ? theme.text : theme.faint
                                                                font.pixelSize: 10; font.family: root.cfgFont }
                                                            MouseArea { id: naMa; anchors.fill: parent; hoverEnabled: true
                                                                cursorShape: nact.live ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                                onClicked: if (nact.live) root.noteInvoke(nrow.modelData.key, nact.modelData.i) } } } } } } } } } } }
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
                                    width: 26; height: 26; radius: Tok.r
                                    color: rfm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                    Sym { anchors.centerIn: parent; text: "refresh"; sz: 15; color: theme.sub }
                                    MouseArea { id: rfm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.wifiRescan(true) } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Repeater { model: root.wifiList
                                delegate: Column { id: netRow; required property var modelData; width: parent.width; spacing: 3
                                    readonly property bool asking: root.wifiPwFor === netRow.modelData.ssid
                                    readonly property bool saved: root.wifiSaved.indexOf(netRow.modelData.ssid) >= 0
                                    readonly property string secLbl: root.wifiSecLabel(netRow.modelData.sec)
                                    // ONE chip per row, carrying whichever fact is worth the width here.
                                    // An unencrypted or WEP network is a warning and always wins; past
                                    // that, "remembered" is what explains the row's behaviour (it joins
                                    // without asking), and only an unknown network needs its scheme named.
                                    readonly property string chipText:
                                          netRow.secLbl === "OPEN" || netRow.secLbl === "WEP" ? netRow.secLbl
                                        : netRow.modelData.active                             ? ""
                                        : netRow.saved                                        ? "SAVED"
                                        : netRow.secLbl
                                    readonly property string chipTone:
                                          netRow.secLbl === "OPEN" || netRow.secLbl === "WEP" ? "warn"
                                        : netRow.saved                                        ? "accent" : "neutral"
                                    Rectangle { width: parent.width; height: 34; radius: Tok.r
                                        color: netRow.modelData.active ? theme.a(theme.iris,0.18) : (netRow.asking ? theme.a(theme.iris,0.10) : (wm.containsMouse ? theme.a(theme.line,0.45) : "transparent"))
                                        border.width: netRow.modelData.active ? 1 : 0; border.color: theme.a(theme.iris,0.3)
                                        // base click zone sits UNDER the forget hitbox
                                        MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { if(netRow.modelData.active) return; if(netRow.asking) root.wifiPwFor=""; else root.wifiConnect(netRow.modelData.ssid, netRow.modelData.secure) } }
                                        // Anchored rather than laid out in a Row: the old row sized the
                                        // SSID by subtracting magic numbers for whatever might sit to its
                                        // right, and the forget button — anchored to the same right edge —
                                        // was drawn straight over the trailing glyph.
                                        Sym { id: sigIcon
                                            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                            text: netRow.modelData.signal>66?"signal_wifi_4_bar":netRow.modelData.signal>33?"network_wifi_3_bar":"network_wifi_1_bar"
                                            sz: 16; color: netRow.modelData.active ? theme.iris : theme.faint }
                                        Row { id: rightBits
                                            anchors.right: parent.right; anchors.rightMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                            // yields the right edge to the forget button rather than
                                            // being overdrawn by it
                                            visible: !(netRow.saved && (wm.containsMouse || fgm.containsMouse))
                                            IndChip { anchors.verticalCenter: parent.verticalCenter
                                                visible: netRow.chipText !== ""; text: netRow.chipText; tone: netRow.chipTone }
                                            // The scan sorts on this and the dropdown re-probes the air
                                            // every 8s to keep it moving — but it only ever reached the
                                            // screen as one of three icon buckets, so the number that
                                            // decides which network to join was the one thing the panel
                                            // would not tell you. Mono and tabular so it cannot reflow
                                            // the row from under the cursor between polls.
                                            IndText { anchors.verticalCenter: parent.verticalCenter
                                                mono: true; sz: 11; width: 18; horizontalAlignment: Text.AlignRight
                                                text: netRow.modelData.signal
                                                color: netRow.modelData.active ? theme.text : theme.sub } }
                                        Text { anchors.left: sigIcon.right; anchors.leftMargin: 8
                                            anchors.right: rightBits.left; anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideRight; text: netRow.modelData.ssid
                                            color: netRow.modelData.active ? theme.text : theme.sub
                                            font.pixelSize: 12; font.family: root.cfgFont; font.bold: netRow.modelData.active }
                                        // forget — only for remembered networks, and only on hover so it can't be hit by accident
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; anchors.rightMargin: 6
                                            width: 24; height: 24; radius: Tok.rSmall
                                            visible: netRow.saved && wm.containsMouse || fgm.containsMouse
                                            color: fgm.containsMouse ? theme.a(theme.bad, 0.22) : "transparent"
                                            Sym { anchors.centerIn: parent; text: "delete"; sz: 14; color: fgm.containsMouse ? theme.bad : theme.faint }
                                            MouseArea { id: fgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: root.wifiForget(netRow.modelData.ssid) } } }
                                    // inline password field
                                    Row { width: parent.width; height: 34; visible: netRow.asking; spacing: 6
                                        Rectangle { width: parent.width-42; height: 32; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: pwIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                            TextInput { id: pwIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; verticalAlignment: TextInput.AlignVCenter
                                                echoMode: TextInput.Password; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; clip: true; focus: netRow.asking
                                                onAccepted: root.wifiJoin(netRow.modelData.ssid, text)
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: pwIn.text===""; text: "password ↵"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont } } }
                                        Rectangle { width: 36; height: 32; radius: Tok.r; color: jm.containsMouse?theme.iris:theme.a(theme.iris,0.2); border.width: 1; border.color: theme.iris
                                            Sym { anchors.centerIn: parent; text: "arrow_forward"; sz: 14; color: jm.containsMouse?theme.bg:theme.frost }
                                            MouseArea { id: jm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wifiJoin(netRow.modelData.ssid, pwIn.text) } } } } }
                            Text { visible: root.wifiList.length===0
                                text: root.wifiScanning ? "scanning…" : "no networks in range"
                                color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont; topPadding: 4 }
                            // The list has always been capped at the top 8 by signal and never said so,
                            // which reads as "these are all the networks there are" when it is not.
                            Text { visible: root.wifiSeen > root.wifiList.length
                                text: "+" + (root.wifiSeen - root.wifiList.length) + " weaker, hidden"
                                color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; topPadding: 3 }

                            // ---- VPN Section ----
                            Item { height: 2; width: 1 }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 4; width: 1 }

                            // Cloudflare WARP row
                            //
                            // It sat at 11px sub-ink with a faint icon while the networks above it were
                            // 12px — so the one row here that is a control read as a greyed-out caption,
                            // and nothing but the switch said it could be pressed. It now carries the
                            // same weight as a network row, and the shared IndToggle replaces the
                            // hand-rolled switch that was the only one in the shell not using it.
                            Item { width: parent.width; height: 30
                                Row { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; spacing: 7
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "security"; sz: 15
                                        color: root.warpConnected ? theme.good : theme.sub }
                                    Text { anchors.verticalCenter: parent.verticalCenter
                                        text: "Cloudflare WARP"
                                        color: root.warpConnected ? theme.text : theme.sub
                                        font.pixelSize: 12; font.family: root.cfgFont }
                                    Text { anchors.verticalCenter: parent.verticalCenter
                                        visible: root.warpConnected
                                        text: "· " + root.warpMode; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont } }
                                IndToggle { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                                    on: root.warpConnected; onToggled: root.warpToggle() } }

                            // WARP mode chips (only when WARP is connected)
                            Row { visible: root.warpConnected; spacing: 5; topPadding: 2
                                Repeater { model: ["warp","doh","warp+doh","tunnel_only"]
                                    delegate: Rectangle { required property var modelData
                                        readonly property bool cur: root.warpMode === modelData
                                        height: 20; radius: Tok.r; width: modeTxt.implicitWidth + 14
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
                                        width: 36; height: 20; radius: Tok.r
                                        color: modelData.active ? theme.iris : (connecting ? theme.a(theme.frost, 0.4) : theme.a(theme.line, 0.85))
                                        border.width: 1; border.color: modelData.active ? theme.a(theme.iris,0.5) : (connecting ? theme.a(theme.frost,0.3) : theme.a(theme.iris,0.3))
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Rectangle { width: 15; height: 15; radius: Tok.r; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
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
                                    Rectangle { width: 26; height: 26; radius: Tok.r
                                        color: btScanMa.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                                        Sym { anchors.centerIn: parent; text: (root.btAdapter&&root.btAdapter.discovering)?"sync":"search"; sz: 15; color: theme.sub }
                                        MouseArea { id: btScanMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering } }
                                    // power toggle
                                    Rectangle { width: 36; height: 20; radius: Tok.r; anchors.verticalCenter: undefined
                                        color: (root.btAdapter&&root.btAdapter.enabled)?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: theme.a(theme.iris,0.3)
                                        Rectangle { width: 15; height: 15; radius: Tok.r; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
                                            x: (root.btAdapter&&root.btAdapter.enabled)?19:2; Behavior on x { NumberAnimation { duration: 130 } } }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled } } } }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.line, 0.6) }
                            Item { height: 2; width: 1 }
                            Repeater { model: root.btDevices
                                delegate: Rectangle { required property var modelData; width: parent.width; height: 36; radius: Tok.r
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
                                                color: sel ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                                        MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.kdeSel = modelData.id } } } }
                            // The device itself
                            Rectangle { width: parent.width; radius: Tok.r; visible: kdeCol.dev !== null
                                implicitHeight: devCol.implicitHeight + 20
                                color: theme.a(theme.line, 0.32); border.width: 1
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
                                Rectangle { width: 28; height: 28; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
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
                                    width: parent.width; height: 32; radius: Tok.r
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
                                        implicitHeight: 24; implicitWidth: ccT.implicitWidth + 18; radius: Tok.r
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
                                            implicitWidth: acRow.implicitWidth + 14; height: 20; radius: Tok.r
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
                                    width: parent.width; height: 34; radius: Tok.r
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
                            // The month keeps its own title row rather than a CalHead: it is the panel's
                            // identity, not a section label, so it stays centred and full size and only
                            // borrows the chevron.
                            Item { width: parent.width; height: 20
                                Text { anchors.centerIn: parent; text: Qt.formatDateTime(clock.date,"MMMM yyyy"); color: theme.frost; font.pixelSize: 14; font.family: root.cfgFont; font.bold: true }
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
                                        width: 34; height: 26; radius: Tok.r
                                        color: isToday ? theme.iris : (hasEvent ? theme.a(theme.iris, 0.13) : "transparent")
                                        border.width: (hasEvent && !isToday) ? 1 : 0; border.color: theme.a(theme.frost, 0.4)
                                        Text { anchors.centerIn: parent; text: parent.modelData; color: parent.isToday ? theme.bg : theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: parent.isToday }
                                        Rectangle {
                                            visible: parent.hasEvent && !parent.isToday
                                            width: 3; height: 3; radius: 1.5; color: theme.frost
                                            anchors.bottom: parent.bottom; anchors.bottomMargin: 3; anchors.horizontalCenter: parent.horizontalCenter } } } }
                            }
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column {
                                width: parent.width; spacing: 5
                                CalHead { skey: "up"; title: "UPCOMING"
                                    summary: root.calUpcoming.length === 0 ? "none"
                                           : root.calUpcoming.length + (root.calUpcoming.length > 4 ? " · +" + (root.calUpcoming.length - 4) + " more" : "") }
                                Column { width: parent.width; spacing: 5; visible: !root.calFolded("up")
                                Text { visible: root.calUpcoming.length === 0; text: "nothing coming up"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
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
                                                    color: evRow.soon ? theme.frost : theme.iris; font.pixelSize: 15; font.family: root.cfgFont; font.bold: true }
                                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(root.calDate(evRow.modelData.date), "MMM").toUpperCase()
                                                    color: theme.faint; font.pixelSize: 8; font.family: root.cfgFont } }
                                            Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 44; spacing: 1
                                                Text { width: parent.width; text: evRow.modelData.title; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; elide: Text.ElideRight }
                                                Text { text: evRow.rel + "  ·  " + Qt.formatDate(root.calDate(evRow.modelData.date), "ddd") + (evRow.modelData.time ? "  ·  " + evRow.modelData.time : "")
                                                    color: evRow.soon ? theme.frost : theme.faint; font.pixelSize: 9; font.family: root.cfgFont } } } } } }

                            }
                            // ================= TIMER · POMODORO =================
                            Rectangle { width: parent.width; height: 1; color: theme.a(theme.iris, 0.15) }
                            Column { width: parent.width; spacing: 6
                                // A running countdown is the one thing that must survive folding: the
                                // section is exactly where you look to find out how long is left.
                                CalHead { skey: "tmr"; title: root.pomoActive ? "POMODORO" : "TIMER"
                                    summary: root.tmrRunning ? root.tmrText
                                           : (root.pomoActive ? "session " + (root.pomoDone + (root.pomoPhase==="focus"?1:0)) : "off") }
                                Column { width: parent.width; spacing: 6; visible: !root.calFolded("tmr")

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
                                        Rectangle { width: (parent.width - (root.pomoActive?12:6))/(root.pomoActive?3:2); height: 30; radius: Tok.r
                                            color: tpMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"play_arrow":"pause"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.tmrPaused?"resume":"pause"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: tpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrToggle() } }
                                        Rectangle { visible: root.pomoActive; width: (parent.width - 12)/3; height: 30; radius: Tok.r
                                            color: tsMa.containsMouse ? theme.a(theme.iris,0.25) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.2)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "skip_next"; sz: 14; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "skip"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: tsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoSkip() } }
                                        Rectangle { width: root.pomoActive ? (parent.width-12)/3 : (parent.width-6)/2; height: 30; radius: Tok.r
                                            color: txMa.containsMouse ? theme.a(theme.bad,0.22) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.bad,0.25)
                                            Row { anchors.centerIn: parent; spacing: 5
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "stop"; sz: 14; color: theme.bad }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: "stop"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont } }
                                            MouseArea { id: txMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tmrStop() } } } }

                                // ---- idle: quick timers + pomodoro ----
                                Column { width: parent.width; spacing: 6; visible: !root.tmrRunning
                                    Flow { width: parent.width; spacing: 5
                                        Repeater { model: [1,5,10,15,25]
                                            delegate: Rectangle { required property var modelData; height: 28; radius: Tok.r; width: (parent.width - 4*5)/5
                                                color: qcMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.4); border.width:1; border.color: theme.a(theme.iris,0.16)
                                                Text { anchors.centerIn: parent; text: modelData+"m"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                                MouseArea { id: qcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.timerStartMin(modelData) } } } }
                                    Rectangle { width: parent.width; height: 34; radius: Tok.r
                                        color: psMa.containsMouse ? theme.iris : theme.a(theme.iris,0.22); border.width:1; border.color: theme.iris
                                        Row { anchors.centerIn: parent; spacing: 7
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "local_fire_department"; sz: 16; color: psMa.containsMouse?theme.bg:theme.frost }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Start Pomodoro · " + root.pomoFocusMin + "/" + root.pomoBreakMin; color: psMa.containsMouse?theme.bg:theme.frost; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true } }
                                        MouseArea { id: psMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pomoStart() } }
                                    // compact config: focus / break steppers + DND toggle
                                    Row { width: parent.width; spacing: 8
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "focus"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: fmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: fmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.max(5, root.pomoFocusMin-5); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoFocusMin; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: fpMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "add"; sz: 12; color: theme.frost }
                                                MouseArea { id: fpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoFocusMin = Math.min(120, root.pomoFocusMin+5); root.tmrSaveCfg() } } } }
                                        Row { spacing: 3
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "break"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                            Rectangle { width: 20; height: 20; radius: Tok.r; color: bmMa.containsMouse?theme.a(theme.iris,0.2):theme.a(theme.line,0.4)
                                                Sym { anchors.centerIn: parent; text: "remove"; sz: 12; color: theme.frost }
                                                MouseArea { id: bmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.pomoBreakMin = Math.max(1, root.pomoBreakMin-1); root.tmrSaveCfg() } } }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: 22; horizontalAlignment: Text.AlignHCenter; text: root.pomoBreakMin; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
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
                                CalHead { skey: "wc"; title: "WORLD CLOCK"
                                    summary: root.wcZones.length === 0 ? "none" : root.wcZones.length + " cities" }
                                Column { width: parent.width; spacing: 5; visible: !root.calFolded("wc")
                                Repeater { model: root.wcTimes
                                    delegate: Rectangle { required property var modelData; width: parent.width; height: 28; radius: Tok.r
                                        color: wcm.containsMouse ? theme.a(theme.line,0.4) : "transparent"
                                        Row { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "public"; sz: 13; color: theme.faint }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 120; elide: Text.ElideRight; text: modelData.label; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.day; color: theme.faint; font.pixelSize: 9; font.family: root.cfgFont }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.time; color: theme.frost; font.pixelSize: 12; font.family: root.cfgFont; font.bold: true } }
                                        MouseArea { id: wcm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                        Rectangle { anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter; visible: wcm.containsMouse
                                            width: 20; height: 20; radius: Tok.r; color: theme.a(theme.bad,0.22)
                                            Sym { anchors.centerIn: parent; text: "close"; sz: 12; color: theme.bad }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wcRemove(modelData.zone) } } } }
                                Text { visible: root.wcTimes.length===0; text: "add a city below"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                                Flow { width: parent.width; spacing: 5; topPadding: 2
                                    Repeater { model: root.wcPresets
                                        delegate: Rectangle { required property var modelData
                                            visible: root.wcZones.indexOf(modelData.z) < 0
                                            height: 22; radius: Tok.r; width: visible ? (wcAddRow.implicitWidth + 14) : 0
                                            color: wcaMa.containsMouse ? theme.a(theme.iris,0.2) : theme.a(theme.line,0.35); border.width: 1; border.color: theme.a(theme.iris,0.18)
                                            Row { id: wcAddRow; anchors.centerIn: parent; spacing: 3
                                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "add"; sz: 11; color: theme.frost }
                                                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: theme.text; font.pixelSize: 9; font.family: root.cfgFont } }
                                            MouseArea { id: wcaMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.wcAdd(modelData.z) } } } } } } } }
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
                                    width: parent.width; height: 34; radius: Tok.r
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
                            Layout.alignment: Qt.AlignHCenter
                            Repeater {
                                model: Hyprland.workspaces
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                    width: 24
                                    height: foc ? 36 : 24
                                    radius: Tok.r
                                    color: foc ? theme.iris : theme.a(theme.line, 0.55)
                                    border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris, 0.18)
                                    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.wsLabelFor(modelData.id)
                                        color: foc ? theme.bg : theme.sub
                                        font.pixelSize: 12; font.family: root.wsFontFamily; font.bold: foc
                                    }
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                                width: 22; height: 22; radius: Tok.r
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
                                            asynchronous: true; source: { try { return (trayItemVert.modelData && trayItemVert.modelData.icon) ? trayItemVert.modelData.icon : "" } catch(e) { return "" } }
                                            sourceSize.width: 96; sourceSize.height: 96; smooth: true; mipmap: true
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        MouseArea {
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
                        
                        // Quick Settings shortcut (Vertical variant)
                        Rectangle {
                            id: ccPillVert
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
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
                            width: 32; height: 32; radius: Tok.r
                            color: theme.a(theme.line, 0.45); border.width: 1; border.color: theme.a(theme.iris, 0.22)
                            visible: root.cfgNotif
                            Sym { anchors.centerIn: parent; text: root.dnd ? "notifications_off" : (root.notes.length>0 ? "notifications" : "notifications_none"); sz: 16; color: theme.frost }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.openBar = bar; root.openPop = (root.openPop === "notif") ? "" : "notif" }
                            }
                        }
                        
                        // Vertical Stacked Clock
                        Item {
                            id: clockPillVert
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.cfgClock
                            implicitWidth: clockColVert.implicitWidth
                            implicitHeight: clockColVert.implicitHeight
                            ColumnLayout {
                                id: clockColVert
                                anchors.centerIn: parent
                                spacing: 1
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
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.openBar = bar; root.openPop = (root.openPop === "cal") ? "" : "cal" }
                            }
                        }
                        
                        // Power Control (Vertical variant)
                        Rectangle {
                            id: pwrPillVert
                            width: 32; height: 32; radius: Tok.r
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
            Item {
                // EVERY dropdown must be in this list. One left out is not "unregistered", it is
                // treated as outside the grab — so it opens and is dismissed in the same frame,
                // which looks exactly like a dead pill. (updDrop was missing and did precisely that.)
                readonly property var myWins: [bar, ccDrop, wxDrop, wifiDrop, btDrop, kdeDrop, volDrop, batDrop, calDrop, pwrDrop, notifDrop, mprisDrop, trayDrop, sysDrop, updDrop]
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
                    readonly property var actList: {
                        try { return JSON.parse(pcard.model.acts || "[]"); } catch (e) { return []; }
                    }
                    width: popCol.width; radius: Tok.rCard
                    implicitHeight: pcc.implicitHeight + 22
                    color: Tok.alpha(Tok.surface, root.dropOpacity)
                    border.width: 1; border.color: pcard.model.urg===2 ? theme.a(theme.bad,0.6) : Tok.ruleHard
                    Column { id: pcc; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12; anchors.rightMargin: 36; spacing: 3
                        Row { width: parent.width
                            Sym { anchors.verticalCenter: parent.verticalCenter; text: pcard.model.urg===2 ? "priority_high" : "notifications"; sz: 13; color: pcard.model.urg===2 ? theme.bad : theme.frost }
                            Text { leftPadding: 6; anchors.verticalCenter: parent.verticalCenter; text: pcard.model.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-24 } }
                        Text { width: parent.width; visible: pcard.model.summary!==""; text: pcard.model.summary; color: theme.text; font.pixelSize: 13; font.family: root.cfgFont; font.bold: true; wrapMode: Text.WordWrap }
                        Text { width: parent.width; visible: pcard.model.body!==""; text: pcard.model.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight; textFormat: Text.PlainText }
                        // action buttons the app supplied (Reply, Mark as read, …)
                        Row {
                            spacing: 6; topPadding: 6
                            visible: pcard.actList.length > 0
                            Repeater {
                                model: pcard.actList
                                delegate: Rectangle {
                                    required property var modelData
                                    height: 24; radius: Tok.r
                                    width: alab.implicitWidth + 18
                                    color: am.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.5)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                    Text { id: alab; anchors.centerIn: parent; text: modelData.t
                                        color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
                                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.noteInvoke(pcard.model.key, modelData.i) }
                                }
                            }
                        }
                    }
                    Rectangle { anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6; width: 22; height: 22; radius: Tok.r
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
            width: 250; height: 54; radius: Tok.rCard
            color: Tok.alpha(Tok.surface, root.dropOpacity); border.width: 1; border.color: Tok.ruleHard
            Row { anchors.fill: parent; anchors.margins: 16; spacing: 13
                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.osdIcon; sz: 24; color: theme.frost }
                Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width-52; spacing: 6
                    Row { width: parent.width
                        Text { text: root.osdKind==="vol" ? "volume" : (root.osdKind==="zoom" ? "magnifier" : "brightness"); color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                        Item { width: parent.width - 80; height: 1 }
                        Text { text: root.osdKind==="zoom" ? (root.zoomFactor.toFixed(2).replace(/\.?0+$/,"")+"×") : (Math.round(root.osdVal*100)+"%"); color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont } }
                    Rectangle { width: parent.width; height: 6; radius: Tok.r; color: theme.a(theme.line,0.85)
                        Rectangle { width: parent.width*Math.max(0,Math.min(1,root.osdVal)); height: parent.height; radius: Tok.r; color: theme.iris
                            Behavior on width { NumberAnimation { duration: 90 } } } }
                }
            }
        }
    }

    // (the alt-tab switcher HUD lives up top, next to its state + the `switcher` IPC —
    //  a single thumbnail-based overlay; there is deliberately no second one here.)

    // ===== Exposé — every workspace, as a map of where things actually are =====
    //
    // The version this replaces drew a fixed 280x180 card per workspace in a Flow, inside a
    // box clamped to 1000x700 and centred — so on a 1080p screen three workspaces sat in the
    // top-left eighth of a mostly empty page. Inside each card, the windows were 122x60 tiles
    // laid out left to right in the order the compositor happened to list them.
    //
    // That last part is the real fault. An exposé is a MAP: its whole job is that the picture
    // of a workspace matches the shape of the workspace, so you recognise the one you want by
    // its layout rather than by reading three labels. Windows are now drawn at their true
    // relative positions and sizes within the monitor, and a card is the monitor's own aspect
    // ratio, so a workspace with a wide editor and a narrow terminal beside it LOOKS like that.
    property bool exposeActive: false
    // refresh on the way in: the tiles read titles/classes and focus by address out of
    // lastIpcObject, which goes empty on a long-lived shell until something asks for it.
    function toggleExpose() { if (!root.exposeActive) Hyprland.refreshToplevels(); root.exposeActive = !root.exposeActive }

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

        // Real workspaces only, in order. Hyprland numbers special workspaces from -98 down;
        // the scratchpad is an overlay on wherever you already are, not a place to go.
        readonly property var wsList: {
            var out = [];
            var all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
            for (var i = 0; i < all.length; i++) if (all[i] && all[i].id > 0) out.push(all[i]);
            out.sort(function (a, b) { return a.id - b.id });
            return out;
        }
        // The monitor's shape, which is the shape every card takes.
        readonly property real screenAspect: (exposeWin.screen && exposeWin.screen.height > 0)
                                             ? exposeWin.screen.width / exposeWin.screen.height : 16 / 9
        property int sel: 0
        onVisibleChanged: if (visible) {
            // open on the one you are standing in, so Enter is a no-op and the arrows start
            // from where you are rather than from workspace 1
            for (var i = 0; i < exposeWin.wsList.length; i++)
                if (Hyprland.focusedWorkspace && exposeWin.wsList[i].id === Hyprland.focusedWorkspace.id)
                    exposeWin.sel = i;
        }
        function go(i) {
            if (i < 0 || i >= exposeWin.wsList.length) return;
            Hyprland.dispatch("hl.dsp.focus({ workspace = " + exposeWin.wsList[i].id + " })");
            root.exposeActive = false;
        }

        Rectangle {
            anchors.fill: parent
            color: Tok.bg                       // opaque: a focus mode, no desktop bleed-through
            MouseArea { anchors.fill: parent; onClicked: root.exposeActive = false }

            FocusScope {
                anchors.fill: parent; focus: exposeWin.visible
                Keys.onPressed: (e) => {
                    var n = exposeWin.wsList.length, cols = grid.cols;
                    switch (e.key) {
                    case Qt.Key_Escape: root.exposeActive = false; e.accepted = true; return;
                    case Qt.Key_Left:   exposeWin.sel = Math.max(0, exposeWin.sel - 1); e.accepted = true; return;
                    case Qt.Key_Right:  exposeWin.sel = Math.min(n - 1, exposeWin.sel + 1); e.accepted = true; return;
                    case Qt.Key_Up:     exposeWin.sel = Math.max(0, exposeWin.sel - cols); e.accepted = true; return;
                    case Qt.Key_Down:   exposeWin.sel = Math.min(n - 1, exposeWin.sel + cols); e.accepted = true; return;
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                    case Qt.Key_Space:  exposeWin.go(exposeWin.sel); e.accepted = true; return;
                    }
                    // 1..9 jumps straight to that workspace — the same keys that switch to it
                    // normally, doing the same thing here.
                    if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                        var want = e.key - Qt.Key_0;
                        for (var i = 0; i < n; i++)
                            if (exposeWin.wsList[i].id === want) { exposeWin.go(i); e.accepted = true; return }
                    }
                }

                // ---- header ----
                Item {
                    id: expHead
                    anchors { top: parent.top; left: parent.left; right: parent.right
                              margins: Math.round(40 * exposeWin.ui) }
                    height: Math.round(30 * exposeWin.ui)
                    Row {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        spacing: Math.round(12 * exposeWin.ui)
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "workspaces"; mono: true
                            sz: Math.round(Tok.tPanel * exposeWin.ui)
                            font.weight: 700; color: Tok.ink
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: exposeWin.wsList.length + " · " + (Hyprland.toplevels ? Hyprland.toplevels.values.length : 0) + " windows"
                            mono: true; sz: Math.round(Tok.tData * exposeWin.ui); color: Tok.ink3
                        }
                    }
                    IndText {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        mono: true; sz: Math.round(Tok.tLabel * exposeWin.ui); color: Tok.ink2
                        text: "← →  choose      1–9  jump      enter  go      esc  close"
                    }
                }
                Rectangle {
                    anchors { top: expHead.bottom; left: expHead.left; right: expHead.right
                              topMargin: Math.round(12 * exposeWin.ui) }
                    height: 1; color: Tok.ruleHard
                }

                // ---- the grid ----
                // Sized to the space rather than to a constant: the cards are as large as the
                // screen allows, which is the point of taking the whole screen.
                Item {
                    id: grid
                    anchors {
                        top: expHead.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                        topMargin: Math.round(46 * exposeWin.ui)
                        leftMargin: Math.round(40 * exposeWin.ui)
                        rightMargin: Math.round(40 * exposeWin.ui)
                        bottomMargin: Math.round(40 * exposeWin.ui)
                    }
                    readonly property int n: exposeWin.wsList.length
                    readonly property real gap: Math.round(22 * exposeWin.ui)
                    // Try every column count and keep whichever makes the biggest card that
                    // still fits both ways. Four workspaces on a wide screen want one row;
                    // twelve want three.
                    readonly property int cols: {
                        if (grid.n <= 0) return 1;
                        var best = 1, bestW = 0;
                        for (var c = 1; c <= grid.n; c++) {
                            var rows = Math.ceil(grid.n / c);
                            var w = (grid.width - grid.gap * (c - 1)) / c;
                            var h = (grid.height - grid.gap * (rows - 1)) / rows;
                            var fit = Math.min(w, h * exposeWin.screenAspect);
                            if (fit > bestW) { bestW = fit; best = c }
                        }
                        return best;
                    }
                    readonly property real cardW: {
                        var rows = Math.ceil(grid.n / grid.cols);
                        var w = (grid.width - grid.gap * (grid.cols - 1)) / grid.cols;
                        var h = (grid.height - grid.gap * (rows - 1)) / rows;
                        return Math.max(120, Math.min(w, h * exposeWin.screenAspect));
                    }
                    readonly property real cardH: grid.cardW / exposeWin.screenAspect

                    Grid {
                        anchors.centerIn: parent
                        columns: grid.cols
                        spacing: grid.gap
                        Repeater {
                            model: exposeWin.wsList
                            delegate: Rectangle {
                                id: wsCard
                                required property var modelData
                                required property int index
                                readonly property bool focused: Hyprland.focusedWorkspace
                                                                && Hyprland.focusedWorkspace.id === modelData.id
                                readonly property bool picked: exposeWin.sel === index
                                width: grid.cardW; height: grid.cardH
                                radius: Tok.rSmall
                                clip: true
                                color: Tok.surface
                                border.width: wsCard.picked ? 2 : 1
                                border.color: wsCard.picked ? Tok.accent
                                            : (cardMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
                                Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                                // compose captures into one FBO so a ScreencopyView texture node
                                // can't leak a stray thumbnail outside the card
                                layer.enabled: true

                                // the workspace's own ground, so a window sitting on it reads as
                                // a window on a desktop rather than a tile on a card
                                Rectangle { anchors.fill: parent; anchors.margins: wsCard.border.width
                                            color: Tok.sunken }

                                // ---- the map ----
                                Item {
                                    id: map
                                    anchors.fill: parent
                                    anchors.margins: wsCard.border.width
                                    readonly property real sx: exposeWin.screen ? map.width / exposeWin.screen.width : 0
                                    readonly property real sy: exposeWin.screen ? map.height / exposeWin.screen.height : 0

                                    Repeater {
                                        // EMPTY while exposé is closed. The PanelWindow above is
                                        // only `visible: false`, not destroyed — and in QML that
                                        // keeps every child alive, so this used to hold one
                                        // ScreencopyView per window on the system, permanently,
                                        // each pinned to that window's wayland handle. When a
                                        // window dies the capture outlives its source, which is a
                                        // prime suspect for the fatal "Wayland connection …
                                        // Invalid argument" that kills the whole bar.
                                        model: {
                                            if (!root.exposeActive) return [];
                                            var m = Hyprland.toplevels ? Hyprland.toplevels.values : [];
                                            var out = [];
                                            for (var i = 0; i < m.length; i++) {
                                                var t = m[i];
                                                if (t && t.workspace && t.workspace.id === wsCard.modelData.id) out.push(t);
                                            }
                                            return out;
                                        }
                                        delegate: Rectangle {
                                            id: winTile
                                            required property var modelData
                                            readonly property var ipc: (modelData && modelData.lastIpcObject) || null
                                            readonly property string cls: {
                                                try {
                                                    if (!modelData) return "";
                                                    var c = (winTile.ipc && winTile.ipc.class)
                                                        || (modelData.wayland && modelData.wayland.appId) || "";
                                                    return ("" + c).toLowerCase();
                                                } catch (e) { return "" }
                                            }
                                            // Real geometry, mapped into the card. `at` is in
                                            // layout coordinates across all monitors, so the
                                            // screen's own origin comes off first.
                                            readonly property var at: (winTile.ipc && winTile.ipc.at) || [0, 0]
                                            readonly property var sz: (winTile.ipc && winTile.ipc.size) || [0, 0]
                                            readonly property real ox: exposeWin.screen ? exposeWin.screen.x : 0
                                            readonly property real oy: exposeWin.screen ? exposeWin.screen.y : 0
                                            readonly property bool mapped: winTile.sz[0] > 0 && winTile.sz[1] > 0
                                            x: winTile.mapped ? (winTile.at[0] - winTile.ox) * map.sx : 0
                                            y: winTile.mapped ? (winTile.at[1] - winTile.oy) * map.sy : 0
                                            width:  winTile.mapped ? Math.max(18, winTile.sz[0] * map.sx) : map.width
                                            height: winTile.mapped ? Math.max(14, winTile.sz[1] * map.sy) : map.height
                                            radius: Tok.rSmall
                                            clip: true
                                            color: Tok.raised
                                            border.width: 1
                                            border.color: winMa.containsMouse ? Tok.accent : Tok.ruleHard
                                            Behavior on border.color { ColorAnimation { duration: Tok.mFast } }

                                            ScreencopyView {
                                                id: winScv
                                                anchors.fill: parent
                                                anchors.margins: 1
                                                captureSource: (winTile.modelData && winTile.modelData.wayland)
                                                               ? winTile.modelData.wayland : null
                                                live: root.exposeActive
                                                visible: hasContent
                                            }
                                            IconImage {
                                                anchors.centerIn: parent
                                                implicitSize: Math.min(40, Math.max(16, winTile.height * 0.4))
                                                asynchronous: true
                                                visible: !winScv.hasContent
                                                source: Quickshell.iconPath(winTile.cls, "application-x-executable")
                                            }
                                            // The name, only when the tile is big enough to carry
                                            // one. A 14px strip of 8px text is not a label.
                                            Rectangle {
                                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                                height: Math.round(16 * exposeWin.ui)
                                                visible: winTile.height > 54 * exposeWin.ui
                                                color: Tok.alpha(Tok.bg, 0.82)
                                                IndText {
                                                    anchors { fill: parent; leftMargin: 5; rightMargin: 5 }
                                                    verticalAlignment: Text.AlignVCenter
                                                    elide: Text.ElideRight
                                                    text: winTile.cls || "window"
                                                    mono: true; sz: Math.round(Tok.tLabel * exposeWin.ui)
                                                    color: Tok.ink2
                                                }
                                            }
                                            MouseArea {
                                                id: winMa
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    var o = winTile.ipc;
                                                    if (o && o.address) Hyprland.dispatch("hl.dsp.focuswindow('address:" + o.address + "')");
                                                    root.exposeActive = false;
                                                }
                                            }
                                        }
                                    }
                                }

                                // ---- the label plate ----
                                // Bottom of the card, over the map: a workspace's number is the
                                // thing you are scanning for, and it should not be competing for
                                // space with the map it labels.
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                              margins: wsCard.border.width }
                                    height: Math.round(26 * exposeWin.ui)
                                    color: Tok.alpha(Tok.bg, 0.9)
                                    Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                                                height: 1; color: Tok.ruleHard }
                                    Row {
                                        anchors { left: parent.left; leftMargin: Math.round(9 * exposeWin.ui)
                                                  verticalCenter: parent.verticalCenter }
                                        spacing: Math.round(8 * exposeWin.ui)
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Math.round(7 * exposeWin.ui); height: width; radius: width / 2
                                            color: wsCard.focused ? Tok.accent : Tok.alpha(Tok.ink3, 0.4)
                                        }
                                        IndText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.wsLabelFor(wsCard.modelData.id)
                                            mono: true; sz: Math.round(Tok.tData * exposeWin.ui)
                                            font.weight: 700
                                            color: wsCard.focused ? Tok.accent : Tok.ink
                                        }
                                        IndText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: wsCard.modelData.name && ("" + wsCard.modelData.name) !== ("" + wsCard.modelData.id)
                                                  ? ("" + wsCard.modelData.name) : ""
                                            mono: true; sz: Math.round(Tok.tLabel * exposeWin.ui); color: Tok.ink3
                                        }
                                    }
                                }

                                // An empty workspace is still a place you can go, and saying so
                                // beats an unexplained blank card.
                                IndText {
                                    anchors.centerIn: parent
                                    visible: !(Hyprland.toplevels && Hyprland.toplevels.values.some(function (t) {
                                        return t && t.workspace && t.workspace.id === wsCard.modelData.id }))
                                    text: "empty"; mono: true
                                    sz: Math.round(Tok.tLabel * exposeWin.ui)
                                    font.letterSpacing: 1.4 * exposeWin.ui
                                    font.capitalization: Font.AllUppercase
                                    color: Tok.ink3
                                }

                                MouseArea {
                                    id: cardMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton
                                    z: -1                     // window tiles keep their own clicks
                                    onEntered: exposeWin.sel = wsCard.index
                                    onClicked: exposeWin.go(wsCard.index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
