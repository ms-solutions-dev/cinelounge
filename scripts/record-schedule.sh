#!/usr/bin/env bash
# Records the answer of a broadcast-schedule source for the measurement against the real
# world — to `intern/aufnahmen/sport/`, which stays private like the recordings of
# `record-espn.sh`. The checks run on the synthetic page of `intern/fixtures-synth/sport.py`.
#
# **Why record and not query.** The same house rule as with
# `record-espn.sh`: no check in this project may go onto the network.
#
# **What is recorded.** The page carries its daily schedule twice in the source
# text, and both places are needed:
#
#   * `window.__INITIAL_STATE__` — the state of the application. Per
#     broadcast it names **sport, competition, kind (match or show)**, kickoff,
#     teams and channel. That is the richer source.
#   * `<script type="application/ld+json">` — the same broadcasts as
#     `schema.org` data. They additionally name the **end** of the broadcast,
#     which is missing in the state.
#
# What is recorded is a **reduced page** with exactly these two blocks, each
# cut down to the fields that are read. So the same parser runs in the check as
# on the TV; the full page would be 2 MB.
#
# **Today only.** The day tabs (`/home/day/YYYY-MM-DD`) are filled only in the
# browser: under each of these addresses the server delivers today's schedule,
# down to the page title. Reproduced on 29.08. for the 30th and the 31st — both
# times the 163 entries of 29.08.
#
# Usage:   scripts/record-schedule.sh [YYYY-MM-DD]   (default: today)
set -uo pipefail
cd "$(dirname "$0")/.."

day=${1:-$(date +%Y-%m-%d)}
target="intern/aufnahmen/sport/sendeplan-tr-$day.html"
mkdir -p "$(dirname "$target")"

raw=$(mktemp)
trap 'rm -f "$raw"' EXIT

if ! curl -sS -m 30 -A "Mozilla/5.0 (Macintosh)" -o "$raw" "https://www.sporekrani.com/"; then
    printf '\033[31m✗\033[0m The source does not answer.\n'
    exit 1
fi

python3 - "$raw" "$target" <<'PY'
import json, re, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()

blocks = re.findall(
    r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>', raw, re.S
)
if not blocks:
    print("✗ No ld+json block — the page has changed its shape.")
    raise SystemExit(1)
if "window.__INITIAL_STATE__" not in raw:
    print("✗ No __INITIAL_STATE__ — the page has changed its shape.")
    raise SystemExit(1)

start = raw.index("window.__INITIAL_STATE__")
start = raw.index("=", start) + 1
state, _ = json.JSONDecoder().raw_decode(raw[start:].lstrip())
events = state["common"]["events"]


def channels(entry):
    """The channel names — the source writes one or a list."""
    value = entry.get("publishedOn")
    if isinstance(value, dict):
        value = [value]
    if not isinstance(value, list):
        return []
    return [x.get("name") for x in value if isinstance(x, dict) and x.get("name")]


narrow_ld = []
for entry in json.loads(blocks[0]):
    match = entry.get("broadcastOfEvent") or {}
    if not isinstance(match, dict):
        continue
    narrow_ld.append(
        {
            "publishedOn": [{"name": n} for n in channels(entry)],
            "broadcastOfEvent": {
                "name": match.get("name"),
                "startDate": match.get("startDate"),
                "endDate": match.get("endDate"),
            },
        }
    )

fields = (
    "sport_name", "league_name", "event_type_name", "name", "date_time",
    "home_name", "away_name",
)
narrow_state = {
    "common": {
        "events": [
            {
                **{f: e.get(f) for f in fields},
                "channels": [
                    {"name": k.get("name"), "active": k.get("active")}
                    for k in (e.get("channels") or [])
                ],
            }
            for e in events
        ]
    }
}

page = (
    "<!doctype html><html><head>\n"
    '<script type="application/ld+json">'
    + json.dumps(narrow_ld, ensure_ascii=False)
    + "</script>\n<script>window.__INITIAL_STATE__ = "
    + json.dumps(narrow_state, ensure_ascii=False)
    + "</script>\n</head><body></body></html>\n"
)
open(sys.argv[2], "w", encoding="utf-8").write(page)

matches = sum(1 for e in events if e.get("event_type_name") == "match")
with_channel = sum(1 for e in events if e.get("channels"))
print(
    f"✓ {len(events)} broadcasts recorded, of them {matches} matches "
    f"and {with_channel} with a channel."
)
PY
printf '  %s\n' "$target"
