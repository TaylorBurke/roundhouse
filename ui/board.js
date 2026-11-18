// Folds roundhouse log events into a board per session. Plain JS with no QML or DOM
// dependencies so it can be tested on its own (see tests/board.test.qml).
// Names only, never content: it keeps exactly the fields the emitter wrote.

var MAX_ENTRIES = 80;
var SESSION_IDLE = 1800;   // seconds without an event before a session is dropped from the switcher
var ROUTE_KEEP = 7;        // stations the route line joins
var ROUTE_HOLD = 40;       // seconds a leg stays at full strength ...
var ROUTE_FADE = 20;       // ... then fades out over this many
var ASKING = ["permission_prompt", "elicitation_dialog"];   // notification types that wait on the owner
var SLOW_DEFAULT = 120;    // seconds a call may run before its station is outlined as slow
var MAX_SEEN = 3000;
var LABELS = { you: "You", model: "Model", memory: "Memory", files: "Files", shell: "Shell", network: "Network",
               browser: "Browser", agents: "Agents", skills: "Skills", hooks: "Hooks" };
var STATIONS = ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills", "hooks"];

function newBoard() {
    return { sessions: {}, seen: {}, seenOrder: [] };
}

function newSession(sid) {
    var stations = {};
    STATIONS.forEach(function (s) { stations[s] = { count: 0, running: 0, blocked: 0, errors: 0 }; });
    return {
        sid: sid, dir: "", model: "", tokens: 0, firstTs: 0, lastTs: 0, ended: false, endReason: "",
        hasContext: false,        // a context reading has arrived
        tokensStale: false,       // a compaction since the last reading: the number is out of date
        switched: false,          // a model event since the last prompt: context's model name is stale
        stations: stations,
        errDots: {},              // station -> errors and refusals since the last prompt (the red dot)
        uses: {},                 // station -> every call seen there this session (wears the spoke)
        route: [],                // stations the main loop visited, newest last: { station, ts }
        waitingId: null,          // the call whose permission ask is open, when the ask named one
        waiting: false,           // a permission ask or question is open: You waits on the owner
        newlyBlocked: [],         // calls the latest event marked blocked, for the red pulse
        entries: [],              // newest last, at most MAX_ENTRIES
        byId: {},                 // tool-use id -> entry still in entries
        tasks: {},                // background task id -> { station, label, status }
        agents: {}                // agent id -> { type, running }
    };
}

function remember(board, key) {
    if (board.seen[key]) return false;
    board.seen[key] = true;
    board.seenOrder.push(key);
    if (board.seenOrder.length > MAX_SEEN) delete board.seen[board.seenOrder.shift()];
    return true;
}

function addEntry(sess, entry) {
    var list = sess.entries;
    list.push(entry);
    if (list.length > 1 && list[list.length - 2].ts > entry.ts) {
        list.sort(function (a, b) { return a.ts - b.ts; });
    }
    if (entry.id) sess.byId[entry.id] = entry;
    while (list.length > MAX_ENTRIES) {
        var old = list.shift();
        if (old.id && sess.byId[old.id] === old) delete sess.byId[old.id];
    }
    return entry;
}

function note(sess, ev, station, label, status) {
    return addEntry(sess, { ts: ev.ts, station: station, label: label, status: status || "ok", agent: ev.agent || null, id: null });
}

function recount(sess) {
    STATIONS.forEach(function (s) {
        var c = sess.stations[s];
        c.count = 0; c.running = 0; c.blocked = 0; c.errors = 0;
    });
    sess.entries.forEach(function (e) {
        var c = sess.stations[e.station];
        if (!c) return;
        c.count++;
        if (e.status === "running") c.running++;
        else if (e.status === "blocked") c.blocked++;
        else if (e.status === "err") c.errors++;
    });
    Object.keys(sess.tasks).forEach(function (id) {      // a background task keeps its station lit
        var t = sess.tasks[id], c = sess.stations[t.station];
        if (t.status === "running" && c) c.running++;
    });
}

// A batch or a stop means every call that started before it has finished. One still open was
// refused. That holds for background calls too: the call itself ends within milliseconds of
// launching (only its task keeps running), as measured in stage 2b. Subagents are judged by
// their own events.
function closeOpen(sess, ev) {
    sess.entries.forEach(function (e) {
        if (e.status === "running" && e.id && e.ts <= ev.ts && (e.agent || null) === (ev.agent || null)) blockEntry(sess, e);
    });
}

// Red dots: a failed call marks its station, a refused one marks its station and Hooks.
function dot(sess, station, delta) {
    sess.errDots[station] = Math.max(0, (sess.errDots[station] || 0) + delta);
}

function blockEntry(sess, e) {
    e.status = "blocked";
    e.dotted = "block";
    dot(sess, e.station, 1);
    dot(sess, "hooks", 1);
    sess.newlyBlocked.push({ station: e.station, label: e.label });
}

// The route line follows the main loop only: subagent calls are left out, and so are
// repeats at the same station (a leg needs two different ends).
function visit(sess, entry) {
    if (entry.agent || !LABELS[entry.station]) return;
    var last = sess.route[sess.route.length - 1];
    if (last && last.station === entry.station) return;
    sess.route.push({ station: entry.station, ts: entry.ts });
    if (sess.route.length > ROUTE_KEEP) sess.route.shift();
}

function applyTool(sess, ev, ending) {
    var entry = ev.id ? sess.byId[ev.id] : null;
    if (!entry) {
        entry = addEntry(sess, {
            id: ev.id || null, ts: ev.ts, station: ev.station, label: ev.label, tool: ev.tool,
            status: "running", agent: ev.agent || null, bg: !!ev.bg
        });
        if (ending) entry.ts = ev.ts - (ev.ms || 0) / 1000;   // an end without a start
        sess.uses[ev.station] = (sess.uses[ev.station] || 0) + 1;
        visit(sess, entry);
    }
    if (!ending) {
        if (ev.bg) entry.bg = true;
        return;                       // an end that landed first keeps its result
    }
    if (ev.ms !== undefined) entry.ms = ev.ms;
    if (entry.dotted === "block") {        // a late end: it was not refused after all
        dot(sess, entry.station, -1);
        dot(sess, "hooks", -1);
        entry.dotted = null;
    }
    entry.status = ev.status === "err" ? "err" : "ok";   // also frees an entry wrongly marked blocked
    if (entry.status === "err" && !entry.dotted) {
        entry.dotted = "err";
        dot(sess, entry.station, 1);
    }
    entry.interrupt = !!ev.interrupt;
    if (ev.task) {
        entry.task = ev.task;
        sess.tasks[ev.task] = { station: ev.station, label: ev.label, status: "running", since: entry.ts };
    }
}

function clearWaiting(sess) { sess.waiting = false; sess.waitingId = null; }

function fold(board, ev) {
    if (!ev || typeof ev !== "object" || !ev.sid || !ev.ev) return false;
    if (!remember(board, JSON.stringify(ev))) return false;   // replayed after the log was cut back
    var sess = board.sessions[ev.sid] || (board.sessions[ev.sid] = newSession(ev.sid));
    var kind = ev.ev;
    sess.newlyBlocked = [];
    if (ev.ts > sess.lastTs) sess.lastTs = ev.ts;
    if (!sess.firstTs || ev.ts < sess.firstTs) sess.firstTs = ev.ts;

    if (kind === "session") {
        if (ev.dir) sess.dir = ev.dir;
        if (ev.model && !sess.model) sess.model = ev.model;
        sess.ended = false;
        sess.endReason = "";
    } else if (kind === "session_end") {
        sess.ended = true;
        clearWaiting(sess);
        sess.endReason = ev.reason || "";
    } else if (kind === "tool_start") {
        if (!sess.waitingId || ev.id === sess.waitingId) clearWaiting(sess);   // another call starting does not answer an ask on a parallel one
        applyTool(sess, ev, false);
    } else if (kind === "tool_end") {
        if (sess.waitingId && ev.id === sess.waitingId) clearWaiting(sess);    // the asked call ran: it was approved
        applyTool(sess, ev, true);
    } else if (kind === "prompt") {
        sess.switched = false;
        clearWaiting(sess);
        sess.errDots = {};
        sess.promptTs = ev.ts;
        // The red dots were just cleared, so the calls behind them stop counting: a late end for
        // one of them must not take a dot off the new count.
        sess.entries.forEach(function (e) { if (e.dotted) e.dotted = "cleared"; });
        note(sess, ev, "you", "new message");
    } else if (kind === "task_end") {
        var task = sess.tasks[ev.task];
        if (task && task.status === "running") {
            task.status = ev.status === "err" ? "err" : "ok";
            if (task.status === "err") dot(sess, task.station, 1);
        }
        note(sess, ev, task ? task.station : "shell", "background task " + (ev.status === "err" ? "failed" : "done"), ev.status === "err" ? "err" : "ok");
    } else if (kind === "batch") {
        closeOpen(sess, ev);
        note(sess, ev, "model", "next step");
    } else if (kind === "stop") {
        closeOpen(sess, ev);
        clearWaiting(sess);
        var listed = {};
        (ev.bg || []).forEach(function (t) { if (t && t.id) listed[t.id] = true; });
        Object.keys(sess.tasks).forEach(function (id) {     // started before this stop, not listed: finished
            var t = sess.tasks[id];
            if (t.status === "running" && t.since <= ev.ts && !listed[id]) t.status = "ok";
        });
        note(sess, ev, "you", "answer ready");
    } else if (kind === "stop_error") {
        note(sess, ev, "model", "stopped: " + (ev.error || "error"), "err");
    } else if (kind === "ask") {
        sess.waiting = true;
        sess.waitingId = ev.id || null;
        note(sess, ev, "hooks", "asked permission: " + (ev.tool || ""));
    } else if (kind === "denied") {
        clearWaiting(sess);
        var denied = ev.id ? sess.byId[ev.id] : null;
        if (denied && denied.status === "running") blockEntry(sess, denied);
        else if (!denied) dot(sess, "hooks", 1);
        note(sess, ev, "hooks", "denied: " + (ev.tool || ""), "err");
    } else if (kind === "agent_start") {
        if (ev.agent && ev.type) {
            sess.agents[ev.agent] = { type: ev.type, running: true };
            note(sess, ev, "agents", ev.type + " started");
        }
    } else if (kind === "agent_end") {
        var agent = sess.agents[ev.agent];          // an end with no matching start is an internal agent
        if (agent) {
            agent.running = false;
            if (sess.tasks[ev.agent] && sess.tasks[ev.agent].status === "running") sess.tasks[ev.agent].status = "ok";
            note(sess, ev, "agents", agent.type + " finished");
        }
    } else if (kind === "compact_start") {
        note(sess, ev, "model", "compacting", "running");
    } else if (kind === "compact_end") {
        sess.entries.forEach(function (e) {
            if (e.status === "running" && e.station === "model" && e.label === "compacting") e.status = "ok";
        });
        sess.tokensStale = true;
        note(sess, ev, "model", "compacted");
    } else if (kind === "model") {
        sess.model = ev.to || sess.model;
        sess.switched = true;
        note(sess, ev, "model", (ev.from || "?") + " → " + (ev.to || "?"));
    } else if (kind === "context") {
        sess.tokens = ev.tokens || 0;
        sess.hasContext = true;
        sess.contextTs = ev.ts;
        sess.tokensStale = false;
        if (ev.model && !sess.switched) sess.model = ev.model;
    } else if (kind === "notify") {
        if (ASKING.indexOf(ev.type) >= 0) { sess.waiting = true; sess.waitingId = null; }    // idle_prompt and the like are not a question
        note(sess, ev, "you", "notification: " + (ev.type || ""));
    }
    recount(sess);
    return true;
}

// Parse one log line and fold it. Returns the event, or false for a blank, damaged or replayed line.
function foldLine(board, line) {
    var ev;
    try { ev = JSON.parse(line); } catch (e) { return false; }
    return fold(board, ev) ? ev : false;
}

// ---- sessions ---------------------------------------------------------------------------
// The sessions worth showing: not ended, and heard from within SESSION_IDLE seconds of `now`.
// In a stable order (by first sight), so cycling does not reshuffle as activity moves around.
function liveSessions(board, now) {
    return Object.keys(board.sessions).map(function (id) { return board.sessions[id]; })
        .filter(function (s) { return !s.ended && now - s.lastTs < SESSION_IDLE; })
        .sort(function (a, b) { return a.firstTs - b.firstTs; });
}

// The session to show: the pinned one while it is still live; otherwise the most recently
// active live one; if none is live, the most recent of all (so the map is not blank).
function activeSid(board, pinned, now) {
    var live = liveSessions(board, now);
    if (pinned && live.some(function (s) { return s.sid === pinned; })) return pinned;
    var pool = live.length ? live : Object.keys(board.sessions).map(function (id) { return board.sessions[id]; });
    var best = null;
    pool.forEach(function (s) { if (!best || s.lastTs > best.lastTs) best = s; });
    return best ? best.sid : null;
}

// The next (dir = 1) or previous (dir = -1) live session after `shown`, wrapping round.
function cycleSid(board, shown, dir, now) {
    var live = liveSessions(board, now);
    if (live.length === 0) return shown;
    var at = -1;
    live.forEach(function (s, i) { if (s.sid === shown) at = i; });
    return live[((at < 0 ? 0 : at + dir) % live.length + live.length) % live.length].sid;
}

// A short idle time for the list: "now", "40s", "5m", "2h".
function idleLabel(seconds) {
    if (seconds < 10) return "now";
    if (seconds < 60) return Math.floor(seconds) + "s";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m";
    return Math.floor(seconds / 3600) + "h";
}

// A context-window setting as a number of tokens: 200000, "1m", "200k" and so on. 0 means auto.
function parseWindow(value) {
    if (typeof value === "number") return value >= 1000 ? Math.round(value) : 0;
    var m = /^\s*(\d+(?:\.\d+)?)\s*([km])\s*$/i.exec(String(value || ""));
    if (!m) return 0;
    return Math.round(parseFloat(m[1]) * (m[2].toLowerCase() === "m" ? 1000000 : 1000));
}

// The context window: the setting if there is one, else a guess from the model name (the
// transcript carries no window size), and never smaller than what is already in it.
function windowSize(model, tokens, override) {
    var size = override || (/(^|[^a-z0-9])1m([^a-z0-9]|$)/i.test(model || "") ? 1000000 : 200000);
    return tokens > size ? 1000000 : size;
}

// How full the context is: { share (0..1), size, stale }, or null before the first reading.
function contextOf(sess, override) {
    if (!sess || !sess.hasContext) return null;
    var size = windowSize(sess.model, sess.tokens, override);
    return { share: Math.min(1, sess.tokens / size), size: size, stale: sess.tokensStale, tokens: sess.tokens,
             source: override ? "config" : "guessed", at: sess.contextTs || 0 };
}

// The legs of the route line as of `now` (seconds): { from, to, age, alpha }. A leg holds at
// full strength for ROUTE_HOLD seconds, then fades over ROUTE_FADE, then is gone.
function routeLegs(sess, now) {
    var legs = [];
    if (!sess) return legs;
    for (var i = 1; i < sess.route.length; i++) {
        var age = now - sess.route[i].ts;
        if (age < 0) age = 0;
        var alpha = age <= ROUTE_HOLD ? 1 : Math.max(0, 1 - (age - ROUTE_HOLD) / ROUTE_FADE);
        if (alpha > 0) legs.push({ from: sess.route[i - 1].station, to: sess.route[i].station, age: age, alpha: alpha });
    }
    return legs;
}

// How worn a station's spoke is, 0..1, on a log scale: 1 call is a little, about 60 is full.
function wear(sess, station) {
    var n = sess && sess.uses[station] || 0;
    return Math.min(1, Math.log(1 + n) / Math.log(61));
}

// A station's share of the session's calls, 0..1 (its uses over all uses), for the faint heat ring.
function heat(sess, station) {
    if (!sess) return 0;
    var total = 0;
    Object.keys(sess.uses).forEach(function (k) { total += sess.uses[k]; });
    return total > 0 ? (sess.uses[station] || 0) / total : 0;
}

// The slow-call setting in seconds: a positive number, else the default. 0 or "off" turns it off (returns 0).
function parseSlow(value) {
    if (value === 0 || value === false || /^\s*(off|0+(\.0*)?)\s*$/i.test(String(value))) return 0;
    var n = typeof value === "number" ? value : parseFloat(value);
    return n > 0 && isFinite(n) ? n : SLOW_DEFAULT;
}

// Stations whose own running call (not a background task, which is meant to be long) has run past
// `threshold` seconds as of `now`: { station: seconds running }. A threshold of 0 means off.
function slow(sess, now, threshold) {
    var out = {};
    if (!sess || !(threshold > 0)) return out;
    sess.entries.forEach(function (e) {
        if (e.status !== "running" || e.bg || now - e.ts < threshold) return;
        out[e.station] = Math.max(out[e.station] || 0, now - e.ts);
    });
    return out;
}

// Stations with a call running: { station: { n, since } }, `since` the start of the oldest.
function runningInfo(sess) {
    var info = {};
    if (!sess) return info;
    sess.entries.forEach(function (e) {
        if (e.status !== "running") return;
        var r = info[e.station] || (info[e.station] = { n: 0, since: e.ts });
        r.n++;
        if (e.ts < r.since) r.since = e.ts;
    });
    Object.keys(sess.tasks).forEach(function (id) {
        var t = sess.tasks[id];
        if (t.status !== "running") return;
        var r = info[t.station] || (info[t.station] = { n: 0, since: t.since });
        r.n++;
        if (t.since < r.since) r.since = t.since;
    });
    return info;
}

// What each station stands for, in a sentence, for the hover tooltip.
var HELP = {
    you: "Your messages, and what Claude asks of you: questions, files, notifications.",
    model: "Claude's own steps between tool calls, compaction and model switches.",
    memory: "Reads and writes of Claude's memory files.",
    files: "File tools (Read, Edit, Write, Grep, Glob) and shell commands that only touch files.",
    shell: "Shell commands, and any tool that fits nowhere else.",
    network: "Web fetch and search, network commands, and other MCP servers.",
    browser: "Browser automation: pages Claude opens or drives.",
    agents: "Subagents and background workflows. Each running subagent circles this node.",
    skills: "Skills Claude invokes, and tools it loads on demand.",
    hooks: "Refusals: a call that was denied or stopped before it finished, from any station. Also permission asks."
};

// The red dots, explained: the calls behind a station's badge since the last prompt, newest first,
// at most `max`. A refused call counts at its own station and at Hooks, so the same call shows up
// under both. Names come from the log (names only), and are shown on screen, never written.
function problems(sess, key, max) {
    if (!sess) return [];
    var since = sess.promptTs || 0, out = [], notes = [];
    sess.entries.forEach(function (e) {
        if (e.ts < since) return;
        if (e.dotted === "block") {
            if (key === "hooks" || e.station === key) out.push({ kind: "refused", station: e.station, label: e.label });
        } else if (e.station === "hooks" && e.status === "err") {
            notes.push({ kind: "refused", station: "hooks", label: e.label });       // a denial with no call of its own
        } else if (e.station === key && e.status === "err") {
            out.push({ kind: "failed", station: e.station, label: e.label });
        }
    });
    if (key === "hooks") {      // a denied call is also a blocked entry above; only the surplus is listed from notes
        var extra = (sess.errDots.hooks || 0) - out.length;
        if (extra > 0) out = out.concat(notes.slice(-extra));
    }
    return out.reverse().slice(0, max || 4);
}

// ---- tooltip facts: compact lines, built from the log only ------------------------------------
var MAX_LINES = 6;
function clock(ts) {
    var d = new Date(ts * 1000);
    return (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes();
}
function fmtElapsed(sec) {            // "45s", "1m12s", "2h03m"
    sec = Math.max(0, Math.floor(sec));
    if (sec < 60) return sec + "s";
    if (sec < 3600) return Math.floor(sec / 60) + "m" + (sec % 60 < 10 ? "0" : "") + (sec % 60) + "s";
    return Math.floor(sec / 3600) + "h" + (Math.floor(sec % 3600 / 60) < 10 ? "0" : "") + Math.floor(sec % 3600 / 60) + "m";
}
function isNum(n) { return typeof n === "number" && isFinite(n); }
function fmtMs(ms) { if (!isNum(ms)) return ""; return ms < 1000 ? Math.round(ms) + "ms" : ms < 10000 ? (ms / 1000).toFixed(1) + "s" : fmtElapsed(ms / 1000); }
function trim(text, n) { return text.length > n ? text.slice(0, n - 1) + "\u2026" : text; }
function groups(n) { return String(Math.round(n)).replace(/\B(?=(\d{3})+$)/g, ","); }

// Lines for one station: running calls with elapsed time (longest first), the last finished call,
// the average duration, then the station's own facts. Names and times only.
function factLines(sess, key, now) {
    var lines = [], running = [], done = [];
    sess.entries.forEach(function (e) {
        if (e.station !== key) return;
        if (e.status === "running" && e.id) running.push(e);
        else if (isNum(e.ms) && e.status !== "running") done.push(e);
    });
    running.sort(function (a, b) { return a.ts - b.ts; });
    running.slice(0, 3).forEach(function (e) { lines.push(trim(e.label || e.tool || "call", 28) + " \u00b7 " + fmtElapsed(now - e.ts)); });
    if (running.length > 3) lines.push("+" + (running.length - 3) + " more running");
    if (done.length) {
        var total = 0;
        done.forEach(function (e) { total += e.ms; });
        var last = done[done.length - 1];
        lines.push("last: " + trim(last.label || last.tool || "call", 22) + " \u00b7 " + fmtMs(last.ms));
        lines.push("average " + fmtMs(total / done.length) + " over " + done.length + (done.length === 1 ? " call" : " calls"));
    }
    var since = sess.promptTs || 0;
    if (key === "model") {
        var steps = 0, compactions = 0;
        sess.entries.forEach(function (e) {
            if (e.station !== "model") return;
            if (e.label === "next step" && e.ts >= since) steps++;
            else if (e.label === "compacted") compactions++;
        });
        lines.push((sess.model || "model unknown") + " \u00b7 " + steps + (steps === 1 ? " step" : " steps") + " this turn");
        if (compactions) lines.push(compactions + (compactions === 1 ? " compaction" : " compactions") + " in the last " + MAX_ENTRIES + " events");
    } else if (key === "network") {
        var hosts = {}, order = [];
        sess.entries.forEach(function (e) {
            if (e.station !== "network" || !/^(localhost|[\w-]+(\.[\w-]+)+)$/.test(e.label || "")) return;
            if (!hosts[e.label]) { hosts[e.label] = 0; order.push(e.label); }
            hosts[e.label]++;
        });
        order.sort(function (a, b) { return hosts[b] - hosts[a]; });
        if (order.length) lines.push("hosts: " + order.slice(0, 3).map(function (h) { return trim(h, 24) + " \u00d7" + hosts[h]; }).join(", "));
    } else if (key === "agents") {
        var types = {};
        Object.keys(sess.agents).forEach(function (id) {
            if (sess.agents[id].running) types[sess.agents[id].type] = (types[sess.agents[id].type] || 0) + 1;
        });
        var names = Object.keys(types);
        if (names.length) lines.push("running: " + names.slice(0, 3).map(function (t) { return trim(t, 20) + (types[t] > 1 ? " \u00d7" + types[t] : ""); }).join(", ") + (names.length > 3 ? " +" + (names.length - 3) : ""));
    } else if (key === "you") {
        var wait = 0;
        sess.entries.forEach(function (e) {
            if (e.station !== "you") return;
            if (e.label === "new message") wait = 0;
            else if (!wait && (e.label === "answer ready" || (e.label || "").indexOf("notification") === 0)) wait = e.ts;
        });
        if (wait && !sess.ended) lines.push("waiting on you since " + clock(wait));
    }
    return lines.slice(0, MAX_LINES);
}

// The hub's facts: raw tokens, window size and its source, how old the reading is.
function hubLines(sess, override, now) {
    var c = contextOf(sess, override);
    if (!c) return [];
    var lines = [groups(c.tokens) + " tokens of " + groups(c.size), "window from " + (c.source === "config" ? "your setting" : "a guess (set it in settings)")];
    if (c.at) lines.push("reading " + fmtElapsed(now - c.at) + " old");
    return lines;
}

// Everything the tooltip says about one station.
function report(sess, key, max, now) {
    var s = sess && sess.stations[key];
    var dots = sess && sess.errDots[key] || 0;
    var r = { title: LABELS[key] || key, help: HELP[key] || "", stats: [], dots: dots, problems: problems(sess, key, max), explain: "", lines: [] };
    if (!s) return r;
    r.lines = factLines(sess, key, now === undefined ? Date.now() / 1000 : now);
    if (s.count > 0) r.stats.push(s.count + " of the last " + MAX_ENTRIES + " events");
    var uses = sess.uses[key] || 0;
    if (uses > 0) r.stats.push(uses + (uses === 1 ? " call" : " calls") + " this session");
    if (s.running > 0) r.stats.push(s.running + " running now");
    if (dots > 0) {
        r.explain = key === "hooks"
            ? "Red " + dots + ": " + dots + " call" + (dots === 1 ? " was" : "s were") + " refused or denied since your last message. The same calls show on their own stations."
            : "Red " + dots + ": " + dots + " call" + (dots === 1 ? "" : "s") + " failed or " + (dots === 1 ? "was" : "were") + " refused (stopped before finishing) since your last message. Refused calls also count at Hooks.";
    }
    return r;
}

// What a click on a station can open: the distinct names behind it, newest first. Files and Memory:
// the files the Read/Write/Edit tools touched (their label is the path's last two parts); Skills:
// the skills invoked. Other tools' labels at those stations are descriptions, not names, so they
// are left out. Names only; a click looks the name up on disk (tools/openable.py).
var FILE_TOOLS = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"];
function openables(sess, key, max) {
    if (!sess || (key !== "files" && key !== "memory" && key !== "skills")) return [];
    var by = {}, out = [];
    sess.entries.forEach(function (e) {
        if (e.station !== key || !e.label || e.label === e.tool || e.label.charAt(e.label.length - 1) === "\u2026") return;   // a label cut short names nothing
        if (key === "skills" ? e.tool !== "Skill" : FILE_TOOLS.indexOf(e.tool) < 0) return;
        var it = by[e.label];
        if (!it) { it = by[e.label] = { label: e.label, count: 0, ts: 0 }; out.push(it); }
        it.count++;
        if (e.ts >= it.ts) it.ts = e.ts;
    });
    out.sort(function (a, b) { return b.ts - a.ts; });
    return out.slice(0, max || 12);
}

// The recent calls at a station, newest first, at most `max`: { label, status, ms, ts } (`ms` is
// undefined while a call runs or when none was recorded; `agent` is the subagent's id for its call, else null; `agentType` is its type when known).
// Only the last MAX_ENTRIES events are kept, so that is as far back as it goes. Names only: the labels the log carries,
// shown on screen, never written. Right-click on any station lists these.
function history(sess, key, max) {
    if (!sess) return [];
    var out = [];
    sess.entries.forEach(function (e) {
        if (e.station === key) out.push({ label: e.label, status: e.status, ms: e.ms === null ? undefined : e.ms, ts: e.ts, agent: e.agent || null, agentType: e.agent && sess.agents[e.agent] ? sess.agents[e.agent].type : undefined });
    });
    return out.reverse().slice(0, max || 10);
}

// How many subagents are running, for the dots that orbit the Agents station.
function runningAgents(sess) {
    if (!sess) return 0;
    return Object.keys(sess.agents).filter(function (id) { return sess.agents[id].running; }).length;
}

function compacting(sess) {
    return !!sess && sess.entries.some(function (e) { return e.station === "model" && e.label === "compacting" && e.status === "running"; });
}

// What is happening now, in one line: the newest running call, how many more at its station,
// and how many are running elsewhere.
function currentAction(sess) {
    if (!sess) return "waiting for events";
    var running = sess.entries.filter(function (e) { return e.status === "running"; });
    if (running.length === 0) return sess.ended ? "session ended" : "idle";
    var newest = running[running.length - 1];
    var same = running.filter(function (e) { return e.station === newest.station; }).length;
    var text = LABELS[newest.station] + ": " + newest.label;
    if (same > 1) text += " and " + (same - 1) + " more";
    if (running.length > same) text += " \u00b7 +" + (running.length - same) + " elsewhere";
    return text;
}

// The feed: the newest `max` rows, newest first. Finished rows that follow each other at one
// station are folded into one row with `extra` set to how many it absorbed.
function feedRows(sess, max) {
    if (!sess) return [];
    var rows = [];
    sess.entries.forEach(function (e) {
        var last = rows[rows.length - 1];
        if (last && e.status === "ok" && last.status === "ok" && last.station === e.station) {
            last.label = e.label;
            last.extra++;
            return;
        }
        rows.push({ station: e.station, name: LABELS[e.station] || e.station, label: e.label, status: e.status, extra: 0,
                    mark: e.status === "running" ? "\u25cf" : (e.status === "ok" ? "\u00b7" : "\u2715") });
    });
    return rows.slice(-max).reverse();
}

if (typeof module !== "undefined") module.exports = { liveSessions: liveSessions, activeSid: activeSid, cycleSid: cycleSid, idleLabel: idleLabel, newBoard: newBoard, fold: fold, foldLine: foldLine, currentAction: currentAction, parseWindow: parseWindow, windowSize: windowSize, contextOf: contextOf, compacting: compacting, runningInfo: runningInfo, heat: heat, slow: slow, parseSlow: parseSlow, hubLines: hubLines, factLines: factLines, fmtMs: fmtMs, fmtElapsed: fmtElapsed, runningAgents: runningAgents, report: report, problems: problems, openables: openables, history: history, routeLegs: routeLegs, wear: wear, feedRows: feedRows, STATIONS: STATIONS };
