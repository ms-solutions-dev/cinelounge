import Core
import Flows
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit
import Testing

@testable import Features

/// **What the source says arrives on the screen** — AP39, 2026-09-20.
///
/// The finding of 2026-09-19: A rejection by the portal service fell into the last `catch`
/// in the library and detail page and became `error.unreachable` — "No answer. Is the
/// server running?". The server had answered and said exactly what it lacks. The viewer
/// then searches at the router, while two clicks further on the profile selection
/// stands.
@Suite("Declines arrive where they belong")
@MainActor
struct DeclinePathsTests {

    /// A source that gives the same rejection to every question.
    final class Decliner: ContentSource, @unchecked Sendable {
        let error: any Error
        init(_ error: any Error) { self.error = error }

        nonisolated var displayName: String { "Absagende" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double keeps its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }

        func libraries() async throws -> [Core.Library] { throw error }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            throw error
        }
        func item(id: String) async throws -> MediaItem { throw error }
        func children(of itemID: String) async throws -> [MediaItem] { throw error }
        func resumable(limit: Int) async throws -> [MediaItem] { throw error }
        func segments(for itemID: String) async throws -> [MediaSegment] { throw error }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw error
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { throw error }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    private func library(die error: any Error) -> LibraryModel {
        LibraryModel(
            source: Decliner(error),
            library: Core.Library(id: "portal||/beliebt", name: "Beliebt", kind: .portalLevel),
            store: InMemoryStore()
        )
    }

    private func message(from model: LibraryModel) -> String? {
        if case .failed(let key) = model.state { return key }
        return nil
    }

    @Test("A portal without a profile does not ask about the network")
    func profileRequiredInsteadOfUnreachable() async {
        let model = library(
            die: PortalBridge.TestError.cancelled(
                status: 401, code: "auth.profile_required", values: [:]))

        await model.load()

        // Until 2026-09-20 this said `error.unreachable`.
        #expect(message(from: model) == PlaybackPhase.portalProfileRequired.headline)
    }

    @Test("An expired provider login does not lead to the Jellyfin account")
    func providerAccessInsteadOfAccount() async {
        let model = library(die: XtreamClient.Failure.unauthorized)

        await model.load()

        #expect(message(from: model) == PlaybackPhase.xtreamAccessExpired.headline)
    }

    @Test("What truly nobody reaches stays a network error")
    func foreignStaysNetworkError() async {
        struct SomeError: Error {}
        let model = library(die: SomeError())

        await model.load()

        // The origin is the source itself — a stub is neither Jellyfin nor a portal, so
        // `provider`. Without a drop in the player that means `networkXtream`, and there
        // `ErrorSummary` remains the finer tool (see ``DisruptionInterpretation``).
        #expect(message(from: model) != PlaybackPhase.portalProfileRequired.headline)
        #expect(message(from: model) != nil)
    }
}
