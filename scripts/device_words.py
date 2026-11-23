#!/usr/bin/env python3
"""Checks that no sentence in the language catalog calls *this* device a phone.

**Why this step exists.** Since AP7 the same app runs on the iPad, and since Split View
and Stage Manager it also runs there in the narrow size class — with an unchanged device
idiom. A sentence like "The PIN is in this phone's Keychain" is simply wrong on an iPad,
and silently so: nothing crashes, there is just nonsense on screen. On 24.09.2026 the
catalog held 17 such hits, spread over three languages.

**There is one rule, not two.** Device-neutral in **one** sentence — not two versions per
device. Two versions would mean two texts per language, six instead of three, and a
decision about which one applies, made at the spot that draws the text. The decision
"iPhone or iPad" is not even the right one — Split View gives the iPad the compact class,
and a `UIDevice.userInterfaceIdiom` would be wrong there immediately. A sentence that
covers both does not have the problem.

**Not every hit is wrong**, and that is why this checker is a list with reasons and not a
pattern. Four sentences explicitly mean *a* phone and not *this device*: the TV's menu
item, a screen size, and two phone↔TV contrast pairs. They are listed below in
``WITH_REASON``, each with the reason it stays. A reason you have to write down is a
reason you have thought through — the same shape as ``OHNE_EINTRAG`` in
`Phone/scripts/catalog.py`.

**Why via the catalog and not via the source.** Visible text lives in this app only in
the catalog; `scripts/strings.py` enforces that. Checking the source would check key
names — and a key is called what it always was.

**Two rules, depending on who shows the sentence** (26.09.2026, AP58):

  * **Shared sentences** — keys that shared code looks up (`Packages/`, `grundstock`;
    determined via ``programs.shared_keys``) — name a device in NO catalog,
    neither phone nor iPad nor TV. They appear on both devices. The finding:
    `PortalKit` builds `"error." + code` from the portal service's reply, and the TV
    catalog said "Dieser Fernseher braucht ein Profil." for it — the phone catalog said
    "Dieses Gerät …" for the same key. Once both catalogs merge into one shared catalog
    (report B, step 4) there is only one version, and it has to be right on both devices.
  * **Phone, all sentences** — the old rule above: no phone for *this* device.
    The TV has no counterpart: a TV is always a TV, and "on this TV" is correct there.

Usage:   python3 scripts/device_words.py --app tv|handy            → list
         python3 scripts/device_words.py --app tv|handy --check  → errors only
"""
import re
import sys

from programs import PROGRAMS, arguments, shared_keys

# Device words in all three languages. `telefon` also covers the Turkish inflections
# (telefonda, telefonun, telefondaki, telefona), `phone` also covers "iPhone".
PATTERN = re.compile(r"telefon|phone", re.IGNORECASE)

# For shared sentences additionally iPad and the TV. "Fernseher" and not "fernseh":
# "Fernsehsender" and "Live-TV" are the medium, not a device. For the same reason `TV`
# appears only as "Apple TV".
SHARED_PATTERN = re.compile(
    r"telefon|phone|ipad|fernseher|apple[ -]?tv|televizyon|television", re.IGNORECASE)

# Shared sentences that may name a device — each with a reason. Empty is the normal case.
SHARED_WITH_REASON: dict[str, str] = {
    # Since AP58 R3 (26.09.2026) all states live in `Flows`, shared — including those that
    # only the phone produces (``Zustand.nurTelefon``). Two of them are about the TV as the
    # other device — phrased neutrally they would no longer say where to look.
    "state.camera.denied.text":
        "The code is shown on the TV; the phone's camera reads it. \"Am anderen "
        "Gerät\" would leave open where to find the code. Only the phone shows the state.",
    "state.tv.unreachable.title":
        "The remote on the phone is looking for the TV — it is the subject of the "
        "message and not this device. Only the phone shows the state.",
    "state.tv.unreachable.text":
        "The same state: \"Ist der Apple TV eingeschaltet?\" is the action, and "
        "without the name nobody would know which device is meant.",
    "handover.error.expired":
        "Sentence of the handover SENDER (``Uebergabemeldung``, side .absender, AP58 R5): it appears only on the phone and names the COUNTERPART, the TV that shows the code. Neutral, it would lose the information on which device something has to be done.",
    "handover.error.timeout":
        "Sentence of the handover SENDER (``Uebergabemeldung``, side .absender, AP58 R5): it appears only on the phone and names the COUNTERPART, the TV that shows the code. Neutral, it would lose the information on which device something has to be done.",
    "handover.error.unreachable":
        "Sentence of the handover SENDER (``Uebergabemeldung``, side .absender, AP58 R5): it appears only on the phone and names the COUNTERPART, the TV that shows the code. Neutral, it would lose the information on which device something has to be done.",
    "handover.error.unreadable":
        "Sentence of the handover SENDER (``Uebergabemeldung``, side .absender, AP58 R5): it appears only on the phone and names the COUNTERPART, the TV that shows the code. Neutral, it would lose the information on which device something has to be done.",
    "handover.error.version":
        "Sentence of the handover SENDER (``Uebergabemeldung``, side .absender, AP58 R5): it appears only on the phone and names the COUNTERPART, the TV that shows the code. Neutral, it would lose the information on which device something has to be done.",
    "handover.error.receiver.noService":
        "Sentence of the handover RECEIVER (``Uebergabemeldung``, side .empfaenger, AP58 R5): it appears only on the TV. The board of sides lives in the shared code; the sentence stays tied to its point of view.",
    "handover.error.receiver.version":
        "Sentence of the handover RECEIVER (``Uebergabemeldung``, side .empfaenger, AP58 R5): it appears only on the TV. The board of sides lives in the shared code; the sentence stays tied to its point of view.",
    "setup.welcome.fetchFromPhone":
        "A2 of the TV's first setup (AP88, ``WelcomeView``): the TV fetches a profile from the "
        "OTHER device, the iPhone with CineLounge. Neutral, the button would not say where the "
        "profile lies. The phone's setup scans instead and never shows this sentence.",
    "setup.welcome.codeHint":
        "The line under the QR on A2 of the TV (AP88 §4.2): the code works only with CineLounge "
        "on the iPhone, and the sentence says so honestly. It names the counterpart, not this device.",
}

# Entries that name a phone and mean it — each with the reason.
WITH_REASON = {
    "setup.welcome.fetchFromPhone":
        "TV sentence of the first setup (A2, AP88): it names the phone the profile comes "
        "from. The phone's own setup scans and never shows it.",
    "setup.welcome.codeHint":
        "TV sentence under the QR on A2 (AP88): it names the phone whose camera reads the "
        "code — on the phone itself it never appears.",
    "handover.error.receiver.version":
        "TV sentence during the handover (side .empfaenger): it names the phone that "
        "sends the package — on the phone itself it never appears (AP58 R5).",
    "remote.pairing.hint":
        "Quotes the TV's menu item (\"iPhone als Fernbedienung\") under which the "
        "pairing code is shown. Neutral, nobody would find what to look for there.",
    "remote.pairing.unpairedText":
        "The same TV menu item — the sentence says what to open there.",
    "handover.scan.text":
        "Quotes the TV's menu item (\"Von einem Telefon einrichten\"). The sentence "
        "says what is on the screen there; made neutral, nobody would find what to "
        "look for any more.",
    "place.sources.away":
        "\"Ein Telefon braucht auf sechs Zoll keine 4K\" is a statement about a screen "
        "size and not about this device. The six inches are in the sentence — "
        "they are the reason for 720p on the go.",
    "settings.portals.account.footnote":
        "Contrast pair: \"Auf dem Telefon anfangen, am Fernseher weiterschauen.\" The "
        "sentence lives from naming two different devices; \"auf dem Gerät "
        "anfangen, am Fernseher weiterschauen\" loses the contrast.",
    "setup.network.footnote":
        "Contrast pair with the TV, phrased indefinitely (\"on a phone it is the "
        "quicker way\"): typing happens here because it is tedious on the TV with the "
        "remote. The device class is meant, not this particular unit.",
}


def sentences(version) -> list[str]:
    """All texts of a version — including the branches of a plural or substitution."""
    if isinstance(version, dict):
        result = [version["value"]] if isinstance(version.get("value"), str) else []
        for value in version.values():
            result += sentences(value)
        return result
    return []


def entries(catalog: dict, pattern: re.Pattern) -> dict[str, dict[str, str]]:
    """Per key the versions that carry a device word — language → sentence."""
    found: dict[str, dict[str, str]] = {}
    for key, entry in catalog.items():
        hits = {}
        for language, version in entry.get("localizations", {}).items():
            for sentence in sentences(version):
                if pattern.search(sentence):
                    hits[language] = sentence
        if hits:
            found[key] = hits
    return found


def main() -> int:
    program = PROGRAMS[arguments("Device words in the language catalog", check=True).app]
    catalog = program.entries()
    check = "--check" in sys.argv

    shared = shared_keys(catalog)
    shared_found = {
        k: v for k, v in entries(catalog, SHARED_PATTERN).items() if k in shared}
    shared_without_reason = {
        k: v for k, v in shared_found.items() if k not in SHARED_WITH_REASON}

    # The old phone rule only applies where "this device" is a phone or iPad.
    if program.name == "phone":
        found = entries(catalog, PATTERN)
        without_reason = {k: v for k, v in found.items() if k not in WITH_REASON}
        orphaned = sorted(set(WITH_REASON) - set(found))
    else:
        found, without_reason, orphaned = {}, {}, []

    if check:
        bad = False
        if shared_without_reason:
            print(f"✗ {len(shared_without_reason)} shared sentence(s) name a device "
                  f"({program.name}):")
            for key, versions in sorted(shared_without_reason.items()):
                places = ", ".join(sorted(shared[key])[:2])
                print(f"    {key}   ← {places}")
                for language, sentence in sorted(versions.items()):
                    print(f"      {language}: {sentence}")
            print("  Shared code shows it on both devices — phrase it device-neutrally.")
            bad = True
        if without_reason:
            print(f"✗ {len(without_reason)} entry/entries call this device a phone:")
            for key, versions in sorted(without_reason.items()):
                print(f"    {key}")
                for language, sentence in sorted(versions.items()):
                    print(f"      {language}: {sentence}")
            print("  Device-neutral in ONE sentence — or in WITH_REASON below, with a reason.")
            bad = True
        # **This is an error too, and not a trifle.** A reason that points at nothing any
        # more is an exception that lets someone through next time: whoever renames the
        # key has inherited the exception without it being checked any more.
        orphaned_shared = sorted(set(SHARED_WITH_REASON) - set(shared_found))
        if orphaned or orphaned_shared:
            print(f"✗ {len(orphaned) + len(orphaned_shared)} reason(s) point to "
                  "no entry any more:")
            for key in [*orphaned, *orphaned_shared]:
                print(f"    {key}")
            bad = True
        if bad:
            return 1
        print(f"✓ {len(shared)} shared sentences device-neutral")
        if program.name == "phone":
            print(f"✓ {len(found)} entry/entries with a device word, "
                  f"each with a reason ({len(WITH_REASON)} reasons)")
        return 0

    print(f"{len(shared)} shared sentences, {len(shared_found)} of them with a device word")
    for key, versions in sorted(shared_found.items()):
        label = "reasoned" if key in SHARED_WITH_REASON else "NO REASON"
        print(f"\n  {key}  [shared, {label}]")
        for language, sentence in sorted(versions.items()):
            print(f"    {language}: {sentence}")
    for key, versions in sorted(found.items()):
        label = "reasoned" if key in WITH_REASON else "NO REASON"
        print(f"\n  {key}  [{label}]")
        for language, sentence in sorted(versions.items()):
            print(f"    {language}: {sentence}")
    if orphaned:
        print(f"\nReasons without an entry: {', '.join(orphaned)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
