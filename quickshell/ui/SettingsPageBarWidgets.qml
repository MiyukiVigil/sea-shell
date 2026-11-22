// Settings → BarWidgets. Built the first time it is opened; see PageLoader in settings.qml.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property int tabIdx: 12
    visible: root.tab === 12; Layout.fillWidth: true; spacing: 14

    MacHeaderCard {
        icon: "widgets"
        badgeColor: "#32ADE6"
        title: "Menu Bar Widgets & Global Menu"
        description: "Choose which indicators appear on the bar, drag to reorder them, and configure Global Menu and AI plan tracking."
    }

    Section { title: "Bar widgets"; icon: "widgets" }
    // The bar in miniature, in its real order. It's the thing you're arranging, and the real one
    // is hidden behind this window. Follows every switch and drag below.
    Rectangle {
        Layout.fillWidth: true; Layout.bottomMargin: 6; implicitHeight: 38; radius: Tok.rSmall
        color: Tok.alpha(Tok.ink, 0.06); border.width: 1; border.color: Tok.rule
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
            Text { text: "Workspaces"; color: Tok.ink3; font.pixelSize: 11; font.family: Tok.sans }
            Item { Layout.fillWidth: true }
            Sym { visible: root.wgMpris !== false; text: "play_circle"; sz: 17; color: Tok.ink2 }
            Item { Layout.fillWidth: true }
            Repeater {
                model: root.apWidgetOrder.filter(function (w) {
                    var m = root.wgMeta[w];
                    return m && w !== "wgMpris" && (!m.prop || root[m.prop]);
                })
                delegate: Sym { required property var modelData; text: root.wgMeta[modelData].i; sz: 17; color: Tok.ink2 }
            }
        }
    }
    Text {
        text: "Switch widgets on or off, and drag the dots to change their order."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    // drag-to-reorder list. ListView (non-interactive so the settings page still
    // scrolls) over wgOrderModel; dragging the handle moves rows via ListModel.move
    // and commits the new order to apWidgetOrder on release.
    ListView {
        id: wgList
        Layout.fillWidth: true
        Layout.preferredHeight: contentHeight
        interactive: false
        spacing: 8
        cacheBuffer: 100000
        model: wgOrderModel
        displaced: Transition { NumberAnimation { properties: "y"; duration: 150; easing.type: Easing.OutCubic } }
        delegate: Item {
            id: wrap
            required property int index
            required property string wid
            readonly property var meta: root.wgMeta[wrap.wid] || ({})
            readonly property bool hasToggle: (wrap.meta.prop || "") !== ""
            readonly property bool enabledVal: wrap.hasToggle ? root[wrap.meta.prop] : true
            property bool held: false
            readonly property bool styleOpen: root.wgOpenId === wrap.wid
            width: wgList.width; height: 52 + (wrap.styleOpen ? 116 : 0)
            Behavior on height { NumberAnimation { duration: Tok.mBase; easing.type: Tok.mEase } }
            z: held ? 2 : 1

            Rectangle {
                id: card
                width: wrap.width; height: wrap.height; radius: Tok.r
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                color: wrap.held ? Tok.raised : (wrap.styleOpen ? root.rowHover : "transparent")
                border.width: wrap.held ? 1 : 0; border.color: theme.iris
                Drag.active: wrap.held
                Drag.source: wrap
                Drag.hotSpot.x: width / 2; Drag.hotSpot.y: height / 2
                states: State {
                    when: wrap.held
                    ParentChange { target: card; parent: wgList }
                    AnchorChanges { target: card; anchors.horizontalCenter: undefined; anchors.verticalCenter: undefined }
                }
                RowLayout {
                    id: hdr
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    height: 52
                    anchors.leftMargin: 8; anchors.rightMargin: 14; spacing: 10
                    // drag handle — grabbing this reorders the row
                    MouseArea {
                        id: handle
                        Layout.preferredWidth: 24; Layout.fillHeight: true
                        cursorShape: Qt.SizeVerCursor
                        drag.target: card; drag.axis: Drag.YAxis
                        onPressed: { root.wgOpenId = ""; root.wgDragging = true; wrap.held = true }
                        onReleased: { wrap.held = false; root.wgCommitOrder(); root.wgDragging = false }
                        Sym { anchors.centerIn: parent; text: "drag_indicator"; sz: 18; color: wrap.held ? theme.iris : theme.faint }
                    }
                    Sym { text: wrap.meta.i || "widgets"; sz: 19; color: wrap.enabledVal ? theme.frost : theme.faint }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        Text { text: wrap.meta.l || wrap.wid; color: theme.text; font.pixelSize: 13; font.family: root.apFont
                            Layout.fillWidth: true; elide: Text.ElideRight }
                        Text { text: wrap.meta.d || ""; color: theme.faint; font.pixelSize: 11; font.family: root.apFont
                            Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                    // Opens the appearance controls for THIS widget. A dot marks one that
                    // has been styled, so a bar that no longer looks like the defaults can
                    // be traced to the rows responsible without opening all twenty.
                    MouseArea {
                        Layout.preferredWidth: 26; Layout.fillHeight: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.wgOpenId = wrap.styleOpen ? "" : wrap.wid
                        Sym { anchors.centerIn: parent; text: "tune"; sz: 17
                              color: wrap.styleOpen ? theme.iris : theme.faint }
                        Rectangle {
                            visible: root.wgStyleTouched(wrap.wid) && !wrap.styleOpen
                            width: 5; height: 5; radius: 2.5; color: theme.iris
                            anchors.right: parent.right; anchors.top: parent.top; anchors.topMargin: 13
                        }
                    }
                    // toggle (hidden for no-toggle widgets like the recorder)
                    Rectangle {
                        visible: wrap.hasToggle
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 46; implicitHeight: 22; radius: Tok.r
                        color: wrap.enabledVal ? theme.iris : theme.a(theme.line, 0.85); border.width: 1; border.color: wrap.enabledVal ? theme.iris : theme.a(theme.iris, 0.3)
                        Rectangle {
                            width: 16; height: 16; radius: Tok.r; y: 3; x: wrap.enabledVal ? 27 : 3
                            color: wrap.enabledVal ? Tok.accentInk : Tok.ink3; Behavior on x { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: { if (wrap.hasToggle) { root[wrap.meta.prop] = !wrap.enabledVal; root.saveAppearance() } }
                        }
                    }
                }

                // ---- per-widget appearance ----
                // Colour, what the pill draws, and what it draws it on. Chosen per
                // widget because the reasons differ per widget: the clock wants to be
                // read, the recorder wants to be noticed, and a pill you only keep for
                // its dropdown wants to take as little of the bar as it can.
                ColumnLayout {
                    id: styleBox
                    visible: wrap.styleOpen
                    anchors.top: hdr.bottom
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.leftMargin: 44; anchors.rightMargin: 14; anchors.topMargin: 1
                    spacing: 6

                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.a(theme.iris, 0.14) }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "Colour"; color: theme.faint; font.pixelSize: 11
                               font.family: Tok.sans
                               Layout.preferredWidth: 52 }
                        Repeater {
                            model: root.wgAccentChoices
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: root.wgStyleGet(wrap.wid, "a") === modelData.k
                                implicitWidth: 22; implicitHeight: 22; radius: 11
                                color: modelData.k === "" ? "transparent" : root.wgTone(modelData.k)
                                border.width: sel ? 2 : 1
                                border.color: sel ? theme.text : theme.a(theme.iris, 0.35)
                                // "default" has no colour of its own to show — it means the
                                // widget keeps whatever it already decides for itself.
                                Sym { visible: modelData.k === ""; anchors.centerIn: parent
                                      text: "block"; sz: 12; color: theme.faint }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.wgStyleSet(wrap.wid, "a", modelData.k) }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "Shows"; color: theme.faint; font.pixelSize: 11
                               font.family: Tok.sans
                               Layout.preferredWidth: 52 }
                        Repeater {
                            model: root.wgContentChoices
                            delegate: Chip {
                                required property var modelData
                                label: modelData.l
                                on: root.wgStyleGet(wrap.wid, "c") === modelData.k
                                onPicked: root.wgStyleSet(wrap.wid, "c", modelData.k)
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "Ground"; color: theme.faint; font.pixelSize: 11
                               font.family: Tok.sans
                               Layout.preferredWidth: 52 }
                        Repeater {
                            model: root.wgGroundChoices
                            delegate: Chip {
                                required property var modelData
                                label: modelData.l
                                on: root.wgStyleGet(wrap.wid, "g") === modelData.k
                                onPicked: root.wgStyleSet(wrap.wid, "g", modelData.k)
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }
            DropArea {
                anchors.fill: parent
                onEntered: (drag) => {
                    var from = drag.source.index; var to = wrap.index;
                    if (from !== to && from >= 0) wgOrderModel.move(from, to, 1);
                }
            }
        }
    }
    Section { title: "AI plans"; icon: "auto_awesome"; Layout.topMargin: 8 }
    Text {
        text: "Which plans the bar and the desktop card show. On top is the one that leads; tap it again for whichever is closest to empty. Antigravity reads Gemini + Claude/GPT quota from agy / Antigravity sign-in (keyring), a running language server, ~/.gemini/oauth_creds.json, or ~/.config/sea-shell/gemini-token."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 2
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    Flow {
        Layout.fillWidth: true; spacing: 6
        Repeater {
            model: [{k:"claude", l:"Claude"}, {k:"codex", l:"GPT"}, {k:"cursor", l:"Cursor · Grok"},
                    {k:"cursor-alt", l:"Cursor alt"}, {k:"gemini", l:"Antigravity"}]
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: root.aiOnGet(modelData.k)
                visible: modelData.k !== "cursor-alt" || root.apHasCursorAlt
                height: 27; radius: Tok.r; width: visible ? aiShowTxt.implicitWidth + 20 : 0
                color: on ? theme.a(theme.iris, 0.25)
                     : (aiShowMa.containsMouse ? theme.a(theme.line, 0.7) : theme.a(theme.line, 0.4))
                border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.2)
                Text { id: aiShowTxt; anchors.centerIn: parent; text: modelData.l
                    color: on ? theme.text : theme.sub
                    font.pixelSize: 11; font.family: root.apFont; font.bold: on }
                MouseArea { id: aiShowMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.aiOnToggle(modelData.k) }
            }
        }
    }
    Text { text: "On top"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont }
    Flow {
        Layout.fillWidth: true; Layout.bottomMargin: 4; spacing: 6
        Repeater {
            model: [{k:"claude", l:"Claude"}, {k:"codex", l:"GPT"}, {k:"cursor", l:"Cursor"},
                    {k:"cursor-alt", l:"Cursor alt"}, {k:"gemini", l:"Antigravity"}]
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: root.apAiDefault === modelData.k
                visible: root.aiOnGet(modelData.k) && (modelData.k !== "cursor-alt" || root.apHasCursorAlt)
                height: 27; radius: Tok.r; width: visible ? aiTopTxt.implicitWidth + 20 : 0
                color: on ? theme.a(theme.iris, 0.25)
                     : (aiTopMa.containsMouse ? theme.a(theme.line, 0.7) : theme.a(theme.line, 0.4))
                border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.2)
                Text { id: aiTopTxt; anchors.centerIn: parent; text: modelData.l
                    color: on ? theme.text : theme.sub
                    font.pixelSize: 11; font.family: root.apFont; font.bold: on }
                MouseArea { id: aiTopMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.aiDefaultSet(modelData.k) }
            }
        }
    }
    Text { text: "Percent"; color: theme.faint; font.pixelSize: 11; font.family: root.apFont }
    Flow {
        Layout.fillWidth: true; Layout.bottomMargin: 4; spacing: 6
        Repeater {
            model: [{k:0, l:"0"}, {k:1, l:"0.x"}, {k:2, l:"0.xx"}]
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: root.apAiDigits === modelData.k
                height: 27; radius: Tok.r; width: aiDigTxt.implicitWidth + 20
                color: on ? theme.a(theme.iris, 0.25)
                     : (aiDigMa.containsMouse ? theme.a(theme.line, 0.7) : theme.a(theme.line, 0.4))
                border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.2)
                Text { id: aiDigTxt; anchors.centerIn: parent; text: modelData.l
                    color: on ? theme.text : theme.sub
                    font.pixelSize: 11; font.family: root.apFont; font.bold: on }
                MouseArea { id: aiDigMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.aiDigitsSet(modelData.k) }
            }
        }
    }

    // ---- per-widget options ----
    // The first of these. sea-sysmon.sh samples cpu, ram, gpu, vram, temps and
    // power every 3 seconds and the pill rendered exactly one of them, so a 6GB
    // card had its VRAM measured on every tick and shown nowhere.
    Section { title: "System monitor"; icon: "speed"; Layout.topMargin: 8 }
    Text {
        text: "Choose bar readings; GPU readings appear when a discrete card is available."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    Flow {
        Layout.fillWidth: true; Layout.bottomMargin: 4; spacing: 6
        Repeater {
            model: [{k:"cpu",l:"CPU %"},{k:"cput",l:"CPU temp"},
                    {k:"ram",l:"RAM %"},{k:"ramg",l:"RAM GiB"},
                    {k:"gpu",l:"GPU %"},{k:"gput",l:"GPU temp"},
                    {k:"vram",l:"VRAM %"},{k:"vramg",l:"VRAM GiB"}]
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: root.apSysShow.indexOf(modelData.k) >= 0
                height: 27; radius: Tok.r; width: smTxt.implicitWidth + 20
                color: on ? theme.a(theme.iris, 0.25)
                     : (smMa.containsMouse ? theme.a(theme.line, 0.7) : theme.a(theme.line, 0.4))
                border.width: 1; border.color: on ? theme.iris : theme.a(theme.iris, 0.2)
                Text { id: smTxt; anchors.centerIn: parent; text: modelData.l
                    color: on ? theme.text : theme.sub
                    font.pixelSize: 11; font.family: root.apFont; font.bold: on }
                MouseArea { id: smMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.sysShowToggle(modelData.k) }
            }
        }
    }

    // ---- left cluster order (logo · workspaces · window-title) ----
    Section { title: "Left side"; icon: "align_horizontal_left"; Layout.topMargin: 8 }
    Text {
        text: "Drag to reorder the items on the left of the bar."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    ListView {
        id: lgList
        Layout.fillWidth: true
        Layout.preferredHeight: contentHeight
        interactive: false
        spacing: 8
        cacheBuffer: 100000
        model: lgOrderModel
        displaced: Transition { NumberAnimation { properties: "y"; duration: 150; easing.type: Easing.OutCubic } }
        delegate: Item {
            id: lwrap
            required property int index
            required property string wid
            readonly property var meta: root.lgMeta[lwrap.wid] || ({})
            property bool held: false
            width: lgList.width; height: 46
            z: held ? 2 : 1
            Rectangle {
                id: lcard
                width: lwrap.width; height: lwrap.height; radius: Tok.r
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                color: lwrap.held ? Tok.raised : "transparent"
                border.width: lwrap.held ? 1 : 0; border.color: theme.iris
                Drag.active: lwrap.held
                Drag.source: lwrap
                Drag.hotSpot.x: width / 2; Drag.hotSpot.y: height / 2
                states: State {
                    when: lwrap.held
                    ParentChange { target: lcard; parent: lgList }
                    AnchorChanges { target: lcard; anchors.horizontalCenter: undefined; anchors.verticalCenter: undefined }
                }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 14; spacing: 10
                    MouseArea {
                        id: lhandle
                        Layout.preferredWidth: 24; Layout.fillHeight: true
                        cursorShape: Qt.SizeVerCursor
                        drag.target: lcard; drag.axis: Drag.YAxis
                        onPressed: { root.wgDragging = true; lwrap.held = true }
                        onReleased: { lwrap.held = false; root.lgCommitOrder(); root.wgDragging = false }
                        Sym { anchors.centerIn: parent; text: "drag_indicator"; sz: 18; color: lwrap.held ? theme.iris : theme.faint }
                    }
                    Sym { text: lwrap.meta.i || "widgets"; sz: 19; color: theme.frost }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        Text { text: lwrap.meta.l || lwrap.wid; color: theme.text; font.pixelSize: 13; font.family: root.apFont
                            Layout.fillWidth: true; elide: Text.ElideRight }
                        Text { text: lwrap.meta.d || ""; color: theme.faint; font.pixelSize: 11; font.family: root.apFont
                            Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                }
            }
            DropArea {
                anchors.fill: parent
                onEntered: (drag) => {
                    var from = drag.source.index; var to = lwrap.index;
                    if (from !== to && from >= 0) lgOrderModel.move(from, to, 1);
                }
            }
        }
    }
    // ---- the global menu (it lives in the window-title slot) ----
    Section { title: "Global menu"; icon: "menu_open"; Layout.topMargin: 8 }
    Text {
        text: "Show the active app’s menu in place of its window title when available."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 6
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    ToggleCard {
        icon: "menu_open"; title: "Show the global menu"
        desc: "Replaces the window title when the focused window has a menu bar"
        on: root.gmEnabled
        onToggled: { root.gmEnabled = !root.gmEnabled; root.gmSave() }
    }
    ToggleCard {
        visible: root.gmEnabled
        icon: "keyboard"; title: "Show keyboard shortcuts"
        desc: "The accelerator beside each item, where the application reports one"
        on: root.gmAccel
        onToggled: { root.gmAccel = !root.gmAccel; root.gmSave() }
    }
    ToggleCard {
        visible: root.gmEnabled
        icon: "bolt"; title: "Read menus in the background"
        desc: "Firefox and Electron only describe a menu once it has been opened, and opening it is real — their own popup appears. Off: it happens on the click that needs it, one menu at a time. On: backgrounded windows are read in advance, which is faster but can be seen if you switch to one mid-read."
        on: root.gmPrime
        onToggled: { root.gmPrime = !root.gmPrime; root.gmSave() }
    }
    Text {
        visible: root.gmEnabled
        text: "SUPER+M opens it · SUPER+SHIFT+M searches every command in it · arrows walk it, / searches, escape backs out"
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont
        Layout.fillWidth: true; wrapMode: Text.WordWrap; Layout.topMargin: 2
    }
    AccentBtn {
        visible: root.gmEnabled
        label: root.gmDoctorBusy ? "checking…" : "Why has a window no menu?"
        icon: "stethoscope"
        enabled: !root.gmDoctorBusy
        Layout.topMargin: 4
        onClicked: root.gmRunDoctor()
    }
    Rectangle {
        visible: root.gmEnabled && root.gmDoctor.length > 0
        Layout.fillWidth: true
        implicitHeight: docTxt.implicitHeight + 20
        radius: Tok.r
        color: theme.a(theme.line, 0.4)
        border.width: 1; border.color: theme.a(theme.iris, 0.14)
        Text {
            id: docTxt
            anchors.fill: parent; anchors.margins: 10
            text: root.gmDoctor
            color: theme.sub; font.pixelSize: 11; font.family: Tok.sans
            wrapMode: Text.WordWrap
        }
    }

    // ---- per-app setup ----
    Text {
        visible: root.gmEnabled && root.gmApps.length > 0
        text: "Apps on this machine"
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
        Layout.topMargin: 8
    }
    Repeater {
        model: root.gmEnabled ? root.gmApps : []
        delegate: Rectangle {
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: Math.max(40, appCol.implicitHeight + 14)
            radius: Tok.r
            color: theme.a(theme.line, 0.4)
            border.width: 1
            border.color: modelData.ok ? theme.a(theme.good, 0.35)
                                       : theme.a(theme.warn, 0.35)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 10
                Sym { text: modelData.ok ? "check_circle" : "error"
                      sz: 17
                      color: modelData.ok ? theme.good : theme.warn
                      Layout.alignment: Qt.AlignVCenter }
                ColumnLayout { id: appCol; spacing: 2; Layout.fillWidth: true
                    Text { text: modelData.label; color: theme.text
                           font.pixelSize: 13; font.family: Tok.sans
                           Layout.fillWidth: true; elide: Text.ElideRight }
                    Text { text: modelData.ok ? "Ready" : modelData.how
                           color: theme.faint; font.pixelSize: 11
                           font.family: Tok.sans
                           Layout.fillWidth: true; wrapMode: Text.WordWrap } }
            }
        }
    }
    AccentBtn {
        visible: root.gmEnabled && root.gmNeeds > 0
        enabled: !root.gmSetupBusy
        icon: "auto_fix_high"
        label: root.gmSetupBusy ? "setting up…"
               : "set up " + root.gmNeeds + " app" + (root.gmNeeds === 1 ? "" : "s")
        Layout.topMargin: 4
        onClicked: root.gmSetupAll()
    }
    Text {
        visible: root.gmEnabled && root.gmApps.length > 0
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: root.gmNeeds > 0
              ? "Firefox needs two prefs; Electron apps need to run under xwayland so they can hand their menu over as data. Each app has to be restarted afterwards."
              : "Every app found here can publish its menu. Qt and gtk apps need nothing at all."
        color: theme.faint; font.pixelSize: 11; font.family: Tok.sans
    }

    // ---- bar layout presets (save/restore the whole bar layout) ----
    Section { title: "Layout presets"; icon: "bookmarks"; Layout.topMargin: 8 }
    Text {
        text: "Save the current widget order, left-side order and on/off toggles as a named preset, then restore it in one click."
        color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.bottomMargin: 4
        Layout.fillWidth: true; wrapMode: Text.WordWrap
    }
    RowLayout {
        Layout.fillWidth: true; spacing: 10
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 36; radius: Tok.r
            color: theme.a(theme.line, 0.4); border.width: 1; border.color: blNameIn.activeFocus ? theme.iris : theme.a(theme.iris, 0.16)
            TextInput {
                id: blNameIn; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                color: theme.text; font.pixelSize: 12; font.family: root.apFont; clip: true
                onAccepted: { root.saveBarLayout(text); text = "" }
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !blNameIn.text; text: "Layout name…"; color: theme.faint; font.pixelSize: 12; font.family: root.apFont }
            }
        }
        Rectangle {
            implicitWidth: 84; implicitHeight: 36; radius: Tok.r
            color: blSaveMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.22); border.width: 1; border.color: theme.iris
            enabled: blNameIn.text.trim() !== ""; opacity: enabled ? 1 : 0.5
            Row { anchors.centerIn: parent; spacing: 5
                Sym { anchors.verticalCenter: parent.verticalCenter; text: "save"; sz: 15; color: blSaveMa.containsMouse ? theme.bg : theme.frost }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Save"; color: blSaveMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 12; font.family: root.apFont } }
            MouseArea { id: blSaveMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.saveBarLayout(blNameIn.text); blNameIn.text = "" } }
        }
    }
    Text { visible: root.barLayouts.length === 0; text: "No saved layouts yet."; color: theme.faint; font.pixelSize: 11; font.family: root.apFont; Layout.topMargin: 2 }
    Repeater { model: root.barLayouts
        delegate: Rectangle { required property var modelData; required property int index
            Layout.fillWidth: true; implicitHeight: 44; radius: Tok.r
            color: theme.a(theme.line, 0.4); border.width: 1; border.color: theme.a(theme.iris, 0.16)
            RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                Sym { text: "bookmark"; sz: 17; color: theme.frost }
                Text { text: modelData.name; color: theme.text; font.pixelSize: 13; font.family: root.apFont; Layout.fillWidth: true; elide: Text.ElideRight }
                Rectangle { implicitWidth: 70; implicitHeight: 28; radius: Tok.r
                    color: blLoadMa.containsMouse ? theme.iris : theme.a(theme.iris, 0.18); border.width: 1; border.color: theme.a(theme.iris, 0.4)
                    Text { anchors.centerIn: parent; text: "Load"; color: blLoadMa.containsMouse ? theme.bg : theme.text; font.pixelSize: 11; font.family: root.apFont }
                    MouseArea { id: blLoadMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.loadBarLayout(modelData) } }
                Rectangle { implicitWidth: 30; implicitHeight: 28; radius: Tok.r
                    color: blDelMa.containsMouse ? theme.a(theme.bad, 0.25) : theme.a(theme.line, 0.5)
                    Sym { anchors.centerIn: parent; text: "delete"; sz: 15; color: blDelMa.containsMouse ? theme.bad : theme.faint }
                    MouseArea { id: blDelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteBarLayout(index) } } }
        }
    }
}
