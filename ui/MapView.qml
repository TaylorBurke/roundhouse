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
    property color bg: "#0b0d12"      // window background, for text on red badges
    property color memory: "#5fb3a6"  // the Memory station's own colour
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
    function errOf(key) {
        return revision >= 0 && session ? (session.errDots[key] || 0) : 0;
    }
    function indexOf(key) {
        for (var i = 0; i < stations.length; i++) if (stations[i].key === key) return i;
        return -1;
    }

    // ---- pulses ---------------------------------------------------------------------------
    // handle() is fed each live event. A call starting sends a dot out along its spoke; the
    // call ending sends one back (red if it failed). Ripples mark the station.
    function dot(from, to, tint, ms, delay, lane) {
        var dx = to.x - from.x, dy = to.y - from.y, d = Math.sqrt(dx * dx + dy * dy) || 1;
        var off = laneOffset(lane || 0), ox = -dy / d * off, oy = dx / d * off;   // sideways, off the spoke
        dotC.createObject(overlay, { p0: Qt.point(from.x + ox, from.y + oy), p1: Qt.point(to.x + ox, to.y + oy),
                                     tint: tint, ms: ms, delay: delay || 0 });
    }
    // lanes: 0, +1, -1, +2, -2 ... times 6 px
    function laneOffset(n) { return (n % 2 ? (n + 1) / 2 : -n / 2) * 6; }
    property var recentStarts: ({})   // station -> { n, t }: starts in the last 0.4 s
    function laneFor(key) {
        var now = Date.now(), r = recentStarts[key];
        if (!r || now - r.t > 400) r = { n: 0, t: now };
        var lane = r.n;
        recentStarts[key] = { n: lane + 1, t: now };
        return lane;
    }
    function ripple(at, tint, r0, r1, ms, delay) {
        rippleC.createObject(overlay, { cx0: at.x, cy0: at.y, tint: tint, r0: r0, r1: r1, ms: ms, delay: delay || 0 });
    }
    function handle(ev, blocked) {
        var hub = Qt.point(cx, cy), k = ev.ev, i = indexOf(ev.station || (k === "ask" || k === "denied" ? "hooks" : ""));
        // a subagent's calls leave from the Agents station, not from the hub
        var origin = ev.agent && ev.station !== "agents" ? pos(indexOf("agents")) : hub;
        if (k === "tool_start" && i >= 0) {
            dot(origin, pos(i), accent, 420, 0, laneFor(ev.station));
            ripple(pos(i), accent, discR, discR * 1.9, 700, 380);
        } else if (k === "tool_end" && i >= 0) {
            var tint = ev.status === "err" ? alert : ink;
            ripple(pos(i), tint, discR, discR * 1.9, 700);
            dot(pos(i), origin, tint, 420);
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
    // a theme switch changes these; everything drawn on a canvas has to be drawn again
    readonly property string paletteSig: [ink, inkStrong, faint, line, ring, disc, discEdge, accent, alert, memory, bg].join()
    onPaletteSigChanged: repaintAll()
    onSessionChanged: repaintAll()           // another session was picked
    function repaintAll() { canvas.requestPaint(); ring.requestPaint(); route.requestPaint(); hands.requestPaint(); orbit.requestPaint(); }
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
                Icons.draw(c, root.stations[i].key, p.x, p.y, root.discR * 1.3, root.stations[i].key === "memory" ? root.memory : root.ink, 1.4);
            }
            // hub
            c.beginPath(); c.arc(root.cx, root.cy, root.hubR, 0, 2 * Math.PI);
            c.fillStyle = root.disc; c.fill();
            c.strokeStyle = root.accent; c.lineWidth = 1.6; c.stroke();
        }
    }

    // The route line never crosses the hub or the context ring round it: it stays at least this far
    // from the hub's centre (the ring's outer edge, and a little air).
    readonly property real routeClear: hubR + 14
    function bezierAt(a, k, b, t) {
        var u = 1 - t;
        return Qt.point(u * u * a.x + 2 * u * t * k.x + t * t * b.x, u * u * a.y + 2 * u * t * k.y + t * t * b.y);
    }
    // How near the curve a-k-b comes to the hub's centre.
    function routeNearest(a, k, b) {
        var m = 1e9;
        for (var i = 0; i <= 48; i++) {
            var p = bezierAt(a, k, b, i / 48);
            m = Math.min(m, Math.sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)));
        }
        return m;
    }
    // The control point of the curve from station point a to b. Neighbours get the gentle bow
    // towards the hub; if that would come too close to the hub (stations on opposite sides), the
    // curve is swung out, to the side away from the hub, until it clears it all the way round.
    function routeControl(a, b) {
        var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        var k = Qt.point(mx + (cx - mx) * 0.3, my + (cy - my) * 0.3);
        if (routeNearest(a, k, b) >= routeClear) return k;
        var dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy) || 1;
        var nx = -dy / d, ny = dx / d;
        if (nx * (mx - cx) + ny * (my - cy) < 0) { nx = -nx; ny = -ny; }
        for (var h = 0; h <= 600; h += 3) {
            k = Qt.point(mx + nx * 2 * h, my + ny * 2 * h);     // the curve's middle lies h off the chord
            if (routeNearest(a, k, b) >= routeClear) break;
        }
        return k;
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
                var k = root.routeControl(a, b), kx = k.x, ky = k.y;
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

    // red dot with a count on a station after an error or a refusal, until the next prompt
    Repeater {
        model: root.stations
        Rectangle {
            required property int index
            required property var modelData
            readonly property int n: root.errOf(modelData.key)
            visible: n > 0
            width: Math.max(root.discR * 0.62, badgeText.implicitWidth + 6); height: root.discR * 0.62; radius: height / 2
            x: root.pos(index).x + root.discR * 0.62; y: root.pos(index).y - root.discR * 0.95
            color: root.alert
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: parent.n; color: root.bg
                font.family: "monospace"; font.bold: true; font.pixelSize: Math.max(8, root.discR * 0.45)
            }
        }
    }

    // "x3": three calls running at once at a station
    Repeater {
        model: root.stations
        Text {
            required property int index
            required property var modelData
            readonly property int n: root.runningOf(modelData.key)
            visible: n >= 2
            text: "x" + n; color: root.accent
            font.family: "monospace"; font.bold: true; font.pixelSize: Math.max(8, root.discR * 0.5)
            x: root.pos(index).x - root.discR * 1.45 - width / 2 + root.discR * 0.3
            y: root.pos(index).y - root.discR * 0.95
        }
    }

    // each running subagent is a small dot circling the Agents station
    Canvas {
        id: orbit
        anchors.fill: parent
        property bool live: false
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: root; function onRevisionChanged() { orbit.requestPaint(); } }
        Timer { interval: 40; running: orbit.live; repeat: true; onTriggered: orbit.requestPaint() }
        onPaint: {
            var c = getContext("2d");
            c.reset();
            var n = Board.runningAgents(root.session);
            live = n > 0;
            if (n === 0) return;
            var p = root.pos(root.indexOf("agents")), t = Date.now() / 1000, t0 = root.accent;
            c.fillStyle = Qt.rgba(t0.r, t0.g, t0.b, 0.95);
            for (var k = 0; k < n; k++) {
                var a = t * 1.9 + k * 2 * Math.PI / n;
                c.beginPath();
                c.arc(p.x + Math.cos(a) * root.discR * 1.5, p.y + Math.sin(a) * root.discR * 1.5, 2.6, 0, 2 * Math.PI);
                c.fill();
            }
        }
    }

    // clock hands around a station while a call runs: the long one makes a lap a minute, the
    // short one a lap in ten minutes, both from the start of the oldest running call
    Canvas {
        id: hands
        anchors.fill: parent
        property bool live: false
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections { target: root; function onRevisionChanged() { hands.requestPaint(); } }
        Timer { interval: 250; running: hands.live; repeat: true; onTriggered: hands.requestPaint() }
        onPaint: {
            var c = getContext("2d");
            c.reset();
            var info = Board.runningInfo(root.session), now = Date.now() / 1000, any = false;
            var t = root.accent;
            for (var i = 0; i < 10; i++) {
                var r = info[root.stations[i].key];
                if (!r) continue;
                any = true;
                var p = root.pos(i), el = Math.max(0, now - r.since), rr = root.discR + 5;
                c.strokeStyle = Qt.rgba(t.r, t.g, t.b, 0.28); c.lineWidth = 1;
                c.beginPath(); c.arc(p.x, p.y, rr, 0, 2 * Math.PI); c.stroke();
                [[(el / 60) % 1, 8, 1.6, 0.95], [(el / 600) % 1, 5, 2.2, 0.6]].forEach(function (h) {
                    var a = -Math.PI / 2 + 2 * Math.PI * h[0], cs = Math.cos(a), sn = Math.sin(a);
                    c.strokeStyle = Qt.rgba(t.r, t.g, t.b, h[3]); c.lineWidth = h[2]; c.lineCap = "round";
                    c.beginPath(); c.moveTo(p.x + cs * (rr - h[1]), p.y + sn * (rr - h[1])); c.lineTo(p.x + cs * (rr + 1), p.y + sn * (rr + 1)); c.stroke();
                });
            }
            live = any;
        }
    }

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

    // ---- tooltips ---------------------------------------------------------------------------
    // Hover a station (or the hub) for what it stands for, its counts, and, when it wears a red
    // badge, which calls are behind it. It shows after a short pause and follows the live data.
    // A click on a station that has something to open (Files, Memory, Skills: see Board.openables)
    // says so here; the window decides what to do. The pointer is a pointing hand over those.
    signal nodeClicked(string key, point anchor)
    property bool listOpen: false         // the window shows a list beside a station: no tooltip then
    function canOpen(key) {
        return revision >= 0 && Board.openables(session, key, 1).length > 0;
    }

    property string hoverKey: ""          // the station under the pointer, "hub" for the hub, else ""
    property bool tipShown: false
    onHoverKeyChanged: { tipShown = false; if (hoverKey !== "") tipDelay.restart(); else tipDelay.stop(); }
    Timer { id: tipDelay; interval: 350; onTriggered: root.tipShown = true }

    function tipFor(key) {
        if (key === "hub") {
            var c = context;
            return { title: "Context window",
                     help: "How much of the model's context window this session has used. The ring turns amber from 70% and red from 90%; the oldest turns are compacted when it fills.",
                     stats: c ? [percentLabel() + (c.stale ? " (out of date: a compaction since the last reading)" : "")] : ["no reading yet"],
                     dots: 0, problems: [], explain: "" };
        }
        return Board.report(session, key, 4);
    }
    readonly property var tip: tipShown && !listOpen && hoverKey !== "" && revision >= 0 ? tipFor(hoverKey) : null
    readonly property point tipAnchor: indexOf(hoverKey) >= 0 ? pos(indexOf(hoverKey)) : Qt.point(cx, cy)

    Repeater {
        model: root.stations
        MouseArea {
            required property int index
            required property var modelData
            x: root.pos(index).x - root.discR * 1.5; y: root.pos(index).y - root.discR * 1.2
            width: root.discR * 3; height: root.discR * 3.8
            objectName: "station_" + modelData.key
            readonly property bool clickable: root.canOpen(modelData.key)
            hoverEnabled: true
            acceptedButtons: clickable ? Qt.LeftButton : Qt.NoButton
            cursorShape: clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onEntered: root.hoverKey = modelData.key
            onExited: if (root.hoverKey === modelData.key) root.hoverKey = ""
            onClicked: root.nodeClicked(modelData.key, root.pos(index))
        }
    }
    MouseArea {
        x: root.cx - root.hubR; y: root.cy - root.hubR; width: root.hubR * 2; height: root.hubR * 2
        hoverEnabled: true; acceptedButtons: Qt.NoButton
        onEntered: root.hoverKey = "hub"
        onExited: if (root.hoverKey === "hub") root.hoverKey = ""
    }

    Rectangle {
        id: tipBox
        objectName: "tooltip"
        z: 100
        visible: root.tip !== null
        readonly property bool below: root.tipAnchor.y < root.height * 0.45
        width: Math.min(root.width - 16, 260)
        height: tipCol.implicitHeight + 16
        x: Math.max(8, Math.min(root.width - width - 8, root.tipAnchor.x - width / 2))
        y: Math.max(4, below ? root.tipAnchor.y + root.discR * 2.7 : root.tipAnchor.y - root.discR * 1.7 - height)
        radius: 6
        color: Qt.darker(root.bg, 1.4); border.color: root.discEdge; border.width: 1
        Column {
            id: tipCol
            x: 8; y: 8; width: parent.width - 16
            spacing: 5
            Text {
                width: parent.width
                text: root.tip ? root.tip.title : ""
                color: root.inkStrong; font.family: "monospace"; font.bold: true; font.pixelSize: 12
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: root.tip ? root.tip.help : ""
                color: root.ink; wrapMode: Text.Wrap; font.family: "monospace"; font.pixelSize: 11
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: root.tip ? root.tip.stats.join("  ·  ") : ""
                color: root.faint; wrapMode: Text.Wrap; font.family: "monospace"; font.pixelSize: 11
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: root.tip ? root.tip.explain : ""
                color: root.alert; wrapMode: Text.Wrap; font.family: "monospace"; font.pixelSize: 11
            }
            Repeater {
                model: root.tip ? root.tip.problems : []
                Text {
                    required property var modelData
                    width: tipCol.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: (modelData.kind === "refused" ? "⊘ refused  " : "✕ failed  ")
                          + (modelData.station !== root.hoverKey ? (Board.report(null, modelData.station).title) + ": " : "") + modelData.label
                    color: root.alert; font.family: "monospace"; font.pixelSize: 11
                }
            }
        }
    }
}
