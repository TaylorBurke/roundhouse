import QtQuick
import Quickshell

// The map on top, then the current action and the feed.
ShellRoot {
    FloatingWindow {
        title: "roundhouse"
        implicitWidth: 360
        implicitHeight: 680
        visible: true
        color: "#0b0d12"

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
        }

        Feed {
            anchors { left: parent.left; right: parent.right; top: map.bottom; bottom: parent.bottom; margins: 12 }
            clip: true
            session: tail.active
            revision: tail.revision
        }
    }
}
