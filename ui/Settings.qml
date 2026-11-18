import QtQuick
import Quickshell
import Quickshell.Io
import "board.js" as Board

// Optional settings from $XDG_CONFIG_HOME/roundhouse/config.json (default ~/.config/roundhouse/):
//   { "contextWindow": 1000000 }     a number, "200k", "1m", or "auto" (the default)
//   { "slowCallSeconds": 120 }       a running call older than this is outlined amber; 0 or "off" disables
// A missing or broken file means all defaults. The file is watched, so edits apply at once.
Item {
    id: root
    property int contextWindow: 0          // 0: guess from the model name
    property real slowCallSeconds: 120
    readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/roundhouse/config.json"

    function apply(text) {
        var cfg = {};
        try { cfg = JSON.parse(text); } catch (e) { cfg = {}; }
        root.contextWindow = cfg && typeof cfg === "object" ? Board.parseWindow(cfg.contextWindow) : 0;
        root.slowCallSeconds = Board.parseSlow(cfg && typeof cfg === "object" ? cfg.slowCallSeconds : undefined);
    }

    FileView {
        path: root.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.apply(text())
        onLoadFailed: { root.contextWindow = 0; root.slowCallSeconds = Board.parseSlow(undefined); }
    }
}
