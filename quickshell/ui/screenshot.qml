//@ pragma UseQApplication
// sea-shell — screenshot picker, standalone. The shell keeps ScreenshotPanel loaded and Print
// opens that one (sea-toggle.sh screenshot → the "screenshot" IPC); this runs the same panel on
// its own only when the shell is down.
import Quickshell
import QtQuick
ShellRoot { ScreenshotPanel { Component.onCompleted: open(); onClosed: Qt.quit() } }
