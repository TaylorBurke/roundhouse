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
    // An event that is happening now (not history replayed at start-up), from any session; each
    // window decides whether it is its own. `blocked` lists the calls that event just marked blocked.
    signal live(var ev, var blocked)
    function now() { return Date.now() / 1000; }

    Process {
        running: true
        command: ["tail", "-n", "500", "-F", "--", root.path]
        stdout: SplitParser {
            onRead: line => {
                var ev = Board.foldLine(root.board, line);
                if (!ev) return;
                root.revision++;
                if (root.now() - ev.ts < 5) root.live(ev, root.board.sessions[ev.sid].newlyBlocked);
            }
        }
    }
}
