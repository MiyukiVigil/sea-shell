// sea-shell logo, drawn natively so it recolours with the theme (matugen accent + light/dark)
// instead of being a fixed-colour SVG. Same geometry as logo.svg (64×64 viewBox), scaled down.
// Pass the four theme colours from the caller:
//   SeaLogo { size: 24; card: theme.panel; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property real size: 24
    property color card:      "#232634"   // rounded backdrop
    property color accent:    "#63c7dd"   // the sea — middle/bottom waves, tint, rim
    property color highlight: "#d7f0ef"   // bright crest (top wave)
    property color rim:       "#63c7dd"   // border stroke

    implicitWidth: size; implicitHeight: size

    // everything is authored at 64×64 then scaled to `size` from the top-left corner
    Item {
        width: 64; height: 64
        scale: root.size / 64
        transformOrigin: Item.TopLeft

        Rectangle { x: 3; y: 3; width: 58; height: 58; radius: 16; color: root.card }
        Rectangle { x: 3; y: 3; width: 58; height: 58; radius: 16; color: root.accent; opacity: 0.12 }
        Rectangle { x: 3.75; y: 3.75; width: 56.5; height: 56.5; radius: 15.25
            color: "transparent"; border.width: 1.5; border.color: root.rim; opacity: 0.55 }

        Shape {
            anchors.fill: parent
            // analytic per-pixel AA — stays crisp when scaled down to `size`, where the
            // default GeometryRenderer needs surface MSAA and otherwise fringes/jags.
            preferredRendererType: Shape.CurveRenderer
            ShapePath { fillColor: "transparent"; capStyle: ShapePath.RoundCap; strokeWidth: 3.4
                strokeColor: Qt.rgba(root.highlight.r, root.highlight.g, root.highlight.b, 0.92)
                PathSvg { path: "M11 24 q5.25 -6 10.5 0 t10.5 0 t10.5 0 t10.5 0" } }
            ShapePath { fillColor: "transparent"; capStyle: ShapePath.RoundCap; strokeWidth: 3.4
                strokeColor: root.accent
                PathSvg { path: "M11 34 q5.25 -6 10.5 0 t10.5 0 t10.5 0 t10.5 0" } }
            ShapePath { fillColor: "transparent"; capStyle: ShapePath.RoundCap; strokeWidth: 3.4
                strokeColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6)
                PathSvg { path: "M11 44 q5.25 -6 10.5 0 t10.5 0 t10.5 0 t10.5 0" } }
        }
    }
}
