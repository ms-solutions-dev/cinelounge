import Core
import Flows
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// **Channel tiles in "Continue Watching" get only fitting actions** (Live check,
/// finding 7, 2026-09-27). "Mark as watched" and "Favourite" went to the media server
/// with the channel identifier; there was no way to take the channel out of the row.
@MainActor
@Suite("Continue Watching: channel tiles")
struct ContinueWatchingChannelTests {

    static let channel = MediaItem(
        id: "k1", kind: .channel, title: "Tagesfunke", parentTitle: "Das Nordlicht")
    static let film = MediaItem(id: "f1", kind: .movie, title: "Film")

    @Test("A channel tile in Continue Watching offers only removal")
    func channelInContinueWatching() {
        #expect(
            HomeModel.cardActions(forItem: Self.channel, inShelf: ShelfPreferences.resumeID)
                == [.fromContinueWatching])
    }

    @Test("In the Live shelf a channel tile has no menu")
    func channelInLiveShelf() {
        #expect(HomeModel.cardActions(forItem: Self.channel, inShelf: LiveShelf.identifier).isEmpty)
    }

    /// Since 2026-10-01, for every title "Remove from Continue Watching", as at Apple — instead of
    /// "Reset progress", which with the CL-Server left the position in place.
    @Test("A title keeps Watched and Favorite, gets Details at the top and Remove at the bottom")
    func title() {
        #expect(
            HomeModel.cardActions(forItem: Self.film, inShelf: ShelfPreferences.resumeID)
                == [.details, .seen, .favorite, .fromContinueWatching])
        #expect(HomeModel.cardActions(forItem: Self.film, inShelf: "neu") == [.seen, .favorite])
    }

    /// Requirement 2026-10-01: In Continue Watching a press plays, a long press leads via
    /// "Details" to the page.
    @Test("In Continue Watching film and episode play on press, series and channel do not")
    func playsOnPress() {
        let episode = MediaItem(id: "e1", kind: .episode, title: "Folge")
        let series = MediaItem(id: "s1", kind: .series, title: "Serie")
        let next = ShelfPreferences.resumeID
        #expect(HomeModel.playsOnPress(Self.film, inShelf: next))
        #expect(HomeModel.playsOnPress(episode, inShelf: next))
        #expect(!HomeModel.playsOnPress(series, inShelf: next))
        #expect(!HomeModel.playsOnPress(Self.channel, inShelf: next))
        #expect(!HomeModel.playsOnPress(Self.film, inShelf: "neu"))
    }

    @Test("Removal strikes the timestamp, the channel stays in the list")
    func forgotten() {
        let history = ChannelHistory(store: InMemoryStore(), profile: { "p" }, legacy: nil)
        let now = Date()
        history.memorize("zinne", um: now)
        history.memorize("das erste", um: now)
        history.forget("das erste")
        #expect(history.recentlyUsed(now: now) == ["zinne"])
        #expect(history.names == ["das erste", "zinne"])
    }

    @Test("The menu item takes the tile out of the row and forgets the channel")
    func remove() async {
        final class Transcript: @unchecked Sendable { var identifiers: [String] = [] }
        let transcript = Transcript()
        let channel = Channel(
            id: "k1", name: "Das Nordlicht", streamURL: URL(string: "http://x/1")!, playlistID: "l")
        let model = HomeModel(
            source: ChildInterfaceTests.ChildSource(), store: InMemoryStore(),
            shelfStore: InMemoryStore(),
            recentChannels: { [LiveShelf.tile(channel, isRunning: nil)] },
            forgetChannel: { transcript.identifiers.append($0) })
        await model.load()
        let previous = Self.continueWatching(model)
        #expect(previous.contains("k1"))
        await model.removeFromContinueWatching(LiveShelf.tile(channel, isRunning: nil))
        #expect(!Self.continueWatching(model).contains("k1"))
        #expect(transcript.identifiers == ["k1"])
    }

    static func continueWatching(_ model: HomeModel) -> [String] {
        guard case .ready(_, let shelves) = model.state else { return [] }
        return shelves.first { $0.id == ShelfPreferences.resumeID }?.items.map(\.id) ?? []
    }
}
