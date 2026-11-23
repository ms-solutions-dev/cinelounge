import Core
import Foundation
import ParentalControls
import Testing

@testable import FeaturesPhone

/// That from the child account **no** path without a PIN leads to the adult channels.
///
/// **The most severe finding of the usability pass was exactly that:** four taps, without a
/// PIN. It was found by eye and would have crept back in by eye — that is why it stands
/// here as a test suite and not as a rule of thumb.
@MainActor
@Suite("Parental controls in the shell")
struct ParentalControlsShellTests {

    /// A state with its own store — **no check touches the real one.**
    static func state(pin: String? = "1234", childMode: Bool = true) -> ParentalControlsState {
        let store = UserDefaults(suiteName: "check.\(UUID().uuidString)")!
        let bucket = InMemoryStore()
        let built = ParentalControlsState(store: store, keychain: bucket)
        if let pin { built.setPin(pin) }
        built.mode.set(childMode)
        return built
    }

    // MARK: - The table covers every view

    /// **Every ID in the app needs a decision.**
    ///
    /// What the table does not know is open — that is the only possible direction, because
    /// locking an unknown ID would lock the app up at the next new screen. So that no door is
    /// forgotten anyway, this test checks the other side: **A new screen without an entry
    /// breaks the check**, and that is the point. The roadmap spoke of "sixteen doors"; the
    /// number was already wrong when it was built, the property remains correct.
    @Test("Every view of the app is in the door table")
    func everyViewDecided() {
        for view in ViewID.allCases {
            #expect(
                LockedDoors.board[view.rawValue] != nil,
                "\(view.rawValue) has no entry in LockedDoors")
        }
    }

    /// **And the sheets that are doors, likewise.** The account switch leads nowhere
    /// and still lifts every limit.
    @Test("The sheets that are doors are in it as well")
    func sheetsDecided() {
        for identifier in ["kontowechsel", "abmelden", "listeLoeschen"] {
            #expect(LockedDoors.locked(identifier), "\(identifier) must be closed")
        }
    }

    // MARK: - The path to the switch

    /// **The finding itself, as a test suite.** From the child account a path led through
    /// Settings to the "Adult channels" switch. Every station on it is closed today.
    ///
    /// **The path has been one step shorter since AP5, and that is no loss.** The
    /// switch appeared twice — globally under `Settings → Live` and per account in
    /// parental controls. It now appears only there; under Live a row leads to it.
    /// The path thus ends at parental controls, and that is locked.
    @Test("No path to the adult channels is open")
    func noWayWithoutPin() {
        let rule = Self.state().rule
        for step in ["einstellungen", "liveEinstellungen", "kindersicherung"] {
            #expect(rule.requiresPin(forItem: step), "\(step) could be opened without a PIN")
        }
    }

    /// **Without a PIN nothing applies, and that is not a loophole but honesty.**
    /// A lock without a stored PIN could be lifted by anyone with two taps.
    @Test("Without a stored PIN nothing locks")
    func noPinNoLock() {
        let rule = Self.state(pin: nil).rule
        #expect(!rule.applies)
        #expect(!rule.requiresPin(forItem: "einstellungen"))
    }

    // MARK: - The gatekeeper

    /// **The lock sits in one place**, and that is ``Navigator/show(_:)``.
    @Test("A closed door leads to the keypad instead of into the view")
    func gatekeeperStops() {
        let built = Self.state()
        let navigator = Navigator()
        navigator.gatekeeper = { built.job(forItem: $0.rawValue) }

        navigator.show(.settings)

        #expect(navigator.overlay.isEmpty, "the view must not open")
        #expect(navigator.asksForPin)
        if case .door(let identifier, let reason) = navigator.waiting {
            #expect(identifier == "einstellungen")
            #expect(!reason.isEmpty, "one sentence of its own per door")
        } else {
            Issue.record("no door request is waiting")
        }
    }

    /// **A pass applies to one door and not to all**, and only for one grip.
    @Test("The right PIN opens exactly this one door")
    func singleGrip() {
        let built = Self.state()
        let navigator = Navigator()
        navigator.gatekeeper = { built.job(forItem: $0.rawValue) }

        navigator.show(.settings)
        guard let job = navigator.waiting else {
            Issue.record("no request")
            return
        }
        #expect(built.verify("1234", forItem: job))
        navigator.letPass()

        #expect(navigator.overlay == [.settings])
        #expect(!navigator.asksForPin)
        // **Another** door is not affected.
        #expect(built.job(forItem: "konten") != nil)

        // And after the grip this one is closed again too.
        built.consume()
        #expect(built.job(forItem: "einstellungen") != nil)
    }

    /// **A wrong PIN opens nothing** — and leaves the question standing.
    @Test("A wrong PIN leads nowhere")
    func wrongPIN() {
        let built = Self.state()
        let navigator = Navigator()
        navigator.gatekeeper = { built.job(forItem: $0.rawValue) }

        navigator.show(.accounts)
        guard let job = navigator.waiting else {
            Issue.record("no request")
            return
        }
        #expect(!built.verify("9999", forItem: job))
        #expect(navigator.overlay.isEmpty)
        #expect(navigator.asksForPin, "the question stays")
    }

    /// **The way out leaves the request standing.**
    ///
    /// A first version of the prototype deleted it when turning away — four digits did
    /// nothing afterwards, and anyone who types the right PIN and sees nothing believes they
    /// mistyped.
    @Test("\"Forgot PIN\" keeps the waiting question")
    func recovery() {
        let built = Self.state()
        let navigator = Navigator()
        navigator.gatekeeper = { built.job(forItem: $0.rawValue) }

        navigator.show(.parentalControls)
        navigator.showFallback()

        #expect(navigator.overlay == [.forgotPin])
        #expect(navigator.waiting != nil, "the request must stay")
        #expect(!navigator.asksForPin, "the sheet stays closed meanwhile")

        navigator.back()
        #expect(navigator.asksForPin, "and opens again afterwards")
    }

    /// **The way out itself is never closed.** A lock without a way out is not a lock,
    /// but a defect.
    @Test("The \"Forgot PIN\" path is always open")
    func escapeIsOpen() {
        let built = Self.state()
        let navigator = Navigator()
        navigator.gatekeeper = { built.job(forItem: $0.rawValue) }
        navigator.show(.forgotPin)
        #expect(navigator.overlay == [.forgotPin])
    }

    // MARK: - The tab scope

    /// **In child mode Live and portals disappear — not dimmed, but gone.**
    @Test("Child mode removes Live and portals from the bar")
    func tabsDisappear() {
        let state = CatalogState.fromAccesses(
            jellyfin: true, channelList: true, portals: true)
        #expect(state.tabs.contains(.live))
        #expect(state.tabs.contains(.portals))

        let scoped = state.tabs(isInChildMode: true)
        #expect(!scoped.contains(.live))
        #expect(!scoped.contains(.portals))
        #expect(scoped.contains(.start))
        #expect(scoped.contains(.library))
        #expect(scoped.contains(.search))
    }

    /// **The scope comes last.** Whether the favorites are at the bottom depends on how
    /// many services are set up — not on how many of them a child may see.
    /// Otherwise the heart would move from the header to the bottom when a switch is flipped.
    @Test("The place of the favorites does not depend on child mode")
    func favoritesDoNotMove() {
        for state in CatalogState.allCases {
            let without = state.tabs.contains(.favorites)
            let using = state.tabs(isInChildMode: true).contains(.favorites)
            #expect(without == using, "the favorites have moved")
        }
    }

    /// **What carries no approvals returns nothing in child mode.** A channel that could
    /// still be reached via the Home screen would make the removed tab decoration —
    /// and the provider catalog does not carry `ageRating` at all.
    @Test("Channels, portals and providers deliver nothing in child mode")
    func originsWithoutApprovals() {
        let rule = Self.state().rule
        for origin in [Catalog.Origin.channelList, .portals, .provider] {
            #expect(!rule.scope.delivers(origin.rawValue), "\(origin.rawValue) still delivers")
        }
        #expect(rule.scope.delivers(Catalog.Origin.jellyfin.rawValue))
        #expect(rule.scope.delivers(Catalog.Origin.downloads.rawValue))
    }

    // MARK: - The filter over the source

    /// **The filter applies before a list is built** — and it applies on every path,
    /// not only the main one.
    @Test("The filtered source lets through only what the limit allows")
    func filtered() async throws {
        let rule = ProtectionRule(
            deviceLocked: true, isPinSet: true, limit: .from12, blocksUnrecognized: true)
        let filtered = FilteredSource(source: ApprovalProbe(), rule: rule)

        let title = try await filtered.items(in: "alle", filter: ItemFilter())
        #expect(title.map(\.id) == ["frei", "zwoelf", "ohne"])

        #expect(try await filtered.favorites().map(\.id) == ["frei", "zwoelf", "ohne"])
        #expect(try await filtered.resumable(limit: 9).map(\.id) == ["frei", "zwoelf", "ohne"])
        #expect(try await filtered.episodes(of: "s1").map(\.id) == ["frei", "zwoelf", "ohne"])
        // **No number is better than a wrong one.**
        #expect(try await filtered.itemCount(in: "alle", filter: ItemFilter()) == nil)
    }

    /// **Without an active lock, no wrapper.** A forwarding that does nothing costs
    /// a hop on every fetch and hides the real source in every troubleshooting.
    /// **The standing question is not a question for the filter.**
    ///
    /// If this wrapper said a fixed `true`, ``PlaylistKit/StateSource`` would no longer create a ledger
    /// over a filtered provider source — the child's progress would be
    /// lost, and exactly for the profile this wrapper exists for.
    /// If it said a fixed `false`, it would book a second time next to the media server.
    @Test("The filter wrapper does not answer the state question itself")
    func stateQueryPassedThrough() async throws {
        let rule = ProtectionRule(
            deviceLocked: true, isPinSet: true, limit: .from12, blocksUnrecognized: true)
        #expect(FilteredSource(source: ApprovalProbe(), rule: rule).tracksStateItself)
        #expect(
            !FilteredSource(
                source: ApprovalProbe(tracksStateItself: false), rule: rule
            ).tracksStateItself)
    }

    @Test("Without a lock the source stays the source")
    func unfiltered() async throws {
        let source = ProtectionRule.pending.about(ApprovalProbe())
        #expect(source is ApprovalProbe)
        #expect(try await source.items(in: "alle", filter: ItemFilter()).count == 5)
    }
}

/// Five titles with the approvals that actually occur.
struct ApprovalProbe: ContentSource {

    static let title: [MediaItem] = [
        MediaItem(id: "frei", kind: .movie, title: "A", ageRating: "FSK 0"),
        MediaItem(id: "zwoelf", kind: .movie, title: "B", ageRating: "FSK 12"),
        MediaItem(id: "sechzehn", kind: .movie, title: "C", ageRating: "FSK 16"),
        MediaItem(id: "fremd", kind: .movie, title: "D", ageRating: "TV-MA"),
        MediaItem(id: "ohne", kind: .movie, title: "E", ageRating: nil),
    ]

    var displayName: String { "Stub" }
    nonisolated var canStartAtOffset: Bool { true }
    /// **Settable, and there is a reason:** ``FilteredSource`` must pass this
    /// answer through. A probe that always says `true` could not show that.
    var tracksStateItself: Bool = true

    func libraries() async throws -> [Library] { [] }
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        Self.title
    }
    func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
        Self.title.count
    }
    func item(id: String) async throws -> MediaItem {
        Self.title.first { $0.id == id } ?? Self.title[0]
    }
    func children(of itemID: String) async throws -> [MediaItem] { Self.title }
    func resumable(limit: Int) async throws -> [MediaItem] { Self.title }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://example.invalid/stream")!
    }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { Self.title }
    func trailer(for itemID: String) async throws -> MediaItem? { nil }
    func nextEpisode(after itemID: String) async throws -> MediaItem? { Self.title[2] }
    func similarItem(to itemID: String) async throws -> MediaItem? { Self.title[2] }
    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { Self.title }
    func episodes(of seriesID: String) async throws -> [MediaItem] { Self.title }
    func trickplay(for itemID: String) async throws -> Trickplay? { nil }
    func beginSession(for itemID: String) async throws {}
    func endSession(for itemID: String, at position: TimeInterval) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
        nil
    }
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func refreshAfterPlayback(ids: [String]) async {}
}
