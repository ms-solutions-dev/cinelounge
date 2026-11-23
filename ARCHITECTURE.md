# Architecture

This is the map for contributors: which packages exist, what each one may depend on, and why the cuts are where they are. If you want to move a boundary, this page says what it costs.

## Two apps, one repository

| | Apple TV | iPhone and iPad |
|---|---|---|
| Location | repository root: `App/`, `TopShelf/`, `project.yml` | `Phone/`: `Phone/App/`, `Phone/project.yml` |
| Screens | `Packages/Features` | `Phone/Packages/FeaturesPhone` |
| Design | `Packages/DesignSystem` | `Phone/Packages/DesignSystemPhone` |
| Minimum OS | tvOS 18 | iOS / iPadOS 18 |
| Check script | `scripts/check.sh` | `Phone/scripts/check.sh` |

A TV is operated from three metres with a focus ring that moves in five directions; a phone is held at thirty centimetres and operated with a thumb. They are two interfaces, not two sizes of one, so each app has its own screens and its own design package. What they share is the material underneath: models, server clients, playback, profiles and rules. The two apps are meant to look and behave the same; they differ only where the form factor forces it.

Everything else is **shared, not copied**. The phone project includes the shared packages from `../Packages`. A change there applies to both apps and can break both, which is why `scripts/check-alles.sh` runs both checks one after the other.

The app targets are thin: an entry point, the language setting, startup, and the string catalog. Everything else is in packages.

## Packages

Dependencies point downward only. Nothing depends on a `Features` package. `Core` depends on no other package of this repository except `WordingKit` (and the test helper `SourceProbe`), plus the external `grundstock`.

```
 Apple TV app                         iPhone / iPad app
      │                                     │
   Features                            FeaturesPhone
      │                                     │
 DesignSystem                  DesignSystemPhone · Downloads · NetworkStatus
      └──────────────────┬──────────────────┘
                         │   shared
   Flows · SecondScreen · Household · Trailer
   ProfileKit · ParentalControls · Diagnose · Styling
                         │
   JellyfinKit · PlaylistKit · PortalKit · RatingsKit · Playback
                         │
                       Core ── WordingKit
                         │
                    Grundstock (Packages/Grundstock)
```

### Shared by both apps

| Package | Role |
|---|---|
| `Core` | The lowest layer: media models, the `ContentSource` contract, container readers and remuxers (Matroska, MPEG-TS, CMAF), audio decoders for DTS, AC-3 and MPEG Layer II, the engine choice, local storage (`FileStore`). No SwiftUI, no UI. Includes two C targets: `DCADec` (libdcadec, LGPL-2.1) and `MP2Synthesis`. |
| `WordingKit` | One string catalog for the texts that shared packages need, so no app has to carry keys it never shows. Sits below `Core`. |
| `SourceProbe` | Tiny helper for the checks that read source text. |
| `JellyfinKit` | The Jellyfin connection: sign-in, Quick Connect, server discovery, item mapping, playback info, a session that can trust self-issued certificates. |
| `PlaylistKit` | IPTV: M3U and Xtream clients, XMLTV parsing, the channel database and programme cache, on-demand titles, list synchronisation. |
| `PortalKit` | The client for the optional CL Server (see below): requests, models and the translation between server versions. |
| `RatingsKit` | External scores and the matching of series to them (AniList, MyAnimeList; the package also contains OMDb and TMDb clients). |
| `Playback` | The playback engines behind one contract: `NativePlaybackEngine` (AVPlayer) and `SampleBufferPlaybackEngine` (direct renderer). Also Now Playing, AirPlay, Picture in Picture and the head cache. |
| `Trailer` | Resolves a trailer from YouTube. |
| `ParentalControls` | Age limits, PIN, child profiles, the table of locked doors, and the filter that sits between a source and the screen. Logic only, so a test can walk through every door. |
| `ProfileKit` | A person: accounts, settings and state; the profile book, PIN, backup and CloudKit mapping. |
| `Household` | Signing devices in and out for a household, and assigning portals to profiles. |
| `SecondScreen` | The contract between two devices: the setup bundle, one-time code, encryption, Bonjour discovery and the remote-control commands. Phone and TV each implement one end in their own app. |
| `Flows` | Screen-independent flows and models used by both apps: login, profile management, search, channel list, favourites, home layout, and `PlaybackCore` (see below). Testable without UI. |
| `Diagnose` | One logging route for both apps: an error log that survives a restart, report building and redaction. |
| `Styling` | Colour roles, contrast maths, type levels and surfaces, without any UI toolkit. |

### Apple TV only

| Package | Role |
|---|---|
| `DesignSystem` | Focus styles, button styles, tokens sized for three metres, image cache. |
| `Features` | Home, library, detail, live, player, search, favourites, settings, sport schedule, accounts. |

### iPhone and iPad only

| Package | Role |
|---|---|
| `DesignSystemPhone` | Sizes, colours and building blocks for touch. |
| `FeaturesPhone` | All screens, sorted into folders by area (`Start`, `Library`, `Live`, `Detail`, `Player`, `Remote`, `Settings`, `Setup` and so on). One package on purpose: the boundaries that matter are below the screens, not between them. |
| `Downloads` | Offline copies: queue, background session, resume, storage budget, network rules. |
| `NetworkStatus` | Where the device is (Wi-Fi, cellular, tunnel, nothing), as one source of truth for the rules that depend on it. |

### Outside this repository

`Grundstock` (in `Packages/Grundstock`, package identity `grundstock`) is a small foundation package shared with other apps of the same author; it is kept in sync with their copy by hand. It holds what every app of this kind needs and nothing about media: certificate trust for self-issued certificates, keychain access, the diagnostic trace, device identity, and a second product, `CloudSync`, the CloudKit carrier for profiles (one record zone per profile, shareable). `Core` re-exports its types.

The **CL Server** (CineLounge server) is a separate, optional project. The apps work without it.

## The two contracts that hold it together

- **`ContentSource`**: where content comes from. A Jellyfin server and an IPTV provider answer the same questions, so the screens do not need to know which one they are showing. A source can be wrapped by a filter (`ParentalControls.FilteredSource`) without the screen noticing.
- **`PlaybackEngine`**: what plays it. `PlaybackEngineSelector` chooses in a fixed order and returns its reason with the decision, so you can always see why a file landed on a given engine. The system player is preferred. The direct renderer exists because HLS needs whole segments before the first frame, which on live channels with long keyframe distances meant seconds of waiting; it remuxes packets on the device and hands them to `AVSampleBufferDisplayLayer`.

Above the engine sits `PlaybackCore` (in `Flows`), the player's decisions without an engine: progress reports to the server, the next-episode offer, skip offers and automatic skipping, the "Still watching?" count, the sleep timer and stall detection. The platform feeds it position and state on every beat and shows what comes out, so TV and phone cannot drift apart. The switches that belong to a person (automatic skip, spoiler protection, the "Still watching?" limit) live in the profile as `BingePreferences`.

## Where a setting belongs

One rule for both apps, so that the same setting has the same name in the same place everywhere:

| Kind | Where | Why |
|---|---|---|
| **Secret**: password, access token, PIN hash | Keychain (`SecureStore`) | Everything else sits in plain text in every backup. |
| **Structure**: lists, order, preferences, mappings | JSON file (`Core/FileStore`) | It grows, has a shape and belongs in the backup. |
| **State**: where someone was, what they watched | Per-profile state book | It belongs to the person, not to the device. |
| **Cache**: images, fetched lists, prefetched data | Caches directory | It may disappear at any time. |

Structures are written as indented JSON with sorted keys, and the file store picks its directory with a write probe, because a write to one location once silently went nowhere on a real Apple TV while the same code passed on the Mac. One exception has a hard reason: the age limit and the "lock unrecognised ratings" switch live in the keychain although they are structure. They apply together with the PIN, and the PIN survives a reinstall. If they lived in a file, a reinstall would leave a PIN, child mode and no limit at all, and the filter would run and filter nothing.

`scripts/storage_rule.py` checks this rule.

## The companion server (optional)

The CL Server runs in your own network and offers portals (sources) the apps can list and play. The apps know no source-specific page or pattern: they talk to the server through `PortalKit`, which also translates between server versions. Without a server address the corresponding area does not appear. The server is a separate repository and is not needed to build or use the apps.

## Scripts and checks

| Script | What it does |
|---|---|
| `scripts/check.sh` | The Apple TV quality run, after every change: format, lint, project files, string keys, alternate icons, analysis scripts (storage rule, silent errors, colours, type scale, linkage), tests, a build for the tvOS simulator, and the test suite once more in a release build. |
| `Phone/scripts/check.sh` | The same for the phone, plus checks for buttons without an effect, sheets leading nowhere, plural forms, the settings catalog, and a launch in airplane mode. |
| `scripts/check-alles.sh` | Both, one after the other (never in parallel: they build the same shared packages), plus the tests of `Grundstock`. Green only if all are green. |
| `scripts/device.sh`, `scripts/release.sh` | Install on your own Apple TV; archive and upload to App Store Connect (`--check` verifies the setup first). The phone has its own copies in `Phone/scripts/`. |
| `scripts/run.sh` | Build and launch in the simulator. Installs from `.dd`, not from the usual DerivedData, so you never test a stale build. |
| `Phone/scripts/project.sh` | Generates the Xcode project of the phone app. |

Tests use Swift Testing (`@Test`, `#expect`). Every package declares macOS next to its device platforms so that `swift test` runs on the Mac in seconds instead of needing a simulator. Code under `#if os(tvOS)` is not compiled by `swift test`: "build complete" on the Mac only means the macOS half compiled, so the simulator build in `check.sh` is the one that counts.

## Conventions

- One file per thing: a view, a sheet, a building block, a model.
- Package boundaries are enforced by declaring dependencies explicitly: a package can only use what it names.
- After changing a `Package.swift`, resolve once (`xcodebuild -project CineLounge.xcodeproj -scheme CineLounge -derivedDataPath .dd -resolvePackageDependencies`). Otherwise the build can be green without having seen the new package.
- All user-facing text goes through the string catalogs; `scripts/strings.py` checks that keys are used and translated.
- When a rule has bitten once, there is a script for it.
