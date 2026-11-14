// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/icons.test.qml
// The hooks icon: the eyelet stays where it was, the hook leans 14 degrees to the right, and the icon is
// nudged 3 screen pixels right; no other icon is moved.
import QtQuick
import QtTest
import "../ui/icons.js" as Icons

TestCase {
    name: "Icons"

    // a drawing context that only records what it is asked to do
    function recorder() {
        var calls = [];
        var ctx = {
            calls: calls,
            save: function () { calls.push(["save"]); }, restore: function () { calls.push(["restore"]); },
            translate: function (x, y) { calls.push(["translate", x, y]); }, scale: function (a, b) { calls.push(["scale", a, b]); },
            beginPath: function () { calls.push(["beginPath"]); }, stroke: function () { calls.push(["stroke"]); },
            moveTo: function (x, y) { calls.push(["moveTo", x, y]); }, lineTo: function (x, y) { calls.push(["lineTo", x, y]); },
            arc: function (x, y, r, a0, a1) { calls.push(["arc", x, y, r, a0, a1]); },
            closePath: function () { calls.push(["closePath"]); },
            rect: function () { calls.push(["rect"]); }, ellipse: function () { calls.push(["ellipse"]); }
        };
        return ctx;
    }
    function drawn(name) { var c = recorder(); Icons.draw(c, name, 100, 50, 24, "#fff", 1.4); return c.calls; }
    function first(calls, kind) { return calls.filter(function (c) { return c[0] === kind; })[0]; }
    function all(calls, kind) { return calls.filter(function (c) { return c[0] === kind; }); }

    function test_the_hooks_icon_is_nudged_three_pixels_right_and_no_other_icon_is() {
        compare(first(drawn("hooks"), "translate")[1], 103);
        compare(first(drawn("hooks"), "translate")[2], 50);
        ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills"].forEach(function (k) {
            compare(first(drawn(k), "translate")[1], 100, k);
        });
    }
    function test_the_nudge_is_in_screen_pixels_whatever_the_icon_size() {
        var small = recorder(), big = recorder();
        Icons.draw(small, "hooks", 100, 50, 12, "#fff", 1.4);
        Icons.draw(big, "hooks", 100, 50, 96, "#fff", 1.4);
        compare(first(small.calls, "translate")[1], 103);
        compare(first(big.calls, "translate")[1], 103);
    }
    function test_the_eyelet_has_not_moved() {
        var arcs = all(drawn("hooks"), "arc");
        compare(arcs[0].slice(1), [0, -6.5, 1.5, 0, 2 * Math.PI]);       // the ring at the top: same centre, radius, and sweep as before the tilt
        compare(first(drawn("hooks"), "moveTo").slice(1), [1.5, -6.5]);
    }
    function test_the_hook_leans_fourteen_degrees_to_the_right_about_the_eyelets_foot() {
        var calls = drawn("hooks");
        compare(all(calls, "moveTo")[1].slice(1), [0, -5]);              // the shaft still starts at the eyelet's foot
        var bottom = all(calls, "lineTo")[0];                             // where the 8-long shaft ends once it has swung
        fuzzyCompare(bottom[1], 8 * Math.sin(14 * Math.PI / 180), 0.001);
        fuzzyCompare(bottom[2], -5 + 8 * Math.cos(14 * Math.PI / 180), 0.001);
        verify(bottom[1] > 0);                                            // the bottom is right of the shaft's old line (x = 0)
    }
    function test_the_curve_under_the_shaft_leans_with_it() {
        var arcs = all(drawn("hooks"), "arc");
        var curve = arcs[1];                                              // centre, radius 4, from the swing angle round the bottom
        compare(curve[3], 4);
        fuzzyCompare(curve[4], -14 * Math.PI / 180, 0.0001);
        fuzzyCompare(curve[5], Math.PI - 14 * Math.PI / 180, 0.0001);
        verify(curve[1] > -4);                                            // the curve's centre moved right of where it was (-4)
    }
}
