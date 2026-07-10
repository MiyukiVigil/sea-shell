// sea-shell — resident app launcher, lives inside the bar process (no spawn delay).
// Open via IPC:  qs -c sea-shell ipc call launcher toggle | clipboard
//
//   type        fuzzy-search apps (ranked by how often/recently you launch them)
//   >cmd        run a shell command        ⏎ detached · CTRL+⏎ in a kitty window
//   =expr       calculator (also auto-detects "2+2")   ⏎ copies the result
//   ~query      file search in $HOME (fd)  ⏎ opens with xdg-open
//   ?query      web search                 ⏎ opens the browser
//   ;query      clipboard history (cliphist)           ⏎ copies the entry
//   :           system actions (settings · wallpaper · power · lock · …)
//
// Esc / click-outside closes. ↑↓/Tab navigate · PgUp/PgDn jump · ALT+1..9 quick-launch.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick

Scope {
    id: root
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgRadius: 14
    property string query: ""
    property int sel: 0
    property var results: []
    property var fileHits: []      // async fd results for ~ mode
    property var clipLines: []     // cached `cliphist list` lines for ; mode
    property var hist: ({})        // app id → {n: launches, t: last epoch} (frecency)
    property string histPath: ""
    property bool shown: false     // logical open state
    property bool held: false      // keep the window mapped a few frames past close (no unmap flash)

    function open(prefix) {
        clipProc.running = true                     // refresh clipboard cache on every open
        apProc.running = true                       // re-read accent + light/dark each open
        field.text = prefix; root.query = prefix; root.sel = 0
        root.shown = true
    }
    function toggle() { root.shown ? close() : open("") }
    function close() { root.shown = false }

    // CLOSE IS INSTANT: the card opacity is zeroed on the same frame (see card.openF),
    // and — paired with `layerrule = animation none` on sea-shell:launcher — the layer
    // surface can't fade its last buffer, so the result text never lingers on close.
    // We hold the window mapped ~90ms, then unmap and only THEN clear the query, so the
    // list never repopulates while still on screen.
    onShownChanged: { if (shown) { held = true; holdTimer.stop() } else holdTimer.restart() }
    Timer { id: holdTimer; interval: 90; onTriggered: { root.held = false; field.text = ""; root.query = "" } }

    QtObject {
        id: theme
        readonly property bool light: root.cfgLight
        readonly property color _acc: root.accent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    light ? Qt.hsla(_ah, 0.20, 0.945, 1) : Qt.hsla(_ah, 0.36, 0.070, 1)
        readonly property color line:  light ? Qt.hsla(_ah, 0.16, 0.780, 1) : Qt.hsla(_ah, 0.24, 0.205, 1)
        readonly property color text:  light ? "#0c1520" : "#e2e9f4"
        readonly property color sub:   light ? "#2c4256" : "#a6b6cf"
        readonly property color faint: light ? "#48606f" : "#6f8099"
        readonly property color iris:  light ? Qt.darker(root.accent, 2.4)  : root.accent
        readonly property color frost: light ? Qt.darker(root.accent, 1.7)  : Qt.lighter(root.accent, 1.22)
        readonly property color warn:  light ? "#b9820f" : "#f4c542"
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // accent follows the bar's appearance config
    Process { id: apProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.radius!==undefined) root.cfgRadius=j.radius; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

    // ---------- frecency history ----------
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; cat \"$d/launcher-history.json\" 2>/dev/null; printf '\\n%s/launcher-history.json' \"$d\" >&2"]
        stdout: StdioCollector { id: hOut; onStreamFinished: { try { root.hist = JSON.parse(hOut.text) } catch(e) { root.hist = {} } } }
        stderr: StdioCollector { id: hErr; onStreamFinished: root.histPath = hErr.text.trim() } }
    function frecency(id) {
        var h = root.hist[id]; if (!h) return 0;
        var days = (Date.now()/1000 - h.t) / 86400;              // gentle decay: recent use matters
        return h.n * (days < 1 ? 3 : days < 7 ? 2 : days < 30 ? 1 : 0.4);
    }
    function bump(id) {
        var h = root.hist; h[id] = { n: (h[id] ? h[id].n : 0) + 1, t: Math.floor(Date.now()/1000) };
        // write via base64 → no shell-quoting pitfalls with arbitrary desktop ids
        if (root.histPath !== "")
            Quickshell.execDetached(["sh","-c","echo '" + Qt.btoa(JSON.stringify(h)) + "' | base64 -d > \"" + root.histPath + "\""]);
    }

    // ---------- fuzzy matching (subsequence + bonuses, returns match positions) ----------
    function fuzzy(q, s) {
        var ql = q.toLowerCase(), sl = s.toLowerCase();
        var sub = sl.indexOf(ql);
        if (sub >= 0) {                                          // exact substring beats scattered matches
            var pos = []; for (var i=0;i<ql.length;i++) pos.push(sub+i);
            return { score: 100 - sub*2 + (sub===0 ? 40 : 0) + ql.length*3, pos: pos };
        }
        var score = 0, pi = 0, last = -2, positions = [];
        for (var j=0; j<sl.length && pi<ql.length; j++) {
            if (sl[j] !== ql[pi]) continue;
            var bonus = 1;
            if (j === last+1) bonus += 3;                        // consecutive run
            if (j === 0 || " -_./".indexOf(sl[j-1]) >= 0) bonus += 4;   // word boundary
            score += bonus; positions.push(j); last = j; pi++;
        }
        return pi === ql.length ? { score: score, pos: positions } : null;
    }
    function esc(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;") }
    function highlight(s, pos) {
        if (!pos || !pos.length) return esc(s);
        var out = "", set = {}; pos.forEach(p => set[p]=1);
        for (var i=0;i<s.length;i++) out += set[i] ? "<font color=\"" + root.accent + "\"><b>" + esc(s[i]) + "</b></font>" : esc(s[i]);
        return out;
    }

    // ---------- calculator ----------
    function calc(expr) {
        var fns = /\b(sqrt|cbrt|sinh|cosh|tanh|asin|acos|atan2|atan|sin|cos|tan|log10|log2|log|ln|abs|round|floor|ceil|pow|min|max|exp|hypot|sign|trunc|pi|e)\b/g;
        if (!/^[0-9+\-*/%().,\s]*$/.test(expr.replace(fns, ""))) return null;
        try {
            var v = new Function("with(Math){var ln=log,log=log10,pi=PI,e=E;return(" + expr.replace(/\^/g,"**") + ")}")();
            if (typeof v !== "number" || !isFinite(v)) return null;
            return String(Math.abs(v) < 1e15 ? Math.round(v*1e10)/1e10 : v);
        } catch(err) { return null }
    }

    // ---------- system actions (: mode) ----------
    readonly property var sysActions: [
        {l:"Settings",        s:"sea-shell control center",  i:"tune",               c:"~/.config/quickshell/sea-shell/sea-toggle.sh settings"},
        {l:"Wallpaper",       s:"wallpaper picker",         i:"wallpaper",          c:"~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"},
        {l:"Keybinds",        s:"cheat-sheet",              i:"keyboard",           c:"~/.config/quickshell/sea-shell/sea-toggle.sh keybinds"},
        {l:"Power menu",      s:"lock · suspend · off",     i:"power_settings_new", c:"~/.config/quickshell/sea-shell/sea-toggle.sh power"},
        {l:"Lock",            s:"loginctl lock-session",    i:"lock",               c:"~/.config/quickshell/sea-shell/sea-lock.sh"},
        {l:"Suspend",         s:"systemctl suspend",        i:"bedtime",            c:"systemctl suspend"},
        {l:"Reboot",          s:"systemctl reboot",         i:"restart_alt",        c:"systemctl reboot", warn:true},
        {l:"Shut down",       s:"systemctl poweroff",       i:"mode_off_on",        c:"systemctl poweroff", warn:true},
        {l:"Log out",         s:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch exit; sleep 3; loginctl terminate-session self; }",    i:"logout",             c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch exit; sleep 3; loginctl terminate-session self; }", warn:true},
        {l:"Reload Hyprland", s:"hyprctl reload",           i:"refresh",            c:"hyprctl reload"},
        {l:"Restart bar",     s:"quickshell sea-shell",      i:"replay",             c:"pkill -xf 'qs -c sea-shell'; sleep 0.3; hyprctl dispatch exec 'qs -c sea-shell'"}
    ]

    // ---------- async file search (~ mode, debounced) ----------
    Timer { id: fdDebounce; interval: 140; onTriggered: {
        var q = root.query.slice(1).trim();
        if (q === "") { root.fileHits = []; return }
        fdProc.running = false;
        fdProc.command = ["sh","-c","cd \"$HOME\" && fd -i --max-results 28 -E '.cache' -E 'node_modules' -- " + "'" + q.replace(/'/g,"'\\''") + "'" + " 2>/dev/null"];
        fdProc.running = true;
    } }
    Process { id: fdProc
        stdout: StdioCollector { id: fdOut; onStreamFinished: {
            var out = [];
            fdOut.text.split("\n").forEach(l => { if (l.trim() !== "") out.push(l) });
            root.fileHits = out; root.refresh();
        } } }

    // ---------- clipboard history (; mode) ----------
    Process { id: clipProc; command: ["sh","-c","cliphist list 2>/dev/null | head -80"]
        stdout: StdioCollector { id: clipOut; onStreamFinished: {
            var out = [];
            clipOut.text.split("\n").forEach(l => { if (l.indexOf("\t") > 0) out.push(l) });
            root.clipLines = out; if (root.query.startsWith(";")) root.refresh();
        } } }

    // ---------- build the result list for the current query ----------
    function refresh() {
        var q = root.query, out = [], i;
        if (q.startsWith(">")) {
            var cmd = q.slice(1).trim();
            if (cmd !== "") out = [
                {type:"run",  title:esc(cmd),  sub:"run command  ·  ⏎ detached", mi:"terminal", exec:cmd},
                {type:"term", title:esc(cmd),  sub:"run in kitty  ·  stays open", mi:"monitor",  exec:cmd}];
        } else if (q.startsWith("=")) {
            var r = calc(q.slice(1));
            out = [{type:"calc", title: r !== null ? "= " + esc(r) : "…", sub: r !== null ? "⏎ copy result" : "keep typing", mi:"calculate", exec:r}];
        } else if (q.startsWith("~") || q.startsWith("/")) {
            fdDebounce.restart();
            for (i=0;i<root.fileHits.length;i++) {
                var p = root.fileHits[i];
                out.push({type:"file", title:esc(p.split("/").pop()), sub:"~/" + esc(p), mi: p.indexOf(".")<0 ? "folder" : "description", exec:p});
            }
            if (!out.length) out = [{type:"hint", title:"search files in ~", sub:"powered by fd — keep typing", mi:"travel_explore"}];
        } else if (q.startsWith(";")) {
            var cq = q.slice(1).trim();
            for (i=0;i<root.clipLines.length;i++) {
                var line = root.clipLines[i];
                var tab = line.indexOf("\t"), cid = line.slice(0,tab), body = line.slice(tab+1);
                var img = body.indexOf("[[ binary data") === 0;
                var label = img ? body.replace("[[ binary data","image ·").replace("]]","").trim() : body;
                var m = cq==="" ? {score:0,pos:[]} : fuzzy(cq, label);
                if (!m) continue;
                out.push({type:"clip", title: img ? esc(label) : highlight(label, m.pos),
                          sub: img ? "⏎ copy image" : "⏎ copy text", mi: img ? "image" : "content_paste", exec: cid});
            }
            if (!out.length) out = [{type:"hint", title:"clipboard history", sub: root.clipLines.length ? "no match" : "history is empty", mi:"content_paste"}];
        } else if (q.startsWith("?")) {
            var w = q.slice(1).trim();
            out = [{type:"web", title: w==="" ? "search the web" : esc(w), sub:"DuckDuckGo  ·  ⏎ opens browser", mi:"travel_explore", exec:w}];
        } else if (q.startsWith(":")) {
            var aq = q.slice(1).trim();
            root.sysActions.forEach(a => {
                var m = aq==="" ? {score:0,pos:[]} : fuzzy(aq, a.l);
                if (m) out.push({type:"act", title:highlight(a.l, m.pos), sub:a.s, mi:a.i, exec:a.c, warn:!!a.warn});
            });
        } else {
            // auto-calculator on plain math ("2+2", "(9*9)/4")
            if (/^[0-9(.\-]/.test(q) && /[\d)]/.test(q)) { var cv = calc(q); if (cv !== null) out.push({type:"calc", title:"= "+esc(cv), sub:"⏎ copy result", mi:"calculate", exec:cv}); }
            var apps = DesktopEntries.applications.values, scored = [];
            for (i=0;i<apps.length;i++) {
                var a = apps[i]; if (a.noDisplay) continue;
                var hay = [a.name, a.genericName||"", (a.keywords||[]).join(" "), a.comment||"", (a.execString||"").split(" ")[0].split("/").pop()];
                if (q === "") { scored.push({e:a, sc:0, pos:[]}); continue }
                var best = null, bi = 0;
                for (var h=0;h<hay.length;h++) {
                    var mm = fuzzy(q, hay[h]); if (!mm) continue;
                    var sc = mm.score * (h===0 ? 3 : h===1 ? 2 : 1);   // name > generic > keywords/comment/bin
                    if (!best || sc > best.score) { best = {score:sc, pos:mm.pos}; bi = h }
                }
                if (best) scored.push({e:a, sc:best.score, pos: bi===0 ? best.pos : []});
            }
            scored.sort((x,y) => (y.sc + frecency(y.e.id)*4) - (x.sc + frecency(x.e.id)*4) || x.e.name.localeCompare(y.e.name));
            scored.forEach(s => out.push({type:"app", title:highlight(s.e.name, s.pos),
                sub: esc(s.e.genericName || s.e.comment || ""), entry:s.e, fav: frecency(s.e.id) > 2}));
        }
        root.results = out;
        root.sel = 0;
    }
    onQueryChanged: refresh()
    Component.onCompleted: refresh()
    // DesktopEntries scans .desktop files asynchronously — refresh when the list lands
    Connections { target: DesktopEntries.applications; ignoreUnknownSignals: true
        function onValuesChanged() { root.refresh() } }

    // ---------- activate ----------
    function activate(idx) {
        var r = root.results[idx]; if (!r || r.type === "hint") return;
        if (r.type === "app")  { bump(r.entry.id); r.entry.execute() }
        if (r.type === "run")  Quickshell.execDetached(["sh","-c",r.exec])
        if (r.type === "term") Quickshell.execDetached(["kitty","--hold","sh","-c",r.exec])
        if (r.type === "calc") Quickshell.execDetached(["sh","-c","printf %s '" + r.exec.replace(/'/g,"") + "' | wl-copy"])
        if (r.type === "file") Quickshell.execDetached(["sh","-c","xdg-open \"$HOME/\"'" + r.exec.replace(/'/g,"'\\''") + "'"])
        if (r.type === "clip") Quickshell.execDetached(["sh","-c","cliphist decode " + r.exec + " | wl-copy"])
        if (r.type === "web")  { if (r.exec==="") return; Quickshell.execDetached(["xdg-open","https://duckduckgo.com/?q=" + encodeURIComponent(r.exec)]) }
        if (r.type === "act")  Quickshell.execDetached(["sh","-c",r.exec])
        root.close();
    }
    function move(d) {
        if (!root.results.length) return;
        root.sel = Math.min(root.results.length-1, Math.max(0, root.sel + d));
        list.positionViewAtIndex(root.sel, ListView.Contain);
    }

    readonly property string modeBadge: query.startsWith(">") ? "RUN" : query.startsWith("=") ? "CALC"
        : (query.startsWith("~")||query.startsWith("/")) ? "FILES" : query.startsWith("?") ? "WEB"
        : query.startsWith(";") ? "CLIP" : query.startsWith(":") ? "SYS" : "APPS"

    PanelWindow {
        id: win
        visible: root.shown || root.held
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:launcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        onVisibleChanged: if (visible) field.forceActiveFocus()

        // dim scrim — alpha stays under the launcher's ignore_alpha (0.42) so the desktop
        // behind it is only dimmed, not blurred; only the card itself frosts. Fades with
        // the card so close is instant (no lingering dim).
        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.35); opacity: card.openF
            MouseArea { anchors.fill: parent; onClicked: root.close() } }

        Rectangle {
            id: card
            width: 640
            height: head.height + 12 + Math.min(8, Math.max(1, root.results.length)) * 52 + hints.height + 26
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.16
            radius: root.cfgRadius
            // glassy matte — translucent so the compositor blur (sea-shell:launcher
            // layerrule) frosts the wallpaper behind it; soft cool tint, no gloss.
            color: theme.a(theme.bg, theme.light ? 0.60 : 0.52)
            border.width: 1; border.color: theme.a(theme.frost, 0.26)
            Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

            // open fades + tiles in; close zeroes openF on the same frame → instant, no
            // lingering. (An imperative Animation.start() in Component.onCompleted makes
            // quickshell 0.3 exit silently on layer surfaces, so we drive it via Connections.)
            property real openF: 0.0
            opacity: openF
            scale: 0.975 + 0.025 * openF
            NumberAnimation { id: cardIn; target: card; property: "openF"; to: 1.0
                duration: 200; easing.type: Easing.OutCubic }
            Connections { target: root; function onShownChanged() {
                if (root.shown) cardIn.restart(); else { cardIn.stop(); card.openF = 0.0 } } }

            // frosted-glass rim: a whisper of light at the top edge, fading out — matte,
            // not a glossy sheen. Sits above the fill, below the content.
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0;  color: Qt.rgba(1, 1, 1, theme.light ? 0.10 : 0.05) }
                    GradientStop { position: 0.35; color: "transparent" }
                }
            }
            Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: parent.radius; rightMargin: parent.radius }
                height: 1; color: Qt.rgba(1, 1, 1, theme.light ? 0.45 : 0.12) }

            // ---------- search field ----------
            Item {
                id: head
                width: parent.width; height: 54
                Text { id: lens; text: "search"; font.family: "Material Symbols Outlined"; font.pixelSize: 20
                    color: theme.iris; anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter } }
                TextInput {
                    id: field
                    anchors { left: lens.right; leftMargin: 12; right: badge.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    color: theme.text; font.pixelSize: 16; font.family: "monospace"
                    clip: true
                    onTextChanged: root.query = text
                    Text { text: "apps  ·  >run  =calc  ~files  ?web  ;clip  :sys"; visible: field.text===""
                        color: theme.faint; font.pixelSize: 14; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                    Keys.onEscapePressed: root.close()
                    Keys.onReturnPressed: (e)=> {
                        if ((e.modifiers & Qt.ControlModifier) && root.results[root.sel] && root.results[root.sel].type==="run")
                            { root.activate(root.sel+1); return }   // CTRL+⏎ on a command → kitty row
                        root.activate(root.sel) }
                    Keys.onPressed: (e)=> {
                        if (e.key===Qt.Key_Down || (e.key===Qt.Key_Tab && !(e.modifiers&Qt.ShiftModifier))) { root.move(1); e.accepted=true }
                        else if (e.key===Qt.Key_Up || e.key===Qt.Key_Backtab) { root.move(-1); e.accepted=true }
                        else if (e.key===Qt.Key_PageDown) { root.move(8); e.accepted=true }
                        else if (e.key===Qt.Key_PageUp)   { root.move(-8); e.accepted=true }
                        else if (e.modifiers & Qt.AltModifier && e.key>=Qt.Key_1 && e.key<=Qt.Key_9)
                            { root.activate(e.key-Qt.Key_1); e.accepted=true }
                    }
                }
                Rectangle {
                    id: badge
                    anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                    width: badgeTxt.width + 16; height: 22; radius: 11
                    color: theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                    Text { id: badgeTxt; anchors.centerIn: parent; text: root.modeBadge
                        color: theme.frost; font.pixelSize: 10; font.family: "monospace"; font.bold: true }
                }
                Rectangle { width: parent.width - 28; height: 1; color: theme.a(theme.iris, 0.22)
                    anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter } }
            }

            // ---------- results ----------
            ListView {
                id: list
                anchors { top: head.bottom; topMargin: 6; left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8 }
                height: Math.min(8, Math.max(1, root.results.length)) * 52
                clip: true
                model: root.results
                interactive: true
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width; height: 52; radius: 10
                    color: index===root.sel ? theme.a(theme.iris, 0.15) : rowMa.containsMouse ? theme.a(theme.iris, 0.07) : "transparent"
                    // icon: real app icon when we have one, Material glyph otherwise, letter-tile fallback
                    Item {
                        id: ic; width: 30; height: 30
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        property string ip: modelData.entry ? Quickshell.iconPath(modelData.entry.icon, true) : ""
                        IconImage { anchors.fill: parent; visible: ic.ip!==""; source: ic.ip }
                        Text { anchors.centerIn: parent; visible: ic.ip==="" && !!modelData.mi; text: modelData.mi||""
                            font.family: "Material Symbols Outlined"; font.pixelSize: 22
                            color: modelData.warn ? theme.bad : theme.iris }
                        Rectangle { anchors.fill: parent; radius: 8; visible: ic.ip==="" && !modelData.mi
                            color: theme.a(theme.iris,0.18); border.width: 1; border.color: theme.a(theme.iris,0.4)
                            Text { anchors.centerIn: parent; text: (modelData.entry?modelData.entry.name:"?").charAt(0).toUpperCase()
                                color: theme.frost; font.pixelSize: 15; font.bold: true; font.family: "monospace" } }
                    }
                    Column {
                        anchors { left: ic.right; leftMargin: 12; right: favStar.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 1
                        Text { width: parent.width; elide: Text.ElideRight; textFormat: Text.StyledText
                            text: modelData.title; color: theme.text; font.pixelSize: 14; font.family: "monospace" }
                        Text { width: parent.width; elide: Text.ElideRight; visible: text!==""
                            text: modelData.sub||""; color: theme.faint; font.pixelSize: 11; font.family: "monospace" }
                    }
                    Text { id: favStar
                        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        text: modelData.fav ? "star" : (index===root.sel ? "keyboard_return" : "")
                        font.family: "Material Symbols Outlined"; font.pixelSize: 14
                        color: modelData.fav ? theme.warn : theme.faint }
                    MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onEntered: root.sel = index
                        onClicked: root.activate(index) }
                }
            }

            // ---------- footer hints ----------
            Item {
                id: hints
                width: parent.width; height: 24
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                Text { anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                    text: root.results.length + (root.results.length===1 ? " result" : " results")
                    color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                Text { anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                    text: "↑↓ move · ⏎ open · alt+1–9 quick · esc close"
                    color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
            }
        }
    }
}
