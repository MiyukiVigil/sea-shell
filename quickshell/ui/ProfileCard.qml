import QtQuick
import QtQuick.Effects

Rectangle {
    id: card
    property var profile: ({})
    property string subtitle: "Your sea-shell profile"
    property url subtitleIcon: ""
    property bool compact: false
    property bool flat: false
    // Never shorter than the old fixed size, and taller when a large name font needs it.
    implicitHeight: Math.max(compact ? 76 : 116, words.implicitHeight + (compact ? 20 : 32))
    radius: 18; color: flat ? "transparent" : Tok.surface; border.width: flat ? 0 : 1; border.color: Tok.ruleHard
    Rectangle { id: face; x: card.compact ? 10 : 20; anchors.verticalCenter: parent.verticalCenter; width: card.compact ? 40 : 72; height: width; radius: width/2; color: Tok.sunken
        Text { anchors.centerIn: parent; text: "person"; font.family: "Material Symbols Outlined"; font.pixelSize: 34; color: Tok.ink3 }
        Image { anchors.fill: parent; source: card.profile.avatar ? "file://" + card.profile.avatar : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 160; sourceSize.height: 160
            layer.enabled: true; layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask }
        }
        Rectangle { id: faceMask; anchors.fill: parent; radius: width/2; color: "white"; visible: false; layer.enabled: true }
    }
    Column { id: words; anchors.left: face.right; anchors.leftMargin: card.compact ? 10 : 18; anchors.right: parent.right; anchors.rightMargin: 20; anchors.verticalCenter: parent.verticalCenter; spacing: 7
        // A script or display face draws far smaller than the UI font at the same pixel size, so
        // the name is scaled to look as big as it would in Tok.sans. Neither x-height alone (a
        // script's tall flourishes hide how small its letters are) nor width alone (the UI font is
        // monospace, and wide) is fair, so it takes the geometric mean of the two.
        FontMetrics { id: plainName; font.family: Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
        FontMetrics { id: chosenName; font.family: card.profile.font || Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
        Text { width: parent.width; text: card.profile.name || "Welcome"; elide: Text.ElideRight
            readonly property real baseSize: card.compact ? 15 : (card.profile.nameSize || 22)
            readonly property real opticalScale: {
                var plainW = plainName.tightBoundingRect(text).width, chosenW = chosenName.tightBoundingRect(text).width;
                if (!(plainW > 0 && chosenW > 0 && plainName.xHeight > 0 && chosenName.xHeight > 0)) return 1;
                return Math.max(1, Math.min(2, Math.sqrt(plainName.xHeight / chosenName.xHeight * plainW / chosenW)));
            }
            font.family: card.profile.font || Tok.sans; font.pixelSize: Math.round(baseSize * opticalScale); font.weight: Font.DemiBold
            color: card.profile.color || Tok.ink
            layer.enabled: card.profile.glow === true
            layer.effect: MultiEffect { shadowEnabled: true; shadowColor: card.profile.color || Tok.accent; shadowBlur: 0.65; shadowOpacity: 0.7 }
        }
        Row { width: parent.width; spacing: 6
            ThemedLogo { visible: card.subtitleIcon.toString().length > 0; artwork: card.subtitleIcon; width: visible ? 16 : 0; height: 16 }

            Text { width: parent.width - (card.subtitleIcon.toString().length ? 22 : 0); text: card.subtitle; elide: Text.ElideRight; font.family: Tok.sans; font.pixelSize: card.compact ? 10 : 12; color: Tok.ink3 }
        }
    }
}
