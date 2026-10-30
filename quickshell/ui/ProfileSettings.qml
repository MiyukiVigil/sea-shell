import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as C
import Quickshell
import Quickshell.Io

ColumnLayout {
    id: panel
    property var profile: ({})
    property string message: ""
    signal browseRequested()
    function setAvatar(path) { picture.text = path }
    function draft() { return {name: name.text, avatar: picture.text, font: family.text, color: tint.text, glow: glow.checked, nameSize: size.value, clockSize: clockSize.value, clock24: clock24.checked, showDate: date.checked, showMedia: media.checked, showAvatar: avatar.checked} }
    spacing: 14
    Component.onCompleted: reader.running = true
    Process { id: reader; command: ["python3", Qt.resolvedUrl("sea-profile.py").toString().replace("file://", ""), "get"]
        stdout: StdioCollector { onStreamFinished: { try { var p=JSON.parse(text); panel.profile=p; name.text=p.name;picture.text=p.avatar;family.text=p.font;tint.text=p.color;glow.checked=p.glow;size.value=p.nameSize;clockSize.value=p.clockSize;clock24.checked=p.clock24;date.checked=p.showDate;media.checked=p.showMedia;avatar.checked=p.showAvatar } catch(e){} } }
    }
    Process { id: writer
        stdout: StdioCollector { onStreamFinished: panel.message=text.trim() }
        stderr: StdioCollector { onStreamFinished: panel.message=text.trim() }
    }
    component Label: Text {
        color: Tok.ink; font.family: Tok.sans; font.pixelSize: 12
    }
    component Choice: C.ComboBox {
        id: choice
        implicitHeight: 36
        font.family: Tok.sans; font.pixelSize: 12
        contentItem: Text {
            text: choice.displayText; color: Tok.ink; font: choice.font
            verticalAlignment: Text.AlignVCenter; leftPadding: 12; rightPadding: 30
            elide: Text.ElideRight
        }
        indicator: Text { x: parent.width - 25; anchors.verticalCenter: parent.verticalCenter; text: "⌄"; color: Tok.ink3; font.pixelSize: 17 }
        background: Rectangle { radius: 9; color: Tok.sunken; border.width: 1; border.color: choice.activeFocus ? Tok.accent : Tok.ruleHard }
        delegate: C.ItemDelegate {
            required property var modelData
            required property int index
            width: choice.width; height: 34
            contentItem: Text { text: modelData; color: Tok.ink; font: choice.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
            background: Rectangle { radius: 6; color: choice.highlightedIndex === index ? Tok.sunken : Tok.surface }
            highlighted: choice.highlightedIndex === index
        }
        popup: C.Popup {
            y: choice.height + 4; width: choice.width
            padding: 5
            implicitHeight: Math.min(270, contentItem.implicitHeight + 10)
            contentItem: ListView {
                clip: true; implicitHeight: contentHeight
                model: choice.popup.visible ? choice.delegateModel : null
                currentIndex: choice.highlightedIndex
                C.ScrollIndicator.vertical: C.ScrollIndicator {}
            }
            background: Rectangle { color: Tok.surface; radius: 10; border.width: 1; border.color: Tok.ruleHard }
        }
    }
    component Action: C.Button {
        id: button
        property bool primary: false
        implicitHeight: 36; leftPadding: 16; rightPadding: 16
        font.family: Tok.sans; font.pixelSize: 12
        contentItem: Text { text: button.text; font: button.font; color: button.primary ? Tok.accentInk : Tok.ink; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { radius: 9; color: button.primary ? Tok.accent : (button.hovered ? Tok.sunken : Tok.surface); border.width: button.primary ? 0 : 1; border.color: Tok.ruleHard }
        opacity: enabled ? 1 : 0.5
    }
    component Switch: C.AbstractButton {
        id: toggle
        checkable: true; implicitHeight: 32
        implicitWidth: switchLabel.implicitWidth + 58
        contentItem: Item {
            Text { id: switchLabel; text: toggle.text; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: 36; height: 20; radius: 10; color: toggle.checked ? Tok.accent : Tok.sunken
                border.width: 1; border.color: toggle.checked ? Tok.accent : Tok.ruleHard
                Rectangle { x: toggle.checked ? 18 : 3; y: 3; width: 14; height: 14; radius: 7; color: toggle.checked ? Tok.accentInk : Tok.ink3
                    Behavior on x { NumberAnimation { duration: Tok.reducedMotion ? 0 : 120 } }
                }
            }
        }
    }

    component Range: C.Slider {
        id: range
        implicitHeight: 32
        stepSize: 1
        background: Rectangle {
            x: range.leftPadding; y: (range.height - height) / 2
            width: range.availableWidth; height: 5; radius: 2.5; color: Tok.sunken
            Rectangle { width: range.visualPosition * parent.width; height: parent.height; radius: parent.radius; color: Tok.accent }
        }
        handle: Rectangle {
            x: range.leftPadding + range.visualPosition * (range.availableWidth - width)
            y: (range.height - height) / 2
            width: 16; height: 16; radius: 8
            color: Tok.accent; border.width: range.activeFocus ? 2 : 0; border.color: Tok.ink2
            scale: range.pressed ? 1.15 : 1
            Behavior on scale { NumberAnimation { duration: Tok.mFast } }
        }
    }
    component Field: C.TextField {
        implicitHeight: 38; color: Tok.ink; placeholderTextColor: Tok.ink3; font.family: Tok.sans; font.pixelSize: 13; leftPadding: 12
        selectByMouse: true
        background: Rectangle { radius: 10; color: Tok.surface; border.width: 1; border.color: parent.activeFocus ? Tok.accent : Tok.ruleHard }
    }
    ProfileCard { Layout.fillWidth: true; profile: panel.draft(); subtitle: "Preview · settings, power menu and lock screen" }
    Label { text: "Identity"; font.pixelSize: 15; font.weight: Font.DemiBold }
    Label { text: "Display name" }
    Field { id: name; Layout.fillWidth: true }
    Label { text: "Profile picture" }
    RowLayout { Layout.fillWidth: true
        Field { id: picture; Layout.fillWidth: true }
        Action { text: "Browse…"; onClicked: panel.browseRequested() }
    }
    RowLayout { Layout.fillWidth: true; spacing: 14
        ColumnLayout { Layout.fillWidth: true; Label { text: "Name font" } FontPicker { id: family; Layout.fillWidth: true } }
        ColumnLayout { Layout.preferredWidth: 160; Label { text: "Name color" } Field { id: tint; Layout.fillWidth: true; placeholderText: "#ffffff" } }
    }
    RowLayout { Layout.fillWidth: true; spacing: 16
        Label { text: "Name size"; Layout.preferredWidth: 84 }
        Range { id: size; from: 12; to: 40; stepSize: 1; Layout.preferredWidth: 180 }
        Label { text: Math.round(size.value); Layout.preferredWidth: 28 }
        Item { Layout.preferredWidth: 14 }
        Switch { id: glow; text: "Name glow" }
    }
    Label { text: "Lock screen"; font.pixelSize: 15; font.weight: Font.DemiBold }
    // The real lock screen, drawn small with sample notifications; Unlocking shows the state
    // a key press brings up. It follows the fields above before they are saved.
    property bool previewLogin: false
    FontLoader { id: rhPreview; source: "file:///usr/share/sddm/themes/sea-silent/fonts/redhat/RedHatDisplay-SemiBold.otf" }
    Rectangle {
        id: lockFrame
        Layout.fillWidth: true; Layout.preferredHeight: width * 9 / 16
        radius: 14; color: "#0a0d14"; clip: true
        visible: panel.lockCfg.engine !== "hyprlock"
        LockSurface {
            width: 1920; height: 1080
            scale: lockFrame.width / 1920; transformOrigin: Item.TopLeft
            preview: true
            profile: panel.draft()
            wallpaper: Quickshell.env("HOME") + "/.config/sea-shell/sea-lockwall.png"
            clockFont: panel.draft().font || Tok.sans
            clockWeight: Font.Normal
            textFont: rhPreview.status === FontLoader.Ready ? rhPreview.name : Tok.sans
            dateFormat: "dddd, MMMM dd, yyyy"
            state_: panel.previewLogin ? "login" : "idle"
            typed: panel.previewLogin ? 6 : 0
            notes: panel.lockCfg.notifications === "off" ? [] : panel.sampleNotes
            showContent: panel.lockCfg.notifications !== "names"
            battery: ({ pct: 76, charging: false })
        }
        Rectangle {
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
            width: stateT.implicitWidth + 22; height: 28; radius: 14; color: Qt.rgba(0, 0, 0, 0.55)
            Text { id: stateT; anchors.centerIn: parent; text: panel.previewLogin ? "Show the clock" : "Show unlocking"
                color: "white"; font.family: Tok.sans; font.pixelSize: 11 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: panel.previewLogin = !panel.previewLogin }
        }
    }
    readonly property var sampleNotes: [
        { appName: "Messages", appIcon: "internet-chat", summary: "Alex", body: "Are we still on for tonight? I can bring the cables.", time: "21:42", urgency: 1 },
        { appName: "Messages", appIcon: "internet-chat", summary: "Sam", body: "ok", time: "21:40", urgency: 1 },
        { appName: "Firefox", appIcon: "firefox", summary: "Download complete", body: "cachyos-desktop-linux.iso", time: "21:20", urgency: 1 } ]

    // lock.json: which lock runs and how much of a notification it shows
    property var lockCfg: ({})
    FileView { id: lockFile; path: Quickshell.env("HOME") + "/.config/sea-shell/lock.json"; watchChanges: true
        onLoaded: { try { panel.lockCfg = JSON.parse(text()) } catch (e) { panel.lockCfg = {} } }
        onLoadFailed: panel.lockCfg = {}
        onFileChanged: reload() }
    function setLock(k, v) {
        var c = Object.assign({}, panel.lockCfg); c[k] = v; panel.lockCfg = c;
        Quickshell.execDetached(["python3", "-c",
            "import sys,os,pathlib; p=pathlib.Path(os.path.expanduser('~/.config/sea-shell/lock.json')); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[1])",
            JSON.stringify(c)]);
    }
    RowLayout { Layout.fillWidth: true; spacing: 14
        ColumnLayout { Layout.fillWidth: true
            Label { text: "Lock screen" }
            Choice { Layout.fillWidth: true; model: ["sea-shell", "hyprlock (classic)"]
                currentIndex: panel.lockCfg.engine === "hyprlock" ? 1 : 0
                onActivated: i => panel.setLock("engine", i === 1 ? "hyprlock" : "sea") } }
        ColumnLayout { Layout.fillWidth: true
            visible: panel.lockCfg.engine !== "hyprlock"
            Label { text: "Notifications while locked" }
            Choice { Layout.fillWidth: true; model: ["Show what they say", "App names only", "Hide them"]
                currentIndex: panel.lockCfg.notifications === "names" ? 1 : panel.lockCfg.notifications === "off" ? 2 : 0
                onActivated: i => panel.setLock("notifications", ["full", "names", "off"][i]) } }
    }
    RowLayout { spacing: 24
        Switch { id: avatar; text: "Picture" }
        Switch { id: clock24; text: "24-hour clock" }
        Switch { id: date; text: "Date" }
        Switch { id: media; text: "Now playing" }
    }
    RowLayout { Layout.fillWidth: true; spacing: 16
        Label { text: "Clock size"; Layout.preferredWidth: 84 }
        Range { id: clockSize; from: 40; to: 120; stepSize: 1; Layout.preferredWidth: 240 }
        Label { text: Math.round(clockSize.value) }
    }
    RowLayout {
        Action { text: "Save profile"; primary: true; enabled: !writer.running
            onClicked: { writer.command=["python3",Qt.resolvedUrl("sea-profile.py").toString().replace("file://",""),"set",JSON.stringify(panel.draft())];writer.running=true }
        }
        Label { text: "Applies to the next lock screen. Your account name stays unchanged."; color: Tok.ink3; Layout.fillWidth: true; wrapMode: Text.WordWrap }
    }
    Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: panel.message }
}
