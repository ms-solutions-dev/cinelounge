import Core
import Flows
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Parity in the player on the phone** (AP58 G1, decision 27) — the same rules as
/// on the TV (`PlayerModelTests+Gleichstand`), connected to the ``PlayerModel``:
/// time offset (A1), board (A4), chapter (A5), speed (A6), similar movie (A8), source choice
/// per title (A9) and audio choice per title (A10).
@MainActor
@Suite("Parity in the player on the phone")
struct PlayerEquivalenceTests {

    static let address = URL(string: "http://a" + ".example/f.mp4")!

    /// A source that starts nothing and records what was asked for — **and that supplies
    /// the filter and the catalog** that the shared flows need.
    final class ProbeSource: PlayerSource, @unchecked Sendable {
        var asked: [String] = []
        var hostFetches: [String] = []
        var catalog: CatalogDouble?
        var isAllowed: (MediaItem) -> Bool = { _ in true }

        struct Declined: Error {}

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            asked.append(job.identifier)
            throw Declined()
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
        func host(zu job: PlaybackJob) async throws -> [PortalHost] {
            hostFetches.append(job.identifier)
            return [PortalHost(id: "a", name: "HOSTA"), PortalHost(id: "b", name: "Klenvauk")]
        }
        func contents(zu job: PlaybackJob) -> (any ContentSource)? { catalog }
        func mayPlay(_ title: MediaItem, zu job: PlaybackJob) -> Bool { isAllowed(title) }
    }

    static func recording(
        chapters: [Chapter] = [], audioTracks: [PlaybackTrack] = [], kind: PlaybackTarget.Kind = .recording
    ) -> PlaybackRequest {
        PlaybackRequest(
            identifier: "folge-1", title: "Folge 1", address: address, duration: 1_200,
            audioTracks: audioTracks, chapters: chapters, kind: kind)
    }

    static func model(
        _ source: (any PlayerSource)? = nil, series: String? = "serie",
        audioStore: any KeyValueStore = InMemoryStore()
    ) -> PlayerModel {
        PlayerModel(
            job: PlaybackJob(identifier: "folge-1", origin: .jellyfin, series: series),
            source: source ?? ProbeSource(), audioStore: audioStore)
    }

    // MARK: - Zeitversatz (A1)

    @Test("A channel without a buffer does not jump — until G1 the jump set it to zero")
    func channelWithoutBuffer() {
        let model = Self.model()
        model.job = Self.recording(kind: .live)
        model.set(location: 500)
        model.jump(-10)
        #expect(model.location == 500)
        #expect(!model.isSeekable)
        #expect(!model.hasTimeShift, "without a repackager with a ring, no switch")
    }

    @Test("Within the buffer the jump stays inside its limits")
    func channelInBuffer() {
        let model = Self.model()
        model.job = Self.recording(kind: .live)
        model.timeShiftWindow = TimeShift.Window(1_000...1_300)
        #expect(model.timeShiftWindow != nil)
        model.set(location: 1_250)
        #expect(model.isSeekable)
        #expect(model.isBehindLive)
        model.jump(30)
        #expect(model.location == 1_280)
        model.jump(-900)
        #expect(model.location == 1_000, "not before the oldest piece")
        model.jump(900)
        #expect(model.location == 1_300, "not beyond the edge")
        #expect(!model.isBehindLive)
    }

    @Test("A channel goes through the list with a ring, and the ring holds five minutes of pause")
    func channelViaList() {
        let channels = PlaybackRequest(
            identifier: "s", title: "Channel", address: URL(string: "http://s.invalid/live/1.ts")!,
            origin: .channelList, kind: .live)
        #expect(channels.target.decision.delivery == .remuxInApp)
        #expect(
            Double(TimeShift.capacity(.phone)) * 8 / TimeShift.highBitrate
                >= TimeShift.retention)
    }

    // MARK: - Kapitel (A5)

    static let chapters = [
        Chapter(title: "A", start: 0), Chapter(title: "B", start: 300), Chapter(title: "C", start: 900),
    ]

    @Test("Chapters jump as on the TV")
    func chapterSkipping() {
        let model = Self.model()
        model.job = Self.recording(chapters: Self.chapters)
        #expect(model.hasChapters)
        model.set(location: 100)
        model.skipChapter(forward: true)
        #expect(model.location == 300)
        model.skipChapter(forward: true)
        #expect(model.location == 900)
        model.set(location: 400)
        model.skipChapter(forward: false)
        #expect(model.location == 300)
    }

    @Test("A single chapter is no choice")
    func oneChapter() {
        let model = Self.model()
        model.job = Self.recording(chapters: [Self.chapters[0]])
        #expect(!model.hasChapters)
    }

    // MARK: - Tempo (A6)

    @Test("No speed control on a channel")
    func speedOnChannel() {
        let model = Self.model()
        model.job = Self.recording(kind: .live)
        #expect(!model.speedOffered)
        model.setRate(1.5)
        #expect(model.rate == 1)
    }

    // MARK: - Similar movie and board (A4, A8)

    static func film(_ id: String, unrestricted: Bool = true) -> MediaItem {
        var title = MediaItem(id: id, kind: .movie, title: "Movie \(id)")
        title.ageRating = unrestricted ? "FSK 6" : "FSK 18"
        return title
    }

    @Test("After a movie the similar one is on offer — it does not start by itself")
    func similarInOffering() {
        let model = Self.model(series: nil)
        model.similarItem = Self.film("two")
        model.core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        model.core.setNext(available: true, similar: true, location: 1_190, duration: 1_200)
        #expect(model.offerTitle == "Movie two")
        #expect(model.nextOffer != nil)
        #expect(model.core.episode(status: .ended, location: 1_200, duration: 1_200).step == .close)
    }

    @Test("The press plays the similar movie — only if the filter lets it through")
    func similarFiltered() async {
        let source = ProbeSource()
        source.isAllowed = { $0.ageRating != "FSK 18" }
        let model = Self.model(source, series: nil)
        model.similarItem = Self.film("blocked", unrestricted: false)
        await model.playNext()
        #expect(source.asked.isEmpty, "fail-closed: blocked does not play")

        model.similarItem = Self.film("free")
        await model.playNext()
        #expect(source.asked == ["free"])
    }

    @Test("Without information from the source the player offers nothing")
    func presetSaysNo() {
        struct Mute: PlayerSource {
            func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
                throw CancellationError()
            }
            func notify(
                location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob,
                isPaused: Bool
            ) async throws {}
        }
        #expect(!Mute().mayPlay(Self.film("x"), zu: PlaybackJob(identifier: "x")))
        #expect(Mute().contents(zu: PlaybackJob(identifier: "x")) == nil)
    }

    @Test("The composite source filters by origin and rule before asking the responsible one")
    func aggregateSourceFilters() {
        let kind = ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12,
            blocksUnrecognized: true, assignments: [:])
        let pending = CompositePlayerSource(jellyfin: ProbeSource())
        let filtered = CompositePlayerSource(jellyfin: ProbeSource(), rule: kind)
        let job = PlaybackJob(identifier: "x", origin: .jellyfin)
        #expect(pending.mayPlay(Self.film("x", unrestricted: false), zu: job))
        #expect(!filtered.mayPlay(Self.film("x", unrestricted: false), zu: job))
        #expect(filtered.mayPlay(Self.film("x"), zu: job))
        #expect(
            !CompositePlayerSource(rule: kind).mayPlay(Self.film("x"), zu: job),
            "without a responsible source: no")
    }

    @Test("The board loads through the shared info board, filtered")
    func board() async {
        let catalog = CatalogDouble()
        catalog.title = Self.film("folge-1")
        catalog.similar = [Self.film("a", unrestricted: false), Self.film("b")]
        let source = ProbeSource()
        source.catalog = catalog
        source.isAllowed = { $0.ageRating != "FSK 18" }
        let model = Self.model(source, series: nil)
        model.job = Self.recording()
        #expect(model.hasBoard)
        await model.loadBoard()
        #expect(model.board.more.map(\.id) == ["b"])
    }

    // MARK: - Quellenwahl je Titel (A9)

    @Test("The source choice applies per title — the next episode fetches its own")
    func sourceChoicePerTitle() async {
        let source = ProbeSource()
        let model = Self.model(source)
        await model.loadSelection()
        await model.loadSelection()
        #expect(source.hostFetches == ["folge-1"])
        #expect(model.choice.isWorthwhile)
    }

    // MARK: - Audio choice per title (A10)

    @Test("The chosen audio track is remembered under the series — the same store as on the TV")
    func audioIsRemembered() {
        let store = InMemoryStore()
        let model = Self.model(audioStore: store)
        model.job = Self.recording(audioTracks: [
            PlaybackTrack(id: 1, language: "deu"), PlaybackTrack(id: 2, language: "jpn"),
        ])
        model.select(audioTrack: 2)
        #expect(AudioMemory.load(from: store).language(forItem: "serie") == "jpn")
    }

    @Test("The choice in the detail page's source sheet now reaches the player")
    func sourceSheetRemembers() {
        let store = InMemoryStore()
        let page = DetailModel(identifier: "film", source: nil, rule: .pending)
        page.audioStore = store
        page.select(audioTrack: AudioTrackInfo(id: "2", name: "Japanese", language: "jpn"))
        #expect(page.audioTrack == "2")
        #expect(AudioMemory.load(from: store).language(forItem: "film") == "jpn")
    }

    // MARK: - Wiring

    @Test("The view carries board, chapters, live and speed")
    func wired() throws {
        let view = try SourceText.read("SpielerView.swift", in: .featuresPhone)
        #expect(view.contains("case .infoBoard:"))
        #expect(view.contains("model.skipChapter(forward: forward)"))
        #expect(view.contains("model.backToLive()"))
        #expect(view.contains("model.setRate($0)"))
        #expect(view.contains("model.holdSpeed("))
    }
}

/// A catalog that answers only what the board asks.
final class CatalogDouble: ContentSource, @unchecked Sendable {
    var title: MediaItem?
    var similar: [MediaItem] = []

    struct Missing: Error {}

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
        URL(string: "https://catalog.invalid/\(itemID)")!
    }
    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { similar }
}
