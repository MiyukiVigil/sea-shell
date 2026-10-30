import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as C
import Quickshell
import Quickshell.Io

ColumnLayout {
    id: panel
    property color ink: "#202020"
    property var values: ({})
    property string message: ""
    property bool authenticating: false
    property bool ready: false            // the saved values are on the form; changes after this are the user's
    property bool previewLive: true
    spacing: 10
    function choices() {
        return JSON.stringify({preset: presets.currentText, background: background.text, position: position.currentText,
            avatar: avatar.text, clock: clock.checked, animations: animations.checked, blur: blur.value})
    }
    // The preview inside the page: every change is staged (half a second after the last one)
    // and the frame below picks the new config up by itself.
    function restage() { if (panel.ready && panel.values.installed === true) stageDelay.restart() }
    Timer { id: stageDelay; interval: 500
        onTriggered: { stager.running = false; stager.command = ["python3", Qt.resolvedUrl("sea-sddm.py").toString().replace("file://", ""), "stage", panel.choices()]; stager.running = true } }
    Process {
        id: stager
        stdout: StdioCollector { onStreamFinished: { var d = text.trim(); if (d.length) preview.themeDir = d } }
        stderr: StdioCollector { onStreamFinished: { if (text.trim()) panel.message = text.trim() } }
    }
    function run(action) {
        worker.command = ["python3", Qt.resolvedUrl("sea-sddm.py").toString().replace("file://", ""), action, panel.choices()]
        panel.message = ""
        if (action === "apply") {
            panel.authenticating = true
            authenticationDelay.start()
        } else worker.running = true
    }
    // Unmap the settings layer before the desktop authentication window opens.
    Timer { id: authenticationDelay; interval: 100; onTriggered: worker.running = true }
    signal browseRequested()
    signal avatarBrowseRequested()
    function setAvatar(path) { avatar.text = path; panel.restage() }
    function setBackground(path) { background.text = path; panel.restage() }
    Component.onCompleted: reader.running = true
    Process {
        id: reader
        command: ["python3", Qt.resolvedUrl("sea-sddm.py").toString().replace("file://", ""), "get"]
        stdout: StdioCollector { onStreamFinished: {
            try { panel.values = JSON.parse(text); presets.model = panel.values.presets || [];
                presets.currentIndex = Math.max(0, presets.find(panel.values.preset));
                background.text = panel.values.background || "";
                avatar.text = panel.values.avatar || "";
                position.currentIndex = Math.max(0, position.find(panel.values.position));
                clock.checked = panel.values.clock; animations.checked = panel.values.animations; blur.value = panel.values.blur;
                if (!panel.ready) { panel.ready = true; stageDelay.interval = 0; panel.restage(); stageDelay.interval = 500 }
            } catch(e) { panel.message = "Could not read login screen settings." }
        } }
    }
    Process {
        id: worker
        stdout: StdioCollector { onStreamFinished: { if (text.trim()) panel.message = text.trim() } }
        stderr: StdioCollector { onStreamFinished: { if (text.trim()) panel.message = text.trim() } }
        onExited: function(code) { panel.authenticating = false; if (code === 0) reader.running = true; if (code !== 0 && !panel.message) panel.message = "Action did not complete." }
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
    Rectangle {
        // Flat: the settings page already puts this on its section's panel.
        Layout.fillWidth: true; implicitHeight: form.implicitHeight + 4
        color: "transparent"
        ColumnLayout {
            id: form
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 2 }
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                ColumnLayout { Layout.fillWidth: true; spacing: 3
                    Label { text: "SilentSDDM"; font.pixelSize: 15; font.weight: Font.DemiBold }
                    Label { text: "A new look for your next login"; color: Tok.ink3 }
                }
                Label { text: "LOGIN THEME"; color: Tok.ink3; font.pixelSize: 10; font.letterSpacing: 1 }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 16
                ColumnLayout { Layout.fillWidth: true; spacing: 6
                    Label { text: "Preset" }
                    Choice { id: presets; Layout.fillWidth: true; onCurrentTextChanged: panel.restage() }
                }
                ColumnLayout { Layout.fillWidth: true; spacing: 6
                    Label { text: "Login position" }
                    Choice { id: position; model: ["left", "center", "right"]; Layout.fillWidth: true; onCurrentTextChanged: panel.restage() }
                }
            }
            ColumnLayout { Layout.fillWidth: true; spacing: 6
                Label { text: "Background" }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                C.TextField {
                    id: background; Layout.fillWidth: true; implicitHeight: 36
                    onEditingFinished: panel.restage()
                    placeholderText: "Image or video path · leave empty to use the preset"
                    selectByMouse: true; color: Tok.ink; placeholderTextColor: Tok.ink3
                    font.family: Tok.sans; font.pixelSize: 12; leftPadding: 12; rightPadding: 12
                    background: Rectangle { radius: 9; color: Tok.sunken; border.width: 1; border.color: background.activeFocus ? Tok.accent : Tok.ruleHard }
                }
                Action { text: "Browse…"; onClicked: panel.browseRequested() }
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Label { text: "User picture" }
                C.TextField {
                    id: avatar; Layout.fillWidth: true; implicitHeight: 36
                    onEditingFinished: panel.restage()
                    placeholderText: "Choose your login avatar"; selectByMouse: true
                    color: Tok.ink; placeholderTextColor: Tok.ink3; font.family: Tok.sans; font.pixelSize: 12; leftPadding: 12
                    background: Rectangle { radius: 9; color: Tok.sunken; border.width: 1; border.color: Tok.ruleHard }
                }
                Action { text: "Browse…"; onClicked: panel.avatarBrowseRequested() }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 24
                Switch { id: clock; text: "Clock"; onToggled: panel.restage() }
                Switch { id: animations; text: "Animations"; onToggled: panel.restage() }
                Item { Layout.fillWidth: true }
                Label { text: "Blur" }
                C.Slider {
                    id: blur; from: 0; to: 100; stepSize: 1; Layout.preferredWidth: 120
                    onMoved: panel.restage()
                    background: Rectangle { x: blur.leftPadding; y: (blur.height-height)/2; width: blur.availableWidth; height: 4; radius: 2; color: Tok.sunken
                        Rectangle { width: blur.visualPosition * parent.width; height: parent.height; radius: 2; color: Tok.accent }
                    }
                    handle: Rectangle { x: blur.leftPadding + blur.visualPosition * (blur.availableWidth-width); y: (blur.height-height)/2; width: 14; height: 14; radius: 7; color: Tok.accent }
                }
                Label { text: Math.round(blur.value); Layout.preferredWidth: 24 }
            }
            // ---- the login screen itself, live ----
            RowLayout {
                Layout.fillWidth: true; Layout.topMargin: 4; spacing: 6
                visible: panel.values.installed === true
                Label { text: "Preview"; font.weight: Font.DemiBold; Layout.fillWidth: true }
                Repeater {
                    model: [{ l: "Lock screen", login: false }, { l: "Login", login: true }]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: preview.showLogin === modelData.login
                        implicitHeight: 26; implicitWidth: segT.implicitWidth + 22; radius: 13
                        color: on ? Tok.accent : (segMa.containsMouse ? Tok.sunken : "transparent")
                        border.width: on ? 0 : 1; border.color: Tok.ruleHard
                        Text { id: segT; anchors.centerIn: parent; text: modelData.l; color: on ? Tok.accentInk : Tok.ink2; font.family: Tok.sans; font.pixelSize: 11 }
                        MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: preview.showLogin = modelData.login }
                    }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                visible: panel.values.installed === true
                implicitHeight: preview.implicitHeight + 2
                radius: 12; color: "transparent"; border.width: 1; border.color: Tok.ruleHard
                SddmPreview {
                    id: preview
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
                    userName: Quickshell.env("USER") || ""
                    avatar: avatar.text
                    live: panel.previewLive
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Tok.ruleHard }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Label { text: "The preview follows your changes. Apply requires authentication."; color: Tok.ink3; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                Action { text: "Download theme"; visible: panel.values.installed !== true; enabled: !worker.running; onClicked: panel.run("setup") }
                Action { text: "Open full screen"; enabled: !worker.running && panel.values.installed === true; onClicked: panel.run("preview") }
                Action { text: "Apply theme"; primary: true; enabled: !worker.running && panel.values.installed === true; onClicked: panel.run("apply") }
            }
            Label { Layout.fillWidth: true; visible: worker.running || panel.message.length > 0; wrapMode: Text.WordWrap; text: worker.running ? "Working…" : panel.message }
        }
    }
}
