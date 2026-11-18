#!/usr/bin/python3 -I
"""Summarise a Claude Code transcript at click time. Read-only: nothing is written, nothing is executed.

  transcript.py turn SID [AGENT]      the latest turn: one entry per model call (think time, reasoning, tokens, tools)
  transcript.py context SID [AGENT]   tokens in the context at each model call, and the compactions
  transcript.py path SID [AGENT]      where the transcript (or a subagent's) lives

SID is the 8-character session prefix the map shows; AGENT is a subagent id (a prefix of agent-<id>). The
transcript is looked for as ~/.claude/projects/<project>/<SID>*.jsonl (the project folder from claude-strip's
state when it is known, else every project, newest file first); a subagent's is
<project>/<session>/subagents/agent-<AGENT>*.jsonl. A path is only used if it resolves to a regular file
inside ~/.claude/projects. Every answer is one JSON object on stdout, kept under a size cap. Thinking blocks
are often empty (redacted): that shows as "thinking": null with "redacted": true, never as an error.

Exit status: 0 answered (a missing transcript is {"found": false}), 2 bad arguments.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import openable  # noqa: E402  (folder_of_session, project_keys, under)

MAX_FILE = 256 * 1024 * 1024      # a bigger transcript is read from its tail only
TAIL = 16 * 1024 * 1024
MAX_LINE = 4 * 1024 * 1024        # a longer line is skipped, not parsed
MAX_STEPS = 60                    # turn: steps returned (the last ones)
MAX_CONTEXT = 300                 # context: points returned (evenly thinned)
MAX_TOOLS = 20
MAX_REASONING = 400               # characters of reasoning kept per step
MAX_OUTPUT = 60000                # bytes of JSON on stdout
SID = re.compile(r"[A-Za-z0-9_-]{8}")
AGENT = re.compile(r"[A-Za-z0-9_-]{1,64}")


def projects_root():
    return os.path.join(openable.HOME, ".claude", "projects")


def safe(path):
    """The real path of an existing regular file inside ~/.claude/projects, or None."""
    try:
        real = os.path.realpath(path)
        if os.path.isfile(real) and openable.under(real, os.path.realpath(projects_root())):
            return real
    except (OSError, ValueError):
        pass
    return None


def newest(paths):
    out = []
    for p in paths:
        real = safe(p)
        if real:
            try:
                out.append((os.path.getmtime(real), real))
            except OSError:
                pass
    return [p for _, p in sorted(out, reverse=True)]


def project_dirs(sid):
    """Project folders to look in: the session's own when its folder is known, else all of them."""
    root = projects_root()
    try:
        every = sorted(e for e in os.listdir(root) if os.path.isdir(os.path.join(root, e)))
    except OSError:
        return []
    cwd = openable.folder_of_session(sid)
    if cwd:
        own = [e for e in every if e in openable.project_keys(cwd)]
        if own:
            return [os.path.join(root, e) for e in own]
    return [os.path.join(root, e) for e in every]


def find_session(sid):
    """The newest ~/.claude/projects/*/<sid>*.jsonl that passes safe(), or None."""
    if not isinstance(sid, str) or not SID.fullmatch(sid):
        return None
    hits = []
    for d in project_dirs(sid):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        hits += [os.path.join(d, n) for n in names if n.startswith(sid) and n.endswith(".jsonl")]
    found = newest(hits)
    return found[0] if found else None


def agents_of(session_path):
    folder = session_path[:-len(".jsonl")] + "/subagents"
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return {}
    out = {}
    for n in names:
        m = re.fullmatch(r"agent-([A-Za-z0-9_-]+)\.jsonl", n)
        if m and safe(os.path.join(folder, n)):
            out[m.group(1)] = os.path.join(folder, n)
    return out


def locate(sid, agent=None):
    """(transcript path or None, session path or None, agent ids). Raises ValueError for a bad agent."""
    if agent is not None and not AGENT.fullmatch(agent):
        raise ValueError("agent")
    session = find_session(sid)
    if not session:
        return None, None, []
    agents = agents_of(session)
    if agent is None:
        return safe(session), session, sorted(agents)
    hits = sorted(k for k in agents if k.startswith(agent))
    return (safe(agents[hits[0]]) if hits else None), session, sorted(agents)


def records(path):
    """Parsed records of a transcript, in order. Lines that are too long or not JSON are skipped; a huge
    file is read from its tail (the first partial line dropped). Returns (records, truncated)."""
    out, truncated = [], False
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > MAX_FILE:
                f.seek(size - TAIL)
                f.readline()
                truncated = True
            for raw in f:
                if len(raw) > MAX_LINE:
                    continue
                try:
                    rec = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        return [], False
    return out, truncated


def is_prompt(rec):
    """A real user prompt: not a tool result, not a meta or compaction-summary entry."""
    if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isCompactSummary"):
        return False
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip())
    return isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "text" for b in content)


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def steps_of(recs, sidechain):
    """One step per model call: consecutive assistant records sharing a message id are the blocks of one call."""
    steps, by_id = [], {}
    for rec in recs:
        if rec.get("type") != "assistant" or (not sidechain and rec.get("isSidechain")):
            continue
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        key = msg.get("id") or rec.get("requestId") or rec.get("uuid")
        step = by_id.get(key)
        if step is None:
            step = {"ts": rec.get("timestamp"), "think_ms": 0, "thinking": None, "redacted": False,
                    "tokens_in": 0, "tokens_out": 0, "tools": [], "text": False}
            by_id[key] = step
            steps.append(step)
        usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
        if usage:
            step["tokens_in"] = (num(usage.get("input_tokens")) + num(usage.get("cache_read_input_tokens"))
                                 + num(usage.get("cache_creation_input_tokens")))
            step["tokens_out"] = num(usage.get("output_tokens"))
        content = msg.get("content") if isinstance(msg.get("content"), list) else []
        for b in content:
            if not isinstance(b, dict):
                continue
            kind = b.get("type")
            if kind == "thinking":
                step["think_ms"] += int(num(rec.get("thinkingDurationMs")))
                text = b.get("thinking")
                if isinstance(text, str) and text.strip():
                    if step["thinking"] is None:
                        step["thinking"] = text.strip()[:MAX_REASONING]
                else:
                    step["redacted"] = True
            elif kind == "tool_use" and isinstance(b.get("name"), str) and len(step["tools"]) < MAX_TOOLS:
                step["tools"].append(b["name"][:80])
            elif kind == "text":
                step["text"] = True
    return steps


def thin(items, limit):
    if len(items) <= limit:
        return items
    keep = {round(i * (len(items) - 1) / (limit - 1)) for i in range(limit)}
    return [x for i, x in enumerate(items) if i in keep]


def turn(recs, sidechain):
    """Records of the latest turn: after the last real prompt (the whole file for a subagent or no prompt)."""
    start = 0
    if not sidechain:
        for i, rec in enumerate(recs):
            if is_prompt(rec) and not rec.get("isSidechain"):
                start = i + 1
    part = recs[start:]
    steps = steps_of(part, sidechain)
    duration = None
    for rec in part:
        if rec.get("type") == "system" and rec.get("subtype") == "turn_duration":
            duration = int(num(rec.get("durationMs")))
    shown = steps[-MAX_STEPS:]
    return {"duration_ms": duration, "steps": shown, "step_count": len(steps),
            "totals": {"think_ms": sum(s["think_ms"] for s in steps),
                       "tokens_out": sum(s["tokens_out"] for s in steps),
                       "tokens_in_last": steps[-1]["tokens_in"] if steps else 0}}


def context(recs, sidechain):
    steps = steps_of(recs, sidechain)
    points = [{"ts": s["ts"], "tokens_in": s["tokens_in"], "tokens_out": s["tokens_out"]} for s in steps]
    compactions = []
    for rec in recs:
        if rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
            meta = rec.get("compactMetadata") if isinstance(rec.get("compactMetadata"), dict) else {}
            trigger = meta.get("trigger")
            compactions.append({"ts": rec.get("timestamp"),
                                "trigger": trigger[:20] if isinstance(trigger, str) else None,
                                "pre_tokens": int(num(meta.get("preTokens"))),
                                "post_tokens": int(num(meta.get("postTokens")))})
    return {"points": thin(points, MAX_CONTEXT), "point_count": len(points),
            "peak": max((p["tokens_in"] for p in points), default=0), "compactions": compactions[-50:]}


def cap(result):
    """Keep the JSON under MAX_OUTPUT: drop the oldest steps, then the reasoning text, until it fits."""
    def size():
        return len(json.dumps(result))
    body = result.get("turn") or result.get("context") or {}
    key = "steps" if "steps" in body else "points"
    while size() > MAX_OUTPUT and body.get(key):
        if key == "steps" and any(s.get("thinking") for s in body[key]):
            for s in body[key]:
                s["thinking"] = None
        else:
            body[key] = body[key][len(body[key]) // 2:]
        result["capped"] = True
    return result


def run(cmd, sid, agent=None):
    path, session, agents = locate(sid, agent)
    out = {"sid": sid, "agent": agent, "found": bool(path)}
    if cmd == "path":
        out.update(path=path, session=session, agents=agents)
        return out
    if not path:
        out["agents"] = agents
        return out
    recs, truncated = records(path)
    out["path"] = path
    out["truncated"] = truncated
    sidechain = agent is not None
    out["turn" if cmd == "turn" else "context"] = (turn if cmd == "turn" else context)(recs, sidechain)
    return cap(out)


def main(argv):
    if len(argv) in (2, 3) and argv[0] in ("turn", "context", "path") and SID.fullmatch(argv[1]):
        try:
            print(json.dumps(run(argv[0], argv[1], argv[2] if len(argv) == 3 else None)))
            return 0
        except ValueError:
            pass
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
