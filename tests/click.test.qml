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
    SignalSpy { id: rights; target: map; signalName: "nodeRightClicked" }

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
            clicks.clear(); rights.clear(); picks.clear();
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
        function test_memory_is_always_clickable_even_before_any_memory_file_was_touched() {
            compare(findChild(map, "tooltip").visible, false);
            compare(area("memory").cursorShape, Qt.PointingHandCursor);
            mouseClick(map, station("memory").x, station("memory").y);
            compare(clicks.count, 1);
            compare(clicks.signalArguments[0][0], "memory");
        }
        function test_memory_needs_a_session_to_be_clickable() {
            parent.board = Board.newBoard();
            parent.rev++;
            compare(area("memory").cursorShape, Qt.ArrowCursor);
        }
        function test_a_clickable_station_has_a_backlight_and_the_others_do_not() {
            function lit(k) { return findChild(map, "backlight_" + k).visible; }
            compare(lit("memory"), true);                    // always
            compare(lit("files"), false);
            compare(lit("skills"), false);
            read("a", "files", "src/app.ts");
            read("s", "skills", "omarchy", "Skill");
            compare(lit("files"), true);
            compare(lit("skills"), true);
            ["you", "model", "shell", "network", "browser", "agents", "hooks"].forEach(function (k) { compare(lit(k), false, k); });
        }
        function test_the_backlight_is_a_quiet_ring_not_the_busy_glow() {
            read("a", "files", "src/app.ts");
            var b = findChild(map, "backlight_files");
            verify(b.border.width === 1);
            verify(b.color.a < 0.2);                          // faint
            verify(b.width > map.discR * 2 && b.width < map.discR * 3);   // snug round the disc, smaller than the busy glow (3.0)
        }
        function test_a_right_click_works_on_all_ten_stations_with_or_without_calls() {
            read("a", "files", "src/app.ts");
            var keys = ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills", "hooks"];
            keys.forEach(function (k, i) {
                mouseClick(map, station(k).x, station(k).y, Qt.RightButton);
                compare(rights.count, i + 1, k);
                compare(rights.signalArguments[i][0], k);
                verify(rights.signalArguments[i][1].x > 0);          // the anchor, to put the list beside
            });
            compare(clicks.count, 0);                                 // and none of them was a left click
        }
        function test_a_right_click_is_not_a_left_click_and_a_left_click_is_not_a_right_click() {
            read("a", "files", "src/app.ts");
            mouseClick(map, station("files").x, station("files").y, Qt.RightButton);
            compare(clicks.count, 0);
            compare(rights.count, 1);
            mouseClick(map, station("files").x, station("files").y);
            compare(clicks.count, 1);
            compare(rights.count, 1);
        }
        function test_a_right_press_on_a_station_with_nothing_to_open_leaves_the_pointer_an_arrow() {
            var p = station("shell");
            mouseMove(map, p.x, p.y);
            compare(area("shell").cursorShape, Qt.ArrowCursor);
            mousePress(map, p.x, p.y, Qt.RightButton);
            compare(area("shell").cursorShape, Qt.ArrowCursor);
            mouseRelease(map, p.x, p.y, Qt.RightButton);
            compare(area("shell").cursorShape, Qt.ArrowCursor);
            compare(clicks.count, 0);                                  // never a left click
            compare(rights.count, 1);
            mouseMove(map, 2, 2);
        }
        function test_a_left_press_passes_through_a_station_with_nothing_to_open() {
            compare(area("shell").acceptedButtons, Qt.RightButton);          // only the right button is taken
            read("a", "files", "src/app.ts");
            compare(area("files").acceptedButtons, Qt.LeftButton | Qt.RightButton);
            var p = station("shell");
            mousePress(map, p.x, p.y, Qt.LeftButton);
            compare(area("shell").pressed, false);                           // not accepted: it is not ours
            mouseRelease(map, p.x, p.y, Qt.LeftButton);
        }
        function test_the_station_under_a_point_is_found_for_the_click_away_overlay() {
            ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills", "hooks"].forEach(function (k) {
                var p = station(k);
                compare(map.stationAt(p.x, p.y), k);
            });
            compare(map.stationAt(map.cx, map.cy), "");                       // the hub is no station
            compare(map.stationAt(-5, -5), "");
        }
        function test_a_station_with_nothing_to_open_stays_an_arrow_and_does_not_react() {
            compare(area("files").cursorShape, Qt.ArrowCursor);
            mouseClick(map, station("files").x, station("files").y);
            compare(clicks.count, 0);
        }
        function test_other_stations_never_react_even_with_calls_behind_them() {
            read("sh", "shell", "build it", "Bash");
            read("n", "network", "web search", "WebSearch");               // Network reacts only to hosts and MCP servers
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
            tryVerify(function () { return findChild(map, "tooltip").visible; }, 5000);       // it shows after a short pause
            map.listOpen = true;
            compare(findChild(map, "tooltip").visible, false);
            map.listOpen = false;
            mouseMove(map, 2, 2);
        }

        // ---- the table of what a left click does ----
        function test_the_handler_table_decides_what_can_open() {
            var sess = { n: 0 };
            var spy = { calls: 0, openables: function () { this.calls++; return [{ label: "x", count: 1 }]; } };
            verify(OpenList.canOpen("memory", sess, spy));                    // always
            compare(spy.calls, 0);                                           // and no names were computed for it
            ["you", "model", "shell", "network", "browser", "agents", "hooks", "hub", "nope"].forEach(function (k) {
                verify(!OpenList.canOpen(k, sess, spy), k);                  // no entry: nothing to open, even with names
            });
            compare(spy.calls, 0);                                           // no names computed for a key with no entry
            verify(OpenList.canOpen("files", sess, spy));
            verify(OpenList.canOpen("skills", sess, spy));
            compare(spy.calls, 2);
            var none = { openables: function () { return []; } };
            verify(!OpenList.canOpen("files", sess, none));
            verify(!OpenList.canOpen("files", null, { openables: function () { return []; } }));
        }
        function test_a_new_entry_can_bring_its_own_items_without_touching_board_js() {
            var board = { openables: function () { throw new Error("must not be asked"); } };
            try {
                OpenList.HANDLERS.hooks = { items: function (sess, key, max) { return [{ label: "h", count: 1 }]; } };
                verify(OpenList.canOpen("hooks", null, board));
                compare(OpenList.onClick("hooks", null, board).action, "resolve");
                OpenList.HANDLERS.hooks = { items: function () { return []; } };
                verify(OpenList.canOpen("hooks", null, board));              // openable; the click finds nothing
                compare(OpenList.onClick("hooks", null, board).action, "none");
                OpenList.HANDLERS.hooks = { always: true, action: "custom" };
                verify(OpenList.canOpen("hooks", null, board));
                compare(OpenList.onClick("hooks", null, board).action, "custom");
                OpenList.HANDLERS.hooks = { always: true };                  // nothing to do on a click: not openable
                verify(!OpenList.canOpen("hooks", null, board));
                compare(OpenList.onClick("hooks", null, board).action, "none");
            } finally {
                delete OpenList.HANDLERS.hooks;
            }
            verify(!OpenList.canOpen("hooks", null, board));
        }
        function test_can_open_never_calls_a_provider() {
            var board = { openables: function () { throw new Error("must not be asked"); } };
            var calls = 0;
            try {
                OpenList.HANDLERS.hooks = { can: true, items: function () { calls++; return [{ label: "h", count: 1 }]; } };
                OpenList.HANDLERS.shell = { can: function (s) { return !!s; }, items: function () { calls++; return []; } };
                OpenList.HANDLERS.agents = { items: function () { calls++; return []; } };
                for (var i = 0; i < 5; i++) ["hooks", "shell", "agents"].forEach(function (k) { OpenList.canOpen(k, {}, board); });
                compare(calls, 0);
                verify(OpenList.canOpen("hooks", null, board));
                verify(OpenList.canOpen("shell", {}, board));
                verify(!OpenList.canOpen("shell", null, board));            // a cheap check can say no
                verify(OpenList.canOpen("agents", null, board));
                compare(OpenList.onClick("hooks", null, board).action, "resolve");
                compare(calls, 1);                                          // the provider runs at click time
                compare(OpenList.onClick("shell", {}, board).action, "none");
                compare(calls, 2);
                OpenList.HANDLERS.hooks = { can: false, items: function () { calls++; return []; } };
                verify(!OpenList.canOpen("hooks", null, board));
            } finally {
                delete OpenList.HANDLERS.hooks; delete OpenList.HANDLERS.shell; delete OpenList.HANDLERS.agents;
            }
        }
        function test_a_left_click_goes_through_the_table_as_it_did() {
            function board(items) { return { openables: function () { return items; } }; }
            compare(OpenList.onClick("memory", null, board([])).action, "memory");
            compare(OpenList.onClick("files", null, board([])).action, "none");
            compare(OpenList.onClick("files", null, board([{ label: "a/b.md", count: 1 }])).action, "resolve");
            var two = board([{ label: "x", count: 2 }, { label: "y", count: 1 }]);
            compare(OpenList.onClick("skills", null, two).action, "list");
            compare(OpenList.onClick("skills", null, two).rows[0].sub, "\u00d72");
            compare(OpenList.onClick("shell", null, two).action, "none");     // no entry
        }

        // ---- recent calls as rows ----
        function test_history_rows_say_status_duration_and_age() {
            var rows = OpenList.historyRows([
                { label: "watch it", status: "running", ms: undefined, ts: 95 },
                { label: "test it", status: "err", ms: 250, ts: 90 },
                { label: "build it", status: "ok", ms: 1234, ts: 40 },
                { label: "old", status: "blocked", ms: undefined, ts: -3500 },
                { label: "sub call", status: "ok", ms: 7, ts: 99, agent: "a1", agentType: "Explore" },
                { label: "untyped", status: "ok", ms: 7, ts: 99, agent: "a2" }], 100);
            compare(rows.map(function (r) { return r.text; }), ["watch it", "test it", "build it", "old", "sub call", "untyped"]);
            compare(rows[0].sub, "running \u00b7 now");
            compare(rows[1].sub, "err \u00b7 250ms \u00b7 10s");
            compare(rows[2].sub, "ok \u00b7 1.2s \u00b7 1m");
            compare(rows[3].sub, "blocked \u00b7 1h");
            compare(rows[4].sub, "ok \u00b7 7ms \u00b7 now \u00b7 Explore");
            compare(rows[5].sub, "ok \u00b7 7ms \u00b7 now \u00b7 agent");
            compare(OpenList.historyRows([], 100), []);
            compare(OpenList.historyRows(null, 100), []);
        }
        function test_durations_and_ages_are_short() {
            compare([0, 340, 999, 1000, 9960, 10000, 45000, 59999, 60000, 185000].map(OpenList.durationLabel),
                    ["0ms", "340ms", "999ms", "1s", "10s", "10s", "45s", "1m", "1m", "3m"]);
            compare([999.6, 999.4, 9949, 9950, 59499, 59500, -5, -0.4].map(OpenList.durationLabel),
                    ["1s", "999ms", "9.9s", "10s", "59s", "1m", "0ms", "0ms"]);       // the unit is picked after rounding; never negative
            compare(OpenList.durationLabel(NaN), "");
            compare([undefined, null, NaN, "x"].map(OpenList.ageLabel), ["", "", "", ""]);
            var odd = OpenList.historyRows([{ label: "x", status: "ok", ms: 5 }, { label: "y", status: "ok", ts: "soon" }], 100);
            compare(odd.map(function (r) { return r.sub; }), ["ok \u00b7 5ms", "ok"]);        // no NaN, no dangling separator
            compare(OpenList.durationLabel(undefined), "");
            compare([0, 9, 10, 59, 60, 3599, 3600, 7300].map(OpenList.ageLabel), ["now", "now", "10s", "59s", "1m", "59m", "1h", "2h"]);
            compare(OpenList.historyRows([{ label: "x", status: "ok", ms: 5, ts: 200 }], 100)[0].sub, "ok \u00b7 5ms \u00b7 now");   // a clock a little behind never goes negative
        }

        // ---- the list ----
        function test_a_row_click_says_which_row() {
            list.message = "";
            list.rows = [{ text: "src/app.ts", sub: "\u00d73" }, { text: "README.md", sub: "" }];     // its own rows, whatever ran before
            tryVerify(function () { return findChild(list, "row0") !== null && findChild(list, "row1") !== null; }, 3000);
            wait(60);                                       // the rows were rebuilt by an earlier test: let them lay out
            mouseClick(findChild(list, "row1"));
            compare(picks.count, 1);
            compare(picks.signalArguments[0][0], 1);
            mouseClick(findChild(list, "row0"));
            compare(picks.signalArguments[1][0], 0);
        }
        function test_rows_that_are_not_interactive_do_not_react_or_light_up() {
            list.message = "";
            list.rows = [{ text: "make build", sub: "err" }, { text: "npm test", sub: "ok" }];
            tryVerify(function () { return findChild(list, "row0") !== null; }, 3000);
            wait(60);
            list.interactive = false;
            picks.clear();
            mouseMove(findChild(list, "row0"), 10, 5);
            mouseClick(findChild(list, "row0"));
            compare(picks.count, 0);
            list.interactive = true;
            mouseClick(findChild(list, "row0"));
            compare(picks.count, 1);
            list.rows = [{ text: "src/app.ts", sub: "\u00d73" }, { text: "README.md", sub: "" }];
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
        function test_the_memory_listing_command_and_its_rows() {
            compare(OpenList.memoryListArgs("/s", "/h/p", "p"), ["python3", "-I", "/s", "list", "memory", "--cwd", "/h/p"]);
            compare(OpenList.memoryListArgs("/s", "", "p"), ["python3", "-I", "/s", "list", "memory", "--dir", "p"]);
            compare(OpenList.memoryListArgs("/s", "", ""), ["python3", "-I", "/s", "list", "memory"]);
            var rows = OpenList.memoryFileRows(["/h/.claude/projects/-h-p/memory/MEMORY.md", "/h/.claude/projects/-h-p/memory/topics/x.md", "/odd/place/y.md"]);
            compare(rows.map(function (r) { return r.text; }), ["MEMORY.md", "topics/x.md", "y.md"]);
            var r = OpenList.pathRows(["/h/.claude/projects/-h-p/memory/MEMORY.md", "/h/.claude/projects/-h-p/memory/a.md"], "memoryfiles", "/h", 10);
            compare(r.rows.map(function (x) { return x.text; }), ["MEMORY.md", "a.md"]);
        }
        function test_the_lookups_answer_is_read_defensively() {
            compare(OpenList.parsePaths('{"paths": ["/h/a.md", "/h/b.md"]}'), ["/h/a.md", "/h/b.md"]);
            compare(OpenList.parsePaths('{"paths": []}'), []);
            ["", "not json", "{", "null", "[]", '"x"', '{"paths": "x"}', '{"paths": null}', '{"other": 1}', "42"].forEach(function (t) {
                compare(OpenList.parsePaths(t), [], t);
            });
            compare(OpenList.parsePaths('{"paths": ["/ok", 5, null, "relative", {}]}'), ["/ok"]);        // only absolute path strings
        }
        function test_the_session_id_reaches_the_lookup_so_the_all_sessions_window_finds_files_too() {
            compare(OpenList.lookupArgs("/s", "files", "a/b", "", "proj", "abcd1234"),
                    ["python3", "-I", "/s", "resolve", "files", "a/b", "--sid", "abcd1234", "--dir", "proj"]);
            compare(OpenList.lookupArgs("/s", "files", "a/b", "/h/p", "proj", "abcd1234").slice(-2), ["--cwd", "/h/p"]);   // a known folder wins
            compare(OpenList.memoryListArgs("/s", "", "", "abcd1234"), ["python3", "-I", "/s", "list", "memory", "--sid", "abcd1234"]);
            compare(OpenList.memoryListArgs("/s", "", "", ""), ["python3", "-I", "/s", "list", "memory"]);
        }
        function test_a_lookups_answer_is_used_only_while_it_is_current_and_awaited() {
            verify(OpenList.accepts(3, 3, "note"));
            verify(!OpenList.accepts(2, 3, "note"));         // another lookup took over
            verify(!OpenList.accepts(3, 3, ""));              // the list was closed
            verify(!OpenList.accepts(3, 3, "items"));         // the user went back to a list of names
            verify(!OpenList.accepts(3, 4, "paths"));
        }
        function test_a_row_click_means_lookup_open_or_nothing() {
            var items = [{ label: "a.ts" }, { label: "b.ts" }];
            var paths = ["/h/a.ts", "/h/b.ts"];
            compare(OpenList.pickAction("items", 1, items, paths).action, "lookup");
            compare(OpenList.pickAction("items", 1, items, paths).item.label, "b.ts");
            compare(OpenList.pickAction("paths", 0, items, paths).action, "open");
            compare(OpenList.pickAction("paths", 0, items, paths).path, "/h/a.ts");
            compare(OpenList.pickAction("paths", 2, items, paths).action, "none");      // the "... and N more" row
            compare(OpenList.pickAction("items", 5, items, paths).action, "none");
            compare(OpenList.pickAction("note", 0, items, paths).action, "none");
            compare(OpenList.pickAction("", 0, items, paths).action, "none");
            compare(OpenList.pickAction("items", 0, null, null).action, "none");
        }
        function test_the_lookup_command_has_each_part_as_one_argument() {
            var a = OpenList.lookupArgs("/x/openable.py", "files", "src/my file; rm -rf.ts", "/home/ww/proj", "proj");
            compare(a, ["python3", "-I", "/x/openable.py", "resolve", "files", "src/my file; rm -rf.ts", "--cwd", "/home/ww/proj"]);
        }
        function test_the_sessions_folder_wins_over_its_name_and_either_may_be_missing() {
            compare(OpenList.lookupArgs("/s", "skills", "omarchy", "", "proj"), ["python3", "-I", "/s", "resolve", "skills", "omarchy", "--dir", "proj"]);
            compare(OpenList.lookupArgs("/s", "memory", "m/x.md", "", ""), ["python3", "-I", "/s", "resolve", "memory", "m/x.md"]);
            compare(OpenList.lookupArgs("/s", "files", "a/b", "/h/p", "").slice(-2), ["--cwd", "/h/p"]);
        }
        function test_more_than_ten_files_show_ten_and_say_how_many_more() {
            var many = [];
            for (var i = 0; i < 13; i++) many.push("/home/ww/p" + i + "/f.md");
            var r = OpenList.pathRows(many, "files", "/home/ww", 10);
            compare(r.paths.length, 10);
            compare(r.rows.length, 11);
            compare(r.rows[10].text, "\u2026 and 3 more");
            compare(r.paths[10], undefined);                      // the extra row opens nothing
            var few = OpenList.pathRows(many.slice(0, 3), "files", "/home/ww", 10);
            compare(few.rows.length, 3);
        }
        function test_memory_files_are_listed_by_project_and_others_by_their_endings() {
            var m = OpenList.pathRows(["/home/ww/.claude/projects/-home-ww-Work-a/memory/MEMORY.md", "/home/ww/.claude/projects/-home-ww-Work-b/memory/MEMORY.md"], "memory", "/home/ww", 10);
            compare(m.rows.map(function (x) { return x.text; }), ["Work-a", "Work-b"]);
            var f = OpenList.pathRows(["/home/ww/a/f.md", "/home/ww/b/f.md"], "files", "/home/ww", 10);
            compare(f.rows.map(function (x) { return x.text; }), ["\u2026/a/f.md", "\u2026/b/f.md"]);
        }
        function test_paths_are_shown_with_the_home_folder_as_a_tilde() {
            compare(OpenList.shorten("/home/ww/Work/a.md", "/home/ww"), "~/Work/a.md");
            compare(OpenList.shorten("/etc/x", "/home/ww"), "/etc/x");
            compare(OpenList.shorten("/home/wwx/a", "/home/ww"), "/home/wwx/a");
            compare(OpenList.shorten("/home/ww/a", ""), "/home/ww/a");
        }

        // ---- Network: hosts and MCP servers ----
        function net(id, label, tool, ts) {
            parent.fold({ ts: ts || 3, ev: "tool_end", id: id, station: "network", label: label, tool: tool, status: "ok" });
        }
        function sessNow() { return parent.board.sessions["aaaaaaaa"]; }
        function test_network_groups_hosts_and_mcp_servers_with_counts() {
            net("a", "docs.python.org", "WebFetch", 3);
            net("b", "example.com", "WebFetch", 4);
            net("c", "docs.python.org", "WebFetch", 5);
            net("d", "gh: list issues", "mcp__gh__list_issues", 6);
            net("e", "gh: get pr", "mcp__gh__get_pr", 7);
            net("f", "web search", "WebSearch", 8);
            net("g", "artifact", "Artifact", 9);
            var items = OpenList.networkItems(sessNow(), "network", 12);
            compare(items.map(function (i) { return i.label + ":" + i.kind + ":" + i.count; }),
                    ["gh:mcp:2", "docs.python.org:host:2", "example.com:host:1"]);   // newest first; search and artifact name no host
            compare(items[0].host, undefined);
            compare(items[1].host, "docs.python.org");
        }
        function test_network_never_offers_a_label_that_is_not_a_plain_hostname() {
            ["https://evil.com", "a b.com", "-x.com", "x.com/p", "web fetch", "a.com;id", "b\u00fccher.de"].forEach(function (l, i) {
                net("h" + i, l, "WebFetch");
            });
            compare(OpenList.networkItems(sessNow(), "network", 12).length, 0);
            verify(!OpenList.canOpen("network", sessNow(), Board));
        }
        function test_network_is_clickable_once_there_is_a_host_or_a_server() {
            net("a", "web search", "WebSearch");
            compare(area("network").cursorShape !== Qt.PointingHandCursor, true);
            net("b", "example.com", "WebFetch");
            compare(area("network").cursorShape, Qt.PointingHandCursor);
        }
        function test_a_label_at_the_emitters_40_character_cap_may_be_cut_short_and_is_not_offered() {
            var cut = "a".repeat(30) + ".example.com";                 // 42 characters
            var edge = "a".repeat(27) + ".example.com";                // 39: fine
            var at40 = "a".repeat(28) + ".example.com";                // 40: could be a cut label
            net("a", cut, "WebFetch"); net("b", at40, "WebFetch");
            verify(!OpenList.canOpen("network", sessNow(), Board));
            net("c", edge, "WebFetch");
            compare(OpenList.networkItems(sessNow(), "network", 12).map(function (i) { return i.label; }), [edge]);
            verify(OpenList.canOpen("network", sessNow(), Board));
        }
        function test_a_single_host_is_still_listed_not_opened_at_once() {
            net("a", "example.com", "WebFetch");
            var d = OpenList.onClick("network", sessNow(), Board);
            compare(d.action, "list");
            compare(d.rows, [{ text: "example.com", sub: "" }]);
        }
        function test_a_pick_opens_a_host_and_nothing_else() {
            net("a", "example.com", "WebFetch", 3);
            net("b", "gh: x", "mcp__gh__x", 4);
            net("c", "gh: y", "mcp__gh__y", 5);
            var d = OpenList.onClick("network", sessNow(), Board);
            compare(d.rows.map(function (r) { return r.text + "|" + r.sub; }), ["gh|MCP \u00b7 \u00d72", "example.com|"]);
            compare(OpenList.pickAction("items", 0, d.items, []), { action: "mcp" });             // the server: a toast, nothing opens
            compare(OpenList.pickAction("items", 1, d.items, []), { action: "openhost", host: "example.com" });
            compare(OpenList.pickAction("items", 2, d.items, []), { action: "none" });            // no such row
            // a host that is not plain is refused even if an item claims it
            compare(OpenList.pickAction("items", 0, [{ action: "openhost", host: "a b.com" }], []), { action: "refused" });
            compare(OpenList.pickAction("items", 0, [{ action: "openhost", host: "-o.com" }], []), { action: "refused" });
            // another station's items never become a host open, whatever else they carry
            compare(OpenList.pickAction("items", 0, [{ label: "x.com", host: "x.com", kind: "host" }], []).action, "lookup");
        }
        function test_isHost_refuses_hostile_input() {
            ["example.com", "a-b.example.org", "xn--bcher-kva.de", "1.2.3.4"].forEach(function (h) { verify(OpenList.isHost(h), h); });
            ["", "localhost", "a b.com", "https://a.com", "-a.com", "a.-b.com", "a-.com", "a.com.", "a..com", ".a.com",
             "a.com/x", "a.com:80", "u@a.com", "a.com\n", "a\u0000.com", "a\u001b.com", "b\u00fccher.de", "a_b.com", "$(x).com",
             "a.com;id", null, undefined, 5].forEach(function (h) { verify(!OpenList.isHost(h), String(h)); });
        }
        function test_the_open_command_is_one_list_with_the_host_as_one_argument() {
            compare(OpenList.openHostArgs("/s/openhost.py", "example.com"), ["python3", "-I", "/s/openhost.py", "open", "example.com"]);
        }
    }
}
