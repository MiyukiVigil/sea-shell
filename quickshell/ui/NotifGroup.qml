import QtQuick
import Quickshell

// One app's notifications in the notification centre. Collapsed, it shows the newest message
// in full with the rest stacked behind it, so a busy chat is one card, not a wall. Expanded,
// every message is listed with its own dismiss. shell.qml owns the data and the actions; this
// draws them and reports what was asked.
Item {
    id: g
    property var group: ({ app: "", icon: "", items: [] })
    property bool expanded: false
    property bool current: false            // the keyboard's cursor is on this group
    property bool muted: false
    property var isLive: function(k) { return false }   // root.noteLive: can this one's actions still fire?
    property string font: Tok.sans
    signal toggle()
    signal dismissAll()
    signal dismiss(int key)
    signal mute()
    signal invoke(int key, int idx)

    readonly property var items: group.items || []
    readonly property int more: items.length - 1
    readonly property int stack: expanded ? 0 : Math.min(2, more)   // paper edges peeking out below
    implicitHeight: card.height + stack * 5

    function plain(s) {
        return ("" + (s || "")).replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&").trim();
    }
    readonly property string iconSrc: {
        var i = group.icon || "";
        if (i.indexOf("/") === 0) return "file://" + i;
        if (i.indexOf("file://") === 0) return i;
        var p = i ? Quickshell.iconPath(i, true) : "";
        if (!p) { try { var e = DesktopEntries.heuristicLookup(group.app); if (e && e.icon) p = Quickshell.iconPath(e.icon, true) } catch (err) {} }
        return p || "";
    }

    // the stacked edges, drawn first so the card sits on top of them
    Repeater {
        model: g.stack
        delegate: Rectangle {
            required property int index
            x: 6 * (index + 1); width: g.width - 12 * (index + 1)
            y: card.height - 10 + 5 * (index + 1); height: 12
            radius: Tok.r; color: Tok.surface; border.width: 1; border.color: Tok.rule
            opacity: 0.85 - index * 0.25
            z: -1 - index
        }
    }

    Rectangle {
        id: card
        width: parent.width
        height: col.implicitHeight + 20
        radius: Tok.r
        color: hover.hovered ? Tok.sunken : Tok.surface
        border.width: g.current ? 2 : 1
        border.color: g.current ? Tok.accent : (g.items.length && g.items[0].urgency === 2 ? Tok.crit : Tok.rule)
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        HoverHandler { id: hover }
        // clicking the card (not a button on it) opens or closes the group
        TapHandler { enabled: g.more > 0; onTapped: g.toggle() }

        Column {
            id: col
            x: 12; y: 10; width: parent.width - 24
            spacing: 6

            // header: icon, app, count · time, then mute / dismiss / chevron
            Item {
                width: parent.width; height: 20
                Image { id: ic; width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                    source: g.iconSrc; sourceSize.width: 32; asynchronous: true; visible: status === Image.Ready }
                Text { visible: !ic.visible; width: 16; anchors.verticalCenter: parent.verticalCenter
                    text: "notifications"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: Tok.ink3 }
                Text {
                    anchors.left: ic.right; anchors.leftMargin: 7; anchors.verticalCenter: parent.verticalCenter
                    anchors.right: tools.left; anchors.rightMargin: 6
                    elide: Text.ElideRight
                    text: g.group.app + (g.more > 0 ? "  ·  " + g.items.length : "") + "  ·  " + (g.items.length ? g.items[0].time : "")
                    color: Tok.ink2; font.family: g.font; font.pixelSize: 11; font.weight: Font.DemiBold
                }
                Row {
                    id: tools
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    // the controls stay out of the way until the card is pointed at or selected
                    opacity: hover.hovered || g.current || g.muted ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                    Repeater {
                        model: [ { i: g.muted ? "notifications_off" : "notifications_active", t: g.muted ? "Unmute" : "Mute this app", f: "mute", on: true },
                                 { i: "close", t: "Dismiss", f: "dismissAll", on: true },
                                 { i: g.expanded ? "expand_less" : "expand_more", t: g.expanded ? "Collapse" : "Show all", f: "toggle", on: g.more > 0 } ]
                        delegate: Rectangle {
                            required property var modelData
                            visible: modelData.on
                            width: 22; height: 20; radius: Tok.rSmall
                            color: tm.containsMouse ? Tok.sunken : "transparent"
                            Text { anchors.centerIn: parent; text: modelData.i; font.family: "Material Symbols Outlined"; font.pixelSize: 14
                                color: modelData.f === "mute" && g.muted ? Tok.warn : tm.containsMouse ? Tok.ink : Tok.ink3 }
                            MouseArea { id: tm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: g[modelData.f]() }
                        }
                    }
                }
            }

            // collapsed: the newest one; expanded: all of them, each with its own dismiss
            Repeater {
                model: g.expanded ? g.items : g.items.slice(0, 1)
                delegate: Item {
                    id: note
                    required property var modelData
                    required property int index
                    width: col.width
                    height: nc.implicitHeight + (g.expanded && index > 0 ? 8 : 0)
                    Rectangle { visible: g.expanded && note.index > 0; width: parent.width; height: 1; color: Tok.rule }
                    Column {
                        id: nc
                        y: g.expanded && note.index > 0 ? 8 : 0
                        width: parent.width - (g.expanded ? 24 : 0)
                        spacing: 2
                        Text { width: parent.width; visible: text !== ""; text: g.plain(note.modelData.summary)
                            color: Tok.ink; font.family: g.font; font.pixelSize: 12; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                        Text { width: parent.width; visible: text !== ""; text: g.plain(note.modelData.body)
                            color: Tok.ink2; font.family: g.font; font.pixelSize: 11; wrapMode: Text.Wrap
                            maximumLineCount: g.expanded ? 6 : 3; elide: Text.ElideRight; textFormat: Text.PlainText }
                        Text { visible: g.expanded; text: note.modelData.time || ""; color: Tok.ink3; font.family: Tok.mono; font.pixelSize: 10 }
                        // the app's own buttons, dead (and shown so) once the app has let go
                        Flow {
                            width: parent.width; spacing: 5; topPadding: 4
                            visible: !!note.modelData.actions && note.modelData.actions.length > 0
                            Repeater {
                                model: note.modelData.actions || []
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool live: g.isLive(note.modelData.key)
                                    height: 24; radius: Tok.r; width: at.implicitWidth + 18
                                    opacity: live ? 1 : 0.4
                                    color: live && am.containsMouse ? Tok.accentWash : Tok.sunken
                                    border.width: 1; border.color: live ? Tok.ruleHard : Tok.rule
                                    Text { id: at; anchors.centerIn: parent; text: modelData.t; color: Tok.ink; font.family: g.font; font.pixelSize: 11 }
                                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: parent.live ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: if (parent.live) g.invoke(note.modelData.key, modelData.i) }
                                }
                            }
                        }
                    }
                    Rectangle {
                        visible: g.expanded
                        anchors.right: parent.right; y: nc.y
                        width: 20; height: 20; radius: Tok.rSmall
                        color: dm.containsMouse ? Tok.sunken : "transparent"
                        Text { anchors.centerIn: parent; text: "close"; font.family: "Material Symbols Outlined"; font.pixelSize: 13; color: dm.containsMouse ? Tok.ink : Tok.ink3 }
                        MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: g.dismiss(note.modelData.key) }
                    }
                }
            }

            // collapsed with more behind it: say what is there, not just how many
            Text {
                visible: !g.expanded && g.more > 0
                width: parent.width; elide: Text.ElideRight
                text: (g.more === 1 ? "1 more" : g.more + " more") + (g.items.length > 1 && g.plain(g.items[1].summary) ? " · " + g.plain(g.items[1].summary) : "")
                color: Tok.ink3; font.family: g.font; font.pixelSize: 11
            }
        }
    }
}
