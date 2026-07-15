// ─────────────────────────────────────────────────────────────────────────────
// sea-shell — Moondrop DAC control panel
//
// Instantiated by shell.qml. Talks to scripts/system/moondrop_control.py (the
// reverse-engineered controller) over its --json / --set-* CLI. Parametric EQ
// with a live frequency-response graph (region-labelled), an all-bands column
// editor, pre-gain / global-offset, preset selection, an in-panel tuning guide,
// and save-to-flash.
//
// Everything device-shaped comes from --json rather than being assumed here:
// band count, which slot custom PEQ lives on, and whether the device supports
// pre-gain at all. The script is the single source of truth for the device
// registry — don't re-hardcode it.
//
// This panel does NOT try to tell you whether the EQ is switched on. On a DAWN
// PRO2 that is a hardware toggle (both volume buttons at once), and it is not
// reflected in any register the DAC exposes — every readable sub-command reads
// identical in both modes. The active EQ profile is NOT a proxy for it either:
// firmware 1.5 reports profile 9 whether the EQ is on or off, while band writes
// are audible in custom-EQ mode regardless. The official app assumes otherwise
// (isInPEQMode: readEQIndex() === peqIndex) and is simply wrong on this firmware.
//
// Toggle:  qs -c sea-shell ipc call dac toggle   (SUPER+SHIFT+E)
// ─────────────────────────────────────────────────────────────────────────────
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

Scope {
    id: root

    // the shell flattens scripts next to the QML on deploy, so resolve it as a sibling
    readonly property string pyScript: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "") + "/moondrop_control.py"

    // ---- lifecycle ----
    property bool shown: false
    property bool helpOpen: false
    function open()   { root.shown = true; root.dirty = false; root.pristine = null; root.refresh() }
    function close()  { root.shown = false; root.helpOpen = false }
    function toggle() { if (root.shown) root.close(); else root.open() }
    IpcHandler {
        target: "dac"
        function toggle(): void { root.toggle() }
        function open(): void   { root.open() }
        function close(): void  { root.close() }
    }

    // ---- device state (all of it read from the script; nothing assumed) ----
    property var  dev: ({ ok: false })
    property var  bands: []          // [{index,type,frequency,gain,q}]
    property real pregain: 0
    property real globalGain: 0
    property int  profile: 0
    property int  sel: 0             // selected band index
    property bool dirty: false       // unsaved live edits pending a flash write
    property int  bandCount: 8       // device band count (--json "bands")
    property int  peqIndex: 7        // slot custom PEQ lives on; 4 on E.S. combo
    property bool supportsPregain: true
    property string lastError: ""    // last refusal from the script, shown as a toast

    // The DAC's state as last known *saved*: the first read of a session, and again
    // after each save-to-flash. Edits go to the DSP live (--no-flash), and a re-read
    // reports what we just wrote — the DSP has no way to tell us what flash still
    // holds. So re-reading can never undo an edit; only this snapshot can.
    property var pristine: null
    function snapshot() {
        root.pristine = { bands: JSON.parse(JSON.stringify(root.bands)),
                          pregain: root.pregain, globalGain: root.globalGain };
    }
    function revert() {
        if (!root.pristine) return;
        root.bands = JSON.parse(JSON.stringify(root.pristine.bands));
        root.pregain = root.pristine.pregain;
        root.globalGain = root.pristine.globalGain;
        for (var i = 0; i < root.bands.length; i++) root.applyBand(i);
        if (root.supportsPregain) root.applyPregain();
        root.applyGlobal();
        root.dirty = false;   // applyBand set it true; we're back at the saved state
    }

    Process { id: jsonProc; command: ["python3", root.pyScript, "--json"]
        stdout: StdioCollector { id: jsonOut; onStreamFinished: {
            try {
                var d = JSON.parse(jsonOut.text.trim() || "{}");
                root.dev = d;
                if (d.ok) {
                    root.bands = d.filters || [];
                    root.reorder();
                    root.pregain = d.pregain || 0;
                    root.globalGain = d.global_gain || 0;
                    root.profile = d.active_eq_profile || 0;
                    // tolerate an older script that predates these fields
                    root.bandCount = d.bands || (d.filters ? d.filters.length : 8);
                    root.peqIndex = d.peq_index !== undefined ? d.peq_index : 7;
                    root.supportsPregain = d.supports_pregain !== undefined ? d.supports_pregain : true;
                    if (root.sel >= root.bands.length) root.sel = 0;
                    // Deliberately NOT clearing dirty here: a reload tells us what the
                    // DSP is playing, which says nothing about whether flash matches it.
                    if (root.pristine === null) root.snapshot();
                }
            } catch(e) { root.dev = { ok: false, error: "parse error: " + e }; }
            root._finishRefresh();
        } } }

    // ---- device access queue ----
    // EVERY call to the script goes through here, reads included. Two processes must
    // never touch the DAC at once: they share one hidraw and one reply queue, so
    // concurrent commands can pick up each other's answers. The refresh used to be
    // fired straight from _done() while _pump() started the next write in the same
    // breath — exactly that race.
    //
    // Writes also can't be fire-and-forget: the script refuses a filter it can't
    // represent, so we read stdout back and resync the graph when that happens.
    property var  _queue: []
    property bool _busy: false

    function refresh() { root._queue.push({ refresh: true }); root._pump() }
    function run(argv, reload) {
        root._queue.push({ argv: argv });
        if (reload) root._queue.push({ refresh: true });
        root._pump();
    }
    function _pump() {
        if (root._busy || root._queue.length === 0) return;
        root._busy = true;
        var job = root._queue[0];
        if (job.refresh) { jsonProc.running = true; return; }   // _finishRefresh steps the queue
        wProc.command = ["python3", root.pyScript].concat(job.argv);
        wProc.running = true;
    }
    function _finishRefresh() {
        if (root._queue.length > 0 && root._queue[0].refresh) {
            root._queue.shift();
            root._busy = false;
        }
        root._pump();
    }
    // The script reports refusals as "Error: ..." on stdout and exits 1; a traceback
    // would land on stderr. Keyed off output rather than exit code so it doesn't
    // depend on exited/streamFinished ordering. stdout owns the queue step; stderr
    // only ever adds an error, so an empty one can't advance or stall the queue.
    function _done(out) {
        root._queue.shift();
        root._busy = false;
        var m = ("" + out).match(/^Error:\s*([\s\S]+)$/m);
        if (m) {
            root.lastError = m[1].trim();
            errTimer.restart();
            // Anything still queued was built on a write that didn't land — drop it
            // and go ask the DAC what it actually holds.
            root._queue = [];
            root.refresh();
            return;
        }
        root._pump();
    }
    Process {
        id: wProc
        stdout: StdioCollector { id: wOut; onStreamFinished: root._done(wOut.text) }
        stderr: StdioCollector { id: wErr; onStreamFinished: {
            if (wErr.text.trim() !== "") { root.lastError = wErr.text.trim().split("\n").pop(); errTimer.restart(); } } }
    }
    Timer { id: errTimer; interval: 9000; onTriggered: root.lastError = "" }

    // ---- import from a file, picked in-shell ----
    // zenity is the one portable picker present here (no kdialog/yad/portal).
    Process { id: pickProc
        command: ["zenity", "--file-selection", "--title=Import EQ preset",
                  "--file-filter=EQ presets (AutoEQ/REW .txt, .json) | *.txt *.json",
                  "--file-filter=All files | *"]
        stdout: StdioCollector { id: pickOut; onStreamFinished: {
            var p = pickOut.text.trim();
            if (p !== "") root.importFile(p);
        } } }
    function pickImport() { pickProc.running = true }
    function importFile(path) {
        // Live, not flashed: audition it first, then hit save to keep it.
        var flag = /\.json$/i.test(path) ? "--import-json" : "--import-rew";
        root.run(["--no-flash", flag, path], true);
        root.dirty = true;
    }

    function applyBand(i) {
        var b = root.bands[i]; if (!b) return;
        root.run(["--no-flash", "--set-peq", "" + b.index, "" + b.type,
                  "" + Math.round(b.frequency), b.gain.toFixed(2), b.q.toFixed(3)]);
        root.dirty = true;
    }
    function applyPregain()  { root.run(["--no-flash", "--set-pregain", root.pregain.toFixed(2)]); root.dirty = true }
    function applyGlobal()   { root.run(["--no-flash", "--set-globalgain", root.globalGain.toFixed(2)]); root.dirty = true }
    function applyProfile()  { root.run(["--no-flash", "--set-eq-index", "" + root.profile], true); root.dirty = true }
    // What's live is now what's in flash, so this becomes the new revert target.
    function saveFlash()     { root.run(["--save-flash"]); root.dirty = false; root.snapshot() }

    // Largest Q a shelf can take at this gain. RBJ's shelf formulas read Q as slope,
    // and past this there's no real filter — the python raises ShelfSlopeError and the
    // graph maths would go NaN. Mirrors max_shelf_q() in the script; the 0.995 keeps
    // float drift between the two from landing us a hair over its limit.
    readonly property real qMax: 10
    function qCeiling(type, gain) {
        if (type !== "low_shelf" && type !== "high_shelf") return root.qMax;
        var a = Math.pow(10, Math.abs(gain) / 40), s = a + 1/a;
        if (s <= 2) return root.qMax;
        return Math.min(root.qMax, 1 / (1 - 2/s) * 0.995);
    }

    // ---- Q2.30 coefficient headroom ----------------------------------------
    // The firmware stores coefficients as Q2.30, which only spans [-2, 2). Some
    // perfectly reasonable-looking filters need coefficients outside that, and the
    // script refuses those writes outright. Rather than let a drag sail past the
    // limit and bounce back as a refusal toast, work out the ceiling here and stop
    // the control at it — the same way Q is already clamped to qCeiling.
    //
    // Mirrors pack_coefficients() in the script: it packs [b0,b1,b2,-a1,-a2] and
    // every one of those must land inside int32 once scaled by 2^30.
    readonly property real q30Scale: 1073741824
    function fits(type, f0, gain, Q) {
        var c = root.coeffs(f0, gain, Q, type);
        if (!c) return true;                       // disabled → flat → always fine
        var v = [c.b[0], c.b[1], c.b[2], -c.a[1], -c.a[2]];
        for (var i = 0; i < 5; i++) {
            if (!isFinite(v[i])) return false;
            if (Math.abs(Math.round(v[i] * root.q30Scale)) > 2147483647) return false;
        }
        return true;
    }
    // Largest |gain| in this sign direction whose coefficients still fit. Bisection,
    // mirroring max_safe_gain() in the script. Returns 0 when nothing fits (a high
    // shelf below ~200 Hz overflows at ANY gain — b1 is already past -2 at +0.05 dB).
    function gainCeiling(type, f0, Q, sign) {
        if (root.fits(type, f0, sign * root.dbMax, Q)) return root.dbMax;
        var lo = 0, hi = root.dbMax;
        for (var n = 0; n < 24; n++) {
            var mid = (lo + hi) / 2;
            if (root.fits(type, f0, sign * mid, Q)) lo = mid; else hi = mid;
        }
        return lo;
    }

    // Is this band pinned against the coefficient ceiling? (nudging it further in the
    // same direction would overflow) — drives the "limit" tag on the column.
    function atCeiling(b) {
        if (!b || b.type === "disabled") return false;
        var sign = b.gain >= 0 ? 1 : -1;
        return !root.fits(b.type, b.frequency, b.gain + sign * 0.15, b.q);
    }

    // immutably patch a band so bindings/repaint fire, then optionally push to the device
    function setBand(i, patch, write) {
        var arr = root.bands.slice();
        var nb = {}; for (var k in arr[i]) nb[k] = arr[i][k];
        for (var p in patch) nb[p] = patch[p];
        // Clamp here rather than at each caller: raising gain can invalidate a Q that
        // was fine a moment ago, so type/gain/Q edits all have to re-check.
        var ceil = root.qCeiling(nb.type, nb.gain);
        if (nb.q > ceil) nb.q = Math.round(ceil * 1000) / 1000;
        // Then the coefficient-range ceiling, which depends on type/freq/Q together.
        if (nb.type !== "disabled" && !root.fits(nb.type, nb.frequency, nb.gain, nb.q)) {
            var sign = nb.gain >= 0 ? 1 : -1;
            var gc = root.gainCeiling(nb.type, nb.frequency, nb.q, sign);
            nb.gain = Math.round(sign * gc * 10) / 10;
            // Bisection can land a hair over the limit; walk it back until it fits.
            for (var g = 0; g < 8 && !root.fits(nb.type, nb.frequency, nb.gain, nb.q); g++)
                nb.gain = Math.round((nb.gain - sign * 0.1) * 10) / 10;
        }
        arr[i] = nb; root.bands = arr;
        if (write) root.applyBand(i);
    }
    // ---- column order ----------------------------------------------------------
    // The columns carry region tags (SUB → AIR), which promises a left-to-right sweep
    // up the spectrum. The DAC's slots are in whatever order they were written, so a
    // 1 kHz band can sit between 6 kHz and 14 kHz and break that promise. Sort for
    // display only; writes still go to the true slot, which each column labels.
    //
    // Deliberately NOT a binding on bands: re-sorting live would slide a column out
    // from under the cursor mid-drag. Recomputed on load and on preset apply, where
    // the layout is expected to change anyway.
    property var bandOrder: []
    function reorder() {
        var bs = root.bands, idx = [];
        for (var i = 0; i < bs.length; i++) idx.push(i);
        idx.sort(function(a, b) {
            var A = bs[a], B = bs[b];
            var ad = A.type === "disabled", bd = B.type === "disabled";
            if (ad !== bd) return ad ? 1 : -1;               // unused bands park on the right
            if (A.frequency !== B.frequency) return A.frequency - B.frequency;
            return a - b;                                     // stable for equal frequencies
        });
        root.bandOrder = idx;
    }
    function slotAt(col) { return root.bandOrder.length === root.bands.length ? root.bandOrder[col] : col }

    // ---- starting-point curves -------------------------------------------------
    // Not the DAC's built-in preset slots (that's the hardware "slot" number) — these
    // just fill the bands with a known-good shape you can then tweak.
    //
    // Every band here was checked against the script's own packer: all fit inside the
    // firmware's Q2.30 coefficient range with headroom, so none get clamped on apply.
    // The tight ones are the high shelves (V-shape +3 vs a +4.65 ceiling at 8 kHz,
    // Air +4 vs +5.36 at 9 kHz) — if you retune these, re-check them.
    //
    // pre is pre-gain: roughly minus the biggest boost, so boosts don't clip.
    readonly property var presets: [
        { nm: "Flat",     ic: "remove",          pre:  0.0, bands: [] },
        { nm: "Bass",     ic: "graphic_eq",      pre: -4.0, bands: [["low_shelf",100,4.0,0.7]] },
        { nm: "V-shape",  ic: "show_chart",      pre: -4.5, bands: [["low_shelf",90,4.0,0.7],["peaking",900,-2.0,1.0],["high_shelf",8000,3.0,0.7]] },
        { nm: "Vocals",   ic: "record_voice_over",pre: -3.5, bands: [["peaking",200,-3.0,1.2],["peaking",450,-2.0,1.0],["peaking",2600,3.0,1.2]] },
        { nm: "Warm",     ic: "local_fire_department", pre: -3.5, bands: [["low_shelf",220,3.0,0.7],["high_shelf",6000,-3.0,0.7]] },
        { nm: "Air",      ic: "air",             pre: -4.0, bands: [["high_shelf",9000,4.0,0.7],["peaking",5000,-1.5,2.0]] },
        { nm: "Podcast",  ic: "podcasts",        pre: -3.5, bands: [["high_pass",85,0.0,0.7],["peaking",300,-2.5,1.0],["peaking",3000,3.0,1.2]] },
        { nm: "Loudness", ic: "volume_up",       pre: -5.5, bands: [["low_shelf",80,5.0,0.7],["high_shelf",10000,3.5,0.7],["peaking",1500,-1.5,1.0]] }
    ]
    // Fill every slot: bands the preset doesn't define are explicitly disabled, so
    // applying one never leaves a stray filter from whatever was there before.
    function applyPreset(p) {
        var arr = [];
        for (var i = 0; i < root.bandCount; i++) {
            var s = p.bands[i];
            arr.push(s ? { index: i, type: s[0], frequency: s[1], gain: s[2], q: s[3] }
                       : { index: i, type: "disabled", frequency: 1000, gain: 0, q: 1.0 });
        }
        root.bands = arr;
        root.reorder();
        root.pregain = p.pre;
        for (var j = 0; j < arr.length; j++) root.applyBand(j);
        if (root.supportsPregain) root.applyPregain();
        root.dirty = true;
    }

    readonly property var filterTypes: ["peaking","low_shelf","high_shelf","low_pass","high_pass","disabled"]
    function typeAbbr(t) { return ({peaking:"PK", low_shelf:"LS", high_shelf:"HS", low_pass:"LP", high_pass:"HP", disabled:"—"})[t] || "PK" }
    function typeName(t) { return (t || "peaking").replace("_", " ") }
    function cycleType(i, dir) {
        var n = root.filterTypes.indexOf(root.bands[i].type); if (n < 0) n = 0;
        n = (n + dir + root.filterTypes.length) % root.filterTypes.length;
        root.setBand(i, { type: root.filterTypes[n] }, true);
    }
    function stepFreq(i, dir) {
        var f = root.bands[i].frequency * (dir > 0 ? 1.06 : 1/1.06);
        root.setBand(i, { frequency: Math.round(root.clamp(f, fMin, fMax)) }, true);
    }
    function fmtHz(f) { return f >= 1000 ? (f/1000).toFixed(f % 1000 === 0 ? 0 : 1) + "k" : ("" + Math.round(f)) }

    // ---- graph math (log-freq X, ±dbMax dB Y) ----
    readonly property real dbMax: 12
    readonly property real fMin: 20
    readonly property real fMax: 20000
    readonly property real l0: Math.log(fMin) / Math.LN10
    readonly property real l1: Math.log(fMax) / Math.LN10
    function xOfFreq(f, w) { return (Math.log(f)/Math.LN10 - l0) / (l1 - l0) * w }
    function freqOfX(x, w) { return Math.pow(10, l0 + Math.max(0, Math.min(1, x/w)) * (l1 - l0)) }
    function yOfDb(db, h)  { return h/2 - (db/dbMax) * (h/2) }
    function dbOfY(y, h)   { return (h/2 - y) / (h/2) * dbMax }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    // frequency regions — labels the graph and each band ("what tunes what")
    readonly property var regionDefs: [
        {n:"SUB",      f1:20,   f2:60,    c:"#6f8bd6"},
        {n:"BASS",     f1:60,   f2:250,   c:"#5a90d2"},
        {n:"LOW-MID",  f1:250,  f2:500,   c:"#4fa0c8"},
        {n:"MID",      f1:500,  f2:2000,  c:"#4fb8ac"},
        {n:"UPPER-MID",f1:2000, f2:4000,  c:"#5fc79a"},
        {n:"PRESENCE", f1:4000, f2:6000,  c:"#9fd48a"},
        {n:"AIR",      f1:6000, f2:20000, c:"#ccd98a"}
    ]
    function regionOf(f) {
        for (var i = 0; i < regionDefs.length; i++) if (f < regionDefs[i].f2 || i === regionDefs.length - 1) return regionDefs[i];
        return regionDefs[0];
    }

    // RBJ biquad → {b:[b0,b1,b2], a:[a0,a1,a2]} (a0 normalised to 1) — mirrors the python
    function coeffs(f0, gain, Q, type) {
        var w0 = 2 * Math.PI * f0 / 96000, cw = Math.cos(w0), sw = Math.sin(w0);
        if (type === "peaking") {
            var A = Math.sqrt(Math.pow(10, gain/20)), al = sw/(2*Q), a0 = al/A + 1;
            return { b: [(al*A+1)/a0, -2*cw/a0, (1-al*A)/a0], a: [1, -2*cw/a0, (1-al/A)/a0] };
        } else if (type === "low_shelf" || type === "high_shelf") {
            var amp = Math.pow(10, gain/40);
            // Same shelf-slope term as the python. Its radicand goes negative once Q is
            // too steep for the gain, and Math.sqrt would hand back NaN and erase the
            // curve rather than throw. setBand keeps Q under qCeiling so this shouldn't
            // trigger; floor it anyway for bands read off a DAC some other tool wrote.
            var alpha = sw/2 * Math.sqrt(Math.max(0, (amp + 1/amp) * (1/Q - 1) + 2));
            var tsa = 2 * Math.sqrt(amp) * alpha;
            if (type === "low_shelf") {
                var d0 = amp + 1 + (amp-1)*cw + tsa;
                return { b: [amp*(amp+1-(amp-1)*cw+tsa)/d0, 2*amp*(amp-1-(amp+1)*cw)/d0, amp*(amp+1-(amp-1)*cw-tsa)/d0],
                         a: [1, -2*(amp-1+(amp+1)*cw)/d0, (amp+1+(amp-1)*cw-tsa)/d0] };
            } else {
                var e0 = amp + 1 - (amp-1)*cw + tsa;
                return { b: [amp*(amp+1+(amp-1)*cw+tsa)/e0, -2*amp*(amp-1+(amp+1)*cw)/e0, amp*(amp+1+(amp-1)*cw-tsa)/e0],
                         a: [1, 2*(amp-1-(amp+1)*cw)/e0, (amp+1-(amp-1)*cw-tsa)/e0] };
            }
        } else if (type === "low_pass" || type === "high_pass") {
            var aq = sw/(2*Q), f0n = aq + 1;
            if (type === "low_pass")
                return { b: [(1-cw)/2/f0n, (1-cw)/f0n, (1-cw)/2/f0n], a: [1, -2*cw/f0n, (1-aq)/f0n] };
            return { b: [(1+cw)/2/f0n, -(1+cw)/f0n, (1+cw)/2/f0n], a: [1, -2*cw/f0n, (1-aq)/f0n] };
        }
        return null; // disabled → flat
    }
    function bandDb(band, f) {
        if (!band || band.type === "disabled") return 0;
        var c = coeffs(band.frequency, band.gain, band.q, band.type); if (!c) return 0;
        var w = 2 * Math.PI * f / 96000, c1 = Math.cos(w), c2 = Math.cos(2*w), s1 = Math.sin(w), s2 = Math.sin(2*w);
        var nr = c.b[0] + c.b[1]*c1 + c.b[2]*c2, ni = -(c.b[1]*s1 + c.b[2]*s2);
        var dr = c.a[0] + c.a[1]*c1 + c.a[2]*c2, di = -(c.a[1]*s1 + c.a[2]*s2);
        var mag = Math.sqrt((nr*nr + ni*ni) / (dr*dr + di*di));
        return 20 * Math.log(mag) / Math.LN10;
    }
    function totalDb(f) { var s = 0; for (var i = 0; i < root.bands.length; i++) s += root.bandDb(root.bands[i], f); return s }

    // ---- digital headroom ------------------------------------------------------
    // Boosts are gain applied in the DSP: the summed curve peaking at +6 dB means
    // peaks are 6 dB hotter than the source, and anything already near full scale
    // clips. Pre-gain buys that back by attenuating first, which is the whole reason
    // AutoEQ ships a preamp value with every profile. The guide has said "set pre-gain
    // ≈ minus your biggest boost" all along; nothing was checking whether you had.
    //
    // Peak of the SUMMED curve, not the biggest single band — overlapping bands add.
    readonly property real curvePeak: {
        var bs = root.bands;                       // dependency
        var pk = 0;
        for (var n = 0; n <= 120; n++) {
            var f = Math.pow(10, root.l0 + (n / 120) * (root.l1 - root.l0));
            var s = 0;
            for (var i = 0; i < bs.length; i++) s += root.bandDb(bs[i], f);
            if (s > pk) pk = s;
        }
        return pk;
    }
    // >0 means the curve overshoots full scale by that much. 0.05 dB of slack keeps
    // float noise from flickering the warning on an otherwise exactly-matched preset.
    readonly property real overshoot: root.curvePeak + root.pregain
    readonly property bool clipping: root.dev.ok && root.supportsPregain && root.overshoot > 0.05
    function matchHeadroom() {
        root.pregain = root.clamp(Math.round(-root.curvePeak * 10) / 10, -24, 6);
        root.applyPregain();
    }

    // ---- theme (reads the shared appearance.json so it matches the rice) ----
    property string apAccent: "#63c7dd"
    property bool   apLight: false
    Process { running: true; command: ["sh","-c","cat ~/.config/sea-shell/appearance.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j = JSON.parse(apOut.text.trim() || "{}");
            if (j.accent) root.apAccent = j.accent; if (j.mode !== undefined) root.apLight = ("" + j.mode === "light"); } catch(e){} } } }
    QtObject {
        id: theme
        readonly property bool light: root.apLight
        readonly property color bg:    light ? "#e8eef5" : "#0d1420"
        readonly property color panel: light ? "#dbe3ee" : "#161d2b"
        readonly property color line:  light ? "#c2ccd9" : "#24304a"
        readonly property color text:  light ? "#0c1520" : "#e2e9f4"
        readonly property color sub:   light ? "#2c4256" : "#a6b6cf"
        readonly property color faint: light ? "#48606f" : "#6f8099"
        readonly property color iris:  light ? Qt.darker(root.apAccent, 2.4) : root.apAccent
        readonly property color frost: light ? Qt.darker(root.apAccent, 1.7) : Qt.lighter(root.apAccent, 1.22)
        readonly property color good:  light ? "#2f9e63" : "#a6e3a1"
        readonly property color warn:  light ? "#b9820f" : "#f4c542"
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    component Sym: Text { property int sz: 18; font.family: "Material Symbols Outlined"; font.pixelSize: sz
        color: theme.iris; verticalAlignment: Text.AlignVCenter }

    // horizontal slider (pre-gain / global offset)
    component DSlider: Item {
        id: sl
        property real from: 0; property real to: 1; property real value: 0
        property color fill: theme.iris
        signal moved(real v); signal committed(real v)
        implicitHeight: 18; Layout.fillWidth: true
        readonly property real t: sl.to === sl.from ? 0 : (sl.value - sl.from) / (sl.to - sl.from)
        Rectangle { id: trk; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5; radius: 3; color: theme.a(theme.line, 0.85)
            Rectangle { width: trk.width * Math.max(0, Math.min(1, sl.t)); height: parent.height; radius: 3; color: sl.fill } }
        Rectangle { width: 14; height: 14; radius: 7; border.width: 2; border.color: sl.fill; color: theme.frost
            anchors.verticalCenter: parent.verticalCenter; x: (sl.width - width) * Math.max(0, Math.min(1, sl.t)) }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            function put(px) { var tt = Math.max(0, Math.min(1, px / sl.width)); sl.value = sl.from + tt * (sl.to - sl.from); sl.moved(sl.value) }
            onPressed: (e) => put(e.x)
            onPositionChanged: (e) => { if (pressed) put(e.x) }
            onReleased: () => sl.committed(sl.value) }
    }

    // vertical gain slider (band columns) — fills from the 0 dB centre line
    component VSlider: Item {
        id: vs
        property real from: -12; property real to: 12; property real value: 0
        property color fill: theme.iris
        signal moved(real v); signal committed(real v)
        implicitWidth: 24
        function tOf(v) { return vs.to === vs.from ? 0 : (v - vs.from) / (vs.to - vs.from) }
        Rectangle { id: vtrk; width: 6; radius: 3; color: theme.a(theme.line, 0.85)
            anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.bottom: parent.bottom
            Rectangle { width: parent.width + 5; x: -2.5; height: 1; color: theme.a(theme.faint, 0.7); y: vtrk.height * (1 - vs.tOf(0)) }
            Rectangle { width: parent.width; radius: 3; color: vs.fill
                property real cy: vtrk.height * (1 - vs.tOf(0)); property real ky: vtrk.height * (1 - vs.tOf(vs.value))
                y: Math.min(cy, ky); height: Math.abs(cy - ky) } }
        Rectangle { width: 20; height: 12; radius: 4; color: theme.frost; border.width: 2; border.color: vs.fill
            anchors.horizontalCenter: parent.horizontalCenter; y: vtrk.height * (1 - vs.tOf(vs.value)) - height/2 }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            function put(py) { var t = 1 - Math.max(0, Math.min(1, py / vs.height)); vs.value = vs.from + t * (vs.to - vs.from); vs.moved(vs.value) }
            onPressed: (e) => put(e.y)
            onPositionChanged: (e) => { if (pressed) put(e.y) }
            onReleased: () => vs.committed(vs.value) }
    }

    component IconBtn: Rectangle {
        id: ib
        property string icon: ""; property int sz: 30; signal tapped()
        implicitWidth: sz + 4; implicitHeight: sz + 4; radius: 8
        color: ibm.containsMouse ? theme.a(theme.iris, 0.18) : "transparent"
        Sym { anchors.centerIn: parent; text: ib.icon; sz: Math.round(ib.sz * 0.6); color: theme.sub }
        MouseArea { id: ibm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ib.tapped() }
    }
    component TextBtn: Rectangle {
        id: tb
        property string label: ""; property string icon: ""; property bool primary: false; signal tapped()
        implicitHeight: 32; implicitWidth: tbr.width + 22; radius: 9
        opacity: tb.enabled ? 1 : 0.4
        color: tb.primary ? (tbm.containsMouse ? theme.frost : theme.iris) : (tbm.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: theme.a(theme.iris, tb.primary ? 0.5 : 0.2)
        RowLayout { id: tbr; anchors.centerIn: parent; spacing: 7
            Sym { text: tb.icon; sz: 15; color: tb.primary ? theme.bg : theme.frost }
            Text { text: tb.label; color: tb.primary ? theme.bg : theme.sub; font.pixelSize: 11; font.family: "monospace"; font.bold: tb.primary } }
        MouseArea { id: tbm; anchors.fill: parent; enabled: tb.enabled; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tb.tapped() }
    }
    component OffsetTile: Rectangle {
        id: ot
        property string label: ""; property string unit: ""; property string hint: ""; property real from: 0; property real to: 1; property real value: 0
        // alert recolours the tile; action adds a one-tap fix chip beside the readout
        property bool alert: false
        property string action: ""
        signal moved(real v); signal committed(); signal actionTapped()
        Layout.fillWidth: true; implicitHeight: 56; radius: 11
        color: ot.alert ? theme.a(theme.warn, 0.13) : theme.a(theme.line, 0.24)
        border.width: 1; border.color: ot.alert ? theme.a(theme.warn, 0.45) : theme.a(theme.iris, 0.12)
        ColumnLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 8; spacing: 3
            RowLayout { Layout.fillWidth: true; spacing: 6
                Text { text: ot.label; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                Text { text: ot.hint; color: ot.alert ? theme.warn : theme.faint; font.pixelSize: 9; font.family: "monospace"; visible: ot.hint !== ""
                    font.bold: ot.alert }
                Item { Layout.fillWidth: true }
                Rectangle {
                    visible: ot.action !== ""
                    implicitHeight: 15; implicitWidth: actT.width + 12; radius: 7
                    color: actMa.containsMouse ? theme.warn : theme.a(theme.warn, 0.2)
                    border.width: 1; border.color: theme.a(theme.warn, 0.55)
                    Text { id: actT; anchors.centerIn: parent; text: ot.action
                        color: actMa.containsMouse ? theme.bg : theme.warn; font.pixelSize: 8; font.family: "monospace"; font.bold: true }
                    MouseArea { id: actMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ot.actionTapped() }
                }
                Text { text: (ot.value >= 0 ? "+" : "") + ot.value.toFixed(1) + " " + ot.unit
                    color: ot.alert ? theme.warn : theme.frost; font.pixelSize: 12; font.family: "monospace"; font.bold: true } }
            DSlider { from: ot.from; to: ot.to; value: ot.value; fill: ot.alert ? theme.warn : theme.iris
                onMoved: (v) => ot.moved(v); onCommitted: ot.committed() }
        }
    }

    // ---- tuning-guide building blocks ----------------------------------------
    // section heading with a trailing rule, so the guide scans as sections rather
    // than one long column of paragraphs
    component HelpHead: RowLayout {
        id: hh
        property string title: ""
        property string note: ""
        Layout.fillWidth: true; spacing: 9; Layout.topMargin: 2
        Text { text: hh.title; color: theme.iris; font.pixelSize: 10; font.family: "monospace"; font.bold: true; font.letterSpacing: 2 }
        Text { text: hh.note; color: theme.faint; font.pixelSize: 10; font.family: "monospace"; visible: hh.note !== "" }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.a(theme.iris, 0.2) }
    }

    // Tiny response-curve preview. Uses root.bandDb — the same maths as the big
    // graph — so every shape in the guide is the real curve the DAC would produce,
    // not an illustration that can drift out of sync with the filters.
    component MiniCurve: Canvas {
        id: mc
        property var band: null
        property real span: 12          // vertical range, ±dB
        property color stroke: theme.frost
        implicitWidth: 58; implicitHeight: 30
        onBandChanged: requestPaint()
        onStrokeChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
            var w = width, h = height, mid = h / 2, pad = 3;
            ctx.lineWidth = 1; ctx.globalAlpha = 0.3; ctx.strokeStyle = theme.faint;
            ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke();
            ctx.globalAlpha = 1;
            if (!mc.band) return;
            ctx.strokeStyle = mc.stroke; ctx.lineWidth = 1.7; ctx.beginPath();
            for (var px = 0; px <= w; px++) {
                var db = root.clamp(root.bandDb(mc.band, root.freqOfX(px, w)), -mc.span, mc.span);
                var y = mid - (db / mc.span) * (mid - pad);
                px === 0 ? ctx.moveTo(px, y) : ctx.lineTo(px, y);
            }
            ctx.stroke();
        }
    }

    component RuleCard: Rectangle {
        id: rc
        property int n: 1
        property string title: ""
        property string body: ""
        Layout.fillWidth: true; Layout.preferredWidth: 1; radius: 10
        color: theme.a(theme.line, 0.2); border.width: 1; border.color: theme.a(theme.iris, 0.13)
        implicitHeight: rcr.height + 20
        RowLayout {
            id: rcr
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 11; anchors.rightMargin: 11; anchors.topMargin: 10; spacing: 9
            Rectangle {
                implicitWidth: 19; implicitHeight: 19; radius: 10; Layout.alignment: Qt.AlignTop
                color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.35)
                Text { anchors.centerIn: parent; text: "" + rc.n; color: theme.frost; font.pixelSize: 10; font.family: "monospace"; font.bold: true }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 2
                Text { text: rc.title; color: theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: rc.body; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; lineHeight: 1.3 }
            }
        }
    }

    component NoteCard: Rectangle {
        id: nc
        property string icon: "info"
        property string title: ""
        property string body: ""
        property color tint: theme.iris
        Layout.fillWidth: true; radius: 11
        color: theme.a(nc.tint, 0.08); border.width: 1; border.color: theme.a(nc.tint, 0.26)
        implicitHeight: ncr.height + 22
        RowLayout {
            id: ncr
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 11; spacing: 10
            Sym { text: nc.icon; sz: 16; color: nc.tint; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 3
                Text { text: nc.title; color: nc.tint; font.pixelSize: 11; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: nc.body; color: theme.sub; font.pixelSize: 11; font.family: "monospace"; lineHeight: 1.35 }
            }
        }
    }

    PanelWindow {
        id: win
        visible: root.shown
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.5); MouseArea { anchors.fill: parent; onClicked: root.close() } }
        Item { anchors.fill: parent; focus: root.shown; Keys.onEscapePressed: root.helpOpen ? (root.helpOpen = false) : root.close() }

        Rectangle {
            anchors.centerIn: parent
            width: 980; height: 726; radius: 18
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                // ---------------- header ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Sym { text: "graphic_eq"; sz: 26; color: theme.iris }
                    ColumnLayout { spacing: 1
                        RowLayout { spacing: 8
                            Text { text: root.dev.ok ? root.dev.device_name : "Moondrop DAC"; color: theme.text; font.pixelSize: 20; font.family: "monospace"; font.bold: true }
                            Rectangle { visible: root.dev.ok; radius: 9; implicitHeight: 18; implicitWidth: fwT.width + 14; color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                Text { id: fwT; anchors.centerIn: parent; text: "fw " + (root.dev.firmware || "?"); color: theme.frost; font.pixelSize: 10; font.family: "monospace" } }
                            Rectangle { visible: root.dirty; radius: 9; implicitHeight: 18; implicitWidth: dtT.width + 14; color: theme.a(theme.warn, 0.18); border.width: 1; border.color: theme.a(theme.warn, 0.4)
                                Text { id: dtT; anchors.centerIn: parent; text: "unsaved"; color: theme.warn; font.pixelSize: 10; font.family: "monospace" } }
                        }
                        Text { text: root.dev.ok ? (root.bandCount + "-band parametric EQ · DSP @ 96 kHz") : (root.dev.error || "no device connected")
                            color: root.dev.ok ? theme.faint : theme.bad; font.pixelSize: 11; font.family: "monospace"
                            Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                    Item { Layout.fillWidth: true }
                    TextBtn { label: "how to tune"; icon: "help"; onTapped: root.helpOpen = true }
                    IconBtn { icon: "refresh"; onTapped: root.refresh() }
                    IconBtn { icon: "close"; onTapped: root.close() }
                }

                // ---------------- preset + offsets ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 12; enabled: root.dev.ok; opacity: root.dev.ok ? 1 : 0.4
                    Rectangle { Layout.preferredWidth: 236; implicitHeight: 56; radius: 11; color: theme.a(theme.line, 0.24); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                        RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 4
                            ColumnLayout { spacing: 1; Layout.fillWidth: true
                                Text { text: "DEVICE SLOT"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                                RowLayout { spacing: 6
                                    Text { text: "slot " + root.profile; color: theme.text; font.pixelSize: 15; font.family: "monospace" }
                                    // Just what the DAC reports. It is NOT a readout of whether
                                    // the EQ is on -- see the header note; don't colour it as one.
                                    Text { text: "· as reported"; color: theme.faint; font.pixelSize: 9; font.family: "monospace" } } }
                            IconBtn { icon: "remove"; sz: 26; onTapped: { root.profile = root.clamp(root.profile - 1, 0, 15); root.applyProfile() } }
                            IconBtn { icon: "add";    sz: 26; onTapped: { root.profile = root.clamp(root.profile + 1, 0, 15); root.applyProfile() } }
                        } }
                    // some devices report no pre-gain support at all (script's NO_PREGAIN_DEVICES)
                    OffsetTile { label: "PRE-GAIN"; unit: "dB"
                        hint: !root.supportsPregain ? "not supported"
                              : root.clipping ? ("clips by " + root.overshoot.toFixed(1) + " dB")
                              : "headroom"
                        alert: root.clipping
                        action: root.clipping ? "match" : ""
                        onActionTapped: root.matchHeadroom()
                        from: -24; to: 6; value: root.pregain
                        enabled: root.supportsPregain; opacity: root.supportsPregain ? 1 : 0.45
                        onMoved: (v) => root.pregain = v; onCommitted: root.applyPregain() }
                    OffsetTile { label: "GLOBAL OFFSET"; hint: "volume"; unit: "dB"; from: -10; to: 10; value: root.globalGain
                        onMoved: (v) => root.globalGain = v; onCommitted: root.applyGlobal() }
                }

                // ---------------- starting-point presets ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    enabled: root.dev.ok; opacity: root.dev.ok ? 1 : 0.4
                    Text { text: "PRESETS"; color: theme.faint; font.pixelSize: 9; font.family: "monospace"; font.bold: true; font.letterSpacing: 1 }
                    Repeater {
                        model: root.presets
                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 28; radius: 8
                            color: chipMa.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.3)
                            border.width: 1; border.color: theme.a(theme.iris, chipMa.containsMouse ? 0.45 : 0.16)
                            RowLayout {
                                anchors.centerIn: parent; spacing: 5
                                Sym { text: chip.modelData.ic; sz: 13; color: theme.frost }
                                Text { text: chip.modelData.nm; color: theme.sub; font.pixelSize: 10; font.family: "monospace"; font.bold: true }
                            }
                            MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.applyPreset(chip.modelData) }
                        }
                    }
                }

                // ---------------- response graph (region-labelled) ----------------
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 244; radius: 12
                    color: theme.a(theme.panel, 0.6); border.width: 1; border.color: theme.a(theme.iris, 0.14); clip: true

                    Canvas {
                        id: graph; anchors.fill: parent; anchors.margins: 10; antialiasing: true
                        property var _bands: root.bands
                        property int _sel: root.sel
                        property color _accent: theme.iris
                        on_BandsChanged: requestPaint()
                        on_SelChanged: requestPaint()
                        on_AccentChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        function css(c) { return Qt.rgba(c.r, c.g, c.b, c.a) }
                        function hexA(hex, a) { var h = ("" + hex).replace("#", "");
                            return Qt.rgba(parseInt(h.substr(0,2),16)/255, parseInt(h.substr(2,2),16)/255, parseInt(h.substr(4,2),16)/255, a) }

                        onPaint: {
                            var ctx = getContext("2d"); var w = width, h = height;
                            ctx.clearRect(0, 0, w, h); ctx.lineWidth = 1; ctx.textAlign = "left";
                            // frequency-region zones + labels (what each part tunes)
                            for (var r = 0; r < root.regionDefs.length; r++) {
                                var rd = root.regionDefs[r];
                                var zx1 = root.xOfFreq(rd.f1, w), zx2 = root.xOfFreq(rd.f2, w);
                                ctx.fillStyle = graph.hexA(rd.c, r % 2 ? 0.05 : 0.09);
                                ctx.fillRect(zx1, 0, zx2 - zx1, h);
                                if (zx2 - zx1 > 34) { ctx.fillStyle = graph.hexA(rd.c, 0.85);
                                    ctx.font = "9px monospace"; ctx.textAlign = "center"; ctx.fillText(rd.n, (zx1 + zx2) / 2, 12); ctx.textAlign = "left"; }
                            }
                            ctx.font = "9px monospace";
                            for (var db = -root.dbMax; db <= root.dbMax; db += 6) {
                                var y = root.yOfDb(db, h);
                                ctx.globalAlpha = db === 0 ? 0.85 : 0.4; ctx.strokeStyle = theme.line;
                                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
                                // Keep the label inside the canvas and clear of the frequency
                                // row along the bottom. Unclamped, +dbMax draws at y=-2 (above
                                // the top edge, invisible) and -dbMax at y=h-2 — exactly where
                                // the "20" sits, which is what made the corner read "2012".
                                ctx.globalAlpha = 1; ctx.fillStyle = theme.faint;
                                ctx.fillText((db > 0 ? "+" : "") + db, 2, root.clamp(y - 2, 9, h - 12));
                            }
                            var marks = [20,50,100,200,500,1000,2000,5000,10000,20000];
                            var labels = ["20","50","100","200","500","1k","2k","5k","10k","20k"];
                            for (var i = 0; i < marks.length; i++) {
                                var x = root.xOfFreq(marks[i], w);
                                ctx.globalAlpha = 0.28; ctx.strokeStyle = theme.line;
                                ctx.beginPath(); ctx.moveTo(x, 16); ctx.lineTo(x, h); ctx.stroke();
                                ctx.globalAlpha = 0.9; ctx.fillStyle = theme.faint; ctx.fillText(labels[i], root.clamp(x - 6, 0, w - 18), h - 2);
                            }
                            ctx.globalAlpha = 1;
                            for (var b = 0; b < graph._bands.length; b++) {
                                if (graph._bands[b].type === "disabled") continue;
                                ctx.strokeStyle = graph.css(theme.a(b === graph._sel ? theme.frost : theme.iris, b === graph._sel ? 0.5 : 0.16));
                                ctx.lineWidth = b === graph._sel ? 1.5 : 1; ctx.beginPath();
                                for (var px = 0; px <= w; px += 3) {
                                    var f = root.freqOfX(px, w); var yy = root.yOfDb(root.clamp(root.bandDb(graph._bands[b], f), -root.dbMax, root.dbMax), h);
                                    px === 0 ? ctx.moveTo(px, yy) : ctx.lineTo(px, yy);
                                }
                                ctx.stroke();
                            }
                            ctx.strokeStyle = theme.iris; ctx.lineWidth = 2.4; ctx.beginPath();
                            for (var qx = 0; qx <= w; qx += 2) {
                                var ff = root.freqOfX(qx, w); var ty = root.yOfDb(root.clamp(root.totalDb(ff), -root.dbMax, root.dbMax), h);
                                qx === 0 ? ctx.moveTo(qx, ty) : ctx.lineTo(qx, ty);
                            }
                            ctx.stroke();
                            // handles: dot on the curve, number offset with a leader (anti-overlap)
                            var order = [];
                            for (var k = 0; k < graph._bands.length; k++) { if (graph._bands[k].type === "disabled") continue;
                                order.push({ k: k, hx: root.xOfFreq(graph._bands[k].frequency, w), hy: root.yOfDb(root.clamp(graph._bands[k].gain, -root.dbMax, root.dbMax), h) }); }
                            order.sort(function(a, b2) { return a.hx - b2.hx });
                            var prevX = -999, above = true;
                            ctx.textAlign = "center";
                            for (var o = 0; o < order.length; o++) {
                                var oo = order[o], selK = oo.k === graph._sel;
                                var near = (oo.hx - prevX) < 24; above = near ? !above : true; prevX = oo.hx;
                                var ly = above ? oo.hy - 15 : oo.hy + 15;
                                ctx.globalAlpha = 0.5; ctx.strokeStyle = selK ? theme.frost : theme.iris; ctx.lineWidth = 1;
                                ctx.beginPath(); ctx.moveTo(oo.hx, oo.hy); ctx.lineTo(oo.hx, ly + (above ? 5 : -5)); ctx.stroke(); ctx.globalAlpha = 1;
                                ctx.beginPath(); ctx.arc(oo.hx, oo.hy, selK ? 6 : 4, 0, 2*Math.PI);
                                ctx.fillStyle = selK ? theme.frost : theme.iris; ctx.fill();
                                ctx.lineWidth = 2; ctx.strokeStyle = theme.bg; ctx.stroke();
                                ctx.fillStyle = selK ? theme.frost : theme.sub; ctx.font = (selK ? "bold " : "") + "10px monospace";
                                ctx.fillText("" + graph._bands[oo.k].index, oo.hx, ly + 3);
                            }
                            ctx.textAlign = "left";
                        }

                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true
                            property int dragIdx: -1
                            function nearest(mx, my) {
                                var best = -1, bd = 1e9;
                                for (var i = 0; i < root.bands.length; i++) {
                                    if (root.bands[i].type === "disabled") continue;
                                    var hx = root.xOfFreq(root.bands[i].frequency, width), hy = root.yOfDb(root.clamp(root.bands[i].gain, -root.dbMax, root.dbMax), height);
                                    var d = Math.hypot(mx - hx, my - hy); if (d < bd) { bd = d; best = i; }
                                }
                                return bd < 26 ? best : -1;
                            }
                            onPressed: (e) => { var n = nearest(e.x, e.y); if (n >= 0) { root.sel = n; dragIdx = n; } }
                            onPositionChanged: (e) => {
                                if (dragIdx < 0) return;
                                root.setBand(dragIdx, { frequency: Math.round(root.clamp(root.freqOfX(e.x, width), root.fMin, root.fMax)),
                                                        gain: Math.round(root.clamp(root.dbOfY(e.y, height), -root.dbMax, root.dbMax) * 10) / 10 }, false);
                            }
                            onReleased: () => { if (dragIdx >= 0) { root.applyBand(dragIdx); dragIdx = -1; } }
                            onWheel: (e) => {
                                if (root.sel < 0 || root.sel >= root.bands.length) return;
                                var q = root.clamp(root.bands[root.sel].q * (e.angleDelta.y > 0 ? 1.12 : 0.89), 0.1, root.qMax);
                                root.setBand(root.sel, { q: Math.round(q * 1000) / 1000 }, false); qDebounce.restart();
                            }
                        }
                        Timer { id: qDebounce; interval: 250; onTriggered: root.applyBand(root.sel) }
                    }
                }

                // ---------------- all-bands column editor ----------------
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; radius: 12
                    visible: root.dev.ok
                    color: theme.a(theme.panel, 0.5); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 9; spacing: 7
                        Repeater {
                            model: root.bands.length
                            delegate: Rectangle {
                                id: col
                                required property int index                      // position on screen
                                readonly property int slot: root.slotAt(index)   // the DAC slot it edits
                                readonly property var bd: root.bands[slot]
                                readonly property bool selCol: slot === root.sel
                                readonly property bool off: col.bd.type === "disabled"
                                Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; radius: 10
                                color: selCol ? theme.a(theme.iris, 0.13) : theme.a(theme.line, 0.16)
                                border.width: 1; border.color: selCol ? theme.a(theme.iris, 0.5) : theme.a(theme.line, 0.5)
                                MouseArea { anchors.fill: parent; onClicked: root.sel = col.slot }   // click empty space to select
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 8; spacing: 5
                                    // region tag + slot number. The tag tracks frequency only, so on a
                                    // disabled band it describes where nothing is happening — mute it
                                    // rather than let eight parked bands all shout MID. The slot number
                                    // keeps these matched to the numbered handles on the graph now that
                                    // columns sit in frequency order rather than slot order.
                                    Item {
                                        Layout.fillWidth: true; implicitHeight: 10
                                        Text { anchors.centerIn: parent; text: root.regionOf(col.bd.frequency).n
                                            color: col.off ? theme.a(theme.faint, 0.45) : root.regionOf(col.bd.frequency).c
                                            font.pixelSize: 8; font.family: "monospace"; font.bold: true; font.letterSpacing: .5 }
                                        // bd.index is the slot the write actually targets, and the same
                                        // number the graph prints on its handles — use it, not the
                                        // on-screen position, so the two can never disagree.
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            text: col.bd.index; color: theme.a(theme.faint, col.selCol ? 0.9 : 0.5)
                                            font.pixelSize: 7; font.family: "monospace" }
                                    }
                                    // filter type — click cycles fwd, right-click back
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 24; radius: 6
                                        color: col.off ? theme.a(theme.line, 0.4) : theme.a(theme.iris, 0.12)
                                        border.width: 1; border.color: theme.a(theme.iris, 0.28)
                                        Text { anchors.centerIn: parent; text: root.typeAbbr(col.bd.type); color: col.off ? theme.faint : theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onPressed: (e) => { root.sel = col.slot; root.cycleType(col.slot, e.button === Qt.RightButton ? -1 : 1) } }
                                    }
                                    // vertical gain slider — the tall centrepiece
                                    VSlider { Layout.fillWidth: true; Layout.fillHeight: true; from: -root.dbMax; to: root.dbMax; value: col.bd.gain
                                        fill: col.off ? theme.a(theme.faint, 0.5) : (col.selCol ? theme.frost : theme.iris)
                                        onMoved: (v) => { root.sel = col.slot; root.setBand(col.slot, { gain: Math.round(v * 10) / 10 }, false) }
                                        onCommitted: () => root.applyBand(col.slot) }
                                    // gain readout — turns amber and tags "limit" when the band is
                                    // pinned against the firmware's Q2.30 coefficient ceiling, so
                                    // the wall is visible instead of just feeling like a stuck slider
                                    RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 4
                                        Text { text: (col.bd.gain >= 0 ? "+" : "") + col.bd.gain.toFixed(1)
                                            color: col.off ? theme.a(theme.faint, 0.55) : (root.atCeiling(col.bd) ? theme.warn : theme.frost)
                                            font.pixelSize: 12; font.family: "monospace"; font.bold: true }
                                        Text { visible: root.atCeiling(col.bd); text: "limit"; color: theme.warn; font.pixelSize: 7; font.family: "monospace" } }
                                    // frequency stepper (log step)
                                    RowLayout { Layout.fillWidth: true; spacing: 0
                                        IconBtn { icon: "remove"; sz: 18; onTapped: { root.sel = col.slot; root.stepFreq(col.slot, -1) } }
                                        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.fmtHz(col.bd.frequency)
                                            color: col.off ? theme.a(theme.faint, 0.6) : theme.sub; font.pixelSize: 10; font.family: "monospace" }
                                        IconBtn { icon: "add"; sz: 18; onTapped: { root.sel = col.slot; root.stepFreq(col.slot, 1) } } }
                                    Text { Layout.alignment: Qt.AlignHCenter; text: "FREQ"; color: theme.faint; font.pixelSize: 7; font.family: "monospace"; font.letterSpacing: 1 }
                                    // Q stepper
                                    RowLayout { Layout.fillWidth: true; spacing: 0
                                        IconBtn { icon: "remove"; sz: 18; onTapped: { root.sel = col.slot; root.setBand(col.slot, { q: Math.round(root.clamp(col.bd.q - 0.1, 0.1, root.qMax) * 100) / 100 }, true) } }
                                        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "Q" + col.bd.q.toFixed(2)
                                            color: col.off ? theme.a(theme.faint, 0.6) : theme.sub; font.pixelSize: 10; font.family: "monospace" }
                                        IconBtn { icon: "add"; sz: 18; onTapped: { root.sel = col.slot; root.setBand(col.slot, { q: Math.round(root.clamp(col.bd.q + 0.1, 0.1, root.qMax) * 100) / 100 }, true) } } }
                                }
                            }
                        }
                    }
                }

                // ---------------- footer ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text { text: "drag graph points · scroll = Q · new to this? tap “how to tune” · edits are live, save to keep them after unplug"
                        color: theme.faint; font.pixelSize: 10; font.family: "monospace"
                        Layout.fillWidth: true; elide: Text.ElideRight }
                    TextBtn { label: "import"; icon: "folder_open"; enabled: root.dev.ok; onTapped: root.pickImport() }
                    // "reload" re-reads the DAC (truth). "revert" undoes live edits back to
                    // the last saved state — re-reading can't do that, since the DSP reports
                    // what we wrote, not what flash holds.
                    TextBtn { label: "revert"; icon: "undo"; enabled: root.dev.ok && root.dirty && root.pristine !== null; onTapped: root.revert() }
                    TextBtn { label: "reload"; icon: "sync"; enabled: root.dev.ok; onTapped: root.refresh() }
                    TextBtn { label: "save to flash"; icon: "save"; primary: true; enabled: root.dev.ok; onTapped: root.saveFlash() }
                }
            }

            // ---------------- refusal toast ----------------
            // Mostly the Q2.30 coefficient-overflow refusal: the firmware can't
            // represent the filter, so the script declines rather than let the DAC
            // wrap and play a curve that isn't the one drawn. The graph has already
            // been resynced to the device by the time this shows.
            Rectangle {
                visible: root.lastError !== "" && !root.helpOpen
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.margins: 14
                implicitHeight: errCol.height + 20; radius: 11
                color: theme.a(theme.bad, 0.16); border.width: 1; border.color: theme.a(theme.bad, 0.5)
                RowLayout {
                    id: errCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 10
                    Sym { text: "block"; sz: 18; color: theme.bad }
                    ColumnLayout { Layout.fillWidth: true; spacing: 1
                        Text { text: "device refused the write — graph resynced to the DAC"
                            color: theme.bad; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: root.lastError
                            color: theme.sub; font.pixelSize: 10; font.family: "monospace"; lineHeight: 1.25 } }
                    IconBtn { icon: "close"; onTapped: root.lastError = "" }
                }
            }

            // ---------------- in-panel tuning guide ----------------
            Rectangle {
                visible: root.helpOpen; anchors.fill: parent; radius: 18
                color: theme.a(theme.bg, 0.985); border.width: 1; border.color: theme.a(theme.iris, 0.34)
                MouseArea { anchors.fill: parent }   // swallow clicks
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 22; spacing: 12
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "school"; sz: 22; color: theme.iris }
                        Text { text: "How to tune"; color: theme.text; font.pixelSize: 19; font.family: "monospace"; font.bold: true }
                        Item { Layout.fillWidth: true }
                        IconBtn { icon: "close"; onTapped: root.helpOpen = false }
                    }
                    Flickable {
                        id: helpFlick
                        Layout.fillWidth: true; Layout.fillHeight: true; contentHeight: helpCol.height; clip: true; boundsBehavior: Flickable.StopAtBounds
                        ColumnLayout { id: helpCol; width: helpFlick.width; spacing: 13

                            // ---- the one-paragraph version ----
                            Rectangle {
                                Layout.fillWidth: true; radius: 12
                                color: theme.a(theme.iris, 0.09); border.width: 1; border.color: theme.a(theme.iris, 0.24)
                                implicitHeight: introRow.height + 26
                                RowLayout {
                                    id: introRow
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                    anchors.leftMargin: 14; anchors.rightMargin: 14; anchors.topMargin: 13; spacing: 13
                                    Sym { text: "graphic_eq"; sz: 22; color: theme.iris; Layout.alignment: Qt.AlignTop }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 4
                                        Text { text: "EQ is just “make some frequencies louder or quieter”."
                                            color: theme.text; font.pixelSize: 14; font.family: "monospace"; font.bold: true }
                                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: theme.sub; font.pixelSize: 12; font.family: "monospace"; lineHeight: 1.35
                                            text: "Each of the " + root.bandCount + " columns is one filter. Give it a shape, a frequency, how much (gain) and how wide (Q). "
                                                  + "Drag a dot on the graph for big moves, use the column steppers for fine ones, scroll on the graph to change Q. "
                                                  + "Changes are heard instantly — nothing is permanent until you hit save to flash." }
                                    }
                                }
                            }

                            // ---- rules ----
                            HelpHead { title: "THE FOUR RULES"; note: "if you read nothing else" }
                            GridLayout {
                                columns: 2; columnSpacing: 11; rowSpacing: 8; Layout.fillWidth: true
                                RuleCard { n: 1; title: "Cut, don’t boost"; body: "Lowering a problem is cleaner than raising everything around it, and it can never clip. Boost only to add something that truly isn’t there." }
                                RuleCard { n: 2; title: "Small moves"; body: "±2–3 dB is already a lot. If you’re reaching for ±8 dB you’re usually on the wrong band — or fighting the headphones." }
                                RuleCard { n: 3; title: "Mind headroom"; body: "Every boost eats headroom. Set pre-gain to roughly minus your biggest boost so peaks don’t clip." }
                                RuleCard { n: 4; title: "A/B constantly"; body: "Flip a band to “—” and back. If you can’t clearly hear it helping, you don’t need it." }
                            }

                            // ---- shapes, with real curves ----
                            HelpHead { title: "FILTER SHAPES"; note: "click a column’s type to cycle" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: [
                                        { ab: "PK", nm: "Peaking",    band: { type: "peaking",    frequency: 1000, gain: 9, q: 1.1 },  d: "A bell that lifts or dips around one frequency. Your workhorse — use it for almost everything." },
                                        { ab: "LS", nm: "Low shelf",  band: { type: "low_shelf",  frequency: 250,  gain: 8, q: 0.7 },  d: "Raises or drops everything below the point. The natural way to add overall bass warmth." },
                                        { ab: "HS", nm: "High shelf", band: { type: "high_shelf", frequency: 4000, gain: 8, q: 0.7 },  d: "Raises or drops everything above the point. Adds “air”, or tames a bright headphone." },
                                        { ab: "LP", nm: "Low-pass",   band: { type: "low_pass",   frequency: 3000, gain: 0, q: 0.7 },  d: "A cliff: removes everything above the point. Rarely wanted for music." },
                                        { ab: "HP", nm: "High-pass",  band: { type: "high_pass",  frequency: 400,  gain: 0, q: 0.7 },  d: "A cliff: removes everything below the point. At ~30 Hz it kills subsonic rumble." },
                                        { ab: "—",  nm: "Off",        band: null,                                                       d: "Band does nothing. Use it to A/B a filter." }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; radius: 9; implicitHeight: 42
                                        color: theme.a(theme.line, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 12; spacing: 11
                                            Rectangle {
                                                implicitWidth: 34; implicitHeight: 20; radius: 6
                                                color: theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                                Text { anchors.centerIn: parent; text: modelData.ab; color: theme.text; font.pixelSize: 10; font.family: "monospace"; font.bold: true }
                                            }
                                            MiniCurve { band: modelData.band; stroke: theme.frost }
                                            Text { text: modelData.nm; color: theme.text; font.pixelSize: 12; font.family: "monospace"; font.bold: true; Layout.preferredWidth: 82 }
                                            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: modelData.d; color: theme.sub; font.pixelSize: 11; font.family: "monospace" }
                                        }
                                    }
                                }
                            }

                            // ---- regions: colours come straight from the graph's own zone table ----
                            HelpHead { title: "WHAT EACH REGION DOES"; note: "same colours as the graph" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                Repeater {
                                    model: [
                                        { i: 0, d: "rumble & weight — felt more than heard" },
                                        { i: 1, d: "punch & fullness; too much and it booms" },
                                        { i: 2, d: "warmth & body; excess turns to mud" },
                                        { i: 3, d: "most instruments and voices; boxy if piled up" },
                                        { i: 4, d: "attack & clarity — and ear fatigue if harsh" },
                                        { i: 5, d: "detail & edge; sibilance (“sss”) starts here" },
                                        { i: 6, d: "sparkle, cymbals, sense of openness" }
                                    ]
                                    delegate: RowLayout {
                                        required property var modelData
                                        readonly property var rd: root.regionDefs[modelData.i]
                                        Layout.fillWidth: true; spacing: 10
                                        Rectangle { implicitWidth: 4; implicitHeight: 15; radius: 2; color: rd.c }
                                        Text { text: rd.n; color: rd.c; font.pixelSize: 11; font.family: "monospace"; font.bold: true; Layout.preferredWidth: 84 }
                                        Text { text: root.fmtHz(rd.f1) + "–" + root.fmtHz(rd.f2); color: theme.faint; font.pixelSize: 11; font.family: "monospace"; Layout.preferredWidth: 74 }
                                        Text { Layout.fillWidth: true; text: modelData.d; color: theme.sub; font.pixelSize: 11; font.family: "monospace" }
                                    }
                                }
                            }

                            // ---- recipes, each drawn as the curve it actually makes ----
                            HelpHead { title: "QUICK RECIPES"; note: "starting points — then trust your ears" }
                            GridLayout {
                                columns: 2; columnSpacing: 11; rowSpacing: 6; Layout.fillWidth: true
                                Repeater {
                                    model: [
                                        { nm: "More bass, clean",   band: { type: "low_shelf",  frequency: 90,    gain: 3,  q: 0.7 } },
                                        { nm: "Kill boom / mud",    band: { type: "peaking",    frequency: 200,   gain: -3, q: 1.2 } },
                                        { nm: "Clearer vocals",     band: { type: "peaking",    frequency: 400,   gain: -3, q: 1.0 } },
                                        { nm: "Less harsh",         band: { type: "peaking",    frequency: 3200,  gain: -3, q: 1.4 } },
                                        { nm: "Tame “sss”",         band: { type: "peaking",    frequency: 7000,  gain: -4, q: 4.0 } },
                                        { nm: "More air / sparkle", band: { type: "high_shelf", frequency: 10000, gain: 3,  q: 0.7 } }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; Layout.preferredWidth: 1; radius: 9; implicitHeight: 40
                                        color: theme.a(theme.line, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 10; spacing: 9
                                            MiniCurve { band: modelData.band; span: 6; stroke: theme.iris }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 0
                                                Text { text: modelData.nm; color: theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                                Text { color: theme.frost; font.pixelSize: 10; font.family: "monospace"
                                                    text: root.typeName(modelData.band.type) + " · " + root.fmtHz(modelData.band.frequency) + " Hz · "
                                                          + (modelData.band.gain >= 0 ? "+" : "") + modelData.band.gain + " dB · Q" + modelData.band.q }
                                            }
                                        }
                                    }
                                }
                            }

                            // ---- the things people actually get stuck on ----
                            HelpHead { title: "GOOD TO KNOW" }

                            NoteCard {
                                icon: "hearing_disabled"; tint: theme.warn
                                title: "NOT HEARING YOUR CHANGES?"
                                body: "On the DAWN PRO2 the EQ is switched on at the hardware — press both volume buttons together to toggle between the default (no EQ) mode and custom EQ. Edits here only change the sound in custom EQ mode.\n\n"
                                      + "The DAC never reports which mode it is in (every register reads identical either way), so nothing on this screen can tell you. Your ears are the only indicator."
                            }

                            NoteCard {
                                icon: "bolt"
                                title: "SHORTCUT — DON’T WANT TO TUNE BY EAR?"
                                body: "The PRESETS row along the top fills every band with a known-good starting shape (and sets a sensible pre-gain) — tap one, then nudge it to taste. Nothing is permanent until you save to flash.\n\n"
                                      + "Better still, grab a measured preset for your exact headphones from the AutoEQ project — search “AutoEQ <model> ParametricEQ” — then import it. It sets every band and the pre-gain for you:\n\n"
                                      + "python3 ~/.config/quickshell/sea-shell/moondrop_control.py --import-rew ParametricEQ.txt"
                            }

                            NoteCard {
                                icon: "speaker_group"
                                title: "WANT THIS EQ ON A NON-MOONDROP DEVICE?"
                                body: "The bands above run on the DAC's own chip, so they only exist on supported Moondrop hardware. The same curves can run in software instead, through PipeWire — that works with any output: another brand's DAC, laptop speakers, Bluetooth.\n\n"
                                      + "python3 …/moondrop_control.py --to-pipewire eq.conf --from-json backup.json\n"
                                      + "cp eq.conf ~/.config/pipewire/pipewire.conf.d/ && systemctl --user restart pipewire pipewire-pulse\n\n"
                                      + "Then pick the “Universal EQ” sink as your output. It needs no Moondrop DAC at all — feed it an AutoEQ file with --from-rew instead. Software biquads are floating point, so the shelf gains the DAC has to refuse work fine there."
                            }

                            NoteCard {
                                icon: "help"; tint: theme.faint
                                title: "PRESETS vs DEVICE SLOT — NOT THE SAME THING"
                                body: "PRESETS (top row) are just starting shapes this panel writes into your bands — they’re ours, not the DAC’s. DEVICE SLOT is a number the DAC itself reports for which of its internal profiles is selected. Tapping a preset never changes the slot."
                            }

                            NoteCard {
                                icon: "block"; tint: theme.bad
                                title: "WHY A SLIDER SOMETIMES STOPS EARLY"
                                body: "The DAC stores filters as fixed-point numbers (Q2.30) that only span ±2.0, and some filters need coefficients outside that — high shelves above roughly +5 dB, or anything with a big boost at high frequency and low Q.\n\n"
                                      + "Rather than let the firmware wrap the number and play a curve that isn’t the one drawn, the panel stops the gain at the highest value that fits and tags the column “limit”. Widen the band (lower Q), move it, or ask for less."
                            }

                            NoteCard {
                                icon: "info"; tint: theme.faint
                                title: "PRESET SLOT?"
                                body: "Whatever slot the DAC reports — read from hardware, not chosen by the panel. It is not a readout of whether the EQ is on: firmware 1.5 reports the same slot in both modes. Informational only; change it only if you know your device’s preset layout."
                            }

                            Item { Layout.preferredHeight: 4 }
                        }
                    }
                }
            }
        }
    }
}
