// sea-shell — the bar's leading mark.
//
// It used to be SeaLogo, always, hardcoded into the bar's left cluster. That is the wrong
// default for a shell people run on their own distro: the first thing on the bar should be
// able to say what the machine IS, not what the shell is.
//
// Four kinds of mark, in one component so the bar has one child either way:
//   · drawn      — SeaLogo and CachyLogo, authored as QML shapes, so they recolour with
//                  the theme instead of being fixed-colour SVGs
//   · glyph      — any distro in a Nerd Font, which is where the whole set already lives;
//                  drawing fifteen distro logos by hand would be fifteen things to maintain
//   · image      — a file the user points at, for anything not covered
//   · auto       — whatever /etc/os-release says this machine is (resolved by the caller)
//
// Everything degrades: no Nerd Font installed → the sea logo rather than a row of boxes,
// an unreadable image → the same.
import QtQuick

Item {
    id: root

    // "sea" · "cachy" · "custom" · any key in `glyphs`
    property string kind: "sea"
    property string imagePath: ""
    property real size: 24

    property color card:      "#232634"
    property color accent:    "#63c7dd"
    property color highlight: "#d7f0ef"
    property color rim:       "#63c7dd"

    implicitWidth: size; implicitHeight: size

    // nf-linux-* from Nerd Fonts v3. Kept as data rather than as a switch so Settings can
    // build its picker from the same list — one definition of what is offerable.
    readonly property var glyphs: ({
        "arch":        "",
        "alpine":      "",
        "artix":       "",
        "debian":      "",
        "endeavouros": "",
        "fedora":      "",
        "gentoo":      "",
        "manjaro":     "",
        "mint":        "",
        "nixos":       "",
        "opensuse":    "",
        "pop":         "",
        "ubuntu":      "",
        "void":        "",
        "tux":         ""
    })

    // The first Nerd Font actually installed. Probed rather than hardcoded: the symbols-only
    // font is the tidiest carrier but almost nobody installs it deliberately, whereas anyone
    // who patched a terminal font has one of the others.
    readonly property string nerdFamily: {
        var fams = Qt.fontFamilies();
        var prefs = ["Symbols Nerd Font", "Symbols Nerd Font Mono",
                     "MesloLGL Nerd Font", "FantasqueSansM Nerd Font",
                     "JetBrainsMono Nerd Font", "FiraCode Nerd Font", "Hack Nerd Font"];
        for (var i = 0; i < prefs.length; i++)
            if (fams.indexOf(prefs[i]) >= 0) return prefs[i];
        for (var j = 0; j < fams.length; j++)
            if (fams[j].indexOf("Nerd Font") >= 0) return fams[j];
        return "";
    }

    readonly property bool isGlyph: root.glyphs[root.kind] !== undefined && root.nerdFamily !== ""
    readonly property bool isImage: root.kind === "custom" && root.imagePath.length > 0
                                    && img.status !== Image.Error
    readonly property bool isCachy: root.kind === "cachy"
    // The fallback for everything else, including a glyph asked for on a machine with no
    // Nerd Font — a row of tofu boxes on the bar is worse than the shell's own mark.
    readonly property bool isSea:   !root.isGlyph && !root.isImage && !root.isCachy

    SeaLogo {
        visible: root.isSea
        size: root.size
        card: root.card; accent: root.accent; highlight: root.highlight; rim: root.rim
    }

    // CachyLogo takes a single colour, not the four-part card/accent/highlight/rim that
    // SeaLogo does — it is one mark, not a badge on a card. Nerd Fonts ships no CachyOS
    // glyph, which is exactly why this drawn one exists.
    CachyLogo {
        anchors.centerIn: parent
        visible: root.isCachy
        size: root.size
        color: root.accent
    }

    Text {
        anchors.centerIn: parent
        visible: root.isGlyph
        text: root.glyphs[root.kind] || ""
        font.family: root.nerdFamily
        // Glyphs are drawn on the text baseline with their own bearing, so matching the
        // drawn logos' visual weight means going a little larger than the box.
        font.pixelSize: Math.round(root.size * 0.92)
        color: root.accent
    }

    Image {
        id: img
        anchors.fill: parent
        visible: root.isImage
        source: root.imagePath.length ? ("file://" + root.imagePath) : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true; cache: true
        sourceSize.width: Math.round(root.size * 2)
        sourceSize.height: Math.round(root.size * 2)
        smooth: true
    }
}
