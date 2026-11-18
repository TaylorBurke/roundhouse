import QtQuick
import Quickshell
import Quickshell.Io
import "board.js" as Board
import "follow.js" as Follow
import "openlist.js" as OpenList
import "turn.js" as Turn
import "contextpanel.js" as CtxPanel

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
        function onLive(ev, blocked) {
            if (ev.sid !== win.shownSid) return;
            map.handle(ev, blocked);
            if (win.listMode === "drafts" && !Board.isIdle(win.session)) win.closeList();      // the session got busy: a stale draft list is not offered
        }
    }

    // keyboard (all-sessions window): [ ] or the arrow keys step through sessions, space shows the
    // list (1-9 pick from it), a follows the most recently active, w opens the session in a window
    // of its own, escape closes the list
    Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape && (win.listMode !== "" || win.ctxOpen)) { win.closeList(); event.accepted = true; return; }
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
        onActivate: win.focusTerminal(OpenList.terminalAddress(win.strip))
    }
    function focusTerminal(a) {
        if (a) Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = 'address:" + a + "' })"]);
    }

    MapView {
        id: map
        anchors { left: parent.left; right: parent.right; top: head.bottom }
        height: Math.min(parent.width, (parent.height - head.height) * 0.6)
        session: win.session
        revision: win.tail.revision
        windowSetting: win.settings.contextWindow
        slowSeconds: win.settings.slowCallSeconds
        bg: theme.bg; disc: theme.disc; discEdge: theme.discEdge; line: theme.line; ring: theme.ring
        ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
        accent: theme.accent; alert: theme.alert; memory: theme.memory
        listOpen: win.listMode !== "" || win.ctxOpen
        onNodeClicked: (key, anchor) => win.nodeClicked(key, anchor)
        onNodeRightClicked: (key, anchor) => win.nodeRightClicked(key, anchor)
        onHubClicked: win.hubClicked()
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
    property string listMode: ""            // "" closed; "items" names from the map; "paths" files found for one name; "note" a message; "history" recent calls; "windows" browser windows to pick from; "agent" one subagent (its calls, and its transcript)
    property string listKey: ""
    property var listItems: []              // the names (mode "items")
    property var listPaths: []              // the files found (mode "paths")
    property var listRowsView: []
    property var listWins: []               // the browser windows found (mode "windows"); page titles, kept in memory only
    property string listTitle: ""
    property string listNote: ""
    property point listAnchor: Qt.point(0, 0)
    property string lookingFor: ""
    readonly property string home: Quickshell.env("HOME") || ""

    // Each lookup has a number. Closing the list, a new lookup or another session retires the current
    // one: its answer, whenever it arrives, is ignored (so a cancelled click never opens a file, and
    // two clicks in a row never mix their results).
    property int lookupSeq: 0
    function closeList() { lookupSeq++; listMode = ""; listWins = []; ctxOpen = false; noteTimer.stop(); turnView = ({ steps: [], note: "", summary: "" }); }
    onShownSidChanged: { closeList(); clearToast(); }
    onListModeChanged: {
        if (listMode !== "") { clearToast(); ctxOpen = false; }      // a list and a toast never show together
        if (listMode !== "turn") turnView = ({ steps: [], note: "", summary: "" });   // reasoning never outlives its panel
    }

    function nodeClicked(key, anchor) {
        var d = OpenList.onClick(key, session, Board, now());
        if (d.action === "none") {       // openable by the cheap check, but the click-time lookup found nothing
            closeList();
            toast("Nothing to open at " + Board.report(null, key).title + " yet");
            return;
        }
        if (d.action === "you") { youClicked(anchor); return; }
        clearToast();
        listKey = key; listAnchor = anchor;
        listTitle = Board.report(null, key).title;
        if (d.action === "backstage") {      // the agent's own Chrome is in Backstage: say so, touch nothing
            closeList();
            toast("The agent's browser is in Backstage; run backstage view to see it");
            return;
        }
        if (d.action === "browser") lookupBrowser();
        else if (d.action === "turn") showTurn();
        else if (d.action === "memory") lookupMemory();       // whether or not any file was touched
        else if (d.action === "hooks") lookupHooks();         // the configured hooks, read now
        else if (d.action === "resolve") lookup(d.item);
        else { lookupSeq++; listItems = d.items; listRowsView = d.rows; listMode = "items"; noteTimer.stop(); }
    }
    // A left click on You: with drafts to offer (idle session, drafts on) it lists them and leaves the
    // focus alone (the list is in this window); otherwise it focuses the terminal. A pick runs
    // tools/draft.py, which focuses the terminal, checks it is the active window and types the text
    // without pressing Enter (the owner reviews and submits). It says why on a refusal.
    function youClicked(anchor) {
        var y = OpenList.onYou(strip, session, settings, Board);
        closeList();
        if (!y.address) { toast(y.toast); return; }
        clearToast();
        if (y.drafts.length === 0) { focusTerminal(y.address); return; }
        listKey = "you"; listAnchor = anchor; listTitle = "Draft";
        lookupSeq++; listItems = y.drafts; listPaths = [];
        listRowsView = y.drafts.map(function (t) { return { text: t, sub: "" }; });
        listMode = "drafts"; noteTimer.stop();
    }
    property bool drafting: false           // draft.py is running: another pick is ignored
    function typeDraft(text) {
        var a = OpenList.terminalAddress(strip);
        if (drafting || !a) return;
        if (!Board.isIdle(session)) { toast("Claude is busy; not typing"); return; }     // checked again at the pick
        drafting = true;
        var job = draftC.createObject(win.contentItem, { command: ["python3", "-I", Quickshell.shellPath("../tools/draft.py"), "type", a, text] });
        if (!job) { drafting = false; toast("Could not start the draft tool"); }
    }
    // `drafting` is cleared only when the process has exited, so two draft.py runs never overlap. After
    // 20 s (longer than the tool's own limits) the process is told to stop; if it cannot be stopped,
    // `drafting` stays true and picks stay ignored until this window is closed.
    Component {
        id: draftC
        Item {
            id: job
            property var command: []
            Process {
                id: proc
                command: job.command
                running: true
                onExited: { win.drafting = false; cleanup.start(); }
                stderr: StdioCollector { onStreamFinished: { if (text.trim() !== "") win.toast(text.trim()); } }
            }
            Timer { interval: 20000; running: true; onTriggered: proc.running = false }
            Timer { id: cleanup; interval: 1000; onTriggered: job.destroy() }      // after the stderr text has arrived
        }
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
    // A click on the hub: the context panel. The transcript is read now (tools/transcript.py context),
    // by a short-lived process like the file lookups; nothing found is a toast, never an empty panel.
    property bool ctxOpen: false
    property var ctxInfo: ({ found: false })
    property bool ctxBusy: false             // a transcript read is running: a second click waits for it
    function hubClicked() {
        if (ctxBusy) return;
        ctxBusy = true;
        var seq = ++lookupSeq;
        listMode = ""; ctxOpen = false; noteTimer.stop(); clearToast();
        ctxC.createObject(win.contentItem, { seq: seq, command: CtxPanel.args(Quickshell.shellPath("../tools/transcript.py"), shownSid) });
    }
    function ctxAnswer(seq, text) {
        if (seq !== lookupSeq || listMode !== "") return;       // closed, or another click took over
        var d = CtxPanel.parse(text);
        if (!d.found) { ctxOpen = false; toast("No transcript found for this session"); return; }
        clearToast(); ctxInfo = d; ctxOpen = true; keys.forceActiveFocus();
    }
    Component {
        id: ctxC
        Item {
            id: ctxJob
            property int seq: 0
            property var command: []
            Component.onDestruction: win.ctxBusy = false
            Process {
                id: ctxProc
                command: ctxJob.command
                running: true
                stdout: StdioCollector { onStreamFinished: { win.ctxAnswer(ctxJob.seq, text); ctxJob.destroy(); } }
            }
            Timer { interval: 8000; running: true; onTriggered: { ctxProc.running = false; ctxJob.destroy(); } }
        }
    }
    function lookup(item) {
        var seq = ++lookupSeq;
        lookingFor = item.label;
        listNote = "Looking for " + item.label + "\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        var args = OpenList.lookupArgs(Quickshell.shellPath("../tools/openable.py"), listKey, item.label,
                                       strip && strip.cwd ? strip.cwd : "", session && session.dir ? session.dir : "", shownSid, item.task || "");
        finderC.createObject(win.contentItem, { seq: seq, command: args });
    }
    // Model: the current turn, read from the transcript now (tools/transcript.py turn SID; the id is the only
    // argument). Shown on screen only: nothing of it is kept beyond these properties, which are cleared
    // when the panel closes. The answer is used only if it is still the current lookup.
    property var turnView: ({ steps: [], note: "", summary: "" })
    function showTurn() {
        if (!Turn.validSid(shownSid)) { closeList(); toast("Transcript not found"); return; }
        var seq = ++lookupSeq;
        listNote = "Reading the transcript\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        turnC.createObject(win.contentItem, { seq: seq, command: Turn.turnArgs(Quickshell.shellPath("../tools/transcript.py"), shownSid) });
    }
    function turnAnswered(seq, text) {
        if (!OpenList.accepts(seq, lookupSeq, listMode)) return;
        var t = Turn.parse(text);
        if (!t.found) {
            closeList();
            toast(t.error === "missing" ? "Transcript not found" : t.error === "empty" ? "No turn yet in this session" : "Could not read the transcript");
            return;
        }
        turnView = t; listMode = "turn";
    }
    function openTranscript() {
        var ok = Turn.validSid(shownSid);
        closeList();
        if (!ok) { toast("Could not open the transcript"); return; }
        openJobC.createObject(win.contentItem, { command: Turn.openArgs(Quickshell.shellPath("../tools/transcript.py"), shownSid) });
    }
    function lookupMemory() {
        var seq = ++lookupSeq;
        lookingFor = "";
        listNote = "Looking for memory files\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        var args = OpenList.memoryListArgs(Quickshell.shellPath("../tools/openable.py"),
                                           strip && strip.cwd ? strip.cwd : "", session && session.dir ? session.dir : "", shownSid);
        finderC.createObject(win.contentItem, { seq: seq, command: args });
    }
    property bool browserBusy: false        // a window lookup is running: a second click waits for it
    function lookupBrowser() {
        if (browserBusy) return;
        browserBusy = true;
        var seq = ++lookupSeq;
        lookingFor = "";
        listNote = "Looking for browser windows\u2026"; listRowsView = []; listMode = "note"; noteTimer.stop();
        finderC.createObject(win.contentItem, { seq: seq, what: "windows",
                             command: OpenList.browserListArgs(Quickshell.shellPath("../tools/browserwin.py")) });
    }
    function foundWindows(seq, text) {
        if (!OpenList.accepts(seq, lookupSeq, listMode)) return;
        var d = OpenList.onWindows(text);
        if (d.action === "focus") { focusBrowser(d.address); closeList(); }
        else if (d.action === "list") {
            listWins = d.windows; listRowsView = d.rows; listTitle = Board.report(null, listKey).title; listMode = "windows";
        } else if (d.action === "error") { closeList(); toast("Could not list windows");
        } else { closeList(); toast("No browser window open"); }
    }
    function focusBrowser(address) {
        finderC.createObject(win.contentItem, { what: "focus", command: OpenList.browserFocusArgs(Quickshell.shellPath("../tools/browserwin.py"), address) });
    }
    function lookupHooks() {
        var seq = ++lookupSeq;
        lookingFor = "";
        listNote = "Reading the hooks…"; listRowsView = []; listMode = "note"; noteTimer.stop();
        finderC.createObject(win.contentItem, { seq: seq, command: OpenList.hooksListArgs(Quickshell.shellPath("../tools/hooklist.py")) });
    }
    function foundHooks(text) {
        var parsed = OpenList.parseHooks(text);
        if (parsed === null) { closeList(); toast("Could not read hooks"); return; }       // a failed read, not an empty list
        var r = OpenList.hookRows(parsed, 16);
        if (r.rows.length === 0) { closeList(); toast("No hooks configured"); return; }
        listPaths = r.targets; listRowsView = r.rows; listTitle = "Hooks"; listMode = "hooks";
    }
    function found(seq, text) {
        if (!OpenList.accepts(seq, lookupSeq, listMode)) return;     // cancelled, or another lookup took over
        if (listKey === "hooks") { foundHooks(text); return; }
        var d = OpenList.onResolved(OpenList.parsePaths(text));
        if (d.action === "open") { openPath(d.path); closeList(); }
        else if (d.action === "choose") {
            var r = OpenList.pathRows(d.paths, listKey === "memory" ? "memoryfiles" : listKey, home, 10);
            listPaths = r.paths; listRowsView = r.rows;
            listTitle = listKey === "memory" ? "Memory" : Board.report(null, listKey).title + " \u00b7 " + lookingFor;
            listMode = "paths";
        } else if (listKey === "shell") {            // a task whose output file is not there: a toast, not a list
            closeList();
            toast("No output file found for " + lookingFor);
        } else {
            listNote = listKey === "memory" ? "No memory files found for this project" : "Could not find " + lookingFor;
            listRowsView = []; listMode = "note"; noteTimer.restart();
        }
    }
    function picked(index) {
        var d = OpenList.pickAction(listMode, index, listItems, listPaths, listWins);
        if (d.action === "focus") { focusBrowser(d.address); closeList(); }
        else if (d.action === "lookup") lookup(d.item);
        else if (d.action === "open") { openPath(d.path); closeList(); }
        else if (d.action === "draft") { closeList(); typeDraft(d.text); }
        else if (d.action === "hookopen") { openHookFile(d.path); closeList(); }
        else if (d.action === "openhost") { openHost(d.host); closeList(); }
        else if (d.action === "agent") showAgent(d.item);
        else if (d.action === "transcript") openTranscript();
        else if (d.action === "mcp") { closeList(); toast("MCP servers open nothing"); }
        else if (d.action === "refused") { closeList(); toast("Not a plain hostname, not opened"); }
    }
    // A picked subagent: its status and the calls it made (from the log), with an action to open its
    // transcript. The transcript's path is only looked up when that row is clicked.
    property var pickedAgent: null
    function showAgent(item) {
        var v = OpenList.agentView(item, Board.agentCalls(session, item.id, 8), now(), 8);
        pickedAgent = item; lookupSeq++; listItems = v.rows; listPaths = []; transcriptBusy = false;   // a new pick retires any lookup (its seq is stale)
        listTitle = v.title; listNote = v.note; listRowsView = v.rows; listMode = "agent"; noteTimer.stop();
    }
    property bool transcriptBusy: false     // a transcript lookup is running: a second click is ignored
    function openTranscript() {
        if (transcriptBusy) return;
        var args = pickedAgent ? OpenList.transcriptArgs(Quickshell.shellPath("../tools/transcript.py"), shownSid, pickedAgent.id) : null;
        if (!args) { closeList(); toast("Transcript not found"); return; }
        var seq = ++lookupSeq;
        transcriptBusy = true;
        finderC.createObject(win.contentItem, { seq: seq, what: "transcript", command: args });
    }
    function transcriptFound(seq, text) {
        if (seq !== lookupSeq || listMode !== "agent") return;       // closed or replaced meanwhile
        if (text.trim() === "") return;                               // no answer: onExited decides (toast, cleanup)
        var p = OpenList.transcriptPath(text);
        closeList();
        if (!p) { toast("Transcript not found"); return; }
        // run as a job so a failed open (exit code not 0) says so instead of vanishing
        finderC.createObject(win.contentItem, { what: "openfile", command: OpenList.openFileArgs(Quickshell.shellPath("../tools/openable.py"), p) });
    }
    function transcriptFailed(seq) {
        if (seq === lookupSeq && listMode === "agent") { closeList(); toast("Could not look up the transcript"); }
    }
    function openHost(host) {
        if (!OpenList.isHost(host)) { toast("Not a plain hostname, not opened"); return; }
        Quickshell.execDetached(OpenList.openHostArgs(Quickshell.shellPath("../tools/openhost.py"), host));
    }
    function openHookFile(path) {
        Quickshell.execDetached(OpenList.hooksOpenArgs(Quickshell.shellPath("../tools/hooklist.py"), path));
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
            property string what: "files"
            Process {
                id: proc
                command: job.command
                running: true
                stdout: StdioCollector { onStreamFinished: {
                    if (job.what === "focus" || job.what === "openfile") return;               // judged by the exit code
                    if (job.what === "transcript") { win.transcriptFound(job.seq, text); job.destroy(); return; }
                    if (job.what === "windows") win.foundWindows(job.seq, text); else win.found(job.seq, text);
                    job.destroy();
                } }
                onExited: (code, status) => {
                    if (job.what === "transcript") {                // killed (timeout), crashed or failed: say so, free the click
                        if (code !== 0) win.transcriptFailed(job.seq);
                        job.destroy(); return;
                    }
                    if (job.what !== "focus" && job.what !== "openfile") return;
                    if (code !== 0) win.toast(job.what === "openfile" ? "Could not open the transcript" : "Could not focus the window");
                    job.destroy();
                }
            }
            Component.onDestruction: { if (job.what === "windows") win.browserBusy = false; if (job.what === "transcript") win.transcriptBusy = false; }
            Timer { interval: 8000; running: true; onTriggered: proc.running = false }
        }
    }
    Component {
        id: turnC
        Item {
            id: tjob
            property int seq: 0
            property var command: []
            Process {
                id: tproc
                command: tjob.command
                running: true
                stdout: StdioCollector { onStreamFinished: { win.turnAnswered(tjob.seq, text); tjob.destroy(); } }
            }
            Timer { interval: 8000; running: true; onTriggered: tproc.running = false }
        }
    }
    // `transcript.py open SID` as a job, so a failed open (exit not 0) is told, not silent
    Component {
        id: openJobC
        Item {
            id: ojob
            property var command: []
            Process {
                id: oproc
                command: ojob.command
                running: true
                onExited: (code, status) => { if (code !== 0) win.toast("Could not open the transcript"); ojob.destroy(); }
            }
            Timer { interval: 8000; running: true; onTriggered: oproc.running = false }
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
        visible: win.listMode !== "" || win.ctxOpen
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
        visible: win.listMode !== "" && win.listMode !== "turn"
        title: win.listTitle
        rows: win.listRowsView
        message: win.listMode === "note" || win.listMode === "agent" ? win.listNote : ""
        interactive: win.listMode !== "history"
        actionOnly: win.listMode === "agent"
        elideMode: win.listMode === "paths" ? Text.ElideLeft : Text.ElideRight
        bg: theme.bg; ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent; edge: theme.discEdge
        readonly property point at: Qt.point(map.x + win.listAnchor.x, map.y + win.listAnchor.y)
        x: Math.max(8, Math.min(parent.width - width - 8, at.x - width / 2))
        y: Math.max(4, Math.min(parent.height - height - 4, win.listAnchor.y < map.height * 0.45 ? at.y + map.discR * 2.7 : at.y - map.discR * 1.7 - height))
        onPicked: index => win.picked(index)
    }

    TurnPanel {
        id: turnPanel
        z: 100
        visible: win.listMode === "turn"
        summary: win.turnView.summary
        note: win.turnView.note
        steps: win.turnView.steps
        maxHeight: parent.height - 16
        bg: theme.bg; ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent; edge: theme.discEdge
        x: (parent.width - width) / 2
        y: Math.max(8, (parent.height - height) / 2)
        onOpenRaw: win.openTranscript()
    }

    ContextPanel {
        id: ctxPanel
        objectName: "contextPanel"
        z: 100
        visible: win.ctxOpen
        info: win.ctxInfo
        reading: map.context ? map.context.tokens : 0
        windowSize: map.context ? map.context.size : 0
        bg: theme.bg; ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent; alert: theme.alert; edge: theme.discEdge
        x: Math.max(8, (parent.width - width) / 2)
        y: Math.max(4, Math.min(parent.height - height - 4, map.y + map.cy + map.hubR + 18))
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
