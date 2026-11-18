import QtQuick
import Quickshell
import Quickshell.Io
import "board.js" as Board
import "follow.js" as Follow
import "openlist.js" as OpenList

// One roundhouse window. The all-sessions one (sid "*") has the switcher and follows whichever
// session is active; any other is fixed to its session, so a terminal and its map belong together.
// `winId` is the window's own stable id; its session can change under it (a /clear), in place.
FloatingWindow {
    id: win
    required property string winId
    required property var tail
    required property var theme
    required property var settings
    required property var windows
    required property var strips

    readonly property string sid: windows.sidOf(winId)
    readonly property bool all: sid === "*"
    property string pinned: ""            // the all-sessions window: a session picked by hand
    property int tick: 0
    function now() { return Date.now() / 1000; }

    readonly property string shownSid: all ? (tail.revision >= 0 && tick >= 0 ? (Board.activeSid(tail.board, pinned, now()) || "") : "") : sid
    readonly property var session: shownSid && tail.revision >= 0 ? (tail.board.sessions[shownSid] || null) : null
    // What the session's claude-strip says (task, phase, tools, context, terminal), if there is one.
    readonly property var strip: !all && strips.bySid[shownSid] ? strips.bySid[shownSid] : null
    readonly property string name: strip && strip.project ? strip.project : (session && session.dir ? session.dir : shownSid)
    readonly property var sessionList: tail.revision >= 0 && tick >= 0
        ? Board.liveSessions(tail.board, now()).map(function (s) { return { sid: s.sid, name: s.dir || s.sid, idle: now() - s.lastTs }; })
        : []
    readonly property bool isPinned: pinned !== "" && pinned === shownSid
    function cycle(dir) { pinned = Board.cycleSid(tail.board, shownSid, dir, now()); }
    Timer { interval: 20000; running: true; repeat: true; onTriggered: win.tick++ }

    // Only a window for a session can be unpinned and named for it; the all-sessions one keeps its title.
    // The session's id ends the title so no two windows share one (follow.py finds a window by it).
    title: all ? "roundhouse" : "roundhouse: " + (name || "session") + " · " + sid

    // When the session's terminal is moved to another workspace, this window goes along. Only a
    // change in the terminal's workspace moves it, so a window you placed by hand stays put until
    // then. It follows quietly, without taking the focus. (The strip state is read every 2 s.)
    readonly property int terminalWorkspace: strip && typeof strip.workspace === "number" ? strip.workspace : 0
    property int lastTerminalWorkspace: 0
    onTerminalWorkspaceChanged: {
        var d = Follow.step(lastTerminalWorkspace, terminalWorkspace);
        // follow.py finds the window by the session id that ends its title, so a folder name that
        // changes at the same moment cannot make it miss.
        if (d.move && !win.all)     // the all-sessions window has no terminal of its own to follow
            Quickshell.execDetached(["python3", "-I", Quickshell.shellPath("../tools/follow.py"), win.sid, String(terminalWorkspace)]);
        lastTerminalWorkspace = d.last;
    }
    implicitWidth: 360
    implicitHeight: 680
    visible: true
    color: theme.bg

    // Closed from outside (the window manager): take it out of the set.
    onVisibleChanged: if (!visible && windows.sidOf(winId) !== "") windows.hide(sid)

    Connections {
        target: win.tail
        function onLive(ev, blocked) { if (ev.sid === win.shownSid) map.handle(ev, blocked); }
    }

    // keyboard (all-sessions window): [ ] or the arrow keys step through sessions, space shows the
    // list (1-9 pick from it), a follows the most recently active, w opens the session in a window
    // of its own, escape closes the list
    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape && win.listMode !== "") { win.closeList(); event.accepted = true; return; }
            if (!win.all) return;
            var k = event.key, t = event.text;
            if (k === Qt.Key_Left || t === "[") win.cycle(-1);
            else if (k === Qt.Key_Right || t === "]") win.cycle(1);
            else if (t === "a") { switcher.open = false; win.pinned = ""; }
            else if (t === "w" && win.shownSid) win.windows.show(win.shownSid);
            else if (k === Qt.Key_Space) switcher.open = !switcher.open;
            else if (k === Qt.Key_Escape) switcher.open = false;
            else if (switcher.open && t >= "1" && t <= "9" && win.sessionList[parseInt(t) - 1]) switcher.choose(win.sessionList[parseInt(t) - 1].sid);
            else return;
            event.accepted = true;
        }
    }

    // A session's own window: a band at the very top with the strip's text, so it is plain which
    // terminal it belongs to. A click focuses the terminal. The address was checked by the reader
    // and is checked again here, so nothing but a window address can reach the command.
    StripHeader {
        id: head
        z: 10
        anchors { left: parent.left; right: parent.right; top: parent.top }
        visible: !win.all
        height: visible ? implicitHeight : 0
        info: win.strip
        name: win.name
        model: win.session ? win.session.model : ""
        ended: win.session ? win.session.ended : false
        band: Qt.darker(theme.bg, 1.35)
        ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent; alert: theme.alert
        // Dragging the band moves the window: the compositor takes over the move.
        onDragStarted: win.startSystemMove()
        onActivate: {
            var a = win.strip ? win.strip.address : "";
            if (/^0x[0-9a-f]{1,16}$/.test(a))
                Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = 'address:" + a + "' })"]);
        }
    }

    MapView {
        id: map
        anchors { left: parent.left; right: parent.right; top: head.bottom }
        height: Math.min(parent.width, (parent.height - head.height) * 0.6)
        session: win.session
        revision: win.tail.revision
        windowSetting: win.settings.contextWindow
        bg: theme.bg; disc: theme.disc; discEdge: theme.discEdge; line: theme.line; ring: theme.ring
        ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
        accent: theme.accent; alert: theme.alert; memory: theme.memory
        listOpen: win.listMode !== ""
        onNodeClicked: (key, anchor) => win.nodeClicked(key, anchor)
        onNodeRightClicked: (key, anchor) => win.nodeRightClicked(key, anchor)
    }

    Item {
        id: bar
        z: 10
        height: win.all ? 24 : 0
        anchors { left: parent.left; right: parent.right; top: map.bottom; leftMargin: 12; rightMargin: 12; topMargin: 2 }

        SessionSwitcher {
            id: switcher
            anchors.fill: parent
            visible: win.all
            sessions: win.sessionList
            shown: win.shownSid
            shownName: win.name
            pinned: win.isPinned
            ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent
            disc: theme.disc; discEdge: theme.discEdge
            onPick: sid => win.pinned = sid
            onFollow: win.pinned = ""
            onCycle: dir => win.cycle(dir)
        }
    }

    // ---- clicking a station: open the file behind a name --------------------------------------
    // Files, Memory and Skills react to a click (the map shows a pointing hand there). One name is
    // looked up and opened at once; several are listed to pick from; a name that matches several
    // files lists those. The log keeps no full paths, so the lookup (tools/openable.py) happens now,
    // under the session's folder; names only are read, and opening only ever hands one existing
    // file in the home folder to the editor.
    property string listMode: ""            // "" closed; "items" names from the map; "paths" files found for one name; "note" a message; "history" recent calls
    property string listKey: ""
    property var listItems: []              // the names (mode "items")
    property var listPaths: []              // the files found (mode "paths")
    property var listRowsView: []
    property string listTitle: ""
    property string listNote: ""
    property point listAnchor: Qt.point(0, 0)
    property string lookingFor: ""
    readonly property string home: Quickshell.env("HOME") || ""

    // Each lookup has a number. Closing the list, a new lookup or another session retires the current
    // one: its answer, whenever it arrives, is ignored (so a cancelled click never opens a file, and
    // two clicks in a row never mix their results).
    property int lookupSeq: 0
    function closeList() { lookupSeq++; listMode = ""; noteTimer.stop(); }
    onShownSidChanged: { closeList(); clearToast(); }
    onListModeChanged: if (listMode !== "") clearToast()      // a list and a toast never show together

    function nodeClicked(key, anchor) {
        var d = OpenList.onClick(key, session, Board);
        if (d.action === "none") return;
        clearToast();
        listKey = key; listAnchor = anchor;
        listTitle = Board.report(null, key).title;
        if (d.action === "memory") lookupMemory();       // whether or not any file was touched
        else if (d.action === "resolve") lookup(d.item);
        else { lookupSeq++; listItems = d.items; listRowsView = d.rows; listMode = "items"; noteTimer.stop(); }
    }
    // A right click on any station: its recent calls, newest first (names only, from the log), or a
    // toast when there are none. The rows are a snapshot of the moment of the click.
    function nodeRightClicked(key, anchor) {
        var calls = Board.history(session, key, 10);
        if (calls.length === 0) {
            closeList();
            toast("Nothing at " + Board.report(null, key).title + " yet");
            return;
        }
        clearToast();
        listKey = key; listAnchor = anchor;
        lookupSeq++; listItems = []; listPaths = [];
        listTitle = Board.report(null, key).title + " \u00b7 recent";
        listRowsView = OpenList.historyRows(calls, now());
        listMode = "history"; noteTimer.stop();
    }
    function lookup(item) {
        var seq = ++lookupSeq;
        lookingFor = item.label;
        listNote = "Looking for " + item.label + "\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        var args = OpenList.lookupArgs(Quickshell.shellPath("../tools/openable.py"), listKey, item.label,
                                       strip && strip.cwd ? strip.cwd : "", session && session.dir ? session.dir : "", shownSid);
        finderC.createObject(win.contentItem, { seq: seq, command: args });
    }
    function lookupMemory() {
        var seq = ++lookupSeq;
        lookingFor = "";
        listNote = "Looking for memory files\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        var args = OpenList.memoryListArgs(Quickshell.shellPath("../tools/openable.py"),
                                           strip && strip.cwd ? strip.cwd : "", session && session.dir ? session.dir : "", shownSid);
        finderC.createObject(win.contentItem, { seq: seq, command: args });
    }
    function found(seq, text) {
        if (!OpenList.accepts(seq, lookupSeq, listMode)) return;     // cancelled, or another lookup took over
        var d = OpenList.onResolved(OpenList.parsePaths(text));
        if (d.action === "open") { openPath(d.path); closeList(); }
        else if (d.action === "choose") {
            var r = OpenList.pathRows(d.paths, listKey === "memory" ? "memoryfiles" : listKey, home, 10);
            listPaths = r.paths; listRowsView = r.rows;
            listTitle = listKey === "memory" ? "Memory" : Board.report(null, listKey).title + " \u00b7 " + lookingFor;
            listMode = "paths";
        } else {
            listNote = listKey === "memory" ? "No memory files found for this project" : "Could not find " + lookingFor;
            listRowsView = []; listMode = "note"; noteTimer.restart();
        }
    }
    function picked(index) {
        var d = OpenList.pickAction(listMode, index, listItems, listPaths);
        if (d.action === "lookup") lookup(d.item);
        else if (d.action === "open") { openPath(d.path); closeList(); }
    }
    function openPath(path) {
        Quickshell.execDetached(["python3", "-I", Quickshell.shellPath("../tools/openable.py"), "open", path]);
    }
    // one short-lived process per lookup, stopped after 8 s if it hangs, and gone once it has answered
    Component {
        id: finderC
        Item {
            id: job
            property int seq: 0
            property var command: []
            Process {
                id: proc
                command: job.command
                running: true
                stdout: StdioCollector { onStreamFinished: { win.found(job.seq, text); job.destroy(); } }
            }
            Timer { interval: 8000; running: true; onTriggered: proc.running = false }
        }
    }
    Timer { id: noteTimer; interval: 2500; onTriggered: win.closeList() }

    // A short note for "nothing to open" and the like. A new one replaces the one showing.
    property string toastText: ""
    function toast(text) { toastText = text; toastTimer.restart(); }
    function clearToast() { toastText = ""; toastTimer.stop(); }
    Timer { id: toastTimer; interval: 2500; onTriggered: win.toastText = "" }
    Rectangle {
        objectName: "toast"
        z: 110
        visible: win.toastText !== ""
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 16 }
        width: Math.min(parent.width - 24, toastLabel.implicitWidth + 24); height: toastLabel.implicitHeight + 14
        radius: 6; color: Qt.darker(theme.bg, 1.4); border.color: theme.discEdge; border.width: 1
        Text {
            id: toastLabel
            anchors.centerIn: parent; width: parent.width - 24
            text: win.toastText
            textFormat: Text.PlainText; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
            color: theme.inkStrong; font.family: "monospace"; font.pixelSize: 11
        }
    }

    MouseArea {                              // a click anywhere else closes the list
        anchors.fill: parent
        z: 90
        visible: win.listMode !== ""
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            // a right click on a station opens that station's recent calls, as it does with no list open
            var at = mouse.button === Qt.RightButton ? map.stationAt(mouse.x - map.x, mouse.y - map.y) : "";
            if (at !== "") win.nodeRightClicked(at, map.pos(map.indexOf(at)));
            else win.closeList();
        }
    }
    OpenList {
        id: openList
        z: 100
        visible: win.listMode !== ""
        title: win.listTitle
        rows: win.listRowsView
        message: win.listMode === "note" ? win.listNote : ""
        interactive: win.listMode !== "history"
        elideMode: win.listMode === "paths" ? Text.ElideLeft : Text.ElideRight
        bg: theme.bg; ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent; edge: theme.discEdge
        readonly property point at: Qt.point(map.x + win.listAnchor.x, map.y + win.listAnchor.y)
        x: Math.max(8, Math.min(parent.width - width - 8, at.x - width / 2))
        y: Math.max(4, Math.min(parent.height - height - 4, win.listAnchor.y < map.height * 0.45 ? at.y + map.discR * 2.7 : at.y - map.discR * 1.7 - height))
        onPicked: index => win.picked(index)
    }

    Feed {
        anchors { left: parent.left; right: parent.right; top: bar.bottom; bottom: parent.bottom; margins: 12; topMargin: 6 }
        clip: true
        session: win.session
        revision: win.tail.revision
        ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
        accent: theme.accent; alert: theme.alert
    }
}
