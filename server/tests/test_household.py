"""What would break silently if nobody checked.

What fails loudly anyway is not tested. What is tested is where a rule holds —
and where its failure looks like correct behaviour.
"""

from __future__ import annotations

import time

import pytest

from cinelounge.core import errors as f
from cinelounge.core.ids import key, normalized, pairing_code
from cinelounge.household.devices import Devices
from cinelounge.household.people import People
from cinelounge.household.store import MIGRATIONS, Store


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "household.sqlite")


@pytest.fixture
def people(store):
    return People(store)


# ── Ids ──────────────────────────────────────────────────────────────────────


def test_titel_werden_gleich_normalisiert():
    """`Die Corvellis` and `die corvellis!` are the same title."""
    assert normalized("Die Corvellis") == normalized("die corvellis!")
    assert normalized("Shōgun") == normalized("Shogun")


def test_schluessel_haengt_nicht_an_der_adresse():
    """Trap 2: if a portal changes its address scheme, the progress stays."""
    assert key("ahorn", "Krimireihe", 2024) == key("ahorn", "  krimireihe  ", 2024)


def test_kopplungscode_ohne_verwechselbare_zeichen():
    """`0` against `O` costs a second attempt when typing off the television."""
    for _ in range(200):
        code = pairing_code()
        assert len(code) == 6
        assert not set(code) & set("O0I1L")


# ── People and PIN ───────────────────────────────────────────────────────────


def test_pin_muss_ziffern_haben(people):
    with pytest.raises(f.Error) as err:
        people.create("Max", "admin", "abc")
    assert err.value.code == "auth.pin_format"


def test_anmelden_traegt_und_falsche_pin_nicht(people):
    people.create("Max", "admin", "1234")
    assert people.sign_in("max", "1234").role == "admin"
    with pytest.raises(f.Error):
        people.sign_in("max", "0000")


def test_unbekannte_kennung_sieht_aus_wie_falsche_pin(people):
    """Otherwise the service tells everybody which ids exist.

    The code is `AUTH_BAD_CREDENTIALS` and not `AUTH_REQUIRED`: "you mistyped"
    and "you sent no token" are two different sentences for the interface, and
    on the same code they cannot be translated. What the code still does
    **not** reveal is which of the two halves was wrong — and that is exactly
    the point here.
    """
    people.create("Max", "admin", "1234")
    with pytest.raises(f.Error) as a:
        people.sign_in("gibtsnicht", "1234")
    with pytest.raises(f.Error) as b:
        people.sign_in("max", "1111")
    assert a.value.code == b.value.code == f.AUTH_BAD_CREDENTIALS
    assert a.value.status == b.value.status == 401


def test_pin_sperrt_nach_fuenf_versuchen(people):
    """A four-digit PIN without a limit is no PIN."""
    people.create("Max", "admin", "1234")
    for _ in range(5):
        with pytest.raises(f.Error):
            people.sign_in("max", "9999")
    with pytest.raises(f.Error) as err:
        people.sign_in("max", "1234")  # right PIN, locked all the same
    assert err.value.code == f.AUTH_LOCKED_OUT


def test_pin_steht_nicht_im_klartext(people, store):
    people.create("Max", "admin", "1234")
    with store.connect() as v:
        hash_ = v.execute("SELECT pin_hash FROM person").fetchone()["pin_hash"]
    assert "1234" not in hash_
    assert hash_.startswith("$argon2")


# ── Roles ────────────────────────────────────────────────────────────────────


def test_nur_der_admin_darf_verwalten(people):
    admin = people.create("Max", "admin", "1234")
    frau = people.create("Sina", "adult", "1234")
    kind = people.create("Eli", "child", "1111")

    assert admin.may("change_settings")
    assert not frau.may("change_settings")
    assert not kind.may("change_settings")

    for current_person in (admin, frau, kind):
        assert current_person.may("watch")

    assert admin.may("view_adult")
    assert frau.may("view_adult")
    assert not kind.may("view_adult")


def test_unbekanntes_recht_sperrt_statt_durchzulassen(people):
    """A typo in the call must not open a door."""
    admin = people.create("Max", "admin", "1234")
    assert not admin.may("einstelungen_aendern")


def test_rolle_wechselt_ohne_dass_die_person_neu_entsteht(store, people):
    """**A child turning eighteen keeps their progress.** Before 19.09.2026
    the only way was remove-and-recreate, and that took the progress and the
    devices with it (`ON DELETE CASCADE`)."""
    people.create("Max", "admin", "1234")
    kind = people.create("Eli", "child", "1111")
    with store.connect() as v:
        v.execute(
            "INSERT INTO progress (person_id, key, portal_id, position_s, duration_s, changed) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (kind.id, "ahorn:krimireihe:", "ahorn", 60.0, 3000.0, 0.0),
        )

    grown = people.set_role("eli", "adult")
    assert grown.role == "adult"
    assert grown.may("view_adult")
    assert people.by_id("eli").adult, "the change is in the household, not only in the answer"
    with store.connect() as v:
        assert (
            v.execute("SELECT COUNT(*) AS n FROM progress WHERE person_id = 'eli'").fetchone()["n"]
            == 1
        )
    # And the PIN still carries — the row was changed, not replaced.
    assert people.sign_in("eli", "1111").role == "adult"


def test_der_letzte_admin_wird_nicht_herabgestuft(people):
    """The last person with console access keeps it — a household nobody can
    manage is only recoverable inside the database. A role change never
    touches console access (09.11.2026)."""
    people.create("Max", "admin", "1234")
    people.create("Sina", "adult", "1234")
    assert people.set_role("max", "adult").console is True
    with pytest.raises(f.Error) as e:
        people.set_console("max", False)
    assert e.value.code == "household.last_admin"

    # With a second one the first may step down.
    people.set_console("sina", True)
    assert people.set_console("max", False).role == "adult"


def test_rolle_fuer_unbekannte_person(people):
    with pytest.raises(f.Error) as e:
        people.set_role("niemand", "adult")
    assert e.value.code == "household.unknown_person"


# ── Pairing and invitation ───────────────────────────────────────────────────


def test_kopplung_gilt_genau_einmal(store, people):
    people.create("Max", "admin", "1234")
    g = Devices(store)
    pending = g.request_code("Apple TV Wohnzimmer", "tvOS 18.4", "192.0.2.33")

    token = g.redeem(pending.token, user_id="max")
    assert g.by_token(token) is not None

    with pytest.raises(f.Error) as err:
        g.redeem(pending.token, user_id="max")
    assert err.value.code == f.INVITE_USED


def test_geteiltes_geraet_hat_keine_person(store, people):
    people.create("Max", "admin", "1234")
    g = Devices(store)
    pending = g.request_code("Apple TV", "tvOS 18.4", "192.0.2.33")
    token = g.redeem(pending.token, user_id=None)
    assert g.by_token(token).shared


def test_keine_einladung_fuer_kinder(store, people):
    """Otherwise the age lock is a matter of care instead of a rule."""
    people.create("Eli", "child", "1111")
    g = Devices(store)
    with pytest.raises(f.Error) as err:
        g.invite("eli")
    assert err.value.code == "invite.not_for_children"


def test_abgelaufene_kopplung_traegt_nicht(store, people):
    people.create("Max", "admin", "1234")
    g = Devices(store)
    pending = g.request_code("Apple TV", "tvOS 18.4", "")
    with store.connect() as v:
        v.execute(
            "UPDATE pending SET valid_until = ? WHERE token = ?",
            (time.time() - 1, pending.token),
        )
    with pytest.raises(f.Error) as err:
        g.redeem(pending.token, user_id="max")
    assert err.value.code == f.PAIRING_EXPIRED


def test_geloeschte_person_nimmt_ihre_geraete_mit(store, people):
    """`ON DELETE CASCADE` only holds with `PRAGMA foreign_keys = ON`."""
    people.create("Sina", "adult", "1234")
    g = Devices(store)
    pending = g.request_code("iPhone", "iOS 18.7", "")
    g.redeem(pending.token, user_id="sina")
    with store.connect() as v:
        v.execute("DELETE FROM person WHERE id = 'sina'")
    assert g.list_all() == []


# ── Migrations ───────────────────────────────────────────────────────────────


def test_wanderung_zwei_traegt_einen_deutschen_haushalt_hinueber(tmp_path):
    """**The case it failed on once.**

    A database from before the rename: German tables, German columns,
    `rolle = 'kind'`. Migration 2 has to carry it across without losing a row —
    and without failing on its own check constraint.

    Measured 10.09.2026: exactly that went wrong. After `RENAME COLUMN rolle TO
    role` it still read `CHECK (role IN ('admin','adult','kind'))`, and the
    `UPDATE … SET role = 'child'` ran into it. The migration broke in the
    middle, `user_version` stayed at 1, and at the next start it failed on
    what it had already done the first time.
    """
    import sqlite3

    path = tmp_path / "alt.sqlite"
    v = sqlite3.connect(path)
    v.executescript(MIGRATIONS[0])
    # **Both roles that existed back then.** The first attempt checked only
    # `kind` — and `erwachsen` stayed untranslated until the live database
    # showed it: `CHECK constraint failed: role IN ('admin','adult','child')`.
    v.execute(
        "INSERT INTO benutzer (id, name, rolle, pin_hash, farbe, angelegt) "
        "VALUES ('eli', 'Eli', 'kind', 'x', '#8DC088', 1.0)"
    )
    v.execute(
        "INSERT INTO benutzer (id, name, rolle, pin_hash, farbe, angelegt) "
        "VALUES ('sina', 'Sina', 'erwachsen', 'y', '#5C97EE', 2.0)"
    )
    v.execute(
        "INSERT INTO zugang (marke, art, benutzer_id, erstellt, gilt_bis) "
        "VALUES ('ABC123', 'kopplung', NULL, 1.0, 9999999999.0)"
    )
    v.execute(
        "INSERT INTO stand (benutzer_id, schluessel, titel, position_s, dauer_s) "
        "VALUES ('eli', 'ahorn:igel:', 'Die Stunde mit dem Igel', 60.0, 1500.0)"
    )
    v.execute("PRAGMA user_version = 1")
    v.commit()
    v.close()

    Store(path)  # migrates

    v = sqlite3.connect(path)
    v.row_factory = sqlite3.Row
    # **Against the number of migrations, not a fixed one.** Otherwise this
    # test would be due with every new migration although it says nothing
    # about it.
    import cinelounge.household.store as store_modul

    assert v.execute("PRAGMA user_version").fetchone()[0] == len(store_modul.MIGRATIONS)

    person = v.execute("SELECT * FROM person WHERE id = 'eli'").fetchone()
    assert person["role"] == "child", "the role is now called child"
    assert person["color"] == "#8DC088", "and the rest still stands"
    assert v.execute("SELECT role FROM person WHERE id = 'sina'").fetchone()[0] == "adult"

    wartend = v.execute("SELECT * FROM pending").fetchone()
    assert wartend["kind"] == "pairing"
    assert wartend["token"] == "ABC123"

    stand = v.execute("SELECT * FROM progress").fetchone()
    assert stand["title"] == "Die Stunde mit dem Igel"
    assert stand["duration_s"] == 1500.0
    v.close()


def test_eine_gescheiterte_wanderung_laesst_nichts_halbes_zurueck(tmp_path, monkeypatch):
    """**`executescript` is not transactional**, and that is the trap.

    If the seventeenth statement aborts, the first sixteen are written and
    `user_version` still stands at the old level — at the next start the same
    migration runs again from the top and fails on what it has already done.
    The service then does not start at all any more.

    That is why a copy lies beside it before every step.
    """
    import sqlite3

    import cinelounge.household.store as store_modul

    path = tmp_path / "h.sqlite"
    Store(path)  # up to the latest level
    stand = len(store_modul.MIGRATIONS)

    kaputt = [*list(store_modul.MIGRATIONS), "CREATE TABLE spaeter (x TEXT); SELECT nonsense();"]
    monkeypatch.setattr(store_modul, "MIGRATIONS", kaputt)

    with pytest.raises(sqlite3.OperationalError):
        Store(path)

    v = sqlite3.connect(path)
    assert v.execute("PRAGMA user_version").fetchone()[0] == stand, "the level stays where it was"
    tabellen = {r[0] for r in v.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert "spaeter" not in tabellen, "and the half migration is taken back"
    assert "person" in tabellen
    v.close()
    assert not list(tmp_path.glob("*.vor*")), "the copy does not linger"


# ── The base schema and the extensions' own migrations ──────────────────────


def _schema(path) -> dict[str, object]:
    """Everything about a schema that a query can tell apart, without whitespace.

    Columns with type, default and key, foreign keys, indexes with their
    direction and uniqueness, the CHECK clauses, the level and the seeded roles.
    """
    import re
    import sqlite3

    v = sqlite3.connect(path)
    out: dict[str, object] = {"level": v.execute("PRAGMA user_version").fetchone()[0]}
    for name, sql in v.execute(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ).fetchall():
        checks = sorted(" ".join(c.split()) for c in re.findall(r"CHECK \(([^)]*\))", sql or ""))
        out["table " + name] = (
            [tuple(r) for r in v.execute(f"PRAGMA table_info({name})")],
            [tuple(r) for r in v.execute(f"PRAGMA foreign_key_list({name})")],
            checks,
        )
    for name, table in v.execute(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' ORDER BY name"
    ).fetchall():
        listed = [tuple(r)[1:] for r in v.execute(f"PRAGMA index_list({table})") if r[1] == name]
        out["index " + name] = (
            table,
            [tuple(r) for r in v.execute(f"PRAGMA index_xinfo({name})")],
            listed,
        )
    out["roles"] = [
        tuple(r)
        for r in v.execute(
            "SELECT id, name, color, rights, position, child_lock FROM role ORDER BY id"
        )
    ]
    v.close()
    return out


def test_ein_neuer_haushalt_beginnt_bei_der_basis_wie_nach_allen_schritten(tmp_path):
    """**Two ways to the same schema.** A new file gets `BASE_SCHEMA` in one
    step; an old one walks the steps. If they ever drift apart, a household's
    schema depends on its age — and the next migration meets two."""
    import sqlite3

    import cinelounge.household.store as store_modul

    Store(tmp_path / "neu.sqlite")

    schritte = tmp_path / "schritte.sqlite"
    v = sqlite3.connect(schritte)
    for nummer, sql in enumerate(store_modul.MIGRATIONS[: store_modul.BASE_VERSION], start=1):
        v.execute("PRAGMA foreign_keys = OFF")
        v.executescript(sql)
        v.execute(f"PRAGMA user_version = {nummer}")
    v.commit()
    v.close()

    neu = _schema(tmp_path / "neu.sqlite")
    assert neu["level"] == store_modul.BASE_VERSION == 12
    assert neu == _schema(schritte)
    assert neu["roles"] == [
        (
            "adult",
            "Adult",
            "#6aa8ff",
            "watch,track_progress,view_adult,own_devices,invite",
            0,
            0,
        ),
        ("child", "Child", "#6fcf8e", "watch,track_progress", 1, 1),
    ]


def test_ein_haushalt_auf_der_basisstufe_bleibt_unberuehrt(tmp_path):
    """The running households stand at 12: opening one changes nothing in it."""
    import hashlib

    path = tmp_path / "h.sqlite"
    Store(path)
    People(Store(path)).create("Ada", "admin", "1234")
    vorher = _schema(path)
    with Store(path).connect() as v:
        v.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    abdruck = hashlib.sha256(path.read_bytes()).hexdigest()

    Store(path)

    assert _schema(path) == vorher
    assert hashlib.sha256(path.read_bytes()).hexdigest() == abdruck


def test_eine_datei_mit_tabellen_auf_stufe_null_geht_die_schritte(tmp_path):
    """Only an empty file starts at the base — anything else is history to walk."""
    import sqlite3

    path = tmp_path / "alt.sqlite"
    v = sqlite3.connect(path)
    v.executescript(MIGRATIONS[0])
    v.commit()
    v.close()
    with pytest.raises(sqlite3.OperationalError, match="already exists"):
        Store(path)


def test_erweiterungsschritte_laufen_einmal_und_zaehlen_eigen(store):
    """A namespace of its own in `schema_ext` — the core's level never moves."""
    gelaufen: list[int] = []

    def zweiter(v):
        gelaufen.append(2)
        v.execute("INSERT INTO probe_notiz (text) VALUES ('zwei')")

    schritte = ["CREATE TABLE IF NOT EXISTS probe_notiz (text TEXT NOT NULL)", zweiter]
    assert store.migrate_extension("probe", schritte) == 2
    assert store.migrate_extension("probe", schritte) == 2
    assert gelaufen == [2]
    # One more step later: only that one runs.
    assert store.migrate_extension("probe", [*schritte, "ALTER TABLE probe_notiz ADD x INT"]) == 3
    with store.connect() as v:
        assert [tuple(r) for r in v.execute("SELECT * FROM schema_ext")] == [("probe", 3)]
        assert v.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)
        assert [r[0] for r in v.execute("SELECT text FROM probe_notiz")] == ["zwei"]


def test_ein_gescheiterter_erweiterungsschritt_nimmt_sich_zurueck(store, tmp_path):
    import sqlite3

    def kaputt(v):
        v.execute("CREATE TABLE probe_halb (x TEXT)")
        raise sqlite3.OperationalError("Schritt zwei geht nicht")

    with pytest.raises(sqlite3.OperationalError):
        store.migrate_extension("probe", ["CREATE TABLE probe_eins (x TEXT)", kaputt])
    with store.connect() as v:
        tabellen = {r[0] for r in v.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        stufe = v.execute("SELECT version FROM schema_ext WHERE namespace = 'probe'").fetchone()
    assert "probe_eins" in tabellen and "probe_halb" not in tabellen
    assert stufe[0] == 1, "the first step counts, the second will run again"
    assert not list(tmp_path.glob("*.vor*")), "the copy does not linger"


@pytest.mark.parametrize("namespace", ["", "Gross", "mit leer", "../weg", "x" * 65])
def test_ein_namensraum_hat_eine_feste_form(store, namespace):
    with pytest.raises(ValueError):
        store.migrate_extension(namespace, [])
