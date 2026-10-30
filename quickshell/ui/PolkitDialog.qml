import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Polkit

// The password prompt for system actions (pkexec, package managers, mounting…), drawn by the
// shell instead of hyprpolkitagent so it looks like the lock screen it sits next to: you, the
// request in full, the same dot field that shakes on a wrong try. shell.qml owns the agent
// and hands its current flow in; this only draws it and answers it.
Scope {
    id: dlg
    property var flow: null                 // the agent's AuthFlow, null when nothing is asked
    property var profile: ({})
    readonly property bool asking: !!dlg.flow && !dlg.flow.isCompleted
    property int fails: 0
    property bool busy: false               // submitted, waiting for polkit's answer
    property bool details: false
    // on the screen you are looking at, chosen when the prompt arrives so it never jumps
    property var onScreen: null
    onFlowChanged: {
        dlg.fails = 0; dlg.busy = false; dlg.details = false; field.text = "";
        var fm = Hyprland.focusedMonitor, ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++) if (fm && ss[i].name === fm.name) { dlg.onScreen = ss[i]; return }
        dlg.onScreen = ss.length ? ss[0] : null;
    }

    Connections {
        target: dlg.flow
        ignoreUnknownSignals: true
        function onAuthenticationFailed() { dlg.busy = false; dlg.fails++; field.text = ""; if (!Tok.reducedMotion) shake.restart() }
        function onAuthenticationSucceeded() { dlg.busy = false }
        function onIsResponseRequiredChanged() { if (dlg.flow && dlg.flow.isResponseRequired) dlg.busy = false }
    }
    function submit() {
        if (!dlg.flow || dlg.busy || field.text === "") return;
        dlg.busy = true;
        dlg.flow.submit(field.text);
    }
    function cancel() { if (dlg.flow) dlg.flow.cancelAuthenticationRequest() }

    // pkexec's message names the program in a sentence; pulled out, it can be shown whole in
    // mono instead of truncated mid-path
    readonly property string program: {
        var m = dlg.flow ? ("" + dlg.flow.message).match(/run [`'"]?(\/[^`'"\s]+)[`'"]?/) : null;
        return m ? m[1] : "";
    }
    readonly property string who: {
        var id = dlg.flow ? dlg.flow.selectedIdentity : null;
        if (!id) return Quickshell.env("USER") || "";
        return "" + (id.displayName || id.name || id.toString());
    }
    readonly property bool asRoot: dlg.who === "root"

    PanelWindow {
        id: win
        visible: dlg.asking || stage.opacity > 0
        screen: dlg.onScreen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:polkit"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: dlg.asking ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        Item {
            id: stage
            anchors.fill: parent
            opacity: dlg.asking ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tok.reducedMotion ? 0 : 140; easing.type: Easing.OutCubic } }

            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55)
                MouseArea { anchors.fill: parent } }      // a click outside does not cancel by accident

            Rectangle {
                id: card
                anchors.centerIn: parent
                anchors.verticalCenterOffset: dlg.asking ? 0 : 12
                Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: Tok.reducedMotion ? 0 : 180; easing.type: Easing.OutCubic } }
                width: 440; height: body.implicitHeight + 48
                radius: 24; color: Tok.bg; border.width: 1; border.color: Tok.ruleHard

                Column {
                    id: body
                    x: 24; y: 24; width: parent.width - 48
                    spacing: 16

                    // who is being asked for: your face, or a shield when it is another account
                    Row {
                        spacing: 14
                        Rectangle {
                            width: 52; height: 52; radius: 26; color: Tok.sunken
                            Text { anchors.centerIn: parent; text: dlg.asRoot ? "shield_person" : "person"
                                font.family: "Material Symbols Outlined"; font.pixelSize: 26; color: Tok.ink3 }
                            Image { id: faceImg; anchors.fill: parent; visible: false
                                source: !dlg.asRoot && dlg.profile.avatar ? "file://" + dlg.profile.avatar : ""
                                fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 128 }
                            MultiEffect { anchors.fill: parent; source: faceImg; visible: faceImg.status === Image.Ready
                                maskEnabled: true; maskSource: faceMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                            Rectangle { id: faceMask; anchors.fill: parent; radius: 26; visible: false; layer.enabled: true }
                            // the small lock badge says what kind of prompt this is
                            Rectangle { anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: -3
                                width: 22; height: 22; radius: 11; color: Tok.accent; border.width: 2; border.color: Tok.bg
                                Text { anchors.centerIn: parent; text: "lock"; font.family: "Material Symbols Outlined"; font.pixelSize: 13; color: Tok.accentInk } }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Text { text: "Allow this change?"; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 17; font.weight: Font.DemiBold }
                            Text { text: "Enter the password for " + dlg.who; color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 12 }
                        }
                    }

                    Text {
                        width: parent.width
                        // with the program shown whole below, the sentence need not repeat it
                        text: !dlg.flow ? "" : dlg.program === "" ? dlg.flow.message
                            : /super ?user/i.test(dlg.flow.message) ? "This will run as the super user:" : "This will run:"
                        wrapMode: Text.Wrap; color: Tok.ink2; font.family: Tok.sans; font.pixelSize: 13; lineHeight: 1.15
                    }
                    // the program, whole, so you can see exactly what will run
                    Rectangle {
                        visible: dlg.program !== ""
                        width: parent.width; height: progT.implicitHeight + 18; radius: 12
                        color: Tok.sunken; border.width: 1; border.color: Tok.rule
                        Text {
                            id: progT
                            x: 12; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 24
                            text: "<span style='color:" + Tok.accent + "'>$</span> " + dlg.program
                            textFormat: Text.StyledText
                            wrapMode: Text.WrapAnywhere; color: Tok.ink; font.family: Tok.mono; font.pixelSize: 12
                        }
                    }

                    // the field: real text input (paste works), dots drawn by Qt
                    Item {
                        id: fieldBox
                        width: parent.width; height: 46
                        property real shakeX: 0
                        Rectangle {
                            x: fieldBox.shakeX; width: parent.width; height: parent.height; radius: 23
                            color: Tok.surface
                            border.width: field.activeFocus || dlg.fails > 0 ? 2 : 1
                            border.color: dlg.fails > 0 && field.text === "" ? Tok.crit : field.activeFocus ? Tok.accent : Tok.ruleHard
                            Behavior on border.color { ColorAnimation { duration: Tok.mFast } }
                            TextInput {
                                id: field
                                anchors.left: parent.left; anchors.leftMargin: 18
                                anchors.right: eye.left; anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                focus: dlg.asking
                                enabled: !dlg.busy
                                echoMode: dlg.flow && dlg.flow.responseVisible || eye.show ? TextInput.Normal : TextInput.Password
                                passwordCharacter: "•"
                                color: Tok.ink; font.family: Tok.sans; font.pixelSize: 15; font.letterSpacing: echoMode === TextInput.Password ? 2 : 0
                                selectionColor: Tok.accent; selectedTextColor: Tok.accentInk
                                clip: true
                                Keys.onReturnPressed: dlg.submit()
                                Keys.onEnterPressed: dlg.submit()
                                Keys.onEscapePressed: dlg.cancel()
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: field.text === ""
                                    text: dlg.busy ? "Checking…" : dlg.fails > 0 ? "Try again"
                                        : ((dlg.flow && dlg.flow.inputPrompt ? ("" + dlg.flow.inputPrompt).replace(/:\s*$/, "") : "Password"))
                                    color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 14
                                }
                            }
                            Text {
                                id: eye
                                property bool show: false
                                visible: !(dlg.flow && dlg.flow.responseVisible)
                                anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                text: show ? "visibility_off" : "visibility"
                                font.family: "Material Symbols Outlined"; font.pixelSize: 18; color: eyeMa.containsMouse ? Tok.ink : Tok.ink3
                                MouseArea { id: eyeMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: eye.show = !eye.show }
                            }
                        }
                        SequentialAnimation {
                            id: shake
                            NumberAnimation { target: fieldBox; property: "shakeX"; to: -12; duration: 50 }
                            NumberAnimation { target: fieldBox; property: "shakeX"; to: 10; duration: 70 }
                            NumberAnimation { target: fieldBox; property: "shakeX"; to: -6; duration: 60 }
                            NumberAnimation { target: fieldBox; property: "shakeX"; to: 0; duration: 50 }
                        }
                    }

                    // one line under the field: polkit's own words win, then the wrong-try count
                    Text {
                        width: parent.width
                        visible: text !== ""
                        wrapMode: Text.Wrap
                        text: dlg.flow && dlg.flow.supplementaryMessage ? dlg.flow.supplementaryMessage
                            : dlg.fails > 0 ? (dlg.fails === 1 ? "Wrong password" : "Wrong password · " + dlg.fails + " tries") : ""
                        color: (dlg.flow && dlg.flow.supplementaryMessage && !dlg.flow.supplementaryIsError) ? Tok.ink2 : Tok.crit
                        font.family: Tok.sans; font.pixelSize: 12
                    }

                    // details: what polkit calls this, for when you want to know before you allow it
                    Column {
                        width: parent.width; spacing: 6
                        visible: dlg.details
                        Repeater {
                            model: [ { k: "Action", v: dlg.flow ? dlg.flow.actionId : "" },
                                     { k: "As", v: dlg.who } ]
                            delegate: Row {
                                required property var modelData
                                spacing: 10
                                Text { width: 54; text: modelData.k; color: Tok.ink3; font.family: Tok.sans; font.pixelSize: 11 }
                                Text { width: body.width - 64; text: modelData.v; wrapMode: Text.WrapAnywhere; color: Tok.ink2; font.family: Tok.mono; font.pixelSize: 11 }
                            }
                        }
                    }

                    Item {
                        width: parent.width; height: 38
                        Text {
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            text: dlg.details ? "Hide details" : "Details"
                            color: detMa.containsMouse ? Tok.accent : Tok.ink3; font.family: Tok.sans; font.pixelSize: 12
                            MouseArea { id: detMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: dlg.details = !dlg.details }
                        }
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            Rectangle {
                                width: 96; height: 38; radius: 19
                                color: cMa.containsMouse ? Tok.sunken : Tok.surface; border.width: 1; border.color: Tok.ruleHard
                                Text { anchors.centerIn: parent; text: "Cancel"; color: Tok.ink; font.family: Tok.sans; font.pixelSize: 13 }
                                MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.cancel() }
                            }
                            Rectangle {
                                width: 112; height: 38; radius: 19
                                readonly property bool ready: field.text !== "" && !dlg.busy
                                color: ready ? (aMa.containsMouse ? Qt.lighter(Tok.accent, 1.08) : Tok.accent) : Tok.sunken
                                Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                Text { anchors.centerIn: parent; text: dlg.busy ? "Checking…" : "Allow"
                                    color: parent.ready ? Tok.accentInk : Tok.ink3; font.family: Tok.sans; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MouseArea { id: aMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.submit() }
                            }
                        }
                    }
                }
            }
        }
    }
}
