// A hairline. Depth in this language comes from rules and background steps — never shadow,
// never translucency. `hard` marks a section boundary; the default separates rows.
import QtQuick

Rectangle {
    property bool hard: false
    implicitHeight: 1
    color: hard ? Tok.ruleHard : Tok.rule
}
