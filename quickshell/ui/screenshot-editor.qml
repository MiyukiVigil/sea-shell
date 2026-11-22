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
    property var  cfgMonitors: ({})   // per-monitor overrides from appearance.json
    property string capturePath: "/tmp/sea-capture.png"
    readonly property string rawPath: "/tmp/sea-shot-raw.png"

    // native pixel size of the capture (set once the image loads)
    property int imgW: 0
    property int imgH: 0

    // annotation state
    property string tool: "brush"          // brush | arrow | rect | redact | step | text | crop
    property color penColor: "#f38ba8"
    property int penSize: 6
    property var objects: []               // committed annotation objects
    property var draft: null               // in-progress object, drawn live
    function nextStepNumber() {
        var n = 1;
        for (var i = 0; i < root.objects.length; i++) if (root.objects[i].type === "step") n++;
        return n;
    }

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
        var mo = (scr && scr.name && root.cfgMonitors[scr.name]) ? root.cfgMonitors[scr.name].scale : 0;
        if (mo > 0) return mo;                // per-monitor override wins (same rule as the bar)
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

    // grab the stage at native resolution, then hand off to finishProc (mode: "copy" | "save" | "pin")
    function exportShot(mode) {
        if (root.imgW <= 0) return;
        var m = (mode === true) ? "save" : (mode === false ? "copy" : ("" + mode));
        root.exporting = true;                     // hide crop mask from the grab
        stage.grabToImage(function(res) {
            res.saveToFile(root.rawPath);
            root.exporting = false;
            finishProc.run(m);
        }, Qt.size(root.imgW, root.imgH));
    }

    // appearance sync (accent / light / scale) — same appearance.json every surface reads
    Process {
        running: true
        command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: {
            try { var j=JSON.parse(apOut.text);
                if(j.accent) root.accent=j.accent;
                if(j.scale!==undefined) root.cfgScale=j.scale; if(j.monitors) root.cfgMonitors=j.monitors;
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

    // ---- export: crop the native grab (if any), copy to clipboard, optionally save or pin ----
    Process {
        id: finishProc
        function run(mode) {
            var cropExpr = (root.hasCrop && root.cropW > 4 && root.cropH > 4)
                ? "-crop " + root.cropW + "x" + root.cropH + "+" + root.cropX + "+" + root.cropY + " +repage "
                : "";
            var out = "/tmp/sea-shot-final.png";
            var base = "magick " + root.rawPath + " " + cropExpr + out;
            var copy = "wl-copy --type image/png < " + out;
            var cmd;
            if (mode === "pin") {
                var pinPath = "/tmp/sea-shot-pin-" + Date.now() + ".png";
                var pinQml = Qt.resolvedUrl("PinImage.qml").toString().replace("file://", "");
                cmd = base + " && cp " + out + " " + pinPath + " && " + copy +
                      " && SEA_PIN_IMAGE='" + pinPath + "' setsid quickshell -n -p '" + pinQml + "' >/dev/null 2>&1 &";
            } else if (mode === "save") {
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
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // a hairline between toolbar sections
    component Divider: Rectangle { Layout.alignment: Qt.AlignVCenter; width: 1; height: 24
        color: Tok.alpha(Tok.ink, 0.10) }

    // a toolbar button with hover tooltip: round, and the chosen tool filled with the accent,
    // as macOS Markup marks its current tool
    component TBtn: Rectangle {
        id: tb
        property string icon: ""
        property string tip: ""
        property bool active: false
        property color tint: Tok.ink2
        signal act()
        width: 36; height: 36; radius: 18
        color: active ? Tok.accent : (tbm.containsMouse ? Tok.alpha(Tok.ink, 0.08) : "transparent")
        scale: tbm.pressed ? 0.94 : 1
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        Sym { anchors.centerIn: parent; text: tb.icon; sz: 19; color: tb.active ? Tok.accentInk : tb.tint }
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
                    case Qt.Key_M: root.tool = "redact"; e.accepted = true; break;
                    case Qt.Key_N: root.tool = "step"; e.accepted = true; break;
                    case Qt.Key_T: root.tool = "text"; e.accepted = true; break;
                    case Qt.Key_C: root.tool = "crop"; e.accepted = true; break;
                    case Qt.Key_P: root.exportShot("pin"); e.accepted = true; break;
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
                            source: Tok.fileUrl(root.capturePath)
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
                                } else if (o.type === "redact") {
                                    var rx = Math.min(o.start[0], o.end[0]), ry = Math.min(o.start[1], o.end[1]);
                                    var rw = Math.abs(o.end[0] - o.start[0]), rh = Math.abs(o.end[1] - o.start[1]);
                                    var cell = Math.max(10, o.size * 2);
                                    var shades = ["#141821", "#1e2433", "#293145", "#191f2c"];
                                    for (var py = 0; py < rh; py += cell) {
                                        for (var px = 0; px < rw; px += cell) {
                                            var idx = (Math.floor(px / cell) * 7 + Math.floor(py / cell) * 13) & 3;
                                            ctx.fillStyle = shades[idx];
                                            ctx.fillRect(rx + px, ry + py, Math.min(cell, rw - px), Math.min(cell, rh - py));
                                        }
                                    }
                                    ctx.strokeStyle = "rgba(255,255,255,0.16)";
                                    ctx.lineWidth = 1;
                                    ctx.strokeRect(rx, ry, rw, rh);
                                } else if (o.type === "step") {
                                    var rad = Math.max(15, o.size * 2.8);
                                    ctx.beginPath();
                                    ctx.arc(o.pos[0], o.pos[1], rad, 0, Math.PI * 2);
                                    ctx.fillStyle = o.color;
                                    ctx.fill();
                                    ctx.lineWidth = 2.5;
                                    ctx.strokeStyle = "#ffffff";
                                    ctx.stroke();
                                    ctx.fillStyle = "#11111b";
                                    ctx.font = "bold " + Math.round(rad * 1.15) + "px '" + Tok.sans + "'";
                                    ctx.textAlign = "center";
                                    ctx.textBaseline = "middle";
                                    ctx.fillText("" + o.num, o.pos[0], o.pos[1] + 1);
                                    ctx.textAlign = "start";
                                } else if (o.type === "text") {
                                    ctx.font = "bold " + Math.max(16, o.size * 4) + "px '" + Tok.sans + "'";
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
                                } else if (root.tool === "redact") {
                                    root.draft = { type: "redact", color: root.penColor, size: root.penSize, start: [m.x, m.y], end: [m.x, m.y] };
                                } else if (root.tool === "step") {
                                    var sl = root.objects.slice();
                                    sl.push({ type: "step", color: root.penColor, size: root.penSize, pos: [m.x, m.y], num: root.nextStepNumber() });
                                    root.objects = sl;
                                    annotationCanvas.requestPaint();
                                    return;
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
                            font.family: Tok.sans; font.bold: true
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
                // One bar along the foot, in the shell's language: round tools, round swatches,
                // and the two ways out (Copy, Save) as named buttons rather than three more icons.
                Rectangle {
                    id: toolbar
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
                    scale: root.uiFor(mainWin.screen)
                    transformOrigin: Item.Bottom
                    width: bar.implicitWidth + 20; height: 56; radius: 28
                    color: Tok.bg
                    border.width: 1; border.color: Tok.alpha(Tok.ink, 0.10)

                    // tooltip: dark on any capture, so it reads over a white page or a black one
                    Rectangle {
                        visible: root.hoverTip !== ""
                        anchors { bottom: parent.top; bottomMargin: 10; horizontalCenter: parent.horizontalCenter }
                        width: tipTxt.implicitWidth + 22; height: 28; radius: 14
                        color: Tok.light ? Tok.ink : Tok.raised
                        IndText { id: tipTxt; anchors.centerIn: parent; text: root.hoverTip; sz: Tok.tData
                            color: Tok.light ? Tok.bg : Tok.ink }
                    }

                    RowLayout {
                        id: bar
                        anchors.centerIn: parent
                        spacing: 8

                        // tools
                        Row { spacing: 2
                            TBtn { icon: "brush";           tip: "Brush  (B)";          active: root.tool === "brush";  onAct: root.tool = "brush" }
                            TBtn { icon: "arrow_right_alt"; tip: "Arrow  (A)";          active: root.tool === "arrow";  onAct: root.tool = "arrow" }
                            TBtn { icon: "crop_square";     tip: "Rectangle  (R)";      active: root.tool === "rect";   onAct: root.tool = "rect" }
                            TBtn { icon: "blur_on";         tip: "Redact / Mosaic (M)"; active: root.tool === "redact"; onAct: root.tool = "redact" }
                            TBtn { icon: "looks_one";       tip: "Step badge  (N)";     active: root.tool === "step";   onAct: root.tool = "step" }
                            TBtn { icon: "title";           tip: "Text  (T)";           active: root.tool === "text";   onAct: root.tool = "text" }
                            TBtn { icon: "crop";            tip: "Crop  (C)";           active: root.tool === "crop";   onAct: root.tool = "crop" }
                        }

                        Divider {}

                        // colours: round swatches, the chosen one ringed
                        Row { spacing: 4; Layout.alignment: Qt.AlignVCenter
                            Repeater {
                                model: ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#89b4fa", "#cba6f7", "#ffffff", "#11111b"]
                                delegate: Item {
                                    required property var modelData
                                    readonly property bool sel: root.penColor.toString().toLowerCase() === modelData.toLowerCase()
                                    width: 24; height: 24
                                    Rectangle { anchors.fill: parent; radius: 12; color: "transparent"
                                        border.width: 2; border.color: parent.sel ? Tok.accent : "transparent" }
                                    Rectangle { anchors.centerIn: parent; width: 16; height: 16; radius: 8; color: modelData
                                        border.width: 1; border.color: Tok.alpha(Tok.ink, 0.18) }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.penColor = modelData }
                                }
                            }
                        }

                        Divider {}

                        // stroke sizes
                        Row { spacing: 2; Layout.alignment: Qt.AlignVCenter
                            Repeater {
                                model: [3, 6, 11]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool sel: root.penSize === modelData
                                    width: 30; height: 30; radius: 15
                                    color: sel ? Tok.alpha(Tok.accent, 0.16) : "transparent"
                                    Rectangle { anchors.centerIn: parent; width: 3 + modelData; height: 3 + modelData; radius: width / 2
                                        color: parent.sel ? Tok.accent : Tok.ink3 }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.penSize = modelData }
                                }
                            }
                        }

                        Divider {}

                        // edit actions
                        Row { spacing: 2
                            TBtn { icon: "undo";         tip: "Undo  (Ctrl Z)";            onAct: root.undo() }
                            TBtn { icon: "delete_sweep"; tip: "Clear all  (X)";            onAct: root.clearAll() }
                            TBtn { icon: "text_fields";  tip: "Copy the text in it (OCR)"; onAct: ocrProc.run() }
                            TBtn { icon: "keep";         tip: "Pin to screen  (P)";        onAct: root.exportShot("pin") }
                        }

                        Divider {}

                        // the ways out, named
                        Row { spacing: 6; Layout.alignment: Qt.AlignVCenter
                            Rectangle {
                                width: cpT.implicitWidth + 28; height: 36; radius: 18
                                color: cpMa.containsMouse ? Tok.alpha(Tok.ink, 0.10) : Tok.alpha(Tok.ink, 0.05)
                                scale: cpMa.pressed ? 0.96 : 1
                                Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
                                IndText { id: cpT; anchors.centerIn: parent; text: "Copy"; sz: Tok.tDense; font.weight: Font.DemiBold }
                                MouseArea { id: cpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.exportShot(false)
                                    onEntered: root.hoverTip = "Copy to the clipboard  (Ctrl C)"
                                    onExited: root.hoverTip = "" }
                            }
                            Rectangle {
                                width: svT.implicitWidth + 28; height: 36; radius: 18
                                color: svMa.containsMouse ? Qt.lighter(Tok.accent, 1.1) : Tok.accent
                                scale: svMa.pressed ? 0.96 : 1
                                Behavior on scale { NumberAnimation { duration: Tok.mMicro } }
                                IndText { id: svT; anchors.centerIn: parent; text: "Save"; sz: Tok.tDense; font.weight: Font.DemiBold
                                    color: Tok.accentInk }
                                MouseArea { id: svMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.exportShot(true)
                                    onEntered: root.hoverTip = "Save to ~/Pictures and copy  (Ctrl S)"
                                    onExited: root.hoverTip = "" }
                            }
                            TBtn { icon: "close"; tip: "Discard  (Esc)"; onAct: root.closeEditor() }
                        }
                    }
                }
            }
        }
    }
}
