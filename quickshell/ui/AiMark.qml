import QtQuick

// Brand marks for the usage widget. The spark, the GPT blossom, Cursor's arrow, Grok's G.
Item {
    id: mark
    property string tool: "claude"
    // A second brand drawn beside the first when two products share one allowance.
    property string also: ""
    property color ink: "#211c2a"
    implicitWidth: 16
    implicitHeight: 16

    Image {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: mark.also !== "" ? parent.width * 0.62 : parent.width
        height: width
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        sourceSize.width: 128
        sourceSize.height: 128
        source: mark.sourceFor(mark.tool)
    }
    Image {
        visible: mark.also !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width * 0.62
        height: width
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        sourceSize.width: 128
        sourceSize.height: 128
        source: mark.sourceFor(mark.also)
    }

    function sourceFor(id) {
        if (id.indexOf("cursor") === 0) return Qt.resolvedUrl("ai-cursor.svg");
        if (id === "codex") return Qt.resolvedUrl("ai-gpt.svg");
        if (id === "grok") return Qt.resolvedUrl("ai-grok.svg");
        if (id === "gemini" || id === "antigravity") return Qt.resolvedUrl("ai-antigravity.svg");
        return Qt.resolvedUrl("ai-claude.svg");
    }
}
