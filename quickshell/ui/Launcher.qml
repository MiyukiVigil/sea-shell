// sea-shell — resident app launcher, lives inside the bar process (no spawn delay).
// Open via IPC:  qs -c sea-shell ipc call launcher toggle | clipboard
//
//   type        fuzzy-search apps (ranked by how often/recently you launch them)
//   >cmd        run a shell command        ⏎ detached · CTRL+⏎ in a kitty window
//   =expr       calculator (also auto-detects "2+2")   ⏎ copies the result
//   ~query      file search in $HOME (fd)  ⏎ opens with xdg-open
//   ?query      web search                 ⏎ opens the browser
//   ;query      clipboard history (cliphist)           ⏎ copies the entry
//   .query      emoji picker (search by name)          ⏎ copies the emoji
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
    property real cfgScale: 0     // 0 = auto (per-monitor), >0 = manual UI-scale multiplier
    // matches shell.qml uiFor(): ≤1440p untouched, grows past it, capped at 2.5×
    function uiFor(scr) {
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    property string query: ""
    property int sel: 0
    property var results: []
    property var fileHits: []      // async fd results for ~ mode
    property var clipLines: []     // cached `cliphist list` lines for ; mode
    readonly property string clipThumbDir: "/tmp/sea-clip-thumbs"  // decoded image previews, keyed by cliphist id
    property int clipThumbTick: 0  // bumps when thumbs finish generating → image rows reload their source
    property var hist: ({})        // app id → {n: launches, t: last epoch} (frecency)
    property string histPath: ""
    property bool shown: false     // logical open state
    property bool held: false      // keep the window mapped a few frames past close (no unmap flash)

    function open(prefix) {
        clipProc.running = true                     // refresh clipboard cache on every open
        clipThumbProc.running = true                // (re)generate image previews for ; mode
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
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.radius!==undefined) root.cfgRadius=j.radius; if(j.scale!==undefined) root.cfgScale=j.scale; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

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

    // ---------- unit / currency / temp conversion ----------  ("10 km to mi", "72 f to c", "5 gb to mb")
    function parseConversion(q) {
        var m = q.toLowerCase().match(/^(-?\d+(?:\.\d+)?)\s*([a-z°\/]+)\s+to\s+([a-z°\/]+)$/);
        if (!m) return null;
        var val = parseFloat(m[1]), from = m[2], to = m[3];

        // temperatures (non-linear — normalise through Celsius)
        var temp = { c: ["c","°c","celsius"], f: ["f","°f","fahrenheit"], k: ["k","kelvin"] };
        function tkind(u) { for (var kk in temp) if (temp[kk].indexOf(u) >= 0) return kk; return null; }
        var tf = tkind(from), tt = tkind(to);
        if (tf && tt) {
            var cc = tf === "c" ? val : tf === "f" ? (val - 32) * 5/9 : val - 273.15;
            var tr = tt === "c" ? cc : tt === "f" ? (cc * 9/5 + 32) : cc + 273.15;
            return tr.toFixed(1) + " " + (tt === "c" ? "°C" : tt === "f" ? "°F" : "K");
        }

        // linear units — factor to a base unit within each category
        var cats = [
            { u: { mm:0.001, cm:0.01, m:1, km:1000, in:0.0254, inch:0.0254, inches:0.0254, ft:0.3048, foot:0.3048, feet:0.3048, yd:0.9144, yard:0.9144, mi:1609.34, mile:1609.34, miles:1609.34, nmi:1852 } },
            { u: { mg:0.001, g:1, gram:1, grams:1, kg:1000, kilogram:1000, kilograms:1000, oz:28.3495, ounce:28.3495, ounces:28.3495, lb:453.592, lbs:453.592, pound:453.592, pounds:453.592, st:6350.29, stone:6350.29, ton:1e6, tonne:1e6, tonnes:1e6 } },
            { u: { ml:0.001, l:1, litre:1, liter:1, litres:1, liters:1, tsp:0.00492892, tbsp:0.0147868, cup:0.236588, cups:0.236588, pt:0.473176, pint:0.473176, qt:0.946353, quart:0.946353, gal:3.78541, gallon:3.78541, gallons:3.78541, floz:0.0295735 } },
            { u: { b:1, byte:1, bytes:1, kb:1e3, mb:1e6, gb:1e9, tb:1e12, pb:1e15, kib:1024, mib:1048576, gib:1073741824, tib:1099511627776, bit:0.125, bits:0.125, kbit:125, mbit:125000, gbit:125000000 } },
            { u: { "m/s":1, mps:1, kmh:0.277778, kph:0.277778, "km/h":0.277778, mph:0.44704, "mi/h":0.44704, knot:0.514444, knots:0.514444, kn:0.514444, fps:0.3048 } },
            { u: { ms:0.001, s:1, sec:1, secs:1, second:1, seconds:1, min:60, mins:60, minute:60, minutes:60, h:3600, hr:3600, hrs:3600, hour:3600, hours:3600, day:86400, days:86400, week:604800, weeks:604800, month:2629800, months:2629800, year:31557600, years:31557600 } }
        ];
        for (var i = 0; i < cats.length; i++) {
            var uu = cats[i].u;
            if (uu[from] !== undefined && uu[to] !== undefined)
                return (Math.round((val * uu[from] / uu[to]) * 10000) / 10000) + " " + to;
        }

        // currency (USD-base static rates — offline, approximate)
        var rates = { usd:1.0, eur:0.92, gbp:0.79, jpy:158.0, cad:1.36, aud:1.50, sgd:1.35, inr:83.3, cny:7.24, chf:0.88, nzd:1.64, mxn:17.0, brl:5.1, krw:1370, rub:90, zar:18.5, hkd:7.8, sek:10.6, nok:10.7, aed:3.67 };
        if (rates[from] !== undefined && rates[to] !== undefined)
            return ((val / rates[from]) * rates[to]).toFixed(2) + " " + to.toUpperCase();

        return null;
     }

    // ---------- emoji picker (. mode) — search a curated set by keyword, ⏎ copies ----------
    readonly property var emojiDB: [
        {e:"😀",k:"grinning smile happy face"},{e:"😄",k:"smile happy laugh"},{e:"😁",k:"grin beaming"},{e:"😂",k:"joy laugh tears lol funny"},{e:"🤣",k:"rofl rolling laughing"},
        {e:"😊",k:"blush smile happy"},{e:"🙂",k:"slight smile"},{e:"😉",k:"wink"},{e:"😍",k:"heart eyes love"},{e:"🥰",k:"love hearts adore"},{e:"😘",k:"kiss blow"},
        {e:"😎",k:"cool sunglasses"},{e:"🤩",k:"star struck excited wow"},{e:"🥳",k:"party celebrate hooray"},{e:"😏",k:"smirk"},{e:"😇",k:"angel innocent halo"},
        {e:"🙃",k:"upside down silly"},{e:"😌",k:"relieved calm"},{e:"😴",k:"sleep tired zzz"},{e:"🤤",k:"drool yum"},{e:"😐",k:"neutral meh"},{e:"😑",k:"expressionless"},
        {e:"🙄",k:"eye roll annoyed"},{e:"😒",k:"unamused meh"},{e:"😔",k:"sad pensive"},{e:"😞",k:"disappointed sad"},{e:"😢",k:"cry sad tear"},{e:"😭",k:"sob cry bawl"},
        {e:"😤",k:"huff triumph steam"},{e:"😠",k:"angry mad"},{e:"😡",k:"rage furious mad"},{e:"🤬",k:"cursing swearing angry"},{e:"🤯",k:"mind blown exploding"},
        {e:"😳",k:"flushed embarrassed shock"},{e:"🥵",k:"hot heat sweat"},{e:"🥶",k:"cold freezing"},{e:"😱",k:"scream shock fear"},{e:"😨",k:"fearful scared"},
        {e:"😰",k:"anxious sweat nervous"},{e:"🤔",k:"thinking hmm"},{e:"🤨",k:"raised eyebrow suspicious"},{e:"😬",k:"grimace awkward"},{e:"🤒",k:"sick ill fever"},
        {e:"🤕",k:"hurt injured bandage"},{e:"🤢",k:"nauseous sick gross"},{e:"🤮",k:"vomit puke sick"},{e:"🤧",k:"sneeze sick"},{e:"😷",k:"mask sick"},
        {e:"🥺",k:"pleading puppy eyes cute"},{e:"😅",k:"sweat smile nervous relief"},{e:"👍",k:"thumbs up like yes approve ok"},{e:"👎",k:"thumbs down dislike no"},
        {e:"👌",k:"ok perfect"},{e:"🤌",k:"pinched fingers italian"},{e:"✌️",k:"peace victory"},{e:"🤞",k:"fingers crossed luck"},{e:"🤟",k:"love you rock"},
        {e:"🤙",k:"call me hang loose shaka"},{e:"👏",k:"clap applause bravo"},{e:"🙌",k:"raised hands praise hooray"},{e:"🙏",k:"pray please thanks thank you"},
        {e:"🤝",k:"handshake deal agree"},{e:"💪",k:"muscle strong flex"},{e:"👀",k:"eyes look watch"},{e:"🫶",k:"heart hands love"},{e:"👋",k:"wave hi hello bye"},
        {e:"❤️",k:"heart love red"},{e:"🧡",k:"orange heart"},{e:"💛",k:"yellow heart"},{e:"💚",k:"green heart"},{e:"💙",k:"blue heart"},{e:"💜",k:"purple heart"},
        {e:"🖤",k:"black heart"},{e:"🤍",k:"white heart"},{e:"💔",k:"broken heart"},{e:"💕",k:"two hearts love"},{e:"💯",k:"hundred perfect keep it"},{e:"🔥",k:"fire lit hot flame"},
        {e:"✨",k:"sparkles shiny clean magic"},{e:"⭐",k:"star"},{e:"🌟",k:"glowing star"},{e:"⚡",k:"lightning bolt zap fast"},{e:"💥",k:"boom collision explode"},
        {e:"🎉",k:"party tada celebrate congrats"},{e:"🎊",k:"confetti party"},{e:"🎁",k:"gift present"},{e:"🏆",k:"trophy win winner champion"},{e:"🥇",k:"gold medal first"},
        {e:"✅",k:"check tick done yes correct"},{e:"❌",k:"cross x no wrong"},{e:"⚠️",k:"warning caution"},{e:"❓",k:"question"},{e:"❗",k:"exclamation important"},
        {e:"💡",k:"idea bulb light"},{e:"📌",k:"pin"},{e:"📍",k:"location pin"},{e:"🔒",k:"lock secure"},{e:"🔓",k:"unlock"},{e:"🔑",k:"key"},{e:"🔔",k:"bell notification"},
        {e:"💰",k:"money bag cash"},{e:"💸",k:"money flying spend"},{e:"💳",k:"card credit"},{e:"📈",k:"chart up growth"},{e:"📉",k:"chart down loss"},
        {e:"⏰",k:"alarm clock time"},{e:"⏳",k:"hourglass wait time"},{e:"📅",k:"calendar date"},{e:"📎",k:"paperclip attach"},{e:"✏️",k:"pencil edit write"},
        {e:"📝",k:"memo note write"},{e:"📖",k:"book read"},{e:"💻",k:"laptop computer code"},{e:"🖥️",k:"desktop computer monitor"},{e:"⌨️",k:"keyboard"},{e:"🖱️",k:"mouse"},
        {e:"📱",k:"phone mobile"},{e:"🔋",k:"battery"},{e:"🔌",k:"plug power"},{e:"💾",k:"save floppy disk"},{e:"🗑️",k:"trash delete bin"},{e:"🐛",k:"bug insect error"},
        {e:"⚙️",k:"gear settings config"},{e:"🔧",k:"wrench fix tool"},{e:"🔨",k:"hammer build"},{e:"🚀",k:"rocket launch ship fast"},{e:"🛠️",k:"tools build"},
        {e:"☕",k:"coffee tea cafe"},{e:"🍺",k:"beer drink"},{e:"🍕",k:"pizza food"},{e:"🍔",k:"burger food"},{e:"🎂",k:"cake birthday"},{e:"🍎",k:"apple fruit"},
        {e:"🌈",k:"rainbow"},{e:"☀️",k:"sun sunny weather"},{e:"🌙",k:"moon night"},{e:"⛅",k:"cloud weather"},{e:"🌧️",k:"rain weather"},{e:"❄️",k:"snow cold winter"},
        {e:"🐱",k:"cat kitten"},{e:"🐶",k:"dog puppy"},{e:"🦊",k:"fox"},{e:"🐢",k:"turtle slow"},{e:"🦄",k:"unicorn magic"},{e:"🐧",k:"penguin linux"},
        {e:"👀",k:"eyes look"},{e:"🧠",k:"brain smart think"},{e:"🫡",k:"salute respect yes sir"},{e:"🤖",k:"robot bot ai"},{e:"👻",k:"ghost boo spooky"},
        {e:"💀",k:"skull dead dying"},{e:"🎯",k:"target dart bullseye goal"},{e:"🧩",k:"puzzle piece"},{e:"🔗",k:"link chain url"},{e:"📢",k:"announce megaphone loud"}
    ]

    // ---------- system actions (: mode) ----------
    readonly property var sysActions: [
        {l:"Settings",        s:"sea-shell control center",  i:"tune",               c:"~/.config/quickshell/sea-shell/sea-toggle.sh settings"},
        {l:"Wallpaper",       s:"wallpaper picker",         i:"wallpaper",          c:"~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"},
        {l:"Keybinds",        s:"cheat-sheet",              i:"keyboard",           c:"~/.config/quickshell/sea-shell/sea-toggle.sh keybinds"},
        {l:"Power menu",      s:"lock · suspend · off",     i:"power_settings_new", c:"~/.config/quickshell/sea-shell/sea-toggle.sh power"},
        {l:"Caffeine mode",   s:"toggle screen idle sleeping",i:"coffee",            c:"qs -c sea-shell ipc call shell toggleIdle"},
        {l:"Lock",            s:"loginctl lock-session",    i:"lock",               c:"~/.config/quickshell/sea-shell/sea-lock.sh"},
        {l:"Suspend",         s:"systemctl suspend",        i:"bedtime",            c:"systemctl suspend"},
        {l:"Reboot",          s:"systemctl reboot",         i:"restart_alt",        c:"systemctl reboot", warn:true},
        {l:"Shut down",       s:"systemctl poweroff",       i:"mode_off_on",        c:"systemctl poweroff", warn:true},
        {l:"Log out",         s:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }",    i:"logout",             c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }", warn:true},
        {l:"Reload Hyprland", s:"hyprctl reload",           i:"refresh",            c:"hyprctl reload"},
        {l:"Restart bar",     s:"quickshell sea-shell",      i:"replay",             c:"pkill -xf 'qs -c sea-shell'; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('qs -c sea-shell')\""}
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

    // decode every image entry to a small square thumbnail (cached by cliphist id) so the
    // ; picker shows real previews instead of a generic glyph. Always overwrites — ids can
    // be reused after a `cliphist wipe`, so a stale cache would show the wrong image.
    Process { id: clipThumbProc
        command: ["sh","-c",
            "d=" + root.clipThumbDir + "; mkdir -p \"$d\"; " +
            "cliphist list 2>/dev/null | head -80 | awk -F'\\t' '$2 ~ /^\\[\\[ binary data/{print $1}' | " +
            "while read -r id; do cliphist decode \"$id\" 2>/dev/null | " +
            "magick - -thumbnail 120x120^ -gravity center -extent 120x120 png:\"$d/$id.png\" 2>/dev/null; done; echo ok"]
        stdout: StdioCollector { onStreamFinished: root.clipThumbTick++ } }

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
                          sub: img ? "⏎ copy image" : "⏎ copy text", mi: img ? "image" : "content_paste", exec: cid, clipImg: img});
            }
            if (!out.length) out = [{type:"hint", title:"clipboard history", sub: root.clipLines.length ? "no match" : "history is empty", mi:"content_paste"}];
        } else if (q.startsWith("?") || q.toLowerCase().startsWith("g ") || q.toLowerCase().startsWith("yt ") || q.toLowerCase().startsWith("gh ")) {
            var w = q;
            var title = "";
            var url = "";
            var engine = "DuckDuckGo";
            var icon = "travel_explore";
            
            if (q.toLowerCase().startsWith("g ")) {
                w = q.slice(2).trim();
                title = w === "" ? "search Google" : "Search Google for \"" + w + "\"";
                url = "https://google.com/search?q=" + encodeURIComponent(w);
                engine = "Google";
            } else if (q.toLowerCase().startsWith("yt ")) {
                w = q.slice(3).trim();
                title = w === "" ? "search YouTube" : "Search YouTube for \"" + w + "\"";
                url = "https://youtube.com/results?search_query=" + encodeURIComponent(w);
                engine = "YouTube";
            } else if (q.toLowerCase().startsWith("gh ")) {
                w = q.slice(3).trim();
                title = w === "" ? "search GitHub" : "Search GitHub for \"" + w + "\"";
                url = "https://github.com/search?q=" + encodeURIComponent(w);
                engine = "GitHub";
            } else {
                w = q.slice(1).trim();
                title = w === "" ? "search the web" : "Search DuckDuckGo for \"" + w + "\"";
                url = "https://duckduckgo.com/?q=" + encodeURIComponent(w);
            }
            out = [{type:"web", title: title, sub: engine + "  ·  ⏎ opens browser", mi: icon, exec: url}];
        } else if (q.startsWith(":")) {
            var aq = q.slice(1).trim();
            root.sysActions.forEach(a => {
                var m = aq==="" ? {score:0,pos:[]} : fuzzy(aq, a.l);
                if (m) out.push({type:"act", title:highlight(a.l, m.pos), sub:a.s, mi:a.i, exec:a.c, warn:!!a.warn});
            });
        } else if (q.startsWith(".")) {
            // emoji picker: ".fire", ".heart" … ⏎ copies the glyph
            var eq = q.slice(1).trim().toLowerCase();
            for (var ei = 0; ei < root.emojiDB.length && out.length < 48; ei++) {
                var em = root.emojiDB[ei];
                if (eq === "" || em.k.indexOf(eq) >= 0) {
                    var words = em.k.split(" ");
                    out.push({ type:"emoji", emoji: em.e, title: words.slice(0,3).join(" "), sub: "⏎ copy  " + em.e, exec: em.e });
                }
            }
        } else {
            // auto-calculator on plain math ("2+2", "(9*9)/4")
            if (/^[0-9(.\-]/.test(q) && /[\d)]/.test(q)) { var cv = calc(q); if (cv !== null) out.push({type:"calc", title:"= "+esc(cv), sub:"⏎ copy result", mi:"calculate", exec:cv}); }
            
            // auto-conversion (e.g. "120 usd to eur", "32 c to f")
            var conv = parseConversion(q);
            if (conv !== null) {
                out.push({type:"calc", title: "= " + esc(conv), sub: "⏎ copy result", mi:"currency_exchange", exec:conv});
            }

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
        if (r.type === "calc" || r.type === "emoji") Quickshell.execDetached(["sh","-c","printf %s '" + r.exec.replace(/'/g,"") + "' | wl-copy"])
        if (r.type === "file") Quickshell.execDetached(["sh","-c","xdg-open \"$HOME/\"'" + r.exec.replace(/'/g,"'\\''") + "'"])
        if (r.type === "clip") Quickshell.execDetached(["sh","-c","cliphist decode " + r.exec + " | wl-copy"])
        if (r.type === "web")  { if (r.exec==="") return; Quickshell.execDetached(["xdg-open", r.exec]) }
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
        : query.startsWith(";") ? "CLIP" : query.startsWith(":") ? "SYS" : query.startsWith(".") ? "EMOJI" : "APPS"

    PanelWindow {
        id: win
        readonly property real ui: root.uiFor(win.screen)
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
            // combine the open-animation tile-in with the global UI scale; grow from the top
            // so the card stays pinned at y (16% down) and centred horizontally on big displays
            transformOrigin: Item.Top
            scale: win.ui * (0.975 + 0.025 * openF)
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
                    Text { text: "apps  ·  >run  =calc  ~files  ?web  ;clip  :sys  .emoji"; visible: field.text===""
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
                        IconImage { anchors.fill: parent; visible: ic.ip!=="" && !modelData.emoji; source: ic.ip }
                        // clipboard image entry → live thumbnail (decoded from cliphist); falls back to the glyph until it's ready
                        Rectangle { visible: !!modelData.clipImg; anchors.fill: parent; radius: 7; clip: true
                            color: theme.a(theme.iris, 0.10); border.width: 1; border.color: theme.a(theme.iris, 0.35)
                            Image { id: thumbImg; anchors.fill: parent; anchors.margins: 1; asynchronous: true; cache: false
                                fillMode: Image.PreserveAspectCrop; sourceSize.width: 60; sourceSize.height: 60
                                source: modelData.clipImg ? ("file://" + root.clipThumbDir + "/" + modelData.exec + ".png?t=" + root.clipThumbTick) : "" }
                            Text { anchors.centerIn: parent; visible: thumbImg.status !== Image.Ready
                                text: "image"; font.family: "Material Symbols Outlined"; font.pixelSize: 18; color: theme.iris } }
                        // emoji glyph (from the . picker) rendered in the system emoji font
                        Text { anchors.centerIn: parent; visible: !!modelData.emoji; text: modelData.emoji||""; font.pixelSize: 24 }
                        Text { anchors.centerIn: parent; visible: ic.ip==="" && !!modelData.mi && !modelData.emoji && !modelData.clipImg; text: modelData.mi||""
                            font.family: "Material Symbols Outlined"; font.pixelSize: 22
                            color: modelData.warn ? theme.bad : theme.iris }
                        Rectangle { anchors.fill: parent; radius: 8; visible: ic.ip==="" && !modelData.mi && !modelData.emoji
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
