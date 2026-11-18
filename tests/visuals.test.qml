// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/visuals.test.qml
// The map's extra cues: the waiting pulse on You, the slow-call outline, the usage heat ring and the
// press ripple. The state logic itself is in board.test.qml; this checks the map shows it.
import QtQuick
import QtTest
import "../ui"
import "../ui/board.js" as Board

Item {
    width: 360; height: 360

    property var board: Board.newBoard()
    property int rev: 0
    function fold(ev) { ev.v = 1; ev.sid = "aaaaaaaa"; Board.fold(board, ev); rev++; }

    MapView {
        id: map
        width: 360; height: 360
        session: parent.rev >= 0 ? (parent.board.sessions["aaaaaaaa"] || null) : null
        revision: parent.rev
        slowSeconds: 120
    }

    TestCase {
        name: "MapVisuals"
        when: windowShown

        function init() {
            parent.board = Board.newBoard();
            parent.fold({ ts: 1, ev: "session", dir: "proj", model: "claude-sonnet-5-5" });
            map.slowSeconds = 120;
            map.presses = 0;
        }
        function item(name) { return findChild(map, name); }

        function test_you_pulses_only_while_an_ask_is_open() {
            verify(!item("waiting").visible);
            parent.fold({ ts: 2, ev: "ask", tool: "Bash" });
            verify(item("waiting").visible);
            parent.fold({ ts: 3, ev: "prompt" });
            verify(!item("waiting").visible);
        }
        function test_the_pulse_sits_on_you_and_does_not_move_it() {
            var you = map.pos(0), w = item("waiting");
            compare(w.x + w.width / 2, you.x);
            compare(w.y + w.height / 2, you.y);
        }
        function test_a_call_past_the_threshold_is_outlined() {
            var past = Date.now() / 1000 - 300;
            parent.fold({ ts: past, ev: "tool_start", id: "a", station: "shell", label: "sleep", tool: "Bash" });
            map.nowSec = Date.now() / 1000;
            verify(item("slow_shell").visible);
            verify(!item("slow_files").visible);
            map.slowSeconds = 600;
            verify(!item("slow_shell").visible);
            map.slowSeconds = 0;
            verify(!item("slow_shell").visible);
        }
        function test_a_fresh_call_is_not_outlined() {
            parent.fold({ ts: Date.now() / 1000, ev: "tool_start", id: "a", station: "shell", label: "ls", tool: "Bash" });
            map.nowSec = Date.now() / 1000;
            verify(!item("slow_shell").visible);
        }
        function test_heat_ring_grows_with_share() {
            parent.fold({ ts: 2, ev: "tool_start", id: "a", station: "files", label: "x", tool: "Read" });
            verify(!item("heat_shell").visible);
            var one = item("heat_files").border.width;
            parent.fold({ ts: 3, ev: "tool_start", id: "b", station: "shell", label: "x", tool: "Bash" });
            parent.fold({ ts: 4, ev: "tool_start", id: "c", station: "files", label: "x", tool: "Read" });
            verify(item("heat_shell").visible);
            verify(item("heat_files").border.width < one + 0.01 || item("heat_files").border.width > 1);
            verify(item("heat_files").border.width > item("heat_shell").border.width);
        }
        function test_pressing_any_station_ripples_but_empty_space_does_not() {
            var p = map.pos(map.indexOf("network"));          // nothing to open there
            mouseClick(map, p.x, p.y);
            compare(map.presses, 1);
            mouseClick(map, map.cx, map.cy);                   // the hub
            compare(map.presses, 1);
        }
        function test_pressing_a_clickable_station_ripples_and_still_clicks() {
            parent.fold({ ts: 2, ev: "tool_end", id: "a", station: "files", label: "src/app.ts", tool: "Read", status: "ok" });
            var p = map.pos(map.indexOf("files"));
            var got = 0;
            map.nodeClicked.connect(function () { got++; });
            mouseClick(map, p.x, p.y);
            compare(map.presses, 1);
            compare(got, 1);
        }
    }
}
