import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// The Home screen after the decisions of 2026-09-06 — direction B for K4 and W2.
@Suite("Home screen")
struct HomeScreenTests {

    private static func channel(_ name: String, identifier: String? = nil) -> Channel {
        Channel(
            id: identifier ?? name, name: name,
            streamURL: URL(string: "https://example.test/\(UUID().uuidString)")!,
            playlistID: "probe", group: "DE | SPORT")
    }

    // MARK: - Which channels appear in "Live today"

    /// **The own selection is not only first, it stands alone** — it is the only
    /// information that comes from the viewer themselves.
    ///
    /// Until 2026-09-07 it was only the first of three tiers, and under the four chosen
    /// channels there were still two from the history. Product requirement: if an entry is
    /// chosen there at all, the selection from settings takes precedence over the default.
    @Test("The choice from Appearance takes precedence over everything")
    func choiceFirst() {
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE"), Self.channel("Sportfeld")]
        let ordered = TodayLive.order(
            from: channels, chosen: ["Sportfeld"], recent: ["ZINNE"])
        #expect(ordered.map(\.name) == ["Sportfeld"])
    }

    /// **Without a selection the recently watched** — the product requirement of 2026-09-06.
    @Test("Without a choice the most recently watched come first")
    func lastWatched() {
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE"), Self.channel("Sportfeld")]
        let ordered = TodayLive.order(
            from: channels, chosen: [], recent: ["Sportfeld", "ZINNE"])
        #expect(ordered.map(\.name) == ["Sportfeld", "ZINNE", "Das Nordlicht"])
    }

    /// **After the history the favorites** — since AP58 R5 as on the TV
    /// (``Core/LiveShelfChoice/order(from:chosen:recent:)``). Until then the
    /// phone knew no favorites here, and a star changed nothing on the shelf.
    @Test("Without a choice: history first, then favorites, then the rest")
    func favoritesAfterHistory() {
        var remembered = Self.channel("Sportfeld")
        remembered.isFavorite = true
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE"), remembered]
        let ordered = TodayLive.order(from: channels, chosen: [], recent: ["ZINNE"])
        #expect(ordered.map(\.name) == ["ZINNE", "Sportfeld", "Das Nordlicht"])
    }

    /// **And without either, the provider's order** — otherwise the shelf would stand empty on the
    /// first day, and nobody would say why.
    @Test("Without a choice and without history the list stays as it came")
    func withoutAnything() {
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE")]
        let ordered = TodayLive.order(from: channels, chosen: [], recent: [])
        #expect(ordered.map(\.name) == ["Das Nordlicht", "ZINNE"])
    }

    /// **A selection displaces the default, it does not supplement it** (requirement, 2026-09-07:
    /// if an entry is chosen there at all, the selection from settings takes precedence over the
    /// default).
    ///
    /// Until then, two from the history stood under the four chosen channels — the
    /// app added something nobody had asked for, and on the narrow shelf the addition pushed
    /// the chosen items out of view.
    @Test("A choice displaces the history")
    func choiceDisplacesHistory() {
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE"), Self.channel("Avena")]
        let ordered = TodayLive.order(
            from: channels, chosen: ["ZINNE"], recent: ["Avena", "Das Nordlicht"])
        #expect(ordered.map(\.name) == ["ZINNE"])
    }

    /// Without a selection the history applies, and then the rest — both without duplicates.
    @Test("Without a choice the history leads, then the provider")
    func withoutChoiceHistoryLeads() {
        let channels = [Self.channel("Das Nordlicht"), Self.channel("ZINNE"), Self.channel("Avena")]
        let ordered = TodayLive.order(
            from: channels, chosen: [], recent: ["ZINNE", "ZINNE", "Avena"])
        #expect(ordered.map(\.name) == ["ZINNE", "Avena", "Das Nordlicht"])
        #expect(ordered.count == channels.count)
    }

    /// **One name, one channel.** The same channel stands at the provider in several groups,
    /// with several IDs; on 2026-09-07. "TR: KULE SPORT" therefore stood twice next to each other
    /// on the shelf — the same match, the same bar.
    @Test("The same channel from two groups appears once")
    func noDuplicates() {
        let channels = [
            Self.channel("KULE SPORT", identifier: "group-a"),
            Self.channel("KULE SPORT", identifier: "group-b"),
        ]
        let ordered = TodayLive.order(from: channels, chosen: ["KULE SPORT"], recent: [])
        #expect(ordered.map(\.id) == ["group-a"])
    }

    /// **The name is remembered and not the ID** — an Xtream ID changes
    /// when the provider rebuilds its list, and then the selection would silently be gone.
    @Test("The choice survives a new identifier")
    func nameInsteadOfIdentifier() {
        let old = [Self.channel("Sportfeld", identifier: "old-1"), Self.channel("ZINNE")]
        let fresh = [Self.channel("Sportfeld", identifier: "new-9"), Self.channel("ZINNE")]
        #expect(
            TodayLive.order(from: old, chosen: ["Sportfeld"], recent: []).first?.id
                == "old-1")
        #expect(
            TodayLive.order(from: fresh, chosen: ["Sportfeld"], recent: []).first?.id
                == "new-9")
    }

    /// A name that no longer exists is skipped instead of leading to empty rows.
    @Test("A choice of a vanished channel does nothing")
    func vanishedChannel() {
        let channels = [Self.channel("ZINNE")]
        let ordered = TodayLive.order(from: channels, chosen: ["Does not exist"], recent: [])
        #expect(ordered.map(\.name) == ["ZINNE"])
    }

    // MARK: - The remembered order

    /// **The request of 2026-09-06:** if a sort order has already been set up there,
    /// can it be carried over to the Home screen?
    @Test("The chosen order survives an app run")
    func orderStays() {
        let memory = SortMemory(store: Self.freshStore())
        let catalog = Catalog.Identifier(.jellyfin, .movies, "filme")
        let choice = OrderChoice(sorting: .rating, ascending: false, explicit: true)

        memory.memorize(choice, zu: catalog)
        #expect(memory.last(zu: catalog) == choice)
    }

    /// **The default is not a state.** Storing it would mean saving "I have chosen
    /// nothing" and reading it as a selection on the next open.
    @Test("The default is not remembered")
    func presetNotRemembered() {
        let memory = SortMemory(store: Self.freshStore())
        let catalog = Catalog.Identifier(.jellyfin, .movies, "filme")

        memory.memorize(
            OrderChoice(sorting: .rating, ascending: false, explicit: true),
            zu: catalog)
        memory.memorize(OrderChoice.preset(forItem: .movies), zu: catalog)
        #expect(memory.last(zu: catalog) == nil)
    }

    /// Two catalogs, two orders — whoever sorted the movies by rating
    /// finds that there and not for the series.
    @Test("The order belongs to the catalog")
    func orderPerCatalog() {
        let memory = SortMemory(store: Self.freshStore())
        let movies = Catalog.Identifier(.jellyfin, .movies, "filme")
        let allSeries = Catalog.Identifier(.jellyfin, .allSeries, "serien")

        memory.memorize(
            OrderChoice(sorting: .rating, ascending: false, explicit: true),
            zu: movies)
        #expect(memory.last(zu: movies)?.sorting == .rating)
        #expect(memory.last(zu: allSeries) == nil)
    }

    /// **The direction belongs to the selection.** One tap sorts, the second reverses — without
    /// the direction the second tap would be forgotten at the next start.
    @Test("The direction is remembered too")
    func directionStays() {
        let memory = SortMemory(store: Self.freshStore())
        let catalog = Catalog.Identifier(.jellyfin, .movies, "filme")

        memory.memorize(
            OrderChoice(sorting: .title, ascending: false, explicit: true),
            zu: catalog)
        #expect(memory.last(zu: catalog)?.ascending == false)
    }

    /// The library's order as the server's — **the translation stands in one
    /// place**, otherwise Home and library drift apart.
    @Test("Every order has its counterpart on the server")
    func serverOrder() {
        #expect(JellyfinStartSource.serverOrder(.title) == .title)
        #expect(JellyfinStartSource.serverOrder(.fresh) == .dateAdded)
        #expect(JellyfinStartSource.serverOrder(.rating) == .rating)
    }

    /// **Since AP40 a file store and not user defaults.** For the check
    /// a compartment in working memory is enough — it fulfils the same contract.
    private static func freshStore() -> any KeyValueStore {
        InMemoryStore()
    }
}
