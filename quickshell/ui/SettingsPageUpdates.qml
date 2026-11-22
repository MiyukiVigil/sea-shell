// Settings → General → Software Update. Built on demand via PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 29
    visible: root.tab === 29
    Layout.fillWidth: true
    spacing: 14

    MacHeaderCard {
        icon: "system_update_alt"
        badgeColor: "#8E8E93"
        title: "Software Update"
        description: "Check for new sea-shell releases, review changes, and apply updates."
        note: "Currently installed: sea-shell v" + root.seaVersion
    }

    Section { title: "sea-shell updates"; icon: "cloud_download" }
    UpdatePanel {}
}
