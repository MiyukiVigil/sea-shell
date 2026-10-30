import QtQuick
import QtQuick.Effects

// One composition: a quiet artwork column and a tabbed working area.
Item {
    id: frame
    property var player: null
    property url mascotSource: ""
    property var viz: []
    property bool active: true
    property bool reducedMotion: false
    property int selectedTab: 0
    property color ink: "#211c2a"
    property color secondary: "#625a70"
    property color accent: "#65538c"
    property color wash: "#e5dff5"
    property color rule: "#d8d2df"
    readonly property real outerPadding: 24
    readonly property real mascotWidth: mascotSource.toString().length > 0 ? 168 : 0
    readonly property real leftWidth: Math.min(212,width*.35)
    property alias controlsHost: controls
    property alias detailsHost: details
    property alias lyricsHost: lyrics
    signal selected(int tab)
    Text {
        x: frame.outerPadding; y: 15; width: frame.leftWidth-frame.outerPadding*2
        text: frame.player ? (frame.player.identity || "Music") : "Music"
        color: frame.secondary; font.family: "Adwaita Sans"; font.pixelSize: 11; elide: Text.ElideRight
    }
    Rectangle {
        id: artwork
        x: frame.outerPadding; y: 44
        width: frame.leftWidth-frame.outerPadding*2; height: Math.min(width,Math.max(80,frame.height-136))
        radius: 14; color: frame.wash
        Image {
            id: cover
            anchors.fill: parent; anchors.margins: 5
            source: frame.player ? (frame.player.trackArtUrl || "") : ""
            fillMode: Image.PreserveAspectCrop; asynchronous: true
            sourceSize.width: 256; sourceSize.height: 256
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 5 }
            height: 24; color: frame.wash
            Row {
                anchors.centerIn: parent; spacing: 2; height: 18
                Repeater { model: 22
                    Rectangle {
                        required property int index
                        objectName: "cover-spectrum-" + index
                        readonly property real magnitude: frame.active && frame.player && frame.player.isPlaying && !frame.reducedMotion && frame.viz.length
                            ? Math.max(0,Math.min(1,Number(frame.viz[Math.floor(index*frame.viz.length/22)])/100)) : 0
                        width: Math.max(2,(artwork.width-24-42)/22); height: 2 + 16*magnitude; radius: 1
                        anchors.bottom: parent.bottom; color: frame.accent
                        Behavior on height { NumberAnimation { duration: frame.reducedMotion ? 0 : 80; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
        Text { anchors.centerIn: parent; visible: cover.status !== Image.Ready; text: "music_note"
            color: frame.accent; font.family: "Material Symbols Outlined"; font.pixelSize: 48 }
    }
    Text {
        id: title; objectName: "trackTitle"
        x: frame.outerPadding; y: artwork.y+artwork.height+12; width: frame.leftWidth-frame.outerPadding*2
        text: frame.player ? (frame.player.trackTitle || "Unknown track") : "Nothing playing"
        color: frame.ink; font.family: "Adwaita Sans"; font.pixelSize: 17; font.weight: Font.DemiBold
        wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
    }
    Text {
        x: frame.outerPadding; y: title.y+title.height+5; width: frame.leftWidth-frame.outerPadding*2
        text: frame.player ? (frame.player.trackArtist || frame.player.trackAlbum || "") : "Open a music player"
        color: frame.secondary; font.family: "Adwaita Sans"; font.pixelSize: 12; elide: Text.ElideRight
    }
    Rectangle { x: frame.leftWidth; y: 18; width: 1; height: parent.height-36; color: frame.rule }
    Row {
        id: tabs
        x: frame.leftWidth+20; y: 10; width: frame.width-x-18-frame.mascotWidth; height: 34
        Repeater {
            model: ["Controls","Details","Lyrics"]
            Item {
                required property string modelData; required property int index
                objectName: "player-tab-" + index
                width: tabs.width/3; height: tabs.height
                Text { anchors.centerIn: parent; text: modelData; color: frame.selectedTab===index ? frame.accent : frame.secondary
                    font.family: "Adwaita Sans"; font.pixelSize: 12; font.weight: frame.selectedTab===index ? Font.DemiBold : Font.Normal }
                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 12; rightMargin: 12 }
                    height: frame.selectedTab===index ? 3 : 1; radius: 1.5; color: frame.selectedTab===index ? frame.accent : frame.rule }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: frame.selected(index) }
            }
        }
    }
    Text {
        visible: frame.mascotWidth > 0
        x: frame.width-frame.mascotWidth; y: 20; width: frame.mascotWidth
        text: "Miku"; horizontalAlignment: Text.AlignHCenter
        color: frame.accent; font.family: "Adwaita Sans"; font.pixelSize: 15; font.weight: Font.DemiBold
    }
    Text {
        visible: frame.mascotWidth > 0
        x: frame.width-frame.mascotWidth; y: 43; width: frame.mascotWidth
        text: frame.player ? (frame.player.isPlaying ? "Playing" : "Paused") : "Music buddy"
        horizontalAlignment: Text.AlignHCenter; color: frame.secondary; font.family: "Adwaita Sans"; font.pixelSize: 11
    }
    Rectangle {
        x: mascot.x-4; y: mascot.y-4; width: mascot.width+8; height: mascot.height+8
        visible: mascot.visible; radius: width/2; color: frame.wash; border.width: 1; border.color: frame.rule
    }
    Rectangle {
        id: mascotMask; anchors.fill: mascot; radius: width/2; color: "white"
        layer.enabled: true; visible: false
    }
    AnimatedImage {
        id: mascot; objectName: "mediaMascot"
        x: frame.width-frame.mascotWidth+(frame.mascotWidth-width)/2; y: (frame.height-height)/2
        width: 112; height: 112
        visible: frame.mascotWidth > 0
        source: visible ? frame.mascotSource : ""; sourceSize: Qt.size(112,112)
        fillMode: Image.PreserveAspectFit; cache: false
        layer.enabled: true
        layer.effect: MultiEffect { maskEnabled: true; maskSource: mascotMask }
        playing: frame.active && visible && !frame.reducedMotion
    }
    Item { id: controls; objectName: "controlsHost"; visible: frame.selectedTab===0
        x: tabs.x; y: 55; width: tabs.width; height: frame.height-y-16 }
    Item { id: details; objectName: "detailsHost"; visible: frame.selectedTab===1
        x: tabs.x; y: 55; width: tabs.width; height: frame.height-y-16 }
    Item { id: lyrics; objectName: "lyricsHost"; visible: frame.selectedTab===2
        x: tabs.x; y: 55; width: tabs.width; height: frame.height-y-16 }
}
