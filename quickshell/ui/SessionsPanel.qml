// sea-shell — Workspace App Sessions (Super+Alt+L).
// Snapshot currently open Hyprland apps + workspace assignments as named bundles
// and relaunch an entire workspace setup in one click.
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

    readonly property string script: Qt.resolvedUrl("sea-sessions.py").toString().replace("file://", "")
    property var openOn: null
    property var sessions: []
    property string draftName: ""

    function open() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        root.shown = true;
        root.refresh();
    }
    function close() { if (!root.shown) return; root.shown = false; root.closed(); }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    function refresh() { listProc.running = false; listProc.running = true; }
    Timer { id: refreshLater; interval: 320; onTriggered: root.refresh() }

    Process {
        id: listProc
        command: ["python3", root.script, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.sessions) root.sessions = j.sessions;
                } catch (e) {}
            }
        }
    }

    function capture(name) {
        var n = ("" + (name || "")).trim() || "Workspace Session";
        Quickshell.execDetached(["python3", root.script, "capture", n]);
        root.draftName = "";
        refreshLater.restart();
    }
    function launch(id) {
        Quickshell.execDetached(["python3", root.script, "launch", id]);
        root.close();
    }
    function remove(id) {
        Quickshell.execDetached(["python3", root.script, "delete", id]);
        root.sessions = root.sessions.filter(function (s) { return s.id !== id });
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
            WlrLayershell.namespace: "sea-shell:sessions"
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
                height: Math.min(480, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; nameIn.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                MouseArea { anchors.fill: parent }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Sym { text: "workspaces"; sz: 18; color: Tok.accent }
                        Text { text: "Workspace sessions"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        Text { text: root.sessions.length + " saved"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono }
                    }

                    // ---- Save current open apps as a new bundle ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                            color: Tok.sunken; border.width: 1; border.color: nameIn.activeFocus ? Tok.accent : Tok.rule
                            TextInput {
                                id: nameIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
                                text: root.draftName; onTextChanged: root.draftName = text
                                Text { visible: nameIn.text.length === 0; anchors.verticalCenter: parent.verticalCenter; text: "Name current layout (e.g. FYP Dev, Study, Gaming)…"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                                Keys.onReturnPressed: root.capture(text)
                                Keys.onEscapePressed: root.close()
                            }
                        }
                        Rectangle {
                            implicitHeight: 34; implicitWidth: capRow.implicitWidth + 20; radius: Tok.r
                            color: capMa.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent
                            Row { id: capRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "save"; sz: 15; color: Tok.accentInk }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Snapshot"; color: Tok.accentInk; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold } }
                            MouseArea { id: capMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.capture(nameIn.text) }
                        }
                    }

                    // ---- Saved sessions list ----
                    ListView {
                        id: sesView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 8
                        model: root.sessions

                        delegate: Rectangle {
                            id: sCard
                            required property var modelData
                            width: sesView.width
                            implicitHeight: sCol.implicitHeight + 20
                            radius: Tok.r
                            color: sCardMa.containsMouse ? Tok.raised : Tok.surface
                            border.width: 1; border.color: Tok.rule
                            MouseArea { id: sCardMa; anchors.fill: parent; hoverEnabled: true }

                            ColumnLayout {
                                id: sCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                                spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    Text { text: sCard.modelData.name || "Session"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    Rectangle {
                                        implicitHeight: 26; implicitWidth: lnRow.implicitWidth + 16; radius: Tok.rSmall
                                        color: lnMa.containsMouse ? Tok.accent : Tok.alpha(Tok.accent, 0.18)
                                        Row { id: lnRow; anchors.centerIn: parent; spacing: 4
                                            Sym { anchors.verticalCenter: parent.verticalCenter; text: "play_arrow"; sz: 15; color: lnMa.containsMouse ? Tok.accentInk : Tok.accent }
                                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Launch"; color: lnMa.containsMouse ? Tok.accentInk : Tok.ink; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium } }
                                        MouseArea { id: lnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.launch(sCard.modelData.id) }
                                    }
                                    Rectangle {
                                        implicitWidth: 26; implicitHeight: 26; radius: Tok.rSmall
                                        color: delMa.containsMouse ? Tok.critWash : "transparent"
                                        Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: delMa.containsMouse ? Tok.crit : Tok.ink3 }
                                        MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.remove(sCard.modelData.id) }
                                    }
                                }
                                Flow {
                                    Layout.fillWidth: true; spacing: 5
                                    Repeater {
                                        model: sCard.modelData.apps || []
                                        delegate: Rectangle {
                                            required property var modelData
                                            implicitHeight: 22; implicitWidth: apT.implicitWidth + 12; radius: Tok.rSmall
                                            color: Tok.sunken; border.width: 1; border.color: Tok.rule
                                            Text { id: apT; anchors.centerIn: parent; text: "WS " + modelData.ws + " · " + modelData.label; color: Tok.ink2; font.pixelSize: 10; font.family: Tok.mono }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.sessions.length === 0
                            anchors.centerIn: parent
                            text: "No saved sessions yet — name your current layout above and click Snapshot"
                            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                        }
                    }

                    Text { text: "Captures mapped windows per workspace and launches them silently into their slots · Esc close"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                }
            }
        }
    }
}
