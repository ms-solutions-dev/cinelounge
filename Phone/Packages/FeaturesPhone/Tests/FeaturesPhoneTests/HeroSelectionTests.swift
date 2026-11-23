import Core
import Flows
import Testing

@testable import FeaturesPhone

/// Who appears big at the top — four rules, each with a reason.
///
/// **One rule was dropped on 2026-09-06** (direction B to K4): "First the most recently
/// started." It thus stood at the top **and** as the first tile in the "Continue Watching" shelf
/// directly below — the same question twice on one screen.
@Suite("Hero selection")
struct HeroSelectionTests {

    private func title(
        _ identifier: String, kind: MediaItem.Kind = .movie, backdrop: Bool = true,
        series: String? = nil
    ) -> MediaItem {
        var entry = MediaItem(id: identifier, kind: kind, title: identifier)
        entry.seriesID = series
        if backdrop { entry.artwork.backdropID = identifier }
        return entry
    }

    /// **The library's order stays when nothing is shuffled.** The box shuffles
    /// in operation; for the check the fixed order is the verifiable one.
    @Test("Without shuffling the first title comes first")
    func orderStays() {
        let chosen = HeroSelection.select(
            library: [title("a"), title("b")], shuffle: false)
        #expect(chosen.map(\.id) == ["a", "b"])
    }

    /// The box is ninety percent picture; without one an empty area would remain, and
    /// when paging it would look like a loading error.
    @Test("No hero without a backdrop")
    func withoutImage() {
        let chosen = HeroSelection.select(
            library: [title("ohne", backdrop: false), title("mit")],
            shuffle: false)
        #expect(chosen.map(\.id) == ["mit"])
    }

    /// Whoever sets up personal recordings as a movie library does not want them big on the
    /// Home screen.
    @Test("Home videos are left out")
    func noHomeVideos() {
        let chosen = HeroSelection.select(
            library: [title("urlaub", kind: .homeVideo), title("film")],
            shuffle: false)
        #expect(chosen.map(\.id) == ["film"])
    }

    /// Two episodes of the same series count as one title here — otherwise the box pages
    /// between two almost identical pictures.
    @Test("A series counts once")
    func seriesOnlyOnce() {
        let chosen = HeroSelection.select(
            library: [
                title("f1", kind: .episode, series: "s"),
                title("f2", kind: .episode, series: "s"),
                title("f3", kind: .episode, series: "s"),
            ],
            shuffle: false)
        #expect(chosen.count == 1)
    }

    @Test("At most eight")
    func upperLimit() {
        let many = (1...20).map { title("t\($0)") }
        #expect(HeroSelection.select(library: many).count == 8)
    }

    @Test("No hero without a catalog")
    func empty() {
        #expect(HeroSelection.select(library: []).isEmpty)
    }

    /// **Decision 25 (2026-09-26): the same choice as on the TV.** A started
    /// title stands where its library has it — `HomeModelTests.likeOnPhone` demands the
    /// same on the TV against the same rule.
    @Test("As on the TV: nothing started comes first")
    func asOnTV() {
        var half = title("b")
        half.progress = PlaybackProgress(position: 600, duration: 3600)
        let catalog = [title("a"), half, title("c")]
        let chosen = HeroSelection.select(library: catalog, shuffle: false)
        #expect(chosen.map(\.id) == ["a", "b", "c"])
        #expect(chosen == HomeLayout.heroes(libraries: [catalog], shuffle: false))
    }
}
