// Gaming tab inside the dashboard — laid out like a game library rather than a stats page: the
// selected game fills a banner with its Play button and covers sit under it on a sideways shelf.
// A large library opens up into a searchable grid. The play records run the full height beside
// them, and the playtime comes from Steam, so it exists even for games never run under game mode.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

Item {
    id: hub
    property bool active: false
    property var games: []
    property var summary: ({})
    property string selectedId: ""
    property string runningId: ""
    property string liveGameId: ""
    onLiveGameIdChanged: if (hub.active) hub.refresh()
    property string launchingId: ""
    property bool gameModeOn: false
    property bool ultraShellOff: false
    property bool barsReady: false
    // Nothing is drawn until the library has answered: an empty list is what "No games installed"
    // shows for, and the first open otherwise flashed it and then jumped.
    property bool loaded: false
    property var preflight: ({})
    readonly property var selectedProfile: hub.selected && hub.selected.profile ? hub.selected.profile : ({})
    signal launched()
    readonly property string script: Qt.resolvedUrl("sea-gaming.py").toString().replace("file://", "")
    readonly property string gameModeScript: Qt.resolvedUrl("sea-gamemode.sh").toString().replace("file://", "")

    readonly property var selected: {
        for (var i = 0; i < games.length; i++) if (games[i].appid === selectedId) return games[i];
        return games.length ? games[0] : null;
    }
    readonly property var sessions: summary.sessions || []
    readonly property var recentGames: games.filter(function (g) { return g.recent_seconds > 0; })
        .sort(function (a, b) { return b.recent_seconds - a.recent_seconds; })
    readonly property int recentTotal: recentGames.reduce(function (sum, g) { return sum + g.recent_seconds; }, 0)
    readonly property color track: Tok.alpha(Tok.ink, Tok.light ? 0.08 : 0.10)
    readonly property var runs: {
        if (!hub.runsForSelected) return hub.sessions;
        var id = hub.selected ? hub.selected.appid : "";
        return hub.sessions.filter(function (s) { return s.appid === id; });
    }
    property bool runsForSelected: false

    // Four covers fit the shelf and part of a fifth shows when there are more, which is what says
    // it scrolls. Past that the controls appear, and a small library never sees them.
    readonly property int recordsWidth: 392
    readonly property int shelfInset: 4
    readonly property int shelfGap: Tok.s4
    readonly property int coverText: 46
    readonly property int shelfFits: 4
    readonly property bool manyGames: games.length > shelfFits
    property bool showAll: false
    readonly property bool allGames: showAll && manyGames
    readonly property real shelfSpan: shelfBox.width - shelfInset * 2
    readonly property real railTile: Math.max(120, Math.min(
        (shelfSpan - shelfGap * shelfFits) / (shelfFits + 0.4),
        (hub.height * 0.5 - shelfInset * 2 - coverText) * 2 / 3))
    // The banner takes whatever the shelf, the status line and the library title leave.
    readonly property real bannerHeight: Math.max(200, hub.height - 28 - 32 - Tok.s4 * 3
        - (railTile * 1.5 + coverText + shelfInset * 2))
    readonly property int gridColumns: Math.max(2, Math.floor((shelfSpan + shelfGap) / (140 + shelfGap)))
    readonly property real gridTile: (shelfSpan - shelfGap * (gridColumns - 1)) / gridColumns
    readonly property real shelfTile: allGames ? gridTile : railTile

    property string search: ""
    property string shelfSort: "recent"
    property var shelfGames: []
    property string shelfKey: ""
    // Only a different list reaches the view. Changing a launch option replaces hub.games too, and
    // that must not rebuild every cover and throw away the scroll position.
    function rebuildShelf() {
        var list = hub.games.slice();
        if (hub.search.length)
            list = list.filter(function (g) { return g.name.toLowerCase().indexOf(hub.search) >= 0; });
        // The library arrives most recent first, and the two sorts that change it key on these.
        if (hub.allGames && hub.shelfSort === "played")
            list.sort(function (a, b) { return b.seconds - a.seconds; });
        else if (hub.allGames && hub.shelfSort === "name")
            list.sort(function (a, b) { return a.name.localeCompare(b.name); });
        var key = list.map(function (g) { return g.appid + "/" + g.seconds + "/" + hub.coverUrl(g); }).join("|");
        if (key === hub.shelfKey) return;
        hub.shelfKey = key;
        hub.shelfGames = list;
    }
    onGamesChanged: rebuildShelf()
    onSearchChanged: rebuildShelf()
    onShelfSortChanged: rebuildShelf()
    onAllGamesChanged: {
        hub.closeOptions();
        hub.rebuildShelf();
        Qt.callLater(hub.showSelected);
    }
    function showSelected() {
        for (var i = 0; i < hub.shelfGames.length; i++)
            if (hub.selected && hub.shelfGames[i].appid === hub.selected.appid)
                shelf.positionViewAtIndex(i, GridView.Contain);
    }
    function shelfTo(x) {
        shelfGlide.stop();
        var start = shelf.originX - shelf.leftMargin;
        var end = Math.max(start, shelf.originX + shelf.contentWidth + shelf.rightMargin - shelf.width);
        shelf.contentX = Math.max(start, Math.min(end, x));
    }
    function pageShelf(dir) {
        var start = shelf.originX - shelf.leftMargin;
        var end = Math.max(start, shelf.originX + shelf.contentWidth + shelf.rightMargin - shelf.width);
        shelfGlide.stop();
        shelfGlide.to = Math.max(start, Math.min(end, shelf.contentX + dir * shelf.cellWidth * hub.shelfFits));
        shelfGlide.start();
    }

    property bool optionsOpen: false
    function toggleOptions() {
        if (hub.optionsOpen) { hub.closeOptions(); return; }
        // Over the banner above its button; below it once the banner has shrunk to a strip.
        var b = banner.mapToItem(hub, 0, 0);
        var btn = optionsBtn.mapToItem(hub, 0, 0);
        optionsCard.x = btn.x + optionsBtn.width - optionsCard.width;
        optionsCard.y = hub.allGames ? b.y + banner.height + Tok.s2 : Math.max(b.y + Tok.s2, btn.y - optionsCard.height - Tok.s2);
        hub.optionsOpen = true;
        optionsCard.forceActiveFocus();
    }
    // Focus returns to the hub, or Esc would stop reaching the dashboard that closes on it.
    function closeOptions() {
        if (!hub.optionsOpen) return;
        hub.optionsOpen = false;
        hub.forceActiveFocus();
    }

    function fmt(sec) {
        sec = Math.round(sec || 0);
        if (sec < 60) return sec + "s";
        var m = Math.floor(sec / 60);
        if (m < 60) return m + "m";
        var h = Math.floor(m / 60);
        return h + "h " + (m % 60) + "m";
    }
    function fmtAgo(epoch) {
        if (!epoch) return "Never";
        var then = new Date(epoch * 1000), now = new Date();
        var dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000;
        if (epoch >= dayStart) return "Today";
        var days = Math.ceil((dayStart - epoch) / 86400);
        if (days === 1) return "Yesterday";
        if (days < 7) return days + " days ago";
        return then.toLocaleDateString(Qt.locale(), "d MMM" + (then.getFullYear() === now.getFullYear() ? "" : " yyyy"));
    }
    function fmtSize(bytes) {
        return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + " GB" : Math.round((bytes || 0) / 1e6) + " MB";
    }
    function coverUrl(g) { return g.art || g.icon || ""; }
    function refresh() {
        hub.barsReady = false;
        libProc.running = true;
        sumProc.running = true;
        preProc.running = true;
        var top = ToplevelManager.toplevels.values, running = "";
        for (var i = 0; i < top.length; i++) {
            var m = ("" + top[i].appId).match(/steam_app_(\d+)/);
            if (m) running = m[1];
            // Gamescope's window doesn't say which game is inside it.
            else if (top[i].appId === "gamescope" && !running) running = hub.launchingId;
        }
        if (!running && hub.liveGameId) running = hub.liveGameId;
        hub.runningId = running;
        if (running && running === hub.launchingId) hub.launchingId = "";
    }
    // Always the same columns in the same order, so numbers can be compared down the list.
    function runCells(st) {
        st = st || {};
        function has(v) { return v !== undefined && v !== null; }
        return [
            { v: has(st.fps_avg) ? "" + st.fps_avg : "–", l: "FPS" },
            { v: has(st.fps_1pct_low) ? "" + st.fps_1pct_low : "–", l: "1% low" },
            { v: has(st.gpu_avg) ? Math.round(st.gpu_avg) + "%" : "–", l: "GPU" },
            { v: has(st.gpu_temp_max) ? st.gpu_temp_max + "°C" : "–", l: "Peak" },
            { v: has(st.vram_peak) ? st.vram_peak + " GiB" : "–", l: "VRAM" }
        ];
    }
    function runTitle(run) {
        for (var i = 0; i < hub.games.length; i++) if (hub.games[i].appid === run.appid) return hub.games[i].name;
        return (run.title || "").trim() || "Game session";
    }
    function runWhen(run) {
        var ended = Date.parse(run.ended);
        if (isNaN(ended)) return "";
        return hub.fmtAgo(ended / 1000) + ", " + Qt.formatTime(new Date(ended), "HH:mm");
    }
    function applyProfile(appid, profile) {
        var next = [];
        for (var i = 0; i < hub.games.length; i++) {
            var g = hub.games[i];
            if (g.appid === appid) next.push(Object.assign({}, g, { profile: profile }));
            else next.push(g);
        }
        hub.games = next;
    }
    function patchProfile(patch) {
        // hub.selected, not selectedId: that stays empty until a cover is clicked, while the
        // banner is already showing the first game and its chips.
        if (!hub.selected) return;
        var appid = hub.selected.appid;
        hub.applyProfile(appid, Object.assign({}, hub.selectedProfile, patch));
        hub.patchQueue = hub.patchQueue.concat([{ appid: appid, patch: patch }]);
        hub.flushPatches();
    }
    // One write at a time: a Process already running ignores running = true, which lost the
    // second of two quick clicks, and the next poll then turned that chip back off.
    property var patchQueue: []
    function flushPatches() {
        if (patchProc.running || !hub.patchQueue.length) return;
        var next = hub.patchQueue[0];
        hub.patchQueue = hub.patchQueue.slice(1);
        patchProc.command = ["python3", hub.script, "profile-patch", next.appid, JSON.stringify(next.patch)];
        patchProc.running = true;
    }
    function play(appid) {
        if (!appid || appid === hub.runningId || appid === hub.launchingId) return;
        hub.launchingId = "" + appid;
        launchHold.restart();
        playProc.command = ["python3", hub.script, "play", "" + appid];
        playProc.running = true;
        hub.launched();
    }
    // By exact match: big picture can write Gamescope settings these presets don't cover, and those
    // should light none of them.
    function gamescopePresetKey(scope) {
        scope = (scope || "").trim();
        if (scope === "") return "";
        if (scope === "-W 1920 -H 1080 -f --") return "1080p";
        if (scope === "-W 1920 -H 1080 -w 1920 -h 1080 --") return "1080p-windowed";
        return "custom";
    }

    onActiveChanged: {
        if (hub.active) return;
        hub.barsReady = false;
        hub.closeOptions();
        hub.showAll = false;
        searchField.text = "";
    }

    Timer { interval: 8000; running: hub.active; repeat: true; onTriggered: hub.refresh() }
    Timer { id: launchHold; interval: 60000; repeat: false; onTriggered: hub.launchingId = "" }
    Process {
        id: playProc
        command: ["python3", hub.script, "play", "0"]
        stdout: StdioCollector { }
        stderr: StdioCollector { }
    }

    Process {
        id: artProc
        command: ["python3", hub.script, "set-art", "0", ""]
        onExited: hub.refresh()
    }
    function pickArt(reset) {
        if (!hub.selected || artProc.running) return;
        if (reset) {
            artProc.command = ["python3", hub.script, "set-art", hub.selected.appid, ""];
            artProc.running = true;
            return;
        }
        // The dashboard is an overlay layer and would cover the file picker, so it steps aside
        // until a picture is chosen.
        Quickshell.execDetached(["sh", "-c",
            "qs -c sea-shell ipc call dashboard close; python3 \"$1\" pick-art \"$2\"; qs -c sea-shell ipc call dashboard gaming",
            "sh", hub.script, hub.selected.appid]);
    }

    Process {
        id: patchProc
        command: ["python3", hub.script, "profile-patch", "0", "{}"]
        onExited: hub.flushPatches()
    }
    Process {
        id: preProc
        command: ["python3", hub.script, "preflight"]
        stdout: StdioCollector { id: preOut; onStreamFinished: {
            try { hub.preflight = JSON.parse(preOut.text.trim()) || ({}); } catch (e) { hub.preflight = ({}); }
        } }
    }
    Process {
        id: libProc
        command: ["python3", hub.script, "library"]
        property string last: ""
        stdout: StdioCollector { id: libOut; onStreamFinished: {
            // Unchanged polls leave the model alone, or every cover would rebuild and blink.
            hub.loaded = true;
            if (libOut.text === libProc.last) {
                if (hub.active && !hub.barsReady) barsDefer.restart();
                return;
            }
            libProc.last = libOut.text;
            try { hub.games = JSON.parse(libOut.text.trim()) || []; } catch (e) { hub.games = []; }
            if (hub.active) barsDefer.restart();
        } }
    }
    // Let the playtime tracks get a real width before animating — otherwise the first
    // gaming-tab open animates 6px → full width and reads as a bar bursting out of bounds.
    Timer { id: barsDefer; interval: 50; repeat: false
        onTriggered: { if (hub.active) hub.barsReady = true } }
    Process {
        id: sumProc
        command: ["python3", hub.script, "summary", "--days", "7"]
        property string last: ""
        stdout: StdioCollector { id: sumOut; onStreamFinished: {
            // Unchanged polls leave the list alone, or reading it would jump back to the top.
            if (sumOut.text === sumProc.last) return;
            sumProc.last = sumOut.text;
            try { hub.summary = JSON.parse(sumOut.text.trim()) || ({}); } catch (e) { hub.summary = ({}); }
        } }
    }
    FileView {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sea-gamemode.json"
        watchChanges: true
        printErrors: false
        function apply() { try { hub.gameModeOn = !!JSON.parse(text()).on; } catch (e) {} }
        Component.onCompleted: apply()
        onLoaded: apply()
        onFileChanged: reload()
    }
    FileView {
        path: Quickshell.env("HOME") + "/.config/sea-shell/appearance.json"
        watchChanges: true
        printErrors: false
        function apply() { try { hub.ultraShellOff = !!JSON.parse(text()).suspendShellGaming; } catch (e) {} }
        Component.onCompleted: apply()
        onLoaded: apply()
        onFileChanged: reload()
    }
    function toggleUltraShell() {
        var next = !hub.ultraShellOff;
        hub.ultraShellOff = next;
        Quickshell.execDetached(["python3", "-c",
            "import json,os,pathlib,sys; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell/appearance.json')); " +
            "p.parent.mkdir(parents=True,exist_ok=True); " +
            "d=json.loads(p.read_text()) if p.is_file() else {}; " +
            "d['suspendShellGaming']=(sys.argv[1]=='1'); " +
            "t=p.with_suffix('.json.tmp'); t.write_text(json.dumps(d,indent=2)); os.replace(t,p)",
            next ? "1" : "0"]);
    }

    component PlaytimeBar: Item {
        id: pb
        property real amount: 0          // 0..1
        Layout.fillWidth: true
        implicitHeight: 6
        Rectangle {
            id: track
            anchors.fill: parent
            radius: 3
            color: hub.track
            clip: true
            Rectangle {
                id: fill
                height: parent.height
                radius: 3
                color: Tok.accent
                readonly property real clamped: Math.max(0, Math.min(1, pb.amount))
                width: track.width > 0
                       ? Math.max(clamped > 0 ? 6 : 0, track.width * clamped)
                       : 0
                Behavior on width {
                    enabled: hub.barsReady && !Tok.reducedMotion
                    NumberAnimation { duration: Tok.mSlow; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // Drawn: the icon font's FILL axis renders play_arrow with holes.
    component PlayGlyph: Canvas {
        width: 14
        height: 16
        onPaint: {
            var c = getContext("2d");
            c.fillStyle = "#101114";
            c.lineJoin = "round";
            c.lineWidth = 2;
            c.strokeStyle = "#101114";
            c.beginPath();
            c.moveTo(1.5, 1.5);
            c.lineTo(12.5, 8);
            c.lineTo(1.5, 14.5);
            c.closePath();
            c.fill();
            c.stroke();
        }
    }

    component HeroFact: ColumnLayout {
        property string label: ""
        property string value: ""
        spacing: 1
        // Always light: these sit on the banner's dark scrim in both themes.
        IndText { text: parent.label; sz: Tok.tData; color: Qt.rgba(1, 1, 1, 0.72) }
        IndText { text: parent.value; sz: Tok.tDense; color: "white"; font.weight: Font.DemiBold }
    }

    // Dark, because the art under the banner's corner can be nearly white.
    component BannerPill: Rectangle {
        id: pill
        property string label: ""
        property bool lit: false
        signal clicked()
        implicitWidth: pillLbl.implicitWidth + Tok.s4 * 2
        implicitHeight: 40
        radius: height / 2
        color: pillMa.containsMouse || pill.lit ? Qt.rgba(0, 0, 0, 0.72) : Qt.rgba(0, 0, 0, 0.52)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.24)
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText {
            id: pillLbl
            anchors.centerIn: parent
            text: pill.label
            sz: Tok.tDense
            color: "white"
            font.weight: Font.Medium
        }
        MouseArea {
            id: pillMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.clicked()
        }
    }

    component ColumnTitle: IndText {
        sz: Tok.tDense
        font.weight: Font.Bold
    }

    // Plain text button for the small controls beside a section title.
    component QuietBtn: Rectangle {
        id: quiet
        property string label: ""
        property bool lit: false
        signal clicked()
        implicitHeight: 28
        implicitWidth: quietLbl.implicitWidth + Tok.s3 * 2
        radius: Tok.r
        color: quiet.lit ? Tok.alpha(Tok.ink, 0.1)
             : quietMa.containsMouse ? Tok.alpha(Tok.ink, 0.06) : "transparent"
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText {
            id: quietLbl
            anchors.centerIn: parent
            text: quiet.label
            sz: Tok.tData
            color: quiet.lit || quietMa.containsMouse ? Tok.ink : Tok.ink2
            font.weight: quiet.lit ? Font.DemiBold : Font.Medium
        }
        MouseArea {
            id: quietMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quiet.clicked()
        }
    }

    // A vertical list scrolls with no other hint, so its thumb stays visible while it can move.
    component ScrollThumb: Rectangle {
        property Flickable view
        visible: view.contentHeight > view.height + 1
        anchors.right: view.right
        y: view.y + view.visibleArea.yPosition * view.height
        width: 4
        height: Math.max(24, view.visibleArea.heightRatio * view.height)
        radius: 2
        color: Tok.alpha(Tok.ink, 0.22)
    }

    // Moves the shelf a page at a time for anyone not scrolling it.
    component ShelfArrow: Rectangle {
        id: arrow
        property string glyph: ""
        signal clicked()
        y: shelf.topMargin + (hub.railTile * 1.5 - height) / 2
        width: 36
        height: 36
        radius: 18
        color: arrowMa.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.92)
        Text {
            anchors.centerIn: parent
            text: arrow.glyph
            font.family: "Material Symbols Outlined"
            font.pixelSize: 22
            color: "#101114"
        }
        MouseArea {
            id: arrowMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: arrow.clicked()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Tok.s4
        visible: hub.loaded

        // ---------- machine state, then the switch that changes it ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: Tok.s6

            Row {
                Layout.fillWidth: true
                clip: true
                spacing: Tok.s6
                Repeater {
                    model: hub.preflight.checks || []
                    delegate: Row {
                        required property var modelData
                        spacing: 6
                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                        // Only a problem gets colour, so a quiet line means nothing needs doing.
                        readonly property color problem: modelData.warn ? Tok.warn : Tok.crit
                        IndText {
                            text: modelData.label
                            sz: Tok.tData
                            color: modelData.ok ? Tok.ink3 : parent.problem
                        }
                        IndText {
                            text: modelData.detail
                            sz: Tok.tData
                            color: modelData.ok ? Tok.ink2 : parent.problem
                            font.weight: modelData.ok ? Font.Normal : Font.DemiBold
                        }
                    }
                }
            }
            QuietBtn {
                label: "Big picture"
                onClicked: {
                    hub.launched();
                    Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "bigpicture", "open"]);
                }
            }
            Rectangle {
                implicitHeight: 28
                implicitWidth: ultraRow.implicitWidth + 18
                radius: Tok.r
                color: hub.ultraShellOff
                    ? Tok.alpha(Tok.accent, ultraMa.containsMouse ? 0.24 : 0.16)
                    : (ultraMa.containsMouse ? Tok.raised : Tok.surface)
                border.width: 1
                border.color: hub.ultraShellOff ? Tok.alpha(Tok.accent, 0.55) : (ultraMa.containsMouse ? Tok.ruleHard : Tok.rule)
                Row {
                    id: ultraRow
                    anchors.centerIn: parent
                    spacing: 5
                    Sym {
                        text: "bolt"
                        sz: 13
                        color: hub.ultraShellOff ? Tok.accent : Tok.ink3
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    IndText {
                        text: hub.ultraShellOff ? "Zero-shell" : "Hibernate"
                        sz: Tok.tData
                        color: hub.ultraShellOff ? Tok.ink : Tok.ink2
                        font.weight: hub.ultraShellOff ? Font.DemiBold : Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: ultraMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: hub.toggleUltraShell()
                }
            }
            IndText { text: "Game mode"; sz: Tok.tDense; font.weight: Font.Medium }
            Toggle {
                on: hub.gameModeOn
                onToggled: Quickshell.execDetached(["sh", hub.gameModeScript, "toggle"])
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Tok.s6

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Tok.s4

                // ---------- the selected game ----------
                ClippingRectangle {
                    id: banner
                    Layout.fillWidth: true
                    Layout.preferredHeight: hub.allGames ? 72 : Math.round(hub.bannerHeight)
                    Behavior on Layout.preferredHeight { NumberAnimation { duration: Tok.mBase; easing.type: Easing.OutCubic } }
                    visible: hub.selected !== null
                    radius: Tok.rCard
                    color: Tok.alpha(Tok.accent, 0.25)

                    readonly property string art: hub.selected ? hub.selected.hero : ""
                    onArtChanged: {
                        // With no art of its own, the last game's picture would stay up behind this one.
                        artBack.source = banner.art && artFront.status === Image.Ready ? artFront.source : "";
                        artFront.opacity = 0;
                        artFront.source = banner.art;
                        if (artFront.status === Image.Ready) artFront.opacity = 1;
                    }

                    Image {
                        id: artBack
                        anchors.fill: parent
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        verticalAlignment: Image.AlignTop
                        sourceSize.width: 1600
                    }
                    Image {
                        id: artFront
                        anchors.fill: parent
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        verticalAlignment: Image.AlignTop
                        sourceSize.width: 1600
                        onStatusChanged: {
                            if (status === Image.Ready) opacity = 1;
                            else if (status === Image.Error) artBack.source = "";
                        }
                        Behavior on opacity { NumberAnimation { duration: Tok.mBase; easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.8) }
                            GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.42) }
                            GradientStop { position: 0.8; color: Qt.rgba(0, 0, 0, 0) }
                        }
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height * 0.6
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
                            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
                        }
                    }

                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: hub.allGames ? Tok.s4 : Tok.s6
                        spacing: Tok.s4

                        // Plain type, not Steam's logo.png: those are often padded out to a 16:9 canvas
                        // or too dark to read here.
                        IndText {
                            Layout.fillWidth: true
                            visible: !hub.allGames
                            text: hub.selected ? hub.selected.name : ""
                            sz: Tok.tKpi
                            color: "white"
                            font.weight: Font.Bold
                            elide: Text.ElideRight
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: hub.allGames ? Tok.s3 : Tok.s8

                            IndText {
                                Layout.fillWidth: true
                                visible: hub.allGames
                                text: hub.selected ? hub.selected.name : ""
                                sz: Tok.tPanel
                                color: "white"
                                font.weight: Font.Bold
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                readonly property bool isRunning: hub.selected && hub.selected.appid === hub.runningId
                                readonly property bool isLaunching: hub.selected && hub.selected.appid === hub.launchingId
                                implicitWidth: playRow.implicitWidth + Tok.s6 * 2 - Tok.s1
                                implicitHeight: 40
                                radius: height / 2
                                color: playMa.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.92)
                                opacity: isLaunching ? 0.85 : 1
                                scale: playMa.pressed ? 0.97 : 1
                                Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
                                Row {
                                    id: playRow
                                    anchors.centerIn: parent
                                    spacing: Tok.s2
                                    PlayGlyph {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !parent.parent.isRunning && !parent.parent.isLaunching
                                    }
                                    IndText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: parent.parent.isRunning ? "Playing now"
                                            : parent.parent.isLaunching ? "Launching…"
                                            : "Play"
                                        sz: Tok.tBody
                                        color: "#101114"
                                        font.weight: Font.DemiBold
                                    }
                                }
                                MouseArea {
                                    id: playMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: hub.play(hub.selected.appid)
                                }
                            }
                            HeroFact { visible: !hub.allGames; label: "Last played"; value: hub.selected ? hub.fmtAgo(hub.selected.last_played) : "" }
                            HeroFact { visible: !hub.allGames; label: "Play time"; value: hub.selected && hub.selected.seconds > 0 ? hub.fmt(hub.selected.seconds) : "None yet" }
                            HeroFact { visible: !hub.allGames; label: "On disk"; value: hub.selected ? hub.fmtSize(hub.selected.size) : "" }
                            Item { Layout.fillWidth: true; visible: !hub.allGames }
                            BannerPill {
                                visible: !hub.allGames && hub.selected !== null && !!hub.selected.custom_hero
                                label: "Reset background"
                                onClicked: hub.pickArt(true)
                            }
                            BannerPill {
                                visible: !hub.allGames && hub.selected !== null
                                label: "Background"
                                onClicked: hub.pickArt(false)
                            }
                            // Launch settings are changed rarely, so they wait behind a button
                            // instead of covering the art.
                            BannerPill {
                                id: optionsBtn
                                visible: hub.selected !== null && hub.selected.source === "steam"
                                label: "Launch options"
                                lit: hub.optionsOpen
                                onClicked: hub.toggleOptions()
                            }
                        }

                        IndText {
                            visible: !hub.allGames && hub.selected !== null && hub.selected.source !== "steam"
                            text: "Launch settings for this game are in " + ({ lutris: "Lutris", heroic: "Heroic", twintail: "TwintailLauncher", prism: "Prism Launcher" }[hub.selected ? hub.selected.source : ""] || "its launcher") + "."
                            sz: Tok.tData
                            color: Qt.rgba(1, 1, 1, 0.82)
                        }
                    }
                }

                // ---------- library ----------
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    spacing: Tok.s2
                    ColumnTitle { text: "Library" }
                    IndText {
                        visible: hub.games.length > 0
                        Layout.leftMargin: Tok.s1
                        text: hub.search.length ? hub.shelfGames.length + " of " + hub.games.length : hub.games.length
                        sz: Tok.tData
                        color: Tok.ink3
                    }
                    Item { Layout.fillWidth: true }
                    Repeater {
                        model: hub.allGames ? [
                            { k: "recent", l: "Recent" },
                            { k: "played", l: "Most played" },
                            { k: "name", l: "A to Z" }
                        ] : []
                        delegate: QuietBtn {
                            required property var modelData
                            label: modelData.l
                            lit: hub.shelfSort === modelData.k
                            onClicked: hub.shelfSort = modelData.k
                        }
                    }
                    IndField {
                        id: searchField
                        visible: hub.manyGames
                        Layout.preferredWidth: 170
                        Layout.leftMargin: Tok.s2
                        placeholder: "Search games"
                        onAccepted: if (hub.shelfGames.length) hub.selectedId = hub.shelfGames[0].appid
                        input.onTextChanged: hub.search = input.text.trim().toLowerCase()
                        input.Keys.onEscapePressed: event => {
                            if (input.text.length) input.text = "";
                            else event.accepted = false;
                        }
                    }
                    QuietBtn {
                        visible: hub.manyGames
                        label: hub.allGames ? "Back to shelf" : "All games"
                        onClicked: hub.showAll = !hub.showAll
                    }
                }

                // One view for both shapes, so opening every game keeps the same covers rather
                // than building a second set. Only covers near the view exist, whatever the library size.
                Item {
                    id: shelfBox
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    GridView {
                        id: shelf
                        anchors.fill: parent
                        // A grid counts the gap after its last column and takes its margins off
                        // the width, so the view reaches into the gutter for that column to fit.
                        anchors.rightMargin: hub.allGames ? -hub.shelfGap - 1 : 0
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        cacheBuffer: 400
                        leftMargin: hub.shelfInset
                        rightMargin: hub.shelfInset
                        topMargin: hub.shelfInset
                        bottomMargin: hub.shelfInset
                        flow: hub.allGames ? GridView.FlowLeftToRight : GridView.FlowTopToBottom
                        cellWidth: hub.shelfTile + hub.shelfGap
                        cellHeight: hub.allGames
                            ? hub.shelfTile * 1.5 + hub.coverText + hub.shelfGap
                            : Math.max(hub.shelfTile * 1.5 + hub.coverText, height - hub.shelfInset * 2)
                        model: hub.shelfGames

                        delegate: Item {
                            id: tile
                            required property var modelData
                            readonly property bool isSelected: hub.selected && hub.selected.appid === modelData.appid
                            width: hub.shelfTile
                            height: width * 1.5 + hub.coverText

                            Rectangle {
                                x: -3; y: -3
                                width: art.width + 6
                                height: art.height + 6
                                radius: Tok.r + 5
                                color: "transparent"
                                border.width: 2
                                border.color: tile.isSelected ? Tok.accent : "transparent"
                                Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                            }
                            ClippingRectangle {
                                id: art
                                width: parent.width
                                height: width * 1.5
                                radius: Tok.r + 2
                                color: hub.track
                                Image {
                                    id: cover
                                    anchors.fill: parent
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: 400
                                    source: hub.coverUrl(tile.modelData)
                                }
                                Sym {
                                    anchors.centerIn: parent
                                    visible: cover.status !== Image.Ready
                                    text: "sports_esports"
                                    sz: 32
                                    color: Tok.ink3
                                }
                            }
                            IndText {
                                anchors.top: art.bottom
                                anchors.topMargin: Tok.s2
                                width: parent.width
                                text: tile.modelData.name
                                sz: Tok.tDense
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            IndText {
                                anchors.top: art.bottom
                                anchors.topMargin: Tok.s2 + 19
                                width: parent.width
                                text: tile.modelData.seconds > 0 ? hub.fmt(tile.modelData.seconds) + " played" : "Not played yet"
                                sz: Tok.tData
                                color: Tok.ink3
                                elide: Text.ElideRight
                            }
                            MouseArea {
                                id: tileMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: hub.selectedId = tile.modelData.appid
                                onDoubleClicked: hub.play(tile.modelData.appid)
                            }
                            // Plays straight from the cover, so a selected game is not a required step.
                            Rectangle {
                                anchors.right: art.right
                                anchors.bottom: art.bottom
                                anchors.margins: Tok.s2
                                width: 40
                                height: 40
                                radius: 20
                                color: quickMa.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.92)
                                opacity: tileMa.containsMouse || quickMa.containsMouse ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                                PlayGlyph { anchors.centerIn: parent; anchors.horizontalCenterOffset: 1 }
                                MouseArea {
                                    id: quickMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: hub.play(tile.modelData.appid)
                                }
                            }
                        }

                        // A wheel only has an up and down, and the shelf only moves sideways.
                        WheelHandler {
                            enabled: !hub.allGames
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: event => {
                                var d = Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y)
                                    ? event.angleDelta.x : event.angleDelta.y;
                                hub.shelfTo(shelf.contentX - d * 1.5);
                            }
                        }
                        NumberAnimation {
                            id: shelfGlide
                            target: shelf
                            property: "contentX"
                            duration: Tok.mSlow
                            easing.type: Easing.OutCubic
                        }
                    }
                    ScrollThumb { view: shelf }
                    ShelfArrow {
                        visible: !hub.allGames && shelf.contentX > shelf.originX - shelf.leftMargin + 1
                        anchors.left: parent.left
                        anchors.leftMargin: Tok.s2
                        glyph: "chevron_left"
                        onClicked: hub.pageShelf(-1)
                    }
                    ShelfArrow {
                        visible: !hub.allGames && shelf.contentWidth + shelf.rightMargin > shelf.contentX + shelf.width + 1
                        anchors.right: parent.right
                        anchors.rightMargin: Tok.s2
                        glyph: "chevron_right"
                        onClicked: hub.pageShelf(1)
                    }
                    IndText {
                        x: hub.shelfInset
                        visible: hub.shelfGames.length === 0
                        text: hub.games.length === 0 ? "No games found in Steam, Heroic, Lutris, TwintailLauncher or Prism Launcher." : "No games match."
                        sz: Tok.tDense
                        color: Tok.ink3
                    }
                }
            }

            // ---------- play records ----------
            // One panel from the banner's top down to the shelf's foot, the same weight as the
            // left side however few runs there are.
            Rectangle {
                Layout.preferredWidth: hub.recordsWidth
                Layout.minimumWidth: hub.recordsWidth
                Layout.maximumWidth: hub.recordsWidth
                Layout.fillHeight: true
                radius: Math.min(18, Tok.r + 4)
                color: Tok.surface
                border.width: 1
                border.color: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Tok.s4
                    spacing: Tok.s3

                    RowLayout {
                        Layout.fillWidth: true
                        ColumnTitle { text: "Last two weeks"; Layout.fillWidth: true }
                        IndText {
                            text: hub.recentTotal > 0 ? hub.fmt(hub.recentTotal) : "Nothing played"
                            sz: hub.recentTotal > 0 ? Tok.tPanel : Tok.tDense
                            color: hub.recentTotal > 0 ? Tok.ink : Tok.ink3
                            font.weight: hub.recentTotal > 0 ? Font.DemiBold : Font.Normal
                        }
                    }
                    Repeater {
                        model: hub.recentGames.slice(0, 3)
                        delegate: RowLayout {
                            id: recentRow
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Tok.s3
                            readonly property real share: hub.recentTotal > 0
                                ? Math.min(1, (modelData.recent_seconds || 0) / hub.recentTotal)
                                : 0
                            ClippingRectangle {
                                implicitWidth: 28
                                implicitHeight: 42
                                radius: Tok.rSmall
                                color: hub.track
                                Image {
                                    anchors.fill: parent
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: 84
                                    source: hub.coverUrl(recentRow.modelData)
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Tok.s2
                                RowLayout {
                                    Layout.fillWidth: true
                                    IndText { text: recentRow.modelData.name; sz: Tok.tDense; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                                    IndText { text: hub.fmt(recentRow.modelData.recent_seconds); mono: true; sz: Tok.tDense; color: Tok.ink2 }
                                }
                                PlaytimeBar { amount: recentRow.share }
                            }
                        }
                    }

                    IndRule { Layout.fillWidth: true; Layout.topMargin: Tok.s2; Layout.bottomMargin: Tok.s1 }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Tok.s1
                        ColumnTitle { text: "Saved runs"; Layout.fillWidth: true }
                        QuietBtn { label: "All games"; lit: !hub.runsForSelected; onClicked: hub.runsForSelected = false }
                        QuietBtn { label: "This game"; lit: hub.runsForSelected; onClicked: hub.runsForSelected = true }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        IndText {
                            width: parent.width
                            visible: hub.runs.length === 0
                            text: (hub.runsForSelected && hub.selected ? "None for " + hub.selected.name + " yet. " : "None yet. ")
                                  + "Stats are saved when a game closes or game mode ends."
                            sz: Tok.tDense
                            color: Tok.ink2
                            wrapMode: Text.WordWrap
                        }
                        ListView {
                            id: runList
                            anchors.fill: parent
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: hub.runs
                            delegate: ColumnLayout {
                                id: runRow
                                required property var modelData
                                required property int index
                                width: runList.width
                                spacing: Tok.s2

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: runRow.index > 0 ? Tok.s3 : 0
                                    spacing: Tok.s3
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        IndText {
                                            Layout.fillWidth: true
                                            visible: !hub.runsForSelected
                                            text: hub.runTitle(runRow.modelData)
                                            sz: Tok.tDense
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                        }
                                        IndText {
                                            Layout.fillWidth: true
                                            text: hub.runWhen(runRow.modelData)
                                            sz: hub.runsForSelected ? Tok.tDense : Tok.tData
                                            color: hub.runsForSelected ? Tok.ink : Tok.ink2
                                            font.weight: hub.runsForSelected ? Font.DemiBold : Font.Normal
                                        }
                                    }
                                    IndText {
                                        Layout.alignment: Qt.AlignTop
                                        text: hub.fmt(runRow.modelData.seconds)
                                        mono: true
                                        sz: Tok.tDense
                                        font.weight: Font.DemiBold
                                    }
                                }
                                Row {
                                    id: runCells
                                    Layout.fillWidth: true
                                    Repeater {
                                        model: runRow.modelData.stats && Object.keys(runRow.modelData.stats).length ? hub.runCells(runRow.modelData.stats) : []
                                        delegate: Column {
                                            required property var modelData
                                            width: runCells.width / 5
                                            IndText {
                                                text: modelData.v
                                                mono: true
                                                sz: Tok.tDense
                                                font.weight: Font.Medium
                                                color: modelData.v === "–" ? Tok.ink3 : Tok.ink
                                            }
                                            IndText { text: modelData.l; sz: Tok.tLabel; color: Tok.ink2 }
                                        }
                                    }
                                }
                                IndText {
                                    visible: !runRow.modelData.stats || Object.keys(runRow.modelData.stats).length === 0
                                    text: "No GPU samples"
                                    sz: Tok.tData
                                    color: Tok.ink2
                                }
                                IndRule { Layout.fillWidth: true; Layout.topMargin: Tok.s1 }
                            }
                        }
                        ScrollThumb { view: runList; anchors.rightMargin: -Tok.s3 }
                    }
                }
            }
        }
    }

    // ---------- launch options, floating over the banner ----------
    MouseArea {
        anchors.fill: parent
        visible: hub.optionsOpen
        hoverEnabled: true
        onClicked: hub.closeOptions()
        onWheel: event => event.accepted = true
    }
    Rectangle {
        id: optionsCard
        visible: hub.optionsOpen
        width: 300
        height: optionsBody.implicitHeight + Tok.s4 * 2
        radius: Tok.rCard
        color: Tok.raised
        border.width: 1
        border.color: Tok.rule
        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.35)
            shadowBlur: 0.8
            shadowVerticalOffset: 6
        }
        MouseArea { anchors.fill: parent; hoverEnabled: true }
        Keys.onEscapePressed: hub.closeOptions()

        ColumnLayout {
            id: optionsBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Tok.s4
            spacing: Tok.s3

            Repeater {
                model: [
                    { k: "mangohud", l: "MangoHud", on: !!hub.selectedProfile.mangohud },
                    { k: "game_mode_on_play", l: "Game mode on play", on: hub.selectedProfile.game_mode_on_play !== false },
                    { k: "gamemode", l: "gamemoderun", on: hub.selectedProfile.gamemode !== false }
                ]
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    IndText { text: modelData.l; sz: Tok.tDense; Layout.fillWidth: true }
                    Toggle {
                        on: modelData.on
                        onToggled: {
                            var patch = {};
                            patch[modelData.k] = !modelData.on;
                            hub.patchProfile(patch);
                        }
                    }
                }
            }
            IndRule { Layout.fillWidth: true }
            IndText { text: "Gamescope"; sz: Tok.tDense }
            RowLayout {
                Layout.fillWidth: true
                spacing: Tok.s1
                Repeater {
                    model: [
                        { id: "", l: "Off" },
                        { id: "1080p", l: "1080p full" },
                        { id: "1080p-windowed", l: "1080p window" }
                    ]
                    delegate: QuietBtn {
                        required property var modelData
                        lit: hub.gamescopePresetKey(hub.selectedProfile.gamescope) === modelData.id
                        label: modelData.l
                        onClicked: {
                            var presets = { "": "", "1080p": "-W 1920 -H 1080 -f --",
                                            "1080p-windowed": "-W 1920 -H 1080 -w 1920 -h 1080 --" };
                            hub.patchProfile({ gamescope: presets[modelData.id] || "" });
                        }
                    }
                }
            }
        }
    }
}
