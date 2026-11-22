import QtQuick
import QtQuick.Layouts

// Authentic macOS Settings section header + elevated grouped card with mathematically symmetric padding.
ColumnLayout {
    id: sec
    property string title: ""
    property string icon: ""
    property bool sameAsPage: false
    readonly property bool isSection: true

    readonly property Item host: sec.parent
    readonly property real hostGap: host && host.spacing !== undefined ? host.spacing : 14
    readonly property bool isCompactList: {
        if (!host) return false;
        var kids = host.children, mine = false;
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k === sec) { mine = true; continue }
            if (!mine) continue;
            if (k.visible && k.isSection === true) break;
            if (k.visible && k.height > 0) return k.compactCard === true;
        }
        return false;
    }

    Component.onCompleted: { root.regSection(sec); Qt.callLater(sec.insetRows) }
    Layout.fillWidth: true
    Layout.leftMargin: 0
    Layout.rightMargin: 0
    Layout.topMargin: 18
    spacing: 0

    function insetRows() {
        var h = sec.parent;
        if (!h) return;
        var kids = h.children, mine = false;
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k === sec) { mine = true; continue }
            if (!mine) continue;
            if (k.isSection === true) break;
            if (k.edgeToEdge === true) continue;
            if (!k.Layout) continue;
            k.Layout.leftMargin = 16;
            k.Layout.rightMargin = 16;
        }
    }
    Connections { target: sec.parent; function onChildrenChanged() { Qt.callLater(sec.insetRows) } }

    RowLayout {
        id: titleRow
        visible: !sec.sameAsPage && sec.title !== ""
        Layout.fillWidth: true
        Layout.leftMargin: 4
        Layout.bottomMargin: 8
        spacing: 6
        Text {
            text: Tok.cap(sec.title)
            color: Tok.ink
            font.pixelSize: 13
            font.family: Tok.sans
            font.weight: 700
        }
    }

    // Guarantees at least 14px top padding inside non-MacList cards even when host.spacing < 14.
    Item {
        id: topPadBridge
        Layout.fillWidth: true
        Layout.preferredHeight: sec.isCompactList ? 0 : Math.max(0, 14 - sec.hostGap)
    }

    // Zero-height anchor whose elevated card wraps symmetrically around the section's rows.
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 0
        Rectangle {
            readonly property real pad: sec.isCompactList ? 6 : 14
            readonly property real firstTop: {
                if (!sec.host) return sec.y + sec.height;
                var kids = sec.host.children, mine = false;
                for (var i = 0; i < kids.length; i++) {
                    var k = kids[i];
                    if (k === sec) { mine = true; continue }
                    if (!mine) continue;
                    if (k.visible && k.isSection === true) break;
                    if (k.visible && k.height > 0) return k.y;
                }
                return sec.y + sec.height + sec.hostGap;
            }
            readonly property real lastBottom: {
                if (!sec.host) return firstTop;
                var kids = sec.host.children, mine = false, b = firstTop;
                for (var i = 0; i < kids.length; i++) {
                    var k = kids[i];
                    if (k === sec) { mine = true; continue }
                    if (!mine) continue;
                    if (k.visible && k.isSection === true) break;
                    if (k.visible && k.height > 0) b = Math.max(b, k.y + k.height);
                }
                return b;
            }
            readonly property real cardTop: firstTop - pad
            readonly property real cardBottom: lastBottom + pad
            x: 0
            y: cardTop - (sec.y + sec.height)
            z: -1
            width: sec.host ? sec.host.width : 0
            height: Math.max(0, cardBottom - cardTop)
            visible: height > 18 && lastBottom > firstTop
            radius: 11
            color: root.cardFill
            border.width: 1
            border.color: root.cardBorder
        }
    }
}
