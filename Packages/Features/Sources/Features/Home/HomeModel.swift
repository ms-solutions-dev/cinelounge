import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import ParentalControls
import ProfileKit
import RatingsKit
import SwiftUI

/// Loads and holds the content of the Home screen.
final class HomeModel: ObservableObject {

    /// One row of the Home screen.
    /// `Sendable` because the rows are built concurrently — one task per
    /// library, otherwise the wait would be four times as long.
    /// The identifier of the collections row — **fixed, for the same reason as
    /// ``ShelfRule/portalShelfID``.**
    ///
    /// ``ShelfPreferences`` remembers order and visibility per identifier. Until
    /// 2026-09-12 it existed only as a string in the body and in no list to choose from —
    /// so the row could be neither moved nor switched off, although its own
    /// comment says it can be "switched off through shelf management like any other".
    /// - Note: **`nonisolated`, because ``ShelfPlan`` needs it without the main actor.**
    ///   An identifier is a string and not state; binding it to the actor
    ///   would mean hoisting the plan onto it just to read one word.
    public nonisolated static let collectionsID = ShelfIdentifier.collections

    public nonisolated struct Shelf: Identifiable, Equatable, Sendable, Codable {
        public let id: String
        /// Translation key, not finished text.
        public let titleKey: String
        public let items: [MediaItem]
        /// Wide format for episodes, portrait format for titles.
        public let usesWideCards: Bool
        /// What kind of library the row comes from; empty for "Continue Watching",
        /// because that one spans all libraries. Needed to keep
        /// home videos out of the hero area.
        public let libraryKind: Core.Library.Kind?

        public init(
            id: String,
            titleKey: String,
            items: [MediaItem],
            usesWideCards: Bool,
            libraryKind: Core.Library.Kind? = nil
        ) {
            self.id = id
            self.titleKey = titleKey
            self.items = items
            self.usesWideCards = usesWideCards
            self.libraryKind = libraryKind
        }
    }

    /// What is currently on screen. A single state instead of several flags,
    /// so that "is loading and is faulty" cannot occur at the same time.
    enum State: Equatable {
        case loading
        /// Several titles for the hero area, not one: it pages on by itself.
        /// The list is already filtered and sorted — the view only decides
        /// which of them is currently shown.
        case ready(heroes: [MediaItem], shelves: [Shelf])
        /// **The state and no longer a translation key** (AP25, 2026-09-11).
        ///
        /// This used to be a `String` identifier, and next to it ``HomeView`` built its own
        /// error screen — symbol, heading, button, all of it once more. A
        /// second home-grown version interprets the same failure differently from the
        /// first sooner or later; that was exactly the finding on the phone on 2026-09-06.
        case failed(PlaybackPhase)
        case empty

        /// Whether a failure is being displayed. Needed by ``RetriesWhenAwake``, which
        /// reloads after waking only in that case.
        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// **When the state leaves `.loading`, the Home screen can draw** (AP51,
    /// 2026-09-24) — and the intro makes room for the cards. `.failed` and `.empty` count
    /// too; the reasoning is at ``DrawReadiness``.
    ///
    /// **Here and not in ``load(force:)``:** The state has more than one writer,
    /// and a reporter at one place in the loading would forget the next one that is added.
    @Published private(set) var state: State = .loading {
        didSet { if state != .loading { drawReadiness.notify() } }
    }

    /// Whom the Home screen tells that it can draw. Tests set their own.
    var drawReadiness = DrawReadiness.shared

    /// Third-party ratings for the title currently shown at the top. Only for the one
    /// currently visible — querying all eight candidates up front would be eight
    /// requests for seven numbers nobody reads.
    @Published public private(set) var heroRatings: [String: ExternalRatings] = [:]

    /// The libraries this screen has loaded — **unfiltered.**
    ///
    /// **It exists because of a regression from 2026-09-12 that I built myself.**
    /// The pill at the top was supposed to leave out empty sections and asked
    /// ``MainView``'s own list for that — but that list is **only loaded the first time
    /// "Movies" or "Series" is opened**. On the Home screen it was empty, so
    /// only "Home" remained: the way into a section depended on information that only
    /// exists once you go into the section.
    ///
    /// **Not the shelves, but the libraries.** A shelf is also missing when
    /// someone hid it or ``ShelfRule/perOrigin`` capped it — neither
    /// says anything about whether movies exist. Anyone who tied the pill to the shelves
    /// would remove the whole section along with one hidden row.
    ///
    /// **Empty means "not loaded yet"**, and the pill then shows everything. A
    /// screen that removes sections on the first draw and brings them back half a
    /// second later flickers worse than one that carries one row too many.
    @Published public private(set) var libraries: [Core.Library] = []

    /// **Since AP29 all catalogs and no longer just the media server** (2026-09-11).
    ///
    /// This used to be `JellyfinSource`, and with it the Home screen built its shelves
    /// exclusively from the media server — **anyone who had a channel list but no
    /// media server saw a Home screen that did not exist for them.** Now the
    /// protocol stands here, and ``AggregateSource`` acts for all origins at once.
    ///
    /// **Filtered before a shelf is built** (AP58 R1, finding K3): The source sits
    /// behind ``ParentalControls/FilteredSource`` — every shelf, the in-progress items, the
    /// collections and the portal levels go through the same filter, instead of every place
    /// asking ``ParentalControls/ProtectionRule/shows(_:)`` itself. A blocked title was
    /// therefore never in a row, not even for a moment.
    private let source: any ContentSource

    /// The parental controls in force — **`.pending` as long as nothing is blocked.**
    ///
    /// **A named value and not `nil`.** An optional rule value would mean that every
    /// call site has to handle the "no rule" case itself; one of them would forget
    /// it, and there would be no block there — which looks like an oversight and is not
    /// meant to be one. The full reasoning is at ``ProtectionRule/pending``.
    ///
    /// **Passed in at construction and not observed.** An account switch rewrites the
    /// signed-in session; ``RootView`` then rebuilds the source, and with it
    /// this model. A rule that changes under a running model therefore does not
    /// exist — an observer for it would be a second route to the same goal.
    private let rule: ProtectionRule

    /// The form factor — **passed in at construction, for the same reason as ``rule``.**
    ///
    /// ``ShellModels`` rebuilds the Home screen as soon as the form factor changes; a
    /// running model whose shelves change their origin underneath it does not exist.
    /// ``HomeView`` reads it from here so that shelves and tiles come from **one** source:
    /// A view that asked for its form factor elsewhere could lay child tiles
    /// over an adult's shelves.
    let surface: Surface
    private let anime: AnimeRating?
    /// Where the choice comes from of which libraries may appear at the top.
    private let store: any KeyValueStore

    /// Where the shelf order comes from — **a second store, and with good reason.**
    ///
    /// Since AP40 (2026-09-21) the order of the Home screen lives in a file and no longer in the
    /// Keychain; the hero-area choice and the per-library sorting are still
    /// there. Fetching both through ``store`` would silently take the two others
    /// along — without a migration they would be empty at the next start.
    private let shelfStore: any KeyValueStore

    /// What is currently on TV — **from the downloads, without network.**
    ///
    /// **Passed in and not taken from the ``AggregateSource``**, and this is the one
    /// exception in this package: A channel list has no *latest* but a
    /// **programme**. It does not answer `libraries()` and `items(in:)` at all — the
    /// information comes from the programme guide, and that lives in ``LiveLibrary``.
    /// Forcing it through the content protocol would mean teaching it something
    /// that only one of four sources can do.
    ///
    /// Without a channel list the callback returns nothing, and the shelf stays absent.
    private let liveShelf: @Sendable () async -> [MediaItem]

    /// The channels of the last six hours — **at the front of "Continue Watching", as on the phone**
    /// (decision 27, C5). The computation is at ``MainView/recentChannels(channels:rule:)``.
    private let recentChannels: @Sendable () async -> [MediaItem]

    /// Removes a channel from "Continue Watching" — by its identifier; the computation is at
    /// ``MainView/forgetChannel(channels:)`` (Live check, finding 7).
    private let forgetChannel: @Sendable (String) async -> Void
    /// Where the image of the last Home screen lives — see ``HomeSnapshot``. `nil`
    /// means: no image (tests; the app passes in the cache).
    private let snapshotStore: (any KeyValueStore)?

    public init(
        source: any ContentSource,
        anime: AnimeRating? = nil,
        rule: ProtectionRule = .pending,
        surface: Surface = .familiar,
        store: any KeyValueStore = SecureStore(),
        shelfStore: (any KeyValueStore)? = nil,
        snapshotStore: (any KeyValueStore)? = nil,
        liveShelf: @escaping @Sendable () async -> [MediaItem] = { [] },
        recentChannels: @escaping @Sendable () async -> [MediaItem] = { [] },
        forgetChannel: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.source = rule.about(source)
        self.anime = anime
        self.rule = rule
        self.surface = surface
        self.store = store
        self.shelfStore = shelfStore ?? FileStore()
        self.snapshotStore = snapshotStore
        self.liveShelf = liveShelf
        self.recentChannels = recentChannels
        self.forgetChannel = forgetChannel
    }

    /// Fetches the rating for a hero-area title after the fact.
    ///
    /// Called on switching and not on loading: The Home screen should
    /// not wait for third-party services, and what has been fetched once stays in the
    /// client's cache.
    public func loadHeroRatings(for item: MediaItem) async {
        guard heroRatings[item.id] == nil, let anime else { return }

        // With Continue Watching the top item is an episode, and it carries no identifier of
        // its own — it hangs off the series. Without this detour exactly the
        // most common case on the Home screen would stay without a rating. The season of the episode
        // decides which MAL rating applies (AP68).
        var series: MediaItem?
        if item.kind == .episode || item.kind == .season, let seriesID = item.seriesID {
            series = try? await source.item(id: seriesID)
            guard series != nil else { return }
        }
        guard let value = await anime.rating(forItem: item, series: series) else { return }
        heroRatings[item.id] = ExternalRatings(mal: value)
    }

    /// Whether loading has succeeded at least once — see ``LibraryModel/load(force:)``.
    private var didLoad = false

    /// With which shelf settings the current state was built.
    ///
    /// **The finding of 2026-09-12, from on-device testing:** a channel was selected as a
    /// test and still did not appear on the Home screen. It was
    /// right, and it affected **not only** the new channel selection: ``load(force:)`` aborts
    /// at `didLoad`, and nobody called it with `force`. So **no** Home screen setting
    /// took effect until the next app start — order and visibility did not either,
    /// and those have existed since AP29.
    ///
    /// **Remembered instead of triggered.** A call from outside ("settings are closed, rebuild")
    /// would be an obligation for every future settings screen, and one would forget it.
    /// Here the screen asks on every appearance whether what it was built with still holds.
    private var builtWith: ShelfPreferences?

    /// For which profile the current state was built (check finding A-S1, 2026-09-27).
    ///
    /// **For the same reason as ``builtWith``:** "Continue Watching", the recently watched
    /// channels and the states of provider and portal belong to the profile. Two adults with
    /// the same (or empty) shelf order otherwise differed in nothing that was
    /// compared here, and the second saw the first one's Home screen.
    private var builtFor: String??

    /// Listens for the source having silently swapped out a list.
    ///
    /// **The second half of cache-first.** At start the source serves the
    /// snapshot of the last session and confirms it in the background with the
    /// server. Without this listening, the Home screen would stay on the old state —
    /// new content would be there, but nobody would see it. The reload here costs
    /// no network request: It reads from the memory the swap has just
    /// filled. And because `didLoad` is long since set by then, the old
    /// content stays until the new one replaces it — no spinner, no flicker.
    private var listObservation: Task<Void, Never>?

    private func observeListChanges() {
        guard listObservation == nil else { return }
        listObservation = Task { [weak self, source] in
            for await _ in await source.listChanges() {
                await self?.load(force: true)
            }
        }
    }

    deinit {
        listObservation?.cancel()
    }

    /// - Parameter force: Whether to fetch again despite existing data.
    ///
    ///   Without this distinction the Home screen reloaded on every pill switch,
    ///   complete with spinner and empty screen. A switch is no reason, though: Nothing
    ///   has changed.
    /// On returning to the app: "Continue Watching" fresh from the server and rebuild
    /// (2026-09-28) — playback started on the phone is then there immediately.
    public func fresh() async {
        await source.reloadContinueWatching()
        await load(force: true)
    }

    /// **One build at a time** (AP70, 2026-10-11). At start, `.task`, the switch
    /// to `.active` and the cloud triggered three builds simultaneously — in the server log
    /// every list appeared three times and every menu four times. Whoever arrives during a running build
    /// waits for its result; whoever insists on `force` then gets exactly one
    /// more. Only the first caller carries the cancellation chain: If its view disappears,
    /// the build ends — the waiters then get what is there.
    public func load(force: Bool = false) async {
        if let running = runningBuild {
            if force { followUpForced = true }
            await running.value
            return
        }
        let task = Task { await self.build(force: force) }
        runningBuild = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        runningBuild = nil
        if followUpForced {
            followUpForced = false
            await load(force: true)
        }
    }

    private var runningBuild: Task<Void, Never>?
    private var followUpForced = false
    /// Counts the builds — a later addition (portals) belongs only to the build that started it.
    private var buildNumber = 0

    private func build(force: Bool) async {
        observeListChanges()
        // **Changed shelf settings are a reason to rebuild** — see
        // ``builtWith``. The comparison costs one Keychain access per appearance
        // and saves the rebuild on every press in the settings.
        let preferences = ShelfPreferences.load(from: shelfStore, forItem: ProfilePointer.active)
        let preferencesChanged = builtWith != nil && builtWith != preferences
        let profileChanged = builtFor != nil && builtFor != .some(ProfilePointer.active)
        guard force || !didLoad || preferencesChanged || profileChanged else { return }
        buildNumber += 1
        let nr = buildNumber
        if !didLoad { showSnapshotOrSpinner() }
        builtWith = preferences
        builtFor = .some(ProfilePointer.active)

        do {
            // **Look in the cloud once beforehand** (AP43). "Continue Watching" is the
            // row where a state from another device is noticed first — and the
            // only one where a viewer notices that the sync is stuck. The throttle
            // sits in ``ProfileKit/SyncCadence`` and not here: This spot is passed through
            // several times a second while scrolling.
            SyncCall.call(.continueWatching)
            // Fetch in-progress items and libraries at the same time — one after the other
            // would be double the wait, and neither needs the other.
            async let resumable = source.resumable(limit: ContinueWatching.perSource)
            async let libraryList = source.libraries()

            // **Channels first** (C5): They apply for only six hours and are therefore almost
            // always newer than an in-progress movie — on the phone the history orders by
            // time and puts them at the front for the same reason.
            //
            // **A portal in its own section does not appear in "Continue Watching"** (decision
            // 27, C12) — the same rule as on the phone (``Core/PortalPreferences``).
            let portalPreferences = PortalPreferences.load(from: store)
            let channels = rule.scope.deliversChannels ? rule.filter(await recentChannels()) : []
            let title = try await resumable.filter(delivers(title:))
                .filter { portalPreferences.accepts(identifier: $0.id) }
            let started = ContinueWatching.mix(
                [channels, title], identifier: \.id, recent: \.lastWatched)
            // **Top Shelf shows exactly this row** (product decision, 2026-09-28: Continue Watching
            // must show exactly the same there as the app) — the same titles, the same
            // order, the channels too. Until then the extension built its own from Jellyfin
            // and a contribution from the app, and the two deviated from each other.
            adoptTopShelf(started)
            let found = try await libraryList.filter(delivers(library:))
            // **Remembered before filtering** — the pill asks for it, and for it
            // "are there movies" is something other than "do movies get a shelf".
            libraries = found
            let shelves = try await buildShelves(libraries: found, resumable: started)
            let preferences = ShelfPreferences.load(from: shelfStore, forItem: ProfilePointer.active)

            // **The portals come after the first frame** (AP70): They hung off the CL-Server
            // and that off its 20 s deadlines — until then the whole Home screen waited.
            // Now it stands as soon as Jellyfin has answered, and the portal shelves are
            // added when they arrive. If nothing is there by this point, the spinner stays
            // until the portals have answered too — only then is "empty" honest.
            if !shelves.isEmpty || started.first != nil {
                show(shelves: shelves, preferences: preferences, lookup: nil)
            }
            let portals = await portalShelves(libraries: found)
            guard !Task.isCancelled, nr == buildNumber else { return }
            guard !shelves.isEmpty || started.first != nil || !portals.isEmpty else {
                state = .empty
                didLoad = true
                return
            }
            if !portals.isEmpty || !didLoad {
                show(shelves: shelves + portals, preferences: preferences, lookup: nil)
            }
            if HeroLadder.needsTopUp(
                Self.heroCandidates(
                    shelves: shelves + portals, preferences: preferences,
                    device: HeroPreferences.load(from: store)))
            {
                let lookup = await lookedUpHeroes(shelves + portals)
                guard !Task.isCancelled, nr == buildNumber else { return }
                show(shelves: shelves + portals, preferences: preferences, lookup: lookup)
            }
        } catch let failure as JellyfinSource.SourceFailure {
            Diagnostics.defect(
                "Home not loaded: \(Diagnostics.explain(failure))", since: nil, area: "Oberfläche"
            )
            state = .failed(PlaybackPhase.forItem(failure))
        } catch is CancellationError {
            // **A cancellation gets no error message.** It does not mean that something
            // went wrong, but that nobody is waiting for the result any more: The
            // section was switched while still loading, or the TV
            // fell asleep. Showing that claims a server outage that
            // does not exist — and the claim stayed up until you signed out.
            //
            // The state stays as it was. When the view comes back, it reloads;
            // if the device sleeps, ``retriesWhenAwake(isFailed:reload:)`` takes over.
        } catch {
            Diagnostics.defect(
                "Home not loaded: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            // What arrives here is no `SourceFailure` — so not a case the
            // server named. What remains is the connection.
            state = .failed(.networkJellyfin)
        }
    }

    /// Sets the state from built shelves — and remembers it for the next cold start.
    private func show(shelves: [Shelf], preferences: ShelfPreferences, lookup: [MediaItem]?) {
        let arranged = Self.arrange(shelves, by: preferences)
        // **Built is not shown** (2026-09-13): The line "2 shelves with content"
        // was in the log, on screen there was one — and between the two lies only
        // this arrangement. What it hides is now recorded with its identifier.
        let route = shelves.map(\.id).filter { id in !arranged.contains { $0.id == id } }
        Diagnostics.network.info(
            """
            Home: \(shelves.count) shelves built, \(arranged.count) shown\
            \(route.isEmpty ? "" : ", hidden: " + route.joined(separator: ", "))
            """)
        // **The hero-area ladder, as on the phone** (decision 27, C4): If the
        // media server yields nothing, the box asks the provider catalog for titles with a
        // background image instead of staying empty.
        let loaded = Self.heroCandidates(
            shelves: shelves, preferences: preferences, device: HeroPreferences.load(from: store))
        let heroes = HeroLadder.tier(
            loaded: loaded, lookup: lookup ?? [], leadsWithChannelList: false
        ).heroes
        state = .ready(heroes: heroes, shelves: arranged)
        didLoad = true
        if let snapshotStore {
            HomeSnapshot(heroes: heroes, shelves: arranged, state: Date())
                .write(in: snapshotStore, forItem: ProfilePointer.active)
        }
    }

    /// **The cold start shows what was there last time** (AP70) — through the child filter
    /// of the profile and the portal preferences, because both may have changed since.
    /// Without an image it stays with the spinner.
    private func showSnapshotOrSpinner() {
        guard let snapshotStore,
            let image = HomeSnapshot.read(
                from: snapshotStore, forItem: ProfilePointer.active)
        else {
            state = .loading
            return
        }
        let portalPreferences = PortalPreferences.load(from: store)
        // **No portal title from the image** (AP77, 2026-10-11). Whether a portal on the CL-Server
        // is still switched on, the app only knows once it has answered — an image from the
        // previous day could show tiles of a portal that has since been switched off. Portal shelves
        // have come in only after the first `.ready` since AP70 anyway; they wait along here.
        func filtered(_ title: [MediaItem]) -> [MediaItem] {
            rule.filter(title).filter(delivers(title:)).filter {
                portalPreferences.accepts(identifier: $0.id)
            }
            .filter { PortalPreferences.portal(zu: $0.id) == nil }
        }
        let snapshotShelves = image.shelves.compactMap { shelf -> Shelf? in
            let title = filtered(shelf.items)
            guard !title.isEmpty else { return nil }
            return Shelf(
                id: shelf.id, titleKey: shelf.titleKey, items: title,
                usesWideCards: shelf.usesWideCards, libraryKind: shelf.libraryKind)
        }
        guard !snapshotShelves.isEmpty else {
            state = .loading
            return
        }
        Diagnostics.network.info(
            "Home: snapshot from \(image.state.formatted(date: .numeric, time: .shortened)) with \(snapshotShelves.count) shelves shown, rebuild running"
        )
        state = .ready(heroes: filtered(image.heroes), shelves: snapshotShelves)
    }

    /// Orders the rows by the user's setting and leaves out anything hidden.
    ///
    /// The server delivers its libraries in arbitrary order — without its own
    /// ordering, "Home videos and pictures" sometimes came before the series. The
    /// default is therefore fixed: Continue Watching, series, movies,
    /// home videos. Anyone who wants it differently changes it.
    static func arrange(_ shelves: [Shelf], by preferences: ShelfPreferences) -> [Shelf] {
        let byID = Dictionary(shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Without its own setting the default applies. It stands here and not
        // in the setting itself, because it depends on the kind of library and
        // is therefore only known here.
        let natural = defaultOrder(shelves)
        return preferences.arrange(natural).compactMap { byID[$0] }
    }

    /// The sequence in which rows appear on their own — **the board of both programs**
    /// (``Flows/ShelfSequence``, decision 27, C3).
    ///
    /// Until 2026-09-26 this place sorted all rows by the kind of their library
    /// (series, movies, other, home videos) and thereby put the libraries **before**
    /// collections, Live and portals — unlike shelf management, which reads from the
    /// ``ShelfPlan``. Now both order by the same board; the kind decides only
    /// within the catalogs.
    static func defaultOrder(_ shelves: [Shelf]) -> [String] {
        ShelfSequence.arrange(shelves, identifier: \.id, kind: \.libraryKind).map(\.id)
    }

    // MARK: - Selection for the hero area

    /// Which kinds of libraries the hero area may draw from.
    ///
    /// Allow list instead of block list: If a new kind were added tomorrow, a block list
    /// would silently put it large on the Home screen. This way
    /// it stays out at first — the more harmless error.
    ///
    /// **Since 2026-09-27 the board lives in ``Flows/HomeLayout/headerKinds``** — the
    /// phone asks the same one (check finding A-S3).
    static let heroEligible: Set<Core.Library.Kind> = HomeLayout.headerKinds

    /// Which titles the hero area pages through.
    ///
    /// The order is not arbitrary:
    ///
    /// 1. **No in-progress items at the front** (decision 25, 2026-09-26). Until then
    ///    the first item in progress stood in first place here — and at the same time as the first tile
    ///    in "Continue Watching" below. The phone has not done this since 2026-09-06;
    ///    both devices now ask "what is new" at the top.
    /// 2. **Round-robin through the libraries**, not library by library. Otherwise
    ///    a large series library would give a series eight times in a row and the movies
    ///    would never be seen.
    /// 3. **Shuffled**, so that the same sequence does not run on every opening.
    ///
    /// Admitted are **only movie and series libraries** — an allow list,
    /// not an exclusion list. The difference is essential:
    ///
    /// The kind of a library does not come from its name but from the
    /// fixed marker the server keeps for it. A folder "Home videos and
    /// pictures" reports `homevideos`, one named "Vidéos personnelles" does too —
    /// language and naming play no role. That is only reliable, though,
    /// for the known kinds. A mixed or pure folder library reports
    /// `folders` and can contain anything, private things included. What cannot be
    /// assigned safely therefore does not belong full-screen on the Home screen.
    ///
    /// A case remains that no automation solves: Anyone who sets up their family recordings as a
    /// movie library will see them up here. Only a per-library setting helps
    /// against that — noted in the roadmap.
    ///
    /// Also excluded: **titles without a background image.** The hero area
    /// is 90 % image; without one an empty area would remain, and while paging
    /// it would look like a loading error.
    ///
    /// The same series several times is merged: Two in-progress episodes
    /// of the same series are one title for the hero area, otherwise it pages
    /// between two almost identical images.
    ///
    /// **The selection itself lives in
    /// ``Flows/HomeLayout/heroes(libraries:shuffle:atMost:)``** since AP58 R6 —
    /// the same one on the phone. What remains here is what only the TV asks: which kinds
    /// (``heroEligible``) and which libraries the viewer allows at the top.
    ///
    /// **Which ones they allow lives per profile in the shelf order since 2026-09-27**
    /// (``Core/ShelfPreferences/heroShelves``, check finding A-S8) — the same choice as on the
    /// phone. The device-wide exclusion list is now only the fallback of a profile without
    /// a choice of its own.
    static func heroCandidates(
        shelves: [Shelf],
        preferences: ShelfPreferences = ShelfPreferences(),
        device: HeroPreferences = HeroPreferences(),
        limit: Int = HomeLayout.maxHeroes,
        shuffle: Bool = true
    ) -> [MediaItem] {
        let pools =
            shelves
            .filter { HomeLayout.fillsHeader($0.libraryKind) }
            .filter { preferences.fillsHeroes($0.id, device: device) }
            .map(\.items)
        return HomeLayout.heroes(libraries: pools, shuffle: shuffle, atMost: limit)
    }

    /// **Step 2 of the ladder:** Titles of the first category of the provider catalog, queried
    /// individually — ``Flows/HeroLadder/lookup(candidates:atMost:shuffle:fetch:)``,
    /// the same lookup as on the phone. Only if the media server yields nothing: It costs
    /// one request per title.
    private func lookedUpHeroes(_ shelves: [Shelf]) async -> [MediaItem] {
        guard
            let catalog = shelves.first(where: {
                Origin.forItem(library: $0.id) == .provider && !$0.items.isEmpty
            })
        else { return [] }
        let found = await HeroLadder.lookup(candidates: catalog.items.map(\.id)) {
            [source] identifier in try? await source.item(id: identifier)
        }
        Diagnostics.network.info("Hero area: \(found.count) titles from the provider")
        return found
    }

    /// Whether this library may get a shelf in this form factor.
    ///
    /// **Decided by the origin and not by the kind** — a movie section of the
    /// provider is `.movies` like that of the media server, but carries no ratings.
    ///
    /// **Asked before the build and not on the finished shelves** (AP45, 2026-09-25): This
    /// way no fetch arises for an origin that has dropped out, and the pill at the top
    /// (``libraries``) offers no section that would consist only of it.
    private func delivers(library: Core.Library) -> Bool {
        rule.scope.delivers(Origin.forItem(library: library.id))
    }

    /// The same question for a single title — needed for "Continue Watching", which
    /// spans all origins.
    private func delivers(title: MediaItem) -> Bool {
        rule.scope.delivers(Origin.forItem(identifier: title.id))
    }

    private func buildShelves(
        libraries: [Core.Library],
        resumable: [MediaItem]
    ) async throws -> [Shelf] {
        var shelves: [Shelf] = []

        if !resumable.isEmpty {
            shelves.append(
                Shelf(
                    id: ShelfPreferences.resumeID, titleKey: "home.continueWatching",
                    items: resumable, usesWideCards: surface.showsWideImages)
            )
        }

        // The server's collections as a row of their own — the place the
        // Jellyfin web interface has too. No section of its own in the sidebar
        // or pill: A handful of rows does not justify one; the row can be switched off through
        // shelf management like any other. Selecting opens the
        // collection detail page with the parts in release order.
        // Collections are titles themselves and carry a rating of their own.
        if let collections = try? await source.collections(),
            !collections.isEmpty
        {
            shelves.append(
                Shelf(
                    id: Self.collectionsID,
                    titleKey: "home.collections",
                    items: collections,
                    usesWideCards: false
                )
            )
        }

        // **What is on right now, directly behind the in-progress items** — perishable goods.
        // Where the shelf ends up is still decided by shelf management.
        if rule.scope.deliversChannels,
            let live = LiveShelf.shelf(from: rule.filter(await liveShelf()))
        {
            shelves.append(live)
        }

        // One row per library with the latest. Deliberately loaded side by side:
        // With four libraries this would otherwise be four times the wait.
        //
        // **Which one gets one is decided by ``ShelfRule``** and no longer by a filter
        // at this spot: Since the Home screen asks all origins, capping per
        // origin is the rule that carries the screen.
        let preferences = ShelfPreferences.load(from: shelfStore, forItem: ProfilePointer.active)
        let relevant = ShelfRule.forShelves(
            libraries, perProvider: preferences.shelvesPerProvider,
            categories: preferences.providerCategories)

        // **The titles per library are collected here and used twice** — for
        // the library shelf and for "Recently Added" (``RecentShelf``). A
        // separate fetch across all libraries would be another request for titles that
        // are in memory right afterwards.
        var contributions: [(Int, Core.Library.Kind, [MediaItem])] = []

        await withTaskGroup(of: (Int, Shelf?, Core.Library.Kind, [MediaItem]).self) { group in
            for (index, library) in relevant.enumerated() {
                // **A provider section is sorted like its section** (2026-09-13: a
                // provider series section was shown but not in the right
                // sort order). The same store ``LibraryModel`` reads from when opening
                // the section — per list for movies, per section for series
                // (``LibraryModel/sortScope(forLibraryID:)``); without an entry the
                // default of the section applies, and there it is "Title".
                //
                // **The media server stays with the latest.** Its shelves are called "one row
                // per library with the latest", and "Recently Added" is also fed from
                // that. Provider titles carry no `addedAt` and never arrive
                // there anyway — for them the section's order costs nothing.
                let order: (sortBy: Core.ItemFilter.SortBy, ascending: Bool)
                if Origin.forItem(library: library.id) == .provider {
                    let remembered = LibraryModel.loadOrder(
                        for: library, from: shelfStore, keychain: store)
                    order = (remembered.sorting.filter, remembered.ascending)
                } else {
                    order = (.dateAdded, false)
                }
                group.addTask { [source] in
                    // Without a kind given, the server returns everything in the
                    // library — in a series library that includes
                    // single episodes. Under "Series" there were therefore episodes
                    // of a single series instead of the series themselves.
                    let filter = Core.ItemFilter(
                        kinds: Self.kinds(for: library.kind),
                        sortBy: order.sortBy,
                        ascending: order.ascending,
                        limit: HomeLayout.titlesPerShelf
                    )
                    // **And a shelf that drops out says why** — the same line as
                    // for the portal folders (E81). A movie section selected but not shown on
                    // Home could not be told apart without it
                    // from: never asked, fetch failed, empty, filtered out.
                    let fetched: [MediaItem]
                    do {
                        fetched = try await source.items(in: library.id, filter: filter)
                    } catch {
                        Diagnostics.network.info(
                            "Shelf \(library.name) skipped: \(String(describing: error))")
                        return (index, nil, library.kind, [])
                    }
                    let items = fetched
                    guard !items.isEmpty else {
                        Diagnostics.network.info(
                            """
                            Shelf \(library.name) skipped: \(fetched.count) entries, \
                            \(items.count) after parental controls
                            """)
                        return (index, nil, library.kind, [])
                    }

                    return (
                        index,
                        Shelf(
                            id: library.id,
                            titleKey: library.name,
                            items: items,
                            usesWideCards: library.kind == .homeVideos,
                            libraryKind: library.kind
                        ),
                        library.kind,
                        items
                    )
                }
            }

            var collected: [(Int, Shelf)] = []
            for await (index, shelf, kind, title) in group {
                if let shelf { collected.append((index, shelf)) }
                if !title.isEmpty { contributions.append((index, kind, title)) }
            }
            // Keep the order of the libraries — concurrent loading
            // otherwise delivers them shuffled, and the Home screen would look different on every
            // call.
            shelves += collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // **Where "Recently Added" stands is decided by the board** (``defaultOrder(_:)``)
        // and after that by shelf management — here it is only built, from the titles the
        // library shelves have fetched anyway.
        if let recent = RecentShelf.shelf(
            from: contributions.sorted { $0.0 < $1.0 }.map { (kind: $0.1, title: $0.2) })
        {
            shelves.append(recent)
        }

        return shelves
    }

    /// One shelf per **chosen** portal folder.
    ///
    /// **The requirement of 2026-09-12:** exactly as on the phone. On the phone
    /// "Animehub · Beliebte Serien" stands next to "Serieshub · Meistgesehen gerade", at most
    /// three; on the TV there was only the one shelf across all portals.
    ///
    /// **The name comes from the choice and not from the level.** A portal level
    /// answers with entries, not with a heading — see
    /// ``Core/ShelfPreferences/PortalChoice``.
    ///
    /// **A level that does not answer drops out and does not take the others with it.**
    /// The same `try?` as with the collective shelf, and for the same reason: A portal via
    /// a bridge in the home network is the shakiest of the three routes.
    ///
    /// **But it does not drop out silently** (2026-09-13). The line "2 chosen, 1 shelf"
    /// was in the log, and which of the two was missing and why was recorded nowhere — four
    /// causes, one result. Now every dropout states its reason.
    private func portalFolderShelves(
        libraries: [Core.Library], choice: [ShelfPreferences.PortalChoice]
    ) async -> [HomeModel.Shelf] {
        // **All chosen folders at once** (AP70, 2026-10-11): One after the other meant on the
        // TV three portals × 20 s deadline = 60 s before the Home screen appeared (F-017).
        // The order of the choice stays — via the index, not via arrival.
        let chosen = Array(choice.prefix(ShelfPreferences.maximumPortalFolders))
        var found: [(Int, HomeModel.Shelf)] = []
        await withTaskGroup(of: (Int, HomeModel.Shelf?).self) { group in
            for (index, folder) in chosen.enumerated() {
                guard ShelfRule.portalReported(forItem: folder.identifier, under: libraries) else {
                    Diagnostics.network.info(
                        "Portal folder \(folder.name) skipped: portal not reported")
                    continue
                }
                let order = LibraryModel.loadOrder(
                    for: Core.Library(id: folder.identifier, name: folder.name, kind: .portalLevel),
                    from: shelfStore, keychain: store)
                let filter = Core.ItemFilter(
                    kinds: [], sortBy: order.sorting.filter, ascending: order.ascending,
                    limit: HomeLayout.titlesPerShelf)
                group.addTask { [source] in
                    let fetched: [MediaItem]
                    do {
                        fetched = try await source.items(in: folder.identifier, filter: filter)
                    } catch {
                        Diagnostics.network.info(
                            """
                            Portal folder \(folder.name) skipped: \
                            \(String(describing: error))
                            """)
                        return (index, nil)
                    }
                    guard !fetched.isEmpty else {
                        Diagnostics.network.info(
                            "Portal folder \(folder.name) skipped: 0 entries after parental controls")
                        return (index, nil)
                    }
                    return (
                        index,
                        Shelf(
                            id: folder.identifier, titleKey: folder.name, items: fetched,
                            usesWideCards: false, libraryKind: .portalLevel)
                    )
                }
            }
            for await (index, shelf) in group {
                if let shelf { found.append((index, shelf)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The titles of the first portal entry points, as **one** shelf.
    ///
    /// **A level that does not answer does not take the others with it** — `try?` per
    /// entry point. A portal via a bridge in the home network is the shakiest of the three
    /// routes; its being silent right now must not cost the Home screen anything.

    /// **The portal shelves — added after the first frame** (AP70). Until 2026-10-11 this
    /// block stood in the middle of ``buildShelves(libraries:resumable:)``, and the Home screen
    /// waited for every portal level before it showed anything.
    private func portalShelves(libraries: [Core.Library]) async -> [Shelf] {
        var builtShelves: [Shelf] = []
        // **The portal levels first, and together** (AP29, 2026-09-11): One shelf per
        // entry point would be two dozen rows from one origin with two portals — the
        // reasoning is at ``ShelfRule/portalShelf(from:)``.
        // **Either the collective shelf or the chosen ones — never both.** The same rule
        // as on the phone: ``FromPortals`` fills either the fixed shelf or the
        // chosen ones, and both side by side would be the same content twice.
        let folderChoice = ShelfPreferences.load(from: shelfStore, forItem: ProfilePointer.active)
            .portalFolders
        var folderShelves: [Shelf] = []
        if !folderChoice.isEmpty {
            folderShelves = await portalFolderShelves(libraries: libraries, choice: folderChoice)
            // **The same line as for the live shelf and for the same reason:** An empty
            // shelf has four causes — the choice is not in the store, the level is
            // not reported, it does not answer, or the parental controls filter everything
            // out. From outside all four look the same.
            let reported = libraries.filter { $0.kind == .portalLevel }.count
            Diagnostics.network.info(
                """
                Portal folder shelves: \(folderChoice.count) chosen, \(reported) levels reported, \(folderShelves.count) shelves with content
                """)
            builtShelves += folderShelves
        }
        // **If no choice yields anything, the collective shelf stands there** (check finding A-S9,
        // 2026-09-27) — as on the phone (``FromPortals``): A choice that does not
        // answer today does not take the shelf with it. Until then the TV had no
        // portal shelf at all in that case.
        if folderShelves.isEmpty, let portalShelfBuilt = await portalShelf(libraries: libraries) {
            builtShelves.append(portalShelfBuilt)
        }
        return builtShelves
    }

    private func portalShelf(libraries: [Core.Library]) async -> HomeModel.Shelf? {
        let layers =
            libraries
            .filter { Origin.forItem(library: $0.id) == .portals }
            .prefix(ShelfRule.portalEntryPoints)
        guard !layers.isEmpty else { return nil }

        var title: [MediaItem] = []
        for level in layers {
            let filter = Core.ItemFilter(
                kinds: Self.kinds(for: level.kind), sortBy: .natural, limit: 12)
            title += (try? await source.items(in: level.id, filter: filter)) ?? []
        }
        return ShelfRule.portalShelf(from: title)
    }

    /// The address of a preview image at the width at which it is shown.
    // The defaults are computed from the **display size** and not written
    // down as a number. Before, 480, 840, 1920 and 520 stood here — four numbers from which
    // it was impossible to tell what they referred to, and three of them were
    // off: Posters were fetched too large, background images too small and thus
    // scaled up on the TV. See ``ImageSizing``.

    public nonisolated func posterURL(
        for item: MediaItem,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width)
    ) -> URL? {
        PosterAddress.url(for: item, from: source, width: width)
    }

    public nonisolated func stillURL(
        for item: MediaItem,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.episode.width)
    ) -> URL? {
        Self.stillURL(for: item, from: source, width: width)
    }

    public nonisolated func tileImage(for item: MediaItem) -> TileImage? {
        Self.tileImage(for: item, from: source)
    }

    /// Also as a free computation, so that warming up (``StartupPrefetch``)
    /// forms **the same** address as the card. Two separate computations
    /// would drift apart, and a cache under a foreign key warms nothing.
    public nonisolated static func stillURL(
        for item: MediaItem,
        from source: any ContentSource,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.episode.width)
    ) -> URL? {
        tileImage(for: item, from: source, width: width)?.url
    }

    /// The image of a wide tile — and whether it is portrait.
    public nonisolated struct TileImage: Equatable, Sendable {
        public let url: URL
        /// A poster (2 : 3): The tile shows it **whole**, on a blurred background made from
        /// the same image, instead of cropping it to 16 : 9.
        public let up: Bool
    }

    /// **The chain that never crops an image** (product decision 2026-10-01): first the still frame
    /// of the spot where playback continues — "it looks better than anything else and
    /// recognition is high", for all services —, then the episode image, then the
    /// background image, last the poster, shown whole.
    ///
    /// **And otherwise `nil`** (AP29, 2026-09-11) — the same rule as in ``PosterAddress``:
    /// do not request an image that is already known to be missing. ``ItemMapping`` sets
    /// `posterID` only if the server holds an image.
    ///
    /// **An episode's own image is wide** as long as nothing else is known
    /// (Jellyfin keeps an episode's still frame as its primary image); for everything else only if
    /// ``Core/Artwork/isWide`` says so. An Xtream "movie" like "Laitkrutbai Gezougros 5.Bölüm" brings
    /// a poster — until 2026-10-01 it was cropped in the 16 : 9 frame.
    ///
    /// - Parameter standbild: Where the still frame lives — replaceable for tests.
    public nonisolated static func tileImage(
        for item: MediaItem,
        from source: any ContentSource,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.episode.width),
        stillFrame: (String) -> URL? = { StillFrameStore.address(forItem: $0) }
    ) -> TileImage? {
        let frames = item.artwork
        func wide(_ identifier: String?, _ tag: String?, _ kind: ImageKind = .primary) -> TileImage? {
            guard let identifier,
                let url = source.imageURL(itemID: identifier, kind: kind, width: width, tag: tag)
            else { return nil }
            return TileImage(url: url, up: false)
        }
        if let file = stillFrame(item.id) { return TileImage(url: file, up: false) }
        if let image = wide(frames.thumbID, frames.thumbTag) { return image }
        let ownIsWide =
            frames.isWide == true || (item.kind == .episode && frames.isWide != false)
        if ownIsWide, let image = wide(frames.posterID, frames.posterTag) { return image }
        if let image = wide(frames.backdropID, frames.backdropTag, .backdrop) { return image }
        for (identifier, tag) in [
            (frames.posterID, frames.posterTag),
            (frames.seriesPosterID, frames.seriesPosterTag),
        ] {
            guard let identifier,
                let url = source.imageURL(itemID: identifier, kind: .primary, width: width, tag: tag)
            else { continue }
            return TileImage(url: url, up: true)
        }
        return nil
    }

    public nonisolated func backdropURL(
        for item: MediaItem,
        width: Int = ImageSizing.backdropWidth(points: 1920)
    ) -> URL? {
        guard let id = item.artwork.backdropID else { return nil }
        return source.imageURL(
            itemID: id, kind: .backdrop, width: width, tag: item.artwork.backdropTag)
    }

    public nonisolated func logoURL(
        for item: MediaItem,
        width: Int = ImageSizing.requestWidth(points: TVMetrics.logo.width, headroom: 1)
    ) -> URL? {
        guard let id = item.artwork.logoID else { return nil }
        return source.imageURL(itemID: id, kind: .logo, width: width, tag: item.artwork.logoTag)
    }

    /// Which kind of titles a library shows in the overview.
    ///
    /// In a series library these are the **series**, not their episodes —
    /// episodes appear only on the detail page. Without this restriction
    /// the server mixes both.
    ///
    /// **Since AP58 R6 the board lives in `Core`** (``Core/Library/Kind/overviewKinds``).
    nonisolated static func kinds(for kind: Core.Library.Kind) -> [MediaItem.Kind] {
        kind.overviewKinds
    }

    /// The sentence for a failure — **for the views that do not yet draw a
    /// state.**
    ///
    /// Search, library and detail page still carry `String` states; connecting
    /// them is separate work and is not part of AP25. **The table behind it
    /// has been the same since 2026-09-11 regardless** (``PlaybackPhase/forItem(_:)``) — two tables
    /// over the same failure drift apart sooner or later, and then search interprets
    /// an expired sign-in differently from the Home screen.
    ///
    /// Each of the three states of this table carries a sentence; the fallback is the
    /// sentence from `ErrorSummary` and never occurs.
    nonisolated static func messageKey(for failure: JellyfinSource.SourceFailure) -> String {
        PlaybackPhase.forItem(failure).message ?? ErrorSummary.key(forItem: failure)
    }

    /// The image from which the accent color is derived.
    ///
    /// The **background image**, not the poster: Posters are often photographed
    /// covers whose packaging frame wins every analysis — one series became
    /// blue instead of orange that way. Only if none is available does the poster have to do.
    ///
    /// Requested tiny on purpose — the reasoning is at
    /// `AccentExtractor.sourceWidth`.
    /// **With `tag`, and that is no decoration:** Only the tag gets the server
    /// to send a `max-age` — without it `URLCache` revalidated this
    /// tiny image over the network on every focus change and thereby occupied one
    /// of the three image fetch slots.
    public nonisolated func accentSourceURL(for item: MediaItem) -> URL? {
        if let backdrop = item.artwork.backdropID {
            return source.imageURL(
                itemID: backdrop, kind: .backdrop, width: AccentExtractor.sourceWidth,
                tag: item.artwork.backdropTag)
        }
        return source.imageURL(
            itemID: item.artwork.posterID ?? item.id, kind: .primary,
            width: AccentExtractor.sourceWidth, tag: item.artwork.posterTag)
    }

    // MARK: - Long-press menu

    /// Toggle the watched mark — the same computation as in the library.
    ///
    /// First the display, then the server: The menu toggles **before** the
    /// answer is there — otherwise the card would look unchanged after the press, one
    /// would press again and take the mark right back. If the
    /// call fails, the server state brings the truth back.
    public func toggleWatched(for item: MediaItem) async {
        let wanted = !item.isWatched
        replace(LibraryModel.marking(item, watched: wanted))
        do {
            try await source.setPlayed(wanted, for: item.id)
        } catch {
            Diagnostics.defect(
                "Watched mark not set: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            replace(await (try? source.item(id: item.id)) ?? item)
        }
    }

    /// Toggle the favorite mark — ``Flows/MarkToggle``: first the display, then the
    /// service, back on error.
    public func toggleFavorite(for item: MediaItem) async {
        var updated = item
        updated.isFavorite = !item.isFavorite
        await MarkToggle.setEnabled(to: updated, previous: item, show: replace) {
            try await source.setFavorite(updated.isFavorite, for: item.id)
        }
    }

    /// Swaps a title in the hero area and rows without reloading.
    ///
    /// Deliberately no `load(force:)` — the reasoning is at
    /// ``LibraryModel``: A reload over the network while the menu is still open
    /// would make the feedback stand still exactly when one
    /// is looking at it.
    /// Removes a tile from "Continue Watching" — **first the display, then the source**, as
    /// with the other actions of this menu.
    ///
    /// **For every title, as on Apple's** (product requirement 2026-10-01). Until then only for
    /// channels (Live check, finding 7); a title got "Reset progress" through the
    /// unwatched mark, and with the CL-Server the position — and the title — stayed.
    /// A channel has no mark at a source; it is forgotten in the channel history.
    public func removeFromContinueWatching(_ item: MediaItem) async {
        let previous = state
        if case .ready(let heroes, let shelves) = state {
            state = .ready(
                heroes: heroes,
                shelves: shelves.compactMap { shelf in
                    guard shelf.id == ShelfPreferences.resumeID else { return shelf }
                    let rest = shelf.items.filter { $0.id != item.id }
                    guard !rest.isEmpty else { return nil }
                    return Shelf(
                        id: shelf.id, titleKey: shelf.titleKey, items: rest,
                        usesWideCards: shelf.usesWideCards, libraryKind: shelf.libraryKind)
                })
        }
        // **Top Shelf follows along** (AP70, product decision 2026-10-11): Until then the row
        // was taken over only at build, and the home screen kept showing the removed title
        // until the Home screen was next rebuilt completely.
        defer { adoptTopShelf(continueWatchingInState) }
        guard item.kind != .channel else { return await forgetChannel(item.id) }
        do {
            try await source.removeFromContinueWatching(item.id)
        } catch {
            Diagnostics.defect(
                "Not removed from Continue Watching: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            state = previous
        }
    }

    /// The titles of the "Continue Watching" row as currently shown.
    var continueWatchingInState: [MediaItem] {
        guard case .ready(_, let shelves) = state else { return [] }
        return shelves.first { $0.id == ShelfPreferences.resumeID }?.items ?? []
    }

    /// **Top Shelf shows exactly this row** (product decision, 2026-09-28: Continue Watching
    /// must show exactly the same there as the app) — the same titles, the same
    /// order, the channels too. Called at build and after every removal.
    private func adoptTopShelf(_ started: [MediaItem]) {
        HomeShelf.adopt(
            continueWatching: started.prefix(TopShelfEntry.shelfSize).map { title in
                TopShelfEntry(
                    id: title.id,
                    title: title.kind == .episode ? (title.parentTitle ?? title.title) : title.title,
                    image: stillURL(for: title, width: 1200),
                    recent: title.lastWatched)
            })
    }

    /// Which actions the long-press menu of a card offers (Live check, finding 7).
    ///
    /// **A channel gets only what suits it:** in "Continue Watching" removal,
    /// in the live shelf nothing. "Mark as watched" and "Favorite" go to the media server,
    /// which does not know channel identifiers.
    ///
    /// **"Details" stands at the top, where the press plays** (2026-10-01) — see
    /// ``playsOnPress(_:inShelf:)``: The detail page is then reachable only through the
    /// menu.
    enum CardAction: Equatable {
        case details, seen, favorite, fromContinueWatching
    }

    static func cardActions(forItem item: MediaItem, inShelf shelf: String) -> [CardAction] {
        let continueWatching = shelf == ShelfPreferences.resumeID
        if item.kind == .channel { return continueWatching ? [.fromContinueWatching] : [] }
        var actions: [CardAction] = playsOnPress(item, inShelf: shelf) ? [.details] : []
        actions += [.seen, .favorite]
        if continueWatching { actions.append(.fromContinueWatching) }
        return actions
    }

    /// Whether pressing a card **plays right away**, instead of opening the detail page.
    ///
    /// **Continue Watching means continue watching** (user requirement 2026-10-01: in Continue Watching
    /// content should open directly without a detail view). Whoever presses there has
    /// already chosen the title; the detail page was an intermediate stop with a single useful
    /// button. Only movie and episode: A series must first find its episode, which the
    /// detail page does — and a channel plays on press anyway.
    static func playsOnPress(_ item: MediaItem, inShelf shelf: String) -> Bool {
        shelf == ShelfPreferences.resumeID && (item.kind == .movie || item.kind == .episode)
    }

    private func replace(_ item: MediaItem) {
        guard case .ready(let heroes, let shelves) = state else { return }
        state = .ready(
            heroes: heroes.map { $0.id == item.id ? item : $0 },
            shelves: shelves.map { shelf in
                Shelf(
                    id: shelf.id,
                    titleKey: shelf.titleKey,
                    items: shelf.items.map { $0.id == item.id ? item : $0 },
                    usesWideCards: shelf.usesWideCards,
                    libraryKind: shelf.libraryKind
                )
            }
        )
    }

}
