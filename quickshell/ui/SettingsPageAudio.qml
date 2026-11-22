// Settings → Audio. Built the first time it is opened; see PageLoader in settings.qml.
import Quickshell
import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: audioPage
    property int tabIdx: 0
    visible: root.tab === 0; Layout.fillWidth: true; spacing: 12
    readonly property var appRows: {
        // Volume comes from the live Pipewire node, routing from sea-audio.py. They are one app, so
        // they are one row, joined on node id. An app sea-audio hasn't reported yet still gets its slider.
        var routes = root.audioStreams, out = [];
        for (var i = 0; i < root.streams.length; i++) {
            var n = root.streams[i], route = null;
            for (var k = 0; k < routes.length; k++) if (routes[k].id === n.id) route = routes[k];
            out.push({ node: n, id: n.id, app: route ? route.app : root.streamName(n),
                       title: route ? (route.title || "") : "", sinkId: route ? route.sink_id : -1,
                       sinkLabel: route ? (route.sink_label || "") : "" });
        }
        return out;
    }
    function sinkLabel(sinkId) {
        for (var i = 0; i < root.sinkRows.length; i++)
            if (root.sinkRows[i]._node.id === sinkId) return root.sinkRows[i].name;
        return "Default output";
    }
    property int openApp: -1

    // A row for one device: pick it by clicking. Replaces a table whose only real column was a name.
    component DeviceRow: Rectangle {
        id: dev
        required property var modelData
        required property int index
        property int selectedIndex: -1
        signal picked(var node)
        readonly property bool sel: index === selectedIndex
        Layout.fillWidth: true; implicitHeight: 38; radius: Tok.rSmall
        color: sel ? Tok.accentWash : (devMouse.containsMouse ? Tok.surface : "transparent")
        MouseArea { id: devMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: dev.picked(dev.modelData._node) }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
            Text { text: "check"; renderType: Text.NativeRendering; font.family: "Material Symbols Rounded"; font.pixelSize: 16
                color: dev.sel ? Tok.accent : "transparent" }
            ColumnLayout { Layout.fillWidth: true; spacing: 0
                Text { text: dev.modelData.name; color: Tok.ink; Layout.fillWidth: true; elide: Text.ElideRight
                    font.pixelSize: 12; font.family: Tok.sans; font.weight: dev.sel ? 600 : 400 }
                Text { visible: dev.modelData.chip !== ""; text: dev.modelData.chip; color: Tok.ink3; Layout.fillWidth: true
                    elide: Text.ElideRight; font.pixelSize: 11; font.family: Tok.sans }
            }
            Text { visible: !!dev.modelData.rate && dev.modelData.rate !== "—"; text: dev.modelData.rate || ""
                color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
            Text { visible: !!dev.modelData.format; text: dev.modelData.format || ""; color: Tok.ink2
                font.pixelSize: 11; font.family: Tok.mono }
        }
    }

    MacHeaderCard {
        icon: "volume_up"
        badgeColor: "#FF2D55"
        title: "Sound"
        description: "Choose output and input devices, test your microphone, pick Bluetooth codecs, and adjust per-app volume."
    }

    Section { title: "Output"; icon: "volume_up" }
    RowLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
        Sym { text: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? "volume_off" : "volume_up"; sz: 18
            color: (root.curSink && root.curSink.audio && root.curSink.audio.muted) ? theme.faint : theme.sub; Layout.alignment: Qt.AlignVCenter
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: { if (root.curSink && root.curSink.audio) root.curSink.audio.muted = !root.curSink.audio.muted } } }
        Slider { value: (root.curSink && root.curSink.audio) ? root.curSink.audio.volume : 0
            onMoved: (v) => { if (root.curSink && root.curSink.audio) { root.curSink.audio.muted = false; root.curSink.audio.volume = v } } }
        Text { text: (root.curSink && root.curSink.audio) ? Math.round(root.curSink.audio.volume * 100) + "%" : "—"
            color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight }
        IndBtn { text: "Test"; rank: "secondary"
            onActivated: Quickshell.execDetached(["pw-play", "/usr/share/sounds/freedesktop/stereo/audio-volume-change.oga"]) }
    }
    ColumnLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 0
        Repeater { model: root.sinkRows
            delegate: DeviceRow { selectedIndex: root.sinkSel; onPicked: (node) => Pipewire.preferredDefaultAudioSink = node } }
        Text { visible: root.sinkRows.length === 0; text: "No output devices"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
    }
    // ---- bluetooth codec (per connected BT output offering a choice) ----
    Text { visible: root.audioBtSinks.length > 0; text: "Bluetooth codec"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.leftMargin: 14; Layout.topMargin: 2 }
    ColumnLayout { visible: root.audioBtSinks.length > 0; Layout.fillWidth: true; spacing: 8
        Repeater { model: root.audioBtSinks
            delegate: ColumnLayout { id: btRow; required property var modelData; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 5
                Text { text: btRow.modelData.label; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; elide: Text.ElideRight; Layout.fillWidth: true }
                Flow { Layout.fillWidth: true; Layout.leftMargin: 4; spacing: 6
                    Repeater { model: btRow.modelData.bt_codecs
                        delegate: Rectangle { required property var modelData
                            readonly property bool on: modelData.active
                            implicitHeight: 26; implicitWidth: bcT.implicitWidth + 20; radius: Tok.r
                            color: on ? theme.a(theme.iris, 0.25) : (bcMa.containsMouse ? theme.a(theme.line, 0.55) : theme.a(theme.line, 0.32))
                            border.width: 1; border.color: on ? theme.a(theme.iris, 0.55) : theme.a(theme.iris, 0.14)
                            Text { id: bcT; anchors.centerIn: parent; text: modelData.codec; color: on ? theme.iris : theme.sub; font.pixelSize: 11; font.family: Tok.sans; font.bold: on }
                            MouseArea { id: bcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.audioSetCodec(btRow.modelData.name, modelData.profile) } } } } } } }

    Section { title: "Input"; icon: "mic" }
    RowLayout { visible: root.curSource && root.curSource.audio; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
        Sym { text: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? "mic_off" : "mic"; sz: 18
            color: (root.curSource && root.curSource.audio && root.curSource.audio.muted) ? theme.faint : theme.sub; Layout.alignment: Qt.AlignVCenter
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: { if (root.curSource && root.curSource.audio) root.curSource.audio.muted = !root.curSource.audio.muted } } }
        Slider { fill: theme.good; value: (root.curSource && root.curSource.audio) ? root.curSource.audio.volume : 0
            onMoved: (v) => { if (root.curSource && root.curSource.audio) { root.curSource.audio.muted = false; root.curSource.audio.volume = v } } }
        Text { text: (root.curSource && root.curSource.audio) ? Math.round(root.curSource.audio.volume * 100) + "%" : "—"
            color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight }
    }
    // Is it hearing you? The most common microphone question, answered without recording anything.
    // Only listens for the few seconds after Test, so Settings never lights the mic indicator by itself.
    RowLayout { visible: root.curSource && root.curSource.audio; Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 12
        Text { text: "Level"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.minimumWidth: 18 }
        Rectangle { Layout.fillWidth: true; implicitHeight: 6; radius: 3; color: Tok.alpha(Tok.ink, 0.10)
            Rectangle { height: parent.height; radius: 3; color: theme.good
                width: parent.width * Math.min(1, micTest.running ? Math.sqrt(micPeak.peak) : 0)
                Behavior on width { NumberAnimation { duration: 80 } } } }
        IndBtn { text: micTest.running ? "Listening…" : "Test"; rank: "secondary"; enabled: !micTest.running
            onActivated: micTest.running = true }
        PwNodePeakMonitor { id: micPeak; node: root.curSource; enabled: root.shown && root.tab === 0 && micTest.running }
        Timer { id: micTest; interval: 8000 }
    }
    ColumnLayout { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 0
        Repeater { model: root.sourceRows
            delegate: DeviceRow { selectedIndex: root.sourceSel; onPicked: (node) => Pipewire.preferredDefaultAudioSource = node } }
        Text { visible: root.sourceRows.length === 0; text: "No input devices"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
    }

    Section { title: "Apps"; icon: "graphic_eq" }
    Text { visible: audioPage.appRows.length === 0; text: "Nothing is playing. Apps show up here while they make sound."
        color: theme.faint; font.pixelSize: 12; font.family: Tok.sans; Layout.leftMargin: 14 }
    Repeater { model: audioPage.appRows
        delegate: ColumnLayout { id: appRow; required property var modelData
            readonly property bool open: audioPage.openApp === modelData.id
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 4
            RowLayout { Layout.fillWidth: true; spacing: 10
                ColumnLayout { Layout.preferredWidth: 220; Layout.maximumWidth: 220; spacing: 0
                    Text { text: appRow.modelData.app; color: Tok.ink; Layout.fillWidth: true; elide: Text.ElideRight
                        font.pixelSize: 12; font.family: Tok.sans; font.weight: 500 }
                    Text { visible: appRow.modelData.title !== ""; text: appRow.modelData.title; color: Tok.ink3; Layout.fillWidth: true
                        elide: Text.ElideRight; font.pixelSize: 11; font.family: Tok.sans }
                }
                Slider { fill: theme.iris; value: appRow.modelData.node.audio ? appRow.modelData.node.audio.volume : 0
                    onMoved: (v) => { if (appRow.modelData.node.audio) appRow.modelData.node.audio.volume = v } }
                Text { text: appRow.modelData.node.audio ? Math.round(appRow.modelData.node.audio.volume * 100) + "%" : "—"
                    color: theme.sub; font.pixelSize: 12; font.family: Tok.sans; Layout.minimumWidth: 40; horizontalAlignment: Text.AlignRight }
                IndBtn { text: audioPage.sinkLabel(appRow.modelData.sinkId); rank: "ghost"; Layout.maximumWidth: 180
                    onActivated: audioPage.openApp = appRow.open ? -1 : appRow.modelData.id }
            }
            Flow { visible: appRow.open; Layout.fillWidth: true; spacing: 6
                Chip { label: "Default output"; on: false
                    onPicked: { root.audioRoute(appRow.modelData.id, "auto"); audioPage.openApp = -1 } }
                Repeater { model: root.sinkRows
                    delegate: Chip { required property var modelData; label: modelData.name
                        on: appRow.modelData.sinkId === modelData._node.id
                        onPicked: { root.audioRoute(appRow.modelData.id, modelData._node.id); audioPage.openApp = -1 } } }
            }
        }
    }
    Text { Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; wrapMode: Text.WordWrap
        visible: audioPage.appRows.length > 0
        text: "Click the output name beside an app to send just that app somewhere else."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
}
