import Core
import Foundation

/// Fetches the scheduled matches — the kickoff-time source of the schedule.
///
/// **ESPN leads, TheSportsDB falls back** (addendum of 2026-08-29 to the
/// sports concept). The concept had ESPN as a *second* source alongside; the
/// product decision reversed that, and the measurement backs it: ESPN hits its
/// benchmarks for 2026-08-29 exactly (Süper Lig 3, Bundesliga 6, Premier League
/// 4) and delivers the full matchday, while TheSportsDB with the free key gives
/// **one** fixture per league.
///
/// **TheSportsDB stays anyway.** ESPN is an undocumented
/// interface without guaranteed availability; it can vanish without notice.
/// The fallback is built, costs nothing as long as it stays
/// silent, and asks **only** when ESPN does not answer at all — not
/// additionally and not to top up. A Tuesday without matches is an
/// answer and does not wake it (``FixtureTally/hasAnswered``).
///
/// **The league list is not here.** It lives in ``SportCompetition`` —
/// once, with the EPG vocabulary next to it. Exactly the drifting apart of the
/// two old lists is the finding the single board is meant to fix.
public struct SportFixtureSource: Sendable {

    /// One fetch: address in, response and state key out.
    ///
    /// **Why injected and not taken:** No test in this project
    /// may touch the network. The recordings in the test fixtures come in as such a
    /// fetch, and so the test runs the same path as on the
    /// TV — same address building, same counting, same
    /// merging. `nil` means "no response" and is something other than
    /// a response with an error key.
    public typealias Fetch = @Sendable (URL) async -> (bytes: Data, status: Int)?

    /// What one pass yields.
    public struct Outcome: Sendable {
        public let fixtures: [SportFixture]
        public let counter: FixtureTally
    }

    /// How far into the future fixtures are fetched.
    ///
    /// **Three days, and that is the point** (requirement of 2026-08-29: a three-day
    /// view). The provider's guide is a rolling 48-hour window and reaches about +24 h — which is why the
    /// area has had only two tabs since E3. ESPN knows the fixtures independently
    /// of that. What is fetched here thus reaches further than the guide;
    /// **which channel belongs to it is answered by E7**, and until then
    /// a fixture without a broadcast stays without a row. No channel is invented.
    public static let reach = 3

    private let apiKey: String
    private let fetch: Fetch

    public init(session: URLSession = .shared, store: any KeyValueStore = SecureStore()) {
        apiKey = Self.storedKey(from: store)
        fetch = { address in
            guard let (bytes, reply) = try? await session.data(from: address) else { return nil }
            return (bytes, (reply as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// For the test bench: the recording instead of the network.
    init(fetch: @escaping Fetch, apiKey: String = "123") {
        self.apiKey = apiKey
        self.fetch = fetch
    }

    /// The access key of the fallback.
    ///
    /// "123" is the free identifier — it delivers only the next fixture per league
    /// (measured on 2026-08-29: 19 fixtures across 20 leagues). A key of one's own
    /// is stored under this store key; the store
    /// exists so that the switch needs no new version. It is still
    /// not writable from anywhere — the concept openly calls that a
    /// false promise and leaves the decision about it open.
    static let keyStorageKey = "spielplan.quelle.schluessel"

    static func storedKey(from store: any KeyValueStore) -> String {
        guard let stored = try? store.value(for: keyStorageKey), !stored.isEmpty else {
            return "123"
        }
        return stored
    }

    // MARK: - Der Abruf

    /// How many competitions are fetched at the same time.
    ///
    /// **Measured on 2026-08-29 against the real interface:** The 60 fetches
    /// (20 competitions × 3 days) take **11.2 s** one after another, **2.5 s** with five
    /// concurrent. One after another, that is the most noticeable lengthening
    /// of the refresh that this stage would bring — before, it was 20
    /// fetches to one source.
    ///
    /// Five and not twenty: The service is undocumented and free,
    /// and twenty simultaneous requests to someone else's server are not
    /// thrift but an imposition. The gain between five and more
    /// is down to latency anyway, not bandwidth.
    static let concurrently = 5

    /// All fixtures of the tapped competitions, ``reach`` days ahead.
    ///
    /// - Parameter ab: The first day. Passed in clock-free so that the
    ///   test computes on the day of the recording and not on today.
    public func fixtures(
        from start: Date, days: Int = SportFixtureSource.reach,
        timeZone: TimeZone = .current
    ) async -> Outcome {
        let stamp = Self.dayStamps(from: start, days: days, timeZone: timeZone)
        let harvested = await inParallel { competition in
            await self.espn(competition, days: stamp)
        }
        var counter = FixtureTally(source: .espn, days: stamp.count)
        var found: [SportFixture] = []
        for competition in SportCompetition.all {
            guard let harvest = harvested[competition.path] else { continue }
            counter.set(harvest.finding, forItem: competition.path)
            found.append(contentsOf: harvest.fixtures)
        }

        guard counter.hasAnswered == 0 else {
            return Outcome(fixtures: found, counter: counter)
        }
        // ESPN is completely silent. Only now the fallback.
        return await fallback(days: stamp.count)
    }

    /// One competition, all its days.
    private func espn(
        _ competition: SportCompetition, days: [String]
    ) async -> (finding: FixtureTally.Finding, fixtures: [SportFixture]) {
        var finding = FixtureTally.Finding.noResponse
        var found: [SportFixture] = []
        for day in days {
            guard let address = Self.espnAddress(competition, day) else { continue }
            guard let reply = await fetch(address) else { continue }
            // ESPN answers an unknown identifier with 400 — measured
            // on 2026-08-29 with `soccer/ger.7` and `soccer/nonsense`. The case
            // applies to all days alike, so it does not need the others.
            guard reply.status != 400, reply.status != 404 else {
                return (.unknownIdentifier, [])
            }
            guard reply.status == 200,
                let read = ESPNScoreboard.read(reply.bytes, competition: competition)
            else { continue }
            found.append(contentsOf: read.fixtures)
            finding = finding.and(day: read.fixtures.count)
        }
        return (finding, found)
    }

    /// Runs a job for every competition, at most ``concurrently``
    /// of them side by side.
    ///
    /// **The order of the result is that of the board, not that of
    /// chance.** Finishing concurrently means finishing in any
    /// order; otherwise the fixtures would go into the store sorted differently on every run,
    /// and no number would be comparable anymore.
    /// So the results are collected and afterwards ordered by the board.
    private func inParallel<Harvest: Sendable>(
        _ work: @escaping @Sendable (SportCompetition) async -> Harvest
    ) async -> [String: Harvest] {
        var result: [String: Harvest] = [:]
        await withTaskGroup(of: (String, Harvest).self) { group in
            var next = 0
            func trigger() {
                guard next < SportCompetition.all.count else { return }
                let competition = SportCompetition.all[next]
                next += 1
                group.addTask { (competition.path, await work(competition)) }
            }
            for _ in 0..<Self.concurrently { trigger() }
            while let (path, harvest) = await group.next() {
                result[path] = harvest
                trigger()
            }
        }
        return result
    }

    static func espnAddress(_ competition: SportCompetition, _ day: String) -> URL? {
        URL(
            string: "https://site.api.espn.com/apis/site/v2/sports/"
                + "\(competition.path)/scoreboard?dates=\(day)")
    }

    /// "20260829" for each of the days — the calendar of the device's time zone.
    static func dayStamps(from start: Date, days: Int, timeZone: TimeZone) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return (0..<max(days, 1)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start).map(formatter.string(from:))
        }
    }

    // MARK: - The fallback

    /// TheSportsDB, league by league — only if ESPN does not answer at all.
    ///
    /// **One request per league** (`eventsnextleague`): The day query of the
    /// free identifier is truncated, the league query is not. The obvious
    /// rebuild to `eventsday.php` was measured and rejected — it lowered the
    /// usable fixtures of the day from 14 to 0.
    ///
    /// This endpoint does not know a reach: It delivers the *next*
    /// fixtures, without a time window. That is why the tally holds the day count of the
    /// call and not that of the endpoint — a fallback with an
    /// invented window would be a lie about its own data.
    func fallback(days: Int) async -> Outcome {
        let harvested = await inParallel { competition -> [SportFixture]? in
            guard
                let address = URL(
                    string: "https://www.thesportsdb.com/api/v1/json/\(self.apiKey)"
                        + "/eventsnextleague.php?id=\(competition.tsdb)"),
                let reply = await self.fetch(address), reply.status == 200
            else { return nil }
            return Self.parsed(reply.bytes, competition: competition)
        }
        var counter = FixtureTally(source: .tsdb, days: days)
        var found: [SportFixture] = []
        for competition in SportCompetition.all {
            guard let fixtures = harvested[competition.path] ?? nil else {
                counter.set(.noResponse, forItem: competition.path)
                continue
            }
            found.append(contentsOf: fixtures)
            counter.set(
                fixtures.isEmpty ? .empty : .fixtures(fixtures.count), forItem: competition.path)
        }
        return Outcome(fixtures: found, counter: counter)
    }

    /// Reads the response of a league query at TheSportsDB.
    ///
    /// **`events: null` is ambiguous here and stays so.** The source
    /// answers with HTTP 200 and `null`, whether the league has a break or whether
    /// the identifier no longer exists — the recording in the test fixtures contains
    /// such a case with the FA Cup. For the fallback this is counted as "empty";
    /// nobody can tell the difference, and that deserves saying instead of
    /// guessing.
    static func parsed(_ data: Data, competition: SportCompetition) -> [SportFixture] {
        struct Payload: Decodable {
            struct Event: Decodable {
                let idEvent: String
                let strLeague: String?
                let strHomeTeam: String?
                let strAwayTeam: String?
                let strTimestamp: String?
            }
            let events: [Event]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        return (payload.events ?? []).compactMap { event in
            guard let home = event.strHomeTeam, !home.isEmpty,
                let away = event.strAwayTeam, !away.isEmpty,
                let stamp = event.strTimestamp, let start = Self.date(from: stamp)
            else { return nil }
            return SportFixture(
                id: SportFixtureProvider.tsdb.prefix + event.idEvent,
                source: .tsdb,
                path: competition.path,
                kind: competition.kind,
                league: event.strLeague ?? competition.name,
                home: home, away: away,
                start: start)
        }
    }

    /// TheSportsDB stempelt in UTC, ohne Zonen-Suffix: „2026-08-16T16:00:00".
    static func date(from stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: stamp)
    }
}
