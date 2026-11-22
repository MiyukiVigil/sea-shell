// sea-shell — Wi-Fi, VPN & Share QR dropdown body (extracted from shell.qml).
// Adds 1-click scannable Wi-Fi join QR code via sea-wifi-qr.sh alongside network scanning,
// enterprise/WPA password join card, Cloudflare WARP, and NetworkManager VPN toggles.
import QtQuick
import Quickshell
import Quickshell.Io

Column {
    id: wf
    property var shellRoot: null
    property bool shown: false
    property bool expanded: false
    property bool qrOpen: false
    property var qrInfo: null
    property int qrNonce: 0
    spacing: 5

    readonly property string qrScript: Qt.resolvedUrl("sea-wifi-qr.sh").toString().replace("file://", "")

    onShownChanged: {
        if (!shown) {
            qrOpen = false;
            if (shellRoot && shellRoot.openPop !== "wifi") shellRoot.wifiCancelDraft();
        }
    }

    function toggleQr() {
        if (qrOpen) { qrOpen = false; return; }
        qrOpen = true;
        qrProc.running = false;
        qrProc.running = true;
    }

    Process {
        id: qrProc
        command: ["sh", wf.qrScript]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    wf.qrInfo = JSON.parse(text.trim() || "{}");
                    wf.qrNonce++;
                } catch (e) {
                    wf.qrInfo = { ok: false, err: "QR unavailable" };
                }
            }
        }
    }

    // Header
    Item {
        width: parent.width; height: 28
        Text {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left }
            text: "Wi-Fi"; color: Tok.ink; font.pixelSize: 16; font.family: Tok.sans; font.bold: true; font.letterSpacing: 0.6
        }
        Row {
            anchors { verticalCenter: parent.verticalCenter; right: parent.right }
            spacing: 4
            // Wi-Fi Share QR button (visible when connected)
            Rectangle {
                visible: !!(shellRoot && shellRoot.wifiOn)
                width: 26; height: 26; radius: Tok.r
                color: wf.qrOpen ? Tok.alpha(Tok.accent, 0.22) : (qrm.containsMouse ? Tok.alpha(Tok.accent, 0.14) : "transparent")
                border.width: wf.qrOpen ? 1 : 0; border.color: Tok.accent
                Sym { anchors.centerIn: parent; text: "qr_code_2"; sz: 15; color: wf.qrOpen ? Tok.accent : Tok.ink2 }
                MouseArea { id: qrm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: wf.toggleQr() }
            }
            // Refresh scan button
            Rectangle {
                width: 26; height: 26; radius: Tok.r
                color: rfm.containsMouse ? Tok.alpha(Tok.accent, 0.16) : "transparent"
                Sym { anchors.centerIn: parent; text: "refresh"; sz: 15; color: Tok.ink2 }
                MouseArea { id: rfm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.wifiRescan(true) }
            }
        }
    }

    Text {
        width: parent.width; elide: Text.ElideRight
        text: !shellRoot ? ""
            : shellRoot.wifiBusy ? "Connecting to " + shellRoot.wifiConnectingTo + "…"
            : shellRoot.wifiOn ? "Connected to " + shellRoot.ssid : "Choose a network to connect"
        color: !shellRoot ? Tok.ink2 : shellRoot.wifiBusy ? Tok.accent : shellRoot.wifiOn ? Tok.ok : Tok.ink2
        font.pixelSize: 12; font.family: Tok.sans
    }

    // ---- Scannable Wi-Fi Join QR card ----
    Rectangle {
        visible: wf.qrOpen
        width: parent.width
        implicitHeight: qrCol.implicitHeight + 18
        radius: Tok.r
        color: Tok.surface
        border.width: 1; border.color: Tok.alpha(Tok.accent, 0.55)
        Column {
            id: qrCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
            spacing: 6
            Row {
                width: parent.width; spacing: 6
                Sym { anchors.verticalCenter: parent.verticalCenter; text: "wifi"; sz: 14; color: Tok.accent }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (wf.qrInfo && wf.qrInfo.ok) ? ("Scan to join " + wf.qrInfo.ssid) : ((wf.qrInfo && wf.qrInfo.err) || "Generating QR…")
                    color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium
                    width: parent.width - 24; elide: Text.ElideRight
                }
            }
            Rectangle {
                visible: !!(wf.qrInfo && wf.qrInfo.ok && wf.qrInfo.qr)
                anchors.horizontalCenter: parent.horizontalCenter
                width: 164; height: 164; radius: Tok.rSmall; color: "#ffffff"; clip: true
                Image {
                    anchors.fill: parent; anchors.margins: 6
                    source: (wf.qrInfo && wf.qrInfo.qr) ? (Tok.fileUrl(wf.qrInfo.qr) + "?" + wf.qrNonce) : ""
                    fillMode: Image.PreserveAspectFit; cache: false
                }
            }
        }
    }

    Text {
        text: (shellRoot && shellRoot.wifiScanning) ? "Scanning for networks…" : "Available networks"
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }

    WifiJoinCard {
        width: parent.width
        visible: !!(shellRoot && shellRoot.wifiPwFor.length > 0)
        ssid: shellRoot ? shellRoot.wifiPwFor : ""
        draft: shellRoot ? shellRoot.wifiDraft : ""
        busy: !!(shellRoot && shellRoot.wifiJoining)
        enterprise: !!(shellRoot && shellRoot.wifiPwEnterprise)
        identityDraft: shellRoot ? shellRoot.wifiIdentity : ""
        message: shellRoot ? shellRoot.wifiJoinMessage : ""
        failed: !!(shellRoot && shellRoot.wifiJoinFailed)
        surface: Tok.alpha(Tok.accent, 0.08); ink: Tok.ink; muted: Tok.ink2
        accent: Tok.accent; accentInk: Tok.accentInk; danger: Tok.crit
        fontFamily: Tok.sans; rounding: Tok.rSmall
        onEdited: value => { if (shellRoot) shellRoot.wifiDraft = value }
        onIdentityEdited: value => { if (shellRoot) shellRoot.wifiIdentity = value }
        onSubmitted: value => { if (shellRoot) shellRoot.wifiJoin(shellRoot.wifiPwFor, value) }
        onCancelled: { if (shellRoot) shellRoot.wifiCancelDraft() }
    }

    Rectangle { width: parent.width; height: 1; color: Tok.rule }
    Item { height: 2; width: 1 }

    Repeater {
        model: !shellRoot ? [] : (wf.expanded ? shellRoot.wifiList : shellRoot.wifiList.slice(0, 4))
        delegate: Column {
            id: netRow
            required property var modelData
            width: parent.width; spacing: 3
            readonly property bool asking: !!(shellRoot && shellRoot.wifiPwFor === netRow.modelData.ssid)
            readonly property bool joining: !!(shellRoot && shellRoot.wifiConnectingTo === netRow.modelData.ssid)
            readonly property bool saved: !!(shellRoot && shellRoot.wifiSaved.indexOf(netRow.modelData.ssid) >= 0)
            readonly property string secLbl: shellRoot ? shellRoot.wifiSecLabel(netRow.modelData.sec) : ""
            readonly property string chipText:
                  netRow.joining                                      ? "CONNECTING"
                : netRow.secLbl === "OPEN" || netRow.secLbl === "WEP" ? netRow.secLbl
                : netRow.modelData.active                             ? ""
                : netRow.saved                                        ? "SAVED"
                : netRow.secLbl
            readonly property string chipTone:
                  netRow.joining                                      ? "accent"
                : netRow.secLbl === "OPEN" || netRow.secLbl === "WEP" ? "warn"
                : netRow.saved                                        ? "accent" : "neutral"

            Rectangle {
                width: parent.width; height: 36; radius: Tok.rSmall
                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                color: netRow.modelData.active ? Tok.alpha(Tok.accent, 0.16)
                     : (netRow.asking || netRow.joining ? Tok.alpha(Tok.accent, 0.10)
                     : (wm.containsMouse ? Tok.raised : "transparent"))
                border.width: netRow.modelData.active ? 1 : 0; border.color: Tok.alpha(Tok.accent, 0.45)

                MouseArea {
                    id: wm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!shellRoot || netRow.modelData.active || netRow.joining) return;
                        if (netRow.asking) shellRoot.wifiCancelDraft();
                        else shellRoot.wifiConnect(netRow.modelData.ssid, netRow.modelData.secure);
                    }
                }

                Sym {
                    id: sigIcon
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    text: netRow.joining ? (shellRoot ? shellRoot.wifiIcon : "wifi")
                        : netRow.modelData.signal > 66 ? "signal_wifi_4_bar" : netRow.modelData.signal > 33 ? "network_wifi_3_bar" : "network_wifi_1_bar"
                    sz: 16; color: netRow.modelData.active || netRow.joining ? Tok.accent : Tok.ink3
                }
                Row {
                    id: rightBits
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    spacing: 6
                    visible: !(netRow.saved && (wm.containsMouse || fgm.containsMouse))
                    IndChip { anchors.verticalCenter: parent.verticalCenter; visible: netRow.chipText !== ""; text: netRow.chipText; tone: netRow.chipTone }
                    IndText {
                        anchors.verticalCenter: parent.verticalCenter
                        mono: true; sz: 11; width: 18; horizontalAlignment: Text.AlignRight
                        text: netRow.modelData.signal
                        color: netRow.modelData.active ? Tok.ink : Tok.ink2
                    }
                }
                Text {
                    anchors { left: sigIcon.right; leftMargin: 8; right: rightBits.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    elide: Text.ElideRight; text: netRow.modelData.ssid
                    color: netRow.modelData.active ? Tok.ink : Tok.ink2
                    font.pixelSize: 12; font.family: Tok.sans; font.bold: netRow.modelData.active
                }
                Rectangle {
                    anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 6 }
                    width: 24; height: 24; radius: Tok.rSmall
                    visible: netRow.saved && (wm.containsMouse || fgm.containsMouse)
                    color: fgm.containsMouse ? Tok.critWash : "transparent"
                    Sym { anchors.centerIn: parent; text: "delete"; sz: 14; color: fgm.containsMouse ? Tok.crit : Tok.ink3 }
                    MouseArea { id: fgm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: if (shellRoot) shellRoot.wifiForget(netRow.modelData.ssid) }
                }
            }
        }
    }

    Text {
        visible: !!(shellRoot && shellRoot.wifiList.length === 0)
        text: (shellRoot && shellRoot.wifiScanning) ? "scanning…" : "No networks in range"
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; topPadding: 4
    }
    Rectangle {
        visible: !!(shellRoot && shellRoot.wifiList.length > 4)
        width: parent.width; height: 28; radius: Tok.rSmall
        color: moreWifi.containsMouse ? Tok.alpha(Tok.ink, 0.08) : "transparent"
        Text { anchors.centerIn: parent; text: wf.expanded ? "Show fewer networks" : "Other networks…"; color: Tok.ink2; font.family: Tok.sans; font.pixelSize: 12 }
        MouseArea { id: moreWifi; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: wf.expanded = !wf.expanded }
    }
    Text {
        visible: !!(wf.expanded && shellRoot && shellRoot.wifiSeen > shellRoot.wifiList.length)
        text: shellRoot ? ("+" + (shellRoot.wifiSeen - shellRoot.wifiList.length) + " more nearby") : ""
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans
    }

    // ---- VPN Section ----
    Item { height: 2; width: 1 }
    Rectangle { width: parent.width; height: 1; color: Tok.rule }
    Item { height: 4; width: 1 }

    Item {
        width: parent.width; height: 30
        Row {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left }
            spacing: 7
            Sym { anchors.verticalCenter: parent.verticalCenter; text: "security"; sz: 15; color: (shellRoot && shellRoot.warpConnected) ? Tok.ok : Tok.ink2 }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Cloudflare WARP"; color: (shellRoot && shellRoot.warpConnected) ? Tok.ink : Tok.ink2; font.pixelSize: 12; font.family: Tok.sans }
            Text { anchors.verticalCenter: parent.verticalCenter; visible: !!(shellRoot && shellRoot.warpConnected); text: shellRoot ? ("· " + shellRoot.warpMode) : ""; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
        }
        IndToggle {
            anchors { verticalCenter: parent.verticalCenter; right: parent.right }
            on: !!(shellRoot && shellRoot.warpConnected)
            onToggled: if (shellRoot) shellRoot.warpToggle()
        }
    }

    Row {
        visible: !!(shellRoot && shellRoot.warpConnected); spacing: 5; topPadding: 2
        Repeater {
            model: ["warp", "doh", "warp+doh", "tunnel_only"]
            delegate: Rectangle {
                required property var modelData
                readonly property bool cur: !!(shellRoot && shellRoot.warpMode === modelData)
                height: 20; radius: Tok.r; width: modeTxt.implicitWidth + 14
                color: cur ? Tok.alpha(Tok.ok, 0.2) : (modeMa.containsMouse ? Tok.raised : Tok.surface)
                border.width: cur ? 1 : 0; border.color: Tok.alpha(Tok.ok, 0.45)
                Text { id: modeTxt; anchors.centerIn: parent; text: modelData; color: cur ? Tok.ok : Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; font.bold: cur }
                MouseArea { id: modeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (shellRoot) shellRoot.warpSetMode(modelData) }
            }
        }
    }

    Repeater {
        model: shellRoot ? shellRoot.vpnList : []
        delegate: Item {
            required property var modelData
            readonly property bool connecting: modelData.state === "activating" || (shellRoot && shellRoot.vpnActionName === modelData.name)
            readonly property bool failed: !!(shellRoot && shellRoot.vpnFailedName === modelData.name)
            width: parent.width; height: 34
            Column {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                spacing: 0
                Row {
                    spacing: 7
                    Sym { anchors.verticalCenter: parent.verticalCenter; text: "vpn_key"; sz: 14; color: modelData.active ? Tok.accent : (connecting ? Tok.ink2 : (failed ? Tok.crit : Tok.ink3)) }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.name; color: modelData.active ? Tok.ink : (failed ? Tok.crit : Tok.ink2); font.pixelSize: 11; font.family: Tok.sans; font.bold: modelData.active || connecting; elide: Text.ElideRight }
                }
                Text {
                    visible: connecting || failed || modelData.active
                    text: connecting ? "connecting…" : (failed ? "Connection failed" : "Connected")
                    color: connecting ? Tok.ink2 : (failed ? Tok.crit : Tok.ok)
                    font.pixelSize: 11; font.family: Tok.sans; leftPadding: 21
                }
            }
            IndToggle {
                anchors { verticalCenter: parent.verticalCenter; right: parent.right }
                on: !!modelData.active
                onToggled: if (shellRoot && !connecting) shellRoot.vpnToggle(modelData.name)
            }
        }
    }
}
