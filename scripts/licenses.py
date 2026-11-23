#!/usr/bin/env python3
"""The licenses of the third-party packages — generated, not maintained.

The same rule as for the app icon (`appsymbol.py`): Whoever adds a dependency runs the
script. A hand-maintained list drifts apart on the first day someone swaps a package —
and unnoticed, because a wrong license list looks like a right one.

**What is read is what really travels along**, and not what someone considers likely:
`Package.resolved` of the Xcode project names the resolved packages including their
version, and `.dd/SourcePackages/checkouts/` holds their sources including the license
file. If none turns up for a package, the list says so explicitly — an invented entry
would be worse for a license than a missing one.

Why at all: Apple does not require third-party licenses, the licenses themselves do.
Apache 2.0 §4 and the MIT license both want notice and license text to be shipped along.

**Pulled over from the phone project on 11.09.2026** (AP26), verbatim except for the
paths: Both programs resolve the same seven packages, and a second version of the same
script would drift apart at the first package change.

Usage:   python3 scripts/licenses.py            → App/Resources/Licenses.json
         python3 scripts/licenses.py --check  → only report what is missing (returns 1)
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RESOLVED = os.path.join(
    ROOT, "CineLounge.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm",
    "Package.resolved")
CHECKOUTS = os.path.join(ROOT, ".dd", "SourcePackages", "checkouts")
TARGET = os.path.join(ROOT, "App", "Resources", "Licenses.json")

# How to recognize a license. Checked at the start of the file and in this order —
# "Apache" also appears in the header of some MPL files, not the other way round.
KINDS = (
    ("MPL-2.0", r"Mozilla Public License"),
    ("Apache-2.0", r"Apache License"),
    ("MIT", r"MIT License"),
    ("BSD", r"BSD"),
)


def kind(text):
    head = " ".join(text.split())[:400]
    for name, pattern in KINDS:
        if re.search(pattern, head, re.I):
            return name
    return None


def from_history(folder):
    """The license from the **history of the same source**, if the checked-out state has none.

    **The case this exists for** (07.09.): `jellyfin-sdk-swift` has no license file at
    version 2.1.0 — it was only added afterwards (`a57ec183 [Re] License SDK`). GitHub
    declares MPL-2.0 for the repository, and the text is in the clone that SwiftPM
    fetched anyway.

    **Read and not typed in.** A hand-inserted license would be exactly the invented
    entry that this file otherwise avoids; here it comes from the repository itself, only
    from a later state. The result carries that as ``nachgetragen`` and the screen says
    so too.
    """
    if not os.path.isdir(os.path.join(folder, ".git")):
        return None, None
    run = subprocess.run(
        ["git", "-C", folder, "log", "--all", "--format=%H", "--diff-filter=A", "--",
         "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"],
        capture_output=True, text=True)
    hashes = [z for z in run.stdout.split() if z]
    if not hashes:
        return None, None
    # The **most recent** addition: A repository may have changed its license, and then
    # the later one applies. `git log` lists newest first.
    commit = hashes[0]
    for name in ("LICENSE.md", "LICENSE", "LICENSE.txt", "COPYING"):
        shown = subprocess.run(
            ["git", "-C", folder, "show", f"{commit}:{name}"], capture_output=True, text=True)
        if shown.returncode == 0 and shown.stdout.strip():
            return shown.stdout.strip(), commit[:8]
    return None, None


def license_file(folder):
    if not os.path.isdir(folder):
        return None
    for name in sorted(os.listdir(folder)):
        if name.lower().startswith(("license", "licence", "copying")):
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                return path
    return None


def collect():
    with open(RESOLVED, encoding="utf-8") as f:
        pins = json.load(f).get("pins", [])

    packages, without = [], []
    for pin in sorted(pins, key=lambda p: p.get("identity", "")):
        name = pin.get("identity", "?")
        location = pin.get("location", "")
        state = pin.get("state", {})
        version = state.get("version") or (state.get("revision") or "")[:8]

        folder = os.path.join(CHECKOUTS, name)
        file = license_file(folder)
        if file:
            text = open(file, encoding="utf-8", errors="replace").read().strip()
            packages.append(
                {"name": name, "fassung": version, "ort": location,
                 "art": kind(text) or "?", "text": text, "nachgetragen": None})
            continue

        text, source = from_history(folder)
        if text:
            packages.append(
                {"name": name, "fassung": version, "ort": location,
                 "art": kind(text) or "?", "text": text, "nachgetragen": source})
        else:
            # **Explicitly kept as a gap and not left out.** A package without a license
            # file in its source is not a package without a license — it is one whose
            # license someone has to add.
            without.append(name)
            packages.append(
                {"name": name, "fassung": version, "ort": location, "art": None, "text": None,
                 "nachgetragen": None})
    return packages, without


def main():
    if not os.path.exists(RESOLVED):
        print(f"✗ No Package.resolved at {os.path.relpath(RESOLVED, ROOT)}")
        print("  First `./scripts/project.sh` and a build, then once more.")
        return 1

    packages, without = collect()
    if "--check" in sys.argv:
        if without:
            print(f"✗ {len(without)} package(s) without license text: {', '.join(without)}")
            return 1
        print(f"✓ {len(packages)} third-party packages, each with license text")
        return 0

    with open(TARGET, "w", encoding="utf-8") as f:
        json.dump(packages, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{len(packages)} third-party packages → {os.path.relpath(TARGET, ROOT)}")
    for p in packages:
        added = f"  (added from {p['nachgetragen']})" if p.get("nachgetragen") else ""
        print(f"  {p['name']:<30} {p['fassung']:<10} {p['art'] or '— no license file —'}{added}")
    if without:
        print(f"\n⚠ Without license text: {', '.join(without)}")
        print("  They are in the list with their source; the text still has to be added.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
