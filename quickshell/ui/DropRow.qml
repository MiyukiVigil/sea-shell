import QtQuick

// One choice in a bar dropdown, built the way the Wi-Fi network rows are: an icon, the name
// (and a quieter second line when there is one), and on the right a reading and/or one chip.
// The current choice is tinted and outlined. A destructive or secondary action (forget,
// disconnect) only appears while the row is pointed at, so it cannot be hit by accident.
Rectangle {
    id: r
    property string icon: ""
    property string label: ""
    property string sub: ""                   // a second line, e.g. "Paired · not in range"
    property string value: ""                 // a reading on the right, mono, e.g. "82%"
    property string chip: ""                  // one fact worth the width, e.g. "CONNECTED"
    property string chipTone: "neutral"
    property bool current: false
    property bool busy: false                 // e.g. connecting: the icon pulses
    property bool dim: false                  // shown, but not something you can use right now
    property string hoverIcon: ""             // the on-hover action's icon, e.g. "link_off"
    property string hoverTone: "neutral"      // "crit" for things like forget
    signal clicked()
    signal hoverAction()

    width: parent ? parent.width : 280
    height: r.sub !== "" ? 44 : 36
    radius: Tok.rSmall
    color: r.current ? Tok.accentWash : (ma.containsMouse || ha.containsMouse ? Tok.sunken : "transparent")
    border.width: r.current ? 1 : 0; border.color: Qt.rgba(Tok.accent.r, Tok.accent.g, Tok.accent.b, 0.35)
    opacity: r.dim ? 0.55 : 1
    Behavior on color { ColorAnimation { duration: Tok.mFast } }

    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r.clicked() }

    Text {
        id: ic
        anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
        text: r.icon; font.family: "Material Symbols Outlined"; font.pixelSize: 17
        color: r.current ? Tok.accent : Tok.ink3
        SequentialAnimation on opacity { running: r.busy; loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 500 } NumberAnimation { to: 1; duration: 500 }
            onRunningChanged: if (!running) ic.opacity = 1 }
    }
    Row {
        id: right
        anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        // yields its place to the hover action rather than being drawn over by it
        visible: !(r.hoverIcon !== "" && (ma.containsMouse || ha.containsMouse))
        IndChip { anchors.verticalCenter: parent.verticalCenter; visible: r.chip !== ""; text: r.chip; tone: r.chipTone }
        Text { anchors.verticalCenter: parent.verticalCenter; visible: r.value !== ""
            text: r.value; color: r.current ? Tok.ink : Tok.ink2; font.family: Tok.mono; font.pixelSize: 11; font.features: { "tnum": 1 } }
    }
    Column {
        anchors.left: ic.right; anchors.leftMargin: 10
        anchors.right: right.visible ? right.left : hov.left; anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        Text { width: parent.width; elide: Text.ElideRight; text: r.label
            color: r.current ? Tok.ink : Tok.ink2; font.family: Tok.sans; font.pixelSize: 12; font.bold: r.current }
        Text { visible: r.sub !== ""; width: parent.width; elide: Text.ElideRight; text: r.sub
            color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 10 }
    }
    Rectangle {
        id: hov
        visible: r.hoverIcon !== "" && (ma.containsMouse || ha.containsMouse)
        anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
        width: 24; height: 24; radius: Tok.rSmall
        color: ha.containsMouse ? (r.hoverTone === "crit" ? Tok.critWash : Tok.accentWash) : "transparent"
        Text { anchors.centerIn: parent; text: r.hoverIcon; font.family: "Material Symbols Outlined"; font.pixelSize: 15
            color: ha.containsMouse ? (r.hoverTone === "crit" ? Tok.crit : Tok.ink) : Tok.ink3 }
        MouseArea { id: ha; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r.hoverAction() }
    }
}
