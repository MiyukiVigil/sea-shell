// sea-shell — the dashboard on its own, for when the shell is not running. Normally SUPER+D
// reaches the copy kept inside the shell (DashboardPanel.qml), which opens at once;
// sea-toggle.sh falls back to this file.
import Quickshell
import QtQuick

ShellRoot {
    DashboardPanel {
        Component.onCompleted: open()
        onClosed: Qt.quit()
    }
}
