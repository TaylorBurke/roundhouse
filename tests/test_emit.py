"""Run with:  python3 -m unittest discover -s tests"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMIT = os.path.join(ROOT, "hooks", "emit.py")
sys.path.insert(0, os.path.join(ROOT, "hooks"))
import emit  # noqa: E402

SECRET = "hunter2-SECRET-do-not-log"


class Classify(unittest.TestCase):
    def test_files(self):
        self.assertEqual(emit.classify("Read", {"file_path": "/home/u/proj/src/auth/tokens.ts"}), ("files", "auth/tokens.ts"))
        self.assertEqual(emit.classify("Grep", {"pattern": SECRET}), ("files", "Grep"))

    def test_memory_folder(self):
        path = "/home/u/.claude/projects/-home-u-Work/memory/MEMORY.md"
        self.assertEqual(emit.classify("Read", {"file_path": path}), ("memory", "memory/MEMORY.md"))
        self.assertEqual(emit.classify("Bash", {"command": f"cat {path}"})[0], "memory")

    def test_shell_kinds(self):
        cases = {
            "npm test": "shell",
            "cat a.txt | grep foo 2>&1": "files",
            "cd /tmp && ls -la": "files",
            "FOO=1 sudo sed -i s/a/b/ x.txt": "files",
            "curl -s https://example.com/x?token=abc": "network",
            "git push origin main": "network",
            "git status": "shell",
            "echo $(curl -s https://example.com)": "network",
            "/usr/bin/gh pr list": "network",
            "python3 script.py": "shell",
            "ls; python3 x.py": "shell",
            "": "shell",
        }
        for command, station in cases.items():
            self.assertEqual(emit.classify("Bash", {"command": command})[0], station, command)

    def test_shell_label_is_name_or_description(self):
        self.assertEqual(emit.classify("Bash", {"command": f"curl -H 'Authorization: {SECRET}' https://x.io"})[1], "curl")
        self.assertEqual(emit.classify("Bash", {"command": "npm test", "description": "Run tests"})[1], "Run tests")
        self.assertEqual(emit.classify("Bash", {"command": f"/opt/my tools/run.sh {SECRET}"})[1], "my")

    def test_urls_become_hosts(self):
        url = f"https://user:{SECRET}@docs.example.com:8443/path/{SECRET}?q={SECRET}#frag"
        self.assertEqual(emit.classify("WebFetch", {"url": url}), ("network", "docs.example.com"))
        self.assertEqual(emit.classify("WebFetch", {"url": "not a url at all"}), ("network", "web fetch"))
        self.assertEqual(emit.classify("WebSearch", {"query": SECRET}), ("network", "web search"))

    def test_other_tools(self):
        self.assertEqual(emit.classify("Agent", {"description": "Explore tests", "prompt": SECRET}), ("agents", "Explore tests"))
        self.assertEqual(emit.classify("Skill", {"skill": "code-review", "args": SECRET}), ("skills", "code-review"))
        self.assertEqual(emit.classify("ToolSearch", {"query": SECRET}), ("skills", "loading tools"))
        self.assertEqual(emit.classify("AskUserQuestion", {"questions": [SECRET]})[0], "you")
        self.assertEqual(emit.classify("mcp__claude-in-chrome__navigate", {"url": "https://a.example.org/p?x=1"}), ("browser", "a.example.org"))
        self.assertEqual(emit.classify("mcp__plugin_ecc_chrome-devtools__click", {"uid": "1"}), ("browser", "click"))
        self.assertEqual(emit.classify("mcp__claude_ai_Gmail__search_threads", {"query": SECRET}), ("network", "claude_ai_Gmail: search threads"))
        self.assertEqual(emit.classify("SomethingNew", {"x": SECRET}), ("shell", "SomethingNew"))

    def test_clean(self):
        self.assertEqual(emit.clean("a\x1b[31mb‮c\n\td"), "a [31mb c d")
        self.assertEqual(len(emit.clean("x" * 500)), emit.LABEL_MAX)


class EndToEnd(unittest.TestCase):
    """The script as Claude Code runs it: payload on stdin, lines in the log."""

    def run_hook(self, payload, folder, raw=None):
        env = {**os.environ, "LOT_MAP_DIR": folder}
        done = subprocess.run([sys.executable, "-I", EMIT], input=raw if raw is not None else json.dumps(payload),
                              capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
        path = os.path.join(folder, "events.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f]

    def test_tool_events_carry_no_content(self):
        with tempfile.TemporaryDirectory() as folder:
            base = {"session_id": "0123abcd-ffff", "cwd": "/home/u/secret-project", "transcript_path": "/nowhere.jsonl"}
            self.run_hook({**base, "hook_event_name": "UserPromptSubmit", "prompt": f"please use {SECRET}"}, folder)
            self.run_hook({**base, "hook_event_name": "PreToolUse", "tool_name": "Write", "tool_use_id": "toolu_1",
                           "tool_input": {"file_path": "/home/u/p/src/a.py", "content": SECRET}}, folder)
            self.run_hook({**base, "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_2",
                           "tool_input": {"command": f"./deploy --key {SECRET}", "run_in_background": True},
                           "tool_response": {"stdout": SECRET, "backgroundTaskId": "bash_7"}, "duration_ms": 41.7}, folder)
            self.run_hook({**base, "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": "toolu_3",
                           "tool_input": {"command": "npm test"}, "error": f"Exit code 1\n{SECRET}", "is_interrupt": False}, folder)
            events = self.run_hook({**base, "hook_event_name": "Stop", "last_assistant_message": SECRET,
                                    "background_tasks": [{"id": "bash_7", "type": "shell", "status": "running",
                                                          "command": SECRET, "description": SECRET}]}, folder)
            self.assertEqual([e["ev"] for e in events], ["prompt", "tool_start", "tool_end", "tool_end", "stop"])
            self.assertEqual(events[1]["label"], "src/a.py")
            self.assertEqual((events[2]["task"], events[2]["ms"], events[2]["label"]), ("bash_7", 41, "deploy"))
            self.assertEqual(events[3]["status"], "err")
            self.assertEqual(events[4]["bg"], [{"id": "bash_7", "type": "shell", "status": "running"}])
            self.assertTrue(all(e["sid"] == "0123abcd" and e["v"] == 1 for e in events))
            with open(os.path.join(folder, "events.jsonl")) as f:
                self.assertNotIn(SECRET, f.read())
            self.assertEqual(os.stat(os.path.join(folder, "events.jsonl")).st_mode & 0o777, 0o600)

    def test_task_notification_is_not_a_prompt(self):
        with tempfile.TemporaryDirectory() as folder:
            prompt = f"<task-notification><task-id>bash_7</task-id><status>failed</status><summary>{SECRET}</summary></task-notification>"
            events = self.run_hook({"session_id": "s", "hook_event_name": "UserPromptSubmit", "prompt": prompt}, folder)
            self.assertEqual((events[0]["ev"], events[0]["task"], events[0]["status"]), ("task_end", "bash_7", "err"))

    def test_bad_input_is_silent(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.run_hook(None, folder, raw="not json {"), [])
            self.assertEqual(self.run_hook(None, folder, raw="[1,2]"), [])
            self.assertEqual(self.run_hook({"hook_event_name": "SomethingElse"}, folder), [])

    def test_context_from_transcript(self):
        home = os.path.expanduser("~/.claude")
        if not os.path.isdir(home):
            self.skipTest("no ~/.claude")
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", dir=home, delete=True) as t:
            t.write(json.dumps({"message": {"role": "user", "content": SECRET}}) + "\n")
            t.write(json.dumps({"message": {"model": "claude-x-1", "content": SECRET, "usage": {
                "input_tokens": 4, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 96, "output_tokens": 50}}}) + "\n")
            t.write(json.dumps({"isSidechain": True, "message": {"model": "claude-sub", "usage": {"input_tokens": 9}}}) + "\n")
            t.flush()
            self.assertEqual(emit.context_of(t.name), {"tokens": 1100, "model": "claude-x-1"})
        self.assertIsNone(emit.context_of("/etc/passwd"))

    def test_log_is_cut_back(self):
        with tempfile.TemporaryDirectory() as folder:
            os.environ["LOT_MAP_DIR"] = folder
            try:
                path = os.path.join(folder, "events.jsonl")
                with open(path, "w") as f:
                    f.write('{"ev":"old"}\n' * (emit.MAX_LOG_BYTES // 13 + 10))
                emit.append([{"ev": "new"}])
                with open(path) as f:
                    lines = f.read().splitlines()
                self.assertEqual(len(lines), emit.KEEP_LINES + 1)
                self.assertEqual(json.loads(lines[-1]), {"ev": "new"})
                self.assertTrue(all(json.loads(line) for line in lines))
            finally:
                del os.environ["LOT_MAP_DIR"]


if __name__ == "__main__":
    unittest.main()
