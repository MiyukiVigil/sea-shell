// Settings → IdleLock. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 10
    visible: root.tab === 10; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "lock"
        badgeColor: "#5E5CE6"
        title: "Lock Screen"
        description: "Customize your SDDM login screen, idle dim/lock/sleep timeouts, Caffeine mode, and lock screen blur."
    }

    Section { title: "Login screen"; icon: "login" }
    SddmSettings {
        id: loginThemeSettings
        onAuthenticatingChanged: root.authenticationPending = authenticating
        Layout.fillWidth: true; ink: theme.text
        // the live login preview exists only while it can be seen
        previewLive: root.shown && root.tab === 10 && !root.authenticationPending
        onAvatarBrowseRequested: root.pickFile("Choose user picture", "*.png *.jpg *.jpeg *.webp", function(path) {
            loginThemeSettings.setAvatar(path)
        })
        onBrowseRequested: root.pickFile("Choose login background", "*.png *.jpg *.jpeg *.webp *.gif *.mp4 *.webm", function(path) {
            loginThemeSettings.setBackground(path)
        })
    }

    // segmented horizontal navigation bar for Idle & Lock sub-menus
    RowLayout {
        Layout.fillWidth: true; spacing: 6; Layout.bottomMargin: 8
        Repeater {
            model: [
                { i: "timer", l: "timeouts" },
                { i: "security", l: "lock screen" }
            ]
            delegate: Rectangle {
                required property var modelData; required property int index
                readonly property bool sel: root.idlSubTab === index
                Layout.fillWidth: true; implicitHeight: 34; radius: Tok.r
                color: sel ? theme.iris : (subIdMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                RowLayout {
                    anchors.centerIn: parent; spacing: 6
                    Sym { text: modelData.i; sz: 14; color: sel ? theme.bg : theme.frost }
                    Text { text: modelData.l; color: sel ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                }
                MouseArea { id: subIdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.idlSubTab = index }
            }
        }
    }

    // SUB-TAB 0: Timeouts
    ColumnLayout {
        visible: root.idlSubTab === 0; Layout.fillWidth: true; spacing: 14
        Section { title: "Idle daemon"; icon: "bedtime" }
        RowLayout {
            Layout.fillWidth: true; spacing: 10
            Sym { text: root.idleOn ? "bedtime" : "coffee"; sz: 18; color: root.idleOn ? theme.iris : theme.warn }
            ColumnLayout { spacing: 0; Layout.fillWidth: true
                Text { text: root.idleOn ? "Idle daemon running" : "Caffeine mode — idle daemon stopped"; color: theme.text; font.pixelSize: 13; font.family: root.apFont }
                Text {
                    text: {
                        if (!root.idleOn) return "screen stays on until you turn hypridle back on";
                        var d = root.lockDim >= 60 ? (root.lockDim / 60).toFixed(0) + "m" : root.lockDim + "s";
                        var l = (root.lockLock / 60).toFixed(0) + "m";
                        var o = (root.lockDpms / 60).toFixed(0) + "m";
                        var s = root.lockSuspendEnabled ? " · suspend " + (root.lockSuspend / 60).toFixed(0) + "m" : "";
                        return "dim " + d + " · lock " + l + " · screen off " + o + s;
                    }
                    color: theme.faint; font.pixelSize: 11; font.family: root.apFont
                }
            }
            Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                color: root.idleOn ? theme.a(theme.iris, 0.35) : theme.a(theme.warn, 0.3)
                border.width: 1; border.color: root.idleOn ? theme.iris : theme.warn
                Rectangle { width: 16; height: 16; radius: Tok.r; y: 3
                    x: root.idleOn ? parent.width - 19 : 3
                    color: root.idleOn ? theme.frost : theme.warn
                    Behavior on x { NumberAnimation { duration: 120 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleIdle() } }
        }

        Section { title: "Timeouts"; icon: "timer" }

        // Dim Backlight
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "brightness_medium"; sz: 20 }
            Text { text: "Dim display"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"15s",v:15},{l:"30s",v:30},{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockDim === modelData.v
                        implicitWidth: chipDim.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipDimMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipDim; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipDimMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDim = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customDimIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customDimIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: root.lockDim.toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockDim = Math.max(1, v) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customDimIn.activeFocus; text: "s"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Lock Screen
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "lock"; sz: 20 }
            Text { text: "Lock screen"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300},{l:"10m",v:600},{l:"30m",v:1800}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockLock === modelData.v
                        implicitWidth: chipLck.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipLckMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipLck; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipLckMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockLock = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customLckIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customLckIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: Math.round(root.lockLock / 60).toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockLock = Math.max(1, v * 60) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customLckIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Screen Off (DPMS)
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "settings_brightness"; sz: 20 }
            Text { text: "Screen off"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"1m",v:60},{l:"2m",v:120},{l:"5m",v:300},{l:"10m",v:600},{l:"30m",v:1800}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockDpms === modelData.v
                        implicitWidth: chipDpms.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipDpmsMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipDpms; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipDpmsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockDpms = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customDpmsIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customDpmsIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: Math.round(root.lockDpms / 60).toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockDpms = Math.max(1, v * 60) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customDpmsIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Suspend
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "power"; sz: 20; color: root.lockSuspendEnabled ? theme.frost : theme.faint }
            Text { text: "Suspend system"; color: root.lockSuspendEnabled ? theme.sub : theme.faint; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6; visible: root.lockSuspendEnabled
                Repeater {
                    model: [{l:"10m",v:600},{l:"30m",v:1800},{l:"1h",v:3600},{l:"2h",v:7200}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockSuspend === modelData.v
                        implicitWidth: chipSsp.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipSspMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipSsp; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipSspMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockSuspend = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customSspIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customSspIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: Math.round(root.lockSuspend / 60).toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockSuspend = Math.max(1, v * 60) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customSspIn.activeFocus; text: "m"; color: theme.faint; font.pixelSize: 11 } } } }
            Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                color: root.lockSuspendEnabled ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                border.width: 1; border.color: root.lockSuspendEnabled ? theme.iris : theme.faint
                Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
                    x: root.lockSuspendEnabled ? parent.width - 17 : 3
                    color: root.lockSuspendEnabled ? theme.frost : theme.faint
                    Behavior on x { NumberAnimation { duration: 120 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockSuspendEnabled = !root.lockSuspendEnabled } }
        }

        // Laptop Lid Close
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "laptop"; sz: 20; color: theme.frost }
            Text { text: "Lid close action"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 100 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [
                        {l:"Suspend",  v:"suspend",   i:"bedtime"},
                        {l:"Lock",     v:"lock",      i:"lock"},
                        {l:"Screen Off",v:"dpms",     i:"settings_brightness"},
                        {l:"Hibernate",v:"hibernate", i:"save_as"},
                        {l:"Shut down",v:"shutdown",  i:"power_settings_new"},
                        {l:"Ignore",   v:"ignore",    i:"block"}
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool sel: root.lockLidAction === modelData.v
                        implicitWidth: chipLidRow.implicitWidth + 18; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipLidMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        RowLayout {
                            id: chipLidRow
                            anchors.centerIn: parent; spacing: 4
                            Sym { text: modelData.i; sz: 14; color: sel ? theme.bg : (chipLidMa.containsMouse ? theme.frost : theme.sub) }
                            Text { text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        }
                        MouseArea {
                            id: chipLidMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.lockLidAction = modelData.v;
                                root.saveLockSettings();
                                root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"; hyprctl reload");
                            }
                        }
                    }
                }
            }
        }
    }

    // SUB-TAB 1: Style & Wallpaper
    ColumnLayout {
        visible: root.idlSubTab === 1; Layout.fillWidth: true; spacing: 14
        Section { title: "Lock screen"; icon: "lock" }
        ProfileSettings { id: lockProfileEditor; Layout.fillWidth: true; part: "lock"
            onSaved: { if (root.userEditor) root.userEditor.reload() }
            Component.onCompleted: root.lockEditor = lockProfileEditor }
        Section { title: "Lock screen options"; icon: "security" }

        // Grace period
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "av_timer"; sz: 20 }
            Text { text: "Grace period"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"0s",v:0},{l:"2s",v:2},{l:"5s",v:5},{l:"10s",v:10}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockGrace === modelData.v
                        implicitWidth: chipGrc.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipGrcMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipGrc; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipGrcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockGrace = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customGrcIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customGrcIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: root.lockGrace.toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockGrace = Math.max(0, v) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customGrcIn.activeFocus; text: "s"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Hide cursor Toggle
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "navigation"; sz: 20 }
            Text { text: "Hide cursor on lock"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
            Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                color: root.lockHideCursor ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                border.width: 1; border.color: root.lockHideCursor ? theme.iris : theme.faint
                Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
                    x: root.lockHideCursor ? parent.width - 17 : 3
                    color: root.lockHideCursor ? theme.frost : theme.faint
                    Behavior on x { NumberAnimation { duration: 120 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockHideCursor = !root.lockHideCursor } }
        }

        // Ignore empty input Toggle
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "space_bar"; sz: 20 }
            Text { text: "Ignore empty input"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.fillWidth: true }
            Rectangle { implicitWidth: 40; implicitHeight: 20; radius: Tok.r
                color: root.lockIgnoreEmpty ? theme.a(theme.iris, 0.35) : theme.a(theme.line, 0.3)
                border.width: 1; border.color: root.lockIgnoreEmpty ? theme.iris : theme.faint
                Rectangle { width: 14; height: 14; radius: Tok.r; y: 3
                    x: root.lockIgnoreEmpty ? parent.width - 17 : 3
                    color: root.lockIgnoreEmpty ? theme.frost : theme.faint
                    Behavior on x { NumberAnimation { duration: 120 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.lockIgnoreEmpty = !root.lockIgnoreEmpty } }
        }

        Section { title: "Blur & background"; icon: "wallpaper" }

        // Blur Passes
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "blur_on"; sz: 20 }
            Text { text: "Blur passes"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"1",v:1},{l:"2",v:2},{l:"3",v:3},{l:"5",v:5},{l:"8",v:8}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockBlurPasses === modelData.v
                        implicitWidth: chipPas.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipPasMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipPas; anchors.centerIn: parent; text: modelData.l.toString(); color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipPasMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurPasses = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customPasIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customPasIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: root.lockBlurPasses.toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockBlurPasses = Math.max(0, v) } } } }
        }

        // Blur Size
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "photo_size_select_large"; sz: 20 }
            Text { text: "Blur size"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"2px",v:2},{l:"4px",v:4},{l:"8px",v:8},{l:"12px",v:12},{l:"16px",v:16}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: root.lockBlurSize === modelData.v
                        implicitWidth: chipSz.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipSzMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipSz; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipSzMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockBlurSize = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customSzIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customSzIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: root.lockBlurSize.toString(); selectByMouse: true
                        onEditingFinished: { var v = parseInt(text); if(!isNaN(v)) root.lockBlurSize = Math.max(0, v) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customSzIn.activeFocus; text: "px"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Vibrancy
        RowLayout { Layout.fillWidth: true; spacing: 10
            Sym { text: "vignette"; sz: 20 }
            Text { text: "Vibrancy"; color: theme.sub; font.pixelSize: 12; font.family: root.apFont; Layout.minimumWidth: 110 }
            Item { Layout.fillWidth: true }
            RowLayout { spacing: 6
                Repeater {
                    model: [{l:"0%",v:0.0},{l:"25%",v:0.25},{l:"50%",v:0.5},{l:"75%",v:0.75},{l:"100%",v:1.0}]
                    delegate: Rectangle { required property var modelData; readonly property bool sel: Math.abs(root.lockVibrancy - modelData.v) < 0.02
                        implicitWidth: chipVib.implicitWidth+14; implicitHeight: 26; radius: Tok.r
                        color: sel ? theme.iris : (chipVibMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4))
                        border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                        Text { id: chipVib; anchors.centerIn: parent; text: modelData.l; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: root.apFont; font.bold: sel }
                        MouseArea { id: chipVibMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.lockVibrancy = modelData.v } } }
                Rectangle { implicitWidth: 64; implicitHeight: 26; radius: Tok.r; color: theme.a(theme.line, 0.5)
                    border.width: 1; border.color: customVibIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.2)
                    TextInput { id: customVibIn; anchors.fill: parent; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                        color: theme.text; font.pixelSize: 11; font.family: Tok.sans; text: Math.round(root.lockVibrancy * 100).toString(); selectByMouse: true
                        onEditingFinished: { var v = parseFloat(text); if(!isNaN(v)) root.lockVibrancy = Math.max(0, Math.min(100, v)) / 100 }
                        Text { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; visible: !customVibIn.activeFocus; text: "%"; color: theme.faint; font.pixelSize: 11 } } } }
        }

        // Wallpaper path text input
        Text { text: "Wallpaper image path"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.topMargin: 4 }
        RowLayout {
            Layout.fillWidth: true; spacing: 10
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                color: theme.a(theme.line, 0.4); border.width: 1
                border.color: bgIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                TextInput {
                    id: bgIn
                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: theme.text; font.pixelSize: 12; font.family: Tok.sans
                    clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                    text: root.lockBg
                    onTextChanged: root.lockBg = text
                }
            }
            Rectangle {
                implicitWidth: 36; implicitHeight: 36; radius: Tok.r
                color: bgBrowseMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                border.width: 1; border.color: theme.a(theme.iris, 0.25)
                Sym { anchors.centerIn: parent; text: "folder_open"; sz: 16; color: theme.frost }
                MouseArea {
                    id: bgBrowseMa
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.pickFile("Select Wallpaper Image", "Images (*.png *.jpg *.jpeg) | *.png;*.jpg;*.jpeg", function(path) {
                            bgIn.text = path;
                        }); } } }
        }
    }

    // Save & Actions Row (always visible at bottom of tab)
    RowLayout {
        Layout.fillWidth: true; spacing: 10; Layout.topMargin: 8
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 38; radius: Tok.r
            color: svLockM.containsMouse ? theme.iris : theme.a(theme.iris, 0.18)
            border.width: 1; border.color: theme.iris
            RowLayout {
                anchors.centerIn: parent; spacing: 6
                Sym { text: "save"; sz: 16; color: svLockM.containsMouse ? theme.bg : theme.frost }
                Text { text: "Apply & Restart Daemon"; color: svLockM.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: root.apFont; font.bold: true }
            }
            MouseArea {
                id: svLockM
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.saveLockSettings();
                    // Restart daemon
                    root.run("pkill -x hypridle; sleep 0.3; hyprctl dispatch \"hl.dsp.exec_cmd('hypridle')\"");
                    // Notify user
                    root.run("notify-send 'sea-shell' 'Lock & Idle settings applied live!'");
                }
            }
        }
        Rectangle {
            implicitWidth: 120; implicitHeight: 38; radius: Tok.r
            color: lkNowM.containsMouse ? theme.warn : theme.a(theme.line, 0.38)
            border.width: 1; border.color: lkNowM.containsMouse ? theme.warn : theme.a(theme.iris, 0.16)
            RowLayout {
                anchors.centerIn: parent; spacing: 6
                Sym { text: "lock"; sz: 16; color: lkNowM.containsMouse ? theme.bg : theme.warn }
                Text { text: "Lock Now"; color: lkNowM.containsMouse ? theme.bg : theme.text; font.pixelSize: 13; font.family: root.apFont }
            }
            MouseArea {
                id: lkNowM
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.run("~/.config/quickshell/sea-shell/sea-lock.sh"); root.closePanel() }
            }
        }
    }
}
