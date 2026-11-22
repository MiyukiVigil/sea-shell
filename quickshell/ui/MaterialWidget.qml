// sea-shell — one widget: clock, weather, system, media, calendar, batteries, network,
// notifications, a quote, a photo, AI usage, GitHub, pomodoro, clipboard, or tide pool.
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
import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Shapes
import Qt.labs.folderlistmodel

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
    // photo: the folder it shows (DesktopItem resolves the widget's `src` to a path)
    property string photoDir: ""
    // ...or a ready list of pictures [{ u, cap }] (the wallpapers, as stills: see WallStills.qml)
    property var photoList: []
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
    property color warn: "#8f6300"
    property color crit: "#ad2020"
    property color ok: "#1b7a4b"
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
    readonly property color base: (kind === "weather" || kind === "ai" || (kind === "clock" && cls === "s")) ? container : surface
    color: controlsOnly || bare || kind === "photo" ? "transparent" : Qt.rgba(base.r, base.g, base.b, fill)
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
    // Shapes, not a Canvas: a Canvas holds a raster copy of itself, and the first one in the
    // shell pulls in the whole 2D context machinery and its threads. Each Shape sits in a plain
    // Item: a Shape's implicit size follows its paths, so a layout sizing it from that would
    // move the hands, which resize the Shape, which moves the hands.
    component Dial: Item {
        id: dial
        property bool numerals: false
        property bool seconds: true
        readonly property real r: width * .47
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property bool cookie: card.face === "cookie"
        readonly property int sec: card.now.getSeconds()
        readonly property real minute: card.now.getMinutes() + sec / 60
        readonly property real hour: (card.now.getHours() % 12) + minute / 60
        readonly property point hourEnd: at(hour * 30, .44)
        readonly property point minuteEnd: at(minute * 6, .64)
        readonly property point secondEnd: at(sec * 6, .70)
        readonly property point secondDot: at(sec * 6, .80)
        readonly property bool showSeconds: seconds && !card.reducedMotion
        readonly property color tickInk: Qt.rgba(card.accentInk.r, card.accentInk.g, card.accentInk.b, .55)
        readonly property var outline: {
            var out = [], lobes = cookie ? 7 : 12, depth = cookie ? .09 : .06;
            for (var i = 0; i <= 360; i += 2) {
                var a = i * Math.PI / 180, rr = r * (1 - depth + depth * Math.cos(a * lobes));
                out.push(Qt.point(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr));
            }
            return out;
        }
        function at(deg, len) {
            var a = deg * Math.PI / 180;
            return Qt.point(cx + Math.sin(a) * r * len, cy - Math.cos(a) * r * len);
        }
        function ticks(major) {
            var out = [];
            for (var k = 0; k < 12; k++)
                if ((k % 3 === 0) === major) out.push([at(k * 30, .70), at(k * 30, major ? .80 : .77)]);
            return out;
        }
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath { fillColor: card.accent; strokeWidth: -1; PathPolyline { path: dial.outline } }
            ShapePath {
                strokeColor: dial.tickInk; strokeWidth: Math.max(1, dial.r * .045); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                PathMultiline { paths: dial.ticks(true) }
            }
            ShapePath {
                strokeColor: dial.tickInk; strokeWidth: Math.max(1, dial.r * .022); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                PathMultiline { paths: dial.ticks(false) }
            }
            ShapePath {
                strokeColor: card.accentInk; strokeWidth: Math.max(3, dial.r * .085); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                startX: dial.cx; startY: dial.cy
                PathLine { x: dial.hourEnd.x; y: dial.hourEnd.y }
            }
            ShapePath {
                strokeColor: card.accentInk; strokeWidth: Math.max(2, dial.r * .055); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                startX: dial.cx; startY: dial.cy
                PathLine { x: dial.minuteEnd.x; y: dial.minuteEnd.y }
            }
            ShapePath {
                strokeColor: dial.showSeconds && !dial.cookie ? card.container : "transparent"
                strokeWidth: Math.max(1, dial.r * .02); fillColor: "transparent"; capStyle: ShapePath.RoundCap
                startX: dial.cx; startY: dial.cy
                PathLine { x: dial.secondEnd.x; y: dial.secondEnd.y }
            }
            ShapePath {
                fillColor: dial.showSeconds && dial.cookie ? card.container : "transparent"; strokeWidth: -1
                PathAngleArc { centerX: dial.secondDot.x; centerY: dial.secondDot.y
                    radiusX: dial.r * .055; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
            }
            ShapePath {
                fillColor: card.accentInk; strokeWidth: -1
                PathAngleArc { centerX: dial.cx; centerY: dial.cy; radiusX: dial.r * .07; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
            }
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
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "clock" && card.cls === "s"
        sourceComponent: Component {
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
        }
    }
    // medium: the time to read, the face to glance at
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "clock" && card.cls === "m"
        sourceComponent: Component {
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
        }
    }
    // large: the day, and the month around it
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "clock" && card.cls === "l"
        sourceComponent: Component {
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
                        model: !parent.visible ? 0 : month.cells
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
        }
    }

    // =====================================================================================
    // WEATHER
    // =====================================================================================
    readonly property var wx: card.readings || ({})
    readonly property var forecast: (card.wx.wxForecast || []).slice(0, card.cls === "s" ? 0 : 3)
    readonly property var today: (card.wx.wxForecast && card.wx.wxForecast.length) ? card.wx.wxForecast[0] : null
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "weather"
        sourceComponent: Component {
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
                                model: !parent.visible ? 0 : card.forecast
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
                            model: !parent.visible ? 0 : [{ i: "thermostat", l: "Feels like", v: card.wx.wxFeels }, { i: "humidity_percentage", l: "Humidity", v: card.wx.wxHumid },
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
    component Gauge: Item {
        id: g
        property real amount: 0
        property real thickness: 8
        // what is drawn: eases toward amount so a new reading sweeps rather than jumps
        property real shown: amount
        Behavior on shown { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        property color tone: amount >= 85 ? "#e5534b" : amount >= 65 ? "#d9a440" : card.accent
        readonly property real r: Math.max(0, width / 2 - thickness / 2 - 1)
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: g.r > 0
            ShapePath {
                strokeColor: card.container; strokeWidth: g.thickness; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                PathAngleArc { centerX: g.width / 2; centerY: g.height / 2; radiusX: g.r; radiusY: g.r; startAngle: 135; sweepAngle: 270 }
            }
            ShapePath {
                strokeColor: g.shown > 0.5 ? g.tone : "transparent"; strokeWidth: g.thickness; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                PathAngleArc { centerX: g.width / 2; centerY: g.height / 2; radiusX: g.r; radiusY: g.r; startAngle: 135
                    sweepAngle: 270 * Math.max(0, Math.min(100, g.shown)) / 100 }
            }
        }
    }
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "system"
        sourceComponent: Component {
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
                            model: !parent.visible ? 0 : card.gauges.length
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
                        model: !parent.visible ? 0 : card.cls === "l" ? card.details : []
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
        Image { id: art; anchors.fill: parent; source: parent.visible && card.active ? card.artUrl : ""; fillMode: Image.PreserveAspectCrop
            asynchronous: true; sourceSize.width: 384; sourceSize.height: 384; visible: status === Image.Ready }
        Symbol { anchors.centerIn: parent; visible: art.status !== Image.Ready; text: "music_note"; font.pixelSize: parent.width * .4 }
    }
    // the sound, as the bar draws it: one source, so they never disagree
    component Bars: Row {
        id: bars
        property int count: 24
        spacing: 2 * card.u
        Repeater {
            model: !parent.visible ? 0 : bars.count
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
            model: !parent.visible ? 0 : [{ s: "skip_previous", a: "previous" }, { s: card.playing ? "pause" : "play_arrow", a: "play" }, { s: "skip_next", a: "next" }]
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
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "media" && !card.controlsOnly && card.cls === "s"
        sourceComponent: Component {
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
        }
    }
    // medium: cover beside the title, the sound under it, the controls under that
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "media" && !card.controlsOnly && card.cls === "m"
        sourceComponent: Component {
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
        }
    }
    // large: the cover, big, with the sound rising off its edge
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "media" && !card.controlsOnly && card.cls === "l"
        sourceComponent: Component {
            ColumnLayout {
                visible: card.kind === "media" && !card.controlsOnly && card.cls === "l"
                anchors.fill: parent; anchors.margins: card.pad
                spacing: 8 * card.u
                Header { icon: "graphic_eq"; text: card.player ? (card.player.identity || "Now playing") : "Music" }
                // Stage face: art dominates; transport stays under it (Now Playing).
                Art {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.min(parent.width, (card.face === "stage" ? 220 : 170) * card.u)
                    Layout.preferredHeight: Layout.preferredWidth
                }
                Bars { Layout.fillWidth: true; Layout.preferredHeight: (card.face === "stage" ? 22 : 18) * card.u; count: card.face === "stage" ? 40 : 32 }
                Label { Layout.fillWidth: true; text: card.title; font.pixelSize: (card.face === "stage" ? 20 : 17) * card.u; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
                Label { Layout.fillWidth: true; text: card.artist; color: card.secondary; font.pixelSize: (card.face === "stage" ? 13 : 12) * card.u; horizontalAlignment: Text.AlignHCenter }
                Seek { Layout.fillWidth: true; visible: card.face !== "stage" ? true : true }
                Transport { Layout.alignment: Qt.AlignHCenter; k: card.u }
                Item { Layout.fillHeight: true }
            }
        }
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
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "calendar"
        sourceComponent: Component {
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
                        model: !parent.visible ? 0 : card.cls === "l" ? ["S", "M", "T", "W", "T", "F", "S"].concat(card.monthCells) : []
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
                        model: !parent.visible ? 0 : Math.min(card.events.length, card.cls === "l" ? 5 : 3)
                        delegate: Row {
                            required property int index
                            readonly property var modelData: card.events[index] || ({})
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
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "battery"
        sourceComponent: Component {
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
                        model: !parent.visible ? 0 : card.cls === "m" ? Math.min(card.batItems.length, 4) : 0
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
                        model: !parent.visible ? 0 : card.cls === "l" ? Math.min(card.batItems.length, 5) : 0
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
    }

    // =====================================================================================
    // NETWORK
    // =====================================================================================
    // Small: the Wi-Fi glyph at its strength, the network, and the two rates. Medium: the
    // same beside a minute of traffic. Large: adds each interface. History is kept here, from
    // the readings the shell already takes every two seconds, only while the widget is seen.
    readonly property var rd: card.readings || ({})
    property var netHist: []
    Timer {
        interval: 2000; repeat: true; triggeredOnStart: true
        running: card.active && card.visible && card.kind === "network"
        onTriggered: card.netHist = card.netHist.concat([(card.rd.netRx || 0) + (card.rd.netTx || 0)]).slice(-30)
    }
    function perSec(b) {
        b = Number(b) || 0;
        return b >= 1048576 ? (b / 1048576).toFixed(b >= 10485760 ? 0 : 1) + " MB/s"
             : b >= 1024 ? Math.round(b / 1024) + " KB/s" : Math.round(b) + " B/s";
    }
    readonly property bool netUp: !!card.rd.wifiOn || (card.rd.netIf || []).length > 0
    readonly property string netName: card.rd.wifiOn ? (card.rd.ssid || "Wi-Fi")
        : (card.rd.netIf || []).length ? "Wired" : "Offline"
    readonly property string netGlyph: !card.rd.wifiOn ? ((card.rd.netIf || []).length ? "lan" : "wifi_off")
        : (card.rd.wifiSig || 0) >= 67 ? "wifi" : (card.rd.wifiSig || 0) >= 34 ? "wifi_2_bar" : "wifi_1_bar"
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "network"
        sourceComponent: Component {
            Item {
                visible: card.kind === "network"
                anchors.fill: parent; anchors.margins: card.pad
                // the network and its glyph: the whole small widget, the left of the medium one
                Column {
                    id: netId
                    width: card.cls === "s" ? parent.width : 128 * card.u
                    spacing: 4 * card.u
                    Rectangle {
                        width: 38 * card.u; height: width; radius: width / 2
                        color: card.netUp ? card.accent : Qt.rgba(card.secondary.r, card.secondary.g, card.secondary.b, 0.18)
                        Symbol { anchors.centerIn: parent; text: card.netGlyph; font.pixelSize: 21 * card.u
                            color: card.netUp ? card.accentInk : card.secondary }
                    }
                    Item { width: 1; height: 4 * card.u }
                    Label { width: parent.width; text: card.netName; font.pixelSize: 15 * card.u; font.weight: Font.DemiBold }
                    Label { width: parent.width; color: card.secondary; font.pixelSize: 11 * card.u
                        text: card.rd.wifiOn ? "Signal " + (card.rd.wifiSig || 0) + "%" : card.netUp ? "Connected" : "Not connected" }
                }
                Column {
                    visible: card.cls === "s"
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    spacing: 2 * card.u
                    Repeater {
                        model: !parent.visible ? 0 : [{ g: "arrow_downward", v: card.rd.netRx || 0 }, { g: "arrow_upward", v: card.rd.netTx || 0 }]
                        delegate: Row {
                            required property var modelData
                            spacing: 4 * card.u
                            Symbol { text: modelData.g; font.pixelSize: 14 * card.u; color: card.secondary; anchors.verticalCenter: parent.verticalCenter }
                            Label { text: card.perSec(modelData.v); font.pixelSize: 12 * card.u; font.features: { "tnum": 1 }; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                // medium and large: a minute of traffic, and the rates under it
                Item {
                    visible: card.cls !== "s"
                    anchors.left: netId.right; anchors.leftMargin: 14 * card.u; anchors.right: parent.right
                    height: card.cls === "m" ? parent.height : parent.height - 118 * card.u
                    WidgetTrace { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        height: parent.height - 26 * card.u; points: card.netHist; tone: card.accent; lineWidth: 2 * card.u }
                    Row {
                        anchors.bottom: parent.bottom; anchors.right: parent.right
                        spacing: 12 * card.u
                        Repeater {
                            model: !parent.visible ? 0 : [{ g: "arrow_downward", v: card.rd.netRx || 0 }, { g: "arrow_upward", v: card.rd.netTx || 0 }]
                            delegate: Row {
                                required property var modelData
                                spacing: 4 * card.u
                                Symbol { text: modelData.g; font.pixelSize: 14 * card.u; color: card.secondary; anchors.verticalCenter: parent.verticalCenter }
                                Label { text: card.perSec(modelData.v); font.pixelSize: 12 * card.u; font.features: { "tnum": 1 }; anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                    }
                }
                // large: each interface with its share
                Column {
                    visible: card.cls === "l"
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    spacing: 8 * card.u
                    Header { icon: "router"; text: "Interfaces" }
                    Repeater {
                        model: !parent.visible ? 0 : card.cls === "l" ? Math.min((card.rd.netIf || []).length, 4) : 0
                        delegate: Item {
                            required property int index
                            readonly property var row: (card.rd.netIf || [])[index] || ({ name: "", rx: 0, tx: 0 })
                            width: parent.width; height: 20 * card.u
                            Label { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: row.name; font.pixelSize: 12 * card.u }
                            Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; color: card.secondary
                                text: "↓ " + card.perSec(row.rx) + "   ↑ " + card.perSec(row.tx); font.pixelSize: 11 * card.u; font.features: { "tnum": 1 } }
                        }
                    }
                    Label { visible: (card.rd.netIf || []).length === 0; text: "No active interfaces"; color: card.secondary; font.pixelSize: 12 * card.u }
                }
            }
        }
    }

    // =====================================================================================
    // NOTIFICATIONS
    // =====================================================================================
    // Small: how many are waiting, or "all caught up". Medium: the newest two. Large: five.
    // Each app gets a round initial in a colour of its own, turned off the accent's hue, so
    // the list reads at a glance without loading app icons in a plain-QtQuick file.
    readonly property var noteList: card.rd.notes || []
    function noteTint(app) {
        var h = 0; app = "" + (app || "");
        for (var i = 0; i < app.length; i++) h = (h * 31 + app.charCodeAt(i)) % 360;
        var a = card.accent;
        return Qt.hsla(((a.hslHue < 0 ? 0.6 : a.hslHue) + h / 360) % 1, Math.max(0.35, a.hslSaturation), 0.55, 1);
    }
    function ago(ts) {
        if (!ts) return "";
        var m = Math.round((card.now.getTime() - ts) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : m < 1440 ? Math.round(m / 60) + "h" : Math.round(m / 1440) + "d";
    }
    Timer { interval: 60000; repeat: true; running: card.active && card.visible && (card.kind === "notifications" || card.kind === "quote")
        onTriggered: card.now = new Date() }
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "notifications"
        sourceComponent: Component {
            Item {
                visible: card.kind === "notifications"
                anchors.fill: parent; anchors.margins: card.pad
                Header { id: noteHead; icon: card.rd.dnd ? "do_not_disturb_on" : "notifications"
                    text: card.rd.dnd ? "Do not disturb" : "Notifications" }
                // small: the count
                Column {
                    visible: card.cls === "s"
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    spacing: 0
                    Label { text: card.rd.noteCount || 0; font.pixelSize: 46 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                        visible: (card.rd.noteCount || 0) > 0; bottomPadding: -4 * card.u }
                    Label { text: (card.rd.noteCount || 0) > 0 ? ((card.rd.noteCount === 1 ? "notification" : "notifications")) : "All caught up"
                        color: (card.rd.noteCount || 0) > 0 ? card.secondary : card.ink
                        font.pixelSize: ((card.rd.noteCount || 0) > 0 ? 12 : 15) * card.u; font.weight: (card.rd.noteCount || 0) > 0 ? Font.Normal : Font.DemiBold }
                    Label { visible: (card.rd.noteCount || 0) > 0 && card.noteList.length > 0; width: card.width - card.pad * 2
                        text: card.noteList.length ? "Latest: " + (card.noteList[0].appName || "") : ""; color: card.secondary; font.pixelSize: 10 * card.u }
                }
                // medium and large: the newest few
                Column {
                    visible: card.cls !== "s"
                    anchors.top: noteHead.bottom; anchors.topMargin: 10 * card.u
                    anchors.left: parent.left; anchors.right: parent.right
                    spacing: 9 * card.u
                    Repeater {
                        model: !parent.visible ? 0 : card.cls === "s" ? 0 : Math.min(card.noteList.length, card.cls === "l" ? 5 : 2)
                        delegate: Row {
                            id: nr
                            required property int index
                            readonly property var n: card.noteList[index] || ({})
                            width: parent.width
                            spacing: 10 * card.u
                            Rectangle {
                                width: 30 * card.u; height: width; radius: width / 2; color: card.noteTint(nr.n.appName)
                                Label { anchors.centerIn: parent; text: ("" + (nr.n.appName || "?")).charAt(0).toUpperCase()
                                    color: "white"; font.pixelSize: 13 * card.u; font.weight: Font.DemiBold }
                            }
                            Column {
                                width: nr.width - 40 * card.u; spacing: 1 * card.u
                                anchors.verticalCenter: parent.verticalCenter
                                Item {
                                    width: parent.width; height: 16 * card.u
                                    Label { anchors.left: parent.left; width: parent.width - 34 * card.u; font.pixelSize: 12 * card.u; font.weight: Font.DemiBold
                                        text: nr.n.summary || nr.n.appName || "" }
                                    Label { anchors.right: parent.right; color: card.secondary; font.pixelSize: 10 * card.u; text: card.ago(nr.n.ts) }
                                }
                                Label { width: parent.width; color: card.secondary; font.pixelSize: 11 * card.u; visible: text !== ""
                                    text: ("" + (nr.n.body || "")).replace(/<[^>]*>/g, "").replace(/\s+/g, " ") }
                            }
                        }
                    }
                }
                Column {
                    visible: card.cls !== "s" && card.noteList.length === 0
                    anchors.centerIn: parent; anchors.verticalCenterOffset: 8 * card.u
                    spacing: 4 * card.u
                    Symbol { anchors.horizontalCenter: parent.horizontalCenter; text: "done_all"; font.pixelSize: 26 * card.u; color: card.secondary }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: "All caught up"; color: card.secondary; font.pixelSize: 12 * card.u }
                }
            }
        }
    }

    // =====================================================================================
    // QUOTE
    // =====================================================================================
    // One a day, from writers long out of copyright, picked by the date so every widget and
    // every screen agrees; a click moves on to the next one.
    readonly property var quotes: [
        ["The obstacle is the way.", "Marcus Aurelius"],
        ["Luck is what happens when preparation meets opportunity.", "Seneca"],
        ["It is not that we have a short time to live, but that we waste a lot of it.", "Seneca"],
        ["We suffer more often in imagination than in reality.", "Seneca"],
        ["Waste no more time arguing what a good man should be. Be one.", "Marcus Aurelius"],
        ["The happiness of your life depends upon the quality of your thoughts.", "Marcus Aurelius"],
        ["First say to yourself what you would be; and then do what you have to do.", "Epictetus"],
        ["No man is free who is not master of himself.", "Epictetus"],
        ["A journey of a thousand miles begins with a single step.", "Lao Tzu"],
        ["Nature does not hurry, yet everything is accomplished.", "Lao Tzu"],
        ["It does not matter how slowly you go as long as you do not stop.", "Confucius"],
        ["Simplify, simplify.", "Henry David Thoreau"],
        ["Go confidently in the direction of your dreams.", "Henry David Thoreau"],
        ["Do not go where the path may lead; go instead where there is no path and leave a trail.", "Ralph Waldo Emerson"],
        ["Adopt the pace of nature: her secret is patience.", "Ralph Waldo Emerson"],
        ["The secret of getting ahead is getting started.", "Mark Twain"],
        ["Well done is better than well said.", "Benjamin Franklin"],
        ["Lost time is never found again.", "Benjamin Franklin"],
        ["Energy and persistence conquer all things.", "Benjamin Franklin"],
        ["I am not afraid of storms, for I am learning how to sail my ship.", "Louisa May Alcott"],
        ["What we think, we become.", "The Buddha"],
        ["Knowing yourself is the beginning of all wisdom.", "Aristotle"],
        ["Quality is not an act, it is a habit.", "Aristotle"],
        ["The unexamined life is not worth living.", "Socrates"],
        ["Well begun is half done.", "Aristotle"],
        ["Patience is bitter, but its fruit is sweet.", "Jean-Jacques Rousseau"],
        ["Life is really simple, but we insist on making it complicated.", "Confucius"],
        ["The best way out is always through.", "Robert Frost"],
        ["In the middle of difficulty lies opportunity.", "Albert Einstein"],
        ["Little by little, one travels far.", "J. R. R. Tolkien"],
        ["Not all those who wander are lost.", "J. R. R. Tolkien"],
        ["Do what you can, with what you have, where you are.", "Theodore Roosevelt"]
    ]
    property int quoteShift: 0
    readonly property int quoteIx: {
        var d = card.now, start = new Date(d.getFullYear(), 0, 0);
        return (Math.floor((d - start) / 86400000) + card.quoteShift) % card.quotes.length;
    }
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "quote"
        sourceComponent: Component {
            Item {
                visible: card.kind === "quote"
                anchors.fill: parent; anchors.margins: card.pad
                Label { id: qMark; text: "\u201C"; font.family: "serif"; font.weight: Font.Bold; color: card.accent
                    font.pixelSize: (card.cls === "l" ? 72 : 52) * card.u; height: font.pixelSize * 0.48; verticalAlignment: Text.AlignTop
                    topPadding: -font.pixelSize * 0.12 }
                Label {
                    anchors.top: qMark.bottom; anchors.topMargin: (card.cls === "s" ? 4 : 8) * card.u
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.bottom: qBy.top; anchors.bottomMargin: 6 * card.u
                    text: card.quotes[card.quoteIx][0]
                    wrapMode: Text.WordWrap; elide: Text.ElideRight
                    verticalAlignment: Text.AlignTop
                    fontSizeMode: Text.Fit; minimumPixelSize: Math.round(10 * card.u)
                    font.pixelSize: (card.cls === "s" ? 15 : card.cls === "m" ? 19 : 26) * card.u
                    font.weight: Font.Medium; lineHeight: 1.12
                }
                Label {
                    id: qBy
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    text: "— " + card.quotes[card.quoteIx][1]
                    color: card.secondary; font.pixelSize: 11 * card.u
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.quoteShift++ }
            }
        }
    }

    // =====================================================================================
    // PHOTO
    // =====================================================================================
    // A picture from a folder, filling the tile, changing every fifteen minutes or on a click,
    // with the date it was taken (well, last changed) across the foot, as macOS's Photos.
    // Only a photo widget reading a folder has one: each FolderListModel keeps its own thread.
    Instantiator {
        id: photoModel
        active: card.kind === "photo" && !card.photoFromList
        delegate: FolderListModel {
            folder: card.photoDir !== "" ? "file://" + card.photoDir : ""
            nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.JPG", "*.JPEG", "*.PNG", "*.WEBP"]
            showDirs: false
            sortField: FolderListModel.Name
        }
    }
    readonly property var photos: photoModel.object
    property int photoIx: 0
    Timer {
        interval: 15 * 60 * 1000; repeat: true
        running: card.active && card.visible && card.kind === "photo" && card.photoCount > 1
        onTriggered: card.photoIx = (card.photoIx + 1) % Math.max(1, card.photoCount)
    }
    onKindChanged: if (kind === "photo") photoIx = Math.floor(Math.random() * 997)
    readonly property bool photoFromList: card.photoList.length > 0
    readonly property int photoCount: card.photoFromList ? card.photoList.length : (card.photos ? card.photos.count : 0)
    readonly property int photoAt: card.photoCount > 0 ? card.photoIx % card.photoCount : -1
    // Instantiate only the selected kind/size; keep it resident while hidden.
    Loader {
        anchors.fill: parent
        active: card.kind === "photo"
        sourceComponent: Component {
            Item {
                visible: card.kind === "photo"
                anchors.fill: parent
                Image {
                    id: photoImg
                    anchors.fill: parent
                    visible: false
                    source: card.photoAt < 0 ? "" : card.photoFromList ? card.photoList[card.photoAt].u : card.photos.get(card.photoAt, "fileUrl")
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; cache: false
                    sourceSize.width: Math.max(360, card.width * 1.5)
                }
                Rectangle { id: photoMask; anchors.fill: parent; radius: card.radius; visible: false; layer.enabled: true }
                MultiEffect {
                    anchors.fill: parent; source: photoImg
                    visible: photoImg.status === Image.Ready
                    maskEnabled: true; maskSource: photoMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1
                }
                // nothing to show: say where it is looking
                Rectangle {
                    anchors.fill: parent; radius: card.radius
                    visible: photoImg.status !== Image.Ready
                    color: Qt.rgba(card.surface.r, card.surface.g, card.surface.b, Math.max(0.6, card.fill))
                    Column {
                        anchors.centerIn: parent; spacing: 4 * card.u; width: parent.width - 2 * card.pad
                        Symbol { anchors.horizontalCenter: parent.horizontalCenter; text: "photo_library"; font.pixelSize: 28 * card.u; color: card.secondary }
                        Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; color: card.secondary; font.pixelSize: 11 * card.u
                            text: !card.photoFromList && !!card.photos && card.photos.status === FolderListModel.Ready && card.photos.count === 0
                                ? "No pictures in " + card.photoDir.replace(/^.*\//, "") : "Photos" }
                    }
                }
                // the foot: a soft shade so the date reads on any picture
                Rectangle {
                    visible: photoImg.status === Image.Ready
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 54 * card.u; radius: card.radius
                    gradient: Gradient {
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.45) }
                    }
                    Label {
                        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 12 * card.u
                        width: parent.width - 24 * card.u
                        color: "white"; font.pixelSize: 11 * card.u; font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        text: card.photoAt < 0 ? "" : card.photoFromList ? card.photoList[card.photoAt].cap
                            : Qt.formatDate(card.photos.get(card.photoAt, "fileModified"), "d MMMM yyyy")
                    }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: card.photoIx = (card.photoIx + 1) % Math.max(1, card.photoCount) }
            }
        }
    }

    // =====================================================================================
    // AI USAGE
    // =====================================================================================
    // Same family as the battery rings and the calendar page: one accent tile, a ring,
    // a figure. The marks are the selector. The ring is how much of this week's usage
    // landed today, so a quiet tool reads as an empty ring rather than a wall of text.
    Loader {
        anchors.fill: parent
        active: card.kind === "ai"
        sourceComponent: Component {
            Item {
                id: ai
                anchors.fill: parent
                anchors.margins: card.pad
                clip: true
                property string focusId: ""
                readonly property var usage: (card.readings && card.readings.aiUsage) ? card.readings.aiUsage : ({})
                function rowLive(id) {
                    if (id === "grok") id = "cursor";
                    var m = (card.readings && card.readings.aiLive) ? card.readings.aiLive : ({});
                    return !!m[id];
                }
                function pct(n) {
                    var d = Number((card.readings || {}).aiDigits);
                    if (d !== 0 && d !== 1 && d !== 2) d = 2;
                    var v = Number(n);
                    if (!isFinite(v)) v = 0;
                    return v.toFixed(d) + "%";
                }
                readonly property var tools: usage.tools || []
                readonly property var shown: {
                    var list = ai.tools;
                    for (var i = 0; i < list.length; i++)
                        if (list[i].id === ai.focusId || (ai.focusId === "grok" && list[i].with === "grok")) return list[i];
                    if (usage.lead) {
                        for (var j = 0; j < list.length; j++)
                            if (list[j].name === usage.lead.name) return list[j];
                    }
                    return list.length ? list[0] : null;
                }
                readonly property real weekShare: {
                    if (!shown) return 0;
                    var week = Number(shown.week) || 0;
                    var today = Number(shown.today) || 0;
                    if (week <= 0) return today > 0 ? 100 : 0;
                    return Math.max(0, Math.min(100, today / week * 100));
                }
                readonly property real peak: {
                    var m = 1;
                    for (var i = 0; i < tools.length; i++)
                        m = Math.max(m, Number(tools[i].today) || 0);
                    return m;
                }
                function pick(id) { ai.focusId = id }

                // small: the chosen tool, large, and a tap moves to the next one
                Column {
                    visible: card.cls === "s"
                    anchors.centerIn: parent
                    spacing: 6 * card.u
                    width: parent.width
                    Item {
                        id: smallDial
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 78 * card.u; height: width
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                strokeColor: Qt.rgba(card.secondary.r, card.secondary.g, card.secondary.b, 0.28)
                                strokeWidth: 7 * card.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                PathAngleArc { centerX: smallDial.width / 2; centerY: smallDial.height / 2
                                    radiusX: smallDial.width / 2 - 4 * card.u; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
                            }
                            ShapePath {
                                strokeColor: card.accent; strokeWidth: 7 * card.u
                                fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                PathAngleArc { centerX: smallDial.width / 2; centerY: smallDial.height / 2
                                    radiusX: smallDial.width / 2 - 4 * card.u; radiusY: radiusX
                                    startAngle: -90; sweepAngle: 3.6 * Math.max(ai.shown ? 2 : 0, ai.weekShare) }
                            }
                        }
                        AiMark {
                            anchors.centerIn: parent
                            width: (ai.shown && ai.shown.with ? 36 : 26) * card.u; height: 26 * card.u
                            tool: ai.shown ? ai.shown.id : "claude"
                            also: (ai.shown && ai.shown.with) ? ai.shown.with : ""
                            ink: card.ink
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!ai.tools.length) return;
                                var at = 0;
                                for (var i = 0; i < ai.tools.length; i++)
                                    if (ai.tools[i].id === (ai.shown ? ai.shown.id : "")) at = i;
                                ai.pick(ai.tools[(at + 1) % ai.tools.length].id);
                            }
                        }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: ai.shown ? (ai.shown.unit === "left" ? ai.pct(ai.shown.today) : ai.shown.todayLabel) : "0"
                        font.pixelSize: 26 * card.u
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        elide: Text.ElideRight
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        color: card.secondary
                        font.pixelSize: 11 * card.u
                        elide: Text.ElideRight
                        text: ai.shown
                            ? (ai.shown.unit === "left"
                                ? (ai.shown.name + (ai.shown.weekLabel ? (" · " + ai.shown.weekLabel) : " left"))
                                : (ai.shown.name + " · " + ai.shown.unit))
                            : "No usage yet"
                    }
                    Label {
                        visible: ai.shown && (ai.shown.pace || "").length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        color: card.secondary
                        font.pixelSize: 10 * card.u
                        wrapMode: Text.WordWrap
                        text: ai.shown ? (ai.shown.pace || "") : ""
                    }
                }

                // medium: the figure on the left, the plans spread down the rest of the card
                Item {
                    visible: card.cls === "m"
                    anchors.fill: parent
                    Column {
                        id: medFigure
                        anchors.verticalCenter: parent.verticalCenter
                        width: 118 * card.u
                        spacing: 2 * card.u
                        Item {
                            id: medDial
                            width: 64 * card.u; height: width
                            Shape {
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    strokeColor: Qt.rgba(card.secondary.r, card.secondary.g, card.secondary.b, 0.28)
                                    strokeWidth: 6 * card.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                    PathAngleArc { centerX: medDial.width / 2; centerY: medDial.height / 2
                                        radiusX: medDial.width / 2 - 3 * card.u; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
                                }
                                ShapePath {
                                    strokeColor: card.accent; strokeWidth: 6 * card.u
                                    fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                    PathAngleArc { centerX: medDial.width / 2; centerY: medDial.height / 2
                                        radiusX: medDial.width / 2 - 3 * card.u; radiusY: radiusX
                                        startAngle: -90; sweepAngle: 3.6 * Math.max(ai.shown ? 2 : 0, ai.weekShare) }
                                }
                            }
                            AiMark {
                                anchors.centerIn: parent
                                width: (ai.shown && ai.shown.with ? 32 : 22) * card.u; height: 22 * card.u
                                tool: ai.shown ? ai.shown.id : "claude"
                                also: (ai.shown && ai.shown.with) ? ai.shown.with : ""
                                ink: card.ink
                            }
                        }
                        Label {
                            width: parent.width
                            text: ai.shown ? (ai.shown.unit === "left" ? ai.pct(ai.shown.today) : ai.shown.todayLabel) : "0"
                            font.pixelSize: 28 * card.u
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            elide: Text.ElideRight
                        }
                        Label {
                            width: parent.width
                            color: card.secondary
                            font.pixelSize: 11 * card.u
                            elide: Text.ElideRight
                            text: ai.shown
                                ? (ai.shown.unit === "left"
                                    ? (ai.shown.weekLabel || (ai.shown.name + " left"))
                                    : (ai.shown.name + " today"))
                                : "No usage yet"
                        }
                        Label {
                            visible: ai.shown && (ai.shown.pace || "").length > 0
                            width: parent.width
                            color: card.secondary
                            font.pixelSize: 10 * card.u
                            wrapMode: Text.WordWrap
                            text: ai.shown ? (ai.shown.pace || "") : ""
                        }
                    }
                    Column {
                        id: medList
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.left: medFigure.right
                        anchors.leftMargin: 14 * card.u
                        anchors.right: parent.right
                        spacing: 0
                        Repeater {
                            model: Math.min(ai.tools.length, 4)
                            delegate: Item {
                                required property int index
                                readonly property var row: ai.tools[index] || ({})
                                readonly property bool on: ai.shown && row.id === ai.shown.id
                                width: medList.width
                                height: medList.height / Math.max(1, Math.min(ai.tools.length, 4))
                                Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                height: Math.min(32 * card.u, parent.height - 4 * card.u)
                                radius: height / 2
                                color: on ? card.surface : "transparent"
                                Item {
                                    anchors.fill: parent
                                    anchors.leftMargin: 4 * card.u
                                    anchors.rightMargin: 8 * card.u
                                    Rectangle {
                                        id: medMark
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: (row.with ? 26 : 20) * card.u; height: width; radius: width / 2
                                        color: on ? card.accent : Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.08)
                                        AiMark {
                                            anchors.centerIn: parent
                                            width: (row.with ? 16 : 12) * card.u; height: 12 * card.u
                                            tool: row.id || "claude"
                                            also: row.with || ""
                                            ink: on ? card.accentInk : card.ink
                                        }
                                    }
                                    Label {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: medMark.right
                                        anchors.leftMargin: 6 * card.u
                                        anchors.rightMargin: 6 * card.u
                                        text: (row.name || "")
                                        font.pixelSize: 12 * card.u
                                        font.weight: on ? Font.DemiBold : Font.Normal
                                        elide: Text.ElideRight
                                        anchors.right: liveDot.left
                                    }
                                    Rectangle {
                                        id: liveDot
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.right: medLeft.left
                                        anchors.rightMargin: ai.rowLive(row.id) ? 6 * card.u : 0
                                        width: ai.rowLive(row.id) ? 7 * card.u : 0
                                        height: width; radius: width / 2
                                        color: "#1b7a4b"
                                        border.width: ai.rowLive(row.id) ? 1 : 0
                                        border.color: "#ffffff"
                                        visible: ai.rowLive(row.id)
                                    }
                                    Label {
                                        id: medLeft
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.right: parent.right
                                        visible: row.unit === "left" && row.today !== undefined
                                        text: ai.pct(row.today)
                                        color: (Number(row.today) <= 5) ? card.crit
                                            : ((Number(row.today) <= 20) ? card.warn : card.secondary)
                                        font.pixelSize: 11 * card.u
                                        font.features: { "tnum": 1 }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ai.pick(row.id || "")
                                }
                            }
                        }
                    }

                // large: the marks across the top, then the figure and how the week compares
                Column {
                    visible: card.cls === "l"
                    anchors.fill: parent
                    spacing: 12 * card.u
                    Row {
                        width: parent.width
                        spacing: 8 * card.u
                        Repeater {
                            model: Math.min(ai.tools.length, 4)
                            delegate: Rectangle {
                                required property int index
                                readonly property var row: ai.tools[index] || ({})
                                readonly property bool on: ai.shown && row.id === ai.shown.id
                                width: (parent.width - Math.max(0, Math.min(ai.tools.length, 4) - 1) * 8 * card.u) / Math.max(1, Math.min(ai.tools.length, 4))
                                height: 64 * card.u
                                radius: 16 * card.u
                                color: on ? card.surface : Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.05)
                                border.width: on ? 1 : 0
                                border.color: Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.45)
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 4 * card.u
                                    AiMark {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: (row.with ? 28 : 18) * card.u; height: 18 * card.u
                                        tool: row.id || "claude"
                                        also: row.with || ""
                                        ink: card.ink
                                    }
                                    Label {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: parent.parent.width - 8 * card.u
                                        horizontalAlignment: Text.AlignHCenter
                                        text: row.name || ""
                                        font.pixelSize: 10 * card.u
                                        font.weight: on ? Font.DemiBold : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ai.pick(row.id || "")
                                }
                            }
                        }
                    }
                    Label {
                        text: ai.shown ? (ai.shown.unit === "left" ? ai.pct(ai.shown.today) : ai.shown.todayLabel) : "0"
                        font.pixelSize: 42 * card.u
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Label {
                        width: parent.width
                        color: card.secondary
                        font.pixelSize: 12 * card.u
                        elide: Text.ElideRight
                        text: ai.shown
                            ? (ai.shown.unit === "left"
                                ? (ai.shown.name + " · " + ai.pct(ai.shown.today) + " left"
                                    + (ai.shown.weekLabel ? (" · " + ai.shown.weekLabel) : "")
                                    + (ai.shown.detail ? (" · " + ai.shown.detail) : ""))
                                : (ai.shown.name + " · " + ai.shown.todayLabel + " " + ai.shown.unit + " today"))
                            : "No usage yet"
                    }
                    Label {
                        visible: ai.shown && (ai.shown.pace || "").length > 0
                        width: parent.width
                        color: card.secondary
                        font.pixelSize: 12 * card.u
                        wrapMode: Text.WordWrap
                        text: ai.shown ? (ai.shown.pace || "") : ""
                    }
                    Column {
                        width: parent.width
                        spacing: 8 * card.u
                        Repeater {
                            model: Math.min(ai.tools.length, 4)
                            delegate: Item {
                                required property int index
                                readonly property var row: ai.tools[index] || ({})
                                readonly property bool on: ai.shown && row.id === ai.shown.id
                                width: parent.width
                                height: 22 * card.u
                                AiMark {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: (row.with ? 24 : 14) * card.u; height: 14 * card.u
                                    tool: row.id || "claude"
                                    also: row.with || ""
                                    ink: card.ink
                                }
                                Label {
                                    anchors.left: parent.left
                                    anchors.leftMargin: (row.with ? 30 : 20) * card.u
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 64 * card.u
                                    text: row.name || ""
                                    font.pixelSize: 11 * card.u
                                    font.weight: on ? Font.DemiBold : Font.Normal
                                    elide: Text.ElideRight
                                }
                                Item {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 88 * card.u
                                    anchors.right: parent.right
                                    anchors.rightMargin: 52 * card.u
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 6 * card.u
                                    Rectangle {
                                        anchors.fill: parent; radius: height / 2
                                        color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.10)
                                    }
                                    Rectangle {
                                        width: parent.width * Math.max(0.04, Math.min(1,
                                            row.unit === "left"
                                                ? ((Number(row.today) || 0) / 100)
                                                : ((Number(row.today) || 0) / ai.peak)))
                                        height: parent.height; radius: height / 2
                                        color: on ? card.accent : Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.28)
                                    }
                                }
                                Label {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 64 * card.u
                                    horizontalAlignment: Text.AlignRight
                                    text: row.unit === "left" ? ai.pct(row.today) : (row.todayLabel || "0")
                                    color: card.secondary
                                    font.pixelSize: 11 * card.u
                                    font.features: { "tnum": 1 }
                                    elide: Text.ElideRight
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ai.pick(row.id || "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    }
    }

    // =====================================================================================
    // GITHUB — contribution grid, streak, today's commits
    // =====================================================================================
    Loader {
        anchors.fill: parent
        active: card.kind === "github"
        sourceComponent: Component {
            Item {
                id: gh
                anchors.fill: parent
                anchors.margins: card.pad
                readonly property var ghData: (card.readings && card.readings.github) ? card.readings.github : ({})
                readonly property var weeks: ghData.weeks || []
                function cell(level) {
                    var n = Number(level) || 0;
                    if (n <= 0) return Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.08);
                    if (n === 1) return Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.28);
                    if (n === 2) return Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.48);
                    if (n === 3) return Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.72);
                    return card.accent;
                }
                Column {
                    anchors.fill: parent
                    spacing: 8 * card.u
                    Row {
                        width: parent.width
                        Text {
                            text: "commit"
                            font.family: "Material Symbols Outlined"
                            font.pixelSize: 16 * card.u
                            color: card.accent
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Item { width: 6 * card.u; height: 1 }
                        Label {
                            text: ghData.ok ? ("@" + (ghData.login || "github")) : "GitHub"
                            font.pixelSize: 12 * card.u
                            font.weight: Font.DemiBold
                            color: card.ink
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Item { width: parent.width - x - streakLbl.width - 4 * card.u; height: 1 }
                        Label {
                            id: streakLbl
                            text: ghData.ok ? ((ghData.streak || 0) + " day streak") : "offline"
                            font.pixelSize: 11 * card.u
                            color: card.secondary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Row {
                        visible: card.cls !== "s"
                        width: parent.width
                        height: card.cls === "l" ? 118 * card.u : 72 * card.u
                        spacing: 3 * card.u
                        Repeater {
                            model: gh.weeks
                            delegate: Column {
                                required property var modelData
                                spacing: 3 * card.u
                                Repeater {
                                    model: modelData
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: card.cls === "l" ? 14 * card.u : 10 * card.u
                                        height: width
                                        radius: Math.max(2 * card.u, width * 0.22)
                                        color: gh.cell(modelData.level)
                                    }
                                }
                            }
                        }
                    }
                    Row {
                        width: parent.width
                        spacing: 16 * card.u
                        Column {
                            Label { text: String(ghData.today || 0); font.pixelSize: (card.cls === "s" ? 28 : 22) * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                            Label { text: "today"; font.pixelSize: 11 * card.u; color: card.secondary }
                        }
                        Column {
                            visible: card.cls !== "s"
                            Label { text: String(ghData.year || 0); font.pixelSize: 22 * card.u; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                            Label { text: "this year"; font.pixelSize: 11 * card.u; color: card.secondary }
                        }
                        Column {
                            visible: card.cls === "l" && (ghData.repos || []).length
                            Label {
                                text: {
                                    var repos = ghData.repos || [];
                                    var bad = 0;
                                    for (var i = 0; i < repos.length; i++) if (repos[i].ci === "fail") bad++;
                                    return bad ? (bad + " failing") : ((repos.length) + " watched");
                                }
                                font.pixelSize: 22 * card.u; font.weight: Font.DemiBold
                                color: {
                                    var repos = ghData.repos || [];
                                    for (var i = 0; i < repos.length; i++) if (repos[i].ci === "fail") return card.crit;
                                    return card.ink;
                                }
                            }
                            Label { text: "CI / PRs"; font.pixelSize: 11 * card.u; color: card.secondary }
                        }
                    }
                    Label {
                        visible: !ghData.ok
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: ghData.error || "gh auth login, or token in ~/.config/sea-shell/github-token"
                        font.pixelSize: 11 * card.u
                        color: card.secondary
                    }
                }
            }
        }
    }

    // =====================================================================================
    // POMODORO — desktop face for the bar timer
    // =====================================================================================
    Loader {
        anchors.fill: parent
        active: card.kind === "pomodoro"
        sourceComponent: Component {
            Item {
                anchors.fill: parent
                anchors.margins: card.pad
                readonly property var t: (card.readings && card.readings.timer) ? card.readings.timer : ({})
                readonly property bool on: !!t.running
                readonly property real share: t.total > 0 ? Math.max(0, Math.min(1, t.remain / t.total)) : 0
                Column {
                    anchors.centerIn: parent
                    spacing: 10 * card.u
                    width: parent.width
                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width, 100 * card.u); height: width
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                strokeColor: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.12)
                                strokeWidth: 8 * card.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                PathAngleArc { centerX: parent.width / 2; centerY: parent.height / 2
                                    radiusX: parent.width / 2 - 6 * card.u; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
                            }
                            ShapePath {
                                strokeColor: (t.phase === "break" || t.phase === "long") ? card.ok : card.accent
                                strokeWidth: 8 * card.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                                PathAngleArc { centerX: parent.width / 2; centerY: parent.height / 2
                                    radiusX: parent.width / 2 - 6 * card.u; radiusY: radiusX
                                    startAngle: -90; sweepAngle: 360 * share }
                            }
                        }
                        Label {
                            anchors.centerIn: parent
                            text: on ? (t.text || "") : "25:00"
                            font.pixelSize: 22 * card.u
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                        }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: on ? (t.pomo ? (t.phase === "focus" ? "Focus" : (t.phase === "long" ? "Long break" : "Break")) : "Timer")
                                 : "Pomodoro"
                        font.pixelSize: 12 * card.u
                        color: card.secondary
                    }
                    Label {
                        visible: card.cls !== "s" && t.pomo
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Session " + ((t.done || 0) + (t.phase === "focus" ? 1 : 0))
                        font.pixelSize: 11 * card.u
                        color: card.secondary
                    }
                }
            }
        }
    }

    // =====================================================================================
    // CLIPBOARD — recent clips (+ OCR grabs when marked)
    // =====================================================================================
    Loader {
        anchors.fill: parent
        active: card.kind === "clipboard"
        sourceComponent: Component {
            Item {
                anchors.fill: parent
                anchors.margins: card.pad
                readonly property var clips: (card.readings && card.readings.clips) ? card.readings.clips : []
                Column {
                    anchors.fill: parent
                    spacing: 8 * card.u
                    Row {
                        width: parent.width
                        Text { text: "content_paste"; font.family: "Material Symbols Outlined"; font.pixelSize: 16 * card.u; color: card.accent; anchors.verticalCenter: parent.verticalCenter }
                        Item { width: 6 * card.u; height: 1 }
                        Label { text: "Clipboard"; font.pixelSize: 12 * card.u; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                        Item { width: parent.width - x - countLbl.width; height: 1 }
                        Label { id: countLbl; text: String(clips.length); font.pixelSize: 11 * card.u; color: card.secondary; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Repeater {
                        model: clips.slice(0, card.cls === "l" ? 6 : (card.cls === "m" ? 4 : 2))
                        delegate: Rectangle {
                            required property var modelData
                            width: parent.width
                            height: 28 * card.u
                            radius: 8 * card.u
                            color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.05)
                            Row {
                                anchors.fill: parent; anchors.margins: 6 * card.u; spacing: 6 * card.u
                                Text {
                                    text: modelData.ocr ? "document_scanner" : (modelData.img ? "image" : "notes")
                                    font.family: "Material Symbols Outlined"; font.pixelSize: 14 * card.u
                                    color: card.secondary; anchors.verticalCenter: parent.verticalCenter
                                }
                                Label {
                                    width: parent.width - 24 * card.u
                                    text: modelData.text || ""
                                    font.pixelSize: 11 * card.u
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                    Label {
                        visible: clips.length === 0
                        text: "History is empty"
                        font.pixelSize: 11 * card.u
                        color: card.secondary
                    }
                }
            }
        }
    }

    // =====================================================================================
    // TIDE POOL — ambient sysmonitor as a rock pool (janky on purpose)
    // Water = battery · chop = CPU · fish = network · bubbles = notifs/bottles · crab hides
    // when mic/camera is live. Click opens the dashboard.
    // =====================================================================================
    Loader {
        anchors.fill: parent
        active: card.kind === "tide"
        sourceComponent: Component {
            Item {
                id: pool
                anchors.fill: parent
                anchors.margins: card.pad * 0.4
                readonly property var r: card.readings || ({})
                readonly property real bat: Math.max(0.08, Math.min(1, (Number(r.batPct) || 100) / 100))
                readonly property real cpu: Math.max(0, Math.min(1, (Number(r.cpu) || 0) / 100))
                readonly property real net: Math.max(0, Math.min(1, ((Number(r.netRx) || 0) + (Number(r.netTx) || 0)) / 500000))
                readonly property int bubbles: Math.min(10, (Number(r.noteCount) || 0) + (Number(r.bottles) || 0))
                readonly property bool hide: !!r.privacy
                property real t: 0
                property var fish: []
                property var foam: []

                Component.onCompleted: {
                    var f = [], n = card.cls === "s" ? 2 : (card.cls === "l" ? 5 : 3);
                    for (var i = 0; i < n; i++)
                        f.push({ x: 0.15 + Math.random() * 0.7, y: 0.45 + Math.random() * 0.35,
                                 s: 0.7 + Math.random() * 0.6, dir: Math.random() > 0.5 ? 1 : -1, phase: Math.random() * 6.28 });
                    pool.fish = f;
                    var b = [];
                    for (var j = 0; j < 8; j++)
                        b.push({ x: 0.2 + Math.random() * 0.6, y: 1, life: Math.random() });
                    pool.foam = b;
                }

                Timer {
                    interval: card.reducedMotion ? 200 : 40
                    repeat: true
                    running: card.active && card.visible && card.kind === "tide"
                    onTriggered: {
                        pool.t += 0.045 + pool.cpu * 0.08;
                        var f = pool.fish.slice(), speed = 0.0025 + pool.net * 0.012;
                        for (var i = 0; i < f.length; i++) {
                            f[i].x += f[i].dir * speed * f[i].s;
                            f[i].y = 0.42 + 0.08 * Math.sin(pool.t * 1.4 + f[i].phase) + pool.cpu * 0.04 * Math.sin(pool.t * 3 + i);
                            if (f[i].x > 0.92) { f[i].x = 0.92; f[i].dir = -1; }
                            if (f[i].x < 0.08) { f[i].x = 0.08; f[i].dir = 1; }
                        }
                        pool.fish = f;
                        var b = pool.foam.slice(), n = pool.bubbles;
                        for (var j = 0; j < b.length; j++) {
                            if (j >= n) { b[j].y = 1.2; continue; }
                            b[j].y -= 0.012 + pool.cpu * 0.01;
                            b[j].x += 0.002 * Math.sin(pool.t * 2 + j);
                            if (b[j].y < (1 - pool.bat) + 0.05) {
                                b[j].y = 0.92 + Math.random() * 0.08;
                                b[j].x = 0.18 + Math.random() * 0.64;
                            }
                        }
                        pool.foam = b;
                        poolCanvas.requestPaint();
                    }
                }

                Canvas {
                    id: poolCanvas
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d");
                        var w = width, h = height;
                        ctx.clearRect(0, 0, w, h);

                        // rock rim
                        var rr = Math.min(28, 18 * card.u);
                        ctx.beginPath();
                        ctx.moveTo(rr, 0); ctx.lineTo(w - rr, 0);
                        ctx.quadraticCurveTo(w, 0, w, rr); ctx.lineTo(w, h - rr);
                        ctx.quadraticCurveTo(w, h, w - rr, h); ctx.lineTo(rr, h);
                        ctx.quadraticCurveTo(0, h, 0, h - rr); ctx.lineTo(0, rr);
                        ctx.quadraticCurveTo(0, 0, rr, 0); ctx.closePath();
                        ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.14);
                        ctx.fill();

                        // inner basin
                        var m = 7 * card.u;
                        ctx.beginPath();
                        ctx.moveTo(m + rr * 0.5, m); ctx.lineTo(w - m - rr * 0.5, m);
                        ctx.quadraticCurveTo(w - m, m, w - m, m + rr * 0.5);
                        ctx.lineTo(w - m, h - m - rr * 0.5);
                        ctx.quadraticCurveTo(w - m, h - m, w - m - rr * 0.5, h - m);
                        ctx.lineTo(m + rr * 0.5, h - m);
                        ctx.quadraticCurveTo(m, h - m, m, h - m - rr * 0.5);
                        ctx.lineTo(m, m + rr * 0.5);
                        ctx.quadraticCurveTo(m, m, m + rr * 0.5, m);
                        ctx.closePath();
                        ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.06);
                        ctx.fill();
                        ctx.save();
                        ctx.clip();

                        var waterTop = m + (h - 2 * m) * (1 - pool.bat);
                        var amp = (3 + pool.cpu * 10) * card.u;
                        ctx.beginPath();
                        ctx.moveTo(m, h - m);
                        ctx.lineTo(m, waterTop);
                        for (var x = 0; x <= w - 2 * m; x += 4) {
                            var wx = m + x;
                            var wy = waterTop + Math.sin(pool.t * 2.2 + x * 0.045) * amp
                                   + Math.sin(pool.t * 3.7 + x * 0.09) * amp * 0.35;
                            ctx.lineTo(wx, wy);
                        }
                        ctx.lineTo(w - m, h - m);
                        ctx.closePath();
                        var g = ctx.createLinearGradient(0, waterTop, 0, h);
                        g.addColorStop(0, Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.35));
                        g.addColorStop(1, Qt.rgba(card.accent.r * 0.4, card.accent.g * 0.55, card.accent.b * 0.9, 0.72));
                        ctx.fillStyle = g;
                        ctx.fill();

                        // fish
                        for (var i = 0; i < pool.fish.length; i++) {
                            var f = pool.fish[i];
                            var fx = m + f.x * (w - 2 * m);
                            var fy = m + f.y * (h - 2 * m);
                            if (fy < waterTop + 4) continue;
                            var fs = (5 + 4 * f.s) * card.u;
                            ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.55);
                            ctx.beginPath();
                            ctx.ellipse(fx - fs, fy - fs * 0.45, fs * 2, fs * 0.9);
                            ctx.fill();
                            // tail
                            ctx.beginPath();
                            var td = f.dir > 0 ? -1 : 1;
                            ctx.moveTo(fx + td * fs * 0.9, fy);
                            ctx.lineTo(fx + td * fs * 1.7, fy - fs * 0.55);
                            ctx.lineTo(fx + td * fs * 1.7, fy + fs * 0.55);
                            ctx.closePath();
                            ctx.fill();
                        }

                        // bubbles
                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.45);
                        ctx.lineWidth = 1.2 * card.u;
                        for (var j = 0; j < pool.foam.length && j < pool.bubbles; j++) {
                            var b = pool.foam[j];
                            var bx = m + b.x * (w - 2 * m);
                            var by = m + b.y * (h - 2 * m);
                            if (by < waterTop) continue;
                            var br = (2.2 + (j % 3)) * card.u;
                            ctx.beginPath();
                            ctx.arc(bx, by, br, 0, Math.PI * 2);
                            ctx.stroke();
                        }

                        // hermit crab on the sand — hides when privacy is on
                        var cx = m + (w - 2 * m) * 0.78;
                        var cy = h - m - 10 * card.u;
                        if (!pool.hide) {
                            ctx.fillStyle = Qt.rgba(card.warn.r, card.warn.g, card.warn.b, 0.85);
                            ctx.beginPath();
                            ctx.ellipse(cx - 7 * card.u, cy - 5 * card.u, 14 * card.u, 10 * card.u);
                            ctx.fill();
                            ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.55);
                            ctx.beginPath();
                            ctx.ellipse(cx + 4 * card.u, cy - 2 * card.u, 6 * card.u, 5 * card.u);
                            ctx.fill();
                        } else {
                            // just a little shell bump under the sand
                            ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.2);
                            ctx.beginPath();
                            ctx.ellipse(cx - 5 * card.u, cy + 2 * card.u, 10 * card.u, 4 * card.u);
                            ctx.fill();
                        }

                        ctx.restore();

                        // label
                        if (card.cls !== "s") {
                            ctx.fillStyle = Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.55);
                            ctx.font = "600 " + Math.round(11 * card.u) + "px \"" + card.uiFont + "\"";
                            ctx.fillText("Tide pool", m + 4 * card.u, m + 14 * card.u);
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "dashboard", "toggle"])
                }

                // tiny legend on large
                Column {
                    visible: card.cls === "l"
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    anchors.margins: 10 * card.u
                    spacing: 2
                    Label { text: Math.round(pool.bat * 100) + "% tide · " + Math.round(pool.cpu * 100) + "% chop"; font.pixelSize: 10 * card.u; color: card.secondary }
                    Label {
                        text: pool.hide ? "crab is hiding (mic/cam)" : (pool.bubbles ? (pool.bubbles + " bubbles") : "calm water")
                        font.pixelSize: 10 * card.u; color: card.secondary
                    }
                }
            }
        }
    }
}