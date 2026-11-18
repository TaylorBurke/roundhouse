#!/usr/bin/python3 -I
"""The browser windows on the desktop, and focusing one (a click on Browser).

  browserwin.py list              prints [{"address", "title", "class", "pid", "devtools"}, ...] (JSON)
  browserwin.py focus ADDRESS     focuses that window, if it is still one of the browser windows

`list` reads `hyprctl clients -j` (the Hyprland of the environment it runs in, as the session header's
terminal focus does) and keeps the mapped windows whose class is a known browser. `devtools` is true
when the window's process was started by chrome-devtools-mcp (its command line is read from /proc,
only to look for that name, and is never printed). Titles are page titles: they are printed for
the window to show and are never stored. `focus` checks the address (0x + hex) and that it is in the
current list before it runs one hyprctl dispatch, with a list argv and no shell.

Exit status: 0 done, 1 hyprctl failed, 2 bad arguments or not a browser window.
"""
import json
import os
import re
import subprocess
import sys

ADDRESS = re.compile(r"0x[0-9a-f]{1,16}")
BROWSER = re.compile(r"chrom|firefox|brave|vivaldi|opera|librewolf|floorp|^zen$|zen-browser|epiphany|falkon|"
                     r"microsoft-edge|msedge|waterfox|tor-browser|qutebrowser|thorium", re.I)
PROC = os.environ.get("BROWSERWIN_PROC") or "/proc"     # tests point this at a fake tree
DEVTOOLS = b"chrome-devtools-mcp"


def is_browser(klass):
    return isinstance(klass, str) and bool(BROWSER.search(klass))


def is_devtools(pid):
    try:
        with open(os.path.join(PROC, str(int(pid)), "cmdline"), "rb") as f:
            return DEVTOOLS in f.read(65536)
    except (OSError, ValueError, TypeError):
        return False


def clients():
    return json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], timeout=3))


def windows(raw):
    out = []
    for c in raw if isinstance(raw, list) else []:
        if not isinstance(c, dict) or not c.get("mapped", True) or not is_browser(c.get("class")):
            continue
        address, pid = c.get("address"), c.get("pid")
        if not isinstance(address, str) or not ADDRESS.fullmatch(address):
            continue
        pid = pid if isinstance(pid, int) and not isinstance(pid, bool) else 0
        title = c.get("title")
        out.append({"address": address, "title": title if isinstance(title, str) else "", "class": c["class"],
                    "pid": pid, "devtools": is_devtools(pid) if pid else False})
    return out


def main(argv):
    if argv == ["list"]:
        try:
            found = windows(clients())
        except (OSError, ValueError, subprocess.SubprocessError):
            return 1
        print(json.dumps(found))
        return 0
    if len(argv) == 2 and argv[0] == "focus" and ADDRESS.fullmatch(argv[1]):
        try:
            known = [w["address"] for w in windows(clients())]
        except (OSError, ValueError, subprocess.SubprocessError):
            return 1
        if argv[1] not in known:
            return 2
        r = subprocess.run(["hyprctl", "dispatch", "hl.dsp.focus({ window = 'address:" + argv[1] + "' })"],
                           check=False, timeout=3, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0 if r.returncode == 0 else 1
    print("usage: browserwin.py list | focus ADDRESS", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
