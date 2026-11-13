#!/usr/bin/python3 -I
"""Move a session's roundhouse window to a workspace, without taking the focus.

  follow.py SID WORKSPACE

Used when the terminal a session runs in changes workspace: the session's window goes along. The
window is found by the Quickshell app id and by the session id that ends its title
(`roundhouse: <folder> · <sid>`), not by the whole title, so a folder name that changes at the same
moment cannot make it miss. Does nothing if there is no such window or it is already there, and
never touches a window that is not a roundhouse window. Only a Hyprland window address that
matched the pattern below, and a whole number, ever reach the command.

Exit status: 0 done (or nothing to do), 1 Hyprland could not be read, 2 bad arguments.
"""
import json
import re
import subprocess
import sys

APP_CLASS = "org.quickshell"
TITLE_START = "roundhouse: "
SEPARATOR = " · "          # between the folder and the session id; ui/RoundhouseWindow.qml builds the title
ADDRESS = re.compile(r"0x[0-9a-f]{1,16}")
SID = re.compile(r"[A-Za-z0-9_-]{8}")


def pick(clients, sid, workspace):
    """Addresses of the windows of session `sid` that are not on `workspace` yet."""
    out = []
    for c in clients if isinstance(clients, list) else []:
        if not isinstance(c, dict) or c.get("class") != APP_CLASS or not c.get("mapped", True):
            continue
        title = c.get("title")
        if not isinstance(title, str) or not title.startswith(TITLE_START) or not title.endswith(SEPARATOR + sid):
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
    if len(argv) != 2 or not SID.fullmatch(argv[0]) or not re.fullmatch(r"[1-9][0-9]{0,5}", argv[1]):
        print("usage: follow.py SID WORKSPACE   (an 8-character session id, a workspace id)", file=sys.stderr)
        return 2
    sid, workspace = argv[0], int(argv[1])
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], timeout=3))
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1
    for address in pick(clients, sid, workspace):
        subprocess.run(["hyprctl", "dispatch", dispatch_for(address, workspace)], check=False, timeout=3,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
