"""tools/openhost.py: only a plain hostname ever reaches xdg-open, and as one argument.
`xdg-open` on PATH is a stand-in that records its arguments."""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "openhost.py")
_loader = importlib.machinery.SourceFileLoader("openhost", TOOL)
_spec = importlib.util.spec_from_loader("openhost", _loader)
openhost = importlib.util.module_from_spec(_spec)
_loader.exec_module(openhost)

GOOD = ["example.com", "a.b.c.example.org", "EXAMPLE.com", "docs.python.org", "xn--bcher-kva.example",
        "my-site.io", "1.2.3.4", "a-b.c-d.e", "x" * 63 + ".com"]
BAD = ["", "localhost", "example", "xn--", "example.com ", " example.com", "exa mple.com", "example.com\n",
       "\nexample.com", "https://example.com", "http://example.com", "javascript:alert(1)",
       "file:///etc/passwd", "example.com/path", "example.com/", "example.com?x=1", "example.com#f",
       "example.com:8080", "user@example.com", "user:pw@example.com", "-example.com", "--help.com", "-o.com",
       "a.-b.com", "a-.com", "example.-com", "example.com-", "example.com.", ".example.com", "example..com",
       "exa\x00mple.com", "exa\x1bmple.com", "exa\tmple.com", "exa\x7fmple.com", "bücher.example",
       "ｅxample.com", "exa_mple.com", "exa;mple.com", "exa&mple.com", "exa|mple.com", "$(id).com",
       "`id`.com", "a.com;id", "exa'mple.com", 'exa"mple.com', "exa\\mple.com", "[::1]", "::1",
       "x" * 64 + ".com", ("a." * 130) + "com", "‮example.com"]


class Validation(unittest.TestCase):
    def test_plain_hostnames_pass(self):
        for h in GOOD:
            self.assertTrue(openhost.valid_host(h), h)

    def test_hostile_and_odd_inputs_are_refused(self):
        for h in BAD:
            self.assertFalse(openhost.valid_host(h), repr(h))

    def test_not_a_string(self):
        for v in (None, 5, b"example.com", ["example.com"]):
            self.assertFalse(openhost.valid_host(v))


class SameRuleAsTheWindow(unittest.TestCase):
    """HOST_RE in ui/openlist.js and _HOST here must stay identical: same text, same verdicts."""

    def js_pattern(self):
        import re
        src = open(os.path.join(ROOT, "ui", "openlist.js")).read()
        return re.search(r"var HOST_RE = /\^(.*)\$/;", src).group(1)

    def test_the_two_patterns_are_the_same_text(self):
        self.assertEqual(self.js_pattern(), openhost._HOST.pattern)

    def test_both_give_the_same_verdict_on_the_samples(self):
        import re
        js = re.compile("^" + self.js_pattern() + "$", re.ASCII)
        for h in GOOD + BAD:
            self.assertEqual(js.fullmatch(h) is not None and len(h) <= 253, openhost.valid_host(h), repr(h))


class Launch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.tmp.name, "calls")
        stub = os.path.join(self.bin, "xdg-open")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a" >> "$CALLS"; done\nprintf "END\\n" >> "$CALLS"\n')
        os.chmod(stub, 0o755)
        self.env = {"PATH": self.bin + ":/usr/bin:/bin", "CALLS": self.log, "HOME": self.tmp.name}

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, *args):
        return subprocess.run([sys.executable, "-I", TOOL, *args], env=self.env, capture_output=True, text=True, timeout=20)

    def calls(self, wait=True):
        for _ in range(100 if wait else 1):
            if os.path.exists(self.log) and open(self.log).read().endswith("END\n"):
                break
            time.sleep(0.05)
        return open(self.log).read().split("\n") if os.path.exists(self.log) else []

    def test_a_good_host_opens_https_host_only(self):
        r = self.run_tool("open", "docs.python.org")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ["https://docs.python.org", "END", ""])

    def test_every_hostile_input_launches_nothing(self):
        for h in BAD:
            if "\x00" in h:
                continue                                   # an argv cannot carry a NUL; valid_host covers it
            self.assertEqual(self.run_tool("open", h).returncode, 2, repr(h))
        self.assertEqual(self.calls(wait=False), [])

    def test_a_leading_dash_is_not_read_as_an_option(self):
        self.assertEqual(self.run_tool("open", "--help").returncode, 2)
        self.assertEqual(self.run_tool("open", "-h").returncode, 2)
        self.assertEqual(self.calls(wait=False), [])

    def test_bad_arguments(self):
        for args in ([], ["open"], ["open", "a.com", "b.com"], ["launch", "a.com"], ["a.com"]):
            self.assertEqual(self.run_tool(*args).returncode, 2, args)
        self.assertEqual(self.calls(wait=False), [])

    def test_shell_metacharacters_never_reach_a_shell(self):
        self.assertEqual(self.run_tool("open", "a.com;touch pwned").returncode, 2)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "pwned")))

    def test_a_missing_xdg_open_is_a_failure_not_a_crash(self):
        self.env["PATH"] = self.tmp.name
        self.assertEqual(self.run_tool("open", "a.com").returncode, 1)


if __name__ == "__main__":
    unittest.main()
