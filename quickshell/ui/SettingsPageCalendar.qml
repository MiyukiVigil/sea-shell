// Settings → Calendar. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 11
    visible: root.tab === 11; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "calendar_month"
        badgeColor: "#FF3B30"
        title: "Calendar & Reminders"
        description: "Import .ics files, subscribe to remote calendars, and configure upcoming event reminders."
    }

    // header + live count
    Section { title: "Calendar"; icon: "calendar_month" }
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Text { text: "Calendar"; color: Tok.ink; font.pixelSize: 13; font.family: Tok.sans }
        Item { Layout.fillWidth: true }
        Rectangle { visible: root.calEvents.length > 0; implicitHeight: 20; implicitWidth: cntTxt.width + 16; radius: Tok.r
            color: theme.a(theme.iris, 0.16); border.width: 1; border.color: theme.a(theme.iris, 0.3)
            Text { id: cntTxt; anchors.centerIn: parent; text: root.calEvents.length + (root.calEvents.length===1 ? " event" : " events")
                color: theme.frost; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } }
    }

    // ---- import card ----
    Rectangle {
        Layout.fillWidth: true; radius: Tok.r; implicitHeight: impCol.implicitHeight + 24
        color: "transparent"
        ColumnLayout {
            id: impCol
            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
            Text { text: "Import events"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
            // url + import link
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                    color: theme.bg; border.width: 1
                    border.color: calUrlIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
                    RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                        Sym { text: "link"; sz: 15; color: theme.faint }
                        TextInput {
                            id: calUrlIn
                            Layout.fillWidth: true
                            verticalAlignment: TextInput.AlignVCenter
                            color: theme.text; font.pixelSize: 12; font.family: Tok.sans
                            clip: true; selectByMouse: true; selectionColor: theme.a(theme.iris, 0.4)
                            Text { anchors.verticalCenter: parent.verticalCenter; visible: calUrlIn.text === ""
                                text: "Paste an .ics link…"; color: theme.faint; font.pixelSize: 12; font.family: Tok.sans }
                            Keys.onReturnPressed: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
                }
                Rectangle {
                    implicitWidth: 108; implicitHeight: 36; radius: Tok.r
                    color: calUrlMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.2)
                    border.width: 1; border.color: theme.iris
                    RowLayout { anchors.centerIn: parent; spacing: 6
                        Sym { text: "download"; sz: 15; color: calUrlMa.containsMouse ? theme.bg : theme.frost }
                        Text { text: "Import"; color: calUrlMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } }
                    MouseArea { id: calUrlMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { if (calUrlIn.text.trim()) { root.importICS(calUrlIn.text.trim()); calUrlIn.text = ""; } } } }
            }
            // file picker + clear
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
                    color: calImpMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.14)
                    border.width: 1; border.color: theme.a(theme.iris, 0.6)
                    RowLayout { anchors.centerIn: parent; spacing: 6
                        Sym { text: "upload_file"; sz: 15; color: calImpMa.containsMouse ? theme.bg : theme.frost }
                        Text { text: "Import .ics file"; color: calImpMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } }
                    MouseArea { id: calImpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickFile("Select Calendar iCalendar (.ics) File", "iCalendar (*.ics) | *.ics", function(path) { root.importICS(path); }) } }
                Rectangle {
                    implicitWidth: 128; implicitHeight: 36; radius: Tok.r
                    visible: root.calEvents.length > 0
                    color: calClrMa.containsMouse ? theme.a(theme.bad, 0.22) : "transparent"
                    border.width: 1; border.color: calClrMa.containsMouse ? theme.bad : theme.a(theme.bad, 0.4)
                    RowLayout { anchors.centerIn: parent; spacing: 6
                        Sym { text: "delete_sweep"; sz: 15; color: theme.bad }
                        Text { text: "Clear all"; color: theme.bad; font.pixelSize: 11; font.family: Tok.sans; font.bold: true } }
                    MouseArea { id: calClrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.clearEvents() } }
            }
            Text { visible: root.calMsg !== ""; text: root.calMsg; color: theme.frost; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: theme.faint
                font.pixelSize: 11
                font.family: Tok.sans
                text: "Paste the secret iCal (.ics) URL from Google Calendar (Settings → your calendar → Integrate calendar), or any other HTTPS .ics feed. No OAuth — the link is enough."
            }
        }
    }

    // ---- subscriptions (imported links are remembered & auto-refreshed) ----
    RowLayout { Layout.fillWidth: true; spacing: 8; visible: root.calSubs.length > 0
        Text { text: "Subscriptions"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
        Sym { text: "sync"; sz: 14; color: resyncMa.containsMouse ? theme.iris : theme.faint
            MouseArea { id: resyncMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.calMsg = "re-syncing subscriptions…"; root.calMutate(["--resync"]) } } }
        Text { text: "Re-sync"; color: resyncMa.containsMouse ? theme.iris : theme.faint; font.pixelSize: 11; font.family: Tok.sans }
    }
    Repeater {
        model: root.calSubs
        delegate: Rectangle {
            required property var modelData
            Layout.fillWidth: true; implicitHeight: 32; radius: Tok.r
            color: theme.a(theme.line, 0.3); border.width: 1; border.color: theme.a(theme.iris, 0.1)
            RowLayout { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 8
                Sym { text: "link"; sz: 14; color: theme.frost }
                Text { text: modelData; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; elide: Text.ElideMiddle; Layout.fillWidth: true }
                Sym { text: "close"; sz: 15; color: unsubMa.containsMouse ? theme.bad : theme.faint
                    MouseArea { id: unsubMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--unsub", modelData]) } } }
        }
    }

    // ---- reminders ----
    RowLayout { Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
        Text { text: "Reminders"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
    }
    Rectangle {
        Layout.fillWidth: true; implicitHeight: 46; radius: Tok.r
        color: "transparent"
        RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
            Sym { text: "notifications_active"; sz: 18; color: root.calRemind ? theme.frost : theme.faint }
            ColumnLayout { spacing: 0; Layout.fillWidth: true
                Text { text: "Notify before events"; color: theme.text; font.pixelSize: 13; font.family: Tok.sans }
                Text { text: "timed: " + root.calLead + " min ahead · all-day: at 8:00 am"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans } }
            Rectangle { implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                color: root.calRemind ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: root.calRemind ? theme.iris : theme.a(theme.iris, 0.3)
                Rectangle { width: 16; height: 16; radius: Tok.r; y: 3; x: root.calRemind ? 27 : 3; color: root.calRemind ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","remind", root.calRemind ? "false" : "true"]) } } }
    }
    RowLayout { Layout.fillWidth: true; spacing: 6; visible: root.calRemind
        Text { text: "Lead"; color: theme.sub; font.pixelSize: 11; font.family: Tok.sans; Layout.rightMargin: 4 }
        Repeater { model: [10, 15, 30, 60]
            delegate: Rectangle { required property var modelData
                readonly property bool sel: root.calLead === modelData
                implicitWidth: 48; implicitHeight: 26; radius: Tok.r
                color: sel ? theme.iris : (ldMa.containsMouse ? theme.a(theme.iris, 0.16) : theme.a(theme.line, 0.4)); border.width: 1; border.color: sel ? theme.iris : theme.a(theme.iris, 0.14)
                Text { anchors.centerIn: parent; text: modelData + "m"; color: sel ? theme.bg : theme.sub; font.pixelSize: 11; font.family: Tok.sans; font.bold: sel }
                MouseArea { id: ldMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.calMutate(["--set","lead", "" + modelData]) } } }
        Item { Layout.fillWidth: true }
    }

    // ---- events list header + refresh ----
    RowLayout {
        Layout.fillWidth: true; spacing: 8; Layout.topMargin: 2
        Text { text: "Events"; color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.1) }
        Sym { text: "refresh"; sz: 15; color: calRefMa.containsMouse ? theme.iris : theme.faint
            MouseArea { id: calRefMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: reloadEventsProc.running = true } }
    }

    Text { visible: root.calEvents.length === 0; text: "No events yet. Import an .ics file or link above.";
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans; Layout.fillWidth: true; wrapMode: Text.Wrap }

    Repeater {
        model: root.calSorted
        delegate: Rectangle {
            required property var modelData
            readonly property var rel: root.evRel(modelData.date)
            Layout.fillWidth: true; implicitHeight: bodyRow.implicitHeight + 16; radius: Tok.r
            opacity: rel.past ? 0.45 : 1
            color: theme.a(theme.line, 0.32); border.width: 1
            border.color: rel.soon ? theme.a(theme.iris, 0.4) : theme.a(theme.iris, 0.1)
            RowLayout {
                id: bodyRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 8; anchors.rightMargin: 12; spacing: 12
                // date chip
                Rectangle {
                    implicitWidth: 44; implicitHeight: 42; radius: Tok.r
                    color: rel.soon ? theme.iris : theme.a(theme.iris, 0.14)
                    ColumnLayout { anchors.centerIn: parent; spacing: 0
                        Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(root.evDate(modelData.date), "ddd").toUpperCase()
                            color: rel.soon ? theme.bg : theme.frost; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                        Text { Layout.alignment: Qt.AlignHCenter; text: (""+modelData.date).slice(8)
                            color: rel.soon ? theme.bg : theme.text; font.pixelSize: 17; font.family: Tok.sans; font.bold: true } }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 2
                    Text { text: modelData.title; color: theme.text; font.pixelSize: 12; font.family: Tok.sans; font.bold: true
                        Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                    RowLayout { spacing: 6
                        Text { text: rel.t; color: rel.past ? theme.faint : theme.frost; font.pixelSize: 11; font.family: Tok.sans; font.bold: true }
                        Text { visible: !!modelData.time; text: "· " + (modelData.time||""); color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                        Text { text: "· " + Qt.formatDate(root.evDate(modelData.date), "d MMM yyyy"); color: theme.faint; font.pixelSize: 11; font.family: Tok.sans }
                    }
                }
                Sym { text: "close"; sz: 16; Layout.alignment: Qt.AlignVCenter
                    color: delMa.containsMouse ? theme.bad : theme.a(theme.faint, 0.55)
                    MouseArea { id: delMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.calMutate(["--delete", root.evKey(modelData)]) } }
            }
        }
    }
}
