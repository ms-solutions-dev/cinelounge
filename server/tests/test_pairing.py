"""Pairing: what expires, what holds once, and what the television sees of it.

**Why this is a file of its own.** At the television nobody types a PIN — the
pairing code is the only way in. If it goes wrong, the viewer stands in front
of a screen that does not tell them what is going on, and the only answer that
helps them is "start over".

So these tests check not only that an expired code no longer works, but also
**with which code** the server says so: the app builds two different sentences
out of `pairing.expired` and `invite.used`.
"""

from __future__ import annotations

import time

import pytest

from cinelounge.core import errors as f
from cinelounge.household.devices import PAIRING_TTL_S, Devices
from cinelounge.household.store import Store


@pytest.fixture
def geraete(tmp_path):
    return Devices(Store(tmp_path / "h.sqlite"))


def test_ein_frischer_code_wird_eingeloest(geraete):
    """The cross-check first — otherwise the rest only checks that nothing works."""
    warte = geraete.request_code("Apple TV", "tv", "192.0.2.40")
    merkmal = geraete.redeem(warte.token, name="Apple TV", kind="tv")

    assert merkmal
    g = geraete.by_token(merkmal)
    assert g is not None and g.name == "Apple TV"
    assert g.shared, "without an assignment a television belongs to nobody"


def test_die_adresse_folgt_dem_geraet(geraete):
    """**The address in the list is the last one, not the first.**

    Until 12.09.2026 `from_where` was written at redeem time and never again.
    A phone that paired on Wi-Fi and now calls through the tunnel showed the
    Wi-Fi address for weeks — and two phones both called "iPhone" are told
    apart by nothing else in the console.
    """
    warte = geraete.request_code("iPhone", "ios", "192.0.2.41")
    merkmal = geraete.redeem(warte.token, name="iPhone", kind="ios")

    g = geraete.by_token(merkmal, "192.0.2.204")
    assert g is not None and g.from_where == "192.0.2.204"
    assert geraete.by_token(merkmal).from_where == "192.0.2.204", (
        "a call without a peer address keeps the last one instead of blanking it"
    )
    assert geraete.by_token(merkmal, "192.0.2.41").from_where == "192.0.2.41"


def test_umbenennen_trifft_nur_das_eine_geraet(geraete):
    a = geraete.redeem(geraete.request_code("iPhone", "ios", "").token, name="iPhone")
    b = geraete.redeem(geraete.request_code("iPhone", "ios", "").token, name="iPhone")
    ga, gb = geraete.by_token(a), geraete.by_token(b)
    assert ga is not None and gb is not None

    assert geraete.rename(ga.id, "Maxs iPhone")
    assert geraete.by_token(a).name == "Maxs iPhone"
    assert geraete.by_token(b).name == "iPhone", "the other phone keeps its name"
    assert not geraete.rename("gibt-es-nicht", "x"), "no row, no rename"


def test_ein_abgelaufener_code_geht_nicht_mehr(geraete):
    """`pairing.expired` — and the app says "request a new code".

    The clock is not moved, the code is made old: a test that replaces
    `time.time` afterwards also tests the replacement.
    """
    warte = geraete.request_code("Apple TV", "tv", "")
    with geraete.store.connect() as v:
        v.execute(
            "UPDATE pending SET valid_until = ? WHERE token = ?",
            (time.time() - 60, warte.token),
        )

    with pytest.raises(f.Error) as err:
        geraete.redeem(warte.token)
    assert err.value.code == f.PAIRING_EXPIRED


def test_derselbe_code_gilt_genau_einmal(geraete):
    """The second attempt is a different case from an expired code.

    It is called `invite.used`, and the app says something else for it: "this
    device is already paired" instead of "request a new code".
    """
    warte = geraete.request_code("Apple TV", "tv", "")
    geraete.redeem(warte.token)

    with pytest.raises(f.Error) as err:
        geraete.redeem(warte.token)
    assert err.value.code == f.INVITE_USED


def test_ein_unbekannter_code_sieht_aus_wie_ein_abgelaufener(geraete):
    """**Deliberate, not sloppy.**

    Whoever mistypes and whoever waited too long get the same answer — and for
    the viewer that is right, because they do the same thing both times. As a
    side effect the server does not reveal which codes currently exist.
    """
    with pytest.raises(f.Error) as err:
        geraete.redeem("ZZZZZZ")
    assert err.value.code == f.PAIRING_EXPIRED


def test_ein_zurueckgezogener_code_ist_weg(geraete):
    """The admin withdraws a pairing before somebody redeems it."""
    warte = geraete.request_code("Fremdes Geraet", "tv", "")
    assert geraete.revoke(warte.token)

    with pytest.raises(f.Error) as err:
        geraete.redeem(warte.token)
    assert err.value.code == f.PAIRING_EXPIRED


def test_verfallenes_wird_beim_naechsten_code_weggeraeumt(geraete):
    """**The finding of A7.**

    Cleaning up used to happen only in `pending()` — that is, exactly when
    somebody opens the console. Whoever has set up their household once does
    not do that for months, and every abandoned pairing attempt stayed as a row
    until then.

    It was never dangerous: `redeem()` checks `valid_until` and lets nothing
    dead through. It is the kind of residue that quietly piles up and travels
    along with the backup (A6).
    """
    alt = geraete.request_code("Altes Geraet", "tv", "")
    with geraete.store.connect() as v:
        # This is what a long-expired code looks like: `pending()` allows an
        # hour of grace so that one that just expired can still explain why
        # it no longer works.
        v.execute(
            "UPDATE pending SET valid_until = ? WHERE token = ?",
            (time.time() - 7200, alt.token),
        )

    geraete.request_code("Neues Geraet", "tv", "")

    with geraete.store.connect() as v:
        rest = v.execute("SELECT COUNT(*) c FROM pending WHERE token = ?", (alt.token,)).fetchone()
    assert rest["c"] == 0, "the expired code still lies in the table"


def test_ein_gerade_abgelaufener_code_bleibt_vorerst_liegen(geraete):
    """The cross-check for the hour of grace.

    Whoever types the code in two minutes late should get `pairing.expired` —
    and not `pairing.expired` because the row is already gone. The result would
    be the same, the way there chance.
    """
    alt = geraete.request_code("Eben abgelaufen", "tv", "")
    with geraete.store.connect() as v:
        v.execute(
            "UPDATE pending SET valid_until = ? WHERE token = ?",
            (time.time() - 60, alt.token),
        )

    geraete.request_code("Neues Geraet", "tv", "")

    with geraete.store.connect() as v:
        rest = v.execute("SELECT COUNT(*) c FROM pending WHERE token = ?", (alt.token,)).fetchone()
    assert rest["c"] == 1


def test_die_wartenden_zeigen_die_restzeit(geraete):
    """The console writes "expires in 4:12" — for that the number has to be
    right and keep moving."""
    warte = geraete.request_code("Apple TV", "tv", "")

    assert warte.remaining_s <= PAIRING_TTL_S
    assert warte.remaining_s > PAIRING_TTL_S - 5

    offen = geraete.pending()
    assert [o.token for o in offen] == [warte.token]
    assert offen[0].device_name == "Apple TV"
