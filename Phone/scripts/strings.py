#!/usr/bin/env python3
"""Checks that every language key in the source is also in the catalog.

Why this is a step of its own and not left to the translator: A missing key
breaks neither the build nor a test. It appears on the device as a bare key name —
in the sister project it happened twice, 17 keys of playback and 20 of sign-in,
both times noticed only on the screen.

Procedure, taken over from `jellyfin-tvos/scripts/strings.py`:
  1. Read the catalog and derive the valid namespaces FROM THE CATALOG,
     not from a list here in the code.
  2. Search all *.swift that look up in the phone's catalog for key-shaped
     strings — for ALL of them, not for particular call forms: A first attempt that
     only knew `Text(app:)` reported 20 instead of 26 missing. WHICH files those are
     is derived by `../scripts/linkage.py` from `project.yml` and the `Package.swift`
     files: App/Sources, the own packages, the shared ones under `../Packages` and
     `grundstock` — as far as the phone links them.
  3. What formally looks like a key but is not one stands in
     NO_FILE (a whole file that only holds symbol names) or in
     IGNORED — enumerated, not pattern-matched. `live.ungrouped` and `play.tv`
     cannot be told apart formally.
  4. Orphaned catalog entries are a HINT, not an error: Keys
     are assembled at runtime ("state." + zustand.rawValue).

Return value: 0 if nothing is missing, otherwise 1.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Resources" / "Localizable.xcstrings"
# The TV's catalog — only read, as a witness for what counts as a text in shared
# packages (see ``main``).
SIBLING = ROOT.parent / "App" / "Resources" / "Localizable.xcstrings"

# **Until 26.09.2026 this said `ORTE = ["App", "Packages"]`** — only what lies under
# `Phone/`. But the shared packages (`../Packages`) and `grundstock` have no catalog
# of their own; their texts look up in THIS one through `bundle: .main`. 27 of their
# keys were missing, and on the device "Deutsch · player.subtitleForced" stood in the
# track picker. The linkage has been derived since, not enumerated.
sys.path.insert(0, str(ROOT.parent / "scripts"))
from linkage import (  # noqa: E402
    BYPASSES_WORDING, display_name, source_folders, swift_files, wording_catalog)

# Key-shaped, but not language keys. Add to it, do not pattern-match.
IGNORED = {
    # **Host names look like keys and are not.** `jellyfin.example` stands in the test of
    # ``Standortbestimmung`` — there the point is exactly that a name is not a text but
    # something the name service resolves. The same kind of false alarm as with the SF
    # Symbol names, and the same answer: The checker cannot know it, so it stands here.
    "jellyfin.example",
    "portale.example",
    # Store keys (UserDefaults, Keychain)
    "app.language",
    # `app.theme` stays until it dies out: Since 20.09.2026 (AP40) the key is named as
    # on the TV, but the old one is read once more at startup to take over an existing
    # choice.
    "app.theme",
    "appearance.theme",
    "childMode.on",
    "tabs.hidden",
    "live.hiddenSports",
    "childLock.ageLimit",
    "childLock.blockUnknown",
    "childLock.hideUnmarked",
    "childLock.pinDigest",
    "childLock.pinSalt",
    "childLock.pinChanged",
    "childLock.ratingMap",
    "portal.hinweisGelesen",
    # Whether notifications have been asked for yet (AP8) — a marker, not a text.
    "stock.notificationsAsked",
    "app.deviceID",
    "library.sort",
    # The shared sorting board of both programs (AP58 R6, `Core.Sortierablage`) and
    # the prefix of the old TV rows — store, not text.
    "library.sortierung",
    "library.sort.",
    "library.sortByStock",
    "home.shelfOrder",
    "home.shelfHidden",
    "home.heroShelves",
    "home.liveChannels",
    "home.portalFolder",
    # Not text but store slots: the haptics switch and the two markers by which the
    # error book recognizes that a new version is running.
    "app.haptics",
    "diagnose.buch.fassung",
    "diagnose.buch.begonnen",
    "library.lastCategory",
    "library.lastStock",
    "live.lastChannel",
    "live.recentChannels",
    "live.sportMarks",
    "live.lastSide",
    "portal.lastPortal",
    "portal.lastPath",
    "portals.ownArea",
    "setup.done",
    "setup.portalsWanted",
    "setup.portalBridge",
    "accounts.children",
    "diagnostics.id",
    "server.accounts",
    "omdb.apikey",
    "tmdb.apikey",
    "player.lastTarget",
    "player.subtitleSize",
    "player.originalAudio",
    "vorrat.wlanOnly",
    # **Store keys of the shared packages** (since 26.09.2026 this checker also
    # searches `../Packages`). The same names stand in the TV checker under
    # IGNORED or slip through there because their namespace does not occur in the TV
    # catalog. Not text: The name IS the slot in the user's store.
    "account.hasJellyfin",
    "account.hasPlaylist",
    "account.hasPortals",
    "childLock.liveGroups",
    "live.engine",
    "live.groupOrder",
    "live.hiddenGroups",
    "live.ownDecoder",
    "live.previewsChannels",
    "live.rawStreamRule",
    "live.rawStreamRule.v2",
    "live.rawStreams",
    "live.showsAdult",
    "live.showsBrowseArea",
    "live.slowSources",
    "profile.startetAls",
    "profiles.mergeQuestions",
    "profiles.takeoverVersion",
    "profiles.tombstones",
    # The profiles that are hidden on this device only ("Von diesem Gerät
    # entfernen", 27.09.2026) — a store key next to the profile book, which
    # ``Profilwolke/finde()`` respects (``Profilausblendung``).
    "profiles.hiddenHere",
    "setup.deviceOwned",
    "setup.deviceProfile",
    "setup.deviceToken",
    # Bundle and name identifiers
    "dev.ms-solutions.cinelounge",
    "dev.ms-solutions.cinelounge.shared",
    # Invented host names from tests. They look like keys and are not — and they are
    # expressly invented: This house's server does not stand in the source.
    "medienserver.beispiel",
    # File extensions and path fragments
    "Localizable.xcstrings",
    "fehlerbuch.jsonl",
    "verlauf.json",
}

# Lines with these words carry SF Symbol names, not keys.
NO_LINE = ("systemName:", "systemImage:", "Image(systemName")

# Files that hold ONLY symbol names. No per-name exception list helps here:
# `live.ungrouped` and `play.tv` cannot be told apart formally, and the file is the
# enumeration. Whoever excludes it excludes exactly what it is — and not a pattern
# that hits too much tomorrow.
NO_FILE = ("DesignSystemPhone/Sinnbilder.swift",)

PATTERN = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+(?: %[a-z]+)?)"')


def catalog_keys() -> set[str]:
    with CATALOG.open(encoding="utf-8") as f:
        return set(json.load(f)["strings"].keys())


def namespaces(keys: set[str]) -> set[str]:
    return {k.split(".", 1)[0] for k in keys}


def source_files():
    # `.build/`, `.dd/` and `.claude/` are filtered by ``swift_files`` — relative to
    # each source folder, so that the checker really checks in a working copy under
    # `.claude/` as well.
    for path in swift_files(source_folders(ROOT / "project.yml")):
        if any(str(path).endswith(suffix) for suffix in NO_FILE):
            continue
        yield path


def place_name(path: pathlib.Path) -> str:
    """Relative to `Phone/`; shared code as `../Packages/…`, grundstock as
    `grundstock/…` — so the location shows who owns the text."""
    if path.is_relative_to(ROOT):
        return str(path.relative_to(ROOT))
    if path.is_relative_to(ROOT.parent):
        return "../" + str(path.relative_to(ROOT.parent))
    return display_name(path, ROOT.parent)


def is_own(place: str) -> bool:
    """Does the location lie in the phone project itself (and not in shared code)?"""
    return not place.startswith(("../", "grundstock/"))


def found() -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {}
    for path in source_files():
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if any(w in line for w in NO_LINE):
                continue
            for key in PATTERN.findall(line):
                if key in IGNORED:
                    continue
                place = f"{place_name(path)}:{number}"
                hits.setdefault(key, []).append(place)
    return hits


def main() -> int:
    if not CATALOG.exists():
        print(f"✗ No catalog under {CATALOG.relative_to(ROOT)}")
        return 1

    in_catalog = catalog_keys()
    # **The shared catalog counts too** (AP58 R0) — the same rule as in
    # `../scripts/strings.py`: A key stands in exactly ONE catalog, in this app's
    # catalog or in `WordingKit`, which the shared packages bring along.
    shared_path = wording_catalog(ROOT / "project.yml")
    shared = (
        set(json.loads(shared_path.read_text(encoding="utf-8"))["strings"])
        if shared_path else set())
    duplicate = sorted(in_catalog & shared)
    spaces = namespaces(in_catalog | shared)
    in_source = found()

    missing = {k: v for k, v in in_source.items() if k not in in_catalog | shared}
    # Reported separately: a known namespace means "forgot to translate", an unknown
    # one means "a new area starts here".
    known = {k: v for k, v in missing.items() if k.split(".", 1)[0] in spaces}
    # From an unknown namespace, in shared code only what the TV's catalog knows as a
    # text counts: There stand a good hundred store keys, host names and symbols in key
    # shape (`shelves.order`, `get.php`, `figure.golf`), which would otherwise all have
    # to be exempted one by one here. In the phone's own code it stays as before: every
    # find from an unknown namespace is an error.
    sibling = set(json.loads(SIBLING.read_text(encoding="utf-8"))["strings"])
    new = {
        k: v for k, v in missing.items()
        if k.split(".", 1)[0] not in spaces
        and (any(is_own(o) for o in v) or k in sibling)
    }

    # A shared key needs a path that knows the shared catalog — the same rule as in
    # `../scripts/strings.py` (``linkage.BYPASSES_WORDING``).
    wrong_path = {}
    for path in source_files():
        place = place_name(path)
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("//") or not BYPASSES_WORDING.search(line):
                continue
            for key in PATTERN.findall(line):
                if key in shared - in_catalog:
                    wrong_path.setdefault(key, f"{place}:{number}")

    if duplicate:
        print(f"✗ {len(duplicate)} keys stand in the catalog AND in `WordingKit`:")
        for k in duplicate:
            print(f"    {k}")
    if wrong_path:
        print(f"✗ {len(wrong_path)} shared keys read through the app's catalog:")
        for k in sorted(wrong_path):
            print(f"    {k}   ({wrong_path[k]})")

    if known:
        print(f"✗ {len(known)} keys are missing in the catalog:")
        for k in sorted(known):
            print(f"    {k}   ({known[k][0]})")
    if new:
        print(f"⚠ {len(new)} keys from unknown namespaces:")
        for k in sorted(new):
            print(f"    {k}   ({new[k][0]})")

    orphaned = in_catalog - set(in_source)
    if orphaned:
        print(f"\033[90m  Note: {len(orphaned)} catalog entries do not occur "
              f"literally in the source.\033[0m")
        print("\033[90m  That is not an error — keys are assembled at runtime."
              "\033[0m")

    if known or new or duplicate or wrong_path:
        return 1
    used = len(set(in_source) & in_catalog)
    print(f"✓ {len(in_catalog)} keys in the catalog, {used} used, none missing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
