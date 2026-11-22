// sea-shell — the video wallpaper, drawn by the bar itself.
//
// One surface per monitor on the BACKGROUND layer, shown only while the wallpaper is a clip;
// for a still it unmaps and awww's surface underneath is the wallpaper. awww also holds the
// clip's poster, so a bar restart drops to that still frame rather than to black.
//
// SAME LAYER AS AWWW, AND HYPRLAND STACKS A LAYER BY MAP ORDER: whichever surface mapped
// last is on top. remap() unmaps and maps this one again, which is how it gets back above
// an awww-daemon that (re)started after it — sea-wallpaper-apply.sh asks for it over IPC
// every time it seeds a poster.
import Quickshell
import Quickshell.Wayland
import QtQuick

PanelWindow {
    id: root

    property string source: ""       // the clip to play (already the optimized copy when ready)
    property string poster: ""       // full-resolution still of the same clip
    property string mode: "off"      // off | play | pause | freeze — see WallpaperState.js
    property bool mapped: true
    signal ready()

    readonly property bool frameShown: player.frameShown

    visible: root.mode !== "off" && root.mapped
    color: "transparent"
    WlrLayershell.namespace: "sea-shell:wallpaper"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; left: true; right: true; bottom: true }
    mask: Region {}

    function remap() {
        if (root.mode === "off") return;
        root.mapped = false;
        Qt.callLater(function () { root.mapped = true });
    }

    Image {
        anchors.fill: parent
        source: Tok.fileUrl(root.poster)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: root.width
        sourceSize.height: root.height
    }

    VideoWallpaperPlayer {
        id: player
        anchors.fill: parent
        source: root.source
        mode: root.mode
        onReady: root.ready()
    }
}
