// Sparkline over a fixed 0–100 scale. A flat accent wash under a 1px accent stroke — no
// gradient fill, no glow, no curve smoothing that invents data between samples. The baseline
// hairline is what makes it readable as an instrument trace rather than a decorative squiggle.
import QtQuick

Item {
    id: sp
    property var values: []
    property color stroke: Tok.accent
    property real max: 100
    // The trace normally sits in a sunken well, which is right inside a panel and wrong on
    // a wallpaper — there it reads as a black bar someone left on the picture. Callers on
    // the desktop pass "transparent" and keep only the baseline and the trace.
    property color ground: Tok.sunken

    Rectangle { anchors.fill: parent; color: sp.ground }

    // 50% reference line — without it a sparkline has no scale at all
    Rectangle {
        anchors.left: parent.left; anchors.right: parent.right
        y: Math.round(parent.height / 2)
        height: 1
        color: Tok.rule
    }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var v = sp.values || [];
            if (v.length < 2) return;
            var step = width / (v.length - 1);
            function yAt(i) {
                var n = Math.max(0, Math.min(sp.max, v[i] || 0));
                return height - (n / sp.max) * (height - 1) - 0.5;
            }
            // wash under the trace
            ctx.beginPath();
            ctx.moveTo(0, height);
            for (var i = 0; i < v.length; i++) ctx.lineTo(i * step, yAt(i));
            ctx.lineTo(width, height);
            ctx.closePath();
            ctx.fillStyle = Qt.rgba(sp.stroke.r, sp.stroke.g, sp.stroke.b, 0.16);
            ctx.fill();
            // the trace itself
            ctx.beginPath();
            for (var j = 0; j < v.length; j++) {
                var x = j * step, y = yAt(j);
                if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.lineWidth = 1;
            ctx.strokeStyle = sp.stroke;
            ctx.stroke();
        }
    }

    onValuesChanged: cv.requestPaint()
    onWidthChanged: cv.requestPaint()
    onHeightChanged: cv.requestPaint()
    Connections { target: Tok; function onChanged() { cv.requestPaint() } }
}
