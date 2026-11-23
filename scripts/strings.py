#!/usr/bin/env python3
"""Finds language keys that are used but missing from the language file.

Why this is a step of its own in the quality run: A missing key is
**not a translation error**, it breaks no build and no check — it only shows up
on the TV, and then `login.wayServer` stands on a card. That has happened twice in
this project, once with 17 keys of playback and once with 20 of sign-in.

**The detection must not guess.** A first attempt looked for particular call
forms (`Text(app:)`, `bundle: .main`) and thereby overlooked everything that goes
through a helper function as an ordinary string — `wordmark(subtitle:)`,
`title:`, `detail:`. It reported 20 missing while there were 26, and a checker that
cannot be believed is worse than none.

Hence the opposite approach: **All** strings that have the shape of a key are
considered, and the valid namespaces are derived from the language file itself.
Whoever creates a new area therefore has to enter its first key by hand — after
that the checker finds all further ones.
"""

import json
import pathlib
import re
import sys

from linkage import BYPASSES_WORDING, display_name, source_folders, swift_files, wording_catalog
from programs import PROGRAMS

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
# The phone's catalog — only read, as a witness for what counts as a text in shared
# packages (see the search for unknown areas in ``main``).
SIBLING = ROOT / "Phone/App/Resources/Localizable.xcstrings"
# **Since the merge (decision 17) the phone lives under `Phone/`** and has its own
# catalog and its own checker (`Phone/scripts/strings.py`). Its keys do not belong in
# this catalog — without the exclusion this checker reported every phone key as
# missing. The shared packages under `Packages/` count here as before.
PHONE = "Phone/"


def files() -> list[pathlib.Path]:
    """What looks up in the TV catalog — derived, not enumerated.

    Until 26.09.2026 this ran `ROOT.rglob("*.swift")`: everything except `Phone/`,
    including tests, the Top Shelf extension and tools — but without `grundstock`,
    which lies outside the repo. Now: the app target from `project.yml` and every
    package that links it (``linkage``).
    """
    result = []
    for path in swift_files(source_folders(ROOT / "project.yml")):
        if display_name(path, ROOT).startswith(PHONE):
            raise SystemExit(f"✗ {path} belongs to the phone and must not get in here")
        result.append(path)
    return result

# A string in the form `area.name` or `area.name %lld`.
SHAPE = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+(?: %[a-z]+)?)"')

# Strings that look like a key and are not one.
#
# Enumerated explicitly and not dispatched with a pattern: System symbols such as
# `star.fill` have exactly the same shape as a key, and every rule that sorts them
# out eventually sorts out a real key too — `live.ungrouped` and `play.tv` cannot be
# told apart by structure. A list is longer but hides nothing by accident: Whoever
# adds an entry has decided it.
IGNORED = {
    # System symbols, kept in computed properties
    "pause.fill",
    "person.2",
    "person.crop.circle",
    # Symbol of the parental-controls area (G3)
    "lock.shield",
    # Symbol of the child account in ``KontoNeuView`` (G3)
    "figure.child",
    # The symbols of the twenty states (G4). They stand as strings in
    # ``Zustand/form`` and not at a `systemName:` — a state is a value and not a
    # view; it names its symbol, drawing it happens elsewhere.
    "clock.badge.exclamationmark",
    "globe.badge.chevron.backward",
    "lock.trianglebadge.exclamationmark",
    "person.2.slash",
    "person.crop.circle.badge.exclamationmark",
    "play.slash",
    "questionmark.circle",
    "waveform.badge.exclamationmark",
    # Not recognizable by `systemName:`: It stands as a placeholder symbol in
    # an argument of its own (``RemoteImage``).
    "person.fill",
    "play.circle",
    "arrow.triangle.2.circlepath",
    "backward.end.fill",
    "forward.end.fill",
    "play.fill",
    "play.tv",
    "popcorn.fill",
    "server.rack",
    "star.fill",
    "captions.bubble.fill",
    "checkmark.circle.fill",
    "checkmark.square.fill",
    "arrow.up",
    "arrow.down",
    "chevron.down",
    "chevron.right",
    "chevron.up",
    "antenna.radiowaves.left.and.right",
    "dot.radiowaves.left.and.right",
    # The fourth card of sign-in: "From a phone" (10.09., AP5).
    "iphone.and.arrow.forward",
    # The glyph of an ``Aktionszeile`` (AP46, 23.09.). It stands at the argument
    # `sinnbild:` and not at a `systemName:`, because the building block swaps it for
    # the hourglass while running — which glyph gets drawn is its decision and not
    # the call site's.
    "square.and.arrow.up",
    "exclamationmark.triangle.fill",
    "arrow.counterclockwise",
    "arrow.right.circle",
    "checkmark.circle",
    "eye.slash",
    "film.stack",
    "gobackward.10",
    "goforward.30",
    "heart.fill",
    # Store keys, not display texts. They deliberately have the same spelling as
    # language keys — both name a thing unambiguously —, and that is why they are to be
    # enumerated here instead of detected. Renaming would be the wrong way out: The name
    # is also the key in the user's store, and with it the user's saved setting would
    # vanish.
    "app.language",
    # The version in which the takeover happened (AP48, 24.09.2026). It sits next to the
    # profile book in the same store and is the reference point for "gets deleted in the
    # version after next" — without it the condition would have none.
    "profiles.takeoverVersion",
    # The open questions of the profile reconciliation (AP45/AP48, 24.09.2026): pairs
    # that look like the same person without proving it. Likewise a store key next to the
    # profile book.
    "profiles.mergeQuestions",
    # The tombstones of removed and merged profiles (AP43 · B5, 25.09.2026) — a store key
    # next to the profile book, which ``Profilwolke/finde()`` respects.
    "profiles.tombstones",
    # The device's CL-Server keys in the Keychain (``DeviceTrait``, ``BridgeAddress``). Since
    # AP88 the first setup's texts live under `setup.*`, and these old store keys share the
    # prefix — renaming them would lose the stored sign-in and address.
    "setup.deviceOwned",
    "setup.deviceProfile",
    "setup.deviceToken",
    "setup.portalBridge",
    # The profiles that are hidden on this device only ("Von diesem Gerät
    # entfernen", 27.09.2026) — a store key next to the profile book, which
    # ``Profilwolke/finde()`` respects (``Profilausblendung``).
    "profiles.hiddenHere",
    # Codes of the portal service, not language keys (AP39, 20.09.2026). Since the
    # failure interpretation they also stand in `Features` and have the same shape as a
    # key — but the name IS the agreement with the server, and the app translates it into
    # a state, not into a sentence.
    "auth.required",
    "auth.profile_required",
    "device.id",
    "live.groupOrder",
    "live.rawStreams",
    # The learned rule "which kind of channel goes raw" (AP3 · V5)
    "live.rawStreamRule",
    "live.rawStreamRule.v2",
    # Store key of the delivery memory (SlowSourceMemory)
    "live.slowSources",
    "live.engineOverride",
    "live.engine",
    "live.ownDecoder",
    "pip.enter",  # SF Symbol, not a language key
    "forward.end.alt.fill",  # SF Symbol, not a language key
    "live.lastChannel",
    "live.hiddenGroups",
    "live.previewsChannels",
    "live.showsBrowseArea",
    "live.showsAdult",
    # The hidden sports (since 06.09.) — the same kind of store key
    "live.hiddenSports",
    # The channel history per profile (AP58 R5) — since it lives in `Ablaeufe`, this
    # checker reads it too; a store key and not a sentence.
    "live.recentChannels",
    # "Start automatically as ..." (AP45, 23.09.2026) — store key per device,
    # not a sentence. It stands out here because "profile." is a language namespace;
    # `childMode.on` got through without this entry because "childMode" is not one.
    "profile.startetAls",
    "playback.enginePreference",
    "playback.quality",
    "server.lastAddress",
    "topshelf.context",
    "topshelf.mode",
    "sidebar.lastLive",
    "live.lastSection",
    "library.sort",
    # The shared sorting board of both programs (AP58 R6, `Core.Sortierablage`) and
    # the prefix of the old TV rows — store, not text.
    "library.sortierung",
    "library.sort.",
    "library.sortByStock",
    "settings.lastSection",
    # Which accounts are child accounts (G1, ``Kinderkontenliste``) — store, not text.
    # Since 20.09.2026 (AP40) the list is called `accounts.children` on both devices
    # and lives in the `Dateiablage`; `konten.kinder` is read once more at first launch
    # to take over existing marks.
    "konten.kinder",
    "accounts.children",
    # The parental-controls store (G3). It moved here from the phone project on 07.09.
    # and brings its own store keys — digest and salt of the PIN, when it was last
    # changed, and the manually assigned approvals. They have the shape `area.name`
    # because that is the same spelling over there; renaming would be the wrong way out
    # here too, because the name IS the key in the user's store.
    "childLock.pinDigest",
    "childLock.pinSalt",
    "childLock.pinChanged",
    "childLock.ratingMap",
    # The age limit and the switch for unrecognized ratings (G3, step 5).
    # The same names as in the phone project: Both programs name the same thing
    # the same, so that a later reconciliation between devices finds it under ONE name
    # and not under two.
    "childLock.ageLimit",
    "childLock.blockUnknown",
    # "Hide unmarked adult channels" (G3, finding C8) — store key, not a sentence.
    # Since G3 it is shared at ``Sendersperre`` and no longer only on the phone.
    "childLock.hideUnmarked",
    # The allow list for channels per child profile (AP52, ``Senderfreigabe``) — in the
    # same compartment of the Keychain as the age limit.
    "childLock.liveGroups",
    "sidebar.vodCategories",
    "sidebar.vodLibraries",
    "sidebar.lastVOD",
    "sidebar.lastPortal",
    "vod.memory.v1",
    # Focus identifiers of the chooser window — they never appear on screen,
    # but have the same shape as a key.
    "vod.chooser",
    "vod.sheet.anchor",
    # Test data
    "ahorn.de",
    "telve1.tr",
    # The program identifier of the test channel in ``SportModelTests`` (E3). It has
    # the shape of a key because program identifiers simply look like that.
    "sportwelt.de",
    # And the program identifiers of the bundling tests (E4): Four entries
    # under `PusulaSports1.tr` are the measured case from the provider's
    # catalog; "a.tr" and "b.tr" are two stations that have to stay two.
    "PusulaSports1.tr",
    "a.tr",
    "b.tr",
}


def prefixes(stem: str) -> list[str]:
    """Every prefix under which a key may be built at runtime.

    **At every level and not only up to the last dot** (check finding B5 of
    27.09.2026): `PortalKit` builds `"error." + code` from the server's response code,
    and `error.join.too_many` therefore showed up as "unused" — only
    `"error.join."` was searched for.

    >>> prefixes("error.join.too_many")
    ['error.join.', 'error.']
    >>> prefixes("home.empty")
    ['home.']
    """
    parts = stem.split(".")
    return [".".join(parts[:n]) + "." for n in range(len(parts) - 1, 0, -1)]


def orphaned(present: set[str], sources: list[pathlib.Path]) -> set[str]:
    """Keys that stand in a catalog and nowhere in the sources.

    **Three ways to use a key**, and all three count:

    - literally: ``Text(app: "live.raster")``
    - with a format spec: ``Text("live.channelCount \\(n)")`` — then the source has
      only the stem without ``%lld``
    - built at runtime: ``"sport.kind." + art.rawValue``,
      ``"settings.subtitleSize.\\(größe)"`` or ``"error." + code`` — the prefix at
      every level (``prefixes``)

    The third way is the reason this stays a hint and does not become an error:
    Whoever builds it in a fourth way would otherwise get a red run for a key that
    works perfectly.
    """
    everything = "\n".join(path.read_text(errors="replace") for path in sources)

    dead = set()
    for key in present:
        stem = key.split(" ")[0]
        if stem in everything:
            continue
        if any(
            f'"{prefix}\\(' in everything or f'"{prefix}" +' in everything
            or f'"{prefix}" \n' in everything or f'"{prefix}"' in everything
            for prefix in prefixes(stem)
        ):
            continue
        dead.add(key)
    return dead


def both_programs() -> list[pathlib.Path]:
    """The sources of TV AND phone — **for the shared catalog.**

    A sentence from `WordingKit` is used if either program reads it; a phone view that
    shows it alone counts just like shared code.
    """
    return sorted({p for program in PROGRAMS.values() for p in program.swift_files()})


def main() -> int:
    catalog = json.loads(CATALOG.read_text())
    present = set(catalog["strings"])

    # **The shared catalog counts too** (AP58 R0): What shared packages say has stood
    # in `WordingKit` bit by bit since 26.09.2026 (``linkage.WORDING_CATALOG``). A key
    # may stand in exactly ONE of the two catalogs — in both it would mean two wordings
    # for the same key, and which one applies would depend on the call.
    shared_path = wording_catalog(ROOT / "project.yml")
    shared = set(json.loads(shared_path.read_text())["strings"]) if shared_path else set()
    duplicate = sorted(present & shared)
    everything = present | shared

    # The namespaces come from the language file and not from a list in the code:
    # Otherwise this file would have to be touched for every new area and one would
    # forget it.
    namespaces = {k.split(".", 1)[0] for k in everything if "." in k}

    # `.claude/` holds working copies of parallel agents — old states whose keys
    # have long stopped applying. The exclusion sits in ``linkage.swift_files`` and
    # applies only BELOW the source folders.
    sources = files()
    used: dict[str, set[str]] = {}
    for path in sources:
        for match in SHAPE.finditer(path.read_text(errors="replace")):
            key = match.group(1)
            if key in IGNORED:
                continue
            if key.split(".", 1)[0] in namespaces:
                used.setdefault(key, set()).add(display_name(path, ROOT))

    # A COMPLETELY NEW area would be invisible because its namespace does not yet
    # occur in the language file. That is exactly where the first draft of this
    # checker failed: The keys of the new Live view slipped through because there was
    # not a single one with `live.` yet. Therefore the key-shaped strings from the UI
    # layers whose namespace is unknown are additionally collected — they are reported
    # but not counted as errors, because foreign things get in there too.
    #
    # **Over ALL linked sources, not only `App/` and `Features/`** (26.09.2026):
    # `childlock.ask.*` stands in `Kindersicherung` and slipped through because the TV
    # catalog did not know the namespace `childlock` and the search for unknown areas
    # only looked at the UI layers. Since the packages are shared, texts stand in every
    # layer.
    #
    # Outside the own UI, though, with a restriction: There stand a good hundred store
    # keys, host names and symbols in key shape (`shelves.order`, `get.php`,
    # `figure.golf`), and a list that is nine tenths false alarm is no longer looked
    # through by anyone. There only what the **phone's catalog** knows as a text is
    # reported — shared code whose text the other app already translates is certainly a
    # text. A namespace that NEITHER of the two catalogs knows stays invisible in the
    # packages; its first key is entered by hand (see the head).
    surface = ("App/", "Packages/Features/")
    sibling = set(json.loads(SIBLING.read_text())["strings"])
    unknown: dict[str, set[str]] = {}
    for path in sources:
        rel = display_name(path, ROOT)
        own = rel.startswith(surface)
        for line in path.read_text(errors="replace").splitlines():
            # System symbols have the same shape as a key — `star.fill`,
            # `person.crop.circle`, `play.tv`. But they always stand at a recognizable
            # place, and without this exclusion half of the list consists of them;
            # then nobody looks through it any more.
            if "systemName:" in line or "systemImage:" in line:
                continue
            for match in SHAPE.finditer(line):
                key = match.group(1)
                if key in IGNORED:
                    continue
                space = key.split(".", 1)[0]
                if not own and key not in sibling:
                    continue
                if space not in namespaces and key not in everything:
                    unknown.setdefault(key, set()).add(rel)

    # **A shared key needs a path that knows the shared catalog**
    # (AP58 final step, ``linkage.BYPASSES_WORDING``). `Text(app:)` and
    # `Appsprache.text(_:)` choose the catalog by the key; whoever instead names
    # `bundle: .main` or lets `Text("…")` search in the main bundle would not find a key
    # from `WordingKit`, and on the TV its name would stand.
    wrong_path: dict[str, set[str]] = {}
    for path in sources:
        rel = display_name(path, ROOT)
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("//") or not BYPASSES_WORDING.search(line):
                continue
            for match in SHAPE.finditer(line):
                if match.group(1) in shared - present:
                    wrong_path.setdefault(match.group(1), set()).add(f"{rel}:{number}")

    missing = {k: v for k, v in used.items() if k not in everything}
    orphans = sorted(orphaned(present, sources))
    # **The shared catalog too** (check finding B5): Until 27.09.2026 the hint only
    # looked at the app's catalog, and what stayed lying around in `WordingKit` was
    # noticed nowhere.
    orphans += sorted(f"{k}  (WordingKit)" for k in orphaned(shared, both_programs()))

    if duplicate:
        print(f"  {len(duplicate)} keys stand in the app's catalog AND in `WordingKit`:")
        for key in duplicate:
            print(f"    {key}")
    if wrong_path:
        print(f"  {len(wrong_path)} shared keys read through the app's catalog:")
        for key in sorted(wrong_path):
            print(f"    {key:<34} {sorted(wrong_path[key])[0]}")
    if duplicate or wrong_path:
        return 1

    if not missing and not unknown:
        print(f"  {len(used)} keys used, all present "
              f"({len(shared)} of them possible from `WordingKit`)")
        if orphans:
            # **A hint and not a failure.** A key that is assembled at runtime in a
            # way nobody foresaw here would otherwise stand there as an error and
            # break every run — for a line that harms nobody. It is reported anyway:
            # On 02.09. there were 18 of them left, among them four that described the
            # long-removed engine switch.
            print(f"  {len(orphans)} keys appear unused — please have a look:")
            for key in orphans:
                print(f"    {key}")
        return 0

    if missing:
        print(f"  {len(missing)} keys are missing in the language file:")
        for key in sorted(missing):
            places = ", ".join(sorted(missing[key])[:2])
            print(f"    {key:<34} {places}")

    if unknown:
        print(f"  {len(unknown)} more from unknown areas — please have a look:")
        for key in sorted(unknown):
            places = ", ".join(sorted(unknown[key])[:1])
            print(f"    {key:<34} {places}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
