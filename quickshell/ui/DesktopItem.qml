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
    property var history: []
    property var viz: []
    property real fieldW: 1920
    property real fieldH: 1000
    property real fieldY: 0

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
        radius: Tok.r + 2
        color: item.pal ? item.pal.a(item.pal.bg, 0.62) : "#a0101010"
        opacity: item.editing ? 0.0
               : item.ground === "panel" ? 0.92
               : Math.max(0, Math.min(1, (item.busy - 0.30) * 4))
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Tok.mEase } }
    }

    // ---------- the arranging frame ----------
    Rectangle {
        anchors.fill: parent
        anchors.margins: -10
        radius: Tok.r + 2
        visible: item.editing
        color: item.pal ? item.pal.a(item.pal.bg, 0.45) : "#40000000"
        border.width: 1
        border.color: item.pal ? item.pal.a(item.pal.iris, dragArea.drag.active ? 0.95 : 0.4)
                               : "#7788ccff"
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
        visible: item.kind !== "launch"

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

        // A load figure with no history is a number; with one it is an instrument.
        IndSpark {
            visible: item.kind === "system" && item.history.length > 1
            Layout.fillWidth: true
            implicitHeight: Math.max(12, item.height * 0.20)
            values: item.history
            stroke: item.accent
            ground: "transparent"
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
                        IndLabel { text: modelData.l }
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
    readonly property var stats: {
        var r = item.readings || {};
        var out = [];
        if (r.memPct !== undefined)
            out.push({ l: "mem", v: Math.round(r.memPct) + "%", hot: r.memPct >= 85 });
        if (r.cpuTemp)
            out.push({ l: "temp", v: Math.round(r.cpuTemp) + "\u00b0", hot: r.cpuTemp >= 80 });
        if (r.gpuName && r.gpuName.length > 0)
            out.push({ l: "gpu", v: Math.round(r.gpu || 0) + "%", hot: (r.gpu || 0) >= 90 });
        else if (r.netRx !== undefined)
            out.push({ l: "net", v: item.rate(r.netRx), hot: false });
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

    // ---------- interaction ----------
    MouseArea {
        id: dragArea
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
}
