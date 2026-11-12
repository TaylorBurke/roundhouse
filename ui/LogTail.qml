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
    readonly property var active: revision >= 0 && board.active ? board.sessions[board.active] : null

    Process {
        running: true
        command: ["tail", "-n", "500", "-F", "--", root.path]
        stdout: SplitParser {
            onRead: line => { if (Board.foldLine(root.board, line)) root.revision++; }
        }
    }
}
