import QtQuick
import QtQuick.Layouts

Rectangle {
    id: preview
    property bool baseLight: false
    property color baseAccent: "#63c7dd"
    property string baseFont: "sans-serif"
    property bool baseSolid: true
    property string baseIconTheme: "breeze"
    property var iconCatalog: []
    property var fonts: ["sans-serif", "monospace"]
    property string barFill: "matugen"
    property bool editing: false
    property bool draftLight: false
    property color draftAccent: "#63c7dd"
    property string draftFont: "sans-serif"
    property bool draftSolid: true
    property string draftIcons: "breeze"
    readonly property bool light: editing ? draftLight : baseLight
    readonly property color accent: editing ? draftAccent : baseAccent
    readonly property string fontName: editing ? draftFont : baseFont
    readonly property bool solid: editing ? draftSolid : baseSolid
    readonly property string icons: editing ? draftIcons : baseIconTheme
    readonly property color ink: light ? "#18202b" : "#e6eaf0"
    readonly property color muted: light ? "#586171" : "#a4adbc"
    readonly property color ground: light ? "#f0f2f7" : "#11151d"
    readonly property color card: light ? "#ffffff" : "#1b2230"
    readonly property color rule: light ? "#d3d8e2" : "#323c4e"
    readonly property color barColor: barFill === "black" ? "#0a0d12"
        : barFill === "white" ? "#f5f8fb"
        : Qt.hsla(accent.hslHue >= 0 ? accent.hslHue : 0.55, light ? 0.18 : 0.46, light ? 0.90 : 0.135, 1)
    signal applied(bool light, color accent, string fontName, bool solid, string iconTheme)
    function begin() {
        if (editing) return;
        draftLight = baseLight; draftAccent = baseAccent; draftFont = baseFont;
        draftSolid = baseSolid; draftIcons = baseIconTheme; editing = true;
    }
    function iconUrl(name) {
        for (var i = 0; i < iconCatalog.length; i++) {
            var entry = iconCatalog[i];
            if (entry.name === icons) return (light ? entry.light : entry.dark)[name] || "";
        }
        return "";
    }
    implicitHeight: content.implicitHeight + 32
    radius: 18; color: ground; border.width: 1; border.color: rule
    Behavior on color { ColorAnimation { duration: 140 } }
    component Choice: Rectangle {
        id: choice
        property string label: ""
        property bool selected: false
        signal picked()
        implicitWidth: labelText.implicitWidth + 24; implicitHeight: 30
        radius: 10; color: selected ? preview.accent : preview.card
        border.width: 1; border.color: selected ? preview.accent : preview.rule
        Behavior on color { ColorAnimation { duration: 120 } }
        Text { id: labelText; anchors.centerIn: parent; text: choice.label
            color: choice.selected ? (preview.accent.hslLightness > 0.55 ? "#111827" : "#ffffff") : preview.ink
            font.pixelSize: 11; font.family: preview.baseFont }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: choice.picked() }
    }
    ColumnLayout {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Text { text: "Try your look"; color: preview.ink; font.pixelSize: 16; font.bold: true; font.family: preview.baseFont }
            Item { Layout.fillWidth: true }
            Text { text: preview.editing ? "Preview only · not applied" : "Current appearance"
                color: preview.muted; font.pixelSize: 10; font.family: preview.baseFont }
        }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 150; radius: 14; color: preview.card
            border.width: 1; border.color: preview.rule
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                height: 28; radius: 9
                color: Qt.rgba(preview.barColor.r, preview.barColor.g, preview.barColor.b, 1)
                Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "sea-shell   1   2   3"; color: preview.ink; font.pixelSize: 11; font.family: preview.fontName }
                Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "06:30   100%"; color: preview.ink; font.pixelSize: 11; font.family: preview.fontName }
            }
            Row {
                anchors { left: parent.left; leftMargin: 18; top: parent.top; topMargin: 52 }
                spacing: 24
                Repeater {
                    model: [{ key: "folder", label: "Projects" }, { key: "text", label: "Notes.txt" }, { key: "image", label: "Photo.png" }]
                    delegate: Column {
                        required property var modelData
                        spacing: 6; width: 88
                        Image { anchors.horizontalCenter: parent.horizontalCenter; width: 36; height: 36
                            source: preview.iconUrl(modelData.key); sourceSize.width: 48; sourceSize.height: 48
                            fillMode: Image.PreserveAspectFit }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.label
                            color: preview.ink; font.pixelSize: 11; font.family: preview.fontName }
                    }
                }
            }
            Text { anchors { left: parent.left; leftMargin: 18; bottom: parent.bottom; bottomMargin: 10 }
                text: "The quick brown fox · 0123456789"; color: preview.muted; font.pixelSize: 12; font.family: preview.fontName }
        }
        Flow {
            Layout.fillWidth: true; spacing: 6
            Choice { label: "Light"; selected: preview.light; onPicked: { preview.begin(); preview.draftLight = true; } }
            Choice { label: "Dark"; selected: !preview.light; onPicked: { preview.begin(); preview.draftLight = false; } }
            Repeater {
                model: [preview.baseAccent, "#535a92", "#267a72", "#ad5271", "#b87528"]
                delegate: Rectangle {
                    required property var modelData
                    width: 30; height: 30; radius: 15; color: modelData
                    border.width: preview.accent.toString() === color.toString() ? 3 : 1
                    border.color: preview.ink
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { preview.begin(); preview.draftAccent = parent.color; } }
                }
            }
        }
        Flow { Layout.fillWidth: true; spacing: 6
            Repeater { model: preview.fonts.slice(0, 6)
                delegate: Choice { required property var modelData; label: modelData; selected: preview.fontName === modelData
                    onPicked: { preview.begin(); preview.draftFont = modelData; } }
            }
        }
        Flow { Layout.fillWidth: true; spacing: 6
            Repeater { model: preview.iconCatalog
                delegate: Choice { required property var modelData; label: modelData.name; selected: preview.icons === modelData.name
                    onPicked: { preview.begin(); preview.draftIcons = modelData.name; } }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: "Preview changes here first. App icons may need an app restart after applying."
                color: preview.muted; font.pixelSize: 10; font.family: preview.baseFont }
            Choice { objectName: "appearanceReset"; label: "Reset"; visible: preview.editing; onPicked: preview.editing = false }
            Choice { objectName: "appearanceApply"; label: "Apply look"; selected: true; visible: preview.editing
                onPicked: {
                    preview.applied(preview.light, preview.accent, preview.fontName, true, preview.icons);
                    preview.editing = false;
                } }
        }
    }
}
