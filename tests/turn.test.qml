// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/turn.test.qml
// The Model station's turn panel: the handler's cheap check, how tools/transcript.py's answer becomes rows
// (a canned JSON), the panel itself, and that nothing of the transcript ever reaches a command.
import QtQuick
import QtTest
import "../ui"
import "../ui/board.js" as Board
import "../ui/openlist.js" as OpenList
import "../ui/turn.js" as Turn

Item {
    width: 360; height: 460

    property var canned: ({
        sid: "aaaaaaaa", found: true, path: "/x/aaaaaaaa.jsonl", truncated: false,
        turn: {
            duration_ms: 12500, step_count: 10,
            totals: { think_ms: 3000, tokens_out: 900, tokens_in_last: 50000, exact: true }, partial: false,
            steps: [
                { think_ms: 1200, thinking: "plan <b>the</b> edit\nfirst", redacted: false, tokens_in: 12345, tokens_out: 321, tools: ["Read", "Edit"] },
                { think_ms: 400, thinking: null, redacted: true, tokens_in: 100, tokens_out: 5, tools: [] },
                { think_ms: 0, thinking: null, redacted: false, tokens_in: 1, tokens_out: 1, tools: [] }
            ]
        }
    })

    TurnPanel {
        id: panel
        x: 8; y: 8
    }
    SignalSpy { id: raw; target: panel; signalName: "openRaw" }

    TestCase {
        name: "TurnPanel"
        when: windowShown

        function test_model_opens_when_the_session_has_any_entry() {
            var b = Board.newBoard();
            Board.fold(b, { v: 1, sid: "aaaaaaaa", ts: 1, ev: "session", dir: "p", model: "m" });
            Board.fold(b, { v: 1, sid: "aaaaaaaa", ts: 2, ev: "prompt" });
            Board.fold(b, { v: 1, sid: "aaaaaaaa", ts: 3, ev: "tool_end", id: "a", station: "files", label: "x.ts", tool: "Read", status: "ok" });
            var sess = b.sessions["aaaaaaaa"];
            verify(sess.entries.length > 0);
            verify(OpenList.canOpen("model", sess, Board));
            verify(!OpenList.canOpen("model", null, Board));
            verify(!OpenList.canOpen("model", { entries: [] }, Board));
            compare(OpenList.onClick("model", sess, Board).action, "turn");
        }
        function test_can_does_not_need_items() {
            compare(typeof OpenList.HANDLERS.model.can, "function");
            compare(OpenList.HANDLERS.model.items, undefined);
        }

        function test_parse_rows() {
            var t = Turn.parse(JSON.stringify(canned));
            verify(t.found);
            compare(t.steps.length, 3);
            compare(t.steps[0].head, "think 1.2s · in 12,345 · out 321");
            compare(t.steps[0].tools, "Read, Edit");
            compare(t.steps[0].text, "plan <b>the</b> edit first");
            compare(t.steps[1].text, "(reasoning redacted)");
            compare(t.steps[2].text, "");
            compare(t.note, "showing the last 3 of 10 steps");
        }
        function test_only_the_last_steps_and_the_first_400_chars_are_shown() {
            var c = JSON.parse(JSON.stringify(canned));
            c.turn.steps = [];
            for (var i = 0; i < 12; i++) c.turn.steps.push({ think_ms: i, thinking: "y".repeat(1000), tokens_in: i, tokens_out: 0, tools: [] });
            c.turn.step_count = 12;
            var t = Turn.parse(JSON.stringify(c));
            compare(t.steps.length, 8);
            compare(t.steps[7].text.length, 400);
            verify(t.steps[0].head.indexOf("in 4 ") > 0);
        }
        function test_honest_notes() {
            var c = JSON.parse(JSON.stringify(canned));
            c.turn.step_count = 3; c.turn.partial = true; c.turn.totals.exact = false; c.capped = true; c.ambiguous = true;
            var n = Turn.parse(JSON.stringify(c)).note;
            verify(n.indexOf("partial") >= 0);
            verify(n.indexOf("capped") >= 0);
            verify(n.indexOf("several sessions") >= 0);
        }
        function test_missing_and_unreadable() {
            compare(Turn.parse('{"found": false}').error, "missing");
            compare(Turn.parse('{"found": false, "error": "unreadable"}').error, "unreadable");
            compare(Turn.parse("").error, "unreadable");
            compare(Turn.parse("not json").found, false);
            compare(Turn.parse('{"found": true}').found, false);
        }
        function test_commands_carry_only_the_session_id() {
            compare(Turn.turnArgs("/t.py", "aaaaaaaa").join(" "), "python3 -I /t.py turn aaaaaaaa");
            compare(Turn.openArgs("/t.py", "aaaaaaaa").join(" "), "python3 -I /t.py open aaaaaaaa");
            verify(Turn.validSid("abcd-_12"));
            verify(!Turn.validSid("abc"));
            verify(!Turn.validSid("abcdefg; x"));
            verify(!Turn.validSid("../../etc"));
        }

        function test_panel_shows_the_steps_plain_and_the_button_signals() {
            var t = Turn.parse(JSON.stringify(canned));
            panel.summary = t.summary; panel.note = t.note; panel.steps = t.steps;
            wait(50);
            verify(panel.width <= 344);
            verify(panel.x + panel.width <= 360);
            compare(findChild(panel, "note").text, "showing the last 3 of 10 steps");
            var r = findChild(panel, "step0").children;
            var reasoning = null;
            for (var i = 0; i < r.length; i++) if (r[i].objectName === "reasoning") reasoning = r[i];
            verify(reasoning !== null);
            compare(reasoning.textFormat, Text.PlainText);
            compare(reasoning.text, "plan <b>the</b> edit first");
            var b = findChild(panel, "openRaw");
            raw.clear();
            mouseClick(b);
            compare(raw.count, 1);
        }
        function test_panel_stays_inside_the_window_when_long() {
            var many = [];
            for (var i = 0; i < 8; i++) many.push({ head: "think 1s · in 1 · out 1", text: "z".repeat(400), tools: "Read" });
            panel.steps = many; panel.maxHeight = 300;
            wait(50);
            verify(panel.height <= 300);
        }
    }
}
