import Core
import Foundation
import Testing

@testable import PlaylistKit

/// **What the living channel board really brings** — measured on the same
/// guide and fixtures with which E2, E3, E5 and E6 were also calculated
/// (``SportRecording``).
///
/// **Why this measurement has to exist.** A board that assigns channels always
/// looks good: it produces rows. The question is whether the rows are right,
/// and only a **counter-figure** answers that — how many of its assignments
/// the guide refutes. Without it, the first number is worthless.
///
/// Fixed clock, no network. The synthetic set carries what the real Saturday
/// had: a conference of five Bundesliga matches behind "BL" on six channels named
/// after the league, a seeded channel, a channel that showed its league with
/// pairings and is silent at the next kickoff.
@Suite("The channel board on the recorded guide")
struct ChannelBoardMeasurementTests {

    static func fixtures(_ recording: SportRecording) async -> [SportFixture] {
        await recording.fixtures(days: 3)
    }

    /// The assignments from the **channel name** — what the addendum of
    /// 2026-08-29 demands: "If a channel name carries a competition name that the
    /// fixture source names today, it belongs to that competition."
    static func fromNames(_ recording: SportRecording, _ fixtures: [SportFixture]) -> [String: Set<String>] {
        ScheduleCalculator.board(
            ScheduleCalculator.Ingredients(
                broadcasts: [], channelNames: [:], fixtures: fixtures,
                channels: recording.sportChannels, observations: [])
        ).namesOnly
    }

    /// The same guide, shifted by whole days — the substitute for "wait
    /// four weeks".
    ///
    /// **Why this is a permissible measurement:** the board counts days, and a
    /// day is for it nothing but a distance between two kickoffs. Whether the
    /// pairings on four Saturdays are the same changes nothing in the counting
    /// — it only makes it an upper bound: a real match day
    /// would bring different pairings and thus rather more channels, not fewer.
    static func postponed(_ broadcasts: [Programme], by days: Int) -> [Programme] {
        let offset = TimeInterval(days * 86400)
        return broadcasts.map {
            Programme(
                id: "\(days)#\($0.id)", channelID: $0.channelID, title: $0.title,
                start: $0.start.addingTimeInterval(offset),
                end: $0.end.addingTimeInterval(offset))
        }
    }

    static func postponed(_ fixtures: [SportFixture], by days: Int) -> [SportFixture] {
        let offset = TimeInterval(days * 86400)
        return fixtures.map {
            SportFixture(
                id: "\(days)#\($0.id)", source: $0.source, path: $0.path, kind: $0.kind,
                league: $0.league, leagueShort: $0.leagueShort, home: $0.home, away: $0.away,
                start: $0.start.addingTimeInterval(offset),
                homeVariantsList: $0.homeVariantsList, awayVariantsList: $0.awayVariantsList)
        }
    }

    /// The catalog after four simulated match days (three weeks back and
    /// today).
    static func afterFourMatchdays(
        _ recording: SportRecording, _ fixtures: [SportFixture]
    ) -> [ChannelCompetition] {
        var catalog: [ChannelCompetition] = []
        for week in [-21, -14, -7, 0] {
            catalog = SportChannelBoard.merged(
                catalog: catalog,
                fresh: SportMatch.observations(
                    fixtures: postponed(fixtures, by: week),
                    programmes: postponed(recording.broadcasts, by: week)))
        }
        return catalog
    }

    // MARK: - How many channels the board reaches

    /// **One pass reaches channels — and none of them reliable.**
    ///
    /// This is the measurement that justifies the threshold of two days
    /// (``SportChannelBoard/minimumDays``): after the first comparison, each
    /// channel stands there with exactly **one** day. With a threshold of 1
    /// the board would assign right after the first opening, without ever having seen a
    /// pattern — a cup match on a channel from another league
    /// would at once be a rights claim. Only the second match day separates the
    /// channel that has the league from the one that showed a match once.
    ///
    /// After four simulated match days it is the same channels with the same
    /// rows, now all reliable. That the number of channels does not grow
    /// is no defect of the board but the reach of the guide:
    /// it is ONE match day, replayed four times. (On the real recording the
    /// channel count grew once more when the parser read simultaneous entries;
    /// evidence arises precisely from such titles.)
    @Test(
        "How many channels the board reaches — one pass against four matchdays", arguments: SportRecording.all
    )
    func reachOfTheBoard(_ recording: SportRecording) async {
        let expected = recording.expected
        let fixtures = await Self.fixtures(recording)

        let singlePass = SportChannelBoard.merged(
            catalog: [],
            fresh: SportMatch.observations(fixtures: fixtures, programmes: recording.broadcasts))
        #expect(singlePass.count == expected.singlePassRows)
        #expect(Set(singlePass.map(\.channels)).count == expected.singlePassChannels)
        // **This line is not evidence but bookkeeping** (acceptance review
        // for E7): `observations` returns at most one piece of evidence per channel and
        // competition, so after one pass NO row can have more
        // than one hit. It is here so that the deduplication
        // stays visible. Re-measured on the real recording, even
        // without it all pieces of evidence lie on the same calendar day — the threshold of
        // two days is therefore not based on the deduplication.
        #expect(singlePass.allSatisfy { $0.match == 1 })
        #expect(singlePass.count { $0.match >= SportChannelBoard.minimumDays } == 0)

        let four = Self.afterFourMatchdays(recording, fixtures)
        #expect(four.count == expected.singlePassRows)
        #expect(four.allSatisfy { $0.match == 4 })
        #expect(Set(four.map(\.channels)).count == expected.singlePassChannels)

        // And the name stage, which carries from the start: channels that carry a
        // competition name of the source in their own name. A sports mix or a news
        // channel belongs to no league and is therefore not in it.
        let names = Self.fromNames(recording, fixtures)
        #expect(names.count == expected.fromNames)
        for (channel, paths) in expected.namesHit {
            #expect(names[channel] == paths, "\(channel)")
        }
        for channel in expected.namesMiss {
            #expect(names[channel] == nil, "\(channel)")
        }

        print(
            """
            Channel board, \(recording.name)
              from the channel name: \(names.count) channels
              one pass:              \(singlePass.count) rows on \
            \(Set(singlePass.map(\.channels)).count) channels, supporting 0
              four matchdays:        \(four.count) rows on \
            \(Set(four.map(\.channels)).count) channels, supporting \
            \(four.count { $0.match >= SportChannelBoard.minimumDays })
            """)
    }

    // MARK: - What the board yields in rows, and what it costs

    /// **The figure of the stage — and its counter-figure.**
    ///
    /// On the synthetic set:
    ///
    /// | State | Fixtures with a channel | of which sealed |
    /// |---|---:|---:|
    /// | without board (E6 calculation) | 17 | 12 |
    /// | only from channel names and seed values | 29 | 12 |
    /// | with four match days of observation | 39 | 12 |
    ///
    /// (The real recording, where present, brings its own figures in its
    /// `expected.json`; the shape is the same.) Fixtures gain a channel they did not have before — and **not a single one**
    /// gains a seal. That is the promise from the addendum: an assignment from the
    /// board is a reasoned expectation and not evidence (`isVerified == false`).
    ///
    /// **The counter-figure: assignments refuted by the EPG.** Refuted
    /// here means: the assigned channel carries in the kickoff window a programme
    /// that names a DIFFERENT competition of the board. On both sets: not a
    /// single one refuted.
    ///
    /// **What this zero proves and what it does not — correction of the acceptance review of
    /// E7 (2026-08-29).** It cannot show the mute guard in
    /// ``SportMatch/events(fixtures:programmes:channels:board:)``: the counting loop below sets, with
    /// `!inWindow.contains(where: pairing != nil)`, **the same**
    /// condition once more, and is thereby blind to the guard. The guard is proved in
    /// ``SportChannelBoardTests/onlySilentChannelsGetTheBoard()`` and not
    /// here. And the counter is not a dead one: if every channel is given the same
    /// competition in the board, it rises.
    ///
    /// **What the figure does NOT say:** whether a provider really had all
    /// Bundesliga matches on all its league channels. The guide cannot answer that —
    /// on these channels it says only "BL". Exactly for that reason these lines come
    /// without a seal.
    @Test("What rows the board yields — and how many of them the EPG refutes", arguments: SportRecording.all)
    func effectAndErrorRate(_ recording: SportRecording) async {
        let expected = recording.expected
        let broadcasts = recording.broadcasts
        let channels = recording.sportChannels
        let fixtures = await Self.fixtures(recording)
        let names = Self.fromNames(recording, fixtures)
        let catalog = Self.afterFourMatchdays(recording, fixtures)
        let board = SportChannelBoard(observations: catalog, fromNames: names)

        let without = SportMatch.events(fixtures: fixtures, programmes: broadcasts)
        let namesOnly = SportMatch.events(
            fixtures: fixtures, programmes: broadcasts, channels: channels,
            board: SportChannelBoard(fromNames: names))
        let full = SportMatch.events(
            fixtures: fixtures, programmes: broadcasts, channels: channels, board: board)

        #expect(without.count == expected.withoutBoard)
        #expect(namesOnly.count == expected.namesOnlyBoard)
        #expect(full.count == expected.fullBoard)
        #expect(without.count < namesOnly.count && namesOnly.count < full.count)
        // Not a single seal comes from the board — the same before as after it.
        #expect(without.count { $0.isVerified } == expected.sealed)
        #expect(namesOnly.count { $0.isVerified } == expected.sealed)
        #expect(full.count { $0.isVerified } == expected.sealed)

        let previous = Set(without.map(\.id))
        let gained = full.count { !previous.contains($0.id) }
        #expect(gained == expected.gained)

        // The counter-figure.
        let byIdentifier = Dictionary(uniqueKeysWithValues: fixtures.map { ("fixture#" + $0.id, $0) })
        var assignments = 0
        var refuted: Set<String> = []
        for event in full {
            guard let fixture = byIdentifier[event.id] else { continue }
            for identifier in event.epgIDs
            where board.competitions(forItem: identifier, now: fixture.start).contains(fixture.path) {
                let inWindow = broadcasts.filter {
                    $0.channelID == identifier
                        && $0.start >= fixture.start.addingTimeInterval(-45 * 60)
                        && $0.start <= fixture.start.addingTimeInterval(15 * 60)
                }
                // Only those that REALLY come from the board.
                guard !inWindow.contains(where: { SportPlan.pairing(in: $0.title) != nil })
                else { continue }
                assignments += 1
                for broadcast in inWindow {
                    let flattened = SportKind.normalized(broadcast.title)
                    for other in SportCompetition.all
                    where other.path != fixture.path && other.names(flattened) {
                        refuted.insert("\(identifier)#\(broadcast.title)#\(other.path)")
                    }
                }
            }
        }
        #expect(assignments == expected.assignments)
        #expect(refuted.isEmpty)

        print(
            """
            What the channel board moves (\(recording.name), \(fixtures.count) fixtures)
              without board:         \(without.count) with channel, \(without.count { $0.isVerified }) sealed
              names/seed values only: \(namesOnly.count) with channel
              with observations:    \(full.count) with channel
              newly gained:          \(gained) fixtures
              assignments:           \(assignments), of which refuted by the EPG \(refuted.count)
            """)
    }

    // MARK: - The user's benchmark

    /// **The user's reference figure for the recorded Saturday — and this time it
    /// tests the merge.**
    ///
    /// Süper Lig 3, Bundesliga 6, Premier League 4. Requirement: if the same match runs
    /// on four channels and ten rows end up instead of six, the merge is
    /// broken. Measured on the finished schedule, through the same
    /// calculation that runs on the TV (``ScheduleCalculator/calculate(_:)``). The
    /// synthetic day is built to the same benchmark.
    ///
    /// **Six Bundesliga matches on a dozen channels are six rows** —
    /// not ninety and not ten. And not a single heuristic row
    /// stands beside them that names the same match once more.
    ///
    /// **The Süper Lig was 2 of 3 until the evening of the acceptance**, and the
    /// explanation next to it was wrong twice: first "the channel shows another
    /// match in the kickoff window", then "the parser drops the row" — correct, but
    /// left lying. On the Turkish league channel there were three entries with the
    /// same start time, among them the pairing sought; the ID made of channel and
    /// start time kept only the first. Since it carries the title, the match is in
    /// the schedule — **sealed**, not guessed. The synthetic guide carries the same
    /// minute.
    @Test("The user's benchmark on the finished schedule: 6, 4 and 3", arguments: SportRecording.all)
    func guidelineOnSchedule(_ recording: SportRecording) async {
        let fixtures = await Self.fixtures(recording)
        let catalog = Self.afterFourMatchdays(recording, fixtures)
        let schedule = ScheduleCalculator.calculate(
            ScheduleCalculator.Ingredients(
                broadcasts: recording.dayWindow,
                channelNames: recording.names,
                fixtures: fixtures, channels: recording.sportChannels, observations: catalog))

        func onDay(_ path: String) -> SportRecording.Tally {
            let scheduled = fixtures.filter {
                $0.path == path && $0.start >= recording.dayStart && $0.start < recording.dayEnd
            }
            let rows = schedule.filter {
                $0.competitionPath == path && $0.start >= recording.dayStart
                    && $0.start < recording.dayEnd
            }
            let duplicate = schedule.filter { row in
                row.competitionPath == nil
                    && scheduled.contains { SportMatch.sharesBothTeams($0, with: row.title) }
            }
            return .init(fixtures: scheduled.count, rows: rows.count, duplicate: duplicate.count)
        }

        for (path, tally) in recording.expected.tallies {
            #expect(onDay(path) == tally, "\(path)")
        }
        // The schedule as a whole, with fixtures and board.
        #expect(schedule.count == recording.expected.scheduleWithBoard)
    }

    /// **The row that the area lacked until E7**:
    /// "Bundesliga · 15:30 · 5 matches" with the league channels below it.
    ///
    /// Five and not six: the sixth Bundesliga match of the day kicks off at
    /// 18:30 and therefore does not belong to the conference.
    @Test("Bundesliga · 15:30 · 5 matches — the conference row", arguments: SportRecording.all)
    func conferenceRow(_ recording: SportRecording) async {
        let expected = recording.expected
        let fixtures = await Self.fixtures(recording)
        let board = SportChannelBoard(
            observations: Self.afterFourMatchdays(recording, fixtures),
            fromNames: Self.fromNames(recording, fixtures))
        let events = SportMatch.events(
            fixtures: fixtures, programmes: recording.broadcasts,
            channels: recording.sportChannels, board: board
        ).sorted { $0.start < $1.start }

        let groups = SportConference.grouped(events)
        // The rows become fewer entries — and no row is lost.
        #expect(groups.count == expected.conferenceEntries)
        #expect(groups.flatMap(\.events).count == events.count)

        let clock = Self.clockTime(recording)
        let bundesliga = groups.compactMap { entry -> SportConference.Group? in
            guard case .conference(let group) = entry,
                group.path == "soccer/ger.1",
                clock.string(from: group.start) == expected.conferenceTime
            else { return nil }
            return group
        }
        #expect(bundesliga.count == 1)
        #expect(bundesliga.first?.matches.count == expected.conferenceMatches)
        #expect(bundesliga.first?.name == "Bundesliga")
        // And below them are the channels that were mute until E7.
        let channels = Set(bundesliga.first?.matches.flatMap(\.epgIDs) ?? [])
        for channel in expected.conferenceChannels {
            #expect(channels.contains(channel), "\(channel)")
        }

        for group in bundesliga {
            print("\(group.name) · \(clock.string(from: group.start)) · \(group.matches.count) matches")
            for match in group.matches {
                print("   \(match.title) — \(match.epgIDs.count) channels")
            }
        }
    }

    /// The fixed clock for the display — the same time zone as the recording.
    static func clockTime(_ recording: SportRecording) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = recording.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}
