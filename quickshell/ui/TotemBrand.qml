import QtQuick

// Brand badge for a Totem account: Simple Icons glyph on its colour, or a letter badge.
Item {
    id: b
    property var logo: null   // { file, hex, letter, light } from sea-totem-enrich.py
    property string fallback: "?"
    width: 22
    height: 22

    readonly property string hex: (b.logo && b.logo.hex) ? ("#" + b.logo.hex) : "#7F8C8D"
    readonly property bool light: !!(b.logo && b.logo.light)
    readonly property string letter: (b.logo && b.logo.letter) ? b.logo.letter : b.fallback
    readonly property string file: (b.logo && b.logo.file) ? b.logo.file : ""

    // Full SVG badge (coloured ground + glyph) when we have a Simple Icons file.
    Image {
        anchors.fill: parent
        visible: b.file !== ""
        source: b.file !== "" ? ("file://" + b.file) : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        asynchronous: true
        sourceSize.width: 64
        sourceSize.height: 64
    }
    // Letter fallback (LinkedIn etc. aren't in the CC0 pack).
    Rectangle {
        anchors.fill: parent
        visible: b.file === ""
        radius: 6
        color: b.hex
        Text {
            anchors.centerIn: parent
            text: b.letter
            color: b.light ? "#000000" : "#ffffff"
            font.family: Tok.sans
            font.pixelSize: 11
            font.bold: true
        }
    }
}
