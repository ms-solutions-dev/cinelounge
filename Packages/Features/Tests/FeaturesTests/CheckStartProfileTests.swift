import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// Check agent `start`: the Home screen after a profile switch between two adults
/// who share the same media-server access.
@MainActor
struct CheckStartProfileTests {

    /// A source whose "Continue Watching" belongs to the **currently active profile** — like the
    /// states of provider and portal (still-frame ledger per profile) and the channel history.
    final class ProfileSource: ContentSource, @unchecked Sendable {
        nonisolated var displayName: String { "Profil-Doppel" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        private let lock = NSLock()
        private var _calls = 0
        var callCount: Int { lock.withLock { _calls } }

        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }
        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] {
            lock.withLock { _calls += 1 }
            let profile = ProfilePointer.active ?? "geraet"
            return [MediaItem(id: "abc\(profile.count)", kind: .movie, title: "angefangen von \(profile)")]
        }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        enum Missing: Error { case nothing }
    }

    @Test("After switching to another profile, Home shows that profile's Continue Watching")
    func continueWatchingFollowsProfile() async {
        let store = InMemoryStore()
        let source = ProfileSource()
        let model = HomeModel(source: source, store: store, shelfStore: store)

        await ProfilePointer.als("anna") { await model.load() }
        await ProfilePointer.als("benedikt") { await model.load() }

        guard case .ready(_, let shelves) = model.state else {
            Issue.record("not ready: \(model.state)")
            return
        }
        let title = shelves.first { $0.id == ShelfPreferences.resumeID }?.items.map(\.title) ?? []
        #expect(title == ["angefangen von benedikt"], "still there: \(title)")
        #expect(source.callCount == 2)
    }

    @Test("The holder rebuilds Home for another profile")
    func holderBuildsPerProfile() {
        let holder = ShellModels()
        let first = ProfilePointer.als("anna") {
            holder.home(source: nil, provider: nil, portals: nil, channels: nil, anime: nil, rule: .pending)
        }
        let secondOne = ProfilePointer.als("benedikt") {
            holder.home(source: nil, provider: nil, portals: nil, channels: nil, anime: nil, rule: .pending)
        }
        #expect(first !== secondOne)
    }
}
