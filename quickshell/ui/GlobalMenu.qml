// sea-shell — the global menu
//
// The focused window's own menu bar, drawn in the bar, in the place the window title
// otherwise occupies.
//
// IT IS INVISIBLE UNLESS IT HAS SOMETHING TO SAY. That is the whole design rule, and it is
// not politeness — it is what makes the feature survivable on Linux. Most windows on this
// desktop export no menu bar at all (a terminal has none, GTK4 apps put everything behind a
// hamburger, an Electron app with an HTML titlebar has no menu object at all), and a global
// menu that answers those with an empty strip is worse than no global menu: it takes the
// title away and gives back nothing. So `available` is false for anything without menus, the
// title comes back, and the bar looks exactly as it did before this file existed.
//
// WHERE THE MENUS COME FROM. sea-appmenu.py, via accessibility — see the long note at the
// top of that file for why DBusMenu cannot work here. It writes a JSON snapshot of the
// FOCUSED window on every focus change; this reads it. Focus is global, so the strip shows
// on the focused monitor only, which is also the only monitor where it would be true.
//
// TWO KINDS OF APPLICATION, and the difference used to be visible to the user in the worst
// possible way.
//
//   ready — Qt and GTK hand over their entire menu tree for free, nested submenus and all.
//           Nothing is opened, nothing flashes, the menu is simply there.
//
//   lazy  — Firefox and Electron report their top-level labels but build each menu only when
//           it is first opened, and that open is REAL: the application's own popup appears on
//           screen. The old version tried to get ahead of this by opening every menu of every
//           backgrounded window in advance, which meant that switching to a window mid-sweep
//           showed you all eight of your own Firefox menus popping open in turn. It now
//           happens ONCE PER MENU, on the click that asks for it, and is remembered for the
//           life of the window. A menu you never open costs nothing and is never touched.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick

Item {
    id: root

    // ---- wiring from the bar ----
    property var pal                         // the shell's palette object (NOT named
                                             // `theme`: the bar binds this from an object whose id
                                             // is `theme`, and a property of the same name shadows
                                             // that id inside the binding, so `theme: theme` would
                                             // resolve to itself)
    property string uiFont: "sans"
    property string script: ""               // absolute path to sea-appmenu.py
    property string screenName: ""           // the monitor THIS bar is on
    property string focusedMonitor: ""       // the monitor Hyprland says is focused
    property real ui: 1.0
    property int barEdgeY: 0                 // the bar's thickness, in native px
    // Which screen edge the bar is docked to. A menu bar hangs off the FREE side of the bar,
    // and for a bottom-docked bar that is upward — the cards were being placed one bar-height
    // from the TOP of the screen no matter where the bar was, so a bottom bar opened its menus
    // in the far corner with nothing connecting them to the thing that was clicked.
    property string barEdge: "top"
    // How much of the bar the strip may take before it starts folding menus away behind a
    // chevron. 0 means unbounded. LibreOffice exports twelve top-level menus; unbounded,
    // they pushed the media pill out of the centre of the bar.
    property real maxWidth: 0
    // How see-through the cards are. The bar binds its own `dropOpacity`, which is the
    // opacity slider with a floor under it, so the menu reads as the same material as the
    // bar it drops out of and as every other dropdown in the shell — one slider moves all
    // of them. It is a floor rather than the raw value because a menu at 0% would be an
    // unreadable set of floating labels, whereas a bar at 0% is a deliberate look.
    property real dropOpacity: 1.0
    readonly property color cardBg: root.pal ? Tok.alpha(root.pal.panel, root.dropOpacity)
                                             : "#181818"
    // Settings, from ~/.config/sea-shell/appmenu.json by way of the bar. NOT called
    // `enabled`: that is an Item property already, and shadowing it would switch off input
    // handling for the strip rather than switch off the feature.
    property bool featureOn: true
    property bool showKeys: true
    // Right-click the strip to hand the bar back to the workspaces. The bar owns the
    // setting, so this only asks.
    signal toggleRequested()

    // WHAT THE FOCUSED WINDOW IS, as far as the bar knows. Bound by the bar; its only job
    // is to CHANGE when you switch windows.
    //
    // The snapshot is meant to arrive by file watch, and usually does. But the sidecar
    // writes it the safe way — to a temp file, then rename — so every update swaps the
    // inode out from under the watcher, and a watcher that is following an inode rather
    // than a path silently stops hearing about it. When that happened the strip kept
    // drawing the PREVIOUS window's menus: VS Code's File/Edit/Selection sitting above a
    // music player, which is worse than showing nothing because the menu still worked and
    // still acted on the window it came from.
    //
    // So the watch is no longer the only way in. Switching windows is a thing the bar
    // already knows about first-hand, and it re-reads for a moment afterwards — the
    // daemon needs a beat to walk the new window and write — then stops. Twelve reads of
    // a small JSON file, only after an actual focus change, costs nothing measurable.
    property string focusHint: ""
    onFocusHintChanged: reread.restart()
    Timer {
        id: reread
        interval: 120
        repeat: true
        property int n: 0
        onRunningChanged: if (running) n = 0
        onTriggered: {
            snapFile.apply();
            n++;
            if (n > 12) stop();
        }
    }
    // AND A SLOW HEARTBEAT, because the two mechanisms above are both signals and a signal
    // that does not arrive leaves the wrong application's menus sitting in the bar for as
    // long as you leave them there. That is the worst failure this feature has: the strip
    // is not merely stale, it is a WORKING menu wired to a window you are no longer looking
    // at, and choosing something from it acts on that other window.
    //
    // Re-reading a small JSON file once a second costs nothing measurable and puts a hard
    // ceiling of one second on how wrong the bar can be. It is not a substitute for the
    // watch — it is the thing that means a missed watch is a blink instead of a bug.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: snapFile.apply()
    }

    // Keyboard entry points, bumped by the bar's "menu" IPC target. Counters rather than
    // signals because every strip on every monitor watches the same two numbers and only
    // the one on the focused screen is allowed to answer — see the note in shell.qml.
    property int openPing: 0
    property int searchPing: 0
    onOpenPingChanged: {
        if (!root.available) return;
        if (root.openIndex !== -1) { root.close(); return }
        // firstCell(), not `strip`. The strip now begins with the application's NAME, so
        // anchoring here put the card under that instead of under "File" — a card floating
        // one app-name to the left of the menu it belongs to, which is exactly as odd as it
        // sounds. It was right by accident for as long as the strip started at the first menu.
        root.openAt(0, root.firstCell());
        root.cursor = -1;
        root.step(1);
    }
    onSearchPingChanged: if (root.available) root.startSearch()

    // ---- the snapshot ----
    property var snap: ({ "menus": [], "mode": "none" })
    // EVERY MENU THE WINDOW HAS, including ones whose contents are not known yet. A `lazy`
    // entry is a real menu with a real label that simply has not been opened; it is drawn
    // and it works, it just costs one ~350ms read the first time it is clicked. The old
    // version hid these, which meant Firefox — the single most common window on most
    // desktops — showed no menu at all unless a background sweep had happened to reach it.
    readonly property var menus: (root.snap && root.snap.menus) ? root.snap.menus : []
    readonly property string mode: (root.snap && root.snap.mode) ? root.snap.mode : "none"
    readonly property int pid: (root.snap && root.snap.pid) ? root.snap.pid : 0

    // ---- who this menu belongs to ----
    // A mac menu bar reads mark → APPLICATION → its menus, and the middle term is not
    // decoration: without it a strip of File/Edit/View belongs to nothing in particular, and
    // on a desktop where the window with focus changes far more often than it does on a mac
    // that is a real question. It is a label, not a menu — the things a mac puts under the
    // app name (Preferences, Quit) live in the app's own File menu on Linux, and inventing
    // a menu whose items came from nowhere would be worse than not having one.
    //
    // Taken from the SNAPSHOT's class, never from Hyprland's focused window, so the name and
    // the menus under it always describe the same window. Reading Hyprland here would put
    // the new window's name over the old window's menus for the frame between the two.
    readonly property string appClass: (root.snap && root.snap["class"]) ? "" + root.snap["class"] : ""
    readonly property string appName: {
        var c = root.appClass;
        if (!c.length) return "";
        // The .desktop name is what the application calls ITSELF — "Visual Studio Code",
        // not "code"; "Dolphin", not "org.kde.dolphin".
        try {
            var e = DesktopEntries.heuristicLookup(c);
            if (e && e.name && ("" + e.name).length) return "" + e.name;
        } catch (err) {}
        var t = c.indexOf(".") >= 0 ? c.slice(c.lastIndexOf(".") + 1) : c;
        return t.length ? t.charAt(0).toUpperCase() + t.slice(1) : "";
    }

    // The strip belongs to the focused monitor. Comparing names rather than trusting the
    // snapshot's monitor id: the id is Hyprland's index and the bar only knows its name.
    readonly property bool onFocusedScreen:
        root.screenName.length > 0 && root.screenName === root.focusedMonitor
    readonly property bool available: root.featureOn && root.menus.length > 0
                                     && root.onFocusedScreen

    implicitWidth: root.available ? Math.ceil(stripWidth) : 0
    implicitHeight: parent ? parent.height : 22
    // An Item does not size itself to its implicit size; the bar's left group measures
    // children by `width`, so without these the strip would lay out as zero-wide.
    width: implicitWidth
    height: implicitHeight
    visible: root.available
    onAvailableChanged: if (!root.available) root.close()

    // A menu that is no longer the focused window's menu must not stay open over the next
    // one. Closing on pid change rather than on `available` alone catches the case where
    // you alt-tab between two applications that BOTH have menus.
    onPidChanged: root.close()

    FileView {
        id: snapFile
        path: Quickshell.env("HOME") + "/.cache/sea-shell/appmenu.json"
        watchChanges: true
        // The RAW text of the last snapshot that was accepted. The heartbeat below re-reads
        // this file once a second whether or not anything changed, and assigning root.snap
        // hands every derived property a brand-new object — new `menus`, new `levels`, new
        // arrays at every depth — so the open card's row Repeater tore itself down and rebuilt
        // once a second. On a small menu that was a flicker; on LibreOffice, whose File menu
        // is thirty rows, it was a visible flash. Comparing the text first makes an unchanged
        // heartbeat free, which is what a heartbeat is supposed to be.
        property string lastText: ""
        function apply() {
            try {
                reload();
                var t = text() || "";
                if (t === snapFile.lastText) return;
                snapFile.lastText = t;
                if (!t.trim()) { root.snap = { "menus": [], "mode": "none" }; return }
                root.snap = JSON.parse(t);
            } catch (e) {
                snapFile.lastText = "";
                root.snap = { "menus": [], "mode": "none" };
            }
        }
        onFileChanged: apply()
        onLoaded: apply()
        Component.onCompleted: apply()
    }

    // ---- what a lazily-built menu costs, and where the answer is kept ----
    //
    // Keyed by pid AND path, so that alt-tabbing between two windows of the same app cannot
    // serve one's menu under the other, and a nested path ("View/Toolbars") is remembered
    // separately from its parent. Pruned on focus change: a session's worth of menus for
    // windows that no longer exist is memory nobody asked for.
    property var cache: ({})
    property string loadingPath: ""
    function cacheKey(parts) { return root.pid + " " + parts.join("/") }
    function cached(parts) { var v = root.cache[root.cacheKey(parts)]; return v ? v : null }
    // NOT PRUNED ON FOCUS CHANGE. It used to keep only the focused window's entries, which
    // meant alt-tabbing away and back threw away everything that had been read and the next
    // click paid for it again — the "reading menu" flash on a menu you had already opened.
    // Entries are keyed by pid, so a stale one can never be served under another window; the
    // only cost of keeping them is memory, and it is bounded here rather than by forgetting
    // everything the moment you look at something else.
    function pruneCache() {
        var keys = Object.keys(root.cache);
        if (keys.length <= 240) return;
        var keep = {};
        for (var i = keys.length - 160; i < keys.length; i++) keep[keys[i]] = root.cache[keys[i]];
        root.cache = keep;
    }

    Process {
        id: reader
        stdout: StdioCollector {
            id: readerOut
            onStreamFinished: {
                root.loadingPath = "";
                try {
                    var j = JSON.parse((readerOut.text || "").trim() || "{}");
                    if (!j.path) return;
                    var next = {};
                    for (var k in root.cache) next[k] = root.cache[k];
                    // An empty answer is still an answer — remember it, or every click
                    // on an unreachable submenu would ask the application again.
                    next[root.pid + " " + j.path] = j.items || [];
                    root.cache = next;
                    root.pruneCache();
                } catch (e) {}
            }
        }
    }
    // The ONLY thing in this file that can make an application open a menu, and it runs on
    // a click. Never on hover, never on focus, never speculatively — see the header.
    function load(parts) {
        if (!root.script.length) return;
        var key = root.cacheKey(parts);
        if (root.cache[key] !== undefined || root.loadingPath.length) return;
        root.loadingPath = parts.join("/");
        reader.command = ["python3", root.script, "--submenu", root.loadingPath];
        reader.running = true;
    }

    // ---- measuring ----
    //
    // MEASURED, NOT GROWN. Every row in a menu is laid out to the SAME width, worked out
    // once for the whole card from the widest label and the widest accelerator in it. Letting
    // each row size itself is the obvious thing and it is wrong: the shortcuts then sit at a
    // different x on every line, and the one job a shortcut column has is to be a column —
    // "flush right, aligned vertically" is the oldest rule in the macOS menu guidelines and
    // the reason a menu can be read at a glance instead of item by item.
    // FontMetrics.advanceWidth(), NOT TextMetrics.width. TextMetrics measures a `text`
    // PROPERTY, and setting that property in a loop and reading the width back on the next
    // line returns the width of the PREVIOUS string — the value settles a turn later. Menus
    // came out one item too narrow and every long label rendered elided. advanceWidth() is a
    // plain function: ask, get an answer, no property in between.
    FontMetrics { id: fmItem; font.family: root.uiFont; font.pixelSize: 12 }
    FontMetrics { id: fmKey;  font.family: Tok.mono;   font.pixelSize: 11 }
    // Bold, so it is measured bold — a name sized with the regular face is clipped by
    // exactly the weight difference, which is a couple of pixels off the last letter.
    FontMetrics { id: fmName; font.family: root.uiFont; font.pixelSize: 12; font.bold: true }
    function textW(s) { return fmItem.advanceWidth(s || "") }
    function keyW(s) { return fmKey.advanceWidth(root.prettyKey(s)) }
    // "Ctrl+n" → "Ctrl+N". The toolkits report the physical key, which for a letter comes
    // back lower case while every modifier beside it is capitalised — so a column of
    // shortcuts read as a ransom note. Display only: the stored string is what the
    // application said, and nothing matches against these.
    function prettyKey(k) {
        if (!k) return "";
        return ("" + k).replace(/(^|\+)([a-z])$/,
                                function (m, p, c) { return p + c.toUpperCase() });
    }
    function cellW(label) { return Math.ceil(root.textW(label)) + 14 }

    // The name's own cell: a touch more room after it than between two menus, because it is
    // a different kind of thing and the gap is what says so.
    readonly property real nameW: root.appName.length
                                  ? Math.ceil(fmName.advanceWidth(root.appName)) + 20 : 0

    // Rows breathe a little more than they used to (22 → 24) and the card is padded to
    // match. A menu is a list you scan, and the thing that makes a list scannable is the
    // gap between its lines, not the size of its type.
    // How many cards the cascade can ever have on screen. See the note on the Repeater: this
    // is constant so that opening a submenu never rebuilds the ones already open.
    readonly property int maxDepth: 10

    readonly property int rowH: 24
    readonly property int sepH: 9
    readonly property int cardPadX: 6
    readonly property int cardPadY: 6
    // Rows inset from the card edge, so the highlight is a pill floating inside the card
    // rather than a band painted across it — the single detail that most separates a modern
    // menu from a 1990s one.
    readonly property int rowPadX: 10
    // The checkmark column, reserved for the whole card whenever ANY item in it can be
    // ticked — so labels do not jump sideways the moment something is switched on. macOS
    // reserves one too.
    //
    // It was 11, on the reasoning that the tick may overhang into the padding. It may not:
    // the glyph is drawn at 12px and the label began at 11, so a ticked row printed its
    // label ON TOP of its own checkmark — "✓Basic Page Style" with the two touching. The
    // column has to clear the widest thing that goes in it.
    readonly property int checkGutter: 16

    // Whether this level needs the left gutter at all — for a tick, a radio dot, or an
    // icon the application supplied. Measured here as well as drawn, or the card comes out
    // one gutter too narrow and every label ends up elided.
    function levelChecks(items) {
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            if (!it) continue;
            if (it.checked !== undefined) return true;
            if (it.icon && ("" + it.icon).length) return true;
        }
        return false;
    }
    function levelWidth(items) {
        var maxL = 0, maxK = 0, kids = false;
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            if (!it || it.sep) continue;
            var lw = root.textW(it.label);
            if (lw > maxL) maxL = lw;
            if (root.showKeys && it.key) {
                var kw = root.keyW(it.key);
                if (kw > maxK) maxK = kw;
            }
            if ((it.items && it.items.length) || it.stub) kids = true;
        }
        var w = (root.levelChecks(items) ? root.checkGutter : 0)
              + maxL + (maxK > 0 ? maxK + 26 : 0) + (kids ? 16 : 0)
              + (root.cardPadX + root.rowPadX) * 2 + 8;
        return Math.max(172, Math.ceil(w));
    }
    function levelHeight(items) {
        var h = 0;
        for (var i = 0; i < items.length; i++)
            h += (items[i] && items[i].sep) ? root.sepH : root.rowH;
        return h + root.cardPadY * 2;
    }
    function rowOffset(items, idx) {
        var y = 0;
        for (var i = 0; i < idx && i < items.length; i++)
            y += (items[i] && items[i].sep) ? root.sepH : root.rowH;
        return y;
    }

    // Where each card goes. A SUBMENU BELONGS BESIDE THE ROW THAT OPENED IT, not at the top
    // of the screen next to its parent card: three levels deep, a row of top-aligned cards
    // stops telling you which item you came through, and that is the only thing the cascade
    // is for. Each level is therefore offset down to its parent row and flipped to the left
    // of the chain when it would otherwise run off the edge.
    // The band the cards may occupy: the whole screen bar the strip itself, plus a 6px gap.
    // Everything below places by these two numbers rather than by "top of screen + bar", so
    // the same code serves a top bar and a bottom one.
    readonly property real screenH: (drop.height > 0 ? drop.height : 1080) / root.ui
    readonly property real bandTop: root.barEdge === "bottom" ? 6 : root.barEdgeY + 6
    readonly property real bandBot: root.barEdge === "bottom" ? root.screenH - root.barEdgeY - 6
                                                              : root.screenH - 6
    // A card that hangs off a bottom bar is placed by its BOTTOM edge, so it grows upward as
    // it gets taller instead of running off the screen.
    function anchorY(h) { return root.barEdge === "bottom" ? root.bandBot - h : root.bandTop }
    function clampY(y, h) { return Math.max(root.bandTop, Math.min(y, root.bandBot - h)) }

    readonly property var geom: {
        var out = [];
        var sw = (drop.width > 0 ? drop.width : 1920) / root.ui;
        var sh = (drop.height > 0 ? drop.height : 1080) / root.ui;
        for (var k = 0; k < root.levels.length; k++) {
            var items = root.levels[k];
            // CAPPED TO THE BAND. levelHeight() is the height the rows WANT; a menu with
            // more rows than the screen has room for was given exactly that, so clampY had
            // nothing valid to return, pinned the card to the top of the band, and every row
            // past the bottom of the screen was drawn off it — unreachable by pointer and
            // invisible to the arrow keys walking onto them. LibreOffice's File menu is
            // thirty-four rows: fine on this display, off the bottom on a 768px laptop, and
            // the kind of thing that only shows up on someone else's machine.
            var w = root.levelWidth(items);
            var want = root.levelHeight(items);
            var h = Math.min(want, root.bandBot - root.bandTop);
            var x, y;
            if (k === 0) {
                x = drop.hostX;
                y = root.anchorY(h);
            } else {
                var pg = out[k - 1];
                var pidx = root.openPath[k - 1];
                // A GAP, not an overlap. The cards used to sit 2px INSIDE each other, which
                // was fine when a card was a flat panel and is not fine now that its rows are
                // inset pills — two rounded corners touching read as one broken shape. The
                // gap is crossable because truncateSoon() holds the submenu open while the
                // pointer is in transit; without that grace period any gap at all would make
                // submenus unreachable by mouse.
                x = pg.x + pg.w + 4;
                y = pg.y + root.rowOffset(root.levels[k - 1], pidx);
                if (x + w > sw - 6) x = pg.x - w - 4;    // no room right: grow leftward
            }
            x = Math.max(6, Math.min(x, sw - w - 6));
            y = root.clampY(y, h);
            out.push({ "x": x, "y": y, "w": w, "h": h });
        }
        return out;
    }

    readonly property var cellWidths: {
        var out = [];
        for (var i = 0; i < root.menus.length; i++) out.push(root.cellW(root.menus[i].label));
        return out;
    }
    // How many menus fit before the chevron has to take over.
    readonly property int fitCount: {
        var n = root.menus.length;
        if (n === 0) return 0;
        if (root.maxWidth <= 0) return n;
        var total = root.nameW;
        for (var i = 0; i < n; i++) total += root.cellWidths[i] + 2;
        if (total <= root.maxWidth) return n;
        // The name is not negotiable — it is the one part of the strip that says whose
        // menus these are — so it comes off the budget before the menus compete for it.
        var budget = root.maxWidth - root.nameW - 22;      // room for the chevron
        var used = 0, k = 0;
        for (var j = 0; j < n; j++) {
            if (used + root.cellWidths[j] + 2 > budget) break;
            used += root.cellWidths[j] + 2;
            k++;
        }
        return Math.max(1, k);
    }
    readonly property bool overflowing: root.fitCount < root.menus.length
    readonly property real stripWidth: {
        var w = root.nameW;
        for (var i = 0; i < root.fitCount; i++) w += root.cellWidths[i] + 2;
        return w + (root.overflowing ? 22 : 0);
    }

    // One top-level menu label in the bar.
    component MenuCell: Rectangle {
        id: cell
        property int idx: 0
        readonly property var entry: root.menus[cell.idx]
        readonly property bool open: root.openIndex === cell.idx
        // A menu the application reports as disabled. Rare at the top level, but when it
        // happens the cell used to look exactly like a working one and clicking it did
        // nothing — which reads as the bar being broken rather than the menu being off.
        readonly property bool dead: !!(cell.entry && cell.entry.enabled === false)
        width: root.cellWidths[cell.idx] !== undefined ? root.cellWidths[cell.idx] : 0
        height: Math.max(18, root.height - 8)
        radius: Tok.r
        // Filled when open — the same accent-with-background-ink the selected row inside the
        // card uses, so the cell and the menu hanging off it read as one object. A 16% wash
        // over a 25%-opacity bar was, in practice, invisible.
        color: cell.dead ? "transparent"
                         : (cell.open ? root.pal.iris
                                      : (ma.containsMouse ? root.pal.a(root.pal.line, 0.55)
                                                          : "transparent"))
        // A menu bar is read by sweeping across it, and a label that snaps between three
        // inks as the pointer passes flickers. Both the shade and the ink cross-fade.
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Text {
            anchors.centerIn: parent
            text: cell.entry ? (cell.entry.label || "") : ""
            // The strip sits where the window title was, so it starts at the title's
            // weight. The open one lifts to full ink; nothing else shouts.
            color: cell.dead ? root.pal.faint
                             : (cell.open ? Tok.accentInk
                                          : (ma.containsMouse ? root.pal.text : root.pal.sub))
            font.pixelSize: 12
            font.family: root.uiFont
            Behavior on color { ColorAnimation { duration: Tok.mFast } }
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: cell.dead ? Qt.ArrowCursor : Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (e)=> {
                if (e.button === Qt.RightButton) { root.close(); root.toggleRequested(); return }
                if (cell.dead) return;
                root.toggle(cell.idx, cell);
            }
            // Once one menu is open, sliding across the strip moves between them,
            // the way a menu bar has always worked. Only while open: hover-to-open
            // from cold would fire every time the pointer crossed the bar.
            onEntered: if (root.openIndex >= 0 && root.openIndex !== cell.idx)
                           root.openAt(cell.idx, cell)
        }
    }

    // ---- the strip ----
    // Under the labels, so it only ever sees a right-click that missed one.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: { root.close(); root.toggleRequested(); }
    }
    Row {
        id: strip
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        // ---- the application ----
        // Deliberately NOT a MenuCell: it has no hover shade and no click, so sliding across
        // an open menu bar passes over it without the menus appearing to jump a slot, and the
        // strip's right-click (hand the bar back to the workspaces) still lands here because
        // nothing above it eats the event.
        Item {
            id: nameCell
            visible: root.appName.length > 0
            width: root.appName.length ? root.nameW : 0
            height: Math.max(18, root.height - 8)
            Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -3       // the trailing gap is the separation
                text: root.appName
                font.pixelSize: 12
                font.bold: true
                font.family: root.uiFont
                color: root.pal ? root.pal.text : "#eee"
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
            }
        }
        Repeater {
            id: cellRep
            model: root.fitCount
            delegate: MenuCell {
                required property int index
                idx: index
            }
        }
        // The fold. Everything that did not fit, as an ordinary menu of its own.
        Rectangle {
            id: moreCell
            visible: root.overflowing
            width: root.overflowing ? 20 : 0
            height: Math.max(18, root.height - 8)
            radius: Tok.r
            color: root.openIndex === -2 ? root.pal.iris
                                         : (moreMa.containsMouse ? root.pal.a(root.pal.line, 0.55)
                                                                 : "transparent")
            Behavior on color { ColorAnimation { duration: Tok.mFast } }
            Text {
                anchors.centerIn: parent
                text: "more_horiz"
                font.family: "Material Symbols Outlined"
                font.pixelSize: 14
                color: root.openIndex === -2 ? Tok.accentInk
                                             : (moreMa.containsMouse ? root.pal.text : root.pal.sub)
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
            }
            MouseArea {
                id: moreMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (root.openIndex === -2) { root.close(); return }
                    root.openIndex = -2;
                    root.openHost = moreCell;
                    root.openPath = [];
                    root.cursor = -1;
                    root.searching = false;
                    drop.shown = true;
                }
            }
        }
    }

    // The item every keyboard-opened card hangs off: the first top-level menu. Falls back to
    // the strip itself before the delegates exist (the very first frame, and any moment the
    // window has menus the strip has not laid out yet).
    function firstCell() {
        var c = null;
        try { c = cellRep.itemAt(0); } catch (e) {}
        return c ? c : strip;
    }

    // ---- open / close ----
    property int openIndex: -1               // -1 none, -2 the overflow fold
    property Item openHost: null
    // Which submenu is open at each depth. [] is just the top menu's own items; [3, 1]
    // means item 3 of those, then item 1 of that submenu's items.
    property var openPath: []
    // Where the keyboard is. Indexes the DEEPEST open level; -1 means nothing selected,
    // which is the state the mouse leaves things in.
    property int cursor: -1
    property bool searching: false
    property string query: ""

    // The items at each level, derived rather than stored: one source of truth for "what is
    // open" means a stale path can never draw a card belonging to another menu. Contents
    // come from the snapshot when the toolkit gave them up for free, and from the cache when
    // they had to be asked for.
    readonly property var levels: {
        var out = [];
        if (root.openIndex === -2) {
            // The fold draws the menus that did not fit, as rows that open like any other.
            var rest = [];
            for (var r = root.fitCount; r < root.menus.length; r++) {
                var mr = root.menus[r];
                var kidsr = (mr.items && mr.items.length) ? mr.items : root.cached([mr.label]);
                rest.push({ "label": mr.label, "enabled": true,
                            "items": kidsr ? kidsr : [], "stub": !(kidsr && kidsr.length) });
            }
            out.push(rest);
            for (var q = 0; q < root.openPath.length; q++) {
                var pick = out[q][root.openPath[q]];
                if (!pick || !pick.items || !pick.items.length) break;
                out.push(pick.items);
            }
            return out;
        }
        if (root.openIndex < 0) return out;
        var m = root.menus[root.openIndex];
        if (!m) return out;
        var parts = [m.label];
        var items = (m.items && m.items.length) ? m.items : root.cached(parts);
        if (!items || !items.length) return out;
        out.push(items);
        for (var k = 0; k < root.openPath.length; k++) {
            var it = items[root.openPath[k]];
            if (!it) break;
            parts = parts.concat([it.label]);
            var sub = (it.items && it.items.length) ? it.items : root.cached(parts);
            if (!sub || !sub.length) break;
            items = sub;
            out.push(items);
        }
        return out;
    }
    // A submenu was opened and produced no card. Either it is still being fetched, or the
    // toolkit will not hand it over at all — Gecko builds a nested menu only while its parent
    // is open AND hovered, which accessibility cannot do. Either way the click has to produce
    // something: silently doing nothing is indistinguishable from the menu being broken, and
    // that is exactly what it looked like.
    readonly property bool deadEnd: root.openIndex !== -1 && root.levels.length > 0
                                    && root.openPath.length >= root.levels.length
    readonly property var deadGeom: {
        if (!root.deadEnd) return null;
        var k = root.levels.length;
        var pg = root.geom[k - 1];
        if (!pg) return null;
        var w = 268, h = 42;
        var sw = (drop.width > 0 ? drop.width : 1920) / root.ui;
        var x = pg.x + pg.w - 2;
        var y = pg.y + root.rowOffset(root.levels[k - 1], root.openPath[k - 1]);
        if (x + w > sw - 6) x = pg.x - w + 2;
        return { "x": Math.max(6, Math.min(x, sw - w - 6)), "y": y, "w": w, "h": h };
    }

    // The label path to whatever is open at `level`, which is what the sidecar resolves by.
    function pathTo(level) {
        if (root.openIndex < -1) {
            // inside the fold, the first level IS a list of top-level menus
            var fp = [];
            for (var f = 0; f < level && f < root.openPath.length; f++) {
                var fit = root.levels[f] ? root.levels[f][root.openPath[f]] : null;
                if (!fit) break;
                fp.push(fit.label);
            }
            return fp;
        }
        if (root.openIndex < 0) return [];
        var parts = [root.menus[root.openIndex].label];
        for (var k = 0; k < level && k < root.openPath.length; k++) {
            var it = root.levels[k] ? root.levels[k][root.openPath[k]] : null;
            if (!it) break;
            parts.push(it.label);
        }
        return parts;
    }

    function close() {
        root.openIndex = -1;
        root.openHost = null;
        root.openPath = [];
        root.cursor = -1;
        root.searching = false;
        root.query = "";
        drop.shown = false;
    }

    function toggle(i, host) {
        if (root.openIndex === i) { root.close(); return }
        root.openAt(i, host);
    }

    function openAt(i, host) {
        var m = root.menus[i];
        if (!m) return;
        root.openIndex = i;
        root.openHost = host;
        root.openPath = [];
        root.cursor = -1;
        root.searching = false;
        drop.shown = true;
        // A menu whose contents nobody knows yet gets read here, on this click, and
        // never anywhere else.
        if (!(m.items && m.items.length)) root.load([m.label]);
    }

    // Open item `index` of level `level`, discarding anything deeper — walking back up a
    // cascade and along a different branch must not leave the old branch's cards on screen.
    function descend(level, index) {
        // ALREADY EXACTLY HERE? Do nothing.
        //
        // This is the flash. Moving the pointer out of a submenu and back onto the row that
        // opened it re-fires that row's onEntered, which rebuilt openPath as a brand-new array
        // holding the same numbers. A new openPath means a new `levels`, which means every
        // card's `modelData` is handed a fresh reference, which means the row Repeater inside
        // the submenu tore itself down and built itself again — one frame of empty card, on
        // every trip back up the cascade. Nothing about the menu had changed; only the
        // identity of the arrays describing it.
        if (root.openPath.length === level + 1 && root.openPath[level] === index) return;
        // AND CALL OFF ANY PENDING CLOSE. This is what made a submenu open and then vanish a
        // quarter-second later: hovering a row that has to be FETCHED does not descend (a
        // fetch makes the application's own popup flash, so it needs a click), it schedules
        // the grace-period close like any other plain row. The click that followed opened the
        // submenu but left that timer armed, and it fired into the menu it had been scheduled
        // against — closing the thing that had just been asked for. Descending is a
        // commitment; nothing scheduled before it should outlive it.
        root.holdOpen();
        // The cascade has a fixed number of cards; a level past the last one would open
        // something that cannot be drawn. No real menu comes close.
        if (level + 1 >= root.maxDepth) return;
        var next = root.openPath.slice(0, level);
        next.push(index);
        root.openPath = next;
        var it = root.levels[level] ? root.levels[level][index] : null;
        // A `stub` is a submenu the toolkit refused to describe in advance. Chromium will
        // build one on request; Firefox only builds nested menus while their parent is open
        // and hovered, which AT-SPI cannot do, so that one comes back empty and is then
        // remembered as empty rather than asked for again.
        if (it && !(it.items && it.items.length))
            root.load(root.pathTo(level).concat([it.label]));
    }
    function truncate(level) {
        root.holdOpen();
        if (root.openPath.length > level) root.openPath = root.openPath.slice(0, level);
    }
    // THE MENU TRIANGLE, the cheap version.
    //
    // Moving the pointer from a row into the submenu that row opened is a DIAGONAL move: it
    // goes right, and on the way it passes over the rows below. Closing the submenu the
    // instant a plain row is entered means the submenu disappears out from under the pointer
    // that was travelling to it — you can only reach it by going exactly horizontally first,
    // which nobody does. macOS solves this by watching whether you are heading towards the
    // submenu; a short grace period gets almost all of the benefit for none of the geometry.
    // Entering ANY row cancels it, including a row of the submenu itself, so arriving is what
    // calls it off.
    Timer {
        id: keepOpen
        interval: 260
        property int level: 0
        onTriggered: root.truncate(keepOpen.level)
    }
    function truncateSoon(level) { keepOpen.level = level; keepOpen.restart() }
    function holdOpen() { keepOpen.stop() }

    Process { id: invoker }
    // The sidecar resolves by label path, so the chain has to be rebuilt from what is open.
    function activate(level, label) {
        if (!root.script.length || root.openIndex === -1) return;
        var parts = root.pathTo(level);
        parts.push(label);
        root.activatePath(parts);
    }
    function activatePath(parts) {
        if (!root.script.length || !parts || !parts.length) return;
        root.close();
        invoker.command = ["python3", root.script, "--invoke", parts.join("/")];
        invoker.running = true;
    }

    // ---- search ----
    //
    // The reason a global menu is worth having at all on a big application. LibreOffice
    // exports fifty-four nested submenus; finding "Insert > Header and Footer > Header" by
    // hand is four hovers and a memory of which top-level menu it lives under. Typing "head"
    // is neither. Only menus whose contents are actually known can be searched — for a lazy
    // application that means the ones you have opened, which is stated rather than hidden.
    readonly property var flat: {
        var out = [];
        if (!root.searching) return out;
        function walk(items, parts, depth) {
            if (!items || depth > 5) return;
            for (var i = 0; i < items.length; i++) {
                var it = items[i];
                if (!it || it.sep || !it.label) continue;
                var here = parts.concat([it.label]);
                var kids = (it.items && it.items.length) ? it.items : root.cached(here);
                if (kids && kids.length) walk(kids, here, depth + 1);
                else if (it.enabled !== false && !it.stub)
                    out.push({ parts: here, label: it.label, key: it.key || "" });
            }
        }
        for (var m = 0; m < root.menus.length; m++) {
            var mm = root.menus[m];
            var top = [mm.label];
            var its = (mm.items && mm.items.length) ? mm.items : root.cached(top);
            if (its && its.length) walk(its, top, 0);
        }
        return out;
    }
    // Top-level menus whose contents nobody has asked for yet. Zero for an application that
    // publishes its menu as data; for one that builds each menu on first open it is however
    // many you have not clicked — and those are exactly the ones search cannot see.
    readonly property int unreadMenus: {
        var n = 0;
        for (var i = 0; i < root.menus.length; i++) {
            var m = root.menus[i];
            var its = (m.items && m.items.length) ? m.items : root.cached([m.label]);
            if (!its || !its.length) n++;
        }
        return n;
    }
    property bool priming: false
    Process {
        id: primeAll
        command: ["python3", root.script, "--prime-all"]
        onExited: {
            root.priming = false;
            // The sidecar rewrites the snapshot as it goes; this pulls the finished one in
            // so the search list grows the moment the reading stops.
            snapFile.apply();
            root.cache = root.cache;          // nudge anything derived from the cache
        }
    }
    function primeEverything() {
        if (root.priming || !root.script.length) return;
        root.priming = true;
        primeAll.running = true;
    }

    readonly property var hits: {
        if (!root.searching) return [];
        var q = root.query.toLowerCase().trim();
        if (!q.length) return [];
        var out = [];
        for (var i = 0; i < root.flat.length && out.length < 40; i++) {
            var f = root.flat[i];
            var hay = f.parts.join(" ").toLowerCase();
            var ok = true, from = 0;
            // subsequence match over the whole path, so "inhead" finds Insert > Header
            for (var c = 0; c < q.length; c++) {
                if (q.charAt(c) === " ") continue;
                var at = hay.indexOf(q.charAt(c), from);
                if (at < 0) { ok = false; break }
                from = at + 1;
            }
            if (!ok) continue;
            // an exact hit in the leaf label sorts above a scattered one in the path
            out.push({ f: f, rank: f.label.toLowerCase().indexOf(q) >= 0 ? 0 : 1 });
        }
        out.sort(function (a, b) { return a.rank - b.rank });
        return out.map(function (o) { return o.f });
    }
    function startSearch() {
        if (root.openIndex === -1) {
            if (!root.menus.length) return;
            root.openIndex = 0;
            root.openHost = root.firstCell();
            drop.shown = true;
        }
        root.openPath = [];
        root.searching = true;
        root.query = "";
        root.cursor = 0;
    }

    // ---- keyboard ----
    //
    // A menu bar you cannot drive from the keyboard is half a menu bar. Everything below is
    // what a menu has done since 1984: arrows walk, Right opens, Left backs out, Enter fires,
    // Escape lets go one level at a time. Separators and disabled rows are stepped over
    // rather than landed on.
    function rowUsable(it) {
        if (!it || it.sep) return false;
        if (it.items && it.items.length) return true;
        if (it.stub) return true;
        return it.enabled !== false;
    }
    function step(dir) {
        var items = root.levels[root.levels.length - 1];
        if (!items || !items.length) return;
        var i = root.cursor;
        for (var n = 0; n < items.length; n++) {
            i = (i + dir + items.length * 2) % items.length;
            if (root.rowUsable(items[i])) { root.cursor = i; return }
        }
    }
    function typeAhead(ch) {
        var items = root.levels[root.levels.length - 1];
        if (!items || !items.length) return;
        var c = ch.toLowerCase();
        for (var n = 1; n <= items.length; n++) {
            var i = (root.cursor + n + items.length) % items.length;
            var it = items[i];
            if (root.rowUsable(it) && (it.label || "").toLowerCase().indexOf(c) === 0) {
                root.cursor = i; return;
            }
        }
    }
    function moveTop(dir) {
        if (root.openIndex < 0 || !root.menus.length) return;
        var i = (root.openIndex + dir + root.menus.length) % root.menus.length;
        root.openAt(i, root.openHost);
    }
    function enterRow() {
        var lvl = root.levels.length - 1;
        var items = root.levels[lvl];
        var it = items ? items[root.cursor] : null;
        if (!it) return;
        if ((it.items && it.items.length) || it.stub) {
            root.descend(lvl, root.cursor);
            root.cursor = 0;
            return;
        }
        if (it.enabled !== false) root.activate(lvl, it.label);
    }
    function onKey(e) {
        if (e.key === Qt.Key_Escape) {
            if (root.searching) { root.searching = false; root.query = ""; root.cursor = -1 }
            else if (root.openPath.length) { root.openPath = root.openPath.slice(0, -1); root.cursor = 0 }
            else root.close();
            e.accepted = true; return;
        }
        if (root.searching) {
            if (e.key === Qt.Key_Down) {
                root.cursor = Math.min(root.cursor + 1, root.hits.length - 1); e.accepted = true;
            } else if (e.key === Qt.Key_Up) {
                root.cursor = Math.max(root.cursor - 1, 0); e.accepted = true;
            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                var h = root.hits[root.cursor];
                if (h) root.activatePath(h.parts);
                e.accepted = true;
            }
            return;                            // everything else belongs to the field
        }
        switch (e.key) {
        case Qt.Key_Down:  root.step(1);  e.accepted = true; break;
        case Qt.Key_Up:    root.step(-1); e.accepted = true; break;
        case Qt.Key_Home:  root.cursor = -1; root.step(1); e.accepted = true; break;
        case Qt.Key_End:   root.cursor = 0;  root.step(-1); e.accepted = true; break;
        case Qt.Key_Right: {
            var items = root.levels[root.levels.length - 1];
            var it = items ? items[root.cursor] : null;
            if (it && ((it.items && it.items.length) || it.stub)) {
                root.descend(root.levels.length - 1, root.cursor);
                root.cursor = 0;
            } else root.moveTop(1);
            e.accepted = true; break;
        }
        case Qt.Key_Left:
            if (root.openPath.length) { root.openPath = root.openPath.slice(0, -1); root.cursor = 0 }
            else root.moveTop(-1);
            e.accepted = true; break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.enterRow(); e.accepted = true; break;
        default:
            if (e.key === Qt.Key_F && (e.modifiers & Qt.ControlModifier)) {
                root.startSearch(); e.accepted = true; break;
            }
            if (e.text === "/") { root.startSearch(); e.accepted = true; break }
            if (e.text && e.text.length === 1 && e.text >= " ") {
                root.typeAhead(e.text); e.accepted = true;
            }
        }
    }

    // ---- the dropdown ----
    //
    // A CASCADE, not a list. LibreOffice hands over 54 nested submenus already populated,
    // and drawing only the first level meant "File > Recent Documents" rendered as a row
    // that looked clickable and would have fired the wrong thing. Each level is its own
    // card in a Row, so the chain of what you have opened stays on screen — which is the
    // only way to know where you are once you are three menus deep.
    PanelWindow {
        id: drop
        property bool shown: false
        visible: drop.shown && root.available
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:drop"
        WlrLayershell.layer: WlrLayer.Overlay
        // An open menu owns the keyboard, which is what lets arrows walk it and what stops
        // a keystroke meant for the menu reaching the window underneath. Escape and a click
        // anywhere both give it back, and the strip closes itself on focus change, so there
        // is no state in which this holds the keyboard with nothing on screen.
        WlrLayershell.keyboardFocus: drop.shown ? WlrKeyboardFocus.Exclusive
                                                : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; left: true; right: true; bottom: true }
        // An open menu takes the whole screen's clicks, because that is what an open menu
        // does everywhere: the next click either chooses something or dismisses it, and it
        // does not also press whatever was underneath. Masking only the card would leave
        // the click-anywhere-to-close below unreachable — the mask decides what the surface
        // can even receive, so a MouseArea outside it is drawn and never hit.
        mask: Region { item: drop.shown ? drop.contentItem : null }
        onVisibleChanged: if (drop.visible) navScope.forceActiveFocus()

        readonly property real scrX: drop.screen ? drop.screen.x : 0
        readonly property real hostX: {
            if (!root.openHost) return 0;
            var p = root.openHost.mapToGlobal(Qt.point(0, 0));
            return (p.x - drop.scrX) / root.ui;
        }

        FocusScope {
            id: navScope
            anchors.fill: parent
            focus: true
            Keys.onPressed: (e) => root.onKey(e)

            // Anywhere else closes it, which is the one thing every menu on every desktop
            // does. Declared BEFORE the cards on purpose: later siblings sit on top in QML,
            // so this has to come first or it would swallow every click meant for an item.
            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }

            Item {
                id: cascade
                visible: !root.searching
                anchors.fill: parent

                Repeater {
                    // A FIXED NUMBER OF CARDS, SHOWN AND HIDDEN — not a list that grows and
                    // shrinks. This is the whole reason the cascade flashed, and it took two
                    // wrong fixes to find.
                    //
                    // A Repeater REGENERATES — destroys every delegate it has and builds them
                    // all again — whenever its model changes. Not just the delegates that
                    // moved: all of them. That is true when the model is a JS array whose
                    // identity changed (the first thing fixed here) AND when it is a plain
                    // number that went from 1 to 2 (what it was changed to, which is why the
                    // flash survived). Opening one submenu was therefore rebuilding the parent
                    // card and every row in it — thirty-four rows, in LibreOffice's case,
                    // which is precisely why it was worst there and nearly invisible in a
                    // short menu. Traced by counting delegate constructions:
                    //
                    //     CARDGONE 1 · CARDGONE 0 · ROWBUILD 0 ×34 · CARDBUILD 0 …
                    //
                    // A constant model never changes, so a card is CONSTRUCTED ONCE and after
                    // that only shown, hidden and re-pointed at different items. Ten is far
                    // past any real menu — Impress's deepest chain is three — and descend()
                    // refuses to go beyond it rather than opening a card that cannot draw.
                    model: root.maxDepth
                    delegate: Rectangle {
                        id: lvl
                        required property int index              // which level this is
                        readonly property var modelData: root.levels[lvl.index] || []
                        // Whether this card is one of the levels currently open.
                        readonly property bool live: lvl.index < root.levels.length
                                                     && lvl.modelData.length > 0
                        readonly property bool deepest: lvl.index === root.levels.length - 1
                        readonly property var g: root.geom[lvl.index]
                                                 || ({ "x": 6, "y": root.anchorY(30),
                                                       "w": 172, "h": 30 })
                        x: lvl.g.x
                        // Slides in FROM the bar, the way the dropdowns do — a card that
                        // simply exists at full opacity gives the eye nothing to follow from
                        // the thing that was clicked to the thing that opened. Each level of
                        // the cascade runs this on creation, so a submenu three deep arrives
                        // as its own small movement rather than the whole chain blinking.
                        property real slide: root.barEdge === "bottom" ? 7 : -7
                        y: lvl.g.y + lvl.slide
                        opacity: 0
                        visible: lvl.live || lvl.opacity > 0.01
                        // "Appearing" is now a state change, not a construction, so the entry
                        // animation hangs off that instead of Component.onCompleted. Going
                        // away is instant: a card that fades out while the pointer is already
                        // somewhere else is a card in the way.
                        onLiveChanged: {
                            if (lvl.live) {
                                lvl.slide = root.barEdge === "bottom" ? 7 : -7;
                                lvl.opacity = 0;
                                enterAnim.restart();
                            } else {
                                enterAnim.stop();
                                lvl.opacity = 0;
                                lvl.slide = 0;
                                lvl.hoverIdx = -1;      // never light a row of the last menu
                            }
                        }
                        Component.onCompleted: if (lvl.live) enterAnim.start()
                        ParallelAnimation {
                            id: enterAnim
                            NumberAnimation { target: lvl; property: "opacity"; to: 1.0
                                              duration: Tok.mFast }
                            NumberAnimation { target: lvl; property: "slide"; to: 0
                                              duration: Tok.mBase
                                              easing.type: Easing.Bezier
                                              easing.bezierCurve: Tok.mEnter }
                        }
                        // A gutter for check marks, but only where the level actually has
                        // something to check — otherwise every menu would carry an empty
                        // 15px margin it never uses.
                        readonly property bool anyChecks: {
                            for (var i = 0; i < lvl.modelData.length; i++)
                                if (lvl.modelData[i].checked !== undefined) return true;
                            return false;
                        }
                        // Icons share the check column rather than adding a second one: an
                        // item is checkable or it has a picture, essentially never both, and
                        // two gutters would indent every label in the menu twice over for
                        // the sake of the handful of rows that use either.
                        readonly property bool anyIcons: {
                            for (var i = 0; i < lvl.modelData.length; i++) {
                                var ic = lvl.modelData[i].icon;
                                if (ic && ("" + ic).length) return true;
                            }
                            return false;
                        }
                        readonly property real gutter: (lvl.anyChecks || lvl.anyIcons)
                                                       ? root.checkGutter : 0
                        readonly property real rowW: lvl.g.w - root.cardPadX * 2
                        // Which row this card is lighting up. The pointer wins while it is
                        // over the card, then the open path, then the keyboard cursor on the
                        // deepest level — the same precedence the per-row test used to encode,
                        // pulled out to one number so a single highlight can move to it.
                        property int hoverIdx: -1
                        // Whether row i is somewhere the highlight may sit. Separators are not
                        // rows, and a disabled leaf is not a destination — the keyboard already
                        // steps over them and the pointer should not light them.
                        function rowLit(i) {
                            if (i < 0 || i >= lvl.modelData.length) return false;
                            var it = lvl.modelData[i];
                            if (!it || it.sep) return false;
                            return !!(it.items && it.items.length) || !!it.stub
                                   || it.enabled !== false;
                        }
                        readonly property int activeIdx: {
                            if (lvl.hoverIdx >= 0) return lvl.hoverIdx;
                            if (root.openPath.length > lvl.index) return root.openPath[lvl.index];
                            if (lvl.deepest && root.cursor >= 0) return root.cursor;
                            return -1;
                        }
                        width: lvl.g.w
                        height: lvl.g.h
                        // Capped: rCard follows the user's radius slider and goes to 30,
                        // which on a 24px row is a lozenge rather than a menu.
                        radius: Math.min(12, Tok.rCard)
                        // Depth here is a background step and a rule, never a shadow — the
                        // card sits one surface above the bar and is outlined, full stop.
                        color: root.cardBg
                        border.width: 1
                        border.color: root.pal ? root.pal.line : "#333"

                        // The rows live in a Flickable so a menu taller than the screen can
                        // still be read. It only takes the wheel when there is somewhere to
                        // go, so an ordinary menu behaves exactly as it did.
                        Flickable {
                            id: rowsFlick
                            x: 0
                            y: root.cardPadY
                            width: lvl.g.w
                            height: Math.max(0, lvl.g.h - root.cardPadY * 2)
                            contentWidth: width
                            contentHeight: Math.max(0, root.levelHeight(lvl.modelData)
                                                       - root.cardPadY * 2)
                            clip: true
                            interactive: contentHeight > height
                            boundsBehavior: Flickable.StopAtBounds
                            // Walking off the bottom with the arrow keys has to bring the row
                            // with it, or the cursor is somewhere you cannot see.
                            function ensureVisible(i) {
                                if (contentHeight <= height || i < 0) return;
                                var top = root.rowOffset(lvl.modelData, i);
                                var bot = top + root.rowH;
                                if (top < contentY) contentY = top;
                                else if (bot > contentY + height) contentY = bot - height;
                            }

                        // THE highlight. There used to be one Rectangle per row, shown and
                        // hidden by a visible: binding, so walking a menu with the arrow keys
                        // read as a row switching off and another switching on somewhere else.
                        // One rectangle that travels turns the same walk into a continuous
                        // movement, which is the thing that says "these rows are one list".
                        Rectangle {
                            id: hilite
                            readonly property int idx: lvl.activeIdx
                            readonly property bool on: lvl.rowLit(hilite.idx)
                            // WHERE IT RESTS — the last row it was actually on, which is not
                            // the same as the row the pointer is over. Brushing a disabled item
                            // turns `on` off, and the y binding used to fall back to row 0: the
                            // highlight was still fading out, so the Behavior below was still
                            // armed, and it flew the length of the card to the top on its way
                            // out. Holding the last lit row means it fades where it stands.
                            //
                            // Assigned from onIdxChanged rather than from an `on` handler
                            // because the order in which two bindings notify is not something
                            // to rely on; this asks the same question `on` asks, directly.
                            property int restIdx: 0
                            // AND WHICH LIST THAT INDEX BELONGS TO.
                            //
                            // Cards are pooled now — one card serves every submenu that opens
                            // at its depth — so "row 4" means a different thing from one
                            // moment to the next. Gliding between two of those is the
                            // highlight visibly travelling across a menu it was never in,
                            // which is the jumping: it happens exactly when a reused card's
                            // new selection sits at a different offset from the old one.
                            //
                            // Travel only within one list. Anywhere else, be there already.
                            property var restList: null
                            property bool glide: false
                            onIdxChanged: {
                                if (!lvl.rowLit(hilite.idx)) return;
                                rowsFlick.ensureVisible(hilite.idx);
                                hilite.glide = (hilite.restList === lvl.modelData)
                                               && hilite.opacity > 0.5;
                                hilite.restList = lvl.modelData;
                                hilite.restIdx = hilite.idx;
                            }
                            x: root.cardPadX
                            width: lvl.rowW
                            height: root.rowH - 2
                            y: 1 + root.rowOffset(lvl.modelData, hilite.restIdx)
                            // Capped well under Tok.r: at the user's radius setting a 22px
                            // pill becomes a full capsule, and a capsule behind left-aligned
                            // text has a visibly different gap at each end.
                            radius: Math.min(7, Tok.r)
                            // SOLID, not a 16% wash. A translucent card over a bright
                            // wallpaper turned a 16% tint into "slightly different grey",
                            // and the selected row is the one thing in a menu that has to be
                            // unmistakable. Filled accent with the background colour as ink
                            // is the same treatment the focused workspace chip already uses,
                            // so the bar and its menus agree about what "chosen" looks like.
                            //
                            // Everything drawn ON it uses Tok.accentInk, which exists for
                            // exactly this and is not the same thing as the background colour:
                            // the accent is clamped into a readable lightness band, and its
                            // ink is the pure white / near-black that band was chosen against.
                            color: root.pal ? root.pal.iris : "#8ad"
                            opacity: hilite.on ? 1 : 0
                            // Set immediately above, on the same assignment that moves it:
                            // travel only between two rows of the same menu, and only when
                            // already on screen. An appearing highlight that slides in from
                            // wherever it last sat lights up two or three wrong rows on the
                            // way, which reads as the menu choosing for you.
                            Behavior on y {
                                enabled: hilite.glide
                                NumberAnimation { duration: Tok.mMicro
                                                  easing.type: Easing.Bezier
                                                  easing.bezierCurve: Tok.mMove }
                            }
                            Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                        }

                        Column {
                            id: colInner
                            x: root.cardPadX
                            y: 0
                            spacing: 0

                            Repeater {
                                // COUNT, NOT THE ARRAY — the same rule as the cascade above,
                                // and this is the one that was still being broken.
                                //
                                // `root.levels` is rebuilt on every openPath change, so every
                                // card's `modelData` binding re-evaluates, and a Repeater fed
                                // a JS array rebuilds every delegate when its model is
                                // reassigned — even to the identical contents. So opening or
                                // closing ONE submenu tore down and rebuilt the rows of EVERY
                                // card on screen, including the ones that had not changed.
                                //
                                // That is the flash, and it scales with the number of rows:
                                // invisible on a short menu, obvious on LibreOffice, whose
                                // File menu is thirty-four items. Keyed on the count, a row is
                                // built when a row appears and not otherwise — and a menu's
                                // item count does not change while you walk around inside it.
                                model: lvl.modelData.length
                                delegate: Item {
                                    id: rowIt
                                    required property int index
                                    readonly property var modelData: lvl.modelData[rowIt.index]
                                                                     || ({})
                                    readonly property bool isSep: !!modelData.sep
                                    // A submenu whose contents we already hold.
                                    readonly property bool hasKids:
                                        !isSep && !!modelData.items && modelData.items.length > 0
                                    // A submenu the toolkit would not describe in advance.
                                    // Chromium builds one on request; Firefox cannot, and
                                    // comes back empty. Either way it is drawn as a submenu
                                    // rather than as a leaf, because pretending it is a leaf
                                    // would fire the wrong action.
                                    readonly property bool isStub: !isSep && !!modelData.stub
                                    readonly property bool clickable:
                                        !isSep && !isStub && !hasKids && modelData.enabled !== false
                                    readonly property bool onPath:
                                        root.openPath.length > lvl.index
                                        && root.openPath[lvl.index] === index
                                    readonly property bool onCursor:
                                        lvl.deepest && root.cursor === index
                                    // The row the shared highlight is currently sitting on.
                                    // Everything inked on it flips to the card colour so it
                                    // stays legible against a filled accent.
                                    readonly property bool lit: hilite.on && lvl.activeIdx === rowIt.index
                                    width: lvl.rowW
                                    height: isSep ? root.sepH : root.rowH

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        // Inset to the row text, not run wall to wall: a rule
                                        // that touches both edges cuts the card in half, and a
                                        // separator is meant to group rows, not divide cards.
                                        x: root.rowPadX
                                        visible: rowIt.isSep
                                        width: Math.max(0, parent.width - root.rowPadX * 2)
                                        height: 1
                                        color: root.pal ? root.pal.a(root.pal.line, 0.55) : "#333"
                                    }
                                    // check / radio state, when the item carries one
                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: root.rowPadX
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !rowIt.isSep && rowIt.modelData.checked === true
                                        // A dot for one-of-these, a tick for this-is-on.
                                        // Drawing both as a tick said a set of mutually
                                        // exclusive options could all be chosen at once.
                                        text: rowIt.modelData.radio ? "radio_button_checked" : "check"
                                        font.family: "Material Symbols Outlined"
                                        font.pixelSize: rowIt.modelData.radio ? 11 : 12
                                        color: rowIt.lit ? Tok.accentInk
                                                         : (root.pal ? root.pal.iris : "#8ad")
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                    }
                                    // The application's own icon for this row, when it
                                    // named one. Freedesktop name, resolved by the theme —
                                    // an unknown name simply yields nothing and the row
                                    // draws as it always did.
                                    IconImage {
                                        visible: !rowIt.isSep && !!rowIt.modelData.icon
                                                 && rowIt.modelData.checked === undefined
                                        anchors.left: parent.left
                                        anchors.leftMargin: root.rowPadX - 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        implicitSize: 14
                                        source: rowIt.modelData.icon
                                                ? Quickshell.iconPath("" + rowIt.modelData.icon, true)
                                                : ""
                                        opacity: rowIt.lit ? 1.0
                                               : (rowIt.clickable || rowIt.hasKids || rowIt.isStub ? 0.9 : 0.4)
                                    }
                                    Text {
                                        id: rowTxt
                                        anchors.left: parent.left
                                        anchors.leftMargin: root.rowPadX + lvl.gutter
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !rowIt.isSep
                                        text: modelData.label || ""
                                        color: rowIt.lit
                                               ? Tok.accentInk
                                               : ((rowIt.clickable || rowIt.hasKids || rowIt.isStub)
                                                  ? (root.pal ? root.pal.text : "#eee")
                                                  : (root.pal ? root.pal.faint : "#777"))
                                        font.pixelSize: 12
                                        font.family: root.uiFont
                                        elide: Text.ElideRight
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                        width: Math.max(0, parent.width - root.rowPadX * 2 - lvl.gutter
                                               - (accTxt.visible ? accTxt.implicitWidth + 20 : 0)
                                               - ((rowIt.hasKids || rowIt.isStub) ? 16 : 2))
                                    }
                                    // The accelerator, mono so a column of them lines up, and
                                    // faint so it never competes with the name.
                                    Text {
                                        id: accTxt
                                        anchors.right: parent.right
                                        anchors.rightMargin: root.rowPadX
                                                             + ((rowIt.hasKids || rowIt.isStub) ? 16 : 2)
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: root.showKeys && !rowIt.isSep && !!modelData.key
                                        text: root.prettyKey(modelData.key)
                                        color: rowIt.lit ? Tok.alpha(Tok.accentInk, 0.75)
                                                         : (root.pal ? root.pal.faint : "#777")
                                        font.pixelSize: 11
                                        font.family: Tok.mono
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                    }
                                    Text {
                                        anchors.right: parent.right
                                        anchors.rightMargin: root.rowPadX - 3
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: rowIt.hasKids || rowIt.isStub
                                        text: "chevron_right"
                                        font.family: "Material Symbols Outlined"
                                        font.pixelSize: 13
                                        color: rowIt.lit
                                               ? Tok.accentInk
                                               : (rowIt.hasKids ? (root.pal ? root.pal.sub : "#aaa")
                                                                : (root.pal ? root.pal.faint : "#777"))
                                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                    }
                                    MouseArea {
                                        id: ima
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: !rowIt.isSep
                                        cursorShape: rowIt.clickable ? Qt.PointingHandCursor
                                                                     : Qt.ArrowCursor
                                        // Hover opens a submenu that is already known and
                                        // closes any deeper one, the way every cascading menu
                                        // has always behaved. It does NOT fetch an unknown
                                        // one: hovering is not asking, and a fetch makes the
                                        // application's own popup flash. That needs a click.
                                        onEntered: {
                                            lvl.hoverIdx = rowIt.index;
                                            root.holdOpen();
                                            if (lvl.deepest) root.cursor = rowIt.index;
                                            if (rowIt.hasKids) root.descend(lvl.index, rowIt.index);
                                            else root.truncateSoon(lvl.index);
                                        }
                                        // Guarded: leaving row 3 for row 4 fires row 4's
                                        // onEntered FIRST, and an unguarded reset would then
                                        // blank the index that had just been set.
                                        onExited: if (lvl.hoverIdx === rowIt.index) lvl.hoverIdx = -1
                                        onClicked: {
                                            if (rowIt.hasKids || rowIt.isStub) {
                                                root.descend(lvl.index, rowIt.index);
                                                return;
                                            }
                                            if (rowIt.clickable) root.activate(lvl.index, modelData.label);
                                        }
                                    }
                                }
                            }
                            // What a lazily-built menu looks like while the application is
                            // being asked. It is one menu and about a third of a second, and
                            // saying so is better than an empty card.
                            Item {
                                visible: lvl.deepest && root.loadingPath.length > 0
                                         && lvl.modelData.length === 0
                                width: lvl.rowW
                                height: root.rowH
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: root.rowPadX
                                    text: "reading menu"
                                    color: root.pal ? root.pal.faint : "#777"
                                    font.pixelSize: 12
                                    font.family: root.uiFont
                                    font.italic: true
                                }
                            }
                        }
                        }

                        // "there is more this way" — only while there is. Two small fades
                        // rather than arrows: a menu that can scroll is rare enough that a
                        // control would be furniture, but the eye still needs telling that
                        // the list does not end where the card does.
                        Rectangle {
                            visible: rowsFlick.contentY > 1
                            x: 1; y: 1; width: lvl.g.w - 2; height: 12
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: root.cardBg }
                                GradientStop { position: 1.0; color: "transparent" }
                            }
                        }
                        Rectangle {
                            visible: rowsFlick.contentHeight - rowsFlick.contentY
                                     > rowsFlick.height + 1
                            x: 1; width: lvl.g.w - 2; height: 12
                            y: lvl.g.h - height - 1
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: root.cardBg }
                            }
                        }
                    }
                }
            }

            // A submenu that is being read, or that cannot be read at all, drawn beside the
            // row that asked for it.
            Rectangle {
                id: deadCard
                visible: !root.searching && drop.shown && root.deadEnd && root.deadGeom !== null
                x: root.deadGeom ? root.deadGeom.x : 0
                y: root.deadGeom ? root.deadGeom.y : 0
                width: root.deadGeom ? root.deadGeom.w : 268
                height: root.deadGeom ? root.deadGeom.h : 42
                radius: Tok.r
                color: root.cardBg
                border.width: 1
                border.color: root.pal ? root.pal.line : "#333"
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    x: root.cardPadX
                    width: parent.width - root.cardPadX * 2
                    spacing: 2
                    Text {
                        text: root.loadingPath.length ? "reading this menu" : "this submenu is not readable"
                        color: root.pal ? root.pal.sub : "#aaa"
                        font.pixelSize: 12
                        font.italic: root.loadingPath.length > 0
                        font.family: root.uiFont
                    }
                    Text {
                        visible: !root.loadingPath.length && root.mode === "lazy"
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "turn on the global-menu prefs in about:config"
                        color: root.pal ? root.pal.faint : "#777"
                        font.pixelSize: 10
                        font.family: root.uiFont
                    }
                }
            }

            // The card for a top-level menu that turned out to be unreachable, so a click
            // never looks like it did nothing at all.
            Rectangle {
                visible: !root.searching && drop.shown && root.openIndex !== -1
                         && root.levels.length === 0
                y: root.anchorY(height)
                x: Math.max(6, Math.min(drop.hostX, (drop.width / root.ui) - width - 6))
                width: 200
                height: 34
                radius: Math.min(12, Tok.rCard)
                color: root.cardBg
                border.width: 1
                border.color: root.pal ? root.pal.line : "#333"
                Text {
                    anchors.centerIn: parent
                    text: root.loadingPath.length ? "reading menu" : "this menu will not open"
                    color: root.pal ? root.pal.faint : "#777"
                    font.pixelSize: 12
                    font.italic: root.loadingPath.length > 0
                    font.family: root.uiFont
                }
            }

            // ---- the search card ----
            Rectangle {
                id: searchCard
                visible: root.searching
                y: root.anchorY(height)
                x: Math.max(6, Math.min(drop.hostX, (drop.width / root.ui) - width - 6))
                width: 340
                height: 30 + (root.query.length ? Math.min(root.hits.length, 10) * 22 + 8 : 24)
                radius: Math.min(12, Tok.rCard)
                color: root.cardBg
                border.width: 1
                border.color: root.pal ? root.pal.line : "#333"

                Item {
                    id: fieldRow
                    x: 10; y: 0
                    width: parent.width - 20
                    height: 29
                    Text {
                        id: mag
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "search"
                        font.family: "Material Symbols Outlined"
                        font.pixelSize: 13
                        color: root.pal ? root.pal.faint : "#777"
                    }
                    TextInput {
                        id: field
                        anchors.left: mag.right
                        anchors.leftMargin: 7
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.pal ? root.pal.text : "#eee"
                        font.pixelSize: 12
                        font.family: root.uiFont
                        selectByMouse: true
                        selectionColor: root.pal ? root.pal.a(root.pal.iris, 0.35) : "#345"
                        focus: true
                        onTextChanged: { root.query = text; root.cursor = 0 }
                        Keys.onPressed: (e) => root.onKey(e)
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !field.text.length
                            text: "search menus"
                            color: root.pal ? root.pal.faint : "#777"
                            font: field.font
                        }
                    }
                }
                Rectangle {
                    y: 29
                    width: parent.width
                    height: 1
                    color: root.pal ? root.pal.a(root.pal.line, 0.75) : "#333"
                }
                // Only what is loaded can be searched, and for a lazy application that is
                // whatever you have opened. Saying so beats looking broken.
                Text {
                    visible: !root.query.length
                    x: 10; y: 35
                    text: root.priming
                          ? "reading every menu — this flashes, once"
                          : (root.unreadMenus > 0
                             ? root.flat.length + " commands · " + root.unreadMenus + " menus unread"
                             : root.flat.length + " commands")
                    color: root.pal ? root.pal.faint : "#777"
                    font.pixelSize: 11
                    font.family: root.uiFont
                }
                // SEARCH CAN ONLY SEARCH WHAT IS KNOWN, and for an application that builds
                // each menu on first open that is however much you happen to have clicked.
                // This is the one-time payment: every unread menu opened, read, remembered
                // and closed. It is a button rather than something done quietly because it
                // IS visible — the app's own menus flash past — and having been paid once
                // it is never paid again, in this session or the next.
                Rectangle {
                    id: readAllBtn
                    visible: root.unreadMenus > 0 || root.priming
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    y: 6
                    width: readAllTxt.implicitWidth + 18
                    height: 18
                    radius: Tok.r
                    color: root.priming ? root.pal.a(root.pal.iris, 0.18)
                          : (raMa.containsMouse ? root.pal.iris : root.pal.a(root.pal.iris, 0.18))
                    Behavior on color { ColorAnimation { duration: Tok.mFast } }
                    Text {
                        id: readAllTxt
                        anchors.centerIn: parent
                        text: root.priming ? "reading…" : "read all"
                        color: (raMa.containsMouse && !root.priming) ? Tok.accentInk
                                                                     : (root.pal ? root.pal.sub : "#aaa")
                        font.pixelSize: 10
                        font.family: Tok.mono
                    }
                    MouseArea {
                        id: raMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !root.priming
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.primeEverything()
                    }
                }
                Text {
                    visible: root.query.length > 0 && root.hits.length === 0
                    x: 10; y: 35
                    text: "nothing matches"
                    color: root.pal ? root.pal.faint : "#777"
                    font.pixelSize: 11
                    font.family: root.uiFont
                }
                Column {
                    x: 6; y: 34
                    width: parent.width - 12
                    visible: root.query.length > 0
                    Repeater {
                        model: Math.min(root.hits.length, 10)
                        delegate: Item {
                            id: hitRow
                            required property int index
                            readonly property var hit: root.hits[hitRow.index]
                            width: parent.width
                            height: 22
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 1
                                anchors.bottomMargin: 1
                                visible: root.cursor === hitRow.index || hitMa.containsMouse
                                radius: Tok.r
                                color: root.pal ? root.pal.a(root.pal.iris, 0.16) : "#2a2a3a"
                            }
                            Text {
                                id: hitPath
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                // the trail, so two items with the same name stay tellable apart
                                text: hitRow.hit
                                      ? hitRow.hit.parts.slice(0, -1).join(" / ") + " / " : ""
                                color: root.pal ? root.pal.faint : "#777"
                                font.pixelSize: 11
                                font.family: root.uiFont
                            }
                            Text {
                                anchors.left: hitPath.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: hitRow.hit ? hitRow.hit.label : ""
                                color: root.pal ? root.pal.text : "#eee"
                                font.pixelSize: 12
                                font.family: root.uiFont
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.showKeys && hitRow.hit && !!hitRow.hit.key
                                text: hitRow.hit ? root.prettyKey(hitRow.hit.key) : ""
                                color: root.pal ? root.pal.faint : "#777"
                                font.pixelSize: 11
                                font.family: Tok.mono
                            }
                            MouseArea {
                                id: hitMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.cursor = hitRow.index
                                onClicked: if (hitRow.hit) root.activatePath(hitRow.hit.parts)
                            }
                        }
                    }
                }
            }
        }
    }
}
