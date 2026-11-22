// sea-shell — resident app launcher, lives inside the bar process (no spawn delay).
// Open via IPC:  qs -c sea-shell ipc call launcher toggle | clipboard
//
//   type        fuzzy-search apps, open windows, settings, math, conversions, or #hex colors
//   >cmd        run a shell command        ⏎ detached · CTRL+⏎ in a kitty window
//   =expr       calculator (also auto-detects "2+2")   ⏎ copies the result
//   ~query      file search in $HOME (fd)  ⏎ opens with xdg-open
//   ?query      web search (or `yt query` for YouTube) ⏎ opens the browser
//   ;query      clipboard history (cliphist)           ⏎ copies the entry
//   .query      emoji picker (search by name)          ⏎ copies the emoji
//   g query     Steam library (installed games)        ⏎ play · g alone shows recent
//   gh query    GitHub API (repos, PRs, issues)        ⏎ opens in browser
//   !note       cast a message in a bottle             ⏎ washes up later as a reminder
//   :kill q     search running processes               ⏎ SIGTERM · CTRL+⏎ SIGKILL
//   :           system actions (settings · wallpaper · power · lock · …)
//
// Esc / click-outside closes. ↑↓/Tab navigate · PgUp/PgDn jump · ALT+1..9 quick-launch.
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick

Scope {
    id: root
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgRadius: 14
    property real cfgScale: 0
    property var  cfgMonitors: ({})
    function uiFor(scr) {
        var mo = (scr && scr.name && root.cfgMonitors[scr.name]) ? root.cfgMonitors[scr.name].scale : 0;
        if (mo > 0) return mo;
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
    property string query: ""
    property int sel: 0
    property var results: []
    property var fileHits: []
    property var clipLines: []
    property var gameHits: []
    property var ghHits: []
    property var killHits: []
    readonly property string gamingScript: Qt.resolvedUrl("sea-gaming.py").toString().replace("file://", "")
    readonly property string githubScript: Qt.resolvedUrl("sea-github.py").toString().replace("file://", "")
    readonly property string bottleScript: Qt.resolvedUrl("sea-bottle.py").toString().replace("file://", "")
    readonly property string clipThumbDir: "/tmp/sea-clip-thumbs"
    property int clipThumbTick: 0
    property var bottleHits: []
    property var hist: ({})
    property string histPath: ""
    property bool shown: false
    property bool held: false

    function open(prefix) {
        Hyprland.refreshToplevels()
        clipProc.running = true
        clipThumbProc.running = true
        apProc.running = true
        field.text = prefix || ""; root.query = prefix || ""; root.sel = 0
        root.shown = true
    }
    function toggle() { root.shown ? close() : open("") }
    function close() { root.shown = false }

    SurfaceMotion { id: launcherMotion; opened: root.shown; reduced: Tok.reducedMotion }
    onShownChanged: { if (shown) { held = true; holdTimer.stop() } else holdTimer.restart() }
    Timer { id: holdTimer; interval: Tok.reducedMotion ? 0 : 170
        onTriggered: { root.held = false; field.text = ""; root.query = "" } }

    // ---------- sea-shell surface tokens ----------
    readonly property color cardEdge:  Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color cardSheen: Tok.light ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(1, 1, 1, 0.05)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)
    readonly property real  paneRad:   Math.min(16, Tok.r + 4)

    QtObject {
        id: theme
        readonly property bool  light: Tok.light
        readonly property color bg:    Tok.bg
        readonly property color panel: Tok.surface
        readonly property color line:  Tok.rule
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

    Process { id: apProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.radius!==undefined) root.cfgRadius=j.radius; if(j.scale!==undefined) root.cfgScale=j.scale; if(j.monitors) root.cfgMonitors=j.monitors; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

    // ---------- frecency history ----------
    Process { running: true; command: ["sh","-c","d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; cat \"$d/launcher-history.json\" 2>/dev/null; printf '\\n%s/launcher-history.json' \"$d\" >&2"]
        stdout: StdioCollector { id: hOut; onStreamFinished: { try { root.hist = JSON.parse(hOut.text) } catch(e) { root.hist = {} } } }
        stderr: StdioCollector { id: hErr; onStreamFinished: root.histPath = hErr.text.trim() } }
    function frecency(id) {
        var h = root.hist[id]; if (!h) return 0;
        var days = (Date.now()/1000 - h.t) / 86400;
        return h.n * (days < 1 ? 3 : days < 7 ? 2 : days < 30 ? 1 : 0.4);
    }
    function bump(id) {
        var h = root.hist; h[id] = { n: (h[id] ? h[id].n : 0) + 1, t: Math.floor(Date.now()/1000) };
        if (root.histPath !== "")
            Quickshell.execDetached(["sh","-c","echo '" + Qt.btoa(JSON.stringify(h)) + "' | base64 -d > \"" + root.histPath + "\""]);
    }
    function copyText(s) {
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", "" + s]);
    }

    // ---------- fuzzy matching ----------
    function fuzzy(q, s) {
        var ql = q.toLowerCase(), sl = s.toLowerCase();
        var sub = sl.indexOf(ql);
        if (sub >= 0) {
            var pos = []; for (var i=0;i<ql.length;i++) pos.push(sub+i);
            return { score: 100 - sub*2 + (sub===0 ? 40 : 0) + ql.length*3, pos: pos };
        }
        var score = 0, pi = 0, last = -2, positions = [];
        for (var j=0; j<sl.length && pi<ql.length; j++) {
            if (sl[j] !== ql[pi]) continue;
            var bonus = 1;
            if (j === last+1) bonus += 3;
            if (j === 0 || " -_./".indexOf(sl[j-1]) >= 0) bonus += 4;
            score += bonus; positions.push(j); last = j; pi++;
        }
        return pi === ql.length ? { score: score, pos: positions } : null;
    }
    function esc(s) { return ("" + (s || "")).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;") }
    function highlight(s, pos) {
        if (!pos || !pos.length) return esc(s);
        var out = "", set = {}; pos.forEach(p => set[p]=1);
        for (var i=0;i<s.length;i++) out += set[i] ? "<font color=\"" + Tok.accent + "\"><b>" + esc(s[i]) + "</b></font>" : esc(s[i]);
        return out;
    }

    // ---------- live color parser (#RGB, #RRGGBB, rgb(r,g,b)) ----------
    function parseColor(q) {
        var s = ("" + (q || "")).trim();
        var r, g, b;
        var m = s.match(/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/);
        if (m && s.indexOf("#") === 0) {
            var h = m[1];
            if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
            r = parseInt(h.slice(0,2), 16);
            g = parseInt(h.slice(2,4), 16);
            b = parseInt(h.slice(4,6), 16);
        } else {
            m = s.match(/^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$/i);
            if (!m) return null;
            r = Math.min(255, parseInt(m[1]));
            g = Math.min(255, parseInt(m[2]));
            b = Math.min(255, parseInt(m[3]));
        }
        function hx(n) { var t = n.toString(16); return t.length < 2 ? "0" + t : t }
        var hex = "#" + hx(r) + hx(g) + hx(b);
        var rn = r / 255, gn = g / 255, bn = b / 255;
        var max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn), d = max - min;
        var hh = 0, ss = 0, ll = (max + min) / 2;
        if (d > 0) {
            ss = ll > 0.5 ? d / (2 - max - min) : d / (max + min);
            if (max === rn) hh = ((gn - bn) / d + (gn < bn ? 6 : 0)) / 6;
            else if (max === gn) hh = ((bn - rn) / d + 2) / 6;
            else hh = ((rn - gn) / d + 4) / 6;
        }
        var lum = 0.2126 * rn + 0.7152 * gn + 0.0722 * bn;
        return {
            hex: hex,
            rgb: "rgb(" + r + ", " + g + ", " + b + ")",
            hsl: "hsl(" + Math.round(hh * 360) + ", " + Math.round(ss * 100) + "%, " + Math.round(ll * 100) + "%)",
            ink: lum > 0.52 ? "#111318" : "#ffffff"
        };
    }

    // ---------- calculator ----------
    function calc(expr) {
        var fns = /\b(sqrt|cbrt|sinh|cosh|tanh|asin|acos|atan2|atan|sin|cos|tan|log10|log2|log|ln|abs|round|floor|ceil|pow|min|max|exp|hypot|sign|trunc|pi|e)\b/g;
        if (!/^[0-9+\-*/%^().,\s]*$/.test(expr.replace(fns, ""))) return null;
        try {
            var v = new Function("with(Math){var ln=log,log=log10,pi=PI,e=E;return(" + expr.replace(/\^/g,"**") + ")}")();
            if (typeof v !== "number" || !isFinite(v)) return null;
            return String(Math.abs(v) < 1e15 ? Math.round(v*1e10)/1e10 : v);
        } catch(err) { return null }
    }

    // ---------- unit / currency / temp conversion ----------
    function parseConversion(q) {
        var ql = ("" + (q || "")).trim().toLowerCase();

        // Number base conversions: "255 to hex", "0xff to dec", "42 to bin", "0b101010 to hex"
        var bm = ql.match(/^(0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+)\s+(?:to|in)\s+(hex|dec|bin|oct)$/);
        if (bm) {
            var raw = bm[1], tgt = bm[2];
            var n = raw.startsWith("0x") ? parseInt(raw.slice(2), 16)
                  : raw.startsWith("0b") ? parseInt(raw.slice(2), 2)
                  : raw.startsWith("0o") ? parseInt(raw.slice(2), 8)
                  : parseInt(raw, 10);
            if (!isNaN(n)) {
                if (tgt === "hex") return "0x" + n.toString(16).toUpperCase();
                if (tgt === "bin") return "0b" + n.toString(2);
                if (tgt === "oct") return "0o" + n.toString(8);
                return "" + n;
            }
        }

        // Timezone conversions: "14:00 utc to myt", "9:30 est to jst", "18:00 pst to sgt"
        var tm = ql.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*([a-z]{2,4})\s+(?:to|in)\s+([a-z]{2,4})$/);
        if (tm) {
            var tzOff = {
                utc: 0, gmt: 0, bst: 1, cet: 1, cest: 2, eet: 2, ist: 5.5,
                myt: 8, sgt: 8, hkt: 8, cst: 8, awst: 8, pht: 8,
                jst: 9, kst: 9, aest: 10, aedt: 11, nzst: 12,
                est: -5, edt: -4, cdt: -5, mst: -7, mdt: -6, pst: -8, pdt: -7,
                wib: 7, ict: 7, gst: 4
            };
            var z1 = tzOff[tm[4]], z2 = tzOff[tm[5]];
            if (z1 !== undefined && z2 !== undefined) {
                var hh = parseInt(tm[1], 10), mm = parseInt(tm[2] || "0", 10);
                if (tm[3] === "pm" && hh < 12) hh += 12;
                if (tm[3] === "am" && hh === 12) hh = 0;
                var total = Math.round(hh * 60 + mm + (z2 - z1) * 60);
                var dayShift = total >= 1440 ? " (+1d)" : (total < 0 ? " (-1d)" : "");
                total = ((total % 1440) + 1440) % 1440;
                var oh = Math.floor(total / 60), om = total % 60;
                return (oh < 10 ? "0" : "") + oh + ":" + (om < 10 ? "0" : "") + om + " " + tm[5].toUpperCase() + dayShift;
            }
        }

        var m = ql.match(/^(-?\d+(?:\.\d+)?)\s*([a-z°\/]+)\s+(?:to|in)\s+([a-z°\/]+)$/);
        if (!m) return null;
        var val = parseFloat(m[1]), from = m[2], to = m[3];

        // CSS px <-> rem / pt (16px root)
        var css = { px: 1, rem: 16, em: 16, pt: 1.3333333 };
        if (css[from] !== undefined && css[to] !== undefined)
            return (Math.round((val * css[from] / css[to]) * 1000) / 1000) + " " + to;

        var temp = { c: ["c","°c","celsius"], f: ["f","°f","fahrenheit"], k: ["k","kelvin"] };
        function tkind(u) { for (var kk in temp) if (temp[kk].indexOf(u) >= 0) return kk; return null; }
        var tf = tkind(from), tt = tkind(to);
        if (tf && tt) {
            var cc = tf === "c" ? val : tf === "f" ? (val - 32) * 5/9 : val - 273.15;
            var tr = tt === "c" ? cc : tt === "f" ? (cc * 9/5 + 32) : cc + 273.15;
            return tr.toFixed(1) + " " + (tt === "c" ? "°C" : tt === "f" ? "°F" : "K");
        }

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

        var rates = { usd:1.0, eur:0.92, gbp:0.79, jpy:158.0, cad:1.36, aud:1.50, sgd:1.35, myr:4.45, idr:15800, thb:34.5, php:58.0, inr:83.3, cny:7.24, chf:0.88, nzd:1.64, mxn:17.0, brl:5.1, krw:1370, rub:90, zar:18.5, hkd:7.8, sek:10.6, nok:10.7, aed:3.67 };
        if (rates[from] !== undefined && rates[to] !== undefined)
            return ((val / rates[from]) * rates[to]).toFixed(2) + " " + to.toUpperCase();

        return null;
    }

    // ---------- emoji picker (. mode) ----------
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
        {e:"🧠",k:"brain smart think"},{e:"🫡",k:"salute respect yes sir"},{e:"🤖",k:"robot bot ai"},{e:"👻",k:"ghost boo spooky"},
        {e:"💀",k:"skull dead dying"},{e:"🎯",k:"target dart bullseye goal"},{e:"🧩",k:"puzzle piece"},{e:"🔗",k:"link chain url"},{e:"📢",k:"announce megaphone loud"}
    ]

    // ---------- system actions (: mode) ----------
    readonly property var sysActions: [
        {l:"Settings",        s:"sea-shell control center",  i:"tune",               c:"~/.config/quickshell/sea-shell/sea-toggle.sh settings"},
        {l:"Dashboard",       s:"system monitor · tasks",    i:"space_dashboard",    c:"qs -c sea-shell ipc call dashboard toggle"},
        {l:"Wallpaper",       s:"wallpaper picker",         i:"wallpaper",          c:"~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"},
        {l:"Screenshot",      s:"capture · copy · OCR",     i:"photo_camera",       c:"qs -c sea-shell ipc call screenshot toggle"},
        {l:"Record screen",   s:"screen recorder",          i:"videocam",           c:"qs -c sea-shell ipc call recorder toggle"},
        {l:"Keybinds",        s:"cheat-sheet",              i:"keyboard",           c:"~/.config/quickshell/sea-shell/sea-toggle.sh keybinds"},
        {l:"Power menu",      s:"lock · suspend · off",     i:"power_settings_new", c:"~/.config/quickshell/sea-shell/sea-toggle.sh power"},
        {l:"Caffeine mode",   s:"toggle screen idle sleeping",i:"coffee",            c:"qs -c sea-shell ipc call shell toggleIdle"},
        {l:"Pick a colour",   s:"copies the hex · SUPER+SHIFT+C",i:"colorize",       c:"sh ~/.config/quickshell/sea-shell/sea-colorpick.sh"},
        {l:"Color Studio",    s:"eyedropper history · contrast · ramp", i:"palette",  c:"qs -c sea-shell ipc call colors toggle"},
        {l:"Scratchpad Notes",s:"quick markdown notes · SUPER+ALT+N",   i:"edit_note",c:"qs -c sea-shell ipc call notes toggle"},
        {l:"Drop Shelf & QR", s:"share files over Wi-Fi · SUPER+ALT+S", i:"qr_code_2",c:"qs -c sea-shell ipc call dropzone toggle"},
        {l:"Workspace Sessions",s:"save & launch app bundles · SUPER+ALT+L", i:"workspaces", c:"qs -c sea-shell ipc call sessions toggle"},
        {l:"Clipboard & Emoji",s:"visual history & pins · SUPER+V",     i:"content_paste", c:"qs -c sea-shell ipc call clipboard toggle"},
        {l:"PiP Snap Window", s:"float & pin corner · SUPER+ALT+P",     i:"picture_in_picture_alt", c:"sh ~/.config/quickshell/sea-shell/sea-win-layout.sh pip"},
        {l:"Focus Float 75%", s:"center active window · SUPER+ALT+F",   i:"center_focus_strong", c:"sh ~/.config/quickshell/sea-shell/sea-win-layout.sh focus"},
        {l:"Screen Ruler",    s:"measure pixels & aspect · SUPER+ALT+R",i:"straighten",          c:"qs -c sea-shell ipc call ruler toggle"},
        {l:"OCR & Translate", s:"screen region translate · SUPER+SHIFT+T", i:"translate",        c:"qs -c sea-shell ipc call translate ocr"},
        {l:"Cast a bottle",   s:"delayed reminder · launcher !note", i:"sailing",     c:"qs -c sea-shell ipc call launcher bottle"},
        {l:"Lock",            s:"loginctl lock-session",    i:"lock",               c:"~/.config/quickshell/sea-shell/sea-lock.sh"},
        {l:"Suspend",         s:"systemctl suspend",        i:"bedtime",            c:"systemctl suspend"},
        {l:"Reboot",          s:"systemctl reboot",         i:"restart_alt",        c:"systemctl reboot", warn:true},
        {l:"Shut down",       s:"systemctl poweroff",       i:"mode_off_on",        c:"systemctl poweroff", warn:true},
        {l:"Log out",         s:"end Hyprland session",     i:"logout",             c:"systemctl --user is-active -q 'wayland-wm@*.service' && uwsm stop || { hyprctl dispatch 'hl.dsp.exit()'; sleep 3; loginctl terminate-session self; }", warn:true},
        {l:"Reload Hyprland", s:"hyprctl reload",           i:"refresh",            c:"hyprctl reload"},
        {l:"Restart bar",     s:"seashell supervisor",      i:"replay",             c:"sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"}
    ]

    // ---------- process kill mode (:kill <query>) ----------
    function killMode(q) {
        var ql = ("" + (q || "")).toLowerCase();
        return ql === ":kill" || ql.startsWith(":kill ");
    }
    Timer { id: killDebounce; interval: 100; onTriggered: {
        killProc.running = false;
        killProc.running = true;
    } }
    Process {
        id: killProc
        command: ["sh", "-c", "ps -u \"$USER\" -o pid=,pcpu=,rss=,comm= --sort=-pcpu 2>/dev/null | head -60"]
        stdout: StdioCollector { id: killOut; onStreamFinished: {
            var out = [], lines = killOut.text.trim().split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].trim().split(/\s+/);
                if (f.length < 4) continue;
                var pid = parseInt(f[0]) || 0;
                if (pid <= 1) continue;
                out.push({ pid: pid, cpu: f[1], rss: Math.round(parseInt(f[2]) / 1024), name: f.slice(3).join(" ") });
            }
            root.killHits = out;
            if (root.killMode(root.query)) root.refresh();
        } }
    }

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

    Timer { id: gameSearchDebounce; interval: 140; onTriggered: {
        var gq = root.query.slice(1).trim();
        gameSearchProc.command = ["python3", root.gamingScript, "search", gq, "--limit", "28"];
        gameSearchProc.running = true;
    } }
    Process { id: gameSearchProc
        stdout: StdioCollector { id: gameOut; onStreamFinished: {
            try { root.gameHits = JSON.parse(gameOut.text.trim()) || []; } catch (e) { root.gameHits = []; }
            if (root.gamesMode(root.query)) root.refresh();
        } } }

    function githubMode(q) {
        q = ("" + (q || "")).toLowerCase();
        return q === "gh" || q.startsWith("gh ");
    }
    Timer { id: ghSearchDebounce; interval: 140; onTriggered: {
        var ql = root.query.toLowerCase();
        var gq = ql.length >= 3 && ql[2] === " " ? root.query.slice(3).trim() : "";
        ghSearchProc.command = ["python3", root.githubScript, "search", gq];
        ghSearchProc.running = true;
    } }
    Process { id: ghSearchProc
        stdout: StdioCollector { id: ghOut; onStreamFinished: {
            try { root.ghHits = JSON.parse(ghOut.text.trim()) || []; } catch (e) { root.ghHits = []; }
            if (root.githubMode(root.query)) root.refresh();
        } } }

    function bottleMode(q) {
        return ("" + (q || "")).startsWith("!");
    }
    Process { id: bottleListProc
        command: ["python3", root.bottleScript, "list"]
        stdout: StdioCollector { id: bottleOut; onStreamFinished: {
            try {
                var j = JSON.parse(bottleOut.text.trim() || "{}") || {};
                root.bottleHits = j.floating || [];
            } catch (e) { root.bottleHits = []; }
            if (root.bottleMode(root.query)) root.refresh();
        } } }

    Process { id: clipThumbProc
        command: ["sh","-c",
            "d=" + root.clipThumbDir + "; mkdir -p \"$d\"; rm -f \"$d\"/big-*.png; " +
            "cliphist list 2>/dev/null | head -80 | awk -F'\\t' '$2 ~ /^\\[\\[ binary data/{print $1}' | " +
            "while read -r id; do cliphist decode \"$id\" 2>/dev/null | " +
            "magick - -thumbnail 120x120^ -gravity center -extent 120x120 png:\"$d/$id.png\" 2>/dev/null; done; echo ok"]
        stdout: StdioCollector { onStreamFinished: root.clipThumbTick++ } }

    readonly property var settingDestinations: [
        {l:"Wi-Fi & network", k:"connect wi-fi wifi internet network ethernet dns vpn", t:2, i:"wifi"},
        {l:"Bluetooth", k:"bluetooth pair headphones device", t:9, i:"bluetooth"},
        {l:"Appearance & text size", k:"make text bigger font scale appearance theme colours colors dark light", t:4, i:"palette"},
        {l:"Displays", k:"display displays monitor resolution refresh brightness night light", t:1, i:"monitor"},
        {l:"Storage & disks", k:"disk disks drive storage free up space clear clean junk cache full health", t:19, i:"hard_drive"},
        {l:"Sound", k:"audio sound volume microphone speakers", t:0, i:"volume_up"},
        {l:"Keyboard & shortcuts", k:"keyboard shortcuts keybinds rebind keys repeat layout caps lock", t:7, i:"keyboard"},
        {l:"Lock Screen", k:"idle lock sleep timeout login screen sddm", t:10, i:"lock"},
        {l:"Wallpaper & desktop", k:"change wallpaper desktop widgets background hot corners", t:21, i:"wallpaper"},
        {l:"Gaming", k:"steam games game mode mangohud gamescope launch profile", t:25, i:"sports_esports"},
        {l:"Accessibility", k:"accessibility reduce motion transparency cursor pointer size zoom", t:26, i:"accessibility_new"},
        {l:"Privacy & Security", k:"privacy security firewall ufw clipboard camera microphone", t:27, i:"shield"},
        {l:"Date & Time", k:"date time timezone clock ntp 24 hour seconds", t:31, i:"schedule"},
        {l:"Language & Region", k:"language locale region celsius fahrenheit units", t:32, i:"language"},
        {l:"Login Items & Startup", k:"login startup autostart boot background services", t:30, i:"rocket_launch"},
        {l:"Window Effects & Tiling", k:"window gaps border rounding blur shadow animations focus", t:35, i:"view_quilt"}
    ]
    function gamesMode(q) {
        q = ("" + (q || "")).toLowerCase();
        return q === "g" || q.startsWith("g ");
    }
    function isSteamGameEntry(a) {
        if (!a) return false;
        var exec = "" + (a.execString || "");
        var comment = "" + (a.comment || "");
        var id = "" + (a.id || "");
        if (/steam:\/\/rungameid/i.test(exec) || /steam_app_/i.test(id)) return true;
        if (/play this game on steam/i.test(comment)) return true;
        return false;
    }
    function settingsMatches(query) {
        var words = query.toLowerCase().trim().split(/\s+/);
        if (!words[0]) return [];
        return root.settingDestinations.filter(function(d) {
            return words.every(function(w) { return d.k.indexOf(w) >= 0 });
        }).map(function(d) {
            return {type:"setting", title:esc(d.l), sub:"Open settings · " + d.l, mi:d.i, tab:d.t};
        });
    }

    // ---------- build the result list for the current query ----------
    function refresh() {
        var q = root.query, out = [], i;
        if (root.killMode(q)) {
            var kq = q.slice(5).trim();
            killDebounce.restart();
            for (i = 0; i < root.killHits.length; i++) {
                var kp = root.killHits[i];
                var km = kq === "" ? { score: 0, pos: [] } : fuzzy(kq, kp.name + " " + kp.pid);
                if (!km) continue;
                out.push({
                    type: "kill", pid: kp.pid, cpu: kp.cpu, rss: kp.rss, pname: kp.name,
                    title: kq === "" ? esc(kp.name) : highlight(kp.name, fuzzy(kq, kp.name) ? fuzzy(kq, kp.name).pos : []),
                    sub: "PID " + kp.pid + " · " + kp.cpu + "% · " + kp.rss + " MB",
                    mi: "dangerous", warn: true
                });
            }
            if (!out.length) out = [{ type: "hint", title: "Kill process", sub: root.killHits.length ? "no matching process" : "loading processes…", mi: "memory" }];
        } else if (q.startsWith(">")) {
            var cmd = q.slice(1).trim();
            if (cmd !== "") out = [
                {type:"run",  title:esc(cmd),  sub:"run command  ·  ⏎ detached", mi:"terminal", exec:cmd},
                {type:"term", title:esc(cmd),  sub:"run in kitty  ·  stays open", mi:"monitor",  exec:cmd}];
            else out = [{type:"hint", title:"Run shell command", sub:"type a command · ⏎ detached · Ctrl+⏎ in kitty", mi:"terminal"}];
        } else if (q.startsWith("=")) {
            var r = calc(q.slice(1));
            out = [{type:"calc", title: r !== null ? "= " + esc(r) : "…", sub: r !== null ? "⏎ copy result" : "keep typing", mi:"calculate", exec:r}];
        } else if (q.startsWith("~") || q.startsWith("/")) {
            fdDebounce.restart();
            for (i=0;i<root.fileHits.length;i++) {
                var p = root.fileHits[i];
                out.push({type:"file", title:esc(p.split("/").pop()), sub:"~/" + esc(p), mi: p.indexOf(".")<0 ? "folder" : "description", exec:p});
            }
            if (!out.length) out = [{type:"hint", title:"Search files in ~", sub:"powered by fd — keep typing", mi:"folder_open"}];
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
            if (!out.length) out = [{type:"hint", title:"Clipboard history", sub: root.clipLines.length ? "no match" : "history is empty", mi:"content_paste"}];
        } else if (root.gamesMode(q)) {
            var gq = q.slice(1).trim();
            gameSearchDebounce.restart();
            for (i = 0; i < root.gameHits.length; i++) {
                var gg = root.gameHits[i];
                var sub = gg.seconds > 0 ? Math.round(gg.seconds / 60) + " min played" : "Steam · appid " + gg.appid;
                out.push({ type: "game", title: esc(gg.name), sub: sub, mi: "sports_esports", appid: gg.appid });
            }
            if (!out.length) out = [{ type: "hint", title: "Steam library", sub: gq === "" ? "loading installed games…" : "no match", mi: "sports_esports" }];
            out.push({ type: "act", title: "Gaming dashboard", sub: "Super+D · library & profiles", mi: "dashboard",
                       exec: "qs -c sea-shell ipc call dashboard gaming" });
        } else if (root.githubMode(q)) {
            var ghql = q.toLowerCase();
            var ghq = ghql.length >= 3 && ghql[2] === " " ? q.slice(3).trim() : "";
            ghSearchDebounce.restart();
            for (i = 0; i < root.ghHits.length; i++) {
                var h = root.ghHits[i];
                if (h.type === "hint") {
                    out.push({ type: "hint", title: h.title || "GitHub", sub: h.sub || "", mi: h.mi || "search" });
                } else if (h.type === "act") {
                    out.push({ type: "act", title: esc(h.title || ""), sub: h.sub || "", mi: h.mi || "bolt", exec: h.exec || "" });
                } else {
                    out.push({ type: "web", title: esc(h.title || ""), sub: h.sub || "GitHub",
                               mi: h.mi || "link", exec: h.url || "" });
                }
            }
            if (!out.length) out = [{ type: "hint", title: "GitHub", sub: ghq === "" ? "loading…" : "no match", mi: "commit" }];
        } else if (root.bottleMode(q)) {
            var note = q.slice(1).trim();
            bottleListProc.running = true;
            if (note !== "") {
                out.push({ type: "bottle", title: "Cast bottle", sub: "\"" + note + "\" · washes up in 20 min–6 h",
                           mi: "sailing", exec: note });
            } else {
                out.push({ type: "hint", title: "Message in a bottle", sub: "type ! then your reminder — it washes up later", mi: "sailing" });
            }
            for (i = 0; i < root.bottleHits.length; i++) {
                var bb = root.bottleHits[i];
                var left = Math.max(0, Math.round((Number(bb.washAt) || 0) - Date.now() / 1000));
                var eta = left < 90 ? "any minute" : left < 3600 ? ("~" + Math.round(left / 60) + " min out") : ("~" + Math.round(left / 3600) + " h out");
                out.push({ type: "hint", title: esc(bb.text || "…"), sub: "still at sea · " + eta, mi: "water" });
            }
        } else if (q.startsWith("?") || q.toLowerCase().startsWith("yt ")) {
            var w = q, title = "", url = "", engine = "DuckDuckGo", icon = "travel_explore";
            if (q.toLowerCase().startsWith("yt ")) {
                w = q.slice(3).trim();
                title = w === "" ? "Search YouTube" : "Search YouTube for \"" + w + "\"";
                url = "https://youtube.com/results?search_query=" + encodeURIComponent(w);
                engine = "YouTube";
            } else {
                w = q.slice(1).trim();
                title = w === "" ? "Search the web" : "Search DuckDuckGo for \"" + w + "\"";
                url = "https://duckduckgo.com/?q=" + encodeURIComponent(w);
            }
            out = [{type:"web", title: esc(title), sub: engine + "  ·  ⏎ opens browser", mi: icon, exec: url}];
        } else if (q.startsWith(":")) {
            var aq = q.slice(1).trim();
            if (aq === "" || "kill".indexOf(aq.toLowerCase()) === 0)
                out.push({type:"mode", title:"Kill process", sub:"search & end running processes (:kill)", mi:"dangerous", prefix:":kill ", warn:true});
            root.sysActions.forEach(a => {
                var m = aq==="" ? {score:0,pos:[]} : fuzzy(aq, a.l);
                if (m) out.push({type:"act", title:highlight(a.l, m.pos), sub:a.s, mi:a.i, exec:a.c, warn:!!a.warn});
            });
        } else if (q.startsWith(".")) {
            var eq = q.slice(1).trim().toLowerCase();
            for (var ei = 0; ei < root.emojiDB.length && out.length < 48; ei++) {
                var em = root.emojiDB[ei];
                if (eq === "" || em.k.indexOf(eq) >= 0) {
                    var words = em.k.split(" ");
                    out.push({ type:"emoji", emoji: em.e, title: words.slice(0,3).join(" "), sub: "⏎ copy  " + em.e, exec: em.e });
                }
            }
        } else {
            // Live color swatch (#hex / rgb(...))
            var col = root.parseColor(q);
            if (col !== null) {
                out.push({ type: "color", title: esc(col.hex.toUpperCase()), sub: col.rgb, hex: col.hex, rgb: col.rgb, hsl: col.hsl, ink: col.ink, exec: col.hex });
            }
            // Auto-calculator on plain math ("2+2", "(9*9)/4")
            if (/^[0-9(.\-]/.test(q) && /[\d)]/.test(q)) { var cv = calc(q); if (cv !== null) out.push({type:"calc", title:"= "+esc(cv), sub:"⏎ copy result", mi:"calculate", exec:cv}); }
            // Auto-conversion ("120 usd to eur", "32 c to f")
            var conv = parseConversion(q);
            if (conv !== null) {
                out.push({type:"calc", title: "= " + esc(conv), sub: "⏎ copy result", mi:"currency_exchange", exec:conv});
            }

            root.settingsMatches(q).forEach(function(hit) { out.push(hit) });
            var apps = DesktopEntries.applications.values, scored = [];
            for (i=0;i<apps.length;i++) {
                var a = apps[i]; if (a.noDisplay) continue;
                if (root.isSteamGameEntry(a)) continue;
                var hay = [a.name, a.genericName||"", (a.keywords||[]).join(" "), a.comment||"", (a.execString||"").split(" ")[0].split("/").pop()];
                if (q === "") { scored.push({e:a, sc:0, pos:[]}); continue }
                var best = null, bi = 0;
                for (var h=0;h<hay.length;h++) {
                    var mm = fuzzy(q, hay[h]); if (!mm) continue;
                    var sc = mm.score * (h===0 ? 3 : h===1 ? 2 : 1);
                    if (!best || sc > best.score) { best = {score:sc, pos:mm.pos}; bi = h }
                }
                if (best) scored.push({e:a, sc:best.score, pos: bi===0 ? best.pos : []});
            }
            scored.sort((x,y) => (y.sc + frecency(y.e.id)*4) - (x.sc + frecency(x.e.id)*4) || x.e.name.localeCompare(y.e.name));
            var windows = Hyprland.toplevels.values, windowHits = [];
            for (var wi = 0; wi < windows.length; wi++) {
                var win = windows[wi], ipc = win.lastIpcObject;
                if (!win.wayland || !ipc || !ipc.address) continue;
                var cls = String(win.wayland.appId || ipc.class || ""), title = String(win.wayland.title || ipc.title || cls);
                var match = q === "" ? {score:0} : fuzzy(q, cls + " " + title);
                if (!match) continue;
                var ws = win.workspace ? win.workspace.id : (ipc.workspace ? ipc.workspace.id : "?");
                var went = cls ? DesktopEntries.heuristicLookup(cls) : null;
                windowHits.push({type:"window", title:esc(went ? went.name : (cls || title)),
                    sub:esc(title), mi:"window", address:ipc.address, score:match.score,
                    top:win, ws:String(ws), wtitle:title, cls:cls, wicon: went ? went.icon : ""});
            }
            windowHits.sort((a,b) => b.score - a.score);
            windowHits.forEach(w => out.push(w));
            scored.forEach(s => out.push({type:"app", title:highlight(s.e.name, s.pos),
                sub: esc(s.e.genericName || s.e.comment || ""), entry:s.e, fav: frecency(s.e.id) > 2}));
        }
        root.results = out;
        root.sel = 0;
    }
    onQueryChanged: refresh()
    Component.onCompleted: refresh()
    Connections { target: DesktopEntries.applications; ignoreUnknownSignals: true
        function onValuesChanged() { root.refresh() } }

    // ---------- activate ----------
    function activate(idx, force) {
        var r = root.results[idx]; if (!r || r.type === "hint") return;
        if (r.type === "mode") { field.text = r.prefix; field.cursorPosition = field.text.length; field.forceActiveFocus(); return; }
        if (r.type === "kill") {
            Quickshell.execDetached(["kill", force ? "-KILL" : "-TERM", String(r.pid)]);
            Quickshell.execDetached(["notify-send", "sea-shell", (force ? "Force killed " : "Ended ") + r.pname + " (PID " + r.pid + ")"]);
            root.close(); return;
        }
        if (r.type === "color") { root.copyText(r.hex); root.close(); return; }
        if (r.type === "window") Hyprland.dispatch("hl.dsp.focus({ window = 'address:" + r.address + "' })");
        if (r.type === "app")  { bump(r.entry.id); r.entry.execute() }
        if (r.type === "run")  Quickshell.execDetached(["sh","-c",r.exec])
        if (r.type === "term") Quickshell.execDetached(["kitty","--hold","sh","-c",r.exec])
        if (r.type === "calc" || r.type === "emoji") root.copyText(r.exec)
        if (r.type === "file") Quickshell.execDetached(["sh","-c","xdg-open \"$HOME/\"'" + r.exec.replace(/'/g,"'\\''") + "'"])
        if (r.type === "clip") Quickshell.execDetached(["sh","-c","cliphist decode " + r.exec + " | wl-copy"])
        if (r.type === "web")  { if (r.exec==="") return; Quickshell.execDetached(["xdg-open", r.exec]) }
        if (r.type === "game") Quickshell.execDetached(["python3", root.gamingScript, "play", "" + r.appid])
        if (r.type === "setting") Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "shell", "openSettingsTab", String(r.tab)])
        if (r.type === "act")  Quickshell.execDetached(["sh","-c",r.exec])
        if (r.type === "bottle") Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "bottle", "cast", "" + r.exec])
        root.close();
    }
    function setModePrefix(p) {
        field.text = p;
        field.cursorPosition = field.text.length;
        field.forceActiveFocus();
    }
    function move(d) {
        if (!root.results.length) return;
        root.sel = Math.min(root.results.length-1, Math.max(0, root.sel + d));
        list.positionViewAtIndex(root.sel, ListView.Contain);
    }

    readonly property string modeKey: root.killMode(query) ? ":kill "
        : query.startsWith(">") ? ">"
        : query.startsWith("=") ? "="
        : (query.startsWith("~") || query.startsWith("/")) ? "~"
        : (query.startsWith("?") || query.toLowerCase().startsWith("yt ")) ? "?"
        : root.gamesMode(query) ? "g "
        : root.githubMode(query) ? "gh "
        : root.bottleMode(query) ? "!"
        : query.startsWith(";") ? ";"
        : query.startsWith(":") ? ":"
        : query.startsWith(".") ? "." : ""

    readonly property string modeIcon: root.killMode(query) ? "dangerous"
        : query.startsWith(">") ? "terminal"
        : query.startsWith("=") ? "calculate"
        : (query.startsWith("~") || query.startsWith("/")) ? "folder_open"
        : (query.startsWith("?") || query.toLowerCase().startsWith("yt ")) ? "travel_explore"
        : root.gamesMode(query) ? "sports_esports"
        : root.githubMode(query) ? "commit"
        : root.bottleMode(query) ? "sailing"
        : query.startsWith(";") ? "content_paste"
        : query.startsWith(":") ? "tune"
        : query.startsWith(".") ? "mood"
        : (root.curType === "color") ? "palette" : "search"

    readonly property var cur: root.results[root.sel] || null
    readonly property string curType: root.cur ? root.cur.type : ""
    function groupOf(t) {
        return ({ window: "Open windows", app: "Apps", game: "Steam", calc: "Answer", color: "Color",
                  file: "Files", clip: "Clipboard", web: "Web", setting: "Settings", act: "System",
                  mode: "System", kill: "Processes", emoji: "Emoji", run: "Run", term: "Run",
                  bottle: "Bottle" })[t] || "";
    }
    function subOf(r) { var t = root.plain(r ? r.sub : ""); return t.indexOf("⏎") >= 0 ? "" : t }
    function plain(html) { return ("" + (html || "")).replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&") }
    function ago(t) {
        var d = Date.now() / 1000 - t;
        if (d < 90) return "just now";
        if (d < 3600) return Math.round(d / 60) + " min ago";
        if (d < 86400) return Math.round(d / 3600) + " h ago";
        if (d < 86400 * 30) return Math.round(d / 86400) + " days ago";
        return "a while ago";
    }
    readonly property string enterVerb: ({ window: "Switch to", app: "Open", game: "Play", calc: "Copy",
        color: "Copy hex", emoji: "Copy", clip: "Copy", file: "Open", web: "Search", act: "Run",
        mode: "Open", kill: "End process", run: "Run", term: "Run in kitty", bottle: "Cast" })[root.curType] || "Open"
    function isImage(p) { return /\.(png|jpe?g|webp|gif|bmp|svg|avif)$/i.test(p || "") }

    // Peek inside clipboard text / text files / directories
    property string peekText: ""
    property string peekFor: ""
    property string peekImage: ""
    Timer { id: peekDebounce; interval: 90; onTriggered: {
        var c = root.cur; root.peekText = ""; root.peekImage = "";
        if (!c || !root.shown) return;
        var key = c.type + ":" + c.exec;
        root.peekFor = key;
        if (c.type === "clip" && c.clipImg)
            peekProc.command = ["sh", "-c", "o=\"$2/big-$1.png\"; [ -s \"$o\" ] || cliphist decode \"$1\" 2>/dev/null "
                + "| magick - -thumbnail '900x560>' png:\"$o\" 2>/dev/null; [ -s \"$o\" ] && printf 'IMG:%s' \"$o\"", "sh", "" + c.exec, root.clipThumbDir];
        else if (c.type === "clip")
            peekProc.command = ["sh", "-c", "cliphist decode \"$1\" 2>/dev/null | head -c 1600", "sh", "" + c.exec];
        else if (c.type === "file" && !root.isImage(c.exec))
            peekProc.command = ["sh", "-c", "f=\"$HOME/$1\"; if [ -d \"$f\" ]; then ls -1p \"$f\" 2>/dev/null | head -16; "
                + "else case \"$(file -b --mime-type \"$f\" 2>/dev/null)\" in text/*|application/json|application/x-shellscript) head -c 1400 \"$f\";; esac; fi", "sh", "" + c.exec];
        else return;
        peekProc.key = key; peekProc.running = false; peekProc.running = true;
    } }
    Process { id: peekProc; property string key: ""
        stdout: StdioCollector { id: peekOut; onStreamFinished: {
            if (peekProc.key !== root.peekFor) return;
            if (peekOut.text.indexOf("IMG:") === 0) root.peekImage = Tok.fileUrl(peekOut.text.slice(4));
            else root.peekText = peekOut.text;
        } } }
    onCurChanged: peekDebounce.restart()

    component DetailBtn: Rectangle {
        id: dbtn
        property string icon: ""
        property string label: ""
        property bool primary: false
        property bool danger: false
        signal tapped()
        height: 32
        width: dbRow.implicitWidth + 24
        radius: Tok.r
        color: dbtn.danger ? (dbMa.containsMouse ? Tok.crit : Tok.critWash)
             : dbtn.primary ? (dbMa.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent)
             : (dbMa.containsMouse ? Tok.raised : Tok.sunken)
        border.width: dbtn.primary ? 0 : 1
        border.color: dbtn.danger ? Tok.alpha(Tok.crit, 0.35) : root.cardEdge
        scale: dbMa.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Row {
            id: dbRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                visible: dbtn.icon !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: dbtn.icon; font.family: "Material Symbols Outlined"; font.pixelSize: 16
                color: dbtn.primary ? Tok.accentInk : (dbtn.danger ? (dbMa.containsMouse ? "white" : Tok.crit) : Tok.ink2)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: dbtn.label; font.family: Tok.sans; font.pixelSize: 12; font.weight: Font.DemiBold
                color: dbtn.primary ? Tok.accentInk : (dbtn.danger ? (dbMa.containsMouse ? "white" : Tok.crit) : Tok.ink)
            }
        }
        MouseArea { id: dbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dbtn.tapped() }
    }

    component KeyCap: Rectangle {
        property string text: ""
        height: 20
        width: kcTxt.implicitWidth + 10
        radius: 5
        color: Tok.sunken
        border.width: 1
        border.color: root.cardEdge
        Text { id: kcTxt; anchors.centerIn: parent; text: parent.text; font.family: Tok.mono; font.pixelSize: 10; color: Tok.ink3 }
    }

    PanelWindow {
        id: win
        readonly property real ui: root.uiFor(win.screen)
        visible: root.shown || root.held
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:launcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        onVisibleChanged: if (visible) field.forceActiveFocus()

        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.35); opacity: card.openF
            MouseArea { anchors.fill: parent; onClicked: root.close() } }

        Rectangle {
            id: card
            width: 900; height: 556
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.max(24, (parent.height - height * win.ui) * 0.28)
            radius: Tok.rCard
            color: Tok.bg
            border.width: 1; border.color: Tok.alpha(Tok.ink, Tok.light ? 0.12 : 0.14)

            readonly property real openF: launcherMotion.progress
            opacity: openF
            enabled: root.shown
            transformOrigin: Item.Top
            scale: win.ui * (0.97 + 0.03 * openF)
            transform: Translate { y: -12 * (1 - card.openF) }

            Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: parent.radius; rightMargin: parent.radius }
                height: 1; color: root.cardSheen }

            // ---------- search header ----------
            Item {
                id: head
                width: parent.width; height: 60
                Rectangle {
                    id: lensBox
                    width: 34; height: 34; radius: Tok.r
                    anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                    color: root.modeKey === ":kill " ? Tok.critWash : Tok.accentWash
                    Text {
                        anchors.centerIn: parent; text: root.modeIcon
                        font.family: "Material Symbols Outlined"; font.pixelSize: 20
                        color: root.modeKey === ":kill " ? Tok.crit : Tok.accent
                    }
                }
                TextInput {
                    id: field
                    anchors { left: lensBox.right; leftMargin: 14; right: clearBtn.visible ? clearBtn.left : parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                    color: Tok.ink; font.pixelSize: 18; font.family: Tok.sans
                    selectionColor: Tok.alpha(Tok.accent, 0.35); selectedTextColor: Tok.ink
                    clip: true
                    onTextChanged: root.query = text
                    Text { text: "Search apps, windows, files, math, #colors…"; visible: field.text === ""
                        color: Tok.ink3; font: field.font; anchors.verticalCenter: parent.verticalCenter }
                    Keys.onEscapePressed: {
                        if (field.text !== "") { field.text = ""; return }
                        root.close()
                    }
                    Keys.onReturnPressed: (e)=> {
                        var cur = root.results[root.sel];
                        if ((e.modifiers & Qt.ControlModifier) && cur && cur.type === "run")
                            { root.activate(root.sel + 1); return }
                        if ((e.modifiers & Qt.ControlModifier) && cur && cur.type === "kill")
                            { root.activate(root.sel, true); return }
                        root.activate(root.sel, false)
                    }
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
                    id: clearBtn
                    visible: field.text !== ""
                    width: 26; height: 26; radius: 13
                    anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                    color: clrMa.containsMouse ? Tok.raised : Tok.sunken
                    border.width: 1; border.color: root.cardEdge
                    Text { anchors.centerIn: parent; text: "close"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: Tok.ink2 }
                    MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.setModePrefix("") }
                }
                Rectangle { width: parent.width; height: 1; color: Tok.rule; anchors.bottom: parent.bottom }
            }

            // ---------- quick mode pill strip (discoverable, clickable) ----------
            Item {
                id: modeBar
                anchors { top: head.bottom; left: parent.left; right: parent.right }
                height: 40
                Row {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    spacing: 5
                    Repeater {
                        model: [
                            { p: "",      l: "All",       i: "apps" },
                            { p: "~",     l: "Files",     i: "folder_open" },
                            { p: ";",     l: "Clipboard", i: "content_paste" },
                            { p: ">",     l: "Run",       i: "terminal" },
                            { p: ":kill ",l: "Kill",      i: "dangerous" },
                            { p: "g ",    l: "Games",     i: "sports_esports" },
                            { p: "gh ",   l: "GitHub",    i: "commit" },
                            { p: ":",     l: "System",    i: "tune" },
                            { p: ".",     l: "Emoji",     i: "mood" },
                            { p: "?",     l: "Web",       i: "travel_explore" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool on: root.modeKey === modelData.p
                            height: 26; width: mpRow.implicitWidth + 16; radius: 13
                            color: on ? Tok.raised : (mpMa.containsMouse ? root.rowHover : "transparent")
                            border.width: on ? 1 : 0
                            border.color: root.cardEdge
                            Behavior on color { ColorAnimation { duration: Tok.mFast } }
                            Row {
                                id: mpRow; anchors.centerIn: parent; spacing: 5
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.i; font.family: "Material Symbols Outlined"; font.pixelSize: 14
                                    color: on ? (modelData.p === ":kill " ? Tok.crit : Tok.accent) : Tok.ink3
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.l; font.family: Tok.sans; font.pixelSize: 11
                                    font.weight: on ? Font.DemiBold : Font.Medium
                                    color: on ? Tok.ink : Tok.ink2
                                }
                            }
                            MouseArea { id: mpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.setModePrefix(modelData.p) }
                        }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Tok.rule; anchors.bottom: parent.bottom }
            }

            // ---------- results (left) ----------
            ListView {
                id: list
                anchors { top: modeBar.bottom; topMargin: 8; bottom: hints.top; bottomMargin: 8
                          left: parent.left; leftMargin: 10 }
                width: 396
                clip: true
                model: root.results
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: root.sel
                highlight: Item {
                    Rectangle {
                        width: parent.width; height: 42; radius: Tok.r
                        y: list.currentItem ? list.currentItem.headH : 0
                        Behavior on y { NumberAnimation { duration: Tok.mMicro } }
                        color: root.curType === "kill" ? Tok.critWash : Tok.accentWash
                        border.width: 1
                        border.color: root.curType === "kill" ? Tok.alpha(Tok.crit, 0.30) : Tok.alpha(Tok.accent, 0.25)
                        Rectangle { width: 3; height: 18; radius: 1.5
                            color: root.curType === "kill" ? Tok.crit : Tok.accent
                            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter } }
                    }
                }
                highlightMoveDuration: Tok.mMicro
                highlightResizeDuration: 0
                highlightMoveVelocity: -1
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property string group: root.groupOf(modelData.type)
                    readonly property bool opens: group !== "" && (index === 0
                        || root.groupOf((root.results[index - 1] || {}).type) !== group)
                    readonly property real headH: opens ? (index === 0 ? 24 : 32) : 0
                    width: list.width; height: headH + 42
                    Text {
                        visible: row.opens
                        anchors { left: parent.left; leftMargin: 12; bottom: rowBox.top; bottomMargin: 5 }
                        text: row.group
                        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.DemiBold
                    }
                    Rectangle {
                        id: rowBox
                        y: row.headH; width: parent.width; height: 42; radius: Tok.r
                        color: rowMa.containsMouse && index !== root.sel ? root.rowHover : "transparent"

                        Item {
                            id: ic; width: 26; height: 26
                            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                            property string ip: modelData.entry ? Quickshell.iconPath(modelData.entry.icon, true)
                                : (modelData.type === "window" ? Quickshell.iconPath(modelData.wicon || (modelData.cls || "").toLowerCase(), true) : "")
                            // Color swatch chip
                            Rectangle {
                                visible: modelData.type === "color"
                                anchors.fill: parent; radius: 7
                                color: modelData.hex || "transparent"
                                border.width: 1; border.color: root.cardEdge
                            }
                            IconImage { anchors.fill: parent; visible: ic.ip !== "" && !modelData.emoji && modelData.type !== "color"; source: ic.ip }
                            Rectangle { visible: !!modelData.clipImg; anchors.fill: parent; radius: Tok.rSmall; clip: true
                                color: Tok.accentWash; border.width: 1; border.color: Tok.alpha(Tok.accent, 0.35)
                                Image { id: thumbImg; anchors.fill: parent; anchors.margins: 1; asynchronous: true; cache: false
                                    fillMode: Image.PreserveAspectCrop; sourceSize.width: 52; sourceSize.height: 52
                                    source: modelData.clipImg ? (Tok.fileUrl(root.clipThumbDir + "/" + modelData.exec + ".png") + "?t=" + root.clipThumbTick) : "" }
                                Text { anchors.centerIn: parent; visible: thumbImg.status !== Image.Ready
                                    text: "image"; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: Tok.accent } }
                            Text { anchors.centerIn: parent; visible: !!modelData.emoji; text: modelData.emoji || ""; font.pixelSize: 21 }
                            Text { anchors.centerIn: parent; visible: ic.ip === "" && !!modelData.mi && !modelData.emoji && !modelData.clipImg && modelData.type !== "color"; text: modelData.mi || ""
                                font.family: "Material Symbols Outlined"; font.pixelSize: 20
                                color: modelData.warn ? Tok.crit : Tok.accent }
                            Rectangle { anchors.fill: parent; radius: Tok.rSmall; visible: ic.ip === "" && !modelData.mi && !modelData.emoji && modelData.type !== "color"
                                color: Tok.accentWash; border.width: 1; border.color: Tok.alpha(Tok.accent, 0.3)
                                Text { anchors.centerIn: parent; text: (modelData.entry ? modelData.entry.name : "?").charAt(0).toUpperCase()
                                    color: Tok.accent; font.pixelSize: 13; font.bold: true; font.family: Tok.sans } }
                        }
                        Text {
                            id: rowTitle
                            anchors { left: ic.right; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, parent.width - 74 - (rowKey.visible ? rowKey.width + 8 : 0))
                            elide: Text.ElideRight; textFormat: Text.StyledText
                            text: modelData.title; color: Tok.ink; font.pixelSize: 14; font.family: Tok.sans
                            font.weight: index === root.sel ? Font.DemiBold : Font.Normal
                        }
                        Text {
                            anchors { left: rowTitle.right; leftMargin: 8; right: rowKey.visible ? rowKey.left : parent.right
                                      rightMargin: 10; verticalCenter: parent.verticalCenter }
                            elide: Text.ElideRight; visible: modelData.type !== "app" || index !== root.sel
                            text: root.subOf(modelData); color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                        }
                        KeyCap {
                            id: rowKey
                            visible: index < 9 && (rowMa.containsMouse || index === root.sel) && modelData.type !== "hint"
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: index === root.sel ? "⏎" : "Alt " + (index + 1)
                        }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { if (root.sel === index) root.activate(index); else root.sel = index }
                            onDoubleClicked: root.activate(index) }
                    }
                }
                Text {
                    anchors.centerIn: parent; visible: root.results.length === 0
                    text: "Nothing matches"; color: Tok.ink3; font.pixelSize: 13; font.family: Tok.sans
                }
            }

            // ---------- elevated detail card (right) ----------
            Rectangle {
                id: detailCard
                anchors { top: modeBar.bottom; bottom: hints.top; left: list.right; right: parent.right
                          topMargin: 10; bottomMargin: 10; leftMargin: 10; rightMargin: 12 }
                radius: root.paneRad
                color: Tok.surface
                border.width: 1
                border.color: root.cardEdge
                clip: true

                Rectangle {
                    anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: 12; rightMargin: 12 }
                    height: 1; color: root.cardSheen
                }

                Item {
                    id: detail
                    anchors { fill: parent; margins: 20 }
                    readonly property var c: root.cur
                    readonly property string t: root.curType

                    // Live color swatch preview
                    Rectangle {
                        id: colorHero
                        visible: detail.t === "color"
                        width: parent.width; height: 140
                        radius: Tok.r + 2
                        color: detail.c && detail.c.hex ? detail.c.hex : "transparent"
                        border.width: 1; border.color: root.cardEdge
                        Column {
                            anchors.centerIn: parent; spacing: 4
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: detail.c && detail.c.hex ? detail.c.hex.toUpperCase() : ""
                                color: detail.c && detail.c.ink ? detail.c.ink : "white"
                                font.family: Tok.mono; font.pixelSize: 28; font.weight: Font.DemiBold
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: detail.c ? (detail.c.rgb || "") : ""
                                color: detail.c && detail.c.ink ? detail.c.ink : "white"
                                opacity: 0.85
                                font.family: Tok.mono; font.pixelSize: 12
                            }
                        }
                    }

                    // Window live preview — cap height so 2-line titles + action buttons never clip at the bottom
                    Rectangle {
                        id: shot
                        visible: detail.t === "window"
                        width: parent.width
                        height: Math.min(Math.round(width * 9 / 16), Math.max(130, detail.height - 168))
                        radius: Tok.r; color: Tok.sunken
                        border.width: 1; border.color: root.cardEdge
                        layer.enabled: visible
                        ScreencopyView {
                            id: scv
                            readonly property real ar: (scv.sourceSize && scv.sourceSize.height > 0)
                                ? scv.sourceSize.width / scv.sourceSize.height : 16 / 9
                            anchors.centerIn: parent
                            width: Math.min(parent.width - 12, (parent.height - 12) * ar); height: width / ar
                            captureSource: (root.shown && detail.t === "window" && detail.c && detail.c.top && detail.c.top.wayland)
                                ? detail.c.top.wayland : null
                            live: false
                        }
                        Text { anchors.centerIn: parent; visible: !scv.hasContent; text: "window"
                            font.family: "Material Symbols Outlined"; font.pixelSize: 40; color: Tok.ink3 }
                    }

                    // Hero icon / emoji / image preview
                    Item {
                        id: hero
                        visible: detail.t !== "window" && detail.t !== "calc" && detail.t !== "color" && detail.t !== ""
                        width: parent.width
                        height: (detail.t === "clip" && detail.c.clipImg) || (detail.t === "file" && root.isImage(detail.c.exec)) ? 190 : 68
                        readonly property string ip: (detail.c && detail.c.entry) ? Quickshell.iconPath(detail.c.entry.icon, true) : ""
                        IconImage { width: 60; height: 60; visible: hero.ip !== ""; source: hero.ip }
                        Text { visible: detail.t === "emoji"; text: detail.c ? (detail.c.emoji || "") : ""; font.pixelSize: 56 }
                        Rectangle {
                            visible: hero.ip === "" && detail.t !== "emoji" && hero.height < 100
                            width: 60; height: 60; radius: Tok.r + 4
                            color: detail.c && detail.c.warn ? Tok.critWash : Tok.accentWash
                            Text { anchors.centerIn: parent; text: detail.c ? (detail.c.mi || "apps") : ""
                                font.family: "Material Symbols Outlined"; font.pixelSize: 30
                                color: detail.c && detail.c.warn ? Tok.crit : Tok.accent }
                        }
                        Rectangle {
                            visible: hero.height >= 100
                            anchors.fill: parent; radius: Tok.r; color: Tok.sunken; clip: true
                            border.width: 1; border.color: root.cardEdge
                            Image {
                                anchors.fill: parent; anchors.margins: 8
                                fillMode: Image.PreserveAspectFit; asynchronous: true; cache: false
                                sourceSize.width: 640
                                source: !hero.visible || hero.height < 100 ? ""
                                    : detail.t === "clip" ? (root.peekImage || Tok.fileUrl(root.clipThumbDir + "/" + detail.c.exec + ".png") + "?t=" + root.clipThumbTick)
                                    : Tok.fileUrl(Quickshell.env("HOME") + "/" + detail.c.exec)
                            }
                        }
                    }

                    Column {
                        id: words
                        anchors {
                            top: colorHero.visible ? colorHero.bottom : (shot.visible ? shot.bottom : (hero.visible ? hero.bottom : parent.top))
                            topMargin: (colorHero.visible || shot.visible || hero.visible) ? 16 : 0
                            left: parent.left; right: parent.right
                        }
                        spacing: 6

                        // Calculator / conversion big readout
                        Text {
                            visible: detail.t === "calc"
                            width: parent.width; wrapMode: Text.WrapAnywhere; maximumLineCount: 3
                            text: detail.c ? root.plain(detail.c.title).replace(/^=\s*/, "") : ""
                            color: Tok.ink; font.pixelSize: Tok.tHero; font.family: Tok.sans; font.weight: Font.DemiBold
                            font.features: ({ "tnum": 1 })
                        }
                        Text {
                            visible: detail.t === "calc"
                            width: parent.width; elide: Text.ElideRight
                            text: root.query.replace(/^=/, "") + " ="
                            color: Tok.ink3; font.pixelSize: 13; font.family: Tok.mono
                        }

                        // Color copy rows
                        Column {
                            visible: detail.t === "color"
                            width: parent.width; spacing: 6
                            Repeater {
                                model: detail.t === "color" && detail.c ? [
                                    { l: "HEX", v: detail.c.hex.toUpperCase() },
                                    { l: "RGB", v: detail.c.rgb },
                                    { l: "HSL", v: detail.c.hsl }
                                ] : []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: words.width; height: 34; radius: Tok.r
                                    color: ccMa.containsMouse ? Tok.accentWash : Tok.sunken
                                    border.width: 1; border.color: ccMa.containsMouse ? Tok.alpha(Tok.accent, 0.35) : root.cardEdge
                                    Text { anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                        text: modelData.l; font.family: Tok.sans; font.pixelSize: 11; font.weight: Font.DemiBold; color: Tok.ink3 }
                                    Text { anchors { left: parent.left; leftMargin: 52; right: parent.right; rightMargin: 32; verticalCenter: parent.verticalCenter }
                                        text: modelData.v; font.family: Tok.mono; font.pixelSize: 12; color: Tok.ink; elide: Text.ElideRight }
                                    Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                        text: "content_copy"; font.family: "Material Symbols Outlined"; font.pixelSize: 15
                                        color: ccMa.containsMouse ? Tok.accent : Tok.ink3 }
                                    MouseArea { id: ccMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.copyText(modelData.v); root.close() } }
                                }
                            }
                        }

                        Text {
                            visible: detail.t !== "calc" && detail.t !== "color" && detail.t !== ""
                            width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                            text: !detail.c ? ""
                                : detail.t === "app" && detail.c.entry ? detail.c.entry.name
                                : detail.t === "window" ? (detail.c.wtitle || root.plain(detail.c.title))
                                : root.plain(detail.c.title)
                            color: Tok.ink; font.pixelSize: Tok.tTitle; font.family: Tok.sans; font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                            visible: text !== "" && detail.t !== "color"
                            text: !detail.c ? ""
                                : detail.t === "app" && detail.c.entry ? (detail.c.entry.comment || detail.c.entry.genericName || "")
                                : detail.t === "window" ? root.plain(detail.c.title) + "  ·  workspace " + detail.c.ws
                                : detail.t === "file" ? "~/" + detail.c.exec
                                : detail.t === "web" ? detail.c.exec
                                : detail.t === "run" || detail.t === "term" || detail.t === "calc" ? ""
                                : root.subOf(detail.c)
                            color: Tok.ink2; font.pixelSize: 13; font.family: Tok.sans
                        }

                        // Metadata facts
                        Item { width: 1; height: 4; visible: metaRep.count > 0 }
                        Repeater {
                            id: metaRep
                            model: {
                                var c = detail.c, out = [];
                                if (!c) return out;
                                if (c.type === "app" && c.entry) {
                                    var h = root.hist[c.entry.id];
                                    if (h) out.push({ k: "Opened", v: h.n + (h.n === 1 ? " time" : " times") + ", last " + root.ago(h.t) });
                                    if (c.entry.genericName && c.entry.comment) out.push({ k: "Kind", v: c.entry.genericName });
                                    var bin = (c.entry.execString || "").split(" ")[0].split("/").pop();
                                    if (bin) out.push({ k: "Runs", v: bin });
                                } else if (c.type === "kill") {
                                    out.push({ k: "PID", v: String(c.pid) });
                                    out.push({ k: "CPU", v: c.cpu + "%" });
                                    out.push({ k: "Memory", v: c.rss + " MB" });
                                } else if (c.type === "run" || c.type === "term") {
                                    out.push({ k: "Command", v: c.exec });
                                    out.push({ k: "Where", v: c.type === "term" ? "a kitty window that stays open" : "in the background" });
                                }
                                return out;
                            }
                            delegate: Row {
                                required property var modelData
                                spacing: 10; width: words.width
                                Text { width: 68; text: modelData.k; color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans }
                                Text { width: parent.width - 78; text: modelData.v; color: Tok.ink2; font.pixelSize: 12
                                    font.family: (modelData.k === "Command" || modelData.k === "Runs" || modelData.k === "PID" || modelData.k === "CPU" || modelData.k === "Memory") ? Tok.mono : Tok.sans
                                    wrapMode: Text.WrapAnywhere; maximumLineCount: 3; elide: Text.ElideRight }
                            }
                        }

                        // Peek preview (clipboard text / text files / directory entries)
                        Rectangle {
                            visible: root.peekText !== "" && (detail.t === "clip" || detail.t === "file")
                            width: parent.width; height: Math.min(peekT.implicitHeight + 20, 175)
                            radius: Tok.r; color: Tok.sunken; clip: true
                            border.width: 1; border.color: root.cardEdge
                            Text { id: peekT; x: 10; y: 10; width: parent.width - 20
                                text: root.peekText; textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere
                                color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono; lineHeight: 1.15 }
                        }

                        // Action buttons for the selected item
                        Item { width: 1; height: 4 }
                        Flow {
                            width: parent.width; spacing: 8
                            visible: detail.c !== null && detail.t !== "hint" && detail.t !== "color" && detail.t !== ""
                            DetailBtn {
                                primary: detail.t !== "kill"
                                danger: detail.t === "kill"
                                icon: detail.t === "kill" ? "stop_circle" : (detail.t === "calc" || detail.t === "clip" || detail.t === "emoji" ? "content_copy" : "arrow_forward")
                                label: root.enterVerb
                                onTapped: root.activate(root.sel, false)
                            }
                            DetailBtn {
                                visible: detail.t === "kill"
                                danger: true; icon: "dangerous"; label: "Force kill"
                                onTapped: root.activate(root.sel, true)
                            }
                            DetailBtn {
                                visible: detail.t === "window"
                                danger: true; icon: "close"; label: "Close window"
                                onTapped: {
                                    if (detail.c && detail.c.address)
                                        Hyprland.dispatch("hl.dsp.window.close({ window = 'address:" + detail.c.address + "' })");
                                    root.close();
                                }
                            }
                            DetailBtn {
                                visible: detail.t === "file"
                                icon: "folder_open"; label: "Reveal folder"
                                onTapped: {
                                    var p = detail.c.exec || "";
                                    var dir = p.indexOf("/") >= 0 ? p.slice(0, p.lastIndexOf("/")) : "";
                                    Quickshell.execDetached(["sh", "-c", "xdg-open \"$HOME/$1\"", "sh", dir]);
                                    root.close();
                                }
                            }
                            DetailBtn {
                                visible: detail.t === "file"
                                icon: "content_copy"; label: "Copy path"
                                onTapped: { root.copyText(Quickshell.env("HOME") + "/" + (detail.c.exec || "")); root.close() }
                            }
                        }

                        // Desktop entry extra actions (New Private Window, etc.)
                        Repeater {
                            model: (detail.t === "app" && detail.c && detail.c.entry && detail.c.entry.actions) ? detail.c.entry.actions : []
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: words.width; height: 34; radius: Tok.r
                                color: actMa.containsMouse ? Tok.accentWash : Tok.sunken
                                border.width: 1; border.color: actMa.containsMouse ? Tok.alpha(Tok.accent, 0.3) : root.cardEdge
                                Text { anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                    text: "subdirectory_arrow_right"; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: Tok.ink3 }
                                Text { anchors { left: parent.left; leftMargin: 36; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                    text: modelData.name; elide: Text.ElideRight
                                    color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans }
                                MouseArea { id: actMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.bump(detail.c.entry.id); modelData.execute(); root.close() } }
                            }
                        }
                    }
                }
            }

            // ---------- footer ----------
            Item {
                id: hints
                width: parent.width; height: 40
                anchors.bottom: parent.bottom
                Rectangle { width: parent.width; height: 1; color: Tok.rule }
                Text {
                    anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                    text: root.results.length + (root.results.length === 1 ? " result" : " results")
                    color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                }
                Row {
                    anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                    spacing: 14
                    Row { spacing: 5; KeyCap { text: "↑↓"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "Move"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter } }
                    Row { visible: root.cur !== null && root.curType !== "hint"; spacing: 5
                        KeyCap { text: "⏎"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: root.enterVerb; color: Tok.ink2; font.pixelSize: 11; font.weight: Font.Medium; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter } }
                    Row { visible: root.curType === "kill" || root.curType === "run"; spacing: 5
                        KeyCap { text: "Ctrl+⏎"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: root.curType === "kill" ? "Force" : "Kitty"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter } }
                    Row { spacing: 5; KeyCap { text: "Esc"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "Close"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; anchors.verticalCenter: parent.verticalCenter } }
                }
            }
        }
    }
}
