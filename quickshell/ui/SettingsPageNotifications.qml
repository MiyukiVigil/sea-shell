// Settings → Notifications. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 24
    visible: root.tab === 24; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "notifications"
        badgeColor: "#FF3B30"
        title: "Notifications & Focus"
        description: "Schedule Quiet Hours, toggle Do Not Disturb, switch Focus profiles, and manage muted apps."
    }

    Section { title: "Quiet hours"; icon: "bedtime" }
    ToggleCard { icon: "schedule"; title: "On a schedule"
        desc: "Popups stay away during these hours. Everything still lands in the notification list, and urgent ones still come through."
        on: root.quietCfg.enabled; onToggled: root.setQuiet("enabled", !root.quietCfg.enabled) }
    RowLayout { visible: root.quietCfg.enabled; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Sym { text: "schedule"; sz: 18; color: theme.sub }
        Text { text: "From"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }
        Rectangle { implicitWidth: 68; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: qFrom.activeFocus ? theme.iris : "transparent"
            TextInput { id: qFrom; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                color: theme.text; font.pixelSize: 13; font.family: Tok.sans; inputMask: "99:99;_"; text: root.quietCfg.from
                onEditingFinished: root.setQuiet("from", text) } }
        Text { text: "to"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans }
        Rectangle { implicitWidth: 68; implicitHeight: 32; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: qTo.activeFocus ? theme.iris : "transparent"
            TextInput { id: qTo; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                color: theme.text; font.pixelSize: 13; font.family: Tok.sans; inputMask: "99:99;_"; text: root.quietCfg.to
                onEditingFinished: root.setQuiet("to", text) } }
        Item { Layout.fillWidth: true } }
    ToggleCard { icon: "screen_share"; title: "While sharing or recording your screen"
        desc: "So nothing private pops up in front of whoever is watching."
        on: root.quietCfg.share; onToggled: root.setQuiet("share", !root.quietCfg.share) }

    Section { title: "Do not disturb"; icon: "do_not_disturb_on" }
    ToggleCard { icon: "do_not_disturb_on"; title: "On now"
        desc: "Stays on until you turn it off. The same switch as in the bar."
        on: root.dndOn
        onToggled: Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "shell", "setDnd", root.dndOn ? "false" : "true"]) }

    Section { title: "Focus profiles"; icon: "blur_on" }
    Text {
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        wrapMode: Text.WordWrap
        text: "Coding, Gaming and Meeting set DND, mute noisy apps, caffeine, and open the right dashboard. Clear puts your previous mute list back."
        color: theme.faint
        font.pixelSize: 11
        font.family: Tok.sans
    }
    Flow {
        Layout.fillWidth: true
        Layout.leftMargin: 16
        Layout.rightMargin: 16
        spacing: 8
        Repeater {
            model: [
                { id: "coding", l: "Coding", i: "code" },
                { id: "gaming", l: "Gaming", i: "sports_esports" },
                { id: "meeting", l: "Meeting", i: "videocam" },
                { id: "clear", l: "Clear", i: "blur_off" }
            ]
            delegate: Chip {
                label: modelData.l
                icon: modelData.i
                on: root.focusActive === modelData.id
                    || (modelData.id === "clear" && !root.focusActive)
                onPicked: Quickshell.execDetached([
                    "qs", "-c", "sea-shell", "ipc", "call", "shell", "applyFocus", modelData.id
                ])
            }
        }
    }

    Section { title: "Muted apps"; icon: "notifications_off" }
    Text { visible: root.mutedList.length === 0; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
        text: "Nothing muted. Point at an app in the notification list and press its bell to mute it."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
    Repeater { model: root.mutedList
        delegate: RowLayout { required property string modelData
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
            Sym { text: "notifications_off"; sz: 18; color: theme.sub }
            Text { Layout.fillWidth: true; text: modelData; elide: Text.ElideRight; color: theme.text; font.pixelSize: 13; font.family: Tok.sans }
            Chip { label: "Unmute"; on: false
                onPicked: Quickshell.execDetached(["qs", "-c", "sea-shell", "ipc", "call", "shell", "toggleMute", modelData]) } } }
}
