// Settings → Menu Bar (macOS Control Center & Menu Bar hub).
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 20
    visible: root.tab === 20
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "view_agenda"
        badgeColor: "#32ADE6"
        title: "Menu Bar"
        description: "Configure the top menu bar's style, workspaces, mark, widgets, and global application menu."
    }

    Section { title: "Control Center & Widgets"; icon: "widgets" }
    MacList {
        MacNavRow {
            icon: "widgets"; badgeColor: "#32ADE6"
            title: "Menu Bar Widgets & Global Menu"
            subtitle: "Reorder widgets, toggle visibility, AI usage tracker, system monitor, and Global Menu"
            destination: 12
        }
    }

    Section { title: "Shape"; icon: "view_agenda" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Bar layout"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 230; Layout.alignment: Qt.AlignVCenter
                    value: root.apBarShape
                    model: [
                        { k: "bar", l: "Full strip", i: "rectangle" },
                        { k: "pills", l: "Floating pills", i: "view_week" }
                    ]
                    onPicked: (k) => { root.apBarShape = k; root.saveAppearance() }
                }
            }
        }
    }

    Section { title: "Bar shape"; icon: "tune" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Position"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 260; Layout.alignment: Qt.AlignVCenter
                    value: root.apEdge
                    model: [
                        { k: "top", l: "Top" },
                        { k: "bottom", l: "Bottom" },
                        { k: "left", l: "Left" },
                        { k: "right", l: "Right" }
                    ]
                    onPicked: (k) => { root.apEdge = k; root.saveAppearance() }
                }
            }
        }
        MacDivider {}
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Material"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 240; Layout.alignment: Qt.AlignVCenter
                    value: root.apGlass
                    model: [
                        { k: "solid", l: "Solid" },
                        { k: "frosted", l: "Frosted" },
                        { k: "clear", l: "Clearer" }
                    ]
                    onPicked: (k) => { root.apGlass = k; root.saveAppearance() }
                }
            }
        }
        MacDivider {}
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Bar fill"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 240; Layout.alignment: Qt.AlignVCenter
                    value: root.apBarFill
                    model: [
                        { k: "matugen", l: "Theme" },
                        { k: "black", l: "Black" },
                        { k: "white", l: "White" }
                    ]
                    onPicked: (k) => { root.apBarFill = k; root.saveAppearance() }
                }
            }
        }
        MacDivider {}
        SliderRow {
            icon: "height"; label: "Bar height"
            value: (root.apHeight - 34) / 20
            readout: Math.round(root.apHeight) + " px"
            onMoved: (v) => { root.apHeight = 34 + v * 20; root.saveAppearance() }
        }
        MacDivider {}
        SliderRow {
            icon: "rounded_corner"; label: "Corner roundness"
            value: root.apRadius / 26
            readout: Math.round(root.apRadius) + " px"
            onMoved: (v) => { root.apRadius = v * 26; root.saveAppearance() }
        }
        MacDivider {}
        ToggleCard {
            icon: "swipe_up"; title: "Automatically hide and show menu bar"
            desc: "Hide the bar until you move the pointer to the screen edge."
            on: root.apAutoHide; onToggled: { root.apAutoHide = !root.apAutoHide; root.saveAppearance() }
        }
        MacDivider { visible: !root.apAutoHide }
        ToggleCard {
            visible: !root.apAutoHide; icon: "fullscreen"; title: "Auto-hide in full screen only"
            desc: "Keep the bar visible on the desktop and hide it during full-screen apps and games."
            on: root.apHideFullscreen; onToggled: { root.apHideFullscreen = !root.apHideFullscreen; root.saveAppearance() }
        }
    }

    Section { title: "Workspaces"; icon: "grid_view" }
    MacList {
        Item {
            Layout.fillWidth: true; implicitHeight: 46
            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                spacing: 12
                Text { text: "Indicator style"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter }
                MacSegmented {
                    Layout.fillWidth: false; Layout.preferredWidth: 240; Layout.alignment: Qt.AlignVCenter
                    value: root.apWsStyle
                    model: [
                        { k: "grow", l: "Grow" },
                        { k: "pill", l: "Pills" },
                        { k: "circle", l: "Circles" }
                    ]
                    onPicked: (k) => { root.apWsStyle = k; root.saveAppearance() }
                }
            }
        }
    }

    Section { title: "Numbering"; icon: "format_list_numbered" }
    Flow {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; Layout.bottomMargin: 6; spacing: 7
        Repeater {
            model: root.wsLabelChoices
            delegate: Chip {
                required property var modelData
                label: modelData.l
                labelFont: modelData.k === "dice" ? root.symbolFamily : Tok.mono
                visible: modelData.k !== "dice" || root.symbolFamily !== ""
                on: root.apWsLabel === modelData.k
                onPicked: { root.apWsLabel = modelData.k; root.saveAppearance() }
            }
        }
    }

    Section { title: "The mark"; icon: "stars" }
    Flow {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; Layout.bottomMargin: 6; spacing: 7
        Repeater {
            model: root.barLogoChoices
            delegate: Rectangle {
                required property var modelData
                readonly property bool sel: root.apBarLogo === modelData.k
                implicitWidth: lgRow.implicitWidth + 20; implicitHeight: 32; radius: 7
                color: sel ? Tok.accent : (lgMa.containsMouse ? root.rowHover : (Tok.light ? Qt.rgba(0,0,0,0.04) : Qt.rgba(1,1,1,0.06)))
                border.width: 1; border.color: sel ? Tok.accent : root.cardBorder
                Behavior on color { ColorAnimation { duration: Tok.mMicro } }
                Row {
                    id: lgRow; anchors.centerIn: parent; spacing: 6
                    BarLogo {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.k !== "auto" && modelData.k !== "custom"
                        kind: modelData.k; size: 16
                        card: sel ? Tok.accentInk : Tok.surface
                        accent: sel ? Tok.accentInk : Tok.accent
                        highlight: sel ? Tok.accentInk : Tok.ink
                        rim: sel ? Tok.accentInk : Tok.accent
                    }
                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.k === "auto" || modelData.k === "custom"
                        text: modelData.k === "auto" ? "auto_awesome" : "image"
                        sz: 15; color: sel ? Tok.accentInk : Tok.ink2
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Tok.cap(modelData.l)
                        color: sel ? Tok.accentInk : Tok.ink
                        font.pixelSize: 12; font.family: Tok.sans; font.weight: sel ? 600 : 400
                    }
                }
                MouseArea {
                    id: lgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.apBarLogo = modelData.k;
                        root.saveAppearance();
                        if (modelData.k === "custom" && !root.apBarLogoPath.length)
                            root.pickFile("Bar logo image", "*.png", function (f) {
                                root.apBarLogoPath = f; root.saveAppearance();
                            });
                    }
                }
            }
        }
    }
    RowLayout {
        visible: root.apBarLogo === "custom"
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 32; radius: 7
            color: Tok.bg; border.width: 1; border.color: root.cardBorder
            Text {
                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                verticalAlignment: Text.AlignVCenter
                text: root.apBarLogoPath.length ? root.apBarLogoPath : "No image chosen"
                color: root.apBarLogoPath.length ? Tok.ink : Tok.ink3
                font.pixelSize: 12; font.family: Tok.sans; elide: Text.ElideLeft
            }
        }
        Chip {
            label: "Choose…"; icon: "folder_open"
            onPicked: root.pickFile("Bar logo image", "*.png", function (f) {
                root.apBarLogoPath = f; root.saveAppearance();
            })
        }
    }
}
