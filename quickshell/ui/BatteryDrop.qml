// sea-shell — Battery, Power & Hybrid dGPU Wake Monitor dropdown body (extracted from shell.qml).
// Shows charge & ETA, power profiles, battery wear health, zero-wake hybrid dGPU status
// (lists exact processes holding /dev/nvidia* open), AC/Battery auto-switch toggle,
// and battery charge limit (auto-shown on laptops supporting charge_control_end_threshold).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

Column {
    id: bd
    property var shellRoot: null
    property bool charging: false
    property int pct: 0
    property bool active: false
    spacing: 4

    readonly property string dgpuScript: Qt.resolvedUrl("sea-dgpu.py").toString().replace("file://", "")
    property var dgpuInfo: ({ ok: false, has_dgpu: false, gpu: {}, holders: [], charge_limit: { supported: false } })

    function refreshDgpu() {
        if (!dgpuProc.running) dgpuProc.running = true;
    }
    onActiveChanged: if (active) refreshDgpu()
    Component.onCompleted: if (active) refreshDgpu()

    Process {
        id: dgpuProc
        command: ["python3", bd.dgpuScript]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(text.trim() || "{}");
                    if (j && j.ok) bd.dgpuInfo = j;
                } catch (e) {}
            }
        }
    }

    function setChargeLimit(lim) {
        Quickshell.execDetached(["python3", bd.dgpuScript, "--limit", "" + lim]);
        limitRefresh.restart();
    }
    Timer { id: limitRefresh; interval: 350; onTriggered: bd.refreshDgpu() }

    function span(sec) {
        if (!(sec > 0)) return "";
        var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
        return h > 0 ? h + " h " + m + " min" : m + " min";
    }
    readonly property var dev: UPower.displayDevice
    readonly property string eta: !dev ? "" : bd.charging
        ? (dev.timeToFull > 0 ? "full in " + span(dev.timeToFull) : "")
        : (dev.timeToEmpty > 0 ? span(dev.timeToEmpty) + " left" : "")

    DropHeader {
        title: "Battery"
        status: (bd.charging ? (bd.pct >= 100 ? "Fully charged" : "Charging") : "On battery") + (bd.eta ? " · " + bd.eta : "")
        tone: bd.charging ? "ok" : bd.pct <= 10 ? "crit" : bd.pct <= 20 ? "warn" : "neutral"
        value: bd.pct + "%"
    }

    DropSection { text: "Power profile" }
    Repeater {
        model: [
            { k: "performance", i: "speed",   l: "Performance", d: "Fastest, fans and battery work harder" },
            { k: "balanced",    i: "balance", l: "Balanced",    d: "The everyday default" },
            { k: "power-saver", i: "eco",     l: "Power saver", d: "Slower, quieter, longer on battery" }
        ]
        delegate: DropRow {
            required property var modelData
            icon: modelData.i; label: modelData.l; sub: modelData.d
            current: !!(shellRoot && shellRoot.powerProfile === modelData.k)
            onClicked: if (shellRoot) shellRoot.setProfile(modelData.k)
        }
    }

    // ---- AC / Battery automatic profile + 60Hz switcher ----
    DropRow {
        icon: "auto_awesome"
        label: "Auto battery saver"
        sub: "Power saver + 60 Hz on battery, restore on AC"
        current: !!(shellRoot && shellRoot.cfgAutoPowerBattery)
        value: (shellRoot && shellRoot.cfgAutoPowerBattery) ? "ON" : "OFF"
        onClicked: if (shellRoot) shellRoot.toggleAutoPowerBattery()
    }

    // ---- Hybrid dGPU wake monitor (zero NVML wake) ----
    readonly property bool hasDgpu: !!(bd.dgpuInfo && bd.dgpuInfo.has_dgpu)
    readonly property string dgpuState: (bd.dgpuInfo && bd.dgpuInfo.gpu && bd.dgpuInfo.gpu.runtime_status) || "unknown"
    readonly property bool dgpuAwake: bd.dgpuState === "active"
    readonly property var dgpuHolders: (bd.dgpuInfo && bd.dgpuInfo.holders) || []

    DropSection {
        visible: bd.hasDgpu
        text: ((bd.dgpuInfo && bd.dgpuInfo.gpu && bd.dgpuInfo.gpu.vendor) || "dGPU") + " power"
        note: bd.dgpuAwake ? "Awake" : (bd.dgpuState === "suspended" ? "Sleeping · 0 W" : bd.dgpuState)
        rule: true
    }
    Rectangle {
        visible: bd.hasDgpu
        width: parent.width
        implicitHeight: dgpuCol.implicitHeight + 14
        radius: Tok.r
        color: bd.dgpuAwake ? Tok.alpha(Tok.warn, 0.10) : Tok.alpha(Tok.ok, 0.10)
        border.width: 1
        border.color: bd.dgpuAwake ? Tok.alpha(Tok.warn, 0.35) : Tok.alpha(Tok.ok, 0.35)
        Column {
            id: dgpuCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 10 }
            spacing: 4
            Row {
                width: parent.width; spacing: 6
                Rectangle {
                    width: 7; height: 7; radius: 4; anchors.verticalCenter: parent.verticalCenter
                    color: bd.dgpuAwake ? Tok.warn : Tok.ok
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: bd.dgpuAwake
                        ? (bd.dgpuHolders.length > 0 ? "Kept awake by " + bd.dgpuHolders.length + (bd.dgpuHolders.length === 1 ? " app" : " apps") : "Active (no user fds)")
                        : "Suspended (saving battery)"
                    color: Tok.ink; font.pixelSize: 11; font.family: Tok.sans; font.weight: Font.Medium
                }
            }
            Flow {
                visible: bd.dgpuAwake && bd.dgpuHolders.length > 0
                width: parent.width; spacing: 4
                Repeater {
                    model: bd.dgpuHolders
                    delegate: Rectangle {
                        required property var modelData
                        implicitHeight: 20; implicitWidth: hTxt.implicitWidth + 10; radius: Tok.rSmall
                        color: Tok.surface; border.width: 1; border.color: Tok.rule
                        Text {
                            id: hTxt; anchors.centerIn: parent
                            text: modelData.name + (modelData.count > 1 ? " ×" + modelData.count : "")
                            color: Tok.ink2; font.pixelSize: 10; font.family: Tok.mono
                        }
                    }
                }
            }
        }
    }

    // ---- Battery charge limit (only shown on laptops exposing charge_control_end_threshold) ----
    readonly property var chLim: (bd.dgpuInfo && bd.dgpuInfo.charge_limit) || ({ supported: false })
    DropSection {
        visible: !!bd.chLim.supported
        text: "Charge limit"
        note: bd.chLim.limit > 0 ? bd.chLim.limit + "%" : ""
        rule: true
    }
    Row {
        visible: !!bd.chLim.supported
        width: parent.width; spacing: 6
        Repeater {
            model: [60, 80, 100]
            delegate: Rectangle {
                required property int modelData
                readonly property bool cur: bd.chLim.limit === modelData
                width: (parent.width - 12) / 3; height: 28; radius: Tok.r
                color: cur ? Tok.accent : (clMa.containsMouse ? Tok.raised : Tok.surface)
                border.width: cur ? 0 : 1; border.color: Tok.rule
                Text {
                    anchors.centerIn: parent; text: modelData + "%"
                    color: cur ? Tok.accentInk : Tok.ink2
                    font.pixelSize: 11; font.family: Tok.mono; font.weight: cur ? Font.DemiBold : Font.Normal
                }
                MouseArea {
                    id: clMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    enabled: !!bd.chLim.writable
                    onClicked: bd.setChargeLimit(modelData)
                }
            }
        }
    }

    // ---- Battery wear health ----
    DropSection { text: "Health"; visible: !!(shellRoot && shellRoot.batHealth >= 0); rule: true }
    DropRow {
        visible: !!(shellRoot && shellRoot.batHealth >= 0)
        icon: "battery_profile"
        label: (shellRoot ? shellRoot.batHealth : 0) + "% of original capacity"
        sub: (shellRoot && shellRoot.batCycles >= 0) ? shellRoot.batCycles + " charge cycles" : ""
        value: !shellRoot ? "" : (shellRoot.batHealth >= 80 ? "Good" : (shellRoot.batHealth >= 60 ? "Worn" : "Replace soon"))
        onClicked: if (shellRoot) { shellRoot.openPop = ""; shellRoot.openSettings(6) }
    }
}
