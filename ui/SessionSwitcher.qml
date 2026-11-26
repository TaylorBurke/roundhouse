import QtQuick
import "board.js" as Board

// A thin bar that says which session is on show and lets you change it:
//   ‹ name 2/3 ›  auto        click ‹ › (or press [ ] or the arrow keys) to step through the
//                             live sessions, which pins one; click "pinned" (or press a) to go
//                             back to following the most recently active; click the name (or
//                             press space) for the list.
// Dragging the bar (the name or the gaps; not the ‹ › and auto buttons) moves the window, as the
// header band does in a session's own window: the all-sessions window has no header.
// Sessions that ended or went quiet for 30 minutes are not listed. The parent decides what the
// signals do (see shell.qml); this only draws and reports clicks.
Item {
    id: root
    property var sessions: []          // [{ sid, name, idle }] live ones, in a stable order
    property string shown: ""          // sid on show
    property string shownName: ""      // its folder name, even when it is no longer listed
    property bool pinned: false
    property bool open: false          // the list is showing
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color disc: "#12151c"
    property color discEdge: "#2c3240"

    signal pick(string sid)
    signal follow()
    signal cycle(int dir)
    signal dragStarted()               // a press on the bar became a drag: move the window

    height: 24
    readonly property int count: sessions.length
    readonly property int position: {
        for (var i = 0; i < sessions.length; i++) if (sessions[i].sid === shown) return i + 1;
        return 0;
    }

    function choose(sid) { open = false; pick(sid); }
    function followLatest() { open = false; follow(); }

    Row {
        id: bar
        anchors.fill: parent
        spacing: 6

        Text {
            id: left
            objectName: "prev"
            width: 18; height: parent.height
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            text: "‹"; color: root.count > 1 ? root.ink : root.faint
            font.family: "monospace"; font.pixelSize: 16
            MouseArea { anchors.fill: parent; enabled: root.count > 1; onClicked: root.cycle(-1) }
        }
        Text {
            objectName: "name"
            width: parent.width - left.width - right.width - mode.width - parent.spacing * 4
            height: parent.height; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter
            text: (root.shownName || "no session") + (root.count > 1 ? "  " + root.position + "/" + root.count : "")
            color: root.inkStrong; font.family: "monospace"; font.pixelSize: 12; font.bold: true
            // a tap, not a MouseArea: a MouseArea would take the press, and the drag below would never see it
            TapHandler { onTapped: root.open = !root.open }
        }
        Text {
            id: right
            objectName: "next"
            width: 18; height: parent.height
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            text: "›"; color: root.count > 1 ? root.ink : root.faint
            font.family: "monospace"; font.pixelSize: 16
            MouseArea { anchors.fill: parent; enabled: root.count > 1; onClicked: root.cycle(1) }
        }
        Text {
            id: mode
            objectName: "mode"
            width: 52; height: parent.height
            horizontalAlignment: Text.AlignRight; verticalAlignment: Text.AlignVCenter
            text: root.pinned ? "pinned" : "auto"
            color: root.pinned ? root.accent : root.faint
            font.family: "monospace"; font.pixelSize: 11
            MouseArea { anchors.fill: parent; enabled: root.pinned; onClicked: root.followLatest() }
        }
    }

    // Moving past the drag threshold cancels the name's tap. A press on ‹ › or auto belongs to its
    // MouseArea, which the drag may not take over, so the buttons never drag.
    DragHandler {
        target: null
        // may take over from the name's TapHandler, never from an item (the buttons' MouseAreas)
        grabPermissions: PointerHandler.CanTakeOverFromHandlersOfDifferentType | PointerHandler.ApprovesTakeOverByAnything
        onActiveChanged: if (active) root.dragStarted()
    }

    // the list, over whatever is below the bar
    Rectangle {
        id: list
        objectName: "list"
        visible: root.open
        z: 20
        y: root.height + 2
        width: parent.width
        height: rows.height + 8
        color: root.disc; border.color: root.discEdge; radius: 6
        Column {
            id: rows
            x: 4; y: 4; width: parent.width - 8
            Repeater {
                model: root.sessions
                Item {
                    required property int index
                    required property var modelData
                    objectName: "row" + index
                    width: rows.width; height: 22
                    Text {
                        anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                        text: (modelData.sid === root.shown ? "● " : "  ") + (index + 1) + "  " + modelData.name
                        color: modelData.sid === root.shown ? root.accent : root.ink
                        font.family: "monospace"; font.pixelSize: 12
                    }
                    Text {
                        anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                        text: modelData.sid.substring(0, 8) + "  " + Board.idleLabel(modelData.idle)
                        color: root.faint; font.family: "monospace"; font.pixelSize: 11
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.choose(modelData.sid) }
                }
            }
            Item {
                objectName: "followRow"
                width: rows.width; height: 22
                Text {
                    anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                    text: "  a  follow the most recent"
                    color: root.pinned ? root.ink : root.faint; font.family: "monospace"; font.pixelSize: 12
                }
                MouseArea { anchors.fill: parent; onClicked: root.followLatest() }
            }
        }
    }
}
