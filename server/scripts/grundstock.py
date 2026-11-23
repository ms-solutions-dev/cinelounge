#!/usr/bin/env python3
"""Bring the bundled portals into the data directory.

**This gap swallowed a week of work.** The service reads its portals from
`/data/portals`; `portals/` in the source tree is transferred by `deploy.sh`
but read by nobody. Between the two there was no path.

Noticed 11.09.2026: the ZDF version over there was 284 lines, the one in the
repo 324. The separator fix from R1, the subtitles, the English key sentence —
all checked in, all deployed, and none of it ran. The service answered with the
version from moving day the whole time.

## What it does not do

**It touches nothing that came from the marketplace.** A portal with a
`.market.json` beside it was installed deliberately by somebody, possibly in a
newer version than the bundled one. Overwriting it would be a silent rollback —
exactly what `market/install.py` with its way back is meant to prevent.

**It deletes nothing.** A portal that only lies over there stays. What is not
here may have been put there by hand.

**And it writes only with `--write`.** Without the word it says what it would
do.

## The way back

Before overwriting, the old version moves to `.<id>.vorige` — the same place
`market/rollback()` reads. A seed that breaks a portal is thereby one click in
the console and not a search through the backup.

    python scripts/grundstock.py                       # only shows
    python scripts/grundstock.py --write               # installs
    python scripts/grundstock.py /data/portals --write  # other target

Returns `0` when there was nothing to do, `10` when something was installed,
`2` on an error. The `10` is for `deploy.sh`: the running service only reads a
newly installed portal after a restart.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cinelounge.portalworks import seed

# **One truth, two callers.** What "bundled", "same" and "from the marketplace"
# mean stands in `portalworks/seed.py` — the service needs it at first start,
# this script in operation. Two copies would be two opinions about what is
# already there.
QUELLE = seed.BUNDLED
IGNORIEREN = seed.IGNORE
NUR_VORLAGE = seed.TEMPLATE_ONLY
_gleich = seed.same


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--write"]
    schreibt = "--write" in sys.argv
    ziel = Path(args[0]) if args else Path("/data/portals")

    if not QUELLE.is_dir():
        print(f"source missing: {QUELLE}", file=sys.stderr)
        return 2

    ziel.mkdir(parents=True, exist_ok=True)
    getan = 0

    for ordner in sorted(QUELLE.iterdir()):
        if not ordner.is_dir() or not (ordner / "portal.yml").is_file():
            continue
        if ordner.name in NUR_VORLAGE:
            print(f"  {ordner.name:16} template — stays home")
            continue

        drueben = ziel / ordner.name

        herkunft = drueben / ".market.json"
        if herkunft.is_file():
            # **From the marketplace.** Do not touch: the version there may be
            # newer than the bundled one, and a silent rollback is the last
            # thing a seed may do.
            print(f"  {ordner.name:16} from the marketplace — untouched")
            continue

        if _gleich(ordner, drueben):
            print(f"  {ordner.name:16} same")
            continue

        was = "new" if not drueben.exists() else "differs"
        if not schreibt:
            print(f"  {ordner.name:16} {was} — WOULD install")
            getan += 1
            continue

        if drueben.exists():
            # The same place `market.rollback()` reads: a seed that breaks
            # something is thereby one click in the console.
            beiseite = ziel / f".{ordner.name}.vorige"
            shutil.rmtree(beiseite, ignore_errors=True)
            drueben.rename(beiseite)

        shutil.copytree(ordner, drueben, ignore=IGNORIEREN)
        print(f"  {ordner.name:16} {was} — installed")
        getan += 1

    if not getan:
        print("Nothing to do.")
    elif not schreibt:
        print(f"\n{getan} portal(s) would have been installed. Add --write to do it.")
    else:
        print(f"\n{getan} portal(s) installed.")
        # **Return 10 means: something changed.** The catalogue is read at
        # startup; a portal that arrives afterwards does not exist for the
        # running service. `deploy.sh` restarts on it — otherwise the seed
        # reports "installed" and the service keeps answering with the old
        # state, which is exactly the kind of lie this script exists to end.
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
