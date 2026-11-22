// Settings → General → Language & Region. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 32
    visible: root.tab === 32
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "language"
        badgeColor: "#8E8E93"
        title: "Language & Region"
        description: "Set your system locale, temperature scale, and regional formatting preferences."
    }

    Section { title: "System Locale"; icon: "translate" }
    MacList {
        MacInfoRow { label: "Current Locale (LANG)"; value: root.localeInfo.lang || "en_US.UTF-8"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Date & Time Format"; value: root.localeInfo.lcTime || "—"; mono: true }
        MacDivider {}
        MacInfoRow { label: "Measurement Format"; value: root.localeInfo.lcMeasurement || "—"; mono: true }
        MacDivider {}
        ColumnLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10; Layout.bottomMargin: 10; spacing: 8
            Text { text: "Installed locales"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: root.localeInfo.locales || []
                    delegate: Chip {
                        required property string modelData
                        label: modelData
                        on: root.localeInfo.lang === modelData
                        onPicked: root.setSystemLocale(modelData)
                    }
                }
            }
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: "Changing the system locale applies to new applications and after your next login. Generate additional locales in /etc/locale.gen if needed."
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
            }
        }
    }

    Section { title: "Temperature & Weather Units"; icon: "thermostat" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Temperature"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
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

    Text {
        visible: root.sysMsg !== ""
        Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; wrapMode: Text.WordWrap
        text: root.sysMsg; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans
    }
}
