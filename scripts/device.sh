#!/usr/bin/env bash
# Put the app on the real Apple TV.
#
# Why a script of its own and not Xcode: The same reason as with run.sh. The build
# lands in .dd, installation happens from .dd, and at the end the program's
# timestamp on the device is shown. Without this display, a whole evening in this
# project has once ended with a state from 00:50 being checked while the changes
# had long been there.
#
# Signing is NOT written into the project but passed in here. Two reasons: Two
# developer accounts work on this machine, and a team hard-coded in the project
# would be a silent source of errors when switching. And the project stays free of
# personal identifiers — they do not belong in a file that is checked in.
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".dd/Build/Products/Debug-appletvos"
BUNDLE_ID="dev.ms-solutions.cinelounge"
APP="$BUILD_DIR/CineLounge.app"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
hint() { printf '  \033[2m%s\033[0m\n' "$1"; }

# ── Determine the team ───────────────────────────────────────────────────────
# From the environment or from ~/.cinelounge-team. Not from the project: see above.
TEAM="${CINELOUNGE_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.cinelounge-team" ]; then
    TEAM=$(tr -d ' \n' < "$HOME/.cinelounge-team")
fi

if [ -z "$TEAM" ]; then
    bad "No developer team given."

    # FIRST Xcode's accounts file, and that is the difference between proof and a
    # guess: It lists the teams the SIGNED-IN account belongs to. A certificate in
    # the Keychain, by contrast, only says that it once lay on this machine — it
    # can be left over from an old job or a foreign account. Exactly such a
    # leftover lay here, and it would almost have led to signing under a foreign
    # identity.
    TEAMS_PLIST="$HOME/Library/Developer/Xcode/UserData/IDEProvisioningTeams.plist"
    if [ -f "$TEAMS_PLIST" ]; then
        hint "Teams of your account signed in to Xcode:"
        python3 - "$TEAMS_PLIST" <<'PY'
import plistlib, sys
for apple_id, teams in plistlib.load(open(sys.argv[1], "rb")).items():
    for team in teams:
        free_note = " — free, profile expires after 7 days" if team.get("isFreeProvisioningTeam") else ""
        print(f'    {team.get("teamID")}  ({team.get("teamName")}){free_note}   [{apple_id}]')
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
    hint ""
    hint "Certificates do lie around here, but they prove no membership:"

    # The team ID is in the ORGANIZATIONAL UNIT (OU), not in the parentheses of the
    # certificate name. For a personal developer certificate, the parentheses hold
    # the ID of the PERSON within the team — the two look alike and are different.
    # An hour was once lost on exactly this: `DEVELOPMENT_TEAM` with the person ID
    # yields "No profiles were found", and the error message does not name the
    # reason.
    for name in "Apple Development" "Apple Distribution" "iPhone Developer" "Mac Developer"; do
        security find-certificate -a -c "$name" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null
    done | sed -n 's|.*/OU=\([A-Z0-9]*\)/O=\([^/]*\)/.*|    \1  (\2)|p' | sort -u

    hint ""
    hint "The first column is the team ID. Then, once:"
    hint "    echo <TEAM_ID> > ~/.cinelounge-team"
    exit 1
fi

# ── Find the device ──────────────────────────────────────────────────────────
step "Look for the Apple TV"
DEVICES=$(xcrun devicectl list devices 2>/dev/null)

# The search goes by the MODEL COLUMN, not by "tvOS": In the listing it says
# `AppleTV14,1` there, and the word tvOS does not occur in the line at all. The
# state column contains a space ("available (paired)"), so the identifier is read
# by its fixed position from the front and not from the back.
#
# The household has two Apple TVs. Without an argument the first paired one is
# taken; with CINELOUNGE_DEVICE one can be chosen by name. Silently taking the
# wrong one would be worse than a question — one would then check on the wrong TV
# and look for the error in the program.
WANTED="${CINELOUNGE_DEVICE:-}"
# The search is for AppleTV ANYWHERE in the line, not at the start of a field:
# Xcode first calls the model "AppleTV14,1" and, after the first contact, "Apple TV
# 4K (3rd generation) (AppleTV14,1)". A pattern at the start of a field therefore
# only held until the first successful access — after that the paired device
# counted as not present, and the message sent one to pairing, which had long been
# done.
#
# **Xcode 27 writes the line differently** (2026-09-27): Instead of "available
# (paired)" it says "connected", with "physical" or "simulated" at the end, and the
# hostname column is empty — the identifier was thus no longer in third place. It is
# therefore read from the "(UDID)" suffix and not from a column number; simulators
# drop out via "simulated".
UDID=$(printf '%s' "$DEVICES" \
    | awk -v want="$WANTED" '
        /AppleTV/ && (/paired/ || /connected/ || /available/) && !/simulated/ {
            if (want != "" && $1 != want) next
            for (i = 2; i <= NF; i++) if ($(i + 1) == "(UDID)") { print $i; exit }
            print $3; exit
        }')

if [ -z "$UDID" ] && [ -n "$WANTED" ]; then
    bad "No paired Apple TV with this name: $WANTED"
    hint "Paired are:"
    printf '%s' "$DEVICES" | awk '$NF ~ /^AppleTV/ {printf "    %s (%s)\n", $1, $NF}'
    exit 1
fi

if [ -z "$UDID" ]; then
    bad "No Apple TV paired."
    hint ""
    hint "Pairing only works by hand, once per device:"
    hint "  1. On the TV:     Settings → Remotes and Devices"
    hint "                    → Remote App and Devices"
    hint "     Leave this screen OPEN — it keeps the device ready to receive."
    hint "  2. In Xcode:      Window → Devices and Simulators"
    hint "     The Apple TV appears there. Pair, enter the six-digit code from"
    hint "     the TV."
    hint "  3. Both must be on the same network — it does not work through the tunnel."
    hint ""
    hint "Then call this script again."
    exit 1
fi
ok "found: $UDID"

# ── Build ────────────────────────────────────────────────────────────────────
step "Build for the device"
# **Only from the right spec** — see "Project spec" in release.sh.
[ -f ./checks.local.sh ] && . ./checks.local.sh
SPEC=${XCODEGEN_SPEC:-project.yml}
. ./scripts/project-spec.sh
if ! spec_reason=$(project_from_spec "$SPEC"); then
    bad "CineLounge.xcodeproj: $spec_reason"
    hint "./scripts/check.sh generates it again from $SPEC."
    exit 1
fi
# **With the team key, like release.sh** (2026-10-01): Without an account signed in
# to Xcode, -allowProvisioningUpdates may not fetch a new profile — when the app
# group was added, it then said "No Accounts" and "doesn't include the App Groups
# capability".
AUTH=()
if [ -f "$HOME/.cinelounge-asc" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cinelounge-asc"
    if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "${ASC_KEY_PATH:-}" ]; then
        AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    fi
fi
# Automatic signing: Xcode fetches or creates the profile itself. With a free
# account it lasts seven days, with a paid one a year — if the app stops running
# after a week, that is the reason and not an error in the program.
build_out=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
    -destination "platform=tvOS,id=$UDID" \
    -derivedDataPath .dd \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" \
    -allowProvisioningUpdates "${AUTH[@]}" \
    build 2>&1)

if [ $? -ne 0 ]; then
    bad "Build failed"
    printf '%s' "$build_out" | grep -E "error:|Signing|Provisioning|requires a provisioning" \
        | sort -u | head -12 | sed 's/^/    /'
    exit 1
fi
ok "built and signed (team $TEAM)"

[ -d "$APP" ] || { bad "Program not found: $APP"; exit 1; }

# ── Install ──────────────────────────────────────────────────────────────────
step "Put it on the device"
if xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null 2>&1; then
    ok "installed"
else
    bad "Installation failed"
    hint "Most common cause: The device has gone to sleep or is no longer on the network."
    exit 1
fi

step "Start"
# **Quit the running app first** (2026-10-12): Without `--terminate-existing` the start
# fails if the app is already open — and on the TV the OLD state then kept running
# while the script had reported "installed". An evening was spent that way checking
# the wrong build.
if xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    ok "started (running app quit beforehand)"
else
    bad "Not started — quit the app on the TV and reopen it, otherwise the old state keeps running."
fi

printf '\n  Build time: %s\n' "$(stat -f '%Sm' -t '%d.%m. %H:%M:%S' "$APP/CineLounge" 2>/dev/null)"
printf '\033[32m✓ Done — now judge it from three meters away.\033[0m\n'
