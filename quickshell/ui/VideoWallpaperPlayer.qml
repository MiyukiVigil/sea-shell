// sea-shell — the moving part of the video wallpaper, without the layer-shell window around it
// (VideoWallpaper.qml), so it loads anywhere QtQuick does.
//
// The player lives in a Loader so FREEZE can drop it outright: a paused decoder still holds
// its frames and its VRAM, and the reason to freeze is that a game wants them.
import QtQuick
import QtMultimedia

Item {
    id: root

    property string source: ""       // the clip to play
    property string mode: "off"      // off | play | pause | freeze — see WallpaperState.js
    signal ready()

    readonly property bool loaded: vidLoad.item !== null
    readonly property bool frameShown: vidLoad.item ? vidLoad.item.out.opacity > 0.99 : false
    readonly property int playbackState: vidLoad.item ? vidLoad.item.player.playbackState : MediaPlayer.StoppedState

    Loader {
        id: vidLoad
        anchors.fill: parent
        active: (root.mode === "play" || root.mode === "pause") && root.source !== ""
        sourceComponent: Item {
            id: slot
            property alias player: mp
            property alias out: vo
            property bool waiting: true
            MediaPlayer {
                id: mp
                videoOutput: vo
                loops: MediaPlayer.Infinite
                // No audioOutput: leaving it unset is how Qt is told not to open an audio device.
                source: root.fileUrl(root.source)
                onSourceChanged: { vo.opacity = 0; slot.waiting = true; root.apply(mp) }
                onErrorOccurred: (error, msg) => console.warn("sea-shell wallpaper: " + msg)
            }
            VideoOutput {
                id: vo
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
                opacity: 0
                Behavior on opacity { NumberAnimation { duration: 260 } }
            }
            // The first decoded frame, not PlayingState: the state flips before anything is on
            // the surface, and fading in then shows a frame of black over the poster.
            Connections {
                target: vo.videoSink
                enabled: slot.waiting
                function onVideoFrameChanged() {
                    slot.waiting = false;
                    vo.opacity = 1;
                    root.ready();
                }
            }
            // vidLoad.item is still null here, so sync() would find nothing to start.
            Component.onCompleted: root.apply(mp)
        }
    }

    // Tok.fileUrl, kept local: Tok is only a singleton under Quickshell, and this component
    // also has to load under plain QtQuick (tests/test_video_wallpaper.py).
    function fileUrl(p) {
        if (!p || !("" + p).length) return "";
        return "file://" + ("" + p).split("/").map(encodeURIComponent).join("/");
    }

    function apply(p) {
        if (root.mode === "play") p.play();
        else if (root.mode === "pause") p.pause();
    }
    function sync() { if (vidLoad.item) root.apply(vidLoad.item.player) }
    onModeChanged: sync()
}
