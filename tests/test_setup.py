import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "hooks"))
import emit  # noqa: E402
import setup  # noqa: E402

EMIT = setup.emitter()

# A settings file like a real one: other keys, hooks of its own on events we also use.
ORIGINAL = {
    "permissions": {"allow": ["Bash(ls:*)"]},
    "model": "opus",
    "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/home/u/guard.sh"}]},
                       {"hooks": [{"type": "command", "command": "/home/u/other.sh", "timeout": 5}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "/home/u/stop.sh"}]}],
    },
    "theme": "dark",
}


def text_of(data, indent=2, newline=True):
    return json.dumps(data, indent=indent, ensure_ascii=False) + ("\n" if newline else "")


class Sandbox:
    """A fake home: settings, bin dir, Hyprland config, runtime dir."""

    def __init__(self, settings_text=None, hypr_text=None):
        self.d = tempfile.mkdtemp()
        self.settings = os.path.join(self.d, "claude", "settings.json")
        self.bin = os.path.join(self.d, "bin")
        self.hypr = os.path.join(self.d, "hypr", "hyprland.lua")
        self.runtime = os.path.join(self.d, "run")
        os.makedirs(os.path.dirname(self.settings))
        os.makedirs(os.path.dirname(self.hypr))
        os.makedirs(os.path.join(self.runtime, "lot-map"))
        if settings_text is not None:
            with open(self.settings, "w") as f:
                f.write(settings_text)
        if hypr_text is not None:
            with open(self.hypr, "w") as f:
                f.write(hypr_text)

    def run(self, *args):
        argv = [*args, "--settings", self.settings, "--bin-dir", self.bin, "--hypr-config", self.hypr,
                "--runtime-dir", self.runtime, "--no-reload"]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                mock.patch.object(setup, "stop_service", return_value=0), \
                mock.patch.object(setup, "_service_pids", return_value=iter(())):
            code = setup.main(argv)
        return code, out.getvalue(), err.getvalue()

    def read(self, path):
        with open(path) as f:
            return f.read()

    def close(self):
        shutil.rmtree(self.d, ignore_errors=True)


class Events(unittest.TestCase):
    def test_the_list_is_what_the_emitter_handles(self):
        with open(os.path.join(ROOT, "hooks", "emit.py"), encoding="utf-8") as f:
            source = f.read()
        handled = set(re.findall(r'kind == "(\w+)"', source))
        for group in re.findall(r"kind in \(([^)]*)\)", source):
            handled |= set(re.findall(r'"(\w+)"', group))
        self.assertEqual(set(setup.EVENTS), handled)
        self.assertEqual(len(setup.EVENTS), len(set(setup.EVENTS)))

    def test_every_event_produces_something(self):
        for event in setup.EVENTS:
            payload = {"hook_event_name": event, "session_id": "s", "agent_type": "Explore", "agent_id": "a1"}
            self.assertTrue(emit.events_for(payload), event)


class Pure(unittest.TestCase):
    def test_add_keeps_everything_and_appends_ours_last(self):
        new = setup.add_hooks(ORIGINAL, EMIT)
        self.assertEqual(set(new["hooks"]), set(setup.EVENTS) | set(ORIGINAL["hooks"]))
        self.assertEqual(new["hooks"]["PreToolUse"][:2], ORIGINAL["hooks"]["PreToolUse"])
        self.assertEqual(new["hooks"]["PreToolUse"][2], {"hooks": [{"type": "command", "command": EMIT, "async": True}]})
        self.assertEqual({k: v for k, v in new.items() if k != "hooks"}, {k: v for k, v in ORIGINAL.items() if k != "hooks"})
        self.assertEqual(ORIGINAL["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "/home/u/stop.sh"}]}])  # input untouched

    def test_add_is_idempotent_and_remove_undoes_it(self):
        once = setup.add_hooks(ORIGINAL, EMIT)
        self.assertEqual(setup.add_hooks(once, EMIT), once)
        self.assertEqual(setup.remove_hooks(once, EMIT), ORIGINAL)

    def test_remove_from_nothing_changes_nothing(self):
        self.assertEqual(setup.remove_hooks(ORIGINAL, EMIT), ORIGINAL)
        self.assertEqual(setup.remove_hooks({}, EMIT), {})
        self.assertEqual(setup.remove_hooks({"hooks": {}}, EMIT), {})

    def test_remove_leaves_other_hooks_in_a_shared_group(self):
        mixed = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/x/keep.sh"},
                                               {"type": "command", "command": EMIT, "async": True}]}]}}
        self.assertEqual(setup.remove_hooks(mixed, EMIT),
                         {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/x/keep.sh"}]}]}})

    def test_a_command_with_arguments_or_another_path_is_not_ours(self):
        self.assertFalse(setup.is_ours(EMIT + " --flag", EMIT))
        self.assertFalse(setup.is_ours("/elsewhere/hooks/emit.py", EMIT))
        self.assertFalse(setup.is_ours(None, EMIT))
        self.assertTrue(setup.is_ours(EMIT, EMIT))

    def test_a_path_with_a_space_is_still_recognised(self):
        odd = "/home/me/my projects/roundhouse/hooks/emit.py"
        once = setup.add_hooks({}, odd)
        self.assertEqual(setup.add_hooks(once, odd), once)
        self.assertEqual(setup.remove_hooks(once, odd), {})

    def test_odd_structures_are_refused(self):
        for bad in ({"hooks": []}, {"hooks": {"Stop": {"hooks": []}}}, {"hooks": {"Stop": ["x"]}}):
            with self.assertRaises(setup.Refuse):
                setup.add_hooks(bad, EMIT)
            with self.assertRaises(setup.Refuse):
                setup.remove_hooks(bad, EMIT)

    def test_style_is_detected(self):
        self.assertEqual(setup.json_style('{\n    "a": 1\n}\n'), (4, True))
        self.assertEqual(setup.json_style('{\n\t"a": 1\n}'), ("\t", False))
        self.assertEqual(setup.json_style("{}"), (2, False))


class Install(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(text_of(ORIGINAL))
        self.addCleanup(self.box.close)

    def test_round_trip_gives_the_original_bytes_back(self):
        before = self.box.read(self.box.settings)
        code, out, _ = self.box.run("install", "--yes")
        self.assertEqual(code, 0, out)
        after = json.loads(self.box.read(self.box.settings))
        self.assertEqual(len([e for e in after["hooks"] if setup.has_ours(after["hooks"][e], EMIT)]), 17)
        code, out, _ = self.box.run("uninstall", "--yes")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.box.read(self.box.settings), before)

    def test_the_diff_is_shown_and_a_backup_is_made(self):
        code, out, _ = self.box.run("install", "--yes")
        self.assertIn("--- ", out)
        self.assertIn('+            "command": "' + EMIT, out)
        backups = [f for f in os.listdir(os.path.dirname(self.box.settings)) if ".roundhouse-backup-" in f]
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.box.read(os.path.join(os.path.dirname(self.box.settings), backups[0])), text_of(ORIGINAL))

    def test_running_it_again_changes_nothing(self):
        self.box.run("install", "--yes")
        once = self.box.read(self.box.settings)
        code, out, _ = self.box.run("install", "--yes")
        self.assertEqual(code, 0)
        self.assertEqual(self.box.read(self.box.settings), once)
        self.assertIn("nothing to do", out)

    def test_dry_run_writes_nothing_anywhere(self):
        before = self.box.read(self.box.settings)
        code, out, _ = self.box.run("install", "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("dry run", out)
        self.assertEqual(self.box.read(self.box.settings), before)
        self.assertEqual(os.listdir(os.path.dirname(self.box.settings)), ["settings.json"])
        self.assertFalse(os.path.exists(self.box.bin))

    def test_without_a_terminal_and_without_yes_it_refuses(self):
        before = self.box.read(self.box.settings)
        with mock.patch.object(sys, "stdin", io.StringIO("")):
            code, _, err = self.box.run("install")
        self.assertEqual(code, 1)
        self.assertIn("--yes", err)
        self.assertEqual(self.box.read(self.box.settings), before)

    def test_answering_no_changes_nothing(self):
        before = self.box.read(self.box.settings)
        fake_tty = mock.Mock(); fake_tty.isatty.return_value = True
        with mock.patch.object(sys, "stdin", fake_tty), mock.patch("builtins.input", return_value="n"):
            code, out, _ = self.box.run("install")
        self.assertEqual(code, 0)
        self.assertIn("skipped", out)
        self.assertEqual(self.box.read(self.box.settings), before)
        self.assertFalse(os.path.lexists(os.path.join(self.box.bin, "roundhouse")))

    def test_file_mode_and_style_are_kept(self):
        self.box.close()
        self.box = Sandbox(text_of(ORIGINAL, indent=4, newline=False))
        os.chmod(self.box.settings, 0o640)
        self.box.run("install", "--yes")
        self.assertEqual(oct(os.stat(self.box.settings).st_mode & 0o777), "0o640")
        text = self.box.read(self.box.settings)
        self.assertTrue(text.startswith('{\n    "permissions"'))
        self.assertFalse(text.endswith("\n"))
        self.box.run("uninstall", "--yes")
        self.assertEqual(self.box.read(self.box.settings), text_of(ORIGINAL, indent=4, newline=False))

    def test_a_missing_settings_file_is_created(self):
        os.unlink(self.box.settings)
        code, out, _ = self.box.run("install", "--yes")
        self.assertEqual(code, 0)
        self.assertIn("will be created", out)
        self.assertEqual(len(json.loads(self.box.read(self.box.settings))["hooks"]), 17)

    def test_broken_or_odd_files_are_left_alone(self):
        for body in ("{not json", "[1, 2]", text_of({"hooks": []})):
            with open(self.box.settings, "w") as f:
                f.write(body)
            code, _, err = self.box.run("install", "--yes")
            self.assertEqual(code, 1, body)
            self.assertIn("leaving", err)
            self.assertEqual(self.box.read(self.box.settings), body)


class Link(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(text_of({}))
        self.addCleanup(self.box.close)
        self.link = os.path.join(self.box.bin, "roundhouse")

    def test_created_once_and_removed_only_if_ours(self):
        self.box.run("install", "--yes")
        self.assertEqual(os.path.realpath(self.link), os.path.realpath(os.path.join(ROOT, "bin", "roundhouse")))
        code, out, _ = self.box.run("install", "--yes")
        self.assertIn("already links here", out)
        self.box.run("uninstall", "--yes")
        self.assertFalse(os.path.lexists(self.link))

    def test_a_file_that_is_not_ours_is_never_touched(self):
        os.makedirs(self.box.bin)
        with open(self.link, "w") as f:
            f.write("someone else's")
        code, out, _ = self.box.run("install", "--yes")
        self.assertIn("not ours", out)
        self.box.run("uninstall", "--yes")
        self.assertEqual(self.box.read(self.link), "someone else's")


class Hyprland(unittest.TestCase):
    CONFIG = '-- my config\no.window("x", { float = true })\n'

    def setUp(self):
        self.box = Sandbox(text_of({}), self.CONFIG)
        self.addCleanup(self.box.close)

    def test_untouched_unless_asked_for(self):
        self.box.run("install", "--yes")
        self.assertEqual(self.box.read(self.box.hypr), self.CONFIG)
        self.box.run("install", "--yes", "--skip-hyprland", "--with-hyprland")
        self.assertEqual(self.box.read(self.box.hypr), self.CONFIG)

    def test_added_and_removed_exactly(self):
        code, out, _ = self.box.run("install", "--yes", "--with-hyprland")
        self.assertEqual(code, 0, out)
        text = self.box.read(self.box.hypr)
        self.assertEqual(text, self.CONFIG + setup.hypr_line() + "\n")
        self.assertTrue(text.splitlines()[-1].endswith("-- roundhouse"))
        self.box.run("install", "--yes", "--with-hyprland")
        self.assertEqual(self.box.read(self.box.hypr), text)          # not twice
        self.box.run("uninstall", "--yes")
        self.assertEqual(self.box.read(self.box.hypr), self.CONFIG)

    def test_a_config_without_a_final_newline(self):
        with open(self.box.hypr, "w") as f:
            f.write("-- x")
        self.box.run("install", "--yes", "--with-hyprland")
        self.assertEqual(self.box.read(self.box.hypr), "-- x\n" + setup.hypr_line() + "\n")

    def test_if_hyprland_reports_errors_the_backup_goes_back(self):
        argv = ["install", "--yes", "--with-hyprland", "--settings", self.box.settings, "--bin-dir", self.box.bin,
                "--hypr-config", self.box.hypr, "--runtime-dir", self.box.runtime]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(setup, "hypr_reload_ok", return_value=(False, "line 3: nope")):
            code = setup.main(argv)
        self.assertEqual(code, 0)
        self.assertIn("backup was put back", out.getvalue())
        self.assertEqual(self.box.read(self.box.hypr), self.CONFIG)

    def test_a_good_reload_is_reported(self):
        argv = ["install", "--yes", "--with-hyprland", "--settings", self.box.settings, "--bin-dir", self.box.bin,
                "--hypr-config", self.box.hypr, "--runtime-dir", self.box.runtime]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(setup, "hypr_reload_ok", return_value=(True, "")):
            setup.main(argv)
        self.assertIn("no config errors", out.getvalue())
        self.assertIn(setup.hypr_line(), self.box.read(self.box.hypr))


class Uninstall(unittest.TestCase):
    def test_removes_the_log_folder_and_only_that(self):
        box = Sandbox(text_of(ORIGINAL))
        self.addCleanup(box.close)
        keep = os.path.join(box.runtime, "other-thing")
        os.makedirs(keep)
        with open(os.path.join(box.runtime, "lot-map", "events.jsonl"), "w") as f:
            f.write("{}\n")
        code, out, _ = box.run("uninstall", "--yes")
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.exists(os.path.join(box.runtime, "lot-map")))
        self.assertTrue(os.path.isdir(keep))

    def test_dry_run_keeps_the_log_folder(self):
        box = Sandbox(text_of(ORIGINAL))
        self.addCleanup(box.close)
        box.run("uninstall", "--dry-run")
        self.assertTrue(os.path.isdir(os.path.join(box.runtime, "lot-map")))

    def test_status_says_what_is_there(self):
        box = Sandbox(text_of(ORIGINAL), "-- c\n")
        self.addCleanup(box.close)
        self.assertIn("0 of 17", box.run("status")[1])
        box.run("install", "--yes")
        out = box.run("status")[1]
        self.assertIn("17 of 17", out)
        self.assertIn("ours", out)


@unittest.skipUnless(shutil.which("jq"), "jq not installed")
class ByHandInstructions(unittest.TestCase):
    def test_the_jq_command_in_the_readme_does_what_uninstall_does(self):
        with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
            readme = f.read()
        filt = re.search(r"jq '([^']+)'", readme).group(1)
        emit_path = "/somewhere/roundhouse/hooks/emit.py"
        installed = setup.add_hooks(ORIGINAL, emit_path)
        run = subprocess.run(["jq", filt], input=json.dumps(installed), capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout), ORIGINAL)


if __name__ == "__main__":
    unittest.main()
