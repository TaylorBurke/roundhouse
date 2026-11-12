// Folds roundhouse log events into a board per session. Plain JS with no QML or DOM
// dependencies so it can be tested on its own (see tests/board.test.qml).
// Names only, never content: it keeps exactly the fields the emitter wrote.

var MAX_ENTRIES = 80;
var MAX_SEEN = 3000;
var LABELS = { you: "You", model: "Model", memory: "Memory", files: "Files", shell: "Shell", network: "Network",
               browser: "Browser", agents: "Agents", skills: "Skills", hooks: "Hooks" };
var STATIONS = ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills", "hooks"];

function newBoard() {
    return { sessions: {}, active: null, seen: {}, seenOrder: [] };
}

function newSession(sid) {
    var stations = {};
    STATIONS.forEach(function (s) { stations[s] = { count: 0, running: 0, blocked: 0, errors: 0 }; });
    return {
        sid: sid, dir: "", model: "", tokens: 0, lastTs: 0, ended: false,
        switched: false,          // a model event since the last prompt: context's model name is stale
        stations: stations,
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
}

// A batch or a stop means every call that started before it has finished. One still open was
// refused. That holds for background calls too: the call itself ends within milliseconds of
// launching (only its task keeps running), as measured in stage 2b. Subagents are judged by
// their own events.
function closeOpen(sess, ev) {
    sess.entries.forEach(function (e) {
        if (e.status === "running" && e.id && e.ts <= ev.ts && (e.agent || null) === (ev.agent || null)) {
            e.status = "blocked";
            sess.newlyBlocked.push({ station: e.station, label: e.label });
        }
    });
}

function applyTool(sess, ev, ending) {
    var entry = ev.id ? sess.byId[ev.id] : null;
    if (!entry) {
        entry = addEntry(sess, {
            id: ev.id || null, ts: ev.ts, station: ev.station, label: ev.label, tool: ev.tool,
            status: "running", agent: ev.agent || null, bg: !!ev.bg
        });
        if (ending) entry.ts = ev.ts - (ev.ms || 0) / 1000;   // an end without a start
    }
    if (!ending) {
        if (ev.bg) entry.bg = true;
        return;                       // an end that landed first keeps its result
    }
    if (ev.ms !== undefined) entry.ms = ev.ms;
    entry.status = ev.status === "err" ? "err" : "ok";   // also frees an entry wrongly marked blocked
    entry.interrupt = !!ev.interrupt;
    if (ev.task) {
        entry.task = ev.task;
        sess.tasks[ev.task] = { station: ev.station, label: ev.label, status: "running" };
    }
}

function fold(board, ev) {
    if (!ev || typeof ev !== "object" || !ev.sid || !ev.ev) return false;
    if (!remember(board, JSON.stringify(ev))) return false;   // replayed after the log was cut back
    var sess = board.sessions[ev.sid] || (board.sessions[ev.sid] = newSession(ev.sid));
    var kind = ev.ev;
    sess.newlyBlocked = [];
    if (ev.ts > sess.lastTs) sess.lastTs = ev.ts;
    if (!board.active || ev.ts >= board.sessions[board.active].lastTs) board.active = ev.sid;

    if (kind === "session") {
        if (ev.dir) sess.dir = ev.dir;
        if (ev.model && !sess.model) sess.model = ev.model;
        sess.ended = false;
    } else if (kind === "session_end") {
        sess.ended = true;
    } else if (kind === "tool_start") {
        applyTool(sess, ev, false);
    } else if (kind === "tool_end") {
        applyTool(sess, ev, true);
    } else if (kind === "prompt") {
        sess.switched = false;
        note(sess, ev, "you", "new message");
    } else if (kind === "task_end") {
        var task = sess.tasks[ev.task];
        if (task) task.status = ev.status === "err" ? "err" : "ok";
        note(sess, ev, task ? task.station : "shell", "background task " + (ev.status === "err" ? "failed" : "done"), ev.status === "err" ? "err" : "ok");
    } else if (kind === "batch") {
        closeOpen(sess, ev);
        note(sess, ev, "model", "next step");
    } else if (kind === "stop") {
        closeOpen(sess, ev);
        note(sess, ev, "you", "answer ready");
    } else if (kind === "stop_error") {
        note(sess, ev, "model", "stopped: " + (ev.error || "error"), "err");
    } else if (kind === "ask") {
        note(sess, ev, "hooks", "asked permission: " + (ev.tool || ""));
    } else if (kind === "denied") {
        var denied = ev.id ? sess.byId[ev.id] : null;
        if (denied && denied.status === "running") {
            denied.status = "blocked";
            sess.newlyBlocked.push({ station: denied.station, label: denied.label });
        }
        note(sess, ev, "hooks", "denied: " + (ev.tool || ""), "err");
    } else if (kind === "agent_start") {
        sess.agents[ev.agent] = { type: ev.type, running: true };
        note(sess, ev, "agents", (ev.type || "agent") + " started");
    } else if (kind === "agent_end") {
        if (sess.agents[ev.agent]) sess.agents[ev.agent].running = false;
        note(sess, ev, "agents", (ev.type || "agent") + " finished");
    } else if (kind === "compact_start") {
        note(sess, ev, "model", "compacting", "running");
    } else if (kind === "compact_end") {
        sess.entries.forEach(function (e) {
            if (e.status === "running" && e.station === "model" && e.label === "compacting") e.status = "ok";
        });
        note(sess, ev, "model", "compacted");
    } else if (kind === "model") {
        sess.model = ev.to || sess.model;
        sess.switched = true;
        note(sess, ev, "model", (ev.from || "?") + " → " + (ev.to || "?"));
    } else if (kind === "context") {
        sess.tokens = ev.tokens || 0;
        if (ev.model && !sess.switched) sess.model = ev.model;
    } else if (kind === "notify") {
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

if (typeof module !== "undefined") module.exports = { newBoard: newBoard, fold: fold, foldLine: foldLine, currentAction: currentAction, feedRows: feedRows, STATIONS: STATIONS };
