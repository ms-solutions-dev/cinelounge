"""Trust anchors and signatures — who the household believes.

**There is no official index, and that is the heart of the design.** Keeping a
directory of foreign content is a different thing from expressing trust.
Whoever enters a source here decides for themselves who they believe; the
service only supplies the tool — and says honestly what it checked and what it
did not.

**Three levels, and the middle one is the important one:**

| | what it means |
|---|---|
| `signed` | A signature that verifies against a stored anchor |
| `unsigned` | No signature. Not forbidden — but not claimed either |
| `bad` | A signature that does **not** verify |

`unsigned` and `bad` are two different things, and throwing them together
would be the most expensive mistake in this module. A portal without a
signature is one nobody vouched for. A portal with a wrong signature is one
where somebody tried and it does not add up — that is an attack or a fault,
and both deserve to be seen.

**Ed25519.** Short keys, short signatures, no parameter choices you can get
wrong. `pynacl` has been in the dependencies from the start, waiting for this
module.

**What a signature covers: the checksum, not the file.** What gets signed is
the canonical entry from the index — id, version and `sha256`. Swap the file
and its checksum changes; change the checksum in the index and the signature
breaks. Both are noticed, and neither costs a download.
"""

from __future__ import annotations

import base64
import hashlib
import json
import time
from dataclasses import dataclass
from typing import Any, Final

from cinelounge.core import errors as f
from cinelounge.market.storage import Storage

#: The three levels an entry can be vouched for at.
SIGNED: Final = "signed"
UNSIGNED: Final = "unsigned"
BAD: Final = "bad"


@dataclass(frozen=True, slots=True)
class Anchor:
    """A public key this household believes."""

    fingerprint: str
    name: str
    public_key: str
    added: float


def fingerprint_of(public_key: str) -> str:
    """A key's fingerprint — `sha256`, shortened to 16 characters.

    **Shortened because it gets read out loud.** Nobody comparing an anchor by
    hand compares 64 characters; 16 hexadecimal ones are 64 bits and ample for
    this purpose. Verification compares the key itself anyway — the fingerprint
    is the identifier for humans.
    """
    return hashlib.sha256(public_key.strip().encode()).hexdigest()[:16]


def signing_payload(entry: dict[str, Any]) -> bytes:
    """What gets signed — canonical, so both sides build the same bytes.

    **Three fields only.** Id, version, checksum. The rest of the entry (name,
    description, capabilities) may change without breaking the signature: it is
    information, not a promise. What is promised is "under this id and this
    version lies exactly this file".

    `sort_keys` and `separators` are not style but half the job: two sides that
    serialise the same dictionary differently get different signatures — and
    the fault then looks like a wrong key.
    """
    kern = {
        "id": str(entry.get("id", "")),
        "version": str(entry.get("version", "")),
        "sha256": str(entry.get("sha256", "")).lower(),
    }
    return json.dumps(kern, sort_keys=True, separators=(",", ":")).encode()


class Trust:
    def __init__(self, store: Storage) -> None:
        self.store = store

    # ── Managing anchors ────────────────────────────────────────────────────

    def add(self, public_key: str, name: str = "") -> Anchor:
        """Store an anchor. The same key twice is not an error.

        It merely takes on its new name — whoever enters an anchor a second
        time does not mean "one more" but "yes, this one".
        """
        roh = public_key.strip()
        if not roh:
            raise f.Error("trust.empty_key", status=422)
        try:
            _lade_schluessel(roh)
        except Exception:  # the reason belongs to the caller
            raise f.Error("trust.bad_key", {"key": roh[:24]}, status=422) from None

        abdruck = fingerprint_of(roh)
        with self.store.connect() as v:
            v.execute(
                "INSERT INTO trust_anchor (fingerprint, name, public_key, added) "
                "VALUES (?, ?, ?, ?) "
                "ON CONFLICT(fingerprint) DO UPDATE SET name = excluded.name",
                (abdruck, name.strip()[:60], roh, time.time()),
            )
        return Anchor(abdruck, name.strip()[:60], roh, time.time())

    def remove(self, fingerprint: str) -> bool:
        with self.store.connect() as v:
            geloescht: int = v.execute(
                "DELETE FROM trust_anchor WHERE fingerprint = ?", (fingerprint,)
            ).rowcount
            return geloescht > 0

    def list_all(self) -> list[Anchor]:
        with self.store.connect() as v:
            rows = v.execute("SELECT * FROM trust_anchor ORDER BY added").fetchall()
        return [Anchor(z["fingerprint"], z["name"], z["public_key"], z["added"]) for z in rows]

    # ── Verifying ───────────────────────────────────────────────────────────

    def check(self, entry: dict[str, Any]) -> tuple[str, str]:
        """Verify one entry. Returns `(level, fingerprint)`.

        The fingerprint is only filled in for `signed` — with `bad` it says
        nothing, because who signed is precisely what is *not* established.

        **No exception on `bad`.** A marketplace that aborts at the first rotten
        entry shows nothing at all; the operator should see the list and, in it,
        which entry is stuck.
        """
        signatur = str(entry.get("signature") or "").strip()
        if not signatur:
            return UNSIGNED, ""

        try:
            roh = base64.b64decode(signatur, validate=True)
        except Exception:
            return BAD, ""

        nachricht = signing_payload(entry)
        for anker in self.list_all():
            try:
                _lade_schluessel(anker.public_key).verify(nachricht, roh)
            except Exception:  # jeder Fehlschlag ist derselbe
                continue
            return SIGNED, anker.fingerprint
        return BAD, ""


def _lade_schluessel(public_key: str) -> Any:
    """A key from Base64. Raises if it is not one.

    The import sits inside the function rather than at the top: `pynacl` brings
    a compiled extension along, and the rest of this module — fingerprints,
    managing the anchors — should run where that is missing too.
    """
    from nacl.signing import VerifyKey  # siehe Docstring

    return VerifyKey(base64.b64decode(public_key.strip(), validate=True))
