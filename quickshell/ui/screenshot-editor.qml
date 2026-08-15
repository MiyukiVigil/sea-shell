//@ pragma UseQApplication
// sea-shell — screenshot editor: annotate, crop, OCR, copy/save.
//
// Loads /tmp/sea-capture.png (written by screenshot.qml). The whole editing
// surface lives in a "stage" sized to the capture's NATIVE pixel dimensions and
// visually scaled to fit the screen — so every mouse coordinate is already in
// native pixels. That means brush/arrow/rect/text, crop and OCR all share one
// coordinate space, and export is a single native-resolution grabToImage() with
// a reliable callback (no Canvas.save timer races, no resolution loss).
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgScale: 0
    property string capturePath: "/tmp/sea-capture.png"
    readonly property string rawPath: "/tmp/sea-shot-raw.png"

    // native pixel size of the capture (set once the image loads)
    property int imgW: 0
    property int imgH: 0

    // annotation state
    property string tool: "brush"          // brush | arrow | rect | text | crop
    property color penColor: "#f38ba8"
    property int penSize: 6
    property var objects: []               // committed annotation objects
    property var draft: null               // in-progress object, drawn live

    // crop state — all in native image pixels
    property int cropX: 0
    property int cropY: 0
    property int cropW: 0
    property int cropH: 0
    property bool hasCrop: false
    property bool cropping: false
    property bool exporting: false         // true only during a grab (hides crop mask)

    property string hoverTip: ""

    function uiFor(scr) {
        if (root.cfgScale > 0) return root.cfgScale;
        var h = (scr && scr.height) ? scr.height : 0;
        if (h <= 1440) return 1.0;
        return Math.min(2.5, h / 1080);
    }

    Component.onCompleted: Quickshell.execDetached(["quickshell","-c","sea-shell","ipc","call","shell","pin"])
    function closeEditor() {
        Quickshell.execDetached(["quickshell","-c","sea-shell","ipc","call","shell","unpin"]);
        Qt.quit();
    }

    function undo() {
        if (root.objects.length === 0) { if (root.hasCrop) { root.hasCrop = false; cropCanvas.requestPaint(); } return; }
        var list = root.objects.slice();
        list.pop();
        root.objects = list;
        annotationCanvas.requestPaint();
    }
    function clearAll() {
        root.objects = [];
        root.draft = null;
        root.hasCrop = false;
        root.cropping = false;
        annotationCanvas.requestPaint();
        cropCanvas.requestPaint();
    }

    // grab the stage at native resolution, then hand off to finishProc
    function exportShot(saveToPictures) {
        if (root.imgW <= 0) return;
        root.exporting = true;                     // hide crop mask from the grab
        stage.grabToImage(function(res) {
            res.saveToFile(root.rawPath);
            root.exporting = false;
            finishProc.run(saveToPictures);
        }, Qt.size(root.imgW, root.imgH));
    }

    // appearance sync (accent / light / scale) — same appearance.json every surface reads
    Process {
        running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: {
            try { var j=JSON.parse(apOut.text);
                if(j.accent) root.accent=j.accent;
                if(j.scale!==undefined) root.cfgScale=j.scale;
                if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light");
            } catch(e){} } } }

    // ---------- industrial token shim ----------
    // Colours come from the shared Tok singleton (see shell.qml). This surface used to carry its
    // own copy of the ramp AND its own appearance.json parse, so it drifted from the bar every
    // time the palette changed. The `theme.*` vocabulary is kept because the call sites below
    // speak it; only the source of the values moved.
    QtObject {
        id: theme
        readonly property bool  light: Tok.light
        readonly property color bg:    Tok.bg
        readonly property color panel: Tok.surface
        readonly property color line:  Tok.ruleHard
        readonly property color text:  Tok.ink
        readonly property color sub:   Tok.ink2
        readonly property color faint: Tok.ink3
        readonly property color iris:  Tok.accent
        readonly property color frost: Tok.ink2
        readonly property color good:  Tok.ok
        readonly property color warn:  Tok.warn
        readonly property color bad:   Tok.crit
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // ---- OCR: crop the native capture to the crop region (if any), then tesseract ----
    Process {
        id: ocrProc
        function toBase64(str) {
            var utf8 = unescape(encodeURIComponent(str));
            var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            var encoded = '';
            for (var i = 0; i < utf8.length; i += 3) {
                var c1 = utf8.charCodeAt(i);
                var c2 = i + 1 < utf8.length ? utf8.charCodeAt(i + 1) : NaN;
                var c3 = i + 2 < utf8.length ? utf8.charCodeAt(i + 2) : NaN;
                var byte1 = c1 >> 2;
                var byte2 = ((c1 & 3) << 4) | (isNaN(c2) ? 0 : (c2 >> 4));
                var byte3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (isNaN(c3) ? 0 : (c3 >> 6)));
                var byte4 = isNaN(c3) ? 64 : (c3 & 63);
                encoded += chars.charAt(byte1) + chars.charAt(byte2) + chars.charAt(byte3) + chars.charAt(byte4);
            }
            return encoded;
        }
        function run() {
            var region = (root.hasCrop && root.cropW > 4 && root.cropH > 4)
                ? "magick " + root.capturePath + " -crop " + root.cropW + "x" + root.cropH + "+" + root.cropX + "+" + root.cropY + " +repage /tmp/sea-ocr.png"
                : "cp " + root.capturePath + " /tmp/sea-ocr.png";
            command = ["sh","-c", region + " && tesseract /tmp/sea-ocr.png stdout -l eng 2>/dev/null"];
            running = false; running = true;
        }
        stdout: StdioCollector { id: ocrOut; onStreamFinished: {
            var txt = ocrOut.text.trim();
            if (txt.length > 0) {
                var b = ocrProc.toBase64(txt);
                Quickshell.execDetached(["sh","-c","printf %s '" + b + "' | base64 -d | wl-copy && notify-send 'sea-shell OCR' 'Text copied to clipboard'"]);
            } else {
                Quickshell.execDetached(["sh","-c","notify-send 'sea-shell OCR' 'No text recognized'"]);
            }
        } } }

    // ---- export: crop the native grab (if any), copy to clipboard, optionally save ----
    Process {
        id: finishProc
        function run(saveToPictures) {
            var cropExpr = (root.hasCrop && root.cropW > 4 && root.cropH > 4)
                ? "-crop " + root.cropW + "x" + root.cropH + "+" + root.cropX + "+" + root.cropY + " +repage "
                : "";
            var out = "/tmp/sea-shot-final.png";
            var base = "magick " + root.rawPath + " " + cropExpr + out;
            var copy = "wl-copy --type image/png < " + out;
            var cmd;
            if (saveToPictures) {
                var f = "$HOME/Pictures/Screenshot-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss") + ".png";
                cmd = base + " && cp " + out + " " + f + " && " + copy + " && notify-send 'sea-shell' 'Saved to ~/Pictures · copied to clipboard'";
            } else {
                cmd = base + " && " + copy + " && notify-send 'sea-shell' 'Copied to clipboard'";
            }
            command = ["sh","-c",cmd];
            running = false; running = true;
        }
        onExited: root.closeEditor()
    }

    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: theme.frost
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // a toolbar button with hover tooltip
    component TBtn: Rectangle {
        id: tb
        property string icon: ""
        property string tip: ""
        property bool active: false
        property color tint: theme.sub
        signal act()
        width: 34; height: 34; radius: Tok.r
        color: active ? theme.a(theme.iris, 0.28) : (tbm.containsMouse ? theme.a(theme.iris, 0.14) : "transparent")
        Behavior on color { ColorAnimation { duration: 90 } }
        Sym { anchors.centerIn: parent; text: tb.icon; sz: 18; color: tb.active ? theme.frost : tb.tint }
        MouseArea { id: tbm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: tb.act()
            onEntered: root.hoverTip = tb.tip
            onExited: if (root.hoverTip === tb.tip) root.hoverTip = "" }
    }

    PanelWindow {
        id: mainWin
        anchors { top: true; bottom: true; left: true; right: true }
        color: "#0b0d12"
        WlrLayershell.namespace: "sea-shell:screenshot-editor"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        FocusScope {
            id: fs
            anchors.fill: parent
            focus: true
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) { root.closeEditor(); e.accepted = true; return }
                if (e.modifiers & Qt.ControlModifier) {
                    if (e.key === Qt.Key_Z) { root.undo(); e.accepted = true; return }
                    if (e.key === Qt.Key_C) { root.exportShot(false); e.accepted = true; return }
                    if (e.key === Qt.Key_S) { root.exportShot(true); e.accepted = true; return }
                    return
                }
                switch (e.key) {
                    case Qt.Key_B: root.tool = "brush"; e.accepted = true; break;
                    case Qt.Key_A: root.tool = "arrow"; e.accepted = true; break;
                    case Qt.Key_R: root.tool = "rect"; e.accepted = true; break;
                    case Qt.Key_T: root.tool = "text"; e.accepted = true; break;
                    case Qt.Key_C: root.tool = "crop"; e.accepted = true; break;
                    case Qt.Key_X: root.clearAll(); e.accepted = true; break;
                    case Qt.Key_Return:
                    case Qt.Key_Enter: root.exportShot(false); e.accepted = true; break;
                }
            }

            Item {
                id: viewport
                anchors.fill: parent
                // fit to the viewport with margins for the toolbar/hint; allow small
                // captures to zoom up to 3x so they're actually workable (export stays
                // native-res regardless of this preview scale)
                readonly property real fit: (root.imgW > 0 && root.imgH > 0)
                    ? Math.min((width - 48) / root.imgW, (height - 150) / root.imgH, 3.0) : 1.0

                Item {
                    id: frame
                    anchors.centerIn: parent
                    width: root.imgW * viewport.fit
                    height: root.imgH * viewport.fit

                    // native-sized editing surface, visually scaled to fit
                    Item {
                        id: stage
                        width: root.imgW
                        height: root.imgH
                        transformOrigin: Item.TopLeft
                        scale: viewport.fit

                        Image {
                            id: baseImage
                            anchors.fill: parent
                            source: "file://" + root.capturePath
                            fillMode: Image.Stretch
                            asynchronous: false
                            cache: false
                            smooth: true
                            mipmap: true
                            onStatusChanged: if (status === Image.Ready) {
                                root.imgW = implicitWidth;
                                root.imgH = implicitHeight;
                            }
                        }

                        Canvas {
                            id: annotationCanvas
                            anchors.fill: parent
                            renderTarget: Canvas.FramebufferObject
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.clearRect(0, 0, width, height);
                                var all = root.objects.slice();
                                if (root.draft) all.push(root.draft);
                                for (var i = 0; i < all.length; i++) drawObj(ctx, all[i]);
                            }
                            function drawObj(ctx, o) {
                                ctx.strokeStyle = o.color; ctx.fillStyle = o.color;
                                ctx.lineWidth = o.size; ctx.lineCap = "round"; ctx.lineJoin = "round";
                                if (o.type === "brush") {
                                    if (o.points.length < 2) {
                                        ctx.beginPath(); ctx.arc(o.points[0][0], o.points[0][1], o.size / 2, 0, Math.PI * 2); ctx.fill(); return;
                                    }
                                    ctx.beginPath(); ctx.moveTo(o.points[0][0], o.points[0][1]);
                                    for (var j = 1; j < o.points.length; j++) ctx.lineTo(o.points[j][0], o.points[j][1]);
                                    ctx.stroke();
                                } else if (o.type === "arrow") {
                                    arrow(ctx, o.start[0], o.start[1], o.end[0], o.end[1]);
                                } else if (o.type === "rect") {
                                    var x = Math.min(o.start[0], o.end[0]), y = Math.min(o.start[1], o.end[1]);
                                    ctx.strokeRect(x, y, Math.abs(o.end[0] - o.start[0]), Math.abs(o.end[1] - o.start[1]));
                                } else if (o.type === "text") {
                                    ctx.font = "bold " + Math.max(16, o.size * 4) + "px monospace";
                                    ctx.textBaseline = "top";
                                    ctx.fillText(o.text, o.pos[0], o.pos[1]);
                                }
                            }
                            function arrow(ctx, fx, fy, tx, ty) {
                                var head = Math.max(14, ctx.lineWidth * 3);
                                var ang = Math.atan2(ty - fy, tx - fx);
                                ctx.beginPath(); ctx.moveTo(fx, fy); ctx.lineTo(tx, ty); ctx.stroke();
                                ctx.beginPath(); ctx.moveTo(tx, ty);
                                ctx.lineTo(tx - head * Math.cos(ang - Math.PI / 6), ty - head * Math.sin(ang - Math.PI / 6));
                                ctx.lineTo(tx - head * Math.cos(ang + Math.PI / 6), ty - head * Math.sin(ang + Math.PI / 6));
                                ctx.closePath(); ctx.fill();
                            }
                        }

                        Canvas {
                            id: cropCanvas
                            anchors.fill: parent
                            visible: !root.exporting && (root.hasCrop || root.cropping)
                            onPaint: {
                                var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
                                if (!(root.hasCrop || root.cropping)) return;
                                ctx.fillStyle = "rgba(0,0,0,0.5)"; ctx.fillRect(0, 0, width, height);
                                ctx.clearRect(root.cropX, root.cropY, root.cropW, root.cropH);
                                ctx.strokeStyle = root.accent; ctx.lineWidth = Math.max(1, 2 / viewport.fit);
                                ctx.strokeRect(root.cropX, root.cropY, root.cropW, root.cropH);
                            }
                        }

                        MouseArea {
                            id: drawArea
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.CrossCursor
                            onPressed: (m) => {
                                if (textEdit.visible) { textEdit.commit(); return; }
                                if (root.tool === "brush") {
                                    root.draft = { type: "brush", color: root.penColor, size: root.penSize, points: [[m.x, m.y]] };
                                } else if (root.tool === "arrow") {
                                    root.draft = { type: "arrow", color: root.penColor, size: root.penSize, start: [m.x, m.y], end: [m.x, m.y] };
                                } else if (root.tool === "rect") {
                                    root.draft = { type: "rect", color: root.penColor, size: root.penSize, start: [m.x, m.y], end: [m.x, m.y] };
                                } else if (root.tool === "text") {
                                    textEdit.startAt(m.x, m.y);
                                    return;
                                } else if (root.tool === "crop") {
                                    root.cropX = m.x; root.cropY = m.y; root.cropW = 0; root.cropH = 0;
                                    root.cropping = true; root.hasCrop = true; cropCanvas.requestPaint();
                                    return;
                                }
                                annotationCanvas.requestPaint();
                            }
                            onPositionChanged: (m) => {
                                if (!pressed) return;
                                if (root.draft) {
                                    if (root.draft.type === "brush") root.draft.points.push([m.x, m.y]);
                                    else root.draft.end = [m.x, m.y];
                                    annotationCanvas.requestPaint();
                                } else if (root.tool === "crop" && root.cropping) {
                                    root.cropW = m.x - root.cropX; root.cropH = m.y - root.cropY;
                                    cropCanvas.requestPaint();
                                }
                            }
                            onReleased: (m) => {
                                if (root.draft) {
                                    var list = root.objects.slice(); list.push(root.draft); root.objects = list;
                                    root.draft = null; annotationCanvas.requestPaint();
                                } else if (root.tool === "crop" && root.cropping) {
                                    root.cropping = false;
                                    if (root.cropW < 0) { root.cropX += root.cropW; root.cropW = -root.cropW; }
                                    if (root.cropH < 0) { root.cropY += root.cropH; root.cropH = -root.cropH; }
                                    if (root.cropW < 5 || root.cropH < 5) root.hasCrop = false;
                                    cropCanvas.requestPaint();
                                }
                            }
                        }

                        // in-stage text editor — native coords, so it's WYSIWYG under the scale
                        TextInput {
                            id: textEdit
                            visible: false
                            color: root.penColor
                            font.family: Tok.mono; font.bold: true
                            font.pixelSize: Math.max(16, root.penSize * 4)
                            selectByMouse: true
                            function startAt(x, y) { textEdit.x = x; textEdit.y = y; text = ""; visible = true; forceActiveFocus(); }
                            function commit() {
                                if (text.trim().length > 0) {
                                    var list = root.objects.slice();
                                    list.push({ type: "text", color: root.penColor, size: root.penSize, pos: [textEdit.x, textEdit.y], text: text });
                                    root.objects = list; annotationCanvas.requestPaint();
                                }
                                text = ""; visible = false; fs.forceActiveFocus();
                            }
                            onAccepted: commit()
                            Keys.onEscapePressed: { text = ""; visible = false; fs.forceActiveFocus(); }
                        }
                    }
                }

                // ---------- floating toolbar ----------
                Rectangle {
                    id: toolbar
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 26 }
                    scale: root.uiFor(mainWin.screen)
                    transformOrigin: Item.Bottom
                    width: bar.implicitWidth + 28; height: 52; radius: Tok.rCard
                    color: theme.a(theme.bg, 0.96)
                    border.width: 1; border.color: theme.a(theme.iris, 0.35)

                    // tooltip
                    Rectangle {
                        visible: root.hoverTip !== ""
                        anchors { bottom: parent.top; bottomMargin: 8; horizontalCenter: parent.horizontalCenter }
                        width: tipTxt.implicitWidth + 18; height: 24; radius: Tok.r
                        color: theme.a(theme.bg, 0.98); border.width: 1; border.color: theme.a(theme.iris, 0.3)
                        Text { id: tipTxt; anchors.centerIn: parent; text: root.hoverTip
                            color: theme.text; font.pixelSize: 11; font.family: Tok.mono }
                    }

                    RowLayout {
                        id: bar
                        anchors.centerIn: parent
                        spacing: 10

                        // tools
                        Row { spacing: 2
                            TBtn { icon: "brush";          tip: "brush · b";     active: root.tool === "brush"; onAct: root.tool = "brush" }
                            TBtn { icon: "arrow_right_alt"; tip: "arrow · a";     active: root.tool === "arrow"; onAct: root.tool = "arrow" }
                            TBtn { icon: "crop_square";    tip: "rectangle · r"; active: root.tool === "rect";  onAct: root.tool = "rect" }
                            TBtn { icon: "title";          tip: "text · t";      active: root.tool === "text";  onAct: root.tool = "text" }
                            TBtn { icon: "crop";           tip: "crop · c";      active: root.tool === "crop";  onAct: root.tool = "crop" }
                        }

                        Rectangle { Layout.alignment: Qt.AlignVCenter; width: 1; height: 26; color: theme.a(theme.line, 0.6) }

                        // colours
                        Row { spacing: 6; Layout.alignment: Qt.AlignVCenter
                            Repeater {
                                model: ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#89b4fa", "#cba6f7", "#ffffff", "#11111b"]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.penColor.toString().toLowerCase() === modelData.toLowerCase()
                                    width: 18; height: 18; radius: Tok.r; color: modelData
                                    border.width: sel ? 3 : 1
                                    border.color: sel ? theme.frost : theme.a(theme.line, 0.7)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.penColor = modelData }
                                }
                            }
                        }

                        Rectangle { Layout.alignment: Qt.AlignVCenter; width: 1; height: 26; color: theme.a(theme.line, 0.6) }

                        // stroke sizes
                        Row { spacing: 4; Layout.alignment: Qt.AlignVCenter
                            Repeater {
                                model: [3, 6, 11]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.penSize === modelData
                                    width: 26; height: 26; radius: Tok.r
                                    color: sel ? theme.a(theme.iris, 0.28) : "transparent"
                                    Rectangle { anchors.centerIn: parent; width: 3 + modelData; height: 3 + modelData; radius: width / 2
                                        color: sel ? theme.frost : theme.faint }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.penSize = modelData }
                                }
                            }
                        }

                        Rectangle { Layout.alignment: Qt.AlignVCenter; width: 1; height: 26; color: theme.a(theme.line, 0.6) }

                        // edit actions
                        Row { spacing: 2
                            TBtn { icon: "undo";        tip: "undo · ⌃z";           tint: theme.sub;  onAct: root.undo() }
                            TBtn { icon: "restart_alt"; tip: "clear all · x";       tint: theme.warn; onAct: root.clearAll() }
                            TBtn { icon: "text_fields"; tip: "extract text (OCR)";  tint: theme.frost; onAct: ocrProc.run() }
                        }

                        Rectangle { Layout.alignment: Qt.AlignVCenter; width: 1; height: 26; color: theme.a(theme.line, 0.6) }

                        // output
                        Row { spacing: 2
                            TBtn { icon: "content_copy"; tip: "copy · ⌃c";            tint: theme.frost; onAct: root.exportShot(false) }
                            TBtn { icon: "save";         tip: "save + copy · ⌃s";     tint: theme.good;  onAct: root.exportShot(true) }
                            TBtn { icon: "close";        tip: "cancel · esc";         tint: theme.bad;   onAct: root.closeEditor() }
                        }
                    }
                }

                // shortcut hint — solid pill so it stays legible over any capture
                Rectangle {
                    anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 18 }
                    scale: root.uiFor(mainWin.screen)
                    transformOrigin: Item.Top
                    width: hintTxt.implicitWidth + 24; height: 28; radius: Tok.rCard
                    color: theme.a(theme.bg, 0.92)
                    border.width: 1; border.color: theme.a(theme.iris, 0.3)
                    Text {
                        id: hintTxt
                        anchors.centerIn: parent
                        text: "b brush · a arrow · r rect · t text · c crop   ·   ⌃z undo · x clear   ·   ⌃c copy · ⌃s save · esc cancel"
                        color: theme.sub; font.pixelSize: 11; font.family: Tok.mono
                    }
                }
            }
        }
    }
}
