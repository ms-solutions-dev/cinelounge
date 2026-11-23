"""The event book — and above all what is not in it.

**The line is the whole design.** Recorded are administrative acts: who
switched a portal, paired a device, changed a permission. **Not** recorded is
who watched what.

The plan asks exactly that question ("and then the question of how long
belongs with it"), and the honest answer is not to ask it in the first place:
a log of who started which film when is an instrument of power in a family. It
should not arise here by accident — which is why this file checks the line and
not only the function.
"""

from __future__ import annotations

import time

import pytest

from cinelounge.household.events import DEFAULT_DAYS, Events
from cinelounge.household.people import People
from cinelounge.household.store import Store


@pytest.fixture
def buch(tmp_path):
    store = Store(tmp_path / "h.sqlite")
    return Events(store), store


# ── What goes in ────────────────────────────────────────────────────────────


def test_ein_vorgang_steht_mit_code_und_werten_drin(buch):
    """Codes and values, no sentences — as with the errors.

    A log in a language the viewer does not read is no log.
    """
    e, _ = buch
    e.record("event.portal_switched", {"portal": "zinne", "on": True}, who="max")

    (z,) = e.recent()
    assert z["code"] == "event.portal_switched"
    assert z["values"] == {"portal": "zinne", "on": True}
    assert z["who"] == "max"
    assert z["at"] > time.time() - 5


def test_die_juengsten_zuerst(buch):
    e, _ = buch
    for i in range(3):
        e.record("event.service_started", {"n": i})

    assert [z["values"]["n"] for z in e.recent()] == [2, 1, 0]


def test_ein_eintrag_ohne_person_ist_erlaubt(buch):
    """A pairing code is redeemed by the device — nobody is signed in there."""
    e, _ = buch
    e.record("event.device_paired", {"name": "Apple TV"})

    assert e.recent()[0]["who"] == ""


def test_ein_unbekannter_name_haelt_den_eintrag_nicht_auf(buch):
    """**The finding from the first trial run.**

    With `REFERENCES person(id)` SQLite rejected every row whose person does
    not (any longer) exist — and because `record()` promises never to raise,
    the event vanished silently: two written, one arrived.

    A log is a by-product. It must never be the reason something that did
    happen is missing.
    """
    e, _ = buch
    e.record("event.portal_switched", {"portal": "zinne", "on": False}, who="gibtsnicht")

    assert e.count() == 1


# ── What does not go in ─────────────────────────────────────────────────────


def test_das_schema_hat_kein_feld_fuer_nutzungsverhalten(buch):
    """**The line stands in the schema, not in discipline.**

    A field for title or playback position would be an invitation: at some
    point somebody "just quickly" writes in who started what, and after that it
    is a log about people. What does not exist does not get used by accident.
    """
    _, store = buch
    with store.connect() as v:
        spalten = {z[1] for z in v.execute("PRAGMA table_info(event)")}

    assert spalten == {"id", "at", "code", "values_json", "person_id"}
    for verboten in ("title", "titel", "address", "adresse", "position_s", "portal_item"):
        assert verboten not in spalten


def test_keine_stelle_im_dienst_schreibt_eine_wiedergabe_ins_buch():
    """The cross-check in the source.

    What is checked is what `record()` is called with: every code begins with
    `event.` and stands in the list below. Whoever adds a new one enters it
    here — and stumbles over the question whether it belongs.
    """
    import re
    from pathlib import Path

    erlaubt = {
        "event.service_started",
        "event.portal_switched",
        "event.portal_removed",
        "event.portal_settings",
        "event.person_added",
        "event.person_removed",
        # A role changed afterwards (E7, 19.09.2026) is the same kind of act
        # as granting a portal: it decides what somebody in the house may see.
        "event.person_role_changed",
        # Roles as data and console access (09.11.2026): who sees what and who
        # manages — the same kind of decision as a role change.
        "event.console_granted",
        "event.console_revoked",
        "event.role_created",
        "event.role_changed",
        "event.role_deleted",
        "event.role_portal_changed",
        # Operations, not playback (09.11.2026): a route going dark or coming
        # back, Telegram being connected or disconnected.
        "event.exit_back",
        "event.role_child_locked",
        "event.role_child_unlocked",
        "event.exit_down",
        "event.telegram_connected",
        "event.telegram_disconnected",
        "event.access_changed",
        "event.device_paired",
        "event.device_assigned",
        "event.device_revoked",
        # A name is the household's word for a device (12.09.2026). The act
        # belongs in the book like an assignment does: both change what the
        # list of devices says about a row without touching its access.
        "event.device_renamed",
        "event.restored",
        # The marketplace (B6) — administrative acts as well: whoever enters
        # a source, stores an anchor or installs a portal decides for the whole
        # house.
        "event.source_added",
        "event.source_removed",
        "event.anchor_added",
        "event.anchor_removed",
        "event.portal_installed",
        "event.portal_rolled_back",
        # The nightly run (B10). **Two and not eleven per night:**
        # `portal_failing` only comes when a portal fails on the third night in
        # a row — a book with eleven lines every night is no book. `nights_run`
        # only stands there when somebody started it by hand; the run at four
        # o'clock does not write itself in.
        "event.portal_failing",
        "event.nights_run",
        # The first run (E6). **The first line of every house:** without it
        # the book begins with a service start and keeps quiet that there was
        # no household at all before.
        "event.household_created",
        # Network routes. Laying a portal onto a route, saving or removing a
        # proxy is a decision for the whole house — the same weight as
        # switching a portal on.
        "event.portal_net",
        "event.route_saved",
        "event.route_removed",
        # Der Beitritt (AP47). **Der Vorgang, der einen Menschen in den
        # Haushalt lässt, darf von „wer hat was freigegeben“ nicht die Ausnahme
        # sein.** `join_requested` trägt keine Person — es ist noch niemand.
        # Die Marke auszugeben und zu erneuern gehört dazu: Das eine reicht
        # einen Schlüssel heraus, das andere nimmt Geräten den Zugang.
        "event.join_requested",
        "event.join_approved",
        "event.join_declined",
        "event.device_enrolled",
        "event.mark_issued",
        "event.mark_renewed",
        # AP90 (16.11.2026): the manifest's default written down as the switch,
        # once per portal. Stored data changing is never silent.
        "event.switches_pinned",
    }

    wurzel = Path(__file__).resolve().parent.parent / "cinelounge"
    gefunden = set()
    for datei in wurzel.rglob("*.py"):
        gefunden |= set(re.findall(r'\.record\(\s*"([\w.]+)"', datei.read_text(encoding="utf-8")))

    fremd = sorted(gefunden - erlaubt)
    assert not fremd, (
        "neuer Ereignis-Code — gehoert er wirklich ins Buch? "
        "(Wiedergabe gehoert es nicht): " + ", ".join(fremd)
    )


def test_eine_entfernte_person_verliert_ihren_namen_im_buch(tmp_path):
    """The act stays, the name goes.

    What somebody did in the household belongs to the house's history; who it
    was belongs to the person — and they are gone.
    """
    store = Store(tmp_path / "h.sqlite")
    leute, e = People(store), Events(store)
    leute.create("Sina", "adult", "1234")
    e.record("event.portal_switched", {"portal": "zinne", "on": True}, who="sina")

    leute.remove("sina")

    (z,) = e.recent()
    assert z["code"] == "event.portal_switched", "the act stays"
    assert z["who"] == "", "the name goes"


# ── Retention ───────────────────────────────────────────────────────────────


def test_alte_eintraege_gehen_beim_schreiben_weg(buch):
    """Cleaning up happens on writing, not on looking.

    Whoever only cleans up on reading never cleans up in a household that runs
    for months — the same consideration as with the pairing codes.
    """
    e, store = buch
    e.record("event.service_started", {})
    with store.connect() as v:
        v.execute("UPDATE event SET at = ?", (time.time() - (DEFAULT_DAYS + 2) * 86400,))

    e.record("event.service_started", {})

    assert e.count() == 1, "the old entry still lies there"


def test_die_aufbewahrung_laesst_sich_einstellen(buch):
    e, store = buch
    store.write("log.tage", "1")
    e.record("event.service_started", {})
    with store.connect() as v:
        v.execute("UPDATE event SET at = ?", (time.time() - 2 * 86400,))

    e.record("event.service_started", {})

    assert e.count() == 1


def test_null_tage_heisst_nicht_nach_alter_loeschen(buch):
    e, store = buch
    store.write("log.tage", "0")
    e.record("event.service_started", {})
    with store.connect() as v:
        v.execute("UPDATE event SET at = ?", (time.time() - 3650 * 86400,))

    e.record("event.service_started", {})

    assert e.count() == 2


def test_ein_unlesbarer_wert_heisst_nicht_fuer_immer(buch):
    """The silent variant of "never delete" would be the most dangerous."""
    e, store = buch
    store.write("log.tage", "bald")

    assert e._days() == DEFAULT_DAYS


def test_die_obergrenze_greift_unabhaengig_vom_alter(buch, monkeypatch):
    """Against the case that something writes in a loop.

    The table lies in the same file as the household, and that goes into every
    backup.
    """
    import cinelounge.household.events as modul

    monkeypatch.setattr(modul, "MAX_ROWS", 5)
    for i in range(9):
        e_ = Events(buch[1])
        e_.record("event.service_started", {"n": i})

    assert Events(buch[1]).count() == 5


def test_ein_kaputter_eintrag_nimmt_die_liste_nicht_mit(buch):
    """The log is what one looks at when something else is already stuck."""
    e, store = buch
    e.record("event.service_started", {"version": "0.1.0"})
    with store.connect() as v:
        v.execute("UPDATE event SET values_json = ?", ("kein json",))

    (z,) = e.recent()
    assert z["values"] == {}
    assert z["code"] == "event.service_started"
