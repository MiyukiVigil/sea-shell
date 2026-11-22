// One piece of the shell's glass (see Tok's glass tokens): the bar, a dropdown card, a
// notification, an indicator. Put content inside it or beside it; its own layers stay below.
// Hyprland blurs what is behind (layer_rule blur in sea.lua); this is the tint and the edge.
import QtQuick

Rectangle {
    id: g
    // false: draw nothing (the bar in "pills" shape, where each pill is its own glass)
    property bool on: true
    property color tint: Tok.glassTint
    color: g.on ? Tok.alpha(g.tint, Tok.glassAlpha) : "transparent"
    border.width: g.on ? 1 : 0
    border.color: Tok.glassy ? Tok.glassEdge : Tok.alpha(Tok.ink, 0.08)
    // light along the top edge, fading out by the middle: what makes glass read as glass
    // rather than a tinted hole
    Rectangle {
        anchors.fill: parent; anchors.margins: 1
        radius: Math.max(0, g.radius - 1)
        visible: Tok.glassy && g.on
        gradient: Gradient {
            GradientStop { position: 0.0; color: Tok.glassSheen }
            GradientStop { position: Math.min(0.5, 14 / Math.max(1, g.height)); color: Tok.alpha(Tok.glassSheen, Tok.glassSheen.a * 0.25) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
}
