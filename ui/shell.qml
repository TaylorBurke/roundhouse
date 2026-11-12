import QtQuick
import Quickshell

// Stage 3, step 3: the window now follows the log. This text view is a stand-in that shows
// the board is right; the map (#4) and pulses (#5) replace it.
ShellRoot {
    FloatingWindow {
        title: "roundhouse"
        implicitWidth: 360
        implicitHeight: 520
        visible: true
        color: "#1a1b26"

        LogTail { id: tail }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4
            readonly property var s: tail.active
            Text {
                color: "#c0caf5"; font.family: "monospace"; font.pixelSize: 13
                text: tail.revision >= 0 && parent.s ? parent.s.sid + "  " + parent.s.dir + "  " + parent.s.model + "\n"
                                + parent.s.tokens.toLocaleString() + " tokens" + (parent.s.ended ? "  (ended)" : "")
                              : "waiting for events\n" + tail.path
            }
            Repeater {
                model: parent.s ? Object.keys(parent.s.stations) : []
                Text {
                    required property string modelData
                    // Read through tail.revision: the board is mutated in place, so QML sees no change otherwise.
                    readonly property int running: tail.revision >= 0 ? tail.active.stations[modelData].running : 0
                    readonly property int blocked: tail.revision >= 0 ? tail.active.stations[modelData].blocked : 0
                    readonly property int errors: tail.revision >= 0 ? tail.active.stations[modelData].errors : 0
                    color: blocked ? "#f7768e" : running ? "#e0af68" : "#7aa2f7"
                    font.family: "monospace"; font.pixelSize: 12
                    text: modelData.padEnd(8) + " running " + running + "  blocked " + blocked + "  errors " + errors
                }
            }
            Repeater {
                model: tail.revision >= 0 && parent.s ? parent.s.entries.slice(-12).reverse() : []
                Text {
                    required property var modelData
                    color: modelData.status === "blocked" || modelData.status === "err" ? "#f7768e" : modelData.status === "running" ? "#e0af68" : "#565f89"
                    font.family: "monospace"; font.pixelSize: 11
                    width: parent.width; elide: Text.ElideRight
                    text: modelData.status.padEnd(8) + modelData.station.padEnd(8) + modelData.label
                }
            }
        }
    }
}
