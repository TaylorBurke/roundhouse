# Design

Written at stage 1, updated with what stage 2 measured. Checked against the Claude Code
hooks reference and Claude Code 2.1.322.

## Pieces

1. **Emitter** (`hooks/emit.py`): one Python file, standard library only, run by Claude
   Code hooks registered with `"async": true`. It sanitises the hook payload and appends
   JSON lines to the log.
2. **Log**: `$XDG_RUNTIME_DIR/lot-map/events.jsonl`. Append-only, mode 0600 in a 0700
   folder, cut back in place to its newest 500 lines when it passes 1 MB. Every writer
   takes an exclusive lock, so a cut never loses or splits a line.
3. **Renderer** (stage 3): a Quickshell `FloatingWindow` that tails the log.

A file was chosen over a socket because it works while the window is closed and can be
followed with any tool.

## Hooks used

| Hook | Fields read | Event written |
| --- | --- | --- |
| `SessionStart` | `source`, `model`, `cwd` (folder name only) | `session` |
| `UserPromptSubmit` | `prompt` (checked for a task-notification prefix; never stored) | `prompt` or `task_end` |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | `tool_start` |
| `PostToolUse` | the same, `duration_ms`, background task id from `tool_response` | `tool_end` ok |
| `PostToolUseFailure` | the same, `is_interrupt` | `tool_end` err |
| `PostToolBatch` | none | `batch` |
| `PermissionRequest` | `tool_name`, `tool_input` | `ask` |
| `PermissionDenied` | `tool_name`, `tool_input`, `tool_use_id` | `denied` |
| `SubagentStart` / `SubagentStop` | `agent_id`, `agent_type` | `agent_start` / `agent_end` |
| `Stop` | `background_tasks[].id/type/status` | `stop` |
| `StopFailure` | `error` | `stop_error` |
| `PreCompact` / `PostCompact` | `trigger` | `compact_start` / `compact_end` |
| `PostModelSwitch` | `from_model`, `to_model` | `model` |
| `Notification` | `notification_type` | `notify` |
| `SessionEnd` | `reason` | `session_end` |

After `Stop`, `PostToolBatch`, `PostCompact` and `SessionStart` in the main loop, a
`context` event follows with the token count and model of the newest response, read from
the transcript's `usage` numbers.

## Event lines

Every line has `v` (schema version, 1), `ts` (Unix seconds with milliseconds), `sid`
(first 8 characters of the session id) and `ev`. Events fired inside a subagent also
carry `agent`.

```json
{"v":1,"ts":1794461573.486,"sid":"7c8862de","ev":"tool_start","id":"toolu_017Q…","station":"files","label":"e2e/sample.txt","tool":"Read"}
{"v":1,"ts":1794461573.659,"sid":"7c8862de","ev":"tool_end","id":"toolu_017Q…","station":"files","label":"e2e/sample.txt","tool":"Read","status":"ok","ms":6}
{"v":1,"ts":1794461573.755,"sid":"7c8862de","ev":"context","tokens":42129,"model":"claude-haiku-5-5"}
```

`tool_start` and `tool_end` are paired by `id`, not by order: async hooks are separate
processes and may land out of order. `tool_end` repeats the station and label so a
reader that missed the start can still place it. Optional fields: `bg` (the call asked
to run in the background), `task` (the background task it started), `ms`, `interrupt`.

## Station mapping

| Station | Tools |
| --- | --- |
| Files | Read, Write, Edit, NotebookEdit, Grep, Glob; shell lines made only of file commands |
| Memory | any of the above on `~/.claude/projects/*/memory/`; MCP server `memory` |
| Shell | every other shell line, Monitor, unknown tools |
| Network | WebFetch, WebSearch, Artifact, MCP servers; shell lines with `curl`, `gh`, `ssh`, `git push`, `npm install` and the like, also inside `$(…)` |
| Browser | `claude-in-chrome`, `chrome-devtools`, Playwright and Puppeteer MCP servers |
| Agents | Agent, Task, Workflow, SendMessage, TaskStop |
| Skills | Skill, ToolSearch |
| You | AskUserQuestion, prompts, answers, notifications |
| Hooks | permission prompts, auto-mode denials, calls that started and never reported back |
| Model | steps between tool batches, compaction, model changes |

Shell lines are read by command name, not by what the command does: a script that opens
a connection itself shows as Shell.

## What hooks cannot give

- **Model steps.** No hook fires per model request. The Model station pulses on a prompt
  and after each tool batch; there is no step counter.
- **Context percentage.** No hook carries it. The emitter reads token counts from the
  transcript; the window size (200k or 1M) is a renderer setting (`config.json`), guessed
  from the model name when unset and raised to 1M if the tokens exceed 200k.
- **Context added by other hooks.** Not visible to a hook, so those rows are absent.
- **A refusal, directly.** See below.

## Measured in stage 2

A real `claude -p` session with the hooks attached showed:

- Hooks fire with `async: true` and events arrive in order in practice, about 150 ms
  after the action.
- A failing command arrives as `PostToolUseFailure` with `duration_ms`.
- A call that needs permission and is not granted gives `tool_start`, then `ask`
  (`PermissionRequest` has no `tool_use_id`), then `batch`, and no `tool_end`. So the
  renderer marks a call blocked when a `batch` or `stop` arrives while it is still open
  and it is not a background task.
- `SessionStart` may omit `model`; the first `context` event supplies it.

## Measured in stage 2b (interactive session)

An interactive session on Claude Code with all 17 hooks attached showed:

- **Call refused by a `PreToolUse` hook** (`omarchy-guard.sh`): `tool_start`, then nothing
  for that call (no `tool_end`, no `ask`, no `denied`), then the next `batch`. The
  "blocked" rule above holds for this case too. Seen twice, same result.
- **Background shell task:** `tool_end` with `task`, then `stop` with
  `bg: [{id, type: "shell", status: "running"}]`, then `task_end` (status `ok`) from the
  notification prompt, then a `stop` with `bg: []`.
- **Subagent:** `agent_start` with the type, `tool_*` events carrying `agent`, `agent_end`
  with the same type and id. A background `Agent` call's `tool_end` carries `task` set to
  the agent's id. `SubagentStop` also fires for Claude Code's own internal agents with an
  empty `agent_type` and no matching start (four times in one short session, including
  during `/compact`). The emitter now drops those.
- **Pseudo-tool `SubagentHandback`:** called by a subagent to hand its report back; shown
  at the Agents station.
- **Model switch:** a `model` event with `from` and `to`, right when `/model` is used. The
  `context` events keep naming the old model until the next response, so the renderer
  should treat the `model` event as authoritative.
- **Compaction:** `compact_start`, then a `session` event with `source: "compact"`, then
  `compact_end`. A `context` reading taken at that point is stale (the transcript still has
  the old numbers), so the emitter no longer writes one after a compaction; the next
  `Stop` or `PostToolBatch` supplies a fresh one.

## Board state (stage 3)

`ui/board.js` is plain JavaScript with no QML in it, so `tests/board.test.qml` can run it
under `qml6`. `ui/LogTail.qml` runs `tail -n 500 -F` and feeds it lines. `tail -F` waits for
a log that does not exist and starts again from the top when the emitter cuts the file in
place, so the board remembers the last 3000 lines it folded and skips replays. Order is not
trusted: an end may land before its start, and a late end frees a call a `batch` had wrongly
marked blocked. A `batch` or `stop` only blocks calls that started before it and belong to
the same agent. The `model` event wins over `context`'s model name until the next prompt.
A background call is judged like any other: its own `tool_end` arrives within milliseconds of launch (only the task keeps running), so one still open at the next `batch` was refused. (Stage 3 first exempted background calls; the recorded session showed a refused one glowing forever.)

## Windows (stage 5)

One Quickshell process (`quickshell -n`, so a second launch does nothing) runs a window per
entry of `windows.json`, an array of `{id, sid}`. `id` is the window's own and stable; `sid` is
what it shows (`*` is the all-sessions window), so `rebind` after a `/clear` changes `sid` and
the window stays where it is. The file is written by `tools/windows.py` under a lock and
replaced atomically, so the service watches it and also re-reads it every two seconds. The
service quits 1.5 s after the set becomes empty. Two Quickshell facts found the hard way:
`Qt.resolvedUrl` outside the config folder gives `qrc:/qs-blackhole` (use `Quickshell.shellPath`),
and a `FloatingWindow` closed by the compositor reports it as `visible` becoming false.

## Renderer choice

Quickshell: already installed, no build step, QML drawing, and the theme can be followed
by watching `~/.local/state/omarchy/current/theme/colors.toml`. Risk: Quickshell windows
may share one app id, so the Hyprland rule would match on title. If that proves flaky,
the same QML moves into a small Qt Quick app with its own app id. A Chrome `--app` page
was rejected as heavy and unable to follow the theme.

Hyprland on this system is configured in Lua, so the window rule ships as a Lua snippet.
