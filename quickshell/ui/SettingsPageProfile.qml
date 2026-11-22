// Settings → Profile. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 23
    visible: root.tab === 23; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "account_circle"
        badgeColor: "#007AFF"
        title: "Your Profile"
        description: "Your avatar picture and display name shown across Settings, the power menu, and the lock screen."
    }

    Section { title: "Your profile"; icon: "account_circle" }
    ProfileSettings { id: userProfileEditor; Layout.fillWidth: true; part: "identity"
        onSaved: { if (root.lockEditor) root.lockEditor.reload() }
        Component.onCompleted: root.userEditor = userProfileEditor
        onBrowseRequested: root.pickFile("Choose profile picture", "*.png *.jpg *.jpeg *.webp", function(path) { userProfileEditor.setAvatar(path) })
    }
}
