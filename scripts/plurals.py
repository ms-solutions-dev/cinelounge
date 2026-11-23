#!/usr/bin/env python3
"""Checks that every counter in the language catalog has a plural form — or a reason.

**The finding of 07.09. (AP10):** Of forty-three keys with a counter, **exactly one**
carried a plural form. On screen that produced "1 Tage Archiv", "1 Portale gefunden",
"Auch die 1 Folgen davor?" and — for this household's provider account, which allows
exactly **one** connection — "1 von 1 Verbindungen belegt".

**Why a script and not diligence.** A new key with `%lld` appears casually, and the
singular only shows when the case occurs: with one portal, one day of archive, one
error. Until then everything looks right.

**What is NOT required is listed below with a reason.** Not every counter needs a
plural:

  * **Ordinals and labels** — "Staffel 1", "Kapitel 1", "Tonspur 1". The number names,
    it does not count.
  * **Nouns that stay the same in German** — "1 Titel"/"5 Titel", "1 Sender",
    "1 Fehler". A variation with two identical branches would be work for nothing, and
    the next reader would wonder what the difference is supposed to be.
  * **Abbreviations** — "1 Min", "1 %".
  * **Sentences without a noun after the number** — "5 gefunden", "3 · 2 aktiv".

**Turkish never needs one.** After a numeral the noun stays singular: "1 kanal",
"5 kanal". That is why the language is not part of the check at all — and why the
Turkish plural forms in the catalog carry the same text twice where they were created
because of another language.

**One list for both catalogs** (26.09.2026, AP58): The guard used to cover only the
phone, and the TV catalog had 32 counters without a plural — "1 Profil(e)
dazugekommen", "noch 1 Sekunden". The reasons below apply to the key, whichever catalog
it is in: a key that appears in both means the same thing. A reason is only stale when
its key is in NEITHER catalog any more.

Usage:   python3 scripts/plurals.py --app tv|handy            → list
         python3 scripts/plurals.py --app tv|handy --check  → report only what is missing
"""
import sys

from programs import PROGRAMS, arguments

# Only these two languages have a plural after the numeral.
LANGUAGES = ("de", "en")

# Key → languages that need no plural → reason.
# Adding one means writing down a reason. Whoever finds none needs the plural.
WITHOUT_PLURAL = {
    # **Live for children (AP52) — the TV's wording**, deliberately built there as a label
    # with a colon: "Gruppen: 3", "Sender: 42". No noun after the number, so no
    # inflection — and a second wording on the phone would be a second truth about the
    # same line.
    "childLock.liveChannels %lld": ("de en", "„12 Sender“ / „channels: 12“ — Sender is invariable in German, English with a colon"),
    "childLock.liveCount %lld %lld": ("de en", "„Gruppen: 3 · Sender: 42“ — label with a colon"),
    "childLock.liveGroupCount %lld": ("de en", "„Gruppen: 3“ — label with a colon"),
    "childLock.limit %lld": ("de en", "label of an age rating: „ab 12“, not „12 Titel“"),
    "childLock.server.upTo %lld": ("de en", "the same age rating, other side"),
    "season.number %lld": ("de en", "ordinal — „Staffel 1“ names, it does not count"),
    "common.seasonEpisode %lld %lld": ("de en", "episode designation „S1 F3“ — ordinals, no noun"),
    "detail.chapterNumber %lld": ("de en", "ordinal — „Kapitel 1“"),
    "sources.track %lld": ("de en", "ordinal — „Tonspur 1“"),
    "filmography.movies %lld": ("de en", "label with the count behind it: „Filme 12“"),
    "filmography.series %lld": ("de en", "the same for series"),
    "detail.castAll %lld": ("de en", "„Alle 12“ — no noun after the number"),
    "season.open %lld": ("de en", "„noch 3“ — no noun after the number"),
    "settings.live.groups.found %lld": ("de en", "„5 gefunden“ — no noun"),
    "childLock.ratings.openShort %lld": ("de en", "„3 nicht eingeordnet“ — no noun"),
    "portal.count %lld %lld": ("de en", "„3 von 5 geladen“ — no noun"),
    "settings.live.groups.count %lld %lld": ("de en", "„79 gelesen · 46 sichtbar“ — no noun"),
    "settings.value.lists %lld": ("de en", "„2 · 1 aktiv“ — no noun"),
    "episode.minutes %lld": ("de en", "abbreviation: „1 Min“, „1 min“"),
    "settings.value.subtitles %lld": ("de en", "percentage, no noun"),
    "settings.live.sports.count %lld %lld": (
        "de en", "the second counter is fixed (23 sports); „1 Sportart“ never occurs"),
    "live.noGuideCount %lld": (
        "de en", "only shown where there is more than one — „einer von 1“ never appears"),
    "childLock.pin.digits %lld": ("de", "„%lld-stellig“ stays the same in German"),
    "common.titleCount %lld": ("de", "„Titel“ is both singular and plural in German"),
    "childLock.ratings.open %lld": ("de", "„Titel“ is both singular and plural in German"),
    "stock.removeCount %lld": ("de", "„Titel“ is both singular and plural in German"),
    "stock.removeWatched %lld": ("de", "„Titel“ is both singular and plural in German"),
    "live.channelCount %lld": ("de", "„Sender“ is both singular and plural in German"),
    "search.channelsSearched %lld": ("de", "„Sender“ is both singular and plural in German"),
    "settings.value.errors %lld": ("de", "„Fehler“ is both singular and plural in German"),
    # **TV** (26.09.2026, AP58).
    "childLock.ratingsFrom %lld": ("de en", "label of an age rating: „ab 12“"),
    "detail.markEarlierAll %lld": ("de en", "„Diese und 3 davor“ — no noun after the number"),
    "detail.playEpisode %lld %lld": ("de en", "ordinals — „S1 F2 abspielen“"),
    "home.resumeAt %lld %lld": ("de en", "ordinals — „Staffel 1, Folge 2“"),
    "handover.tv.done.keys %lld": ("de", "„Schlüssel“ is both singular and plural in German"),
    "settings.homeChannelsTotal %lld": ("de", "„Sender“ is both singular and plural in German"),
    "live.remaining %lld": ("de en", "abbreviation: „noch 1 Min.“, „1 min left“"),
    "player.nextIn %lld": ("de en", "seconds without a unit: „Nächste Folge in 5“ — no noun"),
    "player.sleepMinutes %lld": ("de en", "abbreviated unit „30 Min.“ / „30 min“ — the same for one and many"),
    "player.sleepMinutesLeft %lld": ("de en", "abbreviated unit „noch 1 Min.“ / „1 min left“ — the same for one and many"),
    "settings.homeChosenOf %lld %lld": ("de en", "„3 von 5 gewählt“ — no noun"),
    "settings.homeShownOf %lld %lld": ("de en", "„3 von 5“ — no noun"),
    "sport.moreChannels %lld": ("de en", "„+3 weitere“ — no noun"),
    "settings.liveAdultCount %lld %lld %@": (
        "de en", "label with a colon, without a verb: „…gekennzeichnet: 1 von 412 "
        "Sendern“; the second counter is the whole channel list"),
    "sport.versions %lld": (
        "de en", "only shown for more than one version (`buendel.anzahl > 1` in SportView)"),
}


def counters(strings):
    """Every key whose value inserts a number."""
    return sorted(k for k in strings if "%lld" in k or "%d" in k)


def has_plural(entry):
    return "variations" in entry or "substitutions" in entry


def main():
    program = PROGRAMS[arguments("Counters without a plural form", check=True).app]
    strings = program.entries()
    missing, exempt = [], 0

    for key in counters(strings):
        locations = strings[key].get("localizations", {})
        reason = WITHOUT_PLURAL.get(key)
        for language in LANGUAGES:
            entry = locations.get(language)
            if entry is None or has_plural(entry):
                continue
            if reason and language in reason[0].split():
                exempt += 1
                continue
            missing.append((key, language, entry.get("stringUnit", {}).get("value", "?")))

    # A reason for a key that no longer exists is a reason nobody checks.
    everything = set()
    for other in PROGRAMS.values():
        everything |= set(other.entries())
    stale = sorted(k for k in WITHOUT_PLURAL if k not in everything)

    if "--check" in sys.argv:
        bad = False
        if missing:
            print(f"✗ {len(missing)} counters without a plural form ({program.name}):")
            for key, language, value in missing:
                print(f"    {language}  {key}  →  {value}")
            print("  Add a plural — or give a reason in scripts/plurals.py, WITHOUT_PLURAL.")
            bad = True
        if stale:
            print(f"✗ {len(stale)} reason(s) without a key: {', '.join(stale)}")
            bad = True
        if bad:
            return 1
        total = len(counters(strings))
        print(f"✓ {total} counters, each with a plural form or a reason ({exempt} exempt)")
        return 0

    for key in counters(strings):
        locations = strings[key].get("localizations", {})
        status = []
        for language in LANGUAGES:
            entry = locations.get(language, {})
            if has_plural(entry):
                status.append(f"{language}:plural")
            elif WITHOUT_PLURAL.get(key) and language in WITHOUT_PLURAL[key][0].split():
                status.append(f"{language}:reasoned")
            else:
                status.append(f"{language}:MISSING")
        print(f"  {key:45} {' '.join(status)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
