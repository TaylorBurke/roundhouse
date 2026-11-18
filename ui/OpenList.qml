import QtQuick

// The small list that opens beside a map station when it was clicked and more than one thing is
// behind it (or when a lookup found several files for one name). A row click says which; the
// owner decides what that means. With only `message` set it is just a note ("Looking for ...").
Rectangle {
    id: root
    property string title: ""
    property var rows: []             // [{ text, sub }]
    property string message: ""
    property color bg: "#0b0d12"
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color edge: "#2a3140"
    property bool interactive: true               // false: rows only show (recent calls), they do not react
    property int elideMode: Text.ElideRight        // how a long row is cut: a path reads best cut in the middle

    signal picked(int index)

    readonly property int rowHeight: 24
    width: Math.min(parent ? parent.width - 16 : 280, 280)
    height: col.implicitHeight + 16
    radius: 6
    color: Qt.darker(bg, 1.4); border.color: edge; border.width: 1

    Column {
        id: col
        x: 8; y: 8; width: parent.width - 16
        spacing: 3
        Text {
            width: parent.width
            text: root.title
            textFormat: Text.PlainText
            color: root.inkStrong; font.family: "monospace"; font.bold: true; font.pixelSize: 12
        }
        Text {
            objectName: "message"
            width: parent.width
            visible: text !== ""
            text: root.message
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.ink; font.family: "monospace"; font.pixelSize: 11
        }
        Repeater {
            model: root.rows
            Rectangle {
                id: row
                required property int index
                required property var modelData
                objectName: "row" + index
                width: col.width; height: root.rowHeight; radius: 4
                color: hit.containsMouse && root.interactive ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) : "transparent"
                Text {
                    anchors { left: parent.left; leftMargin: 6; right: sub.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    text: row.modelData.text
                    textFormat: Text.PlainText
                    elide: root.elideMode
                    color: hit.containsMouse && root.interactive ? root.inkStrong : root.ink
                    font.family: "monospace"; font.pixelSize: 11
                }
                Text {
                    id: sub
                    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    text: row.modelData.sub || ""
                    color: root.faint; font.family: "monospace"; font.pixelSize: 10
                }
                MouseArea {
                    id: hit
                    anchors.fill: parent
                    enabled: root.interactive
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(row.index)
                }
            }
        }
    }
}
