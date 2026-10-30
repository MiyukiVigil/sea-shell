//@ pragma UseQApplication
// sea-shell — the lock screen. Started by sea-lock.sh as its own Quickshell process, never from
// inside the shell, so a shell reload cannot drop it. sea-lock.sh watches two marker files:
//   $XDG_RUNTIME_DIR/sea-lock.up   the compositor confirmed every screen is covered
//   $XDG_RUNTIME_DIR/sea-lock.ok   a real unlock happened (written AFTER unlocking)
// and starts hyprlock if either is missing. What it looks like is LockSurface.qml.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import QtQuick

ShellRoot {
    id: root
    readonly property string home: Quickshell.env("HOME")
    readonly property string run: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sea-lock"
    readonly property string sddmDir: "/usr/share/sddm/themes/sea-silent"
    readonly property string pamDir: "/etc/pam.d"

    property string state_: "idle"
    property string buffer: ""
    property bool busy: false
    property int fails: 0
    property int shakes: 0
    property string message: ""
    property bool messageIsError: false
    property bool leaving: false

    // ---------- what it shows ----------
    property var profile: ({})
    FileView { path: root.home + "/.config/sea-shell/profile.json"
        onLoaded: { try { root.profile = JSON.parse(text()) } catch (e) {} } }

    // lock.json: { "engine": "sea"|"hyprlock", "notifications": "full"|"names"|"off" }
    property var cfg: ({})
    FileView { path: root.home + "/.config/sea-shell/lock.json"
        onLoaded: { try { root.cfg = JSON.parse(text()) } catch (e) {} } }

    // The clock face and date format come from the login screen's own settings, so the lock
    // and the greeter it hands back to look like one screen.
    property string clockFamily: ""
    property int clockWeight: 900
    property string dateFormat: "dddd, d MMMM"
    FileView { path: root.sddmDir + "/configs/sea-shell.conf"
        onLoaded: {
            var sec = "", t = text().split("\n");
            for (var i = 0; i < t.length; i++) {
                var l = t[i].trim(), m = l.match(/^\[(.*)\]$/);
                if (m) { sec = m[1]; continue }
                var kv = l.match(/^([\w.-]+)\s*=\s*"?([^"]*)"?$/);
                if (!kv) continue;
                if (sec === "LockScreen.Clock" && kv[1] === "font-family") root.clockFamily = kv[2];
                if (sec === "LockScreen.Clock" && kv[1] === "font-weight") root.clockWeight = parseInt(kv[2]) || 900;
                if (sec === "LockScreen.Date" && kv[1] === "format") root.dateFormat = kv[2];
            }
        } }
    // SilentSDDM ships Red Hat Display inside the theme rather than installing it
    readonly property string rhFile: ({ 900: "Black", 800: "ExtraBold", 700: "Bold", 600: "SemiBold", 500: "Medium" })[root.clockWeight] || "Black"
    FontLoader { id: rhClock; source: root.clockFamily === "RedHatDisplay" ? "file://" + root.sddmDir + "/fonts/redhat/RedHatDisplay-" + root.rhFile + ".otf" : "" }
    FontLoader { source: root.clockFamily === "RedHatDisplay" ? "file://" + root.sddmDir + "/fonts/redhat/RedHatDisplay-SemiBold.otf" : "" }
    // the profile's font wins, as it did on hyprlock; the login screen's is the fallback
    readonly property string clockFont: root.profile.font ? root.profile.font
        : rhClock.status === FontLoader.Ready ? rhClock.name : (root.clockFamily || Tok.sans)

    // What arrived while locked, from the shell's notification history. Muted apps stay quiet
    // here as in popups, unless critical. SEA_LOCK_SINCE_MIN widens the window for testing.
    readonly property real since: Date.now() - 60000 * (parseFloat(Quickshell.env("SEA_LOCK_SINCE_MIN") || "0") || 0)
    property var history: []
    property var mutes: []
    FileView { path: root.home + "/.config/sea-shell/notif-history.json"; watchChanges: true
        onLoaded: { try { root.history = JSON.parse(text()) } catch (e) {} }
        onFileChanged: reload() }
    FileView { path: root.home + "/.config/sea-shell/notif-mutes.json"; watchChanges: true
        onLoaded: { try { root.mutes = JSON.parse(text()) } catch (e) {} }
        onFileChanged: reload() }
    readonly property var notes: (root.cfg.notifications === "off") ? [] : root.history.filter(n =>
        n && n.ts && n.ts >= root.since && (n.urgency === 2 || root.mutes.indexOf(n.appName) < 0))

    readonly property var player: {
        var ps = Mpris.players ? Mpris.players.values : [], best = null;
        for (var i = 0; i < ps.length; i++) {
            if (!ps[i] || !ps[i].canControl) continue;
            if (ps[i].isPlaying) return ps[i];
            if (!best && ps[i].trackTitle) best = ps[i];
        }
        return best;
    }
    readonly property var battery: {
        var d = UPower.displayDevice;
        return d && d.isLaptopBattery ? { pct: (d.percentage || 0) * 100, charging: !UPower.onBattery } : null;
    }

    // Caps Lock and the layout are asked of Hyprland: on entering the field, on the Caps Lock
    // key, and every few seconds while the field is up.
    property bool capsLock: false
    property string layout: ""
    Process {
        id: kbd
        command: ["hyprctl", "devices", "-j"]
        stdout: StdioCollector { onStreamFinished: {
            try {
                var ks = JSON.parse(text).keyboards || [], caps = false, lay = "";
                for (var i = 0; i < ks.length; i++) {
                    if (ks[i].capsLock) caps = true;
                    if (ks[i].main) {
                        var all = ("" + ks[i].layout).split(",");
                        if (all.length > 1) lay = all[ks[i].active_layout_index || 0] || ks[i].active_keymap || "";
                    }
                }
                root.capsLock = caps; root.layout = lay;
            } catch (e) {}
        } }
    }
    function pollKbd() { if (!kbd.running) kbd.running = true }
    Timer { interval: 3000; repeat: true; running: root.state_ === "login"; onTriggered: root.pollKbd() }
    Timer { id: capsLater; interval: 120; onTriggered: root.pollKbd() }

    // ---------- input ----------
    // back to the clock after a quiet half minute, forgetting anything half-typed
    Timer { id: idleBack; interval: 30000; onTriggered: if (!root.busy) { root.buffer = ""; root.state_ = "idle" } }
    function wake() {
        idleBack.restart();
        if (root.state_ !== "login") { root.state_ = "login"; root.pollKbd() }
    }
    function onKey(e) {
        if (root.leaving) return;
        idleBack.restart();
        if (e.key === Qt.Key_Escape) {
            if (!root.busy) root.buffer = "";
            root.state_ = "idle"; return;
        }
        root.wake();
        if (e.key === Qt.Key_CapsLock) { capsLater.restart(); return }
        if (root.busy) return;
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.tryUnlock(); return }
        if (e.key === Qt.Key_Backspace) {
            root.buffer = (e.modifiers & Qt.ControlModifier) ? "" : root.buffer.slice(0, -1); return;
        }
        if (e.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) return;
        var t = e.text || "";
        if (t.length === 1 && t.charCodeAt(0) >= 32 && t.charCodeAt(0) !== 127) {
            root.buffer += t;
            root.message = ""; root.messageIsError = false;
        }
    }

    // ---------- PAM ----------
    // The same stack hyprlock uses (/etc/pam.d/hyprlock → login), so faillock and fingerprint
    // readers behave as they did.
    function tryUnlock() {
        if (root.buffer === "" || root.busy) return;
        root.busy = true; root.message = ""; root.messageIsError = false;
        if (!pam.start()) { root.busy = false; root.message = "Could not start the password check"; root.messageIsError = true }
    }
    PamContext {
        id: pam
        config: "hyprlock"
        configDirectory: root.pamDir
        onPamMessage: {
            if (responseRequired) { respond(root.buffer); return }
            root.message = message; root.messageIsError = messageIsError;
        }
        onCompleted: result => {
            root.busy = false;
            if (result === PamResult.Success) { root.unlock(); return }
            // Error comes after onError below, for the same try; it counts once, here
            root.buffer = ""; root.fails++; root.shakes++;
            if (result === PamResult.MaxTries) { root.message = "Too many tries. Wait a moment, then try again"; root.messageIsError = true }
        }
        // TryAuthFailed is a module refusing outright (pam_exec, a locked-out faillock): to the
        // person typing that is just a wrong try. Only a PAM that would not run gets a message.
        onError: error => {
            root.busy = false; root.buffer = "";
            if (error !== PamError.TryAuthFailed) {
                root.message = "The password check could not run (" + PamError.toString(error) + ")"; root.messageIsError = true;
            }
        }
    }

    // ---------- lock / unlock ----------
    function unlock() {
        root.buffer = "";
        root.leaving = true;
        leaveT.start();
    }
    Timer { id: leaveT; interval: Tok.reducedMotion ? 0 : 240
        onTriggered: { lock.locked = false; okMark.running = true } }
    Process { id: okMark; command: ["touch", root.run + ".ok"]; onExited: Qt.quit() }
    Process { id: upMark; command: ["touch", root.run + ".up"] }

    function power(a) {
        var c = a === "suspend" ? "systemctl suspend" : a === "reboot" ? "systemctl reboot" : a === "poweroff" ? "systemctl poweroff" : "";
        if (c) Quickshell.execDetached(["sh", "-c", c]);
    }

    WlSessionLock {
        id: lock
        locked: true
        onSecureChanged: if (secure) upMark.running = true
        WlSessionLockSurface {
            id: surf
            color: "#0a0d14"
            LockSurface {
                anchors.fill: parent
                profile: root.profile
                wallpaper: root.home + "/.config/sea-shell/sea-lockwall.png"
                clockFont: root.clockFont
                textFont: rhClock.status === FontLoader.Ready ? rhClock.name : Tok.sans
                clockWeight: root.profile.font ? Font.Normal : root.clockWeight
                dateFormat: root.dateFormat
                state_: root.state_
                typed: root.buffer.length
                busy: root.busy
                fails: root.fails
                shakes: root.shakes
                message: root.message
                messageIsError: root.messageIsError
                capsLock: root.capsLock
                layout: root.layout
                notes: root.notes
                showContent: root.cfg.notifications !== "names"
                player: root.player
                battery: root.battery
                leaving: root.leaving
                onKey: e => root.onKey(e)
                onWake: root.wake()
                onPower: a => root.power(a)
            }
        }
    }
}
