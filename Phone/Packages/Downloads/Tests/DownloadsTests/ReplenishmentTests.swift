import Foundation
import Testing

@testable import Downloads

/// The standing order — **three episodes ready, and no fourth.**
@Suite("Replenishment")
struct ReplenishmentTests {

    /// Six episodes, of which the first `seen` have been watched.
    private func series(seen: Int, from number: Int = 6) -> [Replenishment.Episode] {
        (1...number).map { .init(identifier: "f\($0)", seen: $0 <= seen) }
    }

    /// **The gap comes first and not the number.** Whoever has nothing gets three.
    @Test("Without downloads the first three unwatched are fetched")
    func firstRun() {
        let plan = Replenishment.plan(episodes: series(seen: 0), inDownloads: [])
        #expect(plan.fetch == ["f1", "f2", "f3"])
        #expect(plan.discard.isEmpty)
    }

    /// **The order is that of the series.** What is watched next is the
    /// next episode — not the shortest and not the smallest.
    @Test("Watched episodes at the start shift the window")
    func windowMoves() {
        let plan = Replenishment.plan(episodes: series(seen: 2), inDownloads: [])
        #expect(plan.fetch == ["f3", "f4", "f5"])
    }

    /// **Only the gap is fetched.** Whoever calculated "three minus the watched" would fetch
    /// three episodes again after every evening.
    @Test("If three unwatched already lie there, nothing is fetched")
    func nothingToDo() {
        let plan = Replenishment.plan(
            episodes: series(seen: 0), inDownloads: ["f1", "f2", "f3"])
        #expect(plan.fetch.isEmpty)
        #expect(plan.discard.isEmpty)
        #expect(plan.empty)
    }

    /// A watched episode makes room, and the room is filled again immediately — **both
    /// in one plan**, because it is one decision.
    @Test("A watched episode is dropped and replaced")
    func discardAndFetch() {
        let plan = Replenishment.plan(
            episodes: series(seen: 1), inDownloads: ["f1", "f2", "f3"])
        #expect(plan.discard == ["f1"])
        #expect(plan.fetch == ["f4"])
    }

    /// **Only what is here gets thrown out.** Proposing a watched episode that was never fetched
    /// for throwing out would be the announcement of freeing room that does not exist.
    @Test("A watched episode without a file is not thrown out")
    func onlyWhatIsStored() {
        let plan = Replenishment.plan(episodes: series(seen: 3), inDownloads: ["f4"])
        #expect(plan.discard.isEmpty)
        #expect(plan.fetch == ["f5", "f6"])
    }

    /// **At the end of the series the gap stays open**, and that is right: there is nothing
    /// left to fetch. A plan that started over from the beginning here would fetch what was already watched.
    @Test("At the end of the series it does not fetch from the start again")
    func seriesEnd() {
        let plan = Replenishment.plan(episodes: series(seen: 5), inDownloads: ["f5"])
        #expect(plan.fetch == ["f6"])
        #expect(plan.discard == ["f5"])
    }

    @Test("A fully watched series replenishes nothing more")
    func watchedIDs() {
        let plan = Replenishment.plan(episodes: series(seen: 6), inDownloads: ["f6"])
        #expect(plan.fetch.isEmpty)
        #expect(plan.discard == ["f6"])
    }
}
