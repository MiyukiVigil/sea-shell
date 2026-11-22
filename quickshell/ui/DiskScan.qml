// The Disks page's slow half: drive health, what could be cleared, what is using the space.
// sea-disk.py does the work and decides what may be deleted; this holds the answers and what is
// ticked. It lives in its own file so a page of 9,000 lines isn't what reloads when it changes.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: s
    visible: false
    // True while the page is on screen: temperature keeps moving, nothing else needs to.
    property bool active: false
    readonly property string script: Qt.resolvedUrl("sea-disk.py").toString().replace("file://", "")
    readonly property string home: Quickshell.env("HOME") || "/"

    property var info: ({ drives: {}, fs: {} })
    property var items: []
    property var files: []
    property var folder: ({ path: "", rows: [], totalSize: "" })
    property var selected: ({})
    property var rowState: ({})      // id -> { state, note } for the last clean
    property bool scanned: false
    property string summary: ""
    property string fileNote: ""
    signal cleaned()

    readonly property bool scanning: scanProc.running
    readonly property bool cleaning: cleanProc.running
    readonly property bool folderBusy: duProc.running || (scanning && !folder.path)

    // ---------- what the page reads ----------
    readonly property var chosen: items.filter(function (i) { return s.selected[i.id] && !i.busy })
    readonly property real chosenBytes: chosen.reduce(function (n, i) { return n + i.bytes }, 0)
    readonly property bool chosenNeedsAdmin: chosen.some(function (i) { return i.admin })
    readonly property bool chosenHasTrash: chosen.some(function (i) { return i.id === "trash" })
    readonly property real clearableBytes: items.reduce(function (n, i) { return n + (i.busy ? 0 : i.bytes) }, 0)
    readonly property int clearableCount: items.filter(function (i) { return !i.busy }).length

    function human(n) {
        var units = ["B", "KB", "MB", "GB", "TB"], u = 0;
        n = Math.max(0, n);
        while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
        return (u < 2 || n >= 100 ? Math.round(n) : n.toFixed(1)) + " " + units[u];
    }
    function tierItems(tier) { return items.filter(function (i) { return i.tier === tier }) }
    function fsNote(dev) { return info.fs[dev] || "" }

    // Figures worth a glance for one drive, leaving out whatever it doesn't report. Plain words:
    // "percent_used" means nothing to anyone, and neither does a Kelvin reading.
    function healthRows(dev) {
        var h = info.drives[dev];
        if (!h) return [];
        var rows = [];
        var words = { good: ["Good", "ok"], warn: ["Check soon", "warn"], bad: ["Back up now", "crit"] };
        if (words[h.status]) rows.push({ label: "Health", value: words[h.status][0], tone: words[h.status][1] });
        if (h.temp !== undefined)
            rows.push({ label: "Temperature", value: h.temp + "°C",
                        tone: h.temp >= 80 ? "crit" : h.temp >= 70 ? "warn" : "neutral" });
        if (h.wear !== undefined)
            rows.push({ label: "Life used", value: h.wear + "%",
                        tone: h.wear >= 90 ? "crit" : h.wear >= 75 ? "warn" : "neutral" });
        if (h.written) rows.push({ label: "Total written", value: h.written, tone: "neutral" });
        if (h.read) rows.push({ label: "Total read", value: h.read, tone: "neutral" });
        if (h.hours) rows.push({ label: "Powered on", value: Number(h.hours).toLocaleString(Qt.locale("C"), "f", 0) + " h", tone: "neutral" });
        if (h.bootWritten) rows.push({ label: "Written since boot", value: h.bootWritten, tone: "neutral" });
        if (h.unsafe) rows.push({ label: "Sudden power-offs", value: "" + h.unsafe, tone: "neutral" });
        if (h.errors) rows.push({ label: "Data errors", value: "" + h.errors, tone: "crit" });
        return rows;
    }

    // ---------- actions ----------
    function toggle(id) {
        var next = Object.assign({}, selected);
        next[id] = !next[id];
        selected = next;
    }
    function open() {
        infoProc.running = true;
        if (!scanned) rescan();
    }
    function rescan() {
        if (scanProc.running) return;
        s._items = []; s._files = []; s._folder = null;
        scanProc.running = true;
    }
    function clean() {
        if (cleanProc.running || chosen.length === 0) return;
        rowState = {};
        summary = "";
        s._freed = "";
        cleanProc.command = ["python3", script, "clean"].concat(chosen.map(function (i) { return i.id }));
        cleanProc.running = true;
    }
    function openFolder(path) {
        if (duProc.running) return;
        duProc.command = ["python3", script, "du", path];
        duProc.running = true;
    }
    function trash(file) {
        if (trashProc.running) return;
        fileNote = "";
        s._trashing = file;
        trashProc.command = ["python3", script, "trash", file.path];
        trashProc.running = true;
    }
    function showInFiles(path) {
        Quickshell.execDetached(["xdg-open", path.substring(0, path.lastIndexOf("/")) || "/"]);
    }

    // ---------- scan: the first one fills in as it goes, later ones swap in whole, so clearing
    // something doesn't blank the list for three seconds ----------
    property var _items: []
    property var _files: []
    property var _folder: null
    property string _freed: ""
    property var _trashing: null

    function _publish() {
        var next = Object.assign({}, selected);
        // Size order within a tier: the point of the list is the biggest win. Ticks survive a
        // rescan; a new row starts ticked only if clearing it costs nothing you'd notice.
        _items.sort(function (a, b) { return b.bytes - a.bytes });
        for (var i = 0; i < _items.length; i++) {
            var it = _items[i];
            if (next[it.id] === undefined) next[it.id] = it.tier === "safe" && !it.busy;
        }
        selected = next;
        items = _items.slice();
        files = _files.slice();
        // A folder you've walked into stays on screen; only the top level is replaced under you.
        if (_folder && (!folder.path || folder.path === _folder.path)) folder = _folder;
    }
    function _scanLine(line) {
        var r;
        try { r = JSON.parse(line) } catch (e) { return }
        if (r.kind === "item") _items.push(r);
        else if (r.kind === "file") _files.push(r);
        else if (r.kind === "folder") _folder = r;
        if (!scanned || r.kind === "done") _publish();
    }
    function _cleanLine(line) {
        var r;
        try { r = JSON.parse(line) } catch (e) { return }
        if (r.kind === "progress") {
            var next = Object.assign({}, rowState);
            next[r.id] = { state: r.state, note: r.note };
            rowState = next;
        } else if (r.kind === "result") {
            s._freed = r.size;
            s._freedBytes = r.freed;
        }
    }
    property real _freedBytes: 0
    function _cleanSummary() {
        var left = 0;
        for (var id in rowState) if (rowState[id].state !== "done") left++;
        var head = _freedBytes >= 1048576 ? "Freed about " + _freed + "."
                 : "Cleared, but the drive doesn't report more free space yet.";
        return head + (left ? " " + left + (left === 1 ? " item" : " items") + " couldn't be finished, see the list." : "");
    }

    Process { id: infoProc; command: ["python3", s.script, "info"]
        stdout: StdioCollector { onStreamFinished: { try { s.info = JSON.parse(text) } catch (e) {} } } }
    Timer { interval: 30000; repeat: true; running: s.active; onTriggered: infoProc.running = true }
    Process { id: scanProc; command: ["python3", s.script, "scan"]
        stdout: SplitParser { onRead: data => s._scanLine(data) }
        onExited: {
            s._publish();
            s.scanned = true;
            // Whatever just changed may be inside the folder you're looking at.
            if (s.folder.path && s._folder && s.folder.path !== s._folder.path) s.openFolder(s.folder.path);
        } }
    Process { id: cleanProc
        stdout: SplitParser { onRead: data => s._cleanLine(data) }
        onExited: { s.summary = s._freed !== "" ? s._cleanSummary() : "The clean-up stopped before it finished."
                    s.rescan(); s.cleaned() } }
    Process { id: duProc
        stdout: StdioCollector { onStreamFinished: { try { s.folder = JSON.parse(text) } catch (e) {} } } }
    Process { id: trashProc
        stdout: StdioCollector { onStreamFinished: {
            var r;
            try { r = JSON.parse(text) } catch (e) { r = { ok: false, note: "Couldn't move it to the Trash." } }
            s.fileNote = r.ok ? "Moved " + s._trashing.name + " to the Trash. Empty the Trash above to get the space back."
                              : r.note;
            if (r.ok) s.rescan();
        } } }
}
