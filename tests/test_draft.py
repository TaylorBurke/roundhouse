"""tools/draft.py: what is typed, and every way it refuses. No desktop is touched: a fake `hyprctl` and a
fake `wtype` on PATH stand in for the real ones (the real wtype is never run)."""
import os
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "draft.py")
ADDR = "0x55aa11"

# `dispatch` makes the window in $FAKE_FOCUS_TO active (default: the one asked for); `activewindow -j`
# prints the active window's address from the state file. Every call is logged.
HYPRCTL = """#!/bin/sh
echo "$@" >> "$FAKE_DIR/hyprctl.log"
if [ "$1" = dispatch ]; then
  if [ -n "$FAKE_FOCUS_TO" ]; then echo "$FAKE_FOCUS_TO" > "$FAKE_DIR/active"; fi
  exit 0
fi
if [ "$1" = activewindow ]; then
  printf '{"address": "%s", "class": "x"}\\n' "$(cat "$FAKE_DIR/active")"
fi
"""
# one line per argument, so the log shows exactly what the argv was
WTYPE = """#!/bin/sh
for a in "$@"; do printf '%s\\n' "$a" >> "$FAKE_DIR/wtype.log"; done
echo --end-- >> "$FAKE_DIR/wtype.log"
exit "${FAKE_WTYPE_RC:-0}"
"""


class DraftTool(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.bin = os.path.join(self.dir, "bin")
        os.mkdir(self.bin)
        self.addCleanup(self._tmp.cleanup)
        self.fake("hyprctl", HYPRCTL)
        self.fake("wtype", WTYPE)
        self.set_active("0x1")

    def fake(self, name, body):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)

    def set_active(self, addr):
        with open(os.path.join(self.dir, "active"), "w") as f:
            f.write(addr)

    def run_tool(self, *args, focus_to=ADDR, path=None, wtype_rc=None):
        env = {"PATH": path if path is not None else self.bin + ":/usr/bin:/bin", "FAKE_DIR": self.dir}
        if focus_to:
            env["FAKE_FOCUS_TO"] = focus_to
        if wtype_rc is not None:
            env["FAKE_WTYPE_RC"] = str(wtype_rc)
        return subprocess.run([sys.executable, "-I", TOOL, *args], env=env, capture_output=True, text=True, timeout=20)

    def log(self, name):
        p = os.path.join(self.dir, name)
        return open(p).read().splitlines() if os.path.exists(p) else []

    def test_types_the_text_as_one_argument_after_double_dash(self):
        r = self.run_tool("type", ADDR, "Why did Bash: ls fail?")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertEqual(self.log("wtype.log"), ["--", "Why did Bash: ls fail?", "--end--"])

    def test_it_focuses_the_asked_window_first(self):
        self.run_tool("type", ADDR, "continue")
        self.assertIn("dispatch hl.dsp.focus({ window = 'address:%s' })" % ADDR, self.log("hyprctl.log"))

    def test_only_text_is_typed_no_other_key(self):
        # the only wtype call has `--` and the text: no -k, no -P, no newline
        self.run_tool("type", ADDR, "continue")
        argv = self.log("wtype.log")[:-1]
        self.assertEqual(argv, ["--", "continue"])

    def test_hostile_text_is_passed_whole_never_to_a_shell(self):
        for text in ("$(touch pwned)", "; rm -rf ~", "`id`", "-k Return", "--help", "a 'quote\" and \\ back", "x && y | z"):
            os.path.exists(os.path.join(self.dir, "wtype.log")) and os.remove(os.path.join(self.dir, "wtype.log"))
            r = self.run_tool("type", ADDR, text)
            self.assertEqual(r.returncode, 0, text)
            self.assertEqual(self.log("wtype.log"), ["--", text, "--end--"], text)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "pwned")))

    def test_control_characters_and_line_breaks_are_refused(self):
        for text in ("a\nb", "a\rb", "a\x1bb", "a\tb", "a\x7fb", "a\x85b", "a\u2028b", "a\u2029b", "\n", "tail\n",
                     "a\u202eb", "a\u200bb", "a\ufeffb", "a\ue000b", "a\u2066b"):    # bidi override, zero-width, BOM, private use, isolate
            r = self.run_tool("type", ADDR, text)
            self.assertEqual(r.returncode, 1, repr(text))
            self.assertIn("not typed", r.stderr)
        self.assertEqual(self.log("wtype.log"), [])

    def test_emoji_and_other_text_is_accepted_and_counted_in_code_points(self):
        self.assertEqual(self.run_tool("type", ADDR, "ok \U0001f600 é中").returncode, 0)
        self.assertEqual(self.run_tool("type", ADDR, "\U0001f600" * 300).returncode, 0)
        self.assertEqual(self.run_tool("type", ADDR, "\U0001f600" * 301).returncode, 1)

    def test_the_active_window_is_checked_again_right_before_typing(self):
        # the first look says the terminal, every later one says another window
        self.fake("hyprctl", HYPRCTL.replace('if [ "$1" = activewindow ]; then',
                                             'if [ "$1" = activewindow ]; then n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_DIR/n"; [ $n -ge 1 ] && echo 0x999 > "$FAKE_DIR/active"; '))
        r = self.run_tool("type", ADDR, "continue")
        self.assertEqual(r.returncode, 1)
        self.assertIn("changed", r.stderr)
        self.assertEqual(self.log("wtype.log"), [])

    def test_empty_and_too_long_are_refused(self):
        self.assertEqual(self.run_tool("type", ADDR, "").returncode, 1)
        self.assertEqual(self.run_tool("type", ADDR, "x" * 301).returncode, 1)
        self.assertEqual(self.log("wtype.log"), [])
        self.assertEqual(self.run_tool("type", ADDR, "x" * 300).returncode, 0)

    def test_a_bad_address_is_refused_before_anything_runs(self):
        for a in ("", "55aa11", "0x", "0xZZ", "0X55AA", "0x55AA11", "0x55 aa", "0x55aa11; id", "address:0x55aa11", "0x55aa11\n"):
            r = self.run_tool("type", a, "continue")
            self.assertEqual(r.returncode, 1, repr(a))
        self.assertEqual(self.log("hyprctl.log"), [])
        self.assertEqual(self.log("wtype.log"), [])

    def test_a_different_active_window_means_nothing_is_typed(self):
        r = self.run_tool("type", ADDR, "continue", focus_to="0x999")      # the focus lands elsewhere
        self.assertEqual(r.returncode, 1)
        self.assertIn("did not take the focus", r.stderr)
        self.assertEqual(self.log("wtype.log"), [])

    def test_a_focus_that_never_lands_is_refused_after_about_a_second(self):
        r = self.run_tool("type", ADDR, "continue", focus_to="")            # the dispatch changes nothing
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.log("wtype.log"), [])
        self.assertGreater(len([l for l in self.log("hyprctl.log") if l.startswith("activewindow")]), 2)

    def test_a_late_focus_is_waited_for(self):
        self.fake("hyprctl", HYPRCTL.replace('if [ "$1" = activewindow ]; then',
                                             'if [ "$1" = activewindow ]; then n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_DIR/n"; [ $n -ge 3 ] && echo %s > "$FAKE_DIR/active"; ' % ADDR))
        r = self.run_tool("type", ADDR, "continue", focus_to="")
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.assertEqual(self.log("wtype.log"), ["--", "continue", "--end--"])

    def test_hyprctl_answering_with_junk_means_nothing_is_typed(self):
        self.fake("hyprctl", "#!/bin/sh\necho 'not json'\n")
        r = self.run_tool("type", ADDR, "continue")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.log("wtype.log"), [])

    def test_no_hyprctl_means_nothing_is_typed(self):
        os.remove(os.path.join(self.bin, "hyprctl"))
        r = self.run_tool("type", ADDR, "continue")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.log("wtype.log"), [])

    def test_missing_wtype_is_reported_and_nothing_is_focused(self):
        os.remove(os.path.join(self.bin, "wtype"))
        r = self.run_tool("type", ADDR, "continue", path=self.bin)     # PATH holds only the fakes: no real wtype
        self.assertEqual(r.returncode, 1)
        self.assertIn("wtype is not installed", r.stderr)
        self.assertEqual(self.log("hyprctl.log"), [])

    def test_a_failing_wtype_is_reported(self):
        r = self.run_tool("type", ADDR, "continue", wtype_rc=1)
        self.assertEqual(r.returncode, 1)
        self.assertIn("wtype failed", r.stderr)

    def test_bad_usage(self):
        for args in ((), ("type",), ("type", ADDR), ("press", ADDR, "x"), ("type", ADDR, "a", "b")):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)
        self.assertEqual(self.log("wtype.log"), [])


if __name__ == "__main__":
    unittest.main()
