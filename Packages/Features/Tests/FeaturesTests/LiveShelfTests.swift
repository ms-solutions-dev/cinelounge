import Core
import Foundation
import PlaylistKit
import SourceProbe
import Testing

@testable import Features

/// **What is running right now — as a shelf on Home** (AP29, 2026-09-11).
///
/// The third of the three shelves and the only one the ``ShelfRule`` could not
/// flatten: a library has a *newest*, a channel list has a **guide**.
struct LiveShelfTests {

    static func channels(
        _ id: String, _ name: String, favorite: Bool = false, logo: String? = nil
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://x/\(id)")!,
            playlistID: "liste", logoURL: logo.flatMap(URL.init(string:)),
            epgID: id, isFavorite: favorite)
    }

    static func broadcast(_ channel: String, _ title: String, isRunning: Bool) -> Programme {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Programme(
            id: "\(channel)-\(title)", channelID: channel, title: title,
            start: isRunning ? now.addingTimeInterval(-600) : now.addingTimeInterval(3600),
            end: isRunning ? now.addingTimeInterval(600) : now.addingTimeInterval(7200))
    }

    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// **The most recently watched channel comes first, then the remembered ones.**
    ///
    /// Whoever opens the app usually wants to go back there — and it is the same information
    /// the Live area uses on entry. Two places with two opinions
    /// about where one was last would be one too many.
    @Test("Recently watched first, then the remembered ones, then the rest")
    func order() {
        let catalog = [
            Self.channels("a", "Eins"),
            Self.channels("b", "Zwei", favorite: true),
            Self.channels("c", "Drei"),
            Self.channels("d", "Vier", favorite: true),
        ]
        let ordered = LiveShelf.order(from: catalog, recent: [catalog[2].channelName])
        #expect(ordered.map(\.id) == ["c", "b", "d", "a"])
    }

    /// **Without a remembered channel, the order of the list stays.**
    @Test("Without memory and without marks the list order stays")
    func orderWithoutChoice() {
        let catalog = [Self.channels("a", "Eins"), Self.channels("b", "Zwei")]
        #expect(LiveShelf.order(from: catalog, recent: []).map(\.id) == ["a", "b"])
    }

    /// **Separator rows are not channels.**
    ///
    /// Some providers put headings into the list as entries. They have neither
    /// picture nor guide — a tile made from one would be a tile that does nothing.
    @Test("Separator rows do not go onto the shelf")
    func withoutSeparatorRows() {
        let catalog = [Self.channels("a", "===== SPORT ====="), Self.channels("b", "Zwei")]
        let ordered = LiveShelf.order(from: catalog, recent: [])
        #expect(ordered.allSatisfy { !$0.isSectionMarker })
    }

    /// **Only channels on which something is running right now.**
    ///
    /// The shelf answers "is something running that interests me". A channel without a
    /// guide entry does not answer it — it would be a tile with the channel name
    /// on it twice.
    @Test("A channel without a running programme stays out")
    func onlyWhatIsRunning() {
        let tiles = LiveShelf.tiles(
            channels: [Self.channels("a", "Eins"), Self.channels("b", "Zwei")],
            isVisible: LivePreferences(),
            recent: [],
            program: [
                "a": [Self.broadcast("a", "Tagesfunke", isRunning: true)],
                "b": [Self.broadcast("b", "Später", isRunning: false)],
            ],
            now: Self.now)

        #expect(tiles.count == 1)
        #expect(tiles.first?.id == "a")
    }

    /// **The channel is the title, the show the subtitle** — and not the other way round.
    ///
    /// ``EpisodeCard`` sets ``MediaItem/parentTitle`` large. Whoever skims Home
    /// recognizes the channel; the show is the answer to whether it is
    /// worth it.
    @Test("The tile carries the channel on top and the programme below")
    func tileLabeling() {
        let tile = LiveShelf.tile(
            Self.channels("a", "Das Nordlicht (HD)", logo: "https://bilder/ahorn.png"),
            isRunning: Self.broadcast("a", "Tagesfunke", isRunning: true))

        // **The cleaned-up name and not the raw one** — ``Channel/cleanName`` removes the
        // appended resolution. On a 420 pt tile every character counts, and
        // "(HD)" answers no question anyone has.
        #expect(tile.parentTitle == "Das Nordlicht")
        #expect(tile.title == "Tagesfunke")
        #expect(tile.kind == .channel)
        // **The address is passed through and not built** — see
        // ``AggregateSource/imageURL(itemID:kind:width:tag:)``.
        #expect(tile.artwork.posterID == "https://bilder/ahorn.png")
    }

    /// **Without a guide, the channel name stands in both lines.**
    ///
    /// Better than an empty subtitle, which looks as if something is missing. This case does not
    /// make it into the shelf anyway — it only arises when someone builds the tile individually.
    @Test("Without a programme the tile carries the channel name")
    func tileWithoutBroadcast() {
        let tile = LiveShelf.tile(Self.channels("a", "Eins"), isRunning: nil)
        #expect(tile.title == "Eins")
        #expect(tile.parentTitle == "Eins")
    }

    /// **An empty shelf does not appear.**
    ///
    /// That a channel list is set up is not news.
    @Test("Without tiles there is no shelf")
    func noEmptyShelf() {
        #expect(LiveShelf.shelf(from: []) == nil)
        #expect(LiveShelf.shelf(from: [LiveShelf.tile(Self.channels("a", "Eins"), isRunning: nil)]) != nil)
    }

    /// **Wide format, and that is not a matter of taste.**
    ///
    /// A channel has no poster; on a 2 : 3 tile there would in the end be a logo
    /// and not a word about what is running — so exactly not the information this shelf
    /// exists for.
    @Test("The shelf carries wide tiles")
    func wideTiles() throws {
        let shelf = try #require(
            LiveShelf.shelf(from: [LiveShelf.tile(Self.channels("a", "Eins"), isRunning: nil)]))
        #expect(shelf.usesWideCards)
        #expect(shelf.id == LiveShelf.identifier)
        #expect(shelf.libraryKind == .liveTV)
    }

    /// **The order also applies when capping — order first, then cut off.**
    ///
    /// **The check is here because the counter-test demanded it.** A first
    /// suite checked ``order(from:recent:)`` on its own and ``tiles(…)`` only for
    /// "what is running" and "at most six". If one then takes the order out of `tiles`,
    /// everything stays green — what was checked was that the rule *exists*, not that
    /// it is *applied*.
    ///
    /// The case behind it is real: on the phone the capping came before the ordering, and with
    /// 2064 visible channels a remembered channel beyond position 400 **never** got a
    /// guide (2026-09-07).
    @Test("The most recently watched channel goes onto the shelf, even from the very back")
    func orderBeforeCapping() {
        let catalog = (1...20).map { Self.channels("k\($0)", "Sender \($0)") }
        let program = Dictionary(
            uniqueKeysWithValues: catalog.map {
                ($0.id, [Self.broadcast($0.id, "Läuft", isRunning: true)])
            })
        let tiles = LiveShelf.tiles(
            channels: catalog, isVisible: LivePreferences(), recent: [catalog[18].channelName],
            program: program, now: Self.now)

        #expect(tiles.first?.id == "k19")
        #expect(tiles.count == LiveShelf.atMost)
    }

    /// **At most six.**
    ///
    /// A shelf with twenty channels would be the Live area done badly.
    @Test("The shelf ends at six")
    func upperLimit() {
        let catalog = (1...20).map { Self.channels("k\($0)", "Sender \($0)") }
        let program = Dictionary(
            uniqueKeysWithValues: catalog.map {
                ($0.id, [Self.broadcast($0.id, "Läuft", isRunning: true)])
            })
        let tiles = LiveShelf.tiles(
            channels: catalog, isVisible: LivePreferences(), recent: [],
            program: program, now: Self.now)
        #expect(tiles.count == LiveShelf.atMost)
    }

    /// **The whole list as on the phone** (Live check, finding 5, decision 25): after
    /// three channels, all three come first, the most recently watched first.
    @Test("All recently watched channels come first, in their order")
    func fullHistory() {
        let catalog = [
            Self.channels("a", "Eins"), Self.channels("b", "Zwei", favorite: true),
            Self.channels("c", "Drei"), Self.channels("d", "Vier"), Self.channels("e", "Fünf"),
        ]
        let history = [catalog[3], catalog[0], catalog[2]].map(\.channelName)
        #expect(
            LiveShelf.order(from: catalog, recent: history).map(\.id)
                == ["d", "a", "c", "b", "e"])
    }

    @Test("The TV's Live shelf reads the channel history, not LiveMemory")
    func shelfReadsHistory() throws {
        let text = SourceText.strippingCommentLines(try SourceText.read("MainView.swift", in: .features))
        let shelf = try #require(text.range(of: "nonisolated static func liveShelf("))
        let bodyContent = text[shelf.upperBound...].prefix(2500)
        #expect(bodyContent.contains("ChannelHistory().names"))
        #expect(!bodyContent.contains("LiveMemory.lastChannel"))
    }
}
