import QtQuick
import QtQuick.Layouts

// Authentic macOS segmented control: recessed track with elevated active segment.
Rectangle {
    id: seg
    // model: [{ k, l, i? }]
    property var model: []
    property var value: ""
    signal picked(var key)

    Layout.fillWidth: true
    implicitHeight: 30
    radius: 8
    color: Tok.light ? Qt.rgba(0, 0, 0, 0.06) : Qt.rgba(1, 1, 1, 0.07)
    border.width: 1
    border.color: Tok.light ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(1, 1, 1, 0.06)

    readonly property int selectedIndex: {
        for (var i = 0; i < model.length; i++) {
            if (model[i].k === value) return i;
        }
        return -1;
    }

    // Sliding active capsule
    Rectangle {
        visible: seg.selectedIndex >= 0 && seg.model.length > 0
        y: 2
        height: parent.height - 4
        width: seg.model.length > 0 ? (parent.width - 4) / seg.model.length : 0
        x: 2 + Math.max(0, seg.selectedIndex) * width
        radius: 6
        color: Tok.light ? "#ffffff" : Qt.rgba(1, 1, 1, 0.16)
        border.width: 1
        border.color: Tok.light ? Qt.rgba(0, 0, 0, 0.09) : Qt.rgba(1, 1, 1, 0.12)
        Behavior on x { NumberAnimation { duration: Tok.mFast; easing.type: Easing.OutCubic } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 2
        spacing: 0
        Repeater {
            model: seg.model
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool sel: seg.value === modelData.k
                Layout.fillWidth: true
                Layout.fillHeight: true

                Row {
                    anchors.centerIn: parent
                    spacing: 5
                    Sym {
                        visible: !!(cell.modelData.i && cell.modelData.i.length)
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.i || ""
                        sz: 14
                        color: cell.sel ? Tok.ink : Tok.ink2
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.l
                        color: cell.sel ? Tok.ink : Tok.ink2
                        font.pixelSize: 12
                        font.family: Tok.sans
                        font.weight: cell.sel ? 600 : 400
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(cell.modelData.k)
                }
            }
        }
    }
}
