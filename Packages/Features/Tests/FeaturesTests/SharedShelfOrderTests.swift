import Core
import Foundation
import Testing

@testable import Features

/// **The same `shelves.json` orders on the TV as on the phone** (AP58 R6, St1).
///
/// The file below is literally the same as in `FeaturesPhoneTests/SharedShelfOrderTests`:
/// an order, half in the phone's old form (`fresh:…`), half in the shared one. Both sides must
/// make the same sequence of it — before R6 the TV did not know the phone's library shelves
/// and appended them at the back.
@MainActor
@Suite("Shared shelf order on the TV")
struct SharedShelfOrderTests {

    static let file = """
        {"reihenfolge":["weiterSchauen","neu:medienserver:movies:f1","animehub||neu","s1","live"],\
        "ausgeblendet":["neu:medienserver:homeVideos:h1"]}
        """

    static let expected = ["resume", "f1", "animehub||neu", "s1", "live"]

    @Test("The shared file orders the TV's shelves")
    func orders() throws {
        let store = FileStore(
            folder: FileManager.default.temporaryDirectory
                .appendingPathComponent("regale-\(UUID().uuidString)"))
        try store.set(Self.file, for: ShelfOrder.key)

        func makeShelf(_ id: String, _ kind: Core.Library.Kind?) -> HomeModel.Shelf {
            HomeModel.Shelf(
                id: id, titleKey: id, items: [], usesWideCards: false, libraryKind: kind)
        }
        let shelfList = [
            makeShelf("resume", nil), makeShelf("live", nil), makeShelf("f1", .movies),
            makeShelf("s1", .series), makeShelf("h1", .homeVideos), makeShelf("animehub||neu", .portalLevel),
        ]
        let ordered = HomeModel.arrange(
            shelfList, by: ShelfPreferences.load(from: store, forItem: nil))
        #expect(ordered.map(\.id) == Self.expected)
    }
}
