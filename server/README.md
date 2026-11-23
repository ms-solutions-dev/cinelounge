<h1 align="center">CL Server</h1>

<p align="center">
  The companion server for CineLounge: a household service for your home network,<br>
  with a web console, portals for online media libraries and a marketplace for more.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python&logoColor=white" alt="Python 3.11+">
  <img src="https://img.shields.io/badge/FastAPI-0.121-009688?logo=fastapi&logoColor=white" alt="FastAPI">
  <img src="https://img.shields.io/badge/Docker-compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose">
  <img src="https://img.shields.io/badge/license-GPL--3.0-2f6b4f" alt="License: GPL-3.0">
</p>

<p align="center">
  <img src="docs/screenshots/console-01-overview.png" width="800" alt="Console: overview with portals, door, household and network routes">
</p>

The CineLounge app plays your Jellyfin library and your IPTV lists on its own. The CL Server is the optional part that runs next to it in your home network. It gives the household one place for people, roles, devices and age rules, and it brings in sources the app does not know about itself: **portals**. A portal is a small piece of Python that answers a few questions (what is on the menu, what is in this row, how do I play this) and hands back a video address the player can open. The server ships with portals for the public media libraries of ARD, ZDF, arte, 3sat and SVT, and an example portal to start your own.

Why a separate service and not code inside the app: portal code changes whenever a website changes. On the server it is a folder you update; in the app it would be a new release for every fix, and an App Store app may not load executable code. The app therefore contains no scraper and no list of sources. It only talks to a server you run yourself.

- [Screenshots](#screenshots)
- [Quick start](#quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [Network routes](#network-routes)
- [Writing a portal](#writing-a-portal)
- [Extending the server](#extending-the-server)
- [Security](#security)
- [For developers](#for-developers)
- [API](#api)
- [Project layout](#project-layout)
- [License](#license)

## Screenshots

| | |
|---|---|
| ![Overview](docs/screenshots/console-01-overview.png) | ![Household: people and the parental control summary](docs/screenshots/console-02-household.png) |
| **Overview.** What runs, what waits for you, the nightly run and the latest events. | **Household.** People, their role, their devices, and the 18+ check for everyone. |
| ![Roles](docs/screenshots/console-03-roles.png) | ![Door: a device code and a join request](docs/screenshots/console-04-door.png) |
| **Roles.** Rights in the app, the 18+ lock and which portals a role sees. | **Door.** A waiting device code and a join request sent from the app. |
| ![Portals](docs/screenshots/console-05-portals.png) | ![Marketplace with a signed portal](docs/screenshots/console-06-marketplace.png) |
| **Portals.** State, network route, who sees it, and seven nights of checks. | **Marketplace.** A portal from a source you added, signed by a key you trust. |

The screenshots show a fresh server with demo people (Alex, Sam, Jordan, Robin). The console's header pictures are hidden in them.

## Quick start

You need Docker with the Compose plugin. Nothing else: no reverse proxy, no prepared network, no folder that must exist beforehand.

```sh
cd server
docker compose up -d
docker compose logs cinelounge     # the setup code is in here
```

The log shows a box like this:

```
┌──────────────────────────────────────────────┐
│  CineLounge is not set up yet.               │
│  Setup code:  4KMS4RZ3                       │
│  Enter it at: http://<this-host>             │
└──────────────────────────────────────────────┘
```

Open `http://<this-machine>:8099` in a browser, type in the code, choose your name and a PIN. You are now the household's admin. The code is only valid until the household exists; without it nobody can set up a fresh server, so a new container does not belong to whoever finds it first on the network.

In the app, enter the server's address under *Settings → CL server* and choose *Or ask to join*. The request appears in the console under **Door**, where you pick a role and approve it.

Everything the household is (people, devices, permissions, portal folders, the stream buffer) lives in the Docker volume `cinelounge-data`. **That volume is what you back up.** The image can be rebuilt at any time. The console can also export the household as one file (see [Backup and restore](#household)).

Optional: `docker compose --profile bonjour up -d` starts a small mDNS announcer so the app finds the server without typing an address. It needs `network_mode: host`, which Docker Desktop on macOS and Windows does not provide.

## Features

### Household

- **People and roles.** Everyone in the household is a person with a role. Three kinds come built in: *admin* (the first person, created at setup), *adult* and *child*. You can rename them and create more roles, each with its own colour, rights and portals. Rights are a fixed set: watch, remember progress and favourites, see 18+ portals, sign in own devices, create invitations.
- **Console access belongs to the person, not the role.** A role decides what someone sees in the app. Whether they may open the console is a switch on the person, and the last person with console access cannot lose it, so the household can never lock itself out.
- **18+ lock per role.** A role with the lock gets no 18+ portal and no "18+" right, whatever else is switched on. The household page shows for every person whether they can see 18+ content and why, so a wrong setting is visible at a glance instead of in the living room.
- **Portals per role.** Each role has its own list of visible portals. The server enforces this: a portal a person may not see is refused on the server, not just hidden in the app.
- **Devices.** A device either belongs to a person (their phone) or to nobody (the living-room TV). On a shared device the viewer picks a profile at start. A picked profile may watch, but never administer: backup, events, settings and pairing are refused on shared devices, because whoever holds the remote should not own the household. The list of what a shared device may do is an allow-list, so a right added later is closed until someone opens it on purpose.
- **Pairing codes.** The console creates a six-character code, valid for five minutes, which you type in on the TV. You choose beforehand whom the device belongs to, or leave it shared.
- **Invitations.** A personal link for a device someone already holds in their hand. Opening it signs the device in for that person, without typing a code off a screen.
- **Join requests from the app.** Someone in the household asks to join from the app with a name and a colour. The request does not carry a role or a PIN: what someone wants, they say; what they are, the admin decides when approving. Requests are rate-limited per origin.
- **Person marks.** Each person can have a mark that travels with their profile in the app (through iCloud). Every further device of that person signs itself in with it. Revoking the mark signs out every device that came through it.
- **PINs with a limit.** Signing in to the console takes a person and a PIN. After five wrong tries the person is paused for a minute; a four-digit PIN without a limit would be no protection.
- **Continue watching, favourites.** Progress and favourites are stored per person, and the person comes from the device token, never from a request parameter, so no device can overwrite someone else's progress. Progress is keyed by portal, title and year, not by the portal's address, so it survives a portal changing its URLs.
- **Event log.** Joins, pairings, role changes, portal changes, unreachable network routes and more are written to an event log the overview shows.
- **Notifications.** Optional Telegram messages when someone wants in or something fails. Setup is three steps in the console: paste a bot token, write `/start` to the bot, confirm the chat. Nobody types a chat id.
- **Backup and restore.** The whole household as one file: people, roles, devices, settings, progress and favourites, plus the marketplace sources and trust anchors. Pairing codes are left out, because a five-minute code restored a day later is only a corpse. Portal folders are not in it either; they are fetched again by their checksum.

### Portals

- **Portals are folders.** A portal is `portal.yml` plus `portal.py` in the portals directory. There is no registration and no base class; a restart (or *Re-read portals* in the console) picks it up.
- **A strict manifest.** Unknown keys, an unknown capability or a missing English name stop the portal from loading, and the console says which key. A typo that is silently ignored would change behaviour without anybody noticing.
- **Menus, rows, series, search.** The app walks a portal like a library: menu, rows with paging, seasons and episodes, sources, play. Search runs across all portals at once; a portal that fails shows its error code next to an empty result instead of breaking the others.
- **Per-portal settings.** A portal can declare settings (an API key, a maximum quality). The console shows them on the portal's page and hands the values to the portal before its first call.
- **Error codes, not sentences.** A portal raises a code with values (`myportal.rate_limited`), and the app shows the sentence in the viewer's language. The server never sends prose that ends up on a screen.
- **Bundled portals.** ARD, ZDF, arte, 3sat and SVT are installed on the first start, but only into an empty portals directory: a portal you removed on purpose does not come back on the next restart.

### Playing

- **Preferred language first.** Sources in the language a viewer chose for a series move to the front; the others stay behind them instead of disappearing.
- **Fallback while playing.** When the app asks for one source and that source does not carry, the server tries the item's other sources. The answer then says `switched: true` and names the one that worked, so the app can tell the viewer.
- **Proving the address.** Before an address goes to the player, the server reads its first bytes: MP4 boxes, the MPEG-TS sync byte or an HLS playlist header. DRM-protected streams are recognised and named instead of handed to a player that cannot open them.
- **Stream buffer.** Some sources hand out a stream that can be opened only once, while a player opens an address several times (HEAD, then ranges for seeking). For those the server catches the stream at the moment of resolving, writes it to disk and serves every further request from the file. Finished files are kept as a stock of up to 20 GB.
- **Relay.** Where a source needs request headers the player cannot send, or refuses the player's connection, the server passes the stream through itself. Nothing is ever transcoded.
- **One fetch for many askers.** The same row asked twice within seconds is fetched once. An older answer is served at once and renewed in the background, so the first request after hours of quiet does not wait for a cold fetch.

### Nightly run

At four in the morning the server checks every switched-on portal end to end: menu, a row, sources, a playable address. Portals run one after the other with a pause in between, so the run never starts more than one child process at a time. The result is kept per night (carried, failed, did not run) and shown as a strip of seven nights next to each portal. A marketplace without a central directory has no curator; this measurement is the next best thing. The console's **Workshop** starts the run by hand and calls single portal methods for debugging.

### Marketplace

- **No central index, on purpose.** You add the address of an index (a JSON file) and decide yourself whom you trust. The server keeps no directory of foreign portals.
- **Signed packages.** A portal entry can carry an Ed25519 signature over its id, version and SHA-256. You add the publisher's public key as a *trust anchor*. The marketplace then shows each portal as `signed` (valid signature from a trusted key), `unsigned` (nobody vouched for it; installing needs a confirmation) or `bad` (a signature that does not verify; there is no switch that installs it).
- **Checksum before unpacking.** An archive is downloaded in full, compared with the SHA-256 from the index, and only then unpacked entry by entry. Absolute paths, `..` and symlinks are refused.
- **Install, update, roll back.** Nothing updates by itself. The console shows when a newer version exists and you press the button. The previous version is kept once, so a broken update is one click back.
- **A cached offer.** The last good copy of each index stays, with the time it was read and the last error, so a source that is down does not empty the marketplace.

### Network

- **Direct or through an HTTP proxy.** Every portal goes out over the house's own connection. A *network route* is a named HTTP proxy you can lay a portal onto instead, per portal, in the console. Everything that portal fetches then goes through the proxy: its pages and the video the relay passes on. See [Network routes](#network-routes).
- **A missing route is an error, not a detour.** A portal laid onto a route that does not exist (any more) is marked broken in the console and is not called, instead of quietly going out directly.
- **Route watch.** Each route's state is shown on the **Network** page. A background watch notices when a proxy stops answering (two misses five minutes apart) and writes one event when it goes and one when it returns.
- **mDNS.** The optional `melder` container announces the server on the home network (see [Quick start](#quick-start)).

### Console

A React app served by the server itself, in **English, German and Turkish**, light or dark, usable on a phone. Its areas:

| Area | What you do there |
|---|---|
| Overview | What runs, what is stuck, what waits; the nightly strip; the latest events |
| Door | Join requests, device codes, invitations |
| Household | People and roles, devices, console access, PINs, marks |
| Portals | Switch portals on and off, settings, network route, visibility, seven nights |
| Marketplace | Offer, sources, trust anchors; install and roll back |
| Network | HTTP proxies and their state; add or remove a proxy |
| Workshop | Call a portal by hand; start the nightly run; re-read portals |
| Settings | Notifications, backup and restore, household name, service status, language and appearance |

## Architecture

```mermaid
flowchart LR
    app["CineLounge app<br/>Apple TV · iPhone · iPad"]
    browser["Console<br/>in a browser"]

    subgraph cl["container: cinelounge (1000:1000, 512 MB)"]
        api["FastAPI service<br/>household · marketplace · console"]
        child["child process<br/>one portal call<br/>256 MB · 20 s"]
        api -- "fork() per call" --> child
    end

    data[("volume<br/>cinelounge-data")]
    proxy["HTTP proxy<br/>optional, per portal"]
    net(("Internet"))

    app -- "HTTP :8099" --> api
    browser -- "HTTP :8099" --> api
    api --- data
    child -- "direct" --> net
    child -- "network route" --> proxy --> net
```

Inside the service the code is layered, and the layers only import downwards: `core` (models, contract, error codes) depends on nothing; `web` depends on everything and nothing depends on it. The rule is written down in `setup.cfg` and checked by `import-linter`, because Python has no compiler that would catch an import in the wrong direction.

## Network routes

By default every portal goes out directly. To send a portal through an HTTP proxy instead, name the proxy once and pick it for that portal in the console (**Portals → the portal → Route**).

Proxies come from two places:

```sh
# in .env next to docker-compose.yml: name=address, several separated by spaces
CL_PROXIES="office=http://10.0.0.2:3128 lab=http://user:secret@lab.example:8080"
```

or from the console (**Network → Add proxy**), stored in the household. A name is `a-z`, `0-9` and `-`, at most 32 characters. A piece of `CL_PROXIES` that cannot be read is skipped with a log line, so one typo does not keep the service from starting.

The **Network** page lists every route with its state, its response time and the portals on it; *Check* calls each of those portals once through the route. Credentials in a proxy address never leave the server: the API shows `host:port` only.

## Privacy

- **No site scripts run.** Portals fetch pages and read them; nothing executes the sites' JavaScript, so their trackers, fingerprinting and cookie banners never run.
- **The relay keeps devices apart from sites.** Where the server passes a stream through (`cinelounge/stream/proxy.py`), the television talks to the server, not to the site, and the relay forwards only a short list of headers. It uses the portal's network route.
- **No telemetry.** The server reports to nobody; the only message it sends on its own is the optional Telegram notice, and only once you enter a bot token. Everything it knows stays in its own volume.

**Where this ends:** it covers what goes through the CL Server. What the app fetches itself (your Jellyfin server, your IPTV provider, TMDb, OMDb, trailers) does not pass through it.

## Writing a portal

A portal is a folder with two files:

```
myportal/
  portal.yml   the manifest: id, names, capabilities, limits, settings
  portal.py    a class named Portal
```

The class answers seven methods, defined in `cinelounge/core/contract.py`:

| Method | Returns | When it runs |
|---|---|---|
| `menu()` | entries | the portal's start screen |
| `listing(entry, next_page, user_input)` | a page of items | a row is opened |
| `children(item)` | items | a series or folder is opened |
| `sources(item)` | sources | play is pressed |
| `resolve(source)` | a stream | right after, per source |
| `search(text)` | items | someone searches |
| `series(address)` | a series key or `None` | a per-series preference is applied |

Three rules matter most: raise error codes, never sentences; treat `next_page` as opaque; and return an empty page instead of raising when there is nothing there. Your code runs in a forked child process with a memory limit, a CPU limit and a 20-second deadline for the whole call, and its return value travels back as JSON.

Start from [`portals/beispiel`](portals/beispiel/), a complete portal with no network of its own, meant to be copied. The full guide, including the manifest rules, testing and how to publish a signed index for the marketplace, is in **[docs/SDK.md](docs/SDK.md)**. Only portals for content that may be streamed legally belong in this repository (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Extending the server

Below portals sits a small plugin system. An extension is a Python package that names an `install(ctx)` function in the entry-point group `cinelounge.extensions` (or in `CL_EXTENSIONS` during development). At startup it may register further portal kinds and manifest fields, readiness checks, a playback policy per portal kind, network route providers, routes, background services and console pages. The server runs complete without any; `GET /health` lists the extensions that loaded and those that failed. The registration points and the rules that keep them working with the fork runner are in **[docs/EXTENSIONS.md](docs/EXTENSIONS.md)**.

## Security

- **Not root.** The service runs as `1000:1000` with `no-new-privileges` and a 512 MB memory limit. The image creates `/data` with the right owner, so a fresh named volume works without `chown`.
- **Foreign code in a child process.** Portal code never runs in the API process. Every call forks a child that imports one portal, answers on a pipe and exits. The child gets a memory limit (`RLIMIT_AS`, 256 MB by default; two may run at once inside the 512 MB), a CPU-time limit, a wall-clock deadline, no core dumps and an answer size limit of 1 MB. A crash or a leak ends with the child, not with the service. The process that knows PINs and device tokens never has portal code in it.
- **Fork barrier.** A fork that lands while another thread holds an SQLite lock copies that lock, locked, into the child. The server therefore never forks while a thread is inside SQLite.
- **No Docker socket.** The service runs foreign code, so it never gets the Docker socket or any other handle on the host.
- **Setup code.** A fresh server cannot be set up without the code from the log, and the code is gone once the household exists.
- **Device tokens.** Every device signs in once and then sends a random token (`X-CL-Device`). Signing out removes the device from the list.
- **Proxy headers.** Behind a reverse proxy the service trusts `X-Forwarded-*` only from the networks in `FORWARDED_ALLOW_IPS`, because the client address is what join requests and sign-ins are rate-limited by.
- **Plain HTTP on the LAN, deliberately.** Port 8099 speaks plain HTTP so that a TV does not fail on a certificate that protects nothing inside your own network. If you want the server reachable from outside, put a reverse proxy with TLS in front of it.

## For developers

Without Docker (Python 3.11 or later, Node 22 for the console):

```sh
cd server
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[check]"
(cd console-app && npm ci && npm run build)        # builds into cinelounge/web/console
CL_DATA=./data uvicorn cinelounge.web.main:app --port 8099
```

For work on the console, start the service on port 8199 and run `npm run dev` in `console-app/`: Vite serves the page on port 5199 and forwards API calls to 8199.

**Portal calls need Linux.** The runner uses `fork()` and resource limits. On macOS the service and the console start, but the kernel refuses the memory limit and every portal call ends with `run.crashed`; on Windows there is no `fork` at all. Use Docker or a Linux machine to run portals.

The full check:

```sh
./scripts/check.sh      # ruff format, ruff check, import-linter, mypy --strict, pytest
```

The tests run on Linux; tests that call a portal through the runner skip themselves where `fork` is missing.

## API

The app and the console use the same HTTP API. `GET /.well-known/cinelounge` describes the server (name, version, supported contract versions `api: [1, 2]`, languages, capabilities) and is how the app decides whether it can talk to it. Signed-in requests carry the device token in `X-CL-Device`; a shared device adds the chosen profile in `X-CL-Profile`.

Errors never contain prose. Every error is a code with values, and the app and the console translate it:

```json
{ "error": { "code": "auth.required", "values": {} } }
```

The most important routes:

| Route | Purpose |
|---|---|
| `GET /.well-known/cinelounge`, `GET /health` | Self-description; health with portal, household, route, buffer and extension counts |
| `POST /setup`, `POST /login`, `POST /logout` | First run with the setup code; console sign-in with person and PIN |
| `POST /join`, `GET /join/{token}` | Ask to join from the app; poll the answer |
| `POST /redeem`, `POST /device/enroll` | Trade a pairing code, an invitation or a person mark for a device token |
| `GET /portals` | The portals this person may see |
| `GET /p/{portal}/menu`, `/list`, `/children`, `/sources` | Walk a portal |
| `GET /search` | Search across all portals |
| `GET /play` | Resolve a source to a playable address (with fallback) |
| `GET /stream` | The relay and buffer for streams that need it |
| `POST/GET/DELETE /state`, `GET /resume`, `GET /favorites` | Progress, continue watching, favourites |
| `/household/…` | Administration: people, roles, devices, joins, portals, marketplace, events, nights, backup, settings |
| `/network/…` | Network routes: list, add and remove proxies, check a route |

## Project layout

| Path | Contents |
|---|---|
| `cinelounge/core/` | Models, the portal contract, error codes, the fork barrier; depends on nothing |
| `cinelounge/portalworks/` | Manifest reader, registry, network routes, playback chain, nightly check, extension registries |
| `cinelounge/portalworks/runner/` | The process boundary: one fork per call |
| `cinelounge/stream/` | Relay, buffer, stream probe |
| `cinelounge/household/` | People, roles, visibility, devices, joins, progress, events, nights, backup |
| `cinelounge/market/` | Sources, trust anchors and signatures, installing |
| `cinelounge/language/` | Message catalogue and language choice |
| `cinelounge/web/` | FastAPI routes, one file per area; serves the built console |
| `console-app/` | The console (React, Vite, TypeScript) |
| `portals/` | The bundled portals and `beispiel`, the SDK template |
| `tests/` | pytest suite |
| `scripts/` | Checks and maintenance scripts |
| `docs/SDK.md` | How to write and publish a portal |
| `docs/EXTENSIONS.md` | The plugin system: registration points and startup order |
| `docker-compose.yml`, `Dockerfile` | The containers |

## License

The CL Server is part of CineLounge and shares its licence: GNU General Public License version 3 or later, see [LICENSE](../LICENSE). Contributions need a signed [Contributor License Agreement](../CLA.md); see [CONTRIBUTING.md](CONTRIBUTING.md). The name, logo and icons are excluded from the licence, see [TRADEMARKS.md](../TRADEMARKS.md).

Copyright © 2026 ms-solutions
