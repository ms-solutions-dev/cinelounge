import Core
import Foundation
import SQLite3
import Testing

@testable import PlaylistKit

/// The kickoff-time source: fetch, count, store, find again — everything
/// against recorded answers (``SportRecording``), nothing against the network.
@Suite("Fixture source: fetch, counter and store")
struct SportFixtureSourceTests {

    /// Records whom the fetch asked — an actor, because the fetch runs across
    /// threads.
    actor Transcript {
        private(set) var asked: [String] = []
        func note(_ host: String) { asked.append(host) }
    }

    // MARK: - The user's benchmark

    /// **The three numbers by which this stage is measured.** The product
    /// requirement for 2026-08-29 names them: Süper Lig 3 matches,
    /// Bundesliga 6, Premier League 4. If something else stands here, either
    /// the fetch is broken or the parsing — and the test says which,
    /// because it records both ends of the same stretch.
    @Test("The user's benchmark: 3 / 6 / 4", arguments: SportRecording.all)
    func guidelineOfTheUser(_ recording: SportRecording) async {
        let result = await SportFixtureSource(fetch: recording.fetch)
            .fixtures(from: recording.day, days: 1, timeZone: recording.timeZone)
        func matches(_ path: String) -> Int {
            result.fixtures.count { $0.path == path }
        }
        for (path, count) in recording.expected.benchmark {
            #expect(matches(path) == count, "\(path)")
        }
        // All twenty competitions together on this one day.
        #expect(result.fixtures.count == recording.expected.fixturesToday)
        #expect(result.counter.source == .espn)
    }

    /// **The reach beyond the guide** (requirement of 2026-08-29: a
    /// three-day view). The provider's guide
    /// is a rolling 48-hour window and reaches about +24 h; the
    /// fixture source knows the schedules independently of that. The synthetic
    /// set: 28 fixtures on the day, 23 on the two days after it.
    @Test("Three days ahead, not just today", arguments: SportRecording.all)
    func threeDaysWide(_ recording: SportRecording) async {
        let source = SportFixtureSource(fetch: recording.fetch)
        let result = await source.fixtures(from: recording.day, timeZone: recording.timeZone)
        #expect(result.fixtures.count == recording.expected.fixturesThreeDays)
        #expect(result.counter.days == 3)

        let calendar = recording.calendar
        func onDay(_ offset: Int) -> Int {
            let start = calendar.date(byAdding: .day, value: offset, to: recording.day)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return result.fixtures.count { $0.start >= start && $0.start < end }
        }
        // Sorted by local time, not by the day stamp of the source:
        // a kickoff at 23:30 local time is still the previous day at ESPN.
        #expect(onDay(0) + onDay(1) + onDay(2) >= recording.expected.fixturesFirstThreeLocalDays)
        #expect(onDay(3) > 0, "the night matches of the third day fall into the fourth")
    }

    /// **Fetched concurrently, stored in order.** Five competitions are
    /// fetched at the same time — measured 11,2 s one after another against 2,5 s
    /// fivefold. Finishing concurrently, however, means finishing in any
    /// order, and a fixture list that is sorted differently on every run
    /// makes every number incomparable. That is why results are
    /// collected and ordered by the board.
    @Test("Fetched concurrently, stored in the order of the board", arguments: SportRecording.all)
    func orderStaysThatOfTheBoard(_ recording: SportRecording) async {
        let source = SportFixtureSource(fetch: recording.fetch)
        let a = await source.fixtures(from: recording.day, days: 3, timeZone: recording.timeZone)
        let b = await source.fixtures(from: recording.day, days: 3, timeZone: recording.timeZone)
        #expect(a.fixtures.map(\.id) == b.fixtures.map(\.id))

        // The competitions stand one after the other in the order of the board,
        // not interleaved.
        let rank = Dictionary(
            uniqueKeysWithValues: SportCompetition.all.enumerated().map { ($1.path, $0) })
        let ranks = a.fixtures.map { rank[$0.path]! }
        #expect(ranks == ranks.sorted())
    }

    // MARK: - The counter

    /// **The finding from the concept:** a dead league ID could not be told from an
    /// empty one — both answer with HTTP 200. At ESPN the
    /// state key separates the cases (400 against 200), at
    /// TheSportsDB nothing does. The counter keeps both apart and names
    /// every conspicuous competition by name.
    @Test("The counter separates empty from unknown", arguments: SportRecording.all)
    func counterSeparatesEmptyFromUnknown(_ recording: SportRecording) async {
        let result = await SportFixtureSource(fetch: recording.fetch)
            .fixtures(from: recording.day, days: 1, timeZone: recording.timeZone)
        let spec = result.counter
        #expect(spec.finding(forItem: "soccer/ger.1") == .fixtures(6))
        // Champions League and Europa League do not play this Saturday —
        // the source says so explicitly, and that is something different from
        // silence.
        #expect(spec.finding(forItem: recording.expected.emptyCompetition) == .empty)
        #expect(spec.hasAnswered == 20)
        #expect(spec.unknown.isEmpty)
        #expect(!spec.isFault)
        #expect(spec.report.contains("20 of 20 competitions"))
    }

    @Test("An unknown identifier stands out instead of silently missing", arguments: SportRecording.all)
    func unknownIdentifierStandsOut(_ recording: SportRecording) async {
        // How ESPN answers when a slug was renamed: HTTP 400.
        // Measured on 2026-08-29 at `soccer/ger.7` and `soccer/nonsense`.
        let recorded = recording.fetch
        let fetch: SportFixtureSource.Fetch = { address in
            if address.absoluteString.contains("soccer/ger.1") {
                return (Data("{}".utf8), 400)
            }
            return await recorded(address)
        }
        let spec = await SportFixtureSource(fetch: fetch).fixtures(
            from: recording.day, days: 1, timeZone: recording.timeZone
        ).counter
        #expect(spec.finding(forItem: "soccer/ger.1") == .unknownIdentifier)
        #expect(spec.unknown == ["Bundesliga"])
        #expect(spec.isFault)
        #expect(spec.report.contains("UNKNOWN IDENTIFIER: Bundesliga"))
    }

    // MARK: - The fallback

    /// **TheSportsDB asks only if ESPN does not answer at all** (addendum of
    /// 2026-08-29). Not additionally, not to fill up — a match-free
    /// Tuesday is an answer and does not wake the fallback.
    @Test("The fallback steps in only when ESPN is silent", arguments: SportRecording.all)
    func fallbackOnlyOnSilence(_ recording: SportRecording) async {
        let transcript = Transcript()
        let recorded = recording.fetch
        let listener: SportFixtureSource.Fetch = { address in
            await transcript.note(address.host ?? "")
            return await recorded(address)
        }
        _ = await SportFixtureSource(fetch: listener).fixtures(
            from: recording.day, days: 1, timeZone: recording.timeZone)
        #expect(
            await !transcript.asked.contains("www.thesportsdb.com"), "ESPN answered")

        let result = await SportFixtureSource(fetch: recording.muted).fixtures(
            from: recording.day, days: 1, timeZone: recording.timeZone)
        #expect(result.counter.source == .tsdb)
        // The free key returns exactly the next fixture per league —
        // one across a whole league, never a match day. Exactly for that reason ESPN now leads.
        #expect(result.fixtures.count == recording.expected.fallbackFixtures)
        #expect(result.fixtures.allSatisfy { $0.source == .tsdb })
    }

    /// **`events: null` stays ambiguous at TheSportsDB, and that deserves
    /// saying.** Both sets carry one such case with the FA Cup:
    /// HTTP 200, no fixture. Whether the league is paused or the ID is dead,
    /// nobody can decide from here.
    @Test("In the fallback empty stays indistinguishable from dead", arguments: SportRecording.all)
    func fallbackCannotTellEmptyFromDead(_ recording: SportRecording) async {
        let spec = await SportFixtureSource(fetch: recording.muted).fixtures(
            from: recording.day, days: 1, timeZone: recording.timeZone
        ).counter
        #expect(spec.finding(forItem: recording.expected.fallbackEmpty) == .empty)
        #expect(spec.unknown.isEmpty)
    }

    // MARK: - Die Auswertung

    @Test("A response of the source becomes fixtures", arguments: SportRecording.all)
    func responseBecomesFixtures(_ recording: SportRecording) throws {
        let expected = recording.expected
        let file = recording.espnFolder.appendingPathComponent(expected.responseFile)
        let competition = SportCompetition.using(path: "soccer/ger.1")!
        let reply = try #require(
            ESPNScoreboard.read(try Data(contentsOf: file), competition: competition))

        #expect(reply.league == expected.responseLeague)
        // The short form is the word that E7 searches for in channel names.
        #expect(reply.short == expected.responseShort)
        #expect(reply.fixtures.count == expected.responseCount)

        let first = try #require(reply.fixtures.first)
        #expect(first.id == expected.responseFirstID)
        #expect(first.path == "soccer/ger.1")
        #expect(first.source == .espn)
        #expect(first.home == expected.responseFirstHome)
        #expect(first.away == expected.responseFirstAway)
        // "…T13:30Z" — without seconds, in UTC.
        #expect(first.start == Date(timeIntervalSince1970: expected.responseFirstStart))
        // The further spellings that the source supplies.
        for variant in expected.responseHomeVariants {
            #expect(first.homeVariantsList.contains(variant), "\(variant)")
        }
    }

    @Test("Both sources prefix their identifiers")
    func identifiersCarryTheirOrigin() throws {
        let json = """
            {"events":[{"idEvent":"2274671","strLeague":"Turkish Super Lig",
            "strHomeTeam":"İnciköy Başakvadi","strAwayTeam":"Tepelispor",
            "strTimestamp":"2026-08-16T16:00:00"},
            {"idEvent":"kaputt","strHomeTeam":"","strAwayTeam":"X","strTimestamp":"2026-08-16T16:00:00"}]}
            """
        let competition = SportCompetition.using(path: "soccer/tur.1")!
        let fixtures = SportFixtureSource.parsed(Data(json.utf8), competition: competition)

        #expect(fixtures.count == 1, "the broken entry without a home team drops out")
        #expect(fixtures.first?.id == "tsdb#2274671")
        #expect(fixtures.first?.home == "İnciköy Başakvadi")
        #expect(fixtures.first?.kind == .football)
        // The stamp is UTC: 16:00Z, independent of the device's zone.
        #expect(fixtures.first?.start.timeIntervalSince1970 == 1_786_896_000)
    }

    // MARK: - Die Ablage

    @Test("Fixtures survive the store — with their origin")
    func fixturesSurviveTheStore() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixtures-\(UUID().uuidString)")
        let cache = LiveCache(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Rounded to the second: the store stamps in whole
        // seconds, a fraction does not survive it.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let fixture = SportFixture(
            id: "espn#1", source: .espn, path: "soccer/tur.1", kind: .football,
            league: "Turkish Super Lig", home: "Gökyamaç", away: "Dumanspor",
            start: now.addingTimeInterval(3600),
            homeVariantsList: ["Gokyamac", "GOK"], awayVariantsList: ["Duman"])
        await cache.save(fixtures: [fixture], of: .espn)

        let found = await cache.fixtures(from: now, to: now.addingTimeInterval(7200))
        #expect(found == [fixture], "everything comes back, including origin and spellings")
        #expect(await cache.fixtureCount() == 1)

        // The next sync of the same source replaces its catalog.
        await cache.save(
            fixtures: [
                SportFixture(
                    id: "espn#2", source: .espn, path: "basketball/nba", kind: .basketball,
                    league: "NBA", home: "Sunhawks", away: "Pinecrests",
                    start: now.addingTimeInterval(1800))
            ], of: .espn)
        #expect(
            await cache.fixtures(from: now, to: now.addingTimeInterval(7200)).map(\.id)
                == ["espn#2"])
    }

    /// **The reach of the fixtures is a number of its own** — and the reason
    /// why the third tab exists again (finding of 2026-08-29).
    ///
    /// The guide of this provider is a rolling 48-hour window;
    /// the fixture source has been asked over three days since E6. Whoever derives the
    /// day tabs from ``LiveLibrary/DownloadsState/newest``
    /// gives away exactly these days. It is therefore tested that the download state
    /// carries **both** reaches and does not confuse them.
    @Test("The cache state carries the reach of the fixtures separately")
    @MainActor
    func downloadsStateCarriesTheFixtures() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminspanne-\(UUID().uuidString)")
        let cache = LiveCache(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Without fixtures the span is empty — and does not report 1970.
        #expect(await cache.fixtureSpan().count == 0)
        #expect(await cache.fixtureSpan().newest == nil)

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let late = now.addingTimeInterval(2 * 86_400)
        func fixture(_ identifier: String, _ start: Date) -> SportFixture {
            SportFixture(
                id: identifier, source: .espn, path: "soccer/ger.1", kind: .football,
                league: "German Bundesliga", home: "Bergland", away: "Union", start: start)
        }
        await cache.save(
            fixtures: [fixture("espn#1", now), fixture("espn#2", late)], of: .espn)

        let span = await cache.fixtureSpan()
        #expect(span.count == 2)
        #expect(span.newest == late, "the LATEST kickoff, not the first")

        // And the library passes on both separately: the programme store
        // is empty here, the fixtures reach two days. Exactly this situation
        // the viewer had on the TV.
        let library = LiveLibrary(
            store: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            cache: cache)
        let state = await library.downloadsState(from: now, to: late)
        #expect(state.broadcasts == 0)
        #expect(state.newest == nil)
        #expect(state.fixtures == 2)
        #expect(state.fixturesNewest == late)
    }

    /// **The trap the concept warns of — sprung here and
    /// reproduced.** Until E6 the table `fixtures` was created with
    /// `CREATE TABLE IF NOT EXISTS` **outside** the version check. Appending
    /// columns there stays ineffective on every existing database: the
    /// extended INSERT fails, ``LiveCache/save(fixtures:of:)`` bails out
    /// silently, and on every device that already had the app the
    /// fixtures would vanish silently — while on the Mac, where the database is
    /// created fresh, everything would stay green.
    ///
    /// This test builds a database in the old form (version 3, old
    /// `fixtures` table with one row in it) and lets ``LiveCache`` open it.
    /// Without its own version stage it is red.
    @Test("An existing database gets the new fixture shape")
    func oldDatabaseIsLifted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("alt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var db: OpaquePointer?
        let file = folder.appendingPathComponent("cinelounge-live.sqlite")
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        for command in [
            "PRAGMA user_version=3;",
            "CREATE TABLE fixtures (id TEXT PRIMARY KEY, sport TEXT NOT NULL, "
                + "league TEXT NOT NULL, home TEXT NOT NULL, away TEXT NOT NULL, "
                + "start INTEGER NOT NULL);",
            "INSERT INTO fixtures VALUES ('2274671','football','Süper Lig','A','B',1788010200);",
        ] {
            #expect(sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)

        let cache = LiveCache(directory: folder)
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let fixture = SportFixture(
            id: "espn#1", source: .espn, path: "soccer/ger.1", kind: .football,
            league: "German Bundesliga", home: "Union Kesselburg", away: "Talstadt",
            start: now.addingTimeInterval(3600), homeVariantsList: ["FCU"])
        await cache.save(fixtures: [fixture], of: .espn)

        // The old row is gone — fixtures are a cache —, the new one is there,
        // complete, with origin and spellings.
        #expect(await cache.fixtureCount() == 1)
        let found = await cache.fixtures(from: now, to: now.addingTimeInterval(7200))
        #expect(found == [fixture])
    }

    /// **Version 5 lifts a database that already had version 4** (E7).
    ///
    /// The dangerous case is not the empty folder — there everything is created
    /// fresh and everything is green. It is the database that already exists: it
    /// carries `fixtures` **without** the column `league_short`, and without the
    /// version stage every INSERT would fail silently, ``LiveCache/save(fixtures:of:)``
    /// would bail out, and on the device the fixtures would vanish silently. This
    /// very trap has sprung once before in E6; the test above
    /// reproduces it for version 3, this one for version 4.
    @Test("Version 5 lifts a database of version 4")
    func versionFiveLiftsFour() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("v4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var db: OpaquePointer?
        let file = folder.appendingPathComponent("cinelounge-live.sqlite")
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        for command in [
            "PRAGMA user_version=4;",
            "CREATE TABLE fixtures (id TEXT PRIMARY KEY, source TEXT NOT NULL, "
                + "slug TEXT NOT NULL, sport TEXT NOT NULL, league TEXT NOT NULL, "
                + "home TEXT NOT NULL, away TEXT NOT NULL, home_alt TEXT, away_alt TEXT, "
                + "start INTEGER NOT NULL);",
            "INSERT INTO fixtures VALUES ('espn#alt','espn','soccer/ger.1','football',"
                + "'German Bundesliga','A','B',NULL,NULL,1788010200);",
        ] {
            #expect(sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)

        let cache = LiveCache(directory: folder)
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let fixture = SportFixture(
            id: "espn#1", source: .espn, path: "soccer/eng.2", kind: .football,
            league: "English League Championship", leagueShort: "EFL Championship",
            home: "Dunmore County", away: "Swanmere City", start: now.addingTimeInterval(3600))
        await cache.save(fixtures: [fixture], of: .espn)

        // The short form of the source survives the trip through the database — without
        // it the channel board would have no vocabulary.
        let found = await cache.fixtures(from: now, to: now.addingTimeInterval(7200))
        #expect(found == [fixture])
        #expect(found.first?.leagueShort == "EFL Championship")

        // And the new board is there, writes and ages.
        #expect(await cache.channelCompetitions().isEmpty)
        let row = ChannelCompetition(
            channels: "arenabundesliga1.de", path: "soccer/ger.1", match: 3,
            firstSeen: now.addingTimeInterval(-14 * 24 * 3600), recent: now)
        await cache.setChannelCompetitions([row])
        #expect(await cache.channelCompetitions() == [row])
        // The whole catalog is written: deleting the aged entries is
        // half the rule, and a partial write would have to make that up.
        await cache.setChannelCompetitions([])
        #expect(await cache.channelCompetitions().isEmpty)
    }

    /// **Two sources with raw IDs collide silently.** Without a prefix and
    /// without an origin column, one source would overwrite the row of the other:
    /// the catalog would stay complete, only the content of one row
    /// would change, and nobody would see it.
    @Test("The sources do not delete each other")
    func sourcesDoNotDeleteEachOther() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixtures-\(UUID().uuidString)")
        let cache = LiveCache(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let now = Date()
        func fixture(_ id: String, _ source: SportFixtureProvider) -> SportFixture {
            SportFixture(
                id: source.prefix + id, source: source, path: "soccer/ger.1", kind: .football,
                league: "Bundesliga", home: "Bergland", away: "Erzfeld",
                start: now.addingTimeInterval(600))
        }
        await cache.save(fixtures: [fixture("7", .espn)], of: .espn)
        await cache.save(fixtures: [fixture("7", .tsdb)], of: .tsdb)

        #expect(await cache.fixtureCount() == 2, "the same raw number, two rows")
        #expect(await cache.fixtureCount(of: .espn) == 1)
        #expect(await cache.fixtureCount(of: .tsdb) == 1)

        await cache.removeFixtures(of: .tsdb)
        #expect(await cache.fixtureCount() == 1)
        #expect(await cache.fixtureCount(of: .espn) == 1)
    }
}
