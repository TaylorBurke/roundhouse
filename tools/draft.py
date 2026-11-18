#!/usr/bin/python3 -I
"""Type a draft prompt into a session's terminal. Never presses Enter or any other key.

  draft.py type ADDRESS TEXT

This is keystroke injection, so it is kept small and refuses by default:
  1. ADDRESS must look like a Hyprland window address (0x, then lower-case hex);
  2. TEXT must be 1-300 characters (code points) with no control, format (bidi, zero-width), private-use
     or line-break characters;
  3. the window is focused, and `hyprctl activewindow` must then report exactly ADDRESS (checked for
     up to a second) and once more right before typing; otherwise nothing is typed;
  4. the typing is `wtype -- TEXT` run with a list of arguments, never through a shell.
A refusal prints one line to stderr and exits non-zero; success prints nothing.

Exit status: 0 typed, 1 refused or failed, 2 bad usage.
"""
import json
import re
import shutil
import subprocess
import sys
import time
import unicodedata

ADDRESS = re.compile(r"0x[0-9a-f]+")
MAX_TEXT = 300
FOCUS_WAIT = 1.0          # seconds to wait for the focus to land
BAD_CATEGORIES = ("Cc", "Cf", "Co", "Cs", "Zl", "Zp")   # control, format (bidi, zero-width), private use, surrogate, line and paragraph separators


def bad_text(text):
    """Why `text` may not be typed, or None."""
    if not text:
        return "empty draft"
    if len(text) > MAX_TEXT:
        return "draft longer than %d characters" % MAX_TEXT
    if any(unicodedata.category(c) in BAD_CATEGORIES for c in text):
        return "draft contains a control, format or other invisible character"
    return None


def active_address():
    try:
        out = subprocess.run(["hyprctl", "activewindow", "-j"], capture_output=True, text=True, timeout=3).stdout
        win = json.loads(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    addr = win.get("address") if isinstance(win, dict) else None
    return addr if isinstance(addr, str) else None


def focus_lands(address):
    subprocess.run(["hyprctl", "dispatch", "hl.dsp.focus({ window = 'address:%s' })" % address],
                   capture_output=True, timeout=3)
    deadline = time.monotonic() + FOCUS_WAIT
    while True:
        if active_address() == address:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def type_draft(address, text):
    """None when typed, else the reason it was refused."""
    if not ADDRESS.fullmatch(address):
        return "not a window address"
    why = bad_text(text)
    if why:
        return why
    if not shutil.which("wtype"):
        return "wtype is not installed"
    try:
        if not focus_lands(address):
            return "the terminal did not take the focus; nothing typed"
        if active_address() != address:        # the last look, right before typing
            return "the active window changed; nothing typed"
        done = subprocess.run(["wtype", "--", text], capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return "could not run hyprctl or wtype"
    return None if done.returncode == 0 else "wtype failed"


def main(argv):
    if len(argv) != 3 or argv[0] != "type":
        print("usage: draft.py type ADDRESS TEXT", file=sys.stderr)
        return 2
    why = type_draft(argv[1], argv[2])
    if why:
        print("Draft not typed: " + why, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
