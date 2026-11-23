import Testing

@testable import Features

/// **The walkable card** — AP46, product decision 6 of 2026-09-24.
///
/// Its core problem was in the roadmap before it was built: When the focus goes into the
/// card, the row loses it and reports nothing any more. Without holding on, the card
/// would vanish under the focus; without catching up, it would show the old one after a
/// choice.
@Suite("The walkable map")
struct WalkableMapTests {

    static func spec(chosen: String) -> CardSpec {
        CardSpec(
            header: "kopf", statementWording: chosen,
            pills: ["resume", "favorites", "latest", "off"].map {
                CardPill($0, chosen: $0 == chosen, identifier: $0)
            },
            optionCount: 4, validity: .device,
            selection: CardSelection(row: "topshelf") { _ in })
    }

    /// **The focus is in the card, the row reports nothing** — the card stays.
    @Test("Inside the map the pinned one carries")
    func pinned() {
        let old = Self.spec(chosen: "resume")
        #expect(SettingsView.displayedCard(reported: nil, pinned: old, focusInCard: true) == old)
    }

    /// **Outside, what is reported applies**, also `nil` — otherwise an old card would hang
    /// next to a row that has none.
    @Test("Outside the map the report applies, even if empty")
    func outside() {
        let old = Self.spec(chosen: "resume")
        #expect(SettingsView.displayedCard(reported: nil, pinned: old, focusInCard: false) == nil)
        let fresh = Self.spec(chosen: "latest")
        #expect(SettingsView.displayedCard(reported: fresh, pinned: old, focusInCard: true) == fresh)
    }

    @Test("Focus in the map is recognizable by the prefix")
    func prefix() {
        #expect(SettingsView.isInCard(SettingsCard.focusPrefix + "latest"))
        #expect(!SettingsView.isInCard("topshelf"))
        #expect(!SettingsView.isInCard(nil))
    }

    /// **The card catches up with the choice itself** — the row cannot, it has handed the
    /// focus off.
    @Test("After a choice it stands filled and as a statement")
    func migrated() {
        let fresh = Self.spec(chosen: "resume").withSelection("favorites")
        #expect(fresh.pills.filter(\.chosen).map(\.identifier) == ["favorites"])
        #expect(fresh.statementWording == "favorites")
    }

    /// An unknown identifier changes nothing — better the old choice than none filled in.
    @Test("An unknown choice changes nothing")
    func unknown() {
        let old = Self.spec(chosen: "resume")
        #expect(old.withSelection("gibtEsNicht") == old)
    }
}
