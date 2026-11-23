"""Extensions: optional packages that add to the server at startup.

The server runs complete without any. An extension is a callable
`install(ctx: ExtensionContext) -> None`, found in two places:

- **Installed packages** that name it in the entry-point group
  `cinelounge.extensions` — the usual way for Python plugins::

      [project.entry-points."cinelounge.extensions"]
      example = "example_package:install"

- **`CL_EXTENSIONS`**, a comma-separated list of `module` or
  `module:function` (default function `install`), for development without
  pip. `CL_EXTENSIONS=none` switches both sources off.

## Order at startup (`web/main.py`)

1. `load()` — before the household and the portal registry are read. Every
   `install(ctx)` runs now and fills the registries of
   `portalworks/extension.py`, because reading a manifest already needs them.
2. `migrate(store)` — from `Services.from_path`, when the household file is
   opened: the extensions' own tables (`ctx.store_migrations`).
3. `attach(app, services)` — routers, background services and health
   contributions collected in step 1 are put to work.
4. `runner.preload()` seals the registries. The first child process is forked
   after this point, so every child inherits the same registries.

## A broken extension does not stop the service

An extension that fails to import or raises in `install` is logged, its
partial registrations are rolled back, and `/health` names it under
`extensions_failed`. The service starts with the others.

The same holds for a failure in `attach`: the background services of that
extension that had already started are stopped again, and none of its routers
is mounted. `/health` then says "failed", and nothing of it answers.

A migration that fails in `migrate` puts the household file back as it was
(see `Store.migrate_extension`) and takes the extension out of the web side:
`attach` mounts nothing of it, and its view hooks, observers and reports are
not asked. What it put into the portal works' registries stays — the
manifests were already read with it.
"""

from __future__ import annotations

import importlib
import logging
import os
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from importlib.metadata import entry_points
from typing import TYPE_CHECKING, Any

from cinelounge.portalworks import extension as registries

if TYPE_CHECKING:
    from fastapi import APIRouter, FastAPI, Request

    from cinelounge.core.errors import Error
    from cinelounge.household.people import Person
    from cinelounge.household.store import Step, Store
    from cinelounge.portalworks.manifest import Manifest
    from cinelounge.web.access import Services

__all__ = [
    "GROUP",
    "ExtensionContext",
    "Failure",
    "PortalViewHook",
    "attach",
    "event_examples",
    "event_texts",
    "health",
    "load",
    "migrate",
    "network_fields",
    "observe_error",
    "reset",
    "view_items",
    "view_menu",
    "view_opened",
    "view_played",
]

GROUP = "cinelounge.extensions"
_ENV = "CL_EXTENSIONS"
_OFF = "none"

_LOG = logging.getLogger("cinelounge.extension")


@dataclass(frozen=True)
class Failure:
    """One extension that did not make it, and where."""

    name: str
    phase: str
    error: str

    def as_json(self) -> dict[str, str]:
        return {"name": self.name, "phase": self.phase, "error": self.error}


class PortalViewHook:
    """Takes part in what the portal routes (`web/portals.py`) hand out.

    Subclass it and override what you need; the base class changes nothing.
    Register it with `ctx.view_hook(hook)`. Its methods run in the API process,
    on the request's thread — they must be quick, and one that raises is
    logged and skipped. `request` gives the household through
    `web.access.services(request)`; `person` is the one asking, already
    checked against the portal.
    """

    def menu(
        self, request: Request, person: Person, m: Manifest, entries: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        """The portal's menu (`GET /p/{id}/menu`) — return the entries to show.

        Gets copies of its own; it may drop, reorder, add or change entries in
        place. Several hooks run one after the other, each on what the one
        before returned. A hook that raises leaves the entries as they were
        before it — also what it changed in place before raising.
        """
        return entries

    def items(self, m: Manifest, items: list[dict[str, Any]]) -> None:
        """Items of a listing or a search result, before they go out.

        May fill fields in place — on copies, never on cached pages. Items
        that already carry a field from the portal itself keep it.
        """

    def opened(self, request: Request, person: Person, m: Manifest, entry: str) -> None:
        """Somebody opened an entry: the first page of `GET /p/{id}/list`.

        Not for a next page, and not for the answer to a question asked inside
        the entry. Called before the portal is asked, so also when it fails.
        """

    def played(self, request: Request, person: Person, m: Manifest, address: str) -> None:
        """`GET /play` resolved something for this person.

        `address` is the item's address, or the source's when only that was
        given.
        """


@dataclass
class ExtensionContext:
    """What `install(ctx)` gets: the ways an extension may contribute.

    Everything handed over here is only collected. It takes effect in
    `attach()`, once the household exists — so `install` never needs the
    services, and nothing runs before the registries are complete.
    """

    name: str
    _routers: list[APIRouter] = field(default_factory=list)
    _background: list[tuple[Callable[[Services], None], Callable[[], None] | None]] = field(
        default_factory=list
    )
    _health: list[Callable[[], Mapping[str, Any]]] = field(default_factory=list)
    _network: list[Callable[[], Mapping[str, Any]]] = field(default_factory=list)
    _texts: dict[str, dict[str, str]] = field(default_factory=dict)
    _examples: dict[str, dict[str, Any]] = field(default_factory=dict)
    _error_observers: list[Callable[[Request, Error], None]] = field(default_factory=list)
    _view_hooks: list[PortalViewHook] = field(default_factory=list)
    _migrations: dict[str, tuple[Step, ...]] = field(default_factory=dict)

    def include_router(self, router: APIRouter) -> None:
        """Additional routes. Core routes are registered first and win a clash."""
        self._routers.append(router)

    def background(
        self, start: Callable[[Services], None], stop: Callable[[], None] | None = None
    ) -> None:
        """A background service, started in `attach` with the household's services.

        A thread started here must not survive into a forked child: clear it
        with `os.register_at_fork(after_in_child=...)`. `stop` runs when the
        application shuts down.
        """
        self._background.append((start, stop))

    def health(self, report: Callable[[], Mapping[str, Any]]) -> None:
        """Extra fields for `/health`. Core fields cannot be overwritten."""
        self._health.append(report)

    def network_report(self, report: Callable[[], Mapping[str, Any]]) -> None:
        """Extra top-level fields for `GET /network/exits`, the network view.

        Asked when the view opens, like the rest of that answer. Core fields
        cannot be overwritten.
        """
        self._network.append(report)

    def event_texts(
        self,
        texts: Mapping[str, Mapping[str, str]],
        examples: Mapping[str, Mapping[str, Any]] | None = None,
    ) -> None:
        """Texts for the notifications the server sends (`web/telegram.py`).

        `texts` maps a language (`de`, `en`, `tr`) to message names and their
        texts, with the same placeholders as `web/messages/<lang>.json`.
        **These replace the core's text of the same name** — that is what
        they are for. `examples` are the values the console's preview fills
        in, per message name.
        """
        for language, by_name in texts.items():
            self._texts.setdefault(language, {}).update(by_name)
        for name, values in (examples or {}).items():
            self._examples[name] = dict(values)

    def error_observer(self, observe: Callable[[Request, Error], None]) -> None:
        """Called for every `f.Error` that leaves the service as an answer.

        For bookkeeping (an entry in the event book, a counter); it cannot
        change the answer. One that raises is logged and skipped.
        """
        self._error_observers.append(observe)

    def view_hook(self, hook: PortalViewHook) -> None:
        """A hook into the portal routes' answers — see `PortalViewHook`."""
        self._view_hooks.append(hook)

    def store_migrations(self, namespace: str, steps: Sequence[Step]) -> None:
        """Tables of the extension's own in the household file.

        `steps` are SQL scripts or functions that get the connection; they run
        once each, in order, numbered per `namespace` — see
        `Store.migrate_extension`. Later versions of the extension append to
        the list and never change a step that has run. A namespace belongs to
        one extension: a second registration of it is an error in `install`.
        """
        taken = {ns for c in _STATE.installed for ns in c._migrations}
        if namespace in taken or namespace in self._migrations:
            raise ValueError(f"store namespace already registered: {namespace}")
        self._migrations[namespace] = tuple(steps)


@dataclass
class _State:
    loaded: bool = False
    installed: list[ExtensionContext] = field(default_factory=list)
    failed: list[Failure] = field(default_factory=list)


_STATE = _State()


def _describe(err: BaseException) -> str:
    return f"{type(err).__name__}: {err}"


def _candidates(environ: Mapping[str, str]) -> list[tuple[str, str, Callable[[], Any]]]:
    """(name, target, loader) for every extension named anywhere, without duplicates.

    The target is `module:function`; a package found both as an entry point
    and in `CL_EXTENSIONS` is loaded once.
    """
    wish = environ.get(_ENV, "").strip()
    if wish.lower() == _OFF:
        return []
    out: list[tuple[str, str, Callable[[], Any]]] = []
    seen: set[str] = set()
    for ep in sorted(entry_points(group=GROUP), key=lambda e: e.name):
        target = ep.value.replace(" ", "")
        if target not in seen:
            seen.add(target)
            out.append((ep.name, target, ep.load))
    for piece in wish.split(","):
        spec = piece.strip()
        if not spec:
            continue
        module, _, attr = spec.partition(":")
        target = f"{module}:{attr or 'install'}"
        if target in seen:
            continue
        seen.add(target)

        def loader(module: str = module, attr: str = attr or "install") -> Any:
            return getattr(importlib.import_module(module), attr)

        out.append((spec, target, loader))
    return out


def load(environ: Mapping[str, str] | None = None) -> list[str]:
    """Phase 1: find every extension and run its `install(ctx)`.

    **Runs once per process.** `web/main.py` may be imported again (tests
    reload it); a second call returns what the first one loaded instead of
    registering everything twice.
    """
    if _STATE.loaded:
        return [c.name for c in _STATE.installed]
    _STATE.loaded = True
    for name, target, loader in _candidates(os.environ if environ is None else environ):
        try:
            install = loader()
        except Exception as err:
            _fail(name, "load", err)
            continue
        if not callable(install):
            _fail(name, "load", TypeError(f"{target} is not callable"))
            continue
        before = registries.snapshot()
        ctx = ExtensionContext(name)
        try:
            install(ctx)
        except Exception as err:
            registries.restore(before)
            _fail(name, "install", err)
            continue
        _STATE.installed.append(ctx)
        _LOG.info("Extension loaded: %s (%s)", name, target)
    return [c.name for c in _STATE.installed]


def attach(app: FastAPI, services: Services) -> None:
    """Phase 2: routers, background services — for this application object.

    Called for every new `app` (a reloaded `web/main.py` builds a new one), so
    it reads the collected contributions and changes nothing in them. The
    attach failures of an earlier application object are dropped first: what
    `/health` reports belongs to the current one.

    **All or nothing per extension.** The background services start first,
    then the routers are mounted. If anything raises, the routes added for
    this extension are cut off again and the services already running are
    stopped. Shutdown handlers go into `app` only once all of it succeeded.
    """
    _STATE.failed[:] = [x for x in _STATE.failed if x.phase != "attach"]
    left_out = {x.name for x in _STATE.failed if x.phase == "migrate"}
    for ctx in _STATE.installed:
        if ctx.name in left_out:
            continue
        running: list[Callable[[], None] | None] = []
        routes = len(app.router.routes)
        try:
            for start, stop in ctx._background:
                start(services)
                running.append(stop)
            for router in ctx._routers:
                app.include_router(router)
        except Exception as err:
            del app.router.routes[routes:]
            _stop_all(ctx.name, running)
            _fail(ctx.name, "attach", err)
            continue
        for stop in running:
            if stop is not None:
                app.add_event_handler("shutdown", stop)


def _stop_all(name: str, running: list[Callable[[], None] | None]) -> None:
    """Stop what an extension already started, newest first.

    One failing stop does not keep the others running.
    """
    for stop in reversed(running):
        if stop is None:
            continue
        try:
            stop()
        except Exception as err:
            _LOG.warning(
                "Extension %s: stop after a failed attach raised (%s)", name, _describe(err)
            )


def migrate(store: Store) -> None:
    """Bring the extensions' own tables in `store` up to date.

    Called whenever the household file is opened (`Services.from_path`), so
    the failures of an earlier file are dropped first. An extension whose step
    fails is taken out — see the head of this module.
    """
    _STATE.failed[:] = [x for x in _STATE.failed if x.phase != "migrate"]
    for ctx in _STATE.installed:
        for namespace, steps in ctx._migrations.items():
            try:
                store.migrate_extension(namespace, steps)
            except Exception as err:
                _fail(ctx.name, "migrate", err)
                break


def health() -> dict[str, Any]:
    """The fields `/health` adds: which extensions run, which failed, and theirs."""
    failed = {x.name for x in _STATE.failed}
    out: dict[str, Any] = {
        "extensions": [c.name for c in _STATE.installed if c.name not in failed],
        "extensions_failed": [x.as_json() for x in _STATE.failed],
    }
    for key, value in _reports("_health", "health report").items():
        out.setdefault(key, value)
    return out


def network_fields() -> dict[str, Any]:
    """What the running extensions add to the network view."""
    return _reports("_network", "network report")


def _running() -> list[ExtensionContext]:
    failed = {x.name for x in _STATE.failed}
    return [c for c in _STATE.installed if c.name not in failed]


def event_texts(language: str) -> dict[str, str]:
    """The notification texts the running extensions bring for one language."""
    out: dict[str, str] = {}
    for ctx in _running():
        out.update(ctx._texts.get(language, {}))
    return out


def event_examples() -> dict[str, dict[str, Any]]:
    """The preview values the running extensions bring, per message name."""
    out: dict[str, dict[str, Any]] = {}
    for ctx in _running():
        out.update(ctx._examples)
    return out


def observe_error(request: Request, err: Error) -> None:
    """Hand an error answer to every running extension's observers."""
    for ctx in _running():
        for observe in ctx._error_observers:
            try:
                observe(request, err)
            except Exception as failure:
                _LOG.warning(
                    "Extension %s: error observer failed (%s)", ctx.name, _describe(failure)
                )


def view_menu(
    request: Request, person: Person, m: Manifest, entries: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """The menu through every running extension's view hooks, one after the other.

    Every hook gets copies of the entries: the cached menu stays as the portal
    gave it, and a hook that changes entries in place and then raises leaves
    nothing of its change behind.
    """
    out = [dict(e) for e in entries]
    for ctx in _running():
        for hook in ctx._view_hooks:
            try:
                out = list(hook.menu(request, person, m, [dict(e) for e in out]))
            except Exception as failure:
                _LOG.warning("Extension %s: view hook failed (%s)", ctx.name, _describe(failure))
    return out


def view_items(m: Manifest, items: list[dict[str, Any]]) -> None:
    """Hand a listing's or search's items to every running extension's view hooks."""
    for ctx in _running():
        for hook in ctx._view_hooks:
            try:
                hook.items(m, items)
            except Exception as failure:
                _LOG.warning("Extension %s: view hook failed (%s)", ctx.name, _describe(failure))


def view_opened(request: Request, person: Person, m: Manifest, entry: str) -> None:
    """Tell every running extension's view hooks that an entry was opened."""
    for ctx in _running():
        for hook in ctx._view_hooks:
            try:
                hook.opened(request, person, m, entry)
            except Exception as failure:
                _LOG.warning("Extension %s: view hook failed (%s)", ctx.name, _describe(failure))


def view_played(request: Request, person: Person, m: Manifest, address: str) -> None:
    """Tell every running extension's view hooks that something was played."""
    for ctx in _running():
        for hook in ctx._view_hooks:
            try:
                hook.played(request, person, m, address)
            except Exception as failure:
                _LOG.warning("Extension %s: view hook failed (%s)", ctx.name, _describe(failure))


def _reports(attr: str, what: str) -> dict[str, Any]:
    failed = {x.name for x in _STATE.failed}
    out: dict[str, Any] = {}
    for ctx in _STATE.installed:
        if ctx.name in failed:
            continue
        for report in getattr(ctx, attr):
            try:
                for key, value in report().items():
                    out.setdefault(key, value)
            except Exception as err:
                _LOG.warning("Extension %s: %s failed (%s)", ctx.name, what, _describe(err))
    return out


def _fail(name: str, phase: str, err: BaseException) -> None:
    _LOG.error("Extension %s failed in %s: %s", name, phase, _describe(err))
    _STATE.failed.append(Failure(name, phase, _describe(err)))


def reset() -> None:
    """Forget everything loaded and reopen the registries. For tests only."""
    _STATE.loaded = False
    _STATE.installed.clear()
    _STATE.failed.clear()
    registries.reset()
