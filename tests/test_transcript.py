"""tools/transcript.py: reading a transcript at click time. Everything runs in a temporary fake home."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "transcript.py")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import openable  # noqa: E402

_loader = importlib.machinery.SourceFileLoader("transcript", TOOL)
_spec = importlib.util.spec_from_loader("transcript", _loader)
transcript = importlib.util.module_from_spec(_spec)
_loader.exec_module(transcript)

SID = "abcd1234"
FULL = SID + "-0000-4000-8000-000000000000"


def prompt(text="hi", **extra):
    return {"type": "user", "message": {"role": "user", "content": text}, **extra}


def result():
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "x"}]}}


def call(mid, blocks, tin=2, cache=100, out=10, think_ms=None, **extra):
    """One model call, written as Claude Code does: one record per content block, same message id."""
    recs = []
    for i, b in enumerate(blocks):
        rec = {"type": "assistant", "timestamp": f"2026-01-01T00:00:{i:02d}Z", "apiBlockIndex": i,
               "message": {"id": mid, "role": "assistant", "content": [b],
                           "usage": {"input_tokens": tin, "cache_read_input_tokens": cache,
                                     "cache_creation_input_tokens": 5, "output_tokens": out}}, **extra}
        if b["type"] == "thinking" and think_ms is not None:
            rec["thinkingDurationMs"] = think_ms
        recs.append(rec)
    return recs


def thinking(text=""):
    return {"type": "thinking", "thinking": text, "signature": "sig"}


def tool(name):
    return {"type": "tool_use", "id": "t", "name": name, "input": {}}


def write(path, recs, raw=()):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
        for line in raw:
            f.write(line + "\n")
    return path


class World(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.saved = openable.HOME
        openable.HOME = self.home
        self.saved_env = os.environ.get("CLAUDE_STRIP_DIR")
        os.environ["CLAUDE_STRIP_DIR"] = os.path.join(self.home, "strip")
        self.proj = os.path.join(self.home, ".claude", "projects", "-home-u-proj")
        self.main = os.path.join(self.proj, FULL + ".jsonl")

    def tearDown(self):
        openable.HOME = self.saved
        if self.saved_env is None:
            os.environ.pop("CLAUDE_STRIP_DIR", None)
        else:
            os.environ["CLAUDE_STRIP_DIR"] = self.saved_env
        self.tmp.cleanup()

    def session(self, recs, **kw):
        return write(self.main, recs, **kw)


class Turn(World):
    def test_the_latest_turn_has_one_step_per_model_call(self):
        self.session([
            prompt("old"), *call("m0", [tool("Old")]),
            prompt("new"),
            *call("m1", [thinking("plan it"), {"type": "text", "text": "ok"}, tool("Read"), tool("Bash")], think_ms=1500, out=30),
            result(),
            *call("m2", [tool("Edit")], tin=3, out=7),
            {"type": "system", "subtype": "turn_duration", "durationMs": 4200},
        ])
        out = transcript.run("turn", SID)
        t = out["turn"]
        self.assertTrue(out["found"])
        self.assertEqual(t["step_count"], 2)
        self.assertEqual(t["duration_ms"], 4200)
        first, second = t["steps"]
        self.assertEqual(first["think_ms"], 1500)
        self.assertEqual(first["thinking"], "plan it")
        self.assertFalse(first["redacted"])
        self.assertEqual(first["tools"], ["Read", "Bash"])
        self.assertTrue(first["text"])
        self.assertEqual((first["tokens_in"], first["tokens_out"]), (107, 30))
        self.assertEqual(second["tools"], ["Edit"])
        self.assertEqual(t["totals"]["tokens_out"], 37)

    def test_empty_thinking_is_redacted_not_an_error(self):
        self.session([prompt(), *call("m1", [thinking(""), tool("Read")], think_ms=900)])
        step = transcript.run("turn", SID)["turn"]["steps"][0]
        self.assertIsNone(step["thinking"])
        self.assertTrue(step["redacted"])
        self.assertEqual(step["think_ms"], 900)

    def test_long_reasoning_is_cut(self):
        self.session([prompt(), *call("m1", [thinking("x" * 5000)])])
        step = transcript.run("turn", SID)["turn"]["steps"][0]
        self.assertEqual(len(step["thinking"]), transcript.MAX_REASONING)

    def test_sidechain_records_in_the_main_file_are_ignored(self):
        self.session([prompt(), *call("m1", [tool("Read")]), *call("s1", [tool("Grep")], isSidechain=True),
                      prompt("side", isSidechain=True)])
        t = transcript.run("turn", SID)["turn"]
        self.assertEqual([s["tools"] for s in t["steps"]], [["Read"]])

    def test_meta_and_compaction_summaries_do_not_start_a_turn(self):
        self.session([prompt(), *call("m1", [tool("Read")]), prompt("ctx", isMeta=True),
                      prompt("summary", isCompactSummary=True), *call("m2", [tool("Edit")])])
        self.assertEqual(transcript.run("turn", SID)["turn"]["step_count"], 2)

    def test_bad_lines_are_skipped(self):
        self.session([prompt(), *call("m1", [tool("Read")])], raw=["{not json", "[1,2]", ""])
        self.assertEqual(transcript.run("turn", SID)["turn"]["step_count"], 1)

    def test_steps_and_output_are_capped(self):
        recs = [prompt()]
        for i in range(200):
            recs += call(f"m{i}", [thinking("y" * 400), tool("T" * 80)] + [tool("t")] * 30)
        self.session(recs)
        out = transcript.run("turn", SID)
        self.assertEqual(out["turn"]["step_count"], 200)
        self.assertLessEqual(len(out["turn"]["steps"]), transcript.MAX_STEPS)
        self.assertTrue(all(len(s["tools"]) <= transcript.MAX_TOOLS for s in out["turn"]["steps"]))
        self.assertLessEqual(len(json.dumps(out)), transcript.MAX_OUTPUT)

    def test_a_prompt_only_transcript_has_no_steps(self):
        self.session([prompt()])
        t = transcript.run("turn", SID)["turn"]
        self.assertEqual((t["steps"], t["step_count"], t["totals"]["tokens_in_last"]), ([], 0, 0))


class Context(World):
    def test_tokens_per_step_and_compactions(self):
        boundary = {"type": "system", "subtype": "compact_boundary", "timestamp": "t",
                    "compactMetadata": {"trigger": "auto", "preTokens": 500000, "postTokens": 20000,
                                        "preservedMessages": {"uuids": ["secret-list"]}}}
        self.session([prompt(), *call("m1", [tool("a")], cache=1000), *call("m2", [tool("b")], cache=5000),
                      boundary, prompt("again", isCompactSummary=True), *call("m3", [tool("c")], cache=300)])
        c = transcript.run("context", SID)["context"]
        self.assertEqual([p["tokens_in"] for p in c["points"]], [1007, 5007, 307])
        self.assertEqual(c["peak"], 5007)
        self.assertEqual(c["compactions"], [{"ts": "t", "trigger": "auto", "pre_tokens": 500000, "post_tokens": 20000}])

    def test_points_are_thinned_but_keep_the_ends(self):
        recs = [prompt()]
        for i in range(1000):
            recs += call(f"m{i}", [tool("a")], cache=i)
        self.session(recs)
        c = transcript.run("context", SID)["context"]
        self.assertEqual(c["point_count"], 1000)
        self.assertLessEqual(len(c["points"]), transcript.MAX_CONTEXT)
        self.assertEqual((c["points"][0]["tokens_in"], c["points"][-1]["tokens_in"]), (7, 1006))

    def test_no_compactions_is_an_empty_list(self):
        self.session([prompt(), *call("m1", [tool("a")])])
        self.assertEqual(transcript.run("context", SID)["context"]["compactions"], [])


class Finding(World):
    def test_a_missing_transcript_is_found_false(self):
        os.makedirs(self.proj)
        for cmd in ("turn", "context", "path"):
            out = transcript.run(cmd, SID)
            self.assertFalse(out["found"])
        self.assertIsNone(transcript.run("path", SID)["path"])

    def test_no_projects_folder_at_all(self):
        self.assertFalse(transcript.run("turn", SID)["found"])

    def test_path_names_the_session_file_and_its_subagents(self):
        self.session([prompt()])
        sub = os.path.join(self.proj, FULL, "subagents", "agent-a1b2c3.jsonl")
        write(sub, [prompt("p", isSidechain=True)])
        out = transcript.run("path", SID)
        self.assertEqual(out["path"], self.main)
        self.assertEqual(out["agents"], ["a1b2c3"])
        self.assertEqual(transcript.run("path", SID, "a1b2")["path"], sub)
        self.assertFalse(transcript.run("path", SID, "zzzz")["found"])

    def test_a_subagent_transcript_is_all_sidechain_and_still_read(self):
        self.session([prompt()])
        sub = os.path.join(self.proj, FULL, "subagents", "agent-a1b2c3.jsonl")
        write(sub, [prompt("task", isSidechain=True), *call("s1", [tool("Grep")], isSidechain=True)])
        t = transcript.run("turn", SID, "a1b2c3")["turn"]
        self.assertEqual([s["tools"] for s in t["steps"]], [["Grep"]])

    def test_the_newest_of_several_projects_wins_unless_the_folder_is_known(self):
        other = os.path.join(self.home, ".claude", "projects", "-home-u-other", FULL + ".jsonl")
        self.session([prompt()])
        write(other, [prompt()])
        os.utime(self.main, (1, 1))
        self.assertEqual(transcript.find_session(SID), other)
        os.makedirs(os.environ["CLAUDE_STRIP_DIR"])
        with open(os.path.join(os.environ["CLAUDE_STRIP_DIR"], "s.json"), "w") as f:
            json.dump({"sessionId": FULL, "cwd": "/home/u/proj", "updatedAt": 1}, f)
        self.assertEqual(transcript.find_session(SID), self.main)

    def test_a_symlink_out_of_projects_is_refused(self):
        outside = write(os.path.join(self.home, "elsewhere", "secret.jsonl"), [prompt("x")])
        os.makedirs(self.proj)
        os.symlink(outside, self.main)
        self.assertFalse(transcript.run("turn", SID)["found"])
        self.assertIsNone(transcript.safe(outside))

    def test_a_symlinked_subagents_folder_out_is_refused(self):
        self.session([prompt()])
        outside = write(os.path.join(self.home, "elsewhere", "agent-evil.jsonl"), [prompt("x")])
        os.makedirs(os.path.join(self.proj, FULL))
        os.symlink(os.path.dirname(outside), os.path.join(self.proj, FULL, "subagents"))
        self.assertEqual(transcript.run("path", SID)["agents"], [])

    def test_bad_ids_are_rejected(self):
        self.assertIsNone(transcript.find_session("../../et"))
        with self.assertRaises(ValueError):
            transcript.run("path", SID, "../x")

    def test_a_transcript_over_the_size_cap_is_read_from_its_tail(self):
        saved = (transcript.MAX_FILE, transcript.TAIL)
        transcript.MAX_FILE, transcript.TAIL = 2000, 1500
        try:
            recs = [prompt()]
            for i in range(40):
                recs += call(f"m{i}", [tool("a")])
            self.session(recs)
            out = transcript.run("context", SID)
            self.assertTrue(out["truncated"])
            self.assertLess(out["context"]["point_count"], 40)
        finally:
            transcript.MAX_FILE, transcript.TAIL = saved


class Cli(World):
    def run_cli(self, *args):
        env = dict(os.environ, HOME=self.home)
        return subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True, env=env)

    def test_prints_json_and_writes_nothing(self):
        self.session([prompt(), *call("m1", [tool("Read")])])
        before = sorted(os.walk(self.home))
        p = self.run_cli("turn", SID)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["turn"]["steps"][0]["tools"], ["Read"])
        self.assertEqual(sorted(os.walk(self.home)), before)

    def test_missing_transcript_still_exits_zero(self):
        p = self.run_cli("path", SID)
        self.assertEqual(p.returncode, 0)
        self.assertFalse(json.loads(p.stdout)["found"])

    def test_bad_arguments_exit_two(self):
        for args in ([], ["turn"], ["turn", "short"], ["nope", SID], ["path", SID, "../x"], ["turn", SID, "a", "b"]):
            self.assertEqual(self.run_cli(*args).returncode, 2, args)


if __name__ == "__main__":
    unittest.main()
