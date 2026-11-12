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
  transcript, and the window size (200k or 1M) will be a renderer setting.
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

Still to check in an interactive session: a refusal by a `PreToolUse` hook, a background
shell task from start to its notification, and subagent events.

## Renderer choice

Quickshell: already installed, no build step, QML drawing, and the theme can be followed
by watching `~/.local/state/omarchy/current/theme/colors.toml`. Risk: Quickshell windows
may share one app id, so the Hyprland rule would match on title. If that proves flaky,
the same QML moves into a small Qt Quick app with its own app id. A Chrome `--app` page
was rejected as heavy and unable to follow the theme.

Hyprland on this system is configured in Lua, so the window rule ships as a Lua snippet.
