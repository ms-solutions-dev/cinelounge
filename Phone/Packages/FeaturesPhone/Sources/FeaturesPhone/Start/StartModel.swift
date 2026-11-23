import Core
import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import Observation
import ParentalControls

/// What Home shows and what state it is in.
@MainActor
@Observable
public final class StartModel {

    /// How many tiles a shelf fetches at most.
    ///
    /// Twenty: nobody pages through more, and every further one is an image that is loaded and
    /// kept in memory without ever being seen.
    public static let perShelf = HomeLayout.titlesPerShelf

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        /// The server responds but has nothing.
        case empty
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading

    /// What the service holds in the way of catalogs. Before the first load, what the accounts
    /// suggest; afterwards, what is really there.
    public private(set) var catalogs: CatalogState

    /// Which step of the ladder currently carries the header area.
    ///
    /// **Remembered and not recalculated on every redraw**, because the third step costs a
    /// network request: a computed property that depends on it would query sixty times per
    /// second.
    public private(set) var tier: HeroLadder.Tier<HeroContent> = .setUp

    public private(set) var tiles: [Shelf.Identifier: [TileContent]] = [:]

    /// Which shelves are not empty but disturbed — see ``ShelfDisruption``.
    public private(set) var disruptions: [Shelf.Identifier: ShelfDisruption] = [:]

    /// What the user has determined about their Home — order, hidden items, which shelves fill
    /// the hero.
    ///
    /// **Re-read on every load**, so that a change in `Presentation → Startseite` takes effect
    /// on returning and not only at the next program start. The same agreement as with
    /// ``LiveModel`` and the channel preferences.
    public private(set) var preferences = StartPreferences.preset

    private let source: (any StartSource)?
    private let ratings: (any RatingSource)?

    /// - Parameter vorliebenLaden: Where the Home settings come from. **A handle and not a
    ///   value**, so that ``load()`` reads them fresh each time: anyone who flips something in
    ///   `Presentation → Startseite` and goes back should see it. The default gives the factory
    ///   setting — for tests that have no Keychain.
    ///
    /// - Parameter synchronisierung: The running sync. **Can be injected from outside for the
    ///   tests**, otherwise the one shared — see ``Synchronization``.
    ///
    /// - Parameter regel: The parental controls by which the local history is filtered
    ///   (``ParentalControls/ProtectionRule/shows(history:)``). The server tiles are filtered
    ///   by the start source itself.
    public init(
        source: (any StartSource)?,
        ratings: (any RatingSource)? = nil,
        catalogs: CatalogState = .fromAccesses(jellyfin: true),
        loadPreferences: (@Sendable () -> StartPreferences)? = nil,
        portalPreferences: (@Sendable () -> PortalPreferences)? = nil,
        synchronization: Synchronization = .shared,
        rule: ProtectionRule = .pending
    ) {
        self.rule = rule
        self.source = source
        self.ratings = ratings
        self.catalogs = catalogs
        self.loadPreferences = loadPreferences ?? { .preset }
        self.portalPreferences = portalPreferences ?? { .preset }
        self.synchronization = synchronization
    }

    private let synchronization: Synchronization

    /// See `init` — the filter for the local history.
    private let rule: ProtectionRule

    private let loadPreferences: @Sendable () -> StartPreferences

    /// Which portals count in the shared shelves.
    ///
    /// **A handle and not a value**, for the same reason as ``loadPreferences``: anyone who
    /// flips the switch in the portal settings and comes back should see it.
    private let portalPreferences: @Sendable () -> PortalPreferences

    /// The shelves that exist for this catalog situation and for which something is there.
    ///
    /// A shelf without content does not appear: a heading over nothing is not information but
    /// a construction site.
    public var visibleShelves: [Shelf] {
        // **A disturbed shelf counts as filled.** It carries no tiles and yet information — see
        // ``ShelfDisruption``. Without this line it would fall victim to the rule "an empty shelf
        // does not appear", and the information with it.
        let filled = preferences.arrange(ShelfPlan.shelves(forItem: catalogs))
            .filter { !(tiles[$0.id] ?? []).isEmpty || disruptions[$0.id] != nil }
        // **Filter first, then cap.** The other way round, an empty library wastes one of the four
        // places — and which one is empty is only known after loading.
        //
        // **And the cap is per origin, not across all** (finding of 2026-09-05, on the screen): the
        // media server filled the four places alone, and of the provider catalog **nothing** was
        // to be seen on Home — although it was set up and its shelves had content. A service of
        // which you see nothing is as good as not set up.
        //
        // The limit protects against "twenty libraries", not against "two services": it is a
        // question of loading — a shelf carries twenty tiles, and ten shelves are two hundred
        // images through a tunnel with a measured 0.31 Mbit/s. Four per service stays in the same
        // order of magnitude; four **in total** would make the second service disappear.
        var shown: [Shelf] = []
        var perOrigin: [Catalog.Origin: Int] = [:]
        for shelf in filled {
            if shelf.target != nil, let origin = shelf.sources.first {
                let previous = perOrigin[origin, default: 0]
                guard previous < ShelvesPerCatalog.atMost else { continue }
                perOrigin[origin] = previous + 1
            }
            shown.append(shelf)
        }
        return shown
    }

    /// Whether there are more catalogs than shelves show — then a row at the bottom leads into
    /// the register.
    ///
    /// **Without it, the cap at four would be a silent omission.** Anyone who has six libraries
    /// and sees four shelves should not have to search for the rest.
    public var hasMultipleCatalogs: Bool {
        catalogs.catalogs.count > ShelvesPerCatalog.atMost
    }

    /// Who appears large at the top — up to eight, by the rules from ``HeroSelection``.
    public private(set) var heroes: [HeroContent] = []

    /// Welcher davon gerade steht.
    public var held = 0

    /// How long a hero stays up.
    ///
    /// Twelve seconds, as on the TV: short enough that you see a second one while paging
    /// through the shelves, and long enough that nobody is surprised by a change in the middle
    /// of reading the title.
    public static let heroRotation = HomeLayout.heroRotation

    public var headerTitle: HeroContent? {
        guard !heroes.isEmpty else { return nil }
        return heroes[min(held, heroes.count - 1)]
    }

    /// Moves one forward. From the last to the first.
    public func nextHero() {
        guard heroes.count > 1 else { return }
        held = (held + 1) % heroes.count
    }

    /// Sets the tiles without a source — **only for tests.**
    ///
    /// The cap at four filled shelves cannot otherwise be tested: it depends on which shelves
    /// have content after loading, and there is no loading in the test.
    func setTilesForCheck(_ fresh: [Shelf.Identifier: [TileContent]]) {
        tiles = fresh
    }

    /// Whether everything is currently being fetched anew.
    ///
    /// **Read and not kept itself.** The sync outlives this model — it rebuilds Home along the
    /// way; the reasoning is at ``Synchronization``.
    public var isSynced: Bool { synchronization.isRunning }

    /// Pull down — **and that means the whole sync, not just this view.**
    ///
    /// **Decided on 2026-09-08 by the product owner**, and it makes a button superfluous: the
    /// requirement was that pulling down should additionally do exactly what the sync does, so
    /// that everything is covered. It is, yes — and with that the space in the header row is
    /// free for the downloads.
    ///
    /// **What spoke against it here until then** is stated in ``PlayerView`` in spirit and in
    /// ``StartView`` verbatim: *"a gesture that you trigger by accident while scrolling must
    /// not do the most expensive thing the app can do."* The sentence was right for an
    /// arbitrary gesture and is not for **this** one: pull to refresh only takes effect at the
    /// top end of the list and only beyond a distance that nobody covers incidentally. And the
    /// one danger behind it — a second startup on an account with exactly one permitted
    /// connection — is caught anyway: ``Synchronization/start()`` does not run twice.
    ///
    /// **Three steps in this order, and none of them is dispensable:** kick off, wait for the
    /// clearing, then reload. Anyone who left out the middle one would load the old sources
    /// again — the sync would become the refresh that it is supposed to replace.
    @MainActor
    public func refresh() async {
        synchronization.start()
        await synchronization.wait()
        await load()
    }

    public func load() async {
        // **The state at the beginning and not at the end.** It says which sync this load is the
        // answer to; the reasoning is at ``Synchronization/homeIsReady(after:)``.
        let stateAtLoad = synchronization.state
        defer { synchronization.homeIsReady(after: stateAtLoad) }

        guard let source else {
            state = .disrupted(.notSetUpYet)
            return
        }
        state = tiles.isEmpty ? .isLoading : state

        do {
            let content = try await source.home(perShelf: Self.perShelf)
            catalogs = content.state

            // **The history fills the shelf, no longer the box** (direction B to K4, decided on
            // 2026-09-06). It remains the only point at which a channel, a portal title and a movie stand
            // side by side as equals — but that is "Continue Watching" and not the header area; see
            // ``HeroLadder``.
            preferences = loadPreferences()
            // **Ready and counting — two conditions, one set** (2026-09-07). A switched-off portal drops
            // out because its tile led to an error message; a portal in the own area drops out because
            // the viewer said so. Both end in the same question, and ``History`` should not have it
            // asked twice. See ``PortalPreferences``.
            let allowed = content.portals.map { ready in
                ready.filter(portalPreferences().countsTogether)
            }
            let fullHistory = await HistoryStore.shared.load()
            let isValid = fullHistory.validOnes(at: catalogs, portals: allowed)
                .filter(rule.shows(history:))
            // **A vanished Continue Watching entry has four possible reasons, and from outside they
            // all look the same** (finding of 2026-09-12, from the product owner: something had been
            // started and the content was no longer visible, although the source is visible). The
            // entry can be missing because the origin is not carried, because its portal is in the own
            // area, because it was not reported at all — or because it was never written. Without this
            // line, every search for it begins with guessing.
            //
            // **Only if something really drops out.** A line on every redraw would make the log
            // unreadable, and unreadable is as good as none.
            if isValid.count < fullHistory.entries.count {
                let route = fullHistory.entries.filter { entry in
                    !isValid.contains { $0.identifier == entry.identifier }
                }
                // **Reported AND admitted, not just the result.** The first version of this line named
                // only the admitted portals — and then it said "animehub,serieshub" while the service
                // reported ten. Whether eight portals were switched off or not reported at all cannot be
                // told from the result, and they are two entirely different errors. Both sets belong
                // there.
                Diagnose.step(
                    .surface,
                    "Continue Watching: \(isValid.count) of \(fullHistory.entries.count); "
                        + "reported \(content.portals.map { $0.sorted().joined(separator: ",") } ?? "— (no report)"); "
                        + "own section \(portalPreferences().ownSection.sorted().joined(separator: ",")); "
                        + "allowed \(allowed.map { $0.sorted().joined(separator: ",") } ?? "all"); "
                        + "dropped \(route.map { $0.identifier.prefix(40) })")
            }
            heroes = content.heroes
            tiles = Self.ordered(content.tiles)
            disruptions = content.disruptions

            // **The expensive step only when the cheap one yields nothing.** The provider catalog
            // carries background image and plot only in one request per title — eight of them for a
            // box that nobody sees are eight too many.
            if HeroLadder.needsTopUp(heroes) {
                heroes = (try? await source.heroes(atMost: HeroSelection.atMost)) ?? []
            }
            tier = HeroLadder.tier(
                loaded: content.heroes, lookup: heroes, state: catalogs)

            // **Where a tile comes from is remembered and not guessed.** Two sources: the history,
            // which carries its origin per entry, and every shelf that has only **one** source —
            // "Live today" is exactly such a one.
            var origin: [String: Catalog.Origin] = [:]
            for shelf in ShelfPlan.shelves(forItem: catalogs) where shelf.sources.count == 1 {
                guard let only = shelf.sources.first else { continue }
                for tile in tiles[shelf.id] ?? [] { origin[tile.id] = only }
            }
            for entry in isValid { origin[entry.tile.id] = entry.origin }
            originPerTile = origin

            state = visibleShelves.isEmpty ? .empty : .settled

            // **What Home really shows belongs in the log.** Which shelves arise for which catalog
            // situation has depended on the server's catalogs since AP11 and no longer on an
            // enumeration — and a missing shelf otherwise goes unnoticed by anyone, because there is
            // simply nothing in its place.
            Diagnose.step(
                .network,
                "Home: \(catalogs.catalogs.count) catalogs, "
                    + visibleShelves.map { $0.label.raw }.joined(separator: " · "))
            preloadHeaderImages()
            await fetch(ratings: content.heroes)
        } catch {
            Diagnose.error(.network, "Home not loaded", error)
            state = .disrupted(.networkJellyfin)
        }
    }

    /// **"Continue Watching" takes every source** — the history comes first.
    ///
    /// What ran last may have run on TV and may have run from a portal; this one shelf is the
    /// place where that comes together. The media server delivers its started items anyway
    /// (`resumable`), and what is **and** in the history is the same title — which is why it is
    /// merged and not appended.
    ///
    /// Where a tile comes from — **for the tiles for which it cannot be guessed.**
    ///
    /// **The case this exists for:** a channel from "Live today" or from the history has no
    /// detail page; a press on it must **play** it. Its identifier carries no attribute by which
    /// that could be recognised, and is not meant to get one — the reasoning is at
    /// ``PlaybackJob/origin(zu:)``. So the origin travels along, and this board is the place
    /// where Home keeps it.
    ///
    /// Empty for everything that can be told from the identifier: a portal title and a provider
    /// title are recognised there, a media server title is the normal case.
    public private(set) var originPerTile: [String: Catalog.Origin] = [:]

    public func origin(zu identifier: String) -> Catalog.Origin? { originPerTile[identifier] }

    /// "Continue Watching" **from the sources alone**, ordered by "last watched".
    ///
    /// **The finding (2026-09-29, three devices, three orders):** until then the phone mixed its
    /// own history (``HistoryStore``, never synced) into the row and moved points in time
    /// forward in the process — what had been watched on the phone was further forward only
    /// there, finished titles stayed in place. The TV has no such history. Everything that
    /// belongs in the row now travels with the profile: Jellyfin's state, the IPTV state, the
    /// CL-Server state and the channel history. So the same row from the same sources,
    /// de-duplicated and ordered as on the TV
    /// (``Core/ContinueWatching/mix(_:identifier:ersetze:recent:)``).
    nonisolated static func ordered(
        _ tiles: [Shelf.Identifier: [TileContent]]
    ) -> [Shelf.Identifier: [TileContent]] {
        var result = tiles
        guard let row = tiles[.fixed(ShelfIdentifier.continueWatching)] else { return result }
        result[.fixed(ShelfIdentifier.continueWatching)] = ContinueWatching.mix(
            [row], identifier: \.id, recent: \.recent)
        return result
    }

    /// Prepares the images of all heroes before anyone swipes there.
    ///
    /// **The finding of 2026-09-05** (the images were not rendering cleanly and smoothly, mostly
    /// with a delay, and taking really long). Without this nudge a background image only starts
    /// loading when its page is due — and through a tunnel with a measured 0.31 Mbit/s that
    /// takes about four seconds. During that time the screen showed the title logo over a black
    /// area: both start at the same time, but the logo is a tenth as large.
    ///
    /// **The pixels must match those of the view.** The cache keeps address **and** size in the
    /// key; a different number here would mean fetching every image twice and finding none
    /// again. That is why ``HeaderImage/imageHeight`` and ``Wordmark`` stand here as the measure
    /// and not a round number.
    private func preloadHeaderImages() {
        let boxPixels = ImageSizes.pixels(
            forItem: HeaderImage.imageHeight, reference: ImageSizes.reference)
        let wordmarkPixels = ImageSizes.pixels(
            forItem: Wordmark.heightInHeader, reference: ImageSizes.reference)
        let frames = heroes.compactMap { $0.tile.backdrop ?? $0.tile.image }
        let wordmarks = heroes.compactMap(\.logo)
        Task {
            await ImageLoader.shared.preload(frames, pixels: boxPixels)
            await ImageLoader.shared.preload(wordmarks, pixels: wordmarkPixels)
        }
    }

    /// Fetches the more precise ratings for the heroes afterwards.
    ///
    /// **Delivered later and not waited for.** Home stands with what the media server
    /// supplies; IMDb and AniList are third-party services with third-party response times.
    /// Anyone who waits for them has, with the network switched off, a header area that does
    /// not appear at all — for a number that nobody would have missed.
    ///
    /// **All eight at once.** One after another it would be eight round trips; the numbers
    /// would then appear spread over half a minute, one by one, in the box — and that is
    /// exactly what the eye falls on.
    private func fetch(ratings source: [HeroContent]) async {
        guard let service = ratings else { return }
        let asked = source.filter { !$0.identifier.isEmpty }
        guard !asked.isEmpty else { return }

        let found = await withTaskGroup(of: (String, [Rating]).self) { group in
            for kandidat in asked {
                group.addTask { (kandidat.id, await service.ratings(zu: kandidat.identifier)) }
            }
            var board: [String: [Rating]] = [:]
            for await (identifier, ratings) in group {
                if !ratings.isEmpty { board[identifier] = ratings }
            }
            return board
        }

        guard !found.isEmpty else { return }
        heroes = heroes.map { $0.using(ratings: found[$0.id] ?? []) }
    }
}
