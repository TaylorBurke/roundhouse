// Run with:  QT_QPA_PLATFORM=offscreen qml6 tests/board.test.qml
import QtQuick
import "../ui/board.js" as Board

QtObject {
    id: root
    property int failures: 0

    function check(name, got, want) {
        if (JSON.stringify(got) !== JSON.stringify(want)) {
            failures++;
            console.log("FAIL " + name + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want));
        }
    }
    function ev(o) { return Object.assign({ sid: "s1", ts: 1 }, o); }
    function sess(b, sid) { return b.sessions[sid || "s1"]; }

    Component.onCompleted: {
        var b, s;

        // pairing by id, in order
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "a", station: "files", label: "x", tool: "Read" }));
        s = sess(b);
        check("running", [s.entries[0].status, s.stations.files.running], ["running", 1]);
        Board.fold(b, ev({ ts: 2, ev: "tool_end", id: "a", station: "files", label: "x", tool: "Read", status: "ok", ms: 6 }));
        check("paired", [s.entries.length, s.entries[0].status, s.entries[0].ms, s.stations.files.running], [1, "ok", 6, 0]);
        check("count", [s.stations.files.count, s.stations.shell.count], [1, 0]);

        // end before start, then the start lands: one entry, result kept
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 2, ev: "tool_end", id: "a", station: "shell", label: "x", tool: "Bash", status: "err", ms: 9 }));
        Board.fold(b, ev({ ts: 1.9, ev: "tool_start", id: "a", station: "shell", label: "x", tool: "Bash" }));
        s = sess(b);
        check("end first", [s.entries.length, s.entries[0].status], [1, "err"]);
        check("end first errors", s.stations.shell.errors, 1);

        // end without any start
        b = Board.newBoard();
        Board.fold(b, ev({ ev: "tool_end", id: "z", station: "network", label: "host", tool: "WebFetch", status: "ok" }));
        check("orphan end", [sess(b).entries.length, sess(b).entries[0].status], [1, "ok"]);

        // refused call: batch marks it blocked, a late end frees it
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "r", station: "files", label: "f", tool: "Edit" }));
        Board.fold(b, ev({ ts: 2, ev: "batch" }));
        s = sess(b);
        check("blocked", [s.entries[0].status, s.stations.files.blocked], ["blocked", 1]);
        Board.fold(b, ev({ ts: 2.01, ev: "tool_end", id: "r", station: "files", label: "f", tool: "Edit", status: "ok" }));
        check("unblocked", [s.entries[0].status, s.stations.files.blocked], ["ok", 0]);

        // stop blocks too; a call started after the batch is untouched
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "r", station: "files", label: "f", tool: "Edit" }));
        Board.fold(b, ev({ ts: 3, ev: "tool_start", id: "n", station: "files", label: "g", tool: "Edit" }));
        Board.fold(b, ev({ ts: 2, ev: "stop", bg: [] }));
        s = sess(b);
        check("stop", [s.entries.filter(function (e) { return e.id === "r"; })[0].status, s.entries.filter(function (e) { return e.id === "n"; })[0].status], ["blocked", "running"]);

        // background call stays open; its task runs, then ends
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "g", station: "shell", label: "sleep", tool: "Bash", bg: true }));
        Board.fold(b, ev({ ts: 1.1, ev: "batch" }));
        check("bg not blocked", sess(b).entries[0].status, "running");
        Board.fold(b, ev({ ts: 1.2, ev: "tool_end", id: "g", station: "shell", label: "sleep", tool: "Bash", status: "ok", task: "t1" }));
        check("bg task", sess(b).tasks.t1.status, "running");
        Board.fold(b, ev({ ts: 5, ev: "task_end", task: "t1", status: "ok" }));
        check("bg task done", sess(b).tasks.t1.status, "ok");

        // a subagent's batch does not block the main loop's open call
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "m", station: "agents", label: "sub", tool: "Agent" }));
        Board.fold(b, ev({ ts: 2, ev: "batch", agent: "a1" }));
        check("agent batch", sess(b).entries[0].status, "running");

        // last 80 entries, with ids evicted
        b = Board.newBoard();
        for (var i = 0; i < 100; i++) Board.fold(b, ev({ ts: 10 + i, ev: "tool_end", id: "t" + i, station: "files", label: "x", tool: "Read", status: "ok" }));
        s = sess(b);
        check("cap", [s.entries.length, s.byId.t0, s.byId.t99 !== undefined], [80, undefined, true]);

        // a replay after the log was cut back changes nothing
        var before = JSON.stringify(s.entries);
        for (i = 50; i < 100; i++) Board.fold(b, ev({ ts: 10 + i, ev: "tool_end", id: "t" + i, station: "files", label: "x", tool: "Read", status: "ok" }));
        check("replay", JSON.stringify(s.entries), before);

        // damaged and blank lines are ignored
        check("junk", [Board.foldLine(b, ""), Board.foldLine(b, "{not json"), Board.foldLine(b, "[1]"), Board.foldLine(b, "{}")], [false, false, false, false]);

        // most recently active session wins
        b = Board.newBoard();
        Board.fold(b, { sid: "old", ts: 1, ev: "prompt" });
        Board.fold(b, { sid: "new", ts: 5, ev: "prompt" });
        Board.fold(b, { sid: "old", ts: 3, ev: "stop", bg: [] });
        check("active", b.active, "new");
        Board.fold(b, { sid: "old", ts: 9, ev: "prompt" });
        check("active moves", b.active, "old");

        // model event beats a stale context reading until the next prompt
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "context", tokens: 100, model: "sonnet" }));
        Board.fold(b, ev({ ts: 2, ev: "model", from: "sonnet", to: "haiku" }));
        Board.fold(b, ev({ ts: 3, ev: "context", tokens: 120, model: "sonnet" }));
        check("model stale", [sess(b).model, sess(b).tokens], ["haiku", 120]);
        Board.fold(b, ev({ ts: 4, ev: "prompt" }));
        Board.fold(b, ev({ ts: 5, ev: "context", tokens: 130, model: "haiku" }));
        check("model fresh", sess(b).model, "haiku");

        // subagents and compaction
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "agent_start", type: "Explore", agent: "a1" }));
        check("agent running", sess(b).agents.a1.running, true);
        Board.fold(b, ev({ ts: 2, ev: "agent_end", type: "Explore", agent: "a1" }));
        check("agent done", sess(b).agents.a1.running, false);
        Board.fold(b, ev({ ts: 3, ev: "compact_start", trigger: "manual" }));
        check("compacting", sess(b).stations.model.running, 1);
        Board.fold(b, ev({ ts: 4, ev: "compact_end", trigger: "manual" }));
        check("compacted", sess(b).stations.model.running, 0);

        console.log(failures === 0 ? "board tests: all passed" : "board tests: " + failures + " FAILED");
        Qt.exit(failures === 0 ? 0 : 1);
    }
}
