#!/usr/bin/env bash
# Put the app on a real iPhone.
#
# Why a script of its own and not Xcode: the same reason as for run.sh. The build
# lands in .dd, the install comes from .dd, and at the end the build time of the
# program on the device is shown. Without that display a whole evening in the sister
# project once ended with a state of 00:50 being checked while the changes had long
# been there.
#
# Signing is NOT written into the project but passed in here. Two reasons: two
# developer accounts work on this machine, and a team hard-coded in the project would
# be a silent source of errors when switching. And the project stays free of personal
# identifiers — those do not belong in a file that gets checked in.
#
# DIFFERENCE FROM THE TV: an iPhone is not paired. It is on the cable or on the same
# network; the six-digit code of the Apple TV does not exist here. In return three
# hurdles come in that do not exist there — unlocking, trusting, developer mode —, and
# all three report themselves with messages that do not name the reason. That is why
# it is written down here.
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".dd/Build/Products/Debug-iphoneos"
BUNDLE_ID="dev.ms-solutions.cinelounge"
APP="$BUILD_DIR/CineLounge.app"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
hint() { printf '  \033[2m%s\033[0m\n' "$1"; }

# `--with-credentials` passes the environment variables from `run.sh` through as well.
#
# **The default is OFF, and that is the difference from the simulator.** There the
# Keychain is empty on every launch, and without the variables there would be no access
# at all — they are the only way. On a real phone the Keychain survives the restart:
# whatever the setup stored once is there next time. Whoever passes variables anyway
# never checks whether the setup really held — the app would find its server even if
# nothing had been stored. That very question is the first one on the device.
WITH_CREDENTIALS=0
[ "${1:-}" = "--with-credentials" ] && WITH_CREDENTIALS=1

# ── Determine the team ───────────────────────────────────────────────────────
# From the environment or from ~/.cinelounge-team. Not from the project: see above.
TEAM="${CINELOUNGE_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.cinelounge-team" ]; then
    TEAM=$(tr -d ' \n' < "$HOME/.cinelounge-team")
fi

if [ -z "$TEAM" ]; then
    bad "No developer team given."

    # FIRST Xcode's accounts file, and that is the difference between proof and
    # conjecture: it lists the teams the SIGNED-IN account belongs to. A certificate in
    # the Keychain, by contrast, only says that it once lay on this machine — it may be
    # left over from an old job or a foreign account. In the sister project exactly such
    # a leftover lay around, and it would have nearly led to signing under a foreign
    # identifier.
    TEAMS_PLIST="$HOME/Library/Developer/Xcode/UserData/IDEProvisioningTeams.plist"
    if [ -f "$TEAMS_PLIST" ]; then
        hint "Teams of your account signed in to Xcode:"
        python3 - "$TEAMS_PLIST" <<'PY'
import plistlib, sys
for apple_id, teams in plistlib.load(open(sys.argv[1], "rb")).items():
    for team in teams:
        free = " — free, profile expires after 7 days" if team.get("isFreeProvisioningTeam") else ""
        print(f'    {team.get("teamID")}  ({team.get("teamName")}){free}   [{apple_id}]')
PY
        hint ""
        hint "The first column is the team ID. Then, once:"
        hint "    echo <TEAM_ID> > ~/.cinelounge-team"
        exit 1
    fi

    hint "No account is signed in to Xcode. That is the actual deficiency:"
    hint '    Xcode → Settings (⌘,) → Accounts → Plus → Apple ID'
    hint ""
    hint "Without an account Xcode cannot fetch a provisioning profile. And only after"
    hint "that is it clear which teams actually belong to you."
    exit 1
fi

# ── Find the device ──────────────────────────────────────────────────────────
step "Finding the iPhone"
DEVICES=$(xcrun devicectl list devices 2>/dev/null)

# We search via the MODEL COLUMN, not via "iOS": the listing shows `iPhone17,1` there,
# and the word iOS does not appear in the line at all. The state column contains a space
# ("available (paired)"), so the identifier is read by its fixed position from the front
# and not from the back. Names may contain spaces ("iPhone von …") and simulators report
# `connected` too, so only `physical` lines count and the identifier is the word before
# "(UDID)".
#
# **Two states count, not one.** On the cable devicectl reports `connected`, over the
# network `available (paired)`. Whoever checks only one will look the next day for a
# device that is right there.
WANTED="${CINELOUNGE_DEVICE:-}"
UDID=$(printf '%s' "$DEVICES" \
    | awk -v want="$WANTED" '
        /iPhone/ && / physical *$/ && (/paired/ || /connected/) {
            if (want != "" && index($0, want) != 1) next
            for (i = 2; i <= NF; i++) if ($(i + 1) == "(UDID)") { print $i; exit }
        }')

if [ -z "$UDID" ] && [ -n "$WANTED" ]; then
    bad "No iPhone with this name: $WANTED"
    hint "Reachable are:"
    printf '%s' "$DEVICES" | awk '/iPhone/ {printf "    %s\n", $1}'
    exit 1
fi

if [ -z "$UDID" ]; then
    bad "No iPhone reachable."
    hint ""
    hint "An iPhone is NOT paired like an Apple TV — it is on the cable"
    hint "or on the same network. Three things, once per device:"
    hint "  1. Plug in the cable, UNLOCK the phone, confirm the trust"
    hint "     prompt. Without that it does not exist for devicectl."
    hint "  2. On the phone: Settings → Privacy & Security"
    hint "     → switch on Developer Mode, the phone restarts."
    hint "     The entry ONLY APPEARS after it has been connected to Xcode once."
    hint "  3. Without a cable: Xcode → Window → Devices and Simulators, tick"
    hint "     the network connection there. Same network, not the tunnel."
    hint ""
    hint "Then call this script again."
    exit 1
fi
NAME=$(printf '%s' "$DEVICES" | awk -v id="$UDID" '$0 ~ id {sub(/ +[0-9A-F-]+ \(UDID\).*/, ""); print; exit}')
ok "found: ${NAME:-iPhone} ($UDID)"

# ── Build ────────────────────────────────────────────────────────────────────
step "Compiling for the device"
# **Only from the right spec** — see "Project spec" in release.sh. Generating takes seconds
# here, so a mismatch is repaired instead of reported, as check.sh does.
[ -f ../checks.local.sh ] && . ../checks.local.sh
SPEC=${PHONE_XCODEGEN_SPEC:-project.yml}
. ../scripts/project-spec.sh
if ! spec_reason=$(project_from_spec "$SPEC"); then
    hint "CineLounge.xcodeproj: $spec_reason — generating it again"
    ./scripts/project.sh >/dev/null 2>&1 || { bad "scripts/project.sh failed"; exit 1; }
    project_from_spec "$SPEC" >/dev/null || { bad "still not from $SPEC"; exit 1; }
fi
# Automatic signing: Xcode fetches or creates the profile itself. With a free account
# it lasts seven days, with a paid one a year — if the app stops launching after a
# week, that is the reason and not a bug in the program.
build_out=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
    -destination "platform=iOS,id=$UDID" \
    -derivedDataPath .dd \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" \
    -allowProvisioningUpdates \
    build 2>&1)

if [ $? -ne 0 ]; then
    bad "Build failed"
    printf '%s' "$build_out" | grep -E "error:|Signing|Provisioning|requires a provisioning" \
        | sort -u | head -12 | sed 's/^/    /'
    # The most common case with a free account, and the message does not name it: the
    # Keychain groups from `App/CineLounge.entitlements` need an explicit app ID. A
    # wildcard profile does not carry them.
    if printf '%s' "$build_out" | grep -q "keychain-access-groups\|Provisioning profile.*doesn't"; then
        hint ""
        hint "Sounds like a free account: the Keychain groups in"
        hint "App/CineLounge.entitlements require an explicit app ID."
        hint "With a paid team Xcode creates it itself."
    fi
    exit 1
fi
ok "compiled and signed (team $TEAM)"

[ -d "$APP" ] || { bad "Program not found: $APP"; exit 1; }

# ── Install ──────────────────────────────────────────────────────────────────
step "Putting it on the device"
if install_out=$(xcrun devicectl device install app --device "$UDID" "$APP" 2>&1); then
    ok "installed"
else
    bad "Install failed"
    printf '%s' "$install_out" | tail -4 | sed 's/^/    /'
    hint ""
    hint "Most common causes, in this order:"
    hint "  · The phone is locked. Unlock it and try again."
    hint "  · Developer Mode is off (Privacy & Security)."
    hint "  · An older version with a different signature is on it — delete it."
    exit 1
fi

# ── Launch ───────────────────────────────────────────────────────────────────
step "Launching"
# The environment is passed as JSON and not inherited — `devicectl` behaves like
# `simctl` in that respect. It is only assembled on request; the reasoning is above at
# WITH_CREDENTIALS.
ENVIRONMENT="{}"
if [ "$WITH_CREDENTIALS" = "1" ]; then
    pairs=""
    for name in CINELOUNGE_SERVER CINELOUNGE_USER CINELOUNGE_TOKEN CINELOUNGE_OMDB \
        CINELOUNGE_TMDB CINELOUNGE_REITER CINELOUNGE_TITEL CINELOUNGE_ANSICHT \
        CINELOUNGE_SPIELER CINELOUNGE_SPIELER_HERKUNFT CINELOUNGE_SPIELER_AB \
        CINELOUNGE_XTREAM CINELOUNGE_XTREAM_USER CINELOUNGE_XTREAM_PASS \
        CINELOUNGE_XTREAM_NAME CINELOUNGE_XTREAM2 CINELOUNGE_XTREAM2_USER \
        CINELOUNGE_XTREAM2_PASS CINELOUNGE_XTREAM2_NAME CINELOUNGE_PORTALE; do
        value=$(eval "printf '%s' \"\${$name:-}\"")
        [ -n "$value" ] && pairs="$pairs$name=$value"$'\n'
    done
    if [ -n "$pairs" ]; then
        ENVIRONMENT=$(printf '%s' "$pairs" | python3 -c '
import json, sys
print(json.dumps(dict(z.split("=", 1) for z in sys.stdin.read().splitlines() if z)))')
        hint "with credentials from the environment — the setup is skipped"
    fi
fi

if xcrun devicectl device process launch --device "$UDID" \
    --environment-variables "$ENVIRONMENT" "$BUNDLE_ID" >/dev/null 2>&1; then
    ok "launched"
else
    # **The very first time this is the normal case and not an error.** A developer
    # certificate is only valid on an iPhone once someone has trusted it by hand — on
    # the TV this step does not exist. iOS reports only "App not available" in the
    # process, and the reason is somewhere else.
    hint "Not launched. The first time that is to be expected:"
    hint "    Settings → General → VPN & Device Management"
    hint "    → Developer App → Trust."
    hint "Then open it from the Home Screen."
fi

printf '\n  Build: %s\n' "$(stat -f '%Sm' -t '%d.%m. %H:%M:%S' "$APP/CineLounge" 2>/dev/null)"
printf '\033[32m✓ Done — now judge it standing up, with one thumb.\033[0m\n'
