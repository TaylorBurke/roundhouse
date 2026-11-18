#!/usr/bin/python3 -I
"""Open a host in the browser: https://<host>, nothing else.

  openhost.py open HOST

HOST must be a plain hostname (letters, digits, hyphens and dots; at least one dot; no label starting
or ending with a hyphen; non-ASCII names only as punycode, xn--...). Anything else (spaces, a scheme,
a path, a port, a login, a leading '-', control characters) is refused. The check is made here, again,
whatever the caller already did. The host goes to `xdg-open` as one list argument, never through a shell.

Exit status: 0 handed to xdg-open, 2 bad arguments or a host that is not a plain hostname.
"""
import re
import subprocess
import sys

_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
_HOST = re.compile(_LABEL + r"(?:\." + _LABEL + r")+", re.ASCII)


def valid_host(host):
    return isinstance(host, str) and len(host) <= 253 and _HOST.fullmatch(host) is not None


def main(argv):
    if len(argv) != 3 or argv[1] != "open" or not valid_host(argv[2]):
        print("usage: openhost.py open HOST (a plain hostname)", file=sys.stderr)
        return 2
    try:
        subprocess.Popen(["xdg-open", "https://" + argv[2]], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
