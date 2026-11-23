import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The fixtures against the guide: **how many find a channel?**
///
/// **This is the number E6 hangs on.** A fixture without a channel is not a
/// row: the viewer cannot press it. The concept names it as the
/// reason for the source switch — ESPN found far more channels than
/// TheSportsDB, calculated against the same EPG. Here it is recalculated on
/// the guide and the fixture answers of the same day (``SportRecording``), so that
/// it is no longer merely asserted. The comparison between the two sources means
/// something only on the real recording; the synthetic set proves that the
/// stretch counts what it should.
@Suite("Fixtures against the program guide")
struct ScheduleFixturesTests {

    static func fetched(
        _ recording: SportRecording, _ fetch: SportFixtureSource.Fetch? = nil, days: Int
    ) async -> [SportFixture] {
        await recording.fixtures(days: days, fetch: fetch)
    }

    static func taken(_ recording: SportRecording, _ fixtures: [SportFixture]) -> [SportEvent] {
        SportMatch.events(fixtures: fixtures, programmes: recording.broadcasts)
    }

    /// **The number that carries the source switch.** Both sources against
    /// the same guide, on the same day, through the same calculation.
    ///
    /// On the synthetic set:
    ///
    /// | Source | Fixtures | with channel | of which evidenced |
    /// |---|---:|---:|---:|
    /// | ESPN, 3 days | 51 | 17 | 12 |
    /// | ESPN, the day only | 28 | 17 | 12 |
    /// | TheSportsDB (fallback) | 19 | 8 | 6 |
    ///
    /// The figures of the real recording stand in its `expected.json`.
    ///
    /// **This calculation does not know the channel board** — it calls
    /// ``SportMatch/events(fixtures:programmes:channels:board:)`` without channels
    /// and without a board and thus keeps measuring exactly what E6 measured.
    /// What E7 adds is in ``ChannelBoardMeasurementTests``.
    ///
    /// **History of the real figures.** E7 took three rows out that were wrong:
    /// they arose through the
    /// bare word "championship" in the hand-made vocabulary of `soccer/eng.2` —
    /// three Championship fixtures got as their ONLY channel a motorsport channel
    /// that was showing a "World Championship" at the time (the synthetic guide
    /// carries that trap on purpose). Since the programme ID carries the title the
    /// parser also reads simultaneous entries, and both figures rose.
    ///
    /// **The comparison with the concept.** The concept counted its fixtures
    /// across one league more than the board has; and most of E6's rows came
    /// through a competition placeholder that the old rule would have refused. They carry
    /// `isVerified == false` and are a reasoned expectation, not evidence.
    ///
    /// **What most fixtures lack is not a channel but an entry.** The guide
    /// reaches about +24 h. That is why the three-day count equals the one-day
    /// count: the fixtures of the two further days find not a single channel,
    /// because there can be no entry for them. That is exactly what E7 is for.
    @Test("How many fixtures find a channel — ESPN against TheSportsDB", arguments: SportRecording.all)
    func fixtureWithChannel(_ recording: SportRecording) async {
        let expected = recording.expected
        let espn = await Self.fetched(recording, days: 3)
        let espnToday = await Self.fetched(recording, days: 1)
        let tsdb = await Self.fetched(recording, recording.muted, days: 3)
        let fromEspn = Self.taken(recording, espn)
        let fromToday = Self.taken(recording, espnToday)
        let fromTsdb = Self.taken(recording, tsdb)

        print(
            """
            Fixtures against the program guide (\(recording.name))
              ESPN 3 days:   \(espn.count) fixtures → \(fromEspn.count) with channel \
            (evidenced \(fromEspn.count { $0.isVerified }), expected \(fromEspn.count { !$0.isVerified }))
              ESPN day 1:    \(espnToday.count) fixtures → \(fromToday.count) with channel \
            (evidenced \(fromToday.count { $0.isVerified }))
              TheSportsDB:   \(tsdb.count) fixtures → \(fromTsdb.count) with channel \
            (evidenced \(fromTsdb.count { $0.isVerified }))
            """)

        #expect(espn.count == expected.fixturesThreeDays)
        #expect(fromEspn.count == expected.withChannel)
        #expect(fromEspn.count { $0.isVerified } == expected.verified)

        #expect(espnToday.count == expected.fixturesToday)
        // The same number as over three days: what lies beyond the guide
        // cannot find anything without a channel board.
        #expect(fromToday.count == expected.todayWithChannel)
        #expect(fromToday.count { $0.isVerified } == expected.todayVerified)

        #expect(tsdb.count == expected.fallbackFixtures)
        #expect(fromTsdb.count == expected.fallbackWithChannel)
        #expect(fromTsdb.count { $0.isVerified } == expected.fallbackVerified)
    }

    /// **The seal tells the truth since E6.** Before, every result
    /// of the sync carried `isVerified == true`, including those guessed via a
    /// competition placeholder — the "evidenced only" filter in the
    /// settings thereby showed rows for which nobody had any evidence.
    ///
    /// On the real recording the placeholder rows shrank twice: when the three
    /// "championship" rows went, and since the programme ID carries the
    /// title, fixtures that before had only an expectation found a real
    /// programme title and became **sealed**. The number fell because the area got
    /// better.
    @Test("A placeholder does not seal", arguments: SportRecording.all)
    func placeholderDoesNotSeal(_ recording: SportRecording) async {
        let fixtures = await Self.fetched(recording, days: 3)
        let events = Self.taken(recording, fixtures)
        let byIdentifier = Dictionary(
            uniqueKeysWithValues: fixtures.map { ("fixture#" + $0.id, $0) })
        #expect(events.count { !$0.isVerified } == recording.expected.placeholderRows)
        #expect(events.contains { $0.isVerified } && events.contains { !$0.isVerified })

        // Counter-checked on the guide itself: a sealed row has
        // a programme whose title carries BOTH team cores; an
        // expected one has none. Otherwise the seal would again be a mere claim.
        for event in events {
            let fixture = byIdentifier[event.id]!
            let carriesPairing = recording.broadcasts.contains { broadcast in
                broadcast.start >= fixture.start.addingTimeInterval(-45 * 60)
                    && broadcast.start <= fixture.start.addingTimeInterval(15 * 60)
                    && SportMatch.sharesBothTeams(fixture, with: broadcast.title)
            }
            #expect(carriesPairing == event.isVerified, "\(event.title)")
        }
    }

    /// **"Championship" alone names nothing** — the trap of E6, built into the
    /// synthetic guide: at the kickoff of three Championship matches a football
    /// channel names the competition the way the source does, and a motorsport
    /// channel shows a "World Championship". The placeholder stage takes the first
    /// and leaves the second. The same holds for "LaLiga 2030/31": it names the
    /// first Spanish division, not the second, although "laliga 2" stands in it.
    @Test("The source's words reach the right channel and no other")
    func sourceWordsPickTheRightChannel() async {
        let recording = SportRecording.synthetic
        let events = Self.taken(recording, await Self.fetched(recording, days: 1))
        let championship = events.filter { $0.competitionPath == "soccer/eng.2" }
        #expect(championship.count == 3)
        #expect(championship.allSatisfy { $0.epgIDs == ["sportkanal.de"] && !$0.isVerified })
        #expect(!events.contains { $0.epgIDs.contains("motorwelt.de") })

        #expect(events.contains { $0.competitionPath == "soccer/esp.1" && $0.epgIDs == ["zenit2.de"] })
        #expect(!events.contains { $0.competitionPath == "soccer/esp.2" })
    }

    /// **What the sync moves on the finished schedule.** The same calculation
    /// that runs on the TV (``ScheduleCalculator/calculate(_:)``), once without
    /// fixtures and once with — on the day window of the guide.
    ///
    /// The difference is not the number of evidenced rows: a fixture that the
    /// heuristic had found anyway replaces it
    /// (``SportMatch/combined(verified:heuristic:fixtures:)``), and the wrong-time
    /// rule throws out canned recordings in return. On the real recording the
    /// figures moved with E7 (the bare hyphen and the "championship" rows) and
    /// again since the parser reads simultaneous entries.
    @Test("What the fixtures move on the finished schedule", arguments: SportRecording.all)
    func effectOnSchedule(_ recording: SportRecording) async {
        let fixtures = await Self.fetched(recording, days: 3)
        func computed(using fixtures: [SportFixture]) -> Int {
            ScheduleCalculator.calculate(
                ScheduleCalculator.Ingredients(
                    broadcasts: recording.dayWindow,
                    channelNames: recording.names, fixtures: fixtures, channels: [],
                    observations: [])
            ).count
        }
        let without = computed(using: [])
        let using = computed(using: fixtures)
        print("Schedule \(recording.name): \(without) events without fixtures, \(using) with fixtures")
        #expect(without == recording.expected.scheduleWithoutFixtures)
        #expect(using == recording.expected.scheduleWithFixtures)
    }
}
