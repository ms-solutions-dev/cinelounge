"""Beitritt: eine Person fragt an, der Verwalter gibt frei (AP47).

**Der zweite offene Schreibweg des Dienstes, nach `POST /setup`.** Deshalb hängt
hier fast alles an der Absicherung und kaum etwas an der Nutzlast. Die Regeln
stehen in dieser Datei und nicht in den Wegen — dieselbe Trennung wie bei
`People` und `Devices`.

**Vor der Freigabe entsteht nichts.** Keine Person, kein Recht, kein Merkmal,
das irgendwo greift — nur eine Zeile in `join_request`. Das ist der eigentliche
Schutz; Drossel, Obergrenze und Frist schützen nur die Benutzbarkeit.

**Eine eigene Tabelle, kein Umbau von `pending`.** `pending.kind` trägt eine
`CHECK`-Bedingung, und genau der Umbau einer solchen Tabelle ist die Stelle, an
der der Dienst am 10.09.2026 nicht mehr startete (`store.py`, Migration 2).

**Die Personenmarke** ist der Schlüssel, mit dem ein weiteres Gerät dieser
Person sich selbst anmeldet (`POST /device/enroll`). Entscheidung des Besitzers
vom 24.09.2026: Sie steckt im Profil der App und wandert mit ihm über iCloud —
wer ein Profil teilt, teilt es ganz. Daraus folgt der Widerruf: Er nimmt
**jedes Gerät mit, das über diese Marke kam**, und gibt eine neue aus. Dafür
trägt `device.via_mark` den Fingerabdruck der Marke, über die es kam — den
Abdruck und nicht die Marke, damit der Schlüssel nur an einer Stelle liegt.
"""

from __future__ import annotations

import hashlib
import re
import sqlite3
import time
from dataclasses import dataclass
from typing import Final

from cinelounge.core import errors as f
from cinelounge.core.ids import device_token, invite_token
from cinelounge.household.devices import insert_device
from cinelounge.household.people import (
    OWN_DEVICES_JOINED,
    OWN_DEVICES_SQL,
    PERSON_COLUMNS,
    PERSON_FROM,
    People,
    Person,
    person_from,
)
from cinelounge.household.store import Store

#: Frist einer offenen Anfrage. Fünf Minuten (Kopplung) sind falsch, weil
#: niemand daneben steht; 24 Stunden (Einladung), weil der Verwalter verreist
#: sein kann. Eine Woche trägt „Selin fragt am Samstag, Vater sieht am Mittwoch
#: nach“ und lässt eine vergessene Anfrage von selbst verschwinden.
REQUEST_TTL_S: Final = 7 * 24 * 3600.0

#: Nach der Entscheidung ist die Woche vorbei: Die Antwort bleibt noch einen Tag
#: abholbar, dann ist die Anfragemarke nichts mehr wert.
DECIDED_TTL_S: Final = 24 * 3600.0

#: Wie lange eine schon abgeholte Freigabe ein zweites Mal abholbar bleibt.
#:
#: **Nicht genau einmal:** Eine App, die zwischen Antwort und Ablegen abstürzt,
#: wäre sonst dauerhaft draußen. **Aber auch nicht den ganzen Tag:** Eine
#: Anfragemarke, unter der eine Personenmarke liegt, ist ein zweiter Schlüssel
#: zum Haushalt, der herumliegt. Zehn Minuten decken den Absturz und nicht mehr.
FETCH_GRACE_S: Final = 10 * 60.0

#: Höchstens so viele offene Anfragen im Haushalt. Darüber wird **abgelehnt und
#: nicht ersetzt**: Die Liste des Verwalters ist das Gut, und die darf ihm
#: niemand von außen umschreiben.
MAX_OPEN: Final = 10

#: Höchstens so viele Geräte über **eine** Marke.
#:
#: Die Drossel zählt bei `enroll` nur Fehlgriffe — wer die Marke hat, trifft
#: immer, und jeder Treffer legt ein Gerät an. Gedeckelt wird der **Bestand**
#: über die aktuelle Marke und nicht die Zahl am Tag: Ein Tageszähler ließe den
#: Stapel jeden Tag um zehn wachsen, ein Bestand bleibt begrenzt. Es braucht
#: keine neue Tabelle (`device.via_mark` zählt schon), andere Wege (Kopplung,
#: Einladung, PIN) zählen nicht mit, und der Widerruf setzt ihn von selbst
#: zurück, weil er genau diese Geräte mitnimmt. Zehn trägt Telefon, Tablet,
#: zwei Fernseher und ein paar Neuanmeldungen nach einem Geräteumzug.
MAX_DEVICES_PER_MARK: Final = 10

#: Was man sich wünschen kann. Unbekannte Wünsche fallen still weg — dieselbe
#: Vorwärtsverträglichkeit wie bei den Rechten in der App.
KNOWN_WANTS: Final = ("portals",)

#: Die Drossel je Herkunft: drei in der Stunde, zehn am Tag (8.8).
LIMITS: Final = ((3, 3600.0), (10, 24 * 3600.0))

_FARBE: Final = re.compile(r"#[0-9A-Fa-f]{6}")


def mark_fingerprint(mark: str) -> str:
    """Der Abdruck einer Personenmarke — das, was ein Gerät von ihr behält.

    Ein Abdruck und nicht die Marke selbst: Sie soll nur an einer Stelle im
    Haushalt liegen (`person.mark`), und für „welche Geräte kamen über diese
    Marke“ genügt, sie wiederzuerkennen.
    """
    return hashlib.sha256(mark.encode()).hexdigest()[:32]


class Throttle:
    """Wie oft eine Herkunft einen offenen Weg benutzen darf.

    **In der Ablage, nicht im Prozessspeicher** — anders als die PIN-Versuche in
    `People._fehl`. Der Container wird von Watchtower neu gestartet, und eine
    Drossel, die ein Neustart aufhebt, ist keine.

    `check` und `note` sind getrennt, weil nicht jeder Weg jeden Aufruf zählt:
    `POST /join` zählt jeden, Nachfragen und Anmelden nur Fehlgriffe (siehe
    dort). Geprüft wird aber immer **vor** dem Nachsehen — sonst liefe das
    Raten hinter der Sperre einfach weiter.
    """

    def __init__(self, store: Store) -> None:
        self.store = store

    def check(self, scope: str, origin: str, code: str) -> None:
        now = time.time()
        with self.store.connect() as v:
            for limit, window in LIMITS:
                rows = v.execute(
                    "SELECT at FROM throttle WHERE scope = ? AND origin = ? AND at > ? ORDER BY at",
                    (scope, origin, now - window),
                ).fetchall()
                if len(rows) >= limit:
                    # Frei wird es, wenn der älteste Eintrag im Fenster herausfällt,
                    # der die Grenze gerade noch ausmacht.
                    free_at = float(rows[len(rows) - limit]["at"]) + window
                    raise f.Error(code, {"seconds": max(1, round(free_at - now))}, status=429)

    def note(self, scope: str, origin: str) -> None:
        now = time.time()
        with self.store.connect() as v:
            # Aufräumen beim Schreiben: Was älter als das längste Fenster ist,
            # zählt nie wieder und wandert sonst in jede Sicherung der Datei mit.
            v.execute("DELETE FROM throttle WHERE at < ?", (now - LIMITS[-1][1],))
            v.execute(
                "INSERT INTO throttle (scope, origin, at) VALUES (?, ?, ?)", (scope, origin, now)
            )


@dataclass(frozen=True, slots=True)
class JoinRequest:
    """Eine offene Anfrage, so wie der Verwalter sie sieht."""

    token: str
    name: str
    color: str
    want: tuple[str, ...]
    device_name: str
    device_kind: str
    from_where: str
    created: float
    valid_until: float

    @property
    def remaining_s(self) -> float:
        return max(0.0, self.valid_until - time.time())


@dataclass(frozen=True, slots=True)
class Answer:
    """Was das anfragende Gerät beim Nachfragen erfährt."""

    state: str
    """`pending`, `declined` oder `approved`."""
    remaining_s: float = 0.0
    device_token: str = ""
    mark: str = ""
    person: Person | None = None


class Joins:
    def __init__(self, store: Store, people: People) -> None:
        self.store = store
        self.people = people
        self.throttle = Throttle(store)

    # ── Die Anfrage ─────────────────────────────────────────────────────────

    def ask(
        self,
        name: str,
        color: str,
        want: list[str],
        device_name: str,
        device_kind: str,
        from_where: str,
    ) -> JoinRequest:
        """Eine Anfrage annehmen — nicht erledigen.

        **Jeder Aufruf zählt für die Drossel**, auch einer, der danach an einem
        leeren Namen scheitert: Sonst ließe sich die Ablage mit ungültigen
        Rümpfen beschäftigen, ohne je an die Grenze zu stoßen.

        **Kein Namensorakel:** Ob es „Selin“ schon gibt, sagt die Antwort nicht.
        Die Kollision fällt erst bei der Freigabe auf, und zwar dem Verwalter.
        """
        self.throttle.check("join", from_where, "join.too_often")
        self.throttle.note("join", from_where)

        # Ein leerer Haushalt hat niemanden, der freigeben könnte. Dürfte `/join`
        # hier die erste Person anlegen, gehörte das Haus dem, der zuerst im
        # WLAN ist — genau das, wogegen `web/firstrun.py` gebaut wurde.
        if self.people.is_empty():
            raise f.Error("setup.required", status=409)

        clean = " ".join(name.split())[:60]
        if not clean:
            raise f.Error("join.bad_name", status=422)
        if not _FARBE.fullmatch(color):
            raise f.Error("join.bad_color", status=422)
        wants = [w for w in dict.fromkeys(want) if w in KNOWN_WANTS]
        if not wants:
            raise f.Error("join.no_want", status=422)

        now = time.time()
        token = invite_token()
        with self.store.connect() as v:
            # Abgelaufenes geht hier, mit einer Stunde Gnadenfrist — dieselbe
            # Regel wie bei `pending`: Eine gerade abgelaufene Anfrage soll noch
            # sagen können, warum sie nicht mehr gilt.
            v.execute("DELETE FROM join_request WHERE valid_until < ?", (now - 3600,))
            offen = v.execute(
                "SELECT COUNT(*) AS n FROM join_request WHERE decided IS NULL AND valid_until >= ?",
                (now,),
            ).fetchone()["n"]
            if offen >= MAX_OPEN:
                raise f.Error("join.too_many", {"max": MAX_OPEN}, status=409)
            v.execute(
                "INSERT INTO join_request (token, name, color, want, device_name, device_kind, "
                "from_where, created, valid_until) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    token,
                    clean,
                    color.upper(),
                    ",".join(wants),
                    device_name[:60],
                    device_kind[:20],
                    from_where,
                    now,
                    now + REQUEST_TTL_S,
                ),
            )
        return JoinRequest(
            token,
            clean,
            color.upper(),
            tuple(wants),
            device_name[:60],
            device_kind[:20],
            from_where,
            now,
            now + REQUEST_TTL_S,
        )

    # ── Nachfragen ──────────────────────────────────────────────────────────

    def poll(self, token: str, from_where: str) -> Answer:
        """Wie steht es um die Anfrage — und nach der Freigabe: das Merkmal.

        **Die Drossel zählt hier nur Fehlgriffe.** Die App fragt alle 15
        Sekunden nach, solange der Wartebildschirm offen ist — das sind 240 in
        der Stunde, und „drei je Stunde“ auf jeden Aufruf machte den Weg
        unbenutzbar. Was die Drossel hier verhindern soll, ist Raten, und Raten
        besteht aus Fehlgriffen.

        **Unbekannt und abgelaufen sind dieselbe Antwort** (`404 join.unknown`),
        abgelehnt dagegen nicht: „nichts passiert“ von „nein“ zu unterscheiden
        ist der ganze Sinn der Freigabe.

        Das Gerät entsteht **beim ersten Abholen**, nicht bei der Freigabe: Ein
        Gerät, das nie abgeholt wird, stünde sonst als Leiche in der Liste.
        """
        self.throttle.check("join_poll", from_where, "join.too_often")
        now = time.time()
        # Mit Sperre ab dem Lesen: siehe `enroll` — dasselbe Muster, derselbe Wettlauf.
        with self.store.connect(immediate=True) as v:
            z = v.execute("SELECT * FROM join_request WHERE token = ?", (token,)).fetchone()
            if z is None or z["valid_until"] < now:
                z = None
            elif z["decided"] is None:
                return Answer("pending", remaining_s=z["valid_until"] - now)
            elif z["declined"]:
                return Answer("declined")
            else:
                p = v.execute(
                    f"SELECT {PERSON_COLUMNS}, p.mark, "
                    f"{OWN_DEVICES_JOINED} AS own {PERSON_FROM} "
                    "WHERE p.id = ?",
                    (z["person_id"],),
                ).fetchone()
                # Ein Kind trägt keine Marke (Entscheidung 14) und bekommt sein
                # Gerät trotzdem: Die Freigabe war der Akt des Verwalters, wie das
                # Koppeln am Gerät. Das Gerät kam dann über keine Marke.
                if p is not None and (p["mark"] or not p["own"]):
                    # **Das `UPDATE` zuerst**: Es nimmt die Schreibsperre, und
                    # nur wer die Zeile von „nicht abgeholt“ auf „abgeholt“
                    # dreht, legt das Gerät an. Zwei gleichzeitige Nachfragen
                    # ergeben so ein Gerät und nicht zwei.
                    erstes = v.execute(
                        "UPDATE join_request SET fetched = ?, valid_until = MIN(valid_until, ?) "
                        "WHERE token = ? AND fetched IS NULL",
                        (now, now + FETCH_GRACE_S, token),
                    ).rowcount
                    if erstes:
                        secret, device_id = insert_device(
                            v,
                            person_id=p["id"],
                            name=z["device_name"] or "Device",
                            kind=z["device_kind"],
                            from_where=from_where or z["from_where"],
                            via_mark=mark_fingerprint(p["mark"]) if p["mark"] else None,
                        )
                        v.execute(
                            "UPDATE join_request SET device_id = ? WHERE token = ?",
                            (device_id, token),
                        )
                    else:
                        g = v.execute(
                            "SELECT token FROM device WHERE id = ?", (z["device_id"],)
                        ).fetchone()
                        # Das Gerät ist inzwischen widerrufen: Dann gibt es hier
                        # nichts mehr abzuholen, und die Antwort ist dieselbe wie
                        # für eine unbekannte Marke.
                        secret = str(g["token"]) if g is not None else ""
                    if secret:
                        return Answer(
                            "approved",
                            device_token=secret,
                            mark=str(p["mark"] or ""),
                            person=person_from(p),
                        )
        self.throttle.note("join_poll", from_where)
        raise f.Error("join.unknown", status=404)

    # ── Die Seite des Verwalters ────────────────────────────────────────────

    def open_requests(self) -> list[JoinRequest]:
        now = time.time()
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT * FROM join_request WHERE decided IS NULL AND valid_until >= ? "
                "ORDER BY created",
                (now,),
            ).fetchall()
        return [_anfrage(z) for z in rows]

    def approve(
        self,
        token: str,
        role: str,
        name: str | None = None,
        pin: str | None = None,
        console: bool | None = None,
    ) -> tuple[JoinRequest, Person]:
        """Die Person anlegen, ihre Marke ausgeben, die Anfrage schließen.

        **Ohne PIN** (Entscheidung 8.1 a): Der Weg dieser Person in den Haushalt
        ist allein die Personenmarke. `People.sign_in` weist ihren leeren
        Abdruck deshalb als 401 ab.

        Die PIN des Freigebenden prüft der Weg davor — vor allem anderen, sonst
        kostet jeder Rateversuch die ganze Arbeit hier.

        **Ein Kind bekommt keine Marke** (Entscheidung 14 des Besitzers vom
        24.09.2026): Sein Gerät koppelt der Verwalter, und eine Marke im Profil
        hieße, dass es weitere Geräte selbst anmeldet.

        Ein Verwalter bekommt dagegen eine PIN (`pin`, Entscheidung 15): Ohne
        sie könnte er selbst nie freigeben und käme nicht in den Leitstand.
        """
        now = time.time()
        with self.store.connect() as v:
            z = v.execute(
                "SELECT * FROM join_request WHERE token = ? AND decided IS NULL "
                "AND valid_until >= ?",
                (token, now),
            ).fetchone()
        if z is None:
            raise f.Error("join.unknown", status=404)
        anfrage = _anfrage(z)
        clean = " ".join((name or "").split())[:60] or anfrage.name
        person = self.people.create(clean, role, pin, anfrage.color, console=console)
        if person.may("own_devices"):
            self.issue_mark(person.id)
        with self.store.connect() as v:
            v.execute(
                "UPDATE join_request SET decided = ?, person_id = ?, valid_until = ? "
                "WHERE token = ?",
                (now, person.id, now + DECIDED_TTL_S, token),
            )
        return anfrage, person

    def decline(self, token: str) -> JoinRequest:
        """Nein sagen — **ohne Begründung**, und das ist Absicht.

        Ein Begründungsfeld würde zum Nachrichtenkanal von einem unangemeldeten
        Fremden in den Haushalt und zurück.
        """
        now = time.time()
        with self.store.connect() as v:
            z = v.execute(
                "SELECT * FROM join_request WHERE token = ? AND decided IS NULL "
                "AND valid_until >= ?",
                (token, now),
            ).fetchone()
            if z is None:
                raise f.Error("join.unknown", status=404)
            v.execute(
                "UPDATE join_request SET decided = ?, declined = 1, valid_until = ? "
                "WHERE token = ?",
                (now, now + DECIDED_TTL_S, token),
            )
        return _anfrage(z)

    # ── Die Personenmarke ───────────────────────────────────────────────────

    def issue_mark(self, person_id: str) -> tuple[str, bool]:
        """Die Marke einer Person — die vorhandene oder eine neue.

        Gibt `(marke, neu)` zurück. Im Klartext wie `device.token`
        (Entscheidung 8.5): `GET /household/backup` liefert ohnehin jedes
        Merkmal aus, ein Abdruck daneben wäre eine zweite Art, dasselbe zu tun.
        """
        with self.store.connect() as v:
            holder = v.execute(
                f"SELECT {OWN_DEVICES_SQL} AS own FROM person WHERE id = ?", (person_id,)
            ).fetchone()
            if holder is None:
                raise f.Error("household.unknown_person", {"id": person_id}, status=404)
            # **Kein Kind, auch nicht für sich selbst** (Entscheidung 14) —
            # dieselbe Regel wie `invite.not_for_children` in `devices.py`: Ein
            # Kindergerät koppelt der Verwalter am Gerät.
            # Since 09.11.2026: the role's right `own_devices`.
            if not holder["own"]:
                raise f.Error("mark.not_for_children", {"id": person_id}, status=403)
            neu = v.execute(
                "UPDATE person SET mark = ? WHERE id = ? AND mark IS NULL",
                (device_token(), person_id),
            ).rowcount
            z = v.execute("SELECT mark FROM person WHERE id = ?", (person_id,)).fetchone()
        return str(z["mark"]), bool(neu)

    def renew_mark(self, person_id: str) -> tuple[str | None, int]:
        """Die Marke widerrufen und eine neue ausgeben. Gibt `(neue, geräte)` zurück.

        **Jedes Gerät, das über die alte Marke kam, fällt mit** (Entscheidung
        8.4). Wer das Teilen eines Profils beendet, dem reicht ein neuer
        Schlüssel nicht: Der fremde Fernseher hat sich mit dem alten schon
        angemeldet, und diese Anmeldung bliebe sonst gültig. Die eigenen Geräte
        melden sich mit der neuen Marke aus dem Profil still wieder an.

        Geräte, die **nicht** über die Marke kamen (gekoppelt, eingeladen, per
        PIN angemeldet), bleiben: Die hat jemand anders hereingelassen, und
        über sie entscheidet `DELETE /household/devices/{id}` einzeln.

        In **einer** Verbindung: Zwischen „Geräte weg“ und „neue Marke“ darf
        kein Anmelden mit der alten mehr durchrutschen.
        """
        neu = device_token()
        with self.store.connect(immediate=True) as v:
            z = v.execute(
                f"SELECT mark, {OWN_DEVICES_SQL} AS own FROM person WHERE id = ?", (person_id,)
            ).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": person_id}, status=404)
            weg = 0
            if z["mark"]:
                weg = v.execute(
                    "DELETE FROM device WHERE via_mark = ?", (mark_fingerprint(z["mark"]),)
                ).rowcount
            # Ein Kind bekommt keine neue (Entscheidung 14): Widerrufen ja —
            # eine Marke aus der Zeit, als es erwachsen war, soll fallen können.
            ersatz = neu if z["own"] else None
            v.execute("UPDATE person SET mark = ? WHERE id = ?", (ersatz, person_id))
        return ersatz, weg

    def enroll(self, mark: str, name: str, kind: str, from_where: str) -> tuple[str, Person]:
        """Die Marke gegen ein Gerätemerkmal tauschen. Das Gerät gehört der Person.

        **Unbekannt und widerrufen sind dieselbe Antwort** — kein Orakel dafür,
        ob eine Marke einmal gegolten hat. Die Drossel zählt nur Fehlgriffe:
        Nach einem Widerruf melden sich alle eigenen Geräte einer Person neu an,
        oft hinter derselben Adresse, und das ist kein Angriff.
        """
        self.throttle.check("enroll", from_where, "enroll.too_often")
        # **Lesen und Anlegen in einer Transaktion mit Schreibsperre.** Sonst
        # kann ein Widerruf zwischen „Marke gefunden“ und „Gerät angelegt“
        # durchlaufen, und das Gerät trägt den Abdruck der alten Marke — kein
        # späterer Widerruf fände es mehr (Gegenprüfung vom 24.09.2026).
        with self.store.connect(immediate=True) as v:
            p = (
                v.execute(
                    # Only with `own_devices`: an old mark does not sign in a
                    # role that does not (or no longer) hold it.
                    f"SELECT {PERSON_COLUMNS}, "
                    f"{OWN_DEVICES_JOINED} AS own {PERSON_FROM} "
                    "WHERE p.mark = ?",
                    (mark,),
                ).fetchone()
                if mark
                else None
            )
            if p is not None and not p["own"]:
                p = None
            if p is not None:
                # Unter derselben Sperre wie das Anlegen: Zwei gleichzeitige
                # Anmeldungen können den Deckel so nicht gemeinsam überspringen.
                schon = v.execute(
                    "SELECT COUNT(*) AS n FROM device WHERE via_mark = ?",
                    (mark_fingerprint(mark),),
                ).fetchone()["n"]
                if schon >= MAX_DEVICES_PER_MARK:
                    raise f.Error(
                        "enroll.too_many_devices", {"max": MAX_DEVICES_PER_MARK}, status=409
                    )
                secret, _ = insert_device(
                    v,
                    person_id=p["id"],
                    name=name[:60] or "Device",
                    kind=kind[:20],
                    from_where=from_where,
                    via_mark=mark_fingerprint(mark),
                )
                return secret, person_from(p)
        self.throttle.note("enroll", from_where)
        raise f.Error("enroll.unknown_mark", status=401)


def _anfrage(z: sqlite3.Row) -> JoinRequest:
    return JoinRequest(
        z["token"],
        z["name"],
        z["color"],
        tuple(w for w in str(z["want"]).split(",") if w),
        z["device_name"],
        z["device_kind"],
        z["from_where"],
        z["created"],
        z["valid_until"],
    )
