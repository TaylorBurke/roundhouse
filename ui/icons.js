// Station icons, drawn from scratch with a Canvas 2D context. Each one is a handful of
// strokes in a 24 x 24 box centred on (0, 0); draw() scales it to the size asked for.

var HOOK_TILT = 14 * Math.PI / 180;   // how far the bottom of the hook leans to the right
// An icon that sits a little off-centre in its disc is nudged by this many screen pixels (not icon
// units, so the nudge does not grow with the window): the leaning hook, to the right.
var SHIFT_PX = { hooks: 3 };
var ICONS = {
    you: function (c) {
        c.arc(0, -4, 3.5, 0, 2 * Math.PI);
        c.moveTo(-7, 8); c.arc(0, 8, 7, Math.PI, 2 * Math.PI);
    },
    model: function (c) {
        c.rect(-5, -5, 10, 10);
        c.rect(-2, -2, 4, 4);
        [-3, 0, 3].forEach(function (k) {
            c.moveTo(k, -5); c.lineTo(k, -8); c.moveTo(k, 5); c.lineTo(k, 8);
            c.moveTo(-5, k); c.lineTo(-8, k); c.moveTo(5, k); c.lineTo(8, k);
        });
    },
    memory: function (c) {
        c.moveTo(0, -4); c.lineTo(-5, 4); c.lineTo(5, 4); c.closePath();
        [[0, -6], [-6, 5], [6, 5]].forEach(function (p) {
            c.moveTo(p[0] + 2, p[1]); c.arc(p[0], p[1], 2, 0, 2 * Math.PI);
        });
    },
    files: function (c) {
        c.moveTo(-5, -8); c.lineTo(2, -8); c.lineTo(6, -4); c.lineTo(6, 8); c.lineTo(-5, 8); c.closePath();
        c.moveTo(2, -8); c.lineTo(2, -4); c.lineTo(6, -4);
    },
    shell: function (c) {
        c.moveTo(-8, -4); c.lineTo(-3, 0); c.lineTo(-8, 4);
        c.moveTo(0, 5); c.lineTo(7, 5);
    },
    network: function (c) {
        c.arc(0, 0, 8, 0, 2 * Math.PI);
        c.moveTo(-8, 0); c.lineTo(8, 0);
        c.moveTo(3.6, 0); c.save(); c.scale(0.45, 1); c.arc(0, 0, 8, 0, 2 * Math.PI); c.restore();
    },
    browser: function (c) {
        c.rect(-8, -6, 16, 12);
        c.moveTo(-8, -2); c.lineTo(8, -2);
        c.moveTo(-5, -4); c.lineTo(-4.5, -4);
        c.moveTo(-2.5, -4); c.lineTo(-2, -4);
    },
    agents: function (c) {
        [[0, -6], [-6, 6], [6, 6]].forEach(function (p) {
            c.moveTo(p[0] + 2, p[1]); c.arc(p[0], p[1], 2, 0, 2 * Math.PI);
        });
        c.moveTo(0, -4); c.lineTo(0, 1);
        c.moveTo(-6, 4); c.lineTo(-6, 1); c.lineTo(6, 1); c.lineTo(6, 4);
    },
    skills: function (c) {
        c.moveTo(2, -9); c.lineTo(-5, 1); c.lineTo(-0.5, 1); c.lineTo(-2, 9);
        c.lineTo(5, -2); c.lineTo(0.5, -2); c.closePath();
    },
    // The eyelet stays put; the shaft and the curve under it swing about the eyelet's foot, so the
    // bottom of the hook leans to the right.
    hooks: function (c) {
        var a = -HOOK_TILT, cos = Math.cos(a), sin = Math.sin(a), px = 0, py = -5;
        function turn(x, y) { return [px + (x - px) * cos - (y - py) * sin, py + (x - px) * sin + (y - py) * cos]; }
        c.moveTo(1.5, -6.5); c.arc(0, -6.5, 1.5, 0, 2 * Math.PI);
        c.moveTo(px, py);
        var foot = turn(0, 3), centre = turn(-4, 3), tip = turn(-8, 1);
        c.lineTo(foot[0], foot[1]);
        c.arc(centre[0], centre[1], 4, a, Math.PI + a);
        c.lineTo(tip[0], tip[1]);
    }
};

function draw(ctx, name, x, y, size, color, weight) {
    var shape = ICONS[name];
    if (!shape) return;
    var k = size / 24;
    ctx.save();
    ctx.translate(x + (SHIFT_PX[name] || 0), y);
    ctx.scale(k, k);
    ctx.beginPath();
    shape(ctx);
    ctx.restore();                       // stroke after restoring, so the line width stays in pixels
    ctx.strokeStyle = color;
    ctx.lineWidth = weight || 1.5;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.stroke();
}
