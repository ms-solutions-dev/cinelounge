"""The two programs of the repo — catalog and sources per app, in ONE place.

Shared by the guards `plurals.py`, `device_words.py`, `colors.py`, `type_scale.py`,
`glossary.py` and `silent-errors.py`. Each runs with `--app tv` from
`scripts/check.sh` and with `--app phone` from `Phone/scripts/check.sh`.

**Why the guards live here and not twice** (26.09.2026, AP58): Until the merge
(decision 17) only the phone had these four guards, and they only knew the phone
catalog and `Phone/`. The TV ran without them: 32 counters without a plural form,
"Dieser Fernseher braucht ein Profil." in a sentence that the shared `PortalKit` also
shows on the phone, 17 system colors without a justification. One copy per program
would have recreated the same situation within two months — only with two rule sets
that drift apart. Hence one script, and whatever differs per program is in
``PROGRAMS``.

**The sources per program** are the program's own folders (as the guards have read
them so far, including extensions such as widgets and Top Shelf) plus everything the
app target links according to ``linkage.source_folders`` — so the shared packages
under `Packages/` and `grundstock` as well. Shared code runs on both devices and is
therefore subject to both rule sets.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re

import json

from linkage import WORDING_CATALOG, source_folders, swift_files, wording_catalog

ROOT = pathlib.Path(__file__).resolve().parent.parent


@dataclasses.dataclass(frozen=True)
class Program:
    name: str
    project: pathlib.Path
    catalog: pathlib.Path
    own: tuple[pathlib.Path, ...]

    def source_folders(self) -> list[pathlib.Path]:
        """Own folders and everything linked, each folder once."""
        folders: list[pathlib.Path] = []
        for path in [*self.own, *source_folders(self.project)]:
            path = path.resolve()
            if any(path == f or path.is_relative_to(f) for f in folders):
                continue
            folders = [f for f in folders if not f.is_relative_to(path)]
            folders.append(path)
        return folders

    def catalogs(self) -> list[pathlib.Path]:
        """The app's catalog and — if it links `WordingKit` — the shared one.

        **Both belong to the program** (AP58 R0): What stands on the device comes from
        two catalogs since 26.09.2026. A guard that read only the app's would let through
        every sentence that has moved to `WordingKit` — the shared ones, of all things.
        """
        shared = wording_catalog(self.project)
        return [self.catalog, *([shared] if shared else [])]

    def entries(self) -> dict:
        """All entries from ``catalogs`` — a key lives in only one of them."""
        merged: dict = {}
        for catalog in self.catalogs():
            merged.update(json.loads(catalog.read_text(encoding="utf-8"))["strings"])
        return merged

    def swift_files(self) -> list[pathlib.Path]:
        """All `*.swift` of the program without tests and build debris.

        `Tests` is filtered relative to the source folder, as in ``linkage`` —
        otherwise a working-copy path containing that word would exclude everything.
        """
        result = []
        for base in self.source_folders():
            for path in swift_files([base]):
                if "Tests" in path.relative_to(base).parts:
                    continue
                result.append(path)
        return sorted(set(result))


PROGRAMS = {
    "tv": Program(
        name="tv",
        project=ROOT / "project.yml",
        catalog=ROOT / "App/Resources/Localizable.xcstrings",
        own=(ROOT / "App", ROOT / "Packages"),
    ),
    "phone": Program(
        name="phone",
        project=ROOT / "Phone/project.yml",
        catalog=ROOT / "Phone/App/Resources/Localizable.xcstrings",
        own=(ROOT / "Phone/App", ROOT / "Phone/Packages"),
    ),
}


def arguments(description: str, check: bool = False) -> argparse.Namespace:
    """`--app tv|handy` is required: A silent default would check the wrong thing."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--app", required=True, choices=sorted(PROGRAMS))
    if check:
        parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def display(path: pathlib.Path) -> str:
    """Relative to the repo root, `grundstock` starting at the package name."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        parts = path.parts
        if "Sources" in parts:
            return str(pathlib.Path(*parts[parts.index("Sources") - 1:]))
        return str(path)


# A string in key shape — the same as in `strings.py`.
SHAPE = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+(?: %[a-z]+)?)"')
# A prefix that something is appended to at runtime: `"error." + code`, `"state.\(fall)"`.
PREFIX = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*\.)(?:"\s*\+|\\\()')


def shared_files() -> list[pathlib.Path]:
    """Sources that end up in BOTH app targets — the shared packages and grundstock."""
    tv = set(swift_files(source_folders(PROGRAMS["tv"].project)))
    phone = set(swift_files(source_folders(PROGRAMS["phone"].project)))
    return sorted(tv & phone)


def shared_keys(catalog: dict) -> dict[str, set[str]]:
    """Catalog keys that shared code looks up → the files that do so.

    On top of that **every key from `WordingKit`**: The catalog is shared, even if a
    sentence from it is read only through one view and appears nowhere in shared code.

    Literal (also with a format spec: the source only has the stem) and assembled at
    runtime: `PortalKit` builds `"error." + code` from the server's response code, and
    that is exactly how "Dieser Fernseher braucht ein Profil." reached the phone. A
    prefix therefore counts every key beneath it — the cautious direction: better to
    demand one sentence too many as device-neutral than to overlook one.
    """
    stems: dict[str, list[str]] = {}
    for key in catalog:
        stems.setdefault(key.split(" ")[0], []).append(key)

    found: dict[str, set[str]] = {}
    if WORDING_CATALOG.exists():
        for key in json.loads(WORDING_CATALOG.read_text(encoding="utf-8"))["strings"]:
            if key in catalog:
                found.setdefault(key, set()).add("Packages/WordingKit")
    for path in shared_files():
        text = path.read_text(errors="replace")
        place = display(path)
        for match in SHAPE.finditer(text):
            for key in stems.get(match.group(1).split(" ")[0], []):
                found.setdefault(key, set()).add(place)
        for match in PREFIX.finditer(text):
            prefix = match.group(1)
            for key in catalog:
                if key.startswith(prefix):
                    found.setdefault(key, set()).add(place)
    return found


def justified(lines: list[str], number: int, marker: re.Pattern) -> bool:
    """Does the line itself or one of the six above it carry the marker?

    Six and not three: A justification that really names the reason is rarely a single
    line — and a guard that forces a terse justification gets terse justifications.
    """
    return any(marker.search(lines[i]) for i in range(max(0, number - 6), number + 1))
