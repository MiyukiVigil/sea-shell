import QtQuick

// The real login theme, drawn inside settings instead of in sddm-greeter's own window.
//
// sea-sddm.py `stage` builds a copy of the theme whose Config reads configs/sea-shell.conf
// directly (and watches it), so every change made on the page reaches this frame with no
// reload. What the greeter would otherwise hand the theme, the user list, sessions, keyboard
// layouts and the screen, is stood in for below by objects with the same names: a theme file
// loaded here looks names up through this file, as it would through the greeter's context.
// Nothing here logs anyone in; the frame takes no input.
Item {
    id: frame
    property string themeDir: ""          // the staged copy; empty until the first stage lands
    property string userName: ""
    property string avatar: ""
    property bool showLogin: false        // the theme opens on its lock screen; this skips to login
    // ONLY WHILE SEEN. The theme plays a video, and the settings window is unmapped every time it
    // closes and made again when it opens: a loaded theme then straddled the old window and the
    // new one, and the next open crashed the whole shell in the scene graph. So it is unloaded
    // whenever it is out of sight, which also stops the video costing anything meanwhile.
    property bool live: true
    readonly property real sw: 1920
    readonly property real sh: 1080
    implicitHeight: width * sh / sw
    clip: true

    QtObject {
        id: sddm
        property string hostName: "sea-shell"
        property string currentUser: frame.userName
        property bool canPowerOff: true
        property bool canReboot: true
        property bool canSuspend: true
        property bool canHibernate: false
        property bool canHybridSleep: false
        signal loginSucceeded()
        signal loginFailed()
        signal informationMessage(string message)
        function login(user, password, session) {}
        function powerOff() {}
        function reboot() {}
        function suspend() {}
        function hibernate() {}
    }
    // SDDM's roles, by number, as the theme asks for them.
    ListModel {
        id: userModel
        property int lastIndex: 0
        property string lastUser: frame.userName
        property bool disableAvatarsThreshold: false
        function rowCount() { return count }
        function index(row, column) { return row }
        function data(i, role) {
            var e = get(i);
            if (!e) return undefined;
            return role === 257 ? e.name : role === 258 ? e.realName : role === 259 ? e.homeDir
                 : role === 260 ? e.icon : role === 261 ? e.needsPassword : undefined;
        }
        function reset() {}
    }
    ListModel {
        id: sessionModel
        property int lastIndex: 0
        function rowCount() { return count }
        function index(row, column) { return row }
        function data(i, role) { var e = get(i); return e && role === 260 ? e.name : (e ? e.file : undefined) }
    }
    QtObject {
        id: keyboard
        // objects, not plain records: the theme indexes the list and also uses it as a model
        // whose delegates read shortName and longName as roles
        property list<QtObject> layouts: [ QtObject { property string shortName: "us"; property string longName: "English (US)" } ]
        property int currentLayout: 0
        property bool capsLock: false
        property bool numLock: false
        property var svg: null
    }
    QtObject {
        id: screenModel
        property int primary: 0
        function geometry(i) { return Qt.rect(0, 0, frame.sw, frame.sh) }
    }
    function fill() {
        userModel.clear();
        userModel.append({ name: frame.userName, realName: frame.userName, homeDir: "",
                           icon: frame.avatar ? "file://" + frame.avatar : "", needsPassword: true });
        sessionModel.clear();
        sessionModel.append({ name: "Hyprland", file: "hyprland.desktop" });
    }
    onUserNameChanged: fill()
    onAvatarChanged: fill()
    Component.onCompleted: fill()

    Rectangle { anchors.fill: parent; color: "#000" }
    Loader {
        id: theme
        width: frame.sw; height: frame.sh
        scale: frame.width / frame.sw
        transformOrigin: Item.TopLeft
        enabled: false
        asynchronous: true
        active: frame.live && frame.themeDir.length > 0
        source: frame.themeDir ? "file://" + frame.themeDir + "/Main.qml" : ""
        onLoaded: if (frame.showLogin && item) item.state = "loginState"
    }
    onShowLoginChanged: if (theme.item) theme.item.state = showLogin ? "loginState" : "lockState"
    Text {
        anchors.centerIn: parent
        visible: theme.status !== Loader.Ready && frame.live
        text: theme.status === Loader.Error ? "The theme could not be drawn here. Use Open full screen."
            : frame.themeDir ? "Drawing the login screen…" : "Preparing the preview…"
        color: "#cfcfcf"; font.family: Tok.sans; font.pixelSize: 12
    }
}
