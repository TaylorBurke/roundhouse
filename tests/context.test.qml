// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/context.test.qml
// The hub's context panel: the hub click and its cheap check, parsing a canned answer of
// tools/transcript.py context, the thinned sparkline, the compaction rows and the honest caveat line.
import QtQuick
import QtTest
import "../ui"
import "../ui/board.js" as Board
import "../ui/contextpanel.js" as Panel

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
    SignalSpy { id: hubs; target: map; signalName: "hubClicked" }
    SignalSpy { id: nodes; target: map; signalName: "nodeClicked" }

    ContextPanel {
        id: panel
        y: 365; x: 8
        reading: 98000; windowSize: 200000
    }

    function canned(extra) {
        var pts = [];
        for (var i = 0; i < 200; i++) pts.push({ ts: "t" + i, tokens_in: 1000 * (i + 1), tokens_out: 5 });
        var j = { sid: "aaaaaaaa", found: true, context: { points: pts, point_count: 200, peak: 200000,
                  compactions: [{ ts: "2026-11-18T14:02:00Z", trigger: "auto", pre_tokens: 168000, post_tokens: 21000 },
                                { ts: "2026-11-18T15:30:00Z", trigger: "manual", pre_tokens: 90000, post_tokens: 0 }],
                  partial: false } };
        for (var k in extra) { if (k === "partial") j.context.partial = extra[k]; else j[k] = extra[k]; }
        return JSON.stringify(j);
    }

    TestCase {
        name: "HubContext"
        when: windowShown

        function init() {
            parent.board = Board.newBoard();
            parent.fold({ ts: 1, ev: "session", dir: "proj", model: "claude-sonnet-5-5" });
            hubs.clear(); nodes.clear();
        }
        function hub() { return findChild(map, "hub"); }
        function clickHub() { var h = hub(); mouseClick(map, h.x + h.width / 2, h.y + h.height / 2); }

        // ---- the hub click ----
        function test_hub_needs_something_to_show() {
            parent.board = Board.newBoard();
            parent.rev++;
            compare(map.canClickHub, false);
            compare(hub().acceptedButtons, Qt.NoButton);
            clickHub();
            compare(hubs.count, 0);
        }
        function test_hub_clickable_with_a_context_reading() {
            parent.fold({ ts: 2, ev: "context", tokens: 50000 });
            compare(map.canClickHub, true);
            compare(hub().cursorShape, Qt.PointingHandCursor);
            clickHub();
            compare(hubs.count, 1);
            compare(nodes.count, 0);
        }
        function test_hub_clickable_with_logged_calls() {
            parent.fold({ ts: 2, ev: "prompt" });
            compare(map.canClickHub, true);
            clickHub();
            compare(hubs.count, 1);
        }
        function test_hub_cheap_check_is_in_memory() {
            compare(Panel.canClickHub(null), false);
            compare(Panel.canClickHub({ hasContext: false, entries: [] }), false);
            compare(Panel.canClickHub({ hasContext: true, entries: [] }), true);
            compare(Panel.canClickHub({ hasContext: false, entries: [{}] }), true);
        }

        // ---- the answer ----
        function test_parse_canned_answer() {
            var d = Panel.parse(canned({}));
            compare(d.found, true);
            compare(d.points.length, 200);
            compare(d.peak, 200000);
            compare(d.count, 200);
            compare(d.compactions.length, 2);
            compare(d.compactions[0].pre, 168000);
            compare(d.partial, false); compare(d.capped, false); compare(d.ambiguous, false);
        }
        function test_count_absent_is_null_and_omitted() {
            var d = Panel.parse('{"found":true,"context":{"points":[{"tokens_in":5},{"tokens_in":9}],"peak":9}}');
            compare(d.count, null);
            panel.info = d;
            compare(findChild(panel, "summary").text.indexOf("calls"), -1);
        }
        function test_bad_last_point_does_not_zero_now() {
            var d = Panel.parse('{"found":true,"context":{"points":[{"tokens_in":5000},{"tokens_in":9000},{"tokens_in":null}],"peak":9000,"point_count":3}}');
            compare(d.points.join(","), "5000,9000");
            panel.reading = 0;
            panel.info = d;
            compare(panel.now, 9000);
            compare(findChild(panel, "summary").text, "now 9k of 200k  ·  peak 9k  ·  3 model calls");
            panel.reading = 98000;
        }
        function test_parse_flags() {
            var d = Panel.parse(canned({ partial: true, capped: true, ambiguous: true }));
            compare(d.partial, true); compare(d.capped, true); compare(d.ambiguous, true);
        }
        function test_parse_not_found_and_garbage() {
            compare(Panel.parse('{"sid":"aaaaaaaa","found":false}').found, false);
            compare(Panel.parse('{"found":false,"error":"unreadable"}').found, false);
            compare(Panel.parse("").found, false);
            compare(Panel.parse("Traceback ...").found, false);
            compare(Panel.parse('{"found":true}').found, false);
            compare(Panel.parse('[1]').found, false);
        }
        function test_parse_survives_odd_values() {
            var d = Panel.parse('{"found":true,"context":{"points":[{"tokens_in":"x"},null,{"tokens_in":-5},{"tokens_in":7}],"peak":"big","compactions":[1,{"ts":3}]}}');
            compare(d.found, true);
            compare(d.points.join(","), "7");          // invalid points are dropped, not zeroed
            compare(d.peak, 0);
            compare(d.compactions.length, 1);
            compare(d.compactions[0].ts, "");
        }

        // ---- thinning, labels, rows ----
        function test_thin_keeps_ends_and_size() {
            var pts = []; for (var i = 0; i < 300; i++) pts.push(i);
            var t = Panel.thin(pts, 60);
            compare(t.length, 60);
            compare(t[0], 0); compare(t[59], 299);
            compare(Panel.thin([1, 2, 3], 60).length, 3);
            compare(Panel.thin([], 60).length, 0);
        }
        function test_token_labels() {
            compare(Panel.tok(950), "950");
            compare(Panel.tok(12400), "12k");
            compare(Panel.tok(168000), "168k");
            compare(Panel.tok(1250000), "1.3M");
            compare(Panel.tok(undefined), "0");
        }
        function test_compaction_rows_newest_first() {
            var rows = Panel.compactionRows(Panel.parse(canned({})).compactions);
            compare(rows.length, 2);
            compare(rows[0].sub, "90k → ?");          // the newest, after-size unknown
            verify(rows[0].text.indexOf("manual") >= 0);
            compare(rows[1].sub, "168k → 21k");
            verify(rows[1].text.indexOf("auto") >= 0);
        }
        function test_compaction_rows_are_limited() {
            var list = []; for (var i = 0; i < 8; i++) list.push({ ts: "", trigger: "auto", pre: 1000, post: 500 });
            var rows = Panel.compactionRows(list);
            compare(rows.length, 6);
            compare(rows[5].text, "… and 3 more");
        }
        function test_note_is_honest() {
            compare(Panel.note({}), "");
            verify(Panel.note({ partial: true }).indexOf("end of a very large transcript") >= 0);
            verify(Panel.note({ capped: true }).indexOf("dropped") >= 0);
            verify(Panel.note({ ambiguous: true }).indexOf("everal sessions") >= 0);
        }
        function test_command_is_a_list_with_eight_chars() {
            var a = Panel.args("/x/transcript.py", "abcdef0123456789");
            compare(a.join(" "), "python3 -I /x/transcript.py context abcdef01");
        }

        // ---- the panel ----
        function test_panel_shows_numbers_and_compactions() {
            panel.info = Panel.parse(canned({}));
            compare(panel.spark.length, 60);
            compare(findChild(panel, "summary").text, "now 98k of 200k  ·  peak 200k  ·  200 model calls");
            compare(findChild(panel, "caveat").visible, false);
            compare(panel.rows.length, 2);
            compare(findChild(panel, "compactionsTitle").text, "compactions");
            verify(panel.width <= 300);
        }
        function test_panel_caveat_and_no_compactions() {
            panel.info = Panel.parse(canned({ partial: true, capped: true }));
            compare(findChild(panel, "caveat").visible, true);
            var j = JSON.parse(canned({})); j.context.compactions = [];
            panel.info = Panel.parse(JSON.stringify(j));
            compare(findChild(panel, "compactionsTitle").text, "no compactions");
        }
        function test_panel_without_reading_uses_last_point() {
            panel.reading = 0;
            panel.info = Panel.parse(canned({}));
            compare(panel.now, 200000);
            panel.reading = 98000;
        }
        function test_panel_renders() {
            panel.info = Panel.parse(canned({}));
            var img = null;
            panel.grabToImage(function (r) { img = r; });
            tryVerify(function () { return img !== null; });
            verify(panel.height > 50); verify(img.url !== "");
        }
    }
}
