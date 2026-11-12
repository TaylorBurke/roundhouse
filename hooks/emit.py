#!/usr/bin/python3 -I
"""Claude Code hook -> one sanitised JSON line in $XDG_RUNTIME_DIR/lot-map/events.jsonl.

Rules this file must keep:
  * Names only, never content. No prompt text, command lines, file bodies,
    tool output or memory text is ever written.
  * Never print to stdout/stderr and always exit 0, so a fault here can never
    reach a tool call, a permission decision or the conversation.
  * Standard library only, no network, no subprocesses.
"""
import fcntl
import json
import os
import re
import sys
import time
from urllib.parse import urlsplit

SCHEMA = 1
MAX_LOG_BYTES = 1_000_000   # cut the log back when it passes this size ...
KEEP_LINES = 500            # ... to its newest lines
LABEL_MAX = 60
TRANSCRIPT_TAIL = 256 * 1024

# ---- labels ---------------------------------------------------------------------------

# C0/C1 control characters and the bidirectional-override marks.
_UNSAFE = re.compile(r"[\x00-\x1f\x7f-\x9f‎‏‪-‮⁦-⁩]+")
_ID = re.compile(r"^[\w.:-]{1,64}$")


def clean(text, limit=LABEL_MAX):
    text = re.sub(r" {2,}", " ", _UNSAFE.sub(" ", str(text))).strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def ident(value):
    """An opaque id (tool use, task, agent, model) or None. Anything odd is dropped."""
    return value if isinstance(value, str) and _ID.match(value) else None


def text_of(value):
    return value if isinstance(value, str) else ""


def last_two(path):
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    return "/".join(parts[-2:])


def host_of(url):
    """Only the host: no login, password, port, path or query."""
    try:
        host = urlsplit(url if "//" in url else "//" + url).hostname or ""
    except ValueError:
        host = ""
    return host[:40] if re.fullmatch(r"[\w.\-:]+", host) else ""


_MEMORY_DIR = re.compile(r"/\.claude/projects/[^/]+/memory(/|$)")


def is_memory_path(path):
    return bool(_MEMORY_DIR.search(path.replace("\\", "/")))


# ---- shell commands -------------------------------------------------------------------

FILE_COMMANDS = frozenset(
    "cat head tail less sed awk grep egrep fgrep rg ag fd find ls tree stat file wc du df "
    "cp mv rm mkdir rmdir touch ln chmod chown diff cmp sort uniq cut tr tee jq yq "
    "basename dirname realpath readlink md5sum sha256sum tar zip unzip gzip gunzip xxd".split()
)
QUIET_COMMANDS = frozenset(
    "echo printf cd pushd popd export unset set true false pwd sleep which type test [ [[ "
    "wait read local return exit : source .".split()
)
NETWORK_COMMANDS = frozenset(
    "curl wget gh ssh scp sftp ftp rsync nc ncat telnet ping dig nslookup host whois "
    "traceroute nmap aria2c yt-dlp pacman yay paru wrangler vercel eas".split()
)
NETWORK_SUBCOMMANDS = {
    "git": {"push", "pull", "fetch", "clone", "ls-remote"},
    "npm": {"install", "i", "ci", "add", "update", "publish", "view", "audit"},
    "npx": None,  # None: every use may download
    "pnpm": {"install", "i", "add", "update", "publish", "dlx"},
    "yarn": {"install", "add", "upgrade", "publish", "dlx"},
    "bun": {"install", "add", "update", "publish", "x"},
    "pip": {"install", "download"},
    "pip3": {"install", "download"},
    "uv": {"add", "sync", "pip", "tool"},
    "cargo": {"install", "fetch", "publish", "update", "add"},
    "docker": {"pull", "push", "login"},
    "podman": {"pull", "push", "login"},
    "go": {"get", "install"},
}
WRAPPERS = frozenset("sudo env time nohup command exec nice stdbuf".split())

_REDIRECT = re.compile(r"\d*>&\d+|&>>?|\d*>>?|<<?<?")
_SPLIT = re.compile(r"&&|\|\||[;|&\n]")
_SPLIT_DEEP = re.compile(r"&&|\|\||[;|&\n()`]|\$\(")
_WORD = re.compile(r"""(?:[^\s"']|"[^"]*"?|'[^']*'?)+""")
_ASSIGN = re.compile(r"^[A-Za-z_]\w*=")


def _commands(line, deep=False):
    """Each command of a shell line as its words, assignments and wrappers taken off."""
    out = []
    for part in (_SPLIT_DEEP if deep else _SPLIT).split(_REDIRECT.sub(" ", line)):
        words = _WORD.findall(part)
        i = 0
        while i < len(words) and (_ASSIGN.match(words[i]) or words[i] in WRAPPERS):
            i += 1
        if words[i:]:
            out.append(words[i:])
    return out


def _name(word):
    return word.replace('"', "").replace("'", "").replace("\\", "/").rsplit("/", 1)[-1]


def classify_shell(command, description):
    commands = _commands(command)
    first = _name(commands[0][0]) if commands else "shell"
    label = clean(description) or clean(first, 32) or "shell"
    for words in _commands(command, deep=True):
        head = _name(words[0])
        subs = NETWORK_SUBCOMMANDS.get(head, ())
        if head in NETWORK_COMMANDS or subs is None or (len(words) > 1 and words[1] in subs):
            return "network", label
    real = [w for w in commands if _name(w[0]) not in QUIET_COMMANDS]
    if real and all(_name(w[0]) in FILE_COMMANDS for w in real):
        return ("memory" if is_memory_path(command) else "files"), label
    return "shell", label


# ---- tools ----------------------------------------------------------------------------

BROWSER_SERVERS = ("claude-in-chrome", "Claude_Browser", "chrome-devtools", "playwright", "puppeteer")
MEMORY_SERVERS = ("memory",)


def classify(tool, tool_input):
    """A tool call as (station, label). The label is a name, never content."""
    inp = tool_input if isinstance(tool_input, dict) else {}
    if tool in ("Read", "Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = text_of(inp.get("file_path")) or text_of(inp.get("notebook_path"))
        return ("memory" if is_memory_path(path) else "files"), clean(last_two(path)) or tool
    if tool in ("Grep", "Glob", "LS"):
        return ("memory" if is_memory_path(text_of(inp.get("path"))) else "files"), tool
    if tool in ("Bash", "PowerShell"):
        return classify_shell(text_of(inp.get("command")), text_of(inp.get("description")))
    if tool == "Monitor":
        return "shell", clean(text_of(inp.get("description"))) or tool
    if tool == "WebFetch":
        return "network", host_of(text_of(inp.get("url"))) or "web fetch"
    if tool == "WebSearch":
        return "network", "web search"
    if tool == "Artifact":
        return "network", "artifact"
    if tool in ("Agent", "Task"):
        return "agents", clean(text_of(inp.get("description"))) or "subagent"
    if tool in ("Workflow", "SendMessage", "TaskStop", "ListAgents", "SubagentHandback"):
        return "agents", tool
    if tool == "Skill":
        return "skills", clean(text_of(inp.get("skill")), 40) or "skill"
    if tool == "ToolSearch":
        return "skills", "loading tools"
    if tool in ("AskUserQuestion", "SendUserFile"):
        return "you", "question for you" if tool == "AskUserQuestion" else "file for you"
    mcp = re.fullmatch(r"mcp__(.+?)__(.+)", tool or "")
    if not mcp:
        return "shell", clean(tool, 40) or "tool"
    server, name = mcp.group(1), clean(mcp.group(2).replace("_", " "), 40)
    if any(key in server for key in BROWSER_SERVERS):
        return "browser", host_of(text_of(inp.get("url"))) or name
    if server in MEMORY_SERVERS:
        return "memory", name
    return "network", clean(f"{server}: {name}")


def task_of(response):
    """The id of the background task a tool call started, if it started one."""
    if not isinstance(response, dict):
        return None
    if response.get("status") in ("async_launched", "remote_launched"):
        return ident(response.get("agentId")) or ident(response.get("taskId"))
    return ident(response.get("backgroundTaskId"))


_NOTICE_ID = re.compile(r"<task-id>([\w-]{1,64})</task-id>")
_NOTICE_STATUS = re.compile(r"<status>(\w{1,20})</status>")


def task_notice(prompt):
    """A background task's report: its id and how it ended, and nothing else of it."""
    if not prompt.lstrip().startswith("<task-notification>"):
        return None
    found = _NOTICE_ID.search(prompt)
    if not found:
        return None
    status = _NOTICE_STATUS.search(prompt)
    return {"task": found.group(1), "status": ("err" if status.group(1) == "failed" else "ok") if status else None}


# ---- context window -------------------------------------------------------------------


def context_of(transcript_path):
    """Token count and model of the newest main-loop response. Reads numbers, keeps nothing else."""
    path = os.path.realpath(os.path.expanduser(transcript_path))
    root = os.path.realpath(os.path.expanduser("~/.claude")) + os.sep
    if not path.startswith(root) or not path.endswith(".jsonl"):
        return None
    with open(path, "rb") as f:
        size = f.seek(0, os.SEEK_END)
        start = max(0, size - TRANSCRIPT_TAIL)
        f.seek(start)
        lines = f.read().split(b"\n")
    if start > 0:
        lines = lines[1:]  # the first one is cut in the middle
    for raw in reversed(lines):
        if b'"usage"' not in raw:
            continue
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        message = row.get("message") if isinstance(row, dict) else None
        if row.get("isSidechain") or not isinstance(message, dict):
            continue
        usage, model = message.get("usage"), ident(message.get("model"))
        if not isinstance(usage, dict) or model is None:
            continue
        keys = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
        tokens = sum(v for v in (usage.get(k) for k in keys) if isinstance(v, int))
        return {"tokens": tokens, "model": model}
    return None


# ---- events ---------------------------------------------------------------------------


def events_for(data):
    """The hook's payload as a list of event dicts (without the common fields)."""
    kind = data.get("hook_event_name")
    agent = ident(data.get("agent_id"))
    tool = text_of(data.get("tool_name"))
    out = []

    def tool_fields():
        station, label = classify(tool, data.get("tool_input"))
        return {"id": ident(data.get("tool_use_id")), "station": station, "label": label, "tool": clean(tool, 60)}

    def duration():
        ms = data.get("duration_ms")
        return {"ms": int(ms)} if isinstance(ms, (int, float)) else {}

    if kind == "SessionStart":
        out.append({"ev": "session", "source": clean(text_of(data.get("source")), 20),
                    "model": ident(data.get("model")),
                    "dir": clean(os.path.basename(text_of(data.get("cwd")).rstrip("/")), 40)})
    elif kind == "UserPromptSubmit":
        notice = task_notice(text_of(data.get("prompt")))
        out.append({"ev": "task_end", **notice} if notice else {"ev": "prompt"})
    elif kind == "PreToolUse":
        inp = data.get("tool_input")
        background = isinstance(inp, dict) and inp.get("run_in_background") is True
        out.append({"ev": "tool_start", **tool_fields(), **({"bg": True} if background else {})})
    elif kind == "PostToolUse":
        task = task_of(data.get("tool_response"))
        out.append({"ev": "tool_end", **tool_fields(), "status": "ok", **duration(), **({"task": task} if task else {})})
    elif kind == "PostToolUseFailure":
        out.append({"ev": "tool_end", **tool_fields(), "status": "err", **duration(),
                    **({"interrupt": True} if data.get("is_interrupt") is True else {})})
    elif kind == "PostToolBatch":
        out.append({"ev": "batch"})
    elif kind == "PermissionRequest":
        out.append({"ev": "ask", **tool_fields()})
    elif kind == "PermissionDenied":
        out.append({"ev": "denied", **tool_fields()})
    elif kind in ("SubagentStart", "SubagentStop"):
        if not clean(text_of(data.get("agent_type")), 40):
            return []  # Claude Code's own internal agents: no matching start, nothing to show
        out.append({"ev": "agent_start" if kind == "SubagentStart" else "agent_end",
                    "type": clean(text_of(data.get("agent_type")), 40)})
    elif kind == "Stop":
        tasks = data.get("background_tasks")
        running = [{"id": ident(t.get("id")), "type": clean(text_of(t.get("type")), 20),
                    "status": clean(text_of(t.get("status")), 20)}
                   for t in (tasks if isinstance(tasks, list) else []) if isinstance(t, dict)]
        out.append({"ev": "stop", "bg": running[:20]})
    elif kind == "StopFailure":
        out.append({"ev": "stop_error", "error": clean(text_of(data.get("error")), 30)})
    elif kind in ("PreCompact", "PostCompact"):
        out.append({"ev": "compact_start" if kind == "PreCompact" else "compact_end",
                    "trigger": clean(text_of(data.get("trigger")), 10)})
    elif kind == "PostModelSwitch":
        out.append({"ev": "model", "from": ident(data.get("from_model")), "to": ident(data.get("to_model"))})
    elif kind == "Notification":
        out.append({"ev": "notify", "type": clean(text_of(data.get("notification_type")), 30)})
    elif kind == "SessionEnd":
        out.append({"ev": "session_end", "reason": clean(text_of(data.get("reason")), 20)})
    else:
        return []

    # How full the context window is, after the moments the main loop's usage changes.
    # Not after a compaction: the transcript still holds the old, larger numbers then.
    after_compact = kind == "PostCompact" or (kind == "SessionStart" and data.get("source") == "compact")
    if kind in ("Stop", "PostToolBatch", "SessionStart") and agent is None and not after_compact:
        try:
            context = context_of(text_of(data.get("transcript_path")))
        except OSError:
            context = None
        if context:
            out.append({"ev": "context", **context})

    if agent:
        for event in out:
            event["agent"] = agent
    return out


# ---- the log --------------------------------------------------------------------------


def log_dir():
    base = os.environ.get("LOT_MAP_DIR")
    if base:
        return base
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/lot-map-{os.getuid()}"
    return os.path.join(runtime, "lot-map")


def append(events):
    if not events:
        return
    folder = log_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    payload = "".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n" for e in events).encode()
    fd = os.open(os.path.join(folder, "events.jsonl"), os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if os.fstat(fd).st_size > MAX_LOG_BYTES:
            # Cut in place, under the lock every writer takes, so readers keep their handle.
            kept = os.pread(fd, MAX_LOG_BYTES * 2, 0).split(b"\n")[-(KEEP_LINES + 1):]
            os.ftruncate(fd, 0)
            os.write(fd, b"\n".join(kept))
        os.write(fd, payload)
    finally:
        os.close(fd)


def main():
    started = time.time()
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        return
    session = ident(data.get("session_id")) or "unknown"
    common = {"v": SCHEMA, "ts": round(started, 3), "sid": session[:8]}
    append([{**common, **event} for event in events_for(data)])


if __name__ == "__main__":
    try:
        main()
    except BaseException:  # noqa: BLE001 - nothing here may ever surface in Claude Code
        pass
    sys.exit(0)
