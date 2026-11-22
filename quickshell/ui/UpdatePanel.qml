// sea-shell updates: which version you're on, what the next one changes, and a way back. The
// work happens in sea-update.sh, detached, because installing restarts the process this runs in.
// That's also why the result is read from a file: the page that pressed Update may not survive.
import QtQuick
import QtQuick.Layouts
import Quickshell.Io

ColumnLayout {
    id: panel
    Layout.fillWidth: true
    spacing: 6

    readonly property string script: Qt.resolvedUrl("sea-update.sh").toString().replace("file://", "")
    property string state: ""        // uptodate·available·pending·ahead·diverged·dirty·norepo·offline
    property string installed: ""
    property string remote: ""
    property string detail: ""
    property string changes: ""
    property var drift: []
    property string undoTo: ""
    property string phase: ""        // working·updated·undone·failed, from the last run
    property string phaseText: ""
    property bool confirmUndo: false

    readonly property bool working: phase === "working"
    readonly property bool canUpdate: !working && !checkProc.running && (state === "available" || state === "pending")
    readonly property string headline: {
        switch (state) {
        case "available": case "pending": return "Version " + remote + " is ready";
        case "uptodate": return "You're up to date";
        case "dirty": return "Updates are paused";
        case "ahead": return "You're ahead of the remote";
        case "diverged": return "Updates need a hand";
        case "offline": return "Couldn't check for updates";
        case "norepo": return "Updates are off";
        default: return "Checking for updates…";
        }
    }
    function refresh() {
        statusProc.running = true;
        undoProc.running = true;
        if (!checkProc.running) checkProc.running = true;
    }
    onVisibleChanged: if (visible) refresh()
    Component.onCompleted: if (visible) refresh()

    Process { id: checkProc; command: ["sh", panel.script, "check"]
        stdout: StdioCollector { onStreamFinished: {
            var p = text.trim().split("|");
            if (p.length < 5) { panel.state = "offline"; panel.detail = "The check didn't finish."; return }
            panel.state = p[0]; panel.installed = p[1]; panel.remote = p[2]; panel.detail = p.slice(4).join("|");
            if (panel.state === "available" || panel.state === "pending") { changesProc.running = true; driftProc.running = true }
            else { panel.changes = ""; panel.drift = [] }
        } } }
    Process { id: changesProc; command: ["sh", panel.script, "changes"]
        stdout: StdioCollector { onStreamFinished: panel.changes = text.trim() } }
    Process { id: driftProc; command: ["sh", panel.script, "drift"]
        stdout: StdioCollector { onStreamFinished: panel.drift = text.split("\n").filter(function (l) { return l !== "" }) } }
    Process { id: undoProc; command: ["sh", panel.script, "undoable"]
        stdout: StdioCollector { onStreamFinished: panel.undoTo = text.trim() } }
    Process { id: statusProc; command: ["sh", panel.script, "status"]
        stdout: StdioCollector { onStreamFinished: {
            var p = text.trim().split("|");
            var was = panel.phase;
            panel.phase = p.length >= 4 ? p[0] : "";
            panel.phaseText = p.length >= 4 ? p.slice(3).join("|") : "";
            if (was === "working" && panel.phase !== "working") panel.refresh();
        } } }
    Process { id: startProc }
    function begin(cmd) {
        phase = "working"; phaseText = "Starting…"; confirmUndo = false;
        startProc.command = ["sh", script, cmd];
        startProc.running = true;
    }
    Timer { interval: 1000; repeat: true; running: panel.working && panel.visible; onTriggered: statusProc.running = true }

    RowLayout {
        Layout.fillWidth: true; spacing: 12
        ColumnLayout {
            Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 3
            Text { text: panel.working ? panel.phaseText : panel.headline; color: Tok.ink
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                font.pixelSize: 13; font.family: Tok.sans; font.weight: 600 }
            Text { visible: !panel.working
                text: (panel.installed ? "sea-shell " + panel.installed + ". " : "") + panel.detail
                color: Tok.ink3; Layout.fillWidth: true; wrapMode: Text.WordWrap
                font.pixelSize: 11; font.family: Tok.sans }
        }
        IndBtn { Layout.alignment: Qt.AlignVCenter; visible: !panel.canUpdate; text: checkProc.running ? "Checking…" : "Check"; rank: "secondary"
            enabled: !checkProc.running && !panel.working; onActivated: panel.refresh() }
        IndBtn { Layout.alignment: Qt.AlignVCenter; visible: panel.canUpdate; text: "Update to " + panel.remote; rank: "primary"
            onActivated: panel.begin("start") }
    }

    Text {
        visible: !panel.working && (panel.phase === "failed" || panel.phase === "updated" || panel.phase === "undone")
        text: panel.phaseText
        color: panel.phase === "failed" ? Tok.crit : Tok.ok
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        font.pixelSize: 12; font.family: Tok.sans; font.weight: 500
    }
    Text {
        visible: panel.drift.length > 0 && panel.canUpdate
        text: "You've changed " + panel.drift.join(" and ") + ". The update replaces " + (panel.drift.length === 1 ? "it" : "them")
              + " and keeps a dated copy next to " + (panel.drift.length === 1 ? "it." : "them.")
        color: Tok.warn; Layout.fillWidth: true; wrapMode: Text.WordWrap
        font.pixelSize: 11; font.family: Tok.sans
    }
    Text {
        visible: panel.changes !== "" && panel.canUpdate
        Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap
        textFormat: Text.MarkdownText
        text: panel.changes
        color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans
    }
    Text {
        Layout.fillWidth: true; Layout.topMargin: 2; wrapMode: Text.WordWrap
        text: "An update saves the current version first and goes back by itself if the bar won't stay up. Your settings aren't touched."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }
    RowLayout {
        visible: panel.undoTo !== "" && !panel.working
        Layout.fillWidth: true; spacing: 8
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: panel.confirmUndo ? "Go back to " + panel.undoTo + "? The bar restarts." : "Version " + panel.undoTo + " is saved if you want to go back."
            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
        IndBtn { visible: panel.confirmUndo; text: "Stay"; rank: "ghost"; onActivated: panel.confirmUndo = false }
        IndBtn { text: "Go back"; rank: panel.confirmUndo ? "danger" : "secondary"
            onActivated: panel.confirmUndo ? panel.begin("undo") : (panel.confirmUndo = true) }
    }
}
