"""tools/browserwin.py: listing the browser windows and focusing one. `hyprctl` on PATH is a fake that
answers `clients -j` and records the dispatches."""
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
    def run_tool(self, *args, clients=None, hyprctl_fails=False, bad_json=False, dispatch_fails=False, dispatch_says="ok"):
        """Returns (result, dispatches)."""
        with tempfile.TemporaryDirectory() as d:
            record = os.path.join(d, "dispatches")
            fake = os.path.join(d, "hyprctl")
            payload = "this is not json" if bad_json else json.dumps(clients if clients is not None else [])
            answer = "exit 1" if hyprctl_fails else f"cat <<'JSON_END'\n{payload}\nJSON_END"
            after = "exit 1" if dispatch_fails else ("echo " + dispatch_says)
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nif [ \"$1\" = clients ]; then\n{answer}\nelse\nprintf '%s\\n' \"$2\" >> '{record}'\n{after}\nfi\n")
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            env = {**os.environ, "PATH": d + os.pathsep + os.environ["PATH"]}
            run = subprocess.run([TOOL, *args], env=env, capture_output=True, text=True, timeout=20)
            sent = []
            if os.path.exists(record):
                with open(record) as f:
                    sent = f.read().splitlines()
            return run, sent

    def listed(self, clients):
        run, _ = self.run_tool("list", clients=clients)
        self.assertEqual(run.returncode, 0, run.stderr)
        return json.loads(run.stdout)

    def test_list_keeps_only_browser_windows(self):
        out = self.listed([win(), win("0x2", "foot", "term", 5), win("0x3", "firefox", "Home", 6),
                           win("0x4", "chromium", "x", 7), win("0x5", "Brave-browser", "y", 8),
                           win("0x6", "org.quickshell", "roundhouse: a", 9)])
        self.assertEqual([w["address"] for w in out], ["0x55aa11", "0x3", "0x4", "0x5"])
        self.assertEqual(sorted(out[0]), ["address", "class", "pid", "title", "workspace"])

    def test_list_skips_unmapped_and_malformed_windows(self):
        out = self.listed([win(mapped=False), win(address="55aa"), win(address=5), "junk", None,
                           win("0x9", title=None)])
        self.assertEqual([(w["address"], w["title"]) for w in out], [("0x9", "")])

    def test_list_fails_quietly_when_hyprctl_is_broken(self):
        for kw in ({"hyprctl_fails": True}, {"bad_json": True}):
            run, _ = self.run_tool("list", **kw)
            self.assertEqual((run.returncode, json.loads(run.stdout)), (1, {"error": "hyprctl"}), kw)

    def test_app_and_pwa_windows_are_not_browser_windows(self):
        apps = ["chrome-abcdefgh-Default", "chrome-mail.google.com__-Default", "Chromium-app", "chrome-123-Profile 1",
                "chromium-foo", "firefoxy", "zenity", "foot", "opera-gx-helper"]
        self.assertEqual(self.listed([win(f"0x{i}", k) for i, k in enumerate(apps, 1)]), [])
        ok = ["google-chrome", "google-chrome-stable", "Google-chrome", "chromium", "Chromium", "chromium-browser", "firefox",
              "Brave-browser", "vivaldi-stable", "microsoft-edge", "librewolf", "floorp", "zen", "zen-browser", "google-chrome-beta"]
        self.assertEqual(len(self.listed([win(f"0x{i}", k) for i, k in enumerate(ok, 1)])), len(ok))

    def test_the_workspace_name_comes_along(self):
        out = self.listed([win(workspace={"id": 3, "name": "3"}), win("0x2", workspace=None), win("0x3", workspace={"id": 1})])
        self.assertEqual([w["workspace"] for w in out], ["3", "", ""])

    def test_the_tool_never_reads_proc_or_a_command_line(self):
        with open(TOOL) as f:
            text = f.read()
        self.assertNotIn("/proc", text)
        self.assertNotIn("cmdline", text)
        self.assertNotIn("devtools", text.lower())

    def test_a_dispatch_that_prints_an_error_and_exits_0_is_a_failure(self):
        for says in ("'Invalid dispatcher'", "''"):
            run, sent = self.run_tool("focus", "0x55aa11", clients=[win()], dispatch_says=says)
            self.assertEqual((run.returncode, len(sent)), (1, 1), says)

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
