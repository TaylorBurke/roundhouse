import QtQuick
import Quickshell
import Quickshell.Io

// What claude-strip knows about each session (task title, phase, tools running, context, the
// terminal's window), by session id, from tools/strip_state.py. Optional: without the strip,
// or with an older mod that writes no session id, `bySid` stays empty. Polled every two
// seconds, and only while `active` (a window for one session is shown).
Item {
    id: root
    property bool active: false
    property var bySid: ({})
    readonly property string script: Quickshell.shellPath("../tools/strip_state.py")

    Process {
        id: scan
        // Output is capped, and the timer below kills a hung read.
        command: ["sh", "-c", "python3 -I \"$1\" | head -c 65536", "roundhouse-strip", root.script]
        stdout: StdioCollector {
            onStreamFinished: {
                var next = {};
                try {
                    var parsed = JSON.parse(text);
                    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) next = parsed;
                } catch (e) { next = {}; }
                if (JSON.stringify(next) !== JSON.stringify(root.bySid)) root.bySid = next;
            }
        }
    }
    Timer { interval: 5000; running: scan.running; onTriggered: scan.running = false }
    Timer {
        interval: 2000; running: root.active; repeat: true; triggeredOnStart: true
        onTriggered: if (!scan.running) scan.running = true
    }
    onActiveChanged: if (!active) bySid = ({})
}
