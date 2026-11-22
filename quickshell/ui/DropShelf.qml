// sea-shell — File Drop Shelf & Instant LAN QR Share (Super+Alt+S).
// Hold files/screenshots across workspaces, convert images (WebP/JPG/PNG),
// or serve any file over local Wi-Fi with a scannable QR code (auto-expires in 5m).
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

Scope {
    id: root
    property bool shown: false
    property var uiFor: function (scr) { return 1 }
    signal closed()

    readonly property string script: Qt.resolvedUrl("sea-dropzone.py").toString().replace("file://", "")
    property var openOn: null
    property var items: []
    property var activeShare: null
    property int qrNonce: 0

    function open() {
        var fm = Hyprland.focusedMonitor, scrs = Quickshell.screens;
        root.openOn = scrs.length ? scrs[0] : null;
        if (fm) for (var i = 0; i < scrs.length; i++) if (scrs[i].name === fm.name) root.openOn = scrs[i];
        root.shown = true;
        root.refresh();
    }
    function close() {
        if (!root.shown) return;
        root.shown = false;
        root.closed();
    }
    function toggle() { if (root.shown) root.close(); else root.open(); }

    function refresh() { listProc.running = false; listProc.running = true; }
    Timer { id: refreshDelay; interval: 260; onTriggered: root.refresh() }

    Process {
        id: listProc
        command: ["python3", root.script, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.items) root.items = j.items;
                    root.activeShare = j.share || null;
                    root.qrNonce++;
                } catch (e) {}
            }
        }
    }

    function addFromClipboard() {
        Quickshell.execDetached(["python3", root.script, "add-clip"]);
        refreshDelay.restart();
    }
    function addPath(p) {
        var s = ("" + (p || "")).trim();
        if (!s) return;
        Quickshell.execDetached(["python3", root.script, "add", s]);
        refreshDelay.restart();
    }
    function removeItem(p) {
        Quickshell.execDetached(["python3", root.script, "remove", p]);
        root.items = root.items.filter(function (x) { return x.path !== p });
    }
    function convertItem(p, fmt) {
        Quickshell.execDetached(["python3", root.script, "convert", p, fmt]);
        refreshDelay.interval = 650;
        refreshDelay.restart();
    }
    function shareItem(p) {
        shareProc.command = ["python3", root.script, "share", p];
        shareProc.running = false;
        shareProc.running = true;
    }
    function stopShare() {
        Quickshell.execDetached(["python3", root.script, "stop-share"]);
        root.activeShare = null;
    }

    Process {
        id: shareProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.ok) { root.activeShare = j; root.qrNonce++; }
                } catch (e) {}
            }
        }
    }

    Variants {
        model: (root.shown && root.openOn) ? [root.openOn] : []
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property real ui: root.uiFor(win.screen)
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "sea-shell:dropzone"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.42)
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(680, (win.width / win.ui) - 48)
                height: Math.min(540, (win.height / win.ui) - 64)
                radius: Tok.rCard
                color: Tok.bg
                border.width: 1
                border.color: Tok.ruleHard
                scale: win.ui * (ready ? 1.0 : 0.97)
                opacity: ready ? 1.0 : 0.0
                property bool ready: false
                Component.onCompleted: { ready = true; pathIn.forceActiveFocus() }
                Behavior on opacity { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }
                Behavior on scale { NumberAnimation { duration: Tok.mFast; easing.type: Tok.mEase } }

                MouseArea { anchors.fill: parent }

                DropArea {
                    anchors.fill: parent
                    onDropped: (drop) => {
                        if (drop.hasUrls) {
                            for (var i = 0; i < drop.urls.length; i++) {
                                var u = ("" + drop.urls[i]).replace(/^file:\/\//, "");
                                root.addPath(decodeURIComponent(u));
                            }
                        }
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    // ---- Header ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Sym { text: "inventory_2"; sz: 18; color: Tok.accent }
                        Text { text: "Drop shelf & QR share"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            implicitHeight: 28; implicitWidth: clRow.implicitWidth + 16; radius: Tok.r
                            color: clMa.containsMouse ? Tok.alpha(Tok.accent, 0.2) : Tok.surface
                            border.width: 1; border.color: Tok.rule
                            Row { id: clRow; anchors.centerIn: parent; spacing: 5
                                Sym { anchors.verticalCenter: parent.verticalCenter; text: "content_paste"; sz: 14; color: Tok.accent }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "+ From clipboard"; color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans } }
                            MouseArea { id: clMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.addFromClipboard() }
                        }
                        Rectangle {
                            visible: root.items.length > 0
                            implicitHeight: 28; implicitWidth: 52; radius: Tok.r
                            color: clrMa.containsMouse ? Tok.critWash : Tok.surface
                            border.width: 1; border.color: clrMa.containsMouse ? Tok.crit : Tok.rule
                            Text { anchors.centerIn: parent; text: "Clear"; color: clrMa.containsMouse ? Tok.crit : Tok.ink2; font.pixelSize: 11; font.family: Tok.sans }
                            MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { Quickshell.execDetached(["python3", root.script, "clear"]); root.items = []; root.activeShare = null } }
                        }
                    }

                    // ---- Quick path add bar ----
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
                            color: Tok.sunken; border.width: 1; border.color: pathIn.activeFocus ? Tok.accent : Tok.rule
                            TextInput {
                                id: pathIn; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                color: Tok.ink; font.pixelSize: 12; font.family: Tok.mono; clip: true
                                Text { visible: pathIn.text.length === 0; anchors.verticalCenter: parent.verticalCenter; text: "Drop files here or paste a file path (~/Pictures/…) and press Enter"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                                Keys.onReturnPressed: { root.addPath(text); text = "" }
                                Keys.onEscapePressed: root.close()
                            }
                        }
                    }

                    // ---- Active LAN QR Share card ----
                    Rectangle {
                        visible: root.activeShare !== null && !!root.activeShare.url
                        Layout.fillWidth: true
                        implicitHeight: 146
                        radius: Tok.r
                        color: Tok.alpha(Tok.accent, 0.10)
                        border.width: 1; border.color: Tok.alpha(Tok.accent, 0.55)
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 12; spacing: 14
                            Rectangle {
                                Layout.preferredWidth: 122; Layout.preferredHeight: 122
                                radius: Tok.rSmall; color: "#ffffff"; clip: true
                                Image {
                                    anchors.fill: parent; anchors.margins: 4
                                    source: (root.activeShare && root.activeShare.qr) ? (Tok.fileUrl(root.activeShare.qr) + "?" + root.qrNonce) : ""
                                    fillMode: Image.PreserveAspectFit; cache: false
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 5
                                Text { text: "Scan on phone to download"; color: Tok.accent; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.DemiBold }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideMiddle
                                    text: root.activeShare ? (root.activeShare.filename || "") : ""
                                    color: Tok.ink; font.pixelSize: 14; font.family: Tok.sans; font.weight: Font.DemiBold
                                }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideMiddle
                                    text: root.activeShare ? (root.activeShare.url || "") : ""
                                    color: Tok.ink2; font.pixelSize: 11; font.family: Tok.mono
                                }
                                Row {
                                    spacing: 6
                                    Rectangle {
                                        implicitHeight: 26; implicitWidth: 82; radius: Tok.r
                                        color: cuMa.containsMouse ? Tok.accent : Tok.surface
                                        border.width: 1; border.color: Tok.accent
                                        Text { anchors.centerIn: parent; text: "Copy URL"; color: cuMa.containsMouse ? Tok.accentInk : Tok.ink; font.pixelSize: 11; font.family: Tok.sans }
                                        MouseArea { id: cuMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: if (root.activeShare) Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", root.activeShare.url]) }
                                    }
                                    Rectangle {
                                        implicitHeight: 26; implicitWidth: 92; radius: Tok.r
                                        color: stMa.containsMouse ? Tok.crit : Tok.critWash
                                        border.width: 1; border.color: Tok.crit
                                        Text { anchors.centerIn: parent; text: "Stop share"; color: stMa.containsMouse ? "#ffffff" : Tok.crit; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium }
                                        MouseArea { id: stMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.stopShare() }
                                    }
                                }
                            }
                        }
                    }

                    // ---- Shelf items list ----
                    ListView {
                        id: shelfView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 6
                        model: root.items

                        delegate: Rectangle {
                            id: sRow
                            required property var modelData
                            width: shelfView.width
                            height: modelData.is_image ? 62 : 48
                            radius: Tok.r
                            color: sMa.containsMouse ? Tok.raised : Tok.surface
                            border.width: 1; border.color: Tok.rule
                            MouseArea { id: sMa; anchors.fill: parent; hoverEnabled: true }

                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 10
                                Rectangle {
                                    visible: sRow.modelData.is_image
                                    Layout.preferredWidth: 58; Layout.preferredHeight: 46; radius: Tok.rSmall; color: Tok.sunken; clip: true
                                    Image { anchors.fill: parent; source: Tok.fileUrl(sRow.modelData.path); fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; sourceSize.width: 120 }
                                }
                                Sym { visible: !sRow.modelData.is_image; text: "description"; sz: 20; color: Tok.accent }

                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    Text { Layout.fillWidth: true; elide: Text.ElideMiddle; text: sRow.modelData.name; color: Tok.ink; font.pixelSize: 12; font.family: Tok.sans; font.weight: Font.Medium }
                                    Text { text: sRow.modelData.ext + " · " + sRow.modelData.size; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.mono }
                                }

                                // Quick image convert buttons
                                Row {
                                    visible: sRow.modelData.is_image
                                    spacing: 4
                                    Repeater {
                                        model: ["webp", "jpg", "png"]
                                        delegate: Rectangle {
                                            required property string modelData
                                            visible: sRow.modelData.ext.toLowerCase() !== modelData
                                            implicitHeight: 24; implicitWidth: cvT.implicitWidth + 12; radius: Tok.rSmall
                                            color: cvMa.containsMouse ? Tok.alpha(Tok.accent, 0.18) : Tok.sunken
                                            border.width: 1; border.color: Tok.rule
                                            Text { id: cvT; anchors.centerIn: parent; text: "→" + modelData.toUpperCase(); color: Tok.ink2; font.pixelSize: 10; font.family: Tok.mono }
                                            MouseArea { id: cvMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.convertItem(sRow.modelData.path, modelData) }
                                        }
                                    }
                                }

                                // QR Wi-Fi Share button
                                Rectangle {
                                    implicitHeight: 26; implicitWidth: qrBtnR.implicitWidth + 14; radius: Tok.rSmall
                                    color: qrMa.containsMouse ? Tok.accent : Tok.alpha(Tok.accent, 0.16)
                                    Row { id: qrBtnR; anchors.centerIn: parent; spacing: 4
                                        Sym { anchors.verticalCenter: parent.verticalCenter; text: "qr_code_2"; sz: 14; color: qrMa.containsMouse ? Tok.accentInk : Tok.accent }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "QR"; color: qrMa.containsMouse ? Tok.accentInk : Tok.ink; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium } }
                                    MouseArea { id: qrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.shareItem(sRow.modelData.path) }
                                }

                                // Remove button
                                Rectangle {
                                    implicitWidth: 26; implicitHeight: 26; radius: Tok.rSmall
                                    color: rmMa.containsMouse ? Tok.critWash : "transparent"
                                    Sym { anchors.centerIn: parent; text: "close"; sz: 15; color: rmMa.containsMouse ? Tok.crit : Tok.ink3 }
                                    MouseArea { id: rmMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeItem(sRow.modelData.path) }
                                }
                            }
                        }

                        Text {
                            visible: root.items.length === 0
                            anchors.centerIn: parent
                            text: "Shelf is empty — drag files here or click '+ From clipboard'"
                            color: Tok.ink3; font.pixelSize: 12; font.family: Tok.sans
                        }
                    }

                    Text { text: "Local LAN QR shares auto-expire after 5 minutes · Esc close"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
                }
            }
        }
    }
}
