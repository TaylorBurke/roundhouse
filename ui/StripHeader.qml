import QtQuick

// The top of a session's window, made to look like that session's claude-strip: a darker band
// across the whole width with a 2px divider under it (red while the session waits for you). In
// it: a dot for the phase and the task title (up to two lines, so a long title is readable), and
// under that "waiting for you" or the number of tools running. (No context bar: the map's hub
// already shows it.) A click asks the parent to focus the terminal. With no strip to copy, it shows the
// folder name and model.
Item {
    id: root
    property var info: null              // the strip's state for this session, or null
    property string name: ""             // fallbacks: the folder name from the log ...
    property string model: ""            // ... and the model
    property bool ended: false
    property color band: "#0b0e14"       // the band's own, darker background
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color alert: "#f7768e"

    readonly property bool canActivate: info !== null && typeof info.address === "string" && info.address !== ""
    signal activate()
    signal dragStarted()                 // the pointer pressed here and began to drag: move the window

    readonly property int pad: 14        // the strip's own side inset
    readonly property int dividerHeight: 2
    readonly property string statusLine: info ? (waiting ? "waiting for you" : running > 0 ? toolsText(running) : "")
                                              : (model + (ended ? "  (ended)" : "")).trim()
    readonly property bool hasStatus: statusLine !== ""
    implicitHeight: 8 + title.implicitHeight + (hasStatus ? 5 + statusRow.height : 0) + 8 + dividerHeight
    height: implicitHeight

    function toolsText(n) { return n + (n === 1 ? " tool running" : " tools running"); }
    readonly property string phase: info ? info.phase : "idle"
    readonly property bool waiting: phase === "waiting"
    readonly property int running: info ? info.running : 0
    readonly property string title: info ? (info.task || info.project || name) : (name || "no session")
    readonly property color dotColor: waiting ? alert : phase === "working" ? accent : faint

    Rectangle {
        anchors.fill: parent
        color: root.band
    }

    // The strip's divider: a muted tint of the foreground, red while waiting.
    Rectangle {
        objectName: "divider"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: root.dividerHeight
        color: root.waiting ? root.alert : Qt.rgba(root.inkStrong.r, root.inkStrong.g, root.inkStrong.b, 0.2)
    }

    Text {
        id: dot
        objectName: "dot"
        anchors { left: parent.left; leftMargin: root.pad; top: parent.top; topMargin: 8 + Math.round((title.font.pixelSize * 1.3 - height) / 2) }
        text: "●"
        color: root.info ? root.dotColor : (root.ended ? root.alert : root.faint)
        font.family: "monospace"; font.pixelSize: 10
    }

    Text {
        id: title
        objectName: "title"
        anchors { left: parent.left; leftMargin: root.pad + 18; right: parent.right; rightMargin: root.pad; top: parent.top; topMargin: 8 }
        text: root.title
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        color: root.inkStrong; font.family: "monospace"; font.pixelSize: 12; font.bold: !root.info
    }

    Row {
        id: statusRow
        objectName: "status"
        visible: root.hasStatus
        anchors { left: title.left; top: title.bottom; topMargin: 5 }
        spacing: 12
        Text {
            id: statusText
            objectName: "statusText"
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: root.statusLine
            color: root.waiting ? root.alert : root.faint
            font.family: "monospace"; font.pixelSize: 11
        }
    }

    // A tap focuses the terminal; a press that turns into a drag asks the window to move (the
    // handlers tell them apart: moving past the drag threshold cancels the tap).
    TapHandler {
        enabled: root.canActivate
        onTapped: root.activate()
    }
    DragHandler {
        target: null
        onActiveChanged: if (active) root.dragStarted()
    }
    HoverHandler {
        cursorShape: root.canActivate ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
}
