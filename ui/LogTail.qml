import QtQuick
import Quickshell
import Quickshell.Io
import "board.js" as Board

// Follows the emitter's log and folds every line into `board`. `tail -F` waits for a log
// that does not exist yet and starts over when the emitter cuts the file back; the board
// ignores the replayed lines.
Item {
    id: root
    property var board: Board.newBoard()
    property int revision: 0                  // bumps after every change; bind to it to redraw
    readonly property string path: {
        var dir = Quickshell.env("LOT_MAP_DIR");
        if (!dir) dir = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp/lot-map-" + Quickshell.env("UID")) + "/lot-map";
        return dir + "/events.jsonl";
    }
    // An event that is happening now (not history replayed at start-up) in the session on show.
    // `blocked` lists the calls that event just marked blocked.
    signal live(var ev, var blocked)
    // Which session is on show: the one pinned here while it is live, else the most recently
    // active. `tick` makes the choice (and the idle clock) re-evaluate as time passes.
    property string pinned: ""
    property int tick: 0
    function now() { return Date.now() / 1000; }
    readonly property string shownSid: revision >= 0 && tick >= 0 ? (Board.activeSid(board, pinned, now()) || "") : ""
    readonly property var active: shownSid ? board.sessions[shownSid] : null
    readonly property bool isPinned: pinned !== "" && pinned === shownSid
    readonly property var sessionList: revision >= 0 && tick >= 0
        ? Board.liveSessions(board, now()).map(function (s) { return { sid: s.sid, name: s.dir || s.sid, idle: now() - s.lastTs }; })
        : []
    function pick(sid) { pinned = sid; }
    function follow() { pinned = ""; }
    function cycle(dir) { pinned = Board.cycleSid(board, shownSid, dir, now()); }
    Timer { interval: 20000; running: true; repeat: true; onTriggered: root.tick++ }

    Process {
        running: true
        command: ["tail", "-n", "500", "-F", "--", root.path]
        stdout: SplitParser {
            onRead: line => {
                var ev = Board.foldLine(root.board, line);
                if (!ev) return;
                root.revision++;
                if (ev.sid === Board.activeSid(root.board, root.pinned, root.now()) && root.now() - ev.ts < 5)
                    root.live(ev, root.board.sessions[ev.sid].newlyBlocked);
            }
        }
    }
}
