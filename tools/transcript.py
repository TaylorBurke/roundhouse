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

Added fields (the rest of each shape is unchanged): "partial" (turn and context) and turn "totals"."exact" say
whether a tail read of a huge file may have cut off the start of what is reported, so the numbers are then
lower bounds; "ambiguous" is set when the 8-character SID matches several sessions (the newest is used);
"error": "unreadable" accompanies {"found": false} when a transcript could not be processed.

Exit status: 0 answered (a missing transcript is {"found": false}), 2 bad arguments. Never a traceback.
"""
import json
import math
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
MAX_AGENTS = 200                  # path: subagent ids listed
MAX_TS = 40                       # characters of a timestamp kept
MAX_NUM = 2 ** 53                 # numbers read from a transcript are clamped to this
INTERRUPTED = "[Request interrupted by user"
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
    cwd = openable.folder_of_session(sid)
    if cwd:
        own = [os.path.join(root, k) for k in sorted(openable.project_keys(cwd))
               if os.path.isdir(os.path.join(root, k))]
        if own:
            return own
    try:
        with os.scandir(root) as it:
            return [e.path for e in sorted(it, key=lambda e: e.name) if e.is_dir()]
    except OSError:
        return []


def find_sessions(sid):
    """Every ~/.claude/projects/*/<sid>*.jsonl that passes safe(), newest first."""
    if not isinstance(sid, str) or not SID.fullmatch(sid):
        return []
    hits = []
    for d in project_dirs(sid):
        try:
            with os.scandir(d) as it:
                hits += [os.path.join(d, e.name) for e in it if e.name.startswith(sid) and e.name.endswith(".jsonl")]
        except OSError:
            continue
    return newest(hits)


def find_session(sid):
    """The newest ~/.claude/projects/*/<sid>*.jsonl that passes safe(), or None."""
    found = find_sessions(sid)
    return found[0] if found else None


AGENT_FILE = re.compile(r"agent-([A-Za-z0-9_-]+)\.jsonl")


def agents_of(session_path, prefix=None):
    """{agent id: path} of a session's subagents that pass safe(). With a prefix only the matching names are
    looked at, so nothing else is resolved."""
    folder = os.path.join(session_path[:-len(".jsonl")], "subagents")
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return {}
    out = {}
    for n in names:
        m = AGENT_FILE.fullmatch(n)
        if m and (prefix is None or m.group(1).startswith(prefix)):
            p = os.path.join(folder, n)
            if safe(p):
                out[m.group(1)] = p
    return out


def locate(sid, agent=None, listing=False, sessions=None):
    """(transcript path or None, session path or None, agent ids). Raises ValueError for a bad agent.
    Subagent files are only listed when an agent is asked for or the listing is (the path command)."""
    if agent is not None and not AGENT.fullmatch(agent):
        raise ValueError("agent")
    if sessions is None:
        sessions = find_sessions(sid)
    if not sessions:
        return None, None, []
    session = sessions[0]
    if agent is None:
        agents = sorted(agents_of(session))[:MAX_AGENTS] if listing else []
        return safe(session), session, agents
    hits = agents_of(session, prefix=agent)
    first = sorted(hits)[:1]
    agents = sorted(agents_of(session))[:MAX_AGENTS] if listing else []
    return (safe(hits[first[0]]) if first else None), session, agents


def records(path):
    """Parsed records of a transcript, in order, as a generator; returns (generator, truncated). Lines that
    are too long or not JSON are skipped (a long line is never held whole); a huge file is read from its
    tail, dropping the partial first line (a line that starts exactly at the seek point is kept)."""
    try:
        size = os.path.getsize(path)
        f = open(path, "rb")
    except OSError:
        return iter(()), False
    truncated = size > MAX_FILE

    def gen():
        with f:
            try:
                if truncated:
                    # start one byte early: if that byte is the newline ending the previous line, the readline
                    # below eats only that newline and the line at the seek point is kept
                    f.seek(size - TAIL - 1)
                    f.readline(MAX_LINE + 1)
                while True:
                    raw = f.readline(MAX_LINE + 1)
                    if not raw:
                        return
                    if len(raw) > MAX_LINE and not raw.endswith(b"\n"):
                        while True:            # over-long: drop the rest of the line without keeping it
                            rest = f.readline(MAX_LINE)
                            if not rest or rest.endswith(b"\n"):
                                break
                        continue
                    try:
                        rec = json.loads(raw)
                    except (ValueError, RecursionError):
                        continue
                    if isinstance(rec, dict):
                        yield rec
            except OSError:
                return
    return gen(), truncated


def is_prompt(rec):
    """A real user prompt: not a tool result, not a meta or compaction-summary entry, not the synthetic
    "[Request interrupted by user]" record Claude Code writes after Esc."""
    if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isCompactSummary"):
        return False
    msg = rec.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        return bool(content.strip()) and not content.lstrip().startswith(INTERRUPTED)
    if not isinstance(content, list):
        return False
    for b in content:
        if isinstance(b, dict) and b.get("type") == "text":
            t = b.get("text")
            if not (isinstance(t, str) and t.lstrip().startswith(INTERRUPTED)):
                return True
    return False


def num(v):
    """A finite number, else 0 (NaN and Infinity, which Python's json accepts, are not numbers here)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    if isinstance(v, float) and not math.isfinite(v):
        return 0
    return v


def whole(v):
    """num() as an int, clamped to +-MAX_NUM."""
    return max(-MAX_NUM, min(MAX_NUM, int(num(v))))


def short(v, n):
    return v[:n] if isinstance(v, str) else None


class Steps:
    """Folds assistant records into one step per model call (records sharing a message id are the blocks of
    one call). A record with no id at all counts as a call of its own."""

    def __init__(self, sidechain):
        self.sidechain, self.steps, self.by_id, self.anon = sidechain, [], {}, 0

    def add(self, rec):
        if rec.get("type") != "assistant" or (not self.sidechain and rec.get("isSidechain")):
            return
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        key = msg.get("id") or rec.get("requestId") or rec.get("uuid")
        if not isinstance(key, str) or not key:
            self.anon += 1
            key = ("anon", self.anon)
        step = self.by_id.get(key)
        if step is None:
            step = {"ts": short(rec.get("timestamp"), MAX_TS), "think_ms": 0, "thinking": None, "redacted": False,
                    "tokens_in": 0, "tokens_out": 0, "tools": [], "text": False}
            self.by_id[key] = step
            self.steps.append(step)
        usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
        if usage:
            tin = (whole(usage.get("input_tokens")) + whole(usage.get("cache_read_input_tokens"))
                   + whole(usage.get("cache_creation_input_tokens")))
            if tin > 0:                     # a later zero or placeholder usage never erases real counts
                step["tokens_in"] = tin
            step["tokens_out"] = max(step["tokens_out"], whole(usage.get("output_tokens")))
        content = msg.get("content") if isinstance(msg.get("content"), list) else []
        for b in content:
            if not isinstance(b, dict):
                continue
            kind = b.get("type")
            if kind == "thinking":
                step["think_ms"] += whole(rec.get("thinkingDurationMs"))
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


def steps_of(recs, sidechain):
    s = Steps(sidechain)
    for rec in recs:
        s.add(rec)
    return s.steps


def thin(items, limit):
    if len(items) <= limit:
        return items
    keep = {round(i * (len(items) - 1) / (limit - 1)) for i in range(limit)}
    return [x for i, x in enumerate(items) if i in keep]


def scan(recs, sidechain, want=("turn", "context"), truncated=False):
    """One streaming pass over the records feeding the latest-turn view and the whole-file context view
    (whichever are wanted); only the folded steps are kept. Returns {"turn": ..., "context": ...}.
    "partial" is true when a tail read may have lost the start of what is reported."""
    turn_steps, all_steps = Steps(sidechain), Steps(sidechain)
    duration, saw_prompt, compactions = None, False, []
    for rec in recs:
        if "turn" in want and not sidechain and not rec.get("isSidechain") and is_prompt(rec):
            turn_steps, duration, saw_prompt = Steps(sidechain), None, True
            continue
        if "turn" in want:
            turn_steps.add(rec)
        if "context" in want:
            all_steps.add(rec)
        if rec.get("type") != "system":
            continue
        if rec.get("subtype") == "turn_duration":
            duration = whole(rec.get("durationMs"))
        elif rec.get("subtype") == "compact_boundary" and "context" in want:
            meta = rec.get("compactMetadata") if isinstance(rec.get("compactMetadata"), dict) else {}
            compactions.append({"ts": short(rec.get("timestamp"), MAX_TS), "trigger": short(meta.get("trigger"), 20),
                                "pre_tokens": whole(meta.get("preTokens")),
                                "post_tokens": whole(meta.get("postTokens"))})
            del compactions[:-50]
    out = {}
    if "turn" in want:
        steps = turn_steps.steps
        partial = bool(truncated and (sidechain or not saw_prompt))
        out["turn"] = {"duration_ms": duration, "steps": steps[-MAX_STEPS:], "step_count": len(steps),
                       "totals": {"think_ms": sum(s["think_ms"] for s in steps),
                                  "tokens_out": sum(s["tokens_out"] for s in steps),
                                  "tokens_in_last": steps[-1]["tokens_in"] if steps else 0,
                                  "exact": not partial},
                       "partial": partial}
    if "context" in want:
        steps = all_steps.steps
        points = [{"ts": s["ts"], "tokens_in": s["tokens_in"], "tokens_out": s["tokens_out"]} for s in steps]
        out["context"] = {"points": thin(points, MAX_CONTEXT), "point_count": len(points),
                          "peak": max((p["tokens_in"] for p in points), default=0),
                          "compactions": compactions, "partial": bool(truncated)}
    return out


def turn(recs, sidechain, truncated=False):
    """The latest turn: after the last real prompt (the whole file for a subagent or no prompt)."""
    return scan(recs, sidechain, ("turn",), truncated)["turn"]


def context(recs, sidechain, truncated=False):
    return scan(recs, sidechain, ("context",), truncated)["context"]


def cap(result):
    """Keep the JSON under MAX_OUTPUT. Every stage strictly shrinks the result, so it always terminates: drop
    the reasoning text, then the oldest half of the steps or points (a lone one goes), then compactions and
    agents, and as a last resort the whole body. Strings are bounded where they are built."""
    def fits():
        return len(json.dumps(result)) <= MAX_OUTPUT
    if fits():
        return result
    result["capped"] = True
    body = result.get("turn") or result.get("context")
    if isinstance(body, dict):
        for s in body.get("steps", ()):
            s["thinking"] = None
        key = "steps" if "steps" in body else "points"
        while not fits() and body.get(key):
            items = body[key]
            body[key] = items[max(1, len(items) // 2):]
        if not fits():
            body["compactions"] = []
    if not fits() and isinstance(result.get("agents"), list):
        result["agents"] = []
    if not fits():
        for k in ("turn", "context"):
            result.pop(k, None)
    return result


def run(cmd, sid, agent=None):
    """Raises ValueError for bad arguments, before any file is touched."""
    if cmd not in ("turn", "context", "path"):
        raise ValueError("cmd")
    if not (isinstance(sid, str) and SID.fullmatch(sid)):
        raise ValueError("sid")
    if agent is not None and not (isinstance(agent, str) and AGENT.fullmatch(agent)):
        raise ValueError("agent")
    sessions = find_sessions(sid)
    path, session, agents = locate(sid, agent, listing=(cmd == "path"), sessions=sessions)
    out = {"sid": sid, "agent": agent, "found": bool(path)}
    if len({os.path.basename(p) for p in sessions}) > 1:
        out["ambiguous"] = True        # the 8-character prefix matches several sessions; the newest was used
    if cmd == "path":
        out.update(path=path, session=session, agents=agents)
        return cap(out)
    if not path:
        out["agents"] = agents
        return out
    recs, truncated = records(path)
    out["path"] = path
    out["truncated"] = truncated
    key = "turn" if cmd == "turn" else "context"
    out.update(scan(recs, agent is not None, (key,), truncated))
    return cap(out)


def main(argv):
    if len(argv) in (2, 3) and argv[0] in ("turn", "context", "path") and SID.fullmatch(argv[1]) \
            and (len(argv) == 2 or AGENT.fullmatch(argv[2])):
        agent = argv[2] if len(argv) == 3 else None
        try:
            out = run(argv[0], argv[1], agent)
        except ValueError:
            pass
        except Exception:      # RecursionError, MemoryError, odd data: answered, never a traceback
            out = {"sid": argv[1], "agent": agent, "found": False, "error": "unreadable"}
            print(json.dumps(out))
            return 0
        else:
            print(json.dumps(out))
            return 0
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
