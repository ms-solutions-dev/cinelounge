#!/bin/bash
# Builds and launches the app in the running simulator.
#
# The reason for its existence is the same as in the TV project: it installs from
# `.dd`, not from the ordinary DerivedData — otherwise you install the state of the
# last Xcode run and hunt for the bug in your own code.
set -uo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '\033[31m✗\033[0m %s\n' "$1"; }

BUNDLE_ID="dev.ms-solutions.cinelounge"
BUILD=1
# **`--large` sets the system font to the largest size** (AP5).
#
# `accessibilityExtraExtraExtraLarge` is the size at which layouts break — and the
# only way to see that is to look. What a script can contribute is the effort
# beforehand: without this line the way leads through Settings → Accessibility →
# Display → Font Size in the simulator, again after every restart. With it, it is one
# word on the same line that launches the app anyway.
#
# **It stays set until someone takes it back** — `./scripts/run.sh --small` does that.
# A switch that undoes itself on exit would be more convenient and would hide that the
# setting belongs to the device and not to this run.
FONT_SIZE=""
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --large)    FONT_SIZE="accessibility-extra-extra-extra-large" ;;
        --small)    FONT_SIZE="large" ;;
    esac
done

# ── Credentials from the environment, not from the source ─────────────
#
# **Finding of 05.09., on screen:** a launch without `CINELOUNGE_SERVER` produced a
# BLACK screen — `CatalogState.tabs` is then empty, and a tab bar without tabs shows
# nothing. That looks like a crash, and you end up hunting for the bug in the view you
# just built.
#
# `simctl launch` does NOT inherit the environment. Whatever the app is meant to see
# must get `SIMCTL_CHILD_` prepended — exactly what this loop does.
#
# This household's Jellyfin server is not recorded here but in
# `~/.jellyfin-claude`; the file is only read when nothing is set.
CREDENTIALS_FILE="$HOME/.jellyfin-claude"
if [ -z "${CINELOUNGE_SERVER:-}" ] && [ -f "$CREDENTIALS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CREDENTIALS_FILE"
    export CINELOUNGE_SERVER="${JELLYFIN_URL:-}"
    export CINELOUNGE_USER="${JELLYFIN_USER_ID:-}"
    export CINELOUNGE_TOKEN="${JELLYFIN_API_KEY:-}"
fi

# The provider — categories and titles of the library. The account allows ONE
# connection; the app therefore only asks once someone opens the categories.
#
# **Two accounts, since 06.09.** The TV simulator carries two lists; the phone only
# knew one, so the second was never to be seen. The second block only takes effect if
# the file names it — whoever has a single account notices nothing.
if [ -z "${CINELOUNGE_XTREAM:-}" ] && [ -f "$HOME/.xtream-claude" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.xtream-claude"
    export CINELOUNGE_XTREAM="${XTREAM_URL:-}"
    export CINELOUNGE_XTREAM_USER="${XTREAM_USER:-}"
    export CINELOUNGE_XTREAM_PASS="${XTREAM_PASS:-}"
    export CINELOUNGE_XTREAM2="${XTREAM2_URL:-}"
    export CINELOUNGE_XTREAM2_USER="${XTREAM2_USER:-}"
    export CINELOUNGE_XTREAM2_PASS="${XTREAM2_PASS:-}"
    export CINELOUNGE_XTREAM2_NAME="${XTREAM2_NAME:-}"
fi

# The portals — **asked for, not assumed.**
#
# Unlike the Jellyfin server and the provider, they need no credentials: the bridge
# sits under its name on the home network. What was missing was the **information that
# they exist** — `SourceAssembly.state()` only switches the tab on once the setup has
# asked for it or this variable is set, and on the simulator the Keychain is empty.
# Without these lines the portals tab was never to be seen on the simulator, even
# though the bridge answered.
#
# **We ask instead of setting.** Whoever set the variable unconditionally would get the
# tab even where no service runs — and then a screen that loads and finds nothing.
#
# **The CineLounge server takes precedence (12.09.2026), and this finding came from the
# product owner.** Only the bridge was queried here, so after the whole migration the app
# in the simulator still showed "An old-style CL-Server answers at this address. It
# knows no people — there is nothing to sign in to." The build was new, the target was
# old — and from the outside that looks like a build that did not arrive. The queries now
# run in the order you mean them: the server first, then the bridge as a fallback.
if [ -z "${CINELOUNGE_PORTALE:-}" ] && [ -f "$HOME/.cinelounge-server" ]; then
    # The candidates are in ~/.cinelounge-server, one base address per line (AP85,
    # 08.11.2026) — like the team ID in ~/.cinelounge-team, not in the repo. The CL-Server
    # answers on `/.well-known/cinelounge`, the old bridge on `/portale`.
    while IFS= read -r BASE; do
        BASE="${BASE%/}"
        [ -z "$BASE" ] && continue
        if curl -sf -m 2 -o /dev/null "$BASE/.well-known/cinelounge" 2>/dev/null \
            || curl -sf -m 2 -o /dev/null "$BASE/portale" 2>/dev/null; then
            export CINELOUNGE_PORTALE="$BASE"
            break
        fi
    done < "$HOME/.cinelounge-server"
fi

# The ratings key lives in the Keychain on the TV; on the simulator it is empty, and
# then the detail page shows only the number from the Jellyfin server.
if [ -z "${CINELOUNGE_OMDB:-}" ] && [ -f "$HOME/.omdb-claude" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.omdb-claude"
    export CINELOUNGE_OMDB="${OMDB_API_KEY:-}"
fi
for name in CINELOUNGE_SERVER CINELOUNGE_USER CINELOUNGE_TOKEN CINELOUNGE_OMDB \
    CINELOUNGE_TMDB CINELOUNGE_AUFENTHALT CINELOUNGE_REITER CINELOUNGE_TITEL \
    CINELOUNGE_SPIELER CINELOUNGE_SPIELER_HERKUNFT CINELOUNGE_SPIELER_AB \
    CINELOUNGE_XTREAM CINELOUNGE_XTREAM_USER CINELOUNGE_XTREAM_PASS \
    CINELOUNGE_XTREAM_NAME CINELOUNGE_XTREAM2 CINELOUNGE_XTREAM2_USER \
    CINELOUNGE_XTREAM2_PASS CINELOUNGE_XTREAM2_NAME \
    CINELOUNGE_PORTALE CINELOUNGE_VORRAT CINELOUNGE_PROBE CINELOUNGE_ZUSTAND CINELOUNGE_PROGRAMM CINELOUNGE_LIVE CINELOUNGE_SUCHE CINELOUNGE_ANSICHT CINELOUNGE_BLATT CINELOUNGE_SYNCHRO CINELOUNGE_OHNE_NETZ CINELOUNGE_VORRAT_LEGEN \
    CINELOUNGE_KOMPAKT; do
    value=$(eval "printf '%s' \"\${$name:-}\"")
    [ -n "$value" ] && export "SIMCTL_CHILD_$name=$value"
done

step "Finding the simulator"
DEVICE=$(xcrun simctl list devices booted | grep -oE '\(([0-9A-F-]{36})\)' | head -1 | tr -d '()')
if [ -z "$DEVICE" ]; then
    bad "No simulator is running."
    printf '  Start one: xcrun simctl boot "iPhone 16 Pro" && open -a Simulator\n'
    exit 1
fi
ok "$DEVICE"

if [ "$BUILD" = 1 ]; then
    step "Building"
    xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
        -destination "id=$DEVICE" -derivedDataPath .dd -quiet build || exit 1
    ok "built"
fi

APP=".dd/Build/Products/Debug-iphonesimulator/CineLounge.app"
[ -d "$APP" ] || { bad "$APP is missing"; exit 1; }

step "Installing and launching"
# **The point in time before the launch, for the log step below.** A window ("the last
# 30 seconds") also sees the previous run — on the first attempt the step therefore
# reported an error that was already fixed. We read from here on, not from earlier.
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
if [ -n "$FONT_SIZE" ]; then
    xcrun simctl ui "$DEVICE" content_size "$FONT_SIZE" 2>/dev/null \
        && ok "System font: $FONT_SIZE" \
        || bad "Could not set the font size"
fi
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null
xcrun simctl install "$DEVICE" "$APP" || exit 1
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" || exit 1
ok "running — build time of the program: $(date -r "$APP/CineLounge" '+%H:%M:%S' 2>/dev/null || echo unknown)"
if [ -n "${SIMCTL_CHILD_CINELOUNGE_SERVER:-}" ]; then
    ok "Jellyfin server passed through from the environment"
else
    bad "Without CINELOUNGE_SERVER the app stays empty — no catalog, no tabs."
fi
if [ -n "${SIMCTL_CHILD_CINELOUNGE_PORTALE:-}" ]; then
    ok "Portals bridge found — the tab is there"
else
    printf '  No portals bridge on the home server (port 8099) — the tab stays away.\n'
fi

# ── What only the system log says ─────────────────────────────────────
#
# **The finding of 07.09., and it cost a whole evening.** The wrapper attached
# `navigationDestination(for:)` to the `NavigationStack` **itself** instead of to its
# content. It was thereby silently ignored, and **every** step in the settings ended on
# SwiftUI's placeholder "no destination found" — a black screen with a yellow triangle.
#
# **The compiler stayed silent, `check.sh` stayed green, all 465 checks passed.** The
# sentence appeared nowhere but here:
#
#   "There's a misplaced navigationDestination(for:destination:) modifier for type
#    ViewID. It will be ignored."
#
# SwiftUI reports its misconfigurations **at runtime and only into the system log** —
# misplaced destinations, duplicate identifiers in a `ForEach`, `@State` in the wrong
# place. Nobody reads that log on their own. So this script reads it.
#
# **And that is why the test hook pushes.** On the first attempt this step stood here
# and reported "clean" although the error was still in: the message only arises **on the
# first push**, and the app starts on the Home screen. With
# `CINELOUNGE_ANSICHT=einstellungen,senderlisten` it creates a root **and** pushes onto
# it — then there is something SwiftUI can complain about.
step "SwiftUI messages"
sleep 3
LOG=$(xcrun simctl spawn "$DEVICE" log show --start "$SINCE" \
    --predicate "processImagePath CONTAINS \"CineLounge\" AND category CONTAINS \"Invalid\"" \
    --style compact 2>/dev/null | grep "SwiftUI" || true)
MESSAGES=$(printf '%s' "$LOG" | grep -c . || true)
if [ "${MESSAGES:-0}" -gt 0 ]; then
    printf '%s\n' "$LOG" | sed 's/^/    /' | head -5
    bad "$MESSAGES SwiftUI misconfiguration(s) — they break nothing and show nothing"
else
    ok "no SwiftUI misconfiguration in the log"
fi
