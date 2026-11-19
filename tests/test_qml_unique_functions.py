"""A QML component refuses to load when two functions share a name ("Duplicate method name"),
which happened when two parallel branches each added openTranscript(). Catch it without a display."""
import collections
import pathlib
import re
import unittest

UI = pathlib.Path(__file__).resolve().parent.parent / "ui"


class QmlFunctionNamesAreUnique(unittest.TestCase):
    def test_no_function_is_declared_twice_in_one_qml_file(self):
        for path in sorted(UI.glob("*.qml")):
            names = re.findall(r"^\s*function\s+(\w+)\s*\(", path.read_text(), re.M)
            dupes = [n for n, c in collections.Counter(names).items() if c > 1]
            self.assertEqual(dupes, [], path.name)


if __name__ == "__main__":
    unittest.main()
