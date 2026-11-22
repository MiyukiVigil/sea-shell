// Settings → WindowRules. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 17
    visible: root.tab === 17; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "picture_in_picture"
        badgeColor: "#5856D6"
        title: "Window Rules"
        description: "Match windows by class or title to automatically float, center, pin, set opacity, or assign a workspace."
        note: "Rules apply when matching applications open a new window."
    }

    Section { title: "Window rules"; icon: "picture_in_picture" }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        wrapMode: Text.WordWrap
        text: "Match a window by class (and optionally title), then change how it opens. "
            + "hyprland applies rules when a window MAPS, so an edit affects the next window "
            + "of that class — windows already open keep what they were given."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }
    IndTable {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 30
        rows: root.wrRows
        selectable: true
        selectedIndex: root.wrSel
        emptyText: "No rules yet. Add one below."
        columns: [
            { label: "Class",  key: "cls", w: 190, mono: true },
            { label: "Title",  key: "ttl", w: 130, mono: true },
            { label: "Does",   key: "act", flex: true }
        ]
        onActivated: (i, row) => root.wrSel = i
    }
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
        IndBtn { text: "Add rule"; rank: "primary"; onActivated: root.wrAdd() }
        IndBtn { text: "Delete"; rank: "danger"; enabled: root.wrSel >= 0
            onActivated: root.wrDel(root.wrSel) }
        Item { Layout.fillWidth: true }
        IndBtn { text: "Re-apply all"; rank: "secondary"; onActivated: root.wrSave() }
    }

    // ---- editor for the selected rule ----
    ColumnLayout {
        id: wrEdit
        visible: root.wrSel >= 0 && root.wrSel < root.wrRules.length
        Layout.fillWidth: true; spacing: 10
        readonly property var r: (root.wrSel >= 0 && root.wrSel < root.wrRules.length)
                                  ? root.wrRules[root.wrSel] : ({})

        Section { title: "Match"; icon: "search" }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            Text { text: "Class"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 54 }
            Rectangle { Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                color: theme.a(theme.line, 0.5); border.width: 1
                border.color: wrC.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                TextInput { id: wrC; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans
                    text: wrEdit.r["class"] || ""
                    onEditingFinished: root.wrSet(root.wrSel, "class", text.trim())
                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrC.text
                        text: "^(firefox)$"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            Text { text: "Title"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 54 }
            Rectangle { Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                color: theme.a(theme.line, 0.5); border.width: 1
                border.color: wrT.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                TextInput { id: wrT; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans
                    text: wrEdit.r.title || ""
                    onEditingFinished: root.wrSet(root.wrSel, "title", text.trim())
                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrT.text
                        text: "optional — e.g. ^(Picture-in-Picture)$"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
        }
        Text {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
            visible: !wrEdit.r["class"] && !wrEdit.r.title
            text: "A rule with no class and no title would match every window — it is skipped until you fill one in."
            color: theme.bad; font.pixelSize: 11; font.family: Tok.sans
        }
        Text {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
            text: "tip: run  hyprctl clients -j | grep class  to find a window's class. open windows right now: "
                  + root.wrOpenClasses
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        }

        Section { title: "Do this"; icon: "bolt" }
        Grid {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            columns: 3; columnSpacing: 8; rowSpacing: 8
            Repeater {
                model: [ { k: "float", l: "float" }, { k: "tile", l: "force tile" },
                         { k: "center", l: "center" }, { k: "pin", l: "pin" },
                         { k: "noblur", l: "no blur" }, { k: "noshadow", l: "no shadow" } ]
                delegate: Rectangle {
                    required property var modelData
                    readonly property var rr: (root.wrSel >= 0 && root.wrSel < root.wrRules.length) ? root.wrRules[root.wrSel] : ({})
                    readonly property bool on: !!rr[modelData.k]
                    width: 150; height: 34; radius: Tok.r
                    color: on ? theme.a(theme.iris, 0.22) : theme.a(theme.line, 0.4)
                    border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.14)
                    Row { anchors.centerIn: parent; spacing: 7
                        Sym { anchors.verticalCenter: parent.verticalCenter
                            text: on ? "check_box" : "check_box_outline_blank"; sz: 15
                            color: on ? theme.iris : theme.sub }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                            color: on ? theme.text : theme.sub; font.pixelSize: 11; font.family: Tok.sans } }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: root.wrSet(root.wrSel, modelData.k, !parent.on) }
                }
            }
        }
        SliderRow {
            icon: "opacity"; label: "Opacity"
            value: {
                var o = wrEdit.r.opacity;
                return (o === undefined || o === null) ? 1 : Math.max(0.2, Math.min(1, o));
            }
            readout: {
                var o = wrEdit.r.opacity;
                return (o === undefined || o >= 1) ? "off" : Number(o).toFixed(2);
            }
            onMoved: (v) => root.wrSet(root.wrSel, "opacity", Math.max(0.2, Math.min(1, v)))
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            Text { text: "Workspace"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 74 }
            Rectangle { implicitWidth: 90; implicitHeight: 30; radius: Tok.r
                color: theme.a(theme.line, 0.5); border.width: 1
                border.color: wrW.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                TextInput { id: wrW; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans
                    text: wrEdit.r.workspace || ""
                    onEditingFinished: root.wrSet(root.wrSel, "workspace", text.trim())
                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrW.text
                        text: "3"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
            Text { text: "Size"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 10 }
            Rectangle { implicitWidth: 120; implicitHeight: 30; radius: Tok.r
                color: theme.a(theme.line, 0.5); border.width: 1
                border.color: wrS.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                TextInput { id: wrS; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter; clip: true; selectByMouse: true
                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans
                    text: wrEdit.r.size || ""
                    onEditingFinished: root.wrSet(root.wrSel, "size", text.trim())
                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !wrS.text
                        text: "800x600"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
            Item { Layout.fillWidth: true }
        }
    }
}
