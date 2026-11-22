// sea-shell — Bluetooth dropdown body (extracted from shell.qml).
import QtQuick

Column {
    id: bt
    property var shellRoot: null
    spacing: 3

    readonly property bool on: !!(shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.enabled)
    readonly property var linked: shellRoot ? shellRoot.btDevices.filter(d => d.connected) : []
    readonly property var paired: shellRoot ? shellRoot.btDevices.filter(d => d.paired || d.bonded || d.connected) : []
    readonly property var nearby: shellRoot ? shellRoot.btDevices.filter(d => !(d.paired || d.bonded || d.connected)) : []

    DropHeader {
        title: "Bluetooth"
        status: !bt.on ? "Off"
              : bt.linked.length === 1 ? "Connected to " + shellRoot.btName(bt.linked[0])
              : bt.linked.length > 1 ? bt.linked.length + " devices connected"
              : (shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.discovering) ? "Looking for devices…" : "On · nothing connected"
        tone: bt.linked.length ? "ok" : "neutral"
        actionIcon: bt.on ? ((shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.discovering) ? "sync" : "search") : ""
        actionBusy: bt.on && !!(shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.discovering)
        onAction: if (shellRoot && shellRoot.btAdapter) shellRoot.btAdapter.discovering = !shellRoot.btAdapter.discovering
        hasSwitch: !!(shellRoot && shellRoot.btAdapter)
        switchOn: bt.on
        onSwitched: v => { if (shellRoot && shellRoot.btAdapter) shellRoot.btAdapter.enabled = v }
    }

    DropSection { visible: bt.on && bt.paired.length > 0; text: "My devices" }
    Repeater {
        model: bt.on ? bt.paired : []
        delegate: DropRow {
            required property var modelData
            icon: shellRoot ? shellRoot.btIcon(modelData) : "bluetooth"
            label: shellRoot ? shellRoot.btName(modelData) : ""
            current: modelData.connected
            busy: modelData.pairing || modelData.state === 2
            value: modelData.batteryAvailable ? Math.round((modelData.battery || 0) * 100) + "%" : ""
            chip: modelData.connected ? "" : "PAIRED"
            hoverIcon: modelData.connected ? "link_off" : ""
            onClicked: modelData.connected ? null : modelData.connect()
            onHoverAction: modelData.disconnect()
        }
    }

    DropSection {
        visible: bt.on && bt.nearby.length > 0
        text: "Nearby"; rule: bt.paired.length > 0
        note: (shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.discovering) ? "Searching" : ""
    }
    Repeater {
        model: bt.on ? bt.nearby.slice(0, 6) : []
        delegate: DropRow {
            required property var modelData
            icon: shellRoot ? shellRoot.btIcon(modelData) : "bluetooth"
            label: shellRoot ? shellRoot.btName(modelData) : ""
            busy: modelData.pairing
            chip: modelData.pairing ? "PAIRING" : ""
            onClicked: modelData.pair()
        }
    }

    Text {
        visible: bt.on && shellRoot && shellRoot.btDevices.length === 0
        width: parent.width; wrapMode: Text.Wrap
        text: (shellRoot && shellRoot.btAdapter && shellRoot.btAdapter.discovering) ? "Searching for nearby devices…" : "No devices yet. Press search to find one."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; topPadding: 4
    }
    Text {
        visible: !bt.on
        width: parent.width; wrapMode: Text.Wrap
        text: "Turn Bluetooth on to see your devices."
        color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans; topPadding: 4
    }
}
