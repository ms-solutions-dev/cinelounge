"""Installing a portal — and above all what must not happen while doing it.

**An archive is foreign content.** It comes from an address somebody entered,
and it gets unpacked onto the household's disk. What goes wrong here goes wrong
outside the portal folder — which is why most tests in this file do not check
whether something arrives, but whether it does **not** arrive.
"""

from __future__ import annotations

import hashlib
import io
import tarfile
import time

import pytest

from cinelounge.core import errors as f
from cinelounge.market import install as inst


def _archiv(dateien: dict[str, str], wurzel: str = "zinne") -> bytes:
    """Build a `tar.gz` as a source would deliver it."""
    puffer = io.BytesIO()
    with tarfile.open(fileobj=puffer, mode="w:gz") as tar:
        for name, inhalt in dateien.items():
            roh = inhalt.encode()
            info = tarfile.TarInfo((wurzel + "/" + name) if wurzel else name)
            info.size = len(roh)
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(roh))
    return puffer.getvalue()


def _sha(roh: bytes) -> str:
    return hashlib.sha256(roh).hexdigest()


MANIFEST = "api: 1\nid: zinne\nname: Zinne\nkind: native\n"


# ── Installing ──────────────────────────────────────────────────────────────


def test_ein_archiv_wird_zu_einem_portalordner(tmp_path):
    """The cross-check — otherwise the rest only checks that everything aborts."""
    roh = _archiv({"portal.yml": MANIFEST, "portal.py": "class Portal: pass\n"})

    fertig = inst.install(roh, "zinne", "1.0.0", _sha(roh), tmp_path)

    assert fertig.folder == tmp_path / "zinne"
    assert (fertig.folder / "portal.yml").read_text(encoding="utf-8") == MANIFEST
    assert not fertig.replaced, "there was no previous version"


def test_die_herkunft_liegt_daneben(tmp_path):
    """So that the detail page can say where the portal came from."""
    roh = _archiv({"portal.yml": MANIFEST})
    inst.install(roh, "zinne", "1.2.3", _sha(roh), tmp_path)

    h = inst.origin("zinne", tmp_path)
    assert h["version"] == "1.2.3"
    assert h["sha256"] == _sha(roh)


def test_ein_portal_von_hand_hat_keine_herkunft(tmp_path):
    (tmp_path / "eigen").mkdir()
    assert inst.origin("eigen", tmp_path) == {}


def test_auch_ein_archiv_ohne_eigenes_verzeichnis(tmp_path):
    """`tar czf x.tar.gz -C zinne .` packs the contents, not the folder.

    Whoever assumes only the one rejects half of all archives that are
    otherwise fine.
    """
    roh = _archiv({"portal.yml": MANIFEST}, wurzel="")
    fertig = inst.install(roh, "zinne", "1.0.0", _sha(roh), tmp_path)

    assert (fertig.folder / "portal.yml").is_file()


def test_ohne_manifest_wird_nichts_eingerichtet(tmp_path):
    """A folder without `portal.yml` is no portal — and the loader would still
    find it and report `broken`."""
    roh = _archiv({"liesmich.txt": "hallo"})

    with pytest.raises(f.Error) as err:
        inst.install(roh, "zinne", "1.0.0", _sha(roh), tmp_path)
    assert err.value.code == "market.no_manifest"
    assert not (tmp_path / "zinne").exists(), "and nothing lingers"


# ── What must not happen ────────────────────────────────────────────────────


def test_ein_eintrag_der_aus_dem_ordner_zeigt(tmp_path):
    """**`extractall()` believes the archive.** An entry `../../x` writes where
    it points."""
    puffer = io.BytesIO()
    with tarfile.open(fileobj=puffer, mode="w:gz") as tar:
        roh = b"pwned"
        info = tarfile.TarInfo("../../entwischt.txt")
        info.size = len(roh)
        tar.addfile(info, io.BytesIO(roh))
    archiv = puffer.getvalue()

    with pytest.raises(f.Error) as err:
        inst.install(archiv, "zinne", "1.0.0", _sha(archiv), tmp_path)
    assert err.value.code in ("market.unsafe_archive", "market.bad_archive")
    assert not (tmp_path.parent / "entwischt.txt").exists()


def test_ein_symbolischer_verweis_wird_abgelehnt(tmp_path):
    """A link does not write itself — it lets the next access write, and that
    one is no longer an archive."""
    puffer = io.BytesIO()
    with tarfile.open(fileobj=puffer, mode="w:gz") as tar:
        info = tarfile.TarInfo("zinne/portal.yml")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        tar.addfile(info)
    archiv = puffer.getvalue()

    with pytest.raises(f.Error) as err:
        inst.install(archiv, "zinne", "1.0.0", _sha(archiv), tmp_path)
    assert err.value.code == "market.unsafe_archive"


def test_eine_kennung_mit_pfad_wird_abgelehnt(tmp_path):
    """The id becomes the folder name. `index.py` already checks that — it
    stands here once more because this module can be called without an index
    too."""
    roh = _archiv({"portal.yml": MANIFEST})
    with pytest.raises(f.Error) as err:
        inst.install(roh, "../entwischt", "1.0.0", _sha(roh), tmp_path)
    assert err.value.code == "market.bad_id"


def test_ein_kaputtes_archiv_laesst_nichts_halbes_zurueck(tmp_path):
    with pytest.raises(f.Error) as err:
        inst.install(b"kein tar", "zinne", "1.0.0", _sha(b"kein tar"), tmp_path)
    assert err.value.code == "market.bad_archive"
    assert list(tmp_path.iterdir()) == []


# ── The way back ────────────────────────────────────────────────────────────


def test_die_vorige_fassung_bleibt_und_kommt_zurueck(tmp_path):
    """**The way back is the condition, not the convenience.**

    A new version that breaks something has to be revocable without anybody
    hunting for the old state somewhere.
    """
    alt = _archiv({"portal.yml": MANIFEST, "kennzeichen.txt": "alt"})
    inst.install(alt, "zinne", "1.0.0", _sha(alt), tmp_path)

    neu = _archiv({"portal.yml": MANIFEST, "kennzeichen.txt": "neu"})
    fertig = inst.install(neu, "zinne", "2.0.0", _sha(neu), tmp_path)

    assert fertig.replaced
    assert (tmp_path / "zinne" / "kennzeichen.txt").read_text(encoding="utf-8") == "neu"

    assert inst.rollback("zinne", tmp_path)
    assert (tmp_path / "zinne" / "kennzeichen.txt").read_text(encoding="utf-8") == "alt"
    assert inst.origin("zinne", tmp_path)["version"] == "1.0.0"


def test_ohne_vorige_fassung_gibt_es_keinen_rueckweg(tmp_path):
    roh = _archiv({"portal.yml": MANIFEST})
    inst.install(roh, "zinne", "1.0.0", _sha(roh), tmp_path)

    assert inst.rollback("zinne", tmp_path) is False
    assert (tmp_path / "zinne" / "portal.yml").is_file(), "and the portal stays"


def test_genau_eine_stufe_zurueck(tmp_path):
    """A stack of old versions would be an archive nobody maintains.

    What lies here is the answer to "the new one breaks something" and not to
    "how was it half a year ago".
    """
    for n, kennzeichen in ((1, "eins"), (2, "zwei"), (3, "drei")):
        roh = _archiv({"portal.yml": MANIFEST, "k.txt": kennzeichen})
        inst.install(roh, "zinne", f"{n}.0.0", _sha(roh), tmp_path)

    assert inst.rollback("zinne", tmp_path)
    assert (tmp_path / "zinne" / "k.txt").read_text(encoding="utf-8") == "zwei"
    assert inst.rollback("zinne", tmp_path) is False, "there is no further back"


# ── Checksum ────────────────────────────────────────────────────────────────


def test_eine_falsche_pruefsumme_haelt_alles_auf(monkeypatch):
    """**The checksum decides, not the address.**

    What was swapped in transit never reaches the disk — and the check costs
    nothing the download does not cost anyway.
    """
    roh = _archiv({"portal.yml": MANIFEST})

    class Antwort:
        @staticmethod
        def raise_for_status():
            return None

        @staticmethod
        def iter_content(n):
            yield roh

    monkeypatch.setattr(inst.requests, "get", lambda *a, **k: Antwort())

    with pytest.raises(f.Error) as err:
        inst.fetch_archive("https://example.test/zinne.tar.gz", "b" * 64)
    assert err.value.code == "market.checksum"
    # The reason names both sums — "does not match" alone leads to the
    # question which one was meant.
    assert err.value.values["found"] == _sha(roh)
    assert err.value.values["expected"] == "b" * 64


def test_die_richtige_pruefsumme_geht_durch(monkeypatch):
    roh = _archiv({"portal.yml": MANIFEST})

    class Antwort:
        @staticmethod
        def raise_for_status():
            return None

        @staticmethod
        def iter_content(n):
            yield roh

    monkeypatch.setattr(inst.requests, "get", lambda *a, **k: Antwort())
    assert inst.fetch_archive("https://example.test/zinne.tar.gz", _sha(roh)) == roh


def test_ein_zu_grosses_archiv_wird_abgebrochen(monkeypatch):
    """A portal is Python and a manifest. Whoever sends more is sending
    something else."""
    monkeypatch.setattr(inst, "MAX_BYTES", 1024)

    class Antwort:
        @staticmethod
        def raise_for_status():
            return None

        @staticmethod
        def iter_content(n):
            for _ in range(4):
                yield b"x" * 512

    monkeypatch.setattr(inst.requests, "get", lambda *a, **k: Antwort())

    with pytest.raises(f.Error) as err:
        inst.fetch_archive("https://example.test/gross.tar.gz", "a" * 64)
    assert err.value.code == "market.fetch_failed"
    assert "larger than" in err.value.values["why"]
