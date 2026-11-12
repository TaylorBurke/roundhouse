import QtQuick
import Quickshell

// Map on top, a plain-text feed stand-in below (the real feed and the pulses are #5).
ShellRoot {
    FloatingWindow {
        title: "roundhouse"
        implicitWidth: 360
        implicitHeight: 520
        visible: true
        color: "#0b0d12"

        LogTail { id: tail }

        MapView {
            id: map
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: Math.min(parent.width * 1.0, parent.height * 0.72)
            session: tail.active
            revision: tail.revision
        }

        Column {
            anchors { left: parent.left; right: parent.right; top: map.bottom; bottom: parent.bottom; margins: 12 }
            clip: true
            spacing: 2
            Text {
                color: "#8d96ab"; font.family: "monospace"; font.pixelSize: 11
                text: tail.revision >= 0 && tail.active
                      ? tail.active.sid + "  " + tail.active.dir + "  " + tail.active.tokens.toLocaleString() + " tokens"
                      : "waiting for events"
            }
            Repeater {
                model: tail.revision >= 0 && tail.active ? tail.active.entries.slice(-7).reverse() : []
                Text {
                    required property var modelData
                    color: modelData.status === "blocked" || modelData.status === "err" ? "#f7768e"
                         : modelData.status === "running" ? "#e0af68" : "#565f89"
                    font.family: "monospace"; font.pixelSize: 11
                    width: parent.width; elide: Text.ElideRight
                    text: modelData.status.padEnd(8) + modelData.station.padEnd(8) + modelData.label
                }
            }
        }
    }
}
