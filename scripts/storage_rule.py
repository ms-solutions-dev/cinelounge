#!/usr/bin/env python3
"""Who touches the default store — and is it on the list for that?

**The "done when" commitment of AP40** (20.09.2026): The feature comparison found
sixteen settings with the same purpose but a different key or a different store.
The rule against that lives in `README.md` ("Wohin eine Einstellung gehört"); what
was missing was something that notices when it is followed.

**Files and not keys, and that is a deliberate boundary.** A key sometimes stands as
a literal at `forKey:`, sometimes as a constant twenty lines further up, sometimes
composed. Whoever wants to find them all builds half a compiler and still misses the
twenty-first case. A **place**, on the other hand, is unambiguous: this file touches
`UserDefaults`, that one does not. Whoever opens a new one justifies it here — and on
exactly that day the question is cheap to answer.

Usage: `scripts/storage_rule.py [--list]`
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# **Who may touch the default store today — with the reason next to it.**
#
# The list is not a permission for the future but the inventory of 20.09.2026. What
# stands here is either right there (platform matter, test tooling) or work that is
# listed in AP40.
ALLOWED = {
    # The one-time parental-controls migration (AP59 N4, 30.09.2026) — reads and deletes
    # the child-mode switch and sets the start choice, both always in the default store;
    # its own marker sits next to it for the same reason. It runs before any UI.
    "Packages/Flows/Sources/Flows/ParentalControlsMigration.swift",
    # The child-mode switch (`childMode.on`) — shared with the phone and always in the
    # default store there. A switch, not a secret.
    "Packages/ParentalControls/Sources/ParentalControls/ChildMode.swift",
    # "Hide unmarked adult channels" (`childLock.hideUnmarked`, G3) — the same place
    # where the phone has always kept the switch; since it also exists on the TV,
    # ``Sendersperre`` reads and writes it for both. A device switch like child mode
    # next to it, not a secret, and only changeable behind the parental-controls door.
    # In Core since 27.09.2026 because `LiveLibrary` creates the lock at the source
    # (Live review, finding 1).
    "Packages/Core/Sources/Core/ChannelLock.swift",
    # The backup of the structure store (AP66, 03.10.2026). On the TV the store lives
    # in Caches, and tvOS may purge that; only about 500 KB of default store is
    # permanent there. Not a setting that lives here but a copy of the files — with a
    # budget (300 KB) so it does not eat the space of the other switches.
    # ``Dateiablage`` passes `.standard` on to it only when it lives in Caches.
    "Packages/Core/Sources/Core/StoreBackup.swift",
    "Packages/Core/Sources/Core/FileStore.swift",
    # "Start automatically as ..." (`profile.startetAls`, AP45) — the same kind as child
    # mode next to it and for the same reason: The choice belongs to the **device** and
    # not to the person. The TV in a child's room starts as one profile, the one in the
    # living room as another; a value that travelled through the cloud would turn the
    # setting of one into that of the other. It is not a secret — the PIN is in the
    # Keychain, and the start choice does not get past it (see `Startwahl.wendeAn`).
    "Packages/ProfileKit/Sources/ProfileKit/StartChoice.swift",
    # Takes a `UserDefaults` only in order to **take over** from it (AP40) and to
    # **clear** it after a successful takeover (AP48, decision 2 of 25.09.2026: clean
    # cut) — nothing new is written there.
    "Packages/ParentalControls/Sources/ParentalControls/ChildAccountList.swift",
    # Only pass on the old `UserDefaults` and the store of the ``Startwahl`` — to the
    # clearing of the legacy data (AP48) and to the move of a profile identifier when
    # merging (AP45). They do not store anything there themselves; a start choice that
    # points to a vanished profile moves to the remaining one.
    # Shared since AP58 R2: ``Profilanlauf`` passes the start choice's store and the old
    # `UserDefaults` on to migration, clearing and start choice; ``Altbestand`` clears it.
    "Packages/Flows/Sources/Flows/LegacyData.swift",
    "Packages/Flows/Sources/Flows/ProfileStartup.swift",
    "Packages/Features/Sources/Features/Accounts/ProfileModel.swift",
    # Since AP58 R7 the management is shared; it passes the start choice's store on when
    # merging, like the profile model before it.
    "Packages/Flows/Sources/Flows/ProfileManagement.swift",
    "Packages/ProfileKit/Sources/ProfileKit/ProfileMove.swift",
    "Packages/ProfileKit/Sources/ProfileKit/ProfileCloud.swift",
    "Packages/ProfileKit/Sources/ProfileKit/ProfileMerge.swift",
    "Packages/SecondScreen/Sources/SecondScreen/Takeover.swift",
    # The channel history per profile (AP58 R5): lives in the file store and takes the
    # `UserDefaults` only in order to take over the old device list ONCE and to clear it
    # there — nothing new is written there.
    "Packages/Flows/Sources/Flows/ChannelHistory.swift",
    # The sports reminder list per profile (decision 27, B5): lives in the file store and
    # takes the `UserDefaults` only in order to take over the phone's oldest list ONCE and
    # to clear it there — nothing new is written there.
    "Packages/Core/Sources/Core/SportReminderList.swift",
    # The device's language choice (`app.language`). It belongs in the default store
    # because the system keeps `AppleLanguages` next to it and both are read together.
    # Since 25.09.2026 (AP46) ``Appsprache`` in Core reads and writes it; a person's
    # choice lives in their compartment in the Keychain, the device value stays here.
    "Packages/Core/Sources/Core/AppLanguageSetting.swift",
    # The marker "the old Keychain service has been read out" (AP39). It is not access
    # information, and whoever sets the app up again should get the data back from a
    # restored backup.
    "Packages/PlaylistKit/Sources/PlaylistKit/DeviceStore.swift",
    # `server.lastAddress` lives in the file store since AP58 R7; the shared
    # ``Anmeldeablauf`` takes the old `UserDefaults` only in order to take over the
    # address ONCE and to clear it there.
    "Packages/Flows/Sources/Flows/LoginFlow.swift",
    # The color scheme lives in the file store since AP58 R7 (`Core/Farbmuster`).
    # Both take `UserDefaults` only in order to take over the earlier choice ONCE and
    # to clear it there — nothing new is written there.
    "Packages/Core/Sources/Core/ColorPattern.swift",
    "Packages/Features/Sources/Features/Settings/ThemeStore.swift",
    # The program version for which the error ledger is kept — belongs to the device and
    # not to the person. Moved here from `Phone/Packages/` together with `Diagnose` on
    # 26.09.2026 (AP58 R0); until then the entry stood in `Phone/scripts/storage_rule.py`.
    "Packages/Diagnose/Sources/Diagnose/VersionChange.swift",
}


def locations() -> dict[str, list[int]]:
    """All files that touch `UserDefaults` or `@AppStorage`."""
    pattern = re.compile(r"UserDefaults|@AppStorage")
    found: dict[str, list[int]] = {}
    for path in sorted(ROOT.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        if "/.build/" in rel or "/Tests/" in rel or ".dd/" in rel:
            continue
        if not rel.startswith(("App/", "Packages/")):
            continue
        # grundstock is a repo of its own with its own run; the public copy embeds it
        # here, the private one keeps it next door, out of reach of this glob.
        if rel.startswith("Packages/Grundstock/"):
            continue
        lines = [
            number
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1)
            if pattern.search(line) and not line.strip().startswith("//")
        ]
        if lines:
            found[rel] = lines
    return found


def main() -> int:
    found = locations()

    if "--list" in sys.argv:
        for rel, lines in found.items():
            marker = " " if rel in ALLOWED else "*"
            print(f"{marker} {rel}  (lines {', '.join(map(str, lines))})")
        return 0

    new = {rel: lines for rel, lines in found.items() if rel not in ALLOWED}
    orphaned = sorted(ALLOWED - set(found))

    if orphaned:
        print(f"  {len(orphaned)} entries of the list no longer touch anything:")
        for rel in orphaned:
            print(f"    {rel}")

    if not new:
        print(f"  {len(found)} places at the default store, all with a reason")
        return 1 if orphaned else 0

    print(f"  {len(new)} places without an entry in the list:")
    for rel, lines in new.items():
        print(f"    {rel}  (line {lines[0]})")
    print(
        "  Where a setting belongs is described in README.md. Whoever needs the default store\n"
        "  adds themselves in scripts/storage_rule.py — with the reason."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
