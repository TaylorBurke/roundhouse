"""Runs tests/switcher.test.qml (clicks on the session switcher) under qmltestrunner."""
import os
import shutil
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = shutil.which("qmltestrunner") or next(
    (p for p in ("/usr/lib/qt6/bin/qmltestrunner",) if os.access(p, os.X_OK)), None)


@unittest.skipUnless(RUNNER, "qmltestrunner (qt6-declarative) not found")
class SessionSwitcher(unittest.TestCase):
    def test_switcher_qml(self):
        env = {**os.environ, "QT_QPA_PLATFORM": "offscreen"}
        run = subprocess.run([RUNNER, "-input", os.path.join(ROOT, "tests", "switcher.test.qml")],
                             env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
