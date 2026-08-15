// A labelled REGION, not a card. Label + hard rule + content. This is the replacement for the
// translucent rounded boxes the old surfaces nested two and three deep — one level of surface,
// subdivided by rules. `action` puts a single ghost control on the label line (refresh, add).
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: p
    property string title: ""
    property string note: ""               // right-hand annotation: counts, units, timestamps
    default property alias content: body.data

    // QtQuick.Layouts defaults fillHeight/fillWidth to TRUE for nested Layout types (unlike
    // plain Items, which default false). A panel left at that default eats all the slack in its
    // column and its rows stretch with it — which is why the KPI rules ran the full height of
    // the region with the figures stranded at the bottom. Panels size to content unless the
    // caller explicitly asks to expand (the task list does).
    Layout.fillHeight: false

    spacing: 0

    RowLayout {
        Layout.fillWidth: true
        spacing: Tok.s2
        IndLabel { text: p.title }
        Item { Layout.fillWidth: true }
        IndText { visible: p.note !== ""; mono: true; sz: Tok.tData; text: p.note; color: Tok.ink3 }
    }
    IndRule { hard: true; Layout.fillWidth: true; Layout.topMargin: Tok.s1 }
    ColumnLayout {
        id: body
        Layout.fillWidth: true
        Layout.topMargin: Tok.s3
        spacing: Tok.s2
    }
}
