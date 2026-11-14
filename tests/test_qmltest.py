"""Runs the QtTest files (clicks on the session switcher, the session header, hover tooltips on the map) under qmltestrunner."""
import os
import shutil
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = shutil.which("qmltestrunner") or next(
    (p for p in ("/usr/lib/qt6/bin/qmltestrunner",) if os.access(p, os.X_OK)), None)


@unittest.skipUnless(RUNNER, "qmltestrunner (qt6-declarative) not found")
class QtTestFiles(unittest.TestCase):
    def run_file(self, name):
        env = {**os.environ, "QT_QPA_PLATFORM": "offscreen"}
        run = subprocess.run([RUNNER, "-input", os.path.join(ROOT, "tests", name)],
                             env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_switcher_qml(self):
        self.run_file("switcher.test.qml")

    def test_header_qml(self):
        self.run_file("header.test.qml")

    def test_tooltip_qml(self):
        self.run_file("tooltip.test.qml")

    def test_route_qml(self):
        self.run_file("route.test.qml")

    def test_follow_qml(self):
        self.run_file("follow.test.qml")

    def test_click_qml(self):
        self.run_file("click.test.qml")


if __name__ == "__main__":
    unittest.main()
