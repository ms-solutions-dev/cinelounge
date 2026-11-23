import Core
import Foundation
import ParentalControls
import PlaylistKit
import PortalKit
import ProfileKit
import Testing

@testable import Features

/// **The child interface** — AP45, product decision 7 of 2026-09-25.
///
/// Every check here goes **through the connection**: The form comes from a real
/// ``ParentalControlsState`` over a real ``ProfileKit/ProfileBook``, and what is shown comes from
/// the model that feeds the view — ``HomeModel`` for the shelves,
/// ``AppSidebar/mainDestinations(scope:hasPortals:)`` for the sidebar, ``ShellModels`` for the
/// path in between. A calculation next to it, such as `Surface.kind.isAllowed(.settings)`,
/// would stay green even if nobody asked it.
@MainActor
@Suite("The child interface")
struct ChildInterfaceTests {

    // MARK: - Setup

    /// A state over a book with exactly one profile of this kind.
    ///
    /// - Parameter pin: Whether a PIN is set. **Without a PIN the lock does not apply** — the
    ///   child's interface applies all the same, and exactly that is what half of the cases here
    ///   check.
    private func state(
        kind: Profile.Kind, pin: Bool = false, limit: AgeLimit? = nil
    ) -> ParentalControlsState {
        let store = InMemoryStore()
        if pin { _ = Pin(store: store).set("1234") }
        let profileStore = InMemoryStore()
        var person = Profile(name: kind == .kind ? "Selin" : "Max")
        person.kind = kind
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        if let limit { state.set(limit: limit, forItem: person.identifier.rawValue) }
        return state
    }

    /// A source with one library per origin and titles of both ratings.
    final class ChildSource: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Kinder-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }

        private let lock = NSLock()
        private var _asked: [String] = []
        /// Which libraries were asked for titles.
        var asked: [String] { lock.withLock { _asked } }

        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }
        func libraries() async throws -> [Core.Library] {
            [
                Core.Library(id: "jf-filme", name: "Filme", kind: .movies),
                Core.Library(id: "liste|vod|7", name: "DE Kino", kind: .movies),
                Core.Library(id: "animehub||/beliebt", name: "Beliebte Serien", kind: .portalLevel),
            ]
        }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            lock.withLock { _asked.append(library) }
            if library == "jf-filme" {
                return [
                    MediaItem(id: "drache", kind: .movie, title: "Der kleine Funkelfuchs", ageRating: "0"),
                    MediaItem(id: "abend", kind: .movie, title: "Ein später Abend", ageRating: "16"),
                ]
            }
            if library.hasPrefix("animehub") {
                return [MediaItem(id: "animehub|s1|/serie/1", kind: .series, title: "Eine Serie")]
            }
            return [MediaItem(id: library + "-1", kind: .movie, title: "Ein Film")]
        }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] {
            [
                MediaItem(id: "drache", kind: .movie, title: "Der kleine Funkelfuchs", ageRating: "0"),
                MediaItem(id: "animehub|s1|/serie/2", kind: .series, title: "Angefangen im Portal"),
            ]
        }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        enum Missing: Error { case nothing }
    }

    /// A channel as the Live shelf delivers it.
    private nonisolated static let channels = MediaItem(id: "sender-1", kind: .channel, title: "Kinderhafen")

    /// The Home screen, **built with rule and form from the same state** — the way
    /// ``MainView`` hands it to ``ShellModels``.
    private func home(
        _ state: ParentalControlsState, source: ChildSource
    ) async -> [HomeModel.Shelf] {
        let model = HomeModel(
            source: source, rule: state.rule, surface: state.surface,
            store: InMemoryStore(), shelfStore: InMemoryStore(),
            liveShelf: { [Self.channels] })
        await model.load()
        guard case .ready(_, let shelves) = model.state else {
            Issue.record("Home not ready: \(model.state)")
            return []
        }
        return shelves
    }

    // MARK: - The form factor comes from the profile

    @Test("A child profile gets the child interface — even without a PIN")
    func childGetsThem() {
        #expect(state(kind: .kind).surface == .kind)
        #expect(state(kind: .kind, pin: true).surface == .kind)
    }

    @Test("An adult profile keeps the familiar one")
    func adultKeepsThem() {
        #expect(state(kind: .adult).surface == .familiar)
        #expect(state(kind: .adult, pin: true).surface == .familiar)
    }

    // MARK: - The bar

    @Test("A child sees no way into the settings — only \"Switch Profile\"")
    func noSettingsPath() {
        let state = state(kind: .kind)
        let targets = AppSidebar.mainDestinations(scope: state.rule.scope, hasPortals: true)
        #expect(targets == [.accounts, .search, .media, .favorites])
        #expect(!targets.contains(.settings))
        #expect(!targets.contains(.sync))
    }

    @Test("An adult sees the bar as before")
    func adultSeesEverything() {
        let state = state(kind: .adult)
        let targets = AppSidebar.mainDestinations(scope: state.rule.scope, hasPortals: true)
        #expect(
            targets == [
                // In the drawn order since 2026-09-30; "Alle Dienste aktualisieren" back in since 2026-10-01.
                // (AP63).
                .accounts, .search, .media, .live, .sport, .vod, .portals, .favorites, .sync,
                .settings,
            ])
    }

    // MARK: - The shelves

    @Test("A child sees only the shelves of the Jellyfin server — no Live, no portal, no provider")
    func childSeesOnlyApprovedShelves() async {
        let source = ChildSource()
        let shelves = await home(state(kind: .kind), source: source)
        let identifiers = shelves.map(\.id)

        #expect(identifiers.contains("jf-filme"))
        #expect(!identifiers.contains(LiveShelf.identifier))
        #expect(!identifiers.contains("liste|vod|7"))
        #expect(!identifiers.contains(ShelfRule.portalShelfID))
        #expect(!source.asked.contains("liste|vod|7"), "not even asked")

        let next = shelves.first { $0.id == ShelfPreferences.resumeID }
        #expect(next?.items.map(\.id) == ["drache"], "the in-progress item from the portal drops out")
        #expect(next?.usesWideCards == false, "posters instead of still frames")
    }

    @Test("With PIN and limit the title above the limit drops out too")
    func limitAppliesInShelf() async {
        let shelves = await home(
            state(kind: .kind, pin: true, limit: .from6), source: ChildSource())
        let movies = shelves.first { $0.id == "jf-filme" }
        #expect(movies?.items.map(\.id) == ["drache"])
    }

    @Test("An adult sees all shelves as before")
    func adultSeesAllShelves() async {
        let shelves = await home(state(kind: .adult), source: ChildSource())
        let identifiers = shelves.map(\.id)

        #expect(identifiers.contains("jf-filme"))
        #expect(identifiers.contains(LiveShelf.identifier))
        #expect(identifiers.contains("liste|vod|7"))
        #expect(identifiers.contains(ShelfRule.portalShelfID))
        let next = shelves.first { $0.id == ShelfPreferences.resumeID }
        #expect(next?.items.count == 2)
        #expect(next?.usesWideCards == true)
        #expect(shelves.first { $0.id == "jf-filme" }?.items.count == 2)
    }

    // MARK: - The wrapper passes the form factor on

    /// **The counter-check is aimed at the caller:** ``ShellModels`` remembers its Home screen.
    /// If it did not take the form into its state, a child would get the adult's remembered Home
    /// screen after the switch.
    @Test("The wrapper rebuilds Home when the form factor changes")
    func wrapperPassesOn() {
        let models = ShellModels()
        let adult = state(kind: .adult)
        let kind = state(kind: .kind)

        let previous = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: adult.rule, surface: adult.surface)
        let after = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: kind.rule, surface: kind.surface)

        #expect(previous.surface == .familiar)
        #expect(after.surface == .kind)
        #expect(previous !== after)
    }

    /// **Even when the lock applies on both sides** — an adult on the locked device and a child
    /// have the same scope but not the same form. Without this case the check above would stay
    /// green as long as only the scope is in the shell's state.
    @Test("The wrapper distinguishes the form factor even with the same scope")
    func wrapperDistinguishesFormFactor() {
        let models = ShellModels()
        let locked = ProtectionRule(deviceLocked: true, isPinSet: true)
        let kind = state(kind: .kind, pin: true)
        #expect(locked.scope.isInChildMode == kind.rule.scope.isInChildMode)

        let previous = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: locked, surface: .familiar)
        let after = models.home(
            source: nil, provider: nil, portals: nil, channels: nil, anime: nil,
            rule: kind.rule, surface: kind.surface)

        #expect(after.surface == .kind)
        #expect(previous !== after)
    }

    // MARK: - The way out

    @Test("\"Switch Profile\" never leads a child into the settings")
    func wayOut() {
        let withoutPin = state(kind: .kind)
        let withPin = state(kind: .kind, pin: true)
        #expect(
            AccountSwitcher.route(
                parentalControlsApply: withoutPin.rule.applies, surface: withoutPin.surface)
                == .sheet)
        #expect(
            AccountSwitcher.route(
                parentalControlsApply: withPin.rule.applies, surface: withPin.surface)
                == .sheetBehindDoor)
        let adult = state(kind: .adult, pin: true)
        #expect(
            AccountSwitcher.route(
                parentalControlsApply: adult.rule.applies, surface: adult.surface)
                == .sheet)
    }

    // MARK: - The search

    /// **Through the model itself** — with real sources for provider and portals, which it must
    /// keep or drop.
    @Test("A child's search does not keep providers and portals")
    func searchDropsSources() {
        let listen = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let provider = ProviderSource(XtreamVODSource(store: listen), ledger: InMemoryStore())
        let portals = PortalSource(bridge: PortalBridge(basis: URL(string: "http://x.invalid")!))

        let kind = state(kind: .kind)
        let childSearch = SearchModel(
            source: nil, vod: provider, portals: portals, rule: kind.rule,
            surface: kind.surface)
        #expect(!childSearch.queriesProviders)
        #expect(!childSearch.queriesPortals)

        let adult = state(kind: .adult)
        let search = SearchModel(
            source: nil, vod: provider, portals: portals, rule: adult.rule,
            surface: adult.surface)
        #expect(search.queriesProviders)
        #expect(search.queriesPortals)
    }

    @Test("A child's search asks only the Jellyfin server")
    func searchJellyfinOnly() {
        let kind = state(kind: .kind)
        let adult = state(kind: .adult)
        #expect(SearchModel.catalogs(surface: kind.surface, rule: kind.rule) == [.jellyfin])
        #expect(
            SearchModel.catalogs(surface: adult.surface, rule: adult.rule)
                == Set(Origin.allCases))
    }
}
