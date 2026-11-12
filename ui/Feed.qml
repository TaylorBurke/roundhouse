import QtQuick
import "board.js" as Board

// The current-action line and the last 16 rows. Rows read \u25cf running, \u00b7 done, \u2715 failed or blocked;
// finished rows that follow each other at one station are folded into one with "+N".
Column {
    id: root
    property var session: null
    property int revision: 0
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#565f89"
    property color accent: "#e0a458"
    property color alert: "#f7768e"
    spacing: 2

    Text {
        width: parent.width; elide: Text.ElideRight
        color: root.inkStrong; font.family: "monospace"; font.pixelSize: 12; font.bold: true
        text: root.revision >= 0 ? Board.currentAction(root.session) : ""
    }
    Item { width: 1; height: 4 }
    Repeater {
        model: root.revision >= 0 ? Board.feedRows(root.session, 16) : []
        Text {
            required property var modelData
            width: root.width; elide: Text.ElideRight
            font.family: "monospace"; font.pixelSize: 11
            color: modelData.status === "running" ? root.accent
                 : modelData.status === "ok" ? root.faint : root.alert
            text: modelData.mark + " " + modelData.name.padEnd(8) + modelData.label
                  + (modelData.extra > 0 ? "  +" + modelData.extra : "")
        }
    }
}
