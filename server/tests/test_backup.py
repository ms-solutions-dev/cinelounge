"""A backup that really backs up.

**The occasion.** In the design the button has existed from the start, and
there it reports "backup created · 81 catalogue entries, 3 people, 3 devices".
None of that ever happened: the text stands in `entwuerfe/entwurf.js`, a
backend never existed. A button that fakes success is worse than no button —
whoever believes it restores nothing when it matters and only then notices
that there is nothing.

So this file does not check that an export *runs*, but that after restoring
**the same thing stands there**: the same people, the same permissions, the
same devices, the same progress — and the same secrets, because a backup after
which everybody has to pair again does not get used when it matters.
"""

from __future__ import annotations

import pytest

from cinelounge.core import errors as f
from cinelounge.household import backup
from cinelounge.household.devices import Devices
from cinelounge.household.people import People
from cinelounge.household.progress import Progress
from cinelounge.household.store import Store
from cinelounge.household.visibility import Visibility


def _haushalt(pfad):
    """A household with everything a backup has to carry."""
    store = Store(pfad)
    leute, geraete = People(store), Devices(store)
    sicht, stand = Visibility(store), Progress(store)

    leute.create("Max", "admin", "1234")
    leute.create("Sina", "adult", "1234")

    warte = geraete.request_code("Apple TV", "tv", "192.0.2.40")
    merkmal = geraete.redeem(warte.token, name="Apple TV", kind="tv")

    sicht.set_allowed("sina", "zinne", True)
    store.set_portal_setting("kiefer", "api.key", "geheim")
    stand.report(
        "max", "zinne|ein-ganz-grosses-ding", title="Ein ganz großes Ding", position_s=612.0
    )

    return store, merkmal


@pytest.fixture
def haushalt(tmp_path):
    return _haushalt(tmp_path / "h.sqlite")


def test_eine_sicherung_nennt_was_sie_traegt(haushalt):
    """`summary` is not for `restore()` but for the person holding the file
    who wants to know whether it is the right one."""
    store, _ = haushalt
    d = backup.export(store)

    assert d["version"] == backup.VERSION
    assert d["summary"]["person"] == 2
    assert d["summary"]["device"] == 1
    # Since 09.11.2026 a permission lives on the role (`role_portal`).
    assert d["summary"]["role_portal"] >= 1
    assert d["summary"]["progress"] == 1


def test_der_rundlauf_stellt_denselben_haushalt_wieder_her(tmp_path):
    """**The yardstick.** Not "the export runs" but "afterwards the same thing
    stands there"."""
    quelle, merkmal = _haushalt(tmp_path / "a.sqlite")
    d = backup.export(quelle)

    ziel = Store(tmp_path / "b.sqlite")
    backup.restore(ziel, d)

    leute = People(ziel)
    assert sorted(p.id for p in leute.list_all()) == ["max", "sina"]
    assert leute.by_id("max").role == "admin"

    # **The PIN has to come along.** Otherwise after restoring a household
    # stands there nobody can get into.
    assert leute.sign_in("max", "1234").id == "max"

    # The same for the device token: the television in the living room should
    # keep running after a restore and not have to be paired again.
    assert Devices(ziel).by_token(merkmal) is not None

    assert Visibility(ziel).allowed_for("sina") == {"zinne"}
    assert ziel.portal_settings("kiefer") == {"api.key": "geheim"}

    e = Progress(ziel).by_id("max", "zinne|ein-ganz-grosses-ding")
    assert e is not None and e["position_s"] == 612.0


def test_zurueckspielen_raeumt_vorher_ab(tmp_path):
    """A backup establishes a state, it does not mix itself in.

    Two households on top of each other produce permissions nobody ever
    granted — and a person long removed stands there again.
    """
    quelle, _ = _haushalt(tmp_path / "a.sqlite")
    d = backup.export(quelle)

    ziel = Store(tmp_path / "b.sqlite")
    People(ziel).create("Eli", "child", "1111")
    backup.restore(ziel, d)

    assert sorted(p.id for p in People(ziel).list_all()) == ["max", "sina"]


def test_dazuspielen_laesst_den_bestand_stehen(tmp_path):
    """The cross-check — `replace=False` is the way to mix two households.

    It is not the default, but it exists: whoever wants to bring a single
    person back out of an old backup should not have to overwrite everything.
    """
    quelle, _ = _haushalt(tmp_path / "a.sqlite")
    d = backup.export(quelle)

    ziel = Store(tmp_path / "b.sqlite")
    People(ziel).create("Eli", "child", "1111")
    backup.restore(ziel, d, replace=False)

    assert sorted(p.id for p in People(ziel).list_all()) == ["eli", "max", "sina"]


def test_kopplungscodes_gehen_nicht_mit(haushalt):
    """`pending` stays out.

    A pairing code lives 300 seconds. Whatever of it survives a backup is
    always expired — and an expired code standing in the list again after a
    restore looks like an open one.
    """
    store, _ = haushalt
    Devices(store).request_code("Wartet noch", "tv", "")

    d = backup.export(store)

    assert "pending" not in d["tables"]
    assert "pending" not in d["summary"]


def test_eine_fremde_fassung_wird_abgelehnt(haushalt):
    """The same rule as with the manifest: what the server does not understand
    it does not restore. A schema rebuild has hit this project twice already.
    """
    store, _ = haushalt
    d = backup.export(store)
    d["version"] = 99

    with pytest.raises(f.Error) as err:
        backup.restore(store, d)
    assert err.value.code == "backup.version"
    assert err.value.values["found"] == 99


def test_eine_datei_die_keine_sicherung_ist_wird_abgelehnt(haushalt):
    store, _ = haushalt
    with pytest.raises(f.Error) as err:
        backup.restore(store, {"version": backup.VERSION, "tables": "nichts"})
    assert err.value.code == "backup.malformed"


def test_unbekannte_spalten_brechen_nicht_ab(tmp_path):
    """A backup from a newer version may land here.

    As long as the version number fits, this server leaves what it does not
    know — instead of aborting on a `no such column` and restoring nothing at
    all.
    """
    quelle, _ = _haushalt(tmp_path / "a.sqlite")
    d = backup.export(quelle)
    for z in d["tables"]["person"]:
        z["lieblingsfarbe"] = "blau"

    ziel = Store(tmp_path / "b.sqlite")
    geschrieben = backup.restore(ziel, d)

    assert geschrieben["person"] == 2
    assert sorted(p.id for p in People(ziel).list_all()) == ["max", "sina"]


def test_ein_halber_durchgang_schreibt_nichts(tmp_path):
    """Everything in one transaction — if it breaks in the middle, nothing is written.

    A half-restored household would be worse than the broken one before: it
    looks intact.
    """
    quelle, _ = _haushalt(tmp_path / "a.sqlite")
    d = backup.export(quelle)
    # `progress` comes after `person` — by then writing has already happened.
    d["tables"]["progress"] = "kaputt"

    ziel = Store(tmp_path / "b.sqlite")
    People(ziel).create("Eli", "child", "1111")

    with pytest.raises(f.Error):
        backup.restore(ziel, d)

    assert [p.id for p in People(ziel).list_all()] == ["eli"], (
        "der Haushalt von vorher muss unveraendert dastehen"
    )
