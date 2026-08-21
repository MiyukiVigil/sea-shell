pragma Singleton

// Industrial design tokens for sea-shell.
//
// WHY THIS FILE EXISTS: shell.qml, settings.qml and Dashboard.qml each used to declare their
// own `QtObject { id: theme }` and each re-parsed ~/.config/sea-shell/appearance.json on its
// own. Three copies drift — Dashboard's ramp had already fallen behind the bar's. Tokens now
// live here once; every surface reads the same values from the same single config read.
//
// THE LANGUAGE: neutrals + exactly one accent + semantic. Depth comes from four background
// steps and two rule weights, never from shadow or translucency. Radius is 2px everywhere.
// Machine-readable values (numbers, IDs, timestamps, status) are mono and tabular; prose is
// sans. The accent marks the primary action and the active state — it never fills large areas.
//
// The accent stays user-configurable and matugen-driven; the neutral ramp is DERIVED from its
// hue so the greys read as chosen rather than inherited. Everything else is fixed by the
// design language, which is why the appearance radius slider no longer reaches controls.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: tok

    // ---------------- raw config ----------------
    property string accentRaw: "#63c7dd"
    property bool   light: false
    property string sans: "Adwaita Sans"
    property string mono: "Roboto Mono"
    // raw "roundness" from appearance.json — drives the whole radius scale below
    property real   radiusCfg: 14
    property real   cfgScale: 0
    property bool   loaded: false

    signal changed()

    // WHY THIS BLOCKS, AND WHY IT IS NOT A `cat`.
    //
    // This used to be a Process running `cat` and parsing its stdout — which is
    // asynchronous by construction: fork a shell, wait for it to exit, then parse. Every
    // surface in the shell reads its colours from here, so for the whole of that round trip
    // they rendered against the DEFAULTS above, and the default accent is sea cyan. That is
    // the blue flash on every bar start: not a transition, just the shell drawing itself
    // once before it knew what colour it was.
    //
    // `blockLoading` reads the file synchronously during construction, so the singleton is
    // already correct before the first frame is composed and there is nothing to flash
    // from. It is the one place in this shell where blocking is right: it is a single small
    // file, read once, and every pixel drawn afterwards depends on it.
    FileView {
        id: apFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/appearance.json"
        blockLoading: true
        watchChanges: true
        // Component.onCompleted, not just onLoaded: with blockLoading the bytes are already
        // there when construction finishes and no load SIGNAL is emitted at all, so hooking
        // onLoaded alone left the parse to never run and the flash exactly where it was.
        Component.onCompleted: tok.parse(apFile.text())
        onLoaded: tok.parse(apFile.text())
        onFileChanged: { apFile.reload(); tok.parse(apFile.text()) }
        // No file yet (a first run, before install.sh has seeded one) is not an error —
        // the defaults above ARE the answer, and surfaces gated on `loaded` must not hang.
        onLoadFailed: { tok.loaded = true; tok.changed() }
    }

    // The settings panel drives `light` and `accentRaw` directly while it is open, so the colour
    // picker previews across the whole shell. Those bindings SUPPRESS whatever the file says for
    // as long as the panel is up — including a change written during that time — so when the panel
    // lets go the two can disagree with no event left to correct them: the config read dark and the
    // bar drew light until something unrelated happened to touch the file. The panel calls this on
    // close, and the file is the truth again.
    function resync() { apFile.reload(); tok.parse(apFile.text()) }

    // A PATH IS NOT A URL. "file://" + path breaks the moment the path holds a percent sign,
    // because that is where an escape sequence starts — Qt reads `%16` as one byte and opens a
    // filename nobody has. It bit the wallpaper surfaces first: the indexer keys its thumbnail
    // cache on `subfolder%name`, so the day you sort your wallpapers into folders, every still
    // in the picker, the settings shelf and the first-run tour silently stops loading. Spaces
    // and `#` have the same problem and had it all along. Each SEGMENT is encoded; the
    // separators are not, which is what distinguishes this from encodeURIComponent on the lot.
    function fileUrl(p) {
        if (!p || !("" + p).length) return "";
        return "file://" + ("" + p).split("/").map(encodeURIComponent).join("/");
    }

    function parse(t) {
        try {
            var j = JSON.parse(t);
            if (j.accent) tok.accentRaw = j.accent;
            if (j.mode !== undefined) tok.light = (""+j.mode === "light");
            if (j.scale !== undefined) tok.cfgScale = j.scale;
            // A display face (the old `font` key) is fine for prose but destroys data
            // legibility, so it is accepted as the SANS role only — mono is ours.
            if (j.font !== undefined && (""+j.font).length) tok.sans = j.font;
            if (j.radius !== undefined) tok.radiusCfg = Math.max(0, j.radius);
        } catch(e) {}
        tok.loaded = true;
        tok.changed();
    }
    function reload() { apFile.reload(); tok.parse(apFile.text()) }

    // ---------------- accent ----------------
    readonly property color _a: tok.accentRaw
    readonly property real  _h: tok._a.hslHue >= 0 ? tok._a.hslHue : 0.55
    readonly property real  _s: tok._a.hslSaturation

    // GREY IS A CHOICE. Two rules below used to conspire to overrule it: `hslHue` is **-1** for
    // anything colourless, so the fallback above handed it 0.55, and the saturation floor then
    // pulled it up from 0 to 0.35. Pick pure white as your accent and the shell drew #386375 —
    // a muted blue, from an input with no blue in it. Every grey came out as the same blue.
    //
    // The floor is right for a WASHED-OUT colour, which is what it was written for: a pale pink
    // at L≈0.80 has a hue worth keeping and just cannot carry text. It is wrong for a colour that
    // has no hue at all, where it does not rescue an accent, it invents one. So: no chroma, no
    // hue — the accent becomes a neutral of the same readable lightness, and `_sm` takes the
    // tint out of the grounds and inks with it so the whole shell goes properly monochrome
    // rather than accent-grey on faintly-blue panels. For any accent with real colour in it
    // `_sm` is 1 and every value below is bit-identical to what it was.
    readonly property bool _achromatic: tok._s < 0.06
    readonly property real _sm: tok._achromatic ? 0 : 1

    // A user accent can be any lightness (the shipped default is a pale pink at L≈0.80), and a
    // pale accent on a pale ground is unreadable. Clamp it into a band that can carry text and
    // sit on the ground with real contrast, keeping the hue the user picked.
    readonly property color accent: tok.light
        ? Qt.hsla(tok._h, tok._achromatic ? 0 : Math.max(0.35, Math.min(0.95, tok._s)), 0.34, 1)
        : Qt.hsla(tok._h, tok._achromatic ? 0 : Math.max(0.42, Math.min(0.95, tok._s)), 0.62, 1)
    readonly property color accentInk:  tok.light ? "#ffffff" : Qt.hsla(tok._h, 0.55 * tok._sm, 0.07, 1)
    readonly property color accentWash: tok.light ? Qt.hsla(tok._h, 0.34 * tok._sm, 0.915, 1)
                                                  : Qt.hsla(tok._h, 0.40 * tok._sm, 0.155, 1)

    // ---------------- ground → raised (four steps, no more) ----------------
    readonly property color bg:      tok.light ? Qt.hsla(tok._h, 0.07 * tok._sm, 0.940, 1) : Qt.hsla(tok._h, 0.14 * tok._sm, 0.072, 1)
    readonly property color surface: tok.light ? Qt.hsla(tok._h, 0.09 * tok._sm, 0.972, 1) : Qt.hsla(tok._h, 0.13 * tok._sm, 0.104, 1)
    readonly property color raised:  tok.light ? Qt.hsla(tok._h, 0.10 * tok._sm, 1.000, 1) : Qt.hsla(tok._h, 0.12 * tok._sm, 0.136, 1)
    readonly property color sunken:  tok.light ? Qt.hsla(tok._h, 0.08 * tok._sm, 0.898, 1) : Qt.hsla(tok._h, 0.16 * tok._sm, 0.046, 1)

    // ---------------- ink (three steps) ----------------
    readonly property color ink:  tok.light ? Qt.hsla(tok._h, 0.16 * tok._sm, 0.090, 1) : Qt.hsla(tok._h, 0.08 * tok._sm, 0.912, 1)
    readonly property color ink2: tok.light ? Qt.hsla(tok._h, 0.12 * tok._sm, 0.310, 1) : Qt.hsla(tok._h, 0.08 * tok._sm, 0.680, 1)
    readonly property color ink3: tok.light ? Qt.hsla(tok._h, 0.10 * tok._sm, 0.520, 1) : Qt.hsla(tok._h, 0.08 * tok._sm, 0.492, 1)

    // ---------------- rules (two weights — these do the structural work) ----------------
    readonly property color rule:     tok.light ? Qt.hsla(tok._h, 0.10 * tok._sm, 0.845, 1) : Qt.hsla(tok._h, 0.12 * tok._sm, 0.190, 1)
    readonly property color ruleHard: tok.light ? Qt.hsla(tok._h, 0.11 * tok._sm, 0.720, 1) : Qt.hsla(tok._h, 0.12 * tok._sm, 0.282, 1)

    // ---------------- semantic (never decorative) ----------------
    readonly property color ok:    tok.light ? "#1b7a4b" : "#4fbf85"
    readonly property color warn:  tok.light ? "#8f6300" : "#d9a440"
    readonly property color crit:  tok.light ? "#ad2020" : "#f0706a"
    readonly property color okWash:   tok.light ? "#def0e5" : "#12301f"
    readonly property color warnWash: tok.light ? "#f6ebd3" : "#33270d"
    readonly property color critWash: tok.light ? "#f8e1e1" : "#3a1717"

    // ---------------- geometry ----------------
    // ROUNDED, deliberately. The industrial language calls for 2px, but the user asked for a
    // rounded feel and that overrides it. The win from the flattening pass is kept: the shell's
    // 278 scattered radius literals collapsed into this one scale, so roundness is now a single
    // live-tunable value driven by the appearance "roundness" slider instead of magic numbers.
    //
    // Three steps, because one radius cannot serve a 15px checkbox and a full-screen card: at
    // roundness 26 a single value either squares off the panels or turns every chip into a
    // lozenge. Each step is clamped so extreme slider values still render sanely.
    readonly property real rSmall: Math.max(2, Math.min(8,  tok.radiusCfg * 0.28))  // chips, checkboxes, knobs
    readonly property real r:      Math.max(2, Math.min(14, tok.radiusCfg * 0.5))   // buttons, inputs, rows
    readonly property real rCard:  Math.max(2, Math.min(30, tok.radiusCfg))         // panels, windows, the bar
    // space scale — 4 8 12 16 24 32 48, nothing between
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s6: 24
    readonly property int s8: 32
    readonly property int s12: 48

    // ---------------- type scale (pick from it, never interpolate) ----------------
    readonly property int tLabel: 11     // mono, uppercase, tracked — column heads
    readonly property int tData:  12     // mono dense data, chips
    readonly property int tDense: 13     // secondary text
    readonly property int tBody:  15
    readonly property int tPanel: 17     // panel titles
    readonly property int tTitle: 20     // screen titles
    readonly property int tKpi:   28
    readonly property int tHero:  40     // the one number that matters

    // ---------------- motion (pick from it, never interpolate) ----------------
    // Three durations, one curve. Every surface had been hand-picking its own number —
    // 130 here, 150 there, 200 somewhere else — which reads as three different products
    // when two of them animate at once. Anything slower than mSlow is not a transition,
    // it is a wait, and should show progress instead.
    readonly property int mFast: 130     // hover, press, chip state — must feel instant
    readonly property int mBase: 200     // focus moves, panels opening
    readonly property int mSlow: 320     // a whole surface changing what it shows
    readonly property int mEase: Easing.OutCubic

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // per-monitor UI scale — matches the rule shell.qml and Dashboard.qml both hand-rolled
    function uiFor(scr) {
        if (tok.cfgScale > 0) return tok.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
}
