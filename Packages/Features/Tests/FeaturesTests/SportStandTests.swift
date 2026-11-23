import Core
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// What the schedule must be able to say about itself.
///
/// **The finding of 2026-08-29:** "Currently only one entry is shown for today
/// there." It could not be cleared up — the only diagnostic line hung behind
/// the debug switch and derived its verdict "downloads empty or carrying" from the
/// number of **results**, that is, from what was left
/// after all filters. An empty downloads store and a filter that eats everything looked
/// the same. The same mix-up had already cost half a
/// day on 2026-08-16.
///
/// What is tested is therefore the **distinction**, not the view.
@MainActor
@Suite("The schedule says what the cause is")
struct SportStateTests {

    private func downloads(
        broadcasts: Int = 30_157, inWindow: Int = 4_211, fetchedAgo hours: Double? = 3
    ) -> LiveLibrary.DownloadsState {
        LiveLibrary.DownloadsState(
            broadcasts: broadcasts,
            inWindow: inWindow,
            oldest: Date(timeIntervalSince1970: 1_756_000_000),
            newest: Date(timeIntervalSince1970: 1_756_200_000),
            lastFetched: hours.map { Date().addingTimeInterval(-$0 * 3600) }
        )
    }

    @Test("An empty store blames the store")
    func emptyBacklog() {
        let state = downloads(broadcasts: 0, inWindow: 0)

        #expect(SportModel.state(downloads: state, sportsEvents: 0, inWindow: 0) == .noGuide)
    }

    /// The case that looked like "no downloads" until 2026-08-29: the provider EPG
    /// reaches, measured, about +24 h, and whoever pages to the day after tomorrow
    /// has a full downloads store and still nothing in the window.
    @Test("A store without this day is not an empty store")
    func fullButWrongDay() {
        let state = downloads(inWindow: 0)

        #expect(SportModel.state(downloads: state, sportsEvents: 0, inWindow: 0) == .noWindow)
    }

    /// **The statement at stake.** Broadcasts in the window but no
    /// live sport among them — that blames the filter and not the downloads.
    @Test("Broadcasts without sport blame the filter")
    func filterEatsEverything() {
        let state = downloads()

        #expect(SportModel.state(downloads: state, sportsEvents: 0, inWindow: 0) == .noSport)
    }

    /// The reverse case belongs there too: sports events found in the
    /// look-back, but none begins today. For the viewer that is the same
    /// — for the diagnosis the number stands beside it.
    @Test("Events without a single one today count as without sport")
    func nothingToday() {
        let state = downloads()

        #expect(SportModel.state(downloads: state, sportsEvents: 94, inWindow: 0) == .noSport)
    }

    @Test("With events the schedule is ready")
    func ready() {
        let state = downloads()

        #expect(SportModel.state(downloads: state, sportsEvents: 94, inWindow: 54) == .ready)
    }

    /// The status line in the header. It is the reason why an old downloads store is
    /// noticed on the TV at all.
    @Test("The age of the programme guide is named, even if there is none")
    func alter() {
        #expect(SportModel.alter(nil) == "nie geholt")
        #expect(SportModel.alter(Date().addingTimeInterval(-600)).contains("weniger"))
        #expect(SportModel.alter(Date().addingTimeInterval(-3 * 3600)) == "vor 3 h")
        #expect(SportModel.alter(Date().addingTimeInterval(-72 * 3600)) == "vor 3 Tagen")
    }

    @Test("The span of an empty store claims no times")
    func spanEmpty() {
        let emptyState = LiveLibrary.DownloadsState(
            broadcasts: 0, inWindow: 0, oldest: nil, newest: nil, lastFetched: nil)

        #expect(SportModel.stockSpan(emptyState) == "leer")
        #expect(SportModel.stockSpan(downloads()).contains("–"))
    }
}
