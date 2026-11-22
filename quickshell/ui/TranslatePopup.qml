// sea-shell — Screen OCR -> Instant Translate overlay (Super+Shift+T).
// Captures a screen region with slurp+grim+tesseract or reads text/clipboard and
// displays the translation in a crisp opaque Tok.bg card with 1-click copy.
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

    readonly property string script: Qt.resolvedUrl("sea-translate.py").toString().replace("file://", "")
    property var openOn: null
    property string targetLang: "en"
    property string sourceText: ""
    property string translatedText: ""
    property string detectedLang: ""
    property string statusMsg: ""
    property bool busy: false

    function _pinScreen() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
    }
    function open() {
        root._pinScreen();
        root.shown = true;
    }
    function openOcr() {
        root._pinScreen();
        root.shown = false;  // keep screen unobstructed while slurp selects region
        root.busy = true;
        root.statusMsg = "Select region to OCR & translate…";
        ocrProc.command = ["python3", root.script, "ocr", root.targetLang];
        ocrProc.running = false;
        ocrProc.running = true;
    }
    function close() { if (!root.shown) return; root.shown = false; root.closed(); }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    function translateClipboard() {
        root.busy = true;
        root.statusMsg = "Translating clipboard…";
        trProc.command = ["python3", root.script, "clip", root.targetLang];
        trProc.running = false;
        trProc.running = true;
    }
    function translateSource() {
        if (!root.sourceText.trim()) return;
        root.busy = true;
        root.statusMsg = "Translating…";
        trProc.command = ["python3", root.script, "text", root.sourceText, root.targetLang];
        trProc.running = false;
        trProc.running = true;
    }

    function applyResult(raw) {
        root.busy = false;
        try {
            var j = JSON.parse(raw.trim() || "{}");
            if (j.cancelled) { root.statusMsg = ""; return; }
            if (!j.ok) { root.statusMsg = j.err || "Translation failed"; root.shown = true; return; }
            root.sourceText = j.source || "";
            root.translatedText = j.translated || "";
            root.detectedLang = j.lang || "";
            root.statusMsg = "";
            root.shown = true;
        } catch (e) {
            root.statusMsg = "Could not parse translation response";
            root.shown = true;
        }
    }

    Process {
        id: ocrProc
        stdout: StdioCollector { onStreamFinished: root.applyResult(text) }
    }
    Process {
        id: trProc
        stdout: StdioCollector { onStreamFinished: root.applyResult(text) }
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
            WlrLayershell.namespace: "sea-shell:translate"
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
                width: Math.min(620, (win.width / win.ui) - 48)
                height: Math.min(460, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1; border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; srcIn.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                MouseArea { anchors.fill: parent }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 16; spacing: 10

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Sym { text: "translate"; sz: 18; color: Tok.accent }
                        Text { text: "OCR & Translate"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        // Target language chips
                        Row {
                            spacing: 4
                            Repeater {
                                model: [
                                    { c: "en", l: "EN" }, { c: "ja", l: "JA" }, { c: "zh-CN", l: "ZH" },
                                    { c: "ms", l: "MS" }, { c: "ko", l: "KO" }, { c: "es", l: "ES" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool cur: root.targetLang === modelData.c
                                    implicitHeight: 24; implicitWidth: 32; radius: Tok.rSmall
                                    color: cur ? Tok.accent : (lm.containsMouse ? Tok.raised : Tok.surface)
                                    border.width: cur ? 0 : 1; border.color: Tok.rule
                                    Text { anchors.centerIn: parent; text: modelData.l; color: cur ? Tok.accentInk : Tok.ink2; font.pixelSize: 10; font.family: Tok.mono; font.weight: cur ? Font.DemiBold : Font.Normal }
                                    MouseArea { id: lm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.targetLang = modelData.c; if (root.sourceText.trim()) root.translateSource() } }
                                }
                            }
                        }
                    }

                    // Quick capture actions
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Rectangle {
                            implicitHeight: 30; implicitWidth: ocRow.implicitWidth + 18; radius: Tok.r
                            color: ocMa.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent
                            Row { id: ocRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "screenshot_region"; sz: 15; color: Tok.accentInk }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "OCR Screen"; color: Tok.accentInk; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold } }
                            MouseArea { id: ocMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openOcr() }
                        }
                        Rectangle {
                            implicitHeight: 30; implicitWidth: cbRow.implicitWidth + 16; radius: Tok.r
                            color: cbMa.containsMouse ? Tok.raised : Tok.surface
                            border.width: 1; border.color: Tok.rule
                            Row { id: cbRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "content_paste"; sz: 14; color: Tok.ink2 }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "From clipboard"; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans } }
                            MouseArea { id: cbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.translateClipboard() }
                        }
                        Rectangle {
                            implicitHeight: 30; implicitWidth: goRow.implicitWidth + 16; radius: Tok.r
                            color: goMa.containsMouse ? Tok.alpha(Tok.accent, 0.2) : Tok.surface
                            border.width: 1; border.color: Tok.accent
                            Row { id: goRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "g_translate"; sz: 14; color: Tok.accent }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Translate"; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans } }
                            MouseArea { id: goMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.translateSource() }
                        }
                        Item { Layout.fillWidth: true }
                        Text { visible: root.statusMsg !== ""; text: root.statusMsg; color: Tok.warn; font.pixelSize: 11; font.family: Tok.sans }
                    }

                    // Source box
                    Text { text: root.detectedLang ? ("Source (" + root.detectedLang.toUpperCase() + ")") : "Source text"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 1
                        radius: Tok.r; color: Tok.sunken; border.width: 1; border.color: srcIn.activeFocus ? Tok.accent : Tok.rule; clip: true
                        Flickable {
                            anchors.fill: parent; anchors.margins: 8; contentWidth: width; contentHeight: Math.max(height, srcIn.implicitHeight); clip: true
                            TextEdit {
                                id: srcIn; width: parent.width; height: Math.max(parent.height, implicitHeight)
                                color: Tok.ink; font.family: Tok.sans; font.pixelSize: 13; wrapMode: TextEdit.Wrap; selectByMouse: true
                                text: root.sourceText
                                onTextChanged: if (text !== root.sourceText) root.sourceText = text
                                Keys.onEscapePressed: root.close()
                                Keys.onPressed: (e) => { if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { root.translateSource(); e.accepted = true } }
                            }
                        }
                    }

                    // Translated box
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Translation (" + root.targetLang.toUpperCase() + ")"; color: Tok.accent; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            visible: root.translatedText.length > 0
                            implicitHeight: 22; implicitWidth: 56; radius: Tok.rSmall
                            color: cpMa.containsMouse ? Tok.accent : Tok.surface
                            border.width: 1; border.color: Tok.accent
                            Text { anchors.centerIn: parent; text: "Copy"; color: cpMa.containsMouse ? Tok.accentInk : Tok.ink; font.pixelSize: 11; font.family: Tok.sans }
                            MouseArea { id: cpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy && notify-send 'sea-shell' 'Translation copied'", "sh", root.translatedText]) }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredHeight: 1
                        radius: Tok.r; color: Tok.surface; border.width: 1; border.color: Tok.rule; clip: true
                        Flickable {
                            anchors.fill: parent; anchors.margins: 8; contentWidth: width; contentHeight: Math.max(height, outTxt.implicitHeight); clip: true
                            TextEdit {
                                id: outTxt; width: parent.width; readOnly: true; selectByMouse: true
                                color: Tok.ink; font.family: Tok.sans; font.pixelSize: 13; wrapMode: TextEdit.Wrap
                                text: root.busy ? "Translating…" : (root.translatedText || "Capture a region or paste text to translate.")
                            }
                        }
                    }
                }
            }
        }
    }
}
