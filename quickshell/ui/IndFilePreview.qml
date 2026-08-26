// sea-shell — file preview inspector panel for sea-fm
// Features large resizable canvas, in-app video player (QtMultimedia),
// continuous scrollable PDF document reader, and Quick Look integration.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

Rectangle {
    id: previewPanel

    property var previewData: ({})
    property bool panelVisible: true
    property real targetWidth: 460
    property real pdfZoom: 1.0

    readonly property bool isDark: backend && backend.theme ? backend.theme.isDark : true
    readonly property color accentColor: backend && backend.theme ? backend.theme.accent : "#63c7dd"
    // Category colours and the destructive-action red live in one place so a
    // context-menu glyph can never disagree with the file icon it acts on.
    readonly property var catColor: (backend && backend.categoryColors) ? backend.categoryColors : ({})
    function catInk(name, fallback) { return catColor[name] ? catColor[name] : fallback }
    readonly property color dangerInk: isDark ? "#ff6b6b" : "#c2382c"
    readonly property color accentInk: Qt.hsla(accentColor.hslHue,
                                               Math.max(0.38, accentColor.hslSaturation),
                                               isDark ? Math.max(0.64, accentColor.hslLightness)
                                                      : Math.min(0.40, accentColor.hslLightness),
                                               1.0)
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property var iconFilled: ({ "FILL": 1, "wght": 400 })
    readonly property color bgDark: isDark ? "#0c0c10" : "#f0f2f6"
    readonly property color bgCard: isDark ? "#13131b" : "#ffffff"
    readonly property color bgSurface: isDark ? "#191923" : "#e6e9f0"
    readonly property color bgHover: isDark ? "#232330" : "#d8dce6"
    readonly property color textPrimary: isDark ? "#ffffff" : "#0f172a"
    readonly property color textSecondary: isDark ? "#9a9ab2" : "#475569"
    readonly property color textMuted: isDark ? "#606076" : "#64748b"
    readonly property color borderSoft: isDark ? "#22222e" : "#cbd5e1"
    readonly property color borderHard: isDark ? "#323246" : "#94a3b8"

    signal closeRequested()
    signal actionRequested(string action, string path)
    signal quickLookRequested(var data)

    width: panelVisible ? targetWidth : 0
    visible: width > 0
    color: bgCard
    border.width: 1
    border.color: borderSoft
    clip: true

    // ==========================================
    // IN-APP MEDIA PLAYER ENGINE (LAZY LOADED)
    // ==========================================
    readonly property bool isMedia: !!(previewData && (previewData.category === "video" || previewData.category === "audio"))
    readonly property var player: (previewCanvasLoader && previewCanvasLoader.item) ? previewCanvasLoader.item.player : null
    property bool isPlaying: player ? (player.playbackState === MediaPlayer.PlayingState) : false
    property bool isMuted: false

    function formatTime(ms) {
        if (!ms || isNaN(ms)) return "00:00"
        var totalSecs = Math.floor(ms / 1000)
        var mins = Math.floor(totalSecs / 60)
        var secs = totalSecs % 60
        var sMins = mins < 10 ? "0" + mins : "" + mins
        var sSecs = secs < 10 ? "0" + secs : "" + secs
        return sMins + ":" + sSecs
    }

    onPreviewDataChanged: {
        if (player) player.stop()
        pdfZoom = 1.0
    }

    Component.onDestruction: {
        if (player) player.stop()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // ==========================================
        // 1. INSPECTOR HEADER & CONTROLS
        // ==========================================
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                width: 30; height: 30; radius: 6
                color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                Text {
                    anchors.centerIn: parent
                    text: (previewData && previewData.category === "pdf") ? "picture_as_pdf"
                        : ((previewData && previewData.category === "video") ? "movie"
                        : ((previewData && previewData.category === "audio") ? "audiotrack" : "info"))
                    font.family: iconFont
                    font.pixelSize: 17
                    color: (previewData && previewData.category === "pdf") ? catInk("pdf", "#ef4444") : accentInk
                }
            }

            ColumnLayout {
                spacing: 1
                Text {
                    text: (previewData && previewData.category === "pdf") ? "PDF DOCUMENT VIEWER"
                          : (previewData && previewData.pdfPages && previewData.pdfPages.length > 0) ? "DOCUMENT VIEWER"
                        : ((previewData && previewData.category === "video") ? "VIDEO PLAYER"
                        : ((previewData && previewData.category === "audio") ? "AUDIO PLAYER" : "INSPECTOR"))
                    font.pixelSize: 10
                    font.bold: true
                    font.letterSpacing: 1.2
                    color: textMuted
                }
                Text {
                    text: (previewData && previewData.name) ? previewData.name : "Overview"
                    font.pixelSize: 13
                    font.bold: true
                    color: textPrimary
                    elide: Text.ElideMiddle
                    Layout.maximumWidth: previewPanel.width - 150
                }
            }

            Item { Layout.fillWidth: true }

            // Quick Look / Theater Mode Button
            Rectangle {
                width: 28; height: 28; radius: 5
                color: qlBtnMa.containsMouse ? bgHover : "transparent"
                visible: !!(previewData && previewData.path && !previewData.isDir)
                Text {
                    anchors.centerIn: parent
                    text: "fullscreen"
                    font.family: iconFont
                    color: textSecondary
                    font.pixelSize: 18
                }
                MouseArea {
                    id: qlBtnMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: previewPanel.quickLookRequested(previewData)
                }
            }

            // Close Button
            Rectangle {
                width: 28; height: 28; radius: 5
                color: closeBtnMa.containsMouse ? bgHover : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "close"
                    font.family: iconFont
                    color: textSecondary
                    font.pixelSize: 17
                }
                MouseArea {
                    id: closeBtnMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // GUARDED, because `player` is null for everything that is
                        // not video or audio — a folder, a PDF, a text file. The
                        // unguarded call threw before closeRequested() was ever
                        // reached, which is why this button did nothing at all
                        // except on a media file.
                        if (player) player.stop()
                        previewPanel.closeRequested()
                    }
                }
            }
        }

        // ==========================================
        // 2. PDF VIEWER TOOLBAR (Zoom & Page Info)
        // ==========================================
        Rectangle {
            Layout.fillWidth: true
            height: 32
            radius: 6
            color: bgDark
            border.width: 1
            border.color: borderSoft
            visible: previewData && previewData.pdfPages && previewData.pdfPages.length > 0

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 8

                Text {
                    text: (previewData && previewData.pageCount) ? previewData.pageCount + " Page" + (previewData.pageCount > 1 ? "s" : "") : "PDF"
                    font.pixelSize: 11
                    font.bold: true
                    color: textSecondary
                }

                Item { Layout.fillWidth: true }

                // Zoom Out
                Rectangle {
                    width: 24; height: 24; radius: 4
                    color: zoomOutMa.containsMouse ? bgHover : "transparent"
                    Text { anchors.centerIn: parent; text: "zoom_out"; font.family: iconFont; color: textSecondary; font.pixelSize: 16 }
                    MouseArea {
                        id: zoomOutMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: pdfZoom = Math.max(0.6, pdfZoom - 0.15)
                    }
                }

                Text {
                    text: Math.round(pdfZoom * 100) + "%"
                    font.pixelSize: 11
                    color: textPrimary
                    font.bold: true
                }

                // Zoom In
                Rectangle {
                    width: 24; height: 24; radius: 4
                    color: zoomInMa.containsMouse ? bgHover : "transparent"
                    Text { anchors.centerIn: parent; text: "zoom_in"; font.family: iconFont; color: textSecondary; font.pixelSize: 16 }
                    MouseArea {
                        id: zoomInMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: pdfZoom = Math.min(2.5, pdfZoom + 0.15)
                    }
                }

                // Fit Width Button
                Rectangle {
                    width: 24; height: 24; radius: 4
                    color: fitWidthMa.containsMouse ? bgHover : "transparent"
                    Text { anchors.centerIn: parent; text: "fit_screen"; font.family: iconFont; color: textSecondary; font.pixelSize: 16 }
                    MouseArea {
                        id: fitWidthMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: pdfZoom = 1.0
                    }
                }
            }
        }

        // ==========================================
        // 3. EXPANDED MAIN PREVIEW CANVAS
        // (Takes full vertical height for maximum size and clarity!)
        // ==========================================
        Rectangle {
            id: previewCanvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 280
            radius: 10
            color: bgDark
            border.width: 1
            border.color: borderSoft
            clip: true

            // ======================================
            // A. SCROLLABLE MULTI-PAGE PDF VIEWER
            // ======================================
            ScrollView {
                anchors.fill: parent
                anchors.margins: 8
                visible: previewData && previewData.pdfPages && previewData.pdfPages.length > 0
                clip: true

                ListView {
                    id: pdfListView
                    width: previewCanvas.width - 24
                    model: previewData ? previewData.pdfPages : []
                    spacing: 14

                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        width: pdfListView.width
                        height: pdfPageImg.paintedHeight > 0 ? (pdfPageImg.paintedHeight + 16) : (pdfListView.width * 1.414)
                        radius: 8
                        color: "#ffffff"
                        border.width: 1
                        border.color: isDark ? "#282838" : "#cbd5e1"

                        Column {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 4

                            Image {
                                id: pdfPageImg
                                width: parent.width * pdfZoom
                                source: "file://" + modelData
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                                asynchronous: true
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        // Page Number Badge
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.right: parent.right
                            anchors.margins: 8
                            height: 20
                            width: pageBadgeText.implicitWidth + 10
                            radius: 4
                            color: isDark ? Qt.rgba(0, 0, 0, 0.75) : Qt.rgba(255, 255, 255, 0.90)

                            Text {
                                id: pageBadgeText
                                anchors.centerIn: parent
                                text: "Page " + (index + 1)
                                font.pixelSize: 10
                                font.bold: true
                                color: isDark ? "#ffffff" : "#000000"
                            }
                        }
                    }
                }
            }

            // ======================================
            // B. LARGE VIDEO & MEDIA PLAYER SURFACE (LAZY LOADED)
            // ======================================
            Loader {
                id: previewCanvasLoader
                anchors.fill: parent
                anchors.margins: 6
                active: previewPanel.isMedia
                sourceComponent: Item {
                    anchors.fill: parent
                    property alias player: internalPlayer

                    MediaPlayer {
                        id: internalPlayer
                        source: (previewData && previewData.path) ? ("file://" + previewData.path) : ""
                        audioOutput: AudioOutput {
                            volume: previewPanel.isMuted ? 0.0 : 0.8
                        }
                        videoOutput: internalVideoSurface
                    }

                    VideoOutput {
                        id: internalVideoSurface
                        anchors.fill: parent
                        visible: previewData && previewData.category === "video"
                        fillMode: VideoOutput.PreserveAspectFit
                    }
                }
            }

            // Video Play Overlay Button (Huge center play button)
            Rectangle {
                anchors.centerIn: parent
                width: 64; height: 64; radius: 32
                color: Qt.rgba(0, 0, 0, 0.65)
                border.width: 2
                border.color: accentColor
                visible: previewData && previewData.category === "video" && !previewPanel.isPlaying

                Text {
                    anchors.centerIn: parent
                    text: "play_arrow"
                    font.family: iconFont
                    font.pixelSize: 38
                    color: "#ffffff"
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (player) player.play()
                }
            }

            // ======================================
            // C. AUDIO VISUALIZER CANVAS
            // ======================================
            ColumnLayout {
                anchors.centerIn: parent
                visible: previewData && previewData.category === "audio"
                spacing: 12

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: 90; height: 90; radius: 45
                    color: Qt.rgba(0.93, 0.28, 0.6, 0.15)
                    border.width: 2
                    border.color: catInk("audio", "#ec4899")

                    Text {
                        anchors.centerIn: parent
                        text: "music_note"
                        font.family: iconFont
                        font.pixelSize: 48
                        color: catInk("audio", "#ec4899")
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: (previewData && previewData.name) ? previewData.name : "Audio Track"
                    font.pixelSize: 13
                    font.bold: true
                    color: textPrimary
                    elide: Text.ElideMiddle
                    Layout.maximumWidth: previewCanvas.width - 40
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // ======================================
            // D. HIGH-RES IMAGE VIEWER
            // ======================================
            Flickable {
                anchors.fill: parent
                anchors.margins: 8
                // Any picture we have and no pages to draw it as — an image file,
                // or a document whose thumbnail arrived before its conversion did.
                // Gating this on category "image" alone left documents in that
                // in-between state drawing nothing at all.
                visible: !!(previewData && previewData.thumbnailPath && previewData.thumbnailPath !== ""
                         && previewData.category !== "video" && previewData.category !== "audio"
                         && !(previewData.pdfPages && previewData.pdfPages.length > 0))
                contentWidth: Math.max(width, mainThumbImage.paintedWidth)
                contentHeight: Math.max(height, mainThumbImage.paintedHeight)
                clip: true

                Image {
                    id: mainThumbImage
                    anchors.centerIn: parent
                    source: (previewData && previewData.thumbnailPath) ? "file://" + previewData.thumbnailPath : ""
                    fillMode: Image.PreserveAspectFit
                    width: previewCanvas.width - 16
                    height: previewCanvas.height - 16
                    smooth: true
                    mipmap: true
                    asynchronous: true
                }
            }

            // ======================================
            // E. CODE PREVIEW FLICKABLE
            // ======================================
            Flickable {
                anchors.fill: parent
                anchors.margins: 12
                // Documents as well as code: a .txt or .md is filed as a document,
                // and showing it a big grey icon instead of its own first lines was
                // the least useful thing the panel could have done with it.
                visible: !!(previewData && !previewData.thumbnailPath
                            && !previewData.renderPending
                            && !(previewData.pdfPages && previewData.pdfPages.length > 0)
                            && (previewData.category === "code" || previewData.category === "document")
                            && previewData.text)
                contentWidth: Math.max(width, codeText.width)
                contentHeight: codeText.height
                clip: true

                Text {
                    id: codeText
                    text: (previewData && previewData.text) ? previewData.text : "Empty file"
                    font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                    font.pixelSize: 12
                    color: isDark ? "#e2e8f0" : "#1e293b"
                    wrapMode: Text.NoWrap
                }
            }

            // ======================================
            // E2. WAITING ON A RENDER
            // ======================================
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 10
                visible: !!(previewData && previewData.renderPending
                            && !(previewData.pdfPages && previewData.pdfPages.length > 0))

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "hourglass_top"
                    font.family: iconFont
                    font.pixelSize: 44
                    renderType: Text.QtRendering
                    color: accentInk
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Rendering pages\u2026"
                    font.pixelSize: 12
                    color: textSecondary
                }
            }

            // ======================================
            // F. ARCHIVE PREVIEW
            // ======================================
            ColumnLayout {
                anchors.centerIn: parent
                visible: previewData && previewData.category === "archive"
                spacing: 10

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: 76; height: 76; radius: 14
                    color: Qt.rgba(0.96, 0.62, 0.04, 0.15)
                    border.width: 1
                    border.color: catInk("archive", "#f59e0b")

                    Text {
                        anchors.centerIn: parent
                        text: "folder_zip"
                        font.family: iconFont
                        font.pixelSize: 42
                        color: catInk("archive", "#f59e0b")
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Compressed Archive"
                    font.pixelSize: 14
                    font.bold: true
                    color: textPrimary
                }
            }

            // ======================================
            // G. DIRECTORY & GENERIC FILE PLACEHOLDER
            // ======================================
            ColumnLayout {
                anchors.centerIn: parent
                visible: !!(previewData && !previewData.thumbnailPath
                            && !previewData.renderPending
                            && !(previewData.text && (previewData.category === "code"
                                                      || previewData.category === "document"))
                            && previewData.category !== "code" && previewData.category !== "archive"
                            && previewData.category !== "video" && previewData.category !== "audio"
                            && previewData.category !== "pdf")
                spacing: 10

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: (previewData && previewData.iconName)
                          ? previewData.iconName
                          : ((previewData && previewData.isDir) ? "folder" : "draft")
                    font.family: iconFont
                    font.pixelSize: 76
                    font.variableAxes: iconFilled
                    // Large filled glyphs seam under the native rasteriser; see
                    // the note on the grid icon in FileManager.qml.
                    renderType: Text.QtRendering
                    color: (previewData && previewData.isDir)
                           ? accentInk
                           : ((previewData && previewData.accentColor) ? previewData.accentColor : accentInk)
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: (previewData && previewData.name) ? previewData.name : "Current Folder"
                    font.pixelSize: 13
                    font.bold: true
                    color: textPrimary
                    elide: Text.ElideMiddle
                    maximumLineCount: 1
                    Layout.maximumWidth: previewCanvas.width - 40
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        // ==========================================
        // 4. IN-APP MEDIA PLAYER CONTROLLER BAR
        // ==========================================
        Rectangle {
            Layout.fillWidth: true
            height: 52
            radius: 8
            color: bgDark
            border.width: 1
            border.color: borderSoft
            visible: previewData && (previewData.category === "video" || previewData.category === "audio")

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 2

                // Scrub / Progress Bar
                Slider {
                    id: scrubSlider
                    Layout.fillWidth: true
                    Layout.preferredHeight: 16
                    from: 0
                    to: (player && player.duration > 0) ? player.duration : 1
                    value: player ? player.position : 0
                    onMoved: if (player) player.position = value

                    background: Rectangle {
                        x: scrubSlider.leftPadding
                        y: scrubSlider.topPadding + scrubSlider.availableHeight / 2 - 2
                        width: scrubSlider.availableWidth
                        height: 5
                        radius: 2.5
                        color: isDark ? "#282838" : "#cbd5e1"

                        Rectangle {
                            width: scrubSlider.visualPosition * parent.width
                            height: parent.height
                            color: accentColor
                            radius: 2.5
                        }
                    }

                    handle: Rectangle {
                        x: scrubSlider.leftPadding + scrubSlider.visualPosition * (scrubSlider.availableWidth - width)
                        y: scrubSlider.topPadding + scrubSlider.availableHeight / 2 - height / 2
                        width: 12
                        height: 12
                        radius: 6
                        color: accentColor
                    }
                }

                // Controls Row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        width: 28; height: 28; radius: 6
                        color: playBtnMa.containsMouse ? bgHover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: previewPanel.isPlaying ? "pause" : "play_arrow"
                            font.family: iconFont
                            font.pixelSize: 20
                            color: accentColor
                        }
                        MouseArea {
                            id: playBtnMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (player) {
                                    if (previewPanel.isPlaying) player.pause()
                                    else player.play()
                                }
                            }
                        }
                    }

                    Text {
                        text: previewPanel.formatTime(player ? player.position : 0) + " / " + previewPanel.formatTime(player ? player.duration : 0)
                        font.pixelSize: 11
                        color: textSecondary
                        font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                    }

                    Item { Layout.fillWidth: true }

                    // Quick Look Theater button
                    Rectangle {
                        width: 28; height: 28; radius: 6
                        color: fsBtnMa.containsMouse ? bgHover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "fullscreen"
                            font.family: iconFont
                            font.pixelSize: 18
                            color: textSecondary
                        }
                        MouseArea {
                            id: fsBtnMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: previewPanel.quickLookRequested(previewData)
                        }
                    }

                    // Mute / Unmute Button
                    Rectangle {
                        width: 28; height: 28; radius: 6
                        color: muteBtnMa.containsMouse ? bgHover : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: isMuted ? "volume_off" : "volume_up"
                            font.family: iconFont
                            font.pixelSize: 18
                            color: isMuted ? dangerInk : textSecondary
                        }
                        MouseArea {
                            id: muteBtnMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: isMuted = !isMuted
                        }
                    }
                }
            }
        }

        // ==========================================
        // 5. METADATA KEY-VALUE TABLE
        // ==========================================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(135, metaCol.implicitHeight + 16)
            radius: 8
            color: bgDark
            border.width: 1
            border.color: borderSoft
            clip: true

            ScrollView {
                anchors.fill: parent
                anchors.margins: 10
                clip: true

                ColumnLayout {
                    id: metaCol
                    width: parent.width - 12
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { text: "Size"; color: textMuted; font.pixelSize: 11; Layout.preferredWidth: 125; elide: Text.ElideRight }
                        Text { text: (previewData && previewData.sizeStr) ? previewData.sizeStr : "--"; color: textPrimary; font.pixelSize: 11; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { text: "Modified"; color: textMuted; font.pixelSize: 11; Layout.preferredWidth: 125; elide: Text.ElideRight }
                        Text { text: (previewData && previewData.mtimeStr) ? previewData.mtimeStr : "--"; color: textSecondary; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
                    }

                    Repeater {
                        model: (previewData && previewData.meta) ? Object.keys(previewData.meta) : []
                        delegate: RowLayout {
                            required property string modelData
                            Layout.fillWidth: true
                            spacing: 12
                            Text { text: modelData; color: textMuted; font.pixelSize: 11; Layout.preferredWidth: 125; elide: Text.ElideRight }
                            Text { text: previewData.meta[modelData] + ""; color: textPrimary; font.pixelSize: 11; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: borderSoft
        }

        // ==========================================
        // 6. QUICK ACTIONS TOOLBAR
        // ==========================================
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            // Archive Extraction Button
            Rectangle {
                Layout.fillWidth: true
                height: 34
                radius: 6
                visible: previewData && previewData.category === "archive"
                color: extractMa.containsMouse ? catInk("archive", "#f59e0b") : Qt.rgba(0.96, 0.62, 0.04, 0.2)
                border.width: 1
                border.color: catInk("archive", "#f59e0b")

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 6
                    Text { text: "unarchive"; font.family: iconFont; color: extractMa.containsMouse ? "#000000" : catInk("archive", "#f59e0b"); font.pixelSize: 16 }
                    Text { text: "Extract Archive Here"; font.bold: true; font.pixelSize: 12; color: extractMa.containsMouse ? "#000000" : catInk("archive", "#f59e0b") }
                }

                MouseArea {
                    id: extractMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (previewData && previewData.path) previewPanel.actionRequested("extractHere", previewData.path)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                // Primary Open Button
                Rectangle {
                    Layout.fillWidth: true
                    height: 34
                    radius: 6
                    color: openMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        Text { text: "open_in_new"; font.family: iconFont; color: "#000000"; font.pixelSize: 16 }
                        Text { text: "Open"; font.bold: true; font.pixelSize: 12; color: "#000000" }
                    }

                    MouseArea {
                        id: openMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("open", previewData.path)
                    }
                }

                // Terminal Button
                Rectangle {
                    Layout.fillWidth: true
                    height: 34
                    radius: 6
                    color: termMa.containsMouse ? bgHover : bgDark
                    border.width: 1
                    border.color: borderSoft

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        Text { text: "terminal"; font.family: iconFont; color: textPrimary; font.pixelSize: 16 }
                        Text { text: "Terminal"; font.bold: true; font.pixelSize: 12; color: textPrimary }
                    }

                    MouseArea {
                        id: termMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("terminal", previewData.path)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                // Compress Button
                Rectangle {
                    Layout.fillWidth: true
                    height: 30
                    radius: 6
                    color: compMa.containsMouse ? bgHover : bgDark
                    border.width: 1
                    border.color: borderSoft

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4
                        Text { text: "archive"; font.family: iconFont; color: textSecondary; font.pixelSize: 14 }
                        Text { text: "Zip"; font.pixelSize: 11; color: textSecondary }
                    }

                    MouseArea {
                        id: compMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("compress", previewData.path)
                    }
                }

                // Copy Path
                Rectangle {
                    Layout.fillWidth: true
                    height: 30
                    radius: 6
                    color: copyMa.containsMouse ? bgHover : bgDark
                    border.width: 1
                    border.color: borderSoft

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4
                        Text { text: "content_copy"; font.family: iconFont; color: textSecondary; font.pixelSize: 14 }
                        Text { text: "Copy Path"; font.pixelSize: 11; color: textSecondary }
                    }

                    MouseArea {
                        id: copyMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("copyPath", previewData.path)
                    }
                }

                // Duplicate
                Rectangle {
                    Layout.fillWidth: true
                    height: 30
                    radius: 6
                    color: dupMa.containsMouse ? bgHover : bgDark
                    border.width: 1
                    border.color: borderSoft

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4
                        Text { text: "control_point_duplicate"; font.family: iconFont; color: textSecondary; font.pixelSize: 14 }
                        Text { text: "Duplicate"; font.pixelSize: 11; color: textSecondary }
                    }

                    MouseArea {
                        id: dupMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("duplicate", previewData.path)
                    }
                }

                // Move to Trash
                Rectangle {
                    width: 30; height: 30
                    radius: 6
                    color: trashMa.containsMouse ? Qt.rgba(0.93, 0.27, 0.27, 0.2) : bgDark
                    border.width: 1
                    border.color: trashMa.containsMouse ? dangerInk : borderSoft

                    Text {
                        anchors.centerIn: parent
                        text: "delete"
                        font.family: iconFont
                        color: trashMa.containsMouse ? dangerInk : textSecondary
                        font.pixelSize: 15
                    }

                    MouseArea {
                        id: trashMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (previewData && previewData.path) previewPanel.actionRequested("trash", previewData.path)
                    }
                }
            }
        }
    }
}
