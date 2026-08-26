// sea-shell — main file manager window (FileManager.qml)
// Modern QML File Manager with resizable inspector drawer,
// Spacebar Quick Look theater overlay, dynamic Light & Dark mode,
// custom frosted glass right-click menu, and Matugen color syncing.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtMultimedia

ApplicationWindow {
    id: window
    visible: true
    width: 1280
    height: 840
    minimumWidth: 640
    minimumHeight: 420
    title: "Files — " + (backend ? backend.currentPath : "sea-shell")
    color: bgDark

    // ---- INDUSTRIAL DESIGN TOKENS ----
    //
    // This is Tok.qml's ramp, mirrored. sea-fm cannot import the singleton itself:
    // Tok is a Quickshell FileView singleton and this window is a plain PySide6
    // QApplication, so there is no Quickshell runtime here to provide it. The
    // VALUES are therefore duplicated, deliberately and in one place, from the
    // same accent the rest of the shell reads out of appearance.json.
    //
    // THE LANGUAGE, which the old palette did not follow: neutrals plus exactly
    // one accent. Depth comes from four background steps and two rule weights,
    // never from shadow or translucency. Radius is small and uniform. Numbers,
    // sizes and dates are mono and tabular; prose is sans. The accent marks the
    // primary action and the active state — it never fills large areas.
    //
    // The neutral ramp is DERIVED from the accent's hue, so the greys read as
    // chosen rather than inherited. That is why these are hsla() and not hex.
    readonly property bool isDark: backend && backend.theme ? backend.theme.isDark : true
    readonly property bool light: !isDark
    readonly property color accentColor: backend && backend.theme ? backend.theme.accent : "#63c7dd"

    readonly property real _h: accentColor.hslHue >= 0 ? accentColor.hslHue : 0.55
    // A grey accent must not tint the neutrals, or the whole window goes muddy.
    readonly property real _sm: accentColor.hslSaturation < 0.06 ? 0 : 1

    // Four background steps, and only four.
    readonly property color bgDark:  light ? Qt.hsla(_h, 0.07 * _sm, 0.940, 1) : Qt.hsla(_h, 0.14 * _sm, 0.072, 1)
    readonly property color bgPanel: light ? Qt.hsla(_h, 0.09 * _sm, 0.972, 1) : Qt.hsla(_h, 0.13 * _sm, 0.104, 1)
    readonly property color bgCard:  light ? Qt.hsla(_h, 0.10 * _sm, 1.000, 1) : Qt.hsla(_h, 0.12 * _sm, 0.136, 1)
    readonly property color bgSunken: light ? Qt.hsla(_h, 0.08 * _sm, 0.898, 1) : Qt.hsla(_h, 0.16 * _sm, 0.046, 1)
    readonly property color bgHover: light ? Qt.hsla(_h, 0.09 * _sm, 0.912, 1) : Qt.hsla(_h, 0.13 * _sm, 0.170, 1)

    // Three ink weights.
    readonly property color textPrimary:   light ? Qt.hsla(_h, 0.16 * _sm, 0.090, 1) : Qt.hsla(_h, 0.08 * _sm, 0.912, 1)
    readonly property color textSecondary: light ? Qt.hsla(_h, 0.12 * _sm, 0.310, 1) : Qt.hsla(_h, 0.08 * _sm, 0.680, 1)
    readonly property color textMuted:     light ? Qt.hsla(_h, 0.10 * _sm, 0.520, 1) : Qt.hsla(_h, 0.08 * _sm, 0.492, 1)

    // Two rule weights. Depth is these, not shadows.
    readonly property color borderSoft: light ? Qt.hsla(_h, 0.10 * _sm, 0.845, 1) : Qt.hsla(_h, 0.12 * _sm, 0.190, 1)
    readonly property color borderHard: light ? Qt.hsla(_h, 0.11 * _sm, 0.720, 1) : Qt.hsla(_h, 0.12 * _sm, 0.282, 1)

    // Semantic.
    readonly property color dangerInk: light ? "#ad2020" : dangerInk
    readonly property color dangerWash: light ? dangerWash : "#3a1717"
    readonly property color okInk: light ? "#1b7a4b" : "#4fbf85"
    readonly property color warnInk: light ? "#8f6300" : warnInk

    // accentInk is accent-COLOURED TEXT; onAccent is what goes on top of an
    // accent fill. Two different jobs that a single token kept confusing.
    readonly property color accentInk: light ? Qt.hsla(_h, Math.max(0.40, accentColor.hslSaturation), 0.34, 1)
                                             : Qt.hsla(_h, Math.max(0.38, accentColor.hslSaturation), 0.66, 1)
    // WHAT GOES ON TOP OF AN ACCENT FILL, decided by the accent's own brightness
    // rather than by whether the window is dark. Tying it to the mode meant a
    // light theme always got white ink — and on a pale accent like a dusty rose
    // that is white-on-near-white: the "Done" button had a label nobody could
    // read. Relative luminance, then pick the ink that survives on it.
    readonly property real accentLum: 0.2126 * accentColor.r
                                    + 0.7152 * accentColor.g
                                    + 0.0722 * accentColor.b
    readonly property color onAccent: accentLum > 0.5
                                      ? Qt.hsla(_h, 0.50 * _sm, 0.12, 1)
                                      : "#ffffff"
    readonly property color accentWash: light ? Qt.hsla(_h, 0.34 * _sm, 0.915, 1) : Qt.hsla(_h, 0.30 * _sm, 0.170, 1)
    readonly property color accentGlow: accentWash
    readonly property color bgCardSelected: accentWash

    // ROUNDNESS COMES FROM appearance.json, exactly as it does everywhere else in
    // this shell. Tok derives a three-step scale from the same "radius" value the
    // appearance panel's roundness slider writes, so the file manager is as round
    // as the bar, the dock and the dashboard are — and moves with them when the
    // slider does. Hardcoding a radius here, which is what the first pass did,
    // silently overrode a preference the user had already set.
    // Appended to every themed icon URL. An icon's NAME is the same in every
    // theme -- a folder is "folder" everywhere -- so switching themes produced
    // the identical URL and QML handed back the bitmap it had already cached,
    // which is why new icons only showed up after a restart.
    readonly property int iconGen: backend ? backend.iconGeneration : 0

    readonly property real radiusCfg: (backend && backend.theme && backend.theme.radius !== undefined)
                                      ? backend.theme.radius : 14
    readonly property real rSmall: Math.max(2, Math.min(8,  radiusCfg * 0.28))   // chips, dots, small toggles
    readonly property real rBase:  Math.max(2, Math.min(14, radiusCfg * 0.5))    // buttons, inputs, rows
    readonly property real rCard:  Math.max(2, Math.min(30, radiusCfg))          // panels, dialogs, cards
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s6: 24
    readonly property int tLabel: 11
    readonly property int tData: 12
    readonly property int tDense: 13
    readonly property int tBody: 15
    readonly property int tPanel: 17
    readonly property int mFast: 130
    readonly property int mBase: 200

    // The mono face, for everything machine-readable — sizes, dates, counts,
    // permissions. Tabular figures stop columns of numbers from shivering as
    // they update.
    readonly property string monoFont: backend && backend.theme && backend.theme.fontMono
                                       ? backend.theme.fontMono : "Roboto Mono"

    // Category colours and the destructive-action red live in one place so a
    // context-menu glyph can never disagree with the file icon it acts on.
    readonly property var catColor: (backend && backend.categoryColors) ? backend.categoryColors : ({})
    function catInk(name, fallback) { return catColor[name] ? catColor[name] : fallback }

    // One icon face for the whole window. The Rounded cut with FILL=1 gives solid
    // glyphs that read as objects rather than the hairline outlines they replaced.
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property var iconFilled: ({ "FILL": 1, "wght": 400 })
    readonly property var iconLine: ({ "FILL": 0, "wght": 400 })

    // Thumbnails land asynchronously. Rebinding this object repaints the delegates
    // that care without touching the model, so no delegate is ever rebuilt.
    property var thumbCache: ({})
    property var pendingThumbs: ({})
    function thumbFor(item) {
        if (!item) return ""
        if (item.thumbnailPath && item.thumbnailPath !== "") return item.thumbnailPath
        return thumbCache[item.path] || ""
    }

    Timer {
        id: thumbFlush
        interval: 120
        onTriggered: {
            var merged = {}
            for (var k in window.thumbCache) merged[k] = window.thumbCache[k]
            for (var j in window.pendingThumbs) merged[j] = window.pendingThumbs[j]
            window.pendingThumbs = ({})
            window.thumbCache = merged
        }
    }

    // The file grid is the point of the window, so the two chrome panels yield to
    // it as things get narrow: the sidebar drops its labels, the inspector is capped
    // to a fraction of the width no matter what the splitter was dragged to.
    // Everything in a grid cell is a fraction of this, so one number resizes the
    // icons, the thumbnails, the labels and the column count together.
    readonly property int gridIcon: backend ? backend.gridIconSize : 120
    readonly property int gridSlot: Math.round(gridIcon * 0.52)
    readonly property int gridLabelPx: Math.max(10, Math.min(13, Math.round(gridIcon / 11)))
    readonly property int gridGap: Math.round(gridIcon * 0.065)
    // The cell hugs what is actually in it — icon, gap, two lines of label — so
    // zooming up does not open a field of dead space between rows.
    readonly property int gridCellH: gridSlot + gridGap + Math.round(gridLabelPx * 2.7) + 24
    function zoomGrid(step) {
        if (backend) backend.setGridIconSize(backend.gridIconSize + step)
    }

    readonly property bool sidebarCollapsed: window.width < 820
    readonly property real sidebarW: sidebarCollapsed ? 58 : 240
    readonly property real inspectorCap: Math.max(240, window.width * 0.38)
    // Below this there is no width left to inspect anything with. The user's own
    // toggle is remembered, so widening the window brings the panel straight back.
    readonly property bool inspectorShown: showInspector && window.width >= 700
    readonly property real inspectorEffective: Math.min(inspectorWidth, inspectorCap)

    // Toolbar vocabulary. Grouping related buttons into one capsule — the way the
    // nav arrows already were — replaces a row of eight identical floating boxes.
    component ToolBtn: Rectangle {
        id: tb
        property string glyph: ""
        property string tip: ""
        property bool active: false
        property bool on: true
        signal activated()

        width: 30; height: 30; radius: rBase
        enabled: tb.on
        opacity: tb.on ? 1.0 : 0.4
        color: tb.active ? Qt.rgba(window.accentColor.r, window.accentColor.g, window.accentColor.b, 0.16)
                         : (tbMa.containsMouse ? window.bgHover : "transparent")
        Behavior on color { ColorAnimation { duration: 90 } }

        Text {
            anchors.centerIn: parent
            text: tb.glyph
            font.family: window.iconFont
            font.pixelSize: 18
            color: tb.active ? window.accentInk : window.textPrimary
        }

        ToolTip.visible: tbMa.containsMouse && tb.tip.length > 0
        ToolTip.text: tb.tip
        ToolTip.delay: 550

        MouseArea {
            id: tbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tb.activated()
        }
    }

    component ToolGroup: Rectangle {
        id: tg
        default property alias content: tgRow.data
        implicitWidth: tgRow.implicitWidth + 8
        implicitHeight: 36
        radius: rBase
        color: window.bgDark
        border.width: 1
        border.color: window.borderSoft
        Row { id: tgRow; anchors.centerIn: parent; spacing: 2 }
    }

    // SPLIT VIEW. `backend` here is a root property, and a root property shadows a
    // context property — so every `backend.foo` already written in this file now
    // resolves to whichever pane has focus, without renaming a single call site.
    property bool splitView: false
    property int activePane: 0
    property real splitRatio: 0.5
    readonly property var backend: (splitView && activePane === 1) ? be2 : be1

    // Each backend owns a model that updates in place. These are the same object
    // for the life of the window; only its rows change, which is what lets the
    // views keep their delegates, their scroll position and their selection
    // through a refresh instead of being rebuilt from nothing every time.
    readonly property var modelA: be1 ? be1.model : null
    readonly property var modelB: be2 ? be2.model : null
    readonly property var currentModel: (splitView && activePane === 1) ? modelB : modelA
    readonly property int currentCount: currentModel ? currentModel.count : 0

    function focusPane(i) {
        if (window.activePane === i) return
        window.activePane = i
        selectedPaths = []
        selectedPath = ""
        customMenu.visible = false
        if (backend) backend.selectFile("")
    }

    function toggleSplit() {
        window.splitView = !window.splitView
        if (!window.splitView) window.focusPane(0)
        else refreshAllPanes()
    }

    property var selectedPaths: []
    property string selectedPath: ""
    // Closed until asked for. It is a wide panel that pushes the files aside, and
    // most of what it shows is already in the row you clicked.
    property bool showInspector: prefs ? !!prefs.all.inspectorOnOpen : false
    property real inspectorWidth: 380
    property bool manualPathEdit: false
    property string renameTarget: ""

    // Drag & Drop State
    property var draggedPaths: []
    property bool isDragging: false
    property string dragPreviewName: ""
    property real dragX: 0
    property real dragY: 0

    // Multi-Tab State
    property var tabs: [
        {
            id: 1,
            path: backend ? backend.currentPath : "/",
            name: backend ? (backend.currentPath.split("/").filter(function(s){ return s !== "" }).pop() || "Home") : "Home",
            history: [backend ? backend.currentPath : "/"],
            historyIdx: 0,
            searchQuery: ""
        }
    ]
    property int activeTabIdx: 0
    property int nextTabId: 2

    function createNewTab(targetPath) {
        var p = targetPath || (backend ? backend.currentPath : (backend ? backend.bookmarks[0].path : "/"))
        var parts = p.split("/").filter(function(s){ return s !== "" })
        var n = parts.length > 0 ? parts[parts.length - 1] : "Home"
        var newTabObj = {
            id: nextTabId++,
            path: p,
            name: n,
            history: [p],
            historyIdx: 0,
            searchQuery: ""
        }
        var arr = tabs.slice()
        arr.push(newTabObj)
        tabs = arr
        switchTab(tabs.length - 1)
    }

    function closeTab(idx) {
        if (tabs.length <= 1) {
            Qt.quit()
            return
        }
        var arr = tabs.slice()
        arr.splice(idx, 1)
        tabs = arr
        var newIdx = activeTabIdx
        if (newIdx >= tabs.length) {
            newIdx = tabs.length - 1
        }
        switchTab(newIdx)
    }

    function switchTab(idx) {
        if (idx < 0 || idx >= tabs.length) return
        activeTabIdx = idx
        var t = tabs[idx]
        if (backend && t) {
            if (searchInput) searchInput.text = t.searchQuery || ""
            backend.setSearchQuery(t.searchQuery || "")
            if (backend.currentPath !== t.path) {
                backend.cd(t.path)
            } else {
                refreshDirectory()
            }
        }
    }

    // ---- moving tabs around ----

    function moveTab(from, to) {
        if (from === to || from < 0 || to < 0
            || from >= tabs.length || to >= tabs.length) return
        var arr = tabs.slice()
        arr.splice(to, 0, arr.splice(from, 1)[0])
        tabs = arr
        // The active tab is identified by index, so it has to travel with the
        // move — otherwise reordering silently switches which folder you are in.
        if (activeTabIdx === from) activeTabIdx = to
        else if (from < activeTabIdx && to >= activeTabIdx) activeTabIdx -= 1
        else if (from > activeTabIdx && to <= activeTabIdx) activeTabIdx += 1
    }

    // Which tab sits under an x in the tab row's own coordinates. Tabs are not a
    // fixed width, so this is a hit test rather than a division.
    // Which tab a drag is hovering to MERGE with, or -1. Merging and reordering
    // are the same gesture over the same strip, so they are told apart by WHERE in
    // the target tab the pointer is: the middle of a tab means "combine with this
    // one", the edges mean "move past it". Without that split the reorder fires
    // the moment two tabs overlap and there is no way to express the other intent.
    property int tabMergeTarget: -1

    function tabZoneAtX(x) {
        for (var i = 0; i < tabRow.children.length; i++) {
            var c = tabRow.children[i]
            if (!c || c.objectName !== "tabCard") continue
            if (x >= c.x && x <= c.x + c.width) {
                var f = (x - c.x) / Math.max(1, c.width)
                return { idx: c.tabIndex, merge: (f > 0.3 && f < 0.7) }
            }
        }
        return { idx: -1, merge: false }
    }

    // Drop tab A onto tab B: B stays in the strip as the tab you are on, A becomes
    // the other half of a split. A's tab is then closed, because it is no longer a
    // tab — it is a pane, and leaving it in the bar would show the same folder twice.
    function mergeTabIntoSplit(sourceIdx, targetIdx) {
        if (sourceIdx < 0 || targetIdx < 0 || sourceIdx === targetIdx) return
        if (sourceIdx >= tabs.length || targetIdx >= tabs.length) return
        var sourcePath = tabs[sourceIdx].path
        switchTab(targetIdx)
        if (!splitView) toggleSplit()
        if (be2) be2.cd(sourcePath)
        activePane = 0
        // Indices shift when the source tab goes, so re-find it by identity.
        var freshIdx = -1
        for (var i = 0; i < tabs.length; i++) {
            if (tabs[i].path === sourcePath && i !== activeTabIdx) { freshIdx = i; break }
        }
        if (freshIdx >= 0 && tabs.length > 1) closeTab(freshIdx)
    }

    // "Open in split view" from a right-click on a folder.
    function openInSplit(path) {
        if (!path) return
        if (!splitView) toggleSplit()
        if (activePane === 1) { if (be1) be1.cd(path) }
        else { if (be2) be2.cd(path) }
    }

    function tabIndexAtX(x) {
        for (var i = 0; i < tabRow.children.length; i++) {
            var c = tabRow.children[i]
            if (!c || c.objectName !== "tabCard") continue
            if (x >= c.x && x <= c.x + c.width) return c.tabIndex
        }
        return -1
    }

    function duplicateTab(idx) {
        if (idx < 0 || idx >= tabs.length) return
        createNewTab(tabs[idx].path)
    }

    function closeOtherTabs(idx) {
        if (idx < 0 || idx >= tabs.length) return
        tabs = [tabs[idx]]
        activeTabIdx = 0
        switchTab(0)
    }

    function closeTabsToRight(idx) {
        if (idx < 0 || idx >= tabs.length - 1) return
        tabs = tabs.slice(0, idx + 1)
        if (activeTabIdx > idx) switchTab(idx)
    }

    // A tab and a pane are the same thing seen two ways, so sending one to the
    // other side is what "merge these tabs" actually means.
    function tabToOtherPane(idx) {
        if (idx < 0 || idx >= tabs.length) return
        var p = tabs[idx].path
        if (!splitView) toggleSplit()
        if (activePane === 1) { if (be1) be1.cd(p) }
        else { if (be2) be2.cd(p) }
    }

    function mergeTabsToSplit() {
        if (tabs.length < 2) return
        var other = (activeTabIdx + 1) % tabs.length
        var p = tabs[other].path
        if (!splitView) toggleSplit()
        if (activePane === 1) { if (be1) be1.cd(p) } else { if (be2) be2.cd(p) }
        // The tab has become the other half of the window; leaving it in the bar
        // as well would show the same folder twice.
        closeTab(other)
    }

    function detachTab(idx) {
        if (idx < 0 || idx >= tabs.length || tabs.length < 2) return
        var p = tabs[idx].path
        if (be1) be1.openNewWindow(p)
        closeTab(idx)
    }

    function nextTab() {
        if (tabs.length > 1) {
            switchTab((activeTabIdx + 1) % tabs.length)
        }
    }

    function prevTab() {
        if (tabs.length > 1) {
            switchTab((activeTabIdx - 1 + tabs.length) % tabs.length)
        }
    }

    function restoreKeyFocus() {
        if (isModalOpen() || manualPathEdit) return
        if (splitView && activePane === 1) paneB.forceActiveFocus()
        else paneA.forceActiveFocus()
    }

    function isModalOpen() {
        return confirmTrash.visible || prefsDialog.visible || shareDialog.visible || conflictDialog.visible || newFolderDialog.visible || newFileDialog.visible || renameDialog.visible || compressDialog.visible || quickLookModal.visible || openWithModal.visible || confirmPurge.visible || propertiesDialog.visible || batchRenameDialog.visible || duplicatesDialog.visible
    }

    function selectedPathIsDir() {
        if (!selectedPath) return false
        if (!currentModel) return false
        var i = currentModel.indexOfPath(selectedPath)
        return i >= 0 ? !!currentModel.at(i).isDir : false
    }

    // Each pane lists from its own backend. refreshDirectory() means "the pane I am
    // looking at"; the per-backend Connections below keep the other one current.
    function refreshPane(i) {
        if (i === 1) { if (be2) be2.refresh() }
        else { if (be1) be1.refresh() }
    }
    function refreshDirectory() { refreshPane(splitView ? activePane : 0) }
    function refreshAllPanes() { refreshPane(0); if (splitView) refreshPane(1) }

    function isSelected(path) {
        return selectedPaths.indexOf(path) !== -1 || selectedPath === path
    }

    // Put the selected row where it can be seen. A revealed file three screens
    // down is not revealed.
    function scrollToSelection() {
        if (!be1 || !selectedPath) return
        var i = be1.rowOf(selectedPath)
        if (i < 0) return
        var v = paneA.currentView()
        if (v && v.positionViewAtIndex) v.positionViewAtIndex(i, ListView.Contain)
    }

    function selectSingle(path) {
        selectedPath = path
        selectedPaths = [path]
        if (backend) backend.selectFile(path)
    }

    function toggleSelect(path) {
        var idx = selectedPaths.indexOf(path)
        var arr = selectedPaths.slice()
        if (idx !== -1) {
            arr.splice(idx, 1)
        } else {
            arr.push(path)
        }
        selectedPaths = arr
        selectedPath = arr.length > 0 ? arr[arr.length - 1] : ""
        if (backend) backend.selectFile(selectedPath)
    }

    function selectAll() {
        var arr = currentModel ? currentModel.paths() : []
        selectedPaths = arr
        selectedPath = arr.length > 0 ? arr[0] : ""
        if (backend && selectedPath) backend.selectFile(selectedPath)
    }

    function selectionPaths() {
        return selectedPaths.length > 0 ? selectedPaths.slice() : (selectedPath ? [selectedPath] : [])
    }

    function restoreSelection() {
        var picked = selectionPaths()
        if (picked.length > 0 && backend) {
            backend.restoreFromTrash(picked)
            selectedPaths = []; selectedPath = ""
        }
    }

    // Shift+Delete. Nothing about this is recoverable, so it always asks — including
    // from inside the trash, where "delete" is otherwise the only thing left to do.
    function deletePermanentlyAsk() {
        var picked = selectionPaths()
        if (picked.length > 0) confirmPurge.openDialog(picked)
    }

    // Read once here so the delegates do not each reach into the store.
    readonly property bool singleClickOpens: prefs ? !!prefs.all.singleClickOpen : false
    readonly property bool themeIsOwn: prefs ? prefs.all.themeSource === "own" : false

    // Make sure a change made from the Appearance menu lands on this window,
    // rather than being written into a shell config the menu no longer targets.
    function ownAppearance() {
        if (backend && !themeIsOwn) backend.setThemeScope("own")
    }

    function deleteSelection() {
        var toDelete = selectionPaths()
        if (toDelete.length === 0 || !backend) return
        // Off by default: trashing is already reversible with Ctrl+Z, so a
        // confirmation would be a second question about a decision the undo stack
        // has already made safe. It is offered for people who want it anyway.
        if (prefs && prefs.all.confirmTrash) {
            confirmTrash.openDialog(toDelete)
            return
        }
        commitTrash(toDelete)
    }

    function commitTrash(toDelete) {
        if (!backend || !toDelete || toDelete.length === 0) return
        // The rows used to be spliced out of the array by hand here so the view
        // would look right before the listing caught up. The model and the
        // directory watcher both report the removal themselves now, so faking it
        // would only risk disagreeing with what is on disk.
        backend.trashFiles(toDelete)
        selectedPaths = []
        selectedPath = ""
        backend.selectFile("")
    }


    // ---- Undo, tags, properties, batch rename ----

    function doUndo() {
        if (!undo || !undo.canUndo) return
        var msg = undo.undo()
        selectedPaths = []; selectedPath = ""
        if (be1) be1.setStatus(msg)
        refreshAllPanes()
    }

    // With nothing selected the folder you are looking at is what you mean — the
    // same thing every other file manager does with an empty selection here.
    function openProperties() {
        var picked = selectionPaths()
        if (picked.length === 0 && backend) picked = [backend.currentPath]
        if (picked.length > 0) propertiesDialog.openFor(picked)
    }

    // F2 on one file is a rename; on several it is the batch dialog. Same key,
    // because it is the same intent and the count is not something you should
    // have to translate into a different shortcut.
    function openRenameFor() {
        var picked = selectionPaths()
        if (picked.length === 0) return
        if (picked.length === 1) renameDialog.openRename(picked[0])
        else batchRenameDialog.openFor(picked)
    }

    function applyTag(name) {
        var picked = selectionPaths()
        if (picked.length > 0 && tagstore) tagstore.setTag(picked, name)
    }

    readonly property var tagNames: tagstore ? tagstore.names : []
    readonly property var tagPalette: tagstore ? tagstore.palette : ({})
    readonly property var tagCounts: tagstore ? tagstore.counts : ({})
    readonly property var tagsInUse: {
        var out = []
        for (var i = 0; i < tagNames.length; i++)
            if ((tagCounts[tagNames[i]] || 0) > 0) out.push(tagNames[i])
        return out
    }
    function tagColor(name) { return tagPalette[name] ? tagPalette[name] : textMuted }
    readonly property string tagViewName: backend && backend.tagView !== "-" ? backend.tagView : ""
    readonly property bool inTagView: backend ? backend.tagView !== "-" : false
    readonly property bool inArchiveNow: !!(backend && backend.inArchive)
    // Both are read-only views onto something that is not a directory, so every
    // command that writes is off in either.
    readonly property bool frozenHere: inArchiveNow || inTagView

    Connections {
        target: tagstore
        ignoreUnknownSignals: true
        function onChanged() { menuPublish.restart() }
    }
    Connections {
        target: undo
        ignoreUnknownSignals: true
        // The Edit menu names the operation it would reverse, so the menu has to be
        // republished whenever that changes — not just when the selection does.
        function onChanged() { menuPublish.restart() }
    }

    function openQuickLook() {
        if (selectedPath && backend && backend.previewData && backend.previewData.path) {
            quickLookModal.openModal(backend.previewData)
        }
    }

    Connections {
        target: backend
        function onCurrentPathChanged(newPath) {
            if (activeTabIdx >= 0 && activeTabIdx < tabs.length) {
                var arr = tabs.slice()
                var parts = newPath.split("/").filter(function(s){ return s !== "" })
                var n = parts.length > 0 ? parts[parts.length - 1] : "Home"
                arr[activeTabIdx].path = newPath
                arr[activeTabIdx].name = n
                tabs = arr
            }
            selectedPaths = []
            selectedPath = ""
            manualPathEdit = false
            customMenu.visible = false
        }
        // Re-listing is no longer wired up here. Each backend refreshes its own
        // model from the same signals, coalesced, so the seven handlers that used
        // to live here — plus the duplicate pair on be1/be2 below, which made a
        // single navigation list the folder twice — are all one pass now.
    }

    Connections {
        target: be1
        function onThumbnailReady(filePath, thumbPath) {
            window.pendingThumbs[filePath] = thumbPath
            thumbFlush.restart()
        }
        // "Open containing folder" from another application. The backend has
        // already navigated and told the preview which file it is about, but the
        // GRID's selection is this window's own state, so a reveal that only
        // reached the backend opened the right folder with nothing highlighted —
        // which is most of what makes a reveal a reveal.
        function onRevealRequested(path) {
            window.focusPane(0)
            window.selectSingle(path)
            window.scrollToSelection()
        }
    }

    Connections {
        target: be2
        function onThumbnailReady(filePath, thumbPath) {
            window.pendingThumbs[filePath] = thumbPath
            thumbFlush.restart()
        }
    }

    Component.onCompleted: {
        refreshAllPanes()
        paneA.forceActiveFocus()
        // Publish once up front. menuStateKey only reports CHANGES, and the first
        // evaluation of a binding is not one — without this the bar has nothing to
        // draw until the user touches something.
        menuPublish.start()
    }

    // Keyboard Shortcuts
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+T"; onActivated: createNewTab() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+W"; onActivated: closeTab(activeTabIdx) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Tab"; onActivated: nextTab() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Shift+Tab"; onActivated: prevTab() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Page_Down"; onActivated: nextTab() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Page_Up"; onActivated: prevTab() }
    Shortcut { enabled: !isModalOpen(); sequence: "Space"; onActivated: openQuickLook() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+H"; onActivated: if (backend) backend.setShowHidden(!backend.showHidden) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+="; onActivated: zoomGrid(12) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl++"; onActivated: zoomGrid(12) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+-"; onActivated: zoomGrid(-12) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+0"; onActivated: if (backend) backend.setGridIconSize(120) }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+1"; onActivated: if (backend) backend.setViewMode("grid") }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+2"; onActivated: if (backend) backend.setViewMode("list") }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+I"; onActivated: showInspector = !showInspector }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+L"; onActivated: { manualPathEdit = !manualPathEdit; if (manualPathEdit) pathInput.forceActiveFocus() } }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+F"; onActivated: searchInput.forceActiveFocus() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+A"; onActivated: selectAll() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+,"; onActivated: prefsDialog.openDialog() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Shift+F"; onActivated: filterBox.focusIt() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+D"; onActivated: toggleStar() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Shift+S"; onActivated: shareSelection() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+3"; onActivated: if (backend) backend.setViewMode("compact") }
    Shortcut { enabled: !isModalOpen(); sequence: "Alt+Up"; onActivated: if (backend) backend.goUp() }
    Shortcut { enabled: !isModalOpen(); sequence: "Alt+Left"; onActivated: if (backend) backend.goBack() }
    Shortcut { enabled: !isModalOpen(); sequence: "Alt+Right"; onActivated: if (backend) backend.goForward() }
    Shortcut { enabled: !isModalOpen(); sequence: "F5"; onActivated: refreshAllPanes() }
    Shortcut { enabled: !isModalOpen(); sequence: "F3"; onActivated: toggleSplit() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Shift+O"; onActivated: {
        // Send the other pane to where this one is — the usual reason to open a split.
        if (!splitView) toggleSplit()
        var here = backend ? backend.currentPath : ""
        if (here.length > 0) { if (activePane === 1) be1.cd(here); else be2.cd(here) }
    } }
    Shortcut { enabled: !isModalOpen(); sequence: "F2"; onActivated: openRenameFor() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Z"; onActivated: doUndo() }
    Shortcut { enabled: !isModalOpen(); sequence: "Alt+Return"; onActivated: openProperties() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+Shift+N"; onActivated: newFolderDialog.openDialog() }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+N"; onActivated: newFileDialog.openDialog() }
    Shortcut {
        enabled: !isModalOpen()
        sequence: "Ctrl+C"
        onActivated: {
            var paths = selectedPaths.length > 0 ? selectedPaths : (selectedPath ? [selectedPath] : [])
            if (paths.length > 0 && backend) backend.setClipboard(paths, "copy")
        }
    }
    Shortcut {
        enabled: !isModalOpen()
        sequence: "Ctrl+X"
        onActivated: {
            var paths = selectedPaths.length > 0 ? selectedPaths : (selectedPath ? [selectedPath] : [])
            if (paths.length > 0 && backend) backend.setClipboard(paths, "cut")
        }
    }
    Shortcut {
        enabled: !isModalOpen()
        sequence: "Ctrl+V"
        onActivated: {
            if (backend) backend.pasteFiles()
        }
    }
    Shortcut { enabled: !isModalOpen(); sequence: "Ctrl+D"; onActivated: if (selectedPath && backend) backend.duplicateFile(selectedPath) }
    Shortcut { sequence: "Escape"; onActivated: { customMenu.visible = false; bookmarkMenu.visible = false; tabMenu.visible = false; manualPathEdit = false; newFolderDialog.visible = false; newFileDialog.visible = false; renameDialog.visible = false; compressDialog.visible = false; openWithModal.visible = false; confirmPurge.visible = false; propertiesDialog.visible = false; batchRenameDialog.visible = false; duplicatesDialog.close(); quickLookModal.closeModal(); restoreKeyFocus() } }

    // =========================================================
    // GLOBAL MENU  (com.canonical.dbusmenu, drawn by sea-shell's bar)
    // =========================================================
    //
    // WHY THE TREE IS BUILT HERE AND NOT IN PYTHON. Everything a menu has to say —
    // whether a command is available, which of a group is the current one, whether a
    // toggle is on — is already a binding on this window. Expressing it twice is how
    // a menu ends up disagreeing with the window it belongs to. So Python owns the
    // wire format and nothing else: it is handed a tree, it hands back the `cmd`
    // string of whatever was clicked.
    //
    // There is no incremental update path on purpose. The whole tree is a few dozen
    // small objects and rebuilding it is far below a frame, so anything the menu
    // shows simply feeds `menuStateKey` and a change re-publishes the lot. One code
    // path, no stale corners.
    //
    // sea-fm has no QMenuBar anywhere in it — it is Qt Quick all the way down — so
    // without this export the global menu could never see it at all: the fallback
    // path is an accessibility walk looking for a menu bar that does not exist.

    readonly property int selectionCount: selectedPaths.length > 0
                                          ? selectedPaths.length
                                          : (selectedPath ? 1 : 0)
    readonly property bool inTrashNow: !!(backend && backend.inTrash)

    readonly property var archiveExts: [".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar"]
    property int starTick: 0        // bumped so the label re-evaluates
    readonly property bool selectionStarred: {
        starTick;                    // dependency, deliberately
        if (!stars) return false
        var picked = selectionPaths()
        return picked.length > 0 && stars.isStarred(picked[0])
    }

    function toggleStar() {
        var picked = selectionPaths()
        if (picked.length > 0 && stars) { stars.toggle(picked); starTick++ }
    }

    function shareSelection() {
        var picked = selectionPaths()
        if (picked.length > 0) shareDialog.openFor(picked)
    }

    function selectionIsArchive() {
        if (!selectedPath || selectionCount !== 1) return false
        var base = selectedPath.split("/").pop()
        var dot = base.lastIndexOf(".")
        return dot > 0 && archiveExts.indexOf(base.substring(dot).toLowerCase()) !== -1
    }

    function selectionTag() {
        if (!tagstore || !selectedPath) return ""
        return tagstore.tagOf(selectedPath)
    }

    function tagMenuItems() {
        var out = []
        var cur = selectionTag()
        for (var i = 0; i < tagNames.length; i++) {
            out.push({ label: tagNames[i], cmd: "tag:" + tagNames[i], radio: true,
                       checked: cur === tagNames[i], enabled: selectionCount > 0 })
        }
        out.push({ sep: true })
        out.push({ label: "No Tag", cmd: "tag:", enabled: selectionCount > 0 })
        return out
    }

    function menuTree() {
        var be = backend
        var one = selectionCount === 1
        var any = selectionCount > 0
        var trash = inTrashNow
        var arc = inArchiveNow
        var frozen = trash || arc
        var sf = be ? be.sortField : "name"
        var vm = be ? be.viewMode : "grid"
        var home = be && be.bookmarks && be.bookmarks.length > 0 ? be.bookmarks[0].path : ""

        var go = [
            { label: "Back", cmd: "back", key: "Alt+Left", icon: "go-previous" },
            { label: "Forward", cmd: "forward", key: "Alt+Right", icon: "go-next" },
            { label: "Enclosing Folder", cmd: "up", key: "Alt+Up", icon: "go-up",
              enabled: !!(be && be.currentPath !== "/") },
            { sep: true }
        ]
        var bms = be ? be.bookmarks : []
        for (var i = 0; i < bms.length; i++) {
            // Only icon names from the freedesktop naming spec go on the wire. The
            // bookmark's own icon is a Material Symbols glyph name, which the bar
            // would look up in an icon theme and come back empty-handed.
            go.push({ label: bms[i].name, cmd: "go:" + bms[i].path,
                      icon: bms[i].path === home ? "go-home" : "folder" })
        }
        var tagged = []
        for (var t = 0; t < tagNames.length; t++) {
            var cnt = tagCounts[tagNames[t]] || 0
            if (cnt > 0) {
                tagged.push({ label: tagNames[t] + "  (" + cnt + ")",
                              cmd: "go:" + "/Tags/" + tagNames[t] })
            }
        }
        if (tagged.length > 0) {
            go.push({ sep: true })
            tagged.push({ sep: true })
            tagged.push({ label: "All Tagged", cmd: "go:/Tags" })
            go.push({ label: "Tags", items: tagged })
        }
        go.push({ sep: true })
        go.push({ label: "Trash", cmd: "go-trash", icon: "user-trash" })
        go.push({ sep: true })
        go.push({ label: splitView ? "Other Pane Here" : "Split and Follow",
                  cmd: "other-pane", key: "Ctrl+Shift+O" })

        return [
        { label: "File", items: [
            { label: "New Folder", cmd: "new-folder", key: "Ctrl+Shift+N",
              icon: "folder-new", enabled: !frozen },
            { label: "New File", cmd: "new-file", key: "Ctrl+N",
              icon: "document-new", enabled: !frozen },
            { sep: true },
            { label: "New Tab", cmd: "new-tab", key: "Ctrl+T" },
            { label: "New Window", cmd: "new-window", icon: "window-new" },
            { sep: true },
            { label: "Open", cmd: "open", icon: "document-open", enabled: one && !trash },
            { label: "Open With...", cmd: "open-with", enabled: one && !trash },
            { label: "Quick Look", cmd: "quick-look", key: "Space", enabled: one },
            { sep: true },
            { label: "Compress...", cmd: "compress", enabled: any && !frozen },
            { label: "Extract Here", cmd: "extract", enabled: selectionIsArchive() && !frozen },
            { label: any ? "Extract " + selectionCount + " Selected..." : "Extract All...",
              cmd: "extract-members", icon: "archive-extract", visible: arc },
            { label: "Find Duplicates...", cmd: "duplicates", enabled: !trash && !inTagView && !arc },
            { sep: true },
            { label: "Open Terminal Here", cmd: "terminal", enabled: !frozen },
            { label: "Copy Location", cmd: "copy-path" },
            { label: "Add to Sidebar", cmd: "bookmark",
              enabled: one && selectedPathIsDir() && !trash },
            { label: "Properties", cmd: "properties", key: "Alt+Return",
              icon: "document-properties" },
            { sep: true },
            { label: "Close Tab", cmd: "close-tab", key: "Ctrl+W", enabled: tabs.length > 1 },
            { label: "Close Window", cmd: "quit", icon: "application-exit" }
        ]},
        // APPEARANCE MEANS THIS APPLICATION. No scope submenu and no wording about
        // the shell: from inside a menu bar labelled Appearance, the only thing
        // anyone expects to change is the window they are looking at. Following
        // the shell instead is still possible, but it belongs in Preferences,
        // where it reads as the deliberate setting it is rather than as a
        // question the menu keeps asking.
        { label: "Appearance", items: [
            { label: "Dark Mode", cmd: "mode:dark", radio: true, checked: isDark },
            { label: "Light Mode", cmd: "mode:light", radio: true, checked: !isDark },
            { sep: true },
            { label: "Accent", items: [
                { label: "Sea Cyan",  cmd: "accent:#63c7dd" },
                { label: "Blue",      cmd: "accent:#7aa2f7" },
                { label: "Green",     cmd: "accent:#9ece6a" },
                { label: "Amber",     cmd: "accent:#e0af68" },
                { label: "Rose",      cmd: "accent:#f7768e" },
                { label: "Violet",    cmd: "accent:#bb9af7" },
                { label: "Grey",      cmd: "accent:#8a8a99" }
            ]},
            { label: "Roundness", items: [
                { label: "Square",   cmd: "round:0" },
                { label: "Slight",   cmd: "round:8" },
                { label: "Rounded",  cmd: "round:16" },
                { label: "Very Round", cmd: "round:26" }
            ]},
            { sep: true },
            { label: "Preferences...", cmd: "prefs", key: "Ctrl+,",
              icon: "preferences-system" }
        ]},
        { label: "Edit", items: [
            // The label names the operation it would reverse, so the menu answers
            // "what happens if I press this" before you press it.
            { label: (undo && undo.canUndo) ? "Undo " + undo.label : "Undo",
              cmd: "undo", key: "Ctrl+Z", icon: "edit-undo",
              enabled: !!(undo && undo.canUndo) },
            { sep: true },
            { label: "Cut", cmd: "cut", key: "Ctrl+X", icon: "edit-cut", enabled: any && !frozen },
            { label: "Copy", cmd: "copy", key: "Ctrl+C", icon: "edit-copy", enabled: any && !trash },
            { label: "Paste", cmd: "paste", key: "Ctrl+V", icon: "edit-paste", enabled: !frozen },
            { sep: true },
            { label: "Duplicate", cmd: "duplicate", key: "Ctrl+D", enabled: one && !frozen },
            { label: selectionCount > 1 ? "Rename " + selectionCount + " Items..." : "Rename...",
              cmd: "rename", key: "F2", enabled: any && !frozen },
            { sep: true },
            { label: "Select All", cmd: "select-all", key: "Ctrl+A", icon: "edit-select-all" },
            { label: "Deselect All", cmd: "deselect", enabled: any },
            { label: "Find...", cmd: "find", key: "Ctrl+F", icon: "edit-find" },
            { sep: true },
            { label: "Tags", items: tagMenuItems() },
            { sep: true },
            // In the trash "move to trash" is meaningless and restore is the point,
            // so the pair swaps rather than sitting there greyed out.
            { label: "Restore", cmd: "restore", enabled: any, visible: trash },
            { label: "Move to Trash", cmd: "trash", key: "Delete", icon: "edit-delete",
              enabled: any && !arc, visible: !trash },
            { label: "Delete Permanently", cmd: "purge", key: "Shift+Delete", enabled: any && !arc },
            { label: "Empty Trash", cmd: "empty-trash",
              enabled: currentCount > 0, visible: trash }
        ]},
        { label: "View", items: [
            { label: "Icons", cmd: "view:grid", key: "Ctrl+1", radio: true, checked: vm === "grid" },
            { label: "List", cmd: "view:list", key: "Ctrl+2", radio: true, checked: vm === "list" },
            { label: "Compact", cmd: "view:compact", key: "Ctrl+3", radio: true,
              checked: vm === "compact" },
            { sep: true },
            { label: "Filter...", cmd: "filter", key: "Ctrl+Shift+F", icon: "edit-find" },
            { label: "Inspector", cmd: "toggle-inspector", key: "Ctrl+I",
              checkable: true, checked: showInspector },
            { label: "Split View", cmd: "toggle-split", key: "Ctrl+Shift+D",
              checkable: true, checked: splitView },
            { sep: true },
            { label: "Zoom In", cmd: "zoom-in", key: "Ctrl+=", icon: "zoom-in" },
            { label: "Zoom Out", cmd: "zoom-out", key: "Ctrl+-", icon: "zoom-out" },
            { label: "Actual Size", cmd: "zoom-reset", key: "Ctrl+0", icon: "zoom-original" },
            { sep: true },
            { label: "Sort By", items: [
                { label: "Name", cmd: "sort:name", radio: true, checked: sf === "name" },
                { label: "Size", cmd: "sort:size", radio: true, checked: sf === "size" },
                { label: "Kind", cmd: "sort:extension", radio: true, checked: sf === "extension" },
                { label: "Date Modified", cmd: "sort:mtime", radio: true, checked: sf === "mtime" },
                { sep: true },
                { label: "Reversed", cmd: "sort-reverse", check: true,
                  checked: !!(be && be.sortDescending) }
            ]},
            { sep: true },
            { label: "Hidden Files", cmd: "toggle-hidden", key: "Ctrl+H", check: true,
              checked: !!(be && be.showHidden) },
            { label: "Preview Panel", cmd: "toggle-inspector", key: "Ctrl+I", check: true,
              checked: showInspector },
            { label: "Split View", cmd: "toggle-split", key: "F3", check: true,
              checked: splitView },
            { sep: true },
            { label: "Refresh", cmd: "refresh", key: "F5", icon: "view-refresh" }
        ]},
        { label: "Go", items: go }
        ]
    }

    // One string that changes whenever anything the menu displays does. Cheaper to
    // compare than the tree, and it makes the republish condition readable in one
    // place instead of scattered across a dozen onXChanged handlers.
    readonly property string menuStateKey: [
        selectionCount, selectedPathIsDir(), selectionIsArchive(), inTrashNow,
        backend ? backend.currentPath : "", backend ? backend.viewMode : "",
        backend ? backend.showHidden : false, backend ? backend.sortField : "",
        backend ? backend.sortDescending : false,
        splitView, activePane, showInspector, tabs.length,
        backend && backend.bookmarks ? backend.bookmarks.length : 0,
        currentCount > 0,
        undo ? undo.label : "", inTagView, inArchiveNow,
        backend && backend.storageDevices ? backend.storageDevices.length : 0,
        // THE APPEARANCE MENU'S OWN STATE. Without these the exported menu was
        // never rebuilt when the theme changed, so its radio marks kept whatever
        // they were at the last publish: switching to dark left "Light Mode"
        // showing as the selected one, in a window that was plainly dark.
        isDark, "" + accentColor, radiusCfg, themeIsOwn
    ].join("|")

    onMenuStateKeyChanged: menuPublish.restart()

    // Coalesced: a directory change moves the path, the selection and the listing in
    // the same tick, and each of those would otherwise be its own rebuild and its own
    // LayoutUpdated on the bus.
    Timer {
        id: menuPublish
        interval: 50
        onTriggered: if (appmenu) appmenu.setMenu(JSON.stringify(window.menuTree()))
    }

    Connections {
        target: appmenu
        ignoreUnknownSignals: true
        function onTriggered(cmd) { window.runMenuCommand(cmd) }
    }

    function runMenuCommand(cmd) {
        if (!cmd) return
        var be = backend
        var colon = cmd.indexOf(":")
        if (colon > 0) {
            var verb = cmd.substring(0, colon)
            var arg = cmd.substring(colon + 1)
            if (!be) return
            if (verb === "tag") { applyTag(arg); return }
            if (verb === "go") be.cd(arg)
            else if (verb === "view") be.setViewMode(arg)
            // The Appearance menu always means THIS WINDOW. If it happened to be
            // following the shell, the change moves it to its own theme first —
            // seeded from what is on screen, so nothing jumps except the one
            // thing that was actually asked for.
            else if (verb === "mode") { ownAppearance(); prefs.set("ownMode", arg) }
            else if (verb === "round") { ownAppearance(); prefs.set("ownRadius", parseInt(arg)) }
            else if (verb === "accent") { ownAppearance(); prefs.set("ownAccent", arg) }
            else if (verb === "sort") be.setSortField(arg)
            return
        }
        var picked = selectionPaths()
        switch (cmd) {
        case "new-folder":  newFolderDialog.openDialog(); break
        case "new-file":    newFileDialog.openDialog(); break
        case "new-tab":     createNewTab(); break
        case "new-window":  if (be) be.openNewWindow(be.currentPath); break
        case "open":        if (be && selectedPath) be.openFile(selectedPath); break
        case "open-with":   if (selectedPath) openWithModal.openDialog(selectedPath); break
        case "quick-look":  openQuickLook(); break
        case "compress":    if (picked.length > 0) compressDialog.openDialog(picked); break
        case "extract":     if (be && selectedPath) be.extractArchive(selectedPath, false); break
        case "extract-members": if (be) be.extractSelection(selectionPaths()); break
        case "terminal":    if (be) be.openTerminal(be.currentPath); break
        case "copy-path":   if (be) be.copyPath(selectedPath ? selectedPath : be.currentPath); break
        case "bookmark":    if (be && selectedPath) be.addBookmark(selectedPath, ""); break
        case "close-tab":   closeTab(activeTabIdx); break
        case "quit":        Qt.quit(); break

        case "cut":         if (be && picked.length > 0) be.setClipboard(picked, "cut"); break
        case "copy":        if (be && picked.length > 0) be.setClipboard(picked, "copy"); break
        case "paste":       if (be) be.pasteFiles(); break
        case "duplicate":   if (be && selectedPath) be.duplicateFile(selectedPath); break
        case "rename":      openRenameFor(); break
        case "undo":        doUndo(); break
        case "properties":  openProperties(); break
        case "duplicates":  if (be) duplicatesDialog.openFor(be.currentPath); break
        case "select-all":  selectAll(); break
        case "deselect":    selectedPaths = []; selectedPath = ""; if (be) be.selectFile(""); break
        case "find":        searchInput.forceActiveFocus(); break
        case "trash":       deleteSelection(); break
        case "purge":       deletePermanentlyAsk(); break
        case "restore":     restoreSelection(); break
        case "empty-trash": {
            var all = []
            all = currentModel ? currentModel.paths() : []
            if (all.length > 0) confirmPurge.openDialog(all)
            break
        }

        case "zoom-in":     zoomGrid(12); break
        case "zoom-out":    zoomGrid(-12); break
        case "zoom-reset":  if (be) be.setGridIconSize(120); break
        case "sort-reverse": if (be) be.setSortDescending(!be.sortDescending); break
        case "toggle-hidden": if (be) be.setShowHidden(!be.showHidden); break
        case "toggle-inspector": showInspector = !showInspector; break
        case "prefs": prefsDialog.openDialog(); break
        case "filter": filterBox.focusIt(); break
        case "toggle-split": toggleSplit(); break
        case "toggle-split": toggleSplit(); break
        case "refresh":     refreshAllPanes(); break

        case "back":        if (be) be.goBack(); break
        case "forward":     if (be) be.goForward(); break
        case "up":          if (be) be.goUp(); break
        case "go-trash":    if (be) be.cd(be.trashPath); break
        case "other-pane": {
            if (!splitView) toggleSplit()
            var here = be ? be.currentPath : ""
            if (here.length > 0) { if (activePane === 1) be1.cd(here); else be2.cd(here) }
            break
        }
        }
    }


    // =========================================================
    // 1. TOP TOOLBAR (Height: 52px, full width)
    // =========================================================
    Rectangle {
        id: topToolbar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 52
        color: bgPanel
        border.width: 1
        border.color: borderSoft
        z: 10

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 10

            // Navigation Pill Capsule (<, >, ^, ↻)
            Rectangle {
                height: 36
                width: navRow.implicitWidth + 8
                radius: rBase
                color: bgDark
                border.width: 1
                border.color: borderSoft

                RowLayout {
                    id: navRow
                    anchors.centerIn: parent
                    spacing: 2

                    // Back
                    Rectangle {
                        width: 30; height: 30; radius: rBase
                        color: backMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "arrow_back"; font.family: iconFont; color: textPrimary; font.pixelSize: 18 }
                        MouseArea { id: backMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (backend) backend.goBack() }
                    }

                    // Forward
                    Rectangle {
                        width: 30; height: 30; radius: rBase
                        color: fwdMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "arrow_forward"; font.family: iconFont; color: textPrimary; font.pixelSize: 18 }
                        MouseArea { id: fwdMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (backend) backend.goForward() }
                    }

                    // Up
                    Rectangle {
                        width: 30; height: 30; radius: rBase
                        color: upMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "arrow_upward"; font.family: iconFont; color: textPrimary; font.pixelSize: 18 }
                        MouseArea { id: upMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (backend) backend.goUp() }
                    }

                    // Refresh
                    Rectangle {
                        width: 30; height: 30; radius: rBase
                        color: refMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "refresh"; font.family: iconFont; color: textSecondary; font.pixelSize: 18 }
                        MouseArea { id: refMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: refreshDirectory() }
                    }
                }
            }

            // Interactive Breadcrumb & Path Bar. It grows with the path and stops
            // there — filling the whole bar left the edit button stranded a thousand
            // pixels from the folder name it edits.
            Rectangle {
                Layout.fillWidth: true
                Layout.minimumWidth: 190
                Layout.maximumWidth: manualPathEdit ? Number.POSITIVE_INFINITY
                                                    : Math.max(220, breadcrumbRow.width + 88)
                height: 36
                radius: rBase
                color: bgDark
                border.width: 1
                border.color: pathInput.activeFocus ? accentColor : borderSoft
                clip: true

                // Breadcrumbs Mode
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 4
                    visible: !manualPathEdit

                    Text {
                        text: "folder"
                        font.family: iconFont
                        color: accentColor
                        font.pixelSize: 19
                    }

                    Flickable {
                        id: crumbFlick
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: breadcrumbRow.width
                        clip: true
                        // Keep the folder you are actually in pinned in view. When a
                        // path is too long for the bar, the head is the half you can
                        // afford to lose, not the tail.
                        function pinToEnd() {
                            crumbFlick.contentX = Math.max(0, crumbFlick.contentWidth - crumbFlick.width)
                        }
                        onContentWidthChanged: crumbFlick.pinToEnd()
                        onWidthChanged: crumbFlick.pinToEnd()

                        Row {
                            id: breadcrumbRow
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Repeater {
                                model: backend ? backend.currentPath.split("/").filter(function(s){ return s !== "" }) : []
                                delegate: Row {
                                    id: segRow
                                    required property string modelData
                                    required property int index
                                    readonly property bool isLast: index === (backend.currentPath.split("/").filter(function(s){ return s !== "" }).length - 1)
                                    spacing: 2
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        text: "chevron_right"
                                        font.family: iconFont
                                        color: textMuted
                                        font.pixelSize: 17
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Rectangle {
                                        height: 26
                                        width: segText.implicitWidth + 14
                                        radius: rBase
                                        color: segRow.isLast ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.12) : (segMa.containsMouse ? bgHover : "transparent")
                                        anchors.verticalCenter: parent.verticalCenter

                                        Text {
                                            id: segText
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: segRow.isLast ? accentColor : textPrimary
                                            font.pixelSize: 12
                                            font.bold: true
                                        }

                                        MouseArea {
                                            id: segMa
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                var parts = backend.currentPath.split("/").filter(function(s){ return s !== "" })
                                                var targetPath = "/" + parts.slice(0, index + 1).join("/")
                                                backend.cd(targetPath)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Edit path button
                    Rectangle {
                        width: 26; height: 26; radius: rBase
                        color: editPathMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "edit"; font.family: iconFont; color: textSecondary; font.pixelSize: 16 }
                        MouseArea {
                            id: editPathMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                manualPathEdit = true
                                pathInput.text = backend.currentPath
                                pathInput.forceActiveFocus()
                            }
                        }
                    }
                }

                // Manual Text Edit Mode
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    visible: manualPathEdit

                    TextInput {
                        id: pathInput
                        Layout.fillWidth: true
                        color: textPrimary
                        font.pixelSize: 12
                        text: backend ? backend.currentPath : ""
                        selectByMouse: true
                        onAccepted: {
                            if (backend) backend.cd(text)
                            manualPathEdit = false
                        }
                        Keys.onEscapePressed: manualPathEdit = false
                    }

                    Rectangle {
                        width: 24; height: 24; radius: rBase
                        color: closePathMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "close"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                        MouseArea { id: closePathMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: manualPathEdit = false }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

            // Live Search Field
            Rectangle {
                visible: window.width >= 800 || searchInput.text.length > 0
                Layout.preferredWidth: Math.max(132, Math.min(260, window.width * 0.2))
                height: 36
                radius: rBase
                color: bgDark
                border.width: 1
                border.color: searchInput.activeFocus ? accentColor : borderSoft

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 7
                    spacing: 6
                    Text { text: "search"; font.family: iconFont; color: textSecondary; font.pixelSize: 17 }
                    TextInput {
                        id: searchInput
                        Layout.fillWidth: true
                        color: textPrimary
                        font.pixelSize: 12
                        clip: true

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: searchInput.text.length === 0
                            text: "Search this folder"
                            color: textMuted
                            font.pixelSize: 12
                        }
                        onTextChanged: {
                            if (backend) {
                                backend.setSearchQuery(text)
                                refreshDirectory()
                            }
                        }
                    }
                    Rectangle {
                        width: 20; height: 20; radius: rCard
                        visible: searchInput.text.length > 0
                        color: clearSearchMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "close"; font.family: iconFont; color: textSecondary; font.pixelSize: 14 }
                        MouseArea {
                            id: clearSearchMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                searchInput.text = ""
                                if (backend) {
                                    backend.setSearchQuery("")
                                    refreshDirectory()
                                }
                            }
                        }
                    }
                }
            }

            // FILTER, WHICH IS NOT SEARCH. Dolphin draws this distinction and it
            // is a real one: search walks subdirectories and takes as long as
            // that takes, while the filter only hides rows already listed and is
            // therefore instant. Two different questions — "where is this file"
            // and "show me fewer of these" — so two different boxes.
            Rectangle {
                id: filterBox
                visible: window.width >= 940 || filterInput.text.length > 0
                Layout.preferredWidth: Math.max(118, Math.min(200, window.width * 0.14))
                height: 36
                radius: rBase
                color: bgDark
                border.width: 1
                border.color: filterInput.activeFocus ? accentColor
                              : ((backend && backend.activeFilterCount > 0)
                                 ? accentInk : borderSoft)

                function focusIt() { filterInput.forceActiveFocus(); filterInput.selectAll() }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 7
                    spacing: 6
                    Text {
                        text: "filter_alt"; font.family: iconFont
                        color: filterInput.text.length > 0 ? accentInk : textSecondary
                        font.pixelSize: 16
                    }
                    TextInput {
                        id: filterInput
                        Layout.fillWidth: true
                        color: textPrimary
                        font.pixelSize: 12
                        clip: true
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: filterInput.text.length === 0
                            text: "Filter"
                            color: textMuted
                            font.pixelSize: 12
                        }
                        onTextChanged: if (backend) backend.setFilterText(text)
                        Keys.onEscapePressed: { filterInput.text = ""; restoreKeyFocus() }
                    }
                    Rectangle {
                        width: 20; height: 20; radius: rSmall
                        visible: backend && backend.activeFilterCount > 0
                        color: clearFilterMa.containsMouse ? bgHover : "transparent"
                        Text {
                            anchors.centerIn: parent; text: "close"
                            font.family: iconFont; color: textSecondary; font.pixelSize: 14
                        }
                        MouseArea {
                            id: clearFilterMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                filterInput.text = ""
                                if (backend) backend.clearFilters()
                            }
                        }
                    }

                    // The rest of the filter. A name box alone can only answer
                    // "what is it called"; kind, size, age and tag are the other
                    // questions you can ask about a file without opening it, and
                    // are what Finder and Explorer both put behind this control.
                    Rectangle {
                        width: 20; height: 20; radius: rSmall
                        color: filterMenu.visible ? accentWash
                             : (facetMa.containsMouse ? bgHover : "transparent")
                        Text {
                            anchors.centerIn: parent
                            text: "tune"
                            font.family: iconFont; font.pixelSize: 15
                            color: (backend && backend.activeFilterCount > 0)
                                   ? accentInk : textSecondary
                        }
                        MouseArea {
                            id: facetMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: filterMenu.toggle(filterBox)
                        }
                    }
                }
            }

            // THE OPERATIONS BUTTON. Only visible while something is running, so
            // it costs no width the rest of the time. The ring fills as the work
            // does, which is the whole status at a glance; the popover behind it
            // is the detail and the way out.
            Rectangle {
                id: opsButton
                visible: opsCentre.running > 0
                Layout.preferredWidth: 36
                height: 36
                radius: rBase
                color: opsBtnMa.containsMouse || opsCentre.open ? bgHover : bgDark
                border.width: 1
                border.color: opsCentre.open ? accentColor : borderSoft

                Canvas {
                    id: opsRing
                    anchors.centerIn: parent
                    width: 20; height: 20
                    property real frac: opsCentre.overallFraction
                    property color trackCol: borderHard
                    property color fillCol: accentColor
                    onFracChanged: requestPaint()
                    onTrackColChanged: requestPaint()
                    onFillColChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var cx = width / 2, cy = height / 2, r = width / 2 - 2
                        ctx.lineWidth = 3
                        ctx.strokeStyle = trackCol
                        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
                        if (frac > 0) {
                            ctx.strokeStyle = fillCol
                            ctx.beginPath()
                            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac)
                            ctx.stroke()
                        }
                    }
                }

                Rectangle {
                    visible: opsCentre.running > 1
                    anchors { right: parent.right; top: parent.top; margins: 2 }
                    width: 13; height: 13; radius: rBase
                    color: accentColor
                    Text {
                        anchors.centerIn: parent
                        text: opsCentre.running
                        font.family: monoFont; font.pixelSize: 9; font.bold: true
                        color: onAccent
                    }
                }

                MouseArea {
                    id: opsBtnMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: opsCentre.open = !opsCentre.open
                }
            }

            // Action Controls — grouped by what they do rather than eight loose boxes
            ToolGroup {
                ToolBtn {
                    // "preview" reads as a framed page; the plain eye is the
                    // universal hidden-files glyph and shouldn't be spent here.
                    glyph: "preview"; tip: "Quick Look  (Space)"
                    on: selectedPath.length > 0
                    onActivated: openQuickLook()
                }
                ToolBtn {
                    glyph: "visibility_off"
                    tip: "Hidden files  (Ctrl+H)"
                    active: backend && backend.showHidden
                    onActivated: if (backend) backend.setShowHidden(!backend.showHidden)
                }
            }

            ToolGroup {
                ToolBtn {
                    glyph: "grid_view"; tip: "Icon view  (Ctrl+1)"
                    active: backend && backend.viewMode === "grid"
                    onActivated: if (backend) backend.setViewMode("grid")
                }
                ToolBtn {
                    glyph: "view_list"; tip: "List view  (Ctrl+2)"
                    active: backend && backend.viewMode === "list"
                    onActivated: if (backend) backend.setViewMode("list")
                }
            }

            ToolGroup {
                visible: window.width >= 1000
                ToolBtn {
                    glyph: "create_new_folder"; tip: "New folder  (Ctrl+Shift+N)"
                    onActivated: newFolderDialog.openDialog()
                }
                ToolBtn {
                    glyph: "note_add"; tip: "New file"
                    onActivated: newFileDialog.openDialog()
                }
            }

            // No light/dark control here on purpose: the window follows appearance.json,
            // which the shell owns. A second switch for the same setting could only ever
            // disagree with the first, and this one reached out and changed the whole desktop.
            ToolGroup {
                ToolBtn {
                    glyph: "splitscreen_left"; tip: "Split view  (F3)"
                    active: splitView
                    onActivated: toggleSplit()
                }
                ToolBtn {
                    glyph: "dock_to_right"; tip: "Inspector"
                    active: showInspector
                    onActivated: showInspector = !showInspector
                }
            }
        }
    }

    // =========================================================
    // 2. BOTTOM STATUS BAR (Height: 28px, full width)
    // =========================================================
    Rectangle {
        id: bottomStatusBar
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 28
        color: bgPanel
        border.width: 1
        border.color: borderSoft
        z: 10

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 12

            Text {
                text: currentCount + " items" + (selectedPaths.length > 0 ? " (" + selectedPaths.length + " selected)" : "")
                color: textSecondary
                font.pixelSize: 11
            }

            Text { text: "•"; color: textMuted; font.pixelSize: 10 }

            RowLayout {
                spacing: 6
                Text { text: "hard_drive"; font.family: iconFont; color: textMuted; font.pixelSize: 14 }
                Text {
                    text: backend && backend.storageStats ? "Free: " + backend.storageStats.freeStr + " / " + backend.storageStats.totalStr : "Storage: --"
                    color: textSecondary
                    font.pixelSize: 11
                }
            }

            Text { text: "•"; color: textMuted; font.pixelSize: 10 }

            Text {
                text: backend ? backend.statusMessage : "Ready"
                color: textPrimary
                font.pixelSize: 11
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            // Icon zoom. Ctrl+wheel and Ctrl+/- do the same thing; this is here so
            // the feature is findable without knowing the shortcut.
            RowLayout {
                spacing: 4
                visible: backend && backend.viewMode === "grid"

                Repeater {
                    model: [ {g: "zoom_out", d: -12}, {g: "zoom_in", d: 12} ]
                    delegate: Rectangle {
                        id: zoomBtn
                        required property var modelData
                        width: 20; height: 20; radius: rBase
                        readonly property bool atLimit: backend
                            && ((modelData.d < 0 && backend.gridIconSize <= 64)
                             || (modelData.d > 0 && backend.gridIconSize >= 256))
                        color: zoomMa.containsMouse && !zoomBtn.atLimit ? bgHover : "transparent"
                        opacity: zoomBtn.atLimit ? 0.35 : 1.0

                        Text {
                            anchors.centerIn: parent
                            text: zoomBtn.modelData.g
                            font.family: iconFont
                            font.pixelSize: 14
                            color: zoomMa.containsMouse && !zoomBtn.atLimit ? accentInk : textSecondary
                        }

                        MouseArea {
                            id: zoomMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !zoomBtn.atLimit
                            cursorShape: Qt.PointingHandCursor
                            onClicked: zoomGrid(zoomBtn.modelData.d)
                        }
                    }
                }

                Text {
                    text: gridIcon + "px"
                    color: textMuted
                    font.pixelSize: 10
                    Layout.preferredWidth: 34
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }

    // =========================================================
    // 2. MODERN TAB BAR STRIP (Height: 38px, multi-tab browsing!)
    // =========================================================
    Rectangle {
        id: tabBarStrip
        anchors.top: topToolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 38
        color: isDark ? "#11111a" : bgCard
        border.width: 1
        border.color: borderSoft
        z: 8

        Flickable {
            id: tabFlickable
            anchors.left: parent.left
            anchors.right: newTabBtnRect.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            contentWidth: tabRow.width + 12
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Row {
                id: tabRow
                height: parent.height
                spacing: 4
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                    model: tabs
                    delegate: Rectangle {
                        id: tabCard
                        objectName: "tabCard"
                        required property var modelData
                        required property int index
                        // `index` is not readable from outside the delegate, so the
                        // row hit test needs its own copy to report back.
                        readonly property int tabIndex: index
                        readonly property bool isCurrent: index === activeTabIdx
                        width: Math.min(220, Math.max(130, tabLabel.implicitWidth + 64))
                        height: 30
                        anchors.verticalCenter: parent.verticalCenter

                        // A TAB, NOT A LOZENGE. Rounding all four corners of
                        // something 30px tall by the shared radius turned each tab
                        // into a pill with semicircular ends — which is what read
                        // as choppy, because the ends are almost half-circles and
                        // the 1px border has to describe them. Tabs round at the
                        // TOP and sit flat on the strip, the way a tab does, and
                        // the radius is capped against the height so a high
                        // roundness setting cannot turn them back into lozenges.
                        readonly property real tabR: Math.min(rBase, height * 0.34)
                        topLeftRadius: tabR
                        topRightRadius: tabR
                        bottomLeftRadius: 0
                        bottomRightRadius: 0
                        antialiasing: true

                        color: tabDropHighlight.visible ? accentWash
                             : (isCurrent ? bgCard : (tabMa.containsMouse ? bgHover : "transparent"))
                        border.width: isCurrent ? 1 : (tabMa.containsMouse ? 1 : 0)
                        border.color: isCurrent ? borderSoft : "transparent"

                        // Active Glowing Indicator Strip on bottom
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 2
                            color: accentColor
                            visible: isCurrent
                        }

                        // Merge affordance: the tab about to absorb another says so.
                        Rectangle {
                            anchors.fill: parent
                            topLeftRadius: tabCard.tabR
                            topRightRadius: tabCard.tabR
                            bottomLeftRadius: 0
                            bottomRightRadius: 0
                            antialiasing: true
                            visible: window.tabMergeTarget === tabCard.index
                            color: accentWash
                            border.width: 2
                            border.color: accentColor
                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                Text {
                                    text: "splitscreen_right"
                                    font.family: iconFont; font.pixelSize: 15
                                    color: accentInk
                                }
                                Text {
                                    text: "Split"
                                    font.pixelSize: 11; font.bold: true
                                    color: accentInk
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // Tab Drop Highlight for Drag & Drop
                        Rectangle {
                            id: tabDropHighlight
                            anchors.fill: parent
                            topLeftRadius: tabCard.tabR
                            topRightRadius: tabCard.tabR
                            bottomLeftRadius: 0
                            bottomRightRadius: 0
                            antialiasing: true
                            color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.25)
                            border.width: 1.5
                            border.color: accentColor
                            visible: false
                        }

                        DropArea {
                            anchors.fill: parent
                            keys: ["files"]
                            onEntered: {
                                tabDropHighlight.visible = true
                                tabHoverTimer.start()
                            }
                            onExited: {
                                tabDropHighlight.visible = false
                                tabHoverTimer.stop()
                            }
                            onDropped: function(drop) {
                                tabDropHighlight.visible = false
                                tabHoverTimer.stop()
                                var paths = window.draggedPaths.length > 0 ? window.draggedPaths : []
                                if (paths.length > 0 && backend) {
                                    backend.moveFiles(paths, modelData.path)
                                }
                            }
                        }

                        Timer {
                            id: tabHoverTimer
                            interval: 500
                            onTriggered: switchTab(index)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 6
                            spacing: 6

                            // Tab Folder Icon
                            Text {
                                text: "folder"
                                font.family: iconFont
                                font.pixelSize: 16
                                color: isCurrent ? accentColor : textSecondary
                            }

                            // Tab Title
                            Text {
                                id: tabLabel
                                Layout.fillWidth: true
                                text: modelData.name || "Folder"
                                color: isCurrent ? textPrimary : textSecondary
                                font.pixelSize: 11
                                font.bold: isCurrent
                                elide: Text.ElideMiddle
                            }

                            // Tab Close Button (x)
                            Rectangle {
                                width: 18
                                height: 18
                                radius: rBase
                                color: tabCloseMa.containsMouse ? (isDark ? borderHard : borderHard) : "transparent"
                                visible: tabs.length > 1 && (isCurrent || tabMa.containsMouse)

                                Text {
                                    anchors.centerIn: parent
                                    text: "close"
                                    font.family: iconFont
                                    font.pixelSize: 12
                                    color: isCurrent ? textPrimary : textMuted
                                }

                                MouseArea {
                                    id: tabCloseMa
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: closeTab(index)
                                }
                            }
                        }

                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            z: -1
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true

                            // REORDER BY SWAPPING, NOT BY DRAGGING THE ITEM.
                            // These tabs live in a Row, which owns their x — moving
                            // one by hand just fights the layout. So the pointer is
                            // hit-tested against the row instead and the MODEL is
                            // reordered; the Row then re-lays out on its own and the
                            // tab appears to follow the cursor.
                            property bool didDrag: false

                            onPressed: tabMa.didDrag = false

                            onPositionChanged: function(mouse) {
                                if (!tabMa.pressed || tabs.length < 2) return
                                var pt = tabMa.mapToItem(tabRow, mouse.x, mouse.y)
                                var zone = window.tabZoneAtX(pt.x)
                                if (zone.idx < 0 || zone.idx === tabCard.index) {
                                    window.tabMergeTarget = -1
                                    return
                                }
                                if (zone.merge) {
                                    // Over the middle of another tab: this is a
                                    // merge, so do NOT reorder underneath it.
                                    window.tabMergeTarget = zone.idx
                                    tabMa.didDrag = true
                                } else {
                                    window.tabMergeTarget = -1
                                    window.moveTab(tabCard.index, zone.idx)
                                    tabMa.didDrag = true
                                }
                            }

                            onReleased: {
                                if (window.tabMergeTarget >= 0
                                        && window.tabMergeTarget !== tabCard.index) {
                                    window.mergeTabIntoSplit(tabCard.index,
                                                             window.tabMergeTarget)
                                }
                                window.tabMergeTarget = -1
                            }
                            onCanceled: window.tabMergeTarget = -1

                            onClicked: function(mouse) {
                                if (mouse.button === Qt.MiddleButton) {
                                    closeTab(tabCard.index)
                                } else if (mouse.button === Qt.RightButton) {
                                    // mapToItem needs an ITEM, and the root here
                                    // is a Window — null maps to scene coordinates,
                                    // which is what a top-level popup is placed in.
                                    var pt = tabMa.mapToItem(null, mouse.x, mouse.y)
                                    tabMenu.openFor(tabCard.index, pt.x, pt.y)
                                } else if (!tabMa.didDrag) {
                                    // A drag that ended over this tab is not a click
                                    // asking to switch to it.
                                    switchTab(tabCard.index)
                                }
                            }
                        }
                    }
                }
            }
        }

        // New Tab (+) Button
        Rectangle {
            id: newTabBtnRect
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 26
            height: 26
            radius: rBase
            color: newTabMa.containsMouse ? bgHover : "transparent"
            border.width: 1
            border.color: newTabMa.containsMouse ? borderSoft : "transparent"

            Text {
                anchors.centerIn: parent
                text: "add"
                font.family: iconFont
                font.pixelSize: 18
                color: textSecondary
            }

            MouseArea {
                id: newTabMa
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: createNewTab()
            }
        }
    }

    // =========================================================
    // 3. LEFT SIDEBAR (Fixed Width: 240px, anchored!)
    // =========================================================
    Rectangle {
        id: leftSidebar
        anchors.top: tabBarStrip.bottom
        anchors.bottom: bottomStatusBar.top
        anchors.left: parent.left
        width: sidebarW
        Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        color: bgPanel
        border.width: 1
        border.color: borderSoft
        z: 5

        ScrollView {
            anchors.fill: parent
            anchors.margins: sidebarCollapsed ? 7 : 12
            clip: true

            Column {
                width: parent.width
                spacing: 14

                // ---- PLACES: Recent, Starred, Trash ----
                //
                // Virtual folders, so they behave like any other location — the
                // breadcrumb, tabs, history and the filter box all work on them
                // with no special cases. Recent is the freedesktop list every GTK
                // application already writes to, so what appears here is what you
                // actually opened, in any application.
                Column {
                    width: parent.width
                    spacing: 3

                    Text {
                        visible: !sidebarCollapsed
                        text: "PLACES"
                        font.family: monoFont
                        font.pixelSize: tLabel
                        font.letterSpacing: 1.2
                        color: textMuted
                        leftPadding: 6
                    }

                    Repeater {
                        model: [
                            { g: "history",  n: "Recent",  p: "/Recent" },
                            { g: "star",     n: "Starred", p: "/Starred" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            width: parent.width
                            height: 30
                            radius: rBase
                            readonly property bool here: backend && backend.currentPath === modelData.p
                            color: here ? accentWash : (plMa.containsMouse ? bgHover : "transparent")
                            border.width: 1
                            border.color: here ? accentColor : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 7
                                anchors.rightMargin: 7
                                spacing: 9
                                Text {
                                    text: modelData.g
                                    font.family: iconFont
                                    font.pixelSize: 17
                                    color: parent.parent.here ? accentInk : textSecondary
                                }
                                Text {
                                    visible: !sidebarCollapsed
                                    text: modelData.n
                                    font.pixelSize: tDense
                                    color: parent.parent.here ? textPrimary : textSecondary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: !sidebarCollapsed && modelData.p === "/Starred"
                                             && stars && stars.count > 0
                                    text: stars ? stars.count : ""
                                    font.family: monoFont
                                    font.pixelSize: 10
                                    font.features: ({ "tnum": 1 })
                                    color: textMuted
                                }
                            }

                            MouseArea {
                                id: plMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (backend) backend.cd(modelData.p)
                            }
                        }
                    }
                }

                // ---- FAVORITES SECTION ----
                RowLayout {
                    width: parent.width
                    visible: !sidebarCollapsed
                    Text {
                        text: "FAVORITES"
                        font.pixelSize: 10
                        font.bold: true
                        font.letterSpacing: 1.2
                        color: textMuted
                        leftPadding: 6
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 22; height: 22; radius: rBase
                        color: addFavMa.containsMouse ? bgHover : "transparent"
                        border.width: 1
                        border.color: addFavMa.containsMouse ? borderSoft : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "add"
                            font.family: iconFont
                            font.pixelSize: 16
                            color: addFavMa.containsMouse ? accentColor : textSecondary
                        }
                        MouseArea {
                            id: addFavMa
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend) backend.addBookmark(backend.currentPath, "")
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: 3

                    Repeater {
                        model: backend ? backend.bookmarks : []
                        delegate: Rectangle {
                            id: bmCard
                            required property var modelData
                            width: sidebarCollapsed ? 44 : 216
                            height: 34
                            radius: rBase
                            readonly property bool isActive: !!(backend && backend.currentPath === modelData.path)
                            color: bmDropArea.containsDrag ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.28)
                                 : (isActive ? accentGlow : (bmMa.containsMouse ? bgHover : "transparent"))
                            border.width: bmDropArea.containsDrag ? 1.5 : 0
                            border.color: accentColor

                            Timer {
                                id: bmHoverNavTimer
                                interval: 500
                                repeat: false
                                onTriggered: {
                                    if (backend) backend.cd(modelData.path)
                                }
                            }

                            DropArea {
                                id: bmDropArea
                                anchors.fill: parent
                                onEntered: (drag) => {
                                    bmHoverNavTimer.start()
                                }
                                onExited: {
                                    bmHoverNavTimer.stop()
                                }
                                onDropped: function(drop) {
                                    bmHoverNavTimer.stop()
                                    var paths = []
                                    if (drop.hasUrls) {
                                        for (var i = 0; i < drop.urls.length; i++) {
                                            paths.push(backend.urlToPath("" + drop.urls[i]))
                                        }
                                    }
                                    if (paths.length > 0 && backend) {
                                        backend.moveFiles(paths, modelData.path)
                                        drop.acceptProposedAction()
                                    }
                                }
                            }

                            Rectangle {
                                width: 3
                                height: 18
                                radius: rSmall
                                color: accentColor
                                anchors.left: parent.left
                                anchors.leftMargin: 2
                                anchors.verticalCenter: parent.verticalCenter
                                visible: isActive
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: sidebarCollapsed ? 0 : 12
                                anchors.rightMargin: sidebarCollapsed ? 0 : 8
                                spacing: sidebarCollapsed ? 0 : 10

                                Text {
                                    text: modelData.icon || "folder"
                                    font.family: iconFont
                                    font.variableAxes: iconFilled
                                    color: isActive ? accentInk : textSecondary
                                    font.pixelSize: 19
                                    Layout.fillWidth: sidebarCollapsed
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                Text {
                                    visible: !sidebarCollapsed
                                    text: modelData.name
                                    color: isActive ? accentInk : textPrimary
                                    font.pixelSize: 12
                                    font.bold: isActive
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: bmMa
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    if (mouse.button === Qt.RightButton) {
                                        var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                                        bookmarkMenu.openMenu(pt.x, pt.y, modelData.path, modelData.name)
                                    } else if (mouse.button === Qt.MiddleButton) {
                                        createNewTab(modelData.path)
                                    } else {
                                        if (backend) backend.cd(modelData.path)
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: borderSoft }

                // ---- TRASH ----
                Rectangle {
                    id: trashRow
                    width: sidebarCollapsed ? 44 : 216
                    height: 34
                    radius: rBase
                    readonly property bool isActive: !!(backend && backend.inTrash)
                    color: trashDrop.containsDrag ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.28)
                         : (trashRow.isActive ? accentGlow : (trashRowMa.containsMouse ? bgHover : "transparent"))
                    border.width: trashDrop.containsDrag ? 1.5 : 0
                    border.color: accentColor

                    DropArea {
                        id: trashDrop
                        anchors.fill: parent
                        onDropped: function(drop) {
                            var paths = []
                            if (drop.hasUrls) {
                                for (var i = 0; i < drop.urls.length; i++)
                                    paths.push(backend.urlToPath("" + drop.urls[i]))
                            }
                            if (paths.length > 0 && backend) {
                                backend.trashFiles(paths)
                                drop.acceptProposedAction()
                            }
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: sidebarCollapsed ? 0 : 12
                        anchors.rightMargin: sidebarCollapsed ? 0 : 8
                        spacing: sidebarCollapsed ? 0 : 10

                        Text {
                            text: "delete"
                            font.family: iconFont
                            font.variableAxes: iconFilled
                            color: trashRow.isActive ? accentInk : textSecondary
                            font.pixelSize: 19
                            Layout.fillWidth: sidebarCollapsed
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            visible: !sidebarCollapsed
                            text: "Trash"
                            color: trashRow.isActive ? accentInk : textPrimary
                            font.pixelSize: 12
                            font.bold: trashRow.isActive
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: trashRowMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (backend) backend.cd(backend.trashPath)
                    }
                }

                // ---- TAGS SECTION ----
                //
                // Only tags that are actually in use appear. A fixed list of seven
                // colours, most of them empty, is a menu of things to do rather
                // than a list of where your files are.
                Text {
                    visible: !sidebarCollapsed && window.tagsInUse.length > 0
                    text: "TAGS"
                    font.pixelSize: 10
                    font.bold: true
                    font.letterSpacing: 1.2
                    color: textMuted
                    leftPadding: 6
                }

                Column {
                    width: parent.width
                    spacing: 3
                    visible: window.tagsInUse.length > 0

                    Repeater {
                        model: window.tagsInUse
                        delegate: Rectangle {
                            id: tagRow
                            required property string modelData
                            width: sidebarCollapsed ? 44 : 216
                            height: 30
                            radius: rBase
                            readonly property bool isActive: window.tagViewName === tagRow.modelData
                            color: tagDrop.containsDrag
                                 ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.28)
                                 : (tagRow.isActive ? accentGlow
                                    : (tagRowMa.containsMouse ? bgHover : "transparent"))
                            border.width: tagDrop.containsDrag ? 1.5 : 0
                            border.color: accentColor

                            Rectangle {
                                visible: tagRow.isActive
                                width: 3; height: 16; radius: rBase
                                color: accentInk
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: sidebarCollapsed ? 0 : 12
                                anchors.rightMargin: sidebarCollapsed ? 0 : 10
                                spacing: 9
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter | (sidebarCollapsed ? Qt.AlignHCenter : Qt.AlignLeft)
                                    Layout.leftMargin: sidebarCollapsed ? 16 : 0
                                    width: 11; height: 11; radius: rBase
                                    color: tagColor(tagRow.modelData)
                                    border.width: 1.5
                                    border.color: Qt.rgba(0, 0, 0, isDark ? 0.35 : 0.15)
                                }
                                Text {
                                    visible: !sidebarCollapsed
                                    text: tagRow.modelData
                                    font.pixelSize: 12
                                    font.bold: tagRow.isActive
                                    color: tagRow.isActive ? accentInk : textPrimary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: !sidebarCollapsed
                                    text: "" + (tagCounts[tagRow.modelData] || 0)
                                    font.pixelSize: 10
                                    color: textMuted
                                }
                            }

                            // Dropping onto a tag applies it — the same gesture that
                            // moves a file into a folder, for the thing tags are a
                            // lighter-weight alternative to.
                            DropArea {
                                id: tagDrop
                                anchors.fill: parent
                                onDropped: function(drop) {
                                    if (tagstore && window.draggedPaths.length > 0)
                                        tagstore.setTag(window.draggedPaths, tagRow.modelData)
                                    drop.accept()
                                }
                            }

                            MouseArea {
                                id: tagRowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (backend) backend.cd("/Tags/" + tagRow.modelData)
                            }
                        }
                    }
                }

                // ---- DEVICES SECTION ----
                //
                // Everything the machine can reach, mounted or not. An unmounted
                // drive is the interesting case: it is shown greyed with a mount
                // affordance, because a USB stick you have just plugged in is
                // exactly when you go looking for it and exactly when the old
                // /proc/mounts list could not see it.
                Text {
                    visible: !sidebarCollapsed
                    text: "DEVICES"
                    font.pixelSize: 10
                    font.bold: true
                    font.letterSpacing: 1.2
                    color: textMuted
                    leftPadding: 6
                }

                Column {
                    width: parent.width
                    spacing: 3

                    Repeater {
                        model: backend ? backend.storageDevices : []
                        delegate: Rectangle {
                            id: drvRow
                            required property var modelData
                            width: sidebarCollapsed ? 44 : 216
                            height: (!sidebarCollapsed && drvRow.modelData.mounted
                                     && drvRow.modelData.usedPct >= 0) ? 44 : 34
                            radius: rBase
                            readonly property bool isActive: !!(backend && backend.currentPath === drvRow.modelData.path
                                                                && drvRow.modelData.path)
                            color: drvRow.isActive ? accentGlow : (drvMa.containsMouse ? bgHover : "transparent")
                            opacity: drvRow.modelData.mounted ? 1.0 : 0.62

                            ColumnLayout {
                                // ABOVE drvMa, AND THIS IS THE LEVEL THAT DECIDES IT.
                                // z orders an item against its OWN siblings. The eject
                                // button carried z: 2, but its siblings are the other
                                // cells of the row it sits in -- drvMa is a sibling of
                                // THIS layout, one level up, and being declared last it
                                // hit-tested on top of the whole stack. So every press
                                // of the eject button went to the row instead, which is
                                // why it read as not being clicked at all. Nothing else
                                // in here accepts a mouse event, so the rest of the row
                                // still falls through to drvMa as before.
                                z: 2
                                anchors.fill: parent
                                anchors.leftMargin: sidebarCollapsed ? 0 : 12
                                anchors.rightMargin: sidebarCollapsed ? 0 : 8
                                anchors.topMargin: 4
                                anchors.bottomMargin: 4
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: sidebarCollapsed ? 0 : 10

                                    Text {
                                        text: drvRow.modelData.icon
                                        font.family: iconFont
                                        font.variableAxes: iconFilled
                                        color: drvRow.isActive ? accentInk
                                             : (drvRow.modelData.removable ? catInk("archive", textSecondary)
                                                                           : textSecondary)
                                        font.pixelSize: 19
                                        Layout.fillWidth: sidebarCollapsed
                                        horizontalAlignment: Text.AlignHCenter
                                    }

                                    ColumnLayout {
                                        visible: !sidebarCollapsed
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            text: drvRow.modelData.name
                                            color: drvRow.isActive ? accentInk : textPrimary
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                            elide: Text.ElideMiddle
                                        }
                                        Text {
                                            visible: !drvRow.modelData.mounted
                                            text: drvRow.modelData.sizeStr + " · not mounted"
                                            color: textMuted
                                            font.pixelSize: 9
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }
                                    }

                                    // Eject a removable drive, UNMOUNT a fixed one,
                                    // mount anything that is not mounted. The three
                                    // are not interchangeable: eject powers the drive
                                    // down, which is what you want before pulling a
                                    // stick out and emphatically not what you want for
                                    // a partition of the disk the machine runs on.
                                    // Root gets none of them.
                                    Rectangle {
                                        // MUST sit above the row's own click handler.
                                        // That handler is declared after this and so
                                        // paints and hit-tests on top by default —
                                        // which meant every press of this button was
                                        // silently swallowed and navigated into the
                                        // volume instead of ejecting it.
                                        z: 2
                                        // ALWAYS PRESENT, JUST DIMMED. Showing it only
                                        // on hover made its own visibility depend on a
                                        // MouseArea it sits on top of: moving onto the
                                        // button took the hover away from the row, so
                                        // the condition that put it there stopped being
                                        // true, and it could vanish out from under the
                                        // pointer mid-click. Opacity has no such
                                        // feedback loop.
                                        visible: !sidebarCollapsed && !drvRow.modelData.system
                                        opacity: (drvMa.containsMouse || ejMa.containsMouse
                                                  || !drvRow.modelData.mounted) ? 1.0 : 0.45
                                        Behavior on opacity { NumberAnimation { duration: mFast } }
                                        Layout.preferredWidth: 22
                                        Layout.preferredHeight: 22
                                        radius: rBase
                                        color: ejMa.containsMouse ? bgCard : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: !drvRow.modelData.mounted ? "play_arrow"
                                                : (drvRow.modelData.removable ? "eject" : "stop_circle")
                                            font.family: iconFont
                                            font.pixelSize: 14
                                            color: ejMa.containsMouse ? accentInk : textMuted
                                        }
                                        MouseArea {
                                            id: ejMa
                                            objectName: "ejectFor:" + drvRow.modelData.dev
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (!backend) return
                                                if (!drvRow.modelData.mounted)
                                                    backend.mountDevice(drvRow.modelData.dev)
                                                else if (drvRow.modelData.removable)
                                                    backend.ejectDevice(drvRow.modelData.dev)
                                                else
                                                    backend.unmountDevice(drvRow.modelData.dev)
                                            }
                                        }
                                    }
                                }

                                // How full it is, only where that is knowable.
                                Rectangle {
                                    visible: !sidebarCollapsed && drvRow.modelData.mounted
                                             && drvRow.modelData.usedPct >= 0
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 29
                                    Layout.rightMargin: 2
                                    height: 3
                                    radius: rBase
                                    color: isDark ? "#26263a" : bgHover
                                    Rectangle {
                                        width: parent.width * Math.min(1, Math.max(0, drvRow.modelData.usedPct / 100))
                                        height: parent.height
                                        radius: rBase
                                        color: drvRow.modelData.usedPct >= 90 ? dangerInk : accentInk
                                    }
                                }
                            }

                            MouseArea {
                                id: drvMa
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                cursorShape: Qt.PointingHandCursor
                                // The eject control sits on top of this and takes its
                                // own clicks; everything else opens the volume, and an
                                // unmounted one mounts first because that is plainly
                                // what clicking it means.
                                onClicked: function(mouse) {
                                    if (!backend) return
                                    if (!drvRow.modelData.mounted) {
                                        backend.mountDevice(drvRow.modelData.dev)
                                        return
                                    }
                                    if (mouse.button === Qt.MiddleButton)
                                        createNewTab(drvRow.modelData.path)
                                    else
                                        backend.cd(drvRow.modelData.path)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 4. RIGHT INSPECTOR DRAWER (Anchored to right!)
    // =========================================================
    IndFilePreview {
        id: inspectorDrawer
        anchors.top: tabBarStrip.bottom
        anchors.bottom: bottomStatusBar.top
        anchors.right: parent.right
        panelVisible: inspectorShown
        targetWidth: inspectorEffective
        previewData: backend ? backend.previewData : ({})
        onCloseRequested: showInspector = false
        onQuickLookRequested: function(data) { quickLookModal.openModal(data) }
        onActionRequested: function(action, path) {
            if (action === "open") backend.openFile(path)
            else if (action === "terminal") backend.openTerminal(path)
            else if (action === "copyPath") backend.copyPath(path)
            else if (action === "duplicate") backend.duplicateFile(path)
            else if (action === "trash") deleteSelection()
            else if (action === "extractHere") backend.extractArchive(path, false)
            else if (action === "compress") compressDialog.openDialog([path])
        }
        z: 5
    }

    // =========================================================
    // 5. DRAGGABLE SPLITTER HANDLE (Resize inspector freely!)
    // =========================================================
    Rectangle {
        id: splitterHandle
        anchors.top: tabBarStrip.bottom
        anchors.bottom: bottomStatusBar.top
        anchors.right: inspectorDrawer.left
        width: 8
        z: 20
        color: splitterMa.containsMouse || splitterMa.pressed ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.3) : "transparent"
        visible: inspectorShown

        Rectangle {
            anchors.centerIn: parent
            width: 2
            height: parent.height
            color: splitterMa.containsMouse || splitterMa.pressed ? accentColor : borderSoft
        }

        MouseArea {
            id: splitterMa
            anchors.fill: parent
            cursorShape: Qt.SplitHCursor
            hoverEnabled: true

            property real lastX: 0

            onPressed: function(mouse) {
                lastX = mouse.x
            }

            onPositionChanged: function(mouse) {
                if (pressed) {
                    var delta = mouse.x - lastX
                    inspectorWidth = Math.max(240, Math.min(inspectorCap, inspectorWidth - delta))
                }
            }
        }
    }

    // =========================================================
    // FILE PANE — one directory view. Two of these make the split.
    // Selection lives on the window rather than in here: only one pane can own a
    // selection at a time, and keeping it in one place means the toolbar, the
    // inspector and every shortcut go on reading exactly what they read before.
    // =========================================================
    component FilePane: Rectangle {
        id: pane
        property var be: null
        readonly property var model: pane.be ? pane.be.model : null
        readonly property int itemCount: pane.model ? pane.model.count : 0
        property int paneIndex: 0
        readonly property bool active: window.activePane === pane.paneIndex
        readonly property int selCount: pane.active ? window.selectedPaths.length : 0

        function isSel(p) { return pane.active && window.isSelected(p) }
        // Where a shift-click measures from. Set by every plain or toggling click,
        // the way it works everywhere else.
        property int selAnchor: -1
        // Whichever of the three is on screen, for anything that needs to scroll
        // the list rather than read it.
        function currentView() {
            var vm = pane.be ? pane.be.viewMode : "grid"
            if (vm === "list") return listView
            if (vm === "compact") return compactView
            return gridView
        }
        function pick(p) { window.focusPane(pane.paneIndex); window.selectSingle(p) }
        function pickToggle(p) { window.focusPane(pane.paneIndex); window.toggleSelect(p) }
        function pickAt(p, i) { pane.selAnchor = i; pane.pick(p) }
        function pickToggleAt(p, i) { pane.selAnchor = i; pane.pickToggle(p) }
        function pickRangeTo(p, i) {
            if (!pane.be) return
            var from = pane.selAnchor
            if (from < 0) from = pane.be.rowOf(window.selectedPath)
            if (from < 0) { pane.pickAt(p, i); return }
            window.focusPane(pane.paneIndex)
            window.selectedPaths = pane.be.pathRange(from, i)
            window.selectedPath = p
            if (pane.be) pane.be.selectFile(p)
        }
        // One place decides what a click on a row means, so the grid and the list
        // cannot drift apart -- which is how ctrl-click came to be handled twice.
        function clickRow(mouse, p, i) {
            if (mouse.modifiers & Qt.ShiftModifier) { pane.pickRangeTo(p, i); return false }
            if (mouse.modifiers & Qt.ControlModifier) { pane.pickToggleAt(p, i); return false }
            pane.pickAt(p, i)
            return true      // a plain click, which may also mean "open"
        }
        function refresh() { if (pane.be) pane.be.refresh() }

        focus: pane.active
        Keys.onPressed: (event) => {
            if (isModalOpen() || manualPathEdit) return;
            if (event.key === Qt.Key_Delete) {
                if (event.modifiers & Qt.ShiftModifier) deletePermanentlyAsk();
                else deleteSelection();
                event.accepted = true;
            }
        }

        // Clicking anywhere in a pane makes it the one the chrome talks about.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            propagateComposedEvents: true
            z: -2
            onPressed: function(mouse) { window.focusPane(pane.paneIndex); mouse.accepted = false }
        }

        // Which pane the toolbar is talking about has to be unmistakable, because
        // every command in the window silently acts on it. A dim alone read as a
        // rendering artefact, so the active pane is also underlined in the accent.
        Rectangle {
            anchors.fill: parent
            visible: window.splitView && !pane.active
            color: isDark ? Qt.rgba(0, 0, 0, 0.22) : Qt.rgba(0, 0, 0, 0.07)
            z: 60
        }

        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 2
            visible: window.splitView && pane.active
            color: accentInk
            z: 61
        }

        color: bgDark
        clip: true

        // Background Empty Space Click Handler
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton | Qt.LeftButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) {
                    window.selectedPaths = []
                    window.selectedPath = ""
                    var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                    customMenu.openMenu(pt.x, pt.y, false)
                } else {
                    customMenu.visible = false
                    window.selectedPaths = []
                    window.selectedPath = ""
                    if (pane.be) pane.be.selectFile("")
                }
            }
        }

        // Restore and Empty live here rather than only in the context menu: the
        // trash is the one folder where what you can do to a file is not the same
        // as everywhere else, and that should be visible on arrival.
        Rectangle {
            id: trashBanner
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: visible ? 42 : 0
            visible: !!(pane.be && pane.be.inTrash)
            color: Qt.rgba(dangerInk.r, dangerInk.g, dangerInk.b, isDark ? 0.13 : 0.09)

            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: borderSoft
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 10

                Text {
                    text: "delete"
                    font.family: iconFont
                    font.variableAxes: iconFilled
                    font.pixelSize: 18
                    color: dangerInk
                }
                Text {
                    text: pane.selCount > 0
                          ? (pane.selCount + " selected")
                          : "Items here are waiting to be deleted"
                    font.pixelSize: 12
                    color: textSecondary
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                Rectangle {
                    width: 104; height: 28; radius: rBase
                    opacity: pane.selCount > 0 || window.selectedPath.length > 0 ? 1.0 : 0.4
                    color: restoreMa.containsMouse && opacity > 0.5 ? bgHover : bgDark
                    border.width: 1; border.color: borderSoft
                    RowLayout {
                        anchors.centerIn: parent; spacing: 5
                        Text { text: "restore_from_trash"; font.family: iconFont; font.pixelSize: 15; color: textPrimary }
                        Text { text: "Restore"; font.pixelSize: 11; color: textPrimary }
                    }
                    MouseArea {
                        id: restoreMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: pane.selCount > 0 || window.selectedPath.length > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: restoreSelection()
                    }
                }

                Rectangle {
                    width: 118; height: 28; radius: rBase
                    opacity: pane.itemCount > 0 ? 1.0 : 0.4
                    color: emptyMa.containsMouse && pane.itemCount > 0
                           ? Qt.rgba(dangerInk.r, dangerInk.g, dangerInk.b, 0.22) : bgDark
                    border.width: 1
                    border.color: emptyMa.containsMouse && pane.itemCount > 0 ? dangerInk : borderSoft
                    RowLayout {
                        anchors.centerIn: parent; spacing: 5
                        Text { text: "delete_forever"; font.family: iconFont; font.pixelSize: 15; color: dangerInk }
                        Text { text: "Empty Trash"; font.pixelSize: 11; color: dangerInk }
                    }
                    MouseArea {
                        id: emptyMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: pane.itemCount > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var all = []
                            all = pane.model ? pane.model.paths() : []
                            if (all.length > 0) confirmPurge.openDialog(all)
                        }
                    }
                }
            }
        }

        // Empty Directory Placeholder
        ColumnLayout {
            anchors.centerIn: parent
            visible: pane.itemCount === 0
            spacing: 10

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "folder_open"
                font.family: iconFont
                font.pixelSize: 64
                color: textMuted
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "This folder is empty"
                font.pixelSize: 15
                font.bold: true
                color: textSecondary
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Right-click or press Ctrl+Shift+N to create a folder"
                font.pixelSize: 12
                color: textMuted
            }
        }

        // GRID VIEW MODE
        GridView {
            id: gridView
            anchors { top: trashBanner.bottom; left: parent.left
                      right: parent.right; bottom: parent.bottom; margins: 16 }
            visible: pane.be && pane.be.viewMode === "grid" && pane.itemCount > 0
            // Columns are whole numbers, then the remainder is shared back out so the
            // grid never leaves a ragged gutter down the right-hand side.
            readonly property int cols: Math.max(1, Math.floor(width / gridIcon))
            // Capped so a lone column does not stretch one card across the pane.
            cellWidth: Math.min(Math.floor(width / cols), Math.round(gridIcon * 1.5))
            cellHeight: gridCellH
            model: pane.model
            clip: true
            ScrollBar.vertical: ScrollBar { active: true }

            WheelHandler {
                acceptedModifiers: Qt.ControlModifier
                onWheel: function(ev) { zoomGrid(ev.angleDelta.y > 0 ? 12 : -12) }
            }

            MouseArea {
                parent: gridView.contentItem
                z: -1
                width: Math.max(gridView.width, gridView.contentWidth)
                height: Math.max(gridView.height, gridView.contentHeight)
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: function(mouse) {
                    customMenu.visible = false
                    window.selectedPaths = []
                    window.selectedPath = ""
                    if (pane.be) pane.be.selectFile("")
                    if (mouse.button === Qt.RightButton) {
                        var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                        customMenu.openMenu(pt.x, pt.y, false)
                    }
                }
            }

            delegate: Rectangle {
                id: itemCard
                required property var modelData
                required property int index      // shift-click measures in rows
                width: gridView.cellWidth - 6
                height: gridView.cellHeight - 6
                radius: rCard
                readonly property int slot: gridSlot
                readonly property bool itemSelected: pane.isSel(modelData.path)
                color: folderDropArea.containsDrag ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.3)
                     : (itemSelected ? bgCardSelected : (itemMa.containsMouse ? bgCard : "transparent"))
                border.width: (folderDropArea.containsDrag || itemSelected) ? 1.5 : (itemMa.containsMouse ? 1 : 0)
                border.color: (folderDropArea.containsDrag || itemSelected) ? accentColor : borderSoft

                Rectangle {
                    visible: !!itemCard.modelData.tag
                    width: 11; height: 11; radius: rBase
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 7
                    z: 5
                    color: tagColor(itemCard.modelData.tag)
                    border.width: 1.5
                    border.color: Qt.rgba(0, 0, 0, isDark ? 0.35 : 0.15)
                }

                Timer {
                    id: folderHoverNavTimer
                    interval: 700
                    repeat: false
                    onTriggered: {
                        if (modelData.isDir && pane.be) pane.be.cd(modelData.path)
                    }
                }

                DropArea {
                    id: folderDropArea
                    anchors.fill: parent
                    enabled: modelData.isDir
                    onEntered: (drag) => {
                        folderHoverNavTimer.start()
                    }
                    onExited: {
                        folderHoverNavTimer.stop()
                    }
                    onDropped: function(drop) {
                        folderHoverNavTimer.stop()
                        var paths = []
                        if (drop.hasUrls) {
                            for (var i = 0; i < drop.urls.length; i++) {
                                paths.push(pane.be.urlToPath("" + drop.urls[i]))
                            }
                        }
                        if (paths.length > 0 && pane.be) {
                            pane.be.moveFiles(paths, modelData.path)
                            drop.acceptProposedAction()
                        }
                    }
                }

                Column {
                    anchors.centerIn: parent
                    width: itemCard.width - 12
                    spacing: gridGap

                    // Icon or thumbnail. A bare glyph floats on the card; only a real
                    // thumbnail gets a frame, so the two never compete for the same space.
                    Item {
                        id: iconSlot
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: itemCard.slot
                        height: itemCard.slot
                        readonly property string thumbSrc: thumbFor(modelData)
                        readonly property bool hasThumb: iconSlot.thumbSrc !== "" && thumbImg.status === Image.Ready

                        // The icon theme's picture for this kind of file, which
                        // knows the difference between a Python file and a log
                        // where one glyph per category could not. Falls back to
                        // the glyph below when the theme has nothing.
                        Image {
                            id: themeIcon
                            anchors.centerIn: parent
                            visible: !iconSlot.hasThumb && modelData.themeIcon
                                     && status === Image.Ready
                            // iconGeneration rides along so a theme change makes a
                            // URL QML has not cached; see the property's note.
                            source: modelData.themeIcon
                                    ? "image://fileicon/" + modelData.themeIcon
                                      + "?g=" + iconGen : ""
                            sourceSize.width: Math.round(itemCard.slot * 0.86)
                            sourceSize.height: Math.round(itemCard.slot * 0.86)
                            width: Math.round(itemCard.slot * 0.86)
                            height: Math.round(itemCard.slot * 0.86)
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            asynchronous: true
                            cache: true
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !iconSlot.hasThumb && !themeIcon.visible
                            text: modelData.iconName || "draft"
                            font.family: iconFont
                            font.pixelSize: Math.round(itemCard.slot * (modelData.isDir ? 0.78 : 0.71))
                            font.variableAxes: iconFilled
                            // The window rasterises text natively, which is right
                            // for small UI glyphs but leaves a visible SEAM across
                            // a large filled icon where two contours meet — the
                            // folder tab against the folder body, most obviously.
                            // Distance-field rendering has no such seam and is
                            // what large glyphs want; it is chosen here rather
                            // than globally so ordinary text keeps the native
                            // rasteriser.
                            renderType: Text.QtRendering
                            color: modelData.isDir
                                   ? accentInk
                                   : (modelData.accentColor || textSecondary)
                            opacity: itemSelected ? 1.0 : 0.94
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: itemCard.slot - 2
                            height: itemCard.slot - 2
                            radius: Math.max(5, Math.round(itemCard.slot * 0.13))
                            visible: iconSlot.hasThumb
                            color: onAccent
                            border.width: 1
                            border.color: itemSelected ? accentColor : borderSoft
                            clip: true

                            Image {
                                id: thumbImg
                                anchors.fill: parent
                                anchors.margins: 1
                                source: iconSlot.thumbSrc ? "file://" + iconSlot.thumbSrc : ""
                                // Decode straight to cell size — a 24MP photo must never
                                // be unpacked at full resolution to fill 60 logical pixels.
                                sourceSize.width: Math.max(128, itemCard.slot * 2)
                                sourceSize.height: Math.max(128, itemCard.slot * 2)
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                asynchronous: true
                                cache: true
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.right: parent.right
                                anchors.margins: 3
                                height: 14
                                width: badgeText.implicitWidth + 8
                                radius: rBase
                                color: isDark ? Qt.rgba(0, 0, 0, 0.78) : Qt.rgba(255, 255, 255, 0.9)
                                visible: modelData.category !== "image"

                                Text {
                                    id: badgeText
                                    anchors.centerIn: parent
                                    text: modelData.extBadge || ""
                                    font.pixelSize: 8
                                    font.bold: true
                                    color: modelData.accentColor || (isDark ? "#ffffff" : "#000000")
                                }
                            }
                        }
                    }

                    // File Name Label
                    Text {
                        width: itemCard.width - 12
                        text: modelData.name
                        color: itemSelected ? accentInk : textPrimary
                        font.pixelSize: gridLabelPx
                        font.bold: modelData.isDir || itemSelected
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 2
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                        clip: true
                    }
                }

                MouseArea {
                    id: itemMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    property point startPos: Qt.point(0, 0)
                    onPressed: function(mouse) {
                        if (mouse.button === Qt.MiddleButton) {
                            if (modelData.isDir) {
                                createNewTab(modelData.path)
                            }
                            return
                        }
                        if (mouse.button === Qt.LeftButton) {
                            startPos = Qt.point(mouse.x, mouse.y)
                            // A PLAIN PRESS ONLY. Pressing used to toggle for
                            // ctrl and then onClicked toggled the same row back,
                            // so ctrl-clicking an unselected file selected and
                            // deselected it in one gesture and looked dead. The
                            // press still selects for a plain click, because that
                            // is what makes dragging an unselected file work.
                            if (!pane.isSel(modelData.path)
                                    && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) {
                                pane.pickAt(modelData.path, index)
                            }
                        }
                    }
                    property bool dragArmed: false
                    onPositionChanged: function(mouse) {
                        if (!(mouse.buttons & Qt.LeftButton) || dragArmed) return
                        var dx = mouse.x - startPos.x
                        var dy = mouse.y - startPos.y
                        if ((dx*dx + dy*dy) > 36) {
                            // ONCE per press. onPositionChanged fires for every
                            // mouse move, and each call used to start a nested,
                            // blocking QDrag.exec() — inside which further moves
                            // arrived and nested again, without bound, until the
                            // process died. That was the drag crash.
                            dragArmed = true
                            var paths = pane.selCount > 0 ? window.selectedPaths : [modelData.path]
                            if (pane.be) pane.be.startNativeDrag(paths)
                        }
                    }
                    onReleased: dragArmed = false
                    onCanceled: dragArmed = false
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton) {
                            var plain = pane.clickRow(mouse, modelData.path, index)
                            // Single-click-to-open is a preference, off by
                            // default; a modified click is never an open.
                            if (plain && window.singleClickOpens && pane.be) {
                                pane.be.openFile(modelData.path)
                            }
                            customMenu.visible = false
                        } else if (mouse.button === Qt.RightButton) {
                            if (!pane.isSel(modelData.path)) {
                                pane.pick(modelData.path)
                            }
                            var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                            customMenu.openMenu(pt.x, pt.y, true)
                        }
                    }
                    onDoubleClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton && pane.be) {
                            pane.be.openFile(modelData.path)
                        }
                    }
                }
            }
        }

        // LIST VIEW MODE
        // COMPACT: names in narrow columns that flow down and then across, which
        // is Dolphin's third mode. It fits several times more of a large folder
        // on screen than the grid, and reads faster than the detail list when all
        // you are doing is looking for a name.
        GridView {
            id: compactView
            anchors { top: trashBanner.bottom; left: parent.left
                      right: parent.right; bottom: parent.bottom; margins: 10 }
            visible: pane.be && pane.be.viewMode === "compact" && pane.itemCount > 0
            model: pane.model
            clip: true
            flow: GridView.FlowTopToBottom
            cellWidth: Math.max(170, Math.min(280, compactView.width / 4))
            cellHeight: 24
            ScrollBar.horizontal: ScrollBar { active: true }

            delegate: Rectangle {
                required property var modelData
                required property int index
                width: compactView.cellWidth - 4
                height: compactView.cellHeight - 2
                radius: rBase
                readonly property bool sel: pane.isSel(modelData.path)
                color: sel ? accentWash : (cpMa.containsMouse ? bgHover : "transparent")
                border.width: 1
                border.color: sel ? accentColor : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 7

                    Image {
                        id: cpThemeIcon
                        visible: modelData.themeIcon && status === Image.Ready
                        source: modelData.themeIcon
                                ? "image://fileicon/" + modelData.themeIcon
                                  + "?g=" + iconGen : ""
                        sourceSize.width: 16; sourceSize.height: 16
                        width: 16; height: 16
                        fillMode: Image.PreserveAspectFit
                        smooth: true; asynchronous: true; cache: true
                    }
                    Text {
                        visible: !cpThemeIcon.visible
                        text: modelData.iconName
                        font.family: iconFont
                        font.pixelSize: 15
                        font.variableAxes: iconFilled
                        color: modelData.isDir ? accentColor
                               : catInk(modelData.category, textSecondary)
                    }
                    Text {
                        text: modelData.name
                        font.pixelSize: tDense
                        color: textPrimary
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        visible: modelData.tag !== ""
                        width: 6; height: 6; radius: rCard
                        color: tagColor(modelData.tag)
                    }
                }

                MouseArea {
                    id: cpMa
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(mouse) {
                        window.focusPane(pane.paneIndex)
                        if (mouse.button === Qt.RightButton) {
                            if (!pane.isSel(modelData.path)) pane.pick(modelData.path)
                            var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                            customMenu.openMenu(pt.x, pt.y, true)
                        } else {
                            var plainCp = pane.clickRow(mouse, modelData.path, index)
                            if (plainCp && window.singleClickOpens && pane.be)
                                pane.be.openFile(modelData.path)
                        }
                    }
                    onDoubleClicked: if (pane.be) pane.be.openFile(modelData.path)
                }
            }
        }

        ListView {
            id: listView
            anchors { top: trashBanner.bottom; left: parent.left
                      right: parent.right; bottom: parent.bottom; margins: 10 }
            visible: pane.be && pane.be.viewMode === "list" && pane.itemCount > 0
            model: pane.model
            spacing: 3
            clip: true
            ScrollBar.vertical: ScrollBar { active: true }

            MouseArea {
                parent: listView.contentItem
                z: -1
                width: Math.max(listView.width, listView.contentWidth)
                height: Math.max(listView.height, listView.contentHeight)
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: function(mouse) {
                    customMenu.visible = false
                    window.selectedPaths = []
                    window.selectedPath = ""
                    if (pane.be) pane.be.selectFile("")
                    if (mouse.button === Qt.RightButton) {
                        var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                        customMenu.openMenu(pt.x, pt.y, false)
                    }
                }
            }

            header: Rectangle {
                width: parent ? parent.width : 600
                height: 32
                color: bgDark
                border.width: 1
                border.color: borderSoft
                z: 2

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 12

                    Text { text: "Name"; font.bold: true; color: textSecondary; font.pixelSize: 11; Layout.fillWidth: true }
                    Text { text: "Size"; font.bold: true; color: textSecondary; font.pixelSize: 11; Layout.preferredWidth: 90 }
                    Text { text: "Type"; font.bold: true; color: textSecondary; font.pixelSize: 11; Layout.preferredWidth: 110 }
                    Text { text: "Modified"; font.bold: true; color: textSecondary; font.pixelSize: 11; Layout.preferredWidth: 130 }
                }
            }

            delegate: Rectangle {
                id: listRowCard
                required property var modelData
                required property int index
                width: listView.width - 24
                height: 36
                radius: rBase
                readonly property bool itemSelected: pane.isSel(modelData.path)
                color: listDropArea.containsDrag ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.3)
                     : (itemSelected ? bgCardSelected : (listMa.containsMouse ? bgCard : "transparent"))
                border.width: (listDropArea.containsDrag || itemSelected) ? 1.5 : (listMa.containsMouse ? 1 : 0)
                border.color: (listDropArea.containsDrag || itemSelected) ? accentColor : borderSoft

                Rectangle {
                    visible: !!listRowCard.modelData.tag
                    width: 9; height: 9; radius: rBase
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    z: 5
                    color: tagColor(listRowCard.modelData.tag)
                    border.width: 1.5
                    border.color: Qt.rgba(0, 0, 0, isDark ? 0.35 : 0.15)
                }

                Timer {
                    id: listFolderHoverNavTimer
                    interval: 700
                    repeat: false
                    onTriggered: {
                        if (modelData.isDir && pane.be) pane.be.cd(modelData.path)
                    }
                }

                DropArea {
                    id: listDropArea
                    anchors.fill: parent
                    enabled: modelData.isDir
                    onEntered: (drag) => {
                        listFolderHoverNavTimer.start()
                    }
                    onExited: {
                        listFolderHoverNavTimer.stop()
                    }
                    onDropped: function(drop) {
                        listFolderHoverNavTimer.stop()
                        var paths = []
                        if (drop.hasUrls) {
                            for (var i = 0; i < drop.urls.length; i++) {
                                paths.push(pane.be.urlToPath("" + drop.urls[i]))
                            }
                        }
                        if (paths.length > 0 && pane.be) {
                            pane.be.moveFiles(paths, modelData.path)
                            drop.acceptProposedAction()
                        }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 12

                    Item {
                        id: rowIcon
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        readonly property string thumbSrc: thumbFor(modelData)
                        readonly property bool hasThumb: rowIcon.thumbSrc !== "" && rowThumb.status === Image.Ready

                        Image {
                            id: rowThemeIcon
                            anchors.centerIn: parent
                            visible: !rowIcon.hasThumb && modelData.themeIcon
                                     && status === Image.Ready
                            source: modelData.themeIcon
                                    ? "image://fileicon/" + modelData.themeIcon
                                      + "?g=" + iconGen : ""
                            sourceSize.width: 24; sourceSize.height: 24
                            width: 24; height: 24
                            fillMode: Image.PreserveAspectFit
                            smooth: true; asynchronous: true; cache: true
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !rowIcon.hasThumb && !rowThemeIcon.visible
                            text: modelData.iconName || "draft"
                            font.family: iconFont
                            font.pixelSize: 20
                            font.variableAxes: iconFilled
                            color: modelData.isDir ? accentInk : (modelData.accentColor || textSecondary)
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: rBase
                            visible: rowIcon.hasThumb
                            color: onAccent
                            clip: true

                            Image {
                                id: rowThumb
                                anchors.fill: parent
                                source: rowIcon.thumbSrc ? "file://" + rowIcon.thumbSrc : ""
                                sourceSize.width: 64
                                sourceSize.height: 64
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                asynchronous: true
                                cache: true
                            }
                        }
                    }

                    Text {
                        text: modelData.name
                        color: itemSelected ? accentInk : textPrimary
                        font.pixelSize: 12
                        font.bold: modelData.isDir
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    Text {
                        text: modelData.sizeStr
                        color: textSecondary
                        font.family: monoFont
                        font.pixelSize: tData
                        font.features: ({ "tnum": 1 })
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: 90
                    }

                    Text {
                        text: modelData.mimeType
                        color: textMuted
                        font.pixelSize: 11
                        Layout.preferredWidth: 110
                        elide: Text.ElideRight
                    }

                    Text {
                        text: modelData.mtimeStr
                        color: textSecondary
                        font.family: monoFont
                        font.pixelSize: tData
                        font.features: ({ "tnum": 1 })
                        Layout.preferredWidth: 130
                    }
                }

                MouseArea {
                    id: listMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    property point startPos: Qt.point(0, 0)
                    onPressed: function(mouse) {
                        if (mouse.button === Qt.MiddleButton) {
                            if (modelData.isDir) {
                                createNewTab(modelData.path)
                            }
                            return
                        }
                        if (mouse.button === Qt.LeftButton) {
                            startPos = Qt.point(mouse.x, mouse.y)
                            // A PLAIN PRESS ONLY. Pressing used to toggle for
                            // ctrl and then onClicked toggled the same row back,
                            // so ctrl-clicking an unselected file selected and
                            // deselected it in one gesture and looked dead. The
                            // press still selects for a plain click, because that
                            // is what makes dragging an unselected file work.
                            if (!pane.isSel(modelData.path)
                                    && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) {
                                pane.pickAt(modelData.path, index)
                            }
                        }
                    }
                    property bool dragArmed: false
                    onPositionChanged: function(mouse) {
                        if (!(mouse.buttons & Qt.LeftButton) || dragArmed) return
                        var dx = mouse.x - startPos.x
                        var dy = mouse.y - startPos.y
                        if ((dx*dx + dy*dy) > 36) {
                            // ONCE per press. onPositionChanged fires for every
                            // mouse move, and each call used to start a nested,
                            // blocking QDrag.exec() — inside which further moves
                            // arrived and nested again, without bound, until the
                            // process died. That was the drag crash.
                            dragArmed = true
                            var paths = pane.selCount > 0 ? window.selectedPaths : [modelData.path]
                            if (pane.be) pane.be.startNativeDrag(paths)
                        }
                    }
                    onReleased: dragArmed = false
                    onCanceled: dragArmed = false
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton) {
                            var plain = pane.clickRow(mouse, modelData.path, index)
                            // Single-click-to-open is a preference, off by
                            // default; a modified click is never an open.
                            if (plain && window.singleClickOpens && pane.be) {
                                pane.be.openFile(modelData.path)
                            }
                            customMenu.visible = false
                        } else if (mouse.button === Qt.RightButton) {
                            if (!pane.isSel(modelData.path)) {
                                pane.pick(modelData.path)
                            }
                            var pt = mapToItem(window.contentItem, mouse.x, mouse.y)
                            customMenu.openMenu(pt.x, pt.y, true)
                        }
                    }
                    onDoubleClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton && pane.be) {
                            pane.be.openFile(modelData.path)
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 6. MAIN CONTENT AREA — one pane, or two when the split is open
    // =========================================================
    Item {
        id: contentHost
        anchors.top: tabBarStrip.bottom
        anchors.bottom: bottomStatusBar.top
        anchors.left: leftSidebar.right
        anchors.right: inspectorShown ? splitterHandle.left : parent.right

        FilePane {
            id: paneA
            paneIndex: 0
            be: be1
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: window.splitView ? Math.round(contentHost.width * window.splitRatio) - 3 : contentHost.width
            color: bgDark
            clip: true
        }

        // Drag to give one side more room.
        Rectangle {
            id: paneSplitter
            visible: window.splitView
            anchors { top: parent.top; bottom: parent.bottom }
            x: paneA.width
            width: 6
            color: paneSplitMa.containsMouse || paneSplitMa.pressed
                   ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.3) : "transparent"
            z: 70

            Rectangle {
                anchors.centerIn: parent
                width: 1; height: parent.height
                color: paneSplitMa.containsMouse || paneSplitMa.pressed ? accentColor : borderSoft
            }

            MouseArea {
                id: paneSplitMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SplitHCursor
                property real grabX: 0
                onPressed: function(mouse) { paneSplitMa.grabX = mouse.x }
                onPositionChanged: function(mouse) {
                    if (!paneSplitMa.pressed || contentHost.width <= 0) return
                    var delta = mouse.x - paneSplitMa.grabX
                    window.splitRatio = Math.max(0.2, Math.min(0.8,
                        (paneA.width + delta) / contentHost.width))
                }
            }
        }

        FilePane {
            id: paneB
            paneIndex: 1
            be: be2
            visible: window.splitView
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            width: window.splitView ? contentHost.width - paneA.width - 6 : 0
            color: bgDark
            clip: true
        }
    }


    // =========================================================
    // 7. MAC-STYLE "QUICK LOOK" THEATER MODAL (Spacebar)
    // =========================================================
    Rectangle {
        id: quickLookModal
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.85)
        visible: false
        z: 200

        property var qlData: ({})
        // A Word document carries both an extracted text body and rendered pages, so
        // the two theatres matched at once and drew over each other. Rendered pages
        // are the better answer whenever they exist, so they win and text stands down.
        readonly property bool qlHasPages: !!(quickLookModal.qlData
                                              && quickLookModal.qlData.pdfPages
                                              && quickLookModal.qlData.pdfPages.length > 0)
        readonly property var qlPlayer: qlMediaLoader.item ? qlMediaLoader.item.player : null
        property bool isPlaying: qlPlayer ? (qlPlayer.playbackState === MediaPlayer.PlayingState) : false
        property bool isMuted: false

        function openModal(data) {
            qlData = data
            visible = true
            if (data && (data.category === "video" || data.category === "audio") && data.path) {
                Qt.callLater(function() {
                    if (qlPlayer) {
                        qlPlayer.source = "file://" + data.path
                        qlPlayer.play()
                    }
                })
            }
        }

        function closeModal() {
            if (qlPlayer) {
                qlPlayer.stop()
                qlPlayer.source = ""
            }
            visible = false
        }

        function formatTime(ms) {
            if (!ms || isNaN(ms)) return "00:00"
            var totalSecs = Math.floor(ms / 1000)
            var mins = Math.floor(totalSecs / 60)
            var secs = totalSecs % 60
            return (mins < 10 ? "0" + mins : mins) + ":" + (secs < 10 ? "0" + secs : secs)
        }

        MouseArea {
            anchors.fill: parent
            onClicked: quickLookModal.closeModal()
        }

        // Quick Look Floating Window Card
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(window.width * 0.88, 1060)
            height: Math.min(window.height * 0.88, 740)
            radius: rCard
            color: bgPanel
            border.width: 1
            border.color: isDark ? "#323246" : borderHard
            clip: true

            MouseArea {
                anchors.fill: parent
                onClicked: {} // Trap clicks inside card
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text {
                            anchors.centerIn: parent
                            text: (quickLookModal.qlData && quickLookModal.qlData.iconName) ? quickLookModal.qlData.iconName : "visibility"
                            font.family: iconFont
                            color: accentColor
                            font.pixelSize: 20
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Text {
                            text: (quickLookModal.qlData && quickLookModal.qlData.name) ? quickLookModal.qlData.name : "Quick Look"
                            font.pixelSize: 15
                            font.bold: true
                            color: textPrimary
                            elide: Text.ElideMiddle
                            Layout.maximumWidth: 650
                        }
                        Text {
                            text: (quickLookModal.qlData && quickLookModal.qlData.sizeStr) ? quickLookModal.qlData.sizeStr + " • " + (quickLookModal.qlData.mime || "") : ""
                            font.pixelSize: 11
                            color: textSecondary
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Open (Default App)
                    Rectangle {
                        height: 32
                        width: 86
                        radius: rBase
                        color: qlOpenMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 6
                            Text { text: "open_in_new"; font.family: iconFont; color: onAccent; font.pixelSize: 16 }
                            Text { text: "Open"; font.bold: true; font.pixelSize: 12; color: onAccent }
                        }
                        MouseArea {
                            id: qlOpenMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (quickLookModal.qlData && quickLookModal.qlData.path && backend) {
                                    backend.openFile(quickLookModal.qlData.path)
                                    quickLookModal.closeModal()
                                }
                            }
                        }
                    }

                    // Open With...
                    Rectangle {
                        height: 32
                        width: 106
                        radius: rBase
                        color: qlOpenWithMa.containsMouse ? bgHover : (isDark ? "#202030" : bgCard)
                        border.width: 1; border.color: borderSoft
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 5
                            Text { text: "apps"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                            Text { text: "Open With"; font.pixelSize: 12; color: textPrimary }
                        }
                        MouseArea {
                            id: qlOpenWithMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (quickLookModal.qlData && quickLookModal.qlData.path) {
                                    var p = quickLookModal.qlData.path
                                    quickLookModal.closeModal()
                                    openWithModal.openDialog(p)
                                }
                            }
                        }
                    }

                    // Close Quick Look
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: qlCloseBtnMa.containsMouse ? bgHover : "transparent"
                        Text { anchors.centerIn: parent; text: "close"; font.family: iconFont; color: textSecondary; font.pixelSize: 20 }
                        MouseArea {
                            id: qlCloseBtnMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: quickLookModal.closeModal()
                        }
                    }
                }

                // Main Stage Canvas
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: rCard
                    color: isDark ? "#0a0a0f" : bgSunken
                    border.width: 1
                    border.color: borderSoft
                    clip: true

                    // A. VIDEO & AUDIO THEATER (LAZY LOADED)
                    Loader {
                        id: qlMediaLoader
                        anchors.fill: parent
                        anchors.margins: 8
                        active: quickLookModal.visible && (quickLookModal.qlData && (quickLookModal.qlData.category === "video" || quickLookModal.qlData.category === "audio"))
                        sourceComponent: Item {
                            anchors.fill: parent
                            property alias player: internalQlPlayer

                            MediaPlayer {
                                id: internalQlPlayer
                                source: (quickLookModal.qlData && quickLookModal.qlData.path) ? ("file://" + quickLookModal.qlData.path) : ""
                                audioOutput: AudioOutput { volume: quickLookModal.isMuted ? 0.0 : 0.9 }
                                videoOutput: internalQlVideoOut
                            }

                            VideoOutput {
                                id: internalQlVideoOut
                                anchors.fill: parent
                                visible: quickLookModal.qlData && quickLookModal.qlData.category === "video"
                                fillMode: VideoOutput.PreserveAspectFit
                            }
                        }
                    }

                    // B. MULTI-PAGE PDF CONTINUOUS READER
                    ScrollView {
                        anchors.fill: parent
                        anchors.margins: 12
                        visible: quickLookModal.qlHasPages
                        clip: true

                        ListView {
                            id: qlPdfList
                            width: parent.width - 24
                            model: quickLookModal.qlData ? quickLookModal.qlData.pdfPages : []
                            spacing: 16

                            delegate: Rectangle {
                                required property string modelData
                                required property int index
                                width: qlPdfList.width
                                height: qlPdfImg.paintedHeight > 0 ? (qlPdfImg.paintedHeight + 16) : (qlPdfList.width * 1.414)
                                radius: rBase
                                color: "#f2f2f5"
                                border.width: 1
                                border.color: borderHard

                                Image {
                                    id: qlPdfImg
                                    anchors.centerIn: parent
                                    width: parent.width - 8
                                    source: "file://" + modelData
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    mipmap: true
                                    asynchronous: true
                                }

                                Rectangle {
                                    anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: 8
                                    height: 20; width: qlBadgeT.implicitWidth + 10; radius: rBase
                                    color: Qt.rgba(0, 0, 0, 0.75)
                                    Text { id: qlBadgeT; anchors.centerIn: parent; text: "Page " + (index + 1); font.pixelSize: 10; font.bold: true; color: "#f2f2f5" }
                                }
                            }
                        }
                    }

                    // C. HIGH-RES IMAGE THEATER
                    Image {
                        anchors.centerIn: parent
                        width: parent.width - 20
                        height: parent.height - 20
                        // See IndFilePreview: a thumbnail with no pages is worth
                        // showing whatever kind of file it came from.
                        visible: !!(quickLookModal.qlData && !quickLookModal.qlHasPages
                                 && quickLookModal.qlData.category !== "video"
                                 && quickLookModal.qlData.category !== "audio"
                                 && quickLookModal.qlData.thumbnailPath)
                        source: (quickLookModal.qlData && quickLookModal.qlData.thumbnailPath) ? "file://" + quickLookModal.qlData.thumbnailPath : ""
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        mipmap: true
                        asynchronous: true
                    }

                    // C2. WAITING ON A RENDER
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 10
                        visible: !!(quickLookModal.qlData && quickLookModal.qlData.renderPending
                                    && !quickLookModal.qlHasPages)
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "hourglass_top"
                            font.family: iconFont; font.pixelSize: 40
                            color: accentInk
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Rendering pages\u2026"
                            font.pixelSize: tDense; color: textSecondary
                        }
                    }

                    // D. CODE & TEXT THEATER
                    ScrollView {
                        anchors.fill: parent
                        anchors.margins: 16
                        // Stands down for the image theater above as well as for
                        // the page reader — two theaters drawing at once is how the
                        // pages-versus-text overlap started.
                        visible: !!(quickLookModal.qlData && !quickLookModal.qlHasPages
                                 && !quickLookModal.qlData.thumbnailPath
                                 && !quickLookModal.qlData.renderPending
                                 && (quickLookModal.qlData.category === "code" || quickLookModal.qlData.category === "document")
                                 && quickLookModal.qlData.text)
                        clip: true

                        Text {
                            text: (quickLookModal.qlData && quickLookModal.qlData.text) ? quickLookModal.qlData.text : ""
                            font.pixelSize: 12
                            font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                            color: isDark ? bgCard : "#1e293b"
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // Video / Audio Playback Controller Bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 50
                    radius: rBase
                    color: isDark ? "#0c0c12" : bgSunken
                    border.width: 1
                    border.color: borderSoft
                    visible: quickLookModal.qlData && (quickLookModal.qlData.category === "video" || quickLookModal.qlData.category === "audio")

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        // Play/Pause
                        Rectangle {
                            width: 32; height: 32; radius: rBase
                            color: qlPlayMa.containsMouse ? bgHover : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: quickLookModal.isPlaying ? "pause" : "play_arrow"
                                font.family: iconFont
                                font.pixelSize: 22
                                color: accentColor
                            }
                            MouseArea {
                                id: qlPlayMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (quickLookModal.qlPlayer) {
                                        if (quickLookModal.isPlaying) quickLookModal.qlPlayer.pause()
                                        else quickLookModal.qlPlayer.play()
                                    }
                                }
                            }
                        }

                        // Slider
                        Slider {
                            id: qlSlider
                            Layout.fillWidth: true
                            from: 0
                            to: (quickLookModal.qlPlayer && quickLookModal.qlPlayer.duration > 0) ? quickLookModal.qlPlayer.duration : 1
                            value: quickLookModal.qlPlayer ? quickLookModal.qlPlayer.position : 0
                            onMoved: if (quickLookModal.qlPlayer) quickLookModal.qlPlayer.position = value

                            background: Rectangle {
                                x: qlSlider.leftPadding; y: qlSlider.topPadding + qlSlider.availableHeight / 2 - 2
                                width: qlSlider.availableWidth; height: 5; radius: rSmall
                                color: isDark ? "#282838" : borderHard
                                Rectangle { width: qlSlider.visualPosition * parent.width; height: parent.height; color: accentColor; radius: rSmall }
                            }

                            handle: Rectangle {
                                x: qlSlider.leftPadding + qlSlider.visualPosition * (qlSlider.availableWidth - width)
                                y: qlSlider.topPadding + qlSlider.availableHeight / 2 - height / 2
                                width: 14; height: 14; radius: rBase; color: accentColor
                            }
                        }

                        // Time
                        Text {
                            text: quickLookModal.formatTime(quickLookModal.qlPlayer ? quickLookModal.qlPlayer.position : 0) + " / " + quickLookModal.formatTime(quickLookModal.qlPlayer ? quickLookModal.qlPlayer.duration : 0)
                            font.pixelSize: 11
                            color: textSecondary
                            font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                        }

                        // Mute
                        Rectangle {
                            width: 30; height: 30; radius: rBase
                            color: qlMuteMa.containsMouse ? bgHover : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: quickLookModal.isMuted ? "volume_off" : "volume_up"
                                font.family: iconFont
                                font.pixelSize: 18
                                color: quickLookModal.isMuted ? dangerInk : textSecondary
                            }
                            MouseArea {
                                id: qlMuteMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: quickLookModal.isMuted = !quickLookModal.isMuted
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 8. CUSTOM FROSTED GLASS RIGHT-CLICK CONTEXT MENU
    // =========================================================
    Rectangle {
        id: customMenu
        visible: false
        z: 90
        width: 220
        height: menuColumn.implicitHeight + 16
        radius: rCard
        color: bgPanel
        border.width: 1
        border.color: isDark ? bgHover : borderHard

        property bool isItemMenu: false
        readonly property bool isArchive: selectedPath.endsWith(".zip") || selectedPath.endsWith(".tar.gz") || selectedPath.endsWith(".tgz") || selectedPath.endsWith(".tar.xz") || selectedPath.endsWith(".tar") || selectedPath.endsWith(".7z")

        function openMenu(px, py, onFile) {
            isItemMenu = onFile
            var mx = Math.min(px, window.width - width - 10)
            var my = Math.min(py, window.height - height - 10)
            x = Math.max(10, mx)
            y = Math.max(10, my)
            visible = true
        }

        Column {
            id: menuColumn
            anchors.centerIn: parent
            width: parent.width - 12
            spacing: 2

            // Quick Look Preview
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: qlActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "visibility"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "Quick Look Preview"; color: textPrimary; font.pixelSize: 12; font.bold: true; Layout.fillWidth: true }
                    Text { text: "Space"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: qlActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; openQuickLook() }
                }
            }

            // Open (Default)
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: openActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "open_in_new"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Open"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "↵"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: openActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath && backend) backend.openFile(selectedPath) }
                }
            }

            // Open With...
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu && !selectedPathIsDir()
                color: openWithActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "apps"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "Open With..."; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: openWithActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath) openWithModal.openDialog(selectedPath) }
                }
            }

            // Open in New Tab (Folders only)
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu && selectedPathIsDir()
                color: openTabActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "tab"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "Open in New Tab"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: openTabActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath) createNewTab(selectedPath) }
                }
            }

            // Pin to Favorites (Folders only)
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu && selectedPathIsDir()
                color: pinFavActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "bookmark_add"; font.family: iconFont; color: accentInk; font.pixelSize: 15 }
                    Text { text: "Pin to Favorites"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: pinFavActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath && backend) backend.addBookmark(selectedPath, "") }
                }
            }

            // Open in Terminal
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: termActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "terminal"; font.family: iconFont; color: catInk("code", okInk); font.pixelSize: 15 }
                    Text { text: "Open in Terminal"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+Alt+T"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: termActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (backend) backend.openTerminal(selectedPath) }
                }
            }

            Rectangle { width: parent.width; height: 1; color: borderSoft; visible: customMenu.isItemMenu }

            // Open in split view — only meaningful for a folder.
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu && window.selectedPathIsDir()
                color: splitOpenMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text {
                        text: "splitscreen_right"; font.family: iconFont
                        color: accentInk; font.pixelSize: 15
                    }
                    Text {
                        text: "Open in Split View"; color: textPrimary
                        font.pixelSize: 12; Layout.fillWidth: true
                    }
                }
                MouseArea {
                    id: splitOpenMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        customMenu.visible = false
                        window.openInSplit(window.selectedPath)
                    }
                }
            }

            // Send to device
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: shareActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "send_to_mobile"; font.family: iconFont; color: accentInk; font.pixelSize: 15 }
                    Text { text: "Send to device..."; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: shareActMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; shareDialog.openFor(selectionPaths()) }
                }
            }

            // Star / unstar
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: starActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text {
                        text: window.selectionStarred ? "star" : "star_outline"
                        font.family: iconFont; color: warnInk; font.pixelSize: 15
                    }
                    Text {
                        text: window.selectionStarred ? "Remove star" : "Star"
                        color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true
                    }
                }
                MouseArea {
                    id: starActMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; toggleStar() }
                }
            }

            // Compress to ZIP
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: compActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "archive"; font.family: iconFont; color: catInk("archive", warnInk); font.pixelSize: 15 }
                    Text { text: "Compress to ZIP..."; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: compActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; compressDialog.openDialog(selectedPaths.length > 0 ? selectedPaths : [selectedPath]) }
                }
            }

            // Extract Here
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu && customMenu.isArchive
                color: extHereMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "unarchive"; font.family: iconFont; color: catInk("archive", warnInk); font.pixelSize: 15 }
                    Text { text: "Extract Archive Here"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: extHereMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath && backend) backend.extractArchive(selectedPath, false) }
                }
            }

            Rectangle { width: parent.width; height: 1; color: borderSoft; visible: customMenu.isItemMenu }

            // Cut
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: cutActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "content_cut"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Cut"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+X"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: cutActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPaths.length > 0 && backend) backend.setClipboard(selectedPaths, "cut") }
                }
            }

            // Copy
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: copyActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "content_copy"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Copy"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+C"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: copyActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPaths.length > 0 && backend) backend.setClipboard(selectedPaths, "copy") }
                }
            }

            // Duplicate
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: dupActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "control_point_duplicate"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Duplicate"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+D"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: dupActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (selectedPath && backend) backend.duplicateFile(selectedPath) }
                }
            }

            // Rename
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: renActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "edit"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: selectionCount > 1 ? "Rename " + selectionCount + " Items..." : "Rename"
                           color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "F2"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: renActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; openRenameFor() }
                }
            }

            // Properties
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: propActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "info"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Properties"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Alt+Enter"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: propActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; openProperties() }
                }
            }

            // Tag swatches
            Rectangle {
                width: parent.width; height: 30; radius: rBase
                visible: customMenu.isItemMenu
                color: "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    spacing: 5
                    Repeater {
                        model: window.tagNames
                        delegate: Rectangle {
                            id: swatch
                            required property string modelData
                            width: 16; height: 16; radius: rBase
                            color: tagColor(swatch.modelData)
                            readonly property bool on: selectionTag() === swatch.modelData
                            border.width: swatch.on ? 2.5 : (swatchMa.containsMouse ? 2 : 1.5)
                            border.color: swatch.on ? textPrimary
                                        : Qt.rgba(0, 0, 0, isDark ? 0.35 : 0.15)
                            MouseArea {
                                id: swatchMa
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                // Clicking the tag an item already has removes it,
                                // so the strip is a toggle and there is no separate
                                // "untag" to go looking for.
                                onClicked: {
                                    applyTag(swatch.on ? "" : swatch.modelData)
                                    customMenu.visible = false
                                }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 16; height: 16; radius: rBase
                        color: "transparent"
                        border.width: 1.5; border.color: borderHard
                        visible: selectionTag() !== ""
                        Text {
                            anchors.centerIn: parent; text: "close"
                            font.family: iconFont; font.pixelSize: 11; color: textMuted
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: { applyTag(""); customMenu.visible = false }
                        }
                    }
                }
            }

            // Background Menu Items
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: !customMenu.isItemMenu
                color: newFldMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "create_new_folder"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "New Folder"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+Shift+N"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: newFldMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; newFolderDialog.openDialog() }
                }
            }

            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: !customMenu.isItemMenu
                color: newFilMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "note_add"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "New Text File"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+N"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: newFilMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; newFileDialog.openDialog() }
                }
            }

            // Paste
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: pasteActMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "content_paste"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Paste"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+V"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: pasteActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; if (backend) backend.pasteFiles() }
                }
            }

            Rectangle { width: parent.width; height: 1; color: borderSoft }

            // Move to Trash
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: customMenu.isItemMenu
                color: delActMa.containsMouse ? Qt.rgba(0.93, 0.27, 0.27, 0.18) : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "delete"; font.family: iconFont; color: delActMa.containsMouse ? dangerInk : textSecondary; font.pixelSize: 15 }
                    Text { text: "Move to Trash"; color: delActMa.containsMouse ? dangerInk : textPrimary; font.pixelSize: 12; font.bold: delActMa.containsMouse; Layout.fillWidth: true }
                    Text { text: "Del"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: delActMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; deleteSelection() }
                }
            }

            // Select All
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                visible: !customMenu.isItemMenu
                color: selAllMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "select_all"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Select All"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: "Ctrl+A"; color: textMuted; font.pixelSize: 10 }
                }
                MouseArea {
                    id: selAllMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { customMenu.visible = false; selectAll() }
                }
            }
        }
    }

    // =========================================================
    // 8B. SIDEBAR BOOKMARK CONTEXT MENU
    // =========================================================
    Rectangle {
        id: bookmarkMenu
        visible: false
        z: 95
        width: 190
        height: bmMenuCol.implicitHeight + 14
        radius: rCard
        color: bgPanel
        border.width: 1
        border.color: isDark ? bgHover : borderHard

        property string menuPath: ""
        property string menuName: ""

        function openMenu(px, py, path, name) {
            menuPath = path
            menuName = name
            var mx = Math.min(px, window.width - width - 10)
            var my = Math.min(py, window.height - height - 10)
            x = Math.max(10, mx)
            y = Math.max(10, my)
            visible = true
        }

        Column {
            id: bmMenuCol
            anchors.centerIn: parent
            width: parent.width - 12
            spacing: 2

            // Open
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmOpenMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "folder_open"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Open"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmOpenMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; if (backend) backend.cd(bookmarkMenu.menuPath) }
                }
            }

            // Open in New Tab
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmTabMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "tab"; font.family: iconFont; color: accentColor; font.pixelSize: 15 }
                    Text { text: "Open in New Tab"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmTabMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; createNewTab(bookmarkMenu.menuPath) }
                }
            }

            // Open in New Window
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmWinMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "open_in_new"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Open in New Window"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmWinMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; if (backend) backend.openNewWindow(bookmarkMenu.menuPath) }
                }
            }

            // Open in Terminal
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmTermMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "terminal"; font.family: iconFont; color: catInk("code", okInk); font.pixelSize: 15 }
                    Text { text: "Open in Terminal"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmTermMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; if (backend) backend.openTerminal(bookmarkMenu.menuPath) }
                }
            }

            Rectangle { width: parent.width; height: 1; color: borderSoft }

            // Remove from Favorites
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmRemoveMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "bookmark_remove"; font.family: iconFont; color: dangerInk; font.pixelSize: 15 }
                    Text { text: "Remove from Favorites"; color: dangerInk; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmRemoveMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; if (backend) backend.removeBookmark(bookmarkMenu.menuPath) }
                }
            }

            // Copy Path
            Rectangle {
                width: parent.width; height: 28; radius: rBase
                color: bmCopyMa.containsMouse ? bgHover : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    Text { text: "content_copy"; font.family: iconFont; color: textSecondary; font.pixelSize: 15 }
                    Text { text: "Copy Path"; color: textPrimary; font.pixelSize: 12; Layout.fillWidth: true }
                }
                MouseArea {
                    id: bmCopyMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { bookmarkMenu.visible = false; if (backend) backend.copyPath(bookmarkMenu.menuPath) }
                }
            }
        }
    }

    // =========================================================
    // 9. MODAL DIALOGS (New Folder / New File / Rename / Compress)
    // =========================================================
    // ---- PERMANENT DELETE CONFIRMATION ----
    Rectangle {
        id: confirmPurge
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 120

        property var doomed: []

        function openDialog(paths) {
            confirmPurge.doomed = paths
            confirmPurge.visible = true
        }
        function commit() {
            if (backend && confirmPurge.doomed.length > 0) {
                backend.deleteFilesPermanently(confirmPurge.doomed)
                selectedPaths = []
                selectedPath = ""
            }
            confirmPurge.visible = false
            confirmPurge.doomed = []
            restoreKeyFocus()
        }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Rectangle {
            anchors.centerIn: parent
            width: 440
            height: 210
            radius: rCard
            color: bgPanel
            border.width: 1
            border.color: borderSoft

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    spacing: 10
                    Text {
                        text: "delete_forever"
                        font.family: iconFont
                        font.variableAxes: iconFilled
                        font.pixelSize: 26
                        color: dangerInk
                    }
                    Text {
                        text: "Delete permanently?"
                        font.pixelSize: 16
                        font.bold: true
                        color: textPrimary
                    }
                }

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: textSecondary
                    text: {
                        var n = confirmPurge.doomed.length
                        var what = n === 1
                            ? ("\"" + confirmPurge.doomed[0].split("/").pop() + "\"")
                            : (n + " items")
                        return what + " will be destroyed. This does not go to the trash and cannot be undone."
                    }
                }

                Item { Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 96; height: 36; radius: rBase
                        color: cancelPurgeMa.containsMouse ? bgHover : bgDark
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 12; color: textPrimary }
                        MouseArea {
                            id: cancelPurgeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { confirmPurge.visible = false; confirmPurge.doomed = [] }
                        }
                    }

                    Rectangle {
                        width: 132; height: 36; radius: rBase
                        color: okPurgeMa.containsMouse ? dangerInk : Qt.rgba(dangerInk.r, dangerInk.g, dangerInk.b, 0.18)
                        border.width: 1; border.color: dangerInk
                        Text {
                            anchors.centerIn: parent
                            text: "Delete forever"
                            font.pixelSize: 12
                            font.bold: true
                            color: okPurgeMa.containsMouse ? onAccent : dangerInk
                        }
                        MouseArea {
                            id: okPurgeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: confirmPurge.commit()
                        }
                    }
                }
            }
        }

        Keys.onEscapePressed: { confirmPurge.visible = false; confirmPurge.doomed = [] }
    }

    Rectangle {
        id: newFolderDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 100

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openDialog() {
            visible = true
            folderNameField.text = "New Folder"
            folderNameField.focus = true
            folderNameField.forceActiveFocus()
            folderNameField.selectAll()
            Qt.callLater(function() {
                folderNameField.forceActiveFocus()
                folderNameField.selectAll()
            })
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420; height: 190; radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 16

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text { anchors.centerIn: parent; text: "create_new_folder"; font.family: iconFont; color: accentColor; font.pixelSize: 20 }
                    }
                    Text { text: "Create New Folder"; font.pixelSize: 16; font.bold: true; color: textPrimary }
                }

                TextField {
                    id: folderNameField
                    Layout.fillWidth: true; height: 42
                    color: textPrimary; font.pixelSize: 13
                    placeholderText: "Enter folder name..."
                    placeholderTextColor: textMuted
                    selectByMouse: true
                    background: Rectangle {
                        color: isDark ? bgSunken : bgSunken
                        radius: rBase
                        border.color: folderNameField.activeFocus ? accentColor : borderSoft
                        border.width: 1.5
                    }
                    onAccepted: {
                        if (backend && folderNameField.text.trim()) backend.createDirectory("", folderNameField.text.trim())
                        newFolderDialog.visible = false
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: cancelFldMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: cancelFldMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: newFolderDialog.visible = false }
                    }
                    Rectangle {
                        width: 120; height: 36; radius: rBase
                        color: createFldMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Create Folder"; color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: createFldMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend && folderNameField.text.trim()) backend.createDirectory("", folderNameField.text.trim())
                                newFolderDialog.visible = false
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: newFileDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 100

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openDialog() {
            visible = true
            fileNameField.text = "new_file.txt"
            fileNameField.focus = true
            fileNameField.forceActiveFocus()
            fileNameField.selectAll()
            Qt.callLater(function() {
                fileNameField.forceActiveFocus()
                fileNameField.selectAll()
            })
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420; height: 190; radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 16

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text { anchors.centerIn: parent; text: "note_add"; font.family: iconFont; color: accentColor; font.pixelSize: 20 }
                    }
                    Text { text: "Create New File"; font.pixelSize: 16; font.bold: true; color: textPrimary }
                }

                TextField {
                    id: fileNameField
                    Layout.fillWidth: true; height: 42
                    color: textPrimary; font.pixelSize: 13
                    placeholderText: "Enter file name..."
                    placeholderTextColor: textMuted
                    selectByMouse: true
                    background: Rectangle {
                        color: isDark ? bgSunken : bgSunken
                        radius: rBase
                        border.color: fileNameField.activeFocus ? accentColor : borderSoft
                        border.width: 1.5
                    }
                    onAccepted: {
                        if (backend && fileNameField.text.trim()) backend.createFile("", fileNameField.text.trim())
                        newFileDialog.visible = false
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: cancelFilMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: cancelFilMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: newFileDialog.visible = false }
                    }
                    Rectangle {
                        width: 110; height: 36; radius: rBase
                        color: createFilMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Create File"; color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: createFilMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend && fileNameField.text.trim()) backend.createFile("", fileNameField.text.trim())
                                newFileDialog.visible = false
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: renameDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 100

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openRename(targetPath) {
            renameTarget = targetPath
            var parts = targetPath.split("/")
            renameField.text = parts[parts.length - 1]
            visible = true
            renameField.focus = true
            renameField.forceActiveFocus()
            renameField.selectAll()
            Qt.callLater(function() {
                renameField.forceActiveFocus()
                renameField.selectAll()
            })
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420; height: 190; radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 16

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text { anchors.centerIn: parent; text: "edit"; font.family: iconFont; color: accentColor; font.pixelSize: 20 }
                    }
                    Text { text: "Rename Item"; font.pixelSize: 16; font.bold: true; color: textPrimary }
                }

                TextField {
                    id: renameField
                    Layout.fillWidth: true; height: 42
                    color: textPrimary; font.pixelSize: 13
                    selectByMouse: true
                    background: Rectangle {
                        color: isDark ? bgSunken : bgSunken
                        radius: rBase
                        border.color: renameField.activeFocus ? accentColor : borderSoft
                        border.width: 1.5
                    }
                    onAccepted: {
                        if (backend && renameTarget && renameField.text.trim()) backend.renameFile(renameTarget, renameField.text.trim())
                        renameDialog.visible = false
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: cancelRenMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: cancelRenMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: renameDialog.visible = false }
                    }
                    Rectangle {
                        width: 90; height: 36; radius: rBase
                        color: applyRenMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Rename"; color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: applyRenMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend && renameTarget && renameField.text.trim()) backend.renameFile(renameTarget, renameField.text.trim())
                                renameDialog.visible = false
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: compressDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 100
        property var targetPaths: []

        MouseArea { anchors.fill: parent; onClicked: {} }

        function confirm() {
            if (backend && targetPaths.length > 0 && archiveNameField.text.trim()) {
                backend.compressFiles(targetPaths, archiveNameField.text.trim(),
                                      zipRadio.checked ? "zip" : "tar.gz")
            }
            visible = false
        }

        function openDialog(paths) {
            targetPaths = paths
            if (paths.length === 1) {
                var p = paths[0].split("/")
                archiveNameField.text = p[p.length - 1]
            } else {
                archiveNameField.text = "archive"
            }
            visible = true
            archiveNameField.focus = true
            archiveNameField.forceActiveFocus()
            archiveNameField.selectAll()
            Qt.callLater(function() {
                archiveNameField.forceActiveFocus()
                archiveNameField.selectAll()
            })
        }

        Rectangle {
            anchors.centerIn: parent
            width: 440; height: 230; radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 14

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(0.96, 0.62, 0.04, 0.15)
                        Text { anchors.centerIn: parent; text: "archive"; font.family: iconFont; color: catInk("archive", warnInk); font.pixelSize: 20 }
                    }
                    Text { text: "Compress to Archive"; font.pixelSize: 16; font.bold: true; color: textPrimary }
                }

                TextField {
                    id: archiveNameField
                    Layout.fillWidth: true; height: 42
                    color: textPrimary; font.pixelSize: 13
                    placeholderText: "Enter archive name..."
                    placeholderTextColor: textMuted
                    selectByMouse: true
                    background: Rectangle {
                        color: isDark ? bgSunken : bgSunken
                        radius: rBase
                        border.color: archiveNameField.activeFocus ? accentColor : borderSoft
                        border.width: 1.5
                    }
                    onAccepted: compressDialog.confirm()
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Text { text: "Format:"; color: textSecondary; font.pixelSize: 12 }
                    RadioButton { id: zipRadio; text: ".zip"; checked: true }
                    RadioButton { id: tarRadio; text: ".tar.gz" }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: cancelCmpMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: cancelCmpMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: compressDialog.visible = false }
                    }
                    Rectangle {
                        width: 100; height: 36; radius: rBase
                        color: applyCmpMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Compress"; color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: applyCmpMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: compressDialog.confirm()
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 10. OPEN WITH APPLICATION MODAL DIALOG
    // =========================================================
    Rectangle {
        id: openWithModal
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.78)
        visible: false
        z: 105

        property string targetPath: ""
        property string targetName: ""
        property var appList: []
        property string detectedMime: ""
        property int selectedIdx: 0
        property bool alwaysDefault: false

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openDialog(path) {
            targetPath = path
            var p = path.split("/")
            targetName = p[p.length - 1]
            selectedIdx = 0
            alwaysDefault = false
            searchAppField.text = ""
            var data = backend ? backend.getAvailableApps(path) : { mime: "", all: [] }
            detectedMime = data.mime || ""
            appList = data.all || []
            visible = true
            searchAppField.forceActiveFocus()
            Qt.callLater(function() { searchAppField.forceActiveFocus() })
        }

        readonly property var filteredApps: {
            var q = searchAppField.text.trim().toLowerCase()
            if (!q) return appList
            var res = []
            for (var i = 0; i < appList.length; i++) {
                var a = appList[i]
                if (a.name.toLowerCase().indexOf(q) >= 0 || a.exec.toLowerCase().indexOf(q) >= 0) {
                    res.push(a)
                }
            }
            return res
        }

        function executeOpen() {
            if (filteredApps.length > 0 && selectedIdx >= 0 && selectedIdx < filteredApps.length) {
                var app = filteredApps[selectedIdx]
                if (alwaysDefault) {
                    backend.setAsDefaultApp(targetPath, app.desktop, app.exec)
                } else {
                    backend.openWithApp(targetPath, app.exec)
                }
            }
            openWithModal.visible = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: 480; height: 500; radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? "#2d2d42" : borderHard
            clip: true

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                // Header
                RowLayout {
                    spacing: 12
                    Rectangle {
                        width: 36; height: 36; radius: rBase
                        color: Qt.rgba(0.39, 0.4, 0.95, 0.15)
                        Text { anchors.centerIn: parent; text: "apps"; font.family: iconFont; color: accentColor; font.pixelSize: 22 }
                    }
                    Column {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "Open With Application"; font.pixelSize: 16; font.bold: true; color: textPrimary }
                        Text { text: openWithModal.targetName + " (" + openWithModal.detectedMime + ")"; font.pixelSize: 11; color: textMuted; elide: Text.ElideMiddle; width: 380 }
                    }
                }

                // Search Box
                TextField {
                    id: searchAppField
                    Layout.fillWidth: true; height: 38
                    color: textPrimary; font.pixelSize: 12
                    placeholderText: "Search applications..."
                    placeholderTextColor: textMuted
                    selectByMouse: true
                    background: Rectangle {
                        color: isDark ? "#0b0b10" : bgSunken
                        radius: rBase
                        border.color: searchAppField.activeFocus ? accentColor : borderSoft
                        border.width: 1.5
                    }
                    onTextChanged: { openWithModal.selectedIdx = 0 }
                    onAccepted: { openWithModal.executeOpen() }
                }

                // Applications List
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    color: isDark ? "#0c0c14" : bgSunken
                    radius: rBase
                    border.width: 1; border.color: borderSoft
                    clip: true

                    ListView {
                        id: appListView
                        anchors.fill: parent; anchors.margins: 4
                        model: openWithModal.filteredApps
                        spacing: 2
                        clip: true
                        ScrollBar.vertical: ScrollBar { active: true }

                        delegate: Rectangle {
                            width: appListView.width - 8; height: 44; radius: rBase
                            color: openWithModal.selectedIdx === index ? (isDark ? "#282840" : bgCard)
                                 : (appRowMa.containsMouse ? (isDark ? "#1c1c2b" : bgSunken) : "transparent")
                            border.width: openWithModal.selectedIdx === index ? 1 : 0
                            border.color: accentColor

                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 10
                                Rectangle {
                                    width: 26; height: 26; radius: rBase
                                    color: isDark ? "#1e1e2d" : bgCard
                                    Text {
                                        anchors.centerIn: parent
                                        text: "open_in_new"
                                        font.family: iconFont
                                        color: accentColor
                                        font.pixelSize: 16
                                    }
                                }
                                Column {
                                    Layout.fillWidth: true; spacing: 1
                                    Text {
                                        text: modelData.name
                                        color: textPrimary
                                        font.pixelSize: 12
                                        font.bold: modelData.isDefault
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.exec
                                        color: textMuted
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }
                                Rectangle {
                                    visible: modelData.isDefault
                                    width: 54; height: 18; radius: rBase
                                    color: Qt.rgba(0.06, 0.72, 0.51, 0.2)
                                    Text {
                                        anchors.centerIn: parent
                                        text: "DEFAULT"
                                        color: okInk
                                        font.pixelSize: 9
                                        font.bold: true
                                    }
                                }
                            }

                            MouseArea {
                                id: appRowMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { openWithModal.selectedIdx = index }
                                onDoubleClicked: { openWithModal.selectedIdx = index; openWithModal.executeOpen() }
                            }
                        }
                    }
                }

                // Checkbox: Set as Default
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Rectangle {
                        width: 18; height: 18; radius: rBase
                        color: openWithModal.alwaysDefault ? accentColor : "transparent"
                        border.width: 1.5; border.color: openWithModal.alwaysDefault ? accentColor : textMuted
                        Text {
                            anchors.centerIn: parent
                            visible: openWithModal.alwaysDefault
                            text: "check"
                            font.family: iconFont
                            color: onAccent
                            font.pixelSize: 13
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: openWithModal.alwaysDefault = !openWithModal.alwaysDefault
                        }
                    }
                    Text {
                        text: "Always use this app to open " + (openWithModal.detectedMime ? openWithModal.detectedMime : "this file type") + " (Set Default)"
                        color: textSecondary
                        font.pixelSize: 11
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: openWithModal.alwaysDefault = !openWithModal.alwaysDefault
                        }
                    }
                }

                // Action Buttons
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: cancelOwMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: cancelOwMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: openWithModal.visible = false }
                    }
                    Rectangle {
                        width: 90; height: 36; radius: rBase
                        color: applyOwMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Open"; color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: applyOwMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: openWithModal.executeOpen()
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 11. PROPERTIES
    // =========================================================
    //
    // Every reference inside these three dialogs qualifies the dialog's own
    // properties by id. QML's scope chain is the object plus the COMPONENT ROOT,
    // never the objects in between, so a bare name here resolves to nothing and
    // throws — which is exactly how the compress dialog quietly stopped working.

    Rectangle {
        id: propertiesDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 130

        property var info: ({})
        property var paths: []
        property int mode: 0
        property bool recurse: false
        property string liveSize: ""

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openFor(list) {
            propertiesDialog.paths = list
            propertiesDialog.info = backend ? backend.fileProperties(list) : ({})
            propertiesDialog.mode = propertiesDialog.info.mode !== undefined
                                    ? propertiesDialog.info.mode : 0
            propertiesDialog.recurse = false
            propertiesDialog.liveSize = ""
            propertiesDialog.srcBe = backend
            // A folder's real size is a walk, so it is asked for separately and
            // arrives whenever it arrives; the row says "Calculating…" until then.
            if (propertiesDialog.info.isDir && backend) {
                propertiesDialog.liveSize = "Calculating…"
                backend.requestDirSize(propertiesDialog.info.path)
            }
            propertiesDialog.visible = true
        }

        property var srcBe: null
        Connections {
            target: propertiesDialog.srcBe
            ignoreUnknownSignals: true
            function onDirSizeReady(path, data) {
                if (!propertiesDialog.visible) return
                if (path !== propertiesDialog.info.path) return
                propertiesDialog.liveSize = data.bytes + " bytes  ·  "
                    + data.files + " files, " + data.dirs + " folders"
            }
        }

        function bit(who, what) {
            // who: 0 owner, 1 group, 2 others.  what: 4 read, 2 write, 1 execute.
            return (propertiesDialog.mode >> ((2 - who) * 3)) & what
        }
        function toggleBit(who, what) {
            propertiesDialog.mode ^= (what << ((2 - who) * 3))
        }
        function octal() {
            var s = (propertiesDialog.mode & 0o7777).toString(8)
            while (s.length < 4) s = "0" + s
            return s
        }
        function apply() {
            if (backend && propertiesDialog.info.path) {
                backend.setPermissions(propertiesDialog.info.path,
                                       propertiesDialog.mode,
                                       propertiesDialog.recurse)
            }
            propertiesDialog.visible = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: 460
            height: Math.min(window.height - 60, propCol.implicitHeight + 40)
            radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                id: propCol
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Rectangle {
                        width: 44; height: 44; radius: rCard
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.14)
                        Text {
                            anchors.centerIn: parent
                            text: propertiesDialog.info.multi ? "checklist"
                                : (propertiesDialog.info.isDir ? "folder" : "description")
                            font.family: iconFont; font.pixelSize: 24
                            font.variableAxes: iconFilled
                            color: catInk(propertiesDialog.info.category, accentInk)
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text {
                            text: propertiesDialog.info.name || ""
                            font.pixelSize: 16; font.bold: true; color: textPrimary
                            Layout.fillWidth: true; elide: Text.ElideMiddle
                        }
                        Text {
                            text: propertiesDialog.info.kind || ""
                            font.pixelSize: 11; color: textSecondary
                            visible: !propertiesDialog.info.multi
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                // ---- the facts ----
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2; columnSpacing: 14; rowSpacing: 7

                    component Key: Text {
                        font.pixelSize: 11; color: textMuted
                        Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    }
                    component Val: Text {
                        font.pixelSize: 11; color: textPrimary
                        Layout.fillWidth: true; wrapMode: Text.WrapAnywhere
                    }

                    Key { text: "Where"; visible: !!propertiesDialog.info.where }
                    Val { text: propertiesDialog.info.where || ""; visible: !!propertiesDialog.info.where }

                    Key { text: "Size" }
                    Val {
                        text: propertiesDialog.info.multi
                            ? (propertiesDialog.info.sizeStr + "  ·  "
                               + propertiesDialog.info.files + " files, "
                               + propertiesDialog.info.dirs + " folders")
                            : (propertiesDialog.liveSize
                               ? propertiesDialog.liveSize
                               : (propertiesDialog.info.sizeStr || ""))
                    }

                    Key { text: "On disk"; visible: !propertiesDialog.info.multi }
                    Val { text: propertiesDialog.info.onDisk || ""; visible: !propertiesDialog.info.multi }

                    Key { text: "Contains"; visible: propertiesDialog.info.items > -1 }
                    Val {
                        visible: propertiesDialog.info.items > -1
                        text: propertiesDialog.info.items + " item"
                              + (propertiesDialog.info.items === 1 ? "" : "s")
                    }

                    Key { text: "Links to"; visible: !!propertiesDialog.info.isLink }
                    Val { text: propertiesDialog.info.linkTarget || ""; visible: !!propertiesDialog.info.isLink }

                    Key { text: "Modified"; visible: !propertiesDialog.info.multi }
                    Val { text: propertiesDialog.info.modified || ""; visible: !propertiesDialog.info.multi }

                    // NOT "Created". Linux has no creation time in stat and
                    // st_ctime is the inode change time, so it is named for what
                    // it actually is.
                    Key { text: "Attributes changed"; visible: !propertiesDialog.info.multi }
                    Val { text: propertiesDialog.info.changed || ""; visible: !propertiesDialog.info.multi }

                    Key { text: "Owner"; visible: !propertiesDialog.info.multi }
                    Val {
                        visible: !propertiesDialog.info.multi
                        text: (propertiesDialog.info.owner || "") + " : "
                              + (propertiesDialog.info.group || "")
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; height: 1; color: borderSoft
                    visible: !propertiesDialog.info.multi
                }

                // ---- permissions ----
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: !propertiesDialog.info.multi

                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "PERMISSIONS"; font.pixelSize: 10; font.bold: true
                               font.letterSpacing: 1; color: textMuted }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: propertiesDialog.octal() + "   "
                                  + (propertiesDialog.info.modeStr || "")
                            font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                            font.pixelSize: 11; color: textSecondary
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        Item { Layout.preferredWidth: 60 }
                        Text { text: "Read"; font.pixelSize: 10; color: textMuted
                               Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                        Text { text: "Write"; font.pixelSize: 10; color: textMuted
                               Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                        Text { text: "Execute"; font.pixelSize: 10; color: textMuted
                               Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    }

                    Repeater {
                        model: [{ n: "Owner", i: 0 }, { n: "Group", i: 1 }, { n: "Others", i: 2 }]
                        delegate: RowLayout {
                            id: pRow
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 6
                            Text {
                                text: pRow.modelData.n
                                font.pixelSize: 11; color: textPrimary
                                Layout.preferredWidth: 60
                            }
                            Repeater {
                                model: [4, 2, 1]
                                delegate: Rectangle {
                                    id: permBox
                                    required property int modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 26
                                    radius: rBase
                                    readonly property bool on: propertiesDialog.bit(pRow.modelData.i, permBox.modelData) > 0
                                    color: permBox.on
                                        ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.22)
                                        : (permMa.containsMouse ? bgHover : "transparent")
                                    border.width: 1
                                    border.color: permBox.on ? accentColor : borderSoft
                                    Text {
                                        anchors.centerIn: parent
                                        text: permBox.modelData === 4 ? "r"
                                            : (permBox.modelData === 2 ? "w" : "x")
                                        font.family: backend && backend.theme ? backend.theme.fontMono : "monospace"
                                        font.pixelSize: 12
                                        color: permBox.on ? accentInk : textMuted
                                    }
                                    MouseArea {
                                        id: permMa
                                        anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: !!propertiesDialog.info.writable
                                        onClicked: propertiesDialog.toggleBit(pRow.modelData.i, permBox.modelData)
                                    }
                                }
                            }
                        }
                    }

                    CheckBox {
                        id: recurseBox
                        visible: !!propertiesDialog.info.isDir
                        text: "Apply to enclosed items"
                        checked: propertiesDialog.recurse
                        onToggled: propertiesDialog.recurse = checked
                        font.pixelSize: 11
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: !propertiesDialog.info.writable
                        text: "You do not own this item, so its permissions cannot be changed here."
                        font.pixelSize: 10; color: textMuted; wrapMode: Text.WordWrap
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: propCloseMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Close"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: propCloseMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: propertiesDialog.visible = false }
                    }
                    Rectangle {
                        width: 130; height: 36; radius: rBase
                        visible: !propertiesDialog.info.multi && !!propertiesDialog.info.writable
                        opacity: propertiesDialog.mode === propertiesDialog.info.mode ? 0.45 : 1.0
                        color: propApplyMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Apply Permissions"
                               color: onAccent; font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: propApplyMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: propertiesDialog.mode !== propertiesDialog.info.mode
                                     || propertiesDialog.recurse
                            onClicked: propertiesDialog.apply()
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 12. BATCH RENAME
    // =========================================================

    Rectangle {
        id: batchRenameDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 130

        property var paths: []
        property int mode: 0            // 0 replace · 1 prefix/suffix · 2 numbered
        property string findText: ""
        property string replaceText: ""
        property string prefixText: ""
        property string suffixText: ""
        property string baseText: ""
        property int startAt: 1
        property int digits: 2

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openFor(list) {
            batchRenameDialog.paths = list
            batchRenameDialog.mode = 0
            batchRenameDialog.findText = ""
            batchRenameDialog.replaceText = ""
            batchRenameDialog.prefixText = ""
            batchRenameDialog.suffixText = ""
            batchRenameDialog.baseText = "File"
            batchRenameDialog.startAt = 1
            batchRenameDialog.digits = 2
            batchRenameDialog.visible = true
            brFind.forceActiveFocus()
        }

        function baseName(p) { return ("" + p).split("/").pop() }
        function stemOf(n) {
            var i = n.lastIndexOf(".")
            return i > 0 ? n.substring(0, i) : n
        }
        function extOf(n) {
            var i = n.lastIndexOf(".")
            return i > 0 ? n.substring(i) : ""
        }
        function pad(n, width) {
            var s = "" + n
            while (s.length < width) s = "0" + s
            return s
        }

        // The one place a new name is decided. The preview list and the rename both
        // read it, so what you are shown is by construction what you get.
        function newNameFor(index) {
            var old = batchRenameDialog.baseName(batchRenameDialog.paths[index])
            if (batchRenameDialog.mode === 0) {
                if (!batchRenameDialog.findText) return old
                return old.split(batchRenameDialog.findText)
                          .join(batchRenameDialog.replaceText)
            }
            if (batchRenameDialog.mode === 1) {
                // The extension is not part of the name you are decorating — a
                // suffix belongs before the dot, or every file becomes extensionless.
                return batchRenameDialog.prefixText
                     + batchRenameDialog.stemOf(old)
                     + batchRenameDialog.suffixText
                     + batchRenameDialog.extOf(old)
            }
            return batchRenameDialog.baseText
                 + " " + batchRenameDialog.pad(batchRenameDialog.startAt + index,
                                               batchRenameDialog.digits)
                 + batchRenameDialog.extOf(old)
        }

        readonly property var plan: {
            var out = []
            var seen = ({})
            for (var i = 0; i < batchRenameDialog.paths.length; i++) {
                var old = batchRenameDialog.baseName(batchRenameDialog.paths[i])
                var neu = batchRenameDialog.newNameFor(i)
                var bad = ""
                if (!neu || !neu.trim()) bad = "empty"
                else if (neu.indexOf("/") !== -1) bad = "slash"
                else if (seen[neu]) bad = "clash"
                seen[neu] = true
                out.push({ old: old, neu: neu, bad: bad, changed: neu !== old })
            }
            return out
        }
        readonly property int changeCount: {
            var n = 0
            for (var i = 0; i < batchRenameDialog.plan.length; i++)
                if (batchRenameDialog.plan[i].changed && !batchRenameDialog.plan[i].bad) n++
            return n
        }
        readonly property bool planOk: {
            for (var i = 0; i < batchRenameDialog.plan.length; i++)
                if (batchRenameDialog.plan[i].bad) return false
            return batchRenameDialog.changeCount > 0
        }

        function commit() {
            if (!batchRenameDialog.planOk || !backend) return
            var names = []
            for (var i = 0; i < batchRenameDialog.plan.length; i++)
                names.push(batchRenameDialog.plan[i].neu)
            backend.batchRename(batchRenameDialog.paths, names)
            batchRenameDialog.visible = false
            selectedPaths = []; selectedPath = ""
        }

        Rectangle {
            anchors.centerIn: parent
            width: 560
            height: Math.min(window.height - 60, 520)
            radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text { anchors.centerIn: parent; text: "drive_file_rename_outline"
                               font.family: iconFont; color: accentInk; font.pixelSize: 20 }
                    }
                    Text {
                        text: "Rename " + batchRenameDialog.paths.length + " Items"
                        font.pixelSize: 16; font.bold: true; color: textPrimary
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Repeater {
                        model: ["Find & Replace", "Prefix / Suffix", "Numbered"]
                        delegate: Rectangle {
                            id: modeTab
                            required property int index
                            required property string modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 30
                            radius: rBase
                            readonly property bool on: batchRenameDialog.mode === modeTab.index
                            color: modeTab.on
                                ? Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.20)
                                : (modeMa.containsMouse ? bgHover : "transparent")
                            border.width: 1
                            border.color: modeTab.on ? accentColor : borderSoft
                            Text {
                                anchors.centerIn: parent; text: modeTab.modelData
                                font.pixelSize: 11; color: modeTab.on ? accentInk : textSecondary
                            }
                            MouseArea {
                                id: modeMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: batchRenameDialog.mode = modeTab.index
                            }
                        }
                    }
                }

                component BrField: TextField {
                    Layout.fillWidth: true
                    color: textPrimary; font.pixelSize: 12
                    placeholderTextColor: textMuted
                    selectByMouse: true
                    // Return commits from whichever field you are in. commit() is
                    // the same guarded path the button uses, so an invalid plan
                    // still refuses.
                    onAccepted: batchRenameDialog.commit()
                    background: Rectangle {
                        color: isDark ? bgSunken : bgSunken
                        radius: rBase
                        border.width: 1.5
                        border.color: parent.activeFocus ? accentColor : borderSoft
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: batchRenameDialog.mode === 0
                    BrField {
                        id: brFind
                        placeholderText: "Find..."
                        onTextChanged: batchRenameDialog.findText = text
                    }
                    Text { text: "→"; color: textMuted; font.pixelSize: 14 }
                    BrField {
                        placeholderText: "Replace with..."
                        onTextChanged: batchRenameDialog.replaceText = text
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: batchRenameDialog.mode === 1
                    BrField {
                        placeholderText: "Prefix..."
                        onTextChanged: batchRenameDialog.prefixText = text
                    }
                    BrField {
                        placeholderText: "Suffix..."
                        onTextChanged: batchRenameDialog.suffixText = text
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: batchRenameDialog.mode === 2
                    BrField {
                        placeholderText: "Base name..."
                        text: "File"
                        onTextChanged: batchRenameDialog.baseText = text
                    }
                    Text { text: "start"; color: textMuted; font.pixelSize: 11 }
                    SpinBox {
                        from: 0; to: 9999; value: batchRenameDialog.startAt
                        onValueChanged: batchRenameDialog.startAt = value
                        Layout.preferredWidth: 100
                    }
                    Text { text: "digits"; color: textMuted; font.pixelSize: 11 }
                    SpinBox {
                        from: 1; to: 6; value: batchRenameDialog.digits
                        onValueChanged: batchRenameDialog.digits = value
                        Layout.preferredWidth: 90
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                // ---- live preview ----
                ScrollView {
                    id: brScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    ColumnLayout {
                        width: brScroll.availableWidth
                        spacing: 1
                        Repeater {
                            model: batchRenameDialog.plan
                            delegate: Rectangle {
                                id: prevRow
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 26
                                radius: rBase
                                color: prevRow.modelData.bad
                                    ? Qt.rgba(1, 0.3, 0.3, 0.12)
                                    : (prevRow.modelData.changed ? "transparent" : "transparent")
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8; anchors.rightMargin: 8
                                    spacing: 8
                                    Text {
                                        text: prevRow.modelData.old
                                        font.pixelSize: 11
                                        color: prevRow.modelData.changed ? textMuted : textSecondary
                                        Layout.preferredWidth: 200
                                        elide: Text.ElideMiddle
                                    }
                                    Text {
                                        text: prevRow.modelData.changed ? "→" : "="
                                        font.pixelSize: 11; color: textMuted
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideMiddle
                                        font.pixelSize: 11
                                        font.bold: prevRow.modelData.changed
                                        color: prevRow.modelData.bad ? dangerInk
                                             : (prevRow.modelData.changed ? accentInk : textSecondary)
                                        text: prevRow.modelData.bad === "clash"
                                                ? prevRow.modelData.neu + "   (already used above)"
                                            : prevRow.modelData.bad === "empty"
                                                ? "(name would be empty)"
                                            : prevRow.modelData.bad === "slash"
                                                ? "(names cannot contain /)"
                                            : prevRow.modelData.neu
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text {
                        Layout.fillWidth: true
                        font.pixelSize: 11
                        color: batchRenameDialog.planOk ? textSecondary : dangerInk
                        text: batchRenameDialog.planOk
                            ? batchRenameDialog.changeCount + " of "
                              + batchRenameDialog.paths.length + " will change"
                            : (batchRenameDialog.changeCount === 0
                               ? "Nothing would change yet"
                               : "Fix the highlighted names first")
                    }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: brCancelMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: brCancelMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: batchRenameDialog.visible = false }
                    }
                    Rectangle {
                        width: 100; height: 36; radius: rBase
                        opacity: batchRenameDialog.planOk ? 1.0 : 0.45
                        color: brOkMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text { anchors.centerIn: parent; text: "Rename"; color: onAccent
                               font.pixelSize: 12; font.bold: true }
                        MouseArea {
                            id: brOkMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: batchRenameDialog.planOk
                            onClicked: batchRenameDialog.commit()
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // 13. DUPLICATE FINDER
    // =========================================================

    Rectangle {
        id: duplicatesDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: false
        z: 130

        property string root: ""
        property bool scanning: false
        property int seen: 0
        property var groups: []
        property var chosen: ({})       // path -> true, the ones to remove
        property var srcBe: null

        MouseArea { anchors.fill: parent; onClicked: {} }

        function openFor(dir) {
            duplicatesDialog.root = dir
            duplicatesDialog.groups = []
            duplicatesDialog.chosen = ({})
            duplicatesDialog.seen = 0
            duplicatesDialog.scanning = true
            duplicatesDialog.srcBe = backend
            duplicatesDialog.visible = true
            if (backend) backend.findDuplicates(dir)
        }
        function close() {
            if (duplicatesDialog.scanning && duplicatesDialog.srcBe)
                duplicatesDialog.srcBe.cancelDuplicates()
            duplicatesDialog.scanning = false
            duplicatesDialog.visible = false
        }

        Connections {
            target: duplicatesDialog.srcBe
            ignoreUnknownSignals: true
            function onDuplicatesReady(groups) {
                duplicatesDialog.groups = groups
                duplicatesDialog.scanning = false
            }
            function onDuplicateProgress(count, where) {
                duplicatesDialog.seen = count
            }
        }

        function pick(path, on) {
            var c = duplicatesDialog.chosen
            if (on) c[path] = true; else delete c[path]
            duplicatesDialog.chosen = c
            duplicatesDialog.chosenChanged()
        }
        function isPicked(path) { return duplicatesDialog.chosen[path] === true }

        // "Keep one" rather than "select all": the safe default in a duplicate list
        // is always that something survives, so these choose what to DELETE by
        // choosing what to keep first.
        function keepBy(newest) {
            var c = ({})
            for (var g = 0; g < duplicatesDialog.groups.length; g++) {
                var files = duplicatesDialog.groups[g].files
                var keep = 0
                for (var i = 1; i < files.length; i++) {
                    if (newest ? files[i].mtime > files[keep].mtime
                               : files[i].mtime < files[keep].mtime) keep = i
                }
                for (var j = 0; j < files.length; j++)
                    if (j !== keep) c[files[j].path] = true
            }
            duplicatesDialog.chosen = c
        }
        function clearPicks() { duplicatesDialog.chosen = ({}) }

        readonly property int pickedCount: Object.keys(duplicatesDialog.chosen).length
        readonly property int wastedTotal: {
            var t = 0
            for (var i = 0; i < duplicatesDialog.groups.length; i++)
                t += duplicatesDialog.groups[i].wasted
            return t
        }
        readonly property string wastedStr: {
            var n = duplicatesDialog.wastedTotal
            var units = ["B", "KB", "MB", "GB", "TB"]
            var u = 0
            while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
            return (u === 0 ? n.toFixed(0) : n.toFixed(1)) + " " + units[u]
        }

        function trashPicked() {
            var list = Object.keys(duplicatesDialog.chosen)
            if (list.length === 0 || !backend) return
            // Trashed, never deleted — a duplicate finder that is wrong once is a
            // finder that has destroyed the only copy.
            backend.trashFiles(list)
            duplicatesDialog.close()
            refreshAllPanes()
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(window.width - 80, 720)
            height: Math.min(window.height - 60, 560)
            radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 20; spacing: 12

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)
                        Text { anchors.centerIn: parent; text: "content_copy"
                               font.family: iconFont; color: accentInk; font.pixelSize: 18 }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 1
                        Text { text: "Duplicate Files"; font.pixelSize: 16; font.bold: true
                               color: textPrimary }
                        Text {
                            font.pixelSize: 10; color: textMuted
                            Layout.fillWidth: true; elide: Text.ElideMiddle
                            text: duplicatesDialog.root
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: duplicatesDialog.scanning
                    font.pixelSize: 12; color: textSecondary
                    text: "Scanning… " + duplicatesDialog.seen + " files checked"
                }

                Text {
                    Layout.fillWidth: true
                    visible: !duplicatesDialog.scanning && duplicatesDialog.groups.length === 0
                    font.pixelSize: 12; color: textSecondary
                    text: "No duplicates found here."
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    visible: !duplicatesDialog.scanning && duplicatesDialog.groups.length > 0
                    Text {
                        Layout.fillWidth: true
                        font.pixelSize: 11; color: textSecondary
                        text: duplicatesDialog.groups.length + " sets  ·  "
                              + duplicatesDialog.wastedStr + " recoverable"
                    }
                    Repeater {
                        model: [{ t: "Keep newest", v: 1 }, { t: "Keep oldest", v: 0 },
                                { t: "Clear", v: -1 }]
                        delegate: Rectangle {
                            id: qbtn
                            required property var modelData
                            Layout.preferredHeight: 26
                            Layout.preferredWidth: qbtnText.implicitWidth + 18
                            radius: rBase
                            color: qbtnMa.containsMouse ? bgHover : "transparent"
                            border.width: 1; border.color: borderSoft
                            Text {
                                id: qbtnText
                                anchors.centerIn: parent; text: qbtn.modelData.t
                                font.pixelSize: 10; color: textSecondary
                            }
                            MouseArea {
                                id: qbtnMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (qbtn.modelData.v === -1) duplicatesDialog.clearPicks()
                                    else duplicatesDialog.keepBy(qbtn.modelData.v === 1)
                                }
                            }
                        }
                    }
                }

                ScrollView {
                    id: dupScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    visible: !duplicatesDialog.scanning
                    ColumnLayout {
                        width: dupScroll.availableWidth
                        spacing: 8
                        Repeater {
                            model: duplicatesDialog.groups
                            delegate: ColumnLayout {
                                id: grp
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: grp.modelData.count + " copies  ·  "
                                          + grp.modelData.sizeStr + " each"
                                    font.pixelSize: 10; font.bold: true
                                    color: catInk("archive", accentInk)
                                }
                                Repeater {
                                    model: grp.modelData.files
                                    delegate: Rectangle {
                                        id: dupRow
                                        required property var modelData
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 30
                                        radius: rBase
                                        readonly property bool picked: duplicatesDialog.isPicked(dupRow.modelData.path)
                                        color: dupRow.picked
                                            ? Qt.rgba(1, 0.3, 0.3, 0.12)
                                            : (dupMa.containsMouse ? bgHover : "transparent")
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8; anchors.rightMargin: 8
                                            spacing: 8
                                            Rectangle {
                                                width: 15; height: 15; radius: rBase
                                                border.width: 1.5
                                                border.color: dupRow.picked ? dangerInk : borderHard
                                                color: dupRow.picked ? dangerInk : "transparent"
                                                Text {
                                                    anchors.centerIn: parent
                                                    visible: dupRow.picked
                                                    text: "check"; font.family: iconFont
                                                    font.pixelSize: 11; color: "#f2f2f5"
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 0
                                                Text {
                                                    text: dupRow.modelData.name
                                                    font.pixelSize: 11; color: textPrimary
                                                    Layout.fillWidth: true; elide: Text.ElideMiddle
                                                }
                                                Text {
                                                    text: dupRow.modelData.dir
                                                    font.pixelSize: 9; color: textMuted
                                                    Layout.fillWidth: true; elide: Text.ElideMiddle
                                                }
                                            }
                                            Text {
                                                text: dupRow.modelData.mtimeStr
                                                font.pixelSize: 9; color: textMuted
                                            }
                                        }
                                        MouseArea {
                                            id: dupMa
                                            anchors.fill: parent; hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: duplicatesDialog.pick(dupRow.modelData.path,
                                                                             !dupRow.picked)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 80; height: 36; radius: rBase
                        color: dupCloseMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent
                               text: duplicatesDialog.scanning ? "Stop" : "Close"
                               color: textPrimary; font.pixelSize: 12 }
                        MouseArea { id: dupCloseMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: duplicatesDialog.close() }
                    }
                    Rectangle {
                        width: 190; height: 36; radius: rBase
                        visible: duplicatesDialog.groups.length > 0
                        opacity: duplicatesDialog.pickedCount > 0 ? 1.0 : 0.45
                        color: dupTrashMa.containsMouse ? Qt.lighter(dangerInk, 1.1) : dangerInk
                        Text {
                            anchors.centerIn: parent
                            text: "Move " + duplicatesDialog.pickedCount + " to Trash"
                            color: onAccent; font.pixelSize: 12; font.bold: true
                        }
                        MouseArea {
                            id: dupTrashMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: duplicatesDialog.pickedCount > 0
                            onClicked: duplicatesDialog.trashPicked()
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // 14. TAB CONTEXT MENU
    // =========================================================
    //
    // Built from a list rather than hand-laid rows: this menu changes with the
    // tab it was opened on (there is no "close to the right" on the last tab),
    // and a data-driven menu keeps that in one place instead of a `visible:`
    // clause on each of eight Rectangles.

    Rectangle {
        id: tabMenu
        visible: false
        z: 96
        width: 210
        height: tabMenuCol.implicitHeight + 12
        radius: rCard
        color: bgPanel
        border.width: 1
        border.color: isDark ? bgHover : borderHard

        property int target: -1

        readonly property var entries: {
            var i = tabMenu.target
            if (i < 0 || i >= tabs.length) return []
            return [
                { label: "Duplicate Tab", icon: "content_copy", act: "dup" },
                { label: splitView ? "Send to Other Pane" : "Open in Split View",
                  icon: "splitscreen_left", act: "pane" },
                { label: "Move to New Window", icon: "open_in_new", act: "detach",
                  off: tabs.length < 2 },
                { sep: true },
                { label: "Close Tab", icon: "close", act: "close", off: tabs.length < 2 },
                { label: "Close Other Tabs", icon: "close_fullscreen", act: "others",
                  off: tabs.length < 2 },
                { label: "Close Tabs to the Right", icon: "last_page", act: "right",
                  off: i >= tabs.length - 1 }
            ]
        }

        function openFor(idx, px, py) {
            tabMenu.target = idx
            tabMenu.x = Math.max(8, Math.min(px, window.width - tabMenu.width - 8))
            tabMenu.y = Math.max(8, Math.min(py, window.height - tabMenu.height - 8))
            tabMenu.visible = true
        }

        function run(act) {
            var i = tabMenu.target
            tabMenu.visible = false
            if (i < 0) return
            if (act === "dup") duplicateTab(i)
            else if (act === "pane") tabToOtherPane(i)
            else if (act === "detach") detachTab(i)
            else if (act === "close") closeTab(i)
            else if (act === "others") closeOtherTabs(i)
            else if (act === "right") closeTabsToRight(i)
        }

        Column {
            id: tabMenuCol
            anchors.centerIn: parent
            width: parent.width - 12
            spacing: 2

            Repeater {
                model: tabMenu.entries
                delegate: Item {
                    id: tmRow
                    required property var modelData
                    width: tabMenuCol.width
                    height: tmRow.modelData.sep ? 7 : 28

                    Rectangle {
                        visible: !!tmRow.modelData.sep
                        anchors.centerIn: parent
                        width: parent.width - 8
                        height: 1
                        color: borderSoft
                    }

                    Rectangle {
                        visible: !tmRow.modelData.sep
                        anchors.fill: parent
                        radius: rBase
                        opacity: tmRow.modelData.off ? 0.4 : 1.0
                        color: (tmMa.containsMouse && !tmRow.modelData.off) ? bgHover : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: tmRow.modelData.icon || ""
                                font.family: iconFont
                                font.pixelSize: 15
                                color: textSecondary
                            }
                            Text {
                                text: tmRow.modelData.label
                                color: textPrimary
                                font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea {
                            id: tmMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !tmRow.modelData.off
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tabMenu.run(tmRow.modelData.act)
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // FILE TRANSFERS — the conflict question and the progress strip
    // =========================================================
    //
    // Copying and moving happen on a worker thread now, and the worker STOPS AND
    // WAITS when a destination already exists. These two pieces are the other half
    // of that handshake: without something on screen answering `ops.conflict`,
    // a paste over an existing file would sit there for ever.
    //
    // The old behaviour was to overwrite without asking, which is why this exists.

    Rectangle {
        id: conflictDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.78)
        visible: false
        z: 130

        property var info: ({})
        property bool applyAll: false

        // Nothing behind the dialog is clickable while a transfer is parked on it.
        MouseArea { anchors.fill: parent; onClicked: {} }

        function ask(payload) {
            info = payload
            applyAll = false
            visible = true
            forceActiveFocus()
        }

        function answer(choice) {
            visible = false
            if (ops) ops.resolve(conflictDialog.info.opId, choice, conflictDialog.applyAll)
            info = ({})
        }

        // Escape means cancel the whole transfer, which is the safe reading:
        // it is the only answer that changes nothing on disk.
        Keys.onEscapePressed: answer("cancel")

        Connections {
            target: ops
            enabled: ops !== null
            function onConflict(payload) { conflictDialog.ask(payload) }
            // The buttons below hide the dialog on their way out, but they are not
            // the only way an answer can arrive — cancelling from the transfer
            // strip while a conflict is parked resolves it from the other side.
            // Without these the question would stay on screen with nothing left
            // behind it to answer.
            function onResolved(opId) {
                if (conflictDialog.info.opId === opId) conflictDialog.visible = false
            }
            function onFinished(opId, info) {
                if (conflictDialog.info.opId === opId) {
                    conflictDialog.visible = false
                    conflictDialog.info = ({})
                }
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: 560
            height: bodyCol.implicitHeight + 40
            radius: rCard
            color: bgPanel
            border.width: 1; border.color: isDark ? borderHard : borderHard

            ColumnLayout {
                id: bodyCol
                anchors.fill: parent; anchors.margins: 20; spacing: 16

                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 32; height: 32; radius: rBase
                        color: Qt.rgba(dangerInk.r, dangerInk.g, dangerInk.b, 0.15)
                        Text {
                            anchors.centerIn: parent; text: "file_copy"
                            font.family: iconFont; font.pixelSize: 20; color: dangerInk
                        }
                    }
                    ColumnLayout {
                        spacing: 2
                        Text {
                            text: "\"" + (conflictDialog.info.name || "") + "\" already exists here"
                            font.pixelSize: 15; font.bold: true; color: textPrimary
                            elide: Text.ElideMiddle; Layout.maximumWidth: 460
                        }
                        Text {
                            text: conflictDialog.info.dstIsDir
                                  ? "Replacing merges the two folders."
                                  : "Replacing moves the existing file to the trash, so it can still be recovered."
                            font.pixelSize: 11; color: textSecondary
                            wrapMode: Text.WordWrap; Layout.maximumWidth: 460
                        }
                    }
                }

                // The two files, side by side. Which one is newer is the thing
                // people actually decide on, so it is called out rather than left
                // to be worked out from two timestamps.
                RowLayout {
                    Layout.fillWidth: true; spacing: 12

                    Repeater {
                        model: [
                            { t: "Replace with",  d: true  },
                            { t: "Existing file", d: false }
                        ]
                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 74
                            radius: rBase
                            color: isDark ? bgSunken : bgSunken
                            border.width: 1
                            border.color: {
                                var newer = conflictDialog.info.srcNewer === true
                                var isNewest = modelData.d ? newer : !newer
                                return isNewest ? accentColor : borderSoft
                            }

                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 10; spacing: 3
                                RowLayout {
                                    spacing: 6
                                    Text {
                                        text: modelData.t
                                        font.pixelSize: 10; font.bold: true
                                        color: textSecondary
                                    }
                                    Rectangle {
                                        visible: modelData.d ? (conflictDialog.info.srcNewer === true)
                                                             : (conflictDialog.info.srcNewer === false)
                                        radius: rBase
                                        implicitWidth: newerTxt.implicitWidth + 8
                                        implicitHeight: 14
                                        color: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.2)
                                        Text {
                                            id: newerTxt
                                            anchors.centerIn: parent; text: "NEWER"
                                            font.pixelSize: 8; font.bold: true; color: accentInk
                                        }
                                    }
                                }
                                Text {
                                    text: modelData.d ? (conflictDialog.info.srcSizeStr || "")
                                                      : (conflictDialog.info.dstSizeStr || "")
                                    font.pixelSize: 13; color: textPrimary
                                }
                                Text {
                                    text: modelData.d ? (conflictDialog.info.srcWhen || "")
                                                      : (conflictDialog.info.dstWhen || "")
                                    font.pixelSize: 10; color: textMuted
                                }
                            }
                        }
                    }
                }

                // Applying to all is what makes this bearable for a folder of
                // forty colliding files, so it sits next to the buttons rather
                // than hidden behind a disclosure.
                RowLayout {
                    spacing: 8
                    Rectangle {
                        width: 16; height: 16; radius: rBase
                        color: conflictDialog.applyAll ? accentColor : "transparent"
                        border.width: 1.5
                        border.color: conflictDialog.applyAll ? accentColor : borderHard
                        Text {
                            anchors.centerIn: parent; visible: conflictDialog.applyAll
                            text: "check"; font.family: iconFont; font.pixelSize: 12
                            color: onAccent
                        }
                    }
                    Text {
                        text: "Do this for everything else in this transfer"
                        font.pixelSize: 11; color: textSecondary
                    }
                    // A handler rather than a MouseArea: this row is a RowLayout, and
                    // an item that anchors to a layout it is a child of is undefined
                    // behaviour -- Qt says so on every construction. Handlers are not
                    // laid out, so it covers the row without being a cell in it.
                    TapHandler {
                        onTapped: conflictDialog.applyAll = !conflictDialog.applyAll
                    }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8

                    Rectangle {
                        implicitWidth: 76; height: 36; radius: rBase
                        color: cxCancelMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea {
                            id: cxCancelMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: conflictDialog.answer("cancel")
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        implicitWidth: 68; height: 36; radius: rBase
                        color: cxSkipMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Skip"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea {
                            id: cxSkipMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: conflictDialog.answer("skip")
                        }
                    }

                    Rectangle {
                        implicitWidth: 96; height: 36; radius: rBase
                        color: cxBothMa.containsMouse ? bgHover : (isDark ? bgCard : bgCard)
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Keep both"; color: textPrimary; font.pixelSize: 12 }
                        MouseArea {
                            id: cxBothMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: conflictDialog.answer("keepboth")
                        }
                    }

                    Rectangle {
                        implicitWidth: 96; height: 36; radius: rBase
                        color: cxRepMa.containsMouse ? Qt.lighter(accentColor, 1.1) : accentColor
                        Text {
                            anchors.centerIn: parent
                            text: conflictDialog.info.dstIsDir ? "Merge" : "Replace"
                            color: onAccent; font.pixelSize: 12; font.bold: true
                        }
                        MouseArea {
                            id: cxRepMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: conflictDialog.answer("replace")
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // THE OPERATIONS CENTRE
    // =========================================================
    //
    // Every long job in this window — copying, moving, trashing, deleting,
    // zipping, extracting, sharing to a phone — runs on one engine and reports
    // itself the same way, so one panel shows all of them and each row has its
    // own cancel. Before this, only copy and move said anything at all; zipping a
    // folder or deleting a large tree simply froze the window.
    //
    // It is a POPOVER off a toolbar button rather than a modal, because a long
    // copy must not stop you carrying on browsing — which is the entire reason
    // the work moved off the UI thread.
    Item {
        id: opsCentre
        anchors.fill: parent
        z: 118

        // opId -> the last progress payload we saw for it.
        property var jobs: ({})
        property var announced: ({})     // jobs the popover has already opened for
        property int running: 0
        property bool open: false
        property real overallFraction: 0

        function recompute() {
            var n = 0, sum = 0
            for (var k in jobs) { n++; sum += (jobs[k].percent || 0) }
            running = n
            overallFraction = n > 0 ? (sum / n) / 100 : 0
            if (n === 0) open = false
            // Only when the SET of jobs changes. Reassigning an equal list rebuilt
            // every delegate several times a second for no reason.
            var keys = Object.keys(jobs)
            if (keys.join("\u0000") !== opsRepeater.model.join("\u0000"))
                opsRepeater.model = keys
        }

        Connections {
            target: ops
            enabled: ops !== null
            function onProgress(opId, info) {
                var j = opsCentre.jobs
                // A COPY YOU HAVE TO GO LOOKING FOR IS NOT PROGRESS. This used to
                // sit closed behind a toolbar button, so unless you thought to
                // click it, a long operation was a silent one. It opens itself for
                // work it has not shown before -- and only for that, so dismissing
                // it does not have it spring back on the next tick.
                if (!(opId in j) && !(opId in opsCentre.announced)) {
                    var seen = Object.assign({}, opsCentre.announced)
                    seen[opId] = true
                    opsCentre.announced = seen
                    opsCentre.open = true
                }
                // A NEW OBJECT, NOT THE SAME ONE BACK AGAIN.
                // Assigning the identical reference to a var property is not a
                // change, so QML sent no notification and `job` below never
                // re-evaluated: the popover kept showing whatever the FIRST frame
                // said and never moved again. It only looked like it worked
                // because a second operation starting changed the key list, which
                // rebuilt the delegates and let them re-read.
                var next = Object.assign({}, j)
                next[opId] = info
                opsCentre.jobs = next
                opsCentre.recompute()
            }
            function onFinished(opId, info) {
                var seen = Object.assign({}, opsCentre.announced)
                delete seen[opId]
                opsCentre.announced = seen
                var next = Object.assign({}, opsCentre.jobs)
                delete next[opId]
                opsCentre.jobs = next
                opsCentre.recompute()
                if (info && info.summary) toast.show(info.summary, !!(info.failed && info.failed.length))
            }
        }

        // Clicking away closes it, the way a popover should.
        MouseArea {
            anchors.fill: parent
            visible: opsCentre.open
            onClicked: opsCentre.open = false
        }

        Rectangle {
            visible: opsCentre.open && opsCentre.running > 0
            width: 400
            height: Math.min(320, opsCol.implicitHeight + 20)
            anchors { right: parent.right; top: parent.top; topMargin: 96; rightMargin: 16 }
            color: bgPanel
            radius: rCard
            border.width: 1
            border.color: borderHard

            // Swallow clicks so they do not reach the dismiss layer behind.
            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
                id: opsCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "FILE OPERATIONS"
                        font.family: monoFont; font.pixelSize: tLabel
                        font.letterSpacing: 1.0
                        color: textMuted
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        visible: opsCentre.running > 1
                        implicitWidth: stopAllT.implicitWidth + 12
                        height: 20; radius: rBase
                        color: stopAllMa.containsMouse ? dangerWash : "transparent"
                        border.width: 1; border.color: borderSoft
                        Text {
                            id: stopAllT
                            anchors.centerIn: parent; text: "Stop all"
                            font.pixelSize: 10
                            color: stopAllMa.containsMouse ? dangerInk : textSecondary
                        }
                        MouseArea {
                            id: stopAllMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (ops) ops.cancelAll()
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                Repeater {
                    id: opsRepeater
                    model: []
                    delegate: ColumnLayout {
                        required property string modelData
                        readonly property var job: opsCentre.jobs[modelData] || ({})
                        Layout.fillWidth: true
                        spacing: 3

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                text: {
                                    var k = job.kind
                                    if (k === "move") return "drive_file_move"
                                    if (k === "trash") return "delete"
                                    if (k === "delete") return "delete_forever"
                                    if (k === "compress") return "folder_zip"
                                    if (k === "extract") return "unarchive"
                                    if (k === "share") return "send_to_mobile"
                                    return "file_copy"
                                }
                                font.family: iconFont; font.pixelSize: 16
                                color: job.kind === "delete" ? dangerInk : accentInk
                            }
                            Text {
                                text: (job.verb || "Working")
                                      + (job.totalFiles > 1
                                         ? " " + (job.doneFiles || 0) + "/" + job.totalFiles
                                         : "")
                                font.pixelSize: tDense; color: textPrimary
                            }
                            Text {
                                Layout.fillWidth: true
                                text: job.current || ""
                                elide: Text.ElideMiddle
                                font.pixelSize: 11; color: textMuted
                            }
                            Text {
                                text: job.phase === "measuring" ? "\u2014" : (job.percent || 0) + "%"
                                font.family: monoFont; font.pixelSize: tData
                                font.features: ({ "tnum": 1 })
                                color: textSecondary
                            }
                            Rectangle {
                                width: 18; height: 18; radius: rBase
                                color: xMa.containsMouse ? dangerWash : "transparent"
                                Text {
                                    anchors.centerIn: parent; text: "close"
                                    font.family: iconFont; font.pixelSize: 12
                                    color: xMa.containsMouse ? dangerInk : textMuted
                                }
                                MouseArea {
                                    id: xMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (ops) ops.cancel(modelData)
                                }
                            }
                        }

                        Rectangle {
                            id: opBar
                            Layout.fillWidth: true
                            height: 4
                            color: bgSunken
                            clip: true
                            readonly property bool waiting: job.phase === "measuring"
                            onWaitingChanged: if (!waiting) opBarFill.x = 0
                            Rectangle {
                                id: opBarFill
                                // While the tree is still being counted there is no
                                // fraction to draw, so a sliver travels instead of a
                                // bar sitting at zero looking stuck.
                                width: opBar.waiting ? opBar.width * 0.3
                                                     : opBar.width * Math.max(0, Math.min(1, (job.percent || 0) / 100))
                                height: parent.height
                                color: job.kind === "delete" ? dangerInk : accentColor
                                Behavior on width { NumberAnimation { duration: mFast } }
                                SequentialAnimation on x {
                                    running: opBar.waiting
                                    loops: Animation.Infinite
                                    NumberAnimation { from: -opBar.width * 0.3; to: opBar.width; duration: 1100 }
                                }
                            }
                        }

                        // "1.2 GB of 4.5 GB — 45 seconds left (32.1 MB/s)", or the
                        // plain counts until the rate has settled enough to be worth
                        // quoting. See ETA_MIN_ELAPSED in sea-fm.py.
                        Text {
                            Layout.fillWidth: true
                            text: {
                                if (job.phase === "measuring")
                                    return job.totalFiles > 0
                                        ? "Preparing\u2026  " + job.totalFiles + " files so far"
                                        : "Preparing\u2026"
                                if (!job.totalFiles && !job.totalBytes) return "Finishing\u2026"
                                var amount = job.totalBytes > 0
                                    ? (job.doneStr || "") + " of " + (job.totalStr || "")
                                    : (job.doneFiles || 0) + " of " + (job.totalFiles || 0) + " files"
                                if (job.etaStr) {
                                    amount += "  \u2014  " + job.etaStr + " left"
                                    if (job.rateStr) amount += "  (" + job.rateStr + ")"
                                }
                                return amount
                            }
                            elide: Text.ElideRight
                            font.family: monoFont; font.pixelSize: 10
                            font.features: ({ "tnum": 1 })
                            color: textMuted
                        }
                    }
                }
            }
        }
    }

    // A finished operation says so once, briefly, at the bottom of the window.
    // The status bar already carries the same words, so this is a glance rather
    // than something to read — and it never sits on top of the files.
    Rectangle {
        id: toast
        z: 119
        property bool bad: false
        visible: opacity > 0
        opacity: 0
        width: Math.min(520, toastT.implicitWidth + 28)
        height: 30
        radius: rBase
        color: bad ? dangerWash : bgCard
        border.width: 1
        border.color: bad ? dangerInk : borderHard
        anchors { bottom: parent.bottom; bottomMargin: 44; horizontalCenter: parent.horizontalCenter }

        function show(msg, isBad) { bad = !!isBad; toastT.text = msg; opacity = 1; toastTimer.restart() }

        Text {
            id: toastT
            anchors.centerIn: parent
            font.pixelSize: tDense
            color: toast.bad ? dangerInk : textPrimary
        }
        Timer { id: toastTimer; interval: 3200; onTriggered: toast.opacity = 0 }
        Behavior on opacity { NumberAnimation { duration: mBase } }
    }

    // =========================================================
    // SHARE
    // =========================================================
    //
    // Devices come from sea-kdeconnect.py, which this shell already had — there
    // is no second implementation of KDE Connect here, just a list and a send.
    // Only PAIRED, REACHABLE devices carrying the share plugin are offered,
    // because anything else gives you a menu entry that silently does nothing.
    //
    // Folders are packed into a zip before they go, since the share plugin takes
    // files and nothing else. That happens on the operations engine, so a large
    // folder shows its packing progress in the same panel as everything else.
    Rectangle {
        id: shareDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        visible: false
        z: 132

        property var paths: []

        MouseArea { anchors.fill: parent; onClicked: shareDialog.visible = false }

        function openFor(picked) {
            if (!picked || picked.length === 0) return
            paths = picked
            visible = true
            if (backend) backend.refreshShareDevices()
        }

        Keys.onEscapePressed: shareDialog.visible = false

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: shareCol.implicitHeight + 32
            color: bgPanel
            radius: rCard
            border.width: 1
            border.color: borderHard
            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
                id: shareCol
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    spacing: 10
                    Text {
                        text: "send_to_mobile"; font.family: iconFont
                        font.pixelSize: 20; color: accentInk
                    }
                    ColumnLayout {
                        spacing: 1
                        Text {
                            text: "Send to device"
                            font.pixelSize: tPanel; font.bold: true; color: textPrimary
                        }
                        Text {
                            text: shareDialog.paths.length === 1
                                  ? shareDialog.paths[0].split("/").pop()
                                  : shareDialog.paths.length + " items"
                            font.pixelSize: 11; color: textSecondary
                            elide: Text.ElideMiddle
                            Layout.maximumWidth: 320
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                Text {
                    visible: !backend || backend.shareDevices.length === 0
                    Layout.fillWidth: true
                    text: "No paired device is reachable.\nOpen KDE Connect and make sure the device is on the same network."
                    wrapMode: Text.WordWrap
                    font.pixelSize: tDense; color: textMuted
                }

                Repeater {
                    model: backend ? backend.shareDevices : []
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        height: 44
                        radius: rBase
                        color: devMa.containsMouse ? bgHover : bgCard
                        border.width: 1
                        border.color: devMa.containsMouse ? accentColor : borderSoft

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10
                            Text {
                                text: modelData.type === "phone" ? "smartphone"
                                      : modelData.type === "tablet" ? "tablet"
                                      : "computer"
                                font.family: iconFont; font.pixelSize: 19
                                color: accentInk
                            }
                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true
                                Text {
                                    text: modelData.name
                                    font.pixelSize: tDense; color: textPrimary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: (modelData.charge >= 0 ? modelData.charge + "%  " : "")
                                          + (modelData.network || "")
                                    font.family: monoFont; font.pixelSize: 10
                                    font.features: ({ "tnum": 1 })
                                    color: textMuted
                                }
                            }
                            Text {
                                text: "chevron_right"; font.family: iconFont
                                font.pixelSize: 16; color: textMuted
                            }
                        }

                        MouseArea {
                            id: devMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend) backend.shareWith(modelData.id, modelData.name,
                                                               shareDialog.paths)
                                shareDialog.visible = false
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        implicitWidth: 96; height: 32; radius: rBase
                        color: copyPathMa.containsMouse ? bgHover : bgCard
                        border.width: 1; border.color: borderSoft
                        Text {
                            anchors.centerIn: parent; text: "Copy path"
                            font.pixelSize: 11; color: textPrimary
                        }
                        MouseArea {
                            id: copyPathMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend && shareDialog.paths.length > 0)
                                    backend.copyPath(shareDialog.paths[0])
                                shareDialog.visible = false
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitWidth: 76; height: 32; radius: rBase
                        color: shClose.containsMouse ? bgHover : bgCard
                        border.width: 1; border.color: borderSoft
                        Text {
                            anchors.centerIn: parent; text: "Cancel"
                            font.pixelSize: 11; color: textPrimary
                        }
                        MouseArea {
                            id: shClose; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: shareDialog.visible = false
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // PREFERENCES
    // =========================================================
    //
    // Two kinds of setting, kept visibly apart because they have different reach.
    // The Appearance group writes ~/.config/sea-shell/appearance.json, so it moves
    // the bar, the dock and the dashboard with it — the panel says so rather than
    // letting that be a surprise. Everything below it is this window only.
    Rectangle {
        id: prefsDialog
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        visible: false
        z: 134

        property int tab: 0

        MouseArea { anchors.fill: parent; onClicked: prefsDialog.visible = false }
        Keys.onEscapePressed: prefsDialog.visible = false

        function openDialog() { visible = true; forceActiveFocus() }

        component PrefRow: RowLayout {
            property string label: ""
            property string hint: ""
            Layout.fillWidth: true
            spacing: 12
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                Text { text: parent.parent.label; font.pixelSize: tDense; color: textPrimary }
                Text {
                    text: parent.parent.hint; visible: text !== ""
                    font.pixelSize: 10; color: textMuted
                    wrapMode: Text.WordWrap; Layout.fillWidth: true
                }
            }
        }

        component PrefSwitch: Rectangle {
            id: sw
            property bool on: false
            signal toggled(bool value)
            implicitWidth: 40; implicitHeight: 22
            radius: rSmall
            color: on ? accentColor : bgSunken
            border.width: 1
            border.color: on ? accentColor : borderHard
            Rectangle {
                width: 16; height: 16; radius: Math.max(2, rSmall - 1)
                y: 3
                x: sw.on ? sw.width - width - 3 : 3
                color: sw.on ? onAccent : textMuted
                Behavior on x { NumberAnimation { duration: mFast; easing.type: Easing.OutCubic } }
            }
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: sw.toggled(!sw.on)
            }
        }

        // ADDRESSED BY id, NOT BY WALKING parent. A Repeater parents its delegates
        // to the Repeater's OWN parent — this Row — so inside a delegate `parent`
        // is already the PrefChoice and `parent.parent` was the layout above it.
        // Reading `.value` off that gave undefined, so nothing ever drew as
        // selected, and calling `.picked()` on it did nothing at all: every
        // segmented control in this panel looked blank and was dead to clicks.
        component PrefChoice: Row {
            id: choice
            property var options: []
            property string value: ""
            signal picked(string v)
            spacing: 4
            Repeater {
                model: choice.options
                delegate: Rectangle {
                    id: seg
                    required property var modelData
                    readonly property bool sel: modelData.v === choice.value
                    height: 28
                    width: Math.max(62, cLabel.implicitWidth + 22)
                    radius: rSmall
                    color: seg.sel ? accentColor : (cMa.containsMouse ? bgHover : bgCard)
                    border.width: 1
                    border.color: seg.sel ? accentColor : borderHard
                    Text {
                        id: cLabel
                        anchors.centerIn: parent
                        text: modelData.t
                        font.pixelSize: 11
                        font.bold: seg.sel
                        color: seg.sel ? onAccent : textSecondary
                    }
                    MouseArea {
                        id: cMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: choice.picked(modelData.v)
                    }
                }
            }
        }

        // The stock Slider and ComboBox come from QtQuick.Controls' default style,
        // which knows nothing about this window's palette — the combo rendered as a
        // black bar and the slider as a bare line. Both are given their own look.
        component PrefSlider: Slider {
            id: sl
            implicitHeight: 24
            background: Rectangle {
                x: sl.leftPadding
                y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: sl.availableWidth
                height: 4
                radius: 2
                color: bgSunken
                border.width: 1
                border.color: borderSoft
                Rectangle {
                    width: sl.visualPosition * parent.width
                    height: parent.height
                    radius: 2
                    color: accentColor
                }
            }
            handle: Rectangle {
                x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
                y: sl.topPadding + sl.availableHeight / 2 - height / 2
                width: 16; height: 16
                radius: rSmall
                color: sl.pressed ? accentColor : bgCard
                border.width: 2
                border.color: accentColor
            }
        }

        component PrefCombo: ComboBox {
            id: cb
            implicitHeight: 30
            background: Rectangle {
                color: bgCard
                radius: rSmall
                border.width: 1
                border.color: cb.activeFocus || cb.hovered ? accentColor : borderHard
            }
            contentItem: Text {
                leftPadding: 10
                rightPadding: 26
                text: cb.displayText
                font.pixelSize: 12
                color: textPrimary
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            indicator: Text {
                x: cb.width - width - 8
                y: cb.topPadding + (cb.availableHeight - height) / 2
                text: "expand_more"
                font.family: iconFont
                font.pixelSize: 16
                color: textSecondary
            }
            popup: Popup {
                y: cb.height + 2
                width: cb.width
                implicitHeight: Math.min(260, contentItem.implicitHeight + 8)
                padding: 4
                background: Rectangle {
                    color: bgPanel
                    radius: rSmall
                    border.width: 1
                    border.color: borderHard
                }
                contentItem: ListView {
                    clip: true
                    implicitHeight: contentHeight
                    model: cb.popup.visible ? cb.delegateModel : null
                    ScrollIndicator.vertical: ScrollIndicator { }
                }
            }
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                width: cb.width - 8
                height: 28
                background: Rectangle {
                    radius: rSmall
                    color: index === cb.currentIndex ? accentWash
                         : (hovered ? bgHover : "transparent")
                }
                contentItem: Text {
                    leftPadding: 8
                    text: modelData
                    font.pixelSize: 12
                    color: index === cb.currentIndex ? accentInk : textPrimary
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: 560
            // Tall enough for the longest tab where the window allows, capped so
            // it never runs off a short screen — the Flickable inside takes up
            // any slack.
            height: Math.min(prefsDialog.height - 60, 640)
            color: bgPanel
            radius: rCard
            border.width: 1
            border.color: borderHard
            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 14

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text { text: "tune"; font.family: iconFont; font.pixelSize: 20; color: accentInk }
                    Text {
                        text: "Preferences"; font.pixelSize: tPanel
                        font.bold: true; color: textPrimary; Layout.fillWidth: true
                    }
                    Rectangle {
                        width: 26; height: 26; radius: rSmall
                        color: prefXMa.containsMouse ? bgHover : "transparent"
                        Text {
                            anchors.centerIn: parent; text: "close"
                            font.family: iconFont; font.pixelSize: 16; color: textSecondary
                        }
                        MouseArea {
                            id: prefXMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: prefsDialog.visible = false
                        }
                    }
                }

                Row {
                    spacing: 0
                    Repeater {
                        model: [ "Appearance", "View", "Behaviour", "Storage" ]
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool sel: prefsDialog.tab === index
                            width: 110; height: 30
                            radius: rSmall
                            color: sel ? accentWash : (ptMa.containsMouse ? bgHover : "transparent")
                            border.width: 1
                            border.color: sel ? accentColor : "transparent"
                            Text {
                                anchors.centerIn: parent; text: modelData
                                font.pixelSize: 12
                                color: parent.sel ? accentInk : textSecondary
                            }
                            MouseArea {
                                id: ptMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: prefsDialog.tab = index
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                // SCROLLS. The dialog was a fixed 520px box with the tab bodies stacked
                // inside it, so the Appearance tab — the tallest — pushed Reset and Done
                // straight off the bottom edge where nothing could reach them. The bodies
                // now live in a flickable that takes whatever height is left, and the
                // footer keeps its place no matter which tab is open.
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: tabHost.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                
                    Column {
                        id: tabHost
                        width: parent.width
                
                    // ---------- APPEARANCE ----------
                    ColumnLayout {
                        visible: prefsDialog.tab === 0
                        width: tabHost.width
                        spacing: 14

                        readonly property bool own: prefs && prefs.all.themeSource === "own"

                        PrefRow {
                            label: "Where these settings apply"
                            hint: parent.own
                                  ? "This window only. Nothing outside the file manager changes."
                                  : "The whole shell — the bar, dock and dashboard follow along."
                            PrefChoice {
                                options: [ { t: "Just Files", v: "own" },
                                           { t: "Whole shell", v: "shell" } ]
                                value: prefs ? prefs.all.themeSource : "shell"
                                onPicked: function(v) { if (backend) backend.setThemeScope(v) }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                        PrefRow {
                            label: "Colour mode"
                            PrefChoice {
                                options: [ { t: "Dark", v: "dark" }, { t: "Light", v: "light" } ]
                                value: isDark ? "dark" : "light"
                                onPicked: function(v) {
                                    if (parent.parent.own) { if (prefs) prefs.set("ownMode", v) }
                                    else if (backend) backend.setAppearance("mode", v)
                                }
                            }
                        }

                        PrefRow {
                            label: "Roundness"
                            hint: "Currently " + Math.round(radiusCfg) + "."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            PrefSlider {
                                id: roundSlider
                                Layout.fillWidth: true
                                from: 0; to: 30; stepSize: 1
                                value: radiusCfg
                                onPressedChanged: {
                                    if (pressed) return
                                    var v = Math.round(value)
                                    if (prefs && prefs.all.themeSource === "own") prefs.set("ownRadius", v)
                                    else if (backend) backend.setAppearance("radius", v)
                                }
                            }
                            Text {
                                text: Math.round(roundSlider.value)
                                font.family: monoFont; font.pixelSize: tData
                                font.features: ({ "tnum": 1 })
                                color: textSecondary
                            }
                        }

                        PrefRow { label: "Accent colour" }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 7
                            Repeater {
                                model: [ "#63c7dd", "#7aa2f7", "#9ece6a", "#e0af68",
                                         "#f7768e", "#bb9af7", "#debfc0", "#8a8a99" ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 26; height: 26; radius: rSmall
                                    color: modelData
                                    border.width: 2
                                    border.color: Qt.colorEqual(accentColor, modelData)
                                                  ? textPrimary : "transparent"
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (prefs && prefs.all.themeSource === "own") {
                                                prefs.set("ownAccent", "" + modelData)
                                            } else if (backend) {
                                                backend.setAppearance("matugen", false)
                                                backend.setAppearance("accent", "" + modelData)
                                            }
                                        }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                visible: !parent.parent.own
                                implicitWidth: wpT.implicitWidth + 16; height: 26
                                radius: rSmall
                                color: wpMa.containsMouse ? bgHover : bgCard
                                border.width: 1; border.color: borderSoft
                                Text {
                                    id: wpT; anchors.centerIn: parent
                                    text: "From wallpaper"; font.pixelSize: 11; color: textPrimary
                                }
                                MouseArea {
                                    id: wpMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (backend) backend.setAppearance("matugen", true)
                                }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                        PrefRow {
                            label: "Use the desktop's file icons"
                            hint: "An icon theme knows a Python file from a log. Off falls back to the built-in glyphs."
                            PrefSwitch {
                                on: prefs ? prefs.all.useThemeIcons : true
                                onToggled: function(v) { if (prefs) prefs.set("useThemeIcons", v) }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: prefs ? prefs.all.useThemeIcons : true
                            spacing: 8
                            Text { text: "Icon theme"; font.pixelSize: tDense; color: textPrimary }
                            PrefCombo {
                                id: iconThemeBox
                                Layout.fillWidth: true
                                implicitHeight: 28
                                model: {
                                    var l = backend ? backend.iconThemes() : []
                                    return ["(desktop default)"].concat(l)
                                }
                                currentIndex: {
                                    var want = prefs ? prefs.all.iconTheme : ""
                                    if (!want) return 0
                                    var i = model.indexOf(want)
                                    return i >= 0 ? i : 0
                                }
                                onActivated: function(i) {
                                    if (prefs) prefs.set("iconTheme", i === 0 ? "" : model[i])
                                }
                            }
                        }

                        // What the choice actually looks like, rather than a theme
                        // name and a leap of faith. Re-rendered whenever the theme or
                        // the accent changes, so the folder tint is visible here too.
                        Rectangle {
                            Layout.fillWidth: true
                            visible: prefs ? prefs.all.useThemeIcons : true
                            implicitHeight: 68
                            color: bgSunken
                            radius: rSmall
                            border.width: 1
                            border.color: borderSoft

                            Row {
                                anchors.centerIn: parent
                                spacing: 14
                                Repeater {
                                    model: [
                                        { i: "folder",          l: "folder" },
                                        { i: "text-x-python",   l: ".py" },
                                        { i: "application-pdf", l: ".pdf" },
                                        { i: "image-png",       l: ".png" },
                                        { i: "application-zip", l: ".zip" },
                                        { i: "video-mp4",       l: ".mp4" }
                                    ]
                                    delegate: Column {
                                        required property var modelData
                                        spacing: 3
                                        Image {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            // The folder sample follows the accent
                                            // tint, exactly as the grid will.
                                            source: "image://fileicon/"
                                                    + (modelData.i === "folder" && backend
                                                       && backend.folderTint()
                                                       ? "folder-" + backend.folderTint()
                                                       : modelData.i)
                                                    + "?g=" + iconGen + accentColor
                                                    + iconThemeBox.currentIndex
                                            sourceSize.width: 32; sourceSize.height: 32
                                            width: 32; height: 32
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true; asynchronous: true
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: modelData.l
                                            font.family: monoFont; font.pixelSize: 9
                                            color: textMuted
                                        }
                                    }
                                }
                            }
                        }

                        PrefRow {
                            label: "Tint folders to the accent"
                            hint: {
                                if (!backend) return ""
                                var n = backend.folderTintCount()
                                if (n === 0) return "This theme has only one folder colour."
                                var t = backend.folderTint()
                                return n + " colours available" + (t ? " — using folder-" + t : "")
                            }
                            PrefSwitch {
                                on: prefs ? prefs.all.tintFolders : true
                                onToggled: function(v) { if (prefs) prefs.set("tintFolders", v) }
                            }
                        }
                    }

                    // ---------- VIEW ----------
                    ColumnLayout {
                        visible: prefsDialog.tab === 1
                        width: tabHost.width
                        spacing: 16

                        PrefRow {
                            label: "Open new windows in"
                            PrefChoice {
                                options: [ { t: "Icons", v: "grid" }, { t: "List", v: "list" },
                                           { t: "Compact", v: "compact" } ]
                                value: prefs ? prefs.all.defaultView : "grid"
                                onPicked: function(v) { if (prefs) prefs.set("defaultView", v) }
                            }
                        }
                        PrefRow {
                            label: "Show hidden files"
                            hint: "Also toggled any time with Ctrl+H."
                            PrefSwitch {
                                on: prefs ? prefs.all.showHidden : false
                                onToggled: function(v) {
                                    if (prefs) prefs.set("showHidden", v)
                                    if (backend) backend.setShowHidden(v)
                                }
                            }
                        }
                        PrefRow {
                            label: "Show the inspector when a window opens"
                            PrefSwitch {
                                on: prefs ? prefs.all.inspectorOnOpen : false
                                onToggled: function(v) { if (prefs) prefs.set("inspectorOnOpen", v) }
                            }
                        }
                        PrefRow {
                            label: "Remember view per folder"
                            hint: "A photo folder keeps big icons, a source tree keeps the list."
                            PrefSwitch {
                                on: prefs ? prefs.all.rememberPerFolder : true
                                onToggled: function(v) { if (prefs) prefs.set("rememberPerFolder", v) }
                            }
                        }
                    }

                    // ---------- BEHAVIOUR ----------
                    ColumnLayout {
                        visible: prefsDialog.tab === 2
                        width: tabHost.width
                        spacing: 16

                        PrefRow {
                            label: "Single click opens files"
                            hint: "Off means a single click selects and a double click opens."
                            PrefSwitch {
                                on: prefs ? prefs.all.singleClickOpen : false
                                onToggled: function(v) { if (prefs) prefs.set("singleClickOpen", v) }
                            }
                        }
                        PrefRow {
                            label: "Ask before moving to trash"
                            hint: "Trashing is already reversible with Ctrl+Z, so this is off by default."
                            PrefSwitch {
                                on: prefs ? prefs.all.confirmTrash : false
                                onToggled: function(v) { if (prefs) prefs.set("confirmTrash", v) }
                            }
                        }
                    }

                    // ---------- STORAGE ----------
                    ColumnLayout {
                        visible: prefsDialog.tab === 3
                        width: tabHost.width
                        spacing: 16

                        PrefRow {
                            label: "Preview cache limit"
                            hint: "Rendered PDF pages and video thumbnails. The oldest are dropped past this."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            PrefSlider {
                                id: cacheSlider
                                Layout.fillWidth: true
                                from: 64; to: 4096; stepSize: 64
                                value: prefs ? prefs.all.cacheBudgetMb : 512
                                onPressedChanged: {
                                    if (!pressed && prefs) prefs.set("cacheBudgetMb", Math.round(value))
                                }
                            }
                            Text {
                                text: Math.round(cacheSlider.value) + " MB"
                                font.family: monoFont; font.pixelSize: tData
                                font.features: ({ "tnum": 1 })
                                color: textSecondary
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Text {
                                id: cacheNow
                                text: "Currently using " + (backend ? backend.cacheSize() : "—")
                                font.pixelSize: 11; color: textMuted
                                Layout.fillWidth: true
                            }
                            Rectangle {
                                implicitWidth: clrT.implicitWidth + 18; height: 28
                                radius: rSmall
                                color: clrMa.containsMouse ? dangerWash : bgCard
                                border.width: 1
                                border.color: clrMa.containsMouse ? dangerInk : borderSoft
                                Text {
                                    id: clrT; anchors.centerIn: parent; text: "Clear cache now"
                                    font.pixelSize: 11
                                    color: clrMa.containsMouse ? dangerInk : textPrimary
                                }
                                MouseArea {
                                    id: clrMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (backend) backend.clearCache()
                                        cacheNow.text = "Currently using " + (backend ? backend.cacheSize() : "—")
                                    }
                                }
                            }
                        }
                    }

                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

                RowLayout {
                    Layout.fillWidth: true
                    Rectangle {
                        implicitWidth: rstT.implicitWidth + 18; height: 30
                        radius: rSmall
                        color: rstMa.containsMouse ? bgHover : "transparent"
                        border.width: 1; border.color: borderSoft
                        Text {
                            id: rstT; anchors.centerIn: parent; text: "Reset to defaults"
                            font.pixelSize: 11; color: textSecondary
                        }
                        MouseArea {
                            id: rstMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (prefs) prefs.reset()
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitWidth: 78; height: 30; radius: rSmall
                        color: doneMa.containsMouse ? Qt.lighter(accentColor, 1.08) : accentColor
                        Text {
                            anchors.centerIn: parent; text: "Done"
                            font.pixelSize: 12; font.bold: true; color: onAccent
                        }
                        MouseArea {
                            id: doneMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: prefsDialog.visible = false
                        }
                    }
                }
            }
        }
    }


    // Only ever shown when the preference asks for it.
    Rectangle {
        id: confirmTrash
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        visible: false
        z: 121
        property var doomed: []

        function openDialog(paths) { doomed = paths; visible = true; forceActiveFocus() }
        Keys.onEscapePressed: visible = false
        MouseArea { anchors.fill: parent; onClicked: confirmTrash.visible = false }

        Rectangle {
            anchors.centerIn: parent
            width: 400
            height: ctCol.implicitHeight + 32
            color: bgPanel
            radius: rCard
            border.width: 1
            border.color: borderHard
            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
                id: ctCol
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    spacing: 10
                    Text { text: "delete"; font.family: iconFont; font.pixelSize: 20; color: accentInk }
                    ColumnLayout {
                        spacing: 1
                        Text {
                            text: confirmTrash.doomed.length === 1
                                  ? "Move to trash?" : "Move " + confirmTrash.doomed.length + " items to trash?"
                            font.pixelSize: tPanel; font.bold: true; color: textPrimary
                        }
                        Text {
                            text: "You can put this back with Ctrl+Z."
                            font.pixelSize: 11; color: textSecondary
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitWidth: 76; height: 32; radius: rSmall
                        color: ctNoMa.containsMouse ? bgHover : bgCard
                        border.width: 1; border.color: borderSoft
                        Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 12; color: textPrimary }
                        MouseArea {
                            id: ctNoMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: confirmTrash.visible = false
                        }
                    }
                    Rectangle {
                        implicitWidth: 116; height: 32; radius: rSmall
                        color: ctYesMa.containsMouse ? Qt.lighter(accentColor, 1.08) : accentColor
                        Text {
                            anchors.centerIn: parent; text: "Move to Trash"
                            font.pixelSize: 12; font.bold: true; color: onAccent
                        }
                        MouseArea {
                            id: ctYesMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                confirmTrash.visible = false
                                window.commitTrash(confirmTrash.doomed)
                            }
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // THE FILTER PANEL
    // =========================================================
    //
    // Four facets, because those are the ones a file can answer from its own
    // metadata: what KIND of thing it is, how BIG it is, how RECENTLY it changed,
    // and which TAG it carries. They combine — "images, over 100 MB, touched this
    // week" is one listing — and every one of them is applied to rows already on
    // screen, so the result is instant and nothing walks the disk.
    Rectangle {
        id: filterMenu
        visible: false
        z: 136
        width: 268
        height: fmCol.implicitHeight + 20
        radius: rCard
        color: bgPanel
        border.width: 1
        border.color: borderHard

        function toggle(anchorItem) {
            if (visible) { visible = false; return }
            var pt = anchorItem.mapToItem(window.contentItem, 0, anchorItem.height + 4)
            x = Math.max(8, Math.min(pt.x, window.width - width - 8))
            y = pt.y
            visible = true
        }

        // Addressed by id rather than by counting parents. A Repeater parents its
        // delegates to the Flow, so a chip is only two levels below this — the
        // same off-by-one that left every segmented control in Preferences blank
        // and unclickable, and it is not worth making twice.
        component FacetRow: ColumnLayout {
            id: facetRow
            property string title: ""
            property string facet: ""
            property var options: []
            property string value: "any"
            Layout.fillWidth: true
            spacing: 4
            Text {
                text: facetRow.title
                font.family: monoFont
                font.pixelSize: tLabel
                font.letterSpacing: 0.8
                color: textMuted
            }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: facetRow.options
                    delegate: Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool sel: modelData.v === facetRow.value
                        height: 24
                        width: chipT.implicitWidth + (chipDot.visible ? 26 : 16)
                        radius: rSmall
                        color: chip.sel ? accentColor : (chipMa.containsMouse ? bgHover : bgCard)
                        border.width: 1
                        border.color: chip.sel ? accentColor : borderSoft
                        Row {
                            anchors.centerIn: parent
                            spacing: 5
                            Rectangle {
                                id: chipDot
                                visible: modelData.c !== undefined
                                width: 8; height: 8; radius: 4
                                color: modelData.c !== undefined ? modelData.c : "transparent"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                id: chipT
                                text: modelData.t
                                font.pixelSize: 11
                                color: chip.sel ? onAccent : textSecondary
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            id: chipMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (backend) backend.setFilterFacet(facetRow.facet, modelData.v)
                            }
                        }
                    }
                }
            }
        }

        ColumnLayout {
            id: fmCol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10

            FacetRow {
                title: "KIND"
                facet: "kind"
                value: backend ? backend.filterKind : "any"
                options: [
                    { t: "Any", v: "any" }, { t: "Folders", v: "folder" },
                    { t: "Images", v: "image" }, { t: "Video", v: "video" },
                    { t: "Audio", v: "audio" }, { t: "Documents", v: "document" },
                    { t: "Code", v: "code" }, { t: "Archives", v: "archive" }
                ]
            }

            FacetRow {
                title: "SIZE"
                facet: "size"
                value: backend ? backend.filterSize : "any"
                options: [
                    { t: "Any", v: "any" }, { t: "< 1 MB", v: "small" },
                    { t: "1 – 100 MB", v: "medium" }, { t: "> 100 MB", v: "large" }
                ]
            }

            FacetRow {
                title: "MODIFIED"
                facet: "date"
                value: backend ? backend.filterDate : "any"
                options: [
                    { t: "Any time", v: "any" }, { t: "Today", v: "today" },
                    { t: "7 days", v: "week" }, { t: "30 days", v: "month" },
                    { t: "This year", v: "year" }
                ]
            }

            FacetRow {
                title: "TAG"
                facet: "tag"
                value: backend ? backend.filterTag : ""
                options: {
                    var out = [{ t: "Any", v: "" }]
                    for (var i = 0; i < window.tagNames.length; i++) {
                        var n = window.tagNames[i]
                        out.push({ t: n, v: n, c: window.tagColor(n) })
                    }
                    return out
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: borderSoft }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: {
                        var n = backend ? backend.activeFilterCount : 0
                        if (n === 0) return "No filters"
                        return currentCount + (currentCount === 1 ? " item shown" : " items shown")
                    }
                    font.pixelSize: 10
                    color: textMuted
                }
                Rectangle {
                    implicitWidth: clrFT.implicitWidth + 16
                    height: 24
                    radius: rSmall
                    visible: backend && backend.activeFilterCount > 0
                    color: clrFMa.containsMouse ? bgHover : "transparent"
                    border.width: 1
                    border.color: borderSoft
                    Text {
                        id: clrFT
                        anchors.centerIn: parent
                        text: "Clear all"
                        font.pixelSize: 10
                        color: textSecondary
                    }
                    MouseArea {
                        id: clrFMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            filterInput.text = ""
                            if (backend) backend.clearFilters()
                        }
                    }
                }
            }
        }
    }

    // Clicking anywhere else puts the panel away.
    MouseArea {
        anchors.fill: parent
        visible: filterMenu.visible
        z: 135
        onClicked: filterMenu.visible = false
    }

}
