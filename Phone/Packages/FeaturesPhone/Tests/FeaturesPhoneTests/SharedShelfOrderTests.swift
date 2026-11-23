import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **The same `shelves.json` orders on the phone as on the TV** (AP58 R6, St1).
///
/// The file is literally the same as in `FeaturesTests/SharedShelfOrderTests`. The
/// shelves arise here via ``Shelf/Identifier/zu(_:)`` from catalog identifiers — exactly the
/// path on which the phone produced `fresh:…` until R6.
@Suite("Shared shelf order on the phone")
struct SharedShelfOrderTests {

    static let file = """
        {"reihenfolge":["weiterSchauen","neu:medienserver:movies:f1","animehub||neu","s1","live"],\
        "ausgeblendet":["neu:medienserver:homeVideos:h1"]}
        """

    static let expected = ["resume", "f1", "animehub||neu", "s1", "live"]

    @Test("The shared file orders the phone's shelves")
    func orders() throws {
        let store = FileStore(
            folder: FileManager.default.temporaryDirectory
                .appendingPathComponent("shelves-\(UUID().uuidString)"))
        try store.set(Self.file, for: ShelfOrder.key)

        func fixed(_ id: String) -> Shelf {
            Shelf(id: .fixed(id), label: .wording(id), sources: [.jellyfin])
        }
        func catalog(_ origin: Catalog.Origin, _ kind: Genre, _ raw: String) -> Shelf {
            Shelf(
                id: .zu(.init(origin, kind, raw)), label: .wording(raw),
                sources: [origin])
        }
        let shelves = [
            fixed("resume"), fixed("live"), catalog(.jellyfin, .movies, "f1"),
            catalog(.jellyfin, .allSeries, "s1"), catalog(.jellyfin, .homeVideos, "h1"),
            catalog(.portals, .portalLevel, "animehub||neu"),
        ]
        let ordered = StartPreferences.load(from: store, forItem: nil).arrange(shelves)
        #expect(ordered.map(\.id.rawValue) == Self.expected)
    }

    /// A catalog shelf is named like the library on the TV.
    @Test("A catalog shelf carries the source's identifier")
    func identifier() {
        #expect(Shelf.Identifier.zu(.init(.jellyfin, .movies, "a1b2")).rawValue == "a1b2")
        #expect(Shelf.Identifier(stored: "neu:medienserver:movies:a1b2").rawValue == "a1b2")
    }
}
