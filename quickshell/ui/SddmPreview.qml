import QtQuick
import QtQuick.Effects
import Quickshell.Io

// Lightweight in-settings preview of SilentSDDM.
//
// Loading SilentSDDM's Main.qml directly inside `qs` pulled QtMultimedia (FFmpeg + VAAPI +
// NVIDIA CUDA + /dev/nvidia0) and all 10 QtQuick.VirtualKeyboard IME plugins into the bar
// process permanently (~80-120 MB RSS that Linux/Qt never unloads after Settings closes).
// Instead, this reads the staged configs/sea-shell.conf directly and renders the background
// (or video poster), blur, clock, login position and avatar using pure QtQuick. The
// "Open full screen" button in SddmSettings still launches the real sddm-greeter-qt6 in its
// own isolated process whenever you want to test live video/greeter behavior.
Item {
    id: frame
    property string themeDir: ""          // the staged copy; empty until the first stage lands
    property string userName: ""
    property string avatar: ""
    property bool showLogin: false        // lock screen vs login screen
    property bool live: true
    readonly property real sw: 1920
    readonly property real sh: 1080
    implicitHeight: width * sh / sw
    clip: true

    property var cfg: ({})
    function parseConf(text) {
        var o = {}, section = "General";
        var lines = (text || "").split(/\r?\n/);
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim();
            if (!l.length || l[0] === ";" || l[0] === "#") continue;
            if (l[0] === "[") {
                var end = l.indexOf("]");
                if (end > 1) section = l.slice(1, end);
                continue;
            }
            var eq = l.indexOf("=");
            if (eq < 0) continue;
            var k = l.slice(0, eq).trim(), v = l.slice(eq + 1).trim();
            if (v.length > 1 && v[0] === "\"" && v[v.length - 1] === "\"") v = v.slice(1, -1);
            o[section === "General" ? k : section + "/" + k] = v;
        }
        return o;
    }

    FileView {
        id: confFile
        path: (frame.live && frame.themeDir.length > 0) ? frame.themeDir + "/configs/sea-shell.conf" : ""
        watchChanges: true
        printErrors: false
        onLoaded: frame.cfg = frame.parseConf(text())
        onFileChanged: reload()
    }

    readonly property string section: frame.showLogin ? "LoginScreen" : "LockScreen"
    readonly property string rawBg: "" + (frame.cfg[frame.section + "/background"] || frame.cfg["LoginScreen/background"] || "")
    readonly property bool isVideoBg: /\.(mp4|webm|mkv|mov|gif)$/i.test(frame.rawBg)
    readonly property string bgFile: {
        if (!frame.themeDir || frame.cfg[frame.section + "/use-background-color"] === "true") return "";
        var f = frame.isVideoBg ? (frame.cfg["General/animated-background-placeholder"] || frame.cfg["animated-background-placeholder"] || "") : frame.rawBg;
        if (!f) return "";
        return f.indexOf("/") === 0 ? f : frame.themeDir + "/backgrounds/" + f;
    }
    readonly property string bgColor: "" + (frame.cfg[frame.section + "/background-color"] || "#101218")
    readonly property int blurVal: {
        var n = parseInt(frame.cfg[frame.section + "/blur"] || frame.cfg["LoginScreen/blur"] || "0");
        return isNaN(n) ? 0 : Math.max(0, Math.min(100, n));
    }
    readonly property bool showClock: (frame.cfg["LockScreen.Clock/display"] || "true") !== "false"
    readonly property string loginPos: {
        var p = "" + (frame.cfg["LoginScreen.LoginArea/position"] || "center");
        return (p === "left" || p === "right") ? p : "center";
    }
    readonly property string avatarFile: {
        if (frame.avatar && frame.avatar.length > 0) return frame.avatar;
        return frame.themeDir ? frame.themeDir + "/sea-avatar.icon" : "";
    }
    readonly property real k: frame.width > 0 ? frame.width / frame.sw : 0.3

    // Background color fallback
    Rectangle {
        anchors.fill: parent
        color: frame.bgColor
    }

    // Static background image (or extracted video poster), decoded at preview resolution only
    Image {
        id: bgImg
        anchors.fill: parent
        visible: status === Image.Ready && frame.blurVal <= 0
        source: (frame.live && frame.bgFile) ? Tok.fileUrl(frame.bgFile) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: Math.max(640, Math.round(frame.width * 1.5))
    }

    MultiEffect {
        anchors.fill: parent
        source: bgImg
        visible: frame.live && bgImg.status === Image.Ready && frame.blurVal > 0
        blurEnabled: true
        blur: Math.min(1.0, frame.blurVal / 100.0)
        blurMax: 48
    }

    // Subtle legibility scrim
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, frame.showLogin ? 0.28 : 0.18)
    }

    // ---- Lock screen preview ----
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * 0.16
        spacing: Math.max(2, 8 * frame.k)
        visible: frame.live && !frame.showLogin && frame.showClock

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(new Date(), "HH:mm")
            color: "#f5f7fa"
            font.family: Tok.sans
            font.pixelSize: Math.max(22, Math.round(136 * frame.k))
            font.weight: Font.DemiBold
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(new Date(), "dddd, d MMMM")
            color: Qt.rgba(1, 1, 1, 0.82)
            font.family: Tok.sans
            font.pixelSize: Math.max(9, Math.round(28 * frame.k))
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: parent.height * 0.09
        visible: frame.live && !frame.showLogin
        text: "Press any key to unlock"
        color: Qt.rgba(1, 1, 1, 0.72)
        font.family: Tok.sans
        font.pixelSize: Math.max(8, Math.round(22 * frame.k))
    }

    // ---- Login screen preview ----
    Item {
        id: loginCard
        visible: frame.live && frame.showLogin
        width: Math.max(120, Math.round(360 * frame.k))
        height: loginCol.implicitHeight
        anchors.verticalCenter: parent.verticalCenter
        x: frame.loginPos === "left" ? Math.round(parent.width * 0.12)
         : frame.loginPos === "right" ? Math.round(parent.width * 0.88 - width)
         : Math.round((parent.width - width) / 2)
        Behavior on x { NumberAnimation { duration: Tok.reducedMotion ? 0 : 180; easing.type: Easing.OutCubic } }

        Column {
            id: loginCol
            width: parent.width
            spacing: Math.max(6, Math.round(18 * frame.k))

            // Avatar circle
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(36, Math.round(112 * frame.k))
                height: width
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Qt.rgba(1, 1, 1, 0.16)
                    border.width: Math.max(1, Math.round(2 * frame.k))
                    border.color: Qt.rgba(1, 1, 1, 0.35)
                    Text {
                        anchors.centerIn: parent
                        visible: avatarImg.status !== Image.Ready
                        text: (frame.userName || "U").charAt(0).toUpperCase()
                        color: "white"
                        font.family: Tok.sans
                        font.pixelSize: Math.max(14, Math.round(42 * frame.k))
                        font.weight: Font.DemiBold
                    }
                }
                Image {
                    id: avatarImg
                    anchors.fill: parent
                    visible: false
                    source: (frame.live && frame.avatarFile) ? Tok.fileUrl(frame.avatarFile) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    sourceSize.width: 160
                    sourceSize.height: 160
                }
                Rectangle {
                    id: avatarMask
                    anchors.fill: parent
                    radius: width / 2
                    visible: false
                    layer.enabled: avatarImg.status === Image.Ready
                }
                MultiEffect {
                    anchors.fill: parent
                    source: avatarImg
                    visible: avatarImg.status === Image.Ready
                    maskEnabled: true
                    maskSource: avatarMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: frame.userName || "user"
                color: "#f5f7fa"
                font.family: Tok.sans
                font.pixelSize: Math.max(10, Math.round(30 * frame.k))
                font.weight: Font.DemiBold
            }

            // Password field placeholder
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width * 0.85
                height: Math.max(18, Math.round(48 * frame.k))
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.16)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.28)
                Row {
                    anchors.centerIn: parent
                    spacing: Math.max(3, Math.round(8 * frame.k))
                    Repeater {
                        model: 8
                        Rectangle {
                            width: Math.max(3, Math.round(8 * frame.k))
                            height: width
                            radius: width / 2
                            color: Qt.rgba(1, 1, 1, 0.85)
                        }
                    }
                }
            }
        }
    }

    // Bottom session badge + video note
    Row {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Math.max(6, Math.round(22 * frame.k))
        spacing: Math.max(4, Math.round(10 * frame.k))
        visible: frame.live && frame.themeDir.length > 0
        Rectangle {
            radius: 6
            color: Qt.rgba(0, 0, 0, 0.42)
            width: sessTxt.implicitWidth + 12
            height: sessTxt.implicitHeight + 6
            Text {
                id: sessTxt
                anchors.centerIn: parent
                text: "Hyprland"
                color: Qt.rgba(1, 1, 1, 0.85)
                font.family: Tok.sans
                font.pixelSize: Math.max(9, Math.round(18 * frame.k))
            }
        }
    }

    Rectangle {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Math.max(6, Math.round(18 * frame.k))
        visible: frame.live && frame.isVideoBg
        radius: 6
        color: Qt.rgba(0, 0, 0, 0.55)
        width: vidNote.implicitWidth + 12
        height: vidNote.implicitHeight + 6
        Text {
            id: vidNote
            anchors.centerIn: parent
            text: "Video poster · Open full screen for live greeter"
            color: Qt.rgba(1, 1, 1, 0.85)
            font.family: Tok.sans
            font.pixelSize: 10
        }
    }

    Text {
        anchors.centerIn: parent
        visible: frame.live && frame.themeDir.length === 0
        text: "Preparing the preview…"
        color: "#cfcfcf"
        font.family: Tok.sans
        font.pixelSize: 12
    }
}
