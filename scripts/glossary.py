#!/usr/bin/env python3
"""Checks the wording in the language catalog against a blocklist.

**The finding of 26.09.2026** (refactoring report B, finding 25): In the TV catalog
"Passwort" appeared six times and "Kennwort" six times — on the same sign-in page, for
the same field, depending on who had written the sentence. The phone has always said
only "Kennwort". Two words for one thing make one ask whether they are two things.

**Why a blocklist and not a dictionary.** What is blocked is the word that does NOT
apply, together with the one that does, and the reason. A dictionary of the allowed
words would have to know every word; the blocklist only knows the places where two
words for one thing have stood before.

All texts of a catalog are checked, including the branches of a plural. A hit is
always an error — an exception exists only with a reason in ``EXCEPTIONS``.

Usage:   python3 scripts/glossary.py --app tv|handy
"""

import re
import sys

from programs import PROGRAMS, arguments

# (language, blocked pattern, the word that applies, reason)
BLOCKLIST = [
    ("de", re.compile(r"passw[oö]rt", re.IGNORECASE), "Kennwort",
     "The phone has always said \"Kennwort\"; one term for one field (finding 25)."),
    # **Sources are named after what they are** (owner, 28.09.2026): Jellyfin, IPTV,
    # CL-Server, OMDb/TMDb. The generic words told nobody what to enter.
    ("de", re.compile(r"medienserver", re.IGNORECASE), "Jellyfin",
     "The source is named after the service (28.09.2026)."),
    ("en", re.compile(r"media server", re.IGNORECASE), "Jellyfin",
     "The source is named after the service (28.09.2026)."),
    ("de", re.compile(r"senderliste", re.IGNORECASE), "IPTV / IPTV-Zugang",
     "The source is called IPTV (28.09.2026)."),
    ("de", re.compile(r"portal", re.IGNORECASE), "CL-Server / Mediathek",
     "The source is called CL-Server, an offering on it Mediathek (28.09.2026)."),
    # **The bridge no longer exists** (AP59 N2, 30.09.2026): It was the predecessor of the
    # CL-Server and still stood in 14 places in the visible text.
    ("de", re.compile(r"brücke", re.IGNORECASE), "CL-Server",
     "The bridge has been replaced; visibly it is called CL-Server (AP59 N2)."),
    ("en", re.compile(r"\bbridge\b", re.IGNORECASE), "CL-Server",
     "The bridge has been replaced; visibly it is called CL-Server (AP59 N2)."),
    # Left over from StoryShelf — there one reads, here one watches.
    ("de", re.compile(r"mitlies|liest mit", re.IGNORECASE), "mitschaut / schaut mit",
     "In CineLounge one watches, not reads (AP59 N2)."),
]

# Key → reason, in case a blocked word is ever meant literally.
EXCEPTIONS: dict[str, str] = {}


def sentences(version) -> list[str]:
    if isinstance(version, dict):
        result = [version["value"]] if isinstance(version.get("value"), str) else []
        for value in version.values():
            result += sentences(value)
        return result
    return []


def main() -> int:
    program = PROGRAMS[arguments("Wording against the blocklist").app]
    catalog = program.entries()
    findings = []
    for key, entry in sorted(catalog.items()):
        if key in EXCEPTIONS:
            continue
        locations = entry.get("localizations", {})
        for language, pattern, replacement, _ in BLOCKLIST:
            for sentence in sentences(locations.get(language, {})):
                if pattern.search(sentence):
                    findings.append(f"{language}  {key}  →  {sentence}   (applies: {replacement})")

    # An exception is only orphaned if its key exists in **neither** program — the
    # player words each live in one of the two.
    everything = set().union(*(p.entries().keys() for p in PROGRAMS.values()))
    orphaned = sorted(k for k in EXCEPTIONS if k not in everything)
    if findings or orphaned:
        if findings:
            print(f"✗ {len(findings)} blocked word(s) ({program.name}):")
            for finding in findings:
                print(f"    {finding}")
        if orphaned:
            print(f"✗ Exceptions without a key: {', '.join(orphaned)}")
        return 1
    print(f"✓ {len(BLOCKLIST)} blocked word(s), none in the catalog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
