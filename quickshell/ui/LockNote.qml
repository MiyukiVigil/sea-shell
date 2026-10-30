import QtQuick
import Quickshell

// One app's notifications on the lock screen: its newest message in full, then how many more.
// showContent false keeps the app and the count but hides what was said.
Rectangle {
    id: card
    property var group: ({ app: "", icon: "", items: [] })
    property real u: 1
    property bool showContent: true
    property color fill: Qt.rgba(0, 0, 0, 0.45)
    property color line: Qt.rgba(1, 1, 1, 0.14)
    readonly property var latest: group.items.length ? group.items[0] : ({})
    readonly property int more: group.items.length - 1
    readonly property bool urgent: top.urgency === 2

    implicitHeight: col.implicitHeight + 26 * u
    radius: 18 * u
    color: fill
    border.width: 1; border.color: urgent ? Qt.rgba(1, 0.7, 0.67, 0.6) : line

    function plain(s) {
        return ("" + (s || "")).replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
    }
    readonly property string iconSrc: {
        var i = group.icon || "";
        if (i.indexOf("/") === 0) return "file://" + i;
        if (i.indexOf("file://") === 0) return i;
        var p = i ? Quickshell.iconPath(i, true) : "";
        // apps often name an icon the theme lacks; their .desktop entry knows the right one
        if (!p) { try { var e = DesktopEntries.heuristicLookup(group.app); if (e && e.icon) p = Quickshell.iconPath(e.icon, true) } catch (err) {} }
        return p || "";
    }

    Column {
        id: col
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 13 * card.u; anchors.leftMargin: 16 * card.u; anchors.rightMargin: 16 * card.u
        spacing: 5 * card.u

        Item {
            width: parent.width; height: 20 * card.u
            Image {
                id: ic
                width: 18 * card.u; height: width; anchors.verticalCenter: parent.verticalCenter
                source: card.iconSrc; sourceSize.width: 48; asynchronous: true
                visible: status === Image.Ready
            }
            Text {
                visible: !ic.visible
                width: 18 * card.u; anchors.verticalCenter: parent.verticalCenter
                text: "notifications"; font.family: "Material Symbols Rounded"; font.pixelSize: 17 * card.u
                color: Qt.rgba(1, 1, 1, 0.7)
            }
            Text {
                anchors.left: ic.right; anchors.leftMargin: 8 * card.u; anchors.verticalCenter: parent.verticalCenter
                anchors.right: when.left; anchors.rightMargin: 8 * card.u
                text: card.group.app + (card.more > 0 ? "  ·  " + (card.more + 1) : "")
                elide: Text.ElideRight
                font.family: Tok.sans; font.pixelSize: 12 * card.u; font.weight: Font.DemiBold
                color: Qt.rgba(1, 1, 1, 0.78)
            }
            Text {
                id: when
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                text: card.latest.time || ""
                font.family: Tok.mono; font.pixelSize: 11 * card.u; color: Qt.rgba(1, 1, 1, 0.5)
            }
        }
        Text {
            visible: card.showContent && text !== ""
            width: parent.width; elide: Text.ElideRight
            text: card.plain(card.latest.summary)
            font.family: Tok.sans; font.pixelSize: 14 * card.u; font.weight: Font.DemiBold; color: "white"
        }
        Text {
            visible: card.showContent && text !== ""
            width: parent.width
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            text: card.plain(card.latest.body)
            font.family: Tok.sans; font.pixelSize: 13 * card.u; color: Qt.rgba(1, 1, 1, 0.78)
            lineHeight: 1.1
        }
        Text {
            visible: card.more > 0
            width: parent.width; elide: Text.ElideRight
            // the next one's summary, so a second message is not just a number
            text: card.showContent && card.group.items.length > 1 && card.plain(card.group.items[1].summary)
                ? card.plain(card.group.items[1].summary) + (card.more > 1 ? "  +" + (card.more - 1) + " more" : "")
                : card.more + " more"
            font.family: Tok.sans; font.pixelSize: 12 * card.u; color: Qt.rgba(1, 1, 1, 0.5)
            topPadding: 2 * card.u
        }
    }
}
