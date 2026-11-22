// What needs you, from sea-attention.py. Lives at the top of Settings rather than on its page so
// the sidebar can show a count, and so a serious problem can notify with Settings closed.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: a
    visible: false
    readonly property string script: Qt.resolvedUrl("sea-attention.py").toString().replace("file://", "")
    readonly property string dir: script.substring(0, script.lastIndexOf("/"))
    property var rows: []
    property bool loaded: false
    readonly property bool busy: listProc.running
    // "When convenient" rows don't earn a badge; a number that never clears gets ignored.
    readonly property int urgentCount: rows.filter(function (r) { return r.level !== "info" }).length
    property var _next: []

    function refresh() { if (!listProc.running) { a._next = []; listProc.running = true } }
    function dismiss(id) {
        Quickshell.execDetached(["python3", script, "dismiss", id]);
        rows = rows.filter(function (r) { return r.id !== id });
    }
    function perform(row) {
        if (row.run === "fans") runProc.command = ["pkexec", "sh", dir + "/sea-fan-setup.sh"];
        else if (row.run === "backup") runProc.command = ["sh", dir + "/sea-backup.sh", "create"];
        else return;
        runProc.running = true;
    }
    Process { id: listProc; command: ["python3", a.script]
        stdout: SplitParser { onRead: data => { try { a._next.push(JSON.parse(data)) } catch (e) {} } }
        onExited: { a.rows = a._next; a.loaded = true } }
    Process { id: runProc; onExited: a.refresh() }
    Process { id: notifyProc; command: ["python3", a.script, "notify"]; onExited: a.refresh() }
    // A minute in, so it isn't part of startup, then a few times a day.
    Timer { interval: 60000; running: true; onTriggered: notifyProc.running = true }
    Timer { interval: 6 * 3600 * 1000; running: true; repeat: true; onTriggered: notifyProc.running = true }
}
