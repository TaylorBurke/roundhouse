import QtQuick
import Quickshell
import "board.js" as Board
import "follow.js" as Follow

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
        if (d.move)
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

    Feed {
        anchors { left: parent.left; right: parent.right; top: bar.bottom; bottom: parent.bottom; margins: 12; topMargin: 6 }
        clip: true
        session: win.session
        revision: win.tail.revision
        ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
        accent: theme.accent; alert: theme.alert
    }
}
