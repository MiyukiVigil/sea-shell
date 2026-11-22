// sea-shell — the first-run tour.
//
// Shown once, when appearance.json has no `welcomed` key, and reopenable forever after from
// Settings → System. `qs -c sea-shell ipc call welcome open`.
//
// WHY A TOUR AT ALL.  Everything here is already in the control center, and that is the
// problem: the control center has twenty tabs, and a shell you have just installed gives you
// no reason to believe any particular one of them is where the thing you want lives. Five
// screens is enough to make the four decisions that change how the desktop LOOKS, which are
// the four people go looking for first.
//
// IT WRITES AS YOU GO, not on finish. Every choice lands in appearance.json immediately and
// the bar behind this card changes while you watch — which is the only honest way to choose
// between "grow" and "circles", and it means quitting halfway keeps what you picked rather
// than discarding it. There is no cancel, because there is nothing to cancel.
//
// Config is written through sea-set-appearance.py rather than rebuilt here: settings.qml owns
// the whole file, and a second surface rewriting it from its own properties would silently
// reset every key it did not know about.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

Scope {
    id: root

    property bool shown: false
    property bool whatsNew: false
    property int step: 0
    // The applications list is a walk of every applications directory on the
    // machine, so it is read when that screen is reached rather than at startup.
    onStepChanged: if (step === 5 && root.defRoles.length === 0) root.defRefresh()
    readonly property int steps: 7
    readonly property var stepNames: ["Welcome", "Look", "Wallpaper", "The bar", "Menus", "Default apps", "All set"]
    readonly property color groupFill: Tok.surface
    readonly property color groupRule: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)

    readonly property string setScript:  Qt.resolvedUrl("sea-set-appearance.py").toString().replace("file://", "")
    readonly property string wpSet:      Qt.resolvedUrl("sea-wallpaper-set.sh").toString().replace("file://", "")
    readonly property string wpIndex:    Qt.resolvedUrl("sea-wallpaper-index.py").toString().replace("file://", "")
    readonly property string matugen:    Qt.resolvedUrl("matugen-accent.sh").toString().replace("file://", "")

    function open()   { root.whatsNew = false; root.step = 0; root.shown = true }
    function close()  { root.shown = false }
    // The flag is written when the tour is first SHOWN (see the timer below), so finishing is
    // only closing. Kept as its own function because the footer button says "finish" and
    // should not read as "cancel".
    function finish() { root.set("welcomed=true"); root.shown = false }

    // IPC target "welcome" lives in shell.qml so this file can unload while it is closed.

    // one or more `key=value` pairs, merged into appearance.json
    function set() {
        var args = ["python3", root.setScript];
        for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
        Quickshell.execDetached(args);
    }

    // ---------- current values, so the tour opens on what is actually set ----------
    property string curMode: "dark"
    property bool   curMatugen: false
    property string curAccent: "#63c7dd"
    property string curWsStyle: "grow"
    property string curWsLabel: "arabic"
    property string curBarShape: "bar"
    property string curBarLogo: "auto"
    property string curWpDir: "~/Pictures/wallpapers"

    // "auto" is resolved in shell.qml, and BarLogo itself has never heard the word — passing
    // it straight through fell through to the sea logo, so the welcome screen greeted a
    // CachyOS machine with someone else's mark. Same os-release read, same mapping.
    property string distroId: ""
    property string distroLike: ""
    FileView {
        id: osRelease
        path: "/etc/os-release"
        blockLoading: true
        Component.onCompleted: root.parseOsRelease(osRelease.text())
        onLoaded: root.parseOsRelease(osRelease.text())
    }
    function parseOsRelease(t) {
        if (!t) return;
        var lines = t.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var m = /^(ID|ID_LIKE)=(.*)$/.exec(lines[i].trim());
            if (!m) continue;
            var v = m[2].replace(/^"|"$/g, "").trim().toLowerCase();
            if (m[1] === "ID") root.distroId = v; else root.distroLike = v;
        }
    }
    readonly property string autoLogo: {
        var id = root.distroId;
        if (id === "cachyos") return "cachy";
        var known = ["arch","alpine","artix","debian","endeavouros","fedora","gentoo",
                     "manjaro","mint","nixos","opensuse","pop","ubuntu","void"];
        if (known.indexOf(id) >= 0) return id;
        if (id === "linuxmint") return "mint";
        if (id.indexOf("opensuse") === 0) return "opensuse";
        if (root.distroLike.indexOf("arch") >= 0) return "arch";
        if (root.distroLike.indexOf("debian") >= 0) return "debian";
        if (root.distroLike.indexOf("fedora") >= 0) return "fedora";
        return id.length ? "tux" : "sea";
    }
    property bool   welcomed: true          // assume yes: never surprise an existing install
                                            // because a read failed

    FileView {
        id: cfg
        path: Quickshell.env("HOME") + "/.config/sea-shell/appearance.json"
        blockLoading: true
        watchChanges: true
        Component.onCompleted: root.readCfg(cfg.text())
        onLoaded: root.readCfg(cfg.text())
        onFileChanged: { cfg.reload(); root.readCfg(cfg.text()) }
        onLoadFailed: root.welcomed = false      // no config at all IS a first run
    }
    function readCfg(t) {
        try {
            var j = JSON.parse(t || "{}");
            root.curMode     = ("" + j.mode) === "light" ? "light" : "dark";
            root.curMatugen  = !!j.matugen;
            if (j.accent)   root.curAccent   = "" + j.accent;
            if (j.wsStyle)  root.curWsStyle  = "" + j.wsStyle;
            if (j.wsLabel)  root.curWsLabel  = "" + j.wsLabel;
            if (j.barShape) root.curBarShape = "" + j.barShape;
            if (j.barLogo)  root.curBarLogo  = "" + j.barLogo;
            if (j.wpDir)    root.curWpDir    = "" + j.wpDir;
            root.welcomed = !!j.welcomed;
        } catch (e) {
            root.welcomed = false;
        }
    }

    // First run. Delayed rather than immediate: the bar is still mapping its own windows at
    // this point, and an exclusive-keyboard overlay racing that has landed under the bar.
    //
    // AND IT MARKS ITSELF SEEN AS IT OPENS, not when you finish it. This is resident inside
    // the bar's config, so it is re-instantiated every time appearance.json changes — and
    // appearance.json changes whenever you touch a setting. Writing the flag on `finish`
    // meant the timer fired again on every one of those reloads, and the tour reopened over
    // whatever the user was doing, repeatedly, until they happened to press finish. Anything
    // they clicked through to dismiss it went into their config on the way past.
    //
    // Shown once ever is the whole contract; the flag belongs at the moment it is shown.
    Timer {
        interval: 1400; running: true; repeat: false
        onTriggered: { if (!root.welcomed) { updateCheck.command = updateCheck.command.concat(["--fresh"]); updateCheck.running = true; root.set("welcomed=true"); root.open() } else updateCheck.running = true }
    }

    Process {
        id: updateCheck
        command: ["python3", Qt.resolvedUrl("sea-whats-new.py").toString().replace("file://", "")]
        stdout: StdioCollector { onStreamFinished: if (text.trim() === "show") { root.whatsNew = true; root.shown = true } }
    }

    // ---------- the wallpaper shelf's data ----------
    property var papers: []
    Process {
        id: wpIndexProc
        command: ["python3", root.wpIndex]
        stdout: StdioCollector { id: wpOut; onStreamFinished: {
            var out = [], lines = wpOut.text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var f = lines[i].split("\t");
                // `< 8`, not `!== 8`. The indexer has grown a column twice now (collection, then
                // mtime, then the full-resolution still) and each time an exact-length check
                // somewhere silently dropped every row — a folder of wallpapers reporting
                // itself empty. Extra columns are none of this parser's business.
                if (f.length < 8 || !f[0]) continue;
                out.push({ path: f[0], name: f[0].slice(f[0].lastIndexOf("/") + 1),
                           poster: f[4], vid: f[4].length > 0 });
            }
            root.papers = out;
        } }
    }
    function still(w) { return !w ? "" : (w.vid ? w.poster : w.path) }
    onShownChanged: if (shown) {
        if (!root.papers.length) wpIndexProc.running = true;
        gmCheck.running = true;
    }

    // ---------- default applications (step 5) ----------
    // Asked here because it is the one setting a fresh machine most often has
    // WRONG rather than merely unset: a distro ships one browser and one file
    // manager as the answer to everything, and you find out the first time a link
    // opens somewhere you did not want it. sea-defaults.py does the writing; see
    // the note at the top of it for why the terminal is not like the others.
    readonly property string defScript: Qt.resolvedUrl("sea-defaults.py").toString().replace("file://","")
    property var defRoles: []
    property var defCands: ({})
    property string defBusy: ""
    // Only the three the shell itself leans on. The other five are on the
    // Settings page; a first run is not the place to work through eight of them.
    readonly property var defAsk: ["terminal", "browser", "filemanager"]
    function defRefresh() { defProc.command = ["python3", root.defScript, "--all"]; defProc.running = false; defProc.running = true }
    function defSet(role, id) {
        root.defBusy = role;
        defSetProc.command = ["python3", root.defScript, "--set", role, id];
        defSetProc.running = false; defSetProc.running = true;
    }
    function defRoleOf(name) {
        for (var i = 0; i < root.defRoles.length; i++)
            if (root.defRoles[i].role === name) return root.defRoles[i];
        return null;
    }
    Process {
        id: defProc
        stdout: StdioCollector { id: defOut; onStreamFinished: {
            try {
                var d = JSON.parse(defOut.text);
                root.defRoles = d.roles || []; root.defCands = d.candidates || ({});
            } catch (e) {}
        } }
    }
    Process {
        id: defSetProc
        stdout: StdioCollector { id: defSetOut; onStreamFinished: { root.defBusy = ""; root.defRefresh() } }
    }

    // ---------- the menu bar (step 5) ----------
    // The tour asks about this one because it is the only feature that needs something done to
    // the APPS rather than to the shell: firefox wants two prefs, and every electron app wants a
    // flag that runs it under xwayland, before either will hand its menu over. Left to be
    // discovered, that reads as "the menu bar doesn't work with my editor" rather than "my editor
    // has not been told to share". One button here is the whole difference.
    property bool gmEnabled: true
    property bool gmPrime: false
    property bool gmAccel: true
    readonly property string gmScript: Qt.resolvedUrl("sea-appmenu.py").toString().replace("file://", "")
    FileView {
        id: gmCfg
        path: Quickshell.env("HOME") + "/.config/sea-shell/appmenu.json"
        watchChanges: true
        function apply(refresh) {
            try {
                if (refresh !== false) reload();
                var t = text();
                if (!t || !t.trim()) return;
                var j = JSON.parse(t);
                if (j.enabled !== undefined) root.gmEnabled = !!j.enabled;
                if (j.prime !== undefined) root.gmPrime = !!j.prime;
                if (j.accelerators !== undefined) root.gmAccel = !!j.accelerators;
            } catch (e) {}
        }
        onFileChanged: apply()
        onLoaded: apply(false)
        Component.onCompleted: apply()
    }
    // Round-trips the two keys it does not offer instead of writing only its own: settings.qml
    // owns this file as well, and a second surface rebuilding it from its own properties would
    // quietly reset every key it had not heard of. Same reason the appearance writes all go
    // through the python setter rather than being composed here.
    function gmSet(on) {
        var b64 = Qt.btoa(JSON.stringify({ enabled: !!on, prime: root.gmPrime,
                                           accelerators: root.gmAccel }));
        Quickshell.execDetached(["sh", "-c",
            "d=\"$HOME/.config/sea-shell\"; mkdir -p \"$d\"; echo '" + b64
            + "' | base64 -d > \"$d/.appmenu.tmp\" && mv -f \"$d/.appmenu.tmp\" \"$d/appmenu.json\""]);
    }

    // --setup only ever REPORTS; nothing on disk changes until --apply. The sidecar is asked
    // rather than this file knowing what each toolkit needs, because it is the thing that knows.
    property var gmApps: []
    property bool gmSetupBusy: false
    property bool gmSetupDone: false
    readonly property int gmNeeds: {
        var n = 0;
        for (var i = 0; i < root.gmApps.length; i++) if (!root.gmApps[i].ok) n++;
        return n;
    }
    Process {
        id: gmCheck
        command: ["python3", root.gmScript, "--setup"]
        stdout: StdioCollector { id: gmCheckOut; onStreamFinished: {
            try { root.gmApps = (JSON.parse(gmCheckOut.text || "{}").apps) || [] }
            catch (e) { root.gmApps = [] }
        } }
    }
    Process {
        id: gmApply
        command: ["python3", root.gmScript, "--setup", "--apply"]
        onExited: { root.gmSetupBusy = false; root.gmSetupDone = true; gmCheck.running = true }
    }

    // ================================================================= the card
    PanelWindow {
        id: win
        visible: root.shown
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.whatsNew ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        // Clicking outside the card leaves. Without this the only ways out were the finish
        // button and Escape, which is a modal you can be stuck in if it opens over your work.
        Rectangle {
            anchors.fill: parent; color: Qt.rgba(0, 0, 0, Tok.light ? 0.30 : 0.50)
            MouseArea { anchors.fill: parent; onClicked: root.finish() }
        }
        Item {
            anchors.fill: parent
            focus: root.shown
            Keys.onPressed: (e) => {
                if (root.whatsNew && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { root.finish(); e.accepted = true }
                else if (e.key === Qt.Key_Escape) { root.finish(); e.accepted = true }
                else if (e.key === Qt.Key_Right && root.step < root.steps - 1) { root.step++; e.accepted = true }
                else if (e.key === Qt.Key_Left && root.step > 0) { root.step--; e.accepted = true }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    if (root.step < root.steps - 1) root.step++; else root.finish();
                    e.accepted = true;
                }
            }
        }

        WhatsNewCard {
            visible: root.whatsNew
            anchors.centerIn: parent
            width: Math.min(620, parent.width - 40)
            surface: Tok.surface; raised: Tok.raised; ink: Tok.ink; secondary: Tok.ink2
            accent: Tok.accent; wash: Tok.accentWash; rule: Tok.ruleHard
            sans: Tok.sans; mono: Tok.mono; rounding: Tok.rCard; controlRadius: Tok.r
            onFinished: root.finish()
        }
        Rectangle {
            anchors.centerIn: parent
            visible: !root.whatsNew
            width: 760; height: 600
            radius: Tok.rCard + 6
            color: Tok.bg
            border.width: 1; border.color: root.groupRule
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 30; spacing: 18

                // ---- header: the mark, the name, and where you are ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    BarLogo {
                        size: 34; kind: "sea"
                        card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent
                    }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        IndText { text: root.stepNames[root.step]; sz: Tok.tTitle; font.weight: Font.Bold; color: Tok.ink }
                        IndText { text: "sea-shell setup · step " + (root.step + 1) + " of " + root.steps
                                  sz: Tok.tDense; color: Tok.ink3 }
                    }
                }

                // ---- the step ----
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true

                    // 0 — hello
                    ColumnLayout {
                        anchors.fill: parent; spacing: 14
                        visible: root.step === 0
                        Item { Layout.fillHeight: true }
                        BarLogo {
                            Layout.alignment: Qt.AlignHCenter
                            size: 92; kind: root.autoLogo
                            card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent
                        }
                        IndText {
                            Layout.alignment: Qt.AlignHCenter
                            text: "A desktop for Hyprland"; sz: 24; font.weight: Font.Bold; color: Tok.ink
                        }
                        IndText {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            Layout.leftMargin: 60; Layout.rightMargin: 60
                            sz: Tok.tBody; color: Tok.ink2; lineHeight: 1.2
                            // Derived, not written out: the header beside it counts "01 / 5", and a
                            // hardcoded "Four screens" beside that reads as one of them being wrong.
                            text: (root.steps - 1) + " short screens, about a minute. Everything you pick applies "
                                + "straight away — you can watch the bar change behind this — and everything "
                                + "here is in the control center afterwards if you change your mind."
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 1 — look
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 1
                        WSection { title: "Appearance" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "Dark";  on: root.curMode === "dark"
                                    onPicked: root.set("mode=dark") }
                            WChip { label: "Light"; on: root.curMode === "light"
                                    onPicked: root.set("mode=light") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "Accent colour" }
                        IndText {
                            sz: Tok.tDense; color: Tok.ink2; Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: "Match colours pulls a palette out of your wallpaper and re-themes the shell, "
                                + "kitty, starship and the window borders every time it changes."
                        }
                        WToggle {
                            label: "Match colours from the wallpaper"
                            on: root.curMatugen
                            onToggled: {
                                root.set("matugen=" + (root.curMatugen ? "false" : "true"));
                                if (!root.curMatugen) Quickshell.execDetached(["sh", root.matugen]);
                            }
                        }
                        Flow {
                            Layout.fillWidth: true; Layout.leftMargin: 5; Layout.topMargin: 4; spacing: 16
                            visible: !root.curMatugen
                            Repeater {
                                model: ["#63c7dd", "#8fb9ff", "#a6da95", "#eed49f", "#f5a97f", "#f0a0c0", "#c6a0f6"]
                                Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.curAccent.toLowerCase() === modelData.toLowerCase()
                                    width: 34; height: 34; radius: 17
                                    color: modelData
                                    border.width: 1; border.color: Tok.alpha("#000", 0.12)
                                    // the chosen one wears a ring with a gap, as macOS draws it
                                    Rectangle { anchors.centerIn: parent; width: 44; height: 44; radius: 22
                                        color: "transparent"; border.width: 2; border.color: parent.modelData
                                        visible: parent.sel }
                                    Text { anchors.centerIn: parent; visible: parent.sel; text: "check"
                                        font.family: "Material Symbols Outlined"; font.pixelSize: 18; color: "#1b1b1b" }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.set("accent=" + modelData);
                                            Quickshell.execDetached(["sh", root.matugen]);
                                        }
                                    }
                                }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 2 — wallpaper
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 2
                        WSection { title: "Wallpaper" }
                        IndText {
                            sz: Tok.tDense; color: Tok.ink2; Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: root.papers.length
                                  ? (root.papers.length + " in " + root.curWpDir
                                     + ". Super Shift W opens the picker, Super N cycles.")
                                  : ("Nothing in " + root.curWpDir
                                     + ". Point it somewhere else in Settings → Bar → Wallpaper.")
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 4; rowSpacing: 8; columnSpacing: 8
                            Repeater {
                                model: Math.min(8, root.papers.length)
                                Rectangle {
                                    required property int index
                                    readonly property var w: root.papers[index]
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 96
                                    radius: 12
                                    clip: true
                                    color: root.groupFill
                                    border.width: wma.containsMouse ? 2 : 0
                                    border.color: Tok.accent
                                    scale: wma.pressed ? 0.97 : 1
                                    Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
                                    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                                    Image {
                                        anchors.fill: parent; anchors.margins: parent.border.width
                                        source: Tok.fileUrl(root.still(parent.w))
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true; cache: true
                                        sourceSize.height: 170
                                    }
                                    MouseArea {
                                        id: wma
                                        anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Quickshell.execDetached(["sh", root.wpSet, parent.w.path, "--quiet"])
                                    }
                                }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 3 — the bar
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        visible: root.step === 3
                        WSection { title: "Bar shape" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "One bar"; on: root.curBarShape === "bar"
                                    onPicked: root.set("barShape=bar") }
                            WChip { label: "Pills";   on: root.curBarShape === "pills"
                                    onPicked: root.set("barShape=pills") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "Workspaces" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "Grow";    on: root.curWsStyle === "grow"
                                    onPicked: root.set("wsStyle=grow") }
                            WChip { label: "Pills";   on: root.curWsStyle === "pill"
                                    onPicked: root.set("wsStyle=pill") }
                            WChip { label: "Circles"; on: root.curWsStyle === "circle"
                                    onPicked: root.set("wsStyle=circle") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "Numbering" }
                        Flow {
                            Layout.fillWidth: true; spacing: 7
                            Repeater {
                                model: [{ k: "arabic", l: "1 2 3" }, { k: "roman", l: "I II III" },
                                        { k: "mandarin", l: "一 二 三" }, { k: "letters", l: "A B C" },
                                        { k: "circled", l: "① ② ③" }, { k: "dots", l: "● ● ●" }]
                                WChip {
                                    required property var modelData
                                    label: modelData.l
                                    on: root.curWsLabel === modelData.k
                                    onPicked: root.set("wsLabel=" + modelData.k)
                                }
                            }
                        }

                        WSection { title: "Logo" }
                        Flow {
                            Layout.fillWidth: true; spacing: 7
                            Repeater {
                                model: ["auto", "sea", "cachy", "arch", "debian", "fedora", "nixos", "ubuntu"]
                                Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.curBarLogo === modelData
                                    width: 46; height: 38; radius: 12
                                    color: sel ? Tok.accentWash : root.groupFill
                                    border.width: sel ? 2 : 0; border.color: Tok.accent
                                    BarLogo {
                                        anchors.centerIn: parent
                                        kind: modelData === "auto" ? root.autoLogo : modelData
                                        size: 19
                                        card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent
                                    }
                                    // "auto" shows what it would actually give you, with a dot
                                    // to say it is the automatic one rather than that distro
                                    // pinned by name.
                                    Rectangle {
                                        visible: modelData === "auto"
                                        anchors { right: parent.right; top: parent.top; margins: 3 }
                                        width: 5; height: 5; radius: 2.5
                                        color: sel ? Tok.accent : Tok.ink3
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.set("barLogo=" + modelData)
                                    }
                                }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 4 — menus
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 4
                        WSection { title: "Menu bar" }
                        IndText {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ink2
                            text: "The bar can carry the focused window's own menus — file, edit, view — "
                                + "instead of every window drawing its own. The workspace numbers step "
                                + "aside while there is a menu to show and come straight back when there "
                                + "isn't. Super M opens it from the keyboard; Super Shift M searches every "
                                + "command in it."
                        }
                        WToggle {
                            label: "Show the focused window's menus"
                            on: root.gmEnabled
                            onToggled: root.gmSet(!root.gmEnabled)
                        }

                        WSection { title: "Apps"; visible: root.gmEnabled }
                        IndText {
                            visible: root.gmEnabled
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ink2
                            text: root.gmApps.length === 0
                                  ? "Looking at what is installed…"
                                  : (root.gmNeeds === 0
                                     ? "Every app found here can already publish its menu. Qt and GTK apps need nothing at all."
                                     : root.gmNeeds + " of " + root.gmApps.length + " apps need one small change first — "
                                       + "Firefox two prefs, Electron apps a flag that runs them under XWayland so they can "
                                       + "hand the menu over as data. Nothing else about them changes, and each one has to be "
                                       + "restarted afterwards.")
                        }
                        RowLayout {
                            visible: root.gmEnabled && root.gmNeeds > 0
                            spacing: 10
                            WBtn {
                                primary: true
                                enabled: !root.gmSetupBusy
                                opacity: root.gmSetupBusy ? 0.6 : 1
                                label: root.gmSetupBusy
                                       ? "Setting up…"
                                       : "Set up " + root.gmNeeds + " app" + (root.gmNeeds === 1 ? "" : "s")
                                onTapped: { root.gmSetupBusy = true; gmApply.running = true }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        IndText {
                            visible: root.gmEnabled && root.gmSetupDone && root.gmNeeds === 0
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ok
                            text: "Done. Restart those apps and their menus turn up in the bar."
                        }
                        IndText {
                            visible: root.gmEnabled
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ink2
                            text: "App by app, and why each one is or is not ready, lives in Settings → Bar."
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 5 — default applications
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 5
                        WSection { title: "Which app opens what" }
                        IndText {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ink2
                            text: "These are the machine's own associations — every application that asks "
                                + "the system will follow them, not just this shell. The terminal is the "
                                + "one exception: no standard covers it, so sea-shell keeps that answer "
                                + "itself and uses it for “open in terminal”."
                        }

                        Repeater {
                            model: root.defAsk
                            delegate: ColumnLayout {
                                id: wRole
                                required property string modelData
                                readonly property var info: root.defRoleOf(modelData)
                                readonly property var choices: root.defCands[modelData] || []
                                visible: !!info && choices.length > 0
                                Layout.fillWidth: true
                                spacing: 4

                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    IndText {
                                        sz: Tok.tDense; font.weight: Font.Medium; color: Tok.ink
                                        text: wRole.info ? wRole.info.label : ""
                                    }
                                    Item { Layout.fillWidth: true }
                                    IndText {
                                        sz: Tok.tDense; color: Tok.ink2
                                        text: root.defBusy === wRole.modelData ? "Setting…" : ""
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: wRole.choices
                                        delegate: Rectangle {
                                            id: wChip
                                            required property var modelData
                                            readonly property bool chosen: !!wRole.info
                                                && modelData.id === wRole.info.current
                                            implicitHeight: 30
                                            implicitWidth: wChipRow.implicitWidth + 22
                                            radius: 15
                                            color: wChip.chosen ? Tok.accent
                                                 : (wChipMa.containsMouse ? root.rowHover : root.groupFill)
                                            Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                            RowLayout {
                                                id: wChipRow
                                                anchors.centerIn: parent; spacing: 6
                                                IconImage {
                                                    visible: wChip.modelData.icon.length > 0 && status === Image.Ready
                                                    implicitSize: 15
                                                    source: wChip.modelData.icon.length > 0
                                                            ? Quickshell.iconPath(wChip.modelData.icon, true) : ""
                                                }
                                                IndText {
                                                    sz: Tok.tDense
                                                    color: wChip.chosen ? Tok.accentInk : Tok.ink
                                                    text: wChip.modelData.name
                                                }
                                            }
                                            MouseArea {
                                                id: wChipMa
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.defSet(wRole.modelData, wChip.modelData.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        IndText {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            sz: Tok.tDense; color: Tok.ink2
                            text: "The rest (images, video, music, documents) are on the same page in "
                                + "Settings → Default Apps, whenever you want them."
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 6 — done
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 6
                        Item { Layout.fillHeight: true }
                        IndText {
                            Layout.alignment: Qt.AlignHCenter
                            text: "You're all set"; sz: 24; font.weight: Font.Bold; color: Tok.ink
                        }
                        WHint { k: "Super K";       v: "Every shortcut, with a description" }
                        WHint { k: "Super M";       v: "The focused window's menus, from the keyboard" }
                        WHint { k: "Super S";       v: "Settings: everything here, and the rest" }
                        WHint { k: "Super Shift W"; v: "The wallpaper picker" }
                        WHint { k: "Hub Moon";      v: "Parametric EQ and DAC control, if you want them" }
                        IndText {
                            Layout.fillWidth: true; Layout.topMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            sz: Tok.tDense; color: Tok.ink2
                            wrapMode: Text.WordWrap
                            text: "You can open this again from Settings → System."
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                // ---- footer ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    WBtn {
                        label: "Back"; visible: root.step > 0
                        onTapped: root.step--
                    }
                    Item { Layout.fillWidth: true }
                    // Step dots — the same "which of how many" as the counter, at a glance.
                    Row {
                        spacing: 6
                        Repeater {
                            model: root.steps
                            Rectangle {
                                required property int index
                                width: index === root.step ? 18 : 7; height: 7; radius: 3.5
                                color: index === root.step ? Tok.accent : Tok.alpha(Tok.ink3, 0.35)
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Behavior on width { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    WBtn {
                        label: root.step === 0 ? "Get started" : root.step < root.steps - 1 ? "Continue" : "Done"
                        primary: true
                        onTapped: { if (root.step < root.steps - 1) root.step++; else root.finish() }
                    }
                }
            }
        }
    }

    // ---------- local controls ----------
    // Deliberately not settings.qml's: those are inline components of that file and cannot be
    // reached from here. Drawn in the same language: quiet fills, no outlines, pills.
    component WSection: IndText {
        property string title: ""
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: title; sz: Tok.tDense; font.weight: Font.DemiBold; color: Tok.ink
    }

    component WChip: Rectangle {
        id: ch
        property string label: ""
        property bool on: false
        signal picked()
        implicitWidth: chT.implicitWidth + 30; implicitHeight: 32; radius: 16
        color: ch.on ? Tok.accent : (chM.containsMouse ? root.rowHover : root.groupFill)
        scale: chM.pressed ? 0.96 : 1
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
        IndText { id: chT; anchors.centerIn: parent; text: ch.label; sz: Tok.tDense
                  color: ch.on ? Tok.accentInk : Tok.ink; font.weight: ch.on ? Font.DemiBold : Font.Normal }
        MouseArea { id: chM; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: ch.picked() }
    }

    component WToggle: Rectangle {
        id: tg
        property string label: ""
        property bool on: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: 46; radius: 12
        color: tgM.containsMouse ? root.rowHover : root.groupFill
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: tg.label; sz: Tok.tBody; color: Tok.ink
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            width: 40; height: 24; radius: 12
            color: tg.on ? Tok.accent : Tok.alpha(Tok.ink, 0.16)
            Behavior on color { ColorAnimation { duration: Tok.mFast } }
            Rectangle {
                width: 20; height: 20; radius: 10; y: 2
                x: tg.on ? parent.width - width - 2 : 2
                color: "white"
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
        }
        MouseArea { id: tgM; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: tg.toggled() }
    }

    component WBtn: Rectangle {
        id: bt
        property string label: ""
        property bool primary: false
        signal tapped()
        implicitWidth: Math.max(96, btT.implicitWidth + 36); implicitHeight: 36; radius: 18
        color: bt.primary ? (btM.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent)
                          : (btM.containsMouse ? root.rowHover : root.groupFill)
        scale: btM.pressed ? 0.97 : 1
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
        IndText {
            id: btT; anchors.centerIn: parent; text: bt.label; sz: Tok.tDense
            font.weight: bt.primary ? Font.DemiBold : Font.Medium
            color: bt.primary ? Tok.accentInk : Tok.ink
        }
        MouseArea { id: btM; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: bt.tapped() }
    }

    component WHint: RowLayout {
        property string k: ""
        property string v: ""
        Layout.fillWidth: true
        Layout.leftMargin: 110; Layout.rightMargin: 60
        spacing: 14
        Item {
            Layout.preferredWidth: 130; implicitHeight: 28
            Rectangle {
                anchors.right: parent.right
                width: hk.implicitWidth + 18; height: 28; radius: 8
                color: root.groupFill
                IndText { id: hk; anchors.centerIn: parent; text: parent.parent.parent.k; sz: Tok.tDense
                          color: Tok.ink; font.weight: Font.Medium }
            }
        }
        IndText { Layout.fillWidth: true; text: parent.v; sz: Tok.tBody; color: Tok.ink2 }
    }
}
