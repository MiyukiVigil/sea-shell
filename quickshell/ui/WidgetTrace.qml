// A filled line of recent values, newest at the right, scaled to its own peak. Used by the
// network widget (MaterialWidget). Its own file: Quickshell's live reload does not pick up a
// NEW inline component (see DesktopOption.qml).
import QtQuick

Canvas {
    id: tr
    property var points: []
    property int span: 30
    property color tone: "#65538c"
    property real lineWidth: 2
    onPointsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        var ctx = getContext("2d"); ctx.reset();
        var n = points.length; if (n < 2) return;
        var mx = 1; for (var i = 0; i < n; i++) mx = Math.max(mx, points[i]);
        var step = width / (span - 1), x0 = width - (n - 1) * step;
        function yAt(v) { return height - (v / mx) * (height - lineWidth - 1) }
        ctx.beginPath(); ctx.moveTo(x0, height);
        for (var j = 0; j < n; j++) ctx.lineTo(x0 + j * step, yAt(points[j]));
        ctx.lineTo(x0 + (n - 1) * step, height); ctx.closePath();
        ctx.fillStyle = Qt.rgba(tone.r, tone.g, tone.b, 0.16); ctx.fill();
        ctx.beginPath();
        for (var k = 0; k < n; k++) { if (k) ctx.lineTo(x0 + k * step, yAt(points[k])); else ctx.moveTo(x0, yAt(points[0])) }
        ctx.strokeStyle = tone; ctx.lineWidth = lineWidth; ctx.lineJoin = "round"; ctx.stroke();
    }
}
