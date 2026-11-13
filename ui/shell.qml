import QtQuick
import Quickshell

// The roundhouse service: one window for every entry of windows.json (see Windows.qml). The
// log, the theme and the settings are shared by all of them. (The ids differ from the windows'
// property names on purpose: `tail: tail` would point a property at itself.)
ShellRoot {
    Theme { id: sharedTheme }
    Settings { id: sharedSettings }
    LogTail { id: sharedTail }
    Windows { id: sharedWindows; tail: sharedTail }
    // read the strip's files only while a window for one session is shown
    StripState { id: sharedStrips; active: sharedWindows.entries.some(e => e.sid !== "*") }

    Variants {
        model: sharedWindows.ids
        RoundhouseWindow {
            required property string modelData
            winId: modelData
            tail: sharedTail
            theme: sharedTheme
            settings: sharedSettings
            windows: sharedWindows
            strips: sharedStrips
        }
    }
}
