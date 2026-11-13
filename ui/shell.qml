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

        Feed {
            anchors { left: parent.left; right: parent.right; top: map.bottom; bottom: parent.bottom; margins: 12 }
            clip: true
            session: tail.active
            revision: tail.revision
            ink: theme.ink; inkStrong: theme.inkStrong; faint: theme.faint
            accent: theme.accent; alert: theme.alert
        }
    }
}
