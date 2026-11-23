import Core
import DesignSystemPhone
import Diagnose
import Downloads
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SwiftUI

/// What a tab shows as long as its content is not built.
///
/// The purpose is proof, not a screen: five tabs switch, one sheet opens and only
/// one, an overlay covers the bar, and Back leads to where you came from.
/// That is exactly the done condition of AP4.
///
/// - Note: Replaced screen by screen, starting with AP8 (Home). The file
///   disappears when the last tab is in place.
struct TabPlaceholder: View {

    let view: ViewID
    let model: ShellModel

    /// The stack slot this view comes from — `nil` for a tab root.
    ///
    /// **The payload hangs on it and not on the view kind.** Whoever fetched the request via
    /// ``ViewID`` got the one of the title opened last; see
    /// ``ViewPath``.
    let route: ViewPath?

    /// Whether this view sits in the ``DownloadsDrawer``.
    ///
    /// **Only the Back arrow depends on this, and explicitly not on
    /// ``ShellModel/drawer``.** The drawer can be open while you are long since in
    /// another tab and open the downloads from there via a state —
    /// then it goes through the stack, and an arrow to "Home" would claim a place
    /// you did not come from.
    var inDrawer = false

    /// The size class the shell is in — **needed here for the image widths
    /// with which the sources build their addresses.**
    ///
    /// **The address and the request must carry the same number.** The ``ImageLoader``
    /// keeps address **and** size in its key, and Jellyfin's `maxWidth` sits in the
    /// address: if the view fetched a header image at 760 points while the source
    /// still issued the address for 400 points, the larger image would not even come from the
    /// server — it would be scaled up anyway. That is why this file moves together with ``HeaderImage``,
    /// ``HeaderSpace`` and ``Wordmark`` or not at all.
    ///
    /// An `init` does not set it; the environment does — that is why it does not disturb the three
    /// own initializers.
    @Environment(\.horizontalSizeClass) private var width

    /// The width at which ``SourceAssembly/playerSource(width:rule:)`` fetches its image —
    /// **the only header-box number in this file that does not move with the size class.**
    ///
    /// This image is not drawn in the app at all: it goes through
    /// ``LockScreen`` as `artworkURL` to "Now Playing" — lock screen,
    /// Control Center, AirPlay receiver. Their size depends on the **system** and not on
    /// the width of our window; under Stage Manager an iPad would get the
    /// *compact* class and thus a smaller cover image on a lock screen of unchanged size.
    /// It therefore stays with ``DesignSystemPhone/Metrics/headerBox``
    /// until someone names a number measured against the lock screen.
    private static let lockImageWidth = Metrics.headerBox

    init(tabs: Tab, model: ShellModel) {
        self.view = tabs.root
        self.model = model
        self.route = nil
    }

    init(route: ViewPath, model: ShellModel) {
        self.view = route.view
        self.model = model
        self.route = route
    }

    init(view: ViewID, model: ShellModel, inDrawer: Bool = false) {
        self.view = view
        self.model = model
        self.route = nil
        self.inDrawer = inDrawer
    }

    /// The request of this stack slot.
    private var job: PlaybackJob? {
        route.flatMap { model.navigator.job(zu: $0) }
    }

    /// Which series what is played from this page belongs to.
    ///
    /// **The tile knows first.** With Jellyfin an episode already carries its `SeriesId`
    /// along — see ``TileContent/series``.
    ///
    /// **Otherwise it depends on whether page and tile are the same thing.** A series page plays
    /// one of its episodes: tile and page carry different identifiers, and the page's
    /// is the series. An episode page plays itself, a movie likewise —
    /// both identifiers are equal, and `nil` comes out here.
    ///
    /// **Without this comparison it ran in a circle** (finding of 2026-09-07, on the device): the
    /// episode page is likewise `.detailPortal`, so it entered itself as its own
    /// series. The tile "Bloufeit" would afterwards have opened "1 - Mebik" again — with
    /// an additional field claiming that this was the series.
    private func series(forItem tile: TileContent) -> String? {
        if let own = tile.series { return own }
        guard view == .detail || view == .detailPortal,
            let page = job?.identifier, page != tile.id
        else { return nil }
        return page
    }

    /// What the series is **called** that the played item belongs to.
    ///
    /// **Exactly the same caveat as with ``series(forItem:)``, and therefore the same question.**
    /// A name without the matching identifier would be a label without a target: the tile
    /// would be called "Bloufeit" and still open the episode. Where no series is set, no
    /// name is set either — that is the case of a movie or episode page where page and tile are
    /// the same thing.
    ///
    /// **The name of the page and not that of the tile** — see ``DetailView``.
    private func seriesTitle(forItem tile: TileContent, page: String) -> String? {
        guard series(forItem: tile) != nil, !page.isEmpty, page != tile.title else {
            return nil
        }
        return page
    }

    /// Where a tapped tile leads.
    ///
    /// **One switch and not four** (finding of 2026-09-07): Home, Favorites, Search and
    /// the detail page asked the same question, and each answered it differently. Favorites
    /// knew the portal switch, Home did not — a portal title from
    /// Home therefore landed at the media server, which does not know its identifier.
    ///
    /// Three cases, in this order:
    ///
    /// * **A channel plays**, it has no detail page, it has an image.
    /// * **An episode leads to its series** — see ``TileContent/series``. The series
    ///   opens by itself at the episode in progress, ``DetailModel`` can already do that.
    /// * **Everything else** opens the detail page — which identifier goes there is decided by
    ///   ``series(forItem:)``.
    /// Which detail view belongs in **this** tab.
    ///
    /// **The view identifier says where you are — not who supplies the title.**
    /// ``ViewID/detailPortal`` carries the tab ``Tab/portals``; in the stack of the
    /// Home tab it is a foreign body claiming you are standing elsewhere. On 2026-09-07
    /// on the device: a portal title from "Continue Watching" could **no longer** be opened at all,
    /// while the same title opened via the Portals tab.
    ///
    /// **The source does not need the distinction.** ``AggregateDetailSource`` reads the
    /// origin from the identifier — the same rule as ``PlaybackJob/origin(zu:)``. The
    /// view kind never had any influence on it.
    private var target: ViewID {
        view.tabs == .portals ? .detailPortal : .detail
    }

    /// What the long press on a tile wants to load.
    ///
    /// **Literally the same rule as in ``DetailView``** (`request(forItem:)` there) — and that
    /// is the point: a second request builder would be the place where the library loads
    /// a title differently from the page of the same title.
    ///
    /// **The scope is ``Extent/film``, even for a series.** A ``TileContent``
    /// does not say whether it means a movie or a season, and no shelf knows the season counts of a
    /// foreign series. That is not a wrong statement but a narrower one:
    /// whoever needs the season choice opens the tile — the downloads button is there, and it
    /// knows the open season. The long press is the shortcut for the regular case and
    /// not its replacement.
    ///
    /// **The origin comes from the same rule as the switch** (``AggregateDetailSource``):
    /// guessing again here would mean having two answers to the same question —
    /// and the wrong one would show a portal title resolution levels that do not exist there.
    static func downloadRequest(forItem tile: TileContent) -> DownloadRequest {
        DownloadRequest(
            identifier: tile.id, title: tile.title, beside: tile.beside, extent: .film,
            source: SourceKind(AggregateDetailSource.origin(tile.id)) ?? .jellyfin,
            // **The runtime sits on the tile and is passed through here.** Without it
            // the download sheet names no size — which is honest, but unnecessary: the
            // media server supplies it on every tile. For the portals it stays
            // `nil`, and that is their truth (measured at the bridge, 2026-09-09).
            runtime: tile.duration)
    }

    private func openTile(_ tile: TileContent, origin: Catalog.Origin?) {
        // **The press is in the log before anything is decided.** On 2026-09-07 the
        // client reported "can no longer be pressed at all", and the log said nothing
        // — neither a fetch nor an error. Without this line it is impossible to tell
        // whether the touch did not arrive or whether the path after it led nowhere.
        Diagnose.step(
            .surface,
            "Tile pressed: \(tile.id.prefix(60)) · origin "
                + "\(origin?.rawValue ?? "unknown") · series \(tile.series ?? "—")")
        if origin == .channelList {
            model.navigator.show(
                .player, job: PlaybackJob(identifier: tile.id, origin: .channelList))
            return
        }
        let identifier = tile.series ?? tile.id
        model.navigator.show(target, title: identifier)
    }

    /// Plays a tile from "Continue Watching" in place (2026-10-01) — via
    /// the same play request as the Resume button of the detail page, with the series, so that
    /// the history leads back to it afterwards.
    private func continueTile(_ tile: TileContent) {
        let location = tile.resumePosition
        Diagnose.step(
            .surface, "Continue Watching pressed: \(tile.id.prefix(60)) from \(Int(location)) s")
        model.start(
            PlaybackJob(
                identifier: tile.id, startAt: location > 0 ? location : nil, series: tile.series),
            from: location)
    }

    /// "Details" from Continue Watching: **the series, where it first has to be looked up** — as
    /// on the TV. If the source finds none, the tile opens as usual.
    private func openToSeries(_ tile: TileContent, origin: Catalog.Origin?) {
        guard tile.series == nil,
            let source = SourceAssembly.detailContentSource(
                width: 1, headerWidth: 1, logoWidth: 1, rule: model.parentalControls.rule)
        else { return openTile(tile, origin: origin) }
        Task {
            if let series = await source.seriesReference(zu: tile) {
                Diagnose.step(.surface, "Details: series \(series.prefix(60)) found")
                model.navigator.show(target, title: series)
            } else {
                openTile(tile, origin: origin)
            }
        }
    }

    var body: some View {
        // **The path into the downloads is set here and nowhere else.**
        //
        // Six states name it — "For now to the downloads", "Open downloads" —, and until
        // 2026-09-08 none went there: ``StateView/secondaryAction`` was set at none
        // of the fourteen call sites, so ``StateBlock`` drew no button at all. Built like that it was right
        // — a button into nothing is worse than none —
        // and still a broken promise as soon as the downloads exist.
        //
        // **Here and not in ``ShellView``**, although it would stand even further up there: the
        // body of the shell is long, and the additional modifier has brought the compiler
        // over the time limit. This switch draws **every** view in which a
        // state occurs anyway; further up there would be nothing to gain.
        //
        // **`nil` as long as nothing is set up** — then the button stays away as before.
        content
            .environment(\.openDownloads, downloadsRoute)
            .environment(\.stateRoute, stateRoute)
    }

    /// The path for the loud buttons of the states — **the same place as the path into
    /// the downloads, and for the same reason**: this switch draws every view in which a
    /// state occurs. The mapping itself is in ``StateRoute``; the locks and the
    /// PIN question of the wayfinder apply as for every other path.
    private var stateRoute: @MainActor (ActionTarget) -> Void {
        { [model] target in
            if target == .sync {
                Synchronization.shared.start()
            } else if let view = StateRoute.view(forItem: target) {
                model.navigator.show(view)
            }
        }
    }

    /// The path into the downloads — `nil` if there is none.
    private var downloadsRoute: (@MainActor () -> Void)? {
        guard model.downloads != nil else { return nil }
        return { model.navigator.show(.downloads) }
    }

    /// Home itself — **moved out because it sits in a drawer.**
    ///
    /// The body of ``content`` is a chain of seventeen branches; indenting Home within it
    /// by two more levels has brought the compiler over the time limit.
    @ViewBuilder
    private var home: some View {
        StartView(
            source: SourceAssembly.startSource(
                width: ImageSizes.pixels(
                    forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                headerWidth: ImageSizes.pixels(
                    forItem: MetricClass.headerBox(self.width), reference: ImageSizes.reference),
                logoWidth: ImageSizes.pixels(
                    forItem: MetricClass.headerBox(self.width), reference: ImageSizes.reference),
                rule: model.parentalControls.rule),
            ratings: SourceAssembly.ratingsSource(),
            catalogs: model.catalogs,
            // **Without this line "Arrange shelves" had no effect.** `StartModel` otherwise
            // falls back to `{ .preset }`, and order as well as hiding from the
            // settings never arrived — it went unnoticed because for the
            // client all switches were on.
            loadPreferences: { StartPreferences.load(from: FileStore(), forItem: ProfilePointer.active) },
            // **Which portals count in the shared shelves** (2026-09-07) — the
            // switch is in the portal settings, and it is read on every
            // load of Home, so that flipping it takes effect immediately.
            portalPreferences: { PortalPreferences.load(from: SecureStore()) },
            account: model.accountName,
            onAccountTap: { model.sheetState.open(.accountSwitch) },
            target: model.target,
            onFavoritesTap: model.toFavorites,
            // **The downloads are in the header of Home.** Five tabs are
            // the limit and five are taken; in this app the header is the
            // overflow — Favorites sits one row above it by exactly the same
            // rule. And Home exists in **every** setup, also with
            // "portals only", where the Library tab is missing (E13).
            // **It pulls open the same drawer as the swipe from the left edge**
            // (``EdgeSwipe``) — one place, one motion. Until 2026-09-08 it pushed the
            // view onto the stack, and then it came in from the right.
            onDownloadsTap: model.downloads == nil
                ? nil : { withAnimation(Motion.sheet) { model.drawer = true } },
            open: { tile, origin in openTile(tile, origin: origin) },
            resume: { tile, _ in continueTile(tile) },
            toSeries: { tile, origin in openToSeries(tile, origin: origin) },
            onTargetTap: { model.sheetState.open(.target) },
            // **"All catalogs" leads into the library and not to the playback target.**
            // Until 2026-09-12 the row called the same closure as the button in the
            // header, and that opened the target sheet.
            //
            // **Into the tab and not into a sheet here.** The register is a sheet
            // of ``LibraryScreen`` with its own state (`isIndexOpen`), not one
            // of the shell; `sheetState.open(.catalogChoice)` landed in the placeholder — tried
            // while building and reported immediately by `scripts/sheets.py`. And a
            // second register here would be a second choice of the same thing, which does not switch the
            // library's catalog. The row appears only with
            // ``StartModel/hasMultipleCatalogs`` anyway, so only when there is a library.
            tabPressed: { model.navigator.tabs = .library },
            // **The long press needs the same source as the detail page** — it
            // can `set(seen:)` and `set(favorite:)` and decides by the
            // identifier who is asked. The image widths do not matter here; the
            // commands fetch no image.
            commandSource: SourceAssembly.detailContentSource(
                width: 1, headerWidth: 1, logoWidth: 1,
                rule: model.parentalControls.rule),
            // **And "Download" in the same menu** (2026-09-09). The command appears only
            // where it does something — on a title that is not yet stored, and never on
            // a channel; the rule is at ``TileCommands/isDownloadable``.
            downloadState: { model.downloadState($0) },
            load: { model.openDownloadSheet(forItem: Self.downloadRequest(forItem: $0)) },
            rule: model.parentalControls.rule)
    }

    @ViewBuilder
    private var content: some View {
        if view == .start {
            // **The downloads sit to the left of Home and not behind it.** Why
            // a drawer and not a step in the stack is explained at ``DownloadsDrawer`` —
            // in short: whoever pulls to the right fetches something that lies to the left, and a stack
            // pushes its view in from the right.
            //
            // **Without downloads it does not exist** — the same condition as for the button in the
            // header.
            DownloadsDrawer(pending: Bindable(model).drawer) {
                home
            } excerpt: {
                TabPlaceholder(view: .downloads, model: model, inDrawer: true)
            }
        } else if view == .library {
            LibraryScreen(
                source: SourceAssembly.catalogSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                onFavoritesTap: model.toFavorites,
                open: { tile in openTile(tile, origin: nil) },
                // **The long press, since 2026-09-09** Without these three lines the
                // library does not attach its menu at all — see ``TileCommands``: a
                // menu with three ineffective commands would be worse than none.
                commandSource: SourceAssembly.detailContentSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                    headerWidth: ImageSizes.pixels(
                        forItem: MetricClass.headerBox(self.width),
                        reference: ImageSizes.reference),
                    logoWidth: ImageSizes.pixels(
                        forItem: MetricClass.headerBox(self.width),
                        reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                downloadState: { model.downloadState($0) },
                load: { model.openDownloadSheet(forItem: Self.downloadRequest(forItem: $0)) }
            )
            .id(LibraryScreen.Rebuild(rule: model.parentalControls.rule, account: model.accountName))
        } else if view == .detail || view == .detailFilm || view == .detailPortal {
            DetailView(
                identifier: job?.identifier ?? "",
                source: SourceAssembly.detailContentSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                    headerWidth: ImageSizes.pixels(
                        forItem: MetricClass.headerBox(self.width),
                        reference: ImageSizes.reference),
                    logoWidth: ImageSizes.pixels(
                        forItem: MetricClass.headerBox(self.width),
                        reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                external: SourceAssembly.ratingsSource(),
                people: SourceAssembly.careerSource(),
                rule: model.parentalControls.rule,
                // **The detail page passes its own identifier along as the series.** It is the
                // only place where the connection is known: from a
                // portal episode identifier like `serieshub:1-mebik:` the
                // series cannot be derived, and the bridge supplies none for an episode. The
                // history writes it along, and "Continue Watching" then leads to the
                // series instead of to a page with a runtime and nothing else.
                play: { tile, pageTitle in
                    model.start(
                        PlaybackJob(
                            identifier: tile.id, series: series(forItem: tile),
                            seriesTitle: seriesTitle(forItem: tile, page: pageTitle)),
                        from: 0)
                },
                // **The position was thrown away until 2026-09-06** The body read
                // `{ tile, _ in … }` — the second value was the start position, and "From the beginning"
                // and every chapter jump hang on it. Whoever had stopped at minute 17
                // landed at minute 17 again on the chapter jump.
                playFrom: { tile, location, pageTitle in
                    model.start(
                        PlaybackJob(
                            identifier: tile.id, startAt: location, series: series(forItem: tile),
                            seriesTitle: seriesTitle(forItem: tile, page: pageTitle)),
                        from: location)
                },
                open: { tile in
                    openTile(tile, origin: nil)
                },
                back: { model.navigator.back() },
                // **The downloads button asks the same management as the
                // downloads screen.** Two would know nothing of each other: the detail page
                // would show an outline while the downloads listed the same title as "loading".
                downloadState: { identifier in
                    model.downloads.map { DownloadState.forItem(.init(identifier), in: $0.downloads) }
                },
                // **Resolving goes through the same play request as when playing.** A
                // second resolution chain would be the place where downloads and player
                // drift apart — and you would only notice when a title plays
                // and cannot be downloaded.
                // **Pause and resume — nothing more.** Queuing runs through the
                // sheet, because scope and level are decided there.
                onDownloadsTap: { request in
                    model.downloads?.setEnabled(
                        identifier: request.identifier, job: request.job,
                        resolve: PlaybackJob(identifier: request.identifier, series: request.series))
                },
                // **Title and scope come from the page that knows them.** The switch
                // knows an identifier; a downloads list whose rows are called `jf-8dec87ad` is
                // a list nobody can read.
                queueDownload: { job, request, queueNew in
                    model.downloads?.create(
                        job, resolve: PlaybackJob(identifier: request.identifier, series: request.series))
                    // **The standing order starts only where a series stands behind it.** Without
                    // its identifier there would be nothing to top up for.
                    if let series = request.series {
                        model.downloads?.setQueueNewEpisodes(queueNew, forItem: series, for: job)
                    }
                },
                // **Only after the first finished download** — see
                // ``DownloadSheet/offersTopUp``.
                offersTopUp: model.downloads?.hasLocalDownloads ?? false,
                // **Asked only for portals** — Jellyfin and the provider have no
                // hosts, and a fetch for a list that does not exist would be
                // a wait without a result.
                hostSource: SourceAssembly.portalDataSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)
                    // **`@Sendable` explicitly on the closure.** `PortalContentSource` is Sendable,
                    // the closure built from `.map` was not — and a non-sendable
                    // closure that runs in a `Task` is exactly the warning this
                    // project does not let stand.
                ).map { source in
                    { @Sendable identifier in
                        PortalSourceChoice(try await source.host(zu: identifier))
                    }
                },
                // **"Language of this series", as on the TV** (AP58 G1, A9) — the same
                // portal source; the page shows the choice only for a portal series.
                languageSource: SourceAssembly.portalDataSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)),
                // **The same target as in the header and the same sheet.** The
                // detail page held its own until 2026-09-12 that nobody else
                // saw — and opened a sheet whose Apple TV row was permanently grayed out.
                target: model.target,
                onTargetTap: { model.sheetState.open(.target) })
        } else if view == .live {
            LiveView(
                // **Through the filter of the parental controls** (AP52): a child sees here only
                // the channels of its allow list — see ``KidsChannelSource``.
                source: SourceAssembly.channelSource(rule: model.parentalControls.rule),
                withSport: !model.parentalControls.rule.scope.isInChildMode,
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                onFavoritesTap: model.toFavorites,
                // **Here and only here `.channelList` travels along.** A channel identifier
                // carries no feature by which it could be recognized, and is not meant to get one
                // — the Live tab is the place that knows it for certain.
                matches: { channels in
                    model.navigator.show(
                        .player,
                        job: PlaybackJob(identifier: channels.id, origin: .channelList))
                },
                // **A past broadcast as a recording** (A2) — the same player, the same
                // filtered source; only the request carries which broadcast.
                playRecording: { channels, broadcast in
                    model.navigator.show(
                        .player,
                        job: PlaybackJob(
                            identifier: channels.id, origin: .channelList, catchUp: broadcast))
                },
                // **Measured and not asserted** — see ``LocationMonitor``.
                location: model.locationMonitor.location)
        } else if view == .portals {
            PortalsView(
                source: SourceAssembly.portalDataSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)),
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                onFavoritesTap: model.toFavorites,
                open: { tile in openTile(tile, origin: .portals) },
                resume: { tile in continueTile(tile) },
                commandSource: SourceAssembly.detailContentSource(
                    width: 1, headerWidth: 1, logoWidth: 1,
                    rule: model.parentalControls.rule),
                // **Also in the Portals tab** (2026-09-09): the long press did not yet work in Portals,
                // only in the Library. The load-bearing line is `load` — without it
                // "Download" is not even there.
                downloadState: { model.downloadState($0) },
                load: { model.openDownloadSheet(forItem: Self.downloadRequest(forItem: $0)) },
                width: ImageSizes.pixels(
                    forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                location: model.locationMonitor.location)
        } else if view == .favorites {
            // **The tab that was a placeholder until 2026-09-06** It was in the bar,
            // had an icon and a title — and no branch here. Whoever tapped it
            // got "favoriten · not built yet" together with three developer buttons.
            FavoritesScreen(
                sources: SourceAssembly.favoritesSources(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                // **No heart on this screen.** It is the place the heart leads to.
                open: { tile, origin in openTile(tile, origin: origin) },
                commandSource: SourceAssembly.detailContentSource(
                    width: 1, headerWidth: 1, logoWidth: 1,
                    rule: model.parentalControls.rule),
                downloadState: { model.downloadState($0) },
                load: { model.openDownloadSheet(forItem: Self.downloadRequest(forItem: $0)) })
        } else if view == .search {
            SearchScreen(
                sources: SourceAssembly.searchSources(
                    width: ImageSizes.pixels(forItem: 70, reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                networkMonitor: model.networkMonitor,
                // **The side path from "nothing found" leads into the Live tab.** The
                // state has named it since E17 ("Search in Live"); nobody served it until
                // 2026-09-06.
                searchInLive: { model.select(.live) },
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                onFavoritesTap: model.toFavorites,
                open: { tile, origin in openTile(tile, origin: origin) },
                // **Search too** (2026-09-09): it is the screen on which you find a
                // title you do not have yet — so exactly the one on which
                // "Download" is most obvious.
                commandSource: SourceAssembly.detailContentSource(
                    width: 1, headerWidth: 1, logoWidth: 1,
                    rule: model.parentalControls.rule),
                downloadState: { model.downloadState($0) },
                load: { model.openDownloadSheet(forItem: Self.downloadRequest(forItem: $0)) },
                location: model.locationMonitor.location)
        } else if view == .settings {
            SettingsScreen { target in model.navigator.show(target) }
        } else if view == .portalSettings {
            PortalSettingsView()
        } else if view == .ratingsSettings {
            RatingsView()
        } else if view == .appearance {
            AppearanceView(arrangeShelves: { model.navigator.show(.arrangeShelves) })
        } else if view == .arrangeShelves {
            // **Until 2026-09-06. "Arrange shelves" led into the placeholder.** The row in
            // ``AppearanceView`` pointed at this identifier, and there was no branch here —
            // which made Home the only view of the app on which nobody could
            // change anything.
            //
            // **With the real catalogs** (check finding A-S2, 2026-09-27): the state of the
            // accesses carries only placeholders; the libraries come from the same source
            // as the library.
            HomeScreen(
                state: SourceAssembly.state(),
                catalogSource: SourceAssembly.catalogSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                channelSource: SourceAssembly.unfilteredChannelSource(),
                portalDataSource: SourceAssembly.portalDataSource(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)),
                catalog: SourceAssembly.catalog(
                    width: ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)))
        } else if view == .playback {
            PlaybackView()
        } else if view == .diagnose {
            DiagnoseView(log: { model.navigator.show(.log) })
        } else if view == .log {
            LogView()
        } else if view == .accountSettings {
            AccountSettingsView(
                accounts: { model.navigator.show(.accounts) },
                storage: { model.navigator.show(.storage) },
                certificates: { model.navigator.show(.certificates) },
                share: ProfileCloud.attached == nil
                    ? nil : { model.navigator.show(.cloud) })
        } else if view == .pinReset {
            if let cloud = ProfileCloud.attached {
                PinFallbackView(cloud: cloud) { model.navigator.back() }
            }
        } else if view == .cloud {
            // **Without the cloud the row does not exist at all** — this branch is the way back
            // for the case that someone calls the identifier from elsewhere.
            if let cloud = ProfileCloud.attached {
                CloudView(
                    cloud: cloud, opened: model.openedProfileLink,
                    pairingCode: model.openedPairingCode,
                    done: {
                        model.openedProfileLink = nil
                        model.openedPairingCode = nil
                    })
            }
        } else if view == .accounts {
            AccountsView(
                profile: { account in model.profileImages.profile(toAccount: account) },
                select: { account in model.switchAccount(account) },
                model: model.accounts,
                newAccount: { model.navigator.show(.newAccount) },
                migration: { model.navigator.show(.migration) },
                certificates: { model.navigator.show(.certificates) },
                handoff: { model.navigator.show(.handoff) },
                pinReset: { model.navigator.show(.pinReset) })
        } else if view == .newAccount {
            // **Until 2026-09-06. "Add account" led into the placeholder.**
            // ``NewAccountView`` had no occurrence besides its declaration — the
            // screen was built, ticked off and unreachable.
            NewAccountView(
                model: SourceFormModel(deviceID: SourceAssembly.deviceID),
                ingest: { credential, kind in
                    model.navigator.back()
                    model.addAccount(credential, asChild: kind)
                })
        } else if view == .profile {
            // **Manage profiles** (G3, finding B1) — the same shared management as in
            // "Who's watching?", behind the door `profile`.
            ManageProfilesView(
                administration: model.profile, isPinSet: model.parentalControls.isPinSet,
                afterIntervention: { model.followProfileChoice() })
        } else if view == .profileChanged {
            // **Create a profile from "Who's watching?"** (decision 3) — after saving, back;
            // the new profile then appears in the row.
            NewProfileView(
                existing: nil, suggestion: model.profile.nextColor, previousLimit: nil,
                isPinSet: model.parentalControls.isPinSet
            ) { draft in
                model.profile.save(draft, existing: nil)
                model.navigator.back()
            }
        } else if view == .parentalControls {
            ParentalControlsView(
                status: model.parentalControls, state: model.catalogs,
                account: model.accounts.signedInAccount,
                // **The keypad opens via the wayfinder and not from here.**
                // It is the same locked door as any other; a second sheet on
                // this view would be a second place with the same rule.
                askPin: { job in model.navigator.query(job) {} },
                approvals: { model.navigator.show(.approvals) },
                accessPolicy: { await SourceAssembly.accessPolicy() },
                pinReset: { model.navigator.show(.pinReset) },
                // **Unfiltered** — the "Live for children" selection shows the whole catalog,
                // so that one can choose from it (AP52).
                channelCatalog: { [source = SourceAssembly.unfilteredChannelSource()] in
                    await source?.channels().channels ?? []
                },
                listNames: Dictionary(
                    (SourceAssembly.listStore()?.visiblePlaylists ?? []).map { ($0.id, $0.name) },
                    uniquingKeysWith: { first, _ in first }))
        } else if view == .approvals {
            ApprovalsView(
                state: model.parentalControls, source: SourceAssembly.approvalsSource())
        } else if view == .forgotPin {
            // **The same two ways as on the TV** (G3, finding B8): confirm on the other device
            // or after 24 hours — without an Apple account there is none.
            if let cloud = ProfileCloud.attached {
                PinForgottenView(cloud: cloud) { model.unlocked() }
            }
        } else if view == .downloads {
            // **The downloads are drawn and no longer merely linked.** Until here there
            // was no branch for ``ViewID/downloads`` — the same type of error as with
            // Storage on 2026-09-07: linked, but not built.
            DownloadsView(
                model: DownloadsModel(
                    administration: model.downloads, networkMonitor: model.networkMonitor,
                    parentalControls: model.parentalControls),
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                // **No register on the downloads title — it was dropped with V4.**
                // Usability finding 13 demanded "Downloads ⌄", and that was right
                // as long as the downloads were the third catalog of the library (V1). Since they are
                // a place of their own behind the header button, the title selects nothing:
                // a selection indicator without a choice is a promise that breaks at the first
                // press. The rest of the finding stands — profile picture, search field, no
                // Back arrow, everything in the same places as in the library.
                tabPressed: nil,
                // Without a bar the band above it stands there and already says so — see
                // ``DownloadsView/isBandOnTop``.
                isBandOnTop: model.barState == .downloadsOnly,
                // **The arrow appears only in the drawer** — there is a place
                // you came from, and it is named. The reason why
                // the downloads otherwise carry none is at ``DownloadsView/back``.
                back: inDrawer
                    ? (
                        CaptionLabel.key("tab.home").readable,
                        { withAnimation(Motion.sheet) { model.drawer = false } }
                    ) : nil,
                storage: { model.navigator.show(.storage) },
                toLibrary: { model.navigator.show(.library) },
                network: { model.sheetState.open(.network) },
                remove: { identifier in model.downloads?.remove(identifier) },
                control: { identifier in
                    model.downloads?.setEnabled(
                        identifier: identifier.rawValue,
                        job: DownloadJob(
                            id: identifier, title: identifier.rawValue, source: .jellyfin,
                            extent: .film),
                        resolve: PlaybackJob(identifier: identifier.rawValue))
                },
                // **The tap leads to the title and not into the trash** (2026-09-09) —
                // the rationale is at ``DownloadsView/open``.
                //
                // **To the detail page and not into the player**, and that is half the
                // answer to the requirement of the same day (a poster leads to a detail
                // view with the downloaded episodes): season, episodes, ratings and
                // cast are there — the player is one tap away from it, the other way round
                // there would be no path to it.
                //
                // **And the page comes from the downloads, not from the network** (2026-09-09,
                // added later). ``DownloadsDetailSource/identifier(forItem:)`` puts the prefix
                // in front by which the ``AggregateDetailSource`` recognizes it — the same
                // construction as with `PortalItemID`.
                //
                // **Why not simply the raw identifier:** the downloads page is a
                // **different** page. Whoever has downloaded three of twenty-four episodes wants to see
                // three in Downloads and twenty-four in the library. Without
                // the prefix the poster would lead to the network source — and without a network to
                // an error screen above a movie that is on the disk.
                open: { job in
                    model.navigator.show(
                        .detail, title: DownloadsDetailSource.identifier(forItem: job.id.rawValue))
                },
                // **A series poster leads to the series and not to its first episode.**
                // The key is ``DownloadDescription/series``; the group knows it,
                // the view passes it through.
                openSeries: { series in
                    model.navigator.show(
                        .detail, title: DownloadsDetailSource.identifier(forItem: series))
                })
        } else if view == .storage {
            // **This branch did not exist until 2026-09-07**, and the path to it led
            // three taps from Settings into the developer placeholder.
            StorageView(
                downloads: model.downloads,
                showDownloads: { model.navigator.show(.downloads) })
        } else if view == .otherDevices {
            OtherDevicesView(
                share: ProfileCloud.attached == nil ? nil : { model.navigator.show(.cloud) },
                setUpTV: { model.navigator.show(.handoff) },
                // The target sheet of the header: choose a TV, then control.
                remote: { model.sheetState.open(.target) })
        } else if view == .about {
            AboutView(
                privacy: { model.navigator.show(.privacy) },
                licenses: { model.navigator.show(.licenses) },
                report: { model.navigator.show(.report) })
        } else if view == .privacy {
            PrivacyView(storage: { model.navigator.show(.storage) })
        } else if view == .licenses {
            LicensesView()
        } else if view == .report {
            ReportView(
                groups: { model.navigator.show(.groups) },
                parentalControls: { model.navigator.show(.parentalControls) })
        } else if view == .certificates {
            CertificatesView()
        } else if view == .remote {
            // **The model comes from the shell and is not created here.** Until
            // 2026-09-12 it was created at this point, that is, on entering the
            // screen, and died on leaving. The comment here claimed it
            // held the connection across sheet changes — it did, but not across
            // a screen change, and so "where is it playing" could be answered
            // nowhere else. See ``ShellModel/remote``.
            RemoteView(
                model: model.remote,
                account: model.accountName,
                onAccountTap: { model.sheetState.open(.accountSwitch) },
                // **"Bring it here" opens the player like any other path.** A
                // path of its own for the handoff would be a second place where a
                // play request originates — and the first to be forgotten at the next
                // refactoring.
                matches: { job in model.navigator.show(.player, job: job) },
                // **What plays on the TV holds the downloads back** (E63). The case had stood
                // in ``ConnectionScarcity/Claim/playbackOnSecondDevice`` all along
                // and was never set: "The case only the phone knows — on the Apple
                // TV nobody could notice it, because there is no downloading there."
                //
                // **As long as the remote is connected, the phone knows it.** That
                // is not the whole case — whoever closes the remote does not know again —,
                // but it is exactly the situation in which you are most likely to download and watch at the
                // same time: whoever has the remote open is watching
                // on the TV.
                playsRemotely: { isRunning in
                    model.downloads?.claim = isRunning ? .playbackOnSecondDevice : .unrestricted
                })
        } else if view == .handoff {
            // **The model is created here and not in the view.** It accesses the
            // Keychain, lists and parental controls; a model that the
            // view builds itself on every redraw would read them anew each time.
            //
            // **A code from the system camera has already been read** (``CodeEntry``): the model
            // then starts with it, as if the reader in the app had seen it.
            HandoffView(
                model: {
                    let handoff = HandoffModel(
                        status: SetupState(), backup: model.parentalControls)
                    if let code = model.openedHandoffCode { handoff.read(code) }
                    return handoff
                }(),
                close: {
                    model.openedHandoffCode = nil
                    model.navigator.back()
                })
        } else if view == .migration {
            MoveView()
        } else if view == .channelLists {
            ChannelListsView(
                storage: SourceAssembly.listStore() ?? SourceAssembly.emptyStorage(),
                newList: { model.navigator.show(.newChannelList) },
                // **The list travels via the wayfinder and not via a state here.**
                // The overlay rebuilds its views at every step; a `@State` in
                // this file would not survive the push.
                editList: { list in
                    model.toEdit = list
                    model.navigator.show(.editChannelList)
                })
        } else if view == .editChannelList {
            if let list = model.toEdit {
                EditChannelListView(
                    list: list,
                    storage: SourceAssembly.listStore() ?? SourceAssembly.emptyStorage(),
                    done: { model.navigator.back() })
            }
        } else if view == .newChannelList {
            // **The setup's form and no second one.** A second place for
            // the same four fields would be a second place where the same errors look
            // different — the roadmap says so literally.
            NewChannelListView(deviceID: SourceAssembly.deviceID) {
                model.navigator.back()
            }
        } else if view == .liveSettings {
            LiveSettingsView(
                source: SourceAssembly.unfilteredChannelSource(),
                state: model.parentalControls,
                groups: { model.navigator.show(.groups) },
                // **The adult switch is there and not here.** It applies per
                // account; two switches for the same matter would leave open which one
                // applies.
                parentalControls: { model.navigator.show(.parentalControls) })
        } else if view == .groups {
            GroupsView(source: SourceAssembly.unfilteredChannelSource())
        } else if view == .player {
            PlayerView(
                // **The whole request and not just its identifier.** Without the origin
                // a channel would fall through to the media server again — see
                // ``CompositePlayerSource``.
                job: job ?? PlaybackJob(identifier: ""),
                source: SourceAssembly.playerSource(
                    width: ImageSizes.pixels(
                        forItem: Self.lockImageWidth, reference: ImageSizes.reference),
                    rule: model.parentalControls.rule),
                networkMonitor: model.networkMonitor,
                // **Only the player gets it, and only a channel shows it.** The
                // channel list above the running picture is the transmission of what hangs
                // to the left of the broadcast on the TV.
                channelSource: SourceAssembly.channelSource(rule: model.parentalControls.rule),
                back: { model.navigator.back() })
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(spacing: MetricsBoard.phone.gutter) {
                Text(verbatim: view.rawValue)
                    .font(TypeLevel.lead.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(verbatim: "not built yet")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)

                VStack(spacing: MetricsBoard.phone.gutter) {
                    Button {
                        // **A sheet that the shell really draws.** Previously
                        // `.catalogChoice` stood here — the register hangs on the
                        // ``LibraryScreen`` and not on this state, so the button led
                        // out of the scaffold back into the same scaffold.
                        model.sheetState.open(.sources)
                    } label: {
                        Text(verbatim: "Open a sheet")
                    }
                    .buttonStyle(.quiet)

                    Button {
                        model.navigator.show(.detail)
                    } label: {
                        Text(verbatim: "One level deeper")
                    }
                    .buttonStyle(.quiet)

                    Button {
                        model.navigator.show(.settings)
                    } label: {
                        Text(verbatim: "Open an overlay")
                    }
                    .buttonStyle(.quiet)
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, MetricsBoard.phone.section)
            }
        }
    }
}

/// What a sheet shows as long as its content is not built.
struct SheetPlaceholder: View {

    let identifier: SheetID
    let model: ShellModel

    /// Open "forgot PIN" requests — for the marks under the circles in "Who's watching?".
    @State private var escapes = PinFallbacks.none

    var body: some View {
        // **The profile picture is the way to Settings** — that is also what the button is called in the
        // draft ("Profile and Settings"). Until 2026-09-06 it led into the
        // placeholder, and Settings were **not reachable at all** on the device;
        // they hung solely on the check hook `CINELOUNGE_ANSICHT`. It was not
        // noticed while building but when asking how to get there — a
        // screen that opens only with an environment variable does not exist for
        // the viewer.
        switch identifier {
        case .accountSwitch: accountSwitch
        case .profileImage: profileImageSheet
        case .profilePin: profilePinSheet
        case .network: networkSheet
        case .load: downloadSheet
        case .target: targetSheet
        default: placeholder
        }
    }

    /// Where playback goes.
    ///
    /// **The sheet existed, the path to it did not.** ``TargetSheet`` had stood ready since 2026-09-06
    /// and was called from exactly one place — the detail page, and there hard-wired with
    /// `isTVReachable: false`. Until 2026-09-12 the button in the header ended up in the
    /// placeholder; the client reported it with a screenshot.
    ///
    /// **It searches as long as the sheet is open** — no longer. `searchDevices()`
    /// cancels a running search itself, so it does no harm if the
    /// remote does the same afterwards.
    ///
    /// **And the choice has an effect, otherwise it is not one.** "Apple TV" connects and
    /// leads into the remote; from there a title goes over. "This iPhone"
    /// disconnects — whoever wants to play here does not want to play over there at the same time.
    private var targetSheet: some View {
        TargetSheet(
            target: model.target,
            isTVReachable: model.remote.hasTV
        ) { chosen in
            switch chosen {
            case .phone:
                Task { await model.remote.disconnect() }
                model.sheetState.close()
            case .tv:
                // **With one TV it connects, with several it is chosen.** Two
                // Apple TVs in one house are explicitly planned for
                // (``SecondScreen/RemoteControl/deviceName`` therefore takes the
                // device name); taking one of them would not be a choice but a
                // coin toss — and you would notice only when something starts in the wrong room.
                let devices = model.remote.found
                if devices.count == 1, let one = devices.first {
                    Task { await model.remote.connect(using: one) }
                }
                model.sheetState.close { model.navigator.show(.remote) }
            }
        }
        .task { model.remote.searchDevices() }
        .presentationDetents([.fraction(SheetID.target.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// The download sheet — **the same as on the detail page, just called from further out.**
    ///
    /// **Since 2026-09-09 the long press** on a tile in Library,
    /// Search, Home and Favorites opens it too. These four are not the host of their
    /// own sheet — it hangs on the shell —, and that is why the request sits at
    /// ``ShellModel/downloadRequest`` instead of in the view.
    ///
    /// **It is built from the same three inputs as in ``DetailView``**, literally:
    /// whoever wrote a second version here would have two download sheets
    /// that decide differently — one with a host list and one without.
    @ViewBuilder
    private var downloadSheet: some View {
        if let request = model.downloadRequest {
            DownloadSheet(
                job: request.job,
                enqueue: { done, queueNew in
                    model.sheetState.close()
                    model.downloads?.create(
                        done, resolve: PlaybackJob(identifier: request.identifier, series: request.series))
                    if let series = request.series {
                        model.downloads?.setQueueNewEpisodes(queueNew, forItem: series, for: done)
                    }
                },
                offersTopUp: model.downloads?.hasLocalDownloads ?? false,
                sources: SheetPlaceholder.hostSource)
        }
    }

    /// The host list — **asked only for portals.**
    ///
    /// Jellyfin and the provider have no hosts; a fetch for a list that does not
    /// exist there would be a wait without a result. The same source as when playing:
    /// `/sources` answers for a title which hosts and language versions there are,
    /// and a second list would be the place where the two drift apart.
    static let hostSource: (@Sendable (String) async throws -> PortalSourceChoice)? =
        SourceAssembly.portalDataSource(
            width: ImageSizes.pixels(
                forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)
        ).map { source in
            { @Sendable identifier in
                PortalSourceChoice(try await source.host(zu: identifier))
            }
        }

    private var accountSwitch: some View {
        ScrollView {
            AccountSwitchSheet(
                profile: model.profile.profile, active: model.profile.active,
                headerProfile: model.headerProfile,
                escapes: escapes,
                changeProfilePicture: { model.openProfileImageChoice() },
                // **No profile PIN any more** (AP59 N4, 2026-09-30): `nil` hides the row —
                // one PIN for the household, asked when leaving the child profile.
                isProfilePinSet: nil,
                profilePin: {},
                // **In child mode a profile is a door (E23)** — ``ShellModel/switchProfile(_:)``
                // asks it, then the latch of the profile PIN.
                select: { profile in model.switchProfile(profile) },
                handle: { mutate in
                    switch mutate {
                    case .create: model.createProfile()
                    case .manage: model.manageProfiles()
                    }
                },
                // **First close, then open** — see ``SheetState/close(following:)``. Doing both
                // in the same pass gave a black screen: a
                // `fullScreenCover` does not come up while a `sheet` is still closing.
                manage: {
                    model.sheetState.close { model.navigator.show(.settings) }
                },
                isManageable: model.isManageable)
        }
        // **Re-read on opening** (AP49): since the last look a sync may have brought
        // an image or a profile from the TV, and the person sheet is
        // the place where you look for it first.
        .onAppear {
            model.profileImages.load()
            model.profile.load()
        }
        .task {
            escapes = await PinFallbacks.read(cloud: ProfileCloud.attached, ledgerStore: FileStore())
        }
        .presentationDetents([.fraction(SheetID.accountSwitch.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// Choose the profile picture (AP49).
    ///
    /// **Without a choice no content** — then the sheet was opened from outside without
    /// anyone saying whose picture. It closes again immediately instead of showing a grid
    /// without a target.
    @ViewBuilder
    private var profileImageSheet: some View {
        Group {
            if let choice = model.profileImageChoice {
                ProfilePictureSheet(choice: choice) { chosen in
                    model.saveProfileImage(chosen)
                }
            } else {
                Color.clear.onAppear { model.sheetState.close() }
            }
        }
        .presentationDetents([.fraction(SheetID.profileImage.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// The profile PIN (AP52) — **without a state no content**, the same rule as with the
    /// image choice: the sheet closes again immediately instead of showing a keypad without a
    /// target.
    ///
    /// **Swiped away means cancelled**: the state falls with the sheet, and a latch without a
    /// PIN switches nothing.
    @ViewBuilder
    private var profilePinSheet: some View {
        Group {
            if let state = model.profilePinState {
                ProfilePinPanel(
                    state: state, administration: model.profilePins(),
                    openLatch: { model.openLatch($0) },
                    latchReleased: { model.latchReleased() },
                    done: { model.closeProfilePin() })
            } else {
                Color.clear.onAppear { model.sheetState.close() }
            }
        }
        .presentationDetents([.fraction(SheetID.profilePin.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// Network and usage.
    ///
    /// **The rule lives in the management and not in the sheet.** A sheet that kept its
    /// own copy would leave it behind on closing — and the next request
    /// would run under the old one.
    private var networkSheet: some View {
        NetworkSheet(
            route: model.networkMonitor.route,
            rule: Binding(
                get: { model.downloads?.rule ?? NetworkRule() },
                set: { model.downloads?.rule = $0 })
        )
        .presentationDetents([.fraction(SheetID.network.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    private var placeholder: some View {
        ZStack {
            ColorRole.surfaceHigh.color.ignoresSafeArea()
            VStack(spacing: MetricsBoard.phone.gutter) {
                Text(verbatim: identifier.rawValue)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(verbatim: "Portion \(identifier.portion)")
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                Button {
                    model.sheetState.open(.sources)
                } label: {
                    Text(verbatim: "Another sheet")
                }
                .buttonStyle(.quiet)
                .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
    }
}
