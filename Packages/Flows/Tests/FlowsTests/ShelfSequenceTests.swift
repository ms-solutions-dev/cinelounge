import Core
import Flows
import Foundation
import Testing

/// **One board for both programs** (decision 27, C3, C1, C2).
///
/// Both `ShelfPlan` types order through ``ShelfSequence``; the counter-check is to change the
/// board here and see the checks of both programs (`ShelfPlanTests` here and there) go
/// red.
struct ShelfSequenceTests {

    private struct Row: Equatable {
        let id: String
        let kind: Library.Kind?
    }

    @Test("The board: Continue Watching · Collections · Live · Recent · Portals · Catalogs")
    func board() {
        #expect(
            ShelfSequence.board == [.continueWatching, .collections, .live, .recent, .portals, .catalogs])
    }

    @Test("Orders fixed shelves, portal folders and catalogs by the board")
    func orders() {
        let generated = [
            Row(id: "h1", kind: .homeVideos),
            Row(id: "liste|vod|7", kind: .movies),
            Row(id: "f1", kind: .movies),
            Row(id: ShelfIdentifier.portals, kind: .portalLevel),
            Row(id: "animehub|neu|x", kind: .portalLevel),
            Row(id: "s1", kind: .series),
            Row(id: ShelfIdentifier.recent, kind: nil),
            Row(id: ShelfIdentifier.live, kind: nil),
            Row(id: ShelfIdentifier.collections, kind: nil),
            Row(id: ShelfIdentifier.continueWatching, kind: nil),
            Row(id: "x1", kind: .mixed),
        ]
        let episode = ShelfSequence.arrange(generated, identifier: \.id, kind: \.kind).map(\.id)
        #expect(
            episode == [
                ShelfIdentifier.continueWatching, ShelfIdentifier.collections, ShelfIdentifier.live,
                ShelfIdentifier.recent, ShelfIdentifier.portals, "animehub|neu|x",
                "s1", "f1", "x1", "h1", "liste|vod|7",
            ])
    }

    @Test("With equal rank the order of creation stays")
    func stable() {
        let generated = (1...6).map { Row(id: "f\($0)", kind: .movies) }
        #expect(ShelfSequence.arrange(generated, identifier: \.id, kind: \.kind) == generated)
    }

    @Test("Provider categories: the chosen ones, otherwise the first")
    func providerCategories() {
        let all = ["l|vod|1", "l|vod|2", "l|series|3", "l|series|4"]
        #expect(
            HomeLayout.providerCategories(all, identifier: { $0 }, perProvider: 2, chosen: [])
                == ["l|vod|1", "l|vod|2"])
        #expect(
            HomeLayout.providerCategories(all, identifier: { $0 }, perProvider: 0, chosen: []).isEmpty)
        #expect(
            HomeLayout.providerCategories(
                all, identifier: { $0 }, perProvider: 2, chosen: ["l|series|4", "l|vod|2"])
                == ["l|vod|2", "l|series|4"])
    }

    @Test("The collection library is recognized by name, only for a mixed kind")
    func collectionLibrary() {
        let name = AppLanguageSetting.text("home.collections")
        #expect(HomeLayout.isCollectionLibrary(name: name, kind: .mixed))
        #expect(HomeLayout.isCollectionLibrary(name: name.uppercased(), kind: nil))
        #expect(!HomeLayout.isCollectionLibrary(name: name, kind: .movies))
        #expect(!HomeLayout.isCollectionLibrary(name: "Verzeichnisse", kind: .mixed))
    }
}
