// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tooltip.test.qml
// Hovering a station of the map shows what it is, its counts and the calls behind its red badge.
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
    }

    TestCase {
        name: "MapTooltip"
        when: windowShown

        function station(key) { return map.pos(map.indexOf(key)); }
        function hover(key) {
            var p = station(key);
            mouseMove(map, p.x, p.y);
            wait(450);                       // the tip shows after a short pause
        }
        function tip() { return findChild(map, "tooltip"); }
        function texts(item, out) {
            out = out || [];
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i];
                if (c.text !== undefined) out.push(String(c.text));
                texts(c, out);
            }
            return out;
        }
        function all() { return texts(tip()).join("\n"); }

        function init() {
            parent.board = Board.newBoard();
            parent.fold({ ts: 1, ev: "session", dir: "proj", model: "claude-sonnet-5-5" });
            parent.fold({ ts: 2, ev: "prompt" });
            mouseMove(map, 2, 2);
            wait(20);
        }

        function test_nothing_shows_until_a_station_is_hovered() {
            compare(tip().visible, false);
        }
        function test_a_station_says_what_it_is_and_its_counts() {
            parent.fold({ ts: 3, ev: "tool_end", id: "t1", station: "files", label: "a/b.md", tool: "Read", status: "ok" });
            hover("files");
            compare(tip().visible, true);
            verify(all().indexOf("Files") >= 0);
            verify(all().indexOf("File tools") >= 0);
            verify(all().indexOf("1 call this session") >= 0);
            verify(all().indexOf("refused") < 0);
        }
        function test_a_red_badge_is_explained_with_the_calls_behind_it() {
            parent.fold({ ts: 3, ev: "tool_start", id: "r1", station: "files", label: "a/b.md", tool: "Edit" });
            parent.fold({ ts: 3.5, ev: "tool_start", id: "r2", station: "files", label: "c/d.md", tool: "Edit" });
            parent.fold({ ts: 4, ev: "batch" });
            hover("files");
            verify(all().indexOf("Red 2") >= 0);
            verify(all().indexOf("refused") >= 0);
            verify(all().indexOf("c/d.md") >= 0);
            verify(all().indexOf("a/b.md") >= 0);
            mouseMove(map, 2, 2);
            wait(20);
            hover("hooks");
            verify(all().indexOf("Red 2") >= 0);
            verify(all().indexOf("Files: c/d.md") >= 0);     // from another station, so it is named
        }
        function test_a_failed_call_says_failed() {
            parent.fold({ ts: 3, ev: "tool_end", id: "e1", station: "shell", label: "build it", tool: "Bash", status: "err" });
            hover("shell");
            verify(all().indexOf("failed") >= 0);
            verify(all().indexOf("build it") >= 0);
        }
        function test_the_hub_explains_the_context_ring() {
            var p = map.pos(0);
            mouseMove(map, map.cx, map.cy);
            wait(450);
            compare(tip().visible, true);
            verify(all().indexOf("Context window") >= 0);
        }
        function test_a_running_call_shows_its_elapsed_time() {
            var now = Date.now() / 1000;
            parent.fold({ ts: now - 72, ev: "tool_start", id: "q1", station: "shell", label: "npm test", tool: "Bash" });
            parent.fold({ ts: now - 5, ev: "tool_start", id: "q2", station: "shell", label: "ls", tool: "Bash" });
            parent.fold({ ts: now - 3, ev: "tool_end", id: "q3", station: "shell", label: "make", tool: "Bash", status: "ok", ms: 2000 });
            hover("shell");
            var t = all();
            verify(t.indexOf("npm test \u00b7 1m1") >= 0 || t.indexOf("npm test \u00b7 1m2") >= 0);
            verify(t.indexOf("npm test") < t.indexOf("ls \u00b7"));       // longest first
            verify(t.indexOf("last: make \u00b7 2.0s") >= 0);
            verify(t.indexOf("average 2.0s over 1 call") >= 0);
            verify(tip().width <= 260 && tip().x + tip().width <= map.width);
        }
        function test_a_station_shows_its_facts() {
            parent.fold({ ts: 3, ev: "batch" });
            hover("model");
            verify(all().indexOf("claude-sonnet-5-5 \u00b7 1 step this turn") >= 0);
        }
        function test_the_hub_shows_tokens_window_and_age() {
            parent.fold({ ts: Date.now() / 1000 - 120, ev: "context", tokens: 48213, model: "claude-sonnet-5-5" });
            mouseMove(map, map.cx, map.cy);
            wait(450);
            var t = all();
            verify(t.indexOf("48,213 tokens of 200,000") >= 0);
            verify(t.indexOf("window from a guess") >= 0);
            verify(t.indexOf("reading 2m") >= 0);
            verify(tip().y >= 0 && tip().y + tip().height <= map.height);
        }
        function test_leaving_hides_it_and_it_stays_inside_the_map() {
            hover("agents");
            compare(tip().visible, true);
            verify(tip().x >= 0 && tip().x + tip().width <= map.width);
            verify(tip().y >= 0);
            mouseMove(map, 2, 2);
            wait(30);
            compare(tip().visible, false);
        }
    }
}
