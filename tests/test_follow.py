"""tools/follow.py: which window moves, what is sent, and how it fails. No Hyprland needed: a fake
`hyprctl` on PATH answers `clients -j` and records the dispatches."""
import importlib.machinery
import importlib.util
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "follow.py")
_loader = importlib.machinery.SourceFileLoader("follow", TOOL)
_spec = importlib.util.spec_from_loader("follow", _loader)
follow = importlib.util.module_from_spec(_spec)
_loader.exec_module(follow)

SID = "8f2cfbd5"


def client(sid=SID, folder="proj", ws=11, address="0x55aa11", cls="org.quickshell", title=None, **extra):
    title = title if title is not None else f"roundhouse: {folder} · {sid}"
    return {"class": cls, "title": title, "workspace": {"id": ws}, "address": address, "mapped": True, **extra}


class Pick(unittest.TestCase):
    def test_a_window_on_another_workspace_is_picked(self):
        self.assertEqual(follow.pick([client(ws=11)], SID, 12), ["0x55aa11"])

    def test_one_already_there_is_left_alone(self):
        self.assertEqual(follow.pick([client(ws=12)], SID, 12), [])

    def test_the_folder_name_does_not_matter_only_the_session_id(self):
        # the folder shown in the title can change while the terminal moves
        for folder in ("proj", "session", "other-name", ""):
            self.assertEqual(follow.pick([client(folder=folder)], SID, 12), ["0x55aa11"], folder)

    def test_two_sessions_of_one_folder_do_not_mix(self):
        other = client(sid="1111aaaa", address="0x55aa22")
        self.assertEqual(follow.pick([client(), other], SID, 12), ["0x55aa11"])
        self.assertEqual(follow.pick([client(), other], "1111aaaa", 12), ["0x55aa22"])

    def test_only_a_quickshell_window_titled_like_a_roundhouse_session_window(self):
        clients = [client(cls="foot"), client(title=f"not roundhouse: proj · {SID}"),
                   client(title=f"roundhouse: proj {SID}"), client(title=f"roundhouse: proj · {SID} "),
                   client(title="roundhouse")]
        self.assertEqual(follow.pick(clients, SID, 12), [])

    def test_a_session_id_that_only_ends_the_same_way_is_not_a_match(self):
        self.assertEqual(follow.pick([client(sid="xx" + SID[2:])], SID, 12), [])
        self.assertEqual(follow.pick([client(title="roundhouse: proj · AAAA" + SID)], SID, 12), [])

    def test_an_unmapped_window_or_a_bad_address_is_skipped(self):
        self.assertEqual(follow.pick([client(mapped=False)], SID, 12), [])
        for bad in ("0xZZ", "0x1; evil", "", None, 5):
            self.assertEqual(follow.pick([client(address=bad)], SID, 12), [], bad)

    def test_junk_in_the_client_list_is_ignored(self):
        self.assertEqual(follow.pick("nope", SID, 12), [])
        self.assertEqual(follow.pick([None, 5, {"class": "org.quickshell"}, client(title=7)], SID, 12), [])


class Dispatch(unittest.TestCase):
    def test_moves_quietly_to_the_workspace(self):
        self.assertEqual(follow.dispatch_for("0x55aa11", 12),
                         'hl.dsp.window.move({ workspace = "12", follow = false, window = "address:0x55aa11" })')


class TitleContract(unittest.TestCase):
    """The window builds its title; follow.py finds it by that title. Keep the two in step."""

    def setUp(self):
        with open(os.path.join(ROOT, "ui", "RoundhouseWindow.qml"), encoding="utf-8") as f:
            self.qml = f.read()

    def test_the_title_the_window_builds_ends_with_the_separator_and_its_session_id(self):
        line = next(l for l in self.qml.splitlines() if re.match(r"\s*title:\s", l))
        self.assertIn('"roundhouse: "', line)
        self.assertIn(follow.SEPARATOR, line.replace("\\u00b7", "·"))     # the QML may spell it as an escape
        self.assertTrue(line.rstrip().endswith("+ sid"), line)
        self.assertTrue(follow.TITLE_START.startswith("roundhouse: "))

    def test_the_window_asks_follow_py_for_its_own_session_id(self):
        call = next(l for l in self.qml.splitlines() if "follow.py" in l and "execDetached" in l)
        self.assertIn("win.sid", call)
        self.assertNotIn("win.title", call)

    def test_the_window_session_id_is_eight_characters_like_the_tool_expects(self):
        with open(os.path.join(ROOT, "tools", "windows.py"), encoding="utf-8") as f:
            windows_py = f.read()
        self.assertIn("return sid[:8]", windows_py)
        self.assertEqual(follow.SID.pattern, "[A-Za-z0-9_-]{8}")


class Command(unittest.TestCase):
    def run_tool(self, *args, clients=None, hyprctl_fails=False, bad_json=False):
        """Run follow.py with a fake hyprctl; returns (result, list of dispatch strings)."""
        with tempfile.TemporaryDirectory() as d:
            record = os.path.join(d, "dispatches")
            fake = os.path.join(d, "hyprctl")
            payload = "this is not json" if bad_json else json.dumps(clients if clients is not None else [])
            answer = "exit 1" if hyprctl_fails else f"cat <<'JSON_END'\n{payload}\nJSON_END"
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nif [ \"$1\" = clients ]; then\n{answer}\nelse\nprintf '%s\\n' \"$2\" >> '{record}'\nfi\n")
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            env = {**os.environ, "PATH": d + os.pathsep + os.environ["PATH"]}
            run = subprocess.run([TOOL, *args], env=env, capture_output=True, text=True, timeout=20)
            sent = []
            if os.path.exists(record):
                with open(record) as f:
                    sent = f.read().splitlines()
            return run, sent

    def test_it_moves_the_matching_window_and_only_that_one(self):
        clients = [client(ws=11), client(sid="1111aaaa", address="0x55aa22", ws=11), client(cls="foot", address="0x55aa33")]
        run, sent = self.run_tool(SID, "12", clients=clients)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(sent, ['hl.dsp.window.move({ workspace = "12", follow = false, window = "address:0x55aa11" })'])

    def test_it_does_nothing_when_the_window_is_already_there_or_missing(self):
        for clients in ([client(ws=12)], [], [client(sid="1111aaaa")]):
            run, sent = self.run_tool(SID, "12", clients=clients)
            self.assertEqual((run.returncode, sent), (0, []), clients)

    def test_it_still_finds_the_window_after_the_folder_name_changed(self):
        run, sent = self.run_tool(SID, "12", clients=[client(folder="renamed")])
        self.assertEqual((run.returncode, len(sent)), (0, 1))

    def test_it_exits_1_when_hyprland_cannot_be_read(self):
        run, sent = self.run_tool(SID, "12", hyprctl_fails=True)
        self.assertEqual((run.returncode, sent), (1, []))
        run, sent = self.run_tool(SID, "12", bad_json=True)
        self.assertEqual((run.returncode, sent), (1, []))

    def test_it_exits_1_when_there_is_no_hyprctl_at_all(self):
        env = {**os.environ, "PATH": "/nonexistent"}
        run = subprocess.run(["/usr/bin/python3", "-I", TOOL, SID, "12"], env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 1)

    def test_refuses_anything_but_a_session_id_and_a_whole_workspace(self):
        bad = ((), (SID,), ("roundhouse: x", "3"), ("foot", "3"), (SID, "0"), (SID, "-1"), (SID, "3; rm"),
               (SID, "special:scratchpad"), (SID, "3", "4"), ("short", "3"), (SID + "9", "3"), ("bad id!!", "3"),
               ("roundhouseX", "3"), ("../../x__", "3"))
        for args in bad:
            run, sent = self.run_tool(*args, clients=[client()])
            self.assertEqual((run.returncode, sent), (2, []), args)


if __name__ == "__main__":
    unittest.main()
