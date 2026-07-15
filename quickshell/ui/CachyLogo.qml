// CachyOS mark, drawn natively so it recolours with the theme accent (like SeaLogo)
// instead of pulling the fixed teal-gradient /usr/share/icons/cachyos.svg. Nerd Fonts
// ships no CachyOS glyph, so this fills that gap for the System/About page.
// Geometry traced from the official logo (64×64 viewBox), scaled to `size`.
//   CachyLogo { size: 19; color: theme.iris }
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property real size: 24
    property color color: "#63c7dd"
    implicitWidth: size; implicitHeight: size

    // authored at 64×64 then scaled to `size` from the top-left corner
    Item {
        width: 64; height: 64
        scale: root.size / 64
        transformOrigin: Item.TopLeft

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer   // crisp per-pixel AA when scaled down

            // the open "C" chevron silhouette
            ShapePath {
                fillColor: root.color; strokeColor: "transparent"
                PathSvg { path: "M15.761 9.639 L42.959 9.639 L36.074 21.565 L21.324 21.565 L15.178 32.21 L21.41 43.003 L50.181 43.003 L43.121 55.232 L15.177 55.232 L1.695 31.88 L14.602 9.525 Z" }
            }
            // the three trailing dots (large → small)
            ShapePath { fillColor: root.color; strokeColor: "transparent"
                PathAngleArc { centerX: 57.6;   centerY: 38.429; radiusX: 4.641; radiusY: 4.641; startAngle: 0; sweepAngle: 360 } }
            ShapePath { fillColor: root.color; strokeColor: "transparent"
                PathAngleArc { centerX: 45.714; centerY: 28.659; radiusX: 3.524; radiusY: 3.524; startAngle: 0; sweepAngle: 360 } }
            ShapePath { fillColor: root.color; strokeColor: "transparent"
                PathAngleArc { centerX: 50.467; centerY: 15.061; radiusX: 1.814; radiusY: 1.814; startAngle: 0; sweepAngle: 360 } }
        }
    }
}
