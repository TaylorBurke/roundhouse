// Turns an Omarchy theme file (colors.toml) into the palette the window uses. Plain JS so it
// can be tested on its own. Only #rrggbb values are accepted; anything else is ignored.

var HEX = /^#[0-9a-fA-F]{6}$/;

// The palette used when there is no theme file (the built-in dark look).
var FALLBACK = {
    light: false,
    bg: "#0b0d12", disc: "#12151c", discEdge: "#2c3240", line: "#252a36", ring: "#1c212b",
    ink: "#8d96ab", inkStrong: "#d7dcea", faint: "#4a5164",
    accent: "#e0a458", alert: "#f7768e", memory: "#5fb3a6"
};

// colors.toml has flat `key = "value"` lines, with # comments.
function parseColors(text) {
    var out = {};
    String(text || "").split("\n").forEach(function (line) {
        var m = /^\s*([A-Za-z_][\w]*)\s*=\s*"([^"]*)"/.exec(line);
        if (m) out[m[1]] = m[2];
    });
    return out;
}

function rgb(hex) {
    return [parseInt(hex.substr(1, 2), 16), parseInt(hex.substr(3, 2), 16), parseInt(hex.substr(5, 2), 16)];
}

// `t` of the way from colour a to colour b, as "#rrggbb".
function mix(a, b, t) {
    var x = rgb(a), y = rgb(b), out = "#";
    for (var i = 0; i < 3; i++) {
        var v = Math.round(x[i] + (y[i] - x[i]) * t);
        out += (v < 16 ? "0" : "") + Math.max(0, Math.min(255, v)).toString(16);
    }
    return out;
}

function luminance(hex) {
    var c = rgb(hex);
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255;
}

// The palette for a theme. Surfaces and text are mixed from background and foreground, so a
// light theme (dark text on a light background) comes out right with the same recipe.
function derive(colors) {
    var c = colors || {};
    function pick(key, fallback) { return HEX.test(c[key] || "") ? c[key] : fallback; }
    var hasBase = HEX.test(c.background || "") && HEX.test(c.foreground || "");
    if (!hasBase) {
        var p = {};
        for (var k in FALLBACK) p[k] = FALLBACK[k];
        p.accent = pick("accent", p.accent); p.alert = pick("red", p.alert); p.memory = pick("cyan", p.memory);
        return p;
    }
    var bg = c.background, fg = c.foreground;
    return {
        light: c.mode === "light" || (c.mode !== "dark" && luminance(bg) > 0.5),
        bg: bg,
        disc: mix(bg, fg, 0.06), discEdge: mix(bg, fg, 0.2), line: mix(bg, fg, 0.14), ring: mix(bg, fg, 0.09),
        ink: mix(bg, fg, 0.68), inkStrong: pick("bright_foreground", mix(bg, fg, 1)),
        faint: pick("muted", mix(bg, fg, 0.42)),
        accent: pick("accent", FALLBACK.accent), alert: pick("red", FALLBACK.alert), memory: pick("cyan", FALLBACK.memory)
    };
}

if (typeof module !== "undefined") module.exports = { parseColors: parseColors, derive: derive, mix: mix, FALLBACK: FALLBACK };
