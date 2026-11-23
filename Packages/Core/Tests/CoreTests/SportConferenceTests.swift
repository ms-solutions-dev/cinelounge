import Foundation
import Testing

@testable import Core

/// The row "Bundesliga · 15:30 · 5 matches".
///
/// **What has to be proven here is not the heading but the opposite:** that the
/// grouping creates no rows. The yardstick for 2026-08-29 is Süper Lig 3, Bundesliga 6,
/// Premier League 4 — "if the same fixture runs on four channels and in the end ten
/// rows stand instead of six, it is broken". Measured on the data state, that stands in
/// ``ChannelBoardMeasurementTests``; here stands the rule behind it.
@Suite("The conference row")
struct SportConferenceTests {

    static let kickoff = Date(timeIntervalSince1970: 1_787_000_000)

    static func game(
        _ title: String, path: String? = "soccer/ger.1", offset: TimeInterval = 0,
        name: String = "Bundesliga"
    ) -> SportEvent {
        SportEvent(
            id: title, kind: .football, competition: name, title: title,
            start: kickoff.addingTimeInterval(offset),
            end: kickoff.addingTimeInterval(offset + 7200),
            epgIDs: ["arena1.de"], competitionPath: path)
    }

    @Test("Five games of the same league at the same time are one row with five beneath it")
    func fiveGamesOneHeading() {
        let games = ["A - B", "C - D", "E - F", "G - H", "I - J"].map { Self.game($0) }
        let entries = SportConference.grouped(games)

        #expect(entries.count == 1)
        guard case .conference(let group) = entries[0] else {
            Issue.record("no conference formed")
            return
        }
        #expect(group.matches.count == 5)
        #expect(group.name == "Bundesliga")
        #expect(group.start == Self.kickoff)
        // **No row is lost and none is added.** That is the promise on which the yardstick
        // hangs.
        #expect(entries.flatMap(\.events).count == 5)
    }

    @Test("A single game stays single")
    func singleStaysSingle() {
        let entries = SportConference.grouped([Self.game("A - B")])
        #expect(entries.count == 1)
        if case .conference = entries[0] { Issue.record("one game is not a conference") }
    }

    /// **Different competitions are different groups, even at the same minute.** On
    /// Saturday at 15:30 Bundesliga and 2. Bundesliga kick off together; merging them
    /// would be a heading that lies.
    @Test("Different competitions at the same time stay separate")
    func differentCompetitionsStaySeparate() {
        let entries = SportConference.grouped([
            Self.game("A - B"), Self.game("C - D"),
            Self.game("E - F", path: "soccer/ger.2", name: "2. Bundesliga"),
            Self.game("G - H", path: "soccer/ger.2", name: "2. Bundesliga"),
        ])
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.events.count == 2 })
    }

    /// Two matches of the same league at **different** times are not a conference.
    /// Otherwise on Sunday evening a heading would stand above two matches that are four
    /// hours apart.
    @Test("Two kickoffs outside the window form no conference")
    func otherTimeNoConference() {
        let entries = SportConference.grouped([
            Self.game("A - B"),
            Self.game("C - D", offset: SportConference.window + 60),
        ])
        #expect(entries.count == 2)
    }

    /// **No identifier, no group.** The rows of the heuristic carry no
    /// ``SportEvent/competitionPath``: what only the broadcast title claims is not league
    /// membership, and two similar names are no answer to "is this the same competition".
    @Test("Heuristic rows are not grouped")
    func heuristicStaysUngrouped() {
        let entries = SportConference.grouped([
            Self.game("A - B", path: nil), Self.game("C - D", path: nil),
        ])
        #expect(entries.count == 2)
    }

    /// The order of the input decides where a group stands — it is not re-sorted. The memo
    /// list pulls what is remembered to the top, and a grouping that overwrote that would
    /// make the memo list ineffective.
    @Test("Grouping does not reorder the list")
    func orderStays() {
        let entries = SportConference.grouped([
            Self.game("Z - Y", path: nil),
            Self.game("A - B"),
            Self.game("Q - R", path: nil),
            Self.game("C - D"),
        ])
        #expect(entries.count == 3)
        #expect(entries[0].events.map(\.title) == ["Z - Y"])
        #expect(entries[1].events.map(\.title) == ["A - B", "C - D"])
        #expect(entries[2].events.map(\.title) == ["Q - R"])
    }
}
