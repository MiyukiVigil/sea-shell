// A switch that is a rectangle, not a pill, and that always shows its STATE IN WORDS as well
// as position — the old dashboard had bare toggles you could not read at a glance, and the
// quick-command buttons showed no state at all.
import QtQuick

Item {
    id: sw
    property bool on: false
    property bool enabled: true
    signal toggled(bool value)

    implicitWidth: 38
    implicitHeight: 20
    opacity: sw.enabled ? 1 : 0.45

    Rectangle {
        anchors.fill: parent
        radius: Tok.r
        color: sw.on ? Tok.accent : Tok.sunken
        border.width: 1
        border.color: sw.on ? Tok.accent : Tok.ruleHard
        Behavior on color { ColorAnimation { duration: 130; easing.type: Easing.OutCubic } }

        Rectangle {
            width: 14; height: 14; radius: Tok.r
            anchors.verticalCenter: parent.verticalCenter
            x: sw.on ? parent.width - width - 3 : 3
            color: sw.on ? Tok.accentInk : Tok.ink3
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.Bezier
                easing.bezierCurve: [0.2, 0, 0, 1, 1, 1] } }
        }
    }

    // CONTROLLED, not self-driving. Every caller binds `on` to the real state — root.wifiOn,
    // root.btOn, root.warpConnected — and acts on `toggled`. Flipping `sw.on` here assigned over
    // that binding and destroyed it, so from the first click onward the switch showed what it had
    // been clicked to rather than what was true: a WARP connect that failed, or a radio something
    // else turned off, left the switch stuck in the wrong position for the life of the shell.
    //
    // Reporting the intended value and letting the owner's state come back is a beat slower on
    // screen, which is honest — the radio really has not changed yet.
    MouseArea {
        anchors.fill: parent
        cursorShape: sw.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (sw.enabled) sw.toggled(!sw.on)
    }
}
