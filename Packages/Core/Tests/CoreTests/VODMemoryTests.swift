import Testing

@testable import Core

/// **Memory here is the navigation, not a comfort on top**
/// (user decision 2026-08-22): with 27,558 movies it is not a clever
/// start view that decides whether the section is usable, but whether one gets
/// back out where one stopped.
/// **One after another, not side by side:** all checks here swap the same
/// global store. Run in parallel they overwrite one another in the middle of a
/// run — that reliably ended in a crash, not in a failure.
@Suite("Where the user last was in movies & series", .serialized)
struct VODMemoryTests {

    private func fresh() -> KeyValueStore {
        let store = InMemoryStore()
        VODMemory.store = store
        return store
    }

    /// Without an entry, movies applies — every provider has them, not every provider has series.
    @Test("Without an entry, movies applies")
    func defaultsToMovies() {
        _ = fresh()
        #expect(VODMemory.kind(forProvider: "a") == .movies)
        #expect(VODMemory.category(forProvider: "a", kind: .movies) == nil)
    }

    /// **Separate per list.** Two providers have their own categories; a
    /// shared bookmark slot would point at a category of the first one for the second.
    @Test("Two lists remember separately")
    func providersAreSeparate() {
        _ = fresh()
        VODMemory.setCategory("a|vod|1", forProvider: "a", kind: .movies)
        VODMemory.setCategory("b|vod|9", forProvider: "b", kind: .movies)

        #expect(VODMemory.category(forProvider: "a", kind: .movies) == "a|vod|1")
        #expect(VODMemory.category(forProvider: "b", kind: .movies) == "b|vod|9")
    }

    /// **Separate per kind, and that is the more important case.** Xtream keeps separate
    /// number ranges for movies and series — the same identifier means a different category in
    /// the other kind. A shared bookmark slot would point after switching
    /// to something that does not exist there, and the grid would stay empty.
    @Test("Movies and series remember separately")
    func kindsAreSeparate() {
        _ = fresh()
        VODMemory.setCategory("a|vod|427", forProvider: "a", kind: .movies)
        VODMemory.setCategory("a|series|427", forProvider: "a", kind: .series)

        #expect(VODMemory.category(forProvider: "a", kind: .movies) == "a|vod|427")
        #expect(VODMemory.category(forProvider: "a", kind: .series) == "a|series|427")
    }

    /// The kind itself is also remembered: whoever last watched series comes back in at
    /// series.
    @Test("The most recently seen kind comes back")
    func kindIsRemembered() {
        _ = fresh()
        VODMemory.setKind(.series, forProvider: "a")
        #expect(VODMemory.kind(forProvider: "a") == .series)
        #expect(VODMemory.kind(forProvider: "b") == .movies, "and only for this list")
    }

    /// When an account is deleted nothing may stay behind that later points to a
    /// category that no longer exists.
    @Test("Forgetting clears both kinds")
    func forgettingClearsBoth() {
        _ = fresh()
        VODMemory.setKind(.series, forProvider: "a")
        VODMemory.setCategory("a|vod|1", forProvider: "a", kind: .movies)
        VODMemory.setCategory("a|series|2", forProvider: "a", kind: .series)

        VODMemory.forget(provider: "a")

        #expect(VODMemory.kind(forProvider: "a") == .movies)
        #expect(VODMemory.category(forProvider: "a", kind: .movies) == nil)
        #expect(VODMemory.category(forProvider: "a", kind: .series) == nil)
    }
}
