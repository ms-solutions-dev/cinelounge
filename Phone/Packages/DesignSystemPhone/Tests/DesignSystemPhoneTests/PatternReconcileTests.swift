import Core
import Testing

@testable import DesignSystemPhone

/// **Both programs read the same choice** — AP40, 2026-09-20.
///
/// Until then the color theme was called `app.theme` here with
/// `cinema`/`mitternacht`/`contrast` and on the TV `appearance.theme` with
/// `cinema`/`midnight`/`contrast`. Nobody saw that as long as no setting traveled between the
/// devices — and that is exactly what one does since the handoff: the bundle carries the
/// color theme as a string and thereby sent a word the other side does not know.
///
/// **That is why this series tests crosswise** and not the same thing twice: it writes with
/// one program and reads with the reader of the other. A test that only queries its own side
/// would be green again at the next rename.
@Suite("The color pattern carries the same name on both sides")
struct PatternReconcileTests {

    @Test("What the phone stores, the TV reads as the same pattern")
    func tvReadsPhoneChoice() throws {
        for board in ColorBoard.all(forItem: .phone) {
            let store = InMemoryStore()
            try store.set(board.id, for: ColorBoard.storeKey)

            #expect(
                Theme.load(from: store).id == board.id,
                """
                The TV reads "\(board.id)" as "\(Theme.load(from: store).id)". \
                Either the key is named differently or the identifier — both silently turn \
                a transferred setting into the default.
                """
            )
        }
    }

    @Test("What the TV stores, the phone finds again")
    func phoneReadsTVChoice() throws {
        for theme in Theme.all {
            let store = InMemoryStore()
            theme.save(to: store)

            let stored = try store.value(for: ColorBoard.storeKey)
            #expect(ColorBoard.zu(id: stored, forItem: .phone)?.id == theme.id)
        }
    }

    @Test("A choice from before 20.09.2026 is translated, no other is touched")
    func oldIdentifiersMigrate() {
        #expect(ColorBoard.newIdentifier(forItem: "kino") == "cinema")
        #expect(ColorBoard.newIdentifier(forItem: "mitternacht") == "midnight")
        #expect(ColorBoard.newIdentifier(forItem: "kontrast") == "contrast")

        // An unknown identifier can come from a newer version; passing it through unchanged is more
        // correct than forcing it to "Cinema".
        #expect(ColorBoard.newIdentifier(forItem: "somethingNew") == "somethingNew")
    }
}
