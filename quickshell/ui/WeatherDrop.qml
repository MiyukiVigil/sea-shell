// sea-shell — Weather dropdown body (extracted from shell.qml).
import QtQuick

Column {
    id: wx
    property var shellRoot: null
    spacing: 8

    Row {
        width: parent.width; spacing: 10
        Sym { anchors.verticalCenter: parent.verticalCenter; text: shellRoot ? shellRoot.wxIcon(shellRoot.wxCond) : "cloud"; sz: 30; color: Tok.accent }
        Column {
            anchors.verticalCenter: parent.verticalCenter; spacing: 1; width: parent.width - 40
            Text { text: shellRoot ? shellRoot.wxTemp : ""; color: Tok.ink; font.pixelSize: 20; font.family: Tok.sans; font.bold: true }
            Text {
                width: parent.width; text: shellRoot ? shellRoot.wxCond : ""; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            }
        }
    }

    Rectangle { width: parent.width; height: 1; color: Tok.rule }

    Repeater {
        model: shellRoot ? [
            { i: "thermostat",          l: "Feels like", v: shellRoot.wxFeels },
            { i: "humidity_percentage", l: "Humidity",   v: shellRoot.wxHumid },
            { i: "air",                 l: "Wind",       v: shellRoot.wxWind }
        ] : []
        delegate: Item {
            required property var modelData
            width: parent.width; height: 20
            Sym { id: wxdIc; anchors.verticalCenter: parent.verticalCenter; text: modelData.i; sz: 15; color: Tok.accent }
            Text { anchors { left: wxdIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter } text: modelData.l; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Text {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: Math.min(implicitWidth, parent.width - 110); elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                text: modelData.v; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans
            }
        }
    }

    Rectangle { width: parent.width; height: 1; color: Tok.rule; visible: !!(shellRoot && shellRoot.wxForecast.length > 0) }
    Text { visible: !!(shellRoot && shellRoot.wxForecast.length > 0); text: "Forecast"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
    Repeater {
        model: shellRoot ? shellRoot.wxForecast : []
        delegate: Row {
            required property var modelData
            width: parent.width; height: 26; spacing: 8
            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.day; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; width: 46 }
            Sym { anchors.verticalCenter: parent.verticalCenter; text: shellRoot ? shellRoot.wxIcon(modelData.cond) : "cloud"; sz: 17; color: Tok.accent }
            Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 168; elide: Text.ElideRight; text: modelData.cond; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.hi; color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono }
            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.lo; color: Tok.ink3; font.pixelSize: 12; font.family: Tok.mono }
        }
    }

    Rectangle { width: parent.width; height: 1; color: Tok.rule }
    Item {
        width: parent.width; height: 26
        Row {
            anchors.fill: parent; spacing: 8
            Sym { anchors.verticalCenter: parent.verticalCenter; text: "settings"; sz: 15; color: Tok.ink2 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Set location / units"; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
        }
        MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onClicked: if (shellRoot) { shellRoot.openPop = ""; shellRoot.openSettings(3) }
        }
    }
}
