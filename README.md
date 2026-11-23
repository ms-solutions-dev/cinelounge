<h1 align="center">CineLounge</h1>

<p align="center">
  A player for Apple TV, iPhone and iPad for your own Jellyfin server and your IPTV channel lists.<br>
  Jellyfin · M3U · Xtream · XMLTV · CL Server
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-18%2B-111111?logo=apple" alt="tvOS 18+">
  <img src="https://img.shields.io/badge/iOS-18%2B-111111?logo=apple" alt="iOS 18+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-GPL--3.0-2f6b4f" alt="License: GPL-3.0">
</p>

<p align="center">
  <img src="docs/screenshots/tv-01-home.png" width="390" alt="Apple TV: home with continue watching">
  <img src="docs/screenshots/tv-03-film.png" width="390" alt="Apple TV: film detail page">
</p>
<p align="center">
  <img src="docs/screenshots/tv-05-live.png" width="390" alt="Apple TV: live channels">
  <img src="docs/screenshots/tv-04-series.png" width="390" alt="Apple TV: series with spoiler protection">
</p>
<p align="center">
  <img src="docs/screenshots/phone-01-home.png" width="190" alt="iPhone: home">
  <img src="docs/screenshots/phone-02-library.png" width="190" alt="iPhone: library">
  <img src="docs/screenshots/phone-05-live.png" width="190" alt="iPhone: live channels with programme guide">
  <img src="docs/screenshots/phone-06-cl-server.png" width="190" alt="iPhone: CL Server">
</p>

## Why CineLounge?

The Apple TV is the best screen in most homes, but the apps for self-hosted media tend to treat it as an afterthought, and the phone as another. CineLounge is built for the sofa first: a Jellyfin library, live TV from your own channel lists and the files you downloaded for the train, in one app with the same look and the same behaviour on every device. It starts fast, remembers where you stopped, and works for several people sharing one Apple TV.

## Download

CineLounge is not on TestFlight or the App Store yet. Until then you can build it yourself (see [Building](#building)).

## Features

- **Jellyfin library.** Movies, series and collections with detail pages, continue watching, next up and search. Sign in with a password or with Jellyfin's Quick Connect code, so nobody types a password with a remote. Servers on your network are found automatically.
- **IPTV.** Channel lists in M3U and Xtream format, an XMLTV programme guide, a channel list with now-and-next, favourites, catch-up where your provider offers it and on-demand titles from Xtream accounts.
- **Direct playback.** AVPlayer where the file allows it, plus a direct renderer that remuxes Matroska and transport streams on the device. Audio the system cannot decode (DTS, AC-3, MPEG Layer II) is decoded in the app. Picture in Picture and AirPlay on the phone.
- **Skip buttons** for intro, outro and recap, taken from the segments your Jellyfin server provides.
- **Binge-watching.** At the end of an episode the next one is offered as a small card with its still and a counter; one press starts it, or you can watch the credits. Intro and recap can be skipped automatically (with a short "Back" to undo it), unseen episodes can hide their still and description to avoid spoilers, and after three episodes without a button press the player asks "Are you still watching?" (three, five or never). These three are settings of each profile. A sleep timer in the player's track board stops playback after the current episode or after 30 or 60 minutes.
- **Subtitles and audio tracks** with remembered preferences, including ASS/SSA subtitles.
- **Profiles for shared devices.** Each person gets their own accounts, continue-watching state, shelves and appearance, optionally protected by a PIN. Profiles sync through your private iCloud database and can be shared with another iCloud account.
- **Parental controls.** Age limits, child profiles that only see approved channels and titles, and a PIN that survives a reinstall.
- **Downloads on iPhone and iPad.** Download for offline use, with a storage budget, background transfers, resume and a Wi-Fi-only rule.
- **Phone as a second screen.** Set up the Apple TV from the phone by handing over your accounts, and use the phone as a remote and keyboard.
- **Top Shelf** on the Apple TV home screen, respecting the active profile's age limit.
- **Trailers** from YouTube, and anime scores from AniList and MyAnimeList.
- **Portals through the CL Server (optional).** If you run the companion CL Server in your network, the app can show the portals it provides, such as the public media libraries it ships with. The app itself contains no list of such services and works fully without the server.
- **Light and dark** looks, alternate app icons, in English, German and Turkish.

## Screenshots

**Apple TV**

| | |
|---|---|
| ![Home](docs/screenshots/tv-01-home.png) | ![Library](docs/screenshots/tv-02-library.png) |
| ![Film](docs/screenshots/tv-03-film.png) | ![Series with spoiler protection](docs/screenshots/tv-04-series.png) |
| ![Live TV](docs/screenshots/tv-05-live.png) | ![CL Server](docs/screenshots/tv-06-cl-server.png) |
| ![Who's watching?](docs/screenshots/tv-07-whos-watching.png) | |

**Setting up on the Apple TV** — a profile first, then its sources, each one optional.

| | |
|---|---|
| ![Welcome](docs/screenshots/tv-setup-01-welcome.png) | ![Profile](docs/screenshots/tv-setup-02-profile.png) |
| ![Jellyfin with a code](docs/screenshots/tv-setup-03-jellyfin-code.png) | ![Sources](docs/screenshots/tv-setup-04-sources.png) |
| ![Done](docs/screenshots/tv-setup-05-done.png) | |

**iPhone and iPad**

| | | |
|---|---|---|
| ![iPhone home](docs/screenshots/phone-01-home.png) | ![iPhone film](docs/screenshots/phone-03-film.png) | ![iPhone CL Server](docs/screenshots/phone-06-cl-server.png) |
| ![iPhone series](docs/screenshots/phone-04-series.png) | ![iPhone live TV](docs/screenshots/phone-05-live.png) | ![iPhone library](docs/screenshots/phone-02-library.png) |

| | |
|---|---|
| ![iPad home](docs/screenshots/ipad-01-home.png) | ![iPad series](docs/screenshots/ipad-04-series.png) |

**Setting up on iPhone**

| | | | |
|---|---|---|---|
| ![Welcome](docs/screenshots/phone-setup-01-welcome.png) | ![Jellyfin with a code](docs/screenshots/phone-setup-02-jellyfin-code.png) | ![Sources](docs/screenshots/phone-setup-03-sources.png) | ![Done](docs/screenshots/phone-setup-04-done.png) |

The screenshots are taken against a demo server with freely licensed films and art (Blender Studio, David Revoy's Pepper&Carrot and others, CC BY); no video plays there.

## FAQ

### Is CineLounge a Jellyfin client for Apple TV?

Yes. CineLounge is a Jellyfin client for Apple TV, iPhone and iPad, and it also plays IPTV channel lists. It is built for the Apple TV first and looks and behaves the same on every device.

### How is CineLounge different from other Jellyfin apps?

It combines your Jellyfin library, live TV from your own channel lists and offline downloads in one app, with profiles for several people on one Apple TV, parental controls, skip buttons for intro and recap, and a next-episode card for binge-watching.

### Do I need a Jellyfin server?

No. You can use CineLounge with a Jellyfin server, with IPTV channel lists, or with both.

### Does CineLounge include channels or films?

No. CineLounge is a player. It shows the media on your own Jellyfin server and the channel lists you add yourself in M3U or Xtream format; it contains no list of channels or services.

### Which formats does it play?

Whatever AVPlayer can play, plus Matroska (MKV) and transport streams, which are remuxed on the device. DTS, AC-3 and MPEG Layer II audio are decoded in the app, and ASS/SSA subtitles are supported.

### Do I need the CL Server?

No. The app works fully without it. The optional CL Server adds a household console and portals such as the public media libraries it ships with.

### Can several people share one Apple TV?

Yes. Each profile has its own accounts, continue-watching state and appearance, optionally protected by a PIN, and child profiles only see approved titles and channels.

### Is there an Android TV version?

No. CineLounge runs on Apple TV (tvOS), iPhone and iPad.

## Requirements

| | |
|---|---|
| Xcode | 27 or later |
| tvOS / iOS / iPadOS | 18.0 or later |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.46 or later |
| A Jellyfin server | For the library; optional if you only use IPTV |
| An IPTV subscription | Optional; M3U or Xtream credentials of your own |

## Building

The Xcode projects are generated from `project.yml` and are not checked in. The repository holds two apps: the Apple TV app in the root and the iPhone/iPad app in `Phone/`. The foundation package `Grundstock` lives in `Packages/Grundstock` (see [Project layout](#project-layout)); one clone is all you need.

```sh
git clone https://github.com/ms-solutions-dev/cinelounge.git
cd cinelounge

xcodegen generate            # Apple TV: CineLounge.xcodeproj
open CineLounge.xcodeproj

cd Phone && xcodegen generate  # iPhone and iPad: Phone/CineLounge.xcodeproj
```

Choose the `CineLounge` scheme and run it on a simulator. To run on your own devices, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, set `CL_BUNDLE_PREFIX` to your own prefix and put your team ID into `~/.cinelounge-team`. Create the matching app IDs, app group (`group.<prefix>.cinelounge`) and iCloud container (`iCloud.<prefix>.cinelounge`) in your developer account. The name and icon are not part of the licence, see [TRADEMARKS.md](TRADEMARKS.md).

Each package has its own tests and runs on the Mac without a simulator:

```sh
swift test --package-path Packages/Core
```

The full quality run, which formats, lints, checks the string catalogs and licence data, runs all package tests and builds for the simulator:

```sh
./scripts/check.sh          # Apple TV
./Phone/scripts/check.sh    # iPhone and iPad
./scripts/check-alles.sh    # both, one after the other
```

## The CL Server (optional)

`server/` holds the companion server: a small Python service with a web console for the household (people, roles, devices, 18+ lock) and the portals the app can show. It ships with portals for ARD, ZDF, arte, 3sat and SVT and an example portal to start your own (`server/docs/SDK.md`).

```sh
cd server
docker compose up -d
docker compose logs cinelounge     # the setup code is in here
```

Then open `http://<this-machine>:8099`, type in the code, pick a name and a PIN. In the app, enter its address under *Settings → CL server* and choose *Or ask to join*; you approve the request in the console.

The app works fully without the server. The server needs nothing but Docker: no reverse proxy, no prepared network. Its tests run with `pytest` (`pip install -e ".[check]"`, Linux).

What the server can do, how its exits and marketplace work, how to write a portal and screenshots of its console: see [server/README.md](server/README.md).

## Project layout

| Path | Contents |
|---|---|
| `App/`, `TopShelf/` | Apple TV app and Top Shelf extension: entry point, catalog, resources |
| `Phone/App/` | iPhone and iPad app: entry point, catalog, resources |
| `Packages/Features` | The Apple TV screens |
| `Phone/Packages/FeaturesPhone` | The iPhone and iPad screens |
| `Packages/Core` | Models, contracts, container readers and remuxers, audio decoders; no UI |
| `Packages/JellyfinKit` | The Jellyfin connection |
| `Packages/PlaylistKit` | M3U, Xtream and XMLTV |
| `Packages/PortalKit` | The client for the optional CL Server |
| `server/` | The CL Server: service, web console (`server/console-app`), portals, tests, Docker files |
| `Packages/Playback` | Playback engines behind one contract |
| `Packages/RatingsKit` | AniList and MyAnimeList scores |
| `Packages/ProfileKit`, `Household`, `ParentalControls` | Profiles, sign-in and age rules |
| `Packages/SecondScreen` | The channel between phone and TV |
| `Packages/Flows`, `Diagnose`, `WordingKit` | Shared flows and models, diagnostics, shared strings |
| `Packages/Styling`, `DesignSystem` | Colours, type, and the Apple TV components |
| `Phone/Packages/` | `DesignSystemPhone`, `Downloads`, `NetworkStatus` |
| `scripts/`, `Phone/scripts/` | Build, check and release scripts |

How the packages fit together is described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Privacy

CineLounge talks only to the servers you add: your Jellyfin server, your channel list providers, the optional CL Server, and, for the features that need them, YouTube (trailers), AniList or MyAnimeList (anime scores), TMDb (cast filmographies) and OMDb (ratings), the last two only with an API key you enter yourself. There is no analytics, no tracking and no account with us. Profiles sync through your private iCloud database; passwords and PIN hashes stay in the keychain on your device. Diagnostic reports stay on the device until you choose to share them, and sensitive values are redacted.

## Contributing

Bug reports and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). Before your first pull request is merged, you sign our [Contributor License Agreement](CLA.md) with a one-line comment. You keep the copyright in your work.

**Translations:** all user-facing text lives in the string catalogs (`*.xcstrings`). Adding a language is a good first contribution.

## Credits

Third-party code, as listed in the app under *About* (data in `App/Resources/Lizenzen.json`):

| Component | Licence |
|---|---|
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) 2.1.0 | MPL-2.0 |
| [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) 0.4.9 | MIT |
| [Get](https://github.com/kean/Get) 2.2.1 | MIT |
| [swift-nio](https://github.com/apple/swift-nio) 2.101.3, [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) 1.28.0 | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) 1.3.1, [swift-collections](https://github.com/apple/swift-collections) 1.6.0, [swift-system](https://github.com/apple/swift-system) 1.7.5 | Apache-2.0 |
| [libdcadec](https://github.com/foo86/dcadec) by Alexander E. Patrakov and others, compiled into `Packages/Core` for DTS decoding (see `COPYING.LGPLv2.1` there) | LGPL-2.1-or-later |

Jellyfin is a trademark of its respective owners; CineLounge is an independent client and is not affiliated with the Jellyfin project. Film and series metadata shown in the app comes from your own server.

This product uses the TMDB API but is not endorsed or certified by TMDB. Ratings can also come from [OMDb](https://www.omdbapi.com) (not endorsed by IMDb), anime scores from [AniList](https://anilist.co) and [MyAnimeList](https://myanimelist.net); each needs your own key where the service requires one.

## License

Copyright © 2026 ms-solutions

CineLounge is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE). The name, logo and app icons are excluded, see [TRADEMARKS.md](TRADEMARKS.md).
