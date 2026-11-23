import Core
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// **After the player the detail page stays put** (diagnosis F-039, 2026-09-30).
///
/// The IPTV provider with one connection slot says "not reachable" as long as the
/// playback that just ended still holds its slot. The finished page became an error page —
/// on the device that looked like the video crashing.
@MainActor
@Suite("Detail page after the player")
struct DetailAfterPlayerTests {

    /// Rejects the first `declines` fetches with "not reachable".
    final class Declining: ContentSource, @unchecked Sendable {
        var declines: Int
        var fetches = 0
        let error: any Error
        init(declines: Int, error: any Error = XtreamClient.Failure.unreachable) {
            self.declines = declines
            self.error = error
        }

        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        nonisolated var displayName: String { "Absagend" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }
        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem {
            fetches += 1
            if declines > 0 {
                declines -= 1
                throw error
            }
            return MediaItem(id: id, kind: .movie, title: "Kumlu Fincan")
        }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://server/\(itemID)")!
        }
    }

    private func film() -> MediaItem { MediaItem(id: "f1", kind: .movie, title: "Kumlu Fincan") }

    @Test("A connection refusal gets a second attempt")
    func secondAttempt() async {
        let source = Declining(declines: 1)
        let model = DetailModel(source: source, item: film())
        await model.load()
        #expect(model.state == .ready)
        #expect(source.fetches == 2)
    }

    @Test("If refreshing fails, the loaded page stays")
    func pageStays() async {
        let source = Declining(declines: 0)
        let model = DetailModel(source: source, item: film())
        await model.load()
        #expect(model.state == .ready)

        source.declines = 2
        await model.load()
        #expect(model.state == .ready)
    }

    @Test("A refusal with a reason is not repeated")
    func noLookupWithReason() async {
        let source = Declining(declines: 1, error: XtreamClient.Failure.unauthorized)
        let model = DetailModel(source: source, item: film())
        await model.load()
        #expect(source.fetches == 1)
        if case .failed = model.state {} else { Issue.record("expected: error page") }
    }
}
