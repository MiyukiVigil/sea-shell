import QtQuick

// Authentic Material You (Material 3) tonal icon container + filled Material Symbols Rounded glyph.
// Automatically derives M3 tonal container + on-container colors for both Light and Dark modes,
// and harmonizes with Tok.accentInk when active inside a selected sidebar pill.
Rectangle {
    id: badge
    property string icon: "tune"
    property color badgeColor: Tok.accent
    property int size: 24
    property int iconSize: Math.round(size * 0.60)
    property bool ringed: false

    readonly property real _h: badgeColor.hslHue >= 0 ? badgeColor.hslHue : Tok._h
    readonly property real _s: badgeColor.hslSaturation
    readonly property bool _neutral: _s < 0.12

    readonly property color containerFill: {
        if (ringed) return Qt.rgba(Tok.accentInk.r, Tok.accentInk.g, Tok.accentInk.b, 0.18);
        if (_neutral) {
            return Tok.light
                ? Qt.hsla(Tok._h, 0.14 * Tok._sm, 0.90, 1)
                : Qt.hsla(Tok._h, 0.16 * Tok._sm, 0.24, 1);
        }
        return Tok.light
            ? Qt.hsla(_h, Math.min(0.86, _s * 0.92), 0.90, 1)
            : Qt.hsla(_h, Math.min(0.58, _s * 0.62), 0.24, 1);
    }

    readonly property color glyphColor: {
        if (ringed) return Tok.accentInk;
        if (_neutral) {
            return Tok.light
                ? Qt.hsla(Tok._h, 0.18 * Tok._sm, 0.28, 1)
                : Qt.hsla(Tok._h, 0.14 * Tok._sm, 0.84, 1);
        }
        return Tok.light
            ? Qt.hsla(_h, Math.min(0.95, _s * 1.02), 0.34, 1)
            : Qt.hsla(_h, Math.min(0.90, _s * 0.95), 0.80, 1);
    }

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    radius: size / 2
    color: containerFill
    Behavior on color { ColorAnimation { duration: Tok.mFast } }

    Text {
        anchors.centerIn: parent
        text: badge.icon
        color: badge.glyphColor
        renderType: Text.NativeRendering
        font.family: "Material Symbols Rounded"
        font.pixelSize: badge.iconSize
        font.variableAxes: ({
            "FILL": 1,
            "wght": 500,
            "GRAD": 0,
            "opsz": Math.max(20, Math.min(48, badge.iconSize))
        })
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }
}
