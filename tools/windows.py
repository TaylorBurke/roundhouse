#!/usr/bin/python3 -I
"""Which roundhouse windows are shown, and the command that changes it.

  windows.py show [SID]       show a window for that session (default: the all-sessions window, "*")
  windows.py hide [SID]
  windows.py toggle [SID]
  windows.py rebind OLD NEW   the window for OLD now shows NEW (after /clear), keeping its place
  windows.py list             the sessions in the log, and which have a window

The set lives in $XDG_RUNTIME_DIR/lot-map/windows.json (tmpfs, so it resets at logout):

  {"shown": [{"id": "all", "sid": "*"}, {"id": "w1", "sid": "ab12cd34"}]}

`id` is stable for a window's life, `sid` is the first 8 characters of a session id (or "*" for
the all-sessions window with the switcher). The file is rewritten atomically under a lock. The
mutating commands print the sids now shown, space separated, and nothing if none are.
"""
import fcntl
import json
import os
import re
import sys
import time

ALL = "*"


def log_dir():
    base = os.environ.get("LOT_MAP_DIR")
    if base:
        return base
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/lot-map-{os.getuid()}"
    return os.path.join(runtime, "lot-map")


def norm(sid):
    """The 8-character form of a session id, or "*"."""
    if sid == ALL:
        return ALL
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", sid or ""):
        raise ValueError(f"not a session id: {sid!r}")
    return sid[:8]


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        entries = data["shown"]
    except (OSError, ValueError, KeyError, TypeError):
        return []
    out = []
    for e in entries if isinstance(entries, list) else []:
        if isinstance(e, dict) and isinstance(e.get("id"), str) and isinstance(e.get("sid"), str):
            out.append({"id": e["id"], "sid": e["sid"]})
    return out


def save(path, entries):
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"shown": entries}, f, separators=(",", ":"))
    os.replace(tmp, path)


def next_id(entries):
    used = {e["id"] for e in entries}
    n = 1
    while f"w{n}" in used:
        n += 1
    return f"w{n}"


def show(entries, sid):
    if any(e["sid"] == sid for e in entries):
        return entries
    return entries + [{"id": "all" if sid == ALL else next_id(entries), "sid": sid}]


def hide(entries, sid):
    return [e for e in entries if e["sid"] != sid]


def toggle(entries, sid):
    return hide(entries, sid) if any(e["sid"] == sid for e in entries) else show(entries, sid)


def rebind(entries, old, new):
    if old == new or not any(e["sid"] == old for e in entries):
        return entries
    if any(e["sid"] == new for e in entries):      # NEW already has a window: just drop OLD's
        return hide(entries, old)
    return [{"id": e["id"], "sid": new} if e["sid"] == old else e for e in entries]


def update(change):
    """Apply `change(entries) -> entries` under a lock; returns the new entries."""
    folder = log_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    path = os.path.join(folder, "windows.json")
    fd = os.open(os.path.join(folder, "windows.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        before = load(path)
        after = change(before)
        if after != before:
            save(path, after)
        return after
    finally:
        os.close(fd)


def idle_label(seconds):
    if seconds < 10:
        return "now"
    if seconds < 60:
        return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    return f"{int(seconds // 3600)}h"


def sessions_in_log():
    """sid -> {dir, first, last, ended} from the event log, oldest first."""
    found = {}
    try:
        with open(os.path.join(log_dir(), "events.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                sid = e.get("sid")
                if not isinstance(sid, str):
                    continue
                s = found.setdefault(sid, {"dir": "", "first": e.get("ts", 0), "last": 0, "ended": False})
                s["last"] = max(s["last"], e.get("ts", 0))
                if e.get("ev") == "session":
                    s["dir"] = e.get("dir") or s["dir"]
                    s["ended"] = False
                elif e.get("ev") == "session_end":
                    s["ended"] = True
    except OSError:
        pass
    return dict(sorted(found.items(), key=lambda kv: kv[1]["first"]))


def listing():
    shown = {e["sid"] for e in load(os.path.join(log_dir(), "windows.json"))}
    now = time.time()
    lines = []
    for sid, s in sessions_in_log().items():
        state = "ended" if s["ended"] else idle_label(now - s["last"])
        lines.append(f"{sid}  {s['dir'] or '-':20.20}  {state:6}  {'window' if sid in shown else ''}".rstrip())
    return "\n".join(lines)


USAGE = __doc__.split("\n\n")[0]


def main(argv):
    if not argv:
        argv = ["show"]
    action, rest = argv[0], argv[1:]
    try:
        if action == "list" and not rest:
            print(listing())
            return 0
        if action in ("show", "hide", "toggle") and len(rest) <= 1:
            sid = norm(rest[0]) if rest else ALL
            fn = {"show": show, "hide": hide, "toggle": toggle}[action]
            after = update(lambda entries: fn(entries, sid))
        elif action == "rebind" and len(rest) == 2:
            old, new = norm(rest[0]), norm(rest[1])
            after = update(lambda entries: rebind(entries, old, new))
        else:
            raise ValueError("usage")
    except ValueError as err:
        print(str(err) if str(err) != "usage" else USAGE, file=sys.stderr)
        return 2
    print(" ".join(e["sid"] for e in after))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
