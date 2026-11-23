"""Which sources look up their language keys in the catalog of ONE app?

Shared by `scripts/strings.py` (TV) and `Phone/scripts/strings.py` (phone).

**Why this is computed rather than kept in a list** (26.09.2026): The shared
packages under `Packages/` and the `grundstock` repo have no catalog of their own.
Their texts go through `bundle: .main` or `Appsprache.buendel` — that is, into the
catalog of whichever app is carrying them. Every app therefore has to hold the keys
of ALL the packages it links. The phone checker only searched `Phone/App` and
`Phone/Packages` and so missed 27 keys of the shared packages — the track picker
showed "Deutsch · player.subtitleForced" on the device. A package list maintained by
hand would drift apart just like the catalog itself; that is why the linkage is
derived from `project.yml` and the `Package.swift` files.

Counting happens at the **package level**: If an app links a package, every
`Sources/` in it counts. A product the app does not take from the package therefore
counts too — that is the cautious direction: it can at most demand one key too many,
never overlook one.

`Tests/` do not count: tests never run inside the app, and their test data
(`ard.de`, `a.tr`) has the shape of a key without being one.
"""

from __future__ import annotations

import pathlib
import re

import yaml

PACKAGE_PATH = re.compile(r'\.package\(\s*path:\s*"([^"]+)"')

# **The shared catalog** (AP58 R0, report B finding 4). Since 26.09.2026 the package
# `WordingKit` has a catalog of its own via `Bundle.module`; what shared packages say
# themselves moves there bit by bit. A key then lives in EXACTLY one catalog: the
# shared one or the app's.
WORDING = pathlib.Path(__file__).resolve().parent.parent / "Packages" / "WordingKit"
WORDING_CATALOG = WORDING / "Sources" / "WordingKit" / "Resources" / "Localizable.xcstrings"

# A line that reads a literal key **past the shared catalog** (AP58 final step). Until
# then the rule ran the other way round: A line with a shared key had to carry
# `wort(`/`Wortlaut.`. Since `Text(app:)`, `Text(appKey:)`, `Appsprache.text(_:)` and
# `Appsprache.satz(_:)` themselves look the key up in the catalog that holds it, most
# paths are correct — including those where a key travels through a building block as
# `titel:`. What stays wrong are only the endpoints that name a bundle outright or let
# SwiftUI pick the main bundle:
#
# * `bundle: .main`, `Bundle.main`, `bundle: AppLanguageSetting.bundles` (without `(zu:)`)
# * `String(localized: "…"` and `NSLocalizedString("…"` — except with the bundle of
#   the catalog that holds the key (`AppLanguageSetting.bundles(zu:)`)
# * the SwiftUI building blocks that look up a literal key themselves
#   (`Text("…")`, `Button("…")`, `.navigationTitle("…")` …)
BYPASSES_WORDING = re.compile(
    r'^(?!.*bundles\(zu:).*?(?:'
    r'bundle:\s*(?:\.main\b|Bundle\.main\b|AppLanguageSetting\.bundles\b)'
    r'|localized:\s*"|NSLocalizedString\(\s*"'
    r'|(?<![\w.])(?:Text|Button|Label|Toggle|Section|Picker|TextField|SecureField|Link|Menu'
    r'|LabeledContent|navigationTitle|alert|confirmationDialog|accessibilityLabel'
    r'|accessibilityHint|accessibilityValue|help)\(\s*")')


def _package_and_dependencies(start: pathlib.Path, seen: set[pathlib.Path]) -> None:
    """A local package and everything its `Package.swift` links by path."""
    package = start.resolve()
    if package in seen:
        return
    seen.add(package)
    manifest = package / "Package.swift"
    if not manifest.exists():
        raise SystemExit(f"✗ No Package.swift under {package}")
    for rel in PACKAGE_PATH.findall(manifest.read_text(encoding="utf-8")):
        _package_and_dependencies(package / rel, seen)


def packages(project: pathlib.Path, target: str = "CineLounge") -> list[pathlib.Path]:
    """Every local package that the app target `target` links — also through other packages."""
    root = project.parent
    data = yaml.safe_load(project.read_text(encoding="utf-8"))
    directory = data.get("packages", {})
    seen: set[pathlib.Path] = set()
    for dep in data["targets"][target].get("dependencies", []):
        name = dep.get("package")
        if name is None:
            continue
        if name not in directory:
            raise SystemExit(f"✗ {project.name}: package {name} is not listed under packages:")
        _package_and_dependencies(root / directory[name]["path"], seen)
    return sorted(seen)


def wording_catalog(project: pathlib.Path, target: str = "CineLounge") -> pathlib.Path | None:
    """The shared catalog if the app target links `WordingKit` — otherwise `None`.

    Derived like everything here: A program that does not carry the package does not
    get its keys credited either.
    """
    if WORDING.resolve() in packages(project, target) and WORDING_CATALOG.exists():
        return WORDING_CATALOG
    return None


def source_folders(project: pathlib.Path, target: str = "CineLounge") -> list[pathlib.Path]:
    """The folders whose `*.swift` look up in the catalog of the app target `target`.

    - the `sources:` of the target in `project` (folders only, resources carry no Swift)
    - `Sources/` of every package the target names under `dependencies:`, and —
      through `.package(path:)` — of every package those in turn link

    Other targets (the Top Shelf extension) do not count: They are a bundle of their
    own, and `.main` there is the extension, not the app.
    """
    root = project.parent
    data = yaml.safe_load(project.read_text(encoding="utf-8"))
    entry = data["targets"][target]

    folders: list[pathlib.Path] = []
    for source in entry.get("sources", []):
        path = source if isinstance(source, str) else source.get("path")
        if isinstance(source, dict) and source.get("buildPhase") == "resources":
            continue
        folders.append((root / path).resolve())

    for package in packages(project, target):
        if (package / "Sources").is_dir():
            folders.append(package / "Sources")
    return folders


def swift_files(folders: list[pathlib.Path]):
    """All `*.swift` under the folders, without build debris and agent working copies.

    **Filtering happens relative to each folder**, not on the absolute path: If the
    whole repo itself lies in a working copy under `.claude/worktrees/…`, the old
    filter `"/.claude/" in str(path)` excluded EVERY file, and the checker reported
    "0 keys used, all present" there — green without having checked anything.
    """
    for base in folders:
        for path in sorted(base.rglob("*.swift")):
            rel = "/" + str(path.relative_to(base))
            if "/.build/" in rel or "/.claude/" in rel or "/.dd/" in rel:
                continue
            yield path


def display_name(path: pathlib.Path, root: pathlib.Path) -> str:
    """Relative to the repo root, otherwise (grundstock) starting at the package name."""
    try:
        return str(path.relative_to(root))
    except ValueError:
        parts = path.parts
        if "Sources" in parts:
            i = parts.index("Sources")
            return str(pathlib.Path(*parts[i - 1:]))
        return str(path)
