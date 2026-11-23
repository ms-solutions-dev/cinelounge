#!/usr/bin/env bash
# Records the answers of the ESPN fixture source for the measurement against the real world.
#
# **Where it goes.** To `intern/aufnahmen/sport/`, not into the check fixtures: the answers
# are verbatim copies of a foreign service and stay private. The checks run on synthetic
# answers of the same form (`intern/fixtures-synth/sport.py` writes them to
# `Packages/PlaylistKit/Tests/PlaylistKitTests/Fixtures/sport/`); a recording here is read
# in addition by `SportRecording.real` when its day is the one the tests know.
#
# **Why record and not query.** No check in this project may go onto the
# network. A check that did would be green or red depending on the time of day,
# the schedule and the provider's mood, and a red one would not say whether the
# source text is broken or it is just the summer break. So it is recorded once,
# stored with a date and calculated against.
#
# **What is recorded.** One request per competition and day, three days ahead —
# exactly the reach the sports area is meant to show. The competition list
# stands in `Packages/Core/Sources/Core/SportCompetition.swift` and is not
# maintained a second time here; it is read from there.
#
# **The cut, and what it costs.** The full answers of the 20 competitions over
# three days are 1.7 MB — too much next to a 795 KB program guide. What is kept is therefore exactly what
# ``ESPNScoreboard`` reads, in the nesting in which ESPN delivers it: the
# competition header (name, short form, ID — the vocabulary for E7) and per
# match the ID, kickoff, state and the four spellings of each team. Everything
# else (odds, crests, links, statistics, stadium) is dropped. **The price,
# named openly:** if ESPN changes a field that is dropped here and that the
# parser is supposed to need tomorrow, it has to be recorded again. A format
# change to the kept fields would, even with the full answer, only show at the
# next recording — the check may not go onto the network either way.
#
# Usage:   scripts/record-espn.sh [YYYY-MM-DD]   (default: today)
set -uo pipefail
cd "$(dirname "$0")/.."

start=${1:-$(date +%Y-%m-%d)}
target="intern/aufnahmen/sport/espn-$start"
mkdir -p "$target"

# The IDs from the one competition board — not from a second list here in the
# script. Exactly the drifting apart of two lists is the finding
# ``SportCompetition`` was set up against.
slugs=$(grep -oE 'path: "[^"]+"' Packages/Core/Sources/Core/SportCompetition.swift \
    | sed 's/path: "//;s/"//')
if [ -z "$slugs" ]; then
    printf '\033[31m✗\033[0m No IDs found in SportCompetition.swift.\n'
    exit 1
fi

days=$(python3 -c "
import datetime
s = datetime.date.fromisoformat('$start')
print(' '.join((s + datetime.timedelta(days=i)).strftime('%Y%m%d') for i in range(3)))
")

errors=0
for day in $days; do
    for slug in $slugs; do
        file="$target/$(echo "$slug" | tr '/' '-')-$day.json"
        raw=$(mktemp)
        code=$(curl -s --max-time 30 -o "$raw" -w '%{http_code}' \
            "https://site.api.espn.com/apis/site/v2/sports/$slug/scoreboard?dates=$day")
        if [ "$code" != "200" ]; then
            # An unknown ID answers with 400 — the case ``FixtureTally`` has to
            # separate from "nothing on this day". It is stored as such, so the
            # check knows it.
            printf '{"fehlschlag": %s}\n' "$code" > "$file"
            printf '  \033[33m!\033[0m %-28s %s  HTTP %s\n' "$slug" "$day" "$code"
            errors=$((errors + 1))
            rm -f "$raw"
            continue
        fi
        python3 - "$raw" "$file" <<'PY'
import json, sys

raw, target = sys.argv[1], sys.argv[2]
d = json.load(open(raw))

def header(l):
    return {k: l[k] for k in ("id", "name", "abbreviation", "midsizeName", "slug") if k in l}

def team(c):
    t = c.get("team", {})
    return {
        "homeAway": c.get("homeAway"),
        "team": {k: t[k] for k in
                 ("abbreviation", "displayName", "shortDisplayName", "name", "location")
                 if k in t},
    }

def match(e):
    w = (e.get("competitions") or [{}])[0]
    kind = (e.get("status") or {}).get("type", {})
    return {
        "id": e.get("id"),
        "date": e.get("date"),
        "name": e.get("name"),
        "shortName": e.get("shortName"),
        "status": {"type": {k: kind[k] for k in ("state", "completed", "description")
                            if k in kind}},
        "competitions": [{"competitors": [team(c) for c in (w.get("competitors") or [])]}],
    }

json.dump(
    {"leagues": [header(l) for l in (d.get("leagues") or [])],
     "events": [match(e) for e in (d.get("events") or [])]},
    open(target, "w"), ensure_ascii=False, indent=1, sort_keys=False)
PY
        count=$(python3 -c "import json;print(len(json.load(open('$file')).get('events') or []))")
        printf '  \033[2m%-28s %s  %3s matches\033[0m\n' "$slug" "$day" "$count"
        rm -f "$raw"
    done
done

printf '\n\033[1m%s\033[0m — %s files, %s\n' "$target" \
    "$(ls "$target" | wc -l | tr -d ' ')" "$(du -sh "$target" | cut -f1)"
[ "$errors" -gt 0 ] && printf '\033[33m%s requests without 200 — stored as failure.\033[0m\n' "$errors"
exit 0
