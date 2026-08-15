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

    Process {
        id: apRead; running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: {
            try {
                var j = JSON.parse(apOut.text);
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
        } }
    }
    function reload() { apRead.running = true }

    // ---------------- accent ----------------
    readonly property color _a: tok.accentRaw
    readonly property real  _h: tok._a.hslHue >= 0 ? tok._a.hslHue : 0.55
    readonly property real  _s: tok._a.hslSaturation

    // A user accent can be any lightness (the shipped default is a pale pink at L≈0.80), and a
    // pale accent on a pale ground is unreadable. Clamp it into a band that can carry text and
    // sit on the ground with real contrast, keeping the hue the user picked.
    readonly property color accent: tok.light
        ? Qt.hsla(tok._h, Math.max(0.35, Math.min(0.95, tok._s)), 0.34, 1)
        : Qt.hsla(tok._h, Math.max(0.42, Math.min(0.95, tok._s)), 0.62, 1)
    readonly property color accentInk:  tok.light ? "#ffffff" : Qt.hsla(tok._h, 0.55, 0.07, 1)
    readonly property color accentWash: tok.light ? Qt.hsla(tok._h, 0.34, 0.915, 1)
                                                  : Qt.hsla(tok._h, 0.40, 0.155, 1)

    // ---------------- ground → raised (four steps, no more) ----------------
    readonly property color bg:      tok.light ? Qt.hsla(tok._h, 0.07, 0.940, 1) : Qt.hsla(tok._h, 0.14, 0.072, 1)
    readonly property color surface: tok.light ? Qt.hsla(tok._h, 0.09, 0.972, 1) : Qt.hsla(tok._h, 0.13, 0.104, 1)
    readonly property color raised:  tok.light ? Qt.hsla(tok._h, 0.10, 1.000, 1) : Qt.hsla(tok._h, 0.12, 0.136, 1)
    readonly property color sunken:  tok.light ? Qt.hsla(tok._h, 0.08, 0.898, 1) : Qt.hsla(tok._h, 0.16, 0.046, 1)

    // ---------------- ink (three steps) ----------------
    readonly property color ink:  tok.light ? Qt.hsla(tok._h, 0.16, 0.090, 1) : Qt.hsla(tok._h, 0.08, 0.912, 1)
    readonly property color ink2: tok.light ? Qt.hsla(tok._h, 0.12, 0.310, 1) : Qt.hsla(tok._h, 0.08, 0.680, 1)
    readonly property color ink3: tok.light ? Qt.hsla(tok._h, 0.10, 0.520, 1) : Qt.hsla(tok._h, 0.08, 0.492, 1)

    // ---------------- rules (two weights — these do the structural work) ----------------
    readonly property color rule:     tok.light ? Qt.hsla(tok._h, 0.10, 0.845, 1) : Qt.hsla(tok._h, 0.12, 0.190, 1)
    readonly property color ruleHard: tok.light ? Qt.hsla(tok._h, 0.11, 0.720, 1) : Qt.hsla(tok._h, 0.12, 0.282, 1)

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

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // per-monitor UI scale — matches the rule shell.qml and Dashboard.qml both hand-rolled
    function uiFor(scr) {
        if (tok.cfgScale > 0) return tok.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }
}
