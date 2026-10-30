//@ pragma UseQApplication
// sea-shell — the power menu on its own, for when the shell is not running. Normally SUPER+ESC
// reaches the copy kept inside the shell (PowerMenu.qml), which opens at once; sea-toggle.sh
// falls back to this file.
import Quickshell
import QtQuick

ShellRoot {
    PowerMenu {
        Component.onCompleted: open()
        onClosed: Qt.quit()
    }
}
