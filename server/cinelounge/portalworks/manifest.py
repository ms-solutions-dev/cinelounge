"""A portal's manifest — read without executing a single line of portal code.

**Unknown keys are an error.** The old bridge ignores them silently, and that
led, measured, to `durchreichen: true` sitting uselessly in two `portal.yml`
files since 29 Aug — with a long justification beside it that concerns nobody
any more. A manifest that quietly does the wrong thing is worse than one that
stops.

**The fields are English.** This is the only surface strangers touch, and it
freezes the moment it is published.

**What `api: 1` promises.** From here on the manifest is an interface and no
longer just a configuration file: once the app builds on it (A2), every change
is a migration across two repositories. That is why the loader checks not only
the top-level keys but **also those inside `settings` and `limits`** — a
`requiered: true` in the wrong place would otherwise be a mandatory field that
never applies, and exactly that kind of mistake cost six portals on
10 Sep 2026 without `/health` noticing a thing.

A manifest this server does not fully understand is called `broken`, not
`ready`. That is the whole rule.

## What extensions add

The keys below (`CORE_KEYS`) and the kind `native` are the core. An extension
(see `portalworks/extension.py`) may register further kinds, further keys
with their own parser, and further readiness checks; this module asks those
registers instead of a fixed list. A key no register knows is still an error.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Final

import yaml

from cinelounge.portalworks import extension, routes
from cinelounge.portalworks import native as _native  # noqa: F401 — registers `native`

API_VERSIONS: Final = frozenset({1})

CAPABILITIES: Final = frozenset(
    {
        "search",
        "seasons",
        "languages",
        "resolver",
        "login",
        "own_images",
        "subtitles",
        "paging",
    }
)

LIMITS: Final = frozenset({"drm_partial", "login_required", "region_locked"})

#: Which limits may carry a value — and which one.
#:
#: `region_locked` without countries is a warning without content: the app
#: cannot turn it into a sentence, and "this portal is blocked somewhere" helps
#: nobody.
LIMITS_WITH_VALUE: Final = frozenset({"region_locked"})

#: Allowed keys inside an entry under `settings`.
#:
#: `web/admin.py` reads `label` for the caption in the console, `required` is
#: checked by `_check_settings`. Whether a value is a secret is **derived** from
#: its name (`admin._geheim`) and deliberately does not appear here: two places
#: deciding what "secret" means would be one too many.
SETTING_KEYS: Final = frozenset({"key", "label", "value", "required"})

#: Which language tags a language field may carry.
#:
#: Exactly two lower-case letters (ISO 639-1). That leaves a foreign author
#: every language but catches `DE`, `german` and `dee` — a typo in a language
#: tag is otherwise a text that never appears.
LANGUAGE_PATTERN: Final = re.compile(r"^[a-z]{2}$")

#: Which country codes `region_locked` may carry.
#:
#: The same pattern as for languages and still a name of its own: ISO 639-1
#: (languages) and ISO 3166-1 (countries) are two standards that happen to look
#: alike. `tr` is both, `uk` only one of them — a shared pattern would be the
#: same trap as `modul` next to `module`.
#:
#: The shape is checked, not the list. Whoever puts an allow-list here will not
#: maintain it.
COUNTRY_PATTERN: Final = re.compile(r"^[a-z]{2}$")

#: The fallback language. **Mandatory in `name`.**
#:
#: `title()` falls back to it when the requested language is missing. Without
#: it a Turkish viewer facing a German manifest has nothing but the `id` — and
#: the manifest is the one surface strangers touch.
FALLBACK_LANGUAGE: Final = "en"

#: The three words `state` takes. `needs_setting` is not ready either, but it
#: is the one state the operator mends in the console with a value.
STATE_READY: Final = "ready"
STATE_NEEDS_SETTING: Final = "needs_setting"
STATE_BROKEN: Final = "broken"

#: Under which key the household stores the operator's route for a portal
#: (`portal.<id>._net`). See `Manifest.net_override` and `routes.py`.
NET_OVERRIDE_KEY: Final = "_net"

#: A key older manifests carried with the value `direct` — what every portal
#: does without a route. Accepted with that value and otherwise unknown, so a
#: portal folder from an older version still reads; an extension may register
#: the key with a meaning of its own.
_LEGACY_DIRECT_KEY: Final = "net"

#: The keys every server understands. Extensions add theirs through
#: `extension.register_field`; `allowed_keys()` is the union.
CORE_KEYS: Final = frozenset(
    {
        "api",
        "id",
        "name",
        "description",
        "kind",
        "capabilities",
        "limits",
        "settings",
        "enabled",
        "adult",
        "images",
    }
)


def allowed_keys() -> frozenset[str]:
    """The core keys plus every key a loaded extension registered."""
    return CORE_KEYS | {s.key for s in extension.FIELDS}


def kinds() -> frozenset[str]:
    """Every `kind:` this server can build — `native` plus the registered ones."""
    return frozenset(k.name for k in extension.KINDS)


#: What `images:` may say. `measure` is the default and right for every site that
#: delivers its thumbnails in one format; see `Manifest.images`.
IMAGES: Final = frozenset({"measure", "landscape", "portrait"})


@dataclass(slots=True)
class Manifest:
    id: str
    name: dict[str, str]
    kind: str
    api: int = 1
    description: dict[str, str] = field(default_factory=dict)
    capabilities: set[str] = field(default_factory=set)
    limits: list[Any] = field(default_factory=list)
    settings: list[dict[str, Any]] = field(default_factory=list)
    on_by_default: bool = False
    adult: bool = False
    """Adults only. **A property of the portal, not a setting.**

    It lives in the manifest because it belongs to the content and not to the
    household — and `web/portals.py` checks it before anything goes out. A
    child's device calling the route directly gets a 403, not the listing.
    """
    images: str = "measure"
    """How the portal's pictures are shaped: `measure`, `landscape` or `portrait`.

    `measure` asks each picture's host for its size, inside the child and
    within the call's deadline. A level with a great many different image
    hosts spends that deadline on measuring alone. A portal whose pictures are
    all one shape says so here, and nothing is measured. The app then gets
    `image_wide` on every entry and frames the detail column to match (16:9
    plate instead of 2:3).
    """
    extras: dict[str, Any] = field(default_factory=dict)
    """The values of the keys extensions registered (`extension.FieldSpec`).

    Every registered key has its entry here once the manifest was read — the
    parser's default when the key was missing, and the defaults of all keys
    when the manifest broke while being read. Without extensions it is empty.
    """
    folder: Path = field(default_factory=Path)
    broken_reason: str | None = None
    from_check: bool = field(default=False, repr=False)
    """Whether `broken_reason` came from a readiness check rather than from
    reading. Only such a defect is looked at again by `overlay()`: a value the
    household enters can mend a check, never a manifest that cannot be read."""
    missing_settings: list[str] = field(default_factory=list, repr=False)
    """The required settings that are empty — set by `_check_settings` only.

    **Not a defect of the portal but a task for the operator.** A portal with
    an empty required key cannot play, so it is not ready; but calling it
    `broken` sent people looking for a fault in the code, the night book and
    the status page, while all it needed was a value in the console. Non-empty
    exactly when `state` is `needs_setting`; `broken_reason` still carries the
    sentence, so everything that only asks `is_ready` stays as it was.
    """
    net_override: str | None = None
    """The operator's route for this portal (`routes.py`), or `direct`.

    **Household, not manifest.** Which way out a portal takes in this house is
    the operator's knowledge, and it would not survive the next portal version
    if it stood in the file. Stored as `portal.<id>._net` beside the settings;
    `overlay()` lays it here. `None` means: nobody chose, the default applies.
    """

    @property
    def is_ready(self) -> bool:
        return self.broken_reason is None

    @property
    def needs_setting(self) -> bool:
        """Not ready only because a required setting is empty."""
        return not self.is_ready and bool(self.missing_settings)

    @property
    def state(self) -> str:
        """`ready`, `needs_setting` or `broken` — the word every answer sends."""
        if self.is_ready:
            return STATE_READY
        return STATE_NEEDS_SETTING if self.needs_setting else STATE_BROKEN

    def refusal(self) -> dict[str, Any]:
        """The values of a `portal.broken` refusal: id, reason — and the keys.

        **The code stays `portal.broken`** for a missing setting too: the apps
        carry a sentence for that code and none for a new one, and a refusal
        without a sentence shows the bare code. What is new is `settings`, the
        empty keys, so a client that knows the field can point at them.
        """
        out: dict[str, Any] = {"id": self.id, "why": self.broken_reason}
        if self.needs_setting:
            out["state"] = STATE_NEEDS_SETTING
            out["settings"] = list(self.missing_settings)
        return out

    @property
    def exit_net(self) -> str:
        """The route the runner and the relay act on, or `direct`.

        The operator's choice wins; without one, a registered route provider
        may name one (`routes.choose`); otherwise the portal goes direct.
        """
        return self.net_override or routes.choose(self) or routes.DIRECT

    def title(self, language: str = "de") -> str:
        return self._in_sprache(self.name, language) or self.id

    def blurb(self, language: str = "de") -> str:
        """The description, through the same fallback chain as the name.

        It was missing, and that gap had consequences: `as_json` handed out the
        name translated and the description not at all. In the marketplace (B6)
        the description is what somebody picks a foreign portal by.
        """
        return self._in_sprache(self.description, language)

    @staticmethod
    def _in_sprache(feld: dict[str, str], language: str) -> str:
        """Requested language → `en` → whatever stands there first.

        The last step is deliberate: a manifest in one language only is still
        better than an empty field, and `en` is mandatory in `name` alone.
        """
        return feld.get(language) or feld.get(FALLBACK_LANGUAGE) or next(iter(feld.values()), "")

    def as_json(self, language: str = "de") -> dict[str, Any]:
        out = {
            "id": self.id,
            "name": self.title(language),
            "description": self.blurb(language),
            "kind": self.kind,
            "capabilities": sorted(self.capabilities),
            "limits": self.limits,
            "net_override": self.net_override,
            "exit_net": self.exit_net,
            "adult": self.adult,
            "state": self.state,
            "reason": self.broken_reason,
            "missing_settings": list(self.missing_settings),
        }
        # An extension's field goes out only when it says so, and never over
        # a core field.
        for spec in extension.FIELDS:
            if spec.public_json and spec.key in self.extras:
                out.setdefault(spec.key, self.extras[spec.key])
        return out


def _sprachfeld(
    value: Any, what: str, *, needs_fallback: bool = False
) -> tuple[dict[str, str], str | None]:
    """`name: Foo` or `name: {de: …, en: …}` — both are allowed.

    The short form counts as `en`, because that is the fallback language:
    whoever writes down a single name writes the one everybody should read.

    **What was added here are the tags themselves.** Before, every key got
    through — `DE:`, `german:`, a slipped `dee:`. All three produce a field
    that never appears, because `title()` does not look for it. A text nobody
    ever sees is worse than an error at load time.
    """
    if isinstance(value, str):
        if not value.strip():
            return {}, what + " is empty"
        return {FALLBACK_LANGUAGE: value}, None
    if not isinstance(value, dict):
        return {}, what + " is neither text nor a language mapping"

    out: dict[str, str] = {}
    for k, v in value.items():
        code = str(k)
        if not LANGUAGE_PATTERN.match(code):
            return {}, f"{what}: not a language code: {code}"
        if not isinstance(v, str):
            return {}, f"{what}.{code} is not text"
        if not v.strip():
            return {}, f"{what}.{code} is empty"
        out[code] = v

    if needs_fallback and FALLBACK_LANGUAGE not in out:
        return {}, f"{what}: no {FALLBACK_LANGUAGE} — it is the fallback every other language needs"
    return out, None


def _defaults() -> dict[str, Any]:
    """Each registered key's default — its parser's answer to a missing key.

    A portal that breaks while it is read carries these, so that it looks
    like every other portal to whoever reads `extras` or `as_json()`: the
    field is there, with the value an empty manifest would have had. A parser
    that complains about nothing, or raises, leaves its key out.
    """
    out: dict[str, Any] = {}
    for feld_spec in extension.FIELDS:
        try:
            value, complaint = feld_spec.parse(None)
        except Exception:
            continue
        if not complaint:
            out[feld_spec.key] = value
    return out


def read(file: Path) -> Manifest:
    """Read one manifest. Never raises — every failure becomes `broken`.

    A single broken folder must not stop the whole pass.
    """
    folder = file.parent
    broken = Manifest(
        id=folder.name, name={"en": folder.name}, kind="?", extras=_defaults(), folder=folder
    )

    try:
        raw = yaml.safe_load(file.read_text(encoding="utf-8")) or {}
    except Exception as err:  # the reason belongs in the list
        broken.broken_reason = "manifest unreadable: " + str(err)
        return broken
    if not isinstance(raw, dict):
        broken.broken_reason = "manifest is not a mapping"
        return broken

    keys = allowed_keys()
    if (
        _LEGACY_DIRECT_KEY in raw
        and _LEGACY_DIRECT_KEY not in keys
        and raw[_LEGACY_DIRECT_KEY] in (None, routes.DIRECT)
    ):
        raw = {k: v for k, v in raw.items() if k != _LEGACY_DIRECT_KEY}
    unknown = sorted(set(raw) - keys)
    if unknown:
        broken.broken_reason = "unknown keys: " + ", ".join(unknown)
        return broken

    # `int("one")` raises — and the docstring above promises that never
    # happens here. A manifest saying `api: v1` would have aborted the entire
    # pass instead of a single portal.
    #
    # **`int()` is too forgiving for this.** `int(True)` is `1` and so is
    # `int(1.9)` — `api: true` and `api: 1.9` would have passed as version 1. A
    # version number is a whole number, and `bool` is only one by accident in
    # Python.
    roh_api = raw.get("api", 0)
    if isinstance(roh_api, bool) or not isinstance(roh_api, int):
        broken.broken_reason = "api is not a whole number: " + repr(roh_api)
        return broken
    api = roh_api
    if api not in API_VERSIONS:
        broken.broken_reason = (
            f"api {api} not supported (this server speaks {sorted(API_VERSIONS)})"
        )
        return broken

    missing = [s for s in ("id", "name", "kind") if not raw.get(s)]
    if missing:
        broken.broken_reason = "missing: " + ", ".join(missing)
        return broken

    kind = str(raw["kind"])
    spec = extension.kind(kind)
    if spec is None:
        broken.broken_reason = "unknown kind: " + kind
        return broken

    # **A string is not a list.** `capabilities: search` looks right and gets
    # torn into its letters by `{str(x) for x in …}` — the message then read
    # `unknown capability: a, c, e, h, r, s`. That is the kind of error message
    # that makes you look for the fault in yourself.
    for feld in ("capabilities", "limits", "settings"):
        if feld in raw and raw[feld] is not None and not isinstance(raw[feld], list):
            broken.broken_reason = f"{feld} must be a list, not {type(raw[feld]).__name__}"
            return broken

    name, complaint = _sprachfeld(raw["name"], "name", needs_fallback=True)
    if complaint:
        broken.broken_reason = complaint
        return broken

    # A description is optional — a broken one is not. Before, the complaint
    # fell on the floor here (`_`), and a `description: 42` quietly became "no
    # description".
    #
    # **`or {}` was too blunt for that.** It ran before the type check and so
    # let through every value that happens to be falsy: `description: 0`,
    # `description: false`, `description: ''` all quietly became "no
    # description" again — precisely what was being abolished here. Only an
    # empty `description:` (which YAML reads as `None`) really means "not
    # given".
    roh = raw.get("description")
    description, complaint = _sprachfeld({} if roh is None else roh, "description")
    if complaint:
        broken.broken_reason = complaint
        return broken

    can = {str(x) for x in (raw.get("capabilities") or [])}
    if can - CAPABILITIES:
        broken.broken_reason = "unknown capability: " + ", ".join(sorted(can - CAPABILITIES))
        return broken

    limits = list(raw.get("limits") or [])
    complaint = _check_limits(limits)
    if complaint:
        broken.broken_reason = complaint
        return broken

    complaint = _check_settings_shape(raw.get("settings") or [])
    if complaint:
        broken.broken_reason = complaint
        return broken

    images = str(raw.get("images") or "measure")
    if images not in IMAGES:
        broken.broken_reason = (
            "images must be one of " + ", ".join(sorted(IMAGES)) + ", not " + images
        )
        return broken

    # **The extensions' keys, each through its own parser.** Every registered
    # key gets its value — a missing one its parser's default — so that a
    # reader finds it in `extras` without asking whether it was written. A
    # parser that raises makes this one portal broken, never the pass.
    extras: dict[str, Any] = {}
    for feld_spec in extension.FIELDS:
        try:
            value, complaint = feld_spec.parse(raw.get(feld_spec.key))
        except Exception as err:
            value, complaint = None, f"{feld_spec.key} unreadable: {type(err).__name__}: {err}"
        if complaint:
            broken.broken_reason = complaint
            return broken
        extras[feld_spec.key] = value

    m = Manifest(
        id=str(raw["id"]),
        name=name,
        kind=kind,
        api=api,
        description=description,
        capabilities=can,
        limits=limits,
        settings=list(raw.get("settings") or []),
        on_by_default=bool(raw.get("enabled", False)),
        adult=bool(raw.get("adult", False)),
        images=images,
        extras=extras,
        folder=folder,
    )
    try:
        complaint = spec.validate(m) if spec.validate is not None else None
    except Exception as err:
        complaint = f"kind {kind} unreadable: {type(err).__name__}: {err}"
    if complaint:
        m.broken_reason = complaint
    else:
        _run_checks(m)
    return m


def _check_limits(limits: list[Any]) -> str | None:
    """What a portal CANNOT do is a promise like any other.

    `INHALTE.md` gives the reason: "a portal with a geo block looks like a
    broken one". The app turns a limit into a sentence before somebody clicks
    four titles and gets the same thing four times — and for that it has to be
    able to read the value, not just the name.

    Two shapes are allowed, and only two: `drm_partial` as a bare name,
    `region_locked: [fr, de]` with countries. Anything else is a manifest
    claiming something the server cannot interpret.
    """
    for g in limits:
        if isinstance(g, dict):
            if len(g) != 1:
                return "a limit is one name with one value, got: " + repr(sorted(g))
            token, value = next(iter(g.items()))
            token = str(token)
            if token not in LIMITS:
                return "unknown limit: " + token
            if token not in LIMITS_WITH_VALUE:
                return "limit takes no value: " + token
            if not isinstance(value, list) or not value:
                return token + " needs a non-empty list of country codes"
            for land in value:
                if not COUNTRY_PATTERN.match(str(land)):
                    return f"{token}: not a country code: {land}"
            continue

        token = str(g)
        if token not in LIMITS:
            return "unknown limit: " + token
        if token in LIMITS_WITH_VALUE:
            return token + " without a value says nothing — list the countries"
    return None


def _check_settings_shape(settings: list[Any]) -> str | None:
    """Unknown keys are an error **inside** `settings` as well.

    **Not to be confused with `_check_settings`.** This one checks the *shape*
    (which keys, once per name, `required` as yes/no) and runs exactly once,
    while reading. `_check_settings` checks the *values* — whether a mandatory
    field is filled — and runs again after every `overlay()`. Two names one
    word apart have gone wrong here before (`modul` next to `module`); that is
    why the difference is spelled out.

    **The reason sits one level up.** The top level has been checked since the
    beginning, `settings` has not — and `required` is exactly the field where a
    typo does nothing and still changes everything: a mandatory setting becomes
    a suggestion, the portal calls itself `ready` and says `stream.no_host`
    when you try to play. The same half hour in the wrong direction as on
    10 Sep 2026, only with a different trigger.

    Duplicate keys are an error too: `overlay()` writes into **every** matching
    entry, while a portal that receives its settings as a mapping keeps the
    last. Two entries under the same name would be two truths, one of which
    applies depending on who is asking.
    """
    gesehen: set[str] = set()
    for e in settings:
        if not isinstance(e, dict):
            return "a setting is a mapping, got: " + type(e).__name__
        unknown = sorted(set(e) - SETTING_KEYS)
        if unknown:
            return "unknown keys in setting {}: {}".format(
                repr(e.get("key", "?")), ", ".join(unknown)
            )
        key = str(e.get("key") or "").strip()
        if not key:
            return "a setting without a key"
        if key in gesehen:
            return "setting listed twice: " + key
        gesehen.add(key)
        if "required" in e and not isinstance(e["required"], bool):
            return "{}: required is yes or no, got: {}".format(key, repr(e["required"]))
    return None


def overlay(m: Manifest, values: dict[str, str]) -> None:
    """Lay the operator's values over the author's.

    **Two sources, cleanly separated.** The manifest says which settings a
    portal knows and what the author considers a sensible default. What this
    household enters on top — an API key, an account password — does not
    belong in that file: since E4 the portal folder is pinned by `sha256`, and
    a value inside it would not survive the next version.

    Only keys the manifest already carries. A stored value for something that
    does not exist would be a silent setting — and silent is never right here.

    Afterwards the readiness checks run again: a portal that was `broken` only
    because of an empty required field is `ready` again once it is filled — and
    the other way round just the same. A defect from reading stays.
    """
    if not values:
        return
    for e in m.settings:
        key = str(e.get("key", ""))
        if key in values:
            e["value"] = values[key]
    # **The route, with an underscore so that no portal setting can collide.**
    # Settings are the author's names; a key beginning with `_` is ours. A
    # stored value of the right shape is taken even when no such route exists
    # (any more): the registry then calls the portal broken until the route
    # is back, instead of sending it out directly. Anything else is nothing,
    # and the default applies.
    route = str(values.get(NET_OVERRIDE_KEY) or "").strip().lower()
    if routes.NAME_PATTERN.match(route):
        m.net_override = route
    if m.broken_reason and not m.from_check:
        return  # a defect from reading stays a defect
    m.broken_reason = None
    m.from_check = False
    m.missing_settings = []
    _run_checks(m)


def _run_checks(m: Manifest) -> None:
    """The readiness checks: the extensions' first, the mandatory settings last.

    **The settings last, on purpose.** An empty mandatory setting is the one
    defect the operator mends in the console; every other one needs a change
    somewhere else. Named first, it would hide the defect that the filled
    setting does not mend.

    The first reason wins. A check that raises is a defect of that check, and
    it says so instead of taking the whole registry pass down.
    """
    for check in extension.CHECKS:
        try:
            reason = check(m)
        except Exception as err:
            reason = f"check failed: {type(err).__name__}: {err}"
        if reason:
            m.broken_reason = reason
            m.from_check = True
            return
    _check_settings(m)
    if m.broken_reason:
        m.from_check = True


def _check_settings(m: Manifest) -> None:
    """A setting with `required: true` and an empty value breaks the portal.

    **Because the alternative is a lie.** A portal that needs a key for every
    item it plays cannot play a single one without it. What the server used to
    say then was `stream.no_host`, meaning "no host reachable" — while every
    host answered perfectly and none of them was the problem. On 10 Sep 2026
    that cost half an hour of searching in the wrong direction, and the next
    person would have done the same.

    The objection to this is: but browsing works. True — and that is exactly
    the trap `INHALTE.md` describes: "a portal that browses but does not play
    is worse than one that is missing". Whoever clicks four titles and gets the
    same thing four times looks for the fault in themselves.

    `broken_reason` names the key, so the detail page can say what to do — and
    `PUT /household/portals/{id}/settings` is the way to do it.
    """
    empty = sorted(
        str(e.get("key", ""))
        for e in m.settings
        if e.get("required") and not str(e.get("value") or "").strip()
    )
    if empty:
        m.broken_reason = "setting required but empty: " + ", ".join(empty)
        m.missing_settings = empty
