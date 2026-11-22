import QtQuick
import QtQuick.Layouts

// ---- a wallpaper as a CARTRIDGE ----
// The picker commits by dropping a cartridge into a deck. Choosing which wallpaper is
// loaded automatically at dusk is the same act, decided in advance — so it is the same
// object: a labelled plate with a picture on it and a key notch down one side, sitting
// in a slot that is either occupied or plainly empty.
//
// The notch is not decoration. It is the one marking on here that says which way up
// this goes, which is the only thing a physical cartridge's shape ever told you.
Rectangle {
    id: ct
    property string slot: ""            // DAY / NIGHT — the tracked legend
    property string path: ""
    property bool armed: false          // waiting for a pick off the shelf
    signal picked()
    signal cleared()

    readonly property var entry: root.wpNamed(ct.path)
    readonly property bool filled: ct.path.length > 0

    implicitWidth: 208; implicitHeight: 132
    radius: Tok.rSmall
    clip: true
    color: Tok.sunken
    border.width: ct.armed ? 2 : 1
    border.color: ct.armed ? Tok.accent : (ctMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }

    Image {
        anchors { fill: parent; margins: ct.border.width; bottomMargin: 26 + ct.border.width }
        visible: ct.filled
        source: ct.entry ? Tok.fileUrl(root.wpStill(ct.entry)) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true; cache: true
        sourceSize.height: 240
    }

    // empty slot — an opening with nothing in it, said the way the deck says it
    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -13
        spacing: 4
        visible: !ct.filled
        Sym { anchors.horizontalCenter: parent.horizontalCenter
              text: "add_photo_alternate"; sz: 22; color: Tok.ink3 }
        Text { anchors.horizontalCenter: parent.horizontalCenter
               text: ct.armed ? "Pick one below" : "Empty"
               color: ct.armed ? Tok.accent : Tok.ink3
               font.pixelSize: Tok.tLabel; font.family: Tok.sans
               font.letterSpacing: 1.2 }
    }

    // the label plate
    Rectangle {
        id: ctPlate
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 26
        color: Tok.raised
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1; color: Tok.ruleHard }
        Row {
            anchors { left: parent.left; leftMargin: 8; right: ctClear.left; rightMargin: 6
                      verticalCenter: parent.verticalCenter }
            spacing: 8
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ct.slot; color: Tok.accent
                font.pixelSize: Tok.tLabel; font.family: Tok.sans; font.weight: 700
            }
            Rectangle { anchors.verticalCenter: parent.verticalCenter
                        width: 1; height: 12; color: Tok.ruleHard }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - 96)
                text: ct.filled ? (ct.entry ? ct.entry.name : ct.path.slice(ct.path.lastIndexOf("/") + 1))
                                : "—"
                color: Tok.ink2; font.pixelSize: Tok.tData; font.family: Tok.sans
                elide: Text.ElideMiddle
            }
        }
        Sym {
            id: ctClear
            anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
            visible: ct.filled
            text: "backspace"; sz: 14
            color: ctClearMa.containsMouse ? Tok.crit : Tok.ink3
            MouseArea { id: ctClearMa; anchors.fill: parent; anchors.margins: -5
                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: ct.cleared() }
        }
    }

    // The key notch, in the ground's own colour so it reads as absent material rather
    // than as a painted mark. TOP corner, which is where a cartridge is actually keyed —
    // and, on the profile cartridge that shares this detail, the only edge where a
    // notch does not take a bite out of the accent band that identifies it.
    Rectangle {
        anchors { right: parent.right; top: parent.top }
        width: 18; height: 10
        color: Tok.bg
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: 1; color: Tok.ruleHard }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1; color: Tok.ruleHard }
    }

    // registration corners while armed — the same four brackets the picker puts on the
    // panel it has hold of, meaning the same thing: this one is the target.
    Repeater {
        model: ct.armed ? 4 : 0
        Item {
            required property int index
            readonly property bool onRight: (index % 2) === 1
            readonly property bool onBottom: index >= 2
            // 4px, matching the picker's brackets. At 3 they were technically drawn and
            // practically invisible — the same measuring mistake the picker's own
            // corners needed correcting for.
            readonly property real arm: 16
            width: arm; height: arm
            x: onRight ? ct.width - arm : 0
            y: onBottom ? ct.height - 26 - arm : 0
            Rectangle { width: parent.arm; height: 4; color: Tok.accent
                        y: parent.onBottom ? parent.arm - 4 : 0 }
            Rectangle { width: 4; height: parent.arm; color: Tok.accent
                        x: parent.onRight ? parent.arm - 4 : 0 }
        }
    }

    MouseArea { id: ctMa; anchors.fill: parent; anchors.bottomMargin: 26
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: ct.picked() }
}
