"""Registries that extensions fill at startup — the portal-works half.

An extension (see `cinelounge/web/extension.py`) adds portal kinds, manifest
fields, readiness checks and similar pieces. They land in the registries of
this module, and the portal works ask them instead of a fixed list.

## Two phases, and the line between them is the first child process

1. **Open.** `web/extension.load()` runs every extension's `install(ctx)`;
   whatever it registers lands here.
2. **Sealed.** `runner.preload()` seals the registries before it imports the
   shared modules. From then on every registration raises `SealedError`.

**Why sealed and not merely "too late".** Portal code runs in a forked child.
The child inherits the parent's memory as it was at the fork — a kind
registered afterwards exists in the parent and in no child forked before it,
and the same portal would work on one call and not on the next. A registration
after the preload is therefore a programming error, and it fails loudly at
startup instead of quietly at the first call.

## What a registry may hold

Plain data and callables. No threads, no locks, no open files: the registries
are copied into every child as they are. A hook that needs a background thread
starts it through `ctx.background(...)` in the web layer and clears it in the
child with `os.register_at_fork(after_in_child=...)`.

Hooks are never called while a lock of the portal works is held; whoever adds
a call site keeps it that way.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Generic, TypeVar

if TYPE_CHECKING:
    from cinelounge.core.errors import Error
    from cinelounge.portalworks.manifest import Manifest
    from cinelounge.portalworks.nightly import Result
    from cinelounge.portalworks.runner.fork import Limits

T = TypeVar("T")

__all__ = [
    "CALL_OBSERVERS",
    "CHECKS",
    "CHILD_SETUPS",
    "FIELDS",
    "KINDS",
    "NIGHTLY_HOOKS",
    "POLICIES",
    "UNKNOWN_RANK",
    "FieldSpec",
    "KindSpec",
    "NightlyHook",
    "Register",
    "SealedError",
    "is_sealed",
    "kind",
    "policy",
    "rank",
    "register_call_observer",
    "register_check",
    "register_child_setup",
    "register_field",
    "register_kind",
    "register_nightly_hook",
    "register_policy",
    "reset",
    "restore",
    "seal",
    "snapshot",
]


class SealedError(RuntimeError):
    """A registration after `seal()` — i.e. after the preload, before a fork."""


_SEALED = False
_ALL: list[Register[Any]] = []


class Register(Generic[T]):
    """One named list of contributions, in the order they were registered.

    `key` makes entries unique: a second entry with the same key raises
    `ValueError` instead of silently replacing the first. Two extensions that
    claim the same portal kind are a conflict the operator has to see.

    **Core entries and extension entries.** The core's own defaults go in with
    `add_core` (at import time, next to the code they describe); everything an
    extension contributes goes in with `add`. Core entries always stand first,
    survive `reset()` and are never part of a `snapshot()` — rolling back a
    failed extension or resetting a test can never take away what the core
    itself brings.
    """

    def __init__(self, name: str, key: Callable[[T], str] | None = None) -> None:
        self.name = name
        self._key = key
        self._core: list[T] = []
        self._items: list[T] = []
        _ALL.append(self)

    def add(self, item: T) -> T:
        """An extension's entry, after every earlier one."""
        self._check(item)
        self._items.append(item)
        return item

    def add_core(self, item: T) -> T:
        """A default of the core itself: kept by `reset()`, placed before every
        extension entry no matter which module was imported first."""
        self._check(item)
        self._items.insert(len(self._core), item)
        self._core.append(item)
        return item

    def _check(self, item: T) -> None:
        if _SEALED:
            raise SealedError(f"{self.name}: registration after the preload")
        if self._key is not None:
            k = self._key(item)
            if any(self._key(x) == k for x in self._items):
                raise ValueError(f"{self.name}: {k!r} is already registered")

    def items(self) -> tuple[T, ...]:
        return tuple(self._items)

    def get(self, key: str) -> T | None:
        """The entry with this key, for a register made with `key`."""
        if self._key is None:
            raise TypeError(f"{self.name} has no key")
        return next((x for x in self._items if self._key(x) == key), None)

    def __iter__(self) -> Iterator[T]:
        return iter(tuple(self._items))

    def __len__(self) -> int:
        return len(self._items)


def seal() -> None:
    """Close every register. Called by `runner.preload()`."""
    global _SEALED
    _SEALED = True


def is_sealed() -> bool:
    return _SEALED


def snapshot() -> dict[int, list[Any]]:
    """The extension entries of every register — taken before an extension installs.

    If `install` fails halfway, `restore` puts back exactly this, and nothing
    of the failed extension stays behind. Core entries are not part of it;
    they stay as they are, even one a lazily imported core module added
    meanwhile.
    """
    return {id(r): r._items[len(r._core) :] for r in _ALL}


def restore(state: dict[int, list[Any]]) -> None:
    for r in _ALL:
        r._items[:] = [*r._core, *state.get(id(r), [])]


def reset() -> None:
    """Back to the core entries alone, and reopen every register. For tests only."""
    global _SEALED
    _SEALED = False
    for r in _ALL:
        r._items[:] = r._core


# ── The registers of the portal works ────────────────────────────────────────
#
# Each one below is asked by exactly the call sites named in its comment or
# docstring, and nowhere else.

#: Where a kind without a registration stands when results are merged.
UNKNOWN_RANK = 9


@dataclass(frozen=True)
class KindSpec:
    """A portal kind: the value of `kind:` in a manifest, and how it is built.

    - `build(m)` runs **inside the child process only** and returns the portal
      object (`portalworks/runner/call.py`). Whatever the kind imports for that
      happens there, never in the API process.
    - `preload` names modules `runner.preload()` imports once before the
      first fork, after the standard library — what every portal of this kind
      shares, so that each child inherits it ready instead of importing it
      itself.
    - `rank` orders the sources of one title when several portals have it
      (`web/portals._zusammenlegen`): smaller is further forward. A kind that
      speaks an official interface belongs in front of one that reads web
      pages.
    - `validate(m)` names a defect of a manifest of this kind, or `None`. It
      runs while reading, after the core keys were checked.
    """

    name: str
    build: Callable[[Manifest], Any]
    preload: tuple[str, ...] = ()
    rank: int = 1
    validate: Callable[[Manifest], str | None] | None = None


@dataclass(frozen=True)
class FieldSpec:
    """An additional top-level key of `portal.yml`.

    `parse(raw)` gets the raw YAML value (`None` when the key is missing) and
    returns `(value, complaint)`. A complaint makes the manifest `broken` with
    exactly that sentence; otherwise the value lands in `Manifest.extras[key]`
    — also for a missing key, so that a reader always finds the field's
    default there.

    `public_json` puts the value into `Manifest.as_json()`, i.e. into the
    answers the apps and the console read.
    """

    key: str
    parse: Callable[[Any], tuple[Any, str | None]]
    public_json: bool = False


#: The portal kinds. The core brings `native` (`portalworks/native.py`).
KINDS: Register[KindSpec] = Register("portal kinds", key=lambda k: k.name)

#: Additional manifest keys. The core keys stand in `manifest.CORE_KEYS`.
FIELDS: Register[FieldSpec] = Register("manifest fields", key=lambda s: s.key)

#: Readiness checks: `check(m)` returns the reason a portal is not ready, or
#: `None`. They run after reading and again after every `manifest.overlay()`,
#: before the core's own check for empty mandatory settings.
CHECKS: Register[Callable[[Manifest], str | None]] = Register("readiness checks")

#: Set-up in the child: `setup(m, via)` runs inside the child process after
#: the network route is in place (`via` is the proxy address or `None`) and
#: before the portal is built. For whatever has to hold for every request the
#: portal code makes — and only in that child.
CHILD_SETUPS: Register[Callable[[Manifest, str | None], None]] = Register("child set-up")

#: Call observers: `observe(m, method, error)` runs in the API process after
#: every portal call (`runner/call.py`) — `error` is the `f.Error` the call
#: ended with, `None` after a success. For bookkeeping only: it cannot change
#: the result, and an observer that raises is logged and skipped. It runs on
#: the caller's thread, so it must be quick and must not block.
CALL_OBSERVERS: Register[Callable[[Manifest, str, Error | None], None]] = Register("call observers")


class NightlyHook:
    """Takes part in the nightly check (`portalworks/nightly.py`,
    `web/nightwatch.py`). Subclass it and override what you need; the base
    class changes nothing.

    Both methods run in the API process, on the night watch's thread — never
    under a lock of the portal works, and never waiting for the night run
    itself to end.
    """

    def order_entries(
        self,
        m: Manifest,
        menu: list[dict[str, Any]],
        entries: list[dict[str, Any]],
        limits: Limits,
    ) -> list[dict[str, Any]]:
        """The entry points the check tries, in the order it tries them.

        `menu` is every entry point the portal named; `entries` is what the
        core would try — the menu without tools and the viewer's own areas
        (`nightly.content_entries`), or what an earlier hook made of it. The
        check tries the first few of the answer. A hook may look one level
        deeper with `runner.call(m, "listing", …, limits)`; it must not raise.
        """
        return entries

    def after(self, m: Manifest, result: Result) -> None:
        """Called once a portal is checked, with what came out — carried or not."""


@dataclass(frozen=True)
class _Policy:
    kind: str
    policy: Any


#: Playback policies per portal kind (`portalworks/playback.py`,
#: `register_policy`). A kind without one plays with `PlaybackPolicy()`. A
#: policy may be registered for any kind, `native` included.
POLICIES: Register[_Policy] = Register("playback policies", key=lambda p: p.kind)

#: Hooks of the nightly check, in the order they were registered.
NIGHTLY_HOOKS: Register[NightlyHook] = Register("nightly hooks")


def register_nightly_hook(hook: NightlyHook) -> NightlyHook:
    return NIGHTLY_HOOKS.add(hook)


def register_policy(kind: str, policy: Any) -> None:
    """The playback policy for portals of `kind` — see `playback.register_policy`."""
    POLICIES.add(_Policy(kind, policy))


def policy(kind: str) -> Any | None:
    """The policy registered for this kind, if any."""
    entry = POLICIES.get(kind)
    return None if entry is None else entry.policy


def register_kind(spec: KindSpec) -> KindSpec:
    return KINDS.add(spec)


def register_field(spec: FieldSpec) -> FieldSpec:
    return FIELDS.add(spec)


def register_check(check: Callable[[Manifest], str | None]) -> None:
    CHECKS.add(check)


def register_child_setup(setup: Callable[[Manifest, str | None], None]) -> None:
    CHILD_SETUPS.add(setup)


def register_call_observer(observe: Callable[[Manifest, str, Error | None], None]) -> None:
    CALL_OBSERVERS.add(observe)


def kind(name: str) -> KindSpec | None:
    """The registered kind of this name, if any."""
    return KINDS.get(name)


def rank(name: str) -> int:
    """Where a portal of this kind stands among the sources of one title."""
    spec = KINDS.get(name)
    return UNKNOWN_RANK if spec is None else spec.rank
