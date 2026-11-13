import QtQuick
import "icons.js" as Icons
import "board.js" as Board

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
    property color accent: "#e0a458"  // hub outline, running calls, outbound pulses
    property color alert: "#f7768e"   // failed and blocked calls
    property int windowSetting: 0     // context window from the settings file; 0 = guess

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
    function runningOf(key) {
        return revision >= 0 && session ? session.stations[key].running : 0;
    }
    function indexOf(key) {
        for (var i = 0; i < stations.length; i++) if (stations[i].key === key) return i;
        return -1;
    }

    // ---- pulses ---------------------------------------------------------------------------
    // handle() is fed each live event. A call starting sends a dot out along its spoke; the
    // call ending sends one back (red if it failed). Ripples mark the station.
    function dot(from, to, tint, ms, delay) {
        dotC.createObject(overlay, { p0: from, p1: to, tint: tint, ms: ms, delay: delay || 0 });
    }
    function ripple(at, tint, r0, r1, ms, delay) {
        rippleC.createObject(overlay, { cx0: at.x, cy0: at.y, tint: tint, r0: r0, r1: r1, ms: ms, delay: delay || 0 });
    }
    function handle(ev, blocked) {
        var hub = Qt.point(cx, cy), k = ev.ev, i = indexOf(ev.station || (k === "ask" || k === "denied" ? "hooks" : ""));
        if (k === "tool_start" && i >= 0) {
            dot(hub, pos(i), accent, 420);
            ripple(pos(i), accent, discR, discR * 1.9, 700, 380);
        } else if (k === "tool_end" && i >= 0) {
            var tint = ev.status === "err" ? alert : ink;
            ripple(pos(i), tint, discR, discR * 1.9, 700);
            dot(pos(i), hub, tint, 420);
        } else if (k === "prompt") {
            var you = pos(indexOf("you")), model = pos(indexOf("model"));
            ripple(you, accent, discR, discR * 1.9, 700);
            dot(you, hub, accent, 380);
            dot(hub, model, accent, 380, 380);
            ripple(model, accent, discR, discR * 1.9, 700, 760);
        } else if (k === "batch") {
            var m = pos(indexOf("model"));
            ripple(m, ink, discR, discR * 1.9, 700);
            dot(m, hub, ink, 420);
        } else if (k === "stop") {
            ripple(hub, accent, hubR, Math.max(rx, ry) * 1.15, 1100);
            ripple(pos(indexOf("you")), accent, discR, discR * 1.9, 700, 500);
        } else if (k === "model") {
            ripple(hub, accent, hubR, hubR * 1.7, 2600);
            ripple(pos(indexOf("model")), accent, discR, discR * 2.2, 2600);
        } else if (k === "compact_start" || k === "compact_end") {
            ripple(pos(indexOf("model")), ink, discR, discR * 1.9, 900);
        } else if ((k === "ask" || k === "denied") && i >= 0) {
            ripple(pos(i), k === "denied" ? alert : accent, discR, discR * 1.9, 700);
        }
        (blocked || []).forEach(function (b) {
            var j = indexOf(b.station);
            if (j < 0) return;
            ripple(pos(j), alert, discR, discR * 2.1, 900);
            dot(pos(j), hub, alert, 420);
        });
    }

    readonly property var context: revision >= 0 ? Board.contextOf(session, windowSetting) : null
    readonly property bool compactingNow: revision >= 0 && Board.compacting(session)
    function sizeLabel(n) { return n >= 1000000 ? (n / 1000000) + "M" : Math.round(n / 1000) + "k"; }
    function percentLabel() {
        return !context ? "" : (context.stale ? "\u2013" : Math.round(context.share * 100)) + "% of " + sizeLabel(context.size);
    }
    onContextChanged: ring.requestPaint()
    // changes whenever any station's use count does, so the spokes are redrawn then
    readonly property string wearSig: revision >= 0 && session
        ? Object.keys(session.uses).map(function (k) { return k + session.uses[k]; }).join() : ""
    onWearSigChanged: canvas.requestPaint()

    function modelName() {
        var m = revision >= 0 && session ? session.model : "";
        return m.replace(/^claude-/, "").replace(/-(\d)/g, " $1").replace(/(\d) (\d)/, "$1.$2");
    }

    // a steady glow behind every station that has a call running
    Repeater {
        model: root.stations
        Rectangle {
            id: glow
            required property int index
            required property var modelData
            readonly property bool busy: root.runningOf(modelData.key) > 0
            z: -1
            visible: busy
            width: root.discR * 3.0; height: width; radius: width / 2
            x: root.pos(index).x - width / 2; y: root.pos(index).y - height / 2
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
            SequentialAnimation on opacity {
                running: glow.busy; loops: Animation.Infinite
                NumberAnimation { from: 0.45; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 1.0; to: 0.45; duration: 700; easing.type: Easing.InOutSine }
            }
        }
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
            // spokes, hub edge to station edge; the more a station is used, the thicker and brighter
            for (var i = 0; i < 10; i++) {
                var p = root.pos(i), dx = p.x - root.cx, dy = p.y - root.cy, d = Math.sqrt(dx * dx + dy * dy);
                var w = Board.wear(root.session, root.stations[i].key), a = root.line, b = root.ink;
                c.strokeStyle = Qt.rgba(a.r + (b.r - a.r) * w, a.g + (b.g - a.g) * w, a.b + (b.b - a.b) * w, 1);
                c.lineWidth = 1.2 + 2.4 * w;
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

    // the route line: a thin curve joining the stations the main loop visited last. The newest
    // leg draws itself; a leg holds for 40 s and fades over 20. Time passes without events, so
    // a timer repaints while any leg is showing.
    Canvas {
        id: route
        anchors.fill: parent
        property bool live: false          // some leg is still visible
        property bool drawing: false       // the newest leg is still drawing itself
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: root; function onRevisionChanged() { route.requestPaint(); } }
        Timer {
            interval: route.drawing ? 33 : 500
            running: route.live; repeat: true
            onTriggered: route.requestPaint()
        }
        onPaint: {
            var c = getContext("2d");
            c.reset();
            var legs = Board.routeLegs(root.session, Date.now() / 1000);
            live = legs.length > 0;
            drawing = live && legs[legs.length - 1].age < 0.8;
            var tint = root.accent;
            legs.forEach(function (leg, n) {
                var a = root.pos(root.indexOf(leg.from)), b = root.pos(root.indexOf(leg.to));
                var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
                var kx = mx + (root.cx - mx) * 0.3, ky = my + (root.cy - my) * 0.3;   // bow towards the hub
                var newest = n === legs.length - 1, reach = newest ? Math.min(1, leg.age / 0.6) : 1;
                var steps = Math.max(2, Math.round(28 * reach)), x = a.x, y = a.y;
                c.beginPath(); c.moveTo(a.x, a.y);
                for (var k = 1; k <= steps; k++) {
                    var t = reach * k / steps, u = 1 - t;
                    x = u * u * a.x + 2 * u * t * kx + t * t * b.x;
                    y = u * u * a.y + 2 * u * t * ky + t * t * b.y;
                    c.lineTo(x, y);
                }
                c.strokeStyle = Qt.rgba(tint.r, tint.g, tint.b, 0.6 * leg.alpha);
                c.lineWidth = 1.5; c.lineCap = "round"; c.stroke();
                if (newest) {
                    c.beginPath(); c.arc(x, y, 2.6, 0, 2 * Math.PI);
                    c.fillStyle = Qt.rgba(tint.r, tint.g, tint.b, leg.alpha); c.fill();
                }
            });
        }
    }

    // how full the context window is, as a ring around the hub: grey, amber from 70%, red from 90%
    Canvas {
        id: ring
        width: (root.hubR + 8) * 2; height: width
        x: root.cx - width / 2; y: root.cy - height / 2
        onWidthChanged: requestPaint()
        onPaint: {
            var c = getContext("2d"), mid = width / 2, r = root.hubR + 6;
            c.reset();
            c.lineWidth = 3; c.lineCap = "round";
            c.strokeStyle = root.ring; c.beginPath(); c.arc(mid, mid, r, 0, 2 * Math.PI); c.stroke();
            var ctx = root.context;
            if (!ctx || ctx.share <= 0) return;
            c.strokeStyle = ctx.stale ? root.faint : ctx.share >= 0.9 ? root.alert : ctx.share >= 0.7 ? root.accent : root.ink;
            if (ctx.stale) c.setLineDash([3, 4]);
            c.beginPath(); c.arc(mid, mid, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * ctx.share); c.stroke();
        }
    }

    Item { id: overlay; anchors.fill: parent }

    Component {
        id: dotC
        Rectangle {
            id: d
            property point p0; property point p1; property color tint; property int ms: 420; property int delay: 0
            width: 8; height: 8; radius: 4; color: tint; opacity: 0
            x: p0.x - 4; y: p0.y - 4
            SequentialAnimation {
                running: true
                PauseAnimation { duration: d.delay }
                PropertyAction { target: d; property: "opacity"; value: 1 }
                ParallelAnimation {
                    NumberAnimation { target: d; property: "x"; to: d.p1.x - 4; duration: d.ms; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: d; property: "y"; to: d.p1.y - 4; duration: d.ms; easing.type: Easing.InOutQuad }
                }
                PropertyAction { target: d; property: "opacity"; value: 0 }
                ScriptAction { script: d.destroy() }
            }
        }
    }

    Component {
        id: rippleC
        Rectangle {
            id: r
            property real cx0; property real cy0; property color tint
            property real r0: 10; property real r1: 30; property int ms: 700; property int delay: 0
            property real size: r0
            width: size * 2; height: width; radius: size
            x: cx0 - size; y: cy0 - size
            color: "transparent"; border.width: 2; border.color: tint; opacity: 0
            SequentialAnimation {
                running: true
                PauseAnimation { duration: r.delay }
                PropertyAction { target: r; property: "opacity"; value: 0.85 }
                ParallelAnimation {
                    NumberAnimation { target: r; property: "size"; from: r.r0; to: r.r1; duration: r.ms; easing.type: Easing.OutCubic }
                    NumberAnimation { target: r; property: "opacity"; to: 0; duration: r.ms }
                }
                ScriptAction { script: r.destroy() }
            }
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
                text: modelData.key === "model" && root.compactingNow ? "compacting"
                      : root.countOf(modelData.key) > 0 ? root.countOf(modelData.key) : ""
                color: modelData.key === "model" && root.compactingNow ? root.accent : root.faint
                font.family: "monospace"; font.pixelSize: Math.max(8, root.unit * 0.03)
            }
        }
    }

    Column {
        x: root.cx - width / 2
        y: root.cy - height / 2
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: text !== ""
            text: root.percentLabel()
            color: root.context && !root.context.stale && root.context.share >= 0.9 ? root.alert
                 : root.context && !root.context.stale && root.context.share >= 0.7 ? root.accent : root.faint
            font.family: "monospace"; font.pixelSize: Math.max(8, root.unit * 0.026)
        }
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
