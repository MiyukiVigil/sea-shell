// sea-shell — power / session menu (SUPER+ESC), a component. Esc or click-outside closes.
// ←→/Tab or hover to select · ⏎ or the letter to go · 1–5 quick.
// Log out, restart and shut down end open work, so they are HELD: keep the key or the button
// down while the ring fills (letting go early cancels). Lock and suspend lose nothing and act
// at once. Below the tiles: which apps would close, restart to firmware setup (UEFI only) and
// shut down later (a transient systemd user timer, sea-shutdown.timer).
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

Scope {
    id: root
    // Kept in the shell (shell.qml) so it opens at once; power.qml wraps it for when the shell
    // is not running. open() re-reads everything it shows, since it stays loaded between uses.
    property bool shown: false
    signal closed()
    function open() {
        root.sel = 0; root.holding = null; root.holdP = 0;
        upProc.running = true; appsProc.running = true; laterProc.running = true;
        root.shown = true;
    }
    function close() { holdAnim.stop(); root.holding = null; root.holdP = 0; root.shown = false; root.closed() }
    function toggle() { if (root.shown) root.close(); else root.open() }
    property var userProfile: ({})
    FileView { path: Quickshell.env("HOME") + "/.config/sea-shell/profile.json"; watchChanges: true
        onLoaded: { try { root.userProfile=JSON.parse(text()) } catch(e){} }
        onFileChanged: reload()
    }
    property int sel: 0
    property string up: ""
    property real cfgScale: 0     // 0 = auto (per-monitor), >0 = manual UI-scale multiplier
    property var  cfgMonitors: ({})   // per-monitor overrides from appearance.json
    function uiFor(scr) {          // matches shell.qml: ≤1440p → 1×, grows past it, capped 2.5×
        var mo = (scr && scr.name && root.cfgMonitors[scr.name]) ? root.cfgMonitors[scr.name].scale : 0;
        if (mo > 0) return mo;                // per-monitor override wins (same rule as the bar)
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    // follow the bar's UI scale (colours come from Tok)
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.scale!==undefined) root.cfgScale=j.scale; if(j.monitors) root.cfgMonitors=j.monitors } catch(e){} } } }

    property var actions: [
        {i:"lock",       l:"Lock",      k:Qt.Key_L, c:"~/.config/quickshell/sea-shell/sea-lock.sh",  what:"Locks the screen. Everything stays open."},
        {i:"bedtime",    l:"Suspend",   k:Qt.Key_S, c:"systemctl suspend",  what:"Sleeps. Everything stays open and comes back as it was."},
        {i:"logout",     l:"Log out",   k:Qt.Key_O, c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }", hold:true, what:"Ends the session."},
        {i:"restart_alt",l:"Restart",   k:Qt.Key_R, c:"systemctl reboot",   hold:true, what:"Restarts the computer."},
        {i:"power_settings_new", l:"Shut down", k:Qt.Key_P, c:"systemctl poweroff", hold:true, crit:true, what:"Turns the computer off."}
    ]
    readonly property var firmware: ({i:"memory", l:"restart into firmware setup", k:Qt.Key_F, c:"systemctl reboot --firmware-setup", hold:true, what:"Restarts into the UEFI firmware setup."})
    function run(c) { Quickshell.execDetached(["sh","-c",c]); root.close() }

    // ---------- hold to confirm ----------
    property var holding: null        // the action being held, or null
    property real holdP: 0
    NumberAnimation { id: holdAnim; target: root; property: "holdP"; from: 0; to: 1
        duration: 750; easing.type: Easing.InOutQuad
        onFinished: if (root.holding && root.holdP >= 0.999) root.run(root.holding.c) }
    NumberAnimation { id: holdBack; target: root; property: "holdP"; to: 0; duration: Tok.reducedMotion ? 0 : 160; easing.type: Easing.OutCubic }
    function press(a) {
        if (!a.hold) { root.run(a.c); return }
        holdBack.stop(); root.holding = a; holdAnim.restart();
    }
    function release() {
        if (!root.holding || root.holdP >= 0.999) return;
        holdAnim.stop(); root.holding = null; holdBack.restart();
    }
    readonly property var showing: root.holding || root.actions[root.sel]

    // ---------- what is on screen right now ----------
    Process { id: upProc; command: ["awk", "{s=int($1); printf \"%dh %02dm\", s/3600, (s%3600)/60}", "/proc/uptime"]
        stdout: StdioCollector { onStreamFinished: root.up = text.trim() } }
    readonly property string batt: {
        var d = UPower.displayDevice;
        if (!d || !d.isLaptopBattery) return "";
        return Math.round((d.percentage || 0) * 100) + "%" + (UPower.onBattery ? "" : ", charging");
    }
    // open windows, one entry per app, in the order Hyprland lists them
    property var apps: []
    Process { id: appsProc; command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { onStreamFinished: {
            try {
                var cs = JSON.parse(text), seen = {}, out = [];
                for (var i = 0; i < cs.length; i++) {
                    var c = cs[i], k = (c.class || c.initialClass || "").trim();
                    if (!k || c.mapped === false) continue;
                    if (seen[k]) { seen[k].n++; continue }
                    seen[k] = { k: k, n: 1 };
                    out.push(seen[k]);
                }
                root.apps = out;
            } catch (err) {}
        } } }
    property bool efi: false
    Process { running: true; command: ["test", "-d", "/sys/firmware/efi"]; onExited: code => root.efi = code === 0 }

    // ---------- shut down later ----------
    property string laterAt: ""       // "22:30" while sea-shutdown.timer is waiting
    Process { id: laterProc
        command: ["systemctl", "--user", "show", "sea-shutdown.timer", "-p", "ActiveState", "-p", "NextElapseUSecRealtime", "--value"]
        stdout: StdioCollector { onStreamFinished: {
            var l = text.trim().split("\n");
            var m = (l[1] || "").match(/(\d\d:\d\d):\d\d/);
            root.laterAt = l[0] === "active" && m ? m[1] : "";
        } } }
    function later(min) {
        Quickshell.execDetached(["sh", "-c",
            "systemctl --user stop sea-shutdown.timer 2>/dev/null; systemd-run --user --unit=sea-shutdown --on-active=" + min + "m --timer-property=AccuracySec=1s systemctl poweroff"
            + " && notify-send -i system-shutdown 'Shutting down in " + (min >= 60 ? min / 60 + " h" : min + " min") + "' 'Open the power menu to cancel'"]);
        root.close();
    }
    function cancelLater() {
        Quickshell.execDetached(["sh", "-c", "systemctl --user stop sea-shutdown.timer && notify-send -i system-shutdown 'Shutdown cancelled'"]);
        root.laterAt = "";
    }

    // Kept warm like the settings window: closed, it is one transparent pixel that takes no
    // input, so opening skips building a surface (that and starting a process each time was
    // the ~0.3 s wait before the menu appeared).
    PanelWindow {
        id: win
        readonly property real ui: root.uiFor(win.screen)
        readonly property bool live: root.shown || stage.opacity > 0
        anchors { top: true; left: true; bottom: win.live; right: win.live }
        implicitWidth: 1; implicitHeight: 1
        // two regions, not null: a null mask cannot be assigned back, so the window stayed click-through once opened
        mask: win.live ? allInput : noInput
        Region { id: noInput }
        Region { id: allInput; item: win.contentItem }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:power"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        // scale the whole overlay up on big displays; centred content stays centred
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

        Item {
            id: stage
            anchors.fill: parent
            opacity: root.shown ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Tok.reducedMotion ? 0 : (root.shown ? 120 : 90); easing.type: Easing.OutCubic } }

            // scrim in native units so it still reaches the screen edges after the scale
            Rectangle { anchors.centerIn: parent; width: win.contentItem.width / win.ui; height: win.contentItem.height / win.ui
                color: Qt.rgba(0,0,0,0.6); MouseArea { anchors.fill: parent; onClicked: root.close() } }
            Item {
                anchors.fill: parent; focus: root.shown
                function keyAction(k) {
                    for (var i = 0; i < root.actions.length; i++) if (k === root.actions[i].k) return root.actions[i];
                    if (root.efi && k === root.firmware.k) return root.firmware;
                    return null;
                }
                Keys.onPressed: (e) => {
                    e.accepted = true;
                    if (e.isAutoRepeat) return;
                    if (e.key === Qt.Key_Escape) { if (root.holding) root.release(); else root.close(); return }
                    if (root.holding) return;
                    var n = root.actions.length;
                    if (e.key === Qt.Key_Left  || e.key === Qt.Key_Backtab) { root.sel = (root.sel+n-1)%n; return }
                    if (e.key === Qt.Key_Right || e.key === Qt.Key_Tab)     { root.sel = (root.sel+1)%n; return }
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { root.press(root.actions[root.sel]); return }
                    if (e.key >= Qt.Key_1 && e.key <= Qt.Key_5) { root.sel = e.key - Qt.Key_1; root.press(root.actions[root.sel]); return }
                    var a = keyAction(e.key);
                    if (a) { var i = root.actions.indexOf(a); if (i >= 0) root.sel = i; root.press(a) }
                }
                Keys.onReleased: (e) => { if (!e.isAutoRepeat) { e.accepted = true; root.release() } }
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: 680; height: body.implicitHeight + 48; radius: 24
                color: Tok.bg; border.width: 1; border.color: Tok.ruleHard
                MouseArea { anchors.fill: parent }      // clicks inside the card do not close it

                Column {
                    id: body
                    x: 24; y: 24; width: parent.width - 48
                    spacing: 18

                    // One row, not a card: you on the left, the machine's state on the right. The old
                    // full ProfileCard left a block of empty space beside a short name.
                    Item {
                        width: parent.width; height: 56
                        Rectangle {
                            id: face
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: 52; height: 52; radius: 26; color: Tok.sunken
                            Text { anchors.centerIn: parent; text: "person"; font.family: "Material Symbols Outlined"; font.pixelSize: 26; color: Tok.ink3 }
                            Image { id: faceImg; anchors.fill: parent; visible: false
                                source: root.userProfile.avatar ? "file://" + root.userProfile.avatar : ""
                                fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 128 }
                            MultiEffect { anchors.fill: parent; source: faceImg; visible: faceImg.status === Image.Ready
                                maskEnabled: true; maskSource: faceMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                            Rectangle { id: faceMask; anchors.fill: parent; radius: 26; visible: false; layer.enabled: true }
                        }
                        // the name in the profile font, scaled to look as big as the UI font would
                        // (the reasoning is in ProfileCard.qml)
                        Text {
                            id: nameT
                            anchors.left: face.right; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                            anchors.right: statusCol.left; anchors.rightMargin: 16
                            elide: Text.ElideRight
                            text: root.userProfile.name || Quickshell.env("USER") || ""
                            FontMetrics { id: plainName; font.family: Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
                            FontMetrics { id: chosenName; font.family: root.userProfile.font || Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
                            readonly property real opticalScale: {
                                var a = plainName.tightBoundingRect(text).width, b = chosenName.tightBoundingRect(text).width;
                                if (!(a > 0 && b > 0 && plainName.xHeight > 0 && chosenName.xHeight > 0)) return 1;
                                return Math.max(1, Math.min(2, Math.sqrt(plainName.xHeight / chosenName.xHeight * a / b)));
                            }
                            font.family: root.userProfile.font || Tok.sans; font.weight: Font.DemiBold
                            font.pixelSize: Math.round(Math.min(24, (root.userProfile.nameSize || 22) * 0.75) * opticalScale)
                            color: root.userProfile.color || Tok.ink
                            layer.enabled: root.userProfile.glow === true
                            layer.effect: MultiEffect { shadowEnabled: true; shadowColor: root.userProfile.color || Tok.accent; shadowBlur: 0.6; shadowOpacity: 0.6 }
                        }
                        Column {
                            id: statusCol
                            anchors.right: parent.right; anchors.rightMargin: 64; anchors.verticalCenter: parent.verticalCenter
                            spacing: 4
                            Repeater {
                                model: [ { i: "schedule", t: "Up " + root.up, on: root.up !== "", c: Tok.ink2 },
                                         { i: "battery_full", t: root.batt, on: root.batt !== "", c: Tok.ink2 },
                                         { i: "timer", t: "Shutting down at " + root.laterAt, on: root.laterAt !== "", c: Tok.warn } ]
                                delegate: Row {
                                    required property var modelData
                                    visible: modelData.on
                                    anchors.right: parent.right; spacing: 6
                                    Text { text: modelData.t; color: modelData.c; font.pixelSize: 12; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: modelData.i; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: Tok.ink3; anchors.verticalCenter: parent.verticalCenter }
                                }
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter; spacing: 10
                        Repeater {
                            model: root.actions
                            delegate: Rectangle {
                                id: tile
                                required property var modelData
                                required property int index
                                readonly property bool cur: index === root.sel
                                readonly property bool held: root.holding === modelData
                                readonly property color tint: modelData.hold ? (modelData.crit ? Tok.crit : Tok.warn) : Tok.accent
                                width: 118; height: 118; radius: Tok.rCard
                                scale: held ? 0.97 : cur ? 1.025 : 1.0
                                color: held ? (modelData.crit ? Tok.critWash : Tok.warnWash) : cur ? Tok.accentWash : Tok.bg
                                border.width: cur || held ? 2 : 1
                                border.color: cur || held ? tile.tint : Qt.rgba(Tok.accent.r, Tok.accent.g, Tok.accent.b, 0.24)
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }

                                Item {
                                    anchors.horizontalCenter: parent.horizontalCenter; y: 14
                                    width: 54; height: 54
                                    // a faint track where the ring will run, so "hold" is visible before you press
                                    Rectangle { anchors.fill: parent; radius: width / 2; color: "transparent"
                                        visible: !!tile.modelData.hold; border.width: 2; border.color: tile.cur ? Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, 0.25) : Tok.rule }
                                    Shape {
                                        anchors.fill: parent
                                        visible: tile.held || (tile.cur && root.holdP > 0)
                                        preferredRendererType: Shape.CurveRenderer
                                        ShapePath {
                                            strokeColor: tile.tint; strokeWidth: 3; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                            PathAngleArc { centerX: 27; centerY: 27; radiusX: 26; radiusY: 26; startAngle: -90; sweepAngle: 360 * root.holdP }
                                        }
                                    }
                                    Text { anchors.centerIn: parent; text: tile.modelData.i
                                        font.family: "Material Symbols Outlined"; font.pixelSize: 28
                                        color: tile.cur || tile.held ? tile.tint : Tok.ink2 }
                                }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; y: 76
                                    text: tile.modelData.l; color: Tok.ink; font.pixelSize: 14; font.family: Tok.sans }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; y: 96
                                    text: (tile.modelData.hold ? "hold " : "") + String.fromCharCode(tile.modelData.k).toLowerCase()
                                    color: tile.cur ? Tok.ink2 : Tok.ink3; font.pixelSize: 10; font.family: Tok.sans }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onEntered: if (!root.holding) root.sel = tile.index
                                    onPressed: { root.sel = tile.index; root.press(tile.modelData) }
                                    onReleased: root.release()
                                    onCanceled: root.release() }
                            }
                        }
                    }

                    // what the selected action does, and for the ones that end the session, what closes
                    Column {
                        width: parent.width; spacing: 10
                        Text {
                            width: parent.width; horizontalAlignment: Text.AlignHCenter
                            text: root.holding ? "Keep holding to " + root.holding.l.toLowerCase() + ". Let go to cancel."
                                               : root.showing.what + (root.showing.hold ? " Hold to confirm." : "")
                            color: root.holding ? (root.holding.crit ? Tok.crit : Tok.warn) : Tok.ink2
                            font.pixelSize: 12; font.family: Tok.sans
                        }
                        Item {
                            width: parent.width; height: 26
                            visible: !!root.showing.hold
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 6
                                Text { height: 26; verticalAlignment: Text.AlignVCenter; rightPadding: 4
                                    text: root.apps.length ? "Closes" : "No open windows"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                                Repeater {
                                    model: root.apps.slice(0, 5)
                                    delegate: Rectangle {
                                        required property var modelData
                                        // looked up here, not when the list is read: the .desktop
                                        // entries load after this window opens, and this re-reads when they do
                                        readonly property var entry: DesktopEntries.applications.values.length >= 0 ? DesktopEntries.heuristicLookup(modelData.k) : null
                                        width: chip.implicitWidth + 16; height: 26; radius: 13
                                        color: Tok.surface; border.width: 1; border.color: Tok.rule
                                        Row {
                                            id: chip; anchors.centerIn: parent; spacing: 6
                                            Image { width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                                                source: Quickshell.iconPath(entry && entry.icon ? entry.icon : modelData.k, true) || ""; sourceSize.width: 32
                                                visible: status === Image.Ready }
                                            Text { anchors.verticalCenter: parent.verticalCenter
                                                text: (entry && entry.name ? entry.name : modelData.k) + (modelData.n > 1 ? " ×" + modelData.n : "")
                                                color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans
                                                width: Math.min(implicitWidth, 110); elide: Text.ElideRight }
                                        }
                                    }
                                }
                                Text { visible: root.apps.length > 5; height: 26; verticalAlignment: Text.AlignVCenter
                                    text: "+" + (root.apps.length - 5) + " more"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                            }
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: Tok.rule }

                    // the rarer two: firmware setup on the left, shut down later on the right
                    Item {
                        width: parent.width; height: 32
                        Rectangle {
                            id: fwBtn
                            visible: root.efi
                            readonly property bool held: root.holding === root.firmware
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: fwRow.implicitWidth + 24; height: 32; radius: 16
                            color: held ? Tok.warnWash : fwMa.containsMouse ? Tok.surface : "transparent"
                            border.width: 1; border.color: held ? Tok.warn : Tok.rule
                            clip: true
                            Rectangle { visible: fwBtn.held; width: parent.width * root.holdP; height: parent.height; radius: 16
                                color: Qt.rgba(Tok.warn.r, Tok.warn.g, Tok.warn.b, 0.25) }
                            Row { id: fwRow; anchors.centerIn: parent; spacing: 6
                                Text { text: "memory"; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: fwBtn.held ? Tok.warn : Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "Firmware setup"; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "hold f"; color: Tok.ink3; font.pixelSize: 10; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter }
                            }
                            MouseArea { id: fwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onPressed: root.press(root.firmware); onReleased: root.release(); onCanceled: root.release() }
                        }
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            Text { anchors.verticalCenter: parent.verticalCenter; rightPadding: 4
                                text: root.laterAt ? "Shutting down at " + root.laterAt : "Shut down in"
                                color: root.laterAt ? Tok.warn : Tok.ink3; font.pixelSize: 12; font.family: Tok.sans }
                            Repeater {
                                model: root.laterAt ? [{ l: "Cancel", m: 0 }] : [{ l: "15 min", m: 15 }, { l: "30 min", m: 30 }, { l: "1 h", m: 60 }]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: lt.implicitWidth + 22; height: 32; radius: 16
                                    color: lma.containsMouse ? Tok.surface : "transparent"; border.width: 1; border.color: Tok.rule
                                    Text { id: lt; anchors.centerIn: parent; text: modelData.l; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans }
                                    MouseArea { id: lma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: modelData.m ? root.later(modelData.m) : root.cancelLater() }
                                }
                            }
                        }
                    }
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: card.bottom; anchors.topMargin: 16
                text: "←→ select · ⏎ go · l s o r p · esc to close"
                color: Qt.rgba(1, 1, 1, 0.55)
                font.pixelSize: 12; font.family: Tok.sans
            }
            // Miku, stuck on the card's corner like a sticker; she only moves while the menu is up
            AnimatedImage {
                anchors.right: card.right; anchors.rightMargin: -30
                anchors.top: card.top; anchors.topMargin: -38
                width: 96; height: 96; rotation: 8
                source: Qt.resolvedUrl("power-miku.gif")
                playing: root.shown && !Tok.reducedMotion
                fillMode: Image.PreserveAspectFit; smooth: true
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000"; shadowOpacity: 0.35; shadowBlur: 0.5; shadowVerticalOffset: 3 }
            }
        }
    }
}
