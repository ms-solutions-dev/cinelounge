#!/bin/bash
# Fetches the log from the simulator.
#
# `--info` is hard-wired so that nobody can forget it: without the switch `log show`
# shows only errors, and the sequence of steps before them is exactly what explains a
# playback failure.
set -uo pipefail
SIM="${CINELOUNGE_SIM:-$(xcrun simctl list devices booted | grep -oE '\(([0-9A-F-]{36})\)' | head -1 | tr -d '()')}"
[ -z "$SIM" ] && { echo "No simulator is running."; exit 1; }
PREDICATE='subsystem == "dev.ms-solutions.cinelounge"'

if [ "${1:-}" = "-f" ]; then
    exec xcrun simctl spawn "$SIM" log stream --level info --predicate "$PREDICATE" --style compact
fi
exec xcrun simctl spawn "$SIM" log show --last "${1:-15m}" --info --predicate "$PREDICATE" --style compact
