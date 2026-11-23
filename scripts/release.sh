#!/usr/bin/env bash
#
# Build for TestFlight and upload to App Store Connect.
#
# The difference from device.sh is not the number of steps but how reversible
# they are: a build onto your own device costs a minute if it was wrong. An upload
# does not — App Store Connect accepts each build number only ONCE. Once a build
# is up, it cannot be replaced, only overtaken. That is why everything that can be
# checked sits BEFORE the build and not after it.
#
#   ./scripts/release.sh                build, archive, upload
#   ./scripts/release.sh --check      preflight checks only, build nothing
#   ./scripts/release.sh --export-only   archive and export, do not upload
#   ./scripts/release.sh --build 42       set the build number yourself
#   ./scripts/release.sh --version 0.2.0
#
set -uo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="build/CineLounge.xcarchive"
EXPORT_DIR="build/export"
OPTIONS="build/ExportOptions.plist"

CHECK_ONLY=0
EXPORT_ONLY=0
BUILD=""
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check)    CHECK_ONLY=1; shift ;;
        --export-only) EXPORT_ONLY=1; shift ;;
        --build)        BUILD="${2:-}"; shift 2 ;;
        --version)    VERSION="${2:-}"; shift 2 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ── Only one at a time ───────────────────────────────────────────────────────
# Added on 14.08., after two runs overlapped by accident. Both work in build/, and
# one clears the archive with `rm -rf` while the other is writing into it — what
# comes out of that can no longer be told. Worse still: the build number is read
# at the START. If a commit lands in between, the two runs carry different
# numbers, and which one belongs to which source can no longer be established
# afterwards.
#
# `mkdir` is the lock and not, say, a file with the process ID in it: creating a
# directory is atomic, whereas "does the file exist yet?" followed by "then I'll
# create it" is not.
LOCK="build/.laeuft"
mkdir -p build
if ! mkdir "$LOCK" 2>/dev/null; then
    printf '\033[31m✗ A run is already in progress (%s).\033[0m\n' "$LOCK"
    printf '  \033[2mIf none is really running any more: rmdir %s\033[0m\n' "$LOCK"
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
hint() { printf '  \033[2m%s\033[0m\n' "$1"; }

fail=0

# ── Determine the team ───────────────────────────────────────────────────────
# From the environment or from ~/.cinelounge-team, exactly as in device.sh. The
# reasoning for why the team is NOT in the project is written down there in
# detail: two developer accounts on this machine, and no personal identifiers in
# a checked-in file.
TEAM="${CINELOUNGE_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.cinelounge-team" ]; then
    TEAM=$(tr -d ' \n' < "$HOME/.cinelounge-team")
fi

step "Developer team"
if [ -z "$TEAM" ]; then
    bad "No team given."
    hint "Once:  echo <TEAM_ID> > ~/.cinelounge-team"
    hint "The ID is under developer.apple.com → Membership Details."
    exit 1
fi
ok "Team $TEAM"

# ── Sign-in ──────────────────────────────────────────────────────────────────
# This check was added after it was missing on 14.08.: the run archived without
# complaint for five minutes — the developer certificate alone is enough for that
# — and only failed at export with "exportArchive No Accounts". The cause was
# fixed from the start and could have been had in a second. That is why it now
# sits right at the front.
#
# Two ways in. The key from ~/.cinelounge-asc is the more reliable one: it works
# even without Xcode being signed in and without a confirmation on a second
# device. Without it, xcodebuild uses the account signed in to Xcode — that works,
# but may demand a two-factor confirmation in the middle of the run.
step "Sign-in"
AUTH=()
if [ -f "$HOME/.cinelounge-asc" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cinelounge-asc"
    if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "${ASC_KEY_PATH:-}" ]; then
        AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
        ok "Team key $ASC_KEY_ID"
    else
        warn "~/.cinelounge-asc is incomplete — only the Xcode account counts."
    fi
fi

if [ ${#AUTH[@]} -eq 0 ]; then
    # What gets counted is the list of signed-in Apple IDs. It is the only place
    # that proves an EXISTING sign-in — the team entries further down survive a
    # sign-out and cheerfully keep claiming afterwards that everything is fine.
    # This check fell for exactly that on 14.08.
    # Counting uses plistlib and not grep: in the text output of `defaults` the
    # list's name still appears in quotes even when the list is EMPTY, and a line
    # count then reports an account that does not exist.
    ACCOUNTS=$(python3 - <<'PY' 2>/dev/null
import subprocess, plistlib
raw = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"],
                     capture_output=True).stdout
lists = plistlib.loads(raw).get("DVTDeveloperAccountManagerAppleIDLists", {})
print(sum(len(v) for v in lists.values()))
PY
)
    if [ "${ACCOUNTS:-0}" -gt 0 ]; then
        ok "via the account signed in to Xcode"
    else
        bad "Neither a team key nor an account signed in to Xcode."
        hint ""
        hint "Without one of the two, neither a distribution certificate can be"
        hint "fetched nor anything exported. The build itself would run through —"
        hint "it only needs the development certificate — and fail right at the end."
        hint ""
        hint "The more convenient way, because it is one-time and has no two-factor prompt:"
        hint "  App Store Connect → Users and Access → Integrations"
        hint "  → Team Keys → Plus, role \"Admin\" (not \"App Manager\" —"
        hint "  that one may upload but not create certificates), download the .p8"
        hint "  (downloadable only ONCE), then create ~/.cinelounge-asc:"
        hint "      ASC_KEY_ID=..."
        hint "      ASC_ISSUER_ID=..."
        hint "      ASC_KEY_PATH=\$HOME/.appstoreconnect/AuthKey_....p8"
        hint ""
        hint "The other way:"
        hint '  Xcode → Settings (⌘,) → Accounts → Plus → Apple ID'
        fail=1
    fi
fi

# ── Membership ───────────────────────────────────────────────────────────────
# The only check that really decides between success and failure: a FREE account
# can build and install onto your own device, but never upload. Without
# membership in the Apple Developer Program there is no distribution certificate,
# and the run would go all the way to export, only to fail there after several
# minutes of building on a message about missing profiles that does not name the
# actual reason.
#
# WATCH OUT, and this is the reason for the "Sign-in" step before it: this value
# comes from Xcode's cache and SURVIVES a sign-out. It proves what the team last
# was, not that anyone may access it right now. Read on its own it cheerfully says
# "in the program" while nothing is signed in any more — that is exactly how the
# run on 14.08. ran into a five-minute build that ended in "No Accounts".
step "Membership"
TEAM_KIND=$(python3 - "$TEAM" <<'PY' 2>/dev/null
import subprocess, plistlib, sys
team = sys.argv[1]
raw = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"],
                     capture_output=True).stdout
for entries in plistlib.loads(raw).get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in entries:
        if t.get("teamID") == team:
            print("free" if t.get("isFreeProvisioningTeam") else "paid")
            sys.exit()
print("unknown")
PY
)

case "$TEAM_KIND" in
    paid)
        ok "Team $TEAM is in the Apple Developer Program" ;;
    free)
        bad "Team $TEAM is a free account."
        hint "This is not a malfunction but the limit: without membership there is no"
        hint "distribution certificate and therefore no TestFlight. device.sh remains."
        fail=1 ;;
    *)
        warn "Membership cannot be determined — is an account signed in to Xcode?"
        hint "Xcode → Settings (⌘,) → Accounts. The run continues anyway;"
        hint "if membership is really missing, it fails at signing." ;;
esac

# ── Distribution certificate ─────────────────────────────────────────────────
# Explicitly NOT a reason to abort, and this is a correction to the first version
# of this script: there the run aborted when no distribution certificate was in
# the Keychain — and thereby blocked exactly the case that `xcodebuild` solves by
# itself with `-allowProvisioningUpdates`. It creates the certificate, identifiers
# and profiles if they are missing. Before the FIRST upload their absence is the
# normal case and not a defect.
#
# The search goes by the certificate's ORGANIZATIONAL UNIT (OU), not by the
# parentheses in the name: for personal certificates the parentheses hold the ID
# of the PERSON within the team. The two look the same and are not — the same
# pitfall that already cost an hour in device.sh.
step "Distribution certificate"
DIST_OUS=$(security find-certificate -a -c "Apple Distribution" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's|.*/OU=\([A-Z0-9]*\)/.*|\1|p' | sort -u)

if printf '%s\n' "$DIST_OUS" | grep -qx "$TEAM"; then
    ok "Apple Distribution present for team $TEAM"
else
    warn "None yet for team $TEAM — xcodebuild creates it when archiving."
fi

# ── State of the working directory ───────────────────────────────────────────
# An upload from an unsaved state can no longer be reproduced later. When a tester
# reports a bug in four weeks, the only reliable piece of information is the build
# number — and it is only any use if a commit belongs to it.
step "Working directory"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "There are uncommitted changes."
    hint "The build number then points to a state that does not exist in the"
    hint "history. Commit first, then upload."
    git status --short | head -8 | sed 's/^/      /'
    [ "$EXPORT_ONLY" -eq 0 ] && fail=1
else
    ok "clean"
fi

# ── Version and build number ─────────────────────────────────────────────────
# The build number comes from the commit count: monotonic, no counter file of its
# own, and the state can be found again for every number. The pitfall is stated
# in the message — anyone uploading the same commit a second time needs --build.
step "Version and build number"
[ -z "$VERSION" ] && VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')
[ -z "$BUILD" ] && BUILD=$(git rev-list --count HEAD 2>/dev/null)

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    bad "Version or build number cannot be determined (version='$VERSION' build='$BUILD')"
    fail=1
else
    ok "$VERSION ($BUILD)"
    hint "App Store Connect accepts each build number only once. If the same"
    hint "commit is needed again:  ./scripts/release.sh --build $((BUILD + 1))"
fi

# ── The Info.plist carries references, not numbers ───────────────────────────
# This check guards against a regression that has happened before: XcodeGen
# writes fixed numbers into the Info.plist when project.yml does not list the keys
# explicitly as a $(...) reference. If a number is there again, the build number
# from above bounces off without effect — the build is green, the upload is
# rejected, and the reason is written nowhere. Both bundles are checked, because
# an extension with a differing version makes App Store Connect reject the whole
# package.
step "Version references in the Info.plist files"
for plist in App/Info.plist TopShelf/Info.plist; do
    short=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null)
    long=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null)
    if [ "$short" = '$(MARKETING_VERSION)' ] && [ "$long" = '$(CURRENT_PROJECT_VERSION)' ]; then
        ok "$plist"
    else
        bad "$plist carries fixed values ($short / $long) instead of the references."
        hint "In project.yml under info.properties these belong:"
        hint '    CFBundleShortVersionString: $(MARKETING_VERSION)'
        hint '    CFBundleVersion: $(CURRENT_PROJECT_VERSION)'
        fail=1
    fi
done

# ── Which spec the project comes from ────────────────────────────────────────
# The project is generated and not checked in. Archiving whatever lies there is only right
# if it was generated from the spec this checkout builds with — `checks.local.sh` may name a
# different one (`XCODEGEN_SPEC`, as in check.sh). A project made from another spec builds
# without complaint and simply lacks what that spec adds.
step "Project spec"
[ -f ./checks.local.sh ] && . ./checks.local.sh
SPEC=${XCODEGEN_SPEC:-project.yml}
. ./scripts/project-spec.sh
if spec_reason=$(project_from_spec "$SPEC"); then
    ok "CineLounge.xcodeproj comes from $SPEC"
else
    bad "CineLounge.xcodeproj: $spec_reason"
    hint "./scripts/check.sh generates it again from $SPEC."
    fail=1
fi

# ── Export compliance ────────────────────────────────────────────────────────
# If the key is missing, App Store Connect asks again after every upload and keeps
# the build from the testers until it is answered. Not an error, but a silent brake.
step "Export compliance"
if [ "$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" App/Info.plist 2>/dev/null)" = "false" ]; then
    ok "ITSAppUsesNonExemptEncryption is set to false"
else
    warn "ITSAppUsesNonExemptEncryption is missing — App Store Connect will ask."
fi

# ── Store icon ───────────────────────────────────────────────────────────────
# On tvOS the App Store icon is a SEPARATE entry next to the tile icon, and it is
# only required on upload. On the device its absence is never noticed.
step "Store icon"
STORE_ICON="App/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/App Icon - App Store.imagestack"
if [ -d "$STORE_ICON" ]; then
    ok "App Icon - App Store present"
else
    bad "Missing: $STORE_ICON"
    fail=1
fi

# ── Result of the preflight checks ───────────────────────────────────────────
printf '\n'
if [ $fail -ne 0 ]; then
    printf '\033[31m✗ Preflight failed — nothing built, nothing uploaded.\033[0m\n'
    exit 1
fi
printf '\033[32m✓ Preflight passed.\033[0m\n'

if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi

# ── Archive ──────────────────────────────────────────────────────────────────
# Version and build number are passed in here and not written into the project.
# That way every build carries the number that belongs to its state, without a
# file having to be touched and reset for it.
step "Archive ($VERSION build $BUILD)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build

archive_out=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
    -destination "generic/platform=tvOS" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -derivedDataPath .dd \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"} \
    archive 2>&1)

if [ $? -ne 0 ]; then
    bad "Archiving failed"
    printf '%s' "$archive_out" | grep -E "error:|Signing|Provisioning|doesn't include" \
        | sort -u | head -12 | sed 's/^/    /'
    hint ""
    hint "If it says something about missing profiles: both identifiers must be"
    hint "registered in the developer portal as EXPLICIT App IDs, with"
    hint "Keychain Sharing — wildcard profiles are no good for the store."
    hint "    dev.ms-solutions.cinelounge"
    hint "    dev.ms-solutions.cinelounge.topshelf"
    exit 1
fi
ok "archived"

# Cross-check against the finished bundle instead of the input: what is in the
# archive now is what goes up. If app and extension differ from each other, it can
# still be seen here — after the upload only as a rejection by email.
APP_PLIST="$ARCHIVE/Products/Applications/CineLounge.app/Info.plist"
EXT_PLIST="$ARCHIVE/Products/Applications/CineLounge.app/PlugIns/TopShelf.appex/Info.plist"
for p in "$APP_PLIST" "$EXT_PLIST"; do
    [ -f "$p" ] || { bad "Missing in the archive: $p"; exit 1; }
    v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$p" 2>/dev/null)
    b=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$p" 2>/dev/null)
    if [ "$v" != "$VERSION" ] || [ "$b" != "$BUILD" ]; then
        bad "The archive has $v ($b) instead of $VERSION ($BUILD) — $(basename "$(dirname "$p")")"
        exit 1
    fi
done
ok "App and extension both carry $VERSION ($BUILD)"
# The same question as "Project spec" above, asked of the finished bundle: whatever the spec
# lists as app extensions must have arrived in it.
if grep -q 'CLExtensionClasses' "$SPEC" \
    && ! /usr/libexec/PlistBuddy -c "Print :CLExtensionClasses" "$APP_PLIST" >/dev/null 2>&1; then
    bad "The archive lacks CLExtensionClasses that $SPEC sets"
    exit 1
fi

# ── Export ───────────────────────────────────────────────────────────────────
# The file carries the team ID and is therefore regenerated on every run instead
# of being checked in — the same reason as for the team itself.
#
# `app-store-connect` is the name of the method from Xcode 15.3 on; the older
# spelling `app-store` is still accepted but no longer maintained.
if [ "$EXPORT_ONLY" -eq 1 ]; then
    DESTINATION="export"
    step "Export to $EXPORT_DIR"
else
    DESTINATION="upload"
    step "Upload to App Store Connect"
fi

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$DESTINATION</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST

# The output runs through `tee` instead of being collected in a variable, and that
# is a correction from the first evening: trapped in `$(...)`, NO line appears
# until everything is over — with 52 MB over an ordinary connection that is
# several minutes in which it is impossible to tell whether something is going up
# or hanging. Only the progress lines are shown; the full log stays in the file
# and is read below for troubleshooting.
LOG="build/export.log"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"} 2>&1 \
    | tee "$LOG" \
    | grep --line-buffered -oE "Progress [0-9]+ %" \
    | sed -u 's/^/  … /'

# The exit status must come from the BUILD and not from the last link of the
# chain — otherwise a failed upload reports success because `sed` was happy.
#
# WATCH OUT, on 03.09. there was a `|| true` behind the pipeline here, and it
# reopened exactly the bug that the sentence above warns about: with `pipefail`
# the whole pipeline fails as soon as xcodebuild fails — then `true` runs, and
# `true` is a command that RESETS `PIPESTATUS` to `(0)`. What gets read afterwards
# is no longer the build but the `true`. Shown on 03.09.: the upload of 0.1.0 (460)
# failed on a missing symbol, the script reported "uploaded" and exited with 0.
# The `|| true` is not needed anyway — `set -e` is not set here, the script
# carries on by itself after a failed pipeline.
export_status=${PIPESTATUS[0]}
export_out=$(cat "$LOG" 2>/dev/null)

if [ "$export_status" -ne 0 ]; then
    bad "Failed"
    printf '%s' "$export_out" | grep -iE "error|failed|invalid" | sort -u | head -12 | sed 's/^/    /'

    # "Cloud signing permission error" is the most unfriendly message on this
    # whole path: it sounds like an error in the sign-in, and the sign-in is fine.
    # A PERMISSION of the key is missing.
    #
    # A team key with the "App Manager" role may upload builds but not create
    # certificates. Cloud signing needs exactly that, and that is why three
    # follow-up messages about missing profiles and a missing certificate appear
    # below it — they are effect, not cause. Anyone who takes them for the cause
    # creates profiles by hand and still gets nowhere.
    #
    # The role of an existing key cannot be changed afterwards.
    if printf '%s' "$export_out" | grep -q "Cloud signing permission error"; then
        hint ""
        hint "The three messages about missing profiles are only the consequence. The"
        hint "cause is the first line: the team key may not create certificates."
        hint ""
        hint "For that it needs the \"Admin\" role — \"App Manager\" is enough for"
        hint "uploading, not for signing. The role of an existing key cannot be"
        hint "changed, so a new one is needed:"
        hint "  App Store Connect → Users and Access → Integrations"
        hint "  → Team Keys → Plus, role \"Admin\""
        hint "Then enter the new ID and the new path in ~/.cinelounge-asc;"
        hint "revoke the old key."
        hint ""
        hint "The way around it: fetch the distribution certificate by hand once"
        hint "(Xcode → Settings → Accounts → Manage Certificates → Plus →"
        hint "Apple Distribution). Then the \"App Manager\" key is enough."
    elif [ ${#AUTH[@]} -eq 0 ]; then
        hint ""
        hint "Without a key, the sign-in goes through Xcode and often fails on"
        hint "the two-factor prompt. A team key is more reliable:"
        hint "  App Store Connect → Users and Access → Integrations"
        hint "  → Team Keys → Plus, role \"Admin\", download the .p8"
        hint "  (downloadable only ONCE), then create ~/.cinelounge-asc:"
        hint "      ASC_KEY_ID=..."
        hint "      ASC_ISSUER_ID=..."
        hint "      ASC_KEY_PATH=\$HOME/.appstoreconnect/AuthKey_....p8"
    fi
    exit 1
fi

printf '\n'
if [ "$EXPORT_ONLY" -eq 1 ]; then
    ok "exported to $EXPORT_DIR"
    printf '\033[32m✓ Done.\033[0m\n'
else
    ok "uploaded"
    printf '\033[32m✓ %s (%s) is up.\033[0m\n' "$VERSION" "$BUILD"
    printf '\n'
    hint "Processing takes 5 to 30 minutes. Afterwards, in App Store Connect"
    hint "→ TestFlight, assign the build to a test group, otherwise nobody sees it."
    hint ""
    hint "Internal testers see it immediately, without beta review. What matters"
    hint "here is the Apple ID: TestFlight on the Apple TV uses the DEVICE's one,"
    hint "another cannot be chosen there. So the person to invite is the Apple ID"
    hint "that is signed in on the TV in question."
    hint ""
    hint "The text for \"What to Test\" is in ~/dev/apps/cinelounge-privat/intern/design/testflight-hinweis.md —"
    hint "three sentences, and the third says what to watch for. A tester who does"
    hint "not know that only reports what catches their eye, and that is rarely what is new."
fi
