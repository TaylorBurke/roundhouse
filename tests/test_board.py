"""Runs tests/board.test.qml (the board.js fold logic) under qml6, so `unittest discover` covers it."""
import os
import shutil
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@unittest.skipUnless(shutil.which("qml6"), "qml6 (qt6-declarative) not installed")
class BoardLogic(unittest.TestCase):
    def test_board_js(self):
        env = {**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_FORCE_STDERR_LOGGING": "1"}
        run = subprocess.run(["qml6", "-a", "core", os.path.join(ROOT, "tests", "board.test.qml")],
                             env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("all passed", run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
