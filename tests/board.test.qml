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

        console.log(failures === 0 ? "board tests: all passed" : "board tests: " + failures + " FAILED");
        Qt.exit(failures === 0 ? 0 : 1);
    }
}
