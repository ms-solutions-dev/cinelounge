# Contributing

Thank you for helping. Bug reports, ideas and pull requests are welcome.

## Before you start

- **Bugs:** open an issue with your device (Apple TV, iPhone, iPad), OS version, app version and the steps that lead to the problem. If it is about playback, say whether the source is Jellyfin or an IPTV list and what kind of file or stream it is.
- **Larger changes:** open an issue first, so we can agree on the approach before you invest time.
- **Read [ARCHITECTURE.md](ARCHITECTURE.md)** to see which package a change belongs in. Packages under `Packages/` serve both apps, so a change there must work on the Apple TV and on the phone.
- **Translations:** all user-facing text lives in the string catalogs (`*.xcstrings`). Adding a language is a good first contribution.
- **Read [ARCHITECTURE.md](ARCHITECTURE.md)** to see which package a change belongs in. Shared packages under `Packages/` serve both apps, so a change there must work on the Apple TV and on the phone.

## Contributor License Agreement

Before we can merge your first pull request, you need to sign our [Contributor License Agreement](CLA.md). You keep the copyright in your work; the agreement lets us ship your contribution in the app, including the App Store version.

A bot comments on your first pull request. Reply with the sentence it asks for, and you are done. The signature covers all your future contributions to this repository.

## Building with your own Apple developer account

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, set your own bundle prefix, and put your team ID into `~/.cinelounge-team`. See [TRADEMARKS.md](TRADEMARKS.md) for the name and icon.

## Pull requests

- Keep each pull request focused on one change.
- Follow the existing code style; the project uses `swift-format` with the configuration in `.swift-format`.
- Add or update tests for behaviour you change. Tests use Swift Testing (`@Test`, `#expect`).
- Run the checks before you push: `swift test --package-path Packages/<Name>` for the package you touched, and `./scripts/check-alles.sh` for the full run (format, lint, string catalogs, all package tests and a simulator build for both apps). If you touched only the phone, `./Phone/scripts/check.sh` is enough; if you touched a shared package, run both.
- Write commit messages in English.
