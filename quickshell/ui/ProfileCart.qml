import QtQuick
import QtQuick.Layouts

Rectangle {
    id: pc
    property var profile: null
    property bool loaded: false
    signal load()
    signal eject()

    implicitWidth: 176; implicitHeight: 116
    radius: Tok.rSmall
    clip: true
    color: Tok.sunken
    border.width: pc.loaded ? 2 : 1
    border.color: pc.loaded ? Tok.accent : (pcMa.containsMouse ? Tok.ink3 : Tok.ruleHard)
    Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
    // The dip on press: 3px of the machine taking the object. Anticipation is the whole
    // reason the picker's insert reads as force rather than as a position change, and it
    // costs one Behavior here.
    transform: Translate { y: pcMa.pressed ? 3 : 0
                           Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } } }

    // The face. Three neutral steps and the accent, with hairlines between them —
    // without those a low-saturation preset (the shipped "BW" is four shades of
    // near-white) draws four bands you cannot tell apart, and the cartridge looks blank
    // rather than pale. The rules are the profile's OWN rule colour, so the separation
    // is drawn in the palette being previewed rather than in the one you are sitting in.
    Item {
        id: pcFace
        anchors { fill: parent; margins: pc.border.width; bottomMargin: 26 + pc.border.width }

        Column {
            anchors.fill: parent
            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    width: pcFace.width
                    height: (pcFace.height - 14) / 3
                    color: root.profStep(pc.profile, index)
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1
                        color: root.profLight(pc.profile)
                               ? Qt.hsla(root.profHue(pc.profile), 0.10, 0.845, 1)
                               : Qt.hsla(root.profHue(pc.profile), 0.12, 0.190, 1)
                    }
                }
            }
            // The accent gets a band rather than a dot: it is the single fact that
            // distinguishes one preset from another, and a 30px circle floating in the
            // corner was decoration standing in for it.
            Rectangle {
                width: pcFace.width; height: 14
                color: root.profAccent(pc.profile)
            }
        }

        // light or dark, said once, in the palette's own ink
        Sym {
            anchors { left: parent.left; top: parent.top; margins: 7 }
            text: root.profLight(pc.profile) ? "light_mode" : "dark_mode"
            sz: 15
            color: root.profLight(pc.profile) ? Qt.hsla(root.profHue(pc.profile), 0.16, 0.09, 1)
                                              : Qt.hsla(root.profHue(pc.profile), 0.08, 0.912, 1)
        }

        // The spec, printed on the label the way a spec is printed on hardware — in the
        // preset's own secondary ink, over its own raised step. This is what the row
        // this replaces spent a whole line of prose on.
        Text {
            anchors { left: parent.left; right: parent.right; leftMargin: 7; rightMargin: 7
                      bottom: parent.bottom; bottomMargin: 19 }
            text: (pc.profile ? pc.profile.font : "") + "  ·  r" + (pc.profile ? Math.round(pc.profile.radius) : 0)
            color: root.profLight(pc.profile) ? Qt.hsla(root.profHue(pc.profile), 0.12, 0.310, 1)
                                              : Qt.hsla(root.profHue(pc.profile), 0.08, 0.680, 1)
            font.pixelSize: Tok.tLabel; font.family: Tok.sans
            elide: Text.ElideRight
        }
    }

    Rectangle {
        id: pcPlate
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 26
        color: Tok.raised
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1; color: Tok.ruleHard }
        Row {
            anchors { left: parent.left; leftMargin: 8; right: pcEject.left; rightMargin: 6
                      verticalCenter: parent.verticalCenter }
            spacing: 7
            // The status lamp, exactly as the deck runs it: lit for the one that is in.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 3.5
                color: pc.loaded ? Tok.accent : Tok.alpha(Tok.ink3, 0.40)
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - 26)
                text: pc.profile ? pc.profile.name : ""
                color: Tok.ink; font.pixelSize: Tok.tData; font.family: Tok.sans
                font.weight: pc.loaded ? 700 : 400
                elide: Text.ElideRight
            }
        }
        Sym {
            id: pcEject
            anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
            text: "eject"; sz: 15
            color: pcEjectMa.containsMouse ? Tok.crit : Tok.ink3
            MouseArea { id: pcEjectMa; anchors.fill: parent; anchors.margins: -5
                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: pc.eject() }
        }
    }

    // the key notch — the one marking that says which way up this goes
    Rectangle {
        anchors { right: parent.right; top: parent.top }
        width: 18; height: 10
        color: Tok.bg
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: 1; color: Tok.ruleHard }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1; color: Tok.ruleHard }
    }

    MouseArea { id: pcMa; anchors.fill: parent; anchors.bottomMargin: 26
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: pc.load() }
}
