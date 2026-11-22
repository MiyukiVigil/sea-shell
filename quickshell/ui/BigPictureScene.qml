// Big picture mode: the shell as a console. Steam's Big Picture is the baseline. Always dark, whatever
// the desktop is set to. Home is the selected game's art edge to edge with a row of games and a row of
// round buttons under it. A opens a game's own page, with Play and its launch options straight there.
// Pages replace what is on screen rather than floating on it, and the home button brings in a guide
// over anything. Focus is one bright thing that moves. Button icons are real ones for the pad in use
// (Kenney's Input Prompts, CC0, in assets/input-prompts).
//
// Opening it plays the sea rising over the screen with the logo on it, then draining away to leave
// the room, the same tide as the wallpaper picker. Any button skips ahead.
//
// Pressing Play still pushes the game in as a cartridge: the cover keeps its size and goes straight
// down into a slot in the footer, which lights on contact. That light then runs out along the slot and
// rises off it, leaving the game's title screen behind while the game starts. Under a second to
// contact, because it plays on every launch, and any button skips it.
//
// Everything is worked out from one clock, stepped by step(). Input all arrives through input(), from
// the keyboard here or from sea-gamepad.py by way of the shell.
//
// With BP_DRY set, nothing runs: commands are logged and no game starts.
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

Item {
    id: bp

    property var cfg: ({ screen: "auto", other: "black", home: true })
    property var pads: []
    property string screenName: ""
    property var screenChoices: []
    property bool manualClock: false
    // The gaming session: no desktop to go back to, so everything has to be reachable from here.
    property bool session: false
    signal setCfg(var patch)
    signal exited()

    readonly property bool dry: (Quickshell.env("BP_DRY") || "") !== ""
    property bool dryWindow: false
    property var dryDevices: []

    readonly property string gamingScript: Qt.resolvedUrl("sea-gaming.py").toString().replace("file://", "")
    readonly property string audioScript: Qt.resolvedUrl("sea-audio.py").toString().replace("file://", "")
    readonly property string perfScript: Qt.resolvedUrl("sea-perf.sh").toString().replace("file://", "")
    readonly property string gameModeScript: Qt.resolvedUrl("sea-gamemode.sh").toString().replace("file://", "")
    readonly property string tickSnd: Qt.resolvedUrl("bp-tick.wav").toString().replace("file://", "")
    readonly property string clickSnd: Qt.resolvedUrl("bp-click.wav").toString().replace("file://", "")

    readonly property real ui: Math.min(width / 1920, height / 1080)
    readonly property real cornerR: Tok.rCard * ui
    readonly property real tileRadius: Math.min(Tok.rCard, 20) * ui
    readonly property real hue: Math.max(0, Tok.accent.hslHue)
    readonly property color pBg: Qt.hsla(hue, 0.2, 0.07, 1)
    readonly property color pPanel: Qt.hsla(hue, 0.18, 0.115, 1)
    readonly property color pFoot: Qt.hsla(hue, 0.2, 0.05, 1)
    readonly property color pFill: Qt.rgba(1, 1, 1, 0.065)
    readonly property color ink: "#f3f5f9"
    readonly property color ink2: "#b9bfca"
    readonly property color ink3: "#808692"
    readonly property color accent: Qt.hsla(hue, 0.7, 0.74, 1)
    readonly property color warn: "#f0b84e"
    readonly property color crit: "#ff7d76"

    // ---- sizes, at 1080p ----
    readonly property real cardW: 290 * ui
    readonly property real cardH: 435 * ui
    readonly property real cardGap: 44 * ui
    readonly property real dockH: 76 * ui
    readonly property real dockTop: height - dockH
    readonly property real slotH: 14 * ui
    readonly property real slotY: dockTop - slotH / 2
    readonly property real lipY: dockTop
    readonly property real cardTop: 250 * ui

    // ---- the library ----
    property var games: []
    property var shelf: []
    property string shelfSort: "recent"
    property int index: 0
    property real railPos: 0
    readonly property var game: shelf.length ? shelf[Math.min(index, shelf.length - 1)] : null
    // A Repeater hands its delegates copies of the games, so a cover asks here, by appid.
    readonly property var favIds: {
        bp.profileTick;
        var m = {};
        for (var i = 0; i < bp.games.length; i++) if (bp.games[i].favourite) m[bp.games[i].appid] = true;
        return m;
    }
    readonly property var sortNames: ({ recent: "Recent", fav: "Favourites first", played: "Most played", name: "A to Z" })
    readonly property var sortOrder: ["recent", "fav", "played", "name"]
    // Where each game comes from, and what opens it. Settings that are not Steam's live there.
    readonly property var launchers: ({
        steam: { l: "Steam", cmd: ["steam"], cls: "steam" },
        heroic: { l: "Heroic", cmd: ["heroic"], cls: "heroic" },
        lutris: { l: "Lutris", cmd: ["lutris"], cls: "lutris" },
        twintail: { l: "TwinTail", cmd: ["twintaillauncher"], cls: "twintail" },
        prism: { l: "Prism Launcher", cmd: ["prismlauncher"], cls: "prismlauncher" }
    })
    function launcherName(g) { return g && bp.launchers[g.source] ? bp.launchers[g.source].l : "its launcher"; }
    // "" is every game. Only launchers something is installed from are offered.
    property string sourceFilter: ""
    readonly property var sourcesPresent: {
        var seen = [];
        for (var i = 0; i < bp.games.length; i++)
            if (seen.indexOf(bp.games[i].source) < 0) seen.push(bp.games[i].source);
        return ["steam", "heroic", "lutris", "twintail", "prism"].filter(function (s) { return seen.indexOf(s) >= 0; });
    }
    readonly property string filterName: bp.sourceFilter ? bp.launchers[bp.sourceFilter].l + " only" : "Every launcher"

    function resort(keepId) {
        var list = bp.games.slice();
        if (bp.sourceFilter && bp.sourcesPresent.indexOf(bp.sourceFilter) < 0) bp.sourceFilter = "";
        if (bp.sourceFilter) list = list.filter(function (g) { return g.source === bp.sourceFilter; });
        if (bp.shelfSort === "played") list.sort(function (a, b) { return b.seconds - a.seconds; });
        else if (bp.shelfSort === "name") list.sort(function (a, b) { return a.name.localeCompare(b.name); });
        else if (bp.shelfSort === "fav") list.sort(function (a, b) { return (b.favourite ? 1 : 0) - (a.favourite ? 1 : 0); });
        bp.shelf = list;
        var at = 0;
        for (var i = 0; i < list.length; i++) if (list[i].appid === keepId) at = i;
        bp.index = at;
        bp.railPos = at;
        bg.show(at);
    }

    // ---- the clock ----
    property real boot: -1          // ms since the startup screen began, -1 when it is over
    property real t: -1             // ms since the insert began, -1 when idle
    property real launchedAt: -1    // t when the game's window appeared
    property real ej: -1            // ms since the eject began, -1 when idle
    property real room: 1           // how far the room has come back
    property bool launchSent: false
    property bool gameShowing: false
    readonly property int contact: 580
    readonly property int bootHold: 1180    // when the sea starts to drain
    readonly property int bootEnd: 1760

    function clamp01(x) { return Math.max(0, Math.min(1, x)); }
    function outCubic(x) { x = clamp01(x); return 1 - Math.pow(1 - x, 3); }
    function inQuad(x) { x = clamp01(x); return x * x; }
    function inOut(x) { x = clamp01(x); return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2; }
    function outBack(x) { x = clamp01(x) - 1; return 1 + 2.4 * x * x * x + 1.4 * x * x; }

    readonly property bool inserting: t >= 0
    readonly property bool seated: t >= contact
    readonly property bool launched: launchedAt >= 0 && t >= launchedAt
    readonly property real travel: lipY - cardTop + 76 * ui

    // The press answers first, then the card lifts, hangs for a beat and drops. Eject is the drop
    // backwards, slowing as it arrives.
    readonly property real cardOffset: {
        if (ej >= 0) return travel * (1 - outCubic(ej / 420));
        if (t < 0) return 0;
        if (t < 90) return 8 * ui * outCubic(t / 90);
        if (t < 240) return (8 - 44 * outCubic((t - 90) / 150)) * ui;
        if (t < 340) return -36 * ui;
        return -36 * ui + travel * inQuad((t - 340) / 240);
    }
    // The slot widens ahead of the card, then closes behind it, faster and with an overshoot.
    readonly property real slotOpen: {
        if (ej >= 0) return ej < 300 ? outCubic(ej / 90) : 1 - outBack((ej - 300) / 110);
        if (t < 290) return 0;
        if (t < contact) return outCubic((t - 290) / 130);
        return 1 - outBack((t - contact) / 110);
    }
    readonly property real jolt: seated ? 7 * ui * Math.exp(-(t - contact) / 70) * Math.cos((t - contact) / 30) : 0
    readonly property real ring: seated ? (t - contact) / 460 : 0
    readonly property real ring2: launched ? (t - launchedAt) / 460 : 0
    // Unlit until contact, then breathing for as long as the game takes to start.
    readonly property real lamp: {
        if (!seated) return 0;
        if (launched) return 1;
        var since = t - contact;
        return since < 360 ? 1 : 0.42 + 0.58 * (0.5 + 0.5 * Math.cos((since - 360) / 1200 * 2 * Math.PI));
    }
    readonly property real neighbours: {
        if (ej >= 0) return outCubic((ej - 120) / 300);
        return inserting ? 1 - outCubic((t - 90) / 240) : 1;
    }
    readonly property real titleShown: inserting ? 1 - outCubic((t - 240) / 160) : 1
    readonly property real dim: inserting ? outCubic((t - 340) / 560) : 0
    readonly property real blackout: launched ? clamp01((t - launchedAt) / 320) : 0
    // At contact the slot's light runs out to both edges, then rises off it as one line, and the
    // game's title screen is what it leaves behind. Ejecting runs the same line back down.
    property bool shutting: false
    readonly property real since: seated ? t - contact : 0
    readonly property real seam: {
        if (ej >= 0) return shutting ? 1 - outCubic((ej - 200) / 180) : 0;
        return seated ? (Tok.reducedMotion ? 1 : outCubic(since / 220)) : 0;
    }
    readonly property real bootOpen: {
        if (ej >= 0) return shutting ? 1 - inOut(ej / 240) : 0;
        if (!seated) return 0;
        return Tok.reducedMotion ? 1 : inOut((since - 150) / 560);
    }

    property real menuT: 0
    property real gameT: 0
    property real gridT: 0
    property real statsT: 0
    property real guideT: 0
    property real holdP: 0
    property string notice: ""
    property real noticeLeft: 0
    property real checkAcc: 0
    property real pollAcc: 0

    function approach(cur, aim, dt) {
        if (cur === aim) return cur;
        var by = dt / (Tok.reducedMotion ? 1 : 200);
        return aim > cur ? Math.min(aim, cur + by) : Math.max(aim, cur - by);
    }
    function step(dt) {
        // Not on screen yet: nothing should spend the startup screen's time before it can be seen.
        if (!(bp.width > 0)) return;
        if (bp.boot >= 0) {
            bp.boot += dt;
            if (bp.boot >= bp.bootEnd) bp.boot = -1;
        }
        bp.railPos += (bp.index - bp.railPos) * (1 - Math.exp(-dt / 70));
        if (Math.abs(bp.index - bp.railPos) < 0.001) bp.railPos = bp.index;
        if (bg.frontOpacity < 1) bg.frontOpacity = Math.min(1, bg.frontOpacity + dt / 220);
        if (bp.room < 1) bp.room = Math.min(1, bp.room + dt / 260);
        bp.menuT = bp.approach(bp.menuT, bp.inSettings() ? 1 : 0, dt);
        bp.guideT = bp.approach(bp.guideT, bp.focusOn === "guide" ? 1 : 0, dt);
        bp.gameT = bp.approach(bp.gameT, bp.under("game") ? 1 : 0, dt);
        bp.gridT = bp.approach(bp.gridT, bp.under("grid") ? 1 : 0, dt);
        bp.statsT = bp.approach(bp.statsT, bp.under("stats") ? 1 : 0, dt);
        if (bp.noticeLeft > 0) {
            bp.noticeLeft -= dt;
            if (bp.noticeLeft <= 0) bp.notice = "";
        }
        if (bp.t >= 0) {
            bp.t += dt;
            if (bp.t >= bp.contact && !bp.launchSent) {
                bp.launchSent = true;
                bp.uiSound("insert");
                bp.launch();
            }
            bp.checkAcc += dt;
            if (bp.checkAcc >= 500) {
                bp.checkAcc = 0;
                bp.checkGame();
            }
        }
        if (bp.ej >= 0) {
            bp.ej += dt;
            if (bp.ej > 480) bp.ej = -1;
        }
        if (bp.holding) {
            bp.holdP = Math.min(1, bp.holdP + dt / 900);
            if (bp.holdP >= 1) {
                var id = bp.holding;
                bp.holding = "";
                bp.holdP = 0;
                bp.rowAct({ id: id });
            }
        }
        // What a page shows can change while it is open: networks, a device that just paired.
        bp.pollAcc += dt;
        if (bp.pollAcc >= 1000) {
            bp.pollAcc = 0;
            bp.finishPairing();
            bp.netAge += 1;
            if (bp.modeUndo) {
                bp.modeLeft -= 1;
                if (bp.modeLeft <= 0) bp.undoMode();
            }
            if (bp.panelKind === "settings" && bp.pageId === "net" && bp.menuT > 0 && bp.netAge >= 8) bp.loadPage();
        }
    }
    FrameAnimation {
        running: !bp.manualClock && bp.visible && !bp.gameShowing
        onTriggered: bp.step(frameTime * 1000)
    }

    function say(text) {
        bp.notice = text;
        bp.noticeLeft = 2800;
    }
    function run(cmd) {
        if (bp.dry) { console.log("BPRUN", JSON.stringify(cmd)); return; }
        Quickshell.execDetached(cmd);
    }
    // One small set, made by scripts/gen-bp-sounds.py so they belong together. cfg.sfx is
    // on, quiet or off, from Settings → Sound.
    readonly property string soundDir: bp.tickSnd.replace(/bp-tick\.wav$/, "")
    readonly property var soundFiles: ({
        tick: "bp-tick.wav", click: "bp-click.wav", back: "bp-back.wav", open: "bp-open.wav",
        bump: "bp-bump.wav", "toggle-on": "bp-toggle-on.wav", "toggle-off": "bp-toggle-off.wav",
        insert: "bp-insert.wav", launch: "bp-launch.wav", boot: "bp-boot.wav", exit: "bp-exit.wav",
        error: "bp-error.wav", star: "bp-star.wav"
    })
    readonly property real sfxLevel: bp.cfg.sfx === "off" ? 0 : bp.cfg.sfx === "quiet" ? 0.4 : 0.9
    function uiSound(kind) {
        if (bp.dry || bp.sfxLevel <= 0 || !bp.soundFiles[kind]) return;
        Quickshell.execDetached(["pw-play", "--volume=" + bp.sfxLevel, bp.soundDir + bp.soundFiles[kind]]);
    }
    // Set by anything that has already played its own sound for this press.
    property bool soundTaken: false
    function navState() {
        return [bp.focusOn, bp.index, bp.gridSel, bp.menuSel, bp.rowSel, bp.dockSel, bp.guideSel,
                bp.gameTab, bp.statTab, bp.onPlay, bp.shelfSort, bp.sourceFilter, bp.holding].join("|");
    }
    // What a press sounds like is worked out from what it changed, so every page gets the same
    // language without each branch of the input handling needing to know about sound.
    function soundFor(a, focusBefore, stateBefore, wasInserting) {
        if (bp.gameShowing) return "";
        if (wasInserting) return bp.ej >= 0 && a === "b" ? "back" : "";
        if (bp.inserting) return "";
        var isMove = a === "up" || a === "down" || a === "left" || a === "right" || a === "l" || a === "r";
        if (bp.focusOn !== focusBefore) {
            if (bp.focusOn === "guide") return "open";
            if (focusBefore === "guide" || a === "b" || a === "left" || a === "home" || a === "menu") return "back";
            if (a === "up" || a === "down") return "tick";
            return "open";
        }
        if (bp.navState() !== stateBefore) return isMove ? "tick" : "click";
        if (isMove) return "bump";
        if (a === "a") return "click";
        return "";
    }
    function focusScreen() {
        if (bp.dry || !bp.screenName) return;
        Hyprland.dispatch("hl.dsp.focus({ monitor = \"" + bp.screenName + "\" })");
    }

    // ---- entering and leaving ----
    property bool gameModeOn: false
    property bool weTurnedGameModeOn: false
    FileView {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sea-gamemode.json"
        watchChanges: true
        printErrors: false
        function apply() { try { bp.gameModeOn = !!JSON.parse(text()).on; } catch (e) {} }
        Component.onCompleted: apply()
        onLoaded: apply()
        onFileChanged: reload()
    }
    function enter() {
        bp.focusOn = "shelf";
        bp.panelKind = "settings";
        bp.menuT = 0;
        bp.guideT = 0;
        radioProc.running = true;
        bp.gameT = 0;
        bp.gridT = 0;
        bp.statsT = 0;
        bp.t = -1;
        bp.launchedAt = -1;
        bp.ej = -1;
        bp.room = 1;
        bp.boot = Tok.reducedMotion ? -1 : 0;
        bp.uiSound(bp.boot >= 0 ? "boot" : "open");
        bp.dryWindow = false;
        bp.gameShowing = false;
        bp.handoffTop = null;
        bp.handoffFor = 0;
        bp.steamHandoff = false;
        bp.steamSeen = false;
        bp.closedSteam = false;
        bp.appHandoff = "";
        bp.lastInput = Date.now();
        bp.refresh();
        bp.focusScreen();
        bp.forceActiveFocus();
        // Only undone on the way out if it was this that turned it on. Not in the gaming session,
        // where it would hold the performance profile for as long as the machine is on: there,
        // each game turns it on for itself ("Game mode on play").
        bp.weTurnedGameModeOn = !bp.gameModeOn && !bp.session;
        if (bp.weTurnedGameModeOn) bp.run(["sh", bp.gameModeScript, "on"]);
        // Steam started now, out of sight, is ready by the time Play is pressed.
        bp.keepSteamHidden = true;
        bp.hideSteamWindows();
        bp.run(["python3", bp.gamingScript, "steam-warm"]);
    }
    function leave() {
        bp.uiSound("exit");
        bp.releaseSteamWindows();
        bp.steamHandoff = false;
        bp.stopSearching();
        if (bp.weTurnedGameModeOn) bp.run(["sh", bp.gameModeScript, "off"]);
        bp.weTurnedGameModeOn = false;
        bp.exited();
    }
    function refresh() {
        libProc.running = true;
        sumProc.running = true;
        preProc.running = true;
    }

    // ---- the game ----
    property var knownTops: []
    function insert() {
        if (bp.inserting || !bp.game) return;
        bp.knownTops = ToplevelManager.toplevels.values.slice();
        bp.knownAddrs = bp.currentAddrs();
        bp.launchSent = false;
        bp.launchedAt = -1;
        bp.ej = -1;
        bp.checkAcc = 0;
        bp.focusOn = "shelf";
        bp.t = Tok.reducedMotion ? bp.contact : 0;
        bp.handoffTop = null;
        bp.handoffFor = 0;
        bp.closedSteam = false;
    }
    function launch() {
        bp.focusScreen();
        bp.run(["python3", bp.gamingScript, "play", "" + bp.game.appid]);
    }
    // Steam's own Big Picture, on the same screen. Our room hides. The other screen stays dark.
    property bool steamHandoff: false
    property bool steamSeen: false
    property int steamGone: 0
    property int steamTries: 0
    property bool closedSteam: false
    function steamBigPicture() {
        bp.releaseSteamWindows();
        bp.steamHandoff = true;
        bp.steamSeen = false;
        bp.steamGone = 0;
        bp.steamTries = 0;
        bp.run(["steam", "steam://open/bigpicture"]);
        steamRaise.restart();
    }
    function ipcOf(t) {
        try { return (t && t.lastIpcObject) ? t.lastIpcObject : null; } catch (e) { return null; }
    }
    function findSteam() {
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var any = null;
        for (var i = 0; i < list.length; i++) {
            var h = list[i], o = bp.ipcOf(h);
            var cls = "" + ((o && o.class) || (h.wayland && h.wayland.appId) || "");
            var title = "" + ((o && o.title) || "");
            if (!/steam/i.test(cls)) continue;
            if (/big picture/i.test(title)) return h;
            any = h;
        }
        var tops = ToplevelManager.toplevels.values;
        for (var j = 0; j < tops.length; j++)
            if (/^steam(webhelper)?$/i.test("" + (tops[j].appId || ""))) return tops[j];
        return any;
    }
    // Steam's own windows stay out of sight while this is up: its library popping open on Play
    // is what showed beside the game for a moment before it went full screen. They go to a
    // special workspace the moment they map. Not while Steam's Big Picture is the one showing.
    readonly property string steamStash: "special:sea-steam"
    property bool keepSteamHidden: false
    function isSteamClass(cls) { return /^(steam|steamwebhelper)$/i.test("" + cls); }
    function stashWindow(addr) {
        if (bp.dry || !addr) return;
        if (addr.indexOf("0x") !== 0) addr = "0x" + addr;
        Hyprland.dispatch("hl.dsp.window.move({ workspace = '" + bp.steamStash + "', follow = false, window = 'address:" + addr + "' })");
    }
    function hideSteamWindows() {
        if (bp.dry) return;
        try { Hyprland.refreshToplevels(); } catch (e) {}
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < list.length; i++) {
            var o = bp.ipcOf(list[i]);
            if (!o || !o.address || !bp.isSteamClass(o.class)) continue;
            if (o.workspace && o.workspace.name === bp.steamStash) continue;
            bp.stashWindow("" + o.address);
        }
    }
    // On the way out the library window is closed, which leaves Steam running in the tray, and
    // anything else of Steam's (a sign-in or update prompt) comes back where it can be answered.
    function releaseSteamWindows() {
        bp.keepSteamHidden = false;
        if (bp.dry) return;
        try { Hyprland.refreshToplevels(); } catch (e) {}
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var here = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.name : "1";
        for (var i = 0; i < list.length; i++) {
            var o = bp.ipcOf(list[i]);
            if (!o || !o.address || !o.workspace || o.workspace.name !== bp.steamStash) continue;
            var addr = "address:" + o.address;
            if (/^(steam|friends list|special offers)$/i.test("" + (o.title || "")))
                Hyprland.dispatch("hl.dsp.window.close({ window = '" + addr + "' })");
            else
                Hyprland.dispatch("hl.dsp.window.move({ workspace = '" + here + "', follow = false, window = '" + addr + "' })");
        }
    }
    Connections {
        target: Hyprland
        enabled: bp.keepSteamHidden && !bp.steamHandoff
        function onRawEvent(ev) {
            if (ev.name !== "openwindow") return;
            var d = ("" + ev.data).split(",");
            if (d.length >= 3 && bp.isSteamClass(d[2])) bp.stashWindow(d[0]);
        }
    }

    property var knownAddrs: []
    function currentAddrs() {
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var o = bp.ipcOf(list[i]);
            if (o && o.address) out.push("" + o.address);
        }
        return out;
    }
    // A window that appeared after Play and is not Steam. That is the game, even when its
    // app id is empty, which is how the Unreal splash was left tiled beside Steam.
    function gameAddress() {
        try { Hyprland.refreshToplevels(); } catch (e) {}
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var found = "";
        for (var i = 0; i < list.length; i++) {
            var o = bp.ipcOf(list[i]);
            if (!o || !o.address) continue;
            var addr = "" + o.address;
            if (bp.knownAddrs.indexOf(addr) >= 0) continue;
            var cls = "" + (o.class || "");
            if (/steam|cursor|quickshell/i.test(cls)) continue;
            found = addr;
        }
        return found;
    }
    // Hyprland 0.57 only accepts the hl.dsp form. The old fullscreenstate dispatch was ignored,
    // so the game stayed split with Steam.
    function placeWindow(t, fullscreen) {
        if (bp.dry) return;
        var addr = bp.gameAddress();
        if (!addr && t) {
            var o = bp.ipcOf(t);
            if (o && o.address) addr = "" + o.address;
        }
        if (!addr) return;
        Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + addr + "' })");
        if (fullscreen)
            Hyprland.dispatch("hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"set\" })");
    }
    function reclaim() {
        if (bp.appHandoff) {
            bp.appHandoff = "";
            bp.appSeen = false;
            bp.focusScreen();
            bp.forceActiveFocus();
            return;
        }
        if (!bp.steamHandoff) return;
        bp.keepSteamHidden = true;
        bp.steamHandoff = false;
        bp.steamSeen = false;
        bp.steamGone = 0;
        bp.run(["steam", "steam://close/bigpicture"]);
        bp.focusScreen();
        bp.forceActiveFocus();
    }
    function presentSteam() {
        if (!bp.steamHandoff) return;
        var t = bp.findSteam();
        bp.steamTries += 1;
        if (!t) {
            if (bp.steamTries < 8) steamRaise.restart();
            return;
        }
        bp.steamSeen = true;
        bp.placeWindow(t, true);
    }
    // Proton games usually map with an empty app id, and a game can also take over a Steam
    // window that was already open. Those were skipped, so the overlay stayed above the game.
    function shellChrome(id) {
        return /^(steamwebhelper|quickshell|org\.quickshell)$/i.test(id);
    }
    function freshGame() {
        if (bp.dry) return null;
        var tops = ToplevelManager.toplevels.values;
        var strong = null, weak = null;
        for (var i = 0; i < tops.length; i++) {
            var t = tops[i];
            var id = "" + (t.appId || "");
            var known = bp.knownTops.indexOf(t) >= 0;
            if (/steam_app_|^gamescope$/i.test(id)) { strong = t; continue; }
            if (known || bp.shellChrome(id)) continue;
            // Steam's own window is Big Picture, not the game. Counting it left the game beside it.
            if (/^(steam|steamwebhelper)$/i.test(id)) continue;
            if (id === "") { if (!weak) weak = t; continue; }
            strong = t;
        }
        return strong || weak;
    }
    function raiseTop(t) {
        if (!t || bp.dry) return;
        bp.placeWindow(t, true);
        // Steam Big Picture is a second window next to the game. Close it once the game is up.
        if (!bp.closedSteam) {
            bp.closedSteam = true;
            bp.run(["steam", "steam://close/bigpicture"]);
        }
    }
    function gameWindows() {
        if (bp.dry) return bp.dryWindow ? 1 : 0;
        return bp.freshGame() ? 1 : 0;
    }
    property int goneFor: 0
    property var handoffTop: null
    property int handoffFor: 0
    function checkGame() {
        var n = bp.gameWindows();
        if (bp.gameShowing) {
            // A launcher often closes just before its game opens, so give it a moment.
            bp.goneFor = n > 0 ? 0 : bp.goneFor + 1000;
            if (bp.goneFor >= 4000) bp.endGame();
            return;
        }
        if (!(bp.seated && bp.launchedAt < 0)) return;
        var top = bp.freshGame();
        if (!top) {
            bp.handoffTop = null;
            bp.handoffFor = 0;
            if (bp.t > bp.contact + 120000) {
                bp.ejectCard();
                bp.uiSound("error");
                bp.say("The game has not opened. It may still be starting.");
            }
            return;
        }
        if (top !== bp.handoffTop) {
            bp.handoffTop = top;
            bp.handoffFor = 0;
            return;
        }
        bp.handoffFor += 500;
        // The launch screen holds until the same window has stayed up. The game goes full screen
        // under it first, so when the overlay drops there is no desktop or split layout to see,
        // then it is raised. Hiding is still what hands it the keyboard.
        if (bp.handoffFor >= 400 && !dropLater.running) {
            bp.hideSteamWindows();
            bp.fullscreenUnder(top);
            dropLater.restart();
        }
    }
    function fullscreenUnder(t) {
        if (bp.dry) return;
        var addr = bp.gameAddress();
        if (!addr && t) {
            var o = bp.ipcOf(t);
            if (o && o.address) addr = "" + o.address;
        }
        if (addr) Hyprland.dispatch("hl.dsp.window.fullscreen({ mode = 'fullscreen', action = 'set', window = 'address:" + addr + "' })");
    }
    Timer {
        id: dropLater
        interval: 250
        onTriggered: {
            if (!bp.seated || bp.launchedAt >= 0) return;
            bp.launchedAt = bp.t;
            bp.uiSound("launch");
            bp.gameShowing = true;
            bp.raiseTop(bp.handoffTop);
            raiseLater.restart();
        }
    }
    function ejectCard() {
        bp.shutting = bp.seated;
        bp.t = -1;
        bp.launchedAt = -1;
        bp.handoffTop = null;
        bp.handoffFor = 0;
        bp.room = 0;
        bp.ej = Tok.reducedMotion ? -1 : 0;
    }
    function endGame() {
        bp.gameShowing = false;
        bp.goneFor = 0;
        bp.ejectCard();
        bp.refresh();
        bp.focusScreen();
        bp.showLastRun = true;
        bp.forceActiveFocus();
    }
    Timer {
        interval: 1000
        repeat: true
        running: bp.gameShowing
        onTriggered: bp.checkGame()
    }
    // The overlay releases keyboard focus a moment after it hides. Raise the game again then.
    Timer {
        id: raiseLater
        interval: 600
        repeat: true
        property int shots: 0
        onTriggered: {
            bp.raiseTop(bp.handoffTop);
            shots += 1;
            if (shots >= 4) { shots = 0; stop(); }
        }
    }
    Timer {
        id: steamRaise
        interval: 900
        onTriggered: bp.presentSteam()
    }
    Timer {
        interval: 1000
        repeat: true
        running: bp.steamHandoff
        onTriggered: {
            if (bp.findSteam()) { bp.steamSeen = true; bp.steamGone = 0; return; }
            if (!bp.steamSeen) return;
            bp.steamGone += 1000;
            if (bp.steamGone >= 2500) { if (bp.session) bp.reclaim(); else bp.leave(); }
        }
    }
    // Another launcher (Heroic, Lutris) shown full screen in the gaming session, where there is no
    // desktop to open it on. Home comes back, and so does closing it.
    property string appHandoff: ""
    property bool appSeen: false
    property int appTries: 0
    function findApp(cls) {
        var list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < list.length; i++) {
            var o = bp.ipcOf(list[i]);
            if (o && o.address && new RegExp(cls, "i").test("" + (o.class || ""))) return list[i];
        }
        return null;
    }
    function openApp(src) {
        bp.run(src.cmd);
        if (!bp.session) { bp.leave(); return; }
        bp.appHandoff = src.cls;
        bp.appSeen = false;
        bp.appTries = 0;
        bp.say("Opening " + src.l + ". Home comes back here.");
    }
    Timer {
        interval: 1000
        repeat: true
        running: bp.appHandoff !== ""
        onTriggered: {
            try { Hyprland.refreshToplevels(); } catch (e) {}
            var t = bp.findApp(bp.appHandoff);
            if (t) {
                if (!bp.appSeen && !bp.dry) {
                    var addr = "address:" + bp.ipcOf(t).address;
                    Hyprland.dispatch("hl.dsp.focus({ window = '" + addr + "' })");
                    Hyprland.dispatch("hl.dsp.window.fullscreen({ mode = 'fullscreen', action = 'set', window = '" + addr + "' })");
                }
                bp.appSeen = true;
                return;
            }
            bp.appTries += 1;
            if (bp.appSeen || bp.appTries > 45) bp.reclaim();
        }
    }
    property bool showLastRun: false

    // ---- input ----
    // shelf | dock | grid | guide | settings | page | game | stats
    property string focusOn: "shelf"
    // Which page the rows belong to. Set on opening rather than following focusOn, so a page keeps
    // its contents while it fades out.
    property string panelKind: "settings"
    // What the guide was opened over, and goes back to.
    property string guideFrom: "shelf"
    property bool onPlay: true
    property int menuSel: 0
    property int rowSel: 0
    property int gridSel: 0
    property int gameTab: 0
    property int statTab: 0
    property int dockSel: 0
    property int guideSel: 0
    property string holding: ""
    property bool usingPad: false
    // Power stays last: the dock's power button opens the last page.
    readonly property var pages: [
        { id: "sound", l: "Sound", i: "volume_up" },
        { id: "display", l: "Display", i: "tv" },
        { id: "net", l: "Wi-Fi", i: "wifi" },
        { id: "bt", l: "Bluetooth", i: "bluetooth" },
        { id: "pads", l: "Controllers", i: "sports_esports" },
        { id: "games", l: "Games", i: "joystick" },
        { id: "perf", l: "Performance", i: "speed" },
        { id: "system", l: "System", i: "computer" },
        { id: "power", l: "Power", i: "power_settings_new" }
    ]
    readonly property var dockItems: [
        { id: "grid", l: "All games", i: "apps" },
        { id: "stats", l: "Stats", i: "bar_chart" },
        { id: "settings", l: "Settings", i: "settings" },
        { id: "steam", l: "Steam", mark: "steam" },
        { id: "sleep", l: "Sleep", i: "bedtime" },
        { id: "power", l: "Power", i: "power_settings_new" }
    ]
    readonly property var guideItems: [
        { id: "home", l: "Home", i: "home" },
        { id: "grid", l: "All games", i: "apps" },
        { id: "stats", l: "Stats", i: "bar_chart" },
        { id: "settings", l: "Settings", i: "settings" },
        { id: "steam", l: "Steam", mark: "steam" },
        { id: "sleep", l: "Sleep", i: "bedtime" },
        { id: "power", l: "Power", i: "power_settings_new" }
    ]
    readonly property var gameTabs: ["Launch options", "Runs", "Manage"]
    readonly property var statTabs: ["Playtime", "Library", "Runs", "Hardware"]
    readonly property string pageId: panelKind === "game" ? "game" : panelKind === "stats" ? "stats" : pages[menuSel].id
    // Bumped when a launch option changes: it edits the game in place, which no binding can see.
    property int profileTick: 0
    readonly property var rows: { bp.profileTick; return bp.rowsFor(bp.pageId); }
    readonly property int gridColumns: 7

    function under(s) { return bp.focusOn === s || (bp.focusOn === "guide" && bp.guideFrom === s); }
    function inSettings() {
        return bp.focusOn === "settings" || bp.focusOn === "page"
            || (bp.focusOn === "guide" && (bp.guideFrom === "settings" || bp.guideFrom === "page"));
    }
    function openGuide() {
        bp.guideFrom = bp.focusOn;
        bp.guideSel = 0;
        bp.focusOn = "guide";
    }
    function go(id) {
        bp.holding = "";
        if (id === "home") bp.focusOn = "shelf";
        else if (id === "grid") { bp.gridSel = bp.index; bp.focusOn = "grid"; Qt.callLater(bp.gridShow); }
        else if (id === "stats") bp.openStats();
        else if (id === "settings") bp.openSettings(0);
        else if (id === "steam") bp.steamBigPicture();
        else if (id === "sleep") bp.run(["systemctl", "suspend"]);
        else if (id === "power") bp.openSettings(bp.pages.length - 1);
    }
    function input(a, fromPad) {
        bp.usingPad = !!fromPad;
        bp.lastInput = Date.now();
        // The press that wakes the screen only wakes it.
        if (bp.screenOff) { bp.wakeScreen(); return; }
        if (bp.kbd) { bp.kbdInput(a); return; }
        if (bp.boot >= 0) {
            var skipMove = a === "up" || a === "down" || a === "left" || a === "right";
            if (!skipMove && bp.boot < bp.bootHold) bp.boot = bp.bootHold;
            return;
        }
        var focusBefore = bp.focusOn, stateBefore = bp.navState(), wasInserting = bp.inserting;
        bp.soundTaken = false;
        bp.handleInput(a);
        if (!bp.soundTaken) bp.uiSound(bp.soundFor(a, focusBefore, stateBefore, wasInserting));
    }
    function handleInput(a) {
        var isMove = a === "up" || a === "down" || a === "left" || a === "right";
        if (bp.gameShowing || bp.ej >= 0) return;
        if (bp.inserting) {
            if (!bp.seated) {
                if (!isMove) bp.t = bp.contact;
            } else if (a === "b" && !bp.launched) {
                bp.ejectCard();
            }
            return;
        }
        if (bp.focusOn === "guide") {
            if (a === "up") bp.guideSel = Math.max(0, bp.guideSel - 1);
            else if (a === "down") bp.guideSel = Math.min(bp.guideItems.length - 1, bp.guideSel + 1);
            else if (a === "a" || a === "right") bp.go(bp.guideItems[bp.guideSel].id);
            else if (a === "b" || a === "left" || a === "home" || a === "menu") bp.focusOn = bp.guideFrom;
            return;
        }
        if (a === "home" || a === "menu") {
            bp.holding = "";
            bp.stopSearching();
            bp.openGuide();
            return;
        }
        if (bp.focusOn === "shelf") {
            if (a === "left") bp.move(-1);
            else if (a === "right") bp.move(1);
            else if (a === "l") bp.move(-5);
            else if (a === "r") bp.move(5);
            else if (a === "down") bp.focusOn = "dock";
            else if (a === "a") bp.openGame();
            else if (a === "x") bp.insert();
            else if (a === "y") bp.go("grid");
            else if (a === "view") bp.go("stats");
            else if (a === "b") bp.openGuide();
            return;
        }
        if (bp.focusOn === "dock") {
            if (a === "left" && bp.dockSel > 0) bp.dockSel--;
            else if (a === "right" && bp.dockSel < bp.dockItems.length - 1) bp.dockSel++;
            else if (a === "up" || a === "b") bp.focusOn = "shelf";
            else if (a === "a") bp.go(bp.dockItems[bp.dockSel].id);
            return;
        }
        if (bp.focusOn === "grid") {
            var n = bp.shelf.length, c = bp.gridColumns, was = bp.gridSel;
            if (a === "left") bp.gridSel = Math.max(0, was - 1);
            else if (a === "right") bp.gridSel = Math.min(n - 1, was + 1);
            else if (a === "up") bp.gridSel = Math.max(0, was - c);
            else if (a === "down") bp.gridSel = Math.min(n - 1, was + c);
            else if (a === "l") bp.gridSel = Math.max(0, was - c * 2);
            else if (a === "r") bp.gridSel = Math.min(n - 1, was + c * 2);
            else if (a === "y") bp.cycleSort();
            else if (a === "x") bp.cycleFilter();
            else if (a === "a") {
                bp.index = bp.gridSel;
                bp.railPos = bp.gridSel;
                bg.show(bp.gridSel);
                bp.openGame();
            }
            else if (a === "b") bp.focusOn = "shelf";
            if (bp.gridSel !== was) bp.gridShow();
            return;
        }
        if (bp.focusOn === "settings") {
            if (a === "up" && bp.menuSel > 0) { bp.stopSearching(); bp.menuSel--; bp.rowSel = 0; bp.loadPage(); }
            else if (a === "down" && bp.menuSel < bp.pages.length - 1) { bp.stopSearching(); bp.menuSel++; bp.rowSel = 0; bp.loadPage(); }
            else if (a === "a" || a === "right") {
                bp.rowSel = bp.firstRow();
                bp.focusOn = "page";
            }
            else if (a === "b" || a === "left") { bp.stopSearching(); bp.focusOn = "shelf"; }
            return;
        }
        // The shoulder buttons cycle the tabs of any page that has them.
        if ((a === "l" || a === "r") && (bp.focusOn === "game" || bp.focusOn === "stats")) {
            var d0 = a === "l" ? -1 : 1;
            if (bp.focusOn === "game") bp.gameTab = (bp.gameTab + d0 + bp.gameTabs.length) % bp.gameTabs.length;
            else bp.statTab = (bp.statTab + d0 + bp.statTabs.length) % bp.statTabs.length;
            bp.holding = "";
            bp.rowSel = bp.firstRow();
            return;
        }
        if (bp.focusOn === "game" && bp.onPlay) {
            if (a === "a") bp.insert();
            else if (a === "down") { bp.onPlay = false; bp.rowSel = bp.firstRow(); }
            else if (a === "b") bp.focusOn = "shelf";
            return;
        }
        // In a page: every row can be landed on, or a page of readouts seems stuck. Only titles are skipped.
        if (a === "up" || a === "down") {
            var d = a === "up" ? -1 : 1, moved = false;
            for (var i = bp.rowSel + d; i >= 0 && i < bp.rows.length; i += d)
                if (bp.selectable(bp.rows[i])) { bp.rowSel = i; moved = true; break; }
            if (!moved && a === "up" && bp.focusOn === "game") bp.onPlay = true;
            return;
        }
        var row = bp.rows[bp.rowSel];
        if (a === "left" || a === "right") {
            if (row && (row.k === "slider" || row.k === "choice" || row.k === "toggle")) bp.rowAdjust(row, a === "left" ? -1 : 1);
            else if (a === "left" && bp.focusOn === "page") bp.focusOn = "settings";
            return;
        }
        if (a === "b") {
            bp.holding = "";
            bp.holdP = 0;
            if (bp.focusOn === "page") bp.focusOn = "settings";
            else if (bp.focusOn === "game") bp.onPlay = true;
            else bp.focusOn = "shelf";
            return;
        }
        if (a === "y" && row && row.alt) { bp.rowAlt(row); return; }
        if (a === "a" && row) {
            if (row.k === "choice" || row.k === "toggle") bp.rowAdjust(row, 1);
            else if (row.k === "action" || (row.k === "bar" && row.appid)) bp.rowAct(row);
            else if (row.k === "hold") { bp.holding = row.id; bp.holdP = 0; }
        }
    }
    // ---- the on-screen keyboard ----
    // For whatever has to be typed with only a controller: a Wi-Fi password, a hidden network.
    // Every row is ten units wide, so moving up or down lands on the key under the one you left.
    property var kbd: null          // { title, secret, done(text) }
    property string kbdText: ""
    property int kbdRow: 1
    property int kbdCol: 0
    property bool kbdShift: false
    property bool kbdSyms: false
    property bool kbdReveal: false
    function keysOf(s) { return s.split(" ").map(function (c) { return { t: c, w: 1 }; }); }
    readonly property var kbdRows: {
        var digits = bp.keysOf("1 2 3 4 5 6 7 8 9 0");
        var back = { id: "back", i: "backspace", w: 1.5 }, done = { id: "done", l: "Done", w: 2 }, space = { id: "space", l: "space", w: 4 };
        if (bp.kbdSyms) return [
            digits,
            bp.keysOf("! @ # $ % ^ & * ( )"),
            bp.keysOf("- _ = + [ ] { } ; :"),
            [{ t: "\"", w: 1.5 }].concat(bp.keysOf("/ \\ | ~ ` < >"), [back]),
            [{ id: "syms", l: "abc", w: 2 }, { t: "?", w: 1 }, space, { t: ".", w: 1 }, done]
        ];
        return [
            digits,
            bp.keysOf("q w e r t y u i o p"),
            bp.keysOf("a s d f g h j k l '"),
            [{ id: "shift", i: "shift", w: 1.5 }].concat(bp.keysOf("z x c v b n m"), [back]),
            [{ id: "syms", l: "?123", w: 2 }, { t: "@", w: 1 }, space, { t: ".", w: 1 }, done]
        ];
    }
    function keyLeft(row, col) {
        var x = 0;
        for (var i = 0; i < col; i++) x += bp.kbdRows[row][i].w;
        return x;
    }
    function openKeyboard(title, secret, done) {
        bp.kbdText = "";
        bp.kbdRow = 1;
        bp.kbdCol = 0;
        bp.kbdShift = false;
        bp.kbdSyms = false;
        bp.kbdReveal = false;
        bp.kbd = { title: title, secret: secret, done: done };
    }
    function kbdType(c) {
        if (bp.kbdText.length >= 128) { bp.uiSound("bump"); return; }
        bp.kbdText += c;
        if (bp.kbdShift && /[a-z]/i.test(c)) bp.kbdShift = false;
    }
    function kbdBack() { bp.kbdText = bp.kbdText.slice(0, -1); }
    function kbdCancel() { bp.kbd = null; bp.uiSound("back"); }
    function kbdDone() {
        var cb = bp.kbd ? bp.kbd.done : null, text = bp.kbdText;
        bp.kbd = null;
        bp.kbdText = "";
        bp.uiSound("open");
        if (cb) cb(text);
    }
    function kbdPress(k) {
        if (k.t !== undefined) bp.kbdType(bp.kbdShift ? k.t.toUpperCase() : k.t);
        else if (k.id === "back") bp.kbdBack();
        else if (k.id === "space") bp.kbdType(" ");
        else if (k.id === "shift") bp.kbdShift = !bp.kbdShift;
        else if (k.id === "syms") { bp.kbdSyms = !bp.kbdSyms; bp.kbdCol = Math.min(bp.kbdCol, bp.kbdRows[bp.kbdRow].length - 1); }
        else if (k.id === "done") { bp.kbdDone(); return; }
        bp.uiSound("click");
    }
    function kbdInput(a) {
        var rows = bp.kbdRows;
        if (a === "left" || a === "right") {
            var n = rows[bp.kbdRow].length;
            bp.kbdCol = (bp.kbdCol + (a === "left" ? n - 1 : 1)) % n;
            bp.uiSound("tick");
        } else if (a === "up" || a === "down") {
            var to = bp.kbdRow + (a === "up" ? -1 : 1);
            if (to < 0 || to >= rows.length) { bp.uiSound("bump"); return; }
            var mid = bp.keyLeft(bp.kbdRow, bp.kbdCol) + rows[bp.kbdRow][bp.kbdCol].w / 2, x = 0, col = rows[to].length - 1;
            for (var i = 0; i < rows[to].length; i++) {
                if (mid < x + rows[to][i].w) { col = i; break; }
                x += rows[to][i].w;
            }
            bp.kbdRow = to;
            bp.kbdCol = col;
            bp.uiSound("tick");
        }
        else if (a === "a") bp.kbdPress(rows[bp.kbdRow][bp.kbdCol]);
        else if (a === "b" || a === "l") { if (bp.kbdText === "" && a === "b") bp.kbdCancel(); else { bp.kbdBack(); bp.uiSound("back"); } }
        else if (a === "x") { bp.kbdShift = !bp.kbdShift; bp.uiSound("click"); }
        else if (a === "y" || a === "r") { bp.kbdType(" "); bp.uiSound("click"); }
        else if (a === "view" && bp.kbd.secret) { bp.kbdReveal = !bp.kbdReveal; bp.uiSound("click"); }
        else if (a === "menu") bp.kbdDone();
        else if (a === "home") bp.kbdCancel();
    }
    function release(a) {
        if (a === "a") {
            bp.holding = "";
            bp.holdP = 0;
        }
    }
    function selectable(row) { return row.k !== "head"; }
    function move(d) {
        if (!bp.shelf.length) return;
        var next = Math.max(0, Math.min(bp.shelf.length - 1, bp.index + d));
        if (next === bp.index) return;
        bp.index = next;
        bg.show(next);
    }
    function cycleSort() {
        var order = bp.sortOrder;
        var keep = bp.shelf[bp.gridSel] ? bp.shelf[bp.gridSel].appid : "";
        bp.shelfSort = order[(order.indexOf(bp.shelfSort) + 1) % order.length];
        bp.resort(keep);
        bp.gridSel = bp.index;
        Qt.callLater(bp.gridShow);
    }
    // Every launcher, then each one in turn. The home shelf follows it too.
    function cycleFilter() {
        var order = [""].concat(bp.sourcesPresent);
        if (order.length < 2) { bp.uiSound("bump"); bp.soundTaken = true; return; }
        var keep = bp.shelf[bp.gridSel] ? bp.shelf[bp.gridSel].appid : "";
        bp.sourceFilter = order[(order.indexOf(bp.sourceFilter) + 1) % order.length];
        bp.resort(keep);
        bp.gridSel = bp.index;
        Qt.callLater(bp.gridShow);
    }
    function toggleFavourite() {
        var g = bp.game;
        if (!g) return;
        var on = !g.favourite;
        g.favourite = on;
        bp.profileTick++;
        bp.queueRun(["python3", bp.gamingScript, "favourite", "" + g.appid, on ? "on" : "off"]);
        bp.uiSound(on ? "star" : "toggle-off");
        bp.soundTaken = true;
        bp.say(on ? "Added to favourites" : "Removed from favourites");
    }
    function gridShow() { grid.positionViewAtIndex(bp.gridSel, GridView.Contain); }
    function openSettings(page) {
        bp.panelKind = "settings";
        bp.menuSel = page;
        bp.focusOn = "settings";
        bp.rowSel = 0;
        bp.loadPage();
    }
    function openGame() {
        if (!bp.game) return;
        bp.panelKind = "game";
        bp.gameTab = 0;
        bp.onPlay = true;
        bp.focusOn = "game";
        bp.rowSel = bp.firstRow();
    }
    function openStats() {
        bp.panelKind = "stats";
        bp.focusOn = "stats";
        bp.rowSel = bp.firstRow();
        sumProc.running = true;
    }
    function firstRow() {
        for (var i = 0; i < bp.rows.length; i++) if (bp.selectable(bp.rows[i])) return i;
        return 0;
    }
    function loadPage() {
        if (bp.pageId === "sound") { volProc.running = true; sinkProc.running = true; micProc.running = true; }
        else if (bp.pageId === "display") { brightProc.running = true; monProc.running = true; }
        else if (bp.pageId === "games") defProc.running = true;
        else if (bp.pageId === "system") sysProc.running = true;
        else if (bp.pageId === "perf") { perfProc.running = true; preProc.running = true; }
        else if (bp.pageId === "net") {
            bp.netAge = 0;
            wifiProc.running = true;
            savedProc.running = true;
            radioProc.running = true;
        }
    }

    Keys.onPressed: event => {
        // A real keyboard types straight into the on-screen one.
        if (bp.kbd && !bp.screenOff) {
            bp.lastInput = Date.now();
            event.accepted = true;
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) bp.kbdDone();
            else if (event.key === Qt.Key_Escape) bp.kbdCancel();
            else if (event.key === Qt.Key_Backspace) bp.kbdBack();
            else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down)
                bp.kbdInput(event.key === Qt.Key_Left ? "left" : event.key === Qt.Key_Right ? "right" : event.key === Qt.Key_Up ? "up" : "down");
            else if (event.text && event.text.length === 1 && event.text >= " ") bp.kbdType(event.text);
            else event.accepted = false;
            return;
        }
        var map = {};
        map[Qt.Key_Left] = "left"; map[Qt.Key_Right] = "right"; map[Qt.Key_Up] = "up"; map[Qt.Key_Down] = "down";
        map[Qt.Key_Return] = "a"; map[Qt.Key_Enter] = "a"; map[Qt.Key_Space] = "a";
        map[Qt.Key_Escape] = "b"; map[Qt.Key_Backspace] = "b"; map[Qt.Key_Tab] = "menu";
        map[Qt.Key_O] = "x"; map[Qt.Key_G] = "y"; map[Qt.Key_T] = "view";
        map[Qt.Key_PageUp] = "l"; map[Qt.Key_PageDown] = "r"; map[Qt.Key_Q] = "l"; map[Qt.Key_E] = "r";
        var a = map[event.key];
        if (a === undefined) return;
        event.accepted = true;
        // Held keys repeat for moving, but one press of Enter must not fire an action twice.
        if (event.isAutoRepeat && a !== "left" && a !== "right" && a !== "up" && a !== "down") return;
        bp.input(a, false);
    }
    Keys.onReleased: event => {
        if (event.isAutoRepeat) return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            event.accepted = true;
            bp.release("a");
        }
    }

    // ---- what the pages read ----
    property real volume: 0
    property bool muted: false
    property var sinks: []
    property string defaultSink: ""
    property real brightness: -1
    property string perfMode: "auto"
    property var preflight: []
    property var sessions: []
    property var networks: []
    property var savedNets: []
    property bool wifiOn: true
    property int netAge: 0

    // On a favourite's cover. Dark under it, because covers can be any colour.
    component FavBadge: Rectangle {
        property var game: null
        property real s: 1
        visible: !!(game && bp.favIds[game.appid])
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 12 * bp.ui * s
        width: 46 * bp.ui * s
        height: width
        radius: width / 2
        color: Qt.rgba(0, 0, 0, 0.62)
        border.width: Math.max(1, 1.5 * bp.ui)
        border.color: Qt.rgba(1, 1, 1, 0.22)
        Sym { anchors.centerIn: parent; text: "star"; sz: Math.round(28 * bp.ui * parent.s); color: "#ffd166" }
    }

    component Reader: Process {
        property var parse: function (s) {}
        stdout: StdioCollector { onStreamFinished: parse(text) }
    }
    Reader {
        id: libProc
        command: ["python3", bp.gamingScript, "library"]
        parse: function (s) {
            var keep = bp.game ? bp.game.appid : "";
            try { bp.games = JSON.parse(s) || []; } catch (e) { bp.games = []; }
            bp.resort(keep);
            bp.profileTick++;
            if (bp.showLastRun) {
                bp.showLastRun = false;
                if (bp.game && bp.game.last_session)
                    bp.say("Last run: " + bp.fmtRun(bp.game.last_session));
            }
        }
    }
    Reader {
        id: sumProc
        command: ["python3", bp.gamingScript, "summary", "--days", "7"]
        parse: function (s) {
            try { bp.sessions = JSON.parse(s).sessions || []; } catch (e) { bp.sessions = []; }
        }
    }
    Reader {
        id: preProc
        command: ["python3", bp.gamingScript, "preflight"]
        parse: function (s) {
            try { bp.preflight = JSON.parse(s).checks || []; } catch (e) { bp.preflight = []; }
        }
    }
    Reader {
        id: volProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        parse: function (s) {
            var m = s.match(/([0-9.]+)/);
            if (m) bp.volume = parseFloat(m[1]);
            bp.muted = s.indexOf("MUTED") >= 0;
        }
    }
    Reader {
        id: sinkProc
        command: ["python3", bp.audioScript, "--status"]
        parse: function (s) {
            try {
                var d = JSON.parse(s);
                bp.sinks = d.sinks || [];
                bp.defaultSink = d.default_sink || "";
            } catch (e) { bp.sinks = []; }
        }
    }
    Reader {
        id: brightProc
        command: ["brightnessctl", "-m"]
        parse: function (s) {
            var m = s.match(/,(\d+)%,/);
            bp.brightness = m ? parseInt(m[1]) / 100 : -1;
        }
    }
    Reader {
        id: perfProc
        command: ["sh", bp.perfScript, "status"]
        parse: function (s) { bp.perfMode = s.trim() || "auto"; }
    }
    Reader {
        id: radioProc
        command: ["nmcli", "radio", "wifi"]
        parse: function (s) { bp.wifiOn = s.trim() !== "disabled"; }
    }
    Reader {
        id: savedProc
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "con", "show"]
        parse: function (s) {
            bp.savedNets = s.split("\n").filter(function (l) { return /:802-11-wireless$/.test(l); })
                .map(function (l) { return l.replace(/:802-11-wireless$/, "").replace(/\\:/g, ":"); });
        }
    }
    Reader {
        id: wifiProc
        // The cache, not a fresh scan. A rescan on every look would stall the radio during a download.
        command: ["nmcli", "-t", "-f", "ACTIVE,SIGNAL,SECURITY,SSID", "dev", "wifi", "list"]
        parse: function (s) {
            var best = {};
            s.split("\n").forEach(function (l) {
                var m = l.match(/^(yes|no):(\d+):([^:]*):(.+)$/);
                if (!m) return;
                var ssid = m[4].replace(/\\:/g, ":");
                var n = { ssid: ssid, active: m[1] === "yes", signal: parseInt(m[2]), secure: m[3] !== "" && m[3] !== "--" };
                if (!best[ssid] || n.active || (!best[ssid].active && n.signal > best[ssid].signal)) best[ssid] = n;
            });
            bp.networks = Object.keys(best).map(function (k) { return best[k]; }).sort(function (a, b) {
                return (b.active - a.active) || (b.signal - a.signal);
            }).slice(0, 10);
        }
    }

    property real micVolume: -1
    property bool micMuted: false
    Reader {
        id: micProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"]
        parse: function (s) {
            var m = s.match(/([0-9.]+)/);
            bp.micVolume = m ? parseFloat(m[1]) : -1;
            bp.micMuted = s.indexOf("MUTED") >= 0;
        }
    }
    // The screen this is on, with every mode it offers.
    property var monitor: null
    Reader {
        id: monProc
        command: ["hyprctl", "monitors", "-j"]
        parse: function (s) {
            var list = [];
            try { list = JSON.parse(s) || []; } catch (e) {}
            var hit = null;
            for (var i = 0; i < list.length; i++) if (list[i].name === bp.screenName) hit = list[i];
            bp.monitor = hit || list[0] || null;
        }
    }
    // Launch options every game starts with until it is given its own.
    property var defaults: ({})
    Reader {
        id: defProc
        command: ["python3", bp.gamingScript, "defaults"]
        parse: function (s) { try { bp.defaults = JSON.parse(s) || {}; } catch (e) {} }
    }
    property var sysInfo: ({})
    Reader {
        id: sysProc
        command: ["sh", "-c", "df -B1 --output=size,avail \"$HOME\" | tail -1; cat \"$1\" 2>/dev/null || echo ?; uname -r; cat /etc/hostname 2>/dev/null || hostname",
                  "sh", Qt.resolvedUrl("VERSION").toString().replace("file://", "")]
        parse: function (s) {
            var l = s.split("\n"), disk = (l[0] || "").trim().split(/\s+/);
            bp.sysInfo = { size: parseFloat(disk[0]) || 0, free: parseFloat(disk[1]) || 0,
                           version: (l[1] || "").trim(), kernel: (l[2] || "").trim(), host: (l[3] || "").trim() };
        }
    }
    // Joining a network that needs a password, typed on the on-screen keyboard.
    property string joining: ""
    Process {
        id: joinProc
        property string ssid: ""
        stderr: StdioCollector { id: joinErr }
        onExited: code => {
            bp.joining = "";
            if (code === 0) { bp.uiSound("star"); bp.say("Connected to " + ssid); }
            else {
                bp.uiSound("error");
                // nmcli keeps the profile of a failed join, which would then be retried with the wrong password.
                bp.run(["nmcli", "con", "delete", "id", ssid]);
                bp.say(/secrets|password|802-1x/i.test(joinErr.text) ? "Wrong password for " + ssid : "Could not join " + ssid);
            }
            bp.netAge = 6;
        }
    }
    function joinNetwork(ssid, password, hidden) {
        if (bp.dry) { bp.run(["nmcli-join", ssid]); return; }
        bp.joining = ssid;
        joinProc.ssid = ssid;
        var cmd = ["nmcli", "--wait", "40", "dev", "wifi", "connect", ssid];
        if (password !== "") cmd.push("password", password);
        if (hidden) cmd.push("hidden", "yes");
        joinProc.command = cmd;
        joinProc.running = true;
        bp.say("Joining " + ssid);
    }

    // ---- the screen sleeping ----
    // Controller presses never reach Wayland, so the compositor's idle timer cannot see them; this
    // keeps its own, from every press that comes in. cfg.screenOff is minutes, 0 for never.
    property real lastInput: Date.now()
    property bool screenOff: false
    readonly property int screenOffMin: bp.cfg.screenOff !== undefined ? bp.cfg.screenOff : (bp.session ? 15 : 0)
    function wakeScreen() {
        bp.screenOff = false;
        bp.lastInput = Date.now();
        if (!bp.dry) Hyprland.dispatch("hl.dsp.dpms({ action = 'on' })");
    }
    Timer {
        interval: 20000
        repeat: true
        running: bp.visible && bp.screenOffMin > 0 && !bp.gameShowing && !bp.screenOff
        onTriggered: {
            if (Date.now() - bp.lastInput < bp.screenOffMin * 60000 || bp.inserting) return;
            bp.screenOff = true;
            if (!bp.dry) Hyprland.dispatch("hl.dsp.dpms({ action = 'off' })");
        }
    }

    // ---- a mode change waits to be kept ----
    // A mode the screen cannot show leaves nothing to press "keep" on, so it goes back by itself.
    property var modeUndo: null
    property int modeLeft: 0
    function monSpec(m) {
        return { name: m.name, mode: m.width + "x" + m.height + "@" + m.refreshRate.toFixed(3), pos: m.x + "x" + m.y, scale: m.scale };
    }
    function applyMon(spec) {
        bp.run(["hyprctl", "eval", "hl.monitor({ output = \"" + spec.name + "\", mode = \"" + spec.mode + "\", position = \""
                + spec.pos + "\", scale = " + spec.scale + " })"]);
        monLater.restart();
    }
    function changeMon(patch) {
        var m = bp.monitor;
        if (!m) return;
        var now = bp.monSpec(m);
        if (!bp.modeUndo) bp.modeUndo = now;
        bp.applyMon(Object.assign({}, now, patch));
        bp.modeLeft = 15;
    }
    function keepMode() {
        bp.modeUndo = null;
        bp.modeLeft = 0;
        bp.run(["python3", Qt.resolvedUrl("sea-display.py").toString().replace("file://", ""), "--persist"]);
        bp.say("Kept");
    }
    function undoMode() {
        if (!bp.modeUndo) return;
        bp.applyMon(bp.modeUndo);
        bp.modeUndo = null;
        bp.modeLeft = 0;
        bp.say("Put back");
    }
    Timer { id: monLater; interval: 900; onTriggered: monProc.running = true }

    // ---- Bluetooth ----
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool searching: !!adapter && adapter.discovering
    readonly property var btDevices: {
        if (bp.dry) return bp.dryDevices;
        return adapter && adapter.devices ? adapter.devices.values : [];
    }
    readonly property var btPads: btDevices.filter(function (d) {
        return (d.icon === "input-gaming" || /controller|gamepad|xbox|dualsense|dualshock|8bitdo|joy-con/i.test(d.name || d.deviceName || ""));
    })
    property var pairingDev: null
    function pair(dev) {
        if (bp.dry) { console.log("BPRUN", JSON.stringify(["bt-pair", dev.name])); return; }
        bp.pairingDev = dev;
        // Trusted, so it reconnects by itself from the next press of its home button.
        dev.trusted = true;
        dev.pair();
    }
    function finishPairing() {
        var dev = bp.pairingDev;
        if (!dev || !dev.paired) return;
        bp.pairingDev = null;
        if (!dev.connected) dev.connect();
    }
    function stopSearching() {
        if (bp.searching && !bp.dry) bp.adapter.discovering = false;
    }
    // A pad joined or left while this was open: say so, because its buttons are how you would know.
    property var lastPadNames: []
    property bool lastPadsKnown: false
    onPadsChanged: {
        var names = bp.pads.map(function (p) { return p.name; });
        names.forEach(function (n) { if (bp.lastPadNames.indexOf(n) < 0 && bp.visible && bp.lastPadsKnown) bp.say(n + " connected"); });
        bp.lastPadNames.forEach(function (n) { if (names.indexOf(n) < 0 && bp.visible) bp.say(n + " disconnected"); });
        bp.lastPadNames = names;
        bp.lastPadsKnown = true;
    }

    // ---- Gamescope arguments, as settings a controller can change ----
    function gsParse(str) {
        var bits = (str || "").trim().split(/\s+/).filter(function (b) { return b.length; });
        var g = { on: bits.length > 0, W: 0, H: 0, w: 0, h: 0, full: false, filter: "", fps: 0, rest: [] };
        for (var i = 0; i < bits.length; i++) {
            var b = bits[i], next = bits[i + 1];
            if (b === "--") continue;
            if (b === "-W") { g.W = parseInt(next); i++; }
            else if (b === "-H") { g.H = parseInt(next); i++; }
            else if (b === "-w") { g.w = parseInt(next); i++; }
            else if (b === "-h") { g.h = parseInt(next); i++; }
            else if (b === "-f") g.full = true;
            else if (b === "-F") { g.filter = next; i++; }
            else if (b === "-r") { g.fps = parseInt(next); i++; }
            else g.rest.push(b);
        }
        return g;
    }
    function gsBuild(g) {
        if (!g.on) return "";
        var a = [];
        if (g.W) a.push("-W", g.W, "-H", g.H);
        if (g.w) a.push("-w", g.w, "-h", g.h);
        if (g.full) a.push("-f");
        if (g.filter) a.push("-F", g.filter);
        if (g.fps) a.push("-r", g.fps);
        return a.concat(g.rest, ["--"]).join(" ");
    }
    readonly property var gsSizes: [
        { l: "720p", W: 1280, H: 720 }, { l: "900p", W: 1600, H: 900 }, { l: "1080p", W: 1920, H: 1080 },
        { l: "1440p", W: 2560, H: 1440 }, { l: "4K", W: 3840, H: 2160 }
    ]
    function gsSizeAt(W, H, first) {
        for (var i = 0; i < bp.gsSizes.length; i++)
            if (bp.gsSizes[i].W === W && bp.gsSizes[i].H === H) return i + first;
        return -1;
    }

    // ---- what a screen can show, from hyprctl's "1920x1080@165.00Hz" ----
    function modeList(m) {
        return (m.availableModes || []).map(function (s) {
            var x = ("" + s).match(/^(\d+)x(\d+)@([0-9.]+)/);
            return x ? { w: parseInt(x[1]), h: parseInt(x[2]), hz: parseFloat(x[3]) } : null;
        }).filter(function (x) { return x; });
    }
    function modeSizes(m) {
        var seen = [];
        bp.modeList(m).sort(function (a, b) { return b.w * b.h - a.w * a.h; }).forEach(function (x) {
            var k = x.w + "x" + x.h;
            if (seen.indexOf(k) < 0) seen.push(k);
        });
        var here = m.width + "x" + m.height;
        if (seen.indexOf(here) < 0) seen.unshift(here);
        return seen;
    }
    function modeRates(m, size) {
        var out = [];
        bp.modeList(m).forEach(function (x) {
            if (x.w + "x" + x.h !== size) return;
            if (!out.some(function (r) { return Math.abs(r - x.hz) < 0.5; })) out.push(x.hz);
        });
        if (!out.length) out.push(m.refreshRate);
        return out.sort(function (a, b) { return b - a; });
    }
    function btIcon(d) {
        var ic = "" + (d.icon || "");
        if (/headset|headphone/.test(ic)) return "headphones";
        if (/audio|speaker/.test(ic)) return "speaker";
        if (/gaming/.test(ic) || bp.btPads.indexOf(d) >= 0) return "sports_esports";
        if (/keyboard/.test(ic)) return "keyboard";
        if (/mouse|tablet/.test(ic)) return "mouse";
        if (/phone/.test(ic)) return "smartphone";
        if (/computer/.test(ic)) return "computer";
        return "bluetooth";
    }
    readonly property var kbLayouts: [
        { id: "us", l: "English (US)" }, { id: "gb", l: "English (UK)" }, { id: "de", l: "German" },
        { id: "fr", l: "French" }, { id: "es", l: "Spanish" }, { id: "it", l: "Italian" },
        { id: "pt", l: "Portuguese" }, { id: "br", l: "Portuguese (Brazil)" }, { id: "se", l: "Swedish" },
        { id: "pl", l: "Polish" }, { id: "ru", l: "Russian" }, { id: "jp", l: "Japanese" }, { id: "kr", l: "Korean" }
    ]

    // ---- rows: what each page offers ----
    function rowsFor(id) {
        if (id === "sound") {
            var outs = bp.sinks.map(function (s) { return s.label; });
            var outAt = 0;
            for (var i = 0; i < bp.sinks.length; i++) if (bp.sinks[i].name === bp.defaultSink) outAt = i;
            return [
                { k: "slider", id: "volume", l: "Volume", i: "volume_up", v: bp.volume },
                { k: "toggle", id: "mute", l: "Mute", i: "volume_off", on: bp.muted },
                { k: "choice", id: "sink", l: "Plays through", i: "speaker", opts: outs.length ? outs : ["Nothing found"], at: outAt },
                { k: "choice", id: "sfx", l: "Sound effects", i: "music_note", opts: ["On", "Quiet", "Off"],
                  at: bp.cfg.sfx === "quiet" ? 1 : bp.cfg.sfx === "off" ? 2 : 0 }
            ].concat(bp.micVolume < 0 ? [] : [
                { k: "head", l: "Microphone" },
                { k: "slider", id: "mic", l: "Microphone level", i: "mic", v: bp.micVolume },
                { k: "toggle", id: "micmute", l: "Mute microphone", i: "mic_off", on: bp.micMuted }
            ]);
        }
        if (id === "display") {
            var choices = ["Automatic"].concat(bp.screenChoices);
            var rows = [];
            if (bp.modeUndo) rows.push({ k: "action", id: "keepmode", l: "Keep this setting", i: "check_circle", lit: true,
                                         value: "Going back in " + bp.modeLeft + "s", alt: "Go back" });
            rows.push({ k: "choice", id: "screen", l: "Show on", i: "tv", opts: choices, at: Math.max(0, choices.indexOf(bp.cfg.screen === "auto" ? "Automatic" : bp.cfg.screen)) });
            rows.push({ k: "choice", id: "other", l: "Other screen", i: "desktop_access_disabled", opts: ["Black", "Leave on"], at: bp.cfg.other === "black" ? 0 : 1 });
            var m = bp.monitor;
            if (m) {
                rows.push({ k: "head", l: m.name + (m.model ? ", " + m.model : "") });
                var sizes = bp.modeSizes(m), here = m.width + "x" + m.height;
                rows.push({ k: "choice", id: "res", l: "Resolution", i: "aspect_ratio", opts: sizes, at: Math.max(0, sizes.indexOf(here)) });
                var rates = bp.modeRates(m, here);
                var rateAt = 0;
                for (var r = 0; r < rates.length; r++) if (Math.abs(rates[r] - m.refreshRate) < Math.abs(rates[rateAt] - m.refreshRate)) rateAt = r;
                rows.push({ k: "choice", id: "rate", l: "Refresh rate", i: "speed", opts: rates.map(function (x) { return Math.round(x) + " Hz"; }), at: rateAt, rates: rates });
                var scales = [1, 1.25, 1.5, 1.6, 2];
                var scaleAt = 0;
                for (var sc = 0; sc < scales.length; sc++) if (Math.abs(scales[sc] - m.scale) < Math.abs(scales[scaleAt] - m.scale)) scaleAt = sc;
                rows.push({ k: "choice", id: "scale", l: "Scale", i: "zoom_in", opts: scales.map(function (x) { return Math.round(x * 100) + "%"; }), at: scaleAt, scales: scales });
            }
            var vrr = bp.cfg.vrr !== undefined ? bp.cfg.vrr : 0;
            rows.push({ k: "choice", id: "vrr", l: "Variable refresh rate", i: "motion_photos_auto", opts: ["Off", "On", "Full screen only"], at: vrr });
            if (bp.brightness >= 0) rows.push({ k: "slider", id: "bright", l: "Laptop brightness", i: "brightness_medium", v: bp.brightness });
            return rows;
        }
        if (id === "net") {
            var nets = [{ k: "toggle", id: "wifi", l: "Wi-Fi", i: "wifi", on: bp.wifiOn }];
            if (bp.wifiOn) {
                if (bp.networks.length) nets.push({ k: "head", l: "Networks" });
                else nets.push({ k: "info", l: "Looking for networks", value: "" });
                bp.networks.forEach(function (n) {
                    var known = bp.savedNets.indexOf(n.ssid) >= 0;
                    nets.push({
                        k: "action", id: "net", net: n, l: n.ssid,
                        i: n.signal > 66 ? "wifi" : n.signal > 33 ? "wifi_2_bar" : "wifi_1_bar",
                        value: bp.joining === n.ssid ? "Joining" : n.active ? "Connected" : known ? "Saved" : n.secure ? "Needs a password" : "Open",
                        lit: n.active, alt: known ? "Forget" : ""
                    });
                });
                nets.push({ k: "action", id: "hidden", l: "Join a hidden network", i: "add" });
            }
            return nets;
        }
        if (id === "bt") {
            if (!bp.adapter && !bp.dry) return [{ k: "info", l: "No Bluetooth adapter", value: "" }];
            var bt = [{ k: "toggle", id: "bt", l: "Bluetooth", i: "bluetooth", on: bp.dry || bp.adapter.enabled }];
            if (!bp.dry && !bp.adapter.enabled) return bt;
            bt.push({ k: "action", id: "search", l: bp.searching ? "Searching" : "Look for devices", i: bp.searching ? "sync" : "bluetooth_searching", lit: bp.searching,
                      value: bp.searching ? "Put the device in pairing mode" : "" });
            var named = bp.btDevices.filter(function (d) { return d.paired || !/^([0-9A-F]{2}[-:]){5}[0-9A-F]{2}$/i.test(d.name || d.deviceName || ""); });
            var mine = named.filter(function (d) { return d.paired; }), near = named.filter(function (d) { return !d.paired; });
            function devRow(d) {
                var state = d.connected ? "Connected" : d.pairing ? "Pairing" : d.paired ? "Not connected" : "Pair";
                if (d.batteryAvailable) state = Math.round(d.battery * 100) + "%  " + state;
                return { k: "action", id: "dev", dev: d, l: d.name || d.deviceName || d.address, i: bp.btIcon(d), value: state, lit: d.connected, alt: d.paired ? "Forget" : "" };
            }
            if (mine.length) bt.push({ k: "head", l: "My devices" });
            mine.forEach(function (d) { bt.push(devRow(d)); });
            if (near.length) bt.push({ k: "head", l: "Nearby" });
            near.forEach(function (d) { bt.push(devRow(d)); });
            return bt;
        }
        if (id === "games") {
            var df = bp.defaults, gsd = bp.gsParse(df.gamescope);
            return [
                { k: "head", l: "Every game starts with these until you change its own" },
                { k: "toggle", id: "d_mangohud", key: "mangohud", l: "MangoHud", i: "monitoring", on: !!df.mangohud },
                { k: "toggle", id: "d_gmplay", key: "game_mode_on_play", l: "Game mode on play", i: "stadia_controller", on: df.game_mode_on_play !== false },
                { k: "toggle", id: "d_gamemode", key: "gamemode", l: "gamemoderun", i: "bolt", on: df.gamemode !== false },
                { k: "choice", id: "d_gs", l: "Run in Gamescope", i: "aspect_ratio", opts: ["Off", "Fullscreen", "Window"], at: !gsd.on ? 0 : gsd.full ? 1 : 2 },
                { k: "head", l: "Library" },
                { k: "info", l: "Games found", value: "" + bp.games.length },
                { k: "action", id: "rescan", l: "Look for new games", i: "refresh" },
                { k: "action", id: "steamui", l: "Open Steam", i: "storefront", value: "Store, sign-in, downloads" }
            ];
        }
        if (id === "system") {
            var sys = [];
            var offs = [0, 5, 10, 15, 30, 60];
            sys.push({ k: "choice", id: "screenoff", l: "Turn the screen off after", i: "bedtime", opts: ["Never", "5 minutes", "10 minutes", "15 minutes", "30 minutes", "1 hour"],
                       at: Math.max(0, offs.indexOf(bp.screenOffMin)) });
            if (bp.session) {
                var at = Math.max(0, bp.kbLayouts.map(function (k) { return k.id; }).indexOf(bp.cfg.kbLayout || "us"));
                sys.push({ k: "choice", id: "kb", l: "Keyboard layout", i: "keyboard", opts: bp.kbLayouts.map(function (k) { return k.l; }), at: at });
            }
            var si = bp.sysInfo;
            sys.push({ k: "head", l: "This machine" });
            if (si.host) sys.push({ k: "info", l: "Name", value: si.host });
            if (si.size) sys.push({ k: "info", l: "Free space", value: bp.fmtSize(si.free) + " of " + bp.fmtSize(si.size), bad: si.free < 20e9 });
            if (si.version) sys.push({ k: "info", l: "sea-shell", value: si.version });
            if (si.kernel) sys.push({ k: "info", l: "Kernel", value: si.kernel });
            return sys;
        }
        if (id === "perf") {
            var modes = ["auto", "quiet", "max"];
            var perf = [
                { k: "choice", id: "perf", l: "Fans and power", i: "mode_fan", opts: ["Auto", "Quiet", "Max"], at: Math.max(0, modes.indexOf(bp.perfMode)) },
                { k: "head", l: "This machine" },
                { k: "info", l: "Game mode", value: bp.gameModeOn ? "On" : "Off" }
            ];
            for (var c = 0; c < bp.preflight.length; c++)
                perf.push({ k: "info", l: bp.preflight[c].label, value: Tok.cap(bp.preflight[c].detail), bad: !bp.preflight[c].ok });
            return perf;
        }
        if (id === "pads") {
            var list = [];
            if (!bp.pads.length) list.push({ k: "info", l: "No controller connected", value: "" });
            for (var p = 0; p < bp.pads.length; p++)
                list.push({ k: "info", l: bp.pads[p].name, i: "sports_esports", value: bp.padDetail(bp.pads[p]), bad: bp.padLow(bp.pads[p]) });
            list.push({ k: "toggle", id: "home", l: "Home button opens this", i: "home", on: bp.cfg.home !== false });
            if (bp.adapter || bp.dry) {
                list.push({ k: "head", l: "Bluetooth" });
                list.push({ k: "toggle", id: "bt", l: "Bluetooth", i: "bluetooth", on: !!bp.adapter && bp.adapter.enabled });
                if (bp.dry || bp.adapter.enabled) {
                    list.push({ k: "action", id: "search", l: bp.searching ? "Searching for controllers" : "Pair a controller", i: bp.searching ? "sync" : "add", lit: bp.searching,
                                value: bp.searching ? "Put it in pairing mode" : "" });
                    bp.btPads.forEach(function (d) {
                        var nm = d.name || d.deviceName || d.address;
                        var state = d.connected ? "Connected" : d.pairing ? "Pairing" : d.paired ? "Paired" : "Pair";
                        if (d.batteryAvailable) state = Math.round(d.battery * 100) + "%  " + state;
                        list.push({ k: "action", id: "dev", dev: d, l: nm, i: "sports_esports", value: state, lit: d.connected });
                    });
                }
            }
            return list;
        }
        if (id === "power") return (bp.session ? [] : [{ k: "action", id: "desktop", l: "Back to desktop", i: "desktop_windows" }]).concat([
            { k: "hold", id: "logout", l: "Log out", i: "logout",
              sub: bp.session ? "Back to the login screen. Pick Hyprland there for the desktop." : "Closes every app and ends the session." },
            { k: "action", id: "suspend", l: "Suspend", i: "bedtime" },
            { k: "hold", id: "reboot", l: "Restart", i: "restart_alt" },
            { k: "hold", id: "off", l: "Shut down", i: "power_settings_new", dangerous: true }
        ]);
        if (id === "game") return bp.gameTab === 0 ? bp.gameOptions() : bp.gameTab === 1 ? bp.gameRuns() : bp.gameManage();
        if (id === "stats") return bp.statRows();
        return [];
    }
    function gameManage() {
        var g = bp.game;
        if (!g) return [];
        bp.profileTick;
        var fav = { k: "action", id: "fav", l: g.favourite ? "Remove from favourites" : "Add to favourites", i: "star" };
        if (g.source !== "steam") return [fav, { k: "action", id: "launcher", l: "Open " + bp.launcherName(g), i: "open_in_new" }];
        return [
            fav,
            { k: "action", id: "verify", l: "Verify game files", i: "verified" },
            { k: "action", id: "reset", l: "Use my default settings", i: "restart_alt" }
        ];
    }
    function gameRuns() {
        var g = bp.game;
        if (!g) return [];
        var runs = bp.sessions.filter(function (s) { return s.appid === g.appid; });
        if (!runs.length) return [{ k: "info", l: "None saved yet. Stats are kept when a game closes.", value: "" }];
        return runs.map(function (r) { return bp.runRow(r, false); });
    }
    function runRow(run, withName) {
        var st = run.stats || {};
        function cell(v, unit) { return v === undefined || v === null ? "–" : v + unit; }
        return {
            k: "run",
            l: withName ? bp.nameOf(run) : bp.fmtAgo(Date.parse(run.ended) / 1000),
            sub: withName ? bp.fmtAgo(Date.parse(run.ended) / 1000) + ", " + bp.fmt(run.seconds) : bp.fmt(run.seconds),
            cells: [
                { l: "FPS", v: cell(st.fps_avg, "") },
                { l: "1% low", v: cell(st.fps_1pct_low, "") },
                { l: "GPU", v: cell(st.gpu_avg === undefined ? undefined : Math.round(st.gpu_avg), "%") },
                { l: "Peak", v: cell(st.gpu_temp_max, "°C") },
                { l: "VRAM", v: cell(st.vram_peak, " GiB") }
            ]
        };
    }
    function nameOf(run) {
        for (var i = 0; i < bp.games.length; i++) if (bp.games[i].appid === run.appid) return bp.games[i].name;
        return (run.title || "").trim() || "Game";
    }
    function gameOptions() {
        var g = bp.game;
        if (!g) return [];
        // Heroic, Lutris, Twintail and Prism start these themselves, so nothing here could reach the launch.
        if (g.source !== "steam") return [
            { k: "info", l: "This game's launch options are in " + bp.launcherName(g), value: "" },
            { k: "action", id: "launcher", l: "Open " + bp.launcherName(g), i: "open_in_new" }
        ];
        var out = [];
        var prof = g.profile || {}, env = prof.env || {};
        var gs = bp.gsParse(prof.gamescope);

        out.push({ k: "head", l: "Overlay" });
        out.push({ k: "toggle", id: "mangohud", l: "MangoHud", i: "monitoring", on: !!prof.mangohud });
        if (prof.mangohud) {
            var caps = ["", "0", "60", "120", "144"], looks = ["", "fps", "compact", "full"];
            var corners = ["", "top-left", "top-right", "bottom-left", "bottom-right"];
            out.push({ k: "choice", id: "mh_fps", l: "FPS limit", i: "speed", opts: ["Your config", "No limit", "60", "120", "144"], at: Math.max(0, caps.indexOf("" + (prof.mh_fps || ""))) });
            out.push({ k: "choice", id: "mh_look", l: "Look", i: "tune", opts: ["Your config", "FPS only", "Compact", "Full"], at: Math.max(0, looks.indexOf("" + (prof.mh_look || ""))) });
            out.push({ k: "choice", id: "mh_corner", l: "Corner", i: "picture_in_picture", opts: ["Your config", "Top left", "Top right", "Bottom left", "Bottom right"], at: Math.max(0, corners.indexOf("" + (prof.mh_corner || ""))) });
        }

        out.push({ k: "head", l: "Gamescope" });
        out.push({ k: "choice", id: "gs_mode", l: "Run in Gamescope", i: "aspect_ratio", opts: ["Off", "Fullscreen", "Window"], at: !gs.on ? 0 : gs.full ? 1 : 2 });
        if (gs.on) {
            var outOpts = ["This screen"].concat(bp.gsSizes.map(function (s) { return s.l; }));
            var outAt = !gs.W || (gs.W === Math.round(bp.width) && gs.H === Math.round(bp.height)) ? 0 : Math.max(0, bp.gsSizeAt(gs.W, gs.H, 1));
            out.push({ k: "choice", id: "gs_out", l: "Output size", i: "fit_screen", opts: outOpts, at: outAt });
            var gameOpts = ["Same as output"].concat(bp.gsSizes.map(function (s) { return s.l; }));
            var gameAt = !gs.w || (gs.w === gs.W && gs.h === gs.H) ? 0 : Math.max(0, bp.gsSizeAt(gs.w, gs.h, 1));
            out.push({ k: "choice", id: "gs_game", l: "Game renders at", i: "photo_size_select_large", opts: gameOpts, at: gameAt });
            var filters = ["", "fsr", "nis", "pixel"];
            out.push({ k: "choice", id: "gs_filter", l: "Upscaling", i: "auto_awesome", opts: ["Off", "FSR", "NIS", "Pixel"], at: Math.max(0, filters.indexOf(gs.filter || "")) });
            var rates = [0, 30, 60, 90, 120, 144];
            out.push({ k: "choice", id: "gs_fps", l: "Frame limit", i: "timer", opts: ["Off", "30", "60", "90", "120", "144"], at: Math.max(0, rates.indexOf(gs.fps)) });
            if (gs.rest.length) out.push({ k: "info", l: "Other arguments", value: gs.rest.join(" ") });
        }

        out.push({ k: "head", l: "Performance" });
        out.push({ k: "toggle", id: "game_mode_on_play", l: "Game mode on play", i: "stadia_controller", on: prof.game_mode_on_play !== false });
        out.push({ k: "toggle", id: "gamemode", l: "gamemoderun", i: "bolt", on: prof.gamemode !== false });

        out.push({ k: "head", l: "Proton" });
        out.push({ k: "toggle", id: "env", envKey: "PROTON_ENABLE_WAYLAND", l: "Native Wayland", i: "layers", on: env.PROTON_ENABLE_WAYLAND === "1" });
        out.push({ k: "toggle", id: "env", envKey: "PROTON_ENABLE_HDR", l: "HDR", i: "hdr_on", on: env.PROTON_ENABLE_HDR === "1" });
        Object.keys(env).filter(function (k) { return k !== "PROTON_ENABLE_WAYLAND" && k !== "PROTON_ENABLE_HDR"; })
            .forEach(function (k) { out.push({ k: "info", l: k, value: "" + env[k] }); });
        return out;
    }
    function statRows() {
        if (bp.statTab === 0) {
            var recent = bp.games.filter(function (g) { return g.recent_seconds > 0; })
                .sort(function (a, b) { return b.recent_seconds - a.recent_seconds; });
            var total = recent.reduce(function (n, g) { return n + g.recent_seconds; }, 0);
            if (!recent.length) return [{ k: "info", l: "Nothing played in the last two weeks", value: "" }];
            return [{ k: "head", l: "Last two weeks: " + bp.fmt(total) }].concat(recent.map(function (g) {
                return { k: "bar", appid: g.appid, l: g.name, value: bp.fmt(g.recent_seconds), share: g.recent_seconds / total, cover: g.art || g.icon || "" };
            }));
        }
        if (bp.statTab === 1) {
            var played = bp.games.slice().sort(function (a, b) { return b.seconds - a.seconds; });
            var hours = played.reduce(function (n, g) { return n + (g.seconds || 0); }, 0);
            var disk = played.reduce(function (n, g) { return n + (g.size || 0); }, 0);
            var top = played.length ? played[0].seconds || 1 : 1;
            return [{ k: "head", l: played.length + (played.length === 1 ? " game, " : " games, ") + bp.fmt(hours) + " played, " + bp.fmtSize(disk) + " on disk" }]
                .concat(played.map(function (g) {
                    return { k: "bar", appid: g.appid, l: g.name, value: g.seconds > 0 ? bp.fmt(g.seconds) : "Not yet", share: (g.seconds || 0) / top, cover: g.art || g.icon || "" };
                }));
        }
        if (bp.statTab === 2) {
            if (!bp.sessions.length) return [{ k: "info", l: "None saved yet. Stats are kept when a game closes.", value: "" }];
            return bp.sessions.map(function (r) { return bp.runRow(r, true); });
        }
        return bp.hardwareRows();
    }
    // The saved runs read as totals, for all games and then each one. Only what was measured is shown.
    function hardwareRows() {
        if (!bp.sessions.length) return [{ k: "info", l: "None saved yet. Stats are kept when a game closes.", value: "" }];
        function block(title, runs) {
            function vals(key) {
                return runs.map(function (r) { return (r.stats || {})[key]; }).filter(function (v) { return v !== undefined && v !== null; });
            }
            function avg(a) { return a.reduce(function (n, v) { return n + v; }, 0) / a.length; }
            var out = [{ k: "head", l: title }];
            function add(label, value) { out.push({ k: "stat", l: label, value: value }); }
            add("Saved runs", "" + runs.length);
            var longest = runs.reduce(function (n, r) { return Math.max(n, r.seconds || 0); }, 0);
            add("Longest run", bp.fmt(longest));
            var fps = vals("fps_avg"), low = vals("fps_1pct_low"), gpu = vals("gpu_avg"), temp = vals("gpu_temp_max"), vram = vals("vram_peak");
            if (fps.length) add("Average FPS", "" + Math.round(avg(fps)));
            if (low.length) add("Worst 1% low", "" + Math.min.apply(null, low));
            if (gpu.length) add("Average GPU load", Math.round(avg(gpu)) + "%");
            if (temp.length) add("Hottest GPU", Math.max.apply(null, temp) + "°C");
            if (vram.length) add("Most VRAM", Math.max.apply(null, vram) + " GiB");
            return out;
        }
        var rows = block("All games", bp.sessions);
        var seen = {};
        bp.sessions.forEach(function (r) { seen[r.appid] = true; });
        Object.keys(seen).forEach(function (id) {
            var mine = bp.sessions.filter(function (r) { return r.appid === id; });
            rows = rows.concat(block(bp.nameOf(mine[0]), mine));
        });
        return rows;
    }
    function rowAdjust(row, d) {
        bp.soundTaken = true;
        if (row.id !== "sfx") bp.uiSound(row.k === "toggle" ? (row.on ? "toggle-off" : "toggle-on") : "tick");
        if (row.k === "toggle") {
            var on = !row.on;
            if (row.id === "mute") {
                bp.muted = on;
                bp.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", on ? "1" : "0"]);
            } else if (row.id === "wifi") {
                bp.wifiOn = on;
                bp.run(["nmcli", "radio", "wifi", on ? "on" : "off"]);
            } else if (row.id === "micmute") {
                bp.micMuted = on;
                bp.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", on ? "1" : "0"]);
            } else if (row.id.indexOf("d_") === 0) {
                bp.patchDefaults(row.key, on);
            } else if (row.id === "home") {
                bp.setCfg({ home: on });
            } else if (row.id === "bt") {
                if (bp.adapter && !bp.dry) bp.adapter.enabled = on;
            } else if (row.id === "env") {
                var e = {};
                e[row.envKey] = on ? "1" : null;
                bp.patchGame("env", e);
            } else {
                bp.patchGame(row.id, on);
            }
            return;
        }
        if (row.k === "slider") {
            var v = Math.round((row.v + d * 0.05) * 100) / 100;
            v = Math.max(row.id === "bright" ? 0.05 : 0, Math.min(1, v));
            if (row.id === "volume") {
                bp.volume = v;
                bp.run(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "" + v]);
            } else if (row.id === "bright") {
                bp.brightness = v;
                bp.run(["brightnessctl", "-q", "set", Math.round(v * 100) + "%"]);
            } else if (row.id === "mic") {
                bp.micVolume = v;
                bp.run(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SOURCE@", "" + v]);
            }
            return;
        }
        var n = row.opts.length, at = (row.at + d + n) % n;
        if (row.id === "res") {
            var wh = row.opts[at].split("x"), rs = bp.modeRates(bp.monitor, row.opts[at]);
            bp.changeMon({ mode: wh[0] + "x" + wh[1] + "@" + rs[0].toFixed(3) });
            return;
        }
        if (row.id === "rate") {
            bp.changeMon({ mode: bp.monitor.width + "x" + bp.monitor.height + "@" + row.rates[at].toFixed(3) });
            return;
        }
        if (row.id === "scale") {
            bp.changeMon({ scale: row.scales[at] });
            return;
        }
        if (row.id === "vrr") {
            bp.setCfg({ vrr: at });
            bp.run(["hyprctl", "eval", "hl.config({ misc = { vrr = " + at + " } })"]);
            return;
        }
        if (row.id === "screenoff") {
            bp.setCfg({ screenOff: [0, 5, 10, 15, 30, 60][at] });
            return;
        }
        if (row.id === "kb") {
            var lay = bp.kbLayouts[at].id;
            bp.setCfg({ kbLayout: lay });
            bp.run(["hyprctl", "eval", "hl.config({ input = { kb_layout = \"" + lay + "\" } })"]);
            return;
        }
        if (row.id === "d_gs") {
            var g = bp.gsParse(bp.defaults.gamescope);
            if (at > 0 && !g.on) { g.W = Math.round(bp.width); g.H = Math.round(bp.height); }
            g.on = at > 0;
            g.full = at === 1;
            bp.patchDefaults("gamescope", bp.gsBuild(g));
            return;
        }
        if (row.id === "sink" && bp.sinks.length) {
            bp.defaultSink = bp.sinks[at].name;
            bp.run(["python3", bp.audioScript, "--default", bp.sinks[at].name]);
        } else if (row.id === "screen") {
            bp.setCfg({ screen: at === 0 ? "auto" : row.opts[at] });
        } else if (row.id === "other") {
            bp.setCfg({ other: at === 0 ? "black" : "on" });
        } else if (row.id === "sfx") {
            bp.setCfg({ sfx: ["on", "quiet", "off"][at] });
            // After the change, so what you hear is the new level.
            Qt.callLater(function () { bp.uiSound("click"); });
        } else if (row.id === "perf") {
            bp.perfMode = ["auto", "quiet", "max"][at];
            bp.run(["sh", bp.perfScript, bp.perfMode]);
        } else if (row.id === "mh_fps") {
            bp.patchGame("mh_fps", ["", "0", "60", "120", "144"][at]);
        } else if (row.id === "mh_look") {
            bp.patchGame("mh_look", ["", "fps", "compact", "full"][at]);
        } else if (row.id === "mh_corner") {
            bp.patchGame("mh_corner", ["", "top-left", "top-right", "bottom-left", "bottom-right"][at]);
        } else if (row.id.indexOf("gs_") === 0) {
            bp.patchGamescope(row.id, at);
        }
    }
    function patchGamescope(id, at) {
        var g = bp.gsParse((bp.game.profile || {}).gamescope);
        if (id === "gs_mode") {
            // "This screen" is written out, because Gamescope's own default is 720p.
            if (at > 0 && !g.on) { g.W = Math.round(bp.width); g.H = Math.round(bp.height); }
            g.on = at > 0;
            g.full = at === 1;
        } else if (id === "gs_out") {
            var keepSame = !g.w || (g.w === g.W && g.h === g.H);
            if (at === 0) { g.W = Math.round(bp.width); g.H = Math.round(bp.height); }
            else { g.W = bp.gsSizes[at - 1].W; g.H = bp.gsSizes[at - 1].H; }
            if (keepSame) { g.w = 0; g.h = 0; }
        } else if (id === "gs_game") {
            if (at === 0) { g.w = 0; g.h = 0; }
            else { g.w = bp.gsSizes[at - 1].W; g.h = bp.gsSizes[at - 1].H; }
        } else if (id === "gs_filter") {
            g.filter = ["", "fsr", "nis", "pixel"][at];
        } else if (id === "gs_fps") {
            g.fps = [0, 30, 60, 90, 120, 144][at];
        }
        bp.patchGame("gamescope", bp.gsBuild(g));
    }
    function patchGame(key, value) {
        var g = bp.game;
        var patch = {};
        patch[key] = value;
        var prof = Object.assign({}, g.profile || {});
        if (key === "env") {
            var env = Object.assign({}, prof.env || {});
            for (var k in value) {
                if (value[k] === null) delete env[k];
                else env[k] = value[k];
            }
            prof.env = env;
        } else {
            prof[key] = value;
        }
        g.profile = prof;
        bp.profileTick++;
        bp.queueRun(["python3", bp.gamingScript, "profile-patch", "" + g.appid, JSON.stringify(patch)]);
    }
    function patchDefaults(key, value) {
        var patch = {};
        patch[key] = value;
        bp.defaults = Object.assign({}, bp.defaults, patch);
        bp.queueRun(["python3", bp.gamingScript, "defaults-patch", JSON.stringify(patch)]);
    }
    // Y on a row: the second thing it can do, named in the footer.
    function rowAlt(row) {
        bp.soundTaken = true;
        if (row.id === "keepmode") { bp.uiSound("back"); bp.undoMode(); }
        else if (row.id === "net") {
            bp.uiSound("toggle-off");
            bp.run(["nmcli", "con", "delete", "id", row.net.ssid]);
            bp.say("Forgot " + row.net.ssid);
            bp.savedNets = bp.savedNets.filter(function (s) { return s !== row.net.ssid; });
            bp.netAge = 6;
        } else if (row.id === "dev") {
            bp.uiSound("toggle-off");
            if (!bp.dry) row.dev.forget();
            bp.say("Forgot " + row.l);
        }
    }
    // One write at a time, in order: two quick presses running together could lose the first.
    property var writeQueue: []
    function queueRun(cmd) {
        if (bp.dry) { bp.run(cmd); return; }
        bp.writeQueue = bp.writeQueue.concat([cmd]);
        bp.flushWrites();
    }
    function flushWrites() {
        if (writeProc.running || !bp.writeQueue.length) return;
        writeProc.command = bp.writeQueue[0];
        bp.writeQueue = bp.writeQueue.slice(1);
        writeProc.running = true;
    }
    Process {
        id: writeProc
        onExited: bp.flushWrites()
    }
    function rowAct(row) {
        var id = row.id;
        if (row.k === "bar" && row.appid) {
            for (var g = 0; g < bp.shelf.length; g++) {
                if (bp.shelf[g].appid === row.appid) {
                    bp.index = g;
                    bp.railPos = g;
                    bg.show(g);
                }
            }
            bp.openGame();
            return;
        }
        if (id === "desktop") bp.leave();
        else if (id === "logout") bp.run(["sh", "-c", "systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }"]);
        else if (id === "suspend") bp.run(["systemctl", "suspend"]);
        else if (id === "reboot") bp.run(["systemctl", "reboot"]);
        else if (id === "off") bp.run(["systemctl", "poweroff"]);
        else if (id === "launcher") {
            var src = bp.game ? bp.launchers[bp.game.source] : null;
            if (src) bp.openApp(src);
        }
        else if (id === "fav") bp.toggleFavourite();
        else if (id === "verify") {
            bp.run(["steam", "steam://validate/" + bp.game.appid]);
            if (bp.session) bp.steamBigPicture();
            else bp.say("Steam is checking the files. Its window is on the desktop.");
        } else if (id === "keepmode") {
            bp.keepMode();
        } else if (id === "hidden") {
            bp.openKeyboard("Hidden network name", false, function (ssid) {
                if (!ssid) return;
                bp.openKeyboard("Password for " + ssid + " (leave empty if open)", true, function (pw) { bp.joinNetwork(ssid, pw, true); });
            });
        } else if (id === "rescan") {
            libProc.running = true;
            bp.say("Looking for new games");
        } else if (id === "steamui") {
            bp.steamBigPicture();
        } else if (id === "reset") {
            bp.queueRun(["python3", bp.gamingScript, "profile-reset", "" + bp.game.appid]);
            resetRead.restart();
            bp.say("Back to your default settings");
        } else if (id === "net") {
            var n = row.net;
            if (n.active) return;
            if (bp.joining) return;
            if (bp.savedNets.indexOf(n.ssid) >= 0) {
                bp.run(["nmcli", "con", "up", "id", n.ssid]);
                bp.say("Connecting to " + n.ssid);
                bp.netAge = 4;
            } else if (!n.secure) bp.joinNetwork(n.ssid, "");
            else bp.openKeyboard("Password for " + n.ssid, true, function (pw) { if (pw) bp.joinNetwork(n.ssid, pw); });
        } else if (id === "search") {
            if (bp.adapter && !bp.dry) bp.adapter.discovering = !bp.adapter.discovering;
        } else if (id === "dev") {
            var d = row.dev;
            if (!d.paired) bp.pair(d);
            else if (d.connected) { if (!bp.dry) d.disconnect(); }
            else if (!bp.dry) d.connect();
        }
    }
    // Long enough for the queued write to land before the library is read back.
    Timer { id: resetRead; interval: 500; onTriggered: libProc.running = true }

    // ---- wording ----
    function fmt(sec) {
        var m = Math.floor((sec || 0) / 60), h = Math.floor(m / 60);
        if (h > 0) return h + "h " + (m % 60) + "m";
        return m > 0 ? m + "m" : Math.round(sec || 0) + "s";
    }
    function fmtRun(run) {
        var bits = [bp.fmt(run.seconds)], st = run.stats || {};
        if (st.fps_avg !== undefined) bits.push(st.fps_avg + " FPS");
        if (st.gpu_temp_max !== undefined) bits.push(st.gpu_temp_max + "°C peak");
        return bits.join(", ");
    }
    function fmtAgo(epoch) {
        if (!epoch) return "Never";
        var then = new Date(epoch * 1000), now = new Date();
        var dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000;
        if (epoch >= dayStart) return "Today";
        var days = Math.ceil((dayStart - epoch) / 86400);
        if (days === 1) return "Yesterday";
        if (days < 7) return days + " days ago";
        return then.toLocaleDateString(Qt.locale(), "d MMM");
    }
    function fmtSize(b) { return b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round((b || 0) / 1e6) + " MB"; }
    // Some Bluetooth pads only tell BlueZ their charge, so that fills in when the device itself does not.
    function padBattery(p) {
        if (p.battery) return p.battery;
        for (var i = 0; i < bp.btDevices.length; i++) {
            var d = bp.btDevices[i];
            if (d.batteryAvailable && (d.name === p.name || d.deviceName === p.name))
                return { pct: Math.round(d.battery * 100), status: "Unknown" };
        }
        return null;
    }
    function padLow(p) { var b = bp.padBattery(p); return !!b && b.pct <= 20 && b.status !== "Charging"; }
    function padDetail(p) {
        var bus = p.bus === "bluetooth" ? "Bluetooth" : p.bus === "usb" ? "USB" : "";
        var b = bp.padBattery(p);
        if (!b) return bus;
        var state = b.status === "Charging" ? ", charging" : b.status === "Full" ? ", full" : "";
        return b.pct + "%" + state + (bus ? "  " + bus : "");
    }
    // Real button icons for whichever pad is in use. A hint naming the wrong button is worse than none.
    readonly property string padFamily: {
        var n = bp.pads.length ? bp.pads[0].name : "";
        if (/dualsense|dualshock|playstation|^wireless controller$/i.test(n)) return "ps";
        if (/nintendo|pro controller|joy-con/i.test(n)) return "switch";
        if (/steam deck|valve/i.test(n)) return "deck";
        return "xbox";
    }
    readonly property var glyphNames: ({
        keyboard: { a: "keyboard_enter", b: "keyboard_escape", x: "keyboard_o", y: "keyboard_g", view: "keyboard_t", menu: "keyboard_tab", l: "keyboard_q", r: "keyboard_e", dpad: "keyboard_arrows_horizontal" },
        xbox: { a: "xbox_button_color_a", b: "xbox_button_color_b", x: "xbox_button_color_x", y: "xbox_button_color_y", view: "xbox_button_view", menu: "xbox_button_menu", l: "xbox_lb", r: "xbox_rb", dpad: "xbox_dpad" },
        // The evdev codes follow position, so on PlayStation 307 is the triangle and 308 the square.
        ps: { a: "playstation_button_color_cross", b: "playstation_button_color_circle", x: "playstation_button_color_triangle", y: "playstation_button_color_square", view: "playstation5_button_create", menu: "playstation5_button_options", l: "playstation_trigger_l1", r: "playstation_trigger_r1", dpad: "playstation_dpad" },
        // And on Nintendo pads the bottom button is B and the right one A.
        "switch": { a: "switch_button_b", b: "switch_button_a", x: "switch_button_x", y: "switch_button_y", view: "switch_button_minus", menu: "switch_button_plus", l: "switch_button_l", r: "switch_button_r", dpad: "switch_dpad" },
        deck: { a: "steamdeck_button_a", b: "steamdeck_button_b", x: "steamdeck_button_x", y: "steamdeck_button_y", view: "steamdeck_button_view", menu: "steamdeck_button_options", l: "steamdeck_button_l1", r: "steamdeck_button_r1", dpad: "steamdeck_dpad" }
    })
    function glyph(a) {
        var family = bp.usingPad ? bp.padFamily : "keyboard";
        return Qt.resolvedUrl(bp.glyphNames[family][a] + ".svg");
    }
    function hint(a, l) { return { g: bp.glyph(a), l: l }; }
    readonly property var hints: {
        if (bp.kbd) {
            var kh = [bp.hint("a", "Type"), bp.hint("b", bp.kbdText ? "Delete" : "Cancel"), bp.hint("x", "Shift"), bp.hint("y", "Space")];
            if (bp.kbd.secret) kh.push(bp.hint("view", bp.kbdReveal ? "Hide" : "Show"));
            return kh.concat([bp.hint("menu", "Done")]);
        }
        if (bp.seated && !bp.launched) return [bp.hint("b", "Cancel")];
        if (bp.inserting) return [];
        if (bp.focusOn === "shelf") return [bp.hint("a", "Open"), bp.hint("x", "Play"), bp.hint("y", "All games"), bp.hint("view", "Stats"), bp.hint("menu", "Menu")];
        if (bp.focusOn === "dock") return [bp.hint("a", "Select"), bp.hint("b", "Back")];
        if (bp.focusOn === "grid") {
            var gh = [bp.hint("a", "Open"), bp.hint("y", bp.sortNames[bp.shelfSort])];
            if (bp.sourcesPresent.length > 1) gh.push(bp.hint("x", bp.filterName));
            return gh.concat([bp.hint("b", "Back")]);
        }
        if (bp.focusOn === "guide") return [bp.hint("a", "Select"), bp.hint("b", "Back")];
        if (bp.focusOn === "settings") return [bp.hint("a", "Open"), bp.hint("b", "Back")];
        if (bp.focusOn === "game" && bp.onPlay) return [bp.hint("a", "Play"), bp.hint("r", "Tabs"), bp.hint("b", "Back")];
        var row = bp.rows[bp.rowSel], out = [];
        if (row && row.k === "hold") out.push(bp.hint("a", "Hold"));
        else if (row && row.k === "slider") out.push(bp.hint("dpad", "Change"));
        else if (row && (row.k === "choice" || row.k === "toggle")) out.push(bp.hint("a", "Change"));
        else if (row && row.k === "action") out.push(bp.hint("a", "Select"));
        else if (row && row.k === "bar" && row.appid) out.push(bp.hint("a", "Open"));
        if (row && row.alt) out.push(bp.hint("y", row.alt));
        if (bp.focusOn === "game" || bp.focusOn === "stats") out.push(bp.hint("r", "Tabs"));
        out.push(bp.hint("b", "Back"));
        return out;
    }
    property string clock: Qt.formatTime(new Date(), "HH:mm")
    Timer {
        interval: 5000
        repeat: true
        running: bp.visible
        onTriggered: bp.clock = Qt.formatTime(new Date(), "HH:mm")
    }

    component Sym: Text {
        property real sz: 26
        font.family: "Material Symbols Rounded"
        font.pixelSize: sz * bp.ui
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }
    component Glyph: Image {
        property real sz: 40
        width: sz * bp.ui
        height: sz * bp.ui
        sourceSize.width: 128
        sourceSize.height: 128
        fillMode: Image.PreserveAspectFit
        asynchronous: false
    }
    // A full-screen page. Pages replace what is on screen, as a console's do, rather than floating on it.
    component Screen: Rectangle {
        property real shown: 0
        anchors.fill: parent
        anchors.topMargin: (1 - bp.outCubic(shown)) * 24 * bp.ui
        anchors.bottomMargin: -(1 - bp.outCubic(shown)) * 24 * bp.ui
        visible: shown > 0
        opacity: shown
        color: bp.pBg
    }
    // Tabs, with the real buttons that cycle them either side.
    component TabBar: Row {
        id: tabBar
        property var tabs: []
        property int current: 0
        spacing: 10 * bp.ui
        Glyph { anchors.verticalCenter: parent.verticalCenter; sz: 46; source: bp.glyph("l") }
        Repeater {
            model: tabBar.tabs
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool on: tabBar.current === index
                width: tabText.implicitWidth + 48 * bp.ui
                height: 60 * bp.ui
                radius: height / 2
                color: on ? bp.ink : "transparent"
                Text {
                    id: tabText
                    anchors.centerIn: parent
                    text: modelData
                    color: parent.on ? bp.pBg : bp.ink2
                    font.family: Tok.sans
                    font.pixelSize: 26 * bp.ui
                    font.weight: parent.on ? Font.DemiBold : Font.Medium
                }
            }
        }
        Glyph { anchors.verticalCenter: parent.verticalCenter; sz: 46; source: bp.glyph("r") }
    }

    // ---------- the room: the selected game's art, edge to edge ----------
    Item {
        id: bg
        anchors.fill: parent
        property real frontOpacity: 1
        function show(i) {
            if (!bp.shelf.length || !bp.shelf[i]) return;
            if (frontArt.source == bp.shelf[i].hero) return;
            backArt.source = frontArt.source;
            frontArt.source = bp.shelf[i].hero;
            bg.frontOpacity = 0;
        }
        Image {
            id: backArt
            anchors.fill: parent
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize.width: 1920
        }
        Image {
            id: frontArt
            anchors.fill: parent
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize.width: 1920
            opacity: bg.frontOpacity
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.78) }
                GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0.3) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.4) }
            }
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.3; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 0.72; color: Qt.rgba(0, 0, 0, 0.72) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.94) }
            }
        }
        // One dark layer rather than fading the pictures, which would show the previous game's art
        // through this one.
        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: 1 - (1 - 0.8 * bp.dim) * bp.room
        }
    }

    // ---------- the game in focus ----------
    Column {
        x: 72 * bp.ui
        y: 96 * bp.ui
        width: bp.width - 520 * bp.ui
        spacing: 8 * bp.ui
        opacity: bp.titleShown * bp.room
        Text {
            width: parent.width
            text: bp.game ? bp.game.name : (bp.games.length ? "" : "No games found")
            color: "white"
            elide: Text.ElideRight
            font.family: Tok.sans
            font.pixelSize: 64 * bp.ui
            font.weight: Font.Bold
        }
        Text {
            text: bp.game ? (bp.game.seconds > 0 ? bp.fmt(bp.game.seconds) + " played" : "Not played yet")
                + (bp.game.last_played ? ", last played " + bp.fmtAgo(bp.game.last_played).toLowerCase() : "") : ""
            color: Qt.rgba(1, 1, 1, 0.85)
            font.family: Tok.sans
            font.pixelSize: 24 * bp.ui
        }
        // The shelf is filtered from All games; without this, games would just seem to be gone.
        Text {
            visible: bp.sourceFilter !== ""
            text: "Showing " + bp.filterName.replace(" only", "") + " games only"
            color: bp.accent
            font.family: Tok.sans
            font.pixelSize: 20 * bp.ui
            font.weight: Font.DemiBold
        }
    }

    // ---------- the shelf, cut off where it meets the footer ----------
    Item {
        x: 0; y: 0
        width: bp.width
        height: bp.lipY + bp.jolt
        clip: true

        Repeater {
            model: bp.shelf
            delegate: Item {
                id: cart
                required property var modelData
                required property int index
                readonly property real off: cart.index - bp.railPos
                readonly property real dist: Math.abs(off)
                readonly property bool chosen: cart.index === bp.index
                visible: dist < 6
                width: bp.cardW
                height: bp.cardH
                x: bp.width / 2 - width / 2 + off * (bp.cardW + bp.cardGap) * (dist > 1 ? 0.88 : 0.96)
                y: bp.cardTop + (chosen ? bp.cardOffset : (1 - bp.neighbours) * 30 * bp.ui)
                transformOrigin: Item.Bottom
                layer.enabled: opacity < 1
                scale: 1 - 0.24 * bp.clamp01(dist)
                opacity: (1 - 0.12 * bp.clamp01(dist) - 0.3 * bp.clamp01(dist - 1))
                         * (chosen ? 1 : bp.neighbours) * bp.room

                // Only covers near the middle are built, however long the shelf gets.
                Loader {
                    anchors.fill: parent
                    active: cart.dist < 6
                    sourceComponent: Item {
                        // The focus ring: the one bright thing on the screen, as on a console.
                        Rectangle {
                            visible: cart.chosen && !bp.inserting && bp.ej < 0
                            anchors.fill: parent
                            anchors.margins: -7 * bp.ui
                            radius: bp.tileRadius + 7 * bp.ui
                            color: "transparent"
                            border.width: 4 * bp.ui
                            border.color: bp.focusOn === "shelf" ? "white" : Qt.rgba(1, 1, 1, 0.3)
                        }
                        ClippingRectangle {
                            anchors.fill: parent
                            radius: bp.tileRadius
                            color: bp.pPanel
                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 600
                                source: cart.modelData.art || cart.modelData.icon || ""
                            }
                        }
                        FavBadge { game: cart.modelData }
                    }
                }
            }
        }
    }

    // ---------- the row of round buttons under the games ----------
    // Sits low, just above the hint footer, with a clear gap under the covers.
    // The whole row fades while a cartridge is travelling, so the drop stays clear.
    Item {
        id: dockBar
        anchors.horizontalCenter: parent.horizontalCenter
        readonly property real barH: 100 * bp.ui
        width: dockRow.width + 36 * bp.ui
        height: barH + 40 * bp.ui
        y: bp.dockTop - height - 16 * bp.ui
        opacity: bp.neighbours * bp.room
        visible: opacity > 0

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: dockBar.barH
            radius: height / 2
            color: Qt.rgba(0.05, 0.06, 0.08, 0.62)
            border.width: Math.max(1, bp.ui)
            border.color: Qt.rgba(1, 1, 1, 0.16)
        }
        Row {
            id: dockRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 8 * bp.ui
            spacing: 22 * bp.ui
            Repeater {
                model: bp.dockItems
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property bool on: bp.focusOn === "dock" && bp.dockSel === index
                    width: 84 * bp.ui
                    height: 84 * bp.ui
                    Rectangle {
                        anchors.centerIn: parent
                        width: 72 * bp.ui
                        height: width
                        radius: width / 2
                        scale: parent.on ? 1.12 : 1
                        color: parent.on ? "white" : "transparent"
                        Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
                        Sym {
                            visible: !modelData.mark
                            anchors.centerIn: parent
                            text: modelData.i || ""
                            sz: 38
                            color: parent.parent.on ? bp.pBg : "white"
                        }
                        Image {
                            visible: !!modelData.mark
                            anchors.centerIn: parent
                            width: 32 * bp.ui
                            height: width
                            source: Qt.resolvedUrl(parent.parent.on ? "steam-ink.svg" : "steam.svg")
                            sourceSize.width: 128
                            sourceSize.height: 128
                            fillMode: Image.PreserveAspectFit
                        }
                    }
                }
            }
        }
        Text {
            visible: bp.focusOn === "dock"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            text: bp.dockItems[bp.dockSel].l
            color: "white"
            font.family: Tok.sans
            font.pixelSize: 22 * bp.ui
            font.weight: Font.DemiBold
        }
    }

    // ---------- a row of a page, whichever page it is in ----------
    function rowHeight(row) { return (row.k === "head" ? 60 : row.k === "run" ? 104 : 88) * bp.ui; }
    function rowTop(i) {
        var y = 0;
        for (var n = 0; n < i && n < bp.rows.length; n++) y += bp.rowHeight(bp.rows[n]);
        return y;
    }
    component RowList: Flickable {
        id: list
        property bool hasFocus: false
        clip: true
        interactive: false
        contentHeight: listCol.height
        // Keeps the selected row in view; a controller has nothing else to scroll with.
        readonly property real wanted: hasFocus && bp.rows.length
            ? Math.max(0, Math.min(contentHeight - height, bp.rowTop(bp.rowSel) + 44 * bp.ui - height / 2)) : 0
        onWantedChanged: contentY = wanted
        Behavior on contentY { NumberAnimation { duration: Tok.mBase; easing.type: Easing.OutCubic } }
        // One highlight that travels between rows, the way a console's focus moves.
        Rectangle {
            visible: list.hasFocus && bp.rows.length > 0
            width: list.width
            y: bp.rowTop(bp.rowSel)
            height: bp.rows[bp.rowSel] ? bp.rowHeight(bp.rows[bp.rowSel]) - 8 * bp.ui : 0
            radius: bp.tileRadius
            color: "white"
            Behavior on y { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
        }
        Column {
            id: listCol
            width: list.width
            Repeater {
                model: bp.rows
                delegate: Item {
                    id: rowItem
                    required property var modelData
                    required property int index
                    readonly property bool isHead: modelData.k === "head"
                    readonly property bool sel: list.hasFocus && bp.rowSel === index
                    readonly property bool held: sel && bp.holding === modelData.id
                    // On the white highlight, text turns dark.
                    readonly property color main: sel ? bp.pBg : modelData.dangerous ? bp.crit : modelData.k === "info" ? bp.ink2 : bp.ink
                    readonly property color soft: sel ? Qt.tint(bp.pBg, Qt.rgba(1, 1, 1, 0.3)) : modelData.bad ? bp.warn : modelData.lit ? bp.accent : bp.ink2
                    width: listCol.width
                    height: bp.rowHeight(modelData)

                    Text {
                        visible: rowItem.isHead
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 14 * bp.ui
                        x: 12 * bp.ui
                        width: parent.width - 24 * bp.ui
                        elide: Text.ElideRight
                        text: rowItem.modelData.l
                        color: bp.ink2
                        font.family: Tok.sans
                        font.pixelSize: 23 * bp.ui
                        font.weight: Font.DemiBold
                    }
                    Rectangle {
                        id: tile
                        visible: !rowItem.isHead
                        anchors.fill: parent
                        anchors.bottomMargin: 8 * bp.ui
                        radius: bp.tileRadius
                        color: rowItem.sel ? "transparent" : bp.pFill
                        clip: true

                        // How long a hold has left to go.
                        Rectangle {
                            visible: rowItem.held
                            height: parent.height
                            width: parent.width * bp.holdP
                            color: rowItem.modelData.dangerous ? Tok.alpha(bp.crit, 0.55) : Tok.alpha(bp.accent, 0.55)
                        }
                        Sym {
                            visible: !!rowItem.modelData.i
                            anchors.verticalCenter: parent.verticalCenter
                            x: 24 * bp.ui
                            width: 38 * bp.ui
                            text: rowItem.modelData.i || ""
                            sz: 34
                            color: rowItem.sel ? bp.pBg : rowItem.modelData.dangerous ? bp.crit : rowItem.modelData.lit ? bp.accent : bp.ink2
                        }
                        // A game's cover, in place of an icon.
                        ClippingRectangle {
                            visible: rowItem.modelData.k === "bar"
                            anchors.verticalCenter: parent.verticalCenter
                            x: 16 * bp.ui
                            width: 42 * bp.ui
                            height: 64 * bp.ui
                            radius: 6 * bp.ui
                            color: bp.pBg
                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 120
                                source: rowItem.modelData.cover || ""
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: rowItem.modelData.k === "bar" ? -10 * bp.ui : 0
                            x: rowItem.modelData.i || rowItem.modelData.k === "bar" ? 80 * bp.ui : 24 * bp.ui
                            width: rowItem.modelData.k === "run" ? parent.width - 560 * bp.ui
                                : parent.width * (rowItem.modelData.value || rowItem.modelData.k === "slider" || rowItem.modelData.k === "choice" || rowItem.modelData.k === "hold" ? 0.52 : 0.78)
                            spacing: 2 * bp.ui
                            Text {
                                width: parent.width
                                text: rowItem.modelData.l
                                color: rowItem.main
                                elide: Text.ElideRight
                                font.family: Tok.sans
                                font.pixelSize: (rowItem.modelData.k === "run" ? 25 : 28) * bp.ui
                                font.weight: rowItem.sel ? Font.DemiBold : Font.Normal
                            }
                            Text {
                                visible: !!rowItem.modelData.sub
                                width: parent.width
                                text: rowItem.modelData.sub || ""
                                color: rowItem.soft
                                elide: Text.ElideRight
                                font.family: Tok.sans
                                font.pixelSize: 20 * bp.ui
                            }
                        }
                        // Words on the right: a value, or a choice with arrows once it is selected.
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: rowItem.modelData.k === "bar" ? -10 * bp.ui : 0
                            anchors.right: parent.right
                            anchors.rightMargin: 26 * bp.ui
                            width: parent.width * 0.38
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            visible: !!rowItem.modelData.value || rowItem.modelData.k === "choice"
                            text: rowItem.modelData.k === "choice"
                                  ? (rowItem.sel ? "‹   " : "") + (rowItem.modelData.opts ? rowItem.modelData.opts[rowItem.modelData.at] : "") + (rowItem.sel ? "   ›" : "")
                                  : (rowItem.modelData.value || "")
                            color: rowItem.soft
                            font.family: Tok.sans
                            font.pixelSize: 25 * bp.ui
                            font.weight: rowItem.sel ? Font.DemiBold : Font.Normal
                        }
                        // Hold, with the real button.
                        Row {
                            visible: rowItem.modelData.k === "hold"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 22 * bp.ui
                            spacing: 8 * bp.ui
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Hold"
                                color: rowItem.soft
                                font.family: Tok.sans
                                font.pixelSize: 25 * bp.ui
                            }
                            Glyph { anchors.verticalCenter: parent.verticalCenter; sz: 42; source: bp.glyph("a") }
                        }
                        // How this game compares, under its name.
                        Rectangle {
                            visible: rowItem.modelData.k === "bar"
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 15 * bp.ui
                            x: 80 * bp.ui
                            width: parent.width - 104 * bp.ui
                            height: 8 * bp.ui
                            radius: height / 2
                            color: rowItem.sel ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.1)
                            Rectangle {
                                height: parent.height
                                radius: height / 2
                                width: (rowItem.modelData.share || 0) > 0 ? Math.max(height, parent.width * rowItem.modelData.share) : 0
                                color: rowItem.sel ? bp.pBg : bp.accent
                            }
                        }
                        // A run's numbers, in the same five columns as the Gaming tab.
                        Row {
                            visible: rowItem.modelData.k === "run"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 14 * bp.ui
                            Repeater {
                                model: rowItem.modelData.cells || []
                                delegate: Column {
                                    required property var modelData
                                    width: 102 * bp.ui
                                    Text {
                                        text: modelData.v
                                        color: rowItem.sel ? bp.pBg : modelData.v === "–" ? bp.ink3 : bp.ink
                                        font.family: Tok.mono
                                        font.pixelSize: 22 * bp.ui
                                        font.weight: Font.Medium
                                    }
                                    Text {
                                        text: modelData.l
                                        color: rowItem.soft
                                        font.family: Tok.sans
                                        font.pixelSize: 17 * bp.ui
                                    }
                                }
                            }
                        }
                        // A switch.
                        Rectangle {
                            visible: rowItem.modelData.k === "toggle"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 26 * bp.ui
                            width: 76 * bp.ui
                            height: 40 * bp.ui
                            radius: height / 2
                            color: rowItem.modelData.on ? (rowItem.sel ? bp.pBg : bp.accent) : (rowItem.sel ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.14))
                            Rectangle {
                                width: 30 * bp.ui
                                height: width
                                radius: width / 2
                                y: 5 * bp.ui
                                x: rowItem.modelData.on ? parent.width - width - 5 * bp.ui : 5 * bp.ui
                                color: rowItem.modelData.on ? "white" : (rowItem.sel ? bp.pBg : bp.ink2)
                            }
                        }
                        // A slider.
                        Item {
                            visible: rowItem.modelData.k === "slider"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 26 * bp.ui
                            width: parent.width * 0.42
                            height: 34 * bp.ui
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: Math.round((rowItem.modelData.v || 0) * 100) + "%"
                                color: rowItem.soft
                                font.family: Tok.sans
                                font.pixelSize: 25 * bp.ui
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 88 * bp.ui
                                height: 10 * bp.ui
                                radius: height / 2
                                color: rowItem.sel ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.14)
                                Rectangle {
                                    height: parent.height
                                    radius: height / 2
                                    width: Math.max(height, parent.width * (rowItem.modelData.v || 0))
                                    color: rowItem.sel ? bp.pBg : bp.accent
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- all games ----------
    Screen {
        shown: bp.gridT
        Text {
            x: 72 * bp.ui
            y: 40 * bp.ui
            text: "All games"
            color: bp.ink
            font.family: Tok.sans
            font.pixelSize: 48 * bp.ui
            font.weight: Font.Bold
        }
        Text {
            x: 74 * bp.ui
            y: 104 * bp.ui
            text: bp.shelf.length + (bp.shelf.length === 1 ? " game" : " games") + ", " + bp.sortNames[bp.shelfSort].toLowerCase()
                + (bp.sourceFilter ? ", " + bp.filterName : "")
            color: bp.ink2
            font.family: Tok.sans
            font.pixelSize: 23 * bp.ui
        }
        GridView {
            id: grid
            x: 66 * bp.ui
            y: 152 * bp.ui
            width: parent.width - 120 * bp.ui
            height: bp.dockTop - y - 8 * bp.ui
            clip: true
            interactive: false
            topMargin: 8 * bp.ui
            bottomMargin: 8 * bp.ui
            leftMargin: 8 * bp.ui
            cellWidth: (width - 8 * bp.ui) / bp.gridColumns
            cellHeight: (cellWidth - 22 * bp.ui) * 1.5 + 58 * bp.ui
            cacheBuffer: 500
            model: bp.gridT > 0 ? bp.shelf : []
            delegate: Item {
                id: gtile
                required property var modelData
                required property int index
                readonly property bool sel: bp.gridSel === index
                width: grid.cellWidth - 22 * bp.ui
                height: grid.cellHeight - 8 * bp.ui
                Rectangle {
                    visible: gtile.sel
                    anchors.fill: coverBox
                    anchors.margins: -7 * bp.ui
                    radius: bp.tileRadius + 7 * bp.ui
                    color: "transparent"
                    border.width: 4 * bp.ui
                    border.color: "white"
                }
                ClippingRectangle {
                    id: coverBox
                    width: parent.width
                    height: width * 1.5
                    radius: bp.tileRadius
                    color: bp.pPanel
                    Image {
                        anchors.fill: parent
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 400
                        source: gtile.modelData.art || gtile.modelData.icon || ""
                    }
                    FavBadge { game: gtile.modelData; s: 0.85 }
                }
                Text {
                    y: coverBox.height + 12 * bp.ui
                    width: parent.width
                    text: gtile.modelData.name
                    color: gtile.sel ? bp.ink : bp.ink2
                    elide: Text.ElideRight
                    font.family: Tok.sans
                    font.pixelSize: 21 * bp.ui
                    font.weight: gtile.sel ? Font.DemiBold : Font.Normal
                }
            }
        }
    }

    // ---------- settings: categories on the left, what they hold on the right ----------
    Screen {
        shown: bp.menuT
        Text {
            x: 72 * bp.ui
            y: 40 * bp.ui
            text: "Settings"
            color: bp.ink
            font.family: Tok.sans
            font.pixelSize: 48 * bp.ui
            font.weight: Font.Bold
        }
        Item {
            x: 56 * bp.ui
            y: 132 * bp.ui
            width: 440 * bp.ui
            height: bp.pages.length * 92 * bp.ui
            Rectangle {
                y: bp.menuSel * 92 * bp.ui
                width: parent.width
                height: 84 * bp.ui
                radius: height / 2
                color: bp.focusOn === "settings" ? "white" : Qt.rgba(1, 1, 1, 0.12)
                Behavior on y { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
            }
            Column {
                width: parent.width
                Repeater {
                    model: bp.pages
                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property bool lit: bp.menuSel === index && bp.focusOn === "settings"
                        readonly property bool sel: bp.menuSel === index
                        width: parent.width
                        height: 92 * bp.ui
                        Sym {
                            y: 42 * bp.ui - height / 2
                            x: 28 * bp.ui
                            width: 40 * bp.ui
                            text: modelData.i
                            sz: 36
                            color: parent.lit ? bp.pBg : parent.sel ? "white" : bp.ink2
                        }
                        Text {
                            y: 42 * bp.ui - height / 2
                            x: 88 * bp.ui
                            text: modelData.l
                            color: parent.lit ? bp.pBg : parent.sel ? "white" : bp.ink2
                            font.family: Tok.sans
                            font.pixelSize: 30 * bp.ui
                            font.weight: parent.sel ? Font.DemiBold : Font.Normal
                        }
                    }
                }
            }
        }
        RowList {
            x: 560 * bp.ui
            y: 132 * bp.ui
            width: parent.width - x - 72 * bp.ui
            height: bp.dockTop - y - 16 * bp.ui
            visible: bp.panelKind === "settings"
            hasFocus: bp.focusOn === "page"
        }
    }

    // ---------- stats ----------
    Screen {
        shown: bp.statsT
        Text {
            id: statsTitle
            x: 72 * bp.ui
            y: 40 * bp.ui
            text: "Stats"
            color: bp.ink
            font.family: Tok.sans
            font.pixelSize: 48 * bp.ui
            font.weight: Font.Bold
        }
        TabBar {
            id: statsBar
            x: 66 * bp.ui
            y: 112 * bp.ui
            tabs: bp.statTabs
            current: bp.statTab
        }
        RowList {
            x: 72 * bp.ui
            y: statsBar.y + statsBar.height + 20 * bp.ui
            width: parent.width - 144 * bp.ui
            height: bp.dockTop - y - 16 * bp.ui
            visible: bp.panelKind === "stats"
            hasFocus: bp.focusOn === "stats"
        }
    }

    // ---------- a game's page: its art, Play, then everything you can change ----------
    Screen {
        id: gameScreen
        shown: bp.gameT
        Image {
            id: gameHero
            width: parent.width
            height: 470 * bp.ui
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize.width: 1920
            source: bp.game ? bp.game.hero : ""
        }
        Rectangle {
            width: parent.width
            height: gameHero.height + 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: Tok.alpha(bp.pBg, 0.35) }
                GradientStop { position: 0.72; color: Tok.alpha(bp.pBg, 0.82) }
                GradientStop { position: 1.0; color: bp.pBg }
            }
        }
        ClippingRectangle {
            id: gameCover
            x: 72 * bp.ui
            y: 56 * bp.ui
            width: 240 * bp.ui
            height: width * 1.5
            radius: bp.tileRadius
            color: bp.pPanel
            Image {
                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 500
                source: bp.game ? (bp.game.art || bp.game.icon || "") : ""
            }
        }
        Text {
            id: gameTitle
            x: gameCover.x + gameCover.width + 44 * bp.ui
            y: 70 * bp.ui
            width: parent.width - x - 260 * bp.ui
            text: bp.game ? bp.game.name : ""
            color: "white"
            elide: Text.ElideRight
            font.family: Tok.sans
            font.pixelSize: 56 * bp.ui
            font.weight: Font.Bold
        }
        Row {
            id: gameFacts
            x: gameTitle.x
            y: gameTitle.y + gameTitle.height + 14 * bp.ui
            spacing: 56 * bp.ui
            Repeater {
                model: bp.game ? [
                    { l: "Played", v: bp.game.seconds > 0 ? bp.fmt(bp.game.seconds) : "Not yet" },
                    { l: "Last two weeks", v: bp.game.recent_seconds > 0 ? bp.fmt(bp.game.recent_seconds) : "Nothing" },
                    { l: "Last played", v: bp.fmtAgo(bp.game.last_played) },
                    { l: "On disk", v: bp.fmtSize(bp.game.size) },
                    { l: "From", v: bp.launcherName(bp.game) }
                ] : []
                delegate: Column {
                    required property var modelData
                    spacing: 2 * bp.ui
                    Text {
                        text: modelData.l
                        color: Qt.rgba(1, 1, 1, 0.72)
                        font.family: Tok.sans
                        font.pixelSize: 19 * bp.ui
                    }
                    Text {
                        text: modelData.v
                        color: "white"
                        font.family: Tok.sans
                        font.pixelSize: 27 * bp.ui
                        font.weight: Font.DemiBold
                    }
                }
            }
        }
        Rectangle {
            id: playBtn
            x: gameTitle.x
            y: gameFacts.y + gameFacts.height + 28 * bp.ui
            width: playRow.implicitWidth + 64 * bp.ui
            height: 84 * bp.ui
            radius: height / 2
            color: bp.onPlay ? "white" : Qt.rgba(1, 1, 1, 0.16)
            Row {
                id: playRow
                anchors.centerIn: parent
                spacing: 14 * bp.ui
                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "play_arrow"
                    sz: 46
                    color: bp.onPlay ? bp.pBg : "white"
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Play"
                    color: bp.onPlay ? bp.pBg : "white"
                    font.family: Tok.sans
                    font.pixelSize: 36 * bp.ui
                    font.weight: Font.Bold
                }
            }
        }
        TabBar {
            id: gameBar
            x: gameTitle.x - 6 * bp.ui
            y: 450 * bp.ui
            tabs: bp.gameTabs
            current: bp.gameTab
        }
        RowList {
            x: gameTitle.x
            y: gameBar.y + gameBar.height + 18 * bp.ui
            width: parent.width - x - 72 * bp.ui
            height: bp.dockTop - y - 12 * bp.ui
            visible: bp.panelKind === "game"
            hasFocus: bp.focusOn === "game" && !bp.onPlay
        }
    }

    // ---------- the top right: time and what is connected, over everything ----------
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 56 * bp.ui
        y: 34 * bp.ui
        spacing: 26 * bp.ui
        opacity: bp.room
        Row {
            visible: bp.pads.length > 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * bp.ui
            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                sz: 44
                source: Qt.resolvedUrl("controller_" + ({ xbox: "xboxseries", ps: "playstation5", switch: "switch_pro", deck: "steamdeck" })[bp.padFamily] + ".svg")
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                readonly property var b: bp.pads.length ? bp.padBattery(bp.pads[0]) : null
                visible: !!b
                text: b ? b.pct + "%" : ""
                color: bp.pads.length && bp.padLow(bp.pads[0]) ? bp.warn : "white"
                font.family: Tok.sans
                font.pixelSize: 24 * bp.ui
                font.weight: Font.Medium
            }
        }
        Sym {
            anchors.verticalCenter: parent.verticalCenter
            text: !bp.wifiOn ? "wifi_off" : "wifi"
            sz: 34
            color: "white"
        }
        Row {
            visible: UPower.displayDevice && UPower.displayDevice.isPresent
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4 * bp.ui
            Sym {
                anchors.verticalCenter: parent.verticalCenter
                text: UPower.onBattery ? "battery_5_bar" : "battery_charging_full"
                sz: 34
                color: "white"
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: UPower.displayDevice ? Math.round(UPower.displayDevice.percentage * 100) + "%" : ""
                color: "white"
                font.family: Tok.sans
                font.pixelSize: 24 * bp.ui
                font.weight: Font.Medium
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: bp.clock
            color: "white"
            font.family: Tok.sans
            font.pixelSize: 32 * bp.ui
            font.weight: Font.DemiBold
        }
    }

    // ---------- the footer: what the buttons do, as on any console ----------
    Rectangle {
        id: footer
        x: 0
        y: bp.dockTop + bp.jolt
        width: bp.width
        height: bp.dockH + 20 * bp.ui
        color: bp.pFoot
        opacity: bp.room
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 72 * bp.ui
            anchors.verticalCenter: parent.top
            anchors.verticalCenterOffset: bp.dockH / 2
            width: parent.width * 0.5 - 72 * bp.ui - bp.cardW * 0.6
            text: bp.seated ? (bp.launched ? "Running " : "Starting ") + (bp.game ? bp.game.name : "") : bp.notice
            color: bp.seated ? bp.accent : bp.ink
            elide: Text.ElideRight
            font.family: Tok.sans
            font.pixelSize: 24 * bp.ui
            font.weight: Font.Medium
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 56 * bp.ui
            anchors.verticalCenter: parent.top
            anchors.verticalCenterOffset: bp.dockH / 2
            spacing: 28 * bp.ui
            Repeater {
                model: bp.hints
                delegate: Row {
                    required property var modelData
                    spacing: 6 * bp.ui
                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        sz: 46
                        source: modelData.g
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.l
                        color: bp.ink
                        font.family: Tok.sans
                        font.pixelSize: 23 * bp.ui
                        font.weight: Font.Medium
                    }
                }
            }
        }
    }

    // ---------- the game's title screen, rising off the slot while the game starts ----------
    // The same hero art as home, lit evenly with the game's logo on it. It stops at the slot, so the
    // footer keeps "Starting" and Cancel under it.
    Item {
        id: launch
        width: bp.width
        height: bp.slotY + bp.jolt
        visible: !bp.gameShowing && bp.seam > 0
        readonly property real edge: height * (1 - bp.bootOpen)
        readonly property real lineW: slot.width + (bp.width - slot.width) * bp.seam
        readonly property real lineFade: 1 - bp.clamp01((bp.bootOpen - 0.75) / 0.25)
        readonly property real logoIn: Tok.reducedMotion ? 1 : bp.outCubic((bp.since - 420) / 560)
        readonly property real barIn: Tok.reducedMotion ? 1 : bp.outCubic((bp.since - 760) / 420)

        Item {
            y: launch.edge
            width: parent.width
            height: parent.height - y
            clip: true
            Item {
                y: -parent.y
                width: bp.width
                height: bp.height
                Rectangle { anchors.fill: parent; color: bp.pBg }
                Image {
                    anchors.fill: parent
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    verticalAlignment: Image.AlignTop
                    sourceSize.width: 1920
                    source: bp.game ? (bp.game.hero || bp.game.art || "") : ""
                    // Arrives a little close and settles back, then drifts slowly for as long as the wait goes on.
                    scale: 1 + 0.06 * (1 - bp.outCubic(bp.since / 1800))
                           + 0.035 * (1 - Math.exp(-Math.max(0, bp.since - 1800) / 25000))
                }
                // Darker than home's art, whatever the art is, so the logo always reads.
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.45) }
                        GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.1) }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.45) }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.6) }
                        GradientStop { position: 0.42; color: Qt.rgba(0, 0, 0, 0.5) }
                        GradientStop { position: 0.8; color: Qt.rgba(0, 0, 0, 0.75) }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.94) }
                    }
                }
                // The light off the line, spilling down over what it has just shown.
                Rectangle {
                    y: launch.edge
                    width: parent.width
                    height: 220 * bp.ui
                    opacity: launch.lineFade
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Tok.alpha(bp.accent, 0.2) }
                        GradientStop { position: 1.0; color: Tok.alpha(bp.accent, 0) }
                    }
                }

                Item {
                    id: mark
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: bp.height * 0.42 - height / 2 + 14 * bp.ui * (1 - launch.logoIn)
                    width: 880 * bp.ui
                    height: 300 * bp.ui
                    opacity: launch.logoIn
                    Image {
                        id: logo
                        anchors.fill: parent
                        visible: false
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: 1280
                        source: (bp.game && bp.game.logo) || ""
                    }
                    MultiEffect {
                        anchors.fill: logo
                        source: logo
                        visible: logo.status === Image.Ready
                        shadowEnabled: true
                        shadowColor: "black"
                        shadowOpacity: 0.55
                        shadowBlur: 1.0
                        shadowVerticalOffset: 2 * bp.ui
                    }
                    Text {
                        anchors.fill: parent
                        visible: logo.status !== Image.Ready
                        text: bp.game ? bp.game.name : ""
                        color: "white"
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        fontSizeMode: Text.Fit
                        minimumPixelSize: 28
                        font.family: Tok.sans
                        font.pixelSize: 76 * bp.ui
                        font.weight: Font.Bold
                        layer.enabled: visible
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            shadowColor: "black"
                            shadowOpacity: 0.6
                            shadowBlur: 1.0
                        }
                    }
                }
                // Starting: a short light running along a track under the logo.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: mark.y + mark.height + 56 * bp.ui
                    width: 240 * bp.ui
                    height: 4 * bp.ui
                    radius: height / 2
                    color: Qt.rgba(1, 1, 1, 0.14)
                    opacity: launch.barIn
                    Rectangle {
                        readonly property real p: Tok.reducedMotion ? 0.25 : (bp.since % 1600) / 1600
                        width: parent.width * 0.3
                        height: parent.height
                        radius: height / 2
                        x: (parent.width - width) * (0.5 - 0.5 * Math.cos(p * 2 * Math.PI))
                        color: bp.accent
                    }
                }
            }
        }

        // The line itself, with a soft glow over it.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: launch.edge - height
            width: launch.lineW
            height: 34 * bp.ui
            opacity: launch.lineFade * bp.seam
            gradient: Gradient {
                GradientStop { position: 0.0; color: Tok.alpha(bp.accent, 0) }
                GradientStop { position: 1.0; color: Tok.alpha(bp.accent, 0.4) }
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: launch.edge - height / 2
            width: launch.lineW
            height: 3 * bp.ui
            radius: height / 2
            color: Qt.lighter(bp.accent, 1.12)
            opacity: launch.lineFade
        }
    }

    // ---------- the slot in the footer's top edge: dark until a game is in it ----------
    Rectangle {
        id: slot
        readonly property real closedW: bp.cardW * 0.34
        readonly property real openW: bp.cardW + 16 * bp.ui
        anchors.horizontalCenter: parent.horizontalCenter
        y: bp.slotY + bp.jolt
        width: closedW + (openW - closedW) * bp.slotOpen
        height: bp.slotH
        radius: height / 2
        color: "black"
        opacity: bp.room * (bp.inserting || bp.ej >= 0 ? 1 : 0.0)
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: bp.accent
            opacity: bp.lamp
        }
    }
    Repeater {
        model: [bp.ring, bp.ring2]
        Rectangle {
            required property real modelData
            anchors.horizontalCenter: parent.horizontalCenter
            y: slot.y + slot.height / 2 - height / 2
            width: slot.width + modelData * 120 * bp.ui
            height: slot.height + modelData * 36 * bp.ui
            radius: height / 2
            color: "transparent"
            border.width: Math.max(1, 2 * bp.ui)
            border.color: bp.accent
            visible: modelData > 0 && modelData < 1
            opacity: 1 - modelData
        }
    }

    // ---------- the guide: the home button brings this in over anything ----------
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.6 * bp.guideT
        visible: bp.guideT > 0
    }
    Rectangle {
        id: guide
        visible: bp.guideT > 0
        x: -(1 - bp.outCubic(bp.guideT)) * width
        width: 520 * bp.ui
        height: parent.height
        color: bp.pPanel
        Row {
            x: 44 * bp.ui
            y: 44 * bp.ui
            spacing: 18 * bp.ui
            SeaLogo {
                anchors.verticalCenter: parent.verticalCenter
                size: 56 * bp.ui
                accent: Tok.accent
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "sea-shell"
                color: "white"
                font.family: Tok.sans
                font.pixelSize: 34 * bp.ui
                font.weight: Font.Bold
            }
        }
        Item {
            x: 24 * bp.ui
            y: 138 * bp.ui
            width: parent.width - 48 * bp.ui
            height: bp.guideItems.length * 92 * bp.ui
            Rectangle {
                y: bp.guideSel * 92 * bp.ui
                width: parent.width
                height: 84 * bp.ui
                radius: height / 2
                color: "white"
                Behavior on y { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
            }
            Column {
                width: parent.width
                Repeater {
                    model: bp.guideItems
                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property bool sel: bp.guideSel === index
                        width: parent.width
                        height: 92 * bp.ui
                        Sym {
                            visible: !modelData.mark
                            y: 42 * bp.ui - height / 2
                            x: 30 * bp.ui
                            width: 40 * bp.ui
                            text: modelData.i || ""
                            sz: 36
                            color: parent.sel ? bp.pBg : bp.ink2
                        }
                        Image {
                            visible: !!modelData.mark
                            x: 28 * bp.ui
                            y: 46 * bp.ui - height / 2
                            width: 32 * bp.ui
                            height: width
                            source: Qt.resolvedUrl(parent.sel ? "steam-ink.svg" : "steam.svg")
                            sourceSize.width: 128
                            sourceSize.height: 128
                            fillMode: Image.PreserveAspectFit
                        }
                        Text {
                            y: 42 * bp.ui - height / 2
                            x: 92 * bp.ui
                            text: modelData.l
                            color: parent.sel ? bp.pBg : bp.ink
                            font.family: Tok.sans
                            font.pixelSize: 31 * bp.ui
                            font.weight: parent.sel ? Font.DemiBold : Font.Normal
                        }
                    }
                }
            }
        }
    }

    // ---------- the on-screen keyboard, over whatever asked for it ----------
    // The footer stays lit: its hints are how the keyboard's buttons are learnt.
    Rectangle {
        width: parent.width
        height: bp.dockTop
        color: "black"
        opacity: 0.62
        visible: bp.kbd !== null
    }
    Rectangle {
        id: kbdPanel
        visible: bp.kbd !== null
        readonly property real unit: 104 * bp.ui
        readonly property real keyH: 80 * bp.ui
        readonly property real gap: 10 * bp.ui
        anchors.horizontalCenter: parent.horizontalCenter
        width: unit * 10 + 2 * 36 * bp.ui
        height: kbdCol.height + 2 * 32 * bp.ui
        y: bp.dockTop - height - 28 * bp.ui
        radius: bp.cornerR
        color: bp.pPanel
        border.width: Math.max(1, bp.ui)
        border.color: Qt.rgba(1, 1, 1, 0.1)
        Column {
            id: kbdCol
            x: 36 * bp.ui
            y: 32 * bp.ui
            width: kbdPanel.unit * 10
            spacing: 18 * bp.ui
            Text {
                width: parent.width
                text: bp.kbd ? bp.kbd.title : ""
                color: bp.ink2
                elide: Text.ElideRight
                font.family: Tok.sans
                font.pixelSize: 26 * bp.ui
                font.weight: Font.Medium
            }
            // What has been typed, with a caret after it.
            Rectangle {
                width: parent.width - kbdPanel.gap
                height: 84 * bp.ui
                radius: bp.tileRadius
                color: bp.pBg
                border.width: Math.max(1, 2 * bp.ui)
                border.color: bp.accent
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 26 * bp.ui
                    spacing: 4 * bp.ui
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, kbdCol.width - 120 * bp.ui)
                        elide: Text.ElideLeft
                        text: bp.kbd && bp.kbd.secret && !bp.kbdReveal ? "•".repeat(bp.kbdText.length) : bp.kbdText
                        color: bp.ink
                        font.family: Tok.mono
                        font.pixelSize: 32 * bp.ui
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 3 * bp.ui
                        height: 40 * bp.ui
                        color: bp.accent
                        SequentialAnimation on opacity {
                            running: bp.kbd !== null && !Tok.reducedMotion
                            loops: Animation.Infinite
                            NumberAnimation { to: 0; duration: 520 }
                            NumberAnimation { to: 1; duration: 520 }
                        }
                    }
                }
            }
            Column {
                spacing: kbdPanel.gap
                Repeater {
                    model: bp.kbdRows
                    delegate: Row {
                        id: keyRow
                        required property var modelData
                        required property int index
                        spacing: kbdPanel.gap
                        Repeater {
                            model: keyRow.modelData
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool sel: bp.kbdRow === keyRow.index && bp.kbdCol === index
                                readonly property bool lit: modelData.id === "shift" && bp.kbdShift
                                width: kbdPanel.unit * modelData.w - kbdPanel.gap
                                height: kbdPanel.keyH
                                radius: bp.tileRadius
                                color: sel ? "white" : modelData.id === "done" ? Tok.alpha(bp.accent, 0.3) : lit ? Tok.alpha(bp.accent, 0.4) : bp.pFill
                                scale: sel ? 1.06 : 1
                                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
                                Sym {
                                    visible: !!parent.modelData.i
                                    anchors.centerIn: parent
                                    text: parent.modelData.i || ""
                                    sz: 34
                                    color: parent.sel ? bp.pBg : bp.ink
                                }
                                Text {
                                    visible: !parent.modelData.i
                                    anchors.centerIn: parent
                                    text: parent.modelData.t !== undefined ? (bp.kbdShift ? parent.modelData.t.toUpperCase() : parent.modelData.t) : (parent.modelData.l || "")
                                    color: parent.sel ? bp.pBg : bp.ink
                                    font.family: Tok.sans
                                    font.pixelSize: (parent.modelData.t !== undefined ? 32 : 25) * bp.ui
                                    font.weight: parent.sel ? Font.DemiBold : Font.Medium
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- the screen asleep: black until any press ----------
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: bp.screenOff
    }

    // ---------- the startup screen: the sea comes up, and goes out to leave the room ----------
    Item {
        id: startup
        anchors.fill: parent
        visible: bp.boot >= 0
        // Where the water's surface is: up over the first half second, then down and off the bottom.
        readonly property real surge: bp.inOut(bp.boot / 560)
        readonly property real ebb: bp.inOut((bp.boot - bp.bootHold) / (bp.bootEnd - bp.bootHold))
        readonly property real amp: 18 * bp.ui * (1 + 1.6 * surge * (1 - ebb))
        readonly property real waterTop: bp.boot < bp.bootHold
            ? bp.height * (1 - surge) - amp * 3 * surge
            : bp.height * ebb - amp * 3 * (1 - ebb)
        readonly property color deep: Qt.hsla(bp.hue, 0.5, 0.11, 1)
        readonly property color shallow: Qt.hsla(bp.hue, 0.5, 0.2, 1)
        readonly property color crest: Qt.hsla(bp.hue, 0.55, 0.34, 1)
        readonly property real lambda: 420 * bp.ui
        function wavePath(len, a) {
            // A window has no size until it is on screen, and a wave with no length never ends.
            if (!(len > 0) || !(bp.width > 0)) return "";
            var w = bp.width + len * 3, d = "M 0 0", x = 0, up = true, deepTo = bp.height + 200 * bp.ui;
            while (x < w) {
                d += " Q " + (x + len / 4) + " " + (up ? -2 * a : 2 * a) + " " + (x + len / 2) + " 0";
                x += len / 2;
                up = !up;
            }
            return d + " L " + x + " " + deepTo + " L 0 " + deepTo + " Z";
        }

        // What covers the room until the water has.
        Rectangle {
            anchors.fill: parent
            color: "black"
            visible: bp.boot < 560
        }
        Shape {
            x: -((bp.boot * 0.16 * bp.ui) % (startup.lambda * 1.4))
            y: startup.waterTop - 26 * bp.ui
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillColor: startup.crest
                PathSvg { path: startup.visible ? startup.wavePath(startup.lambda * 1.4, startup.amp) : "" }
            }
        }
        Shape {
            x: -startup.lambda + ((bp.boot * 0.22 * bp.ui) % startup.lambda)
            y: startup.waterTop - 8 * bp.ui
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillColor: startup.shallow
                PathSvg { path: startup.visible ? startup.wavePath(startup.lambda, startup.amp * 0.8) : "" }
            }
        }
        Rectangle {
            width: parent.width
            y: Math.max(0, startup.waterTop + 40 * bp.ui)
            height: Math.max(0, parent.height - y)
            gradient: Gradient {
                GradientStop { position: 0.0; color: startup.shallow }
                GradientStop { position: 1.0; color: startup.deep }
            }
        }
        Column {
            anchors.centerIn: parent
            spacing: 22 * bp.ui
            readonly property real inT: bp.outCubic((bp.boot - 240) / 340)
            readonly property real outT: bp.clamp01((bp.boot - bp.bootHold + 60) / 180)
            opacity: inT * (1 - outT)
            scale: 0.94 + 0.06 * inT
            SeaLogo {
                anchors.horizontalCenter: parent.horizontalCenter
                size: 176 * bp.ui
                accent: Tok.accent
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "sea-shell"
                color: "white"
                font.family: Tok.sans
                font.pixelSize: 58 * bp.ui
                font.weight: Font.Bold
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Big picture"
                color: Qt.rgba(1, 1, 1, 0.75)
                font.family: Tok.sans
                font.pixelSize: 25 * bp.ui
            }
        }
    }
}
