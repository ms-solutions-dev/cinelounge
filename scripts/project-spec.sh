# shellcheck shell=bash
# Was the Xcode project in the current folder generated from the expected spec?
#
# Sourced by scripts/check.sh, scripts/release.sh, scripts/device.sh and their Phone
# counterparts; each runs it in its own project folder (root or `Phone/`).
#
# **Why the stamp alone is not enough** (22.11.2026, measured): `xcodegen generate` run by
# hand rewrites `project.pbxproj` and `App/Info.plist` but leaves `.cl-spec` from the last
# scripted run in place. The stamp then names a spec the project no longer comes from — and
# an archive built from it is missing whatever that spec added (packages, Info.plist keys)
# without a single error. Hence three checks:
#   1. the stamp names the spec,
#   2. nothing was generated after the stamp was written,
#   3. `CLExtensionClasses`, when the spec sets it, is in the generated Info.plist.
#
# The default spec `project.yml` is what a plain `xcodegen generate` uses, so a project
# without stamp or with a newer hand-made generation still counts as coming from it.
#
#   project_from_spec <spec>   → status 0 if it matches; otherwise the reason on stdout, status 1

project_from_spec() {
    local spec=$1 stamp=CineLounge.xcodeproj/.cl-spec built
    if [ ! -f CineLounge.xcodeproj/project.pbxproj ] || [ ! -f App/Info.plist ]; then
        echo "no generated project"
        return 1
    fi
    if [ -f "$stamp" ]; then
        built=$(cat "$stamp")
    elif [ "$spec" = project.yml ]; then
        built=project.yml
    else
        echo "generated without a record of its spec"
        return 1
    fi
    if [ "$built" != "$spec" ]; then
        echo "generated from $built, expected $spec"
        return 1
    fi
    if [ "$spec" != project.yml ] && { [ CineLounge.xcodeproj/project.pbxproj -nt "$stamp" ] \
        || [ App/Info.plist -nt "$stamp" ]; }; then
        echo "generated again after the scripted run (by hand?), not from $spec"
        return 1
    fi
    if grep -q 'CLExtensionClasses' "$spec" 2>/dev/null \
        && ! /usr/libexec/PlistBuddy -c "Print :CLExtensionClasses" App/Info.plist >/dev/null 2>&1; then
        echo "App/Info.plist lacks CLExtensionClasses that $spec sets"
        return 1
    fi
    return 0
}
