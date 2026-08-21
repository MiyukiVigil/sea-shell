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
    // One shape for every widget — label, rule, figure, detail — so adding a kind is three
    // strings and never a new layout. That is also what keeps four widgets looking like one
    // instrument instead of four applications.
    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        visible: item.kind !== "launch"

        Text {
            id: capText
            width: parent.width
            horizontalAlignment: item.hAlign
            text: item.caption
            visible: text.length > 0 && item.ground !== "bare"
            color: item.ink2
            font.family: Tok.mono
            font.pixelSize: Math.max(8, Math.min(11, item.height * 0.13))
            font.weight: 600
            font.letterSpacing: 1.15
            font.capitalization: Font.AllUppercase
            renderType: Text.NativeRendering
        }

        // The rule, and the one piece of colour in the whole widget. A hairline on its own
        // is a divider; a hairline that starts with a short accent segment is a mark, and
        // that is the difference between text lying on a picture and text placed on one.
        //
        // On the CLOCK the accent segment is not decoration — it is the minute, filling
        // left to right as it passes. An instrument's rule should be doing something.
        Item {
            width: parent.width
            height: 1
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

        Text {
            width: parent.width
            horizontalAlignment: item.hAlign
            text: item.figure
            color: item.ink
            font.family: Tok.mono
            font.pixelSize: Math.max(15, item.height * item.figureScale)
            font.weight: 500
            // Tabular figures: a value that changes width as it counts makes the whole
            // desktop twitch once a second.
            font.features: ({ "tnum": 1 })
            renderType: Text.NativeRendering
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            horizontalAlignment: item.hAlign
            text: item.detail
            visible: text.length > 0
            color: item.ink2
            font.family: Tok.mono
            font.pixelSize: Math.max(8, Math.min(12, item.height * 0.12))
            font.features: ({ "tnum": 1 })
            renderType: Text.NativeRendering
            elide: Text.ElideRight
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
        case "system": {
            if (!item.readings || item.readings.memPct === undefined) return "";
            var t = item.readings.cpuTemp ? ("   " + Math.round(item.readings.cpuTemp) + "°") : "";
            return "mem " + Math.round(item.readings.memPct) + "%" + t;
        }
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
