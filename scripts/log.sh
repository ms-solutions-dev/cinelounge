#!/usr/bin/env bash
# Fetch the app's log from the simulator.
#
# Why this script exists: `log show` shows ONLY errors by default. The course of a
# playback sits at the "info" level and is therefore missing for exactly the person
# looking for it — a debugging session once ended with an empty log and the
# conclusion that the app reports nothing. The `--info` switch is hard-wired here
# so that nobody can forget it.
#
#   ./scripts/log.sh          last 15 minutes
#   ./scripts/log.sh 60m      last hour
#   ./scripts/log.sh -f       follow live
set -uo pipefail

SUBSYSTEM='dev.ms-solutions.cinelounge'
DEVICE=${CINELOUNGE_SIM:-booted}

# The playback trace first, then the network fetches: When searching for "why does
# this not play", the sequence is the information, and the fetches are the by-catch.
PREDICATE="subsystem == \"$SUBSYSTEM\""

if [ "${1:-}" = "-f" ]; then
    echo "▸ Live log — stop with Ctrl-C"
    exec xcrun simctl spawn "$DEVICE" log stream \
        --info --predicate "$PREDICATE" --style compact
fi

SPAN=${1:-15m}
echo "▸ Log of the last $SPAN"
xcrun simctl spawn "$DEVICE" log show \
    --last "$SPAN" --info --predicate "$PREDICATE" --style compact 2>/dev/null \
    | grep -v "^getpwuid_r" \
    | sed -e 's/dev\.ms-solutions\.cinelounge://' -e 's/CineLounge\[[0-9:a-f]*\]//'
