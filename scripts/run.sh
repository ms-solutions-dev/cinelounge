#!/bin/bash
#
# Installs the app in the running simulator and starts it.
#
# This file exists for one reason: The build via `check.sh` lands in `.dd`,
# because it is built with `-derivedDataPath .dd`. Whoever installs from the usual
# DerivedData directory instead gets the state of the last Xcode run — possibly
# hours old. That is exactly what happened: Half a working day went into hunting
# two bugs that had long been fixed, because the old app was always the one being
# checked.
#
# That is why the path is fixed correctly here once and not typed by hand every
# time.
#
#   ./scripts/run.sh                  build, install, start
#   ./scripts/run.sh --probe sidebar  start with a probe screen instead of the app
#   ./scripts/run.sh --no-build       only install and start
#
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".dd/Build/Products/Debug-appletvsimulator"
BUNDLE="dev.ms-solutions.cinelounge"
PROBE=""
DO_BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --probe) PROBE="${2:-}"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

# ── Device ───────────────────────────────────────────────────────────────────
#
# **The first running simulator listed is not necessarily an Apple TV.** On
# 2026-09-12 two iPhone simulators of the sister project stood next to it, and
# `head -1` took one of them: Installing a tvOS app on an iPhone fails, and the
# message does not name the reason. So among the RUNNING devices the tvOS section
# is looked up explicitly.
DEVICE=$(xcrun simctl list devices booted 2>/dev/null \
    | awk '/^-- tvOS/{inside=1; next} /^-- /{inside=0} inside' \
    | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$DEVICE" ]; then
    bad "No Apple TV simulator booted — boot one first."
    if xcrun simctl list devices booted 2>/dev/null | grep -qE '[0-9A-F-]{36}'; then
        printf '  \033[2mOther simulators are running; an iPhone does not accept this app.\033[0m\n'
    fi
    exit 1
fi
ok "Simulator $DEVICE"

# ── Build ────────────────────────────────────────────────────────────────────
if [ "$DO_BUILD" -eq 1 ]; then
    step "Build"
    if xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
        -destination "id=$DEVICE" -derivedDataPath .dd -quiet build >/tmp/cinelounge-build.log 2>&1
    then
        ok "built"
    else
        bad "Build failed:"
        grep -E "error:" /tmp/cinelounge-build.log | head -10
        exit 1
    fi
fi

APP="$BUILD_DIR/CineLounge.app"
if [ ! -d "$APP" ]; then
    bad "Nothing under $APP — run without --no-build first."
    exit 1
fi

# Write down the age. Whoever does not see a change recognizes here first whether
# the new state is running at all.
step "Install"
printf '  Build time: %s\n' "$(stat -f '%Sm' -t '%d.%m. %H:%M:%S' "$APP/CineLounge")"

xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1
if xcrun simctl install "$DEVICE" "$APP" >/dev/null 2>&1; then
    ok "installed"
else
    bad "Installation failed"
    exit 1
fi

# ── Pass the portal service through ──────────────────────────────────────────
#
# **On the TV the address lives in the Keychain, and a fresh simulator has an empty
# one.** It would therefore have to be entered via the TV keyboard before there is
# anything to check at all — and again for every new simulator. On the evening of
# 2026-09-12 that blocked the first test attempt of the server switchover: The
# simulator still held `https://portale.example:8099` from an old session, both
# services listen in plain text, and the screen thus looked like before the
# switchover.
#
# **First the server, then the bridge** — in the order one means it. The same as
# in the sister project, and it also says there why: A new state against an old
# target looks from the outside like a build that did not arrive.
#
# `BridgeAddress.effective` takes the value only as a FALLBACK — what is in the
# field wins. So the hook never explains why a device asks somewhere else.
if [ -z "${CINELOUNGE_PORTALE:-}" ] && [ -f "$HOME/.cinelounge-server" ]; then
    # The candidates are in ~/.cinelounge-server, one base address per line (AP85,
    # 2026-11-08) — like the team ID in ~/.cinelounge-team, not in the repo. The
    # CL-Server answers on `/.well-known/cinelounge`, the old bridge on `/portale`.
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
if [ -n "${CINELOUNGE_PORTALE:-}" ]; then
    ok "Portal service: $CINELOUNGE_PORTALE"
else
    printf '  \033[33m⚠\033[0m No portal service reachable — the section stays empty.\n'
fi

for name in CINELOUNGE_PORTALE CINELOUNGE_START; do
    value=$(eval "printf '%s' \"\${$name:-}\"")
    [ -n "$value" ] && export "SIMCTL_CHILD_$name=$value"
done

# ── Start ────────────────────────────────────────────────────────────────────
step "Start"
if [ -n "$PROBE" ]; then
    printf '  Probe screen: %s\n' "$PROBE"
    SIMCTL_CHILD_CINELOUNGE_PROBE="$PROBE" \
        xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null && ok "running"
else
    xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null && ok "running"
fi

printf '\nScreenshot:\n  xcrun simctl io %s screenshot --type=png image.png\n' "$DEVICE"
