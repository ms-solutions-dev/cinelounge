import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The player offers only what the shell would open** (check 2026-09-25, finding 1).
///
/// After a cleared movie, an 18-rated one stood in the offer as a "similar movie" for a child,
/// the index card led to it, and a press played it. The check uses the real
/// filter of the shell (``ParentalControls/ChildScope/opens(_:origin:)``) of a child with limit 6.
@MainActor
@Suite("Player: offers through the filter")
struct PlayerModelChildProtectionTests {

    private static let dragon = MediaItem(
        id: "drache2", kind: .movie, title: "Der kleine Funkelfuchs 2", ageRating: "0")
    private static let evening = MediaItem(
        id: "abend", kind: .movie, title: "Ein später Abend", ageRating: "18")

    private func childState() -> ParentalControlsState {
        let store = InMemoryStore()
        _ = Pin(store: store).set("1234")
        let profileStore = InMemoryStore()
        var person = Profile(name: "Selin")
        person.kind = .kind
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: profileStore)
        let state = ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: profileStore,
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
        state.set(limit: .from6, forItem: person.identifier.rawValue)
        return state
    }

    private func model(
        _ source: SourceSpy, seriesID: String? = nil
    ) -> (PlayerModel, HostDouble) {
        let kind = childState()
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: "drache",
                title: "Der kleine Funkelfuchs",
                url: URL(string: "https://server/Videos/drache/main.m3u8")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .hls, reason: .containerNotNativelySupported),
                duration: 7200,
                seriesID: seriesID,
                kind: .recording
            ),
            engine: host,
            source: source,
            mayPlay: { kind.rule.scope.opens($0) }
        )
        return (model, host)
    }

    @Test("A blocked similar film gives way to the first allowed one in the list")
    func similarFilmYields() async {
        let source = SourceSpy()
        source.similarToReturn = Self.evening
        source.similarListToReturn = [Self.evening, Self.dragon]
        let (model, _) = model(source)

        await model.loadContext()

        #expect(model.nextEpisode?.id == "drache2")
        #expect(model.nextIsSimilar)
    }

    @Test("If nothing related is allowed, there is no offer")
    func noOffer() async {
        let source = SourceSpy()
        source.similarToReturn = Self.evening
        source.similarListToReturn = [Self.evening]
        let (model, _) = model(source)

        await model.loadContext()

        #expect(model.nextEpisode == nil)
        #expect(!model.nextIsSimilar)
    }

    @Test("A blocked next episode is not offered")
    func lockedEpisode() async {
        let source = SourceSpy()
        source.nextEpisodeToReturn = MediaItem(
            id: "f2", kind: .episode, title: "Folge 2", seriesID: "serie", ageRating: "16")
        let (model, _) = model(source, seriesID: "serie")

        await model.loadContext()

        #expect(model.nextEpisode == nil)
    }

    @Test("The \"Similar Movies\" card lists only allowed items")
    func flashcardFiltered() async {
        let source = SourceSpy()
        source.itemToReturn = MediaItem(id: "drache", kind: .movie, title: "Der kleine Funkelfuchs")
        source.similarListToReturn = [Self.evening, Self.dragon]
        let (model, _) = model(source)

        await model.loadInfoIfNeeded()

        #expect(model.siblingEpisodes.map(\.id) == ["drache2"])
    }

    @Test("The \"More Episodes\" card lists only allowed items")
    func episodesFiltered() async {
        let source = SourceSpy()
        source.itemToReturn = MediaItem(id: "drache", kind: .episode, title: "Folge 1")
        source.episodesToReturn = [
            MediaItem(id: "drache", kind: .episode, title: "Folge 1", ageRating: "0"),
            MediaItem(id: "f2", kind: .episode, title: "Folge 2", ageRating: "16"),
            MediaItem(id: "f3", kind: .episode, title: "Folge 3", ageRating: "6"),
        ]
        let (model, _) = model(source, seriesID: "serie")

        await model.loadInfoIfNeeded()

        #expect(model.siblingEpisodes.map(\.id) == ["f3"])
    }

    @Test("A press on a blocked title does not play it, on an allowed one it does")
    func printDoesNotPlay() async {
        let source = SourceSpy()
        let (model, _) = model(source)
        var full = Self.evening
        full.source = MediaSource(container: .mp4, audioTracks: [], subtitleTracks: [])
        source.itemToReturn = full

        await model.play(Self.evening)
        #expect(model.target.itemID == "drache")

        full = Self.dragon
        full.source = MediaSource(container: .mp4, audioTracks: [], subtitleTracks: [])
        source.itemToReturn = full
        await model.play(Self.dragon)
        #expect(model.target.itemID == "drache2")
    }
}
