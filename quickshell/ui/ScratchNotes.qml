// sea-shell — Instant Scratchpad / Markdown Notes (Super+Alt+N).
// Stores plain .md files in ~/.config/sea-shell/notes/ with debounced auto-save,
// clickable checklist toggles (- [ ] / - [x]), multi-note tabs, and zero idle RAM when closed.
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
    property var notes: []            // [{ name, path, content }]
    property int currentIdx: 0
    property bool dirty: false
    property bool _syncing: false
    property string newTitle: ""
    property bool addingNote: false

    readonly property var currentNote: (root.notes.length > 0 && root.currentIdx >= 0 && root.currentIdx < root.notes.length)
        ? root.notes[root.currentIdx] : null

    readonly property var checklistItems: {
        var n = root.currentNote;
        if (!n || !n.content) return [];
        var lines = ("" + n.content).split("\n"), out = [];
        for (var i = 0; i < lines.length; i++) {
            var m = lines[i].match(/^\s*-\s*\[( |x|X)\]\s+(.*)$/);
            if (m) out.push({ line: i, done: m[1].toLowerCase() === "x", text: m[2] });
        }
        return out;
    }

    function open() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        root.shown = true;
        root.loadNotes();
    }
    function close() {
        if (root.dirty) root.saveCurrent();
        if (!root.shown) return;
        root.shown = false;
        root.closed();
    }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    function loadNotes() {
        loadProc.running = false;
        loadProc.running = true;
    }

    Process {
        id: loadProc
        command: ["python3", "-c",
            "import json, pathlib\n" +
            "d = pathlib.Path.home() / '.config/sea-shell/notes'\n" +
            "d.mkdir(parents=True, exist_ok=True)\n" +
            "q = d / 'Quick.md'\n" +
            "if not any(d.glob('*.md')):\n" +
            "    q.write_text('# Quick Notes\\n\\n- [ ] Press Esc to hide anytime\\n- [ ] Add - [ ] lines for clickable checklists\\n')\n" +
            "files = sorted(d.glob('*.md'), key=lambda p: (p.name != 'Quick.md', p.name.lower()))\n" +
            "print(json.dumps([{'name': p.stem, 'path': str(p), 'content': p.read_text(errors='ignore')} for p in files]))\n"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(text.trim() || "[]");
                    if (Array.isArray(arr) && arr.length > 0) {
                        root._syncing = true;
                        root.notes = arr;
                        if (root.currentIdx >= arr.length) root.currentIdx = 0;
                        root._syncing = false;
                    }
                } catch (e) {}
            }
        }
    }

    Timer { id: saveTimer; interval: 420; onTriggered: root.saveCurrent() }

    function saveCurrent() {
        var n = root.currentNote;
        if (!n || !n.path) return;
        root.dirty = false;
        Quickshell.execDetached(["python3", "-c",
            "import os,pathlib,sys; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True); " +
            "t=p.with_suffix('.md.tmp'); t.write_text(sys.argv[2]); os.replace(t,p)",
            n.path, "" + (n.content || "")]);
    }

    function updateContent(txt) {
        if (!root.currentNote) return;
        var list = root.notes.slice();
        list[root.currentIdx] = Object.assign({}, list[root.currentIdx], { content: txt });
        root.notes = list;
        root.dirty = true;
        saveTimer.restart();
    }

    function toggleCheck(lineIdx) {
        var n = root.currentNote;
        if (!n) return;
        var lines = ("" + (n.content || "")).split("\n");
        if (lineIdx < 0 || lineIdx >= lines.length) return;
        if (/^\s*-\s*\[ \]/.test(lines[lineIdx])) lines[lineIdx] = lines[lineIdx].replace(/\[ \]/, "[x]");
        else lines[lineIdx] = lines[lineIdx].replace(/\[[xX]\]/, "[ ]");
        root.updateContent(lines.join("\n"));
    }

    function createNote(rawName) {
        var clean = ("" + (rawName || "")).trim().replace(/[^a-zA-Z0-9 _\-]/g, "");
        if (!clean) return;
        root.addingNote = false;
        root.newTitle = "";
        Quickshell.execDetached(["python3", "-c",
            "import pathlib, sys\n" +
            "d = pathlib.Path.home() / '.config/sea-shell/notes'\n" +
            "d.mkdir(parents=True, exist_ok=True)\n" +
            "p = d / (sys.argv[1] + '.md')\n" +
            "if not p.exists():\n" +
            "    p.write_text('# ' + sys.argv[1] + '\\n\\n')\n",
            clean]);
        reloadLater.restart();
    }

    function deleteCurrent() {
        var n = root.currentNote;
        if (!n || root.notes.length <= 1) return;
        Quickshell.execDetached(["rm", "-f", n.path]);
        root.currentIdx = Math.max(0, root.currentIdx - 1);
        reloadLater.restart();
    }

    Timer { id: reloadLater; interval: 220; onTriggered: root.loadNotes() }

    Variants {
        model: (root.shown && root.openOn) ? [root.openOn] : []
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property real ui: root.uiFor(win.screen)
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:notes"
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
                width: Math.min(720, (win.width / win.ui) - 48)
                height: Math.min(540, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; editor.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                MouseArea { anchors.fill: parent }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    // ---- Header: title + note tabs + actions ----
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Sym { text: "edit_note"; sz: 19; color: Tok.accent }
                        Text { text: "Notes"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold }

                        Row {
                            Layout.leftMargin: 6
                            spacing: 4
                            Repeater {
                                model: root.notes
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    readonly property bool cur: index === root.currentIdx
                                    implicitHeight: 26; implicitWidth: ntLbl.implicitWidth + 18; radius: Tok.r
                                    color: cur ? Tok.alpha(Tok.accent, 0.18) : (ntMa.containsMouse ? Tok.raised : Tok.surface)
                                    border.width: 1; border.color: cur ? Tok.alpha(Tok.accent, 0.6) : Tok.rule
                                    Text {
                                        id: ntLbl; anchors.centerIn: parent; text: modelData.name
                                        color: cur ? Tok.ink : Tok.ink2
                                        font.pixelSize: 12; font.family: Tok.sans; font.weight: cur ? Font.DemiBold : Font.Normal
                                    }
                                    MouseArea {
                                        id: ntMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { if (root.dirty) root.saveCurrent(); root.currentIdx = index; editor.forceActiveFocus() }
                                    }
                                }
                            }
                            Rectangle {
                                implicitHeight: 26; implicitWidth: 26; radius: Tok.r
                                color: addMa.containsMouse ? Tok.raised : Tok.surface
                                border.width: 1; border.color: Tok.rule
                                Sym { anchors.centerIn: parent; text: "add"; sz: 15; color: Tok.ink2 }
                                MouseArea {
                                    id: addMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.addingNote = !root.addingNote; if (root.addingNote) newIn.forceActiveFocus() }
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            implicitHeight: 26; implicitWidth: 26; radius: Tok.r
                            color: cpMa.containsMouse ? Tok.alpha(Tok.accent, 0.16) : Tok.surface
                            border.width: 1; border.color: Tok.rule
                            Sym { anchors.centerIn: parent; text: "content_copy"; sz: 14; color: Tok.ink2 }
                            MouseArea {
                                id: cpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: if (root.currentNote) Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy && notify-send 'sea-shell' 'Note copied'", "sh", root.currentNote.content || ""])
                            }
                        }
                        Rectangle {
                            visible: root.notes.length > 1
                            implicitHeight: 26; implicitWidth: 26; radius: Tok.r
                            color: delMa.containsMouse ? Tok.critWash : Tok.surface
                            border.width: 1; border.color: delMa.containsMouse ? Tok.crit : Tok.rule
                            Sym { anchors.centerIn: parent; text: "delete"; sz: 14; color: delMa.containsMouse ? Tok.crit : Tok.ink3 }
                            MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteCurrent() }
                        }
                    }

                    // ---- Inline new note name prompt ----
                    RowLayout {
                        visible: root.addingNote
                        Layout.fillWidth: true; spacing: 6
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                            color: Tok.sunken; border.width: 1; border.color: Tok.accent
                            TextInput {
                                id: newIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
                                text: root.newTitle; onTextChanged: root.newTitle = text
                                Text { visible: newIn.text.length === 0; anchors.verticalCenter: parent.verticalCenter; text: "New note title…"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                                Keys.onReturnPressed: root.createNote(text)
                                Keys.onEscapePressed: { root.addingNote = false; editor.forceActiveFocus() }
                            }
                        }
                        Rectangle {
                            implicitHeight: 30; implicitWidth: 68; radius: Tok.r; color: Tok.accent
                            Text { anchors.centerIn: parent; text: "Create"; color: Tok.accentInk; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.createNote(newIn.text) }
                        }
                    }

                    // ---- Clickable checklist pills (if note has - [ ] lines) ----
                    Flow {
                        visible: root.checklistItems.length > 0
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: root.checklistItems.slice(0, 6)
                            delegate: Rectangle {
                                required property var modelData
                                implicitHeight: 24; implicitWidth: Math.min(220, ckRow.implicitWidth + 14); radius: Tok.rSmall
                                color: modelData.done ? Tok.okWash : Tok.surface
                                border.width: 1; border.color: modelData.done ? Tok.alpha(Tok.ok, 0.45) : Tok.rule
                                Row {
                                    id: ckRow; anchors.centerIn: parent; spacing: 5
                                    Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.done ? "check_box" : "check_box_outline_blank"; sz: 14; color: modelData.done ? Tok.ok : Tok.ink3 }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, 180); elide: Text.ElideRight
                                        text: modelData.text; color: modelData.done ? Tok.ink3 : Tok.ink
                                        font.pixelSize: 11; font.family: Tok.sans; font.strikeout: modelData.done
                                    }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleCheck(modelData.line) }
                            }
                        }
                    }

                    // ---- Main markdown editor ----
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: Tok.r
                        color: Tok.sunken
                        border.width: 1
                        border.color: editor.activeFocus ? Tok.alpha(Tok.accent, 0.7) : Tok.rule
                        clip: true

                        Flickable {
                            id: flick
                            anchors.fill: parent
                            anchors.margins: 10
                            contentWidth: width
                            contentHeight: Math.max(height, editor.implicitHeight)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            TextEdit {
                                id: editor
                                width: flick.width
                                height: Math.max(flick.height, implicitHeight)
                                color: Tok.ink
                                selectionColor: Tok.alpha(Tok.accent, 0.35)
                                selectedTextColor: Tok.ink
                                font.family: Tok.mono
                                font.pixelSize: 13
                                wrapMode: TextEdit.Wrap
                                selectByMouse: true
                                text: root.currentNote ? (root.currentNote.content || "") : ""
                                onTextChanged: {
                                    if (root._syncing || !root.currentNote) return;
                                    if (text !== (root.currentNote.content || "")) root.updateContent(text);
                                }
                                Keys.onEscapePressed: root.close()
                                Keys.onPressed: (e) => {
                                    if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_S) {
                                        root.saveCurrent(); e.accepted = true;
                                    }
                                }
                            }
                        }
                    }

                    // ---- Footer status ----
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: root.dirty ? "Saving…" : ("Saved · ~/.config/sea-shell/notes/" + (root.currentNote ? root.currentNote.name + ".md" : ""))
                            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            readonly property string txt: root.currentNote ? (root.currentNote.content || "") : ""
                            readonly property int words: txt.trim() ? txt.trim().split(/\s+/).length : 0
                            text: words + " words · Esc close"
                            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                        }
                    }
                }
            }
        }
    }
}
