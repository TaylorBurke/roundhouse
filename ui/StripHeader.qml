import QtQuick

// The top of a session's window: the same text as that session's claude-strip, so the two
// belong together at a glance: a dot for the phase, the task title, then "waiting for you" or
// the number of tools running, and the context bar with its percentage. A click asks the
// parent to focus the terminal. With no strip to copy, it shows the folder name and model.
Item {
    id: root
    property var info: null              // the strip's state for this session, or null
    property string name: ""             // fallbacks: the folder name from the log ...
    property string model: ""            // ... and the model
    property bool ended: false
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color alert: "#f7768e"

    readonly property bool canActivate: info !== null && typeof info.address === "string" && info.address !== ""
    signal activate()
    height: 24

    function toolsText(n) { return n + (n === 1 ? " tool running" : " tools running"); }
    readonly property string phase: info ? info.phase : "idle"
    readonly property bool waiting: phase === "waiting"
    readonly property int running: info ? info.running : 0
    readonly property int context: info ? info.context : -1
    readonly property string title: info ? (info.task || info.project || name) : (name || "no session")
    readonly property color dotColor: waiting ? alert : phase === "working" ? accent : faint

    Text {
        id: dot
        objectName: "dot"
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        text: "●"
        color: root.info ? root.dotColor : (root.ended ? root.alert : root.faint)
        font.family: "monospace"; font.pixelSize: 10
    }

    Row {
        id: status
        objectName: "status"
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 10
        Text {
            objectName: "statusText"
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: root.info ? (root.waiting ? "waiting for you" : root.running > 0 ? root.toolsText(root.running) : "")
                            : (root.model + (root.ended ? "  (ended)" : "")).trim()
            color: root.waiting ? root.alert : root.faint
            font.family: "monospace"; font.pixelSize: 11
        }
        Row {
            objectName: "contextRow"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.info !== null && !root.waiting && root.context >= 0
            spacing: 6
            Rectangle {
                id: track
                anchors.verticalCenter: parent.verticalCenter
                width: 44; height: 6; radius: 3
                color: Qt.rgba(root.inkStrong.r, root.inkStrong.g, root.inkStrong.b, 0.18)
                Rectangle {
                    objectName: "contextFill"
                    visible: root.context > 0
                    width: Math.max(track.height, track.width * Math.min(root.context, 100) / 100); height: parent.height; radius: 3
                    color: root.context >= 85 ? root.alert : root.accent
                }
            }
            Text {
                objectName: "contextText"
                anchors.verticalCenter: parent.verticalCenter
                text: root.context + "%"
                color: root.faint; font.family: "monospace"; font.pixelSize: 11
            }
        }
    }

    Text {
        objectName: "title"
        anchors { left: dot.right; leftMargin: 8; right: status.width > 0 ? status.left : parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: root.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.inkStrong; font.family: "monospace"; font.pixelSize: 12; font.bold: !root.info
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.canActivate
        cursorShape: root.canActivate ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.activate()
    }
}
