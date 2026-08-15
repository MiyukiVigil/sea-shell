// ─────────────────────────────────────────────────────────────────────────────
// sea-shell — Moondrop DAC control panel
//
// Instantiated by shell.qml. Talks to scripts/system/moondrop_control.py (the
// reverse-engineered controller) over its --json / --set-* CLI. Parametric EQ
// with a live frequency-response graph (region-labelled), an all-bands column
// editor, pre-gain / global-offset, preset selection, an in-panel tuning guide,
// and save-to-flash.
//
// Everything device-shaped comes from --json rather than being assumed here:
// band count, which slot custom PEQ lives on, and whether the device supports
// pre-gain at all. The script is the single source of truth for the device
// registry — don't re-hardcode it.
//
// This panel does NOT try to tell you whether the EQ is switched on. On a DAWN
// PRO2 that is a hardware toggle (both volume buttons at once), and it is not
// reflected in any register the DAC exposes — every readable sub-command reads
// identical in both modes. The active EQ profile is NOT a proxy for it either:
// firmware 1.5 reports profile 9 whether the EQ is on or off, while band writes
// are audible in custom-EQ mode regardless. The official app assumes otherwise
// (isInPEQMode: readEQIndex() === peqIndex) and is simply wrong on this firmware.
//
// Toggle:  qs -c sea-shell ipc call dac toggle   (SUPER+SHIFT+E)
// ─────────────────────────────────────────────────────────────────────────────
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel

Scope {
    id: root

    // the shell flattens scripts next to the QML on deploy, so resolve it as a sibling
    readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    // Two scripts, two jobs, deliberately no overlap. moondrop_control.py is the DAC:
    // USB HID, its DSP, the community library — and it knows nothing about pipewire.
    // sea-eq.py is the software EQ: pipewire only, no Moondrop anything. This panel is
    // the one place they meet, which is what keeps either usable without the other.
    readonly property string pyScript: root.scriptDir + "/moondrop_control.py"
    readonly property string swScript: root.scriptDir + "/sea-eq.py"

    // ---- lifecycle ----
    property bool shown: false
    property bool helpOpen: false
    property bool graphReadout: false     // editor view vs the official-style readout
    function open()   { apReadProc.running = true;   // pick up appearance changes made while closed
                        root.shown = true; root.dirty = false; root.pristine = null; root.refresh() }
    function close()  { root.shown = false; root.helpOpen = false; root.hubOpen = false }
    function toggle() { if (root.shown) root.close(); else root.open() }
    IpcHandler {
        target: "dac"
        function toggle(): void { root.toggle() }
        function open(): void   { root.open() }
        function close(): void  { root.close() }
    }

    // ---- which EQ are we driving? ----
    //
    // Two backends, same bands, same maths, same panel. A supported Moondrop DAC runs
    // the filters on its own DSP chip; without one they run in software as a PipeWire
    // filter-chain, which works on anything — laptop speakers, a rival brand's DAC,
    // bluetooth. Auto picks the DAC when it's there, because that's the one that keeps
    // working after you close the shell.
    //
    // The override earns its place: software has no Q2.30 limit and isn't pinned to
    // 96 kHz, so the shelf gains the DAC has to refuse (see §4.1) work there. Wanting
    // software while a DAC is plugged in is a real thing to want.
    property string backendPref: "auto"     // auto | hw | sw
    readonly property bool hwPresent: root.dev.ok === true
    readonly property bool sw: root.backendPref === "sw" || (root.backendPref === "auto" && !root.hwPresent)
    // Is there anything to edit? On hardware that means a DAC answered; in software
    // it's always true — the sink doesn't have to exist yet, applying creates it.
    readonly property bool ready: root.sw || root.dev.ok
    property var  swInfo: ({ installed: false, running: false, sink_present: false })
    // Software edits are apply-based: pipewire 1.6 accepts and then ignores per-control
    // param writes, so a band change means re-rendering the graph. See the note above
    // sw_apply() in the script.
    property bool swDirty: false
    property bool swBusy: false
    property bool swConfirm: false          // first-time "create the virtual output?" gate

    // ---- device state (all of it read from the script; nothing assumed) ----
    property var  dev: ({ ok: false })
    property var  bands: []          // [{index,type,frequency,gain,q}]
    property real pregain: 0
    property real globalGain: 0
    property int  profile: 0
    property int  sel: 0             // selected band index
    property bool dirty: false       // unsaved live edits pending a flash write
    property int  bandCount: 8       // device band count (--json "bands")
    property int  peqIndex: 7        // slot custom PEQ lives on; 4 on E.S. combo
    property bool supportsPregain: true
    property string lastError: ""    // last refusal from the script, shown as a toast

    // The DAC's state as last known *saved*: the first read of a session, and again
    // after each save-to-flash. Edits go to the DSP live (--no-flash), and a re-read
    // reports what we just wrote — the DSP has no way to tell us what flash still
    // holds. So re-reading can never undo an edit; only this snapshot can.
    property var pristine: null
    function snapshot() {
        root.pristine = { bands: JSON.parse(JSON.stringify(root.bands)),
                          pregain: root.pregain, globalGain: root.globalGain };
    }
    function revert() {
        if (!root.pristine) return;
        root.bands = JSON.parse(JSON.stringify(root.pristine.bands));
        root.pregain = root.pristine.pregain;
        root.globalGain = root.pristine.globalGain;
        for (var i = 0; i < root.bands.length; i++) root.applyBand(i);
        if (root.supportsPregain) root.applyPregain();
        root.applyGlobal();
        root.dirty = false;   // applyBand set it true; we're back at the saved state
    }

    Process { id: jsonProc; command: ["python3", root.pyScript, "--json"]
        stdout: StdioCollector { id: jsonOut; onStreamFinished: {
            try {
                var d = JSON.parse(jsonOut.text.trim() || "{}");
                root.dev = d;
                if (d.ok) {
                    root.bands = d.filters || [];
                    root.reorder();
                    root.pregain = d.pregain || 0;
                    root.globalGain = d.global_gain || 0;
                    root.profile = d.active_eq_profile || 0;
                    // tolerate an older script that predates these fields
                    root.bandCount = d.bands || (d.filters ? d.filters.length : 8);
                    root.peqIndex = d.peq_index !== undefined ? d.peq_index : 7;
                    root.supportsPregain = d.supports_pregain !== undefined ? d.supports_pregain : true;
                    if (root.sel >= root.bands.length) root.sel = 0;
                    // Deliberately NOT clearing dirty here: a reload tells us what the
                    // DSP is playing, which says nothing about whether flash matches it.
                    if (root.pristine === null) root.snapshot();
                }
            } catch(e) { root.dev = { ok: false, error: "parse error: " + e }; }
            // --json also answers "is a DAC here at all", which is what picks the
            // backend. If the answer is no (or you asked for software anyway), the
            // bands come from the filter-chain's state instead.
            if (root.sw) swStatusProc.running = true;
            root._finishRefresh();
        } } }

    // ---- software EQ ----
    // Deliberately off the device queue below: nothing here opens a hidraw, and the
    // queue exists purely to stop two processes sharing one.
    Process {
        id: swStatusProc
        command: ["python3", root.swScript, "--status"]
        stdout: StdioCollector { id: swOut; onStreamFinished: {
            try {
                var j = JSON.parse(swOut.text.trim() || "{}");
                root.swInfo = j;
                // Only adopt the stored bands when we have nothing pending; otherwise a
                // status poll would quietly throw away edits you haven't applied.
                if (!root.swDirty) {
                    var fs = j.filters || [];
                    var arr = [];
                    for (var i = 0; i < root.bandCount; i++) {
                        var b = null;
                        for (var k = 0; k < fs.length; k++) if (fs[k].index === i) b = fs[k];
                        arr.push(b ? { index: i, type: b.type, frequency: b.frequency, gain: b.gain, q: b.q }
                                   : { index: i, type: "disabled", frequency: 1000, gain: 0, q: 1.0 });
                    }
                    root.bands = arr;
                    root.reorder();
                    root.pregain = j.pregain || 0;
                    root.globalGain = 0;          // software has no device volume offset
                    if (root.pristine === null) root.snapshot();
                }
            } catch (e) { /* leave the panel on its defaults */ }
        } } }

    // Gated entry: the first apply has to create the virtual output, which writes a
    // pipewire config and starts a service — so ask once rather than doing it behind
    // your back. swCommit is the ungated one the dialog calls; keeping them separate
    // matters, since a single function that both raises the prompt and is called BY it
    // just re-raises the prompt forever.
    function swApply() {
        if (root.swBusy) return;
        if (!root.swInfo.installed) { root.swConfirm = true; return }
        root.swCommit();
    }
    function swCommit() {
        if (root.swBusy) return;
        root.swConfirm = false;
        root.swBusy = true;
        // argv, not a shell string: band values are ours, but the label isn't always.
        var payload = JSON.stringify({ pregain: root.pregain, filters: root.bands });
        swWriteProc.command = ["python3", "-c",
            "import sys,os,pathlib,subprocess;"
            + "p=pathlib.Path(os.path.expanduser('~/.cache/sea-shell'));p.mkdir(parents=True,exist_ok=True);"
            + "f=p/'panel-eq.json';f.write_text(sys.argv[2]);"
            + "sys.exit(subprocess.run([sys.executable,sys.argv[1],'--apply','--from-json',str(f),"
            + "'--name',sys.argv[3]]).returncode)",
            root.swScript, payload, root.swLabel];
        swWriteProc.running = true;
    }
    property string swLabel: "sea-shell panel"
    Process {
        id: swWriteProc
        stdout: StdioCollector { id: swWOut; onStreamFinished: {
            root.swBusy = false;
            try {
                var j = JSON.parse(swWOut.text.trim() || "{}");
                if (j.ok) { root.swDirty = false; root.dirty = false; root.snapshot(); }
                else { root.lastError = j.error || "could not apply the software EQ"; errTimer.restart(); }
            } catch (e) { root.lastError = "could not apply the software EQ"; errTimer.restart(); }
            swStatusProc.running = true;
        } }
        stderr: StdioCollector { id: swWErr; onStreamFinished: {
            if (swWErr.text.trim() !== "") { root.lastError = swWErr.text.trim().split("\n").pop(); errTimer.restart(); }
        } } }
    function swRemove() {
        root.swBusy = true;
        swRmProc.running = true;
    }
    Process {
        id: swRmProc
        command: ["python3", root.swScript, "--remove"]
        stdout: StdioCollector { onStreamFinished: { root.swBusy = false; root.swDirty = false; swStatusProc.running = true } } }

    // ---- device access queue ----
    // EVERY call to the script goes through here, reads included. Two processes must
    // never touch the DAC at once: they share one hidraw and one reply queue, so
    // concurrent commands can pick up each other's answers. The refresh used to be
    // fired straight from _done() while _pump() started the next write in the same
    // breath — exactly that race.
    //
    // Writes also can't be fire-and-forget: the script refuses a filter it can't
    // represent, so we read stdout back and resync the graph when that happens.
    property var  _queue: []
    property bool _busy: false

    function refresh() { root._queue.push({ refresh: true }); root._pump() }
    function run(argv, reload) {
        root._queue.push({ argv: argv });
        if (reload) root._queue.push({ refresh: true });
        root._pump();
    }
    function _pump() {
        if (root._busy || root._queue.length === 0) return;
        root._busy = true;
        var job = root._queue[0];
        if (job.refresh) { jsonProc.running = true; return; }   // _finishRefresh steps the queue
        wProc.command = ["python3", root.pyScript].concat(job.argv);
        wProc.running = true;
    }
    function _finishRefresh() {
        if (root._queue.length > 0 && root._queue[0].refresh) {
            root._queue.shift();
            root._busy = false;
        }
        root._pump();
    }
    // The script reports refusals as "Error: ..." on stdout and exits 1; a traceback
    // would land on stderr. Keyed off output rather than exit code so it doesn't
    // depend on exited/streamFinished ordering. stdout owns the queue step; stderr
    // only ever adds an error, so an empty one can't advance or stall the queue.
    function _done(out) {
        root._queue.shift();
        root._busy = false;
        var m = ("" + out).match(/^Error:\s*([\s\S]+)$/m);
        if (m) {
            root.lastError = m[1].trim();
            errTimer.restart();
            root.exported = "";   // an export in flight didn't land; don't claim it did
            // Anything still queued was built on a write that didn't land — drop it
            // and go ask the DAC what it actually holds.
            root._queue = [];
            root.refresh();
            return;
        }
        root._pump();
    }
    Process {
        id: wProc
        stdout: StdioCollector { id: wOut; onStreamFinished: root._done(wOut.text) }
        stderr: StdioCollector { id: wErr; onStreamFinished: {
            if (wErr.text.trim() !== "") { root.lastError = wErr.text.trim().split("\n").pop(); errTimer.restart(); } } }
    }
    Timer { id: errTimer; interval: 9000; onTriggered: root.lastError = "" }

    // ---- community preset browser (Moondrop Hub library) ----
    //
    // The official web app carries a public library of user-made curves. Reading it
    // needs no account, so this browses and applies; it never publishes, likes or
    // favourites (all of which would need a login this tool doesn't implement).
    //
    // Deliberately NOT on the device queue below. Both --presets and --preset are
    // network-only and provably open zero hidraw handles, so they must not wait
    // behind a band write — and can't corrupt one by racing it. Only *applying* a
    // preset touches the DAC, and that goes through applyPreset -> applyBand -> run.
    property bool   hubOpen: false
    property var    hubList: []
    property string hubQuery: ""
    property string hubState: "idle"      // idle | loading | ok | error
    property string hubError: ""
    property int    hubTotal: 0
    property string hubBusy: ""           // uuid of the preset currently being applied

    // ---- preview ----
    // Clicking a row draws its curve; only the apply button touches the DAC. 59,700
    // strangers' curves is a lot to audition one flash-write at a time, and a title
    // like "三角洲" tells you nothing about what it does to 3 kHz.
    property string hubSel: ""            // uuid being previewed
    property string hubSelTitle: ""
    property var    hubPreview: []        // bands, or [] while loading
    property var    hubCache: ({})        // uuid -> bands, so re-clicking is instant
    property bool   hubPreLoading: false
    property bool   hubPreShowPre: true   // draw the level with pre-gain paid for

    // How far the previewed curve would clip at the pre-gain currently set. Same
    // maths as root.overshoot, but for a curve we haven't applied — the whole point
    // of a preview is to find that out before writing it.
    readonly property real hubPreOvershoot: {
        var bs = root.hubPreview;
        if (!bs || bs.length === 0) return 0;
        var pk = 0;
        for (var n = 0; n <= 120; n++) {
            var f = Math.pow(10, root.l0 + (n / 120) * (root.l1 - root.l0));
            var s = 0;
            for (var i = 0; i < bs.length; i++) s += root.bandDb(bs[i], f);
            if (s > pk) pk = s;
        }
        return pk + root.pregain;
    }

    function hubShow(p) {
        root.hubSel = p.uuid;
        root.hubSelTitle = p.title;
        if (root.hubCache[p.uuid]) { root.hubPreview = root.hubCache[p.uuid]; return }
        root.hubPreview = [];
        root.hubPreLoading = true;
        hubPreProc.command = ["python3", root.pyScript, "--preset", p.uuid];
        hubPreProc.running = true;
    }
    Process {
        id: hubPreProc
        stdout: StdioCollector { id: hubPreOut; onStreamFinished: {
            root.hubPreLoading = false;
            try {
                var j = JSON.parse(hubPreOut.text.trim() || "{}");
                if (!j.ok) return;
                var c = root.hubCache; c[root.hubSel] = j.bands || [];
                root.hubCache = c;
                root.hubPreview = j.bands || [];
            } catch (e) { /* leave the chart empty rather than draw a lie */ }
        } } }

    // The script wants the pid as hex; --json reports it as an int.
    readonly property string devPidHex: (root.dev.ok && root.dev.product_id !== undefined)
        ? ("0000" + root.dev.product_id.toString(16)).slice(-4) : ""

    // Which library to browse. With a DAC it's that DAC's family. Without one there is
    // no device to key off, so fall back to the DAWN PRO2's group — the biggest pool
    // (~6,900) — because in software the device a curve was filed under is irrelevant:
    // a preset is bands, and what it's actually FOR is the headphone in its title.
    readonly property string hubPid: root.devPidHex !== "" ? root.devPidHex : "011d"
    readonly property bool hubFallback: root.devPidHex === ""

    function hubBrowse() {
        root.hubState = "loading";
        hubProc.command = ["python3", root.pyScript, "--presets", "--pid", root.hubPid, "--limit", "200"]
            .concat(root.hubQuery.trim() !== "" ? ["--search", root.hubQuery.trim()] : []);
        hubProc.running = true;
    }
    // Search runs in the script, not here, so it covers the whole library (~6900 for a
    // DAWN PRO2) rather than only the 200 rows we're showing. That costs a process per
    // query, hence the debounce; the index is cached on disk so a warm query is ~100ms.
    Timer { id: hubDebounce; interval: 300; onTriggered: root.hubBrowse() }
    onHubQueryChanged: if (root.hubOpen) hubDebounce.restart()

    Process {
        id: hubProc
        stdout: StdioCollector { id: hubOut; onStreamFinished: {
            try {
                var j = JSON.parse(hubOut.text.trim() || "{}");
                if (j.ok) {
                    root.hubList = j.presets || [];
                    root.hubTotal = j.total || 0;
                    root.hubState = "ok";
                } else {
                    root.hubError = j.error || "unknown error";
                    root.hubState = "error";
                }
            } catch (e) {
                root.hubError = "could not read the library";
                root.hubState = "error";
            }
        } }
        stderr: StdioCollector { id: hubErrOut; onStreamFinished: {
            if (hubErrOut.text.trim() !== "" && root.hubState === "loading") {
                root.hubError = hubErrOut.text.trim().split("\n").pop();
                root.hubState = "error";
            }
        } }
    }

    // Fetch one preset's curve, then hand it to the same applyPreset() the built-in
    // presets use — so a community curve fills every slot and disables the rest,
    // exactly like "Bass" or "V-shape" does.
    function hubApply(p) {
        root.hubBusy = p.uuid;
        hubGetProc.command = ["python3", root.pyScript, "--preset", p.uuid];
        hubGetProc.running = true;
    }
    Process {
        id: hubGetProc
        stdout: StdioCollector { id: hubGetOut; onStreamFinished: {
            root.hubBusy = "";
            try {
                var j = JSON.parse(hubGetOut.text.trim() || "{}");
                if (!j.ok) { root.lastError = j.error || "could not fetch that preset"; errTimer.restart(); return; }
                var bands = j.bands || [];
                // Community presets carry no pre-gain — the published file is bands and
                // nothing else. So leave pre-gain where the user put it rather than
                // inventing a value; the panel's own clipping readout and "match" button
                // already handle headroom, and they do it from the actual curve.
                root.applyPreset({ nm: "", pre: root.pregain,
                                   bands: bands.map(function (b) { return [b.type, b.frequency, b.gain, b.q] }) });
                if (j.dropped > 0)
                    root.lastError = "preset had " + (bands.length + j.dropped) + " bands; this device has "
                                   + root.bandCount + " — the last " + j.dropped + " were dropped";
                else if (j.coerced > 0)
                    root.lastError = j.coerced + " band(s) used a filter type this hardware has no register for; "
                                   + "written as peaking, same as the official app";
                if (j.dropped > 0 || j.coerced > 0) errTimer.restart();
                root.hubOpen = false;
            } catch (e) {
                root.lastError = "could not read that preset";
                errTimer.restart();
            }
        } }
    }

    // ---- in-panel file browser (import / export) ----
    // Deliberately NOT an external dialog. This panel is a layer-shell Overlay with
    // exclusive keyboard focus, so zenity/portal windows open *underneath* it and
    // can never take focus — the dialog is there, just unreachable. Browsing has to
    // happen inside the panel.
    property bool   fileOpen: false
    property string fileMode: "import"            // "import" | "export"
    property string homeDir: ""
    property string fileDir: ""                   // folder currently listed
    property string exportName: "moondrop-eq.json"
    property string exportFmt: "json"             // "json" (backup) | "pipewire" (software EQ)

    Process { running: true; command: ["sh", "-c", "printf %s \"$HOME\""]
        stdout: StdioCollector { id: homeOut; onStreamFinished: {
            root.homeDir = homeOut.text.trim();
            if (root.fileDir === "") root.fileDir = root.homeDir;
        } } }

    function browse(mode) {
        root.fileMode = mode;
        if (root.fileDir === "") root.fileDir = root.homeDir;
        root.fileOpen = true;
    }
    function goUp() {
        var p = root.fileDir.replace(/\/+$/, "");
        var i = p.lastIndexOf("/");
        root.fileDir = i > 0 ? p.substring(0, i) : "/";
    }
    function importFile(path) {
        // Live, not flashed: audition it first, then hit save to keep it.
        var flag = /\.json$/i.test(path) ? "--import-json" : "--import-rew";
        root.run(["--no-flash", flag, path], true);
        root.dirty = true;
        root.fileOpen = false;
    }
    function doExport() {
        var nm = root.exportName.trim();
        if (nm === "") return;
        // Keep the extension honest so the file says what it is.
        if (root.exportFmt === "pipewire" && !/\.conf$/i.test(nm)) nm += ".conf";
        if (root.exportFmt === "json" && !/\.json$/i.test(nm)) nm += ".json";
        var path = root.fileDir.replace(/\/+$/, "") + "/" + nm;
        if (root.exportFmt === "pipewire") {
            // Software EQ, so sea-eq.py's job, not the DAC script's — and off the
            // device queue entirely: rendering a config file has no business waiting
            // behind a band write, or joining a queue that exists to protect a hidraw.
            // The bands are already in memory; hand them over rather than round-tripping
            // through the device.
            var payload = JSON.stringify({ pregain: root.pregain, filters: root.bands });
            pwExportProc.command = ["python3", "-c",
                "import sys,os,pathlib,subprocess;"
                + "p=pathlib.Path(os.path.expanduser('~/.cache/sea-shell'));p.mkdir(parents=True,exist_ok=True);"
                + "f=p/'export-eq.json';f.write_text(sys.argv[2]);"
                + "sys.exit(subprocess.run([sys.executable,sys.argv[1],'--render',sys.argv[3],"
                + "'--from-json',str(f)]).returncode)",
                root.swScript, payload, path];
            pwExportProc.running = true;
        } else {
            root.run(["--export-json", path]);
        }
        root.exported = path;
        expTimer.restart();
        root.fileOpen = false;
    }
    Process {
        id: pwExportProc
        stdout: StdioCollector { id: pwExpOut; onStreamFinished: {
            try {
                var j = JSON.parse(pwExpOut.text.trim() || "{}");
                if (!j.ok) { root.lastError = j.error || "could not write that config"; errTimer.restart(); root.exported = "" }
            } catch (e) { root.lastError = "could not write that config"; errTimer.restart(); root.exported = "" }
        } } }
    property string exported: ""
    Timer { id: expTimer; interval: 6000; onTriggered: root.exported = "" }

    // On hardware every edit goes straight to the DSP and you hear it; the flash write
    // is the deliberate part. In software nothing is audible until apply, because a
    // band change means re-rendering the whole graph — so an edit only marks itself.
    function applyBand(i) {
        var b = root.bands[i]; if (!b) return;
        if (root.sw) { root.swDirty = true; root.dirty = true; return }
        root.run(["--no-flash", "--set-peq", "" + b.index, "" + b.type,
                  "" + Math.round(b.frequency), b.gain.toFixed(2), b.q.toFixed(3)]);
        root.dirty = true;
    }
    function applyPregain()  {
        if (root.sw) { root.swDirty = true; root.dirty = true; return }
        root.run(["--no-flash", "--set-pregain", root.pregain.toFixed(2)]); root.dirty = true;
    }
    function applyGlobal()   {
        if (root.sw) return;              // no device volume offset in software
        root.run(["--no-flash", "--set-globalgain", root.globalGain.toFixed(2)]); root.dirty = true;
    }
    function applyProfile()  {
        if (root.sw) return;              // profile slots are a DAC concept
        root.run(["--no-flash", "--set-eq-index", "" + root.profile], true); root.dirty = true;
    }
    // Hardware: what's live becomes what's in flash. Software: render and reload.
    // Same button, same meaning — commit what you've been editing.
    function saveFlash() {
        if (root.sw) { root.swApply(); return }
        root.run(["--save-flash"]); root.dirty = false; root.snapshot();
    }

    // Largest Q a shelf can take at this gain. RBJ's shelf formulas read Q as slope,
    // and past this there's no real filter — the python raises ShelfSlopeError and the
    // graph maths would go NaN. Mirrors max_shelf_q() in the script; the 0.995 keeps
    // float drift between the two from landing us a hair over its limit.
    readonly property real qMax: 10
    function qCeiling(type, gain) {
        if (type !== "low_shelf" && type !== "high_shelf") return root.qMax;
        var a = Math.pow(10, Math.abs(gain) / 40), s = a + 1/a;
        if (s <= 2) return root.qMax;
        return Math.min(root.qMax, 1 / (1 - 2/s) * 0.995);
    }

    // ---- Q2.30 coefficient headroom ----------------------------------------
    // The firmware stores coefficients as Q2.30, which only spans [-2, 2). Some
    // perfectly reasonable-looking filters need coefficients outside that, and the
    // script refuses those writes outright. Rather than let a drag sail past the
    // limit and bounce back as a refusal toast, work out the ceiling here and stop
    // the control at it — the same way Q is already clamped to qCeiling.
    //
    // Mirrors pack_coefficients() in the script: it packs [b0,b1,b2,-a1,-a2] and
    // every one of those must land inside int32 once scaled by 2^30.
    readonly property real q30Scale: 1073741824
    function fits(type, f0, gain, Q) {
        var c = root.coeffs(f0, gain, Q, type);
        if (!c) return true;                       // disabled → flat → always fine
        var v = [c.b[0], c.b[1], c.b[2], -c.a[1], -c.a[2]];
        for (var i = 0; i < 5; i++) {
            if (!isFinite(v[i])) return false;
            if (Math.abs(Math.round(v[i] * root.q30Scale)) > 2147483647) return false;
        }
        return true;
    }
    // Largest |gain| in this sign direction whose coefficients still fit. Bisection,
    // mirroring max_safe_gain() in the script. Returns 0 when nothing fits (a high
    // shelf below ~200 Hz overflows at ANY gain — b1 is already past -2 at +0.05 dB).
    function gainCeiling(type, f0, Q, sign) {
        if (root.fits(type, f0, sign * root.dbMax, Q)) return root.dbMax;
        var lo = 0, hi = root.dbMax;
        for (var n = 0; n < 24; n++) {
            var mid = (lo + hi) / 2;
            if (root.fits(type, f0, sign * mid, Q)) lo = mid; else hi = mid;
        }
        return lo;
    }

    // Is this band pinned against the coefficient ceiling? (nudging it further in the
    // same direction would overflow) — drives the "limit" tag on the column.
    function atCeiling(b) {
        if (!b || b.type === "disabled") return false;
        var sign = b.gain >= 0 ? 1 : -1;
        return !root.fits(b.type, b.frequency, b.gain + sign * 0.15, b.q);
    }

    // immutably patch a band so bindings/repaint fire, then optionally push to the device
    function setBand(i, patch, write) {
        var arr = root.bands.slice();
        var nb = {}; for (var k in arr[i]) nb[k] = arr[i][k];
        for (var p in patch) nb[p] = patch[p];
        // Clamp here rather than at each caller: raising gain can invalidate a Q that
        // was fine a moment ago, so type/gain/Q edits all have to re-check.
        var ceil = root.qCeiling(nb.type, nb.gain);
        if (nb.q > ceil) nb.q = Math.round(ceil * 1000) / 1000;
        // Then the coefficient-range ceiling, which depends on type/freq/Q together.
        if (nb.type !== "disabled" && !root.fits(nb.type, nb.frequency, nb.gain, nb.q)) {
            var sign = nb.gain >= 0 ? 1 : -1;
            var gc = root.gainCeiling(nb.type, nb.frequency, nb.q, sign);
            nb.gain = Math.round(sign * gc * 10) / 10;
            // Bisection can land a hair over the limit; walk it back until it fits.
            for (var g = 0; g < 8 && !root.fits(nb.type, nb.frequency, nb.gain, nb.q); g++)
                nb.gain = Math.round((nb.gain - sign * 0.1) * 10) / 10;
        }
        arr[i] = nb; root.bands = arr;
        if (write) root.applyBand(i);
    }
    // ---- column order ----------------------------------------------------------
    // The columns carry region tags (SUB → AIR), which promises a left-to-right sweep
    // up the spectrum. The DAC's slots are in whatever order they were written, so a
    // 1 kHz band can sit between 6 kHz and 14 kHz and break that promise. Sort for
    // display only; writes still go to the true slot, which each column labels.
    //
    // Deliberately NOT a binding on bands: re-sorting live would slide a column out
    // from under the cursor mid-drag. Recomputed on load and on preset apply, where
    // the layout is expected to change anyway.
    property var bandOrder: []
    function reorder() {
        var bs = root.bands, idx = [];
        for (var i = 0; i < bs.length; i++) idx.push(i);
        idx.sort(function(a, b) {
            var A = bs[a], B = bs[b];
            var ad = A.type === "disabled", bd = B.type === "disabled";
            if (ad !== bd) return ad ? 1 : -1;               // unused bands park on the right
            if (A.frequency !== B.frequency) return A.frequency - B.frequency;
            return a - b;                                     // stable for equal frequencies
        });
        root.bandOrder = idx;
    }
    function slotAt(col) { return root.bandOrder.length === root.bands.length ? root.bandOrder[col] : col }

    // ---- starting-point curves -------------------------------------------------
    // Not the DAC's built-in preset slots (that's the hardware "slot" number) — these
    // just fill the bands with a known-good shape you can then tweak.
    //
    // Every band here was checked against the script's own packer: all fit inside the
    // firmware's Q2.30 coefficient range with headroom, so none get clamped on apply.
    // The tight ones are the high shelves (V-shape +3 vs a +4.65 ceiling at 8 kHz,
    // Air +4 vs +5.36 at 9 kHz) — if you retune these, re-check them.
    //
    // pre is pre-gain: roughly minus the biggest boost, so boosts don't clip.
    readonly property var presets: [
        { nm: "Flat",     ic: "remove",          pre:  0.0, bands: [] },
        { nm: "Bass",     ic: "graphic_eq",      pre: -4.0, bands: [["low_shelf",100,4.0,0.7]] },
        { nm: "V-shape",  ic: "show_chart",      pre: -4.5, bands: [["low_shelf",90,4.0,0.7],["peaking",900,-2.0,1.0],["high_shelf",8000,3.0,0.7]] },
        { nm: "Vocals",   ic: "record_voice_over",pre: -3.5, bands: [["peaking",200,-3.0,1.2],["peaking",450,-2.0,1.0],["peaking",2600,3.0,1.2]] },
        { nm: "Warm",     ic: "local_fire_department", pre: -3.5, bands: [["low_shelf",220,3.0,0.7],["high_shelf",6000,-3.0,0.7]] },
        { nm: "Air",      ic: "air",             pre: -4.0, bands: [["high_shelf",9000,4.0,0.7],["peaking",5000,-1.5,2.0]] },
        { nm: "Podcast",  ic: "podcasts",        pre: -3.5, bands: [["high_pass",85,0.0,0.7],["peaking",300,-2.5,1.0],["peaking",3000,3.0,1.2]] },
        { nm: "Loudness", ic: "volume_up",       pre: -5.5, bands: [["low_shelf",80,5.0,0.7],["high_shelf",10000,3.5,0.7],["peaking",1500,-1.5,1.0]] }
    ]
    // Fill every slot: bands the preset doesn't define are explicitly disabled, so
    // applying one never leaves a stray filter from whatever was there before.
    function applyPreset(p) {
        var arr = [];
        for (var i = 0; i < root.bandCount; i++) {
            var s = p.bands[i];
            arr.push(s ? { index: i, type: s[0], frequency: s[1], gain: s[2], q: s[3] }
                       : { index: i, type: "disabled", frequency: 1000, gain: 0, q: 1.0 });
        }
        root.bands = arr;
        root.reorder();
        root.pregain = p.pre;
        for (var j = 0; j < arr.length; j++) root.applyBand(j);
        if (root.supportsPregain) root.applyPregain();
        root.dirty = true;
    }

    readonly property var filterTypes: ["peaking","low_shelf","high_shelf","low_pass","high_pass","disabled"]
    function typeAbbr(t) { return ({peaking:"PK", low_shelf:"LS", high_shelf:"HS", low_pass:"LP", high_pass:"HP", disabled:"—"})[t] || "PK" }
    function typeName(t) { return (t || "peaking").replace("_", " ") }
    function cycleType(i, dir) {
        var n = root.filterTypes.indexOf(root.bands[i].type); if (n < 0) n = 0;
        n = (n + dir + root.filterTypes.length) % root.filterTypes.length;
        root.setBand(i, { type: root.filterTypes[n] }, true);
    }
    function stepFreq(i, dir) {
        var f = root.bands[i].frequency * (dir > 0 ? 1.06 : 1/1.06);
        root.setBand(i, { frequency: Math.round(root.clamp(f, fMin, fMax)) }, true);
    }
    function fmtHz(f) { return f >= 1000 ? (f/1000).toFixed(f % 1000 === 0 ? 0 : 1) + "k" : ("" + Math.round(f)) }

    // ---- graph math (log-freq X, ±dbMax dB Y) ----
    readonly property real dbMax: 12
    readonly property real fMin: 20
    readonly property real fMax: 20000
    readonly property real l0: Math.log(fMin) / Math.LN10
    readonly property real l1: Math.log(fMax) / Math.LN10
    function xOfFreq(f, w) { return (Math.log(f)/Math.LN10 - l0) / (l1 - l0) * w }
    function freqOfX(x, w) { return Math.pow(10, l0 + Math.max(0, Math.min(1, x/w)) * (l1 - l0)) }
    function yOfDb(db, h)  { return h/2 - (db/dbMax) * (h/2) }
    function dbOfY(y, h)   { return (h/2 - y) / (h/2) * dbMax }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    // frequency regions — labels the graph and each band ("what tunes what")
    readonly property var regionDefs: [
        {n:"SUB",      f1:20,   f2:60,    c:"#6f8bd6"},
        {n:"BASS",     f1:60,   f2:250,   c:"#5a90d2"},
        {n:"LOW-MID",  f1:250,  f2:500,   c:"#4fa0c8"},
        {n:"MID",      f1:500,  f2:2000,  c:"#4fb8ac"},
        {n:"UPPER-MID",f1:2000, f2:4000,  c:"#5fc79a"},
        {n:"PRESENCE", f1:4000, f2:6000,  c:"#9fd48a"},
        {n:"AIR",      f1:6000, f2:20000, c:"#ccd98a"}
    ]
    function regionOf(f) {
        for (var i = 0; i < regionDefs.length; i++) if (f < regionDefs[i].f2 || i === regionDefs.length - 1) return regionDefs[i];
        return regionDefs[0];
    }

    // RBJ biquad → {b:[b0,b1,b2], a:[a0,a1,a2]} (a0 normalised to 1) — mirrors the python
    function coeffs(f0, gain, Q, type) {
        var w0 = 2 * Math.PI * f0 / 96000, cw = Math.cos(w0), sw = Math.sin(w0);
        if (type === "peaking") {
            var A = Math.sqrt(Math.pow(10, gain/20)), al = sw/(2*Q), a0 = al/A + 1;
            return { b: [(al*A+1)/a0, -2*cw/a0, (1-al*A)/a0], a: [1, -2*cw/a0, (1-al/A)/a0] };
        } else if (type === "low_shelf" || type === "high_shelf") {
            var amp = Math.pow(10, gain/40);
            // Same shelf-slope term as the python. Its radicand goes negative once Q is
            // too steep for the gain, and Math.sqrt would hand back NaN and erase the
            // curve rather than throw. setBand keeps Q under qCeiling so this shouldn't
            // trigger; floor it anyway for bands read off a DAC some other tool wrote.
            var alpha = sw/2 * Math.sqrt(Math.max(0, (amp + 1/amp) * (1/Q - 1) + 2));
            var tsa = 2 * Math.sqrt(amp) * alpha;
            if (type === "low_shelf") {
                var d0 = amp + 1 + (amp-1)*cw + tsa;
                return { b: [amp*(amp+1-(amp-1)*cw+tsa)/d0, 2*amp*(amp-1-(amp+1)*cw)/d0, amp*(amp+1-(amp-1)*cw-tsa)/d0],
                         a: [1, -2*(amp-1+(amp+1)*cw)/d0, (amp+1+(amp-1)*cw-tsa)/d0] };
            } else {
                var e0 = amp + 1 - (amp-1)*cw + tsa;
                return { b: [amp*(amp+1+(amp-1)*cw+tsa)/e0, -2*amp*(amp-1+(amp+1)*cw)/e0, amp*(amp+1+(amp-1)*cw-tsa)/e0],
                         a: [1, 2*(amp-1-(amp+1)*cw)/e0, (amp+1-(amp-1)*cw-tsa)/e0] };
            }
        } else if (type === "low_pass" || type === "high_pass") {
            var aq = sw/(2*Q), f0n = aq + 1;
            if (type === "low_pass")
                return { b: [(1-cw)/2/f0n, (1-cw)/f0n, (1-cw)/2/f0n], a: [1, -2*cw/f0n, (1-aq)/f0n] };
            return { b: [(1+cw)/2/f0n, -(1+cw)/f0n, (1+cw)/2/f0n], a: [1, -2*cw/f0n, (1-aq)/f0n] };
        }
        return null; // disabled → flat
    }
    function bandDb(band, f) {
        if (!band || band.type === "disabled") return 0;
        var c = coeffs(band.frequency, band.gain, band.q, band.type); if (!c) return 0;
        var w = 2 * Math.PI * f / 96000, c1 = Math.cos(w), c2 = Math.cos(2*w), s1 = Math.sin(w), s2 = Math.sin(2*w);
        var nr = c.b[0] + c.b[1]*c1 + c.b[2]*c2, ni = -(c.b[1]*s1 + c.b[2]*s2);
        var dr = c.a[0] + c.a[1]*c1 + c.a[2]*c2, di = -(c.a[1]*s1 + c.a[2]*s2);
        var mag = Math.sqrt((nr*nr + ni*ni) / (dr*dr + di*di));
        return 20 * Math.log(mag) / Math.LN10;
    }
    function totalDb(f) { var s = 0; for (var i = 0; i < root.bands.length; i++) s += root.bandDb(root.bands[i], f); return s }

    // ---- digital headroom ------------------------------------------------------
    // Boosts are gain applied in the DSP: the summed curve peaking at +6 dB means
    // peaks are 6 dB hotter than the source, and anything already near full scale
    // clips. Pre-gain buys that back by attenuating first, which is the whole reason
    // AutoEQ ships a preamp value with every profile. The guide has said "set pre-gain
    // ≈ minus your biggest boost" all along; nothing was checking whether you had.
    //
    // Peak of the SUMMED curve, not the biggest single band — overlapping bands add.
    readonly property real curvePeak: {
        var bs = root.bands;                       // dependency
        var pk = 0;
        for (var n = 0; n <= 120; n++) {
            var f = Math.pow(10, root.l0 + (n / 120) * (root.l1 - root.l0));
            var s = 0;
            for (var i = 0; i < bs.length; i++) s += root.bandDb(bs[i], f);
            if (s > pk) pk = s;
        }
        return pk;
    }
    // >0 means the curve overshoots full scale by that much. 0.05 dB of slack keeps
    // float noise from flickering the warning on an otherwise exactly-matched preset.
    readonly property real overshoot: root.curvePeak + root.pregain
    readonly property bool clipping: root.ready && root.supportsPregain && root.overshoot > 0.05
    function matchHeadroom() {
        root.pregain = root.clamp(Math.round(-root.curvePeak * 10) / 10, -24, 6);
        root.applyPregain();
    }

    // ---- theme (reads the shared appearance.json so it matches the rice) ----
    property string apAccent: "#63c7dd"
    property bool   apLight: false
    // Re-run on every open() — matugen rewrites `accent` whenever the wallpaper changes, and a
    // panel that only read this at bar startup would sit on a stale colour while the bar recoloured.
    Process { id: apReadProc; running: true; command: ["sh","-c","cat ~/.config/sea-shell/appearance.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j = JSON.parse(apOut.text.trim() || "{}");
            if (j.accent) root.apAccent = j.accent; if (j.mode !== undefined) root.apLight = ("" + j.mode === "light"); } catch(e){} } } }
    // ---------- industrial token shim ----------
    // Colours come from the shared Tok singleton (see shell.qml). This surface used to carry its
    // own copy of the ramp AND its own appearance.json parse, so it drifted from the bar every
    // time the palette changed. The `theme.*` vocabulary is kept because the call sites below
    // speak it; only the source of the values moved.
    QtObject {
        id: theme
        readonly property bool  light: Tok.light
        readonly property color bg:    Tok.bg
        readonly property color panel: Tok.surface
        readonly property color line:  Tok.ruleHard
        readonly property color text:  Tok.ink
        readonly property color sub:   Tok.ink2
        readonly property color faint: Tok.ink3
        readonly property color iris:  Tok.accent
        readonly property color frost: Tok.ink2
        readonly property color good:  Tok.ok
        readonly property color warn:  Tok.warn
        readonly property color bad:   Tok.crit
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    component Sym: Text { property int sz: 18; font.family: "Material Symbols Outlined"; font.pixelSize: sz
        color: theme.iris; verticalAlignment: Text.AlignVCenter }

    // horizontal slider (pre-gain / global offset)
    component DSlider: Item {
        id: sl
        property real from: 0; property real to: 1; property real value: 0
        property color fill: theme.iris
        signal moved(real v); signal committed(real v)
        implicitHeight: 18; Layout.fillWidth: true
        readonly property real t: sl.to === sl.from ? 0 : (sl.value - sl.from) / (sl.to - sl.from)
        Rectangle { id: trk; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5; radius: Tok.r; color: theme.a(theme.line, 0.85)
            Rectangle { width: trk.width * Math.max(0, Math.min(1, sl.t)); height: parent.height; radius: Tok.r; color: sl.fill } }
        Rectangle { width: 14; height: 14; radius: Tok.r; border.width: 2; border.color: sl.fill; color: theme.frost
            anchors.verticalCenter: parent.verticalCenter; x: (sl.width - width) * Math.max(0, Math.min(1, sl.t)) }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            function put(px) { var tt = Math.max(0, Math.min(1, px / sl.width)); sl.value = sl.from + tt * (sl.to - sl.from); sl.moved(sl.value) }
            onPressed: (e) => put(e.x)
            onPositionChanged: (e) => { if (pressed) put(e.x) }
            onReleased: () => sl.committed(sl.value) }
    }

    // vertical gain slider (band columns) — fills from the 0 dB centre line
    component VSlider: Item {
        id: vs
        property real from: -12; property real to: 12; property real value: 0
        property color fill: theme.iris
        signal moved(real v); signal committed(real v)
        implicitWidth: 24
        function tOf(v) { return vs.to === vs.from ? 0 : (v - vs.from) / (vs.to - vs.from) }
        Rectangle { id: vtrk; width: 6; radius: Tok.r; color: theme.a(theme.line, 0.85)
            anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.bottom: parent.bottom
            Rectangle { width: parent.width + 5; x: -2.5; height: 1; color: theme.a(theme.faint, 0.7); y: vtrk.height * (1 - vs.tOf(0)) }
            Rectangle { width: parent.width; radius: Tok.r; color: vs.fill
                property real cy: vtrk.height * (1 - vs.tOf(0)); property real ky: vtrk.height * (1 - vs.tOf(vs.value))
                y: Math.min(cy, ky); height: Math.abs(cy - ky) } }
        Rectangle { width: 20; height: 12; radius: Tok.r; color: theme.frost; border.width: 2; border.color: vs.fill
            anchors.horizontalCenter: parent.horizontalCenter; y: vtrk.height * (1 - vs.tOf(vs.value)) - height/2 }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            function put(py) { var t = 1 - Math.max(0, Math.min(1, py / vs.height)); vs.value = vs.from + t * (vs.to - vs.from); vs.moved(vs.value) }
            onPressed: (e) => put(e.y)
            onPositionChanged: (e) => { if (pressed) put(e.y) }
            onReleased: () => vs.committed(vs.value) }
    }

    component IconBtn: Rectangle {
        id: ib
        property string icon: ""; property int sz: 30; signal tapped()
        implicitWidth: sz + 4; implicitHeight: sz + 4; radius: Tok.r
        color: ibm.containsMouse ? theme.a(theme.iris, 0.18) : "transparent"
        Sym { anchors.centerIn: parent; text: ib.icon; sz: Math.round(ib.sz * 0.6); color: theme.sub }
        MouseArea { id: ibm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ib.tapped() }
    }
    component TextBtn: Rectangle {
        id: tb
        property string label: ""; property string icon: ""; property bool primary: false; signal tapped()
        implicitHeight: 32; implicitWidth: tbr.width + 22; radius: Tok.r
        opacity: tb.enabled ? 1 : 0.4
        color: tb.primary ? (tbm.containsMouse ? theme.frost : theme.iris) : (tbm.containsMouse ? theme.a(theme.iris, 0.18) : theme.a(theme.line, 0.4))
        border.width: 1; border.color: theme.a(theme.iris, tb.primary ? 0.5 : 0.2)
        RowLayout { id: tbr; anchors.centerIn: parent; spacing: 7
            Sym { text: tb.icon; sz: 15; color: tb.primary ? theme.bg : theme.frost }
            Text { text: tb.label; color: tb.primary ? theme.bg : theme.sub; font.pixelSize: 11; font.family: Tok.mono; font.bold: tb.primary } }
        MouseArea { id: tbm; anchors.fill: parent; enabled: tb.enabled; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tb.tapped() }
    }
    component OffsetTile: Rectangle {
        id: ot
        property string label: ""; property string unit: ""; property string hint: ""; property real from: 0; property real to: 1; property real value: 0
        // alert recolours the tile; action adds a one-tap fix chip beside the readout
        property bool alert: false
        property string action: ""
        signal moved(real v); signal committed(); signal actionTapped()
        Layout.fillWidth: true; implicitHeight: 56; radius: Tok.r
        color: ot.alert ? theme.a(theme.warn, 0.13) : theme.a(theme.line, 0.24)
        border.width: 1; border.color: ot.alert ? theme.a(theme.warn, 0.45) : theme.a(theme.iris, 0.12)
        ColumnLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 8; anchors.bottomMargin: 8; spacing: 3
            RowLayout { Layout.fillWidth: true; spacing: 6
                Text { text: ot.label; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                Text { text: ot.hint; color: ot.alert ? theme.warn : theme.faint; font.pixelSize: 9; font.family: Tok.mono; visible: ot.hint !== ""
                    font.bold: ot.alert }
                Item { Layout.fillWidth: true }
                Rectangle {
                    visible: ot.action !== ""
                    implicitHeight: 15; implicitWidth: actT.width + 12; radius: Tok.r
                    color: actMa.containsMouse ? theme.warn : theme.a(theme.warn, 0.2)
                    border.width: 1; border.color: theme.a(theme.warn, 0.55)
                    Text { id: actT; anchors.centerIn: parent; text: ot.action
                        color: actMa.containsMouse ? theme.bg : theme.warn; font.pixelSize: 8; font.family: Tok.mono; font.bold: true }
                    MouseArea { id: actMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ot.actionTapped() }
                }
                Text { text: (ot.value >= 0 ? "+" : "") + ot.value.toFixed(1) + " " + ot.unit
                    color: ot.alert ? theme.warn : theme.frost; font.pixelSize: 12; font.family: Tok.mono; font.bold: true } }
            DSlider { from: ot.from; to: ot.to; value: ot.value; fill: ot.alert ? theme.warn : theme.iris
                onMoved: (v) => ot.moved(v); onCommitted: ot.committed() }
        }
    }

    // ---- tuning-guide building blocks ----------------------------------------
    // section heading with a trailing rule, so the guide scans as sections rather
    // than one long column of paragraphs
    component HelpHead: RowLayout {
        id: hh
        property string title: ""
        property string note: ""
        Layout.fillWidth: true; spacing: 9; Layout.topMargin: 2
        Text { text: hh.title; color: theme.iris; font.pixelSize: 10; font.family: Tok.mono; font.bold: true; font.letterSpacing: 2 }
        Text { text: hh.note; color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; visible: hh.note !== "" }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.a(theme.iris, 0.2) }
    }

    // Tiny response-curve preview. Uses root.bandDb — the same maths as the big
    // graph — so every shape in the guide is the real curve the DAC would produce,
    // not an illustration that can drift out of sync with the filters.
    // Response readout drawn the way hub.moondroplab.tech draws it: a flat reference
    // and the same signal with the EQ applied, normalised so the reference sits at
    // `normDb` (their default: 60 dB, referenced at 500 Hz). Read-only — no zones, no
    // handles. That framing carries one thing our editor graph can't: because the
    // equalised curve includes PRE-GAIN, you see the real output level, so a curve
    // that boosts 6 dB visibly sits below the reference once you've paid for it.
    component RespChart: Canvas {
        id: rc
        property var  bands: []
        property real pre: 0
        property bool withPre: true      // the official's eye toggle
        property real normDb: 60
        property color curve: theme.bad
        property color flat: "#c86fd0"
        readonly property real topDb: rc.normDb + 6
        readonly property real botDb: rc.normDb - 14
        antialiasing: true
        onBandsChanged: requestPaint()
        onPreChanged: requestPaint()
        onWithPreChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
        function yOf(db) { return (rc.topDb - db) / (rc.topDb - rc.botDb) * height }
        function sumDb(f) {
            var s = 0;
            for (var i = 0; i < rc.bands.length; i++) s += root.bandDb(rc.bands[i], f);
            return s;
        }
        onPaint: {
            var ctx = getContext("2d"), w = width, h = height;
            ctx.clearRect(0, 0, w, h);

            // minor gridlines: every 1-2-3…9 step of each decade, like the official
            ctx.lineWidth = 1; ctx.strokeStyle = theme.line;
            for (var dec = 1; dec <= 4; dec++) {
                for (var m = 1; m <= 9; m++) {
                    var f = m * Math.pow(10, dec);
                    if (f < root.fMin || f > root.fMax) continue;
                    var gx = root.xOfFreq(f, w);
                    ctx.globalAlpha = 0.13;
                    ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, h - 13); ctx.stroke();
                }
            }
            // horizontal dashed lines every 5 dB
            ctx.setLineDash([3, 4]);
            for (var db = Math.ceil(rc.botDb / 5) * 5; db <= rc.topDb; db += 5) {
                var y = rc.yOf(db);
                ctx.globalAlpha = 0.3; ctx.strokeStyle = theme.line;
                ctx.beginPath(); ctx.moveTo(30, y); ctx.lineTo(w, y); ctx.stroke();
                ctx.globalAlpha = 0.85; ctx.fillStyle = theme.faint;
                ctx.font = "9px monospace"; ctx.textAlign = "left";
                ctx.fillText("+" + db + "dB", 0, root.clamp(y + 3, 9, h - 15));
            }
            ctx.setLineDash([]);

            // frequency labels
            var marks = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
            var labels = ["20Hz", "50Hz", "100Hz", "200Hz", "500Hz", "1KHz", "2KHz", "5KHz", "10KHz", "20KHz"];
            ctx.textAlign = "center";
            for (var i = 0; i < marks.length; i++) {
                var x = root.xOfFreq(marks[i], w);
                ctx.globalAlpha = 0.28; ctx.strokeStyle = theme.line;
                ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h - 13); ctx.stroke();
                ctx.globalAlpha = 0.9; ctx.fillStyle = theme.faint;
                ctx.fillText(labels[i], root.clamp(x, 16, w - 16), h - 2);
            }

            // the flat reference
            ctx.globalAlpha = 1; ctx.lineWidth = 1.6; ctx.strokeStyle = rc.flat;
            var fy = rc.yOf(rc.normDb);
            ctx.beginPath(); ctx.moveTo(30, fy); ctx.lineTo(w, fy); ctx.stroke();

            // …and the same thing equalised. Pre-gain is part of the answer, not a
            // footnote: it is what makes a +6 dB curve safe, and hiding it would draw
            // an output level the DAC never produces.
            var off = rc.normDb + (rc.withPre ? rc.pre : 0);
            ctx.lineWidth = 2.2; ctx.strokeStyle = rc.curve; ctx.beginPath();
            for (var px = 0; px <= w; px += 2) {
                var ff = root.freqOfX(px, w);
                var yy = rc.yOf(root.clamp(off + rc.sumDb(ff), rc.botDb - 4, rc.topDb + 4));
                px === 0 ? ctx.moveTo(px, yy) : ctx.lineTo(px, yy);
            }
            ctx.stroke();
            ctx.textAlign = "left";
        }
    }

    component MiniCurve: Canvas {
        id: mc
        property var band: null
        property real span: 12          // vertical range, ±dB
        property color stroke: theme.frost
        implicitWidth: 58; implicitHeight: 30
        onBandChanged: requestPaint()
        onStrokeChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
            var w = width, h = height, mid = h / 2, pad = 3;
            ctx.lineWidth = 1; ctx.globalAlpha = 0.3; ctx.strokeStyle = theme.faint;
            ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke();
            ctx.globalAlpha = 1;
            if (!mc.band) return;
            ctx.strokeStyle = mc.stroke; ctx.lineWidth = 1.7; ctx.beginPath();
            for (var px = 0; px <= w; px++) {
                var db = root.clamp(root.bandDb(mc.band, root.freqOfX(px, w)), -mc.span, mc.span);
                var y = mid - (db / mc.span) * (mid - pad);
                px === 0 ? ctx.moveTo(px, y) : ctx.lineTo(px, y);
            }
            ctx.stroke();
        }
    }

    component RuleCard: Rectangle {
        id: rc
        property int n: 1
        property string title: ""
        property string body: ""
        Layout.fillWidth: true; Layout.preferredWidth: 1; radius: Tok.r
        color: theme.a(theme.line, 0.2); border.width: 1; border.color: theme.a(theme.iris, 0.13)
        implicitHeight: rcr.height + 20
        RowLayout {
            id: rcr
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 11; anchors.rightMargin: 11; anchors.topMargin: 10; spacing: 9
            Rectangle {
                implicitWidth: 19; implicitHeight: 19; radius: Tok.r; Layout.alignment: Qt.AlignTop
                color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.35)
                Text { anchors.centerIn: parent; text: "" + rc.n; color: theme.frost; font.pixelSize: 10; font.family: Tok.mono; font.bold: true }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 2
                Text { text: rc.title; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: rc.body; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; lineHeight: 1.3 }
            }
        }
    }

    component NoteCard: Rectangle {
        id: nc
        property string icon: "info"
        property string title: ""
        property string body: ""
        property color tint: theme.iris
        Layout.fillWidth: true; radius: Tok.r
        color: theme.a(nc.tint, 0.08); border.width: 1; border.color: theme.a(nc.tint, 0.26)
        implicitHeight: ncr.height + 22
        RowLayout {
            id: ncr
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 12; anchors.rightMargin: 12; anchors.topMargin: 11; spacing: 10
            Sym { text: nc.icon; sz: 16; color: nc.tint; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 3
                Text { text: nc.title; color: nc.tint; font.pixelSize: 11; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: nc.body; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; lineHeight: 1.35 }
            }
        }
    }

    PanelWindow {
        id: win
        visible: root.shown
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.5); MouseArea { anchors.fill: parent; onClicked: root.close() } }
        // Escape backs out one layer at a time rather than nuking the whole panel.
        Item { anchors.fill: parent; focus: root.shown
            Keys.onEscapePressed: {
                if (root.fileOpen) root.fileOpen = false;
                // the search field eats Escape first to clear itself; this is the
                // second press, which should back out of the browser
                else if (root.hubOpen) root.hubOpen = false;
                else if (root.helpOpen) root.helpOpen = false;
                else root.close();
            } }

        Rectangle {
            anchors.centerIn: parent
            width: 980; height: 726; radius: Tok.rCard
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                // ---------------- header ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Sym { text: "graphic_eq"; sz: 26; color: theme.iris }
                    ColumnLayout { spacing: 1
                        RowLayout { spacing: 8
                            Text {
                                text: root.sw ? "Software EQ" : (root.dev.ok ? root.dev.device_name : "Moondrop DAC")
                                color: theme.text; font.pixelSize: 20; font.family: Tok.mono; font.bold: true }
                            Rectangle { visible: root.dev.ok && !root.sw; radius: Tok.r; implicitHeight: 18; implicitWidth: fwT.width + 14; color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                Text { id: fwT; anchors.centerIn: parent; text: "fw " + (root.dev.firmware || "?"); color: theme.frost; font.pixelSize: 10; font.family: Tok.mono } }
                            // Where the filters are actually running. Worth stating plainly:
                            // the software one dies with the sink, the DAC's outlives the shell.
                            Rectangle {
                                visible: root.sw; radius: Tok.r; implicitHeight: 18; implicitWidth: swT.width + 14
                                color: theme.a(root.swInfo.sink_present ? theme.good : theme.faint, 0.16)
                                border.width: 1; border.color: theme.a(root.swInfo.sink_present ? theme.good : theme.faint, 0.4)
                                Text { id: swT; anchors.centerIn: parent
                                    text: root.swInfo.sink_present ? "live · pipewire" : "not created yet"
                                    color: root.swInfo.sink_present ? theme.good : theme.faint
                                    font.pixelSize: 10; font.family: Tok.mono } }
                            Rectangle { visible: root.dirty; radius: Tok.r; implicitHeight: 18; implicitWidth: dtT.width + 14; color: theme.a(theme.warn, 0.18); border.width: 1; border.color: theme.a(theme.warn, 0.4)
                                Text { id: dtT; anchors.centerIn: parent; text: "unsaved"; color: theme.warn; font.pixelSize: 10; font.family: Tok.mono } }
                        }
                        Text {
                            text: root.sw
                                  ? (root.bandCount + "-band EQ in pipewire · any output · "
                                     + (root.hwPresent ? "DAC connected but overridden"
                                        : "no Moondrop DAC — filters run in software"))
                                  : (root.dev.ok ? (root.bandCount + "-band parametric EQ · DSP @ 96 kHz")
                                                 : (root.dev.error || "no device connected"))
                            color: (root.sw || root.dev.ok) ? theme.faint : theme.bad
                            font.pixelSize: 11; font.family: Tok.mono
                            Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                    Item { Layout.fillWidth: true }

                    // Backend override. Only worth showing when there's a real choice:
                    // with no DAC there is nothing to switch to.
                    Rectangle {
                        visible: root.hwPresent
                        implicitHeight: 24; implicitWidth: bkRow.width + 8; radius: Tok.r
                        color: theme.a(theme.line, 0.4)
                        border.width: 1; border.color: theme.a(theme.iris, 0.16)
                        RowLayout {
                            id: bkRow; anchors.centerIn: parent; spacing: 2
                            Repeater {
                                model: [ { k: "hw", t: "DAC" }, { k: "sw", t: "software" } ]
                                delegate: Rectangle {
                                    id: bk
                                    required property var modelData
                                    readonly property bool on: (bk.modelData.k === "hw") !== root.sw
                                    implicitHeight: 20; implicitWidth: bkT.width + 14; radius: Tok.r
                                    color: bk.on ? theme.iris : (bkMa.containsMouse ? theme.a(theme.iris, 0.2) : "transparent")
                                    Text { id: bkT; anchors.centerIn: parent; text: bk.modelData.t
                                        color: bk.on ? theme.bg : theme.sub
                                        font.pixelSize: 10; font.family: Tok.mono; font.bold: bk.on }
                                    MouseArea {
                                        id: bkMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.backendPref = bk.modelData.k;
                                            root.dirty = false; root.swDirty = false;
                                            root.pristine = null;
                                            root.refresh();     // the two backends hold different bands
                                        }
                                    }
                                }
                            }
                        }
                    }

                    TextBtn {
                        label: "community"; icon: "groups"
                        enabled: root.devPidHex !== "" || root.sw
                        onTapped: { root.hubOpen = true; if (root.hubState === "idle" || root.hubState === "error") root.hubBrowse() }
                    }
                    TextBtn { label: "how to tune"; icon: "help"; onTapped: root.helpOpen = true }
                    IconBtn { icon: "refresh"; onTapped: root.refresh() }
                    IconBtn { icon: "close"; onTapped: root.close() }
                }

                // ---------------- preset + offsets ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 12; enabled: root.ready; opacity: root.ready ? 1 : 0.4
                    // A DAC concept: which of the device's internal profiles is selected.
                    // There is no such thing in a pipewire graph, so don't draw a control
                    // that would sit there reporting "slot 0" and doing nothing.
                    Rectangle { visible: !root.sw
                        Layout.preferredWidth: 236; implicitHeight: 56; radius: Tok.r; color: theme.a(theme.line, 0.24); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                        RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 4
                            ColumnLayout { spacing: 1; Layout.fillWidth: true
                                Text { text: "DEVICE SLOT"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                                RowLayout { spacing: 6
                                    Text { text: "slot " + root.profile; color: theme.text; font.pixelSize: 15; font.family: Tok.mono }
                                    // Just what the DAC reports. It is NOT a readout of whether
                                    // the EQ is on -- see the header note; don't colour it as one.
                                    Text { text: "· as reported"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono } } }
                            IconBtn { icon: "remove"; sz: 26; onTapped: { root.profile = root.clamp(root.profile - 1, 0, 15); root.applyProfile() } }
                            IconBtn { icon: "add";    sz: 26; onTapped: { root.profile = root.clamp(root.profile + 1, 0, 15); root.applyProfile() } }
                        } }
                    // some devices report no pre-gain support at all (script's NO_PREGAIN_DEVICES)
                    OffsetTile { label: "PRE-GAIN"; unit: "dB"
                        hint: !root.supportsPregain ? "not supported"
                              : root.clipping ? ("clips by " + root.overshoot.toFixed(1) + " dB")
                              : "headroom"
                        alert: root.clipping
                        action: root.clipping ? "match" : ""
                        onActionTapped: root.matchHeadroom()
                        from: -24; to: 6; value: root.pregain
                        enabled: root.supportsPregain; opacity: root.supportsPregain ? 1 : 0.45
                        onMoved: (v) => root.pregain = v; onCommitted: root.applyPregain() }
                    // Also a DAC register (its own volume trim), with no software analogue —
                    // use your normal volume for that.
                    OffsetTile { visible: !root.sw
                        label: "GLOBAL OFFSET"; hint: "volume"; unit: "dB"; from: -10; to: 10; value: root.globalGain
                        onMoved: (v) => root.globalGain = v; onCommitted: root.applyGlobal() }
                }

                // ---------------- starting-point presets ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    enabled: root.ready; opacity: root.ready ? 1 : 0.4
                    Text { text: "PRESETS"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                    Repeater {
                        model: root.presets
                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r
                            color: chipMa.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.3)
                            border.width: 1; border.color: theme.a(theme.iris, chipMa.containsMouse ? 0.45 : 0.16)
                            RowLayout {
                                anchors.centerIn: parent; spacing: 5
                                Sym { text: chip.modelData.ic; sz: 13; color: theme.frost }
                                Text { text: chip.modelData.nm; color: theme.sub; font.pixelSize: 10; font.family: Tok.mono; font.bold: true }
                            }
                            MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.applyPreset(chip.modelData) }
                        }
                    }
                }

                // ---------------- response graph (region-labelled) ----------------
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 244; radius: Tok.r
                    color: theme.a(theme.panel, 0.6); border.width: 1; border.color: theme.a(theme.iris, 0.14); clip: true

                    // Two views of the same maths, because they answer different questions.
                    // The editor shows what each band does and lets you drag it. The readout
                    // is hub.moondroplab.tech's framing: one curve, normalised, pre-gain
                    // paid — what the DAC actually outputs. Neither is a substitute for the
                    // other, so it's a toggle rather than a replacement.
                    RespChart {
                        id: bigChart
                        visible: root.graphReadout
                        anchors.fill: parent; anchors.margins: 10
                        bands: root.bands
                        pre: root.pregain
                        withPre: true
                    }
                    Rectangle {
                        z: 6
                        anchors.right: parent.right; anchors.top: parent.top
                        anchors.rightMargin: 8; anchors.topMargin: 8
                        implicitWidth: 26; implicitHeight: 22; radius: Tok.r
                        color: gmMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.bg, 0.6)
                        border.width: 1; border.color: theme.a(theme.iris, root.graphReadout ? 0.5 : 0.18)
                        Sym {
                            anchors.centerIn: parent; sz: 13
                            text: root.graphReadout ? "tune" : "show_chart"
                            color: root.graphReadout ? theme.frost : theme.faint
                        }
                        MouseArea {
                            id: gmMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.graphReadout = !root.graphReadout
                        }
                    }

                    Canvas {
                        id: graph; visible: !root.graphReadout
                        anchors.fill: parent; anchors.margins: 10; antialiasing: true
                        property var _bands: root.bands
                        property int _sel: root.sel
                        property color _accent: theme.iris
                        property real _pre: root.pregain    // the output curve depends on it
                        on_BandsChanged: requestPaint()
                        on_SelChanged: requestPaint()
                        on_AccentChanged: requestPaint()
                        on_PreChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        function css(c) { return Qt.rgba(c.r, c.g, c.b, c.a) }
                        function hexA(hex, a) { var h = ("" + hex).replace("#", "");
                            return Qt.rgba(parseInt(h.substr(0,2),16)/255, parseInt(h.substr(2,2),16)/255, parseInt(h.substr(4,2),16)/255, a) }

                        onPaint: {
                            var ctx = getContext("2d"); var w = width, h = height;
                            ctx.clearRect(0, 0, w, h); ctx.lineWidth = 1; ctx.textAlign = "left";
                            // frequency-region zones + labels (what each part tunes)
                            for (var r = 0; r < root.regionDefs.length; r++) {
                                var rd = root.regionDefs[r];
                                var zx1 = root.xOfFreq(rd.f1, w), zx2 = root.xOfFreq(rd.f2, w);
                                ctx.fillStyle = graph.hexA(rd.c, r % 2 ? 0.05 : 0.09);
                                ctx.fillRect(zx1, 0, zx2 - zx1, h);
                                if (zx2 - zx1 > 34) { ctx.fillStyle = graph.hexA(rd.c, 0.85);
                                    ctx.font = "9px monospace"; ctx.textAlign = "center"; ctx.fillText(rd.n, (zx1 + zx2) / 2, 12); ctx.textAlign = "left"; }
                            }
                            // minor gridlines (1-2-3…9 per decade), like the official chart
                            ctx.strokeStyle = theme.line; ctx.globalAlpha = 0.1;
                            for (var dc = 1; dc <= 4; dc++) {
                                for (var mm = 2; mm <= 9; mm++) {
                                    var mf = mm * Math.pow(10, dc);
                                    if (mf < root.fMin || mf > root.fMax) continue;
                                    var mx = root.xOfFreq(mf, w);
                                    ctx.beginPath(); ctx.moveTo(mx, 16); ctx.lineTo(mx, h - 11); ctx.stroke();
                                }
                            }
                            ctx.font = "9px monospace";
                            for (var db = -root.dbMax; db <= root.dbMax; db += 6) {
                                var y = root.yOfDb(db, h);
                                ctx.globalAlpha = db === 0 ? 0.85 : 0.4; ctx.strokeStyle = theme.line;
                                if (db !== 0) ctx.setLineDash([3, 4]);
                                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
                                ctx.setLineDash([]);
                                // Keep the label inside the canvas and clear of the frequency
                                // row along the bottom. Unclamped, +dbMax draws at y=-2 (above
                                // the top edge, invisible) and -dbMax at y=h-2 — exactly where
                                // the "20" sits, which is what made the corner read "2012".
                                ctx.globalAlpha = 1; ctx.fillStyle = theme.faint;
                                ctx.fillText((db > 0 ? "+" : "") + db, 2, root.clamp(y - 2, 9, h - 12));
                            }
                            var marks = [20,50,100,200,500,1000,2000,5000,10000,20000];
                            var labels = ["20","50","100","200","500","1k","2k","5k","10k","20k"];
                            for (var i = 0; i < marks.length; i++) {
                                var x = root.xOfFreq(marks[i], w);
                                ctx.globalAlpha = 0.28; ctx.strokeStyle = theme.line;
                                ctx.beginPath(); ctx.moveTo(x, 16); ctx.lineTo(x, h); ctx.stroke();
                                ctx.globalAlpha = 0.9; ctx.fillStyle = theme.faint; ctx.fillText(labels[i], root.clamp(x - 6, 0, w - 18), h - 2);
                            }
                            ctx.globalAlpha = 1;
                            for (var b = 0; b < graph._bands.length; b++) {
                                if (graph._bands[b].type === "disabled") continue;
                                ctx.strokeStyle = graph.css(theme.a(b === graph._sel ? theme.frost : theme.iris, b === graph._sel ? 0.5 : 0.16));
                                ctx.lineWidth = b === graph._sel ? 1.5 : 1; ctx.beginPath();
                                for (var px = 0; px <= w; px += 3) {
                                    var f = root.freqOfX(px, w); var yy = root.yOfDb(root.clamp(root.bandDb(graph._bands[b], f), -root.dbMax, root.dbMax), h);
                                    px === 0 ? ctx.moveTo(px, yy) : ctx.lineTo(px, yy);
                                }
                                ctx.stroke();
                            }
                            // "Flat" — the reference the EQ is shaping, drawn the way the
                            // official chart draws it so the two read the same way.
                            ctx.globalAlpha = 1; ctx.strokeStyle = "#c86fd0"; ctx.lineWidth = 1.4;
                            var flatY = root.yOfDb(0, h);
                            ctx.beginPath(); ctx.moveTo(0, flatY); ctx.lineTo(w, flatY); ctx.stroke();

                            // The EQ curve: what the bands do, which is what the handles edit.
                            ctx.strokeStyle = theme.iris; ctx.lineWidth = 2.4; ctx.beginPath();
                            for (var qx = 0; qx <= w; qx += 2) {
                                var ff = root.freqOfX(qx, w); var ty = root.yOfDb(root.clamp(root.totalDb(ff), -root.dbMax, root.dbMax), h);
                                qx === 0 ? ctx.moveTo(qx, ty) : ctx.lineTo(qx, ty);
                            }
                            ctx.stroke();

                            // …and the level that actually leaves the DAC, once pre-gain is
                            // paid for. The official chart only ever draws THIS one, which is
                            // why a +6 dB curve looks like it sits below flat there and above
                            // it here. Without it the graph shows gain you don't get to keep.
                            if (Math.abs(root.pregain) > 0.05) {
                                ctx.strokeStyle = graph.css(theme.a(theme.bad, 0.85));
                                ctx.lineWidth = 1.6; ctx.setLineDash([5, 3]); ctx.beginPath();
                                for (var ox = 0; ox <= w; ox += 2) {
                                    var of = root.freqOfX(ox, w);
                                    var oy = root.yOfDb(root.clamp(root.totalDb(of) + root.pregain, -root.dbMax, root.dbMax), h);
                                    ox === 0 ? ctx.moveTo(ox, oy) : ctx.lineTo(ox, oy);
                                }
                                ctx.stroke(); ctx.setLineDash([]);
                            }
                            // handles: dot on the curve, number offset with a leader (anti-overlap)
                            var order = [];
                            for (var k = 0; k < graph._bands.length; k++) { if (graph._bands[k].type === "disabled") continue;
                                order.push({ k: k, hx: root.xOfFreq(graph._bands[k].frequency, w), hy: root.yOfDb(root.clamp(graph._bands[k].gain, -root.dbMax, root.dbMax), h) }); }
                            order.sort(function(a, b2) { return a.hx - b2.hx });
                            var prevX = -999, above = true;
                            ctx.textAlign = "center";
                            for (var o = 0; o < order.length; o++) {
                                var oo = order[o], selK = oo.k === graph._sel;
                                var near = (oo.hx - prevX) < 24; above = near ? !above : true; prevX = oo.hx;
                                var ly = above ? oo.hy - 15 : oo.hy + 15;
                                ctx.globalAlpha = 0.5; ctx.strokeStyle = selK ? theme.frost : theme.iris; ctx.lineWidth = 1;
                                ctx.beginPath(); ctx.moveTo(oo.hx, oo.hy); ctx.lineTo(oo.hx, ly + (above ? 5 : -5)); ctx.stroke(); ctx.globalAlpha = 1;
                                ctx.beginPath(); ctx.arc(oo.hx, oo.hy, selK ? 6 : 4, 0, 2*Math.PI);
                                ctx.fillStyle = selK ? theme.frost : theme.iris; ctx.fill();
                                ctx.lineWidth = 2; ctx.strokeStyle = theme.bg; ctx.stroke();
                                ctx.fillStyle = selK ? theme.frost : theme.sub; ctx.font = (selK ? "bold " : "") + "10px monospace";
                                ctx.fillText("" + graph._bands[oo.k].index, oo.hx, ly + 3);
                            }
                            ctx.textAlign = "left";

                            // legend, bottom-left like the official's
                            var lg = [{ c: "#c86fd0", t: "Flat", d: false },
                                      { c: graph.css(theme.iris), t: "Equalized", d: false }];
                            if (Math.abs(root.pregain) > 0.05)
                                lg.push({ c: graph.css(theme.a(theme.bad, 0.85)), t: "+ pre-gain (output)", d: true });
                            ctx.font = "9px monospace";
                            var lw = 0;
                            for (var q = 0; q < lg.length; q++) lw = Math.max(lw, ctx.measureText(lg[q].t).width);
                            var bx = 6, by = h - 14 - lg.length * 12;
                            ctx.globalAlpha = 0.82; ctx.fillStyle = graph.css(theme.a(theme.bg, 0.9));
                            ctx.fillRect(bx, by, lw + 26, lg.length * 12 + 6);
                            ctx.globalAlpha = 1;
                            for (var q2 = 0; q2 < lg.length; q2++) {
                                var ly2 = by + 9 + q2 * 12;
                                ctx.strokeStyle = lg[q2].c; ctx.lineWidth = 2;
                                if (lg[q2].d) ctx.setLineDash([3, 2]);
                                ctx.beginPath(); ctx.moveTo(bx + 4, ly2 - 2); ctx.lineTo(bx + 18, ly2 - 2); ctx.stroke();
                                ctx.setLineDash([]);
                                ctx.fillStyle = theme.faint; ctx.fillText(lg[q2].t, bx + 22, ly2 + 1);
                            }
                        }

                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true
                            property int dragIdx: -1
                            function nearest(mx, my) {
                                var best = -1, bd = 1e9;
                                for (var i = 0; i < root.bands.length; i++) {
                                    if (root.bands[i].type === "disabled") continue;
                                    var hx = root.xOfFreq(root.bands[i].frequency, width), hy = root.yOfDb(root.clamp(root.bands[i].gain, -root.dbMax, root.dbMax), height);
                                    var d = Math.hypot(mx - hx, my - hy); if (d < bd) { bd = d; best = i; }
                                }
                                return bd < 26 ? best : -1;
                            }
                            onPressed: (e) => { var n = nearest(e.x, e.y); if (n >= 0) { root.sel = n; dragIdx = n; } }
                            onPositionChanged: (e) => {
                                if (dragIdx < 0) return;
                                root.setBand(dragIdx, { frequency: Math.round(root.clamp(root.freqOfX(e.x, width), root.fMin, root.fMax)),
                                                        gain: Math.round(root.clamp(root.dbOfY(e.y, height), -root.dbMax, root.dbMax) * 10) / 10 }, false);
                            }
                            onReleased: () => { if (dragIdx >= 0) { root.applyBand(dragIdx); dragIdx = -1; } }
                            onWheel: (e) => {
                                if (root.sel < 0 || root.sel >= root.bands.length) return;
                                var q = root.clamp(root.bands[root.sel].q * (e.angleDelta.y > 0 ? 1.12 : 0.89), 0.1, root.qMax);
                                root.setBand(root.sel, { q: Math.round(q * 1000) / 1000 }, false); qDebounce.restart();
                            }
                        }
                        Timer { id: qDebounce; interval: 250; onTriggered: root.applyBand(root.sel) }
                    }
                }

                // ---------------- all-bands column editor ----------------
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; radius: Tok.r
                    visible: root.ready
                    color: theme.a(theme.panel, 0.5); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 9; spacing: 7
                        Repeater {
                            model: root.bands.length
                            delegate: Rectangle {
                                id: col
                                required property int index                      // position on screen
                                readonly property int slot: root.slotAt(index)   // the DAC slot it edits
                                readonly property var bd: root.bands[slot]
                                readonly property bool selCol: slot === root.sel
                                readonly property bool off: col.bd.type === "disabled"
                                Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; radius: Tok.r
                                color: selCol ? theme.a(theme.iris, 0.13) : theme.a(theme.line, 0.16)
                                border.width: 1; border.color: selCol ? theme.a(theme.iris, 0.5) : theme.a(theme.line, 0.5)
                                MouseArea { anchors.fill: parent; onClicked: root.sel = col.slot }   // click empty space to select
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 8; spacing: 5
                                    // region tag + slot number. The tag tracks frequency only, so on a
                                    // disabled band it describes where nothing is happening — mute it
                                    // rather than let eight parked bands all shout MID. The slot number
                                    // keeps these matched to the numbered handles on the graph now that
                                    // columns sit in frequency order rather than slot order.
                                    Item {
                                        Layout.fillWidth: true; implicitHeight: 10
                                        Text { anchors.centerIn: parent; text: root.regionOf(col.bd.frequency).n
                                            color: col.off ? theme.a(theme.faint, 0.45) : root.regionOf(col.bd.frequency).c
                                            font.pixelSize: 8; font.family: Tok.mono; font.bold: true; font.letterSpacing: .5 }
                                        // bd.index is the slot the write actually targets, and the same
                                        // number the graph prints on its handles — use it, not the
                                        // on-screen position, so the two can never disagree.
                                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                            text: col.bd.index; color: theme.a(theme.faint, col.selCol ? 0.9 : 0.5)
                                            font.pixelSize: 7; font.family: Tok.mono }
                                    }
                                    // filter type — click cycles fwd, right-click back
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 24; radius: Tok.r
                                        color: col.off ? theme.a(theme.line, 0.4) : theme.a(theme.iris, 0.12)
                                        border.width: 1; border.color: theme.a(theme.iris, 0.28)
                                        Text { anchors.centerIn: parent; text: root.typeAbbr(col.bd.type); color: col.off ? theme.faint : theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onPressed: (e) => { root.sel = col.slot; root.cycleType(col.slot, e.button === Qt.RightButton ? -1 : 1) } }
                                    }
                                    // vertical gain slider — the tall centrepiece
                                    VSlider { Layout.fillWidth: true; Layout.fillHeight: true; from: -root.dbMax; to: root.dbMax; value: col.bd.gain
                                        fill: col.off ? theme.a(theme.faint, 0.5) : (col.selCol ? theme.frost : theme.iris)
                                        onMoved: (v) => { root.sel = col.slot; root.setBand(col.slot, { gain: Math.round(v * 10) / 10 }, false) }
                                        onCommitted: () => root.applyBand(col.slot) }
                                    // gain readout — turns amber and tags "limit" when the band is
                                    // pinned against the firmware's Q2.30 coefficient ceiling, so
                                    // the wall is visible instead of just feeling like a stuck slider
                                    RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 4
                                        Text { text: (col.bd.gain >= 0 ? "+" : "") + col.bd.gain.toFixed(1)
                                            color: col.off ? theme.a(theme.faint, 0.55) : (root.atCeiling(col.bd) ? theme.warn : theme.frost)
                                            font.pixelSize: 12; font.family: Tok.mono; font.bold: true }
                                        Text { visible: root.atCeiling(col.bd); text: "limit"; color: theme.warn; font.pixelSize: 7; font.family: Tok.mono } }
                                    // frequency stepper (log step)
                                    RowLayout { Layout.fillWidth: true; spacing: 0
                                        IconBtn { icon: "remove"; sz: 18; onTapped: { root.sel = col.slot; root.stepFreq(col.slot, -1) } }
                                        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.fmtHz(col.bd.frequency)
                                            color: col.off ? theme.a(theme.faint, 0.6) : theme.sub; font.pixelSize: 10; font.family: Tok.mono }
                                        IconBtn { icon: "add"; sz: 18; onTapped: { root.sel = col.slot; root.stepFreq(col.slot, 1) } } }
                                    Text { Layout.alignment: Qt.AlignHCenter; text: "FREQ"; color: theme.faint; font.pixelSize: 7; font.family: Tok.mono; font.letterSpacing: 1 }
                                    // Q stepper
                                    RowLayout { Layout.fillWidth: true; spacing: 0
                                        IconBtn { icon: "remove"; sz: 18; onTapped: { root.sel = col.slot; root.setBand(col.slot, { q: Math.round(root.clamp(col.bd.q - 0.1, 0.1, root.qMax) * 100) / 100 }, true) } }
                                        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "Q" + col.bd.q.toFixed(2)
                                            color: col.off ? theme.a(theme.faint, 0.6) : theme.sub; font.pixelSize: 10; font.family: Tok.mono }
                                        IconBtn { icon: "add"; sz: 18; onTapped: { root.sel = col.slot; root.setBand(col.slot, { q: Math.round(root.clamp(col.bd.q + 0.1, 0.1, root.qMax) * 100) / 100 }, true) } } }
                                }
                            }
                        }
                    }
                }

                // ---------------- toasts ----------------
                // Layout items, not overlays: anchored to the panel bottom they sat on
                // top of the footer and hid the buttons. Layouts skip invisible items,
                // so these cost nothing until they fire, then push the footer down.

                // Mostly the Q2.30 coefficient-overflow refusal: the firmware can't
                // represent the filter, so the script declines rather than let the DAC
                // wrap and play a curve that isn't the one drawn. The graph has already
                // been resynced to the device by the time this shows.
                Rectangle {
                    visible: root.lastError !== ""
                    Layout.fillWidth: true
                    implicitHeight: errCol.height + 18; radius: Tok.r
                    color: theme.a(theme.bad, 0.16); border.width: 1; border.color: theme.a(theme.bad, 0.5)
                    RowLayout {
                        id: errCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 10
                        Sym { text: "block"; sz: 18; color: theme.bad }
                        ColumnLayout { Layout.fillWidth: true; spacing: 1
                            Text { text: "device refused the write — graph resynced to the DAC"
                                color: theme.bad; font.pixelSize: 11; font.family: Tok.mono; font.bold: true }
                            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: root.lastError
                                color: theme.sub; font.pixelSize: 10; font.family: Tok.mono; lineHeight: 1.25 } }
                        IconBtn { icon: "close"; onTapped: root.lastError = "" }
                    }
                }

                Rectangle {
                    // A failed export clears `exported` in _done(), and this yields to the
                    // error toast anyway, so the two can never both be showing.
                    visible: root.exported !== "" && root.lastError === ""
                    Layout.fillWidth: true
                    implicitHeight: expRow.height + 18; radius: Tok.r
                    color: theme.a(theme.good, 0.14); border.width: 1; border.color: theme.a(theme.good, 0.45)
                    RowLayout {
                        id: expRow
                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 10
                        Sym { text: "check_circle"; sz: 18; color: theme.good }
                        ColumnLayout { Layout.fillWidth: true; spacing: 1
                            Text { text: /\.conf$/i.test(root.exported) ? "exported — copy it to ~/.config/pipewire/pipewire.conf.d/ and restart pipewire"
                                                                        : "exported"
                                color: theme.good; font.pixelSize: 11; font.family: Tok.mono; font.bold: true }
                            Text { Layout.fillWidth: true; elide: Text.ElideMiddle; text: root.exported
                                color: theme.sub; font.pixelSize: 10; font.family: Tok.mono } }
                        IconBtn { icon: "close"; onTapped: root.exported = "" }
                    }
                }

                // ---------------- footer ----------------
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text {
                        // The one sentence that differs most between the backends: on the DAC
                        // you hear every drag, in software you hear nothing until you apply.
                        text: root.sw
                              ? (root.swInfo.sink_present
                                 ? "drag graph points · scroll = Q · nothing is audible until you apply · select “Universal EQ” as your output"
                                 : "drag graph points · scroll = Q · these filters run in pipewire — apply to create the output and hear them")
                              : "drag graph points · scroll = Q · new to this? tap “how to tune” · edits are live, save to keep them after unplug"
                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                        Layout.fillWidth: true; elide: Text.ElideRight }
                    TextBtn {
                        visible: root.sw && root.swInfo.installed
                        label: "remove"; icon: "delete"; enabled: !root.swBusy
                        onTapped: root.swRemove()
                    }
                    TextBtn { label: "import"; icon: "folder_open"; enabled: root.ready; onTapped: root.browse("import") }
                    TextBtn { label: "export"; icon: "save_as"; enabled: root.ready; onTapped: root.browse("export") }
                    // "reload" re-reads the DAC (truth). "revert" undoes live edits back to
                    // the last saved state — re-reading can't do that, since the DSP reports
                    // what we wrote, not what flash holds.
                    TextBtn { label: "revert"; icon: "undo"; enabled: root.ready && root.dirty && root.pristine !== null; onTapped: root.revert() }
                    TextBtn { label: "reload"; icon: "sync"; enabled: root.ready; onTapped: root.refresh() }
                    // Same button, different commit. On the DAC it burns the live state
                    // into flash; in software it renders the graph and reloads the sink,
                    // which is the first moment any of it becomes audible.
                    TextBtn {
                        label: root.sw ? (root.swBusy ? "applying…"
                                          : root.swInfo.installed ? "apply" : "create + apply")
                                       : "save to flash"
                        icon: root.sw ? "play_arrow" : "save"
                        primary: true
                        enabled: root.ready && !root.swBusy
                        onTapped: root.saveFlash()
                    }
                }
            }

            // ---------------- first-run: create the virtual output ----------------
            // Writing to your pipewire config and starting a service is not something to
            // do silently, so the first apply asks. It is genuinely low-impact — the
            // filter-chain daemon adds the sink without the main pipewire restarting —
            // and saying so is the difference between an informed yes and a shrug.
            Rectangle {
                visible: root.swConfirm
                anchors.fill: parent; radius: Tok.rCard
                color: theme.a(theme.bg, 0.97); border.width: 1; border.color: theme.a(theme.iris, 0.34)
                MouseArea { anchors.fill: parent }
                ColumnLayout {
                    anchors.centerIn: parent; width: 560; spacing: 14
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Sym { text: "speaker_group"; sz: 24; color: theme.iris }
                        Text { text: "Create the software EQ output?"; color: theme.text
                            font.pixelSize: 18; font.family: Tok.mono; font.bold: true }
                    }
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: "There's no Moondrop DAC to run these filters on, so they'll run in pipewire "
                            + "instead — which works on anything: your speakers, another brand's DAC, bluetooth.\n\n"
                            + "This writes one config file and starts a service:\n"
                            + "    ~/.config/pipewire/filter-chain.conf.d/99-hub-moon-eq.conf\n"
                            + "    systemctl --user start filter-chain.service\n\n"
                            + "A “Universal EQ” output appears, and you pick it as your output device. Your "
                            + "main pipewire is NOT restarted, so nothing playing right now is interrupted. "
                            + "Undo it any time with “remove”."
                        color: theme.sub; font.pixelSize: 11; font.family: Tok.mono; lineHeight: 1.4
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Item { Layout.fillWidth: true }
                        TextBtn { label: "cancel"; icon: "close"; onTapped: root.swConfirm = false }
                        TextBtn { label: "create it"; icon: "check"; primary: true
                                  onTapped: root.swCommit() }
                    }
                }
            }

            // ---------------- community preset browser ----------------
            Rectangle {
                id: hubBrowser
                visible: root.hubOpen; anchors.fill: parent; radius: Tok.rCard
                color: theme.a(theme.bg, 0.985); border.width: 1; border.color: theme.a(theme.iris, 0.34)
                MouseArea { anchors.fill: parent }   // swallow clicks

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 22; spacing: 11

                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Sym { text: "groups"; sz: 22; color: theme.iris }
                        Text { text: "Community presets"; color: theme.text
                            font.pixelSize: 19; font.family: Tok.mono; font.bold: true }
                        Text {
                            text: root.hubState === "ok"
                                  ? (root.hubTotal > root.hubList.length
                                     ? ("· " + root.hubList.length + " of " + root.hubTotal + " · most downloaded first")
                                     : ("· " + root.hubTotal + " for this device family"))
                                  : "· from hub.moondroplab.tech"
                            color: theme.faint; font.pixelSize: 11; font.family: Tok.mono
                            Layout.fillWidth: true; elide: Text.ElideRight
                        }
                        IconBtn { icon: "refresh"; onTapped: { root.hubState = "loading"
                            hubProc.command = ["python3", root.pyScript, "--presets", "--pid", root.hubPid,
                                               "--limit", "200", "--refresh"]
                                .concat(root.hubQuery.trim() !== "" ? ["--search", root.hubQuery.trim()] : []);
                            hubProc.running = true } }
                        IconBtn { icon: "close"; onTapped: root.hubOpen = false }
                    }

                    // search — typing filters the whole library, not just what's listed
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                        color: theme.a(theme.line, 0.4)
                        border.width: 1; border.color: theme.a(theme.iris, hubSearch.activeFocus ? 0.5 : 0.16)
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                            Sym { text: "search"; sz: 15; color: theme.faint }
                            TextInput {
                                id: hubSearch
                                Layout.fillWidth: true
                                text: root.hubQuery
                                onTextChanged: root.hubQuery = text
                                color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                selectByMouse: true; clip: true
                                focus: root.hubOpen
                                Keys.onEscapePressed: { if (text !== "") text = ""; else root.hubOpen = false }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: hubSearch.text === ""
                                    text: "search by name, author or description…"
                                    color: theme.faint; font.pixelSize: 12; font.family: Tok.mono
                                }
                            }
                            Sym { text: "close"; sz: 14; color: theme.faint; visible: hubSearch.text !== ""
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: hubSearch.text = "" } }
                        }
                    }

                    // states: loading / error / empty / list
                    Text {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: root.hubState !== "ok"
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        wrapMode: Text.WordWrap
                        text: root.hubState === "loading"
                              ? "fetching the library…\nthe first fetch pulls the whole index (a few MB); it's cached after that"
                              : root.hubState === "error" ? ("couldn't load the library\n" + root.hubError)
                              : ""
                        color: root.hubState === "error" ? theme.bad : theme.faint
                        font.pixelSize: 12; font.family: Tok.mono; lineHeight: 1.4
                    }
                    Text {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: root.hubState === "ok" && root.hubList.length === 0
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        text: "nothing matches “" + root.hubQuery + "”"
                        color: theme.faint; font.pixelSize: 12; font.family: Tok.mono
                    }

                    // ---- preview: what the selected curve actually does ----
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: root.hubSel !== "" ? 186 : 0
                        visible: root.hubSel !== "" && root.hubState === "ok"
                        radius: Tok.r; clip: true
                        color: theme.a(theme.panel, 0.6)
                        border.width: 1; border.color: theme.a(theme.iris, 0.14)
                        Behavior on implicitHeight { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 9; spacing: 5
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight; maximumLineCount: 1
                                    text: root.hubSelTitle
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true
                                }
                                // legend, same names the official uses
                                Rectangle { implicitWidth: 9; implicitHeight: 2; color: "#c86fd0" }
                                Text { text: "Flat"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono }
                                Rectangle { implicitWidth: 9; implicitHeight: 2; color: theme.bad; Layout.leftMargin: 4 }
                                Text { text: "Flat (Equalized)"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono }
                                // the official's eye: does the drawn level include pre-gain
                                Rectangle {
                                    Layout.leftMargin: 6
                                    implicitWidth: 26; implicitHeight: 18; radius: Tok.r
                                    color: preEye.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                    Sym { anchors.centerIn: parent; sz: 12
                                        text: root.hubPreShowPre ? "visibility" : "visibility_off"
                                        color: root.hubPreShowPre ? theme.frost : theme.faint }
                                    MouseArea { id: preEye; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.hubPreShowPre = !root.hubPreShowPre }
                                }
                                Text {
                                    text: "pre " + root.pregain.toFixed(1) + " dB"
                                    color: theme.faint; font.pixelSize: 9; font.family: Tok.mono
                                }
                            }
                            RespChart {
                                id: preChart
                                Layout.fillWidth: true; Layout.fillHeight: true
                                bands: root.hubPreview
                                pre: root.pregain
                                withPre: root.hubPreShowPre
                                opacity: root.hubPreLoading ? 0.35 : 1
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                            }
                        }
                        Text {
                            anchors.centerIn: parent; visible: root.hubPreLoading
                            text: "…"; color: theme.faint; font.pixelSize: 20; font.family: Tok.mono
                        }
                        // A community curve is bands only — it says nothing about headroom.
                        // With YOUR pre-gain applied, this is what it would actually output.
                        Text {
                            anchors.right: parent.right; anchors.bottom: parent.bottom
                            anchors.rightMargin: 10; anchors.bottomMargin: 18
                            visible: root.hubPreview.length > 0 && root.hubPreOvershoot > 0.05
                            text: "clips by " + root.hubPreOvershoot.toFixed(1) + " dB at this pre-gain"
                            color: theme.warn; font.pixelSize: 9; font.family: Tok.mono
                        }
                    }

                    ListView {
                        id: hubView
                        visible: root.hubState === "ok" && root.hubList.length > 0
                        Layout.fillWidth: true; Layout.fillHeight: true
                        model: root.hubList
                        clip: true; spacing: 5

                        // ---- back to top ----
                        // 200 rows deep, the search box is a long way up.
                        Rectangle {
                            parent: hubView
                            // Left, not right: the right edge is a column of apply buttons,
                            // and floating a pill over the consequential control is asking
                            // for a mis-aimed click. Over a row's title costs nothing.
                            anchors.left: parent.left; anchors.bottom: parent.bottom
                            anchors.leftMargin: 6; anchors.bottomMargin: 6
                            z: 5
                            visible: hubView.contentY > 120
                            opacity: visible ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                            implicitWidth: 92; implicitHeight: 26; radius: Tok.r
                            color: topMa.containsMouse ? theme.iris : theme.a(theme.bg, 0.94)
                            border.width: 1; border.color: theme.a(theme.iris, 0.45)
                            RowLayout {
                                anchors.centerIn: parent; spacing: 5
                                Sym { text: "arrow_upward"; sz: 13
                                    color: topMa.containsMouse ? theme.bg : theme.frost }
                                Text { text: "top"; font.pixelSize: 10; font.family: Tok.mono; font.bold: true
                                    color: topMa.containsMouse ? theme.bg : theme.frost }
                            }
                            MouseArea {
                                id: topMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: hubView.positionViewAtBeginning()
                            }
                        }
                        delegate: Rectangle {
                            id: hp
                            required property var modelData
                            width: hubView.width; implicitHeight: 46; radius: Tok.r
                            // These rows hold arbitrary text from strangers. The script
                            // already flattens whitespace, but clip is the backstop that
                            // keeps one weird row from painting over its neighbours.
                            clip: true
                            readonly property bool picked: root.hubSel === hp.modelData.uuid
                            color: hp.picked ? theme.a(theme.iris, 0.22)
                                 : hpMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.28)
                            border.width: 1
                            border.color: theme.a(theme.iris, hp.picked ? 0.6 : hpMa.containsMouse ? 0.4 : 0.1)

                            // FIRST child on purpose. Later siblings receive input first in
                            // QML, so this has to be declared before the row content or it
                            // sits on top of the apply button and eats its clicks.
                            MouseArea {
                                id: hpMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.hubShow(hp.modelData)
                            }

                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 1
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        maximumLineCount: 1
                                        text: hp.modelData.title !== "" ? hp.modelData.title : "(untitled)"
                                        color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                    }
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        maximumLineCount: 1
                                        text: hp.modelData.author
                                              + (hp.modelData.desc !== "" ? "  ·  " + hp.modelData.desc : "")
                                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                                    }
                                }
                                RowLayout {
                                    spacing: 4
                                    Sym { text: "download"; sz: 12; color: theme.faint }
                                    Text { text: "" + hp.modelData.downloads; color: theme.frost
                                        font.pixelSize: 10; font.family: Tok.mono }
                                    Sym { text: "favorite"; sz: 12; color: theme.faint; Layout.leftMargin: 6 }
                                    Text { text: "" + hp.modelData.likes; color: theme.frost
                                        font.pixelSize: 10; font.family: Tok.mono }
                                }
                                // Apply is its own target. Clicking the row only draws the
                                // curve; writing 8 bands to the DAC should take aim.
                                Rectangle {
                                    implicitWidth: 62; implicitHeight: 24; radius: Tok.r
                                    color: root.hubBusy === hp.modelData.uuid ? theme.a(theme.iris, 0.3)
                                         : applyMa.containsMouse ? theme.iris : theme.a(theme.line, 0.5)
                                    border.width: 1
                                    border.color: theme.a(theme.iris, applyMa.containsMouse ? 0.7 : 0.4)
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.hubBusy === hp.modelData.uuid ? "…" : "apply"
                                        color: applyMa.containsMouse && root.hubBusy === "" ? theme.bg : theme.sub
                                        font.pixelSize: 10; font.family: Tok.mono; font.bold: true
                                    }
                                    MouseArea {
                                        id: applyMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: root.hubBusy === ""
                                        onClicked: root.hubApply(hp.modelData)
                                    }
                                }
                            }
                        }
                    }

                    // The one thing a user can't see from a title: these are strangers'
                    // curves for a whole device family, not vendor-checked tunings.
                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: "Click a preset to see its curve — nothing touches the DAC until you press apply. "
                            + "Applying overwrites all " + root.bandCount + " bands live, and stays out of flash "
                            + "until you save. Pre-gain is left alone — published presets don't carry one."
                        color: theme.faint; font.pixelSize: 10; font.family: Tok.mono; lineHeight: 1.3
                    }
                }
            }

            // ---------------- in-panel file browser ----------------
            Rectangle {
                id: fileBrowser
                visible: root.fileOpen; anchors.fill: parent; radius: Tok.rCard
                color: theme.a(theme.bg, 0.985); border.width: 1; border.color: theme.a(theme.iris, 0.34)
                MouseArea { anchors.fill: parent }   // swallow clicks

                FolderListModel {
                    id: folderModel
                    folder: root.fileDir === "" ? "" : "file://" + root.fileDir
                    showDirs: true
                    showFiles: true
                    showDotAndDotDot: false
                    showHidden: false
                    sortField: FolderListModel.Type      // folders first, then name
                    // Import reads AutoEQ/REW text or an exported backup; export lists
                    // what we'd write, so you can see what's already there.
                    nameFilters: root.fileMode === "import" ? ["*.txt", "*.json"] : ["*.json", "*.conf"]
                }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 22; spacing: 11

                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Sym { text: root.fileMode === "import" ? "folder_open" : "save_as"; sz: 22; color: theme.iris }
                        Text { text: root.fileMode === "import" ? "Import EQ" : "Export EQ"
                            color: theme.text; font.pixelSize: 19; font.family: Tok.mono; font.bold: true }
                        Text { text: root.fileMode === "import" ? "· AutoEQ/REW .txt or a .json backup" : "· writes to the folder you're in"
                            color: theme.faint; font.pixelSize: 11; font.family: Tok.mono }
                        Item { Layout.fillWidth: true }
                        IconBtn { icon: "close"; onTapped: root.fileOpen = false }
                    }

                    // shortcuts + current path
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        IconBtn { icon: "arrow_upward"; onTapped: root.goUp() }
                        Repeater {
                            model: [ { nm: "Home", d: root.homeDir },
                                     { nm: "Downloads", d: root.homeDir + "/Downloads" },
                                     { nm: "Documents", d: root.homeDir + "/Documents" } ]
                            delegate: Rectangle {
                                id: sc
                                required property var modelData
                                implicitHeight: 24; implicitWidth: scT.width + 18; radius: Tok.r
                                color: scMa.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.3)
                                border.width: 1; border.color: theme.a(theme.iris, 0.14)
                                Text { id: scT; anchors.centerIn: parent; text: sc.modelData.nm; color: theme.sub; font.pixelSize: 10; font.family: Tok.mono }
                                MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.fileDir = sc.modelData.d }
                            }
                        }
                        Text { Layout.fillWidth: true; elide: Text.ElideLeft; text: root.fileDir
                            color: theme.frost; font.pixelSize: 11; font.family: Tok.mono }
                    }

                    // listing
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; radius: Tok.r
                        color: theme.a(theme.panel, 0.5); border.width: 1; border.color: theme.a(theme.iris, 0.12); clip: true
                        ListView {
                            id: fileList
                            anchors.fill: parent; anchors.margins: 6; spacing: 2
                            model: folderModel
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Rectangle {
                                id: row
                                required property string fileName
                                required property string filePath
                                required property bool fileIsDir
                                width: fileList.width; height: 30; radius: Tok.r
                                color: rowMa.containsMouse ? theme.a(theme.iris, 0.16) : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; spacing: 9
                                    Sym { text: row.fileIsDir ? "folder" : (/\.json$/i.test(row.fileName) ? "data_object" : "description")
                                        sz: 15; color: row.fileIsDir ? theme.iris : theme.faint }
                                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: row.fileName
                                        color: row.fileIsDir ? theme.text : theme.sub; font.pixelSize: 12; font.family: Tok.mono }
                                    Text { visible: !row.fileIsDir && root.fileMode === "import"
                                        text: /\.json$/i.test(row.fileName) ? "backup" : "AutoEQ/REW"
                                        color: theme.faint; font.pixelSize: 9; font.family: Tok.mono }
                                }
                                MouseArea {
                                    id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (row.fileIsDir) root.fileDir = row.filePath;
                                        else if (root.fileMode === "import") root.importFile(row.filePath);
                                        else root.exportName = row.fileName;   // export: click to overwrite
                                    }
                                }
                            }
                        }
                        Text {
                            anchors.centerIn: parent; visible: folderModel.count === 0
                            text: root.fileMode === "import" ? "no .txt or .json files here" : "no existing exports here"
                            color: theme.faint; font.pixelSize: 11; font.family: Tok.mono
                        }
                    }

                    // export controls
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8; visible: root.fileMode === "export"
                        Text { text: "FORMAT"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                        Repeater {
                            model: [ { k: "json",     nm: "JSON backup",  d: "restore later with import" },
                                     { k: "pipewire", nm: "PipeWire EQ",  d: "software EQ for any output device" } ]
                            delegate: Rectangle {
                                id: fmt
                                required property var modelData
                                readonly property bool on: root.exportFmt === fmt.modelData.k
                                implicitHeight: 30; implicitWidth: fmtT.width + 20; radius: Tok.r
                                color: fmt.on ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.28)
                                border.width: 1; border.color: theme.a(theme.iris, fmt.on ? 0.5 : 0.14)
                                Text { id: fmtT; anchors.centerIn: parent; text: fmt.modelData.nm
                                    color: fmt.on ? theme.frost : theme.sub; font.pixelSize: 10; font.family: Tok.mono; font.bold: fmt.on }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.exportFmt = fmt.modelData.k;
                                        root.exportName = fmt.modelData.k === "pipewire" ? "moondrop-eq.conf" : "moondrop-eq.json";
                                    } }
                            }
                        }
                        Text { text: root.exportFmt === "pipewire" ? "runs the same curves in software — works with any DAC/speakers"
                                                                   : "a full device snapshot you can re-import"
                            color: theme.faint; font.pixelSize: 10; font.family: Tok.mono
                            Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8; visible: root.fileMode === "export"
                        Text { text: "FILE"; color: theme.faint; font.pixelSize: 9; font.family: Tok.mono; font.bold: true; font.letterSpacing: 1 }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                            color: theme.a(theme.line, 0.3); border.width: 1
                            border.color: nameIn.activeFocus ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
                            TextInput {
                                id: nameIn
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                text: root.exportName
                                onTextChanged: root.exportName = text
                                color: theme.text; font.pixelSize: 12; font.family: Tok.mono
                                selectByMouse: true; clip: true
                                onAccepted: root.doExport()
                            }
                        }
                        TextBtn { label: "export here"; icon: "save"; primary: true
                            enabled: root.ready && root.exportName.trim() !== ""
                            onTapped: root.doExport() }
                    }
                }
            }

            // ---------------- in-panel tuning guide ----------------
            Rectangle {
                visible: root.helpOpen; anchors.fill: parent; radius: Tok.rCard
                color: theme.a(theme.bg, 0.985); border.width: 1; border.color: theme.a(theme.iris, 0.34)
                MouseArea { anchors.fill: parent }   // swallow clicks
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 22; spacing: 12
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "school"; sz: 22; color: theme.iris }
                        Text { text: "How to tune"; color: theme.text; font.pixelSize: 19; font.family: Tok.mono; font.bold: true }
                        Item { Layout.fillWidth: true }
                        IconBtn { icon: "close"; onTapped: root.helpOpen = false }
                    }
                    Flickable {
                        id: helpFlick
                        Layout.fillWidth: true; Layout.fillHeight: true; contentHeight: helpCol.height; clip: true; boundsBehavior: Flickable.StopAtBounds
                        ColumnLayout { id: helpCol; width: helpFlick.width; spacing: 13

                            // ---- the one-paragraph version ----
                            Rectangle {
                                Layout.fillWidth: true; radius: Tok.r
                                color: theme.a(theme.iris, 0.09); border.width: 1; border.color: theme.a(theme.iris, 0.24)
                                implicitHeight: introRow.height + 26
                                RowLayout {
                                    id: introRow
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                    anchors.leftMargin: 14; anchors.rightMargin: 14; anchors.topMargin: 13; spacing: 13
                                    Sym { text: "graphic_eq"; sz: 22; color: theme.iris; Layout.alignment: Qt.AlignTop }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 4
                                        Text { text: "EQ is just “make some frequencies louder or quieter”."
                                            color: theme.text; font.pixelSize: 14; font.family: Tok.mono; font.bold: true }
                                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: theme.sub; font.pixelSize: 12; font.family: Tok.mono; lineHeight: 1.35
                                            text: "Each of the " + root.bandCount + " columns is one filter. Give it a shape, a frequency, how much (gain) and how wide (Q). "
                                                  + "Drag a dot on the graph for big moves, use the column steppers for fine ones, scroll on the graph to change Q. "
                                                  + "Changes are heard instantly — nothing is permanent until you hit save to flash." }
                                    }
                                }
                            }

                            // ---- rules ----
                            HelpHead { title: "THE FOUR RULES"; note: "if you read nothing else" }
                            GridLayout {
                                columns: 2; columnSpacing: 11; rowSpacing: 8; Layout.fillWidth: true
                                RuleCard { n: 1; title: "Cut, don’t boost"; body: "Lowering a problem is cleaner than raising everything around it, and it can never clip. Boost only to add something that truly isn’t there." }
                                RuleCard { n: 2; title: "Small moves"; body: "±2–3 dB is already a lot. If you’re reaching for ±8 dB you’re usually on the wrong band — or fighting the headphones." }
                                RuleCard { n: 3; title: "Mind headroom"; body: "Every boost eats headroom. Set pre-gain to roughly minus your biggest boost so peaks don’t clip." }
                                RuleCard { n: 4; title: "A/B constantly"; body: "Flip a band to “—” and back. If you can’t clearly hear it helping, you don’t need it." }
                            }

                            // ---- shapes, with real curves ----
                            HelpHead { title: "FILTER SHAPES"; note: "click a column’s type to cycle" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: [
                                        { ab: "PK", nm: "Peaking",    band: { type: "peaking",    frequency: 1000, gain: 9, q: 1.1 },  d: "A bell that lifts or dips around one frequency. Your workhorse — use it for almost everything." },
                                        { ab: "LS", nm: "Low shelf",  band: { type: "low_shelf",  frequency: 250,  gain: 8, q: 0.7 },  d: "Raises or drops everything below the point. The natural way to add overall bass warmth." },
                                        { ab: "HS", nm: "High shelf", band: { type: "high_shelf", frequency: 4000, gain: 8, q: 0.7 },  d: "Raises or drops everything above the point. Adds “air”, or tames a bright headphone." },
                                        { ab: "LP", nm: "Low-pass",   band: { type: "low_pass",   frequency: 3000, gain: 0, q: 0.7 },  d: "A cliff: removes everything above the point. Rarely wanted for music." },
                                        { ab: "HP", nm: "High-pass",  band: { type: "high_pass",  frequency: 400,  gain: 0, q: 0.7 },  d: "A cliff: removes everything below the point. At ~30 Hz it kills subsonic rumble." },
                                        { ab: "—",  nm: "Off",        band: null,                                                       d: "Band does nothing. Use it to A/B a filter." }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; radius: Tok.r; implicitHeight: 42
                                        color: theme.a(theme.line, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 12; spacing: 11
                                            Rectangle {
                                                implicitWidth: 34; implicitHeight: 20; radius: Tok.r
                                                color: theme.a(theme.iris, 0.14); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                                                Text { anchors.centerIn: parent; text: modelData.ab; color: theme.text; font.pixelSize: 10; font.family: Tok.mono; font.bold: true }
                                            }
                                            MiniCurve { band: modelData.band; stroke: theme.frost }
                                            Text { text: modelData.nm; color: theme.text; font.pixelSize: 12; font.family: Tok.mono; font.bold: true; Layout.preferredWidth: 82 }
                                            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: modelData.d; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono }
                                        }
                                    }
                                }
                            }

                            // ---- regions: colours come straight from the graph's own zone table ----
                            HelpHead { title: "WHAT EACH REGION DOES"; note: "same colours as the graph" }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                Repeater {
                                    model: [
                                        { i: 0, d: "rumble & weight — felt more than heard" },
                                        { i: 1, d: "punch & fullness; too much and it booms" },
                                        { i: 2, d: "warmth & body; excess turns to mud" },
                                        { i: 3, d: "most instruments and voices; boxy if piled up" },
                                        { i: 4, d: "attack & clarity — and ear fatigue if harsh" },
                                        { i: 5, d: "detail & edge; sibilance (“sss”) starts here" },
                                        { i: 6, d: "sparkle, cymbals, sense of openness" }
                                    ]
                                    delegate: RowLayout {
                                        required property var modelData
                                        readonly property var rd: root.regionDefs[modelData.i]
                                        Layout.fillWidth: true; spacing: 10
                                        Rectangle { implicitWidth: 4; implicitHeight: 15; radius: 2; color: rd.c }
                                        Text { text: rd.n; color: rd.c; font.pixelSize: 11; font.family: Tok.mono; font.bold: true; Layout.preferredWidth: 84 }
                                        Text { text: root.fmtHz(rd.f1) + "–" + root.fmtHz(rd.f2); color: theme.faint; font.pixelSize: 11; font.family: Tok.mono; Layout.preferredWidth: 74 }
                                        Text { Layout.fillWidth: true; text: modelData.d; color: theme.sub; font.pixelSize: 11; font.family: Tok.mono }
                                    }
                                }
                            }

                            // ---- recipes, each drawn as the curve it actually makes ----
                            HelpHead { title: "QUICK RECIPES"; note: "starting points — then trust your ears" }
                            GridLayout {
                                columns: 2; columnSpacing: 11; rowSpacing: 6; Layout.fillWidth: true
                                Repeater {
                                    model: [
                                        { nm: "More bass, clean",   band: { type: "low_shelf",  frequency: 90,    gain: 3,  q: 0.7 } },
                                        { nm: "Kill boom / mud",    band: { type: "peaking",    frequency: 200,   gain: -3, q: 1.2 } },
                                        { nm: "Clearer vocals",     band: { type: "peaking",    frequency: 400,   gain: -3, q: 1.0 } },
                                        { nm: "Less harsh",         band: { type: "peaking",    frequency: 3200,  gain: -3, q: 1.4 } },
                                        { nm: "Tame “sss”",         band: { type: "peaking",    frequency: 7000,  gain: -4, q: 4.0 } },
                                        { nm: "More air / sparkle", band: { type: "high_shelf", frequency: 10000, gain: 3,  q: 0.7 } }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true; Layout.preferredWidth: 1; radius: Tok.r; implicitHeight: 40
                                        color: theme.a(theme.line, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.1)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 10; spacing: 9
                                            MiniCurve { band: modelData.band; span: 6; stroke: theme.iris }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 0
                                                Text { text: modelData.nm; color: theme.text; font.pixelSize: 11; font.family: Tok.mono; font.bold: true }
                                                Text { color: theme.frost; font.pixelSize: 10; font.family: Tok.mono
                                                    text: root.typeName(modelData.band.type) + " · " + root.fmtHz(modelData.band.frequency) + " Hz · "
                                                          + (modelData.band.gain >= 0 ? "+" : "") + modelData.band.gain + " dB · Q" + modelData.band.q }
                                            }
                                        }
                                    }
                                }
                            }

                            // ---- the things people actually get stuck on ----
                            HelpHead { title: "GOOD TO KNOW" }

                            NoteCard {
                                icon: "hearing_disabled"; tint: theme.warn
                                title: "NOT HEARING YOUR CHANGES?"
                                body: "On the DAWN PRO2 the EQ is switched on at the hardware — press both volume buttons together to toggle between the default (no EQ) mode and custom EQ. Edits here only change the sound in custom EQ mode.\n\n"
                                      + "The DAC never reports which mode it is in (every register reads identical either way), so nothing on this screen can tell you. Your ears are the only indicator."
                            }

                            NoteCard {
                                icon: "bolt"
                                title: "SHORTCUT — DON’T WANT TO TUNE BY EAR?"
                                body: "The PRESETS row along the top fills every band with a known-good starting shape (and sets a sensible pre-gain) — tap one, then nudge it to taste. Nothing is permanent until you save to flash.\n\n"
                                      + "Better still, grab a measured preset for your exact headphones from the AutoEQ project — search “AutoEQ <model> ParametricEQ” — then import it. It sets every band and the pre-gain for you:\n\n"
                                      + "python3 ~/.config/quickshell/sea-shell/moondrop_control.py --import-rew ParametricEQ.txt"
                            }

                            NoteCard {
                                icon: "speaker_group"
                                title: "WANT THIS EQ ON A NON-MOONDROP DEVICE?"
                                body: "The bands above run on the DAC's own chip, so they only exist on supported Moondrop hardware. The same curves can run in software instead, through PipeWire — any output: another brand's DAC, laptop speakers, Bluetooth.\n\n"
                                      + "This panel already does it. With no DAC connected it switches to software by itself; with one connected, use the DAC | software toggle up in the header. Press apply and pick the “Universal EQ” output — your main pipewire is never restarted, so nothing playing is interrupted.\n\n"
                                      + "Two differences, both in software's favour: floating-point biquads have no Q2.30 limit, so the shelf gains the DAC has to refuse work fine there; and it isn't pinned to 96 kHz. The one cost is that nothing is audible until you press apply.\n\n"
                                      + "From a terminal, the same thing without this panel:\n"
                                      + "python3 ~/.config/quickshell/sea-shell/sea-eq.py --apply --from-rew ParametricEQ.txt"
                            }

                            NoteCard {
                                icon: "help"; tint: theme.faint
                                title: "PRESETS vs DEVICE SLOT — NOT THE SAME THING"
                                body: "PRESETS (top row) are just starting shapes this panel writes into your bands — they’re ours, not the DAC’s. DEVICE SLOT is a number the DAC itself reports for which of its internal profiles is selected. Tapping a preset never changes the slot."
                            }

                            NoteCard {
                                icon: "block"; tint: theme.bad
                                title: "WHY A SLIDER SOMETIMES STOPS EARLY"
                                body: "The DAC stores filters as fixed-point numbers (Q2.30) that only span ±2.0, and some filters need coefficients outside that — high shelves above roughly +5 dB, or anything with a big boost at high frequency and low Q.\n\n"
                                      + "Rather than let the firmware wrap the number and play a curve that isn’t the one drawn, the panel stops the gain at the highest value that fits and tags the column “limit”. Widen the band (lower Q), move it, or ask for less."
                            }

                            NoteCard {
                                icon: "info"; tint: theme.faint
                                title: "PRESET SLOT?"
                                body: "Whatever slot the DAC reports — read from hardware, not chosen by the panel. It is not a readout of whether the EQ is on: firmware 1.5 reports the same slot in both modes. Informational only; change it only if you know your device’s preset layout."
                            }

                            Item { Layout.preferredHeight: 4 }
                        }
                    }
                }
            }
        }
    }
}
