import Core
import Foundation
import JellyfinAPI
import Testing

@testable import JellyfinKit

/// The data layer for P3: collections, collection parts, episodes across season
/// boundaries and the director names — all against real server responses.
@Suite("Collections and episodes — mapping and ordering")
struct CollectionMappingTests {

    // MARK: - Collections

    @Test("A BoxSet becomes a collection with title, poster and part count")
    func boxSetMapping() throws {
        let response = try ItemMappingTests.fixture(
            "boxset-list", as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        // The real catalog: six collections, all with posters.
        #expect(items.count == 6)
        for item in items {
            #expect(item.kind == .collection)
            #expect(!item.title.isEmpty)
            #expect(item.artwork.posterID != nil)
            #expect(item.artwork.posterTag != nil, "without a tag there is no durable image fetch")
        }

        // `ChildCount` carries the number of parts — verified on the filled BoxSet.
        let kitewalker = try #require(items.first { $0.title == "Toke-Gretkl Punprei" })
        #expect(kitewalker.seasonCount == 3)
    }

    @Test("The parts of a collection are ordinary films")
    func boxSetParts() throws {
        let response = try ItemMappingTests.fixture(
            "boxset-parts", as: BaseItemDtoQueryResult.self)
        let parts = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        #expect(parts.count == 3)
        for part in parts {
            #expect(part.kind == .movie)
            #expect(part.recordedAt != nil, "without a release date there is no order")
        }
    }

    @Test("Parts are ordered by release date, not alphabetically")
    func partsOrderedByPremiereDate() throws {
        let response = try ItemMappingTests.fixture(
            "boxset-parts", as: BaseItemDtoQueryResult.self)
        let parts = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        // Deliberately scrambled — the order must come from the calculation, not from the
        // random order of the server response.
        let arranged = JellyfinSource.byPremiereDate(parts.reversed())

        #expect(arranged.map(\.title) == ["Toke-Gretkl", "Toke-Gretkl 2", "Toke-Gretkl 3"])
    }

    @Test("Parts without a date go to the end instead of the front")
    func partsWithoutDateGoLast() {
        let dated = MediaItem(id: "a", kind: .movie, title: "Mit Datum", recordedAt: .now)
        let undated = MediaItem(id: "b", kind: .movie, title: "Aaa without date")

        let arranged = JellyfinSource.byPremiereDate([undated, dated])
        #expect(arranged.map(\.id) == ["a", "b"])
    }

    // MARK: - Episodes across season boundaries

    @Test("Episodes are ordered across the season boundary")
    func episodesAcrossSeasons() throws {
        let response = try ItemMappingTests.fixture(
            "episodes-two-seasons", as: BaseItemDtoQueryResult.self)
        let episodes = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        // The fixture carries the end of season 1 and the start of season 2 of The Flaihuski Freipri
        // Taspreis — exactly the transition at which the old map broke off.
        let arranged = JellyfinSource.inBroadcastOrder(episodes.shuffled())

        let order = arranged.map { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) }
        #expect(order.map(\.0) == [1, 1, 2, 2, 2])
        #expect(order.map(\.1) == [16, 17, 1, 2, 3])

        // All hang on the same series — that is how the player recognizes the membership.
        #expect(Set(arranged.compactMap(\.seriesID)).count == 1)
    }

    @Test("Episodes without a number sit at the end, not in the middle of the count")
    func unnumberedEpisodesGoLast() {
        let extra = MediaItem(id: "x", kind: .episode, title: "Extra")
        let first = MediaItem(
            id: "a", kind: .episode, title: "S1F1", seasonNumber: 1, episodeNumber: 1)
        let second = MediaItem(
            id: "b", kind: .episode, title: "S2F1", seasonNumber: 2, episodeNumber: 1)

        let arranged = JellyfinSource.inBroadcastOrder([extra, second, first])
        #expect(arranged.map(\.id) == ["a", "b", "x"])
    }

    // MARK: - Miaplein

    @Test("The director comes as names, even without a stored image")
    func directorsFromDetail() throws {
        let dto = try ItemMappingTests.fixture("movie-detail", as: BaseItemDto.self)
        let item = try #require(ItemMapping.mediaItem(from: dto))

        // Zusk Febriofi has no image in the catalog — he would drop out of the `cast` filter, which
        // is exactly why the separate field exists.
        #expect(item.directors == ["Zusk Febriofi"])
        // Writing and production do not belong in the director line.
        #expect(item.directors?.contains("Blis Mouskl") == false)
    }

    @Test("List responses without people yield no empty director list, but none")
    func directorsAbsentInLists() throws {
        let response = try ItemMappingTests.fixture(
            "boxset-parts", as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        // Lists do not carry `People` — "not asked" must stay `nil`, otherwise a list snapshot
        // overwrites a real answer with empty.
        for item in items {
            #expect(item.directors == nil)
        }
    }

    // MARK: - Cache keys

    @Test("The collection keys are named stably")
    func collectionKeys() {
        // The keys stand in snapshot files on disk — a silent rename would throw away every
        // download on update.
        #expect(JellyfinSource.collectionsKey == "boxsets")
        #expect(JellyfinSource.collectionKey("abc") == "boxset:abc")
    }
}
