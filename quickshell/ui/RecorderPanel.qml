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

    function open()   { if (root.recording) return; apReadProc.running = true;  // appearance may have changed while closed
                        root.load(); root.probe(); root.shown = true }
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

    IpcHandler {
        target: "recorder"
        function toggle(): void { root.toggle() }
        function open(): void   { root.open() }
        function close(): void  { root.close() }
        function stop(): void   { root.stop() }
        function cancel(): void { root.cancel() }
    }

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

    // ---- theme (reads the shared appearance.json so it matches the rice) ----
    property string apAccent: "#63c7dd"
    property bool   apLight: false
    // Re-run on every open() — matugen rewrites `accent` whenever the wallpaper changes, and a
    // panel that only read this at bar startup would sit on a stale colour while the bar recoloured.
    Process { id: apReadProc; running: true; command: ["sh","-c","cat ~/.config/sea-shell/appearance.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j = JSON.parse(apOut.text.trim() || "{}");
            if (j.accent) root.apAccent = j.accent; if (j.mode !== undefined) root.apLight = ("" + j.mode === "light"); } catch(e){} } } }
    // ---------- industrial token shim ----------
    // Colours come from the shared Tok singleton (see shell.qml). This surface used to carry its
    // own copy of the ramp AND its own appearance.json parse, so it drifted from the bar every
    // time the palette changed. The `theme.*` vocabulary is kept because the call sites below
    // speak it; only the source of the values moved.
    QtObject {
        id: theme
        readonly property bool  light: Tok.light
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

    component Sym: Text { property int sz: 18; font.family: "Material Symbols Outlined"; font.pixelSize: sz
        color: theme.iris; verticalAlignment: Text.AlignVCenter }

    component Head: Text {
        color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1
    }

    // A segmented choice. Carries no anchors of its own so it can live inside a Flow
    // or a RowLayout without fighting the positioner for its geometry.
    component Seg: Rectangle {
        id: sg
        property string label: ""
        property string sub: ""
        property bool on: false
        property int maxW: 0
        signal tapped()
        implicitHeight: 28
        implicitWidth: Math.min(sg.maxW > 0 ? sg.maxW : 9999, sgt.implicitWidth + 20)
        radius: Tok.r
        opacity: sg.enabled ? 1 : 0.4
        color: sg.on ? theme.iris : (sgm.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: theme.a(theme.iris, sg.on ? 0.6 : 0.18)
        Behavior on color { ColorAnimation { duration: 110 } }
        Text {
            id: sgt
            anchors.centerIn: parent
            width: Math.min(implicitWidth, sg.width - 16)
            elide: Text.ElideRight
            text: sg.label; color: sg.on ? theme.bg : theme.sub
            font.pixelSize: 11; font.family: Tok.mono; font.bold: sg.on
        }
        MouseArea { id: sgm; anchors.fill: parent; enabled: sg.enabled
            hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sg.tapped() }
    }

    component IconBtn: Rectangle {
        id: ib
        property string icon: ""; property int sz: 30; signal tapped()
        implicitWidth: sz + 4; implicitHeight: sz + 4; radius: Tok.r
        color: ibm.containsMouse ? theme.a(theme.iris, 0.18) : "transparent"
        Sym { anchors.centerIn: parent; text: ib.icon; sz: Math.round(ib.sz * 0.6); color: theme.sub }
        MouseArea { id: ibm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ib.tapped() }
    }

    component TextBtn: Rectangle {
        id: tb
        property string label: ""; property string icon: ""; property bool primary: false; signal tapped()
        implicitHeight: 32; implicitWidth: tbr.width + 22; radius: Tok.r
        opacity: tb.enabled ? 1 : 0.4
        color: tb.primary ? (tbm.containsMouse ? theme.frost : theme.iris) : (tbm.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: theme.a(theme.iris, tb.primary ? 0.5 : 0.2)
        RowLayout { id: tbr; anchors.centerIn: parent; spacing: 7
            Sym { text: tb.icon; sz: 15; color: tb.primary ? theme.bg : theme.frost }
            Text { text: tb.label; color: tb.primary ? theme.bg : theme.sub; font.pixelSize: 11; font.family: Tok.mono; font.bold: tb.primary } }
        MouseArea { id: tbm; anchors.fill: parent; enabled: tb.enabled; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tb.tapped() }
    }

    // ---------------- the chooser ----------------
    PanelWindow {
        id: win
        visible: root.shown
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.5)
            MouseArea { anchors.fill: parent; onClicked: root.close() } }
        Item { anchors.fill: parent; focus: root.shown
            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: root.begin()
            Keys.onEnterPressed: root.begin() }

        Rectangle {
            anchors.centerIn: parent
            width: 560
            height: card.implicitHeight + 40
            radius: Tok.rCard
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: card
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 20
                spacing: 14

                // ---- header ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Sym { text: "videocam"; sz: 26; color: theme.iris }
                    ColumnLayout { spacing: 1; Layout.fillWidth: true
                        Text { text: "record"; color: theme.text; font.pixelSize: 20; font.family: Tok.mono; font.bold: true }
                        Text {
                            text: root.wfAvail
                                  ? (root.captureLabel + " · " + (root.audio === "none" ? "no audio"
                                     : root.audio === "mic" ? "microphone"
                                     : root.audio === "system" ? "system audio" : "mic + system")
                                     + " · " + root.fps + "fps " + root.format)
                                  : "wf-recorder is not installed"
                            color: root.wfAvail ? theme.faint : theme.bad
                            font.pixelSize: 11; font.family: Tok.mono
                            Layout.fillWidth: true; elide: Text.ElideRight
                        }
                    }
                    IconBtn { icon: "refresh"; onTapped: root.probe() }
                    IconBtn { icon: "close"; onTapped: root.close() }
                }

                // ---- capture ----
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    Head { text: "CAPTURE" }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Seg { label: "region"; on: root.capture === "region"; onTapped: root.capture = "region" }
                        Seg { label: "this screen"; on: root.capture === "screen"; onTapped: root.capture = "screen" }
                        Repeater {
                            model: root.outputs
                            delegate: Seg {
                                required property var modelData
                                label: modelData.name + " · " + modelData.desc
                                on: root.capture === ("output:" + modelData.name)
                                onTapped: root.capture = "output:" + modelData.name
                            }
                        }
                    }
                }

                // ---- audio ----
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    Head { text: "AUDIO" }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Seg { label: "none";   on: root.audio === "none";   onTapped: root.audio = "none" }
                        Seg { label: "mic";    on: root.audio === "mic";    onTapped: root.audio = "mic" }
                        Seg { label: "system"; on: root.audio === "system"; onTapped: root.audio = "system" }
                        Seg { label: "mic + system"; on: root.audio === "both"; onTapped: root.audio = "both"
                              enabled: root.mics.length > 0 }
                    }

                    // Device pickers appear only for the sources actually being recorded.
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 6
                        visible: root.audio === "mic" || root.audio === "both"
                        Head { text: "MICROPHONE" }
                        Flow {
                            Layout.fillWidth: true; spacing: 6
                            Seg { label: root.micLabel.indexOf("Default") === 0 ? root.micLabel : "Default"
                                  maxW: 250; on: root.mic === ""; onTapped: root.mic = "" }
                            Repeater {
                                model: root.mics
                                delegate: Seg {
                                    required property var modelData
                                    label: root.labelFor(root.mics, modelData); maxW: 220
                                    on: root.mic === modelData.name
                                    onTapped: root.mic = modelData.name
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 6
                        visible: root.audio === "system" || root.audio === "both"
                        Head { text: "SYSTEM AUDIO — RECORDED FROM AN OUTPUT'S MONITOR" }
                        Flow {
                            Layout.fillWidth: true; spacing: 6
                            // "Default" is not just a shortcut: it re-reads the default sink at
                            // start, so recordings follow the DAC when it's plugged in.
                            Seg { label: root.sysLabel.indexOf("Default") === 0 ? root.sysLabel : "Default"
                                  maxW: 280; on: root.sys === ""; onTapped: root.sys = "" }
                            Repeater {
                                model: root.sinks
                                delegate: Seg {
                                    required property var modelData
                                    label: root.labelFor(root.sinks, modelData); maxW: 220
                                    on: root.sys === modelData.name
                                    onTapped: root.sys = modelData.name
                                }
                            }
                        }
                    }

                    // The one thing that silently produces a dead audio track.
                    Rectangle {
                        Layout.fillWidth: true; visible: root.exclusiveWarn
                        implicitHeight: exw.implicitHeight + 16; radius: Tok.r
                        color: theme.a(theme.warn, 0.14)
                        border.width: 1; border.color: theme.a(theme.warn, 0.4)
                        RowLayout {
                            id: exw
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Sym { text: "warning"; sz: 15; color: theme.warn }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: (root.exclusiveName || "A DAC") + " is playing bit-perfect, straight to ALSA. "
                                      + "That bypasses pipewire, so the monitor this records from will be silent. "
                                      + "Record the mic, or take the player out of exclusive mode."
                                color: theme.warn; font.pixelSize: 10; font.family: Tok.mono; lineHeight: 1.3
                            }
                        }
                    }
                }

                // ---- quality ----
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    Head { text: "QUALITY" }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Seg { label: "30 fps"; on: root.fps === 30; onTapped: root.fps = 30 }
                        Seg { label: "60 fps"; on: root.fps === 60; onTapped: root.fps = 60 }
                        Seg { label: "120 fps"; on: root.fps === 120; onTapped: root.fps = 120 }
                        Item { implicitWidth: 10; implicitHeight: 1 }
                        Seg { label: "mp4"; on: root.format === "mp4"; onTapped: root.format = "mp4" }
                        Seg { label: "mkv"; on: root.format === "mkv"; onTapped: root.format = "mkv" }
                        Seg { label: "webm"; on: root.format === "webm"; onTapped: root.format = "webm" }
                        Item { implicitWidth: 10; implicitHeight: 1 }
                        Seg { label: "cpu"; on: root.encoder === "sw"; onTapped: root.encoder = "sw" }
                        Seg { label: "gpu"; on: root.encoder === "hw"; onTapped: root.encoder = "hw"
                              enabled: root.hwAvail }
                    }
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        // mkv is the honest recommendation, not a preference: mp4 keeps its index
                        // at the end of the file, so a recording that dies with the machine is a
                        // write-off. mkv can be cut short and still plays.
                        text: root.format === "mp4"
                              ? "mp4 finalises its index on stop — a crash mid-recording loses the file. mkv survives that."
                              : root.format === "webm"
                              ? "webm/VP9 is the slowest to encode; on a long capture the CPU may not keep up."
                              : "mkv keeps every frame written so far, even if the recording never stops cleanly."
                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; lineHeight: 1.3
                    }
                }

                // ---- countdown ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Head { text: "COUNTDOWN"; Layout.rightMargin: 4 }
                    Seg { label: "off"; on: root.countdown === 0; onTapped: root.countdown = 0 }
                    Seg { label: "3s";  on: root.countdown === 3; onTapped: root.countdown = 3 }
                    Seg { label: "5s";  on: root.countdown === 5; onTapped: root.countdown = 5 }
                    Item { Layout.fillWidth: true }
                    Text {
                        // whatever the script will really use, not a hardcoded guess
                        text: root.dir !== "" ? root.dir : "~/Videos/Recordings"
                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                        elide: Text.ElideLeft; Layout.maximumWidth: 220
                    }
                }

                // ---- actions ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: root.capture === "region" ? "enter → drag a region" : "enter → record"
                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                    }
                    TextBtn { label: "cancel"; icon: "close"; onTapped: root.close() }
                    TextBtn { label: "record"; icon: "fiber_manual_record"; primary: true
                              enabled: root.wfAvail; onTapped: root.begin() }
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
            anchors.centerIn: parent
            width: 132; height: 132; radius: Tok.rCard
            color: theme.a(theme.bg, 0.86)
            border.width: 2; border.color: theme.a(theme.bad, 0.8)
            Text {
                anchors.centerIn: parent
                text: "" + root.ticking
                color: theme.text; font.pixelSize: 64; font.family: Tok.mono; font.bold: true
            }
            scale: root.ticking > 0 ? 1 : 0.8
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        }
    }
}
