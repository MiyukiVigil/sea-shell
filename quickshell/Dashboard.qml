import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    
    property string cfgFont: "monospace"
    property string accent: "#63c7dd"
    property bool cfgLight: false
    property real cfgRadius: 14

    property var cpuHistory: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    property var ramHistory: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    
    property string cpuPct: "0"
    property string cpuTemp: "0"
    property string ramUsed: "0.0"
    property string ramTotal: "0.0"
    property string ramPct: "0"
    property string diskInfo: "0 / 0 GB"
    property int diskPct: 0
    property string loadAvg: "0.00 0.00 0.00"
    
    property var todoList: []

    // ---------- load system stats ----------
    Timer {
        interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: sysMonProc.running = true
    }
    
    Process {
        id: sysMonProc
        command: ["sh", "-c", "~/.config/quickshell/sea-shell/sea-sysmon.sh; cat /proc/loadavg | awk '{printf \"%s %s %s\", $1, $2, $3}'; printf '|'; df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,\"\",$5); printf \"%s/%s|%d\", $3, $2, $5}'"]
        stdout: StdioCollector {
            id: sysOut
            onStreamFinished: {
                var txt = sysOut.text.trim();
                if (!txt) return;
                var parts = txt.split("|");
                if (parts.length >= 11) {
                    root.cpuPct = parts[0] || "0";
                    root.cpuTemp = parts[1] || "0";
                    root.ramUsed = parts[2] || "0.0";
                    root.ramTotal = parts[3] || "0.0";
                    root.ramPct = parts[4] || "0";
                    
                    var load = parts[11] || "0.00 0.00 0.00";
                    root.loadAvg = load;
                    
                    var dfVal = parts[12] || "0/0";
                    var dfPct = parseInt(parts[13]) || 0;
                    root.diskInfo = dfVal;
                    root.diskPct = dfPct;
                    
                    // append history
                    var cpuH = root.cpuHistory.slice(1);
                    cpuH.push(parseInt(root.cpuPct));
                    root.cpuHistory = cpuH;
                    
                    var ramH = root.ramHistory.slice(1);
                    ramH.push(parseInt(root.ramPct));
                    root.ramHistory = ramH;
                    
                    cpuCanvas.requestPaint();
                    ramCanvas.requestPaint();
                }
            }
        }
    }
    
    // ---------- load/save todo list ----------
    Component.onCompleted: {
        loadTodoProc.running = true;
    }
    
    Process {
        id: loadTodoProc
        command: ["sh", "-c", "cat ~/.config/sea-shell/todo.json 2>/dev/null || echo '[]'"]
        stdout: StdioCollector {
            id: todoOut
            onStreamFinished: {
                try {
                    root.todoList = JSON.parse(todoOut.text);
                } catch(e) {
                    root.todoList = [];
                }
            }
        }
    }
    
    // ---------- load appearance config ----------
    Process {
        id: apProc; running: true; command: ["sh","-c","cat \"$HOME/.config/sea-shell/appearance.json\" 2>/dev/null"]
        stdout: StdioCollector {
            id: apOut
            onStreamFinished: {
                try {
                    var j=JSON.parse(apOut.text);
                    if(j.accent) root.accent=j.accent;
                    if(j.radius!==undefined) root.cfgRadius=j.radius;
                    if(j.font!==undefined) root.cfgFont=j.font;
                    if(j.mode!==undefined) root.cfgLight=(""+j.mode==="light");
                } catch(e){}
            }
        }
    }
    
    function saveTodo() {
        var base64 = Qt.btoa(JSON.stringify(root.todoList));
        Quickshell.execDetached(["sh", "-c", "mkdir -p ~/.config/sea-shell && echo '" + base64 + "' | base64 -d > ~/.config/sea-shell/todo.json"]);
    }
    
    function addTodo(txt) {
        if (!txt.trim()) return;
        var list = root.todoList.slice();
        list.push({text: txt.trim(), done: false});
        root.todoList = list;
        saveTodo();
    }
    
    function toggleTodo(idx) {
        var list = root.todoList.slice();
        list[idx].done = !list[idx].done;
        root.todoList = list;
        saveTodo();
    }
    
    function removeTodo(idx) {
        var list = root.todoList.slice();
        list.splice(idx, 1);
        root.todoList = list;
        saveTodo();
    }

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
        readonly property color frost: light ? Qt.darker(root.accent, 1.7)  : Qt.lighter(root.accent, 1.22)
        readonly property color bad:   light ? "#d1495b" : "#f38ba8"
        function a(c, al) { return Qt.rgba(c.r, c.g, c.b, al) }
    }

    // Material Symbols glyphs helper
    component Sym: Text {
        id: sym
        property int sz: 16
        font.family: "Material Symbols Outlined"
        font.pixelSize: sz
        color: theme.frost
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    PanelWindow {
        id: dWin
        visible: true
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:dashboard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore
        onVisibleChanged: if (visible) tdIn.forceActiveFocus()
        
        // frosted background scrim
        Rectangle {
            anchors.fill: parent
            color: theme.light ? Qt.rgba(0.96, 0.96, 0.97, 0.98) : Qt.rgba(0.05, 0.06, 0.08, 0.98) // high opacity - no app text bleed-through
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
            
            // ESC key to close
            FocusScope {
                anchors.fill: parent; focus: true
                Keys.onEscapePressed: Qt.quit()
                
                // Dashboard layout
                ColumnLayout {
                    anchors.centerIn: parent
                    width: 740; height: 580; spacing: 20
                    
                    // --- Header ---
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            spacing: 2
                            Text {
                                id: timeTextLabel
                                property string timeText: Qt.formatDateTime(new Date(), "HH:mm")
                                text: timeText
                                color: theme.text; font.pixelSize: 34; font.bold: true; font.family: root.cfgFont
                                Timer {
                                    interval: 1000; running: true; repeat: true
                                    onTriggered: timeTextLabel.timeText = Qt.formatDateTime(new Date(), "HH:mm")
                                }
                            }
                            Text {
                                id: dateTextLabel
                                property string dateText: Qt.formatDateTime(new Date(), "dddd, d MMMM")
                                text: dateText
                                color: theme.faint; font.pixelSize: 13; font.family: root.cfgFont
                                Timer {
                                    interval: 60000; running: true; repeat: true
                                    onTriggered: dateTextLabel.dateText = Qt.formatDateTime(new Date(), "dddd, d MMMM")
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        
                        // Close button
                        Rectangle {
                            implicitWidth: 36; implicitHeight: 36; radius: 18
                            color: clsMa.containsMouse ? theme.a(theme.iris, 0.25) : theme.a(theme.line, 0.4)
                            border.width: 1; border.color: theme.a(theme.iris, 0.16)
                            Sym { anchors.centerIn: parent; text: "close"; sz: 18; color: theme.frost }
                            MouseArea { id: clsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Qt.quit() }
                        }
                    }
                    
                    // --- Grid panels ---
                    RowLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 20
                        
                        // Left column
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 360; spacing: 16
                            
                            // Resource card
                            Rectangle {
                                Layout.fillWidth: true; Layout.fillHeight: true; radius: root.cfgRadius
                                color: theme.a(theme.line, 0.35); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 14; spacing: 10
                                    Text { text: "RESOURCE MONITOR"; color: theme.faint; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
                                    
                                    // CPU info
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text { text: "CPU"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
                                        Text { text: root.cpuPct + "% (" + root.cpuTemp + "°C)"; color: theme.frost; font.pixelSize: 11; font.bold: true; font.family: "monospace" }
                                        Item { Layout.fillWidth: true }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; height: 32; color: "transparent"
                                        Canvas {
                                            id: cpuCanvas; anchors.fill: parent
                                            onPaint: {
                                                var ctx = getContext("2d");
                                                ctx.clearRect(0,0,width,height);
                                                ctx.lineWidth = 1.5; ctx.strokeStyle = theme.iris;
                                                ctx.beginPath();
                                                var step = width / (root.cpuHistory.length - 1);
                                                for (var i = 0; i < root.cpuHistory.length; i++) {
                                                    var x = i * step;
                                                    var y = height - (root.cpuHistory[i] / 100.0) * height;
                                                    if (i === 0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
                                                }
                                                ctx.stroke();
                                            }
                                        }
                                    }
                                    
                                    // RAM info
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text { text: "Memory"; color: theme.text; font.pixelSize: 11; font.family: root.cfgFont }
                                        Text { text: root.ramUsed + " / " + root.ramTotal + " GiB (" + root.ramPct + "%)"; color: theme.frost; font.pixelSize: 11; font.bold: true; font.family: "monospace" }
                                        Item { Layout.fillWidth: true }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; height: 32; color: "transparent"
                                        Canvas {
                                            id: ramCanvas; anchors.fill: parent
                                            onPaint: {
                                                var ctx = getContext("2d");
                                                ctx.clearRect(0,0,width,height);
                                                ctx.lineWidth = 1.5; ctx.strokeStyle = theme.frost;
                                                ctx.beginPath();
                                                var step = width / (root.ramHistory.length - 1);
                                                for (var i = 0; i < root.ramHistory.length; i++) {
                                                    var x = i * step;
                                                    var y = height - (root.ramHistory[i] / 100.0) * height;
                                                    if (i === 0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
                                                }
                                                ctx.stroke();
                                            }
                                        }
                                    }
                                    
                                    // Disk & Load
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 14
                                        ColumnLayout {
                                            spacing: 1; Layout.fillWidth: true
                                            Text { text: "Disk usage"; color: theme.sub; font.pixelSize: 10 }
                                            Text { text: root.diskInfo + " (" + root.diskPct + "%)"; color: theme.text; font.pixelSize: 11; font.bold: true }
                                        }
                                        ColumnLayout {
                                            spacing: 1; Layout.fillWidth: true
                                            Text { text: "Load average"; color: theme.sub; font.pixelSize: 10 }
                                            Text { text: root.loadAvg; color: theme.text; font.pixelSize: 11; font.bold: true; font.family: "monospace" }
                                        }
                                    }
                                }
                            }
                            
                            // Control Center buttons card
                            Rectangle {
                                Layout.fillWidth: true; height: 160; radius: root.cfgRadius
                                color: theme.a(theme.line, 0.35); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 14; spacing: 10
                                    Text { text: "QUICK COMMANDS"; color: theme.faint; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
                                    GridLayout {
                                        columns: 3; Layout.fillWidth: true; Layout.fillHeight: true; rowSpacing: 8; columnSpacing: 8
                                        
                                        // wifi toggle
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "wifi"; sz: 16; color: theme.frost }
                                                Text { text: "Wi-Fi"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "rfkill toggle wifi"]); Qt.quit() } }
                                        }
                                        // bluetooth toggle
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "bluetooth"; sz: 16; color: theme.frost }
                                                Text { text: "Bluetooth"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "rfkill toggle bluetooth"]); Qt.quit() } }
                                        }
                                        // caffeine toggle
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "coffee"; sz: 16; color: theme.frost }
                                                Text { text: "Caffeine"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "qs -c sea-shell ipc call shell toggleIdle"]); Qt.quit() } }
                                        }
                                        // lock now
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "lock"; sz: 16; color: theme.frost }
                                                Text { text: "Lock Now"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "~/.config/quickshell/sea-shell/sea-lock.sh"]); Qt.quit() } }
                                        }
                                        // sound toggle
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "volume_up"; sz: 16; color: theme.frost }
                                                Text { text: "Mute Audio"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"]); Qt.quit() } }
                                        }
                                        // wallpaper manager
                                        Rectangle {
                                            Layout.fillWidth: true; implicitHeight: 46; radius: 9
                                            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
                                            RowLayout { anchors.centerIn: parent; spacing: 8
                                                Sym { text: "wallpaper"; sz: 16; color: theme.frost }
                                                Text { text: "Wallpaper"; color: theme.text; font.pixelSize: 11 } }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { Quickshell.execDetached(["sh", "-c", "~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"]); Qt.quit() } }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Right column (Todo list)
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 360; radius: root.cfgRadius
                            color: theme.a(theme.line, 0.35); border.width: 1; border.color: theme.a(theme.iris, 0.12)
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 14; spacing: 10
                                Text { text: "STICKY NOTES & TODOS"; color: theme.faint; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1 }
                                
                                // scrollable list of todos
                                ListView {
                                    id: todoListLv
                                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                                    model: root.todoList
                                    delegate: Rectangle {
                                        required property var modelData
                                        required property int index
                                        width: todoListLv.width; height: 36; radius: 6
                                        color: theme.a(theme.line, 0.28)
                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                            Rectangle {
                                                implicitWidth: 16; implicitHeight: 16; radius: 3; color: modelData.done ? theme.iris : "transparent"
                                                border.width: 1.5; border.color: theme.iris
                                                Sym { anchors.centerIn: parent; text: "check"; sz: 11; color: theme.bg; visible: modelData.done }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleTodo(index) }
                                            }
                                            Text {
                                                text: modelData.text; color: modelData.done ? theme.faint : theme.text
                                                font.pixelSize: 11; font.strikeout: modelData.done; Layout.fillWidth: true; font.family: root.cfgFont
                                            }
                                            Sym {
                                                text: "delete"; sz: 15; color: delMa.containsMouse ? theme.bad : theme.faint
                                                MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeTodo(index) }
                                            }
                                        }
                                    }
                                }
                                
                                // Text input to add new todo
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 34; radius: 7
                                    color: theme.a(theme.line, 0.4); border.width: 1; border.color: tdIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 8
                                        TextInput {
                                            id: tdIn; Layout.fillWidth: true; verticalAlignment: TextInput.AlignVCenter
                                            color: theme.text; font.pixelSize: 11; font.family: root.cfgFont; selectByMouse: true
                                            onAccepted: { root.addTodo(text); text = "" }
                                            Text { anchors.verticalCenter: parent.verticalCenter; visible: !tdIn.text; text: "Add a sticky todo note..."; color: theme.faint; font.pixelSize: 11 }
                                        }
                                        Rectangle {
                                            implicitWidth: 24; implicitHeight: 24; radius: 12
                                            color: addMa.containsMouse ? theme.iris : theme.a(theme.line, 0.5)
                                            Sym { anchors.centerIn: parent; text: "add"; sz: 14; color: addMa.containsMouse ? theme.bg : theme.frost }
                                            MouseArea { id: addMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.addTodo(tdIn.text); tdIn.text = "" } }
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
