// A real table. Data belongs in one of these, not in a stack of bespoke rows — which is what
// every data-bearing surface in this shell had grown its own copy of (displays, keybinds, audio
// devices, VPNs, processes each hand-rolled the same header + row + hairline layout).
//
// Columns are declared once and drive BOTH the header and the cells, so they cannot drift apart:
//
//   IndTable {
//       columns: [
//           { label: "Command", key: "name", flex: true },
//           { label: "CPU %",   key: "cpu",  w: 60, num: true },
//       ]
//       rows: root.procList
//   }
//
// Column fields: label · key · w (fixed px) · flex (takes slack) · num (right-aligned mono,
// tabular) · mono (mono without right-aligning). A row may carry `_tone` ("ok"|"warn"|"crit")
// to colour its numeric cells, and `_sel` is handled via selectedIndex.
//
// Deliberately NO zebra striping: hairlines already separate rows, and stripes are noise.

import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: t

    property var columns: []
    property var rows: []
    property int rowHeight: 30
    property string emptyText: "—"
    property bool selectable: false
    property int selectedIndex: -1
    // Cap long tables, but never silently: the footer says what was dropped, because a truncated
    // list that looks complete is worse than no list.
    property int maxRows: 0
    signal activated(int index, var row)

    readonly property int _shown: t.maxRows > 0 ? Math.min(t.maxRows, t.rows.length) : t.rows.length
    readonly property int _hidden: t.rows.length - t._shown

    spacing: 0

    function _cellText(row, col) {
        var v = row ? row[col.key] : undefined;
        return (v === undefined || v === null || v === "") ? "—" : "" + v;
    }

    // ---- header ----
    RowLayout {
        Layout.fillWidth: true
        spacing: Tok.s3
        Repeater {
            model: t.columns
            delegate: IndLabel {
                required property var modelData
                text: modelData.label || ""
                horizontalAlignment: modelData.num ? Text.AlignRight : Text.AlignLeft
                elide: Text.ElideRight
                Layout.fillWidth: !!modelData.flex
                Layout.preferredWidth: modelData.w ? modelData.w : -1
            }
        }
    }
    IndRule { hard: true; Layout.fillWidth: true; Layout.topMargin: 3 }

    // ---- rows ----
    Repeater {
        model: t._shown
        delegate: Rectangle {
            id: rowRect
            required property int index
            readonly property var rowData: t.rows[index] || ({})
            readonly property bool sel: t.selectable && t.selectedIndex === index

            Layout.fillWidth: true
            implicitHeight: t.rowHeight
            radius: Tok.rSmall
            color: rowRect.sel ? Tok.accentWash
                 : (rowMa.containsMouse ? Tok.surface : "transparent")

            // selection is an inset bar, not a border — a border reads as a pressable control
            Rectangle {
                visible: rowRect.sel
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 2; color: Tok.accent
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Tok.s2
                anchors.rightMargin: Tok.s2
                spacing: Tok.s3
                Repeater {
                    model: t.columns
                    delegate: Item {
                        id: cell
                        required property var modelData
                        readonly property string val: t._cellText(rowRect.rowData, modelData)
                        implicitHeight: t.rowHeight
                        Layout.fillWidth: !!cell.modelData.flex
                        Layout.preferredWidth: cell.modelData.w ? cell.modelData.w : -1

                        // chip columns carry short categorical values — key combos, statuses,
                        // device types — where a bordered token reads faster than bare text
                        IndChip {
                            visible: !!cell.modelData.chip && cell.val !== "—"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: cell.modelData.num ? parent.right : undefined
                            anchors.left: cell.modelData.num ? undefined : parent.left
                            text: cell.val
                            tone: rowRect.rowData[cell.modelData.toneKey || "_tone"] || "neutral"
                        }

                        IndText {
                            visible: !cell.modelData.chip
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: cell.val
                            // numerics are mono + tabular so columns stay aligned between refreshes
                            mono: !!cell.modelData.num || !!cell.modelData.mono
                            sz: cell.modelData.num ? Tok.tData : Tok.tDense
                            horizontalAlignment: cell.modelData.num ? Text.AlignRight : Text.AlignLeft
                            elide: Text.ElideRight
                            color: cell.modelData.num && rowRect.rowData._tone === "crit" ? Tok.crit
                                 : cell.modelData.num && rowRect.rowData._tone === "warn" ? Tok.warn
                                 : cell.modelData.num && rowRect.rowData._tone === "ok"   ? Tok.ok
                                 : cell.modelData.num ? Tok.ink2 : Tok.ink
                        }
                    }
                }
            }

            IndRule {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            }

            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: t.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (t.selectable) t.selectedIndex = rowRect.index;
                    t.activated(rowRect.index, rowRect.rowData);
                }
            }
        }
    }

    IndText {
        visible: t.rows.length === 0
        text: t.emptyText
        mono: true
        color: Tok.ink3
        Layout.topMargin: Tok.s1
    }
    IndText {
        visible: t._hidden > 0
        text: "+" + t._hidden + " more not shown"
        mono: true
        sz: Tok.tData
        color: Tok.ink3
        Layout.topMargin: Tok.s1
    }
}
