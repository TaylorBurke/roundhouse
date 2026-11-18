import QtQuick
import "contextpanel.js" as Panel

// The hub's context panel: a sparkline of the tokens in the context over the session, the peak, the
// current reading, and the compactions. `info` is Panel.parse() of tools/transcript.py's answer.
Rectangle {
    id: root
    property var info: ({ found: false })
    property real reading: 0              // the map's current reading (tokens), 0 if none
    property real windowSize: 0
    property color bg: "#0b0d12"
    property color ink: "#8d96ab"
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"
    property color accent: "#e0a458"
    property color alert: "#e06c75"
    property color edge: "#2a3140"

    readonly property var spark: Panel.thin(info.points || [], Panel.SPARK_POINTS)
    readonly property real now: reading > 0 ? reading : (spark.length ? spark[spark.length - 1] : 0)
    readonly property var rows: Panel.compactionRows(info.compactions)
    readonly property string caveat: Panel.note(info)

    width: Math.min(parent ? parent.width - 16 : 300, 300)
    height: col.implicitHeight + 16
    radius: 6
    color: Qt.darker(bg, 1.4); border.color: edge; border.width: 1
    onSparkChanged: canvas.requestPaint()
    onInkChanged: canvas.requestPaint()
    onAccentChanged: canvas.requestPaint()
    onFaintChanged: canvas.requestPaint()

    Column {
        id: col
        x: 8; y: 8; width: parent.width - 16
        spacing: 5
        Text {
            width: parent.width
            text: "Context window"
            color: root.inkStrong; font.family: "monospace"; font.bold: true; font.pixelSize: 12
        }
        Canvas {
            id: canvas
            objectName: "spark"
            width: parent.width; height: 44
            onPaint: {
                var c = getContext("2d");
                c.reset();
                var pts = root.spark, w = width, h = height;
                c.strokeStyle = root.faint; c.lineWidth = 1;
                c.beginPath(); c.moveTo(0, h - 0.5); c.lineTo(w, h - 0.5); c.stroke();
                if (pts.length < 2) return;
                var top = Math.max(1, root.info.peak || 0);
                pts.forEach(function (v) { top = Math.max(top, v); });
                c.strokeStyle = root.accent; c.lineWidth = 1.5; c.lineJoin = "round";
                c.beginPath();
                pts.forEach(function (v, i) {
                    var x = i * (w - 1) / (pts.length - 1), y = (h - 3) - (h - 6) * v / top;
                    if (i === 0) c.moveTo(x, y); else c.lineTo(x, y);
                });
                c.stroke();
            }
        }
        Text {
            objectName: "summary"
            width: parent.width
            visible: root.info.found
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            color: root.inkStrong; font.family: "monospace"; font.pixelSize: 11
            text: "now " + Panel.tok(root.now) + (root.windowSize > 0 ? " of " + Panel.tok(root.windowSize) : "")
                  + "  ·  peak " + Panel.tok(root.info.peak) + (root.info.count !== null && root.info.count !== undefined ? "  ·  " + root.info.count + " model calls" : "")
        }
        Text {
            objectName: "caveat"
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            color: root.alert; font.family: "monospace"; font.pixelSize: 11
            text: root.caveat
        }
        Text {
            objectName: "compactionsTitle"
            width: parent.width
            color: root.ink; font.family: "monospace"; font.pixelSize: 11
            text: root.rows.length === 0 ? "no compactions" : "compactions"
        }
        Repeater {
            model: root.rows
            Item {
                required property var modelData
                width: col.width; height: 16
                Text {
                    anchors { left: parent.left; right: sub.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: modelData.text; textFormat: Text.PlainText; elide: Text.ElideRight
                    color: root.ink; font.family: "monospace"; font.pixelSize: 11
                }
                Text {
                    id: sub
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    text: modelData.sub; textFormat: Text.PlainText
                    color: root.inkStrong; font.family: "monospace"; font.pixelSize: 11
                }
            }
        }
    }
}
