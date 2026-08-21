//@ pragma UseQApplication
// sea-shell — the wallpaper picker, as a program.
//
// The picker itself is WallpaperPicker.qml and lives inside the bar now. The reason is one
// measurement: constructing QtMultimedia's MediaPlayer costs 642ms of one-time plugin
// initialisation PER PROCESS, and building a second player after that costs 0ms. So a picker
// that is spawned fresh every time can never open with a warm video decoder, no matter where
// the 642ms is deferred to — deferring only chooses who it interrupts.
//
// This wrapper stays for two reasons: `qs -p wallpaper.qml` still opens the picker on its own
// for development, and the SUPER+SHIFT+W bind falls back to it if the bar is not running.
import Quickshell
import QtQuick

ShellRoot {
    WallpaperPicker {
        id: picker
        // Not `showing: true` as an initial value: standalone, the only way out is the window
        // closing itself, and this has to be a CHANGE for that to be observable.
        Component.onCompleted: picker.showing = true
        onShowingChanged: if (!picker.showing) Qt.quit()
    }
}
