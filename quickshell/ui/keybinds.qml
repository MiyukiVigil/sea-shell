//@ pragma UseQApplication
// sea-shell — keybind cheat-sheet + editor (SUPER+K). Reads live binds from
// `hyprctl binds` (descriptions come from the bindd lines in keybinds.conf).
// Type to search · click a bind to REBIND it: toggle modifier chips, press the
// new base key — sea-rebind.sh rewrites keybinds.conf (+ repo copy) and reloads.
// Esc / click-outside closes.
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    property var binds: []
    property string query: ""
    property var rec: null           // bind being rebound: {desc, key, keys, mods, ...}
    property var recMods: []         // modifier chips currently toggled on
    property string conflict: ""
    property string accent: "#63c7dd"
    property bool cfgLight: false
 
    // Add new bind state variables
    property bool adding: false
    property string addDesc: ""
    property string addAction: "exec, "
    property var addMods: ["SUPER"]
    property string addKey: ""
    property bool addRecording: false

    component Sym: Text { property int sz: 16; font.family: "Material Symbols Outlined"; font.pixelSize: sz }

    QtObject {
        id: theme
        readonly property bool light: root.cfgLight
        readonly property color _acc: root.accent
        readonly property real  _ah:  _acc.hslHue >= 0 ? _acc.hslHue : 0.55
        readonly property color bg:    light ? Qt.hsla(_ah, 0.20, 0.945, 1) : Qt.hsla(_ah, 0.36, 0.070, 1)
        readonly property color line:  light ? Qt.hsla(_ah, 0.16, 0.780, 1) : Qt.hsla(_ah, 0.24, 0.205, 1)
        readonly property color text:  light ? "#0c1520" : "#e2e9f4"
        readonly property color sub:   light ? "#2c4256" : "#a6b6cf"
        readonly property color faint: light ? "#48606f" : "#6f8099"
        readonly property color iris:  light ? Qt.darker(root.accent, 2.4)  : root.accent
        readonly property color frost: light ? Qt.darker(root.accent, 1.7) : Qt.lighter(root.accent, 1.22)
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // accent follows the bar's appearance config
    Process { running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector { id: apOut; onStreamFinished: { try { var j=JSON.parse(apOut.text); if(j.accent) root.accent=j.accent; if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light") } catch(e){} } } }

    function modStr(m) {
        var s = [];
        if (m & 64) s.push("SUPER");
        if (m & 4)  s.push("CTRL");
        if (m & 8)  s.push("ALT");
        if (m & 1)  s.push("SHIFT");
        return s;
    }
    function prettyKey(k) {
        if (k === "Return") return "⏎";
        if (k === "Escape") return "Esc";
        if (k === "grave") return "`";
        if (k === "Space" || k === "space") return "Space";
        if (/^mouse/.test(k)) return k.replace("mouse:","M");
        if (/^XF86/.test(k)) return k.replace("XF86","");
        return k.length === 1 ? k.toUpperCase() : k;
    }
    function label(d, a) {
        var map = {
            "exec":"run", "killactive":"close window", "fullscreen":"fullscreen",
            "togglefloating":"toggle float", "centerwindow":"center", "movefocus":"focus",
            "movewindow":"move window", "resizeactive":"resize", "workspace":"workspace",
            "movetoworkspace":"→ workspace", "togglespecialworkspace":"scratchpad",
            "togglesplit":"toggle split", "pseudo":"pseudo", "exit":"exit hyprland"
        };
        var base = map[d] || d;
        if (d === "exec") { var cmd = (a||"").split(" ")[0].split("/").pop(); return cmd || "run" }
        if (a && a.length && a.length < 14) return base + " " + a;
        return base;
    }

    Process {
        id: bindsProc; running: true
        command: ["sh","-c","hyprctl binds -j"]
        stdout: StdioCollector { id: bOut; onStreamFinished: {
            try {
                var arr = JSON.parse(bOut.text); var out = []; var seen = {};
                for (var i=0;i<arr.length;i++) {
                    var b = arr[i];
                    if (b.mouse) continue;
                    var mods = root.modStr(b.modmask);
                    var keys = mods.concat([root.prettyKey(b.key)]).join(" + ");
                    var hasDesc = !!(b.description && b.description.length);
                    var desc = hasDesc ? b.description : root.label(b.dispatcher, b.arg);
                    var sig = keys + "|" + desc;
                    if (seen[sig]) continue; seen[sig] = 1;
                    out.push({ keys: keys, desc: desc, arg: (b.arg||""), key: b.key, mods: mods, canEdit: hasDesc });
                }
                root.binds = out;
            } catch(e) {}
        } }
    }
    Timer { interval: 4000; running: root.rec === null; repeat: true; onTriggered: bindsProc.running = true }
    Timer { id: refetch; interval: 600; onTriggered: bindsProc.running = true }

    readonly property var shown: {
        var q = root.query.toLowerCase().trim();
        if (q === "") return root.binds;
        return root.binds.filter(b => b.desc.toLowerCase().indexOf(q) >= 0 || b.keys.toLowerCase().indexOf(q) >= 0);
    }

    // recorded base key → the xkb-ish name Hyprland expects in the config
    function keyName(e) {
        var k = e.key;
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(97 + (k - Qt.Key_A));
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(48 + (k - Qt.Key_0));
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1);
        var map = {};
        map[Qt.Key_Left]="left"; map[Qt.Key_Right]="right"; map[Qt.Key_Up]="up"; map[Qt.Key_Down]="down";
        map[Qt.Key_Return]="Return"; map[Qt.Key_Enter]="Return"; map[Qt.Key_Space]="Space";
        map[Qt.Key_Print]="Print"; map[Qt.Key_QuoteLeft]="grave"; map[Qt.Key_Tab]="Tab";
        map[Qt.Key_Backspace]="BackSpace"; map[Qt.Key_Delete]="Delete"; map[Qt.Key_Insert]="Insert";
        map[Qt.Key_Home]="Home"; map[Qt.Key_End]="End"; map[Qt.Key_PageUp]="Page_Up"; map[Qt.Key_PageDown]="Page_Down";
        map[Qt.Key_Comma]="comma"; map[Qt.Key_Period]="period"; map[Qt.Key_Minus]="minus"; map[Qt.Key_Equal]="equal";
        map[Qt.Key_Semicolon]="semicolon"; map[Qt.Key_Apostrophe]="apostrophe"; map[Qt.Key_Slash]="slash"; map[Qt.Key_Backslash]="backslash";
        map[Qt.Key_BracketLeft]="bracketleft"; map[Qt.Key_BracketRight]="bracketright";
        return map[k] || null;
    }
    function applyRebind(base) {
        var combo = root.recMods.join(" ");
        var clash = null;
        for (var i=0;i<root.binds.length;i++) {
            var b = root.binds[i];
            if (b.desc === root.rec.desc && b.key === root.rec.key) continue;
            if (b.mods.join(" ") === combo && b.key.toLowerCase() === base.toLowerCase()) { clash = b; break }
        }
        if (clash) { root.conflict = "already used by “" + clash.desc + "”"; return }
        Quickshell.execDetached(["sh", Qt.resolvedUrl("sea-rebind.sh").toString().replace("file://",""),
                                 root.rec.desc, root.rec.key, combo, base]);
        root.rec = null; root.conflict = "";
        refetch.start();
    }
    function applyAddBind() {
        var modsStr = root.addMods.join(" ");
        var scriptPath = Qt.resolvedUrl("sea-add-bind.sh").toString().replace("file://","");
        Quickshell.execDetached(["sh", scriptPath, modsStr, root.addKey, root.addDesc, root.addAction]);
        root.adding = false;
        root.addDesc = "";
        root.addAction = "exec, ";
        root.addKey = "";
        root.addMods = ["SUPER"];
        refetch.start();
    }

    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:keybinds"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.55); MouseArea { anchors.fill: parent; onClicked: Qt.quit() } }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 940)
            height: Math.min(parent.height - 80, 660)
            radius: 18
            color: theme.a(theme.bg, 0.98)
            border.width: 1; border.color: theme.a(theme.iris, 0.34)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 24; spacing: 14

                RowLayout {
                    spacing: 12; Layout.fillWidth: true
                    SeaLogo { size: 28; card: theme.line; accent: theme.iris; highlight: theme.frost; rim: theme.iris }
                    Text { text: "keybinds"; color: theme.text; font.pixelSize: 18; font.family: "monospace"; font.bold: true }
                    // search box — always focused; captures the rebind key while recording
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 30; radius: 8
                        color: theme.a(theme.line, 0.4)
                        border.width: 1; border.color: field.text!=="" ? theme.a(theme.iris,0.5) : theme.a(theme.iris,0.2)
                        Text { id: lens; text: "search"; font.family: "Material Symbols Outlined"; font.pixelSize: 14
                            color: theme.faint; anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter } }
                        TextInput {
                            id: field
                            anchors { left: lens.right; leftMargin: 8; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            color: theme.text; font.pixelSize: 13; font.family: "monospace"; clip: true
                            focus: true
                            onTextChanged: root.query = text
                            Text { text: "type to filter…"; visible: field.text===""; color: theme.faint
                                font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                            Keys.onPressed: (e)=> {
                                if (e.key === Qt.Key_Escape) {
                                    if (root.rec) { root.rec = null; root.conflict = "" }
                                    else if (root.addRecording) { root.addRecording = false }
                                    else if (root.adding) { root.adding = false }
                                    else Qt.quit();
                                    e.accepted = true;
                                    return;
                                }
                                if (root.rec) {           // recording: this key becomes the new base key
                                    if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                    var n = root.keyName(e);
                                    if (n) root.applyRebind(n); else root.conflict = "unsupported key";
                                    e.accepted = true;
                                    return;
                                }
                                if (root.addRecording) {
                                    if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                    var k = root.keyName(e);
                                    if (k) { root.addKey = k; root.addRecording = false }
                                    e.accepted = true;
                                }
                            }
                        }
                    }
                    // Add Button
                    Rectangle {
                        implicitWidth: 30; implicitHeight: 30; radius: 8
                        color: addBtnMa.containsMouse ? theme.iris : theme.a(theme.line, 0.4)
                        border.width: 1; border.color: theme.a(theme.iris, 0.2)
                        Sym { anchors.centerIn: parent; text: "add"; sz: 18; color: addBtnMa.containsMouse ? theme.bg : theme.frost }
                        MouseArea {
                            id: addBtnMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.adding = !root.adding; root.addRecording = false; field.forceActiveFocus() }
                        }
                    }
                    Text { text: root.shown.length + "/" + root.binds.length; color: theme.frost; font.pixelSize: 11; font.family: "monospace" }
                }

                // ================= ADD BIND PANEL =================
                Rectangle {
                    visible: root.adding
                    Layout.fillWidth: true
                    implicitHeight: addFormCol.implicitHeight + 20
                    radius: 10
                    color: theme.a(theme.line, 0.2)
                    border.width: 1; border.color: theme.a(theme.iris, 0.2)
                    ColumnLayout {
                        id: addFormCol
                        anchors.fill: parent; anchors.margins: 14; spacing: 12
                        
                        // Description
                        ColumnLayout {
                            spacing: 4; Layout.fillWidth: true
                            Text { text: "description"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 32; radius: 6
                                color: theme.a(theme.line, 0.4); border.width: 1
                                border.color: descIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.1)
                                TextInput {
                                    id: descIn
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                    text: root.addDesc
                                    onTextChanged: root.addDesc = text
                                    Text { text: "e.g. Launch Firefox"; visible: descIn.text===""; color: theme.faint; font.pixelSize: 12; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                }
                            }
                        }
                        
                        // Action / Command
                        ColumnLayout {
                            spacing: 4; Layout.fillWidth: true
                            Text { text: "action / command"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 32; radius: 6
                                color: theme.a(theme.line, 0.4); border.width: 1
                                border.color: actionIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.1)
                                TextInput {
                                    id: actionIn
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: theme.text; font.pixelSize: 12; font.family: "monospace"
                                    text: root.addAction
                                    onTextChanged: root.addAction = text
                                }
                            }
                        }

                        // Shortcut combination
                        ColumnLayout {
                            spacing: 4; Layout.fillWidth: true
                            Text { text: "shortcut combination"; color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                            RowLayout {
                                spacing: 10; Layout.fillWidth: true
                                // Modifier chips
                                Row {
                                    spacing: 6
                                    Repeater {
                                        model: ["SUPER","CTRL","ALT","SHIFT"]
                                        delegate: Rectangle {
                                            required property string modelData
                                            readonly property bool on: root.addMods.indexOf(modelData) >= 0
                                            width: amc.width + 14; height: 22; radius: 11
                                            color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5)
                                            border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                            Text { id: amc; anchors.centerIn: parent; text: modelData
                                                color: on ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace"; font.bold: on }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { var m = root.addMods.slice(); var i = m.indexOf(modelData);
                                                    if (i >= 0) m.splice(i,1); else m.push(modelData);
                                                    root.addMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x => m.indexOf(x) >= 0);
                                                    field.forceActiveFocus() } }
                                        }
                                    }
                                }
                                
                                Text { text: "+"; color: theme.faint; font.pixelSize: 12; font.family: "monospace" }

                                // Key capture button
                                Rectangle {
                                    implicitWidth: 120; implicitHeight: 24; radius: 6
                                    color: root.addRecording ? theme.a(theme.bad, 0.2) : theme.a(theme.line, 0.4)
                                    border.width: 1; border.color: root.addRecording ? theme.bad : theme.a(theme.iris, 0.3)
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.addRecording ? "press key…" : (root.addKey ? root.addKey : "set key combo")
                                        color: root.addRecording ? theme.bad : theme.frost
                                        font.pixelSize: 11; font.family: "monospace"; font.bold: true
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.addRecording = true; field.forceActiveFocus() }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                        }
                        
                        // Control buttons (Save / Cancel)
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10; Layout.topMargin: 4
                            Item { Layout.fillWidth: true }
                            
                            // Cancel button
                            Rectangle {
                                implicitWidth: 70; implicitHeight: 28; radius: 6
                                color: cancelBtnMa.containsMouse ? theme.a(theme.bad, 0.15) : "transparent"
                                border.width: 1; border.color: cancelBtnMa.containsMouse ? theme.bad : theme.a(theme.line, 0.5)
                                Text { anchors.centerIn: parent; text: "Cancel"; color: cancelBtnMa.containsMouse ? theme.bad : theme.text; font.pixelSize: 11; font.family: "monospace" }
                                MouseArea {
                                    id: cancelBtnMa
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.adding = false; root.addRecording = false; field.forceActiveFocus() }
                                }
                            }
                            
                            // Save button
                            Rectangle {
                                readonly property bool valid: root.addDesc.trim() !== "" && root.addKey !== "" && root.addAction.trim() !== ""
                                implicitWidth: 90; implicitHeight: 28; radius: 6
                                color: valid ? (saveBtnMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)) : theme.a(theme.line, 0.2)
                                border.width: 1; border.color: valid ? theme.iris : theme.a(theme.line, 0.5)
                                Text { anchors.centerIn: parent; text: "Save Bind"; color: parent.valid ? (saveBtnMa.containsMouse ? theme.bg : theme.text) : theme.faint; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                                MouseArea {
                                    id: saveBtnMa
                                    anchors.fill: parent; enabled: parent.valid; cursorShape: parent.valid ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.applyAddBind()
                                }
                            }
                        }
                    }
                }

                Flickable {
                    id: flick
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: width; contentHeight: grid.implicitHeight
                    clip: true; boundsBehavior: Flickable.StopAtBounds

                    Grid {
                        id: grid
                        width: flick.width
                        columns: 2
                        columnSpacing: 14; rowSpacing: 7
                        Repeater {
                            model: root.shown
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool isRec: root.rec !== null && root.rec.desc === modelData.desc && root.rec.key === modelData.key
                                width: (grid.width - grid.columnSpacing) / 2
                                height: 34; radius: 8
                                color: isRec ? theme.a(theme.iris, 0.2) : hov.containsMouse ? theme.a(theme.iris, 0.12) : theme.a(theme.line, 0.32)
                                border.width: 1; border.color: isRec ? theme.iris : theme.a(theme.iris, 0.12)
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11; spacing: 10
                                    Text { text: modelData.desc; color: theme.text; font.pixelSize: 12; font.family: "monospace"; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { visible: hov.containsMouse && modelData.canEdit && !isRec; text: "edit"
                                        font.family: "Material Symbols Outlined"; font.pixelSize: 14; color: theme.faint }
                                    Rectangle { implicitHeight: 22; implicitWidth: kb.implicitWidth + 16; radius: 6
                                        color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                                        Text { id: kb; anchors.centerIn: parent; text: modelData.keys; color: theme.frost; font.pixelSize: 11; font.family: "monospace"; font.bold: true } }
                                }
                                MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: modelData.canEdit ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { if (!modelData.canEdit) return;
                                        root.rec = modelData; root.recMods = modelData.mods.slice(); root.conflict = "";
                                        field.forceActiveFocus() } }
                            }
                        }
                    }
                }

                // footer: hints, or the recording bar with modifier chips
                Item {
                    Layout.fillWidth: true; implicitHeight: 30
                    Text { anchors.centerIn: parent; visible: root.rec === null
                        text: "type to search · click a bind to rebind it · esc closes"
                        color: theme.faint; font.pixelSize: 10; font.family: "monospace" }
                    Row {
                        anchors.centerIn: parent; spacing: 8; visible: root.rec !== null
                        Text { anchors.verticalCenter: parent.verticalCenter
                            text: "rebind “" + (root.rec ? root.rec.desc : "") + "”:"
                            color: theme.text; font.pixelSize: 11; font.family: "monospace"; font.bold: true }
                        Repeater {
                            model: ["SUPER","CTRL","ALT","SHIFT"]
                            delegate: Rectangle {
                                required property string modelData
                                readonly property bool on: root.recMods.indexOf(modelData) >= 0
                                width: mc.width + 14; height: 22; radius: 11
                                color: on ? theme.a(theme.iris,0.3) : theme.a(theme.line,0.5)
                                border.width: 1; border.color: on ? theme.iris : theme.a(theme.line,0.9)
                                Text { id: mc; anchors.centerIn: parent; text: modelData
                                    color: on ? theme.frost : theme.faint; font.pixelSize: 10; font.family: "monospace"; font.bold: on }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { var m = root.recMods.slice(); var i = m.indexOf(modelData);
                                        if (i >= 0) m.splice(i,1); else m.push(modelData);
                                        // keep hyprland's canonical order
                                        root.recMods = ["SUPER","CTRL","ALT","SHIFT"].filter(x => m.indexOf(x) >= 0);
                                        root.conflict = ""; field.forceActiveFocus() } }
                            }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter
                            text: root.conflict !== "" ? root.conflict : "now press the key · esc cancels"
                            color: root.conflict !== "" ? theme.bad : theme.sub
                            font.pixelSize: 11; font.family: "monospace" }
                    }
                }
            }
        }
    }
}
