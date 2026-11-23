import Core
import Foundation
import Testing

@testable import ParentalControls

/// **Diagnostics coverage of the parental controls** (2026-09-27): Whoever sells must be able to find out from the
/// report alone why something was blocked — without the report
/// itself revealing which title it was.
///
/// **Why not check against ``Diagnose/ErrorLog/shared``.** The ledger is a single
/// file under `~/Library/Application Support` — shared across **every** check run on
/// this machine, including parallel rounds in other working copies. A
/// concurrent run can empty the file in between (version change) or fill it with
/// its own lines; a check that reads there then checks the coincidence of the
/// timing and not the code. What is checked here is therefore the counting and the
/// line that ``ProtectionRule/filter(_:)`` passes to ``Diagnose/Diagnose/hint(_:_:)``
/// — **the same path, the same computation**, only without the asynchronous detour via
/// the shared ledger. That ``Diagnose`` itself writes reliably is already checked by
/// `Packages/Diagnose` with its own, isolated ledgers.
@Suite("Parental controls report locks — without title names")
struct DiagnosticsCoverageTests {

    private static let title = [
        MediaItem(id: "1", kind: .movie, title: "Kobe Runaways", ageRating: "FSK16"),
        MediaItem(id: "2", kind: .movie, title: "Ein anderer Film", ageRating: "FSK18"),
        MediaItem(id: "3", kind: .movie, title: "Kieselgasse", ageRating: "FSK0"),
        MediaItem(id: "4", kind: .movie, title: "Noch ein Film", ageRating: "FSK6"),
        MediaItem(id: "5", kind: .movie, title: "Ein fremdes Format", ageRating: "TV-MA"),
    ]

    @Test("The filter counts correctly — age, unrated, series open")
    func filterCountsCorrectly() {
        let rule = ProtectionRule(deviceLocked: true, isPinSet: true, limit: .from12)

        // **The real, public path:** the same list goes through the same lock as on the
        // device — the filtering itself depends on no diagnostics line.
        let result = rule.filter(Self.title)
        #expect(result.count == 2)

        let tally = rule.filterTally(Self.title)
        #expect(tally.locked == 3)
        #expect(tally.alter == 2, "FSK 16 and FSK 18 above the limit from 12")
        #expect(tally.unrecognized == 1, "this app does not know TV-MA")
        #expect(tally.series == 0, "no title waits for a series rating")
    }

    @Test("The line in the report — numbers only, no title")
    func rowWithoutTitle() {
        let rule = ProtectionRule(deviceLocked: true, isPinSet: true, limit: .from12)
        let tally = rule.filterTally(Self.title)
        let row = tally.summary(verified: Self.title.count)

        #expect(row == "Filter: 5 checked, 3 locked (age 2, unrated 1, series open 0)")

        // **Not just a sample:** ``FilterTally/summary(verified:)`` accepts
        // only `Int` — it structurally cannot output a title, because
        // it accepts none. The sample still proves that the obvious
        // titles are really not in it.
        for forbidden in [
            "Kobe Runaways", "Ein anderer Film", "Kieselgasse", "Noch ein Film",
            "Ein fremdes Format",
        ] {
            #expect(!row.contains(forbidden))
        }
    }

    @Test("A filter without hits counts nothing and reports nothing")
    func noHitCountsNothing() {
        let rule = ProtectionRule(deviceLocked: true, isPinSet: true, limit: .from0)
        let title = [
            MediaItem(id: "1", kind: .movie, title: "Kieselgasse", ageRating: "FSK0"),
            MediaItem(id: "2", kind: .movie, title: "Noch eine Sendung", ageRating: "FSK0"),
        ]

        #expect(rule.filter(title).count == 2)
        #expect(rule.filterTally(title).locked == 0)
    }
}
