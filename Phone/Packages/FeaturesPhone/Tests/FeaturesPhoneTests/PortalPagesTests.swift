import Foundation
import Testing

@testable import FeaturesPhone

/// Paged loading — **the path without which, at the Ahorn, fifteen movies were the whole
/// thing.**
///
/// Measured at the bridge on 2026-09-06: The nine entry points of the Ahorn Mediathek return 2 to 25
/// titles per page and each names a marker; Animehub and Serieshub name none.
@Suite("Portal pages")
@MainActor
struct PortalPagesTests {

    private static func entry(_ identifier: String) -> PortalEntry {
        PortalEntry(id: identifier, title: identifier.uppercased())
    }

    private static func level(
        _ identifiers: [String], next: String? = nil, total: Int? = nil
    )
        -> PortalLayer
    {
        PortalLayer(
            identifier: "ahorn::filme", title: "Filme", entries: identifiers.map(entry),
            total: total, next: next)
    }

    // MARK: - Appending

    @Test("A following page is appended and takes over the new marker")
    func append() {
        let first = Self.level(["a", "b"], next: "2")
        let second = Self.level(["c", "d"], next: "3")
        let combined = first.using(page: second)

        #expect(combined.entries.map(\.id) == ["a", "b", "c", "d"])
        #expect(combined.next == "3")
        #expect(combined.hasMore)
    }

    /// **Duplicates are the normal case and no error** — a reader can repeat an
    /// entry of page 1 on page 2 if something was added in between.
    /// Two equal IDs in a `ForEach` are a drawing error in SwiftUI.
    @Test("An entry that arrives twice appears once")
    func duplicatesDropOut() {
        let first = Self.level(["a", "b"], next: "2")
        let second = Self.level(["b", "c"])
        let combined = first.using(page: second)

        #expect(combined.entries.map(\.id) == ["a", "b", "c"])
        // No marker any more: That was the last page.
        #expect(!combined.hasMore)
    }

    /// Title and ID stay those of the first page — the path keeps pointing to where
    /// one entered.
    @Test("Title and identifier stay those of the first page")
    func pathStaysInPlace() {
        let first = Self.level(["a"], next: "2")
        let second = PortalLayer(
            identifier: "ahorn::filme", title: "Page 2", entries: [Self.entry("b")])
        #expect(first.using(page: second).title == "Filme")
    }

    /// **`total` is adopted where the new page names one, and kept otherwise.**
    /// Turning the absence into a zero would mean writing "0 titles" over visible ones.
    @Test("The total survives a page that does not state one")
    func totalStays() {
        let first = Self.level(["a"], next: "2", total: 40)
        let second = Self.level(["b"])
        #expect(first.using(page: second).total == 40)
    }

    // MARK: - On the model

    @Test("Loading more appends the second page to the open level")
    func modelLoadsMore() async {
        let source = PagedPortal(
            tree: ["ahorn::": [Self.entry("a"), Self.entry("b")]],
            pages: ["ahorn::": [[Self.entry("c")], [Self.entry("d")]]])
        let model = PortalsModel(
            source: source, memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.pending?.entries.count == 2)

        await model.loadMore()
        #expect(model.pending?.entries.map { $0.id } == ["a", "b", "c"])

        await model.loadMore()
        #expect(model.pending?.entries.map { $0.id } == ["a", "b", "c", "d"])
    }

    /// **Without a marker nothing happens** — and that is the case of Animehub and
    /// Serieshub, which deliver everything at once.
    @Test("Without a marker the model does not ask for more")
    func withoutMarkerNoQuery() async {
        let source = PagedPortal(tree: ["ahorn::": [Self.entry("a")]], pages: [:])
        let model = PortalsModel(
            source: source, memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        let previous = await source.fetches

        await model.loadMore()
        #expect(await source.fetches == previous)
        #expect(model.pending?.entries.count == 1)
    }

    /// The view reports the list end several times while it draws. Two fetches for
    /// the same page would be two requests to a foreign site — and the second would append
    /// the same entries once more.
    @Test("At the end of the last page nobody asks further")
    func standstillAtEnd() async {
        let source = PagedPortal(
            tree: ["ahorn::": [Self.entry("a")]], pages: ["ahorn::": [[Self.entry("b")]]])
        let model = PortalsModel(
            source: source, memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        await model.loadMore()
        #expect(model.pending?.hasMore == false)

        let fetches = await source.fetches
        await model.loadMore()
        await model.loadMore()
        #expect(await source.fetches == fetches)
    }

    private static func freshStore() -> UserDefaults {
        UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
    }
}

/// A portal that hands out its entries page by page — **like the Ahorn Mediathek.**
///
/// The marker is the position in ``pages``; what is in it only this portal knows. Exactly
/// as with the real one: There it is a page number that jumps.
private actor PagedPortal: PortalContentSource {

    let tree: [String: [PortalEntry]]
    let pages: [String: [[PortalEntry]]]
    /// How often a level was fetched — so that a test suite can prove the **absence** of a
    /// request and not just an unchanged result.
    private(set) var fetches = 0

    init(tree: [String: [PortalEntry]], pages: [String: [[PortalEntry]]]) {
        self.tree = tree
        self.pages = pages
    }

    func portals() async throws -> [PortalInfo] {
        [PortalInfo(id: "ahorn", name: "Ahorn Mediathek", state: .ready, capabilities: [])]
    }

    nonisolated func root(zu portal: String) -> String { "\(portal)::" }

    func level(zu identifier: String, title: String, next following: String?) async throws -> PortalLayer {
        fetches += 1
        let episodes = pages[identifier] ?? []
        let slot = following.flatMap(Int.init)
        let entries =
            slot.map { episodes.indices.contains($0) ? episodes[$0] : [] } ?? (tree[identifier] ?? [])
        let nextItem = (slot ?? -1) + 1
        return PortalLayer(
            identifier: identifier, title: title, entries: entries,
            next: episodes.indices.contains(nextItem) ? String(nextItem) : nil)
    }

    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { [] }
}
