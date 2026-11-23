#!/bin/bash
# The quality run. After EVERY stage, not at the end.
#
# Structure taken from `jellyfin-tvos/scripts/check.sh` and shortened by the steps
# that do not exist here (alternate icons go through the asset catalog on iOS; a
# focus trace does not exist without focus). Added is the airplane-mode launch
# (ROADMAP A4).
set -uo pipefail
cd "$(dirname "$0")/.."
../scripts/disk-space.sh || exit 1

# **Local additions** (optional): `../checks.local.sh` may set
#   PHONE_XCODEGEN_SPEC         the project spec, relative to this folder (default `project.yml`),
#   PHONE_EXTRA_PACKAGE_DIRS    further package folders, space-separated, relative to this
#                               folder, that are formatted, linted and tested like `Packages/`.
[ -f ../checks.local.sh ] && . ../checks.local.sh
SPEC=${PHONE_XCODEGEN_SPEC:-project.yml}
. ../scripts/project-spec.sh
read -r -a EXTRA_PKGS <<< "${PHONE_EXTRA_PACKAGE_DIRS:-}"

SOURCES=(App Packages ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"})

# The simulator target is SEARCHED for, not named.
#
# `name=iPhone 16 Pro` alone makes xcodebuild resolve against the newest runtime —
# and iOS 26.5 no longer has that device. The message then reads
# "Unable to find a device matching the provided destination specifier" and names
# neither the runtime nor the reason. So the identifier is fetched: preferably an
# iPhone Pro, otherwise any iPhone.
SIM_ID=$(xcrun simctl list devices available \
    | grep -oE '[A-Za-z0-9 ()]*iPhone[^(]*\([0-9A-F-]{36}\)' \
    | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -1)
SIM_NAME=$(xcrun simctl list devices available | grep "$SIM_ID" | sed -E 's/^ *//; s/ \(.*//')
SIM="id=$SIM_ID"
FORMAT=$(xcrun --find swift-format 2>/dev/null)
FAILED=0
# What the diagnostics use to tag a network or sign-in line — from `Area.tag`.
# **Both, not just "NETZ":** a sign-in attempt at launch carries the marker "ANM ".
NETWORK_MARKER="NETZ|ANM "

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '\033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$1"; }
hint() { printf '\033[90m  %s\033[0m\n' "$1"; }

# ── 1 · Formatting ────────────────────────────────────────────────────
step "Formatting"
if [ -z "$FORMAT" ]; then
    warn "swift-format not found — step skipped"
else
    "$FORMAT" format -i -r --configuration .swift-format "${SOURCES[@]}" \
        && ok "formatted" || bad "swift-format stumbled"
fi

# ── 2 · Lint ──────────────────────────────────────────────────────────
step "Lint"
if [ -n "$FORMAT" ]; then
    OUTPUT=$("$FORMAT" lint --strict -r --configuration .swift-format "${SOURCES[@]}" 2>&1)
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT" | head -40
        bad "$(echo "$OUTPUT" | wc -l | tr -d ' ') lint complaints"
    else
        ok "no complaints"
    fi
fi

# ── 3 · Duplicate file names ──────────────────────────────────────────
# SwiftPM stores its intermediate products by BASE NAME, not by path. Two files of
# the same name in different folders break the build with "multiple producers" — a
# message that does not name the folder and looks like a tool error. This happened
# twice while building the wrapper.
step "Duplicate file names"
# Checked PER TARGET, not across the whole directory: two files of the same name in
# different packages do no harm — the store is per module.
DUPLICATES_TOTAL=0
for target in App/Sources Packages/*/Sources/* Packages/*/Tests/*; do
    [ -d "$target" ] || continue
    DUPLICATES=$(find "$target" -name "*.swift" -not -path "*/.build/*" -exec basename {} \; \
        | sort | uniq -d)
    [ -z "$DUPLICATES" ] && continue
    for name in $DUPLICATES; do
        printf '  %s\n' "$name"
        find "$target" -name "$name" | sed 's/^/      /'
        DUPLICATES_TOTAL=$((DUPLICATES_TOTAL + 1))
    done
done
if [ "$DUPLICATES_TOTAL" -gt 0 ]; then
    bad "$DUPLICATES_TOTAL file names occur more than once in their target"
else
    ok "every file name occurs once in its target"
fi

# ── 4 · Silent errors ─────────────────────────────────────────────────
# Whoever writes a `catch` writes a line into the ledger. A rule is worth as much as
# it is checked — and a swallowed error never reports itself. Since 27.09.2026 the
# script lives under ../scripts/ and reads all sources the phone pulls in, shared
# packages included.
step "Silent errors"
python3 ../scripts/silent-errors.py --app phone || bad "catch blocks without a log entry"

# ── 5 · Buttons without effect ────────────────────────────────────────
# Since `StateView.action` is no longer optional, nobody can FORGET it any
# more — but anybody can write `{}`. An empty body compiles cleanly and still draws
# a button that does nothing.
step "Buttons without effect"
python3 scripts/buttons.py || bad "drawn buttons without an action"

# ── 5b · Sheets leading nowhere ───────────────────────────────────────
# The same kind of error one level further: the button HAS an effect, and it ends in
# the developer placeholder. Reported on 12.09.2026 ("the button between profile and
# download … that doesn't look right either"): the path was wired up, the sheet stood
# ready, and a `case` was missing in between. `default: placeholder` is an exhaustive
# `switch` — the compiler stays silent.
step "Sheets leading nowhere"
python3 scripts/sheets.py --check || bad "a sheet ends in the placeholder"

# ── The store rule ───────────────────────────────────────────────────────────
#
# **The "done when" promise of AP40** (20.09.2026, TV roadmap): the rule for where a
# setting belongs is written down in `ARCHITEKTUR.md` — what was missing was
# something that notices when it is kept. It reports **places**, not keys; the
# reason for that is in the head of the script.
step "Store rule"
if store_out=$(python3 scripts/storage_rule.py 2>&1); then
    ok "$(printf '%s' "$store_out" | tail -1 | sed 's/^ *//')"
else
    printf '%s\n' "$store_out"
    bad "default storage touched without a reason"
fi

# ── 6 · Language keys ─────────────────────────────────────────────────
# A missing key breaks neither the build nor a test — it shows up on the device as a
# bare key name. Hence a step of its own.
step "Language keys"
python3 scripts/strings.py || bad "keys missing from the catalog"

# ── 7 · Tests per package ─────────────────────────────────────────────
# On macOS, not in the simulator: all packages declare `.macOS(.v15)`, and that
# makes feedback take seconds instead of minutes.
step "Tests"
TOTAL=0
for pkg_dir in Packages/*/ ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}; do
    [ -f "$pkg_dir/Package.swift" ] || continue
    pkg=$(basename "$pkg_dir")
    OUTPUT=$(swift test --package-path "$pkg_dir" 2>&1)
    RC=$?
    # Self-healing: after a layout change in a shared package, a stale intermediate
    # state is the most common cause — throw it away once and rebuild before the run
    # counts as a failure.
    if [ $RC -ne 0 ] && echo "$OUTPUT" | grep -qE "signal code 11|cannot find|link(er)? command failed"; then
        hint "$pkg: stale intermediate state, rebuilding"
        rm -rf "$pkg_dir/.build"
        OUTPUT=$(swift test --package-path "$pkg_dir" 2>&1)
        RC=$?
    fi
    if [ $RC -ne 0 ]; then
        echo "$OUTPUT" | grep -E "error:|failed" | head -10
        bad "$pkg"
    else
        COUNT=$(echo "$OUTPUT" | grep -oE "with [0-9]+ test" | grep -oE "[0-9]+" | tail -1)
        TOTAL=$((TOTAL + ${COUNT:-0}))
        ok "$pkg"
    fi
done
[ "$TOTAL" -gt 0 ] && hint "$TOTAL checks ran"

# ── 8 · Compiling for the simulator ───────────────────────────────────
# Every compiler warning is a failure. Only what really comes from a Swift file is
# counted — tool messages with a timestamp do not count.
step "Compiling"
# A fresh clone has no project yet (`.xcodeproj` and `App/Info.plist` are in
# `.gitignore`). Generating it here keeps the run from skipping the build and the
# icon check below with only a warning — the TV run does the same with XcodeGen.
if ! project_from_spec "$SPEC" >/dev/null; then
    ./scripts/project.sh >/dev/null 2>&1 && hint "project generated" || bad "scripts/project.sh failed"
fi
if [ -z "$SIM_ID" ]; then
    warn "No iPhone simulator available — step skipped"
elif [ ! -d CineLounge.xcodeproj ]; then
    warn "No Xcode project — run scripts/project.sh first"
else
    hint "against $SIM_NAME"
    rm -rf .dd/Build
    OUTPUT=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
        -destination "$SIM" -derivedDataPath .dd build 2>&1)
    RC=$?
    WARNINGS=$(echo "$OUTPUT" | grep -cE '^/.*\.swift:[0-9]+:[0-9]+: warning:')
    if [ $RC -ne 0 ]; then
        echo "$OUTPUT" | grep -E "error:" | sort -u | head -20
        bad "Compiling failed"
    elif [ "$WARNINGS" -gt 0 ]; then
        echo "$OUTPUT" | grep -E '^/.*\.swift:[0-9]+:[0-9]+: warning:' | sort -u | head -20
        bad "$WARNINGS warnings"
    else
        ok "compiled without warnings"
    fi
fi

# ── 9 · Test suite in the release build ───────────────────────────────
# Reason from the sister project: an error that only appeared under -O survived the
# debug build — and the incremental debug build does not see package warnings anyway.
step "Release build"
for pkg_dir in Packages/*/ ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}; do
    [ -f "$pkg_dir/Package.swift" ] || continue
    pkg=$(basename "$pkg_dir")
    OUTPUT=$(swift test -c release --package-path "$pkg_dir" -Xswiftc -warnings-as-errors 2>&1)
    RC=$?
    # Same self-healing as above. A failure of this step used to say only
    # "(release build)" and swallowed the message — exactly the kind of information
    # you miss later.
    if [ $RC -ne 0 ] && echo "$OUTPUT" | grep -qE "signal code 11|cannot find|link(er)? command failed"; then
        hint "$pkg: stale intermediate state, rebuilding"
        rm -rf "$pkg_dir/.build"
        OUTPUT=$(swift test -c release --package-path "$pkg_dir" -Xswiftc -warnings-as-errors 2>&1)
        RC=$?
    fi
    if [ $RC -ne 0 ]; then
        echo "$OUTPUT" | grep -E "error:|warning:|failed" | sort -u | head -8
        bad "$pkg (release build)"
    else
        ok "$pkg"
    fi
done

# ── 10 · Legal texts ───────────────────────────────────────────────────
step "Legal texts"
# **The only hard submission blocker that four passes found** (E43): guideline
# 5.1.1(i) explicitly demands the privacy policy *inside* the app, and until 07.09.
# not a word of it appeared in the whole source. What was missing once goes missing
# again — that is why it lives here and not in a reminder.
#
# **What is checked is presence, not wording.** Whether the text is any good is not
# for a script to decide; whether it is there, very much is.
LEGAL_MISSING=""
for key in about.privacyText about.licences about.report; do
    grep -q "\"$key\"" App/Resources/Localizable.xcstrings || LEGAL_MISSING="$LEGAL_MISSING $key"
done
[ -f "App/Resources/Licenses.json" ] || LEGAL_MISSING="$LEGAL_MISSING Licenses.json"
if [ -z "$LEGAL_MISSING" ]; then
    ok "Privacy policy, licences and reporting route are in the catalog"
else
    bad "Legal texts missing:$LEGAL_MISSING"
fi

# **And every third-party package needs its licence text.** Apple does not demand the
# list, the licences themselves do — Apache 2.0 §4 and MIT both want notice AND text.
# `licenses.py` reads them from the checkouts; without this step a swapped-in package
# without a licence file would go unnoticed.
if python3 scripts/licenses.py --check >/dev/null 2>&1; then
    ok "every third-party package with licence text"
else
    python3 scripts/licenses.py --check 2>&1 | sed 's/^/    /'
    bad "Licence texts incomplete — python3 scripts/licenses.py"
fi

# ── 11 · Plural forms ──────────────────────────────────────────────────
step "Plural forms"
# **Of forty-three counters, exactly one carried a plural form** (07.09., AP10). The
# screen read "1 Tage Archiv", "1 Portale gefunden", "Auch die 1 Folgen davor?" — and
# for this household's provider account, which allows exactly ONE connection, "1 von 1
# Verbindungen belegt".
#
# A new key with `%lld` comes into being casually, and the singular only shows when the
# case occurs: with one portal, one day of archive, one error. Until then everything
# looks right. What needs no plural is listed in the script **with a reason**.
PLURALS=$(python3 ../scripts/plurals.py --app phone --check 2>&1)
if [ $? -eq 0 ]; then
    echo "$PLURALS" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$PLURALS" | sed 's/^/    /'
    bad "Counters without a plural form — python3 ../scripts/plurals.py --app phone"
fi

# ── 12 · Scaffolds ─────────────────────────────────────────────────────
step "Scaffolds"
# **For unbuilt things this project creates a file with only a comment** — "Not built
# yet — scaffold after `entwuerfe/prototyp.html`". That is intentional: the cut is made
# before the code exists, and the directory shows what is missing.
#
# **The error is the aftermath** (07.09., AP10). Whoever then builds the thing — often
# elsewhere, because it belongs there — leaves the scaffold standing. From then on the
# thing has two files and one of them is no thing; above all, "Not built yet" is useless
# as an inventory as soon as it sits above something finished. And that is exactly what
# one reads it for.
SCAFFOLDS=$(python3 scripts/scaffold.py --check 2>&1)
if [ $? -eq 0 ]; then
    echo "$SCAFFOLDS" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$SCAFFOLDS" | sed 's/^/    /'
    bad "Scaffold above something built — python3 scripts/scaffold.py"
fi

# ── 12b · Colour board ─────────────────────────────────────────────────
step "Colour board"
# **A system colour compiles cleanly and stays put when the colour scheme changes**
# (10.09., AP5). `Material.edge()` drew `Color.white` at 8 %, while `GESTALTUNG.md`
# §6.3 has always demanded `#F7EBD6` there — white appears in **none** of the three
# colour boards. Under "Contrast" the edge therefore glowed colder than any text next
# to it, under "Midnight" it stayed put while everything else switched. The sentence
# "Colours come from the board" had stood at the `StripeBand` since E41; what was
# missing was a place where it cannot be bypassed.
COLORS=$(python3 ../scripts/colors.py --app phone 2>&1)
if [ $? -eq 0 ]; then
    echo "$COLORS" | while read -r line; do ok "$line"; done
else
    echo "$COLORS" | sed 's/^/    /'
    bad "System colour without a reason — python3 ../scripts/colors.py --app phone"
fi

# **And the same trap with font size** (10.09., AP5). `Font.system(size:)` is fixed:
# whoever sets the system font to `accessibilityExtraExtraExtraLarge` gets an app in
# which the text grows to 48 points and the chevron next to it stays at eleven — at
# that setting simply no longer visible. `Tokens.Typography` had always been built correctly;
# **38 places** bypassed it. None of them was a slip on its own, together they were the
# biggest item of this package.
FONTS=$(python3 ../scripts/type_scale.py --app phone 2>&1)
if [ $? -eq 0 ]; then
    echo "$FONTS" | while read -r line; do ok "$line"; done
else
    echo "$FONTS" | sed 's/^/    /'
    bad "Fixed font size without a reason — python3 ../scripts/type_scale.py --app phone"
fi

# ── 13 · Settings catalog ──────────────────────────────────────────────
step "Settings catalog"
# **A hand-maintained catalog goes stale silently** (E49): the search across the
# settings goes through `SettingsCatalog.swift`. Whoever adds a setting and forgets the
# catalog builds something that works and cannot be found — the error never reports
# itself. That is exactly what happened on 07.09. with the `SwipeMark`, one day after
# the comment there had predicted it word for word.
#
# Three things are checked: every operable row is in the catalog or, with a reason, in
# the exception list; every entry has a language key; and every jump target is actually
# drawn by the `TabPlaceholder` — the error type "linked but not built" has occurred
# three times in this project.
CATALOG_OUTPUT=$(python3 scripts/catalog.py --check 2>&1)
if [ $? -eq 0 ]; then
    echo "$CATALOG_OUTPUT" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$CATALOG_OUTPUT" | sed 's/^/    /'
    bad "Settings catalog incomplete — python3 scripts/catalog.py"
fi

# ── 13b · Device words ─────────────────────────────────────────────────
step "Device words"
# **Since AP7 the same app runs on the iPad** — and in Split View even in the narrow
# size class there, with an unchanged device identifier. A sentence that calls this
# device a phone is wrong there, and silently so. Four sentences name a phone and mean
# one too (the TV's menu item, a screen size, two pairs of opposites); they are listed
# with a reason in `MIT_GRUND`.
DEVICE_OUTPUT=$(python3 ../scripts/device_words.py --app phone --check 2>&1)
if [ $? -eq 0 ]; then
    echo "$DEVICE_OUTPUT" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$DEVICE_OUTPUT" | sed 's/^/    /'
    bad "Device word without a reason — python3 ../scripts/device_words.py --app phone"
fi

# ── 13b′ · Word choice ─────────────────────────────────────────────────
step "Word choice"
# **One term for one thing** (26.09.2026, report B, finding 25): "Kennwort", never
# "Passwort". The block list lives in `../scripts/glossary.py` and applies to both
# catalogs.
if WORD_OUTPUT=$(python3 ../scripts/glossary.py --app phone 2>&1); then
    echo "$WORD_OUTPUT" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$WORD_OUTPUT" | sed 's/^/    /'
    bad "Blocked word in the catalog — python3 ../scripts/glossary.py --app phone"
fi

# ── 13c · Size-class probe ─────────────────────────────────────────────
step "Size-class probe"
# **The simulator does not trigger the switch regular → compact** — Split View needs a
# second app, Stage Manager a window you drag. The probe forces it through
# `traitOverrides` and writes the numbers of `MetricClass` into the record. What is
# checked here is that it names **every** one of those numbers: an eighth number the
# probe does not know is never looked at in the half-width window and only turns up on
# the device.
SIZE_OUTPUT=$(python3 scripts/size_classes.py 2>&1)
if [ $? -eq 0 ]; then
    echo "$SIZE_OUTPUT" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
else
    echo "$SIZE_OUTPUT" | sed 's/^/    /'
    bad "Number without a probe — python3 scripts/size_classes.py"
fi

# ── 14 · App icon ──────────────────────────────────────────────────────
step "App icon"
# **The 1024 entry and the three appearances** (AP11): `release.sh` demands it on
# upload, and App Store Connect rejects without it — that should show up here and not
# only there. The set is produced by `scripts/appsymbol.py`.
ICON="App/Resources/Assets.xcassets/AppIcon.appiconset"
if python3 - "$ICON" <<'PY'
import json, os, sys
d = sys.argv[1]
entries = json.load(open(os.path.join(d, "Contents.json")))["images"]
appearances = set()
for e in entries:
    if e.get("size") != "1024x1024" or not e.get("filename"):
        continue
    if not os.path.exists(os.path.join(d, e["filename"])):
        print("    missing: " + e["filename"]); sys.exit(1)
    kind = e.get("appearances", [{}])[0].get("value", "light")
    appearances.add(kind)
absent = {"light", "dark", "tinted"} - appearances
if absent:
    print("    without appearance: " + ", ".join(sorted(absent))); sys.exit(1)
PY
then
    ok "1024 icon in all three appearances"
else
    bad "App icon incomplete — python3 ~/dev/apps/cinelounge-privat/intern/phone/scripts/appsymbol.py --uebernehmen <draft>"
fi

# **And every alternate-icon entry needs its files.** An entry without a file breaks
# nothing: the build goes through, and only on the device the call fails with "The
# requested image could not be found" — with a checkmark that stays and an icon that
# does not change. All three resolutions are checked, because which one the device
# fetches is the device's decision.
#
# `App/Info.plist` is a product of `project.yml` and is listed in `.gitignore`: in a
# freshly fetched directory it only exists after `scripts/project.sh`. That is not a
# failure but a missing prerequisite — as with compiling above.
if [ ! -f App/Info.plist ]; then
    warn "No App/Info.plist — run scripts/project.sh first"
elif python3 - App/Info.plist App/AlternateIcons <<'PY'
import os, plistlib, sys
plist, folder = sys.argv[1], sys.argv[2]
icons = plistlib.load(open(plist, "rb")).get("CFBundleIcons") or {}
if (icons.get("CFBundlePrimaryIcon") or {}).get("CFBundleIconName") != "AppIcon":
    print("    CFBundlePrimaryIcon does not name the AppIcon catalog"); sys.exit(1)
alternates = icons.get("CFBundleAlternateIcons") or {}
if not alternates:
    print("    no alternate icons registered"); sys.exit(1)
missing = [f"{name}: {base}{suffix}.png"
           for name, entry in sorted(alternates.items())
           for base in entry.get("CFBundleIconFiles", [])
           for suffix in ("", "@2x", "@3x")
           if not os.path.exists(os.path.join(folder, f"{base}{suffix}.png"))]
if missing:
    print("    missing: " + "\n    missing: ".join(missing)); sys.exit(1)
PY
then
    ok "every alternate icon has its files"
else
    bad "Alternate icons incomplete — python3 ~/dev/apps/cinelounge-privat/intern/phone/scripts/appsymbol.py --wechsel"
fi

# ── 15 · Airplane-mode launch ──────────────────────────────────────────
# ROADMAP A4: open the app without a network, the downloads are there immediately, no
# loading spinner, no sign-in attempt. Plex and the ARD Mediathek fail exactly here,
# and both HAVE downloads.
#
# **Built halfway, and the other half is not claimed** (07.09.).
#
# **What is checked here:** the app starts against a server that never answers (port 9,
# the discard service), keeps running afterwards — and **writes not a single network
# error** while doing so. That is the measurable version of "no sign-in attempt":
# `Startup` explicitly promises "not: sign in, reload, ask the server", and whoever did
# it anyway would leave a line in the ledger. No server, no line — then the promise
# holds.
#
# **What is NOT checked here, and why it is listed anyway:**
#   · "The downloads are there immediately" — the downloads do not exist (AP2). The
#     step is not superfluous, but early.
#   · "No loading spinner" — cannot be decided from pixels; to a script a spinner and a
#     shelf look the same.
# A step that claims more than it measures is worse than one that is missing.
step "Airplane-mode launch"
if [ -z "$SIM_ID" ] || [ ! -d ".dd/Build/Products/Debug-iphonesimulator/CineLounge.app" ]; then
    warn "no built bundle — step skipped"
else
    # **Try twice, and only the second failure counts** (07.09.).
    #
    # The step was flaky at first: green one time, red the next, with an unchanged app.
    # Reproduced by hand three times **at rest** — install, launch, wait — it ran every
    # time, without a single crash report. The difference is the **load state**: here the
    # step sits right behind the release build, which compiles and tests six packages
    # under `-O`. A freshly installed bundle that fails to come up once under that is no
    # finding about the app.
    #
    # **A guard that raises false alarms is worse than none** — and one that forgives
    # every failure is none. Hence two attempts and not arbitrarily many.
    # **Boot first, then measure** (08.09.).
    #
    # The step was red twice in a row with "The app is no longer running after launch
    # without a server" — and the app was fine: by hand it ran, and not a single crash
    # report was in the simulator. The difference was a **switched-off** device.
    # `simctl launch` then boots it on the side, and a cold start takes longer than the
    # sixteen seconds this step waits.
    #
    # That is exactly the false alarm the paragraph above warns about — only with a
    # different cause than assumed. `bootstatus -b` boots if necessary and **waits it
    # out**; on a running device it costs nothing.
    xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1

    AIRPLANE_OK=0
    AIRPLANE_REASON=""
    for attempt in 1 2; do
        xcrun simctl terminate "$SIM_ID" dev.ms-solutions.cinelounge 2>/dev/null
        xcrun simctl install "$SIM_ID" .dd/Build/Products/Debug-iphonesimulator/CineLounge.app >/dev/null 2>&1
        SINCE_AIRPLANE=$(date '+%Y-%m-%d %H:%M:%S')
        # Port 9 discards whatever arrives and never answers — you cannot get closer to
        # "no network" without airplane mode, and `simctl` cannot switch that.
        START=$(SIMCTL_CHILD_CINELOUNGE_SERVER="http://127.0.0.1:9" \
            xcrun simctl launch "$SIM_ID" dev.ms-solutions.cinelounge 2>&1)
        if ! echo "$START" | grep -q "dev.ms-solutions.cinelounge:"; then
            AIRPLANE_REASON="The app does not even start without a server: $START"
            continue
        fi
        # **We wait for a state and not for a clock.**
        #
        # **Thirty seconds and not sixteen** (08.09., third false alarm). By hand the app
        # is in `launchctl list` after **under two** seconds; the step was red
        # exclusively right behind the release build, which compiles six packages under
        # `-O`. What is measured here is **whether** the app comes up without a server
        # and stays up — not how fast. A window that gets tight under load measures the
        # machine's utilisation and not the app.
        # **And a silent probe is not an absence** (10.09.) — the same lesson as in the
        # part without a network further down, and the same reason: under load
        # `simctl spawn` hands out an empty answer, and `2>/dev/null` silently turned
        # that into "the app is gone". Measured afterwards, it stood in exactly this list
        # with its PID.
        RUNNING=0
        for _ in $(seq 20); do
            sleep 2
            LIST=$(xcrun simctl spawn "$SIM_ID" launchctl list 2>&1) || LIST=""
            [ -z "$LIST" ] && continue
            if printf '%s' "$LIST" | grep -q "dev.ms-solutions.cinelounge"; then
                RUNNING=1
                break
            fi
        done
        if [ "$RUNNING" = 0 ]; then
            AIRPLANE_REASON="The app is no longer running after launch without a server"
            [ "$attempt" = 1 ] && hint "first attempt lost — once more"
            continue
        fi
        # One more breath, so that the first draw would also be in the ledger.
        sleep 3
        # **What is counted is the area tag.** `Diagnose` puts it in front of
        # every line; a sign-in, a reload or a server query would leave exactly one here
        # — "NETZ" or "ANM ".
        NETWORK=$(xcrun simctl spawn "$SIM_ID" log show --start "$SINCE_AIRPLANE" \
            --predicate "processImagePath CONTAINS \"CineLounge\"" \
            --style compact 2>/dev/null | grep -cE "$NETWORK_MARKER" || true)
        if [ "${NETWORK:-0}" -gt 0 ]; then
            AIRPLANE_REASON="$NETWORK network message(s) at launch — Startup promises none"
            break
        fi
        AIRPLANE_OK=1
        break
    done
    if [ "$AIRPLANE_OK" = 1 ]; then
        ok "starts without a server, keeps running, no sign-in attempt"
    else
        bad "$AIRPLANE_REASON"
    fi

    # **And the same launch without a network** (AP3, 08.09.).
    #
    # `CINELOUNGE_OHNE_NETZ=1` sets the network path to "none" without arming the guard —
    # `simctl` cannot switch airplane mode itself. The tab bar then drops away and the
    # downloads remain alone (``BarState``). What is measured is the same as above:
    # the app comes up, stays up, and writes **no** network or sign-in line while doing
    # so.
    #
    # **That the bar is really gone, this step does not measure** — to a script a bar and
    # no bar look the same. What it measures is the case Plex and the ARD Mediathek fail
    # at: that the app survives this state at all.
    if [ "$AIRPLANE_OK" = 1 ]; then
        # **Two attempts as above** (08.09., learned on the first run): this part had only
        # one at first and therefore reported red where the part above was green — with the
        # same app, on the same device, in the same minute. A guard that leaves out half of
        # its own caution raises false alarms; by hand the app came up immediately every
        # time.
        OFFLINE_RUNNING=0
        for attempt_offline in 1 2; do
            SINCE_OFFLINE=$(date '+%Y-%m-%d %H:%M:%S')
            xcrun simctl terminate "$SIM_ID" dev.ms-solutions.cinelounge 2>/dev/null
            # **A breath between terminating and launching** (08.09.): the part above has
            # an `install` in between, which takes a few seconds on its own; here the
            # launch followed immediately, and the system handed out a PID while the old
            # process was still winding down. `launchctl list` then found none.
            sleep 3
            START_OFFLINE=$(SIMCTL_CHILD_CINELOUNGE_SERVER="http://127.0.0.1:9" \
                SIMCTL_CHILD_CINELOUNGE_OHNE_NETZ=1 \
                xcrun simctl launch "$SIM_ID" dev.ms-solutions.cinelounge 2>&1)
            # **A silent probe is not an absence** (10.09., third false alarm in one day).
            # Until here the rule was: `launchctl list` does not name the app, so it is not
            # running. Measured afterwards, both were wrong — the app stood in exactly this
            # list with its PID, and by hand it came up immediately. What failed is
            # `simctl spawn` itself: when a release build runs alongside, it hands out an
            # empty answer under load, and `2>/dev/null` silently turned that into a "no".
            #
            # An empty list now means **nothing** and is not counted. Only a list that really
            # is one and does not contain the app speaks against it.
            for _ in $(seq 20); do
                sleep 2
                LIST_OFFLINE=$(xcrun simctl spawn "$SIM_ID" launchctl list 2>&1) || LIST_OFFLINE=""
                [ -z "$LIST_OFFLINE" ] && continue
                if printf '%s' "$LIST_OFFLINE" | grep -q "dev.ms-solutions.cinelounge"; then
                    OFFLINE_RUNNING=1
                    break
                fi
            done
            [ "$OFFLINE_RUNNING" = 1 ] && break
            [ "$attempt_offline" = 1 ] && hint "first attempt without network lost — once more"
        done
        sleep 3
        if [ "$OFFLINE_RUNNING" = 0 ]; then
            bad "Without a network the app does not come up: $START_OFFLINE"
        else
            NETWORK_OFFLINE=$(xcrun simctl spawn "$SIM_ID" log show --start "$SINCE_OFFLINE" \
                --predicate "processImagePath CONTAINS \"CineLounge\"" \
                --style compact 2>/dev/null | grep -cE "$NETWORK_MARKER" || true)
            if [ "${NETWORK_OFFLINE:-0}" -gt 0 ]; then
                bad "$NETWORK_OFFLINE network message(s) at launch without a network"
            else
                ok "starts without a network, the downloads remain, no network message"
            fi
        fi
    fi
    hint "Whether the bar is really gone only the eye can tell — see entwuerfe/LADENPRUEFUNG.md"
fi

# ── Wrap-up ───────────────────────────────────────────────────────────
echo
if [ "$FAILED" = 0 ]; then
    printf '\033[32mAll passed — tick the roadmap (~/dev/apps/cinelounge-privat/intern/phone) and check in.\033[0m\n'
else
    printf '\033[31mNot passed.\033[0m\n'
    exit 1
fi
