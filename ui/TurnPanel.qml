import QtQuick

// The Model station's turn panel: one block per step (think time, tokens, tools, the reasoning summary or
// "redacted"), a one-line note when the numbers may be incomplete, and a button for the raw transcript.
// Read-only and on screen only. Everything is plain text; nothing here runs a command (the window does).
Rectangle {
    id: root
    property string title: "Model · this turn"
    property string summary: ""
    property string note: ""
    property var steps: []            // [{ head, text, tools }]
    property color bg: "#0b0d12"
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color edge: "#2a3140"
    property real maxHeight: 400

    signal openRaw()

    width: Math.min(parent ? parent.width - 16 : 344, 344)
    height: Math.min(maxHeight, col.implicitHeight + 16)
    radius: 6
    color: Qt.darker(bg, 1.4); border.color: edge; border.width: 1
    clip: true

    Flickable {
        anchors { fill: parent; margins: 8 }
        contentWidth: width; contentHeight: col.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: root.width - 16
            spacing: 6
            Text {
                width: parent.width
                text: root.title + (root.summary !== "" ? "  ·  " + root.summary : "")
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                color: root.inkStrong; font.family: "monospace"; font.bold: true; font.pixelSize: 12
            }
            Text {
                objectName: "note"
                width: parent.width
                visible: text !== ""
                text: root.note
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                color: root.accent; font.family: "monospace"; font.pixelSize: 10
            }
            Repeater {
                model: root.steps
                Column {
                    id: step
                    required property int index
                    required property var modelData
                    objectName: "step" + index
                    width: col.width
                    spacing: 1
                    Text {
                        objectName: "head"
                        width: parent.width
                        text: step.modelData.head
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        color: root.inkStrong; font.family: "monospace"; font.pixelSize: 11
                    }
                    Text {
                        objectName: "tools"
                        width: parent.width
                        visible: text !== ""
                        text: step.modelData.tools !== "" ? "tools: " + step.modelData.tools : ""
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        color: root.faint; font.family: "monospace"; font.pixelSize: 10
                    }
                    Text {
                        objectName: "reasoning"
                        width: parent.width
                        visible: text !== ""
                        text: step.modelData.text
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        color: root.ink; font.family: "monospace"; font.pixelSize: 10
                    }
                }
            }
            Rectangle {
                objectName: "openRaw"
                width: parent.width; height: 24; radius: 4
                color: hit.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) : "transparent"
                border.color: root.edge; border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "Open the raw transcript"; textFormat: Text.PlainText
                    color: hit.containsMouse ? root.inkStrong : root.ink
                    font.family: "monospace"; font.pixelSize: 11
                }
                MouseArea {
                    id: hit
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openRaw()
                }
            }
        }
    }
}
