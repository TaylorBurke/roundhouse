"""Runs the real roundhouse service (ui/shell.qml and every window component) under Quickshell, offscreen,
and clicks through it with tests/window/Driver.qml. Catches what no unit test sees: a window that does not
load at all (#79: two merged branches that each added the same QML function), and the window glue in
RoundhouseWindow.qml between a click and what the window does (#78: jobs, lists, toasts, the click-away area).

Nothing reaches the real desktop or the real home folder:
- a scratch folder holds a fake home (a project, its memory files, a settings.json with one hook), a short
  XDG_RUNTIME_DIR with the event log and windows.json, and links to ui/, tools/ and bin/ beside a copy of
  ui/shell.qml with the driver added;
- the environment is emptied (`env -i` style): no WAYLAND_DISPLAY, no HYPRLAND_INSTANCE_SIGNATURE, and Qt
  draws offscreen;
- hyprctl, omarchy, xdg-open, wtype, wl-copy and setsid are stubs first on PATH that only write their
  arguments to a file, which the driver reads (a click on a file name must ask the editor for that file).

Skipped when quickshell is not installed. To look at what the window showed at each step:
  RH_SHOTS=/some/dir python3 -m unittest tests.test_window
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUICKSHELL = shutil.which("quickshell")
STUBS = ("hyprctl", "omarchy", "xdg-open", "wtype", "wl-copy", "setsid")
SID = "abcd1234"

# Log lines that mean the window did not load or a binding threw. Quickshell prints QML errors as WARN or
# ERROR lines; these are the ones that matter here.
BAD = re.compile(r"Failed to load|ERROR|ReferenceError|TypeError|SyntaxError|is not a function|Duplicate method"
                 r"|Cannot assign|Unable to assign|Type .* unavailable|is not a type")


def harness_shell():
    """ui/shell.qml with the window Variants named and the driver added: the real service, so the test
    can never drift from what is installed. Fails loudly if shell.qml no longer has the expected shape."""
    with open(os.path.join(ROOT, "ui", "shell.qml"), encoding="utf-8") as f:
        src = f.read()
    if src.count("    Variants {\n") != 1 or not src.rstrip().endswith("}"):
        raise AssertionError("ui/shell.qml changed shape: update tests/test_window.py harness_shell()")
    src = src.replace("    Variants {\n", "    Variants {\n        id: rhTestWindows\n", 1)
    body = src.rstrip()[:-1]
    return body + "    Driver { windows: rhTestWindows.instances; tail: sharedTail }\n}\n"


def write(path, text, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def project_key(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


@unittest.skipUnless(QUICKSHELL, "quickshell not installed")
class RealWindow(unittest.TestCase):
    def setUp(self):
        # short: the runtime folder holds Quickshell's IPC socket, whose path must stay under 108 bytes
        self.tmp = tempfile.mkdtemp(prefix="rh")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        t = self.tmp
        self.home = os.path.join(t, "h")
        self.run_dir = os.path.join(t, "r")
        self.stub_log = os.path.join(t, "stub.log")
        os.makedirs(self.run_dir, mode=0o700)

        # the service, from links (Quickshell resolves ../tools and ../bin from the folder shell.qml is in)
        conf = os.path.join(t, "c")
        os.makedirs(os.path.join(conf, "ui"))
        for name in os.listdir(os.path.join(ROOT, "ui")):
            if name != "shell.qml":
                os.symlink(os.path.join(ROOT, "ui", name), os.path.join(conf, "ui", name))
        os.symlink(os.path.join(ROOT, "tests", "window", "Driver.qml"), os.path.join(conf, "ui", "Driver.qml"))
        write(os.path.join(conf, "ui", "shell.qml"), harness_shell())
        for d in ("tools", "bin", "hooks"):
            os.symlink(os.path.join(ROOT, d), os.path.join(conf, d))
        self.conf = conf

        # stubs: record the command, do nothing else
        stubs = os.path.join(t, "s")
        os.makedirs(stubs)
        for name in STUBS:
            p = os.path.join(stubs, name)
            write(p, '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\n' % (name, self.stub_log))
            os.chmod(p, 0o755)
        self.path = stubs + ":/usr/bin:/bin"

        # the fake home: a project with one source file, its memory folder, one configured hook
        proj = os.path.join(self.home, "Work", "proj")
        write(os.path.join(proj, "src", "a.ts"), "export {};\n")
        write(os.path.join(proj, "src", "b.ts"), "export {};\n")
        mem = os.path.join(self.home, ".claude", "projects", project_key(os.path.realpath(proj)), "memory")
        now = time.time()
        write(os.path.join(mem, "MEMORY.md"), "- [notes](notes.md)\n", now - 300)
        write(os.path.join(mem, "notes.md"), "a note\n", now - 200)
        write(os.path.join(mem, "other.md"), "another\n", now - 100)
        hook = os.path.join(self.home, "bin", "check.sh")
        write(hook, "#!/bin/sh\n")
        write(os.path.join(self.home, ".claude", "settings.json"), json.dumps({"hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": hook}]}]}}))

        # the log: one session in that project that read two files and a memory file and ran a command
        events = [
            {"ev": "session", "dir": "proj", "model": "claude-opus-5-5"},
            {"ev": "prompt"},
            {"ev": "tool_end", "id": "t0", "station": "files", "label": "src/b.ts", "tool": "Read", "status": "ok", "ms": 4},
            {"ev": "tool_end", "id": "t1", "station": "files", "label": "src/a.ts", "tool": "Read", "status": "ok", "ms": 4},
            {"ev": "tool_end", "id": "t2", "station": "memory", "label": "memory/notes.md", "tool": "Read", "status": "ok", "ms": 3},
            {"ev": "tool_end", "id": "t3", "station": "shell", "label": "Run the tests", "tool": "Bash", "status": "ok", "ms": 900},
        ]
        lot = os.path.join(self.run_dir, "lot-map")
        os.makedirs(lot)
        with open(os.path.join(lot, "events.jsonl"), "w", encoding="utf-8") as f:
            for i, e in enumerate(events):
                f.write(json.dumps({"v": 1, "ts": round(now - 5 + i * 0.5, 3), "sid": SID, **e}) + "\n")
        write(os.path.join(lot, "windows.json"), json.dumps({"shown": [{"id": "all", "sid": "*"}, {"id": "w1", "sid": SID}]}))

    def run_service(self, timeout=90):
        env = {"PATH": self.path, "HOME": self.home, "XDG_RUNTIME_DIR": self.run_dir, "LANG": "C.UTF-8",
               "QT_QPA_PLATFORM": "offscreen", "RH_STUB_LOG": self.stub_log,
               "QML_XHR_ALLOW_FILE_READ": "1",      # the driver reads the stub log
               "QT_QUICK_BACKEND": "software"}      # draws without a GPU, so RH_SHOTS pictures can be grabbed
        if os.environ.get("RH_SHOTS"):
            env["RH_SHOTS"] = os.path.abspath(os.environ["RH_SHOTS"])
            os.makedirs(env["RH_SHOTS"], exist_ok=True)
        try:
            run = subprocess.run([QUICKSHELL, "-p", os.path.join(self.conf, "ui")], env=env, cwd=self.tmp,
                                 capture_output=True, text=True, timeout=timeout)
            return run.stdout + run.stderr
        except subprocess.TimeoutExpired as e:      # a config that fails to load waits for a fix: it never quits
            text = lambda b: b.decode("utf-8", "replace") if isinstance(b, bytes) else (b or "")
            return text(e.stdout) + text(e.stderr) + "\n(timed out after %d s)" % timeout

    def test_the_window_loads_and_reacts_to_clicks(self):
        out = self.run_service()
        lines = out.splitlines()
        results = [l.split("RH-TEST ", 1)[1] for l in lines if "RH-TEST " in l]
        bad = [l for l in lines if BAD.search(l) and "RH-TEST" not in l]
        failed = [r for r in results if r.startswith("FAIL")]
        if os.environ.get("RH_SHOTS"):              # a run for pictures: say what happened
            print("\n" + "\n".join(results))
        self.assertIn("DONE", results, "the driver never finished; the service said:\n" + out[-4000:])
        self.assertEqual(failed, [], "\n".join(failed) + "\n\n" + out[-4000:])
        self.assertEqual(bad, [], "QML errors while running:\n" + "\n".join(bad))
        self.assertGreaterEqual(len([r for r in results if r.startswith("PASS")]), 26, "\n".join(results))

    def test_a_window_that_does_not_load_fails(self):
        # the check itself: a duplicate function (the #80 breakage) must be caught for what it is
        broken = os.path.join(self.conf, "ui", "RoundhouseWindow.qml")
        with open(broken, encoding="utf-8") as f:
            src = f.read()
        planted = src.replace("    function now() {", "    function closeList() {}\n    function now() {", 1)
        self.assertNotEqual(planted, src, "the anchor for the planted duplicate is gone: update this test")
        os.unlink(broken)                            # a link to the real file: replace the link, not the file
        write(broken, planted)
        out = self.run_service(timeout=20)
        self.assertIn("Failed to load configuration", out, out[-2000:])
        self.assertIn("Duplicate method name", out, out[-2000:])
        self.assertTrue(BAD.search(out))
        self.assertNotIn("RH-TEST DONE", out)

if __name__ == "__main__":
    unittest.main()
