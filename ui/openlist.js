.pragma library

// What a click on a map station does, and what happens when the on-disk lookup answers.

// The names a station can open (from Board.openables): none, one (look it up and open it), or
// several (list them to pick from).
function onNode(items) {
    if (!items || items.length === 0) return { action: "none" };
    if (items.length === 1) return { action: "resolve", item: items[0] };
    return {
        action: "list", items: items,
        rows: items.map(function (it) { return { text: it.label, sub: it.count > 1 ? "×" + it.count : "" }; })
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
