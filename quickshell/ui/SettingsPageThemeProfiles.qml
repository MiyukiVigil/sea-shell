// Settings → ThemeProfiles. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 13
    visible: root.tab === 13; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "auto_awesome"
        badgeColor: "#AF52DE"
        title: "Theme Profiles & Presets"
        description: "Save your active theme, colors, fonts, and bar configuration as reusable presets."
    }

    Section { title: "Theme profiles & presets"; icon: "auto_awesome" }
    Text {
        text: "Save your active layout configuration as a custom preset, or load an existing preset profile."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
    }

    // Save section
    RowLayout {
        Layout.fillWidth: true; spacing: 10
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
            color: theme.a(theme.line, 0.4); border.width: 1; border.color: profNameIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
            TextInput {
                id: profNameIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                color: theme.text; font.pixelSize: 12; font.family: root.apFont
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !profNameIn.text; text: "Enter preset name..."; color: theme.faint; font.pixelSize: 12 }
            }
        }
        Rectangle {
            implicitWidth: 120; implicitHeight: 36; radius: Tok.r
            color: savePrMa.containsMouse ? theme.iris : theme.a(theme.line, 0.6)
            border.width: 1; border.color: theme.a(theme.iris, 0.16)
            Text { anchors.centerIn: parent; text: "Save Preset"; color: savePrMa.containsMouse ? theme.bg : theme.frost; font.pixelSize: 11; font.bold: true; font.family: root.apFont }
            MouseArea {
                id: savePrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (profNameIn.text.trim() !== "") {
                        root.saveProfile(profNameIn.text);
                        profNameIn.text = "";
                    }
                }
            }
        }
    }

    // ---- the rack ----
    // Cartridges, not a list of rows with a Load button. A preset
    // has a palette and no words for it, and the row this replaces
    // spent its width on "font: Adwaita Sans · radius: 14px ·
    // accent: #dbc0c8" — a description of a colour scheme in the
    // one format that cannot show you a colour scheme.
    ColumnLayout {
        Layout.fillWidth: true; spacing: 8
        visible: root.profilesList.length > 0
        Section { title: "Saved presets"; icon: "inventory_2" }
        Text {
            text: "Click a cartridge to load it · the lit lamp is the one you are on"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            Layout.leftMargin: 14; Layout.bottomMargin: 4
        }
        Flow {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 10
            Repeater {
                model: root.profilesList
                delegate: ProfileCart {
                    required property var modelData
                    required property int index
                    profile: modelData
                    loaded: root.profLoaded(modelData)
                    onLoad: root.loadProfile(modelData)   // it persists itself
                    onEject: root.deleteProfile(index)
                }
            }
        }
    }

    // Placeholder
    Text {
        text: "No presets saved yet — set the shell up how you like it, name it above, and save."
        visible: root.profilesList.length === 0
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        Layout.topMargin: 20; horizontalAlignment: Text.AlignHCenter
        Layout.fillWidth: true
    }
}
