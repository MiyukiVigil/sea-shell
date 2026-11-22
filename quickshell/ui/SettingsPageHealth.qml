// Settings → General → Health Check. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 34
    visible: root.tab === 34
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "stethoscope"
        badgeColor: "#30B0C7"
        title: "Health Check"
        description: "Verify sea-shell dependencies, Hyprland configuration validity, deployment status, and bar crash history."
    }

    Section { title: "Diagnostics"; icon: "stethoscope" }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Text {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: root.docRows.length === 0
                ? "Run a system health check to inspect every sea-shell component."
                : (root.docCrit > 0
                    ? (root.docCrit + " problem" + (root.docCrit === 1 ? "" : "s")
                        + (root.docWarn > 0 ? "  ·  " + root.docWarn + " warning" + (root.docWarn === 1 ? "" : "s") : ""))
                    : root.docWarn > 0
                        ? (root.docWarn + " warning" + (root.docWarn === 1 ? "" : "s") + "  ·  nothing broken")
                        : "All " + root.docRows.length + " checks passed")
            color: root.docCrit > 0 ? Tok.crit : root.docWarn > 0 ? Tok.warn : Tok.ink2
            font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
        }
        IndBtn {
            text: root.docRunning ? "Checking…" : "Run check"
            rank: "primary"
            enabled: !root.docRunning
            onActivated: root.runHealthCheck()
        }
    }
    IndTable {
        visible: root.docRows.length > 0
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 28
        rows: root.docSorted
        maxRows: 18
        columns: [
            { label: "",       key: "st",     w: 56, chip: true },
            { label: "Area",   key: "cat",    w: 92 },
            { label: "Item",   key: "item",   w: 150 },
            { label: "Detail", key: "detail", flex: true }
        ]
    }
}
