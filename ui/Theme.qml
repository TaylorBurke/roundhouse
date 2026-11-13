import QtQuick
import Quickshell
import Quickshell.Io
import "theme.js" as Palette

// Follows the Omarchy theme: reads colors.toml and turns it into the palette. A theme switch
// replaces files and symlinks (even the folder), which can leave a file watcher looking at a
// deleted file, so the file is also re-read every two seconds; reading a small file is cheap.
// With no theme file the built-in dark palette is used. ROUNDHOUSE_THEME points at another
// colors.toml, to try a theme without switching the desktop.
Item {
    id: root
    readonly property string path: Quickshell.env("ROUNDHOUSE_THEME")
        || ((Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/theme/colors.toml")

    property var palette: Palette.derive({})
    readonly property bool light: palette.light
    readonly property color bg: palette.bg
    readonly property color disc: palette.disc
    readonly property color discEdge: palette.discEdge
    readonly property color line: palette.line
    readonly property color ring: palette.ring
    readonly property color ink: palette.ink
    readonly property color inkStrong: palette.inkStrong
    readonly property color faint: palette.faint
    readonly property color accent: palette.accent
    readonly property color alert: palette.alert
    readonly property color memory: palette.memory

    property bool loaded: false
    property string lastText: ""

    function apply(text) {
        if (loaded && text === lastText) return;        // nothing changed
        lastText = text;
        loaded = true;
        palette = Palette.derive(Palette.parseColors(text));
    }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onPathChanged: reload()
        onLoaded: root.apply(text())
        // Missing during a switch: keep what is showing. Never loaded at all: the fallback.
        onLoadFailed: if (!root.loaded) root.apply("")
    }
    Timer { interval: 2000; running: true; repeat: true; onTriggered: file.reload() }
}
