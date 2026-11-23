import Core
import Foundation
import Testing

@testable import PlaylistKit

/// "Continue Watching" for foreign libraries — AP39, 2026-09-20.
///
/// **The bug was silent and two levels deep:** the memory wrote dutifully into `vod.memory.v1`
/// on every reported position, and ``XtreamVODSource/resumable(limit:)``
/// returned an empty list alongside. Nobody threw, nobody reported; the Home screen
/// simply had no shelf for a provider with 27.558 films.
@Suite("The Xtream state appears in Continue Watching")
struct VODContinueWatchingTests {

    private func item(
        _ id: String, _ title: String, kind: MediaItem.Kind = .movie, image: String? = "http://p/1.jpg"
    ) -> MediaItem {
        MediaItem(id: id, kind: kind, title: title, artwork: Artwork(posterID: image))
    }

    @Test("A started title appears with title and image in the list")
    func startedTitleAppears() async {
        let memory = VODMemory(store: InMemoryStore())

        // That is how it runs in production: the title comes from a list through `enrich`,
        // and only then is a position reported.
        await memory.setPosition(300, of: 5400, for: "film:42")
        _ = await memory.enrich([item("film:42", "Fair Wind Calling")])

        let list = await memory.resumable(limit: 12)

        #expect(list.count == 1)
        #expect(list.first?.title == "Fair Wind Calling")
        // Without a picture the tile is a black surface — the profile is the purpose.
        #expect(list.first?.artwork.posterID == "http://p/1.jpg")
        #expect(list.first?.progress?.position == 300)
    }

    @Test("A watched title does not appear in Continue Watching")
    func watchedDropsOut() async {
        let memory = VODMemory(store: InMemoryStore())
        await memory.setPosition(300, of: 5400, for: "film:42")
        _ = await memory.enrich([item("film:42", "Fair Wind Calling")])
        await memory.setWatched(true, for: "film:42")

        #expect(await memory.resumable(limit: 12).isEmpty)
    }

    @Test("The most recently touched title is first")
    func newestFirst() async {
        let memory = VODMemory(store: InMemoryStore())

        await memory.setPosition(300, of: 5400, for: "film:1")
        _ = await memory.enrich([item("film:1", "Der erste")])
        // `Date()` in the same millisecond would say nothing; the store writes
        // the time itself, so here positions really are reported one after another.
        try? await Task.sleep(for: .milliseconds(10))
        await memory.setPosition(120, of: 3600, for: "film:2")
        _ = await memory.enrich([item("film:2", "Der zweite")])

        #expect(await memory.resumable(limit: 12).map(\.title) == ["Der zweite", "Der erste"])
    }

    @Test("Whoever has no state gets no entry")
    func enrichCreatesNothing() async {
        let memory = VODMemory(store: InMemoryStore())

        // A list with 27.558 films runs through here. If `enrich` created an entry per title,
        // the store would be unusable after a single scroll.
        _ = await memory.enrich([item("film:1", "Ein Film"), item("film:2", "Noch einer")])

        #expect(await memory.resumable(limit: 12).isEmpty)
        #expect(await memory.resumableWithoutProfile(limit: 12).isEmpty)
    }

    @Test("The old catalog without a profile is reported as an identifier")
    func legacyCatalogIsReported() async {
        let memory = VODMemory(store: InMemoryStore())

        // Remembered before 2026-09-20: a position, nothing else. The source resolves these
        // IDs one by one instead of dropping them.
        await memory.setPosition(300, of: 5400, for: "film:alt")

        #expect(await memory.resumable(limit: 12).isEmpty)
        #expect(await memory.resumableWithoutProfile(limit: 12) == ["film:alt"])
    }

    @Test("The profile survives a restart")
    func profileSheetSurvives() async {
        let store = InMemoryStore()

        let first = VODMemory(store: store)
        await first.setPosition(300, of: 5400, for: "film:42")
        _ = await first.enrich([item("film:42", "Fair Wind Calling")])

        // The same store, a new memory — as at the next start of the app.
        let second = VODMemory(store: store)
        #expect(await second.resumable(limit: 12).map(\.title) == ["Fair Wind Calling"])
    }

    // MARK: - The way through the wrapper

    /// **Since AP42 the path goes through ``StateSource``** (2026-09-21). The source itself
    /// no longer keeps any state — an Xtream panel knows none, and whom it belongs to is
    /// a question for the person and not for the provider.
    @MainActor
    private func wrapper(_ ledger: InMemoryStore) -> ProviderSource {
        let listen = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        return ProviderSource(XtreamVODSource(store: listen), ledger: ledger)
    }

    @Test("The wrapper hands out the state — and asks nobody for it")
    @MainActor
    func wrapperReturnsTheState() async throws {
        // Exactly the line that until 2026-09-20 hard-returned `[]`. The store of the
        // lists is empty, so there is no provider that could be asked —
        // if a title comes out here, it came from the position ledger.
        let ledger = InMemoryStore()
        let memory = VODMemory(store: ledger)
        await memory.setPosition(300, of: 5400, for: "film:42")
        _ = await memory.enrich([item("film:42", "Fair Wind Calling")])

        #expect(try await wrapper(ledger).resumable(limit: 12).map(\.title) == ["Fair Wind Calling"])
    }

    /// **The counter-check to the wrapper**: without it there is no state, and that should be visible.
    @Test("The bare source keeps no state")
    @MainActor
    func bareSourceWithoutState() async throws {
        let ledger = InMemoryStore()
        await VODMemory(store: ledger).setPosition(300, of: 5400, for: "film:42")

        let listen = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        #expect(try await XtreamVODSource(store: listen).resumable(limit: 12).isEmpty)
    }

    @Test("Old catalog that no provider resolves anymore drops out silently")
    @MainActor
    func legacyCatalogWithoutProviderDoesNotThrow() async throws {
        let ledger = InMemoryStore()
        await VODMemory(store: ledger).setPosition(300, of: 5400, for: "film:alt")

        // A failure here would take the whole shelf from the Home screen — also the
        // titles that can be resolved.
        #expect(try await wrapper(ledger).resumable(limit: 12).isEmpty)
    }
}
