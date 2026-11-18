.pragma library

// The hub's context panel: what a click on the hub shows, from `tools/transcript.py context SID`.
// Pure helpers (parsing the answer, thinning the points, wording), so they can be tested with canned JSON.

var SPARK_POINTS = 60;        // the sparkline is thinned to about this many points
var MAX_COMPACTIONS = 5;      // newest compactions listed; a last row says how many more

// Whether the hub reacts to a click. Cheap, in memory only: a context reading has arrived, or the
// session has logged anything (so there is a transcript to look at). The transcript is read at click time.
function canClickHub(sess) {
    return !!sess && (!!sess.hasContext || (!!sess.entries && sess.entries.length > 0));
}

function num(v) { return typeof v === "number" && isFinite(v) && v >= 0 ? v : 0; }

// The tool's answer as one object: { found, points: [tokens_in...], peak, count, compactions, partial,
// capped, ambiguous }. Anything that is not the expected JSON is { found: false }.
function parse(text) {
    var j;
    try { j = JSON.parse(text); } catch (e) { return { found: false }; }
    if (!j || typeof j !== "object" || !j.found || !j.context || typeof j.context !== "object") return { found: false };
    var c = j.context;
    var pts = Array.isArray(c.points) ? c.points.map(function (p) { return num(p && p.tokens_in); }) : [];
    var comps = Array.isArray(c.compactions) ? c.compactions.filter(function (k) { return k && typeof k === "object"; }).map(function (k) {
        return { ts: typeof k.ts === "string" ? k.ts : "", trigger: typeof k.trigger === "string" ? k.trigger : "",
                 pre: num(k.pre_tokens), post: num(k.post_tokens) };
    }) : [];
    return { found: true, points: pts, peak: num(c.peak), count: num(c.point_count) || pts.length, compactions: comps,
             partial: !!c.partial, capped: !!j.capped, ambiguous: !!j.ambiguous };
}

// Evenly thinned to at most n points, always keeping the first and the last.
function thin(points, n) {
    var max = n || SPARK_POINTS;
    if (!points || points.length <= max) return (points || []).slice();
    var out = [];
    for (var i = 0; i < max; i++) out.push(points[Math.round(i * (points.length - 1) / (max - 1))]);
    return out;
}

// 950 -> "950", 12400 -> "12k", 1250000 -> "1.3M"
function tok(n) {
    n = num(n);
    if (n >= 1000000) return (Math.round(n / 100000) / 10) + "M";
    if (n >= 1000) return Math.round(n / 1000) + "k";
    return String(Math.round(n));
}

// One honest line about what the numbers may miss, or "".
function note(d) {
    var parts = [];
    if (d.partial) parts.push("only the end of a very large transcript was read, so the peak and history may be incomplete");
    if (d.capped) parts.push("the oldest points were dropped to fit");
    if (d.ambiguous) parts.push("several sessions share this id; showing the newest");
    if (parts.length === 0) return "";
    var s = parts.join("; ");
    return s.charAt(0).toUpperCase() + s.slice(1) + ".";
}

// "14:02" from an ISO timestamp, in local time; "" when it cannot be read.
function clock(ts) {
    var t = Date.parse(ts);
    if (isNaN(t)) return "";
    var d = new Date(t);
    return (d.getHours() < 10 ? "0" : "") + d.getHours() + ":" + (d.getMinutes() < 10 ? "0" : "") + d.getMinutes();
}

// The compaction history, newest first, as rows { text, sub }: "14:02 auto" and "168k -> 21k".
function compactionRows(list) {
    var all = (list || []).slice().reverse();
    var rows = all.slice(0, MAX_COMPACTIONS).map(function (k) {
        var after = k.post > 0 ? tok(k.post) : "?";
        return { text: [clock(k.ts), k.trigger].filter(function (x) { return x !== ""; }).join(" ") || "compaction",
                 sub: (k.pre > 0 ? tok(k.pre) : "?") + " → " + after };
    });
    if (all.length > MAX_COMPACTIONS) rows.push({ text: "… and " + (all.length - MAX_COMPACTIONS) + " more", sub: "" });
    return rows;
}

// The command: python3 -I tools/transcript.py context SID (8 characters, as the tool checks again).
function args(script, sid) {
    return ["python3", "-I", script, "context", String(sid).slice(0, 8)];
}
