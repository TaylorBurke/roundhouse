import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "strip_state.py")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import strip_state  # noqa: E402

ME = os.getpid()


def write(folder, name, **fields):
    body = {"pid": ME, "project": "proj", "task": "doing a thing", "phase": "working", "running": 2,
            "context": 40, "updatedAt": 1000, "sessionId": "ab12cd34-aaaa-bbbb", **fields}
    body = {k: v for k, v in body.items() if v is not None}
    with open(os.path.join(folder, name), "w") as f:
        json.dump(body, f)


class ReadStates(unittest.TestCase):
    def test_joins_on_the_first_eight_characters(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, f"{ME}.json")
            got = strip_state.read_states(d)
            self.assertEqual(list(got), ["ab12cd34"])
            self.assertEqual(got["ab12cd34"], {"project": "proj", "task": "doing a thing", "phase": "working",
                                              "running": 2, "context": 40, "pid": ME, "cwd": ""})

    def test_the_sessions_folder_is_passed_on_only_when_it_is_an_absolute_path(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "a.json", cwd="/home/ww/Work/dev/proj")
            self.assertEqual(strip_state.read_states(d)["ab12cd34"]["cwd"], "/home/ww/Work/dev/proj")
        for bad in ("relative/dir", "", "/x\nevil", "/" + "a" * 500, 5, None, ["/x"]):
            with tempfile.TemporaryDirectory() as d:
                write(d, "a.json", cwd=bad)
                self.assertEqual(strip_state.read_states(d)["ab12cd34"]["cwd"], "", bad)

    def test_skips_what_cannot_be_used(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "a.json", sessionId=None)                         # an older mod: no session id
            write(d, "b.json", sessionId="short")                      # not an id
            write(d, "c.json", phase="ended")                          # over
            write(d, "d.json", pid=2 ** 22 + 12345)                    # no such process
            with open(os.path.join(d, "e.json"), "w") as f:
                f.write("{broken")
            with open(os.path.join(d, "drag-0xabc.pending"), "w") as f:
                f.write("1")
            self.assertEqual(strip_state.read_states(d), {})

    def test_values_are_clamped_and_cleaned(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "a.json", phase="exploding", running=-3, context=250, task="x\x1b[31m red\n" + "y" * 400, project=5)
            s = strip_state.read_states(d)["ab12cd34"]
            self.assertEqual((s["phase"], s["running"], s["context"], s["project"]), ("idle", 0, -1, ""))
            self.assertNotIn("\x1b", s["task"])
            self.assertNotIn("\n", s["task"])
            self.assertEqual(len(s["task"]), 240)

    def test_the_newer_of_two_files_wins(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "old.json", task="old", updatedAt=1000)
            write(d, "new.json", task="new", updatedAt=2000)
            self.assertEqual(strip_state.read_states(d)["ab12cd34"]["task"], "new")


class Address(unittest.TestCase):
    def test_walks_up_to_the_terminal_window(self):
        parent = strip_state.parent_of(ME)
        self.assertGreater(parent, 1)
        self.assertEqual(strip_state.window_address(ME, {parent: {"address": "0x55aa11"}}), "0x55aa11")
        self.assertIsNone(strip_state.window_address(ME, {}))

    def test_the_terminals_workspace_is_found_the_same_way(self):
        parent = strip_state.parent_of(ME)
        self.assertEqual(strip_state.window_workspace(ME, {parent: {"workspace": {"id": 12}}}), 12)
        self.assertIsNone(strip_state.window_workspace(ME, {}))

    def test_a_special_or_odd_workspace_is_none(self):
        for bad in ({"id": -98}, {"id": 0}, {"id": "3"}, {"id": True}, {"id": None}, {}, None, 7):
            self.assertIsNone(strip_state.window_workspace(ME, {ME: {"workspace": bad}}), bad)

    def test_a_malformed_address_is_dropped(self):
        for bad in ("0xZZ", "address:0x1", "0x1; do-something", "", 5, None):
            self.assertIsNone(strip_state.window_address(ME, {ME: {"address": bad}}), bad)


class Command(unittest.TestCase):
    def test_prints_json_and_never_fails(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, f"{ME}.json")
            run = subprocess.run([TOOL], env={**os.environ, "CLAUDE_STRIP_DIR": d}, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0)
            self.assertIn("ab12cd34", json.loads(run.stdout))
        run = subprocess.run([TOOL], env={**os.environ, "CLAUDE_STRIP_DIR": "/nonexistent/dir"}, capture_output=True, text=True)
        self.assertEqual((run.returncode, json.loads(run.stdout)), (0, {}))


if __name__ == "__main__":
    unittest.main()
