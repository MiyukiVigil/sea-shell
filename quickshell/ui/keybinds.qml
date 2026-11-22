//@ pragma UseQApplication
// sea-shell — keyboard shortcuts (SUPER+K). Reads live binds from `hyprctl binds`; the names
// are the `description` each bind carries in keybinds.lua.
//
// Shortcuts are grouped (apps, shell, windows, workspaces, capture, media), one row per action
// with every combo that triggers it, and numbered runs like "Workspace 1…10" fold into one row
// until you search for one. Click a combo to change it: toggle the modifiers in the bar at the
// bottom, then press the new key — sea-rebind.sh rewrites keybinds.lua (+ repo copy) and
// reloads. Binds without a description are plumbing (the alt-tab switcher's commit/cancel,
// the lid switch) and are left out. Esc / click-outside closes.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    property var binds: []
    property int hiddenCount: 0
    property string query: ""
    property var rec: null           // bind being rebound: {desc, key, keys, mods, ...}
    property var recMods: []         // modifier chips currently toggled on
    property string conflict: ""

    // new-shortcut form
    property bool adding: false
    property string addDesc: ""
    property string addAction: "exec, "
    property var addMods: ["SUPER"]
    property string addKey: ""
    property bool addRecording: false

    // ---------------- look ----------------
    // settings.qml's control-centre rules: panels and hovers are the ink laid thinly over the
    // ground, so this sheet and the dashboard read as the same product.
    readonly property color groupFill: Tok.surface
    readonly property color groupRule: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color rowHover:  Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)

    property bool closing: false
    function close() { if (root.closing) return; root.closing = true; quitTimer.start() }
    Timer { id: quitTimer; interval: Tok.reducedMotion ? 0 : 130; onTriggered: Qt.quit() }
    SurfaceMotion { id: motion; opened: Tok.loaded && !root.closing; reduced: Tok.reducedMotion
        enterDuration: 220; exitDuration: 120 }

    component Sym: Text {
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: Tok.ink2
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // ---------------- reading the binds ----------------
    function modStr(m) {
        var s = [];
        if (m & 64) s.push("SUPER");
        if (m & 4)  s.push("CTRL");
        if (m & 8)  s.push("ALT");
        if (m & 1)  s.push("SHIFT");
        return s;
    }
    function prettyMod(m) { return ({ SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" })[m] || m }
    // the key as it is printed on a keyboard, not as xkb spells it
    function prettyKey(k) {
        var named = {
            Return: "Enter", Escape: "Esc", grave: "`", space: "Space", Space: "Space", Tab: "Tab",
            equal: "=", minus: "-", comma: ",", period: ".", slash: "/", backslash: "\\",
            semicolon: ";", apostrophe: "'", bracketleft: "[", bracketright: "]",
            left: "←", right: "→", up: "↑", down: "↓", BackSpace: "Backspace",
            Page_Up: "PgUp", Page_Down: "PgDn", Print: "PrtSc",
            KP_Add: "Num +", KP_Subtract: "Num −", Alt_L: "Alt",
            mouse_down: "Scroll ↓", mouse_up: "Scroll ↑", "mouse:272": "Left click", "mouse:273": "Right click",
            XF86AudioRaiseVolume: "Volume +", XF86AudioLowerVolume: "Volume −", XF86AudioMute: "Mute",
            XF86AudioMicMute: "Mic mute", XF86MonBrightnessUp: "Brightness +", XF86MonBrightnessDown: "Brightness −",
            XF86AudioPlay: "Play", XF86AudioPause: "Pause", XF86AudioNext: "Next", XF86AudioPrev: "Previous"
        };
        if (named[k] !== undefined) return named[k];
        if (/^XF86/.test(k)) return k.replace("XF86", "").replace(/([a-z])([A-Z])/g, "$1 $2");
        return k.length === 1 ? k.toUpperCase() : k;
    }

    // Which group an action belongs in, read from its name — the same sections keybinds.lua is
    // written in, and a bind the user adds later lands somewhere sensible without a lookup table.
    readonly property var groupOrder: ["Apps", "Shell", "Windows", "Workspaces", "Capture", "Media & hardware", "Other"]
    function groupOf(b) {
        var d = b.desc;
        if (/^XF86/.test(b.key) || /volume|brightness|mute|track|play|pause/i.test(d)) return "Media & hardware";
        if (/screenshot|screen ?record|ocr|capture|ruler|translate/i.test(d)) return "Capture";
        if (/workspace|scratchpad|session/i.test(d)) return "Workspaces";
        if (/launcher|wallpaper|dashboard|control center|settings|cheat|light|dark|lock|power|reload|restart|menu|mission|widget|clipboard|emoji|notes|color|colour|drop shelf|qr|game mode|magnifier|arrange|notification|desktop|bar/i.test(d)) return "Shell";
        if (/window|focus|maximi|fullscreen|float|center|split|pseudo|pin|picture-in-picture|pip|group|switcher/i.test(d)) return "Windows";
        if (b.exec) return "Apps";
        return "Other";
    }

    Process {
        id: bindsProc; running: true
        command: ["sh","-c","hyprctl binds -j"]
        stdout: StdioCollector { id: bOut; onStreamFinished: {
            try {
                var arr = JSON.parse(bOut.text), out = [], seen = {}, hidden = 0;
                for (var i = 0; i < arr.length; i++) {
                    var b = arr[i];
                    if (b.mouse && !b.description) continue;
                    if (!(b.description && b.description.length)) { hidden++; continue }
                    var mods = root.modStr(b.modmask);
                    var keys = mods.concat([b.key]).join(" + ");
                    var sig = keys + "|" + b.description;
                    if (seen[sig]) continue; seen[sig] = 1;
                    var o = { keys: keys, desc: b.description, arg: (b.arg || ""), key: b.key, mods: mods,
                              caps: mods.map(root.prettyMod).concat([root.prettyKey(b.key)]),
                              exec: /exec/.test(b.dispatcher || ""),
                              canEdit: !b.mouse && !/^mouse/.test(b.key) };
                    o.group = root.groupOf(o);
                    out.push(o);
                }
                root.binds = out;
                root.hiddenCount = hidden;
            } catch(e) {}
        } }
    }
    Timer { interval: 4000; running: root.rec === null && !root.adding; repeat: true; onTriggered: bindsProc.running = true }
    Timer { id: refetch; interval: 600; onTriggered: bindsProc.running = true }

    // binds → groups of rows. A row is one action with every combo that runs it; numbered runs
    // ("Workspace 1" … "Workspace 10") fold into one row while nothing is being searched.
    readonly property var groups: {
        var q = root.query.toLowerCase().trim();
        var list = q === "" ? root.binds : root.binds.filter(b =>
            b.desc.toLowerCase().indexOf(q) >= 0 || b.keys.toLowerCase().indexOf(q) >= 0
            || b.caps.join(" ").toLowerCase().indexOf(q) >= 0 || b.group.toLowerCase().indexOf(q) >= 0);
        var byGroup = {};
        for (var i = 0; i < list.length; i++) {
            var b = list[i], g = byGroup[b.group] || (byGroup[b.group] = { rows: [], index: {} });
            var m = q === "" ? /^(.*\D) (\d+)$/.exec(b.desc) : null;
            var rk = m ? "#" + m[1] + "|" + b.mods.join(" ") : b.desc;
            var row = g.index[rk];
            if (!row) {
                row = { desc: m ? m[1] : b.desc, combos: [], run: m ? [] : null };
                g.index[rk] = row; g.rows.push(row);
            }
            if (m) row.run.push({ n: parseInt(m[2]), b: b }); else row.combos.push(b);
        }
        var out = [];
        for (var k = 0; k < root.groupOrder.length; k++) {
            var gr = byGroup[root.groupOrder[k]];
            if (!gr) continue;
            var rows = [];
            for (var r = 0; r < gr.rows.length; r++) {
                var rw = gr.rows[r];
                if (rw.run) {
                    rw.run.sort((x, y) => x.n - y.n);
                    if (rw.run.length < 3) {             // too short to be a run: list them
                        for (var s = 0; s < rw.run.length; s++)
                            rows.push({ desc: rw.desc + " " + rw.run[s].n, combos: [rw.run[s].b] });
                        continue;
                    }
                    var first = rw.run[0], last = rw.run[rw.run.length - 1];
                    rows.push({ desc: rw.desc + " " + first.n + "–" + last.n, folded: true,
                                combos: [{ caps: first.b.caps.slice(0, -1).concat([first.b.caps[first.b.caps.length - 1] + "…" + last.b.caps[last.b.caps.length - 1]]),
                                           canEdit: false, desc: "", key: "" }] });
                } else rows.push(rw);
            }
            out.push({ name: root.groupOrder[k], rows: rows });
        }
        return out;
    }
    readonly property int shownCount: {
        var n = 0;
        for (var i = 0; i < root.groups.length; i++) n += root.groups[i].rows.length;
        return n;
    }
    // two columns, each group going to whichever is shorter, so neither runs on alone
    readonly property var columns: {
        var cols = [[], []], h = [0, 0];
        for (var i = 0; i < root.groups.length; i++) {
            var c = h[0] <= h[1] ? 0 : 1;
            cols[c].push(root.groups[i]);
            h[c] += root.groups[i].rows.length + 2;
        }
        return cols;
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
    function startRebind(b) {
        if (!b || !b.canEdit) return;
        root.adding = false;
        root.rec = b; root.recMods = b.mods.slice(); root.conflict = "";
        field.forceActiveFocus();
    }
    function applyRebind(base) {
        var combo = root.recMods.join(" ");
        var clash = null;
        for (var i=0;i<root.binds.length;i++) {
            var b = root.binds[i];
            if (b.desc === root.rec.desc && b.key === root.rec.key) continue;
            if (b.mods.join(" ") === combo && b.key.toLowerCase() === base.toLowerCase()) { clash = b; break }
        }
        if (clash) { root.conflict = "Already used by “" + clash.desc + "”"; return }
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
    function toggleMod(list, m) {
        var l = list.slice(), i = l.indexOf(m);
        if (i >= 0) l.splice(i, 1); else l.push(m);
        return ["SUPER","CTRL","ALT","SHIFT"].filter(x => l.indexOf(x) >= 0);   // Hyprland's order
    }

    // ---------------- pieces ----------------
    // A key cap: a raised key with a lip under it, so a combo reads as keys to press rather than
    // as a string of text.
    component Cap: Item {
        id: cap
        property string text: ""
        property bool lit: false
        implicitWidth: Math.max(24, capT.implicitWidth + 14)
        implicitHeight: 24
        Rectangle {
            anchors.fill: parent; anchors.topMargin: 2
            radius: 6
            color: cap.lit ? Qt.darker(Tok.accent, 1.35) : Tok.alpha(Tok.ink, Tok.light ? 0.16 : 0.30)
        }
        Rectangle {
            anchors.fill: parent; anchors.bottomMargin: 2
            radius: 6
            color: cap.lit ? Tok.accent : (Tok.light ? "#ffffff" : Tok.raised)
            border.width: 1
            border.color: cap.lit ? Tok.accent : Tok.alpha(Tok.ink, 0.10)
            IndText { id: capT; anchors.centerIn: parent; text: cap.text; sz: 11; font.weight: Font.Medium
                color: cap.lit ? Tok.accentInk : Tok.ink2 }
        }
    }

    // a modifier you can switch on and off (rebind bar, new-shortcut form)
    component ModChip: Rectangle {
        id: mch
        property string mod: ""
        property bool on: false
        signal flipped()
        implicitWidth: mcT.implicitWidth + 20
        implicitHeight: 28
        radius: 14
        color: mch.on ? Tok.accent : (mchMa.containsMouse ? root.rowHover : root.groupFill)
        border.width: 1
        border.color: mch.on ? Tok.accent : root.groupRule
        Behavior on color { ColorAnimation { duration: Tok.mFast } }
        IndText { id: mcT; anchors.centerIn: parent; text: root.prettyMod(mch.mod); sz: Tok.tData
            font.weight: Font.Medium; color: mch.on ? Tok.accentInk : Tok.ink2 }
        MouseArea { id: mchMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: mch.flipped() }
    }

    component Btn: Rectangle {
        id: bt
        property string text: ""
        property bool primary: false
        property bool enabled: true
        signal clicked()
        implicitWidth: btT.implicitWidth + 28
        implicitHeight: 32
        radius: 16
        opacity: bt.enabled ? 1 : 0.45
        color: bt.primary ? (btMa.containsMouse ? Qt.lighter(Tok.accent, 1.1) : Tok.accent)
                          : (btMa.containsMouse ? root.rowHover : root.groupFill)
        border.width: bt.primary ? 0 : 1
        border.color: root.groupRule
        scale: btMa.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: Tok.mMicro; easing.type: Easing.OutCubic } }
        IndText { id: btT; anchors.centerIn: parent; text: bt.text; sz: Tok.tDense; font.weight: Font.Medium
            color: bt.primary ? Tok.accentInk : Tok.ink }
        MouseArea { id: btMa; anchors.fill: parent; hoverEnabled: true; enabled: bt.enabled
            cursorShape: Qt.PointingHandCursor; onClicked: bt.clicked() }
    }

    // a labelled text field for the new-shortcut form
    component Field: ColumnLayout {
        id: fl
        property string label: ""
        property string placeholder: ""
        property alias text: flIn.text
        property alias input: flIn
        property bool mono: false
        Layout.fillWidth: true
        spacing: 5
        IndText { text: fl.label; sz: Tok.tData; color: Tok.ink2; font.weight: Font.DemiBold }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            radius: Tok.r + 2
            color: Tok.light ? "#ffffff" : Tok.raised
            border.width: 1
            border.color: flIn.activeFocus ? Tok.accent : root.groupRule
            TextInput {
                id: flIn
                anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 11
                verticalAlignment: TextInput.AlignVCenter
                clip: true; selectByMouse: true
                color: Tok.ink; selectionColor: Tok.accent; selectedTextColor: Tok.accentInk
                font.family: fl.mono ? Tok.mono : Tok.sans
                font.pixelSize: Tok.tDense
                IndText { anchors.verticalCenter: parent.verticalCenter; visible: flIn.text === ""
                    text: fl.placeholder; color: Tok.ink3; mono: fl.mono }
            }
        }
    }

    // ---------------- window ----------------
    PanelWindow {
        id: win
        readonly property real ui: Tok.uiFor(win.screen)
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:keybinds"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        Binding { target: win.contentItem; property: "scale"; value: win.ui }

        // sized in native units (screen ÷ ui), because the contentItem is scaled
        Rectangle {
            id: scrim
            anchors.centerIn: parent
            width: win.width / win.ui
            height: win.height / win.ui
            color: Qt.rgba(0, 0, 0, Tok.light ? 0.30 : 0.50)
            opacity: motion.progress
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        Rectangle {
            id: sheet
            anchors.centerIn: scrim
            anchors.verticalCenterOffset: (1 - motion.progress) * 16
            width: Math.min(1080, scrim.width - Tok.s12 * 2)
            height: Math.min(840, scrim.height - Tok.s12 * 2)
            radius: Tok.rCard
            color: Tok.bg
            border.width: 1
            border.color: root.groupRule
            opacity: motion.progress
            scale: 0.98 + 0.02 * motion.progress
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Tok.s8
                anchors.bottomMargin: Tok.s6
                spacing: Tok.s4

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tok.s3
                    ColumnLayout {
                        spacing: 2
                        IndText { text: "Keyboard shortcuts"; sz: Tok.tTitle + 2; font.weight: Font.Bold }
                        IndText {
                            sz: Tok.tDense; color: Tok.ink3
                            text: root.query === "" ? root.binds.length + " shortcuts"
                                : root.shownCount === 0 ? "Nothing matches “" + root.query + "”"
                                : root.shownCount + " matching"
                        }
                    }
                    Item { Layout.fillWidth: true }
                    // search — always focused; it also catches the new key while rebinding
                    Rectangle {
                        Layout.preferredWidth: 300
                        implicitHeight: 36
                        radius: 18
                        color: root.groupFill
                        border.width: 1
                        border.color: field.text !== "" ? Tok.alpha(Tok.accent, 0.6) : root.groupRule
                        Sym { id: lens; text: "search"; sz: 17; color: Tok.ink3
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter } }
                        TextInput {
                            id: field
                            anchors { left: lens.right; leftMargin: 8; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                            color: Tok.ink; font.pixelSize: Tok.tDense; font.family: Tok.sans; clip: true
                            selectionColor: Tok.accent; selectedTextColor: Tok.accentInk
                            focus: true
                            onTextChanged: root.query = text
                            IndText { text: "Search"; visible: field.text === ""; color: Tok.ink3
                                anchors.verticalCenter: parent.verticalCenter }
                            Keys.onPressed: (e)=> {
                                if (e.key === Qt.Key_Escape) {
                                    if (root.rec) { root.rec = null; root.conflict = "" }
                                    else if (root.addRecording) { root.addRecording = false }
                                    else if (root.adding) { root.adding = false }
                                    else if (field.text !== "") { field.text = "" }
                                    else root.close();
                                    e.accepted = true;
                                    return;
                                }
                                if (root.rec) {           // recording: this key becomes the new base key
                                    if (e.key===Qt.Key_Shift||e.key===Qt.Key_Control||e.key===Qt.Key_Alt||e.key===Qt.Key_Meta) { e.accepted=true; return }
                                    var n = root.keyName(e);
                                    if (n) root.applyRebind(n); else root.conflict = "That key can’t be bound here";
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
                    Btn { text: root.adding ? "Cancel" : "New shortcut"; primary: !root.adding
                        onClicked: { root.adding = !root.adding; root.addRecording = false; root.rec = null
                            if (root.adding) descField.input.forceActiveFocus(); else field.forceActiveFocus() } }
                    Rectangle {
                        implicitWidth: 34; implicitHeight: 34; radius: 17
                        color: closeMa.containsMouse ? root.rowHover : root.groupFill
                        border.width: 1; border.color: root.groupRule
                        Sym { anchors.centerIn: parent; text: "close"; sz: 18 }
                        MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                    }
                }

                // ---------- new shortcut ----------
                Rectangle {
                    visible: root.adding
                    Layout.fillWidth: true
                    implicitHeight: addCol.implicitHeight + Tok.s4 * 2
                    radius: Tok.r + 4
                    color: root.groupFill
                    border.width: 1; border.color: root.groupRule
                    ColumnLayout {
                        id: addCol
                        anchors.fill: parent; anchors.margins: Tok.s4
                        spacing: Tok.s3
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tok.s4
                            Field { id: descField; label: "Name"; placeholder: "Open Firefox"
                                text: root.addDesc; onTextChanged: root.addDesc = text }
                            Field { label: "Action"; mono: true; placeholder: "exec, firefox"
                                text: root.addAction; onTextChanged: root.addAction = text }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tok.s2
                            IndText { text: "Shortcut"; sz: Tok.tData; color: Tok.ink2; font.weight: Font.DemiBold
                                Layout.rightMargin: Tok.s2 }
                            Repeater {
                                model: ["SUPER","CTRL","ALT","SHIFT"]
                                delegate: ModChip {
                                    required property string modelData
                                    mod: modelData; on: root.addMods.indexOf(modelData) >= 0
                                    onFlipped: { root.addMods = root.toggleMod(root.addMods, modelData); field.forceActiveFocus() }
                                }
                            }
                            IndText { text: "+"; color: Tok.ink3 }
                            Rectangle {
                                implicitWidth: Math.max(130, akT.implicitWidth + 28); implicitHeight: 28; radius: 14
                                color: root.addRecording ? Tok.accentWash : root.groupFill
                                border.width: 1
                                border.color: root.addRecording ? Tok.accent : root.groupRule
                                IndText { id: akT; anchors.centerIn: parent; sz: Tok.tData; font.weight: Font.Medium
                                    text: root.addRecording ? "Press a key…" : root.addKey ? root.prettyKey(root.addKey) : "Choose key"
                                    color: root.addRecording ? Tok.accent : Tok.ink }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.addRecording = true; field.forceActiveFocus() } }
                            }
                            Item { Layout.fillWidth: true }
                            Btn { text: "Add shortcut"; primary: true
                                enabled: root.addDesc.trim() !== "" && root.addKey !== "" && root.addAction.trim() !== ""
                                onClicked: root.applyAddBind() }
                        }
                    }
                }

                // ---------- the groups ----------
                Flickable {
                    id: flick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: cols.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    RowLayout {
                        id: cols
                        width: flick.width
                        spacing: Tok.s6
                        Repeater {
                            model: root.columns
                            delegate: ColumnLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                spacing: Tok.s4
                                Repeater {
                                    model: modelData
                                    delegate: ColumnLayout {
                                        id: grp
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: Tok.s2
                                        IndText { text: grp.modelData.name; sz: Tok.tDense; font.weight: Font.Bold
                                            Layout.leftMargin: Tok.s1 }
                                        Rectangle {
                                            Layout.fillWidth: true
                                            implicitHeight: rowsCol.implicitHeight + 8
                                            radius: Tok.r + 4
                                            color: root.groupFill
                                            border.width: 1; border.color: root.groupRule
                                            ColumnLayout {
                                                id: rowsCol
                                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 4 }
                                                spacing: 0
                                                Repeater {
                                                    model: grp.modelData.rows
                                                    delegate: Rectangle {
                                                        id: row
                                                        required property var modelData
                                                        required property int index
                                                        readonly property bool editable: modelData.combos.length > 0 && modelData.combos[0].canEdit
                                                        Layout.fillWidth: true
                                                        implicitHeight: 40
                                                        radius: Tok.r + 1
                                                        color: rowHov.hovered && row.editable ? root.rowHover : "transparent"
                                                        Behavior on color { ColorAnimation { duration: Tok.mFast } }
                                                        HoverHandler { id: rowHov }
                                                        // hairline between rows, inset like a System Settings list
                                                        Rectangle { visible: row.index > 0; height: 1; color: root.groupRule
                                                            anchors { top: parent.top; left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 } }
                                                        MouseArea { anchors.fill: parent
                                                            cursorShape: row.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                            onClicked: root.startRebind(row.modelData.combos[0]) }
                                                        RowLayout {
                                                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8
                                                            spacing: Tok.s3
                                                            IndText { text: row.modelData.desc; sz: Tok.tDense
                                                                Layout.fillWidth: true; elide: Text.ElideRight }
                                                            Sym { text: "edit"; sz: 14; color: Tok.ink3
                                                                visible: rowHov.hovered && row.editable && root.rec === null }
                                                            Repeater {
                                                                model: row.modelData.combos
                                                                delegate: Item {
                                                                    id: combo
                                                                    required property var modelData
                                                                    required property int index
                                                                    readonly property bool isRec: root.rec !== null && root.rec.desc === modelData.desc && root.rec.key === modelData.key
                                                                    implicitWidth: comboRow.implicitWidth
                                                                    implicitHeight: comboRow.implicitHeight
                                                                    Row {
                                                                        id: comboRow
                                                                        spacing: 4
                                                                        IndText { visible: combo.index > 0; text: "or"; sz: Tok.tData; color: Tok.ink3
                                                                            anchors.verticalCenter: parent.verticalCenter; rightPadding: 4 }
                                                                        Repeater {
                                                                            model: combo.isRec ? root.recMods.map(root.prettyMod).concat(["…"]) : combo.modelData.caps
                                                                            delegate: Cap { required property string modelData; text: modelData; lit: combo.isRec }
                                                                        }
                                                                    }
                                                                    // a second combo is its own target: clicking it changes that one
                                                                    MouseArea { anchors.fill: parent
                                                                        visible: combo.index > 0 && combo.modelData.canEdit
                                                                        cursorShape: Qt.PointingHandCursor
                                                                        onClicked: root.startRebind(combo.modelData) }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- footer: a hint, or the rebind bar ----------
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 48
                    radius: 24
                    color: root.rec !== null ? Tok.accentWash : "transparent"
                    border.width: root.rec !== null ? 1 : 0
                    border.color: Tok.alpha(Tok.accent, 0.35)
                    Behavior on color { ColorAnimation { duration: Tok.mFast } }

                    IndText {
                        anchors.centerIn: parent
                        visible: root.rec === null
                        sz: Tok.tData; color: Tok.ink3
                        text: "Click a shortcut to change it. Esc closes."
                              + (root.hiddenCount > 0 ? "  " + root.hiddenCount + " unnamed helper binds are not listed." : "")
                    }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: Tok.s4; anchors.rightMargin: 8
                        visible: root.rec !== null
                        spacing: Tok.s2
                        IndText { text: "Change “" + (root.rec ? root.rec.desc : "") + "”"; sz: Tok.tDense
                            font.weight: Font.DemiBold; Layout.rightMargin: Tok.s2 }
                        Repeater {
                            model: ["SUPER","CTRL","ALT","SHIFT"]
                            delegate: ModChip {
                                required property string modelData
                                mod: modelData; on: root.recMods.indexOf(modelData) >= 0
                                onFlipped: { root.recMods = root.toggleMod(root.recMods, modelData); root.conflict = ""; field.forceActiveFocus() }
                            }
                        }
                        IndText {
                            Layout.fillWidth: true; Layout.leftMargin: Tok.s2
                            elide: Text.ElideRight
                            text: root.conflict !== "" ? root.conflict : "then press the new key"
                            color: root.conflict !== "" ? Tok.crit : Tok.ink2
                            sz: Tok.tDense
                        }
                        Btn { text: "Cancel"; onClicked: { root.rec = null; root.conflict = ""; field.forceActiveFocus() } }
                    }
                }
            }
        }
    }
}
