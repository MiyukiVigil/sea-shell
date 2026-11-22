// ─────────────────────────────────────────────────────────────────────────────
// sea-shell — screen recorder chooser
//
// Instantiated by shell.qml. Picks what to capture and which audio to record, then
// hands the job to scripts/system/sea-record.sh, which owns wf-recorder and the
// PipeWire mix. Everything device-shaped (mics, outputs, monitors, whether VAAPI is
// available at all) comes from `sea-record.sh probe` rather than being assumed here.
//
// Division of labour: this panel owns the SCREEN (region drag, 3-2-1 countdown) and
// the script owns the RECORDING. So the script never draws anything, and the panel
// never touches wf-recorder. A bare `sea-record.sh start` in a terminal reproduces
// whatever the panel last did, because every choice is passed as a flag *and* saved
// to ~/.config/sea-shell/recorder.json as the default for next time.
//
// Toggle:  qs -c sea-shell ipc call recorder toggle   (SUPER+R)
// While a recording is running SUPER+R stops it instead of opening this — see the
// recorder IPC in shell.qml.
// ─────────────────────────────────────────────────────────────────────────────
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

Scope {
    id: root

    // the shell flattens scripts next to the QML on deploy, so resolve it as a sibling
    readonly property string script: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "") + "/sea-record.sh"

    // ---- set by shell.qml ----
    property bool   recording: false      // a recording is already running
    property bool   exclusiveHold: false  // a DAC is held in bit-perfect mode, bypassing pipewire
    property string exclusiveName: ""     // …by this model

    // ---- choices (persisted to recorder.json) ----
    property string capture:   "region"   // region | screen | output:<name>
    property string audio:     "system"   // none | mic | system | both
    property string mic:       ""         // "" = default source
    property string sys:       ""         // "" = default sink's monitor
    property int    fps:       60
    property string format:    "mp4"      // mp4 | mkv | webm
    property string encoder:   "sw"       // sw | hw
    property int    countdown: 3          // 0 = off
    // "" = wherever the script defaults to. Carried through load → save even though the
    // panel offers no way to change it, so hand-editing recorder.json to record somewhere
    // else isn't silently undone the next time you press record.
    property string dir:       ""

    // ---- probed hardware ----
    property var mics: []                 // [{name, desc, via}]
    property var sinks: []
    property var outputs: []              // [{name, desc, focused}]
    property string defaultMic: ""
    property string defaultSys: ""
    property bool hwAvail: true
    property bool wfAvail: true

    // ---- lifecycle ----
    property bool shown: false
    property int  ticking: 0              // countdown seconds remaining; 0 = not counting
    property string pendingGeom: ""

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
            w.visible = true;
        }
        root.screensMoved = false;
    }
    function open()   { if (root.recording) return; root.placeOn(win); root.load(); root.probe(); root.shown = true }
    function close()  { root.shown = false }
    // SUPER+R is one key for the whole feature: it stops a running recording, otherwise
    // it opens the chooser. So the "already recording" case never opens a window you'd
    // then have to dismiss to get at the stop button.
    function toggle() {
        if (root.recording) { root.stop(); return }
        if (root.shown) root.close(); else root.open();
    }
    function stop()   { Quickshell.execDetached([root.script, "stop"]) }
    function cancel() { Quickshell.execDetached([root.script, "cancel"]) }

    // IPC target "recorder" is owned by shell.qml so SUPER+R works before this panel loads.

    // ---- persistence ----
    // Written via argv rather than a shell string so a device name with a space or a
    // quote in it can't break out. Reading is best-effort: a missing or corrupt file
    // just means the defaults above, never a panel that won't open.
    function save() {
        var j = JSON.stringify({
            capture: root.capture, audio: root.audio, mic: root.mic, sys: root.sys,
            fps: root.fps, format: root.format, encoder: root.encoder,
            countdown: root.countdown, dir: root.dir
        });
        Quickshell.execDetached(["python3", "-c",
            "import sys,os,pathlib; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell'))/sys.argv[1]; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[2])",
            "recorder.json", j]);
    }
    function load() { cfgProc.running = true }
    Process {
        id: cfgProc
        command: ["sh", "-c", "cat ~/.config/sea-shell/recorder.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: cfgOut; onStreamFinished: {
            try {
                var j = JSON.parse(cfgOut.text.trim() || "{}");
                if (j.capture   !== undefined) root.capture   = "" + j.capture;
                if (j.audio     !== undefined) root.audio     = "" + j.audio;
                if (j.mic       !== undefined) root.mic       = "" + j.mic;
                if (j.sys       !== undefined) root.sys       = "" + j.sys;
                if (j.fps       !== undefined) root.fps       = parseInt(j.fps) || 60;
                if (j.format    !== undefined) root.format    = "" + j.format;
                if (j.encoder   !== undefined) root.encoder   = "" + j.encoder;
                if (j.countdown !== undefined) root.countdown = parseInt(j.countdown) || 0;
                if (j.dir       !== undefined) root.dir       = "" + j.dir;
            } catch (e) { /* defaults */ }
        } } }

    // ---- hardware probe ----
    function probe() { probeProc.running = true }
    Process {
        id: probeProc
        command: [root.script, "probe"]
        stdout: StdioCollector { id: probeOut; onStreamFinished: {
            try {
                var j = JSON.parse(probeOut.text.trim() || "{}");
                root.mics = j.mics || [];
                root.sinks = j.sinks || [];
                root.outputs = j.outputs || [];
                root.defaultMic = j.default_mic || "";
                root.defaultSys = j.default_sys || "";
                root.hwAvail = j.hw !== undefined ? !!j.hw : true;
                root.wfAvail = j.wf !== undefined ? !!j.wf : true;
            } catch (e) { /* leave the last good probe in place */ }
        } } }

    // ---- start ----
    // The panel owns the screen, so the order is: put our own UI away, let the user
    // drag a region, count down, and only then hand over. Otherwise the chooser and
    // the slurp overlay end up in frame one of the recording.
    function begin() {
        if (root.recording || !root.wfAvail) return;
        root.save();
        root.shown = false;
        if (root.capture === "region") slurpProc.running = true;
        else root.afterGeom("");
    }
    Process {
        id: slurpProc
        // NOT ["slurp","-d"]. slurp reads a list of regions to highlight from stdin
        // whenever stdin isn't a terminal, and Quickshell gives every Process an open
        // stdin pipe — so bare slurp blocks in read() forever waiting for an EOF that
        // never comes: no wayland connection, no layer surface, nothing on screen to
        // drag. (stdinEnabled:false does not help; the pipe is still there.) Redirecting
        // from /dev/null gives it the EOF and it goes interactive. `exec` keeps the pid
        // slurp's own, so processId still refers to the thing we'd need to kill.
        command: ["sh", "-c", "exec slurp -d </dev/null"]
        stdout: StdioCollector { id: slurpOut; onStreamFinished: {
            var g = slurpOut.text.trim();
            if (g === "") return;             // cancelled the drag — not an error
            root.afterGeom(g);
        } } }
    function afterGeom(geom) {
        root.pendingGeom = geom;
        if (root.countdown > 0) { root.ticking = root.countdown; tick.restart(); }
        else root.launch();
    }
    Timer {
        id: tick; interval: 1000; repeat: true
        onTriggered: {
            root.ticking = root.ticking - 1;
            if (root.ticking <= 0) { tick.stop(); root.launch(); }
        }
    }
    function launch() {
        var a = [root.script, "start",
                 "--capture", root.capture, "--audio", root.audio,
                 "--fps", "" + root.fps, "--format", root.format, "--encoder", root.encoder];
        if (root.pendingGeom !== "") a = a.concat(["--geometry", root.pendingGeom]);
        if (root.mic !== "") a = a.concat(["--mic", root.mic]);
        if (root.sys !== "") a = a.concat(["--sys", root.sys]);
        if (root.dir !== "") a = a.concat(["--dir", root.dir]);
        root.pendingGeom = "";
        Quickshell.execDetached(a);
    }

    // ---- labels ----
    // Name a device the way a person would.
    //
    // Each device gives us a card ("DAWN PRO2", "Alder Lake PCH-P High Definition Audio
    // Controller") and a port ("Analog Output", "Speaker", "HDMI / DisplayPort 2 Output"),
    // and neither one alone is right for both. Show the card and the four built-in outputs
    // become four chips all reading "Alder Lake PCH-P High Defi…". Show the port and the
    // DAC becomes "Analog Output", which is not what anyone calls it.
    //
    // What actually distinguishes them is how many outputs the card has. One → the card IS
    // the device, so name the card. Several → the card name is identical across all of them
    // and carries nothing; the port is the whole information.
    function labelFor(list, item) {
        if (!item) return "";
        var d = item.desc || item.name || "";
        var v = item.via || "";
        if (v === "") return d;
        var n = 0;
        for (var i = 0; i < list.length; i++) if (list[i].via === v) n++;
        return n === 1 ? v : d;
    }
    function findIn(list, name) {
        for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i];
        return null;
    }
    function nameOf(list, name, fallback) {
        var it = root.findIn(list, name);
        return it ? root.labelFor(list, it) : fallback;
    }
    readonly property string micLabel: root.mic === ""
        ? ("Default · " + root.nameOf(root.mics, root.defaultMic, "no microphone"))
        : root.nameOf(root.mics, root.mic, root.mic)
    readonly property string sysLabel: root.sys === ""
        ? ("Default · " + root.nameOf(root.sinks, root.defaultSys, "no output"))
        : root.nameOf(root.sinks, root.sys, root.sys)
    readonly property string captureLabel: root.capture === "region" ? "region"
        : root.capture === "screen" ? "this screen" : root.capture.replace("output:", "")
    // System audio is captured from a sink's MONITOR, which is a pipewire construct. A
    // DAC held in exclusive mode is fed by the player directly over ALSA and never
    // passes through pipewire at all — so the monitor is real, readable, and silent.
    // Say so before the recording rather than after.
    readonly property bool exclusiveWarn: root.exclusiveHold && (root.audio === "system" || root.audio === "both")


    // ---------------- look ----------------
    // The control centre's language, as the dashboard and the shortcuts sheet speak it: titled
    // groups on thin ink panels, macOS segmented controls for one-of-several choices, and the
    // capture targets as tiles.
    readonly property color groupFill: Tok.surface
    readonly property color groupRule: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)
    readonly property color track:     Tok.sunken
    SurfaceMotion { id: motion; opened: root.shown; reduced: Tok.reducedMotion; enterDuration: 180; exitDuration: 110 }

    component Sym: Text {
        property int sz: 18
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // a titled group: the title above, a rounded panel holding the rows
    component Group: ColumnLayout {
        id: grp
        property string title: ""
        default property alias content: gBody.data
        Layout.fillWidth: true
        spacing: Tok.s2
        IndText { text: grp.title; sz: Tok.tDense; font.weight: Font.Bold; Layout.leftMargin: Tok.s1 }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: gBody.implicitHeight + Tok.s3 * 2
            radius: Tok.r + 4
            color: root.groupFill
            border.width: 1; border.color: root.groupRule
            ColumnLayout {
                id: gBody
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Tok.s3 }
                anchors.leftMargin: Tok.s4; anchors.rightMargin: Tok.s3
                spacing: Tok.s3
            }
        }
    }

    // a labelled row inside a group: name on the left, the control on the right
    component Line: RowLayout {
        id: ln
        property string label: ""
        default property alias content: lnSlot.data
        Layout.fillWidth: true
        spacing: Tok.s3
        IndText { text: ln.label; sz: Tok.tDense; Layout.fillWidth: true }
        Row { id: lnSlot; spacing: Tok.s2 }
    }

    // macOS segmented control: one track, the chosen segment raised out of it
    component Segmented: Rectangle {
        id: sc
        property var options: []          // [{ label, value, enabled }]
        property var value
        signal picked(var v)
        implicitWidth: scRow.implicitWidth + 4
        implicitHeight: 30
        radius: 15
        color: root.track
        Row {
            id: scRow
            anchors.centerIn: parent
            Repeater {
                model: sc.options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: sc.value === modelData.value
                    readonly property bool ok: modelData.enabled !== false
                    width: Math.max(52, scT.implicitWidth + 24)
                    height: 26
                    radius: 13
                    color: on ? (Tok.light ? "#ffffff" : Tok.alpha(Tok.ink, 0.16)) : (scMa.containsMouse && ok ? root.rowHover : "transparent")
                    border.width: on ? 1 : 0
                    border.color: root.groupRule
                    opacity: ok ? 1 : 0.4
                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                    IndText { id: scT; anchors.centerIn: parent; text: modelData.label; sz: Tok.tData + 1
                        font.weight: parent.on ? Font.DemiBold : Font.Normal
                        color: parent.on ? Tok.ink : Tok.ink2 }
                    MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true; enabled: parent.ok
                        cursorShape: Qt.PointingHandCursor; onClicked: sc.picked(modelData.value) }
                }
            }
        }
    }

    // a device to pick (microphone, output) — a pill, filled when chosen
    component Pick: Rectangle {
        id: pk
        property string label: ""
        property bool on: false
        signal tapped()
        implicitWidth: Math.min(260, pkT.implicitWidth + 26)
        implicitHeight: 28
        radius: 14
        color: pk.on ? Tok.accentWash : (pkMa.containsMouse ? root.rowHover : "transparent")
        border.width: 1
        border.color: pk.on ? Tok.alpha(Tok.accent, 0.5) : root.groupRule
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText { id: pkT; anchors.centerIn: parent; width: Math.min(implicitWidth, pk.width - 20)
            elide: Text.ElideRight; text: pk.label; sz: Tok.tData + 1
            color: pk.on ? Tok.accent : Tok.ink2; font.weight: pk.on ? Font.DemiBold : Font.Normal }
        MouseArea { id: pkMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: pk.tapped() }
    }

    // what to capture, as a tile
    component CaptureTile: Rectangle {
        id: tg
        property string icon: ""
        property string label: ""
        property string sub: ""
        property bool on: false
        signal tapped()
        Layout.fillWidth: true
        implicitHeight: 82
        radius: Tok.r + 4
        color: tg.on ? Tok.accentWash : (tgMa.containsMouse ? root.rowHover : root.groupFill)
        border.width: 1
        border.color: tg.on ? Tok.alpha(Tok.accent, 0.55) : root.groupRule
        scale: tgMa.pressed ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Column {
            anchors.centerIn: parent
            width: parent.width - 16
            spacing: 3
            Sym { anchors.horizontalCenter: parent.horizontalCenter; text: tg.icon; sz: 26
                color: tg.on ? Tok.accent : Tok.ink }
            IndText { anchors.horizontalCenter: parent.horizontalCenter; text: tg.label; sz: Tok.tDense
                font.weight: Font.Medium; color: tg.on ? Tok.accent : Tok.ink }
            IndText { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                visible: tg.sub !== ""; text: tg.sub; sz: Tok.tData - 1; color: Tok.ink3 }
        }
        MouseArea { id: tgMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: tg.tapped() }
    }

    component Btn: Rectangle {
        id: bt
        property string text: ""
        property string icon: ""
        property bool primary: false
        signal tapped()
        implicitWidth: btRow.implicitWidth + 30
        implicitHeight: 36
        radius: 18
        opacity: bt.enabled ? 1 : 0.45
        color: bt.primary ? (btMa.containsMouse ? Qt.lighter(Tok.crit, 1.08) : Tok.crit)
                          : (btMa.containsMouse ? root.rowHover : root.groupFill)
        border.width: bt.primary ? 0 : 1
        border.color: root.groupRule
        scale: btMa.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Row {
            id: btRow
            anchors.centerIn: parent
            spacing: 7
            Rectangle { visible: bt.primary; anchors.verticalCenter: parent.verticalCenter
                width: 10; height: 10; radius: 5; color: "white" }
            IndText { anchors.verticalCenter: parent.verticalCenter; text: bt.text; sz: Tok.tDense
                font.weight: Font.DemiBold; color: bt.primary ? "white" : Tok.ink }
        }
        MouseArea { id: btMa; anchors.fill: parent; enabled: bt.enabled; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: bt.tapped() }
    }

    // ---------------- the chooser ----------------
    // KEPT WARM, like the dashboard and settings: closed, the window stays mapped as one
    // transparent pixel that takes no input or keys, so SUPER+R is a resize, not a new surface.
    PanelWindow {
        id: win
        readonly property real ui: Tok.uiFor(win.screen)
        readonly property bool live: root.shown || motion.presenting
        // Keep fullscreen geometry stable when the compositor maps the panel.
        anchors { top: true; left: true; bottom: true; right: true }
        visible: win.live
        implicitWidth: 1
        implicitHeight: 1
        mask: win.live ? allInput : noInput
        Region { id: noInput }
        Region { id: allInput; item: win.contentItem }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:recorder"
        // Keep closed panels warm without blocking fullscreen presentation.
        WlrLayershell.layer: (win.live) ? WlrLayer.Overlay : WlrLayer.Bottom
        // Quickshell applies the new layer when the native surface is mapped again.
        // Keep the QML content resident and preserve the window's visibility policy.
        Connections {
            target: win.WlrLayershell
            function onLayerChanged() {
                if (!win.visible) return;
                win.visible = false;
                win.visible = Qt.binding(function() { return win.live; });
            }
        }
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

        Rectangle {
            id: scrim
            anchors.centerIn: parent
            width: win.width / win.ui; height: win.height / win.ui
            color: Qt.rgba(0, 0, 0, Tok.light ? 0.30 : 0.50)
            opacity: motion.progress
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }
        Item { anchors.fill: scrim; focus: root.shown
            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: root.begin()
            Keys.onEnterPressed: root.begin() }

        Rectangle {
            anchors.centerIn: scrim
            anchors.verticalCenterOffset: (1 - motion.progress) * 14
            width: 600
            height: card.implicitHeight + Tok.s6 * 2
            radius: Tok.rCard
            color: Tok.bg
            border.width: 1; border.color: root.groupRule
            opacity: motion.progress
            scale: 0.98 + 0.02 * motion.progress
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: card
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Tok.s6 }
                spacing: Tok.s4

                // ---- header ----
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tok.s3
                    Rectangle {
                        implicitWidth: 40; implicitHeight: 40; radius: Tok.r + 4
                        color: Tok.crit
                        Sym { anchors.centerIn: parent; text: "videocam"; sz: 22; color: "white" }
                    }
                    ColumnLayout {
                        spacing: 1
                        Layout.fillWidth: true
                        IndText { text: "Record screen"; sz: Tok.tTitle; font.weight: Font.Bold }
                        IndText {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            sz: Tok.tDense; color: root.wfAvail ? Tok.ink3 : Tok.crit
                            text: root.wfAvail
                                ? (root.audio === "none" ? "No audio" : root.audio === "mic" ? "Microphone"
                                   : root.audio === "system" ? "System audio" : "Microphone and system audio")
                                  + ", " + root.fps + " fps " + root.format.toUpperCase()
                                : "wf-recorder is not installed: pacman -S wf-recorder"
                        }
                    }
                    Rectangle {
                        implicitWidth: 34; implicitHeight: 34; radius: 17
                        color: rfMa.containsMouse ? root.rowHover : "transparent"
                        Sym { anchors.centerIn: parent; text: "refresh"; sz: 18 }
                        MouseArea { id: rfMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.probe() }
                    }
                    Rectangle {
                        implicitWidth: 34; implicitHeight: 34; radius: 17
                        color: clMa.containsMouse ? root.rowHover : root.groupFill
                        border.width: 1; border.color: root.groupRule
                        Sym { anchors.centerIn: parent; text: "close"; sz: 18 }
                        MouseArea { id: clMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                    }
                }

                // ---- capture ----
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tok.s2
                    CaptureTile { icon: "crop"; label: "Region"; sub: "Drag to select"
                        on: root.capture === "region"; onTapped: root.capture = "region" }
                    CaptureTile { icon: "desktop_windows"; label: "This screen"; sub: "Where the pointer is"
                        on: root.capture === "screen"; onTapped: root.capture = "screen" }
                    Repeater {
                        model: root.outputs.length > 1 ? root.outputs : []
                        delegate: CaptureTile {
                            required property var modelData
                            icon: "monitor"; label: modelData.name; sub: modelData.desc
                            on: root.capture === ("output:" + modelData.name)
                            onTapped: root.capture = "output:" + modelData.name
                        }
                    }
                }

                // ---- audio ----
                Group {
                    title: "Audio"
                    Segmented {
                        value: root.audio
                        options: [{ label: "None", value: "none" }, { label: "Microphone", value: "mic" },
                                  { label: "System", value: "system" },
                                  { label: "Both", value: "both", enabled: root.mics.length > 0 }]
                        onPicked: (v) => root.audio = v
                    }
                    // device pickers only for the sources actually being recorded
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Tok.s1
                        visible: root.audio === "mic" || root.audio === "both"
                        IndText { text: "Microphone"; sz: Tok.tData; color: Tok.ink3 }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            Pick { label: root.micLabel.indexOf("Default") === 0 ? root.micLabel.replace("Default · ", "Default: ") : "Default"
                                on: root.mic === ""; onTapped: root.mic = "" }
                            Repeater {
                                model: root.mics
                                delegate: Pick {
                                    required property var modelData
                                    label: root.labelFor(root.mics, modelData)
                                    on: root.mic === modelData.name
                                    onTapped: root.mic = modelData.name
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Tok.s1
                        visible: root.audio === "system" || root.audio === "both"
                        IndText { text: "System audio, recorded from this output"; sz: Tok.tData; color: Tok.ink3 }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            // "Default" is not just a shortcut: it re-reads the default sink at
                            // start, so recordings follow the DAC when it's plugged in.
                            Pick { label: root.sysLabel.indexOf("Default") === 0 ? root.sysLabel.replace("Default · ", "Default: ") : "Default"
                                on: root.sys === ""; onTapped: root.sys = "" }
                            Repeater {
                                model: root.sinks
                                delegate: Pick {
                                    required property var modelData
                                    label: root.labelFor(root.sinks, modelData)
                                    on: root.sys === modelData.name
                                    onTapped: root.sys = modelData.name
                                }
                            }
                        }
                    }
                    // the one thing that silently produces a dead audio track
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.exclusiveWarn
                        implicitHeight: exw.implicitHeight + 18
                        radius: Tok.r + 2
                        color: Tok.warnWash
                        RowLayout {
                            id: exw
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                      leftMargin: 12; rightMargin: 12 }
                            spacing: 10
                            Sym { text: "warning"; sz: 17; color: Tok.warn; Layout.alignment: Qt.AlignTop }
                            IndText {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: (root.exclusiveName || "A DAC") + " is playing bit-perfect, straight to ALSA. "
                                      + "That bypasses PipeWire, so system audio will record as silence. "
                                      + "Record the microphone, or take the player out of exclusive mode."
                                color: Tok.warn; sz: Tok.tData; lineHeight: 1.25
                            }
                        }
                    }
                }

                // ---- quality ----
                Group {
                    title: "Quality"
                    Line { label: "Frame rate"
                        Segmented { value: root.fps; onPicked: (v) => root.fps = v
                            options: [{ label: "30", value: 30 }, { label: "60", value: 60 }, { label: "120", value: 120 }] } }
                    Line { label: "Format"
                        Segmented { value: root.format; onPicked: (v) => root.format = v
                            options: [{ label: "MP4", value: "mp4" }, { label: "MKV", value: "mkv" }, { label: "WebM", value: "webm" }] } }
                    Line { label: "Encoder"
                        Segmented { value: root.encoder; onPicked: (v) => root.encoder = v
                            options: [{ label: "CPU", value: "sw" }, { label: "GPU", value: "hw", enabled: root.hwAvail }] } }
                    IndText {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        // mkv is the honest recommendation, not a preference: mp4 keeps its index
                        // at the end of the file, so a recording that dies with the machine is a
                        // write-off. mkv can be cut short and still plays.
                        text: root.format === "mp4"
                              ? "MP4 writes its index when you stop, so a crash mid-recording loses the file. MKV survives that."
                              : root.format === "webm"
                              ? "WebM (VP9) is the slowest to encode; on a long capture the CPU may not keep up."
                              : "MKV keeps every frame written so far, even if the recording never stops cleanly."
                        sz: Tok.tData; color: Tok.ink3; lineHeight: 1.25
                    }
                }

                // ---- countdown + destination ----
                Group {
                    title: "Start"
                    Line { label: "Countdown"
                        Segmented { value: root.countdown; onPicked: (v) => root.countdown = v
                            options: [{ label: "Off", value: 0 }, { label: "3 s", value: 3 }, { label: "5 s", value: 5 }] } }
                    Line { label: "Saved to"
                        Rectangle {
                            implicitWidth: dirRow.implicitWidth + 16; implicitHeight: 26; radius: 13
                            color: dirMa.containsMouse ? Tok.raised : Tok.sunken
                            border.width: 1; border.color: root.groupRule
                            Row {
                                id: dirRow; anchors.centerIn: parent; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "folder_open"; sz: 14; color: dirMa.containsMouse ? Tok.accent : Tok.ink3 }
                                IndText { anchors.verticalCenter: parent.verticalCenter; text: root.dir !== "" ? root.dir : "~/Videos/Recordings"; mono: true
                                    sz: Tok.tData; color: Tok.ink2; elide: Text.ElideLeft; width: Math.min(implicitWidth, 230) }
                            }
                            MouseArea {
                                id: dirMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var d = root.dir !== "" ? root.dir : "$HOME/Videos/Recordings";
                                    Quickshell.execDetached(["sh", "-c", "mkdir -p \"" + d + "\" && xdg-open \"" + d + "\""]);
                                    root.close();
                                }
                            }
                        }
                    }
                }

                // ---- actions ----
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Tok.s1
                    spacing: Tok.s2
                    IndText {
                        Layout.fillWidth: true
                        text: root.capture === "region" ? "Enter to choose a region and record" : "Enter to record"
                        sz: Tok.tData; color: Tok.ink3
                    }
                    Btn { text: "Cancel"; onTapped: root.close() }
                    Btn { text: "Record"; primary: true; enabled: root.wfAvail; onTapped: root.begin() }
                }
            }
        }
    }

    // ---------------- countdown ----------------
    // Click-through (empty input mask) and never focused: it is painted over whatever
    // is about to be recorded, and must not steal the pointer from it. It is gone
    // before wf-recorder starts, so it can't land in frame one.
    PanelWindow {
        id: cd
        visible: root.ticking > 0
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: Region {}

        Rectangle {
            id: cdDisc
            anchors.centerIn: parent
            width: 148; height: 148; radius: 74
            color: Tok.bg
            border.width: 1; border.color: root.groupRule
            // the second draining away round the rim
            Canvas {
                id: cdRing
                anchors.fill: parent
                property real p: 0
                NumberAnimation on p { id: cdSweep; from: 1; to: 0; duration: 1000; running: false }
                onPChanged: requestPaint()
                onPaint: {
                    var c = getContext("2d"), r = width / 2 - 5;
                    c.clearRect(0, 0, width, height);
                    c.lineWidth = 5; c.lineCap = "round";
                    c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p);
                    c.strokeStyle = Tok.crit; c.stroke();
                }
            }
            IndText { anchors.centerIn: parent; text: "" + root.ticking; sz: 64; font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 }) }
        }
        Connections {
            target: root
            function onTickingChanged() { if (root.ticking > 0) cdSweep.restart() }
        }
    }
}
