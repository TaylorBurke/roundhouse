#!/usr/bin/python3 -I
"""Move a roundhouse window to a workspace, without taking the focus.

  follow.py TITLE WORKSPACE

Used when the terminal a session runs in changes workspace: the session's window, found by its
exact title and the Quickshell app id, goes along. Does nothing if no such window exists or it is
already there, and never touches a window that is not a roundhouse window. Only a Hyprland window
address that matched the pattern below, and a whole number, ever reach the command.
"""
import json
import re
import subprocess
import sys

APP_CLASS = "org.quickshell"
ADDRESS = re.compile(r"0x[0-9a-f]{1,16}")


def pick(clients, title, workspace):
    """Addresses of the roundhouse windows titled `title` that are not on `workspace` yet."""
    out = []
    for c in clients if isinstance(clients, list) else []:
        if not isinstance(c, dict) or c.get("class") != APP_CLASS or c.get("title") != title or not c.get("mapped", True):
            continue
        ws = c.get("workspace")
        if isinstance(ws, dict) and ws.get("id") == workspace:
            continue
        address = c.get("address")
        if isinstance(address, str) and ADDRESS.fullmatch(address):
            out.append(address)
    return out


def dispatch_for(address, workspace):
    return f'hl.dsp.window.move({{ workspace = "{int(workspace)}", follow = false, window = "address:{address}" }})'


def main(argv):
    if len(argv) != 2 or not argv[0].startswith("roundhouse") or not re.fullmatch(r"[1-9][0-9]{0,5}", argv[1]):
        print("usage: follow.py TITLE WORKSPACE   (a roundhouse window title, a workspace id)", file=sys.stderr)
        return 2
    title, workspace = argv[0], int(argv[1])
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], timeout=3))
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1
    for address in pick(clients, title, workspace):
        subprocess.run(["hyprctl", "dispatch", dispatch_for(address, workspace)], check=False, timeout=3,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
