// sea-shell — visual clipboard manager (Super+V): History (with image thumbnails),
// persistent Pinned snippets, and searchable Emoji & Symbols picker.
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

    readonly property string clipScript: Qt.resolvedUrl("sea-clipboard.py").toString().replace("file://", "")

    property string tab: "history"       // history | pins | emoji
    property string query: ""
    property int sel: 0
    property var history: []
    property var pins: []
    property bool loading: false
    property string newPinDraft: ""

    readonly property var emojiList: [
        { e: "😀", n: "grinning happy smile" }, { e: "😂", n: "joy laugh tears" }, { e: "🥹", n: "holding back tears proud" },
        { e: "😊", n: "blush smile warm" }, { e: "😍", n: "heart eyes love" }, { e: "😎", n: "sunglasses cool" },
        { e: "🤔", n: "thinking hmm" }, { e: "😭", n: "sob cry loud" }, { e: "😤", n: "triumph huff" },
        { e: "🤯", n: "mind blown exploded" }, { e: "🥳", n: "party celebrate" }, { e: "😴", n: "sleep zzz tired" },
        { e: "👍", n: "thumbs up ok yes" }, { e: "👎", n: "thumbs down no" }, { e: "👏", n: "clap applause" },
        { e: "🙏", n: "pray please thanks" }, { e: "🔥", n: "fire lit hot" }, { e: "✨", n: "sparkles magic shine" },
        { e: "⚡", n: "zap bolt fast lightning" }, { e: "💡", n: "bulb idea tip" }, { e: "🎯", n: "target bullseye goal" },
        { e: "🚀", n: "rocket launch ship" }, { e: "🎉", n: "tada party confetti" }, { e: "💯", n: "100 hundred perfect" },
        { e: "❤️", n: "red heart love" }, { e: "🩵", n: "light blue heart sea" }, { e: "💜", n: "purple heart" },
        { e: "🖤", n: "black heart" }, { e: "⭐", n: "star favorite" }, { e: "🌟", n: "glowing star" },
        { e: "✅", n: "check done yes green" }, { e: "❌", n: "cross x no wrong" }, { e: "⚠️", n: "warning caution alert" },
        { e: "📌", n: "pin pushpin" }, { e: "📎", n: "paperclip attach" }, { e: "📁", n: "folder directory" },
        { e: "📝", n: "memo note edit" }, { e: "🔒", n: "lock secure private" }, { e: "🔑", n: "key password auth" },
        { e: "🔧", n: "wrench tool fix" }, { e: "🐛", n: "bug issue debug" }, { e: "💻", n: "laptop computer code" },
        { e: "🎮", n: "gamepad gaming controller" }, { e: "🎧", n: "headphones music audio" }, { e: "🎵", n: "music note song" },
        { e: "📸", n: "camera screenshot photo" }, { e: "🌊", n: "wave ocean sea" }, { e: "☕", n: "coffee caffeine" },
        { e: "→", n: "arrow right" }, { e: "←", n: "arrow left" }, { e: "↑", n: "arrow up" },
        { e: "↓", n: "arrow down" }, { e: "↔", n: "arrow both" }, { e: "⌘", n: "command cmd meta" },
        { e: "⌥", n: "option alt" }, { e: "⇧", n: "shift" }, { e: "⏎", n: "return enter" },
        { e: "✓", n: "checkmark tick" }, { e: "✕", n: "multiply close x" }, { e: "•", n: "bullet dot" },
        { e: "·", n: "middle dot interpunct" }, { e: "—", n: "em dash" }, { e: "…", n: "ellipsis dots" },
        { e: "≈", n: "approx roughly" }, { e: "≠", n: "not equal" }, { e: "≤", n: "less equal" },
        { e: "≥", n: "greater equal" }, { e: "°", n: "degree temp" }, { e: "±", n: "plus minus" },
        { e: "€", n: "euro currency" }, { e: "£", n: "pound currency" }, { e: "¥", n: "yen currency" }
    ]

    readonly property var filteredHistory: {
        var q = root.query.trim().toLowerCase();
        if (!q) return root.history;
        return root.history.filter(function (it) {
            return (it.preview || "").toLowerCase().indexOf(q) >= 0 || (it.kind || "").indexOf(q) >= 0;
        });
    }
    readonly property var filteredPins: {
        var q = root.query.trim().toLowerCase();
        if (!q) return root.pins;
        return root.pins.filter(function (p) { return (p.text || "").toLowerCase().indexOf(q) >= 0 });
    }
    readonly property var filteredEmoji: {
        var q = root.query.trim().toLowerCase();
        if (!q) return root.emojiList;
        return root.emojiList.filter(function (it) {
            return it.n.indexOf(q) >= 0 || it.e.indexOf(q) >= 0;
        });
    }

    property var openOn: null
    function open(startTab) {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        if (startTab === "history" || startTab === "pins" || startTab === "emoji") root.tab = startTab;
        root.query = "";
        root.sel = 0;
        root.shown = true;
        root.refresh();
    }
    function close() {
        if (!root.shown) return;
        root.shown = false;
        root.closed();
    }
    function toggle(startTab) {
        if (root.shown && (!startTab || root.tab === startTab)) root.close();
        else root.open(startTab || "history");
    }

    function refresh() {
        root.loading = true;
        listProc.running = false;
        listProc.running = true;
    }

    Process {
        id: listProc
        command: ["python3", root.clipScript, "list", "--limit", "80"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.loading = false;
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.items) root.history = j.items;
                    if (j && j.pins) root.pins = j.pins;
                } catch (e) {}
            }
        }
    }

    function copyHistory(id) {
        Quickshell.execDetached(["python3", root.clipScript, "copy", "" + id]);
        root.close();
    }
    function deleteHistory(id) {
        Quickshell.execDetached(["python3", root.clipScript, "delete", "" + id]);
        root.history = root.history.filter(function (x) { return x.id !== id });
        if (root.sel >= root.filteredHistory.length) root.sel = Math.max(0, root.filteredHistory.length - 1);
    }
    function pinHistory(id) {
        Quickshell.execDetached(["python3", root.clipScript, "pin-entry", "" + id]);
        refreshDelay.restart();
    }
    function clearHistory() {
        Quickshell.execDetached(["python3", root.clipScript, "clear"]);
        root.history = [];
        root.sel = 0;
    }
    function copyPin(pid) {
        Quickshell.execDetached(["python3", root.clipScript, "pin-copy", "" + pid]);
        root.close();
    }
    function removePin(pid) {
        Quickshell.execDetached(["python3", root.clipScript, "pin-remove", "" + pid]);
        root.pins = root.pins.filter(function (x) { return x.id !== pid });
    }
    function addPin(txt) {
        var t = (txt || "").trim();
        if (!t) return;
        Quickshell.execDetached(["python3", root.clipScript, "pin-add", t]);
        root.newPinDraft = "";
        refreshDelay.restart();
    }
    function copyEmoji(ch) {
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", ch]);
        root.close();
    }
    Timer { id: refreshDelay; interval: 220; onTriggered: root.refresh() }

    function activateSelected() {
        if (root.tab === "history") {
            var it = root.filteredHistory[root.sel];
            if (it) root.copyHistory(it.id);
        } else if (root.tab === "pins") {
            var p = root.filteredPins[root.sel];
            if (p) root.copyPin(p.id);
        } else if (root.tab === "emoji") {
            var e = root.filteredEmoji[root.sel];
            if (e) root.copyEmoji(e.e);
        }
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
            WlrLayershell.namespace: "sea-shell:clipboard"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            // Dimmed backdrop; click outside dismisses
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.42)
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(640, (win.width / win.ui) - 48)
                height: Math.min(560, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; searchIn.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                MouseArea { anchors.fill: parent } // swallow backdrop clicks

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    // ---- Header: title + tabs + clear ----
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Sym { text: "content_paste"; sz: 18; color: Tok.accent }
                        Text {
                            text: "Clipboard"
                            color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold
                        }
                        Item { Layout.fillWidth: true }
                        Row {
                            spacing: 4
                            Repeater {
                                model: [
                                    { k: "history", l: "History", i: "history",  n: root.history.length },
                                    { k: "pins",    l: "Pinned",  i: "keep",     n: root.pins.length },
                                    { k: "emoji",   l: "Emoji",   i: "mood",     n: 0 }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool cur: root.tab === modelData.k
                                    implicitHeight: 28; implicitWidth: tabRow.implicitWidth + 18; radius: Tok.r
                                    color: cur ? Tok.alpha(Tok.accent, 0.18) : (tabMa.containsMouse ? Tok.raised : Tok.surface)
                                    border.width: 1; border.color: cur ? Tok.alpha(Tok.accent, 0.6) : Tok.rule
                                    Row {
                                        id: tabRow; anchors.centerIn: parent; spacing: 5
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 14; color: cur ? Tok.accent : Tok.ink2 }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.l + (modelData.n > 0 ? " " + modelData.n : "")
                                            color: cur ? Tok.ink : Tok.ink2
                                            font.pixelSize: 12; font.family: Tok.sans; font.weight: cur ? Font.DemiBold : Font.Normal
                                        }
                                    }
                                    MouseArea {
                                        id: tabMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.tab = modelData.k; root.sel = 0; searchIn.forceActiveFocus() }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            visible: root.tab === "history" && root.history.length > 0
                            implicitHeight: 28; implicitWidth: clrTxt.implicitWidth + 16; radius: Tok.r
                            color: clrMa.containsMouse ? Tok.critWash : Tok.surface
                            border.width: 1; border.color: clrMa.containsMouse ? Tok.crit : Tok.rule
                            Text { id: clrTxt; anchors.centerIn: parent; text: "Clear"; color: clrMa.containsMouse ? Tok.crit : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                            MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.clearHistory() }
                        }
                    }

                    // ---- Search bar ----
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 36
                        radius: Tok.r
                        color: Tok.sunken
                        border.width: 1
                        border.color: searchIn.activeFocus ? Tok.accent : Tok.rule
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                            Sym { text: "search"; sz: 16; color: Tok.ink3 }
                            TextInput {
                                id: searchIn
                                Layout.fillWidth: true
                                color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans
                                selectByMouse: true; clip: true
                                text: root.query
                                onTextChanged: { root.query = text; root.sel = 0 }
                                Text {
                                    visible: searchIn.text.length === 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.tab === "emoji" ? "Search emojis & symbols…" : (root.tab === "pins" ? "Filter pinned snippets…" : "Search clipboard history…")
                                    color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                                }
                                Keys.onEscapePressed: root.close()
                                Keys.onReturnPressed: root.activateSelected()
                                Keys.onEnterPressed: root.activateSelected()
                                Keys.onTabPressed: {
                                    var order = ["history", "pins", "emoji"];
                                    root.tab = order[(order.indexOf(root.tab) + 1) % order.length];
                                    root.sel = 0;
                                }
                                Keys.onDownPressed: {
                                    var n = root.tab === "history" ? root.filteredHistory.length : (root.tab === "pins" ? root.filteredPins.length : root.filteredEmoji.length);
                                    if (n > 0) root.sel = Math.min(n - 1, root.sel + (root.tab === "emoji" ? 8 : 1));
                                }
                                Keys.onUpPressed: {
                                    root.sel = Math.max(0, root.sel - (root.tab === "emoji" ? 8 : 1));
                                }
                                Keys.onRightPressed: {
                                    if (root.tab === "emoji" && root.query.length === 0)
                                        root.sel = Math.min(root.filteredEmoji.length - 1, root.sel + 1);
                                }
                                Keys.onLeftPressed: {
                                    if (root.tab === "emoji" && root.query.length === 0)
                                        root.sel = Math.max(0, root.sel - 1);
                                }
                                Keys.onDeletePressed: {
                                    if (root.tab === "history" && root.filteredHistory[root.sel])
                                        root.deleteHistory(root.filteredHistory[root.sel].id);
                                    else if (root.tab === "pins" && root.filteredPins[root.sel])
                                        root.removePin(root.filteredPins[root.sel].id);
                                }
                            }
                        }
                    }

                    // ---- Add custom snippet bar (Pinned tab only) ----
                    RowLayout {
                        visible: root.tab === "pins"
                        Layout.fillWidth: true
                        spacing: 6
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                            color: Tok.surface; border.width: 1; border.color: pinAddIn.activeFocus ? Tok.accent : Tok.rule
                            TextInput {
                                id: pinAddIn
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; clip: true
                                text: root.newPinDraft
                                onTextChanged: root.newPinDraft = text
                                Keys.onReturnPressed: root.addPin(text)
                                Keys.onEscapePressed: searchIn.forceActiveFocus()
                            }
                            Text {
                                visible: pinAddIn.text.length === 0
                                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                text: "Add a reusable snippet (command, email, template) and press Enter…"
                                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                            }
                        }
                        Rectangle {
                            implicitHeight: 32; implicitWidth: 64; radius: Tok.r
                            color: pinAddBtnMa.containsMouse ? Tok.accent : Tok.alpha(Tok.accent, 0.85)
                            Text { anchors.centerIn: parent; text: "Pin"; color: Tok.accentInk; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold }
                            MouseArea { id: pinAddBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.addPin(pinAddIn.text) }
                        }
                    }

                    // ---- Content Area ----
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        // TAB 1: HISTORY (with real image thumbnails!)
                        ListView {
                            id: histView
                            visible: root.tab === "history"
                            anchors.fill: parent
                            clip: true
                            spacing: 6
                            model: root.filteredHistory
                            currentIndex: root.sel
                            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

                            delegate: Rectangle {
                                id: hRow
                                required property var modelData
                                required property int index
                                readonly property bool isSel: index === root.sel
                                readonly property bool isImg: modelData.kind === "image" && modelData.thumb !== ""
                                width: histView.width
                                height: isImg ? 76 : 46
                                radius: Tok.r
                                color: isSel ? Tok.alpha(Tok.accent, 0.14) : (hMa.containsMouse ? Tok.raised : Tok.surface)
                                border.width: 1
                                border.color: isSel ? Tok.alpha(Tok.accent, 0.65) : Tok.rule

                                MouseArea {
                                    id: hMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onEntered: root.sel = hRow.index
                                    onClicked: root.copyHistory(hRow.modelData.id)
                                }

                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 10
                                    // Visual preview: image thumbnail, color swatch, or kind icon
                                    Rectangle {
                                        visible: hRow.isImg
                                        Layout.preferredWidth: 92; Layout.preferredHeight: 60
                                        radius: Tok.rSmall; color: Tok.sunken; border.width: 1; border.color: Tok.rule; clip: true
                                        Image {
                                            anchors.fill: parent
                                            source: hRow.isImg ? Tok.fileUrl(hRow.modelData.thumb) : ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true; cache: false
                                            sourceSize.width: 184; sourceSize.height: 120
                                        }
                                    }
                                    Rectangle {
                                        visible: !hRow.isImg && hRow.modelData.kind === "color"
                                        Layout.preferredWidth: 26; Layout.preferredHeight: 26
                                        radius: Tok.rSmall; color: hRow.modelData.preview; border.width: 1; border.color: Tok.ruleHard
                                    }
                                    Sym {
                                        visible: !hRow.isImg && hRow.modelData.kind !== "color"
                                        text: hRow.modelData.kind === "url" ? "link" : "notes"
                                        sz: 16; color: hRow.isSel ? Tok.accent : Tok.ink3
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 2
                                        Text {
                                            Layout.fillWidth: true
                                            text: hRow.modelData.preview || ""
                                            color: Tok.ink; font.pixelSize: 12
                                            font.family: hRow.modelData.kind === "color" ? Tok.mono : Tok.sans
                                            font.weight: hRow.isSel ? Font.Medium : Font.Normal
                                            elide: Text.ElideRight
                                            maximumLineCount: hRow.isImg ? 1 : 2
                                            wrapMode: hRow.isImg ? Text.NoWrap : Text.WrapAnywhere
                                        }
                                        Text {
                                            visible: hRow.isImg
                                            text: (hRow.modelData.ext || "IMG") + " · Click or Enter to copy"
                                            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono
                                        }
                                    }

                                    // Pin button (text entries)
                                    Rectangle {
                                        visible: !hRow.isImg && (hMa.containsMouse || hRow.isSel)
                                        Layout.preferredWidth: 26; Layout.preferredHeight: 26; radius: Tok.rSmall
                                        color: hpMa.containsMouse ? Tok.alpha(Tok.accent, 0.2) : "transparent"
                                        Sym { anchors.centerIn: parent; text: "keep"; sz: 15; color: hpMa.containsMouse ? Tok.accent : Tok.ink2 }
                                        MouseArea { id: hpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.pinHistory(hRow.modelData.id) }
                                    }
                                    // Delete button
                                    Rectangle {
                                        visible: hMa.containsMouse || hRow.isSel
                                        Layout.preferredWidth: 26; Layout.preferredHeight: 26; radius: Tok.rSmall
                                        color: hdMa.containsMouse ? Tok.critWash : "transparent"
                                        Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: hdMa.containsMouse ? Tok.crit : Tok.ink3 }
                                        MouseArea { id: hdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.deleteHistory(hRow.modelData.id) }
                                    }
                                }
                            }

                            Text {
                                visible: root.filteredHistory.length === 0 && !root.loading
                                anchors.centerIn: parent
                                text: root.query ? "No clipboard matches" : "Clipboard history is empty"
                                color: Tok.ink3; font.pixelSize: 13; font.family: Tok.sans
                            }
                        }

                        // TAB 2: PINNED SNIPPETS
                        ListView {
                            id: pinView
                            visible: root.tab === "pins"
                            anchors.fill: parent
                            clip: true
                            spacing: 6
                            model: root.filteredPins
                            currentIndex: root.sel

                            delegate: Rectangle {
                                id: pRow
                                required property var modelData
                                required property int index
                                readonly property bool isSel: index === root.sel
                                width: pinView.width; height: 46; radius: Tok.r
                                color: isSel ? Tok.alpha(Tok.accent, 0.14) : (pMa.containsMouse ? Tok.raised : Tok.surface)
                                border.width: 1; border.color: isSel ? Tok.alpha(Tok.accent, 0.65) : Tok.rule
                                MouseArea {
                                    id: pMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onEntered: root.sel = pRow.index
                                    onClicked: root.copyPin(pRow.modelData.id)
                                }
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 10
                                    Sym { text: "keep"; sz: 15; color: Tok.accent }
                                    Text {
                                        Layout.fillWidth: true; text: pRow.modelData.text || ""
                                        color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
                                        elide: Text.ElideRight; maximumLineCount: 2
                                    }
                                    Rectangle {
                                        visible: pMa.containsMouse || pRow.isSel
                                        Layout.preferredWidth: 26; Layout.preferredHeight: 26; radius: Tok.rSmall
                                        color: prMa.containsMouse ? Tok.critWash : "transparent"
                                        Sym { anchors.centerIn: parent; text: "close"; sz: 15; color: prMa.containsMouse ? Tok.crit : Tok.ink3 }
                                        MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: root.removePin(pRow.modelData.id) }
                                    }
                                }
                            }

                            Text {
                                visible: root.filteredPins.length === 0
                                anchors.centerIn: parent
                                text: "No pinned snippets yet — pin items from History or add one above"
                                color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                            }
                        }

                        // TAB 3: EMOJI & SYMBOLS GRID
                        GridView {
                            id: emojiView
                            visible: root.tab === "emoji"
                            anchors.fill: parent
                            clip: true
                            cellWidth: Math.floor(width / 8)
                            cellHeight: 52
                            model: root.filteredEmoji
                            currentIndex: root.sel

                            delegate: Item {
                                required property var modelData
                                required property int index
                                width: emojiView.cellWidth; height: emojiView.cellHeight
                                readonly property bool isSel: index === root.sel
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: 3; radius: Tok.r
                                    color: isSel ? Tok.alpha(Tok.accent, 0.20) : (emMa.containsMouse ? Tok.raised : Tok.surface)
                                    border.width: 1; border.color: isSel ? Tok.accent : Tok.rule
                                    Text { anchors.centerIn: parent; text: modelData.e; font.pixelSize: 22 }
                                    MouseArea {
                                        id: emMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onEntered: root.sel = index
                                        onClicked: root.copyEmoji(modelData.e)
                                    }
                                }
                            }
                        }
                    }

                    // ---- Footer hint ----
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "⏎ copy · Tab switch · Del remove · Esc close"
                            color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.tab === "emoji" && root.filteredEmoji[root.sel]
                            text: (root.filteredEmoji[root.sel] && root.filteredEmoji[root.sel].n) || ""
                            color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono
                        }
                    }
                }
            }
        }
    }
}
