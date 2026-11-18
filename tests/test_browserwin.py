"""tools/browserwin.py: listing the browser windows and focusing one. `hyprctl` on PATH is a fake that
answers `clients -j` and records the dispatches; /proc is a fake tree (BROWSERWIN_PROC)."""
import json
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "browserwin.py")


def win(address="0x55aa11", klass="google-chrome", title="Some page - Google Chrome", pid=100, **kw):
    return {"address": address, "class": klass, "title": title, "pid": pid, "mapped": True, **kw}


class Tool(unittest.TestCase):
    def run_tool(self, *args, clients=None, procs=None, hyprctl_fails=False, bad_json=False, dispatch_fails=False):
        """Returns (result, dispatches). `procs` maps pid -> command line text for the fake /proc."""
        with tempfile.TemporaryDirectory() as d:
            record = os.path.join(d, "dispatches")
            fake = os.path.join(d, "hyprctl")
            payload = "this is not json" if bad_json else json.dumps(clients if clients is not None else [])
            answer = "exit 1" if hyprctl_fails else f"cat <<'JSON_END'\n{payload}\nJSON_END"
            after = "exit 1" if dispatch_fails else ":"
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nif [ \"$1\" = clients ]; then\n{answer}\nelse\nprintf '%s\\n' \"$2\" >> '{record}'\n{after}\nfi\n")
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            proc = os.path.join(d, "proc")
            for pid, cmd in (procs or {}).items():
                os.makedirs(os.path.join(proc, str(pid)))
                with open(os.path.join(proc, str(pid), "cmdline"), "wb") as f:
                    f.write(cmd.replace(" ", "\0").encode())
            env = {**os.environ, "PATH": d + os.pathsep + os.environ["PATH"], "BROWSERWIN_PROC": proc}
            run = subprocess.run([TOOL, *args], env=env, capture_output=True, text=True, timeout=20)
            sent = []
            if os.path.exists(record):
                with open(record) as f:
                    sent = f.read().splitlines()
            return run, sent

    def listed(self, clients, procs=None):
        run, _ = self.run_tool("list", clients=clients, procs=procs)
        self.assertEqual(run.returncode, 0, run.stderr)
        return json.loads(run.stdout)

    def test_list_keeps_only_browser_windows(self):
        out = self.listed([win(), win("0x2", "foot", "term", 5), win("0x3", "firefox", "Home", 6),
                           win("0x4", "chromium", "x", 7), win("0x5", "Brave-browser", "y", 8),
                           win("0x6", "org.quickshell", "roundhouse: a", 9)])
        self.assertEqual([w["address"] for w in out], ["0x55aa11", "0x3", "0x4", "0x5"])
        self.assertEqual(sorted(out[0]), ["address", "class", "devtools", "pid", "title"])

    def test_list_skips_unmapped_and_malformed_windows(self):
        out = self.listed([win(mapped=False), win(address="55aa"), win(address=5), "junk", None,
                           win("0x9", title=None)])
        self.assertEqual([(w["address"], w["title"]) for w in out], [("0x9", "")])

    def test_the_devtools_mcp_instance_is_told_apart_by_its_command_line(self):
        out = self.listed([win("0x1", pid=10), win("0x2", pid=20), win("0x3", pid=30)],
                          procs={10: "/usr/bin/chrome --profile-directory=Default",
                                 20: "/usr/bin/chrome --user-data-dir=/home/u/.cache/chrome-devtools-mcp/chrome-profile"})
        self.assertEqual([w["devtools"] for w in out], [False, True, False])     # pid 30 has no /proc entry

    def test_list_never_prints_a_command_line(self):
        run, _ = self.run_tool("list", clients=[win(pid=20)], procs={20: "/usr/bin/chrome --secret-flag=hunter2 chrome-devtools-mcp"})
        self.assertNotIn("hunter2", run.stdout + run.stderr)

    def test_list_fails_quietly_when_hyprctl_is_broken(self):
        for kw in ({"hyprctl_fails": True}, {"bad_json": True}):
            run, _ = self.run_tool("list", **kw)
            self.assertEqual((run.returncode, run.stdout), (1, ""), kw)

    def test_an_empty_desktop_lists_nothing(self):
        self.assertEqual(self.listed([]), [])

    def test_focus_dispatches_once_for_a_listed_window(self):
        run, sent = self.run_tool("focus", "0x55aa11", clients=[win()])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(sent, ["hl.dsp.focus({ window = 'address:0x55aa11' })"])

    def test_focus_refuses_a_window_that_is_gone_or_not_a_browser(self):
        for clients in ([], [win("0x2")], [win(klass="foot")]):
            run, sent = self.run_tool("focus", "0x55aa11", clients=clients)
            self.assertEqual((run.returncode, sent), (2, []), clients)

    def test_focus_refuses_anything_that_is_not_an_address(self):
        for bad in ("0x", "55aa11", "0xZZ", "0x55aa11' }) + hl.dsp.exec_cmd('x", "0x" + "1" * 17, "", "0x55aa11 "):
            run, sent = self.run_tool("focus", bad, clients=[win()])
            self.assertEqual((run.returncode, sent), (2, []), bad)

    def test_bad_arguments(self):
        for args in ((), ("nope",), ("list", "x"), ("focus",), ("focus", "0x1", "0x2")):
            run, sent = self.run_tool(*args, clients=[win("0x1")])
            self.assertEqual((run.returncode, sent), (2, []), args)

    def test_a_failed_dispatch_is_exit_1(self):
        run, sent = self.run_tool("focus", "0x55aa11", clients=[win()], dispatch_fails=True)
        self.assertEqual((run.returncode, len(sent)), (1, 1))


if __name__ == "__main__":
    unittest.main()
