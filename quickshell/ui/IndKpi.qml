// One figure, read at arm's length. Mono uppercase label above, the number at a scale-step
// size, unit and detail below. Never assembled into a grid of six identical tiles — lay these
// on a row separated by hairline verticals so one figure clearly leads.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: k
    property string label: ""
    property string value: "—"
    property string unit: ""
    property string sub: ""
    property string tone: "neutral"        // neutral | ok | warn | crit
    property int    size: Tok.tKpi

    spacing: 2

    IndLabel { text: k.label }
    RowLayout {
        spacing: 3
        IndText {
            mono: true
            sz: k.size
            text: k.value
            font.weight: 500
            color: k.tone === "ok" ? Tok.ok : k.tone === "warn" ? Tok.warn
                 : k.tone === "crit" ? Tok.crit : Tok.ink
        }
        IndText {
            visible: k.unit !== ""
            mono: true
            sz: Math.max(Tok.tData, Math.round(k.size * 0.45))
            text: k.unit
            color: Tok.ink3
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: Math.round(k.size * 0.12)
        }
    }
    IndText { visible: k.sub !== ""; mono: true; sz: Tok.tData; text: k.sub; color: Tok.ink3 }
}
