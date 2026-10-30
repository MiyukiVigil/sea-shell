import QtQuick
import QtQuick.Shapes

// A battery level as a ring around the device's symbol, for the Batteries widget
// (MaterialWidget.qml). Its own file because an inline component added to a loaded file
// does not survive Quickshell's hot reload.
Item {
    id: ring
    property real value: 0
    property string icon: ""
    property color tint: "#63c7dd"
    property color track: Qt.rgba(0.5, 0.5, 0.5, 0.22)
    property color ink: "white"
    property real stroke: 5
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: ring.track; strokeWidth: ring.stroke
            fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - ring.stroke / 2; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
        }
        ShapePath {
            strokeColor: ring.tint; strokeWidth: ring.stroke
            fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - ring.stroke / 2; radiusY: radiusX
                startAngle: -90; sweepAngle: 3.6 * Math.max(1, Math.min(100, ring.value)) }
        }
    }
    Text {
        anchors.centerIn: parent; text: ring.icon; color: ring.ink
        font.family: "Material Symbols Rounded"; font.variableAxes: ({ "FILL": 0, "wght": 400 })
        font.pixelSize: ring.width * 0.36
    }
}
