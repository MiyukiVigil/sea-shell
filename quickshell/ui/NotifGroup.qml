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
    property bool priority: false           // bypasses DND when enabled
    property var isLive: function(k) { return false }   // root.noteLive: can this one's actions still fire?
    property string font: Tok.sans
    signal toggle()
    signal dismissAll()
    signal dismiss(int key)
    signal mute()
    signal prioritize()
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
            radius: 14; color: Tok.alpha(Tok.ink, 0.045); border.width: 0
            opacity: 0.85 - index * 0.25
            z: -1 - index
        }
    }

    Rectangle {
        id: card
        width: parent.width
        height: Math.max(col.implicitHeight + 20, appMark.height + 24)
        // a tinted card on the dropdown's glass, as Notification Centre's; outlined only for
        // the keyboard's cursor or something critical
        radius: 14
        color: hover.hovered ? Tok.alpha(Tok.ink, 0.10) : Tok.alpha(Tok.ink, 0.065)
        border.width: g.current ? 2 : (g.items.length && g.items[0].urgency === 2 ? 1 : 0)
        border.color: g.current ? Tok.accent : Tok.alpha(Tok.crit, 0.7)
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        HoverHandler { id: hover }
        // clicking the card (not a button on it) opens or closes the group
        TapHandler { enabled: g.more > 0; onTapped: g.toggle() }

        // the app, as large as the popup that announced it: its mark, its icon, or a bell
        Item {
            id: appMark
            x: 12; y: 12; width: 36; height: 36
            SeaLogo { anchors.centerIn: parent; visible: g.group.app === "sea-shell"; size: parent.width; accent: Tok.accent }
            Image { id: ic; anchors.fill: parent; visible: g.group.app !== "sea-shell" && status === Image.Ready
                source: g.iconSrc; sourceSize.width: 72; sourceSize.height: 72; asynchronous: true; fillMode: Image.PreserveAspectFit }
            Rectangle { anchors.fill: parent; radius: 10; color: Tok.accent; visible: g.group.app !== "sea-shell" && !ic.visible
                Text { anchors.centerIn: parent; text: "notifications"; font.family: "Material Symbols Outlined"; font.pixelSize: 20; color: Tok.accentInk } }
        }

        Column {
            id: col
            x: appMark.x + appMark.width + 11; y: 10; width: parent.width - x - 12
            spacing: 6

            // header: icon, app, count · time, then mute / dismiss / chevron
            Item {
                width: parent.width; height: 20
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
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
                    opacity: hover.hovered || g.current || g.muted || g.priority ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
                    Repeater {
                        model: [ { i: g.priority ? "star" : "star_outline", t: g.priority ? "Remove priority" : "Bypass DND", f: "prioritize", on: true },
                                 { i: g.muted ? "notifications_off" : "notifications_active", t: g.muted ? "Unmute" : "Mute this app", f: "mute", on: true },
                                 { i: "close", t: "Dismiss", f: "dismissAll", on: true },
                                 { i: g.expanded ? "expand_less" : "expand_more", t: g.expanded ? "Collapse" : "Show all", f: "toggle", on: g.more > 0 } ]
                        delegate: Rectangle {
                            required property var modelData
                            visible: modelData.on
                            width: 22; height: 22; radius: 11
                            color: tm.containsMouse ? Tok.alpha(Tok.ink, 0.10) : "transparent"
                            Text { anchors.centerIn: parent; text: modelData.i; font.family: "Material Symbols Outlined"; font.pixelSize: 14
                                color: modelData.f === "mute" && g.muted ? Tok.warn
                                     : modelData.f === "prioritize" && g.priority ? Tok.accent
                                     : tm.containsMouse ? Tok.ink : Tok.ink3 }
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
                    Rectangle { visible: g.expanded && note.index > 0; width: parent.width; height: 1; color: Tok.alpha(Tok.ink, 0.08) }
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
                        Text { visible: g.expanded; text: note.modelData.time || ""; color: Tok.ink3; font.family: g.font; font.pixelSize: 11; font.features: { "tnum": 1 } }
                        // the app's own buttons, dead (and shown so) once the app has let go
                        Flow {
                            width: parent.width; spacing: 5; topPadding: 4
                            visible: !!note.modelData.actions && note.modelData.actions.length > 0
                            Repeater {
                                model: note.modelData.actions || []
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool live: g.isLive(note.modelData.key)
                                    height: 26; radius: 13; width: at.implicitWidth + 22
                                    opacity: live ? 1 : 0.4
                                    color: live && am.containsMouse ? Tok.alpha(Tok.ink, 0.14) : Tok.alpha(Tok.ink, 0.07)
                                    border.width: 0
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
                        width: 22; height: 22; radius: 11
                        color: dm.containsMouse ? Tok.alpha(Tok.ink, 0.10) : "transparent"
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
