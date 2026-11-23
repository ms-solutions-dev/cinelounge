"""Die Quellen des Haushalts — welche Adressen er nach Portalen fragt.

**There is no official index.** Whoever enters a source here decides for
themselves who they believe. The service keeps no directory of foreign content;
it fetches what it is told, checks the shape and says what it
gefunden hat.

**The cache is not a speed trick.** Whatever was fetched successfully last
stays put — a source that is not answering right now must not empty the
marketplace. Otherwise a network outage looks like a withdrawn portal, and
whoever has seen that twice stops trusting the list
mehr.

That is why the cache always carries **when** it was made and **what** went
wrong on the last attempt. An empty cache and a stale one are two different
things, and the interface has to be able to say both.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Final

import requests

from cinelounge.core import errors as f
from cinelounge.market import index as index_lesen
from cinelounge.market.storage import Storage

#: How long a source is waited for.
#:
#: Short, and deliberately so: the marketplace is opened while somebody is
#: sitting in front of it. A source that takes ten seconds has not answered for
#: that moment — its cache steps in.
TIMEOUT_S: Final = 8.0

#: How large an index may be at most.
#:
#: An index is a list; whoever sends a megabyte is sending something else. The
#: limit stands here and not in the hope that nobody will.
MAX_BYTES: Final = 2 * 1024 * 1024


@dataclass(frozen=True, slots=True)
class Source:
    url: str
    name: str
    added: float
    last_fetch: float | None
    last_error: str
    cached: str

    @property
    def stale_s(self) -> float | None:
        """Wie alt der Zwischenspeicher ist — `None`, wenn es keinen gibt."""
        return None if not self.last_fetch else max(0.0, time.time() - self.last_fetch)


class Sources:
    def __init__(self, store: Storage) -> None:
        self.store = store

    # ── Verwalten ───────────────────────────────────────────────────────────

    def add(self, url: str, name: str = "") -> Source:
        roh = url.strip()
        if not roh.startswith(("https://", "http://")):
            raise f.Error("market.bad_url", {"url": roh[:60]}, status=422)
        now = time.time()
        with self.store.connect() as v:
            v.execute(
                "INSERT INTO market_source (url, name, added) VALUES (?, ?, ?) "
                "ON CONFLICT(url) DO UPDATE SET name = excluded.name",
                (roh, name.strip()[:60], now),
            )
        return Source(roh, name.strip()[:60], now, None, "", "")

    def remove(self, url: str) -> bool:
        with self.store.connect() as v:
            geloescht: int = v.execute("DELETE FROM market_source WHERE url = ?", (url,)).rowcount
            return geloescht > 0

    def list_all(self) -> list[Source]:
        with self.store.connect() as v:
            rows = v.execute("SELECT * FROM market_source ORDER BY added").fetchall()
        return [
            Source(
                z["url"],
                z["name"] or "",
                z["added"],
                z["last_fetch"],
                z["last_error"] or "",
                z["cached_json"] or "",
            )
            for z in rows
        ]

    # ── Holen ───────────────────────────────────────────────────────────────

    def fetch(self, url: str) -> tuple[dict[str, Any], list[str]]:
        """Fetch one source and read its index.

        **The cache is replaced only on success.** What was read once stays
        until something better arrives — and "better" here means: an answer
        that could be read.

        Returns `(index, complaints)`. On failure the reason is in
        `complaints` and the index comes out of the cache.
        """
        try:
            antwort = requests.get(
                url,
                timeout=TIMEOUT_S,
                headers={"Accept": "application/json"},
                stream=True,
            )
            antwort.raise_for_status()
            # **Not `answer.text`.** That loads whatever comes — and what
            # comes is decided by the other side. An index is a list; whoever
            # sends a gigabyte is sending something else.
            roh = antwort.raw.read(MAX_BYTES + 1, decode_content=True)
            if len(roh) > MAX_BYTES:
                raise ValueError(f"index larger than {MAX_BYTES} bytes")
            text = roh.decode("utf-8", "replace")
        except Exception as err:  # every reason belongs in the list
            grund = type(err).__name__ + ": " + str(err)[:120]
            self._merken_fehler(url, grund)
            gespeichert = self._cached(url)
            if not gespeichert:
                return index_lesen._leer(), [grund]
            d, klagen = index_lesen.read(gespeichert)
            return d, [grund, *klagen]

        d, klagen = index_lesen.read(text)
        # **An index with complaints is cached too**, as long as it could be
        # read: the good entries in it are real, and at the next network outage
        # they beat nothing.
        self._merken_erfolg(url, text, klagen)
        return d, klagen

    def fetch_all(self) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
        """All sources. Returns the entries and, per source, its complaints.

        Every entry carries `source` — which source named it. Without that,
        with two sources offering the same portal there would be no way to say
        which one is meant, and that is exactly the question the marketplace
        has to answer.
        """
        alles: list[dict[str, Any]] = []
        klagen: dict[str, list[str]] = {}
        for quelle in self.list_all():
            d, k = self.fetch(quelle.url)
            if k:
                klagen[quelle.url] = k
            for e in d["portals"]:
                alles.append({**e, "source": quelle.url, "source_name": quelle.name})
        return alles, klagen

    # ── Zwischenspeicher ────────────────────────────────────────────────────

    def _cached(self, url: str) -> str:
        with self.store.connect() as v:
            z = v.execute("SELECT cached_json FROM market_source WHERE url = ?", (url,)).fetchone()
        return (z["cached_json"] or "") if z else ""

    def _merken_erfolg(self, url: str, text: str, klagen: list[str]) -> None:
        with self.store.connect() as v:
            v.execute(
                "UPDATE market_source SET cached_json = ?, last_fetch = ?, last_error = ? "
                "WHERE url = ?",
                (text, time.time(), "; ".join(klagen)[:400], url),
            )

    def _merken_fehler(self, url: str, grund: str) -> None:
        with self.store.connect() as v:
            v.execute("UPDATE market_source SET last_error = ? WHERE url = ?", (grund, url))
