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
// THE COMMIT.  The switch used to read as two separate events with a gap between them:
// the modal blinked out, then swww faded from the old wallpaper to the new one.  Now it is
// a cartridge going into a console, and two things make that read.
//
// The card NEVER CHANGES SIZE.  Growing it to fill the screen is a zoom, which is what the
// first attempt looked like; a cartridge is a fixed object that travels and is swallowed.
//
// And the machine is at the BOTTOM, where the rail already was — not floating in the middle
// of the screen, which was the second attempt and read as a slot in the sky.  A console sits
// on the desk in front of you: you pick the cartridge up, hold it over the slot, and push it
// DOWN.  So the picked frame pops up out of the rail, hangs clear for a beat, drops into the
// slot until the clip has eaten all of it, the console takes the impact, and the lid lifts.
//
// The daemon runs its own transition under all of that, so the flourish costs no time the
// switch was not already going to spend, and what the lid opens on is the same full-bleed
// preview that was behind the picker the whole time.
//
// The frames keep their own aspect ratio and share a baseline, so a folder of portrait
// and landscape wallpapers packs into a skyline rather than being cropped to a uniform
// grid. Falloff away from centre is scale and opacity only. There is no perspective and
// no shadow here: this is a rail seen straight on, not a Cover Flow.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
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
        win.phase = ""; win.entered = false; win.deckShift = 0; win.guides = true;
        win.shutter = 0; win.ring = 0; win.jolt = 0;
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
    // fades the picture, the deck and the rail together, and what comes up through it is the
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
        imgA.source = ""; imgB.source = "";
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

        // Seed the card on the focused frame's exact place on screen, in window pixels
        // rather than the chrome's scaled ones. The focused frame is always horizontally
        // centred in the rail — that is the whole layout — so the position is arithmetic
        // and needs no lookup into the view's delegates.
        //
        // `bay` is everything ABOVE the opening, and it clips. The card's coordinates are
        // plain screen coordinates, and pushing its y down to the slot line is the console
        // swallowing it — no fade, no shrink, just an object going somewhere it cannot be
        // seen any more.
        var ui = win.ui;
        cart.width  = rail.frameW(root.cur) * ui;
        cart.height = win.railH * ui;
        cart.x = win.holoX;
        cart.y = win.holoTop;                      // exactly where the hologram is projected
        lid.y = 0;
        lid.height = win.gapTop;
        win.deckShift = 0;
        win.phase = "ready";
        win.jolt = 0;
        win.shutter = 0;
        win.ring = 0;
        cart.plateH = 0;
        cartImg.source = root.bigStillFor(root.item).length
                       ? Tok.fileUrl(root.bigStillFor(root.item)) : "";

        // Hand our decoder back before mpvpaper asks for one. Two 4K decoders competing
        // during the handover is the one moment this surface could stutter.
        preview.stopVideo();

        root.committing = true;
        insert.start();

        // A path with a quote in it used to be a shell injection into the `printf` above;
        // it is an argv element now, so the quoting problem no longer exists. --quiet
        // because this surface is already showing you, at length, what it is doing.
        Quickshell.execDetached(["sh", root.setScript, p, "--quiet",
                                 root.matchColors ? "--match" : "--no-match"]);

        // The daemon transition runs UNDER the insert rather than after it, so the
        // flourish costs nothing it was not already going to wait for. Quitting before
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
        // THE DECK. A console across the bottom, present the whole time rather than
        // conjured at commit: slot, vent grille, status lamp, readout. The holograms are
        // projected above it and the cartridge drops into it, so the machine is the one
        // fixed thing on screen and everything else happens in relation to it.
        readonly property real deckH:    176            // the console, logical px
        readonly property real bezelH:   52             // the raised top face the slot is cut in
        readonly property real slotHL:   20             // the opening, logical
        readonly property real holoGap:  60             // daylight between projection and deck
        readonly property real holoDrop: 14             // the tick lane under the panels
        readonly property real railH:    196            // a focused hologram's height
        readonly property real slotH:    win.slotHL * win.ui

        // The slot line and the projection's resting place, in real pixels — the chrome is
        // laid out in logical ones and scaled, but the card has to travel out of it. The slot
        // is centred in the bezel, which is what makes the bezel read as a face with an
        // opening cut into it rather than as another stripe.
        readonly property real slotInset: (win.bezelH - win.slotHL) / 2
        readonly property real gapTop: win.height - (win.deckH - win.slotInset) * win.ui
        readonly property real gapBot: win.gapTop + win.slotH
        readonly property real holoTop: win.height
                                      - (win.deckH + win.holoGap + win.holoDrop + win.railH) * win.ui
        // Where the card rises to when it solidifies, before it drops.
        readonly property real gateY: win.holoTop - 56 * win.ui
        // The held panel's own geometry. It has to be a binding, not something apply() sets:
        // the guide rails and the slot are sized off it while the picker is still idle, and
        // reading it from `cart` — which only gets a position at commit — put the rails hard
        // against the left edge of the screen and the slot under nothing.
        readonly property real holoW: rail.frameW(root.cur) * win.ui
        readonly property real holoX: (win.width - win.holoW) / 2
        // The deck slides away on the output. Animating its `y` would need `y` to be free of
        // a binding, and a deck with no binding sits at zero — which drew the console across
        // the TOP of the screen, over the header, for the whole time the picker was idle.
        property real deckShift: 0
        property string phase: ""
        // "Every colour applied must earn its place through function" — so the accent marks
        // exactly one thing, and which thing depends on what the machine is doing. Choosing:
        // the index, because which of N you are on is the fact that matters. Loading: the
        // step. Never the two together, and never a third.
        readonly property bool loading: root.committing
        property real jolt: 0                                       // the recoil, in px
        // The guide rails serve twice: the column the holograms are projected up, and the
        // channel the cartridge runs down. One element, two readings, always present.
        property bool guides: true
        // The shutter across the slot: 0 closed, 1 fully parted. Driven by the insert
        // sequence rather than by a Behavior, because opening and closing are not the same
        // gesture — the machine opens for the cartridge and snaps shut behind it.
        property real shutter: 0
        // The contact ring, fired once when the cartridge seats. 0 unfired, 1 spent.
        property real ring: 0
        // dip 80 · pop 220 · beat 100 · drop 160 · seat 110 · output 300
        // dip 80 · pop 220 · beat 100 · drop 210 · seat 110 · output 300 · clear 90
        readonly property int insertMs: 80 + 220 + 100 + 210 + 110 + 470
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
                if (!root.showing) { imgA.source = ""; imgB.source = ""; hop.stop(); return }
                hop.restart();
            }
            Timer {
                id: hop; interval: 90; repeat: false
                onTriggered: {
                    var src = root.bigStillFor(root.item);
                    var into = preview.useA ? imgB : imgA;
                    into.source = Tok.fileUrl(src);
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
                opacity: preview.useA ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
                onStatusChanged: if (status === Image.Ready) preview.useA = true
            }
            Image {
                id: imgB
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: false
                sourceSize.width: preview.decodeW(root.item)
                sourceSize.height: preview.decodeH(root.item)
                opacity: preview.useA ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Tok.mSlow; easing.type: Tok.mEase } }
                onStatusChanged: if (status === Image.Ready) preview.useA = false
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
                    mono: true; sz: Tok.tData; color: Tok.ink3
                    text: "install ffmpeg to preview moving wallpapers"
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
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: (win.deckH + 90) * win.ui
            opacity: chrome.opacity
            gradient: Gradient {
                GradientStop { position: 0.0;  color: "transparent" }
                GradientStop { position: 0.30; color: Tok.alpha(Tok.bg, 0.58) }
                GradientStop { position: 0.62; color: Tok.alpha(Tok.bg, 0.91) }
                GradientStop { position: 1.0;  color: Tok.alpha(Tok.bg, 0.985) }
            }
        }

        // The ground, in two pieces that part on the slot line: the LID is everything above
        // the console, the DECK is the console's own face. Without them the card travelled
        // across a full-bleed copy of the very image it carries — same picture at two scales,
        // which reads as a smear rather than as an object moving.
        //
        // `y` is set in apply() rather than bound, because the reveal animates it and an
        // animation writing over a binding silently destroys the binding.
        Rectangle {
            id: lid
            z: 1
            x: 0; width: win.width; height: win.gapTop
            color: Tok.bg
            opacity: root.committing ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        }


        // ================= the chrome =================
        // Laid out in logical pixels and scaled as one block, so every margin and rule keeps
        // its proportion on a 4K panel instead of each one being multiplied by hand. Sits at
        // z 0, under the deck and the ground, because the commit's machinery has to cover it.
        Item {
            id: chrome
            z: 0
            width: parent.width / win.ui
            height: parent.height / win.ui
            transformOrigin: Item.TopLeft
            scale: win.ui
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
                        text: "wallpapers"; mono: true; sz: Tok.tPanel
                        font.weight: 600; color: Tok.ink
                    }
                    // The folder, or — once there are subfolders in it — the collections
                    // they became. A wallpaper folder with any organisation in it used to
                    // index as empty, so this control had nothing it could have said.
                    IndText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !root.collections.length
                        text: root.wpDir; mono: true; sz: Tok.tData; color: Tok.ink3
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.collections.length > 0
                        width: cRow.implicitWidth + Tok.s4; height: 28; radius: Tok.r
                        color: Tok.alpha(Tok.surface, 0.9)
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
                                text: "all"; mono: true; sz: Tok.tData
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
                                    text: modelData; mono: true; sz: Tok.tData
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
                        color: Tok.alpha(Tok.surface, 0.9)
                        border.width: 1; border.color: Tok.ruleHard
                        Row {
                            id: fRow; anchors.centerIn: parent; spacing: Tok.s3
                            Repeater {
                                model: root.filters
                                IndText {
                                    required property var modelData
                                    readonly property bool on: root.filter === modelData
                                    text: modelData; mono: true; sz: Tok.tData
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
                        color: Tok.alpha(Tok.surface, 0.9)
                        border.width: 1
                        border.color: root.sort === "new" ? Tok.accent : Tok.ruleHard
                        Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                        Row {
                            id: sRow; anchors.centerIn: parent; spacing: Tok.s2
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sort === "new" ? "schedule" : "sort_by_alpha"
                                font.family: "Material Symbols Outlined"; font.pixelSize: 14
                                color: root.sort === "new" ? Tok.accent : Tok.ink3
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sort === "new" ? "newest" : "a–z"
                                mono: true; sz: Tok.tData
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
                        color: root.matchColors ? Tok.accentWash : Tok.alpha(Tok.surface, 0.9)
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
                                text: "match colours"; mono: true; sz: Tok.tData
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
                mono: true; sz: Tok.tLabel; color: Tok.ink2
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
                mono: true; sz: Tok.tLabel
                font.weight: 600
                color: root.importNote.indexOf("nothing") === 0 ? Tok.crit : Tok.accent
                text: root.importing ? "importing…" : root.importNote
                opacity: (root.importing || root.importNote.length) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            }

            // ---- the search window ----
            // Built out of the deck's own parts, at the size of a control rather than a
            // panel: a RAISED legend plate, a SUNKEN well for the thing you are typing, a
            // raised counter plate, and hard rules where the materials meet. The first
            // version was a rounded box with a border, which is a text field from some
            // other product wearing this one's colours.
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
                    // A recess, not an opening. The slot in the deck is genuinely dark
                    // because it is a hole; this is a surface you read text off, so it is
                    // darkened only far enough to separate from an arbitrary photograph —
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
                            text: "find"; mono: true; sz: Tok.tLabel
                            font.weight: 700; font.letterSpacing: 1.5
                            font.capitalization: Font.AllUppercase
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
                            text: root.query; mono: true; sz: Tok.tDense
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

                    // 3 — the counter plate, in the deck counter's language: the number
                    //     large, its unit small beside it. The deck says which of how many;
                    //     this says how many there are to be which of.
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
                                mono: true; sz: Tok.tBody; font.weight: 700
                                color: find.hit ? Tok.accent : Tok.crit
                                text: find.hit ? (root.shown.length < 10 ? "0" : "") + root.shown.length
                                               : "--"
                            }
                            IndText {
                                id: findHits
                                mono: true; sz: Tok.tLabel; color: Tok.ink3
                                font.letterSpacing: 0.8
                                font.capitalization: Font.AllUppercase
                                text: "hit" + (root.shown.length === 1 ? "" : "s")
                            }
                        }
                    }
                }
            }

            // ---- the projection row ----
            ListView {
                id: rail
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                anchors.bottomMargin: win.deckH + win.holoGap
                height: win.railH + win.holoDrop
                orientation: ListView.Horizontal
                spacing: Tok.s3
                model: root.shown
                cacheBuffer: 1600

                // Dragging and the arrow keys are the same gesture through one variable:
                // whoever moved last owns contentX. `glide` drives it from the keyboard and is
                // never running while a finger is down; the drag drives it directly and
                // publishes what it lands on. Binding contentX to the index instead — which is
                // what this was — makes the rail unmovable by hand, because the binding wins
                // back every pixel the drag gains.
                interactive: true
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 2800
                maximumFlickVelocity: 4200

                // Centring the first and last panels means scrolling past both ends of the
                // content, and Flickable pulls contentX back inside its bounds when you do.
                // These margins ARE those two overhangs, sized exactly.
                leftMargin:  Math.max(0, rail.width / 2 - rail.frameW(0) / 2)
                rightMargin: Math.max(0, rail.width / 2 - rail.frameW(root.shown.length - 1) / 2)

                opacity: root.committing ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                transform: Translate {
                    y: win.entered ? 0 : 44
                    Behavior on y { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
                }

                // Panel widths vary, so the centring maths cannot come from ListView — it has
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
                    duration: Tok.mBase; easing.type: Tok.mEase
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

                    // Distance from the centre of the row, in panels. Continuous rather than a
                    // focused/not-focused step, so the falloff stays smooth while contentX is
                    // still animating — or being dragged — instead of snapping when the index
                    // flips.
                    readonly property real n: Math.abs(
                        (x + width / 2) - (rail.contentX + rail.width / 2)) / win.railH
                    readonly property real k: Math.min(1, frame.n / 3)
                    readonly property bool focused: index === root.cur

                    // Centre large and sharp, the rest receding — out of scale and opacity
                    // alone. No rotation, no perspective, no shadow: this shell states depth
                    // with size and ink, never with fake light.
                    readonly property real sc: 1 - 0.34 * Math.pow(frame.k, 0.60)
                    readonly property real op: 1 - 0.55 * Math.pow(frame.k, 0.55)

                    Rectangle {
                        id: plate
                        // The panels share a baseline, so scaling grows them upward and a mixed
                        // folder packs into a skyline instead of a ragged band.
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: win.holoDrop
                        width: parent.width
                        height: win.railH
                        transformOrigin: Item.Bottom
                        scale: frame.sc
                        opacity: frame.op
                        // No Behavior on scale or opacity: both are already continuous
                        // functions of contentX, which is itself animated. Easing an eased
                        // value is what made the row feel like it was lagging the keys.

                        // The held panel goes out instantly, not on the row's fade: the
                        // cartridge is seeded at exactly this position, so a shared fade leaves
                        // two copies of the same card dissolving over each other.
                        visible: !(root.committing && frame.focused)

                        radius: Tok.rSmall
                        clip: true
                        color: Tok.sunken
                        border.width: frame.focused ? 2 : 1
                        border.color: frame.focused ? Tok.accent
                                    : fm.containsMouse ? Tok.ink3 : Tok.alpha(Tok.rule, 0.9)
                        Behavior on border.color { ColorAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                        Image {
                            anchors.fill: parent
                            anchors.margins: 1
                            source: root.stillFor(frame.modelData).length
                                    ? Tok.fileUrl(root.stillFor(frame.modelData)) : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true; cache: true
                            sourceSize.height: Math.round(win.railH * 1.4)
                        }

                        // The projection raster. The held panel is resolved and has none; the
                        // others are still being projected, which is what the raster says.
                        Repeater {
                            model: frame.focused ? 0 : Math.floor(plate.height / 14)
                            Rectangle {
                                required property int index
                                y: index * 14
                                width: plate.width
                                height: 1
                                color: Tok.alpha(Tok.bg, 0.26)
                            }
                        }

                        // Registration corners on the held panel. Four brackets say "locked"
                        // far more clearly over an arbitrary photograph than a border colour
                        // can — they were 26×3 and invisible until measured against red.
                        Repeater {
                            model: (frame.focused && !root.committing) ? 4 : 0
                            Item {
                                required property int index
                                readonly property bool onRight: (index % 2) === 1
                                readonly property bool onBottom: index >= 2
                                readonly property real arm: 26
                                width: arm; height: arm
                                x: onRight ? plate.width - arm : 0
                                y: onBottom ? plate.height - arm : 0
                                Rectangle {
                                    width: parent.arm; height: 4; color: Tok.accent
                                    y: parent.onBottom ? parent.arm - 4 : 0
                                }
                                Rectangle {
                                    width: 4; height: parent.arm; color: Tok.accent
                                    x: parent.onRight ? parent.arm - 4 : 0
                                }
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
                            anchors { top: parent.top; left: parent.left; margins: Tok.s1 }
                            width: 18; height: 18; radius: Tok.rSmall
                            color: Tok.alpha(Tok.bg, 0.72)
                            Text {
                                anchors.centerIn: parent
                                text: "play_arrow"; font.family: "Material Symbols Outlined"
                                font.pixelSize: 13; color: Tok.ink
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
                }
            }

            // ---- empty ----
            Column {
                anchors.centerIn: parent
                spacing: Tok.s3
                visible: !root.shown.length
                IndText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    mono: true; sz: Tok.tBody; color: Tok.ink
                    text: root.papers.length
                          ? (root.query.length ? "nothing here is called “" + root.query + "”"
                                               : "nothing matches the " + root.filter + " filter")
                          : "no wallpapers in " + root.wpDir
                }
                IndText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    mono: true; sz: Tok.tData; color: Tok.ink3
                    text: root.papers.length
                          ? (root.query.length ? "esc clears the search"
                                               : "tab cycles the filter")
                          : "drop jpg · png · webp · mp4 · webm · gif in there, or set the folder in Settings → Wallpaper"
                }
            }
        }

        // The print head: it rides the lid's bottom edge, which during the reveal is the
        // boundary the wallpaper is coming out of, so the emergence has a leading edge you can
        // follow instead of being an area that grew.
        Rectangle {
            id: feedEdge
            z: 5
            x: 0; width: win.width
            height: Math.max(2, Math.round(2 * win.ui))
            y: lid.y + lid.height
            color: Tok.accent
            visible: win.phase === "loaded"
            opacity: lid.opacity
        }

        // ---------------- the deck ----------------
        // A front panel does three things: it contains, it labels, and it indicates. The
        // version this replaces did the labelling only — text floating on one flat plane,
        // which is why it read as a bar rather than a machine.
        //
        // So it is built the way rack gear is: a RAISED bezel with the opening cut into it,
        // then a panel divided into functional modules by hard rules — counter, readout, vent,
        // indicator. Depth is three background steps (raised bezel over surface panel over a
        // darkened well), never shadow. And there is no nameplate, no serial and no fake
        // fixings: "a lack of superfluous controls, styling or excessive markings" is the
        // whole point, and invented hardware markings would be exactly that.

        // the bezel above the opening — drawn over the card, so the cartridge slides behind
        // the deck's top face and reappears in the slot, the way a front-loader looks
        Rectangle {
            id: deckLip
            z: 4
            x: 0; width: win.width
            y: win.height - win.deckH * win.ui
            height: win.gapTop - y
            color: Tok.raised
            transform: Translate { y: win.jolt + win.deckShift }
            IndRule { anchors { left: parent.left; right: parent.right; top: parent.top } hard: true }

            // Alignment marks either side of the opening. They say where the cartridge goes,
            // which is the one thing a bezel is for.
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    width: Math.round(14 * win.ui)
                    height: Math.max(1, Math.round(win.ui))
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Math.round(5 * win.ui)
                    x: index === 0 ? win.holoX - 30 * win.ui : win.holoX + win.holoW + 16 * win.ui
                    color: Tok.ink3
                }
            }
        }

        // the opening — behind the card, so the card is seen IN it, and only as wide as the
        // thing that goes through it. An opening is dark, and `sunken` cannot say that in the
        // light theme: it sits 4% off `bg`. The token is still the source, darkened.
        Rectangle {
            id: well
            z: 2
            width: win.holoW + 10 * win.ui
            x: (win.width - width) / 2
            y: win.gapTop; height: win.slotH
            color: Qt.darker(Tok.sunken, Tok.light ? 2.1 : 1.6)
            clip: true
            transform: Translate { y: win.jolt + win.deckShift }

            // THE SHUTTER. Two leaves across the opening, in the plane between the bezel
            // and the darkness behind — so the slot still reads as an opening when the
            // picker is idle, but an opening with something across it rather than a hole.
            //
            // It is the answer to the one thing the commit never said: the cartridge used
            // to descend into a static black bar, and the only evidence the machine had
            // taken it was the jolt. Now the machine OPENS for it and snaps shut behind it,
            // which is a thing happening TO the deck rather than to the card alone.
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    // NOT `right` — QQuickItem reserves it as a FINAL property and the
                    // whole file refuses to load.
                    readonly property bool onRight: index === 1
                    width: well.width / 2 + 1
                    height: well.height
                    x: onRight ? well.width / 2 + win.shutter * width
                               : -win.shutter * width
                    color: Tok.sunken
                    // the leaves' meeting edges, so two leaves read as two
                    Rectangle {
                        anchors { top: parent.top; bottom: parent.bottom }
                        x: parent.onRight ? 0 : parent.width - 1
                        width: 1; color: Tok.ruleHard
                    }
                }
            }
        }

        // the bezel closes up either side of the opening
        Repeater {
            model: 2
            Rectangle {
                required property int index
                z: 4
                y: win.gapTop; height: win.slotH
                x: index === 0 ? 0 : well.x + well.width
                width: index === 0 ? well.x : win.width - (well.x + well.width)
                color: Tok.raised
                transform: Translate { y: win.jolt + win.deckShift }
            }
        }

        // everything below the opening: the rest of the bezel, then the panel
        Rectangle {
            id: deck
            z: 4
            x: 0; y: win.gapBot
            width: win.width; height: win.height - win.gapBot
            color: Tok.surface
            transform: Translate { y: win.jolt + win.deckShift }

            // the bezel's lower lip, and the rule where the face steps down to the panel
            Rectangle {
                id: lowerLip
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: (win.bezelH - win.slotInset - win.slotHL) * win.ui
                color: Tok.raised
                IndRule { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } hard: true }
            }

            // ---- the panel: modules, divided by rules ----
            Row {
                id: panel
                anchors { left: parent.left; right: parent.right
                          top: lowerLip.bottom; bottom: parent.bottom }

                // 1 — the counter. A deck's one display, and the fact that matters most while
                //     you are choosing: which of how many.
                Item {
                    width: Math.round(150 * win.ui); height: panel.height
                    Row {
                        anchors.centerIn: parent
                        spacing: Tok.s2 * win.ui
                        IndText {
                            anchors.baseline: ofN.baseline
                            mono: true; sz: Math.round(Tok.tKpi * win.ui)
                            font.weight: 700
                            color: win.loading ? Tok.ink3 : Tok.accent
                            text: root.shown.length
                                  ? (root.cur + 1 < 10 ? "0" : "") + (root.cur + 1) : "--"
                        }
                        IndText {
                            id: ofN
                            mono: true; sz: Math.round(Tok.tDense * win.ui); color: Tok.ink3
                            text: "/ " + root.shown.length
                        }
                    }
                }
                Rectangle { width: 1; height: panel.height; color: Tok.ruleHard }

                // 2 — the readout. Name on top, the numbers under it.
                Item {
                    width: panel.width - Math.round(150 * win.ui) - Math.round(96 * win.ui)
                                       - Math.round(150 * win.ui) - 3
                    height: panel.height
                    Column {
                        anchors { left: parent.left; leftMargin: Tok.s6 * win.ui
                                  verticalCenter: parent.verticalCenter }
                        spacing: Tok.s2 * win.ui
                        IndText {
                            mono: true; sz: Math.round(Tok.tBody * win.ui); color: Tok.ink
                            text: root.item ? root.item.name : "no wallpaper"
                            elide: Text.ElideMiddle
                            width: Math.min(implicitWidth, panel.width * 0.42)
                        }
                        Row {
                            spacing: Tok.s4 * win.ui
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                mono: true; sz: Math.round(Tok.tData * win.ui); color: Tok.ink3
                                visible: root.item !== null && root.item.w > 0
                                text: root.item ? root.item.w + "×" + root.item.h : ""
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                mono: true; sz: Math.round(Tok.tData * win.ui); color: Tok.ink3
                                text: root.item ? root.human(root.item.bytes) : ""
                            }
                            IndText {
                                anchors.verticalCenter: parent.verticalCenter
                                mono: true; sz: Math.round(Tok.tData * win.ui); color: Tok.ink3
                                visible: root.item !== null && root.item.ms > 0
                                text: root.item ? root.clock(root.item.ms) : ""
                            }
                            // A CONTROL, not a caption. Motion is opt-in, and a line of grey text
                            // saying "ctrl+p plays" is not an offer anyone reads — the deck is
                            // covered in text and this is the one piece of it you can press. So it
                            // is built like the rest of the panel is built: a raised key with a
                            // hard border, an indicator that lights when it is doing something,
                            // and the shortcut printed on it the way it is printed on real gear.
                            Rectangle {
                                id: playKey
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.item !== null && root.item.vid
                                width: playRow.implicitWidth + Math.round(16 * win.ui)
                                height: Math.round(24 * win.ui)
                                radius: Tok.rSmall
                                color: root.wantMotion ? Tok.alpha(Tok.accent, 0.20)
                                     : playMa.containsMouse ? Tok.alpha(Tok.ink3, 0.16)
                                     : Tok.alpha(Tok.ink3, 0.07)
                                border.width: 1
                                border.color: root.wantMotion ? Tok.accent
                                            : playMa.containsMouse ? Tok.ink3 : Tok.ruleHard
                                Behavior on color { ColorAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                                Behavior on border.color { ColorAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                                Row {
                                    id: playRow
                                    anchors.centerIn: parent
                                    spacing: Math.round(7 * win.ui)
                                    // The lamp: lit while it is playing, dark while it is not. Same
                                    // grammar as the deck's own status lamp two modules over.
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.round(6 * win.ui); height: width; radius: width / 2
                                        color: root.wantMotion ? Tok.accent : Tok.alpha(Tok.ink3, 0.45)
                                    }
                                    IndText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        mono: true; sz: Math.round(Tok.tData * win.ui)
                                        font.letterSpacing: 1.1 * win.ui
                                        font.capitalization: Font.AllUppercase
                                        color: root.wantMotion ? Tok.accent : Tok.ink
                                        text: root.wantMotion ? "stop" : "play"
                                    }
                                    IndText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        mono: true; sz: Math.round(Tok.tLabel * win.ui)
                                        color: Tok.ink3
                                        font.capitalization: Font.AllUppercase
                                        text: "ctrl+p"
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
                    }
                }
                Rectangle { width: 1; height: panel.height; color: Tok.ruleHard }

                // 3 — the vent. Rules only, a full module rather than a detail in a corner.
                Item {
                    width: Math.round(96 * win.ui); height: panel.height
                    Row {
                        anchors.centerIn: parent
                        spacing: Math.max(2, Math.round(4 * win.ui))
                        Repeater {
                            model: 11
                            Rectangle {
                                width: Math.max(1, Math.round(win.ui))
                                height: Math.round(panel.height * 0.46)
                                color: Tok.alpha(Tok.ink3, 0.34)
                            }
                        }
                    }
                }
                Rectangle { width: 1; height: panel.height; color: Tok.ruleHard }

                // 4 — the indicator. One lamp, and the step it is on.
                Item {
                    width: Math.round(150 * win.ui); height: panel.height
                    Column {
                        anchors.centerIn: parent
                        spacing: Tok.s2 * win.ui
                        // The lamp. It used to go accent the instant you pressed enter and
                        // stay there for the whole commit, which says "busy" and nothing
                        // else. It now reads the cartridge: dim while the card is still in
                        // the air, full at the moment of CONTACT, and a single ring thrown
                        // off at that instant. A lamp that lights when the thing lands is
                        // the deck responding; a lamp that lights when you press a key is
                        // the keyboard responding.
                        Rectangle {
                            id: lamp
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.round(9 * win.ui); height: width; radius: width / 2
                            color: (win.phase === "seated" || win.phase === "loaded") ? Tok.accent
                                 : win.loading ? Tok.alpha(Tok.accent, 0.30)
                                 : Tok.alpha(Tok.ink3, 0.40)
                            // 40ms, not mFast: contact is an impact, and anything slow
                            // enough to watch is not one.
                            Behavior on color { ColorAnimation { duration: 40 } }

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width; height: parent.height
                                radius: width / 2
                                color: "transparent"
                                border.width: Math.max(1, Math.round(2 * win.ui))
                                border.color: Tok.accent
                                visible: win.ring > 0 && win.ring < 1
                                scale: 1 + win.ring * 2.4
                                opacity: 1 - win.ring
                            }
                        }
                        IndText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            mono: true; sz: Math.round(Tok.tLabel * win.ui)
                            font.weight: 600; font.letterSpacing: 1.4 * win.ui
                            font.capitalization: Font.AllUppercase
                            color: win.loading ? Tok.accent : Tok.ink3
                            text: win.loading ? win.phase : "ready"
                        }
                    }
                }
            }
        }

        // ================= the carriage =================
        // Two guide rails down the card's travel, a tick scale along the stretch it actually
        // moves through, and the gate it rests on. This is the part that was missing: the
        // upper four fifths of the screen was flat blank, so a 300px card crossing it had
        // nothing to be measured against and the motion read as small and arbitrary.
        //
        // Every mark here has a job — orientation, in the motion-design sense. The rails say
        // where the card can go, the ticks say how far it has come, the gate says where it
        // stops. None of it is texture; a shell that states depth with hairlines states a
        // mechanism with them too.
        Item {
            id: carriage
            z: 2
            anchors.fill: parent
            visible: opacity > 0
            opacity: win.guides ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: win.guides ? 130 : 90; easing.type: Easing.OutCubic } }

            // the two rails, set just outside the card's own width
            Repeater {
                model: 2
                Rectangle {
                    required property int index
                    width: Math.max(1, Math.round(win.ui))
                    y: win.gateY - 40 * win.ui
                    height: win.gapTop - y
                    x: index === 0 ? win.holoX - 16 * win.ui
                                   : win.holoX + win.holoW + 16 * win.ui
                    color: Tok.rule
                }
            }

            // the scale, on the stretch the card travels — inner ticks on both rails, so the
            // card runs down a measured channel rather than through space
            Repeater {
                model: Math.max(0, Math.floor((win.gapTop - win.gateY) / (26 * win.ui)))
                Item {
                    required property int index
                    readonly property real ty: win.gateY + index * 26 * win.ui
                    // every fourth tick is long and hard — a scale needs a rhythm to be read
                    readonly property bool major: (index % 4) === 0
                    Rectangle {
                        y: parent.ty; height: Math.max(1, Math.round(win.ui))
                        x: win.holoX - 16 * win.ui
                        width: (parent.major ? 11 : 6) * win.ui
                        color: parent.major ? Tok.ruleHard : Tok.rule
                    }
                    Rectangle {
                        y: parent.ty; height: Math.max(1, Math.round(win.ui))
                        width: (parent.major ? 11 : 6) * win.ui
                        x: win.holoX + win.holoW + 16 * win.ui - width
                        color: parent.major ? Tok.ruleHard : Tok.rule
                    }
                }
            }

        }

        // ================= the card =================
        // `bay` is everything ABOVE the opening, and it clips. That single fact is the whole
        // illusion: the card is a fixed-size object whose y travels DOWN, and the clip
        // boundary IS the slot's mouth, so the last 150ms of that travel is the card going
        // into the machine rather than shrinking or fading out of existence.
        Item {
            id: bay
            z: 3
            x: 0; y: 0
            width: win.width; height: win.gapTop
            clip: true
            visible: root.committing

            Rectangle {
                id: cart
                color: Tok.sunken
                clip: true
                radius: Tok.rSmall * win.ui
                border.width: 2
                border.color: Tok.accent

                // THE LABEL. The flying card used to be an image with an accent border —
                // anonymous, and a different object from the cartridges on the shelves in
                // Settings, which have a plate with a name on it and a keyed corner. Now it
                // is the same object, so the language is one thing rather than a motif
                // repeated at two sizes. It is also the only moment you can read what you
                // are loading without looking somewhere else on screen.
                //
                // It arrives during the ANTICIPATION DIP rather than being there from the
                // start: the rail's panels are projections and this is the one that has
                // become a physical thing, so the plate coming up as you take hold of it is
                // that transition, and the seam between panel and card stays invisible.
                property real plateH: 0

                Image {
                    id: cartImg
                    anchors { fill: parent; margins: cart.border.width
                              bottomMargin: cart.border.width + cart.plateH }
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: false; cache: true
                    sourceSize.width: preview.decodeW(root.item)
                    sourceSize.height: preview.decodeH(root.item)
                }

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                              margins: cart.border.width }
                    height: cart.plateH
                    color: Tok.raised
                    clip: true
                    Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                                height: Math.max(1, Math.round(win.ui)); color: Tok.ruleHard }
                    Row {
                        anchors { left: parent.left; leftMargin: Tok.s3 * win.ui
                                  right: parent.right; rightMargin: Tok.s3 * win.ui
                                  verticalCenter: parent.verticalCenter }
                        spacing: Tok.s2 * win.ui
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.item !== null && root.item.vid
                            text: "play_arrow"; font.family: "Material Symbols Outlined"
                            font.pixelSize: Math.round(14 * win.ui); color: Tok.ink3
                        }
                        IndText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, cart.width - Tok.s8 * win.ui)
                            text: root.item ? root.item.name : ""
                            mono: true; sz: Math.round(Tok.tData * win.ui); color: Tok.ink
                            elide: Text.ElideMiddle
                        }
                    }
                }

                // The keyed corner. `Tok.bg` reads as ABSENT material here and nowhere else
                // on this surface would: the lid covering the screen during the commit is
                // that exact colour, so the corner is genuinely showing the ground behind.
                Rectangle {
                    anchors { right: parent.right; top: parent.top; margins: cart.border.width }
                    width: Math.round(20 * win.ui); height: Math.round(11 * win.ui)
                    opacity: cart.plateH > 0 ? 1 : 0
                    color: Tok.bg
                    Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                width: Math.max(1, Math.round(win.ui)); color: Tok.ruleHard }
                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                height: Math.max(1, Math.round(win.ui)); color: Tok.ruleHard }
                }
            }

            // THE MOUTH. The clip boundary alone is a hard cut: the card was not swallowed
            // so much as erased a row of pixels at a time. This is the shadow the deck's
            // own lip throws onto whatever is entering it, so the last part of the travel
            // reads as going UNDER something.
            //
            // Bound to the card's x and width rather than the bay's, or it would draw a
            // dark band across the whole screen along the slot line; and faded in by how
            // much of the card is actually past the mouth, so it is not a smudge sitting
            // there while the card is still up at the gate.
            Rectangle {
                anchors.bottom: parent.bottom
                x: cart.x; width: cart.width
                height: Math.round(30 * win.ui)
                // Lit only while the card actually SPANS the mouth. Ramped over the first
                // 40px of entry, and back out over the last 40px as the top edge crosses —
                // measured over the card's full height it was still at full strength once
                // the card was entirely inside, which drew a dark gradient band across bare
                // ground with nothing under it to be the shadow of.
                opacity: {
                    var ramp = 40 * win.ui;
                    var inn  = (cart.y + cart.height - win.gapTop) / ramp;   // how much has entered
                    var left = (win.gapTop - cart.y) / ramp;                 // how much is still out
                    return Math.max(0, Math.min(1, Math.min(inn, left)));
                }
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.55; color: Tok.alpha(Qt.darker(Tok.sunken, 1.9), 0.42) }
                    GradientStop { position: 1.0; color: Tok.alpha(Qt.darker(Tok.sunken, 1.9), 0.92) }
                }
            }
        }

        SequentialAnimation {
            id: insert
            // 1 — anticipation. The card dips before it rises. It is the oldest trick in
            //     animation and the cheapest: 80ms of the wrong direction is what makes the
            //     pop read as force applied to an object rather than a position changing.
            //     The ground, the console and the carriage are fading in over this, and the
            //     rail's other frames are dropping away — see the delegate's `fall`.
            ParallelAnimation {
                NumberAnimation {
                    target: cart; property: "y"; to: cart.y + 9 * win.ui
                    duration: 80; easing.type: Easing.OutQuad
                }
                // …and the label comes up as you take hold of it. The projection on the
                // rail becomes a physical cartridge in the same 80ms the dip occupies, so
                // there is no frame where an object with a nameplate appears out of a panel
                // that never had one.
                NumberAnimation {
                    target: cart; property: "plateH"; to: 26 * win.ui
                    duration: 80; easing.type: Easing.OutCubic
                }
            }
            // 2 — pop, up the guides to the gate. OutBack overshoots a hair and settles: that
            //     recoil at the top is what makes it read as picked UP rather than slid.
            NumberAnimation {
                target: cart; property: "y"; to: win.gateY
                duration: 220; easing.type: Easing.OutBack
            }
            // 3 — held at the gate. Stillness shorter than about 80ms does not register as
            //     stillness, and without the beat the pop and the drop are one long slide.
            ScriptAction { script: win.phase = "insert" }
            PauseAnimation { duration: 100 }
            // 4 — down the channel. InQuad accelerates into the slot, because a push has no
            //     follow-through, and the clip takes it at the mouth. The shutter parts
            //     ahead of it — 130ms against a 210ms fall, so the way is open well before
            //     the card arrives and the machine is never seen being hit by it.
            ParallelAnimation {
                NumberAnimation {
                    target: cart; property: "y"; to: win.gapTop
                    duration: 210; easing.type: Easing.InQuad
                }
                NumberAnimation {
                    target: win; property: "shutter"; to: 1
                    duration: 130; easing.type: Easing.OutCubic
                }
            }
            // 5 — seated. The console takes the impact and settles, the shutter snaps shut
            //     behind the cartridge, the lamp reads contact, and the carriage marks drop
            //     out: they were orientation for a move that has now happened.
            ScriptAction { script: { win.phase = "seated"; win.guides = false } }

            ParallelAnimation {
                SequentialAnimation {
                    NumberAnimation { target: win; property: "jolt"; to: 4 * win.ui; duration: 45; easing.type: Easing.OutQuad }
                    NumberAnimation { target: win; property: "jolt"; to: 0;          duration: 65; easing.type: Easing.OutBack }
                }
                // Faster shut than open, and OutBack so it overshoots and settles: a
                // sprung leaf closing, not a panel sliding.
                NumberAnimation {
                    target: win; property: "shutter"; to: 0
                    duration: 105; easing.type: Easing.OutBack
                }
                // One ring, thrown off at the instant of contact and spent. It outlives the
                // jolt on purpose — the impact is over in 110ms and the eye needs longer
                // than that to register that anything was signalled.
                NumberAnimation {
                    target: win; property: "ring"; to: 1
                    duration: 420; easing.type: Easing.OutCubic
                }
            }
            // 6 — output. The wallpaper comes OUT of the aperture it just went into: the lid
            //     is eaten from its bottom edge upward and the console drops away, so the
            //     picture emerges from the slot rather than being uncovered by two panels
            //     leaving. In goes the cartridge, out comes the image, through one opening.
            ScriptAction { script: win.phase = "loaded" }
            ParallelAnimation {
                // OutQuint, because a reveal decelerates into place. InOutCubic accelerated
                // into the middle of the sweep — which is exactly where a 956px boundary
                // travelling at speed is most visible as a boundary.
                NumberAnimation { target: lid; property: "height"; to: 0
                                  duration: 460; easing.type: Easing.OutQuint }
                // …and it softens as it goes, so the edge stops being a hard line.
                NumberAnimation { target: lid; property: "opacity"; to: 0
                                  duration: 460; easing.type: Easing.InCubic }
                // The deck follows a beat behind rather than moving at the same instant:
                // follow-through, not two things at once. It travels its own full height so
                // the bezel, the well and the lip all clear the bottom of the screen.
                SequentialAnimation {
                    PauseAnimation { duration: 70 }
                    NumberAnimation { target: win; property: "deckShift"
                                      to: win.deckH * win.ui
                                      duration: 400; easing.type: Easing.OutQuint }
                }
                NumberAnimation { target: bay; property: "opacity"; to: 0; duration: 140 }
            }
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
            anchors.bottomMargin: (win.deckH + win.holoGap) * win.ui
            z: -1
            onClicked: if (!root.committing) root.leave()
        }
    }

    // One place the focus change fans out from: the preview reloads, and the rail closes
    // the gap unless the rail is what moved in the first place.
    onCurChanged: {
        preview.request();
        if (!rail.userMoving) rail.glideTo(root.cur);
    }
}
