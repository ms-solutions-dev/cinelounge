import Core
import Foundation
import Testing

@testable import Flows

/// **Window, filter and order of the schedule — one rule for both devices** (AP58 R5,
/// finding L4).
@Suite("Sports schedule")
struct SportScheduleTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func event(
        _ title: String, _ kind: SportKind = .football, from offset: TimeInterval
    ) -> SportEvent {
        let start = now.addingTimeInterval(offset)
        return SportEvent(
            id: "\(kind.rawValue)-\(title)", kind: kind, competition: nil, title: title,
            start: start, end: start.addingTimeInterval(7200), epgIDs: ["e"])
    }

    @Test("The window is that of the TV")
    func window() {
        #expect(SportsSchedule.window(now: Self.now) == SportWindow.span(now: Self.now))
    }

    @Test("The read cadence is the full hour")
    func readInterval() {
        let cadence = SportsSchedule.readInterval(um: Self.now)
        #expect(cadence <= Self.now)
        #expect(Self.now.timeIntervalSince(cadence) < SportWindow.cadence)
        #expect(cadence.timeIntervalSince1970.truncatingRemainder(dividingBy: SportWindow.cadence) == 0)
    }

    @Test("A switched-off sport is missing from the list and among the sports")
    func filter() {
        var choice = SportFilterSettings()
        choice.toggle(.tennis)
        let all = [
            Self.event("Match", .tennis, from: 60), Self.event("Spiel", from: 120),
            Self.event("Korb", .basketball, from: 180),
        ]
        #expect(SportsSchedule.filtered(all, choice: choice).map(\.title) == ["Spiel", "Korb"])
        #expect(SportsSchedule.sports(in: all, choice: choice) == [.football, .basketball])
    }

    @Test("Remembered first, then by kickoff, at equal time by title")
    func order() {
        let all = [
            Self.event("Zeta", from: 600), Self.event("Alpha", from: 600),
            Self.event("Early", from: 60), Self.event("Remembered", from: 3600),
        ]
        let ordered = SportsSchedule.arrange(all) { $0.title == "Remembered" }
        #expect(ordered.map(\.title) == ["Remembered", "Early", "Alpha", "Zeta"])
    }
}
