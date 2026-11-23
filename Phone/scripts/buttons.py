#!/usr/bin/env python3
"""Checks that no drawn button is left without an effect.

Why this is a step of its own and not left to the compiler: since
`StateView.action` is no longer optional, nobody can FORGET it any more — but
anyone can write `action: {}`. An empty body compiles cleanly and still draws a
button that does nothing. That was exactly the finding of 06.09.: eleven call
sites, two with an action, and `StateBlock` drew an outline and a chevron around
a button leading nowhere.

`ShellView` spells the rule out itself: "a button that leads nowhere is worse
than none."

Procedure:
  1. Find every call site of `StateView(` and `StateBlock(` under `Packages/`
     and `App/` together with its parenthesis, across lines.
  2. Look at every `action:` and `secondaryAction:` inside. An empty body
     (`{}`, `{ }`) is an error.
  3. UNLESS the site carries the marker `// knopflos:` above it, with a
     reason. Nothing is enumerated: the reason stands at the place, not in a
     list here in the script that nobody reads.

Return value: 0 if no empty body without a reason is left, otherwise 1.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCATIONS = ["App", "Packages"]
COMPONENTS = ("StateView", "StateBlock", "LoadingState")
# `{}` or `{ }` — a body that does nothing.
EMPTY = re.compile(r"^\s*\{\s*\}\s*$")


def call_sites(text: str):
    """Finds every call site together with its closing parenthesis."""
    for component in COMPONENTS:
        for match in re.finditer(re.escape(component) + r"\(", text):
            depth, i = 1, match.end()
            while i < len(text) and depth > 0:
                if text[i] == "(":
                    depth += 1
                elif text[i] == ")":
                    depth -= 1
                i += 1
            yield match.start(), text[match.end() : i - 1]


def justified(text: str, position: int) -> bool:
    """Whether a `// knopflos:` marker stands above the call site.

    Ten lines back and not two: the reason is a sentence and not a margin
    note — whoever writes it writes it out, and then the call sits further
    down.
    """
    return "// knopflos:" in "\n".join(text[:position].split("\n")[-10:])


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    errors = []
    for position, body in call_sites(text):
        line = text[:position].count("\n") + 1
        for name in ("action", "secondaryAction"):
            # `secondaryAction:` would otherwise also catch `action:`.
            pattern = re.compile(r"(?<![A-Za-zäöü])" + name + r":\s*([^,\n]*)")
            for value in pattern.finditer(body):
                if EMPTY.match(value.group(1)) and not justified(text, position):
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line}  {name} is an empty body"
                    )
    return errors


def states() -> int:
    """Checks that every state has a producer — or a reason.

    "Never set" is the quietest error on the list: the state is there, the
    showcase presents it, a check sentence names its texts — and on the device
    it never appears. On 06.09. eleven of nineteen were like that.

    **Since AP58 R3 (26.09.2026) the state is shared** in
    `../Packages/Flows`, together with the disruption interpretation. What is
    read therefore is:

    * the cases from the shared `PlaybackPhase.swift`,
    * `PlaybackPhase.tvOnly` in the same place — only the TV produces these
      cases, they need no producer here,
    * `PlaybackPhase.withoutProducerYet` from `PlaybackPhase+Phone.swift` — the
      phone's list, each case with a reason.

    A producer is the phone's source text **and** the shared interpretation
    (`DisruptionInterpretation.swift`): what it makes of an error comes into
    being on the phone as soon as a model asks it. The tables themselves do not
    count — `PlaybackPhase.swift`, the lists in `InfoVersusAction.swift`, the
    mapping in `PlaybackPhase+Phone.swift` and the showcase name every case and
    produce none.

    **If the checker does not find the shared file, that is an error** and not
    a silent pass: until 26.09. this returned 0 when the file was missing — the
    move would have switched the check off without a sound.
    """
    folder = ROOT / "Packages/FeaturesPhone/Sources/FeaturesPhone"
    shared = ROOT.parent / "Packages/Flows/Sources/Flows/States"
    file = shared / "PlaybackPhase.swift"
    phone = folder / "States/PlaybackPhase+Phone.swift"
    if not file.exists() or not phone.exists():
        print(f"✗ State not found ({file} / {phone})")
        return 1
    source = file.read_text(encoding="utf-8")
    cases = re.findall(r"^    case (\w+)(?: = \"[^\"]*\")?$", source, re.M)

    def collect(text: str, name: str) -> set[str]:
        block = re.search(name + r": Set<PlaybackPhase> = \[(.*?)\]", text, re.S)
        return set(re.findall(r"\.(\w+)", block.group(1))) if block else set()

    tv_only = collect(source, "tvOnly")
    explained = collect(phone.read_text(encoding="utf-8"), "withoutProducerYet")
    if not cases or not tv_only:
        print("✗ Cases or `tvOnly` in the shared state not readable")
        return 1

    tables = ("PlaybackPhase.swift", "StateShowcase.swift", "PlaybackPhase+Phone.swift")
    sources = [
        p.read_text(encoding="utf-8")
        for p in folder.rglob("*.swift")
        if p.name not in tables
    ] + [(shared / "DisruptionInterpretation.swift").read_text(encoding="utf-8")]

    without = set()
    for case in cases:
        if case in tv_only:
            continue
        pattern = re.compile(r"\." + case + r"\b")
        if not any(pattern.search(text) for text in sources):
            without.add(case)

    missing = sorted(without - explained)
    outdated = sorted(explained - without)
    for name in missing:
        print(f"  {name}: no producer and no reason in `withoutProducerYet`")
    for name in outdated:
        print(f"  {name}: has a producer — the line in `withoutProducerYet` can go")
    if missing or outdated:
        print(f"✗ {len(missing) + len(outdated)} states do not match their list")
        return 1
    on_phone = len(cases) - len(tv_only)
    print(
        f"✓ {on_phone} states on the phone, {on_phone - len(without)} with a producer, "
        f"{len(without)} with a reason"
    )
    return 0


def main() -> int:
    errors = []
    checked = 0
    for location in LOCATIONS:
        for path in sorted((ROOT / location).rglob("*.swift")):
            if ".build" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            if not any(c + "(" in text for c in COMPONENTS):
                continue
            checked += sum(1 for _ in call_sites(text))
            errors += check_file(path)

    if errors:
        for line in errors:
            print(f"  {line}")
        print(f"✗ {len(errors)} buttons without effect and without a reason")
        return 1
    print(f"✓ {checked} state buttons, each with an effect or with a reason")
    return states()


if __name__ == "__main__":
    sys.exit(main())
