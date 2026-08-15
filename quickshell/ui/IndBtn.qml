// Three ranks, one primary per region. Label is a verb naming the outcome ("Disconnect",
// "Forget network") — never "OK" or "Submit". Radius 2px; pills are for nothing here.
import QtQuick

Rectangle {
    id: b
    property string text: ""
    property string rank: "secondary"      // primary | secondary | ghost | danger
    property string kbd: ""                // shortcut hint, rendered as a mono chip
    property bool   enabled: true
    property alias  hovered: ma.containsMouse
    signal activated()

    implicitHeight: 32
    implicitWidth: lbl.implicitWidth + (kchip.visible ? kchip.width + Tok.s2 : 0) + Tok.s4 * 2
    radius: Tok.r
    opacity: b.enabled ? 1 : 0.45

    color: !b.enabled ? Tok.sunken
         : b.rank === "primary" ? (ma.containsMouse ? Qt.lighter(Tok.accent, 1.12) : Tok.accent)
         : b.rank === "danger"  ? (ma.containsMouse ? Qt.lighter(Tok.crit, 1.12) : Tok.crit)
         : b.rank === "ghost"   ? (ma.containsMouse ? Tok.surface : "transparent")
         : (ma.containsMouse ? Tok.surface : Tok.raised)
    border.width: (b.rank === "secondary") ? 1 : 0
    border.color: Tok.ruleHard
    Behavior on color { ColorAnimation { duration: 130; easing.type: Easing.OutCubic } }

    Row {
        anchors.centerIn: parent
        spacing: Tok.s2
        IndText {
            id: lbl
            anchors.verticalCenter: parent.verticalCenter
            text: b.text
            sz: Tok.tDense
            font.weight: 500
            color: b.rank === "primary" ? Tok.accentInk
                 : b.rank === "danger"  ? "#ffffff"
                 : b.rank === "ghost"   ? Tok.ink2 : Tok.ink
        }
        Rectangle {
            id: kchip
            anchors.verticalCenter: parent.verticalCenter
            visible: b.kbd !== ""
            width: kt.implicitWidth + Tok.s2; height: 16; radius: Tok.r
            color: Tok.alpha(Tok.ink, 0.10)
            IndText { id: kt; anchors.centerIn: parent; mono: true; sz: 10; text: b.kbd; color: lbl.color }
        }
    }

    MouseArea {
        id: ma; anchors.fill: parent; hoverEnabled: true
        cursorShape: b.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (b.enabled) b.activated()
    }
}
