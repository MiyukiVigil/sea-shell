// Big picture mode's windows: the room on one screen, and darkness on the others.
//
// Everything you see and do is in BigPictureScene.qml. This only decides where it goes.
//
// The other screens get a black window rather than being switched off. Turning an output off in the
// compositor moves its workspaces and windows, and a crash would leave it dark; a window puts it all
// back by closing, whichever way it closes.
import Quickshell
import Quickshell.Wayland
import QtQuick

Scope {
    id: root
    property bool shown: false
    property var cfg: ({ screen: "auto", other: "black", home: true })
    property var pads: []
    // The gaming session (gaming.qml): this is the whole screen, and there is no desktop behind it.
    property bool session: false
    signal setCfg(var patch)

    function nameOf(s) { return s ? "" + s.name : ""; }
    // A plugged-in screen unless told otherwise: that is the TV or the monitor at the desk.
    readonly property var target: {
        var list = Quickshell.screens;
        for (var i = 0; i < list.length; i++)
            if (root.cfg.screen !== "auto" && root.nameOf(list[i]) === root.cfg.screen) return list[i];
        for (var j = 0; j < list.length; j++)
            if (!/^(eDP|LVDS|DSI)/.test(root.nameOf(list[j]))) return list[j];
        return list.length ? list[0] : null;
    }

    readonly property bool gameShowing: scene.gameShowing
    readonly property bool steamHandoff: scene.steamHandoff
    readonly property bool appHandoff: scene.appHandoff !== ""

    function open() {
        if (root.steamHandoff || root.appHandoff) { scene.reclaim(); return; }
        if (root.shown) return;
        root.shown = true;
        scene.enter();
    }
    function close() { if (root.shown) scene.leave(); }
    function toggle() {
        if (root.steamHandoff || root.appHandoff) { scene.reclaim(); return; }
        if (root.shown) root.close(); else root.open();
    }
    function press(b) {
        // Home leaves Steam's screen (or a launcher's) and brings this one back. The window is
        // hidden while they have the display, so the press must not go into the hidden room.
        var away = root.steamHandoff || root.appHandoff;
        if (away && b === "home") { scene.reclaim(); return; }
        if (root.shown && !away) scene.input(b, true);
    }
    function release(b) { if (root.shown && !root.steamHandoff && !root.appHandoff) scene.release(b); }

    PanelWindow {
        id: main
        screen: root.target
        visible: root.shown && !scene.gameShowing && !scene.steamHandoff && !root.appHandoff
        color: "black"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "sea-bigpicture"
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onVisibleChanged: if (visible) scene.forceActiveFocus()

        BigPictureScene {
            id: scene
            anchors.fill: parent
            focus: true
            cfg: root.cfg
            pads: root.pads
            session: root.session
            screenName: root.nameOf(root.target)
            screenChoices: Quickshell.screens.map(root.nameOf)
            onSetCfg: patch => root.setCfg(patch)
            onExited: root.shown = false
        }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            visible: root.shown && root.cfg.other === "black" && modelData !== root.target
            color: "black"
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "sea-bigpicture-curtain"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        }
    }
}
