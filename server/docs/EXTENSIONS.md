# Extending the server

CineLounge runs complete on its own. On top of that it has a small plugin
system: an **extension** is an ordinary Python package that the server loads at
startup and that adds pieces through a fixed set of registration points.

Most people never need one. To add content, write a portal (`docs/SDK.md`) — a
folder with a manifest and a class, no plugin API involved. An extension is the
level below that: it changes what a portal *is* to the server, how it is
called, how its streams are delivered, and what the web side offers.

This document lists every registration point, the order in which they are
filled, and the rules that keep them working with the fork runner.

---

## The short version

```python
# example_package/__init__.py
from cinelounge.web.extension import ExtensionContext


def install(ctx: ExtensionContext) -> None:
    ctx.health(lambda: {"example": "ok"})
```

```toml
# the extension's own pyproject.toml
[project.entry-points."cinelounge.extensions"]
example = "example_package:install"
```

Install the package next to the server (`pip install ./example`), restart, and
`GET /health` lists `example` under `extensions`.

---

## Loading

An extension is a callable `install(ctx: ExtensionContext) -> None`. The server
finds it in two places:

| Source | Form | For |
|---|---|---|
| Entry-point group `cinelounge.extensions` | `name = "module:function"` | installed packages — the usual way |
| `CL_EXTENSIONS` | `module` or `module:function`, comma-separated | development without pip |

`CL_EXTENSIONS=none` switches both sources off. A package named in both places
is loaded once.

The public server knows no extension by name. Which ones run is decided by
what is installed and by the environment, nothing else.

### A broken extension does not stop the service

An extension that fails to import or raises in `install` is logged, whatever it
had registered is rolled back, and `/health` names it under
`extensions_failed` with the phase (`load`, `install`, `migrate`, `attach`) and
the error. The service starts with the others.

---

## Order at startup

The order is fixed in `cinelounge/web/main.py`, and it is the order the fork
runner needs:

1. **`extension.load()`** — every `install(ctx)` runs. Registrations land in
   the registries of `cinelounge/portalworks/extension.py`. This happens
   *before* a single manifest is read, because reading a manifest already asks
   the registries (kinds, fields, checks).
2. **The household opens** — the extensions' own tables are migrated
   (`ctx.store_migrations`).
3. **`extension.attach(app, services)`** — routers are mounted, background
   services start, health and network contributions are wired in.
4. **`runner.preload()`** — shared modules are imported and **every registry is
   sealed**. The first child process is forked after this point.

A registration after step 4 raises `SealedError`. That is deliberate: a child
inherits the parent's memory as it was at the fork, so anything registered
later would exist in the parent and in no child forked before it.

---

## Registration points: the portal side

All in `cinelounge/portalworks/extension.py` unless noted.

| Function | Registers | Called |
|---|---|---|
| `register_kind(KindSpec(...))` | a portal kind — a value for `kind:` in `portal.yml` | `build(m)` in the child, before each call |
| `register_field(FieldSpec(...))` | an additional top-level manifest key | while reading a manifest |
| `register_check(check)` | a readiness check: `check(m) -> str \| None` | after reading, and after every settings overlay |
| `register_child_setup(setup)` | `setup(m, via)` in the child, after the network route is in place, before the portal is built | in the child |
| `register_call_observer(observe)` | `observe(m, method, error)` after every portal call | in the API process |
| `register_nightly_hook(NightlyHook())` | takes part in the nightly check | nightly thread |
| `playback.register_policy(kind, policy)` | a `PlaybackPolicy` subclass for one portal kind | `/play`, `/sources` |
| `routes.register_provider(provider)` | a `RouteProvider` that offers network routes | network view, runner, relay |
| `stream.proxy.register_scheme(scheme, reader)` | addresses the relay answers from memory | `/stream` |

### Portal kinds — `KindSpec`

```python
KindSpec(
    name="example",
    build=lambda m: ...,         # returns the portal object; runs in the child only
    preload=("some_module",),    # imported once before the first fork
    rank=1,                      # order among several portals with the same title
    validate=None,               # (m) -> complaint or None, while reading
)
```

The core brings `native` (rank 0): `portal.py` with a class `Portal`. A
manifest naming a kind nobody registered is `broken` with that reason; it does
not crash the service.

`build` runs inside the forked child. Whatever it imports is imported there,
never in the API process — the API process stays startable whatever a kind
depends on.

### Manifest fields — `FieldSpec`

```python
FieldSpec(key="example", parse=lambda raw: (raw or "", None), public_json=False)
```

`parse(raw)` gets the YAML value (`None` when the key is missing) and returns
`(value, complaint)`. A complaint makes the manifest `broken` with that
sentence. The value lands in `Manifest.extras[key]` — also for a missing key, so
a reader always finds the default there. `public_json=True` adds it to
`Manifest.as_json()` — and lets a marketplace index entry carry the same key,
read by the same parser, so a tile can show it before anything is installed.

Without a registration, an unknown key is an error, exactly as for portals
(`docs/SDK.md`).

### Playback — `PlaybackPolicy`

`cinelounge/portalworks/playback.py` turns an item into a playable address. Each
step is a method of `PlaybackPolicy`; a subclass registered for a kind overrides
single steps and inherits the rest:

| Method | Default |
|---|---|
| `sources(m, address, title, limits)` | asks the portal |
| `after_sources(m, address, found, limits)` | nothing |
| `arrange(m, found)` | unchanged order |
| `prepare(m, found, limits)` | nothing |
| `before_play(m)` | nothing; may raise to refuse |
| `order(m, candidates, language)` | preferred language to the front |
| `prepared(m, source_id)` | `None` |
| `on_failure(m, candidate, err)` | nothing; raising ends the chain |
| `normalize(m, stream)` | unchanged |
| `route(m, address)` | the portal's network route |
| `deliver(m, candidate, stream, failed)` | buffer, relay or probe |
| `on_outcome(m, candidate, ok)` | nothing |
| `last_resort(m, tried, unresolved, failed)` | `None` |
| `again(m, source, limits)` | resolve once more for the relay |

A subclass that only adds to a step calls `super()`.

### Network routes — `RouteProvider`

A route is a name and an HTTP proxy address (`routes.Route`). The core offers
the proxies from `CL_PROXIES` and the ones saved in the console. A provider can
offer more:

```python
class RouteProvider:
    def routes(self) -> list[Route]: ...
    def status(self, route: Route) -> dict: ...
    def choose(self, m: Manifest) -> str | None: ...   # a portal's route when the operator chose none
    def details(self, name: str) -> dict: ...          # extra fields in the network view
    def reject(self, name: str) -> str | None: ...     # error code for a malformed name
```

Every method has a default that offers nothing. A name the core already offers
stays the core's. The operator's choice in the console always wins over
`choose`.

### Relay schemes

`register_scheme("example", reader)` lets the relay answer `example://…`
addresses from memory: `reader(address)` returns the playlist text or `None`.
`http`, `https` and `file` cannot be taken. The reader is called outside every lock of
the relay and must not block.

---

## Registration points: the web side

`install(ctx)` gets an `ExtensionContext` (`cinelounge/web/extension.py`).
Everything handed over is collected first and takes effect in `attach`:

| Method | Contributes |
|---|---|
| `ctx.include_router(router)` | additional routes; core routes win a clash |
| `ctx.background(start, stop=None)` | a background service, started with the household's services |
| `ctx.health(report)` | extra fields for `/health`; core fields cannot be overwritten |
| `ctx.network_report(report)` | extra top-level fields for `GET /network/exits` |
| `ctx.event_texts(texts, examples=None)` | notification texts per language; they replace core texts of the same name |
| `ctx.error_observer(observe)` | sees every `f.Error` that leaves the service; cannot change it |
| `ctx.view_hook(PortalViewHook())` | takes part in the portal routes' answers (menu, items, opened, played) |
| `ctx.store_migrations(namespace, steps)` | tables of the extension's own in the household file |

### Store migrations

`steps` are SQL scripts or functions that get the connection. They run once
each, in order, counted per `namespace` in a table of their own
(`schema_ext`). A later version of the extension appends steps and never
changes one that has run. A failing step puts the household file back as it
was and takes the extension out of the web side.

### View hooks

`PortalViewHook` methods run in the API process on the request's thread. They
must be quick; one that raises is logged and skipped. `menu` returns the entries
to show, `items` may fill fields in place (on copies), `opened` and `played`
are notifications.

---

## Rules for working with the fork runner

Portal code runs in forked children (`portalworks/runner/fork.py`). Four rules
follow from that:

1. **Register in `install`, nowhere else.** The registries are sealed before
   the first fork.
2. **Registries hold plain data and callables.** No threads, no locks, no open
   files — they are copied into every child as they are.
3. **Threads clear themselves in the child.** A background thread started
   through `ctx.background` must not survive into a child: register a cleaner
   with `os.register_at_fork(after_in_child=...)`.
4. **Hooks are never called under a core lock**, and a hook must not take one
   the core holds. Whoever adds a call site keeps it that way.

---

## The console

The console (`console-app/`) builds with exactly one extension module, imported
as `cl-extension`. Without one it is `src/extension/none.ts`. When the folder
`src/extension/local/` exists, its `index.ts` is used instead; the folder is
ignored by Git.

An extension module exports a `ConsoleExtension` (`src/extension/types.ts`):

- **areas** — pages of their own in the navigation rail;
- **slots** — components rendered at named places (`network`,
  `network.route`, `portal.detail`, `portal.row`, `home`, `market.tile`,
  `market.install`; `market.install` may hold the "on right away" switch back
  through its `hold` callback);
- **languages** — texts per language, merged deeply over the core's.

---

## Testing an extension

- Run the server's own suite **without** extensions (`CL_EXTENSIONS=none`):
  that is the version everybody else runs.
- Run it again **with** yours loaded. The core tests must stay green — an
  extension adds, it does not break what is there.
- Fork-related tests only run on Linux; on macOS and Windows they skip.
