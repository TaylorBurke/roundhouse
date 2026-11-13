import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "windows.py")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import windows  # noqa: E402


def run(folder, *args):
    env = {**os.environ, "LOT_MAP_DIR": folder}
    return subprocess.run([TOOL, *args], env=env, capture_output=True, text=True)


class Pure(unittest.TestCase):
    def test_show_hide_toggle(self):
        e = windows.show([], "*")
        self.assertEqual(e, [{"id": "all", "sid": "*"}])
        e = windows.show(e, "ab12cd34")
        e = windows.show(e, "ef56ab78")
        self.assertEqual([x["id"] for x in e], ["all", "w1", "w2"])
        self.assertEqual(windows.show(e, "ab12cd34"), e)            # already shown
        e = windows.hide(e, "ab12cd34")
        self.assertEqual([x["sid"] for x in e], ["*", "ef56ab78"])
        e = windows.show(e, "11111111")
        self.assertEqual([x["id"] for x in e], ["all", "w2", "w1"])  # the freed id is reused
        self.assertEqual(windows.toggle(e, "11111111"), windows.hide(e, "11111111"))
        self.assertEqual([x["sid"] for x in windows.toggle([], "zz")], ["zz"])

    def test_rebind_keeps_the_window(self):
        e = [{"id": "all", "sid": "*"}, {"id": "w1", "sid": "old00000"}]
        e2 = windows.rebind(e, "old00000", "new00000")
        self.assertEqual(e2, [{"id": "all", "sid": "*"}, {"id": "w1", "sid": "new00000"}])
        self.assertEqual(windows.rebind(e, "nothere", "new00000"), e)      # no window for it: nothing
        self.assertEqual(windows.rebind(e, "old00000", "old00000"), e)
        both = [{"id": "w1", "sid": "a"}, {"id": "w2", "sid": "b"}]
        self.assertEqual(windows.rebind(both, "a", "b"), [{"id": "w2", "sid": "b"}])  # NEW had one: drop OLD's

    def test_norm(self):
        self.assertEqual(windows.norm("*"), "*")
        self.assertEqual(windows.norm("0123456789abcdef"), "01234567")
        for bad in ("", "a b", "../x", "a;b", "x" * 65):
            with self.assertRaises(ValueError):
                windows.norm(bad)


class Command(unittest.TestCase):
    def test_round_trip_and_file(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(run(d).stdout.strip(), "*")                      # no argument: the all window
            self.assertEqual(run(d, "toggle", "ab12cd34ef").stdout.strip(), "* ab12cd34")
            with open(os.path.join(d, "windows.json")) as f:
                self.assertEqual(json.load(f), {"shown": [{"id": "all", "sid": "*"}, {"id": "w1", "sid": "ab12cd34"}]})
            self.assertEqual(run(d, "rebind", "ab12cd34", "99999999").stdout.strip(), "* 99999999")
            self.assertEqual(run(d, "hide", "*").stdout.strip(), "99999999")
            self.assertEqual(run(d, "hide", "99999999").stdout.strip(), "")
            self.assertEqual(oct(os.stat(os.path.join(d, "windows.json")).st_mode & 0o777), "0o600")

    def test_bad_input_is_refused_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            for args in (["show", "a b"], ["rebind", "x"], ["frobnicate"], ["show", "a", "b"]):
                r = run(d, *args)
                self.assertEqual((r.returncode, r.stdout), (2, ""), args)
            self.assertFalse(os.path.exists(os.path.join(d, "windows.json")))

    def test_damaged_file_counts_as_empty(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "windows.json"), "w") as f:
                f.write("{not json")
            self.assertEqual(run(d, "show", "abcd1234").stdout.strip(), "abcd1234")

    def test_list(self):
        with tempfile.TemporaryDirectory() as d:
            now = __import__("time").time()
            with open(os.path.join(d, "events.jsonl"), "w") as f:
                for e in ({"sid": "aaaa1111", "ts": now - 100, "ev": "session", "dir": "alpha"},
                          {"sid": "bbbb2222", "ts": now - 50, "ev": "session", "dir": "beta"},
                          {"sid": "bbbb2222", "ts": now - 40, "ev": "session_end"}):
                    f.write(json.dumps(e) + "\n")
            run(d, "show", "aaaa1111")
            lines = run(d, "list").stdout.splitlines()
            self.assertEqual(len(lines), 2)
            self.assertTrue(lines[0].startswith("aaaa1111  alpha") and lines[0].endswith("window"))
            self.assertIn("ended", lines[1])


if __name__ == "__main__":
    unittest.main()
