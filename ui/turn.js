.pragma library

// The Model station's turn panel: what tools/transcript.py says about the current turn, as rows to show.
// Everything here is plain data in, plain data out. Reasoning text is only ever put on screen: it is not
// logged, not stored, and never part of a command line (the commands below carry the session id only).

var SHOW_STEPS = 8;          // the last steps shown
var SHOW_CHARS = 400;        // characters of reasoning shown per step
var SID_RE = /^[A-Za-z0-9_-]{8}$/;

function validSid(sid) { return typeof sid === "string" && SID_RE.test(sid); }

// python3 tools/transcript.py turn SID, and ... open SID. The id is the only argument; the tool finds the
// file itself and checks it again.
function turnArgs(script, sid) { return ["python3", "-I", script, "turn", sid]; }
function openArgs(script, sid) { return ["python3", "-I", script, "open", sid]; }

function clean(s, n) {
    if (typeof s !== "string") return "";
    return s.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ").trim().slice(0, n);
}

function num(v) { return typeof v === "number" && isFinite(v) && v >= 0 ? v : 0; }

function count(n) { return Math.round(num(n)).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ","); }

function span(ms) {
    var m = num(ms);
    if (m < 1000) return Math.round(m) + "ms";
    var s = Math.round(m / 100) / 10;
    return s < 60 ? s + "s" : Math.floor(s / 60) + "m" + Math.round(s % 60) + "s";
}

// The transcript tool's answer as { found, error, note, summary, steps: [{ head, text, tools }] }.
// `found` is false for an answer that is not a found transcript with a turn (unparseable, not found,
// unreadable). `note` is one honest line about what may be incomplete, or "".
function parse(text) {
    var j;
    try { j = JSON.parse(text); } catch (e) { return { found: false, error: "unreadable", steps: [], note: "", summary: "" }; }
    if (!j || typeof j !== "object" || !j.found || !j.turn || typeof j.turn !== "object")
        return { found: false, error: j && j.error ? "unreadable" : "missing", steps: [], note: "", summary: "" };
    var t = j.turn, all = Array.isArray(t.steps) ? t.steps : [];
    var shown = all.slice(-SHOW_STEPS);
    var steps = shown.map(function (s) {
        s = s && typeof s === "object" ? s : {};
        var parts = ["think " + span(s.think_ms), "in " + count(s.tokens_in), "out " + count(s.tokens_out)];
        var reason = clean(s.thinking, SHOW_CHARS);
        var tools = Array.isArray(s.tools) ? s.tools.map(function (x) { return clean(x, 40); }).filter(function (x) { return x !== ""; }) : [];
        return { head: parts.join(" · "), text: reason !== "" ? reason : (s.redacted ? "(reasoning redacted)" : ""),
                 tools: tools.length ? tools.join(", ") : "" };
    });
    var totals = t.totals && typeof t.totals === "object" ? t.totals : {};
    var notes = [];
    if (t.partial || totals.exact === false) notes.push("partial: the start of the turn was not read, totals are lower bounds");
    if (j.capped) notes.push("capped: older steps and reasoning were left out");
    else if (num(t.step_count) > shown.length) notes.push("showing the last " + shown.length + " of " + num(t.step_count) + " steps");
    if (j.ambiguous) notes.push("the id matches several sessions, the newest is shown");
    var summary = steps.length + (steps.length === 1 ? " step" : " steps");
    if (typeof t.duration_ms === "number") summary += " · " + span(t.duration_ms);
    if (totals.think_ms !== undefined) summary += " · think " + span(totals.think_ms);
    return { found: true, error: "", steps: steps, note: notes.join("; "), summary: summary };
}
