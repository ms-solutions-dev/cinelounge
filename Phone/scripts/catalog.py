#!/usr/bin/env python3
"""Checks that the settings catalog does not silently go stale.

**Why this step exists.** `SettingsCatalog.swift` is the list the search in the
settings runs over. A hand-maintained list drifts apart on the first day someone adds a
setting — and unnoticed: the new setting works, it just cannot be found. Exactly this
error occurred on 07.09. with the `SwipeMark`, and the comment there had predicted it
word for word a day earlier.

**The rule, and it is one and not three.** Every `SwitchRow` and every
`DisclosureRow` in the settings area is either in the catalog — or it stands below in
`WITHOUT_ENTRY`, with a reason. A reason one has to write down is a reason one has
thought through.

**Why precisely these two forms.** They are the settings: a `SwitchRow` switches
something, a `DisclosureRow` leads somewhere. What else stands in these views —
`HintRow`, `SettingsRow`, `ValueRow` — tells something and cannot be operated;
searching it would mean offering information as settings.

Usage:   python3 scripts/catalog.py            → list
         python3 scripts/catalog.py --check  → only report what is missing (returns 1)
"""
import json
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Packages/FeaturesPhone/Sources/FeaturesPhone"
CATALOG_FILE = SOURCE / "Settings/SettingsCatalog.swift"
PLACEHOLDER = SOURCE / "Shell/TabPlaceholder.swift"
LANGUAGES = ROOT / "App/Resources/Localizable.xcstrings"
# **The shared catalog counts too** (AP58 closing step): the settings search reads
# through `AppLanguageSetting.text`, and that finds sentences from both — what both
# devices say has lived in `WordingKit` since 26.09.2026.
SHARED = ROOT.parent / "Packages/WordingKit/Sources/WordingKit/Resources/Localizable.xcstrings"


def language_texts() -> dict:
    """The entries of the phone catalog and of the shared one, together."""
    texts = json.loads(SHARED.read_text())["strings"]
    texts.update(json.loads(LANGUAGES.read_text())["strings"])
    return texts

# Where settings live. Not the whole project: a `DisclosureRow` in the player or in
# the setup is a path and not a setting.
# `Accounts` belongs: its view is a settings screen, it just lies next to its subject.
# The tab placeholder and the setup do not belong.
LOCATIONS = ["Settings", "ParentalControls", "Accounts"]

# Rows that are not a setting — each with the reason why it is not one.
WITHOUT_ENTRY = {
    # **The profile PIN (AP52) stands in the person sheet and in its sheet**, not in
    # the settings: it belongs to the person in the sheet's header, not to the device.
    # The setting under which one looks for PINs is parental controls — and that is in
    # the catalog. Changing and removing are steps in a sheet that the row opens.
    "profiles.pin":
        "Row in the person sheet for the PIN of the profile in the header — not a device setting.",
    "pin.change":
        "Step in the profile-PIN sheet, reachable only via the row in the person sheet.",
    "profiles.pinRemove":
        "Step in the profile-PIN sheet, reachable only via the row in the person sheet.",
    "childLock.liveClear":
        "Action in a child's “Live for children” list; the list itself lies in "
        "parental controls, and that is in the catalog.",
    "profiles.add":
        "Row in “Manage profiles” (G3); the profile picture leads there via “Who's "
        "watching?”, not the settings — the same “Create profile” card always stands "
        "there (decision 3).",
    "profiles.addExisting":
        "Row in “Manage profiles” (2026-09-27) next to “Create profile”: brings back a "
        "profile that was removed on this device only from iCloud; same way there as "
        "with creating.",
    "settings.title":
        "The way OUT of the account sheet INTO the settings. Finding it where it "
        "leads would be a circle.",
    "live.groups":
        "In the report path, the link “Hide channel yourself”. The setting behind it "
        "is `settings.live.groups.manage`, and that is in the catalog.",
    # The four actions INSIDE “Devices & Sharing” (AP44). The screen itself stands as
    # `pairing.title` in the catalog; what is in it are steps of a process and not
    # settings. Whoever searches “Pair” finds the screen — finding it in four hits,
    # three of which do something only after the first step, would be a search that
    # leads into the middle of a flow.
    "pairing.pairAction":
        "The first step in “Devices & Sharing”. The screen stands as "
        "`pairing.title` in the catalog.",
    "pairing.giveAction":
        "The second way on the same screen — see `pairing.pairAction`.",
    "pairing.end":
        "Revoking an existing share. It is visible only if there is one, "
        "and a search hit would otherwise lead to a screen without this row.",
    "pairing.leave":
        "Like `pairing.end`, only from the other side: visible only for a shared "
        "profile.",
    "childLock.reset.title":
        "A notice and not a setting (AP43): the row appears only while a PIN escape "
        "is open on the TV — and that is almost never. A search hit would lead the "
        "rest of the time to a screen that says “nothing is open right now”. The "
        "setting behind it is parental controls, and that is in the catalog.",
}


# Search probes: what a person types and what must come out on top.
#
# **Why this stands here and not in the Swift checks.** Under `swift test` there is no
# app bundle; `String(localized:)` returns the key instead of the text there, and a
# check for "untertitel" would thus check the presence of the catalog and not the
# search. Here the language catalog is available as a file — this is the only place
# where one can check against the **real words**.
#
# **And this is the case nobody otherwise notices:** whoever changes a translation —
# "Untertitel" to "Beschriftungen" — breaks the search for a word that has worked for
# months. No translator, no test and no look at the screen reports that.
SEARCH_PROBES = [
    ("de", "untertitel", "settings.section.subtitles"),
    ("de", "sprache", "settings.language"),
    ("de", "datenschutz", "about.privacy"),
    ("de", "lizenz", "about.licences"),
    ("de", "m3u", "settings.addPlaylist"),
    ("de", "gerätesperre", "childLock.deviceLock"),
    ("en", "subtitle", "settings.section.subtitles"),
    ("en", "language", "settings.language"),
    ("en", "privacy", "about.privacy"),
    ("tr", "altyazı", "settings.section.subtitles"),
    ("tr", "dil", "settings.language"),
]


def fold(text):
    """Lowercase, without the marks above — the same rule as `SettingsCatalog.fold`."""
    text = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in text if unicodedata.category(c) != "Mn").strip()


def entries():
    """The catalog entries as tuples: title, area, keywords, terms."""
    catalog = CATALOG_FILE.read_text()
    out = []
    for match in re.finditer(r"\.init\((.*?)\),\n", catalog, re.S):
        body = match.group(1)
        title = re.search(r'title:\s*"([^"]+)"', body)
        if not title:
            continue
        keywords = re.search(r"keywords:\s*\[(.*?)\]", body, re.S)
        terms = re.search(r"terms:\s*\[(.*?)\]", body, re.S)
        out.append((
            title.group(1),
            raw_values().get(a := re.search(r"area:\s*\.(\w+)", body).group(1), a),
            re.findall(r'"([^"]+)"', keywords.group(1)) if keywords else [],
            re.findall(r'"([^"]+)"', terms.group(1)) if terms else []))
    _, areas = catalog_keys()
    return out + [(f"settings.{b}", b, [], []) for b in areas]


def search(word, language, texts):
    """The same three ranks as `SettingsCatalog.match(zu:)`."""
    def text(key):
        entry = texts.get(key, {}).get("localizations", {}).get(language, {})
        return entry.get("stringUnit", {}).get("value", key)

    wanted = fold(word)
    if len(wanted) < 2:
        return []
    found = []
    for title, area, keywords, terms in entries():
        top = fold(text(title))
        side = fold(
            " ".join([text(k) for k in keywords] + terms + [text(f"settings.{area}")]))
        if top.startswith(wanted):
            found.append((0, title))
        elif wanted in top:
            found.append((1, title))
        elif wanted in side:
            found.append((2, title))
    return [t for _, t in sorted(found)]


def raw_values():
    """Case name → raw value of the `Area` enumeration (`case account = "konto"`)."""
    model = (SOURCE / "Settings/SettingsModel.swift").read_text()
    block = re.search(
        r"public enum Area: String.*?\{(.*?)public var id: String", model, re.S)
    if not block:
        return {}
    return {
        m.group(1): m.group(2) or m.group(1)
        for m in re.finditer(r'^\s*case (\w+)(?: = "(\w+)")?$', block.group(1), re.M)}


def catalog_keys():
    """The titles of the catalog — the enumerated ones and those of the eleven areas."""
    text = CATALOG_FILE.read_text()
    from_list = set(re.findall(r'title:\s*"([^"]+)"', text))
    # The areas come from `Area.allCases` and do not stand there as a string;
    # their key is `settings.<rawValue>` (see `Area.titleKey`).
    model = (SOURCE / "Settings/SettingsModel.swift").read_text()
    block = re.search(
        r"public enum Area: String.*?\{(.*?)public var id: String", model, re.S)
    cases = list(raw_values().values())
    return from_list | {f"settings.{f}" for f in cases}, cases


def built_views():
    """Which views the tab placeholder really draws.

    **The error type this catches is the most expensive of this project.** It has
    occurred three times already: "Add account" (E23), the favorites tab (E26) and
    the storage (E42) — each time a row led to an ID for which there was no branch,
    and the viewer landed on "not built yet" together with developer buttons. A hit
    of the settings search that ends there would be the same error a fourth time —
    only that this time the search promises it.

    **And a branch that needs a payload does not count as built.** Reported on the
    device on 07.09.: two catalog entries pointed to `editChannelList`, and that
    draws something only if **a specific list** was chosen beforehand
    (`model.toEdit`). Through the search none is chosen — the screen stayed empty,
    without a message and without a way out except "Back". That is the same error as
    a missing branch, only that it hides from a search for `view ==`.
    """
    source = PLACEHOLDER.read_text()
    built = set(re.findall(r"view == \.(\w+)", source))
    for spot in re.finditer(r"view == \.(\w+) \{\n\s*(.*)", source):
        if re.match(r"if let \w+ = model\.", spot.group(2).strip()):
            built.discard(spot.group(1))
    return built


def rows():
    """Every `SwitchRow` and `DisclosureRow` with a title — key → locations."""
    found = {}
    for location in LOCATIONS:
        for file in sorted((SOURCE / location).glob("*.swift")):
            s = file.read_text()
            for match in re.finditer(r"\b(SwitchRow|DisclosureRow)\(", s):
                i, depth = match.end(), 1
                while i < len(s) and depth:
                    depth += 1 if s[i] == "(" else -1 if s[i] == ")" else 0
                    i += 1
                title = re.search(r'title:\s*"([^"]+)"', s[match.end():i - 1])
                if title and title.group(1):
                    found.setdefault(title.group(1), set()).add(file.name)
    return found


def main():
    catalog, areas = catalog_keys()
    built = rows()

    missing = {k: v for k, v in built.items() if k not in catalog and k not in WITHOUT_ENTRY}

    # The reverse case: a catalog entry without a language key. It would otherwise only
    # show on the device, as a bare key name in the hit list.
    every = set(language_texts())
    without_text = sorted(k for k in catalog if k not in every)

    # And the third: an exception that no longer exists. A reason for a row nobody
    # builds any more is a reason nobody checks any more.
    outdated = sorted(k for k in WITHOUT_ENTRY if k not in built)

    # And the fourth: an entry that points to a view nobody draws.
    targets = set(re.findall(r"view:\s*\.(\w+)", CATALOG_FILE.read_text()))
    targets |= set(
        re.findall(r"case \.\w+: \.(\w+)",
                   (SOURCE / "Settings/SettingsModel.swift").read_text()))
    into_void = sorted(targets - built_views())

    # And the fifth: a word that no longer finds what it should find.
    texts = language_texts()
    off = []
    for language, word, expected in SEARCH_PROBES:
        found = search(word, language, texts)
        if not found or found[0] != expected:
            off.append((language, word, expected, found[:3]))

    if "--check" in sys.argv:
        bad = False
        if missing:
            print(f"✗ {len(missing)} setting(s) not in the catalog:")
            for k in sorted(missing):
                print(f"    {k}  ({', '.join(sorted(built[k]))})")
            print("  Add to SettingsCatalog.swift — or with a reason to")
            print("  scripts/catalog.py, WITHOUT_ENTRY.")
            bad = True
        if without_text:
            print(f"✗ {len(without_text)} catalog entry/entries without a language key:")
            for k in without_text:
                print(f"    {k}")
            bad = True
        if outdated:
            print(f"✗ {len(outdated)} exception(s) without a row: {', '.join(outdated)}")
            bad = True
        if off:
            print(f"✗ {len(off)} search probe(s) no longer hit:")
            for language, word, expected, found in off:
                print(f"    {language} „{word}“ → expected {expected}, "
                      f"found {', '.join(found) or '— nothing —'}")
            print("  Usually a changed translation. Either update the word in SEARCH_PROBES")
            print("  or add a keyword in the catalog.")
            bad = True
        if into_void:
            print(f"✗ {len(into_void)} target(s) without a branch in the tab placeholder:")
            for k in into_void:
                print(f"    .{k}")
            print("  A hit that ends in “not built yet“ is worse")
            print("  than no hit — it promises something.")
            bad = True
        if bad:
            return 1
        print(
            f"✓ {len(catalog)} catalog entries, "
            f"{len(built)} operable rows, each found or justified")
        print(f"✓ {len(targets)} jump targets, each drawn in the tab placeholder")
        print(f"✓ {len(SEARCH_PROBES)} search probes in three languages, each hits first")
        return 0

    for language, word, expected in SEARCH_PROBES:
        found = search(word, language, texts)
        mark = "✓" if found and found[0] == expected else "✗"
        print(f"  {mark} {language} {word:<14} → {', '.join(found[:3]) or '— nothing —'}")
    print()
    print(f"{len(catalog)} catalog entries ({len(areas)} areas + rows)")
    print(f"{len(built)} operable rows in the settings area")
    for k in sorted(built):
        where = "catalog" if k in catalog else ("justified" if k in WITHOUT_ENTRY else "MISSING")
        print(f"  {k:<40} {where:<10} {', '.join(sorted(built[k]))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
