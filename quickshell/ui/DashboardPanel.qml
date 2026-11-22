// sea-shell dashboard (SUPER+D).
//
// KEPT IN THE SHELL. It used to be its own `qs -p` process, started on every press: ~125 ms
// for Quickshell to come up, ~115 ms more to build this file, then a fresh window to map, all
// before the first frame. shell.qml now loads it on demand and cools it after close.
// Dashboard.qml is the stand-alone copy for when the shell is not running.
//
// DRESSED IN SEA-SHELL'S OWN LANGUAGE:
//  · Elevated Tok.surface cards over a Tok.bg sheet with hairline Tok.rule borders and subtle
//    top highlights, reading cleanly in both light and dark themes.
//  · Unified segmented tab switcher (Overview · Gaming · Dev) in the header.
//  · Color-coordinated KPI ring gauges matching the live telemetry traces underneath.
//  · Interactive Processes table (sort by CPU or Memory), structured 3-column Graphics strip
//    with inline VRAM meter, refined Control Center tiles, concise Today breakdown, and a
//    proper rounded task input with a centered empty state.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts

Scope {
    id: root
    property bool shown: false
    property int dashTab: 0   // 0 = overview · 1 = gaming · 2 = dev
    property var github: ({})
    property var githubData: ({ ok: false })
    readonly property string githubScript: Qt.resolvedUrl("sea-github.py").toString().replace("file://", "")
    // Bound from shell.qml so the Dev tab can show the same AI meters as the bar.
    property var aiTools: []
    property var aiShown: null
    property string aiBarValue: ""
    // The bar's idea of the game being played, which also knows Wine windows from Lutris,
    // Heroic and Twintail by their process.
    property string liveGameId: ""
    property var player: null
    property string powerProfile: "balanced"
    property real netRx: 0
    property real netTx: 0
    property int batPct: -1
    property bool batCharging: false
    property real batRate: 0
    property string batEta: ""
    signal focusAi(string id)
    signal setPowerProfile(string profile)
    signal closed()

    function netFmt(b) {
        b = Number(b) || 0;
        if (b < 1024) return "0 KB/s";
        if (b < 1048576) return Math.round(b / 1024) + " KB/s";
        return (b / 1048576).toFixed(1) + " MB/s";
    }
    function applyPowerProfile(p) {
        root.powerProfile = p;
        root.setPowerProfile(p);
        Quickshell.execDetached(["powerprofilesctl", "set", p]);
    }

    property bool screensMoved: false
    Connections { target: Quickshell; function onScreensChanged() { root.screensMoved = true } }
    function placeOn(w) {
        var f = Hyprland.focusedMonitor, s = Quickshell.screens, t = null;
        for (var i = 0; f && i < s.length; i++) if (s[i].name === f.name) t = s[i];
        if (!t && s.length) t = s[0];
        if (t && w.visible && (t !== w.screen || root.screensMoved || !w.backingWindowVisible)) {
            w.visible = false;
            w.screen = t;
            w.visible = Qt.binding(function() { return dWin.live; });
        } else if (t) w.screen = t;
        root.screensMoved = false;
    }
    function open(tab) {
        root.placeOn(dWin);
        if (tab === "gaming" || tab === 1) root.dashTab = 1;
        else if (tab === "dev" || tab === 2) root.dashTab = 2;
        else if (tab === "overview" || tab === 0) root.dashTab = 0;
        usageProc.running = true; loadTodoProc.running = true;
        root.shown = true;
        if (root.dashTab === 1 || !gamingHub.loaded) gamingHub.refresh();
        if (root.dashTab === 2) ghProc.running = true;
        if (root.dashTab === 0) tdIn.forceActiveFocus();
        root.checkTodoReminders();
    }
    onGithubChanged: {
        if (github && Object.keys(github).length)
            root.githubData = github;
    }
    Component.onCompleted: { sysMonProc.running = true; usageProc.running = true }
    function close() { if (!root.shown) return; root.shown = false; closedTimer.restart() }
    function toggle() { if (root.shown) root.close(); else root.open() }
    Timer { id: closedTimer; interval: Tok.reducedMotion ? 0 : 130; onTriggered: root.closed() }

    // ---------------- system stats ----------------
    readonly property int historyLen: 30
    property var cpuHistory: []
    property var ramHistory: []

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

    function tempTone(c) { return c >= 88 ? "crit" : c >= 72 ? "warn" : "neutral" }
    function pctTone(p)  { return p >= 90 ? "crit" : p >= 75 ? "warn" : "neutral" }

    Timer { interval: 2000; running: root.shown; repeat: true; triggeredOnStart: true
        onTriggered: if (!sysMonProc.running) sysMonProc.running = true }

    Process {
        id: sysMonProc
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

                root.cpuHistory = root.cpuHistory.concat([root.cpuPct]).slice(-root.historyLen);
                root.ramHistory = root.ramHistory.concat([root.ramPct]).slice(-root.historyLen);
            }
        }
    }

    // ---------------- host identity ----------------
    property string hostName: ""
    property string upTime: ""
    Timer { interval: 60000; running: root.shown; repeat: true; triggeredOnStart: true
        onTriggered: if (!hostProc.running) hostProc.running = true }
    Process {
        id: hostProc
        command: ["sh","-c","printf '%s|%s' \"$(hostnamectl hostname 2>/dev/null || hostname)\" \"$(uptime -p 2>/dev/null | sed 's/^up //')\""]
        stdout: StdioCollector { id: hostOut; onStreamFinished: {
            var p = hostOut.text.trim().split("|");
            root.hostName = p[0] || ""; root.upTime = p[1] || "";
        } } }

    // ---------------- control state ----------------
    property bool wifiOn: false
    property bool btOn: false
    property bool cafOn: false
    property bool muted: false

    Timer { interval: 3000; running: root.shown; repeat: true; triggeredOnStart: true
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
            root.btOn   = (p[1] || "").trim() === "no";
            root.cafOn  = (p[2] || "").trim() === "1";
            root.muted  = (p[3] || "").indexOf("[MUTED]") >= 0;
        } } }
    function poke() { if (!stateProc.running) stateProc.running = true }
    Timer { id: settle; interval: 700; repeat: false; onTriggered: root.poke() }
    function act(cmd) { Quickshell.execDetached(["sh","-c",cmd]); settle.restart() }

    function setWifi(on)  { root.act("nmcli radio wifi " + (on ? "on" : "off")) }
    function setBt(on)    { root.act("rfkill " + (on ? "unblock" : "block") + " bluetooth") }
    function setMute(m)   { root.act("wpctl set-mute @DEFAULT_AUDIO_SINK@ " + (m ? "1" : "0")) }
    function setCaf(on) {
        root.act("mkdir -p ~/.config/sea-shell && echo " + (on ? "1" : "0") + " > ~/.config/sea-shell/caffeine && " +
                 (on ? "pkill -x hypridle" : "hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"") + " || true");
    }

    // ---------------- processes ----------------
    property string procSort: "cpu"       // "cpu" | "mem"
    property var procList: []
    property int armedKillPid: -1
    Timer { id: killArmTimer; interval: 2600; onTriggered: root.armedKillPid = -1 }
    function focusProcess(pid, name) {
        var tops = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        var low = ("" + (name || "")).toLowerCase();
        for (var i = 0; i < tops.length; i++) {
            var o = tops[i] ? tops[i].lastIpcObject : null;
            if (!o || !o.address) continue;
            if ((pid > 0 && o.pid === pid) || (low !== "" && ("" + (o["class"] || "")).toLowerCase().indexOf(low) >= 0)) {
                Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + o.address + "' })");
                root.close();
                return;
            }
        }
    }
    function endProcess(pid) {
        if (!(pid > 1)) return;
        if (root.armedKillPid === pid) {
            root.armedKillPid = -1;
            killArmTimer.stop();
            Quickshell.execDetached(["kill", "-TERM", String(pid)]);
            procRefreshSoon.restart();
        } else {
            root.armedKillPid = pid;
            killArmTimer.restart();
        }
    }
    Timer { id: procRefreshSoon; interval: 600; onTriggered: { procProc.running = false; procProc.running = true } }
    readonly property real procPeak: {
        var m = root.procSort === "mem" ? 128 : 25;
        for (var i = 0; i < root.procList.length; i++) {
            var v = root.procSort === "mem" ? (root.procList[i].rss || 0) : (parseFloat(root.procList[i].cpu) || 0);
            if (v > m) m = v;
        }
        return m;
    }
    onProcSortChanged: {
        if (!root.shown) return;
        procProc.running = false;
        procProc.running = true;
    }
    Timer { interval: 4000; running: root.shown; repeat: true; triggeredOnStart: true
        onTriggered: if (!procProc.running) procProc.running = true }
    Process {
        id: procProc
        command: ["sh", "-c", "ps -eo pid=,pcpu=,pmem=,rss=,comm= --sort=" + (root.procSort === "mem" ? "-rss" : "-pcpu") + " 2>/dev/null | head -9"]
        stdout: StdioCollector { id: procOut; onStreamFinished: {
            var out = [], lines = procOut.text.trim().split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].trim().split(/\s+/);
                if (f.length < 5) continue;
                var pid = parseInt(f[0]) || 0;
                var cpu = parseFloat(f[1]) || 0;
                var mem = parseFloat(f[2]) || 0;
                var rss = Math.round(parseInt(f[3]) / 1024);
                out.push({
                    pid: pid, name: f.slice(4).join(" "), cpu: f[1], mem: f[2], rss: rss,
                    _tone: root.procSort === "mem"
                        ? (mem >= 25 ? "crit" : mem >= 12 ? "warn" : "neutral")
                        : (cpu >= 50 ? "crit" : cpu >= 15 ? "warn" : "neutral")
                });
            }
            root.procList = out;
        } } }

    // ---------------- app usage ----------------
    property var usageAll: ({})
    property string usageDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    Process { id: usageProc
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/usage.json\" 2>/dev/null"]
        stdout: StdioCollector { id: usageOut; onStreamFinished: {
            try { var t = usageOut.text.trim(); if (t) root.usageAll = JSON.parse(t) || ({}); } catch (e) {}
        } } }
    Timer { interval: 30000; repeat: true; running: root.shown; onTriggered: usageProc.running = true }

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

    Process {
        id: ghProc
        command: ["python3", root.githubScript, "--cache-ok"]
        stdout: StdioCollector { id: ghOut; onStreamFinished: {
            try {
                var t = ghOut.text.trim();
                if (t) root.githubData = JSON.parse(t) || ({ ok: false });
            } catch (e) {}
        } } }

    // ---------------- tasks ----------------
    property var todoList: []
    property var todoReminded: ({})
    Process {
        id: loadTodoProc
        command: ["sh", "-c", "cat ~/.config/sea-shell/todo.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: todoOut; onStreamFinished: {
            try {
                var raw = JSON.parse(todoOut.text) || [];
                for (var i = 0; i < raw.length; i++) {
                    if (!raw[i].due) raw[i].due = "";
                }
                root.todoList = raw;
            } catch(e) { root.todoList = [] }
            if (root.shown) root.checkTodoReminders();
        } } }
    function saveTodo() {
        var b64 = Qt.btoa(JSON.stringify(root.todoList));
        Quickshell.execDetached(["sh","-c","mkdir -p ~/.config/sea-shell && echo '" + b64 + "' | base64 -d > ~/.config/sea-shell/todo.json"]);
    }
    function parseTodoInput(raw) {
        var text = ("" + raw).trim(), due = "";
        var m = text.match(/ @(\d{4}-\d{2}-\d{2})\s*$/);
        if (m) { due = m[1]; text = text.slice(0, m.index).trim(); }
        else {
            m = text.match(/\bdue:(\d{4}-\d{2}-\d{2})\b/i);
            if (m) {
                due = m[1];
                text = text.replace(/\bdue:\d{4}-\d{2}-\d{2}\b/i, "").replace(/\s+/g, " ").trim();
            }
        }
        return { text: text, due: due };
    }
    function addTodo(txt) {
        var p = root.parseTodoInput(txt);
        if (!p.text) return;
        var l = root.todoList.slice();
        l.push({ text: p.text, done: false, due: p.due || "" });
        root.todoList = l; saveTodo();
    }
    function checkTodoReminders() {
        var today = Qt.formatDate(new Date(), "yyyy-MM-dd");
        for (var i = 0; i < root.todoList.length; i++) {
            var t = root.todoList[i];
            if (t.done || !t.due || t.due !== today) continue;
            var key = t.text + "|" + t.due;
            if (root.todoReminded[key]) continue;
            var m = root.todoReminded; m[key] = 1; root.todoReminded = m;
            Quickshell.execDetached(["notify-send", "Task due today", t.text]);
        }
    }
    readonly property var todoDisplay: {
        var arr = [];
        for (var i = 0; i < root.todoList.length; i++)
            arr.push(Object.assign({}, root.todoList[i], { _i: i }));
        arr.sort(function (a, b) {
            if (a.done !== b.done) return a.done ? 1 : -1;
            if (!a.done && !b.done) {
                var ad = a.due || "", bd = b.due || "";
                if (ad && !bd) return -1;
                if (!ad && bd) return 1;
                if (ad && bd && ad !== bd) return ad.localeCompare(bd);
            }
            return a._i - b._i;
        });
        return arr;
    }
    function toggleTodo(i) { var l = root.todoList.slice(); l[i].done = !l[i].done; root.todoList = l; saveTodo() }
    function removeTodo(i) { var l = root.todoList.slice(); l.splice(i, 1); root.todoList = l; saveTodo() }
    readonly property int todoOpen: {
        var n = 0;
        for (var i = 0; i < root.todoList.length; i++) if (!root.todoList[i].done) n++;
        return n;
    }

    // ---------------- sea-shell surface & palette tokens ----------------
    // Elevated Tok.surface cards over Tok.bg give crisp figure/ground separation in both
    // light and dark themes (instead of darker grey slabs recessed into a pale sheet).
    readonly property color cardFill:  Tok.surface
    readonly property color cardEdge:  Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color cardSheen: Tok.light ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(1, 1, 1, 0.045)
    readonly property color wellFill:  Tok.alpha(Tok.ink, Tok.light ? 0.032 : 0.055)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)
    readonly property color track:     Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property real  cardRad:   Math.min(18, Tok.r + 4)

    readonly property color memColor:  root.tileColor(0.28)
    readonly property color diskColor: root.tileColor(-0.14)
    readonly property color gpuColor:  root.tileColor(0.14)
    function tileColor(turn) {
        var h = ((Tok._h + turn) % 1 + 1) % 1;
        return Qt.hsla(h, Tok._achromatic ? 0 : 0.48, Tok.light ? 0.44 : 0.62, 1);
    }
    function toneColor(t, fallback) {
        if (t === "crit") return Tok.crit;
        if (t === "warn") return Tok.warn;
        return fallback !== undefined ? fallback : Tok.accent;
    }
    readonly property real vramPct: parseFloat(root.gpuVramTotal) > 0
        ? parseFloat(root.gpuVramUsed) / parseFloat(root.gpuVramTotal) * 100 : 0

    SurfaceMotion { id: motion; opened: Tok.loaded && root.shown; reduced: Tok.reducedMotion
        enterDuration: 180; exitDuration: 110 }

    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // Elevated card group: clean title row above, crisp Tok.surface card below.
    // Supports an optional right-side header slot (e.g., interactive sort toggle) or plain note.
    component Group: ColumnLayout {
        id: grp
        property string title: ""
        property string note: ""
        property bool notePill: false
        property bool fill: false
        property alias headerExtra: extraSlot.data
        default property alias content: body.data
        Layout.fillWidth: true
        Layout.fillHeight: grp.fill
        spacing: Tok.s2

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 2
            Layout.rightMargin: 2
            spacing: Tok.s2
            IndText { text: grp.title; sz: Tok.tDense; font.weight: Font.DemiBold; color: Tok.ink }
            Item { Layout.fillWidth: true }
            Row { id: extraSlot; spacing: Tok.s1 }
            Rectangle {
                visible: grp.note !== "" && grp.notePill
                implicitWidth: pillNoteTxt.implicitWidth + 14
                implicitHeight: 22
                radius: 11
                color: Tok.sunken
                border.width: 1
                border.color: root.cardEdge
                IndText { id: pillNoteTxt; anchors.centerIn: parent; text: grp.note; sz: Tok.tLabel; mono: true; color: Tok.ink2 }
            }
            IndText {
                visible: grp.note !== "" && !grp.notePill
                text: grp.note; sz: Tok.tData; color: Tok.ink3
                font.features: ({ "tnum": 1 })
            }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: grp.fill
            implicitHeight: body.implicitHeight + Tok.s4 * 2
            radius: root.cardRad
            color: root.cardFill
            border.width: 1
            border.color: root.cardEdge
            clip: grp.fill

            // subtle top rim sheen for tactile sea-shell elevation
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: root.cardRad * 0.5; rightMargin: root.cardRad * 0.5 }
                height: 1
                color: root.cardSheen
            }

            ColumnLayout {
                id: body
                anchors.fill: parent
                anchors.margins: Tok.s4
                spacing: Tok.s2
            }
        }
    }

    // Three-quarter ring gauge: color-coordinated with telemetry traces and crisp tabular figures.
    component Ring: ColumnLayout {
        id: rg
        property real amount: 0
        property string label: ""
        property string value: Math.round(rg.shown) + "%"
        property string sub: ""
        property string tone: "neutral"
        property color baseColor: Tok.accent
        property real shown: amount
        Behavior on shown { NumberAnimation { duration: Tok.reducedMotion ? 0 : 600; easing.type: Easing.OutCubic } }
        Layout.fillWidth: true
        spacing: 4

        Canvas {
            id: rcv
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: 102
            implicitHeight: 102
            readonly property color fg: root.toneColor(rg.tone, rg.baseColor)
            onFgChanged: requestPaint()
            Connections { target: rg; function onShownChanged() { rcv.requestPaint() } }
            Connections { target: Tok; function onChanged() { rcv.requestPaint() } }
            onPaint: {
                var c = getContext("2d"), t = 8, r = width / 2 - t / 2 - 2, cx = width / 2, cy = height / 2;
                var start = Math.PI * 0.75, sweep = Math.PI * 1.5;
                c.clearRect(0, 0, width, height);
                c.lineWidth = t; c.lineCap = "round";
                c.beginPath(); c.arc(cx, cy, r, start, start + sweep); c.strokeStyle = root.track; c.stroke();
                var a = Math.max(0, Math.min(100, rg.shown));
                if (a > 0.5) {
                    c.beginPath(); c.arc(cx, cy, r, start, start + sweep * a / 100);
                    c.strokeStyle = rcv.fg; c.stroke();
                }
            }
            IndText {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -4
                text: rg.value; sz: 20; font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
                color: rg.tone === "neutral" ? Tok.ink : root.toneColor(rg.tone, rg.baseColor)
            }
            IndText {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4
                text: rg.label; sz: Tok.tData; color: Tok.ink2; font.weight: Font.DemiBold
            }
        }
        IndText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: rg.sub; sz: Tok.tLabel; color: Tok.ink3
            font.features: ({ "tnum": 1 })
            opacity: rg.sub !== "" ? 1 : 0
        }
    }

    // Live 0–100% telemetry chart with soft area wash, scale lines, and terminal dots.
    component Trace: Canvas {
        id: tr
        property var series: []          // [{ values: [...], color: c }]
        onSeriesChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: Tok; function onChanged() { tr.requestPaint() } }
        onPaint: {
            var c = getContext("2d");
            c.clearRect(0, 0, width, height);
            var padT = 8, padB = 6, h = Math.max(1, height - padT - padB);
            c.lineWidth = 1;
            c.strokeStyle = Tok.alpha(Tok.ink, Tok.light ? 0.06 : 0.08);
            for (var q = 0; q <= 2; q++) {
                var gy = Math.round(padT + h * q / 2) + 0.5;
                c.beginPath(); c.moveTo(0, gy); c.lineTo(width, gy); c.stroke();
            }
            for (var s = 0; s < tr.series.length; s++) {
                var v = tr.series[s].values || [], col = tr.series[s].color;
                if (v.length === 0) continue;
                var step = width / Math.max(1, root.historyLen - 1), pts = [];
                for (var i = 0; i < v.length; i++) {
                    var px = Math.min(width - 4, width - 4 - (v.length - 1 - i) * step);
                    var py = padT + h - Math.max(0, Math.min(100, v[i] || 0)) / 100 * h;
                    pts.push([px, py]);
                }
                if (pts.length >= 2) {
                    var g = c.createLinearGradient(0, padT, 0, padT + h);
                    g.addColorStop(0, Qt.rgba(col.r, col.g, col.b, Tok.light ? 0.16 : 0.24));
                    g.addColorStop(1, Qt.rgba(col.r, col.g, col.b, 0.0));
                    c.beginPath(); c.moveTo(pts[0][0], padT + h);
                    for (var j = 0; j < pts.length; j++) c.lineTo(pts[j][0], pts[j][1]);
                    c.lineTo(pts[pts.length - 1][0], padT + h); c.closePath();
                    c.fillStyle = g; c.fill();

                    c.beginPath();
                    for (var k = 0; k < pts.length; k++) {
                        if (k === 0) c.moveTo(pts[k][0], pts[k][1]);
                        else c.lineTo(pts[k][0], pts[k][1]);
                    }
                    c.lineWidth = 2; c.lineJoin = "round"; c.lineCap = "round";
                    c.strokeStyle = col; c.stroke();
                }
                // live terminal dot on the latest sample
                var last = pts[pts.length - 1];
                c.beginPath(); c.arc(last[0], last[1], 3.2, 0, Math.PI * 2);
                c.fillStyle = col; c.fill();
            }
        }
    }

    // Control Center tile: elevated Tok.surface when off, Tok.accentWash with crisp accent badge when on.
    component Tile: Rectangle {
        id: tl
        property string icon: ""
        property string label: ""
        property string status: ""
        property bool on: false
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: 62
        radius: root.cardRad
        color: tl.on ? Tok.accentWash : (tlMa.containsMouse ? Tok.raised : root.cardFill)
        border.width: 1
        border.color: tl.on ? Tok.alpha(Tok.accent, Tok.light ? 0.26 : 0.34) : root.cardEdge
        scale: tlMa.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Tok.s3
            anchors.rightMargin: Tok.s3
            spacing: Tok.s3
            Rectangle {
                implicitWidth: 34; implicitHeight: 34; radius: 17
                color: tl.on ? Tok.accent : root.track
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                Sym { anchors.centerIn: parent; text: tl.icon; sz: 18; color: tl.on ? Tok.accentInk : Tok.ink2 }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                IndText { text: tl.label; sz: Tok.tDense; font.weight: Font.DemiBold
                    color: Tok.ink; Layout.fillWidth: true; elide: Text.ElideRight }
                IndText { text: tl.status; sz: Tok.tData; color: tl.on ? Tok.accent : Tok.ink3
                    font.weight: tl.on ? Font.Medium : Font.Normal
                    Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
        MouseArea { id: tlMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: tl.clicked() }
    }

    // Secondary action button under the tiles (Lock, Wallpapers)
    component Action: Rectangle {
        id: ac
        property string icon: ""
        property string label: ""
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: 38
        radius: Tok.r + 2
        color: acMa.containsMouse ? Tok.raised : root.cardFill
        border.width: 1
        border.color: acMa.containsMouse ? Tok.alpha(Tok.ink, 0.14) : root.cardEdge
        scale: acMa.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Row {
            anchors.centerIn: parent
            spacing: Tok.s2
            Sym { anchors.verticalCenter: parent.verticalCenter; text: ac.icon; sz: 16; color: acMa.containsMouse ? Tok.accent : Tok.ink2 }
            IndText { anchors.verticalCenter: parent.verticalCenter; text: ac.label; sz: Tok.tDense; font.weight: Font.Medium }
        }
        MouseArea { id: acMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: ac.clicked() }
    }

    // Structured metric cell inside the Graphics card: soft tinted icon badge + clear value + optional bar.
    component Fact: RowLayout {
        id: fc
        property string icon: ""
        property string label: ""
        property string value: ""
        property string sub: ""
        property string tone: "neutral"
        property real turn: 0
        property real barAmount: -1
        readonly property color badgeCol: root.toneColor(fc.tone, root.tileColor(fc.turn))
        Layout.fillWidth: true
        spacing: Tok.s3
        Rectangle {
            implicitWidth: 34; implicitHeight: 34; radius: Tok.r
            color: Tok.alpha(fc.badgeCol, Tok.light ? 0.13 : 0.20)
            Sym { anchors.centerIn: parent; text: fc.icon; sz: 18; color: fc.badgeCol }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            IndText { text: fc.label; sz: Tok.tLabel; color: Tok.ink3; Layout.fillWidth: true }
            Row {
                spacing: 5
                IndText { id: fcVal; text: fc.value; sz: Tok.tBody; font.weight: Font.DemiBold
                    font.features: ({ "tnum": 1 })
                    color: fc.tone === "neutral" ? Tok.ink : root.toneColor(fc.tone) }
                IndText { anchors.baseline: fcVal.baseline; visible: fc.sub !== ""
                    text: fc.sub; sz: Tok.tData; color: Tok.ink3; font.features: ({ "tnum": 1 }) }
            }
            Rectangle {
                visible: fc.barAmount >= 0
                Layout.fillWidth: true
                Layout.maximumWidth: 132
                Layout.topMargin: 2
                implicitHeight: 4
                radius: 2
                color: root.track
                Rectangle {
                    height: parent.height; radius: 2
                    width: Math.max(fc.barAmount > 0 ? 4 : 0, parent.width * Math.max(0, Math.min(1, fc.barAmount)))
                    color: fc.badgeCol
                    Behavior on width { NumberAnimation { duration: Tok.mSlow; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    // Share bar: rounded track with smooth filled indicator.
    component Bar: Rectangle {
        property real amount: 0
        property color fill: Tok.accent
        implicitHeight: 5
        radius: 2.5
        color: root.track
        Rectangle {
            height: parent.height; radius: 2.5
            width: Math.max(parent.amount > 0 ? 5 : 0, parent.width * Math.max(0, Math.min(1, parent.amount)))
            color: parent.fill
            Behavior on width { NumberAnimation { duration: Tok.mSlow; easing.type: Easing.OutCubic } }
        }
    }

    PanelWindow {
        id: dWin
        readonly property real ui: Tok.uiFor(dWin.screen)
        readonly property bool live: root.shown || motion.presenting
        anchors { top: true; left: true; bottom: true; right: true }
        visible: dWin.live
        implicitWidth: 1
        implicitHeight: 1
        mask: dWin.live ? allInput : noInput
        Region { id: noInput }
        Region { id: allInput; item: dWin.contentItem }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:dashboard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        Binding { target: dWin.contentItem; property: "scale"; value: dWin.ui }

        Rectangle {
            id: scrim
            anchors.centerIn: parent
            width: dWin.width / dWin.ui
            height: dWin.height / dWin.ui
            color: Qt.rgba(0, 0, 0, Tok.light ? 0.30 : 0.50)
            opacity: motion.progress
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        FocusScope {
            anchors.fill: scrim
            focus: true
            Keys.onEscapePressed: root.close()

            Rectangle {
                id: sheet
                anchors.centerIn: parent
                anchors.verticalCenterOffset: (1 - motion.progress) * 16
                width: Math.min(1240, parent.width - Tok.s12 * 2)
                height: Math.min(900, parent.height - Tok.s12 * 2)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.alpha(Tok.ink, Tok.light ? 0.11 : 0.13)
                opacity: motion.progress
                scale: 0.98 + 0.02 * motion.progress
                MouseArea { anchors.fill: parent }

                Item {
                    anchors.fill: parent
                    anchors.margins: Tok.s6

                    // ---------- header ----------
                    ColumnLayout {
                        id: headerWrap
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        spacing: Tok.s4

                        RowLayout {
                            id: header
                            Layout.fillWidth: true
                            spacing: Tok.s4

                            IndText {
                                id: clock
                                property string t: Qt.formatDateTime(new Date(), "HH:mm")
                                text: t; sz: 42; font.weight: Font.DemiBold
                                font.letterSpacing: -1.0
                                font.features: ({ "tnum": 1 })
                                Timer { interval: 1000; running: root.shown; repeat: true; triggeredOnStart: true
                                    onTriggered: clock.t = Qt.formatDateTime(new Date(), "HH:mm") }
                            }
                            Rectangle {
                                implicitWidth: 1; implicitHeight: 32
                                color: Tok.rule
                                Layout.alignment: Qt.AlignVCenter
                            }
                            ColumnLayout {
                                spacing: 2
                                Layout.alignment: Qt.AlignVCenter
                                IndText {
                                    id: dateLbl
                                    property string d: Qt.formatDateTime(new Date(), "dddd, d MMMM")
                                    text: d; sz: Tok.tBody; font.weight: Font.DemiBold
                                    Timer { interval: 60000; running: root.shown; repeat: true; triggeredOnStart: true
                                        onTriggered: dateLbl.d = Qt.formatDateTime(new Date(), "dddd, d MMMM") }
                                }
                                Row {
                                    spacing: 6
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6; height: 6; radius: 3
                                        color: Tok.ok
                                    }
                                    IndText {
                                        sz: Tok.tData; color: Tok.ink3
                                        text: root.upTime ? "Up " + root.upTime + " · " + root.hostName : root.hostName
                                    }
                                    IndText {
                                        visible: root.batPct >= 0
                                        sz: Tok.tData; color: Tok.ink3; font.features: ({ "tnum": 1 })
                                        text: "· " + root.batPct + "%"
                                              + (root.batRate > 0.2 ? " (" + root.batRate.toFixed(1) + " W)" : "")
                                              + (root.batEta ? " · " + root.batEta : "")
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }

                            // Unified segmented tab switcher (Overview · Gaming · Dev)
                            Rectangle {
                                implicitHeight: 36
                                implicitWidth: tabRow.implicitWidth + 6
                                radius: 18
                                color: Tok.sunken
                                border.width: 1
                                border.color: root.cardEdge

                                Row {
                                    id: tabRow
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Repeater {
                                        model: [
                                            { id: 0, l: "Overview", i: "space_dashboard" },
                                            { id: 1, l: "Gaming",   i: "sports_esports" },
                                            { id: 2, l: "Dev",      i: "terminal" }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property bool on: root.dashTab === modelData.id
                                            implicitHeight: 30
                                            implicitWidth: tabInner.implicitWidth + 24
                                            radius: 15
                                            color: on ? Tok.raised : (tabMa.containsMouse ? root.rowHover : "transparent")
                                            border.width: on ? 1 : 0
                                            border.color: root.cardEdge
                                            Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                            Row {
                                                id: tabInner
                                                anchors.centerIn: parent
                                                spacing: 6
                                                Sym {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.i; sz: 15
                                                    color: on ? Tok.accent : Tok.ink3
                                                }
                                                IndText {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.l
                                                    sz: Tok.tData
                                                    font.weight: on ? Font.DemiBold : Font.Medium
                                                    color: on ? Tok.ink : Tok.ink2
                                                }
                                            }
                                            MouseArea {
                                                id: tabMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.dashTab = modelData.id;
                                                    if (modelData.id === 1) gamingHub.refresh();
                                                    else if (modelData.id === 2) ghProc.running = true;
                                                    else if (modelData.id === 0) tdIn.forceActiveFocus();
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Subtle Esc keycap + close button
                            Rectangle {
                                implicitHeight: 24
                                implicitWidth: escTxt.implicitWidth + 14
                                radius: 6
                                color: Tok.sunken
                                border.width: 1
                                border.color: root.cardEdge
                                IndText { id: escTxt; anchors.centerIn: parent; text: "Esc"; sz: Tok.tLabel; mono: true; color: Tok.ink3 }
                            }
                            Rectangle {
                                implicitWidth: 34; implicitHeight: 34; radius: 17
                                color: closeMa.containsMouse ? Tok.raised : root.cardFill
                                border.width: 1; border.color: root.cardEdge
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Sym { anchors.centerIn: parent; text: "close"; sz: 18; color: closeMa.containsMouse ? Tok.ink : Tok.ink2 }
                                MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: Tok.rule
                        }
                    }

                    GamingHub {
                        id: gamingHub
                        anchors { top: headerWrap.bottom; topMargin: Tok.s4; left: parent.left
                                  right: parent.right; bottom: parent.bottom }
                        visible: root.dashTab === 1
                        active: root.shown && root.dashTab === 1
                        liveGameId: root.liveGameId
                        onLaunched: root.close()
                    }

                    DevHub {
                        id: devHub
                        anchors { top: headerWrap.bottom; topMargin: Tok.s4; left: parent.left
                                  right: parent.right; bottom: parent.bottom }
                        visible: root.dashTab === 2
                        active: root.shown && root.dashTab === 2
                        github: root.githubData
                        aiTools: root.aiTools
                        aiShown: root.aiShown
                        aiBarValue: root.aiBarValue
                        onRefreshGithub: ghProc.running = true
                        onFocusAi: root.focusAi(id)
                        onOpenGithub: {
                            var u = root.githubData.url || "";
                            if (u) Quickshell.execDetached(["xdg-open", u]);
                            else Quickshell.execDetached(["xdg-open", "https://github.com"]);
                        }
                    }

                    // ---------- two columns (overview) ----------
                    RowLayout {
                        visible: root.dashTab === 0
                        anchors { top: headerWrap.bottom; topMargin: Tok.s4; left: parent.left
                                  right: parent.right; bottom: parent.bottom }
                        spacing: Tok.s6

                        // ===== left: the machine =====
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 3
                            spacing: Tok.s4

                            Group {
                                title: "System"
                                note: (root.loadAvg !== "—" ? "Load " + root.loadAvg : "")
                                      + (root.swapInfo !== "—" ? " · swap " + root.swapInfo : "")
                                      + ((root.netRx > 0 || root.netTx > 0) ? " · ↓ " + root.netFmt(root.netRx) + " ↑ " + root.netFmt(root.netTx) : "")

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s2
                                    Ring { label: "CPU"; amount: root.cpuPct; tone: root.pctTone(root.cpuPct)
                                        baseColor: Tok.accent
                                        sub: root.cpuTemp > 0 ? root.cpuTemp + "°C" : "" }
                                    Ring { label: "Memory"; amount: root.ramPct; tone: root.pctTone(root.ramPct)
                                        baseColor: root.memColor
                                        sub: root.ramUsed + " / " + root.ramTotal + " GiB" }
                                    Ring { label: "Disk"; amount: root.diskPct; tone: root.pctTone(root.diskPct)
                                        baseColor: root.diskColor
                                        sub: root.diskUsed }
                                    Ring { visible: root.gpuName !== ""; label: "GPU"; amount: root.gpuUtil
                                        tone: root.pctTone(root.gpuUtil)
                                        baseColor: root.gpuColor
                                        sub: root.gpuTemp > 0 ? root.gpuTemp + "°C" : "" }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Tok.s1
                                    implicitHeight: 1
                                    color: Tok.rule
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 2
                                    spacing: Tok.s3
                                    IndText { text: "Last minute"; sz: Tok.tData; color: Tok.ink2; font.weight: Font.DemiBold }
                                    IndText {
                                        visible: root.cpuHistory.length < 4
                                        text: "Sampling…"
                                        sz: Tok.tLabel; color: Tok.ink3
                                    }
                                    Item { Layout.fillWidth: true }
                                    Repeater {
                                        model: [
                                            { l: "CPU",    v: root.cpuPct + "%", c: Tok.accent },
                                            { l: "Memory", v: root.ramPct + "%", c: root.memColor }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            implicitHeight: 22
                                            implicitWidth: legRow.implicitWidth + 14
                                            radius: 11
                                            color: Tok.alpha(modelData.c, Tok.light ? 0.10 : 0.16)
                                            Row {
                                                id: legRow
                                                anchors.centerIn: parent
                                                spacing: 5
                                                Rectangle { anchors.verticalCenter: parent.verticalCenter
                                                    width: 7; height: 7; radius: 3.5; color: modelData.c }
                                                IndText { text: modelData.l; sz: Tok.tLabel; color: Tok.ink2; font.weight: Font.Medium }
                                                IndText { text: modelData.v; sz: Tok.tLabel; mono: true; color: modelData.c; font.weight: Font.DemiBold }
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 92
                                    radius: Tok.r
                                    color: root.wellFill
                                    border.width: 1
                                    border.color: Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.07)
                                    clip: true

                                    Trace {
                                        anchors.fill: parent
                                        anchors.leftMargin: 4
                                        anchors.rightMargin: 28
                                        series: [{ values: root.ramHistory, color: root.memColor },
                                                 { values: root.cpuHistory, color: Tok.accent }]
                                    }
                                    // Quiet right-edge scale ticks aligned to gridlines
                                    IndText { anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 3; anchors.rightMargin: 6
                                        text: "100"; sz: 9; mono: true; color: Tok.ink3; opacity: 0.7 }
                                    IndText { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; anchors.rightMargin: 6
                                        text: "50"; sz: 9; mono: true; color: Tok.ink3; opacity: 0.7 }
                                    IndText { anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.bottomMargin: 2; anchors.rightMargin: 6
                                        text: "0"; sz: 9; mono: true; color: Tok.ink3; opacity: 0.7 }
                                }
                            }

                            Group {
                                title: "Graphics"
                                note: root.gpuName
                                notePill: true
                                visible: root.gpuName !== ""

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s3
                                    Fact { icon: "device_thermostat"; label: "Temperature"; turn: -0.08
                                        value: root.gpuTemp + "°C"; tone: root.tempTone(root.gpuTemp) }
                                    Rectangle { implicitWidth: 1; Layout.fillHeight: true; Layout.topMargin: 2; Layout.bottomMargin: 2; color: Tok.rule }
                                    Fact { icon: "bolt"; label: "Power"; turn: 0.12
                                        value: root.gpuPower + " W" }
                                    Rectangle { implicitWidth: 1; Layout.fillHeight: true; Layout.topMargin: 2; Layout.bottomMargin: 2; color: Tok.rule }
                                    Fact { icon: "memory"; label: "Video memory"; turn: 0.28
                                        value: root.gpuVramUsed + " GB"; sub: "/ " + root.gpuVramTotal
                                        tone: root.pctTone(root.vramPct)
                                        barAmount: root.vramPct / 100 }
                                }
                            }

                            Group {
                                title: "Processes"
                                fill: true
                                headerExtra: [
                                    Rectangle {
                                        implicitHeight: 24
                                        implicitWidth: sortRow.implicitWidth + 4
                                        radius: 12
                                        color: Tok.sunken
                                        border.width: 1
                                        border.color: root.cardEdge
                                        Row {
                                            id: sortRow
                                            anchors.centerIn: parent
                                            spacing: 2
                                            Repeater {
                                                model: [{ k: "cpu", l: "CPU" }, { k: "mem", l: "Memory" }]
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    readonly property bool on: root.procSort === modelData.k
                                                    implicitHeight: 20
                                                    implicitWidth: stLbl.implicitWidth + 14
                                                    radius: 10
                                                    color: on ? Tok.raised : (stMa.containsMouse ? root.rowHover : "transparent")
                                                    IndText {
                                                        id: stLbl
                                                        anchors.centerIn: parent
                                                        text: modelData.l
                                                        sz: Tok.tLabel
                                                        font.weight: on ? Font.DemiBold : Font.Normal
                                                        color: on ? Tok.ink : Tok.ink3
                                                    }
                                                    MouseArea {
                                                        id: stMa; anchors.fill: parent; hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.procSort = modelData.k
                                                    }
                                                }
                                            }
                                        }
                                    }
                                ]

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 6
                                    Layout.rightMargin: 6
                                    spacing: Tok.s3
                                    IndText { text: "Name"; sz: Tok.tLabel; color: Tok.ink3; font.weight: Font.Medium; Layout.fillWidth: true }
                                    IndText { text: "CPU"; sz: Tok.tLabel; font.weight: root.procSort === "cpu" ? Font.DemiBold : Font.Medium
                                        color: root.procSort === "cpu" ? Tok.ink2 : Tok.ink3
                                        Layout.preferredWidth: 100 + Tok.s3 + 52; horizontalAlignment: Text.AlignRight }
                                    IndText { text: "Memory"; sz: Tok.tLabel; font.weight: root.procSort === "mem" ? Font.DemiBold : Font.Medium
                                        color: root.procSort === "mem" ? Tok.ink2 : Tok.ink3
                                        Layout.preferredWidth: 68; horizontalAlignment: Text.AlignRight }
                                    Item { Layout.preferredWidth: 38 }
                                }
                                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Tok.rule }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Repeater {
                                        model: root.procList
                                        delegate: Rectangle {
                                            id: procRow
                                            required property var modelData
                                            required property int index
                                            readonly property bool armed: root.armedKillPid === modelData.pid
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 24
                                            radius: Tok.rSmall + 2
                                            color: procRow.armed ? Tok.critWash : (pHover.hovered ? root.rowHover : "transparent")
                                            HoverHandler { id: pHover }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.focusProcess(procRow.modelData.pid, procRow.modelData.name)
                                            }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 6
                                                anchors.rightMargin: 4
                                                spacing: Tok.s3
                                                IndText {
                                                    text: modelData.name; sz: Tok.tDense
                                                    font.weight: index === 0 ? Font.Medium : Font.Normal
                                                    Layout.fillWidth: true; elide: Text.ElideRight
                                                }
                                                Bar {
                                                    Layout.preferredWidth: 100
                                                    amount: root.procSort === "mem"
                                                        ? (modelData.rss || 0) / Math.max(1, root.procPeak)
                                                        : (parseFloat(modelData.cpu) || 0) / Math.max(1, root.procPeak)
                                                    fill: root.toneColor(modelData._tone, root.procSort === "mem" ? root.memColor : Tok.accent)
                                                }
                                                IndText {
                                                    text: modelData.cpu + "%"; mono: true; sz: Tok.tData
                                                    font.weight: root.procSort === "cpu" ? Font.Medium : Font.Normal
                                                    color: modelData._tone !== "neutral" && root.procSort === "cpu"
                                                        ? root.toneColor(modelData._tone)
                                                        : (root.procSort === "cpu" ? Tok.ink : Tok.ink3)
                                                    Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight
                                                }
                                                IndText {
                                                    text: modelData.rss + " MB"; mono: true; sz: Tok.tData
                                                    font.weight: root.procSort === "mem" ? Font.Medium : Font.Normal
                                                    color: modelData._tone !== "neutral" && root.procSort === "mem"
                                                        ? root.toneColor(modelData._tone)
                                                        : (root.procSort === "mem" ? Tok.ink : Tok.ink3)
                                                    Layout.preferredWidth: 68; horizontalAlignment: Text.AlignRight
                                                }
                                                Rectangle {
                                                    Layout.preferredWidth: 38
                                                    Layout.preferredHeight: 19
                                                    radius: 9.5
                                                    opacity: procRow.armed || pHover.hovered ? 1 : 0
                                                    color: procRow.armed ? Tok.crit : (killMa.containsMouse ? Tok.critWash : "transparent")
                                                    Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                                                    IndText {
                                                        anchors.centerIn: parent
                                                        visible: procRow.armed
                                                        text: "Kill?"; sz: 10; font.weight: Font.DemiBold; color: "white"
                                                    }
                                                    Sym {
                                                        anchors.centerIn: parent
                                                        visible: !procRow.armed
                                                        text: "close"; sz: 14
                                                        color: killMa.containsMouse ? Tok.crit : Tok.ink3
                                                    }
                                                    MouseArea {
                                                        id: killMa; anchors.fill: parent; hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.endProcess(procRow.modelData.pid)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                Item { Layout.fillHeight: true }
                            }
                        }

                        // ===== right: controls, today, tasks =====
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 2
                            spacing: Tok.s4

                            // Controls block with aligned section label matching "System" on the left
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Tok.s2

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 2
                                    Layout.rightMargin: 2
                                    IndText { text: "Controls"; sz: Tok.tDense; font.weight: Font.DemiBold; color: Tok.ink }
                                    Item { Layout.fillWidth: true }
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    rowSpacing: Tok.s2
                                    columnSpacing: Tok.s2
                                    Tile { icon: root.wifiOn ? "wifi" : "wifi_off"; label: "Wi-Fi"
                                        on: root.wifiOn; status: root.wifiOn ? "On" : "Off"
                                        onClicked: root.setWifi(!root.wifiOn) }
                                    Tile { icon: root.btOn ? "bluetooth" : "bluetooth_disabled"; label: "Bluetooth"
                                        on: root.btOn; status: root.btOn ? "On" : "Off"
                                        onClicked: root.setBt(!root.btOn) }
                                    Tile { icon: "coffee"; label: "Caffeine"
                                        on: root.cafOn; status: root.cafOn ? "Screen awake" : "Off"
                                        onClicked: root.setCaf(!root.cafOn) }
                                    Tile { icon: root.muted ? "volume_off" : "volume_up"; label: "Sound"
                                        on: !root.muted; status: root.muted ? "Muted" : "On"
                                        onClicked: root.setMute(!root.muted) }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s2
                                    Action { icon: "lock"; label: "Lock"
                                        onClicked: { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-lock.sh"]); root.close() } }
                                    Action { icon: "wallpaper"; label: "Wallpapers"
                                        onClicked: { Quickshell.execDetached(["sh","-c","~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"]); root.close() } }
                                }

                                // Power profile segmented selector
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 34
                                    radius: 17
                                    color: Tok.sunken
                                    border.width: 1
                                    border.color: root.cardEdge
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 3
                                        spacing: 2
                                        Repeater {
                                            model: [
                                                { k: "power-saver", l: "Saver",       i: "eco" },
                                                { k: "balanced",    l: "Balanced",    i: "balance" },
                                                { k: "performance", l: "Performance", i: "bolt" }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool on: root.powerProfile === modelData.k
                                                Layout.fillWidth: true
                                                Layout.fillHeight: true
                                                radius: 14
                                                color: on ? Tok.raised : (ppMa.containsMouse ? root.rowHover : "transparent")
                                                border.width: on ? 1 : 0
                                                border.color: root.cardEdge
                                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                                Row {
                                                    anchors.centerIn: parent
                                                    spacing: 5
                                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 14
                                                        color: on ? Tok.accent : Tok.ink3 }
                                                    IndText { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; sz: Tok.tLabel
                                                        font.weight: on ? Font.DemiBold : Font.Medium; color: on ? Tok.ink : Tok.ink2 }
                                                }
                                                MouseArea {
                                                    id: ppMa; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.applyPowerProfile(modelData.k)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Contextual Now Playing strip (only shown when media is active)
                            Rectangle {
                                visible: root.player !== null && ((root.player.trackTitle || "") !== "" || (root.player.identity || "") !== "")
                                Layout.fillWidth: true
                                implicitHeight: 62
                                radius: root.cardRad
                                color: root.cardFill
                                border.width: 1
                                border.color: root.cardEdge

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Tok.s2 + 2
                                    spacing: Tok.s3
                                    Rectangle {
                                        implicitWidth: 42; implicitHeight: 42; radius: Tok.r
                                        color: Tok.accentWash; clip: true
                                        Image {
                                            id: npArt
                                            anchors.fill: parent
                                            source: (root.player && root.player.trackArtUrl) ? root.player.trackArtUrl : ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true; cache: false
                                            sourceSize.width: 84; sourceSize.height: 84
                                        }
                                        Sym {
                                            anchors.centerIn: parent
                                            visible: npArt.status !== Image.Ready
                                            text: "music_note"; sz: 20; color: Tok.accent
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        IndText {
                                            text: root.player ? (root.player.trackTitle || root.player.identity || "") : ""
                                            sz: Tok.tDense; font.weight: Font.DemiBold
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                        }
                                        IndText {
                                            text: root.player ? (root.player.trackArtist || root.player.identity || "") : ""
                                            sz: Tok.tLabel; color: Tok.ink3
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                        }
                                    }
                                    Row {
                                        spacing: 2
                                        Repeater {
                                            model: [
                                                { i: "skip_previous", act: "prev", prim: false },
                                                { i: (root.player && root.player.isPlaying) ? "pause" : "play_arrow", act: "toggle", prim: true },
                                                { i: "skip_next",     act: "next", prim: false }
                                            ]
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: modelData.prim ? 32 : 28; height: width; radius: width / 2
                                                anchors.verticalCenter: parent.verticalCenter
                                                color: modelData.prim ? Tok.accent : (mpMa.containsMouse ? root.rowHover : "transparent")
                                                Sym {
                                                    anchors.centerIn: parent
                                                    text: modelData.i; sz: modelData.prim ? 19 : 18
                                                    color: modelData.prim ? Tok.accentInk : Tok.ink2
                                                }
                                                MouseArea {
                                                    id: mpMa; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (!root.player) return;
                                                        if (modelData.act === "prev") root.player.previous();
                                                        else if (modelData.act === "next") root.player.next();
                                                        else root.player.togglePlaying();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Group {
                                title: "Today"
                                note: root.usageRows.length > 0 ? root.usageFmt(root.usageTotal) + " active" : ""

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s3
                                    visible: root.usageRows.length > 0
                                    Repeater {
                                        model: root.usageRows.slice(0, 5)
                                        delegate: ColumnLayout {
                                            required property var modelData
                                            required property int index
                                            Layout.fillWidth: true
                                            spacing: 5
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: Tok.s2
                                                IndText {
                                                    text: modelData.app; sz: Tok.tDense
                                                    font.weight: index === 0 ? Font.Medium : Font.Normal
                                                    Layout.fillWidth: true; elide: Text.ElideRight
                                                }
                                                IndText { text: modelData.time; mono: true; sz: Tok.tData; color: Tok.ink; font.weight: Font.Medium }
                                                IndText { text: modelData.pct; mono: true; sz: Tok.tLabel; color: Tok.ink3 }
                                            }
                                            Bar {
                                                Layout.fillWidth: true
                                                amount: (parseInt(modelData.pct) || 0) / Math.max(1, parseInt(root.usageRows[0].pct) || 1)
                                                fill: index === 0 ? Tok.accent : Tok.alpha(Tok.accent, 0.52)
                                            }
                                        }
                                    }
                                }
                                IndText {
                                    visible: root.usageRows.length === 0
                                    text: "No app focus recorded yet today."
                                    sz: Tok.tDense; color: Tok.ink3
                                }
                            }

                            Group {
                                title: "Tasks"
                                note: root.todoList.length ? root.todoOpen + " of " + root.todoList.length + " open" : ""
                                fill: true

                                // Proper rounded input field so it clearly invites typing
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 36
                                    radius: Tok.r
                                    color: root.wellFill
                                    border.width: tdIn.activeFocus ? 1.5 : 1
                                    border.color: tdIn.activeFocus ? Tok.accent : root.cardEdge
                                    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Tok.s2
                                        anchors.rightMargin: Tok.s2
                                        spacing: Tok.s2
                                        Rectangle {
                                            implicitWidth: 22; implicitHeight: 22; radius: 11
                                            color: Tok.accent
                                            Sym { anchors.centerIn: parent; text: "add"; sz: 15; color: Tok.accentInk }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.addTodo(tdIn.text); tdIn.text = ""; tdIn.forceActiveFocus() } }
                                        }
                                        TextInput {
                                            id: tdIn
                                            Layout.fillWidth: true
                                            clip: true
                                            selectByMouse: true
                                            color: Tok.ink
                                            selectionColor: Tok.accent
                                            selectedTextColor: Tok.accentInk
                                            font.family: Tok.sans
                                            font.pixelSize: Tok.tDense
                                            onAccepted: { root.addTodo(text); text = "" }
                                            IndText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: tdIn.text === ""
                                                text: "New task · @YYYY-MM-DD"
                                                sz: Tok.tDense
                                                color: Tok.ink3
                                            }
                                        }
                                        IndText {
                                            visible: tdIn.text !== ""
                                            text: "↵"; mono: true; sz: Tok.tData; color: Tok.accent
                                        }
                                    }
                                }

                                // List + centered empty state inside the same flexible region
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true

                                    ListView {
                                        id: todoLv
                                        anchors.fill: parent
                                        visible: root.todoList.length > 0
                                        clip: true
                                        spacing: 2
                                        model: root.todoDisplay
                                        boundsBehavior: Flickable.StopAtBounds
                                        delegate: Rectangle {
                                            id: td
                                            required property var modelData
                                            required property int index
                                            width: todoLv.width
                                            height: 36
                                            radius: Tok.rSmall + 2
                                            color: tdHover.hovered ? root.rowHover : "transparent"
                                            HoverHandler { id: tdHover }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.toggleTodo(td.modelData._i)
                                            }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: Tok.s2
                                                anchors.rightMargin: Tok.s2
                                                spacing: Tok.s3
                                                Rectangle {
                                                    implicitWidth: 18; implicitHeight: 18; radius: 9
                                                    color: td.modelData.done ? Tok.accent : "transparent"
                                                    border.width: 1.5
                                                    border.color: td.modelData.done ? Tok.accent : Tok.ink3
                                                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                                    Sym { anchors.centerIn: parent; text: "check"; sz: 13
                                                        color: Tok.accentInk; visible: td.modelData.done }
                                                }
                                                IndText {
                                                    text: td.modelData.text
                                                    sz: Tok.tDense
                                                    color: td.modelData.done ? Tok.ink3 : Tok.ink
                                                    font.strikeout: td.modelData.done
                                                    elide: Text.ElideRight
                                                    Layout.fillWidth: true
                                                }
                                                Rectangle {
                                                    visible: (td.modelData.due || "") !== ""
                                                    readonly property bool dueToday: !td.modelData.done && td.modelData.due === Qt.formatDate(new Date(), "yyyy-MM-dd")
                                                    implicitHeight: 20
                                                    implicitWidth: dueLbl.implicitWidth + 12
                                                    radius: 10
                                                    color: dueToday ? Tok.warnWash : Tok.sunken
                                                    IndText {
                                                        id: dueLbl
                                                        anchors.centerIn: parent
                                                        text: td.modelData.due
                                                        sz: Tok.tLabel
                                                        mono: true
                                                        color: parent.dueToday ? Tok.warn : Tok.ink3
                                                    }
                                                }
                                                Sym {
                                                    text: "close"; sz: 15
                                                    opacity: tdHover.hovered ? 1 : 0
                                                    color: delMa.containsMouse ? Tok.crit : Tok.ink3
                                                    MouseArea { id: delMa; anchors.fill: parent; anchors.margins: -4
                                                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.removeTodo(td.modelData._i) }
                                                }
                                            }
                                        }
                                    }

                                    // Clean centered empty state (instead of floating at the bottom edge)
                                    Column {
                                        anchors.centerIn: parent
                                        visible: root.todoList.length === 0
                                        spacing: 6
                                        Rectangle {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 36; height: 36; radius: 18
                                            color: root.wellFill
                                            Sym { anchors.centerIn: parent; text: "task_alt"; sz: 19; color: Tok.ink3 }
                                        }
                                        IndText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "All clear"; sz: Tok.tDense; font.weight: Font.Medium; color: Tok.ink2
                                        }
                                        IndText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "Type a task above and press Enter"; sz: Tok.tLabel; color: Tok.ink3
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
