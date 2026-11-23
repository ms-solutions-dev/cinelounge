"""The one file the household lives in.

SQLite and no database beside it: a household has three to six people and a few
thousand catalogue entries. Demanding Postgres for that demands a second
container from everybody who runs it at home.

**Every request gets its own connection.** FastAPI runs the routes in a thread
pool, and a shared SQLite connection across that is precisely the kind of fault
that only shows up under load.

**Migrations are numbered and only run forwards.** `PRAGMA user_version` holds
the state; a migration that has run once never runs again. Without that, "add a
column" turns into guesswork the time after next.

**A new household starts from `BASE_SCHEMA`**, the state the first
`BASE_VERSION` steps leave behind, written down in one piece. The steps stay
for households that are older; `tests/test_household.py` checks that both
ways end in the same schema.

**Extensions keep their own numbers** (`Store.migrate_extension`): one row per
namespace in `schema_ext`, so that a table of theirs never takes a place in
the core's list.
"""

from __future__ import annotations

import re
import shutil
import sqlite3
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Final

from cinelounge.core.forkschranke import SCHRANKE

#: One step of a migration: an SQL script, or a function that gets the
#: connection — for a step that has to look before it changes something.
Step = str | Callable[[sqlite3.Connection], None]

MIGRATIONS: list[str] = [
    # 1 — Haushalt, Rollen, Sicht
    """
    CREATE TABLE benutzer (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        rolle       TEXT NOT NULL CHECK (rolle IN ('admin', 'erwachsen', 'kind')),
        pin_hash    TEXT NOT NULL DEFAULT '',
        farbe       TEXT NOT NULL DEFAULT '#E2564A',
        angelegt    REAL NOT NULL
    );

    -- Who may see which portal. No row means: no.
    -- Granting is a decision, not a side effect.
    CREATE TABLE sicht (
        benutzer_id TEXT NOT NULL REFERENCES benutzer(id) ON DELETE CASCADE,
        portal_id   TEXT NOT NULL,
        PRIMARY KEY (benutzer_id, portal_id)
    );

    -- Does a portal go out to devices at all? Holds for the whole household
    -- and is a different thing from one person's view.
    CREATE TABLE portal_schalter (
        portal_id TEXT PRIMARY KEY,
        aktiv     INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE geraet (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        art         TEXT NOT NULL DEFAULT '',
        -- NULL heisst „geteilt": ein Fernseher im Wohnzimmer gehoert
        -- niemandem, dort waehlt man beim Start ein Profil.
        benutzer_id TEXT REFERENCES benutzer(id) ON DELETE CASCADE,
        merkmal     TEXT NOT NULL UNIQUE,
        gekoppelt   REAL NOT NULL,
        zuletzt     REAL NOT NULL DEFAULT 0,
        von_wo      TEXT NOT NULL DEFAULT ''
    );

    -- Wartende Kopplungen und ausgesprochene Einladungen. Beide verfallen,
    -- beide gelten einmal — deshalb dieselbe Tabelle.
    CREATE TABLE zugang (
        marke       TEXT PRIMARY KEY,
        art         TEXT NOT NULL CHECK (art IN ('kopplung', 'einladung')),
        benutzer_id TEXT REFERENCES benutzer(id) ON DELETE CASCADE,
        geraet_name TEXT NOT NULL DEFAULT '',
        geraet_art  TEXT NOT NULL DEFAULT '',
        von_wo      TEXT NOT NULL DEFAULT '',
        erstellt    REAL NOT NULL,
        gilt_bis    REAL NOT NULL,
        verbraucht  REAL
    );

    CREATE TABLE stand (
        benutzer_id TEXT NOT NULL REFERENCES benutzer(id) ON DELETE CASCADE,
        schluessel  TEXT NOT NULL,
        portal_id   TEXT NOT NULL DEFAULT '',
        titel       TEXT NOT NULL DEFAULT '',
        jahr        INTEGER,
        adresse     TEXT NOT NULL DEFAULT '',
        art         TEXT NOT NULL DEFAULT '',
        bild        TEXT NOT NULL DEFAULT '',
        sprache     TEXT NOT NULL DEFAULT '',
        position_s  REAL NOT NULL DEFAULT 0,
        dauer_s     REAL NOT NULL DEFAULT 0,
        gesehen     INTEGER NOT NULL DEFAULT 0,
        favorit     INTEGER NOT NULL DEFAULT 0,
        geaendert   REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (benutzer_id, schluessel)
    );

    CREATE INDEX stand_favorit   ON stand(benutzer_id, favorit, geaendert DESC);
    CREATE INDEX stand_geaendert ON stand(benutzer_id, geaendert DESC);
    CREATE INDEX zugang_gilt     ON zugang(gilt_bis);

    CREATE TABLE einstellung (
        schluessel TEXT PRIMARY KEY,
        wert       TEXT NOT NULL
    );
    """,
    # 2 — everything in English.
    #
    # **The old migration stays exactly as it was.** It is history, not a
    # template: a database that already exists has arrived at step 1 and has to
    # move on from there. Rewriting step 1 after the fact turns a numbered
    # migration into guesswork — precisely what the head of this file forbids.
    #
    # **`ALTER TABLE … RENAME` and no re-creation.** The household is already
    # in there: people, PIN hashes, paired devices, weeks of progress. Copying
    # and re-hanging would be the same state with an opportunity to lose it.
    #
    # The statements below are the table of old names.
    """
    ALTER TABLE benutzer RENAME TO person;
    ALTER TABLE person RENAME COLUMN rolle TO role;
    ALTER TABLE person RENAME COLUMN farbe TO color;
    ALTER TABLE person RENAME COLUMN angelegt TO created;

    ALTER TABLE sicht RENAME TO visibility;
    ALTER TABLE visibility RENAME COLUMN benutzer_id TO person_id;

    ALTER TABLE portal_schalter RENAME TO portal_switch;
    ALTER TABLE portal_switch RENAME COLUMN aktiv TO on_air;

    ALTER TABLE geraet RENAME TO device;
    ALTER TABLE device RENAME COLUMN art TO kind;
    ALTER TABLE device RENAME COLUMN benutzer_id TO person_id;
    ALTER TABLE device RENAME COLUMN merkmal TO token;
    ALTER TABLE device RENAME COLUMN gekoppelt TO paired;
    ALTER TABLE device RENAME COLUMN zuletzt TO last_seen;
    ALTER TABLE device RENAME COLUMN von_wo TO from_where;

    ALTER TABLE zugang RENAME TO pending;
    ALTER TABLE pending RENAME COLUMN marke TO token;
    ALTER TABLE pending RENAME COLUMN art TO kind;
    ALTER TABLE pending RENAME COLUMN benutzer_id TO person_id;
    ALTER TABLE pending RENAME COLUMN geraet_name TO device_name;
    ALTER TABLE pending RENAME COLUMN geraet_art TO device_kind;
    ALTER TABLE pending RENAME COLUMN von_wo TO from_where;
    ALTER TABLE pending RENAME COLUMN erstellt TO created;
    ALTER TABLE pending RENAME COLUMN gilt_bis TO valid_until;
    ALTER TABLE pending RENAME COLUMN verbraucht TO used;

    ALTER TABLE stand RENAME TO progress;
    ALTER TABLE progress RENAME COLUMN benutzer_id TO person_id;
    ALTER TABLE progress RENAME COLUMN schluessel TO key;
    ALTER TABLE progress RENAME COLUMN titel TO title;
    ALTER TABLE progress RENAME COLUMN jahr TO year;
    ALTER TABLE progress RENAME COLUMN adresse TO address;
    ALTER TABLE progress RENAME COLUMN art TO kind;
    ALTER TABLE progress RENAME COLUMN bild TO image;
    ALTER TABLE progress RENAME COLUMN sprache TO language;
    ALTER TABLE progress RENAME COLUMN dauer_s TO duration_s;
    ALTER TABLE progress RENAME COLUMN gesehen TO watched;
    ALTER TABLE progress RENAME COLUMN favorit TO favorite;
    ALTER TABLE progress RENAME COLUMN geaendert TO changed;

    ALTER TABLE einstellung RENAME TO setting;
    ALTER TABLE setting RENAME COLUMN schluessel TO key;
    ALTER TABLE setting RENAME COLUMN wert TO value;

    -- **The values through a rebuild, not through UPDATE.** The check
    -- constraint travels along on rename: after `RENAME COLUMN rolle TO role`
    -- it reads `CHECK (role IN ('admin', 'adult', 'kind'))` — and an
    -- `UPDATE … SET role = 'child'` fails against it.
    --
    -- Measured on 10 Sep 2026 against the running database: the migration got
    -- this far, broke off, and `user_version` stayed at 1. On the next start
    -- it ran from the beginning again and failed at `ALTER TABLE benutzer`,
    -- which by then no longer existed. The service stopped starting.
    CREATE TABLE person_new (
        id       TEXT PRIMARY KEY,
        name     TEXT NOT NULL,
        role     TEXT NOT NULL CHECK (role IN ('admin', 'adult', 'child')),
        pin_hash TEXT NOT NULL DEFAULT '',
        color    TEXT NOT NULL DEFAULT '#E2564A',
        created  REAL NOT NULL
    );
    INSERT INTO person_new
        SELECT id, name,
               CASE role WHEN 'kind' THEN 'child'
                         WHEN 'erwachsen' THEN 'adult' ELSE role END,
               pin_hash, color, created
        FROM person;

    CREATE TABLE pending_new (
        token       TEXT PRIMARY KEY,
        kind        TEXT NOT NULL CHECK (kind IN ('pairing', 'invite')),
        person_id   TEXT REFERENCES person_new(id) ON DELETE CASCADE,
        device_name TEXT NOT NULL DEFAULT '',
        device_kind TEXT NOT NULL DEFAULT '',
        from_where  TEXT NOT NULL DEFAULT '',
        created     REAL NOT NULL,
        valid_until REAL NOT NULL,
        used        REAL
    );
    INSERT INTO pending_new
        SELECT token,
               CASE kind WHEN 'kopplung' THEN 'pairing'
                         WHEN 'einladung' THEN 'invite' ELSE kind END,
               person_id, device_name, device_kind, from_where, created,
               valid_until, used
        FROM pending;

    -- **Without `legacy_alter_table`.** With it, SQLite leaves the references
    -- behind on rename: `pending` then pointed at `person_new`, which no
    -- longer exists, and every pairing ran into "no such table". Without it,
    -- SQLite carries the references along — exactly what is needed here. The
    -- foreign keys are off during the migration anyway (`store.py`,
    -- `_migrate`).
    DROP TABLE pending;
    DROP TABLE person;
    ALTER TABLE person_new RENAME TO person;
    ALTER TABLE pending_new RENAME TO pending;

    DROP INDEX IF EXISTS stand_favorit;
    DROP INDEX IF EXISTS stand_geaendert;
    DROP INDEX IF EXISTS zugang_gilt;
    CREATE INDEX progress_favorite ON progress(person_id, favorite, changed DESC);
    CREATE INDEX progress_changed ON progress(person_id, changed DESC);
    CREATE INDEX pending_valid ON pending(valid_until);
    """,
    # 3 — the event book (B9).
    #
    # **What happened in the household, not what somebody watched.** The
    # reasoning behind that line is in `household/events.py`; here stands only
    # what it means for the schema: there is a `person_id`, because an
    # administrative act has somebody who triggered it — and there is **no**
    # field for a title, a portal entry or a playback position.
    #
    # **No foreign key on `person`**, and that is a decision against the first
    # draft. With `REFERENCES person(id)` SQLite rejected every row whose
    # `person_id` does not (any longer) exist — and because `record()` promises
    # never to raise, the event vanished silently in the process. Measured on
    # the first trial run: two written, one arrived.
    #
    # A log is a by-product. It must never be the reason something fails, and
    # least of all the reason something that did happen is missing. Whoever
    # removes a person clears their name out through `People.remove()` —
    # explicitly, and not as a side effect of an integrity rule.
    #
    # `values_json` as text: the values of an event are as varied as the events
    # themselves, and one column per kind would be a table that grows with
    # every new code.
    """
    CREATE TABLE event (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        at          REAL NOT NULL,
        code        TEXT NOT NULL,
        values_json TEXT NOT NULL DEFAULT '{}',
        person_id   TEXT
    );

    CREATE INDEX event_at ON event(at DESC);
    """,
    # 4 — the marketplace: sources and trust anchors (B6).
    #
    # **There is no official index, and that is a decision.** Keeping a
    # directory of foreign content is a different thing from expressing trust:
    # whoever enters a source decides for themselves who they believe — the
    # service only supplies the tool.
    #
    # `cached_json` holds the last successful fetch. **It is not a speed
    # trick.** A source that is not answering right now must not empty the
    # marketplace — otherwise a network outage looks like a withdrawn portal.
    #
    # `last_error` sits beside it because an empty cache and a stale one are
    # two different things, and the interface has to be able to say both.
    """
    CREATE TABLE market_source (
        url          TEXT PRIMARY KEY,
        name         TEXT NOT NULL DEFAULT '',
        added        REAL NOT NULL,
        last_fetch   REAL,
        last_error   TEXT,
        etag         TEXT,
        cached_json  TEXT
    );

    -- **The fingerprint is the key, not the name.**
    --
    -- An anchor is recognised by its public key; the name beside it is what
    -- the operator jotted down. Two anchors with the same name are allowed and
    -- harmless — two with the same key would be the same anchor twice.
    CREATE TABLE trust_anchor (
        fingerprint  TEXT PRIMARY KEY,
        name         TEXT NOT NULL DEFAULT '',
        public_key   TEXT NOT NULL,
        added        REAL NOT NULL
    );
    """,
    # 7 — nightly runs: what every portal did on every night
    #
    # **One row per portal and night, and the night is a date.** `2026-09-12`
    # and not a timestamp: a run that starts at 03:58 and ends at 04:07 belongs
    # to one night, and two runs in the same night are meant to replace each
    # other rather than stand side by side. The primary key sees to that.
    #
    # `ok` is `1`, `0` or `NULL` — carried, failed, did not run at all. The
    # third is not hair-splitting: a portal that was switched off has not
    # failed, and a strip that paints both the same makes a pause look like a
    # fault.
    #
    # `step` says **how far** it got — `menu`, `listing`, `sources`, `resolve`.
    # A portal that shows its list and fails at the stream is a different thing
    # from one that does not answer at all, and the answer to "why" starts
    # here.
    """
    CREATE TABLE night (
        portal_id  TEXT NOT NULL,
        night      TEXT NOT NULL,
        ok         INTEGER,
        step       TEXT NOT NULL DEFAULT '',
        reason     TEXT NOT NULL DEFAULT '',
        ms         INTEGER,
        ran        REAL NOT NULL,
        PRIMARY KEY (portal_id, night)
    );

    -- The strip fetches the last fourteen nights per portal; without the
    -- index that would be a table scan per portal page.
    CREATE INDEX night_by_date ON night (night DESC);
    """,
    # 6 — Beitritt: die Anfrage, die Personenmarke, die Drossel (AP47)
    #
    # **Eine eigene Tabelle und Zusatzfelder, kein Umbau.** `pending.kind`
    # trägt `CHECK (kind IN ('pairing', 'invite'))`; eine dritte Sorte hieße
    # die Tabelle neu bauen, und genau so ein Umbau ist die Stelle, an der
    # der Dienst am 10.09.2026 nicht mehr startete (Migration 2).
    # `ALTER TABLE … ADD COLUMN` berührt keine Prüfbedingung.
    #
    # `join_request.person_id` **ohne Fremdschlüssel**, aus demselben Grund
    # wie bei `event`: Wird die Person später entfernt, soll die Zeile weder
    # verschwinden noch das Schreiben scheitern lassen. `want` als Text mit
    # Komma: Die Wunschliste einer Anfrage lebt sieben Tage und wird einmal
    # gelesen — eine Zuordnungstabelle beantwortete keine Frage.
    #
    # `person.mark` ist die personengebundene Marke. `UNIQUE` über einen
    # Index: SQLite behandelt `NULL` als verschieden, also dürfen beliebig
    # viele Personen keine Marke haben, aber keine zwei dieselbe.
    #
    # `device.via_mark` ist der **Abdruck** der Marke, über die ein Gerät
    # kam (Entscheidung 8.4): Der Widerruf nimmt genau diese Geräte mit.
    # Der Abdruck und nicht die Marke, damit der Schlüssel an einer Stelle
    # liegt. `NULL` heißt: gekoppelt, eingeladen oder per PIN angemeldet.
    #
    # `throttle` hält die Drossel der offenen Wege **in der Ablage**: Der
    # Container wird von Watchtower neu gestartet, und eine Drossel, die ein
    # Neustart aufhebt, ist keine.
    """
    CREATE TABLE join_request (
        token       TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        color       TEXT NOT NULL DEFAULT '#E2564A',
        want        TEXT NOT NULL DEFAULT 'portals',
        device_name TEXT NOT NULL DEFAULT '',
        device_kind TEXT NOT NULL DEFAULT '',
        from_where  TEXT NOT NULL DEFAULT '',
        created     REAL NOT NULL,
        valid_until REAL NOT NULL,
        decided     REAL,
        declined    INTEGER NOT NULL DEFAULT 0,
        person_id   TEXT,
        device_id   TEXT,
        fetched     REAL
    );
    CREATE INDEX join_valid ON join_request(valid_until);

    ALTER TABLE person ADD COLUMN mark TEXT;
    CREATE UNIQUE INDEX person_mark ON person(mark);

    ALTER TABLE device ADD COLUMN via_mark TEXT;
    CREATE INDEX device_via_mark ON device(via_mark);

    CREATE TABLE throttle (
        scope  TEXT NOT NULL,
        origin TEXT NOT NULL,
        at     REAL NOT NULL
    );
    CREATE INDEX throttle_by ON throttle(scope, origin, at);
    """,
    # The series of an episode (AP63, 01.10.2026).
    #
    # **"Details" from Continue Watching showed one episode.** A row knew its
    # title, address and position, but not which series it belongs to — the
    # app had no way to open the series page with seasons and cast. The app
    # sends its own identifier of the series page; the server keeps it as
    # text and does not read it. Older rows stay without one.
    """
    ALTER TABLE progress ADD COLUMN series TEXT;
    """,
    # 8, 9, 10 — retired (23.11.2026).
    #
    # **Empty places, not deleted ones.** The steps are numbered by position;
    # taking three out would give every later step a new number, and a
    # database would skip some of them or run others twice. A database that
    # ran these keeps what they created. What used them now brings its own
    # schema through `Store.migrate_extension`.
    "",
    "",
    "",
    # Roles become data (09.11.2026) — see `household/roles.py`.
    #
    # **`person.role` stays where it is, CHECK and all.** Rebuilding exactly
    # such a table is what stopped the service on 10.09.2026 (migration 2). The
    # truth moves to two new columns instead: `role_id` (what the person sees in
    # the app) and `console` (whether they may run the console). `role` is from
    # now on a derived value the app still reads — `People` keeps it in step.
    #
    # **The two seeded roles keep the old ids `adult` and `child`,** so an app
    # that approves with `role: "adult"` keeps working without an update.
    #
    # **What the per-person permissions turn into.** `adult` gets every portal
    # an adult or the admin was permitted, plus everything switched on — the
    # admin saw all of that before. `child` gets only what *every* child had:
    # where the children differed, the stricter answer wins. A household
    # without children gets the adult list for `child` — the age lock keeps
    # 18+ portals out regardless (`view_adult`). Portals that are on
    # by the manifest's default (no row in `portal_switch`) are added once at
    # start-up by `Roles.adopt_defaults`, because SQL does not know manifests.
    # `visibility` stays as it is, for the way back.
    """
    CREATE TABLE role (
        id        TEXT PRIMARY KEY,
        name      TEXT NOT NULL,
        color     TEXT NOT NULL DEFAULT '#6aa8ff',
        rights    TEXT NOT NULL DEFAULT '',
        position  INTEGER NOT NULL DEFAULT 0,
        created   REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE role_portal (
        role_id    TEXT NOT NULL REFERENCES role(id) ON DELETE CASCADE,
        portal_id  TEXT NOT NULL,
        PRIMARY KEY (role_id, portal_id)
    );
    INSERT INTO role (id, name, color, rights, position, created) VALUES
        ('adult', 'Adult', '#6aa8ff', 'watch,track_progress,view_adult,own_devices,invite',
         0, strftime('%s', 'now')),
        ('child', 'Child', '#6fcf8e', 'watch,track_progress', 1, strftime('%s', 'now'));
    ALTER TABLE person ADD COLUMN role_id TEXT REFERENCES role(id);
    ALTER TABLE person ADD COLUMN console INTEGER NOT NULL DEFAULT 0;
    UPDATE person SET
        role_id = CASE role WHEN 'child' THEN 'child' ELSE 'adult' END,
        console = CASE role WHEN 'admin' THEN 1 ELSE 0 END;
    INSERT OR IGNORE INTO role_portal (role_id, portal_id)
        SELECT 'adult', v.portal_id FROM visibility AS v
        JOIN person AS p ON p.id = v.person_id WHERE p.role IN ('adult', 'admin');
    INSERT OR IGNORE INTO role_portal (role_id, portal_id)
        SELECT 'adult', portal_id FROM portal_switch WHERE on_air = 1;
    INSERT OR IGNORE INTO role_portal (role_id, portal_id)
        SELECT 'child', v.portal_id FROM visibility AS v
        JOIN person AS p ON p.id = v.person_id WHERE p.role = 'child'
        GROUP BY v.portal_id
        HAVING COUNT(*) = (SELECT COUNT(*) FROM person WHERE role = 'child');
    INSERT OR IGNORE INTO role_portal (role_id, portal_id)
        SELECT 'child', portal_id FROM role_portal
        WHERE role_id = 'adult' AND NOT EXISTS (SELECT 1 FROM person WHERE role = 'child');
    """,
    # ── 12: the child lock (09.11.2026) ──────────────────────────────────────
    # A role marked "for children" cannot get the right "ab 18" at all, and no
    # 18+ portal can be given to it; lifting the lock needs the PIN of whoever
    # does it. The seeded child role starts locked, unless somebody had
    # already given it "ab 18", which the lock must not silently take away.
    """
    ALTER TABLE role ADD COLUMN child_lock INTEGER NOT NULL DEFAULT 0;
    UPDATE role SET child_lock = 1
        WHERE id = 'child' AND ',' || rights || ',' NOT LIKE '%,view_adult,%';
    """,
]


#: The level a new household starts at — see `BASE_SCHEMA`.
BASE_VERSION: Final = 12

#: What the first `BASE_VERSION` steps of `MIGRATIONS` leave behind, in one
#: script. Column order as there: `SELECT *` (the backup) reads it in that order.
BASE_SCHEMA: Final = """
CREATE TABLE role (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    color      TEXT NOT NULL DEFAULT '#6aa8ff',
    rights     TEXT NOT NULL DEFAULT '',
    position   INTEGER NOT NULL DEFAULT 0,
    created    REAL NOT NULL DEFAULT 0,
    child_lock INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE role_portal (
    role_id    TEXT NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    portal_id  TEXT NOT NULL,
    PRIMARY KEY (role_id, portal_id)
);
INSERT INTO role (id, name, color, rights, position, created, child_lock) VALUES
    ('adult', 'Adult', '#6aa8ff', 'watch,track_progress,view_adult,own_devices,invite',
     0, strftime('%s', 'now'), 0),
    ('child', 'Child', '#6fcf8e', 'watch,track_progress', 1, strftime('%s', 'now'), 1);

CREATE TABLE person (
    id       TEXT PRIMARY KEY,
    name     TEXT NOT NULL,
    role     TEXT NOT NULL CHECK (role IN ('admin', 'adult', 'child')),
    pin_hash TEXT NOT NULL DEFAULT '',
    color    TEXT NOT NULL DEFAULT '#E2564A',
    created  REAL NOT NULL,
    mark     TEXT,
    role_id  TEXT REFERENCES role(id),
    console  INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX person_mark ON person(mark);

CREATE TABLE visibility (
    person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    portal_id TEXT NOT NULL,
    PRIMARY KEY (person_id, portal_id)
);

CREATE TABLE portal_switch (
    portal_id TEXT PRIMARY KEY,
    on_air    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE device (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT '',
    person_id  TEXT REFERENCES person(id) ON DELETE CASCADE,
    token      TEXT NOT NULL UNIQUE,
    paired     REAL NOT NULL,
    last_seen  REAL NOT NULL DEFAULT 0,
    from_where TEXT NOT NULL DEFAULT '',
    via_mark   TEXT
);
CREATE INDEX device_via_mark ON device(via_mark);

CREATE TABLE pending (
    token       TEXT PRIMARY KEY,
    kind        TEXT NOT NULL CHECK (kind IN ('pairing', 'invite')),
    person_id   TEXT REFERENCES person(id) ON DELETE CASCADE,
    device_name TEXT NOT NULL DEFAULT '',
    device_kind TEXT NOT NULL DEFAULT '',
    from_where  TEXT NOT NULL DEFAULT '',
    created     REAL NOT NULL,
    valid_until REAL NOT NULL,
    used        REAL
);
CREATE INDEX pending_valid ON pending(valid_until);

CREATE TABLE progress (
    person_id  TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    key        TEXT NOT NULL,
    portal_id  TEXT NOT NULL DEFAULT '',
    title      TEXT NOT NULL DEFAULT '',
    year       INTEGER,
    address    TEXT NOT NULL DEFAULT '',
    kind       TEXT NOT NULL DEFAULT '',
    image      TEXT NOT NULL DEFAULT '',
    language   TEXT NOT NULL DEFAULT '',
    position_s REAL NOT NULL DEFAULT 0,
    duration_s REAL NOT NULL DEFAULT 0,
    watched    INTEGER NOT NULL DEFAULT 0,
    favorite   INTEGER NOT NULL DEFAULT 0,
    changed    REAL NOT NULL DEFAULT 0,
    series     TEXT,
    PRIMARY KEY (person_id, key)
);
CREATE INDEX progress_favorite ON progress(person_id, favorite, changed DESC);
CREATE INDEX progress_changed ON progress(person_id, changed DESC);

CREATE TABLE setting (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE event (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    at          REAL NOT NULL,
    code        TEXT NOT NULL,
    values_json TEXT NOT NULL DEFAULT '{}',
    person_id   TEXT
);
CREATE INDEX event_at ON event(at DESC);

CREATE TABLE market_source (
    url          TEXT PRIMARY KEY,
    name         TEXT NOT NULL DEFAULT '',
    added        REAL NOT NULL,
    last_fetch   REAL,
    last_error   TEXT,
    etag         TEXT,
    cached_json  TEXT
);
CREATE TABLE trust_anchor (
    fingerprint  TEXT PRIMARY KEY,
    name         TEXT NOT NULL DEFAULT '',
    public_key   TEXT NOT NULL,
    added        REAL NOT NULL
);

CREATE TABLE night (
    portal_id  TEXT NOT NULL,
    night      TEXT NOT NULL,
    ok         INTEGER,
    step       TEXT NOT NULL DEFAULT '',
    reason     TEXT NOT NULL DEFAULT '',
    ms         INTEGER,
    ran        REAL NOT NULL,
    PRIMARY KEY (portal_id, night)
);
CREATE INDEX night_by_date ON night (night DESC);

CREATE TABLE join_request (
    token       TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    color       TEXT NOT NULL DEFAULT '#E2564A',
    want        TEXT NOT NULL DEFAULT 'portals',
    device_name TEXT NOT NULL DEFAULT '',
    device_kind TEXT NOT NULL DEFAULT '',
    from_where  TEXT NOT NULL DEFAULT '',
    created     REAL NOT NULL,
    valid_until REAL NOT NULL,
    decided     REAL,
    declined    INTEGER NOT NULL DEFAULT 0,
    person_id   TEXT,
    device_id   TEXT,
    fetched     REAL
);
CREATE INDEX join_valid ON join_request(valid_until);

CREATE TABLE throttle (
    scope  TEXT NOT NULL,
    origin TEXT NOT NULL,
    at     REAL NOT NULL
);
CREATE INDEX throttle_by ON throttle(scope, origin, at);
"""

#: What a namespace in `schema_ext` may look like: it also names the copy
#: beside the file while a step runs.
_NAMESPACE: Final = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")


class Store:
    """One file, one household."""

    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextmanager
    def connect(self, *, immediate: bool = False) -> Iterator[sqlite3.Connection]:
        """A connection of its own per call, with foreign keys on.

        `foreign_keys` is a per-connection setting in SQLite and is **off** by
        default. Without this line `ON DELETE CASCADE` is a claim: a deleted
        person would leave their permissions and their progress behind.
        """
        # **Behind the fork barrier** (AP74, 11.10.2026): a fork that lands while
        # this thread is inside SQLite hands the child a locked mutex — see
        # `core/forkschranke.py`. Everything from `connect` to `close` stays
        # inside, the fork waits the few milliseconds.
        with SCHRANKE.sqlite():
            v = sqlite3.connect(self.path, timeout=10)
            v.row_factory = sqlite3.Row
            v.execute("PRAGMA foreign_keys = ON")
            v.execute("PRAGMA journal_mode = WAL")
            # **`immediate=True` nimmt die Schreibsperre vor dem ersten Lesen.**
            # Ohne sie beginnt Python-sqlite die Transaktion erst beim ersten
            # Schreiben; was davor gelesen wurde, kann bis dahin schon falsch sein.
            # Gefunden am 24.09.2026 (AP47): `enroll` las die Personenmarke, ein
            # gleichzeitiger Widerruf tauschte sie aus, und das danach angelegte
            # Gerät trug den Abdruck der alten Marke — es überlebte den Widerruf.
            if immediate:
                v.execute("BEGIN IMMEDIATE")
            try:
                yield v
                v.commit()
            except Exception:
                v.rollback()
                raise
            finally:
                v.close()

    def _migrate(self) -> None:
        """Every migration exactly once — and **with a way back**.

        `executescript` is not transactional: it closes any open transaction
        and then runs statement after statement. If the seventeenth breaks off,
        the first sixteen are written and `user_version` still stands at the
        old value. On the next start the same migration runs from the
        beginning — and fails on what it already did the first time.

        **Measured on 10 Sep 2026**, against this house's running database:
        migration 2 got as far as converting the values, broke off at a check
        constraint, and afterwards the service did not start at all. The only
        way back was by hand.

        That is why a copy sits beside the file before every step. If the step
        goes wrong, the copy comes back and the error stands at the beginning
        instead of in the middle.

        **A file without any table starts at `BASE_VERSION`** in one step.
        A household that already has a level — even one below the base —
        goes on from there, step by step as before.
        """
        with self.connect() as v:
            done = int(v.execute("PRAGMA user_version").fetchone()[0])
            tables = v.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
            ).fetchone()[0]
        if done == 0 and tables == 0:
            # No parameter: PRAGMA takes none. The number is a constant.
            self._step(f".vor{BASE_VERSION}", BASE_SCHEMA, f"PRAGMA user_version = {BASE_VERSION}")
            done = BASE_VERSION
        for number, step in enumerate(MIGRATIONS[done:], start=done + 1):
            # The number comes from `enumerate` and not from outside.
            self._step(f".vor{number}", step, f"PRAGMA user_version = {number}")

    def migrate_extension(self, namespace: str, steps: Sequence[Step]) -> int:
        """An extension's own migrations — numbered per `namespace`, run once each.

        The same rules as the core's: forwards only, one step after the other,
        a copy beside the file while a step runs. The level stands in the
        table `schema_ext` and not in `user_version`, so the core's numbers
        never move. A step must cope with a database that already holds its
        table — `CREATE TABLE IF NOT EXISTS`, or a function that looks first.

        Returns the level the namespace stands at afterwards.
        """
        if not _NAMESPACE.fullmatch(namespace):
            raise ValueError(f"namespace must match {_NAMESPACE.pattern}: {namespace!r}")
        with self.connect() as v:
            v.execute(
                "CREATE TABLE IF NOT EXISTS schema_ext ("
                "namespace TEXT PRIMARY KEY, version INTEGER NOT NULL)"
            )
            z = v.execute(
                "SELECT version FROM schema_ext WHERE namespace = ?", (namespace,)
            ).fetchone()
        done = int(z["version"]) if z else 0
        for number, step in enumerate(steps[done:], start=done + 1):
            self._step(
                f".vor-{namespace}-{number}",
                step,
                "INSERT INTO schema_ext (namespace, version) VALUES (?, ?) "
                "ON CONFLICT(namespace) DO UPDATE SET version = excluded.version",
                (namespace, number),
            )
        return max(done, len(steps))

    def _step(
        self, suffix: str, step: Step, level: str, values: tuple[str | int, ...] = ()
    ) -> None:
        """Run one step and write its level — or put the copy back."""
        sicherung = self.path.with_suffix(self.path.suffix + suffix)
        if self.path.exists():
            shutil.copy2(self.path, sicherung)
        try:
            with self.connect() as v:
                # **Foreign keys off while the schema migrates.**
                # Migration 2 creates `person` anew and drops the old
                # table — with foreign keys on, `ON DELETE CASCADE` clears
                # out `progress`, `visibility` and `device` along with it.
                #
                # Found by `test_wanderung_zwei_traegt_einen_deutschen_
                # haushalt_hinueber`: after the migration, progress was
                # empty. On the running database that would have been
                # weeks.
                v.execute("PRAGMA foreign_keys = OFF")
                if isinstance(step, str):
                    v.executescript(step)
                else:
                    step(v)
                v.execute("PRAGMA foreign_keys = ON")
                v.execute(level, values)
        except Exception:
            if sicherung.exists():
                shutil.copy2(sicherung, self.path)
            raise
        finally:
            sicherung.unlink(missing_ok=True)

    # ── Settings ────────────────────────────────────────────────────────────

    def read(self, key: str, fallback: str = "") -> str:
        with self.connect() as v:
            z = v.execute("SELECT value FROM setting WHERE key = ?", (key,)).fetchone()
        return str(z["value"]) if z else fallback

    def write(self, key: str, value: str) -> None:
        with self.connect() as v:
            v.execute(
                "INSERT INTO setting (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )

    # ── Settings that belong to a portal ────────────────────────────────────
    #
    # **Why not into the `portal.yml`.** The first attempt, on 10 Sep 2026,
    # wrote a portal's API key back to where it stands in the manifest. Two
    # reasons why that is wrong, and the second weighs more:
    #
    # 1. `yaml.safe_dump` knows nothing about comments. The head of the file
    #    ("Generated from portal.yml.bruecke …") was gone after the first
    #    write. A manifest is a file somebody else wrote.
    # 2. **Since E4 the portal folder is pinned by `sha256`.** A value sitting
    #    inside it gets overwritten by the next version — and until then the
    #    checksum no longer matches what was pinned.
    #
    # The manifest belongs to the author, the value to the operator. So: apart.

    def portal_settings(self, portal_id: str) -> dict[str, str]:
        """What the operator stored for this portal."""
        prefix = f"portal.{portal_id}."
        with self.connect() as v:
            rows = v.execute(
                "SELECT key, value FROM setting WHERE key LIKE ?", (prefix + "%",)
            ).fetchall()
        return {str(z["key"])[len(prefix) :]: str(z["value"]) for z in rows}

    def set_portal_setting(self, portal_id: str, key: str, value: str) -> None:
        """Einen Wert hinterlegen — oder mit leerem Wert wieder wegnehmen."""
        full = f"portal.{portal_id}.{key}"
        if value:
            self.write(full, value)
            return
        with self.connect() as v:
            v.execute("DELETE FROM setting WHERE key = ?", (full,))
