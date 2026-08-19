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
import QtQuick
import QtQuick.Layouts

Scope {
    id: root

    property bool shown: false
    property int step: 0
    readonly property int steps: 5

    readonly property string setScript:  Qt.resolvedUrl("sea-set-appearance.py").toString().replace("file://", "")
    readonly property string wpSet:      Qt.resolvedUrl("sea-wallpaper-set.sh").toString().replace("file://", "")
    readonly property string wpIndex:    Qt.resolvedUrl("sea-wallpaper-index.py").toString().replace("file://", "")
    readonly property string matugen:    Qt.resolvedUrl("matugen-accent.sh").toString().replace("file://", "")

    function open()   { root.step = 0; root.shown = true }
    function close()  { root.shown = false }
    // The flag is written when the tour is first SHOWN (see the timer below), so finishing is
    // only closing. Kept as its own function because the footer button says "finish" and
    // should not read as "cancel".
    function finish() { root.set("welcomed=true"); root.shown = false }

    IpcHandler {
        target: "welcome"
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.shown ? root.close() : root.open() }
    }

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
        onTriggered: if (!root.welcomed) { root.set("welcomed=true"); root.open() }
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
    onShownChanged: if (shown && !root.papers.length) wpIndexProc.running = true

    // ================================================================= the card
    PanelWindow {
        id: win
        visible: root.shown
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        // Clicking outside the card leaves. Without this the only ways out were the finish
        // button and Escape, which is a modal you can be stuck in if it opens over your work.
        Rectangle {
            anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: root.finish() }
        }
        Item {
            anchors.fill: parent
            focus: root.shown
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) { root.finish(); e.accepted = true }
                else if (e.key === Qt.Key_Right && root.step < root.steps - 1) { root.step++; e.accepted = true }
                else if (e.key === Qt.Key_Left && root.step > 0) { root.step--; e.accepted = true }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    if (root.step < root.steps - 1) root.step++; else root.finish();
                    e.accepted = true;
                }
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: 760; height: 580
            radius: Tok.rCard
            color: Tok.bg
            border.width: 1; border.color: Tok.ruleHard
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 26; spacing: 16

                // ---- header: the mark, the name, and which step ----
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    BarLogo {
                        size: 30; kind: "sea"
                        card: Tok.surface; accent: Tok.accent; highlight: Tok.ink; rim: Tok.accent
                    }
                    ColumnLayout {
                        spacing: 0; Layout.fillWidth: true
                        IndText { text: "sea-shell"; mono: true; sz: Tok.tTitle; font.weight: 700; color: Tok.ink }
                        IndText { text: "first-run setup"; mono: true; sz: Tok.tLabel; color: Tok.ink3
                                  font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase }
                    }
                    // The counter, in the deck's language: which of how many.
                    Row {
                        spacing: 3
                        IndText { anchors.baseline: ofN.baseline; mono: true; sz: Tok.tKpi
                                  font.weight: 700; color: Tok.accent; text: "0" + (root.step + 1) }
                        IndText { id: ofN; mono: true; sz: Tok.tDense; color: Tok.ink3; text: "/ " + root.steps }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }

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
                            text: "a desktop for Hyprland"; mono: true; sz: Tok.tPanel; color: Tok.ink
                        }
                        IndText {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            mono: true; sz: Tok.tDense; color: Tok.ink3
                            // Derived, not written out: the header beside it counts "01 / 5", and a
                            // hardcoded "Four screens" beside that reads as one of them being wrong.
                            text: (root.steps - 1) + " more screens, about a minute. Everything you pick applies "
                                + "straight away — you can watch the bar change behind this — and everything "
                                + "here is in the control center afterwards if you change your mind."
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // 1 — look
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 1
                        WSection { title: "light or dark" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "dark";  on: root.curMode === "dark"
                                    onPicked: root.set("mode=dark") }
                            WChip { label: "light"; on: root.curMode === "light"
                                    onPicked: root.set("mode=light") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "accent" }
                        IndText {
                            mono: true; sz: Tok.tLabel; color: Tok.ink3; Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: "match colours pulls a palette out of your wallpaper and re-themes the shell, "
                                + "kitty, starship and the window borders every time it changes."
                        }
                        WToggle {
                            label: "match colours from the wallpaper"
                            on: root.curMatugen
                            onToggled: {
                                root.set("matugen=" + (root.curMatugen ? "false" : "true"));
                                if (!root.curMatugen) Quickshell.execDetached(["sh", root.matugen]);
                            }
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: 8
                            visible: !root.curMatugen
                            Repeater {
                                model: ["#63c7dd", "#8fb9ff", "#a6da95", "#eed49f", "#f5a97f", "#f0a0c0", "#c6a0f6"]
                                Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.curAccent.toLowerCase() === modelData.toLowerCase()
                                    width: 34; height: 34; radius: Tok.r
                                    color: modelData
                                    border.width: sel ? 3 : 1
                                    border.color: sel ? Tok.ink : Tok.alpha(Tok.ink, 0.2)
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
                        WSection { title: "wallpaper" }
                        IndText {
                            mono: true; sz: Tok.tLabel; color: Tok.ink3; Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: root.papers.length
                                  ? (root.papers.length + " in " + root.curWpDir
                                     + "  ·  SUPER+SHIFT+W opens the picker, SUPER+N cycles")
                                  : ("nothing in " + root.curWpDir
                                     + "  ·  point it somewhere else in Settings → Bar → wallpaper")
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
                                    Layout.preferredHeight: 88
                                    radius: Tok.rSmall
                                    clip: true
                                    color: Tok.sunken
                                    border.width: 1
                                    border.color: wma.containsMouse ? Tok.accent : Tok.ruleHard
                                    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                                    Image {
                                        anchors.fill: parent; anchors.margins: 1
                                        source: root.still(parent.w).length ? "file://" + root.still(parent.w) : ""
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
                        WSection { title: "bar shape" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "one bar"; on: root.curBarShape === "bar"
                                    onPicked: root.set("barShape=bar") }
                            WChip { label: "pills";   on: root.curBarShape === "pills"
                                    onPicked: root.set("barShape=pills") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "workspaces" }
                        RowLayout {
                            spacing: 8
                            WChip { label: "grow";    on: root.curWsStyle === "grow"
                                    onPicked: root.set("wsStyle=grow") }
                            WChip { label: "pills";   on: root.curWsStyle === "pill"
                                    onPicked: root.set("wsStyle=pill") }
                            WChip { label: "circles"; on: root.curWsStyle === "circle"
                                    onPicked: root.set("wsStyle=circle") }
                            Item { Layout.fillWidth: true }
                        }

                        WSection { title: "numbering" }
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

                        WSection { title: "the mark" }
                        Flow {
                            Layout.fillWidth: true; spacing: 7
                            Repeater {
                                model: ["auto", "sea", "cachy", "arch", "debian", "fedora", "nixos", "ubuntu"]
                                Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.curBarLogo === modelData
                                    width: 42; height: 34; radius: Tok.r
                                    color: sel ? Tok.accentWash : Tok.surface
                                    border.width: 1; border.color: sel ? Tok.accent : Tok.ruleHard
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

                    // 4 — done
                    ColumnLayout {
                        anchors.fill: parent; spacing: 12
                        visible: root.step === 4
                        Item { Layout.fillHeight: true }
                        IndText {
                            Layout.alignment: Qt.AlignHCenter
                            text: "that's it"; mono: true; sz: Tok.tTitle; font.weight: 700; color: Tok.ink
                        }
                        WHint { k: "SUPER+K";       v: "every keybind, with a description" }
                        WHint { k: "SUPER+S";       v: "the control center — everything here, and the rest" }
                        WHint { k: "SUPER+SHIFT+W"; v: "the wallpaper picker" }
                        WHint { k: "Hub Moon";      v: "parametric EQ and DAC control, if you want them" }
                        IndText {
                            Layout.fillWidth: true; Layout.topMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            mono: true; sz: Tok.tLabel; color: Tok.ink3
                            wrapMode: Text.WordWrap
                            text: "you can open this again from Settings → System"
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                // ---- footer ----
                Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    WBtn {
                        label: "back"; visible: root.step > 0
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
                                width: 7; height: 7; radius: 3.5
                                color: index === root.step ? Tok.accent : Tok.alpha(Tok.ink3, 0.4)
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    WBtn {
                        label: root.step < root.steps - 1 ? "next" : "finish"
                        primary: true
                        onTapped: { if (root.step < root.steps - 1) root.step++; else root.finish() }
                    }
                }
            }
        }
    }

    // ---------- local controls ----------
    // Deliberately not settings.qml's: those are inline components of that file and cannot be
    // reached from here. Four small ones is less than making a component library for two users.
    component WSection: ColumnLayout {
        property string title: ""
        Layout.fillWidth: true
        spacing: 3
        IndText {
            text: parent.title; mono: true; sz: Tok.tLabel; color: Tok.ink2
            font.weight: 600; font.letterSpacing: 1.15; font.capitalization: Font.AllUppercase
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Tok.rule }
    }

    component WChip: Rectangle {
        id: ch
        property string label: ""
        property bool on: false
        signal picked()
        implicitWidth: chT.implicitWidth + 24; implicitHeight: 32; radius: Tok.r
        color: ch.on ? Tok.accentWash : (chM.containsMouse ? Tok.raised : Tok.surface)
        border.width: 1; border.color: ch.on ? Tok.accent : Tok.ruleHard
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText { id: chT; anchors.centerIn: parent; text: ch.label; mono: true; sz: Tok.tData
                  color: ch.on ? Tok.ink : Tok.ink2; font.weight: ch.on ? 700 : 400 }
        MouseArea { id: chM; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: ch.picked() }
    }

    component WToggle: Rectangle {
        id: tg
        property string label: ""
        property bool on: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: 44; radius: Tok.r
        color: tgM.containsMouse ? Tok.raised : Tok.surface
        border.width: 1; border.color: tg.on ? Tok.accent : Tok.ruleHard
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText {
            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
            text: tg.label; mono: true; sz: Tok.tDense; color: Tok.ink
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            width: 42; height: 22; radius: Tok.r
            color: tg.on ? Tok.accent : Tok.sunken
            border.width: 1; border.color: tg.on ? Tok.accent : Tok.ruleHard
            Behavior on color { ColorAnimation { duration: Tok.mFast } }
            Rectangle {
                width: 16; height: 16; radius: Tok.rSmall; y: 3
                x: tg.on ? parent.width - width - 3 : 3
                color: tg.on ? Tok.accentInk : Tok.ink3
                Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
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
        implicitWidth: btT.implicitWidth + 34; implicitHeight: 36; radius: Tok.r
        color: bt.primary ? (btM.containsMouse ? Tok.accent : Tok.accentWash)
                          : (btM.containsMouse ? Tok.raised : Tok.surface)
        border.width: 1; border.color: bt.primary ? Tok.accent : Tok.ruleHard
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText {
            id: btT; anchors.centerIn: parent; text: bt.label; mono: true; sz: Tok.tData
            font.weight: bt.primary ? 700 : 400
            color: (bt.primary && btM.containsMouse) ? Tok.accentInk : Tok.ink
        }
        MouseArea { id: btM; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: bt.tapped() }
    }

    component WHint: RowLayout {
        property string k: ""
        property string v: ""
        Layout.fillWidth: true
        spacing: 12
        Rectangle {
            Layout.preferredWidth: 150; implicitHeight: 26; radius: Tok.rSmall
            color: Tok.surface; border.width: 1; border.color: Tok.ruleHard
            IndText { anchors.centerIn: parent; text: parent.parent.k; mono: true; sz: Tok.tData
                      color: Tok.accent; font.weight: 600 }
        }
        IndText { Layout.fillWidth: true; text: parent.v; mono: true; sz: Tok.tDense; color: Tok.ink2 }
    }
}
