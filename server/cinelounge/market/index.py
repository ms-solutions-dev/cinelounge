"""A source's index — read without fetching a line of portal code.

A source is an address that serves a JSON file: a list of portals with version,
checksum and — perhaps — a signature. That is all it is, and all it is meant to
be. Whoever enters a source does not enter a service but a file.

**The same strictness as with the manifest**, and for the same reason: the
index is the surface a stranger writes on. `api: 1`, unknown keys stop it, every
entry is checked on its own.

**One broken entry does not take the index with it.** Unlike the manifest,
where one folder is one portal, dozens live in one file here. Whoever stops at
the third line loses the rest — so the reader collects the reasons and delivers
both: what was read and what was not.

**What does not happen here: downloading.** The index names addresses and
checksums; whether a file lies behind one and whether it matches is decided at
install time. A marketplace that downloads while merely displaying fetches an
archive for every tile.
"""

from __future__ import annotations

import json
from typing import Any, Final

from cinelounge.portalworks import extension

#: Welche Fassungen dieses Indexformats dieser Server liest.
API_VERSIONS: Final = frozenset({1})

#: Allowed keys at the top level.
TOP_KEYS: Final = frozenset({"api", "name", "description", "portals"})

#: Allowed keys per entry.
#:
#: `kind`, `capabilities` and `limits` appear here **and** in the portal's own
#: manifest. That is not an oversight: the index has to name them so the tile
#: can show something without fetching the archive. At install time the
#: manifest wins — whoever claims otherwise in the index was advertising.
#:
#: **Plus what an extension publishes** (`entry_keys()`): a manifest key an
#: extension registered with `public_json` may stand in an entry too, read by
#: the same parser. The core itself names no such key — `net` was one until the
#: extension seam took it out; the tile shows it only where it is registered.
ENTRY_KEYS: Final = frozenset(
    {
        "id",
        "name",
        "description",
        "version",
        "url",
        "sha256",
        "signature",
        "kind",
        "capabilities",
        "limits",
        "adult",
        "homepage",
    }
)


def entry_keys() -> frozenset[str]:
    """The core's keys and every published manifest field of the extensions."""
    return ENTRY_KEYS | {s.key for s in extension.FIELDS if s.public_json}


#: How long a checksum is, and what it is made of.
SHA256_LEN: Final = 64


def read(roh: str | bytes) -> tuple[dict[str, Any], list[str]]:
    """Read one index. Returns `(index, complaints)` — and never raises.

    `index` carries `name`, `description` and `portals`; `complaints` names
    every entry that could not be read, with its reason.

    **Never raises**, because the caller holds one source among several: a
    broken one must not take the others with it, and the interface should show
    the reason instead of an empty list.
    """
    klagen: list[str] = []
    try:
        d = json.loads(roh)
    except Exception as err:
        return _leer(), ["index unreadable: " + str(err)[:120]]

    if not isinstance(d, dict):
        return _leer(), ["index is not a mapping"]

    unknown = sorted(set(d) - TOP_KEYS)
    if unknown:
        return _leer(), ["unknown keys: " + ", ".join(unknown)]

    roh_api = d.get("api", 0)
    if isinstance(roh_api, bool) or not isinstance(roh_api, int):
        return _leer(), ["api is not a whole number: " + repr(roh_api)]
    if roh_api not in API_VERSIONS:
        return _leer(), [f"api {roh_api} not supported (this server speaks {sorted(API_VERSIONS)})"]

    eintraege = d.get("portals")
    if eintraege is None:
        eintraege = []
    if not isinstance(eintraege, list):
        return _leer(), ["portals must be a list, not " + type(eintraege).__name__]

    gut: list[dict[str, Any]] = []
    gesehen: set[str] = set()
    for i, e in enumerate(eintraege):
        grund = _pruefe_eintrag(e, gesehen)
        if grund:
            kennung = e.get("id") if isinstance(e, dict) else None
            klagen.append(f"entry {kennung or i}: {grund}")
            continue
        gesehen.add(str(e["id"]))
        gut.append(_normieren(e))

    return {
        "name": str(d.get("name") or ""),
        "description": str(d.get("description") or ""),
        "portals": gut,
    }, klagen


def _leer() -> dict[str, Any]:
    return {"name": "", "description": "", "portals": []}


def _pruefe_eintrag(e: Any, gesehen: set[str]) -> str | None:
    """What is wrong with an entry — or `None`."""
    if not isinstance(e, dict):
        return "not a mapping"

    unknown = sorted(set(e) - entry_keys())
    if unknown:
        return "unknown keys: " + ", ".join(unknown)

    for pflicht in ("id", "version", "url", "sha256"):
        if not str(e.get(pflicht) or "").strip():
            return "missing: " + pflicht

    kennung = str(e["id"]).strip()
    # **The same shape as a folder name**, because that is exactly what it
    # becomes at install time. An entry called `../../etc` is not a portal but
    # an attempt.
    if not kennung.replace("-", "").replace("_", "").isalnum():
        return "id is not a plain name: " + kennung[:40]
    if kennung in gesehen:
        return "listed twice: " + kennung

    pruefsumme = str(e["sha256"]).strip().lower()
    if len(pruefsumme) != SHA256_LEN or any(c not in "0123456789abcdef" for c in pruefsumme):
        return "sha256 is not a sha256: " + pruefsumme[:20]

    adresse = str(e["url"]).strip()
    # **No `file:` and no bare scheme.** A source lives on the network; an
    # entry pointing at the server's file system would be a way to "install"
    # arbitrary files.
    if not adresse.startswith(("https://", "http://")):
        return "url is neither https nor http: " + adresse[:40]

    for feld in ("capabilities", "limits"):
        if feld in e and not isinstance(e[feld], list):
            return f"{feld} must be a list, not " + type(e[feld]).__name__
    # An extension's field with its own parser — the same sentence as in the
    # manifest, so the author reads one complaint in both places.
    for spec in extension.FIELDS:
        if spec.public_json and spec.key in e and spec.key not in ENTRY_KEYS:
            _, klage = _feld(spec, e[spec.key])
            if klage:
                return klage
    return None


def _feld(spec: extension.FieldSpec, raw: Any) -> tuple[Any, str | None]:
    """One extension field through its parser; a parser that raises complains."""
    try:
        return spec.parse(raw)
    except Exception as err:
        return None, f"{spec.key}: {type(err).__name__}"


def _normieren(e: dict[str, Any]) -> dict[str, Any]:
    """One entry as read, with everything the tile needs."""
    return {
        "id": str(e["id"]).strip(),
        "name": _sprachfeld(e.get("name"), str(e["id"]).strip()),
        "description": _sprachfeld(e.get("description"), ""),
        "version": str(e["version"]).strip(),
        "url": str(e["url"]).strip(),
        "sha256": str(e["sha256"]).strip().lower(),
        "signature": str(e.get("signature") or "").strip(),
        "kind": str(e.get("kind") or ""),
        "capabilities": [str(x) for x in (e.get("capabilities") or [])],
        "limits": list(e.get("limits") or []),
        "adult": bool(e.get("adult", False)),
        "homepage": str(e.get("homepage") or ""),
        # The published extension fields, with their default when missing —
        # as `Manifest.as_json()` hands them out. Never over a core key.
        **{
            spec.key: _feld(spec, e.get(spec.key))[0]
            for spec in extension.FIELDS
            if spec.public_json and spec.key not in ENTRY_KEYS
        },
    }


def _sprachfeld(value: Any, fallback: str) -> dict[str, str]:
    """`name: Foo` or `name: {de: …}` — as in the manifest.

    The short form counts as `en`, because that is the fallback language.
    Unlike the manifest, what is not a language tag is **not** rejected here: an
    index is advertising, and a broken label must not take a portal out of the
    list.
    """
    if isinstance(value, str) and value.strip():
        return {"en": value.strip()}
    if isinstance(value, dict):
        out = {str(k): str(v) for k, v in value.items() if isinstance(v, str) and v.strip()}
        if out:
            return out
    return {"en": fallback} if fallback else {}
