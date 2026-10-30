import QtQuick
import QtQuick.Effects
import Quickshell

// What the lock screen looks like, on one screen. It holds no state of its own: lock.qml owns
// the session lock, PAM and the typed password and hands them in, and Settings hands in sample
// values to draw a preview. Two states, as the login screen (SilentSDDM) has: "idle" shows the
// clock, what arrived while you were away and the media/status strip; any key or click turns it
// to "login", which blurs the wallpaper and brings up you and the password field. The colours
// here are fixed light-on-dark rather than Tok's, because they sit on a photo, not on a surface.
Item {
    id: lk
    // ---- in ----
    property var profile: ({})
    property string wallpaper: ""
    property string clockFont: Tok.sans
    property string textFont: Tok.sans      // the date and small lines: the login screen's face
    property int clockWeight: Font.Black
    property string dateFormat: "dddd, d MMMM"
    property bool preview: false
    property string state_: "idle"          // "idle" | "login" (state is taken by Item)
    property int typed: 0                   // how many characters are in the field (never the text)
    property bool busy: false
    property int fails: 0
    property int shakes: 0                  // bumped by lock.qml on each wrong password
    property string message: ""             // what PAM said, e.g. "Place your finger on the reader"
    property bool messageIsError: false
    property bool capsLock: false
    property string layout: ""              // shown when there is more than one layout
    property var notes: []                  // notif-history entries that arrived while locked
    property bool showContent: true
    property var player: null
    property var battery: null              // { pct, charging } or null on a desktop
    property bool leaving: false
    // ---- out ----
    signal key(var event)
    signal wake()
    signal power(string action)

    readonly property bool login: state_ === "login"
    readonly property real u: Math.max(0.75, Math.min(2.2, height / 1080))
    readonly property color glass: Qt.rgba(0.04, 0.05, 0.08, 0.46)
    readonly property color glassLine: Qt.rgba(1, 1, 1, 0.14)
    readonly property color dim: Qt.rgba(1, 1, 1, 0.66)
    readonly property color faint: Qt.rgba(1, 1, 1, 0.42)
    readonly property int motion: Tok.reducedMotion ? 0 : 1

    SystemClock { id: clock; precision: SystemClock.Seconds }

    // ---------- the photo ----------
    Rectangle { anchors.fill: parent; color: "#0a0d14" }
    Image {
        id: wall
        anchors.fill: parent
        source: lk.wallpaper ? "file://" + lk.wallpaper : ""
        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
        sourceSize.width: lk.preview ? 960 : 0
        visible: false
    }
    MultiEffect {
        id: wallFx
        anchors.fill: parent
        source: wall
        autoPaddingEnabled: false
        blurEnabled: true; blurMax: 64
        blur: lk.login ? 0.9 : 0.0
        brightness: lk.login ? -0.22 : -0.08
        saturation: lk.login ? -0.15 : 0
        // a slight settle as the lock comes up, like the screen breathing out
        scale: lk.leaving ? 1.03 : 1.0
        Behavior on blur { NumberAnimation { duration: 420 * lk.motion; easing.type: Easing.OutCubic } }
        Behavior on brightness { NumberAnimation { duration: 420 * lk.motion } }
        Behavior on scale { NumberAnimation { duration: 260 * lk.motion; easing.type: Easing.InCubic } }
    }
    // legibility: darken the left, where the clock and notifications sit, and the bottom strip
    Rectangle {
        anchors.fill: parent
        opacity: lk.login ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 300 * lk.motion } }
        gradient: Gradient { orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.42) }
            GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0.0) } }
    }
    Rectangle {
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 160 * lk.u
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.45) } }
    }

    MouseArea {
        anchors.fill: parent
        enabled: !lk.preview
        hoverEnabled: true
        property point last: Qt.point(-1, -1)
        // the pointer arriving from the compositor reports a move too, so only a real shove wakes it
        onPositionChanged: m => {
            if (last.x >= 0 && Math.abs(m.x - last.x) + Math.abs(m.y - last.y) > 24) lk.wake();
            if (last.x < 0 || Math.abs(m.x - last.x) + Math.abs(m.y - last.y) > 24) last = Qt.point(m.x, m.y);
        }
        onClicked: { powerMenu.open = false; lk.wake() }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: lk.leaving ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 220 * lk.motion } }

        // ---------- idle: the clock and what you missed ----------
        Column {
            id: idleCol
            x: parent.width * 0.075 - (lk.login ? 28 * lk.u : 0)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -40 * lk.u + (notesCol.visible ? 0 : 40 * lk.u)
            width: Math.min(parent.width * 0.42, 560 * lk.u)
            spacing: 0
            opacity: lk.login ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 260 * lk.motion } }
            Behavior on x { NumberAnimation { duration: 320 * lk.motion; easing.type: Easing.OutCubic } }

            Text {
                id: bigClock
                text: Qt.formatTime(clock.date, lk.profile.clock24 === false ? "h:mm" : "hh:mm")
                // a script face draws smaller than a display face at the same size; measured on
                // the digits, as ProfileCard measures the name
                FontMetrics { id: plainClock; font.family: Tok.sans; font.pixelSize: 100 }
                FontMetrics { id: chosenClock; font.family: lk.clockFont; font.pixelSize: 100; font.weight: lk.clockWeight }
                readonly property real opticalScale: {
                    var a = plainClock.tightBoundingRect("00:00").height, b = chosenClock.tightBoundingRect("00:00").height;
                    return a > 0 && b > 0 ? Math.max(1, Math.min(1.8, a / b)) : 1;
                }
                font.family: lk.clockFont; font.weight: lk.clockWeight
                font.pixelSize: Math.round(Math.min(150, (lk.profile.clockSize || 88) * 1.45) * opticalScale * lk.u)
                font.features: { "tnum": 1 }
                color: "white"
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000"; shadowOpacity: 0.35; shadowBlur: 0.8 }
            }
            Text {
                visible: lk.profile.showDate !== false
                // pulled up into the clock's descent, which digits never use
                topPadding: -bigClock.font.pixelSize * 0.14
                text: Qt.formatDate(clock.date, lk.dateFormat)
                font.family: lk.textFont; font.weight: Font.DemiBold; font.pixelSize: 24 * lk.u
                color: Qt.rgba(1, 1, 1, 0.9)
            }

            Item { width: 1; height: notesCol.visible ? 40 * lk.u : 0 }

            // Grouped by app, newest app first, each showing its newest message in full and a
            // count of the rest, so a burst from one chat cannot fill the screen.
            Column {
                id: notesCol
                visible: lk.groups.length > 0
                width: Math.min(parent.width, 430 * lk.u)
                spacing: 8 * lk.u
                Text {
                    text: lk.notes.length === 1 ? "1 notification while you were away"
                                                : lk.notes.length + " notifications while you were away"
                    font.family: Tok.sans; font.pixelSize: 12 * lk.u; color: lk.dim
                    bottomPadding: 2 * lk.u
                }
                Repeater {
                    model: lk.groups.slice(0, 3)
                    delegate: LockNote {
                        required property var modelData
                        width: notesCol.width
                        group: modelData
                        u: lk.u
                        showContent: lk.showContent
                        fill: lk.glass; line: lk.glassLine
                    }
                }
                Text {
                    visible: lk.groups.length > 3
                    text: "and " + (lk.groups.length - 3) + " more " + (lk.groups.length - 3 === 1 ? "app" : "apps")
                    font.family: Tok.sans; font.pixelSize: 12 * lk.u; color: lk.faint
                }
            }
        }

        // ---------- login: you and the field ----------
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 34 * lk.u + (lk.login ? 0 : -12 * lk.u)
            opacity: lk.login ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260 * lk.motion } }
            Behavior on y { NumberAnimation { duration: 320 * lk.motion; easing.type: Easing.OutCubic } }
            text: Qt.formatTime(clock.date, lk.profile.clock24 === false ? "h:mm" : "hh:mm") + "  ·  " + Qt.formatDate(clock.date, lk.dateFormat)
            font.family: lk.textFont; font.weight: Font.DemiBold; font.pixelSize: 17 * lk.u
            color: Qt.rgba(1, 1, 1, 0.88)
        }

        Column {
            id: loginCol
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: lk.login ? -20 * lk.u : 6 * lk.u
            spacing: 0
            opacity: lk.login ? 1 : 0
            visible: opacity > 0
            scale: lk.login ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 300 * lk.motion } }
            Behavior on scale { NumberAnimation { duration: 320 * lk.motion; easing.type: Easing.OutCubic } }
            Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 320 * lk.motion; easing.type: Easing.OutCubic } }

            Rectangle {
                visible: lk.profile.showAvatar !== false
                anchors.horizontalCenter: parent.horizontalCenter
                width: 116 * lk.u; height: width; radius: width / 2
                color: Qt.rgba(1, 1, 1, 0.12); border.width: 2; border.color: Qt.rgba(1, 1, 1, 0.5)
                Text { anchors.centerIn: parent; text: "person"; font.family: "Material Symbols Outlined"; font.pixelSize: 54 * lk.u; color: lk.dim }
                Image {
                    id: face
                    anchors.fill: parent; anchors.margins: 3
                    source: lk.profile.avatar ? "file://" + lk.profile.avatar : ""
                    fillMode: Image.PreserveAspectCrop; asynchronous: true
                    sourceSize.width: 256; sourceSize.height: 256
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                }
                Rectangle { id: faceMask; anchors.fill: face; radius: width / 2; visible: false; layer.enabled: true }
            }
            Item { width: 1; height: 16 * lk.u }
            // The name in the profile's own font, scaled to look as big as the UI font would at the
            // same size (the reasoning is in ProfileCard.qml).
            Text {
                id: nameT
                anchors.horizontalCenter: parent.horizontalCenter
                text: lk.profile.name || Quickshell.env("USER") || ""
                readonly property real baseSize: Math.min(44, lk.profile.nameSize || 30) * lk.u
                FontMetrics { id: plainName; font.family: Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
                FontMetrics { id: chosenName; font.family: lk.profile.font || Tok.sans; font.pixelSize: 100; font.weight: Font.DemiBold }
                readonly property real opticalScale: {
                    var a = plainName.tightBoundingRect(text).width, b = chosenName.tightBoundingRect(text).width;
                    if (!(a > 0 && b > 0 && plainName.xHeight > 0 && chosenName.xHeight > 0)) return 1;
                    return Math.max(1, Math.min(2, Math.sqrt(plainName.xHeight / chosenName.xHeight * a / b)));
                }
                font.family: lk.profile.font || Tok.sans; font.weight: Font.DemiBold
                font.pixelSize: Math.round(baseSize * opticalScale)
                color: "white"
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowColor: lk.profile.glow ? (lk.profile.color || Tok.accent) : "#000"
                    shadowBlur: 0.7; shadowOpacity: lk.profile.glow ? 0.9 : 0.4 }
            }
            Item { width: 1; height: 26 * lk.u }

            // The field draws dots for what is typed; the text itself never reaches this file.
            Item {
                id: field
                anchors.horizontalCenter: parent.horizontalCenter
                width: 320 * lk.u; height: 50 * lk.u
                property real shakeX: 0
                Rectangle {
                    x: field.shakeX
                    width: parent.width; height: parent.height; radius: height / 2
                    color: lk.glass
                    border.width: lk.fails > 0 && lk.typed === 0 ? 2 : 1
                    border.color: lk.fails > 0 && lk.typed === 0 ? Tok.crit : lk.busy ? Tok.accent : Qt.rgba(1, 1, 1, 0.3)
                    Behavior on border.color { ColorAnimation { duration: 160 * lk.motion } }

                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 22 * lk.u; anchors.verticalCenter: parent.verticalCenter
                        visible: lk.typed === 0 && !lk.busy
                        text: lk.fails > 0 ? "Try again" : "Password"
                        font.family: Tok.sans; font.pixelSize: 15 * lk.u; color: lk.faint
                    }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 22 * lk.u
                        anchors.right: goBtn.left; anchors.rightMargin: 8 * lk.u
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7 * lk.u
                        clip: true
                        Repeater {
                            model: Math.min(lk.typed, 22)
                            delegate: Rectangle {
                                width: 9 * lk.u; height: width; radius: width / 2
                                color: "white"
                                opacity: lk.busy ? 0.4 : 1
                                scale: 0
                                Component.onCompleted: scale = 1
                                Behavior on scale { NumberAnimation { duration: 110 * lk.motion; easing.type: Easing.OutBack } }
                            }
                        }
                    }
                    Rectangle {
                        id: goBtn
                        anchors.right: parent.right; anchors.rightMargin: 6 * lk.u; anchors.verticalCenter: parent.verticalCenter
                        width: parent.height - 12 * lk.u; height: width; radius: width / 2
                        color: lk.typed > 0 && !lk.busy ? Tok.accent : Qt.rgba(1, 1, 1, 0.1)
                        Behavior on color { ColorAnimation { duration: 140 * lk.motion } }
                        Text {
                            anchors.centerIn: parent
                            text: "arrow_forward"
                            visible: !lk.busy
                            font.family: "Material Symbols Rounded"; font.pixelSize: 20 * lk.u
                            color: lk.typed > 0 ? Tok.accentInk : lk.faint
                        }
                        // checking: the button becomes a turning arc
                        Rectangle {
                            anchors.centerIn: parent; visible: lk.busy
                            width: parent.width * 0.5; height: width; radius: width / 2
                            color: "transparent"; border.width: 2 * lk.u; border.color: Qt.rgba(1, 1, 1, 0.25)
                            Rectangle { width: 5 * lk.u; height: width; radius: width / 2; color: "white"
                                x: parent.width / 2 - width / 2; y: -width / 2 + 1 }
                            RotationAnimation on rotation { running: lk.busy; from: 0; to: 360; duration: 800; loops: Animation.Infinite }
                        }
                        MouseArea { anchors.fill: parent; enabled: !lk.preview; cursorShape: Qt.PointingHandCursor
                            onClicked: lk.key({ key: Qt.Key_Return, text: "", modifiers: 0 }) }
                    }
                }
                SequentialAnimation {
                    id: shake
                    NumberAnimation { target: field; property: "shakeX"; to: -14 * lk.u; duration: 50 }
                    NumberAnimation { target: field; property: "shakeX"; to: 12 * lk.u; duration: 70 }
                    NumberAnimation { target: field; property: "shakeX"; to: -8 * lk.u; duration: 60 }
                    NumberAnimation { target: field; property: "shakeX"; to: 5 * lk.u; duration: 50 }
                    NumberAnimation { target: field; property: "shakeX"; to: 0; duration: 40 }
                }
                Connections { target: lk; function onShakesChanged() { if (!Tok.reducedMotion) shake.restart() } }
            }

            Item { width: 1; height: 16 * lk.u }
            // one line under the field, most urgent first
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 420 * lk.u; horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                height: 40 * lk.u
                readonly property string what: {
                    if (lk.message && lk.messageIsError) return lk.message;
                    if (lk.fails > 0 && lk.typed === 0 && !lk.busy)
                        return lk.fails === 1 ? "Wrong password" : "Wrong password · " + lk.fails + " tries";
                    if (lk.capsLock) return "Caps Lock is on";
                    if (lk.message) return lk.message;
                    return "";
                }
                text: what
                color: (lk.message && lk.messageIsError) || (lk.fails > 0 && lk.typed === 0 && !lk.busy) ? "#ffb4ab"
                     : lk.capsLock ? "#ffd8a8" : lk.dim
                font.family: Tok.sans; font.pixelSize: 13 * lk.u
            }
        }

        // ---------- bottom strip, both states ----------
        // now playing, bottom left
        Rectangle {
            id: media
            visible: !!lk.player && lk.profile.showMedia !== false && (lk.player.trackTitle || "") !== ""
            anchors.left: parent.left; anchors.leftMargin: parent.width * 0.075
            anchors.bottom: parent.bottom; anchors.bottomMargin: 36 * lk.u
            width: 360 * lk.u; height: 64 * lk.u; radius: 18 * lk.u
            color: lk.glass; border.width: 1; border.color: lk.glassLine
            Rectangle {
                id: art
                x: 10 * lk.u; anchors.verticalCenter: parent.verticalCenter
                width: 44 * lk.u; height: width; radius: 10 * lk.u; color: Qt.rgba(1, 1, 1, 0.1); clip: true
                Text { anchors.centerIn: parent; text: "music_note"; font.family: "Material Symbols Rounded"; font.pixelSize: 22 * lk.u; color: lk.faint }
                Image { anchors.fill: parent; source: lk.player ? (lk.player.trackArtUrl || "") : ""
                    fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 128 }
            }
            Column {
                anchors.left: art.right; anchors.leftMargin: 12 * lk.u
                anchors.right: transport.left; anchors.rightMargin: 8 * lk.u
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * lk.u
                Text { width: parent.width; elide: Text.ElideRight; text: lk.player ? (lk.player.trackTitle || "") : ""
                    font.family: Tok.sans; font.pixelSize: 14 * lk.u; font.weight: Font.DemiBold; color: "white" }
                Text { width: parent.width; elide: Text.ElideRight; text: lk.player ? (lk.player.trackArtist || lk.player.identity || "") : ""
                    font.family: Tok.sans; font.pixelSize: 12 * lk.u; color: lk.dim }
            }
            Row {
                id: transport
                anchors.right: parent.right; anchors.rightMargin: 8 * lk.u; anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                Repeater {
                    model: [
                        { i: "skip_previous", f: function() { lk.player.previous() }, on: !!lk.player && lk.player.canGoPrevious },
                        { i: lk.player && lk.player.isPlaying ? "pause" : "play_arrow", f: function() { lk.player.togglePlaying() }, on: !!lk.player && lk.player.canTogglePlaying },
                        { i: "skip_next", f: function() { lk.player.next() }, on: !!lk.player && lk.player.canGoNext } ]
                    delegate: Rectangle {
                        required property var modelData
                        width: 36 * lk.u; height: width; radius: width / 2
                        color: tma.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                        opacity: modelData.on ? 1 : 0.35
                        Text { anchors.centerIn: parent; text: modelData.i; font.family: "Material Symbols Rounded"; font.pixelSize: 24 * lk.u; color: "white" }
                        MouseArea { id: tma; anchors.fill: parent; hoverEnabled: true; enabled: !lk.preview && modelData.on
                            cursorShape: Qt.PointingHandCursor; onClicked: modelData.f() }
                    }
                }
            }
        }

        // status, bottom right: layout · battery · power
        Row {
            id: status
            anchors.right: parent.right; anchors.rightMargin: 36 * lk.u
            anchors.bottom: parent.bottom; anchors.bottomMargin: 36 * lk.u + (64 - 44) / 2 * lk.u
            spacing: 10 * lk.u
            Rectangle {
                visible: lk.layout !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: layT.implicitWidth + 24 * lk.u; height: 34 * lk.u; radius: height / 2
                color: lk.glass; border.width: 1; border.color: lk.glassLine
                Text { id: layT; anchors.centerIn: parent; text: lk.layout.toUpperCase()
                    font.family: Tok.mono; font.pixelSize: 12 * lk.u; font.weight: Font.DemiBold; color: "white" }
            }
            Rectangle {
                visible: !!lk.battery
                anchors.verticalCenter: parent.verticalCenter
                width: batRow.implicitWidth + 24 * lk.u; height: 34 * lk.u; radius: height / 2
                color: lk.glass; border.width: 1; border.color: lk.glassLine
                Row {
                    id: batRow; anchors.centerIn: parent; spacing: 4 * lk.u
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: !lk.battery ? "" : lk.battery.charging ? "battery_charging_full"
                            : lk.battery.pct > 85 ? "battery_full" : lk.battery.pct > 55 ? "battery_5_bar"
                            : lk.battery.pct > 30 ? "battery_3_bar" : lk.battery.pct > 12 ? "battery_2_bar" : "battery_alert"
                        rotation: 90
                        font.family: "Material Symbols Rounded"; font.pixelSize: 18 * lk.u
                        color: lk.battery && !lk.battery.charging && lk.battery.pct <= 12 ? "#ffb4ab" : "white"
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter
                        text: lk.battery ? Math.round(lk.battery.pct) + "%" : ""
                        font.family: Tok.mono; font.pixelSize: 12 * lk.u; color: "white" }
                }
            }
            Rectangle {
                id: powerBtn
                width: 44 * lk.u; height: width; radius: width / 2
                color: powerMenu.open || pma.containsMouse ? Qt.rgba(1, 1, 1, 0.2) : lk.glass
                border.width: 1; border.color: lk.glassLine
                Text { anchors.centerIn: parent; text: "power_settings_new"; font.family: "Material Symbols Rounded"; font.pixelSize: 21 * lk.u; color: "white" }
                MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; enabled: !lk.preview; cursorShape: Qt.PointingHandCursor
                    onClicked: { powerMenu.armed = ""; powerMenu.open = !powerMenu.open } }
            }
        }

        // Suspend works at once; restart and shut down ask a second click, because a stray
        // click on a locked machine should not end anyone's open work.
        Rectangle {
            id: powerMenu
            property bool open: false
            property string armed: ""
            anchors.right: status.right; anchors.bottom: status.top; anchors.bottomMargin: 10 * lk.u
            width: 220 * lk.u; height: pmCol.implicitHeight + 12 * lk.u; radius: 18 * lk.u
            color: Qt.rgba(0.04, 0.05, 0.08, 0.82); border.width: 1; border.color: lk.glassLine
            opacity: open ? 1 : 0; visible: opacity > 0
            transform: Translate { y: powerMenu.open ? 0 : 8 * lk.u; Behavior on y { NumberAnimation { duration: 180 * lk.motion; easing.type: Easing.OutCubic } } }
            Behavior on opacity { NumberAnimation { duration: 150 * lk.motion } }
            onOpenChanged: if (!open) armed = ""
            Column {
                id: pmCol
                anchors.centerIn: parent; width: parent.width - 12 * lk.u
                Repeater {
                    model: [ { a: "suspend", i: "bedtime", l: "Suspend", ask: false },
                             { a: "reboot", i: "restart_alt", l: "Restart", ask: true },
                             { a: "poweroff", i: "power_settings_new", l: "Shut down", ask: true } ]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool arm: powerMenu.armed === modelData.a
                        width: pmCol.width; height: 42 * lk.u; radius: 12 * lk.u
                        color: arm ? Qt.rgba(1, 0.42, 0.38, 0.22) : ima.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 14 * lk.u; anchors.verticalCenter: parent.verticalCenter
                            spacing: 12 * lk.u
                            Text { text: modelData.i; font.family: "Material Symbols Rounded"; font.pixelSize: 19 * lk.u
                                color: arm ? "#ffb4ab" : "white"; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: arm ? "Click again to " + modelData.l.toLowerCase() : modelData.l
                                font.family: Tok.sans; font.pixelSize: 13 * lk.u; color: arm ? "#ffb4ab" : "white"
                                anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea { id: ima; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (modelData.ask && !arm) { powerMenu.armed = modelData.a; return }
                                powerMenu.open = false; lk.power(modelData.a);
                            } }
                    }
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom; anchors.bottomMargin: 36 * lk.u + 22 * lk.u
            text: lk.login ? "Enter to unlock · Esc to go back" : "Type or click to unlock"
            font.family: Tok.sans; font.pixelSize: 12 * lk.u; color: lk.faint
            opacity: media.visible && parent.width < 1500 * lk.u ? 0 : 1
        }
    }

    // ---------- grouping ----------
    readonly property var groups: {
        var by = {}, order = [];
        for (var i = 0; i < notes.length; i++) {
            var n = notes[i], k = n.appName || "notification";
            if (!by[k]) { by[k] = { app: k, icon: n.appIcon || "", items: [] }; order.push(k) }
            by[k].items.push(n);
        }
        return order.map(function(k) { return by[k] });
    }

    // ---------- keys ----------
    focus: !preview
    Keys.onPressed: e => { lk.key(e); e.accepted = true }
}
