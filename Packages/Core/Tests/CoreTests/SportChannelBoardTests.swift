import Foundation
import Testing

@testable import Core

/// The **living channel board** — what is tested is the rule, not the store.
///
/// **Why these four checks and no others.** The objection of 2026-08-29:
/// committing today to Bundesliga running on these channels need not
/// stay a fact in three years — rights can be reassigned. The design
/// answers with four
/// commitments, and each of them is a check here:
///
/// 1. A hit across both team cores **writes** an observation.
/// 2. A hit via placeholder, channel name or the board itself writes
///    **no** observation — the feedback loop is the one way this design can
///    silently break.
/// 3. An observation from sixty days ago assigns **nothing** anymore.
/// 4. Observations **beat** the starting value, even when they
///    contradict it.
@Suite("The live channel board")
struct SportChannelBoardTests {

    static let kickoff = Date(timeIntervalSince1970: 1_787_000_000)

    static func fixture(
        _ id: String, path: String = "soccer/ger.1", home: String, away: String,
        offset: TimeInterval = 0
    ) -> SportFixture {
        SportFixture(
            id: id, source: .espn, path: path, kind: .football,
            league: "German Bundesliga", leagueShort: "Bundesliga",
            home: home, away: away, start: kickoff.addingTimeInterval(offset))
    }

    static func broadcast(
        _ title: String, channels: String, offset: TimeInterval = -600
    ) -> Programme {
        Programme(
            id: "\(channels)#\(title)#\(offset)", channelID: channels, title: title,
            start: kickoff.addingTimeInterval(offset),
            end: kickoff.addingTimeInterval(offset + 7200))
    }

    // MARK: - 1. The strongest evidence writes

    @Test("Both team cores in the title write an observation")
    func bothCoresWrite() {
        let evidence = SportMatch.observations(
            fixtures: [Self.fixture("1", home: "Bergland Munich", away: "Union Kesselburg")],
            programmes: [Self.broadcast("Bergland München - Union Kesselburg", channels: "arena1.de")])

        #expect(evidence.count == 1)
        #expect(evidence.first?.channels == "arena1.de")
        #expect(evidence.first?.path == "soccer/ger.1")
        // The point in time is the KICK-OFF, not the moment of the calculation:
        // otherwise the board would count matches instead of match days, and whoever opens the
        // section five times on a Saturday would have five hits.
        #expect(evidence.first?.when == Self.kickoff)
    }

    // MARK: - 2. No feedback loop

    /// **The most important of the four.** If the board wrote from its own
    /// assignments, it would confirm its own guess every week: the
    /// hit count would rise, `recent` would stay fresh, and no row would ever die
    /// again. The ageing that carries the whole design would be switched off —
    /// and from the outside the board would look exactly like one that
    /// is right.
    @Test("Placeholders, channel name and the board itself write nothing")
    func weakTiersDoNotWrite() {
        let fixture = Self.fixture("2", home: "Bergland Munich", away: "Union Kesselburg")

        // a) The placeholder: the channel names the league, but no pairing.
        let placeholder = SportMatch.observations(
            fixtures: [fixture],
            programmes: [Self.broadcast("Bundesliga 26/27", channels: "zenit1.de")])
        #expect(placeholder.isEmpty)
        // Control, so the check is not green for the wrong reason: via
        // the placeholder this date does find its channel.
        let fromPlaceholder = SportMatch.events(
            fixtures: [fixture],
            programmes: [Self.broadcast("Bundesliga 26/27", channels: "zenit1.de")])
        #expect(fromPlaceholder.first?.epgIDs == ["zenit1.de"])
        #expect(fromPlaceholder.first?.isVerified == false)

        // b) The channel name carries the pairing — League Pass, no EPG at all.
        let fromNames = SportMatch.observations(fixtures: [fixture], programmes: [])
        #expect(fromNames.isEmpty)
        let found = SportMatch.events(
            fixtures: [fixture], programmes: [],
            channels: [SportChannel(id: "x#1", name: "BL 01: Bergland Munich vs Union Kesselburg")])
        #expect(found.first?.epgIDs == ["x#1"])

        // c) The board itself: it assigns, and the assignment does not write
        // back. Without this row every guess would grow into a fact.
        let board = SportChannelBoard(fromNames: ["stumm.de": ["soccer/ger.1"]])
        let fromBoard = SportMatch.events(
            fixtures: [fixture], programmes: [Self.broadcast("Sendepause", channels: "stumm.de")],
            channels: [SportChannel(id: "stumm.de", name: "Stummer Sender", epgID: "stumm.de")],
            board: board)
        #expect(fromBoard.first?.epgIDs == ["stumm.de"])
        #expect(fromBoard.first?.isVerified == false, "an assignment is not evidence")
        #expect(
            SportMatch.observations(
                fixtures: [fixture],
                programmes: [Self.broadcast("Sendepause", channels: "stumm.de")]
            ).isEmpty)
    }

    // MARK: - 3. Sie altert

    @Test("An observation from sixty days ago no longer assigns anything")
    func oldObservationAssignsNothing() {
        func board(age days: Double) -> SportChannelBoard {
            let recent = Self.kickoff.addingTimeInterval(-days * 24 * 3600)
            return SportChannelBoard(observations: [
                ChannelCompetition(
                    channels: "arena1.de", path: "soccer/ger.1", match: 9,
                    firstSeen: recent.addingTimeInterval(-9 * 24 * 3600), recent: recent)
            ])
        }
        #expect(
            board(age: 59).competitions(forItem: "arena1.de", now: Self.kickoff)
                == ["soccer/ger.1"])
        #expect(board(age: 61).competitions(forItem: "arena1.de", now: Self.kickoff).isEmpty)

        // And it is not merely skipped but discarded: otherwise the board would
        // grow year after year by rows that no longer say anything.
        let catalog = [
            ChannelCompetition(
                channels: "old.de", path: "soccer/ger.1", match: 5,
                firstSeen: Self.kickoff.addingTimeInterval(-200 * 24 * 3600),
                recent: Self.kickoff.addingTimeInterval(-90 * 24 * 3600)),
            ChannelCompetition(
                channels: "fresh.de", path: "soccer/ger.1", match: 5,
                firstSeen: Self.kickoff.addingTimeInterval(-30 * 24 * 3600),
                recent: Self.kickoff.addingTimeInterval(-2 * 24 * 3600)),
        ]
        let aged = SportChannelBoard.aged(catalog, now: Self.kickoff)
        #expect(aged.map(\.channels) == ["fresh.de"])
    }

    /// **The hit count counts days, not broadcasts.** On a
    /// Bundesliga Saturday five matches kick off together; if each proof counted
    /// on its own, the threshold of two days would be met in the very hour
    /// in which the board sees the channel for the first time.
    @Test("Five matches on one afternoon count as one day")
    func hitsCountDays() {
        let saturday = (0..<5).map {
            (
                channels: "arena1.de", path: "soccer/ger.1",
                when: Self.kickoff.addingTimeInterval(Double($0) * 600)
            )
        }
        let afterOne = SportChannelBoard.merged(catalog: [], fresh: saturday)
        #expect(afterOne.count == 1)
        #expect(afterOne.first?.match == 1)

        let afterWeek = SportChannelBoard.merged(
            catalog: afterOne,
            fresh: [
                (
                    channels: "arena1.de", path: "soccer/ger.1",
                    when: Self.kickoff.addingTimeInterval(7 * 24 * 3600)
                )
            ])
        #expect(afterWeek.first?.match == 2)
        #expect(afterWeek.first?.firstSeen == Self.kickoff)
    }

    // MARK: - 4. Beobachtungen schlagen den Startwert

    /// **Even when they contradict it** — because then the world has changed
    /// and the observation was not mistaken. That is exactly the
    /// answer to "rights can be reassigned": if the Bundesliga moves away
    /// from Zenit 1, the starting value keeps saying `ger.1`, and the board
    /// overrules it as soon as it has seen something different for two match
    /// days.
    @Test("Observations beat the seed, even when they contradict it")
    func observationsBeatTheSeed() {
        let channels = "zenit1.de"
        // Without observations the starting value carries. It is the crutch for the
        // cold start and nothing else.
        #expect(
            SportChannelBoard.empty.competitions(forItem: channels, now: Self.kickoff)
                == ["soccer/ger.1"])
        #expect(SportChannelBoard.empty.origin(forItem: channels, now: Self.kickoff) == .seedValue)

        // Seen a DIFFERENT league for two match days: the starting value drops
        // out entirely, it is not added in.
        let contradiction = SportChannelBoard(observations: [
            ChannelCompetition(
                channels: channels, path: "soccer/ita.1", match: SportChannelBoard.minimumDays,
                firstSeen: Self.kickoff.addingTimeInterval(-14 * 24 * 3600),
                recent: Self.kickoff.addingTimeInterval(-7 * 24 * 3600))
        ])
        #expect(
            contradiction.competitions(forItem: channels, now: Self.kickoff) == ["soccer/ita.1"])
        #expect(contradiction.origin(forItem: channels, now: Self.kickoff) == .observed)

        // A single observation is not enough for that: a guest appearance is not a
        // pattern, and a pattern is the question.
        let oneDay = SportChannelBoard(observations: [
            ChannelCompetition(
                channels: channels, path: "soccer/ita.1", match: 1,
                firstSeen: Self.kickoff.addingTimeInterval(-7 * 24 * 3600),
                recent: Self.kickoff.addingTimeInterval(-7 * 24 * 3600))
        ])
        #expect(oneDay.competitions(forItem: channels, now: Self.kickoff) == ["soccer/ger.1"])

        // And the name level beats the starting value too — for the same
        // reason: it comes from the source and today's channel name, the
        // starting value from the source code.
        let fromName = SportChannelBoard(fromNames: [channels: ["soccer/esp.1"]])
        #expect(fromName.competitions(forItem: channels, now: Self.kickoff) == ["soccer/esp.1"])
        #expect(fromName.origin(forItem: channels, now: Self.kickoff) == .name)
    }

    // MARK: - Das Vokabular kommt aus der Quelle

    /// **The core of the addendum of 2026-08-29:** if a channel name carries a
    /// competition name that the date source names today, it belongs to that
    /// competition. When a league is added, its name comes along — this shows
    /// that the word index really comes from the dates and not from
    /// a list in the source code.
    @Test("The vocabulary comes from the fixtures, not from the source text")
    func vocabularyFromTheSource() {
        let vocabulary = SportChannelBoard.vocabulary([
            Self.fixture("1", home: "Bergland Munich", away: "Union Kesselburg"),
            SportFixture(
                id: "2", source: .espn, path: "soccer/eng.2", kind: .football,
                league: "English League Championship", leagueShort: "EFL Championship",
                home: "Dunmore County", away: "Swanmere City", start: Self.kickoff),
        ])
        #expect(vocabulary["soccer/ger.1"] == ["German Bundesliga", "Bundesliga"])
        #expect(vocabulary["soccer/eng.2"] == ["English League Championship", "EFL Championship"])

        // Words that are too short stay out: at ESPN the Euroleague carries the
        // short form "EURO", and that is contained in every "EURO ARENA 1".
        let short = SportChannelBoard.vocabulary([
            SportFixture(
                id: "3", source: .espn, path: "basketball/euroleague", kind: .basketball,
                league: "Euroleague", leagueShort: "EURO",
                home: "Real Castellar", away: "Panthalassikos", start: Self.kickoff)
        ])
        #expect(short["basketball/euroleague"] == ["Euroleague"])
    }

    /// **What E2 recognised as a magazine is not a placeholder either**
    /// (acceptance of E6, fixed in E7). The placeholder level only checked whether
    /// the title names the competition and carries no pairing — it did not know
    /// the rerun and studio markers. "CUGRINKLIT
    /// Ceidriot 26/27" meets both old conditions and is still
    /// not the airtime of a match.
    ///
    /// **On the dump of 2026-08-29 this rule moves no number**, and
    /// that is no oversight: the same channels also carry a real
    /// placeholder of the same league ("LaLiga 26/27" on Zenit 2, six times on the
    /// same day), so the dates find their channel anyway. The
    /// rule is therefore proven here and not in the probe.
    @Test("A magazine show is no broadcast slot even as a placeholder")
    func magazineIsNotAPlaceholder() {
        let fixture = SportFixture(
            id: "5", source: .espn, path: "soccer/esp.1", kind: .football,
            league: "Spanish LALIGA", leagueShort: "LALIGA",
            home: "Costavella", away: "Rayo Vallehondo", start: Self.kickoff)

        let magazine = SportMatch.events(
            fixtures: [fixture],
            programmes: [Self.broadcast("CUGRINKLIT Ceidriot 26/27", channels: "zenit2.de")])
        #expect(magazine.isEmpty)

        // Control: the same channel with the real placeholder carries.
        let real = SportMatch.events(
            fixtures: [fixture],
            programmes: [Self.broadcast("LaLiga 26/27", channels: "zenit2.de")])
        #expect(real.first?.epgIDs == ["zenit2.de"])
    }

    /// **The board steps NEXT TO the placeholder level, not behind it.**
    ///
    /// Both are expectations of the same quality. Whoever chained them
    /// would lose the better channels to the worse coincidence: on
    /// 2026-08-29 the placeholder for the Bundesliga found "DE: ARENA NEWS HD"
    /// — a news channel that carries "Fußball: Bundesliga" as a topic line —
    /// and would thereby have displaced the ten Arena Bundesliga channels on
    /// which the match really runs. Both levels are suppressed only by
    /// a real proof.
    @Test("A placeholder does not displace the board")
    func placeholderDoesNotDisplaceTheBoard() {
        let fixture = Self.fixture("6", home: "Bergland Munich", away: "Union Kesselburg")
        let board = SportChannelBoard(fromNames: ["arenabundesliga1.de": ["soccer/ger.1"]])
        let events = SportMatch.events(
            fixtures: [fixture],
            programmes: [
                Self.broadcast("Fußball: Bundesliga", channels: "arenanews.de"),
                Self.broadcast("BL", channels: "arenabundesliga1.de"),
            ],
            channels: [
                SportChannel(
                    id: "arenabundesliga1.de", name: "DE: ARENA BUNDESLIGA 1 HD",
                    epgID: "arenabundesliga1.de")
            ],
            board: board)
        #expect(events.first?.epgIDs == ["arenanews.de", "arenabundesliga1.de"])

        // A real proof suppresses both: whoever demonstrably broadcasts makes
        // guessing unnecessary.
        let taken = SportMatch.events(
            fixtures: [fixture],
            programmes: [
                Self.broadcast("Bergland München - Union Kesselburg", channels: "arena2.de"),
                Self.broadcast("Fußball: Bundesliga", channels: "arenanews.de"),
                Self.broadcast("BL", channels: "arenabundesliga1.de"),
            ],
            channels: [
                SportChannel(
                    id: "arenabundesliga1.de", name: "DE: ARENA BUNDESLIGA 1 HD",
                    epgID: "arenabundesliga1.de")
            ],
            board: board)
        #expect(taken.first?.epgIDs == ["arena2.de"])
        #expect(taken.first?.isVerified == true)
    }

    /// A channel that demonstrably shows **something else** in the kick-off window
    /// does not get the date — even if the board lists it for the competition.
    /// Without this safeguard "DE: ARENA BUNDESLIGA 1 HD" would carry all six
    /// matches of the Saturday, although one of them demonstrably runs on it.
    @Test("Whoever visibly shows something else is not silent")
    func onlySilentChannelsGetTheBoard() {
        let fixture = Self.fixture("4", home: "Bergland Munich", away: "Union Kesselburg")
        let board = SportChannelBoard(fromNames: ["arena1.de": ["soccer/ger.1"]])
        let channels = [SportChannel(id: "arena1.de", name: "ARENA BUNDESLIGA 1", epgID: "arena1.de")]

        let muted = SportMatch.events(
            fixtures: [fixture], programmes: [Self.broadcast("BL", channels: "arena1.de")],
            channels: channels, board: board)
        #expect(muted.first?.epgIDs == ["arena1.de"])

        let speaks = SportMatch.events(
            fixtures: [fixture],
            programmes: [Self.broadcast("Tannfeld - Weserau", channels: "arena1.de")],
            channels: channels, board: board)
        #expect(speaks.isEmpty)
    }
}
