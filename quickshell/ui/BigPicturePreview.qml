// A normal window on the current desktop, so big picture can be looked at
// without covering the session. BP_DRY=1 keeps it from launching games or
// changing game mode.
//   BP_DRY=1 qs -p BigPicturePreview.qml
import Quickshell
import QtQuick

FloatingWindow {
    title: "Big picture preview"
    implicitWidth: 1480
    implicitHeight: 833
    color: "black"

    BigPictureScene {
        id: scene
        anchors.fill: parent
        focus: true
        // No live pad in this window, so the corner glyph has something to draw.
        pads: [{ name: "Xbox Wireless Controller", bus: "usb" }]
        Component.onCompleted: scene.enter()
        // BP_SHOW_LAUNCH=1 seats a cartridge once the shelf has a game, so the launch screen can be screenshotted.
        Timer {
            interval: 400
            repeat: true
            running: (Quickshell.env("BP_SHOW_LAUNCH") || "") !== "" && scene.t < 0
            onTriggered: if (scene.game) scene.insert()
        }
    }
}
