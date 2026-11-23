#!/bin/bash
# Archive and upload to TestFlight.
#
# The template is `jellyfin-tvos/scripts/release.sh`, and the principle there is
# the real value: EVERYTHING THAT CAN BE CHECKED SITS BEFORE THE BUILD, because
# App Store Connect accepts each build number only once. Carried over: the lock
# via `mkdir` (atomic, prevents overlapping runs), the team and sign-in checks,
# "working directory clean", the build number from `git rev-list --count HEAD`
# (monotonic, no counter file), the version references in the Info.plist, the
# export compliance and the ExportOptions.plist regenerated on every run.
#
# Different from the TV (07.09.):
#   · Instead of "store icon as an imagestack", the 1024 entry in the AppIcon set —
#     in all three appearances that iOS 18 requires.
#   · PrivacyInfo.xcprivacy must be in the bundle (since May 2024 Apple requires
#     the declaration for UserDefaults, file timestamps and disk space).
#   · UISupportedInterfaceOrientations and UIApplicationSceneManifest are in
#     the Info.plist.
#   · No extension — one bundle, one Info.plist.
#
# Usage:  ./scripts/release.sh               archive and upload
#         ./scripts/release.sh --check     preflight checks only
#         ./scripts/release.sh --export-only  archive and export to build/export
#         ./scripts/release.sh --build 42      set the build number (default: commit count)
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

# ── Team ────────────────────────────────────────────────────────────────────
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

# ── Sign-in ─────────────────────────────────────────────────────────────────
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
    warn "No team key — the sign-in goes through the account signed in to Xcode."
    hint "A team key (role \"Admin\") is more reliable: App Store Connect"
    hint "→ Users and Access → Integrations → Team Keys, then ~/.cinelounge-asc."
fi

# ── Distribution certificate ────────────────────────────────────────────────
step "Distribution certificate"
DIST_OUS=$(security find-certificate -a -c "Apple Distribution" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's|.*/OU=\([A-Z0-9]*\)/.*|\1|p' | sort -u)
if printf '%s\n' "$DIST_OUS" | grep -qx "$TEAM"; then
    ok "Apple Distribution present for team $TEAM"
else
    warn "None yet for team $TEAM — xcodebuild creates it when archiving."
fi

# ── Working directory ───────────────────────────────────────────────────────
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

# ── Version and build number ────────────────────────────────────────────────
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

# ── Info.plist ──────────────────────────────────────────────────────────────
step "Info.plist"
plist=App/Info.plist
short=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null)
long=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null)
if [ "$short" = '$(MARKETING_VERSION)' ] && [ "$long" = '$(CURRENT_PROJECT_VERSION)' ]; then
    ok "Version references"
else
    bad "$plist carries fixed values ($short / $long) instead of the references."
    hint "In project.yml under info.properties these belong:"
    hint '    CFBundleShortVersionString: $(MARKETING_VERSION)'
    hint '    CFBundleVersion: $(CURRENT_PROJECT_VERSION)'
    fail=1
fi
for key in UISupportedInterfaceOrientations UIApplicationSceneManifest; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
        ok "$key"
    else
        bad "$key is missing in $plist"
        fail=1
    fi
done
if [ "$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$plist" 2>/dev/null)" = "false" ]; then
    ok "ITSAppUsesNonExemptEncryption is set to false"
else
    warn "ITSAppUsesNonExemptEncryption is missing — App Store Connect will ask."
fi

# ── App icon and privacy declaration ────────────────────────────────────────
step "App icon"
ICON_SET="App/Resources/Assets.xcassets/AppIcon.appiconset"
if python3 - "$ICON_SET" <<'PY'
import json, os, sys
d = sys.argv[1]
entries = json.load(open(os.path.join(d, "Contents.json")))["images"]
kinds = set()
for e in entries:
    if e.get("size") != "1024x1024" or not e.get("filename"):
        continue
    if not os.path.exists(os.path.join(d, e["filename"])):
        sys.exit(1)
    kinds.add(e.get("appearances", [{}])[0].get("value", "light"))
sys.exit(0 if {"light", "dark", "tinted"} <= kinds else 1)
PY
then
    ok "1024 icon in light, dark and tinted"
else
    bad "App icon incomplete — python3 ~/dev/apps/cinelounge-privat/intern/phone/scripts/appsymbol.py --uebernehmen <draft>"
    fail=1
fi
step "Privacy declaration"
if plutil -lint App/Resources/PrivacyInfo.xcprivacy >/dev/null 2>&1; then
    ok "PrivacyInfo.xcprivacy"
else
    bad "App/Resources/PrivacyInfo.xcprivacy is missing or not a valid plist"
    fail=1
fi
# **And the project must know it** (07.09., learned on the first run): the Xcode
# project is generated from project.yml and is not checked in. A file that was
# added after the last `project.sh` gets archived — without it. Three minutes of
# archiving for a check that costs a second.
if grep -q "PrivacyInfo.xcprivacy" CineLounge.xcodeproj/project.pbxproj 2>/dev/null; then
    ok "the Xcode project bundles it"
else
    bad "The Xcode project does not know the file — run ./scripts/project.sh first"
    fail=1
fi

# ── Which spec the project comes from ───────────────────────────────────────
# As on the TV: `../checks.local.sh` may name another spec (`PHONE_XCODEGEN_SPEC`), and a
# project generated from a different one archives without complaint, minus what it adds.
step "Project spec"
[ -f ../checks.local.sh ] && . ../checks.local.sh
SPEC=${PHONE_XCODEGEN_SPEC:-project.yml}
. ../scripts/project-spec.sh
if spec_reason=$(project_from_spec "$SPEC"); then
    ok "CineLounge.xcodeproj comes from $SPEC"
else
    bad "CineLounge.xcodeproj: $spec_reason"
    hint "./scripts/project.sh generates it again from $SPEC."
    fail=1
fi

printf '\n'
if [ $fail -ne 0 ]; then
    printf '\033[31m✗ Preflight failed — nothing built, nothing uploaded.\033[0m\n'
    exit 1
fi
printf '\033[32m✓ Preflight passed.\033[0m\n'
if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi

# ── Store variant without portals ───────────────────────────────────────────
step "Store variant without portals"
# **ROADMAP A1: Separating only at submission time is too late.** The variant
# without portals has to compile before it is needed — a build flavor that exists
# only in a check and never went through the compiler is not one.
#
# **Why here and not in `check.sh`:** the switch only takes effect at the app
# target, and building that costs a minute. On every check run that would be a
# minute for a variant nobody needs between two deliveries; here is the one place
# where it is really needed.
#
# **What is checked is that it compiles, not the content.** Whether the variant
# has holes is what the `SourceToggleTests` say — they run without a build and in
# seconds.
NO_PORTALS=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
    -destination "generic/platform=iOS" -derivedDataPath .dd-ohne \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="OHNE_PORTALE" \
    CODE_SIGNING_ALLOWED=NO build 2>&1)
if echo "$NO_PORTALS" | grep -q "BUILD SUCCEEDED"; then
    ok "compiles without portals"
else
    echo "$NO_PORTALS" | grep -E "error:" | sort -u | head -10
    bad "The variant without portals does not compile"
    exit 1
fi
rm -rf .dd-ohne

# ── Archive ─────────────────────────────────────────────────────────────────
step "Archive ($VERSION build $BUILD)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
archive_out=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
    -destination "generic/platform=iOS" \
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
    hint "If it says something about missing profiles: dev.ms-solutions.cinelounge must"
    hint "be registered in the developer portal as an EXPLICIT App ID, with Keychain"
    hint "Sharing — wildcard profiles are no good for the store."
    exit 1
fi
ok "archived"
APP_PLIST="$ARCHIVE/Products/Applications/CineLounge.app/Info.plist"
[ -f "$APP_PLIST" ] || { bad "Missing in the archive: $APP_PLIST"; exit 1; }
v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST" 2>/dev/null)
b=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST" 2>/dev/null)
if [ "$v" != "$VERSION" ] || [ "$b" != "$BUILD" ]; then
    bad "The archive has $v ($b) instead of $VERSION ($BUILD)"
    exit 1
fi
[ -f "$ARCHIVE/Products/Applications/CineLounge.app/PrivacyInfo.xcprivacy" ] \
    && ok "App carries $VERSION ($BUILD) and the privacy declaration" \
    || { bad "PrivacyInfo.xcprivacy is not in the bundle"; exit 1; }
if grep -q 'CLExtensionClasses' "$SPEC" \
    && ! /usr/libexec/PlistBuddy -c "Print :CLExtensionClasses" "$APP_PLIST" >/dev/null 2>&1; then
    bad "The archive lacks CLExtensionClasses that $SPEC sets"
    exit 1
fi

# ── Export / upload ─────────────────────────────────────────────────────────
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
export_status=${PIPESTATUS[0]}
export_out=$(cat "$LOG" 2>/dev/null)
if [ "$export_status" -ne 0 ]; then
    bad "Failed"
    printf '%s' "$export_out" | grep -iE "error|failed|invalid" | sort -u | head -12 | sed 's/^/    /'
    if printf '%s' "$export_out" | grep -q "Cloud signing permission error"; then
        hint ""
        hint "The messages about missing profiles are only the consequence. The cause is"
        hint "the first line: the team key may not create certificates —"
        hint "it needs the \"Admin\" role, not \"App Manager\"."
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
    hint "Internal testers see it immediately, without beta review — on the iPhone"
    hint "with the Apple ID that is signed in to TestFlight."
fi
