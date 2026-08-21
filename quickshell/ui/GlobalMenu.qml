// sea-shell — the global menu
//
// The focused window's own menu bar, drawn in the bar, in the place the window title
// otherwise occupies.
//
// IT IS INVISIBLE UNLESS IT HAS SOMETHING TO SAY. That is the whole design rule, and it is
// not politeness — it is what makes the feature survivable on Linux. Most windows on this
// desktop export no menu bar at all (a terminal has none, Electron apps hide theirs, GTK4
// apps put everything behind a hamburger), and a global menu that answers those with an
// empty strip is worse than no global menu: it takes the title away and gives back nothing.
// So `available` is false for anything without menus, the title comes back, and the bar
// looks exactly as it did before this file existed.
//
// WHERE THE MENUS COME FROM. sea-appmenu.py, via accessibility — see the long note at the
// top of that file for why DBusMenu cannot work here. It writes a JSON snapshot of the
// FOCUSED window on every focus change; this reads it. Focus is global, so the strip shows
// on the focused monitor only, which is also the only monitor where it would be true.
//
// TWO KINDS OF APPLICATION, and the difference is visible to the user.
//
//   ready — Qt and GTK hand over their entire menu tree for free, nested submenus and all.
//           Nothing is opened, nothing flashes, the menu is simply there.
//
//   lazy  — Firefox reports its top-level labels but builds each menu only when it is first
//           opened. It can be read, but only by really opening it: the browser's own menu
//           appears on screen for ~350ms and its menu bar stays revealed afterwards for the
//           life of the window. So it is done ONCE PER MENU, on the click that needs it,
//           and remembered — never on focus, never speculatively, never twice. A menu you
//           do not open costs nothing.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

Item {
    id: root

    // ---- wiring from the bar ----
    property var pal                         // the shell's palette object (NOT named
                                             // `theme`: the bar binds this from an object whose id
                                             // is `theme`, and a property of the same name shadows
                                             // that id inside the binding, so `theme: theme` would
                                             // resolve to itself)
    property string uiFont: "sans"
    property string script: ""               // absolute path to sea-appmenu.py
    property string screenName: ""           // the monitor THIS bar is on
    property string focusedMonitor: ""       // the monitor Hyprland says is focused
    property real ui: 1.0
    property int barEdgeY: 0                 // where the bar's bottom edge sits, for the drop

    // ---- the snapshot ----
    property var snap: ({ "menus": [], "mode": "none" })
    // ONLY MENUS THAT CAN ACTUALLY BE SERVED. A `lazy` entry that arrived with no items is
    // one the daemon has not yet been able to read out of sight, and the only way to read
    // it now would be to make the application open it — which puts ITS menu on screen next
    // to ours, twice the menu and none of the point. So it is not drawn at all until the
    // daemon has primed it off-screen, and if that leaves nothing, the window title comes
    // back exactly as if the application had no menu bar.
    readonly property var menus: {
        var all = (root.snap && root.snap.menus) ? root.snap.menus : [];
        var out = [];
        for (var i = 0; i < all.length; i++)
            if (!all[i].lazy || (all[i].items && all[i].items.length)) out.push(all[i]);
        return out;
    }
    readonly property string mode: (root.snap && root.snap.mode) ? root.snap.mode : "none"
    readonly property int pid: (root.snap && root.snap.pid) ? root.snap.pid : 0

    // The strip belongs to the focused monitor. Comparing names rather than trusting the
    // snapshot's monitor id: the id is Hyprland's index and the bar only knows its name.
    readonly property bool onFocusedScreen:
        root.screenName.length > 0 && root.screenName === root.focusedMonitor
    readonly property bool available: root.menus.length > 0 && root.onFocusedScreen

    implicitWidth: root.available ? strip.implicitWidth : 0
    implicitHeight: parent ? parent.height : 22
    // An Item does not size itself to its implicit size; the bar's left group measures
    // children by `width`, so without these the strip would lay out as zero-wide.
    width: implicitWidth
    height: implicitHeight
    visible: root.available
    onAvailableChanged: if (!root.available) root.close()

    // A menu that is no longer the focused window's menu must not stay open over the next
    // one. Closing on pid change rather than on `available` alone catches the case where
    // you alt-tab between two applications that BOTH have menus.
    onPidChanged: root.close()

    FileView {
        id: snapFile
        path: Quickshell.env("HOME") + "/.cache/sea-shell/appmenu.json"
        watchChanges: true
        function apply() {
            try {
                reload();
                var t = text();
                if (!t || !t.trim()) { root.snap = { "menus": [], "mode": "none" }; return }
                root.snap = JSON.parse(t);
            } catch (e) {
                root.snap = { "menus": [], "mode": "none" };
            }
        }
        onFileChanged: apply()
        onLoaded: apply()
        Component.onCompleted: apply()
    }
    // ---- the strip ----
    Row {
        id: strip
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Repeater {
            model: root.menus
            delegate: Rectangle {
                id: cell
                required property var modelData
                required property int index
                readonly property bool open: root.openIndex === index
                width: lbl.implicitWidth + 14
                height: Math.max(18, root.height - 8)
                radius: Tok.r
                color: cell.open ? root.pal.a(root.pal.iris, 0.24)
                                 : (ma.containsMouse ? root.pal.a(root.pal.line, 0.55) : "transparent")
                Text {
                    id: lbl
                    anchors.centerIn: parent
                    text: cell.modelData.label || ""
                    // The strip sits where the window title was, so it starts at the title's
                    // weight. The open one lifts to full ink; nothing else shouts.
                    color: cell.open ? root.pal.text
                                     : (ma.containsMouse ? root.pal.sub : root.pal.faint)
                    font.pixelSize: 12
                    font.family: root.uiFont
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggle(cell.index, cell)
                    // Once one menu is open, sliding across the strip moves between them,
                    // the way a menu bar has always worked. Only while open: hover-to-open
                    // from cold would fire every time the pointer crossed the bar.
                    onEntered: if (root.openIndex >= 0 && root.openIndex !== cell.index)
                                   root.openAt(cell.index, cell)
                }
            }
        }
    }

    // ---- open / close ----
    property int openIndex: -1
    property Item openHost: null
    // Which submenu is open at each depth. [] is just the top menu's own items; [3, 1]
    // means item 3 of those, then item 1 of that submenu's items.
    property var openPath: []

    // The items to draw at each level, derived rather than stored: one source of truth for
    // "what is open" means a stale path can never draw a card belonging to another menu.
    readonly property var levels: {
        var out = [];
        if (root.openIndex < 0) return out;
        var m = root.menus[root.openIndex];
        if (!m) return out;
        var items = m.items || [];
        if (!items.length) return out;
        out.push(items);
        for (var k = 0; k < root.openPath.length; k++) {
            var it = items[root.openPath[k]];
            if (!it || !it.items || !it.items.length) break;
            items = it.items;
            out.push(items);
        }
        return out;
    }

    function close() {
        root.openIndex = -1;
        root.openHost = null;
        root.openPath = [];
        drop.shown = false;
    }

    function toggle(i, host) {
        if (root.openIndex === i) { root.close(); return }
        root.openAt(i, host);
    }

    function openAt(i, host) {
        var m = root.menus[i];
        if (!m) return;
        root.openIndex = i;
        root.openHost = host;
        root.openPath = [];
        drop.shown = true;
    }

    // Open item `index` of level `level`, discarding anything deeper — walking back up a
    // cascade and along a different branch must not leave the old branch's cards on screen.
    function descend(level, index) {
        var next = root.openPath.slice(0, level);
        next.push(index);
        root.openPath = next;
    }
    function truncate(level) {
        if (root.openPath.length > level) root.openPath = root.openPath.slice(0, level);
    }

    Process { id: invoker }
    // The sidecar resolves by label path, so the chain has to be rebuilt from what is open.
    function activate(level, label) {
        if (!root.script.length || root.openIndex < 0) return;
        var parts = [root.menus[root.openIndex].label];
        for (var k = 0; k < level; k++) {
            var items = root.levels[k];
            var it = items ? items[root.openPath[k]] : null;
            if (!it) return;                       // path went stale; do nothing rather
            parts.push(it.label);                  // than fire the wrong item
        }
        parts.push(label);
        root.close();
        invoker.command = ["python3", root.script, "--invoke", parts.join("/")];
        invoker.running = true;
    }

    // ---- the dropdown ----
    //
    // A CASCADE, not a list. LibreOffice hands over 54 nested submenus already populated,
    // and drawing only the first level meant "File > Recent Documents" rendered as a row
    // that looked clickable and would have fired the wrong thing. Each level is its own
    // card in a Row, so the chain of what you have opened stays on screen — which is the
    // only way to know where you are once you are three menus deep.
    PanelWindow {
        id: drop
        property bool shown: false
        visible: drop.shown && root.available
        color: "transparent"
        WlrLayershell.namespace: "sea-shell:drop"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; left: true; right: true; bottom: true }
        // An open menu takes the whole screen's clicks, because that is what an open menu
        // does everywhere: the next click either chooses something or dismisses it, and it
        // does not also press whatever was underneath. Masking only the card would leave
        // the click-anywhere-to-close below unreachable — the mask decides what the surface
        // can even receive, so a MouseArea outside it is drawn and never hit.
        mask: Region { item: drop.shown ? drop.contentItem : null }

        readonly property real scrX: drop.screen ? drop.screen.x : 0
        readonly property real hostX: {
            if (!root.openHost) return 0;
            var p = root.openHost.mapToGlobal(Qt.point(0, 0));
            return (p.x - drop.scrX) / root.ui;
        }

        // Anywhere else closes it, which is the one thing every menu on every desktop does.
        // Declared BEFORE the cards on purpose: later siblings sit on top in QML, so this
        // has to come first or it would swallow every click meant for a menu item.
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        Row {
            id: cascade
            spacing: 2
            y: root.barEdgeY + 6
            // Clamped so a deep chain runs back along the bar rather than off the screen.
            x: Math.max(6, Math.min(drop.hostX, (drop.width / root.ui) - width - 6))

            Repeater {
                model: root.levels
                delegate: Rectangle {
                    id: lvl
                    required property var modelData          // the items at this level
                    required property int index              // which level this is
                    width: Math.max(150, colInner.implicitWidth + 20)
                    height: colInner.implicitHeight + 14
                    radius: Tok.r + 2
                    color: root.pal ? root.pal.a(root.pal.bg, 0.97) : "#181818"
                    border.width: 1
                    border.color: root.pal ? root.pal.a(root.pal.line, 0.9) : "#333"

                    Column {
                        id: colInner
                        x: 10
                        y: 7
                        spacing: 1

                        Repeater {
                            model: lvl.modelData
                            delegate: Item {
                                required property var modelData
                                required property int index
                                readonly property bool isSep: !!modelData.sep
                                // A submenu with contents. Opens the next card along.
                                readonly property bool hasKids: !isSep && !!modelData.items
                                                                && modelData.items.length > 0
                                // A submenu we cannot reach — Firefox builds nested menus
                                // only while their parent is open and hovered, which is not
                                // an interaction AT-SPI can perform. Drawn, greyed, inert:
                                // pretending it is a leaf would fire the wrong action.
                                readonly property bool isStub: !!modelData.stub
                                readonly property bool clickable:
                                    !isSep && !isStub && !hasKids && modelData.enabled !== false
                                readonly property bool onPath:
                                    root.openPath.length > lvl.index
                                    && root.openPath[lvl.index] === index
                                width: Math.max(rowTxt.implicitWidth + 30, 130)
                                height: isSep ? 7 : 21

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: parent.isSep
                                    width: parent.width
                                    height: 1
                                    color: root.pal ? root.pal.a(root.pal.line, 0.8) : "#333"
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.topMargin: 1
                                    anchors.bottomMargin: 1
                                    visible: !parent.isSep
                                             && (parent.onPath || (ima.containsMouse
                                                 && (parent.clickable || parent.hasKids)))
                                    radius: Tok.r
                                    color: root.pal ? root.pal.a(root.pal.iris, 0.2) : "#2a2a3a"
                                }
                                Text {
                                    id: rowTxt
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !parent.isSep
                                    text: modelData.label || ""
                                    color: (parent.clickable || parent.hasKids)
                                           ? (root.pal ? root.pal.text : "#eee")
                                           : (root.pal ? root.pal.faint : "#777")
                                    font.pixelSize: 11
                                    font.family: root.uiFont
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: parent.hasKids || parent.isStub
                                    text: "\u203a"
                                    color: parent.hasKids
                                           ? (root.pal ? root.pal.sub : "#aaa")
                                           : (root.pal ? root.pal.faint : "#777")
                                    font.pixelSize: 13
                                    font.family: root.uiFont
                                }
                                MouseArea {
                                    id: ima
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !parent.isSep
                                    cursorShape: parent.clickable ? Qt.PointingHandCursor
                                                                  : Qt.ArrowCursor
                                    // Hover opens a submenu and closes any deeper one, the
                                    // way every cascading menu has always behaved. Moving
                                    // onto a leaf collapses back to this level.
                                    onEntered: {
                                        if (parent.hasKids) root.descend(lvl.index, index);
                                        else root.truncate(lvl.index);
                                    }
                                    onClicked: {
                                        if (parent.hasKids) { root.descend(lvl.index, index); return }
                                        if (parent.clickable) root.activate(lvl.index, modelData.label);
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
