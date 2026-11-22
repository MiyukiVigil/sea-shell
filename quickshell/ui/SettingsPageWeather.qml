// Settings → Weather. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 3
    visible: root.tab === 3
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "cloud"
        badgeColor: "#32ADE6"
        title: "Weather"
        description: "Set the forecast city and temperature units shown in your menu bar and desktop widgets."
    }

    Section { title: "Location"; icon: "location_on" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 54
            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                spacing: 10
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 34; radius: 8; Layout.alignment: Qt.AlignVCenter
                    color: Tok.bg; border.width: 1
                    border.color: locIn.activeFocus ? Tok.accent : root.cardBorder
                    TextInput {
                        id: locIn
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans
                        clip: true; selectByMouse: true
                        Component.onCompleted: text = root.wxLoc
                        onAccepted: root.saveLoc(text)
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: locIn.text === ""
                            text: "City, e.g. Kuching"
                            color: Tok.ink3; font.pixelSize: 13; font.family: Tok.sans
                        }
                    }
                }
                AccentBtn {
                    Layout.fillWidth: false; implicitWidth: 88; implicitHeight: 34
                    Layout.alignment: Qt.AlignVCenter
                    icon: "check"; label: "Save"
                    onClicked: root.saveLoc(locIn.text)
                }
            }
        }
    }

    Section { title: "Units"; icon: "thermostat" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 48
            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                spacing: 12
                Text { text: "Temperature scale"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 240; Layout.alignment: Qt.AlignVCenter
                    value: root.wxUnit
                    model: [
                        { k: "m", l: "Celsius (°C)" },
                        { k: "u", l: "Fahrenheit (°F)" }
                    ]
                    onPicked: (k) => root.saveUnit(k)
                }
            }
        }
    }
}
