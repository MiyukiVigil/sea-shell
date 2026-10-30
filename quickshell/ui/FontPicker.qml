import QtQuick
import QtQuick.Controls as C
import QtQuick.Layouts

Rectangle {
    id: picker
    property string text: ""
    property var families: []
    signal picked(string family)
    implicitHeight: 38; implicitWidth: 240
    radius: 10; color: Tok.surface; border.width: 1; border.color: popup.visible ? Tok.accent : Tok.ruleHard
    function choose(family) { picker.text = family; popup.close(); picker.picked(family) }
    Text { anchors { left: parent.left; leftMargin: 12; right: arrow.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: picker.text || "Choose a font"; font.family: picker.text || Tok.sans; font.pixelSize: 13; color: Tok.ink; elide: Text.ElideRight
    }
    Text { id: arrow; anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter } text: "⌄"; font.pixelSize: 18; color: Tok.ink3 }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: popup.visible ? popup.close() : popup.open() }
    C.Popup {
        id: popup
        y: picker.height + 5; width: picker.width; height: 330
        padding: 8; focus: true
        closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
        onOpened: {
            if (!picker.families.length) picker.families = Qt.fontFamilies().sort();
            search.text = ""; list.currentIndex = 0; search.forceActiveFocus()
        }
        background: Rectangle { radius: 12; color: Tok.surface; border.width: 1; border.color: Tok.ruleHard }
        contentItem: ColumnLayout {
            spacing: 6
            C.TextField {
                id: search; Layout.fillWidth: true; implicitHeight: 34
                placeholderText: "Search installed fonts…"; color: Tok.ink; placeholderTextColor: Tok.ink3
                font.family: Tok.sans; font.pixelSize: 12; leftPadding: 10; selectByMouse: true
                background: Rectangle { radius: 8; color: Tok.sunken }
                onTextChanged: list.currentIndex = 0
                Keys.onDownPressed: list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1)
                Keys.onUpPressed: list.currentIndex = Math.max(0, list.currentIndex - 1)
                onAccepted: if (list.count) picker.choose(list.model[list.currentIndex])
            }
            ListView {
                id: list; Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                model: picker.families.filter(function(f) { return f.toLowerCase().indexOf(search.text.toLowerCase()) >= 0 })
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: list.width; height: 36; radius: 7
                    color: index === list.currentIndex || mouse.containsMouse ? Tok.sunken : "transparent"
                    Text { anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        text: modelData; font.family: modelData; font.pixelSize: 14; color: Tok.ink; elide: Text.ElideRight
                    }
                    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.choose(modelData) }
                }
                C.ScrollIndicator.vertical: C.ScrollIndicator {}
            }
            Text { visible: list.count === 0; text: "No matching fonts"; color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 12 }
        }
    }
}
