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
    model: { can: modelCan, action: "turn" },       // the current turn from the transcript, read at the click (ui/turn.js)
    network: { can: networkCan, items: networkItems, list: true },   // hosts (open https://<host>) and MCP servers (history only), always listed
    // a browser window to go to: there is one only if the session used the browser (in memory); which
    // windows exist is asked at the click (tools/browserwin.py)
    browser: { can: function (sess) { var b = sess && sess.stations && sess.stations.browser; return !!b && b.count > 0; },
               action: browserAction },
    shell: { can: function (sess) { return hasTasks(sess); }, items: taskItems, list: true }     // background tasks: running first, then finished
};

// Cheap (in memory): Model opens its turn panel once the session has any entry; whether the transcript
// exists is only learned at the click, which toasts when it does not.
function modelCan(sess) {
    return !!sess && typeof sess.sid === "string" && /^[A-Za-z0-9_-]{8}$/.test(sess.sid) && !!sess.entries && sess.entries.length > 0;
}

// A plain hostname, the same rule as tools/openhost.py (which checks again): dotted labels of letters,
// digits and hyphens, none starting or ending with a hyphen, ASCII only (a non-ASCII name is simply not
// offered; nothing converts it to punycode). KEEP IDENTICAL to _HOST in tools/openhost.py (a test checks).
var HOST_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
function isHost(s) { return typeof s === "string" && s.length <= 253 && HOST_RE.test(s); }

// A label of 40 characters or more may have been cut short by the emitter (host_of caps at 40, with no
// marker), and a cut label can look like a different valid host, so it is never offered.
var HOST_CAP = 40;
var MCP_TOOL = /^mcp__(.+?)__(.+)/;

// What a Network entry is: a host worth opening ({kind:"host", id: the host}), an MCP server
// ({kind:"mcp", id: the server}), or nothing to list (null). A host is a WebFetch label that is a plain
// hostname, under the emitter's cap, not an IP literal (the last label has a letter), and from a call
// that worked (not failed, not refused).
function classify(e) {
    if (!e || e.station !== "network") return null;
    var mcp = MCP_TOOL.exec(e.tool || "");
    if (mcp) return { kind: "mcp", id: mcp[1] };
    var l = e.label;
    if (e.tool !== "WebFetch" || !l || l.length >= HOST_CAP || !isHost(l)) return null;
    if (!/[A-Za-z]/.test(l.slice(l.lastIndexOf(".") + 1))) return null;
    if (e.status === "err" || e.status === "blocked" || e.dotted === "block") return null;
    return { kind: "host", id: l };
}

// Cheap (in-memory scan, no disk): is there an MCP server or a host in this session's Network entries?
function networkCan(sess) {
    return !!sess && !!sess.entries && sess.entries.some(function (e) { return classify(e) !== null; });
}

// The distinct hosts (a WebFetch label that is a plain hostname) and MCP servers (from the tool name
// mcp__<server>__<tool>) behind the Network entries, with counts, newest first. Only a host carries
// `host`, the one thing that may be opened; a server is `kind: "mcp"` and opens nothing.
function networkItems(sess, key, max) {
    if (!sess || !sess.entries) return [];
    var by = {}, out = [];
    sess.entries.forEach(function (e) {
        var c = classify(e);
        if (!c) return;
        var id = c.kind + ":" + c.id;
        var it = by[id];
        if (!it) {
            it = by[id] = c.kind === "mcp" ? { label: c.id, kind: "mcp", action: "mcp", count: 0, ts: 0 }
                                           : { label: c.id, kind: "host", action: "openhost", host: c.id, count: 0, ts: 0 };
            out.push(it);
        }
        it.count++;
        if (e.ts >= it.ts) it.ts = e.ts;
    });
    out.sort(function (a, b) { return b.ts - a.ts; });
    return out.slice(0, max || 12);
}

// Background tasks of the shell station. `can` only looks at whether sess.tasks has an entry.
function shellTasks(sess) {
    var out = [];
    if (!sess || !sess.tasks) return out;
    Object.keys(sess.tasks).forEach(function (id) {
        if (sess.tasks[id].station === "shell") out.push(id);
    });
    return out;
}
function hasTasks(sess) { return shellTasks(sess).length > 0; }

// The click-time list: running tasks first, then finished ones, each newest first, with the status
// and the elapsed time (since the start, or between start and end). `task` marks the item as a task
// to look up by id (the label is only what the map shows).
function taskItems(sess, key, max) {
    var now = Date.now() / 1000;
    var list = shellTasks(sess).map(function (id) {
        var t = sess.tasks[id];
        var end = t.status === "running" ? now : (t.end !== undefined ? t.end : null);
        var sub = t.status + (end !== null ? " \u00b7 " + durationLabel((end - t.since) * 1000) : "");
        return { task: id, label: t.label || id, count: 1, status: t.status, since: t.since, sub: sub };
    });
    list.sort(function (a, b) {
        var ra = a.status === "running" ? 0 : 1, rb = b.status === "running" ? 0 : 1;
        return ra !== rb ? ra - rb : b.since - a.since;
    });
    return list.slice(0, max);
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
    if (h.action) return { action: typeof h.action === "function" ? h.action(sess) : h.action };
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
            var sub = it.sub !== undefined ? it.sub : it.count > 1 ? "×" + it.count : "";
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
function lookupArgs(script, kind, label, cwd, dir, sid, task) {
    if (task) return ["python3", "-I", script, "task", task, "--sid", sid || ""];     // the session id alone finds the folder
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
function pickAction(mode, index, items, paths, wins) {
    if (mode === "windows" && wins && wins[index] !== undefined) return { action: "focus", address: wins[index].address };
    // Network rows say what they are (`action` on the item); other stations' items have none.
    if (mode === "items" && items && items[index] !== undefined && items[index].action === "mcp") return { action: "mcp" };
    if (mode === "items" && items && items[index] !== undefined && items[index].action === "openhost")
        return isHost(items[index].host) ? { action: "openhost", host: items[index].host } : { action: "refused" };
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

// ---- Browser: focus a window --------------------------------------------------------------------
// The agent's own Chrome (the chrome-devtools MCP) runs in Backstage, a separate headless desktop that a click
// on the real desktop can neither list nor focus. A session that drove only that browser gets a note saying
// where it is; one that used the Claude-in-Chrome extension (or Playwright and the like) gets the everyday
// windows. The flags are set by board.js for any call, however long ago.
function browserAction(sess) {
    return sess && sess.devtools === true && sess.chromeExt !== true ? "backstage" : "browser";
}

// What `browserwin.py list` answered (`text`), as a click: error (it did not answer a list), none (say so),
// one window (focus it) or several (list them by title, workspace and class to pick from).
// Titles are page titles: shown, never stored.
function onWindows(text) {
    var wins = [], ok = false;
    try {
        var parsed = JSON.parse(text);
        if (Array.isArray(parsed)) {
            ok = true;
            wins = parsed.filter(function (w) {
                return w && typeof w.address === "string" && /^0x[0-9a-f]{1,16}$/.test(w.address);
            });
        }
    } catch (e) { }
    if (!ok) return { action: "error" };          // the lookup failed (no answer, an error): not the same as no window
    if (wins.length === 0) return { action: "none" };
    if (wins.length === 1) return { action: "focus", address: wins[0].address };
    return {
        action: "list", windows: wins,
        rows: wins.map(function (w) { return { text: (typeof w.title === "string" && w.title !== "") ? w.title : (w.class || "window"), sub: [w.workspace ? "ws " + w.workspace : "", w.class || ""].filter(function (x) { return x !== ""; }).join(" \u00b7 ") }; })
    };
}

// The command that lists the browser windows, and the one that focuses one (re-checked by the tool).
function browserListArgs(script) { return ["python3", "-I", script, "list"]; }
function browserFocusArgs(script, address) { return ["python3", "-I", script, "focus", address]; }
