// sea-shell logo: a moon setting over the sea, drawn natively so it follows the theme.
// Every colour comes from the accent's hue (matugen), so it is the same badge as logo.svg
// with the default accent #535a92 and shifts with the wallpaper otherwise.
// Authored in a 112×112 box (the disc, centre 56,56, radius 53) and scaled to `size`.
// card/highlight/rim are kept so callers that pass the old four colours still work; the
// badge is self-contained (its own sky and outline) and does not need them.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property real size: 24
    property color accent: "#535a92"
    property color card: "transparent"
    property color highlight: "white"
    property color rim: accent

    implicitWidth: size; implicitHeight: size

    // the accent's hue and saturation; lightness is set per layer
    readonly property real _h: Math.max(0, root.accent.hslHue)
    readonly property real _s: root.accent.hslSaturation
    function _tone(dh, s, l) { return Qt.hsla((root._h + dh + 1) % 1, Math.min(1, s), l, 1) }
    readonly property color skyTop:    _tone(0, 0.9, 0.89)
    // the glow and the moon stay warm whatever the accent: a sunset is never green
    readonly property color skyLow:    Qt.hsla(0.93, 0.7, 0.88, 1)
    readonly property color moon:      Qt.hsla(0.04, 0.8, 0.975, 1)
    readonly property color sea0:      _tone(0, root._s * 2.4, 0.76)
    readonly property color sea1:      _tone(0, root._s * 1.85, 0.63)
    readonly property color sea2:      root.accent
    readonly property color sea3:      _tone(0, root._s * 1.2, 0.34)
    readonly property color outline:   _tone(0, Math.max(0.3, root._s * 1.3), 0.26)

    Item {
        width: 114; height: 114
        scale: root.size / 114
        transformOrigin: Item.TopLeft

        Shape {
            x: 1; y: 1; width: 112; height: 112
            // analytic AA: stays crisp at bar size without surface MSAA
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: "transparent"
                fillGradient: LinearGradient { x1: 0; y1: 4; x2: 0; y2: 62
                    GradientStop { position: 0; color: root.skyTop }
                    GradientStop { position: 1; color: root.skyLow } }
                PathSvg { path: "M3 56 A53 53 0 1 1 109 56 A53 53 0 1 1 3 56 Z" }
            }
            ShapePath { strokeColor: "transparent"; fillColor: root.moon
                PathSvg { path: "M59 44 A15 15 0 1 1 89 44 A15 15 0 1 1 59 44 Z" } }
            ShapePath { strokeColor: "transparent"; fillColor: root.sea0
                PathSvg { path: "M3.5 53.9 L4 53.8 L5 53.7 L6 53.6 L7 53.5 L8 53.5 L9 53.5 L10 53.6 L11 53.7 L12 53.8 L13 54 L14 54.3 L15 54.5 L16 54.8 L17 55.1 L18 55.5 L19 55.9 L20 56.3 L21 56.7 L22 57.1 L23 57.6 L24 58 L25 58.4 L26 58.9 L27 59.3 L28 59.7 L29 60.1 L30 60.5 L31 60.9 L32 61.2 L33 61.5 L34 61.7 L35 62 L36 62.2 L37 62.3 L38 62.4 L39 62.5 L40 62.5 L41 62.5 L42 62.4 L43 62.3 L44 62.2 L45 62 L46 61.7 L47 61.5 L48 61.2 L49 60.9 L50 60.5 L51 60.1 L52 59.7 L53 59.3 L54 58.9 L55 58.4 L56 58 L57 57.6 L58 57.1 L59 56.7 L60 56.3 L61 55.9 L62 55.5 L63 55.1 L64 54.8 L65 54.5 L66 54.3 L67 54 L68 53.8 L69 53.7 L70 53.6 L71 53.5 L72 53.5 L73 53.5 L74 53.6 L75 53.7 L76 53.8 L77 54 L78 54.3 L79 54.5 L80 54.8 L81 55.1 L82 55.5 L83 55.9 L84 56.3 L85 56.7 L86 57.1 L87 57.6 L88 58 L89 58.4 L90 58.9 L91 59.3 L92 59.7 L93 60.1 L94 60.5 L95 60.9 L96 61.2 L97 61.5 L98 61.7 L99 62 L100 62.2 L101 62.3 L102 62.4 L103 62.5 L104 62.5 L105 62.5 L106 62.4 L107 62.3 L108 62.2 L108.5 62.1 A53 53 0 0 1 3.5 53.9 Z" } }
            ShapePath { strokeColor: "transparent"; fillColor: root.sea1
                PathSvg { path: "M4.5 67.8 L5 67.7 L6 67.6 L7 67.5 L8 67.5 L9 67.5 L10 67.6 L11 67.7 L12 67.8 L13 68 L14 68.3 L15 68.5 L16 68.8 L17 69.1 L18 69.5 L19 69.9 L20 70.3 L21 70.7 L22 71.1 L23 71.6 L24 72 L25 72.4 L26 72.9 L27 73.3 L28 73.7 L29 74.1 L30 74.5 L31 74.9 L32 75.2 L33 75.5 L34 75.7 L35 76 L36 76.2 L37 76.3 L38 76.4 L39 76.5 L40 76.5 L41 76.5 L42 76.4 L43 76.3 L44 76.2 L45 76 L46 75.7 L47 75.5 L48 75.2 L49 74.9 L50 74.5 L51 74.1 L52 73.7 L53 73.3 L54 72.9 L55 72.4 L56 72 L57 71.6 L58 71.1 L59 70.7 L60 70.3 L61 69.9 L62 69.5 L63 69.1 L64 68.8 L65 68.5 L66 68.3 L67 68 L68 67.8 L69 67.7 L70 67.6 L71 67.5 L72 67.5 L73 67.5 L74 67.6 L75 67.7 L76 67.8 L77 68 L78 68.3 L79 68.5 L80 68.8 L81 69.1 L82 69.5 L83 69.9 L84 70.3 L85 70.7 L86 71.1 L87 71.6 L88 72 L89 72.4 L90 72.9 L91 73.3 L92 73.7 L93 74.1 L94 74.5 L95 74.9 L96 75.2 L97 75.5 L98 75.7 L99 76 L100 76.2 L101 76.3 L102 76.4 L103 76.5 L104 76.5 L104.5 76.5 A53 53 0 0 1 4.5 67.8 Z" } }
            ShapePath { strokeColor: "transparent"; fillColor: root.sea2
                PathSvg { path: "M10.5 82.6 L11 82.7 L12 82.8 L13 83 L14 83.3 L15 83.5 L16 83.8 L17 84.1 L18 84.5 L19 84.9 L20 85.3 L21 85.7 L22 86.1 L23 86.6 L24 87 L25 87.4 L26 87.9 L27 88.3 L28 88.7 L29 89.1 L30 89.5 L31 89.9 L32 90.2 L33 90.5 L34 90.7 L35 91 L36 91.2 L37 91.3 L38 91.4 L39 91.5 L40 91.5 L41 91.5 L42 91.4 L43 91.3 L44 91.2 L45 91 L46 90.7 L47 90.5 L48 90.2 L49 89.9 L50 89.5 L51 89.1 L52 88.7 L53 88.3 L54 87.9 L55 87.4 L56 87 L57 86.6 L58 86.1 L59 85.7 L60 85.3 L61 84.9 L62 84.5 L63 84.1 L64 83.8 L65 83.5 L66 83.3 L67 83 L68 82.8 L69 82.7 L70 82.6 L71 82.5 L72 82.5 L73 82.5 L74 82.6 L75 82.7 L76 82.8 L77 83 L78 83.3 L79 83.5 L80 83.8 L81 84.1 L82 84.5 L83 84.9 L84 85.3 L85 85.7 L86 86.1 L87 86.6 L88 87 L89 87.4 L90 87.9 L91 88.3 L92 88.7 L93 89.1 L94 89.5 L95 89.9 L96 90.2 L96 90.2 A53 53 0 0 1 10.5 82.6 Z" } }
            ShapePath { strokeColor: "transparent"; fillColor: root.sea3
                PathSvg { path: "M40 106.5 L40.5 106.5 L41.5 106.5 L42.5 106.4 L43.5 106.2 L44.5 106.1 L45.5 105.9 L46.5 105.6 L47.5 105.3 L48.5 105 L49.5 104.7 L50.5 104.3 L51.5 103.9 L52.5 103.5 L53.5 103.1 L54.5 102.7 L55.5 102.2 L56.5 101.8 L57.5 101.3 L58.5 100.9 L59.5 100.5 L60.5 100.1 L61.5 99.7 L62.5 99.3 L63.5 99 L64.5 98.7 L65.5 98.4 L66.5 98.1 L67.5 97.9 L68.5 97.8 L69.5 97.6 L70.5 97.5 L71.5 97.5 L72.5 97.5 L73.5 97.5 L74.5 97.6 L75.5 97.8 L76.5 97.9 L77.5 98.1 L78.5 98.4 L79.5 98.7 L80.5 99 L81.5 99.3 L82.5 99.7 L83.5 100.1 L84.5 100.5 L84.5 100.5 A53 53 0 0 1 40 106.5 Z" } }
            // the moon's glint on the water
            ShapePath { fillColor: "transparent"; strokeWidth: 3; capStyle: ShapePath.RoundCap
                strokeColor: Qt.rgba(root.moon.r, root.moon.g, root.moon.b, 0.8)
                PathSvg { path: "M62 64 h22 M66 69 h14" } }
            ShapePath { fillColor: "transparent"; strokeWidth: 3.5; strokeColor: root.outline
                PathSvg { path: "M3 56 A53 53 0 1 1 109 56 A53 53 0 1 1 3 56 Z" } }
        }
    }
}
