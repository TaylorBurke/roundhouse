import QtQuick
import "icons.js" as Icons

// The resting map: a hub in the middle, ten stations on an ellipse (You at the top, then
// clockwise), a spoke to each, dashed contour rings behind. Everything is placed from the
// item's size, so it scales with the window. Colours are properties so a theme can set them.
Item {
    id: root
    property var session: null        // a board session, or null before any event
    property int revision: 0          // bump to redraw counts
    property color ink: "#8d96ab"     // icons and labels
    property color inkStrong: "#d7dcea"
    property color faint: "#4a5164"   // counts
    property color line: "#252a36"    // spokes
    property color ring: "#1c212b"    // contour rings
    property color disc: "#12151c"    // station and hub fill
    property color discEdge: "#2c3240"
    property color accent: "#e0a458"  // hub outline

    readonly property var stations: [
        { key: "you", label: "You" }, { key: "model", label: "Model" }, { key: "memory", label: "Memory" },
        { key: "files", label: "Files" }, { key: "shell", label: "Shell" }, { key: "network", label: "Network" },
        { key: "browser", label: "Browser" }, { key: "agents", label: "Agents" }, { key: "skills", label: "Skills" },
        { key: "hooks", label: "Hooks" }
    ]

    readonly property real unit: Math.min(width, height * 1.0)
    readonly property real cx: width / 2
    readonly property real cy: height / 2 - unit * 0.025
    readonly property real rx: width * 0.355
    readonly property real ry: height * 0.335
    readonly property real discR: unit * 0.06
    readonly property real hubR: unit * 0.118

    function pos(i) {
        var a = i * Math.PI / 5;
        return Qt.point(cx + rx * Math.sin(a), cy - ry * Math.cos(a));
    }
    function countOf(key) {
        return revision >= 0 && session ? session.stations[key].count : 0;
    }
    function modelName() {
        var m = revision >= 0 && session ? session.model : "";
        return m.replace(/^claude-/, "").replace(/-(\d)/g, " $1").replace(/(\d) (\d)/, "$1.$2");
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: root; function onInkChanged() { canvas.requestPaint(); } }
        onPaint: {
            var c = getContext("2d");
            c.reset();
            // contour rings
            c.strokeStyle = root.ring; c.lineWidth = 1; c.setLineDash([2, 5]);
            [0.4, 0.68, 0.96].forEach(function (f) {
                c.beginPath();
                c.ellipse(root.cx - root.rx * f, root.cy - root.ry * f, root.rx * 2 * f, root.ry * 2 * f);
                c.stroke();
            });
            c.setLineDash([]);
            // spokes, hub edge to station edge
            c.strokeStyle = root.line; c.lineWidth = 1.2;
            for (var i = 0; i < 10; i++) {
                var p = root.pos(i), dx = p.x - root.cx, dy = p.y - root.cy, d = Math.sqrt(dx * dx + dy * dy);
                c.beginPath();
                c.moveTo(root.cx + dx / d * root.hubR, root.cy + dy / d * root.hubR);
                c.lineTo(p.x - dx / d * root.discR, p.y - dy / d * root.discR);
                c.stroke();
            }
            // stations
            for (i = 0; i < 10; i++) {
                p = root.pos(i);
                c.beginPath(); c.arc(p.x, p.y, root.discR, 0, 2 * Math.PI);
                c.fillStyle = root.disc; c.fill();
                c.strokeStyle = root.discEdge; c.lineWidth = 1.2; c.stroke();
                Icons.draw(c, root.stations[i].key, p.x, p.y, root.discR * 1.3, root.ink, 1.4);
            }
            // hub
            c.beginPath(); c.arc(root.cx, root.cy, root.hubR, 0, 2 * Math.PI);
            c.fillStyle = root.disc; c.fill();
            c.strokeStyle = root.accent; c.lineWidth = 1.6; c.stroke();
        }
    }

    Repeater {
        model: root.stations
        Column {
            required property int index
            required property var modelData
            x: root.pos(index).x - width / 2
            y: root.pos(index).y + root.discR + 2
            spacing: 0
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.label; color: root.ink
                font.family: "monospace"; font.pixelSize: Math.max(9, root.unit * 0.036)
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.countOf(modelData.key) > 0 ? root.countOf(modelData.key) : ""
                color: root.faint
                font.family: "monospace"; font.pixelSize: Math.max(8, root.unit * 0.03)
            }
        }
    }

    Column {
        anchors.centerIn: undefined
        x: root.cx - width / 2
        y: root.cy - height / 2
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "CLAUDE"; color: root.inkStrong
            font.family: "monospace"; font.bold: true; font.letterSpacing: root.unit * 0.004
            font.pixelSize: Math.max(10, root.unit * 0.04)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.modelName(); color: root.faint
            font.family: "monospace"; font.pixelSize: Math.max(8, root.unit * 0.028)
        }
    }
}
