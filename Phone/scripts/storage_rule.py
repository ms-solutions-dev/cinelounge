#!/usr/bin/env python3
"""Who touches the default store — and is it on the list for that?

**The "done when" commitment of AP40** (20.09.2026): The feature comparison found
sixteen settings with the same purpose but a different key or a different store.
The rule against that lives in `ARCHITEKTUR.md`, section 8, ("Wohin eine Einstellung gehört"); what
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
    # ── Platform matters: right there, not merely tolerated ──────────────────
    #
    # The language choice reads `AppleLanguages` next to it; the haptics preference
    # belongs to the device and not to the person. (The version change of the error
    # ledger moved to `../Packages` with `Diagnose` on 26.09.2026 and is listed in
    # `../scripts/storage_rule.py`.)
    "Packages/DesignSystemPhone/Sources/DesignSystemPhone/LanguageChoice.swift",
    "Packages/DesignSystemPhone/Sources/DesignSystemPhone/Haptics.swift",
    # The diagnostics identifier is a name and not a secret — and it has to be the same
    # across program runs so that two reports fit together.
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Settings/DiagnoseView.swift",
    # The observer of the app language (AP46, 25.09.2026) also writes `AppleLanguages` —
    # same reason as for the language choice.
    "Packages/DesignSystemPhone/Sources/DesignSystemPhone/LanguageState.swift",
    # Launch parameters and hints that appear exactly once.
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Downloads/DownloadsNotice.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Portals/PortalChoiceSheet.swift",

    # ── Takeover from the old places (AP40) ──────────────────────────────────
    #
    # They **read** the default store in order to fetch from it into the shared one.
    # They disappear once the takeover is no longer needed one day.
    "App/Sources/Startup.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Setup/SetupState.swift",
    # The first setup (AP88 wave 6, 16.11.2026) only **hands** the default store on — to
    # `SetupState`, `StartChoice` and `ProfileManagement`, which read it already; the checks
    # pass their own suite instead.
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Setup/SetupHub.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/ParentalControls/ParentalControlsState.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Accounts/HandoffModel.swift",
    # Moved on 21.09.2026 — only one `uebernimm(aus:in:)` each remains here.
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Library/SortMemory.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Settings/TabSelection.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Player/PictureFill.swift",

    # ── State that belongs in the state ledger (AP42) — **not retirement** ───
    #
    # **Looked at one by one on 21.09.2026, and the old heading was wrong.**
    # Here they were called "structure" together; they are not. They all answer the
    # same question — *where was I?* — and by the rule in `ARCHITEKTUR.md` that is
    # **state**: the catalog last opened, the section last opened, the channels last
    # seen, the path in the portal, the page last chosen in the Live area.
    #
    # Moving them to ``Core/Dateiablage`` now would mean moving them twice: AP42 builds
    # the state ledger, and then they belong there — **per profile** and not per device,
    # because *"where was I"* is a question to a person. **No new ones are added.**
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Library/CatalogMemory.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Library/CategoryMemory.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Live/LiveView.swift",
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Portals/PortalsModel.swift",

    # ── Temporary storage that belongs in temporary storage ──────────────────
    #
    # Fetched third-party notes are a cache: if they are gone, the next fetch gets them
    # again. By the rule they therefore belong neither here nor in the file store but
    # under `Caches` — the same classification as for the schedule downloads over there.
    "Packages/FeaturesPhone/Sources/FeaturesPhone/Shell/NoteStore.swift",

    # The views that read the color scheme via `@AppStorage` until AP58 R7
    # (DarstellungView, EinstellungenModel) are no longer listed here: the color scheme
    # has lived in the file store since then (`Core/Farbmuster`).
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
        "  Where a setting belongs is described in ARCHITEKTUR.md. Whoever needs the default store\n"
        "  adds themselves in scripts/storage_rule.py — with the reason."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
