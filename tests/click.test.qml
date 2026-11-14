// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/click.test.qml
// Clicking a station of the map: which ones react, the pointer over them, the popup list, and what a
// click and a lookup result lead to (ui/openlist.js).
import QtQuick
import QtTest
import "../ui"
import "../ui/board.js" as Board
import "../ui/openlist.js" as OpenList

Item {
    width: 360; height: 460

    property var board: Board.newBoard()
    property int rev: 0
    function fold(ev) { ev.v = 1; ev.sid = "aaaaaaaa"; Board.fold(board, ev); rev++; }

    MapView {
        id: map
        width: 360; height: 360
        session: parent.rev >= 0 ? (parent.board.sessions["aaaaaaaa"] || null) : null
        revision: parent.rev
    }
    SignalSpy { id: clicks; target: map; signalName: "nodeClicked" }

    OpenList {
        id: list
        y: 365; x: 8
        title: "Files"
        rows: [{ text: "src/app.ts", sub: "×3" }, { text: "README.md", sub: "" }]
    }
    SignalSpy { id: picks; target: list; signalName: "picked" }

    TestCase {
        name: "ClickableNodes"
        when: windowShown

        function station(key) { return map.pos(map.indexOf(key)); }
        function area(key) { return findChild(map, "station_" + key); }
        function read(id, station, label, tool) {
            parent.fold({ ts: 3, ev: "tool_end", id: id, station: station, label: label, tool: tool || "Read", status: "ok" });
        }
        function init() {
            parent.board = Board.newBoard();
            parent.fold({ ts: 1, ev: "session", dir: "proj", model: "claude-sonnet-5-5" });
            parent.fold({ ts: 2, ev: "prompt" });
            clicks.clear(); picks.clear();
        }

        // ---- the map ----
        function test_a_station_with_files_behind_it_is_a_pointing_hand_and_reacts() {
            read("a", "files", "src/app.ts");
            compare(area("files").cursorShape, Qt.PointingHandCursor);
            mouseClick(map, station("files").x, station("files").y);
            compare(clicks.count, 1);
            compare(clicks.signalArguments[0][0], "files");
        }
        function test_memory_and_skills_react_too() {
            read("m", "memory", "memory/note.md", "Edit");
            read("s", "skills", "tdd-workflow", "Skill");
            compare(area("memory").cursorShape, Qt.PointingHandCursor);
            compare(area("skills").cursorShape, Qt.PointingHandCursor);
            mouseClick(map, station("memory").x, station("memory").y);
            mouseClick(map, station("skills").x, station("skills").y);
            compare(clicks.count, 2);
            compare(clicks.signalArguments[1][0], "skills");
        }
        function test_a_station_with_nothing_to_open_stays_an_arrow_and_does_not_react() {
            compare(area("files").cursorShape, Qt.ArrowCursor);
            mouseClick(map, station("files").x, station("files").y);
            compare(clicks.count, 0);
        }
        function test_other_stations_never_react_even_with_calls_behind_them() {
            read("sh", "shell", "build it", "Bash");
            read("n", "network", "example.com", "WebFetch");
            ["shell", "network", "you", "model", "agents", "hooks", "browser"].forEach(function (k) {
                compare(area(k).cursorShape, Qt.ArrowCursor, k);
                mouseClick(map, station(k).x, station(k).y);
            });
            compare(clicks.count, 0);
        }
        function test_shell_lines_at_the_files_station_are_descriptions_not_names() {
            read("b", "files", "List the stale manifests", "Bash");      // a shell line made of file commands
            read("g", "files", "Grep", "Grep");                            // a search: the label is the tool's name
            compare(area("files").cursorShape, Qt.ArrowCursor);
            read("r", "files", "a/b.md");
            compare(area("files").cursorShape, Qt.PointingHandCursor);
        }
        function test_the_pointer_changes_as_files_come_and_go() {
            compare(area("skills").cursorShape, Qt.ArrowCursor);
            read("s", "skills", "omarchy", "Skill");
            compare(area("skills").cursorShape, Qt.PointingHandCursor);
        }
        function test_no_tooltip_while_a_list_is_open() {
            read("a", "files", "src/app.ts");
            var p = station("files");
            mouseMove(map, p.x, p.y);
            wait(450);
            compare(findChild(map, "tooltip").visible, true);
            map.listOpen = true;
            compare(findChild(map, "tooltip").visible, false);
            map.listOpen = false;
            mouseMove(map, 2, 2);
        }

        // ---- the list ----
        function test_a_row_click_says_which_row() {
            mouseClick(findChild(list, "row1"));
            compare(picks.count, 1);
            compare(picks.signalArguments[0][0], 1);
            mouseClick(findChild(list, "row0"));
            compare(picks.signalArguments[1][0], 0);
        }
        function test_a_message_alone_is_a_note_without_rows() {
            list.rows = []; list.message = "Looking for a/b.md";
            compare(findChild(list, "message").visible, true);
            compare(findChild(list, "row0"), null);
            list.message = "";
            compare(findChild(list, "message").visible, false);
            list.rows = [{ text: "src/app.ts", sub: "×3" }, { text: "README.md", sub: "" }];
        }

        // ---- what a click and a lookup lead to ----
        function test_no_items_does_nothing() {
            compare(OpenList.onNode([]).action, "none");
            compare(OpenList.onNode(null).action, "none");
        }
        function test_one_item_is_looked_up_at_once() {
            var d = OpenList.onNode([{ label: "a/b.md", count: 2, ts: 5 }]);
            compare(d.action, "resolve");
            compare(d.item.label, "a/b.md");
        }
        function test_several_items_are_listed_with_their_counts() {
            var d = OpenList.onNode([{ label: "x.ts", count: 3, ts: 9 }, { label: "y.ts", count: 1, ts: 8 }]);
            compare(d.action, "list");
            compare(d.rows.length, 2);
            compare(d.rows[0].text, "x.ts");
            compare(d.rows[0].sub, "×3");
            compare(d.rows[1].sub, "");
        }
        function test_a_lookup_with_one_file_opens_it_several_ask_none_says_so() {
            compare(OpenList.onResolved(["/h/a.md"]).action, "open");
            compare(OpenList.onResolved(["/h/a.md"]).path, "/h/a.md");
            compare(OpenList.onResolved(["/h/a.md", "/h/b.md"]).action, "choose");
            compare(OpenList.onResolved([]).action, "missing");
            compare(OpenList.onResolved(null).action, "missing");
        }
        function test_paths_that_share_their_end_are_told_apart_by_the_part_that_differs() {
            var t = OpenList.tails(["/home/ww/.claude/projects/-home-ww-Work-dev-roundhouse/memory/MEMORY.md",
                                    "/home/ww/.claude/projects/-home-ww-Work-dev-claude-strip/memory/MEMORY.md"], "/home/ww");
            compare(t[0], "\u2026/-home-ww-Work-dev-roundhouse/memory/MEMORY.md");
            compare(t[1], "\u2026/-home-ww-Work-dev-claude-strip/memory/MEMORY.md");
        }
        function test_the_shortest_ending_is_used_and_a_whole_path_keeps_its_start() {
            var t = OpenList.tails(["/home/ww/a/x/f.md", "/home/ww/b/y/f.md"], "/home/ww");
            compare(t[0], "\u2026/x/f.md");
            compare(t[1], "\u2026/y/f.md");
            compare(OpenList.tails(["/home/ww/f.md"], "/home/ww")[0], "~/f.md");
            compare(OpenList.tails(["/etc/f.md"], "/home/ww")[0], "/etc/f.md");
            compare(OpenList.tails([], "/home/ww").length, 0);
            compare(OpenList.tails(["/home/ww/a/f.md", "/home/ww/a/f.md"], "/home/ww").length, 2);   // identical: no endless loop
        }
        function test_memory_files_are_told_apart_by_their_project() {
            var rows = OpenList.memoryRows(["/home/ww/.claude/projects/-home-ww-Work-dev-roundhouse/memory/MEMORY.md",
                                            "/home/ww/.claude/projects/-home-ww-Work/memory/MEMORY.md",
                                            "/home/ww/notes/memory/other.md"], "/home/ww");
            compare(rows[0].text, "Work-dev-roundhouse");
            compare(rows[1].text, "Work");
            compare(rows[2].text.length > 0, true);            // not a project memory path: shown by its ending
            compare(OpenList.memoryRows([], "/home/ww").length, 0);
        }
        function test_paths_are_shown_with_the_home_folder_as_a_tilde() {
            compare(OpenList.shorten("/home/ww/Work/a.md", "/home/ww"), "~/Work/a.md");
            compare(OpenList.shorten("/etc/x", "/home/ww"), "/etc/x");
            compare(OpenList.shorten("/home/wwx/a", "/home/ww"), "/home/wwx/a");
            compare(OpenList.shorten("/home/ww/a", ""), "/home/ww/a");
        }
    }
}
