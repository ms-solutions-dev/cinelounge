import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// The ladder of the head area — **four tiers since 2026-09-06, before that five.**
///
/// The history dropped out as the first tier (direction B to K4, decided by the
/// product owner): it stood at the top **and** directly below in the "Continue Watching" shelf, and the
/// box could not carry what it delivered — a ``HistoryEntry`` carries six
/// fields, the box needs logo, attributes and rating. The reasoning in full is
/// at ``HeroLadder``.
@Suite("Hero ladder")
struct HeroLadderTests {

    private func makeHero(_ name: String) -> HeroContent {
        HeroContent(tile: TileContent(id: name, title: name))
    }

    private func entry(
        _ name: String, _ origin: Catalog.Origin, withImage: Bool = true,
        forward seconds: TimeInterval = 0
    ) -> HistoryEntry {
        HistoryEntry(
            identifier: name, origin: origin, title: name,
            backdrop: withImage ? URL(string: "https://example.invalid/\(name).jpg") : nil,
            timestamp: Date(timeIntervalSince1970: 2_000_000_000 - seconds))
    }

    /// Tier 1 — the media server, mixed from the most recently added.
    @Test("What the sources brought along comes first")
    func loadedTitles() {
        let tier = HeroLadder.tier(
            loaded: [makeHero("Film")], state: .fromAccesses(jellyfin: true))
        #expect(tier == .title([makeHero("Film")]))
    }

    /// **The history no longer stands at the top, even if it exists.** It fills the shelf
    /// below; the ladder has not known it at all since 2026-09-06.
    @Test("The history no longer displaces the Jellyfin source")
    func historyNoLongerOnTop() {
        let tier = HeroLadder.tier(
            loaded: [makeHero("Film")],
            state: .fromAccesses(jellyfin: true, channelList: true))
        #expect(tier == .title([makeHero("Film")]))
    }

    /// Tier 2 — the provider catalog, but **only on request.**
    @Test("The top-up applies only when nothing else is there")
    func lookup() {
        #expect(HeroLadder.needsTopUp([]))
        #expect(!HeroLadder.needsTopUp([makeHero("Film")]))

        let tier = HeroLadder.tier(
            loaded: [], lookup: [makeHero("Anbieter")],
            state: .fromAccesses(provider: true))
        #expect(tier == .title([makeHero("Anbieter")]))
    }

    /// **Tier 3: other content, same place, same job.** Whoever has set up only a
    /// channel list gets no picture box but the running
    /// programme.
    @Test("A channel list alone yields \"Now on air\"")
    func nowOnAir() {
        let tier = HeroLadder.tier(loaded: [], state: .fromAccesses(channelList: true))
        #expect(tier == .nowOnAir)
    }

    /// Tier 4 — the state of a freshly loaded device.
    @Test("With nothing at all the setup prompt remains")
    func setUp() {
        #expect(HeroLadder.tier(loaded: [], state: .empty) == .setUp)
    }

    /// **The flip side of the decision, and it stands here as a test suite:** whoever has set up only
    /// portals gets nothing at the top any more. Before, the history tier caught that.
    @Test("Portals alone no longer yield a box")
    func portalsOnly() {
        #expect(HeroLadder.tier(loaded: [], state: .fromAccesses(portals: true)) == .setUp)
    }

    // MARK: - The shelf below

    /// Without timestamps everything stays as it was — no empty shelf, no reordering.
    @Test("Without timestamps the row stays as it is")
    func withoutTimestamps() {
        let available: [Shelf.Identifier: [TileContent]] = [
            .fixed("resume"): [
                TileContent(id: "film", title: "Film"), TileContent(id: "serie", title: "Serie"),
            ]
        ]
        #expect(StartModel.ordered(available) == available)
    }
}
