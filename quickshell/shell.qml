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
    property string settingsPath: Qt.resolvedUrl("settings.qml").toString().replace("file://", "")

    // resident launcher — no process-spawn delay; open via `qs -c sea-shell ipc call launcher …`
    Launcher { id: launcher }
    IpcHandler {
        target: "launcher"
        function toggle(): void { launcher.toggle() }
        function clipboard(): void { launcher.open(";") }
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
    property string cfgAccent: "#63c7dd"
    property string cfgFont: "monospace"
    // dropdowns use the bar's exact opacity; Hyprland's popup blur keeps text readable
    readonly property real dropOpacity: root.cfgOpacity
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; [ -f \"$d/appearance.json\" ] || printf '{\"radius\":14,\"opacity\":0.80,\"height\":42,\"accent\":\"#63c7dd\",\"font\":\"monospace\"}' > \"$d/appearance.json\"; echo \"$d/appearance.json\""]
        stdout: StdioCollector { id: apprPathOut; onStreamFinished: apprFile.path = apprPathOut.text.trim() } }
    FileView {
        id: apprFile; path: ""; watchChanges: true
        function apply() { try {
            reload();                                  // pull the latest bytes (needed for live changes)
            var t = text(); if(!t || !t.trim()) return; var j = JSON.parse(t);
            if (j.radius  !== undefined) root.cfgRadius  = j.radius;
            if (j.opacity !== undefined) root.cfgOpacity = j.opacity;
            if (j.height  !== undefined) root.cfgHeight  = j.height;
            if (j.accent  !== undefined && (""+j.accent).length>0) root.cfgAccent = j.accent;
            if (j.font    !== undefined && (""+j.font).length>0)   root.cfgFont   = j.font;
        } catch(e) {} }
        onLoaded: apply()
        onFileChanged: apply()
    }

    QtObject {
        id: theme
        readonly property color bg:    "#0d1420"
        readonly property color panel: "#131b29"
        readonly property color line:  "#24304a"
        readonly property color text:  "#e2e9f4"
        readonly property color sub:   "#a6b6cf"
        readonly property color faint: "#6f8099"
        readonly property color iris:  root.cfgAccent          // accent (user-configurable)
        readonly property color frost: Qt.lighter(root.cfgAccent, 1.22)
        readonly property color good:  "#a6e3a1"
        readonly property color warn:  "#f4c542"
        readonly property color bad:   "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // ---------- audio ----------
    property var sinks: (Pipewire.nodes ? Pipewire.nodes.values : []).filter(function (n) { return n && n.isSink && !n.isStream && n.audio })
    PwObjectTracker { objects: { var a = []; if (Pipewire.defaultAudioSink) a.push(Pipewire.defaultAudioSink); for (var i=0;i<root.sinks.length;i++) a.push(root.sinks[i]); return a } }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "device") : "" }

    // ---------- wifi ----------
    property var wifiList: []
    property string ssid: ""
    property bool wifiOn: false
    Process {
        id: wifiScan; running: true
        command: ["sh", "-c", "nmcli -t -f ACTIVE,SIGNAL,SECURITY,SSID dev wifi 2>/dev/null | awk -F: 'length($4)>0' | sort -t: -k2 -rn | head -8"]
        stdout: StdioCollector { id: wifiOut; onStreamFinished: {
            var out = []; var cur = ""; var lines = wifiOut.text.trim().split("\n");
            for (var i=0;i<lines.length;i++){ if(!lines[i])continue; var p=lines[i].split(":");
                var e={active:p[0]==="yes",signal:parseInt(p[1])||0,secure:(p[2]||"").length>0,ssid:p.slice(3).join(":")};
                out.push(e); if(e.active) cur=e.ssid; }
            root.wifiList = out; root.ssid = cur; root.wifiOn = cur.length>0;
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
    Timer { id: wifiRefresh; interval: 2500; onTriggered: wifiScan.running = true }

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
    Timer { interval: 400; running: root.openPop==="mpris" && root.player!==null; repeat: true; triggeredOnStart: true
        onTriggered: root.mprisPos = (root.player && root.player.positionSupported) ? root.player.position : 0 }
    function fmtTime(s) { s = Math.max(0, Math.floor(s||0)); var m = Math.floor(s/60); var ss = s%60; return m + ":" + (ss<10?"0":"") + ss }

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
    property var lyrics: []              // [{t: seconds, l: line}] when synced
    property string plainLyrics: ""
    property string lyricsState: "idle"  // idle | loading | ok | plain | none
    property string lyricsKey: ""
    readonly property string trackKey: root.player ? (root.player.trackArtist||"")+"|"+(root.player.trackTitle||"") : ""
    onTrackKeyChanged: { root.lyricsState = "idle"; root.lyrics = []; root.plainLyrics = "";
        if (root.lyricsOpen && root.openPop==="mpris") root.fetchLyrics() }
    // current line follows playback (small lead so the line flips as it's sung)
    readonly property int lyrIdx: { var i = -1; for (var k=0;k<root.lyrics.length;k++) if (root.lyrics[k].t <= root.mprisPos + 0.4) i = k; else break; return i }
    function fetchLyrics(force) {
        if (!root.player) return;
        if (!force && root.lyricsKey === root.trackKey && root.lyricsState !== "idle") return;
        root.lyricsKey = root.trackKey; root.lyricsState = "loading"; root.lyrics = []; root.plainLyrics = "";
        lyrProc.running = false;
        // env-array → artist/title never touch shell quoting
        lyrProc.command = ["env",
            "A=" + (root.player.trackArtist||""), "T=" + (root.player.trackTitle||""),
            "AL=" + (root.player.trackAlbum||""), "D=" + Math.round(root.player.length||0),
            "sh","-c","curl -sG --max-time 8 https://lrclib.net/api/get --data-urlencode \"artist_name=$A\" --data-urlencode \"track_name=$T\" --data-urlencode \"album_name=$AL\" --data-urlencode \"duration=$D\"; printf '\\x1e'; curl -sG --max-time 8 https://lrclib.net/api/search --data-urlencode \"track_name=$T\" --data-urlencode \"artist_name=$A\""]
        lyrProc.running = true;
    }
    Process { id: lyrProc
        stdout: StdioCollector { id: lyrOut; onStreamFinished: root.parseLyrics(lyrOut.text) } }
    function parseLyrics(raw) {
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

    // keep clipboard history populated so CTRL+V / the bar icon work.
    // clip-watch.sh kills any stale watchers then starts exactly one pair (idempotent on restart).
    Process { running: true; command: ["sh", Qt.resolvedUrl("clip-watch.sh").toString().replace("file://","")] }

    // ---------- notifications (our own daemon: popups + bar center) ----------
    property var notes: []           // history for the center
    property int noteSeq: 0
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
            var entry = { key: k, summary: (n.summary||""), body: (n.body||""),
                          appName: (n.appName||"notification"), urgency: n.urgency,
                          time: Qt.formatDateTime(new Date(), "HH:mm") };
            root.notes = [entry].concat(root.notes).slice(0, 40);
            popupModel.insert(0, { key: k, summary: entry.summary, body: entry.body, appName: entry.appName, urg: n.urgency });
            // not tracked → server releases it after this handler; we've copied the fields
        }
    }
    function popDismiss(k) { for (var i=0;i<popupModel.count;i++) if (popupModel.get(i).key===k) { popupModel.remove(i); return } }
    function noteClear() { root.notes = []; popupModel.clear() }

    // ---------- OSD (volume + brightness) ----------
    property string osdKind: ""      // "vol" | "bright" | ""
    property real osdVal: 0
    property string osdIcon: ""
    property bool osdReady: false
    Timer { id: osdHide; interval: 1500; onTriggered: root.osdKind = "" }
    Timer { interval: 1400; running: true; onTriggered: root.osdReady = true }  // suppress OSD flash on startup
    function showOsd(kind, val, icon) { if(!root.osdReady) return; root.osdKind = kind; root.osdVal = val; root.osdIcon = icon; osdHide.restart() }

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

    // a clickable bar pill that toggles a dropdown identified by `key`
    component Pill: Rectangle {
        id: pill
        property string icon: ""
        property string value: ""
        property color accent: theme.frost
        property string key: ""
        signal clicked()
        signal rightClicked()
        signal scrolled(real dy)
        property var owner: null
        readonly property bool open: root.openPop === key && key !== ""
        implicitHeight: 26; implicitWidth: pr.implicitWidth + 20
        radius: height/2
        color: (open || pm.containsMouse) ? theme.a(theme.iris,0.18) : theme.a(theme.line,0.42)
        border.width: 1; border.color: (open || pm.containsMouse) ? theme.a(theme.iris,0.55) : theme.a(theme.iris,0.16)
        Behavior on color { ColorAnimation { duration: 120 } }
        Row { id: pr; anchors.centerIn: parent; spacing: 6
            Sym { anchors.verticalCenter: parent.verticalCenter; text: pill.icon; color: pill.accent; visible: text!==""; sz: 16 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: pill.value; color: theme.text; visible: text!==""; font.pixelSize: 13; font.family: root.cfgFont } }
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
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:drop"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand   // lets the wifi password field type
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; left: true; right: true; bottom: true }
        mask: Region { item: cardBg; regions: [ sideRegion ] }
        Region { id: sideRegion; item: dw.sidecar }
        readonly property point hp: (dw.visible && dw.host) ? dw.host.mapToGlobal(Qt.point(0, 0)) : Qt.point(-9999, -9999)
        readonly property int sw: dw.screen ? dw.screen.width : 1920
        // mapToGlobal speaks virtual-desktop coordinates; this surface is monitor-local,
        // so subtract the screen's global offset or cards drift on non-origin monitors
        readonly property int scrX: dw.screen ? dw.screen.x : 0
        readonly property int scrY: dw.screen ? dw.screen.y : 0
        Rectangle {
            id: cardBg
            width: dw.cardW; height: dw.cardH
            x: Math.max(8, Math.min(dw.sw - width - 8, dw.hp.x - dw.scrX + (dw.host ? dw.host.width/2 : 0) - width/2))
            y: dw.hp.y - dw.scrY + (dw.host ? dw.host.height : 0) + 8
            radius: root.cfgRadius; color: theme.a(theme.bg, root.dropOpacity)
            border.width: 1; border.color: theme.a(theme.iris,0.34)
        }
    }

    // ============ one bar per monitor ============
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: bar
            property var modelData
            screen: modelData
            // which tray icon owns the shared tray menu dropdown
            property Item trayHost: null
            property var trayMenuSel: null
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "sea-shell:bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand   // lets dropdown text fields (wifi pw) type
            exclusionMode: ExclusionMode.Auto
            anchors { top: true; left: true; right: true }
            implicitHeight: root.cfgHeight

            Rectangle {
                id: barBg
                anchors.fill: parent
                anchors { topMargin: 6; leftMargin: 8; rightMargin: 8 }
                radius: root.cfgRadius
                color: theme.a(theme.bg, root.cfgOpacity)
                border.width: 1; border.color: theme.a(theme.iris,0.30)

                // ---------- LEFT: logo · workspaces · app name ----------
                Row {
                    id: leftGroup
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 9
                    IconImage { anchors.verticalCenter: parent.verticalCenter; implicitSize: 24; source: Qt.resolvedUrl("logo.svg")
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: launcher.toggle() } }
                    Row {
                        anchors.verticalCenter: parent.verticalCenter; spacing: 6
                        Repeater {
                            model: Hyprland.workspaces
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool foc: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === modelData.id
                                width: foc ? 36 : 24; height: 24; radius: height/2   // circle → pill when active
                                color: foc ? theme.iris : theme.a(theme.line,0.55)
                                border.width: 1; border.color: foc ? theme.frost : theme.a(theme.iris,0.18)
                                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Text { anchors.centerIn: parent; text: modelData.id; color: foc ? theme.bg : theme.sub; font.pixelSize: 12; font.family: root.cfgFont; font.bold: foc }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("workspace "+modelData.id) }
                            }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 240); elide: Text.ElideRight
                        color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont
                        text: (Hyprland.activeToplevel && Hyprland.activeToplevel.lastIpcObject) ? (Hyprland.activeToplevel.lastIpcObject.class || "") : ""
                    }
                }

                // ---------- CENTER: media (click → full player dropdown) ----------
                Pill { owner: bar
                    id: mprisPill
                    anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter }
                    visible: root.player !== null
                    key: "mpris"
                    icon: (root.player && root.player.isPlaying) ? "pause" : "play_arrow"
                    accent: theme.iris
                    value: {
                        if (!root.player) return "";
                        var t = (root.player.trackTitle || ""); var ar = (root.player.trackArtist || "");
                        var s = ar ? (ar + " — " + t) : t;
                        return s.length > 40 ? s.slice(0,39)+"…" : s;
                    }
                    onRightClicked: { if(root.player) root.player.togglePlaying() }
                    onScrolled: (dy)=>{ if(!root.player) return; if(dy>0) root.player.next(); else root.player.previous() }
                }
                Drop { screen: bar.screen
                    id: mprisDrop; host: mprisPill; visible: root.openPop === "mpris" && root.openBar === bar
                    cardW: 380; cardH: mprCol.implicitHeight + 32
                    sidecar: root.lyricsOpen ? lyrPanel : null           // clicks land on the panel only while it's open
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
                                Text { width: parent.width; text: root.player ? (root.player.trackTitle||"—") : "—"; color: theme.text; font.pixelSize: 15; font.family: root.cfgFont; font.bold: true; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap }
                                Text { width: parent.width; visible: text!==""; text: root.player ? (root.player.trackArtist||"") : ""; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont; elide: Text.ElideRight }
                                Text { width: parent.width; visible: text!==""; text: root.player ? (root.player.trackAlbum||"") : ""; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight }
                                // gold badge: only appears for direct-ALSA (bit-perfect) playback, e.g. SONE
                                Row { spacing: 5; visible: root.hqInfo !== ""
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "verified"; sz: 13; color: theme.warn }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: root.hqInfo
                                        color: theme.warn; font.pixelSize: 10; font.family: root.cfgFont; font.bold: true } } } }

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

                        // lyrics toggle — the panel itself opens BESIDE the card (sidecar)
                        Rectangle { width: parent.width; height: 26; radius: 8
                            color: lyMa.containsMouse ? theme.a(theme.iris,0.14) : theme.a(theme.line,0.4)
                            border.width: 1; border.color: root.lyricsOpen ? theme.a(theme.iris,0.5) : theme.a(theme.line,0.9)
                            Row { anchors.centerIn: parent; spacing: 6
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "lyrics"; sz: 14; color: root.lyricsOpen ? theme.iris : theme.sub }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: root.lyricsOpen ? "hide lyrics" : "show lyrics"
                                    color: root.lyricsOpen ? theme.text : theme.sub; font.pixelSize: 10; font.family: root.cfgFont } }
                            MouseArea { id: lyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.lyricsOpen = !root.lyricsOpen; if (root.lyricsOpen) root.fetchLyrics() } } }
                    }

                    // ---- lyrics sidecar: full-height panel next to the player card ----
                    Rectangle {
                        id: lyrPanel
                        visible: root.lyricsOpen && root.openPop === "mpris"
                        width: 300; height: mprisDrop.card.height
                        // right of the card; flips to the left near the screen edge
                        x: (mprisDrop.card.x + mprisDrop.card.width + 10 + width > mprisDrop.sw - 8)
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
                                        horizontalAlignment: Text.AlignHCenter; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont } } } } } }

                // ---------- RIGHT: weather · tray · wifi · vol · battery · clock ----------
                Row {
                    id: rightGroup
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 9

                    // ---- WEATHER dropdown (its pill is declared after the tray, below) ----
                    Drop { screen: bar.screen
                        id: wxDrop; host: wxPill; visible: root.openPop === "wx" && root.openBar === bar
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
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.openPop=""; Quickshell.execDetached(["qs","-p",root.settingsPath]) } } } } }

                    // ---- SYSTEM TRAY (after weather) — collapsible, right-click = app menu ----
                    Row { anchors.verticalCenter: parent.verticalCenter; spacing: 8
                        // collapse / expand toggle
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 20; height: 20; radius: 6
                            visible: SystemTray.items.values.length > 0
                            color: tcm.containsMouse ? theme.a(theme.iris,0.18) : "transparent"
                            Sym { anchors.centerIn: parent; text: root.trayCollapsed ? "chevron_left" : "chevron_right"; sz: 16; color: theme.sub }
                            MouseArea { id: tcm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.trayCollapsed = !root.trayCollapsed } }
                        Row { anchors.verticalCenter: parent.verticalCenter; spacing: 9; visible: !root.trayCollapsed
                            Repeater { model: SystemTray.items
                                delegate: Item { id: trayItem; required property SystemTrayItem modelData; width: 18; height: 18
                                    IconImage { anchors.fill: parent; asynchronous: true; source: trayItem.modelData.icon }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton|Qt.RightButton
                                        onClicked: (e)=>{
                                            if (e.button===Qt.LeftButton) { trayItem.modelData.activate(); return }
                                            // one shared menu window → opening a 2nd icon replaces it, same icon toggles
                                            if (root.openPop==="tray" && bar.trayHost===trayItem) { root.openPop=""; return }
                                            bar.trayHost = trayItem; bar.trayMenuSel = trayItem.modelData; root.openBar = bar; root.openPop = "tray" } }
                                } } } }

                    // ---- shared tray menu: ONE blurable layer-surface Drop (sea-shell:drop),
                    // part of the openPop single-dropdown system so the focus grab dismisses it ----
                    Drop { screen: bar.screen
                        id: trayDrop; host: bar.trayHost
                        visible: root.openPop === "tray" && root.openBar === bar && bar.trayHost !== null
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

                    // ---- WEATHER pill (placed after the tray) ----
                    Pill { owner: bar; id: wxPill; anchors.verticalCenter: parent.verticalCenter; key: "wx"
                        visible: root.wxTemp!==""; icon: root.wxIcon(root.wxCond); value: root.wxTemp; accent: theme.frost }

                    // ---- CLIPBOARD (opens the launcher in clipboard mode) ----
                    Pill { owner: bar; anchors.verticalCenter: parent.verticalCenter; icon: "content_paste"; accent: theme.frost
                        onClicked: { root.openPop = ""; launcher.open(";") } }

                    // ---- NOTIFICATION CENTER (bell + badge) ----
                    Pill { owner: bar; id: bellPill; anchors.verticalCenter: parent.verticalCenter; key: "notif"
                        icon: root.notes.length>0 ? "notifications" : "notifications_none"
                        accent: root.notes.length>0 ? theme.iris : theme.frost
                        value: root.notes.length>0 ? String(root.notes.length) : "" }
                    Drop { screen: bar.screen
                        id: notifDrop; host: bellPill; visible: root.openPop === "notif" && root.openBar === bar
                        cardW: 340; cardH: Math.min(440, notifCol.implicitHeight + 32)
                        Column { id: notifCol; anchors.fill: notifDrop.card; anchors.margins: 12; spacing: 8
                            Row { width: parent.width
                                Text { text: "notifications"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                Item { width: parent.width - 150; height: 1 }
                                Text { text: root.notes.length>0 ? "clear all" : ""; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.noteClear() } } }
                            Text { visible: root.notes.length===0; text: "no notifications"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont }
                            Flickable { width: parent.width; height: Math.min(360, listCol.implicitHeight); contentHeight: listCol.implicitHeight; clip: true; boundsBehavior: Flickable.StopAtBounds; visible: root.notes.length>0
                                Column { id: listCol; width: parent.width; spacing: 6
                                    Repeater { model: root.notes
                                        delegate: Rectangle { required property var modelData; width: listCol.width; radius: 9
                                            implicitHeight: ec.implicitHeight + 16; color: theme.a(theme.line,0.4)
                                            border.width: 1; border.color: modelData.urgency===2 ? theme.a(theme.bad,0.5) : theme.a(theme.iris,0.14)
                                            Column { id: ec; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 9; spacing: 2
                                                Row { width: parent.width
                                                    Text { text: modelData.appName; color: theme.frost; font.pixelSize: 10; font.family: root.cfgFont; elide: Text.ElideRight; width: parent.width-46 }
                                                    Text { text: modelData.time; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont; width: 46; horizontalAlignment: Text.AlignRight } }
                                                Text { width: parent.width; visible: modelData.summary!==""; text: modelData.summary; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; wrapMode: Text.WordWrap }
                                                Text { width: parent.width; visible: modelData.body!==""; text: modelData.body; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText } } } } } } } }

                    // ---- WIFI ----
                    Pill { owner: bar; id: wifiPill; anchors.verticalCenter: parent.verticalCenter; key: "wifi"
                        icon: root.wifiOn ? "wifi" : "wifi_off"; accent: root.wifiOn ? theme.frost : theme.bad
                        }   // icon-only: SSID lives in the dropdown
                    Drop { screen: bar.screen
                        id: wifiDrop; host: wifiPill; visible: root.openPop === "wifi" && root.openBar === bar
                        cardW: 270; cardH: wifiCol.implicitHeight + 32
                        onVisibleChanged: if(!visible) root.wifiPwFor = ""
                        Column { id: wifiCol; anchors.fill: wifiDrop.card; anchors.margins: 12; spacing: 6
                            Row { width: parent.width
                                Text { text: "wi-fi"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                Item { width: parent.width - 90; height: 1 }
                                Sym { text: "refresh"; sz: 16; color: theme.sub; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: wifiScan.running = true } } }
                            Repeater { model: root.wifiList
                                delegate: Column { id: netRow; required property var modelData; width: parent.width; spacing: 4
                                    readonly property bool asking: root.wifiPwFor === netRow.modelData.ssid
                                    Rectangle { width: parent.width; height: 32; radius: 7
                                        color: netRow.modelData.active ? theme.a(theme.iris,0.2) : (netRow.asking ? theme.a(theme.iris,0.12) : (wm.containsMouse ? theme.a(theme.line,0.5) : "transparent"))
                                        Row { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 7
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: netRow.modelData.signal>66?"signal_wifi_4_bar":netRow.modelData.signal>33?"network_wifi_3_bar":"network_wifi_1_bar"; sz: 16; color: netRow.modelData.active?theme.iris:theme.frost }
                                            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width-70; elide: Text.ElideRight; text: netRow.modelData.ssid; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont }
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: netRow.modelData.active?"check":"lock"; sz: 12; color: netRow.modelData.active?theme.good:theme.faint; visible: netRow.modelData.secure||netRow.modelData.active } }
                                        MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: { if(netRow.modelData.active) return; if(netRow.asking) root.wifiPwFor=""; else root.wifiConnect(netRow.modelData.ssid, netRow.modelData.secure) } } }
                                    // inline password field for this network
                                    Row { width: parent.width; height: 32; visible: netRow.asking; spacing: 6
                                        Rectangle { width: parent.width-40; height: 30; radius: 7; color: theme.a(theme.line,0.5); border.width: 1; border.color: pwIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                            TextInput { id: pwIn; anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; verticalAlignment: TextInput.AlignVCenter
                                                echoMode: TextInput.Password; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont; clip: true; focus: netRow.asking
                                                onAccepted: root.wifiJoin(netRow.modelData.ssid, text)
                                                Text { anchors.verticalCenter: parent.verticalCenter; visible: pwIn.text===""; text: "password ↵"; color: theme.faint; font.pixelSize: 12; font.family: root.cfgFont } } }
                                        Rectangle { width: 34; height: 30; radius: 7; color: jm.containsMouse?theme.iris:theme.a(theme.iris,0.25); border.width: 1; border.color: theme.iris
                                            Sym { anchors.centerIn: parent; text: "login"; sz: 15; color: jm.containsMouse?theme.bg:theme.frost }
                                            MouseArea { id: jm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.wifiJoin(netRow.modelData.ssid, pwIn.text) } } } } }
                            Text { visible: root.wifiList.length===0; text: "scanning…"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont } } }

                    // ---- BLUETOOTH ----
                    Pill { owner: bar; id: btPill; anchors.verticalCenter: parent.verticalCenter
                        visible: root.btAdapter !== null
                        key: root.btAdapter ? "bt" : ""
                        icon: (!root.btAdapter || !root.btAdapter.enabled) ? "bluetooth_disabled" : (root.btActive ? "bluetooth_connected" : (root.btAdapter.discovering ? "bluetooth_searching" : "bluetooth"))
                        accent: root.btActive ? theme.iris : ((root.btAdapter && root.btAdapter.enabled) ? theme.frost : theme.faint)
                        value: root.btActive ? root.btName(root.btActive) : "" }
                    Drop { screen: bar.screen
                        id: btDrop; host: btPill; visible: root.openPop === "bt" && root.openBar === bar
                        cardW: 280; cardH: btCol.implicitHeight + 32
                        Column { id: btCol; anchors.fill: btDrop.card; anchors.margins: 12; spacing: 7
                            Row { width: parent.width; height: 22
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "bluetooth"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                                Item { width: parent.width - 150; height: 1 }
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: (root.btAdapter&&root.btAdapter.discovering)?"sync":"search"; sz: 15; color: theme.sub
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.discovering = !root.btAdapter.discovering } }
                                Item { width: 10; height: 1 }
                                // power toggle
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 38; height: 20; radius: 10
                                    color: (root.btAdapter&&root.btAdapter.enabled)?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: theme.a(theme.iris,0.3)
                                    Rectangle { width: 15; height: 15; radius: 8; color: theme.frost; anchors.verticalCenter: parent.verticalCenter
                                        x: (root.btAdapter&&root.btAdapter.enabled)?21:3; Behavior on x { NumberAnimation { duration: 130 } } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if(root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled } } }
                            Repeater { model: root.btDevices
                                delegate: Rectangle { required property var modelData; width: parent.width; height: 34; radius: 7
                                    color: modelData.connected ? theme.a(theme.iris,0.2) : (dm.containsMouse ? theme.a(theme.line,0.5) : "transparent")
                                    Row { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 7
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: root.btIcon(modelData); sz: 16; color: modelData.connected?theme.iris:theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - (modelData.batteryAvailable?96:56); elide: Text.ElideRight; text: root.btName(modelData); color: theme.text; font.pixelSize: 12; font.family: root.cfgFont }
                                        Text { anchors.verticalCenter: parent.verticalCenter; visible: modelData.batteryAvailable; text: Math.round((modelData.battery||0)*100)+"%"; color: theme.sub; font.pixelSize: 10; font.family: root.cfgFont }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: modelData.connected; text: "check"; sz: 14; color: theme.good }
                                        Sym { anchors.verticalCenter: parent.verticalCenter; visible: modelData.pairing; text: "sync"; sz: 14; color: theme.warn } }
                                    MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { if(modelData.connected) modelData.disconnect(); else modelData.connect() } } } }
                            Text { visible: root.btDevices.length===0; text: (root.btAdapter&&root.btAdapter.enabled)?"tap search to scan…":"bluetooth is off"; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont } } }

                    // ---- VOLUME ----
                    Pill { owner: bar; id: volPill; anchors.verticalCenter: parent.verticalCenter; key: "vol"
                        readonly property var au: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
                        readonly property int vol: au ? Math.round(au.volume*100) : 0
                        icon: !au||au.muted ? "volume_off" : vol<34?"volume_mute":vol<67?"volume_down":"volume_up"
                        accent: (au&&au.muted)?theme.faint:theme.frost
                        value: au ? (au.muted?"muted":vol+"%") : "—"
                        onRightClicked: { if(au) au.muted = !au.muted }
                        onScrolled: (dy)=>{ if(!au) return; au.muted=false; au.volume=Math.max(0,Math.min(1,au.volume+(dy>0?0.05:-0.05))) } }
                    Drop { screen: bar.screen
                        id: volDrop; host: volPill; visible: root.openPop === "vol" && root.openBar === bar
                        cardW: 280; cardH: volCol.implicitHeight + 32
                        Column { id: volCol; anchors.fill: volDrop.card; anchors.margins: 12; spacing: 9
                            Row { width: parent.width; spacing: 9
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: (volPill.au&&volPill.au.muted)?"volume_off":"volume_up"; sz: 19
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if(volPill.au) volPill.au.muted=!volPill.au.muted } }
                                Slider { anchors.verticalCenter: parent.verticalCenter; width: parent.width-90
                                    value: volPill.au ? volPill.au.volume : 0
                                    onMoved: (v)=>{ if(volPill.au){ volPill.au.muted=false; volPill.au.volume=v } } }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: volPill.vol+"%"; color: theme.sub; font.pixelSize: 12; font.family: root.cfgFont; width: 34; horizontalAlignment: Text.AlignRight } }
                            Text { text: "output"; color: theme.faint; font.pixelSize: 10; font.family: root.cfgFont }
                            Repeater { model: root.sinks
                                delegate: Rectangle { required property var modelData; readonly property bool cur: Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.id===modelData.id
                                    width: parent.width; height: 30; radius: 7
                                    color: cur ? theme.a(theme.iris,0.2) : (sm.containsMouse?theme.a(theme.line,0.5):"transparent")
                                    Row { anchors.fill: parent; anchors.leftMargin: 8; spacing: 7
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: cur?"radio_button_checked":"radio_button_unchecked"; sz: 15; color: cur?theme.iris:theme.faint }
                                        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width-40; elide: Text.ElideRight; text: root.nodeName(modelData); color: theme.text; font.pixelSize: 12; font.family: root.cfgFont } }
                                    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Pipewire.preferredDefaultAudioSink = modelData } } } } }

                    // ---- BATTERY ----
                    Pill { owner: bar; id: batPill; anchors.verticalCenter: parent.verticalCenter
                        readonly property var dev: UPower.displayDevice
                        readonly property bool charging: !UPower.onBattery
                        readonly property int pct: dev ? Math.round(dev.percentage*100) : 0
                        visible: dev && dev.isLaptopBattery
                        key: visible ? "bat" : ""
                        icon: charging?"battery_charging_full":pct>=90?"battery_full":pct>=60?"battery_5_bar":pct>=35?"battery_3_bar":pct>=15?"battery_1_bar":"battery_alert"
                        value: pct+"%"; accent: charging?theme.good:pct<=20?theme.bad:theme.frost }
                    Drop { screen: bar.screen
                        id: batDrop; host: batPill; visible: root.openPop === "bat" && root.openBar === bar
                        cardW: 220; cardH: batCol.implicitHeight + 32
                        Column { id: batCol; anchors.fill: batDrop.card; anchors.margins: 12; spacing: 6
                            Text { text: "power profile"; color: theme.iris; font.pixelSize: 11; font.family: root.cfgFont; font.bold: true }
                            Repeater { model: [{k:"performance",i:"speed"},{k:"balanced",i:"balance"},{k:"power-saver",i:"eco"}]
                                delegate: Rectangle { required property var modelData; readonly property bool cur: root.powerProfile===modelData.k
                                    width: parent.width; height: 32; radius: 7
                                    color: cur ? theme.a(theme.iris,0.2) : (bm.containsMouse?theme.a(theme.line,0.5):"transparent")
                                    Row { anchors.fill: parent; anchors.leftMargin: 8; spacing: 8
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 17; color: cur?theme.iris:theme.frost }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.k; color: theme.text; font.pixelSize: 12; font.family: root.cfgFont } }
                                    MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setProfile(modelData.k) } } } } }

                    // ---- CLOCK ----
                    Pill { owner: bar; id: clockPill; anchors.verticalCenter: parent.verticalCenter; key: "cal"; icon: "schedule"
                        value: Qt.formatDateTime(clock.date,"ddd d MMM · HH:mm"); accent: theme.iris }
                    Drop { screen: bar.screen
                        id: calDrop; host: clockPill; visible: root.openPop === "cal" && root.openBar === bar
                        cardW: 250; cardH: calCol.implicitHeight + 32
                        Column { id: calCol; anchors.fill: calDrop.card; anchors.margins: 14; spacing: 10
                            property var dt: clock.date
                            property int yr: dt.getFullYear()
                            property int mo: dt.getMonth()
                            property int today: dt.getDate()
                            property int lead: new Date(yr, mo, 1).getDay()
                            property var days: { var arr=[]; var n=new Date(yr, mo+1, 0).getDate(); for(var i=1;i<=n;i++) arr.push(i); return arr }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(clock.date,"MMMM yyyy"); color: theme.frost; font.pixelSize: 14; font.family: root.cfgFont; font.bold: true }
                            Grid { anchors.horizontalCenter: parent.horizontalCenter; columns: 7; spacing: 4
                                Repeater { model: ["S","M","T","W","T","F","S"]
                                    delegate: Text { required property var modelData; width: 28; horizontalAlignment: Text.AlignHCenter; text: modelData; color: theme.faint; font.pixelSize: 11; font.family: root.cfgFont } }
                                Repeater { model: calCol.lead
                                    delegate: Item { width: 28; height: 24 } }
                                Repeater { model: calCol.days
                                    delegate: Rectangle { required property var modelData; readonly property bool isToday: modelData===calCol.today
                                        width: 28; height: 24; radius: 7; color: isToday ? theme.iris : "transparent"
                                        Text { anchors.centerIn: parent; text: parent.modelData; color: parent.isToday ? theme.bg : theme.text; font.pixelSize: 12; font.family: root.cfgFont; font.bold: parent.isToday } } } } } }

                    // ---- POWER (very end) ----
                    Pill { owner: bar; id: pwrPill; anchors.verticalCenter: parent.verticalCenter; key: "pwr"; icon: "power_settings_new"; accent: theme.bad }
                    Drop { screen: bar.screen
                        id: pwrDrop; host: pwrPill; visible: root.openPop === "pwr" && root.openBar === bar
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
                            Repeater { model: [{i:"lock",l:"lock",c:"loginctl lock-session",col:theme.frost},
                                               {i:"bedtime",l:"suspend",c:"systemctl suspend",col:theme.frost},
                                               {i:"logout",l:"log out",c:"uwsm check is-active >/dev/null 2>&1 && uwsm stop || hyprctl dispatch exit",col:theme.frost},
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
                }
            }

            // register this bar's windows with the ONE shared focus grab at root —
            // a grab per bar fights the other monitors' grabs and insta-closes dropdowns
            Item { Component.onCompleted: { root.grabWins = root.grabWins.concat([bar, wxDrop, wifiDrop, btDrop, volDrop, batDrop, calDrop, pwrDrop, notifDrop, mprisDrop, trayDrop]) } }
        }
    }

    // ===== on-screen notification popups (top-right, under the bar) =====
    PanelWindow {
        id: notifWin
        anchors { top: true; right: true }
        margins { top: 50; right: 12 }
        implicitWidth: 370
        implicitHeight: Math.max(1, popCol.implicitHeight)
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "sea-shell:notif"
        exclusionMode: ExclusionMode.Ignore
        visible: popupModel.count > 0
        mask: Region { item: popCol }
        Column {
            id: popCol; anchors.top: parent.top; anchors.right: parent.right; width: parent.width; spacing: 8
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
        anchors { bottom: true; left: true; right: true }
        margins { bottom: 80 }
        implicitHeight: 60
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-shell:osd"
        exclusionMode: ExclusionMode.Ignore
        visible: root.osdKind !== ""
        mask: Region { item: osdCard }
        Rectangle {
            id: osdCard
            anchors.centerIn: parent
            width: 250; height: 54; radius: root.cfgRadius
            color: theme.a(theme.bg, root.dropOpacity); border.width: 1; border.color: theme.a(theme.iris,0.34)
            Row { anchors.fill: parent; anchors.margins: 16; spacing: 13
                Sym { anchors.verticalCenter: parent.verticalCenter; text: root.osdIcon; sz: 24; color: theme.frost }
                Column { anchors.verticalCenter: parent.verticalCenter; width: parent.width-52; spacing: 6
                    Row { width: parent.width
                        Text { text: root.osdKind==="vol" ? "volume" : "brightness"; color: theme.sub; font.pixelSize: 11; font.family: root.cfgFont }
                        Item { width: parent.width - 80; height: 1 }
                        Text { text: Math.round(root.osdVal*100)+"%"; color: theme.frost; font.pixelSize: 11; font.family: root.cfgFont } }
                    Rectangle { width: parent.width; height: 6; radius: 3; color: theme.a(theme.line,0.85)
                        Rectangle { width: parent.width*Math.max(0,Math.min(1,root.osdVal)); height: parent.height; radius: 3; color: theme.iris
                            Behavior on width { NumberAnimation { duration: 90 } } } }
                }
            }
        }
    }
}
