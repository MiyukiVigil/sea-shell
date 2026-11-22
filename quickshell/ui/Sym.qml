import QtQuick
import QtQuick.Layouts

// Material You (Material Symbols Rounded) variable icon glyph.
Text {
    id: sym
    property int sz: 18
    property bool filled: false
    property int weight: 500
    renderType: Text.NativeRendering
    font.family: "Material Symbols Rounded"
    font.pixelSize: sz
    font.variableAxes: ({
        "FILL": sym.filled ? 1 : 0,
        "wght": sym.weight,
        "GRAD": 0,
        "opsz": Math.max(20, Math.min(48, sym.sz))
    })
    color: theme.frost
    verticalAlignment: Text.AlignVCenter
}
