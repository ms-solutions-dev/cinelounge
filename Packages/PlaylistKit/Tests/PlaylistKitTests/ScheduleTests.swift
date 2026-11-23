import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The broadcast plan: from the source to the row.
///
/// **The user's draft (2026-08-29):** if ESPN says a club plays
/// tomorrow, and the Turkish broadcast plan says it runs on a certain channel, and the
/// user has that channel, that counts as a hit. An IPTV EPG cannot be fully
/// trusted to be correct.
///
/// Calculation runs against the plan of the recorded day (``SportRecording``),
/// fixed clock, no network.
@Suite("Broadcast plan: source, join and evidence")
struct ScheduleTests {

    private func channels(_ id: String, _ name: String) -> SportChannel {
        SportChannel(id: id, name: name, epgID: id)
    }

    /// The fixture the Turkish match of the plan belongs to.
    static func turkishFixture(_ recording: SportRecording, offset: TimeInterval = 0) -> SportFixture {
        let expected = recording.expected
        return SportFixture(
            id: "espn#1", source: .espn, path: "soccer/tur.1", kind: .football,
            league: expected.turkishLeague, home: expected.turkishHome, away: expected.turkishAway,
            start: Date(timeIntervalSince1970: expected.turkishKickoff + offset))
    }

    // MARK: - Die Quelle lesen

    /// **Shows are not matches, and "no channel" is not a channel.** More than
    /// half the lines of the real plan were **shows** ("Gol Saati", "Maç Önü")
    /// — the source distinguishes this cleanly, and until the evening of the
    /// acceptance the parser did not ask for it. A handful of matches said "Yayın
    /// Yok" or "Yayıncı Belli Değil". The synthetic plan carries the same kinds of lines.
    @Test("The plan is read completely", arguments: SportRecording.all)
    func read(_ recording: SportRecording) {
        let slots = recording.slots

        #expect(slots.count == recording.expected.slots)
        #expect(slots.allSatisfy { $0.sportKind != nil })
        #expect(slots.allSatisfy { !$0.channels.isEmpty })
    }

    /// **"Yayın Yok" is not a channel.** The source lists matches without
    /// broadcast anyway and writes that in place of the channel.
    /// Taken over unfiltered, that would mean searching for a channel of this name.
    @Test("No channel means no broadcast slot", arguments: SportRecording.all)
    func noBroadcast(_ recording: SportRecording) {
        #expect(!recording.slots.contains { $0.channels.contains { $0.lowercased().contains("yayın") } })
    }

    /// The source writes `publishedOn` sometimes as an object, sometimes as a list — if
    /// a match runs on two channels, there is a list.
    @Test("Several channels for one match all arrive", arguments: SportRecording.all)
    func multipleChannels(_ recording: SportRecording) {
        let using = recording.slots.filter { $0.channels.count > 1 }

        #expect(!using.isEmpty, "the plan contains such cases")
        #expect(using.contains { $0.match.contains(recording.expected.multiChannelMatch) })
    }

    /// The local time in Turkey is three hours earlier in UTC.
    @Test("The kickoff is read with its zone offset", arguments: SportRecording.all)
    func kickoff(_ recording: SportRecording) throws {
        let expected = recording.expected
        let match = try #require(recording.slots.first { $0.match.contains(expected.turkishHome) })

        #expect(match.kickoff.timeIntervalSince1970 == expected.turkishKickoff)
        #expect(match.channels.contains(expected.turkishChannel))
    }

    /// **The sport comes from the source, not from a guess.**
    /// On-device finding 2026-08-29, 22:00: a water polo match of the national team
    /// was shown under football, because the parser read only the `schema.org`
    /// data. The same nation plays twice on the day, in two sports — that the source
    /// knows which is which is the whole gain of this switch. (This check was wrong
    /// at first because it had been guessed.)
    @Test("Every row carries the sport the source names", arguments: SportRecording.all)
    func sportKindFromSource(_ recording: SportRecording) throws {
        let expected = recording.expected
        let all = recording.slots
        let waterPolo = try #require(all.first { $0.match == expected.waterPolo })
        let volleyball = try #require(all.first { $0.match == expected.volleyball })

        #expect(waterPolo.sportKind == "Sutopu")
        #expect(volleyball.sportKind == "Voleybol")
        #expect(volleyball.competition == expected.volleyballCompetition)

        let kinds = Set(all.compactMap(\.sportKind))
        #expect(kinds.count > 5, "the plan contains many sports")
    }

    /// **Shows are not matches.** The source distinguishes `match` from
    /// `commentary`.
    @Test("Broadcasts do not stand between the matches", arguments: SportRecording.all)
    func noBroadcasts(_ recording: SportRecording) {
        let title = Set(recording.slots.map(\.match))

        for show in recording.expected.shows {
            #expect(!title.contains(show), "\(show)")
        }
    }

    /// On the TV the whole page arrives, in the test a reduced one
    /// with the same two blocks. Both paths go through the same parser.
    @Test("Both blocks are fetched from one page")
    func fromHTML() {
        let page = """
            <html><head><script type="application/ld+json">
            [{"broadcastOfEvent":{"name":"A - B",
            "startDate":"2026-08-29T19:00:00+03:00",
            "endDate":"2026-08-29T21:00:00+03:00"}}]
            </script><script>window.__INITIAL_STATE__ = {"common":{"events":[
            {"sport_name":"Futbol","league_name":"Testliga","event_type_name":"match",
            "name":"A - B","date_time":"2026-08-29 19:00:00","home_name":"A",
            "away_name":"B","channels":[{"name":"Arena Spor 1","active":1}]}]}}
            </script></head><body>x</body></html>
            """

        let read = SporEkraniSource.read(Data(page.utf8))

        #expect(read.count == 1)
        #expect(read.first?.channels == ["Arena Spor 1"])
        #expect(read.first?.sportKind == "Futbol")
        #expect(read.first?.competition == "Testliga")
        // The end comes from the second block — the state names none.
        #expect(read.first?.end?.timeIntervalSince1970 == 1_788_026_400)
    }

    /// A web page can change its shape. Then the source stays silent instead of
    /// guessing — the schedule keeps what it knew before.
    @Test("Without a readable block nothing comes back")
    func broken() {
        #expect(SporEkraniSource.read(Data("<html>nichts</html>".utf8)).isEmpty)
        #expect(SporEkraniSource.read(Data()).isEmpty)
    }

    // MARK: - Der Join

    @Test("The fixture finds its broadcast slot via the teams", arguments: SportRecording.all)
    func joinOnFixture(_ recording: SportRecording) throws {
        let fixture = Self.turkishFixture(recording)

        let slot = try #require(
            SportBroadcastPlan.broadcastSlot(forItem: fixture, in: recording.slots))

        #expect(slot.channels == [recording.expected.turkishChannel])
    }

    /// **The kickoff separates.** On a match day several matches of
    /// the same league kick off; a widely drawn span would start to guess, and
    /// telling exactly these apart is the purpose of this source.
    @Test("An hour off is not a hit", arguments: SportRecording.all)
    func kickoffSeparates(_ recording: SportRecording) {
        let fixture = Self.turkishFixture(recording, offset: 3600)

        #expect(SportBroadcastPlan.broadcastSlot(forItem: fixture, in: recording.slots) == nil)
    }

    /// **The channel name is the join onto the channel list** — "Arena Spor 1"
    /// from the source against "TR: ARENA SPOR 1 HD" from the provider.
    @Test("The channel name hits the viewer's list")
    func joinOnChannelList() {
        let slot = SportBroadcastPlan.BroadcastSlot(
            match: "Tarlaspor - Tepelispor", home: "Tarlaspor", away: "Tepelispor",
            kickoff: Date(timeIntervalSince1970: 1_788_019_200), channels: ["Arena Spor 1"])

        let found = SportBroadcastPlan.key(
            forItem: slot,
            in: [
                channels("arenaspor1.tr", "TR: ARENA SPOR 1 HD"),
                channels("arenaspor2.tr", "TR: ARENA SPOR 2 HD"),
                channels("ahorn.de", "DE: DAS NORDLICHT HD"),
            ])

        #expect(found == ["arenaspor1.tr"])
    }

    /// **Word boundaries, otherwise "Arena Spor 1" would also hit "Arena Spor 10".**
    @Test("A longer number is not a hit")
    func wordBoundary() {
        let slot = SportBroadcastPlan.BroadcastSlot(
            match: "A - B", home: nil, away: nil,
            kickoff: Date(timeIntervalSince1970: 1_788_019_200), channels: ["Arena Spor 1"])

        let found = SportBroadcastPlan.key(
            forItem: slot, in: [channels("arena10.tr", "TR: ARENA SPOR 10 HD")])

        #expect(found.isEmpty)
    }

    /// A very short channel name would hit every second channel in the list. A
    /// hit that separates nothing is worse than none.
    @Test("Channel names that are too short are not searched at all")
    func tooShort() {
        let slot = SportBroadcastPlan.BroadcastSlot(
            match: "A - B", home: nil, away: nil,
            kickoff: Date(timeIntervalSince1970: 1_788_019_200), channels: ["S"])

        #expect(SportBroadcastPlan.key(forItem: slot, in: [channels("x.tr", "TR: KULE SPORT")]).isEmpty)
    }
}

/// What the broadcast plan moves on the finished schedule — on the recorded
/// day, fixed clock, no network.
///
/// **The number that matters:** on the real Saturday sixteen channels hung on one
/// Bundesliga match, because on all league channels at kickoff time there was
/// nothing but "BL". For the Turkish matches there is now a
/// source that answers the question.
@Suite("What the broadcast plan moves on the schedule")
struct ScheduleMeasurementTests {

    static func events(
        _ recording: SportRecording, plan: Bool = true
    ) async -> [SportEvent] {
        SportMatch.events(
            fixtures: await recording.fixtures(days: 3), programmes: recording.dayWindow,
            channels: recording.sportChannels, broadcastPlan: plan ? recording.slots : [])
    }

    @Test("A Turkish match gets exactly its channel", arguments: SportRecording.all)
    func oneGameOneChannel(_ recording: SportRecording) async throws {
        let expected = recording.expected
        let using = await Self.events(recording)

        let match = try #require(using.first { $0.title.contains(expected.turkishHome) })

        #expect(match.epgIDs == [expected.turkishEPG], "exactly one, not a bundle")
        #expect(match.isVerified)
        #expect(match.evidence == .broadcastPlan)
    }

    /// **The origin of the evidence is carried along**, so that it can later be measured
    /// how often the guide contradicts the broadcast plan — instead of
    /// guessing. Requirement from 2026-08-29: an IPTV EPG cannot be fully
    /// trusted to be correct.
    @Test("Every sealed row says where its evidence comes from", arguments: SportRecording.all)
    func originIsAttached(_ recording: SportRecording) async {
        let using = await Self.events(recording)

        #expect(using.allSatisfy { $0.isVerified == ($0.evidence != nil) })

        let fromSchedule = using.count { $0.evidence == .broadcastPlan }
        let fromMagazine = using.count { $0.evidence == .magazine }
        print(
            """
            Broadcast plan on the schedule (\(recording.name))
              rows total:           \(using.count)
              sealed:               \(using.count { $0.isVerified })
                from the broadcast plan: \(fromSchedule)
                from the program guide:  \(fromMagazine)
              channels per row (max): \(using.map(\.epgIDs.count).max() ?? 0)
            """)
        #expect(fromSchedule > 0, "the source must contribute something")
    }

    /// **Where the source answers, it alone counts.** Its channels replace the
    /// expectations instead of joining them — exactly the difference
    /// from the sixteen channels of a Bundesliga match.
    @Test("The broadcast plan replaces the bundle instead of supplementing it", arguments: SportRecording.all)
    func replacesTheBundle(_ recording: SportRecording) async throws {
        let without = await Self.events(recording, plan: false)
        let using = await Self.events(recording)

        let turkish = { (list: [SportEvent]) in
            list.filter { $0.competitionPath == "soccer/tur.1" }
        }
        let previous = turkish(without).map(\.epgIDs.count).max() ?? 0
        let after = turkish(using).map(\.epgIDs.count).max() ?? 0
        print("Super Lig, channels per row: at most \(previous) -> at most \(after)")

        #expect(after <= previous)
    }
}

/// The broadcast plan as a **source**, not only as a confirmation.
///
/// **On-device finding 2026-08-29, 21:00:** the Turkish broadcast plan offers much,
/// much more than what we cover — matches of the second tier do not appear in
/// our list at all, although the channels are there.
@Suite("The broadcast plan brings rows of its own")
struct ScheduleAsSourceTests {

    @Test("The missed matches are in the list now", arguments: SportRecording.all)
    func missingMatchups(_ recording: SportRecording) async {
        let using = await ScheduleMeasurementTests.events(recording)

        let title = Set(using.map(\.title))
        for own in recording.expected.ownTitles {
            #expect(title.contains(own), "\(own)")
        }
    }

    /// **Six lines that nobody else finds.** The fixture source knows
    /// twenty competitions; the second Turkish tier is not among them, volleyball
    /// neither. And the guide did not help out there: at kickoff it named only the
    /// league, or nothing at all.
    @Test("The broadcast plan brings six rows that no fixture covers", arguments: SportRecording.all)
    func sixRowsMore(_ recording: SportRecording) async {
        let without = await ScheduleMeasurementTests.events(recording, plan: false)
        let using = await ScheduleMeasurementTests.events(recording)

        #expect(using.count == without.count + recording.expected.ownRows)
        #expect(using.count { $0.id.hasPrefix("sendeplan#") } == recording.expected.ownRows)
    }

    /// Every own line is sealed — it has a pairing, kickoff and a
    /// channel that the viewer really has. There is no more evidence than that.
    @Test("Own rows are sealed and name their origin", arguments: SportRecording.all)
    func ownRowsAreVerified(_ recording: SportRecording) async {
        let using = await ScheduleMeasurementTests.events(recording)

        let own = using.filter { $0.id.hasPrefix("sendeplan#") }
        let sealed = own.filter(\.isVerified).count
        let fromTheSource = own.filter { $0.evidence == .broadcastPlan }.count
        let withChannels = own.filter { !$0.epgIDs.isEmpty }.count

        #expect(sealed == own.count)
        #expect(fromTheSource == own.count)
        #expect(withChannels == own.count)
    }

    /// **The end comes from the source**, not from an assumption.
    @Test("The broadcast duration comes from the source", arguments: SportRecording.all)
    func durationFromSource(_ recording: SportRecording) async throws {
        let using = await ScheduleMeasurementTests.events(recording)
        let title = try #require(recording.expected.ownTitles.first)

        let row = try #require(using.first { $0.title == title })
        let slot = try #require(recording.slots.first { $0.match == title })

        #expect(row.end == slot.end)
        #expect(row.end != row.start.addingTimeInterval(2 * 3600))
    }

    /// A match that a fixture already carries does not come a second time.
    @Test("No row appears twice", arguments: SportRecording.all)
    func noDuplicates(_ recording: SportRecording) async {
        let using = await ScheduleMeasurementTests.events(recording)

        #expect(Set(using.map(\.id)).count == using.count)
        #expect(
            !using.contains {
                $0.id.hasPrefix("sendeplan#") && $0.title.contains(recording.expected.turkishHome)
            })
    }
}

/// The store — **there and back**.
///
/// **This test was missing, and that cost something.** When converting to version
/// 9, `end` was added as a third column; the bindings stayed where they
/// were. The home name landed in `end`, `away` stayed empty, and on reading
/// the text became the number 0 — every row from the broadcast plan ended in
/// 1970 and fell out of the day list. On the device this looked as if the
/// sports area were not updating at all (finding 2026-08-29, 21:25).
///
/// The measurement did not catch it: it calculates on the freshly read
/// broadcast slots, never on the stored ones. And the diagnostic line counted what was
/// **fetched**, not what lies in the database — exactly the
/// mix-up that on 2026-08-16 had already sent a troubleshooting session in the
/// wrong direction in this project.
@Suite("The broadcast plan survives the store")
struct ScheduleStoreTests {

    private func fresh() -> (LiveCache, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sendeplan-\(UUID().uuidString)")
        return (LiveCache(directory: folder), folder)
    }

    @Test("Every field comes back unchanged")
    func thereAndBack() async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        let full = SportBroadcastPlan.BroadcastSlot(
            match: "Tarlaspor - Tepelispor", home: "Tarlaspor", away: "Tepelispor",
            kickoff: Date(timeIntervalSince1970: 1_788_019_200),
            channels: ["Arena Spor 1", "Kanal Spor"],
            end: Date(timeIntervalSince1970: 1_788_030_000), land: "tr")
        let tight = SportBroadcastPlan.BroadcastSlot(
            match: "A - B", home: nil, away: nil,
            kickoff: Date(timeIntervalSince1970: 1_788_019_300), channels: ["X TV"])

        await cache.setBroadcastSlots([full, tight])
        let back = await cache.broadcastSlots()

        #expect(back == [full, tight])
    }

    /// The whole plan through the store — the same number in as
    /// out, and **every end time preserved**.
    @Test("The whole plan survives the store", arguments: SportRecording.all)
    func wholeRecording(_ recording: SportRecording) async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        let slots = recording.slots
        await cache.setBroadcastSlots(slots)
        let back = await cache.broadcastSlots()

        #expect(back.count == slots.count)
        let withEnd = back.filter { $0.end != nil }.count
        #expect(withEnd == slots.filter { $0.end != nil }.count)
        // And no end time lies in the past of 1970 — the bug
        // this test caught.
        #expect(back.allSatisfy { ($0.end ?? $0.kickoff) > $0.kickoff.addingTimeInterval(-1) })
    }

    /// An empty plan is not written: "The source does not answer today"
    /// must not have the same effect as "nobody broadcasts today".
    @Test("An empty plan does not delete the existing one")
    func emptyPlanDoesNotDelete() async {
        let (cache, folder) = fresh()
        defer { try? FileManager.default.removeItem(at: folder) }

        let slot = SportBroadcastPlan.BroadcastSlot(
            match: "A - B", home: nil, away: nil,
            kickoff: Date(timeIntervalSince1970: 1_788_019_200), channels: ["X TV"])
        await cache.setBroadcastSlots([slot])
        await cache.setBroadcastSlots([])

        #expect(await cache.broadcastSlots() == [slot])
    }
}

/// The broadcast plan feeds the living board — **so that tomorrow carries what is
/// evidenced today**.
///
/// **User requirement 2026-08-29:** a solution that works exclusively in
/// the app, with no deviation to the home server or similar … Whoever gets the
/// application for IPTV may not run a home server at all.
///
/// The source delivers only today, and nothing can be done about that —
/// its day tabs are filled only by a browser. What is evidenced today can,
/// however, carry tomorrow: "this channel showed the Süper Lig" is a fact
/// about the **channel**, not about the match.
@Suite("The broadcast plan writes into the channel board")
struct ScheduleLearnsTests {

    private func channels(_ id: String, _ name: String) -> SportChannel {
        SportChannel(id: id, name: name, epgID: id)
    }

    /// The Turkish channel as the provider lists it: the display name mangled,
    /// the programme ID intact.
    private func mangled(_ recording: SportRecording) -> SportChannel {
        channels(recording.expected.turkishEPG, recording.expected.turkishMangledName)
    }

    @Test(
        "A broadcast slot becomes an observation, even without an entry in the program guide",
        arguments: SportRecording.all)
    func scheduleSlotWrites(_ recording: SportRecording) {
        let evidence = SportMatch.observations(
            fixtures: [ScheduleTests.turkishFixture(recording)], programmes: [],
            channels: [mangled(recording)],
            broadcastPlan: recording.slots)

        #expect(evidence.count == 1)
        #expect(evidence.first?.channels == recording.expected.turkishEPG)
        #expect(evidence.first?.path == "soccer/tur.1")
    }

    /// Without the broadcast plan it stays with the old path — and that finds
    /// nothing here, because the guide is empty. That is exactly the gain.
    @Test("Without a broadcast plan the observation does not exist", arguments: SportRecording.all)
    func nothingWithoutSchedule(_ recording: SportRecording) {
        #expect(
            SportMatch.observations(
                fixtures: [ScheduleTests.turkishFixture(recording)], programmes: [],
                channels: [mangled(recording)]
            ).isEmpty)
    }

    /// **No channel from the list, no observation.** What the viewer
    /// cannot receive says nothing about their channel list.
    @Test("A foreign channel is not remembered", arguments: SportRecording.all)
    func foreignChannelNot(_ recording: SportRecording) {
        #expect(
            SportMatch.observations(
                fixtures: [ScheduleTests.turkishFixture(recording)], programmes: [],
                channels: [channels("ahorn.de", "DE: DAS NORDLICHT HD")],
                broadcastPlan: recording.slots
            ).isEmpty)
    }

    /// **And tomorrow it carries.** Two days of broadcast plan, then a fixture
    /// finds its channel from the board alone — without guide, without source.
    @Test("After two days tomorrow's fixture finds its channel")
    func tomorrowCarriesIt() {
        let fixture = SportFixture(
            id: "espn#1", source: .espn, path: "soccer/tur.1", kind: .football,
            league: "Turkish Super Lig", home: "Tarlaspor", away: "Tepelispor",
            start: Date(timeIntervalSince1970: 1_788_019_200))
        let list = [channels("arenaspor1.tr", "TR: A**** S*** 1 RAW")]
        var catalog: [ChannelCompetition] = []
        for tag in 0..<SportChannelBoard.minimumDays {
            let postponed = SportFixture(
                id: "espn#\(tag)", source: .espn, path: "soccer/tur.1", kind: .football,
                league: "Turkish Super Lig", home: "Tarlaspor", away: "Tepelispor",
                start: fixture.start.addingTimeInterval(Double(tag) * -86_400))
            let slot = SportBroadcastPlan.BroadcastSlot(
                match: "Tarlaspor - Tepelispor", home: "Tarlaspor", away: "Tepelispor",
                kickoff: postponed.start, channels: ["Arena Spor 1"], land: "tr")
            catalog = SportChannelBoard.merged(
                catalog: catalog,
                fresh: SportMatch.observations(
                    fixtures: [postponed], programmes: [], channels: list, broadcastPlan: [slot]))
        }

        let board = SportChannelBoard(observations: catalog)
        let tomorrow = SportFixture(
            id: "espn#morgen", source: .espn, path: "soccer/tur.1", kind: .football,
            league: "Turkish Super Lig", home: "Kalesaray", away: "Yesiltas",
            start: fixture.start.addingTimeInterval(86_400))

        // No broadcast plan, no guide — only the board.
        let rows = SportMatch.events(
            fixtures: [tomorrow], programmes: [], channels: list, board: board)

        #expect(rows.count == 1)
        #expect(rows.first?.epgIDs == ["arenaspor1.tr"])
        #expect(rows.first?.isVerified == false, "an expectation, not evidence")
    }
}
