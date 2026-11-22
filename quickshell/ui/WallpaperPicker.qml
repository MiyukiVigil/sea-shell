// sea-shell — wallpaper picker (SUPER+SHIFT+W)
//
// The surface, separate from wallpaper.qml, which is the one-line program that runs it.
//
// IT LIVED IN THE BAR FOR AN AFTERNOON, and the reason it does not any more is worth keeping.
// Constructing QtMultimedia's MediaPlayer costs 642ms of one-time plugin initialisation PER
// PROCESS — 0ms for every player built after it — so while the picker auto-played whatever you
// arrowed onto, being a fresh process meant never having a warm decoder. Living inside the bar
// fixed that, at 25ms an open against 216.
//
// It also meant the picker stopped being reset by exiting, and three separate bugs came out of
// that in an afternoon: a search that came back next time, a preview that stayed blank, a commit
// animation that ran a second time with nothing in it. Then motion became opt-in (see
// wantMotion) and nothing built a decoder unless asked, which took the open to 216ms on its own
// and left the residency buying 191ms for three lifecycle bugs. So it is a process again, and
// its state is reset the way it always was: by ending.
//
// The `showing`/reset()/park() machinery below is what remains of that, and it stays: it is what
// lets wallpaper.qml drive this as a component, and it is honest about what has to be true for
// the surface to be reopened rather than merely relaunched.
//
// Reads the wallpaper folder (appearance.json `wpDir`) and hands the pick to
// sea-wallpaper-set.sh — the one script that knows what applying a wallpaper consists of.
// ← → or drag choose · type to search · enter apply · tab filter · ctrl+m match · esc back.
//
// THE IDEA.  The old picker put a 900×620 card over a 55%-black scrim and drew every
// wallpaper as a 220px landscape crop inside it — so you chose a wallpaper by looking
// at twelve postage stamps of it, and only found out what it actually looked like on
// your monitor after committing.  Here the picker *is* the wallpaper: the focused one
// fills the screen at full size, moving wallpapers actually play, and the rail along
// the bottom is the only chrome.  You are always looking at the thing you are choosing,
// at the size and the speed you will get it.
//
// THE SEA.  The rail floats on a waterline along the bottom of the screen. Each frame bobs a
// little, out of step with its neighbours, and throws a rippled reflection into the water under
// it; the water is the ground the readout sits on, so the old legibility gradient became a sea.
// It is a live one: light comes down through it, the crest glints, bubbles rise, the frame you
// land on splashes, the frames throw a wake while the rail moves, and a fish swims along under
// them to wherever you are in the folder.
//
// THE COMMIT is the tide. The frame you chose sinks into the water, a swell rises up the screen
// until the sea covers it, and as it drains away it leaves the new wallpaper behind. The daemon
// runs its own transition under the water, so the flourish costs no time the switch was not
// already going to spend, and what the ebb uncovers is the full-bleed preview that was behind
// the picker the whole time. (It used to be a cartridge going into a console, which was a
// fine machine but not this shell's sea.)
//
// The frames keep their own aspect ratio and share a baseline, so a folder of portrait
// and landscape wallpapers packs into a skyline rather than being cropped to a uniform
// grid. Falloff away from centre is scale and opacity only. There is no perspective and
// no shadow here: this is a rail seen straight on, not a Cover Flow.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Widgets
import QtQuick
import QtQuick.Shapes
import QtMultimedia

Item {
    id: root

    // Driven by wallpaper.qml, which sets it true on start and quits when it goes false. NOT
    // called `shown`: that name is already the filtered list below.
    property bool showing: false

    // ONE SCAN AT CONSTRUCTION, and then one per open. The bar builds this component a few
    // seconds after login and never destroys it, so the scan that decides whether the folder
    // holds anything moving can happen there — which is the whole reason the video backend can
    // be warmed at login instead of on your first open. Cleared by the index itself, so the
    // process stops as soon as it has answered.
    property bool priming: true
    // ---------- motion is opt-in ----------
    // A moving wallpaper does NOT start playing because you arrowed onto it. That was the old
    // behaviour and it is why this surface could stutter: every step tore a decoder down and
    // built another, and the first one in a session dragged QtMultimedia's 642ms of plugin
    // initialisation in behind it — 180MB of player held for a preview nobody asked to see.
    //
    // Now the still is the preview, always, and motion is a thing you ask for. The cost lands
    // only when you have decided you want it, which is also the only moment it is worth paying.
    property bool wantMotion: false
    function togglePlay() {
        if (!root.item || !root.item.vid || root.committing) return;
        if (root.wantMotion) { root.wantMotion = false; preview.stopVideo(); return }
        root.wantMotion = true;
        preview.wantPath = root.item.path;
        if (preview.vid) preview.startWanted();
        else vidLoad.active = true;        // first time in this session: the 642ms, once, asked for
    }

    // Everything that has to be true for this to be a fresh picker. Exiting does all of it for
    // free today; this exists so reopening would too. The three view axes are the ones that
    // matter: they are ways of LOOKING at the folder for as long as the window is open, and a
    // picker that reopens holding last week's search is one you have to check before you trust.
    function reset() {
        root.filter = "all";
        root.collection = "";
        root.query = "";
        root.sort = "name";
        root.committing = false;
        root.importWanted = "";
        hold.stop(); insert.stop();
        win.phase = ""; win.entered = false;
        win.sink = 0; win.surge = 0; win.ebb = 0;
        preview.stopVideo();
        fadeOut.stop();
        win.contentItem.opacity = 1;
        root.applyFilter();
        root.startOnCurrent();
        preview.request();
        enter.restart();
    }
    onShowingChanged: root.showing ? root.reset() : root.park()

    // LEAVING IS A MOVE TOO. The surface used to be torn off the screen in a single frame — the
    // process ended, the layer surface went with it, and whatever had been behind the picker
    // snapped back into place. Over an empty desktop that is invisible, because what is revealed
    // is the wallpaper you were just looking at. Over an application it is a flash: a whole
    // window appearing at once where a full-screen image was.
    //
    // Not the window's own `opacity` — a PanelWindow has no such property, and asking for one is
    // a load error. contentItem is the item everything in here is parented to, so fading that
    // fades the picture, the sea and the rail together, and what comes up through it is the
    // desktop underneath.
    function leave() {
        if (fadeOut.running) return;
        fadeOut.start();
    }
    NumberAnimation {
        id: fadeOut
        target: win.contentItem; property: "opacity"
        to: 0; duration: 170; easing.type: Tok.mEase
        onFinished: root.showing = false
    }

    // Hidden. Everything that costs memory goes; the process is about to end anyway, but this
    // is what would have to happen first if it did not.
    function park() {
        hop.stop(); vidHop.stop(); hold.stop(); insert.stop(); enter.stop();
        preview.stopVideo();
        imgA.source = ""; imgB.source = ""; imgA.want = ""; imgB.want = "";
        vidLoad.active = false;
        win.entered = false;
    }

    // ---------- model ----------
    // Rows come from sea-wallpaper-index.py: path, bytes, width, height, poster, ms.
    // `aspect` is needed to lay the rail out, which is why it is read up front from
    // ffprobe rather than from each Image after it loads — by then the layout that
    // wanted it has already happened.
    property var papers: []
    property var shown: []
    property int cur: 0
    // Three axes, deliberately independent: WHAT KIND of wallpaper (this), WHICH FOLDER
    // (collection), and WHAT IT IS CALLED (query). Folding them into one control would
    // mean "stills" and "recent" could not both be true, which is a question people
    // actually have.
    property string filter: "all"          // all | stills | motion | recent
    readonly property var filters: ["all", "stills", "motion", "recent"]
    property string collection: ""         // "" = every collection
    property var collections: []           // subfolder names, in index order
    property string query: ""              // live name search — just start typing
    property var recents: []               // paths, most recently worn first
    // Not persisted, deliberately: the filter and the collection are not either. All three
    // are ways of LOOKING at the folder for as long as this window is open, and a picker
    // that reopens in a state you set last Tuesday is a picker you have to check.
    property string sort: "name"           // name | new
    readonly property var sorts: ["name", "new"]
    property bool committing: false

    // ---------- config ----------
    // Colours, fonts and UI scale all come from Tok, which is the single appearance.json
    // read for the whole shell. Only the keys this surface acts on are parsed again here.
    property bool matchColors: true
    property real wpDur: 1.0               // the daemon's transition length, in seconds

    // ONE script, not four. The picker used to write the config file, run the lock-screen
    // sync, run matugen and run the apply script itself — its own copy of a sequence the
    // cycle keybinds also had a copy of, which is exactly how the two drifted.
    property string setScript:       Qt.resolvedUrl("sea-wallpaper-set.sh").toString().replace("file://", "")
    property string indexScript:     Qt.resolvedUrl("sea-wallpaper-index.py").toString().replace("file://", "")

    // Where the wallpapers are. Shown in the header and in the empty state, both of which
    // used to say "~/Pictures/wallpapers" as a literal — so once the folder was
    // configurable they would have been confidently telling you about the wrong one.
    property string wpDir: "~/Pictures/wallpapers"

    Process {
        running: root.showing
        command: ["sh", "-c", "cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: {
            try {
                var j = JSON.parse(apOut.text);
                if (j.matugen !== undefined) root.matchColors = !!j.matugen;
                if (j.wpTransitionDur !== undefined) root.wpDur = Math.max(0.1, j.wpTransitionDur);
                if (j.wpDir !== undefined && ("" + j.wpDir).length) root.wpDir = "" + j.wpDir;
            } catch (e) {}
        } }
    }

    // The back stack sea-wallpaper-set.sh keeps, which is also the "recent" filter. Read
    // once at open: it only changes when a wallpaper is applied, and applying one closes
    // this window.
    Process {
        running: root.showing
        command: ["sh", "-c", "cat \"$HOME/.cache/sea-shell/wallhistory\" 2>/dev/null"]
        stdout: StdioCollector { id: histOut; onStreamFinished: {
            var out = [], lines = histOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i].trim();
                if (t.length && out.indexOf(t) < 0) out.push(t);
            }
            root.recents = out;
        } }
    }

    Process {
        id: index; running: root.showing || root.priming
        command: ["python3", root.indexScript]
        stdout: StdioCollector { id: ixOut; onStreamFinished: {
            var out = [];
            var lines = ixOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].split("\t");
                // `< 8`, not `!== 8`. The indexer has grown a column twice now (collection, then
                // mtime, then the full-resolution still) and each time an exact-length check
                // somewhere silently dropped every row — a folder of wallpapers reporting
                // itself empty. Extra columns are none of this parser's business.
                if (f.length < 8 || !f[0]) continue;
                var w = parseInt(f[2]) || 0, h = parseInt(f[3]) || 0;
                out.push({
                    path:   f[0],
                    name:   f[0].slice(f[0].lastIndexOf("/") + 1),
                    bytes:  parseInt(f[1]) || 0,
                    w: w, h: h,
                    // 16:9 is the honest default for a file nothing could measure — it is
                    // what a wallpaper folder is overwhelmingly made of, and a wrong guess
                    // only costs one mis-shaped frame in the rail.
                    aspect: (w > 0 && h > 0) ? (w / h) : (16 / 9),
                    poster: f[4],
                    ms:     parseInt(f[5]) || 0,
                    coll:   f[6] || "",
                    mtime:  parseInt(f[7]) || 0,
                    // The native-resolution still. The poster is 1280px, which is right for a
                    // rail thumbnail and visibly soft filling a 1080p screen — and this surface
                    // shows it full-screen for the ~400ms before the video starts.
                    full:   f.length > 8 ? (f[8] || "") : "",
                    vid:    f[4].length > 0
                });
            }
            root.papers = out;
            root.priming = false;

            var seen = {}, colls = [];
            for (var k = 0; k < out.length; k++) {
                var c = out[k].coll;
                if (c && !seen[c]) { seen[c] = true; colls.push(c) }
            }
            root.collections = colls;

            root.applyFilter();

            // A file that has just been imported is the one you want to be looking at, and
            // it outranks "open on whatever is already up" — which has already happened by
            // the time anything can be imported.
            if (root.importWanted.length) {
                var want = root.importWanted;
                root.importWanted = "";
                for (var m = 0; m < root.shown.length; m++) {
                    if (root.shown[m].path === want) {
                        root.cur = m;
                        rail.settle(false);
                        preview.request();
                        return;
                    }
                }
            }
            root.startOnCurrent();
        } }
    }

    // Open on the wallpaper that is actually up. The picker previews full-screen, so
    // landing on entry zero would replace what you are looking at with something else
    // before you have asked for anything — and "which of these is on right now" is the
    // first question the surface should already have answered.
    property string active: ""
    Process {
        running: root.showing
        command: ["sh", "-c", "cat \"$HOME/.config/sea-shell/wallpaper\" 2>/dev/null"]
        stdout: StdioCollector { id: curOut; onStreamFinished: {
            root.active = curOut.text.trim();
            root.startOnCurrent();
        } }
    }
    function startOnCurrent() {
        if (!root.active || !root.shown.length) return;
        for (var i = 0; i < root.shown.length; i++)
            if (root.shown[i].path === root.active) { root.cur = i; break }
        // Landing on the right entry is free and worth doing while hidden — it is what makes the
        // picker open ALREADY on the wallpaper you are wearing. Drawing it is not free.
        if (!root.showing) return;
        rail.settle(true);
        preview.request();
    }

    // ---------- selection ----------
    function applyFilter() {
        var keep = [];
        var q = root.query.toLowerCase();
        for (var i = 0; i < root.papers.length; i++) {
            var p = root.papers[i];
            if (root.filter === "stills" && p.vid) continue;
            if (root.filter === "motion" && !p.vid) continue;
            if (root.filter === "recent" && root.recents.indexOf(p.path) < 0
                                         && p.path !== root.active) continue;
            if (root.collection.length && p.coll !== root.collection) continue;
            // Name only, and case-insensitively. Searching the path would match every
            // wallpaper in a collection whose folder happens to contain the letters you
            // typed, which is what the collection chips are for.
            if (q.length && p.name.toLowerCase().indexOf(q) < 0) continue;
            keep.push(p);
        }
        // Newest first, when asked. The index hands rows over in name order, which is the
        // one order that cannot answer "what did I just put in here" — and a folder you
        // drop things into is the folder this question is always about.
        if (root.sort === "new") {
            keep.sort(function (a, b) { return b.mtime - a.mtime });
        }
        // "recent" is an ORDER as much as a set: name order in a list of things sorted by
        // when you last wore them tells you nothing. The one on screen leads it. It
        // outranks the sort control, because the two say contradictory things and this one
        // is the more specific request.
        if (root.filter === "recent") {
            keep.sort(function (a, b) {
                function rank(x) {
                    if (x.path === root.active) return -1;
                    var r = root.recents.indexOf(x.path);
                    return r < 0 ? 1e6 : r;
                }
                return rank(a) - rank(b);
            });
        }
        root.shown = keep;
        root.cur = Math.max(0, Math.min(root.cur, keep.length - 1));
        rail.rebuild();
        preview.request();
    }

    // Keep looking at the same wallpaper across any change of what is listed, where that
    // is still possible. Snapping back to index 0 every time loses your place in the
    // folder, which is the one thing a filter is not supposed to cost you.
    function refilterKeepingPlace() {
        var here = root.shown.length ? root.shown[root.cur].path : "";
        root.applyFilter();
        for (var i = 0; i < root.shown.length; i++)
            if (root.shown[i].path === here) { root.cur = i; break }
        rail.settle(false);
    }
    function cycleFilter() {
        root.filter = root.filters[(root.filters.indexOf(root.filter) + 1) % root.filters.length];
        root.refilterKeepingPlace();
    }
    function setCollection(c) {
        root.collection = (root.collection === c) ? "" : c;
        root.refilterKeepingPlace();
    }
    function typed(ch) {
        root.query += ch;
        root.refilterKeepingPlace();
    }
    function backspace() {
        if (!root.query.length) return;
        root.query = root.query.slice(0, -1);
        root.refilterKeepingPlace();
    }
    function cycleSort() {
        root.sort = root.sorts[(root.sorts.indexOf(root.sort) + 1) % root.sorts.length];
        root.refilterKeepingPlace();
    }

    // ---------- import ----------
    // Everything here could CHOOSE a wallpaper and nothing could add one: the folder was
    // filled by a file manager or it was not filled. ctrl+v takes whatever is on the
    // clipboard — image bytes, a path, a file:// URI, a URL — and puts it in the folder.
    property string importScript: Qt.resolvedUrl("sea-wallpaper-import.sh").toString().replace("file://", "")
    property bool importing: false
    property string importNote: ""
    property string importWanted: ""
    Timer { id: noteHide; interval: 2600; repeat: false; onTriggered: root.importNote = "" }

    function importClipboard() {
        if (root.importing || root.committing) return;
        root.importing = true;
        root.importNote = "";
        importProc.running = true;
    }
    Process {
        id: importProc
        command: ["sh", root.importScript]
        stdout: StdioCollector { id: impOut; onStreamFinished: {
            var got = impOut.text.trim();
            root.importing = false;
            if (!got.length) {
                root.importNote = "nothing on the clipboard to import";
                noteHide.restart();
                return;
            }
            // Re-index rather than splicing the row in by hand: the new file still needs
            // its dimensions measured and, if it moves, a poster cut — which is the
            // indexer's whole job and not something to reimplement here.
            root.importWanted = got;
            root.importNote = "imported " + got.slice(got.lastIndexOf("/") + 1);
            noteHide.restart();
            index.running = true;
        } }
    }

    function clearQuery() {
        if (!root.query.length) return false;
        root.query = "";
        root.refilterKeepingPlace();
        return true;
    }
    function step(d) {
        if (!root.shown.length) return;
        root.cur = Math.max(0, Math.min(root.shown.length - 1, root.cur + d));
    }
    function goto(i) {
        if (i >= 0 && i < root.shown.length) root.cur = i;
    }
    readonly property var item: root.shown.length ? root.shown[root.cur] : null
    // The still a wallpaper is previewed by: itself, or a frame ffmpeg cut out of it. Empty
    // means a moving wallpaper on a machine with no ffmpeg.
    //
    // Two sizes, because there are two jobs. The RAIL wants the 1280px poster — it draws it
    // at a couple of hundred pixels and there is no reason to decode more. The full-screen
    // PREVIEW wants the native-resolution frame, or the wallpaper looks like it loaded at
    // half quality for the moment before the video takes over.

    function stillFor(p) { return !p ? "" : (p.vid ? p.poster : p.path) }
    function bigStillFor(p) {
        if (!p) return "";
        if (!p.vid) return p.path;
        return p.full && p.full.length ? p.full : p.poster;
    }

    function human(b) {
        if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB";
        if (b >= 1048576)    return (b / 1048576).toFixed(0) + " MB";
        if (b >= 1024)       return (b / 1024).toFixed(0) + " KB";
        return b + " B";
    }
    function clock(ms) {
        if (!ms) return "";
        var t = Math.round(ms / 1000);
        return Math.floor(t / 60) + ":" + (t % 60 < 10 ? "0" : "") + (t % 60);
    }

    // ---------- commit ----------
    function apply() {
        if (root.committing || !root.item) return;
        var p = root.item.path;
        var vid = root.item.vid;
        win.sink = 0; win.surge = 0; win.ebb = 0;
        win.phase = "sink";

        // Hand our decoder back before the wallpaper asks for one. Two 4K decoders competing
        // during the handover is the one moment this surface could stutter.
        preview.stopVideo();

        root.committing = true;
        insert.start();

        // A path with a quote in it used to be a shell injection into the `printf` above;
        // it is an argv element now, so the quoting problem no longer exists. --quiet
        // because this surface is already showing you, at length, what it is doing.
        Quickshell.execDetached(["sh", root.setScript, p, "--quiet",
                                 root.matchColors ? "--match" : "--no-match"]);

        // The daemon transition runs UNDER the water rather than after it. Quitting before
        // either finishes would show the old wallpaper for the length of the fade — the
        // picker racing the very transition it just started.
        var daemon = vid ? 260 : Math.round(Math.min(root.wpDur, 1.2) * 1000) + 140;
        hold.interval = Math.max(win.insertMs + 90, daemon);
        hold.start();
    }
    Timer { id: hold; repeat: false; onTriggered: root.leave() }

    PanelWindow {
        id: win
        visible: root.showing
        readonly property real ui: Tok.uiFor(win.screen)

        // ---- the sea, in logical px (scaled with the chrome) ----
        readonly property real seaH:   214          // surface line to the bottom of the screen
        readonly property real railH:  188          // a focused frame's height
        readonly property real sinkIn: 20           // how far the frames sit in the water
        readonly property real reflH:  66           // the reflection under each frame
        readonly property real amp:    6            // the swell's height at rest
        readonly property real lambda: 280          // and its length
        readonly property real lw: win.width / win.ui
        readonly property real lh: win.height / win.ui
        readonly property real restTop: win.lh - win.seaH

        // Where the water's surface is. At rest it is the waterline; the commit's surge lifts it
        // past the top of the screen and the ebb drains it out through the bottom.
        property real sink: 0                       // the chosen frame going under, 0..1
        property real surge: 0                      // the swell coming up, 0..1
        property real ebb: 0                        // the water going out, 0..1
        readonly property real swell: win.amp * (1 + 2.2 * win.surge * (1 - win.ebb))
        readonly property real waterTop: win.ebb > 0
            ? -win.swell * 3 + win.ebb * (win.lh + win.swell * 6)
            : win.restTop - win.surge * (win.restTop + win.swell * 3)
        property string phase: ""
        // sink 260 · surge 460 · slack 90 · ebb 600
        readonly property int insertMs: 260 + 460 + 90 + 600

        // The water's colours: the shell's ground with the accent let into it, so the sea is
        // the same sea as the rest of the desktop and recolours with it.
        readonly property color deep: Qt.tint(Tok.bg, Tok.alpha(Tok.accent, Tok.light ? 0.16 : 0.22))
        readonly property color shallow: Qt.tint(Tok.bg, Tok.alpha(Tok.accent, Tok.light ? 0.34 : 0.42))
        // what the tide is made of at its height: more accent near the crest, deep below it
        readonly property color crest: Qt.tint(Tok.bg, Tok.alpha(Tok.accent, Tok.light ? 0.48 : 0.55))
        function mix(a, b, t) {
            return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                           a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
        }

        // One clock for everything that moves on its own: the frames bob on it and the waves
        // drift on it. Stopped for reduced motion, and whenever nobody can see it.
        property real tide: 0
        NumberAnimation on tide {
            from: 0; to: Math.PI * 2; duration: 6400
            loops: Animation.Infinite
            running: root.showing && !Tok.reducedMotion
        }

        // A periodic wave across `w`, its rest line at y 0: half-wavelength quads, crest and
        // trough alternating. `close` runs it down to `deep` and back, for a filled body of water.
        function wavePath(w, len, a, deepTo, close) {
            var d = "M 0 0", x = 0, up = true;
            while (x < w) {
                d += " Q " + (x + len / 4) + " " + (up ? -2 * a : 2 * a) + " " + (x + len / 2) + " 0";
                x += len / 2; up = !up;
            }
            if (close) d += " L " + x + " " + deepTo + " L 0 " + deepTo + " Z";
            return d;
        }

        property bool entered: false

        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Timer { id: enter; interval: 30; repeat: false; onTriggered: win.entered = true }

        // ================= the preview =================
        // Deliberately NOT inside the scaled chrome below: this is the wallpaper at the
        // size the monitor will actually show it, which is the whole point of the surface.
        Item {
            id: preview
            anchors.fill: parent
            property bool useA: true

            // The player does not exist until vidLoad has built it, so every reference goes
            // through these and every one of them can be null.
            readonly property var vid:  vidLoad.item ? vidLoad.item.player : null
            readonly property var vout: vidLoad.item ? vidLoad.item.out    : null
            // What to play once there is something to play it with. Held rather than acted
            // on, because the request can arrive before the backend is finished loading.
            property string wantPath: ""
            function startWanted() {
                if (!preview.wantPath || !preview.vid) return;
                preview.vid.source = Tok.fileUrl(preview.wantPath);
                preview.vid.play();
            }

            // Holding an arrow key walks the folder faster than a 4K JPEG decodes. Without
            // the debounce every intermediate wallpaper is decoded and thrown away, and the
            // preview lands a second behind the rail.
            function request() {
                // Moving cancels motion. Carrying "playing" from one wallpaper to the next would
                // spin up a decoder per step, which is the thing this design exists to stop.
                root.wantMotion = false;
                vidHop.stop(); stopVideo();
                // Nothing decodes for a window nobody is looking at.
                if (!root.showing) { imgA.source = ""; imgB.source = ""; imgA.want = ""; imgB.want = ""; hop.stop(); return }
                hop.restart();
            }
            // What the preview should be showing. Each Image remembers what it was asked to
            // load (`want`), and only a slot holding THIS may take the screen. Flipping on any
            // Ready let a stale decode land after a newer request; and re-asking a slot for the
            // path it already holds changes nothing, so no Ready ever came and a fast swipe back
            // left the preview on the wallpaper before.
            property string wantUrl: ""
            function show(img) { preview.useA = (img === imgA) }
            Timer {
                id: hop; interval: 90; repeat: false
                onTriggered: {
                    var url = Tok.fileUrl(root.bigStillFor(root.item));
                    preview.wantUrl = url;
                    var front = preview.useA ? imgA : imgB, back = preview.useA ? imgB : imgA;
                    if (front.want === url && front.status !== Image.Error) {
                        // already up (or on its way up in the visible slot)
                    } else if (back.want === url && back.status === Image.Ready) {
                        preview.show(back);
                    } else {
                        back.want = url;
                        back.source = url;
                    }
                    if (root.item && root.item.vid && !root.committing) vidHop.restart();
                }
            }

            // A moving wallpaper plays, because a poster frame does not tell you whether
            // the motion is a slow drift or a strobing city, and that is most of what you
            // are choosing between. Started on a longer delay than the still: spinning up
            // an ffmpeg decoder per frame of a held arrow key is the one thing here that
            // could actually cost the machine something.
            Timer {
                id: vidHop; interval: 420; repeat: false
                onTriggered: {
                    if (!root.wantMotion || !root.item || !root.item.vid || root.committing) return;
                    preview.wantPath = root.item.path;
                    if (preview.vid) preview.startWanted();
                    else vidLoad.active = true;      // onLoaded picks wantPath up
                }
            }
            function stopVideo() {
                preview.wantPath = "";
                vidFade.stop();
                if (!preview.vid) return;
                preview.vout.opacity = 0;
                preview.vid.stop();
                preview.vid.source = "";
            }

            // Cover the screen without distorting: decode against whichever edge is
            // binding under PreserveAspectCrop, so an ultrawide panorama is not decoded at
            // screen width and then upscaled to reach the top and bottom of the screen.
            function decodeW(p) {
                if (!p) return 0;
                return (p.aspect > (win.width / win.height)) ? 0 : win.width;
            }
            function decodeH(p) {
                if (!p) return 0;
                return (p.aspect > (win.width / win.height)) ? win.height : 0;
            }

            Rectangle { anchors.fill: parent; color: Tok.bg }

            Image {
                id: imgA
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: false
                sourceSize.width: preview.decodeW(root.item)
                sourceSize.height: preview.decodeH(root.item)
                property string want: ""
                opacity: preview.useA ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
                onStatusChanged: if (status === Image.Ready && want === preview.wantUrl) preview.show(imgA)
            }
            Image {
                id: imgB
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: false
                sourceSize.width: preview.decodeW(root.item)
                sourceSize.height: preview.decodeH(root.item)
                property string want: ""
                opacity: preview.useA ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
                onStatusChanged: if (status === Image.Ready && want === preview.wantUrl) preview.show(imgB)
            }

            // THE BACKEND IS NOT FREE. Constructing MediaPlayer and VideoOutput spins Qt
            // Multimedia up, and that pair alone measured ~700ms of a ~1200ms open — which
            // is the whole of why this surface stopped feeling instant when it grew in 6.2.
            // Importing QtMultimedia costs ~20ms; it is only building the objects that pays.
            // So the player is not part of the window. It is built once the picker is already
            // on screen, and in a folder of stills it is never built at all.
            Loader {
                id: vidLoad
                anchors.fill: parent
                active: false
                asynchronous: true
                onLoaded: preview.startWanted()
                sourceComponent: Item {
                    property alias player: mp
                    property alias out: vo
                    MediaPlayer {
                        id: mp
                        videoOutput: vo
                        loops: MediaPlayer.Infinite
                        // No audioOutput at all — a wallpaper has no business making a sound, and
                        // leaving it unset is how Qt is told not to open an audio device for this.
                        onPlaybackStateChanged: if (playbackState === MediaPlayer.PlayingState) firstFrame.restart()
                        onErrorOccurred: preview.stopVideo()
                    }
                    VideoOutput {
                        id: vo
                        anchors.fill: parent
                        fillMode: VideoOutput.PreserveAspectCrop
                        opacity: 0
                    }
                }
            }

            // WARMED IN A PAUSE, NOT ON A CLOCK. Building the player costs ~700ms of main
            // thread whenever it happens, so the only real question is what you are doing at
            // the time. The first version of this fired 700ms after the window appeared, which
            // is almost exactly when someone starts arrowing along the rail — so the open got
            // faster and the SWIPE got a freeze, which is a straight trade for the worse: an
            // open stall is over before you have decided anything, and a swipe stall lands in
            // the middle of a decision.
            //
            // request() restarts this on every step, so it only elapses once you have stopped
            // moving. Its interval is longer than vidHop's 420ms, so settling on something
            // moving still builds the player through the ordinary path and this never races it.
            // Never fires at all for a folder holding nothing that moves.
            // Fading in the instant playback starts can cross-fade to a frame the decoder
            // has not produced yet, which on a clip that opens dark reads as the preview
            // dimming for no reason. Give it a beat, then reveal over the poster.
            Timer {
                id: firstFrame; interval: 260; repeat: false
                onTriggered: if (preview.vid && preview.vid.hasVideo && !root.committing) vidFade.start()
            }
            NumberAnimation {
                id: vidFade; target: preview.vout; property: "opacity"
                to: 1; duration: Tok.mSlow; easing.type: Tok.mEase
            }

            // A moving wallpaper on a machine with no ffmpeg has no still to show at all.
            Column {
                anchors.centerIn: parent
                spacing: Tok.s3
                visible: root.item !== null && root.item.vid && !root.item.poster
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "movie"; font.family: "Material Symbols Outlined"
                    font.pixelSize: 64; color: Tok.ink3
                }
                IndText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    sz: Tok.tData; color: Tok.ink3
                    text: "Install ffmpeg to preview moving wallpapers"
                }
            }
        }

        // Legibility, not decoration: mono data and hairline rules have to survive being
        // laid over an arbitrary photograph, and the shell's four background steps cannot
        // help when the ground is somebody's 4K screenshot. Two gradients, no blur.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 156 * win.ui
            opacity: chrome.opacity
            gradient: Gradient {
                GradientStop { position: 0.0;  color: Tok.alpha(Tok.bg, 0.94) }
                GradientStop { position: 0.62; color: Tok.alpha(Tok.bg, 0.66) }
                GradientStop { position: 1.0;  color: "transparent" }
            }
        }

        // ================= the far swell =================
        // Behind the frames: a paler, longer, slower wave a little above the surface, so the
        // waterline has depth without a single shadow anywhere.
        Item {
            z: 1
            width: win.lw; height: win.lh
            transformOrigin: Item.TopLeft; scale: win.ui
            opacity: win.entered || root.committing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
            // a soft rise of colour above the water, so the frames stand on something
            Rectangle {
                x: 0; width: parent.width
                y: win.waterTop - 120; height: 130
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Tok.alpha(win.deep, 0.55) }
                }
            }
            Shape {
                readonly property real len: win.lambda * 1.37
                x: -len * ((win.tide / (Math.PI * 2) * 2) % 1)
                y: win.waterTop - 12
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0; strokeColor: "transparent"
                    fillColor: Tok.alpha(win.shallow, 0.62)
                    PathSvg { path: win.wavePath(win.lw + win.lambda * 3, win.lambda * 1.37,
                                                 win.swell * 0.8, win.lh * 2.2, true) }
                }
            }
        }

        // ================= the chrome =================
        // Laid out in logical pixels and scaled as one block, so every margin and rule keeps
        // its proportion on a 4K panel instead of each one being multiplied by hand. Sits at
        // z 2: over the far swell, under the near water and the readout.
        Item {
            id: chrome
            width: parent.width / win.ui
            height: parent.height / win.ui
            transformOrigin: Item.TopLeft
            scale: win.ui
            z: 2
            opacity: root.committing ? 0 : (win.entered ? 1 : 0)
            Behavior on opacity { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }

            // ---- header ----
            Item {
                id: head
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: Tok.s6 }
                height: 30

                Row {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    spacing: Tok.s3
                    SeaLogo {
                        anchors.verticalCenter: parent.verticalCenter
                        size: 24; card: Tok.ruleHard; accent: Tok.accent
                        highlight: Tok.ink; rim: Tok.accent
                    }
                    IndText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Wallpapers"; sz: Tok.tPanel
                        font.weight: 600; color: Tok.ink
                    }
                    // The folder, or — once there are subfolders in it — the collections
                    // they became. A wallpaper folder with any organisation in it used to
                    // index as empty, so this control had nothing it could have said.
                    IndText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !root.collections.length
                        text: root.wpDir; sz: Tok.tData; color: Tok.ink3
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.collections.length > 0
                        width: cRow.implicitWidth + Tok.s4; height: 28; radius: Tok.r
                        color: Tok.surface
                        border.width: 1; border.color: Tok.ruleHard
                        Row {
                            id: cRow; anchors.centerIn: parent; spacing: Tok.s3
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "folder"; font.family: "Material Symbols Outlined"
                                font.pixelSize: 14; color: Tok.ink3
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                readonly property bool on: root.collection === ""
                                text: "All"; sz: Tok.tData
                                font.weight: on ? 700 : 400
                                color: on ? Tok.accent : Tok.ink3
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.collection = ""; root.refilterKeepingPlace() }
                                }
                            }
                            Repeater {
                                model: root.collections
                                IndText {
                                    required property var modelData
                                    anchors.verticalCenter: parent.verticalCenter
                                    readonly property bool on: root.collection === modelData
                                    text: Tok.cap(modelData); sz: Tok.tData
                                    font.weight: on ? 700 : 400
                                    color: on ? Tok.accent : Tok.ink3
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setCollection(parent.modelData)
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    spacing: Tok.s2

                    // filter — one control, three states, cycled by Tab. Three separate toggles
                    // would be three things to look at for one piece of information.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: fRow.implicitWidth + Tok.s4; height: 28; radius: Tok.r
                        color: Tok.surface
                        border.width: 1; border.color: Tok.ruleHard
                        Row {
                            id: fRow; anchors.centerIn: parent; spacing: Tok.s3
                            Repeater {
                                model: root.filters
                                IndText {
                                    required property var modelData
                                    readonly property bool on: root.filter === modelData
                                    text: Tok.cap(modelData); sz: Tok.tData
                                    font.weight: on ? 700 : 400
                                    color: on ? Tok.accent : Tok.ink3
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.filter = parent.modelData;
                                            root.applyFilter();
                                            rail.settle(false);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Sort. One control, two states — the folder's own order, or the order
                    // things arrived in. A third would be inventing a question nobody asks
                    // of a wallpaper folder.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: sRow.implicitWidth + Tok.s4; height: 28; radius: Tok.r
                        color: Tok.surface
                        border.width: 1
                        border.color: root.sort === "new" ? Tok.accent : Tok.ruleHard
                        Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                        Row {
                            id: sRow; anchors.centerIn: parent; spacing: Tok.s2
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sort === "new" ? "Schedule" : "sort_by_alpha"
                                font.family: "Material Symbols Outlined"; font.pixelSize: 14
                                color: root.sort === "new" ? Tok.accent : Tok.ink3
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sort === "new" ? "Newest" : "A–Z"
                                sz: Tok.tData
                                color: root.sort === "new" ? Tok.ink : Tok.ink3
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.cycleSort()
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: mcRow.implicitWidth + Tok.s4; height: 28; radius: Tok.r
                        color: root.matchColors ? Tok.accentWash : Tok.surface
                        border.width: 1
                        border.color: root.matchColors ? Tok.accent : Tok.ruleHard
                        Behavior on color { ColorAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                        Row {
                            id: mcRow; anchors.centerIn: parent; spacing: Tok.s2
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "auto_awesome"; font.family: "Material Symbols Outlined"
                                font.pixelSize: 14
                                color: root.matchColors ? Tok.accent : Tok.ink3
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Match colours"; sz: Tok.tData
                                color: root.matchColors ? Tok.ink : Tok.ink3
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.matchColors = !root.matchColors
                        }
                    }
                }
            }

            IndText {
                anchors { top: head.bottom; right: parent.right; rightMargin: Tok.s6; topMargin: Tok.s2 }
                sz: Tok.tLabel; color: Tok.ink2
                // `m` used to toggle match-colours on its own. It cannot any more: a bare
                // letter is a search now, and a picker where typing does nothing until you
                // find the right control is the thing the search exists to remove.
                text: "type  find      ← →  or drag      enter  apply      tab  filter"
                    + "      ctrl+s  sort      ctrl+v  import      ctrl+m  match      esc  close"
            }

            // What the import did, said once and then gone. It is the only action on this
            // surface whose result is not visible in the rail immediately — a failed paste
            // changes nothing at all, and silence there is indistinguishable from a
            // keypress that never registered.
            IndText {
                id: importNote
                anchors { top: head.bottom; right: parent.right; rightMargin: Tok.s6
                          topMargin: Tok.s2 + 18 }
                sz: Tok.tLabel
                font.weight: 600
                color: root.importNote.indexOf("nothing") === 0 ? Tok.crit : Tok.accent
                text: root.importing ? "importing…" : root.importNote
                opacity: (root.importing || root.importNote.length) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            }

            // ---- the search window ----
            // A legend plate, a well for the thing you are typing and a counter plate.
            //
            // It exists only while you are searching. A machine does not label a window
            // that has nothing behind it.
            Item {
                id: find
                anchors { top: head.bottom; left: parent.left; leftMargin: Tok.s6; topMargin: Tok.s2 }
                width: 356; height: 32
                readonly property bool on: root.query.length > 0
                readonly property bool hit: root.shown.length > 0
                opacity: find.on ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                // Out of the header rather than out of nowhere: it belongs to the row of
                // controls above it, and arriving from there says so.
                transform: Translate {
                    y: find.on ? 0 : -8
                    Behavior on y { NumberAnimation { duration: Tok.mBase; easing.type: Easing.OutBack } }
                }

                Rectangle {
                    id: findWell
                    anchors.fill: parent
                    radius: Tok.rSmall
                    clip: true
                    // Darkened only far enough to separate from an arbitrary photograph —
                    // `sunken` alone sits 4% off `bg` and disappears over a bright one.
                    color: Qt.darker(Tok.sunken, Tok.light ? 1.18 : 1.35)

                    // 1 — the legend plate.
                    Rectangle {
                        id: findLegend
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 54
                        color: Tok.raised
                        IndText {
                            anchors.centerIn: parent
                            text: "Find"; sz: Tok.tLabel
                            font.weight: 700

                            color: Tok.ink3
                        }
                        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                                    width: 1; color: Tok.ruleHard }
                    }

                    // 2 — the well. The query, and the caret that says the keyboard is
                    //     pointed here — which, on a surface with no visible text field
                    //     until you type, is the one thing that is not otherwise obvious.
                    Row {
                        anchors { left: findLegend.right; leftMargin: Tok.s3
                                  verticalCenter: parent.verticalCenter }
                        spacing: 3
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.query; sz: Tok.tDense
                            color: find.hit ? Tok.ink : Tok.ink3
                            elide: Text.ElideLeft
                            width: Math.min(implicitWidth, 186)
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 2; height: Math.round(Tok.tDense * 1.2)
                            color: Tok.accent
                            opacity: blink.on ? 1 : 0
                            Timer {
                                id: blink; interval: 530; running: find.on; repeat: true
                                property bool on: true
                                onTriggered: blink.on = !blink.on
                                onRunningChanged: if (running) blink.on = true
                            }
                        }
                    }

                    // 3 — the counter plate: the number large, its unit small beside it.
                    Rectangle {
                        id: findCount
                        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                        width: 60
                        color: Tok.raised
                        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                    width: 1; color: Tok.ruleHard }
                        Row {
                            anchors.centerIn: parent
                            spacing: 3
                            IndText {
                                anchors.baseline: findHits.baseline
                                sz: Tok.tBody; font.weight: 700
                                color: find.hit ? Tok.accent : Tok.crit
                                text: find.hit ? (root.shown.length < 10 ? "0" : "") + root.shown.length
                                               : "--"
                            }
                            IndText {
                                id: findHits
                                sz: Tok.tLabel; color: Tok.ink3

                                text: "hit" + (root.shown.length === 1 ? "" : "s")
                            }
                        }
                    }
                }
            }


            // ---- the frames, afloat ----
            ListView {
                id: rail
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                anchors.bottomMargin: win.seaH - win.sinkIn - win.reflH
                height: win.railH + win.reflH
                orientation: ListView.Horizontal
                spacing: Tok.s4
                model: root.shown
                cacheBuffer: 1600

                // Dragging and the arrow keys are the same gesture through one variable:
                // whoever moved last owns contentX. `glide` drives it from the keyboard and is
                // never running while a finger is down; the drag drives it directly and
                // publishes what it lands on. Binding contentX to the index instead makes the
                // rail unmovable by hand, because the binding wins back every pixel the drag gains.
                interactive: !root.committing
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 2800
                maximumFlickVelocity: 4200

                // Centring the first and last frames means scrolling past both ends of the
                // content, and Flickable pulls contentX back inside its bounds when you do.
                // These margins ARE those two overhangs, sized exactly.
                leftMargin:  Math.max(0, rail.width / 2 - rail.frameW(0) / 2)
                rightMargin: Math.max(0, rail.width / 2 - rail.frameW(root.shown.length - 1) / 2)

                transform: Translate {
                    y: win.entered ? 0 : 60
                    Behavior on y { NumberAnimation { duration: Tok.mSlow; easing.type: Easing.OutCubic } }
                }

                // Frame widths vary, so the centring maths cannot come from ListView — it has
                // to be told where each one starts. Cached rather than summed on demand:
                // `nearest` runs on every pixel of a drag.
                property var offs: []
                function frameW(i) {
                    var p = root.shown[i];
                    if (!p) return win.railH;
                    // Clamped so one 32:9 panorama cannot eat the whole row, and a very tall
                    // image is not reduced to a sliver.
                    return Math.round(win.railH * Math.max(0.42, Math.min(2.4, p.aspect)));
                }
                function rebuild() {
                    var o = [], x = 0;
                    for (var i = 0; i < root.shown.length; i++) {
                        o.push(x);
                        x += rail.frameW(i) + rail.spacing;
                    }
                    rail.offs = o;
                }
                function centreFor(i) {
                    if (i < 0 || i >= rail.offs.length) return 0;
                    return rail.offs[i] + rail.frameW(i) / 2 - rail.width / 2;
                }
                function nearest() {
                    var c = rail.contentX + rail.width / 2, best = 0, bd = Infinity;
                    for (var i = 0; i < rail.offs.length; i++) {
                        var d = Math.abs(rail.offs[i] + rail.frameW(i) / 2 - c);
                        if (d < bd) { bd = d; best = i }
                    }
                    return best;
                }
                function settle(jump) {
                    if (!root.shown.length) return;
                    glide.stop();
                    if (jump) rail.contentX = rail.centreFor(root.cur);
                    else      rail.glideTo(root.cur);
                }
                function glideTo(i) {
                    glide.stop();
                    glide.from = rail.contentX;
                    glide.to = rail.centreFor(i);
                    glide.start();
                }
                NumberAnimation {
                    id: glide; target: rail; property: "contentX"
                    duration: Tok.mSlow; easing.type: Easing.OutCubic
                }

                // `moving`, not `dragging || flicking`: it also covers the wheel, and still
                // excludes `glide`, which writes contentX directly and raises no movement.
                readonly property bool userMoving: rail.moving
                onContentXChanged: if (rail.userMoving) root.cur = rail.nearest()
                onMovementEnded: { root.cur = rail.nearest(); rail.glideTo(root.cur) }

                delegate: Item {
                    id: frame
                    required property int index
                    required property var modelData

                    width: rail.frameW(index)
                    height: rail.height

                    // Distance from the centre of the row, in frames. Continuous rather than a
                    // focused/not-focused step, so the falloff stays smooth while contentX is
                    // still animating — or being dragged.
                    readonly property real n: Math.abs(
                        (x + width / 2) - (rail.contentX + rail.width / 2)) / win.railH
                    readonly property real k: Math.min(1, frame.n / 3)
                    readonly property bool focused: index === root.cur
                    readonly property real sc: 1 - 0.36 * Math.pow(frame.k, 0.60)
                    readonly property real op: 1 - 0.55 * Math.pow(frame.k, 0.55)

                    // Afloat: each frame rides the same swell a little out of step with the
                    // next, so the row moves like things on water and not like a marquee. The
                    // one you hold is steadier — it is the one you are reading.
                    readonly property real bob: Math.sin(win.tide + frame.index * 1.3)
                                              * (frame.focused ? 2 : 4.5)
                    // The chosen one goes under at the commit; everything else lets go of it.
                    readonly property real under: frame.focused ? win.sink : 0
                    opacity: root.committing && !frame.focused ? 1 - win.sink : 1

                    Rectangle {
                        id: plate
                        width: parent.width
                        height: win.railH
                        y: frame.bob + frame.under * win.railH * 0.85
                        // Shared baseline, so scaling grows a frame upward out of the water and
                        // a mixed folder packs into a skyline rather than a ragged band.
                        transformOrigin: Item.Bottom
                        scale: frame.sc * (1 - 0.06 * frame.under)
                        opacity: frame.op * (1 - 0.6 * frame.under)
                        radius: Tok.r
                        clip: true
                        color: Tok.sunken
                        border.width: frame.focused ? 2 : 1
                        border.color: frame.focused ? Tok.accent
                                    : fm.containsMouse ? Tok.ink3 : Tok.alpha(Tok.rule, 0.9)
                        Behavior on border.color { ColorAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                        // `clip` only clips to the bounding box, so the picture's square corners
                        // used to stick out past the plate's rounded ones.
                        ClippingRectangle {
                            anchors.fill: parent
                            anchors.margins: plate.border.width
                            radius: Math.max(0, plate.radius - plate.border.width)
                            color: "transparent"
                            Image {
                                id: still
                                anchors.fill: parent
                                source: root.stillFor(frame.modelData).length
                                        ? Tok.fileUrl(root.stillFor(frame.modelData)) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                sourceSize.height: Math.round(win.railH * 1.4)
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: frame.modelData.vid && !frame.modelData.poster
                            text: "movie"; font.family: "Material Symbols Outlined"
                            font.pixelSize: 28; color: Tok.ink3
                        }

                        // A moving wallpaper is a different kind of thing to a still, and that
                        // has to be visible here — it decides which daemon takes the layer.
                        Rectangle {
                            visible: frame.modelData.vid
                            anchors { top: parent.top; left: parent.left; margins: Tok.s2 }
                            width: 20; height: 20; radius: 10
                            color: Tok.alpha(Tok.bg, 0.72)
                            Text {
                                anchors.centerIn: parent
                                text: "play_arrow"; font.family: "Material Symbols Outlined"
                                font.pixelSize: 14; color: Tok.ink
                            }
                        }

                        MouseArea {
                            id: fm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // First click focuses — which previews it full-screen — and the
                            // second commits. Applying on the first would make every mis-click
                            // a wallpaper change.
                            onClicked: frame.focused ? root.apply() : root.goto(frame.index)
                        }
                    }

                    // The reflection: the frame upside down in the water under it, broken by
                    // a few drifting lines of sea so it reads as water and not as a mirror.
                    // The front wave is drawn over it, so it fades as it goes deeper by itself.
                    Item {
                        id: refl
                        readonly property real w: plate.width * plate.scale
                        readonly property real h: win.railH * plate.scale
                        x: (parent.width - w) / 2
                        y: win.railH - frame.bob * 0.5
                        width: w; height: Math.min(win.reflH, h)
                        clip: true
                        opacity: 0.42 * frame.op * (1 - frame.under)
                        ClippingRectangle {
                            width: refl.w; height: refl.h
                            radius: plate.radius * plate.scale
                            color: "transparent"
                            Image {
                                anchors.fill: parent
                                source: still.source
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                sourceSize.height: Math.round(win.railH * 1.4)
                                transform: Scale { origin.y: refl.h / 2; yScale: -1 }
                            }
                        }
                        Repeater {
                            model: 6
                            Rectangle {
                                required property int index
                                readonly property real step: win.reflH / 6
                                x: Math.sin(win.tide * 2 + index) * 6 - 6
                                width: refl.w + 12
                                height: 1.5 + index * 0.5
                                y: (index * step + (win.tide / (Math.PI * 2)) * step * 3) % win.reflH
                                color: Tok.alpha(win.deep, 0.75)
                            }
                        }
                    }
                }
            }


            // ---- empty ----
            Column {
                anchors.centerIn: parent
                spacing: Tok.s3
                visible: !root.shown.length
                IndText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    sz: Tok.tBody; color: Tok.ink
                    text: root.papers.length
                          ? (root.query.length ? "nothing here is called “" + root.query + "”"
                                               : "nothing matches the " + root.filter + " filter")
                          : "no wallpapers in " + root.wpDir
                }
                IndText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    sz: Tok.tData; color: Tok.ink3
                    text: root.papers.length
                          ? (root.query.length ? "esc clears the search"
                                               : "Tab cycles the filter")
                          : "drop jpg · png · webp · mp4 · webm · gif in there, or set the folder in Settings → Wallpaper"
                }
            }
        }

        // ================= the near water =================
        // In front of the frames: the surface they sit in, a foam line along its crest, and
        // the body of water the readout is printed on. At rest it is see-through at the top,
        // so the reflections show, and dense at the bottom, so text survives any wallpaper.
        // At the commit it is also the tide.
        Item {
            id: sea
            z: 3
            width: win.lw; height: win.lh
            transformOrigin: Item.TopLeft; scale: win.ui
            opacity: win.entered || root.committing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
            Shape {
                x: -win.lambda * ((win.tide / (Math.PI * 2) * 3) % 1)
                y: win.waterTop
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 0; strokeColor: "transparent"
                    fillGradient: LinearGradient {
                        x1: 0; y1: -win.swell * 2; x2: 0; y2: win.seaH + win.surge * win.lh
                        GradientStop { position: 0.0;  color: win.mix(Tok.alpha(win.deep, 0.50), win.crest, win.surge) }
                        GradientStop { position: 0.45; color: win.mix(Tok.alpha(win.deep, 0.86), win.shallow, win.surge) }
                        GradientStop { position: 1.0;  color: win.mix(Tok.alpha(win.deep, 0.97), win.deep, win.surge) }
                    }
                    PathSvg { path: win.wavePath(win.lw + win.lambda * 3, win.lambda,
                                                 win.swell, win.lh * 2.2, true) }
                }
                // foam: the crest picked out in a hairline of ink
                ShapePath {
                    strokeWidth: 1.5
                    strokeColor: Tok.alpha(Tok.ink, Tok.light ? 0.30 : 0.22)
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathSvg { path: win.wavePath(win.lw + win.lambda * 3, win.lambda,
                                                 win.swell, 0, false) }
                }
            }
        }

        // ================= sea life =================
        // Over the water, under the readout: light coming down through it, glints on the crest,
        // bubbles, a splash where each frame you land on settles, wake off the frames while the
        // rail moves, and a fish that swims to where you are in the folder. All of it hangs off
        // the same tide clock as the waves, and all of it except the fish stops for reduced motion.
        Item {
            id: life
            z: 3.5
            width: win.lw; height: win.lh
            transformOrigin: Item.TopLeft; scale: win.ui
            opacity: win.entered || root.committing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }

            readonly property bool alive: root.showing && !Tok.reducedMotion
            readonly property color foam: Qt.rgba(1, 1, 1, Tok.light ? 0.95 : 0.85)
            // White spray vanishes on pale light-theme water; there it takes the accent.
            readonly property color spray: Tok.light ? Tok.alpha(Tok.accent, 0.7) : life.foam
            // The near wave's height at x — the same curve the sea's Shape draws.
            function waveY(x) {
                var off = -win.lambda * ((win.tide / (Math.PI * 2) * 3) % 1);
                return win.waterTop - win.swell * Math.sin(2 * Math.PI * (x - off) / win.lambda);
            }

            // How fast the rail is moving, from whoever is moving it (drag, flick or glide).
            property real vel: 0
            property real lastX: 0
            FrameAnimation {
                running: life.alive && win.entered
                onTriggered: {
                    var dx = rail.contentX - life.lastX;
                    life.lastX = rail.contentX;
                    var v = frameTime > 0 ? dx / frameTime : 0;
                    life.vel = Math.abs(v) > 20000 ? life.vel : life.vel * 0.8 + v * 0.2;
                    if (Math.abs(life.vel) < 4) life.vel = 0;
                }
            }

            // ---- the splash ----
            property real sp: 1                  // 0..1 through the splash, linear time
            property real splashW: win.railH * 16 / 9
            property int dir: 1                  // which way the last step went
            NumberAnimation { id: splashAnim; target: life; property: "sp"; from: 0; to: 1; duration: 720 }
            function moved(d) {
                life.dir = d;
                if (!life.alive) return;
                life.splashW = rail.frameW(root.cur);
                splashAnim.restart();
            }

            // ---- ambient: rays, glints, bubbles ----
            Item {
                anchors.fill: parent
                visible: life.alive
                opacity: root.committing ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }

                // Light shafts, clipped to the water so they start at the surface.
                Item {
                    y: win.waterTop; width: parent.width
                    height: Math.max(0, win.lh - win.waterTop)
                    clip: true
                    Repeater {
                        model: 6
                        Item {
                            id: ray
                            required property int index
                            readonly property real seed: (index * 0.618034 + 0.2) % 1
                            x: win.lw * (index + 0.5) / 6 + Math.sin(win.tide + index * 1.7) * 30 - width / 2
                            y: -12
                            width: 30 + seed * 60; height: win.seaH * 1.3
                            transformOrigin: Item.Top
                            rotation: 16 + Math.sin(win.tide * 0.5 + index) * 5
                            opacity: 0.25 + 0.75 * Math.pow(0.5 + 0.5 * Math.sin(win.tide * 1.5 + index * 2.3), 2)
                            // three nested shafts instead of one: the overlap makes a soft core
                            // and feathered edges, where a single bar read as a pane of glass
                            Repeater {
                                model: 3
                                Rectangle {
                                    required property int index
                                    width: ray.width * (1 - index * 0.3); height: ray.height * (1 - index * 0.15)
                                    x: (ray.width - width) / 2
                                    radius: width / 2
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, Tok.light ? 0.10 : 0.04) }
                                        GradientStop { position: 1.0; color: "transparent" }
                                    }
                                }
                            }
                        }
                    }
                }

                // Sun on the crest: little four-point glints that catch and go.
                Repeater {
                    model: 14
                    Item {
                        required property int index
                        readonly property real seed: (index * 0.754877 + 0.31) % 1
                        readonly property real px: win.lw * (index + seed) / 14
                        readonly property real tw: Math.pow(Math.max(0, Math.sin(win.tide * (2 + seed * 2) + index * 2.1)), 6)
                        x: px - 6; y: life.waveY(px) - 6
                        width: 12; height: 12
                        opacity: tw
                        scale: 0.4 + tw * 0.8
                        Rectangle { anchors.centerIn: parent; width: 12; height: 1.5; radius: 1; color: life.foam }
                        Rectangle { anchors.centerIn: parent; width: 1.5; height: 12; radius: 1; color: life.foam }
                    }
                }

                // Bubbles, each on its own clock so they never rise in step.
                Repeater {
                    model: 12
                    Item {
                        id: bub
                        required property int index
                        readonly property real seed: (index * 0.381966 + 0.13) % 1
                        readonly property real r: 2.5 + seed * 5
                        property real t: 0
                        NumberAnimation on t {
                            from: 0; to: 1; loops: Animation.Infinite
                            duration: 4200 + bub.seed * 4600
                            running: life.alive
                        }
                        readonly property real p: (bub.t + bub.seed * 1.7) % 1
                        readonly property real ceil: win.waterTop + 8
                        x: win.lw * ((bub.index * 0.618034 + 0.05) % 1) + Math.sin(bub.p * Math.PI * 4 + bub.index) * 8 - bub.r
                        y: win.lh + 10 - bub.p * (win.lh + 10 - bub.ceil) - bub.r
                        width: bub.r * 2; height: bub.r * 2
                        opacity: 0.75 * Math.min(1, bub.p * 4) * (bub.p > 0.93 ? (1 - bub.p) / 0.07 : 1)
                        Rectangle {
                            anchors.fill: parent; radius: width / 2
                            color: Qt.rgba(1, 1, 1, 0.07)
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, Tok.light ? 0.7 : 0.4)
                        }
                        Rectangle {
                            x: parent.width * 0.24; y: parent.height * 0.2
                            width: Math.max(1.5, parent.width * 0.24); height: width; radius: width / 2
                            color: Qt.rgba(1, 1, 1, 0.8)
                        }
                    }
                }
            }

            // ---- wake: foam streaks off the trailing edge of every frame in view ----
            Repeater {
                model: life.alive ? root.shown.length : 0
                Item {
                    id: wake
                    required property int index
                    readonly property real w: rail.frameW(wake.index)
                    readonly property real cx: (rail.offs[wake.index] || 0) + wake.w / 2 - rail.contentX
                    readonly property real n: Math.abs(wake.cx - rail.width / 2) / win.railH
                    readonly property real sc: 1 - 0.36 * Math.pow(Math.min(1, wake.n / 3), 0.60)
                    readonly property real speed: Math.min(1, Math.abs(life.vel) / 1600)
                    // contentX growing means the frames are travelling left, so the wake is on the right
                    readonly property int side: life.vel > 0 ? 1 : -1
                    visible: wake.speed > 0.03 && wake.cx > -wake.w && wake.cx < win.lw + wake.w && !root.committing
                    x: wake.cx + wake.side * wake.w * wake.sc / 2
                    y: life.waveY(wake.x)
                    Repeater {
                        model: 3
                        Rectangle {
                            required property int index
                            width: (50 + index * 36) * wake.speed * (1 - index * 0.12)
                            height: 2.2 - index * 0.5; radius: 1
                            x: wake.side > 0 ? index * 4 : -width - index * 4
                            y: -2 + index * 5
                            opacity: 0.9 - index * 0.25
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: wake.side > 0 ? life.spray : "transparent" }
                                GradientStop { position: 1.0; color: wake.side > 0 ? "transparent" : life.spray }
                            }
                        }
                    }
                }
            }

            // ---- the splash: rings spreading round the frame you landed on, and spray ----
            Item {
                anchors.fill: parent
                visible: life.sp < 1 && !root.committing
                Repeater {
                    model: 2
                    Shape {
                        id: ring
                        required property int index
                        readonly property real lin: Math.max(0, Math.min(1, (life.sp - index * 0.18) / (1 - index * 0.18)))
                        readonly property real q: 1 - Math.pow(1 - lin, 3)
                        readonly property real rx: life.splashW * (0.5 + q * (0.3 + index * 0.18))
                        readonly property real ry: 5 + q * 12
                        x: win.lw / 2; y: win.waterTop + 3
                        opacity: (1 - lin) * (index === 0 ? 0.9 : 0.6)
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeWidth: 2 - ring.index * 0.6
                            strokeColor: life.spray
                            fillColor: "transparent"
                            PathSvg {
                                path: "M " + (-ring.rx) + " 0 A " + ring.rx + " " + ring.ry + " 0 1 0 " + ring.rx
                                    + " 0 A " + ring.rx + " " + ring.ry + " 0 1 0 " + (-ring.rx) + " 0"
                            }
                        }
                    }
                }
                Repeater {
                    model: 12
                    Rectangle {
                        required property int index
                        readonly property real side: index % 2 ? 1 : -1
                        readonly property real seed: (index * 0.618034 + 0.07) % 1
                        readonly property real tt: life.sp * 0.72
                        readonly property real vx: side * (40 + seed * 110) + life.dir * 35
                        readonly property real vy: 170 + seed * 190
                        readonly property real x0: win.lw / 2 + side * life.splashW * (0.36 + seed * 0.16)
                        readonly property real h: vy * tt - 1000 * tt * tt / 2
                        width: 2.5 + seed * 3.5; height: width; radius: width / 2
                        x: x0 + vx * tt - width / 2
                        y: win.waterTop - h - height / 2
                        visible: h > -2
                        opacity: 1 - life.sp * 0.6
                        color: life.spray
                        border.width: 1; border.color: Tok.alpha(Tok.accent, 0.45)
                    }
                }
            }

            // ---- the fish: where you are in the folder ----
            Item {
                id: lane
                readonly property real y0: win.lh - 104
                readonly property real x0: Tok.s8 + 24
                readonly property real x1: win.lw - Tok.s8 - 24
                readonly property int n: root.shown.length
                function at(i) { return lane.x0 + (lane.x1 - lane.x0) * i / Math.max(1, lane.n - 1) }
                width: parent.width; height: parent.height
                opacity: root.committing || lane.n < 2 ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }

                Rectangle {
                    x: lane.x0; width: lane.x1 - lane.x0
                    y: lane.y0 + 13; height: 1
                    color: Tok.alpha(Tok.ink, 0.10)
                }
                // one pebble per wallpaper while that still reads as a row of them
                Repeater {
                    model: lane.n <= 90 ? lane.n : 0
                    Rectangle {
                        required property int index
                        readonly property bool on: index === root.cur
                        width: on ? 8 : 5; height: width; radius: width / 2
                        x: lane.at(index) - width / 2
                        y: lane.y0 + 13 - height / 2
                        color: on ? Tok.accent : Tok.alpha(Tok.ink, 0.30)
                        Behavior on width { NumberAnimation { duration: Tok.mFast } }
                    }
                }

                Item {
                    id: fish
                    readonly property real target: lane.at(root.cur)
                    readonly property bool swimming: Math.abs(fish.x - fish.target) > 1.5
                    x: fish.target
                    y: lane.y0 + Math.sin(win.tide * 2) * 2.5
                    Behavior on x {
                        enabled: !Tok.reducedMotion
                        SpringAnimation { spring: 2.4; damping: 0.3; epsilon: 0.25 }
                    }
                    property real flip: life.dir
                    Behavior on flip { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }
                    transform: Scale { xScale: fish.flip * 1.4; yScale: 1.4 }
                    // tilt into the swim, nose down when diving forward
                    rotation: fish.swimming ? Math.max(-12, Math.min(12, (fish.target - fish.x) * 0.15 * fish.flip)) : 0
                    Behavior on rotation { NumberAnimation { duration: 140 } }

                    Shape {
                        // the tail, wagging from where it meets the body
                        preferredRendererType: Shape.CurveRenderer
                        transform: Rotation {
                            origin.x: -6; origin.y: 0
                            angle: Tok.reducedMotion ? 0
                                 : Math.sin(win.tide * (fish.swimming ? 22 : 7)) * (fish.swimming ? 26 : 12)
                        }
                        ShapePath {
                            strokeWidth: 0; strokeColor: "transparent"
                            fillColor: Qt.darker(Tok.accent, 1.15)
                            PathSvg { path: "M -5 0 L -15 -7 Q -12 0 -15 7 Z" }
                        }
                    }
                    Shape {
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeWidth: 1; strokeColor: Qt.lighter(Tok.accent, 1.35)
                            fillColor: Tok.accent
                            PathSvg { path: "M 12 0 Q 7 -8 -6 -4 Q -9 0 -6 4 Q 7 8 12 0 Z" }
                        }
                        // dorsal fin
                        ShapePath {
                            strokeWidth: 0; strokeColor: "transparent"
                            fillColor: Qt.darker(Tok.accent, 1.15)
                            PathSvg { path: "M 2 -5 Q -1 -10 -4 -4 Z" }
                        }
                    }
                    Rectangle { x: 5; y: -2.6; width: 2.6; height: 2.6; radius: 1.3; color: Tok.bg }
                }
            }
        }

        // ================= the readout =================
        // Printed on the water: which of how many, then the name and its numbers, and the one
        // control a moving wallpaper needs. Fades with the chrome; the sea itself does not.
        Item {
            id: readout
            z: 4
            width: win.lw; height: win.lh
            transformOrigin: Item.TopLeft; scale: win.ui
            opacity: chrome.opacity
            Row {
                anchors { left: parent.left; leftMargin: Tok.s8; right: parent.right; rightMargin: Tok.s8
                          bottom: parent.bottom; bottomMargin: 30 }
                spacing: Tok.s6
                Row {
                    anchors.bottom: parent.bottom
                    spacing: Tok.s2
                    IndText {
                        anchors.baseline: ofN.baseline
                        mono: true; sz: Tok.tKpi; font.weight: 700
                        color: Tok.accent
                        text: root.shown.length
                              ? (root.cur + 1 < 10 ? "0" : "") + (root.cur + 1) : "--"
                    }
                    IndText {
                        id: ofN
                        sz: Tok.tDense; color: Tok.ink3
                        text: "/ " + root.shown.length
                    }
                }
                Column {
                    anchors.bottom: parent.bottom
                    spacing: Tok.s1
                    IndText {
                        sz: Tok.tBody; color: Tok.ink; font.weight: 600
                        text: root.item ? root.item.name : "No wallpaper"
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, win.lw * 0.45)
                    }
                    Row {
                        spacing: Tok.s4
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            sz: Tok.tData; color: Tok.ink3
                            visible: root.item !== null && root.item.w > 0
                            text: root.item ? root.item.w + "×" + root.item.h : ""
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            sz: Tok.tData; color: Tok.ink3
                            text: root.item ? root.human(root.item.bytes) : ""
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            sz: Tok.tData; color: Tok.ink3
                            visible: root.item !== null && root.item.ms > 0
                            text: root.item ? root.clock(root.item.ms) : ""
                        }
                    }
                }
                // Motion is opt-in, so a moving wallpaper gets a button that says so.
                Rectangle {
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 2
                    visible: root.item !== null && root.item.vid
                    width: playRow.implicitWidth + 22; height: 28; radius: 14
                    color: root.wantMotion ? Tok.alpha(Tok.accent, 0.22)
                         : playMa.containsMouse ? Tok.alpha(Tok.ink, 0.12) : Tok.alpha(Tok.ink, 0.06)
                    border.width: 1
                    border.color: root.wantMotion ? Tok.accent : Tok.alpha(Tok.ink, 0.18)
                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                    Row {
                        id: playRow
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.wantMotion ? "Pause" : "play_arrow"
                            font.family: "Material Symbols Outlined"; font.pixelSize: 16
                            color: root.wantMotion ? Tok.accent : Tok.ink
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            sz: Tok.tData; color: root.wantMotion ? Tok.accent : Tok.ink
                            text: root.wantMotion ? "Stop" : "Play"
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            sz: Tok.tLabel; color: Tok.ink3
                            text: "Ctrl+P"
                        }
                    }
                    MouseArea {
                        id: playMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.togglePlay()
                    }
                }
            }
            IndText {
                anchors { right: parent.right; rightMargin: Tok.s8; bottom: parent.bottom; bottomMargin: 34 }
                sz: Tok.tData; color: Tok.ink2
                text: root.matchColors ? "Enter  set it · the shell follows its colours" : "Enter  set it"
            }
        }

        SequentialAnimation {
            id: insert
            // 1 — the chosen frame goes under. InCubic: it starts slowly, as something
            //     settling into water does, and the rest of the row lets go of it meanwhile.
            NumberAnimation { target: win; property: "sink"; to: 1; duration: 260; easing.type: Easing.InCubic }
            // 2 — the swell. The surface lifts up the whole screen and the waves grow as it
            //     comes, so it reads as a wave arriving and not as a curtain being raised.
            ScriptAction { script: win.phase = "surge" }
            NumberAnimation { target: win; property: "surge"; to: 1; duration: 460; easing.type: Easing.InOutCubic }
            // 3 — slack water. Without the beat the rise and the fall are one movement.
            PauseAnimation { duration: 90 }
            // 4 — the ebb. The water drains down and out, and leaves the new wallpaper behind.
            //     OutCubic: it lets go fast and settles, the way a wave runs back down a beach.
            ScriptAction { script: win.phase = "ebb" }
            NumberAnimation { target: win; property: "ebb"; to: 1; duration: 600; easing.type: Easing.OutCubic }
        }

        // ================= input =================
        Item {
            anchors.fill: parent
            focus: true
            // TYPING IS SEARCHING, which is what decides the rest of this table. Every
            // navigation key keeps its job, and the only bare letter that had one — `m` for
            // match-colours — moves to ctrl+m. A picker where you have to find a control
            // before you can type is the thing a search is supposed to remove.
            Keys.onPressed: (e) => {
                if (root.committing) return;
                var mods = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);

                if (e.modifiers & Qt.ControlModifier) {
                    switch (e.key) {
                    case Qt.Key_M: root.matchColors = !root.matchColors; e.accepted = true; return;
                    case Qt.Key_S: root.cycleSort();      e.accepted = true; return;
                    case Qt.Key_V: root.importClipboard(); e.accepted = true; return;
                    // Motion is opt-in — see wantMotion. Ctrl, because this picker's plain
                    // letters go straight into the live search.
                    case Qt.Key_P: root.togglePlay(); e.accepted = true; return;
                    }
                }

                switch (e.key) {
                // Esc unwinds one step at a time: the search first, the window second.
                // Closing on the first press would throw away a query and the picker
                // together, and there is no way back to either.
                case Qt.Key_Escape:    if (!root.clearQuery()) root.leave(); e.accepted = true; return;
                case Qt.Key_Backspace: root.backspace(); e.accepted = true; return;
                case Qt.Key_Left:
                case Qt.Key_Up:        root.step(-1); e.accepted = true; return;
                case Qt.Key_Right:
                case Qt.Key_Down:      root.step(1);  e.accepted = true; return;
                case Qt.Key_Home:      root.goto(0);  e.accepted = true; return;
                case Qt.Key_End:       root.goto(root.shown.length - 1); e.accepted = true; return;
                case Qt.Key_PageUp:    root.step(-5); e.accepted = true; return;
                case Qt.Key_PageDown:  root.step(5);  e.accepted = true; return;
                case Qt.Key_Return:
                case Qt.Key_Enter:     root.apply(); e.accepted = true; return;
                case Qt.Key_Tab:
                case Qt.Key_Backtab:   root.cycleFilter(); e.accepted = true; return;
                // Space still applies, but only while there is nothing to type into —
                // wallpaper filenames are full of spaces, and a search you cannot put one
                // in stops at the first word.
                case Qt.Key_Space:
                    if (!root.query.length) { root.apply(); e.accepted = true; return }
                    break;
                }

                // Anything that produced a printable character and was not claimed above.
                if (!mods && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20) {
                    root.typed(e.text); e.accepted = true;
                }
            }

            // Flickable handles the wheel itself, but a HORIZONTAL one only reads the
            // horizontal delta — and a mouse wheel produces a vertical one, so turning it
            // over this rail did precisely nothing. The old grid scrolled on the wheel and
            // people will expect this to.
            //
            // A MouseArea rather than a WheelHandler because MouseArea.onWheel is the form
            // already proven under this Quickshell build — it is how the bar's volume pill
            // (shell.qml) and the DAC panel's Q control both scroll. `NoButton` makes this
            // deaf to clicks, so the rail underneath keeps its own press, drag and release.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                property real acc: 0
                onWheel: (e) => {
                    if (root.committing) return;
                    acc += (e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x);
                    // One notch is 120 units; a trackpad sends many small deltas per
                    // gesture, and stepping on each would cross the whole folder in a swipe.
                    while (acc >= 120)  { root.step(-1); acc -= 120 }
                    while (acc <= -120) { root.step(1);  acc += 120 }
                }
            }
        }

        // Clicking the wallpaper itself — anywhere above the rail — cancels, which is what
        // clicking outside the old modal did. Placed under the chrome so the rail and the
        // header keep their own clicks.
        MouseArea {
            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom }
            anchors.bottomMargin: (win.seaH + win.railH - win.sinkIn) * win.ui
            z: -1
            onClicked: if (!root.committing) root.leave()
        }
    }

    // One place the focus change fans out from: the preview reloads, and the rail closes
    // the gap unless the rail is what moved in the first place.
    property int prevCur: 0
    onCurChanged: {
        var d = root.cur >= root.prevCur ? 1 : -1;
        root.prevCur = root.cur;
        preview.request();
        if (!rail.userMoving) rail.glideTo(root.cur);
        if (root.showing && win.entered && !root.committing) life.moved(d);
    }
}
