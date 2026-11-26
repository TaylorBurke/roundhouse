import QtQuick
import QtTest
import Quickshell

// Drives the real roundhouse windows for tests/test_window.py: clicks the stations, a list row, the
// hub and the click-away area with synthesized mouse events (QtTest's TestEvent, the same events a
// pointer sends through the window), and checks what the window does. Each check prints one line,
// "RH-TEST PASS <name>" or "RH-TEST FAIL <name>: <why>", then "RH-TEST DONE" and the service quits.
// The scenario is in `steps` below; test_window.py builds the matching home folder, log and stubs.
// With RH_SHOTS set, a picture of the single-session window is saved there after each step.
Item {
    id: d
    property var windows: []                 // the RoundhouseWindow instances (Variants.instances)
    property var tail: null
    readonly property string shots: Quickshell.env("RH_SHOTS") || ""
    readonly property string stubLog: Quickshell.env("RH_STUB_LOG") || ""

    TestEvent { id: ev }
    // The window's root item cannot be grabbed; a copy of it drawn off to the side can (made per picture).
    Component { id: mirrorC; ShaderEffectSource { x: -100000; recursive: true; live: true; hideSource: false } }

    function log(s) { console.log("RH-TEST " + s); }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        var kids = item.children || [];
        for (var i = 0; i < kids.length; i++) {
            var f = find(kids[i], name);
            if (f) return f;
        }
        return null;
    }
    function win(id) {
        for (var i = 0; i < windows.length; i++) if (windows[i].winId === id) return windows[i];
        return null;
    }
    function one() { return win("w1"); }
    function item(name) { var w = one(); return w ? find(w.contentItem, name) : null; }
    function click(it, button, x, y) {
        if (!it) return false;
        return ev.mouseClick(it, x === undefined ? it.width / 2 : x, y === undefined ? it.height / 2 : y,
                             button || Qt.LeftButton, Qt.NoModifier, -1);
    }
    function station(key, button) { return click(item("station_" + key), button); }
    function row(i) { var l = item("openList"); return l ? click(find(l, "row" + i)) : false; }
    function rows() { return one().listRowsView.map(function (r) { return r.text + (r.sub ? " [" + r.sub + "]" : ""); }); }
    // What the stubs (hyprctl, omarchy, xdg-open, wl-copy ...) were asked to do, one command per line.
    function stubCalls() {
        var x = new XMLHttpRequest();
        try { x.open("GET", "file://" + stubLog, false); x.send(); } catch (e) { return ""; }
        return x.responseText || "";
    }
    function eq(got, want) { return JSON.stringify(got) === JSON.stringify(want) ? "" : "got " + JSON.stringify(got) + ", want " + JSON.stringify(want); }

    // Each step: `act` once, then wait until `ready` is true (or `ms` pass), then `check` returns "" or why it failed.
    property var steps: [
        { name: "both windows load", ms: 8000,
          // shown, laid out and the Files station clickable, for a moment (a click before that is lost)
          ready: function () {
              var f = !!win("all") && !!one() && d.tail.revision > 0 ? item("station_files") : null;
              var up = !!f && one().visible && one().contentItem.width > 0 && f.width > 0 && f.clickable;
              if (!up) { d.upSince = 0; return false; }
              if (!d.upSince) d.upSince = Date.now();
              return Date.now() - d.upSince >= 300;
          },
          check: function () { return one().session ? "" : "the single-session window has no session"; } },
        { name: "left click on Files lists the names the session read", ms: 3000,
          act: function () { return station("files"); },
          ready: function () { return one().listMode === "items"; },
          check: function () { return eq(rows(), ["src/a.ts", "src/b.ts"]); } },   // newest first
        { name: "a click on a name opens the file it resolves to", ms: 8000,
          act: function () { return row(0); },
          ready: function () { return stubCalls().indexOf("omarchy launch editor") >= 0; },
          check: function () {
              if (one().listMode !== "") return "the list stayed open (" + one().listMode + ")";
              return stubCalls().indexOf("/Work/proj/src/a.ts") >= 0 ? "" : "editor not asked for src/a.ts: " + stubCalls();
          } },
        { name: "left click on Memory lists the project's memory files, the read one tagged", ms: 8000,
          act: function () { return station("memory"); },
          ready: function () { return one().listMode === "paths"; },
          check: function () { return eq(rows(), ["notes.md [read]", "MEMORY.md", "other.md"]); } },
        { name: "a click away closes the list", ms: 2000,
          act: function () { var w = one(); return click(item("clickAway"), Qt.LeftButton, 10, w.height - 10); },
          ready: function () { return one().listMode === ""; },
          check: function () { return ""; } },
        { name: "right click on Shell lists its recent calls", ms: 2000,
          act: function () { return station("shell", Qt.RightButton); },
          ready: function () { return one().listMode === "history"; },
          check: function () { return eq(one().listRowsView.length, 1); } },
        { name: "right click on another station with the list open moves the list there", ms: 2000,
          act: function () { var w = one(), m = item("map"), p = m.pos(m.indexOf("files"));
                             return click(item("clickAway"), Qt.RightButton, m.x + p.x, m.y + p.y); },
          ready: function () { return one().listKey === "files" && one().listMode === "history"; },
          check: function () { return ""; } },
        { name: "left click on Hooks lists the configured hooks", ms: 8000,
          act: function () { one().closeList(); return station("hooks"); },
          ready: function () { return one().listMode === "hooks"; },
          check: function () { return rows().length > 0 ? "" : "no rows"; } },
        { name: "a click on the hub with no transcript says so", ms: 8000,
          act: function () { one().closeList(); return click(item("hub")); },
          ready: function () { return one().toastText !== ""; },
          check: function () { return eq(one().toastText, "No transcript found for this session"); } },
        { name: "left click on You with no terminal known says so", ms: 2000,
          act: function () { one().clearToast(); return station("you"); },
          ready: function () { return one().toastText !== ""; },
          check: function () { return one().listMode !== "" ? "a list opened: " + one().listMode : eq(one().toastText, "No terminal known for this session"); } },
        { name: "the all-sessions window shows the session too", ms: 2000,
          ready: function () { return win("all").shownSid === one().sid; },
          check: function () { return eq(one().sid, "abcd1234"); } }
    ]

    property int at: -1
    property real upSince: 0
    property real since: 0
    property bool acted: false
    function next() {
        at++;
        acted = false;
        since = Date.now();
        if (at >= steps.length) { if (shots !== "") log("NOTE pictures in " + shots); log("DONE"); Qt.quit(); }
    }
    Component { id: laterC; Timer { property var fn: null; running: true; onTriggered: { fn(); destroy(); } } }
    function later(ms, fn) { laterC.createObject(d, { interval: ms, fn: fn }); }
    function shoot(name, then) {
        var w = one();
        if (shots === "" || !w || !w.contentItem) { then(); return; }
        var file = shots + "/" + String(at).padStart(2, "0") + "-" + name.replace(/[^A-Za-z0-9]+/g, "-").replace(/-+$/, "") + ".png";
        var m = mirrorC.createObject(w.contentItem, { sourceItem: w.contentItem, width: w.contentItem.width, height: w.contentItem.height });
        var over = false;                     // a grab that never answers must not stop the run: 2 s, then on
        var done = function () { if (over) return; over = true; if (m) m.destroy(); then(); };
        d.later(2000, function () { if (!over) d.log("NOTE no picture for " + file); done(); });
        var ok = !!m && m.grabToImage(function (r) { if (!r.saveToFile(file)) d.log("NOTE could not save " + file); done(); });
        if (!ok) { d.log("NOTE could not grab the window"); done(); }
    }
    Timer {
        id: pump
        interval: 50; repeat: true; running: true
        onTriggered: {
            if (d.at < 0) { d.next(); return; }
            if (d.at >= d.steps.length) return;
            var s = d.steps[d.at];
            var ready = false;
            try {
                // an act that could not click (its item missing or not shown) fails at once, not by a timeout
                if (!d.acted) { d.acted = true; if (s.act && s.act() === false) { d.log("FAIL " + s.name + ": could not click"); d.next(); } return; }
                ready = s.ready();
            } catch (e) { d.log("FAIL " + s.name + ": " + e); d.next(); return; }
            if (!ready && Date.now() - d.since < s.ms) return;
            var why = "";
            try { why = ready ? s.check() : "timed out after " + s.ms + " ms"; } catch (e) { why = String(e); }
            d.log((why === "" ? "PASS " : "FAIL ") + s.name + (why === "" ? "" : ": " + why));
            pump.running = false;
            d.shoot(s.name, function () { pump.running = true; d.next(); });
        }
    }
}
