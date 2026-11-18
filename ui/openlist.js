.pragma library

// What a click on a map station does, and what happens when the on-disk lookup answers.

// What a left click does at each station that has something to open. A later ticket gives its
// station an entry here instead of editing a shared switch.
//
// The contract has two halves, because the map asks "can this open?" for every station on every log
// event, while "what is there?" is only needed when the user clicks:
//   can    -- decides whether the station shows a hand cursor. It MUST be cheap: no disk, no process
//             (hyprctl, git, ...), no provider that scales with the log. `true` (a static flag), or
//             `can(sess, key, board)` returning a boolean from what is already in memory.
//   items  -- `items(sess, key, max, board)`, the list behind a click. Called ONLY at click time, so
//             it may read the disk or ask hyprctl. If it finds nothing, the click shows a toast
//             ("nothing found") instead of doing anything silent; never make `can` look ahead for it.
//   names  -- shorthand for "the names Board.openables finds in memory" (items and can both use it).
//   always -- there is always something (no lookup), together with an `action`.
//   action -- what the window does with a click, for an entry that is not a list of names. An
//             `always` entry must name an `action`, or it is not openable.
// An entry with `items` and no `can` counts as openable (a constant-time answer; nothing is looked up
// until the click). A station with no entry reacts to a right click only (its recent calls), and
// nothing is computed for it.
var HANDLERS = {
    files: { names: true },
    memory: { always: true, action: "memory" },     // the project's memory files are there without a call
    skills: { names: true },
    network: { items: networkItems, list: true }   // hosts (open https://<host>) and MCP servers (history only), always listed
};

// A plain hostname, the same rule as tools/openhost.py (which checks again): dotted labels of letters,
// digits and hyphens, none starting or ending with a hyphen, ASCII only (an IDN arrives as punycode).
var HOST_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
function isHost(s) { return typeof s === "string" && s.length <= 253 && HOST_RE.test(s); }

// The distinct hosts (a WebFetch label that is a plain hostname) and MCP servers (from the tool name
// mcp__<server>__<tool>) behind the Network entries, with counts, newest first. Only a host carries
// `host`, the one thing that may be opened; a server is `kind: "mcp"` and opens nothing.
function networkItems(sess, key, max) {
    if (!sess || !sess.entries) return [];
    var by = {}, out = [];
    sess.entries.forEach(function (e) {
        if (e.station !== "network") return;
        var id, it;
        var mcp = /^mcp__(.+?)__/.exec(e.tool || "");
        if (mcp) id = "m:" + mcp[1];
        else if (e.tool === "WebFetch" && isHost(e.label)) id = "h:" + e.label;
        else return;
        it = by[id];
        if (!it) {
            it = by[id] = mcp ? { label: mcp[1], kind: "mcp", count: 0, ts: 0 } : { label: e.label, kind: "host", host: e.label, count: 0, ts: 0 };
            out.push(it);
        }
        it.count++;
        if (e.ts >= it.ts) it.ts = e.ts;
    });
    out.sort(function (a, b) { return b.ts - a.ts; });
    return out.slice(0, max || 12);
}

// The items behind a left click at `key`, at most `max`: [] for a station with no entry or an entry
// that is always open. `board` is board.js (this file cannot import it).
function itemsOf(key, sess, board, max) {
    var h = HANDLERS[key];
    if (!h || h.always) return [];
    if (h.items) return h.items(sess, key, max, board) || [];
    return h.names ? board.openables(sess, key, max) : [];
}

// Whether a left click at `key` leads anywhere. Cheap by contract: never calls a handler's `items`.
function canOpen(key, sess, board) {
    var h = HANDLERS[key];
    if (!h) return false;
    if (h.always) return !!h.action;
    if (h.can !== undefined) return typeof h.can === "function" ? !!h.can(sess, key, board) : !!h.can;
    if (h.items) return true;
    return !!h.names && board.openables(sess, key, 1).length > 0;
}

// What a left click at `key` means: its entry's own action, else what onNode makes of its items.
function onClick(key, sess, board) {
    var h = HANDLERS[key];
    if (!h) return { action: "none" };
    if (h.action) return { action: h.action };
    return onNode(itemsOf(key, sess, board, 12), !!h.list);
}

// The names a station can open (from Board.openables): none, one (look it up and open it), or
// several (list them to pick from).
function onNode(items, alwaysList) {
    if (!items || items.length === 0) return { action: "none" };
    if (items.length === 1 && !alwaysList) return { action: "resolve", item: items[0] };
    return {
        action: "list", items: items,
        rows: items.map(function (it) {
            var sub = it.count > 1 ? "×" + it.count : "";
            return { text: it.label, sub: it.kind === "mcp" ? (sub ? "MCP \u00b7 " + sub : "MCP") : sub };
        })
    };
}

// The files the lookup found for one name: none (say so), one (open it) or several (pick).
function onResolved(paths) {
    if (!paths || paths.length === 0) return { action: "missing" };
    if (paths.length === 1) return { action: "open", path: paths[0] };
    return { action: "choose", paths: paths };
}

// A path for display: the home folder as ~.
function shorten(path, home) {
    return home && path.indexOf(home + "/") === 0 ? "~" + path.slice(home.length) : path;
}

// How to show several paths in one list: the shortest ending of each (the last k parts, the same k
// for all) that tells them all apart, with ".../" in front when something was cut off. Two files
// called MEMORY.md are told apart by their project folder, not by the part they share.
function tails(paths, home) {
    if (paths && paths.length === 1) return [shorten(paths[0], home)];
    var parts = (paths || []).map(function (p) { return p.split("/").filter(function (x) { return x !== ""; }); });
    var longest = parts.reduce(function (m, t) { return Math.max(m, t.length); }, 0);
    for (var k = 1; k <= longest; k++) {
        var cut = parts.map(function (t) { return t.slice(-k).join("/"); });
        var seen = {}, distinct = true;
        cut.forEach(function (c) { if (seen[c]) distinct = false; seen[c] = true; });
        if (distinct || k === longest)
            return cut.map(function (c, i) { return parts[i].length > k ? "\u2026/" + c : shorten(paths[i], home); });
    }
    return [];
}

// Memory files live at ~/.claude/projects/<project folder, / turned into ->/memory/<file>; the
// project is what tells them apart, so that is what a row shows (without the leading -home-<user>-).
// Anything that is not such a path is shown by tails().
function memoryRows(paths, home) {
    var fallback = tails(paths, home);
    return (paths || []).map(function (p, i) {
        var m = /\/\.claude\/projects\/([^\/]+)\/memory\/[^\/]+$/.exec(p);
        return { text: m ? m[1].replace(/^-home-[^-]+-/, "") : fallback[i], sub: "" };
    });
}

// The command that looks a name up: python3 tools/openable.py resolve KIND LABEL, with the session's
// folder if known (--cwd), else the session's folder name (--dir). Each is one argument, so a name
// with spaces or odd characters is never split or interpreted.
function lookupArgs(script, kind, label, cwd, dir, sid) {
    var args = ["python3", "-I", script, "resolve", kind, label];
    return args.concat(folderArgs(cwd, dir, sid));
}

// How the lookup learns the session's folder: given outright (--cwd), else by session id (the tool reads
// it from claude-strip's state, which also serves the all-sessions window) with the folder's name as a
// last resort.
function folderArgs(cwd, dir, sid) {
    if (cwd) return ["--cwd", cwd];
    var a = [];
    if (sid) a = a.concat(["--sid", sid]);
    if (dir) a = a.concat(["--dir", dir]);
    return a;
}

// The files found for one name, as list rows: at most `max` of them (what a click can open), and a
// last row saying how many more there are. Memory files are shown by project, the rest by the
// shortest ending that tells them apart.
function pathRows(paths, kind, home, max) {
    var shown = (paths || []).slice(0, max);
    var rows = kind === "memoryfiles" ? memoryFileRows(shown)
             : kind === "memory" ? memoryRows(shown, home)
             : tails(shown, home).map(function (t) { return { text: t, sub: "" }; });
    if (paths && paths.length > max) rows.push({ text: "\u2026 and " + (paths.length - max) + " more", sub: "" });
    return { paths: shown, rows: rows };
}

// A lookup's answer is used only if it is still the current lookup and the list is still waiting
// for it (the user did not close it, pick something else, or switch session in the meantime).
function accepts(seq, current, mode) {
    return seq === current && mode === "note";
}

// What a click on row `index` means: look the name up (a list of names), open the file (a list of
// files), or nothing (the "... and N more" row, or a row that is not there).
function pickAction(mode, index, items, paths) {
    if (mode === "items" && items && items[index] !== undefined && items[index].kind !== undefined)
        return isHost(items[index].host) ? { action: "openhost", host: items[index].host } : { action: "none" };   // Network rows
    if (mode === "items" && items && items[index] !== undefined) return { action: "lookup", item: items[index] };
    if (mode === "paths" && paths && paths[index] !== undefined) return { action: "open", path: paths[index] };
    return { action: "none" };
}

// The command that lists a project's own memory files (a click on Memory): the session's folder if
// known (--cwd), else its folder name (--dir).
function memoryListArgs(script, cwd, dir, sid) {
    return ["python3", "-I", script, "list", "memory"].concat(folderArgs(cwd, dir, sid));
}

// Memory files of one project as list rows: the path below the project's memory folder (MEMORY.md,
// topics/x.md), which is all that tells them apart.
function memoryFileRows(paths) {
    return (paths || []).map(function (p) {
        var at = p.lastIndexOf("/memory/");
        return { text: at >= 0 ? p.slice(at + "/memory/".length) : p.slice(p.lastIndexOf("/") + 1), sub: "" };
    });
}

// The lookup's answer: the list of paths, or an empty list for anything that is not {"paths": [strings]}.
function parsePaths(text) {
    try {
        var parsed = JSON.parse(text);
        if (parsed && Array.isArray(parsed.paths))
            return parsed.paths.filter(function (p) { return typeof p === "string" && p.charAt(0) === "/"; });
    } catch (e) { }
    return [];
}

// A span for a row: "340ms", "1.2s", "45s", "3m". The unit is picked after rounding, so nothing
// reads "1000ms" or "60s"; a negative span counts as 0.
function durationLabel(ms) {
    if (ms === undefined || ms === null || isNaN(ms)) return "";
    var m = Math.max(0, ms);
    var r = Math.round(m);
    if (r < 1000) return r + "ms";
    var tenths = Math.round(m / 100) / 10;
    if (tenths < 10) return tenths + "s";
    var secs = Math.round(m / 1000);
    if (secs < 60) return secs + "s";
    return Math.floor(secs / 60) + "m";
}

// How long ago, from `seconds`: "now", "40s", "5m", "2h".
function ageLabel(seconds) {
    if (typeof seconds !== "number" || isNaN(seconds)) return "";
    if (seconds < 10) return "now";
    if (seconds < 60) return Math.floor(seconds) + "s";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m";
    return Math.floor(seconds / 3600) + "h";
}

// Recent calls (Board.history) as list rows: the name, and beside it the status, how long it took
// and how long ago it started, and the subagent's type ("agent" if unknown) for a call a subagent made. A call still running has no
// duration yet.
function historyRows(calls, now) {
    return (calls || []).map(function (c) {
        var parts = [c.status || "ok"];
        if (c.status !== "running" && c.ms !== undefined && c.ms !== null) parts.push(durationLabel(c.ms));
        var age = ageLabel(Math.max(0, now - c.ts));
        if (age !== "") parts.push(age);
        if (c.agent) parts.push(c.agentType || "agent");
        return { text: c.label || "", sub: parts.join(" \u00b7 ") };
    });
}

// The command that opens a host: python3 tools/openhost.py open HOST. One argument, and the tool
// validates it again.
function openHostArgs(script, host) {
    return ["python3", "-I", script, "open", host];
}
