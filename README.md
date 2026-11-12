# roundhouse

A live map of what Claude Code is doing, in a floating window on a Linux desktop
(built for Omarchy / Hyprland). A hub in the middle, stations around it (You, Model,
Memory, Files, Shell, Network, Browser, Agents, Skills, Hooks), and a pulse along a
spoke for every tool call.

Inspired by [lot-map](https://github.com/alexeyw/lot-map) by alexeyw (MIT), a Claude
Code plugin that draws this map in the desktop app. In a terminal session that plugin
shows only its text feed; this project gets the picture on screen anyway, fed by
ordinary Claude Code hooks. The code here is written fresh.

**Status: stage 3 of 5, in progress.** The hook emitter and a terminal log viewer work, and
`bin/roundhouse` opens a floating window that follows the log and lists per-station
the resting map (hub, ten stations, spokes, icons, per-station counts) and the recent calls as plain text (no pulses yet), and nothing is installed into your Claude Code settings.

| Stage | What | State |
| --- | --- | --- |
| 1 | Research and design ([docs/DESIGN.md](docs/DESIGN.md)) | done |
| 2 | Hook emitter and terminal log viewer | done |
| 3 | Window with the static map and live pulses | window (#1), board state (#3) and static map (#4) done; pulses and feed (#5) next |
| 4 | Context ring, route line, error dots, background tasks, subagents, theme | |
| 5 | Install and uninstall scripts | |

## How it works

```
Claude Code hook  ->  hooks/emit.py  ->  $XDG_RUNTIME_DIR/lot-map/events.jsonl  ->  viewer / window
```

`hooks/emit.py` runs on each hook event, turns it into one small JSON line and appends
it to the log. The log lives on tmpfs, is readable only by you, and is cut back to its
newest 500 lines when it passes 1 MB.

## What is recorded

Names only, never content:

- a file: the last two parts of its path
- a web address: the host alone
- a shell command: the short description Claude gave it, or the command's name; never
  the command line
- a subagent: its short description
- a background task: its id, type and status
- the context window: a token count and the model name, read from the session
  transcript's usage numbers

Prompts, command lines, file contents, tool output and memory text are never written.
Control characters are stripped from every label. The emitter makes no network calls,
starts no processes, prints nothing and always exits 0, and the hooks are registered as
`async`, so they cannot hold up or alter a tool call.

## Try it without installing

Nothing here touches `~/.claude/settings.json`. To see events flow, give one session a
settings file of its own:

```bash
# 1. a settings file that points every event at the emitter
python3 - > /tmp/roundhouse-hooks.json <<'EOF'
import json
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PostToolBatch", "PermissionRequest", "PermissionDenied", "SubagentStart", "SubagentStop",
          "Stop", "StopFailure", "PreCompact", "PostCompact", "PostModelSwitch", "Notification", "SessionEnd"]
hook = {"type": "command", "command": "/home/YOU/Work/lot-map-linux/hooks/emit.py", "async": True}
print(json.dumps({"hooks": {e: [{"hooks": [hook]}] for e in events}}, indent=1))
EOF

# 2. in one terminal, follow the log
bin/lot-map-log

# 3. in another, start a session with those hooks
claude --settings /tmp/roundhouse-hooks.json
```

To undo: close that session and delete `/tmp/roundhouse-hooks.json`. The log disappears
at logout, or remove it with `rm -r "$XDG_RUNTIME_DIR/lot-map"`.

## The window

```bash
bin/roundhouse    # opens the window; closing it ends the process
```

Quickshell windows all report the app id `org.quickshell`, so the Hyprland rule matches on
the title `roundhouse` as well. To float, size (360x520) and pin it, add this line to
`~/.config/hypr/hyprland.lua` (remove it to undo):

```lua
dofile(os.getenv("HOME") .. "/Work/roundhouse/hypr/roundhouse.lua")
```

To try the rule for one session without editing anything:
`hyprctl eval 'dofile(os.getenv("HOME") .. "/Work/roundhouse/hypr/roundhouse.lua")'`.
Requires `quickshell`.

The window tails the log with `tail -F` and folds each line into a board per session
(`ui/board.js`): calls are paired by id, a call still open at the next `batch` or `stop`
is marked blocked (background calls are not), the newest 80 entries are kept, and the most
recently active session is shown. It copes with a log that does not exist yet and with the
emitter cutting the log back (the replayed lines are recognised and skipped).

![the resting map](docs/map-resting.png)

The map (`ui/MapView.qml`, icons in `ui/icons.js`) is drawn on a Canvas from the window's size,
so it scales: ten stations on an ellipse with You at the top and the rest clockwise, a spoke
to each, dashed contour rings, an icon and label per station with the number of recent calls
under it, and the model name in the hub. Colours are properties on `MapView`, ready for the
theme work. Icons are original line drawings.

## The log viewer

```
bin/lot-map-log              follow, starting with the last 20 events
bin/lot-map-log -n 0         only new events
bin/lot-map-log --no-follow  print what is there and exit
bin/lot-map-log --raw        the JSON lines as they are
bin/lot-map-log -s 7c8862de  one session only
```

```
23:32:53.486 7c8862de ● Files    e2e/sample.txt
23:32:53.659 7c8862de · Files    e2e/sample.txt  6 ms
23:32:53.755 7c8862de ◌ Model    context 42,129 tokens · claude-haiku-5-5
23:32:57.984 7c8862de ✕ Shell    Run false command (expected to exit non-zero)  9 ms
23:32:59.390 7c8862de ? Hooks    asked permission: Bash
23:33:01.751 7c8862de ◂ You      answer ready
```

## Requirements

Python 3 (standard library only); `quickshell` for the window; `qml6` (qt6-declarative) to run the board tests. Claude Code 2.1.295 or later is recommended.

## Tests

```bash
python3 -m unittest discover -s tests   # includes tests/board.test.qml, run under qml6
```

## License

[MIT](LICENSE)
