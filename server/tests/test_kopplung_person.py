"""The reserved person survives the redemption.

**The silent fault this file exists for.** The devices view shows a row of
people at every waiting pairing. Pressing one reported "type in the code FGBNEJ
for Max" — and did nothing else.

On the server stood::

    owner = z["person_id"] if z["kind"] == "invite" else user_id

So with a pairing only the explicit `user_id` counted, and
`web/auth.py:redeem()` never passes one. The column `person_id` in `pending`
stayed unused for pairings.

**Every device paired that way arrived as a shared one**, no matter which
button somebody had pressed. The admin then had to assign it again in the
device list; whoever did not know that had a television without a person and a
button that had lied.

None of it was visible: the code was redeemed, the device appeared, the pairing
"worked".
"""

from __future__ import annotations

import pytest

from cinelounge.core import errors as f


class _Leute:
    """Two people, reachable by name.

    `People` only knows `by_id()`; here the search goes by name, because a test
    that says `sina` reads better than one that says `p2`.
    """

    def __init__(self, people):
        self._people = people

    def __getattr__(self, name):
        return getattr(self._people, name)

    def by_name(self, name: str):
        for p in self._people.list_all():
            if p.name == name:
                return p
        raise AssertionError(f"keine Person {name!r}")


@pytest.fixture()
def haus(tmp_path):
    """A household with two people."""
    from cinelounge.household.devices import Devices
    from cinelounge.household.people import People
    from cinelounge.household.store import Store

    store = Store(tmp_path / "haus.sqlite")
    leute = People(store)
    leute.create("Max", "admin", "1234", "#E2564A")
    leute.create("Sina", "adult", "1234", "#5C97EE")
    return Devices(store), _Leute(leute)


# ── What was wrong before ───────────────────────────────────────────────────


def test_die_vorgemerkte_person_kommt_beim_geraet_an(haus):
    """**The test this file exists for.**"""
    geraete, leute = haus
    wer = leute.by_name("Sina")
    assert wer

    code = geraete.request_code("Wohnzimmer", "tv", "192.0.2.20")
    assert geraete.note_person(code.token, wer.id)

    merkmal = geraete.redeem(code.token, name="Wohnzimmer", kind="tv")
    g = geraete.by_token(merkmal)
    assert g is not None
    assert g.user_id == wer.id, (
        "das Geraet kam als geteiltes an — die vorgemerkte Person ging verloren"
    )


def test_ohne_vormerken_bleibt_es_geteilt(haus):
    """`None` is an answer and not a missing one.

    The television in the living room belongs to nobody and asks for the
    profile at startup. Creating a device without a reservation that way is
    right.
    """
    geraete, _ = haus
    code = geraete.request_code("Wohnzimmer", "tv", "")
    g = geraete.by_token(geraete.redeem(code.token))
    assert g is not None
    assert g.user_id is None


def test_geteilt_laesst_sich_ausdruecklich_vormerken(haus):
    """Whoever presses "shared" reserves `None` — and that has to go through."""
    geraete, leute = haus
    code = geraete.request_code("Wohnzimmer", "tv", "")
    assert geraete.note_person(code.token, leute.by_name("Max").id)
    assert geraete.note_person(code.token, None)

    g = geraete.by_token(geraete.redeem(code.token))
    assert g is not None
    assert g.user_id is None, "the second choice did not overwrite the first"


def test_ein_ausdrueckliches_user_id_sticht_die_vormerkung(haus):
    """Whoever names somebody at redemption means them.

    Nobody takes that path today — `web/auth.py` passes no `user_id` — but the
    parameter is in the contract, and two sources need an order.
    """
    geraete, leute = haus
    code = geraete.request_code("Tablet", "web", "")
    geraete.note_person(code.token, leute.by_name("Sina").id)

    max = leute.by_name("Max")
    g = geraete.by_token(geraete.redeem(code.token, user_id=max.id))
    assert g is not None
    assert g.user_id == max.id


# ── What does not work ──────────────────────────────────────────────────────


def test_eine_unbekannte_person_wird_abgelehnt(haus):
    """Otherwise an id stands in the code that belongs to nobody."""
    geraete, _ = haus
    code = geraete.request_code("Tablet", "web", "")
    with pytest.raises(f.Error) as gefangen:
        geraete.note_person(code.token, "gibtsnicht")
    assert gefangen.value.code == "household.unknown_person"


def test_ein_abgelaufener_code_nimmt_nichts_mehr_an(haus, tmp_path):
    geraete, leute = haus
    code = geraete.request_code("Tablet", "web", "")
    with geraete.store.connect() as v:
        v.execute("UPDATE pending SET valid_until = 1 WHERE token = ?", (code.token,))
    assert geraete.note_person(code.token, leute.by_name("Max").id) is False


def test_ein_eingeloester_code_nimmt_nichts_mehr_an(haus):
    """Afterwards there is a device, and the device list is responsible for that."""
    geraete, leute = haus
    code = geraete.request_code("Tablet", "web", "")
    geraete.redeem(code.token)
    assert geraete.note_person(code.token, leute.by_name("Max").id) is False


def test_eine_einladung_laesst_sich_nicht_umwidmen(haus):
    """With an invitation the recipient is settled.

    Changing them here would be a second way to the same thing — and the
    quieter of the two: the link is already on its way.
    """
    geraete, leute = haus
    sina = leute.by_name("Sina")
    einladung = geraete.invite(sina.id, hours=1)

    assert geraete.note_person(einladung.token, leute.by_name("Max").id) is False

    g = geraete.by_token(geraete.redeem(einladung.token))
    assert g is not None
    assert g.user_id == sina.id, "the invitation went to somebody else"


def test_ein_erfundener_code_aendert_nichts(haus):
    geraete, leute = haus
    assert geraete.note_person("GIBTSNICHT", leute.by_name("Max").id) is False
