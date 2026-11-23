import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

// MARK: - Duplicates

/// An engine that plays nothing but answers everything.
///
/// The checks run without `await` at the places where the engine is queried:
/// host and engine live on the main actor, and without a suspension point no
/// callback can interfere. Whoever later inserts an `await` there makes them unreliable.
@MainActor
final class ControllerDouble: PlaybackController {

    var status: PlaybackStatus = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var selectedAudioTrack: PlaybackTrack.ID?
    var selectedSubtitleTrack: PlaybackTrack.ID?
    /// `nil` as with VLC; the checks on the system engine set a span.
    var bufferedRange: ClosedRange<TimeInterval>?
    /// The window in a channel's buffer (AP58 G1, A1) — set by the checks.
    var timeShiftWindow: ClosedRange<TimeInterval>?
    private(set) var liveJumps = 0

    func seekToLiveEdge() {
        liveJumps += 1
    }

    /// All three startup reports can be set separately — the differences are the
    /// core of the honest startup measurement: "image size known" does not mean "image
    /// drawn", and "the engine is playing" does not mean "was ready".
    /// ``readyToPlayAt`` is therefore explicitly **not** derived from ``status``:
    /// a double that couples the two could not check the separation it is
    /// about at all.
    var hasVideoOutput: Bool?
    var firstFrameVisible: Bool?
    var readyToPlayAt: Date?

    private(set) var seeks: [TimeInterval] = []
    private(set) var didPause = false
    private(set) var didPlay = false

    /// Like the system player: it can do it. Can be switched off in order to play an engine
    /// that cannot — see ``Core/PlaybackController/supportsSpeed``.
    var supportsSpeed = true
    /// **Every change, not just the last.** The interesting question is whether the
    /// engine **gets** the chosen tempo again after a stop.
    private(set) var rates: [Double] = []

    func setRate(_ rate: Double) {
        rates.append(rate)
    }

    func load(_ url: URL, startingAt position: TimeInterval) {
        self.position = position
    }

    func play() {
        didPlay = true
        status = .playing
    }

    func pause() {
        didPause = true
        status = .paused
    }

    func stop() {}

    func seek(to position: TimeInterval) {
        seeks.append(position)
        self.position = position
    }

    func selectAudioTrack(_ id: PlaybackTrack.ID) {
        selectedAudioTrack = id
    }

    func selectSubtitleTrack(_ id: PlaybackTrack.ID?) {
        selectedSubtitleTrack = id
    }
}

/// The host as a double — holds the same engine across all targets.
///
/// The real host swaps it out; here it stays the same, so that a check after
/// the switch to the next episode can keep specifying the same position.
@MainActor
final class HostDouble: PlaybackHosting {

    let engine = ControllerDouble()

    var controller: any PlaybackController { engine }

    private(set) var started: [PlaybackTarget] = []
    private(set) var stopCount = 0

    func start(_ target: PlaybackTarget) {
        started.append(target)
        engine.position = target.startAt
        engine.status = .opening
    }

    func stop() {
        stopCount += 1
    }

    /// What arrived in supplied frame rates — the check reads it out.
    private(set) var lateFrameRates: [Double] = []

    func adopt(contentFrameRate rate: Double) {
        lateFrameRates.append(rate)
    }
}

/// A source that writes down what was reported to it.
///
/// On the main actor and not as an actor: the checks read the record
/// immediately after the tick, and a second actor would bring a further
/// suspension point between act and proof.
@MainActor
final class SourceSpy: ContentSource {

    /// No background sync — test doubles report nothing afterwards.
    /// Spelled out, because the contract no longer has a default for it; why
    /// is stated at ``ContentSource/listChanges()``.
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    nonisolated var displayName: String { "Doppel" }
    /// Like Jellyfin: the server can deliver from a position — can be switched off
    /// in order to play a provider that hands out files only as they lie.
    nonisolated(unsafe) var startsAtOffset = true
    nonisolated var canStartAtOffset: Bool { startsAtOffset }
    /// **A test double keeps its own state** — nobody is supposed to wrap it.
    nonisolated var tracksStateItself: Bool { true }

    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }

    var segmentsToReturn: [MediaSegment] = []
    var nextEpisodeToReturn: MediaItem?
    var similarToReturn: MediaItem?
    var trickplayToReturn: Trickplay?
    var itemToReturn: MediaItem?

    func similarItem(to itemID: String) async throws -> MediaItem? { similarToReturn }

    /// The list from the `Similar` endpoint — index card and replacement for the locked offer.
    var similarListToReturn: [MediaItem] = []
    /// All episodes of the series, for the index card "More episodes".
    var episodesToReturn: [MediaItem] = []

    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
        similarListToReturn
    }

    func episodes(of seriesID: String) async throws -> [MediaItem] { episodesToReturn }

    private(set) var begun: [String] = []
    private(set) var ended: [(itemID: String, position: TimeInterval)] = []
    private(set) var reports: [(progress: PlaybackProgress, isPaused: Bool)] = []

    enum Missing: Error { case item }

    func libraries() async throws -> [Core.Library] { [] }

    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }

    func item(id: String) async throws -> MediaItem {
        guard let itemToReturn else { throw Missing.item }
        return itemToReturn
    }

    func children(of itemID: String) async throws -> [MediaItem] { [] }

    func resumable(limit: Int) async throws -> [MediaItem] { [] }

    /// Holds back the response to the chapters while set — for the race between two
    /// titles (player check, finding S8).
    var beforeSegments: (() async -> Void)?

    func segments(for itemID: String) async throws -> [MediaSegment] {
        await beforeSegments?()
        return segmentsToReturn
    }

    /// What the player asked addresses for — the fallback to the
    /// server's chunking may only do that for a source that can touch the
    /// stream.
    private(set) var streamRequests: [String] = []

    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        streamRequests.append(itemID)
        return URL(string: "https://server/Videos/\(itemID)/stream")!
    }

    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        reports.append((progress, isPaused))
    }

    func nextEpisode(after itemID: String) async throws -> MediaItem? { nextEpisodeToReturn }

    func trickplay(for itemID: String) async throws -> Trickplay? { trickplayToReturn }

    func beginSession(for itemID: String) async throws {
        begun.append(itemID)
    }

    func endSession(for itemID: String, at position: TimeInterval) async throws {
        ended.append((itemID, position))
    }
}
