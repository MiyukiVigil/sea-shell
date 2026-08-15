// sea-shell dashboard — industrial rework.
//
// WHAT CHANGED AND WHY:
//  · The old screen was three translucent rounded boxes in a fixed 740×580 centred block. It is
//    now a stack of labelled regions on hairlines, starting top-left, sized to the display.
//  · The "QUICK COMMANDS" grid was six identical tiles that fired blind `rfkill toggle` and
//    showed NO state — you could not tell whether Wi-Fi was on, and every tile called Qt.quit()
//    so the window vanished before you saw the result. Controls now poll real state, render it
//    in words, and stay open. Only genuinely navigational actions (lock, wallpaper) close.
//  · sea-sysmon.sh has always emitted six GPU fields; the dashboard parsed none of them. On this
//    machine the dGPU is the interesting number, so it now has its own region.
//  · Theme/tokens/appearance parsing moved to the Tok singleton — this file had its own drifting
//    copy of the colour ramp.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root

    // ---------------- system stats ----------------
    property var cpuHistory: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    property var ramHistory: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]

    property int    cpuPct: 0
    property int    cpuTemp: 0
    property string ramUsed: "0.0"
    property string ramTotal: "0.0"
    property int    ramPct: 0
    property string gpuName: ""
    property int    gpuUtil: 0
    property int    gpuTemp: 0
    property string gpuPower: "0.0"
    property string gpuVramUsed: "0.0"
    property string gpuVramTotal: "0.0"
    property string diskUsed: "—"
    property int    diskPct: 0
    property string loadAvg: "—"
    property string swapInfo: "—"

    // temperature bands — a number without a judgement is just a number
    function tempTone(c) { return c >= 88 ? "crit" : c >= 72 ? "warn" : "neutral" }
    function pctTone(p)  { return p >= 90 ? "crit" : p >= 75 ? "warn" : "neutral" }

    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!sysMonProc.running) sysMonProc.running = true }

    Process {
        id: sysMonProc
        // sea-sysmon.sh ends its line with \n, so appending straight after it GLUED the load
        // average onto the gpuVramTotal field and shifted every later index by one — the old
        // dashboard printed the disk string in its "Load average" slot for exactly this reason.
        // Strip the newline and separate every appended group with its own pipe.
        command: ["sh", "-c",
            "~/.config/quickshell/sea-shell/sea-sysmon.sh | tr -d '\\n';" +
            "printf '|';" +
            "awk '{printf \"%s %s %s\", $1, $2, $3}' /proc/loadavg;" +
            "printf '|';" +
            "df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,\"\",$5); printf \"%s / %s|%d\", $3, $2, $5}';" +
            "printf '|';" +
            "free -g | awk '/Swap/{printf \"%s / %s GiB\", $3, $2}'"]
        stdout: StdioCollector {
            id: sysOut
            onStreamFinished: {
                var txt = sysOut.text.trim();
                if (!txt) return;
                var p = txt.split("|");
                if (p.length < 14) return;
                root.cpuPct       = parseInt(p[0]) || 0;
                root.cpuTemp      = parseInt(p[1]) || 0;
                root.ramUsed      = p[2] || "0.0";
                root.ramTotal     = p[3] || "0.0";
                root.ramPct       = parseInt(p[4]) || 0;
                root.gpuName      = p[5] || "";
                root.gpuUtil      = parseInt(p[6]) || 0;
                root.gpuTemp      = parseInt(p[7]) || 0;
                root.gpuPower     = p[8] || "0.0";
                root.gpuVramUsed  = p[9] || "0.0";
                root.gpuVramTotal = p[10] || "0.0";
                root.loadAvg      = p[11] || "—";
                root.diskUsed     = p[12] || "—";
                root.diskPct      = parseInt(p[13]) || 0;
                root.swapInfo     = p[14] || "—";

                var c = root.cpuHistory.slice(1); c.push(root.cpuPct); root.cpuHistory = c;
                var m = root.ramHistory.slice(1); m.push(root.ramPct); root.ramHistory = m;
            }
        }
    }

    // ---------------- host identity ----------------
    property string hostName: ""
    property string upTime: ""
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!hostProc.running) hostProc.running = true }
    Process {
        id: hostProc
        command: ["sh","-c","printf '%s|%s' \"$(hostnamectl hostname 2>/dev/null || hostname)\" \"$(uptime -p 2>/dev/null | sed 's/^up //')\""]
        stdout: StdioCollector { id: hostOut; onStreamFinished: {
            var p = hostOut.text.trim().split("|");
            root.hostName = p[0] || ""; root.upTime = p[1] || "";
        } } }

    // ---------------- control state ----------------
    // One sampler for every toggle, so the row states can never disagree with each other the way
    // four independent blind `rfkill toggle` buttons did.
    property bool wifiOn: false
    property bool btOn: false
    property bool cafOn: false          // caffeine = screen kept awake
    property bool muted: false

    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!stateProc.running) stateProc.running = true }
    Process {
        id: stateProc
        command: ["sh","-c",
            "printf '%s|%s|%s|%s' " +
            "\"$(nmcli radio wifi 2>/dev/null)\" " +
            "\"$(rfkill list bluetooth 2>/dev/null | awk '/Soft blocked/{print $3; exit}')\" " +
            "\"$(cat ~/.config/sea-shell/caffeine 2>/dev/null || echo 0)\" " +
            "\"$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)\""]
        stdout: StdioCollector { id: stOut; onStreamFinished: {
            var p = stOut.text.split("|");
            root.wifiOn = (p[0] || "").trim() === "enabled";
            root.btOn   = (p[1] || "").trim() === "no";        // soft-blocked:no → radio is up
            root.cafOn  = (p[2] || "").trim() === "1";
            root.muted  = (p[3] || "").indexOf("[MUTED]") >= 0;
        } } }
    function poke() { if (!stateProc.running) stateProc.running = true }
    // controls act, then re-sample rather than assuming — an nmcli/rfkill call can be refused
    Timer { id: settle; interval: 700; repeat: false; onTriggered: root.poke() }
    function act(cmd) { Quickshell.execDetached(["sh","-c",cmd]); settle.restart() }

    function setWifi(on)  { root.act("nmcli radio wifi " + (on ? "on" : "off")) }
    function setBt(on)    { root.act("rfkill " + (on ? "unblock" : "block") + " bluetooth") }
    function setMute(m)   { root.act("wpctl set-mute @DEFAULT_AUDIO_SINK@ " + (m ? "1" : "0")) }
    // caffeine mirrors shell.qml's sticky contract: persist the DESIRED state, then enforce it,
    // so the bar pill and this row can't drift apart.
    function setCaf(on) {
        root.act("mkdir -p ~/.config/sea-shell && echo " + (on ? "1" : "0") + " > ~/.config/sea-shell/caffeine && " +
                 (on ? "pkill -x hypridle" : "hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"") + " || true");
    }

    // ---------------- processes ----------------
    // Data belongs in a table. This is also the answer to the question the KPI row raises —
    // "CPU is at 31%, doing what?" — which the old dashboard could not answer at all.
    property var procList: []
    Timer { interval: 4000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!procProc.running) procProc.running = true }
    Process {
        id: procProc
        command: ["sh","-c","ps -eo comm=,pcpu=,pmem=,rss= --sort=-pcpu 2>/dev/null | head -9"]
        stdout: StdioCollector { id: procOut; onStreamFinished: {
            var out = [], lines = procOut.text.trim().split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].trim().split(/\s+/);
                if (f.length < 4) continue;
                var cpu = parseFloat(f[1]) || 0;
                out.push({
                    name: f[0], cpu: f[1], mem: f[2],
                    rss: Math.round(parseInt(f[3]) / 1024),
                    _tone: cpu >= 50 ? "crit" : cpu >= 15 ? "warn" : "neutral"
                });
            }
            root.procList = out;
        } } }

    // ---------------- app usage ----------------
    // The bar process owns the measuring (it is the one watching focus + idle); the dashboard is
    // a SEPARATE process, so it reads the file rather than sharing state. Re-read on every open
    // so it is never showing a snapshot from the last time the dashboard was up.
    property var usageAll: ({})
    property string usageDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    Process { id: usageProc; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage.json\" 2>/dev/null"]
        stdout: StdioCollector { id: usageOut; onStreamFinished: {
            try { var t = usageOut.text.trim(); if (t) root.usageAll = JSON.parse(t) || ({}); } catch (e) {}
        } } }
    Timer { interval: 30000; repeat: true; running: true; onTriggered: usageProc.running = true }

    function usageFmt(s) {
        s = Math.round(s);
        if (s < 60) return s + "s";
        var m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        return Math.floor(m / 60) + "h " + (m % 60) + "m";
    }
    readonly property real usageTotal: {
        var day = root.usageAll[root.usageDate] || ({}), t = 0;
        for (var k in day) t += day[k];
        return t;
    }
    readonly property var usageRows: {
        var day = root.usageAll[root.usageDate] || ({}), arr = [];
        for (var k in day) arr.push({ _k: k, _s: day[k] });
        arr.sort(function (a, b) { return b._s - a._s });
        var tot = root.usageTotal, out = [];
        for (var i = 0; i < arr.length; i++) {
            out.push({ app: arr[i]._k,
                       time: root.usageFmt(arr[i]._s),
                       pct: tot > 0 ? (Math.round(arr[i]._s / tot * 100) + "%") : "—" });
        }
        return out;
    }

    // ---------------- tasks ----------------
    property var todoList: []
    Component.onCompleted: loadTodoProc.running = true
    Process {
        id: loadTodoProc
        command: ["sh", "-c", "cat ~/.config/sea-shell/todo.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: todoOut; onStreamFinished: {
            try { root.todoList = JSON.parse(todoOut.text) } catch(e) { root.todoList = [] }
        } } }
    function saveTodo() {
        var b64 = Qt.btoa(JSON.stringify(root.todoList));
        Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && echo '" + b64 + "' | base64 -d > ~/.config/sea-shell/todo.json"]);
    }
    function addTodo(txt) {
        if (!txt.trim()) return;
        var l = root.todoList.slice(); l.push({ text: txt.trim(), done: false });
        root.todoList = l; saveTodo();
    }
    function toggleTodo(i) { var l = root.todoList.slice(); l[i].done = !l[i].done; root.todoList = l; saveTodo() }
    function removeTodo(i) { var l = root.todoList.slice(); l.splice(i, 1); root.todoList = l; saveTodo() }
    readonly property int todoOpen: {
        var n = 0;
        for (var i = 0; i < root.todoList.length; i++) if (!root.todoList[i].done) n++;
        return n;
    }

    // Material Symbols glyph
    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink3
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // a control row: name on the left, state IN WORDS, then the switch
    component CtlRow: Item {
        id: cr
        property string label: ""
        property string icon: ""
        property bool   on: false
        property string onText: "ON"
        property string offText: "OFF"
        property string tone: "ok"
        signal requested(bool value)
        implicitHeight: 38
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Tok.s1
            anchors.rightMargin: Tok.s1
            spacing: Tok.s3
            Sym { text: cr.icon; sz: 17; color: cr.on ? Tok.accent : Tok.ink3 }
            IndText { text: cr.label; sz: Tok.tBody; color: Tok.ink; Layout.fillWidth: true }
            IndChip { text: cr.on ? cr.onText : cr.offText; tone: cr.on ? cr.tone : "neutral" }
            IndToggle { on: cr.on; onToggled: (v) => cr.requested(v) }
        }
        IndRule { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right }
    }

    PanelWindow {
        id: dWin
        readonly property real ui: Tok.uiFor(dWin.screen)
        visible: true
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:dashboard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        onVisibleChanged: if (visible) tdIn.input.forceActiveFocus()
        Binding { target: dWin.contentItem; property: "scale"; value: dWin.ui }

        // opaque ground — no frost, no blur
        Rectangle {
            anchors.fill: parent
            color: Tok.bg
            opacity: Tok.loaded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

            FocusScope {
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: Qt.quit()

                // content starts top-left, not in a centred hero block
                Item {
                    id: stage
                    anchors.fill: parent
                    anchors.margins: Tok.s8
                    // swallow clicks so the scrim's close handler doesn't fire through the content
                    MouseArea { anchors.fill: parent }

                    // ---------- header ----------
                    RowLayout {
                        id: header
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        spacing: Tok.s4

                        IndText {
                            id: clock
                            property string t: Qt.formatDateTime(new Date(), "HH:mm")
                            mono: true; sz: Tok.tHero; text: t; color: Tok.ink; font.weight: 500
                            Timer { interval: 1000; running: true; repeat: true
                                onTriggered: clock.t = Qt.formatDateTime(new Date(), "HH:mm") }
                        }
                        ColumnLayout {
                            spacing: 1
                            Layout.bottomMargin: 3
                            Layout.alignment: Qt.AlignBottom
                            IndText {
                                id: dateLbl
                                property string d: Qt.formatDateTime(new Date(), "dddd, d MMMM yyyy")
                                text: d; sz: Tok.tDense; color: Tok.ink2
                                Timer { interval: 60000; running: true; repeat: true
                                    onTriggered: dateLbl.d = Qt.formatDateTime(new Date(), "dddd, d MMMM yyyy") }
                            }
                            IndText {
                                mono: true; sz: Tok.tData; color: Tok.ink3
                                text: root.hostName + (root.upTime ? "  ·  up " + root.upTime : "")
                            }
                        }
                        Item { Layout.fillWidth: true }
                        IndBtn { text: "Close"; rank: "ghost"; kbd: "ESC"; onActivated: Qt.quit() }
                    }
                    IndRule {
                        id: headRule; hard: true
                        anchors { top: header.bottom; topMargin: Tok.s4; left: parent.left; right: parent.right }
                    }

                    // ---------- two columns ----------
                    RowLayout {
                        anchors { top: headRule.bottom; topMargin: Tok.s6; left: parent.left
                                  right: parent.right; bottom: parent.bottom }
                        spacing: Tok.s12

                        // ===== left: machine =====
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 3
                            spacing: Tok.s6

                            IndPanel {
                                title: "System"
                                note: root.loadAvg !== "—" ? "load " + root.loadAvg : ""
                                Layout.fillWidth: true

                                // KPI row — one figure leads, hairline verticals between
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s6
                                    IndKpi {
                                        label: "CPU"; value: "" + root.cpuPct; unit: "%"
                                        size: Tok.tHero; tone: root.pctTone(root.cpuPct)
                                        sub: root.cpuTemp > 0 ? root.cpuTemp + " °C" : ""
                                    }
                                    IndRule { Layout.fillHeight: true; implicitWidth: 1; Layout.preferredWidth: 1 }
                                    IndKpi {
                                        label: "Memory"; value: root.ramUsed; unit: "GiB"
                                        tone: root.pctTone(root.ramPct)
                                        sub: "of " + root.ramTotal + "  ·  " + root.ramPct + "%"
                                    }
                                    IndRule { Layout.fillHeight: true; implicitWidth: 1; Layout.preferredWidth: 1 }
                                    IndKpi {
                                        label: "Disk"; value: "" + root.diskPct; unit: "%"
                                        tone: root.pctTone(root.diskPct); sub: root.diskUsed
                                    }
                                    IndRule { Layout.fillHeight: true; implicitWidth: 1; Layout.preferredWidth: 1 }
                                    IndKpi { label: "Swap"; value: root.swapInfo; size: Tok.tPanel }
                                    Item { Layout.fillWidth: true }
                                }

                                // traces
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Tok.s3
                                    spacing: Tok.s4
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: Tok.s1
                                        IndLabel { text: "CPU · 60s" }
                                        IndSpark { values: root.cpuHistory; stroke: Tok.accent
                                            Layout.fillWidth: true; Layout.preferredHeight: 40 }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: Tok.s1
                                        IndLabel { text: "Memory · 60s" }
                                        IndSpark { values: root.ramHistory; stroke: Tok.ink2
                                            Layout.fillWidth: true; Layout.preferredHeight: 40 }
                                    }
                                }
                            }

                            IndPanel {
                                title: "Graphics"
                                note: root.gpuName
                                visible: root.gpuName !== ""
                                Layout.fillWidth: true
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s6
                                    IndKpi { label: "Utilisation"; value: "" + root.gpuUtil; unit: "%"
                                        size: Tok.tKpi; tone: root.pctTone(root.gpuUtil) }
                                    IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
                                    IndKpi { label: "Temp"; value: "" + root.gpuTemp; unit: "°C"
                                        size: Tok.tKpi; tone: root.tempTone(root.gpuTemp) }
                                    IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
                                    IndKpi { label: "Power"; value: root.gpuPower; unit: "W"; size: Tok.tKpi }
                                    IndRule { Layout.fillHeight: true; Layout.preferredWidth: 1 }
                                    IndKpi {
                                        label: "VRAM"; value: root.gpuVramUsed; unit: "GB"; size: Tok.tKpi
                                        sub: "of " + root.gpuVramTotal
                                        tone: root.pctTone(parseFloat(root.gpuVramTotal) > 0
                                            ? (parseFloat(root.gpuVramUsed) / parseFloat(root.gpuVramTotal)) * 100 : 0)
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                            }

                            IndPanel {
                                title: "Processes"
                                note: "top 8 by cpu"
                                Layout.fillWidth: true

                                IndTable {
                                    Layout.fillWidth: true
                                    rowHeight: 26
                                    rows: root.procList
                                    columns: [
                                        { label: "Command", key: "name", flex: true },
                                        { label: "CPU %",   key: "cpu",  w: 60, num: true },
                                        { label: "MEM %",   key: "mem",  w: 60, num: true },
                                        { label: "RSS MB",  key: "rss",  w: 72, num: true }
                                    ]
                                }
                            }

                            IndPanel {
                                title: "App usage"
                                note: root.usageRows.length > 0
                                      ? ("today · " + root.usageFmt(root.usageTotal) + " active")
                                      : "today"
                                Layout.fillWidth: true

                                IndTable {
                                    Layout.fillWidth: true
                                    rowHeight: 26
                                    rows: root.usageRows
                                    maxRows: 8
                                    emptyText: "nothing recorded yet today"
                                    columns: [
                                        { label: "App",   key: "app",  flex: true, mono: true },
                                        { label: "Time",  key: "time", w: 76, num: true },
                                        { label: "Share", key: "pct",  w: 62, num: true }
                                    ]
                                }
                                IndText {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Tok.s1
                                    mono: true; sz: Tok.tData; color: Tok.ink3
                                    wrapMode: Text.WordWrap
                                    text: "focus time, paused while the session is idle. the bar writes this once a minute."
                                }
                            }

                            Item { Layout.fillHeight: true }
                        }

                        // ===== right: controls + tasks =====
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 2
                            spacing: Tok.s6

                            IndPanel {
                                title: "Controls"
                                Layout.fillWidth: true
                                CtlRow { Layout.fillWidth: true; label: "Wi-Fi"; icon: "wifi"
                                    on: root.wifiOn; onRequested: (v) => root.setWifi(v) }
                                CtlRow { Layout.fillWidth: true; label: "Bluetooth"; icon: "bluetooth"
                                    on: root.btOn; onRequested: (v) => root.setBt(v) }
                                CtlRow { Layout.fillWidth: true; label: "Caffeine"; icon: "coffee"
                                    on: root.cafOn; onText: "AWAKE"; offText: "NORMAL"; tone: "warn"
                                    onRequested: (v) => root.setCaf(v) }
                                CtlRow { Layout.fillWidth: true; label: "Audio"; icon: "volume_up"
                                    on: !root.muted; onText: "LIVE"; offText: "MUTED"
                                    onRequested: (v) => root.setMute(!v) }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Tok.s3
                                    spacing: Tok.s2
                                    IndBtn { text: "Lock session"; rank: "secondary"
                                        onActivated: { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-lock.sh"]); Qt.quit() } }
                                    IndBtn { text: "Wallpaper"; rank: "secondary"
                                        onActivated: { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"]); Qt.quit() } }
                                    Item { Layout.fillWidth: true }
                                }
                            }

                            IndPanel {
                                title: "Tasks"
                                note: root.todoList.length
                                      ? root.todoOpen + " open / " + root.todoList.length
                                      : ""
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                // Entry sits directly under the rule: the action comes first, the
                                // data it produces below. Pinned to the panel bottom it ended up
                                // stranded at the foot of the screen whenever the list was short.
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.bottomMargin: Tok.s2
                                    spacing: Tok.s2
                                    IndField {
                                        id: tdIn
                                        Layout.fillWidth: true
                                        placeholder: "New task"
                                        onAccepted: (v) => { root.addTodo(v); text = "" }
                                    }
                                    IndBtn { text: "Add"; rank: "primary"
                                        onActivated: { root.addTodo(tdIn.text); tdIn.text = "" } }
                                }

                                ListView {
                                    id: todoLv
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    model: root.todoList
                                    boundsBehavior: Flickable.StopAtBounds
                                    delegate: Item {
                                        required property var modelData
                                        required property int index
                                        width: todoLv.width
                                        height: 34
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: Tok.s1
                                            anchors.rightMargin: Tok.s1
                                            spacing: Tok.s3
                                            Rectangle {
                                                implicitWidth: 15; implicitHeight: 15; radius: Tok.rSmall
                                                color: modelData.done ? Tok.accent : "transparent"
                                                border.width: 1
                                                border.color: modelData.done ? Tok.accent : Tok.ruleHard
                                                Sym { anchors.centerIn: parent; text: "check"; sz: 11
                                                    color: Tok.accentInk; visible: modelData.done }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.toggleTodo(index) }
                                            }
                                            IndText {
                                                text: modelData.text
                                                sz: Tok.tDense
                                                color: modelData.done ? Tok.ink3 : Tok.ink
                                                font.strikeout: modelData.done
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Sym {
                                                text: "close"; sz: 14
                                                color: delMa.containsMouse ? Tok.crit : Tok.ink3
                                                MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor; onClicked: root.removeTodo(index) }
                                            }
                                        }
                                        IndRule { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right }
                                    }
                                }

                                IndText {
                                    visible: root.todoList.length === 0
                                    text: "—"
                                    mono: true
                                    color: Tok.ink3
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
