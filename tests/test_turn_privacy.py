"""The Model turn panel shows reasoning on screen only: the QML never builds a command from transcript text,
never runs a shell, and never logs or writes what it read. Static checks over the UI sources."""
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf8") as f:
        return f.read()


def function_body(src, name):
    start = src.index("function " + name + "(")
    depth, i = 0, src.index("{", start)
    for j in range(i, len(src)):
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        if depth == 0:
            return src[start:j + 1]
    raise AssertionError(name)


class TurnPanelNeverRunsTranscriptText(unittest.TestCase):
    def setUp(self):
        self.window = read("ui", "RoundhouseWindow.qml")
        self.turn_js = read("ui", "turn.js")
        self.panel = read("ui", "TurnPanel.qml")

    def test_commands_are_built_from_the_session_id_only(self):
        for name in ("turnArgs", "openArgs"):
            self.assertRegex(function_body(self.turn_js, name), r"^function \w+\(script, sid\) \{ return \[\"python3\", \"-I\", script, \"\w+\", sid\]; \}$")
        for name in ("showTurn", "openTranscript"):
            body = function_body(self.window, name)
            self.assertIn("shownSid", body)
            self.assertNotIn("turnView", body)
            self.assertTrue(re.search(r"Turn\.(turn|open)Args\(Quickshell\.shellPath\(\"\.\./tools/transcript\.py\"\), shownSid\)", body), name)

    def test_the_answer_is_only_parsed_and_shown(self):
        body = function_body(self.window, "turnAnswered")
        for bad in ("execDetached", "Process", "command", "createObject", "console."):
            self.assertNotIn(bad, body)
        self.assertIn("Turn.parse(text)", body)

    def test_no_shell_and_no_logging_in_the_turn_code(self):
        code = self.turn_js + self.panel + function_body(self.window, "showTurn") + function_body(self.window, "openTranscript") \
            + function_body(self.window, "turnAnswered")
        for bad in ("bash", "\"sh\"", "-c\"", "eval(", "console.", "FileView", "Qt.openUrlExternally", "Quickshell.exec(", "localStorage"):
            self.assertNotIn(bad, code)

    def test_the_panel_runs_nothing_and_shows_plain_text(self):
        self.assertNotRegex(self.panel, r"Process|execDetached|Quickshell|import \"")
        for m in re.finditer(r"Text \{[^}]*?\}", self.panel, re.S):
            if "text:" in m.group(0):
                self.assertIn("Text.PlainText", m.group(0))

    def test_the_reasoning_is_cleared_whenever_the_panel_is_left(self):
        m = re.search(r"onListModeChanged: \{(.*?)\n    \}", self.window, re.S)
        self.assertIsNotNone(m)
        self.assertIn('if (listMode !== "turn") turnView = ({ steps: [], note: "", summary: "" })', m.group(1))

    def test_what_is_kept_is_cleared_on_close(self):
        self.assertIn("turnView = ({ steps: [], note: \"\", summary: \"\" })", function_body(self.window, "closeList"))


if __name__ == "__main__":
    unittest.main()
