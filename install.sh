#!/bin/sh
# Install roundhouse: shows every change and asks first. See ./install.sh --help, and README "Install".
exec python3 -I "$(dirname "$(readlink -f "$0")")/tools/setup.py" install "$@"
