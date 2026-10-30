// sea-shell — one thing on the desktop.
//
// A widget or a shortcut; the difference is what it draws and what a click does, not how it
// is placed. Position arrives as fractions of the usable field and is handed back the same
// way, so this never learns what a monitor is.
//
// THE DESIGN IS THE SHELL'S OWN, NOT A CARD. Every desktop-widget convention — a rounded
// translucent tile with a shadow under it — is the thing this shell's components already
// refuse in as many words: IndRule says "depth in this language comes from rules and
// background steps, never shadow, never translucency", and IndLabel exists so a screen
// reads as "a stack of labelled regions instead of a scatter of floating cards". A desktop
// full of glass tiles would be a different product wearing this one's accent colour.
//
// So a widget here is an INSTRUMENT READ-OUT: a tracked uppercase mono label, a hairline
// under it, the figure below. The hairline is the only chrome, and it is what keeps the
// text from reading as litter dropped on a photograph. Figures are tabular — a clock whose
// minute shifts sideways every time it ticks is the amateur tell IndText warns about.
//
// AND IT KNOWS WHAT IS BEHIND IT. `busy` is how much the wallpaper has going on under this
// item, from the same map that decides where things are placed. On calm ground the widget
// is bare text on a picture, which is the entire point of putting it on a wallpaper you
// chose. Only where the ground is genuinely busy does a backdrop fade in — a background
// STEP rather than a glow, because that is the house device for depth. This is the part no
// other desktop does, and it is only possible because the shell measured the wallpaper
// first: the same threshold that says "move this widget" says "this one needs a ground".
//
// IT IS ONLY DRAGGABLE WHILE ARRANGING. A desktop where a stray click can move your clock
// is a desktop you cannot trust, and the whole point of putting things somewhere is that
// they stay there.
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

Item {
    id: item

    property var pal
    property string uiFont: "sans"
    property var spec: ({})
    property bool editing: false
    // NOT called `data`: that is Item's default property — the list of an item's children —
    // and shadowing it with a plain var quietly breaks every child this component declares.
    property var readings: ({})
    property var player: null
    // 0 = the wallpaper is empty here, 1 = there is something under this widget.
    property real busy: 0
    // how light the wallpaper is under this item, 0..1 (Desktop.lumaAt); 0.5 when unknown
    property real under: 0.5
    property var history: []
    property var memHistory: []
    property var gpuHistory: []
    property var viz: []
    property real fieldW: 1920
    property real fieldH: 1000
    property real fieldY: 0

    // how busy the wallpaper is under a rectangle (fractions), for the drag hint
    property var busyFn: null
    property real busyLimit: 0.3
    // fx, fy are fractions; `exact` means the user asked for no nudging (shift held).
    signal moved(real fx, real fy, bool exact)
    signal removed()

    readonly property string kind: (item.spec && item.spec.kind) ? item.spec.kind : "clock"
    readonly property color ink: item.pal ? item.pal.text : "#eeeeee"
    readonly property color ink2: item.pal ? item.pal.sub : "#bbbbbb"
    readonly property color hair: item.pal ? item.pal.a(item.pal.text, 0.30) : "#55ffffff"

    // ---------- how it is dressed ----------
    // The same three axes the Bar Widgets tab already uses — colour, ground, and how much
    // room it takes — because a shell where the desktop and the bar are configured in two
    // different vocabularies is two shells. `tone` is deliberately ONE accent used sparingly
    // rather than a palette per widget: the research and the house style agree that a
    // near-monochrome surface with a single accent is what reads as designed.
    readonly property string ground: (item.spec && item.spec.ground) ? item.spec.ground : "rule"
    readonly property string tone: (item.spec && item.spec.tone) ? item.spec.tone : "accent"
    readonly property string align: (item.spec && item.spec.align) ? item.spec.align : "left"
    // "card": the Material/macOS tile, solid. "glass": the same tile, half see-through. "clear":
    // the same content with no tile at all, a faint ground fading in only where the wallpaper is
    // busy. "classic": the original read-out below, a label, a hairline and the figure.
    readonly property string look: (item.spec && item.spec.look) ? item.spec.look : "card"
    readonly property bool clear: item.look === "classic" && item.kind !== "launch"
    readonly property real cardFill: item.look === "glass" ? 0.55
        : item.look === "clear" ? Math.max(0, Math.min(0.6, (item.busy - 0.18) * 2.2)) : 1
    readonly property color accent: {
        if (!item.pal) return "#63c7dd";
        switch (item.tone) {
        case "plain": return item.pal.a(item.pal.text, 0.55);
        case "green": return item.pal.good;
        case "amber": return item.pal.warn;
        case "red":   return item.pal.bad;
        case "frost": return item.pal.frost;
        }
        return item.pal.iris;
    }
    // The figure's colour states a FACT and is not a preference: a load that has gone
    // critical says so even if you asked for green. `tone` colours the accent furniture —
    // the mark on the rule, the trace — which is where taste belongs.
    readonly property string severity: {
        if (item.kind !== "system" || !item.readings || item.readings.cpu === undefined)
            return "neutral";
        if (item.readings.cpu >= 85) return "crit";
        if (item.readings.cpu >= 60) return "warn";
        return "neutral";
    }
    readonly property int hAlign: item.align === "centre" ? Text.AlignHCenter
                                : item.align === "right"  ? Text.AlignRight : Text.AlignLeft

    x: (item.spec ? item.spec.x : 0) * item.fieldW
    y: (item.spec ? item.spec.y : 0) * item.fieldH + item.fieldY
    width: Math.max(40, (item.spec ? item.spec.w : 0.1) * item.fieldW)
    height: Math.max(30, (item.spec ? item.spec.h : 0.08) * item.fieldH)

    // Nothing playing means nothing drawn. A widget reading "—" for most of the day is a
    // permanent hole in a picture you chose.
    visible: item.editing || !(item.kind === "media" && !item.player)

    // ---------- the ground ----------
    // "panel" always has one. "rule" and "bare" ask for one only where the wallpaper is
    // busy enough to need it — the adaptive behaviour is the point, so it stays the default.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -10
        radius: 22
        color: item.pal ? item.pal.bg : "#101010"
        visible: !item.editing && item.kind === "launch"
    }

    // The clear read-out's ground: always with "panel", and with "rule" only where the
    // wallpaper under it is busy enough to need one. A background step, never a glow.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -14
        radius: 20
        visible: item.clear && !item.editing
        color: item.pal ? item.pal.bg : "#101010"
        opacity: item.ground === "panel" ? 0.82
               : item.ground === "rule" ? Math.max(0, Math.min(0.75, (item.busy - 0.18) * 2.2)) : 0
        Behavior on opacity { NumberAnimation { duration: Tok.mSlow } }
    }

    // ---------- the arranging frame ----------
    Rectangle {
        anchors.fill: parent
        anchors.margins: -10
        radius: 22
        visible: item.editing
        // a light wash and an outline, not a slab: a solid frame turned every glass and clear
        // widget opaque the moment you started arranging, so you arranged something that did
        // not look like your desktop
        color: Qt.rgba(Tok.bg.r, Tok.bg.g, Tok.bg.b, dragArea.drag.active ? 0.45 : 0.22)
        border.width: dragArea.drag.active ? 2 : 1.5
        border.color: Qt.rgba(Tok.accent.r, Tok.accent.g, Tok.accent.b, dragArea.drag.active ? 0.95 : 0.5)
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
    }

    MaterialWidget {
        anchors.fill: parent; visible: item.kind !== "launch" && !item.clear; enabled: !item.editing
        face: (item.spec && item.spec.face) ? item.spec.face : "dial"
        fill: item.cardFill
        Behavior on fill { NumberAnimation { duration: Tok.mSlow } }
        kind: item.kind; readings: item.readings; player: item.player; viz: item.viz; active: item.visible
        // the size class the desktop chose (sea-desktop.py FOOTPRINTS), as macOS's three
        size: ({ small: "s", medium: "m", large: "l" })[(item.spec && item.spec.size) || (item.kind === "clock" ? "small" : "medium")] || ""
        uiFont: Tok.sans
        // The small clock IS its shape, so it stands bare unless "panel" asks for a card; the
        // others carry text, which needs a ground over a photo, unless "bare" is chosen.
        bare: item.ground === "bare"
              || (item.kind === "clock" && ((item.spec && item.spec.size) || "small") === "small" && item.ground !== "panel")
        surface: Tok.surface; container: Tok.accentWash; accent: Tok.accent
        // On its own tile the text follows the theme. With little or no tile (clear, bare) it
        // sits on the photo, so it follows the photo instead: dark on a light patch, light on
        // a dark one. The light-mode theme's dark ink was unreadable on a night wallpaper.
        readonly property bool onPhoto: bare || fill < 0.45
        readonly property bool lightPhoto: item.under > 0.58
        ink: onPhoto ? (lightPhoto ? "#14161c" : "#ffffff") : Tok.ink
        secondary: onPhoto ? (lightPhoto ? Qt.rgba(0.08, 0.09, 0.11, 0.72) : Qt.rgba(1, 1, 1, 0.78)) : Tok.ink2
        accentInk: Tok.accentInk; reducedMotion: Tok.reducedMotion
    }

    // ---------- the read-out ----------
    //
    // BUILT FROM THE SHELL'S OWN PARTS. The first version of this hand-rolled Text elements
    // that happened to look tidy, and it read as generic — because it was. IndKpi, IndLabel,
    // IndRule and IndSpark are what every other surface in sea-shell is made of, so using
    // them is not reuse for its own sake: it is the only way the desktop belongs to the same
    // instrument as the bar and the panels.
    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        visible: item.clear

        IndLabel {
            text: item.caption
            visible: text.length > 0 && item.ground !== "bare"
            Layout.fillWidth: true
            horizontalAlignment: item.hAlign
        }

        // The rule, and the one piece of colour in the widget. A hairline alone is a
        // divider; a hairline that begins with a short accent segment is a mark. On the
        // CLOCK that segment is the minute, filling as it passes — an instrument's rule
        // should be doing something.
        Item {
            Layout.fillWidth: true
            implicitHeight: 1
            visible: item.ground !== "bare"
            Rectangle { anchors.fill: parent; color: item.hair }
            Rectangle {
                height: 1
                width: item.kind === "clock"
                       ? Math.max(2, parent.width * clk.minuteFrac)
                       : Math.min(parent.width, Math.max(12, parent.width * 0.18))
                x: item.align === "right" ? parent.width - width
                 : item.align === "centre" ? (parent.width - width) / 2 : 0
                color: item.accent
                Behavior on width { NumberAnimation { duration: 420; easing.type: Tok.mEase } }
            }
        }

        // Short values get the house KPI: label, figure, unit, detail, already tabular and
        // already tone-aware.
        IndKpi {
            visible: item.kind === "system" || item.kind === "weather"
            Layout.fillWidth: true
            label: ""                                   // the rule above already carries it
            value: item.figure
            unit: item.unit
            sub: item.detail
            tone: item.severity
            size: Math.max(15, Math.round(item.height * item.figureScale))
        }

        // A load figure with no history is a number; with one it is an instrument — and
        // three traces on ONE axis say something a stack of separate charts cannot: whether
        // the machine is busy because of the processor, the memory or the card. They share
        // a 0-100 scale, so they are directly comparable, and the readings row below is the
        // legend: each label is tinted to match its trace, which costs no extra chrome.
        Item {
            visible: item.kind === "system" && item.history.length > 1
            Layout.fillWidth: true
            implicitHeight: Math.max(14, item.height * 0.22)
            IndSpark {
                anchors.fill: parent
                values: item.history
                stroke: item.accent
                ground: "transparent"
            }
            IndSpark {
                anchors.fill: parent
                visible: item.memHistory.length > 1
                values: item.memHistory
                stroke: Tok.ink3
                ground: "transparent"
            }
            IndSpark {
                anchors.fill: parent
                visible: item.gpuHistory.length > 1 && item.hasGpu
                values: item.gpuHistory
                stroke: Tok.warn
                ground: "transparent"
            }
        }

        // The rest of the machine. IndKpi's own note says to lay figures "on a row
        // separated by hairline verticals so one figure clearly leads" — which is exactly
        // this: CPU leads above, and memory, temperature and the GPU sit under it as
        // secondary readings rather than four equal tiles.
        RowLayout {
            visible: item.kind === "system"
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 0
            Repeater {
                model: item.stats
                delegate: RowLayout {
                    required property var modelData
                    required property int index
                    spacing: 0
                    Rectangle {
                        visible: index > 0
                        implicitWidth: 1
                        Layout.fillHeight: true
                        Layout.leftMargin: 7
                        Layout.rightMargin: 7
                        Layout.topMargin: 1
                        Layout.bottomMargin: 1
                        color: item.hair
                    }
                    ColumnLayout {
                        spacing: 0
                        IndLabel { text: modelData.l; color: modelData.c }
                        IndText {
                            mono: true
                            sz: Tok.tData
                            text: modelData.v
                            color: modelData.hot ? Tok.warn : Tok.ink
                        }
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }

        // The music, as the bar draws it. Same source, same construction — a desktop
        // visualiser that disagreed with the one in the media pill would be a second
        // opinion about the same sound.
        Item {
            visible: item.kind === "media" && item.viz.length > 0 && item.player !== null
            Layout.fillWidth: true
            Layout.topMargin: 3
            implicitHeight: Math.max(10, item.height * 0.26)
            Row {
                id: vizRow
                anchors.fill: parent
                spacing: 2
                Repeater {
                    model: item.viz.length
                    delegate: Rectangle {
                        required property int index
                        readonly property real v: (item.viz[index] || 0) / 100
                        width: Math.max(1, (vizRow.width - (item.viz.length - 1) * 2)
                                           / Math.max(1, item.viz.length))
                        height: Math.max(1.5, v * vizRow.height)
                        anchors.bottom: parent.bottom
                        radius: 0
                        color: Qt.rgba(item.accent.r, item.accent.g, item.accent.b,
                                       0.45 + 0.5 * v)
                    }
                }
            }
        }

        // Long values (a track title) cannot use IndKpi — its figure has no width to elide
        // against, and a title is exactly the thing that will be too long.
        IndText {
            visible: item.kind === "clock" || item.kind === "media"
            Layout.fillWidth: true
            mono: true
            sz: Math.max(15, Math.round(item.height * item.figureScale))
            text: item.figure
            font.weight: 500
            color: Tok.ink
            elide: Text.ElideRight
            horizontalAlignment: item.hAlign
        }
        IndText {
            visible: (item.kind === "clock" || item.kind === "media") && item.detail.length > 0
            Layout.fillWidth: true
            mono: true
            sz: Tok.tData
            text: item.detail
            color: Tok.ink3
            elide: Text.ElideRight
            horizontalAlignment: item.hAlign
        }
    }

    readonly property real figureScale: item.kind === "clock" ? 0.44 : 0.30
    readonly property string caption: {
        switch (item.kind) {
        case "clock":   return "";              // the time needs no label
        case "weather": return "weather";
        case "media":   return "playing";
        case "system":  return "system";
        }
        return "";
    }
    // Memory, temperature and whichever of the GPU or the network is worth a column. A
    // machine with no discrete GPU should not be shown an empty GPU reading, so the last
    // column is whatever this machine actually has.
    readonly property bool hasGpu:
        !!(item.readings && item.readings.gpuName && ("" + item.readings.gpuName).length > 0)
    readonly property var stats: {
        var r = item.readings || {};
        var out = [];
        // cpu leads above; these are the rest, each tinted to its trace so the chart needs
        // no separate key.
        if (r.memPct !== undefined)
            out.push({ l: "mem", v: Math.round(r.memPct) + "%", hot: r.memPct >= 85,
                       c: Tok.ink3 });
        if (item.hasGpu)
            out.push({ l: "gpu", v: Math.round(r.gpu || 0) + "%", hot: (r.gpu || 0) >= 90,
                       c: Tok.warn });
        if (r.cpuTemp)
            out.push({ l: "cpu\u00b0", v: Math.round(r.cpuTemp) + "\u00b0", hot: r.cpuTemp >= 80,
                       c: Tok.ink2 });
        if (item.hasGpu && r.gpuTemp)
            out.push({ l: "gpu\u00b0", v: Math.round(r.gpuTemp) + "\u00b0",
                       hot: r.gpuTemp >= 85, c: Tok.ink2 });
        if (r.netRx !== undefined)
            out.push({ l: "net", v: item.rate(r.netRx), hot: false, c: Tok.ink2 });
        return out;
    }
    function rate(bytes) {
        var b = bytes || 0;
        if (b >= 1048576) return (b / 1048576).toFixed(1) + "M";
        if (b >= 1024) return Math.round(b / 1024) + "K";
        return Math.round(b) + "B";
    }

    readonly property string unit: {
        switch (item.kind) {
        case "system":  return "cpu";
        case "weather": return "";
        }
        return "";
    }
    readonly property string figure: {
        switch (item.kind) {
        case "clock":   return clk.hhmm;
        case "weather": return (item.readings && item.readings.wxTemp) ? item.readings.wxTemp : "—";
        case "media":   return item.player ? ("" + (item.player.trackTitle || "")) : "";
        case "system":  return (item.readings && item.readings.cpu !== undefined)
                               ? (Math.round(item.readings.cpu) + "%") : "—";
        }
        return "";
    }
    readonly property string detail: {
        switch (item.kind) {
        case "clock":   return clk.date;
        case "weather": return (item.readings && item.readings.wxCond) ? item.readings.wxCond : "";
        case "media":   return item.player ? ("" + (item.player.trackArtist || "")) : "";
        case "system": return "";       // the readings row below carries the rest
        }
        return "";
    }

    QtObject {
        id: clk
        property string hhmm: ""
        property string date: ""
        property real minuteFrac: 0
    }
    Timer {
        running: item.kind === "clock"
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var d = new Date();
            clk.hhmm = Qt.formatDateTime(d, "HH:mm");
            clk.date = Qt.formatDateTime(d, "ddd d MMM").toLowerCase();
            clk.minuteFrac = d.getSeconds() / 60;
        }
    }

    // ---------- shortcut ----------
    Column {
        anchors.centerIn: parent
        visible: item.kind === "launch"
        spacing: 5
        IconImage {
            anchors.horizontalCenter: parent.horizontalCenter
            implicitSize: Math.max(24, Math.min(item.width, item.height) * 0.52)
            source: (item.spec && item.spec.icon)
                    ? Quickshell.iconPath(item.spec.icon, true) : ""
            visible: source !== ""
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: item.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: (item.spec && item.spec.label) ? item.spec.label : ""
            color: item.ink
            font.family: Tok.mono
            font.pixelSize: 10
            font.letterSpacing: 0.6
            renderType: Text.NativeRendering
        }
    }

    Process { id: launcher }
    function launch() {
        if (!item.spec) return;
        // A .desktop id is the better handle: the entry knows its own Exec field codes, its
        // working directory and whether it wants a terminal, none of which survive being
        // flattened into a string. A raw command still works for anything without an entry —
        // a script, a one-liner — which is most of what a shortcut is for.
        if (item.spec.entry) {
            try {
                var e = DesktopEntries.byId("" + item.spec.entry);
                if (e) { e.execute(); return }
            } catch (err) {}
        }
        if (!item.spec.exec) return;
        launcher.command = ["sh", "-c", "" + item.spec.exec];
        launcher.running = true;
    }

    // ---------- editing one widget ----------
    // A gear on every widget while arranging, as macOS's Edit Widget: its size, look, face and
    // ground right on the desktop, where you can see what each choice does, instead of a list
    // of chips in Settings that you have to match back to the widget by name.
    property bool optionsOpen: false
    onEditingChanged: if (!editing) item.optionsOpen = false
    function setOpt(key, value) {
        if (!item.spec || !item.spec.id) return;
        Quickshell.execDetached(["python3", Qt.resolvedUrl("sea-desktop.py").toString().replace("file://", ""),
                                 "--set", "" + item.spec.id, "--" + key, "" + value]);
    }
    // ---------- interaction ----------
    MouseArea {
        id: dragArea
        enabled: item.editing || item.kind === "launch"
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: item.editing ? (drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                  : (item.kind === "launch" ? Qt.PointingHandCursor
                                                            : Qt.ArrowCursor)
        drag.target: item.editing ? item : null
        drag.threshold: 4
        // Right-click removes, but only while arranging: on a desktop you are using, the
        // gesture that deletes your shortcut must not be one click away from launching it.
        acceptedButtons: item.editing ? (Qt.LeftButton | Qt.RightButton) : Qt.LeftButton
        // Holding shift means "exactly here" — the nudge is help, not a rule.
        property bool exact: false
        onPressed: mouse => { dragArea.exact = (mouse.modifiers & Qt.ShiftModifier) !== 0 }
        onReleased: {
            if (!item.editing) return;
            var fx = Math.max(0, Math.min(1, item.x / item.fieldW));
            var fy = Math.max(0, Math.min(1, (item.y - item.fieldY) / item.fieldH));
            item.moved(fx, fy, dragArea.exact);
        }
        onClicked: mouse => {
            if (item.editing) {
                if (mouse.button === Qt.RightButton) item.removed();
                return;
            }
            if (item.kind === "launch") item.launch();
        }
    }

    Rectangle {
        id: gear
        visible: item.editing && item.kind !== "launch"
        z: 5
        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: -2
        width: 30; height: 30; radius: 15
        color: gearMa.containsMouse || item.optionsOpen ? Tok.accent : Tok.bg
        border.width: 1; border.color: Tok.ruleHard
        Text { anchors.centerIn: parent; text: item.optionsOpen ? "close" : "settings"; font.family: "Material Symbols Rounded"; font.pixelSize: 17
            color: gearMa.containsMouse || item.optionsOpen ? Tok.accentInk : Tok.ink }
        MouseArea { id: gearMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: item.optionsOpen = !item.optionsOpen }
    }
    Rectangle {
        id: options
        visible: item.optionsOpen && item.editing
        z: 6
        // opens towards the middle of the screen, so it is never cut off at an edge
        x: item.x + item.width / 2 > item.fieldW / 2 ? item.width - width : 0
        y: gear.y + gear.height + 6
        width: optCol.implicitWidth + 24; height: optCol.implicitHeight + 24
        radius: 18; color: Tok.bg; border.width: 1; border.color: Tok.ruleHard
        MouseArea { anchors.fill: parent }      // clicks here are not drags of the widget
        Column {
            id: optCol
            anchors.centerIn: parent; spacing: 8
            DesktopOption { item: item; label: "Size"; key: "size"; current: (item.spec && item.spec.size) || (item.kind === "clock" ? "small" : "medium")
                choices: [{ v: "small", l: "S" }, { v: "medium", l: "M" }, { v: "large", l: "L" }] }
            DesktopOption { item: item; label: "Look"; key: "look"; current: item.look
                // Classic is the original read-out, which only knows the first four kinds
                choices: [{ v: "card", l: "Card" }, { v: "glass", l: "Glass" }, { v: "clear", l: "Clear" }]
                    .concat(item.kind === "calendar" || item.kind === "battery" ? [] : [{ v: "classic", l: "Classic" }]) }
            DesktopOption { item: item; visible: item.kind === "clock"; label: "Face"; key: "face"; current: (item.spec && item.spec.face) || "dial"
                choices: [{ v: "dial", l: "Dial" }, { v: "cookie", l: "Cookie" }, { v: "digital", l: "Digital" }, { v: "stacked", l: "Stack" }] }
            DesktopOption { item: item; visible: item.look === "classic"; label: "Ground"; key: "ground"; current: item.ground
                choices: [{ v: "rule", l: "Auto" }, { v: "panel", l: "Panel" }, { v: "bare", l: "Bare" }] }
            DesktopOption { item: item; visible: item.look === "classic"; label: "Colour"; key: "tone"; current: item.tone
                choices: [{ v: "accent", l: "Accent" }, { v: "frost", l: "Frost" }, { v: "plain", l: "Plain" }] }
            Row {
                spacing: 6
                Rectangle {
                    implicitWidth: pinT.implicitWidth + 40; implicitHeight: 28; radius: 14
                    color: pinMa.containsMouse ? Tok.accentWash : Tok.sunken
                    Row { id: pinT; anchors.centerIn: parent; spacing: 4
                        Text { text: "push_pin"; font.family: "Material Symbols Rounded"; font.pixelSize: 15; color: Tok.ink; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: item.spec && item.spec.pinned ? "Pinned" : "Pin here"; font.family: Tok.sans; font.pixelSize: 11; color: Tok.ink; anchors.verticalCenter: parent.verticalCenter } }
                    MouseArea { id: pinMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["python3", Qt.resolvedUrl("sea-desktop.py").toString().replace("file://", ""),
                            item.spec && item.spec.pinned ? "--unpin" : "--pin", "" + item.spec.id]) }
                }
                Rectangle {
                    implicitWidth: rmT.implicitWidth + 40; implicitHeight: 28; radius: 14
                    color: rmMa.containsMouse ? Tok.critWash : Tok.sunken
                    Row { id: rmT; anchors.centerIn: parent; spacing: 4
                        Text { text: "delete"; font.family: "Material Symbols Rounded"; font.pixelSize: 15; color: Tok.crit; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "Remove"; font.family: Tok.sans; font.pixelSize: 11; color: Tok.crit; anchors.verticalCenter: parent.verticalCenter } }
                    MouseArea { id: rmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { item.optionsOpen = false; item.removed() } }
                }
            }
        }
    }

    // ---------- while dragging: where will it really land ----------
    // A widget let go on busy ground moves to the nearest calm spot, which looked like a drag
    // that had not worked. Now it says so before you let go.
    readonly property bool overBusy: dragArea.drag.active && !!item.busyFn && !!item.spec
        && item.busyFn(item.x / item.fieldW, (item.y - item.fieldY) / item.fieldH, item.spec.w, item.spec.h) > item.busyLimit
    Rectangle {
        visible: item.overBusy
        z: 7
        anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.bottom; anchors.topMargin: 16
        width: hintT.implicitWidth + 24; height: 30; radius: 15; color: Tok.bg; border.width: 1; border.color: Tok.warn
        Text { id: hintT; anchors.centerIn: parent; text: "Busy here: it will move to a calm spot · hold Shift to keep it here"
            color: Tok.ink; font.family: Tok.sans; font.pixelSize: 11 }
    }

    // ---------- resizing ----------
    // Drag the corner; the widget snaps to the nearest of the three sizes, as macOS's do, and
    // the outline shows which one it will be before you let go.
    property string resizeTo: ""
    readonly property var footPx: ({
        small:  { w: 0.0885 * item.fieldW, h: 0.17 * item.fieldH },
        medium: { w: 0.1875 * item.fieldW, h: 0.17 * item.fieldH },
        large:  { w: 0.1875 * item.fieldW, h: 0.376 * item.fieldH } })
    Rectangle {
        visible: item.resizeTo !== ""
        z: 4
        width: item.resizeTo ? item.footPx[item.resizeTo].w : 0
        height: item.resizeTo ? item.footPx[item.resizeTo].h : 0
        radius: 22; color: "transparent"; border.width: 2; border.color: Tok.accent
        Rectangle { anchors.centerIn: parent; width: sizeT.implicitWidth + 20; height: 26; radius: 13; color: Tok.accent
            Text { id: sizeT; anchors.centerIn: parent; text: item.resizeTo ? item.resizeTo.charAt(0).toUpperCase() + item.resizeTo.slice(1) : ""
                color: Tok.accentInk; font.family: Tok.sans; font.pixelSize: 12; font.bold: true } }
    }
    Rectangle {
        id: grip
        visible: item.editing && item.kind !== "launch" && !item.optionsOpen
        z: 5
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: -4
        width: 26; height: 26; radius: 13
        color: gripMa.containsMouse || gripMa.pressed ? Tok.accent : Tok.bg
        border.width: 1; border.color: Tok.ruleHard
        Text { anchors.centerIn: parent; text: "open_in_full"; rotation: 90; font.family: "Material Symbols Rounded"; font.pixelSize: 15
            color: gripMa.containsMouse || gripMa.pressed ? Tok.accentInk : Tok.ink }
        MouseArea {
            id: gripMa
            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.SizeFDiagCursor
            property point start
            onPressed: e => start = mapToItem(item, e.x, e.y)
            onPositionChanged: e => {
                if (!pressed) return;
                var p = mapToItem(item, e.x, e.y);
                var w = item.width + (p.x - start.x), h = item.height + (p.y - start.y);
                var fp = item.footPx;
                item.resizeTo = w < (fp.small.w + fp.medium.w) / 2 ? "small"
                              : h > (fp.medium.h + fp.large.h) / 2 ? "large" : "medium";
            }
            onReleased: { if (item.resizeTo) item.setOpt("size", item.resizeTo); item.resizeTo = "" }
            onCanceled: item.resizeTo = ""
        }
    }
}
