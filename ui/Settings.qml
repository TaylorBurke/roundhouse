import QtQuick
import Quickshell
import Quickshell.Io
import "board.js" as Board

// Optional settings from $XDG_CONFIG_HOME/roundhouse/config.json (default ~/.config/roundhouse/):
//   { "contextWindow": 1000000 }     a number, "200k", "1m", or "auto" (the default)
//   { "slowCallSeconds": 120 }       a running call older than this is outlined amber; 0 or "off" disables
//   { "drafts": false }              no draft prompts on a click at You (default true)
//   { "draftPrompts": ["continue"] } replaces the built-in canned drafts
// A missing or broken file means all defaults. The file is watched, so edits apply at once.
Item {
    id: root
    property int contextWindow: 0          // 0: guess from the model name
    property real slowCallSeconds: 120
    property bool drafts: true
    property var draftPrompts: null        // null: the built-in list
    property bool loaded: false            // a read has succeeded at least once
    readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/roundhouse/config.json"

    function apply(text) {
        var cfg = {};
        try { cfg = JSON.parse(text); } catch (e) { cfg = {}; }
        root.contextWindow = cfg && typeof cfg === "object" ? Board.parseWindow(cfg.contextWindow) : 0;
        root.slowCallSeconds = Board.parseSlow(cfg && typeof cfg === "object" ? cfg.slowCallSeconds : undefined);
        var d = Board.parseDrafts(cfg);
        root.drafts = d.enabled;
        root.draftPrompts = d.prompts;
    }

    FileView {
        path: root.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root.loaded = true; root.apply(text()); }
        // A failed RELOAD (an atomic-replace save) keeps what was read before; defaults apply only
        // when there never was a successful read.
        onLoadFailed: if (!root.loaded) root.apply("")
    }
}
