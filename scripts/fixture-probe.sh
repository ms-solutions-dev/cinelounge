#!/usr/bin/env bash
# The schedule probe: what does the filter chain make of a real
# program guide?
#
# **What the script is for.** `swift test` shows numbers only when an expectation
# breaks — while building the filters one wants to see them, precisely BECAUSE
# they are still right. The script calls the same calculation the checks call,
# and lays its report out in the open.
#
# **The fixed clock.** The probe calculates on 29.08.2026, Europe/Berlin —
# the day the recording was made. `Core` itself is clock-free; the clock
# sits exclusively in the probe. Without it the same file measures something
# different tomorrow, and then a changed number no longer says whether it was
# the change or the calendar. That is why it stands in the test bench as a
# constant and not as a call parameter: a clock one can adjust gets adjusted.
#
# Usage:
#   scripts/fixture-probe.sh                 — on the recording in the check fixtures
#   scripts/fixture-probe.sh /path/epg.xml   — additionally on a foreign guide
#
# The second form feeds `CINELOUNGE_EPG` and thus wakes the otherwise skipped
# check in SportProbeTests. It calculates on TODAY, not on 29.08. — it is the
# look at fresh data, not the test bench.
set -uo pipefail
cd "$(dirname "$0")/.."

foreign=${1:-}

printf '\n\033[1m▸ Probe on the recording of 29.08.2026\033[0m\n'
out=$( (cd Packages/PlaylistKit && swift test --filter SchedulePrototypeTests 2>&1) )
printf '%s\n' "$out" | sed -n '/^Probe /,/^✔ Test "The stages/p' | grep -v '^✔'
printf '%s\n' "$out" | grep -E "✘|Expectation failed|Test run with" | sed 's/^/  /'

if [ -n "$foreign" ]; then
    if [ ! -f "$foreign" ]; then
        printf '\n\033[31m✗\033[0m %s does not exist.\n' "$foreign"
        exit 1
    fi
    printf '\n\033[1m▸ Probe on %s (clock: today)\033[0m\n' "$foreign"
    foreign_abs=$(cd "$(dirname "$foreign")" && pwd)/$(basename "$foreign")
    out=$( (cd Packages/PlaylistKit \
        && CINELOUNGE_EPG="$foreign_abs" swift test --filter SportProbeTests 2>&1) )
    printf '%s\n' "$out" | grep -E "^Probe:|^  |Test run with|✘" | grep -v '^  *$'
fi
