"""Installing a portal — and the way back.

**The checksum decides, not the address.** What comes off the network is
fetched in full first, then held against the `sha256` from the index, and only
then unpacked. An archive that was swapped in transit never reaches the disk —
and the check costs nothing the download does not cost anyway.

**The way back is not a convenience but the condition.** A new version that
breaks something has to be revocable without anybody hunting for the old state
somewhere. So the previous folder is moved aside instead of deleted, and the
new version is hung in only once it lies there complete.

**Auto-update is off**, and there is nothing here that turns it on. A service
that pulls in foreign code while nobody is watching is a different thing from
one somebody watches install. Whoever wants to update installs the new version
— same path, same check.

**What an archive may be.** A `tar.gz` with exactly one directory, holding a
`portal.yml`. No absolute paths, no `..`, no links — the check lives in
`_sicher_entpacken()` and is the reason this module does not call
`extractall()`.
"""

from __future__ import annotations

import hashlib
import shutil
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

import requests

from cinelounge.core import errors as f

#: How long an archive is waited for.
#:
#: Longer than for the index: here somebody deliberately downloads something
#: and watches it happen. An index is fetched in passing, a portal is not.
TIMEOUT_S: Final = 60.0

#: How large a portal archive may be at most.
#:
#: A portal is Python and a manifest. Fifty megabytes are ample for everything
#: that belongs in one, and little enough that a mishap shows up before the
#: disk is full.
MAX_BYTES: Final = 50 * 1024 * 1024

#: How much is read at a time.
CHUNK: Final = 64 * 1024


@dataclass(frozen=True, slots=True)
class Installed:
    portal_id: str
    version: str
    sha256: str
    folder: Path
    replaced: bool
    """Whether a previous version was set aside — then there is a way back."""


def fetch_archive(url: str, expected_sha256: str) -> bytes:
    """Fetch an archive and hold it against its checksum.

    **Complete first, then check, then unpack.** Whoever unpacks while reading
    has half of it on disk before knowing whether it is the right half.
    """
    erwartet = expected_sha256.strip().lower()
    try:
        antwort = requests.get(url, timeout=TIMEOUT_S, stream=True)
        antwort.raise_for_status()

        stuecke: list[bytes] = []
        gelesen = 0
        for block in antwort.iter_content(CHUNK):
            gelesen += len(block)
            if gelesen > MAX_BYTES:
                raise ValueError(f"archive larger than {MAX_BYTES} bytes")
            stuecke.append(block)
    except f.Error:
        raise
    except Exception as err:  # the reason belongs in the answer
        raise f.Error(
            "market.fetch_failed",
            {"url": url[:80], "why": type(err).__name__ + ": " + str(err)[:100]},
            status=502,
        ) from None

    roh = b"".join(stuecke)
    gefunden = hashlib.sha256(roh).hexdigest()
    if gefunden != erwartet:
        # **The reason names both sums.** "Checksum does not match" on its own
        # leads straight to the question which one was meant — and whoever has
        # to answer it downloads the file a second time by hand.
        raise f.Error(
            "market.checksum",
            {"expected": erwartet, "found": gefunden, "bytes": len(roh)},
            status=409,
        )
    return roh


def install(
    archive: bytes,
    portal_id: str,
    version: str,
    sha256: str,
    portals_dir: Path,
) -> Installed:
    """Install a checked archive. The previous folder moves aside.

    **Complete beside it first, then swap.** A folder that was half
    overwritten is worse than one that is missing: the loader finds it, reads
    its manifest and reports a portal that never existed that way.
    """
    if not portal_id.replace("-", "").replace("_", "").isalnum():
        raise f.Error("market.bad_id", {"id": portal_id[:40]}, status=422)

    ziel = portals_dir / portal_id
    portals_dir.mkdir(parents=True, exist_ok=True)

    neu = portals_dir / f".{portal_id}.neu"
    shutil.rmtree(neu, ignore_errors=True)
    neu.mkdir(parents=True)

    try:
        _sicher_entpacken(archive, neu)
        wurzel = _eine_wurzel(neu)
        if not (wurzel / "portal.yml").is_file():
            raise f.Error("market.no_manifest", {"id": portal_id}, status=422)
    except Exception:
        shutil.rmtree(neu, ignore_errors=True)
        raise

    # The way back: keep the previous version, do not delete it.
    beiseite = portals_dir / f".{portal_id}.vorige"
    ersetzt = ziel.exists()
    if ersetzt:
        shutil.rmtree(beiseite, ignore_errors=True)
        ziel.rename(beiseite)

    try:
        wurzel.rename(ziel)
    except OSError:
        # If the swap went wrong, the previous version comes straight back —
        # a household without the portal is worse than one with the old one.
        if ersetzt and not ziel.exists():
            beiseite.rename(ziel)
        shutil.rmtree(neu, ignore_errors=True)
        raise
    shutil.rmtree(neu, ignore_errors=True)

    (ziel / ".market.json").write_text(_herkunft(portal_id, version, sha256), encoding="utf-8")
    return Installed(portal_id, version, sha256, ziel, ersetzt)


def rollback(portal_id: str, portals_dir: Path) -> bool:
    """Bring the previous version back. Returns `False` if there is none.

    **Exactly one step back, and that is deliberate.** A stack of old versions
    would be an archive nobody maintains; what lies here is the answer to "the
    new one breaks something" and not to "how was it half a year ago".
    """
    beiseite = portals_dir / f".{portal_id}.vorige"
    if not beiseite.is_dir():
        return False

    ziel = portals_dir / portal_id
    kaputt = portals_dir / f".{portal_id}.verworfen"
    shutil.rmtree(kaputt, ignore_errors=True)
    if ziel.exists():
        ziel.rename(kaputt)
    beiseite.rename(ziel)
    shutil.rmtree(kaputt, ignore_errors=True)
    return True


def origin(portal_id: str, portals_dir: Path) -> dict[str, Any]:
    """Where a portal came from — empty if it was put there by hand."""
    datei = portals_dir / portal_id / ".market.json"
    if not datei.is_file():
        return {}
    import json

    try:
        wert = json.loads(datei.read_text(encoding="utf-8"))
        return wert if isinstance(wert, dict) else {}
    except (OSError, ValueError):
        return {}


def _herkunft(portal_id: str, version: str, sha256: str) -> str:
    import json

    return json.dumps(
        {"id": portal_id, "version": version, "sha256": sha256, "installed": time.time()},
        ensure_ascii=False,
        indent=2,
    )


def _sicher_entpacken(archive: bytes, ziel: Path) -> None:
    """Unpack without `extractall()`.

    **An archive is foreign content, and `extractall()` believes it.** An entry
    called `../../etc/cron.d/x` writes where it points; a symbolic link does the
    same at the first access afterwards. Both have been known for years and
    still stand in every second example.

    So here: every entry on its own, every path held against the target, and
    only ordinary files and directories.
    """
    ziel = ziel.resolve()
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        tmp.write(archive)
        tmp_pfad = Path(tmp.name)

    try:
        with tarfile.open(tmp_pfad, "r:gz") as tar:
            for eintrag in tar:
                if eintrag.issym() or eintrag.islnk():
                    raise f.Error("market.unsafe_archive", {"name": eintrag.name[:80]}, status=422)
                if not (eintrag.isfile() or eintrag.isdir()):
                    raise f.Error("market.unsafe_archive", {"name": eintrag.name[:80]}, status=422)

                wohin = (ziel / eintrag.name).resolve()
                if wohin != ziel and ziel not in wohin.parents:
                    raise f.Error("market.unsafe_archive", {"name": eintrag.name[:80]}, status=422)

                tar.extract(eintrag, ziel, filter="data")
    except tarfile.TarError as err:
        raise f.Error("market.bad_archive", {"why": str(err)[:100]}, status=422) from None
    finally:
        tmp_pfad.unlink(missing_ok=True)


def _eine_wurzel(ordner: Path) -> Path:
    """The one directory in the archive — or the folder itself.

    Both occur: `tar czf x.tar.gz zdf/` packs a directory, `tar czf x.tar.gz -C
    zdf .` packs its contents. Whoever assumes only the one rejects half of all
    archives that are otherwise fine.
    """
    eintraege = [p for p in ordner.iterdir() if not p.name.startswith(".")]
    if len(eintraege) == 1 and eintraege[0].is_dir():
        return eintraege[0]
    return ordner
