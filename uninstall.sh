#!/bin/sh
# Remove what install.sh added: shows every change and asks first. See README "Uninstall".
exec python3 -I "$(dirname "$(readlink -f "$0")")/tools/setup.py" uninstall "$@"
