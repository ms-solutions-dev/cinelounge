#!/usr/bin/env bash
# Quality run after every stage: format, lint, language keys, test, build.
#
# Both tools already ship with the Xcode toolchain, nothing needs to be installed.
# swift-format covers both roles: `format` corresponds to Prettier, `lint`
# corresponds to ESLint.
set -uo pipefail
cd "$(dirname "$0")/.."
./scripts/disk-space.sh || exit 1

# **Local additions** (optional): `checks.local.sh` in the root may set
#   XCODEGEN_SPEC        the project spec to generate from (default `project.yml`),
#   EXTRA_PACKAGE_DIRS   further package folders, space-separated, that are formatted,
#                        linted and tested like those under `Packages/`.
# The file is not part of the repository's own content; a build that has none uses the
# defaults. How an app extension is loaded is described at `AppExtensions` (PortalKit).
[ -f ./checks.local.sh ] && . ./checks.local.sh
SPEC=${XCODEGEN_SPEC:-project.yml}
. ./scripts/project-spec.sh
read -r -a EXTRA_PKGS <<< "${EXTRA_PACKAGE_DIRS:-}"

# Xcode 27 calls the device just "Apple TV 4K"; so look for the identifier of the
# first Apple TV simulator instead of a fixed name.
SIM_ID=$(xcrun simctl list devices available 2>/dev/null |
    sed -nE 's/^ *Apple TV 4K[^(]*(\([^)]*\) )?\(([0-9A-F-]{36})\).*/\2/p' | head -1)
SIM="platform=tvOS Simulator,id=${SIM_ID:-unknown}"
SOURCES=(App Packages ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"})
fail=0

# swift-format lives in the Xcode toolchain and not on the search path.
FORMAT=$(xcrun --find swift-format 2>/dev/null)
if [ -z "$FORMAT" ]; then
    echo "swift-format not found — it belongs to the Xcode toolchain from Swift 6."
    exit 1
fi

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

# ── Format ───────────────────────────────────────────────────────────────────
step "Format"
if [ -d App ] || [ -d Packages ]; then
    if "$FORMAT" format -i -r --configuration .swift-format "${SOURCES[@]}"; then
        ok "source formatted"
    else
        bad "formatting failed"
    fi
else
    echo "  skipped — no sources yet"
fi

# ── Lint ─────────────────────────────────────────────────────────────────────
step "Lint"
if [ -d App ] || [ -d Packages ]; then
    lint_out=$("$FORMAT" lint --strict -r --configuration .swift-format "${SOURCES[@]}" 2>&1)
    if [ -z "$lint_out" ]; then
        ok "no findings"
    else
        echo "$lint_out" | head -20
        bad "$(echo "$lint_out" | grep -c .) findings"
    fi
else
    echo "  skipped — no sources yet"
fi

# ── Project files ────────────────────────────────────────────────────────────
# **`App/Info.plist` and `CineLounge.xcodeproj` are GENERATED** — from
# `project.yml`, by XcodeGen —, and both are in `.gitignore`. Until 2026-09-11
# nobody did that automatically, and `xcodebuild` builds whatever is lying there:
#
#   project.yml   10.09. 16:26   (`_cinelounge-fern._tcp` added)
#   App/Info.plist 10.09. 11:30   (five hours older)
#
# Consequence: The remote's Bonjour service was in **no** build since 10.09. at
# 16:26. Without the entry the service does not even register, and the phone
# finds nothing — with no error message on either side. That is exactly what the
# comment at `project.yml:184-187` warns about, and exactly what happened.
#
# **Generate, do not just warn.** A warning that can be clicked away is the wrong
# kind of help for a silent failure. If XcodeGen is missing, the run aborts
# instead of building on: A build from stale project files is worse than no
# build, because it is green.
# **And the call goes through the REAL path, not through a symlink.**
# XcodeGen looks for its SettingPresets relative to the executed file, that is in
# `<bin>/../share/xcodegen/SettingPresets`. Here `~/.local/bin/xcodegen` is a
# symlink to `~/.local/xcodegen/bin/xcodegen`; called through it, XcodeGen looks
# in `~/.local/share/…`, finds nothing and reports four lines of
# "No \"base\" settings found". **That is not a warning, that is a broken
# project:** Without the presets `PRODUCT_NAME` is missing, both targets produce a
# product without a name, and `xcodebuild` aborts with "Multiple commands produce
# '.app'". Happened exactly like this on 2026-09-11.
step "Project files"
GEN=$(command -v xcodegen || echo "$HOME/.local/bin/xcodegen")
# Resolve symlinks for as long as there is one.
while [ -L "$GEN" ]; do
    target=$(readlink "$GEN")
    case "$target" in
        /*) GEN=$target ;;
        *)  GEN=$(dirname "$GEN")/$target ;;
    esac
done
# **Which spec built the project is remembered** next to it (`.cl-spec`): a project generated
# from a different spec is stale even when no file is newer than `App/Info.plist`. The
# comparison is `project_from_spec` (scripts/project-spec.sh), shared with release and device.
spec_stamp=CineLounge.xcodeproj/.cl-spec
if [ ! -f project.yml ]; then
    echo "  skipped — no project.yml"
elif [ ! -x "$GEN" ]; then
    bad "xcodegen is missing — App/Info.plist and the Xcode project may be stale"
    echo "    project.yml is the source; the generated files are in .gitignore."
elif [ project.yml -nt App/Info.plist ] || [ "$SPEC" -nt App/Info.plist ] \
    || ! project_from_spec "$SPEC" >/dev/null; then
    # `--project-root .`: paths in every spec are relative to this folder, also in a spec
    # that lives in a subfolder and includes `project.yml`.
    gen_out=$("$GEN" generate --spec "$SPEC" --project . --project-root . 2>&1)
    if [ $? -ne 0 ]; then
        echo "$gen_out" | head -10
        bad "xcodegen failed"
    elif printf '%s' "$gen_out" | grep -q "settings found"; then
        # See above: This message means the presets are missing. Leaving the
        # project lying there would be worse than having none — it does not
        # build, and the reason is not in the build but here.
        printf '%s' "$gen_out" | grep "settings found" | head -4
        bad "xcodegen cannot find its SettingPresets — generated project is unusable"
        echo "    The call must point at the real file, not at a symlink:"
        echo "    <install>/bin/xcodegen looks for <install>/share/xcodegen/SettingPresets."
    else
        printf '%s\n' "$SPEC" > "$spec_stamp"
        ok "regenerated from $SPEC"
    fi
else
    ok "project files are up to date with $SPEC"
fi

# ── Language keys ────────────────────────────────────────────────────────────
# A missing key breaks neither a build nor a check — it only shows up on the TV,
# as a bare key name on a card. That is why the checker is a step of its own and
# not an appendix; the full rationale is in scripts/strings.py.
step "Language keys"
if [ -f scripts/strings.py ]; then
    strings_out=$(python3 scripts/strings.py 2>&1)
    if [ $? -eq 0 ]; then
        ok "$(printf '%s' "$strings_out" | head -1 | sed 's/^ *//')"
    else
        echo "$strings_out"
        bad "language keys incomplete"
    fi
else
    echo "  skipped — no check script"
fi

# ── Alternate icons ──────────────────────────────────────────────────────────
# The flat PNGs of the alternate icons are computed from the image stacks in the
# catalog and sit next to them in the bundle. Because both are checked in, they
# can drift apart: Whoever changes a layer and forgets to regenerate builds
# without any error — the tile then switches to the OLD image. It would only show
# on the TV, and in the worst case only after the upload.
step "Alternate icons"
if [ -f scripts/alternate_icons.py ]; then
    if sym_out=$(python3 scripts/alternate_icons.py --check 2>&1); then
        ok "$(printf '%s' "$sym_out" | tail -1)"
    else
        printf '%s\n' "$sym_out" | sed 's/^/    /'
        bad "alternate icons do not match the image stacks"
    fi
else
    echo "  skipped — no generator script"
fi

# ── Analysis scripts ─────────────────────────────────────────────────────────
# The scripts in scripts/ are measuring tools themselves, and a tool that measures
# wrongly goes unnoticed — after all, it reports something. `focus_trace.py` was
# wrong in two places until 26.08. without any run seeing it. The doctests
# therefore belong in the quality run and not beside it.
step "Analysis scripts"
if [ -f scripts/focus_trace.py ]; then
    if doctest_out=$(python3 -m doctest -v scripts/focus_trace.py \
        scripts/silent-errors.py scripts/strings.py 2>&1); then
        ok "$(printf '%s' "$doctest_out" | grep -c '^Trying:') doctests in scripts/"
    else
        printf '%s' "$doctest_out" | grep -B2 -A8 "Failed example" | head -24
        bad "doctests failed"
    fi
else
    echo "  skipped — no analysis script"
fi

# ── The storage rule ─────────────────────────────────────────────────────────
#
# **The "done when" commitment of AP40** (2026-09-20): The rule for where a
# setting belongs is in `README.md` — what was missing was something that notices
# when it is kept. What is reported are **places**, not keys; the reason for that
# is in the head of the script.
step "Storage rule"
if store_out=$(python3 scripts/storage_rule.py 2>&1); then
    ok "$(printf '%s' "$store_out" | tail -1 | sed 's/^ *//')"
else
    printf '%s\n' "$store_out"
    bad "default storage touched without a reason"
fi

# ── Guards of both programs ──────────────────────────────────────────────────
#
# **Until 2026-09-26 they ran only on the phone** (AP58, report B, findings
# 23–26): The TV catalog had 32 counters without a plural form, a shared sentence
# said "Dieser Fernseher braucht ein Profil.", 17 system colors stood without a
# reason, and "Passwort" stood next to "Kennwort". The scripts now live ONCE under
# scripts/ and know both programs (`programs.py`); what differs per program is
# there and in the scripts themselves — most clearly the font rule, which on the
# TV leaves symbols free and forces only text onto the scale.
guard() {  # guard <step name> <error text> <script> [arguments…]
    local name=$1 error_text=$2 script=$3
    shift 3
    step "$name"
    local output
    if output=$(python3 "scripts/$script" --app tv "$@" 2>&1); then
        printf '%s\n' "$output" | sed 's/^✓ //' | while read -r line; do ok "$line"; done
    else
        printf '%s\n' "$output" | sed 's/^/    /'
        bad "$error_text — python3 scripts/$script --app tv"
    fi
}
guard "Plural forms" "Counters without a plural form" plurals.py --check
guard "Device words" "Shared sentence names a device" device_words.py --check
guard "Word choice" "Forbidden word in the catalog" glossary.py
guard "Color table" "System color without a reason" colors.py
guard "Type scale" "Fixed font size beside the scale" type_scale.py
guard "Silent failures" "catch blocks without a record" silent-errors.py

# ── Tests ────────────────────────────────────────────────────────────────────
step "Tests"
if [ -d Packages ]; then
    total=0
    for pkg in Packages/*/ ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}; do
        [ -f "$pkg/Package.swift" ] || continue
        name=$(basename "$pkg")
        out=$( (cd "$pkg" && swift test 2>&1) )

        # If the test process crashes with signal 11 while all tests themselves
        # pass, the cause is a stale intermediate state: A new field in one of the
        # local packages changes the memory layout, and the already built test part
        # no longer matches it. Building from scratch once cleans that up. Without
        # this remedy one looks for the error in one's own code, where there is
        # none.
        # Two manifestations, both with the same cause: a stale intermediate state
        # in the package.
        #
        # Signal 11 occurs when a new field in a local package changes the memory
        # layout and the already built test part no longer matches it.
        #
        # "cannot find" occurs when a package does not see a NEW file of another
        # local package. That is the nastier case, because it looks like an error in
        # one's own code: The type is visibly there, the package it lives in is
        # green — and only this one package claims not to know it. Without this
        # remedy one looks for the error where there is none.
        #
        # The search pattern covers BOTH wordings. On the first attempt only
        # "cannot find type" stood here, and the remedy did not take: For a missing
        # type from a foreign package Swift writes "cannot find 'X' in scope"
        # without the word type. Six packages then stood red, although only an
        # intermediate state was old.
        #
        # That "cannot find" also strikes on a real typo is accepted: It then costs
        # one rebuild, and afterwards the actual error stands there. The opposite
        # mistake costs an hour of searching in the wrong place.
        #
        # THIRD manifestation, added when a field in `Core` grew: The linker aborts
        # ("link command failed", "linker command failed") while all sources
        # compile. That, too, is only an old intermediate state — visible from the
        # fact that it hit precisely the packages that knew nothing of the change,
        # and that the same state built for the TV. Without this remedy one looks
        # for the error in a linkage that is fine.
        # FOURTH manifestation — and the only one where a rebuild does NOT help
        # (AP50, 2026-09-23). On 27.08. a new test suite called a static
        # computation of `FilmographySheet`. That is a `View`, hence bound to the
        # main actor, and so are its statics. From an unbound suite the call
        # compiles without complaint and only falls into the isolation check at
        # run time: **Signal 5**, the process dies in the middle of the run, and
        # the message names only the process — no `✘`, no case, no file.
        #
        # **Building from scratch twice did not help**, because it was no stale
        # intermediate state. Precisely for that reason signal 5 stands here
        # separately and not in the line below: The remedy "rebuild" would be the
        # wrong answer there, and a wrong answer that takes two minutes is more
        # expensive than none. The remedy is an `@MainActor` on the test suite.
        if printf '%s' "$out" | grep -qE "unexpected signal code 5"; then
            printf '  \033[2m%s — signal 5: a test suite touches something owned by the main actor.\033[0m\n' "$name"
            printf '  \033[2m   Not a stale intermediate state — a rebuild does not help. Find the\033[0m\n'
            printf '  \033[2m   test suite that calls a static of a `View`, and put\033[0m\n'
            printf '  \033[2m   `@MainActor` in front of it.\033[0m\n'
        fi

        if printf '%s' "$out" | grep -qE "unexpected signal code 11|cannot find|link command failed|linker command failed"; then
            printf '  \033[2m%s — intermediate state stale, rebuilding\033[0m\n' "$name"
            rm -rf "$pkg/.build"
            out=$( (cd "$pkg" && swift test 2>&1) )
        fi

        if echo "$out" | grep -q "Test run with .* passed"; then
            count=$(echo "$out" | grep -oE "Test run with [0-9]+ test" | grep -oE "[0-9]+" | head -1)

            # Subtract skipped tests. Swift Testing counts a test skipped with
            # `.enabled(if:)` in the total — measured on 29.08. on PlaylistKit: 226
            # reported, 225 actually ran, one skipped. Uncounted, the final line
            # thus claims more evidence than there is, and that is exactly the case
            # E2 eliminates: A counter that can never go up is no evidence. The
            # skipped ones are still named and not concealed — whoever needs them
            # should see that they are missing.
            skipped=$(echo "$out" | grep -cE "Test .* skipped")
            count=$((${count:-0} - skipped))
            total=$((total + count))
            if [ "$skipped" -gt 0 ]; then
                ok "$name — $count tests ($skipped skipped)"
            else
                ok "$name — $count tests"
            fi
        else
            echo "$out" | grep -E "error:|✘|failed" | head -12
            bad "$name"
        fi
    done
    [ $fail -eq 0 ] && printf '  \033[2m%s tests in total\033[0m\n' "$total"
else
    echo "  skipped — no packages yet"
fi

# ── Build ────────────────────────────────────────────────────────────────────
# Important: The return value must come from the build itself, not from the
# downstream filter — otherwise a successful build reports an error just because
# the search pattern did not occur in the shortened output.
step "Build for the tvOS simulator"
if [ -f project.yml ]; then
    # **Always build from scratch** (AP15, 02.09.). The build was incremental, and
    # only what was compiled in THIS run was counted: In the counter-test, 2
    # warnings stood there instead of 9. A number that depends on what happened to
    # still be lying in the intermediate state is no number — and a gate that one
    # opens with a second run is none.
    #
    # **Only the products, not the fetched packages.** The first attempt threw
    # away all of `.dd` — and with it the resolved third-party packages. That not
    # only costs a network fetch every time, it also goes wrong as soon as two
    # runs overlap: "already exists unexpectedly", and the build aborts although
    # nothing is missing in the source.
    rm -rf .dd/Build
    build_out=$(xcodebuild -project CineLounge.xcodeproj -scheme CineLounge \
        -destination "$SIM" -derivedDataPath .dd build 2>&1)
    if [ $? -eq 0 ]; then
        ok "build succeeded"
        # **Only real compiler warnings.** The messages of the helper tools
        # ("appintentsmetadataprocessor … warning: Metadata extraction skipped")
        # carry a timestamp and a process number; `sort -u` therefore never merges
        # them, and they used to count as two warnings that nobody can fix. A
        # compiler warning is recognized by the location in front of it: path,
        # line, column.
        warnings=$(printf '%s' "$build_out" \
            | grep -E "^/.*\.swift:[0-9]+:[0-9]+: warning:" | sort -u | grep -c .)
        if [ "$warnings" -gt 0 ]; then
            printf '%s' "$build_out" \
                | grep -E "^/.*\.swift:[0-9]+:[0-9]+: warning:" | sort -u | head -12
            bad "$warnings warnings — the build is clean only without them"
        fi
    else
        echo "$build_out" | grep -E "error:" | sort -u | head -12
        bad "build failed"
    fi
else
    echo "  skipped — project not created yet"
fi

# ── Release build ────────────────────────────────────────────────────────────
# **The first -O build of a state used to be the TestFlight upload.**
#
# Precisely beneath that, on 23.08., an error could arise and survive that would
# have left the whole app without pictures: `withParameterSetPointers` handed
# dangling pointers outward. In the debug build the memory happens to survive long
# enough, with -O every channel fails with -12712. It was found by a check agent
# that happened to build in release — not by this chain.
#
# That is why the test suite now additionally runs with -O. After the first build
# that costs a few seconds per package.
# **And here the gate for the packages holds** (AP15, 02.09.). The debug run above
# is incremental and does not see the warnings of the packages at all — that is
# exactly where the two from ``SeriesEpisodeIndexStore`` stood, unseen for months.
# The release build recompiles everything anyway; `-warnings-as-errors` costs
# nothing there and turns a number that nobody interprets into a failure that
# nobody can overlook.
step "Test suite in the release build"
release_fail=0
# **The list was not "all"** (looked at 2026-09-21, AP41): Parental controls and
# second screen were missing ever since they exist — the message below claimed it
# anyway. A claim that nobody recounts is as good as no check.
# **Since 2026-09-26 a glob as on the phone** (AP58, finding A4): A list that
# somebody has to maintain forgets the next package just the same.
for pkg_path in Packages/*/ ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}; do
    [ -f "$pkg_path/Package.swift" ] || continue
    pkg=$(basename "$pkg_path")
    if ! out=$(swift test -c release --package-path "$pkg_path" \
        -Xswiftc -warnings-as-errors 2>&1); then
        printf '  \033[31m✗\033[0m %s\n' "$pkg"
        printf '%s\n' "$out" | grep -E "error:|✘" | sort -u | head -6
        release_fail=1
    fi
done
if [ $release_fail -eq 0 ]; then
    ok "all packages green with -O and without warnings, too"
else
    bad "release build has different results than the debug build"
fi

printf '\n'
if [ $fail -eq 0 ]; then
    printf '\033[32m✓ Everything passed — tick the roadmap (~/dev/apps/cinelounge-privat/intern) and commit.\033[0m\n'
else
    printf '\033[31m✗ Something failed — see above.\033[0m\n'
    exit 1
fi
