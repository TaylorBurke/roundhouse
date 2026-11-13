#!/usr/bin/python3 -I
"""What claude-strip knows about each session, keyed by roundhouse's session id.

Prints one JSON object: {"ab12cd34": {"project", "task", "phase", "running", "context",
"pid", "address"}, ...}. Optional and read-only: it reads the strip's own state files
($XDG_RUNTIME_DIR/claude-strip/<pid>.json, or $CLAUDE_STRIP_DIR) and writes nothing.

A file is used when it has a `sessionId` (written by the session-strip mod from 0.4 on), its
process is alive, and its session has not ended. The key is the first 8 characters of the
session id, as in roundhouse's log. `address` is the Hyprland window of the terminal the
session runs in (found by walking up from `pid`), or null; it is for focusing that window.

The `task` is the strip's own title, a summary of the session's prompts. It is passed on to
the window and shown there; roundhouse never writes it to its log.
"""
import glob
import json
import os
import re
import subprocess
import sys

PHASES = ("idle", "working", "waiting")
ADDRESS = re.compile(r"0x[0-9a-f]{1,16}")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]+")


def state_dir():
    return os.environ.get("CLAUDE_STRIP_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-strip")


def clean(text, limit):
    text = _CONTROL.sub(" ", text if isinstance(text, str) else "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def parent_of(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def window_address(pid, clients_by_pid):
    seen = 0
    while pid > 1 and seen < 64:
        client = clients_by_pid.get(pid)
        if client:
            address = client.get("address")
            return address if isinstance(address, str) and ADDRESS.fullmatch(address) else None
        pid = parent_of(pid)
        seen += 1
    return None


def hypr_clients():
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], timeout=3))
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    return {c["pid"]: c for c in clients if isinstance(c, dict) and isinstance(c.get("pid"), int) and c.get("mapped")}


def read_states(folder):
    out = {}
    for path in glob.glob(os.path.join(folder, "*.json")):
        try:
            with open(path, encoding="utf-8") as f:
                s = json.load(f)
            pid, session = int(s["pid"]), s["sessionId"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", session):
            continue
        if s.get("phase") == "ended" or not os.path.exists(f"/proc/{pid}"):
            continue
        sid = session[:8]
        stamp = s.get("updatedAt") if isinstance(s.get("updatedAt"), (int, float)) else 0
        if sid in out and out[sid][0] >= stamp:        # a resumed session may leave two files: the newer wins
            continue
        context = s.get("context")
        running = s.get("running")
        out[sid] = (stamp, {
            "project": clean(s.get("project"), 80),
            "task": clean(s.get("task"), 240),
            "phase": s.get("phase") if s.get("phase") in PHASES else "idle",
            "running": running if isinstance(running, int) and running >= 0 else 0,
            "context": context if isinstance(context, int) and 0 <= context <= 100 else -1,
            "pid": pid,
        })
    return {sid: v for sid, (_, v) in out.items()}


def main():
    states = read_states(state_dir())
    if states:
        clients = hypr_clients()
        for s in states.values():
            s["address"] = window_address(s["pid"], clients)
    print(json.dumps(states))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - an optional helper: never anything but a valid answer
        print("{}")
    sys.exit(0)
