// sea-shell — Sound & Per-App Mixer dropdown body (extracted from shell.qml).
// Master output volume, output sink switcher with sample-rate/bit-depth badges,
// Bluetooth A2DP codec picker, microphone mute/gain, and per-app PipeWire mixer
// with individual mute buttons and direct sink routing picker.
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Column {
    id: ad
    property var shellRoot: null
    property var audioSink: null
    property int volPct: 0
    property int expandedStreamId: -1
    spacing: 5

    DropHeader {
        title: "Sound"
        status: (ad.audioSink && ad.audioSink.muted)
            ? "Muted"
            : (Pipewire.defaultAudioSink && shellRoot ? "Playing on " + shellRoot.sinkLabel(Pipewire.defaultAudioSink) : "No output")
        tone: (ad.audioSink && ad.audioSink.muted) ? "warn" : "neutral"
        value: ad.volPct + "%"
    }

    // ---- Master output slider ----
    Row {
        width: parent.width; spacing: 10; height: 32
        Rectangle {
            width: 28; height: 28; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
            color: volMuteMa.containsMouse ? Tok.alpha(Tok.accent, 0.15) : "transparent"
            Sym {
                anchors.centerIn: parent
                text: (ad.audioSink && ad.audioSink.muted) ? "volume_off" : "volume_up"
                sz: 17
                color: (ad.audioSink && ad.audioSink.muted) ? Tok.crit : Tok.ink2
            }
            MouseArea {
                id: volMuteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: if (ad.audioSink) ad.audioSink.muted = !ad.audioSink.muted
            }
        }
        Slider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 38
            value: ad.audioSink ? ad.audioSink.volume : 0
            onMoved: (v) => { if (ad.audioSink) { ad.audioSink.muted = false; ad.audioSink.volume = v } }
        }
    }

    // ---- Microphone input quick control ----
    Row {
        visible: !!(shellRoot && shellRoot.micSource && shellRoot.micSource.audio)
        width: parent.width; spacing: 10; height: 28
        Rectangle {
            width: 28; height: 26; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
            color: micMuteMa.containsMouse ? Tok.alpha(Tok.accent, 0.15) : "transparent"
            Sym {
                anchors.centerIn: parent; sz: 16
                text: (shellRoot && shellRoot.micMuted) ? "mic_off" : "mic"
                color: (shellRoot && shellRoot.micMuted) ? Tok.crit : Tok.ink2
            }
            MouseArea {
                id: micMuteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: if (shellRoot) shellRoot.micToggle()
            }
        }
        Slider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 28 - 40 - 20
            value: shellRoot ? shellRoot.micVol : 0
            onMoved: (v) => {
                if (shellRoot && shellRoot.micSource && shellRoot.micSource.audio) {
                    shellRoot.micSource.audio.muted = false;
                    shellRoot.micSource.audio.volume = v;
                }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 40; horizontalAlignment: Text.AlignRight
            text: shellRoot ? (shellRoot.micMuted ? "Mute" : Math.round(shellRoot.micVol * 100) + "%") : "—"
            color: (shellRoot && shellRoot.micMuted) ? Tok.crit : Tok.ink3
            font.pixelSize: 11; font.family: Tok.mono
        }
    }

    // ---- Output devices ----
    DropSection {
        text: "Output"; rule: true
        note: shellRoot && shellRoot.sinks.length > 1 ? shellRoot.sinks.length + " devices" : ""
    }
    Repeater {
        model: shellRoot ? shellRoot.sinks : []
        delegate: DropRow {
            required property var modelData
            readonly property string nm: (modelData.name || "").toLowerCase()
            icon: nm.indexOf("bluez") >= 0 ? "headphones" : nm.indexOf("hdmi") >= 0 ? "tv" : nm.indexOf("usb") >= 0 ? "speaker" : "laptop_chromebook"
            label: shellRoot ? shellRoot.sinkLabel(modelData) : ""
            sub: shellRoot ? shellRoot.sinkCard(modelData) : ""
            current: !!Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.id === modelData.id
            value: shellRoot ? shellRoot.audioFmtBadge(modelData.name) : ""
            onClicked: Pipewire.preferredDefaultAudioSink = modelData
        }
    }

    // ---- Bluetooth codec picker ----
    DropSection { visible: !!(shellRoot && shellRoot.audioBtSink !== null); text: "Bluetooth codec"; rule: true }
    Flow {
        visible: !!(shellRoot && shellRoot.audioBtSink !== null)
        width: parent.width; spacing: 6
        Repeater {
            model: (shellRoot && shellRoot.audioBtSink) ? shellRoot.audioBtSink.bt_codecs : []
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: modelData.active
                implicitHeight: 24; implicitWidth: ccT.implicitWidth + 18; radius: Tok.r
                color: on ? Tok.alpha(Tok.accent, 0.22) : (ccMa.containsMouse ? Tok.raised : Tok.alpha(Tok.ruleHard, 0.28))
                border.width: on ? 1 : 0; border.color: Tok.alpha(Tok.accent, 0.6)
                Text { id: ccT; anchors.centerIn: parent; text: modelData.codec; color: on ? Tok.accent : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans; font.bold: on }
                MouseArea { id: ccMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (shellRoot && shellRoot.audioBtSink) shellRoot.audioSetCodec(shellRoot.audioBtSink.name, modelData.profile) }
            }
        }
    }

    // ---- Per-app mixer (volume + per-app mute + direct sink picker) ----
    DropSection {
        visible: !!(shellRoot && shellRoot.streams.length > 0)
        text: "Apps"; rule: true
        note: shellRoot && shellRoot.streams.length > 0 ? shellRoot.streams.length + " active" : ""
    }
    Repeater {
        model: shellRoot ? shellRoot.streams : []
        delegate: Column {
            id: appRow
            required property var modelData
            readonly property bool isMuted: !!(modelData.audio && modelData.audio.muted)
            readonly property bool routingOpen: ad.expandedStreamId === modelData.id
            width: parent.width; spacing: 4

            Row {
                width: parent.width; height: 22; spacing: 6
                // Per-app mute toggle button
                Rectangle {
                    width: 22; height: 22; radius: Tok.r; anchors.verticalCenter: parent.verticalCenter
                    color: appMuteMa.containsMouse ? Tok.alpha(Tok.accent, 0.14) : "transparent"
                    Sym {
                        anchors.centerIn: parent; sz: 14
                        text: appRow.isMuted ? "volume_off" : "graphic_eq"
                        color: appRow.isMuted ? Tok.crit : Tok.ink2
                    }
                    MouseArea {
                        id: appMuteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: if (modelData.audio) modelData.audio.muted = !modelData.audio.muted
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 22 - appChip.width - 12
                    elide: Text.ElideRight
                    text: shellRoot ? shellRoot.streamName(modelData) : ""
                    color: appRow.isMuted ? Tok.ink3 : Tok.ink
                    font.pixelSize: 12; font.family: Tok.sans
                }
                // Output routing chip — opens direct sink picker when > 1 sink
                Rectangle {
                    id: appChip; anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: acRow.implicitWidth + 12; height: 20; radius: Tok.r
                    color: appRow.routingOpen
                        ? Tok.alpha(Tok.accent, 0.25)
                        : (acMa.containsMouse ? Tok.alpha(Tok.accent, 0.20) : Tok.alpha(Tok.accent, 0.11))
                    border.width: appRow.routingOpen ? 1 : 0; border.color: Tok.alpha(Tok.accent, 0.55)
                    Row {
                        id: acRow; anchors.centerIn: parent; spacing: 3
                        Sym { anchors.verticalCenter: parent.verticalCenter; text: appRow.routingOpen ? "expand_less" : "arrow_forward"; sz: 11; color: Tok.accent }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: shellRoot ? shellRoot.audioSinkLabelOf(modelData.id) : ""; color: Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                    }
                    MouseArea {
                        id: acMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!shellRoot) return;
                            if (shellRoot.sinks.length > 2) {
                                ad.expandedStreamId = appRow.routingOpen ? -1 : modelData.id;
                            } else {
                                shellRoot.audioCycleRouteById(modelData.id);
                            }
                        }
                    }
                }
            }

            // Inline direct sink selector pills (when expanded on 3+ output setups)
            Flow {
                visible: appRow.routingOpen && shellRoot && shellRoot.sinks.length > 1
                width: parent.width - 24
                x: 24
                spacing: 4
                Repeater {
                    model: shellRoot ? shellRoot.sinks : []
                    delegate: Rectangle {
                        required property var modelData
                        implicitHeight: 22; implicitWidth: skLbl.implicitWidth + 14; radius: Tok.rSmall
                        color: skMa.containsMouse ? Tok.alpha(Tok.accent, 0.22) : Tok.surface
                        border.width: 1; border.color: skMa.containsMouse ? Tok.accent : Tok.rule
                        Text { id: skLbl; anchors.centerIn: parent; text: shellRoot ? shellRoot.sinkLabel(modelData) : ""; color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans }
                        MouseArea {
                            id: skMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (shellRoot) shellRoot.audioRoute(appRow.modelData.id, modelData.name);
                                ad.expandedStreamId = -1;
                            }
                        }
                    }
                }
            }

            // Per-app volume slider + percentage
            Row {
                width: parent.width; height: 20; spacing: 8
                Item { width: 22; height: 1 }
                Slider {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 22 - 42 - 16
                    value: modelData.audio ? modelData.audio.volume : 0
                    onMoved: (v) => { if (modelData.audio) { modelData.audio.muted = false; modelData.audio.volume = v } }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 42; horizontalAlignment: Text.AlignRight
                    text: modelData.audio ? (modelData.audio.muted ? "Mute" : Math.round(modelData.audio.volume * 100) + "%") : "—"
                    color: appRow.isMuted ? Tok.crit : Tok.ink2
                    font.pixelSize: 11; font.family: Tok.mono
                }
            }
        }
    }
}
