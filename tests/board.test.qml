// Run with:  QT_QPA_PLATFORM=offscreen qml6 tests/board.test.qml
import QtQuick
import "../ui/board.js" as Board
import "../ui/theme.js" as Theme

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

        // a background call ends at once (its task keeps running); one that never ends was refused
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "g", station: "shell", label: "sleep", tool: "Bash", bg: true }));
        Board.fold(b, ev({ ts: 1.2, ev: "tool_end", id: "g", station: "shell", label: "sleep", tool: "Bash", status: "ok", task: "t1" }));
        Board.fold(b, ev({ ts: 1.3, ev: "batch" }));
        check("bg ended", sess(b).entries.filter(function (e) { return e.id === "g"; })[0].status, "ok");
        check("bg task", sess(b).tasks.t1.status, "running");
        Board.fold(b, ev({ ts: 5, ev: "task_end", task: "t1", status: "ok" }));
        check("bg task done", sess(b).tasks.t1.status, "ok");
        Board.fold(b, ev({ ts: 6, ev: "tool_start", id: "h", station: "shell", label: "sleep", tool: "Bash", bg: true }));
        Board.fold(b, ev({ ts: 7, ev: "batch" }));
        check("bg refused", sess(b).entries.filter(function (e) { return e.id === "h"; })[0].status, "blocked");

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

        // the session shown: the most recently active live one, a live pin, dropped when ended or idle
        b = Board.newBoard();
        Board.fold(b, { sid: "old", ts: 1, ev: "prompt" });
        Board.fold(b, { sid: "new", ts: 5, ev: "prompt" });
        Board.fold(b, { sid: "old", ts: 3, ev: "stop", bg: [] });
        check("active", Board.activeSid(b, "", 10), "new");
        Board.fold(b, { sid: "old", ts: 9, ev: "prompt" });
        check("active moves", Board.activeSid(b, "", 10), "old");
        check("pinned wins", Board.activeSid(b, "new", 10), "new");
        check("pin on an unknown session is ignored", Board.activeSid(b, "nope", 10), "old");
        Board.fold(b, { sid: "new", ts: 11, ev: "session_end", reason: "other" });
        check("ended pin falls back", [Board.activeSid(b, "new", 12), Board.liveSessions(b, 12).map(function (s) { return s.sid; })], ["old", ["old"]]);
        Board.fold(b, { sid: "old", ts: 13, ev: "session_end", reason: "other" });
        check("none live: most recent of all", [Board.activeSid(b, "", 14), Board.liveSessions(b, 14).length], ["old", 0]);
        check("nothing at all", Board.activeSid(Board.newBoard(), "", 1), null);
        b = Board.newBoard();
        Board.fold(b, { sid: "a", ts: 100, ev: "prompt" });
        Board.fold(b, { sid: "b", ts: 200, ev: "prompt" });
        Board.fold(b, { sid: "c", ts: 300, ev: "prompt" });
        check("idle drop", Board.liveSessions(b, 100 + 1799).map(function (s) { return s.sid; }), ["a", "b", "c"]);
        check("idle drop 2", Board.liveSessions(b, 100 + 1800).map(function (s) { return s.sid; }), ["b", "c"]);
        check("order is first sight, not activity", (Board.fold(b, { sid: "a", ts: 400, ev: "prompt" }), Board.liveSessions(b, 500).map(function (s) { return s.sid; })), ["a", "b", "c"]);
        check("cycle", [Board.cycleSid(b, "a", 1, 500), Board.cycleSid(b, "c", 1, 500), Board.cycleSid(b, "a", -1, 500), Board.cycleSid(b, "zzz", 1, 500)], ["b", "a", "c", "a"]);
        check("cycle with none", Board.cycleSid(Board.newBoard(), "x", 1, 1), "x");
        check("idle label", [Board.idleLabel(3), Board.idleLabel(40), Board.idleLabel(300), Board.idleLabel(7300)], ["now", "40s", "5m", "2h"]);

        // why a session ended is kept: a /clear is not the end of the conversation
        b = Board.newBoard();
        Board.fold(b, { sid: "e", ts: 1, ev: "session", dir: "x" });
        Board.fold(b, { sid: "e", ts: 2, ev: "session_end", reason: "clear" });
        check("end reason", [sess(b, "e").ended, sess(b, "e").endReason], [true, "clear"]);
        Board.fold(b, { sid: "e", ts: 3, ev: "session", dir: "x" });
        check("end reason resets", [sess(b, "e").ended, sess(b, "e").endReason], [false, ""]);

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

        // foldLine hands back the event, and newlyBlocked names what just got blocked
        b = Board.newBoard();
        var got = Board.foldLine(b, JSON.stringify({ sid: "s1", ts: 1, ev: "tool_start", id: "q", station: "files", label: "f", tool: "Edit" }));
        check("foldLine event", got.ev, "tool_start");
        check("foldLine replay", Board.foldLine(b, JSON.stringify({ sid: "s1", ts: 1, ev: "tool_start", id: "q", station: "files", label: "f", tool: "Edit" })), false);
        Board.fold(b, ev({ ts: 2, ev: "batch" }));
        check("newlyBlocked", sess(b).newlyBlocked, [{ station: "files", label: "f" }]);
        Board.fold(b, ev({ ts: 3, ev: "prompt" }));
        check("newlyBlocked resets", sess(b).newlyBlocked, []);

        // the current-action line
        b = Board.newBoard();
        check("action none", Board.currentAction(null), "waiting for events");
        Board.fold(b, ev({ ts: 1, ev: "prompt" }));
        check("action idle", Board.currentAction(sess(b)), "idle");
        Board.fold(b, ev({ ts: 2, ev: "tool_start", id: "1", station: "files", label: "a.ts", tool: "Read" }));
        Board.fold(b, ev({ ts: 3, ev: "tool_start", id: "2", station: "files", label: "b.ts", tool: "Read" }));
        Board.fold(b, ev({ ts: 4, ev: "tool_start", id: "3", station: "files", label: "c.ts", tool: "Read" }));
        check("action same", Board.currentAction(sess(b)), "Files: c.ts and 2 more");
        Board.fold(b, ev({ ts: 5, ev: "tool_start", id: "4", station: "network", label: "example.com", tool: "WebFetch" }));
        check("action elsewhere", Board.currentAction(sess(b)), "Network: example.com \u00b7 +3 elsewhere");

        // the feed: finished rows at one station fold, running and failed ones never do, 16 rows at most
        b = Board.newBoard();
        for (i = 0; i < 5; i++) Board.fold(b, ev({ ts: 1 + i, ev: "tool_end", id: "f" + i, station: "files", label: "n" + i, tool: "Read", status: "ok" }));
        var rows = Board.feedRows(sess(b), 16);
        check("fold", [rows.length, rows[0].label, rows[0].extra, rows[0].mark], [1, "n4", 4, "\u00b7"]);
        Board.fold(b, ev({ ts: 10, ev: "tool_end", id: "bad", station: "files", label: "x", tool: "Read", status: "err" }));
        Board.fold(b, ev({ ts: 11, ev: "tool_start", id: "run", station: "files", label: "y", tool: "Read" }));
        Board.fold(b, ev({ ts: 12, ev: "tool_end", id: "ok2", station: "files", label: "z", tool: "Read", status: "ok" }));
        rows = Board.feedRows(sess(b), 16);
        check("no fold across", rows.map(function (r) { return r.mark + r.label + r.extra; }), ["\u00b7z0", "\u25cfy0", "\u2715x0", "\u00b7n44"]);
        b = Board.newBoard();
        for (i = 0; i < 40; i++) Board.fold(b, ev({ ts: 1 + i, ev: "tool_end", id: "m" + i, station: i % 2 ? "files" : "shell", label: "n" + i, tool: "Read", status: "ok" }));
        check("rows cap", [Board.feedRows(sess(b), 16).length, Board.feedRows(sess(b), 16)[0].label], [16, "n39"]);

        // context window: setting, guess from the model name, never smaller than the contents
        check("parse", [Board.parseWindow(1000000), Board.parseWindow("1m"), Board.parseWindow("200K"), Board.parseWindow("1.5m"), Board.parseWindow("auto"), Board.parseWindow(5), Board.parseWindow(null)], [1000000, 1000000, 200000, 1500000, 0, 0, 0]);
        check("size auto", [Board.windowSize("claude-sonnet-5-5", 100, 0), Board.windowSize("claude-opus-5-5[1m]", 100, 0), Board.windowSize("claude-opus-5-5-1m", 100, 0), Board.windowSize("claude-haiku-5-5", 100, 0)], [200000, 1000000, 1000000, 200000]);
        check("size override", [Board.windowSize("claude-sonnet-5-5", 100, 1000000), Board.windowSize("claude-opus-5-5[1m]", 100, 200000)], [1000000, 200000]);
        check("size grows", Board.windowSize("claude-sonnet-5-5", 250000, 0), 1000000);
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "prompt" }));
        check("no context yet", Board.contextOf(sess(b), 0), null);
        Board.fold(b, ev({ ts: 2, ev: "context", tokens: 140000, model: "claude-sonnet-5-5" }));
        check("share", [Board.contextOf(sess(b), 0).share, Board.contextOf(sess(b), 0).size, Board.contextOf(sess(b), 0).stale], [0.7, 200000, false]);
        Board.fold(b, ev({ ts: 3, ev: "compact_start", trigger: "manual" }));
        check("compacting on", Board.compacting(sess(b)), true);
        Board.fold(b, ev({ ts: 4, ev: "compact_end", trigger: "manual" }));
        check("compacting off, reading stale", [Board.compacting(sess(b)), Board.contextOf(sess(b), 0).stale], [false, true]);
        Board.fold(b, ev({ ts: 5, ev: "context", tokens: 20000, model: "claude-sonnet-5-5" }));
        check("fresh after compact", [Board.contextOf(sess(b), 0).stale, Board.contextOf(sess(b), 0).share], [false, 0.1]);

        // route line: main loop only, no repeats, last 7 stations, legs hold 40 s then fade over 20 s
        b = Board.newBoard();
        var seq = ["files", "files", "shell", "files", "network", "browser", "skills", "memory", "hooks"];
        seq.forEach(function (st, k) { Board.fold(b, ev({ ts: 100 + k, ev: "tool_start", id: "r" + k, station: st, label: "x", tool: "T" })); });
        Board.fold(b, ev({ ts: 120, ev: "tool_start", id: "sub", station: "agents", label: "x", tool: "T", agent: "a1" }));
        check("route", sess(b).route.map(function (r) { return r.station; }), ["shell", "files", "network", "browser", "skills", "memory", "hooks"]);
        check("route legs", Board.routeLegs(sess(b), 109).length, 6);
        check("leg fresh", Board.routeLegs(sess(b), 108)[5].alpha, 1);
        check("leg fading", [Board.routeLegs(sess(b), 108 + 40 + 10)[5].alpha, Board.routeLegs(sess(b), 108 + 40 + 10).length], [0.5, 6]);
        check("old legs go first", Board.routeLegs(sess(b), 103 + 61).length, 4);
        check("leg gone", Board.routeLegs(sess(b), 108 + 61).length, 0);
        check("no sess", Board.routeLegs(null, 1), []);
        // wear: counts every call (subagents too), on a log scale
        check("uses", [sess(b).uses.files, sess(b).uses.agents, sess(b).uses.network], [3, 1, 1]);
        check("wear", [Board.wear(sess(b), "hooks") > 0, Board.wear(sess(b), "files") > Board.wear(sess(b), "shell"), Board.wear(sess(b), "you")], [true, true, 0]);
        b = Board.newBoard();
        for (i = 0; i < 80; i++) Board.fold(b, ev({ ts: 1 + i, ev: "tool_end", id: "w" + i, station: "files", label: "x", tool: "T", status: "ok" }));
        check("wear caps", Board.wear(sess(b), "files"), 1);

        // red dots: a failure marks its station; a refusal marks its station and Hooks; a late end
        // undoes a refusal; the next prompt clears them
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_end", id: "e1", station: "shell", label: "x", tool: "Bash", status: "err" }));
        Board.fold(b, ev({ ts: 2, ev: "tool_end", id: "e2", station: "shell", label: "x", tool: "Bash", status: "err" }));
        check("err dots", sess(b).errDots, { shell: 2 });
        Board.fold(b, ev({ ts: 3, ev: "tool_start", id: "r1", station: "files", label: "f", tool: "Edit" }));
        Board.fold(b, ev({ ts: 4, ev: "batch" }));
        check("refusal dots", sess(b).errDots, { shell: 2, files: 1, hooks: 1 });
        Board.fold(b, ev({ ts: 4, ev: "batch" }));
        check("same batch twice", sess(b).errDots.hooks, 1);
        Board.fold(b, ev({ ts: 4.01, ev: "tool_end", id: "r1", station: "files", label: "f", tool: "Edit", status: "ok" }));
        check("late end undoes", sess(b).errDots, { shell: 2, files: 0, hooks: 0 });
        Board.fold(b, ev({ ts: 5, ev: "prompt" }));
        check("prompt clears", sess(b).errDots, {});
        Board.fold(b, ev({ ts: 6, ev: "tool_start", id: "d1", station: "shell", label: "x", tool: "Bash" }));
        Board.fold(b, ev({ ts: 6.1, ev: "denied", id: "d1", tool: "Bash" }));
        Board.fold(b, ev({ ts: 7, ev: "batch" }));
        check("denied counted once", sess(b).errDots, { shell: 1, hooks: 1 });
        Board.fold(b, ev({ ts: 8, ev: "denied", tool: "Bash" }));
        check("denied without a call", sess(b).errDots.hooks, 2);

        // the tooltip's report: what is behind a red badge, and what the node is
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "prompt" }));
        Board.fold(b, ev({ ts: 2, ev: "tool_end", id: "e1", station: "shell", label: "build it", tool: "Bash", status: "err" }));
        Board.fold(b, ev({ ts: 3, ev: "tool_start", id: "r1", station: "files", label: "a/b.md", tool: "Edit" }));
        Board.fold(b, ev({ ts: 3.5, ev: "tool_start", id: "r2", station: "files", label: "c/d.md", tool: "Edit" }));
        Board.fold(b, ev({ ts: 4, ev: "batch" }));
        var shellRep = Board.report(sess(b), "shell"), filesRep = Board.report(sess(b), "files"), hooksRep = Board.report(sess(b), "hooks");
        check("report: shell has one failure", [shellRep.dots, shellRep.problems.length, shellRep.problems[0].kind, shellRep.problems[0].label], [1, 1, "failed", "build it"]);
        check("report: files shows both refusals, newest first", [filesRep.dots, filesRep.problems.map(function (p) { return p.label; }), filesRep.problems[0].kind], [2, ["c/d.md", "a/b.md"], "refused"]);
        check("report: hooks lists the same refused calls once each", [hooksRep.dots, hooksRep.problems.length, hooksRep.problems[0].station], [2, 2, "files"]);
        check("report: files explains refusals and Hooks", filesRep.explain.indexOf("refused") >= 0 && filesRep.explain.indexOf("Hooks") >= 0, true);
        check("report: hooks explains denials", hooksRep.explain.indexOf("refused or denied") >= 0, true);
        check("report: every node says what it is", Board.STATIONS.every(function (k) { return Board.report(sess(b), k).help.length > 0; }), true);
        check("report: a denial with no call is listed from the note", (function () {
            Board.fold(b, ev({ ts: 5, ev: "prompt" }));
            Board.fold(b, ev({ ts: 6, ev: "denied", tool: "Bash" }));
            var r = Board.report(sess(b), "hooks");
            return [r.dots, r.problems.length];
        })(), [1, 1]);
        check("report: the next prompt clears the badge and the list", (function () {
            Board.fold(b, ev({ ts: 7, ev: "prompt" }));
            var r = Board.report(sess(b), "hooks");
            return [r.dots, r.problems.length, r.explain];
        })(), [0, 0, ""]);
        check("report: a late end of an old refusal leaves the new count alone", (function () {
            var c = Board.newBoard();
            Board.fold(c, ev({ ts: 1, ev: "tool_start", id: "x", station: "files", label: "f", tool: "Edit" }));
            Board.fold(c, ev({ ts: 2, ev: "batch" }));
            Board.fold(c, ev({ ts: 3, ev: "prompt" }));
            Board.fold(c, ev({ ts: 4, ev: "tool_end", id: "y", station: "files", label: "g", tool: "Edit", status: "err" }));
            Board.fold(c, ev({ ts: 4.1, ev: "tool_end", id: "x", station: "files", label: "f", tool: "Edit", status: "ok" }));
            return sess(c).errDots.files;
        })(), 1);

        // what a click on a station can open: distinct names, newest first, from the file and skill tools only
        b = Board.newBoard();
        function put(id, ts, station, label, tool) { Board.fold(b, ev({ ts: ts, ev: "tool_end", id: id, station: station, label: label, tool: tool, status: "ok" })); }
        put("o1", 1, "files", "src/a.ts", "Read");
        put("o2", 2, "files", "src/b.ts", "Edit");
        put("o3", 3, "files", "src/a.ts", "Edit");
        put("o4", 4, "files", "List the manifests", "Bash");        // a shell line of file commands: a description
        put("o5", 5, "files", "Grep", "Grep");                         // a search: the label is the tool name
        put("o6", 6, "files", "Read", "Read");                         // no path: the label fell back to the tool name
        put("o7", 7, "memory", "memory/note.md", "Write");
        put("o8", 8, "skills", "tdd-workflow", "Skill");
        put("o9", 9, "skills", "loading tools", "ToolSearch");         // not a skill
        put("oa", 10, "shell", "build it", "Bash");
        check("openables: files, newest first, deduped with counts",
              Board.openables(sess(b), "files").map(function (i) { return [i.label, i.count]; }), [["src/a.ts", 2], ["src/b.ts", 1]]);
        check("openables: memory", Board.openables(sess(b), "memory").map(function (i) { return i.label; }), ["memory/note.md"]);
        check("openables: skills only from the Skill tool", Board.openables(sess(b), "skills").map(function (i) { return i.label; }), ["tdd-workflow"]);
        ["shell", "network", "you", "model", "agents", "hooks", "browser", "nope"].forEach(function (k) {
            check("openables: " + k + " has nothing to open", Board.openables(sess(b), k), []);
        });
        check("openables: a label cut short with an ellipsis names nothing", (function () {
            var c = Board.newBoard();
            Board.fold(c, ev({ ts: 1, ev: "tool_end", id: "z1", station: "files", label: "pkg/a-very-long-file-name-that-was-cut\u2026", tool: "Read", status: "ok" }));
            Board.fold(c, ev({ ts: 2, ev: "tool_end", id: "z2", station: "files", label: "pkg/short.ts", tool: "Read", status: "ok" }));
            return Board.openables(sess(c), "files").map(function (i) { return i.label; });
        })(), ["pkg/short.ts"]);
        check("openables: no session", Board.openables(null, "files"), []);
        check("openables: the list is capped", (function () {
            var c = Board.newBoard();
            for (var i = 0; i < 30; i++) Board.fold(c, ev({ ts: 1 + i, ev: "tool_end", id: "c" + i, station: "files", label: "d/f" + i + ".ts", tool: "Read", status: "ok" }));
            return [Board.openables(sess(c), "files").length, Board.openables(sess(c), "files", 5).length, Board.openables(sess(c), "files")[0].label];
        })(), [12, 5, "d/f29.ts"]);

        // clock hands need the oldest running start per station
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 10, ev: "tool_start", id: "a", station: "files", label: "x", tool: "Read" }));
        Board.fold(b, ev({ ts: 12, ev: "tool_start", id: "b", station: "files", label: "y", tool: "Read" }));
        Board.fold(b, ev({ ts: 13, ev: "tool_start", id: "c", station: "shell", label: "z", tool: "Bash" }));
        Board.fold(b, ev({ ts: 14, ev: "tool_end", id: "c", station: "shell", label: "z", tool: "Bash", status: "ok" }));
        check("running info", Board.runningInfo(sess(b)), { files: { n: 2, since: 10 } });
        check("running info null", Board.runningInfo(null), {});

        // background tasks: lit after their turn until task_end or a stop that no longer lists them
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "g", station: "shell", label: "sleep", tool: "Bash", bg: true }));
        Board.fold(b, ev({ ts: 1.1, ev: "tool_end", id: "g", station: "shell", label: "sleep", tool: "Bash", status: "ok", task: "t1" }));
        Board.fold(b, ev({ ts: 2, ev: "stop", bg: [{ id: "t1", type: "shell", status: "running" }] }));
        check("task lit after the turn", [sess(b).stations.shell.running, Board.runningInfo(sess(b)).shell.since], [1, 1]);
        Board.fold(b, ev({ ts: 3, ev: "task_end", task: "t1", status: "ok" }));
        check("task_end puts it out", sess(b).stations.shell.running, 0);
        Board.fold(b, ev({ ts: 4, ev: "tool_end", id: "g2", station: "shell", label: "x", tool: "Bash", status: "ok", task: "t2" }));
        Board.fold(b, ev({ ts: 5, ev: "stop", bg: [] }));
        check("stop without it ends it", sess(b).stations.shell.running, 0);
        Board.fold(b, ev({ ts: 6, ev: "tool_end", id: "g3", station: "shell", label: "x", tool: "Bash", status: "ok", task: "t3" }));
        Board.fold(b, ev({ ts: 5.5, ev: "stop", bg: [] }));
        check("earlier stop leaves a newer task", sess(b).stations.shell.running, 1);
        Board.fold(b, ev({ ts: 7, ev: "task_end", task: "t3", status: "err" }));
        check("failed task leaves a dot", [sess(b).stations.shell.running, sess(b).errDots.shell], [0, 1]);

        // subagents: a running one counts, an end with no start is ignored, a background one ends its task
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "agent_start", type: "Explore", agent: "a1" }));
        check("agents running", Board.runningAgents(sess(b)), 1);
        var rowsBefore = sess(b).entries.length;
        Board.fold(b, ev({ ts: 2, ev: "agent_end", type: "", agent: "internal1" }));
        Board.fold(b, ev({ ts: 2.1, ev: "agent_end", type: "Explore", agent: "never-started" }));
        check("unmatched end ignored", [sess(b).entries.length, Board.runningAgents(sess(b))], [rowsBefore, 1]);
        Board.fold(b, ev({ ts: 3, ev: "agent_start", type: "", agent: "x" }));
        check("typeless start ignored", Board.runningAgents(sess(b)), 1);
        Board.fold(b, ev({ ts: 4, ev: "tool_end", id: "ag", station: "agents", label: "sub", tool: "Agent", status: "ok", task: "a1" }));
        check("background agent is a task", sess(b).stations.agents.running, 1);
        Board.fold(b, ev({ ts: 5, ev: "agent_end", type: "Explore", agent: "a1" }));
        check("its end ends the task", [Board.runningAgents(sess(b)), sess(b).stations.agents.running], [0, 0]);

        // history: the recent calls at one station, newest first, capped, names and numbers only
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 1, ev: "tool_start", id: "h1", station: "shell", label: "build it", tool: "Bash" }));
        Board.fold(b, ev({ ts: 2, ev: "tool_end", id: "h1", station: "shell", label: "build it", tool: "Bash", status: "ok", ms: 1000 }));
        Board.fold(b, ev({ ts: 3, ev: "tool_end", id: "h2", station: "files", label: "a/b.md", tool: "Read", status: "ok", ms: 20 }));
        Board.fold(b, ev({ ts: 4, ev: "tool_end", id: "h3", station: "shell", label: "test it", tool: "Bash", status: "err", ms: 250 }));
        Board.fold(b, ev({ ts: 5, ev: "tool_start", id: "h4", station: "shell", label: "watch it", tool: "Bash" }));
        check("history newest first", Board.history(sess(b), "shell", 10).map(function (h) { return h.label + ":" + h.status; }),
              ["watch it:running", "test it:err", "build it:ok"]);
        check("history fields", Board.history(sess(b), "shell", 2).map(function (h) { return [h.ms, h.ts]; }), [[undefined, 5], [250, 3.75]]);
        check("history of another station", Board.history(sess(b), "files", 10).length, 1);
        check("history cap", Board.history(sess(b), "shell", 1).length, 1);
        check("history default cap", Board.history(sess(b), "shell").length, 3);
        check("history of a quiet station", Board.history(sess(b), "network", 10), []);
        check("history without a session", [Board.history(null, "shell", 10), Board.history(undefined, "shell", 10)], [[], []]);
        check("history keeps only what the log has",
              Object.keys(Board.history(sess(b), "files", 1)[0]).sort(), ["agent", "label", "ms", "status", "ts"]);
        Board.fold(b, ev({ ts: 5.5, ev: "tool_end", id: "ag1", station: "files", label: "sub/x.md", tool: "Read", status: "ok", ms: 3, agent: "a1" }));
        check("history marks a subagent's call", Board.history(sess(b), "files", 10).map(function (h) { return h.agent; }), [true, false]);
        Board.fold(b, ev({ ts: 6, ev: "prompt" }));
        sess(b).entries.push({ ts: 5.6, station: "files", label: "odd", status: "ok", ms: null });
        check("history turns a null duration into none", Board.history(sess(b), "files", 1)[0].ms, undefined);
        sess(b).entries.pop();
        check("an unknown station titles itself by its key", [Board.report(null, "zzz").title, Board.report(sess(b), "zzz").title], ["zzz", "zzz"]);
        check("history has the notes too", Board.history(sess(b), "you", 10).map(function (h) { return h.label; }), ["new message"]);
        for (i = 0; i < 20; i++) Board.fold(b, ev({ ts: 10 + i, ev: "tool_end", id: "m" + i, station: "network", label: "n" + i, tool: "WebFetch", status: "ok", ms: 5 }));
        check("history default is ten", Board.history(sess(b), "network").length, 10);
        check("history newest of many", Board.history(sess(b), "network", 1)[0].label, "n19");

        // theme: parse colors.toml, derive a palette, fall back when the file is missing or odd
        var toml = '# a comment\nmode = "dark"\n\naccent = "#509475"\nbackground = "#111c18"\nforeground = "#C1C497"\nbright_foreground = "#F7E8B2"\nmuted = "#53685B"\nred = "#FF5345"\ncyan = "#2DD5B7"\nbroken = nope\n';
        var parsed = Theme.parseColors(toml);
        check("toml", [parsed.accent, parsed.mode, parsed.cyan, parsed.broken], ["#509475", "dark", "#2DD5B7", undefined]);
        var dark = Theme.derive(parsed);
        check("dark palette", [dark.light, dark.bg, dark.accent, dark.alert, dark.memory, dark.inkStrong, dark.faint], [false, "#111c18", "#509475", "#FF5345", "#2DD5B7", "#F7E8B2", "#53685B"]);
        check("mix", [Theme.mix("#000000", "#ffffff", 0.5), Theme.mix("#102030", "#102030", 0.7), Theme.mix("#000000", "#ff0000", 1)], ["#808080", "#102030", "#ff0000"]);
        var lightP = Theme.derive(Theme.parseColors('mode = "light"\nbackground = "#eff1f5"\nforeground = "#4c4f69"\naccent = "#1e66f5"\n'));
        check("light palette", [lightP.light, lightP.bg, lightP.accent, lightP.alert === Theme.FALLBACK.alert], [true, "#eff1f5", "#1e66f5", true]);
        check("light ink is darker than its background", Theme.mix(lightP.bg, "#4c4f69", 0.68) === lightP.ink && lightP.ink < lightP.bg, true);
        check("fallback", Theme.derive({}), Theme.FALLBACK);
        check("fallback keeps good extras", Theme.derive({ accent: "#123456", red: "#bad" }).accent, "#123456");
        check("fallback ignores bad extras", Theme.derive({ accent: "#123456", red: "#bad" }).alert, Theme.FALLBACK.alert);
        check("empty text", Theme.parseColors(null), {});

        // tooltip facts: running calls longest first, last and average, station facts, the hub
        b = Board.newBoard();
        Board.fold(b, ev({ ts: 100, ev: "session", model: "claude-sonnet-5-5" }));
        Board.fold(b, ev({ ts: 101, ev: "prompt" }));
        Board.fold(b, ev({ ts: 102, ev: "tool_start", id: "n1", station: "shell", label: "sleep 9", tool: "Bash" }));
        Board.fold(b, ev({ ts: 110, ev: "tool_start", id: "n2", station: "shell", label: "npm test", tool: "Bash" }));
        Board.fold(b, ev({ ts: 120, ev: "tool_end", id: "d1", station: "shell", label: "ls", tool: "Bash", status: "ok", ms: 400 }));
        Board.fold(b, ev({ ts: 121, ev: "tool_end", id: "d2", station: "shell", label: "make", tool: "Bash", status: "ok", ms: 2000 }));
        var sh = Board.report(sess(b), "shell", 4, 182).lines;
        check("facts: running longest first with elapsed", sh.slice(0, 2), ["sleep 9 \u00b7 1m20s", "npm test \u00b7 1m12s"]);
        check("facts: last call and average", sh.slice(2), ["last: make \u00b7 2.0s", "average 1.2s over 2 calls"]);
        check("facts: no lines for a quiet station", Board.report(sess(b), "files", 4, 182).lines, []);
        for (var i = 0; i < 6; i++) Board.fold(b, ev({ ts: 130 + i, ev: "tool_start", id: "m" + i, station: "shell", label: "x" + i, tool: "Bash" }));
        var capped = Board.report(sess(b), "shell", 4, 200).lines;
        check("facts: capped and counts the rest", [capped.length <= 6, capped.indexOf("+5 more running") >= 0], [true, true]);
        Board.fold(b, ev({ ts: 140, ev: "batch" }));
        Board.fold(b, ev({ ts: 141, ev: "batch" }));
        check("facts: model name and steps this turn", Board.report(sess(b), "model", 4, 150).lines, ["claude-sonnet-5-5 \u00b7 2 steps this turn"]);
        Board.fold(b, ev({ ts: 142, ev: "compact_end" }));
        check("facts: compactions", Board.report(sess(b), "model", 4, 150).lines[1].indexOf("1 compaction in the last") === 0, true);
        Board.fold(b, ev({ ts: 143, ev: "tool_end", id: "w1", station: "network", label: "example.com", tool: "WebFetch", status: "ok", ms: 5 }));
        Board.fold(b, ev({ ts: 144, ev: "tool_end", id: "w2", station: "network", label: "example.com", tool: "WebFetch", status: "ok", ms: 5 }));
        Board.fold(b, ev({ ts: 145, ev: "tool_end", id: "w3", station: "network", label: "other.org", tool: "WebFetch", status: "ok", ms: 5 }));
        Board.fold(b, ev({ ts: 146, ev: "tool_end", id: "w4", station: "network", label: "web search", tool: "WebSearch", status: "ok", ms: 5 }));
        check("facts: top hosts only", Board.report(sess(b), "network", 4, 150).lines.slice(-1), ["hosts: example.com \u00d72, other.org \u00d71"]);
        Board.fold(b, ev({ ts: 147, ev: "agent_start", agent: "a1", type: "Explore" }));
        Board.fold(b, ev({ ts: 148, ev: "agent_start", agent: "a2", type: "Explore" }));
        Board.fold(b, ev({ ts: 149, ev: "agent_start", agent: "a3", type: "Plan" }));
        Board.fold(b, ev({ ts: 149.5, ev: "agent_end", agent: "a3" }));
        check("facts: running agent types", Board.report(sess(b), "agents", 4, 150).lines.slice(-1), ["running: Explore \u00d72"]);
        check("facts: you, nothing to wait on", Board.report(sess(b), "you", 4, 150).lines, []);
        Board.fold(b, ev({ ts: 150, ev: "stop" }));
        var waitLine = Board.report(sess(b), "you", 4, 160).lines;
        var d = new Date(150000), hh = (d.getHours() < 10 ? "0" : "") + d.getHours(), mm = (d.getMinutes() < 10 ? "0" : "") + d.getMinutes();
        check("facts: waiting on you since", waitLine, ["waiting on you since " + hh + ":" + mm]);
        Board.fold(b, ev({ ts: 155, ev: "prompt" }));
        check("facts: a new message ends the wait", Board.report(sess(b), "you", 4, 160).lines, []);
        check("facts: durations", [Board.fmtMs(850), Board.fmtMs(1234), Board.fmtMs(65000), Board.fmtElapsed(3725)], ["850ms", "1.2s", "1m05s", "1h02m"]);
        check("hub: no reading", Board.hubLines(sess(b), 0, 200), []);
        Board.fold(b, ev({ ts: 156, ev: "context", tokens: 48213, model: "claude-sonnet-5-5" }));
        check("hub: guessed window", Board.hubLines(sess(b), 0, 216), ["48,213 tokens of 200,000", "window from a guess (set it in settings)", "reading 1m00s old"]);
        check("hub: configured window", Board.hubLines(sess(b), 1000000, 158).slice(0, 2), ["48,213 tokens of 1,000,000", "window from your setting"]);

        console.log(failures === 0 ? "board tests: all passed" : "board tests: " + failures + " FAILED");
        Qt.exit(failures === 0 ? 0 : 1);
    }
}
