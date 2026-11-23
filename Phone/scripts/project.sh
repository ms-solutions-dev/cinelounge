#!/bin/bash
# Generates CineLounge.xcodeproj from project.yml.
#
# The TV project lacks this script — there the invocation only appears in the README,
# XcodeGen is not installed on this machine at all, and the build is therefore the
# only step that cannot be repeated from the directory alone. Here that is not
# supposed to happen again.
set -uo pipefail
cd "$(dirname "$0")/.."

# **Local additions** (optional): `../checks.local.sh` may set `PHONE_XCODEGEN_SPEC`, the spec
# to generate from, relative to this folder (default `project.yml`).
[ -f ../checks.local.sh ] && . ../checks.local.sh
SPEC=${PHONE_XCODEGEN_SPEC:-project.yml}

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '\033[31m✗\033[0m %s\n' "$1"; }
hint() { printf '\033[90m  %s\033[0m\n' "$1"; }

step "Finding XcodeGen"
# ~/.local/bin is not on the search path on this machine. Instead of touching the
# .zshrc, the script looks there itself — that keeps the build repeatable from the
# directory, no matter who starts it.
XCODEGEN=""
for candidate in \
    "$(command -v xcodegen 2>/dev/null)" \
    "$HOME/.local/bin/xcodegen" \
    "$HOME/.local/xcodegen/bin/xcodegen"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then XCODEGEN="$candidate"; break; fi
done
# Invoked through a symlink, XcodeGen looks for its templates next to the SYMLINK
# instead of next to the executable, does not find share/xcodegen/SettingPresets and
# only reports "No base settings found" — whereupon PRODUCT_NAME is missing and the
# product is called ".app". The build then aborts with "Multiple commands
# produce .../.app", and none of that names the cause. That is why the path is
# resolved here.
if [ -n "$XCODEGEN" ]; then
    XCODEGEN=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$XCODEGEN")
fi
if [ -z "$XCODEGEN" ]; then
    bad "XcodeGen not found."
    hint "Without XcodeGen there is no Xcode project — project.yml is the truth,"
    hint "the .xcodeproj is the product and is listed in .gitignore."
    hint ""
    hint "Installing without Homebrew (there is none on this machine):"
    hint "  V=2.46.0"
    hint "  curl -sSL -o /tmp/xcodegen.zip \\"
    hint "    https://github.com/yonaskolb/XcodeGen/releases/download/\$V/xcodegen.zip"
    hint "  unzip -q /tmp/xcodegen.zip -d /tmp/xg"
    hint "  cp -R /tmp/xg/xcodegen ~/.local/xcodegen"
    hint "  ln -sf ~/.local/xcodegen/bin/xcodegen ~/.local/bin/xcodegen"
    hint ""
    hint "The share/ directory must sit next to bin/ — the version from the"
    hint "zip carries its templates there, and without them xcodegen aborts."
    exit 1
fi
ok "$("$XCODEGEN" --version 2>&1 | head -1) — $XCODEGEN"

step "Checking the neighbouring project"
# Six packages come in over a path from the TV part — since the merge (decision 17)
# from `../Packages` in the same repo. If they are missing, SwiftPM reports a path
# error that nobody connects with this cause.
NEIGHBOUR="../Packages"
if [ ! -d "$NEIGHBOUR/Core" ]; then
    bad "$NEIGHBOUR/Core not found."
    hint "The shared packages live in the repo root under Packages/;"
    hint "the phone lives below it in Phone/ (decision 17)."
    exit 1
fi
MISSING=0
for p in Core JellyfinKit PlaylistKit PortalKit RatingsKit Playback; do
    if ! grep -q "\.iOS(" "$NEIGHBOUR/$p/Package.swift"; then
        bad "$p does not declare iOS."
        MISSING=1
    fi
done
if [ "$MISSING" = 1 ]; then
    hint "ROADMAP stage 3, B1: the six shared Package.swift files must contain"
    hint "  platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)]"
    hint "Without this line SwiftPM rejects them here."
    hint "That is the first step of the build — not a bug in this script."
    exit 1
fi
ok "All six shared packages declare iOS"

step "Generating the project"
# `--project-root .`: paths in every spec are relative to this folder, also in a spec that
# lives elsewhere and includes `project.yml`. Which spec built the project is remembered next
# to it, so that `check.sh` notices a switch.
"$XCODEGEN" generate --spec "$SPEC" --project . --project-root . || exit 1
printf '%s\n' "$SPEC" > CineLounge.xcodeproj/.cl-spec
ok "CineLounge.xcodeproj is in place ($SPEC)"
