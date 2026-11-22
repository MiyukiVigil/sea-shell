// sea-shell — the gaming session. Big picture mode and nothing else: no bar, no wallpaper, no
// widgets, no polling for things only the desktop shows. Started by sea-bar-supervisor.sh in place
// of shell.qml when SEA_SESSION=gaming (the "sea-shell Gaming" login session, hypr/gaming.lua).
//
// Everything a console needs is reached from big picture itself, so nothing here has a window of
// its own except the polkit prompt, which has to be answerable when a setting asks for a password.
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import QtQuick

ShellRoot {
    id: root

    Connections { target: Quickshell; function onReloadCompleted() { Quickshell.inhibitReloadPopup() } }

    property var userProfile: ({})
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/profile.json"
        onLoaded: { try { root.userProfile = JSON.parse(text()) } catch (e) {} } }

    PolkitAgent { id: polkitAgent }
    PolkitDialog { flow: polkitAgent.flow; profile: root.userProfile }

    // ---------- big picture ----------
    property var cfg: ({ screen: "auto", other: "black", home: true, sfx: "on" })
    property bool cfgRead: false
    FileView {
        id: cfgFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/bigpicture.json"
        printErrors: false
        onLoaded: {
            try { root.cfg = Object.assign({}, root.cfg, JSON.parse(text())); } catch (e) {}
            root.applySession();
        }
        onLoadFailed: root.applySession()
    }
    function setCfg(patch) {
        root.cfg = Object.assign({}, root.cfg, patch);
        cfgFile.setText(JSON.stringify(root.cfg));
    }
    // What the session takes from big picture's settings, once they have been read.
    function applySession() {
        if (root.cfgRead) return;
        root.cfgRead = true;
        if (root.cfg.kbLayout)
            Quickshell.execDetached(["hyprctl", "eval", "hl.config({ input = { kb_layout = \"" + root.cfg.kbLayout + "\" } })"]);
        if (root.cfg.vrr !== undefined)
            Quickshell.execDetached(["hyprctl", "eval", "hl.config({ misc = { vrr = " + (root.cfg.vrr | 0) + " } })"]);
        bp.open();
    }

    BigPicture {
        id: bp
        session: true
        cfg: root.cfg
        pads: root.gamepads
        onSetCfg: patch => root.setCfg(patch)
        // Nothing to go back to here. If it ever closes, it comes straight back.
        onShownChanged: if (!shown) reopen.restart()
    }
    Timer { id: reopen; interval: 600; onTriggered: bp.open() }

    IpcHandler { target: "bigpicture"
        function open(): void { bp.open() }
        function close(): void {}
        function toggle(): void { bp.open() }
        function press(button: string): void { bp.press(button); bp.release(button) } }

    // ---------- the controller ----------
    // The same reader the desktop shell runs, with the same hand-off rules: a game has the pad
    // while it is up, Steam's Big Picture has it while that is showing, this screen otherwise.
    property var gamepads: []
    readonly property string gamepadMode: bp.gameShowing ? "pause" : bp.steamHandoff || bp.appHandoff ? "relay" : "grab"
    onGamepadModeChanged: if (gamepadProc.running) gamepadProc.write(root.gamepadMode + "\n")
    function gamepadLine(line) {
        var m;
        try { m = JSON.parse(line); } catch (e) { return; }
        if (m.t === "pads") { root.gamepads = m.pads; return; }
        if (m.t === "error") { gamepadRestart.stop(); root.gamepadGiveUp = true; return; }
        if (m.t === "press") bp.press(m.b);
        else if (m.t === "release") bp.release(m.b);
    }
    property bool gamepadGiveUp: false
    Process {
        id: gamepadProc
        command: ["python3", Qt.resolvedUrl("sea-gamepad.py").toString().replace("file://", "")]
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.gamepadLine(data) }
        onExited: if (!root.gamepadGiveUp) gamepadRestart.restart()
        onStarted: gamepadProc.write(root.gamepadMode + "\n")
    }
    Timer { id: gamepadRestart; interval: 5000; onTriggered: gamepadProc.running = true }
    Component.onCompleted: gamepadProc.running = true
}
