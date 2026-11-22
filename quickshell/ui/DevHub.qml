// Dev tab for the dashboard — GitHub contributions, recent commits, watched repos, AI,
// and live listening localhost ports & Docker/Podman containers.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

Item {
    id: hub
    property bool active: false
    property var github: ({ ok: false, days: [], weeks: [], repos: [], commits: [], today: 0, streak: 0, year: 0, login: "", error: "" })
    property var aiTools: []
    property var aiShown: null
    property string aiBarValue: ""
    property var livePorts: []
    property var liveContainers: []
    property var failedServices: []
    property var coreServices: []
    property string logUnit: ""
    property string logText: ""
    readonly property string portsScript: Qt.resolvedUrl("sea-ports.py").toString().replace("file://", "")
    readonly property string svcScript: Qt.resolvedUrl("sea-services.py").toString().replace("file://", "")
    signal openGithub()
    signal refreshGithub()
    signal focusAi(string id)

    function refreshPorts() {
        if (!portsProc.running) portsProc.running = true;
        if (!svcProc.running) svcProc.running = true;
    }
    onActiveChanged: if (active) refreshPorts()
    Component.onCompleted: if (active) refreshPorts()

    Process {
        id: svcProc
        command: ["python3", hub.svcScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.ok) {
                        hub.failedServices = j.failed || [];
                        hub.coreServices = j.core || [];
                    }
                } catch (e) {}
            }
        }
    }
    Process {
        id: svcLogProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.ok) { hub.logUnit = j.unit || ""; hub.logText = j.lines || ""; }
                } catch (e) {}
            }
        }
    }
    function peekLogs(unit, scope) {
        if (hub.logUnit === unit) { hub.logUnit = ""; hub.logText = ""; return; }
        svcLogProc.command = ["python3", hub.svcScript, "logs", unit, scope];
        svcLogProc.running = false;
        svcLogProc.running = true;
    }
    function restartSvc(unit, scope) {
        Quickshell.execDetached(["python3", hub.svcScript, "restart", unit, scope]);
        portsAfterKill.restart();
    }

    Process {
        id: portsProc
        command: ["python3", hub.portsScript, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.ok) {
                        hub.livePorts = j.ports || [];
                        hub.liveContainers = j.containers || [];
                    }
                } catch (e) {}
            }
        }
    }
    Timer { id: portsAfterKill; interval: 450; onTriggered: hub.refreshPorts() }
    function killPort(pid) {
        if (!pid) return;
        Quickshell.execDetached(["python3", hub.portsScript, "kill", "" + pid]);
        portsAfterKill.restart();
    }
    function stopContainer(cid) {
        if (!cid) return;
        Quickshell.execDetached(["python3", hub.portsScript, "container-stop", "" + cid]);
        portsAfterKill.restart();
    }

    readonly property color groupFill: Tok.surface
    readonly property color groupRule: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)
    readonly property color cardSheen: Tok.light ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(1, 1, 1, 0.045)
    readonly property color rowHover: Tok.alpha(Tok.ink, Tok.light ? 0.05 : 0.075)
    readonly property color track: Tok.alpha(Tok.ink, Tok.light ? 0.085 : 0.11)

    function levelColor(level) {
        var n = Number(level) || 0;
        if (n <= 0) return track;
        if (n === 1) return Tok.alpha(Tok.accent, 0.28);
        if (n === 2) return Tok.alpha(Tok.accent, 0.48);
        if (n === 3) return Tok.alpha(Tok.accent, 0.72);
        return Tok.accent;
    }
    function ciColor(ci) {
        if (ci === "ok") return Tok.ok;
        if (ci === "fail") return Tok.crit;
        if (ci === "running") return Tok.warn;
        return Tok.ink3;
    }
    function ciLabel(ci) {
        if (ci === "ok") return "Passing";
        if (ci === "fail") return "Failing";
        if (ci === "running") return "Running";
        if (ci === "none") return "No runs";
        return "Unknown";
    }
    function shortRepo(full) {
        var s = "" + (full || "");
        var i = s.lastIndexOf("/");
        return i >= 0 ? s.slice(i + 1) : s;
    }

    component Group: ColumnLayout {
        id: grp
        property string title: ""
        property string note: ""
        property bool fill: false
        default property alias content: body.data
        Layout.fillWidth: true
        Layout.fillHeight: grp.fill
        spacing: Tok.s2
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Tok.s1
            Layout.rightMargin: Tok.s1
            IndText { text: grp.title; sz: Tok.tDense; font.weight: Font.Bold }
            Item { Layout.fillWidth: true }
            IndText { visible: grp.note !== ""; text: grp.note; sz: Tok.tData; color: Tok.ink3 }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: grp.fill
            implicitHeight: body.implicitHeight + Tok.s4 * 2
            radius: Math.min(18, Tok.r + 4)
            color: hub.groupFill
            border.width: 1
            border.color: hub.groupRule
            clip: true
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 1; leftMargin: 10; rightMargin: 10 }
                height: 1
                color: hub.cardSheen
            }
            ColumnLayout {
                id: body
                anchors {
                    top: parent.top; left: parent.left; right: parent.right
                    bottom: grp.fill ? parent.bottom : undefined
                    margins: Tok.s4
                }
                spacing: Tok.s3
            }
        }
    }

    component StatChip: Row {
        property string icon: ""
        property string text: ""
        spacing: 4
        Text {
            visible: icon !== ""
            text: icon; font.family: "Material Symbols Outlined"; font.pixelSize: 13
            color: Tok.ink3; anchors.verticalCenter: parent.verticalCenter
        }
        IndText { text: parent.text; sz: Tok.tData; color: Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
    }

    RowLayout {
        anchors.fill: parent
        spacing: Tok.s6

        // -------- left: overview + recent commits --------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 3
            spacing: Tok.s4

            Group {
                title: "GitHub"
                note: github.ok ? ("@" + (github.login || "")) : ""
                fill: true

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tok.s2
                    Repeater {
                        model: [
                            { v: String(github.today || 0), l: "today" },
                            { v: String(github.streak || 0), l: "streak" },
                            { v: String(github.year || 0), l: "this year" }
                        ]
                        delegate: Item {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: col.implicitHeight
                            Column {
                                id: col
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 2
                                IndText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.v; sz: 26; mono: true; font.weight: Font.DemiBold
                                }
                                IndText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.l; sz: Tok.tData; color: Tok.ink3
                                }
                            }
                        }
                    }
                }

                Item {
                    id: gridHost
                    Layout.fillWidth: true
                    // Fixed height (not derived from cell) so Layout can assign width first;
                    // cells then grow to fill that box. A height↔cell binding left them tiny.
                    Layout.preferredHeight: 196
                    visible: github.ok && (github.weeks || []).length > 0
                    readonly property int weekCount: (github.weeks || []).length
                    readonly property int gap: 3
                    readonly property int cell: {
                        var n = gridHost.weekCount;
                        if (n <= 0) return 12;
                        var byW = Math.floor((gridHost.width - gridHost.gap * Math.max(0, n - 1)) / n);
                        var byH = Math.floor((gridHost.height - gridHost.gap * 6) / 7);
                        return Math.max(10, Math.min(byW, byH));
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: gridHost.gap
                        Repeater {
                            model: github.weeks || []
                            delegate: Column {
                                required property var modelData
                                spacing: gridHost.gap
                                Repeater {
                                    model: modelData
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: gridHost.cell; height: gridHost.cell
                                        radius: Math.max(2, gridHost.cell * 0.22)
                                        color: hub.levelColor(modelData.level)
                                    }
                                }
                            }
                        }
                    }
                }

                // Recent commits fill the leftover height
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Tok.s2
                    IndText { text: "Recent commits"; sz: Tok.tData; color: Tok.ink3; font.weight: Font.DemiBold }

                    ListView {
                        id: commitList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: Tok.s1
                        boundsBehavior: Flickable.StopAtBounds
                        model: github.commits || []
                        delegate: Rectangle {
                            required property var modelData
                            width: commitList.width
                            height: cCol.implicitHeight + Tok.s3
                            radius: Tok.r
                            color: cMa.containsMouse ? hub.rowHover : "transparent"
                            ColumnLayout {
                                id: cCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Tok.s2 }
                                spacing: 2
                                IndText {
                                    Layout.fillWidth: true
                                    text: modelData.msg || ""
                                    sz: Tok.tDense; font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s2
                                    IndText {
                                        text: hub.shortRepo(modelData.repo)
                                        sz: Tok.tData; color: Tok.accent; font.weight: Font.Medium
                                    }
                                    IndText {
                                        visible: (modelData.sha || "") !== ""
                                        text: modelData.sha || ""
                                        sz: Tok.tData; mono: true; color: Tok.ink3
                                    }
                                    Item { Layout.fillWidth: true }
                                    IndText {
                                        text: modelData.when || ""
                                        sz: Tok.tData; color: Tok.ink3
                                    }
                                }
                            }
                            MouseArea {
                                id: cMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: if (modelData.url) Quickshell.execDetached(["xdg-open", modelData.url])
                            }
                        }
                    }

                    IndText {
                        visible: !(github.commits || []).length
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: github.ok ? "No recent pushes in your event feed" : (github.error || "Sign in with gh auth login")
                        sz: Tok.tDense; color: Tok.ink3; wrapMode: Text.WordWrap
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tok.s2
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 36
                        radius: Tok.r
                        color: openMa.containsMouse ? Tok.accentWash : hub.track
                        border.width: 1; border.color: Tok.alpha(Tok.accent, 0.25)
                        IndText {
                            anchors.centerIn: parent
                            text: github.ok ? ("Open github.com/" + github.login) : "Open GitHub"
                            sz: Tok.tData; color: Tok.accent; font.weight: Font.Medium
                        }
                        MouseArea { id: openMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.openGithub() }
                    }
                    Rectangle {
                        implicitWidth: refreshRow.implicitWidth + Tok.s4
                        implicitHeight: 36
                        radius: Tok.r
                        color: refreshMa.containsMouse ? hub.rowHover : hub.track
                        border.width: 1; border.color: hub.groupRule
                        Row {
                            id: refreshRow; anchors.centerIn: parent; spacing: 6
                            Text { text: "refresh"; font.family: "Material Symbols Outlined"; font.pixelSize: 16; color: Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
                            IndText { text: "Refresh"; sz: Tok.tData; color: Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea { id: refreshMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.refreshGithub() }
                    }
                }
            }
        }

        // -------- right: richer repo cards + AI --------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 2
            spacing: Tok.s4

            Group {
                title: "Watched repos"
                note: (github.repos || []).length ? (github.repos.length + " tracked") : ""
                fill: true

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Tok.s2

                    Repeater {
                        model: github.repos || []
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 72
                            Layout.maximumHeight: 110
                            radius: Tok.r
                            color: repoMa.containsMouse ? hub.rowHover : Tok.alpha(Tok.ink, Tok.light ? 0.03 : 0.04)
                            border.width: 1
                            border.color: hub.groupRule
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: Tok.s3; spacing: Tok.s1
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tok.s2
                                    Rectangle {
                                        width: 9; height: 9; radius: 4.5
                                        color: hub.ciColor(modelData.ci)
                                    }
                                    IndText {
                                        text: modelData.repo || ""
                                        sz: Tok.tDense; font.weight: Font.DemiBold
                                        elide: Text.ElideMiddle; Layout.fillWidth: true
                                    }
                                    Text {
                                        text: "open_in_new"
                                        font.family: "Material Symbols Outlined"
                                        font.pixelSize: 15
                                        color: Tok.ink3
                                    }
                                }
                                IndText {
                                    visible: (modelData.desc || "") !== ""
                                    Layout.fillWidth: true
                                    text: modelData.desc || ""
                                    sz: Tok.tData; color: Tok.ink3
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: Tok.s3
                                    StatChip { icon: "star"; text: String(modelData.stars || 0) }
                                    StatChip { icon: "fork_right"; text: String(modelData.forks || 0) }
                                    StatChip { icon: "merge"; text: (modelData.prs || 0) + " PR" }
                                    StatChip { icon: "bug_report"; text: (modelData.issues || 0) + " iss" }
                                    StatChip {
                                        visible: (modelData.lang || "") !== ""
                                        icon: "code"
                                        text: modelData.lang || ""
                                    }
                                    StatChip {
                                        visible: (modelData.pushed || "") !== ""
                                        icon: "schedule"
                                        text: modelData.pushed || ""
                                    }
                                    StatChip {
                                        icon: "check_circle"
                                        text: hub.ciLabel(modelData.ci)
                                    }
                                }
                            }
                            MouseArea {
                                id: repoMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: if (modelData.url) Quickshell.execDetached(["xdg-open", modelData.url])
                            }
                        }
                    }

                    IndText {
                        visible: !(github.repos || []).length
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: "Add repos to ~/.config/sea-shell/github-repos.json"
                        sz: Tok.tDense; color: Tok.ink3
                    }
                }
            }

            Group {
                title: "AI plans"
                note: aiBarValue

                Repeater {
                    model: Math.min(4, aiTools.length)
                    delegate: Rectangle {
                        required property int index
                        readonly property var plan: hub.aiTools[index]
                        Layout.fillWidth: true
                        implicitHeight: 44
                        radius: Tok.r
                        color: (hub.aiShown && plan && plan.id === hub.aiShown.id) ? Tok.accentWash : (aiMa.containsMouse ? hub.rowHover : "transparent")
                        RowLayout {
                            anchors.fill: parent; anchors.margins: Tok.s2; spacing: Tok.s3
                            AiMark { width: plan && plan.with ? 28 : 18; height: 18; tool: plan ? plan.id : "claude"; also: (plan && plan.with) ? plan.with : "" }
                            IndText { text: plan ? plan.name : ""; sz: Tok.tDense; Layout.fillWidth: true }
                            IndText {
                                text: plan ? (plan.unit === "left" ? (Number(plan.today).toFixed(0) + "%") : (plan.todayLabel || "")) : ""
                                sz: Tok.tData; mono: true; color: Tok.ink2
                            }
                        }
                        MouseArea { id: aiMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (plan) hub.focusAi(plan.id) }
                    }
                }
                IndText {
                    visible: aiTools.length === 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: "No AI usage yet"
                    sz: Tok.tDense; color: Tok.ink3
                }
            }

            // ---- Live Localhost Ports & Containers ----
            Group {
                title: "Local ports & containers"
                note: (hub.livePorts.length + hub.liveContainers.length) > 0
                    ? (hub.livePorts.length + " ports" + (hub.liveContainers.length ? " · " + hub.liveContainers.length + " containers" : ""))
                    : "idle"

                Flow {
                    visible: hub.livePorts.length > 0
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: hub.livePorts.slice(0, 8)
                        delegate: Rectangle {
                            id: portChip
                            required property var modelData
                            implicitHeight: 28
                            implicitWidth: prRow.implicitWidth + 14
                            radius: Tok.r
                            color: prMa.containsMouse ? hub.rowHover : Tok.alpha(Tok.ink, Tok.light ? 0.035 : 0.05)
                            border.width: 1; border.color: hub.groupRule
                            MouseArea {
                                id: prMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: portChip.modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (portChip.modelData.url) Quickshell.execDetached(["xdg-open", portChip.modelData.url])
                            }
                            Row {
                                id: prRow; anchors.centerIn: parent; spacing: 6
                                Rectangle { width: 6; height: 6; radius: 3; color: Tok.ok; anchors.verticalCenter: parent.verticalCenter }
                                IndText { text: ":" + portChip.modelData.port; sz: Tok.tData; mono: true; color: Tok.accent; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                IndText { text: portChip.modelData.proc; sz: Tok.tData; color: Tok.ink2; anchors.verticalCenter: parent.verticalCenter }
                                Rectangle {
                                    visible: portChip.modelData.own && portChip.modelData.pid > 0
                                    width: 18; height: 18; radius: 9; anchors.verticalCenter: parent.verticalCenter
                                    color: pkMa.containsMouse ? Tok.critWash : "transparent"
                                    Text { anchors.centerIn: parent; text: "close"; font.family: "Material Symbols Outlined"; font.pixelSize: 12; color: pkMa.containsMouse ? Tok.crit : Tok.ink3 }
                                    MouseArea { id: pkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.killPort(portChip.modelData.pid) }
                                }
                            }
                        }
                    }
                }

                Repeater {
                    model: hub.liveContainers.slice(0, 4)
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true; implicitHeight: 30; radius: Tok.r
                        color: ctMa.containsMouse ? hub.rowHover : "transparent"
                        MouseArea { id: ctMa; anchors.fill: parent; hoverEnabled: true }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6; spacing: 8
                            Text { text: "deployed_code"; font.family: "Material Symbols Outlined"; font.pixelSize: 15; color: Tok.accent }
                            IndText { text: modelData.name; sz: Tok.tData; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                            IndText { text: modelData.status; sz: Tok.tLabel; color: Tok.ink3; elide: Text.ElideRight }
                            Rectangle {
                                implicitWidth: 22; implicitHeight: 22; radius: Tok.rSmall
                                color: csMa.containsMouse ? Tok.critWash : "transparent"
                                Text { anchors.centerIn: parent; text: "stop_circle"; font.family: "Material Symbols Outlined"; font.pixelSize: 14; color: csMa.containsMouse ? Tok.crit : Tok.ink3 }
                                MouseArea { id: csMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.stopContainer(modelData.id) }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    IndText {
                        visible: hub.livePorts.length === 0 && hub.liveContainers.length === 0
                        text: "No local dev servers listening"
                        sz: Tok.tData; color: Tok.ink3
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitHeight: 24; implicitWidth: rpT.implicitWidth + 14; radius: Tok.rSmall
                        color: rpMa.containsMouse ? hub.rowHover : hub.track
                        IndText { id: rpT; anchors.centerIn: parent; text: "Rescan"; sz: Tok.tLabel; color: Tok.ink2 }
                        MouseArea { id: rpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.refreshPorts() }
                    }
                }

                // ---- Systemd Service Health + Quick Log Peek ----
                Rectangle { visible: hub.coreServices.length > 0 || hub.failedServices.length > 0; Layout.fillWidth: true; implicitHeight: 1; color: hub.groupRule }
                RowLayout {
                    visible: hub.coreServices.length > 0 || hub.failedServices.length > 0
                    Layout.fillWidth: true
                    IndText { text: "Services"; sz: Tok.tLabel; color: Tok.ink3; font.weight: Font.DemiBold }
                    Item { Layout.fillWidth: true }
                    IndText {
                        visible: hub.failedServices.length > 0
                        text: hub.failedServices.length + " failed"
                        sz: Tok.tLabel; color: Tok.crit; font.weight: Font.DemiBold
                    }
                }
                Flow {
                    visible: hub.coreServices.length > 0 || hub.failedServices.length > 0
                    Layout.fillWidth: true; spacing: 5
                    Repeater {
                        model: hub.failedServices.concat(hub.coreServices)
                        delegate: Rectangle {
                            id: svcChip
                            required property var modelData
                            readonly property bool ok: modelData.state === "active"
                            readonly property bool bad: modelData.state === "failed"
                            implicitHeight: 24; implicitWidth: svRow.implicitWidth + 12; radius: Tok.rSmall
                            color: hub.logUnit === modelData.unit ? Tok.accentWash : (svMa.containsMouse ? hub.rowHover : Tok.alpha(Tok.ink, Tok.light ? 0.03 : 0.05))
                            border.width: 1; border.color: bad ? Tok.crit : (hub.logUnit === modelData.unit ? Tok.accent : hub.groupRule)
                            MouseArea {
                                id: svMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: hub.peekLogs(svcChip.modelData.unit, svcChip.modelData.scope)
                            }
                            Row {
                                id: svRow; anchors.centerIn: parent; spacing: 5
                                Rectangle { width: 6; height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter; color: svcChip.ok ? Tok.ok : (svcChip.bad ? Tok.crit : Tok.ink3) }
                                IndText { text: svcChip.modelData.label; sz: Tok.tLabel; color: Tok.ink; anchors.verticalCenter: parent.verticalCenter }
                                Rectangle {
                                    visible: svcChip.modelData.scope === "user" && !svcChip.ok
                                    width: 16; height: 16; radius: 8; anchors.verticalCenter: parent.verticalCenter
                                    color: srMa.containsMouse ? Tok.accentWash : "transparent"
                                    Text { anchors.centerIn: parent; text: "refresh"; font.family: "Material Symbols Outlined"; font.pixelSize: 12; color: Tok.accent }
                                    MouseArea { id: srMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hub.restartSvc(svcChip.modelData.unit, svcChip.modelData.scope) }
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    visible: hub.logUnit !== ""
                    Layout.fillWidth: true; implicitHeight: 88; radius: Tok.rSmall
                    color: Tok.sunken; border.width: 1; border.color: hub.groupRule; clip: true
                    Flickable {
                        anchors.fill: parent; anchors.margins: 6
                        contentWidth: width; contentHeight: logOut.implicitHeight; clip: true
                        Text { id: logOut; width: parent.width; text: hub.logText; color: Tok.ink2; font.family: Tok.mono; font.pixelSize: 10; wrapMode: Text.WrapAnywhere }
                    }
                }
            }
        }
    }
}
