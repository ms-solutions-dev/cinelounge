import Foundation
import Testing

@testable import Core

/// The duration of a series is calculated, not read — the server's field
/// for it is unusable. All the more important that the calculation is right.
@Suite("Duration and remaining time")
struct WatchEstimateTests {

    private func series(
        episodes: Int?,
        runtime: TimeInterval?,
        unplayed: Int? = nil
    ) -> MediaItem {
        MediaItem(
            id: "s",
            kind: .series,
            title: "Serie",
            runtime: runtime,
            episodeCount: episodes,
            unplayedCount: unplayed
        )
    }

    @Test("The total duration is runtime times episode count")
    func totalIsRuntimeTimesEpisodes() throws {
        // 41 episodes of 24 minutes — the real values of Hollowmark. The server reports
        // 0.4 hours for it, which is the runtime of a single episode; that is why it
        // is calculated.
        let estimate = try #require(
            WatchEstimate.forSeries(series(episodes: 41, runtime: 24 * 60)))

        #expect(estimate.total == 41 * 24 * 60)
        #expect(Int(estimate.total / 3600) == 16, "just over 16 hours")
    }

    @Test("The remaining time follows the unplayed episodes")
    func remainingFollowsUnplayed() throws {
        // 36 of 41 still open — the state from the real library.
        let estimate = try #require(
            WatchEstimate.forSeries(series(episodes: 41, runtime: 24 * 60, unplayed: 36)))

        #expect(estimate.remaining == 36 * 24 * 60)
        #expect(estimate.remaining < estimate.total)
        #expect(abs(estimate.watchedFraction - 5.0 / 41.0) < 0.001)
    }

    @Test("Without watch info, nothing counts as watched")
    func unknownProgressAssumesNothingWatched() throws {
        // The cautious assumption. It shows too much remaining time rather than too little —
        // a figure that is too low would be the more unpleasant surprise.
        let estimate = try #require(
            WatchEstimate.forSeries(series(episodes: 10, runtime: 1200)))

        #expect(estimate.remaining == estimate.total)
        #expect(estimate.watchedFraction == 0)
    }

    @Test("Without a basis nothing is claimed")
    func missingDataYieldsNothing() {
        // Better to show nothing than a zero that looks like a statement.
        #expect(WatchEstimate.forSeries(series(episodes: nil, runtime: 1200)) == nil)
        #expect(WatchEstimate.forSeries(series(episodes: 10, runtime: nil)) == nil)
        #expect(WatchEstimate.forSeries(series(episodes: 0, runtime: 1200)) == nil)
        #expect(WatchEstimate.forSeries(series(episodes: 10, runtime: 0)) == nil)
    }

    @Test("More unplayed episodes than exist yield no excess length")
    func unplayedIsClamped() throws {
        // Happens when the server is still counting or episodes have disappeared.
        // Unchecked, more remaining time would then be shown than the series lasts at all.
        let estimate = try #require(
            WatchEstimate.forSeries(series(episodes: 10, runtime: 600, unplayed: 25)))

        #expect(estimate.remaining == estimate.total)
        #expect(estimate.watchedFraction == 0)
    }

    @Test("For a movie, its runtime and its own progress count")
    func singleUsesItsOwnProgress() throws {
        let film = MediaItem(
            id: "f",
            kind: .movie,
            title: "Film",
            runtime: 7200,
            progress: PlaybackProgress(position: 1800, duration: 7200)
        )

        let estimate = try #require(WatchEstimate.forSingle(film))

        #expect(estimate.total == 7200)
        #expect(abs(estimate.remaining - 5400) < 1, "a quarter of an hour watched")
        #expect(abs(estimate.watchedFraction - 0.25) < 0.001)
    }

    @Test("Under one minute remaining counts as done")
    func almostDoneCountsAsDone() {
        // Otherwise "0 min left" would appear, which looks like an error.
        let nearly = WatchEstimate(total: 3600, remaining: 30, watchedFraction: 0.99)
        let open = WatchEstimate(total: 3600, remaining: 600, watchedFraction: 0.83)

        #expect(!nearly.hasRemaining)
        #expect(open.hasRemaining)
    }

    @Test("Rounding goes to half hours")
    func roundsToHalfHours() {
        // The number is an estimate, and that should be visible. "14 h 23 min"
        // would claim a precision that does not exist.
        #expect(WatchEstimate.roundedToHalfHours(3500) == 3600, "58 min → 1 h")
        #expect(WatchEstimate.roundedToHalfHours(4500) == 5400, "1:15 → 1:30")
        #expect(WatchEstimate.roundedToHalfHours(600) == 600, "10 min stay 10 min")
        #expect(WatchEstimate.roundedToHalfHours(700) == 900, "11:40 → 15 min, rounded up")
        #expect(WatchEstimate.roundedToHalfHours(1790) == 1800, "29:50 → 30 min")
        #expect(WatchEstimate.roundedToHalfHours(0) == 0)
        #expect(WatchEstimate.roundedToHalfHours(59_000) == 59_400, "16:23 → 16:30")
    }

    @Test("The choice depends on the kind of title")
    func picksByKind() {
        // For a series the runtime holds the duration of *one* episode, for a
        // movie its entire length. The same number, two meanings — if one confuses
        // them, a 40-episode series is two hours long.
        let asSeries = WatchEstimate.of(series(episodes: 10, runtime: 600))
        #expect(asSeries?.total == 6000)

        let asFilm = WatchEstimate.of(
            MediaItem(id: "f", kind: .movie, title: "F", runtime: 600, episodeCount: 10))
        #expect(asFilm?.total == 600)
    }

    @Test("A remaining time of ten minutes does not read as 0 min")
    func shortRemainingTime() throws {
        var series = MediaItem(id: "s", kind: .series, title: "Kinderserie")
        series.episodeCount = 10
        series.unplayedCount = 1
        series.runtime = 600
        let estimate = try #require(WatchEstimate.of(series))
        #expect(estimate.hasRemaining)
        #expect(WatchEstimate.durationText(estimate.remaining, roundedValue: true) == "10 min")
        var short = MediaItem(id: "k", kind: .series, title: "Kurz")
        short.episodeCount = 2
        short.unplayedCount = 2
        short.runtime = 300
        let both = try #require(WatchEstimate.of(short))
        #expect(WatchEstimate.durationText(both.total, roundedValue: true) == "10 min")
    }
}
