// Column head / region label: small and quiet. This is the workhorse that makes a
// screen read as a stack of labelled regions instead of a scatter of floating cards.
import QtQuick

IndText {
    mono: true
    sz: Tok.tLabel
    color: Tok.ink2
    font.weight: 600
}
