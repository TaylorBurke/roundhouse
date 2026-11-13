import QtQuick
import Quickshell

// The map on top, then the current action and the feed.
ShellRoot {
    FloatingWindow {
        title: "roundhouse"
        implicitWidth: 360
        implicitHeight: 680
        visible: true
        color: theme.bg

        Theme { id: theme }

        Settings { id: settings }

        LogTail {
            id: tail
            onLive: (ev, blocked) => map.handle(ev, blocked)
        }

        MapView {
            id: map
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: Math.min(parent.width, parent.height * 0.6)
            session: tail.active
            revision: tail.revision
            windowSetting: settings.contextWindow
            bg: theme.bg; disc: theme.disc; discEdge: theme.discEdge; line: theme.line; ring: theme.ring
            ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
            accent: theme.accent; alert: theme.alert; memory: theme.memory
        }

        // keyboard: [ ] or the arrow keys step through sessions, space shows the list (1-9 pick
        // from it), a follows the most recently active, escape closes the list
        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                var k = event.key, t = event.text;
                if (k === Qt.Key_Left || t === "[") tail.cycle(-1);
                else if (k === Qt.Key_Right || t === "]") tail.cycle(1);
                else if (t === "a") { switcher.open = false; tail.follow(); }
                else if (k === Qt.Key_Space) switcher.open = !switcher.open;
                else if (k === Qt.Key_Escape) switcher.open = false;
                else if (switcher.open && t >= "1" && t <= "9" && tail.sessionList[parseInt(t) - 1]) switcher.choose(tail.sessionList[parseInt(t) - 1].sid);
                else return;
                event.accepted = true;
            }
        }

        SessionSwitcher {
            id: switcher
            z: 10
            anchors { left: parent.left; right: parent.right; top: map.bottom; leftMargin: 12; rightMargin: 12; topMargin: 2 }
            sessions: tail.sessionList
            shown: tail.shownSid
            shownName: tail.active ? (tail.active.dir || tail.active.sid) : ""
            pinned: tail.isPinned
            ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint; accent: theme.accent
            disc: theme.disc; discEdge: theme.discEdge
            onPick: sid => tail.pick(sid)
            onFollow: tail.follow()
            onCycle: dir => tail.cycle(dir)
        }

        Feed {
            anchors { left: parent.left; right: parent.right; top: switcher.bottom; bottom: parent.bottom; margins: 12; topMargin: 6 }
            clip: true
            session: tail.active
            revision: tail.revision
            ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
            accent: theme.accent; alert: theme.alert
        }
    }
}
