# roundhouse

A live map of what Claude Code is doing, in a floating window on a Linux desktop
(built for Omarchy / Hyprland). A hub in the middle, stations around it (You, Model,
Memory, Files, Shell, Network, Browser, Agents, Skills, Hooks), and a pulse along a
spoke for every tool call.

Inspired by [lot-map](https://github.com/alexeyw/lot-map) by alexeyw (MIT), a Claude
Code plugin that draws this map in the desktop app. In a terminal session that plugin
shows only its text feed; this project gets the picture on screen anyway, fed by
ordinary Claude Code hooks. The code here is written fresh.

![the map pulsing as a recorded Claude Code session is replayed into it](docs/pulses.gif)

**Quick start:** `./install.sh --dry-run` shows what installing would change (nothing is changed),
`./install.sh` does it after asking, then `roundhouse` opens the window. Details under
[Install](#install); everything it touches is listed there, and so is how to remove it.

**Status: complete.** All five stages are built and tested; see the table.

| Stage | What | State |
| --- | --- | --- |
| 1 | Research and design ([docs/DESIGN.md](docs/DESIGN.md)) | done |
| 2 | Hook emitter and terminal log viewer | done |
| 3 | Window with the static map and live pulses | done |
| 4 | Context ring, route line, error dots, background tasks, subagents, theme, session switcher | done |
| 5 | Per-session windows, the claude-strip link, install and uninstall | done |

## How it works

```
Claude Code hook  ->  hooks/emit.py  ->  $XDG_RUNTIME_DIR/lot-map/events.jsonl  ->  viewer / window
```

`hooks/emit.py` runs on each hook event, turns it into one small JSON line and appends
it to the log. The log lives on tmpfs, is readable only by you, and is cut back to its
newest 500 lines when it passes 1 MB.

## Privacy: what is recorded

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
`async`, so they cannot hold up or alter a tool call. Nothing in roundhouse uses the network.
The log is on tmpfs, readable only by you, and gone at logout. The waiting, heat and slow-call cues
are worked out on screen from the same names and timestamps; they add nothing to the log.

Draft prompts (click You) are the one place roundhouse sends keystrokes: only the chosen draft's
text, to the session's own terminal, only while that window is the active one, and never Enter. A
draft holds at most a cleaned, shortened call name from the log; it is not written anywhere.

One exception to "names only", and only on screen: if you use claude-strip, a session's window
shows the strip's task title (a summary of your prompts; see "The session header"). It is read
from the strip's own file, shown, and never written to roundhouse's log.

A second one, also only on screen: clicking **Model** opens a turn panel. It reads the session's
transcript (`~/.claude/projects/...jsonl`) at the click and shows each step's think time, tokens, tools
and, when the transcript has one, the model's reasoning summary (cut to 400 characters; the last 8 steps).
That text lives only in the panel until you close it: it is never written to roundhouse's log, never put
in a command line, and the transcript is only read, never changed. The "Open the raw transcript" button
hands the file to your default editor, which then has the whole transcript.

## Install

```bash
git clone https://github.com/TaylorBurke/roundhouse     # anywhere you like; the commands below run from the clone
cd roundhouse
./install.sh --dry-run     # shows everything it would do, changes nothing
./install.sh               # shows each change and asks before making it
```

Requires Python 3 and, for the window, Quickshell on Hyprland (Omarchy). **What it changes, and
nothing else:**

1. **`~/.claude/settings.json`**: adds one hook for each of the 17 events it listens to (the
   list is in `tools/setup.py`), every one the command `<this folder>/hooks/emit.py` with
   `"async": true`. It backs the file up first (`settings.json.roundhouse-backup-<time>`), prints
   the exact diff and asks. Hooks you already have are left alone; running it again adds nothing.
   (`$CLAUDE_CONFIG_DIR` is honoured.) Open Claude Code sessions need a restart to pick the hooks up.
2. **`~/.local/bin/roundhouse`**: a symlink to `bin/roundhouse`, so the command is on your PATH.
   An existing file of that name that is not ours is never replaced.
3. **`~/.config/hypr/hyprland.lua`** (asks, default no): appends the one line
   `dofile("<this folder>/hypr/roundhouse.lua")  -- roundhouse`, which floats and sizes the windows.
   Without it Hyprland tiles them (the window asks for 360x680 but nothing makes it float), so say yes
   unless you float them some other way.
   It backs the file up, reloads Hyprland and checks `hyprctl configerrors`, and puts the backup
   back if there is any error. You can add that line yourself instead.

At run time the hooks write a small log under `$XDG_RUNTIME_DIR/lot-map` (tmpfs, owner-only, gone at
logout), and the window settings you choose go in `~/.config/roundhouse/config.json`.

## Uninstall

```bash
cd roundhouse              # your clone
./uninstall.sh --dry-run   # shows what it would do
./uninstall.sh             # shows each change and asks first
```

It reverses exactly the three steps above, each with a diff and a backup: removes only the hook
entries whose command is this folder's `hooks/emit.py` (your other hooks stay), removes the
`~/.local/bin/roundhouse` link if it points here, and removes the `dofile` line from
`hyprland.lua`. It also closes the window service and deletes `$XDG_RUNTIME_DIR/lot-map`. It
keeps `~/.config/roundhouse/config.json`, the backups, and this folder, which you can delete.

**By hand**, if the folder is already gone:

```bash
# 1. the hooks: drop every hook whose command ends in /hooks/emit.py (edit the path if yours differs)
cp ~/.claude/settings.json ~/.claude/settings.json.before-roundhouse-removal
jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | endswith("/roundhouse/hooks/emit.py") | not))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0)))' \
  ~/.claude/settings.json.before-roundhouse-removal > ~/.claude/settings.json
# 2. the command
rm ~/.local/bin/roundhouse
# 3. the window rules: delete the line that ends with  -- roundhouse  from ~/.config/hypr/hyprland.lua
# 4. the log and the windows: close any roundhouse window, then
rm -r "$XDG_RUNTIME_DIR/lot-map"
```

## Try it without installing

Nothing here touches `~/.claude/settings.json`. To see events flow, give one session a
settings file of its own (run from this folder):

```bash
# 1. a settings file that points every event at the emitter
python3 - > /tmp/roundhouse-hooks.json <<'EOF'
import json, os
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PostToolBatch", "PermissionRequest", "PermissionDenied", "SubagentStart", "SubagentStop",
          "Stop", "StopFailure", "PreCompact", "PostCompact", "PostModelSwitch", "Notification", "SessionEnd"]
hook = {"type": "command", "command": os.path.abspath("hooks/emit.py"), "async": True}
print(json.dumps({"hooks": {e: [{"hooks": [hook]}] for e in events}}, indent=1))
EOF

# 2. in one terminal, follow the log
bin/lot-map-log

# 3. in another, start a session with those hooks
claude --settings /tmp/roundhouse-hooks.json
```

To undo: close that session and delete `/tmp/roundhouse-hooks.json`. The log disappears
at logout, or remove it with `rm -r "$XDG_RUNTIME_DIR/lot-map"`.

## Reading the map

Ten stations, You at the top and the rest clockwise. A call lights the station its tool belongs to:

| Station | Lights up for |
| --- | --- |
| You | your prompts, questions to you, notifications, a finished answer |
| Model | the steps between tool batches, a compaction, a model change |
| Memory | the memory folder, the `memory` MCP server |
| Files | Read, Write, Edit, Grep, Glob, shell lines made only of file commands |
| Shell | every other shell command, Monitor |
| Network | web fetches and searches, MCP servers, `curl`, `gh`, `git push`, `npm install` and the like |
| Browser | the browser MCP servers (Chrome, DevTools, Playwright, Puppeteer) |
| Agents | subagents and teammates |
| Skills | skills and loading tools |
| Hooks | permission prompts, denials, and calls that were refused |

What moves and what it means:

- **A dot along a spoke**: a call starting (out from the hub) or finishing (back; red if it failed).
  Calls that start together fly in side-by-side lanes.
- **A ripple at a station**, and a **steady glow with two clock hands** while something runs there
  (the long hand makes a lap a minute, the short one a lap in ten). `x3` means three at once.
- **The ring round the hub**: how full the context is; grey, amber from 70%, red from 90%; dashed
  with `-%` when the number is unknown (right after a compaction).
- **A red dot with a count**: errors and refusals since your last prompt. Hooks counts refusals.
- **Hover a node** (or the hub) for a tooltip: what the station stands for, its counts, and, when it
  wears a red dot, which calls are behind it, marked failed or refused (a refused call counts at its own
  station and at Hooks). It also lists running calls with how long they have run (longest first, e.g.
  `npm test · 1m12s`), the last call and the average duration there, and a few facts per station: Model
  (name, steps this turn, compactions), Network (top hosts), Agents (running types), You ("waiting on you
  since 12:03"). The hub shows the raw token count, the window size and whether it comes from your
  setting or is a guess, and how old the reading is. Call names show on screen only; nothing is written.
  ![Shell tooltip](docs/tooltip-shell.png) ![Hub tooltip](docs/tooltip-hub.png)
- **Click Shell** (a hand cursor once the session has started a background task) lists its background
  tasks: running ones first, then finished ones, each with its status and elapsed time (`ok · 5m`). Picking
  one opens its output file in your editor: Claude Code writes it to
  `/tmp/claude-<uid>/<project>/<session id>/tasks/<task id>.output`, found from the task id and the session id
  by folder names only. If the file is gone, a short toast says so. The same file checks apply (an existing
  regular file in your home folder or Claude's scratch folder; a link that leads elsewhere is refused).
- **Click Files, Memory, Skills, Network, Browser, Hooks or Agents** (the station has a faint backlight, and the pointer turns into a hand,
  when there is something to open). **Files** and **Skills** open the file behind a name in your editor
  (`omarchy launch editor`; pictures, video, audio and PDFs go to your default viewer): one name opens
  at once, several are listed to pick from, and a name that matches several files lists those. If the file
  is refused or the editor cannot start, a toast says "Could not open <name>" (the same for hook files and
  hosts). The log
  keeps no full paths, so the name is looked up on disk at the click: under the session's folder (known
  when claude-strip runs), then Claude's scratch folder, then anywhere under your home folder (not
  Claude's own plugin and transcript folders); skills are looked up in `~/.claude/skills` and the plugin
  folders. **Memory** is always clickable: it lists this project's own memory files, whether or not the
  session has touched any, since memory is loaded at the start without a tool call. The ones this
  session read or edited with the file tools come first, tagged `read` or `edited`; then `MEMORY.md`
  and the rest, newest first. A file read from the shell (`cat`) or recalled automatically gets no tag
  (the log knows no file name for those), and only the log's last 80 entries are looked at. A tag goes
  by the last two parts of the path, so reading another project's `memory/MEMORY.md` tags this one's
  too. Only names are read, and only an existing file in your home folder or
  Claude's scratch folder is ever handed to the editor or viewer (a symlink in a project that points
  outside is refused; skills and plugin folders may link elsewhere, as they usually do); nothing is
  executed. **Network** lists the distinct hosts (from web fetches) and MCP servers behind its entries,
  with counts, newest first. Picking a host opens `https://<host>` in your default browser (host only,
  never a path); picking an MCP server does nothing. The host passes a strict hostname check (letters,
  digits, dots and hyphens; no spaces, scheme, port, login or leading `-`; non-ASCII names are not offered,
  and nothing converts them to punycode; a name of 40 characters or more is skipped as possibly cut
  short) in the window and again in `tools/openhost.py`, which hands it to `xdg-open` as one
  argument, never through a shell. 
  **Hooks** is always clickable too: it lists the hooks you have configured (not which one
  fired; the log does not say), read at the click from the `hooks` section of `settings.json` and
  `settings.local.json` (in `$CLAUDE_CONFIG_DIR`, else `~/.claude`) and from the `hooks.json` of each
  installed and enabled plugin (only the installed version: `plugins/installed_plugins.json` and
  `enabledPlugins` are read for that; if the registry is missing or unreadable, the newest version folder of
  each plugin in `plugins/cache` is used instead). The same hook found twice is listed once. Project-level
  `.claude/settings*.json` files are not read (the log does not know the project folder reliably). Hooks are
  grouped by event, with roundhouse's own entries folded into one "roundhouse (17 events)" row. A row shows
  only the script's name (or "prompt hook", "agent hook", "http hook") and its matcher, never the command
  line or its arguments (they can hold secrets). A click opens the script: the first word of the command
  that is an existing text file in your home folder, skipping interpreters such as `python`, `uv`, `node` or
  `sh`; when there is none (or the hook is not a command), it opens the file that defines the hook. If the
  hooks cannot be read, a toast says "Could not read hooks"; an empty list says "No hooks configured".
  Nothing is edited.
  **Browser** (clickable once the session has used a browser tool) focuses a browser window on your
  desktop (`tools/browserwin.py`, which asks the same Hyprland as the header's terminal focus): one window is
  focused at once, several are listed by page title (with workspace and class beside it) to pick from, and
  none gives a short note (a failed lookup or focus says so instead). Only exact browser classes count;
  Chrome app and PWA windows do not. **If the session drove only the chrome-devtools MCP**, its Chrome runs
  in Backstage (the agents' separate desktop), which a click here cannot list or focus: the click says so
  ("The agent's browser is in Backstage; run `backstage view` to see it") and touches nothing. A session
  that used the Claude-in-Chrome extension (with or without devtools), Playwright or the like gets your
  everyday browser windows. Window level only: **tab selection is not possible**, because Chrome has no
  external API to activate a tab (see #60). A window's title is the active tab's page title; it shows on
  screen only and is never stored.
  **Agents** (backlit once the session has had a subagent) lists the
  session's subagents, running ones first and then the finished ones, which stay listed for the rest of the
  session (the 12 most recent): the type, its status and how long it ran (so far, while it runs). Picking one
  shows its calls (newest first, up to eight, from the log: name, status, time) and an "Open transcript" row:
  the transcript is looked up at that click by `tools/transcript.py path` (the session's 8-character id and the
  agent id, both checked) and handed to your editor only if it is a `.jsonl` file below `~/.claude/projects`.
  If it cannot be found, or the editor cannot be started, you get a short note. Names only are read; nothing is written.
  Known limits: the open agent view is a snapshot (it does not refresh while it is showing), and an
  agent whose end event was lost stays shown as running.
  **Model** opens a small read-only panel for the current turn, read
  from the transcript at the click (`tools/transcript.py turn`): per step the think time, tokens in and
  out, the tools called and the reasoning summary (or "redacted"), the last 8 steps. A one-line note says
  when the numbers may be incomplete (a huge transcript read from its tail, output capped, or an id that
  matches several sessions). "Open the raw transcript" hands that one `.jsonl` (found by the tool, a regular
  file inside `~/.claude/projects`) to the editor. No transcript: a toast.
  Left click, station by station: You focuses the terminal and offers drafts; Model opens the turn panel;
  Shell lists background tasks; Network lists hosts and MCP servers; Browser focuses a browser window;
  Agents lists the subagents; Memory, Files and Skills open the file; Hooks lists the configured hooks;
  the hub opens the context panel. Right-click on any station shows its recent calls.
- **Click the hub** (a hand cursor shows when the session has a context reading or any logged call) for
  the context panel: a small line of the tokens in the context at each model call over the whole session
  (thinned to about 60 points, in the theme's colours), the current reading against the window, the peak,
  and the compaction history, newest first (time, `auto` or `manual`, tokens before -> after; `?` when
  the transcript did not say). It reads the session's transcript at the click (`tools/transcript.py
  context`, read-only, numbers only: no text from the transcript is shown or kept). A very large
  transcript is read from its end, and a very long one has its oldest points dropped; the panel says so
  in one line, as it does when several sessions share the 8-character id (the newest is shown). No
  transcript found: a short note instead. A click anywhere else, or Esc, closes it.
- **Click You** to jump to the session's terminal (a session window needs claude-strip to know it) and,
  when the session looks idle (no call running, no permission question open), a short list of drafts:
  one from what just happened ("Why did the Bash call fail?" for a call that failed since your last
  prompt, "What are you waiting on?" after a refused one, else "continue"), then canned ones from
  `config.json`. A draft never contains text from the log except a tool's name, and only if it is
  letters, digits, `_` or `-` (else "that call"). Picking one **types the text into the terminal and
  never presses Enter or any other key**; you review and submit it yourself. It is typed by
  `tools/draft.py`, which focuses the terminal, checks with `hyprctl activewindow` (twice, the last
  time just before typing) that its address is the active window (nothing is typed otherwise),
  accepts only a window address and 1-300 characters with no control, format (bidi, zero-width),
  private-use or line-break characters, and runs `wtype -- TEXT` with no shell. Needs `wtype` (a toast
  says so if it is missing). The idle check is repeated at the pick; a busy session just gets its
  terminal focused. Known limits: idleness is inferred from tool events only, so a long streaming
  reply with no tool calls looks idle, so an unlogged dialog, or vim in normal mode, in the terminal can
  receive the text; a half-typed prompt already in the terminal is appended to, not replaced; and a
  small time gap remains between `draft.py`'s last window check and `wtype` (the text, at most 300
  characters and never Enter, goes to whichever window is focused then). The window's own draft filter
  lists only the common invisible characters; `draft.py` is the authority and may refuse a draft the
  list showed. After a successful load of `config.json`, a deleted or broken file keeps the last good
  values until the shell restarts (so an atomic-replace save cannot reset them).
- **Right-click any station** for its recent calls: up to ten, newest first, each with its name,
  status (`ok`, `err`, `blocked`, `running`), how long it took and how long ago it started, and the
  subagent's type (`agent` if unknown) for a call a subagent made. It covers the last 80 events of the session, so older calls are gone. A station
  with no calls yet shows a short note at the bottom of the window instead. The list is a snapshot from
  the moment of the click; click anywhere else to close it. Names come from the log and show on screen
  only; nothing is written.
- **A thin curve** joining the last seven stations visited (a leg holds 40 s, then fades), and
  **spokes that thicken** with use.
- **A dot circling Agents** per running subagent. A background task keeps its station lit after its
  own turn is over.
- **A wide ring from the hub**: an answer finished. **Rings at the hub and Model**: a model change.
- **You pulsing** with a tinted disc in the accent colour: a permission ask or question is open and Claude
  is waiting for you. It stops at your next message, the answer, the call going ahead, or a denial.
  See [Waiting, pressing, heat and slow calls](#waiting-pressing-heat-and-slow-calls).
- **A faint ring round a station**, thicker and stronger with its share of the session's calls (usage heat).
- **An amber outline** on a station whose own running call has passed two minutes (see Options).
- **A small ripple** where you press a station, whether or not it opens anything.
- **The feed** under the map: `●` running, `·` done, `✕` failed or blocked; finished rows at one
  station fold into one with `+N`.

## Options

| What | How | Default |
| --- | --- | --- |
| Context window size | `~/.config/roundhouse/config.json`: `{"contextWindow": "1m"}` (a number, `"200k"`, `"1m"` or `"auto"`); watched, no restart | guessed from the model name, else 200k |
| Slow-call threshold | `~/.config/roundhouse/config.json`: `{"slowCallSeconds": 120}` (seconds; `0` or `"off"` disables); watched | 120 (2 minutes) |
| Draft prompts on a click at You | `config.json`: `{"drafts": false}` turns them off (You then only focuses the terminal); `{"draftPrompts": ["continue", "Run the tests"]}` replaces the canned list (each 1-300 characters, no line breaks; `[]`, or a list with no valid entry, leaves only the context draft); watched | on, two canned drafts |
| Colours | follows the Omarchy theme; `ROUNDHOUSE_THEME=/path/to/colors.toml` tries another | the current theme |
| Window size, always on top | edit `hypr/roundhouse.lua` (`size`, `pin`) | 360x680; the all-sessions window pinned, session windows not |
| Keys in the all-sessions window | `[` `]` or arrows step, space lists, `1`-`9` pick, `a` auto, `w` pop out, escape | |
| Where the log lives | `LOT_MAP_DIR` (read by both the emitter and the window) | `$XDG_RUNTIME_DIR/lot-map` |

Not configurable, on purpose: the hub's name and the layout (ten fixed stations).

## The window

```bash
roundhouse                       # the all-sessions window (same as: roundhouse show)
roundhouse toggle ab12cd34       # a window for one session, shown or hidden
roundhouse show|hide [SID]
roundhouse rebind OLD NEW        # a window moves to the session that replaces its own (after /clear)
roundhouse list                  # the sessions in the log, and which have a window
```

(`bin/roundhouse`; put it on your PATH if you like.) The windows that are shown are listed in
`$XDG_RUNTIME_DIR/lot-map/windows.json`. One background process runs them all: the command
starts it when something is to be shown, and it ends by itself when nothing is.

![an all-sessions window and two windows fixed to their sessions](docs/session-windows.png)

- **The all-sessions window** has the switcher and follows whichever session is most recently
  active (see "Several sessions"). It floats on every workspace. In it, `w` opens the session
  on show in a window of its own. Drag the switcher bar (the session's name or the gaps, not the
  `‹ ›` and `auto` buttons) to move it; a plain click on the name still opens the list.
- **A window for one session** is fixed to it (no switcher), is titled `roundhouse: <folder> · <id>`,
  and is **not** pinned: it opens on the workspace you are on and stays there, so switching
  workspace hides it. It **follows its terminal**: when the terminal is moved to another workspace,
  the window goes along (quietly, within a couple of seconds, without taking the focus); one you
  placed by hand stays put until the terminal moves. It closes itself when its session ends. A `/clear` is not an end: the
  session id changes, and `roundhouse rebind OLD NEW` moves the window to the new one, in
  place. Closing a window with the window manager takes it out of the set.
- The session id is the first 8 characters of Claude Code's, as `roundhouse list` shows.

Quickshell windows all report the app id `org.quickshell`, so the Hyprland rules match on the
title. To float and size them (and pin the all-sessions one), let `./install.sh` add this line to
`~/.config/hypr/hyprland.lua` when it asks (or add it yourself; remove it to undo):

```lua
dofile("/path/to/roundhouse/hypr/roundhouse.lua")   -- the absolute path of your clone; the installer writes it for you
```

To try the rules for one session without editing anything:
`hyprctl eval 'dofile("/path/to/roundhouse/hypr/roundhouse.lua")'` (your clone's path).
Requires `quickshell`.

The windows tail the log with `tail -F` (one tail, shared) and fold each line into a board per
session (`ui/board.js`): calls are paired by id, a call still open at the next `batch` or `stop`
is marked blocked (background calls too), the newest 80 entries are kept, and each window
shows its session. It copes with a log that does not exist yet and with the emitter cutting
the log back (the replayed lines are recognised and skipped).

![the resting map](docs/map-resting.png)

The map (`ui/MapView.qml`, icons in `ui/icons.js`) is drawn on a Canvas from the window's size,
so it scales: ten stations on an ellipse with You at the top and the rest clockwise, a spoke
to each, dashed contour rings, an icon and label per station with the number of recent calls
under it, and the model name in the hub. Colours come from the Omarchy theme (see "Theme"). Icons
are original line drawings.

### The session header

![two session windows with the strip's text on top: one working, one waiting (above), then the second working with a nearly full context (below)](docs/session-header.png)

A window for one session starts with the same text as that session's
[claude-strip](https://github.com/TaylorBurke/claude-strip): a dot for the phase, the task
title, then `waiting for you` or the number of tools running, and the context bar with its
percentage. So a terminal and its map are easy to pair up. Clicking the header focuses the
terminal; dragging it moves the window. The window title uses the strip's project name.

It needs claude-strip 0.4 or later, whose session-strip mod writes the session id into its
state file (`tools/strip_state.py` reads those files, read-only, every two seconds while such a
window is shown). Without it the header just names the folder and the model, and everything
else works the same.

**One thing to know:** the task title is a summary of your prompts. It is shown in the window
and nowhere else: roundhouse never writes it to its log, and the hook emitter is unchanged.

### Opening a session's window from its strip

![a claude-strip with its lit map icon, and the window it opened beside it](docs/strip-icon.png)

With [claude-strip](https://github.com/TaylorBurke/claude-strip) 0.4, each strip gets a small
icon at its far right (shown when the `roundhouse` command is on your PATH). Click it to open or
close that session's window; it is lit while the window is open. After a `/clear` the strip
notices the new session id and runs `roundhouse rebind`, so the window carries on in the same
place. Everything the icon does is the command line above, so it works the same by hand.

The strip's side is merged on claude-strip's `main` branch (v0.4.0). Its Omarchy marketplace
update is still to come, so until then use a clone of that repository for the strip.

### Context ring and the model

![the ring at 40%, 75%, 95% and over 200k](docs/context-ring.png)

The ring around the hub is how full the context window is: grey, amber from 70%, red from
90%, with the percentage and the assumed window ("75% of 200k") in the hub and the model's
short name under "CLAUDE". The transcript does not say whether you run the 200k or the 1M
window, so it is a guess from the model name (a `1m` in it means 1M) and grows to 1M if more
than 200k tokens turn up. To set it, create `~/.config/roundhouse/config.json`
(`$XDG_CONFIG_HOME` is honoured; the file is watched, so no restart):

```json
{ "contextWindow": "1m" }
```

A number (`1000000`), `"200k"`, `"1m"` or `"auto"` all work; a missing or broken file means auto.

![a model switch: rings at the hub and Model, new name in the hub](docs/context-model-switch.png)

A model change rings the hub and the Model station for a few seconds. A compaction lights
Model and labels it "compacting"; afterwards the ring is dashed with "\u2013%" until the next
real reading, because the transcript still holds the old numbers right after a compaction.

![compacting, then an unknown reading, then a fresh one](docs/context-compacting.png)

### Route line and worn spokes

![the route line in a replayed real session](docs/route-live.png)

A thin curve joins the last seven stations the main loop visited (subagent calls and repeats at
the same station are left out). The newest leg draws itself; a leg holds at full strength for 40
seconds, then fades over 20. Spokes grow thicker and brighter with use, on a log scale: one
call is a hint, around sixty is full.

![legs at 2 s, 45 s, 55 s and 62 s; Files, Shell and Network spokes worn by use](docs/route-fade.png)

### Waiting, pressing, heat and slow calls

Four small cues, all drawn behind the stations so nothing moves. Each is shown here on a dark
theme and on Catppuccin Latte (`ROUNDHOUSE_THEME=/usr/share/omarchy/themes/catppuccin-latte/colors.toml`).

**Waiting on you.** While a permission ask or a question is open (a `PermissionRequest`, or a
`permission_prompt` / `elicitation_dialog` notification), You pulses in the accent colour. The usual
`idle_prompt` notice (Claude finished and waits for your next message) does not count. It clears on your
next prompt, the answer finishing, the call going ahead, a denial, or the session ending.

| dark | light |
| --- | --- |
| ![You pulsing](docs/visual-waiting-dark.png) | ![You pulsing, light theme](docs/visual-waiting-light.png) |

**Slow call.** A station whose own running call is older than the threshold gets an amber outline
(Shell here, running `sleep 600` for four minutes). Background tasks are left out, since they are meant
to run long. The threshold is `slowCallSeconds` in `~/.config/roundhouse/config.json`, default 120.

| dark | light |
| --- | --- |
| ![amber outline on Shell](docs/visual-slow-dark.png) | ![amber outline on Shell, light theme](docs/visual-slow-light.png) |

**Usage heat.** A faint ring per station, thicker and brighter with its share of the session's calls
(Files holds 14 of 26 here). Unlike the spokes, which wear on a log scale, this is the plain share.

| dark | light |
| --- | --- |
| ![heat rings, Files strongest](docs/visual-heat-dark.png) | ![heat rings, light theme](docs/visual-heat-light.png) |

**Press feedback.** Pressing any station, whether or not it opens anything, sends a brief ripple out from it.
The ripple lasts well under half a second; these screenshots slow it to three seconds to catch it
(on Files).

| dark | light |
| --- | --- |
| ![press ripple on Files](docs/visual-press-dark.png) | ![press ripple on Files, light theme](docs/visual-press-light.png) |

### Error dots, clock hands and parallel calls

![red dots with counts, clock hands on Shell, x3 on Files](docs/dots-hands.png)

- A failed call puts a red dot with a count on its station. A refused call (a hook said no, or
  you did not grant it) marks its station and also Hooks, which is where `ask`, `denied` and
  refusals the log only implies are accounted for. A refusal later found to be a slow call
  taking its dot back, and the next prompt clears them all.
- While a call runs, two hands circle its station: the long one makes a lap a minute, the short
  one a lap in ten, counted from the oldest running call there.
- Calls that start together fly in side-by-side lanes, and the station shows `x3` while that
  many run at once.

![three parallel calls leaving the hub together](docs/parallel-lanes.png)

### Background tasks and subagents

![a subagent orbiting Agents, its call leaving from there](docs/subagent-orbit.png)

- A call that started a background task keeps its station lit, with clock hands, after its own
  turn is over: until the task reports back, or until an answer arrives that no longer lists it
  as running. A task that failed leaves a red dot.
- Each running subagent is a small dot circling the Agents station, and the calls it makes fly
  out from Agents instead of from the hub. Claude Code's own internal agents, which end without
  ever starting, are ignored.

![Shell kept lit by a background task](docs/background-task.png)

### Theme

![osaka-jade, catppuccin-latte and tokyo-night](docs/themes.png)

The window follows the Omarchy theme: it reads `~/.local/state/omarchy/current/theme/colors.toml`
(`accent`, `background`, `foreground`, `muted`, `red`, `cyan` (read, but the Memory icon now matches the others),
`mode`) and mixes the rest of its surfaces and text from background and foreground, so light
themes work too. Without a theme file it uses a built-in dark palette.

A theme switch replaces files, symlinks, even the folder, which can leave a file watcher
looking at a deleted file; so the file is watched *and* re-read every two seconds (a few
hundred bytes). While the file is briefly missing mid-switch the current colours stay.

![tokyo-night, then catppuccin-latte after the theme folder was swapped, still latte while the file was missing, then back](docs/theme-live-switch.png)

To try a theme without switching your desktop, point `ROUNDHOUSE_THEME` at any `colors.toml`:
`ROUNDHOUSE_THEME=/usr/share/omarchy/themes/catppuccin-latte/colors.toml bin/roundhouse`.

### Several sessions

![auto on alpha, stepped to beta (pinned), the list, and auto following beta again](docs/sessions.png)

A bar under the map names the session on show (its folder) and where it sits among the live
ones (`2/3`). By default the window follows whichever session was active most recently
(`auto`); stepping to another one pins it (`pinned`) until you go back to auto. A session
that ended, or has been quiet for 30 minutes, is not listed. If the one you pinned ends, the
window falls back to auto. Only the session on show pulses.

- **Mouse:** `‹` `›` step through sessions, the name opens the list, `pinned` goes back to auto.
- **Keyboard** (click the window first): `[` `]` or the arrow keys step, space opens the
  list and `1`-`9` pick from it, `a` is auto, escape closes the list.

### Pulses and the feed

![a recorded session replayed into the window](docs/pulses.gif)

- A call starting sends a dot from the hub out along its spoke and ripples the station; the
  call ending sends one back, red if it failed. A station with a call running keeps a soft
  amber glow.
- A prompt pulses You and sends a dot on to Model; each step between tool batches pulses
  Model; a finished answer sends a wide ring out from the hub.
- A call that was refused (still open when the next step or the answer arrives) flashes red at
  its station and shows as a red ✕ row. That includes background calls: only their task
  outlives the call.
- Under the map, one line says what is happening now ("Files: a.ts and 2 more · +1
  elsewhere"), and below it the last 16 rows read ● running, · done, ✕ failed or blocked.
  Finished rows that follow each other at one station are folded into one row with `+N`.
- Only events from the last few seconds pulse, so opening the window on an old log does not
  replay it.

![a refused call and several pulses at once](docs/pulses-blocked.png)

To watch a recorded log play back (for development and screenshots), point a second log
directory at the window and replay into it:

```bash
LOT_MAP_DIR=/tmp/rh-demo bin/roundhouse &
tools/replay.py recorded.jsonl /tmp/rh-demo --sid 520a9593
```

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

- Linux with Hyprland and `quickshell` (Omarchy has both); Python 3 (standard library only).
- Claude Code 2.1.295 or later is recommended (the hook events used are listed in `docs/DESIGN.md`).
- Optional: [claude-strip](https://github.com/TaylorBurke/claude-strip) 0.4 or later, for the
  session header and the map icon.
- To run the tests: `qml6` and `qmltestrunner` (both in `qt6-declarative`); `quickshell` for the window test (skipped without it).

## Tests

```bash
python3 -m unittest discover -s tests
```

Covers the emitter, the board logic and the theme (QML run under `qml6`), the map's waiting, slow, heat and press cues (`tests/visuals.test.qml`),
the switcher and session header (clicks through Qt's input system, under `qmltestrunner`), the window
list, the strip reader, the transcript reader (`tools/transcript.py`, read-only, fake home and fixture transcripts: huge or NaN/deeply nested lines, tail reads, interrupted prompts), and the installer (including an exact install-then-uninstall round trip).
`tests/test_window.py` runs the real service (`ui/shell.qml` and every window) under Quickshell, offscreen,
with a fake home folder, a short log and stub `hyprctl`/`omarchy`/`xdg-open`/`wtype`/`wl-copy`, and clicks
through it with synthesized mouse events (`tests/window/Driver.qml`): Files (a list, then a name opens in the
editor), Memory (the read file tagged), the click-away area, right clicks for recent calls, Hooks, the hub and
You. It fails when the window does not load at all. Nothing reaches your desktop or your home folder. To
see each step, `RH_SHOTS=/some/dir python3 -m unittest tests.test_window` saves a picture per step there.
The terminal log viewer (`bin/lot-map-log`) has no tests of its own. Not covered: the compositor's own pointer
delivery to a real Wayland window (the events are synthesized inside Qt), and Hyprland's window rules.

## Credit

The idea and the look are from [lot-map](https://github.com/alexeyw/lot-map) by alexeyw (MIT), a
Claude Code plugin that draws this map in the desktop app. roundhouse is a separate project for
Linux terminals, fed by ordinary Claude Code hooks; its code and icons are written fresh.

## License

[MIT](LICENSE)
