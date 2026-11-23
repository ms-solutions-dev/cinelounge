import Core
import Foundation
import PortalKit
import Testing

@testable import FeaturesPhone

/// The title extras on the detail page on the phone.
@Suite("Detail page: title extras")
struct ExtrasSupplementTests {

    private let extras = TitleExtras(
        label: "Studio North", date: "2026-10-11", minutes: 31,
        people: [
            .init(name: "Anna Example", image: URL(string: "https://bild/anna.jpg")),
            .init(name: "Berta Sample", image: nil),
        ],
        description: "A quiet evening.")

    @Test("Gaps are filled")
    func gaps() {
        let t = ExtrasSupplement.completed(
            MediaItem(id: "x", kind: .movie, title: "Finds Her Way Home"), um: extras)

        #expect(t.overview == "A quiet evening.")
        #expect(t.studio == "Studio North")
        #expect(t.year == 2026)
        #expect(t.runtime == TimeInterval(31 * 60))
    }

    @Test("What the list delivers itself stays")
    func doNotOverwrite() {
        let own = MediaItem(
            id: "x", kind: .movie, title: "T", overview: "Own text", year: 2019,
            studio: "Own studio", runtime: 600)

        let t = ExtrasSupplement.completed(own, um: extras)

        #expect(t.overview == "Own text")
        #expect(t.studio == "Own studio")
        #expect(t.year == 2019)
        #expect(t.runtime == TimeInterval(600))
    }

    @Test("The people become the cast, with a face where there is one")
    func cast() {
        let b = ExtrasSupplement.cast(from: extras)

        #expect(b.map(\.name) == ["Anna Example", "Berta Sample"])
        #expect(b.allSatisfy { $0.task == .cast })
        #expect(b[0].image == URL(string: "https://bild/anna.jpg"))
        #expect(b[1].image == nil)
    }
}
