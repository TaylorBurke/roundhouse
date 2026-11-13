"""tools/follow.py: which window moves, and what is sent. No Hyprland needed."""
import importlib.machinery
import importlib.util
import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "follow.py")
_loader = importlib.machinery.SourceFileLoader("follow", TOOL)
_spec = importlib.util.spec_from_loader("follow", _loader)
follow = importlib.util.module_from_spec(_spec)
_loader.exec_module(follow)

TITLE = "roundhouse: proj · 8f2cfbd5"


def client(title=TITLE, ws=11, address="0x55aa11", cls="org.quickshell", **extra):
    return {"class": cls, "title": title, "workspace": {"id": ws}, "address": address, "mapped": True, **extra}


class Pick(unittest.TestCase):
    def test_a_window_on_another_workspace_is_picked(self):
        self.assertEqual(follow.pick([client(ws=11)], TITLE, 12), ["0x55aa11"])

    def test_one_already_there_is_left_alone(self):
        self.assertEqual(follow.pick([client(ws=12)], TITLE, 12), [])

    def test_only_the_exact_title_of_a_quickshell_window(self):
        clients = [client(title="roundhouse: proj · deadbeef"), client(cls="foot", title=TITLE), client(title=TITLE + " ")]
        self.assertEqual(follow.pick(clients, TITLE, 12), [])

    def test_two_windows_of_one_name_but_different_sessions_do_not_mix(self):
        other = client(title="roundhouse: proj · 1111aaaa", address="0x55aa22")
        self.assertEqual(follow.pick([client(), other], TITLE, 12), ["0x55aa11"])

    def test_an_unmapped_window_or_a_bad_address_is_skipped(self):
        self.assertEqual(follow.pick([client(mapped=False)], TITLE, 12), [])
        for bad in ("0xZZ", "0x1; evil", "", None, 5):
            self.assertEqual(follow.pick([client(address=bad)], TITLE, 12), [], bad)

    def test_junk_in_the_client_list_is_ignored(self):
        self.assertEqual(follow.pick("nope", TITLE, 12), [])
        self.assertEqual(follow.pick([None, 5, {"class": "org.quickshell"}], TITLE, 12), [])


class Dispatch(unittest.TestCase):
    def test_moves_quietly_to_the_workspace(self):
        self.assertEqual(follow.dispatch_for("0x55aa11", 12),
                         'hl.dsp.window.move({ workspace = "12", follow = false, window = "address:0x55aa11" })')


class Command(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([TOOL, *args], capture_output=True, text=True)

    def test_refuses_anything_but_a_roundhouse_title_and_a_whole_workspace(self):
        for args in ((), ("roundhouse: x",), ("foot", "3"), ("roundhouse: x", "0"), ("roundhouse: x", "-1"),
                     ("roundhouse: x", "3; rm"), ("roundhouse: x", "special:scratchpad"), ("roundhouse: x", "3", "4")):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)


if __name__ == "__main__":
    unittest.main()
