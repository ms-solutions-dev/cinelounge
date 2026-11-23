import Core
import Foundation
import PortalKit
import Testing

@testable import Flows

/// **Parity in the player** (AP58 G1, decision 27): time offset, chapters, speed, info
/// board, similar movie, source choice and series language — settled once, used by both
/// devices. The checks in `FeaturesTests` and `FeaturesPhoneTests` show that the views
/// are wired to it.
@MainActor
@Suite("Parity in the player")
struct PlayerParityTests {

    // MARK: - Time shift (A1)

    /// **Five minutes of pause at a high bitrate, on both devices** (Player check, V1): Until
    /// then the phone held 250 MB — at 17 Mbit/s that is just under two minutes.
    @Test("Both rings hold five minutes at 17 Mbit/s")
    func ringSizes() {
        for device in [TimeShift.Device.tv, .phone] {
            let seconds = Double(TimeShift.capacity(device)) * 8 / TimeShift.highBitrate
            #expect(seconds >= TimeShift.retention, "\(device): \(Int(seconds)) s")
        }
        #expect(TimeShift.retention == 300)
        #expect(TimeShift.minimumSize == 750 * 1_000_000)
        #expect(TimeShift.capacity(.tv) >= TimeShiftRing.defaultCapacity, "never less than before")
    }

    @Test("Time shift only for a channel via the own list")
    func switchPoint() {
        #expect(!TimeShift.applies(kind: .live, deliveryRoute: .remuxInApp, session: nil))
        #expect(!TimeShift.applies(kind: .recording, deliveryRoute: .remuxInApp, session: nil))
        #expect(!TimeShift.applies(kind: .live, deliveryRoute: .renderInApp, session: NSObject()))
    }

    @Test("A window under two seconds is not worth a bar")
    func smallWindow() {
        #expect(TimeShift.Window(nil) == nil)
        #expect(TimeShift.Window(100...101) == nil)
        #expect(TimeShift.Window(100...160) != nil)
    }

    @Test("Jumps stay in the buffer — not before the oldest piece, not beyond the edge")
    func limits() {
        guard let window = TimeShift.Window(1_000...1_300) else {
            Issue.record("no window")
            return
        }
        #expect(window.target(900) == 1_000)
        #expect(window.target(1_400) == 1_300)
        #expect(window.target(1_150) == 1_150)
        #expect(window.length == 300)
        #expect(window.portion(at: 1_150) == 0.5)
        #expect(window.location(portion: 2) == 1_300)
    }

    @Test("At the edge it is live, behind it time-shifted")
    func atEdge() {
        guard let window = TimeShift.Window(0...600) else {
            Issue.record("no window")
            return
        }
        #expect(window.atEdge(at: 599))
        #expect(window.atEdge(at: 600 - TimeShift.edgeTolerance))
        #expect(!window.atEdge(at: 500))
        #expect(window.lag(at: 480) == 120)
        #expect(window.lag(at: 700) == 0)
    }

    // MARK: - Chapters (A5)

    static let chapters = [
        Chapter(title: "Anfang", start: 0), Chapter(title: "Mitte", start: 300),
        Chapter(title: "Schluss", start: 900),
    ]

    @Test("Chapter buttons only from two marks and only for a recording")
    func chapterButtons() {
        #expect(ChapterJump.hasChapters(kind: .recording, chapters: Self.chapters))
        #expect(!ChapterJump.hasChapters(kind: .recording, chapters: [Self.chapters[0]]))
        #expect(!ChapterJump.hasChapters(kind: .live, chapters: Self.chapters))
    }

    @Test("Forward to the next chapter, back to the previous one or to the start")
    func chapterTargets() {
        #expect(
            ChapterJump.target(kind: .recording, chapters: Self.chapters, location: 100, forward: true) == 300
        )
        #expect(
            ChapterJump.target(kind: .recording, chapters: Self.chapters, location: 950, forward: true) == nil
        )
        #expect(
            ChapterJump.target(kind: .recording, chapters: Self.chapters, location: 400, forward: false)
                == 300
        )
        #expect(
            ChapterJump.target(kind: .recording, chapters: Self.chapters, location: 100, forward: false) == 0)
        #expect(ChapterJump.target(kind: .live, chapters: Self.chapters, location: 100, forward: true) == nil)
    }

    @Test("Chapter marks leave the edges free")
    func chapterMarks() {
        #expect(
            ChapterJump.fractions(kind: .recording, chapters: Self.chapters, duration: 1_200) == [0.25, 0.75])
        #expect(ChapterJump.fractions(kind: .recording, chapters: Self.chapters, duration: 0).isEmpty)
    }

    // MARK: - Tempo (A6)

    @Test("Six steps, 1 included, without 0.25 and without 3")
    func slots() {
        #expect(SpeedChoice.slots == [0.5, 0.75, 1, 1.25, 1.5, 2])
    }

    @Test("No speed for a channel and not where the engine cannot do it")
    func speedOffered() {
        #expect(SpeedChoice.isOffered(supportsSpeed: true, kind: .recording))
        #expect(!SpeedChoice.isOffered(supportsSpeed: true, kind: .live))
        #expect(!SpeedChoice.isOffered(supportsSpeed: false, kind: .recording))
    }

    @Test("The speed applies to the title, and after holding the chosen one applies again")
    func speedRules() {
        #expect(SpeedChoice.afterSwitch(1.5, sameTitle: false) == 1)
        #expect(SpeedChoice.afterSwitch(1.5, sameTitle: true) == 1.5)
        #expect(SpeedChoice.afterHold(chosen: 1.25) == 1.25)
    }

    // MARK: - Info board and similar movie (A4, A8)

    static func title(_ id: String, series: String? = nil, unrestricted: Bool = true) -> MediaItem {
        var title = MediaItem(id: id, kind: series == nil ? .movie : .episode, title: id)
        title.seriesID = series
        title.ageRating = unrestricted ? "FSK 6" : "FSK 18"
        return title
    }

    static let filter: (MediaItem) -> Bool = { $0.ageRating != "FSK 18" }

    @Test("The board shows the episodes from the running one — and only what the filter lets through")
    func boardEpisodes() async {
        let catalog = ContentCatalog()
        catalog.title = Self.title("f2", series: "s")
        catalog.episodes = [
            Self.title("f1", series: "s"), Self.title("f2", series: "s"),
            Self.title("f3", series: "s", unrestricted: false), Self.title("f4", series: "s"),
        ]
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "f2", series: nil, next: nil, mayPlay: Self.filter,
            applies: { true })
        #expect(board.isSeries, "the series also comes from the title itself")
        #expect(board.more.map(\.id) == ["f4"])
        #expect(board.loaded)
    }

    @Test("For a movie the similar ones fill the board, filtered")
    func boardSimilar() async {
        let catalog = ContentCatalog()
        catalog.title = Self.title("film")
        catalog.similar = [Self.title("a", unrestricted: false), Self.title("b")]
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "film", series: nil, next: nil, mayPlay: Self.filter,
            applies: { true })
        #expect(!board.isSeries)
        #expect(board.more.map(\.id) == ["b"])
    }

    @Test("An answer for an abandoned title is discarded")
    func boardDiscarded() async {
        let catalog = ContentCatalog()
        catalog.title = Self.title("film")
        let board = InfoBoard()
        await board.load(
            source: catalog, identifier: "film", series: nil, next: nil, mayPlay: Self.filter,
            applies: { false })
        #expect(board.title == nil)
        #expect(!board.loaded, "a new attempt stays possible")
    }

    @Test("The similar movie is the first one the filter lets through — or none")
    func similarMovie() async {
        let catalog = ContentCatalog()
        catalog.similarItem = Self.title("blocked", unrestricted: false)
        catalog.similar = [Self.title("blocked", unrestricted: false), Self.title("free")]
        let film = await InfoBoard.allowedRelated(
            zu: "x", from: catalog, mayPlay: Self.filter)
        #expect(film?.id == "free")
        catalog.similar = [Self.title("blocked", unrestricted: false)]
        #expect(
            await InfoBoard.allowedRelated(zu: "x", from: catalog, mayPlay: Self.filter)
                == nil)
    }

    @Test("A similar movie is called that and does not count down")
    func offerWording() {
        #expect(
            PlaybackWording.offer(similar: true, seconds: 7)
                == AppLanguageSetting.word("player.similarOffer"))
        #expect(PlaybackWording.offer(similar: false, seconds: 7) == PlaybackWording.nextIn(7))
    }

    // MARK: - Source picker and series language (A9)

    static let rows = [
        PortalHost(id: "hosta-de", name: "HOSTA", language: "Deutsch"),
        PortalHost(id: "hosta-sub", name: "HOSTA", language: "Japanisch mit Untertiteln"),
        PortalHost(id: "dood-de", name: "Hosth", language: "Deutsch", locked: true),
    ]

    @Test("The source picker fetches once per title and filters blocked items from the flat list")
    func sourceChoice() async {
        let flow = SourcePickerFlow()
        var fetches = 0
        await flow.load(forItem: "f1") {
            fetches += 1
            return Self.rows
        }
        await flow.load(forItem: "f1") {
            fetches += 1
            return []
        }
        #expect(fetches == 1)
        #expect(flow.isWorthwhile)
        #expect(flow.selectable.map(\.id) == ["hosta-de", "hosta-sub"])
        await flow.load(forItem: "f2") {
            fetches += 1
            return [Self.rows[0]]
        }
        #expect(fetches == 2, "the next episode has its own list")
        #expect(!flow.isWorthwhile)
    }

    @Test("A row names host and version")
    func caption() {
        #expect(SourcePickerFlow.caption(Self.rows[1]) == "HOSTA · OmU")
        #expect(SourcePickerFlow.caption(PortalHost(id: "x", name: "HD 1080p")) == "HD 1080p")
    }

    @Test("The series language switches immediately and back on a failure")
    func seriesLanguage() async {
        let store = LanguageStorage()
        let choice = SeriesLanguageFlow(routes: store.routes)
        await choice.loadLanguage()
        #expect(choice.language == "Deutsch")
        await choice.select("Japanisch")
        #expect(choice.language == "Japanisch")
        store.fails = true
        await choice.select("Englisch")
        #expect(choice.language == "Japanisch")
        await choice.loadLanguages()
        #expect(choice.languages == ["Deutsch", "Japanisch"])
    }
}

/// A catalog that answers only what the board asks.
final class ContentCatalog: ContentSource, @unchecked Sendable {
    var title: MediaItem?
    var episodes: [MediaItem] = []
    var similar: [MediaItem] = []
    var similarItem: MediaItem?

    struct Missing: Error {}
    /// What `item(id:)` throws, when set — for aborting the view.
    var error: (any Error)?

    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    nonisolated var displayName: String { "Catalog" }
    nonisolated var canStartAtOffset: Bool { false }
    nonisolated var tracksStateItself: Bool { true }
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
        nil
    }
    func libraries() async throws -> [Core.Library] { [] }
    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        if let error { throw error }
        guard let title else { throw Missing() }
        return title
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://katalog.invalid/\(itemID)")!
    }
    func episodes(of seriesID: String) async throws -> [MediaItem] { episodes }
    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { similar }
    func similarItem(to itemID: String) async throws -> MediaItem? { similarItem }
}

/// The paths of a series' language — with a switch that makes setting fail.
final class LanguageStorage: @unchecked Sendable {
    var language = "Deutsch"
    var fails = false
    struct Rejection: Error {}

    var routes: SeriesLanguageFlow.Routes {
        SeriesLanguageFlow.Routes(
            read: { self.language },
            list: { ["Deutsch", "Japanisch"] },
            set: { fresh in
                if self.fails { throw Rejection() }
                self.language = fresh
            })
    }
}
