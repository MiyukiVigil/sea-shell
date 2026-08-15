// Base text. `mono` selects the role: mono carries every machine-readable value (numbers,
// IDs, timestamps, status, units), sans carries prose. Tabular figures are forced on the mono
// role so values stop shifting width between polls — a 1Hz stat readout that reflows on every
// tick is the fastest way for an instrument to look amateur.
import QtQuick

Text {
    id: t
    property bool mono: false
    property int  sz: Tok.tDense
    color: Tok.ink
    font.family: t.mono ? Tok.mono : Tok.sans
    font.pixelSize: t.sz
    font.features: t.mono ? ({ "tnum": 1 }) : ({})
    renderType: Text.NativeRendering
    textFormat: Text.PlainText
}
