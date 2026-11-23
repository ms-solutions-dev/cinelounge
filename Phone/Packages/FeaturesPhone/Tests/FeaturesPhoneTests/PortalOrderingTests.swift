import Foundation
import PortalKit
import Testing

@testable import FeaturesPhone

/// Portal levels on the phone: sorted by the CL-Server across all pages (AP60, 2026-09-30).
///
/// **The product condition:** Sorted by rating, no 6 may stand on page 1 before
/// an 8 from page 3. Until AP60 portal levels on the phone stayed unsorted; now
/// the app tells the server what to sort by, and appends its pages.
@Suite("Portal sorting")
@MainActor
struct PortalOrderingTests {

    private static func freshStore() -> UserDefaults {
        UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
    }

    @Test("Tap, reverse, off — and every choice goes to the server, also when loading more")
    func choiceGoesToServer() async {
        let source = SortingPortal()
        let model = PortalsModel(source: source, memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.availableOrders == [.title, .rating])
        #expect(!model.choice.explicit)

        await model.tap(.rating)
        #expect(model.pending?.entries.map(\.id) == ["acht", "sechs"])
        await model.loadMore()

        await model.tap(.rating)
        await model.tap(.rating)
        #expect(!model.choice.explicit)

        let asked = await source.asked
        #expect(
            asked == [
                nil,
                PortalSorting(kind: .rating, descending: true),
                PortalSorting(kind: .rating, descending: true),
                PortalSorting(kind: .rating, descending: false),
                nil,
            ])
        #expect(model.preparedCount == nil)
    }

    @Test("Without ratings only the title is offered as an order")
    func withoutRating() async {
        let source = SortingPortal(hasRatings: false)
        let model = PortalsModel(source: source, memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.availableOrders == [.title])
    }
}

/// A portal that delivers sorted **when asked** — and records what it was asked for.
private actor SortingPortal: PortalContentSource {

    let hasRatings: Bool
    private(set) var asked: [PortalSorting?] = []

    init(hasRatings: Bool = true) { self.hasRatings = hasRatings }

    func portals() async throws -> [PortalInfo] {
        [PortalInfo(id: "ss", name: "Serieshub", state: .ready, capabilities: [])]
    }

    nonisolated func root(zu portal: String) -> String { "\(portal)::" }

    func level(zu identifier: String, title: String, next: String?) async throws -> PortalLayer {
        try await level(zu: identifier, title: title, next: next, sorting: nil, progress: { _ in })
    }

    func level(
        zu identifier: String, title: String, next: String?, sorting: PortalSorting?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PortalLayer {
        asked.append(sorting)
        let hasRatings = hasRatings
        func e(_ id: String) -> PortalEntry {
            PortalEntry(
                id: id, title: id,
                rating: hasRatings
                    ? Rating(origin: Rating.Origin.allCases[0], portion: 0.5, text: "5") : nil)
        }
        if next != nil {
            return PortalLayer(identifier: identifier, title: title, entries: [e("drei")])
        }
        if sorting != nil {
            await progress(900)
            return PortalLayer(
                identifier: identifier, title: title, entries: [e("acht"), e("sechs")], next: "@48")
        }
        return PortalLayer(identifier: identifier, title: title, entries: [e("sechs"), e("acht")])
    }

    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { [] }
}
