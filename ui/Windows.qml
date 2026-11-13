import QtQuick
import Quickshell
import Quickshell.Io

// Which windows to show: the entries of $XDG_RUNTIME_DIR/lot-map/windows.json, changed with
// bin/roundhouse (see tools/windows.py). Watched, and re-read every two seconds because the
// file is replaced rather than edited. This is also what ends the service: with nothing left
// to show it quits, and bin/roundhouse starts it again when something is.
Item {
    id: root
    property var tail: null
    property var entries: []               // [{ id, sid }] ; sid "*" is the all-sessions window
    property bool loaded: false
    readonly property var ids: entries.map(e => e.id)
    // Quickshell will not resolve a URL outside the config folder (it becomes qrc:/qs-blackhole),
    // so the launcher, which sits beside ui/, is found with shellPath.
    readonly property string launcher: Quickshell.shellPath("../bin/roundhouse")
    readonly property string path: {
        var dir = Quickshell.env("LOT_MAP_DIR");
        if (!dir) dir = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp/lot-map-" + Quickshell.env("UID")) + "/lot-map";
        return dir + "/windows.json";
    }
    property var asked: ({})               // sid -> when a hide was last requested, to ask once

    function sidOf(id) {
        for (var i = 0; i < entries.length; i++) if (entries[i].id === id) return entries[i].sid;
        return "";
    }
    function run(args) { Quickshell.execDetached([launcher].concat(args)); }
    function show(sid) { run(["show", sid]); }
    function hide(sid) {
        var last = asked[sid] || 0;
        if (Date.now() - last < 3000) return;
        asked[sid] = Date.now();
        run(["hide", sid]);
    }

    function apply(text) {
        var list = [];
        try {
            var data = JSON.parse(text);
            if (data && Array.isArray(data.shown))
                list = data.shown.filter(e => e && typeof e.id === "string" && typeof e.sid === "string"
                                              && /^[\w]{1,16}$/.test(e.id) && /^(\*|[\w-]{1,8})$/.test(e.sid))
                                 .map(e => ({ id: e.id, sid: e.sid }));
        } catch (e) { list = []; }
        loaded = true;
        if (JSON.stringify(list) !== JSON.stringify(entries)) entries = list;
    }

    // A session that has ended closes its window (a /clear is not an end).
    function sweep() {
        if (!tail) return;
        entries.forEach(function (e) {
            var s = e.sid !== "*" ? tail.board.sessions[e.sid] : null;
            if (s && s.ended && s.endReason !== "clear") hide(e.sid);
        });
    }
    Connections { target: root.tail; function onRevisionChanged() { root.sweep(); } }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.apply(text())
        onLoadFailed: root.apply("")
    }
    Timer { interval: 2000; running: true; repeat: true; onTriggered: file.reload() }

    Timer {
        id: quitTimer
        interval: 1500
        running: root.loaded && root.entries.length === 0
        onTriggered: if (root.entries.length === 0) Qt.quit()
    }
}
