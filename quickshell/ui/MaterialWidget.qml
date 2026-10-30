// sea-shell — one widget: clock, weather, system, media, calendar or batteries.
//
// SHAPED LIKE macOS, DRESSED LIKE MATERIAL 3, SPEAKING SEA-SHELL. macOS gives the structure:
// three size classes, and each class is its own layout rather than the same one stretched — a
// small widget says one thing, a medium one adds the next most useful thing beside it, a large
// one adds the detail. Material 3 gives the shapes and colour roles: tonal containers, the
// scalloped dial that has been this shell's clock all along, filled rounded symbols, a play
// button that turns from a circle into a squircle while it plays. And the voice is the shell's
// own: its font, its palette, one accent, nothing translucent.
//
// Everything is measured in `u`, the widget's size over its class's design size, so a widget
// enlarged on the desktop is the same drawing, larger, and never a reflowed one.
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: card
    property string kind: "clock"
    // "s" | "m" | "l". Left empty, it is read from the shape it was given: wide is medium,
    // square is small until it is large enough to be large.
    property string size: ""
    property string mediaPart: "all"
    // the clock's face: "dial" (scalloped), "cookie" (fewer, deeper lobes and a second-hand
    // dot riding the rim), "digital", or "stacked" (hours over minutes)
    property string face: "dial"
    readonly property bool analog: face === "dial" || face === "cookie"      // "controls": only the transport row (the bar's media drop-down)
    property var readings: ({})
    property var player: null
    property var viz: []
    property bool active: true
    property color surface: "#f3f1f8"
    property color container: "#e5dff5"
    property color accent: "#65538c"
    property color ink: "#211c2a"
    property color secondary: "#5e5769"
    property color accentInk: "white"
    property string uiFont: "Adwaita Sans"
    property bool reducedMotion: false
    // No card: the drawing stands on its own, as the scalloped dial does on a wallpaper.
    property bool bare: false
    // How much of the card is drawn, 0..1: 1 a solid card, about half for glass, 0 for none.
    // Only the card's own fill: the content on it stays at full strength.
    property real fill: 1
    // the small tiles on a card (forecast days, details) thin out with it
    readonly property color tile: Qt.rgba(surface.r, surface.g, surface.b, 0.3 + 0.7 * fill)

    readonly property string cls: {
        if (card.size === "s" || card.size === "m" || card.size === "l") return card.size;
        var aspect = card.width / Math.max(1, card.height);
        if (aspect >= 1.5) return "m";
        return card.width >= 300 ? "l" : "s";
    }
    readonly property real designW: cls === "s" ? 170 : 360
    readonly property real designH: cls === "l" ? 376 : 170
    readonly property real u: Math.max(0.55, Math.min(card.width / designW, card.height / designH))
    readonly property real pad: 16 * u

    property date now: new Date()
    property real playPosition: player ? player.position : 0
    readonly property bool playing: !!player && !!player.isPlaying
    readonly property bool controlsOnly: kind === "media" && mediaPart === "controls"

    radius: controlsOnly ? 0 : Math.min(30, 22 * u)
    readonly property color base: (kind === "weather" || (kind === "clock" && cls === "s")) ? container : surface
    color: controlsOnly || bare ? "transparent" : Qt.rgba(base.r, base.g, base.b, fill)
    border.width: controlsOnly || bare ? 0 : 1
    border.color: Qt.rgba(ink.r, ink.g, ink.b, 0.07 * Math.max(fill, 0.4))
    clip: true

    Timer {
        interval: 1000; repeat: true
        running: card.active && card.visible && (card.kind === "clock" || card.kind === "calendar" || (card.kind === "media" && card.playing))
        triggeredOnStart: true
        onTriggered: { card.now = new Date(); if (card.player) card.playPosition = card.player.position }
    }
    onPlayerChanged: playPosition = player ? player.position : 0

    function timeText(seconds) { var s = Math.max(0, Math.floor(seconds || 0)); return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60) }
    function transport(action) {
        if (!player) return;
        if (action === "play" && player.canTogglePlaying !== false) player.togglePlaying();
        if (action === "next" && player.canGoNext) player.next();
        if (action === "previous" && player.canGoPrevious) player.previous();
    }
    function seek(fraction) {
        if (!player || !player.canSeek || !(player.length > 0)) return;
        playPosition = Math.max(0, Math.min(1, fraction)) * player.length;
        player.position = playPosition;
    }
    function wxSymbol(c) {
        c = ("" + (c || "")).toLowerCase();
        if (c.indexOf("thunder") >= 0) return "thunderstorm";
        if (c.indexOf("snow") >= 0 || c.indexOf("sleet") >= 0 || c.indexOf("ice") >= 0) return "weather_snowy";
        if (c.indexOf("rain") >= 0 || c.indexOf("drizzle") >= 0 || c.indexOf("shower") >= 0) return "rainy";
        if (c.indexOf("fog") >= 0 || c.indexOf("mist") >= 0 || c.indexOf("haze") >= 0) return "foggy";
        if (c.indexOf("overcast") >= 0) return "cloud";
        if (c.indexOf("cloud") >= 0 || c.indexOf("partly") >= 0) return "partly_cloudy_day";
        if (c.indexOf("clear") >= 0 || c.indexOf("sunny") >= 0) return (card.now.getHours() >= 19 || card.now.getHours() < 6) ? "clear_night" : "sunny";
        return "cloud";
    }
    function pct(v) { var n = Number(v); return isNaN(n) ? 0 : Math.max(0, Math.min(100, n)) }

    component Label: Text {
        color: card.ink; font.family: card.uiFont; elide: Text.ElideRight
        renderType: Text.QtRendering
    }
    // Rounded outlines. The filled style (FILL 1) of the variable font draws with holes and
    // speckles under this Qt, so it is not used.
    component Symbol: Text {
        color: card.accent
        font.family: "Material Symbols Rounded"
        font.variableAxes: ({ "FILL": 0, "wght": 400 })
        font.pixelSize: 24
    }
    // The line every macOS widget opens with: a small coloured glyph and what this is.
    component Header: Row {
        property string icon: ""
        property string text: ""
        property color tint: card.accent
        spacing: 5 * card.u
        Symbol { text: parent.icon; color: parent.tint; font.pixelSize: 14 * card.u; anchors.verticalCenter: parent.verticalCenter }
        Label { text: parent.text.toUpperCase(); color: parent.tint; font.pixelSize: 10 * card.u; font.weight: Font.DemiBold
            font.letterSpacing: 1.1 * card.u; anchors.verticalCenter: parent.verticalCenter }
    }

    // =====================================================================================
    // CLOCK
    // =====================================================================================
    // The scalloped face: twelve soft lobes, as Material's "cookie" shape, in the accent. Drawn
    // again each second only while the widget can be seen.
    component Dial: Canvas {
        id: dial
        property bool numerals: false
        property bool seconds: true
        property int tick: card.now.getSeconds()
        onTickChanged: requestPaint()
        onWidthChanged: requestPaint()
        Connections { target: card; function onAccentChanged() { dial.requestPaint() } function onContainerChanged() { dial.requestPaint() }
            function onFaceChanged() { dial.requestPaint() } }
        onPaint: {
            var c = getContext("2d"), r = width * .47, x = width / 2, y = height / 2, d = card.now;
            c.clearRect(0, 0, width, height);
            if (r <= 0) return;
            c.beginPath();
            var lobes = card.face === "cookie" ? 7 : 12, depth = card.face === "cookie" ? .09 : .06;
            for (var i = 0; i <= 360; i++) {
                var a = i * Math.PI / 180, rr = r * (1 - depth + depth * Math.cos(a * lobes));
                var xx = x + Math.cos(a) * rr, yy = y + Math.sin(a) * rr;
                if (i === 0) c.moveTo(xx, yy); else c.lineTo(xx, yy);
            }
            c.closePath(); c.fillStyle = card.accent; c.fill();
            c.strokeStyle = Qt.rgba(card.accentInk.r, card.accentInk.g, card.accentInk.b, .55);
            for (var k = 0; k < 12; k++) {
                var t = k * Math.PI / 6;
                c.lineWidth = Math.max(1, r * (k % 3 === 0 ? .045 : .022)); c.lineCap = "round";
                c.beginPath(); c.moveTo(x + Math.sin(t) * r * .70, y - Math.cos(t) * r * .70);
                c.lineTo(x + Math.sin(t) * r * (k % 3 === 0 ? .80 : .77), y - Math.cos(t) * r * (k % 3 === 0 ? .80 : .77)); c.stroke();
            }
            function hand(angle, len, w, col) {
                c.beginPath(); c.moveTo(x, y); c.lineTo(x + Math.sin(angle) * r * len, y - Math.cos(angle) * r * len);
                c.lineWidth = w; c.lineCap = "round"; c.strokeStyle = col; c.stroke();
            }
            var m = d.getMinutes() + d.getSeconds() / 60;
            hand(((d.getHours() % 12) + m / 60) * Math.PI / 6, .44, Math.max(3, r * .085), card.accentInk);
            hand(m * Math.PI / 30, .64, Math.max(2, r * .055), card.accentInk);
            if (dial.seconds && !card.reducedMotion && card.face === "cookie") {
                var sa = d.getSeconds() * Math.PI / 30;
                c.beginPath(); c.arc(x + Math.sin(sa) * r * .80, y - Math.cos(sa) * r * .80, r * .055, 0, Math.PI * 2);
                c.fillStyle = card.container; c.fill();
            } else if (dial.seconds && !card.reducedMotion)
                hand(d.getSeconds() * Math.PI / 30, .70, Math.max(1, r * .02), card.container);
            c.beginPath(); c.arc(x, y, r * .07, 0, Math.PI * 2); c.fillStyle = card.accentInk; c.fill();
        }
    }

    // hours over minutes, the Material 3 expressive clock: hours in the accent, minutes in ink
    component StackedFace: Column {
        property real px: 60
        spacing: -px * .18
        Label { text: Qt.formatDateTime(card.now, "HH"); color: card.accent; font.pixelSize: parent.px; font.weight: Font.Bold; font.features: { "tnum": 1 } }
        Label { text: Qt.formatDateTime(card.now, "mm"); color: card.ink; font.pixelSize: parent.px; font.weight: Font.Bold; font.features: { "tnum": 1 } }
    }

    // small: the face alone, as macOS's clock widget is
    Item {
        visible: card.kind === "clock" && card.cls === "s"
        anchors.fill: parent; anchors.margins: card.pad * .7
        Dial { visible: card.analog; anchors.centerIn: parent; width: Math.min(parent.width, parent.height); height: width }
        Column {
            visible: card.face === "digital"; anchors.centerIn: parent; spacing: 2 * card.u
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(card.now, "dddd").toUpperCase(); color: card.accent
                font.pixelSize: 10 * card.u; font.weight: Font.DemiBold; font.letterSpacing: 1.2 * card.u }
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(card.now, "HH:mm")
                font.pixelSize: 38 * card.u; font.weight: Font.Bold; font.features: { "tnum": 1 } }
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(card.now, "d MMM"); color: card.secondary; font.pixelSize: 11 * card.u }
        }
        StackedFace { visible: card.face === "stacked"; anchors.centerIn: parent; px: 62 * card.u }
    }
    // medium: the time to read, the face to glance at
    Item {
        visible: card.kind === "clock" && card.cls === "m"
        anchors.fill: parent; anchors.margins: card.pad
        StackedFace { id: mStack; visible: card.face === "stacked"; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; px: 64 * card.u }
        Column {
            anchors.left: card.face === "stacked" ? mStack.right : parent.left
            anchors.leftMargin: card.face === "stacked" ? card.pad : 0
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (card.analog ? clockFace.width + card.pad : 0) - (card.face === "stacked" ? mStack.width + card.pad : 0)
            spacing: 2 * card.u
            Label { text: Qt.formatDateTime(card.now, "dddd").toUpperCase(); color: card.accent
                font.pixelSize: 11 * card.u; font.weight: Font.DemiBold; font.letterSpacing: 1.2 * card.u }
            Label { visible: card.face !== "stacked"; width: parent.width; text: Qt.formatDateTime(card.now, "HH:mm")
                font.pixelSize: (card.face === "digital" ? 58 : 46) * card.u; font.weight: card.face === "digital" ? Font.Bold : Font.DemiBold
                font.features: { "tnum": 1 } }
            Label { width: parent.width; text: Qt.formatDateTime(card.now, "d MMMM yyyy"); color: card.secondary; font.pixelSize: 12 * card.u }
        }
        Dial { id: clockFace; visible: card.analog; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            width: Math.min(parent.height, parent.width * .42); height: width }
    }
    // large: the day, and the month around it
    ColumnLayout {
        visible: card.kind === "clock" && card.cls === "l"
        anchors.fill: parent; anchors.margins: card.pad
        spacing: 10 * card.u
        RowLayout {
            Layout.fillWidth: true; spacing: card.pad
            Column {
                Layout.fillWidth: true; spacing: 2 * card.u
                Label { text: Qt.formatDateTime(card.now, "dddd").toUpperCase(); color: card.accent
                    font.pixelSize: 11 * card.u; font.weight: Font.DemiBold; font.letterSpacing: 1.2 * card.u }
                Label { visible: card.face !== "stacked"; text: Qt.formatDateTime(card.now, "HH:mm"); font.pixelSize: 42 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                Label { text: Qt.formatDateTime(card.now, "d MMMM"); color: card.secondary; font.pixelSize: 12 * card.u }
            }
            Dial { visible: card.analog; Layout.preferredWidth: 96 * card.u; Layout.preferredHeight: 96 * card.u }
            StackedFace { visible: card.face === "stacked"; px: 50 * card.u }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, .08) }
        // month grid, Monday first
        GridLayout {
            id: month
            Layout.fillWidth: true; Layout.fillHeight: true
            columns: 7; rowSpacing: 2 * card.u; columnSpacing: 0
            readonly property var cells: {
                var d = card.now, first = new Date(d.getFullYear(), d.getMonth(), 1);
                var lead = (first.getDay() + 6) % 7, days = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
                var out = ["M", "T", "W", "T", "F", "S", "S"].map(function (l) { return { l: l, head: true } });
                for (var i = 0; i < lead; i++) out.push({ l: "" });
                for (var n = 1; n <= days; n++) out.push({ l: "" + n, today: n === d.getDate(), weekend: ((lead + n - 1) % 7) >= 5 });
                return out;
            }
            Repeater {
                model: month.cells
                delegate: Item {
                    required property var modelData
                    Layout.fillWidth: true; implicitHeight: 24 * card.u
                    Rectangle { anchors.centerIn: parent; width: 24 * card.u; height: width; radius: width / 2
                        visible: !!modelData.today; color: card.accent }
                    Label { anchors.centerIn: parent; text: modelData.l
                        color: modelData.today ? card.accentInk : modelData.head ? card.accent
                             : modelData.weekend ? card.secondary : card.ink
                        font.pixelSize: (modelData.head ? 10 : 12) * card.u
                        font.weight: modelData.head || modelData.today ? Font.DemiBold : Font.Normal }
                }
            }
        }
    }

    // =====================================================================================
    // WEATHER
    // =====================================================================================
    readonly property var wx: card.readings || ({})
    readonly property var forecast: (card.wx.wxForecast || []).slice(0, card.cls === "s" ? 0 : 3)
    readonly property var today: (card.wx.wxForecast && card.wx.wxForecast.length) ? card.wx.wxForecast[0] : null
    Item {
        visible: card.kind === "weather"
        anchors.fill: parent; anchors.margins: card.pad
        // the condition, large and quiet, behind everything: Material's tonal illustration
        Symbol {
            visible: card.cls === "s"
            text: card.wxSymbol(card.wx.wxCond); color: Qt.rgba(card.accent.r, card.accent.g, card.accent.b, .13)
            font.pixelSize: (card.cls === "s" ? 120 : 150) * card.u
            anchors.right: parent.right; anchors.rightMargin: -card.pad * 1.6
            anchors.top: parent.top; anchors.topMargin: -card.pad * 1.2
        }
        ColumnLayout {
            anchors.fill: parent; spacing: 0
            RowLayout {
                Layout.fillWidth: true; Layout.fillHeight: card.cls !== "l"; spacing: 12 * card.u
                Layout.preferredHeight: card.cls === "l" ? 150 * card.u : -1
                // today: where, how warm, what it is like
                ColumnLayout {
                    Layout.fillHeight: true; Layout.preferredWidth: card.cls === "s" ? -1 : 128 * card.u
                    Layout.maximumWidth: card.cls === "s" ? -1 : 128 * card.u
                    Layout.fillWidth: card.cls === "s"
                    spacing: 0
                    Header { icon: "location_on"; text: card.wx.wxLoc || "weather" }
                    Item { Layout.fillHeight: true }
                    Label { text: card.wx.wxTemp || "—"; font.pixelSize: 40 * card.u; font.weight: Font.DemiBold; color: card.ink }
                    RowLayout {
                        spacing: 4 * card.u
                        Symbol { text: card.wxSymbol(card.wx.wxCond); font.pixelSize: 15 * card.u }
                        Label { Layout.fillWidth: true; text: card.wx.wxCond || "unavailable"; font.pixelSize: 12 * card.u; color: card.ink }
                    }
                    Label { visible: !!card.today; text: card.today ? ("H:" + card.today.hi + "  L:" + card.today.lo) : ""
                        color: card.secondary; font.pixelSize: 11 * card.u; font.features: { "tnum": 1 } }
                }
                // the next days, as columns
                RowLayout {
                    visible: card.cls !== "s" && card.forecast.length > 0
                    Layout.fillWidth: true; Layout.fillHeight: true; spacing: 6 * card.u
                    Repeater {
                        model: card.forecast
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true; Layout.fillHeight: true
                            Layout.minimumWidth: 0; Layout.preferredWidth: 1
                            radius: 14 * card.u
                            color: index === 0 ? card.accent : card.tile
                            Column {
                                anchors.centerIn: parent; spacing: 5 * card.u
                                Label { anchors.horizontalCenter: parent.horizontalCenter; text: index === 0 ? "Today" : modelData.day
                                    color: index === 0 ? card.accentInk : card.secondary; font.pixelSize: 10 * card.u; font.weight: Font.DemiBold }
                                Symbol { anchors.horizontalCenter: parent.horizontalCenter; text: card.wxSymbol(modelData.cond)
                                    color: index === 0 ? card.accentInk : card.accent; font.pixelSize: 24 * card.u }
                                Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.hi
                                    color: index === 0 ? card.accentInk : card.ink; font.pixelSize: 13 * card.u; font.weight: Font.DemiBold }
                                Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.lo
                                    color: index === 0 ? Qt.rgba(card.accentInk.r, card.accentInk.g, card.accentInk.b, .7) : card.secondary; font.pixelSize: 11 * card.u }
                            }
                        }
                    }
                }
            }
            // large: the numbers that decide what to wear
            GridLayout {
                visible: card.cls === "l"
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.topMargin: 12 * card.u
                columns: 3; columnSpacing: 6 * card.u; rowSpacing: 6 * card.u
                Repeater {
                    model: [{ i: "thermostat", l: "Feels like", v: card.wx.wxFeels }, { i: "humidity_percentage", l: "Humidity", v: card.wx.wxHumid },
                            { i: "air", l: "Wind", v: card.wx.wxWind }]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true; Layout.fillHeight: true
                        Layout.minimumWidth: 0; Layout.preferredWidth: 1
                        radius: 14 * card.u; color: card.tile
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 10 * card.u; anchors.verticalCenter: parent.verticalCenter
                            spacing: 3 * card.u
                            Symbol { text: modelData.i; font.pixelSize: 18 * card.u }
                            Label { text: modelData.v || "—"; font.pixelSize: 15 * card.u; font.weight: Font.DemiBold }
                            Label { text: modelData.l; color: card.secondary; font.pixelSize: 10 * card.u }
                        }
                    }
                }
            }
        }
    }

    // =====================================================================================
    // SYSTEM
    // =====================================================================================
    readonly property var gauges: {
        var r = card.readings || {}, out = [{ l: "CPU", v: card.pct(r.cpu), i: "memory" }, { l: "RAM", v: card.pct(r.memPct), i: "memory_alt" }];
        if (r.gpuName || r.gpu !== undefined) out.push({ l: "GPU", v: card.pct(r.gpu), i: "developer_board" });
        return out;
    }
    // A Material 3 gauge: a thick tonal track, the value in the accent with rounded ends,
    // turning amber then red as it fills.
    component Gauge: Canvas {
        id: g
        property real amount: 0
        property real thickness: 8
        // what is drawn: eases toward amount so a new reading sweeps rather than jumps
        property real shown: amount
        Behavior on shown { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        property color tone: amount >= 85 ? "#e5534b" : amount >= 65 ? "#d9a440" : card.accent
        onShownChanged: requestPaint(); onWidthChanged: requestPaint(); onToneChanged: requestPaint()
        Connections { target: card; function onContainerChanged() { g.requestPaint() } }
        onPaint: {
            var c = getContext("2d"), r = width / 2 - thickness / 2 - 1, cx = width / 2, cy = height / 2;
            var start = Math.PI * .75, sweep = Math.PI * 1.5;
            c.clearRect(0, 0, width, height);
            if (r <= 0) return;             // not laid out yet
            c.lineWidth = thickness; c.lineCap = "round";
            c.beginPath(); c.arc(cx, cy, r, start, start + sweep); c.strokeStyle = card.container; c.stroke();
            if (shown > 0.5) { c.beginPath(); c.arc(cx, cy, r, start, start + sweep * shown / 100); c.strokeStyle = g.tone; c.stroke() }
        }
    }
    Item {
        visible: card.kind === "system"
        anchors.fill: parent; anchors.margins: card.pad
        Header { id: sysHead; icon: "monitor_heart"; text: "System" }
        // small: the processor as one big gauge, memory beside it as a figure
        Item {
            visible: card.cls === "s"
            anchors.fill: parent; anchors.topMargin: sysHead.height + 6 * card.u
            Gauge { id: bigGauge; anchors.centerIn: parent; anchors.verticalCenterOffset: -6 * card.u
                width: Math.min(parent.width, parent.height) * .92; height: width; thickness: 11 * card.u; amount: card.gauges[0].v
                Column { anchors.centerIn: parent; spacing: 0
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(bigGauge.shown) + "%"; font.pixelSize: 26 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: "CPU"; color: card.secondary; font.pixelSize: 10 * card.u; font.weight: Font.DemiBold }
                } }
            Label { anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom
                text: "RAM " + Math.round(card.gauges[1].v) + "%"; color: card.secondary; font.pixelSize: 11 * card.u; font.features: { "tnum": 1 } }
        }
        // medium and large: every gauge, and for large the details under them
        ColumnLayout {
            visible: card.cls !== "s"
            anchors.fill: parent; anchors.topMargin: sysHead.height + 8 * card.u
            spacing: 10 * card.u
            RowLayout {
                Layout.fillWidth: true; Layout.preferredHeight: card.cls === "l" ? 130 * card.u : -1; Layout.fillHeight: card.cls !== "l"
                spacing: 8 * card.u
                Repeater {
                    // a count, not the array: gauges is rebuilt on every reading, and an array model
                    // would recreate each canvas (blank for a frame) instead of updating it
                    model: card.gauges.length
                    delegate: Item {
                        required property int index
                        readonly property var reading: card.gauges[index] || { v: 0, l: "" }
                        Layout.fillWidth: true; Layout.fillHeight: true
                        Gauge { id: gg; anchors.centerIn: parent; width: Math.min(parent.width, parent.height); height: width
                            thickness: 9 * card.u; amount: reading.v
                            Column { anchors.centerIn: parent; spacing: 0
                                Label { anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(gg.shown) + "%"
                                    font.pixelSize: 19 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                                Label { anchors.horizontalCenter: parent.horizontalCenter; text: reading.l; color: card.secondary
                                    font.pixelSize: 9 * card.u; font.weight: Font.DemiBold }
                            } }
                    }
                }
            }
            Repeater {
                model: card.cls === "l" ? card.details : []
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true; spacing: 8 * card.u
                    Rectangle { implicitWidth: 28 * card.u; implicitHeight: 28 * card.u; radius: 9 * card.u; color: card.container
                        Symbol { anchors.centerIn: parent; text: modelData.i; font.pixelSize: 16 * card.u } }
                    Label { text: modelData.l; color: card.secondary; font.pixelSize: 12 * card.u; Layout.fillWidth: true }
                    Label { text: modelData.v; font.pixelSize: 13 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                }
            }
            Item { visible: card.cls === "l"; Layout.fillHeight: true }
        }
    }
    readonly property var details: {
        var r = card.readings || {}, out = [];
        if (r.memUsed) out.push({ i: "memory_alt", l: "Memory", v: Number(r.memUsed).toFixed(1) + (r.memTotal ? " / " + Math.round(r.memTotal) : "") + " GB" });
        if (r.cpuTemp) out.push({ i: "device_thermostat", l: "Processor", v: Math.round(r.cpuTemp) + "°" });
        if (r.gpuTemp) out.push({ i: "thermostat", l: "Graphics", v: Math.round(r.gpuTemp) + "°" });
        if (r.netRx !== undefined) out.push({ i: "download", l: "Network", v: card.rate(r.netRx) + "/s" });
        return out;
    }
    function rate(bytes) {
        var b = bytes || 0;
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
        if (b >= 1024) return Math.round(b / 1024) + " KB";
        return Math.round(b) + " B";
    }

    // =====================================================================================
    // MEDIA
    // =====================================================================================
    readonly property string artUrl: card.player ? (card.player.trackArtUrl || "") : ""
    readonly property string title: card.player ? (card.player.trackTitle || "Unknown track") : "Nothing playing"
    readonly property string artist: card.player ? (card.player.trackArtist || card.player.trackAlbum || "") : "Press play in any app"
    component Art: Rectangle {
        radius: 14 * card.u; color: card.container; clip: true
        Image { id: art; anchors.fill: parent; source: card.artUrl; fillMode: Image.PreserveAspectCrop
            asynchronous: true; sourceSize.width: 384; sourceSize.height: 384; visible: status === Image.Ready }
        Symbol { anchors.centerIn: parent; visible: art.status !== Image.Ready; text: "music_note"; font.pixelSize: parent.width * .4 }
    }
    // the sound, as the bar draws it: one source, so they never disagree
    component Bars: Row {
        id: bars
        property int count: 24
        spacing: 2 * card.u
        Repeater {
            model: bars.count
            delegate: Rectangle {
                required property int index
                readonly property real v: card.active && card.playing && !card.reducedMotion && card.viz.length
                    ? Math.max(0, Math.min(1, Number(card.viz[Math.floor(index * card.viz.length / bars.count)]) / 100)) : 0
                width: (bars.width - (bars.count - 1) * bars.spacing) / bars.count
                height: Math.max(2 * card.u, v * bars.height)
                anchors.bottom: parent.bottom
                radius: width / 2; color: card.accent; opacity: .35 + .65 * v
                Behavior on height { NumberAnimation { duration: card.reducedMotion ? 0 : 90 } }
            }
        }
    }
    component Transport: RowLayout {
        property real k: 1
        spacing: 10 * k
        Repeater {
            model: [{ s: "skip_previous", a: "previous" }, { s: card.playing ? "pause" : "play_arrow", a: "play" }, { s: "skip_next", a: "next" }]
            delegate: Rectangle {
                required property var modelData
                readonly property bool primary: modelData.a === "play"
                readonly property bool allowed: !!card.player && (primary ? card.player.canTogglePlaying !== false
                    : modelData.a === "next" ? !!card.player.canGoNext : !!card.player.canGoPrevious)
                objectName: "media-" + modelData.a
                implicitWidth: (primary ? 56 : 38) * parent.k; implicitHeight: (primary ? 44 : 38) * parent.k
                // Material 3's expressive play button: round at rest, a squircle while playing
                radius: primary && card.playing ? 14 * parent.k : height / 2
                color: primary ? card.accent : card.container; opacity: allowed ? 1 : .4
                Behavior on radius { NumberAnimation { duration: card.reducedMotion ? 0 : 180; easing.type: Easing.OutBack } }
                Symbol { anchors.centerIn: parent; text: modelData.s; color: primary ? card.accentInk : card.accent; font.pixelSize: (primary ? 28 : 22) * parent.parent.k }
                MouseArea { anchors.fill: parent; enabled: parent.allowed; cursorShape: Qt.PointingHandCursor; onClicked: card.transport(modelData.a) }
            }
        }
    }
    component Seek: Item {
        implicitHeight: 14 * card.u
        visible: !!card.player && card.player.length > 0
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5 * card.u; radius: height / 2; color: card.container
            Rectangle { height: parent.height; radius: height / 2; color: card.accent
                width: parent.width * Math.max(0, Math.min(1, card.player && card.player.length > 0 ? card.playPosition / card.player.length : 0)) } }
        MouseArea { anchors.fill: parent; enabled: !!card.player && !!card.player.canSeek; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPressed: e => card.seek(e.x / width); onPositionChanged: e => { if (pressed) card.seek(e.x / width) } }
    }

    // the bar's drop-down: the transport alone
    Transport { visible: card.controlsOnly; anchors.centerIn: parent; k: 1 }

    // small: the cover, and what it is, and one button
    Item {
        visible: card.kind === "media" && !card.controlsOnly && card.cls === "s"
        anchors.fill: parent; anchors.margins: card.pad * .8
        Art { id: sArt; width: parent.width * .58; height: width }
        Rectangle {
            anchors.right: parent.right; anchors.top: parent.top
            width: 40 * card.u; height: width; radius: card.playing ? 13 * card.u : width / 2; color: card.accent
            Behavior on radius { NumberAnimation { duration: card.reducedMotion ? 0 : 180; easing.type: Easing.OutBack } }
            Symbol { anchors.centerIn: parent; text: card.playing ? "pause" : "play_arrow"; color: card.accentInk; font.pixelSize: 24 * card.u }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.transport("play") }
        }
        Column {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; spacing: 1 * card.u
            Label { width: parent.width; text: card.title; font.pixelSize: 13 * card.u; font.weight: Font.DemiBold }
            Label { width: parent.width; text: card.artist; color: card.secondary; font.pixelSize: 11 * card.u }
        }
    }
    // medium: cover beside the title, the sound under it, the controls under that
    RowLayout {
        visible: card.kind === "media" && !card.controlsOnly && card.cls === "m"
        anchors.fill: parent; anchors.margins: card.pad
        spacing: card.pad
        Art { Layout.preferredHeight: parent.height; Layout.preferredWidth: parent.height }
        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 2 * card.u
            Header { icon: "graphic_eq"; text: card.player ? (card.player.identity || "Now playing") : "Music" }
            Label { Layout.fillWidth: true; Layout.topMargin: 4 * card.u; text: card.title; font.pixelSize: 16 * card.u; font.weight: Font.DemiBold }
            Label { Layout.fillWidth: true; text: card.artist; color: card.secondary; font.pixelSize: 12 * card.u }
            Item { Layout.fillHeight: true }
            Seek { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                Label { text: card.timeText(card.playPosition); color: card.secondary; font.pixelSize: 10 * card.u; font.features: { "tnum": 1 } }
                Item { Layout.fillWidth: true }
                Transport { k: card.u * .68 }
                Item { Layout.fillWidth: true }
                Label { text: card.timeText(card.player ? card.player.length : 0); color: card.secondary; font.pixelSize: 10 * card.u; font.features: { "tnum": 1 } }
            }
        }
    }
    // large: the cover, big, with the sound rising off its edge
    ColumnLayout {
        visible: card.kind === "media" && !card.controlsOnly && card.cls === "l"
        anchors.fill: parent; anchors.margins: card.pad
        spacing: 8 * card.u
        Header { icon: "graphic_eq"; text: card.player ? (card.player.identity || "Now playing") : "Music" }
        Art { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: Math.min(parent.width, 170 * card.u); Layout.preferredHeight: Layout.preferredWidth }
        Bars { Layout.fillWidth: true; Layout.preferredHeight: 18 * card.u; count: 32 }
        Label { Layout.fillWidth: true; text: card.title; font.pixelSize: 17 * card.u; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
        Label { Layout.fillWidth: true; text: card.artist; color: card.secondary; font.pixelSize: 12 * card.u; horizontalAlignment: Text.AlignHCenter }
        Seek { Layout.fillWidth: true }
        Transport { Layout.alignment: Qt.AlignHCenter; k: card.u }
        Item { Layout.fillHeight: true }
    }

    // =====================================================================================
    // CALENDAR
    // =====================================================================================
    // Small: today as a page, the weekday in the accent and the date large, with the next
    // thing under it. Medium: the page beside what is coming up. Large: the month, then the list.
    readonly property var events: ((card.readings || {}).calEvents || [])
    function dayKey(d) { return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0") }
    function evWhen(e) {
        var p = ("" + e.date).split("-"), d = new Date(+p[0], (+p[1] || 1) - 1, +p[2] || 1);
        var t = new Date(card.now.getFullYear(), card.now.getMonth(), card.now.getDate());
        var days = Math.round((d - t) / 86400000);
        var when = days <= 0 ? "Today" : days === 1 ? "Tomorrow" : days < 7 ? Qt.formatDate(d, "dddd") : Qt.formatDate(d, "d MMM");
        return when + (e.time ? " · " + e.time : "");
    }
    readonly property var monthCells: {
        var y = card.now.getFullYear(), m = card.now.getMonth(), lead = new Date(y, m, 1).getDay();
        var n = new Date(y, m + 1, 0).getDate(), out = [], busy = {};
        for (var i = 0; i < card.events.length; i++) busy["" + card.events[i].date] = true;
        for (var j = 0; j < lead; j++) out.push({ d: 0 });
        for (var k = 1; k <= n; k++) out.push({ d: k, ev: !!busy[card.dayKey(new Date(y, m, k))] });
        return out;
    }
    Item {
        visible: card.kind === "calendar"
        anchors.fill: parent; anchors.margins: card.pad
        // today, as a page
        Column {
            id: calPage
            width: card.cls === "s" ? parent.width : 112 * card.u
            spacing: 0
            Label { text: Qt.formatDate(card.now, "dddd").toUpperCase(); color: card.accent
                font.pixelSize: 11 * card.u; font.weight: Font.DemiBold; font.letterSpacing: 1 * card.u }
            Label { text: card.now.getDate(); font.pixelSize: (card.cls === "l" ? 46 : 52) * card.u; font.weight: Font.DemiBold
                font.features: { "tnum": 1 }; topPadding: -2 * card.u; bottomPadding: -4 * card.u }
            Label { text: Qt.formatDate(card.now, "MMMM"); color: card.secondary; font.pixelSize: 12 * card.u }
        }
        // small: the one next thing, at the foot of the page
        Column {
            visible: card.cls === "s"
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            spacing: 1 * card.u
            Label { width: parent.width; text: card.events.length ? card.events[0].title : "No events"
                font.pixelSize: 12 * card.u; font.weight: Font.DemiBold; color: card.events.length ? card.ink : card.secondary }
            Label { visible: card.events.length > 0; width: parent.width; text: card.events.length ? card.evWhen(card.events[0]) : ""
                color: card.secondary; font.pixelSize: 10 * card.u }
        }
        // large: the month, right of the page
        Grid {
            id: calMonth
            visible: card.cls === "l"
            anchors.right: parent.right; anchors.top: parent.top
            width: parent.width - calPage.width - 14 * card.u
            columns: 7; rowSpacing: 1 * card.u; columnSpacing: 0
            Repeater {
                model: card.cls === "l" ? ["S", "M", "T", "W", "T", "F", "S"].concat(card.monthCells) : []
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property bool head: index < 7
                    readonly property bool today: !head && modelData.d === card.now.getDate()
                    width: parent.width / 7; height: 19 * card.u
                    Rectangle { anchors.centerIn: parent; width: 18 * card.u; height: width; radius: width / 2
                        visible: today; color: card.accent }
                    Label { anchors.centerIn: parent; text: head ? modelData : (modelData.d || "")
                        color: head ? card.secondary : today ? card.accentInk : card.ink
                        font.pixelSize: (head ? 9 : 10) * card.u; font.weight: head || today ? Font.DemiBold : Font.Normal }
                    Rectangle { visible: !head && !!modelData.ev && !today; anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom; width: 3 * card.u; height: width; radius: width / 2; color: card.accent }
                }
            }
        }
        // medium and large: what is coming up
        Column {
            visible: card.cls !== "s"
            anchors.left: card.cls === "m" ? calPage.right : parent.left; anchors.leftMargin: card.cls === "m" ? 14 * card.u : 0
            anchors.right: parent.right
            // large: under whichever of the page and the month reaches lower
            y: card.cls === "m" ? 2 * card.u : Math.max(calPage.height, calMonth.height) + 18 * card.u
            spacing: 7 * card.u
            Label { visible: card.events.length === 0; text: "Nothing coming up"; color: card.secondary; font.pixelSize: 12 * card.u }
            Repeater {
                model: card.events.slice(0, card.cls === "l" ? 5 : 3)
                delegate: Row {
                    required property int index
                    readonly property var modelData: card.batItems[index] || { p: 0, i: "", n: "" }
                    width: parent.width; spacing: 8 * card.u
                    Rectangle { width: 3 * card.u; height: 30 * card.u; radius: width / 2; color: card.accent }
                    Column {
                        width: parent.width - 11 * card.u; spacing: 1 * card.u
                        Label { width: parent.width; text: modelData.title || "Event"; font.pixelSize: 12 * card.u; font.weight: Font.DemiBold }
                        Label { width: parent.width; text: card.evWhen(modelData); color: card.secondary; font.pixelSize: 10 * card.u }
                    }
                }
            }
        }
    }

    // =====================================================================================
    // BATTERIES
    // =====================================================================================
    // As macOS's Batteries widget: this computer and every connected Bluetooth device that
    // reports a level. Small: one ring. Medium: a ring each. Large: a list with time left.
    // from the shell (readings.batteries / batEta): this file stays plain QtQuick
    readonly property var batItems: ((card.readings || {}).batteries || [])
    readonly property color batTrack: Qt.rgba(card.secondary.r, card.secondary.g, card.secondary.b, 0.22)
    function batTone(b) { return b.c ? "#4caf50" : b.p <= 15 ? "#e5484d" : card.accent }
    function batEta() { return (card.readings || {}).batEta || "" }
    Item {
        visible: card.kind === "battery"
        anchors.fill: parent; anchors.margins: card.pad
        Label { visible: card.batItems.length === 0; anchors.centerIn: parent; text: "No batteries"; color: card.secondary; font.pixelSize: 12 * card.u }
        // small: the first one, large and alone
        Column {
            visible: card.cls === "s" && card.batItems.length > 0
            anchors.centerIn: parent; spacing: 8 * card.u
            BatteryRing { anchors.horizontalCenter: parent.horizontalCenter; width: 92 * card.u; height: width; stroke: 8 * card.u; ink: card.ink; track: card.batTrack
                value: card.batItems.length ? card.batItems[0].p : 0; icon: card.batItems.length ? card.batItems[0].i : ""
                tint: card.batItems.length ? card.batTone(card.batItems[0]) : card.accent }
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: card.batItems.length ? Math.round(card.batItems[0].p) + "%" : ""
                font.pixelSize: 15 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
        }
        // medium: a ring each, as many as fit
        Row {
            visible: card.cls === "m" && card.batItems.length > 0
            anchors.centerIn: parent; spacing: 16 * card.u
            Repeater {
                // a count, not a slice: batItems is rebuilt on every reading, see the system gauges
                model: card.cls === "m" ? Math.min(card.batItems.length, 4) : 0
                delegate: Column {
                    required property int index
                    readonly property var modelData: card.batItems[index] || { p: 0, i: "", n: "" }
                    spacing: 8 * card.u
                    BatteryRing { anchors.horizontalCenter: parent.horizontalCenter; width: 62 * card.u; height: width; stroke: 5 * card.u; ink: card.ink; track: card.batTrack
                        value: modelData.p; icon: modelData.i; tint: card.batTone(modelData) }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(modelData.p) + "%"
                        font.pixelSize: 13 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                }
            }
        }
        // large: a list, with how long this computer has left
        Column {
            visible: card.cls === "l" && card.batItems.length > 0
            anchors.fill: parent; spacing: 12 * card.u
            Header { icon: "battery_full"; text: "Batteries" }
            Label { visible: text !== ""; text: card.batEta(); color: card.secondary; font.pixelSize: 12 * card.u }
            Repeater {
                // a count, not a slice: batItems is rebuilt on every reading, see the system gauges
                model: card.cls === "l" ? Math.min(card.batItems.length, 5) : 0
                delegate: Row {
                    required property int index
                    readonly property var modelData: card.batItems[index] || { p: 0, i: "", n: "" }
                    width: parent.width; spacing: 12 * card.u
                    BatteryRing { width: 40 * card.u; height: width; stroke: 4 * card.u; ink: card.ink; track: card.batTrack; value: modelData.p; icon: modelData.i; tint: card.batTone(modelData) }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 52 * card.u; spacing: 5 * card.u
                        Item {
                            width: parent.width; height: 16 * card.u
                            Label { anchors.left: parent.left; width: parent.width - 50 * card.u; text: modelData.n; font.pixelSize: 12 * card.u }
                            Label { anchors.right: parent.right; text: Math.round(modelData.p) + "%"
                                color: card.secondary; font.pixelSize: 12 * card.u; font.features: { "tnum": 1 } }
                        }
                        Rectangle { width: parent.width; height: 5 * card.u; radius: height / 2
                            color: Qt.rgba(card.secondary.r, card.secondary.g, card.secondary.b, 0.22)
                            Rectangle { width: parent.width * Math.max(0.02, modelData.p / 100); height: parent.height; radius: parent.radius; color: card.batTone(modelData) } }
                    }
                }
            }
        }
    }
}
