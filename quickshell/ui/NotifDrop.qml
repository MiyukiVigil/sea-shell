// sea-shell — Notification Centre dropdown body (extracted from shell.qml).
// Supports per-app Mute rules AND per-app Priority rules (bypass DND), undoable dismiss,
// and full keyboard navigation (↑↓ move · ⏎ expand · Del dismiss · M mute · P priority).
import QtQuick

Column {
    id: nd
    property var shellRoot: null
    property bool shown: false
    spacing: 4

    onShownChanged: {
        if (shellRoot) {
            shellRoot.notifCursor = -1;
            shellRoot.notifOpen = ({});
        }
    }

    // Header
    Item {
        width: parent.width; height: 28
        Text {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left }
            text: "Notifications"; color: Tok.ink; font.pixelSize: 15; font.family: Tok.sans; font.bold: true
        }
        Row {
            anchors { verticalCenter: parent.verticalCenter; right: parent.right }
            spacing: 6
            // Do Not Disturb toggle
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: dndRow.width + 16; height: 22; radius: Tok.r
                readonly property bool sil: !!(shellRoot && shellRoot.silenced)
                color: sil ? Tok.alpha(Tok.warn, 0.20) : (dndMa.containsMouse ? Tok.raised : Tok.surface)
                border.width: 1; border.color: sil ? Tok.alpha(Tok.warn, 0.55) : Tok.rule
                Row {
                    id: dndRow; anchors.centerIn: parent; spacing: 4
                    Sym { anchors.verticalCenter: parent.verticalCenter; text: parent.parent.sil ? "do_not_disturb_on" : "do_not_disturb_off"; sz: 13; color: parent.parent.sil ? Tok.warn : Tok.ink2 }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (shellRoot && shellRoot.quietNow && !shellRoot.dnd) ? "Quiet" : "DND"
                        color: parent.parent.sil ? Tok.warn : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans; font.bold: !!(shellRoot && shellRoot.dnd)
                    }
                }
                MouseArea { id: dndMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.toggleSilence() }
            }
            // Clear all
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: !!(shellRoot && shellRoot.notes.length > 0)
                width: clrTxt.implicitWidth + 16; height: 22; radius: Tok.r
                color: clrMa.containsMouse ? Tok.critWash : Tok.surface
                border.width: 1; border.color: clrMa.containsMouse ? Tok.crit : Tok.rule
                Text { id: clrTxt; anchors.centerIn: parent; text: "Clear all"; color: clrMa.containsMouse ? Tok.crit : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.noteClear() }
            }
        }
    }

    Rectangle { width: parent.width; height: 1; color: Tok.rule }
    Item { height: 2; width: 1 }

    // ---- Muted apps chips ----
    Column {
        width: parent.width; spacing: 5; visible: !!(shellRoot && shellRoot.mutedApps.length > 0)
        Text { text: "Muted apps"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
        Flow {
            width: parent.width; spacing: 5
            Repeater {
                model: shellRoot ? shellRoot.mutedApps : []
                delegate: Rectangle {
                    required property var modelData
                    height: 20; radius: Tok.r; width: mchip.implicitWidth + 16
                    color: mchMa.containsMouse ? Tok.alpha(Tok.warn, 0.22) : Tok.alpha(Tok.warn, 0.13)
                    border.width: 1; border.color: Tok.alpha(Tok.warn, 0.35)
                    Row {
                        id: mchip; anchors.centerIn: parent; spacing: 4
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "notifications_off"; sz: 11; color: Tok.warn }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "close"; sz: 11; color: Tok.ink3 }
                    }
                    MouseArea { id: mchMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.toggleMute(modelData) }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Tok.rule }
    }

    // ---- Priority apps (bypass DND) chips ----
    Column {
        width: parent.width; spacing: 5; visible: !!(shellRoot && shellRoot.priorityApps.length > 0)
        Text { text: "Priority · bypass DND"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
        Flow {
            width: parent.width; spacing: 5
            Repeater {
                model: shellRoot ? shellRoot.priorityApps : []
                delegate: Rectangle {
                    required property var modelData
                    height: 20; radius: Tok.r; width: pchip.implicitWidth + 16
                    color: pchMa.containsMouse ? Tok.alpha(Tok.accent, 0.24) : Tok.alpha(Tok.accent, 0.14)
                    border.width: 1; border.color: Tok.alpha(Tok.accent, 0.45)
                    Row {
                        id: pchip; anchors.centerIn: parent; spacing: 4
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "star"; sz: 11; color: Tok.accent }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData; color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans }
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "close"; sz: 11; color: Tok.ink3 }
                    }
                    MouseArea { id: pchMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.togglePriority(modelData) }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Tok.rule }
    }

    // ---- Undo banner ----
    Rectangle {
        visible: !!(shellRoot && shellRoot.noteUndo)
        width: parent.width; height: 32; radius: Tok.r
        color: Tok.alpha(Tok.ink, 0.06)
        Text {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            text: (shellRoot && shellRoot.noteUndo) ? shellRoot.noteUndo.label : ""
            color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
        }
        Text {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            text: "Undo"; color: Tok.accent; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.DemiBold
            MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.noteUndoNow() }
        }
    }

    Text {
        visible: !!(shellRoot && shellRoot.notes.length === 0)
        text: "No notifications"; color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans; topPadding: 4
    }

    // ---- Grouped notification list ----
    Flickable {
        id: notifFlick
        width: parent.width
        height: Math.min(390, listCol.implicitHeight)
        contentHeight: listCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: !!(shellRoot && shellRoot.notes.length > 0)
        focus: nd.shown
        Keys.onPressed: (e) => {
            if (!shellRoot) return;
            var n = shellRoot.noteGroups.length, c = shellRoot.notifCursor;
            if (e.key === Qt.Key_Z && (e.modifiers & Qt.ControlModifier)) { shellRoot.noteUndoNow(); e.accepted = true; return }
            if (!n) return;
            if (e.key === Qt.Key_Down) { shellRoot.notifCursor = c < 0 ? 0 : Math.min(n - 1, c + 1) }
            else if (e.key === Qt.Key_Up) { shellRoot.notifCursor = c < 0 ? 0 : Math.max(0, c - 1) }
            else if (c < 0) return;
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
                var app = shellRoot.noteGroups[c].app, o = Object.assign({}, shellRoot.notifOpen); o[app] = !o[app]; shellRoot.notifOpen = o;
            }
            else if (e.key === Qt.Key_Delete) {
                shellRoot.noteRemoveApp(shellRoot.noteGroups[c].app); shellRoot.notifCursor = Math.min(c, shellRoot.noteGroups.length - 1);
            }
            else if (e.key === Qt.Key_M) shellRoot.toggleMute(shellRoot.noteGroups[c].app)
            else if (e.key === Qt.Key_P) shellRoot.togglePriority(shellRoot.noteGroups[c].app)
            else if (e.key === Qt.Key_Escape) shellRoot.openPop = ""
            else return;
            e.accepted = true;
            var it = groupRep.itemAt(shellRoot.notifCursor);
            if (it) notifFlick.contentY = Math.max(0, Math.min(it.y, it.y + it.height - notifFlick.height, notifFlick.contentHeight - notifFlick.height));
        }

        Column {
            id: listCol; width: parent.width; spacing: 8
            Repeater {
                id: groupRep
                model: shellRoot ? shellRoot.noteGroups : []
                delegate: NotifGroup {
                    required property var modelData
                    required property int index
                    width: listCol.width
                    group: modelData
                    expanded: !!(shellRoot && shellRoot.notifOpen[modelData.app])
                    current: !!(shellRoot && shellRoot.notifCursor === index)
                    muted: !!(shellRoot && shellRoot.isMuted(modelData.app))
                    priority: !!(shellRoot && shellRoot.isPriority(modelData.app))
                    isLive: k => shellRoot ? shellRoot.noteLive(k) : false
                    onToggle: { var o = Object.assign({}, shellRoot.notifOpen); o[modelData.app] = !o[modelData.app]; shellRoot.notifOpen = o }
                    onDismissAll: shellRoot.noteRemoveApp(modelData.app)
                    onDismiss: k => shellRoot.noteRemove(k)
                    onMute: shellRoot.toggleMute(modelData.app)
                    onPrioritize: shellRoot.togglePriority(modelData.app)
                    onInvoke: (k, i) => shellRoot.noteInvoke(k, i)
                }
            }
        }
    }
}
