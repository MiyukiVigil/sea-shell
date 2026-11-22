// Settings → Input. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 15
    visible: root.tab === 15; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "mouse"
        badgeColor: "#636366"
        title: "Mouse & Trackpad"
        description: "Adjust pointer speed, acceleration profile, scrolling direction, tap-to-click, palm rejection, and multi-finger touchpad gestures."
    }

    Section { title: "Mouse"; icon: "mouse" }
    SliderRow {
        icon: "speed"; label: "Sensitivity"
        value: (root.apMouseSens + 1) / 2      // -1..1 mapped onto the 0..1 track
        readout: (root.apMouseSens >= 0 ? "+" : "") + root.apMouseSens.toFixed(2)
        onMoved: (v) => { root.apMouseSens = Math.round((v * 2 - 1) * 100) / 100
                          root.saveAppearance(); root.applyInput() }
    }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        Text { text: "Accel"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 76 }
        Repeater {
            model: [ { v: "",         l: "default" },
                     { v: "adaptive", l: "adaptive" },
                     { v: "flat",     l: "flat" } ]
            delegate: Chip {
                required property var modelData
                label: modelData.l; on: root.apAccelProfile === modelData.v
                onPicked: { root.apAccelProfile = modelData.v; root.saveAppearance(); root.applyInput() }
            }
        }
        Item { Layout.fillWidth: true }
    }
    ToggleCard {
        icon: "swap_vert"; title: "Natural scrolling"
        desc: "Invert mouse wheel direction"
        on: root.apMouseNatural
        onToggled: { root.apMouseNatural = !root.apMouseNatural; root.saveAppearance(); root.applyInput() }
    }

    Section { title: "Touchpad"; icon: "touch_app" }
    ToggleCard {
        icon: "swap_vert"; title: "Natural scrolling"
        desc: "Content follows your fingers"
        on: root.apTpNatural
        onToggled: { root.apTpNatural = !root.apTpNatural; root.saveAppearance(); root.applyInput() }
    }
    SliderRow {
        icon: "unfold_more"; label: "Scroll speed"
        value: Math.min(1, root.apTpScroll / 3)
        readout: root.apTpScroll.toFixed(2) + "×"
        onMoved: (v) => { root.apTpScroll = Math.max(0.1, Math.round(v * 3 * 100) / 100)
                          root.saveAppearance(); root.applyInput() }
    }
    ToggleCard {
        icon: "ads_click"; title: "Tap to click"
        on: root.apTpTap
        onToggled: { root.apTpTap = !root.apTpTap; root.saveAppearance(); root.applyInput() }
    }
    ToggleCard {
        icon: "edit_off"; title: "Disable while typing"
        desc: "Ignore the touchpad mid-keystroke so a stray palm can't move the caret"
        on: root.apTpDwt
        onToggled: { root.apTpDwt = !root.apTpDwt; root.saveAppearance(); root.applyInput() }
    }

    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.topMargin: 4
        wrapMode: Text.WordWrap
        text: "applied live via hyprctl eval, and re-applied at login — an eval only lasts as long as the current hyprland session"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    // ---- touchpad gestures ----
    Section { title: "Gestures"; icon: "gesture" }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        wrapMode: Text.WordWrap
        text: "Swipe on the touchpad to do something. Hyprland allows one gesture per "
            + "finger-count + direction pair, so a second one on the same pair never fires."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }
    IndTable {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 30
        rows: root.gsRows
        selectable: true
        selectedIndex: root.gsSel
        emptyText: "No gestures yet. Hyprland ships none by default."
        columns: [
            { label: "Fingers",   key: "fing", w: 90,  mono: true },
            { label: "Direction", key: "dir",  w: 110 },
            { label: "Does",      key: "act",  w: 120 },
            { label: "",          key: "note", flex: true }
        ]
        onActivated: (i, row) => root.gsSel = i
    }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        IndBtn { text: "Add gesture"; rank: "primary"; onActivated: root.gsAdd() }
        IndBtn { text: "Delete"; rank: "danger"; enabled: root.gsSel >= 0
            onActivated: root.gsDel(root.gsSel) }
        Item { Layout.fillWidth: true }
    }
    ColumnLayout {
        id: gsEdit
        visible: root.gsSel >= 0 && root.gsSel < root.gsList.length
        Layout.fillWidth: true; spacing: 8
        readonly property var g: (root.gsSel >= 0 && root.gsSel < root.gsList.length)
                                  ? root.gsList[root.gsSel] : ({})
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
            Text { text: "Fingers"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 68 }
            Repeater { model: [2,3,4,5]
                delegate: Chip { required property var modelData
                    label: "" + modelData; on: gsEdit.g.fingers === modelData
                    onPicked: root.gsSet(root.gsSel, "fingers", modelData) } }
            Item { Layout.fillWidth: true }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
            Text { text: "Direction"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 68 }
            Flow { Layout.fillWidth: true; spacing: 6
                Repeater { model: root.gsDirs
                    delegate: Chip { required property var modelData
                        label: modelData; on: gsEdit.g.direction === modelData
                        onPicked: root.gsSet(root.gsSel, "direction", modelData) } } }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
            Text { text: "Action"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 68 }
            Flow { Layout.fillWidth: true; spacing: 6
                Repeater { model: root.gsActions
                    delegate: Chip { required property var modelData
                        label: modelData; on: gsEdit.g.action === modelData
                        onPicked: root.gsSet(root.gsSel, "action", modelData) } } }
        }
    }
}
