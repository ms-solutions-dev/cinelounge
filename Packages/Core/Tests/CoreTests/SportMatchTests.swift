import Foundation
import Testing

@testable import Core

/// The schedule match: dates from the source × EPG journal → verified
/// events (`design/schedule-sync.md`, stage 1) — checked against
/// the provider's real EPG titles.
@Suite("Schedule matching: fixtures meet the programme guide")
struct SportMatchTests {

    private let kickoff = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func programs(
        _ title: String, epg: String, offset: TimeInterval = 0
    ) -> Programme {
        Programme(
            id: "\(epg)-\(title)", channelID: epg, title: title,
            start: kickoff.addingTimeInterval(offset),
            end: kickoff.addingTimeInterval(offset + 7200))
    }

    private func fixture(
        _ home: String, _ away: String, league: String = "Süper Lig"
    ) -> SportFixture {
        SportFixture(
            id: "42", kind: .football, league: league, home: home, away: away, start: kickoff)
    }

    @Test("The fixture finds its channels — across languages and abbreviations")
    func fixtureFindsItsChannels() {
        let events = SportMatch.events(
            fixtures: [fixture("İnciköy Başakvadi", "Tepelispor")],
            programmes: [
                // Arena writes the pairing bare and abbreviates it.
                programs("Başakvadi F.K - Tepelispor", epg: "arenaspor1.tr"),
                // A second channel, a quarter of an hour earlier (pre-match show).
                programs("Süper Lig: İnciköy Başakvadi - Tepelispor", epg: "kanalspor.tr", offset: -900),
                // A different match at the same time stays out.
                programs("Gökyamaç - Kasımdere", epg: "arenaspor2.tr"),
            ])

        #expect(events.count == 1)
        #expect(events.first?.isVerified == true)
        #expect(events.first?.epgIDs.sorted() == ["arenaspor1.tr", "kanalspor.tr"])
        #expect(events.first?.start == kickoff)
    }

    @Test("Outside the kick-off window a title is not a broadcast")
    func airingsOutsideTheWindowAreReruns() {
        // The same pairing, but broadcast six hours after kick-off — the
        // rerun that the EPG doesn't flag.
        let events = SportMatch.events(
            fixtures: [fixture("Kumsalspor", "Demirbahçe")],
            programmes: [programs("Kumsalspor - Demirbahçe", epg: "arenaspor1.tr", offset: 6 * 3600)])
        #expect(events.isEmpty)
    }

    @Test("Evidence beats guesswork: the heuristic yields to the verified event")
    func verifiedReplacesHeuristic() {
        let verified = SportMatch.events(
            fixtures: [fixture("Kumsalspor", "Demirbahçe")],
            programmes: [programs("Kumsalspor - Demirbahçe", epg: "arenaspor1.tr")])
        let heuristic = SportPlan.events(
            from: [
                programs("Kumsalspor - Demirbahçe", epg: "arenaspor1.tr"),
                programs("Boks: Kalberg - Serrat", epg: "kafesspor.tr"),
            ])

        let combined = SportMatch.combined(verified: verified, heuristic: heuristic)
        #expect(combined.count == 2)
        #expect(combined.filter { $0.isVerified }.count == 1)
        #expect(combined.contains { $0.title.contains("Kalberg") })
    }

    /// **Since E6 the placeholder carries all matches of its league in the window.**
    ///
    /// Before, it belonged to a single match only — the only one of its league in
    /// the kick-off window — so that nothing is guessed. But that made the
    /// safeguard stay silent exactly when the most is on: on a Bundesliga
    /// Saturday five matches kick off together, and all five came away empty.
    /// Guessing is still not claimed: these rows come back with
    /// `isVerified == false` and are thus a reasoned expectation, not a proof.
    ///
    /// **And the lookup goes by the competition identifier**, not by how
    /// similar its name is. A date without an identifier therefore finds no
    /// placeholder — as intended: guessing from a name nobody has verified is
    /// exactly how MLS and the EFL Cup were silently missed.
    @Test("The placeholder carries all games of its league in the window")
    func placeholderCarriesAllGames() {
        // The German Zenit EPG names no pairing — only the competition.
        func laliga(
            _ id: String, _ home: String, _ guest: String, offset: TimeInterval
        )
            -> SportFixture
        {
            SportFixture(
                id: id, source: .espn, path: "soccer/esp.1", kind: .football,
                league: "Spanish LALIGA", home: home, away: guest,
                start: kickoff.addingTimeInterval(offset))
        }
        let zenit = [programs("LaLiga 26/27", epg: "zenit2.de", offset: -600)]

        let one = SportMatch.events(
            fixtures: [laliga("7", "Montés", "Navaluz", offset: 0)], programmes: zenit)
        #expect(one.count == 1)
        #expect(one.first?.epgIDs == ["zenit2.de"])
        #expect(one.first?.isVerified == false, "a placeholder proves nothing")

        // Two matches of the same league in the window: **both** get the
        // channel. Before, the placeholder stayed unused and both rows dropped
        // out of the schedule.
        let both = SportMatch.events(
            fixtures: [
                laliga("7", "Montés", "Navaluz", offset: 0),
                laliga("8", "Torrelinda", "Lagares", offset: 600),
            ], programmes: zenit)
        #expect(both.count == 2)
        #expect(both.allSatisfy { $0.epgIDs == ["zenit2.de"] })
        #expect(both.allSatisfy { !$0.isVerified })

        // Ohne Wettbewerbskennung gibt es keinen Platzhalter.
        let withoutIdentifier = SportMatch.events(
            fixtures: [
                SportFixture(
                    id: "9", kind: .football, league: "Spanish La Liga",
                    home: "Montés", away: "Navaluz", start: kickoff)
            ], programmes: zenit)
        #expect(withoutIdentifier.isEmpty)
    }

    @Test("League Pass: the pairing is in the channel name, not in the EPG")
    func leaguePassMatchesByChannelName() {
        let events = SportMatch.events(
            fixtures: [
                SportFixture(
                    id: "11", kind: .basketball, league: "NBA",
                    home: "Port Avalon Sunhawks", away: "Cranford Pinecrests", start: kickoff)
            ],
            programmes: [],
            channels: [
                SportChannel(id: "xtream#795406", name: "NBA 01: Sunhawks @ Pinecrests"),
                SportChannel(id: "xtream#795407", name: "NBA 02: Ridgebacks @ Tidewaters"),
            ])

        #expect(events.count == 1)
        #expect(events.first?.epgIDs == ["xtream#795406"])
    }

    @Test("Wrong time means pre-recorded: the fixture knows the real kick-off")
    func wrongTimeAiringsAreDropped() {
        // The source says: Bulutspor - Dumanspor plays in six days.
        // What airs today under that name is a rerun.
        let fixture = SportFixture(
            id: "13", kind: .football, league: "Turkish Super Lig",
            home: "Bulutspor", away: "Dumanspor",
            start: kickoff.addingTimeInterval(6 * 24 * 3600))
        let heuristic = SportPlan.events(
            from: [
                programs("Bulutspor - Dumanspor", epg: "arenaspor1.tr"),
                // A match without a date in the source stays in place.
                programs("Boks: Kalberg - Serrat", epg: "kafesspor.tr"),
            ])

        let combined = SportMatch.combined(
            verified: [], heuristic: heuristic, fixtures: [fixture])
        #expect(combined.count == 1)
        #expect(combined.first?.title.contains("Kalberg") == true)
    }

    // MARK: - Das Wortverzeichnis (E5)

    /// **Why these three checks carry the speed-up.**
    ///
    /// Until 2026-08-29 the match read through the whole EPG journal for every date.
    /// Since E5 it reaches into half-hour buckets — and a faster calculation
    /// that finds less is not an improvement. So the check is not the time
    /// (it flips on a busy machine without anything being broken; it lives in
    /// ``ScheduleTimingTests``) but the **equality**: the buckets must
    /// deliver exactly the slots that one pass over the whole list delivers.
    ///
    /// The order counts as well. It becomes the order of the identifiers in
    /// ``SportEvent/epgIDs`` and thus the order of the channel strip in the
    /// row; a bucket delivers its slots in time order, but the buckets among
    /// themselves are not necessarily ordered.
    @Test("The half-hour buckets deliver exactly what a full pass delivers")
    func bucketsFindTheSameAsTheFullPass() {
        // Four days of broadcasts at quarter-hour intervals, deliberately passed
        // in **unordered** — the EPG journal does come out of the database sorted
        // by start time, but the index must not rely on that.
        var broadcasts: [Programme] = []
        for step in 0..<(4 * 24 * 4) {
            broadcasts.append(
                programs("Sendung \(step)", epg: "k\(step % 7)", offset: Double(step) * 900))
        }
        broadcasts.shuffle()
        let directory = SportMatch.Directory(broadcasts)

        /// The full pass — the same condition the match previously ran over the
        /// whole list for each date.
        func fullPass(from: Date, to end: Date) -> [Int] {
            broadcasts.indices.filter { broadcasts[$0].start >= from && broadcasts[$0].start <= end }
        }

        // Every quarter of an hour of the period as kick-off, plus the two edges
        // far before and far after.
        for step in -4..<(4 * 24 * 4 + 4) {
            let startTime = kickoff.addingTimeInterval(Double(step) * 900)
            let from = startTime.addingTimeInterval(-SportMatch.leadWindow)
            let end = startTime.addingTimeInterval(SportMatch.lagWindow)
            #expect(directory.slots(from: from, until: end) == fullPass(from: from, to: end))
        }
    }

    @Test("The normalized title in the directory is the same as computed individually")
    func directoryNormalizesAsBefore() {
        let broadcasts = [
            programs("Süper Lig: İnciköy Başakvadi - Tepelispor", epg: "a"),
            programs("Fußball: Bergland München – Rebenfeld", epg: "b"),
            programs("", epg: "c"),
        ]
        let directory = SportMatch.Directory(broadcasts)
        for slot in broadcasts.indices {
            #expect(directory.title[slot] == SportKind.normalized(broadcasts[slot].title))
        }
    }

    /// An empty index and a window with nothing in it must not stumble —
    /// the section opens even with empty downloads.
    @Test("An empty directory and an empty window stay empty instead of stumbling")
    func emptyDirectoryStaysEmpty() {
        let empty = SportMatch.Directory([])
        #expect(empty.slots(from: kickoff, until: kickoff.addingTimeInterval(3600)).isEmpty)

        let directory = SportMatch.Directory([programs("Irgendwas", epg: "a")])
        // A window far before the only broadcast.
        #expect(
            directory.slots(
                from: kickoff.addingTimeInterval(-10 * 3600),
                until: kickoff.addingTimeInterval(-9 * 3600)
            ).isEmpty)
        // And one whose end lies before its start.
        #expect(directory.slots(from: kickoff, until: kickoff.addingTimeInterval(-1)).isEmpty)
    }

    @Test("The alias board bridges what the normal form cannot")
    func aliasesBridgeSpellings() {
        let events = SportMatch.events(
            fixtures: [
                SportFixture(
                    id: "9", kind: .football, league: "Bundesliga",
                    home: "Bergland Munich", away: "Rebenfeld", start: kickoff)
            ],
            programmes: [programs("B. Münih - Rebenfeld", epg: "arenaspor4.tr")])
        #expect(events.count == 1)
    }
}
