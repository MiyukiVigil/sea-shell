// Settings → Display. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 1
    visible: root.tab === 1; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "monitor"
        badgeColor: "#007AFF"
        title: "Displays"
        description: "Configure monitor resolution, refresh rate, orientation, adaptive sync, brightness, layout profiles, and Night Light."
        note: "Monitor mode changes take effect when you click Apply."
    }

    // ---- brightness ----
    Section { title: "Brightness"; icon: "brightness_6" }
    SliderRow { icon: "brightness_low"; label: "Level"; tint: theme.frost
        value: root.brightness >= 0 ? root.brightness / 100 : 0
        readout: root.brightness >= 0 ? root.brightness + "%" : "n/a"
        onMoved: (v) => root.setBrightness(v * 100) }
    Text { visible: root.brightness < 0; text: "Brightnessctl found no backlight (desktop monitor?)"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14 }

    // ---- monitor mode ----
    Section { title: "Monitor"; icon: "monitor" }
    // Every output at once, and the row IS the selector — picking one
    // scopes the resolution / refresh / scale controls below to it.
    IndTable {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        rowHeight: 32
        rows: root.monRows
        selectable: true
        selectedIndex: root.monSel
        emptyText: "Reading monitors…"
        columns: [
            { label: "Output",  key: "name",  w: 110, mono: true },
            { label: "Display", key: "desc",  flex: true },
            { label: "Mode",    key: "mode",  w: 150, num: true },
            { label: "Scale",   key: "scale", w: 60,  num: true },
            { label: "Rotate",  key: "rot",   w: 62,  num: true }
        ]
        onActivated: (i) => { root.monSel = i; root.selRes = ""; root.reloadMonitors() }
    }
    // connected but off — say why, and for the laptop screen offer the way back
    Repeater {
        model: root.offMonitors
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 10
            Sym { text: modelData.laptop ? "laptop" : "desktop_access_disabled"; sz: 18; color: Tok.ink2 }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 1
                Text { text: modelData.name + " · off"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans; font.bold: true }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
                    text: !modelData.laptop ? modelData.desc + " is connected but switched off"
                        : root.panelExternalOnly ? "The laptop screen is off because “off while an external display is connected” is on"
                        : root.panelLidOff ? "The laptop screen is off while the lid is closed" : modelData.desc + " is switched off" }
            }
            AccentBtn { visible: modelData.laptop && root.panelExternalOnly
                Layout.fillWidth: false; implicitWidth: 112; implicitHeight: 32; icon: "power_settings_new"; label: "Turn on"
                onClicked: { root.panelExternalOnly = false; root.setPanel("external_only", false) } }
        }
    }

    // ---- adaptive sync ----
    // misc:vrr is GLOBAL in hyprland, not per-monitor, so it sits under
    // the monitor table rather than inside the per-output controls.
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
        Layout.topMargin: 4; spacing: 8
        Text { text: "Adaptive sync"; color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 100 }
        Repeater {
            model: root.vrrModes
            delegate: Chip {
                required property var modelData
                label: modelData.l; on: root.apVrr === modelData.v
                onPicked: { root.apVrr = modelData.v; root.saveAppearance(); root.applyVrr() }
            }
        }
        Item { Layout.fillWidth: true }
    }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 14; wrapMode: Text.WordWrap
        text: root.curMon && root.curMon.vrrCapable === false
              ? "This panel reports no VRR support, so the setting will have no effect."
              : "variable refresh (FreeSync / G-Sync). “fullscreen” limits it to fullscreen windows, which avoids flicker on panels that misbehave at low refresh"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    Text { text: "Resolution"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14; Layout.topMargin: 2 }
    Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
        Repeater { model: root.uniqueRes(root.curMon)
            delegate: Chip { required property var modelData; label: modelData; on: root.selRes === modelData
                onPicked: { root.selRes = modelData; var hs = root.hzFor(root.curMon, modelData); if (hs.length) root.selHz = hs[0] } } } }

    Text { text: "Refresh rate"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14; Layout.topMargin: 2 }
    Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
        Repeater { model: root.hzFor(root.curMon, root.selRes)
            delegate: Chip { required property var modelData; label: Math.round(parseFloat(modelData)) + " Hz"; on: root.selHz === modelData
                onPicked: root.selHz = modelData } } }

    Text { text: "Orientation"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14; Layout.topMargin: 2 }
    Flow { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 7
        Repeater { model: [{t:0,i:"stay_current_landscape",l:"landscape"},{t:1,i:"stay_current_portrait",l:"portrait"}]
            delegate: Chip { required property var modelData; label: modelData.l; icon: modelData.i; on: root.selTransform === modelData.t
                onPicked: root.selTransform = modelData.t } } }

    AccentBtn { visible: root.curMon !== null; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 4
        icon: "check"; label: "Apply " + root.selRes + "@" + Math.round(parseFloat(root.selHz || "0")) + "Hz"
        onClicked: root.applyDisplay() }

    // ---- layout profiles (save/restore whole monitor arrangements) ----
    Section { title: "Layout profiles"; icon: "dashboard" }
    Text { text: "Save the current monitor arrangement — resolution, position, scale — and restore it in one tap when you dock or unplug."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

    Repeater { model: root.displayProfiles
        delegate: Rectangle {
            required property var modelData
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14
            implicitHeight: 48; radius: Tok.r
            color: dpMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.4)
            border.width: 1; border.color: modelData.matches ? theme.a(theme.iris, 0.5) : theme.a(theme.iris, 0.14)
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 10; spacing: 12
                Sym { text: modelData.matches ? "check_circle" : "dashboard"; sz: 19
                    color: modelData.matches ? theme.good : theme.sub; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout { spacing: 1; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                    Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: Tok.sans; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: modelData.summary + (modelData.created ? "  ·  " + modelData.created : ""); color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; elide: Text.ElideRight; Layout.fillWidth: true } }
                // apply
                Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 66; implicitHeight: 30; radius: Tok.r
                    color: dpApplyMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
                    Row { anchors.centerIn: parent; spacing: 5
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "play_arrow"; sz: 14; color: dpApplyMa.containsMouse ? theme.bg : theme.frost }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Apply"; color: dpApplyMa.containsMouse ? theme.bg : theme.frost; font.pixelSize: 11; font.family: Tok.sans } }
                    MouseArea { id: dpApplyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.applyDisplayProfile(modelData.name) } }
                // delete
                Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 30; implicitHeight: 30; radius: Tok.r
                    color: dpDelMa.containsMouse ? theme.a(theme.bad, 0.25) : "transparent"; border.width: 1; border.color: theme.a(theme.bad, dpDelMa.containsMouse ? 0.5 : 0.2)
                    Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: dpDelMa.containsMouse ? theme.bad : theme.faint }
                    MouseArea { id: dpDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteDisplayProfile(modelData.name) } }
            }
            MouseArea { id: dpMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
        } }
    Text { visible: root.displayProfiles.length === 0; text: "No saved layouts yet"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14 }

    // save-current row
    RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 2; spacing: 8
        Rectangle { Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
            color: theme.a(theme.line, 0.5); border.width: 1; border.color: profIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
            TextInput { id: profIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: TextInput.AlignVCenter
                color: theme.text; font.pixelSize: 12; font.family: Tok.sans; clip: true; selectByMouse: true
                text: root.profName; onTextChanged: root.profName = text
                onAccepted: { root.saveDisplayProfile(text); text = "" }
                Text { anchors.verticalCenter: parent.verticalCenter; visible: profIn.text === ""; text: "Name this layout…"; color: theme.faint; font.pixelSize: 12; font.family: Tok.sans } } }
        Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 78; implicitHeight: 38; radius: Tok.r
            opacity: root.profName.trim() !== "" ? 1 : 0.45
            color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
            Row { anchors.centerIn: parent; spacing: 5
                Sym { anchors.verticalCenter: parent.verticalCenter; text: "bookmark_add"; sz: 15; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Save"; color: profSaveMa.containsMouse && root.profName.trim() !== "" ? theme.bg : theme.frost; font.pixelSize: 11; font.family: Tok.sans } }
            MouseArea { id: profSaveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.saveDisplayProfile(root.profName); profIn.text = "" } } } }

    // ---- per-monitor rules ----
    Section { visible: root.curMon !== null; title: "This monitor" + (root.monitors.length > 1 && root.curMon ? " · " + root.curMon.name : ""); icon: "tv_options_edit_channels" }
    ToggleCard { visible: root.curMon !== null
        icon: (root.curMon && root.monBarAp(root.curMon.name)) ? "web_asset" : "web_asset_off"
        title: "Show bar"; desc: "Display the sea-shell bar on this output"
        on: root.curMon ? root.monBarAp(root.curMon.name) : true
        onToggled: if (root.curMon) root.setMon(root.curMon.name, "bar", !root.monBarAp(root.curMon.name)) }
    ToggleCard { id: ovrScaleCard; visible: root.curMon !== null
        icon: "zoom_out_map"; title: "Override scale"
        desc: ovrScaleCard.on ? ("This monitor: " + root.monScaleAp(root.curMon.name).toFixed(2) + "×") : "use the global / auto scale"
        on: root.curMon ? (root.monScaleAp(root.curMon.name) > 0) : false
        onToggled: if (root.curMon) root.setMon(root.curMon.name, "scale", root.monScaleAp(root.curMon.name) > 0 ? 0 : Math.max(1.0, root.autoScaleEstimate())) }
    SliderRow { visible: root.curMon !== null && root.monScaleAp(root.curMon.name) > 0
        icon: "aspect_ratio"; label: "Scale"
        value: root.curMon ? (root.monScaleAp(root.curMon.name) - 0.75) / 1.75 : 0
        readout: (root.curMon ? root.monScaleAp(root.curMon.name).toFixed(2) : "1.00") + "×"
        onMoved: (v) => { if (root.curMon) root.setMon(root.curMon.name, "scale", Math.round((0.75 + v * 1.75) * 20) / 20) } }

    // ---- laptop screen ----
    Section { visible: root.panelLaptop; title: "Laptop screen"; icon: "laptop" }
    ToggleCard { visible: root.panelLaptop; icon: "tv"; title: "Off while an external display is connected"
        desc: "Only the external screen runs, its windows move over — can steady a game's frame rate on the external screen"
        on: root.panelExternalOnly
        onToggled: { root.panelExternalOnly = !root.panelExternalOnly; root.setPanel("external_only", root.panelExternalOnly) } }
    ToggleCard { visible: root.panelLaptop; icon: "laptop_chromebook"; title: "Off when the lid closes"
        desc: "With an external display connected; back on when the lid opens. the lid action under Idle & lock still runs"
        on: root.panelLidOff
        onToggled: { root.panelLidOff = !root.panelLidOff; root.setPanel("lid_off", root.panelLidOff) } }

    // ---- one arrangement per set of displays (sea-setups.py) ----
    Section { title: "Layouts"; icon: "dashboard_customize" }
    ToggleCard { icon: "devices"; title: "Remember a layout for each set of displays"
        desc: "Widgets, the dock and the bar edge are kept per setup, so docking and undocking bring back how each one was arranged"
        on: root.apDisplaySetups
        onToggled: { root.apDisplaySetups = !root.apDisplaySetups; root.saveAppearance() } }

    // ---- global display scale ----
    Section { title: "Display scale"; icon: "aspect_ratio" }
    ToggleCard { icon: "aspect_ratio"; title: "Auto scale (match display)"
        desc: "Sizes the whole shell per monitor, so a 4K TV scales up and 1080p stays at 1×."
        on: root.apScale === 0
        onToggled: { root.apScale = (root.apScale === 0) ? Math.max(1.0, root.autoScaleEstimate()) : 0; root.saveAppearance() } }
    SliderRow { visible: root.apScale > 0; icon: "zoom_out_map"; label: "UI scale"
        value: (root.apScale - 0.75) / 1.75; readout: root.apScale.toFixed(2) + "×"
        onMoved: (v) => { root.apScale = Math.round((0.75 + v * 1.75) * 20) / 20; root.saveAppearance() } }
    Text { visible: root.apScale > 0; text: "Raise this when projecting to a TV and everything looks too small."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }

    // ---- night light ----
    Section { title: "Night light"; icon: "nightlight" }
    ToggleCard { icon: "routine"; title: "Follow dark mode"
        desc: "Warm the screen automatically whenever the shell is in dark mode"
        on: root.apNightAuto
        onToggled: { root.apNightAuto = !root.apNightAuto; root.saveAppearance() } }
    ToggleCard { visible: !root.apNightAuto; icon: "nightlight"; title: "Night light"
        desc: "Warm the screen now. Also available from the Control Center."
        on: root.apNight
        onToggled: { root.apNight = !root.apNight; root.saveAppearance() } }
    SliderRow { icon: "thermostat"; label: "Warmth"; tint: theme.warn
        value: (6000 - root.apNightTemp) / 3500; readout: root.apNightTemp + "K"
        onMoved: (v) => { root.apNightTemp = Math.round((6000 - v * 3500) / 100) * 100; root.saveAppearance() } }
    Text { text: "Lower is warmer. Needs the hyprsunset package, which the installer includes."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap }
}
