// Settings → Appearance. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 4
    visible: root.tab === 4; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "palette"
        badgeColor: "#AF52DE"
        title: "Appearance"
        description: "Choose Light or Dark mode, accent color, fonts, application icons, wallpaper theming, and saved theme profiles."
        note: "Appearance saves automatically; some open apps may need reopening to refresh icons."
    }

    // Authentic macOS segmented control for Appearance sub-views
    MacSegmented {
        value: root.apSubTab
        model: [
            { i: "palette", l: "Look", k: 0 },
            { i: "wallpaper", l: "Wallpaper", k: 1 },
            { i: "tune", l: "Advanced", k: 2 }
        ]
        onPicked: (k) => root.apSubTab = k
    }

    AppearancePreview {
        Layout.fillWidth: true
        visible: root.apSubTab === 0
        property int appearanceSubTab: 0
        baseLight: root.apLight; baseAccent: root.apAccent; baseFont: root.apFont
        baseSolid: root.apBarOpaque; baseIconTheme: root.apIconTheme
        iconCatalog: root.iconPreviewCatalog; fonts: root.fontPresets; barFill: root.apBarFill
        onApplied: (light, accent, fontName, solid, iconTheme) => {
            var accentChanged = root.apAccent.toString() !== accent.toString();
            root.apModeSource = "manual";
            root.apLight = light; root.apFont = fontName; root.apBarOpaque = solid;
            root.apAccent = accent; root.apIconTheme = iconTheme;
            if (accentChanged) root.apMatugen = false;
            root.applyIconTheme(iconTheme);
            root.applyAppMode();
            if (accentChanged) root.afterAppearanceSave(function() { Quickshell.execDetached(["sh", root.matugenScript]); });
        }
    }

    // LOOK: macOS visual appearance cards, accent color wells, profiles, font, icons
    ColumnLayout {
        property int appearanceSubTab: 0
        visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 12
        Section { title: "Theme"; icon: "contrast" }
        // macOS Light / Dark / Auto visual desktop preview tiles
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 14
            Text { text: "Appearance"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true }
            RowLayout {
                spacing: 12
                Repeater {
                    model: [
                        { k: "light", l: "Light", active: root.apModeSource === "manual" && root.apLight },
                        { k: "dark",  l: "Dark",  active: root.apModeSource === "manual" && !root.apLight },
                        { k: "auto",  l: "Auto",  active: root.apModeSource !== "manual" }
                    ]
                    delegate: ColumnLayout {
                        id: modeTile
                        required property var modelData
                        spacing: 5
                        Rectangle {
                            implicitWidth: 74; implicitHeight: 48; radius: 8
                            border.width: modeTile.modelData.active ? 2 : 1
                            border.color: modeTile.modelData.active ? Tok.accent : root.cardBorder
                            clip: true
                            color: modeTile.modelData.k === "light" ? "#eef1f6" : "#181c24"
                            // Split half-light / half-dark preview for Auto
                            Rectangle {
                                visible: modeTile.modelData.k === "auto"
                                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                width: parent.width / 2
                                color: "#eef1f6"
                            }
                            // Mini menu bar strip
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; top: parent.top }
                                height: 8
                                color: modeTile.modelData.k === "light" ? Qt.rgba(1,1,1,0.85) : Qt.rgba(0,0,0,0.45)
                            }
                            // Mini window card
                            Rectangle {
                                anchors.centerIn: parent; anchors.verticalCenterOffset: 3
                                width: 44; height: 24; radius: 4
                                color: modeTile.modelData.k === "light" ? "#ffffff" : "#252a36"
                                border.width: 1; border.color: Qt.rgba(0.5, 0.5, 0.5, 0.25)
                                Row {
                                    anchors { left: parent.left; top: parent.top; margins: 4 }
                                    spacing: 3
                                    Rectangle { width: 4; height: 4; radius: 2; color: "#FF5F56" }
                                    Rectangle { width: 4; height: 4; radius: 2; color: "#FFBD2E" }
                                    Rectangle { width: 4; height: 4; radius: 2; color: "#27C93F" }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modeTile.modelData.k === "light") {
                                        root.apModeSource = "manual"; root.apAutoDark = false; root.apLight = true; root.saveAppearance();
                                    } else if (modeTile.modelData.k === "dark") {
                                        root.apModeSource = "manual"; root.apAutoDark = false; root.apLight = false; root.saveAppearance();
                                    } else {
                                        root.apModeSource = "clock"; root.apAutoDark = true; root.saveAppearance();
                                    }
                                }
                            }
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: modeTile.modelData.l
                            color: modeTile.modelData.active ? Tok.accent : Tok.ink2
                            font.pixelSize: 11; font.family: Tok.sans
                            font.weight: modeTile.modelData.active ? 600 : 400
                        }
                    }
                }
            }
        }
        MacDivider {}
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
            Text { text: "Auto switch source"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true }
            MacSegmented {
                Layout.fillWidth: false; Layout.preferredWidth: 250
                value: root.apModeSource
                model: [
                    { k: "manual",    l: "Manual" },
                    { k: "clock",     l: "Schedule" },
                    { k: "wallpaper", l: "Wallpaper" }
                ]
                onPicked: (k) => {
                    root.apModeSource = k;
                    root.apAutoDark = (k === "clock");
                    root.saveAppearance();
                    if (k === "wallpaper") root.applyModeFromWallpaper();
                }
            }
        }
        Text {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            wrapMode: Text.WordWrap; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
            text: root.apModeSource === "clock"
                  ? "Switches to Dark mode automatically during the scheduled hours below."
                  : root.apModeSource === "wallpaper"
                  ? "Adapts to each wallpaper's brightness. Press Super+Shift+D anytime to switch manually."
                  : "Stays on your chosen Light or Dark mode until toggled here or with Super+Shift+D."
        }
        RowLayout { visible: root.apModeSource === "clock"; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
            Sym { text: "schedule"; sz: 17; color: Tok.ink2 }
            Text { text: "Dark from"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Rectangle { implicitWidth: 68; implicitHeight: 30; radius: 7; color: Tok.bg; border.width: 1; border.color: dstart.activeFocus ? Tok.accent : root.cardBorder
                TextInput { id: dstart; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; inputMask: "99:99;_"; text: root.apDarkStart
                    onEditingFinished: { root.apDarkStart = text; root.saveAppearance() } } }
            Text { text: "to"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Rectangle { implicitWidth: 68; implicitHeight: 30; radius: 7; color: Tok.bg; border.width: 1; border.color: dend.activeFocus ? Tok.accent : root.cardBorder
                TextInput { id: dend; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                    color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; inputMask: "99:99;_"; text: root.apDarkEnd
                    onEditingFinished: { root.apDarkEnd = text; root.saveAppearance() } } }
            Item { Layout.fillWidth: true } }
        MacDivider {}
        MacNavRow {
            icon: "auto_awesome"; badgeColor: "#AF52DE"
            title: "Theme Profiles & Presets"
            subtitle: "Save your current look or switch between complete theme presets"
            value: root.profilesList.length > 0 ? (root.profilesList.length + " saved") : ""
            destination: 13
        }
    }

    // Look, continued: macOS circular accent color wells
    ColumnLayout {
        property int appearanceSubTab: 0
        visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 12
        Section { title: "Accent colour"; icon: "palette" }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
            Text { text: "Accent color"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; Layout.fillWidth: true }
            Flow {
                Layout.maximumWidth: 380; spacing: 8
                Repeater {
                    model: root.accents
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool sel: root.apAccent.toLowerCase() === modelData.toLowerCase()
                        width: 24; height: 24; radius: 12; color: modelData
                        border.width: sel ? 2 : 1
                        border.color: sel ? Tok.ink : Qt.rgba(0, 0, 0, 0.18)
                        Rectangle {
                            anchors.centerIn: parent; visible: parent.sel
                            width: 8; height: 8; radius: 4; color: "#ffffff"
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickAccent(modelData) }
                    }
                }
            }
        }
        MacDivider {}
        ToggleCard { icon: "colorize"; title: "Auto colours from wallpaper"
            desc: "Recolours the shell and kitty automatically on every wallpaper change."
            on: root.apMatugen; onToggled: root.toggleMatugen() }
        ColumnLayout { Layout.fillWidth: true; spacing: 8; visible: root.apMatugen
            RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
                Sym { text: "tune"; sz: 15; color: Tok.ink3 }
                Text { text: "Colour scheme"; color: Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
                Item { Layout.fillWidth: true }
                Text { text: root.apScheme.replace("scheme-",""); color: Tok.accent; font.pixelSize: 11; font.family: Tok.sans; font.weight: 600 } }
            Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
                Repeater { model: root.schemes
                    delegate: Chip { required property var modelData; label: (""+modelData).replace("scheme-",""); on: root.apScheme===modelData
                        onPicked: root.setScheme(modelData) } } } }
        RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            AccentBtn { icon: root.matugenBusy?"sync":"auto_awesome"; label: root.matugenBusy ? "Matching…" : "Extract palette from wallpaper"; onClicked: root.matchWallpaper() }
            Chip { label: "Eyedropper"; icon: "colorize"; onPicked: { root.pickingTarget = "accent"; colorPickerProc.running = true } } }
        Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8; visible: root.matugenPalette.length>0
            Repeater { model: root.matugenPalette
                delegate: Rectangle { required property var modelData; readonly property bool sel: root.apAccent.toLowerCase()===modelData.toLowerCase()
                    width: 26; height: 26; radius: 13; color: modelData
                    border.width: sel?2:1; border.color: sel?Tok.ink:Qt.rgba(0,0,0,0.2)
                    Rectangle { anchors.centerIn: parent; visible: parent.sel; width: 8; height: 8; radius: 4; color: "#ffffff" }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickPaletteAccent(modelData) } } } }
    }

    // Look, continued: font
    ColumnLayout {
        property int appearanceSubTab: 0
        visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 12
        Section { title: "Font"; icon: "font_download" }
        Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
            Repeater { model: root.fontPresets
                delegate: Rectangle { required property var modelData; readonly property bool sel: root.apFont===modelData
                    implicitWidth: ft.implicitWidth+22; implicitHeight: 32; radius: Tok.r
                    color: sel?theme.iris:(fmm.containsMouse?theme.a(theme.iris,0.16):theme.a(theme.line,0.4)); border.width: 1; border.color: sel?theme.iris:theme.a(theme.iris,0.16)
                    Text { id: ft; anchors.centerIn: parent; text: modelData; color: sel?theme.bg:theme.text; font.pixelSize: 12; font.family: Tok.resolveFont(modelData); font.bold: sel }
                    MouseArea { id: fmm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.apFont=modelData; root.saveAppearance() } } } } }
        FontPicker {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            text: root.apFont
            onPicked: function(family) { root.addCustomFont(family) }
        }
        Text { text: "Changes apply to the bar live"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14 }
    }

    // Look, continued: application icons, after the font
    ColumnLayout {
        property int appearanceSubTab: 0
        visible: root.apSubTab === 0; Layout.fillWidth: true; spacing: 12
        Section { title: "Application icons"; icon: "folder" }
        Text { Layout.fillWidth: true; Layout.leftMargin: 14; wrapMode: Text.WordWrap
            text: "Choose one icon family for Files and desktop applications. Light and dark variants follow your theme."
            color: theme.sub; font.pixelSize: 11; font.family: Tok.sans }
        Flow { Layout.fillWidth: true; Layout.leftMargin: 14; spacing: 8
            Repeater { model: root.installedIconThemes
                delegate: Chip { required property var modelData
                    label: modelData; icon: "folder"; on: root.apIconTheme === modelData
                    onPicked: root.applyIconTheme(modelData) }
            }
        }
        ToggleCard { icon: "palette"; title: "Folders follow wallpaper colour"
            desc: "Papirus folders use the nearest accent colour; requires the folder helper."
            on: root.apFolderColorFollow
            onToggled: { root.apFolderColorFollow = !root.apFolderColorFollow; root.saveAppearance();
                root.afterAppearanceSave(function() { Quickshell.execDetached(["python3", Qt.resolvedUrl("sea-folder-color.py").toString().replace("file://", "")]); }) }
        }
        Chip { Layout.leftMargin: 14; label: "Reset folder colour"; icon: "restart_alt"
            onPicked: { root.apFolderColorFollow = false; root.saveAppearance();
                root.afterAppearanceSave(function() { Quickshell.execDetached(["python3", Qt.resolvedUrl("sea-folder-color.py").toString().replace("file://", ""), "--reset"]); }) }
        }
        Text { Layout.leftMargin: 14; text: root.iconApplyState || "Some running applications need reopening to refresh their icons."
            color: root.iconApplyFailed ? theme.bad : theme.faint; font.pixelSize: 11; font.family: Tok.sans }

        // A picture of your choosing stuck on the corner of the power menu and the
        // media dropdown (a GIF moves while the panel is open). None by default.
    }

    // ADVANCED: per-target colour overrides
    ColumnLayout {
        property int appearanceSubTab: 2
        visible: root.apSubTab === 2; Layout.fillWidth: true; spacing: 14
        // ---------- per-target colour overrides ----------
        ColumnLayout { Layout.fillWidth: true; spacing: 8
            Section { title: "Colour targets"; icon: "tune" }
            Text { text: "Choose which apps follow the accent or use custom colours."; color: theme.faint; font.pixelSize: 11; font.family: root.apFont }
            // Hyprland borders
            Rectangle { Layout.fillWidth: true; implicitHeight: hyprCol.implicitHeight + 20; radius: Tok.r
                color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrHyprland?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                ColumnLayout { id: hyprCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "border_style"; sz: 18; color: root.ovrHyprland?theme.frost:theme.faint }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: "Hyprland borders"; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: "Window active/inactive border colours"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight } }
                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                            color: root.ovrHyprland?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrHyprland?theme.iris:theme.a(theme.iris,0.3)
                            Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrHyprland ? 27 : 3; color: root.ovrHyprland ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprland=!root.ovrHyprland; root.toggleOverride("hyprland") } } } }
                    // custom border colours (only visible when auto-match is OFF)
                    ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrHyprland
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Active"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprActive || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: haIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: haIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrHyprActive
                                    onEditingFinished: { root.ovrHyprActive=text.trim(); root.toggleOverride("hyprland") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !haIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: haEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: haEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprActive"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprActive = modelData; root.toggleOverride("hyprland") } } } } }
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Inactive"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprInactive || theme.a(root.apAccent,0.4); border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: hiIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: hiIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrHyprInactive
                                    onEditingFinished: { root.ovrHyprInactive=text.trim(); root.toggleOverride("hyprland") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !hiIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: hiEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: hiEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "hyprInactive"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprInactive = modelData; root.toggleOverride("hyprland") } } } } } } } }
            // Hyprland window glow (decoration:shadow) — a separate target
            // from the borders on purpose: a matched border with a fixed
            // glow is a real preference, and they used to be welded together
            // only because the glow simply never followed the wallpaper.
            Rectangle { Layout.fillWidth: true; implicitHeight: glowCol.implicitHeight + 20; radius: Tok.r
                color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrHyprGlow?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                ColumnLayout { id: glowCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "blur_on"; sz: 18; color: root.ovrHyprGlow?theme.frost:theme.faint }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: "Hyprland window glow"; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: "The coloured shadow around the focused window"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight } }
                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                            color: root.ovrHyprGlow?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrHyprGlow?theme.iris:theme.a(theme.iris,0.3)
                            Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrHyprGlow ? 27 : 3; color: root.ovrHyprGlow ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprGlow=!root.ovrHyprGlow; root.toggleOverride("hyprGlow") } } } }
                    ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrHyprGlow
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Glow"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrHyprGlowColor || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: hgIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: hgIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrHyprGlowColor
                                    onEditingFinished: { root.ovrHyprGlowColor=text.trim(); root.toggleOverride("hyprGlow") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !hgIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrHyprGlowColor = modelData; root.toggleOverride("hyprGlow") } } } } } } } }
            // Kitty terminal
            Rectangle { Layout.fillWidth: true; implicitHeight: kittyCol.implicitHeight + 20; radius: Tok.r
                color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrKitty?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                ColumnLayout { id: kittyCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "terminal"; sz: 18; color: root.ovrKitty?theme.frost:theme.faint }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: "Kitty terminal"; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: "Terminal colour palette and background"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight } }
                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                            color: root.ovrKitty?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrKitty?theme.iris:theme.a(theme.iris,0.3)
                            Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrKitty ? 27 : 3; color: root.ovrKitty ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKitty=!root.ovrKitty; root.toggleOverride("kitty") } } } }
                    // custom kitty colors
                    ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrKitty
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrKittyAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: kaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: kaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrKittyAccent
                                    onEditingFinished: { root.ovrKittyAccent=text.trim(); root.toggleOverride("kitty") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !kaIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: kaEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: kaEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyAccent"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyAccent = modelData; root.toggleOverride("kitty") } } } } }
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "bg"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrKittyBg || "#171729"; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: kbIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: kbIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrKittyBg
                                    onEditingFinished: { root.ovrKittyBg=text.trim(); root.toggleOverride("kitty") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !kbIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: kbEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: kbEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "kittyBg"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: ["#0f141d","#171729","#1a1b26","#1e1e2e","#282828","#000000"].concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrKittyBg = modelData; root.toggleOverride("kitty") } } } } } } } }
            // Fastfetch
            Rectangle { Layout.fillWidth: true; implicitHeight: ffCol.implicitHeight + 20; radius: Tok.r
                color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrFastfetch?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                ColumnLayout { id: ffCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "info"; sz: 18; color: root.ovrFastfetch?theme.frost:theme.faint }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: "Fastfetch"; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: "System info key + logo accent colour"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight } }
                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                            color: root.ovrFastfetch?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrFastfetch?theme.iris:theme.a(theme.iris,0.3)
                            Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrFastfetch ? 27 : 3; color: root.ovrFastfetch ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetch=!root.ovrFastfetch; root.toggleOverride("fastfetch") } } } }
                    // custom fastfetch accent
                    ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrFastfetch
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrFastfetchAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: ffaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: ffaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrFastfetchAccent
                                    onEditingFinished: { root.ovrFastfetchAccent=text.trim(); root.toggleOverride("fastfetch") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !ffaIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: ffEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: ffEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "fastfetch"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrFastfetchAccent = modelData; root.toggleOverride("fastfetch") } } } } } } } }
            // Starship prompt
            Rectangle { Layout.fillWidth: true; implicitHeight: ssCol.implicitHeight + 20; radius: Tok.r
                color: theme.a(theme.line,0.4); border.width: 1; border.color: root.ovrStarship?theme.a(theme.iris,0.5):theme.a(theme.iris,0.16)
                ColumnLayout { id: ssCol; anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout { Layout.fillWidth: true; spacing: 10
                        Sym { text: "star"; sz: 18; color: root.ovrStarship?theme.frost:theme.faint }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: "Starship prompt"; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: "Terminal prompt accent colours"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight } }
                        Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                            color: root.ovrStarship?theme.iris:theme.a(theme.line,0.85); border.width: 1; border.color: root.ovrStarship?theme.iris:theme.a(theme.iris,0.3)
                            Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.ovrStarship ? 27 : 3; color: root.ovrStarship ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrStarship=!root.ovrStarship; root.toggleOverride("starship") } } } }
                    // custom starship accent
                    ColumnLayout { Layout.fillWidth: true; spacing: 6; visible: !root.ovrStarship
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Text { text: "Accent"; color: theme.sub; font.pixelSize: 11; font.family: root.apFont; Layout.minimumWidth: 46 }
                            Rectangle { implicitWidth: 16; implicitHeight: 16; radius: Tok.r; color: root.ovrStarshipAccent || root.apAccent; border.width: 1; border.color: theme.a(theme.text,0.2) }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 28; radius: Tok.r; color: theme.a(theme.line,0.5); border.width: 1; border.color: ssaIn.activeFocus?theme.iris:theme.a(theme.iris,0.2)
                                TextInput { id: ssaIn; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 11; font.family: Tok.sans; clip: true; selectByMouse: true; text: root.ovrStarshipAccent
                                    onEditingFinished: { root.ovrStarshipAccent=text.trim(); root.toggleOverride("starship") }
                                    Text { anchors.verticalCenter: parent.verticalCenter; visible: !ssaIn.text; text: "Auto"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } } }
                            Rectangle { implicitWidth: 28; implicitHeight: 28; radius: Tok.r
                                color: ssEdm.containsMouse ? theme.a(theme.iris, 0.2) : theme.a(theme.line, 0.4)
                                border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                Sym { anchors.centerIn: parent; text: "colorize"; sz: 14; color: theme.frost }
                                MouseArea { id: ssEdm; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.pickingTarget = "starship"; colorPickerProc.running = true } } } }
                        Flow { Layout.fillWidth: true; spacing: 4; Layout.leftMargin: 54
                            Repeater { model: root.accents.concat(root.matugenPalette)
                                delegate: Rectangle { required property var modelData; width: 16; height: 16; radius: Tok.r; color: modelData; border.width: 1; border.color: theme.a(theme.text, 0.2)
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.ovrStarshipAccent = modelData; root.toggleOverride("starship") } } } } } } } }
        }
    }

    // Advanced, continued: things most people set once or never
    ColumnLayout {
        property int appearanceSubTab: 2
        visible: root.apSubTab === 2; Layout.fillWidth: true; spacing: 12
        Section { title: "App preference"; icon: "apps" }
        Text { text: "controls GTK / Qt app themes independently from the shell"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14 }
        Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
            Repeater { model: [{k:"auto",l:"auto",i:"sync"},{k:"dark",l:"dark",i:"dark_mode"},{k:"light",l:"light",i:"light_mode"}]
                delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.apAppMode===modelData.k
                    onPicked: { root.apAppMode=modelData.k; root.saveAppearance(); root.applyAppMode() } } } }
        Text { visible: root.apAppMode!=="auto"; text: "Apps will stay " + root.apAppMode + " regardless of shell theme"; color: theme.iris; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14 }
        Section { title: "Stickers"; icon: "add_reaction" }
        Repeater {
            model: [{ k: "power", l: "power menu" }, { k: "media", l: "media" }]
            delegate: RowLayout {
                required property var modelData
                readonly property string path: modelData.k === "power" ? root.apStickerPower : root.apStickerMedia
                function setPath(f) {
                    if (modelData.k === "power") root.apStickerPower = f; else root.apStickerMedia = f;
                    root.saveAppearance();
                }
                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
                Text { text: modelData.l; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 90 }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                    color: theme.a(theme.line, 0.4)
                    border.width: 1; border.color: theme.a(theme.iris, 0.16)
                    Text {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        verticalAlignment: Text.AlignVCenter
                        text: parent.parent.path.length ? parent.parent.path : "None"
                        color: parent.parent.path.length ? theme.text : theme.faint
                        font.pixelSize: 11; font.family: Tok.sans; elide: Text.ElideLeft
                    }
                }
                Chip { label: "choose…"; icon: "folder_open"
                    onPicked: root.pickFile(modelData.l + " sticker", "*.gif *.png *.webp *.jpg *.jpeg", function (f) { parent.setPath(f) }) }
                Chip { visible: parent.path.length > 0; label: "Remove"; icon: "close"; onPicked: parent.setPath("") }
            }
        }
    }

    // WALLPAPER — folder · transition · rotation · pair · motion
    ColumnLayout {
        id: wpTab
        property int appearanceSubTab: 1
        visible: root.apSubTab === 1; Layout.fillWidth: true; spacing: 12
        // "" | day | night — which cartridge slot the shelf is filling.
        property string armed: ""
        // Both: onVisibleChanged covers arriving at the tab, and
        // Component.onCompleted covers the panel opening with this
        // tab already selected — where visibility never changes and
        // the shelf would sit empty saying "0 wallpapers".
        onVisibleChanged: if (visible && !root.wpIndex.length) root.rescanWallpapers()
        Component.onCompleted: if (visible && !root.wpIndex.length) root.rescanWallpapers()
        // …and whenever the PANEL opens. The two above only fire when
        // this tab's visibility changes, so a panel left sitting on
        // this tab with an empty index — which is what an earlier
        // failed scan leaves behind — had no way to try again short of
        // the re-scan button.
        Connections {
            target: root
            function onShownChanged() {
                if (root.shown && wpTab.visible && !root.wpIndex.length)
                    root.rescanWallpapers();
            }
        }

        Section { title: "Wallpaper folder"; icon: "folder_open" }
        Text {
            text: "The picker, Super+N shortcuts and auto-rotate all use this folder."
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            Layout.leftMargin: 14
        }
        Rectangle {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            implicitHeight: 38; radius: Tok.r
            color: theme.a(theme.line, 0.4)
            border.width: 1
            border.color: wpDirIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10
                spacing: 8
                Sym { text: "folder"; sz: 17; color: theme.sub }
                TextInput {
                    id: wpDirIn
                    Layout.fillWidth: true
                    verticalAlignment: TextInput.AlignVCenter
                    color: theme.text; font.pixelSize: 13; font.family: Tok.sans
                    clip: true; selectByMouse: true
                    selectionColor: theme.a(theme.iris, 0.4)
                    Component.onCompleted: text = root.apWpDir
                    // Committed on ↵, not on every keystroke: saving per character
                    // would re-scan the folder once per letter of the path you are
                    // still halfway through typing.
                    onAccepted: {
                        root.apWpDir = text.trim().length ? text.trim() : "~/Pictures/wallpapers";
                        wpDirIn.text = root.apWpDir;
                        root.saveAppearance();
                        root.rescanWallpapers();
                    }
                }
                Text {
                    visible: wpDirIn.text.trim() !== root.apWpDir
                    text: "↵ to save"; color: theme.iris
                    font.pixelSize: 11; font.family: Tok.sans
                }
                Rectangle {
                    implicitWidth: 28; implicitHeight: 26; radius: Tok.rSmall
                    color: wpBrowseMa.containsMouse ? theme.a(theme.iris, 0.22) : "transparent"
                    border.width: 1; border.color: theme.a(theme.iris, 0.25)
                    Sym { anchors.centerIn: parent; text: "folder_open"; sz: 15
                          color: wpBrowseMa.containsMouse ? theme.iris : theme.sub }
                    MouseArea {
                        id: wpBrowseMa
                        anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickFolder("wallpaper folder",
                                                   root.expandHome(root.apWpDir),
                                                   function (dir) {
                            root.apWpDir = root.shortenHome(dir);
                            wpDirIn.text = root.apWpDir;
                            root.saveAppearance();
                            root.rescanWallpapers();
                        })
                    }
                }
            }
        }
        ToggleCard {
            icon: "account_tree"
            title: "Include subfolders"
            desc: "Each subfolder becomes a collection you can filter the picker by"
            on: root.apWpRecursive
            onToggled: { root.apWpRecursive = !root.apWpRecursive
                         root.saveAppearance(); root.rescanWallpapers() }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 10
            Text {
                Layout.fillWidth: true
                color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
                text: root.wpIndexBusy ? "scanning…"
                      : !root.wpScanned ? "Not scanned yet. Press Re-scan."
                      : root.wpIndex.length + " wallpaper" + (root.wpIndex.length === 1 ? "" : "s")
                        + (root.wpCollCount ? "  ·  " + root.wpCollCount + " collection"
                                               + (root.wpCollCount === 1 ? "" : "s") : "")
            }
            Chip {
                label: root.wpIndexBusy ? "Scanning" : "Re-scan"
                icon: "refresh"
                onPicked: root.rescanWallpapers()
            }
        }

        Section { title: "Switch transition"; icon: "animation" }
        Text {
            text: "used by the picker, SUPER+N / SUPER+SHIFT+N, and auto-rotate"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            Layout.leftMargin: 14
        }
        Flow {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 6
            Repeater {
                model: root.wpTransitions
                delegate: Chip {
                    required property var modelData
                    label: modelData
                    on: root.apWpTransition === modelData
                    onPicked: { root.apWpTransition = modelData; root.saveAppearance() }
                }
            }
        }
        SliderRow {
            icon: "speed"; label: "Duration"
            value: Math.min(1, root.apWpTransitionDur / 5)
            readout: root.apWpTransitionDur.toFixed(1) + "s"
            onMoved: (v) => { root.apWpTransitionDur = Math.max(0.1, v * 5); root.saveAppearance() }
        }
        SliderRow {
            icon: "60fps"; label: "FPS"
            value: Math.min(1, (root.apWpTransitionFps - 15) / 105)
            readout: Math.round(root.apWpTransitionFps) + ""
            onMoved: (v) => { root.apWpTransitionFps = Math.round(15 + v * 105); root.saveAppearance() }
        }
        Row2 {
            icon: "skip_next"; label: "Preview it — switch to the next wallpaper"
            cmd: "sh '" + root.wpCycleScript + "' next"
        }

        Section { title: "Auto-rotate"; icon: "schedule" }
        ToggleCard {
            icon: "autorenew"
            title: "Rotate wallpaper automatically"
            desc: root.apWpDayNight
                  ? "held — the day/night pair below outranks the timer"
                  : (root.apMatugen
                     ? "On — heads up: “match colours” is enabled, so every rotation re-themes the shell"
                     : "Cycles through the wallpaper folder on a timer.")
            on: root.apWpRotate && !root.apWpDayNight
            onToggled: {
                root.apWpRotate = !root.apWpRotate;
                root.saveAppearance();
                // the daemon re-reads config each tick, but restart so a
                // changed interval takes effect now instead of after the
                // current sleep — and so enabling it works even if the
                // daemon was never started this session.
                run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
            }
        }
        SliderRow {
            icon: "timer"; label: "Every"
            value: Math.min(1, (root.apWpRotateMins - 1) / 239)
            readout: root.apWpRotateMins >= 60
                     ? (root.apWpRotateMins / 60).toFixed(1) + "h"
                     : Math.round(root.apWpRotateMins) + "m"
            onMoved: (v) => { root.apWpRotateMins = Math.max(1, Math.round(1 + v * 239)); root.saveAppearance() }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            Text { text: "Order"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 76 }
            Repeater {
                model: root.wpRotateModes
                delegate: Chip {
                    required property var modelData
                    label: modelData
                    on: root.apWpRotateMode === modelData
                    onPicked: {
                        root.apWpRotateMode = modelData; root.saveAppearance();
                        run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }
        ToggleCard {
            icon: "image"
            title: "Stills only"
            desc: "Skip moving wallpapers — rotating into one restarts a video decoder every interval"
            on: root.apWpRotateStills
            onToggled: { root.apWpRotateStills = !root.apWpRotateStills; root.saveAppearance() }
        }

        // ---------------- the pair ----------------
        Section { title: "Day & night"; icon: "routine" }
        ToggleCard {
            icon: "bedtime"
            title: "Pin a day and a night wallpaper"
            desc: "swaps at " + root.apDarkStart + " and " + root.apDarkEnd
                  + " — the same times as auto dark mode, in Theme"
            on: root.apWpDayNight
            onToggled: {
                root.apWpDayNight = !root.apWpDayNight;
                root.saveAppearance();
                run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 12
            opacity: root.apWpDayNight ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            CartTile {
                slot: "day"; path: root.apWpDay
                armed: wpTab.armed === "day"
                onPicked: wpTab.armed = (wpTab.armed === "day") ? "" : "day"
                onCleared: { root.apWpDay = ""; root.saveAppearance() }
            }
            CartTile {
                slot: "night"; path: root.apWpNight
                armed: wpTab.armed === "night"
                onPicked: wpTab.armed = (wpTab.armed === "night") ? "" : "night"
                onCleared: { root.apWpNight = ""; root.saveAppearance() }
            }
            Item { Layout.fillWidth: true }
        }

        WallShelf {
            open: wpTab.armed === "day" || wpTab.armed === "night"
            chosen: wpTab.armed === "day" ? root.apWpDay
                  : wpTab.armed === "night" ? root.apWpNight : ""
            onPicked: (path) => {
                if (wpTab.armed === "day")        root.apWpDay = path;
                else if (wpTab.armed === "night") root.apWpNight = path;
                root.saveAppearance();
                wpTab.armed = "";
                run("sh '" + root.wpRotateScript + "' --restart >/dev/null 2>&1 &");
            }
        }

        // ---------------- the lock screen ----------------
        Section { title: "Lock screen"; icon: "lock" }
        ToggleCard {
            icon: "photo_library"
            title: "Lock screen keeps its own picture"
            desc: "Off — hyprlock follows the desktop, re-synced on every switch"
            on: root.apWpLockOwn
            onToggled: {
                root.apWpLockOwn = !root.apWpLockOwn;
                root.saveAppearance();
                // Re-run the sync so the change is on the lock screen now
                // rather than at the next wallpaper switch — which, if you
                // never switch, is never.
                run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            spacing: 12
            opacity: root.apWpLockOwn ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: Tok.mFast } }
            CartTile {
                slot: "lock"; path: root.apWpLock
                armed: wpTab.armed === "lock"
                onPicked: wpTab.armed = (wpTab.armed === "lock") ? "" : "lock"
                onCleared: {
                    root.apWpLock = ""; root.saveAppearance();
                    run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
                }
            }
            Item { Layout.fillWidth: true }
        }
        WallShelf {
            open: wpTab.armed === "lock"
            chosen: root.apWpLock
            onPicked: (path) => {
                root.apWpLock = path;
                root.saveAppearance();
                wpTab.armed = "";
                run("sh '" + root.lockwallScript + "' >/dev/null 2>&1 &");
            }
        }

        // ---------------- moving wallpapers ----------------
        Section { title: "Moving wallpapers"; icon: "movie" }
        Text {
            text: "MP4, WebM and GIF play inside the shell, from a copy re-encoded once to your screen size and frame cap"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            Layout.leftMargin: 14; Layout.rightMargin: 14
            Layout.fillWidth: true; wrapMode: Text.WordWrap
        }
        ToggleCard {
            icon: "memory"
            title: "Free it while it's covered"
            desc: "A fullscreen window swaps the video for its own still frame — pausing keeps the VRAM, this hands it back"
            on: root.apWpCoverStill
            onToggled: { root.apWpCoverStill = !root.apWpCoverStill; root.saveAppearance() }
        }
        ToggleCard {
            icon: "battery_saver"
            title: "Still frame on battery"
            desc: "Hold the poster frame until it's plugged back in"
            on: root.apWpBatteryStill
            onToggled: { root.apWpBatteryStill = !root.apWpBatteryStill; root.saveAppearance() }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 8
            Text { text: "Frame cap"; color: theme.sub; font.pixelSize: 12
                   font.family: Tok.sans; Layout.minimumWidth: 76 }
            Repeater {
                model: root.wpVidFpsOptions
                delegate: Chip {
                    required property var modelData
                    label: modelData + " fps"
                    on: (root.apWpVidFps || 30) === modelData
                    // The bar watches appearance.json and re-encodes for the new cap itself.
                    onPicked: { root.apWpVidFps = modelData; root.saveAppearance() }
                }
            }
            Item { Layout.fillWidth: true }
        }
        Text {
            text: "A lower cap means fewer frames to decode and fewer full-screen blits · changing it re-encodes in the background"
            color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
            Layout.leftMargin: 14; Layout.rightMargin: 14
            Layout.fillWidth: true; wrapMode: Text.WordWrap
        }
    }
}
