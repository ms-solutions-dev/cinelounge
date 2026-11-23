import Core
import Foundation
import Testing

@testable import Flows

/// **The window, and what it costs** (AP14, 2026-09-02).
///
/// The rules here decide how often the view queries the database — and
/// a view that queries on every key press is exactly what the
/// downloads were built against.
@Suite("Program grid: the window")
@MainActor
struct ProgramGridModelTests {

    private let now = Date(timeIntervalSince1970: 1_800_003_600)

    private func channels(_ id: String) -> Channel {
        Channel(
            id: id, name: "Channel \(id)", streamURL: URL(string: "http://x/\(id).m3u8")!,
            playlistID: "list", epgID: "epg-\(id)")
    }

    /// Counts how often it really loaded.
    private final class TallyCounter: @unchecked Sendable {
        var fetches = 0
        var spans: [(Date, Date)] = []
    }

    private func model(_ counter: TallyCounter, now: Date) -> GuideGridModel {
        GuideGridModel(now: now) { _, from, until in
            counter.fetches += 1
            counter.spans.append((from, until))
            return [:]
        }
    }

    /// **Not at "now".** Otherwise the view would begin in the middle of the running
    /// program, and its title would lie outside the picture on the left.
    @Test("The window starts on the half hour before")
    func windowStartsOnTheHalfHour() {
        let partiallyWatched = Date(timeIntervalSince1970: 1_800_003_600 + 1234)
        let start = GuideGridModel.gridStart(partiallyWatched)

        #expect(start <= partiallyWatched)
        #expect(partiallyWatched.timeIntervalSince(start) < 1800)
        #expect(Int(start.timeIntervalSince1970) % 1800 == 0)
    }

    /// **The lead is the point.** A step within what is already loaded
    /// must not query the database again — otherwise every page turn costs
    /// a query, and the downloads would be just another name for "later".
    @Test("A step within the lead does not ask again")
    func steppingInsideThePrefetchAsksNothing() async {
        let counter = TallyCounter()
        let model = self.model(counter, now: now)
        model.show([channels("1")], now: now)
        await model.running?.value
        #expect(counter.fetches == 1)

        model.page(.forward, now: now)
        await model.running?.value
        model.page(.forward, now: now)
        await model.running?.value

        #expect(counter.fetches == 1, "both steps are within the lead")
    }

    @Test("Whoever scrolls far enough gets fresh data")
    func steppingBeyondThePrefetchLoadsAgain() async {
        let counter = TallyCounter()
        let model = self.model(counter, now: now)
        model.show([channels("1")], now: now)
        await model.running?.value

        // Four hours of lead, a step is one hour: the fifth step
        // leads out.
        for _ in 0..<5 {
            model.page(.forward, now: now)
            await model.running?.value
        }
        #expect(counter.fetches == 2)
    }

    /// More than the window is always loaded — otherwise there would be no lead,
    /// and the check above would be green only by chance.
    @Test("The window plus one window in each direction is fetched")
    func loadsAWindowOnEachSide() async {
        let counter = TallyCounter()
        let model = self.model(counter, now: now)
        model.show([channels("1")], now: now)
        await model.running?.value

        let (from, until) = counter.spans[0]
        #expect(from == model.windowStart.addingTimeInterval(-GuideGridModel.leadTime))
        #expect(until == model.windowEnd.addingTimeInterval(GuideGridModel.leadTime))
    }

    @Test("Back to now leads to the initial window")
    func backToNowReturnsToTheStartingWindow() async {
        let counter = TallyCounter()
        let model = self.model(counter, now: now)
        model.show([channels("1")], now: now)
        await model.running?.value
        let start = model.windowStart

        for _ in 0..<6 {
            model.page(.forward, now: now)
            await model.running?.value
        }
        #expect(!model.showsNow(now))

        model.backToNow(now: now)
        await model.running?.value
        #expect(model.windowStart == start)
        #expect(model.showsNow(now))
    }

    /// **Before the first load, "no program" is no information.** Without this
    /// flag the view showed, in the first moment, the sentence "no program in the
    /// downloads" — and that is a statement, not a loading indicator.
    @Test("The view reports ready only after the first load")
    func readinessIsReportedOnlyAfterLoading() async {
        let counter = TallyCounter()
        let model = self.model(counter, now: now)
        #expect(!model.isReady)

        model.show([channels("1")], now: now)
        await model.running?.value
        #expect(model.isReady)
    }
}
