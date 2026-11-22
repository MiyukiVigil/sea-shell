import QtQuick
import QtQuick.Layouts

// ---- the shelf a cartridge is picked off ----
// Only while a slot is armed. A row of every wallpaper you own, permanently on display
// under slots that are already full, would be the largest thing on this page and would
// answer nothing. Two groups need one (the day/night pair, and the lock screen), which
// is why it is a component rather than a block of markup written twice.
Rectangle {
    id: sh
    property bool open: false
    property string chosen: ""
    signal picked(string path)

    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
    // Via a plain property: QML has no Behavior on an ATTACHED property, so animating
    // Layout.preferredHeight directly is not a slower open, it is an error.
    property real shelfH: sh.open ? 104 : 0
    Behavior on shelfH { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
    Layout.preferredHeight: shelfH
    visible: shelfH > 1
    clip: true
    radius: Tok.r
    color: Tok.sunken
    border.width: 1; border.color: Tok.ruleHard

    Text {
        anchors.centerIn: parent
        visible: !root.wpIndex.length
        text: root.wpIndexBusy ? "scanning…" : "No wallpapers in that folder"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    ListView {
        id: shelfList
        anchors.fill: parent; anchors.margins: 10
        orientation: ListView.Horizontal
        spacing: 8
        clip: true
        model: root.wpIndex
        delegate: Rectangle {
            id: shelfItem
            required property var modelData
            readonly property bool isChosen: sh.chosen === modelData.path
            width: 132; height: shelfList.height
            radius: Tok.rSmall
            clip: true
            color: Tok.bg
            border.width: shelfItem.isChosen ? 2 : 1
            border.color: shelfItem.isChosen ? Tok.accent
                        : (shelfMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
            Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
            Image {
                anchors.fill: parent; anchors.margins: shelfItem.border.width
                source: root.wpStill(shelfItem.modelData).length
                        ? Tok.fileUrl(root.wpStill(shelfItem.modelData)) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: true
                sourceSize.height: 160
            }
            // motion marker, exactly as the picker draws it — a moving wallpaper is a
            // different kind of thing and that has to be visible wherever one is offered
            Rectangle {
                visible: shelfItem.modelData.vid
                anchors { top: parent.top; left: parent.left; margins: 4 }
                width: 16; height: 16; radius: Tok.rSmall
                color: Tok.alpha(Tok.bg, 0.72)
                Sym { anchors.centerIn: parent; text: "play_arrow"; sz: 12; color: Tok.ink }
            }
            MouseArea {
                id: shelfMa
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sh.picked(shelfItem.modelData.path)
            }
        }
    }
}
