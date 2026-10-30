import QtQuick

// Animate only opacity/transform inputs: no layout work or cached full-screen layer.
Item {
    id: motion
    property bool opened: false
    property bool reduced: false
    property int enterDuration: 260
    property int exitDuration: 140
    readonly property bool presenting: opened || progress > 0
    property real progress: 0
    onOpenedChanged: {
        tween.stop()
        if (reduced) progress = opened ? 1 : 0
        else {
            tween.to = opened ? 1 : 0
            tween.duration = opened ? enterDuration : exitDuration
            tween.restart()
        }
    }
    onReducedChanged: if (reduced) { tween.stop(); progress = opened ? 1 : 0 }
    NumberAnimation {
        id: tween
        target: motion; property: "progress"
        easing.type: Easing.OutCubic
    }
}
