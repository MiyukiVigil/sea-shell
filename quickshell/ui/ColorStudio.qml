// sea-shell — Color Studio & Eyedropper History (Super+Alt+C).
// Persistent history of colors picked via Super+Shift+C (sea-colorpick.sh),
// 1-click HEX/RGB/HSL/OKLCH copy, 5-step tint/shade ramp, WCAG contrast checker,
// and direct "Apply as sea-shell accent".
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

Scope {
    id: root
    property bool shown: false
    property var uiFor: function (scr) { return 1 }
    signal closed()

    property var openOn: null
    property var history: []
    property string activeHex: "#63C7DD"
    property string compareHex: "#0D1117"
    property string copiedBadge: ""

    function open() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        root.shown = true;
        histFile.reload();
    }
    function close() { if (!root.shown) return; root.shown = false; root.closed(); }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    FileView {
        id: histFile
        path: Quickshell.env("HOME") + "/.config/sea-shell/color-history.json"
        watchChanges: true
        printErrors: false
        function apply() {
            try {
                var arr = JSON.parse(text().trim() || "[]");
                if (Array.isArray(arr)) {
                    root.history = arr;
                    if (arr.length > 0 && arr[0].hex) root.activeHex = arr[0].hex;
                }
            } catch (e) {}
        }
        onLoaded: apply()
        onFileChanged: reload()
    }

    function hexToRgb(h) {
        var s = ("" + (h || "#63c7dd")).replace("#", "");
        if (s.length === 3) s = s[0]+s[0]+s[1]+s[1]+s[2]+s[2];
        var n = parseInt(s.slice(0, 6), 16);
        if (isNaN(n)) return { r: 99, g: 199, b: 221 };
        return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
    }
    function rgbToHex(r, g, b) {
        function p(v) { var s = Math.max(0, Math.min(255, Math.round(v))).toString(16); return s.length < 2 ? "0" + s : s; }
        return ("#" + p(r) + p(g) + p(b)).toUpperCase();
    }
    function rgbToHsl(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        var mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, h = 0, s = 0;
        if (mx !== mn) {
            var d = mx - mn;
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
            if (mx === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
            else if (mx === g) h = ((b - r) / d + 2) / 6;
            else h = ((r - g) / d + 4) / 6;
        }
        return "hsl(" + Math.round(h * 360) + ", " + Math.round(s * 100) + "%, " + Math.round(l * 100) + "%)";
    }
    function lin(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
    function rgbToOklch(r, g, b) {
        var lr = lin(r), lg = lin(g), lb = lin(b);
        var l = Math.cbrt(0.4122214708*lr + 0.5363325363*lg + 0.0514459929*lb);
        var m = Math.cbrt(0.2119034982*lr + 0.6806995451*lg + 0.1073969566*lb);
        var s = Math.cbrt(0.0883024619*lr + 0.2817188376*lg + 0.6299787005*lb);
        var L = 0.2104542553*l + 0.7936177850*m - 0.0040720468*s;
        var a = 1.9779984951*l - 2.4285922050*m + 0.4505937099*s;
        var bb = 0.0259040371*l + 0.7827717662*m - 0.8086757660*s;
        var C = Math.sqrt(a*a + bb*bb);
        var H = (Math.atan2(bb, a) * 180 / Math.PI + 360) % 360;
        return "oklch(" + (L * 100).toFixed(1) + "% " + C.toFixed(3) + " " + H.toFixed(0) + ")";
    }
    function relLum(h) {
        var c = hexToRgb(h);
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }
    function contrast(h1, h2) {
        var l1 = relLum(h1), l2 = relLum(h2);
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    }
    function rampFor(h) {
        var c = hexToRgb(h), out = [];
        var steps = [-0.45, -0.22, 0, 0.25, 0.50];
        for (var i = 0; i < steps.length; i++) {
            var t = steps[i];
            if (t < 0) out.push(rgbToHex(c.r * (1 + t), c.g * (1 + t), c.b * (1 + t)));
            else out.push(rgbToHex(c.r + (255 - c.r) * t, c.g + (255 - c.g) * t, c.b + (255 - c.b) * t));
        }
        return out;
    }

    function copyText(txt) {
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", txt]);
        root.copiedBadge = "Copied " + txt;
        copiedClear.restart();
    }
    Timer { id: copiedClear; interval: 1800; onTriggered: root.copiedBadge = "" }

    function applyAsAccent(hex) {
        Quickshell.execDetached(["python3", "-c",
            "import json,os,pathlib,sys; p=pathlib.Path.home()/'.config/sea-shell/appearance.json'; " +
            "p.parent.mkdir(parents=True,exist_ok=True); " +
            "d=json.loads(p.read_text()) if p.is_file() else {}; d['accent']=sys.argv[1]; " +
            "t=p.with_suffix('.json.tmp'); t.write_text(json.dumps(d,indent=2)); os.replace(t,p)",
            hex.toLowerCase()]);
        root.copiedBadge = "Applied " + hex + " as accent";
        copiedClear.restart();
    }

    function pickFromScreen() {
        root.close();
        Quickshell.execDetached(["sh", "-c", "sleep 0.25 && sh \"$HOME/.config/quickshell/sea-shell/sea-colorpick.sh\" && qs -c sea-shell ipc call colors open"]);
    }

    Variants {
        model: (root.shown && root.openOn) ? [root.openOn] : []
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property real ui: root.uiFor(win.screen)
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:colors"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.42)
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(600, (win.width / win.ui) - 48)
                height: Math.min(500, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; keyScope.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                FocusScope {
                    id: keyScope; anchors.fill: parent; focus: true
                    Keys.onEscapePressed: root.close()
                }
                MouseArea { anchors.fill: parent }

                readonly property var rgb: root.hexToRgb(root.activeHex)
                readonly property string rgbStr: "rgb(" + rgb.r + ", " + rgb.g + ", " + rgb.b + ")"
                readonly property string hslStr: root.rgbToHsl(rgb.r, rgb.g, rgb.b)
                readonly property string oklchStr: root.rgbToOklch(rgb.r, rgb.g, rgb.b)
                readonly property real onWhite: root.contrast(root.activeHex, "#FFFFFF")
                readonly property real onBlack: root.contrast(root.activeHex, "#000000")
                readonly property real onCmp:   root.contrast(root.activeHex, root.compareHex)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12

                    // ---- Header ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Sym { text: "palette"; sz: 18; color: Tok.accent }
                        Text { text: "Color Studio"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold }
                        Text { visible: root.copiedBadge !== ""; text: "· " + root.copiedBadge; color: Tok.ok; font.pixelSize: 11; font.family: Tok.mono }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            implicitHeight: 28; implicitWidth: pkRow.implicitWidth + 18; radius: Tok.r
                            color: pkMa.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent
                            Row { id: pkRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "colorize"; sz: 15; color: Tok.accentInk }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Pick screen"; color: Tok.accentInk; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold } }
                            MouseArea { id: pkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickFromScreen() }
                        }
                    }

                    // ---- Hero active color + formats ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 12
                        Rectangle {
                            Layout.preferredWidth: 112; Layout.preferredHeight: 112
                            radius: Tok.rCard; color: root.activeHex
                            border.width: 1; border.color: Tok.ruleHard
                            Text {
                                anchors.centerIn: parent; text: root.activeHex
                                color: card.onBlack >= card.onWhite ? "#11111b" : "#ffffff"
                                font.pixelSize: 13; font.family: Tok.mono; font.weight: Font.DemiBold
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 6
                            Repeater {
                                model: [
                                    { l: "HEX",   v: root.activeHex },
                                    { l: "RGB",   v: card.rgbStr },
                                    { l: "HSL",   v: card.hslStr },
                                    { l: "OKLCH", v: card.oklchStr }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; implicitHeight: 24; radius: Tok.rSmall
                                    color: fmMa.containsMouse ? Tok.raised : Tok.surface
                                    border.width: 1; border.color: Tok.rule
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                        Text { text: modelData.l; color: Tok.ink3; font.pixelSize: 10; font.family: Tok.mono; Layout.preferredWidth: 42 }
                                        Text { Layout.fillWidth: true; text: modelData.v; color: Tok.ink; font.pixelSize: 11; font.family: Tok.mono; elide: Text.ElideRight }
                                        Sym { text: "content_copy"; sz: 13; color: fmMa.containsMouse ? Tok.accent : Tok.ink3 }
                                    }
                                    MouseArea { id: fmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.copyText(modelData.v) }
                                }
                            }
                        }
                    }

                    // ---- 5-step tint / shade ramp ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: root.rampFor(root.activeHex)
                            delegate: Rectangle {
                                required property string modelData
                                Layout.fillWidth: true; implicitHeight: 34; radius: Tok.rSmall
                                color: modelData; border.width: 1; border.color: Tok.ruleHard
                                Text {
                                    anchors.centerIn: parent; text: modelData
                                    color: root.contrast(modelData, "#000000") >= 4.5 ? "#11111b" : "#ffffff"
                                    font.pixelSize: 10; font.family: Tok.mono
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copyText(modelData) }
                            }
                        }
                    }

                    // ---- WCAG Contrast Checker + Apply Accent ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Repeater {
                            model: [
                                { l: "On White", r: card.onWhite, bg: "#ffffff", fg: root.activeHex },
                                { l: "On Black", r: card.onBlack, bg: "#0d1117", fg: root.activeHex },
                                { l: "vs Compare", r: card.onCmp, bg: root.compareHex, fg: root.activeHex }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property string grade: modelData.r >= 7 ? "AAA" : (modelData.r >= 4.5 ? "AA" : "Fail")
                                Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                                color: Tok.surface; border.width: 1; border.color: Tok.rule
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 6
                                    Rectangle {
                                        width: 22; height: 22; radius: 4; color: modelData.bg; border.width: 1; border.color: Tok.ruleHard
                                        Text { anchors.centerIn: parent; text: "Aa"; color: modelData.fg; font.pixelSize: 10; font.weight: Font.Bold }
                                    }
                                    Column {
                                        Layout.fillWidth: true
                                        Text { text: modelData.l; color: Tok.ink3; font.pixelSize: 10; font.family: Tok.sans }
                                        Text { text: modelData.r.toFixed(1) + ":1 · " + grade; color: grade === "Fail" ? Tok.warn : Tok.ok; font.pixelSize: 11; font.family: Tok.mono; font.weight: Font.DemiBold }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            implicitHeight: 36; implicitWidth: accRow.implicitWidth + 16; radius: Tok.r
                            color: accMa.containsMouse ? Tok.alpha(Tok.accent, 0.22) : Tok.surface
                            border.width: 1; border.color: Tok.accent
                            Row { id: accRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "auto_awesome"; sz: 14; color: Tok.accent }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Set accent"; color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium } }
                            MouseArea { id: accMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyAsAccent(root.activeHex) }
                        }
                    }

                    // ---- Picked color history grid ----
                    Text {
                        text: root.history.length > 0 ? "Recent picks (left-click select · right-click compare)" : "No colors picked yet — press Super+Shift+C or click Pick screen"
                        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                    }
                    GridView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        cellWidth: 46; cellHeight: 46
                        model: root.history
                        delegate: Item {
                            required property var modelData
                            width: 46; height: 46
                            Rectangle {
                                anchors.fill: parent; anchors.margins: 4; radius: Tok.r
                                color: modelData.hex || "#63c7dd"
                                border.width: root.activeHex === modelData.hex ? 2 : 1
                                border.color: root.activeHex === modelData.hex ? Tok.accent : Tok.ruleHard
                                MouseArea {
                                    anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton; cursorShape: Qt.PointingHandCursor
                                    onClicked: (m) => {
                                        if (m.button === Qt.RightButton) root.compareHex = modelData.hex;
                                        else root.activeHex = modelData.hex;
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
