// Status chip. States a fact — ON, OFF, CONNECTED, 72%. Never decorates, never a pill.
import QtQuick

Rectangle {
    id: c
    property string text: ""
    property string tone: "neutral"        // neutral | ok | warn | crit | accent

    implicitWidth: t.implicitWidth + Tok.s3
    implicitHeight: 18
    radius: Tok.rSmall
    color: c.tone === "ok"     ? Tok.okWash
         : c.tone === "warn"   ? Tok.warnWash
         : c.tone === "crit"   ? Tok.critWash
         : c.tone === "accent" ? Tok.accentWash
         : Tok.surface
    border.width: 1
    border.color: Tok.alpha(t.color, 0.30)

    IndText {
        id: t
        anchors.centerIn: parent
        mono: true
        sz: 10
        text: c.text
        font.weight: 600
        font.letterSpacing: 0.9
        font.capitalization: Font.AllUppercase
        color: c.tone === "ok"     ? Tok.ok
             : c.tone === "warn"   ? Tok.warn
             : c.tone === "crit"   ? Tok.crit
             : c.tone === "accent" ? Tok.accent
             : Tok.ink2
    }
}
