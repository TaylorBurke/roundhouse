// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/route.test.qml
// The route line joins two stations without ever crossing the hub or the context ring round it.
import QtQuick
import QtTest
import "../ui"

Item {
    width: 400; height: 400

    MapView { id: small; width: 300; height: 300 }
    MapView { id: wide; x: 0; y: 0; width: 360; height: 360 }
    MapView { id: squat; width: 360; height: 220 }

    TestCase {
        name: "RouteAroundHub"
        when: windowShown

        function check_all_pairs(map) {
            var worst = 1e9;
            for (var i = 0; i < 10; i++)
                for (var j = 0; j < 10; j++) {
                    if (i === j) continue;
                    var a = map.pos(i), b = map.pos(j), k = map.routeControl(a, b);
                    worst = Math.min(worst, map.routeNearest(a, k, b));
                }
            return worst;
        }
        function test_no_pair_of_stations_has_a_route_through_the_hub() {
            [small, wide, squat].forEach(function (m) {
                verify(check_all_pairs(m) >= m.routeClear - 0.5, "closest approach " + check_all_pairs(m) + " vs " + m.routeClear);
            });
        }
        function test_the_clearance_covers_the_context_ring() {
            verify(wide.routeClear >= wide.hubR + 6 + 1.5);     // the ring: radius hubR + 6, 3 wide
        }
        function test_opposite_stations_would_have_crossed_without_the_swing() {
            // you (0) and network (5) face each other: the plain chord passes through the centre
            var a = wide.pos(0), b = wide.pos(5);
            var plain = Qt.point((a.x + b.x) / 2 + (wide.cx - (a.x + b.x) / 2) * 0.3, (a.y + b.y) / 2 + (wide.cy - (a.y + b.y) / 2) * 0.3);
            verify(wide.routeNearest(a, plain, b) < wide.routeClear);
            verify(wide.routeNearest(a, wide.routeControl(a, b), b) >= wide.routeClear - 0.5);
        }
        function test_neighbours_keep_the_gentle_bow_towards_the_hub() {
            var a = wide.pos(0), b = wide.pos(1), k = wide.routeControl(a, b);
            var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
            fuzzyCompare(k.x, mx + (wide.cx - mx) * 0.3, 0.001);
            fuzzyCompare(k.y, my + (wide.cy - my) * 0.3, 0.001);
        }
        function test_both_directions_clear_it() {
            var a = wide.pos(2), b = wide.pos(7);
            verify(wide.routeNearest(a, wide.routeControl(a, b), b) >= wide.routeClear - 0.5);
            verify(wide.routeNearest(b, wide.routeControl(b, a), a) >= wide.routeClear - 0.5);
        }
    }
}
